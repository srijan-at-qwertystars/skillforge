// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyVaporApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Core
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),

        // ORM
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),

        // Authentication
        .package(url: "https://github.com/vapor/jwt.git", from: "4.2.0"),

        // Caching & Queues
        .package(url: "https://github.com/vapor/redis.git", from: "4.10.0"),
        .package(url: "https://github.com/vapor/queues.git", from: "1.13.0"),
        .package(url: "https://github.com/vapor/queues-redis-driver.git", from: "1.1.0"),

        // Templating (uncomment if needed)
        // .package(url: "https://github.com/vapor/leaf.git", from: "4.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "Redis", package: "redis"),
                .product(name: "Queues", package: "queues"),
                .product(name: "QueuesRedisDriver", package: "queues-redis-driver"),
                // .product(name: "Leaf", package: "leaf"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .enableUpcomingFeature("ConciseMagicFile"),
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)
