# Advanced Kotlin Coroutine Patterns

## Table of Contents

- [Coroutine Internals](#coroutine-internals)
  - [CPS Transformation](#cps-transformation)
  - [State Machine Generation](#state-machine-generation)
  - [Suspension Mechanics](#suspension-mechanics)
- [Custom Coroutine Builders](#custom-coroutine-builders)
  - [Building a Custom Builder](#building-a-custom-builder)
  - [Intercepting Coroutine Lifecycle](#intercepting-coroutine-lifecycle)
- [CoroutineContext Deep Dive](#coroutinecontext-deep-dive)
  - [Context Elements](#context-elements)
  - [Custom Context Elements](#custom-context-elements)
  - [Context Propagation](#context-propagation)
- [Undispatched Coroutines](#undispatched-coroutines)
  - [CoroutineStart Modes](#coroutinestart-modes)
  - [UNDISPATCHED Behavior](#undispatched-behavior)
- [Coroutine Debugging](#coroutine-debugging)
  - [DebugProbes API](#debugprobes-api)
  - [Coroutine Dump](#coroutine-dump)
  - [JVM Agent](#jvm-agent)
- [Performance Optimization](#performance-optimization)
  - [Dispatcher Selection](#dispatcher-selection)
  - [Avoiding Unnecessary Suspensions](#avoiding-unnecessary-suspensions)
  - [Thread Confinement vs Shared State](#thread-confinement-vs-shared-state)
  - [Coroutine Pool Sizing](#coroutine-pool-sizing)
- [Flow Backpressure](#flow-backpressure)
  - [buffer](#buffer)
  - [conflate](#conflate)
  - [collectLatest](#collectlatest)
  - [Backpressure Strategies Compared](#backpressure-strategies-compared)
- [Advanced Flow Operators](#advanced-flow-operators)
  - [combine](#combine)
  - [zip](#zip)
  - [flatMapMerge](#flatmapmerge)
  - [flatMapConcat](#flatmapconcat)
  - [flatMapLatest](#flatmaplatest)
- [SharedFlow Configuration](#sharedflow-configuration)
  - [replay](#replay)
  - [extraBufferCapacity](#extrabuffercapacity)
  - [onBufferOverflow](#onbufferoverflow)
  - [SharedFlow vs Channel](#sharedflow-vs-channel)

---

## Coroutine Internals

### CPS Transformation

The Kotlin compiler transforms every `suspend` function using **Continuation-Passing Style (CPS)**. At the bytecode level, a `Continuation<T>` parameter is appended to every suspend function signature.

```kotlin
// Source code
suspend fun fetchUser(id: Int): User

// After CPS transformation (JVM bytecode signature)
fun fetchUser(id: Int, cont: Continuation<User>): Any?
```

The return type becomes `Any?` because the function can return:
- `COROUTINE_SUSPENDED` — the coroutine was suspended, result will be delivered via the continuation later
- The actual result (`User`) — the function completed synchronously without suspending

```kotlin
// How the runtime checks
val result = fetchUser(42, continuation)
if (result === COROUTINE_SUSPENDED) {
    // Control returns to caller; continuation.resumeWith() will be called later
    return COROUTINE_SUSPENDED
}
// Fast path: no suspension occurred
processUser(result as User)
```

### State Machine Generation

When a suspend function contains multiple suspension points, the compiler generates a **state machine** instead of creating separate callback objects for each suspension.

```kotlin
// Source code
suspend fun loadData(): String {
    val token = fetchToken()       // suspension point 1
    val user = fetchUser(token)    // suspension point 2
    val data = fetchData(user.id)  // suspension point 3
    return data
}
```

The compiler generates roughly:

```kotlin
// Simplified generated state machine (pseudo-code)
fun loadData(cont: Continuation<String>): Any? {
    // The continuation holds the state machine
    val sm = cont as? LoadDataContinuation ?: LoadDataContinuation(cont)

    when (sm.label) {
        0 -> {
            sm.label = 1
            val result = fetchToken(sm)
            if (result === COROUTINE_SUSPENDED) return COROUTINE_SUSPENDED
            sm.token = result as String
        }
        1 -> {
            sm.token = sm.result as String
            sm.label = 2
            val result = fetchUser(sm.token, sm)
            if (result === COROUTINE_SUSPENDED) return COROUTINE_SUSPENDED
            sm.user = result as User
        }
        2 -> {
            sm.user = sm.result as User
            sm.label = 3
            val result = fetchData(sm.user.id, sm)
            if (result === COROUTINE_SUSPENDED) return COROUTINE_SUSPENDED
            return result
        }
        3 -> {
            return sm.result as String
        }
    }
    // ... continues to next state
}
```

Key insight: **One object per coroutine** (the continuation), not one per suspension point. This is why coroutines are lightweight — no stack frames are kept alive during suspension.

### Suspension Mechanics

```kotlin
// suspendCoroutine — low-level suspension primitive
suspend fun <T> suspendCoroutine(
    block: (Continuation<T>) -> Unit
): T

// suspendCancellableCoroutine — preferred, supports cancellation
suspend fun <T> suspendCancellableCoroutine(
    block: (CancellableContinuation<T>) -> Unit
): T

// Example: wrapping a callback API
suspend fun awaitCallback(): String = suspendCancellableCoroutine { cont ->
    val callback = object : ApiCallback {
        override fun onSuccess(result: String) {
            cont.resume(result)  // or cont.resume(result) { /* onCancellation */ }
        }
        override fun onFailure(e: Exception) {
            cont.resumeWithException(e)
        }
    }
    api.call(callback)

    cont.invokeOnCancellation {
        api.cancel()  // cleanup when coroutine is cancelled
    }
}
```

**Important**: `cont.resume()` must be called exactly once. Calling it twice throws `IllegalStateException`. Use `cont.tryResume()` for race conditions.

---

## Custom Coroutine Builders

### Building a Custom Builder

```kotlin
import kotlin.coroutines.*

// Minimal coroutine builder that runs synchronously (like runBlocking but simpler)
fun <T> runSync(block: suspend () -> T): T {
    var result: Result<T>? = null
    val completion = Continuation<T>(EmptyCoroutineContext) { r ->
        result = r
    }
    block.startCoroutine(completion)
    return result!!.getOrThrow()
}

// Builder with custom scope and context
fun <T> customScope(
    context: CoroutineContext = EmptyCoroutineContext,
    block: suspend CoroutineScope.() -> T
): T = runBlocking(context) { block() }
```

### Intercepting Coroutine Lifecycle

```kotlin
// Custom ContinuationInterceptor (how dispatchers work internally)
class LoggingDispatcher(
    private val delegate: CoroutineDispatcher
) : CoroutineDispatcher() {
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        println("[${Thread.currentThread().name}] Dispatching coroutine")
        delegate.dispatch(context) {
            println("[${Thread.currentThread().name}] Running coroutine")
            block.run()
        }
    }
}

// Usage
val loggingIO = LoggingDispatcher(Dispatchers.IO)
scope.launch(loggingIO) { fetchData() }
```

---

## CoroutineContext Deep Dive

### Context Elements

`CoroutineContext` is an indexed set of `Element` instances. Core elements:

| Element | Key | Purpose |
|---|---|---|
| `Job` | `Job` | Lifecycle, cancellation, parent-child |
| `CoroutineDispatcher` | `ContinuationInterceptor` | Thread/dispatch strategy |
| `CoroutineName` | `CoroutineName` | Debug name |
| `CoroutineExceptionHandler` | `CoroutineExceptionHandler` | Uncaught exception handling |

```kotlin
// Context is combined with `+` operator
val context = Job() + Dispatchers.IO + CoroutineName("data-loader")

// Access elements by key
val job: Job? = context[Job]
val dispatcher = context[ContinuationInterceptor]
val name: CoroutineName? = context[CoroutineName]

// Remove elements with minusKey
val withoutName = context.minusKey(CoroutineName)
```

### Custom Context Elements

```kotlin
// Define a custom context element for request tracing
data class RequestId(val id: String) : AbstractCoroutineContextElement(RequestId) {
    companion object Key : CoroutineContext.Key<RequestId>
}

// Usage
launch(RequestId("req-12345")) {
    val reqId = coroutineContext[RequestId]?.id
    println("Handling request: $reqId")
    // Propagates to child coroutines automatically
    launch {
        val inherited = coroutineContext[RequestId]?.id  // "req-12345"
    }
}
```

```kotlin
// MDC-like logging context propagation
class CoroutineMDCContext(
    private val contextMap: Map<String, String> = MDC.getCopyOfContextMap() ?: emptyMap()
) : ThreadContextElement<Map<String, String>?>(Key) {
    companion object Key : CoroutineContext.Key<CoroutineMDCContext>

    override fun updateThreadContext(context: CoroutineContext): Map<String, String>? {
        val old = MDC.getCopyOfContextMap()
        MDC.setContextMap(contextMap)
        return old
    }

    override fun restoreThreadContext(context: CoroutineContext, oldState: Map<String, String>?) {
        if (oldState == null) MDC.clear() else MDC.setContextMap(oldState)
    }
}

// Usage — MDC values follow the coroutine across dispatchers
launch(CoroutineMDCContext()) {
    withContext(Dispatchers.IO) {
        MDC.get("traceId")  // still available!
    }
}
```

### Context Propagation

```kotlin
// Context flows from parent to child
val parentScope = CoroutineScope(
    SupervisorJob() + Dispatchers.Main + CoroutineName("parent")
)

parentScope.launch {
    // Inherits: SupervisorJob (as parent), Dispatchers.Main, CoroutineName("parent")
    // Gets: new child Job linked to parent

    launch(Dispatchers.IO + CoroutineName("child")) {
        // Inherits: parent Job hierarchy
        // Overrides: Dispatchers.IO, CoroutineName("child")
    }
}
```

---

## Undispatched Coroutines

### CoroutineStart Modes

```kotlin
launch(start = CoroutineStart.DEFAULT)       // scheduled for dispatch
launch(start = CoroutineStart.LAZY)          // starts only on join()/start()
launch(start = CoroutineStart.ATOMIC)        // non-cancellable until first suspension
launch(start = CoroutineStart.UNDISPATCHED)  // execute immediately in caller thread
```

### UNDISPATCHED Behavior

```kotlin
// UNDISPATCHED runs the coroutine body synchronously in the current thread
// until the first suspension point
fun main() = runBlocking {
    println("1: ${Thread.currentThread().name}")

    launch(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) {
        println("2: ${Thread.currentThread().name}")  // same thread as caller!
        delay(100)                                     // first suspension
        println("3: ${Thread.currentThread().name}")  // now on IO dispatcher
    }

    println("4: ${Thread.currentThread().name}")
}
// Output:
// 1: main
// 2: main          <- runs BEFORE returning to caller
// 4: main          <- after launch returns
// 3: DefaultDispatcher-worker-1  <- resumes on IO
```

Use cases:
- Reduce dispatch overhead for fast-path completion
- Ensure initial side effects happen synchronously
- `withContext` uses UNDISPATCHED internally for fast-path when context doesn't change dispatcher

---

## Coroutine Debugging

### DebugProbes API

```kotlin
// Add dependency: kotlinx-coroutines-debug
// In test/debug code:
import kotlinx.coroutines.debug.DebugProbes

fun setupDebug() {
    DebugProbes.install()  // Must be called before creating coroutines
    DebugProbes.sanitizeStackTraces = true  // cleaner stack traces
    DebugProbes.enableCreationStackTraces = true  // capture where coroutines were created
}
```

### Coroutine Dump

```kotlin
// Dump all coroutines and their states
DebugProbes.dumpCoroutines()
// Output:
// Coroutine "data-loader#1":DeferredCoroutine{Active}, state: SUSPENDED
//   at fetchUser(UserRepository.kt:42)
//   at loadData(DataLoader.kt:15)
//   (Coroutine creation stacktrace)
//   at launch(Builders.kt:46)
//   at DataLoader.start(DataLoader.kt:10)

// Get structured info programmatically
val info: List<CoroutineInfo> = DebugProbes.dumpCoroutinesInfo()
info.forEach { coroutine ->
    println("${coroutine.job}: state=${coroutine.state}")
    coroutine.lastObservedStackTrace().forEach { frame ->
        println("  at $frame")
    }
}
```

### JVM Agent

```bash
# Alternative: use as JVM agent (no code changes needed)
java -javaagent:kotlinx-coroutines-debug.jar -jar myapp.jar

# Or set system property for enhanced stack traces
java -Dkotlinx.coroutines.debug -jar myapp.jar

# This adds coroutine name to thread name:
# Thread: "DefaultDispatcher-worker-1 @my-coroutine#42"
```

---

## Performance Optimization

### Dispatcher Selection

```kotlin
// CPU-bound: Default (threads = number of CPUs)
withContext(Dispatchers.Default) {
    data.parallelSort()
}

// I/O-bound: IO (elastic pool, 64+ threads)
withContext(Dispatchers.IO) {
    file.readText()
}

// Limit parallelism for resource-constrained work
val dbPool = Dispatchers.IO.limitedParallelism(4)
val apiPool = Dispatchers.IO.limitedParallelism(10)
// These share the IO pool but limit concurrent operations

// Default.limitedParallelism creates a SEPARATE pool (different from IO!)
val computePool = Dispatchers.Default.limitedParallelism(2)
```

### Avoiding Unnecessary Suspensions

```kotlin
// BAD: unnecessary withContext when already on the right dispatcher
suspend fun getData(): Data {
    return withContext(Dispatchers.IO) {  // overhead if caller is already on IO
        cache.get("key")  // fast in-memory lookup
    }
}

// GOOD: only switch when actually needed
suspend fun getData(): Data {
    return cache.get("key") ?: withContext(Dispatchers.IO) {
        database.query("key")
    }
}

// GOOD: use yield() for cooperative cancellation in tight loops
suspend fun processLargeList(items: List<Item>) {
    items.forEachIndexed { index, item ->
        if (index % 100 == 0) yield()  // check cancellation periodically
        process(item)
    }
}
```

### Thread Confinement vs Shared State

```kotlin
// Approach 1: Thread confinement (preferred for simple state)
val counterContext = newSingleThreadContext("counter")
var counter = 0

coroutineScope {
    repeat(1000) {
        launch {
            withContext(counterContext) { counter++ }
        }
    }
}

// Approach 2: Mutex (for suspend-compatible mutual exclusion)
val mutex = Mutex()
var sharedState = 0

coroutineScope {
    repeat(1000) {
        launch {
            mutex.withLock { sharedState++ }
        }
    }
}

// Approach 3: Atomic operations (best perf for simple operations)
val atomicCounter = AtomicInteger(0)
coroutineScope {
    repeat(1000) {
        launch { atomicCounter.incrementAndGet() }
    }
}
```

### Coroutine Pool Sizing

```kotlin
// Monitor dispatcher thread utilization
val metrics = Dispatchers.IO.limitedParallelism(16)

// Rule of thumb:
// CPU-bound: threads = number of cores
// IO-bound: threads = cores * (1 + wait_time/compute_time)
// Mixed: separate dispatchers for CPU and IO work

// Avoid creating too many coroutines
// BAD: 1M coroutines for trivially parallelizable work
items.forEach { launch { process(it) } }

// GOOD: batch with chunking
items.chunked(100).forEach { batch ->
    launch { batch.forEach { process(it) } }
}

// GOOD: use Flow for natural backpressure
items.asFlow()
    .flatMapMerge(concurrency = 16) { item ->
        flow { emit(process(item)) }
    }
    .collect { results.add(it) }
```

---

## Flow Backpressure

### buffer

```kotlin
// Without buffer: collector backpressures producer (sequential)
// Total time: emission_time + collection_time for each element

// With buffer: producer and collector run concurrently
flow {
    repeat(5) { i ->
        delay(100)  // produce every 100ms
        emit(i)
    }
}
.buffer(capacity = 10)  // decouple producer/collector
.collect { value ->
    delay(300)  // slow collector
    println(value)
}
// Buffer allows producer to run ahead, reducing total time

// Buffer overflow strategies
.buffer(capacity = 10, onBufferOverflow = BufferOverflow.SUSPEND)    // default: suspend producer
.buffer(capacity = 10, onBufferOverflow = BufferOverflow.DROP_OLDEST)
.buffer(capacity = 10, onBufferOverflow = BufferOverflow.DROP_LATEST)
```

### conflate

```kotlin
// Conflate = buffer(1, DROP_OLDEST)
// Always processes the latest value, skips intermediate
flow {
    emit(1); delay(50)
    emit(2); delay(50)
    emit(3); delay(50)
    emit(4)
}
.conflate()
.collect { value ->
    delay(200)
    println(value)
}
// Output: 1, 4 (2 and 3 were skipped because collector was slow)
```

### collectLatest

```kotlin
// Cancels previous collection when new value arrives
flow {
    emit(1); delay(50)
    emit(2); delay(50)
    emit(3)
}
.collectLatest { value ->
    println("Start processing $value")
    delay(200)  // simulates slow processing
    println("Done processing $value")
}
// Output:
// Start processing 1
// Start processing 2  <- cancels processing of 1
// Start processing 3  <- cancels processing of 2
// Done processing 3   <- only 3 completes
```

### Backpressure Strategies Compared

| Strategy | Behavior | Use Case |
|---|---|---|
| `buffer()` | Queue emissions, concurrent | Decouple fast producer/slow consumer |
| `conflate()` | Keep latest, drop intermediate | UI state updates |
| `collectLatest` | Cancel old processing, start new | Search-as-you-type |
| `buffer(DROP_OLDEST)` | Ring buffer, drop oldest | Sensor data |
| `buffer(DROP_LATEST)` | Drop incoming when full | Rate limiting |

---

## Advanced Flow Operators

### combine

```kotlin
// Emits whenever ANY source emits (uses latest from other sources)
val names = flowOf("Alice", "Bob", "Charlie").onEach { delay(100) }
val ages = flowOf(25, 30, 35).onEach { delay(150) }

combine(names, ages) { name, age ->
    "$name is $age"
}.collect { println(it) }
// Output varies based on timing — always uses latest from each flow
// e.g.: "Alice is 25", "Bob is 25", "Bob is 30", "Charlie is 30", "Charlie is 35"
```

### zip

```kotlin
// Pairs elements 1:1, waits for both flows (like a zipper)
val names = flowOf("Alice", "Bob", "Charlie")
val ages = flowOf(25, 30, 35)

names.zip(ages) { name, age ->
    "$name is $age"
}.collect { println(it) }
// Output: "Alice is 25", "Bob is 30", "Charlie is 35"

// If flows have different sizes, stops at shorter
val a = flowOf(1, 2, 3)
val b = flowOf("a", "b")
a.zip(b) { n, s -> "$n$s" }.collect { println(it) }
// Output: "1a", "2b" (3 is dropped)
```

### flatMapMerge

```kotlin
// Flattens flows concurrently (default concurrency = 16)
flowOf("user1", "user2", "user3")
    .flatMapMerge(concurrency = 4) { userId ->
        flow {
            emit(fetchProfile(userId))
            emit(fetchPosts(userId))
        }
    }
    .collect { println(it) }
// Profiles and posts arrive interleaved from all users concurrently
```

### flatMapConcat

```kotlin
// Flattens flows sequentially — waits for each inner flow to complete
flowOf("user1", "user2", "user3")
    .flatMapConcat { userId ->
        flow {
            emit(fetchProfile(userId))
            emit(fetchPosts(userId))
        }
    }
    .collect { println(it) }
// Output is strictly ordered: user1 profile, user1 posts, user2 profile, ...
```

### flatMapLatest

```kotlin
// Cancels previous inner flow when new value arrives
searchQueryFlow
    .debounce(300)
    .flatMapLatest { query ->
        flow {
            emit(SearchResult.Loading)
            emit(SearchResult.Success(api.search(query)))
        }
    }
    .collect { renderSearchResults(it) }
// Only the latest search query's results are collected
```

---

## SharedFlow Configuration

### replay

```kotlin
// replay = N: new collectors receive the last N values immediately
val events = MutableSharedFlow<Event>(replay = 3)
events.emit(Event.A)
events.emit(Event.B)
events.emit(Event.C)
events.emit(Event.D)

// New collector immediately receives: B, C, D (last 3)
events.collect { println(it) }

// replay = 0 (default): new collectors receive nothing from the past
// replay = 1: equivalent to StateFlow behavior (but without equality-based conflation)
```

### extraBufferCapacity

```kotlin
// extraBufferCapacity adds buffer space beyond replay
// Total buffer = replay + extraBufferCapacity

val flow = MutableSharedFlow<Int>(
    replay = 1,
    extraBufferCapacity = 10  // total buffer = 11
)

// With extraBufferCapacity > 0, emit() won't suspend unless buffer is full
// Useful for event buses where you want tryEmit() to succeed
flow.tryEmit(42)  // returns true if buffer has space
```

### onBufferOverflow

```kotlin
val flow = MutableSharedFlow<Int>(
    replay = 0,
    extraBufferCapacity = 5,
    onBufferOverflow = BufferOverflow.DROP_OLDEST  // or DROP_LATEST, SUSPEND
)

// BufferOverflow.SUSPEND (default) — emit() suspends when buffer full
// BufferOverflow.DROP_OLDEST — drops oldest value in buffer
// BufferOverflow.DROP_LATEST — drops the value being emitted

// Important: DROP_OLDEST and DROP_LATEST make tryEmit() always return true
```

### SharedFlow vs Channel

| Aspect | SharedFlow | Channel |
|---|---|---|
| Consumers | Multiple (broadcast) | Single (fan-out) |
| Buffering | replay + extraBuffer | capacity |
| Missed values | Possible (depending on config) | Guaranteed delivery |
| Hot/Cold | Hot | Hot |
| Completion | Never completes | Can be closed |
| Use case | Events, state updates | Work distribution, queues |

```kotlin
// SharedFlow: all collectors see all events
val events = MutableSharedFlow<Event>()
launch { events.collect { handleA(it) } }  // gets all events
launch { events.collect { handleB(it) } }  // also gets all events

// Channel: each element goes to exactly one consumer (fan-out)
val work = Channel<Task>()
launch { for (task in work) processA(task) }  // gets some tasks
launch { for (task in work) processB(task) }  // gets remaining tasks
```
