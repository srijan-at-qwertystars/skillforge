# Caddy v2 Troubleshooting Guide

## Table of Contents

- [Certificate Provisioning Failures](#certificate-provisioning-failures)
- [ACME Challenges Behind Proxies and Firewalls](#acme-challenges-behind-proxies-and-firewalls)
- ["Too Many Certificates" Rate Limits](#too-many-certificates-rate-limits)
- [WebSocket Proxy Issues](#websocket-proxy-issues)
- [Large File Upload Timeouts](#large-file-upload-timeouts)
- [Redirect Loops](#redirect-loops)
- [Caddyfile Parse Errors](#caddyfile-parse-errors)
- [JSON API Conflicts with Caddyfile](#json-api-conflicts-with-caddyfile)
- [Systemd Permission Issues](#systemd-permission-issues)
- [Docker Networking Gotchas](#docker-networking-gotchas)
- [Diagnostic Commands Reference](#diagnostic-commands-reference)

---

## Certificate Provisioning Failures

### Symptoms

- `tls.obtain` errors in logs
- Sites serving Caddy's default certificate instead of a valid one
- `ERR_CERT_AUTHORITY_INVALID` in browser

### Common Causes and Fixes

**1. DNS not pointing to server**

```bash
# Verify DNS resolution
dig +short example.com
# Must return the IP of the machine running Caddy

# Check from Let's Encrypt's perspective
curl -s https://dns.google/resolve?name=example.com&type=A | jq
```

**2. Ports 80/443 not reachable**

```bash
# Check if Caddy is listening
ss -tlnp | grep -E ':(80|443)\s'

# Test from outside
curl -v http://example.com/.well-known/acme-challenge/test
```

**3. Another process holding ports**

```bash
# Find what's using port 80
sudo lsof -i :80
# Kill or stop the conflicting service before starting Caddy
```

**4. Firewall blocking**

```bash
# UFW
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# firewalld
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload

# iptables
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
```

**5. Use staging CA for testing**

```caddyfile
{
    acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}
```

Always test with staging first to avoid hitting production rate limits.

**6. Check certificate storage**

```bash
# Default storage location
ls -la ~/.local/share/caddy/certificates/
# Systemd installations
ls -la /var/lib/caddy/.local/share/caddy/certificates/
```

---

## ACME Challenges Behind Proxies and Firewalls

### HTTP-01 Challenge Failures

The HTTP-01 challenge requires Let's Encrypt to reach `http://yourdomain/.well-known/acme-challenge/<token>` on port 80.

**Behind a load balancer (AWS ALB, Cloudflare, etc.):**

```
Problem: LB terminates TLS and may not forward port 80 correctly.
Solution 1: Configure LB to pass port 80 traffic to Caddy unchanged.
Solution 2: Use DNS-01 challenge instead.
```

**Behind Cloudflare proxy (orange cloud):**

```caddyfile
# Option 1: Use DNS challenge (recommended)
example.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy localhost:8080
}

# Option 2: Temporarily grey-cloud the DNS record for initial issuance
# Then re-enable Cloudflare proxy
```

### TLS-ALPN-01 Challenge Failures

Requires port 443 to be directly reachable. Fails if any upstream proxy terminates TLS before Caddy.

### DNS-01 Challenge (Most Reliable Behind Proxies)

```bash
# Build Caddy with your DNS provider
xcaddy build --with github.com/caddy-dns/cloudflare
```

```caddyfile
example.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
}
```

**Common DNS providers:**
- `github.com/caddy-dns/cloudflare`
- `github.com/caddy-dns/route53`
- `github.com/caddy-dns/googleclouddns`
- `github.com/caddy-dns/digitalocean`
- `github.com/caddy-dns/namecheap`
- `github.com/caddy-dns/duckdns`

### Debugging ACME Issues

```bash
# Enable debug logging
caddy run --config Caddyfile --environ 2>&1 | grep -i acme

# Or set debug in Caddyfile
{
    debug
}
```

Look for these log patterns:
- `certificate obtained successfully` — working
- `challenge failed` — network/DNS issue
- `rate limited` — hit CA rate limits
- `no solvers available` — missing DNS module or port blocked

---

## "Too Many Certificates" Rate Limits

### Let's Encrypt Rate Limits

| Limit | Value | Window |
|---|---|---|
| Certificates per Registered Domain | 50 | 7 days |
| Duplicate Certificate | 5 | 7 days |
| Failed Validation | 5 | 1 hour |
| New Orders | 300 | 3 hours |
| Accounts per IP | 10 | 3 hours |

### Symptoms

- Log: `too many certificates already issued for exact set of domains`
- Log: `too many failed authorizations recently`
- New sites fail to get certificates while existing ones work

### Mitigation Strategies

**1. Use staging for development/testing**

```caddyfile
{
    acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}
```

**2. Use ZeroSSL as fallback issuer**

Caddy automatically falls back to ZeroSSL, but you can configure it explicitly:

```caddyfile
{
    cert_issuer zerossl {env.ZEROSSL_API_KEY}
}
```

**3. Use wildcard certificates**

A single `*.example.com` cert covers unlimited subdomains:

```caddyfile
*.example.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
}
```

**4. Persist certificate storage**

Never use ephemeral volumes for `/data` in Docker. Losing certs means re-requesting them, which burns rate limits.

```yaml
volumes:
  - caddy_data:/data       # MUST be persistent
```

**5. Check current rate limit status**

```bash
# Check how many certs issued for your domain
curl -s "https://crt.sh/?q=%.example.com&output=json" | jq '.[].not_before' | sort | tail -20
```

---

## WebSocket Proxy Issues

### Symptoms

- WebSocket connections fail with 502 or timeout
- Connections drop after 30-60 seconds
- `Error during WebSocket handshake` in browser console

### Common Fixes

**1. Caddy proxies WebSocket transparently** — no special headers config needed:

```caddyfile
# This is usually sufficient
reverse_proxy localhost:9090
```

**2. Long-lived connections timing out**

```caddyfile
reverse_proxy /ws/* localhost:9090 {
    transport http {
        keepalive off
        read_timeout 0      # no timeout
        write_timeout 0     # no timeout
    }
}
```

**3. Behind another proxy (double-proxy)**

If Caddy is behind nginx/HAProxy, ensure the upstream proxy also forwards WebSocket headers:

```nginx
# Nginx upstream config must include:
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

**4. SSE (Server-Sent Events) buffering**

```caddyfile
reverse_proxy /events/* localhost:8080 {
    flush_interval -1    # disable buffering, flush immediately
}
```

**5. Docker networking — container name resolution**

```caddyfile
# Use Docker service names, not localhost
reverse_proxy ws-service:9090
```

### Debugging WebSocket Issues

```bash
# Test WebSocket connectivity
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGVzdA==" \
  http://localhost/ws/

# Check Caddy logs for upstream errors
journalctl -u caddy --no-pager | grep -i "websocket\|upgrade\|502"
```

---

## Large File Upload Timeouts

### Symptoms

- Large uploads fail with 408 or 502
- Uploads stall and eventually timeout
- `context deadline exceeded` in Caddy logs

### Fixes

**1. Increase request body limit**

```caddyfile
example.com {
    request_body {
        max_size 500MB
    }
    reverse_proxy localhost:8080
}
```

**2. Increase proxy timeouts**

```caddyfile
reverse_proxy localhost:8080 {
    transport http {
        read_timeout 300s
        write_timeout 300s
        dial_timeout 10s
        response_header_timeout 300s
    }
}
```

**3. For very large uploads (multi-GB)**

```caddyfile
example.com {
    request_body {
        max_size 0    # no limit (use with caution)
    }
    reverse_proxy localhost:8080 {
        transport http {
            read_timeout 0     # no timeout
            write_timeout 0    # no timeout
        }
    }
}
```

**4. Client-side timeouts (browser)**

Caddy handles keep-alive and chunked encoding automatically. If you see browser timeouts, the issue is usually in the backend application, not Caddy.

---

## Redirect Loops

### Symptoms

- Browser: `ERR_TOO_MANY_REDIRECTS`
- `curl -L` follows redirects endlessly

### Common Causes

**1. Cloudflare "Flexible" SSL mode**

Cloudflare connects to origin over HTTP → Caddy redirects to HTTPS → Cloudflare connects over HTTP → loop.

**Fix**: Set Cloudflare SSL mode to **"Full (Strict)"**.

**2. Upstream app generates HTTP redirect**

The backend returns `Location: http://example.com/...` — Caddy re-redirects to HTTPS.

```caddyfile
reverse_proxy localhost:8080 {
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-For {remote_host}
}
```

Configure your app to trust `X-Forwarded-Proto` header.

**3. Conflicting www/non-www redirects**

```caddyfile
# WRONG: creates a loop if both point to each other
example.com {
    redir https://www.example.com{uri}
}
www.example.com {
    redir https://example.com{uri}
}

# RIGHT: choose one canonical form
www.example.com {
    redir https://example.com{uri} permanent
}
example.com {
    reverse_proxy localhost:8080
}
```

**4. Multiple Caddy instances or proxy layers**

Each layer adds its own HTTP→HTTPS redirect. Solution: only the outermost proxy should handle TLS.

### Debugging Redirects

```bash
# Follow redirects verbose
curl -vL --max-redirs 5 http://example.com/ 2>&1 | grep -E "< HTTP|< Location"
```

---

## Caddyfile Parse Errors

### Common Parse Errors

**1. Missing closing brace**

```
Error: Caddyfile:15 - Error during parsing: unexpected end of file
```

Every `{` needs a matching `}`. Check nested blocks.

**2. Directive outside site block**

```
Error: Caddyfile:3 - Error during parsing: reverse_proxy is not allowed in the global options block
```

Directives like `reverse_proxy`, `file_server`, etc. must be inside a site block.

**3. Wrong placeholder syntax**

```caddyfile
# WRONG
header X-Real-IP $remote_host
# RIGHT
header X-Real-IP {remote_host}
```

Caddy uses `{placeholder}`, not `$variable`.

**4. Tab/space indentation issues**

Caddy doesn't care about indentation, but inconsistent use can cause confusion. Use consistent spacing.

**5. Invalid global option**

```caddyfile
# WRONG — directives in global block
{
    reverse_proxy localhost:8080
}

# RIGHT — only global options in global block
{
    email admin@example.com
    admin off
}
```

**6. Conflicting site addresses**

```caddyfile
# WRONG — same address in two blocks
:443 {
    reverse_proxy localhost:3000
}
:443 {
    file_server
}

# RIGHT — combine into one block
:443 {
    handle /api/* { reverse_proxy localhost:3000 }
    handle { file_server }
}
```

### Validation

```bash
# Always validate before reload
caddy validate --config /etc/caddy/Caddyfile

# Adapt to JSON to inspect parsed structure
caddy adapt --config /etc/caddy/Caddyfile --pretty

# Format the Caddyfile (fix whitespace issues)
caddy fmt --overwrite /etc/caddy/Caddyfile
```

---

## JSON API Conflicts with Caddyfile

### The Problem

Caddy can be configured via Caddyfile OR JSON API, but not both simultaneously. Loading config via the API replaces whatever was loaded from the Caddyfile.

### Symptoms

- Changes via API (`curl -X POST localhost:2019/load`) disappear after `systemctl reload caddy`
- Caddyfile changes don't apply because API-loaded config takes precedence
- Inconsistent behavior between restarts and reloads

### Resolution

**Pick one config method and stick with it:**

**Option A: Caddyfile only (recommended for most users)**

```bash
# Always use systemctl or caddy reload
sudo systemctl reload caddy
# or
caddy reload --config /etc/caddy/Caddyfile
```

**Option B: JSON API only**

```bash
# Load config via API
caddy run --resume    # load last-used config

# Push new config
curl -X POST http://localhost:2019/load \
  -H "Content-Type: application/json" \
  -d @caddy.json
```

**Option C: Caddyfile adapted to JSON, managed via API**

```bash
# Convert Caddyfile to JSON
caddy adapt --config Caddyfile --pretty > caddy.json

# Load via API
curl -X POST http://localhost:2019/load \
  -H "Content-Type: application/json" \
  -d @caddy.json
```

### Securing the Admin API

```caddyfile
# Disable entirely (use Caddyfile + systemctl reload)
{
    admin off
}

# Unix socket only (more secure than TCP)
{
    admin unix//run/caddy/admin.sock
}

# Restrict to localhost with custom port
{
    admin localhost:2019
}
```

**Never expose `:2019` to the network** — it allows full config replacement with no authentication.

---

## Systemd Permission Issues

### Common Errors

**1. Can't bind to ports 80/443**

```
Error: loading initial config: listening on :443: listen tcp :443: bind: permission denied
```

Fix:

```bash
# Option A: Grant capability (recommended)
sudo setcap cap_net_bind_service=+ep /usr/bin/caddy

# Option B: Use systemd capability (in unit file)
# [Service]
# AmbientCapabilities=CAP_NET_BIND_SERVICE
# CapabilityBoundingSet=CAP_NET_BIND_SERVICE
```

**2. Can't read Caddyfile**

```
Error: loading config: open /etc/caddy/Caddyfile: permission denied
```

```bash
sudo chown root:caddy /etc/caddy/Caddyfile
sudo chmod 640 /etc/caddy/Caddyfile
```

**3. Can't write to data directory**

```bash
sudo mkdir -p /var/lib/caddy/.local/share/caddy
sudo chown -R caddy:caddy /var/lib/caddy
sudo chmod 700 /var/lib/caddy
```

**4. Can't write to log directory**

```bash
sudo mkdir -p /var/log/caddy
sudo chown caddy:caddy /var/log/caddy
sudo chmod 755 /var/log/caddy
```

**5. SELinux blocking access**

```bash
# Check for SELinux denials
sudo ausearch -m avc -c caddy

# Allow Caddy to bind to HTTP ports
sudo setsebool -P httpd_can_network_connect 1

# Or create a custom policy
sudo audit2allow -a -M caddy-custom
sudo semodule -i caddy-custom.pp
```

### Recommended Systemd Overrides

```bash
sudo systemctl edit caddy
```

```ini
[Service]
# Increase file descriptor limit
LimitNOFILE=1048576

# Increase process limit
LimitNPROC=512

# Environment variables
Environment=CF_API_TOKEN=your-token-here
EnvironmentFile=/etc/caddy/environment

# Restart policy
Restart=on-failure
RestartSec=5s
```

---

## Docker Networking Gotchas

### Problem 1: Can't Reach Host Services

```caddyfile
# WRONG — localhost inside container is the container itself
reverse_proxy localhost:8080

# RIGHT — use host.docker.internal (with extra_hosts on Linux)
reverse_proxy host.docker.internal:8080
```

Docker Compose:

```yaml
services:
  caddy:
    image: caddy:2-alpine
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

### Problem 2: Container Name Resolution

```caddyfile
# Containers must be on the same Docker network
reverse_proxy app:3000    # service name from docker-compose.yml
```

Verify:

```bash
docker network inspect <network_name>
# Check both containers are listed
```

### Problem 3: Certificate Storage Lost

```yaml
# WRONG — anonymous volume (lost on docker compose down)
volumes:
  - /data

# RIGHT — named volume (persists across recreates)
volumes:
  - caddy_data:/data

volumes:
  caddy_data:
    external: false
```

### Problem 4: Port Conflicts with Host

```bash
# Check if host already uses port 80/443
ss -tlnp | grep -E ':(80|443)\s'

# Stop conflicting services
sudo systemctl stop nginx apache2
```

### Problem 5: ACME Challenges in Docker

- Ports 80 and 443 must be published to the host: `ports: ["80:80", "443:443"]`
- The container must have outbound internet access
- DNS must resolve to the Docker host's public IP
- If using host networking (`network_mode: host`), Caddy binds directly — simpler but less isolated

### Problem 6: Environment Variables Not Passed

```yaml
# Method 1: Direct
environment:
  - CF_API_TOKEN=abc123

# Method 2: .env file
env_file:
  - ./caddy.env

# Method 3: Docker secrets (Swarm)
secrets:
  cf_token:
    external: true
```

### Problem 7: HTTP/3 (QUIC) Not Working

```yaml
ports:
  - "80:80"
  - "443:443"
  - "443:443/udp"    # Required for HTTP/3
```

UDP port 443 must also be published for QUIC/HTTP/3.

---

## Diagnostic Commands Reference

```bash
# Validate config before applying
caddy validate --config /etc/caddy/Caddyfile

# Format Caddyfile
caddy fmt --overwrite /etc/caddy/Caddyfile

# Convert Caddyfile to JSON (debug parsed config)
caddy adapt --config /etc/caddy/Caddyfile --pretty

# List loaded modules
caddy list-modules

# Check running config via API
curl -s http://localhost:2019/config/ | jq .

# View certificate details
curl -s http://localhost:2019/config/apps/tls/certificates | jq .

# Force certificate renewal
curl -X POST http://localhost:2019/config/apps/tls/automation/renew \
  -H "Content-Type: application/json" \
  -d '{"domain":"example.com"}'

# Caddy version and build info
caddy version
caddy build-info

# Check systemd status
systemctl status caddy
journalctl -u caddy --no-pager -n 50

# Follow logs in real time
journalctl -u caddy -f

# Test TLS certificate from outside
openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | \
  openssl x509 -noout -dates -subject -issuer

# Check OCSP stapling
openssl s_client -connect example.com:443 -status 2>/dev/null | grep -A3 "OCSP Response"

# DNS resolution check
dig +short example.com A
dig +short example.com AAAA

# Port reachability
nc -zv example.com 80
nc -zv example.com 443
```
