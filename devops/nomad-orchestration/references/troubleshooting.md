# Nomad Troubleshooting Guide

## Table of Contents

- [Allocation Placement Failures](#allocation-placement-failures)
- [No Nodes Available](#no-nodes-available)
- [Task Driver Errors](#task-driver-errors)
- [Networking Issues](#networking-issues)
- [Consul Service Mesh Problems](#consul-service-mesh-problems)
- [Health Check Failures](#health-check-failures)
- [OOM Kills](#oom-kills)
- [GC Pressure](#gc-pressure)
- [Leader Election Issues](#leader-election-issues)
- [Snapshot and Restore](#snapshot-and-restore)
- [General Debugging Toolkit](#general-debugging-toolkit)

---

## Allocation Placement Failures

Placement failures mean the scheduler cannot find a node that satisfies a job's requirements.

### Diagnosis

```shell
# Check evaluation status for failure reasons
nomad eval status <eval-id>

# Check job status for placement failures
nomad job status <job-name>
# Look for "Placement Failures" section

# Detailed allocation info
nomad alloc status -verbose <alloc-id>
```

### Common Causes and Fixes

**Resource exhaustion (CPU, memory, disk)**

```
Placement Failures: 1 unplaced
  Dimension "memory" exhausted on 5 of 5 nodes
```

- **Fix**: Reduce task `resources` or add more client nodes.
- **Check**: `nomad node status -verbose <node-id>` → look at "Allocated Resources" vs "Total Resources".
- **Common mistake**: Forgetting that `memory` is in MB. `memory = 256` means 256 MB, not bytes.

**Constraint filtering all nodes**

```
Constraint "missing devices" filtered 9 of 9 nodes
Constraint "${node.class} = gpu" filtered 5 of 5 nodes
```

- **Fix**: Verify the constraint attribute exists on target nodes.
- **Check**: `nomad node status -verbose <node-id>` → look at attributes and metadata.
- **Common mistake**: Typos in `${meta.*}` keys — they're case-sensitive.

**Disk exhaustion from dead allocations**

```
Dimension "disk" exhausted on 3 of 3 nodes
```

- Dead allocations reserve disk until GC'd.
- **Fix**: `nomad system gc` to force garbage collection.
- **Fix**: Increase `ephemeral_disk` or reduce `migrate` block's `max_parallel`.

**Datacenter mismatch**

- Job specifies `datacenters = ["dc1"]` but nodes are in `dc2`.
- **Fix**: Check `nomad node status` for actual datacenter names.

### Prevention

- Always run `nomad job plan` before `nomad job run` to preview placement.
- Set up alerts on `nomad.nomad.blocked_evals.total_blocked` metric.
- Maintain 20–30% resource headroom across the cluster.

---

## No Nodes Available

When **zero** nodes are eligible for a job, the entire evaluation blocks.

### Systematic Debugging

```shell
# Step 1: Verify nodes are registered and ready
nomad node status
# Look for "Status = ready" and "Eligibility = eligible"

# Step 2: Check if nodes are in the correct datacenter
nomad node status <node-id> | grep Datacenter

# Step 3: Check if node class matches constraints
nomad node status -verbose <node-id> | grep "Node Class"

# Step 4: Check available resources on each node
nomad node status -verbose <node-id> | grep -A 10 "Allocated Resources"

# Step 5: Check if node is draining
nomad node status <node-id> | grep Drain
```

### Common Scenarios

| Symptom | Cause | Fix |
|---------|-------|-----|
| 0 of 0 nodes | No clients registered | Start Nomad clients, check `server_join` config |
| 0 of N eligible | All filtered by constraints | Relax constraints or add matching nodes |
| N nodes, all exhausted | Cluster full | Add nodes or reduce resource requests |
| Node "ineligible" | Node marked ineligible | `nomad node eligibility -enable <node-id>` |
| Node "draining" | Node being drained | Wait for drain to complete or cancel: `nomad node drain -disable <node-id>` |

### Node Connectivity Issues

```shell
# Check client can reach servers
nomad agent-info | grep -A5 "client"

# Check server membership
nomad server members

# Check if client is fingerprinting properly
nomad node status -verbose <node-id> | grep -A30 "Attributes"
```

---

## Task Driver Errors

### Docker Driver

**Image pull failures**

```
Driver Failure: Failed to pull image "myregistry/app:v1":
  Error response from daemon: pull access denied
```

- **Fix**: Configure Docker auth in client config or task:
  ```hcl
  config {
    image = "myregistry/app:v1"
    auth {
      username = "user"
      password = "pass"
    }
  }
  ```
- Or configure `~/.docker/config.json` on the client host.
- **Check**: `docker pull <image>` directly on the client node.

**Container start failures**

```
Driver Failure: failed to start container: OCI runtime error
```

- **Check**: Docker daemon logs: `journalctl -u docker`
- **Common causes**: Invalid entrypoint/command, missing capabilities, SELinux/AppArmor blocking.
- **Fix**: Test the container locally with equivalent `docker run` command.

**Network mode conflicts**

```
Driver Failure: failed to create network: bridge network not available
```

- Bridge mode requires CNI plugins.
- **Fix**: Install CNI plugins: `apt install containernetworking-plugins` or download to `/opt/cni/bin/`.

### Exec Driver

**Chroot failures**

```
Driver Failure: failed to create chroot: no such file or directory
```

- `exec` driver requires `chroot_env` binaries on the client.
- **Fix**: Configure `chroot_env` in client config or switch to `raw_exec` (less secure).

### Java Driver

```
Driver Failure: failed to find java: exec: "java": not found
```

- **Fix**: Install JDK/JRE on client nodes or use Docker driver with a Java base image.
- **Check**: `java -version` on the client host.

### General Driver Debugging

```shell
# Check which drivers are detected on a node
nomad node status -verbose <node-id> | grep "driver\."

# Check driver health
nomad node status -verbose <node-id> | grep "driver\.docker\.healthy"

# Client-side logs (most driver errors surface here)
journalctl -u nomad -f --grep "driver"
```

---

## Networking Issues

### Bridge Mode Gotchas

**CNI plugins not installed**

```
Failed to create network: plugin bridge not found in path [/opt/cni/bin]
```

- **Fix**: Install CNI plugins:
  ```shell
  curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz \
    | sudo tar -xz -C /opt/cni/bin
  ```

**Bridge mode only on Linux**

- Bridge networking uses Linux network namespaces. Not available on Windows or macOS.
- **Fix**: Use `host` mode on non-Linux platforms.

**iptables conflicts**

- Docker's iptables rules can conflict with Nomad's CNI bridge rules.
- **Fix**: Set Docker's `--iptables=false` if using Nomad's bridge mode exclusively.
- **Fix**: Or use separate bridge interfaces.

**DNS resolution inside bridge network**

- Containers in bridge mode may not resolve Consul DNS.
- **Fix**: Configure DNS in the task:
  ```hcl
  config {
    dns_servers = ["172.17.0.1"]  # Docker bridge gateway
  }
  ```

### Port Exhaustion

**Dynamic port range depleted**

```
Failed to assign ports: no free dynamic ports
```

- Default range: 20000–32000 (12,000 ports per node).
- **Fix**: Expand range in client config:
  ```hcl
  client {
    min_dynamic_port = 10000
    max_dynamic_port = 40000
  }
  ```
- **Fix**: Reduce static port usage. Move services to dynamic ports with service discovery.
- **Check**: Count allocations per node: `nomad node status <node-id>` → allocation count.

**Static port conflicts**

```
Port 8080 already in use
```

- Two jobs requesting the same static port on the same node.
- **Fix**: Use dynamic ports with `to` mapping:
  ```hcl
  port "http" { to = 8080 }   # dynamic host port → container 8080
  ```
- **Fix**: Use `constraint { operator = "distinct_hosts" }` to ensure one alloc per node.

### Debugging Network Issues

```shell
# Inside allocation network namespace
nomad alloc exec <alloc-id> sh -c "ip addr; ip route; cat /etc/resolv.conf"

# Check port mappings
nomad alloc status <alloc-id> | grep -A5 "Ports"

# Test connectivity from allocation
nomad alloc exec <alloc-id> curl -s http://localhost:8080/health

# Check iptables rules on host
sudo iptables -L -n -t nat | grep -i nomad
```

---

## Consul Service Mesh Problems

### Sidecar Proxy Not Starting

```
Task "connect-proxy-web" failed: Driver Failure
```

- **Check**: Envoy binary available on client nodes.
  ```shell
  which envoy
  envoy --version
  ```
- **Fix**: Install Envoy or configure Consul to download it:
  ```hcl
  # Consul client config
  connect {
    enabled = true
  }
  ```

### Service Registration Failures

```
Failed to register service: Unexpected response code: 403
```

- **Fix**: Ensure Nomad has a valid Consul ACL token with `service:write` permissions.
- **Check**: Consul token in Nomad's config:
  ```hcl
  consul {
    token = "<consul-acl-token>"
  }
  ```

### Upstream Connection Refused

```
curl: (7) Failed to connect to 127.0.0.1 port 5432: Connection refused
```

- Upstream port not listening → sidecar proxy hasn't started or upstream service is down.
- **Debug**:
  ```shell
  # Check sidecar proxy is running
  nomad alloc status <alloc-id> | grep connect-proxy

  # Check upstream service exists in Consul
  consul catalog services | grep postgres

  # Check Envoy listeners
  nomad alloc exec <alloc-id> curl -s localhost:19000/listeners
  ```

### Intention Denials

```
upstream connect error: 403 Forbidden
```

- Consul intentions blocking the connection.
- **Fix**: Create an allow intention:
  ```shell
  consul intention create -allow web postgres
  ```

### Health Check Flapping in Consul

- Service alternates between healthy and unhealthy.
- **Causes**: Check interval too short, resource contention, network latency.
- **Fix**: Increase check timeout and interval:
  ```hcl
  check {
    type     = "http"
    path     = "/health"
    interval = "15s"   # was 5s
    timeout  = "5s"    # was 2s
  }
  ```

---

## Health Check Failures

### HTTP Check Returns Non-2xx

```
Check "service: api-web" is failing: HTTP check returned 503
```

- **Debug**: Test the health endpoint directly:
  ```shell
  nomad alloc exec <alloc-id> curl -v http://localhost:8080/health
  ```
- **Common causes**: Application not fully started, missing dependencies, database connection pool exhausted.
- **Fix**: Increase `min_healthy_time` to give the app more startup time.

### Check Timeout

```
Check "service: api-web" is failing: deadline reached
```

- Health check takes longer than configured timeout.
- **Fix**: Increase timeout or optimize health endpoint:
  ```hcl
  check {
    timeout = "5s"   # increase from default 2s
  }
  ```
- **Anti-pattern**: Health endpoint that queries databases or external services. Health checks should be fast and local.

### TCP Check Failing

```
Check "service: redis" is failing: dial tcp: connection refused
```

- Service not listening on the expected port.
- **Debug**: Check port mapping and which port the app actually binds to:
  ```shell
  nomad alloc status <alloc-id> | grep Ports
  nomad alloc exec <alloc-id> ss -tlnp
  ```

### Deployment Stuck — Health Deadline Exceeded

```
Deployment "abc123" status: failed
  Status Description: Failed due to progress deadline
```

- New allocations never became healthy within `healthy_deadline`.
- **Debug**: Check alloc events and task logs:
  ```shell
  nomad alloc status <alloc-id>
  nomad alloc logs <alloc-id>
  nomad alloc logs -stderr <alloc-id>
  ```
- **Fix**: Increase `healthy_deadline` for slow-starting applications.
- **Fix**: Add `initial_status = "warning"` to checks if the app has a long warm-up.

---

## OOM Kills

### Detecting OOM

```shell
# Check allocation events
nomad alloc status <alloc-id>
# Look for: "OOM Killed" or "Memory limit reached"

# Check host dmesg
dmesg | grep -i "oom\|killed"

# Check cgroup memory stats
cat /sys/fs/cgroup/memory/nomad/<alloc-id>/*/memory.max_usage_in_bytes
```

### Common Causes

1. **Task `memory` limit too low**: App legitimately needs more memory.
2. **Memory leak**: App gradually consumes more memory over time.
3. **JVM heap not matching Nomad limits**: JVM `-Xmx` exceeds Nomad's `memory` allocation.
4. **Sidecar overhead**: Envoy/connect proxy consumes memory not accounted for in task resources.

### Fixes

**Increase memory limit**:
```hcl
resources {
  memory     = 512    # base limit in MB
  memory_max = 768    # oversubscription ceiling (if enabled)
}
```

**Memory oversubscription (v1.1+)**:
```hcl
# Server config — enable oversubscription
server {
  memory_oversubscription_enabled = true
}

# Job spec — set memory_max above memory
resources {
  memory     = 256    # guaranteed
  memory_max = 512    # burst limit
}
```

- `memory` is the guaranteed amount used for scheduling decisions.
- `memory_max` is the hard cgroup limit; exceeding it triggers OOM kill.

**JVM alignment**:
```hcl
task "app" {
  config {
    args = ["-Xmx384m", "-Xms128m"]   # Xmx < Nomad memory limit
  }
  resources {
    memory = 512   # leave headroom for JVM metaspace, native memory
  }
}
```

### Monitoring

- Track `nomad.client.allocs.memory.usage` and set alerts at 80% of limit.
- Use `memory.max_usage_in_bytes` to find peak usage and right-size allocations.

---

## GC Pressure

Nomad's garbage collector removes dead allocations, evaluations, and job versions. Excessive dead state causes performance degradation.

### Symptoms

- Disk usage on clients grows continuously.
- `nomad job status` shows thousands of dead allocations.
- Placement failures citing disk exhaustion.
- Server API responses slow down.

### Manual GC

```shell
# Force GC across the cluster
nomad system gc

# Check GC status
nomad operator debug -interval 30s -duration 2m
```

### Tuning GC

Server config:

```hcl
server {
  job_gc_interval   = "5m"     # how often GC runs (default: 5m)
  job_gc_threshold  = "4h"     # age before dead jobs are eligible (default: 4h)
  eval_gc_threshold = "1h"     # age before dead evals are eligible (default: 1h)
  node_gc_threshold = "24h"    # age before dead nodes are eligible (default: 24h)
}
```

Client config:

```hcl
client {
  gc_interval           = "1m"     # local GC check interval
  gc_disk_usage_threshold = 80     # trigger GC when disk usage > 80%
  gc_inode_usage_threshold = 70    # trigger GC when inode usage > 70%
  gc_max_allocs         = 50       # max dead allocs to keep per node
  gc_parallel_destroys  = 2        # concurrent alloc destroys
}
```

### Prevention

- Set aggressive `gc_max_allocs` on high-churn nodes.
- Monitor disk usage on client nodes.
- For periodic/parameterized jobs that dispatch frequently, lower `job_gc_threshold`.

---

## Leader Election Issues

### No Leader Elected

```
Error querying agent info: Unexpected response code: 500
  No cluster leader
```

### Diagnosis

```shell
# Check server membership and leader
nomad server members

# Check Raft peers
nomad operator raft list-peers

# Check server logs for election errors
journalctl -u nomad --grep "leader\|election\|raft" --since "1 hour ago"
```

### Common Causes and Fixes

**Lost quorum (majority of servers down)**

- 3-server cluster: lose 2 → no quorum.
- 5-server cluster: lose 3 → no quorum.
- **Fix**: Restart downed servers. If data loss occurred, use `nomad operator raft remove-peer` to remove dead peers and recover.

**Split brain (network partition)**

- Servers in different network segments elect separate leaders.
- **Fix**: Resolve network partition. Nomad will auto-heal once connectivity restores.

**Clock skew**

- Large clock differences between servers cause Raft instability.
- **Fix**: Ensure NTP is configured and synced on all servers. Clock skew > 500ms is dangerous.

**Disk I/O latency**

- Raft commits require durable writes. Slow disks → election timeouts.
- **Fix**: Use SSDs for `data_dir`. Monitor `nomad.raft.commitTime` — should be < 50ms.

### Emergency Recovery

```shell
# If quorum is permanently lost (majority of servers dead with no recovery)
# On the single surviving server:
nomad operator raft remove-peer -address=<dead-server-1-rpc-addr>
nomad operator raft remove-peer -address=<dead-server-2-rpc-addr>

# The surviving server becomes a single-node cluster
# Then bootstrap new servers to rejoin
```

### Prevention

- Always run 3 or 5 servers (never 2 or 4).
- Use `autopilot` for automatic dead server cleanup:
  ```hcl
  autopilot {
    cleanup_dead_servers      = true
    last_contact_threshold    = "200ms"
    max_trailing_logs         = 250
    server_stabilization_time = "10s"
  }
  ```
- Regular snapshots: `nomad operator snapshot save backup.snap`

---

## Snapshot and Restore

### Taking Snapshots

```shell
# Save snapshot to file
nomad operator snapshot save backup-$(date +%Y%m%d-%H%M%S).snap

# Inspect snapshot metadata
nomad operator snapshot inspect backup.snap
```

### Automated Snapshots (Enterprise)

```hcl
# Server config
autopilot {
  enable_custom_upgrades = true
}
```

For OSS, use cron:

```shell
# /etc/cron.d/nomad-snapshot
0 */6 * * * root nomad operator snapshot save /backup/nomad/snap-$(date +\%Y\%m\%d-\%H\%M\%S).snap && find /backup/nomad -name "snap-*" -mtime +7 -delete
```

### Restoring from Snapshot

```shell
# Stop all servers except one
# On the surviving server:
nomad operator snapshot restore backup.snap

# Restart the server
systemctl restart nomad

# Start other servers — they'll replicate from the restored leader
```

### Restore Gotchas

- **Version mismatch**: Restore must use the same or newer Nomad version as the snapshot source.
- **State divergence**: After restore, running allocations may not match server state. Run `nomad system reconcile summaries` to fix.
- **ACL tokens**: Restored snapshots include ACL state. Tokens from after the snapshot time are lost.
- **Raft peers**: If restoring to a new cluster, you may need to reconfigure `server_join` and Raft peers.

### Verification After Restore

```shell
# Verify leader election
nomad server members

# Verify jobs are present
nomad job status

# Reconcile any state drift
nomad system reconcile summaries

# Check for blocked evaluations
nomad eval list -status blocked
```

---

## General Debugging Toolkit

### Essential Commands

```shell
# Cluster overview
nomad status

# Server health
nomad server members
nomad operator raft list-peers

# Node health
nomad node status
nomad node status -verbose <node-id>

# Job debugging
nomad job status <job-name>
nomad job deployments <job-name>
nomad job evaluations <job-name>

# Allocation debugging
nomad alloc status <alloc-id>
nomad alloc logs <alloc-id>
nomad alloc logs -stderr <alloc-id>
nomad alloc logs -f <alloc-id>       # follow/stream

# Interactive debugging
nomad alloc exec <alloc-id> /bin/sh

# Filesystem inspection
nomad alloc fs <alloc-id> /
nomad alloc fs <alloc-id> /alloc/logs/
```

### API Debugging

```shell
# Agent health
curl -s "${NOMAD_ADDR}/v1/agent/health" | jq

# Cluster stats
curl -s "${NOMAD_ADDR}/v1/operator/metrics" | jq '.Gauges[] | select(.Name | contains("blocked"))'

# Node resources
curl -s "${NOMAD_ADDR}/v1/nodes" | jq '.[].Status'
```

### Log Locations

| Component | Default Log Path | Notes |
|-----------|-----------------|-------|
| Nomad agent | `journalctl -u nomad` | Server and client logs |
| Task stdout | `/alloc/logs/<task>.stdout.0` | Via `nomad alloc logs` |
| Task stderr | `/alloc/logs/<task>.stderr.0` | Via `nomad alloc logs -stderr` |
| Docker daemon | `journalctl -u docker` | Container runtime errors |
| Consul agent | `journalctl -u consul` | Service mesh, health checks |

### Debug Bundle

```shell
# Generate comprehensive debug bundle
nomad operator debug -interval 30s -duration 5m -output nomad-debug.tar.gz

# Includes: agent info, metrics, allocations, raft state, goroutine dumps
```

### Metrics to Watch

| Metric | Alert Threshold | Meaning |
|--------|----------------|---------|
| `nomad.raft.commitTime` | > 100ms | Raft consensus slow — disk I/O issue |
| `nomad.nomad.blocked_evals.total_blocked` | > 0 sustained | Jobs can't be placed |
| `nomad.client.allocs.memory.usage` | > 80% of limit | OOM risk |
| `nomad.client.allocs.cpu.total_ticks` | > 90% of allocated | CPU contention |
| `nomad.runtime.num_goroutines` | > 10,000 | Potential goroutine leak |
| `nomad.nomad.plan.reject` | > 5% of plans | Scheduling contention |
| `nomad.serf.member.failed` | > 0 | Node communication failure |
