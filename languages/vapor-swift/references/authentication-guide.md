# Authentication Deep Dive — Vapor 4.x

## Table of Contents

- [Password Hashing with Bcrypt](#password-hashing-with-bcrypt)
- [Token-Based Authentication](#token-based-authentication)
- [JWT with Custom Claims](#jwt-with-custom-claims)
- [OAuth2 Integration](#oauth2-integration)
- [Session-Based Authentication](#session-based-authentication)
- [Middleware Chaining](#middleware-chaining)
- [Role-Based Access Control](#role-based-access-control)
- [API Key Authentication](#api-key-authentication)
- [Two-Factor Authentication Patterns](#two-factor-authentication-patterns)
- [Security Best Practices](#security-best-practices)

---

## Password Hashing with Bcrypt

Vapor includes Bcrypt out of the box. Never store plaintext passwords.

### User Model with Password Hash

```swift
final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "email") var email: String
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "name") var name: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(name: String, email: String, password: String) throws {
        self.name = name
        self.email = email
        self.passwordHash = try Bcrypt.hash(password)
    }
}
```

### Registration Endpoint

```swift
struct RegisterDTO: Content, Validatable {
    var name: String
    var email: String
    var password: String
    var confirmPassword: String

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty && .count(2...100))
        validations.add("email", as: String.self, is: .email)
        validations.add("password", as: String.self, is: .count(8...72))
        // Bcrypt has a 72-byte limit
    }
}

app.post("register") { req async throws -> User.Public in
    try RegisterDTO.validate(content: req)
    let dto = try req.content.decode(RegisterDTO.self)

    guard dto.password == dto.confirmPassword else {
        throw Abort(.badRequest, reason: "Passwords do not match")
    }

    // Check for existing user
    let existing = try await User.query(on: req.db)
        .filter(\.$email == dto.email.lowercased())
        .first()
    guard existing == nil else {
        throw Abort(.conflict, reason: "Email already registered")
    }

    let user = try User(name: dto.name, email: dto.email.lowercased(), password: dto.password)
    try await user.save(on: req.db)
    return user.asPublic()
}
```

### Public Response DTO

```swift
extension User {
    struct Public: Content {
        var id: UUID?
        var name: String
        var email: String
        var createdAt: Date?
    }

    func asPublic() -> Public {
        Public(id: id, name: name, email: email, createdAt: createdAt)
    }
}
```

### ModelAuthenticatable Conformance

```swift
extension User: ModelAuthenticatable {
    static let usernameKey = \User.$email
    static let passwordHashKey = \User.$passwordHash

    func verify(password: String) throws -> Bool {
        try Bcrypt.verify(password, created: self.passwordHash)
    }
}
```

### Cost Factor Tuning

```swift
// Default cost is 12 (4096 iterations). Increase for security, decrease for speed.
let hash = try Bcrypt.hash("password", cost: 12)

// Timing: cost 10 ≈ 65ms, cost 12 ≈ 250ms, cost 14 ≈ 1s
// Never go below 10 in production
```

---

## Token-Based Authentication

Bearer token auth is ideal for API clients. Tokens are stored in the database and validated on each request.

### Token Model

```swift
final class UserToken: Model, Content, @unchecked Sendable {
    static let schema = "user_tokens"

    @ID(key: .id) var id: UUID?
    @Field(key: "value") var value: String
    @Parent(key: "user_id") var user: User
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Field(key: "expires_at") var expiresAt: Date

    init() {}

    init(userID: User.IDValue, expiresIn: TimeInterval = 86400) throws {
        self.$user.id = userID
        // Generate cryptographically secure random token
        self.value = [UInt8].random(count: 32).base64
        self.expiresAt = Date().addingTimeInterval(expiresIn)
    }
}
```

### Token Migration

```swift
struct CreateUserToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("user_tokens")
            .id()
            .field("value", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .field("expires_at", .datetime, .required)
            .unique(on: "value")
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.schema("user_tokens").delete()
    }
}
```

### ModelTokenAuthenticatable

```swift
extension UserToken: ModelTokenAuthenticatable {
    static let valueKey = \UserToken.$value
    static let userKey = \UserToken.$user

    var isValid: Bool {
        expiresAt > Date()
    }
}
```

### Login Endpoint

```swift
struct LoginDTO: Content {
    var email: String
    var password: String
}

struct LoginResponse: Content {
    var token: String
    var expiresAt: Date
    var user: User.Public
}

// Using Basic Auth authenticator
let basicAuth = app.grouped(User.authenticator())
basicAuth.post("login") { req async throws -> LoginResponse in
    let user = try req.auth.require(User.self)

    // Revoke existing tokens (optional: single-session)
    try await UserToken.query(on: req.db)
        .filter(\.$user.$id == user.id!)
        .delete()

    let token = try UserToken(userID: user.id!)
    try await token.save(on: req.db)

    return LoginResponse(
        token: token.value,
        expiresAt: token.expiresAt,
        user: user.asPublic()
    )
}
```

### Protected Routes

```swift
let protected = app.grouped(
    UserToken.authenticator(),
    User.guardMiddleware()
)

protected.get("me") { req async throws -> User.Public in
    let user = try req.auth.require(User.self)
    return user.asPublic()
}

// Logout
protected.post("logout") { req async throws -> HTTPStatus in
    let user = try req.auth.require(User.self)
    // Delete current token
    if let token = req.headers.bearerAuthorization?.token {
        try await UserToken.query(on: req.db)
            .filter(\.$value == token)
            .delete()
    }
    req.auth.logout(User.self)
    return .noContent
}
```

---

## JWT with Custom Claims

JWT tokens are stateless — no database lookup required for validation.

### Setup

Add `vapor/jwt` to Package.swift:

```swift
.package(url: "https://github.com/vapor/jwt.git", from: "4.2.0"),
// In target dependencies:
.product(name: "JWT", package: "jwt"),
```

### Custom Payload with Claims

```swift
struct UserJWTPayload: JWTPayload, Authenticatable {
    // Standard claims
    var sub: SubjectClaim       // user ID
    var exp: ExpirationClaim    // expiration
    var iat: IssuedAtClaim      // issued at
    var iss: IssuerClaim        // issuer

    // Custom claims
    var email: String
    var role: String
    var permissions: [String]

    func verify(using signer: JWTSigner) throws {
        try exp.verifyNotExpired()
        // Additional verification
        guard iss.value == "my-vapor-app" else {
            throw JWTError.claimVerificationFailure(
                failedClaim: iss,
                reason: "Invalid issuer"
            )
        }
    }
}
```

### Configure Signers

```swift
func configure(_ app: Application) async throws {
    // HS256 (symmetric — same key for sign + verify)
    let secret = Environment.get("JWT_SECRET")!
    app.jwt.signers.use(.hs256(key: secret))

    // RS256 (asymmetric — private key signs, public key verifies)
    let privateKey = try RSAKey.private(pem: Environment.get("JWT_PRIVATE_KEY")!)
    app.jwt.signers.use(.rs256(key: privateKey), kid: "primary")

    // ES256 (ECDSA — smaller keys, faster)
    let ecKey = try ECDSAKey.private(pem: Environment.get("EC_PRIVATE_KEY")!)
    app.jwt.signers.use(.es256(key: ecKey), kid: "ec-primary")
}
```

### Issue JWT Tokens

```swift
app.post("auth", "jwt", "login") { req async throws -> TokenResponse in
    let dto = try req.content.decode(LoginDTO.self)

    guard let user = try await User.query(on: req.db)
        .filter(\.$email == dto.email)
        .first(),
        try user.verify(password: dto.password) else {
        throw Abort(.unauthorized, reason: "Invalid credentials")
    }

    let payload = UserJWTPayload(
        sub: .init(value: user.id!.uuidString),
        exp: .init(value: Date().addingTimeInterval(3600)),  // 1 hour
        iat: .init(value: Date()),
        iss: .init(value: "my-vapor-app"),
        email: user.email,
        role: user.role.rawValue,
        permissions: user.permissions
    )

    let token = try req.jwt.sign(payload)
    return TokenResponse(accessToken: token, expiresIn: 3600)
}

struct TokenResponse: Content {
    var accessToken: String
    var expiresIn: Int
}
```

### Verify JWT in Routes

```swift
// Using JWTPayload as authenticator
let jwtProtected = app.grouped(UserJWTPayload.authenticator())

jwtProtected.get("profile") { req async throws -> User.Public in
    let payload = try req.auth.require(UserJWTPayload.self)
    guard let user = try await User.find(UUID(payload.sub.value), on: req.db) else {
        throw Abort(.notFound)
    }
    return user.asPublic()
}
```

### Refresh Tokens

```swift
struct RefreshTokenPayload: JWTPayload {
    var sub: SubjectClaim
    var exp: ExpirationClaim
    var type: String  // "refresh"

    func verify(using signer: JWTSigner) throws {
        try exp.verifyNotExpired()
        guard type == "refresh" else {
            throw Abort(.unauthorized, reason: "Not a refresh token")
        }
    }
}

app.post("auth", "refresh") { req async throws -> TokenResponse in
    let refreshToken = try req.content.decode(RefreshRequest.self)
    let payload = try req.jwt.verify(refreshToken.token, as: RefreshTokenPayload.self)

    guard let user = try await User.find(UUID(payload.sub.value), on: req.db) else {
        throw Abort(.notFound)
    }

    // Issue new access token
    let newPayload = UserJWTPayload(
        sub: .init(value: user.id!.uuidString),
        exp: .init(value: Date().addingTimeInterval(3600)),
        iat: .init(value: Date()),
        iss: .init(value: "my-vapor-app"),
        email: user.email,
        role: user.role.rawValue,
        permissions: user.permissions
    )

    return TokenResponse(
        accessToken: try req.jwt.sign(newPayload),
        expiresIn: 3600
    )
}
```

---

## OAuth2 Integration

### GitHub OAuth2 Example

```swift
// Step 1: Redirect to GitHub
app.get("oauth", "github") { req -> Response in
    let clientID = Environment.get("GITHUB_CLIENT_ID")!
    let callbackURL = Environment.get("GITHUB_CALLBACK_URL")!
    let state = [UInt8].random(count: 16).base64

    // Store state in session for CSRF protection
    req.session.data["oauth_state"] = state

    let url = "https://github.com/login/oauth/authorize?client_id=\(clientID)&redirect_uri=\(callbackURL)&state=\(state)&scope=user:email"
    return req.redirect(to: url)
}

// Step 2: Handle callback
app.get("oauth", "github", "callback") { req async throws -> LoginResponse in
    let code = try req.query.get(String.self, at: "code")
    let state = try req.query.get(String.self, at: "state")

    // Verify state matches
    guard req.session.data["oauth_state"] == state else {
        throw Abort(.forbidden, reason: "Invalid OAuth state")
    }
    req.session.data["oauth_state"] = nil

    // Exchange code for access token
    let tokenResponse = try await req.client.post("https://github.com/login/oauth/access_token") { tokenReq in
        try tokenReq.content.encode(GitHubTokenRequest(
            clientID: Environment.get("GITHUB_CLIENT_ID")!,
            clientSecret: Environment.get("GITHUB_CLIENT_SECRET")!,
            code: code
        ))
        tokenReq.headers.add(name: .accept, value: "application/json")
    }

    let ghToken = try tokenResponse.content.decode(GitHubTokenResponse.self)

    // Fetch user info from GitHub
    let userResponse = try await req.client.get("https://api.github.com/user") { userReq in
        userReq.headers.bearerAuthorization = .init(token: ghToken.accessToken)
    }

    let ghUser = try userResponse.content.decode(GitHubUser.self)

    // Find or create local user
    let user: User
    if let existing = try await User.query(on: req.db)
        .filter(\.$githubID == ghUser.id)
        .first() {
        user = existing
    } else {
        user = User(name: ghUser.name ?? ghUser.login, email: ghUser.email ?? "", githubID: ghUser.id)
        try await user.save(on: req.db)
    }

    // Issue our app's token
    let token = try UserToken(userID: user.id!)
    try await token.save(on: req.db)
    return LoginResponse(token: token.value, expiresAt: token.expiresAt, user: user.asPublic())
}

// DTOs
struct GitHubTokenRequest: Content {
    var clientID: String
    var clientSecret: String
    var code: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case code
    }
}

struct GitHubTokenResponse: Content {
    var accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

struct GitHubUser: Content {
    var id: Int
    var login: String
    var name: String?
    var email: String?
}
```

### Generic OAuth2 Helper

```swift
struct OAuth2Config {
    var authorizeURL: String
    var tokenURL: String
    var clientID: String
    var clientSecret: String
    var callbackURL: String
    var scopes: [String]
}

struct OAuth2Helper {
    let config: OAuth2Config

    func authorizeURL(state: String) -> String {
        let scopes = config.scopes.joined(separator: " ")
        return "\(config.authorizeURL)?client_id=\(config.clientID)&redirect_uri=\(config.callbackURL)&state=\(state)&scope=\(scopes)&response_type=code"
    }

    func exchangeCode(_ code: String, client: Client) async throws -> String {
        let response = try await client.post(URI(string: config.tokenURL)) { req in
            try req.content.encode([
                "client_id": config.clientID,
                "client_secret": config.clientSecret,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": config.callbackURL,
            ])
            req.headers.add(name: .accept, value: "application/json")
        }
        let tokenData = try response.content.decode(OAuth2TokenResponse.self)
        return tokenData.accessToken
    }
}

struct OAuth2TokenResponse: Content {
    var accessToken: String
    var tokenType: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
    }
}
```

---

## Session-Based Authentication

Best for server-rendered web apps with Leaf templates.

### Setup

```swift
func configure(_ app: Application) async throws {
    // Use Fluent-backed sessions (persistent across restarts)
    app.sessions.use(.fluent)
    app.middleware.use(app.sessions.middleware)

    // Add session migration
    app.migrations.add(SessionRecord.migration)
}
```

### ModelSessionAuthenticatable

```swift
extension User: ModelSessionAuthenticatable {}
// Uses the model's ID to store/retrieve from session
```

### Login / Logout with Sessions

```swift
// Login form (GET)
app.get("login") { req async throws -> View in
    try await req.view.render("login")
}

// Login handler (POST)
app.grouped(User.credentialsAuthenticator())
    .post("login") { req async throws -> Response in
    let user = try req.auth.require(User.self)
    req.auth.login(user)  // Stores user ID in session
    return req.redirect(to: "/dashboard")
}

// Logout
app.post("logout") { req -> Response in
    req.auth.logout(User.self)
    req.session.destroy()
    return req.redirect(to: "/login")
}

// Protected page
let sessionProtected = app.grouped(
    User.sessionAuthenticator(),
    User.guardMiddleware()
)

sessionProtected.get("dashboard") { req async throws -> View in
    let user = try req.auth.require(User.self)
    try await req.view.render("dashboard", ["user": user.asPublic()])
}
```

### Credentials Authenticator

For form-based login (POST with email/password in body):

```swift
extension User: ModelCredentialsAuthenticatable {
    static let usernameKey = \User.$email
    static let passwordHashKey = \User.$passwordHash

    func verify(password: String) throws -> Bool {
        try Bcrypt.verify(password, created: self.passwordHash)
    }
}
```

### Session Configuration

```swift
// Cookie configuration
app.sessions.configuration.cookieName = "my-app-session"
app.sessions.configuration.cookieFactory = { sessionID in
    HTTPCookies.Value(
        string: sessionID.string,
        expires: Date().addingTimeInterval(86400 * 7),  // 7 days
        maxAge: nil,
        domain: nil,
        path: "/",
        isSecure: true,    // HTTPS only
        isHTTPOnly: true,  // Not accessible from JavaScript
        sameSite: .lax
    )
}
```

---

## Middleware Chaining

### Order Matters

Middleware executes in registration order for requests, and reverse order for responses.

```swift
// Request flow: CORS → Auth → Guard → Route Handler
// Response flow: Route Handler → Guard → Auth → CORS

let api = app.grouped("api")
    .grouped(CORSMiddleware.default())    // 1. Handle CORS
    .grouped(UserJWTPayload.authenticator()) // 2. Try to authenticate
    .grouped(User.guardMiddleware())       // 3. Require authentication

try api.register(collection: UserController())
```

### Combining Multiple Auth Methods

```swift
// Accept either JWT or Bearer token
let flexAuth = app.grouped(
    UserJWTPayload.authenticator(),     // Try JWT first
    UserToken.authenticator(),           // Then try database token
    User.guardMiddleware()               // Require one of them to succeed
)
```

### Conditional Middleware

```swift
struct ConditionalMiddleware: AsyncMiddleware {
    let condition: (Request) -> Bool
    let middleware: AsyncMiddleware

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if condition(request) {
            return try await middleware.respond(to: request, chainingTo: next)
        }
        return try await next.respond(to: request)
    }
}

// Rate limit only non-authenticated requests
let rateLimiter = ConditionalMiddleware(
    condition: { req in req.auth.get(User.self) == nil },
    middleware: RateLimitMiddleware(maxRequests: 60, per: .minute)
)
```

### Per-Route Middleware

```swift
struct TodoController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let todos = routes.grouped("todos")

        // Public: list todos
        todos.get(use: index)

        // Protected: create/update/delete
        let protected = todos.grouped(User.guardMiddleware())
        protected.post(use: create)
        protected.group(":todoID") { todo in
            todo.put(use: update)
            todo.delete(use: delete)
        }
    }
}
```

---

## Role-Based Access Control

### Role Enum

```swift
enum UserRole: String, Codable, CaseIterable, Comparable {
    case viewer
    case editor
    case admin
    case superAdmin = "super_admin"

    // Comparable for permission levels
    private var level: Int {
        switch self {
        case .viewer: return 0
        case .editor: return 1
        case .admin: return 2
        case .superAdmin: return 3
        }
    }

    static func < (lhs: UserRole, rhs: UserRole) -> Bool {
        lhs.level < rhs.level
    }
}
```

### Role Guard Middleware

```swift
struct RoleMiddleware: AsyncMiddleware {
    let minimumRole: UserRole

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let user = request.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard user.role >= minimumRole else {
            throw Abort(.forbidden, reason: "Insufficient permissions. Required: \(minimumRole)")
        }
        return try await next.respond(to: request)
    }
}

// Usage
let adminRoutes = app.grouped(
    UserToken.authenticator(),
    User.guardMiddleware(),
    RoleMiddleware(minimumRole: .admin)
)

adminRoutes.get("admin", "users") { req async throws -> [User.Public] in
    try await User.query(on: req.db).all().map { $0.asPublic() }
}
```

### Permission-Based Access

```swift
struct Permission: OptionSet, Codable, Sendable {
    let rawValue: Int

    static let read    = Permission(rawValue: 1 << 0)
    static let write   = Permission(rawValue: 1 << 1)
    static let delete  = Permission(rawValue: 1 << 2)
    static let manage  = Permission(rawValue: 1 << 3)

    static let editor: Permission = [.read, .write]
    static let admin: Permission  = [.read, .write, .delete, .manage]
}

struct PermissionMiddleware: AsyncMiddleware {
    let required: Permission

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let user = request.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard user.permissions.contains(required) else {
            throw Abort(.forbidden)
        }
        return try await next.respond(to: request)
    }
}

// Usage
let writeRoutes = app.grouped(
    UserToken.authenticator(),
    User.guardMiddleware(),
    PermissionMiddleware(required: .write)
)
```

### Resource-Level Authorization

```swift
// Check ownership — not just role
func updatePost(req: Request) async throws -> Post {
    let user = try req.auth.require(User.self)
    guard let post = try await Post.find(req.parameters.get("postID"), on: req.db) else {
        throw Abort(.notFound)
    }

    // Allow if owner OR admin
    guard post.$user.id == user.id || user.role >= .admin else {
        throw Abort(.forbidden, reason: "You can only edit your own posts")
    }

    let dto = try req.content.decode(UpdatePostDTO.self)
    post.title = dto.title
    post.body = dto.body
    try await post.save(on: req.db)
    return post
}
```

---

## API Key Authentication

For service-to-service or third-party API access.

### API Key Model

```swift
final class APIKey: Model, @unchecked Sendable {
    static let schema = "api_keys"

    @ID(key: .id) var id: UUID?
    @Field(key: "key") var key: String
    @Field(key: "name") var name: String            // Description of key usage
    @Parent(key: "user_id") var user: User
    @Field(key: "permissions") var permissions: [String]
    @Field(key: "is_active") var isActive: Bool
    @Field(key: "rate_limit") var rateLimit: Int     // Requests per hour
    @Timestamp(key: "last_used_at", on: .none) var lastUsedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    static func generate(for userID: UUID, name: String, permissions: [String]) throws -> APIKey {
        let key = APIKey()
        key.$user.id = userID
        key.name = name
        key.permissions = permissions
        key.isActive = true
        key.rateLimit = 1000
        // Generate a prefixed key for easy identification
        key.key = "vpr_" + [UInt8].random(count: 32).base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return key
    }
}
```

### API Key Authenticator

```swift
struct APIKeyAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard bearer.token.hasPrefix("vpr_") else { return }

        guard let apiKey = try await APIKey.query(on: request.db)
            .filter(\.$key == bearer.token)
            .filter(\.$isActive == true)
            .with(\.$user)
            .first() else {
            return
        }

        // Update last used
        apiKey.lastUsedAt = Date()
        try await apiKey.save(on: request.db)

        // Login the associated user
        request.auth.login(apiKey.user)

        // Store API key info for permission checks
        request.storage[APIKeyStorageKey.self] = apiKey
    }
}

struct APIKeyStorageKey: StorageKey {
    typealias Value = APIKey
}

// Usage
let apiKeyProtected = app.grouped(
    APIKeyAuthenticator(),
    User.guardMiddleware()
)
```

### API Key Management Endpoints

```swift
// Create API key (authenticated users only)
protected.post("api-keys") { req async throws -> APIKeyResponse in
    let user = try req.auth.require(User.self)
    let dto = try req.content.decode(CreateAPIKeyDTO.self)

    let apiKey = try APIKey.generate(
        for: user.id!,
        name: dto.name,
        permissions: dto.permissions
    )
    try await apiKey.save(on: req.db)

    // Return the key only once — it won't be shown again
    return APIKeyResponse(
        id: apiKey.id!,
        key: apiKey.key,    // Only returned on creation
        name: apiKey.name,
        permissions: apiKey.permissions,
        rateLimit: apiKey.rateLimit
    )
}

// List API keys (masked)
protected.get("api-keys") { req async throws -> [APIKeySummary] in
    let user = try req.auth.require(User.self)
    let keys = try await APIKey.query(on: req.db)
        .filter(\.$user.$id == user.id!)
        .all()
    return keys.map { key in
        APIKeySummary(
            id: key.id!,
            name: key.name,
            keyPrefix: String(key.key.prefix(8)) + "...",
            isActive: key.isActive,
            lastUsedAt: key.lastUsedAt
        )
    }
}

// Revoke API key
protected.delete("api-keys", ":keyID") { req async throws -> HTTPStatus in
    let user = try req.auth.require(User.self)
    guard let keyID = req.parameters.get("keyID", as: UUID.self),
          let apiKey = try await APIKey.find(keyID, on: req.db),
          apiKey.$user.id == user.id! else {
        throw Abort(.notFound)
    }
    apiKey.isActive = false
    try await apiKey.save(on: req.db)
    return .noContent
}
```

---

## Two-Factor Authentication Patterns

### TOTP (Time-Based One-Time Password)

Use a TOTP library compatible with Google Authenticator / Authy.

```swift
// Add a TOTP package to Package.swift (e.g., a Swift OTP library)
// Store the shared secret on the user model

final class User: Model, Content, @unchecked Sendable {
    // ... existing fields ...
    @OptionalField(key: "totp_secret") var totpSecret: String?
    @Field(key: "is_2fa_enabled") var is2FAEnabled: Bool
}
```

### 2FA Setup Flow

```swift
// Step 1: Generate secret and return QR code URI
protected.post("2fa", "setup") { req async throws -> TwoFactorSetup in
    let user = try req.auth.require(User.self)

    // Generate a random secret
    let secret = [UInt8].random(count: 20).base64
    user.totpSecret = secret
    try await user.save(on: req.db)

    // Return otpauth:// URI for QR code generation
    let otpURL = "otpauth://totp/MyApp:\(user.email)?secret=\(secret)&issuer=MyApp&digits=6&period=30"

    return TwoFactorSetup(secret: secret, otpauthURL: otpURL)
}

struct TwoFactorSetup: Content {
    var secret: String
    var otpauthURL: String
}

// Step 2: Verify and enable 2FA
protected.post("2fa", "verify") { req async throws -> HTTPStatus in
    let user = try req.auth.require(User.self)
    let dto = try req.content.decode(VerifyTOTPDTO.self)

    guard let secret = user.totpSecret else {
        throw Abort(.badRequest, reason: "2FA not set up")
    }

    // Verify the TOTP code
    guard verifyTOTP(secret: secret, code: dto.code) else {
        throw Abort(.unauthorized, reason: "Invalid 2FA code")
    }

    user.is2FAEnabled = true
    try await user.save(on: req.db)
    return .ok
}

struct VerifyTOTPDTO: Content {
    var code: String
}
```

### 2FA Login Flow

```swift
// Modified login: return partial token if 2FA is required
app.post("login") { req async throws -> LoginStepResponse in
    let dto = try req.content.decode(LoginDTO.self)

    guard let user = try await User.query(on: req.db)
        .filter(\.$email == dto.email)
        .first(),
        try user.verify(password: dto.password) else {
        throw Abort(.unauthorized)
    }

    if user.is2FAEnabled {
        // Issue a temporary token that only allows 2FA verification
        let tempToken = try TempAuthToken(userID: user.id!, purpose: "2fa")
        try await tempToken.save(on: req.db)
        return LoginStepResponse(
            requiresTwoFactor: true,
            tempToken: tempToken.value,
            accessToken: nil
        )
    }

    // No 2FA — issue full access token
    let token = try UserToken(userID: user.id!)
    try await token.save(on: req.db)
    return LoginStepResponse(
        requiresTwoFactor: false,
        tempToken: nil,
        accessToken: token.value
    )
}

// Complete 2FA login
app.post("login", "2fa") { req async throws -> TokenResponse in
    let dto = try req.content.decode(TwoFactorLoginDTO.self)

    // Verify temp token
    guard let tempToken = try await TempAuthToken.query(on: req.db)
        .filter(\.$value == dto.tempToken)
        .filter(\.$purpose == "2fa")
        .with(\.$user)
        .first(),
        tempToken.isValid else {
        throw Abort(.unauthorized, reason: "Invalid or expired 2FA session")
    }

    let user = tempToken.user

    // Verify TOTP code
    guard let secret = user.totpSecret,
          verifyTOTP(secret: secret, code: dto.code) else {
        throw Abort(.unauthorized, reason: "Invalid 2FA code")
    }

    // Delete temp token and issue real token
    try await tempToken.delete(on: req.db)
    let token = try UserToken(userID: user.id!)
    try await token.save(on: req.db)

    return TokenResponse(accessToken: token.value, expiresIn: 86400)
}

struct TwoFactorLoginDTO: Content {
    var tempToken: String
    var code: String
}

struct LoginStepResponse: Content {
    var requiresTwoFactor: Bool
    var tempToken: String?
    var accessToken: String?
}
```

### Backup Codes

```swift
// Generate backup codes during 2FA setup
protected.post("2fa", "backup-codes") { req async throws -> BackupCodesResponse in
    let user = try req.auth.require(User.self)

    let codes = (0..<10).map { _ in
        String(format: "%08d", Int.random(in: 0..<100_000_000))
    }

    // Hash and store backup codes
    let hashedCodes = try codes.map { try Bcrypt.hash($0, cost: 10) }
    user.backupCodes = hashedCodes
    try await user.save(on: req.db)

    // Return plain codes — user must save these
    return BackupCodesResponse(codes: codes)
}

struct BackupCodesResponse: Content {
    var codes: [String]
}
```

---

## Security Best Practices

1. **Always hash passwords** with Bcrypt (cost ≥ 12). Never store plaintext.
2. **Use HTTPS in production** — set `isSecure: true` on session cookies.
3. **Set `httpOnly` on cookies** to prevent XSS token theft.
4. **Validate CSRF** for session-based auth with forms.
5. **Rotate secrets** regularly — JWT secrets, API keys, session keys.
6. **Rate limit auth endpoints** — prevent brute force attacks.
7. **Log authentication failures** for monitoring.
8. **Set reasonable token expiry** — access tokens: 1h, refresh tokens: 7-30 days.
9. **Use environment variables** for all secrets — never hardcode.
10. **Invalidate tokens on password change** — delete all user tokens.
11. **Use constant-time comparison** for tokens — Bcrypt.verify does this internally.
12. **Implement account lockout** after repeated failed attempts.

```swift
// Example: Rate limiting login attempts
struct LoginRateLimitMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let ip = request.peerAddress?.description ?? "unknown"
        let key = "login_attempts:\(ip)"

        let attempts = try await request.cache.get(key, as: Int.self) ?? 0
        guard attempts < 10 else {
            throw Abort(.tooManyRequests, reason: "Too many login attempts. Try again later.")
        }

        do {
            let response = try await next.respond(to: request)
            // Reset on success
            try await request.cache.delete(key)
            return response
        } catch {
            // Increment on failure
            try await request.cache.set(key, to: attempts + 1, expiresIn: .minutes(15))
            throw error
        }
    }
}
```
