# dig Command Cheatsheet

## Basic Queries

```bash
# Simple lookup (A record)
dig example.com

# Short output (just the answer)
dig +short example.com
# → 93.184.216.34

# Query specific record type
dig example.com MX
dig example.com AAAA
dig example.com NS
dig example.com TXT
dig example.com SOA
dig example.com CAA
dig example.com SRV
dig example.com CNAME

# Query ANY (all record types — may be limited by server)
dig example.com ANY
```

## Controlling Output

```bash
# Short answer only
dig +short example.com

# Answer section only
dig +noall +answer example.com

# Answer + authority + additional sections
dig +noall +answer +authority +additional example.com

# Full output with comments
dig +multiline +noall +answer +authority +comments example.com

# Just the status code
dig +noall +comments example.com | grep status
# → ;; ->>HEADER<<- opcode: QUERY, status: NOERROR

# Suppress all output, just check return code
dig +short example.com > /dev/null 2>&1 && echo "OK" || echo "FAILED"
```

## Querying Specific Servers

```bash
# Query Google's resolver
dig @8.8.8.8 example.com

# Query Cloudflare
dig @1.1.1.1 example.com

# Query Quad9
dig @9.9.9.9 example.com

# Query authoritative nameserver directly (bypass cache)
dig @ns1.example.com example.com +norecurse

# Find and query authoritative NS
dig @$(dig +short NS example.com | head -1) example.com
```

## Tracing & Debugging

```bash
# Trace full resolution path (root → TLD → authoritative)
dig +trace example.com
# Shows each delegation step, useful for finding where resolution breaks

# Show query time and server info
dig example.com | grep -E "Query time|SERVER"
# → ;; Query time: 23 msec
# → ;; SERVER: 8.8.8.8#53(8.8.8.8)

# Check TTL remaining
dig +noall +answer example.com | awk '{print $1, "TTL:", $2}'

# TCP mode (for large responses or when UDP fails)
dig +tcp example.com

# Set timeout and retries
dig +time=5 +tries=2 example.com
```

## DNSSEC

```bash
# Query with DNSSEC data (shows RRSIG records)
dig +dnssec example.com

# Check if DNSSEC validates (look for 'ad' flag)
dig +dnssec example.com | grep flags
# flags: qr rd ra ad → 'ad' = Authenticated Data (DNSSEC valid)

# Disable DNSSEC validation (check if SERVFAIL is DNSSEC-related)
dig +cd example.com
# If +cd works but normal query SERVFAIL → DNSSEC is broken

# Get DNSKEY records
dig example.com DNSKEY +short

# Get DS records (at parent)
dig example.com DS +short

# Check NSEC/NSEC3 (authenticated denial of existence)
dig nonexistent.example.com +dnssec +noall +authority
```

## Reverse DNS

```bash
# Reverse lookup (PTR)
dig -x 8.8.8.8
# → dns.google.

dig -x 8.8.8.8 +short
# → dns.google.

# IPv6 reverse lookup
dig -x 2001:4860:4860::8888 +short
```

## Email DNS Records

```bash
# Check SPF
dig +short TXT example.com | grep "v=spf1"

# Check DKIM (replace 'selector' with actual selector name)
dig +short TXT selector._domainkey.example.com
dig +short TXT google._domainkey.example.com
dig +short TXT selector1._domainkey.example.com

# Check DMARC
dig +short TXT _dmarc.example.com

# Check MTA-STS
dig +short TXT _mta-sts.example.com

# Check TLS-RPT
dig +short TXT _smtp._tls.example.com

# Check BIMI
dig +short TXT default._bimi.example.com

# Full email DNS audit (one-liner)
D=example.com; for r in "MX $D" "TXT $D" "TXT _dmarc.$D" "TXT _mta-sts.$D" "TXT _smtp._tls.$D"; do echo "--- $r ---"; dig +short $r; done
```

## Batch & Scripting

```bash
# Check multiple domains
for d in example.com example.org example.net; do
    echo "$d: $(dig +short $d)"
done

# Check propagation across resolvers
for ns in 8.8.8.8 1.1.1.1 9.9.9.9 208.67.222.222; do
    echo "=== $ns ===" && dig @$ns +short example.com A
done

# Monitor TTL countdown
watch -n 10 'dig +noall +answer example.com | awk "{print \$1, \"TTL:\", \$2}"'

# Extract just IPs from dig output
dig +short example.com A | grep -E '^[0-9]'

# Check if record matches expected value
EXPECTED="93.184.216.34"
ACTUAL=$(dig +short example.com A)
[ "$ACTUAL" = "$EXPECTED" ] && echo "MATCH" || echo "MISMATCH: got $ACTUAL"
```

## Output Interpretation

### Response Header Flags

```
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

qr  = Query Response (this is a response, not a query)
rd  = Recursion Desired (client asked for recursion)
ra  = Recursion Available (server supports recursion)
ad  = Authenticated Data (DNSSEC validated)
aa  = Authoritative Answer (server is authoritative for this zone)
tc  = Truncated (response too large for UDP, retry with TCP)
cd  = Checking Disabled (DNSSEC validation skipped)
```

### Response Status Codes

```
NOERROR   — Success (answer may still be empty = NODATA)
NXDOMAIN  — Domain name does not exist
SERVFAIL  — Server failed (DNSSEC issue, timeout, etc.)
REFUSED   — Server refuses to answer (ACL, no recursion)
FORMERR   — Malformed query (EDNS issues, etc.)
NOTIMP    — Not implemented (query type not supported)
```

### Answer Section Format

```
;; ANSWER SECTION:
example.com.        3600    IN    A    93.184.216.34
│                   │       │     │    │
└─ Name             │       │     │    └─ Record Data
                    │       │     └─ Record Type
                    │       └─ Class (always IN for Internet)
                    └─ TTL in seconds (time remaining in cache)
```

## Less Common But Useful

```bash
# EDNS buffer size
dig +bufsize=4096 example.com

# Disable EDNS (for compatibility testing)
dig +noedns example.com

# Query over DNS-over-HTTPS (using curl)
curl -s -H 'accept: application/dns-json' \
  'https://cloudflare-dns.com/dns-query?name=example.com&type=A' | jq

# Query over DNS-over-TLS (using kdig from knot-dnsutils)
kdig -d @1.1.1.1 +tls-ca +tls-hostname=cloudflare-dns.com example.com

# Zone transfer (if permitted)
dig @ns1.example.com example.com AXFR

# Query with subnet hint (EDNS Client Subnet)
dig +subnet=203.0.113.0/24 @8.8.8.8 example.com

# Check NSID (Name Server ID) for debugging anycast
dig +nsid example.com @8.8.8.8
```
