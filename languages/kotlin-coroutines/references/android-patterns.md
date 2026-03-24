# Android Coroutine Patterns

## Table of Contents

- [viewModelScope](#viewmodelscope)
  - [Basics](#viewmodelscope-basics)
  - [Custom viewModelScope](#custom-viewmodelscope)
  - [Error Handling in viewModelScope](#error-handling-in-viewmodelscope)
- [lifecycleScope](#lifecyclescope)
  - [Activity/Fragment Usage](#activityfragment-usage)
  - [Lifecycle-aware Collection](#lifecycle-aware-collection)
- [repeatOnLifecycle](#repeatonlifecycle)
  - [How It Works](#how-repeatonlifecycle-works)
  - [Multiple Flow Collection](#multiple-flow-collection)
  - [vs launchWhenStarted](#vs-launchwhenstarted)
- [flowWithLifecycle](#flowwithlifecycle)
  - [Single Flow Collection](#single-flow-collection)
  - [When to Use](#when-to-use-flowwithlifecycle)
- [Room Coroutine Integration](#room-coroutine-integration)
  - [Suspend DAO Functions](#suspend-dao-functions)
  - [Flow from Room](#flow-from-room)
  - [Transactions](#room-transactions)
- [Retrofit Coroutine Integration](#retrofit-coroutine-integration)
  - [Suspend API Methods](#suspend-api-methods)
  - [Error Handling](#retrofit-error-handling)
  - [Flow from Retrofit](#flow-from-retrofit)
- [WorkManager Coroutines](#workmanager-coroutines)
  - [CoroutineWorker](#coroutineworker)
  - [Progress Reporting](#progress-reporting)
  - [Chaining Work](#chaining-work)
- [Jetpack Compose + Flow](#jetpack-compose--flow)
  - [collectAsState](#collectasstate)
  - [collectAsStateWithLifecycle](#collectasstatewithlifecycle)
  - [LaunchedEffect](#launchedeffect)
  - [rememberCoroutineScope](#remembercoroutinescope)
  - [produceState](#producestate)
  - [snapshotFlow](#snapshotflow)
- [Testing Android Coroutines](#testing-android-coroutines)
  - [ViewModel Testing](#viewmodel-testing)
  - [Repository Testing](#repository-testing)
  - [Flow Testing with Turbine](#flow-testing-with-turbine)
  - [Main Dispatcher Setup](#main-dispatcher-setup)

---

## viewModelScope

### viewModelScope Basics

`viewModelScope` is a `CoroutineScope` tied to the ViewModel lifecycle. It uses `SupervisorJob() + Dispatchers.Main.immediate` and is cancelled automatically when `onCleared()` is called.

```kotlin
class UserViewModel(
    private val repository: UserRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow<UserUiState>(UserUiState.Loading)
    val uiState: StateFlow<UserUiState> = _uiState.asStateFlow()

    private val _events = MutableSharedFlow<UserEvent>()
    val events: SharedFlow<UserEvent> = _events.asSharedFlow()

    init {
        loadUser()
    }

    fun loadUser() {
        viewModelScope.launch {
            _uiState.value = UserUiState.Loading
            try {
                val user = repository.getUser()
                _uiState.value = UserUiState.Success(user)
            } catch (e: Exception) {
                _uiState.value = UserUiState.Error(e.message ?: "Unknown error")
                _events.emit(UserEvent.ShowSnackbar("Failed to load user"))
            }
        }
    }

    fun deleteUser(userId: String) {
        viewModelScope.launch {
            try {
                repository.deleteUser(userId)
                _events.emit(UserEvent.NavigateBack)
            } catch (e: Exception) {
                _events.emit(UserEvent.ShowSnackbar("Delete failed"))
            }
        }
    }
}

sealed interface UserUiState {
    data object Loading : UserUiState
    data class Success(val user: User) : UserUiState
    data class Error(val message: String) : UserUiState
}

sealed interface UserEvent {
    data class ShowSnackbar(val message: String) : UserEvent
    data object NavigateBack : UserEvent
}
```

### Custom viewModelScope

```kotlin
// Override viewModelScope for custom dispatchers or error handling
class CustomViewModel(
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO
) : ViewModel() {

    // Custom scope with exception handler
    private val exceptionHandler = CoroutineExceptionHandler { _, throwable ->
        _uiState.value = UiState.Error(throwable.message)
    }

    private val customScope = viewModelScope + exceptionHandler

    fun loadData() {
        customScope.launch {
            val data = withContext(ioDispatcher) {
                repository.fetchData()
            }
            _uiState.value = UiState.Success(data)
        }
    }
}
```

### Error Handling in viewModelScope

```kotlin
class RobustViewModel(private val repository: Repository) : ViewModel() {

    // Pattern 1: try/catch per operation
    fun loadData() = viewModelScope.launch {
        runCatching { repository.getData() }
            .onSuccess { _state.value = UiState.Success(it) }
            .onFailure { _state.value = UiState.Error(it.message) }
    }

    // Pattern 2: supervisorScope for independent parallel work
    fun loadDashboard() = viewModelScope.launch {
        _state.value = UiState.Loading
        supervisorScope {
            val profile = async { runCatching { repository.getProfile() } }
            val orders = async { runCatching { repository.getOrders() } }
            val recommendations = async { runCatching { repository.getRecommendations() } }

            _state.value = DashboardState(
                profile = profile.await().getOrNull(),
                orders = orders.await().getOrDefault(emptyList()),
                recommendations = recommendations.await().getOrDefault(emptyList()),
            )
        }
    }

    // Pattern 3: Retry on failure
    fun loadWithRetry() = viewModelScope.launch {
        _state.value = UiState.Loading
        var lastError: Exception? = null
        repeat(3) { attempt ->
            try {
                val data = repository.getData()
                _state.value = UiState.Success(data)
                return@launch
            } catch (e: Exception) {
                lastError = e
                delay(1000L * (attempt + 1))  // backoff
            }
        }
        _state.value = UiState.Error(lastError?.message)
    }
}
```

---

## lifecycleScope

### Activity/Fragment Usage

```kotlin
class UserActivity : AppCompatActivity() {

    private val viewModel: UserViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // lifecycleScope is tied to Activity lifecycle (DESTROYED = cancelled)
        lifecycleScope.launch {
            // One-shot work
            val config = loadAppConfig()
            applyConfig(config)
        }
    }
}

class UserFragment : Fragment() {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        // Use viewLifecycleOwner for UI work — tied to view lifecycle
        viewLifecycleOwner.lifecycleScope.launch {
            // Safe to access binding here
        }
    }
}
```

### Lifecycle-aware Collection

```kotlin
// ❌ BAD: collect in lifecycleScope directly — doesn't stop when backgrounded
lifecycleScope.launch {
    viewModel.uiState.collect { state ->
        updateUi(state)  // runs even when app is in background!
    }
}

// ❌ DEPRECATED: launchWhenStarted — suspends but doesn't cancel
lifecycleScope.launchWhenStarted {
    viewModel.uiState.collect { state ->
        updateUi(state)  // pauses in background but keeps collector alive
    }
}

// ✅ CORRECT: repeatOnLifecycle — cancels and restarts
lifecycleScope.launch {
    repeatOnLifecycle(Lifecycle.State.STARTED) {
        viewModel.uiState.collect { state ->
            updateUi(state)  // stops when backgrounded, restarts when foregrounded
        }
    }
}
```

---

## repeatOnLifecycle

### How repeatOnLifecycle Works

```kotlin
// repeatOnLifecycle launches a block when lifecycle reaches target state
// and CANCELS it when it falls below that state. Repeats on each re-entry.

lifecycleScope.launch {
    // Code here runs once (e.g., setup)

    repeatOnLifecycle(Lifecycle.State.STARTED) {
        // This block runs when STARTED, cancelled when STOPPED
        // Launches again when STARTED again (e.g., returning from background)

        viewModel.uiState.collect { state ->
            binding.title.text = state.title
        }
    }

    // Code here runs after lifecycle reaches DESTROYED
}

// Lifecycle transitions:
// CREATED → STARTED: block launches
// STARTED → STOPPED (backgrounded): block is cancelled
// STOPPED → STARTED (foregrounded): block launches again
// STARTED → DESTROYED: block cancelled, repeatOnLifecycle returns
```

### Multiple Flow Collection

```kotlin
lifecycleScope.launch {
    repeatOnLifecycle(Lifecycle.State.STARTED) {
        // Launch each collection in a separate coroutine
        // All are cancelled together when lifecycle drops below STARTED

        launch {
            viewModel.uiState.collect { state ->
                binding.title.text = state.title
                binding.subtitle.text = state.subtitle
            }
        }

        launch {
            viewModel.events.collect { event ->
                when (event) {
                    is UiEvent.ShowSnackbar -> showSnackbar(event.message)
                    is UiEvent.Navigate -> navigator.navigate(event.route)
                }
            }
        }

        launch {
            viewModel.isLoading.collect { loading ->
                binding.progressBar.isVisible = loading
            }
        }
    }
}
```

### vs launchWhenStarted

```kotlin
// launchWhenStarted (DEPRECATED): SUSPENDS the coroutine when below STARTED
// Problem: upstream Flow keeps emitting, buffering, wasting resources

// repeatOnLifecycle: CANCELS the coroutine when below STARTED
// Advantage: upstream Flow stops, no wasted resources

// Example difference with a location flow:
// launchWhenStarted: location updates buffer in background → memory waste
// repeatOnLifecycle: location tracking stops in background → battery savings
```

---

## flowWithLifecycle

### Single Flow Collection

```kotlin
// flowWithLifecycle is a Flow operator that wraps repeatOnLifecycle
// Convenient for collecting a single flow with lifecycle awareness

override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
    viewModel.uiState
        .flowWithLifecycle(viewLifecycleOwner.lifecycle, Lifecycle.State.STARTED)
        .onEach { state ->
            binding.title.text = state.title
        }
        .launchIn(viewLifecycleOwner.lifecycleScope)
}
```

### When to Use flowWithLifecycle

```kotlin
// Use flowWithLifecycle when:
// - Collecting a single flow
// - You want to use Flow operators before collecting

// Use repeatOnLifecycle when:
// - Collecting multiple flows
// - You need to launch other coroutines alongside collection

// flowWithLifecycle is implemented as:
fun <T> Flow<T>.flowWithLifecycle(
    lifecycle: Lifecycle,
    minActiveState: Lifecycle.State = Lifecycle.State.STARTED
): Flow<T> = callbackFlow {
    lifecycle.repeatOnLifecycle(minActiveState) {
        this@flowWithLifecycle.collect { send(it) }
    }
    close()
}
```

---

## Room Coroutine Integration

### Suspend DAO Functions

```kotlin
@Dao
interface UserDao {
    // Suspend functions for one-shot operations
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(user: User)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(users: List<User>)

    @Update
    suspend fun update(user: User)

    @Delete
    suspend fun delete(user: User)

    @Query("SELECT * FROM users WHERE id = :userId")
    suspend fun getUserById(userId: String): User?

    @Query("SELECT * FROM users WHERE name LIKE :query")
    suspend fun searchUsers(query: String): List<User>

    @Query("SELECT COUNT(*) FROM users")
    suspend fun getUserCount(): Int
}
```

### Flow from Room

```kotlin
@Dao
interface UserDao {
    // Flow for observable queries — emits new list when table changes
    @Query("SELECT * FROM users ORDER BY name")
    fun observeAllUsers(): Flow<List<User>>

    @Query("SELECT * FROM users WHERE id = :userId")
    fun observeUser(userId: String): Flow<User?>

    @Query("SELECT COUNT(*) FROM users")
    fun observeUserCount(): Flow<Int>
}

// Usage in Repository
class UserRepository(private val userDao: UserDao) {
    // Expose as Flow — Room handles threading internally
    val allUsers: Flow<List<User>> = userDao.observeAllUsers()

    fun getUserById(id: String): Flow<User?> = userDao.observeUser(id)
        .distinctUntilChanged()  // avoid unnecessary emissions

    suspend fun saveUser(user: User) {
        userDao.insert(user)
        // Room's Flow will automatically re-emit new data
    }
}

// Usage in ViewModel
class UserListViewModel(private val repository: UserRepository) : ViewModel() {
    val users: StateFlow<List<User>> = repository.allUsers
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5_000),
            initialValue = emptyList()
        )
}
```

### Room Transactions

```kotlin
@Dao
abstract class TransferDao {
    @Transaction
    open suspend fun transferFunds(from: String, to: String, amount: Double) {
        val sender = getAccount(from) ?: throw IllegalArgumentException("Sender not found")
        val receiver = getAccount(to) ?: throw IllegalArgumentException("Receiver not found")

        updateBalance(from, sender.balance - amount)
        updateBalance(to, receiver.balance + amount)
        insertTransaction(TransactionRecord(from, to, amount))
    }

    @Query("SELECT * FROM accounts WHERE id = :accountId")
    abstract suspend fun getAccount(accountId: String): Account?

    @Query("UPDATE accounts SET balance = :newBalance WHERE id = :accountId")
    abstract suspend fun updateBalance(accountId: String, newBalance: Double)

    @Insert
    abstract suspend fun insertTransaction(record: TransactionRecord)
}

// Room runs @Transaction on its own dispatcher — no need for withContext(IO)
```

---

## Retrofit Coroutine Integration

### Suspend API Methods

```kotlin
interface ApiService {
    // Suspend functions — return the deserialized body directly
    @GET("users/{id}")
    suspend fun getUser(@Path("id") id: String): User

    @GET("users")
    suspend fun getUsers(@Query("page") page: Int): List<User>

    @POST("users")
    suspend fun createUser(@Body user: CreateUserRequest): User

    @PUT("users/{id}")
    suspend fun updateUser(@Path("id") id: String, @Body user: User): User

    @DELETE("users/{id}")
    suspend fun deleteUser(@Path("id") id: String)

    // Return Response<T> for access to headers, status codes
    @GET("users/{id}")
    suspend fun getUserResponse(@Path("id") id: String): Response<User>
}

// Setup
val retrofit = Retrofit.Builder()
    .baseUrl("https://api.example.com/")
    .addConverterFactory(GsonConverterFactory.create())
    .build()

val api = retrofit.create(ApiService::class.java)
```

### Retrofit Error Handling

```kotlin
class UserRepository(private val api: ApiService) {

    suspend fun getUser(id: String): Result<User> {
        return try {
            val user = api.getUser(id)
            Result.success(user)
        } catch (e: HttpException) {
            // HTTP error (4xx, 5xx)
            val errorBody = e.response()?.errorBody()?.string()
            Result.failure(ApiError(e.code(), errorBody))
        } catch (e: IOException) {
            // Network error
            Result.failure(NetworkError(e.message))
        }
    }

    // Using Response<T> for more control
    suspend fun getUserSafe(id: String): Result<User> {
        return try {
            val response = api.getUserResponse(id)
            if (response.isSuccessful) {
                Result.success(response.body()!!)
            } else {
                Result.failure(ApiError(response.code(), response.errorBody()?.string()))
            }
        } catch (e: IOException) {
            Result.failure(NetworkError(e.message))
        }
    }
}

// Reusable API call wrapper
suspend fun <T> safeApiCall(call: suspend () -> T): Result<T> {
    return try {
        Result.success(call())
    } catch (e: HttpException) {
        Result.failure(e)
    } catch (e: IOException) {
        Result.failure(e)
    }
}
```

### Flow from Retrofit

```kotlin
// Polling with Flow
fun pollUsers(intervalMs: Long = 5000): Flow<List<User>> = flow {
    while (true) {
        val users = api.getUsers(page = 1)
        emit(users)
        delay(intervalMs)
    }
}.flowOn(Dispatchers.IO)
    .catch { e -> emit(emptyList()) }
    .distinctUntilChanged()

// Pagination with Flow
fun getPaginatedUsers(): Flow<List<User>> = flow {
    var page = 1
    var hasMore = true
    while (hasMore) {
        val users = api.getUsers(page = page)
        if (users.isEmpty()) {
            hasMore = false
        } else {
            emit(users)
            page++
        }
    }
}.flowOn(Dispatchers.IO)
```

---

## WorkManager Coroutines

### CoroutineWorker

```kotlin
// build.gradle.kts: implementation("androidx.work:work-runtime-ktx:2.9+")

class SyncWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    // Runs on Dispatchers.Default by default
    override suspend fun doWork(): Result {
        return try {
            val userId = inputData.getString("user_id")
                ?: return Result.failure()

            val repository = UserRepository.getInstance()
            repository.syncUser(userId)

            Result.success()
        } catch (e: Exception) {
            if (runAttemptCount < 3) {
                Result.retry()
            } else {
                Result.failure(
                    workDataOf("error" to e.message)
                )
            }
        }
    }
}

// Enqueue
val syncRequest = OneTimeWorkRequestBuilder<SyncWorker>()
    .setInputData(workDataOf("user_id" to userId))
    .setConstraints(
        Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
    )
    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
    .build()

WorkManager.getInstance(context).enqueueUniqueWork(
    "sync_$userId",
    ExistingWorkPolicy.REPLACE,
    syncRequest
)
```

### Progress Reporting

```kotlin
class UploadWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val files = getFilesToUpload()

        files.forEachIndexed { index, file ->
            uploadFile(file)
            setProgress(workDataOf("progress" to (index + 1) * 100 / files.size))
        }

        return Result.success(workDataOf("uploaded_count" to files.size))
    }
}

// Observe progress
WorkManager.getInstance(context)
    .getWorkInfoByIdLiveData(uploadRequest.id)
    .observe(lifecycleOwner) { workInfo ->
        when (workInfo.state) {
            WorkInfo.State.RUNNING -> {
                val progress = workInfo.progress.getInt("progress", 0)
                progressBar.progress = progress
            }
            WorkInfo.State.SUCCEEDED -> {
                val count = workInfo.outputData.getInt("uploaded_count", 0)
                showSuccess("Uploaded $count files")
            }
            WorkInfo.State.FAILED -> showError("Upload failed")
            else -> { /* ENQUEUED, BLOCKED, CANCELLED */ }
        }
    }

// Or observe with Flow
WorkManager.getInstance(context)
    .getWorkInfoByIdFlow(uploadRequest.id)
    .collect { workInfo -> /* same handling */ }
```

### Chaining Work

```kotlin
// Sequential chain
val download = OneTimeWorkRequestBuilder<DownloadWorker>().build()
val process = OneTimeWorkRequestBuilder<ProcessWorker>().build()
val upload = OneTimeWorkRequestBuilder<UploadWorker>().build()

WorkManager.getInstance(context)
    .beginWith(download)
    .then(process)
    .then(upload)
    .enqueue()

// Parallel then join
val syncA = OneTimeWorkRequestBuilder<SyncWorkerA>().build()
val syncB = OneTimeWorkRequestBuilder<SyncWorkerB>().build()
val merge = OneTimeWorkRequestBuilder<MergeWorker>().build()

WorkManager.getInstance(context)
    .beginWith(listOf(syncA, syncB))  // parallel
    .then(merge)                       // after both complete
    .enqueue()
```

---

## Jetpack Compose + Flow

### collectAsState

```kotlin
@Composable
fun UserScreen(viewModel: UserViewModel = viewModel()) {
    // collectAsState collects Flow and converts to Compose State
    val uiState by viewModel.uiState.collectAsState()

    when (val state = uiState) {
        is UiState.Loading -> CircularProgressIndicator()
        is UiState.Success -> UserContent(state.user)
        is UiState.Error -> ErrorMessage(state.message)
    }
}

// With initial value for non-StateFlow
@Composable
fun ItemList(viewModel: ItemViewModel = viewModel()) {
    val items by viewModel.itemsFlow.collectAsState(initial = emptyList())
    LazyColumn {
        items(items) { item -> ItemRow(item) }
    }
}
```

### collectAsStateWithLifecycle

```kotlin
// Preferred over collectAsState — lifecycle-aware (stops collecting when backgrounded)
// Requires: implementation("androidx.lifecycle:lifecycle-runtime-compose:2.7+")

@Composable
fun UserScreen(viewModel: UserViewModel = viewModel()) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    // Stops collecting when the Activity/Fragment goes below STARTED
    // Restarts when it returns to STARTED
    when (val state = uiState) {
        is UiState.Loading -> LoadingScreen()
        is UiState.Success -> UserContent(state.user)
        is UiState.Error -> ErrorScreen(state.message)
    }
}

// With custom lifecycle state
val uiState by viewModel.uiState.collectAsStateWithLifecycle(
    minActiveState = Lifecycle.State.RESUMED  // only collect when resumed
)
```

### LaunchedEffect

```kotlin
@Composable
fun UserScreen(userId: String, viewModel: UserViewModel = viewModel()) {
    // LaunchedEffect launches a coroutine scoped to the Composition
    // Re-launches when key changes, cancels on leave/recomposition with new key
    LaunchedEffect(userId) {
        viewModel.loadUser(userId)
    }

    // One-shot events
    LaunchedEffect(Unit) {
        viewModel.events.collect { event ->
            when (event) {
                is UiEvent.ShowSnackbar -> snackbarHostState.showSnackbar(event.message)
                is UiEvent.Navigate -> navController.navigate(event.route)
            }
        }
    }

    // Multiple keys — relaunches if ANY key changes
    LaunchedEffect(userId, filterType) {
        viewModel.loadFiltered(userId, filterType)
    }
}
```

### rememberCoroutineScope

```kotlin
@Composable
fun InteractiveScreen() {
    // rememberCoroutineScope gives a scope tied to the Composition
    // For launching coroutines from callbacks/event handlers
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }
    val drawerState = rememberDrawerState(DrawerValue.Closed)

    Button(onClick = {
        // Can't use LaunchedEffect in callbacks — use scope instead
        scope.launch {
            snackbarHostState.showSnackbar("Hello!")
        }
    }) {
        Text("Show Snackbar")
    }

    Button(onClick = {
        scope.launch {
            drawerState.open()  // animated drawer open
        }
    }) {
        Text("Open Drawer")
    }
}
```

### produceState

```kotlin
// produceState converts non-Compose state into Compose State
@Composable
fun UserProfile(userId: String) {
    val userState by produceState<Result<User>?>(initialValue = null, userId) {
        value = try {
            Result.success(repository.getUser(userId))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    when {
        userState == null -> CircularProgressIndicator()
        userState!!.isSuccess -> UserContent(userState!!.getOrThrow())
        else -> ErrorMessage(userState!!.exceptionOrNull()?.message)
    }
}

// With Flow collection inside produceState
@Composable
fun LiveCounter() {
    val count by produceState(initialValue = 0) {
        repository.counterFlow.collect { value = it }
    }
    Text("Count: $count")
}
```

### snapshotFlow

```kotlin
// snapshotFlow converts Compose State reads into a Flow
@Composable
fun SearchScreen() {
    var searchQuery by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    // React to Compose state changes as a Flow
    LaunchedEffect(Unit) {
        snapshotFlow { searchQuery }
            .debounce(300)
            .distinctUntilChanged()
            .collectLatest { query ->
                viewModel.search(query)
            }
    }

    // Detect scroll position
    LaunchedEffect(listState) {
        snapshotFlow { listState.firstVisibleItemIndex }
            .map { it > 0 }
            .distinctUntilChanged()
            .collect { showFab -> viewModel.setFabVisible(showFab) }
    }

    TextField(
        value = searchQuery,
        onValueChange = { searchQuery = it }
    )
}
```

---

## Testing Android Coroutines

### ViewModel Testing

```kotlin
// Rule to replace Main dispatcher in tests
@OptIn(ExperimentalCoroutinesApi::class)
class MainDispatcherRule(
    private val dispatcher: TestDispatcher = UnconfinedTestDispatcher()
) : TestWatcher() {
    override fun starting(description: Description) {
        Dispatchers.setMain(dispatcher)
    }
    override fun finished(description: Description) {
        Dispatchers.resetMain()
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class UserViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private lateinit var viewModel: UserViewModel
    private lateinit var fakeRepository: FakeUserRepository

    @Before
    fun setup() {
        fakeRepository = FakeUserRepository()
        viewModel = UserViewModel(fakeRepository)
    }

    @Test
    fun `load user shows loading then success`() = runTest {
        fakeRepository.setUser(User("1", "Alice"))

        viewModel.loadUser()

        assertEquals(UiState.Success(User("1", "Alice")), viewModel.uiState.value)
    }

    @Test
    fun `load user shows error on failure`() = runTest {
        fakeRepository.setShouldFail(true)

        viewModel.loadUser()

        assertTrue(viewModel.uiState.value is UiState.Error)
    }

    @Test
    fun `delete triggers navigation event`() = runTest {
        viewModel.events.test {
            viewModel.deleteUser("1")
            assertEquals(UserEvent.NavigateBack, awaitItem())
        }
    }
}
```

### Repository Testing

```kotlin
@OptIn(ExperimentalCoroutinesApi::class)
class UserRepositoryTest {

    private val testDispatcher = StandardTestDispatcher()

    @Test
    fun `getUser returns user from API`() = runTest(testDispatcher) {
        val fakeApi = FakeApiService().apply {
            addUser(User("1", "Alice"))
        }
        val repository = UserRepository(fakeApi, testDispatcher)

        val result = repository.getUser("1")

        assertEquals(User("1", "Alice"), result)
    }

    @Test
    fun `observeUsers emits updates from database`() = runTest {
        val fakeDao = FakeUserDao()
        val repository = UserRepository(fakeDao)

        repository.observeUsers().test {
            assertEquals(emptyList<User>(), awaitItem())

            fakeDao.insertUser(User("1", "Alice"))
            assertEquals(listOf(User("1", "Alice")), awaitItem())

            fakeDao.insertUser(User("2", "Bob"))
            val result = awaitItem()
            assertEquals(2, result.size)

            cancelAndIgnoreRemainingEvents()
        }
    }
}
```

### Flow Testing with Turbine

```kotlin
// app.cash.turbine — powerful Flow testing library

@Test
fun `state flow emits correct sequence`() = runTest {
    viewModel.uiState.test {
        // First emission (initial value)
        assertEquals(UiState.Loading, awaitItem())

        // Trigger action
        viewModel.loadData()

        // Verify state transitions
        assertEquals(UiState.Success(expectedData), awaitItem())

        // No more emissions expected
        expectNoEvents()

        // Cleanup
        cancelAndIgnoreRemainingEvents()
    }
}

@Test
fun `shared flow events test`() = runTest {
    viewModel.events.test {
        viewModel.submitForm(validForm)
        assertEquals(Event.Success, awaitItem())

        viewModel.submitForm(invalidForm)
        assertEquals(Event.ValidationError("Invalid"), awaitItem())

        cancelAndIgnoreRemainingEvents()
    }
}

@Test
fun `flow with timeout`() = runTest {
    viewModel.slowFlow.test(timeout = 5.seconds) {
        awaitItem()  // may take a while in virtual time
        cancelAndIgnoreRemainingEvents()
    }
}

@Test
fun `flow error handling`() = runTest {
    errorProneFlow.test {
        assertEquals("first", awaitItem())
        assertEquals("second", awaitItem())
        // Expect error
        val error = awaitError()
        assertIs<IOException>(error)
    }
}

@Test
fun `flow completion`() = runTest {
    finiteFlow.test {
        assertEquals(1, awaitItem())
        assertEquals(2, awaitItem())
        assertEquals(3, awaitItem())
        awaitComplete()  // flow completes normally
    }
}
```

### Main Dispatcher Setup

```kotlin
// For JUnit 5 (extension)
@OptIn(ExperimentalCoroutinesApi::class)
class MainDispatcherExtension(
    private val dispatcher: TestDispatcher = UnconfinedTestDispatcher()
) : BeforeEachCallback, AfterEachCallback {
    override fun beforeEach(context: ExtensionContext) {
        Dispatchers.setMain(dispatcher)
    }
    override fun afterEach(context: ExtensionContext) {
        Dispatchers.resetMain()
    }
}

// Usage with JUnit 5
@ExtendWith(MainDispatcherExtension::class)
class MyViewModelTest {
    @Test
    fun testSomething() = runTest { /* ... */ }
}

// StandardTestDispatcher vs UnconfinedTestDispatcher
// StandardTestDispatcher: coroutines don't run until you advance the scheduler
//   - Use when you need to control execution order precisely
//   - Requires advanceUntilIdle(), advanceTimeBy(), etc.

// UnconfinedTestDispatcher: coroutines run eagerly (immediately)
//   - Use when you just want things to "work" in tests
//   - Simpler but less control

@Test
fun `standard dispatcher requires manual advancing`() = runTest {
    val dispatcher = StandardTestDispatcher(testScheduler)
    val scope = TestScope(dispatcher)

    var result = ""
    scope.launch { result = "done" }

    assertEquals("", result)       // not executed yet!
    advanceUntilIdle()
    assertEquals("done", result)   // now it's executed
}

@Test
fun `unconfined dispatcher runs eagerly`() = runTest {
    val dispatcher = UnconfinedTestDispatcher(testScheduler)
    val scope = TestScope(dispatcher)

    var result = ""
    scope.launch { result = "done" }

    assertEquals("done", result)   // already executed!
}
```
