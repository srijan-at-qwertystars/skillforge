# Kotlin Coroutines Cheatsheet

## Coroutine Builders

| Builder | Returns | Use Case |
|---|---|---|
| `launch { }` | `Job` | Fire-and-forget |
| `async { }` | `Deferred<T>` | Concurrent with result |
| `runBlocking { }` | `T` | Bridge blocking↔suspend (main/test only) |
| `coroutineScope { }` | `T` | Structured child scope, fails-fast |
| `supervisorScope { }` | `T` | Child failures independent |
| `withContext(dispatcher) { }` | `T` | Switch dispatcher |
| `withTimeout(ms) { }` | `T` | Timeout (throws on expiry) |
| `withTimeoutOrNull(ms) { }` | `T?` | Timeout (null on expiry) |
| `produce { }` | `ReceiveChannel<T>` | Channel producer |

## Dispatchers

| Dispatcher | Threads | Use |
|---|---|---|
| `Dispatchers.Default` | CPU cores | CPU-bound work |
| `Dispatchers.IO` | 64+ elastic | Network, file, DB |
| `Dispatchers.Main` | UI thread | Android UI updates |
| `Dispatchers.Main.immediate` | UI thread | Skip dispatch if already on Main |
| `Dispatchers.Unconfined` | Caller thread | Testing only |
| `Dispatchers.IO.limitedParallelism(n)` | n threads from IO | Rate-limited IO |
| `newSingleThreadContext(name)` | 1 dedicated thread | Thread confinement |

## Scopes

| Scope | Lifecycle | Dispatcher |
|---|---|---|
| `viewModelScope` | ViewModel.onCleared() | Main.immediate |
| `lifecycleScope` | Activity/Fragment DESTROYED | Main.immediate |
| `rememberCoroutineScope()` | Composition | Main.immediate |
| `GlobalScope` | App process (AVOID) | Default |
| `CoroutineScope(Job() + Dispatcher)` | Manual cancel() | Custom |

## Job Operations

```kotlin
val job = launch { work() }
job.cancel()                    // cooperative cancel
job.cancelAndJoin()             // cancel + wait
job.join()                      // wait for completion
job.isActive / isCompleted / isCancelled
job.invokeOnCompletion { cause -> }
job.children                    // child jobs
```

## Flow Operators — Quick Reference

### Creation
```kotlin
flowOf(1, 2, 3)                      // from values
listOf(1,2,3).asFlow()               // from collection
channelFlow { send(value) }          // concurrent emissions
callbackFlow { trySend(value) }      // from callbacks
MutableStateFlow(initial)            // hot, state holder
MutableSharedFlow<T>()               // hot, event bus
```

### Transformation
```kotlin
.map { transform(it) }              // 1:1 transform
.mapNotNull { nullableTransform() } // map + filter nulls
.transform { emit(a); emit(b) }     // 1:N custom
.scan(initial) { acc, v -> acc + v } // running accumulation
.flatMapConcat { innerFlow(it) }    // sequential flatten
.flatMapMerge { innerFlow(it) }     // concurrent flatten
.flatMapLatest { innerFlow(it) }    // cancel-previous flatten
```

### Filtering
```kotlin
.filter { predicate(it) }           // keep matching
.filterNot { predicate(it) }        // keep non-matching
.filterIsInstance<Type>()            // type filter
.distinctUntilChanged()              // deduplicate consecutive
.debounce(300)                       // wait for silence
.take(n)                             // first n items
.drop(n)                             // skip first n
```

### Combining
```kotlin
combine(flowA, flowB) { a, b -> }   // latest from each
flowA.zip(flowB) { a, b -> }        // paired 1:1
flowA.merge(flowB)                   // interleave all
```

### Error Handling
```kotlin
.catch { e -> emit(fallback) }       // catch upstream errors
.retry(3) { e -> e is IOException }  // retry on failure
.retryWhen { e, attempt -> }         // conditional retry
.onCompletion { cause -> }           // finally-like
```

### Context & Threading
```kotlin
.flowOn(Dispatchers.IO)              // upstream dispatcher
.buffer(capacity)                    // decouple producer/consumer
.conflate()                          // keep latest, skip intermediate
.collectLatest { }                   // cancel old, process new
```

### Terminal Operators
```kotlin
.collect { value -> }                // consume all
.first()                             // first item (throws if empty)
.firstOrNull()                       // first or null
.single()                            // exactly one (throws otherwise)
.toList()                            // collect to list
.toSet()                             // collect to set
.fold(init) { acc, v -> }           // reduce to single value
.reduce { acc, v -> }               // reduce without initial
.count()                             // count items
.launchIn(scope)                     // collect in scope (non-suspend)
.stateIn(scope, started, initial)    // → StateFlow
.shareIn(scope, started, replay)     // → SharedFlow
```

## StateFlow vs SharedFlow

| | StateFlow | SharedFlow |
|---|---|---|
| Initial value | Required | Optional |
| Replay | Always 1 (latest) | 0..N |
| Equality conflation | Yes | No |
| `.value` accessor | Yes | No |
| Use case | UI state | Events |

## Cancellation

```kotlin
ensureActive()                 // throw if cancelled
yield()                        // check cancel + yield thread
isActive                       // check without throwing
currentCoroutineContext().ensureActive()
NonCancellable                 // context for cleanup: withContext(NonCancellable) { }
```

## Exception Handling

```kotlin
// try/catch in coroutine body
launch {
    try { riskyOp() }
    catch (e: IOException) { handle(e) }
}

// Handler on root scope (launch only, not async)
val handler = CoroutineExceptionHandler { _, e -> log(e) }
scope.launch(handler) { throw Exception() }

// async: exception at .await()
val d = async { throw Exception() }
try { d.await() } catch (e: Exception) { }
```

## Testing

```kotlin
// runTest — virtual time, skips delay()
@Test fun test() = runTest {
    advanceUntilIdle()      // run all pending
    advanceTimeBy(1000)     // advance virtual clock
    runCurrent()            // run currently scheduled
}

// Turbine — Flow testing
flow.test {
    assertEquals(expected, awaitItem())
    awaitComplete()                       // or awaitError()
    cancelAndIgnoreRemainingEvents()
}

// Main dispatcher replacement
Dispatchers.setMain(UnconfinedTestDispatcher())
// ... test ...
Dispatchers.resetMain()
```

## Android Lifecycle Collection

```kotlin
// ✅ CORRECT: stops when backgrounded
lifecycleScope.launch {
    repeatOnLifecycle(Lifecycle.State.STARTED) {
        viewModel.state.collect { render(it) }
    }
}

// ✅ Single flow shorthand
viewModel.state
    .flowWithLifecycle(lifecycle, Lifecycle.State.STARTED)
    .onEach { render(it) }
    .launchIn(lifecycleScope)

// ✅ Compose
val state by viewModel.state.collectAsStateWithLifecycle()
```

## Common Anti-Patterns

| ❌ Don't | ✅ Do Instead |
|---|---|
| `GlobalScope.launch` | Use lifecycle-bound scope |
| `runBlocking` in prod | Use `suspend` + `launch` |
| `Thread.sleep()` in coroutine | `delay()` |
| `launch(Job())` | `launch { }` (auto child Job) |
| Catch `Exception` broadly | Rethrow `CancellationException` |
| `synchronized { }` in suspend | `Mutex().withLock { }` |
| Collect StateFlow in `onCreate` | Use `repeatOnLifecycle` |
