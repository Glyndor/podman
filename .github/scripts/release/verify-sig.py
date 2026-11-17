#!/usr/bin/env python3
"""Check a detached Ed25519 signature against the release public keys.

Usage: verify-sig.py <file> <sig> <keys-file>

<keys-file> holds one base64 public key per line, the same format the apt
archive uses. The signature is accepted if any key verifies it; a wrong-but-
well-formed signing key would otherwise publish a release nothing can verify,
and releases are immutable. Exit 0 verified, 1 otherwise.
"""
import base64
import sys
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


def main() -> None:
	if len(sys.argv) != 4:
		sys.exit(__doc__)
	data = Path(sys.argv[1]).read_bytes()
	sig = Path(sys.argv[2]).read_bytes()
	keys = [k.strip() for k in Path(sys.argv[3]).read_text().splitlines() if k.strip()]
	if not keys:
		sys.exit("no public keys to verify against")
	for key in keys:
		raw = base64.b64decode(key + "=" * (-len(key) % 4), validate=True)
		try:
			Ed25519PublicKey.from_public_bytes(raw).verify(sig, data)
			print(f"verified {sys.argv[1]}")
			return
		except InvalidSignature:
			continue
	sys.exit(f"no release key verifies {sys.argv[1]}")


if __name__ == "__main__":
	main()
