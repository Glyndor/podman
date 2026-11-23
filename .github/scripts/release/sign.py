#!/usr/bin/env python3
"""Sign a file with the active Glyndor release Ed25519 key (32-byte seed, base64).

Usage:
  sign.py <input-file> [<output-sig-file>]

The active signing seed is read from GLYNDOR_RELEASE_ED25519_KEY, in the
environment and never on the command line, so it never appears in the process
argument list (/proc/<pid>/cmdline). It is a raw 32-byte Ed25519 private key in
standard base64. When output-sig-file is omitted, writes <input-file>.sig.

Rotation is by dual-TRUST, not dual-sign: consumers (install.sh, install.ps1,
verify-debs.sh, internal/update/verify.rs) bake BOTH accepted public keys and
accept a release signed by either, so the active signer can be switched to the
second key with no consumer change. Only one detached .sig is ever produced, the
one signature every verifier reads. Fails closed (exit 1) when the key is unset,
to never publish an unsigned artifact.

A second, post-quantum signature is written as well when
GLYNDOR_RELEASE_MLDSA65_KEY is set: a 32-byte ML-DSA-65 seed in standard base64,
from the environment for the same reason. It goes beside the first one, with
.sig replaced by .mldsa65.sig (<input-file>.mldsa65.sig by default), and holds
the raw 3309-byte ML-DSA-65 (FIPS 204) signature of the same bytes, pure
ML-DSA with the empty context, so `openssl pkeyutl -verify -rawin` 3.5 or later
checks it too. It is added beside the Ed25519 signature, never in its place.

An unset or empty GLYNDOR_RELEASE_MLDSA65_KEY signs with Ed25519 only, as before
the second signature existed, and says so. A set one that is not a valid seed is
an error before anything is written: it never falls back to Ed25519 alone.
"""
import base64
import os
import stat
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

KEY_ENV = "GLYNDOR_RELEASE_ED25519_KEY"
MLDSA65_KEY_ENV = "GLYNDOR_RELEASE_MLDSA65_KEY"


def decode_seed(env: str, seed_b64: str) -> bytes:
	# Normalise padding to a 4-char boundary (the seed is stored unpadded), then
	# validate=True rejects a non-base64 seed (e.g. URL-safe -/_ or a stray char)
	# instead of silently discarding it and signing with a wrong key that nothing
	# can verify. The length check is defence-in-depth over from_private_bytes.
	pad = "=" * (-len(seed_b64) % 4)
	try:
		seed = base64.b64decode(seed_b64 + pad, validate=True)
	except (ValueError, base64.binascii.Error) as exc:
		print(f"{env} is not valid base64: {exc}", file=sys.stderr)
		sys.exit(1)
	if len(seed) != 32:
		print(f"{env} must decode to 32 bytes, got {len(seed)}", file=sys.stderr)
		sys.exit(1)
	return seed


def read_regular(path: str) -> bytes:
	"""Read the file to sign: a regular file, never a link to something else."""
	try:
		fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
		with os.fdopen(fd, "rb") as f:
			if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
				raise OSError(f"{path} is not a regular file")
			return f.read()
	except OSError as exc:
		sys.exit(f"refusing to sign {path}: {exc}")


def write_new(path: str, data: bytes) -> None:
	"""Write a signature to a path that is not a link: a link there would send it elsewhere."""
	try:
		fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
		with os.fdopen(fd, "wb") as f:
			f.write(data)
	except OSError as exc:
		sys.exit(f"cannot write {path}: {exc}")


def mldsa65_sig_path(sig_file: str) -> str:
	return (sig_file[: -len(".sig")] if sig_file.endswith(".sig") else sig_file) + ".mldsa65.sig"


def main() -> None:
	if len(sys.argv) < 2:
		print(__doc__, file=sys.stderr)
		sys.exit(1)

	seed_b64 = os.environ.get(KEY_ENV, "").strip()
	if not seed_b64:
		print(
			f"{KEY_ENV} is not set; refusing to publish an unsigned artifact",
			file=sys.stderr,
		)
		sys.exit(1)

	input_file = sys.argv[1]
	sig_file = sys.argv[2] if len(sys.argv) > 2 else input_file + ".sig"
	seed = decode_seed(KEY_ENV, seed_b64)

	# Every check on the second key runs before anything is written, so a bad
	# seed or a library without ML-DSA leaves no signature behind. An empty value
	# is how a workflow passes a secret that is not configured, so it reads as
	# unset; any other value is meant to be a key and must be one.
	mldsa_b64 = os.environ.get(MLDSA65_KEY_ENV, "")
	mldsa_key = None
	if mldsa_b64:
		mldsa_seed = decode_seed(MLDSA65_KEY_ENV, mldsa_b64.strip())
		# Imported only when there is a second key: signing with Ed25519 alone
		# keeps working on a system cryptography that has no ML-DSA.
		try:
			from cryptography.exceptions import UnsupportedAlgorithm
			from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey

			mldsa_key = MLDSA65PrivateKey.from_seed_bytes(mldsa_seed)
		except (ImportError, UnsupportedAlgorithm) as exc:
			print(
				f"{MLDSA65_KEY_ENV} is set and the installed cryptography cannot sign ML-DSA-65 ({exc});"
				" cryptography 50.0.2 or later is required, pinned in sign-requirements.txt",
				file=sys.stderr,
			)
			sys.exit(1)

	data = read_regular(input_file)

	sig = Ed25519PrivateKey.from_private_bytes(seed).sign(data)
	mldsa_sig = mldsa_key.sign(data) if mldsa_key is not None else None

	write_new(sig_file, sig)
	print(f"signed {input_file} ({len(data):,} bytes) → {sig_file} ({len(sig)} bytes)")

	if mldsa_sig is None:
		print(f"{MLDSA65_KEY_ENV} is not set; wrote the Ed25519 signature only")
		return
	mldsa_file = mldsa65_sig_path(sig_file)
	write_new(mldsa_file, mldsa_sig)
	print(f"signed {input_file} → {mldsa_file} ({len(mldsa_sig)} bytes, ML-DSA-65)")


if __name__ == "__main__":
	main()
