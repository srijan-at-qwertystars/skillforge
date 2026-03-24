#!/usr/bin/env kotlinc-jvm -script

// coroutine-benchmark.kt — Benchmarks coroutine vs thread performance
//
// Usage:
//   chmod +x coroutine-benchmark.kt
//   kotlinc -script coroutine-benchmark.kt
//
// Or with kotlin runner:
//   kotlin coroutine-benchmark.kt
//
// Requirements:
//   - Kotlin 1.9+ with kotlinx-coroutines-core on classpath
//   - kotlinc-jvm or kotlin command available
//
// What it measures:
//   1. Creation overhead: coroutines vs threads
//   2. Context switching: coroutines vs threads
//   3. Memory usage: concurrent coroutines vs threads
//   4. Throughput: tasks/second for both approaches

@file:DependsOn("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")

import kotlinx.coroutines.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicLong
import kotlin.system.measureNanoTime
import kotlin.system.measureTimeMillis

data class BenchmarkResult(
    val name: String,
    val coroutineMs: Long,
    val threadMs: Long,
    val speedup: Double
)

val results = mutableListOf<BenchmarkResult>()

// ============================================================
// Benchmark 1: Creation Overhead
// ============================================================
fun benchmarkCreation(count: Int) {
    println("\n📊 Benchmark 1: Creation Overhead ($count tasks)")
    println("─".repeat(60))

    // Coroutines
    val coroutineTime = measureTimeMillis {
        runBlocking {
            val jobs = (1..count).map {
                launch(Dispatchers.Default) {
                    // minimal work
                    Unit
                }
            }
            jobs.forEach { it.join() }
        }
    }
    println("  Coroutines: ${coroutineTime}ms")

    // Threads
    val threadTime = measureTimeMillis {
        val threads = (1..count.coerceAtMost(10_000)).map {
            Thread {
                // minimal work
                Unit
            }.also { it.start() }
        }
        threads.forEach { it.join() }
    }
    println("  Threads:    ${threadTime}ms")

    val speedup = threadTime.toDouble() / coroutineTime.coerceAtLeast(1)
    println("  Speedup:    ${String.format("%.1fx", speedup)}")

    results.add(BenchmarkResult("Creation ($count)", coroutineTime, threadTime, speedup))
}

// ============================================================
// Benchmark 2: Context Switching
// ============================================================
fun benchmarkContextSwitch(iterations: Int) {
    println("\n📊 Benchmark 2: Context Switching ($iterations iterations)")
    println("─".repeat(60))

    // Coroutines
    val coroutineTime = measureTimeMillis {
        runBlocking {
            val counter = AtomicLong(0)
            val job1 = launch(Dispatchers.Default) {
                repeat(iterations) {
                    counter.incrementAndGet()
                    yield()
                }
            }
            val job2 = launch(Dispatchers.Default) {
                repeat(iterations) {
                    counter.incrementAndGet()
                    yield()
                }
            }
            job1.join()
            job2.join()
        }
    }
    println("  Coroutines: ${coroutineTime}ms")

    // Threads
    val threadTime = measureTimeMillis {
        val counter = AtomicLong(0)
        val latch = CountDownLatch(2)
        val t1 = Thread {
            repeat(iterations) {
                counter.incrementAndGet()
                Thread.yield()
            }
            latch.countDown()
        }
        val t2 = Thread {
            repeat(iterations) {
                counter.incrementAndGet()
                Thread.yield()
            }
            latch.countDown()
        }
        t1.start()
        t2.start()
        latch.await()
    }
    println("  Threads:    ${threadTime}ms")

    val speedup = threadTime.toDouble() / coroutineTime.coerceAtLeast(1)
    println("  Speedup:    ${String.format("%.1fx", speedup)}")

    results.add(BenchmarkResult("Context Switch", coroutineTime, threadTime, speedup))
}

// ============================================================
// Benchmark 3: Memory — Many Concurrent Tasks
// ============================================================
fun benchmarkMemory(count: Int) {
    println("\n📊 Benchmark 3: Concurrent Suspended Tasks ($count)")
    println("─".repeat(60))

    // Coroutines
    val memBefore = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }
    val coroutineTime = measureTimeMillis {
        runBlocking {
            val jobs = (1..count).map {
                launch(Dispatchers.Default) {
                    delay(1000)
                }
            }
            System.gc()
            val memDuring = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }
            println("  Coroutine memory: ~${(memDuring - memBefore) / 1024}KB for $count coroutines")
            jobs.forEach { it.join() }
        }
    }
    println("  Coroutines time: ${coroutineTime}ms")

    // Threads (limited to avoid OOM)
    val threadCount = count.coerceAtMost(5_000)
    System.gc()
    val memBefore2 = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }
    val threadTime = measureTimeMillis {
        val latch = CountDownLatch(threadCount)
        val threads = (1..threadCount).map {
            Thread {
                Thread.sleep(1000)
                latch.countDown()
            }.also { it.start() }
        }
        System.gc()
        val memDuring = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }
        println("  Thread memory:    ~${(memDuring - memBefore2) / 1024}KB for $threadCount threads")
        latch.await()
    }
    println("  Threads time:    ${threadTime}ms (only $threadCount threads)")

    results.add(BenchmarkResult("Memory ($count coroutines vs $threadCount threads)", coroutineTime, threadTime,
        threadTime.toDouble() / coroutineTime.coerceAtLeast(1)))
}

// ============================================================
// Benchmark 4: Throughput — Tasks per Second
// ============================================================
fun benchmarkThroughput(durationMs: Long) {
    println("\n📊 Benchmark 4: Throughput (${durationMs}ms window)")
    println("─".repeat(60))

    // Coroutines
    val coroutineCount = AtomicLong(0)
    val coroutineTime = measureTimeMillis {
        runBlocking {
            val jobs = (1..Runtime.getRuntime().availableProcessors()).map {
                launch(Dispatchers.Default) {
                    val deadline = System.currentTimeMillis() + durationMs
                    while (System.currentTimeMillis() < deadline) {
                        // Simulate small unit of work
                        coroutineCount.incrementAndGet()
                        yield()
                    }
                }
            }
            jobs.forEach { it.join() }
        }
    }
    println("  Coroutines: ${coroutineCount.get()} tasks in ${coroutineTime}ms " +
            "(${coroutineCount.get() * 1000 / coroutineTime} tasks/sec)")

    // Threads
    val threadCount = AtomicLong(0)
    val numCores = Runtime.getRuntime().availableProcessors()
    val threadTime = measureTimeMillis {
        val latch = CountDownLatch(numCores)
        val threads = (1..numCores).map {
            Thread {
                val deadline = System.currentTimeMillis() + durationMs
                while (System.currentTimeMillis() < deadline) {
                    threadCount.incrementAndGet()
                    Thread.yield()
                }
                latch.countDown()
            }.also { it.start() }
        }
        latch.await()
    }
    println("  Threads:    ${threadCount.get()} tasks in ${threadTime}ms " +
            "(${threadCount.get() * 1000 / threadTime} tasks/sec)")

    val speedup = coroutineCount.get().toDouble() / threadCount.get().coerceAtLeast(1)
    println("  Speedup:    ${String.format("%.1fx", speedup)}")

    results.add(BenchmarkResult("Throughput", coroutineTime, threadTime, speedup))
}

// ============================================================
// Run All Benchmarks
// ============================================================
println("🚀 Kotlin Coroutine vs Thread Benchmark")
println("═".repeat(60))
println("JVM: ${System.getProperty("java.version")}")
println("Cores: ${Runtime.getRuntime().availableProcessors()}")
println("Max Memory: ${Runtime.getRuntime().maxMemory() / 1024 / 1024}MB")

benchmarkCreation(100_000)
benchmarkContextSwitch(1_000_000)
benchmarkMemory(100_000)
benchmarkThroughput(2000)

println("\n\n📋 Summary")
println("═".repeat(60))
println(String.format("%-35s %10s %10s %8s", "Benchmark", "Coroutine", "Thread", "Speedup"))
println("─".repeat(60))
results.forEach { r ->
    println(String.format("%-35s %8sms %8sms %7.1fx", r.name, r.coroutineMs, r.threadMs, r.speedup))
}
println("═".repeat(60))
