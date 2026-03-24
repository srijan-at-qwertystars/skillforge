#!/usr/bin/env bash
# tokio-bench.sh — Benchmark async operations: spawn overhead, channel throughput, I/O latency
#
# Usage: ./tokio-bench.sh [test-type]
#
# Test types:
#   spawn     — Measure tokio::spawn overhead (time to spawn + await N tasks)
#   channel   — Measure mpsc channel throughput (messages/sec)
#   io        — Measure async file I/O latency (read/write)
#   all       — Run all benchmarks (default)
#
# Requirements: cargo (Rust toolchain)
# Creates a temporary Cargo project, runs benchmarks, cleans up.

set -euo pipefail

TEST_TYPE="${1:-all}"
BENCH_DIR=$(mktemp -d "/tmp/tokio-bench-XXXXXX")

cleanup() {
    rm -rf "$BENCH_DIR"
}
trap cleanup EXIT

echo "=== Tokio Async Benchmark Suite ==="
echo "Test: $TEST_TYPE"
echo "Temp dir: $BENCH_DIR"
echo ""

# Create benchmark project
cd "$BENCH_DIR"
cargo init --name tokio-bench --quiet 2>/dev/null

cat > Cargo.toml << 'CARGO'
[package]
name = "tokio-bench"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1", features = ["full", "test-util"] }

[profile.release]
opt-level = 3
CARGO

# Generate benchmark source based on test type
cat > src/main.rs << 'BENCH'
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::io::{AsyncWriteExt, AsyncReadExt};

const SPAWN_COUNT: usize = 100_000;
const CHANNEL_MESSAGES: usize = 1_000_000;
const IO_ITERATIONS: usize = 1_000;
const IO_BLOCK_SIZE: usize = 4096;

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let test = args.get(1).map(|s| s.as_str()).unwrap_or("all");

    match test {
        "spawn" => bench_spawn().await,
        "channel" => bench_channel().await,
        "io" => bench_io().await,
        "all" => {
            bench_spawn().await;
            println!();
            bench_channel().await;
            println!();
            bench_io().await;
        }
        other => eprintln!("Unknown test: {other}. Use: spawn, channel, io, all"),
    }
}

async fn bench_spawn() {
    println!("--- Spawn Benchmark ---");
    println!("Spawning {SPAWN_COUNT} tasks...");

    // Warm up
    for _ in 0..1000 {
        tokio::spawn(async {}).await.unwrap();
    }

    // Measure spawn + await
    let start = Instant::now();
    let mut handles = Vec::with_capacity(SPAWN_COUNT);
    for i in 0..SPAWN_COUNT {
        handles.push(tokio::spawn(async move { i * 2 }));
    }
    let spawn_elapsed = start.elapsed();

    let await_start = Instant::now();
    for handle in handles {
        handle.await.unwrap();
    }
    let await_elapsed = await_start.elapsed();
    let total = start.elapsed();

    println!("  Spawn time:       {:>10.2?}  ({:.0} ns/spawn)", spawn_elapsed, spawn_elapsed.as_nanos() as f64 / SPAWN_COUNT as f64);
    println!("  Await time:       {:>10.2?}  ({:.0} ns/await)", await_elapsed, await_elapsed.as_nanos() as f64 / SPAWN_COUNT as f64);
    println!("  Total:            {:>10.2?}  ({:.0} tasks/sec)", total, SPAWN_COUNT as f64 / total.as_secs_f64());

    // JoinSet comparison
    let start = Instant::now();
    let mut set = tokio::task::JoinSet::new();
    for i in 0..SPAWN_COUNT {
        set.spawn(async move { i * 2 });
    }
    while set.join_next().await.is_some() {}
    let joinset_elapsed = start.elapsed();
    println!("  JoinSet total:    {:>10.2?}  ({:.0} tasks/sec)", joinset_elapsed, SPAWN_COUNT as f64 / joinset_elapsed.as_secs_f64());
}

async fn bench_channel() {
    println!("--- Channel Benchmark ---");
    println!("Sending {CHANNEL_MESSAGES} messages...");

    // Bounded channel (buffer=1000)
    let (tx, mut rx) = mpsc::channel::<u64>(1000);
    let start = Instant::now();

    let sender = tokio::spawn(async move {
        for i in 0..CHANNEL_MESSAGES as u64 {
            tx.send(i).await.unwrap();
        }
    });

    let receiver = tokio::spawn(async move {
        let mut count = 0u64;
        while rx.recv().await.is_some() {
            count += 1;
        }
        count
    });

    sender.await.unwrap();
    let count = receiver.await.unwrap();
    let elapsed = start.elapsed();

    println!("  Bounded(1000):    {:>10.2?}  ({:.2}M msg/sec, {} msgs)", elapsed, count as f64 / elapsed.as_secs_f64() / 1_000_000.0, count);

    // Unbounded channel
    let (tx, mut rx) = mpsc::unbounded_channel::<u64>();
    let start = Instant::now();

    let sender = tokio::spawn(async move {
        for i in 0..CHANNEL_MESSAGES as u64 {
            tx.send(i).unwrap();
        }
    });

    let receiver = tokio::spawn(async move {
        let mut count = 0u64;
        while rx.recv().await.is_some() {
            count += 1;
        }
        count
    });

    sender.await.unwrap();
    let count = receiver.await.unwrap();
    let elapsed = start.elapsed();

    println!("  Unbounded:        {:>10.2?}  ({:.2}M msg/sec, {} msgs)", elapsed, count as f64 / elapsed.as_secs_f64() / 1_000_000.0, count);

    // Oneshot throughput
    let start = Instant::now();
    let iterations = 100_000;
    for _ in 0..iterations {
        let (tx, rx) = tokio::sync::oneshot::channel::<u64>();
        tx.send(42).unwrap();
        rx.await.unwrap();
    }
    let elapsed = start.elapsed();
    println!("  Oneshot:          {:>10.2?}  ({:.2}M roundtrips/sec)", elapsed, iterations as f64 / elapsed.as_secs_f64() / 1_000_000.0);
}

async fn bench_io() {
    println!("--- Async I/O Benchmark ---");

    let tmp_path = format!("/tmp/tokio-bench-io-{}", std::process::id());

    // Write benchmark
    let data = vec![0u8; IO_BLOCK_SIZE];
    let start = Instant::now();
    for _ in 0..IO_ITERATIONS {
        let mut file = tokio::fs::File::create(&tmp_path).await.unwrap();
        file.write_all(&data).await.unwrap();
        file.flush().await.unwrap();
    }
    let write_elapsed = start.elapsed();
    println!("  Write ({IO_BLOCK_SIZE}B x {IO_ITERATIONS}):{:>7.2?}  ({:.0} ops/sec)", write_elapsed, IO_ITERATIONS as f64 / write_elapsed.as_secs_f64());

    // Read benchmark
    let start = Instant::now();
    for _ in 0..IO_ITERATIONS {
        let mut file = tokio::fs::File::open(&tmp_path).await.unwrap();
        let mut buf = Vec::new();
        file.read_to_end(&mut buf).await.unwrap();
    }
    let read_elapsed = start.elapsed();
    println!("  Read  ({IO_BLOCK_SIZE}B x {IO_ITERATIONS}):{:>7.2?}  ({:.0} ops/sec)", read_elapsed, IO_ITERATIONS as f64 / read_elapsed.as_secs_f64());

    // Cleanup
    let _ = tokio::fs::remove_file(&tmp_path).await;

    // TCP loopback latency
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let tcp_iterations = 1000;

    let server = tokio::spawn(async move {
        for _ in 0..tcp_iterations {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 64];
            let n = socket.read(&mut buf).await.unwrap();
            socket.write_all(&buf[..n]).await.unwrap();
        }
    });

    let start = Instant::now();
    for _ in 0..tcp_iterations {
        let mut stream = tokio::net::TcpStream::connect(addr).await.unwrap();
        stream.write_all(b"ping").await.unwrap();
        let mut buf = [0u8; 64];
        stream.read(&mut buf).await.unwrap();
    }
    let tcp_elapsed = start.elapsed();
    server.await.unwrap();
    println!("  TCP echo (x{tcp_iterations}):  {:>7.2?}  ({:.0} μs/roundtrip)", tcp_elapsed, tcp_elapsed.as_micros() as f64 / tcp_iterations as f64);
}
BENCH

echo "Building benchmark (release mode)..."
cargo build --release --quiet 2>&1

echo "Running benchmarks..."
echo ""
./target/release/tokio-bench "$TEST_TYPE"

echo ""
echo "=== Benchmark complete ==="
