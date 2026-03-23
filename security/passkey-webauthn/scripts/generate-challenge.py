#!/usr/bin/env python3
"""
generate-challenge.py — Cryptographically secure WebAuthn challenge generator.

Generates challenges suitable for WebAuthn registration and authentication ceremonies.
Challenges are base64url-encoded (no padding) per the WebAuthn specification.

Usage:
    python3 generate-challenge.py                     # 32-byte challenge (default)
    python3 generate-challenge.py --bytes 64          # 64-byte challenge
    python3 generate-challenge.py --count 5           # generate 5 challenges
    python3 generate-challenge.py --format hex        # output as hex
    python3 generate-challenge.py --format json       # output as JSON with metadata
    python3 generate-challenge.py --format raw        # output raw bytes to stdout

Requirements: Python 3.6+ (no external dependencies)
"""

import argparse
import base64
import json
import os
import secrets
import sys
import time
from datetime import datetime, timezone


def generate_challenge(num_bytes: int = 32) -> bytes:
    """Generate a cryptographically secure random challenge.

    Uses os.urandom() via the secrets module, which sources from the OS CSPRNG
    (/dev/urandom on Linux, CryptGenRandom on Windows).

    Args:
        num_bytes: Number of random bytes. Minimum 16 (128 bits) per WebAuthn spec.
                   Default 32 (256 bits) for extra security margin.

    Returns:
        Raw challenge bytes.

    Raises:
        ValueError: If num_bytes < 16.
    """
    if num_bytes < 16:
        raise ValueError(
            f"Challenge must be at least 16 bytes (128 bits). Got {num_bytes}. "
            "WebAuthn spec §13.4.3 requires sufficient entropy to prevent replay."
        )
    return secrets.token_bytes(num_bytes)


def to_base64url(data: bytes) -> str:
    """Encode bytes to base64url without padding (WebAuthn standard encoding)."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def to_hex(data: bytes) -> str:
    """Encode bytes to hexadecimal string."""
    return data.hex()


def to_base64_standard(data: bytes) -> str:
    """Encode bytes to standard base64 (with padding)."""
    return base64.b64encode(data).decode("ascii")


def format_challenge(challenge: bytes, fmt: str, index: int = 0, total: int = 1) -> str:
    """Format a challenge for output.

    Args:
        challenge: Raw challenge bytes.
        fmt: Output format — 'base64url', 'hex', 'json', 'raw', 'all'.
        index: Challenge index (for multi-challenge generation).
        total: Total number of challenges being generated.

    Returns:
        Formatted string representation.
    """
    if fmt == "raw":
        sys.stdout.buffer.write(challenge)
        return ""

    if fmt == "hex":
        return to_hex(challenge)

    if fmt == "json":
        obj = {
            "challenge_base64url": to_base64url(challenge),
            "challenge_hex": to_hex(challenge),
            "challenge_base64": to_base64_standard(challenge),
            "byte_length": len(challenge),
            "bit_length": len(challenge) * 8,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "expires_at": datetime.fromtimestamp(
                time.time() + 300, tz=timezone.utc
            ).isoformat(),
            "ttl_seconds": 300,
        }
        return json.dumps(obj, indent=2)

    if fmt == "all":
        lines = []
        if total > 1:
            lines.append(f"--- Challenge {index + 1}/{total} ---")
        lines.append(f"  base64url: {to_base64url(challenge)}")
        lines.append(f"  hex:       {to_hex(challenge)}")
        lines.append(f"  base64:    {to_base64_standard(challenge)}")
        lines.append(f"  bytes:     {len(challenge)}")
        return "\n".join(lines)

    # Default: base64url
    return to_base64url(challenge)


def validate_entropy_source() -> None:
    """Verify the system CSPRNG is available and functional."""
    try:
        test = os.urandom(32)
        if len(test) != 32 or test == b"\x00" * 32:
            print("WARNING: os.urandom() may not be functioning correctly.", file=sys.stderr)
            sys.exit(1)
    except NotImplementedError:
        print("ERROR: os.urandom() is not available on this system.", file=sys.stderr)
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate cryptographically secure WebAuthn challenges.",
        epilog="Challenges are single-use and should expire within 5 minutes.",
    )
    parser.add_argument(
        "--bytes", "-b",
        type=int,
        default=32,
        help="Challenge length in bytes (min: 16, default: 32)",
    )
    parser.add_argument(
        "--count", "-n",
        type=int,
        default=1,
        help="Number of challenges to generate (default: 1)",
    )
    parser.add_argument(
        "--format", "-f",
        choices=["base64url", "hex", "json", "raw", "all"],
        default="base64url",
        help="Output format (default: base64url)",
    )

    args = parser.parse_args()

    if args.count < 1:
        print("ERROR: --count must be at least 1.", file=sys.stderr)
        sys.exit(1)

    validate_entropy_source()

    try:
        for i in range(args.count):
            challenge = generate_challenge(args.bytes)
            output = format_challenge(challenge, args.format, i, args.count)
            if output:
                print(output)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
