# QA Review: dns-patterns

**Skill path:** `~/skillforge/infrastructure/dns-patterns/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-18

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter: `name` | ✅ Pass | `dns-patterns` |
| YAML frontmatter: `description` | ✅ Pass | Multi-line, detailed |
| Positive triggers | ✅ Pass | 15+ positive triggers (configure DNS records, DNSSEC, SPF/DKIM/DMARC, dig/nslookup/host, DNS load balancing, GeoDNS, split-horizon, DoH/DoT, private DNS zones, DNS propagation) |
| Negative triggers | ✅ Pass | 3 explicit negatives (domain registration, web server config, SSL/TLS cert setup) |
| Body ≤ 500 lines | ✅ Pass | 494 lines — just under the limit |
| Imperative voice | ✅ Pass | Commands and rules stated directly ("Use high TTLs", "CNAME cannot coexist", "Lower TTL 24–48h before migration") |
| Examples with I/O | ✅ Pass | dig examples show expected output (e.g., `dig +short` → `93.184.216.34`, `dig -x 8.8.8.8 +short` → `dns.google.`) |
| References linked from SKILL.md | ✅ Pass | All 3 reference files linked in table at bottom |
| Scripts linked from SKILL.md | ✅ Pass | All 3 scripts linked with usage in table at bottom |
| Assets linked from SKILL.md | ✅ Pass | All 3 asset files linked with descriptions |
| All linked files exist on disk | ✅ Pass | All 9 referenced files verified present |

**Structure verdict:** Excellent. Clean organization, all structural requirements met.

---

## B. Content Check

### DNS Record Syntax — Verified ✅
- A, AAAA, CNAME, MX, TXT, SRV, NS, SOA, CAA, PTR, NAPTR record formats all correct.
- CNAME-at-apex prohibition correctly noted (RFC 1034).
- MX-must-not-point-to-CNAME correctly noted (RFC 2181).
- SOA serial format (YYYYMMDDNN) and field ordering correct.
- SRV format `_service._proto.name TTL IN SRV priority weight port target` correct.
- TXT 255-char-per-string limit correctly noted.

### DNSSEC Details — Verified ✅
- ZSK/KSK roles and rotation frequencies accurate (ZSK: quarterly, KSK: 1–2 years).
- Chain of trust description (Root → TLD DS → domain DNSKEY → RRSIG) correct per RFC 4033/4034/4035.
- Pre-Publish ZSK rollover method accurately described.
- Double-DS KSK rollover method accurately described.
- CDS/CDNSKEY (RFC 8078) correctly referenced.
- Advanced reference adds algorithm selection (ECDSA P-256 / Ed25519 preferred) — correct for 2024+.
- NSEC/NSEC3 for authenticated denial mentioned.

### SPF/DKIM/DMARC Specs — Verified ✅
- **SPF:** `v=spf1` syntax correct. 10 DNS lookup limit per RFC 7208 accurately described. Mechanisms correctly categorized (ip4/ip6/all don't count; include/a/mx/ptr/exists/redirect do count). Flattening technique and macros (RFC 7208) explained.
- **DKIM:** `v=DKIM1; k=rsa; p=<key>` at `selector._domainkey.domain` format correct per RFC 6376. Ed25519 support mentioned. Key rotation strategy sound.
- **DMARC:** `v=DMARC1; p=<policy>` at `_dmarc.domain` format correct per RFC 7489. All tags (v, p, sp, pct, rua, ruf, adkim, aspf, ri, fo) documented with correct defaults. Policy progression (none → quarantine → reject) correctly described.

### dig Command Syntax — Verified ✅
- `dig +short`, `dig +trace`, `dig @server`, `dig +dnssec`, `dig +cd`, `dig -x` all correct.
- `+norecurse` for bypassing cache at authoritative server correct.
- Response flags (qr, rd, ra, ad, aa, tc, cd) and status codes (NOERROR, NXDOMAIN, SERVFAIL, REFUSED, FORMERR) accurate.

### Missing Gotchas — Minor ⚠️
1. **DANE/TLSA records** — Not covered in SKILL.md or references. DANE (RFC 6698) ties TLS certificates to DNS via TLSA records and is relevant to DNS-aware email security (especially with MTA-STS). Minor gap.
2. **HTTPS/SVCB records** (RFC 9460) — Newer record types for service binding. Not mentioned. Very minor since they're still emerging.
3. **DNS rebinding attacks** — Not mentioned in troubleshooting. Minor security gap.

### Examples Correctness — ✅
- All zone file examples use correct syntax with trailing dots on FQDNs.
- IP addresses used are valid examples (93.184.216.34 = example.com, 8.8.8.8 = Google DNS).
- Route 53 JSON examples have correct structure.
- BIND config syntax (views, dnssec-policy) is valid.
- Python script is functional with proper argparse, subprocess, and openssl usage.
- Shell scripts use proper `set -euo pipefail`, getopts, and dig invocations.

---

## C. Trigger Check

### Description Strength — ✅ Strong
The description is detailed and action-oriented. It covers:
- 11 specific record types by name
- 5 distinct use cases (DNSSEC, email auth, debugging, load balancing, private zones)
- Clear technology mentions (dig/nslookup/host, DoH/DoT, GeoDNS, split-horizon)

### False Trigger Risk — Low ✅
- Negative triggers are specific and appropriate (domain registration, nginx/apache, certbot).
- The description avoids overly broad terms — focuses on DNS-specific operations.
- Potential edge case: "DNS" mentioned in context of SSL/TLS (e.g., DNS-01 ACME challenges) could trigger this skill when the certbot skill is more appropriate. Mitigation: negative trigger for SSL/TLS cert setup is present.

### Missing Negative Triggers — Minor ⚠️
- Could add: "NOT for CDN configuration" (Cloudflare CDN features beyond DNS are a different concern)
- Could add: "NOT for network routing/BGP" (anycast DNS mentions BGP but the skill shouldn't trigger for pure routing questions)

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All DNS record formats, RFC references, DNSSEC procedures, SPF/DKIM/DMARC syntax verified correct against authoritative sources. No factual errors found. |
| **Completeness** | 5 | Exceptional breadth: 11 record types, DNSSEC key management, email authentication (SPF/DKIM/DMARC/BIMI/MTA-STS/TLS-RPT), debugging tools, service discovery, split-horizon, GeoDNS, DoH/DoT, private zones, DNS failover, caching/TTL strategy, provider-specific guides (Route 53, Cloudflare, GCP, Google Workspace, M365, SES), common mistakes. 3 reference docs (2000+ lines), 3 scripts, 3 asset files. Only minor gaps (DANE/TLSA, HTTPS/SVCB records). |
| **Actionability** | 5 | Copy-paste zone file template, ready-to-run audit/propagation scripts, Python email DNS generator, dig cheatsheet, provider-specific record templates. Every section has concrete commands or record examples. Troubleshooting has step-by-step flowcharts. |
| **Trigger Quality** | 4 | Strong positive triggers with specific record types and tools. Good negative triggers. Minor risk of overlap with certbot/CDN skills. Could benefit from 1–2 additional negative triggers. |

**Overall Score: 4.75** (average of 5 + 5 + 5 + 4)

---

## E. Issues

No GitHub issues required. Overall score (4.75) ≥ 4.0 and no dimension ≤ 2.

---

## F. Recommendations (non-blocking)

1. **Add DANE/TLSA coverage** — Even a brief mention in the email reference with a forward pointer would close the gap.
2. **Add HTTPS/SVCB record type** — RFC 9460 is increasingly relevant for modern web services.
3. **Add 1–2 negative triggers** — "NOT for CDN configuration beyond DNS" and "NOT for network routing/BGP" to reduce false triggers.
4. **SKILL.md is at 494/500 lines** — Very tight on the limit. If any content is added to the main file, consider moving material to references.

---

## Summary

**Result: PASS** ✅

This is an exemplary skill. Comprehensive, accurate, and highly actionable with excellent supporting materials (scripts, templates, cheatsheets). The DNS patterns skill covers the full spectrum from basic record management through advanced DNSSEC operations, email authentication, and cloud provider integrations. Minor suggestions are cosmetic improvements only.
