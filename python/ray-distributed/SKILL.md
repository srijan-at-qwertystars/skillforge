---
name: ray-distributed
description: >
  Guide for building distributed Python applications with the Ray framework. Covers Ray Core (tasks, actors, objects, placement groups), Ray Serve (model serving, autoscaling, batching), Ray Tune (hyperparameter tuning, schedulers), Ray Data (streaming datasets, preprocessing), Ray Train (distributed training with PyTorch/TF), KubeRay deployment on Kubernetes, memory management, fault tolerance, observability, and common patterns/anti-patterns. Use when writing, debugging, or architecting Ray-based distributed systems.
globs:
triggers:
  positive:
    - "ray"
    - "ray.remote"
    - "ray.init"
    - "Ray Serve"
    - "Ray Tune"
    - "Ray Data"
    - "Ray Train"
    - "Ray actors"
    - "Ray tasks"
    - "ray.put"
    - "ray.get"
    - "KubeRay"
    - "Ray cluster"
    - "distributed Python with Ray"
    - "Ray autoscaling"
    - "Ray dashboard"
    - "Ray object store"
    - "ray.serve.deployment"
    - "ray.data.read"
    - "RayCluster CRD"
    - "placement group"
    - "ActorPoolStrategy"
  negative:
    - "Dask"
    - "dask.distributed"
    - "Apache Spark"
    - "PySpark"
    - "Celery"
    - "multiprocessing.Pool"
    - "concurrent.futures without Ray"
    - "general ML without Ray"
    - "general Python parallelism"
---

# Ray Distributed Computing

## Initialization

Always call `ray.init()` at program entry. Use `ray.init(address="auto")` to connect to an existing cluster. Set `runtime_env` for dependency isolation:

```python
ray.init(runtime_env={
    "pip": ["numpy", "pandas"],
    "env_vars": {"MY_VAR": "value"},
    "working_dir": "./src",
})
```

For local development, `ray.init()` with no args starts a single-node cluster. Set `num_cpus`/`num_gpus` to limit local resources. Use `ray.init(ignore_reinit_error=True)` in notebooks.

## Ray Core — Tasks

Decorate functions with `@ray.remote` to create tasks. Tasks are stateless, async, and return `ObjectRef`:

```python
@ray.remote
def process(data):
    return transform(data)

# Submit tasks — returns immediately
refs = [process.remote(chunk) for chunk in chunks]
results = ray.get(refs)  # Block until all complete
```

Specify resources: `@ray.remote(num_cpus=2, num_gpus=1)`. Override at call time: `process.options(num_cpus=4).remote(data)`. Set `max_retries=3` for fault tolerance. Use `retry_exceptions=True` to retry on application exceptions.

Use `ray.wait()` to process results as they complete instead of blocking on all:

```python
ready, pending = ray.wait(refs, num_returns=1, timeout=5.0)
```

## Ray Core — Actors

Decorate classes with `@ray.remote` for stateful distributed objects:

```python
@ray.remote
class Counter:
    def __init__(self):
        self.n = 0
    def increment(self):
        self.n += 1
        return self.n

counter = Counter.remote()
ray.get(counter.increment.remote())  # 1
```

Actors persist state across method calls on the same worker. Use `max_concurrency` for async actors. Use `max_restarts` and `max_task_retries` for fault-tolerant actors. Named actors (`Counter.options(name="global_counter", lifetime="detached").remote()`) enable cross-job access.

## Ray Core — Object Store

Ray's distributed object store uses shared memory (Plasma). Use `ray.put()` to store large data once, pass refs to many tasks:

```python
large_data_ref = ray.put(large_dataframe)  # Store once
results = [process.remote(large_data_ref) for _ in range(100)]  # Pass ref, not data
```

Object store defaults to ~30% of system RAM. Tune with `ray.init(object_store_memory=10**10)`. Objects are reference-counted and GC'd when no refs remain. Spill-to-disk activates when store is full — monitor with `ray memory` CLI.

## Ray Core — Placement Groups

Reserve resources atomically across nodes for gang scheduling:

```python
from ray.util.placement_group import placement_group
pg = placement_group([{"CPU": 4, "GPU": 1}] * 4, strategy="PACK")
ray.get(pg.ready())
actor = MyActor.options(
    scheduling_strategy=PlacementGroupSchedulingStrategy(placement_group=pg)
).remote()
```

Strategies: `PACK` (colocate on fewest nodes), `SPREAD` (distribute across nodes), `STRICT_PACK`, `STRICT_SPREAD`.

## Ray Serve — Model Serving

Build scalable HTTP endpoints for ML inference:

```python
from ray import serve

@serve.deployment(
    num_replicas="auto",
    ray_actor_options={"num_gpus": 1},
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 10,
        "target_num_ongoing_requests_per_replica": 5,
    },
)
class ModelServer:
    def __init__(self):
        self.model = load_model()

    async def __call__(self, request):
        data = await request.json()
        return self.model.predict(data)

app = ModelServer.bind()
serve.run(app, route_prefix="/predict")
```

Use `@serve.batch(max_batch_size=32, batch_wait_timeout_s=0.1)` for dynamic batching on GPU workloads. Set `max_ongoing_requests` per replica for backpressure. Configure `graceful_shutdown_timeout_s` for zero-downtime deploys. Compose multiple deployments with `DeploymentHandle` for pipeline architectures.

Deploy with Serve config files for production:

```yaml
applications:
  - name: my_app
    route_prefix: /
    import_path: serve_app:app
    deployments:
      - name: ModelServer
        num_replicas: auto
        autoscaling_config:
          min_replicas: 2
          max_replicas: 20
```

Apply with `serve deploy config.yaml`.

## Ray Tune — Hyperparameter Tuning

```python
from ray import tune
from ray.tune.schedulers import ASHAScheduler
from ray.tune.search.optuna import OptunaSearch

def train_fn(config):
    for epoch in range(100):
        loss = train_epoch(config["lr"], config["batch_size"])
        tune.report({"loss": loss, "epoch": epoch})

tuner = tune.Tuner(
    train_fn,
    tune_config=tune.TuneConfig(
        scheduler=ASHAScheduler(metric="loss", mode="min"),
        search_alg=OptunaSearch(),
        num_samples=50,
    ),
    param_space={
        "lr": tune.loguniform(1e-5, 1e-1),
        "batch_size": tune.choice([16, 32, 64, 128]),
    },
    run_config=tune.RunConfig(storage_path="/tmp/ray_results"),
)
results = tuner.fit()
best = results.get_best_result(metric="loss", mode="min")
```

Schedulers: `ASHAScheduler` (async early stopping — default choice), `PopulationBasedTraining` (mutates top performers), `HyperBandScheduler`. Search algorithms: `OptunaSearch`, `HyperOptSearch`, `BayesOptSearch`. Always set `metric` and `mode` consistently. Use `tune.with_resources` to assign CPUs/GPUs per trial. Resume failed experiments with `restore` path.

## Ray Data — Distributed Datasets

Stream-first architecture for ML preprocessing. Lazy execution, block-based:

```python
import ray.data

ds = ray.data.read_parquet("s3://bucket/data/")
ds = ds.map_batches(preprocess_fn, batch_format="pandas")
ds = ds.filter(lambda row: row["label"] is not None)
ds = ds.random_shuffle()

# Feed directly into training
for batch in ds.iter_torch_batches(batch_size=64):
    train_step(batch)
```

Use `map_batches` with `compute=ray.data.ActorPoolStrategy(min_size=2, max_size=8)` for GPU preprocessing. Reads Parquet, CSV, JSON, images, binary. Writes to same formats. Use `repartition()` to control parallelism. Ray Data is the "last mile" bridge from storage to training — avoid materializing full datasets in memory.

## Ray Train — Distributed Training

Unified API for distributed training across frameworks:

```python
from ray.train.torch import TorchTrainer
from ray.train import ScalingConfig, RunConfig, CheckpointConfig

def train_loop(config):
    model = build_model()
    model = ray.train.torch.prepare_model(model)
    dataset = ray.train.get_dataset_shard("train")
    for epoch in range(config["epochs"]):
        for batch in dataset.iter_torch_batches(batch_size=64):
            loss = train_step(model, batch)
        ray.train.report({"loss": loss})

trainer = TorchTrainer(
    train_loop,
    train_loop_config={"epochs": 10},
    scaling_config=ScalingConfig(num_workers=4, use_gpu=True),
    run_config=RunConfig(checkpoint_config=CheckpointConfig(num_to_keep=2)),
    datasets={"train": ray.data.read_parquet("s3://data/train/")},
)
result = trainer.fit()
```

Use `prepare_model` and `prepare_data_loader` for automatic DDP wrapping. Supports PyTorch, TensorFlow, HuggingFace Transformers, Lightning, XGBoost. Integrates with Ray Tune for distributed HPO + distributed training. Use `CheckpointConfig` to manage disk usage.

## KubeRay — Kubernetes Deployment

Install the operator:

```bash
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm install kuberay-operator kuberay/kuberay-operator --namespace ray-system --create-namespace
```

RayCluster CRD with autoscaling:

```yaml
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: my-cluster
spec:
  rayVersion: '2.9.0'
  enableInTreeAutoscaling: true
  headGroupSpec:
    rayStartParams:
      dashboard-host: '0.0.0.0'
    template:
      spec:
        containers:
        - name: ray-head
          image: rayproject/ray:2.9.0-py310
          resources:
            requests: { cpu: "2", memory: "8Gi" }
            limits: { cpu: "4", memory: "16Gi" }
  workerGroupSpecs:
  - groupName: gpu-workers
    replicas: 2
    minReplicas: 1
    maxReplicas: 10
    rayStartParams: {}
    template:
      spec:
        containers:
        - name: ray-worker
          image: rayproject/ray:2.9.0-py310-gpu
          resources:
            requests: { cpu: "4", memory: "16Gi", nvidia.com/gpu: "1" }
```

Three autoscaling tiers: Ray internal (Serve replicas) → Ray Autoscaler (add/remove pods) → K8s cluster autoscaler (add/remove nodes). Production hardening: use external Redis for GCS HA, enable TLS, set RBAC, integrate Prometheus/Grafana. Use `RayJob` CRD for batch workloads, `RayService` CRD for Serve deployments.

## Observability

Access Ray Dashboard at port 8265. Monitor: node/actor/task status, object store usage, GPU utilization, log aggregation. CLI tools: `ray status` (cluster resources), `ray memory` (object store diagnostics), `ray timeline` (Chrome trace). Export metrics to Prometheus with `ray[default]` extras. Set `RAY_DEDUP_LOGS=0` to see all worker logs.

## Memory Management

- Object store defaults to 30% system RAM; tune with `object_store_memory` parameter
- Use `ray.put()` once, pass `ObjectRef` to many tasks — avoid repeated serialization
- Call `del ref` explicitly when done with large objects
- Use `ray.wait()` with `num_returns` to limit in-flight objects and prevent OOM
- Monitor with `ray memory` and dashboard memory tab
- Spill-to-disk is automatic but slow — size object store to minimize spilling
- Set `_max_pending_calls_per_actor` on actor handles to bound queue memory

## Fault Tolerance

- Tasks: `max_retries` (default 3), `retry_exceptions=True` for application errors
- Actors: `max_restarts` for actor process recovery, `max_task_retries` for pending tasks
- Detached actors survive driver failure; use for long-lived services
- Node failures: GCS detects via heartbeats; tasks on dead nodes are rescheduled
- Use external Redis GCS for head node HA in production
- Object reconstruction: lost objects are recomputed from lineage if creator task is deterministic
- Enable `ray.init(_system_config={"task_events_report_interval_ms": 1000})` for detailed fault tracking

## Critical Anti-Patterns — Avoid These

1. **`ray.get()` in loops** — blocks parallelism. Collect refs first, then `ray.get(all_refs)`
2. **Passing large objects by value** — use `ray.put()` + `ObjectRef` instead
3. **Too many tiny tasks** — task overhead dominates. Batch work into coarser tasks
4. **Unbounded task submission** — submit in batches, use `ray.wait()` for backpressure
5. **Closures capturing large objects** — extract data with `ray.put()` before remote call
6. **Ignoring `ray.wait()`** — always prefer over blocking `ray.get()` for streaming results
7. **Global mutable state** — workers are separate processes; use actors for shared state
8. **Head node running compute** — assign zero CPUs to head in production clusters

## Patterns — Use These

- **Tree reduction** — aggregate results hierarchically instead of collecting all to driver
- **Actor pool** — `ray.util.ActorPool` for worker pool patterns with load balancing
- **Async actors** — `max_concurrency > 1` with `async def` methods for I/O-heavy workloads
- **Nested remote calls** — tasks can launch sub-tasks; use for recursive parallelism
- **Pipeline parallelism** — overlap data loading, compute, and writing using task graphs
- **Detached actors as services** — persistent microservices within Ray cluster
- **Resource labels** — custom resources (`{"special_hardware": 1}`) for heterogeneous clusters

## Ray vs Alternatives

| Feature | Ray | Dask | Spark |
|---------|-----|------|-------|
| Primary use | ML/AI workloads | Data analytics | Big data ETL |
| Stateful compute | Native actors | Limited | No |
| GPU support | First-class | Basic | Limited |
| Model serving | Ray Serve built-in | No | No |
| HPO | Ray Tune built-in | No | No |
| Latency | Sub-ms task overhead | ~1ms | High |
| Python-native | Yes | Yes | PySpark wrapper |

Choose Ray for ML pipelines, model serving, RL, and GPU workloads. Choose Dask for pandas-like analytics. Choose Spark for massive ETL and SQL analytics.

## Testing

Test Ray code with `ray.init(num_cpus=2)` in fixtures. Use `ray.shutdown()` in teardown. Mock remote calls by testing the underlying function directly (call without `.remote()`). For integration tests, use `ray.cluster_utils.Cluster` to simulate multi-node. Set `RAY_DEDUP_LOGS=0` and `RAY_ENABLE_RECORD_ACTOR_TASK_LOGGING=1` for test debugging.

## Production Checklist

- [ ] Set `runtime_env` with pinned dependencies
- [ ] Configure object store size for workload
- [ ] Use external Redis for GCS high availability
- [ ] Set `max_retries` and `max_restarts` for fault tolerance
- [ ] Enable autoscaling with min/max bounds
- [ ] Monitor with Dashboard + Prometheus + Grafana
- [ ] Set resource requests/limits in K8s manifests
- [ ] Use `RAY_DEDUP_LOGS=0` during debugging only
- [ ] Test with `ray.init(local_mode=True)` for debugging serialization issues
- [ ] Profile with `ray timeline` before optimizing

## References

Detailed deep-dive guides in `references/`:

- **[ray-serve-guide.md](references/ray-serve-guide.md)** — Ray Serve deep dive: deployment graphs, model composition, dynamic batching, streaming responses, FastAPI integration, autoscaling config, multi-model serving, A/B testing, canary deployments, gRPC support, production deployment patterns, monitoring, performance tuning.

- **[troubleshooting.md](references/troubleshooting.md)** — Common Ray issues and fixes: OOM (object store and worker heap), task/actor failures, serialization errors, slow task submission, GCS failures, head node bottleneck, dashboard not loading, KubeRay pod CrashLoops, resource deadlocks, placement group issues, networking, performance degradation. Includes debugging tools reference.

- **[kuberay-guide.md](references/kuberay-guide.md)** — KubeRay deep dive: RayCluster/RayJob/RayService CRDs, autoscaling (3-tier), node groups, GPU scheduling, persistent storage, Prometheus/Grafana monitoring, production cluster sizing, multi-tenancy, security (RBAC, TLS), networking, upgrades and maintenance.

## Scripts

Operational scripts in `scripts/`:

- **[setup-ray-cluster.sh](scripts/setup-ray-cluster.sh)** — Set up a local Ray cluster: install Ray, start head node, add configurable workers, verify cluster health. Supports `--workers`, `--head-cpus`, `--worker-cpus`, `--object-store-memory`.

- **[deploy-ray-serve.sh](scripts/deploy-ray-serve.sh)** — Deploy a Ray Serve application from a config YAML: validate config, deploy, wait for health, optional health checks. Supports `--address`, `--health-check`, `--wait`.

- **[ray-benchmark.sh](scripts/ray-benchmark.sh)** — Benchmark Ray tasks, actors, and object store: submission throughput, round-trip latency (p50/p95/p99), actor creation/method call rates, object put/get transfer rates. Supports `--tasks`, `--actors`, `--object-size-mb`, `--all`.

## Assets

Reusable configuration and example code in `assets/`:

- **[ray-cluster.yaml](assets/ray-cluster.yaml)** — Production KubeRay RayCluster manifest with autoscaling, CPU + GPU worker groups, health probes, shared memory volumes, and Prometheus annotations.

- **[ray-serve-config.yaml](assets/ray-serve-config.yaml)** — Ray Serve deployment config with preprocessor → model → postprocessor pipeline, autoscaling, resource limits, and health checks.

- **[serve-example.py](assets/serve-example.py)** — Complete Ray Serve ML model serving example: FastAPI integration, Pydantic validation, dynamic batching, model composition pipeline, health endpoints, batch prediction endpoint.

- **[data-pipeline.py](assets/data-pipeline.py)** — Ray Data preprocessing pipeline: multi-format reading (Parquet/CSV/JSON), streaming transforms, feature engineering, GPU-accelerated preprocessing with ActorPoolStrategy, sample data generation.

- **[docker-compose.yml](assets/docker-compose.yml)** — Local Ray cluster with Docker Compose: head + 2 workers (scalable), shared storage, health checks, dashboard at localhost:8265.


<!-- tested: needs-fix -->
