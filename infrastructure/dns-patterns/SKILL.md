---
name: dns-patterns
description: >
  Guide for DNS configuration, record management, DNSSEC, email authentication records,
  DNS debugging, and domain setup. Use when user needs to configure DNS records (A, AAAA,
  CNAME, MX, TXT, SRV, NS, SOA, CAA, PTR, NAPTR), set up DNSSEC signing/validation,
  configure SPF/DKIM/DMARC for email, debug DNS resolution with dig/nslookup/host,
  implement DNS load balancing or failover, set up GeoDNS or split-horizon DNS,
  configure DNS over HTTPS/TLS, manage private DNS zones, or troubleshoot DNS propagation.
  NOT for domain registration/purchasing, NOT for web server configuration (nginx/apache),
  NOT for SSL/TLS certificate setup (use ACME/certbot skills instead).
---

# DNS Patterns

## Record Types Reference

### Address Records
```
; A — maps domain to IPv4
example.com.       3600  IN  A      93.184.216.34

; AAAA — maps domain to IPv6
example.com.       3600  IN  AAAA   2606:2800:220:1:248:1893:25c8:1946
```

### CNAME (Alias)
```
; Points subdomain to another domain. NEVER use at zone apex.
www.example.com.   3600  IN  CNAME  example.com.
blog.example.com.  3600  IN  CNAME  hosted.ghost.io.
```
Rule: CNAME cannot coexist with other record types at the same name.

### MX (Mail Exchange)
```
; Lower priority number = higher preference
example.com.  3600  IN  MX  10  mail1.example.com.
example.com.  3600  IN  MX  20  mail2.example.com.
```
MX targets MUST be A/AAAA records, never CNAMEs.

### TXT
```
example.com.  3600  IN  TXT  "v=spf1 include:_spf.google.com ~all"
example.com.  3600  IN  TXT  "google-site-verification=abc123xyz"
```
Max 255 chars per string; split longer values into multiple quoted strings.

### SRV (Service Locator)
```
; Format: _service._proto.name TTL IN SRV priority weight port target
_sip._tcp.example.com.  3600  IN  SRV  10 60 5060 sipserver.example.com.
_minecraft._tcp.mc.example.com. 3600 IN SRV 0 5 25565 mc.example.com.
```

### NS (Name Server)
```
example.com.  86400  IN  NS  ns1.example.com.
example.com.  86400  IN  NS  ns2.example.com.
```
Use high TTLs (86400+). Minimum 2 NS records for redundancy.

### SOA (Start of Authority)
```
; primary-ns  admin-email  serial  refresh  retry  expire  min-ttl
example.com. 86400 IN SOA ns1.example.com. hostmaster.example.com. (
    2025070101  ; serial (YYYYMMDDNN format)
    7200        ; refresh (2h)
    3600        ; retry (1h)
    1209600     ; expire (14d)
    3600        ; minimum TTL (1h, used for negative caching)
)
```

### CAA (Certificate Authority Authorization)
```
; Restrict which CAs can issue certs
example.com.  3600  IN  CAA  0 issue "letsencrypt.org"
example.com.  3600  IN  CAA  0 issuewild "letsencrypt.org"
example.com.  3600  IN  CAA  0 iodef "mailto:security@example.com"
```

### PTR (Reverse DNS)
```
34.216.184.93.in-addr.arpa.  3600  IN  PTR  example.com.
; IPv6 reverse: nibble format under ip6.arpa
```
Essential for email servers — receiving servers check PTR matches.

### NAPTR (Name Authority Pointer)
```
; Used for ENUM, SIP, and URI rewriting
example.com. 3600 IN NAPTR 100 10 "U" "E2U+sip" "!^.*$!sip:info@example.com!" .
```

## DNS Resolution Process

### Recursive vs Iterative
- **Recursive resolver** (e.g., 8.8.8.8, 1.1.1.1): accepts query, does full resolution, returns final answer
- **Iterative/authoritative**: returns referral to next server in chain
- Resolution path: client → recursive resolver → root (.) → TLD (.com) → authoritative (example.com)

### Caching and TTL
- Resolvers cache responses for the duration of the TTL
- Lower TTL = faster propagation but more queries (higher load)
- Higher TTL = fewer queries but slower updates during changes

**TTL guidelines:**
| Scenario | TTL |
|----------|-----|
| Stable production records | 3600–86400 (1h–24h) |
| Pre-migration (lower before change) | 300 (5min) |
| During active migration | 60–300 |
| Post-migration (raise back) | 3600+ |
| Health-check/failover records | 30–60 |

## DNSSEC

### Core Concepts
- **ZSK (Zone Signing Key):** signs zone records (RRsets). Rotate quarterly.
- **KSK (Key Signing Key):** signs the DNSKEY RRset. Rotate every 1–2 years.
- **DS record:** hash of KSK stored at parent zone, anchors chain of trust.
- **RRSIG:** signature over an RRset, validated using DNSKEY.
- **NSEC/NSEC3:** proves non-existence of a record (authenticated denial).

### Chain of Trust
```
Root (.) trust anchor
  └─ DS for .com → validates .com DNSKEY
       └─ DS for example.com → validates example.com DNSKEY
            └─ RRSIG validates A, MX, etc.
```

### Key Rollover — ZSK (Pre-Publish Method)
1. Publish new ZSK in DNSKEY RRset (keep signing with old)
2. Wait ≥ 1 TTL for propagation
3. Sign with new ZSK
4. Wait ≥ 1 TTL, remove old ZSK

### Key Rollover — KSK (Double-DS Method)
1. Generate new KSK, publish in DNSKEY set
2. Submit new DS to parent zone (keep old DS)
3. Wait for parent propagation + resolver cache expiry
4. Remove old KSK and old DS from parent
5. Verify: `dig +dnssec example.com DNSKEY` — confirm validation succeeds

### Automate DS Updates
Use CDS/CDNSKEY records (RFC 8078) if registrar supports them.

## Email Authentication DNS Records

### SPF
```
; Authorize Google Workspace + specific IP
example.com. 3600 IN TXT "v=spf1 include:_spf.google.com ip4:192.0.2.10 -all"
```
Rules: one SPF record per domain. Max 10 DNS lookups. Use `-all` (hard fail) in production.

### DKIM
```
; Selector-based public key record
google._domainkey.example.com. 3600 IN TXT "v=DKIM1; k=rsa; p=MIIBIjANBgkq..."
```
Generate key pair via mail provider. Publish public key. Rotate keys periodically.

### DMARC
```
_dmarc.example.com. 3600 IN TXT "v=DMARC1; p=reject; rua=mailto:dmarc@example.com; pct=100"
```
Rollout path: `p=none` (monitor) → `p=quarantine` → `p=reject` (enforce).

### Complete Email DNS Setup
```bash
# Verify all three:
dig +short TXT example.com | grep spf
dig +short TXT google._domainkey.example.com
dig +short TXT _dmarc.example.com
```

## DNS Debugging

### dig Commands
```bash
# Basic lookup
dig example.com

# Short output (scriptable)
dig +short example.com
# Output: 93.184.216.34

# Query specific server
dig @8.8.8.8 example.com A

# Trace full resolution path (root → TLD → authoritative)
dig +trace example.com

# Specific record types
dig example.com MX +short
# Output: 10 mail.example.com.

dig example.com NS +short
dig example.com SOA +short
dig example.com CAA +short

# DNSSEC validation check
dig +dnssec example.com

# Check EDNS support (look for OPT pseudo-section)
dig +dnssec +noall +answer +comments example.com

# Reverse lookup
dig -x 8.8.8.8 +short
# Output: dns.google.

# Check all records at a name
dig example.com ANY +noall +answer

# Check specific nameserver directly (bypass cache)
dig @ns1.example.com example.com A +norecurse
```

### nslookup Commands
```bash
nslookup example.com
nslookup -type=MX example.com 8.8.8.8
nslookup -type=TXT _dmarc.example.com
nslookup -debug example.com   # verbose packet data
```

### host Commands
```bash
host example.com
host -t MX example.com
host -t TXT example.com
host 8.8.8.8              # reverse lookup
```

### Debugging Checklist
1. `dig +trace domain.com` — find where resolution breaks
2. `dig @authoritative-ns domain.com` — check authoritative directly
3. Compare `dig @8.8.8.8` vs `dig @1.1.1.1` — check propagation
4. `dig +short domain.com` from multiple locations — verify consistency
5. Check SOA serial: `dig SOA domain.com +short` — confirm zone update

## DNS-Based Service Discovery

### SRV Records for Service Discovery
```
; Kubernetes-style service discovery
_http._tcp.myapp.example.com. 300 IN SRV 0 100 8080 pod1.example.com.
_http._tcp.myapp.example.com. 300 IN SRV 0 100 8080 pod2.example.com.

; consul-style
myservice.service.consul. 0 IN SRV 1 1 8500 node1.node.dc1.consul.
```

### DNS-SD (RFC 6763)
```
; Advertise available services
_services._dns-sd._udp.example.com. IN PTR _http._tcp.example.com.
_http._tcp.example.com. IN PTR My Web Server._http._tcp.example.com.
My Web Server._http._tcp.example.com. IN SRV 0 0 80 web.example.com.
My Web Server._http._tcp.example.com. IN TXT "path=/api"
```

## Split-Horizon DNS

Return different answers based on source network.

### Use Cases
- Internal services resolve to private IPs; external queries get public IPs
- VPN users see internal resources; internet users see public-facing services

### Implementation (BIND example)
```
view "internal" {
    match-clients { 10.0.0.0/8; 172.16.0.0/12; 192.168.0.0/16; };
    zone "example.com" { file "db.example.com.internal"; };
};
view "external" {
    match-clients { any; };
    zone "example.com" { file "db.example.com.external"; };
};
```

### Cloud Provider Split-Horizon
- **Route 53:** private hosted zones attached to VPCs
- **Google Cloud DNS:** private managed zones for VPC networks
- **Cloudflare:** no native private zones; use separate internal DNS

## GeoDNS and Latency-Based Routing

### GeoDNS
Return IPs based on client geographic location. Use for CDN endpoints, regional compliance, data sovereignty.

Route 53 supports geolocation (`GeoLocation.ContinentCode/CountryCode`) and latency-based (`Region`) routing policies. See `references/advanced-patterns.md` for details.

## DNS Load Balancing

### Round-Robin (Multiple A Records)
```
app.example.com.  300  IN  A  10.0.1.1
app.example.com.  300  IN  A  10.0.1.2
app.example.com.  300  IN  A  10.0.1.3
```
Resolvers rotate order. Not health-aware — combine with external health checks.

### Weighted Routing (Route 53)
```json
{
  "Type": "A",
  "Name": "app.example.com",
  "SetIdentifier": "primary",
  "Weight": 70,
  "ResourceRecords": [{ "Value": "10.0.1.1" }]
}
```
Use weight 0 to stop traffic to an endpoint.

## DNS Failover

### Route 53 Health Checks + Failover
```json
{
  "Type": "A",
  "Name": "app.example.com",
  "SetIdentifier": "primary",
  "Failover": "PRIMARY",
  "HealthCheckId": "hc-abc123",
  "ResourceRecords": [{ "Value": "10.0.1.1" }]
}
```
Set TTL ≤ 60s for failover records. Health check interval: 10–30s.

### Simple Failover Pattern
1. Primary A record with health check → active endpoint
2. Secondary A record (failover) → standby endpoint
3. Health check fails → DNS returns secondary IP
4. TTL controls how fast clients switch (lower = faster failover)

## DNS Providers

### AWS Route 53
- ALIAS records at zone apex (point to ELB, CloudFront, S3)
- Routing policies: simple, weighted, latency, geolocation, failover, multivalue
- Private hosted zones for VPCs
- `aws route53 change-resource-record-sets --hosted-zone-id Z123 --change-batch file://changes.json`

### Cloudflare DNS
- CNAME flattening (apex CNAME support)
- Proxied vs DNS-only mode (orange cloud vs gray cloud)
- Automatic DNSSEC with Cloudflare Registrar
- API: `curl -X POST "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records"`

### Google Cloud DNS
- `gcloud dns record-sets create app.example.com --zone=myzone --type=A --rrdatas=10.0.1.1 --ttl=300`
- Private zones for GCP VPC networks
- No ALIAS/ANAME support — use A records with automation

## DNS over HTTPS (DoH) and DNS over TLS (DoT)

### DoT
- Encrypts DNS over TLS on port 853
- Configure in systemd-resolved: `DNSOverTLS=yes` in `/etc/systemd/resolved.conf`
- Easy to block (dedicated port)

### DoH
- DNS over HTTPS on port 443, indistinguishable from web traffic
- Browser-native (Firefox, Chrome, Edge)
- Harder to monitor/block on corporate networks

### Testing
```bash
# DoH query using curl
curl -s -H 'accept: application/dns-json' \
  'https://cloudflare-dns.com/dns-query?name=example.com&type=A'

# DoT test with kdig
kdig -d @1.1.1.1 +tls-ca example.com
```

## Private DNS Zones

Use for internal service discovery without exposing records publicly.

- **Route 53:** create private hosted zone, associate with VPCs
- **Google Cloud DNS:** private managed zone scoped to VPC networks
- **On-prem:** BIND views, Unbound with access-control, CoreDNS with autopath

### Pattern: Internal Service Resolution
```
; Private zone: internal.example.com
db-primary.internal.example.com.  300  IN  A  10.0.2.10
redis.internal.example.com.       300  IN  A  10.0.2.20
api.internal.example.com.         300  IN  A  10.0.3.5
```

## DNS Caching and TTL Tuning

### Local Resolver Caching
- systemd-resolved, dnsmasq, Unbound — all cache locally
- Check cache: `resolvectl statistics` (systemd-resolved)
- Flush cache: `resolvectl flush-caches` or `sudo systemd-resolve --flush-caches`
- macOS: `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`

### TTL Strategy
- Pre-change: lower TTL 24–48h before migration (let old high TTL expire)
- During change: keep low (60–300s)
- Post-change: raise back to production TTL (3600+)
- Negative caching (NXDOMAIN): controlled by SOA minimum TTL field

## Wildcard Records

```
; Catch-all for any undefined subdomain
*.example.com.   300  IN  A  10.0.1.1

; Wildcard MX
*.example.com.   300  IN  MX  10 mail.example.com.
```
Wildcards match only where no explicit record exists. A record for `www.example.com` takes precedence over `*.example.com`.

**Caution:** wildcard + CNAME = all undefined subdomains aliased. Can cause unexpected behavior with cookies, CORS, and TLS certificates.

## ALIAS / ANAME Records

Solve the "CNAME at apex" problem. Resolve a CNAME-like target to A/AAAA at query time.

```
; Route 53 ALIAS (not a standard DNS record type)
example.com.  ALIAS  d111111abcdef8.cloudfront.net.

; Cloudflare CNAME flattening
example.com.  CNAME  myapp.herokuapp.com.  ; automatically flattened to A/AAAA
```
Not all providers support ALIAS/ANAME. Verify provider capabilities before relying on it.

## DNS Propagation

### Why Propagation Takes Time
- Recursive resolvers cache records for TTL duration
- ISP resolvers may not honor low TTLs (some enforce minimum 300s)
- Multiple caching layers: browser → OS → local resolver → ISP resolver

### Verify Propagation
```bash
# Check from multiple public resolvers
for ns in 8.8.8.8 1.1.1.1 9.9.9.9 208.67.222.222; do
  echo "=== $ns ===" && dig @$ns +short example.com A
done

# Check authoritative directly (bypasses cache)
dig @$(dig +short NS example.com | head -1) example.com A +short
```

## Common DNS Mistakes

1. **CNAME at zone apex** — violates RFC 1034. Use ALIAS/ANAME or A record.
2. **Multiple SPF records** — only one TXT with `v=spf1` per domain. Merge them.
3. **MX pointing to CNAME** — violates RFC 2181. MX must point to A/AAAA.
4. **TTL too high before migration** — lower TTL 24–48h before making changes.
5. **Missing trailing dot** — in zone files, `example.com` without dot is relative. Use `example.com.`
6. **Forgetting reverse DNS (PTR)** — email servers check PTR. Missing PTR = mail rejected.
7. **SPF exceeding 10 lookups** — causes permerror. Use `include` sparingly; flatten if needed.
8. **DNSSEC DS mismatch** — DS at parent must match active KSK. Verify after rollover.
9. **Wildcard + specific records confusion** — wildcard doesn't override explicit records but catches everything else.
10. **Not testing from external resolvers** — always verify from 8.8.8.8 and 1.1.1.1, not just local.

## Additional Resources

### Reference Documentation (references/)

| File | Contents |
|------|----------|
| `references/advanced-patterns.md` | DNSSEC key management (KSK/ZSK rotation, algorithm rollover), DNS-based service discovery (SRV, Consul, CoreDNS, Kubernetes DNS), split-horizon architectures, DoH/DoT server setup, DNS sinkholing, dynamic DNS (DDNS), DNS load balancing algorithms, anycast DNS, DNS prefetching, EDNS client subnet |
| `references/troubleshooting.md` | Systematic resolution failure diagnosis, SERVFAIL/NXDOMAIN/NODATA analysis, TTL caching issues, negative caching, DNSSEC validation failures and emergency recovery, DNS amplification attack mitigation, zone transfer problems, split-brain DNS, resolver conflicts (systemd-resolved vs NetworkManager, Docker DNS, WSL DNS) |
| `references/email-dns-reference.md` | SPF syntax and 10-lookup limit (flattening, macros), DKIM key generation and rotation, DMARC policy progression (none→quarantine→reject), BIMI setup, MTA-STS, TLS-RPT, email deliverability issues, provider-specific setup (Google Workspace, Microsoft 365, AWS SES, Fastmail, Zoho) |

### Scripts (scripts/)

| Script | Purpose | Usage |
|--------|---------|-------|
| `scripts/dns-audit.sh` | Comprehensive DNS audit — checks all record types, DNSSEC, email auth (SPF/DKIM/DMARC/MTA-STS/TLS-RPT/BIMI) | `./dns-audit.sh [-v] [-r resolver] <domain>` |
| `scripts/dns-propagation-check.sh` | Check DNS propagation across Google, Cloudflare, Quad9, OpenDNS resolvers | `./dns-propagation-check.sh [-e expected] [-w] <domain> [type]` |
| `scripts/email-dns-setup.py` | Generate and validate SPF, DKIM, DMARC records with provider presets | `./email-dns-setup.py <domain> [--provider google] [--validate]` |

### Assets (assets/)

| File | Contents |
|------|----------|
| `assets/zone-file-template.db` | BIND zone file template with SOA, NS, A, AAAA, CNAME, MX, TXT (SPF/DKIM/DMARC), SRV, CAA, MTA-STS, TLS-RPT, BIMI records — copy and customize |
| `assets/dig-cheatsheet.md` | dig command reference — basic queries, output control, DNSSEC, reverse DNS, email records, batch scripting, output interpretation (flags, status codes, answer format) |
| `assets/dns-record-templates.md` | Copy-paste DNS records for: web hosting (GitHub Pages, Netlify, Vercel, S3), email providers (Google, Microsoft 365, AWS SES, Fastmail), domain verification, security records (CAA, MTA-STS), SaaS platforms, SRV records, load balancing |

<!-- tested: pass -->
