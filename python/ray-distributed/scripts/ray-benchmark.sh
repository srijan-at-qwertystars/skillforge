#!/usr/bin/env bash
# Benchmark Ray tasks/actors: throughput, latency, object store transfer rates.
# Usage: ./ray-benchmark.sh [--tasks N] [--actors N] [--object-size-mb N] [--all]
#
# Examples:
#   ./ray-benchmark.sh --all                        # Run all benchmarks
#   ./ray-benchmark.sh --tasks 10000                # Task throughput benchmark
#   ./ray-benchmark.sh --actors 50 --object-size-mb 100   # Actor + object store benchmark

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
NUM_TASKS=5000
NUM_ACTORS=20
OBJECT_SIZE_MB=10
RUN_ALL=false
RUN_TASKS=false
RUN_ACTORS=false
RUN_OBJECTS=false

# ─── Parse arguments ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tasks)          NUM_TASKS="$2";      RUN_TASKS=true;   shift 2 ;;
        --actors)         NUM_ACTORS="$2";     RUN_ACTORS=true;  shift 2 ;;
        --object-size-mb) OBJECT_SIZE_MB="$2"; RUN_OBJECTS=true; shift 2 ;;
        --all)            RUN_ALL=true;                          shift   ;;
        -h|--help)
            echo "Usage: $0 [--tasks N] [--actors N] [--object-size-mb N] [--all]"
            echo ""
            echo "Benchmarks:"
            echo "  --tasks N            Task throughput/latency (default: 5000 tasks)"
            echo "  --actors N           Actor creation and method calls (default: 20 actors)"
            echo "  --object-size-mb N   Object store transfer rate (default: 10 MB)"
            echo "  --all                Run all benchmarks"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# If no specific benchmark selected, run all
if [[ "${RUN_ALL}" == false && "${RUN_TASKS}" == false && "${RUN_ACTORS}" == false && "${RUN_OBJECTS}" == false ]]; then
    RUN_ALL=true
fi

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
bench() { echo -e "${CYAN}[BENCH]${NC} $*"; }

# ─── Check Ray connection ───────────────────────────────────────────────────
info "Checking Ray cluster..."
if ! ray status >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Cannot connect to Ray cluster. Start a cluster first."
    exit 1
fi
ok "Connected to Ray cluster"
echo ""

# ─── Run benchmarks ─────────────────────────────────────────────────────────
python3 << PYEOF
import ray
import time
import numpy as np
import sys

ray.init(address="auto", ignore_reinit_error=True)

resources = ray.cluster_resources()
print(f"Cluster: {resources.get('CPU', 0):.0f} CPUs, {resources.get('GPU', 0):.0f} GPUs, "
      f"{resources.get('object_store_memory', 0)/1e9:.1f} GB object store")
print(f"{'='*70}")

run_all = ${RUN_ALL,,}  # bash bool to python-ish
run_tasks = ${RUN_TASKS,,} or run_all
run_actors = ${RUN_ACTORS,,} or run_all
run_objects = ${RUN_OBJECTS,,} or run_all

# ── Task Benchmark ──────────────────────────────────────────────────────
if run_tasks:
    num_tasks = ${NUM_TASKS}
    print(f"\n📊 TASK BENCHMARK ({num_tasks} tasks)")
    print("-" * 50)

    @ray.remote
    def noop():
        return 1

    @ray.remote
    def compute(n):
        total = 0
        for i in range(n):
            total += i * i
        return total

    # 1. Task submission throughput
    start = time.perf_counter()
    refs = [noop.remote() for _ in range(num_tasks)]
    submit_time = time.perf_counter() - start
    submit_rate = num_tasks / submit_time
    print(f"  Submission rate:     {submit_rate:>10,.0f} tasks/sec ({submit_time:.2f}s)")

    # 2. Task execution throughput (noop)
    start = time.perf_counter()
    ray.get(refs)
    exec_time = time.perf_counter() - start
    exec_rate = num_tasks / exec_time
    print(f"  Noop throughput:     {exec_rate:>10,.0f} tasks/sec ({exec_time:.2f}s)")

    # 3. Single task round-trip latency
    latencies = []
    for _ in range(100):
        start = time.perf_counter()
        ray.get(noop.remote())
        latencies.append(time.perf_counter() - start)
    lat_arr = np.array(latencies) * 1000  # ms
    print(f"  Round-trip latency:  p50={np.percentile(lat_arr, 50):.2f}ms "
          f"p95={np.percentile(lat_arr, 95):.2f}ms "
          f"p99={np.percentile(lat_arr, 99):.2f}ms")

    # 4. Compute task throughput
    start = time.perf_counter()
    refs = [compute.remote(10000) for _ in range(num_tasks)]
    ray.get(refs)
    compute_time = time.perf_counter() - start
    compute_rate = num_tasks / compute_time
    print(f"  Compute throughput:  {compute_rate:>10,.0f} tasks/sec ({compute_time:.2f}s)")

# ── Actor Benchmark ─────────────────────────────────────────────────────
if run_actors:
    num_actors = ${NUM_ACTORS}
    print(f"\n📊 ACTOR BENCHMARK ({num_actors} actors)")
    print("-" * 50)

    @ray.remote
    class Counter:
        def __init__(self):
            self.n = 0
        def increment(self):
            self.n += 1
            return self.n
        def get_count(self):
            return self.n

    # 1. Actor creation time
    start = time.perf_counter()
    actors = [Counter.remote() for _ in range(num_actors)]
    # Wait for all actors to be created
    ray.get([a.get_count.remote() for a in actors])
    create_time = time.perf_counter() - start
    create_rate = num_actors / create_time
    print(f"  Actor creation:      {create_rate:>10,.1f} actors/sec ({create_time:.2f}s)")

    # 2. Actor method call throughput
    calls_per_actor = 200
    total_calls = num_actors * calls_per_actor
    start = time.perf_counter()
    refs = []
    for actor in actors:
        for _ in range(calls_per_actor):
            refs.append(actor.increment.remote())
    ray.get(refs)
    method_time = time.perf_counter() - start
    method_rate = total_calls / method_time
    print(f"  Method throughput:   {method_rate:>10,.0f} calls/sec ({total_calls} calls, {method_time:.2f}s)")

    # 3. Single actor method latency
    actor = actors[0]
    latencies = []
    for _ in range(200):
        start = time.perf_counter()
        ray.get(actor.increment.remote())
        latencies.append(time.perf_counter() - start)
    lat_arr = np.array(latencies) * 1000
    print(f"  Method latency:      p50={np.percentile(lat_arr, 50):.2f}ms "
          f"p95={np.percentile(lat_arr, 95):.2f}ms "
          f"p99={np.percentile(lat_arr, 99):.2f}ms")

    # Cleanup
    for a in actors:
        ray.kill(a)

# ── Object Store Benchmark ──────────────────────────────────────────────
if run_objects:
    obj_size_mb = ${OBJECT_SIZE_MB}
    print(f"\n📊 OBJECT STORE BENCHMARK ({obj_size_mb} MB objects)")
    print("-" * 50)

    # 1. ray.put() throughput
    data = np.random.bytes(obj_size_mb * 1024 * 1024)
    num_puts = 20
    start = time.perf_counter()
    refs = [ray.put(data) for _ in range(num_puts)]
    put_time = time.perf_counter() - start
    put_rate = (num_puts * obj_size_mb) / put_time
    print(f"  ray.put() rate:      {put_rate:>10,.1f} MB/sec ({num_puts}x {obj_size_mb}MB)")

    # 2. ray.get() throughput (local)
    ref = ray.put(data)
    start = time.perf_counter()
    for _ in range(num_puts):
        result = ray.get(ref)
    get_time = time.perf_counter() - start
    get_rate = (num_puts * obj_size_mb) / get_time
    print(f"  ray.get() rate:      {get_rate:>10,.1f} MB/sec (local, {num_puts}x {obj_size_mb}MB)")

    # 3. Object passing to tasks
    @ray.remote
    def consume(data_ref):
        d = data_ref  # Already deserialized by Ray
        return len(d) if isinstance(d, bytes) else 0

    ref = ray.put(data)
    start = time.perf_counter()
    results = ray.get([consume.remote(ref) for _ in range(num_puts)])
    pass_time = time.perf_counter() - start
    pass_rate = (num_puts * obj_size_mb) / pass_time
    print(f"  Object pass rate:    {pass_rate:>10,.1f} MB/sec ({num_puts} tasks, {obj_size_mb}MB each)")

    # 4. Serialization overhead
    sizes = [1, 10, 100]
    print(f"  Serialization overhead by size:")
    for size_mb in sizes:
        test_data = np.random.bytes(size_mb * 1024 * 1024)
        start = time.perf_counter()
        ref = ray.put(test_data)
        _ = ray.get(ref)
        roundtrip = (time.perf_counter() - start) * 1000
        print(f"    {size_mb:>4} MB: {roundtrip:>8.2f}ms roundtrip")

    # Cleanup refs
    del refs, ref, data

print(f"\n{'='*70}")
print("Benchmark complete.")
ray.shutdown()
PYEOF

echo ""
ok "All benchmarks finished"
