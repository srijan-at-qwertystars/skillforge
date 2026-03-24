"""
Ray Serve ML model serving example with dynamic batching.

Demonstrates:
  - FastAPI integration with Pydantic validation
  - Dynamic batching for GPU inference
  - Model composition (preprocessor → model → postprocessor)
  - Health checks and custom metrics
  - Streaming responses

Deploy:
  serve run serve-example:app
  # or
  serve deploy ray-serve-config.yaml
"""

import asyncio
import logging
import time
from typing import Optional

import numpy as np
from fastapi import FastAPI
from pydantic import BaseModel, Field

import ray
from ray import serve

logger = logging.getLogger("ray.serve")

# ─── Request / Response Models ───────────────────────────────────────────────

class PredictionRequest(BaseModel):
    features: list[float] = Field(..., min_length=1, max_length=1024)
    model_version: str = Field(default="v1", pattern=r"^v\d+$")
    return_probabilities: bool = False

class PredictionResponse(BaseModel):
    prediction: int
    confidence: float
    probabilities: Optional[list[float]] = None
    model_version: str
    latency_ms: float

class BatchPredictionRequest(BaseModel):
    batch: list[PredictionRequest]

class HealthResponse(BaseModel):
    status: str
    model_loaded: bool
    uptime_seconds: float

# ─── Simulated Model ────────────────────────────────────────────────────────

class SimpleModel:
    """Simulated ML model for demonstration. Replace with real model loading."""

    def __init__(self, version: str = "v1"):
        self.version = version
        self.num_classes = 10
        self.weights = np.random.randn(1024, self.num_classes)
        logger.info(f"Model {version} loaded with {self.weights.shape} weights")

    def predict_batch(self, features: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Run batch inference. Returns (predictions, probabilities)."""
        logits = features[:, :self.weights.shape[0]] @ self.weights
        exp_logits = np.exp(logits - np.max(logits, axis=1, keepdims=True))
        probabilities = exp_logits / exp_logits.sum(axis=1, keepdims=True)
        predictions = np.argmax(probabilities, axis=1)
        return predictions, probabilities

# ─── Preprocessor Deployment ────────────────────────────────────────────────

@serve.deployment(
    num_replicas=2,
    ray_actor_options={"num_cpus": 1},
)
class Preprocessor:
    """Normalize and validate input features."""

    def __init__(self):
        self.mean = 0.0
        self.std = 1.0

    def preprocess(self, features: list[float]) -> np.ndarray:
        arr = np.array(features, dtype=np.float32)
        # Pad or truncate to expected size
        target_size = 1024
        if len(arr) < target_size:
            arr = np.pad(arr, (0, target_size - len(arr)))
        else:
            arr = arr[:target_size]
        # Normalize
        arr = (arr - self.mean) / (self.std + 1e-8)
        return arr

# ─── Model Server Deployment (with batching) ────────────────────────────────

@serve.deployment(
    num_replicas="auto",
    autoscaling_config={
        "min_replicas": 1,
        "max_replicas": 10,
        "target_num_ongoing_requests_per_replica": 5,
    },
    ray_actor_options={"num_cpus": 2},
)
class ModelServer:
    """Serve predictions with dynamic batching."""

    def __init__(self):
        self.models = {
            "v1": SimpleModel("v1"),
            "v2": SimpleModel("v2"),
        }
        self.start_time = time.time()
        self.request_count = 0

    @serve.batch(max_batch_size=32, batch_wait_timeout_s=0.05)
    async def predict_batch(
        self,
        feature_arrays: list[np.ndarray],
        model_versions: list[str],
    ) -> list[tuple[int, float, list[float]]]:
        """Batched prediction — called with lists, must return list of same length."""
        # Group by model version for efficient batching
        results = [None] * len(feature_arrays)

        version_groups: dict[str, list[int]] = {}
        for i, ver in enumerate(model_versions):
            version_groups.setdefault(ver, []).append(i)

        for version, indices in version_groups.items():
            model = self.models.get(version, self.models["v1"])
            batch = np.stack([feature_arrays[i] for i in indices])
            predictions, probabilities = model.predict_batch(batch)

            for j, idx in enumerate(indices):
                results[idx] = (
                    int(predictions[j]),
                    float(np.max(probabilities[j])),
                    probabilities[j].tolist(),
                )

        self.request_count += len(feature_arrays)
        return results

    async def predict(
        self, features: np.ndarray, model_version: str = "v1"
    ) -> tuple[int, float, list[float]]:
        return await self.predict_batch(features, model_version)

    def health_info(self) -> dict:
        return {
            "model_loaded": True,
            "uptime_seconds": time.time() - self.start_time,
            "total_requests": self.request_count,
            "available_versions": list(self.models.keys()),
        }

    def check_health(self):
        """Health check — raise to mark replica unhealthy."""
        if not self.models:
            raise RuntimeError("No models loaded")

# ─── Postprocessor Deployment ────────────────────────────────────────────────

@serve.deployment(
    num_replicas=2,
    ray_actor_options={"num_cpus": 1},
)
class Postprocessor:
    """Format prediction results."""

    LABEL_NAMES = [
        "cat", "dog", "bird", "fish", "horse",
        "lion", "tiger", "bear", "wolf", "fox",
    ]

    def format_result(
        self,
        prediction: int,
        confidence: float,
        probabilities: list[float],
        return_probabilities: bool = False,
    ) -> dict:
        result = {
            "prediction": prediction,
            "label": self.LABEL_NAMES[prediction % len(self.LABEL_NAMES)],
            "confidence": round(confidence, 4),
        }
        if return_probabilities:
            result["probabilities"] = {
                self.LABEL_NAMES[i]: round(p, 4)
                for i, p in enumerate(probabilities[:len(self.LABEL_NAMES)])
            }
        return result

# ─── Main Application (FastAPI + Serve) ──────────────────────────────────────

api = FastAPI(
    title="Ray Serve ML Prediction API",
    description="Example ML model serving with dynamic batching",
    version="1.0.0",
)

@serve.deployment(route_prefix="/")
@serve.ingress(api)
class APIIngress:
    def __init__(self, preprocessor, model_server, postprocessor):
        self.preprocessor = preprocessor
        self.model_server = model_server
        self.postprocessor = postprocessor

    @api.post("/predict", response_model=PredictionResponse)
    async def predict(self, request: PredictionRequest) -> PredictionResponse:
        start = time.perf_counter()

        # Preprocess
        features = await self.preprocessor.preprocess.remote(request.features)

        # Predict (with automatic batching)
        prediction, confidence, probabilities = (
            await self.model_server.predict.remote(features, request.model_version)
        )

        # Postprocess
        result = await self.postprocessor.format_result.remote(
            prediction, confidence, probabilities, request.return_probabilities
        )

        latency_ms = (time.perf_counter() - start) * 1000
        return PredictionResponse(
            prediction=result["prediction"],
            confidence=result["confidence"],
            probabilities=result.get("probabilities"),
            model_version=request.model_version,
            latency_ms=round(latency_ms, 2),
        )

    @api.post("/predict/batch")
    async def predict_batch(self, request: BatchPredictionRequest) -> list[PredictionResponse]:
        tasks = [self.predict(req) for req in request.batch]
        return await asyncio.gather(*tasks)

    @api.get("/health", response_model=HealthResponse)
    async def health(self) -> HealthResponse:
        info = await self.model_server.health_info.remote()
        return HealthResponse(
            status="healthy",
            model_loaded=info["model_loaded"],
            uptime_seconds=info["uptime_seconds"],
        )

    @api.get("/models")
    async def list_models(self) -> dict:
        info = await self.model_server.health_info.remote()
        return {"models": info["available_versions"]}


# ─── Build the application ──────────────────────────────────────────────────

app = APIIngress.bind(
    Preprocessor.bind(),
    ModelServer.bind(),
    Postprocessor.bind(),
)
