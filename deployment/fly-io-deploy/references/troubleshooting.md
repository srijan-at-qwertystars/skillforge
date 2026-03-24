# Fly.io Troubleshooting Guide

## Table of Contents
1. [Deployment Failures](#deployment-failures)
2. [Health Check Timeouts](#health-check-timeouts)
3. [Machine Not Starting](#machine-not-starting)
4. [Volume Attachment Errors](#volume-attachment-errors)
5. [DNS Resolution in Private Networking](#dns-resolution-in-private-networking)
6. [Certificate Provisioning Delays](#certificate-provisioning-delays)
7. [Connection Timeouts Across Regions](#connection-timeouts-across-regions)
8. [OOM Kills](#oom-kills)
9. [Disk Space Exhaustion](#disk-space-exhaustion)
10. [Postgres Failover Issues](#postgres-failover-issues)
11. [Slow Cold Starts](#slow-cold-starts)
12. [Deploy Rollback](#deploy-rollback)
13. [WireGuard Tunnel Issues](#wireguard-tunnel-issues)
14. [Billing Surprises](#billing-surprises)

---

## Deployment Failures

### Symptoms
- `fly deploy` exits with error.
- Machines fail to start after deploy.
- Release command fails.

### Diagnosis

```bash
fly logs --no-tail                          # Check recent logs
fly status                                  # Machine states
fly releases                                # List recent releases
fly machine status <machine-id>             # Specific machine details
```

### Common Causes & Fixes

**Build failure (Dockerfile error)**
```
Error: failed to build: exit code 1
```
Fix: Test build locally first: `docker build -t test .`. Check multi-stage COPY paths, missing dependencies, and build args.

**Release command failure**
```
Error: release command failed - Loss of leadership
```
Fix:
- The release command runs in a temporary Machine. It must exit 0.
- Check that DATABASE_URL is set: `fly secrets list`.
- Increase timeout: `fly deploy --wait-timeout 300`.
- Test locally: `fly ssh console -C "bin/rails db:migrate:status"`.

**Image push failure**
```
Error: failed to push image
```
Fix: Ensure you're authenticated (`fly auth token`). Try `fly deploy --remote-only` to build on Fly's builders instead of pushing from local.

**Machine replacement stuck**
```
Machines are not reaching a stable "started" state
```
Fix:
- Check `fly logs` for crash loops.
- Verify `internal_port` matches your app's listen port.
- Increase `[http_service.checks]` `grace_period` for slow-starting apps.
- Try `fly deploy --strategy immediate` to force replacement.

---

## Health Check Timeouts

### Symptoms
- Deployment hangs at "Waiting for health checks".
- Machines start then immediately stop.
- `fly checks list` shows failing checks.

### Diagnosis

```bash
fly checks list                             # See all check statuses
fly logs --no-tail | grep -i health         # Health check logs
fly ssh console -C "curl -v localhost:8080/health"  # Test from inside
```

### Common Causes & Fixes

**Port mismatch**
The most common cause. `internal_port` in `fly.toml` must exactly match what your app listens on.
```toml
# Verify these match:
[http_service]
  internal_port = 8080    # <-- Must match app's listen port

# App code:
# server.listen(8080)    # <-- This must match
```

**App not binding to 0.0.0.0**
Apps must bind to `0.0.0.0`, not `127.0.0.1` or `localhost`.
```bash
# Wrong: only listens on localhost inside container
node server.js --host 127.0.0.1

# Right: listens on all interfaces
node server.js --host 0.0.0.0
```

**Grace period too short**
JVM, Rails, and Python apps may need 30-60s to start.
```toml
[[http_service.checks]]
  grace_period = "60s"     # Allow 60s for startup
  interval = "15s"
  timeout = "5s"
  method = "GET"
  path = "/health"
```

**Health endpoint returns non-200**
Fly expects HTTP 200. Redirects (301/302) count as failures.
```python
@app.route("/health")
def health():
    return "ok", 200       # Must be 200, not redirect
```

**TCP check on wrong port**
```toml
[[http_service.checks]]
  type = "http"            # Not "tcp" for HTTP services
  port = 8080              # Explicit port
```

---

## Machine Not Starting

### Symptoms
- Machine state stuck at `created` or cycling between `starting` and `stopped`.
- `fly status` shows no running Machines.

### Diagnosis

```bash
fly machine status <id>                     # Detailed machine state
fly logs --no-tail                          # Error messages
fly machine list                            # All machines and states
```

### Common Causes & Fixes

**Crash loop (exit code 1)**
App crashes immediately on start. Check logs for the error. Common: missing env vars, config file not found, dependency missing.

**No available resources in region**
```
Error: could not reserve resources
```
Fix: Try a different region, or smaller VM size. GPU regions are particularly constrained.

**Volume not available**
If a machine needs a volume and none exists in that region, it can't start.
```bash
fly volumes list                            # Check volume regions
fly volumes create data --size 10 --region iad  # Create where needed
```

**Dockerfile CMD/ENTRYPOINT missing**
```dockerfile
# Must have one of:
CMD ["node", "server.js"]
ENTRYPOINT ["./start.sh"]
```

**Insufficient memory**
If the app immediately OOMs, the Machine cycles. Scale up:
```bash
fly scale vm shared-cpu-1x --memory 512
```

---

## Volume Attachment Errors

### Symptoms
- `Error: volume not found`
- `Error: volume is attached to another machine`
- Machine starts without expected data.

### Diagnosis

```bash
fly volumes list                            # Volume states and attachments
fly machine status <id>                     # Check mounts
```

### Common Causes & Fixes

**Volume in wrong region**
Volumes are region-locked. A Machine in `cdg` cannot use a volume in `iad`.
```bash
# Fork volume to new region
fly volumes fork vol_abc123 --region cdg
```

**Volume already attached**
Each volume attaches to exactly one Machine. If you scale up, you need more volumes.
```bash
# Create additional volume
fly volumes create data --size 10 --region iad --count 2
# Scale to match
fly scale count 2 --region iad
```

**Volume name mismatch**
`source` in `fly.toml` must match the volume name.
```toml
[mounts]
  source = "data"          # Must match: fly volumes create "data"
  destination = "/data"
```

**Data missing after deploy**
Volumes persist across deploys, but the root filesystem is ephemeral. Only data in the mounted path survives.

---

## DNS Resolution in Private Networking

### Symptoms
- `Could not resolve host: my-app.internal`
- Timeouts connecting to internal services.
- `.internal` DNS returns no results.

### Diagnosis

```bash
# From inside a Machine:
fly ssh console
dig aaaa my-app.internal                    # Should return AAAA records
dig aaaa top1.nearest.of.my-app.internal    # Nearest instance
cat /etc/resolv.conf                        # Should point to fdaa::3
```

### Common Causes & Fixes

**App not in the same organization**
`.internal` DNS only works within the same Fly org. Apps in different orgs cannot resolve each other.

**No running Machines**
If all Machines for an app are stopped, `.internal` DNS returns no records.
```bash
fly status -a target-app                    # Ensure at least 1 running
```

**Using IPv4 instead of IPv6**
`.internal` DNS returns AAAA (IPv6) records only. Your client must support IPv6.
```python
# Force IPv6 for internal connections
import socket
socket.setdefaulttimeout(5)
# Use the [::] family, or let the runtime handle it
```

**DNS resolver misconfigured**
Inside Fly Machines, `/etc/resolv.conf` should contain `nameserver fdaa::3`. If using a custom Docker image that overwrites it, DNS breaks.

**Workaround: Use fly-replay instead**
```python
# Instead of direct .internal call, use fly-replay header
return "", 409, {"fly-replay": "app=my-api"}
```

---

## Certificate Provisioning Delays

### Symptoms
- `fly certs show` says "Awaiting configuration" or "Awaiting certificates".
- HTTPS doesn't work for custom domain.

### Diagnosis

```bash
fly certs show myapp.example.com
fly certs check myapp.example.com
```

### Common Causes & Fixes

**DNS not configured**
Certificate provisioning requires DNS to resolve to Fly before Let's Encrypt can issue.
```bash
# Required DNS records:
# CNAME: myapp.example.com -> my-app.fly.dev
# OR for apex: A record -> fly app IPv4, AAAA -> fly app IPv6

# Check from outside Fly:
dig myapp.example.com CNAME
dig myapp.example.com A
```

**CAA records blocking Let's Encrypt**
If your domain has CAA DNS records, they must allow `letsencrypt.org`.
```
# Add to DNS:
myapp.example.com. CAA 0 issue "letsencrypt.org"
```

**Propagation delay**
DNS changes take 5min–48hrs to propagate. Wait and retry:
```bash
fly certs remove myapp.example.com
fly certs add myapp.example.com
```

**Rate limiting**
Let's Encrypt has rate limits (50 certs/domain/week). If you've been creating/deleting many certs, you may be rate-limited.

---

## Connection Timeouts Across Regions

### Symptoms
- Requests between Machines in different regions time out.
- Intermittent 502/504 errors on cross-region calls.
- High latency on internal service calls.

### Diagnosis

```bash
fly ssh console -a source-app
# Inside machine:
curl -w "\n%{time_total}\n" http://target-app.internal:8080/health
traceroute6 target-app.internal
```

### Common Causes & Fixes

**Target Machine stopped (auto-stop)**
If the target app uses auto-stop, the first request triggers a cold start.
```toml
# On target app: keep at least 1 machine running
[http_service]
  min_machines_running = 1
```

**Concurrency limit reached**
Target Machine may be rejecting connections because it hit the hard limit.
```toml
[http_service.concurrency]
  soft_limit = 200
  hard_limit = 250         # Increase if needed
```

**Internal service not using .internal DNS**
Don't route internal traffic through the public internet. Use `.internal` hostnames.

**Timeout too short in client code**
Cross-region latency can be 100-300ms. Set client timeouts accordingly.
```python
requests.get("http://api.internal:8080/data", timeout=5)
```

---

## OOM Kills

### Symptoms
- Machine restarts unexpectedly.
- Exit code 137 in logs.
- `fly logs` shows `Out of memory: Killed process`.

### Diagnosis

```bash
fly logs --no-tail | grep -E "OOM|oom|137|killed"
fly machine status <id>                     # Check exit code
fly scale show                              # Current VM size
```

### Common Causes & Fixes

**Scale up memory**
```bash
fly scale vm shared-cpu-1x --memory 512     # Double default
fly scale vm shared-cpu-2x --memory 1024    # More headroom
```

**Memory leak in application**
Profile your app. For Node.js: `--max-old-space-size=384` (leave headroom below VM limit). For JVM: `-Xmx384m`.

**Too many worker processes**
Web servers like Puma, Gunicorn, and Uvicorn spawn multiple workers. Reduce count for small VMs.
```bash
# Gunicorn: match workers to available memory
gunicorn app:app --workers 2 --threads 2    # Not --workers 8
```

**Large file processing in memory**
Stream large files instead of loading entirely into memory. Use Tigris for object storage.

**Rule of thumb**: Your app should use ~75% of available RAM at peak. The remaining 25% is for OS overhead and spikes.

---

## Disk Space Exhaustion

### Symptoms
- `No space left on device` errors.
- Writes fail silently.
- Volume fills up.

### Diagnosis

```bash
fly ssh console
df -h                                       # Check disk usage
du -sh /data/*                              # Find large directories
```

### Common Causes & Fixes

**Root filesystem full**
Root filesystem is ephemeral and small (~1-8GB depending on image). Don't write temp files to root.
```bash
# Write temp files to volume instead
TMPDIR=/data/tmp node app.js
```

**Volume full**
```bash
# Extend volume (no shrink, no downtime)
fly volumes extend vol_abc123 --size 20     # Grow to 20GB
```

**Log files accumulating**
If your app writes logs to disk instead of stdout, they accumulate.
```bash
# Fix: Log to stdout, not files
# Or rotate: logrotate config in Dockerfile
```

**SQLite WAL files**
SQLite WAL can grow large under write-heavy load. Run `PRAGMA wal_checkpoint(TRUNCATE)` periodically.

---

## Postgres Failover Issues

### Symptoms
- Application can't connect to Postgres after failover.
- Connection string points to old primary.
- Replication lag after failover.

### Diagnosis

```bash
fly status -a my-db                         # Check Postgres machines
fly postgres connect -a my-db -C "SELECT pg_is_in_recovery();"  # true = replica
fly logs -a my-db --no-tail | grep -i failover
```

### Common Causes & Fixes

**Connection string hardcoded**
Always use `.internal` DNS which auto-updates after failover.
```
# Good: resolves to current primary
postgres://user:pass@my-db.internal:5432/db

# Bad: hardcoded IP
postgres://user:pass@[fdaa:0:abc::2]:5432/db
```

**Application caches DNS**
Some runtimes cache DNS lookups. After failover, cached IPs are stale.
```python
# Python: disable DNS caching or set short TTL
import socket
socket.setdefaulttimeout(5)
```

**Manual failover**
```bash
fly postgres failover -a my-db              # Promote a replica
```

**Replication lag monitoring**
```sql
-- On replica:
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
```

---

## Slow Cold Starts

### Symptoms
- First request after idle takes 2-10+ seconds.
- Users see timeouts or loading spinners.

### Diagnosis

```bash
fly logs --no-tail | grep -E "start|boot|listen"
# Measure time from Machine start to first successful health check
```

### Common Causes & Fixes

**Large Docker image**
Smaller images = faster pull times.
```bash
docker images my-app                        # Check image size
# Use multi-stage builds, slim/alpine base images
# Target: <200MB for web apps
```

**Slow application boot**
- Node.js: Avoid heavy `require()` at startup. Lazy-load modules.
- Rails: Use `bootsnap`, precompile assets in build step.
- JVM: Use GraalVM native-image or CDS (Class Data Sharing).
- Python: Use `gunicorn --preload` to load app before forking.

**Use `suspend` instead of `stop`**
```toml
[http_service]
  auto_stop_machines = "suspend"            # ~50ms wake vs ~300ms+
```
Suspend preserves RAM state. The Machine wakes almost instantly. Costs slightly more (you pay for suspended RAM at reduced rate).

**Keep minimum machines warm**
```toml
[http_service]
  min_machines_running = 1                  # Never fully cold
```

**Pre-warm with health check**
Create an external uptime check that hits your app every 30s to prevent auto-stop.

---

## Deploy Rollback

### Methods

**Immediate rollback to previous release**
```bash
fly releases                                # List releases, find previous
fly deploy --image registry.fly.io/my-app:deployment-XXXXX  # Redeploy old image
```

**Rollback by re-deploying old commit**
```bash
git log --oneline                           # Find last known good commit
git checkout <commit>
fly deploy
```

**Machine-level rollback (Machines API)**
```bash
# Update specific machine to previous image
curl -X POST "https://api.machines.dev/v1/apps/${APP}/machines/${ID}" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}" \
  -d '{"config": {"image": "registry.fly.io/my-app:previous-tag"}}'
```

**Rollback with migration considerations**
If the deploy included a database migration, rollback is more complex:
1. Check if migration is backward-compatible (additive = safe to rollback code).
2. If migration dropped columns/tables, you must write a reverse migration.
3. Deploy reverse migration first, then rollback code.

---

## WireGuard Tunnel Issues

### Symptoms
- `fly proxy` fails to connect.
- `fly ssh console` hangs or times out.
- Local dev can't reach Fly private network.

### Diagnosis

```bash
fly wireguard list                          # List WireGuard peers
fly wireguard status                        # Check tunnel state
fly doctor                                  # Run connectivity diagnostics
```

### Common Causes & Fixes

**Stale WireGuard peer**
```bash
fly wireguard reset                         # Reset all tunnels
fly wireguard create                        # Create fresh tunnel
```

**Corporate firewall blocking UDP**
WireGuard uses UDP port 51820. Some corporate networks block it.
```bash
# Try a different network or VPN
# Or use fly proxy which may work over HTTPS
```

**Too many peers**
Fly limits WireGuard peers. Remove old ones:
```bash
fly wireguard list
fly wireguard remove <peer-name>
```

**fly doctor output**
```bash
fly doctor
# Checks: DNS, authentication, WireGuard, agent connectivity
# Follow its recommendations
```

---

## Billing Surprises

### Common Causes

**Machines left running**
Stopped machines cost $0 compute but volumes still cost money.
```bash
fly apps list                               # Check all apps
fly status -a <app>                         # Check running machines
fly machine list -a <app>                   # List all machines
fly scale count 0 -a unused-app             # Scale down unused
fly apps destroy unused-app                 # Delete entirely
```

**auto_stop not configured**
Without auto-stop, machines run 24/7 even with zero traffic.
```toml
[http_service]
  auto_stop_machines = "stop"
  min_machines_running = 0                  # True scale-to-zero
```

**Dedicated IPv4**
Each dedicated IPv4 is $2/mo. Use shared instead:
```bash
fly ips list                                # Check IP types
fly ips release <ip-address>                # Release dedicated
fly ips allocate-v4 --shared                # Use shared (free)
```

**Builder machines**
Remote builders can accumulate. Destroy when not needed:
```bash
fly apps list | grep builder
fly apps destroy fly-builder-<name>
```

**Volume storage fees**
Volumes cost ~$0.15/GB/mo even when machine is stopped.
```bash
fly volumes list                            # Audit all volumes
fly volumes destroy vol_unused              # Remove unused
```

**Postgres replicas**
Each read replica is a separate app with its own machines and volumes.

### Cost Monitoring

```bash
fly billing view                            # Current billing info
fly orgs show <org>                         # Org details
```

Check `fly.io/dashboard/personal/billing` regularly. Set up billing alerts in the dashboard.
