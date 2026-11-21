#!/usr/bin/env python3
"""Check a release file's detached signatures against the release public keys.

Usage:
  verify-sig.py <file> <sig> <ed25519-keys-file>
                [--mldsa-sig <file> [--mldsa-keys <file>] [--require-mldsa]]

<sig> is the raw 64-byte Ed25519 signature of <file>. A key file holds one
base64 public key per line, the same format the apt archive uses; blank lines
and lines starting with '#' are ignored. A signature is accepted if any listed
key verifies it, so a two-phase rotation can trust the old and the new key at
once. A wrong-but-well-formed signing key would otherwise publish a release
nothing can verify, and releases are immutable.

A second, post-quantum signature may sit beside the first: the raw ML-DSA-65
(FIPS 204) signature of the same bytes, pure ML-DSA with the empty context so
that `openssl pkeyutl -verify -rawin` 3.5 or later checks it too. It is 3309
bytes and is checked against raw 1952-byte ML-DSA-65 public keys. It is a
hybrid, never a replacement:

  --mldsa-sig      where the second signature would be. The Ed25519 signature
                   is checked first and always; when a file is at this path,
                   it must verify as well.
  --mldsa-keys     the ML-DSA-65 public keys. A missing file, or one with no
                   key in it, means no key is configured, and a second
                   signature is then refused: a signature that cannot be
                   checked is not one that passed.
  --require-mldsa  refuse when the second signature is missing. A second
                   signature that may be left out protects nothing, since
                   whoever can forge the first one simply drops it.

Without --mldsa-sig only the Ed25519 signature is checked, exactly as before
the second signature existed.

Exit 0 verified. Exit 1 refused: a signature is missing, malformed or does not
verify, or the installed cryptography cannot check the second one. Exit 2 a
usage error, or one of our own key files is missing or malformed, which is a
problem with the trust anchor and not with the file being checked.
"""
import argparse
import base64
import binascii
import os
import sys
from pathlib import Path

from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

REFUSED = 1
TRUST_ANCHOR = 2

ED25519_KEY_BYTES = 32
# FIPS 204 sizes for ML-DSA-65.
MLDSA65_KEY_BYTES = 1952
MLDSA65_SIG_BYTES = 3309
# The second signature is read with a cap, so a hostile or corrupt file is
# never read whole before its length is known.
MAX_MLDSA65_SIG_BYTES = 4096


def fail(code: int, message: str) -> None:
	print(message, file=sys.stderr)
	sys.exit(code)


def read_keys(path: str, size: int, what: str, missing_is_empty: bool) -> list:
	"""Decode every key in a key file, each exactly <size> raw bytes.

	Anything wrong with the file is our own trust anchor being broken, so it
	exits 2 and never reads as a signature that failed.
	"""
	try:
		text = Path(path).read_text(encoding="utf-8")
	except FileNotFoundError:
		if missing_is_empty:
			return []
		fail(TRUST_ANCHOR, f"{what} key file {path} not found")
	except (OSError, UnicodeDecodeError) as exc:
		fail(TRUST_ANCHOR, f"cannot read the {what} key file {path}: {exc}")
	keys = []
	for number, line in enumerate(text.splitlines(), 1):
		line = line.strip()
		if not line or line.startswith("#"):
			continue
		# The committed keys are unpadded. validate=True rejects a character
		# outside standard base64 instead of silently dropping it and loading
		# a different key.
		try:
			raw = base64.b64decode(line + "=" * (-len(line) % 4), validate=True)
		except binascii.Error as exc:
			fail(TRUST_ANCHOR, f"malformed {what} public key on line {number} of {path}: not base64 ({exc})")
		if len(raw) != size:
			fail(
				TRUST_ANCHOR,
				f"malformed {what} public key on line {number} of {path}: {len(raw)} bytes, expected {size}",
			)
		keys.append(raw)
	return keys


def check_ed25519(data: bytes, args: argparse.Namespace) -> None:
	raw_keys = read_keys(args.keys, ED25519_KEY_BYTES, "Ed25519", missing_is_empty=False)
	if not raw_keys:
		fail(TRUST_ANCHOR, f"no public keys to verify against in {args.keys}")
	try:
		keys = [Ed25519PublicKey.from_public_bytes(raw) for raw in raw_keys]
	except ValueError as exc:
		fail(TRUST_ANCHOR, f"malformed Ed25519 public key in {args.keys}: {exc}")
	try:
		sig = Path(args.sig).read_bytes()
	except OSError as exc:
		fail(REFUSED, f"no Ed25519 signature for {args.file}: {exc}")
	for key in keys:
		try:
			key.verify(sig, data)
			return
		except InvalidSignature:
			continue
	fail(REFUSED, f"no release key verifies {args.file}")


def check_mldsa65(data: bytes, args: argparse.Namespace) -> str:
	"""Check the second signature, after the Ed25519 one passed. Returns how."""
	raw_keys = []
	if args.mldsa_keys is not None:
		raw_keys = read_keys(args.mldsa_keys, MLDSA65_KEY_BYTES, "ML-DSA-65", missing_is_empty=True)

	# lexists, so a dangling link counts as a second signature that is there
	# and cannot be read, and is refused rather than taken as absent.
	if not os.path.lexists(args.mldsa_sig):
		if args.require_mldsa:
			fail(
				REFUSED,
				f"no ML-DSA-65 signature ({args.mldsa_sig}) for {args.file}; the hybrid release signature is required",
			)
		return "Ed25519; no ML-DSA-65 signature, and none is required"

	if not raw_keys:
		fail(
			REFUSED,
			f"{args.file} carries an ML-DSA-65 signature and no ML-DSA-65 release public key is configured;"
			" refusing a signature that cannot be checked",
		)
	try:
		with open(args.mldsa_sig, "rb") as f:
			sig = f.read(MAX_MLDSA65_SIG_BYTES + 1)
	except OSError as exc:
		fail(REFUSED, f"cannot read the ML-DSA-65 signature file {args.mldsa_sig}: {exc}")
	if len(sig) > MAX_MLDSA65_SIG_BYTES:
		fail(REFUSED, f"ML-DSA-65 signature file {args.mldsa_sig} is over {MAX_MLDSA65_SIG_BYTES} bytes")
	if len(sig) != MLDSA65_SIG_BYTES:
		fail(REFUSED, f"ML-DSA-65 signature is {len(sig)} bytes, expected exactly {MLDSA65_SIG_BYTES}")

	# Imported only here: nothing before this line needs ML-DSA, so the
	# Ed25519 check keeps working on a system cryptography that lacks it.
	try:
		from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PublicKey

		keys = [MLDSA65PublicKey.from_public_bytes(raw) for raw in raw_keys]
	except (ImportError, UnsupportedAlgorithm) as exc:
		fail(
			REFUSED,
			f"cannot verify the ML-DSA-65 signature of {args.file}: the installed cryptography has no ML-DSA"
			f" support ({exc}); cryptography 50.0.2 or later is required, pinned in"
			" .github/scripts/release/sign-requirements.txt. Refusing rather than skipping it",
		)
	except ValueError as exc:
		fail(TRUST_ANCHOR, f"malformed ML-DSA-65 public key in {args.mldsa_keys}: {exc}")
	for key in keys:
		try:
			key.verify(sig, data)
			return "Ed25519 and ML-DSA-65"
		except InvalidSignature:
			continue
	fail(REFUSED, f"no ML-DSA-65 release key verifies {args.file}")
	return ""


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(
		usage="verify-sig.py <file> <sig> <ed25519-keys-file>"
		" [--mldsa-sig <file> [--mldsa-keys <file>] [--require-mldsa]]",
		description=__doc__,
		formatter_class=argparse.RawDescriptionHelpFormatter,
	)
	parser.add_argument("file")
	parser.add_argument("sig")
	parser.add_argument("keys")
	parser.add_argument("--mldsa-sig")
	parser.add_argument("--mldsa-keys")
	parser.add_argument("--require-mldsa", action="store_true")
	args = parser.parse_args()
	# Both options only mean something next to a path to look at. Accepting
	# them alone would read as "the second signature is checked" while nothing
	# is, and a required signature nobody looks for is not required.
	if args.mldsa_sig is None and (args.mldsa_keys is not None or args.require_mldsa):
		parser.error("--mldsa-keys and --require-mldsa need --mldsa-sig")
	return args


def main() -> None:
	args = parse_args()
	try:
		data = Path(args.file).read_bytes()
	except OSError as exc:
		fail(REFUSED, f"cannot read {args.file}: {exc}")
	check_ed25519(data, args)
	if args.mldsa_sig is None:
		print(f"verified {args.file}")
		return
	how = check_mldsa65(data, args)
	print(f"verified {args.file} ({how})")


if __name__ == "__main__":
	main()
