---
name: kotlin-coroutines
description: >
  Kotlin coroutines and async programming with kotlinx.coroutines. Covers coroutine builders
  (launch, async, runBlocking), structured concurrency, CoroutineScope, Job, SupervisorJob,
  Dispatchers, suspend functions, Flow (cold streams), StateFlow, SharedFlow (hot streams),
  Channels, select expressions, CoroutineExceptionHandler, supervisorScope, testing with
  runTest/turbine, and Android/Ktor integration. Triggers: "Kotlin coroutines",
  "suspend function", "CoroutineScope", "Flow", "StateFlow", "SharedFlow", "Dispatchers",
  "structured concurrency", "coroutine context", "coroutine builder", "launch async",
  "runBlocking", "SupervisorJob", "CoroutineExceptionHandler", "kotlinx.coroutines",
  "coroutine channel", "select expression", "viewModelScope".
  NOT for Java threads, RxJava, Project Reactor, Go goroutines, Python asyncio,
  or general Kotlin without concurrency context.
---

# Kotlin Coroutines (kotlinx.coroutines 1.8+)

## Coroutine Builders

### `launch` — Fire-and-forget (returns `Job`)
```kotlin
// Input: Launch a background task
scope.launch {
    delay(1000)
    println("Done")
}
// Output: prints "Done" after 1s, does not return a value
```

### `async` — Concurrent with result (returns `Deferred<T>`)
```kotlin
// Input: Fetch two values concurrently
val result = coroutineScope {
    val a = async { fetchUserProfile() }   // starts immediately
    val b = async { fetchUserOrders() }    // starts immediately
    Pair(a.await(), b.await())             // suspends until both complete
}
// Output: Pair(profile, orders) — total time ≈ max(profileTime, ordersTime)
```

### `runBlocking` — Bridge blocking ↔ suspend (test/main only)
```kotlin
fun main() = runBlocking {
    launch { delay(200); println("Task") }
    println("Start")
}
// Output: "Start" then "Task"
```

### `coroutineScope` — Structured child scope (fails-fast)
Waits for all children. If any child fails, all siblings are cancelled and the exception propagates.

### `withContext` — Switch dispatcher within a coroutine
```kotlin
suspend fun loadData(): String = withContext(Dispatchers.IO) {
    URL("https://api.example.com/data").readText()
}
```

## Structured Concurrency

Every coroutine must belong to a `CoroutineScope`. The scope forms a parent-child hierarchy:
- Parent cancellation cancels all children.
- Child failure cancels parent (unless `SupervisorJob`).
- Scope completes only when all children complete.

**Rules:**
1. Never use `GlobalScope` in production — it breaks structured concurrency.
2. Create scopes tied to component lifecycles (Activity, ViewModel, service).
3. Use `coroutineScope { }` inside suspend functions to launch parallel work.

## CoroutineScope, Job, SupervisorJob

```kotlin
// Standard scope — one child failure cancels all
val scope = CoroutineScope(Job() + Dispatchers.Default)

// Supervisor scope — child failures are independent
val supervisorScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

// Cancel when lifecycle ends
scope.cancel()
```

**Job states:** New → Active → Completing → Completed / Cancelled

```kotlin
val job = scope.launch { heavyWork() }
job.cancel()            // cooperative cancellation
job.cancelAndJoin()     // cancel + wait for completion
job.isActive            // true while running
job.invokeOnCompletion { cause -> log(cause) }
```

## Dispatchers

| Dispatcher | Thread pool | Use case |
|---|---|---|
| `Dispatchers.Default` | Shared, CPU-bound | sorting, parsing, computation |
| `Dispatchers.IO` | Elastic, I/O-optimized | network, file, database |
| `Dispatchers.Main` | UI thread (Android) | UI updates |
| `Dispatchers.Unconfined` | Caller thread (initial) | testing, rarely production |

```kotlin
// Limit parallelism for rate-limiting
val dbDispatcher = Dispatchers.IO.limitedParallelism(4)
// 1.9+: named dispatcher view for debugging
val named = Dispatchers.IO.limitedParallelism(4, "db-pool")
```

## Suspend Functions

A `suspend` function can call other suspend functions and be paused/resumed by the runtime.

```kotlin
suspend fun fetchUser(id: Int): User {
    val response = httpClient.get("/users/$id")  // suspends, not blocks
    return response.body<User>()
}
```

**Key rules:**
- Only callable from coroutines or other suspend functions.
- Use `withContext` to switch dispatchers inside a suspend function.
- Mark functions `suspend` only if they actually call suspending code.
- Check `ensureActive()` or `yield()` in long CPU loops for cooperative cancellation.

## Flow (Cold Streams)

A `Flow<T>` emits values lazily — code runs only when collected.

```kotlin
// Input: Create a flow of integers
fun numbers(): Flow<Int> = flow {
    for (i in 1..3) {
        delay(100)
        emit(i)
    }
}

// Collect
numbers()
    .map { it * 2 }
    .filter { it > 2 }
    .collect { println(it) }
// Output: 4, 6
```

### Common Operators
```kotlin
flow.map { transform(it) }
flow.filter { predicate(it) }
flow.flatMapConcat { innerFlow(it) }  // sequential
flow.flatMapMerge { innerFlow(it) }   // concurrent
flow.combine(otherFlow) { a, b -> merge(a, b) }
flow.zip(otherFlow) { a, b -> pair(a, b) }
flow.debounce(300)                    // wait for silence
flow.distinctUntilChanged()
flow.catch { e -> emit(fallback) }    // upstream errors only
flow.onEach { log(it) }
flow.onCompletion { cause -> cleanup() }
flow.flowOn(Dispatchers.IO)           // upstream dispatcher
flow.stateIn(scope, started, initial) // convert to StateFlow
flow.shareIn(scope, started, replay)  // convert to SharedFlow
```

**flowOn** changes the upstream dispatcher; collection always happens in the collector's context.

## StateFlow (Hot, State-holder)

Replays latest value to new collectors. Always has a value. Conflates (skips intermediate values).

```kotlin
// Input: ViewModel state management
class UserViewModel : ViewModel() {
    private val _uiState = MutableStateFlow<UiState>(UiState.Loading)
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _uiState.value = UiState.Loading
            try {
                val user = repository.getUser()
                _uiState.value = UiState.Success(user)
            } catch (e: Exception) {
                _uiState.value = UiState.Error(e.message)
            }
        }
    }
}
// Output: Collectors receive Loading → Success(user) or Loading → Error(msg)
```

### `stateIn` — Convert cold Flow to StateFlow
```kotlin
val state: StateFlow<List<Item>> = repository.observeItems()
    .stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5000), // keep alive 5s after last collector
        initialValue = emptyList()
    )
```

## SharedFlow (Hot, Event Bus)

No initial value. Configurable replay and buffer. Does not conflate by default.

```kotlin
// Input: One-shot events
private val _events = MutableSharedFlow<UiEvent>()  // replay = 0
val events: SharedFlow<UiEvent> = _events.asSharedFlow()

suspend fun navigate(route: String) {
    _events.emit(UiEvent.Navigate(route))  // suspends if no collectors
}
// Output: Active collectors receive Navigate(route); late collectors miss it
```

**SharedFlow vs StateFlow:**
| Feature | StateFlow | SharedFlow |
|---|---|---|
| Initial value | required | optional (replay) |
| Replay to new collectors | latest 1 | configurable (0..N) |
| Equality conflation | yes (skips equal) | no |
| Use case | UI state | events, commands |

## Channels

Channels are hot, synchronization-based communication between coroutines.

```kotlin
// Input: Producer-consumer
val channel = Channel<Int>(capacity = Channel.BUFFERED)

launch { for (i in 1..5) channel.send(i); channel.close() }
launch { for (v in channel) println(v) }
// Output: 1, 2, 3, 4, 5
```

**Channel types:** `RENDEZVOUS` (0), `BUFFERED` (64 default), `CONFLATED` (keep latest), `UNLIMITED`

**`produce` builder** (structured):
```kotlin
fun CoroutineScope.produceNumbers() = produce<Int> {
    for (i in 1..5) send(i)
}
```

**Prefer Flow over Channel** unless you need fan-out (multiple consumers) or bidirectional communication.

## Select Expressions

Select lets you await multiple suspending operations simultaneously.

```kotlin
// Input: First result wins
suspend fun fastest(): String = select {
    async { api1() }.onAwait { "api1: $it" }
    async { api2() }.onAwait { "api2: $it" }
}
// Output: whichever API responds first
```

```kotlin
// Select on channels
select<Unit> {
    channel1.onReceive { handle1(it) }
    channel2.onReceive { handle2(it) }
    onTimeout(1000) { handleTimeout() }
}
```

## Exception Handling

### try/catch in coroutines
```kotlin
launch {
    try {
        riskyOperation()
    } catch (e: IOException) {
        handleError(e)
    }
}
```

### CoroutineExceptionHandler (last resort, launch only)
```kotlin
val handler = CoroutineExceptionHandler { _, e ->
    log.error("Unhandled: ${e.message}")
}
val scope = CoroutineScope(SupervisorJob() + handler)
scope.launch { throw RuntimeException("boom") }
// Output: handler logs "Unhandled: boom", other children unaffected
```

**Rules:**
- `CoroutineExceptionHandler` only works on root coroutines (not nested).
- `async` exceptions surface at `.await()` — use try/catch there.
- `CancellationException` is special — never caught by handler, signals normal cancellation.
- `supervisorScope { }` isolates child failures within a suspend function:

```kotlin
suspend fun loadDashboard() = supervisorScope {
    val profile = async { fetchProfile() }       // failure here
    val orders = async { fetchOrders() }         // continues running
    DashboardData(
        profile = runCatching { profile.await() }.getOrNull(),
        orders = runCatching { orders.await() }.getOrNull()
    )
}
```

## Testing Coroutines

### `runTest` (kotlinx-coroutines-test)
```kotlin
@Test
fun `fetch user returns data`() = runTest {
    val repo = FakeRepository()
    val viewModel = UserViewModel(repo)

    viewModel.load()
    advanceUntilIdle()  // fast-forward virtual time

    assertEquals(UiState.Success(fakeUser), viewModel.uiState.value)
}
```

**Key test utilities:**
- `runTest { }` — auto-skips `delay`, controls virtual time.
- `advanceUntilIdle()` — execute all pending coroutines.
- `advanceTimeBy(ms)` — advance virtual clock.
- `TestDispatcher` — `StandardTestDispatcher` (eager: no auto-run) or `UnconfinedTestDispatcher` (auto-run).
- `Turbine` library (app.cash.turbine) for Flow testing:

```kotlin
@Test
fun `state flow emits loading then success`() = runTest {
    viewModel.uiState.test {
        assertEquals(UiState.Loading, awaitItem())
        viewModel.load()
        assertEquals(UiState.Success(data), awaitItem())
        cancelAndIgnoreRemainingEvents()
    }
}
```

### Injecting dispatchers for testability
```kotlin
class MyRepository(
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO
) {
    suspend fun getData() = withContext(ioDispatcher) { api.fetch() }
}

// In test:
val testDispatcher = StandardTestDispatcher()
val repo = MyRepository(ioDispatcher = testDispatcher)
```

## Android Integration

```kotlin
// ViewModel — viewModelScope auto-cancels on onCleared()
class MyViewModel : ViewModel() {
    fun refresh() = viewModelScope.launch {
        _state.value = repo.fetchData()
    }
}

// Activity/Fragment — lifecycleScope with repeatOnLifecycle
lifecycleScope.launch {
    repeatOnLifecycle(Lifecycle.State.STARTED) {
        viewModel.uiState.collect { state -> render(state) }
    }
}
// Stops collecting when lifecycle drops below STARTED, restarts when STARTED again
```

## Ktor Integration

```kotlin
// Ktor client (suspend-native)
val client = HttpClient(CIO) {
    install(ContentNegotiation) { json() }
}

suspend fun fetchUser(id: Int): User =
    client.get("https://api.example.com/users/$id").body()

// Ktor server route
routing {
    get("/users/{id}") {
        val user = userService.getById(call.parameters["id"]!!.toInt())
        call.respond(user)
    }
}
```

## Quick Reference: Common Patterns

### Parallel decomposition
```kotlin
suspend fun loadPage() = coroutineScope {
    val header = async { fetchHeader() }
    val content = async { fetchContent() }
    val footer = async { fetchFooter() }
    Page(header.await(), content.await(), footer.await())
}
```

### Retry with exponential backoff
```kotlin
suspend fun <T> retry(
    times: Int = 3,
    initialDelay: Long = 100,
    factor: Double = 2.0,
    block: suspend () -> T
): T {
    var currentDelay = initialDelay
    repeat(times - 1) {
        try { return block() }
        catch (e: Exception) { delay(currentDelay); currentDelay = (currentDelay * factor).toLong() }
    }
    return block()  // last attempt — let exception propagate
}
```

### Timeout
```kotlin
val result = withTimeoutOrNull(3000) {
    slowNetworkCall()
}
// Output: result is null if call took > 3s, otherwise the return value
```

### Mutex for shared mutable state
```kotlin
val mutex = Mutex()
var counter = 0

coroutineScope {
    repeat(1000) {
        launch {
            mutex.withLock { counter++ }
        }
    }
}
// Output: counter == 1000 (guaranteed)
```

## References

In-depth guides in `references/`:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Coroutine internals (CPS transformation, state machines), custom coroutine builders, CoroutineContext elements (custom elements, MDC propagation), undispatched coroutines, DebugProbes API, performance optimization (dispatcher selection, pool sizing, avoiding unnecessary suspensions), Flow backpressure (`buffer`, `conflate`, `collectLatest`), advanced Flow operators (`combine`, `zip`, `flatMapMerge/Concat/Latest`), SharedFlow configuration (`replay`, `extraBufferCapacity`, `onBufferOverflow`).

- **[troubleshooting.md](references/troubleshooting.md)** — Debugging leaking coroutines, cancellation not propagating (swallowed `CancellationException`, non-cooperative cancellation, broken Job hierarchy), blocking in suspend functions (detection, common offenders, proper wrapping), `GlobalScope` misuse and migration strategies, IntelliJ coroutine debugger and `DebugProbes`, deadlocks with `Dispatchers.Main`, structured concurrency violations, Flow collection pitfalls, memory leaks with `StateFlow` and `WhileSubscribed`.

- **[android-patterns.md](references/android-patterns.md)** — `viewModelScope`, `lifecycleScope`, `repeatOnLifecycle`, `flowWithLifecycle`, Room coroutine integration (suspend DAOs, Flow queries, transactions), Retrofit suspend methods and error handling, WorkManager `CoroutineWorker`, Jetpack Compose + Flow (`collectAsState`, `collectAsStateWithLifecycle`, `LaunchedEffect`, `rememberCoroutineScope`, `produceState`, `snapshotFlow`), testing Android coroutines (Main dispatcher rule, Turbine, ViewModel/Repository tests).

## Scripts

Executable tools in `scripts/`:

- **[coroutine-benchmark.kt](scripts/coroutine-benchmark.kt)** — Benchmarks coroutine vs thread performance across creation overhead, context switching, memory usage, and throughput. Run: `kotlinc -script coroutine-benchmark.kt`

- **[flow-visualizer.kt](scripts/flow-visualizer.kt)** — Visualizes Flow operator chains (`buffer`, `conflate`, `collectLatest`, `debounce`, `combine` vs `zip`, `flatMap*`, `flowOn`) with ASCII timelines showing emission/collection timing. Run: `kotlinc -script flow-visualizer.kt`

- **[lint-coroutines.sh](scripts/lint-coroutines.sh)** — Checks Kotlin source for common coroutine anti-patterns: `GlobalScope`, `runBlocking` in prod, `Thread.sleep`, `launch(Job())`, deprecated `launchWhenStarted`, `Dispatchers.Unconfined`, and more. Run: `./lint-coroutines.sh src/`

## Assets

Reusable templates and references in `assets/`:

- **[coroutine-test-template.kt](assets/coroutine-test-template.kt)** — Complete test template with `TestCoroutineScheduler`, `runTest`, Main dispatcher rule (JUnit 4/5), Turbine Flow testing, fakes, and example tests for ViewModels and Flows.

- **[flow-patterns.kt](assets/flow-patterns.kt)** — 10 production Flow patterns: debounce search, retry with exponential backoff, offset/cursor pagination, polling, resource-guarded Flow, multi-source combine, error recovery with fallback, throttle first/latest, batch/chunk emissions, per-element timeout.

- **[ktor-coroutine-patterns.kt](assets/ktor-coroutine-patterns.kt)** — Ktor server patterns: coroutine routing, WebSocket chat rooms, SSE streaming, concurrent request aggregation, database integration, error handling middleware, rate limiting, background jobs, streaming responses, and testing.

- **[gradle-coroutines.kts](assets/gradle-coroutines.kts)** — Gradle build config with all coroutine dependencies: core, Android, test, debug, reactive interop (RxJava3, JDK9), Ktor client/server, Room, Retrofit, WorkManager, Turbine, and serialization.

- **[coroutine-cheatsheet.md](assets/coroutine-cheatsheet.md)** — Quick reference card: builders, dispatchers, scopes, Job operations, Flow operators (creation, transformation, filtering, combining, error handling, terminal), StateFlow vs SharedFlow, cancellation, exception handling, testing, Android lifecycle collection, and common anti-patterns.
