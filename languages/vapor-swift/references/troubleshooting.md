# Vapor Troubleshooting Guide

## Table of Contents

- [Swift Concurrency & Sendable Warnings](#swift-concurrency--sendable-warnings)
- [Fluent Migration Errors](#fluent-migration-errors)
- [Connection Pool Exhaustion](#connection-pool-exhaustion)
- [Memory Leaks with EventLoop](#memory-leaks-with-eventloop)
- [Docker Build Failures](#docker-build-failures)
- [Linux vs macOS Differences](#linux-vs-macos-differences)
- [Leaf Template Rendering Errors](#leaf-template-rendering-errors)
- [WebSocket Disconnections](#websocket-disconnections)
- [JWT Verification Failures](#jwt-verification-failures)
- [Common Runtime Errors](#common-runtime-errors)
- [Debugging Techniques](#debugging-techniques)

---

## Swift Concurrency & Sendable Warnings

### Problem: `@unchecked Sendable` warnings everywhere

Fluent models use mutable properties with property wrappers that are not automatically `Sendable`.

**Solution:** Mark Fluent models `@unchecked Sendable`:

```swift
final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"
    // ...
}
```

This is the official Vapor recommendation. Fluent models are designed to be used within a single request context and passed between async boundaries.

### Problem: "Capture of non-sendable type in @Sendable closure"

```
⚠️ Capture of 'user' with non-sendable type 'User' in a `@Sendable` closure
```

**Solution:** Ensure the model conforms to `@unchecked Sendable`. If the warning persists on custom types, either:

```swift
// Option 1: Make the type Sendable
struct UserResponse: Content, Sendable {
    let id: UUID
    let name: String
}

// Option 2: Use @unchecked Sendable for reference types
final class MyService: @unchecked Sendable {
    private let lock = NIOLock()
    private var cache: [String: String] = [:]
}
```

### Problem: "Non-sendable type passed in implicitly asynchronous call"

When passing objects to `Task { }` blocks:

```swift
// ❌ Warning
app.get("process") { req async throws -> String in
    let user = try await User.find(id, on: req.db)
    Task {
        // req is captured here — non-sendable warning
        try await sendEmail(to: user!, on: req.db)
    }
    return "Processing"
}

// ✅ Fix: extract needed values before Task
app.get("process") { req async throws -> String in
    let user = try await User.find(id, on: req.db)
    let email = user!.email
    let app = req.application
    Task {
        try await app.sendEmail(to: email)
    }
    return "Processing"
}
```

### Problem: Strict concurrency checking breaks everything

With `-strict-concurrency=complete`, you may see hundreds of warnings.

**Solution:** Use targeted strict concurrency:

```swift
// Package.swift — enable warnings, not errors
.executableTarget(
    name: "App",
    dependencies: [...],
    swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency=targeted")
    ]
)
```

---

## Fluent Migration Errors

### Problem: "Migration has already been prepared"

```
FluentKit/Migrations.swift: migration CreateUser has already been prepared
```

**Solution:** Fluent tracks applied migrations in `_fluent_migrations` table. If you need to re-run:

```swift
// Revert and re-migrate
try await app.autoRevert()
try await app.autoMigrate()

// Or manually delete the migration record
// DELETE FROM _fluent_migrations WHERE name = 'CreateUser';
```

### Problem: "Relation requires foreign key... table does not exist"

Migration order matters. Tables referenced by foreign keys must exist first.

```swift
// ✅ Correct order
app.migrations.add(CreateUser())      // users table first
app.migrations.add(CreatePost())      // posts references users

// ❌ Wrong order
app.migrations.add(CreatePost())      // FAILS: users table doesn't exist yet
app.migrations.add(CreateUser())
```

### Problem: "Column already exists" on update migration

```swift
// ❌ This fails if column exists
try await database.schema("users").field("phone", .string).update()

// ✅ Check first or use idempotent approach
struct AddPhoneToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("phone", .string)
            .update()
    }
    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("phone")
            .update()
    }
}
```

### Problem: Enum migration fails on PostgreSQL

PostgreSQL enums must be created before use:

```swift
// ❌ Fails
.field("status", .string, .required)  // Works but loses type safety

// ✅ Create enum type first
let statusEnum = try await database.enum("order_status")
    .case("pending")
    .case("shipped")
    .case("delivered")
    .create()

try await database.schema("orders")
    .field("status", statusEnum, .required)
    .create()
```

### Problem: Migration stuck / deadlock

If a migration hangs, it may be waiting for a database lock.

**Solution:**
1. Check for active database connections/locks
2. Restart the database
3. Manually mark the migration in `_fluent_migrations`

---

## Connection Pool Exhaustion

### Symptoms

- Requests hang and eventually timeout
- Logs show: `ConnectionPoolError: Connection request timed out`
- Application becomes unresponsive under load

### Diagnosis

```swift
// Add logging to see pool status
app.logger.logLevel = .debug
```

### Common Causes and Fixes

**Cause 1: Leaked database connections in long-running tasks**

```swift
// ❌ Holds connection for entire task duration
app.get("slow") { req async throws -> String in
    let users = try await User.query(on: req.db).all()
    try await Task.sleep(for: .seconds(30))  // Connection held!
    return "Done"
}

// ✅ Release connection before slow work
app.get("slow") { req async throws -> String in
    let users = try await User.query(on: req.db).all()
    let names = users.map(\.name)  // Extract data
    try await Task.sleep(for: .seconds(30))  // No connection held
    return names.joined(separator: ", ")
}
```

**Cause 2: Too many concurrent requests for pool size**

```swift
// Increase pool size in configure.swift
var pgConfig = SQLPostgresConfiguration(
    hostname: "localhost",
    username: "vapor",
    password: "secret",
    database: "mydb",
    tls: .disable
)
// Default is typically 1 connection per event loop
// Increase for high-concurrency apps
app.databases.use(
    .postgres(configuration: pgConfig, maxConnectionsPerEventLoop: 4),
    as: .psql
)
```

**Cause 3: Uncommitted transactions**

```swift
// ❌ Transaction never completes if error isn't thrown properly
try await req.db.transaction { db in
    try await model.save(on: db)
    // If code hangs here, connection is held
}

// ✅ Always ensure transactions complete
try await req.db.transaction { db in
    try await model.save(on: db)
    // Transaction auto-commits on success, rolls back on throw
}
```

---

## Memory Leaks with EventLoop

### Problem: Retain cycles with closures

```swift
// ❌ Potential retain cycle
class MyService {
    var handler: ((Request) async throws -> Response)?

    func setup(app: Application) {
        handler = { [self] req in  // self retained by closure
            return try await self.process(req)
        }
    }
}

// ✅ Use weak self
class MyService {
    var handler: ((Request) async throws -> Response)?

    func setup(app: Application) {
        handler = { [weak self] req in
            guard let self else { throw Abort(.internalServerError) }
            return try await self.process(req)
        }
    }
}
```

### Problem: Storing Request or EventLoop references

```swift
// ❌ Never store Request — it's tied to the request lifecycle
class BadCache {
    var lastRequest: Request?  // MEMORY LEAK
}

// ✅ Extract what you need
class GoodCache: @unchecked Sendable {
    private let lock = NIOLock()
    private var data: [String: String] = [:]

    func store(_ key: String, value: String) {
        lock.withLock { data[key] = value }
    }
}
```

### Problem: EventLoopFuture chains not completing

With async/await, this is less common, but if using legacy EventLoopFuture APIs:

```swift
// ❌ Dangling future
func process(req: Request) -> EventLoopFuture<Void> {
    return User.find(id, on: req.db).map { user in
        // If this closure is never called, future chain leaks
    }
}

// ✅ Prefer async/await
func process(req: Request) async throws {
    let user = try await User.find(id, on: req.db)
}
```

---

## Docker Build Failures

### Problem: Build runs out of memory

Swift compilation is memory-intensive, especially with many dependencies.

```dockerfile
# ❌ Default may not have enough memory
FROM swift:5.9-jammy AS build

# ✅ Limit parallel jobs
FROM swift:5.9-jammy AS build
WORKDIR /app
COPY Package.* ./
RUN swift package resolve
COPY . .
# Limit parallel compilation jobs
RUN swift build -c release -j 2
```

Also increase Docker memory limit: `docker build --memory=4g`

### Problem: swift-slim image missing libraries

```dockerfile
# ❌ Missing runtime dependencies
FROM swift:5.9-slim

# ✅ Use ubuntu and copy only the binary
FROM swift:5.9-jammy AS build
WORKDIR /app
COPY . .
RUN swift build -c release --static-swift-stdlib

FROM ubuntu:jammy
RUN apt-get update && apt-get install -y \
    libcurl4 \
    libxml2 \
    tzdata \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/.build/release/App /app
ENTRYPOINT ["/app"]
```

### Problem: Package resolution fails in Docker

```dockerfile
# ✅ Copy Package files first for better caching
FROM swift:5.9-jammy AS build
WORKDIR /app
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY . .
RUN swift build -c release
```

### Problem: Architecture mismatch (ARM Mac → Linux AMD64)

```bash
# Build for Linux AMD64 explicitly
docker build --platform linux/amd64 -t myapp .
```

### Problem: "No such module" errors in Docker

Ensure all dependencies are in Package.swift and Package.resolved is committed:

```bash
# Regenerate Package.resolved
swift package resolve
git add Package.resolved
git commit -m "Update Package.resolved"
```

---

## Linux vs macOS Differences

### Foundation differences

Some Foundation APIs behave differently or are missing on Linux:

```swift
// ❌ Not available on Linux
import Foundation
let regex = try NSRegularExpression(pattern: "...")  // Works on macOS, crashes on Linux

// ✅ Use Swift Regex (5.7+)
let regex = /pattern/

// ❌ DateFormatter locale-dependent
let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd"  // May produce different results

// ✅ Use ISO8601DateFormatter or explicit locale
let formatter = ISO8601DateFormatter()
// Or:
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
```

### File paths

```swift
// ❌ Hardcoded macOS paths
let path = "/Users/me/data.json"

// ✅ Use relative paths or environment variables
let path = app.directory.workingDirectory + "data.json"
// Or
let path = Environment.get("DATA_PATH") ?? "./data.json"
```

### Case sensitivity

macOS filesystems are case-insensitive by default; Linux is case-sensitive:

```swift
// This works on macOS but fails on Linux:
// File: Views/Home.leaf
// Code: req.view.render("home")  // ❌ case mismatch on Linux
// Fix: req.view.render("Home")   // ✅ match exact filename
```

### Networking

```swift
// Linux may require explicit TLS configuration
// If you get TLS errors on Linux but not macOS:
app.databases.use(
    .postgres(configuration: .init(
        hostname: "localhost",
        username: "vapor",
        password: "",
        database: "mydb",
        tls: .disable  // Explicitly disable for local dev
    )),
    as: .psql
)
```

---

## Leaf Template Rendering Errors

### Problem: "No custom tag 'tagName'"

```swift
// ❌ Using undefined custom tag
// In template: #myCustomTag(value)

// ✅ Register custom tags
app.leaf.tags["myCustomTag"] = MyCustomTag()
```

### Problem: Template not found

```swift
// Check template location: Resources/Views/
// ❌ Wrong path
try await req.view.render("templates/home")

// ✅ Relative to Resources/Views/
try await req.view.render("home")        // Resources/Views/home.leaf
try await req.view.render("pages/about") // Resources/Views/pages/about.leaf
```

### Problem: Context data not rendering

```swift
// ❌ Dictionary keys don't match template variables
try await req.view.render("user", ["userName": name])
// Template uses: #(name)  — doesn't match!

// ✅ Keys must match template variables
try await req.view.render("user", ["name": name])

// ✅ Better: use a Codable struct for type safety
struct UserContext: Encodable {
    var name: String
    var email: String
}
try await req.view.render("user", UserContext(name: "Alice", email: "a@b.com"))
```

### Problem: Leaf caching in development

```swift
// Templates not updating? Disable cache in development:
if app.environment == .development {
    app.leaf.cache.isEnabled = false
}
```

---

## WebSocket Disconnections

### Problem: Connections drop after 60 seconds

Many reverse proxies (nginx, load balancers) have idle timeouts.

**Solution: Implement ping/pong keepalive:**

```swift
app.webSocket("ws") { req, ws in
    // Send ping every 30 seconds
    let pingTask = Task {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(30))
            try await ws.send(raw: Data(), opcode: .ping)
        }
    }

    ws.onClose.whenComplete { _ in
        pingTask.cancel()
    }

    ws.onText { ws, text in
        // Handle messages
    }
}
```

**Nginx config for WebSocket:**

```nginx
location /ws {
    proxy_pass http://localhost:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
```

### Problem: "WebSocket is not connected" errors

```swift
// ✅ Check connection state before sending
ws.onText { ws, text in
    guard !ws.isClosed else { return }
    try await ws.send("Echo: \(text)")
}
```

### Problem: Broadcast to multiple clients

```swift
// Track connected clients
final class WebSocketClients: @unchecked Sendable {
    private let lock = NIOLock()
    private var clients: [UUID: WebSocket] = [:]

    func add(_ id: UUID, _ ws: WebSocket) {
        lock.withLock { clients[id] = ws }
    }

    func remove(_ id: UUID) {
        lock.withLock { clients.removeValue(forKey: id) }
    }

    func broadcast(_ message: String) {
        lock.withLock {
            for (id, ws) in clients {
                guard !ws.isClosed else {
                    clients.removeValue(forKey: id)
                    continue
                }
                ws.send(message)
            }
        }
    }
}
```

---

## JWT Verification Failures

### Problem: "JWTError.claimVerificationFailure: exp is expired"

Token has expired. Check clock synchronization between services.

```swift
// Generate tokens with reasonable expiry
let payload = UserPayload(
    sub: .init(value: user.id!.uuidString),
    exp: .init(value: Date().addingTimeInterval(3600))  // 1 hour
)

// Allow clock skew tolerance (not built-in, handle manually)
struct UserPayload: JWTPayload {
    var exp: ExpirationClaim

    func verify(using signer: JWTSigner) throws {
        // ExpirationClaim.verify allows no tolerance by default
        try exp.verifyNotExpired()
    }
}
```

### Problem: "JWTError.signerNotFound"

Signer not configured or wrong algorithm.

```swift
// ✅ Ensure signer is configured before any JWT operations
func configure(_ app: Application) async throws {
    // Must be set before routes that use JWT
    let secret = Environment.get("JWT_SECRET") ?? "dev-secret-change-me"
    app.jwt.signers.use(.hs256(key: secret))

    // For RS256 (asymmetric)
    let rsaKey = try RSAKey.public(pem: publicKeyPEM)
    app.jwt.signers.use(.rs256(key: rsaKey))
}
```

### Problem: JWT from external provider won't verify

```swift
// Configure JWKS for external providers (Auth0, Firebase, etc.)
// The key set must match the provider's signing algorithm
let jwksURL = "https://YOUR_DOMAIN/.well-known/jwks.json"
try await app.jwt.signers.use(jwksURI: jwksURL)
```

### Problem: "JWTError.malformedToken"

Token format is incorrect. Ensure it has three base64url-encoded parts separated by dots.

```swift
// ✅ Debug by inspecting token parts
func debugJWT(req: Request) throws {
    guard let bearer = req.headers.bearerAuthorization else {
        throw Abort(.unauthorized, reason: "No bearer token")
    }
    let parts = bearer.token.split(separator: ".")
    req.logger.info("JWT parts: \(parts.count)")  // Should be 3
    // Decode header and payload (they're base64url encoded)
}
```

---

## Common Runtime Errors

### "Abort.500: Internal Server Error" with no details

Enable detailed error reporting in development:

```swift
if app.environment != .production {
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
}
```

### "DecodingError: key not found"

Request body missing required fields:

```swift
// ✅ Use Validatable for clear error messages
struct CreateUserDTO: Content, Validatable {
    var name: String
    var email: String

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty)
        validations.add("email", as: String.self, is: .email)
    }
}

// In route handler, validate before decoding
try CreateUserDTO.validate(content: req)
let dto = try req.content.decode(CreateUserDTO.self)
```

### "Fluent: model not found" on `.find()`

```swift
// ✅ Always handle nil from .find()
guard let user = try await User.find(id, on: req.db) else {
    throw Abort(.notFound, reason: "User not found")
}
```

### Port already in use

```bash
# Find and kill the process using port 8080
lsof -i :8080
kill -9 <PID>

# Or use a different port
swift run App serve --port 8081
```

---

## Debugging Techniques

### Enable verbose logging

```swift
app.logger.logLevel = .debug

// Or per-request
req.logger.debug("Processing user: \(userID)")
```

### Print raw SQL queries

```swift
// In configure.swift
app.databases.use(.postgres(configuration: config), as: .psql, isDefault: true)
app.logger.logLevel = .debug  // Shows SQL queries
```

### Use Xcode debugger with Vapor

1. Open Package.swift in Xcode
2. Select the `App` scheme
3. Set environment variables in scheme settings
4. Set breakpoints and run

### Inspect request/response in middleware

```swift
struct DebugMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        request.logger.info("→ \(request.method) \(request.url)")
        request.logger.debug("Headers: \(request.headers)")
        if let body = request.body.string {
            request.logger.debug("Body: \(body)")
        }

        let response = try await next.respond(to: request)

        request.logger.info("← \(response.status)")
        return response
    }
}

// Register only in development
if app.environment == .development {
    app.middleware.use(DebugMiddleware())
}
```

### Memory profiling

```bash
# On Linux
swift build -c release
valgrind --tool=massif .build/release/App serve

# On macOS
# Use Instruments > Leaks / Allocations
```
