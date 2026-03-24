# Fly.io Multi-Region Deployment Guide

## Table of Contents
1. [Anycast Routing Behavior](#anycast-routing-behavior)
2. [Region Selection Strategies](#region-selection-strategies)
3. [Read Replicas with fly-replay](#read-replicas-with-fly-replay)
4. [Write Forwarding](#write-forwarding)
5. [Regional Routing Strategies](#regional-routing-strategies)
6. [Data Locality Patterns](#data-locality-patterns)
7. [Edge Caching](#edge-caching)
8. [CDN Integration](#cdn-integration)
9. [Latency-Based Routing](#latency-based-routing)
10. [Cross-Region Postgres Replication](#cross-region-postgres-replication)
11. [LiteFS for SQLite Replication](#litefs-for-sqlite-replication)
12. [Cost Considerations Per Region](#cost-considerations-per-region)

---

## Anycast Routing Behavior

Fly.io uses **Anycast IP addresses** — the same IP is announced from every Fly edge location. The internet's BGP routing directs each user to the nearest Fly edge node.

### How It Works
1. User resolves `my-app.fly.dev` → gets an Anycast IP (same IP globally).
2. BGP routes the packet to the nearest Fly edge PoP.
3. Fly Proxy at that PoP inspects the request.
4. Proxy routes to the nearest healthy Machine for the app.
5. If no Machine exists in the local region, request goes to the next closest region with a running Machine.

### Key Behaviors
- **Sticky connections**: TCP connections stick to one Machine for their lifetime. New connections may route elsewhere.
- **No geographic guarantee**: "Nearest" is determined by BGP path, not geographic distance. US users may route to European Machines if the BGP path is shorter.
- **Health-aware**: Fly Proxy skips unhealthy Machines (failed health checks) and stopped Machines.
- **Auto-start**: If `auto_start_machines = true`, a stopped Machine in the nearest region will be started to serve the request. The user waits for the cold start.

### Practical Implications
```
User in London → Fly PoP in London → Machine in cdg (Paris) ✓ fast
User in London → Fly PoP in London → Machine in iad (Virginia) ✗ slow if cdg exists

# Deploy to regions near your users:
fly scale count 2 --region cdg    # Europe
fly scale count 2 --region iad    # US East
```

---

## Region Selection Strategies

### Available Regions (representative selection)

| Code | Location | Use When |
|------|----------|----------|
| `iad` | Virginia, US | US East users, AWS us-east-1 proximity |
| `ord` | Chicago, US | US Central, GPU availability |
| `sjc` | San Jose, US | US West users |
| `yyz` | Toronto, CA | Canadian data residency |
| `cdg` | Paris, FR | EU users, GDPR compliance |
| `lhr` | London, UK | UK users |
| `ams` | Amsterdam, NL | Western EU |
| `fra` | Frankfurt, DE | Central EU, GDPR |
| `nrt` | Tokyo, JP | East Asia, Japan users |
| `sin` | Singapore | Southeast Asia |
| `syd` | Sydney, AU | Australia/Oceania |
| `gru` | São Paulo, BR | South America |
| `jnb` | Johannesburg, ZA | Africa |
| `bom` | Mumbai, IN | India |

Full list: `fly platform regions`

### Strategy: Start Small, Expand

```bash
# Phase 1: Single region near most users
fly scale count 2 --region iad

# Phase 2: Add second region for redundancy + coverage
fly scale count 2 --region cdg

# Phase 3: Expand to Asia
fly scale count 2 --region nrt

# Phase 4: Add more regions based on traffic analytics
fly scale count 1 --region sin
fly scale count 1 --region syd
```

### Strategy: Database-Primary Alignment

Place your primary database and write-heavy Machines in the same region to minimize write latency.
```toml
# fly.toml
primary_region = "iad"       # Database lives here

[env]
  PRIMARY_REGION = "iad"     # App uses this for write routing
```

### Strategy: Compliance-Driven

For GDPR, place EU user data in EU regions:
```bash
# EU-only deployment
fly scale count 3 --region cdg
fly scale count 3 --region fra
# Ensure DATABASE_URL points to EU-region Postgres
```

---

## Read Replicas with fly-replay

The `fly-replay` response header tells Fly Proxy to retry the request against a different Machine, region, or app — transparently to the client.

### How fly-replay Works

```
1. Client → Fly Proxy → Machine in cdg (replica)
2. Machine detects write request
3. Machine responds: 409 + fly-replay: region=iad
4. Fly Proxy → Machine in iad (primary)
5. Primary processes write, returns response
6. Fly Proxy → Client (client sees normal 200, never the 409)
```

The client never sees the replay. It's transparent. The response from the final destination is returned to the client.

### Implementation: Read-Local, Write-Primary

```python
# Flask middleware
import os
from flask import request, Response

PRIMARY = os.environ.get("PRIMARY_REGION", "iad")
CURRENT = os.environ.get("FLY_REGION", "iad")

@app.before_request
def route_writes():
    if CURRENT == PRIMARY:
        return  # We are the primary, handle everything

    if request.method in ("POST", "PUT", "PATCH", "DELETE"):
        return Response(
            status=409,
            headers={"fly-replay": f"region={PRIMARY}"}
        )
    # GET/HEAD requests served locally from read replica
```

```ruby
# Rails middleware
class FlyReplayMiddleware
  WRITE_METHODS = %w[POST PUT PATCH DELETE].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    if WRITE_METHODS.include?(env["REQUEST_METHOD"]) &&
       ENV["FLY_REGION"] != ENV["PRIMARY_REGION"]
      [409, {"fly-replay" => "region=#{ENV['PRIMARY_REGION']}"}, []]
    else
      @app.call(env)
    end
  end
end
```

```javascript
// Express middleware
const PRIMARY = process.env.PRIMARY_REGION || "iad";
const CURRENT = process.env.FLY_REGION || "iad";

app.use((req, res, next) => {
  if (CURRENT !== PRIMARY && ["POST", "PUT", "PATCH", "DELETE"].includes(req.method)) {
    res.set("fly-replay", `region=${PRIMARY}`);
    return res.status(409).end();
  }
  next();
});
```

### Advanced fly-replay Targets

```python
# Route to specific region
headers = {"fly-replay": "region=iad"}

# Route to specific Machine instance
headers = {"fly-replay": "instance=148e272b570789"}

# Route to a different app
headers = {"fly-replay": "app=my-api"}

# Combine: app + region
headers = {"fly-replay": "app=my-api,region=iad"}

# Pass state through replay (available in Fly-Replay-Src on the receiving end)
headers = {"fly-replay": "region=iad;state=user_id:123"}
```

---

## Write Forwarding

### Database Write Forwarding Architecture

```
US User (write) → iad Machine → iad Postgres (primary) → ✓
EU User (write) → cdg Machine → fly-replay → iad Machine → iad Postgres → ✓
EU User (read)  → cdg Machine → cdg Postgres (replica) → ✓
```

### Smart Write Detection

Not all POST requests are writes. For efficiency, detect actual database writes:

```python
# SQLAlchemy event-based detection
from sqlalchemy import event

@event.listens_for(db.engine, "before_execute")
def detect_write(conn, clauseelement, multiparams, params):
    if not isinstance(clauseelement, str):
        return
    if clauseelement.strip().upper().startswith(("INSERT", "UPDATE", "DELETE")):
        if os.environ.get("FLY_REGION") != os.environ.get("PRIMARY_REGION"):
            raise WriteOnReplicaError()
```

### Handling Write Errors Gracefully

```python
class WriteOnReplicaError(Exception):
    pass

@app.errorhandler(WriteOnReplicaError)
def handle_write_on_replica(e):
    return Response(
        status=409,
        headers={"fly-replay": f"region={os.environ['PRIMARY_REGION']}"}
    )
```

---

## Regional Routing Strategies

### Strategy 1: Region Affinity (Sticky)

Keep a user in their closest region for all requests in a session.

```python
@app.after_request
def set_region_cookie(response):
    if "fly_region" not in request.cookies:
        response.set_cookie("fly_region", os.environ.get("FLY_REGION", "iad"),
                            max_age=3600, httponly=True)
    return response
```

### Strategy 2: Content-Based Routing

Route based on what's being accessed:

```python
@app.before_request
def content_routing():
    # User profiles: serve from user's home region
    if request.path.startswith("/users/"):
        user = get_user(request.path.split("/")[2])
        if user.home_region != os.environ["FLY_REGION"]:
            return Response(status=409,
                headers={"fly-replay": f"region={user.home_region}"})
```

### Strategy 3: Failover Routing

If the primary region is down, accept writes on a secondary:

```python
@app.before_request
def failover_routing():
    primary = os.environ.get("PRIMARY_REGION", "iad")
    current = os.environ.get("FLY_REGION")

    if request.method in WRITE_METHODS and current != primary:
        # Try primary, but if it's down, handle locally
        try:
            check_primary_health()
            return Response(status=409,
                headers={"fly-replay": f"region={primary}"})
        except PrimaryDownError:
            # Accept write locally, queue for sync later
            pass
```

---

## Data Locality Patterns

### Pattern 1: Regional Databases

Each region has its own database for region-specific data:

```
iad: users_us, orders_us
cdg: users_eu, orders_eu
nrt: users_asia, orders_asia
```

Cross-region lookups use `.internal` DNS:
```python
def get_regional_db(region):
    return f"postgres://user:pass@db-{region}.internal:5432/app"
```

### Pattern 2: Sharded by User Location

```python
REGION_MAP = {
    "US": "iad", "CA": "yyz",
    "GB": "lhr", "FR": "cdg", "DE": "fra",
    "JP": "nrt", "SG": "sin", "AU": "syd",
}

def get_user_region(country_code):
    return REGION_MAP.get(country_code, "iad")  # Default to US
```

### Pattern 3: Event Sourcing with Regional Projection

Write events to primary, project read models to each region asynchronously. Each region's read model is eventually consistent but locally fast.

---

## Edge Caching

### Fly Proxy Statics Caching

```toml
# fly.toml — serve static files at the edge
[[statics]]
  guest_path = "/app/public"
  url_prefix = "/static"
```

Static files served by Fly Proxy bypass your app entirely and are cached at edge.

### Application-Level Cache Headers

```python
@app.route("/api/products")
def products():
    data = get_products()
    response = jsonify(data)
    response.headers["Cache-Control"] = "public, max-age=60, s-maxage=300"
    response.headers["Vary"] = "Accept-Encoding"
    return response
```

### In-Memory Regional Cache

```python
from functools import lru_cache
import time

# Per-Machine cache (not shared across Machines)
@lru_cache(maxsize=1000)
def get_product_cached(product_id, cache_bust=None):
    return db.query("SELECT * FROM products WHERE id = ?", product_id)

# Bust cache every 60s
def get_product(product_id):
    cache_key = int(time.time()) // 60
    return get_product_cached(product_id, cache_key)
```

### Regional Redis Cache

Deploy Upstash Redis per region for shared cache across Machines in that region:
```bash
fly redis create --name cache-iad --region iad
fly redis create --name cache-cdg --region cdg
```

---

## CDN Integration

### Fly.io as Origin, External CDN at Edge

For very high traffic, put Cloudflare/Fastly in front of Fly.io:

```
User → Cloudflare Edge → Fly.io (origin)
```

**Cloudflare setup:**
1. Set Fly app URL as origin: `my-app.fly.dev`
2. Configure caching rules in Cloudflare.
3. Set `Cache-Control` headers in your app.
4. Use `Fly-Client-IP` header (Fly) or `CF-Connecting-IP` (Cloudflare) for real IPs.

**DNS setup:**
```
myapp.example.com → CNAME → myapp.example.com.cdn.cloudflare.net
# Cloudflare origin: my-app.fly.dev
```

### Fly.io Native CDN (Statics)

For most apps, Fly's built-in statics serving + Anycast is sufficient CDN. No external CDN needed if:
- Static assets < a few hundred MB.
- Your app handles dynamic content well.
- You don't need WAF/DDoS protection beyond Fly's built-in.

---

## Latency-Based Routing

### Fly's Default: Nearest Machine

Fly Proxy automatically routes to the nearest healthy Machine. No configuration needed for basic latency-based routing.

### Measuring Cross-Region Latency

```bash
# From inside a Machine in cdg:
fly ssh console -a my-app --region cdg
time curl -s http://my-app.internal:8080/health  # Measures to nearest Machine
time curl -s http://iad.my-app.internal:8080/health  # Would need specific Machine
```

### Typical Inter-Region Latencies

| From → To | Approximate RTT |
|-----------|----------------|
| iad → cdg | 80-100ms |
| iad → nrt | 150-180ms |
| iad → syd | 200-250ms |
| cdg → nrt | 250-280ms |
| iad → gru | 130-160ms |
| iad → ord | 15-25ms |

### Optimizing for Latency

1. **Place Machines where users are**: Check analytics for user geographic distribution.
2. **Primary region = highest write volume**: Minimize write-forwarding latency.
3. **Read replicas in read-heavy regions**: Serve reads locally.
4. **Use `top1.nearest.of.<app>.internal`**: Always resolve to closest instance for internal calls.
5. **Measure, don't guess**: Use `Fly-Region` header in responses to track where requests are served.

```python
@app.after_request
def add_debug_headers(response):
    response.headers["X-Served-By-Region"] = os.environ.get("FLY_REGION", "unknown")
    response.headers["X-Machine-Id"] = os.environ.get("FLY_MACHINE_ID", "unknown")
    return response
```

---

## Cross-Region Postgres Replication

### Architecture

```
Primary (iad)
  ├── Streaming Replication → Replica (cdg)
  ├── Streaming Replication → Replica (nrt)
  └── Streaming Replication → Replica (syd)
```

### Setup

```bash
# Create primary
fly postgres create --name mydb --region iad --vm-size shared-cpu-2x --volume-size 20

# Attach to app
fly postgres attach mydb -a my-app

# Add read replicas
fly machines clone <primary-machine-id> --region cdg -a mydb
fly machines clone <primary-machine-id> --region nrt -a mydb
```

### Connection Routing in Application

```python
import os

PRIMARY_REGION = os.environ.get("PRIMARY_REGION", "iad")
FLY_REGION = os.environ.get("FLY_REGION", "iad")
DATABASE_URL = os.environ.get("DATABASE_URL")  # Points to primary

def get_read_connection():
    """Use local region's replica for reads."""
    if FLY_REGION == PRIMARY_REGION:
        return DATABASE_URL
    # Fly Postgres machines are accessible via .internal DNS
    # The app name is the Postgres cluster name
    return DATABASE_URL  # Fly auto-routes reads to nearest replica

def get_write_connection():
    """Always use primary for writes."""
    return DATABASE_URL
```

### Monitoring Replication

```sql
-- On primary: check replication slots and lag
SELECT slot_name, active, restart_lsn,
       pg_current_wal_lsn() - restart_lsn AS lag_bytes
FROM pg_replication_slots;

-- On replica: check replication status
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;

-- On replica: confirm it's a replica
SELECT pg_is_in_recovery();  -- true = replica
```

### Handling Replication Lag

```python
# After a write, if you need to read the written data:
@app.route("/items", methods=["POST"])
def create_item():
    item = db.write(new_item)  # Written to primary

    # Option 1: Return the created item directly (no read needed)
    return jsonify(item), 201

    # Option 2: Read from primary after write
    # (set a short-lived cookie to force primary reads)
    response = redirect(f"/items/{item.id}")
    response.set_cookie("read_primary", "1", max_age=5)
    return response
```

---

## LiteFS for SQLite Replication

### When to Use LiteFS vs Postgres

| Factor | LiteFS (SQLite) | Fly Postgres |
|--------|-----------------|-------------|
| **Complexity** | Simpler, embedded | Separate service |
| **Latency** | Microsecond reads (local file) | Network round-trip |
| **Write throughput** | Lower (single writer) | Higher (connection pooling) |
| **Data size** | <10GB ideal, <50GB max | Unlimited (practically) |
| **Concurrency** | Moderate (SQLite limits) | High |
| **Best for** | Content sites, personal apps, read-heavy | SaaS, high-write, high-concurrency |

### Multi-Region LiteFS Setup

```yaml
# litefs.yml
fuse:
  dir: "/litefs"

data:
  dir: "/data/litefs"

proxy:
  addr: ":8080"
  target: "localhost:8081"
  db: "my_app.db"
  passthrough:
    - "*.css"
    - "*.js"
    - "*.png"
    - "*.jpg"

lease:
  type: "consul"
  advertise-url: "http://${HOSTNAME}.vm.${FLY_APP_NAME}.internal:20202"
  candidate: ${FLY_REGION == PRIMARY_REGION}
  promote: true

exec:
  - cmd: "node server.js"
    if-candidate: true
  - cmd: "node server.js --readonly"
    if-candidate: false
```

```toml
# fly.toml
primary_region = "iad"

[env]
  PRIMARY_REGION = "iad"

[mounts]
  source = "litefs_data"
  destination = "/data"

[http_service]
  internal_port = 8080        # LiteFS proxy port
```

### LiteFS Write Forwarding

LiteFS proxy handles write forwarding automatically via `fly-replay`. Your app doesn't need middleware — LiteFS detects write transactions and replays them to the primary.

For explicit control:
```javascript
app.post("/api/data", (req, res) => {
  if (process.env.FLY_REGION !== process.env.PRIMARY_REGION) {
    res.set("fly-replay", `region=${process.env.PRIMARY_REGION}`);
    return res.status(409).end();
  }
  // Handle write
});
```

---

## Cost Considerations Per Region

### Pricing Model (per Machine)

All regions have the same compute pricing. Costs scale with:
- **Machine count**: More regions × more Machines per region = higher cost.
- **VM size**: `shared-cpu-1x` ($2.32/mo) vs `performance-4x` ($124/mo).
- **Volumes**: $0.15/GB/mo per volume per region.
- **Bandwidth**: Outbound bandwidth is metered but included in generous free tier.

### Cost Optimization for Multi-Region

```
# Minimal multi-region (3 regions, 1 Machine each)
3 × shared-cpu-1x (256MB) = $6.96/mo compute
3 × 1GB volume = $0.45/mo storage
Total: ~$7.41/mo

# Production multi-region (3 regions, 2 Machines each)
6 × shared-cpu-2x (512MB) = $27.84/mo compute
6 × 10GB volume = $9.00/mo storage
Total: ~$36.84/mo
```

### Cost-Saving Strategies

1. **Auto-stop in low-traffic regions**: Keep `min_machines_running = 0` in secondary regions; users accept cold start.
   ```toml
   [http_service]
     auto_stop_machines = "stop"
     min_machines_running = 0    # Scale to zero in off-peak
   ```

2. **Right-size per region**: Use smaller VMs in low-traffic regions.
   ```bash
   fly scale vm shared-cpu-2x --region iad    # High traffic
   fly scale vm shared-cpu-1x --region syd    # Low traffic
   ```

3. **Time-based scaling**: Scale down overnight in region-specific timezones.
   ```bash
   # Cron job: scale down Asia at 2 AM JST
   fly scale count 1 --region nrt
   ```

4. **Avoid unnecessary regions**: Each region adds baseline cost. Start with 2-3 and expand based on measured latency impact.

5. **Shared IPv4**: Free. Dedicated IPv4 is $2/mo per app (not per region).

6. **Monitor usage**: `fly billing view` and dashboard alerts to catch unexpected costs.

### Free Tier Considerations

Fly.io offers free tier resources per org:
- 3 shared-cpu-1x Machines (with 256MB RAM)
- 3GB persistent volume storage
- 160GB outbound bandwidth

A minimal multi-region setup (3 regions, 1 Machine each, small volumes) fits within the free tier.
