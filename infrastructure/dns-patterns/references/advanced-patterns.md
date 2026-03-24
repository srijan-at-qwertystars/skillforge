# Advanced DNS Patterns

## Table of Contents

- [DNSSEC Key Management](#dnssec-key-management)
  - [Key Types and Roles](#key-types-and-roles)
  - [Algorithm Selection](#algorithm-selection)
  - [ZSK Rotation](#zsk-rotation)
  - [KSK Rotation](#ksk-rotation)
  - [Algorithm Rollover](#algorithm-rollover)
  - [Automated Key Management](#automated-key-management)
- [DNS-Based Service Discovery](#dns-based-service-discovery)
  - [SRV Records Deep Dive](#srv-records-deep-dive)
  - [DNS-SD (RFC 6763)](#dns-sd-rfc-6763)
  - [Consul DNS](#consul-dns)
  - [CoreDNS](#coredns)
  - [Kubernetes DNS](#kubernetes-dns)
- [Split-Horizon Architectures](#split-horizon-architectures)
  - [BIND Views](#bind-views)
  - [Cloud Provider Split-Horizon](#cloud-provider-split-horizon)
  - [Split-Horizon with DNSSEC](#split-horizon-with-dnssec)
- [DNS-over-HTTPS and DNS-over-TLS](#dns-over-https-and-dns-over-tls)
  - [DoH Server Setup](#doh-server-setup)
  - [DoT Server Setup](#dot-server-setup)
  - [Client Configuration](#client-configuration)
  - [Enterprise Considerations](#enterprise-considerations)
- [DNS Sinkholing](#dns-sinkholing)
- [Dynamic DNS (DDNS)](#dynamic-dns-ddns)
- [DNS Load Balancing Algorithms](#dns-load-balancing-algorithms)
- [Anycast DNS](#anycast-dns)
- [DNS Prefetching](#dns-prefetching)
- [EDNS Client Subnet](#edns-client-subnet)

---

## DNSSEC Key Management

### Key Types and Roles

| Key | Purpose | Rotation Frequency | Storage |
|-----|---------|-------------------|---------|
| **ZSK** (Zone Signing Key) | Signs zone RRsets | Every 3–12 months | Can be online |
| **KSK** (Key Signing Key) | Signs the DNSKEY RRset | Every 1–3 years | HSM recommended |
| **DS** (Delegation Signer) | Hash of KSK at parent zone | Updated on KSK rollover | Parent zone |
| **CDS/CDNSKEY** | Automated DS updates (RFC 8078) | Mirrors KSK changes | Child zone |

### Algorithm Selection

**Preferred (2024+):**
- **ECDSA P-256 with SHA-256 (Algorithm 13)** — modern, efficient, small signatures
- **Ed25519 (Algorithm 15)** — excellent performance, growing support

**Acceptable:**
- **RSA/SHA-256 (Algorithm 8)** — widely supported, larger keys/signatures

**Avoid:**
- RSA/SHA-1 (Algorithm 5) — deprecated
- DSA (Algorithm 3) — deprecated
- Any algorithm with SHA-1 digests

```bash
# Generate ECDSA P-256 keys with BIND
dnssec-keygen -a ECDSAP256SHA256 -n ZONE example.com        # ZSK
dnssec-keygen -a ECDSAP256SHA256 -n ZONE -f KSK example.com # KSK
```

### ZSK Rotation

#### Pre-Publish Method (Recommended for large zones)

```
Timeline:
─────────────────────────────────────────────────────────
Phase 1: Publish new ZSK       │ Sign with OLD ZSK
  ↓ Wait ≥ DNSKEY TTL + propagation delay
Phase 2: Sign with new ZSK     │ Both ZSKs in DNSKEY
  ↓ Wait ≥ max(zone TTL) + propagation delay
Phase 3: Remove old ZSK        │ Only new ZSK remains
─────────────────────────────────────────────────────────
```

1. Generate new ZSK, add to DNSKEY RRset (keep signing with old)
2. Wait ≥ DNSKEY TTL for all resolvers to cache both keys
3. Re-sign zone with new ZSK
4. Wait ≥ longest signature TTL for old RRSIGs to expire from caches
5. Remove old ZSK from DNSKEY RRset

#### Double-Signature Method (Simpler but larger zone)

1. Add new ZSK and sign zone with **both** old and new keys
2. Both sets of RRSIGs published simultaneously
3. Wait ≥ max TTL
4. Remove old ZSK and old RRSIGs

### KSK Rotation

#### Double-DS Method (Recommended)

```
Timeline:
─────────────────────────────────────────────────────────
Phase 1: Add new KSK to DNSKEY │ Sign DNSKEY with BOTH KSKs
Phase 2: Add new DS to parent  │ Both DS records at parent
  ↓ Wait ≥ parent DS TTL + resolver cache expiry
Phase 3: Remove old KSK        │ Remove old DS from parent
  ↓ Verify with: dig +dnssec example.com DNSKEY
─────────────────────────────────────────────────────────
```

**Critical:** Never remove the old DS before the new DS has fully propagated.

```bash
# Generate DS record from KSK for parent submission
dnssec-dsfromkey -2 Kexample.com.+013+12345.key  # SHA-256 digest

# Verify DNSSEC chain after rollover
dig +dnssec +cd example.com DNSKEY
delv @8.8.8.8 example.com DNSKEY +rtrace
```

#### Double-KSK Method (Alternative)

1. Add new KSK, sign DNSKEY with both
2. Submit new DS to parent (keep old)
3. Wait for propagation
4. Sign DNSKEY with only new KSK
5. Wait for old RRSIG expiry
6. Remove old DS from parent

### Algorithm Rollover

When changing from one DNSSEC algorithm to another (e.g., RSA → ECDSA):

1. **Generate new KSK and ZSK** with new algorithm
2. **Sign zone with BOTH algorithm sets** — dual signatures for all RRsets
3. **Add new DS** (new algorithm) to parent, keep old DS
4. Wait for full propagation (parent TTL + resolver cache)
5. **Remove old algorithm** keys and signatures
6. **Remove old DS** from parent

```bash
# Verify both algorithms are being served
dig +dnssec example.com A | grep RRSIG
# Should see RRSIGs with both algorithm numbers during transition
```

**Warning:** Algorithm rollover is the most complex DNSSEC operation. Test in staging first.

### Automated Key Management

#### BIND Automatic DNSSEC (dnssec-policy)

```
// named.conf
dnssec-policy "standard" {
    keys {
        ksk key-directory lifetime P2Y algorithm ecdsap256sha256;
        zsk key-directory lifetime P90D algorithm ecdsap256sha256;
    };
    dnskey-ttl 3600;
    publish-safety PT1H;
    retire-safety PT1H;
    signatures-refresh P5D;
    signatures-validity P14D;
    signatures-validity-dnskey P14D;
    max-zone-ttl P1D;
    zone-propagation-delay PT5M;
    parent-ds-ttl P1D;
    parent-propagation-delay PT1H;
};

zone "example.com" {
    type primary;
    file "db.example.com";
    dnssec-policy "standard";
    inline-signing yes;
};
```

#### CDS/CDNSKEY for Automated DS Updates

```
; Publish CDS record to signal parent for DS update
example.com. 3600 IN CDS 12345 13 2 <sha256-digest>
example.com. 3600 IN CDNSKEY 257 3 13 <public-key-base64>

; To request DS removal (decommission DNSSEC):
example.com. 3600 IN CDS 0 0 0 00
```

Requires registrar/parent support for RFC 8078.

---

## DNS-Based Service Discovery

### SRV Records Deep Dive

```
; Format: _service._proto.name TTL class SRV priority weight port target
;
; Priority: lower = preferred (like MX)
; Weight: relative weight for same-priority records (load distribution)
; Port: TCP/UDP port of the service
; Target: hostname (MUST have A/AAAA records, MUST NOT be CNAME)

; Example: LDAP service with failover and load balancing
_ldap._tcp.example.com. 300 IN SRV 10 60 389 ldap1.example.com.
_ldap._tcp.example.com. 300 IN SRV 10 40 389 ldap2.example.com.
_ldap._tcp.example.com. 300 IN SRV 20 0  389 ldap-backup.example.com.

; Priority 10 servers share load 60/40
; Priority 20 server is backup (only used if priority 10 servers fail)
```

**Weight algorithm:** For records with the same priority, a client should select randomly with probability proportional to weight. Weight 0 means "use only if no other choice at this priority."

### DNS-SD (RFC 6763)

DNS Service Discovery layers on top of SRV records:

```
; Step 1: Enumerate service types available
_services._dns-sd._udp.example.com. IN PTR _http._tcp.example.com.
_services._dns-sd._udp.example.com. IN PTR _printer._tcp.example.com.

; Step 2: Enumerate instances of a service type
_http._tcp.example.com. IN PTR "Main Web Server._http._tcp.example.com."
_http._tcp.example.com. IN PTR "API Server._http._tcp.example.com."

; Step 3: Resolve instance details
Main Web Server._http._tcp.example.com. IN SRV 0 0 80 web.example.com.
Main Web Server._http._tcp.example.com. IN TXT "path=/index.html" "version=2.0"
```

### Consul DNS

Consul provides DNS interface for service discovery on port 8600:

```bash
# Query all instances of "web" service
dig @127.0.0.1 -p 8600 web.service.consul SRV

# Query by tag
dig @127.0.0.1 -p 8600 production.web.service.consul SRV

# Query in specific datacenter
dig @127.0.0.1 -p 8600 web.service.dc2.consul SRV

# Node lookup
dig @127.0.0.1 -p 8600 node1.node.consul A

# Prepared queries (failover, routing)
dig @127.0.0.1 -p 8600 my-query.query.consul SRV
```

**Consul DNS patterns:**
| Query Format | Purpose |
|---|---|
| `<service>.service.consul` | All instances |
| `<tag>.<service>.service.consul` | Filter by tag |
| `<service>.service.<dc>.consul` | Specific datacenter |
| `<query-id>.query.consul` | Prepared query |
| `<node>.node.consul` | Node address |

**Note:** Consul randomizes SRV record order and does not honor the SRV weight field.

### CoreDNS

CoreDNS is the default Kubernetes DNS server. Key plugins for service discovery:

```
# Corefile — forward .consul to Consul DNS
. {
    forward . /etc/resolv.conf
    log
    errors
    cache 30
}

consul {
    forward . 127.0.0.1:8600
    cache 10
}

# Corefile — Kubernetes with custom zones
.:53 {
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    }
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}

internal.example.com {
    file /etc/coredns/db.internal.example.com
    log
}
```

**Useful CoreDNS plugins:**
- `kubernetes` — auto-discovers Kubernetes services/pods
- `forward` — proxy to upstream resolvers
- `rewrite` — transform queries/responses
- `cache` — response caching with TTL
- `loadbalance` — round-robin A/AAAA records
- `health` / `ready` — health check endpoints
- `autopath` — optimize ndots search path

### Kubernetes DNS

Kubernetes creates DNS records automatically via CoreDNS:

```
; Service A record
my-svc.my-namespace.svc.cluster.local. → ClusterIP

; Headless service (no ClusterIP) — returns pod IPs
my-headless.my-namespace.svc.cluster.local. → Pod IPs

; SRV records for named ports
_http._tcp.my-svc.my-namespace.svc.cluster.local. SRV → port + pod hostname

; Pod DNS (when hostname/subdomain set)
pod-hostname.my-headless.my-namespace.svc.cluster.local. → Pod IP

; ExternalName service
my-ext.my-namespace.svc.cluster.local. CNAME → external.example.com.
```

---

## Split-Horizon Architectures

### BIND Views

```
// named.conf — Full split-horizon configuration
acl "internal-nets" {
    10.0.0.0/8;
    172.16.0.0/12;
    192.168.0.0/16;
    fc00::/7;
};

acl "vpn-nets" {
    10.8.0.0/16;
};

view "internal" {
    match-clients { internal-nets; vpn-nets; };
    recursion yes;

    zone "example.com" {
        type primary;
        file "zones/db.example.com.internal";
    };

    // Internal-only zone
    zone "internal.example.com" {
        type primary;
        file "zones/db.internal.example.com";
    };
};

view "external" {
    match-clients { any; };
    recursion no;  // Never allow recursion for external

    zone "example.com" {
        type primary;
        file "zones/db.example.com.external";
    };

    // internal.example.com NOT served — NXDOMAIN for external
};
```

### Cloud Provider Split-Horizon

**AWS Route 53:**
```bash
# Create private hosted zone attached to VPC
aws route53 create-hosted-zone \
  --name example.com \
  --vpc VPCRegion=us-east-1,VPCId=vpc-abc123 \
  --caller-reference "private-$(date +%s)" \
  --hosted-zone-config PrivateZone=true

# Private zone records override public zone for VPC members
```

**Google Cloud DNS:**
```bash
# Create private managed zone
gcloud dns managed-zones create internal-zone \
  --dns-name="example.com." \
  --description="Internal DNS" \
  --visibility=private \
  --networks=my-vpc
```

**Azure Private DNS:**
```bash
az network private-dns zone create \
  --resource-group myRG \
  --name example.com

az network private-dns link vnet create \
  --resource-group myRG \
  --zone-name example.com \
  --name myLink \
  --virtual-network myVnet \
  --registration-enabled true
```

### Split-Horizon with DNSSEC

Split-horizon and DNSSEC can conflict — different views serve different answers for the same name, but DNSSEC expects consistent signed responses. Solutions:

1. **Sign only the external view** — internal resolvers don't validate DNSSEC
2. **Use separate zones** — `internal.example.com` (unsigned) vs `example.com` (signed)
3. **Sign both views** — requires careful key management and may leak internal structure via NSEC/NSEC3

---

## DNS-over-HTTPS and DNS-over-TLS

### DoH Server Setup

**Nginx reverse proxy to local resolver:**
```nginx
server {
    listen 443 ssl http2;
    server_name dns.example.com;

    ssl_certificate     /etc/ssl/certs/dns.example.com.pem;
    ssl_certificate_key /etc/ssl/private/dns.example.com.key;
    ssl_protocols       TLSv1.3;

    location /dns-query {
        proxy_pass       http://127.0.0.1:8053;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

**Standalone with dnsproxy (AdGuard):**
```bash
# Install and run DoH server
dnsproxy \
  --listen 0.0.0.0 \
  --https-port 443 \
  --tls-crt /etc/ssl/certs/dns.pem \
  --tls-key /etc/ssl/private/dns.key \
  --upstream 127.0.0.1:53
```

### DoT Server Setup

**Unbound:**
```yaml
server:
    interface: 0.0.0.0@853
    tls-port: 853
    tls-service-key: "/etc/unbound/dns.key"
    tls-service-pem: "/etc/unbound/dns.pem"
    tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"
```

**BIND (9.17+):**
```
tls local-tls {
    cert-file "/etc/bind/dns.pem";
    key-file "/etc/bind/dns.key";
};

options {
    listen-on tls local-tls { any; } port 853;
};
```

### Client Configuration

**Linux (systemd-resolved):**
```ini
# /etc/systemd/resolved.conf
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com
DNSOverTLS=opportunistic  # or "yes" for strict
```

**Testing:**
```bash
# Test DoH with curl
curl -s -H 'accept: application/dns-json' \
  'https://cloudflare-dns.com/dns-query?name=example.com&type=A' | jq

# Test DoT with kdig (knot-dnsutils)
kdig -d @1.1.1.1 +tls-ca +tls-hostname=cloudflare-dns.com example.com

# Test DoH with dog (modern dig alternative)
dog example.com --https @https://dns.google/dns-query
```

### Enterprise Considerations

- **Monitoring:** DoH on port 443 is indistinguishable from HTTPS — can't block by port
- **DoT on port 853** — easier to monitor/block via firewall rules
- **Force encrypted DNS:** Block outbound port 53 to enforce DoH/DoT usage
- **Internal DoH/DoT:** Run your own resolver to maintain visibility

```bash
# Block plaintext DNS for all but your resolver
iptables -A OUTPUT -p udp --dport 53 ! -d 10.0.0.53 -j REJECT
iptables -A OUTPUT -p tcp --dport 53 ! -d 10.0.0.53 -j REJECT
```

---

## DNS Sinkholing

DNS sinkholing intercepts queries to known-malicious domains and returns a controlled response.

### Implementation with Unbound

```yaml
server:
    local-zone: "malware-c2.example.bad." redirect
    local-data: "malware-c2.example.bad. A 10.0.0.1"  # sinkhole IP

    # Or use response-policy zones (RPZ)
    # Block entire domain and subdomains
    local-zone: "badsite.com." always_nxdomain
```

### Implementation with BIND (RPZ)

```
// named.conf
options {
    response-policy {
        zone "rpz.example.com" policy given;
    };
};

zone "rpz.example.com" {
    type primary;
    file "rpz.db";
};
```

```
; rpz.db — Response Policy Zone
$TTL 300
@   SOA rpz.example.com. hostmaster.example.com. (
    2025010101 3600 900 604800 300 )
    NS  localhost.

; Block specific domain → NXDOMAIN
malware.example.bad    CNAME .

; Redirect to sinkhole
phishing.example.bad   A     10.0.0.1

; Block entire TLD
*.bad                  CNAME .
```

### Monitoring Sinkhole Hits

Log queries hitting the sinkhole IP to identify compromised internal hosts:
```bash
# Capture DNS queries to sinkhole IP
tcpdump -i eth0 dst host 10.0.0.1 -n -l | \
  awk '{print strftime("%Y-%m-%d %H:%M:%S"), $0}'
```

---

## Dynamic DNS (DDNS)

### BIND DDNS with TSIG Authentication

```bash
# Generate TSIG key
tsig-keygen -a hmac-sha256 ddns-key > /etc/bind/ddns-key.conf
```

```
// named.conf
include "/etc/bind/ddns-key.conf";

zone "dyn.example.com" {
    type primary;
    file "zones/db.dyn.example.com";
    allow-update { key ddns-key; };
    journal "zones/db.dyn.example.com.jnl";
};
```

```bash
# Client update using nsupdate
nsupdate -k /etc/bind/ddns-key.conf <<EOF
server ns1.example.com
zone dyn.example.com
update delete myhost.dyn.example.com A
update add myhost.dyn.example.com 300 A 203.0.113.50
send
EOF
```

### Automated DDNS Update Script

```bash
#!/bin/bash
# Update DNS when public IP changes
CURRENT_IP=$(curl -s https://api.ipify.org)
CACHED_IP=$(cat /tmp/last-ip 2>/dev/null)

if [ "$CURRENT_IP" != "$CACHED_IP" ]; then
    nsupdate -k /etc/bind/ddns-key.conf <<EOF
server ns1.example.com
zone dyn.example.com
update delete myhost.dyn.example.com A
update add myhost.dyn.example.com 300 A $CURRENT_IP
send
EOF
    echo "$CURRENT_IP" > /tmp/last-ip
    logger "DDNS updated: myhost.dyn.example.com → $CURRENT_IP"
fi
```

### Security Best Practices

- Use TSIG keys (not IP-based ACLs) for update authentication
- Scope TSIG keys to specific zones/names where possible
- Monitor and audit DDNS update logs
- Set short TTLs (60–300s) for dynamic records
- Prune stale records with automation

---

## DNS Load Balancing Algorithms

### Round-Robin (Multiple Records)

```
app.example.com. 60 IN A 10.0.1.1
app.example.com. 60 IN A 10.0.1.2
app.example.com. 60 IN A 10.0.1.3
```

Resolvers rotate the order. **Not health-aware** — failed backends still receive traffic until TTL expires.

### Weighted (Route 53 / PowerDNS)

```json
// Route 53 weighted routing
{ "SetIdentifier": "backend-1", "Weight": 70, "ResourceRecords": [{"Value": "10.0.1.1"}] }
{ "SetIdentifier": "backend-2", "Weight": 30, "ResourceRecords": [{"Value": "10.0.1.2"}] }
```

### Latency-Based

Route 53 returns the record from the region with lowest latency to the client's resolver.

### Geolocation

Returns records based on client geographic location. Used for:
- CDN endpoint selection
- Data sovereignty / compliance
- Regional content delivery

### Failover

Primary/secondary with health checks. TTL should be ≤ 60s for fast failover.

### Multivalue Answer

Return multiple healthy IPs (up to 8). Each has an independent health check.

---

## Anycast DNS

Anycast uses BGP to announce the same IP prefix from multiple geographic locations. Clients are routed to the nearest node.

### Architecture

```
                    ┌─── Anycast Node (US-East)
                    │    IP: 198.51.100.1
Client ──BGP──→    ├─── Anycast Node (EU-West)
                    │    IP: 198.51.100.1
                    └─── Anycast Node (AP-South)
                         IP: 198.51.100.1
```

### Benefits

- **Low latency:** Clients reach nearest node automatically
- **DDoS resilience:** Attack traffic distributed across all nodes
- **High availability:** Node failure → BGP withdraws route → traffic shifts
- **No client configuration:** Transparent to clients

### Deployment Considerations

- Each node runs independent DNS server (BIND, NSD, Knot DNS)
- Zone data must be synchronized across all nodes (AXFR/IXFR or config management)
- Monitor BGP announcements and DNS health per node
- Use health checks to withdraw BGP when DNS is unhealthy

### Combining with Unicast

Many deployments use anycast for authoritative DNS and unicast for zone transfers:
```
ns-anycast.example.com.  →  198.51.100.1  (anycast, serves queries)
ns-transfer.example.com. →  203.0.113.10  (unicast, zone transfers)
```

---

## DNS Prefetching

### Browser DNS Prefetch

```html
<!-- Hint browser to resolve domains early -->
<link rel="dns-prefetch" href="//cdn.example.com">
<link rel="dns-prefetch" href="//api.example.com">
<link rel="dns-prefetch" href="//fonts.googleapis.com">

<!-- Preconnect (DNS + TCP + TLS) for critical resources -->
<link rel="preconnect" href="https://cdn.example.com">
```

### Resolver-Level Prefetch (Unbound)

```yaml
server:
    prefetch: yes       # Prefetch records about to expire
    prefetch-key: yes   # Prefetch DNSKEY records for DNSSEC
    cache-min-ttl: 0
    cache-max-ttl: 86400
```

When a cached record is queried and has < 10% TTL remaining, Unbound proactively refreshes it before expiry.

### Application-Level Prefetch

```bash
# Warm DNS cache for critical domains
for domain in api.example.com cdn.example.com db.example.com; do
    dig +short "$domain" > /dev/null &
done
wait
```

---

## EDNS Client Subnet

EDNS Client Subnet (ECS, RFC 7871) allows recursive resolvers to send a portion of the client's IP to authoritative servers, enabling geo-aware responses.

### How It Works

```
Client (203.0.113.45) → Resolver → Authoritative
                         Sends: EDNS CLIENT-SUBNET 203.0.113.0/24
                         Gets:  Response scoped to 203.0.113.0/24
```

### Privacy vs Accuracy Trade-off

| Setting | Privacy | Geo-Accuracy |
|---------|---------|-------------|
| ECS disabled | High | Low (resolver location used) |
| ECS /24 (IPv4) | Medium | High |
| ECS /16 (IPv4) | Low | Very high |

### Configuration

**Unbound (disable ECS for privacy):**
```yaml
server:
    module-config: "subnetcache validator iterator"
    client-subnet-always-forward: no
    max-client-subnet-ipv4: 0   # Disable ECS
```

**BIND (send ECS):**
```
options {
    send-cookie yes;
    # ECS support is automatic when using EDNS
};
```

### Checking ECS Support

```bash
# Check if a resolver sends ECS
dig +subnet=203.0.113.0/24 @8.8.8.8 example.com

# Check response includes ECS option
dig +edns +subnet=0.0.0.0/0 @ns1.example.com example.com
```

**Google (8.8.8.8):** Sends ECS by default
**Cloudflare (1.1.1.1):** Does NOT send ECS (privacy-first)
**Quad9 (9.9.9.9):** Does NOT send ECS
