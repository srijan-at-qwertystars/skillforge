#!/usr/bin/env python3
"""
create-test-jwt.py — Generate test JWTs for development and testing

Usage:
    ./create-test-jwt.py [OPTIONS]

Options:
    --claims JSON          JSON string of claims (or @filename to read from file)
    --secret SECRET        HMAC secret for HS256 signing
    --key-file FILE        Path to RSA/EC private key PEM file
    --algorithm ALG        Signing algorithm: HS256 (default), RS256, ES256
    --expiration SECONDS   Set 'exp' claim to now + SECONDS (default: 3600)
    --issuer ISS           Set 'iss' claim
    --audience AUD         Set 'aud' claim
    --subject SUB          Set 'sub' claim
    --jti                  Auto-generate a 'jti' (JWT ID) claim
    --not-before SECONDS   Set 'nbf' to now + SECONDS (negative = past)
    --expired              Create an already-expired token (exp = now - 3600)
    --not-yet-valid        Create a not-yet-valid token (nbf = now + 3600)
    --no-iat               Omit the 'iat' (issued at) claim
    --malformed TYPE       Create a malformed token for testing:
                             missing-sig   — remove signature
                             empty-payload — empty payload
                             bad-header    — invalid header JSON
                             none-alg      — use 'none' algorithm (no sig)
    --header JSON          Additional header fields as JSON
    -h, --help             Show this help message

Requirements:
    pip install PyJWT

    For RS256/ES256, also install cryptography:
    pip install PyJWT cryptography

Examples:
    # Simple HS256 token
    ./create-test-jwt.py --secret "my-secret" --claims '{"user_id": 42, "role": "admin"}'

    # RS256 with key file
    ./create-test-jwt.py --algorithm RS256 --key-file private.pem --issuer "auth.example.com"

    # Expired token for testing
    ./create-test-jwt.py --secret "test" --expired --claims '{"user": "test"}'

    # Not-yet-valid token
    ./create-test-jwt.py --secret "test" --not-yet-valid

    # Malformed token (no signature)
    ./create-test-jwt.py --secret "test" --malformed missing-sig

    # Claims from file
    ./create-test-jwt.py --secret "test" --claims @claims.json
"""

import argparse
import base64
import json
import os
import sys
import time
import uuid


def import_jwt():
    """Import PyJWT with helpful error message."""
    try:
        import jwt
        return jwt
    except ImportError:
        print(
            "ERROR: PyJWT is required. Install with:\n"
            "  pip install PyJWT\n"
            "  pip install PyJWT cryptography  # for RS256/ES256",
            file=sys.stderr,
        )
        sys.exit(1)


def base64url_encode(data: bytes) -> str:
    """Base64url encode without padding."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_claims(claims_str: str) -> dict:
    """Load claims from JSON string or @filename."""
    if claims_str.startswith("@"):
        filepath = claims_str[1:]
        if not os.path.isfile(filepath):
            print(f"ERROR: Claims file not found: {filepath}", file=sys.stderr)
            sys.exit(1)
        with open(filepath, "r") as f:
            return json.load(f)
    return json.loads(claims_str)


def create_malformed_token(malformed_type: str, payload: dict, secret: str, algorithm: str) -> str:
    """Create various malformed tokens for security testing."""
    now = int(time.time())
    payload.setdefault("iat", now)
    payload.setdefault("exp", now + 3600)

    if malformed_type == "missing-sig":
        header = {"alg": algorithm, "typ": "JWT"}
        header_b64 = base64url_encode(json.dumps(header, separators=(",", ":")).encode())
        payload_b64 = base64url_encode(json.dumps(payload, separators=(",", ":")).encode())
        return f"{header_b64}.{payload_b64}."

    elif malformed_type == "empty-payload":
        header = {"alg": algorithm, "typ": "JWT"}
        header_b64 = base64url_encode(json.dumps(header, separators=(",", ":")).encode())
        payload_b64 = base64url_encode(b"{}")
        sig_b64 = base64url_encode(b"invalidsignature")
        return f"{header_b64}.{payload_b64}.{sig_b64}"

    elif malformed_type == "bad-header":
        header_b64 = base64url_encode(b"not-json-at-all")
        payload_b64 = base64url_encode(json.dumps(payload, separators=(",", ":")).encode())
        sig_b64 = base64url_encode(b"invalidsignature")
        return f"{header_b64}.{payload_b64}.{sig_b64}"

    elif malformed_type == "none-alg":
        header = {"alg": "none", "typ": "JWT"}
        header_b64 = base64url_encode(json.dumps(header, separators=(",", ":")).encode())
        payload_b64 = base64url_encode(json.dumps(payload, separators=(",", ":")).encode())
        return f"{header_b64}.{payload_b64}."

    else:
        print(
            f"ERROR: Unknown malformed type: {malformed_type}\n"
            f"Valid types: missing-sig, empty-payload, bad-header, none-alg",
            file=sys.stderr,
        )
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Generate test JWTs for development and testing",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Requires: pip install PyJWT (and cryptography for RS256/ES256)",
    )

    parser.add_argument("--claims", default="{}", help="JSON claims or @filename")
    parser.add_argument("--secret", default=None, help="HMAC secret for HS256")
    parser.add_argument("--key-file", default=None, help="Private key PEM file for RS256/ES256")
    parser.add_argument("--algorithm", default="HS256", help="Algorithm (default: HS256)")
    parser.add_argument("--expiration", type=int, default=3600, help="Seconds until expiration (default: 3600)")
    parser.add_argument("--issuer", default=None, help="Set iss claim")
    parser.add_argument("--audience", default=None, help="Set aud claim")
    parser.add_argument("--subject", default=None, help="Set sub claim")
    parser.add_argument("--jti", action="store_true", help="Auto-generate jti claim")
    parser.add_argument("--not-before", type=int, default=None, help="Set nbf to now + SECONDS")
    parser.add_argument("--expired", action="store_true", help="Create already-expired token")
    parser.add_argument("--not-yet-valid", action="store_true", help="Create not-yet-valid token")
    parser.add_argument("--no-iat", action="store_true", help="Omit iat claim")
    parser.add_argument("--malformed", default=None, help="Create malformed token (missing-sig|empty-payload|bad-header|none-alg)")
    parser.add_argument("--header", default=None, help="Additional header fields as JSON")

    args = parser.parse_args()

    # Build payload from claims
    try:
        payload = load_claims(args.claims)
    except json.JSONDecodeError as e:
        print(f"ERROR: Invalid JSON in --claims: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(payload, dict):
        print("ERROR: Claims must be a JSON object (dict)", file=sys.stderr)
        sys.exit(1)

    now = int(time.time())

    # Set standard claims
    if not args.no_iat:
        payload.setdefault("iat", now)

    if args.expired:
        payload["exp"] = now - 3600
    elif "exp" not in payload:
        payload["exp"] = now + args.expiration

    if args.issuer:
        payload["iss"] = args.issuer

    if args.audience:
        payload["aud"] = args.audience

    if args.subject:
        payload["sub"] = args.subject

    if args.jti:
        payload["jti"] = str(uuid.uuid4())

    if args.not_yet_valid:
        payload["nbf"] = now + 3600
    elif args.not_before is not None:
        payload["nbf"] = now + args.not_before

    # Handle malformed tokens (no PyJWT needed for these)
    if args.malformed:
        secret = args.secret or "test-secret"
        token = create_malformed_token(args.malformed, payload, secret, args.algorithm)
        print(token)
        return

    # Import PyJWT for normal token creation
    jwt = import_jwt()

    # Determine signing key
    algorithm = args.algorithm.upper()
    signing_key = None

    if algorithm.startswith("HS"):
        if not args.secret:
            print("ERROR: --secret is required for HMAC algorithms", file=sys.stderr)
            sys.exit(1)
        signing_key = args.secret

    elif algorithm.startswith("RS") or algorithm.startswith("PS") or algorithm.startswith("ES"):
        if not args.key_file:
            print(f"ERROR: --key-file is required for {algorithm}", file=sys.stderr)
            sys.exit(1)
        if not os.path.isfile(args.key_file):
            print(f"ERROR: Key file not found: {args.key_file}", file=sys.stderr)
            sys.exit(1)
        with open(args.key_file, "r") as f:
            signing_key = f.read()
    else:
        print(f"ERROR: Unsupported algorithm: {algorithm}", file=sys.stderr)
        sys.exit(1)

    # Build additional headers
    extra_headers = {}
    if args.header:
        try:
            extra_headers = json.loads(args.header)
        except json.JSONDecodeError as e:
            print(f"ERROR: Invalid JSON in --header: {e}", file=sys.stderr)
            sys.exit(1)

    # Create the token
    try:
        token = jwt.encode(
            payload,
            signing_key,
            algorithm=algorithm,
            headers=extra_headers if extra_headers else None,
        )
        # PyJWT >= 2.0 returns str, older versions return bytes
        if isinstance(token, bytes):
            token = token.decode("ascii")
        print(token)
    except Exception as e:
        print(f"ERROR: Failed to create JWT: {e}", file=sys.stderr)
        sys.exit(1)

    # Print info to stderr so stdout has just the token
    print(f"\n--- Token Details (stderr) ---", file=sys.stderr)
    print(f"Algorithm: {algorithm}", file=sys.stderr)
    print(f"Payload:   {json.dumps(payload, indent=2)}", file=sys.stderr)
    if args.expired:
        print(f"Status:    EXPIRED (for testing)", file=sys.stderr)
    elif args.not_yet_valid:
        print(f"Status:    NOT YET VALID (for testing)", file=sys.stderr)
    else:
        print(f"Expires:   in {args.expiration}s", file=sys.stderr)


if __name__ == "__main__":
    main()
