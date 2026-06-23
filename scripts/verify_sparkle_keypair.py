#!/usr/bin/env python3
"""Verify that Sparkle EdDSA public/private keys belong to the same pair."""

from __future__ import annotations

import base64
import os
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def _decode_base64(name: str, value: str) -> bytes:
    compact = "".join(value.split())
    if not compact:
        raise ValueError(f"{name} is empty")
    compact += "=" * (-len(compact) % 4)
    try:
        return base64.b64decode(compact, validate=True)
    except ValueError as exc:
        raise ValueError(f"{name} is not valid base64") from exc


def _main() -> int:
    private_key = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "")
    public_key = os.environ.get("SPARKLE_PUBLIC_ED_KEY", "")

    try:
        private_seed = _decode_base64("SPARKLE_ED_PRIVATE_KEY", private_key)
        expected_public = _decode_base64("SPARKLE_PUBLIC_ED_KEY", public_key)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if len(private_seed) != 32:
        print(
            "SPARKLE_ED_PRIVATE_KEY must decode to a 32-byte Ed25519 seed",
            file=sys.stderr,
        )
        return 1
    if len(expected_public) != 32:
        print(
            "SPARKLE_PUBLIC_ED_KEY must decode to a 32-byte Ed25519 public key",
            file=sys.stderr,
        )
        return 1

    derived_public = (
        Ed25519PrivateKey.from_private_bytes(private_seed)
        .public_key()
        .public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
    )
    if derived_public != expected_public:
        print(
            "SPARKLE_PUBLIC_ED_KEY does not match SPARKLE_ED_PRIVATE_KEY",
            file=sys.stderr,
        )
        return 1

    print("Sparkle EdDSA key pair verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
