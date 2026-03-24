import Vapor
import Fluent
import FluentPostgresDriver
import JWT
import Redis

/// Configures the Vapor application: middleware, database, migrations, routes.
func configure(_ app: Application) async throws {

    // ── Middleware ────────────────────────────────────────────
    // Order matters: first registered = first executed for requests

    // CORS (configure for your frontend domain in production)
    let corsConfig = CORSMiddleware.Configuration(
        allowedOrigin: app.environment == .production
            ? .custom(Environment.get("ALLOWED_ORIGIN") ?? "https://yourdomain.com")
            : .all,
        allowedMethods: [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS],
        allowedHeaders: [
            .accept, .authorization, .contentType, .origin,
            .xRequestedWith, .init("X-API-Key"),
        ],
        allowCredentials: true
    )
    app.middleware.use(CORSMiddleware(configuration: corsConfig))

    // Serve static files from Public/
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Custom error handling (replace default in production)
    // app.middleware.use(CustomErrorMiddleware())

    // ── Database ─────────────────────────────────────────────
    let dbConfig = SQLPostgresConfiguration(
        hostname: Environment.get("DB_HOST") ?? "localhost",
        port: Environment.get("DB_PORT").flatMap(Int.init) ?? 5432,
        username: Environment.get("DB_USER") ?? "vapor",
        password: Environment.get("DB_PASS") ?? "vapor",
        database: Environment.get("DB_NAME") ?? "vapor_db",
        tls: app.environment == .production
            ? .require(try .init(configuration: .clientDefault))
            : .disable
    )
    app.databases.use(
        .postgres(configuration: dbConfig, maxConnectionsPerEventLoop: 4),
        as: .psql
    )

    // ── Redis ────────────────────────────────────────────────
    if let redisURL = Environment.get("REDIS_URL") {
        app.redis.configuration = try RedisConfiguration(url: redisURL)
    }

    // ── JWT ──────────────────────────────────────────────────
    let jwtSecret = Environment.get("JWT_SECRET") ?? "dev-secret-change-me"
    app.jwt.signers.use(.hs256(key: jwtSecret))

    // ── Sessions (optional, for web apps) ────────────────────
    // app.sessions.use(.fluent)
    // app.middleware.use(app.sessions.middleware)

    // ── Migrations ───────────────────────────────────────────
    // Register in dependency order
    // app.migrations.add(CreateUser())
    // app.migrations.add(CreateUserToken())
    // app.migrations.add(CreatePost())

    // Auto-migrate in non-production (use CLI migrate command in production)
    if app.environment != .production {
        try await app.autoMigrate()
    }

    // ── Queues (optional) ────────────────────────────────────
    // app.queues.use(.redis(url: Environment.get("REDIS_URL") ?? "redis://127.0.0.1:6379"))
    // app.queues.add(EmailJob())
    // app.queues.schedule(CleanupJob()).daily().at(.midnight)

    // ── Server Configuration ─────────────────────────────────
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "0.0.0.0"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080

    // Request body size limit (default is 16KB)
    app.routes.defaultMaxBodySize = "10mb"

    // ── Logging ──────────────────────────────────────────────
    if let logLevel = Environment.get("LOG_LEVEL") {
        app.logger.logLevel = Logger.Level(rawValue: logLevel) ?? .info
    }

    // ── Routes ───────────────────────────────────────────────
    try routes(app)
}
