#!/usr/bin/env python3
"""Make the throwaway signing keys of a rehearsal of the release.

Usage:
  dry-run-keys.py <directory> [--mldsa]

The directory has to be new. It receives, each in a file that did not exist and
that only its owner can read where it holds a private seed:

  ed25519.seed   a random 32-byte Ed25519 seed, in standard base64, which is the
                 shape GLYNDOR_RELEASE_ED25519_KEY has
  ed25519.b64    the public key of that seed, as the anchor file of keyring/ has it
  mldsa65.seed   with --mldsa, a random 32-byte ML-DSA-65 seed
  mldsa65.b64    with --mldsa, its raw public key in the anchor format

The seeds exist only for the run of the rehearsal, are never printed, and verify
nothing outside it: the real anchors are not touched and these keys are in none
of them. A rehearsal signs with them what a release would sign with the real
ones, so that the whole path is run without the secrets being read.
"""
import base64
import os
import sys

from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def write_new(path: str, text: str, mode: int) -> None:
	fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
	with os.fdopen(fd, "w") as fh:
		fh.write(text)


def b64(raw: bytes) -> str:
	return base64.b64encode(raw).decode("ascii")


def main(argv: list[str]) -> int:
	args = [a for a in argv if a != "--mldsa"]
	with_mldsa = len(args) != len(argv)
	if len(args) != 1:
		print("usage: dry-run-keys.py <directory> [--mldsa]", file=sys.stderr)
		return 2
	directory = args[0]
	os.mkdir(directory, 0o700)
	raw = s.Encoding.Raw, s.PublicFormat.Raw

	seed = os.urandom(32)
	write_new(os.path.join(directory, "ed25519.seed"), b64(seed) + "\n", 0o600)
	pub = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(*raw)
	write_new(os.path.join(directory, "ed25519.b64"), "# Throwaway key of a rehearsal.\n" + b64(pub) + "\n", 0o644)

	if with_mldsa:
		try:
			from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey
		except ImportError as exc:
			print(f"the installed cryptography cannot make ML-DSA-65 keys ({exc})", file=sys.stderr)
			return 1
		seed = os.urandom(32)
		write_new(os.path.join(directory, "mldsa65.seed"), b64(seed) + "\n", 0o600)
		pub = MLDSA65PrivateKey.from_seed_bytes(seed).public_key().public_bytes(*raw)
		write_new(os.path.join(directory, "mldsa65.b64"), "# Throwaway key of a rehearsal.\n" + b64(pub) + "\n", 0o644)
	return 0


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
