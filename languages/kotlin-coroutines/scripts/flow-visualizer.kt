#!/usr/bin/env kotlinc-jvm -script

// flow-visualizer.kt — Visualizes Flow operator chains with timing
//
// Usage:
//   chmod +x flow-visualizer.kt
//   kotlinc -script flow-visualizer.kt
//
// Or with kotlin runner:
//   kotlin flow-visualizer.kt
//
// Requirements:
//   - Kotlin 1.9+ with kotlinx-coroutines-core on classpath
//
// What it does:
//   Demonstrates and visualizes Flow operator behavior with ASCII timelines.
//   Shows how operators like buffer, conflate, debounce, flatMapMerge, etc.
//   affect emission timing and ordering.

@file:DependsOn("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlin.system.measureTimeMillis

// ============================================================
// Visualization Utilities
// ============================================================
data class TimedEvent(val timeMs: Long, val label: String, val type: EventType)
enum class EventType { EMIT, RECEIVE, OPERATOR, INFO }

class FlowVisualizer(private val name: String) {
    private val events = mutableListOf<TimedEvent>()
    private val startTime = System.currentTimeMillis()

    fun record(label: String, type: EventType = EventType.INFO) {
        events.add(TimedEvent(System.currentTimeMillis() - startTime, label, type))
    }

    fun print() {
        println("\n┌─ $name")
        println("│")

        val maxTime = events.maxOfOrNull { it.timeMs } ?: 0
        val timelineWidth = 60
        val scale = if (maxTime > 0) timelineWidth.toDouble() / maxTime else 1.0

        // Group by type for color-coded display
        events.forEach { event ->
            val pos = (event.timeMs * scale).toInt().coerceIn(0, timelineWidth)
            val icon = when (event.type) {
                EventType.EMIT -> "🟢"
                EventType.RECEIVE -> "🔵"
                EventType.OPERATOR -> "🟡"
                EventType.INFO -> "⚪"
            }
            val timeline = " ".repeat(pos) + "│"
            println("│ ${String.format("%5dms", event.timeMs)} $icon ${event.label}")
        }

        println("│")
        println("│ Timeline: 0ms ${" ".repeat(30)} ${maxTime}ms")
        println("│ ${"─".repeat(timelineWidth + 2)}>")
        println("│ 🟢=emit  🔵=receive  🟡=operator")
        println("└─")
    }
}

// ============================================================
// Demo 1: buffer() — Decouples producer and consumer
// ============================================================
suspend fun demoBuffer() {
    val viz = FlowVisualizer("buffer() — Producer/Consumer Decoupling")

    val time = measureTimeMillis {
        flow {
            for (i in 1..5) {
                delay(100)
                viz.record("Emit $i", EventType.EMIT)
                emit(i)
            }
        }
        .buffer(3)
        .collect { value ->
            viz.record("Start processing $value", EventType.RECEIVE)
            delay(250)
            viz.record("Done processing $value", EventType.RECEIVE)
        }
    }

    viz.record("Total time: ${time}ms (without buffer would be ~1750ms)", EventType.INFO)
    viz.print()
}

// ============================================================
// Demo 2: conflate() — Drop intermediate values
// ============================================================
suspend fun demoConflate() {
    val viz = FlowVisualizer("conflate() — Skip Intermediate Values")

    flow {
        for (i in 1..10) {
            delay(50)
            viz.record("Emit $i", EventType.EMIT)
            emit(i)
        }
    }
    .conflate()
    .collect { value ->
        viz.record("Receive $value", EventType.RECEIVE)
        delay(200)
        viz.record("Done $value", EventType.RECEIVE)
    }

    viz.print()
}

// ============================================================
// Demo 3: collectLatest — Cancel old, process new
// ============================================================
suspend fun demoCollectLatest() {
    val viz = FlowVisualizer("collectLatest — Cancel Previous Processing")

    flow {
        for (i in 1..5) {
            delay(100)
            viz.record("Emit $i", EventType.EMIT)
            emit(i)
        }
    }
    .collectLatest { value ->
        viz.record("Start $value", EventType.RECEIVE)
        delay(250)
        viz.record("Complete $value ✓", EventType.RECEIVE)
    }

    viz.print()
    println("  Note: Only the last value completes processing")
}

// ============================================================
// Demo 4: debounce — Wait for quiet period
// ============================================================
suspend fun demoDebounce() {
    val viz = FlowVisualizer("debounce(200ms) — Wait for Silence")

    flow {
        emit(1); viz.record("Emit 1", EventType.EMIT)
        delay(50)
        emit(2); viz.record("Emit 2 (+50ms)", EventType.EMIT)
        delay(50)
        emit(3); viz.record("Emit 3 (+100ms)", EventType.EMIT)
        delay(300)  // silence > 200ms
        emit(4); viz.record("Emit 4 (+400ms)", EventType.EMIT)
        delay(50)
        emit(5); viz.record("Emit 5 (+450ms)", EventType.EMIT)
    }
    .debounce(200)
    .collect { value ->
        viz.record("Receive $value", EventType.RECEIVE)
    }

    viz.print()
    println("  Note: Only values followed by 200ms silence are received (3 and 5)")
}

// ============================================================
// Demo 5: combine vs zip
// ============================================================
suspend fun demoCombineVsZip() {
    val flowA = flow {
        delay(100); emit("A1"); delay(200); emit("A2"); delay(200); emit("A3")
    }
    val flowB = flow {
        delay(150); emit("B1"); delay(300); emit("B2")
    }

    // combine
    val vizCombine = FlowVisualizer("combine — Latest from Each Source")
    flowA.combine(flowB) { a, b -> "$a+$b" }
        .collect { value ->
            vizCombine.record("Receive: $value", EventType.RECEIVE)
        }
    vizCombine.print()
    println("  Note: Emits whenever EITHER source emits (uses latest from other)")

    // zip
    val vizZip = FlowVisualizer("zip — Paired 1:1")
    flowA.zip(flowB) { a, b -> "$a+$b" }
        .collect { value ->
            vizZip.record("Receive: $value", EventType.RECEIVE)
        }
    vizZip.print()
    println("  Note: Pairs elements strictly 1:1, stops at shorter flow")
}

// ============================================================
// Demo 6: flatMapMerge vs flatMapConcat vs flatMapLatest
// ============================================================
suspend fun demoFlatMap() {
    fun innerFlow(prefix: String, count: Int) = flow {
        repeat(count) { i ->
            delay(80)
            emit("$prefix-${i + 1}")
        }
    }

    // flatMapConcat
    val vizConcat = FlowVisualizer("flatMapConcat — Sequential Inner Flows")
    flowOf("A", "B", "C")
        .onEach { vizConcat.record("Outer emit: $it", EventType.EMIT) }
        .flatMapConcat { prefix ->
            vizConcat.record("Start inner flow $prefix", EventType.OPERATOR)
            innerFlow(prefix, 2)
        }
        .collect { vizConcat.record("Receive: $it", EventType.RECEIVE) }
    vizConcat.print()

    // flatMapMerge
    val vizMerge = FlowVisualizer("flatMapMerge — Concurrent Inner Flows")
    flowOf("A", "B", "C")
        .onEach { vizMerge.record("Outer emit: $it", EventType.EMIT) }
        .flatMapMerge { prefix ->
            vizMerge.record("Start inner flow $prefix", EventType.OPERATOR)
            innerFlow(prefix, 2)
        }
        .collect { vizMerge.record("Receive: $it", EventType.RECEIVE) }
    vizMerge.print()

    // flatMapLatest
    val vizLatest = FlowVisualizer("flatMapLatest — Cancel Previous Inner Flow")
    flow {
        emit("A"); delay(100)
        emit("B"); delay(100)
        emit("C")
    }
        .onEach { vizLatest.record("Outer emit: $it", EventType.EMIT) }
        .flatMapLatest { prefix ->
            vizLatest.record("Start inner flow $prefix", EventType.OPERATOR)
            innerFlow(prefix, 3)
        }
        .collect { vizLatest.record("Receive: $it", EventType.RECEIVE) }
    vizLatest.print()
    println("  Note: Only the last inner flow (C) completes fully")
}

// ============================================================
// Demo 7: flowOn — Dispatcher Switching
// ============================================================
suspend fun demoFlowOn() {
    val viz = FlowVisualizer("flowOn — Upstream Dispatcher Change")

    flow {
        viz.record("Emit on: ${Thread.currentThread().name}", EventType.EMIT)
        emit(1)
    }
    .map {
        viz.record("map on: ${Thread.currentThread().name}", EventType.OPERATOR)
        it * 2
    }
    .flowOn(Dispatchers.IO) // everything ABOVE runs on IO
    .map {
        viz.record("map2 on: ${Thread.currentThread().name}", EventType.OPERATOR)
        it + 1
    }
    .collect {
        viz.record("collect on: ${Thread.currentThread().name}", EventType.RECEIVE)
    }

    viz.print()
    println("  Note: flowOn changes the dispatcher for UPSTREAM operators only")
}

// ============================================================
// Main
// ============================================================
println("═".repeat(70))
println("  🌊 Kotlin Flow Operator Visualizer")
println("═".repeat(70))

runBlocking {
    demoBuffer()
    println()
    demoConflate()
    println()
    demoCollectLatest()
    println()
    demoDebounce()
    println()
    demoCombineVsZip()
    println()
    demoFlatMap()
    println()
    demoFlowOn()
}

println("\n═".repeat(70))
println("  ✅ All visualizations complete")
println("═".repeat(70))
