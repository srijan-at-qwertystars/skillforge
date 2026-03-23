---
name: connection-pooling
description:
  positive: "Use when user configures database connection pools, asks about pool sizing, PgBouncer, HikariCP, SQLAlchemy pool, connection limits, pool exhaustion, or connection lifecycle management."
  negative: "Do NOT use for HTTP connection pooling, thread pools, or general object pooling without database context."
---

# Database Connection Pooling

## Why Pool Connections

Opening a database connection involves TCP handshake, TLS negotiation, authentication, and backend process creation (PostgreSQL forks a new process per connection). This costs 50–150ms per connection. Pooling amortizes this cost by reusing a fixed set of pre-established connections.

**Connection lifecycle without pooling:**
1. App opens connection → TCP + TLS + auth (~100ms)
2. Execute query (~5ms)
3. Close connection → backend process terminates

**With pooling:**
1. App borrows connection from pool (~0.1ms)
2. Execute query (~5ms)
3. Return connection to pool (~0.01ms)

Key benefits: lower latency, bounded resource usage, protection against connection storms.

## Pool Sizing

### Formula: Cores × 2 + Spindles

From HikariCP wiki (Brett Wooldridge):

```
connections = (CPU cores × 2) + effective_spindle_count
```

- CPU cores = physical cores (not hyperthreads) on the **database server**.
- Spindle count = number of spinning disks. Use 0 if dataset fits in RAM, 1 for SSD.
- Example: 4-core server with SSD → `(4 × 2) + 1 = 9` connections.

This formula applies to the **total** connections hitting the database, not per-application-instance.

### Little's Law

For workload-driven sizing:

```
L = λ × W
Pool Size = requests_per_second × avg_query_duration_seconds
```

Example: 500 req/s × 0.020s avg query = 10 connections. Add 10–20% headroom for spikes.

### Benchmarking Approach

1. Start with formula-derived size.
2. Load test with realistic traffic.
3. Decrease pool size until throughput drops — the inflection point is your optimal size.
4. Smaller pools reduce contention and improve throughput under load.

## Pool Parameters

| Parameter | Purpose | Typical Default | Guidance |
|-----------|---------|-----------------|----------|
| `minIdle` / `min_size` | Warm connections kept ready | 0–5 | Match steady-state load |
| `maxSize` / `max_pool_size` | Hard cap on connections | 10 | Size per formula above |
| `idleTimeout` | Close idle connections after | 10 min | Keep below DB `wait_timeout` |
| `maxLifetime` | Recycle connections before | 30 min | Set below DB/firewall timeout, stagger across pool |
| `connectionTimeout` | Max wait for a connection | 30s | Fail fast: 5–10s in production |
| `validationQuery` / `test_on_borrow` | Check connection health | SELECT 1 | Use driver-level validation when available |
| `leakDetection` | Log stack trace for unreturned connections | disabled | Enable in dev/staging |

## Application-Level Pools

### HikariCP (Java)

Spring Boot `application.yml`:

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 10
      minimum-idle: 5
      idle-timeout: 300000        # 5 min (ms)
      max-lifetime: 1800000       # 30 min (ms)
      connection-timeout: 10000   # 10s (ms)
      leak-detection-threshold: 30000
      validation-timeout: 5000
      pool-name: myapp-pool
```

**Tuning checklist:**
- Set `maximum-pool-size` per formula. Do not blindly use 50+.
- Set `max-lifetime` 30s shorter than DB `wait_timeout` to avoid stale connections.
- Enable leak detection in staging (`leak-detection-threshold: 30000`).
- Register Micrometer metrics to expose `hikaricp_connections_pending`, `hikaricp_connections_active`, `hikaricp_connections_timeout_total`.

**Common mistakes:**
- Setting pool size equal to `max_connections` on Postgres — leaves no room for admin connections.
- Using `autoCommit=false` without explicit transaction management — connections never return to pool.
- Running long transactions that hold connections — blocks other requests.

### SQLAlchemy (Python)

```python
from sqlalchemy import create_engine

engine = create_engine(
    "postgresql+psycopg://user:pass@host:5432/db",
    pool_size=5,           # maintained connections
    max_overflow=10,       # burst beyond pool_size (total max = 15)
    pool_timeout=10,       # seconds to wait for connection
    pool_recycle=1800,     # recycle after 30 min
    pool_pre_ping=True,    # validate before use (handles stale conns)
)
```

**Pool classes:**
- `QueuePool` (default): fixed size + overflow. Use for most apps.
- `NullPool`: no pooling — every call opens/closes. Use with external pooler (PgBouncer).
- `StaticPool`: single shared connection. Use for single-threaded scripts.
- `AsyncAdaptedQueuePool`: for async engines with `create_async_engine`.

**Async usage:**

```python
from sqlalchemy.ext.asyncio import create_async_engine

engine = create_async_engine(
    "postgresql+asyncpg://user:pass@host:5432/db",
    pool_size=10,
    max_overflow=5,
    pool_pre_ping=True,
)
```

When using PgBouncer in front, set `NullPool` to avoid double pooling:

```python
engine = create_engine(url, poolclass=NullPool)
```

### node-postgres / pg (Node.js)

```javascript
const { Pool } = require('pg');

const pool = new Pool({
  host: 'localhost',
  port: 5432,
  database: 'mydb',
  user: 'app',
  password: 'secret',
  max: 10,                    // max connections
  idleTimeoutMillis: 30000,   // close idle after 30s
  connectionTimeoutMillis: 5000,
  allowExitOnIdle: true,      // let process exit if pool is idle
});

// Always release connections
const client = await pool.connect();
try {
  await client.query('SELECT ...');
} finally {
  client.release();  // MUST release back to pool
}

// Or use pool.query() for auto-release
const result = await pool.query('SELECT NOW()');
```

**Error handling:**

```javascript
pool.on('error', (err) => {
  console.error('Unexpected pool error', err);
  // Don't crash — pool recovers automatically
});
```

**Common mistakes:**
- Forgetting `client.release()` in error paths → pool exhaustion.
- Creating a new `Pool` per request → defeats pooling entirely.

### database/sql (Go)

```go
import "database/sql"

db, err := sql.Open("postgres", connStr)
if err != nil {
    log.Fatal(err)
}

db.SetMaxOpenConns(10)           // total open connections
db.SetMaxIdleConns(5)            // idle connections to keep
db.SetConnMaxLifetime(30 * time.Minute) // recycle connections
db.SetConnMaxIdleTime(5 * time.Minute)  // close stale idle conns
```

**Key behavior:**
- `MaxOpenConns=0` means unlimited — always set an explicit limit.
- `MaxIdleConns` > `MaxOpenConns` is ignored.
- Monitor with `db.Stats()`: `InUse`, `Idle`, `WaitCount`, `WaitDuration`.
- Set `ConnMaxLifetime` shorter than DB timeout to prevent reuse of closed connections.

## External Poolers

### PgBouncer

Sits between application and PostgreSQL. Multiplexes many client connections onto fewer database connections.

**Pooling modes:**

| Mode | Behavior | Use When |
|------|----------|----------|
| `session` | 1:1 client-to-server for session lifetime | Need PREPARE, LISTEN, temp tables |
| `transaction` | Server returned to pool after each transaction | Default for most apps |
| `statement` | Server returned after each statement | Only for simple autocommit queries |

**pgbouncer.ini:**

```ini
[databases]
mydb = host=127.0.0.1 port=5432 dbname=mydb

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

pool_mode = transaction
default_pool_size = 20          # server conns per user/db pair
min_pool_size = 5
max_client_conn = 1000          # max client connections
max_db_connections = 50         # hard cap per database
reserve_pool_size = 5           # extra conns for burst
reserve_pool_timeout = 3        # seconds before using reserve

server_idle_timeout = 300
server_lifetime = 3600
server_login_retry = 3
query_wait_timeout = 120
client_idle_timeout = 0

# Monitoring
stats_period = 60
admin_users = pgbouncer_admin
```

**Monitoring PgBouncer:**

```sql
-- Connect to PgBouncer admin console
psql -p 6432 -U pgbouncer_admin pgbouncer

SHOW POOLS;    -- active/waiting/idle per pool
SHOW STATS;    -- requests, bytes, query times
SHOW CLIENTS;  -- connected clients
SHOW SERVERS;  -- backend connections
SHOW CONFIG;   -- current settings
```

**Auth setup:**

```bash
# userlist.txt format:
"username" "scram-sha-256$4096:salt$storedkey:serverkey"
# Or use auth_query to pull from pg_shadow
```

### PgCat

Rust-based pooler with features beyond PgBouncer.

**Key capabilities:**
- Multi-threaded (uses all CPU cores).
- Built-in read/write splitting and load balancing across replicas.
- Sharding support.
- Per-pool metrics via Prometheus endpoint.
- Query-level routing rules.

**pgcat.toml:**

```toml
[general]
host = "0.0.0.0"
port = 6432
admin_username = "admin"
admin_password = "secret"

[pools.mydb]
pool_mode = "transaction"
default_role = "primary"
query_parser_enabled = true

[pools.mydb.shards.0]
servers = [["primary-host", 5432, "primary"], ["replica-host", 5432, "replica"]]
database = "mydb"

[pools.mydb.users.0]
username = "app"
password = "secret"
pool_size = 20
min_pool_size = 5
```

Use PgCat over PgBouncer when you need read replicas, multi-tenancy, or horizontal scaling.

### ProxySQL (MySQL)

Connection multiplexing and query routing proxy for MySQL/MariaDB.

**Key features:**
- Connection pooling and multiplexing.
- Query routing (read/write split).
- Query caching, mirroring, and firewall rules.
- Runtime reconfiguration via admin interface.

**Configuration:**

```sql
-- Add backend servers
INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_connections)
VALUES (10, 'primary.db', 3306, 100),
       (20, 'replica1.db', 3306, 100);

-- Query routing rules
INSERT INTO mysql_query_rules (rule_id, match_pattern, destination_hostgroup)
VALUES (1, '^SELECT .* FOR UPDATE', 10),  -- writes to primary
       (2, '^SELECT', 20);                -- reads to replica

-- Connection pool settings
UPDATE global_variables SET variable_value=200
WHERE variable_name='mysql-max_connections';

LOAD MYSQL SERVERS TO RUNTIME;
LOAD MYSQL QUERY RULES TO RUNTIME;
```

## Serverless Connection Management

Serverless functions create/destroy connections rapidly. Without pooling, this overwhelms the database.

| Service | How It Works | Key Config |
|---------|-------------|------------|
| **Neon** | Built-in pooler (PgBouncer-based) via `-pooler` endpoint | Use connection string with `?pgbouncer=true` |
| **Supabase Supavisor** | Elixir-based pooler, replaces PgBouncer | Transaction mode by default, configurable per-project |
| **AWS RDS Proxy** | Managed proxy, auto-scales, IAM auth | `max_connections_percent`, `idle_client_timeout` |
| **PlanetScale** | MySQL-compatible, built-in connection handling | No pool config needed — handled at platform level |

**Pattern for serverless (Lambda / Cloud Functions):**

```python
# Initialize pool OUTSIDE handler to reuse across invocations
engine = create_engine(url, pool_size=1, max_overflow=2, pool_recycle=300)

def handler(event, context):
    with engine.connect() as conn:
        result = conn.execute(text("SELECT ..."))
    return result
```

## Monitoring

### Key Metrics to Track

| Metric | Meaning | Alert Threshold |
|--------|---------|-----------------|
| Active connections | Currently executing queries | > 80% of pool max |
| Idle connections | Waiting in pool | Unexpected spikes |
| Waiting/pending | Requests queued for a connection | > 0 sustained |
| Connection wait time | Time spent waiting to acquire | p99 > 1s |
| Timeout count | Failed to acquire connection | Any non-zero |
| Total connections | Connections open on database | Near `max_connections` |

### Platform-Specific Monitoring

**PostgreSQL:**

```sql
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;
SELECT max_conn, used, max_conn - used AS available
FROM (SELECT count(*) AS used FROM pg_stat_activity) t,
     (SELECT setting::int AS max_conn FROM pg_settings WHERE name='max_connections') s;
```

**HikariCP (Prometheus):**

```
hikaricp_connections_active{pool="myapp-pool"}
hikaricp_connections_pending{pool="myapp-pool"}
hikaricp_connections_timeout_total{pool="myapp-pool"}
```

**Go `database/sql`:**

```go
stats := db.Stats()
log.Printf("InUse=%d Idle=%d WaitCount=%d WaitDuration=%s",
    stats.InUse, stats.Idle, stats.WaitCount, stats.WaitDuration)
```

## Troubleshooting

### Connection Leaks

**Symptoms:** Pool exhaustion over time, increasing active connections, eventual timeout errors.

**Diagnosis:**
- Enable leak detection (HikariCP: `leak-detection-threshold`, SQLAlchemy: `echo_pool=True`).
- Check `pg_stat_activity` for long-lived `idle` connections.
- In Go, look for missing `rows.Close()` or `defer db.Close()`.

**Fix:** Ensure every acquired connection is released in a `finally`/`defer`/`try-with-resources` block.

### Pool Exhaustion

**Symptoms:** `Connection is not available, request timed out` errors. Threads/goroutines blocked.

**Causes:**
- Pool too small for workload.
- Long-running queries holding connections.
- Connection leaks.
- Nested connection acquisition (deadlock).

**Fix:** Increase pool size if load justifies it. Add query timeouts. Fix leaks.

### Too Many Connections on Database

**Symptoms:** `FATAL: too many connections for role` or `sorry, too many clients already`.

**Fix:**
- Sum all pool sizes across all app instances. Ensure total < database `max_connections` minus reserved (superuser, replication, monitoring).
- Use an external pooler (PgBouncer) to multiplex.
- Formula: `per_instance_pool × num_instances < max_connections - reserved_connections`.

### Slow Queries Blocking Pool

**Symptoms:** Pool utilization spikes, p99 latency increases, some requests timeout.

**Fix:**
- Set `statement_timeout` on the database or connection.
- Use `pool.query()` with timeout instead of holding a dedicated client.
- Offload long analytics queries to a read replica with a separate pool.

## Anti-Patterns

**Pool per request:** Creating a new pool for each incoming request. Defeats the purpose entirely. Always share a single pool instance.

**Unbounded pools:** Setting `max_connections=0` or `max_overflow=-1`. Under load, this opens hundreds of connections and crashes the database.

**Ignoring database connection limits:** Running 20 app instances × 50 pool size = 1000 connections against a database with `max_connections=200`.

**Double pooling without NullPool:** Using HikariCP/SQLAlchemy pool AND PgBouncer. The application pool holds connections to PgBouncer open, preventing PgBouncer from multiplexing effectively. Set `NullPool` (SQLAlchemy) or `minimumIdle=0` (HikariCP) when using an external pooler.

**Never recycling connections:** Stale connections hit firewall/load-balancer idle timeouts and fail silently. Always set `maxLifetime` / `pool_recycle`.

**Sharing pools across unrelated workloads:** A slow analytics query in a shared pool starves fast OLTP queries. Use separate pools for different workload classes.

<!-- tested: pass -->
