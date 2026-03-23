---
name: dns-configuration
description: |
  Use when user configures DNS records, asks about A/AAAA/CNAME/MX/TXT/SRV/NS records, DNS resolution,
  TTL strategy, DNSSEC, DNS debugging (dig/nslookup), or cloud DNS (Route53, Cloud DNS, Cloudflare).
  Do NOT use for HTTP routing without DNS context, /etc/hosts file editing, or mDNS/service discovery in containers.
---

# DNS Configuration and Best Practices

## DNS Fundamentals

### Resolution Flow

1. Client queries stub resolver (OS-level).
2. Stub forwards to recursive resolver (ISP or public like 8.8.8.8).
3. Recursive resolver walks: root → TLD → authoritative nameserver.
4. Authoritative nameserver returns the answer.
5. Recursive resolver caches response for TTL duration.

### Recursive vs Authoritative

- **Recursive resolver**: Answers queries by traversing the DNS tree. Caches results. Examples: 8.8.8.8, 1.1.1.1, ISP resolvers.
- **Authoritative nameserver**: Holds the actual zone data. Returns definitive answers for domains it hosts.

### Caching and TTL

- Every DNS response carries a TTL (seconds). Resolvers cache until expiry.
- SOA MINIMUM controls negative caching (NXDOMAIN responses).
- Resolvers may enforce TTL floors (30–300s common).

## Record Types

### Zone File Examples

```zone
$ORIGIN example.com.
$TTL 3600

; SOA — zone metadata
@   IN  SOA   ns1.example.com. admin.example.com. (
            2025010101  ; serial (YYYYMMDDNN)
            3600        ; refresh
            900         ; retry
            1209600     ; expire
            300         ; negative cache TTL
        )

; Nameservers
@       IN  NS    ns1.example.com.
@       IN  NS    ns2.example.com.

; Address records
@       IN  A     203.0.113.10
@       IN  AAAA  2001:db8::10
www     IN  A     203.0.113.10
www     IN  AAAA  2001:db8::10

; CNAME — alias (never at apex)
blog    IN  CNAME www.example.com.

; MX — mail routing (priority then target)
@       IN  MX    10 mail1.example.com.
@       IN  MX    20 mail2.example.com.

; TXT — SPF, DKIM, verification
@       IN  TXT   "v=spf1 include:_spf.google.com -all"

; SRV — service discovery (_service._proto.name TTL class SRV priority weight port target)
_sip._tcp   IN  SRV   10 60 5060 sipserver.example.com.

; CAA — restrict certificate issuance
@       IN  CAA   0 issue "letsencrypt.org"
@       IN  CAA   0 issuewild ";"

; PTR — reverse DNS (in reverse zone)
; 10.113.0.203.in-addr.arpa. IN PTR example.com.
```

### Record Type Reference

| Type | Purpose | Points To | At Apex? |
|------|---------|-----------|----------|
| A | IPv4 address | IP address | Yes |
| AAAA | IPv6 address | IP address | Yes |
| CNAME | Alias | Another hostname | **No** |
| MX | Mail routing | Hostname (not IP) | Yes |
| TXT | Arbitrary text | String (≤255 chars per segment) | Yes |
| SRV | Service location | Priority/weight/port/target | Yes |
| NS | Delegation | Nameserver hostname | Yes |
| SOA | Zone authority | Primary NS, admin email, timers | Yes |
| CAA | CA authorization | CA domain | Yes |
| PTR | Reverse lookup | Hostname | N/A |
| ALIAS/ANAME | Apex CNAME equivalent | Hostname (provider-specific) | Yes |

### Key Rules

- CNAME cannot coexist with any other record at the same name.
- MX targets must be A/AAAA records, never CNAMEs.
- Use ALIAS/ANAME (Route53 Alias, Cloudflare CNAME flattening) for apex pointing to hostnames.
- Keep TXT records under 255 chars per string; split into multiple quoted strings if needed.

## Common Configurations

### Apex Domain + WWW

```zone
; Apex with A records
@       IN  A     203.0.113.10
@       IN  AAAA  2001:db8::10

; WWW as CNAME to apex (or separate A records)
www     IN  CNAME example.com.
```

For CDN/load balancer targets at apex, use provider-specific ALIAS records:

```
; Route53 Alias (configured via console/API, not zone file)
; Cloudflare: CNAME flattening handles this automatically
```

### Subdomain Delegation

```zone
; Delegate dev.example.com to separate nameservers
dev     IN  NS    ns1.dev-infra.example.com.
dev     IN  NS    ns2.dev-infra.example.com.
```

## Email DNS (MX, SPF, DKIM, DMARC, MTA-STS)

### MX Records

```zone
@       IN  MX    10 aspmx.l.google.com.
@       IN  MX    20 alt1.aspmx.l.google.com.
@       IN  MX    30 alt2.aspmx.l.google.com.
```

Set priority values in increments of 10 for flexibility. Lower number = higher priority.

### SPF

Publish a single TXT record at the domain apex. Limit to 10 DNS lookups.

```zone
@   IN  TXT  "v=spf1 include:_spf.google.com include:mailgun.org -all"
```

- Use `-all` (hard fail) for production domains.
- Use `~all` (soft fail) only during initial rollout.
- Never use `+all`.
- For domains that don't send email: `"v=spf1 -all"`

### DKIM

Publish the public key as a TXT record under `selector._domainkey.domain`:

```zone
google._domainkey   IN  TXT  "v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBA..."
```

- Use 2048-bit RSA keys minimum.
- Use unique selectors per sending service.
- Rotate keys every 6–12 months.

### DMARC

```zone
_dmarc  IN  TXT  "v=DMARC1; p=reject; rua=mailto:dmarc@example.com; ruf=mailto:dmarc-forensic@example.com; fo=1"
```

Rollout path: `p=none` → monitor reports → `p=quarantine` → `p=reject`.

### MTA-STS

Publish DNS TXT record:

```zone
_mta-sts    IN  TXT  "v=STSv1; id=2025010101"
```

Host policy file at `https://mta-sts.example.com/.well-known/mta-sts.txt`:

```
version: STSv1
mode: enforce
mx: mail1.example.com
mx: mail2.example.com
max_age: 604800
```

Update the `id` value whenever the policy file changes.

## TTL Strategy

### Guidelines

| Scenario | TTL | Rationale |
|----------|-----|-----------|
| Static infrastructure (NS, MX, SOA) | 3600–86400 (1h–24h) | Reduce query load |
| Standard web A/AAAA | 300–3600 (5m–1h) | Balance caching and agility |
| Failover/HA endpoints | 60–300 (1–5m) | Fast failover detection |
| Pre-migration (lower 48h before) | 60–300 | Ensure fast propagation at cutover |
| Post-migration (stable) | 3600–86400 | Restore caching efficiency |
| CDN-managed records | Provider-controlled | CDN handles TTL internally |

### Migration TTL Pattern

```
Day -2:  Lower TTL from 3600 → 60
Day  0:  Change A record to new IP
Day +1:  Verify traffic fully shifted
Day +2:  Raise TTL back to 3600
```

Always verify with `dig` from multiple resolvers before and after cutover.

## DNSSEC

### Overview

DNSSEC adds cryptographic signatures to DNS records, preventing cache poisoning and spoofing.

**Chain of trust**: Root → TLD → domain. Each level signs the DS record of the level below.

### Key Types

- **KSK (Key Signing Key)**: Signs the DNSKEY RRset. DS record derived from KSK is placed at parent zone.
- **ZSK (Zone Signing Key)**: Signs all other RRsets in the zone.

### Algorithm Selection

Prefer ECDSAP256SHA256 (algorithm 13) for new deployments. RSA/SHA-256 (algorithm 8) is acceptable fallback.

### Key Rotation Schedule

| Key | Rotation Frequency | Method |
|-----|-------------------|--------|
| ZSK | Every 3–6 months | Pre-publication or double-signing |
| KSK | Every 1–2 years | Double-DS method |

### ZSK Rollover (Pre-Publication)

1. Publish new ZSK in DNSKEY RRset (do not sign with it yet).
2. Wait ≥ 1 TTL for propagation.
3. Sign zone with new ZSK, remove old signatures.
4. Wait ≥ 1 TTL.
5. Remove old ZSK from DNSKEY RRset.

### KSK Rollover (Double-DS)

1. Generate new KSK, add to DNSKEY RRset.
2. Create DS record for new KSK, submit both old and new DS to parent.
3. Wait for parent TTL propagation.
4. Remove old KSK from DNSKEY RRset.
5. Remove old DS from parent.

### DS Record at Registrar

Use SHA-256 digest (algorithm 2). Never use SHA-1 alone.

```bash
# Generate DS record from DNSKEY
dig example.com DNSKEY | dnssec-dsfromkey -2 -f - example.com
```

### Verification

```bash
dig +dnssec example.com A
dig example.com DNSKEY +multiline
dig example.com DS @a.gtld-servers.net
# Check full chain
delv example.com A +rtrace
```

Look for `ad` flag (Authenticated Data) in responses from DNSSEC-validating resolvers.

## Cloud DNS

### AWS Route53

**Alias records**: Use for apex domains pointing to AWS resources (ELB, CloudFront, S3). No charge for alias queries to AWS resources.

**Routing policies**:
- **Simple**: Single resource.
- **Weighted**: Traffic split by weight (blue/green, canary).
- **Latency-based**: Route to lowest-latency region.
- **Geolocation**: Route by user country/continent.
- **Geoproximity**: Route by geographic distance with bias.
- **Failover**: Active-passive with health checks.
- **Multi-value**: Return multiple healthy IPs.

**Health checks**: Associate with records. Combine with CloudWatch alarms for complex checks.

```bash
# Create hosted zone
aws route53 create-hosted-zone --name example.com --caller-reference 2025-01-01

# Create weighted record
aws route53 change-resource-record-sets --hosted-zone-id Z123 --change-batch '{
  "Changes": [{
    "Action": "CREATE",
    "ResourceRecordSet": {
      "Name": "api.example.com",
      "Type": "A",
      "SetIdentifier": "blue",
      "Weight": 70,
      "TTL": 60,
      "ResourceRecords": [{"Value": "203.0.113.10"}]
    }
  }]
}'
```

### Google Cloud DNS

Managed authoritative DNS. Supports DNSSEC natively. No built-in routing policies — use Cloud Load Balancer for geo/latency routing.

```bash
# Create managed zone
gcloud dns managed-zones create example-zone \
  --dns-name="example.com." --description="Production zone" --dnssec-state=on

# Add record
gcloud dns record-sets create www.example.com. --zone=example-zone \
  --type=A --ttl=300 --rrdatas="203.0.113.10"
```

### Cloudflare DNS

- **CNAME flattening**: Resolves CNAME chains at apex, returning A/AAAA to clients.
- **Proxied mode** (orange cloud): Hides origin IP, enables DDoS protection/CDN.
- **DNS-only mode** (grey cloud): Standard authoritative DNS.
- For advanced routing (geo, weighted, failover), use Cloudflare Load Balancer (separate product).

## DNS-Based Load Balancing

| Method | How It Works | Use Case |
|--------|-------------|----------|
| Round-robin | Multiple A records; resolver rotates | Simple distribution |
| Weighted | Provider assigns traffic % per record | Canary deploys, gradual migration |
| Latency-based | Route to nearest/fastest endpoint | Global applications |
| Geolocation | Route by user location | Compliance, localized content |
| Failover | Health-check-driven primary/secondary | High availability |

Limitations: DNS load balancing is coarse-grained. Clients cache responses. Use application-level load balancing (L7) for fine-grained control.

## DNS Debugging

### dig (Primary Tool)

```bash
# Basic query
dig example.com A

# Query specific nameserver
dig @8.8.8.8 example.com A

# Short output
dig +short example.com A

# Full trace from root
dig +trace example.com A

# Check all record types
dig example.com ANY

# Show TTL and suppress noise
dig +nocmd +nocomments +noquestion example.com A

# Check MX records
dig example.com MX +short

# Check TXT (SPF/DKIM/DMARC)
dig example.com TXT +short
dig _dmarc.example.com TXT +short
dig google._domainkey.example.com TXT +short

# DNSSEC validation
dig +dnssec +cd example.com A

# Reverse DNS
dig -x 203.0.113.10

# Measure query time
dig example.com A +stats | grep "Query time"

# Check SOA serial
dig example.com SOA +short
```

### Other Tools

```bash
nslookup -type=MX example.com 8.8.8.8
host -t MX example.com
host 203.0.113.10       # reverse lookup
```

### Propagation Checking

```bash
# Check against multiple public resolvers
for ns in 8.8.8.8 1.1.1.1 208.67.222.222 9.9.9.9; do
  echo "=== $ns ==="
  dig @$ns example.com A +short
done
```

### whois

```bash
whois example.com | grep -i "name server"
```

## Migration Patterns

### Zero-Downtime DNS Migration

1. **Lower TTL** to 60s at least 48 hours before migration.
2. **Verify** old TTL has expired: `dig +nocmd +nocomments example.com A` should show new TTL.
3. **Update** A/AAAA records to new IP.
4. **Monitor** traffic on both old and new infrastructure during propagation.
5. **Keep old infrastructure running** for ≥ 2× the old TTL after cutover.
6. **Raise TTL** back once stable.

### Dual-Stack Migration (IPv4 → IPv6)

1. Add AAAA records alongside existing A records.
2. Monitor IPv6 traffic percentage.
3. Ensure all services handle both address families.
4. Do not remove A records until IPv4 is fully deprecated.

### Nameserver Migration

1. Add new NS records at the new provider.
2. Update NS at registrar to include both old and new nameservers.
3. Ensure zone data is identical on both providers.
4. Remove old nameservers from registrar after propagation (48–72h).

## Internal DNS

### Split-Horizon DNS

Serve different responses for the same domain based on query source:
- Internal clients resolve `app.example.com` → `10.0.1.50` (private IP).
- External clients resolve `app.example.com` → `203.0.113.50` (public IP).

Implement with BIND views (match on source subnet), Route53 private hosted zones (VPC-associated), or CoreDNS conditional forwarding.

### Private DNS Zones

- AWS: Route53 private hosted zones (VPC). GCP: Cloud DNS private zones (VPC). Azure: Private DNS zones (VNet).

Use for internal service discovery: `service.internal.example.com`.

### Service Discovery via DNS

- SRV records: `_http._tcp.api.internal IN SRV 10 0 8080 api-host.internal.`
- Kubernetes CoreDNS: `service.namespace.svc.cluster.local`
- Consul DNS: `.consul` domain.

## Anti-Patterns

### CNAME at Apex

**Problem**: RFC prohibits CNAME at zone apex (breaks NS, SOA, MX records).
**Fix**: Use A/AAAA records, or provider-specific ALIAS/ANAME/CNAME flattening.

### Extremely Low TTL (< 30s)

**Problem**: Increases query load on authoritative servers. Many resolvers enforce TTL floors, so sub-30s TTLs are ignored anyway.
**Fix**: Use 60–300s for dynamic records. Only go lower during active migration windows.

### Missing Reverse DNS (PTR)

**Problem**: Email from IPs without PTR records is flagged as spam. Some services reject connections without valid reverse DNS.
**Fix**: Ensure every mail server IP has a matching PTR record. PTR target should forward-resolve back to the same IP (FCrDNS).

### Dangling CNAME

**Problem**: CNAME pointing to a decommissioned hostname. Enables subdomain takeover attacks.
**Fix**: Audit DNS records regularly. Remove CNAMEs when the target resource is deleted.

### Multiple SPF Records

**Problem**: Publishing more than one SPF TXT record for a domain breaks SPF validation entirely.
**Fix**: Merge all authorized senders into a single `v=spf1 ... -all` record.

### Wildcard Overuse

**Problem**: `*.example.com` catches all subdomains, masking misconfigurations and enabling unintended resolution.
**Fix**: Use explicit records. Reserve wildcards for intentional catch-all scenarios (e.g., multi-tenant SaaS).

### No CAA Records

**Problem**: Any CA can issue certificates for your domain.
**Fix**: Publish CAA records restricting issuance to your chosen CA(s).

<!-- tested: pass -->