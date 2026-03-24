# Ray Serve — Comprehensive Guide

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Basic Deployments](#basic-deployments)
- [FastAPI Integration](#fastapi-integration)
- [Dynamic Batching](#dynamic-batching)
- [Streaming Responses](#streaming-responses)
- [Deployment Graphs and Model Composition](#deployment-graphs-and-model-composition)
- [Multi-Model Serving](#multi-model-serving)
- [A/B Testing and Canary Deployments](#ab-testing-and-canary-deployments)
- [Autoscaling Configuration](#autoscaling-configuration)
- [gRPC Support](#grpc-support)
- [Health Checks and Readiness](#health-checks-and-readiness)
- [Production Deployment Patterns](#production-deployment-patterns)
- [Configuration File Reference](#configuration-file-reference)
- [Monitoring and Observability](#monitoring-and-observability)
- [Performance Tuning](#performance-tuning)
- [Common Pitfalls](#common-pitfalls)

---

## Overview

Ray Serve is a scalable, framework-agnostic model serving library built on Ray. Key properties:

- **Framework-agnostic** — serve PyTorch, TensorFlow, scikit-learn, HuggingFace, custom logic
- **Python-native** — no YAML-only config, full programmatic control
- **Composable** — chain multiple models/deployments into pipelines
- **Autoscaling** — scale replicas based on request load automatically
- **Incremental adoption** — add to existing Ray applications without rewriting

Ray Serve runs as actors on the Ray cluster. The Serve controller manages deployment state, replica lifecycle, and routing. An HTTP proxy actor handles inbound traffic and load-balances across replicas.

## Architecture

```
Client Request
    │
    ▼
┌──────────────┐
│  HTTP Proxy   │  (or gRPC Proxy)
│  (per node)   │
└──────┬───────┘
       │  route matching + load balancing
       ▼
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│  Replica 0   │   │  Replica 1   │   │  Replica 2   │
│  (Ray Actor) │   │  (Ray Actor) │   │  (Ray Actor) │
└──────────────┘   └──────────────┘   └──────────────┘
       │                  │                  │
       ▼                  ▼                  ▼
   Model / Business Logic / Downstream Services
```

Key components:
- **Serve Controller** — singleton actor managing deployment state, autoscaling decisions
- **HTTP Proxy** — one per head node (configurable on worker nodes), routes requests
- **Replica** — Ray actor running deployment code, horizontally scalable
- **DeploymentHandle** — typed reference for inter-deployment calls (replaces old `DeploymentHandle`)

## Basic Deployments

### Minimal deployment

```python
from ray import serve

@serve.deployment
class Greeter:
    def __call__(self, request):
        name = request.query_params.get("name", "world")
        return f"Hello, {name}!"

app = Greeter.bind()
serve.run(app)
# GET http://localhost:8000/?name=Ray → "Hello, Ray!"
```

### With constructor arguments

```python
@serve.deployment
class ModelServer:
    def __init__(self, model_path: str, device: str = "cpu"):
        import torch
        self.model = torch.load(model_path, map_location=device)
        self.device = device

    async def __call__(self, request):
        data = await request.json()
        tensor = torch.tensor(data["input"]).to(self.device)
        with torch.no_grad():
            result = self.model(tensor)
        return {"prediction": result.tolist()}

app = ModelServer.bind(model_path="/models/bert.pt", device="cuda:0")
```

### Resource allocation

```python
@serve.deployment(
    num_replicas=3,
    ray_actor_options={
        "num_cpus": 2,
        "num_gpus": 1,
        "memory": 4 * 1024 * 1024 * 1024,  # 4 GB
    },
)
class HeavyModel:
    ...
```

## FastAPI Integration

Ray Serve integrates natively with FastAPI for request validation, OpenAPI docs, middleware:

```python
from fastapi import FastAPI
from pydantic import BaseModel
from ray import serve

api = FastAPI(
    title="ML Prediction API",
    description="Production ML model serving",
    version="1.0.0",
)

class PredictionRequest(BaseModel):
    features: list[float]
    model_version: str = "v1"

class PredictionResponse(BaseModel):
    prediction: float
    confidence: float
    model_version: str

@serve.deployment
@serve.ingress(api)
class PredictionService:
    def __init__(self):
        self.models = {
            "v1": load_model("v1"),
            "v2": load_model("v2"),
        }

    @api.post("/predict", response_model=PredictionResponse)
    async def predict(self, req: PredictionRequest) -> PredictionResponse:
        model = self.models[req.model_version]
        pred, conf = model.predict(req.features)
        return PredictionResponse(
            prediction=pred,
            confidence=conf,
            model_version=req.model_version,
        )

    @api.get("/health")
    async def health(self):
        return {"status": "healthy"}

    @api.get("/models")
    async def list_models(self):
        return {"models": list(self.models.keys())}

app = PredictionService.bind()
```

Benefits:
- Automatic request/response validation via Pydantic
- OpenAPI docs at `/docs` and `/redoc`
- Middleware support (CORS, auth, logging)
- Path parameters, query parameters, headers
- WebSocket support

## Dynamic Batching

Batching amortizes GPU kernel launch overhead and improves throughput for vectorizable operations:

```python
@serve.deployment
class BatchedPredictor:
    def __init__(self):
        self.model = load_model()

    @serve.batch(max_batch_size=32, batch_wait_timeout_s=0.1)
    async def predict_batch(self, inputs: list[dict]) -> list[dict]:
        """Called with a list of inputs, must return a list of same length."""
        import numpy as np
        features = np.array([inp["features"] for inp in inputs])
        predictions = self.model.predict(features)  # Single batch inference
        return [{"prediction": float(p)} for p in predictions]

    async def __call__(self, request):
        data = await request.json()
        return await self.predict_batch(data)
```

Tuning batching parameters:

| Parameter | Description | Tuning guidance |
|-----------|-------------|-----------------|
| `max_batch_size` | Max inputs per batch | Match GPU batch capacity; larger = higher throughput, higher latency |
| `batch_wait_timeout_s` | Max wait time to fill batch | Lower = lower latency at low load; higher = better batching at steady load |

For GPU models, set `max_batch_size` to 2-4x what fits in GPU memory for optimal throughput. Under low load, requests are dispatched without waiting for a full batch once the timeout expires.

### Adaptive batching pattern

```python
@serve.deployment
class AdaptiveBatcher:
    def __init__(self):
        self.model = load_model()
        self._request_count = 0

    @serve.batch(max_batch_size=64, batch_wait_timeout_s=0.05)
    async def handle_batch(self, inputs: list[np.ndarray]) -> list[np.ndarray]:
        batch = np.stack(inputs)
        return list(self.model(batch))

    async def __call__(self, request):
        data = await request.json()
        arr = np.array(data["input"])
        return await self.handle_batch(arr)
```

## Streaming Responses

Ray Serve supports streaming for LLM token-by-token generation and large payloads:

```python
from starlette.responses import StreamingResponse
import asyncio

@serve.deployment
class StreamingLLM:
    def __init__(self):
        self.model = load_llm()

    async def generate_tokens(self, prompt: str):
        for token in self.model.stream(prompt):
            yield token
            await asyncio.sleep(0)  # Yield control

    async def __call__(self, request):
        data = await request.json()
        return StreamingResponse(
            self.generate_tokens(data["prompt"]),
            media_type="text/plain",
        )

app = StreamingLLM.bind()
```

### Server-Sent Events (SSE) for chat

```python
from starlette.responses import StreamingResponse

@serve.deployment
class ChatEndpoint:
    async def generate_sse(self, prompt: str):
        async for token in self.model.astream(prompt):
            yield f"data: {json.dumps({'token': token})}\n\n"
        yield "data: [DONE]\n\n"

    async def __call__(self, request):
        data = await request.json()
        return StreamingResponse(
            self.generate_sse(data["prompt"]),
            media_type="text/event-stream",
        )
```

### Streaming with DeploymentHandle

```python
@serve.deployment
class Router:
    def __init__(self, llm_handle):
        self.llm = llm_handle

    async def __call__(self, request):
        data = await request.json()
        # Use .options(stream=True) for handle-level streaming
        gen = self.llm.options(stream=True).predict.remote(data["prompt"])
        async def stream():
            async for token in gen:
                yield token
        return StreamingResponse(stream(), media_type="text/plain")
```

## Deployment Graphs and Model Composition

Chain deployments using `bind()` and `DeploymentHandle`:

### Sequential pipeline

```python
@serve.deployment
class Preprocessor:
    def preprocess(self, raw_input: dict) -> dict:
        # Tokenize, normalize, etc.
        return {"tokens": tokenize(raw_input["text"])}

@serve.deployment
class Model:
    def __init__(self):
        self.model = load_model()

    def predict(self, processed: dict) -> dict:
        return {"logits": self.model(processed["tokens"])}

@serve.deployment
class Postprocessor:
    def format(self, prediction: dict) -> dict:
        label = decode_label(prediction["logits"])
        return {"label": label, "confidence": max(prediction["logits"])}

@serve.deployment
class Pipeline:
    def __init__(self, preprocessor, model, postprocessor):
        self.preprocessor = preprocessor
        self.model = model
        self.postprocessor = postprocessor

    async def __call__(self, request):
        data = await request.json()
        processed = await self.preprocessor.preprocess.remote(data)
        prediction = await self.model.predict.remote(processed)
        result = await self.postprocessor.format.remote(prediction)
        return result

app = Pipeline.bind(
    Preprocessor.bind(),
    Model.bind(),
    Postprocessor.bind(),
)
```

### Ensemble pattern

```python
@serve.deployment
class Ensemble:
    def __init__(self, model_a, model_b, model_c):
        self.models = [model_a, model_b, model_c]

    async def __call__(self, request):
        data = await request.json()
        predictions = await asyncio.gather(
            *[m.predict.remote(data) for m in self.models]
        )
        # Average ensemble
        avg = np.mean([p["score"] for p in predictions])
        return {"ensemble_score": float(avg)}
```

### Conditional routing

```python
@serve.deployment
class Router:
    def __init__(self, text_model, image_model):
        self.text_model = text_model
        self.image_model = image_model

    async def __call__(self, request):
        data = await request.json()
        if data.get("type") == "image":
            return await self.image_model.predict.remote(data)
        return await self.text_model.predict.remote(data)
```

## Multi-Model Serving

Serve multiple models from a single Ray Serve application:

```python
@serve.deployment(route_prefix="/sentiment")
class SentimentModel:
    def __init__(self):
        from transformers import pipeline
        self.pipe = pipeline("sentiment-analysis")

    async def __call__(self, request):
        data = await request.json()
        return self.pipe(data["text"])

@serve.deployment(route_prefix="/summarize")
class SummarizationModel:
    def __init__(self):
        from transformers import pipeline
        self.pipe = pipeline("summarization")

    async def __call__(self, request):
        data = await request.json()
        return self.pipe(data["text"], max_length=100)

# Deploy both as separate applications
serve.run(SentimentModel.bind(), name="sentiment", route_prefix="/sentiment")
serve.run(SummarizationModel.bind(), name="summarize", route_prefix="/summarize")
```

### Multi-model with shared resources

```python
@serve.deployment(
    ray_actor_options={"num_gpus": 0.5},  # Share GPU across models
)
class SharedGPUModel:
    def __init__(self, model_name: str):
        self.model = load_model(model_name)

    async def __call__(self, request):
        data = await request.json()
        return self.model.predict(data["input"])

sentiment = SharedGPUModel.bind(model_name="sentiment-bert")
ner = SharedGPUModel.bind(model_name="ner-bert")
```

## A/B Testing and Canary Deployments

### Traffic splitting with a router

```python
import random

@serve.deployment
class ABRouter:
    def __init__(self, model_a, model_b, traffic_split: float = 0.9):
        self.model_a = model_a
        self.model_b = model_b
        self.traffic_split = traffic_split

    async def __call__(self, request):
        if random.random() < self.traffic_split:
            result = await self.model_a.predict.remote(await request.json())
            return {**result, "variant": "A"}
        else:
            result = await self.model_b.predict.remote(await request.json())
            return {**result, "variant": "B"}

app = ABRouter.bind(
    ModelV1.bind(),
    ModelV2.bind(),
    traffic_split=0.9,  # 90% to V1, 10% to V2
)
```

### Header-based routing for canary

```python
@serve.deployment
class CanaryRouter:
    def __init__(self, stable, canary):
        self.stable = stable
        self.canary = canary

    async def __call__(self, request):
        if request.headers.get("X-Canary") == "true":
            return await self.canary.predict.remote(await request.json())
        return await self.stable.predict.remote(await request.json())
```

### Gradual rollout pattern

```python
@serve.deployment
class GradualRollout:
    def __init__(self, old_model, new_model):
        self.old_model = old_model
        self.new_model = new_model
        self.rollout_pct = 0.0  # Start at 0%

    def set_rollout(self, pct: float):
        self.rollout_pct = max(0.0, min(1.0, pct))

    async def __call__(self, request):
        data = await request.json()
        # Consistent hashing for same user → same model
        user_id = data.get("user_id", "")
        use_new = (hash(user_id) % 100) < (self.rollout_pct * 100)
        if use_new:
            return await self.new_model.predict.remote(data)
        return await self.old_model.predict.remote(data)
```

## Autoscaling Configuration

Ray Serve autoscales replicas based on request load:

```python
@serve.deployment(
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 20,
        "initial_replicas": 2,
        # Target requests in queue + processing per replica
        "target_num_ongoing_requests_per_replica": 5,
        # How quickly to scale up/down
        "upscale_delay_s": 30,
        "downscale_delay_s": 300,
        # Smoothing factor (0-1): higher = more reactive
        "smoothing_factor": 1.0,
        # Scale to zero when idle
        "upscale_smoothing_factor": None,
        "downscale_smoothing_factor": None,
    },
)
class AutoscaledModel:
    ...
```

### Autoscaling parameters reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| `min_replicas` | 1 | Minimum replica count (set 0 for scale-to-zero) |
| `max_replicas` | 1 | Maximum replica count |
| `initial_replicas` | None | Starting count (defaults to min_replicas) |
| `target_num_ongoing_requests_per_replica` | 1.0 | Target load per replica — core tuning knob |
| `upscale_delay_s` | 30 | Seconds to wait before scaling up |
| `downscale_delay_s` | 600 | Seconds to wait before scaling down |
| `smoothing_factor` | 1.0 | Global smoothing (1.0 = react immediately) |
| `metrics_interval_s` | 10 | How often to collect metrics |
| `look_back_period_s` | 30 | Window of metrics to consider |

### Scale-to-zero

```python
@serve.deployment(
    autoscaling_config={
        "min_replicas": 0,  # Allow scale to zero
        "max_replicas": 10,
        "downscale_delay_s": 120,
        "target_num_ongoing_requests_per_replica": 1,
    },
)
class ScaleToZeroModel:
    """Cold start latency applies when scaling from 0."""
    ...
```

### Tuning guidance

- **Latency-sensitive**: `target_num_ongoing_requests = 1`, low `upscale_delay_s`
- **Throughput-optimized**: higher target (5-10), use batching, higher `downscale_delay_s`
- **Cost-optimized**: `min_replicas=0`, high `downscale_delay_s`
- **GPU workloads**: target = 2-4 (GPU can process multiple requests), match `max_batch_size`

## gRPC Support

Ray Serve supports gRPC as an alternative to HTTP:

```python
# Define your protobuf service
# prediction_service.proto:
# service PredictionService {
#   rpc Predict(PredictRequest) returns (PredictResponse);
# }

from ray import serve

@serve.deployment
class GrpcPredictor:
    def __init__(self):
        self.model = load_model()

    async def Predict(self, request):
        """Method name must match protobuf service method."""
        features = list(request.features)
        prediction = self.model.predict([features])[0]
        return prediction_pb2.PredictResponse(
            prediction=prediction,
            model_version="v1",
        )

# Start with gRPC enabled
serve.start(grpc_port=9000, grpc_servicer_functions=[
    "prediction_service_pb2_grpc.add_PredictionServiceServicer_to_server",
])
app = GrpcPredictor.bind()
serve.run(app)
```

gRPC benefits:
- Lower latency than HTTP/JSON for internal service-to-service calls
- Strongly typed with protobuf contracts
- Bidirectional streaming support
- Smaller payload sizes with binary serialization

## Health Checks and Readiness

```python
@serve.deployment(
    health_check_period_s=10,
    health_check_timeout_s=30,
)
class HealthyModel:
    def __init__(self):
        self.model = None
        self.ready = False

    def reconfigure(self, config: dict):
        """Called on config updates without restarting the replica."""
        self.model = load_model(config["model_path"])
        self.ready = True

    def check_health(self):
        """Raise exception to mark replica unhealthy."""
        if not self.ready:
            raise RuntimeError("Model not loaded")
        if not self.model.is_valid():
            raise RuntimeError("Model corrupted")

    async def __call__(self, request):
        data = await request.json()
        return self.model.predict(data["input"])
```

Health check behavior:
- `check_health()` is called every `health_check_period_s` seconds
- If it raises an exception, the replica is marked unhealthy
- After `health_check_timeout_s`, unhealthy replicas are killed and restarted
- Kubernetes liveness/readiness probes should target the Serve health endpoint

## Production Deployment Patterns

### Pattern 1: Config-driven deployment

```yaml
# serve_config.yaml
proxy_location: EveryNode
http_options:
  host: 0.0.0.0
  port: 8000
  request_timeout_s: 60

applications:
  - name: ml_pipeline
    route_prefix: /
    import_path: my_app.serve:app
    runtime_env:
      pip:
        - torch==2.1.0
        - transformers==4.35.0
      env_vars:
        MODEL_CACHE: /mnt/models
    deployments:
      - name: Preprocessor
        num_replicas: 2
      - name: Model
        autoscaling_config:
          min_replicas: 2
          max_replicas: 16
          target_num_ongoing_requests_per_replica: 3
        ray_actor_options:
          num_gpus: 1
      - name: Postprocessor
        num_replicas: 2
```

Deploy with: `serve deploy serve_config.yaml`

### Pattern 2: Blue-green deployments

```python
# Deploy v1
serve.run(ModelV1.bind(), name="production", route_prefix="/predict")

# Deploy v2 to staging
serve.run(ModelV2.bind(), name="staging", route_prefix="/predict-staging")

# Validate v2 with integration tests...

# Swap: undeploy v1, promote v2
serve.delete("production")
serve.run(ModelV2.bind(), name="production", route_prefix="/predict")
serve.delete("staging")
```

### Pattern 3: Multi-application isolation

```yaml
applications:
  - name: low_latency
    route_prefix: /v1
    import_path: app_v1:app
    deployments:
      - name: FastModel
        autoscaling_config:
          target_num_ongoing_requests_per_replica: 1
          max_replicas: 50

  - name: batch_processing
    route_prefix: /batch
    import_path: app_batch:app
    deployments:
      - name: BatchModel
        autoscaling_config:
          target_num_ongoing_requests_per_replica: 10
          max_replicas: 10
```

### Pattern 4: Request/response logging

```python
@serve.deployment
class LoggingModel:
    async def __call__(self, request):
        import time, uuid
        request_id = str(uuid.uuid4())
        start = time.perf_counter()
        data = await request.json()
        result = self.model.predict(data["input"])
        latency = time.perf_counter() - start
        logger.info(f"request={request_id} latency={latency:.3f}s "
                     f"input_size={len(data['input'])} status=ok")
        return {"prediction": result, "request_id": request_id}
```

## Configuration File Reference

Full `serve_config.yaml` schema:

```yaml
proxy_location: EveryNode  # EveryNode | HeadOnly | NoServer
http_options:
  host: 0.0.0.0
  port: 8000
  root_path: ""
  request_timeout_s: null  # None = no timeout
  keep_alive_timeout_s: 5

grpc_options:
  port: 9000
  grpc_servicer_functions: []

logging_config:
  encoding: TEXT  # TEXT | JSON
  log_level: INFO
  logs_dir: /tmp/ray/serve/logs

applications:
  - name: app_name
    route_prefix: /prefix
    import_path: module.submodule:app_variable
    runtime_env:
      pip: [dep1, dep2]
      working_dir: "s3://bucket/app/"
      env_vars: {KEY: value}
    deployments:
      - name: DeploymentClass
        num_replicas: auto  # or integer
        max_ongoing_requests: 100
        autoscaling_config:
          min_replicas: 1
          max_replicas: 50
          initial_replicas: null
          target_num_ongoing_requests_per_replica: 2.0
          upscale_delay_s: 30
          downscale_delay_s: 600
          smoothing_factor: 1.0
          metrics_interval_s: 10
          look_back_period_s: 30
        graceful_shutdown_timeout_s: 20
        graceful_shutdown_wait_loop_s: 2
        health_check_period_s: 10
        health_check_timeout_s: 30
        ray_actor_options:
          num_cpus: 1
          num_gpus: 0
          memory: 0
          runtime_env: {}
        user_config: {}
```

## Monitoring and Observability

### Prometheus metrics

Ray Serve exports metrics automatically:

- `ray_serve_num_ongoing_requests` — current in-flight requests per replica
- `ray_serve_request_latency_ms` — request latency histogram
- `ray_serve_num_replicas` — current replica count per deployment
- `ray_serve_request_counter` — total requests (with status labels)
- `ray_serve_handle_request_counter` — inter-deployment handle calls

### Dashboard integration

Access Serve-specific views at `http://<head>:8265/#/serve`:
- Deployment status and replica count
- Per-replica request metrics
- Application configuration
- Error logs per replica

### Custom metrics

```python
from ray.serve.metrics import Counter, Histogram

@serve.deployment
class InstrumentedModel:
    def __init__(self):
        self.request_counter = Counter(
            "my_model_requests_total",
            description="Total prediction requests",
            tag_keys=("model_version",),
        )
        self.latency_hist = Histogram(
            "my_model_latency_seconds",
            description="Prediction latency",
            boundaries=[0.01, 0.05, 0.1, 0.5, 1.0, 5.0],
        )
        self.model = load_model()

    async def __call__(self, request):
        import time
        start = time.time()
        data = await request.json()
        result = self.model.predict(data["input"])
        self.latency_hist.observe(time.time() - start)
        self.request_counter.inc(tags={"model_version": "v1"})
        return result
```

## Performance Tuning

### Maximizing throughput

1. **Enable batching** — `@serve.batch(max_batch_size=32)` for GPU workloads
2. **Increase `max_ongoing_requests`** — allow more concurrent requests per replica (default 100)
3. **Use async handlers** — `async def __call__` enables concurrency within a replica
4. **Tune autoscaling** — set `target_num_ongoing_requests_per_replica` to match model capacity
5. **Colocate deployments** — use placement groups to minimize network hops

### Minimizing latency

1. **Reduce `batch_wait_timeout_s`** — don't wait too long for batch fill at low load
2. **Use `max_ongoing_requests=1`** for strict sequential processing
3. **Pre-warm models** in `__init__` — avoid lazy loading on first request
4. **Use HTTP/2 or gRPC** for connection multiplexing
5. **Set `target_num_ongoing_requests_per_replica=1`** for immediate autoscaling

### Memory optimization

1. **Share models across replicas** — use `ray.put()` for read-only model weights
2. **Fractional GPUs** — `num_gpus=0.5` to pack multiple models on one GPU
3. **Offload to CPU** — move preprocessing to CPU replicas, inference to GPU replicas
4. **Use `user_config`** for dynamic model swapping without replica restart

## Common Pitfalls

1. **Blocking the event loop** — use `async def` and avoid CPU-heavy sync code in handlers; offload to a thread pool with `asyncio.to_thread()`
2. **Not setting `max_ongoing_requests`** — unbounded queues cause memory issues under load
3. **Ignoring health checks** — always implement `check_health()` for production deployments
4. **Hardcoding model paths** — use `user_config` or environment variables for configurability
5. **Not testing locally** — always test with `serve.run()` before deploying to cluster
6. **Forgetting graceful shutdown** — set `graceful_shutdown_timeout_s` to drain in-flight requests
7. **Over-scaling** — set reasonable `max_replicas` to avoid cluster resource exhaustion
8. **Ignoring cold start** — scale-to-zero has cold start latency; pre-warm for latency-sensitive workloads
