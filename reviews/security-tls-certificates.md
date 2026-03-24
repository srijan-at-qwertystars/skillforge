# QA Review: tls-certificates

**Skill path:** `~/skillforge/security/tls-certificates/`
**Reviewed:** 2025-07-17
**Reviewer:** Copilot CLI (automated)

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `tls-certificates` |
| YAML frontmatter `description` | ✅ Pass | Multi-line, detailed |
| Positive triggers | ✅ Pass | 18+ trigger terms: SSL/TLS, HTTPS, certbot, mTLS, openssl, CSR, OCSP, HSTS, SNI, cert-manager, ACME, etc. |
| Negative triggers | ✅ Pass | 5 exclusions: AES/symmetric, SSH keys, JWT, VPN, code signing |
| Body ≤ 500 lines | ✅ Pass | 496 lines |
| Imperative voice | ✅ Pass | Commands and instructions use imperative consistently |
| Examples with I/O | ✅ Pass | Extensive code blocks with commands; some include expected output (chain verification, error table) |
| References linked from SKILL.md | ✅ Pass | 3 reference docs linked and described |
| Scripts linked from SKILL.md | ✅ Pass | 3 scripts linked with usage examples |
| Assets linked from SKILL.md | ✅ Pass | openssl.cnf, certbot-hooks/, cipher-suites.md all linked |

**Structure verdict:** Pass — well-organized, complete scaffolding.

---

## b. Content Check

### Verified Claims

| Claim | Source | Verdict |
|-------|--------|---------|
| TLS 1.3 has 5 AEAD cipher suites | RFC 8446 | ✅ Correct (AES_128_GCM, AES_256_GCM, CHACHA20_POLY1305, AES_128_CCM, AES_128_CCM_8) |
| TLS 1.3 is 1-RTT, 0-RTT resumption has replay risk | RFC 8446 | ✅ Correct |
| `openssl x509 -checkend 2592000` checks 30-day expiry | OpenSSL docs | ✅ Correct (exit code 1 = expiring) |
| Wildcard `*.example.com` does NOT cover apex | RFC 6125, industry consensus | ✅ Correct |
| Let's Encrypt: 50 certs/registered domain/7 days | letsencrypt.org/docs/rate-limits | ✅ Correct |
| RSA 2048 = 112 security bits, 3072 = 128 | NIST SP 800-57 | ✅ Correct |
| RSA 4096 = 140 security bits | NIST estimates | ⚠️ Acceptable (range is 140–150; 140 is conservative) |
| PEM chain order: leaf → intermediate → root | Industry standard | ✅ Correct |
| HPKP deprecated (Chrome 72, Firefox 72) | Browser changelogs | ✅ Correct |
| cert-manager v1.16.3 | GitHub releases | ✅ Valid version (released Oct 2024) |
| openssl conversion commands (PEM↔DER, PKCS#12) | OpenSSL docs | ✅ All correct |
| CSR generation with `-addext` for SANs | OpenSSL 1.1.1+ | ✅ Correct syntax |

### Issues Found

1. **SNI encryption claim is misleading (line 357)**
   > "encrypted in TLS 1.3 via ECH"

   **Problem:** SNI is NOT encrypted in standard TLS 1.3. ECH (Encrypted Client Hello, RFC 9849) is a separate extension, not part of core TLS 1.3. The current wording implies ECH is a built-in TLS 1.3 feature. A reader may incorrectly assume TLS 1.3 alone protects the SNI field.

   **Suggested fix:** Change to: "SNI is plaintext in TLS 1.2 and TLS 1.3; the ECH extension (RFC 9849, separate from TLS 1.3) encrypts the ClientHello including SNI but requires both client and server support."

   **Severity:** Medium — could mislead security decisions.

2. **Missing gotcha: `-addext` requires OpenSSL 1.1.1+**
   The CSR and self-signed cert examples use `openssl req -addext` which is not available on older OpenSSL versions (e.g., RHEL 7 ships 1.0.2). A note would help users on legacy systems.

   **Severity:** Low.

3. **Missing gotcha: CT logs expose internal hostnames**
   The CT section doesn't warn that publicly-issued certificates for internal hostnames will appear in CT logs, potentially leaking infrastructure details.

   **Severity:** Low.

### Scripts Review

| Script | Quality | Notes |
|--------|---------|-------|
| `cert-check.sh` | ✅ Excellent | 283 lines, handles remote + local certs, color output, OCSP/CT/TLS version checks |
| `self-signed-ca.sh` | ✅ Excellent | 326 lines, full CA hierarchy (root → intermediate → server + client), PKCS#12, verification |
| `cert-renew-monitor.sh` | ✅ Excellent | 263 lines, Slack alerts, JSON output, auto-renewal, configurable thresholds |

All scripts use `set -euo pipefail`, have usage docs, and are well-structured.

### Assets Review

| Asset | Quality | Notes |
|-------|---------|-------|
| `openssl.cnf` | ✅ Excellent | 211 lines, covers CA/CSR/server/client/mTLS/OCSP extensions, well-commented |
| `cipher-suites.md` | ✅ Excellent | Modern/Intermediate/Old profiles for Nginx/Apache/HAProxy/Caddy |
| `certbot-hooks/` | ✅ Good | 3 deploy hooks (Nginx/Apache/HAProxy), config-test-before-reload pattern |

### References Review

| Reference | Lines | Quality | Notes |
|-----------|-------|---------|-------|
| `advanced-patterns.md` | 649 | ✅ Excellent | mTLS patterns, 0-RTT, CT monitoring, DANE, Vault PKI, rotation strategies |
| `troubleshooting.md` | 691 | ✅ Excellent | Comprehensive symptom→cause→fix, trust store differences across platforms |
| `acme-reference.md` | 762 | ✅ Excellent | DNS plugin configs (4 providers), rate limits, cert-manager K8s, acme.sh, Caddy |

---

## c. Trigger Check

**Positive triggers:** Strong. The description covers 18+ relevant terms spanning certificate lifecycle, debugging, automation, and web-server config. Broad enough to catch most legitimate queries.

**Negative triggers:** Good. Five explicit exclusions prevent confusion with adjacent security topics (symmetric encryption, SSH, JWT, VPN, code signing).

**Potential false triggers:** Low risk. The description is specific enough that generic mentions of "certificate" (e.g., "certification exam") should not trigger.

**Missing triggers:** Consider adding "PKI" (Public Key Infrastructure) as an explicit trigger term — users asking about internal PKI would benefit from this skill but might not use the word "TLS" or "SSL".

**Description pushiness:** Adequate. The description clearly states what the skill handles and what it doesn't. Could be slightly more aggressive on Kubernetes-related terms (e.g., "ingress TLS", "kubernetes certificate").

---

## d. Scores

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Accuracy** | 4 | One misleading claim (SNI/ECH conflation with TLS 1.3). All other technical details verified correct. RSA 4096 security-bits value is conservative but acceptable. |
| **Completeness** | 5 | Exceptionally thorough. Covers full certificate lifecycle: generation, issuance, debugging, renewal, automation, Kubernetes, mTLS, revocation, CT, advanced patterns. 3 reference docs, 3 scripts, 3+ asset files. Security checklist included. |
| **Actionability** | 5 | Every section has copy-paste ready commands. Scripts are executable with clear usage. Config templates for Nginx/Apache/HAProxy/Caddy. Troubleshooting uses symptom→cause→fix format. |
| **Trigger quality** | 4 | Strong positive/negative triggers. Minor gap: missing "PKI" keyword. Could strengthen K8s-related triggers. |
| **Overall** | **4.5** | Average of (4+5+5+4)/4 |

---

## e. GitHub Issues

**No issues required.** Overall score (4.5) ≥ 4.0 and no dimension ≤ 2.

### Recommended Improvements (non-blocking)

1. Fix SNI/ECH wording in the SNI section (line 357) — clarify ECH is a separate extension, not a TLS 1.3 built-in feature.
2. Add note that `-addext` requires OpenSSL ≥ 1.1.1 in CSR/self-signed sections.
3. Add CT log privacy warning (internal hostnames exposed).
4. Add "PKI" to trigger description.

---

## f. SKILL.md Annotation

`<!-- tested: pass -->` appended to SKILL.md.

---

**Review path:** `~/skillforge/reviews/security-tls-certificates.md`
**Result:** ✅ **PASS**
