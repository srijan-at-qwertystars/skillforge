# Email DNS Deep Dive

## Table of Contents

- [SPF (Sender Policy Framework)](#spf-sender-policy-framework)
  - [SPF Syntax Reference](#spf-syntax-reference)
  - [The 10 DNS Lookup Limit](#the-10-dns-lookup-limit)
  - [SPF Flattening](#spf-flattening)
  - [SPF Macros](#spf-macros)
  - [Common SPF Mistakes](#common-spf-mistakes)
- [DKIM (DomainKeys Identified Mail)](#dkim-domainkeys-identified-mail)
  - [Key Generation](#key-generation)
  - [Key Rotation Strategy](#key-rotation-strategy)
  - [DKIM Record Syntax](#dkim-record-syntax)
- [DMARC (Domain-based Message Authentication)](#dmarc-domain-based-message-authentication)
  - [Policy Progression](#policy-progression)
  - [DMARC Tags Reference](#dmarc-tags-reference)
  - [Alignment](#alignment)
  - [Reporting](#reporting)
- [BIMI (Brand Indicators for Message Identification)](#bimi-brand-indicators-for-message-identification)
- [MTA-STS (SMTP MTA Strict Transport Security)](#mta-sts-smtp-mta-strict-transport-security)
- [TLS-RPT (SMTP TLS Reporting)](#tls-rpt-smtp-tls-reporting)
- [Common Email Deliverability DNS Issues](#common-email-deliverability-dns-issues)
- [Provider-Specific Setup](#provider-specific-setup)
  - [Google Workspace](#google-workspace)
  - [Microsoft 365](#microsoft-365)
  - [AWS SES](#aws-ses)
- [Complete Email DNS Checklist](#complete-email-dns-checklist)

---

## SPF (Sender Policy Framework)

### SPF Syntax Reference

```
v=spf1 [mechanisms] [qualifier]all

Qualifiers:
  +  Pass (default)     →  +ip4:1.2.3.4  (authorize)
  -  Fail (hard)        →  -all           (reject unauthorized)
  ~  SoftFail           →  ~all           (accept but mark)
  ?  Neutral            →  ?all           (no policy)
```

**Mechanisms (each counts toward 10-lookup limit unless noted):**

| Mechanism | DNS Lookups | Description |
|-----------|-------------|-------------|
| `ip4:x.x.x.x/cidr` | 0 | Match IPv4 address/range |
| `ip6:x::x/cidr` | 0 | Match IPv6 address/range |
| `a` | 1 | Match domain's A/AAAA records |
| `a:other.com` | 1 | Match other domain's A/AAAA |
| `mx` | 1 + (1 per MX) | Match domain's MX hosts |
| `mx:other.com` | 1 + (1 per MX) | Match other domain's MX |
| `include:_spf.x.com` | 1 + (nested) | Include another SPF record |
| `exists:x.com` | 1 | True if domain has any A record |
| `ptr` | 1 | Reverse DNS match (**deprecated, avoid**) |
| `redirect=x.com` | 1 | Replace entire SPF with another |
| `all` | 0 | Match everything (catch-all) |

### The 10 DNS Lookup Limit

SPF evaluation allows a maximum of **10 DNS-querying mechanisms** per evaluation. Exceeding this causes **PermError**, which makes DMARC treat SPF as a failure.

**What counts:** `include`, `a`, `mx`, `ptr`, `exists`, `redirect`
**What doesn't count:** `ip4`, `ip6`, `all`

```
; This SPF has 11 lookups — WILL FAIL with PermError
v=spf1 include:_spf.google.com        ; 1 (+2 nested = 3 total)
       include:spf.protection.outlook.com ; 1 (+1 nested = 2 total)
       include:sendgrid.net             ; 1 (+1 nested = 2 total)
       include:spf.mandrillapp.com      ; 1 (+1 nested = 2 total)
       include:mail.zendesk.com         ; 1 (+1 nested = 2 total)
       a mx                             ; 2
       -all
; Total: 3+2+2+2+2+2 = 13 lookups — PermError!
```

**How to count lookups:**
```bash
# Use an online tool or script to count
# Each 'include' triggers a recursive lookup of the included SPF record
# Nested includes within those records also count

# Quick check with dig
dig +short TXT _spf.google.com
# "v=spf1 include:_netblocks.google.com include:_netblocks2.google.com
#         include:_netblocks3.google.com ~all"
# That's 3 more lookups from the nested includes
# So include:_spf.google.com = 1 + 3 = 4 lookups
```

### SPF Flattening

Replace `include` mechanisms with resolved IP addresses to reduce lookup count:

```
; Before flattening (4 lookups for Google alone)
v=spf1 include:_spf.google.com -all

; After flattening (0 lookups for Google IPs)
v=spf1 ip4:35.190.247.0/24 ip4:64.233.160.0/19 ip4:66.102.0.0/20
       ip4:66.249.80.0/20 ip4:72.14.192.0/18 ip4:74.125.0.0/16
       ip4:108.177.8.0/21 ip4:173.194.0.0/16 ip4:209.85.128.0/17
       ip6:2001:4860:4000::/36 ip6:2404:6800:4000::/36
       ip6:2607:f8b0:4000::/36 ip6:2800:3f0:4000::/36
       ip6:2a00:1450:4000::/36 ip6:2c0f:fb50:4000::/36 -all
```

**Warnings:**
- Cloud provider IP ranges change — automate flattening with tools
- May exceed 255-char TXT string limit — split into multiple strings
- Maintain automation to detect IP changes

**Tools:** `spf-tools`, `dmarcian SPF surveyor`, `EasyDMARC`

### SPF Macros

SPF macros (RFC 7208) can reduce lookups using dynamic evaluation:

```
; %{i} = sender IP, %{d} = sender domain, %{s} = sender address
; Macro-based SPF that handles unlimited senders with 1 lookup:
v=spf1 exists:%{i}._spf.example.com -all

; Create A records for authorized IPs:
10.0.1.1._spf.example.com.  A  127.0.0.1
10.0.1.2._spf.example.com.  A  127.0.0.1
; Unauthorized IPs → NXDOMAIN → SPF fail
```

### Common SPF Mistakes

1. **Multiple SPF records** — Only ONE TXT record starting with `v=spf1` per domain
2. **Using `+all`** — Authorizes everyone (defeats the purpose)
3. **Forgetting `include` for third-party senders** — Causes SPF failures for marketing emails
4. **Using `ptr`** — Deprecated, unreliable, wastes a lookup
5. **Not testing after changes** — Always verify with `dig +short TXT example.com`

---

## DKIM (DomainKeys Identified Mail)

### Key Generation

```bash
# Generate 2048-bit RSA key pair
openssl genrsa -out dkim-private.pem 2048
openssl rsa -in dkim-private.pem -pubout -out dkim-public.pem

# Extract public key for DNS (remove headers and newlines)
grep -v "^-" dkim-public.pem | tr -d '\n'
# Result: MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...

# Generate Ed25519 key (shorter, modern)
openssl genpkey -algorithm Ed25519 -out dkim-ed25519-private.pem
openssl pkey -in dkim-ed25519-private.pem -pubout -out dkim-ed25519-public.pem
```

**DNS record format:**
```
; selector._domainkey.domain  TXT  "v=DKIM1; k=rsa; p=<public-key>"
selector1._domainkey.example.com. 3600 IN TXT (
    "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCg"
    "KCAQEA1234567890abcdefghijklmnopqrstuvwxyz..."
)

; Ed25519 DKIM (smaller record)
selector2._domainkey.example.com. 3600 IN TXT (
    "v=DKIM1; k=ed25519; p=<44-char-base64-key>"
)
```

### Key Rotation Strategy

```
Rotation Timeline:
─────────────────────────────────────────────────
Day 1:  Generate new key pair with new selector name
Day 1:  Publish new selector DNS record (e.g., selector2024q3)
Day 2:  Wait 24-48h for DNS propagation
Day 3:  Configure mail server to sign with new selector
Day 3:  Keep old selector DNS record published
Day 30: Remove old selector DNS record
─────────────────────────────────────────────────

Recommended frequency:
- Standard domains: every 6–12 months
- High-profile/targeted domains: every 3 months
- Key size: 2048-bit RSA minimum (1024-bit is deprecated)
```

**Selector naming convention:**
```
selector2024q3._domainkey.example.com    (quarterly rotation)
s20250101._domainkey.example.com         (date-based)
google._domainkey.example.com            (provider-specific)
```

### DKIM Record Syntax

```
; Full DKIM record with all tags
selector._domainkey.example.com. TXT (
    "v=DKIM1;"       ; Version (required)
    " k=rsa;"        ; Key type: rsa (default) or ed25519
    " p=MIIBIj...;"  ; Public key (required, base64)
    " t=y;"          ; Testing mode (remove for production)
    " s=email;"      ; Service type: email or * (wildcard)
    " h=sha256;"     ; Hash algorithm (sha256 only, sha1 deprecated)
)

; To revoke a DKIM key (empty p= tag)
old-selector._domainkey.example.com. TXT "v=DKIM1; p="
```

---

## DMARC (Domain-based Message Authentication)

### Policy Progression

```
Phase 1: MONITOR (weeks 1-4)
─────────────────────────────────────────────────
_dmarc.example.com. TXT "v=DMARC1; p=none; rua=mailto:dmarc@example.com; pct=100"

→ Collect reports, identify all legitimate senders
→ Fix SPF/DKIM for each sender before proceeding

Phase 2: QUARANTINE RAMP (weeks 5-12)
─────────────────────────────────────────────────
_dmarc.example.com. TXT "v=DMARC1; p=quarantine; pct=10; rua=mailto:dmarc@example.com"
→ Increase pct: 10% → 25% → 50% → 100%
→ Monitor rua reports for false positives

Phase 3: REJECT (ongoing)
─────────────────────────────────────────────────
_dmarc.example.com. TXT "v=DMARC1; p=reject; rua=mailto:dmarc@example.com; pct=100"
→ Full enforcement — unauthenticated mail is rejected
→ Continue monitoring reports
```

### DMARC Tags Reference

| Tag | Required | Default | Description |
|-----|----------|---------|-------------|
| `v=DMARC1` | Yes | — | Version (must be first) |
| `p=` | Yes | — | Policy: `none`, `quarantine`, `reject` |
| `sp=` | No | same as `p` | Subdomain policy |
| `pct=` | No | 100 | Percentage of messages to apply policy |
| `rua=` | No | — | Aggregate report URI (mailto: or https:) |
| `ruf=` | No | — | Forensic report URI |
| `adkim=` | No | `r` | DKIM alignment: `r` (relaxed) or `s` (strict) |
| `aspf=` | No | `r` | SPF alignment: `r` (relaxed) or `s` (strict) |
| `ri=` | No | 86400 | Report interval in seconds |
| `fo=` | No | `0` | Forensic report options: `0`, `1`, `d`, `s` |

### Alignment

DMARC requires SPF or DKIM to **align** with the From: header domain:

```
Relaxed alignment (default): organizational domain must match
  From: user@mail.example.com
  SPF domain: example.com          ✓ aligned (same org domain)
  DKIM d=: example.com             ✓ aligned

Strict alignment: exact domain must match
  From: user@mail.example.com
  SPF domain: example.com          ✗ NOT aligned (strict requires exact match)
  DKIM d=: mail.example.com        ✓ aligned (exact match)
```

### Reporting

**Aggregate reports (rua):** XML reports sent daily by receiving servers

```bash
# Parse DMARC aggregate reports
# Reports are gzipped XML files sent to rua address

# Quick analysis with command line
zcat report.xml.gz | xmllint --format - | grep -E "source_ip|disposition|dkim|spf"

# Key fields in aggregate reports:
# - source_ip: IP that sent the email
# - count: number of messages
# - disposition: none/quarantine/reject
# - dkim: pass/fail
# - spf: pass/fail
```

**External reporting authorization:**
If rua/ruf points to a different domain, the receiving domain must authorize it:
```
; To allow dmarc@reports.example.net to receive reports for example.com:
example.com._report._dmarc.example.net. TXT "v=DMARC1"
```

---

## BIMI (Brand Indicators for Message Identification)

BIMI displays your brand logo in supporting email clients (Gmail, Yahoo, Apple Mail).

### Requirements

1. DMARC policy at `quarantine` or `reject` (not `none`)
2. SVG Tiny PS logo file hosted via HTTPS
3. VMC (Verified Mark Certificate) — required by Gmail, optional for others
4. Trademarked logo (required for VMC)

### DNS Record

```
; BIMI TXT record
default._bimi.example.com. 3600 IN TXT (
    "v=BIMI1;"
    " l=https://example.com/brand/logo.svg;"
    " a=https://example.com/brand/vmc.pem;"
)

; Without VMC (works in Yahoo, not Gmail)
default._bimi.example.com. 3600 IN TXT "v=BIMI1; l=https://example.com/logo.svg;"
```

### Logo Requirements

- Format: SVG Tiny 1.2 Profile (Portable/Secure)
- Square aspect ratio
- No external references (inline everything)
- Hosted over HTTPS
- File should be small (< 32KB recommended)

---

## MTA-STS (SMTP MTA Strict Transport Security)

MTA-STS tells sending servers to only deliver mail over TLS. Prevents TLS stripping attacks.

### Setup

**Step 1: Create policy file** at `https://mta-sts.example.com/.well-known/mta-sts.txt`:
```
version: STSv1
mode: enforce
mx: mail1.example.com
mx: mail2.example.com
mx: *.example.com
max_age: 604800
```

**Modes:**
- `testing` — Log failures but still deliver (start here)
- `enforce` — Reject mail that can't use TLS
- `none` — Disable MTA-STS

**Step 2: Publish DNS record:**
```
_mta-sts.example.com. 3600 IN TXT "v=STSv1; id=20250101T000000"
```

Change the `id` value whenever you update the policy file — senders use it to detect changes.

**Step 3: Serve policy via HTTPS:**
- Must be valid HTTPS (not self-signed)
- Must be at exact path `/.well-known/mta-sts.txt`
- Domain must be `mta-sts.<your-domain>`

---

## TLS-RPT (SMTP TLS Reporting)

Receive reports when sending servers encounter TLS issues delivering to your domain.

### DNS Record

```
_smtp._tls.example.com. 3600 IN TXT "v=TLSRPTv1; rua=mailto:tls-reports@example.com"

; Or report via HTTPS
_smtp._tls.example.com. 3600 IN TXT "v=TLSRPTv1; rua=https://example.com/tls-report"
```

### Report Contents

Reports (JSON) include:
- Sending MTA identity
- Receiving MX hostname
- Policy type (MTA-STS or DANE)
- Success/failure counts
- Failure details (certificate errors, connection failures)

---

## Common Email Deliverability DNS Issues

| Issue | Symptom | Fix |
|-------|---------|-----|
| Missing PTR record | Mail rejected by recipients | Set reverse DNS for mail server IP |
| PTR mismatch | Spam score increased | PTR must resolve back to mail server hostname |
| SPF too many lookups | PermError, SPF fails | Flatten SPF or use subdomains |
| Multiple SPF records | PermError | Merge into single TXT record |
| DKIM key too short | Some receivers reject | Use 2048-bit RSA minimum |
| DKIM selector missing | DKIM fails | Publish public key DNS record |
| DMARC p=none forever | No protection | Progress to quarantine/reject |
| Missing MX records | Mail bounces | Add MX records pointing to mail servers |
| MX pointing to CNAME | RFC violation, unreliable | MX must point to A/AAAA records |
| No CAA record | Any CA can issue certs | Add CAA to restrict certificate issuance |
| Missing DMARC | Easy to spoof | Add DMARC even if just p=none |

### Verification Commands

```bash
# Full email DNS audit
DOMAIN="example.com"

echo "=== MX Records ==="
dig +short MX "$DOMAIN"

echo "=== SPF ==="
dig +short TXT "$DOMAIN" | grep "v=spf1"

echo "=== DKIM (common selectors) ==="
for sel in google selector1 selector2 default dkim s1 s2 k1; do
    RESULT=$(dig +short TXT "${sel}._domainkey.${DOMAIN}" 2>/dev/null)
    [ -n "$RESULT" ] && echo "${sel}: $RESULT"
done

echo "=== DMARC ==="
dig +short TXT "_dmarc.${DOMAIN}"

echo "=== MTA-STS ==="
dig +short TXT "_mta-sts.${DOMAIN}"

echo "=== TLS-RPT ==="
dig +short TXT "_smtp._tls.${DOMAIN}"

echo "=== BIMI ==="
dig +short TXT "default._bimi.${DOMAIN}"

echo "=== PTR (for mail server) ==="
MAIL_IP=$(dig +short A "$(dig +short MX "$DOMAIN" | sort -n | head -1 | awk '{print $2}')")
dig +short -x "$MAIL_IP"
```

---

## Provider-Specific Setup

### Google Workspace

```
; MX Records (priority matters!)
example.com. 3600 IN MX 1  ASPMX.L.GOOGLE.COM.
example.com. 3600 IN MX 5  ALT1.ASPMX.L.GOOGLE.COM.
example.com. 3600 IN MX 5  ALT2.ASPMX.L.GOOGLE.COM.
example.com. 3600 IN MX 10 ALT3.ASPMX.L.GOOGLE.COM.
example.com. 3600 IN MX 10 ALT4.ASPMX.L.GOOGLE.COM.

; SPF
example.com. 3600 IN TXT "v=spf1 include:_spf.google.com -all"

; DKIM — get from Google Admin Console → Apps → Gmail → Authenticate email
; Generate key, then add:
google._domainkey.example.com. 3600 IN TXT "v=DKIM1; k=rsa; p=<key-from-admin-console>"

; DMARC
_dmarc.example.com. 3600 IN TXT "v=DMARC1; p=reject; rua=mailto:dmarc@example.com"

; Domain verification
example.com. 3600 IN TXT "google-site-verification=<verification-code>"
```

### Microsoft 365

```
; MX Record
example.com. 3600 IN MX 0 example-com.mail.protection.outlook.com.

; SPF
example.com. 3600 IN TXT "v=spf1 include:spf.protection.outlook.com -all"

; DKIM — enable in Microsoft 365 Defender → Email authentication → DKIM
; Two CNAME records required:
selector1._domainkey.example.com. CNAME selector1-example-com._domainkey.example.onmicrosoft.com.
selector2._domainkey.example.com. CNAME selector2-example-com._domainkey.example.onmicrosoft.com.

; DMARC
_dmarc.example.com. 3600 IN TXT "v=DMARC1; p=reject; rua=mailto:dmarc@example.com"

; Autodiscover (for Outlook client configuration)
autodiscover.example.com. 3600 IN CNAME autodiscover.outlook.com.
```

### AWS SES

```
; Domain verification (DKIM — SES uses 3 CNAME records)
; Generated in AWS SES console:
abcdef1234._domainkey.example.com. CNAME abcdef1234.dkim.amazonses.com.
ghijkl5678._domainkey.example.com. CNAME ghijkl5678.dkim.amazonses.com.
mnopqr9012._domainkey.example.com. CNAME mnopqr9012.dkim.amazonses.com.

; SPF for SES
example.com. 3600 IN TXT "v=spf1 include:amazonses.com -all"

; Custom MAIL FROM domain (recommended)
bounce.example.com. 3600 IN MX 10 feedback-smtp.us-east-1.amazonses.com.
bounce.example.com. 3600 IN TXT "v=spf1 include:amazonses.com -all"

; DMARC
_dmarc.example.com. 3600 IN TXT "v=DMARC1; p=reject; rua=mailto:dmarc@example.com"
```

### Multiple Providers (Combined SPF)

```
; Sending from Google Workspace + SendGrid + SES
; Count lookups: Google(~4) + SendGrid(~1) + SES(~1) = ~6 lookups ✓
example.com. 3600 IN TXT "v=spf1 include:_spf.google.com include:sendgrid.net include:amazonses.com -all"

; If over 10 lookups, split by subdomain:
; Main domain: Google Workspace
example.com. TXT "v=spf1 include:_spf.google.com -all"

; Marketing: SendGrid
marketing.example.com. TXT "v=spf1 include:sendgrid.net -all"

; Transactional: SES
notify.example.com. TXT "v=spf1 include:amazonses.com -all"
```

---

## Complete Email DNS Checklist

```
□ MX records set (with priorities)
□ SPF record published (single TXT, ≤10 lookups, -all)
□ DKIM keys generated and DNS records published
□ DMARC record set (start p=none, progress to reject)
□ PTR record set for mail server IP (matches hostname)
□ CAA record restricts certificate authorities
□ MTA-STS policy published (testing → enforce)
□ TLS-RPT record set for TLS failure notifications
□ BIMI record set (after DMARC enforcement)
□ SPF lookup count verified under 10
□ All DNS records tested from external resolvers
□ DMARC aggregate reports monitored
□ DKIM keys on rotation schedule
□ No MX records pointing to CNAMEs
□ Autodiscover/autoconfig records for email clients
```
