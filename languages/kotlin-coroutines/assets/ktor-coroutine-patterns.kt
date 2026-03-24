// ktor-coroutine-patterns.kt — Ktor server coroutine patterns
//
// Patterns included:
//   1. Routing with coroutines
//   2. WebSocket handling
//   3. Server-Sent Events (SSE)
//   4. Concurrent request handling
//   5. Database integration (with connection pools)
//   6. Error handling middleware
//   7. Rate limiting with coroutines
//   8. Background jobs in Ktor
//   9. Streaming responses
//  10. Testing Ktor coroutine routes

package com.example.ktor.patterns

import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.server.plugins.statuspages.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.testing.*
import io.ktor.server.websocket.*
import io.ktor.websocket.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.Serializable
import java.time.Duration as JavaDuration
import kotlin.time.Duration.Companion.seconds

// ============================================================
// Data Models
// ============================================================
@Serializable
data class User(val id: String, val name: String, val email: String)

@Serializable
data class CreateUserRequest(val name: String, val email: String)

@Serializable
data class ErrorResponse(val message: String, val code: Int)

@Serializable
data class SseEvent(val id: String, val event: String, val data: String)

// ============================================================
// 1. Routing with Coroutines
// ============================================================
fun Application.configureRouting(userService: UserService) {
    routing {
        route("/api/users") {
            // GET /api/users — all route handlers are suspend functions
            get {
                val users = userService.getAllUsers()
                call.respond(users)
            }

            // GET /api/users/{id}
            get("/{id}") {
                val id = call.parameters["id"]
                    ?: return@get call.respond(HttpStatusCode.BadRequest, ErrorResponse("Missing id", 400))

                val user = userService.getUserById(id)
                    ?: return@get call.respond(HttpStatusCode.NotFound, ErrorResponse("User not found", 404))

                call.respond(user)
            }

            // POST /api/users
            post {
                val request = call.receive<CreateUserRequest>()
                val user = userService.createUser(request)
                call.respond(HttpStatusCode.Created, user)
            }

            // GET /api/users/search?q=...
            get("/search") {
                val query = call.request.queryParameters["q"] ?: ""
                val results = userService.searchUsers(query)
                call.respond(results)
            }
        }
    }
}

// ============================================================
// 2. WebSocket Handling
// ============================================================
fun Application.configureWebSockets(chatService: ChatService) {
    install(WebSockets) {
        pingPeriod = JavaDuration.ofSeconds(30)
        timeout = JavaDuration.ofSeconds(15)
        maxFrameSize = Long.MAX_VALUE
        masking = false
    }

    routing {
        // Basic WebSocket echo
        webSocket("/ws/echo") {
            for (frame in incoming) {
                if (frame is Frame.Text) {
                    val text = frame.readText()
                    outgoing.send(Frame.Text("Echo: $text"))
                }
            }
        }

        // Chat room with coroutines
        webSocket("/ws/chat/{room}") {
            val room = call.parameters["room"] ?: "default"
            val session = ChatSession(this)

            try {
                chatService.join(room, session)

                // Launch a coroutine to forward messages from room to this client
                val forwardJob = launch {
                    session.outgoingMessages.collect { message ->
                        outgoing.send(Frame.Text(message))
                    }
                }

                // Receive messages from this client and broadcast to room
                for (frame in incoming) {
                    if (frame is Frame.Text) {
                        chatService.broadcast(room, session, frame.readText())
                    }
                }

                forwardJob.cancel()
            } finally {
                chatService.leave(room, session)
            }
        }

        // WebSocket with JSON messages and typed handling
        webSocket("/ws/api") {
            for (frame in incoming) {
                if (frame is Frame.Text) {
                    val message = frame.readText()
                    // Parse and route message types
                    val response = when {
                        message.startsWith("subscribe:") -> {
                            val topic = message.removePrefix("subscribe:")
                            """{"type":"subscribed","topic":"$topic"}"""
                        }
                        message.startsWith("unsubscribe:") -> {
                            val topic = message.removePrefix("unsubscribe:")
                            """{"type":"unsubscribed","topic":"$topic"}"""
                        }
                        else -> """{"type":"error","message":"Unknown command"}"""
                    }
                    outgoing.send(Frame.Text(response))
                }
            }
        }
    }
}

// Chat support classes
class ChatSession(val ws: DefaultWebSocketServerSession) {
    val outgoingMessages = MutableSharedFlow<String>()
}

class ChatService {
    private val rooms = mutableMapOf<String, MutableSet<ChatSession>>()

    suspend fun join(room: String, session: ChatSession) {
        rooms.getOrPut(room) { mutableSetOf() }.add(session)
        broadcast(room, session, "User joined")
    }

    suspend fun leave(room: String, session: ChatSession) {
        rooms[room]?.remove(session)
        broadcast(room, session, "User left")
    }

    suspend fun broadcast(room: String, sender: ChatSession, message: String) {
        rooms[room]?.forEach { session ->
            if (session != sender) {
                session.outgoingMessages.emit(message)
            }
        }
    }
}

// ============================================================
// 3. Server-Sent Events (SSE)
// ============================================================
fun Application.configureSse(eventService: EventService) {
    routing {
        // SSE endpoint
        get("/api/events") {
            call.response.cacheControl(CacheControl.NoCache(null))
            call.respondTextWriter(contentType = ContentType.Text.EventStream) {
                eventService.events.collect { event ->
                    write("id: ${event.id}\n")
                    write("event: ${event.event}\n")
                    write("data: ${event.data}\n\n")
                    flush()
                }
            }
        }

        // SSE with filtering
        get("/api/events/{topic}") {
            val topic = call.parameters["topic"] ?: "all"
            call.respondTextWriter(contentType = ContentType.Text.EventStream) {
                eventService.events
                    .filter { it.event == topic || topic == "all" }
                    .collect { event ->
                        write("data: ${event.data}\n\n")
                        flush()
                    }
            }
        }
    }
}

class EventService {
    private val _events = MutableSharedFlow<SseEvent>(replay = 0, extraBufferCapacity = 100)
    val events: SharedFlow<SseEvent> = _events.asSharedFlow()

    suspend fun publish(event: SseEvent) {
        _events.emit(event)
    }
}

// ============================================================
// 4. Concurrent Request Handling
// ============================================================
class AggregatorService(
    private val userService: UserService,
    private val orderService: OrderService,
    private val recommendationService: RecommendationService
) {
    // Parallel data fetching with structured concurrency
    suspend fun getDashboard(userId: String): DashboardResponse = coroutineScope {
        val user = async { userService.getUserById(userId) }
        val orders = async { orderService.getRecentOrders(userId) }
        val recommendations = async { recommendationService.getForUser(userId) }

        DashboardResponse(
            user = user.await(),
            recentOrders = orders.await() ?: emptyList(),
            recommendations = recommendations.await() ?: emptyList()
        )
    }

    // Parallel with independent failures (supervisor)
    suspend fun getDashboardResilient(userId: String): DashboardResponse = supervisorScope {
        val user = async { runCatching { userService.getUserById(userId) }.getOrNull() }
        val orders = async { runCatching { orderService.getRecentOrders(userId) }.getOrDefault(emptyList()) }
        val recs = async { runCatching { recommendationService.getForUser(userId) }.getOrDefault(emptyList()) }

        DashboardResponse(
            user = user.await(),
            recentOrders = orders.await(),
            recommendations = recs.await()
        )
    }

    // Fan-out: process list of items concurrently with limited parallelism
    suspend fun enrichUsers(userIds: List<String>): List<User?> = coroutineScope {
        val semaphore = kotlinx.coroutines.sync.Semaphore(10) // max 10 concurrent
        userIds.map { id ->
            async {
                semaphore.withPermit {
                    runCatching { userService.getUserById(id) }.getOrNull()
                }
            }
        }.awaitAll()
    }
}

@Serializable
data class DashboardResponse(
    val user: User?,
    val recentOrders: List<String>,
    val recommendations: List<String>
)

// ============================================================
// 5. Database Integration Pattern
// ============================================================
class DatabaseUserService(
    private val dbDispatcher: CoroutineDispatcher = Dispatchers.IO.limitedParallelism(10)
) : UserService {
    // Simulate database operations with proper dispatcher
    override suspend fun getAllUsers(): List<User> = withContext(dbDispatcher) {
        // db.users.find().toList()
        listOf(User("1", "Alice", "alice@example.com"))
    }

    override suspend fun getUserById(id: String): User? = withContext(dbDispatcher) {
        // db.users.findOneById(id)
        User(id, "User $id", "user$id@example.com")
    }

    override suspend fun createUser(request: CreateUserRequest): User = withContext(dbDispatcher) {
        // db.users.insertOne(user)
        User("generated-id", request.name, request.email)
    }

    override suspend fun searchUsers(query: String): List<User> = withContext(dbDispatcher) {
        // db.users.find(Filters.regex("name", query, "i")).toList()
        emptyList()
    }
}

// ============================================================
// 6. Error Handling Middleware
// ============================================================
fun Application.configureErrorHandling() {
    install(StatusPages) {
        exception<IllegalArgumentException> { call, cause ->
            call.respond(HttpStatusCode.BadRequest, ErrorResponse(cause.message ?: "Bad request", 400))
        }
        exception<NoSuchElementException> { call, cause ->
            call.respond(HttpStatusCode.NotFound, ErrorResponse(cause.message ?: "Not found", 404))
        }
        exception<Exception> { call, cause ->
            // Log the error
            call.application.log.error("Unhandled exception", cause)
            call.respond(
                HttpStatusCode.InternalServerError,
                ErrorResponse("Internal server error", 500)
            )
        }
    }
}

// ============================================================
// 7. Rate Limiting with Coroutines
// ============================================================
class CoroutineRateLimiter(
    private val maxRequests: Int,
    private val windowMs: Long
) {
    private val requests = Channel<Long>(maxRequests)

    suspend fun acquire() {
        val now = System.currentTimeMillis()
        // Try to drain expired tokens
        while (true) {
            val oldest = requests.tryReceive().getOrNull() ?: break
            if (now - oldest < windowMs) {
                // Put it back — not expired
                requests.send(oldest)
                break
            }
        }

        // Check if under limit
        if (requests.trySend(now).isSuccess) {
            return // allowed
        }

        // Over limit — wait for window to expire
        val oldest = requests.receive()
        val waitTime = windowMs - (now - oldest)
        if (waitTime > 0) delay(waitTime)
        requests.send(System.currentTimeMillis())
    }
}

// Usage in route:
// val rateLimiter = CoroutineRateLimiter(maxRequests = 100, windowMs = 60_000)
// get("/api/limited") {
//     rateLimiter.acquire()
//     call.respond(fetchData())
// }

// ============================================================
// 8. Background Jobs in Ktor
// ============================================================
fun Application.configureBackgroundJobs(eventService: EventService) {
    // Launch a background coroutine tied to application lifecycle
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // Periodic cleanup job
    scope.launch {
        while (isActive) {
            try {
                performCleanup()
            } catch (e: Exception) {
                log.error("Cleanup failed", e)
            }
            delay(60.seconds)
        }
    }

    // Event processing job
    scope.launch {
        eventService.events.collect { event ->
            processEvent(event)
        }
    }

    // Graceful shutdown
    monitor.subscribe(ApplicationStopping) {
        scope.cancel("Application stopping")
    }
}

private suspend fun performCleanup() { /* ... */ }
private suspend fun processEvent(event: SseEvent) { /* ... */ }

// ============================================================
// 9. Streaming Responses
// ============================================================
fun Application.configureStreaming() {
    routing {
        // Stream large dataset without holding all in memory
        get("/api/export/users") {
            call.respondTextWriter(contentType = ContentType.Text.CSV) {
                write("id,name,email\n")
                // Stream from database cursor
                getUserFlow().collect { user ->
                    write("${user.id},${user.name},${user.email}\n")
                    flush()
                }
            }
        }

        // Chunked JSON array streaming
        get("/api/stream/users") {
            call.respondTextWriter(contentType = ContentType.Application.Json) {
                write("[")
                var first = true
                getUserFlow().collect { user ->
                    if (!first) write(",")
                    first = false
                    write("""{"id":"${user.id}","name":"${user.name}"}""")
                    flush()
                }
                write("]")
            }
        }
    }
}

private fun getUserFlow(): Flow<User> = flow {
    // Simulate streaming from database
    for (i in 1..1000) {
        emit(User("$i", "User $i", "user$i@example.com"))
    }
}

// ============================================================
// 10. Testing Ktor Coroutine Routes
// ============================================================
// class UserRoutesTest {
//     @Test
//     fun `GET users returns list`() = testApplication {
//         application {
//             install(ContentNegotiation) { json() }
//             configureRouting(FakeUserService())
//         }
//
//         client.get("/api/users").apply {
//             assertEquals(HttpStatusCode.OK, status)
//             val users = body<List<User>>()
//             assertEquals(1, users.size)
//         }
//     }
//
//     @Test
//     fun `POST users creates user`() = testApplication {
//         application {
//             install(ContentNegotiation) { json() }
//             configureRouting(FakeUserService())
//         }
//
//         client.post("/api/users") {
//             contentType(ContentType.Application.Json)
//             setBody(CreateUserRequest("Alice", "alice@test.com"))
//         }.apply {
//             assertEquals(HttpStatusCode.Created, status)
//         }
//     }
//
//     @Test
//     fun `WebSocket echo works`() = testApplication {
//         application { configureWebSockets(ChatService()) }
//
//         val client = createClient { install(io.ktor.client.plugins.websocket.WebSockets) }
//         client.webSocket("/ws/echo") {
//             send(Frame.Text("Hello"))
//             val response = incoming.receive() as Frame.Text
//             assertEquals("Echo: Hello", response.readText())
//         }
//     }
// }

// ============================================================
// Service Interfaces
// ============================================================
interface UserService {
    suspend fun getAllUsers(): List<User>
    suspend fun getUserById(id: String): User?
    suspend fun createUser(request: CreateUserRequest): User
    suspend fun searchUsers(query: String): List<User>
}

interface OrderService {
    suspend fun getRecentOrders(userId: String): List<String>
}

interface RecommendationService {
    suspend fun getForUser(userId: String): List<String>
}

// ============================================================
// Application Entry Point Example
// ============================================================
// fun main() {
//     embeddedServer(Netty, port = 8080) {
//         install(ContentNegotiation) { json() }
//         configureErrorHandling()
//
//         val userService = DatabaseUserService()
//         val chatService = ChatService()
//         val eventService = EventService()
//
//         configureRouting(userService)
//         configureWebSockets(chatService)
//         configureSse(eventService)
//         configureStreaming()
//         configureBackgroundJobs(eventService)
//     }.start(wait = true)
// }
