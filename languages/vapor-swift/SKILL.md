---
name: vapor-swift
description: >
  Expert guidance for Vapor 4.x, the Swift server-side web framework built on SwiftNIO.
  Covers routing, Fluent ORM (models, migrations, relations, query builder), authentication
  (sessions, JWT, tokens), middleware, Content/Codable encoding, validation, WebSockets,
  Leaf templating, Redis-backed queues, testing with XCTVapor, Swift Package Manager
  project structure, async/await concurrency, Sendable conformance, error handling,
  and deployment (Docker, Linux, cloud). Activate for Vapor, server-side Swift, Fluent ORM,
  Swift web API, or Swift backend development. Do NOT activate for iOS, SwiftUI, Kitura,
  Perfect, or non-Swift web frameworks.
---

# Vapor 4.x — Server-Side Swift

## Project Structure & Setup

Use Swift Package Manager. Standard layout:
```
Sources/App/
  configure.swift    — register services, middleware, databases, migrations, routes
  entrypoint.swift   — @main struct, Environment.detect(), app.run()
  routes.swift       — register HTTP endpoints
  Controllers/       — route handler logic grouped by domain
  Models/            — Fluent models
  Migrations/        — database schema changes
  DTOs/              — request/response transfer objects
Public/              — static files served by FileMiddleware
Tests/AppTests/      — XCTVapor test cases
```

### Package.swift
```swift
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
    ],
    targets: [
        .executableTarget(name: "App", dependencies: [
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
        ]),
        .testTarget(name: "AppTests", dependencies: [
            .targetItem(name: "App", condition: nil),
            .product(name: "XCTVapor", package: "vapor"),
        ]),
    ]
)
```

### Entrypoint
```swift
import Vapor
@main struct Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        defer { app.shutdown() }
        try await configure(app)
        try await app.execute()
    }
}
```

### configure.swift
```swift
func configure(_ app: Application) async throws {
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.databases.use(
        .postgres(configuration: .init(
            hostname: Environment.get("DB_HOST") ?? "localhost",
            username: Environment.get("DB_USER") ?? "vapor",
            password: Environment.get("DB_PASS") ?? "",
            database: Environment.get("DB_NAME") ?? "vapor_db",
            tls: .disable
        )), as: .psql
    )
    app.migrations.add(CreateUser())
    try await app.autoMigrate()
    try routes(app)
}
```

## Routing

### Basic Routes
```swift
func routes(_ app: Application) throws {
    app.get("health") { _ in ["status": "ok"] }

    app.get("users", ":userID") { req async throws -> User in
        guard let user = try await User.find(req.parameters.get("userID"), on: req.db) else {
            throw Abort(.notFound)
        }
        return user
    }

    app.post("users") { req async throws -> User in
        try CreateUserDTO.validate(content: req)
        let dto = try req.content.decode(CreateUserDTO.self)
        let user = User(name: dto.name, email: dto.email)
        try await user.save(on: req.db)
        return user
    }
}
```

### Route Groups & Controllers
```swift
// Group by path prefix + middleware
let api = app.grouped("api", "v1")
let protected = api.grouped(UserToken.authenticator(), User.guardMiddleware())
try protected.register(collection: TodoController())

// Controller pattern
struct TodoController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let todos = routes.grouped("todos")
        todos.get(use: index)
        todos.post(use: create)
        todos.group(":todoID") { todo in
            todo.get(use: show)
            todo.put(use: update)
            todo.delete(use: delete)
        }
    }
    func index(req: Request) async throws -> [Todo] {
        try await Todo.query(on: req.db).all()
    }
}
```

Use path parameters with `req.parameters.get("name")`. Return any `Content`-conforming type directly.

## Fluent ORM

### Models
```swift
final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"
    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "email") var email: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Children(for: \.$user) var posts: [Post]
    @OptionalField(key: "bio") var bio: String?
    init() {}
    init(id: UUID? = nil, name: String, email: String) {
        self.id = id; self.name = name; self.email = email
    }
}
```

Property wrappers: `@ID`, `@Field`, `@OptionalField`, `@Enum`, `@Boolean`, `@Timestamp`, `@Parent`, `@OptionalParent`, `@Children`, `@OptionalChild`, `@Siblings`.

### Migrations
```swift
struct CreateUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .id()
            .field("name", .string, .required)
            .field("email", .string, .required)
            .field("bio", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "email")
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.schema("users").delete()
    }
}
```

Always implement `revert`. Add migrations in order in `configure.swift`. Use `.references("table", "id")` for foreign keys.

### Relations
```swift
// Parent-Child (one-to-many)
final class Post: Model, Content, @unchecked Sendable {
    static let schema = "posts"
    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "title") var title: String
    @Siblings(through: PostTagPivot.self, from: \.$post, to: \.$tag) var tags: [Tag]
}

// Many-to-many pivot
final class PostTagPivot: Model, @unchecked Sendable {
    static let schema = "post_tag_pivot"
    @ID(key: .id) var id: UUID?
    @Parent(key: "post_id") var post: Post
    @Parent(key: "tag_id") var tag: Tag
    init() {}
}
```

### Query Builder
```swift
// Filtering
let users = try await User.query(on: req.db)
    .filter(\.$email == "test@example.com")
    .sort(\.$name)
    .limit(10)
    .all()

// Eager loading
let usersWithPosts = try await User.query(on: req.db)
    .with(\.$posts) { $0.with(\.$tags) }
    .all()

// Aggregates
let count = try await User.query(on: req.db).count()

// Join
let posts = try await Post.query(on: req.db)
    .join(User.self, on: \Post.$user.$id == \User.$id)
    .filter(User.self, \.$name == "Alice")
    .all()

// Pagination
let page = try await User.query(on: req.db).paginate(for: req)

// Attach/detach siblings
try await post.$tags.attach(tag, on: req.db)
try await post.$tags.detach(tag, on: req.db)
```

## Content & Validation

### DTOs (Decouple API from Models)
```swift
struct CreateUserDTO: Content, Validatable {
    var name: String
    var email: String
    var password: String

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty && .count(2...100))
        validations.add("email", as: String.self, is: .email)
        validations.add("password", as: String.self, is: .count(8...))
    }
}
```

Validate before decoding: `try CreateUserDTO.validate(content: req)`. Vapor reports all validation failures at once.

### Custom Content Configuration
```swift
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.keyEncodingStrategy = .convertToSnakeCase
ContentConfiguration.global.use(encoder: encoder, for: .json)
```

Supported formats: JSON, URL-encoded form, multipart, plaintext. Use `req.content.decode()` for all.

## Authentication

### Password (Basic Auth)
```swift
extension User: ModelAuthenticatable {
    static let usernameKey = \User.$email
    static let passwordHashKey = \User.$passwordHash
    func verify(password: String) throws -> Bool {
        try Bcrypt.verify(password, created: self.passwordHash)
    }
}
// In routes:
let basic = app.grouped(User.authenticator())
basic.post("login") { req async throws -> UserToken in
    let user = try req.auth.require(User.self)
    let token = try user.generateToken()
    try await token.save(on: req.db)
    return token
}
```

### Token (Bearer Auth)
```swift
final class UserToken: Model, Content, @unchecked Sendable {
    static let schema = "user_tokens"
    @ID(key: .id) var id: UUID?
    @Field(key: "value") var value: String
    @Parent(key: "user_id") var user: User
    @Timestamp(key: "expires_at", on: .none) var expiresAt: Date?
}
extension UserToken: ModelTokenAuthenticatable {
    static let valueKey = \UserToken.$value
    static let userKey = \UserToken.$user
    var isValid: Bool { expiresAt == nil || expiresAt! > Date() }
}
// Protected routes:
let protected = app.grouped(UserToken.authenticator(), User.guardMiddleware())
```

### JWT
Add `vapor/jwt` dependency. Configure signing key in `configure.swift`:
```swift
app.jwt.signers.use(.hs256(key: Environment.get("JWT_SECRET")!))
```
Define payload:
```swift
struct UserPayload: JWTPayload, Authenticatable {
    var sub: SubjectClaim
    var exp: ExpirationClaim
    func verify(using signer: JWTSigner) throws { try exp.verifyNotExpired() }
}
```

### Sessions
```swift
app.sessions.use(.fluent)  // or .memory
app.middleware.use(app.sessions.middleware)
app.middleware.use(User.sessionAuthenticator())
```

## Middleware

```swift
struct CORSConfigured: Middleware {
    func respond(to request: Request, chainingTo next: Responder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.add(name: .accessControlAllowOrigin, value: "*")
        return response
    }
}
// Register globally or per-group
app.middleware.use(CORSConfigured())
// Built-in: CORSMiddleware, FileMiddleware, ErrorMiddleware
```

Middleware execution order matters. Global middleware runs on every request. Group middleware scopes to specific routes.

## Error Handling

```swift
// Throw Abort for HTTP errors
throw Abort(.notFound, reason: "User not found")
throw Abort(.badRequest, reason: "Invalid input")

// Custom error middleware
struct CustomErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let abort as Abort {
            let body = ErrorResponse(error: true, reason: abort.reason)
            let response = Response(status: abort.status)
            try response.content.encode(body)
            return response
        }
    }
}
struct ErrorResponse: Content { var error: Bool; var reason: String }
```

## WebSockets

```swift
app.webSocket("chat") { req, ws in
    ws.onText { ws, text in
        ws.send("Echo: \(text)")
    }
    ws.onClose.whenComplete { _ in
        print("Client disconnected")
    }
}
```

## Leaf Templating

Add `vapor/leaf` dependency.
```swift
app.views.use(.leaf)
// In route:
app.get("home") { req async throws -> View in
    try await req.view.render("home", ["title": "Welcome"])
}
```
Templates in `Resources/Views/home.leaf`:
```html
<h1>#(title)</h1>
#for(item in items): <li>#(item.name)</li> #endfor
#if(user): <p>Hello #(user.name)</p> #endif
```

## Queues (Background Jobs)

Add `vapor/queues` and `vapor/queues-redis-driver`.
```swift
app.queues.use(.redis(url: Environment.get("REDIS_URL") ?? "redis://127.0.0.1:6379"))

struct EmailJob: AsyncJob {
    typealias Payload = EmailPayload
    func dequeue(_ context: QueueContext, _ payload: EmailPayload) async throws {
        // Send email
    }
    func error(_ context: QueueContext, _ error: Error, _ payload: EmailPayload) async throws {
        context.logger.error("Email job failed: \(error)")
    }
}
struct EmailPayload: Codable { var to: String; var subject: String; var body: String }

// Register and dispatch
app.queues.add(EmailJob())
try await req.queue.dispatch(EmailJob.self, EmailPayload(to: "a@b.com", subject: "Hi", body: "Hello"))
```
Run worker: `swift run App queues`. Use `--scheduled` for scheduled jobs.

## Testing

```swift
import XCTVapor
final class UserTests: XCTestCase {
    var app: Application!
    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        try await app.autoMigrate()
    }
    override func tearDown() async throws {
        try await app.autoRevert()
        try await app.asyncShutdown()
    }
    func testCreateUser() async throws {
        try await app.test(.POST, "users", beforeRequest: { req in
            try req.content.encode(CreateUserDTO(name: "Test", email: "t@t.com", password: "12345678"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let user = try res.content.decode(User.self)
            XCTAssertEqual(user.name, "Test")
        })
    }
}
```

Use `.testing` environment with a separate test database. `app.test()` supports `.GET`, `.POST`, `.PUT`, `.DELETE`. Use `beforeRequest` to set headers/body, `afterResponse` to assert.

## Deployment

### Docker
```dockerfile
FROM swift:5.9-jammy AS build
WORKDIR /app
COPY . .
RUN swift build -c release --static-swift-stdlib
FROM ubuntu:jammy
COPY --from=build /app/.build/release/App /app
COPY --from=build /app/Public /Public
COPY --from=build /app/Resources /Resources
EXPOSE 8080
ENTRYPOINT ["/app", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
```

### Production Checklist
- Set `--env production` for release logging/config.
- Use environment variables for all secrets and connection strings.
- Enable TLS termination via reverse proxy (nginx, Caddy) or load balancer.
- Run `swift build -c release` with `--static-swift-stdlib` for portable Linux binaries.
- Set `app.http.server.configuration.hostname = "0.0.0.0"` to bind all interfaces.
- Use process managers (systemd, supervisor) or container orchestration.
- Configure health check endpoint for load balancers.

## Concurrency, Sendable & Key Rules

- Prefer `async throws` handlers over EventLoopFuture. Mark models `@unchecked Sendable`.
- Use `Task { }` for fire-and-forget work; use `async let`/`TaskGroup` for parallel ops in handlers.
- Access `req.db`, `req.cache`, `req.queue` only within the request lifecycle. Never store `Request` long-term.
- Use DTOs to decouple API contracts from database models. Validate with `Validatable` before decoding.
- Hash passwords with `Bcrypt.hash()`. Use `@Timestamp(on: .create/.update)` for date tracking.
- Register migrations in dependency order. Eager-load with `.with()` to avoid N+1 queries.
- Use `.paginate(for: req)` for lists. Return HTTP status codes via `Abort`.
- Keep `configure.swift` thin. Use environment-based configuration for all targets.
