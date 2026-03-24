# Kotlin Coroutines Troubleshooting Guide

## Table of Contents

- [Leaking Coroutines](#leaking-coroutines)
  - [Symptoms](#leak-symptoms)
  - [Root Causes](#leak-root-causes)
  - [Fixes](#leak-fixes)
- [Cancellation Not Propagating](#cancellation-not-propagating)
  - [Swallowed CancellationException](#swallowed-cancellationexception)
  - [Non-cooperative Cancellation](#non-cooperative-cancellation)
  - [Broken Job Hierarchy](#broken-job-hierarchy)
- [Blocking in Suspend Functions](#blocking-in-suspend-functions)
  - [Detecting Blocking Calls](#detecting-blocking-calls)
  - [Common Blocking Offenders](#common-blocking-offenders)
  - [Proper Wrapping](#proper-wrapping)
- [GlobalScope Misuse](#globalscope-misuse)
  - [Why GlobalScope Is Dangerous](#why-globalscope-is-dangerous)
  - [Migration Strategies](#migration-strategies)
- [Debugging Tools](#debugging-tools)
  - [IntelliJ Coroutine Debugger](#intellij-coroutine-debugger)
  - [DebugProbes](#debugprobes)
  - [Logging Coroutine Context](#logging-coroutine-context)
- [Deadlocks with Dispatchers.Main](#deadlocks-with-dispatchersmain)
  - [Classic Main Thread Deadlock](#classic-main-thread-deadlock)
  - [runBlocking on Main](#runblocking-on-main)
  - [Nested withContext Deadlocks](#nested-withcontext-deadlocks)
- [Structured Concurrency Violations](#structured-concurrency-violations)
  - [Escaped CoroutineScope](#escaped-coroutinescope)
  - [Wrong Scope for Launch](#wrong-scope-for-launch)
  - [SupervisorJob Misplacement](#supervisorjob-misplacement)
- [Flow Collection Pitfalls](#flow-collection-pitfalls)
  - [Collecting in the Wrong Scope](#collecting-in-the-wrong-scope)
  - [Multiple Collections of SharedFlow](#multiple-collections-of-sharedflow)
  - [Flow Never Completes](#flow-never-completes)
  - [catch vs onCompletion Order](#catch-vs-oncompletion-order)
- [Memory Leaks with StateFlow](#memory-leaks-with-stateflow)
  - [Retaining Large Objects](#retaining-large-objects)
  - [WhileSubscribed Misconfiguration](#whilesubscribed-misconfiguration)
  - [Activity/Fragment Leak Patterns](#activityfragment-leak-patterns)

---

## Leaking Coroutines

### Leak Symptoms

- Memory usage grows unboundedly over time
- Background work continues after the screen/component is destroyed
- `DebugProbes.dumpCoroutines()` shows growing number of suspended coroutines
- Log messages appear from destroyed components

### Leak Root Causes

```kotlin
// 1. Using GlobalScope — coroutine outlives the component
class MyActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        GlobalScope.launch {  // ❌ survives activity destruction
            while (true) {
                updateLocation()
                delay(5000)
            }
        }
    }
}

// 2. Forgetting to cancel scope
class MyService {
    private val scope = CoroutineScope(Dispatchers.Default)

    fun start() {
        scope.launch { periodicWork() }
    }

    // ❌ Missing: scope.cancel() when service stops
}

// 3. Holding reference to destroyed context
class Presenter(private val view: View) {
    private val scope = CoroutineScope(Dispatchers.Main)

    fun loadData() {
        scope.launch {
            val data = repository.fetch()  // takes 10s
            view.show(data)  // ❌ view may be destroyed
        }
    }
}
```

### Leak Fixes

```kotlin
// Fix 1: Use lifecycle-aware scopes
class MyActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        lifecycleScope.launch {  // ✅ auto-cancelled on destroy
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                updateLocation()
            }
        }
    }
}

// Fix 2: Always cancel scopes
class MyService : LifecycleObserver {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun start() { scope.launch { periodicWork() } }

    @OnDestroy
    fun stop() { scope.cancel() }  // ✅ cancels all children
}

// Fix 3: Check lifecycle before UI updates
scope.launch {
    val data = repository.fetch()
    if (isActive) {  // ✅ or use ensureActive()
        view.show(data)
    }
}
```

---

## Cancellation Not Propagating

### Swallowed CancellationException

```kotlin
// ❌ BAD: catching Exception swallows CancellationException
suspend fun doWork() {
    try {
        longRunningTask()
    } catch (e: Exception) {
        log.error("Failed", e)  // swallows CancellationException!
    }
}

// ✅ FIX: rethrow CancellationException
suspend fun doWork() {
    try {
        longRunningTask()
    } catch (e: CancellationException) {
        throw e  // must rethrow!
    } catch (e: Exception) {
        log.error("Failed", e)
    }
}

// ✅ BETTER: use runCatching only for non-suspend calls, or handle carefully
suspend fun doWork() {
    try {
        longRunningTask()
    } catch (e: Exception) {
        coroutineContext.ensureActive()  // throws if cancelled
        log.error("Failed", e)
    }
}
```

### Non-cooperative Cancellation

```kotlin
// ❌ BAD: CPU-bound loop never checks cancellation
suspend fun processItems(items: List<Item>) {
    for (item in items) {
        heavyComputation(item)  // never suspends!
    }
}

// ✅ FIX 1: Check isActive
suspend fun processItems(items: List<Item>) {
    for (item in items) {
        ensureActive()  // throws CancellationException if cancelled
        heavyComputation(item)
    }
}

// ✅ FIX 2: yield() — checks cancellation AND lets other coroutines run
suspend fun processItems(items: List<Item>) {
    for (item in items) {
        yield()
        heavyComputation(item)
    }
}

// ✅ FIX 3: Check periodically for tight loops
suspend fun processBigData(data: ByteArray) {
    for (i in data.indices) {
        if (i % 1000 == 0) ensureActive()
        process(data[i])
    }
}
```

### Broken Job Hierarchy

```kotlin
// ❌ BAD: creating a new Job breaks parent-child relationship
fun startWork() {
    scope.launch(Job()) {  // ❌ new Job replaces parent!
        // This coroutine is NOT a child of scope
        // scope.cancel() won't cancel this
    }
}

// ✅ FIX: let the builder create the child Job
fun startWork() {
    scope.launch {  // ✅ child Job created automatically
        // This is a proper child of scope
    }
}

// ❌ BAD: launch in custom scope with new Job
val customScope = CoroutineScope(Job() + Dispatchers.IO)
fun startWork() {
    customScope.launch {
        // Lives independently of any parent
    }
}

// ✅ FIX: derive scope from parent
fun CoroutineScope.startWork() {
    launch {
        // Proper child of calling scope
    }
}
```

---

## Blocking in Suspend Functions

### Detecting Blocking Calls

```kotlin
// Enable blocking detection in debug mode
// Add to JVM args: -Dkotlinx.coroutines.debug

// Using BlockHound (reactor tool, works with coroutines)
// build.gradle.kts:
// testImplementation("io.projectreactor.tools:blockhound:1.0.8")
BlockHound.install(CoroutinesBlockHoundIntegration())

// This will throw when a blocking call is made on a non-blocking thread
```

### Common Blocking Offenders

```kotlin
// ❌ These block the thread despite being in a suspend function:
suspend fun bad1() = Thread.sleep(1000)           // blocks!
suspend fun bad2() = file.readText()               // java.io blocks!
suspend fun bad3() = URL(url).readText()           // blocks!
suspend fun bad4() = synchronized(lock) { work() } // blocks!
suspend fun bad5() = future.get()                  // blocks!
suspend fun bad6() = latch.await()                 // blocks!
suspend fun bad7() = blockingQueue.take()          // blocks!
```

### Proper Wrapping

```kotlin
// ✅ Wrap blocking calls with withContext(Dispatchers.IO)
suspend fun readFile(path: String): String = withContext(Dispatchers.IO) {
    File(path).readText()
}

// ✅ Use suspendCancellableCoroutine for callback APIs
suspend fun fetchAsync(): Result = suspendCancellableCoroutine { cont ->
    api.fetch(object : Callback {
        override fun onSuccess(data: Result) = cont.resume(data)
        override fun onError(e: Exception) = cont.resumeWithException(e)
    })
    cont.invokeOnCancellation { api.cancel() }
}

// ✅ Convert CompletableFuture to coroutine
suspend fun fetchFuture(): Result = completableFuture.await()  // kotlinx-coroutines-jdk8

// ✅ Use Mutex instead of synchronized
private val mutex = Mutex()
suspend fun safeMutation() = mutex.withLock {
    sharedState.modify()
}
```

---

## GlobalScope Misuse

### Why GlobalScope Is Dangerous

```kotlin
// GlobalScope creates top-level coroutines that:
// 1. Are NOT cancelled when the calling component is destroyed
// 2. Don't propagate exceptions to parent
// 3. Leak until they complete or the JVM shuts down
// 4. Cause flaky tests (work continues after test ends)

// ❌ Common misuse patterns
class Repository {
    fun saveInBackground(data: Data) {
        GlobalScope.launch {  // fire-and-forget leak
            database.save(data)
        }
    }
}

class ViewModel {
    fun refresh() {
        GlobalScope.launch {  // outlives ViewModel
            _state.value = fetchData()  // may update dead StateFlow
        }
    }
}
```

### Migration Strategies

```kotlin
// Strategy 1: Accept CoroutineScope as parameter
class Repository(private val externalScope: CoroutineScope) {
    fun saveInBackground(data: Data) {
        externalScope.launch { database.save(data) }
    }
}

// Strategy 2: Make the function suspend
class Repository {
    suspend fun save(data: Data) {
        withContext(Dispatchers.IO) { database.save(data) }
    }
}

// Strategy 3: Use a component-scoped scope
class Repository {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun saveInBackground(data: Data) {
        scope.launch { database.save(data) }
    }

    fun close() { scope.cancel() }  // call when done
}

// Strategy 4: For truly application-scoped work, use a named scope
// (At least it's explicit about the intent)
object AppScope {
    val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default + CoroutineName("app-scope")
    )
}
```

---

## Debugging Tools

### IntelliJ Coroutine Debugger

```
1. Enable in: Settings → Build → Debugger → Data Views → Kotlin → "Enable coroutine debugging"
2. Set breakpoint inside a coroutine
3. Debug run → Coroutines tab appears
4. Shows:
   - All coroutines with their state (RUNNING, SUSPENDED, CREATED)
   - Coroutine call stack (including suspension points)
   - Parent-child hierarchy
   - CoroutineContext elements
5. Can "Dump Coroutines" to see all at once
```

### DebugProbes

```kotlin
// Setup (test or debug builds only — has performance overhead)
import kotlinx.coroutines.debug.DebugProbes

@BeforeAll
fun setup() {
    DebugProbes.install()
    DebugProbes.sanitizeStackTraces = true
}

@AfterAll
fun teardown() {
    DebugProbes.uninstall()
}

// Usage in tests: detect leaked coroutines
@AfterEach
fun checkLeaks() {
    val leakedCoroutines = DebugProbes.dumpCoroutinesInfo()
        .filter { it.state == State.SUSPENDED }
    if (leakedCoroutines.isNotEmpty()) {
        DebugProbes.dumpCoroutines()
        fail("Leaked ${leakedCoroutines.size} coroutines!")
    }
}

// Print coroutine hierarchy
DebugProbes.printJob(rootJob)
// Output:
// "root":StandaloneCoroutine{Active}
//     "child-1":StandaloneCoroutine{Active}
//     "child-2":DeferredCoroutine{Completing}
//         "grandchild":StandaloneCoroutine{Active}
```

### Logging Coroutine Context

```kotlin
// Add -Dkotlinx.coroutines.debug to JVM args
// Thread names will include coroutine info:
// "DefaultDispatcher-worker-1 @my-coroutine#42"

// Custom logging with context
suspend fun logWithContext(msg: String) {
    val name = coroutineContext[CoroutineName]?.name ?: "unnamed"
    val job = coroutineContext[Job]
    println("[$name, job=$job] $msg")
}

// Named coroutines for better logs
launch(CoroutineName("user-fetch")) {
    logWithContext("Starting fetch")  // [user-fetch, job=...] Starting fetch
}
```

---

## Deadlocks with Dispatchers.Main

### Classic Main Thread Deadlock

```kotlin
// ❌ DEADLOCK: runBlocking on Main thread waits for Main dispatcher
// (Android Main thread)
fun onCreate() {
    val data = runBlocking {  // blocks Main thread
        withContext(Dispatchers.Main) {  // needs Main thread → deadlock!
            fetchData()
        }
    }
}

// ✅ FIX: use lifecycleScope
fun onCreate() {
    lifecycleScope.launch {
        val data = fetchData()  // already on Main
        render(data)
    }
}
```

### runBlocking on Main

```kotlin
// ❌ DEADLOCK: Any runBlocking on the Main thread is dangerous
fun onButtonClick() {
    val result = runBlocking {  // blocks Main
        repository.getData()    // if getData() eventually needs Main → deadlock
    }
}

// ❌ Subtle deadlock: liveData builder with runBlocking
val data = liveData {
    val result = runBlocking {  // blocks LiveData's Main context
        api.fetch()
    }
    emit(result)
}

// ✅ FIX: never use runBlocking on Main thread
fun onButtonClick() {
    viewModel.loadData()  // launch in viewModelScope
}
```

### Nested withContext Deadlocks

```kotlin
// ❌ Potential deadlock with limited dispatcher
val singleThread = newSingleThreadContext("single")

suspend fun a() = withContext(singleThread) {
    b()  // calls another function that needs the same thread
}

suspend fun b() = withContext(singleThread) {
    // ✅ This actually works! withContext is smart enough to stay on the same thread
    // But beware of this with external single-threaded dispatchers
    delay(100)
}

// ❌ Real deadlock: blocking the limited thread while waiting for it
val limited = Dispatchers.IO.limitedParallelism(1)
runBlocking(limited) {  // occupies the single slot
    withContext(limited) {  // needs the same slot → deadlock!
        work()
    }
}
```

---

## Structured Concurrency Violations

### Escaped CoroutineScope

```kotlin
// ❌ BAD: scope escapes the structured boundary
suspend fun loadData(): Flow<Data> = coroutineScope {
    val scope = this  // capturing scope reference
    flow {
        scope.launch { /* ... */ }  // ❌ using scope after coroutineScope returns
        emit(data)
    }
}

// ✅ FIX: use flowOn or channelFlow
fun loadData(): Flow<Data> = channelFlow {
    launch {  // ✅ channelFlow provides its own scope
        val data = fetchData()
        send(data)
    }
}

// ❌ BAD: storing scope in a field
class BadClass {
    private lateinit var scope: CoroutineScope

    suspend fun init() = coroutineScope {
        scope = this  // ❌ escapes coroutineScope boundary
    }

    fun doWork() {
        scope.launch { /* uses escaped scope */ }
    }
}
```

### Wrong Scope for Launch

```kotlin
// ❌ BAD: launching in suspend function without scope receiver
suspend fun processBatch(items: List<Item>) {
    items.forEach { item ->
        // Where does this coroutine live? No structured parent!
        CoroutineScope(Dispatchers.IO).launch {  // ❌ orphaned scope
            processItem(item)
        }
    }
    // Returns immediately, orphaned coroutines run uncontrolled
}

// ✅ FIX: use coroutineScope to create structured children
suspend fun processBatch(items: List<Item>) = coroutineScope {
    items.forEach { item ->
        launch(Dispatchers.IO) {  // ✅ child of coroutineScope
            processItem(item)
        }
    }
    // Waits for all children to complete
}
```

### SupervisorJob Misplacement

```kotlin
// ❌ WRONG: SupervisorJob() in launch has no effect
scope.launch(SupervisorJob()) {
    // This creates a NEW root job, breaking the parent-child hierarchy
    // Exceptions won't propagate to scope
    launch { throw RuntimeException() }  // lost exception
}

// ✅ RIGHT: use supervisorScope { } inside coroutines
scope.launch {
    supervisorScope {
        launch { throw RuntimeException() }  // handled independently
        launch { safeWork() }  // not affected by sibling failure
    }
}

// ✅ RIGHT: SupervisorJob in scope construction
val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
scope.launch { throw RuntimeException() }  // other children survive
scope.launch { safeWork() }  // unaffected
```

---

## Flow Collection Pitfalls

### Collecting in the Wrong Scope

```kotlin
// ❌ BAD: collecting flow in GlobalScope
fun observeData() {
    GlobalScope.launch {
        repository.dataFlow.collect { data ->
            updateUi(data)  // leaks, may update destroyed UI
        }
    }
}

// ❌ BAD: using launchIn on the wrong scope
fun observeData() {
    repository.dataFlow
        .onEach { updateUi(it) }
        .launchIn(GlobalScope)  // same problem
}

// ✅ GOOD: lifecycle-aware collection (Android)
lifecycleScope.launch {
    repeatOnLifecycle(Lifecycle.State.STARTED) {
        repository.dataFlow.collect { data ->
            updateUi(data)
        }
    }
}
```

### Multiple Collections of SharedFlow

```kotlin
// SharedFlow is hot — each collect creates a new collector
// ❌ BAD: collecting the same SharedFlow twice without knowing it
viewModel.events.collect { handleEvent(it) }  // suspends forever
viewModel.events.collect { logEvent(it) }     // never reached!

// ✅ FIX: launch each collection in a separate coroutine
lifecycleScope.launch {
    repeatOnLifecycle(Lifecycle.State.STARTED) {
        launch { viewModel.events.collect { handleEvent(it) } }
        launch { viewModel.events.collect { logEvent(it) } }
    }
}
```

### Flow Never Completes

```kotlin
// Hot flows (StateFlow, SharedFlow) never complete
// ❌ This will suspend forever:
val allValues = stateFlow.toList()  // hangs!

// ✅ Use take() or first() for finite collection
val firstValue = stateFlow.first()
val firstFive = stateFlow.take(5).toList()

// ❌ BAD: combining hot + cold flows can be surprising
val cold = flowOf(1, 2, 3)
val hot = MutableStateFlow(0)

cold.combine(hot) { a, b -> a + b }
    .collect { println(it) }
// Completes after cold flow finishes (cold drives completion)

hot.combine(cold) { a, b -> a + b }
    .collect { println(it) }
// Also completes after cold flow finishes
```

### catch vs onCompletion Order

```kotlin
// catch only catches UPSTREAM exceptions
flow {
    emit(1)
    throw RuntimeException("upstream error")
}
.catch { e -> emit(-1) }  // catches upstream error
.onCompletion { cause -> println("Done: $cause") }
.collect { println(it) }
// Output: 1, -1, Done: null

// ❌ catch AFTER the failing operator doesn't catch it
flow { emit(1) }
.map { throw RuntimeException("in map") }
.onCompletion { cause -> println("Done: $cause") }
.catch { e -> println("Caught: $e") }  // ❌ too late for map error above onCompletion
.collect { println(it) }

// ✅ Place catch ABOVE the operators you want to protect
flow { emit(1) }
.map { throw RuntimeException("in map") }
.catch { e -> println("Caught: $e") }  // ✅ catches map error
.collect { println(it) }
```

---

## Memory Leaks with StateFlow

### Retaining Large Objects

```kotlin
// ❌ BAD: StateFlow holds the last value — if it's large, it's retained
private val _state = MutableStateFlow<List<LargeObject>>(emptyList())

fun loadHugeDataset() {
    viewModelScope.launch {
        val data = loadAllRecords()  // 10,000 items with bitmaps
        _state.value = data  // retained until scope is cancelled or value changes
    }
}

// ✅ FIX: use pagination, or clear on lifecycle events
fun onCleared() {
    _state.value = emptyList()  // release reference
}

// ✅ BETTER: hold minimal state
data class UiState(
    val itemCount: Int,
    val visibleItems: List<ItemSummary>,  // lightweight
    // NOT val allItems: List<LargeObject>
)
```

### WhileSubscribed Misconfiguration

```kotlin
// ❌ BAD: Eagerly keeping flow active
val state = repository.observeAll()
    .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
// Active forever, even when no one is collecting

// ❌ BAD: 0ms timeout — resubscribes on every config change
val state = repository.observeAll()
    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(0), emptyList())
// Screen rotation → unsubscribe → resubscribe → re-query database

// ✅ GOOD: 5-second timeout survives config changes
val state = repository.observeAll()
    .stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(
            stopTimeoutMillis = 5_000,    // keep alive 5s after last collector
            replayExpirationMillis = 0     // keep replay cache indefinitely
        ),
        initialValue = emptyList()
    )
```

### Activity/Fragment Leak Patterns

```kotlin
// ❌ LEAK: collecting in onCreate without lifecycle awareness
class MyFragment : Fragment() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // This collector lives as long as the FRAGMENT, not the VIEW
        lifecycleScope.launch {
            viewModel.uiState.collect { state ->
                binding.textView.text = state.text  // ❌ binding may be null!
            }
        }
    }
}

// ✅ FIX: use repeatOnLifecycle or collect in onViewCreated
class MyFragment : Fragment() {
    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.uiState.collect { state ->
                    binding.textView.text = state.text  // ✅ safe
                }
            }
        }
    }
}

// ✅ Alternative: flowWithLifecycle extension
override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
    viewModel.uiState
        .flowWithLifecycle(viewLifecycleOwner.lifecycle, Lifecycle.State.STARTED)
        .onEach { state -> binding.textView.text = state.text }
        .launchIn(viewLifecycleOwner.lifecycleScope)
}
```
