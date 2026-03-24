#!/usr/bin/env python3
"""
email-dns-setup.py — Email DNS Record Generator

Generates and validates SPF, DKIM, and DMARC DNS records for a domain.
Supports common email providers and custom configurations.

Usage:
    ./email-dns-setup.py <domain>
    ./email-dns-setup.py example.com
    ./email-dns-setup.py example.com --provider google
    ./email-dns-setup.py example.com --provider microsoft365
    ./email-dns-setup.py example.com --provider aws-ses
    ./email-dns-setup.py example.com --spf-extra "include:sendgrid.net"
    ./email-dns-setup.py example.com --dmarc-policy quarantine
    ./email-dns-setup.py example.com --validate  # Validate existing records
    ./email-dns-setup.py example.com --generate-dkim  # Generate DKIM keys
    ./email-dns-setup.py example.com --full  # Full setup with all records

Requirements: Python 3.7+, optional: dnspython (pip install dnspython)
"""

import argparse
import subprocess
import sys
import json
import re
import os
import base64
from typing import Optional

# Provider configurations
PROVIDERS = {
    "google": {
        "name": "Google Workspace",
        "spf_include": "include:_spf.google.com",
        "dkim_selector": "google",
        "dkim_note": "Generate DKIM key in Google Admin Console → Apps → Gmail → Authenticate email",
        "mx_records": [
            (1, "ASPMX.L.GOOGLE.COM."),
            (5, "ALT1.ASPMX.L.GOOGLE.COM."),
            (5, "ALT2.ASPMX.L.GOOGLE.COM."),
            (10, "ALT3.ASPMX.L.GOOGLE.COM."),
            (10, "ALT4.ASPMX.L.GOOGLE.COM."),
        ],
    },
    "microsoft365": {
        "name": "Microsoft 365",
        "spf_include": "include:spf.protection.outlook.com",
        "dkim_selector": "selector1",
        "dkim_note": "Enable DKIM in Microsoft 365 Defender → Email authentication → DKIM",
        "dkim_cname": True,
        "mx_records": [
            (0, "{domain_dashed}.mail.protection.outlook.com."),
        ],
    },
    "aws-ses": {
        "name": "AWS SES",
        "spf_include": "include:amazonses.com",
        "dkim_selector": None,
        "dkim_note": "DKIM is configured via 3 CNAME records generated in AWS SES console",
        "mx_records": [],
    },
    "fastmail": {
        "name": "Fastmail",
        "spf_include": "include:spf.messagingengine.com",
        "dkim_selector": "fm1",
        "dkim_note": "DKIM keys are auto-configured via CNAME records",
        "mx_records": [
            (10, "in1-smtp.messagingengine.com."),
            (20, "in2-smtp.messagingengine.com."),
        ],
    },
    "zoho": {
        "name": "Zoho Mail",
        "spf_include": "include:zoho.com",
        "dkim_selector": "zmail",
        "dkim_note": "Generate DKIM in Zoho Admin → Mail → Domain → Email Authentication",
        "mx_records": [
            (10, "mx.zoho.com."),
            (20, "mx2.zoho.com."),
            (50, "mx3.zoho.com."),
        ],
    },
}


def run_dig(query_type: str, name: str) -> Optional[str]:
    """Run a dig query and return the result."""
    try:
        result = subprocess.run(
            ["dig", "+short", "+time=5", "+tries=2", name, query_type],
            capture_output=True, text=True, timeout=15,
        )
        return result.stdout.strip() if result.returncode == 0 else None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def count_spf_lookups(spf_record: str, depth: int = 0) -> int:
    """Count DNS lookups in an SPF record (recursive)."""
    if depth > 10:
        return 0
    count = 0
    lookup_mechanisms = ["include:", "a:", "mx:", "ptr:", "exists:", "redirect="]
    bare_mechanisms = ["a ", "mx ", "ptr "]

    for mech in lookup_mechanisms:
        count += spf_record.lower().count(mech)
    for mech in bare_mechanisms:
        if mech.strip() in spf_record.lower().split():
            count += 1

    return count


def generate_spf(domain: str, provider: Optional[str] = None,
                 extra_includes: list = None, ip4s: list = None,
                 ip6s: list = None, policy: str = "-all") -> dict:
    """Generate SPF record."""
    parts = ["v=spf1"]

    if provider and provider in PROVIDERS:
        parts.append(PROVIDERS[provider]["spf_include"])

    if extra_includes:
        for inc in extra_includes:
            if not inc.startswith("include:") and not inc.startswith("ip4:") and not inc.startswith("ip6:"):
                inc = f"include:{inc}"
            parts.append(inc)

    if ip4s:
        for ip in ip4s:
            parts.append(f"ip4:{ip}")

    if ip6s:
        for ip in ip6s:
            parts.append(f"ip6:{ip}")

    parts.append(policy)
    record = " ".join(parts)

    lookups = count_spf_lookups(record)

    result = {
        "type": "TXT",
        "name": domain,
        "value": record,
        "dns_lookups": lookups,
        "valid": lookups <= 10,
    }

    if lookups > 10:
        result["warning"] = f"SPF exceeds 10 DNS lookup limit ({lookups} lookups). Consider flattening or using subdomains."
    elif lookups > 7:
        result["warning"] = f"SPF uses {lookups}/10 lookups. Be careful adding more includes."

    if len(record) > 255:
        result["note"] = "Record exceeds 255 chars. DNS provider must split into multiple strings."

    return result


def generate_dmarc(domain: str, policy: str = "none",
                   subdomain_policy: Optional[str] = None,
                   rua: Optional[str] = None,
                   ruf: Optional[str] = None,
                   pct: int = 100,
                   alignment_dkim: str = "r",
                   alignment_spf: str = "r") -> dict:
    """Generate DMARC record."""
    parts = [f"v=DMARC1; p={policy}"]

    if subdomain_policy:
        parts.append(f"sp={subdomain_policy}")

    if pct != 100:
        parts.append(f"pct={pct}")

    if rua:
        if not rua.startswith("mailto:"):
            rua = f"mailto:{rua}"
        parts.append(f"rua={rua}")
    else:
        parts.append(f"rua=mailto:dmarc@{domain}")

    if ruf:
        if not ruf.startswith("mailto:"):
            ruf = f"mailto:{ruf}"
        parts.append(f"ruf={ruf}")

    if alignment_dkim != "r":
        parts.append(f"adkim={alignment_dkim}")

    if alignment_spf != "r":
        parts.append(f"aspf={alignment_spf}")

    record = "; ".join(parts)

    return {
        "type": "TXT",
        "name": f"_dmarc.{domain}",
        "value": record,
        "valid": True,
    }


def generate_dkim_keys(domain: str, selector: str = "mail",
                       key_size: int = 2048) -> dict:
    """Generate DKIM key pair using openssl."""
    try:
        # Generate private key
        priv_result = subprocess.run(
            ["openssl", "genrsa", str(key_size)],
            capture_output=True, text=True, timeout=30,
        )
        if priv_result.returncode != 0:
            return {"error": "Failed to generate private key"}

        private_key = priv_result.stdout

        # Extract public key
        pub_result = subprocess.run(
            ["openssl", "rsa", "-pubout"],
            input=private_key,
            capture_output=True, text=True, timeout=10,
        )
        if pub_result.returncode != 0:
            return {"error": "Failed to extract public key"}

        public_key = pub_result.stdout

        # Extract just the base64 content
        pub_b64 = "".join(
            line for line in public_key.strip().split("\n")
            if not line.startswith("-----")
        )

        dns_record = f"v=DKIM1; k=rsa; p={pub_b64}"

        return {
            "type": "TXT",
            "name": f"{selector}._domainkey.{domain}",
            "value": dns_record,
            "private_key": private_key,
            "public_key": public_key,
            "selector": selector,
            "key_size": key_size,
            "valid": True,
            "note": f"Save private key securely. Configure mail server to sign with selector '{selector}'.",
        }
    except FileNotFoundError:
        return {"error": "openssl not found. Install OpenSSL to generate DKIM keys."}
    except subprocess.TimeoutExpired:
        return {"error": "Key generation timed out."}


def generate_mta_sts(domain: str, mode: str = "testing",
                     mx_hosts: list = None) -> dict:
    """Generate MTA-STS DNS record and policy file."""
    from datetime import datetime
    policy_id = datetime.now().strftime("%Y%m%dT%H%M%S")

    dns_record = {
        "type": "TXT",
        "name": f"_mta-sts.{domain}",
        "value": f"v=STSv1; id={policy_id}",
        "valid": True,
    }

    mx_lines = []
    if mx_hosts:
        for mx in mx_hosts:
            mx_lines.append(f"mx: {mx}")
    else:
        mx_lines.append(f"mx: *.{domain}")

    policy_file = "version: STSv1\n"
    policy_file += f"mode: {mode}\n"
    for line in mx_lines:
        policy_file += f"{line}\n"
    policy_file += "max_age: 604800\n"

    dns_record["policy_file"] = policy_file
    dns_record["policy_url"] = f"https://mta-sts.{domain}/.well-known/mta-sts.txt"
    dns_record["note"] = f"Host policy file at {dns_record['policy_url']}"

    return dns_record


def generate_tls_rpt(domain: str, email: Optional[str] = None) -> dict:
    """Generate TLS-RPT DNS record."""
    report_email = email or f"tls-reports@{domain}"
    return {
        "type": "TXT",
        "name": f"_smtp._tls.{domain}",
        "value": f"v=TLSRPTv1; rua=mailto:{report_email}",
        "valid": True,
    }


def generate_bimi(domain: str, logo_url: str,
                  vmc_url: Optional[str] = None) -> dict:
    """Generate BIMI DNS record."""
    value = f"v=BIMI1; l={logo_url};"
    if vmc_url:
        value += f" a={vmc_url};"

    return {
        "type": "TXT",
        "name": f"default._bimi.{domain}",
        "value": value,
        "valid": True,
        "note": "Requires DMARC p=quarantine or p=reject. Gmail requires VMC certificate.",
    }


def validate_existing(domain: str) -> dict:
    """Validate existing email DNS records for a domain."""
    results = {"domain": domain, "checks": []}

    # Check MX
    mx = run_dig("MX", domain)
    if mx:
        results["checks"].append({"record": "MX", "status": "PASS", "value": mx})
    else:
        results["checks"].append({"record": "MX", "status": "FAIL", "detail": "No MX records found"})

    # Check SPF
    txt = run_dig("TXT", domain)
    spf = None
    if txt:
        for line in txt.split("\n"):
            if "v=spf1" in line.lower():
                spf = line
                break

    if spf:
        lookups = count_spf_lookups(spf)
        status = "PASS" if lookups <= 10 else "FAIL"
        detail = f"{lookups}/10 DNS lookups"
        if lookups > 10:
            detail += " — EXCEEDS LIMIT"
        results["checks"].append({"record": "SPF", "status": status, "value": spf, "detail": detail})
    else:
        results["checks"].append({"record": "SPF", "status": "FAIL", "detail": "No SPF record found"})

    # Check DMARC
    dmarc = run_dig("TXT", f"_dmarc.{domain}")
    if dmarc and "v=dmarc1" in dmarc.lower():
        policy = "unknown"
        for tag in dmarc.replace('"', '').split(";"):
            tag = tag.strip()
            if tag.startswith("p="):
                policy = tag[2:]
        status = "PASS" if policy in ("reject", "quarantine") else "WARN"
        results["checks"].append({
            "record": "DMARC", "status": status,
            "value": dmarc, "detail": f"policy={policy}",
        })
    else:
        results["checks"].append({"record": "DMARC", "status": "FAIL", "detail": "No DMARC record found"})

    # Check common DKIM selectors
    dkim_found = False
    for sel in ["google", "selector1", "selector2", "default", "dkim", "s1", "s2", "k1", "mail"]:
        dkim = run_dig("TXT", f"{sel}._domainkey.{domain}")
        if dkim and "v=dkim1" in dkim.lower():
            results["checks"].append({"record": f"DKIM ({sel})", "status": "PASS", "value": dkim[:80] + "..."})
            dkim_found = True
    if not dkim_found:
        results["checks"].append({"record": "DKIM", "status": "WARN", "detail": "No DKIM found for common selectors"})

    # Check MTA-STS
    mta_sts = run_dig("TXT", f"_mta-sts.{domain}")
    if mta_sts and "v=stsv1" in mta_sts.lower():
        results["checks"].append({"record": "MTA-STS", "status": "PASS", "value": mta_sts})
    else:
        results["checks"].append({"record": "MTA-STS", "status": "INFO", "detail": "Not configured (optional)"})

    # Check TLS-RPT
    tls_rpt = run_dig("TXT", f"_smtp._tls.{domain}")
    if tls_rpt and "v=tlsrptv1" in tls_rpt.lower():
        results["checks"].append({"record": "TLS-RPT", "status": "PASS", "value": tls_rpt})
    else:
        results["checks"].append({"record": "TLS-RPT", "status": "INFO", "detail": "Not configured (optional)"})

    return results


def print_record(record: dict, label: str = ""):
    """Pretty-print a DNS record."""
    if "error" in record:
        print(f"  ❌ Error: {record['error']}")
        return

    print(f"  {'─' * 60}")
    if label:
        print(f"  📌 {label}")
    print(f"  Type: {record.get('type', 'TXT')}")
    print(f"  Name: {record['name']}")

    value = record['value']
    if len(value) > 100:
        # Split long records for readability
        print(f"  Value:")
        for i in range(0, len(value), 80):
            print(f"    {value[i:i+80]}")
    else:
        print(f"  Value: {value}")

    if "dns_lookups" in record:
        status = "✓" if record.get("valid", True) else "✗"
        print(f"  DNS Lookups: {record['dns_lookups']}/10 {status}")

    if "warning" in record:
        print(f"  ⚠️  {record['warning']}")
    if "note" in record:
        print(f"  📝 {record['note']}")


def print_validation(results: dict):
    """Pretty-print validation results."""
    print(f"\n{'═' * 60}")
    print(f"  Email DNS Validation: {results['domain']}")
    print(f"{'═' * 60}\n")

    for check in results["checks"]:
        icon = {"PASS": "✅", "FAIL": "❌", "WARN": "⚠️", "INFO": "ℹ️"}.get(check["status"], "?")
        print(f"  {icon} {check['record']}: {check['status']}")
        if "value" in check:
            val = check["value"].replace("\n", " ")[:80]
            print(f"     {val}")
        if "detail" in check:
            print(f"     {check['detail']}")
        print()


def main():
    parser = argparse.ArgumentParser(
        description="Generate and validate email DNS records (SPF, DKIM, DMARC)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("domain", help="Domain name")
    parser.add_argument("--provider", choices=list(PROVIDERS.keys()),
                        help="Email provider preset")
    parser.add_argument("--spf-extra", nargs="*", default=[],
                        help="Additional SPF includes (e.g., sendgrid.net)")
    parser.add_argument("--spf-ip4", nargs="*", default=[],
                        help="Additional IPv4 addresses for SPF")
    parser.add_argument("--spf-policy", default="-all",
                        choices=["-all", "~all", "?all"],
                        help="SPF policy (default: -all)")
    parser.add_argument("--dmarc-policy", default="none",
                        choices=["none", "quarantine", "reject"],
                        help="DMARC policy (default: none)")
    parser.add_argument("--dmarc-rua", help="DMARC aggregate report email")
    parser.add_argument("--dmarc-pct", type=int, default=100,
                        help="DMARC percentage (default: 100)")
    parser.add_argument("--generate-dkim", action="store_true",
                        help="Generate DKIM key pair")
    parser.add_argument("--dkim-selector", default="mail",
                        help="DKIM selector name (default: mail)")
    parser.add_argument("--dkim-bits", type=int, default=2048,
                        help="DKIM key size in bits (default: 2048)")
    parser.add_argument("--validate", action="store_true",
                        help="Validate existing records (requires dig)")
    parser.add_argument("--full", action="store_true",
                        help="Generate all records including MTA-STS, TLS-RPT, BIMI")
    parser.add_argument("--json", action="store_true",
                        help="Output as JSON")

    args = parser.parse_args()
    domain = args.domain.rstrip(".")

    if args.validate:
        results = validate_existing(domain)
        if args.json:
            print(json.dumps(results, indent=2))
        else:
            print_validation(results)
        return

    records = []

    # Generate SPF
    spf = generate_spf(
        domain, provider=args.provider,
        extra_includes=args.spf_extra,
        ip4s=args.spf_ip4,
        policy=args.spf_policy,
    )
    records.append(("SPF Record", spf))

    # Generate DMARC
    dmarc = generate_dmarc(
        domain, policy=args.dmarc_policy,
        rua=args.dmarc_rua,
        pct=args.dmarc_pct,
    )
    records.append(("DMARC Record", dmarc))

    # Generate DKIM
    if args.generate_dkim:
        selector = args.dkim_selector
        if args.provider and PROVIDERS[args.provider].get("dkim_selector"):
            selector = PROVIDERS[args.provider]["dkim_selector"]
        dkim = generate_dkim_keys(domain, selector=selector, key_size=args.dkim_bits)
        records.append(("DKIM Record", dkim))

    # Provider-specific info
    if args.provider and args.provider in PROVIDERS:
        prov = PROVIDERS[args.provider]
        if prov.get("mx_records"):
            for priority, host in prov["mx_records"]:
                host_resolved = host.replace("{domain_dashed}", domain.replace(".", "-"))
                mx_rec = {
                    "type": "MX",
                    "name": domain,
                    "value": f"{priority} {host_resolved}",
                    "valid": True,
                }
                records.append((f"MX Record (priority {priority})", mx_rec))

        if prov.get("dkim_note"):
            records.append(("DKIM Note", {
                "type": "INFO",
                "name": f"{prov.get('dkim_selector', 'selector')}._domainkey.{domain}",
                "value": prov["dkim_note"],
                "valid": True,
            }))

    # Full setup extras
    if args.full:
        mta_sts = generate_mta_sts(domain)
        records.append(("MTA-STS Record", mta_sts))

        tls_rpt = generate_tls_rpt(domain)
        records.append(("TLS-RPT Record", tls_rpt))

    # Output
    if args.json:
        output = {label: rec for label, rec in records}
        # Remove private key from JSON output for safety
        for label, rec in output.items():
            if "private_key" in rec:
                rec["private_key"] = "(hidden — saved to file)"
        print(json.dumps(output, indent=2))
    else:
        print(f"\n{'═' * 60}")
        print(f"  Email DNS Records for: {domain}")
        if args.provider:
            print(f"  Provider: {PROVIDERS[args.provider]['name']}")
        print(f"{'═' * 60}")

        for label, record in records:
            print_record(record, label)

        # Save DKIM private key if generated
        if args.generate_dkim:
            for label, record in records:
                if "private_key" in record:
                    key_file = f"{domain}-dkim-private.pem"
                    with open(key_file, "w") as f:
                        f.write(record["private_key"])
                    os.chmod(key_file, 0o600)
                    print(f"\n  🔑 Private key saved to: {key_file}")
                    print(f"     Permissions set to 600 (owner read/write only)")

        print(f"\n{'─' * 60}")
        print("  Next steps:")
        print("  1. Add these DNS records at your DNS provider")
        print("  2. Wait for propagation (check with: dig +short TXT <record>)")
        if args.dmarc_policy == "none":
            print("  3. Monitor DMARC reports, then progress to p=quarantine → p=reject")
        print(f"{'═' * 60}\n")


if __name__ == "__main__":
    main()
