// flow-patterns.kt — Common Flow patterns for real-world Kotlin applications
//
// Patterns included:
//   1. Debounce for search input
//   2. Retry with exponential backoff
//   3. Pagination (offset and cursor-based)
//   4. Polling with configurable interval
//   5. Resource-guarded Flow (open/close lifecycle)
//   6. Combine multiple data sources
//   7. Error recovery with fallback
//   8. Throttle (first/latest)
//   9. Batch/chunk emissions
//  10. Flow timeout per element

package com.example.coroutines.patterns

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlin.math.pow
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

// ============================================================
// 1. Debounce for Search Input
// ============================================================
/**
 * Debounces a search query Flow, filtering blanks and deduplicating.
 * Typical use: search-as-you-type with API calls.
 */
fun Flow<String>.asSearchQuery(
    debounceMs: Long = 300,
    minLength: Int = 2
): Flow<String> = this
    .debounce(debounceMs)
    .map { it.trim() }
    .filter { it.length >= minLength }
    .distinctUntilChanged()

// Usage:
// searchEditText.textChanges()   // from a UI binding library
//     .asSearchQuery()
//     .flatMapLatest { query -> searchRepository.search(query) }
//     .catch { emit(SearchResult.Error(it)) }
//     .collect { updateUi(it) }


// ============================================================
// 2. Retry with Exponential Backoff
// ============================================================
/**
 * Retries a Flow on failure with exponential backoff.
 *
 * @param maxRetries Maximum number of retries before propagating the error
 * @param initialDelay Initial delay before first retry
 * @param maxDelay Maximum delay cap
 * @param factor Multiplier applied to delay after each retry
 * @param retryOn Predicate to decide which exceptions to retry on
 */
fun <T> Flow<T>.retryWithBackoff(
    maxRetries: Long = 3,
    initialDelay: Duration = 1.seconds,
    maxDelay: Duration = 30.seconds,
    factor: Double = 2.0,
    retryOn: (Throwable) -> Boolean = { true }
): Flow<T> = this.retryWhen { cause, attempt ->
    if (attempt >= maxRetries || !retryOn(cause)) {
        false
    } else {
        val delayMs = (initialDelay.inWholeMilliseconds * factor.pow(attempt.toInt()))
            .toLong()
            .coerceAtMost(maxDelay.inWholeMilliseconds)
        delay(delayMs)
        true
    }
}

// Usage:
// repository.fetchDataFlow()
//     .retryWithBackoff(
//         maxRetries = 3,
//         initialDelay = 1.seconds,
//         retryOn = { it is IOException }
//     )
//     .collect { processData(it) }

/**
 * Retry a suspend function with exponential backoff (non-Flow variant).
 */
suspend fun <T> retryWithBackoff(
    maxRetries: Int = 3,
    initialDelay: Duration = 1.seconds,
    maxDelay: Duration = 30.seconds,
    factor: Double = 2.0,
    retryOn: (Throwable) -> Boolean = { true },
    block: suspend () -> T
): T {
    var currentDelay = initialDelay
    repeat(maxRetries) { attempt ->
        try {
            return block()
        } catch (e: Exception) {
            if (attempt == maxRetries - 1 || !retryOn(e)) throw e
            delay(currentDelay)
            currentDelay = (currentDelay * factor).coerceAtMost(maxDelay)
        }
    }
    return block() // last attempt
}

private operator fun Duration.times(factor: Double): Duration =
    (this.inWholeMilliseconds * factor).toLong().milliseconds


// ============================================================
// 3. Pagination — Offset-based
// ============================================================
/**
 * Creates a Flow that fetches pages of data until exhausted.
 *
 * @param pageSize Items per page
 * @param fetch Suspend function that takes (page, pageSize) and returns items
 */
fun <T> paginatedFlow(
    pageSize: Int = 20,
    fetch: suspend (page: Int, pageSize: Int) -> List<T>
): Flow<List<T>> = flow {
    var page = 0
    while (true) {
        val items = fetch(page, pageSize)
        if (items.isEmpty()) break
        emit(items)
        if (items.size < pageSize) break  // last page
        page++
    }
}

// Usage:
// paginatedFlow(pageSize = 20) { page, size ->
//     api.getUsers(page = page, limit = size)
// }
// .scan(emptyList<User>()) { acc, page -> acc + page }  // accumulate all pages
// .collect { allUsers -> updateUi(allUsers) }

/**
 * Cursor-based pagination Flow.
 */
fun <T> cursorPaginatedFlow(
    pageSize: Int = 20,
    fetch: suspend (cursor: String?, pageSize: Int) -> Pair<List<T>, String?>  // items + next cursor
): Flow<List<T>> = flow {
    var cursor: String? = null
    do {
        val (items, nextCursor) = fetch(cursor, pageSize)
        if (items.isNotEmpty()) emit(items)
        cursor = nextCursor
    } while (cursor != null && items.isNotEmpty())
}


// ============================================================
// 4. Polling with Configurable Interval
// ============================================================
/**
 * Polls a suspend function at a fixed interval.
 * Interval is measured from the END of the previous call.
 */
fun <T> pollingFlow(
    interval: Duration,
    initialDelay: Duration = Duration.ZERO,
    fetch: suspend () -> T
): Flow<T> = flow {
    if (initialDelay > Duration.ZERO) delay(initialDelay)
    while (true) {
        emit(fetch())
        delay(interval)
    }
}

/**
 * Polling with back-off on error (increases interval on failures).
 */
fun <T> resilientPollingFlow(
    interval: Duration,
    maxInterval: Duration = interval * 10,
    backoffFactor: Double = 2.0,
    fetch: suspend () -> T
): Flow<Result<T>> = flow {
    var currentInterval = interval
    while (true) {
        try {
            val result = fetch()
            emit(Result.success(result))
            currentInterval = interval  // reset on success
        } catch (e: Exception) {
            emit(Result.failure(e))
            currentInterval = (currentInterval * backoffFactor).coerceAtMost(maxInterval)
        }
        delay(currentInterval)
    }
}

private operator fun Duration.times(factor: Int): Duration =
    (this.inWholeMilliseconds * factor).milliseconds


// ============================================================
// 5. Resource-guarded Flow
// ============================================================
/**
 * A Flow that manages a resource lifecycle (open/use/close).
 * Similar to Java's try-with-resources.
 */
fun <R : AutoCloseable, T> resourceFlow(
    open: suspend () -> R,
    use: suspend FlowCollector<T>.(R) -> Unit
): Flow<T> = flow {
    val resource = open()
    try {
        use(resource)
    } finally {
        withContext(NonCancellable) {
            resource.close()
        }
    }
}

// Usage:
// resourceFlow(
//     open = { database.openConnection() },
//     use = { connection ->
//         connection.query("SELECT * FROM users").forEach { row ->
//             emit(row.toUser())
//         }
//     }
// ).collect { user -> process(user) }


// ============================================================
// 6. Combine Multiple Data Sources
// ============================================================
/**
 * Combines multiple state sources into a single UI state.
 */
data class DashboardState(
    val profile: UserProfile? = null,
    val notifications: List<Notification> = emptyList(),
    val isOnline: Boolean = true
)

data class UserProfile(val name: String)
data class Notification(val text: String)

// Pattern: combine with data class
fun dashboardFlow(
    profileFlow: Flow<UserProfile?>,
    notificationsFlow: Flow<List<Notification>>,
    connectivityFlow: Flow<Boolean>
): Flow<DashboardState> = combine(
    profileFlow,
    notificationsFlow,
    connectivityFlow
) { profile, notifications, isOnline ->
    DashboardState(
        profile = profile,
        notifications = notifications,
        isOnline = isOnline
    )
}

// For >5 flows, use combine with array:
// combine(flow1, flow2, flow3, flow4, flow5, flow6) { values ->
//     // values is Array<Any?>
// }


// ============================================================
// 7. Error Recovery with Fallback
// ============================================================
/**
 * Tries primary source, falls back to cache on error.
 */
fun <T> Flow<T>.withFallback(fallback: Flow<T>): Flow<T> =
    this.catch { emitAll(fallback) }

/**
 * Maps with error recovery per element.
 */
fun <T, R> Flow<T>.mapWithRecovery(
    transform: suspend (T) -> R,
    recover: suspend (T, Throwable) -> R
): Flow<R> = this.map { value ->
    try {
        transform(value)
    } catch (e: Exception) {
        recover(value, e)
    }
}

// Usage:
// networkFlow
//     .withFallback(cacheFlow)
//     .collect { data -> render(data) }


// ============================================================
// 8. Throttle First / Latest
// ============================================================
/**
 * Throttle first: emit the first item, then ignore for [windowMs].
 * Useful for button click debouncing (emit first click, ignore rapid follow-ups).
 */
fun <T> Flow<T>.throttleFirst(windowMs: Long): Flow<T> = flow {
    var lastEmitTime = 0L
    collect { value ->
        val currentTime = System.currentTimeMillis()
        if (currentTime - lastEmitTime >= windowMs) {
            lastEmitTime = currentTime
            emit(value)
        }
    }
}

/**
 * Throttle latest: emit the latest item in each [windowMs] window.
 * Different from debounce — guarantees emission every windowMs if there's data.
 */
fun <T> Flow<T>.throttleLatest(windowMs: Long): Flow<T> = channelFlow {
    var lastValue: T? = null
    var hasValue = false
    val ticker = kotlinx.coroutines.channels.ticker(windowMs)

    launch {
        this@throttleLatest.collect { value ->
            lastValue = value
            hasValue = true
        }
    }

    for (tick in ticker) {
        if (hasValue) {
            @Suppress("UNCHECKED_CAST")
            send(lastValue as T)
            hasValue = false
        }
    }
}


// ============================================================
// 9. Batch/Chunk Emissions
// ============================================================
/**
 * Collects Flow items into batches of [size] or after [timeoutMs] elapses.
 */
fun <T> Flow<T>.chunked(
    size: Int,
    timeoutMs: Long = Long.MAX_VALUE
): Flow<List<T>> = channelFlow {
    val buffer = mutableListOf<T>()
    val mutex = kotlinx.coroutines.sync.Mutex()

    if (timeoutMs < Long.MAX_VALUE) {
        launch {
            while (true) {
                delay(timeoutMs)
                mutex.withLock {
                    if (buffer.isNotEmpty()) {
                        send(buffer.toList())
                        buffer.clear()
                    }
                }
            }
        }
    }

    this@chunked.collect { value ->
        mutex.withLock {
            buffer.add(value)
            if (buffer.size >= size) {
                send(buffer.toList())
                buffer.clear()
            }
        }
    }

    // Flush remaining
    mutex.withLock {
        if (buffer.isNotEmpty()) {
            send(buffer.toList())
        }
    }
}

// Usage:
// sensorDataFlow
//     .chunked(size = 100, timeoutMs = 1000)
//     .collect { batch -> database.insertAll(batch) }


// ============================================================
// 10. Flow Timeout Per Element
// ============================================================
/**
 * Applies a timeout to each element's processing.
 * If processing takes longer than [timeout], emits the fallback value.
 */
fun <T, R> Flow<T>.mapWithTimeout(
    timeout: Duration,
    fallback: R,
    transform: suspend (T) -> R
): Flow<R> = this.map { value ->
    withTimeoutOrNull(timeout.inWholeMilliseconds) {
        transform(value)
    } ?: fallback
}

// Usage:
// urlsFlow
//     .mapWithTimeout(timeout = 5.seconds, fallback = CachedResponse.empty()) { url ->
//         httpClient.get(url).body()
//     }
//     .collect { response -> process(response) }
