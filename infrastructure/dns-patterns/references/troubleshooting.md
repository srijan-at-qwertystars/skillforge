# DNS Troubleshooting Guide

## Table of Contents

- [Systematic Resolution Failure Diagnosis](#systematic-resolution-failure-diagnosis)
  - [Step-by-Step Methodology](#step-by-step-methodology)
  - [Identifying the Failure Layer](#identifying-the-failure-layer)
- [DNS Response Codes](#dns-response-codes)
  - [SERVFAIL Analysis](#servfail-analysis)
  - [NXDOMAIN vs NOERROR Empty (NODATA)](#nxdomain-vs-noerror-empty-nodata)
  - [REFUSED](#refused)
  - [FORMERR](#formerr)
- [TTL and Caching Issues](#ttl-and-caching-issues)
  - [Stale Cache Problems](#stale-cache-problems)
  - [Negative Caching](#negative-caching)
  - [ISP Minimum TTL Enforcement](#isp-minimum-ttl-enforcement)
  - [Cache Flushing](#cache-flushing)
- [DNSSEC Validation Failures](#dnssec-validation-failures)
  - [Common DNSSEC Failures](#common-dnssec-failures)
  - [Diagnosing DNSSEC Issues](#diagnosing-dnssec-issues)
  - [Emergency DNSSEC Recovery](#emergency-dnssec-recovery)
- [DNS Amplification Attacks](#dns-amplification-attacks)
  - [Detection](#detection)
  - [Mitigation](#mitigation)
- [Zone Transfer Problems](#zone-transfer-problems)
- [Split-Brain DNS Issues](#split-brain-dns-issues)
- [Resolver Configuration Conflicts](#resolver-configuration-conflicts)
  - [systemd-resolved vs NetworkManager](#systemd-resolved-vs-networkmanager)
  - [Docker DNS Issues](#docker-dns-issues)
  - [WSL DNS Issues](#wsl-dns-issues)
- [Tools Reference](#tools-reference)

---

## Systematic Resolution Failure Diagnosis

### Step-by-Step Methodology

```
DNS Resolution Failure Flowchart:

1. Can you resolve ANYTHING?
   ├─ No  → Local resolver/network problem (Step 2)
   └─ Yes → Domain-specific problem (Step 3)

2. Test basic connectivity:
   ├─ dig @8.8.8.8 google.com → Works? Local resolver config issue
   ├─ dig @127.0.0.1 google.com → Works? Upstream resolver issue
   └─ ping 8.8.8.8 → Fails? Network/firewall issue

3. Trace the resolution:
   ├─ dig +trace example.com → Find where chain breaks
   ├─ dig @<authoritative-ns> example.com → Check source of truth
   └─ Compare: dig @8.8.8.8 vs dig @1.1.1.1 → Caching issue?

4. Classify the error:
   ├─ SERVFAIL → DNSSEC, timeout, or server error
   ├─ NXDOMAIN → Domain doesn't exist or delegation broken
   ├─ NOERROR + empty → Record type doesn't exist (NODATA)
   └─ REFUSED → Server policy rejection
```

### Identifying the Failure Layer

```bash
# Layer 1: Local system
cat /etc/resolv.conf
resolvectl status                    # systemd-resolved
scutil --dns                         # macOS

# Layer 2: Local resolver
dig @127.0.0.53 example.com         # systemd-resolved stub
dig @$(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}') example.com

# Layer 3: Upstream recursive resolver
dig @8.8.8.8 example.com
dig @1.1.1.1 example.com
dig @9.9.9.9 example.com

# Layer 4: Authoritative nameserver
NS=$(dig +short NS example.com | head -1)
dig @"$NS" example.com +norecurse

# Layer 5: Parent zone delegation
dig +trace example.com              # Follow delegation chain
dig com. NS +short                  # Check TLD nameservers
dig @$(dig +short NS com. | head -1) example.com NS  # Check delegation
```

---

## DNS Response Codes

### SERVFAIL Analysis

SERVFAIL (RCODE 2) indicates the server failed to process the query. Common causes:

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| DNSSEC validation failure | `dig +cd example.com` succeeds | Fix DNSSEC chain (see below) |
| Authoritative server timeout | `dig @auth-ns example.com` times out | Check authoritative server health |
| Lame delegation | NS records point to non-authoritative server | Update NS records at registrar |
| Recursive server overload | High query volume, resource exhaustion | Scale resolver capacity |
| Malformed zone data | Server logs show parse errors | Fix zone file syntax |
| Expired zone (secondary) | SOA serial not refreshing | Check zone transfer (AXFR/IXFR) |

```bash
# Diagnose SERVFAIL step by step
# 1. Is it DNSSEC-related?
dig example.com           # SERVFAIL
dig +cd example.com       # +cd = disable DNSSEC validation
# If +cd works → DNSSEC problem

# 2. Is the authoritative server responding?
dig +short NS example.com
dig @ns1.example.com example.com +norecurse +time=5

# 3. Check for lame delegation
dig @ns1.example.com example.com SOA +norecurse
# If REFUSED or no authority → lame delegation

# 4. Check server logs
journalctl -u named --since "1 hour ago" | grep -i "error\|servfail"
journalctl -u unbound --since "1 hour ago" | grep -i "error\|servfail"
```

### NXDOMAIN vs NOERROR Empty (NODATA)

| Response | Status | Answer Section | Meaning |
|----------|--------|---------------|---------|
| **NXDOMAIN** | RCODE 3 | Empty | Domain name does not exist at all |
| **NODATA** | RCODE 0 (NOERROR) | Empty | Name exists but has no records of queried type |

```bash
# Example: NXDOMAIN — domain doesn't exist
$ dig nonexistent.example.com A
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN
;; ANSWER SECTION: (empty)
;; AUTHORITY SECTION: SOA record (for negative caching)

# Example: NODATA — domain exists but no AAAA record
$ dig example.com AAAA
;; ->>HEADER<<- opcode: QUERY, status: NOERROR
;; ANSWER SECTION: (empty)
;; AUTHORITY SECTION: SOA record

# Distinguish programmatically
dig example.com AAAA +noall +comments | grep "status:"
# NXDOMAIN = name doesn't exist
# NOERROR with no answer = NODATA (name exists, type doesn't)
```

**Common NXDOMAIN causes:**
1. Typo in domain name
2. Domain not registered / expired
3. Delegation not set at registrar
4. Missing record in zone file (for subdomain)
5. DNS propagation hasn't reached resolver yet

### REFUSED

```bash
# REFUSED means the server won't answer your query
$ dig @ns1.example.com othersite.com
;; status: REFUSED

# Common causes:
# 1. Querying an authoritative server for a domain it doesn't serve
# 2. Recursion disabled and you're asking for external domain
# 3. ACL blocking your IP from querying
# 4. Rate limiting triggered
```

### FORMERR

```bash
# FORMERR = malformed query
# Usually caused by:
# 1. EDNS incompatibility (old servers can't handle EDNS0)
# 2. Oversized UDP response with no TCP fallback
# 3. Buggy DNS client/library

# Test without EDNS
dig +noedns example.com @problematic-server
```

---

## TTL and Caching Issues

### Stale Cache Problems

```bash
# Symptom: Different resolvers return different answers
for ns in 8.8.8.8 1.1.1.1 9.9.9.9 208.67.222.222; do
    echo "=== $ns ==="
    dig @$ns example.com A +short
    dig @$ns example.com A +noall +answer | awk '{print "TTL:", $2}'
done

# Remaining TTL indicates when cache entry was fetched
# Lower remaining TTL = fetched longer ago (closer to expiry)
# Higher remaining TTL = recently fetched (will take longer to update)
```

**Pre-migration TTL strategy:**
```
Timeline for DNS migration:
───────────────────────────────────────────────────────
T-48h: Lower TTL to 300s   (wait for old 86400s TTL to expire)
T-0:   Make the DNS change  (new record published)
T+1h:  Verify propagation   (check multiple resolvers)
T+24h: Raise TTL back       (set production TTL 3600-86400s)
───────────────────────────────────────────────────────
```

### Negative Caching

NXDOMAIN responses are cached for the SOA MINIMUM TTL value:

```bash
# Check negative cache TTL
dig nonexistent.example.com A +noall +authority
# The SOA MINIMUM field (last number) controls negative cache duration

# Example SOA:
# example.com. 3600 IN SOA ns1.example.com. admin.example.com. (
#     2025010101 7200 3600 1209600 3600 )
#                                       ^^^^ negative cache TTL = 3600s

# Problem: Created a new subdomain but still getting NXDOMAIN?
# The negative answer is cached for up to 3600 seconds (1 hour)
# Solutions:
# 1. Wait for negative cache to expire
# 2. Flush resolver caches
# 3. Use a lower SOA minimum for zones with frequent subdomain additions
```

### ISP Minimum TTL Enforcement

Some ISP resolvers enforce a minimum TTL (often 300s), ignoring lower values:

```bash
# Detect ISP TTL enforcement
# Set a record to TTL 60, then check what resolvers return
dig @8.8.8.8 example.com +noall +answer   # Shows actual TTL
dig @isp-resolver example.com +noall +answer  # May show higher TTL

# Workaround: Can't fix ISP behavior
# Plan for worst-case 300-600s propagation even with low TTLs
```

### Cache Flushing

```bash
# Local system cache
# Linux (systemd-resolved)
sudo resolvectl flush-caches
resolvectl statistics                    # Verify cache was flushed

# Linux (nscd)
sudo nscd -i hosts

# macOS
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder

# Windows
ipconfig /flushdns

# Remote resolver caches — you CANNOT flush these
# Google: automatically respects TTL
# Cloudflare: purge via https://1.1.1.1/purge-cache/
# Must wait for TTL expiry at ISP/third-party resolvers
```

---

## DNSSEC Validation Failures

### Common DNSSEC Failures

| Failure | Symptom | Root Cause |
|---------|---------|------------|
| Expired RRSIG | SERVFAIL, `+cd` works | Signature not refreshed before expiry |
| DS mismatch | SERVFAIL at parent | KSK rolled but DS not updated at parent |
| Missing DNSKEY | SERVFAIL | Key removed prematurely during rollover |
| Wrong algorithm | SERVFAIL | Algorithm mismatch between DS and DNSKEY |
| Clock skew | SERVFAIL intermittent | Server time outside RRSIG validity window |
| NSEC/NSEC3 gap | Bogus authenticated denial | Zone not properly re-signed after update |

### Diagnosing DNSSEC Issues

```bash
# Step 1: Confirm it's a DNSSEC issue
dig example.com A           # SERVFAIL
dig +cd example.com A       # Success → DNSSEC problem confirmed

# Step 2: Check the DNSSEC chain
dig +dnssec example.com DNSKEY  # Retrieve DNSKEY records
dig +dnssec example.com A       # Check RRSIGs
delv @8.8.8.8 example.com      # Detailed validation trace

# Step 3: Verify DS → DNSKEY match
dig example.com DS +short           # DS at parent
dig example.com DNSKEY +short       # DNSKEY at authoritative
# DS digest must match hash of one of the KSK DNSKEYs

# Step 4: Check RRSIG validity dates
dig +dnssec example.com A +noall +answer
# RRSIG fields: algorithm, labels, TTL, expiration, inception, key-tag, signer
# Verify: inception < now < expiration

# Step 5: Use online validators
# DNSViz: https://dnsviz.net/
# DNSSEC Analyzer: https://dnssec-debugger.verisignlabs.com/
# Zonemaster: https://zonemaster.net/

# Step 6: Full chain validation with drill
drill -DT example.com    # Trace DNSSEC chain from root
```

### Emergency DNSSEC Recovery

If DNSSEC is broken and causing SERVFAIL for all queries:

```bash
# Option 1: Remove DS from parent (disable DNSSEC validation)
# Contact registrar, remove all DS records
# Wait for parent zone TTL to expire (may be 24-48h)

# Option 2: Fix signatures immediately
# Re-sign the zone with valid keys
dnssec-signzone -o example.com -e +7776000 db.example.com
rndc reload example.com

# Option 3: Publish CDS with algorithm 0 to signal DS removal (RFC 8078)
# Add to zone: example.com. CDS 0 0 0 00
# Requires registrar support for automated CDS processing

# Verify recovery
dig +dnssec example.com @8.8.8.8
```

---

## DNS Amplification Attacks

DNS amplification is a DDoS technique where attackers send small queries with spoofed source IPs, causing large responses to be sent to the victim.

### Detection

```bash
# Signs of amplification attack on your DNS server:
# 1. Unusual spike in ANY queries
# 2. Queries from IPs you don't normally serve
# 3. High response-to-query size ratio
# 4. Identical queries from many different source IPs

# Monitor query patterns
tcpdump -n -i eth0 port 53 -c 1000 | \
  awk '/A\?/{print $NF}' | sort | uniq -c | sort -rn | head -20

# Check for open resolver
dig @your-server-ip example.com +short
# If it answers for domains you don't host → you're an open resolver
```

### Mitigation

```bash
# 1. Disable open recursion (authoritative servers)
# BIND named.conf:
options {
    recursion no;
    allow-query { any; };           # Serve auth queries
    allow-recursion { none; };      # No recursive queries
};

# 2. Enable Response Rate Limiting (RRL)
# BIND:
rate-limit {
    responses-per-second 10;
    window 5;
    slip 2;
    errors-per-second 5;
};

# 3. Restrict ANY queries
# BIND (9.11+):
minimal-any yes;  # Return minimal response to ANY queries

# 4. Block spoofed source IPs (BCP 38)
# At network edge:
iptables -A INPUT -i eth0 -s 10.0.0.0/8 -j DROP      # RFC 1918
iptables -A INPUT -i eth0 -s 172.16.0.0/12 -j DROP
iptables -A INPUT -i eth0 -s 192.168.0.0/16 -j DROP

# 5. Rate limit DNS traffic
iptables -A INPUT -p udp --dport 53 -m limit \
  --limit 50/s --limit-burst 100 -j ACCEPT
iptables -A INPUT -p udp --dport 53 -j DROP
```

---

## Zone Transfer Problems

```bash
# Symptom: Secondary DNS server has stale data

# Step 1: Check if zone transfer works
dig @primary-ns example.com AXFR
# REFUSED → ACL or TSIG issue
# NOTAUTH → server isn't authoritative

# Step 2: Check SOA serial
dig @primary example.com SOA +short
dig @secondary example.com SOA +short
# Secondary serial should match primary

# Step 3: Test with specific transfer key
dig @primary-ns example.com AXFR -k /etc/bind/transfer-key.conf

# Step 4: Check BIND logs
journalctl -u named | grep -i "transfer\|axfr\|ixfr\|zone.*example.com"

# Common fixes:
# 1. Update allow-transfer ACL on primary
allow-transfer { key transfer-key; secondary-ip; };

# 2. Fix TSIG key mismatch
# Both servers must have identical key name, algorithm, and secret

# 3. Check notify settings
notify yes;
also-notify { secondary-ip; };

# 4. Force zone transfer
rndc retransfer example.com    # On secondary
rndc notify example.com        # On primary

# 5. Check if IXFR failing, fall back to AXFR
# On secondary:
request-ixfr no;    # Force full zone transfer
```

---

## Split-Brain DNS Issues

Split-brain occurs when internal and external DNS return different answers, causing confusion:

```
Symptoms:
- Service works internally but not externally (or vice versa)
- VPN users can't access internal resources
- Certificate validation fails (cert has public IP, DNS returns private IP)
- Application health checks fail across network boundaries
```

### Diagnosis

```bash
# Compare internal vs external resolution
dig @internal-resolver app.example.com A +short   # 10.0.1.5 (internal)
dig @8.8.8.8 app.example.com A +short             # 203.0.113.5 (external)

# Check which resolver a client is using
resolvectl status        # Linux
scutil --dns             # macOS
nslookup example.com     # Shows "Server:" line

# Trace the resolution path
dig +trace app.example.com    # Shows public path
dig @10.0.0.53 app.example.com +norecurse  # Shows internal view
```

### Common Fixes

1. **VPN users getting public IPs:** Ensure VPN pushes internal DNS resolver
2. **Certificate mismatch:** Use SANs covering both internal and external names
3. **Inconsistent zones:** Sync overlapping records between views
4. **Testing:** Always test from both internal and external perspectives

---

## Resolver Configuration Conflicts

### systemd-resolved vs NetworkManager

```bash
# Check what's managing DNS
ls -la /etc/resolv.conf
# Symlink to ../run/systemd/resolve/stub-resolv.conf → systemd-resolved
# Symlink to ../run/NetworkManager/resolv.conf → NetworkManager
# Regular file → manual configuration

# systemd-resolved status
resolvectl status
# Shows: Current DNS Server, DNS Servers, DNS Domain, DNSSEC, etc.

# NetworkManager DNS settings
nmcli device show | grep DNS
nmcli connection show "My Connection" | grep dns

# Common conflict: Both services try to manage /etc/resolv.conf
# Fix: Choose one manager

# Option 1: Let systemd-resolved manage (recommended for modern distros)
# /etc/NetworkManager/conf.d/dns.conf
[main]
dns=systemd-resolved

# Option 2: Let NetworkManager manage
sudo systemctl disable --now systemd-resolved
# Remove /etc/resolv.conf symlink, NetworkManager regenerates it

# Option 3: Manual /etc/resolv.conf
sudo systemctl disable --now systemd-resolved
# /etc/NetworkManager/conf.d/dns.conf
[main]
dns=none
# Manually edit /etc/resolv.conf
```

**Debugging resolution chain on modern Linux:**
```bash
# What stub resolver is the system using?
cat /etc/resolv.conf

# What does systemd-resolved see?
resolvectl query example.com

# What does the kernel's resolver library see?
getent hosts example.com

# Bypass all local resolvers
dig @8.8.8.8 example.com

# Check /etc/nsswitch.conf for resolution order
grep hosts /etc/nsswitch.conf
# hosts: files mdns4_minimal [NOTFOUND=return] dns myhostname
# files = /etc/hosts checked first
# dns = DNS resolver used
```

### Docker DNS Issues

```bash
# Docker containers use their own DNS resolver (127.0.0.11)
# Common issues:

# 1. Container can't resolve external domains
docker exec mycontainer cat /etc/resolv.conf
# Check: nameserver should be 127.0.0.11

# 2. Custom DNS for Docker daemon
# /etc/docker/daemon.json
{
    "dns": ["8.8.8.8", "1.1.1.1"],
    "dns-search": ["example.com"]
}

# 3. Docker Compose DNS
# docker-compose.yml
services:
  app:
    dns:
      - 8.8.8.8
      - 1.1.1.1

# 4. Docker internal DNS not resolving container names
# Ensure containers are on the same user-defined network
docker network create mynet
docker run --network mynet --name mydb postgres
docker run --network mynet --name myapp myimage
# myapp can resolve "mydb" via Docker DNS
```

### WSL DNS Issues

```bash
# WSL2 DNS commonly breaks due to auto-generated resolv.conf

# Check current config
cat /etc/resolv.conf
# If nameserver is a Windows Hyper-V IP that's unreachable:

# Fix: Disable auto-generation
# /etc/wsl.conf
[network]
generateResolvConf = false

# Then set DNS manually
sudo rm /etc/resolv.conf   # Remove symlink
sudo tee /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# Alternative: Use Windows DNS but fix routing
# Get Windows host IP from WSL:
cat /etc/resolv.conf  # The auto-generated nameserver IS Windows
# If it fails, it's likely a firewall issue on the Windows side
```

---

## Tools Reference

### Essential DNS Debugging Tools

| Tool | Use Case | Install |
|------|----------|---------|
| `dig` | Detailed DNS queries | `apt install dnsutils` |
| `drill` | DNSSEC-aware queries | `apt install ldnsutils` |
| `delv` | DNSSEC validation debugging | Included with BIND |
| `host` | Simple lookups | `apt install dnsutils` |
| `nslookup` | Interactive/basic queries | `apt install dnsutils` |
| `kdig` | DoT/DoH testing | `apt install knot-dnsutils` |
| `dog` | Modern dig alternative | `cargo install dog` |
| `resolvectl` | systemd-resolved diagnostics | Included with systemd |
| `tcpdump` | DNS packet capture | `apt install tcpdump` |
| `wireshark` | GUI packet analysis | `apt install wireshark` |
| `dnstracer` | Trace delegation chain | `apt install dnstracer` |

### Quick Diagnostic Commands

```bash
# "Is DNS working at all?"
dig +short google.com @8.8.8.8

# "What resolver am I using?"
cat /etc/resolv.conf && resolvectl status 2>/dev/null

# "Is the domain's DNS configured correctly?"
dig +trace example.com

# "Is DNSSEC the problem?"
dig example.com +cd   # bypass validation

# "What records exist for this name?"
dig example.com ANY +noall +answer

# "Is the authoritative server responding?"
dig @$(dig +short NS example.com | head -1) example.com +norecurse

# "Has my DNS change propagated?"
for ns in 8.8.8.8 1.1.1.1 9.9.9.9; do
    echo "=== $ns ===" && dig @$ns +short example.com
done

# "What's the full DNS response?"
dig example.com +multiline +noall +answer +authority +additional +comments
```
