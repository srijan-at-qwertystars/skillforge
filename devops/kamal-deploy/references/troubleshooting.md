# Kamal 2 Troubleshooting Guide

## Table of Contents

- [Container Won't Start](#container-wont-start)
- [Health Check Timeout](#health-check-timeout)
- [SSH Key Issues](#ssh-key-issues)
- [Docker Registry Authentication](#docker-registry-authentication)
- [kamal-proxy Routing Issues](#kamal-proxy-routing-issues)
- [Lock Contention](#lock-contention)
- [Accessory Connection Failures](#accessory-connection-failures)
- [SSL Certificate Issues](#ssl-certificate-issues)
- [Debug Commands Reference](#debug-commands-reference)
- [Log Analysis](#log-analysis)

---

## Container Won't Start

### Symptom
Deploy hangs or fails with "container exited" messages. `kamal app details` shows no running containers.

### Diagnosis

```bash
# Check container status on the server
ssh deploy@server "docker ps -a --filter name=myapp"

# Get exit code and logs from failed container
ssh deploy@server "docker logs \$(docker ps -a --filter name=myapp -q --latest)"

# Check if image was pulled successfully
ssh deploy@server "docker images | grep myapp"
```

### Common Causes and Fixes

**1. Missing environment variables**
```bash
# Verify env vars are set in the container
kamal app exec "env | sort"

# Check .kamal/secrets is populated
cat .kamal/secrets  # Locally — never commit this
```
Fix: Ensure all required env vars are in `deploy.yml` under `env.secret` and defined in `.kamal/secrets`.

**2. Port conflict**
```bash
ssh deploy@server "docker ps --format '{{.Ports}}' | grep 3000"
ssh deploy@server "ss -tlnp | grep 3000"
```
Fix: Kamal manages port allocation via kamal-proxy. Don't expose ports directly in `deploy.yml` 
for web roles — kamal-proxy handles it. Only accessories need explicit `port:` mappings.

**3. Entrypoint/CMD failure**
```bash
# Run container interactively to debug
kamal app exec -i bash
# Or test the CMD directly
kamal app exec "bin/rails server -b 0.0.0.0 -p 3000"
```
Fix: Ensure `Dockerfile` CMD matches what kamal expects. Check that all binaries exist and have execute permission.

**4. Insufficient memory**
```bash
ssh deploy@server "docker stats --no-stream"
ssh deploy@server "free -h"
```
Fix: Add memory limits or upgrade the server:
```yaml
servers:
  web:
    hosts: [10.0.1.10]
    options:
      memory: 1g
```

**5. Volume mount errors**
```bash
ssh deploy@server "docker volume ls"
ssh deploy@server "docker inspect \$(docker ps -a --filter name=myapp -q --latest) | jq '.[0].Mounts'"
```
Fix: Ensure volume paths exist and have correct permissions.

---

## Health Check Timeout

### Symptom
```
ERROR: target failed to become healthy within 30s
```
Deploy aborts, old container continues serving.

### Diagnosis

```bash
# Test health check manually from the server
ssh deploy@server "curl -v http://localhost:3000/up"

# Check if app is actually listening
ssh deploy@server "docker exec \$(docker ps -q --filter name=myapp) curl -s http://localhost:3000/up"

# Watch kamal-proxy logs during deploy
kamal proxy logs -f
```

### Common Causes and Fixes

**1. App port mismatch**
```yaml
# Wrong — app listens on 3000 but proxy checks 80
proxy:
  healthcheck:
    path: /up
    # Missing app_port!

# Correct
proxy:
  app_port: 3000
  healthcheck:
    path: /up
```

**2. Health endpoint returns non-200**
```bash
kamal app exec "curl -sI http://localhost:3000/up"
```
Common causes:
- `force_ssl` redirects `/up` to HTTPS (303 redirect)
- Authentication middleware blocks `/up`
- App crashes during boot

Fix for Rails `force_ssl`:
```ruby
# config/environments/production.rb
config.ssl_options = { redirect: { exclude: ->(req) { req.path == "/up" } } }
```

**3. Slow boot time**
```yaml
proxy:
  healthcheck:
    path: /up
    interval: 5
    timeout: 120    # Give app 2 minutes to boot
```

**4. Database connection required during boot**
If `/up` checks DB connectivity but DB isn't accessible from the new container:
```bash
# Verify container can reach the database
kamal app exec "bin/rails runner 'ActiveRecord::Base.connection.execute(\"SELECT 1\")'"
```
Fix: Ensure `DATABASE_URL` is correct and the database host is accessible from the Docker network.

**5. DNS resolution in container**
```bash
kamal app exec "cat /etc/resolv.conf"
kamal app exec "nslookup db.example.com"
```

---

## SSH Key Issues

### Symptom
```
Permission denied (publickey)
Net::SSH::AuthenticationFailed
```

### Diagnosis

```bash
# Test SSH manually
ssh -v deploy@server

# Check which keys are offered
ssh -v deploy@server 2>&1 | grep "Offering"

# Verify key is loaded in agent
ssh-add -l
```

### Common Causes and Fixes

**1. Wrong SSH user**
```yaml
ssh:
  user: deploy     # Must match server user, default is root
```

**2. Key not in agent**
```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```
In CI (GitHub Actions):
```yaml
- uses: webfactory/ssh-agent@v0.9.0
  with:
    ssh-private-key: ${{ secrets.SSH_DEPLOY_KEY }}
```

**3. Server not accepting the key**
```bash
# On the server, check authorized_keys
cat ~/.ssh/authorized_keys

# Check SSH daemon logs
sudo journalctl -u ssh -n 50

# Verify permissions (must be strict)
ls -la ~/.ssh/
# drwx------ .ssh
# -rw------- authorized_keys
```
Fix: `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`

**4. Jump host / bastion required**
```yaml
ssh:
  user: deploy
  proxy: bastion.example.com
  proxy_command: "ssh -W %h:%p bastion_user@bastion.example.com"
```

**5. Non-standard SSH port**
```yaml
ssh:
  port: 2222
```

---

## Docker Registry Authentication

### Symptom
```
ERROR: denied: access forbidden
unauthorized: authentication required
```

### Diagnosis

```bash
# Test registry login locally
docker login ghcr.io -u USERNAME

# Check Kamal's resolved config
kamal config | grep -A5 registry

# Verify secret is set
echo $KAMAL_REGISTRY_PASSWORD | head -c 5
```

### Common Causes and Fixes

**1. Expired token**
Regenerate the token/PAT and update `.kamal/secrets`:
```bash
# GitHub Container Registry — needs packages:write scope
KAMAL_REGISTRY_PASSWORD=ghp_xxxxxxxxxxxxxxxxxxxx
```

**2. Wrong registry server**
```yaml
registry:
  server: ghcr.io              # GitHub
  # server: registry.digitalocean.com  # DigitalOcean
  # server: ""                  # Docker Hub (leave blank or omit)
  username: deployer
  password:
    - KAMAL_REGISTRY_PASSWORD
```

**3. Docker Hub rate limits**
```bash
# Check remaining pulls
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/alpine:pull" | jq -r .token)
curl -sI -H "Authorization: Bearer $TOKEN" https://registry-1.docker.io/v2/library/alpine/manifests/latest | grep ratelimit
```
Fix: Use authenticated pulls or switch to GHCR/private registry.

**4. Registry auth not propagated to servers**
Kamal runs `docker login` on each server during deploy. If it fails:
```bash
ssh deploy@server "docker login ghcr.io -u deployer -p TOKEN"
```
Check that the deploy user has Docker permissions: `ssh deploy@server "docker info"`.

---

## kamal-proxy Routing Issues

### Symptom
- 502 Bad Gateway
- 404 Not Found
- Requests going to wrong app
- Blank page

### Diagnosis

```bash
# Check proxy status
kamal proxy details

# View proxy logs
kamal proxy logs -n 100

# Check proxy configuration on server
ssh deploy@server "docker exec kamal-proxy kamal-proxy status"

# Test routing from server
ssh deploy@server "curl -H 'Host: myapp.example.com' http://localhost"
```

### Common Causes and Fixes

**1. Proxy not running**
```bash
kamal proxy reboot
```

**2. App container not registered with proxy**
```bash
# Check what the proxy knows about
ssh deploy@server "docker exec kamal-proxy kamal-proxy list"

# Force re-registration
kamal app boot
```

**3. Host header mismatch**
```yaml
proxy:
  host: myapp.example.com   # Must match incoming Host header exactly
```
If using Cloudflare or external LB, ensure it forwards the original Host header.

**4. Wrong app_port**
```yaml
proxy:
  app_port: 3000   # Must match what your app actually listens on
```

**5. forward_headers misconfiguration**
When behind an external load balancer:
```yaml
proxy:
  forward_headers: true   # Pass X-Forwarded-For, X-Forwarded-Proto
```

---

## Lock Contention

### Symptom
```
ERROR: Deploy lock already held
Locked by: user@host at 2024-01-15 10:30:00 UTC
```

### Diagnosis

```bash
kamal lock status
```

### Common Causes and Fixes

**1. Previous deploy failed or was interrupted**
```bash
kamal lock release
kamal deploy
```

**2. Concurrent deploy from CI**
Prevent with CI concurrency groups:
```yaml
# GitHub Actions
concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false    # Don't cancel running deploys
```

**3. Stale lock**
```bash
# Force release (use with caution)
kamal lock release --force

# Or manually on server
ssh deploy@server "rm -rf /tmp/kamal-lock-myapp"
```

**4. Multi-user deploy coordination**
```bash
kamal lock acquire -m "Deploying v1.2.3 - @username"
# ... deploy ...
kamal lock release
```

---

## Accessory Connection Failures

### Symptom
App container can't connect to database/Redis/other accessories.

### Diagnosis

```bash
# Check accessory is running
kamal accessory details db

# Get accessory container IP
ssh deploy@server "docker inspect myapp-db | jq '.[0].NetworkSettings.Networks'"

# Test connectivity from app container
kamal app exec "nc -zv myapp-db 5432"
```

### Common Causes and Fixes

**1. Accessory not booted**
```bash
kamal accessory boot db
```

**2. Wrong hostname in DATABASE_URL**
The accessory container name follows the pattern `<service>-<accessory_name>`.
```bash
# If service=myapp, accessory=db, the container is "myapp-db"
DATABASE_URL=postgres://postgres:password@myapp-db:5432/myapp_production
```

**3. Docker network mismatch**
App and accessory must be on the same Docker network. Kamal handles this automatically
but verify:
```bash
ssh deploy@server "docker network ls"
ssh deploy@server "docker network inspect kamal"
```

**4. Port binding conflicts**
```yaml
accessories:
  db:
    port: "5432:5432"   # host_port:container_port
```
Check for conflicts: `ssh deploy@server "ss -tlnp | grep 5432"`

**5. Accessory data volume lost**
Always use named volumes:
```yaml
accessories:
  db:
    volumes:
      - "db_data:/var/lib/postgresql/data"   # Named — survives remove
      # NOT: "./data:/var/lib/postgresql/data"  # Bind mount — risky
```

---

## SSL Certificate Issues

### Symptom
- Browser shows "Not Secure" or certificate error
- `ERR_SSL_PROTOCOL_ERROR`
- Let's Encrypt challenge fails

### Diagnosis

```bash
# Check cert details
echo | openssl s_client -connect myapp.example.com:443 2>/dev/null | openssl x509 -noout -dates -subject

# Check kamal-proxy logs for ACME errors
kamal proxy logs | grep -i "acme\|cert\|ssl\|tls"

# Verify port 80 is open (required for HTTP-01 challenge)
curl -v http://myapp.example.com/.well-known/acme-challenge/test
```

### Common Causes and Fixes

**1. DNS not pointing to server**
```bash
dig +short myapp.example.com
# Must return your server's IP
```
Fix: Create/update DNS A record. Wait for propagation before deploying.

**2. Port 80 blocked**
Let's Encrypt HTTP-01 challenge requires port 80.
```bash
ssh deploy@server "sudo ufw status"
ssh deploy@server "sudo ufw allow 80/tcp"
```

**3. Too many certificate requests (rate limit)**
Let's Encrypt rate limits: 5 duplicate certs per week, 50 certs per domain per week.
Fix: Wait, or use staging environment for testing:
```bash
# Test with Let's Encrypt staging (not in kamal-proxy directly)
# Use custom cert for testing instead
```

**4. Cloudflare proxy interfering**
If using Cloudflare with "Full (Strict)" mode:
- Set Cloudflare SSL to "Full" (not strict) initially
- Or upload a Cloudflare Origin CA cert as custom cert
- Ensure Cloudflare passes the correct Host header

**5. Multiple hosts, single cert**
```yaml
proxy:
  hosts:
    - myapp.example.com
    - www.myapp.example.com
  ssl: true
```
Both domains must resolve to the server before first deploy.

---

## Debug Commands Reference

### Quick Diagnostic Sequence

```bash
# 1. What's the current state?
kamal details                     # All containers, proxy, accessories

# 2. What went wrong?
kamal app logs -n 200             # Last 200 log lines
kamal proxy logs -n 100           # Proxy logs

# 3. Is the app responding?
kamal app exec "curl -s localhost:3000/up"

# 4. What's the config?
kamal config                      # Resolved configuration

# 5. Server-level checks
ssh deploy@server "docker ps -a"
ssh deploy@server "docker stats --no-stream"
ssh deploy@server "df -h"
ssh deploy@server "free -h"
```

### Container Inspection

```bash
# Full container details
ssh deploy@server "docker inspect \$(docker ps -q --filter name=myapp-web) | jq '.[0].State'"

# Environment variables in running container
ssh deploy@server "docker exec \$(docker ps -q --filter name=myapp-web) env | sort"

# File system check
kamal app exec "ls -la /rails/public/assets"

# Process list
kamal app exec "ps aux"
```

### Network Debugging

```bash
# DNS resolution from container
kamal app exec "nslookup myapp-db"

# Port connectivity
kamal app exec "nc -zv myapp-db 5432"
kamal app exec "nc -zv myapp-redis 6379"

# HTTP check to self
kamal app exec "curl -sI http://localhost:3000/up"
```

---

## Log Analysis

### Filtering Kamal Logs

```bash
# App logs filtered by severity
kamal app logs -n 500 | grep -E "ERROR|FATAL|Exception"

# Proxy logs for specific host
kamal proxy logs | grep "myapp.example.com"

# Accessory logs
kamal accessory logs db -n 100

# Follow logs in real-time during deploy
kamal app logs -f &
kamal proxy logs -f &
kamal deploy
```

### Server-Level Log Locations

```bash
# Docker daemon logs
ssh deploy@server "sudo journalctl -u docker -n 100"

# kamal-proxy container logs
ssh deploy@server "docker logs kamal-proxy --tail 200"

# System resource logs
ssh deploy@server "dmesg | tail -50"   # OOM killer, disk errors
```

### Common Log Patterns

| Log Pattern | Meaning | Action |
|---|---|---|
| `target failed to become healthy` | Health check timeout | Check `/up` endpoint, increase timeout |
| `connection refused` | App not listening | Check port, CMD, boot errors |
| `OOM killed` | Out of memory | Increase server RAM or set memory limits |
| `permission denied` | File/socket permissions | Check volume mounts, user permissions |
| `ACME challenge failed` | SSL cert issue | Check DNS, port 80 access |
| `no such host` | DNS resolution failure | Check Docker network, container names |
| `lock already held` | Concurrent deploy | Release lock: `kamal lock release` |
| `unauthorized` | Registry auth failure | Check registry credentials |

### Structured Log Queries

If shipping logs to a centralized system, tag Kamal containers:
```yaml
servers:
  web:
    hosts: [10.0.1.10]
    options:
      log-driver: json-file
      log-opt: "max-size=50m"
      log-opt: "max-file=3"
      label: "app=myapp,env=production,role=web"
```
