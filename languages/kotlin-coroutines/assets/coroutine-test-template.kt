// coroutine-test-template.kt — Test template for Kotlin coroutine testing
//
// Includes:
//   - TestCoroutineScheduler / TestScope / runTest
//   - StandardTestDispatcher / UnconfinedTestDispatcher
//   - Main dispatcher replacement rule
//   - Turbine Flow testing patterns
//   - Fakes and test utilities
//
// Dependencies (build.gradle.kts):
//   testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8+")
//   testImplementation("app.cash.turbine:turbine:1.1+")
//   testImplementation("org.junit.jupiter:junit-jupiter:5.10+")

package com.example.coroutines.test

import app.cash.turbine.test
import app.cash.turbine.turbineScope
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import org.junit.jupiter.api.*
import org.junit.jupiter.api.extension.*
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

// ============================================================
// Main Dispatcher Rule (JUnit 5)
// ============================================================
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

// For JUnit 4 users:
// @OptIn(ExperimentalCoroutinesApi::class)
// class MainDispatcherRule(
//     private val dispatcher: TestDispatcher = UnconfinedTestDispatcher()
// ) : TestWatcher() {
//     override fun starting(description: Description) = Dispatchers.setMain(dispatcher)
//     override fun finished(description: Description) = Dispatchers.resetMain()
// }

// ============================================================
// Sample System Under Test
// ============================================================
data class User(val id: String, val name: String)

sealed interface UiState {
    data object Loading : UiState
    data class Success(val data: User) : UiState
    data class Error(val message: String) : UiState
}

sealed interface UiEvent {
    data class ShowSnackbar(val message: String) : UiEvent
    data object NavigateBack : UiEvent
}

interface UserRepository {
    suspend fun getUser(id: String): User
    fun observeUsers(): Flow<List<User>>
}

// ============================================================
// Fake Implementation
// ============================================================
class FakeUserRepository : UserRepository {
    private var users = mutableMapOf<String, User>()
    private val usersFlow = MutableStateFlow<List<User>>(emptyList())
    private var shouldFail = false
    private var delayMs: Long = 0

    fun addUser(user: User) {
        users[user.id] = user
        usersFlow.value = users.values.toList()
    }

    fun setShouldFail(fail: Boolean) { shouldFail = fail }
    fun setDelay(ms: Long) { delayMs = ms }

    override suspend fun getUser(id: String): User {
        if (delayMs > 0) delay(delayMs)
        if (shouldFail) throw RuntimeException("Fake error")
        return users[id] ?: throw NoSuchElementException("User $id not found")
    }

    override fun observeUsers(): Flow<List<User>> = usersFlow.asStateFlow()
}

// ============================================================
// ViewModel Under Test
// ============================================================
// Note: Replace with your actual ViewModel. This is a simplified example.
class UserViewModel(
    private val repository: UserRepository,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO
) {
    // In real code, extend ViewModel() and use viewModelScope
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val _uiState = MutableStateFlow<UiState>(UiState.Loading)
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    private val _events = MutableSharedFlow<UiEvent>()
    val events: SharedFlow<UiEvent> = _events.asSharedFlow()

    val users: StateFlow<List<User>> = repository.observeUsers()
        .stateIn(scope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun loadUser(id: String) {
        scope.launch {
            _uiState.value = UiState.Loading
            try {
                val user = withContext(ioDispatcher) { repository.getUser(id) }
                _uiState.value = UiState.Success(user)
            } catch (e: Exception) {
                _uiState.value = UiState.Error(e.message ?: "Unknown error")
                _events.emit(UiEvent.ShowSnackbar("Failed to load user"))
            }
        }
    }

    fun deleteUser(id: String) {
        scope.launch {
            _events.emit(UiEvent.NavigateBack)
        }
    }

    fun cleanup() { scope.cancel() }
}

// ============================================================
// Tests
// ============================================================
@OptIn(ExperimentalCoroutinesApi::class)
@ExtendWith(MainDispatcherExtension::class)
class UserViewModelTest {

    private lateinit var fakeRepository: FakeUserRepository
    private lateinit var viewModel: UserViewModel
    private val testDispatcher = UnconfinedTestDispatcher()

    @BeforeEach
    fun setup() {
        fakeRepository = FakeUserRepository()
        viewModel = UserViewModel(
            repository = fakeRepository,
            ioDispatcher = testDispatcher
        )
    }

    @AfterEach
    fun tearDown() {
        viewModel.cleanup()
    }

    // ── Basic State Tests ───────────────────────────

    @Test
    fun `initial state is Loading`() = runTest {
        assertEquals(UiState.Loading, viewModel.uiState.value)
    }

    @Test
    fun `loadUser emits Success on valid user`() = runTest {
        fakeRepository.addUser(User("1", "Alice"))

        viewModel.loadUser("1")
        advanceUntilIdle()

        assertEquals(UiState.Success(User("1", "Alice")), viewModel.uiState.value)
    }

    @Test
    fun `loadUser emits Error on failure`() = runTest {
        fakeRepository.setShouldFail(true)

        viewModel.loadUser("1")
        advanceUntilIdle()

        assertIs<UiState.Error>(viewModel.uiState.value)
    }

    // ── Turbine Flow Tests ──────────────────────────

    @Test
    fun `uiState emits Loading then Success`() = runTest {
        fakeRepository.addUser(User("1", "Alice"))

        viewModel.uiState.test {
            assertEquals(UiState.Loading, awaitItem())

            viewModel.loadUser("1")
            assertEquals(UiState.Success(User("1", "Alice")), awaitItem())

            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `uiState emits Loading then Error with snackbar event`() = runTest {
        fakeRepository.setShouldFail(true)

        turbineScope {
            val states = viewModel.uiState.testIn(backgroundScope)
            val events = viewModel.events.testIn(backgroundScope)

            assertEquals(UiState.Loading, states.awaitItem())

            viewModel.loadUser("1")

            assertIs<UiState.Error>(states.awaitItem())
            assertEquals(
                UiEvent.ShowSnackbar("Failed to load user"),
                events.awaitItem()
            )

            states.cancelAndIgnoreRemainingEvents()
            events.cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `delete triggers NavigateBack event`() = runTest {
        viewModel.events.test {
            viewModel.deleteUser("1")
            assertEquals(UiEvent.NavigateBack, awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    // ── Flow Observation Tests ──────────────────────

    @Test
    fun `users flow reflects repository changes`() = runTest {
        viewModel.users.test {
            assertEquals(emptyList(), awaitItem())

            fakeRepository.addUser(User("1", "Alice"))
            assertEquals(listOf(User("1", "Alice")), awaitItem())

            fakeRepository.addUser(User("2", "Bob"))
            val result = awaitItem()
            assertEquals(2, result.size)

            cancelAndIgnoreRemainingEvents()
        }
    }

    // ── Virtual Time Tests ──────────────────────────

    @Test
    fun `loading with delay still works with virtual time`() = runTest {
        fakeRepository.addUser(User("1", "Alice"))
        fakeRepository.setDelay(5000)  // 5 second delay

        viewModel.loadUser("1")
        advanceTimeBy(5001)  // fast-forward past delay

        assertEquals(UiState.Success(User("1", "Alice")), viewModel.uiState.value)
    }

    // ── Testing Flow Operators ──────────────────────

    @Test
    fun `debounced search flow test`() = runTest {
        val searchResults = MutableSharedFlow<String>()

        val debounced = searchResults
            .debounce(300)
            .mapLatest { query -> "Results for: $query" }

        debounced.test {
            searchResults.emit("a")
            searchResults.emit("ab")
            searchResults.emit("abc")

            advanceTimeBy(301)
            assertEquals("Results for: abc", awaitItem())

            cancelAndIgnoreRemainingEvents()
        }
    }
}

// ============================================================
// Standalone Flow Test Examples
// ============================================================
@OptIn(ExperimentalCoroutinesApi::class)
class FlowTestExamples {

    @Test
    fun `flow error testing`() = runTest {
        val errorFlow = flow {
            emit(1)
            emit(2)
            throw RuntimeException("boom")
        }

        errorFlow.test {
            assertEquals(1, awaitItem())
            assertEquals(2, awaitItem())
            val error = awaitError()
            assertIs<RuntimeException>(error)
            assertEquals("boom", error.message)
        }
    }

    @Test
    fun `flow completion testing`() = runTest {
        val finiteFlow = flowOf(1, 2, 3)

        finiteFlow.test {
            assertEquals(1, awaitItem())
            assertEquals(2, awaitItem())
            assertEquals(3, awaitItem())
            awaitComplete()
        }
    }

    @Test
    fun `stateFlow with Turbine timeout`() = runTest {
        val stateFlow = MutableStateFlow(0)

        stateFlow.test(timeout = 5.seconds) {
            assertEquals(0, awaitItem())
            stateFlow.value = 1
            assertEquals(1, awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `testing multiple flows simultaneously`() = runTest {
        val flow1 = MutableSharedFlow<Int>()
        val flow2 = MutableSharedFlow<String>()

        turbineScope {
            val turbine1 = flow1.testIn(backgroundScope)
            val turbine2 = flow2.testIn(backgroundScope)

            flow1.emit(1)
            flow2.emit("a")

            assertEquals(1, turbine1.awaitItem())
            assertEquals("a", turbine2.awaitItem())

            turbine1.cancelAndIgnoreRemainingEvents()
            turbine2.cancelAndIgnoreRemainingEvents()
        }
    }
}
