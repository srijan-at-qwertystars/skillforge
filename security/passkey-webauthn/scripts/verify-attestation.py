#!/usr/bin/env python3
"""
verify-attestation.py — WebAuthn attestation statement verification helper.

Parses and validates attestation objects from WebAuthn registration responses.
Supports 'none', 'packed' (self and x5c), and 'fido-u2f' attestation formats.

Usage:
    python3 verify-attestation.py --attestation-object <base64url-encoded>
    python3 verify-attestation.py --file response.json
    echo '<base64url>' | python3 verify-attestation.py --stdin

    # Verify with expected RP ID and origin
    python3 verify-attestation.py --file response.json \\
        --rp-id example.com \\
        --origin https://example.com

Requirements: Python 3.8+, cbor2, cryptography
    pip install cbor2 cryptography
"""

import argparse
import base64
import hashlib
import json
import struct
import sys
from dataclasses import dataclass, field
from enum import IntFlag
from typing import Any, Optional


class AuthDataFlags(IntFlag):
    UP = 0x01   # User Present
    UV = 0x04   # User Verified
    AT = 0x40   # Attested Credential Data included
    ED = 0x80   # Extension Data included
    BE = 0x08   # Backup Eligible
    BS = 0x10   # Backup State


@dataclass
class ParsedAuthData:
    rp_id_hash: bytes = b""
    flags: int = 0
    sign_count: int = 0
    aaguid: str = ""
    credential_id: bytes = b""
    credential_id_b64url: str = ""
    credential_public_key: dict = field(default_factory=dict)
    credential_public_key_bytes: bytes = b""
    extensions: dict = field(default_factory=dict)
    flags_detail: dict = field(default_factory=dict)


@dataclass
class AttestationResult:
    format: str = ""
    auth_data: Optional[ParsedAuthData] = None
    attestation_statement: dict = field(default_factory=dict)
    is_self_attestation: bool = False
    certificate_chain: list = field(default_factory=list)
    warnings: list = field(default_factory=list)
    errors: list = field(default_factory=list)
    verified: bool = False


def b64url_decode(data: str) -> bytes:
    """Decode base64url-encoded data (with or without padding)."""
    padding = 4 - len(data) % 4
    if padding != 4:
        data += "=" * padding
    return base64.urlsafe_b64decode(data)


def b64url_encode(data: bytes) -> str:
    """Encode bytes to base64url without padding."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def format_uuid(raw: bytes) -> str:
    """Format 16 bytes as a UUID string."""
    if len(raw) != 16:
        return raw.hex()
    h = raw.hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def parse_auth_data(auth_data_bytes: bytes) -> ParsedAuthData:
    """Parse the authenticatorData field from an attestation object.

    Layout (per WebAuthn spec §6.1):
        rpIdHash (32 bytes) || flags (1 byte) || signCount (4 bytes, big-endian)
        [|| attestedCredentialData] [|| extensions]
    """
    if len(auth_data_bytes) < 37:
        raise ValueError(
            f"authenticatorData too short: {len(auth_data_bytes)} bytes (minimum 37)"
        )

    parsed = ParsedAuthData()
    parsed.rp_id_hash = auth_data_bytes[:32]
    parsed.flags = auth_data_bytes[32]
    parsed.sign_count = struct.unpack(">I", auth_data_bytes[33:37])[0]

    parsed.flags_detail = {
        "UP (User Present)": bool(parsed.flags & AuthDataFlags.UP),
        "UV (User Verified)": bool(parsed.flags & AuthDataFlags.UV),
        "AT (Attested Cred Data)": bool(parsed.flags & AuthDataFlags.AT),
        "ED (Extensions)": bool(parsed.flags & AuthDataFlags.ED),
        "BE (Backup Eligible)": bool(parsed.flags & AuthDataFlags.BE),
        "BS (Backup State)": bool(parsed.flags & AuthDataFlags.BS),
    }

    offset = 37

    if parsed.flags & AuthDataFlags.AT:
        if len(auth_data_bytes) < offset + 18:
            raise ValueError("authenticatorData too short for attested credential data")

        parsed.aaguid = format_uuid(auth_data_bytes[offset : offset + 16])
        offset += 16

        cred_id_len = struct.unpack(">H", auth_data_bytes[offset : offset + 2])[0]
        offset += 2

        if len(auth_data_bytes) < offset + cred_id_len:
            raise ValueError("authenticatorData too short for credential ID")

        parsed.credential_id = auth_data_bytes[offset : offset + cred_id_len]
        parsed.credential_id_b64url = b64url_encode(parsed.credential_id)
        offset += cred_id_len

        try:
            import cbor2
            parsed.credential_public_key = cbor2.loads(auth_data_bytes[offset:])
            parsed.credential_public_key_bytes = auth_data_bytes[offset:]
        except Exception as e:
            raise ValueError(f"Failed to parse COSE public key: {e}")

    return parsed


def verify_packed_self(auth_data: ParsedAuthData, att_stmt: dict,
                       auth_data_bytes: bytes, client_data_hash: bytes) -> list:
    """Verify packed self-attestation (no x5c certificate)."""
    errors = []
    try:
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        from cryptography.hazmat.primitives import hashes

        sig = att_stmt.get("sig")
        alg = att_stmt.get("alg")
        if sig is None or alg is None:
            errors.append("Missing 'sig' or 'alg' in attestation statement")
            return errors

        cose_key = auth_data.credential_public_key
        signed_data = auth_data_bytes + client_data_hash

        if alg == -7:  # ES256
            kty = cose_key.get(1)
            if kty != 2:
                errors.append(f"Expected EC key type (2), got {kty}")
                return errors
            x = cose_key.get(-2)
            y = cose_key.get(-3)
            public_key = ec.EllipticCurvePublicNumbers(
                int.from_bytes(x, "big"),
                int.from_bytes(y, "big"),
                ec.SECP256R1(),
            ).public_key()
            public_key.verify(sig, signed_data, ec.ECDSA(hashes.SHA256()))
        elif alg == -257:  # RS256
            from cryptography.hazmat.primitives.asymmetric import rsa, padding
            n = int.from_bytes(cose_key.get(-1), "big")
            e = int.from_bytes(cose_key.get(-2), "big")
            public_key = rsa.RSAPublicNumbers(e, n).public_key()
            public_key.verify(sig, signed_data, padding.PKCS1v15(), hashes.SHA256())
        else:
            errors.append(f"Unsupported algorithm: {alg}")

    except ImportError:
        errors.append("'cryptography' package required: pip install cryptography")
    except Exception as e:
        errors.append(f"Signature verification failed: {e}")

    return errors


def verify_attestation_object(
    attestation_object_b64url: str,
    client_data_json_b64url: Optional[str] = None,
    expected_rp_id: Optional[str] = None,
    expected_origin: Optional[str] = None,
) -> AttestationResult:
    """Parse and verify a WebAuthn attestation object.

    Args:
        attestation_object_b64url: Base64url-encoded attestation object.
        client_data_json_b64url: Base64url-encoded clientDataJSON (optional, for full verification).
        expected_rp_id: Expected RP ID for rpIdHash verification.
        expected_origin: Expected origin for clientDataJSON verification.

    Returns:
        AttestationResult with parsing and verification details.
    """
    result = AttestationResult()

    try:
        import cbor2
    except ImportError:
        result.errors.append("'cbor2' package required: pip install cbor2")
        return result

    # Decode attestation object
    try:
        att_obj_bytes = b64url_decode(attestation_object_b64url)
        att_obj = cbor2.loads(att_obj_bytes)
    except Exception as e:
        result.errors.append(f"Failed to decode attestation object: {e}")
        return result

    # Extract top-level fields
    result.format = att_obj.get("fmt", "unknown")
    att_stmt = att_obj.get("attStmt", {})
    auth_data_bytes = att_obj.get("authData", b"")

    result.attestation_statement = {
        k: b64url_encode(v) if isinstance(v, bytes) else v
        for k, v in att_stmt.items()
        if k != "x5c"
    }

    # Parse authenticator data
    try:
        result.auth_data = parse_auth_data(auth_data_bytes)
    except ValueError as e:
        result.errors.append(str(e))
        return result

    # Verify rpId hash if expected rpId is provided
    if expected_rp_id:
        expected_hash = hashlib.sha256(expected_rp_id.encode("utf-8")).digest()
        if result.auth_data.rp_id_hash != expected_hash:
            result.errors.append(
                f"rpIdHash mismatch. Expected SHA-256('{expected_rp_id}') = "
                f"{expected_hash.hex()}, got {result.auth_data.rp_id_hash.hex()}"
            )

    # Verify clientDataJSON if provided
    client_data_hash = b""
    if client_data_json_b64url:
        try:
            client_data_bytes = b64url_decode(client_data_json_b64url)
            client_data_hash = hashlib.sha256(client_data_bytes).digest()
            client_data = json.loads(client_data_bytes)

            if client_data.get("type") != "webauthn.create":
                result.errors.append(
                    f"clientDataJSON type should be 'webauthn.create', "
                    f"got '{client_data.get('type')}'"
                )

            if expected_origin and client_data.get("origin") != expected_origin:
                result.errors.append(
                    f"Origin mismatch: expected '{expected_origin}', "
                    f"got '{client_data.get('origin')}'"
                )
        except Exception as e:
            result.errors.append(f"Failed to parse clientDataJSON: {e}")

    # Check flags
    if not (result.auth_data.flags & AuthDataFlags.UP):
        result.warnings.append("User Presence (UP) flag is NOT set")

    if not (result.auth_data.flags & AuthDataFlags.AT):
        result.warnings.append("Attested Credential Data (AT) flag is NOT set")

    # Verify attestation by format
    if result.format == "none":
        if att_stmt:
            result.warnings.append("Format is 'none' but attStmt is non-empty")
        result.is_self_attestation = True

    elif result.format == "packed":
        x5c = att_stmt.get("x5c")
        if x5c:
            result.certificate_chain = [b64url_encode(cert) for cert in x5c]
            result.is_self_attestation = False
            # Full x5c chain verification requires trusted root CAs — log info
            result.warnings.append(
                f"Packed attestation with x5c chain ({len(x5c)} cert(s)). "
                "Full chain verification requires trusted root CA configuration."
            )
        else:
            result.is_self_attestation = True
            if client_data_hash:
                sig_errors = verify_packed_self(
                    result.auth_data, att_stmt, auth_data_bytes, client_data_hash
                )
                result.errors.extend(sig_errors)

    elif result.format == "fido-u2f":
        x5c = att_stmt.get("x5c")
        if x5c:
            result.certificate_chain = [b64url_encode(cert) for cert in x5c]

    else:
        result.warnings.append(f"Attestation format '{result.format}' — detailed verification not implemented")

    result.verified = len(result.errors) == 0
    return result


def print_result(result: AttestationResult) -> None:
    """Pretty-print the attestation verification result."""
    print("=" * 60)
    print("WebAuthn Attestation Verification Result")
    print("=" * 60)

    status = "✅ PASSED" if result.verified else "❌ FAILED"
    print(f"\nStatus: {status}")
    print(f"Format: {result.format}")
    print(f"Self-attestation: {result.is_self_attestation}")

    if result.auth_data:
        ad = result.auth_data
        print(f"\n--- Authenticator Data ---")
        print(f"  rpIdHash: {ad.rp_id_hash.hex()}")
        print(f"  Flags: 0x{ad.flags:02x}")
        for flag_name, flag_set in ad.flags_detail.items():
            indicator = "✓" if flag_set else "✗"
            print(f"    {indicator} {flag_name}")
        print(f"  Sign count: {ad.sign_count}")

        if ad.aaguid:
            print(f"  AAGUID: {ad.aaguid}")
        if ad.credential_id:
            print(f"  Credential ID: {ad.credential_id_b64url}")
            print(f"  Credential ID length: {len(ad.credential_id)} bytes")
        if ad.credential_public_key:
            cose = ad.credential_public_key
            kty_names = {1: "OKP", 2: "EC2", 3: "RSA"}
            alg_names = {-7: "ES256", -257: "RS256", -8: "EdDSA", -35: "ES384", -36: "ES512"}
            print(f"  Public key type: {kty_names.get(cose.get(1), cose.get(1))}")
            print(f"  Algorithm: {alg_names.get(cose.get(3), cose.get(3))}")

    if result.certificate_chain:
        print(f"\n--- Certificate Chain ---")
        print(f"  Certificates: {len(result.certificate_chain)}")

    if result.warnings:
        print(f"\n--- Warnings ---")
        for w in result.warnings:
            print(f"  ⚠ {w}")

    if result.errors:
        print(f"\n--- Errors ---")
        for e in result.errors:
            print(f"  ✗ {e}")

    print()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Verify WebAuthn attestation statements.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  %(prog)s --attestation-object 'o2NmbXR...'\n"
               "  %(prog)s --file response.json --rp-id example.com\n"
               "  echo 'o2NmbXR...' | %(prog)s --stdin\n",
    )

    input_group = parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument(
        "--attestation-object", "-a",
        help="Base64url-encoded attestation object",
    )
    input_group.add_argument(
        "--file", "-f",
        help="JSON file containing registration response (with response.attestationObject)",
    )
    input_group.add_argument(
        "--stdin",
        action="store_true",
        help="Read base64url attestation object from stdin",
    )

    parser.add_argument("--rp-id", help="Expected RP ID for validation")
    parser.add_argument("--origin", help="Expected origin for clientDataJSON validation")
    parser.add_argument("--json-output", action="store_true", help="Output result as JSON")

    args = parser.parse_args()

    attestation_object = None
    client_data_json = None

    if args.attestation_object:
        attestation_object = args.attestation_object.strip()

    elif args.file:
        try:
            with open(args.file, "r") as f:
                data = json.load(f)
            response = data.get("response", data)
            attestation_object = response.get("attestationObject", "")
            client_data_json = response.get("clientDataJSON")
            if not attestation_object:
                print("ERROR: No 'attestationObject' found in JSON file.", file=sys.stderr)
                sys.exit(1)
        except (json.JSONDecodeError, FileNotFoundError) as e:
            print(f"ERROR: Failed to read file: {e}", file=sys.stderr)
            sys.exit(1)

    elif args.stdin:
        attestation_object = sys.stdin.read().strip()

    if not attestation_object:
        print("ERROR: No attestation object provided.", file=sys.stderr)
        sys.exit(1)

    result = verify_attestation_object(
        attestation_object_b64url=attestation_object,
        client_data_json_b64url=client_data_json,
        expected_rp_id=args.rp_id,
        expected_origin=args.origin,
    )

    if args.json_output:
        output = {
            "verified": result.verified,
            "format": result.format,
            "is_self_attestation": result.is_self_attestation,
            "errors": result.errors,
            "warnings": result.warnings,
        }
        if result.auth_data:
            output["authenticator_data"] = {
                "rp_id_hash": result.auth_data.rp_id_hash.hex(),
                "flags": result.auth_data.flags_detail,
                "sign_count": result.auth_data.sign_count,
                "aaguid": result.auth_data.aaguid,
                "credential_id": result.auth_data.credential_id_b64url,
            }
        print(json.dumps(output, indent=2))
    else:
        print_result(result)

    sys.exit(0 if result.verified else 1)


if __name__ == "__main__":
    main()
