"""
Ray Data preprocessing pipeline example.

Demonstrates:
  - Reading data from multiple formats (Parquet, CSV, JSON)
  - Streaming map_batches transformations
  - GPU-accelerated preprocessing with ActorPoolStrategy
  - Writing processed data back to storage
  - Integration with Ray Train for ML training
  - Windowed aggregation and feature engineering

Usage:
  python data-pipeline.py --input data/ --output processed/ --format parquet
  python data-pipeline.py --input s3://bucket/data/ --output s3://bucket/processed/
"""

import argparse
import logging
import time
from typing import Any

import numpy as np

import ray
import ray.data

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)


# ─── Preprocessing Functions ────────────────────────────────────────────────

def normalize_batch(batch: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    """Normalize numeric columns to zero mean, unit variance."""
    numeric_cols = [
        col for col in batch
        if np.issubdtype(batch[col].dtype, np.number) and col != "label"
    ]
    for col in numeric_cols:
        values = batch[col].astype(np.float32)
        mean = np.mean(values)
        std = np.std(values) + 1e-8
        batch[col] = (values - mean) / std
    return batch


def add_features(batch: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    """Feature engineering: add derived features."""
    numeric_cols = [
        col for col in batch
        if np.issubdtype(batch[col].dtype, np.number) and col != "label"
    ]
    if len(numeric_cols) >= 2:
        col_a, col_b = numeric_cols[0], numeric_cols[1]
        batch["interaction_0_1"] = batch[col_a] * batch[col_b]
        batch["ratio_0_1"] = batch[col_a] / (np.abs(batch[col_b]) + 1e-8)

    for col in numeric_cols[:5]:
        batch[f"{col}_squared"] = batch[col] ** 2

    return batch


def filter_invalid(row: dict[str, Any]) -> bool:
    """Filter out rows with missing or invalid values."""
    for key, value in row.items():
        if value is None:
            return False
        if isinstance(value, float) and (np.isnan(value) or np.isinf(value)):
            return False
    return True


def clean_text_batch(batch: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    """Clean text columns: lowercase, strip whitespace."""
    for col in batch:
        if batch[col].dtype == object:
            batch[col] = np.array([
                s.lower().strip() if isinstance(s, str) else s
                for s in batch[col]
            ])
    return batch


# ─── GPU-Accelerated Preprocessing (Actor-based) ────────────────────────────

class GPUPreprocessor:
    """Stateful preprocessor that runs on GPU.

    Use with ActorPoolStrategy for GPU-accelerated batch transforms.
    """

    def __init__(self):
        self.device = "cpu"  # Replace with torch.device("cuda") when GPU available
        logger.info(f"GPUPreprocessor initialized on {self.device}")

    def __call__(self, batch: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
        """Apply GPU-accelerated transforms to a batch."""
        numeric_cols = [
            col for col in batch
            if np.issubdtype(batch[col].dtype, np.number) and col != "label"
        ]
        # Simulate GPU computation (replace with real torch/cupy operations)
        for col in numeric_cols:
            values = batch[col].astype(np.float32)
            batch[col] = np.log1p(np.abs(values)) * np.sign(values)

        return batch


# ─── Pipeline Definitions ───────────────────────────────────────────────────

def build_basic_pipeline(input_path: str, input_format: str) -> ray.data.Dataset:
    """Build a basic preprocessing pipeline."""
    logger.info(f"Reading {input_format} from {input_path}")

    readers = {
        "parquet": ray.data.read_parquet,
        "csv": ray.data.read_csv,
        "json": ray.data.read_json,
    }
    reader = readers.get(input_format)
    if reader is None:
        raise ValueError(f"Unsupported format: {input_format}. Use: {list(readers.keys())}")

    ds = reader(input_path)

    logger.info(f"Dataset schema: {ds.schema()}")
    logger.info(f"Dataset count: {ds.count()}")

    # Pipeline stages (lazy — nothing executes until materialized)
    ds = ds.filter(filter_invalid)
    ds = ds.map_batches(clean_text_batch, batch_format="numpy", batch_size=2048)
    ds = ds.map_batches(normalize_batch, batch_format="numpy", batch_size=2048)
    ds = ds.map_batches(add_features, batch_format="numpy", batch_size=2048)

    return ds


def build_gpu_pipeline(input_path: str, input_format: str) -> ray.data.Dataset:
    """Build a pipeline with GPU-accelerated preprocessing."""
    readers = {
        "parquet": ray.data.read_parquet,
        "csv": ray.data.read_csv,
        "json": ray.data.read_json,
    }
    reader = readers.get(input_format)
    if reader is None:
        raise ValueError(f"Unsupported format: {input_format}")

    ds = reader(input_path)
    ds = ds.filter(filter_invalid)
    ds = ds.map_batches(normalize_batch, batch_format="numpy", batch_size=2048)

    # GPU preprocessing with actor pool
    ds = ds.map_batches(
        GPUPreprocessor,
        batch_format="numpy",
        batch_size=1024,
        concurrency=2,  # Number of GPU actors
        # For GPU: num_gpus=1 in the actor options
    )

    ds = ds.map_batches(add_features, batch_format="numpy", batch_size=2048)
    return ds


def build_train_pipeline(
    train_path: str,
    val_path: str,
    input_format: str = "parquet",
) -> tuple[ray.data.Dataset, ray.data.Dataset]:
    """Build train/val pipelines for ML training integration."""
    train_ds = build_basic_pipeline(train_path, input_format)
    val_ds = build_basic_pipeline(val_path, input_format)

    # Shuffle training data
    train_ds = train_ds.random_shuffle()

    return train_ds, val_ds


# ─── Generate Sample Data ───────────────────────────────────────────────────

def generate_sample_data(output_path: str, num_rows: int = 10000):
    """Generate sample dataset for testing the pipeline."""
    logger.info(f"Generating {num_rows} sample rows at {output_path}")

    data = {
        "feature_0": np.random.randn(num_rows).tolist(),
        "feature_1": np.random.randn(num_rows).tolist(),
        "feature_2": np.random.randn(num_rows).tolist(),
        "feature_3": np.random.randn(num_rows).tolist(),
        "feature_4": np.random.exponential(2, num_rows).tolist(),
        "category": np.random.choice(["a", "b", "c", "d"], num_rows).tolist(),
        "label": np.random.randint(0, 10, num_rows).tolist(),
    }

    ds = ray.data.from_items([
        {k: v[i] for k, v in data.items()} for i in range(num_rows)
    ])
    ds.write_parquet(output_path)
    logger.info(f"Sample data written to {output_path}")
    return output_path


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Ray Data preprocessing pipeline")
    parser.add_argument("--input", type=str, help="Input data path")
    parser.add_argument("--output", type=str, default="processed/", help="Output path")
    parser.add_argument("--format", type=str, default="parquet",
                        choices=["parquet", "csv", "json"])
    parser.add_argument("--generate", action="store_true",
                        help="Generate sample data before processing")
    parser.add_argument("--num-rows", type=int, default=10000,
                        help="Number of rows for sample data")
    parser.add_argument("--gpu", action="store_true",
                        help="Use GPU-accelerated pipeline")
    parser.add_argument("--output-format", type=str, default="parquet",
                        choices=["parquet", "csv", "json"])

    args = parser.parse_args()

    ray.init(ignore_reinit_error=True)

    try:
        input_path = args.input

        if args.generate or not input_path:
            input_path = "/tmp/ray_sample_data/"
            generate_sample_data(input_path, num_rows=args.num_rows)

        start_time = time.perf_counter()

        if args.gpu:
            ds = build_gpu_pipeline(input_path, args.format)
        else:
            ds = build_basic_pipeline(input_path, args.format)

        # Materialize and write output
        logger.info(f"Writing output to {args.output} as {args.output_format}")
        writers = {
            "parquet": ds.write_parquet,
            "csv": ds.write_csv,
            "json": ds.write_json,
        }
        writers[args.output_format](args.output)

        elapsed = time.perf_counter() - start_time

        # Report stats
        logger.info(f"Pipeline complete in {elapsed:.2f}s")
        logger.info(f"Output schema: {ds.schema()}")
        logger.info(f"Output rows: {ds.count()}")

        stats = ds.stats()
        logger.info(f"Execution stats:\n{stats}")

    finally:
        ray.shutdown()


if __name__ == "__main__":
    main()
