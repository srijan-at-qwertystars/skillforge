# Ray Troubleshooting Guide

## Table of Contents

- [Out of Memory — Object Store Full](#out-of-memory--object-store-full)
- [Out of Memory — Worker Heap](#out-of-memory--worker-heap)
- [Task and Actor Failures](#task-and-actor-failures)
- [Serialization Errors](#serialization-errors)
- [Slow Task Submission](#slow-task-submission)
- [GCS Failures](#gcs-failures)
- [Head Node Bottleneck](#head-node-bottleneck)
- [Dashboard Not Loading](#dashboard-not-loading)
- [KubeRay Pod CrashLoops](#kuberay-pod-crashloops)
- [Resource Deadlocks](#resource-deadlocks)
- [Placement Group Issues](#placement-group-issues)
- [Networking Issues](#networking-issues)
- [Performance Degradation](#performance-degradation)
- [Ray Serve Issues](#ray-serve-issues)
- [Ray Data Issues](#ray-data-issues)
- [Cluster Startup Failures](#cluster-startup-failures)
- [Debugging Tools Reference](#debugging-tools-reference)

---

## Out of Memory — Object Store Full

### Symptoms
- `RayOutOfMemoryError: The object store is full`
- `ObjectStoreFullError` when calling `ray.put()`
- Tasks failing with `Plasma store out of memory`
- Dashboard shows object store at 100%

### Diagnosis

```bash
# Check object store usage
ray memory --stats-only

# Detailed object breakdown
ray memory

# Dashboard: http://<head>:8265 → Memory tab
```

### Solutions

**1. Increase object store size**
```python
ray.init(object_store_memory=20 * 1024**3)  # 20 GB
```
Or via CLI: `ray start --object-store-memory=20000000000`

**2. Reduce in-flight objects**
```python
# BAD: submits all tasks immediately, stores all results
refs = [process.remote(x) for x in huge_dataset]
results = ray.get(refs)

# GOOD: process in batches with backpressure
batch_size = 100
results = []
for i in range(0, len(huge_dataset), batch_size):
    batch_refs = [process.remote(x) for x in huge_dataset[i:i+batch_size]]
    results.extend(ray.get(batch_refs))
```

**3. Delete references explicitly**
```python
ref = ray.put(large_data)
result = ray.get(process.remote(ref))
del ref  # Allow GC to reclaim object store memory
```

**4. Use ray.wait() for streaming**
```python
refs = [process.remote(x) for x in dataset]
while refs:
    ready, refs = ray.wait(refs, num_returns=1)
    result = ray.get(ready[0])
    handle_result(result)  # Process and discard immediately
```

**5. Enable object spilling (automatic but slow)**
```python
ray.init(_system_config={
    "object_spilling_config": json.dumps({
        "type": "filesystem",
        "params": {"directory_path": ["/tmp/ray_spill"]},
        "buffer_size": 100_000_000,
    }),
})
```

### Root causes
- Submitting too many tasks without consuming results
- Storing large intermediate results that aren't needed
- Circular references preventing GC
- Multiple copies of the same data (pass `ObjectRef` not values)

## Out of Memory — Worker Heap

### Symptoms
- Workers killed by OS OOM killer
- `Worker killed by signal 9 (SIGKILL)`
- Increasing RSS without bound

### Diagnosis
```bash
# Check per-worker memory
ray status
# Look at Dashboard → Nodes → per-worker memory

# Check system memory
free -h
dmesg | tail -20  # Look for OOM killer messages
```

### Solutions

**1. Set memory limits**
```python
@ray.remote(memory=2 * 1024**3)  # 2 GB limit per task
def memory_intensive():
    ...
```

**2. Process data in chunks**
```python
@ray.remote
def process_file(path):
    # BAD: loads entire file
    # data = pd.read_csv(path)

    # GOOD: process in chunks
    for chunk in pd.read_csv(path, chunksize=10000):
        yield process_chunk(chunk)
```

**3. Use Ray Data for large datasets**
```python
# Instead of loading all data in a single task:
ds = ray.data.read_parquet("s3://bucket/data/")
ds = ds.map_batches(transform, batch_size=1000)
```

**4. Monitor with memory profiling**
```python
import tracemalloc
tracemalloc.start()
# ... your code ...
snapshot = tracemalloc.take_snapshot()
top_stats = snapshot.statistics('lineno')
for stat in top_stats[:10]:
    print(stat)
```

## Task and Actor Failures

### Symptoms
- `RayTaskError` with traceback from remote worker
- `RayActorError: The actor died`
- Tasks stuck in PENDING state
- `ray.get()` raises unexpected exceptions

### Diagnosis

```bash
# Check task/actor status
ray list actors --filter state=DEAD
ray list tasks --filter state=FAILED

# Get error details from dashboard
# http://<head>:8265 → Jobs → Tasks/Actors
```

### Solutions

**1. Enable retries for transient failures**
```python
@ray.remote(
    max_retries=5,
    retry_exceptions=[ConnectionError, TimeoutError],
)
def flaky_task():
    ...
```

**2. Fault-tolerant actors**
```python
@ray.remote(
    max_restarts=3,          # Restart actor process up to 3 times
    max_task_retries=2,      # Retry pending tasks on actor restart
)
class ResilientWorker:
    def __init__(self):
        self.state = self._recover_state()

    def _recover_state(self):
        """Load state from external storage on restart."""
        try:
            return load_checkpoint()
        except FileNotFoundError:
            return {}
```

**3. Handle RayActorError**
```python
try:
    result = ray.get(actor.method.remote())
except ray.exceptions.RayActorError as e:
    if e.actor_died:
        logger.error(f"Actor died: {e}")
        actor = ResilientWorker.remote()  # Recreate
    raise
```

**4. Debug task failures**
```python
# Get the full traceback
try:
    result = ray.get(task_ref)
except ray.exceptions.RayTaskError as e:
    print(f"Task failed: {e}")
    print(f"Traceback:\n{e.traceback_str}")
```

### Common causes
- Worker OOM (see above)
- Unhandled exceptions in task/actor code
- Node failure (network partition, hardware fault)
- Resource starvation (task can't get required CPU/GPU)
- Segfault in native code (C extensions, CUDA)

## Serialization Errors

### Symptoms
- `TypeError: cannot pickle 'xxx' object`
- `ray.exceptions.RaySerializationError`
- `Could not serialize the argument`
- `Failed to unpickle serialized exception`

### Diagnosis
```python
# Test if an object is serializable
import ray.cloudpickle as pickle
try:
    pickle.dumps(my_object)
    print("Serializable!")
except Exception as e:
    print(f"Not serializable: {e}")
```

### Solutions

**1. Common unpicklable objects and fixes**

```python
# PROBLEM: Lambda with closure
f = lambda x: x + some_var  # Captures local variable

# FIX: Use a regular function
def f(x, offset=some_var):
    return x + offset

# PROBLEM: Database connection
@ray.remote
def query(conn, sql):  # conn is not serializable
    ...

# FIX: Create connection inside the task
@ray.remote
def query(conn_params, sql):
    conn = create_connection(**conn_params)
    return conn.execute(sql)

# PROBLEM: Lock/thread objects
@ray.remote
class Bad:
    def __init__(self):
        self.lock = threading.Lock()  # Not serializable across processes

# FIX: Use Ray actors for synchronization, or recreate in __init__

# PROBLEM: Open file handles
@ray.remote
def process(file_handle):  # Can't serialize file handle
    ...

# FIX: Pass the path, open inside task
@ray.remote
def process(file_path):
    with open(file_path) as f:
        ...
```

**2. Custom serialization**
```python
import ray

# Register custom serializer
class MyComplexObject:
    def __init__(self, data, metadata):
        self.data = data
        self.metadata = metadata

def serialize_my_obj(obj):
    return {"data": obj.data, "metadata": obj.metadata}

def deserialize_my_obj(state):
    return MyComplexObject(state["data"], state["metadata"])

ray.util.register_serializer(
    MyComplexObject,
    serializer=serialize_my_obj,
    deserializer=deserialize_my_obj,
)
```

**3. Use __reduce__ for custom pickle support**
```python
class CustomModel:
    def __init__(self, path):
        self.path = path
        self.model = load_heavy_model(path)

    def __reduce__(self):
        # Only serialize the path, reload model on deserialization
        return (CustomModel, (self.path,))
```

**4. Large object serialization**
```python
# BAD: serialize large object with every task call
large_model = load_model()  # 2 GB
refs = [predict.remote(large_model, x) for x in data]
# Serialized 2 GB × len(data) times!

# GOOD: put once, pass reference
model_ref = ray.put(large_model)  # Serialized once
refs = [predict.remote(model_ref, x) for x in data]
```

### Common unpicklable types
| Type | Fix |
|------|-----|
| `threading.Lock` | Use Ray actors or recreate in `__init__` |
| `socket.socket` | Pass connection params, create inside task |
| DB connections | Pass connection string, connect inside task |
| File handles | Pass path, open inside task |
| Generator objects | Convert to list or use Ray Data |
| CUDA tensors | Move to CPU before serialization |
| `logging.Logger` | Recreate logger inside task/actor |

## Slow Task Submission

### Symptoms
- `ray.remote()` calls take >10ms each
- High overhead for many small tasks
- Dashboard shows low CPU utilization despite many tasks
- Driver CPU pegged at 100%

### Diagnosis
```python
import time
start = time.perf_counter()
refs = [noop.remote() for _ in range(10000)]
elapsed = time.perf_counter() - start
print(f"Submission rate: {10000/elapsed:.0f} tasks/sec")
# Should be >10,000 tasks/sec for lightweight tasks
```

### Solutions

**1. Batch small tasks into larger ones**
```python
# BAD: 1M tiny tasks
refs = [process_one.remote(item) for item in million_items]

# GOOD: batch into chunks
@ray.remote
def process_batch(items):
    return [process_one_local(item) for item in items]

chunks = [million_items[i:i+1000] for i in range(0, len(million_items), 1000)]
refs = [process_batch.remote(chunk) for chunk in chunks]
```

**2. Limit concurrent submissions**
```python
MAX_IN_FLIGHT = 1000
refs = []
for item in huge_dataset:
    if len(refs) >= MAX_IN_FLIGHT:
        ready, refs = ray.wait(refs, num_returns=1)
        process_result(ray.get(ready[0]))
    refs.append(process.remote(item))
# Drain remaining
results = ray.get(refs)
```

**3. Use actors for stateful streaming**
```python
@ray.remote
class StreamProcessor:
    def process_many(self, items):
        return [self._process(item) for item in items]

pool = ray.util.ActorPool([StreamProcessor.remote() for _ in range(8)])
results = list(pool.map(lambda a, batch: a.process_many.remote(batch), batches))
```

**4. Check driver-side bottlenecks**
- Avoid Python loops with per-item `ray.remote()` calls
- Use numpy/pandas to prepare data before shipping to tasks
- Profile the driver with `cProfile` to find bottlenecks

## GCS Failures

### Symptoms
- `GcsRpcError: Failed to connect to GCS`
- Cluster becomes unresponsive
- `raylet` process crashes
- Tasks/actors cannot be scheduled
- `ray status` hangs or errors

### Diagnosis
```bash
# Check GCS process
ps aux | grep gcs_server

# Check GCS logs
cat /tmp/ray/session_latest/logs/gcs_server.out
cat /tmp/ray/session_latest/logs/gcs_server.err

# Check port connectivity
nc -zv <head_ip> 6379  # GCS port
```

### Solutions

**1. External Redis for HA (production)**
```bash
ray start --head \
    --redis-password=<password> \
    --external-address=redis://<redis-host>:6379
```
With Redis Sentinel or Redis Cluster for automatic failover.

**2. GCS recovery**
```bash
# Restart GCS on the head node
ray stop
ray start --head --port=6379

# Workers will automatically reconnect if configured with:
ray start --address=<head>:6379 \
    --gcs-reconnect-timeout-s=60
```

**3. Monitor GCS health**
```python
# Programmatic check
ray.nodes()  # Returns empty or errors if GCS is down

# CLI
ray health-check --address <head>:6379
```

**4. GCS memory limits**
```bash
# GCS stores metadata in memory — limit with:
ray start --head --system-config='{"gcs_server_memory_limit_mb": 4096}'
```

## Head Node Bottleneck

### Symptoms
- Head node CPU at 100%
- Scheduling latency increases with cluster size
- Dashboard sluggish
- GCS response times degrade

### Solutions

**1. Don't schedule compute on head**
```bash
ray start --head --num-cpus=0 --num-gpus=0
```

**2. Separate driver from head**
```python
# Run driver on a separate machine
ray.init(address="ray://<head>:10001")
```

**3. Scale GCS resources**
```yaml
# In KubeRay, give head node more resources
headGroupSpec:
  template:
    spec:
      containers:
      - name: ray-head
        resources:
          requests:
            cpu: "4"
            memory: "16Gi"
          limits:
            cpu: "8"
            memory: "32Gi"
```

**4. Reduce dashboard overhead**
```bash
# Disable dashboard for batch jobs
ray start --head --include-dashboard=false
```

## Dashboard Not Loading

### Symptoms
- `http://<head>:8265` returns connection refused
- Dashboard loads but shows no data
- Dashboard shows stale data

### Diagnosis
```bash
# Check dashboard process
ps aux | grep ray_dashboard

# Check dashboard logs
cat /tmp/ray/session_latest/logs/dashboard.log
cat /tmp/ray/session_latest/logs/dashboard_agent.log

# Check port binding
ss -tlnp | grep 8265
```

### Solutions

**1. Ensure dashboard dependencies are installed**
```bash
pip install "ray[default]"  # Includes dashboard deps
# Or specifically:
pip install ray-dashboard
```

**2. Bind to correct interface**
```bash
ray start --head --dashboard-host=0.0.0.0 --dashboard-port=8265
```

**3. Port forwarding in Kubernetes**
```bash
kubectl port-forward svc/raycluster-head-svc 8265:8265 -n ray-system
```

**4. Check firewall/security groups**
```bash
# Ensure port 8265 is open
iptables -L -n | grep 8265
# For cloud: check security group allows inbound 8265
```

**5. Dashboard agent not running**
```bash
# Dashboard agent runs on each node; check it's alive
ray list cluster-nodes  # Shows dashboard agent status
```

## KubeRay Pod CrashLoops

### Symptoms
- Ray pods in `CrashLoopBackOff` state
- `kubectl describe pod` shows `OOMKilled` or `Error`
- Pods restart repeatedly
- `kubectl logs <pod>` shows errors

### Diagnosis
```bash
# Check pod status
kubectl get pods -n ray-system -l ray.io/cluster=<cluster-name>

# Get pod details
kubectl describe pod <pod-name> -n ray-system

# Check logs (current and previous)
kubectl logs <pod-name> -n ray-system
kubectl logs <pod-name> -n ray-system --previous

# Check events
kubectl get events -n ray-system --sort-by=.metadata.creationTimestamp
```

### Solutions

**1. OOMKilled — increase memory limits**
```yaml
containers:
- name: ray-worker
  resources:
    requests:
      memory: "8Gi"
    limits:
      memory: "16Gi"  # Increase this
```

Also increase object store memory fraction:
```yaml
rayStartParams:
  object-store-memory: "4000000000"  # 4 GB
```

**2. Image pull errors**
```yaml
spec:
  containers:
  - name: ray-worker
    image: rayproject/ray:2.9.0-py310  # Use exact tag, not latest
    imagePullPolicy: IfNotPresent
  imagePullSecrets:
  - name: my-registry-secret  # For private registries
```

**3. Readiness/liveness probe failures**
```yaml
containers:
- name: ray-head
  ports:
  - containerPort: 6379  # GCS
  - containerPort: 8265  # Dashboard
  readinessProbe:
    httpGet:
      path: /
      port: 8265
    initialDelaySeconds: 30  # Give time for startup
    periodSeconds: 10
    failureThreshold: 5
  livenessProbe:
    httpGet:
      path: /
      port: 8265
    initialDelaySeconds: 60
    periodSeconds: 15
    failureThreshold: 10
```

**4. Volume mount failures**
```bash
# Check PVC status
kubectl get pvc -n ray-system
# Ensure PV is bound and storage class exists
kubectl get sc
```

**5. RBAC issues**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ray-worker-role
  namespace: ray-system
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
```

**6. DNS resolution failures**
```bash
# Test DNS from inside a pod
kubectl exec -it <pod> -n ray-system -- nslookup <head-svc>
kubectl exec -it <pod> -n ray-system -- ping <head-svc>
```

## Resource Deadlocks

### Symptoms
- Tasks/actors stuck in `PENDING_CREATION` or `PENDING_EXECUTION`
- `ray status` shows resources available but tasks aren't scheduled
- Cluster appears hung
- No error messages, just tasks not progressing

### Diagnosis
```bash
# Check resource availability
ray status

# Look for pending tasks
ray list tasks --filter state=PENDING

# Check for placement group deadlocks
ray list placement-groups --filter state=PENDING
```

### Solutions

**1. Avoid tasks spawning tasks that compete for same resources**
```python
# DEADLOCK: task needs 1 CPU, spawns child that needs 1 CPU
# If cluster has 4 CPUs and 4 parent tasks run, children can't get CPUs
@ray.remote(num_cpus=1)
def parent():
    return ray.get(child.remote())  # Child needs CPU too!

@ray.remote(num_cpus=1)
def child():
    return 42

# FIX: Reserve resources for children
@ray.remote(num_cpus=0)  # Parent doesn't hold CPU while waiting
def parent():
    return ray.get(child.remote())

# Or use async pattern
@ray.remote(num_cpus=1)
async def parent():
    ref = child.remote()
    # CPU is released while awaiting
    return await ref
```

**2. Actor pool deadlock**
```python
# DEADLOCK: All actors waiting for each other
@ray.remote
class Worker:
    def __init__(self, other_workers):
        self.others = other_workers

    def process(self):
        # Calls another worker that might call back
        return ray.get(self.others[0].process.remote())

# FIX: Use async and avoid circular dependencies
@ray.remote
class Worker:
    async def process(self, data):
        return await self._process(data)
```

**3. Placement group resource exhaustion**
```python
# PROBLEM: Placement groups reserving all resources
pg = placement_group([{"CPU": 100}])  # Takes all CPUs

# FIX: Size placement groups appropriately
# and remove unused ones
ray.util.remove_placement_group(pg)
```

**4. GPU resource mismatch**
```python
# PROBLEM: Requesting more GPUs than exist
@ray.remote(num_gpus=2)
def train():  # Cluster only has 1 GPU per node
    ...

# FIX: Match resource requests to actual hardware
@ray.remote(num_gpus=1)
def train():
    ...
```

## Placement Group Issues

### Symptoms
- `PlacementGroupSchedulingError`
- Placement groups stuck in `PENDING` state
- `STRICT_PACK` fails on heterogeneous clusters
- Resources appear available but PG can't be created

### Diagnosis
```bash
ray list placement-groups
ray list placement-groups --filter state=PENDING
```

### Solutions

**1. Verify resource availability**
```python
# Check if the cluster can satisfy the placement group
import ray
nodes = ray.nodes()
for node in nodes:
    print(f"Node {node['NodeID'][:8]}: {node['Resources']}")
```

**2. Use appropriate strategy**
```python
# STRICT_PACK: all bundles on one node (may fail if node too small)
# PACK: colocate as much as possible (more flexible)
# SPREAD: distribute across nodes
# STRICT_SPREAD: exactly one bundle per node

# For GPU training, prefer PACK over STRICT_PACK
pg = placement_group(
    [{"GPU": 1, "CPU": 4}] * 4,
    strategy="PACK",  # More flexible than STRICT_PACK
)
```

**3. Handle placement group timeout**
```python
try:
    ray.get(pg.ready(), timeout=60)
except ray.exceptions.GetTimeoutError:
    ray.util.remove_placement_group(pg)
    raise RuntimeError("Could not create placement group — insufficient resources")
```

**4. Clean up orphaned placement groups**
```python
# List and remove pending PGs
pgs = ray.util.placement_group_table()
for pg_id, info in pgs.items():
    if info["state"] == "PENDING":
        pg = ray.util.get_placement_group(info["name"])
        ray.util.remove_placement_group(pg)
```

## Networking Issues

### Symptoms
- Workers can't connect to head node
- `ConnectionError: Failed to connect to <ip>:<port>`
- Slow inter-node communication
- Object transfer timeouts

### Diagnosis
```bash
# Test connectivity from worker to head
nc -zv <head_ip> 6379   # GCS
nc -zv <head_ip> 8265   # Dashboard
nc -zv <head_ip> 10001  # Client port

# Check Ray ports
ray list nodes  # Shows node IPs and ports
```

### Solutions

**1. Port range configuration**
```bash
# Ray uses a range of ports; ensure they're open
ray start --head \
    --port=6379 \
    --dashboard-port=8265 \
    --min-worker-port=10002 \
    --max-worker-port=19999
```

**2. Firewall rules (cloud)**
```
Inbound rules for Ray cluster:
  - 6379: GCS (head only)
  - 8265: Dashboard (head only)
  - 10001: Client API (head only)
  - 10002-19999: Worker ports (all nodes, internal)
  - 8076: Object manager (all nodes, internal)
```

**3. DNS issues in Kubernetes**
```yaml
# Use headless service for Ray cluster
apiVersion: v1
kind: Service
metadata:
  name: ray-head-svc
spec:
  clusterIP: None
  selector:
    ray.io/node-type: head
  ports:
  - name: gcs
    port: 6379
  - name: dashboard
    port: 8265
```

**4. Large object transfer slow**
```python
# Object manager port might be bottleneck
# Increase object manager memory
ray.init(_system_config={
    "object_manager_pull_timeout_ms": 30000,
    "object_manager_push_timeout_ms": 30000,
})
```

## Performance Degradation

### Symptoms
- Task throughput drops over time
- Latency increases gradually
- Cluster becomes sluggish after hours of operation

### Solutions

**1. Memory leak detection**
```python
# Monitor object store growth
import ray

while True:
    stats = ray.cluster_resources()
    used = ray.available_resources()
    print(f"Object store: {stats.get('object_store_memory', 0) - used.get('object_store_memory', 0):.2f} bytes used")
    time.sleep(60)
```

**2. GC pressure**
```python
# Force GC on workers periodically
@ray.remote
def gc_worker():
    import gc
    gc.collect()
    return True
```

**3. Log accumulation**
```bash
# Ray logs can fill disk
du -sh /tmp/ray/session_latest/logs/

# Rotate/clean old sessions
ray stop
rm -rf /tmp/ray/session_*/  # Be careful in production
```

**4. Profiling**
```bash
# Generate timeline trace
ray timeline --output timeline.json
# Open in Chrome: chrome://tracing

# CPU profiling
py-spy record -o profile.svg --pid <worker_pid>
```

## Ray Serve Issues

### Deployment stuck in UPDATING
```bash
# Check deployment status
serve status
# Check controller logs
cat /tmp/ray/session_latest/logs/serve/controller.log
```

Fix: Ensure sufficient resources for new replicas. Check for import errors in deployment code.

### 502/503 errors under load
- Increase `max_ongoing_requests` per replica
- Lower `target_num_ongoing_requests_per_replica` for faster scaling
- Increase `max_replicas`
- Check for slow model initialization in `__init__`

### Cold start latency
- Set `min_replicas >= 1` to avoid scale-from-zero
- Pre-download models in Docker image, not in `__init__`
- Use `initial_replicas` for warm start

## Ray Data Issues

### `DatasetPipelineError` or blocks stuck
```python
# Increase parallelism
ds = ray.data.read_parquet(path).repartition(200)

# Limit concurrency to prevent OOM
ds.map_batches(fn, batch_size=1000, concurrency=4)
```

### Slow reads from S3/GCS
```python
# Increase read parallelism
ds = ray.data.read_parquet(
    path,
    parallelism=200,
    ray_remote_args={"num_cpus": 0.5},
)
```

## Cluster Startup Failures

### `ray start` hangs
```bash
# Check for port conflicts
ss -tlnp | grep -E "6379|8265|10001"

# Kill orphan Ray processes
ray stop --force

# Clear stale session
rm -rf /tmp/ray/session_latest
```

### Workers can't join cluster
```bash
# Verify head node address
ray start --address=<head_ip>:6379 --verbose

# Common issues:
# 1. Wrong IP (use internal IP, not public)
# 2. Firewall blocking ports
# 3. Ray version mismatch between head and worker
# 4. Python version mismatch
```

### Version mismatch
```bash
# All nodes must run the same Ray version
ray --version  # Check on each node
pip install ray==2.9.0  # Pin version
```

## Debugging Tools Reference

| Tool | Purpose | Usage |
|------|---------|-------|
| `ray status` | Cluster resource overview | `ray status` |
| `ray memory` | Object store diagnostics | `ray memory --stats-only` |
| `ray list actors` | List all actors | `ray list actors --filter state=ALIVE` |
| `ray list tasks` | List tasks | `ray list tasks --filter state=FAILED` |
| `ray list nodes` | Node information | `ray list nodes` |
| `ray list placement-groups` | PG status | `ray list placement-groups` |
| `ray timeline` | Chrome trace generation | `ray timeline -o trace.json` |
| `ray health-check` | Cluster health | `ray health-check --address <head>:6379` |
| `serve status` | Ray Serve status | `serve status` |
| `serve config` | Current Serve config | `serve config` |
| Dashboard | Web UI | `http://<head>:8265` |

### Environment variables for debugging

```bash
export RAY_DEDUP_LOGS=0                    # Show all worker logs (not just unique)
export RAY_ENABLE_RECORD_ACTOR_TASK_LOGGING=1  # Detailed actor/task logs
export RAY_BACKEND_LOG_LEVEL=debug         # Verbose Ray internals
export RAY_PROFILING=1                     # Enable profiling
export RAY_task_events_report_interval_ms=1000  # Faster event reporting
```

### Log locations
```
/tmp/ray/session_latest/logs/
├── dashboard.log           # Dashboard process
├── dashboard_agent.log     # Per-node dashboard agent
├── gcs_server.out          # GCS stdout
├── gcs_server.err          # GCS stderr
├── monitor.log             # Autoscaler monitor
├── raylet.out              # Raylet stdout
├── raylet.err              # Raylet stderr
├── worker-*.out            # Worker task stdout
├── worker-*.err            # Worker task stderr
└── serve/
    ├── controller.log      # Serve controller
    ├── proxy.log           # HTTP proxy
    └── replica_*.log       # Per-replica logs
```
