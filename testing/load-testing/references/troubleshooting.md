# Load Testing Troubleshooting Guide

## Table of Contents

- [Coordinated Omission](#coordinated-omission)
- [Client-Side Bottlenecks](#client-side-bottlenecks)
- [OS Tuning for Load Generators](#os-tuning-for-load-generators)
- [Interpreting Latency Distributions](#interpreting-latency-distributions)
- [False Positives from Test Infrastructure](#false-positives-from-test-infrastructure)
- [Network Saturation Detection](#network-saturation-detection)
- [JVM Warm-Up Effects](#jvm-warm-up-effects)
- [Connection Pooling Impacts](#connection-pooling-impacts)
- [Debugging Slow Tests](#debugging-slow-tests)
- [Common Error Patterns](#common-error-patterns)
- [Diagnostic Commands Reference](#diagnostic-commands-reference)

---

## Coordinated Omission

### What It Is

Coordinated omission occurs when your load test tool **slows down request generation** in response to slow server responses, making latency appear better than it actually is.

**Closed-loop model** (the problem): VU sends request → waits for response → sleeps → sends next request. If the server takes 5s instead of 50ms, the VU generates far fewer requests. Slow periods get *under-represented* in the data because fewer measurements are taken during them.

**Real-world impact**: A server with 10ms median response time and occasional 5s stalls might show p99=200ms in a closed-loop test but p99=5000ms in reality, because real users don't stop arriving when the server is slow.

### How to Detect It

1. **Compare VU-based vs rate-based tests**: Run the same test with `ramping-vus` and `constant-arrival-rate`. If latency percentiles differ significantly, coordinated omission is hiding problems.

2. **Watch for `dropped_iterations`**: In k6's `constant-arrival-rate` executor, if you see this metric, the system can't keep up with the target rate — that's real data.

3. **Check VU utilization**: If all VUs are busy (none sleeping), your closed-loop test is bottlenecked on the client side.

### Mitigation in k6

```javascript
// BAD: Closed-loop — hides latency spikes
export const options = {
  vus: 100,
  duration: '5m',
};

// GOOD: Open-loop — maintains request rate regardless of response time
export const options = {
  scenarios: {
    open_loop: {
      executor: 'constant-arrival-rate',
      rate: 500,           // 500 requests/sec target
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 100,
      maxVUs: 500,         // can allocate more VUs if responses are slow
    },
  },
};
```

### Mitigation in Locust

Locust is inherently closed-loop. Mitigate by:

```python
from locust import HttpUser, task, constant_throughput

class OpenLoopUser(HttpUser):
    # Each user targets exactly 1 request/sec regardless of response time
    wait_time = constant_throughput(1)

    @task
    def load_test(self):
        self.client.get("/api/endpoint")
```

### When Closed-Loop Is Appropriate

Closed-loop tests are valid when modeling real user behavior where users DO wait for pages to load before acting (e.g., browser-based UI tests). But for API/service load testing and capacity planning, prefer open-loop.

---

## Client-Side Bottlenecks

The load generator machine itself can become the bottleneck, producing misleading results.

### CPU Saturation

**Symptoms**: Measured latency increases linearly with VU count even for a known-fast endpoint. CPU usage on load gen machine at 90%+.

**Diagnosis**:
```bash
# During test, on load gen machine:
top -d 1 -p $(pgrep k6)          # watch k6 CPU usage
mpstat -P ALL 1                   # per-core CPU usage
pidstat -p $(pgrep k6) 1          # k6 process stats
```

**Solutions**:
- Reduce VU count per machine, distribute across multiple load generators
- For k6: use `constant-arrival-rate` with fewer VUs and monitor `dropped_iterations`
- Disable unnecessary checks, reduce custom metric cardinality
- Use `--no-summary` and `--out` to avoid expensive end-of-test aggregation

### Memory Pressure

**Symptoms**: k6 OOM killed, swap usage increasing during test, GC pauses visible in latency.

**Diagnosis**:
```bash
# Monitor memory during test
watch -n 1 "ps aux | grep k6 | grep -v grep | awk '{print \$6/1024 \"MB\"}'"
free -m  # system-wide memory
vmstat 1  # watch swap (si/so columns)
```

**Solutions**:
- Use `SharedArray` instead of loading data per VU (reduces memory by 10-100x)
- Reduce response body processing — don't parse large JSON if you only need status codes
- Limit `http.batch()` size
- Stream results to InfluxDB/file instead of holding in memory

```javascript
// BAD: Each VU gets its own copy of the data
const data = JSON.parse(open('./big-data.json'));  // 100 VUs × 50MB = 5GB

// GOOD: Single copy shared across all VUs
import { SharedArray } from 'k6/data';
const data = new SharedArray('data', () => JSON.parse(open('./big-data.json')));  // 50MB total
```

### Network Saturation on Load Gen

**Symptoms**: Send/receive rates plateau, request queue builds up, latency increases without server CPU increase.

**Diagnosis**:
```bash
# Check NIC throughput
sar -n DEV 1              # network stats per second
nload                     # interactive bandwidth monitor
ifstat 1                  # simple interface stats

# Check for packet drops
netstat -s | grep -i drop
cat /proc/net/dev         # look for drop/error columns
```

**Solutions**:
- Calculate expected bandwidth: `RPS × avg_response_size`
- Use response body discarding if you don't need content: `http.get(url, { responseType: 'none' })`
- Distribute load generators across multiple machines/networks
- Use compression if the target supports it

---

## OS Tuning for Load Generators

### File Descriptor Limits (ulimits)

Each connection uses a file descriptor. Default limits (1024) are far too low.

```bash
# Check current limits
ulimit -n           # soft limit (per-process)
ulimit -Hn          # hard limit
cat /proc/sys/fs/file-max  # system-wide max

# Temporary increase (current session)
ulimit -n 65535

# Permanent increase
cat >> /etc/security/limits.conf << 'EOF'
*         soft    nofile      65535
*         hard    nofile      65535
root      soft    nofile      65535
root      hard    nofile      65535
EOF

# Also set system-wide
echo "fs.file-max = 2097152" >> /etc/sysctl.conf
sysctl -p
```

### TCP Settings

```bash
# Increase ephemeral port range (default: 32768-60999 = ~28K ports)
echo "net.ipv4.ip_local_port_range = 1024 65535" >> /etc/sysctl.conf

# Allow reuse of TIME_WAIT sockets
echo "net.ipv4.tcp_tw_reuse = 1" >> /etc/sysctl.conf

# Increase max connection tracking
echo "net.netfilter.nf_conntrack_max = 1048576" >> /etc/sysctl.conf

# Increase socket buffer sizes
echo "net.core.rmem_max = 16777216" >> /etc/sysctl.conf
echo "net.core.wmem_max = 16777216" >> /etc/sysctl.conf

# Increase backlog for incoming connections
echo "net.core.somaxconn = 65535" >> /etc/sysctl.conf
echo "net.core.netdev_max_backlog = 65535" >> /etc/sysctl.conf

# Apply changes
sysctl -p
```

### Ephemeral Port Exhaustion

**Symptoms**: "Cannot assign requested address" or "Too many open files" errors after running test for a while.

**Diagnosis**:
```bash
# Count connections by state
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn

# Check TIME_WAIT connections (these hold ports for 60s by default)
ss -tan state time-wait | wc -l

# Check available ephemeral ports
cat /proc/sys/net/ipv4/ip_local_port_range
```

**Solutions**:
```bash
# Widen port range
sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# Enable TCP reuse (allows reuse of TIME_WAIT sockets)
sysctl -w net.ipv4.tcp_tw_reuse=1

# Reduce TIME_WAIT timeout (use cautiously)
sysctl -w net.ipv4.tcp_fin_timeout=15

# Use connection keepalive in your test (default for k6)
# k6: noConnectionReuse: false (default)
```

### Load Gen Tuning Checklist

```bash
#!/bin/bash
echo "=== Load Generator Health Check ==="
echo "File descriptors (soft): $(ulimit -n)"
echo "File descriptors (hard): $(ulimit -Hn)"
echo "Ephemeral ports: $(cat /proc/sys/net/ipv4/ip_local_port_range)"
echo "TCP tw_reuse: $(cat /proc/sys/net/ipv4/tcp_tw_reuse)"
echo "Max connections: $(cat /proc/sys/net/core/somaxconn)"
echo "Open files: $(lsof | wc -l)"
echo "TIME_WAIT sockets: $(ss -tan state time-wait | wc -l)"
echo "CPU cores: $(nproc)"
echo "Memory free: $(free -h | awk '/^Mem:/ {print $4}')"
echo "Swap used: $(free -h | awk '/^Swap:/ {print $3}')"
```

---

## Interpreting Latency Distributions

### Understanding Percentiles

```
Percentile Distribution Example:
┌────────┬──────────┬─────────────────────────────────┐
│ Metric │ Value    │ Meaning                         │
├────────┼──────────┼─────────────────────────────────┤
│ min    │ 5ms      │ Best case (cache hit)           │
│ p50    │ 45ms     │ Median user experience          │
│ p90    │ 120ms    │ 10% of users are slower         │
│ p95    │ 250ms    │ 1 in 20 users experience this   │
│ p99    │ 1200ms   │ 1 in 100 users                  │
│ p99.9  │ 4500ms   │ 1 in 1000 users                 │
│ max    │ 12000ms  │ Worst single request            │
│ avg    │ 85ms     │ MISLEADING — hides bimodality   │
└────────┴──────────┴─────────────────────────────────┘
```

### Red Flags in Distributions

**Large gap between p95 and p99**: Indicates intermittent issues — GC pauses, cache misses, slow queries on specific data patterns. Investigate what's different about those requests.

**Bimodal distribution**: Two clusters of latency (e.g., 50ms and 2000ms) suggest different code paths — cached vs. uncached, primary vs. replica, fast query vs. table scan. The average (1025ms) is meaningless here.

**Rising p50 over time**: Steady increase in median latency during test = resource leak. Memory pressure, connection pool exhaustion, log file growth, temp table accumulation.

**Sudden p99 spikes at regular intervals**: GC pauses (if target is JVM), cron jobs, log rotation, autoscaling events, database checkpoint/vacuum.

### Histogram Analysis

```bash
# k6 outputs timing data in JSON. Analyze distribution:
k6 run --out json=results.json script.js

# Parse with jq to build histogram
cat results.json | \
  jq -r 'select(.type=="Point" and .metric=="http_req_duration") | .data.value' | \
  awk '{
    bucket = int($1/50)*50;  # 50ms buckets
    counts[bucket]++;
  }
  END {
    for (b in counts) printf "%5dms-%5dms: %d\n", b, b+49, counts[b]
  }' | sort -n
```

### Latency vs Throughput Curves

The classic pattern at increasing load:
1. **Linear region**: Latency stable, throughput increases linearly with load
2. **Saturation point**: Latency starts climbing, throughput plateaus
3. **Degradation**: Latency spikes exponentially, errors appear, throughput may drop

The **saturation point** is your system's practical capacity. Design for 70-80% of this.

```
Latency │         ╱
        │        ╱
        │       ╱
        │     ╱
        │___╱
        │
        └──────────── Throughput (RPS)
           ^
           saturation point
```

---

## False Positives from Test Infrastructure

### Load Balancer / Proxy Interference

**Problem**: Tests hit a load balancer that rate-limits, connection-limits, or adds its own latency.

**Symptoms**: Errors at specific thresholds (e.g., exactly at 1000 RPS), consistent timeout patterns, 429/503 errors at scale.

**Solutions**:
- Test through and without the load balancer to isolate
- Check LB connection limits, rate limit rules, timeout configs
- For k6: check DNS settings — LB may round-robin but k6 DNS-caches to one IP

```javascript
export const options = {
  dns: {
    ttl: '0',            // don't cache DNS — re-resolve for each connection
    select: 'roundRobin', // cycle through DNS results
  },
};
```

### Shared Test Environment Noise

**Problem**: Other tests, deployments, or users share the staging environment.

**Solutions**:
- Run baseline (smoke) test before and after to detect environmental drift
- Tag test runs with timestamps and correlate with deployment logs
- Use dedicated performance test environment with no other traffic
- Schedule load tests in maintenance windows

### Cloud/Container Throttling

**Problem**: Cloud providers throttle network, CPU, or IOPS at certain burst levels.

**Symptoms**: Abrupt latency jump at a specific RPS/bandwidth, not gradual degradation.

**Diagnosis**:
```bash
# AWS: check instance network performance
# Look for "Network bandwidth exceeded" in CloudWatch
# EBS: check BurstBalance metric — if it hits 0, IOPS drop to baseline

# Kubernetes: check if CPU/memory limits are hit
kubectl top pods -n load-test
kubectl describe pod <pod> | grep -A5 "Limits"

# Docker: check if container is throttled
docker stats --no-stream
cat /sys/fs/cgroup/cpu/docker/*/cpu.stat  # look for nr_throttled
```

### DNS Resolution Failures

**Symptoms**: Intermittent connection errors, "no such host" errors during test.

**Diagnosis**:
```bash
# Test DNS resolution time and consistency
for i in $(seq 1 100); do
  dig +short +time=1 api.example.com | head -1
done | sort | uniq -c | sort -rn

# Check if DNS server is overwhelmed
dig api.example.com @8.8.8.8 +stats  # try external DNS
```

**Solutions**:
- Use IP addresses directly for load testing (bypass DNS)
- Set up local DNS cache (dnsmasq) on load gen machine
- Increase DNS TTL in k6: `dns: { ttl: '10m' }`

---

## Network Saturation Detection

### Bandwidth Calculation

```
Required bandwidth = RPS × (avg_request_size + avg_response_size)

Example:
- 10,000 RPS
- Request: 500 bytes (headers + body)
- Response: 5 KB average
- Bandwidth: 10000 × (500 + 5000) = 55 MB/s = 440 Mbps

A 1 Gbps NIC saturates at ~125 MB/s — this test uses ~44% capacity.
Factor in overhead (TCP headers, TLS) → multiply by 1.1-1.3.
```

### Detecting Network Issues During Test

```bash
# Monitor in real-time during test
sar -n DEV 1                          # throughput per interface
ss -s                                  # socket summary
netstat -s | grep -i "segments retransmited"  # retransmissions = congestion

# Watch for connection errors
dmesg | grep -i "nf_conntrack: table full"    # connection tracking overflow
dmesg | grep -i "neighbour table overflow"     # ARP table full
```

### Retransmission as Congestion Signal

```bash
# Before test
cat /proc/net/snmp | grep Tcp | tail -1 | awk '{print "Retransmits:", $13}'
# After test — compare the count
# Retransmission rate > 1% indicates network issues
```

### MTU and Fragmentation

```bash
# Test path MTU
ping -M do -s 1472 target.host  # 1472 + 28 (IP+ICMP headers) = 1500
# If this fails, there's an MTU issue on the path

# Check for fragmentation
netstat -s | grep "fragments"
```

---

## JVM Warm-Up Effects

### The Problem

JVM applications (Java, Kotlin, Scala) have a warm-up period where:
1. **JIT compilation**: Code interpreted initially, then compiled to native code after hotspot detection
2. **Class loading**: Classes loaded lazily on first use
3. **JIT tiering**: C1 compiler → C2 compiler optimization → deoptimization cycles
4. **Connection pool initialization**: First N connections created on demand

### Impact on Load Test Results

```
Time (minutes):
0-2:    p95 = 500ms    ← Cold JVM, interpreted code
2-5:    p95 = 100ms    ← JIT compiling hotspots
5+:     p95 = 30ms     ← Fully warmed, optimized code

If you run a 3-minute test, you're measuring the JVM startup, not your app.
```

### Mitigation Strategies

```javascript
// k6: Add explicit warm-up phase excluded from thresholds
export const options = {
  scenarios: {
    warmup: {
      executor: 'constant-vus',
      vus: 10,
      duration: '3m',
      exec: 'warmupTest',
      tags: { phase: 'warmup' },
    },
    main_test: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 100 },
        { duration: '10m', target: 100 },
        { duration: '2m', target: 0 },
      ],
      startTime: '3m',  // start after warmup completes
      exec: 'mainTest',
    },
  },
  thresholds: {
    // Only apply thresholds to main test, not warmup
    'http_req_duration{phase:main}': ['p(95)<200'],
  },
};

export function warmupTest() {
  http.get(`${BASE_URL}/api/health`);
  sleep(0.5);
}

export function mainTest() {
  const res = http.get(`${BASE_URL}/api/products`, {
    tags: { phase: 'main' },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);
}
```

### Server-Side Warm-Up

```bash
# Before running load test, warm up the JVM:
# Send representative traffic patterns at low rate for 2-5 minutes
k6 run --vus 5 --duration 3m warmup-script.js

# Verify JIT compilation is done
# On the JVM server:
jstat -compiler $(pgrep java) 1000  # watch compilation activity
# When "Compiled" count stabilizes, JVM is warm
```

---

## Connection Pooling Impacts

### How Connection Pools Affect Load Tests

```
Without pooling:  VU → new TCP connection → TLS handshake → request → response → close
With pooling:     VU → reuse existing connection → request → response → keep alive

Connection setup overhead:
- TCP handshake: 1 RTT (~1-50ms depending on distance)
- TLS handshake: 2 RTTs (~2-100ms)
- Total: 3-150ms per new connection
```

### k6 Connection Behavior

```javascript
export const options = {
  // Default: connections are reused within a VU
  noConnectionReuse: false,

  // Share connections across VUs (less realistic but lower overhead)
  noVUConnectionReuse: false,

  // Test NEW connection performance (cold start):
  // noConnectionReuse: true,   // each request makes a new connection
};
```

### Diagnosing Pool Exhaustion

**Symptoms**: Latency suddenly jumps, connection timeout errors, "too many connections" in server logs.

```bash
# On the target server
# PostgreSQL
psql -c "SELECT count(*) FROM pg_stat_activity;"
psql -c "SELECT state, count(*) FROM pg_stat_activity GROUP BY state;"

# MySQL
mysql -e "SHOW STATUS LIKE 'Threads_connected';"
mysql -e "SHOW STATUS LIKE 'Max_used_connections';"
mysql -e "SHOW VARIABLES LIKE 'max_connections';"

# General TCP connections
ss -tan | grep :8080 | awk '{print $1}' | sort | uniq -c
# Look for many ESTABLISHED connections and growing CLOSE_WAIT
```

### Testing Connection Pool Sizing

```javascript
// Gradually increase VUs to find pool exhaustion point
export const options = {
  scenarios: {
    pool_test: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 10 },
        { duration: '1m', target: 25 },
        { duration: '1m', target: 50 },
        { duration: '1m', target: 100 },
        { duration: '1m', target: 200 },
        { duration: '1m', target: 500 },
      ],
    },
  },
  thresholds: {
    http_req_connecting: ['p(95)<50'],    // connection time spike = pool exhaustion
    http_req_tls_handshaking: ['p(95)<100'],
    http_req_waiting: ['p(95)<500'],       // TTFB = includes queue time for pool
  },
};
```

Monitor `http_req_connecting` metric — normally 0 when connections are reused, spikes when new connections are created.

---

## Debugging Slow Tests

### k6 Debug Mode

```bash
# HTTP debug output
k6 run --http-debug="full" script.js  # full request/response headers+bodies
k6 run --http-debug="headers" script.js  # headers only

# Verbose logging
k6 run --verbose script.js

# Log redirects
k6 run --no-follow-redirects script.js  # handle redirects manually
```

### Identifying Slow Requests

```javascript
export default function () {
  const res = http.get(`${BASE_URL}/api/slow-endpoint`);

  // Log timing breakdown for slow requests
  if (res.timings.duration > 1000) {
    console.warn(`Slow request (${res.timings.duration}ms):
      DNS:        ${res.timings.looking_up}ms
      Connecting: ${res.timings.connecting}ms
      TLS:        ${res.timings.tls_handshaking}ms
      Sending:    ${res.timings.sending}ms
      Waiting:    ${res.timings.waiting}ms (TTFB)
      Receiving:  ${res.timings.receiving}ms
      URL:        ${res.url}
      Status:     ${res.status}
    `);
  }
}
```

### Timing Breakdown Explained

```
┌──────────────────────────────────────────────────────┐
│                   http_req_duration                    │
│                                                        │
│  ┌─────────┬──────────┬─────┬────────┬──────┬───────┐ │
│  │ DNS     │ Connect  │ TLS │ Send   │ Wait │ Recv  │ │
│  │ lookup  │          │     │        │(TTFB)│       │ │
│  └─────────┴──────────┴─────┴────────┴──────┴───────┘ │
└──────────────────────────────────────────────────────┘

If DNS is slow:       DNS resolver overloaded, cache DNS results
If Connect is slow:   Server backlog full, too many connections
If TLS is slow:       TLS config issue, consider session resumption
If Wait (TTFB) slow:  Server processing time — this is your app
If Receive is slow:   Large response body, network bandwidth limit
```

### Profiling Test Script Performance

```bash
# k6 built-in profiling (Go pprof)
k6 run --profiling-enabled script.js

# Access profiling data during test at :6565/debug/pprof/
# CPU profile: wget http://localhost:6565/debug/pprof/profile?seconds=30
# Memory: wget http://localhost:6565/debug/pprof/heap
```

---

## Common Error Patterns

### "dial: i/o timeout"

**Cause**: Cannot establish TCP connection within timeout. Server overloaded, firewall blocking, or network issue.

**Fix**:
- Increase timeout: `http.get(url, { timeout: '30s' })`
- Check server connection backlog
- Verify firewall/security group rules
- Check if rate limiting is in effect

### "request timeout"

**Cause**: Connection established but response not received within timeout.

**Fix**:
- Server genuinely slow — that's a valid test result
- Increase timeout if testing intentionally slow endpoints
- Check if server has request queuing

### "read: connection reset by peer"

**Cause**: Server closed connection abruptly. Often from server-side connection limits or WAF.

**Fix**:
- Check server max connections config
- Check WAF/CDN rate limiting rules
- Enable keepalive and connection reuse

### "too many open files"

**Cause**: File descriptor limit reached on load generator.

**Fix**: See [OS Tuning section](#os-tuning-for-load-generators). Increase `ulimit -n`.

### "cannot assign requested address"

**Cause**: Ephemeral port exhaustion. All local ports used by connections in TIME_WAIT.

**Fix**: Enable `tcp_tw_reuse`, widen port range, enable connection keepalive, or distribute test.

### Error Rate Interpretation

```
Error Rate  │ Likely Cause
────────────┼──────────────────────────────────────
< 0.1%      │ Normal — transient issues, acceptable
0.1% - 1%   │ Investigate — connection limits, timeout configs
1% - 5%     │ System stressed — approaching capacity
5% - 20%    │ Overloaded — shedding load, circuit breakers tripping
> 20%       │ System failure — cascading errors, OOM, deadlocks
100%        │ System down OR test misconfigured (wrong URL, auth, etc.)
```

---

## Diagnostic Commands Reference

### During Load Test (Load Generator Machine)

```bash
# System overview
htop                                    # interactive process monitor
vmstat 1                                # CPU, memory, swap, I/O per second
iostat -x 1                             # disk I/O detail

# Network
ss -s                                   # socket summary
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn  # connection states
sar -n DEV 1                            # network interface throughput
sar -n TCP 1                            # TCP connection rates

# Process-specific
pidstat -p $(pgrep k6) -u -r -d 1      # k6 CPU, memory, disk
ls -la /proc/$(pgrep k6)/fd | wc -l    # k6 open file descriptors
```

### During Load Test (Target Server)

```bash
# Application metrics
curl localhost:8080/metrics              # Prometheus metrics endpoint
curl localhost:8080/health               # health check

# Database connections
psql -c "SELECT state, count(*) FROM pg_stat_activity GROUP BY state;"
psql -c "SELECT * FROM pg_stat_database WHERE datname='mydb';"

# JVM (if applicable)
jstat -gc $(pgrep java) 1000            # GC stats every second
jstack $(pgrep java) > thread-dump.txt  # thread dump for deadlock detection

# General
dmesg -T | tail -50                     # kernel messages (OOM killer, etc.)
journalctl -u myapp --since "5 min ago" # application logs
```

### Post-Test Analysis

```bash
# k6 JSON results analysis
cat results.json | jq 'select(.type=="Point" and .metric=="http_req_duration") | .data.value' | \
  awk '{sum+=$1; count++; if($1>max)max=$1; if(min==""||$1<min)min=$1} END{printf "Count: %d\nMin: %.1f\nMax: %.1f\nAvg: %.1f\n", count, min, max, sum/count}'

# Find slowest requests
cat results.json | jq -r 'select(.type=="Point" and .metric=="http_req_duration" and .data.value > 1000) | "\(.data.value)ms \(.data.tags.url)"' | sort -rn | head -20

# Error analysis
cat results.json | jq -r 'select(.type=="Point" and .metric=="http_req_failed" and .data.value==1) | .data.tags.url' | sort | uniq -c | sort -rn
```
