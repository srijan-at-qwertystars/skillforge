# Fluent ORM Deep Dive — Vapor 4.x

## Table of Contents

- [Model Lifecycle Hooks](#model-lifecycle-hooks)
- [Soft Deletes](#soft-deletes)
- [Timestamps](#timestamps)
- [Enums](#enums)
- [JSON Columns](#json-columns)
- [Composite Unique Constraints](#composite-unique-constraints)
- [Eager Loading: with vs join](#eager-loading-with-vs-join)
- [Sibling Relations and Pivots](#sibling-relations-and-pivots)
- [Raw SQL](#raw-sql)
- [Migrations Best Practices](#migrations-best-practices)
- [Seeding](#seeding)
- [Database Transactions](#database-transactions)
- [Advanced Query Patterns](#advanced-query-patterns)
- [Performance Tips](#performance-tips)

---

## Model Lifecycle Hooks

Fluent models can hook into create, update, and delete events using the `ModelMiddleware` protocol. This allows you to run logic before or after persistence operations without cluttering controller code.

### Defining a Model Middleware

```swift
struct UserMiddleware: AsyncModelMiddleware {
    func create(model: User, on db: Database, next: AnyAsyncModelResponder) async throws {
        // Pre-create: normalize email
        model.email = model.email.lowercased().trimmingCharacters(in: .whitespaces)

        // Validate uniqueness manually if needed
        let existing = try await User.query(on: db)
            .filter(\.$email == model.email)
            .first()
        if existing != nil {
            throw Abort(.conflict, reason: "Email already registered")
        }

        try await next.create(model, on: db)

        // Post-create: dispatch welcome email
        // This runs after the model is saved
        print("User created: \(model.email)")
    }

    func update(model: User, on db: Database, next: AnyAsyncModelResponder) async throws {
        // Pre-update logic
        model.updatedAt = Date()
        try await next.update(model, on: db)
        // Post-update logic
    }

    func delete(model: User, force: Bool, on db: Database, next: AnyAsyncModelResponder) async throws {
        // Pre-delete: cascade manual cleanup
        try await Post.query(on: db)
            .filter(\.$user.$id == model.id!)
            .delete()
        try await next.delete(model, force: force, on: db)
    }
}
```

### Registering Middleware

```swift
// In configure.swift
app.databases.middleware.use(UserMiddleware(), on: .psql)
```

### Hook Execution Order

1. `create` → called on `.save()` for new models (no existing ID in DB)
2. `update` → called on `.save()` for existing models or `.update(on:)`
3. `delete` → called on `.delete(on:)`, receives `force` flag for soft deletes
4. `softDelete` → called when soft-deleting (if model uses `@Timestamp(on: .delete)`)

Middleware chains in registration order. If any middleware throws, the operation aborts and subsequent middleware does not execute.

---

## Soft Deletes

Soft deletes mark records as deleted without removing them from the database. Fluent supports this natively via `@Timestamp(key:on:format:)` with the `.delete` trigger.

### Model Setup

```swift
final class Article: Model, Content, @unchecked Sendable {
    static let schema = "articles"

    @ID(key: .id) var id: UUID?
    @Field(key: "title") var title: String
    @Field(key: "body") var body: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}
}
```

### Migration

```swift
struct CreateArticle: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("articles")
            .id()
            .field("title", .string, .required)
            .field("body", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)  // nullable — null means not deleted
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.schema("articles").delete()
    }
}
```

### Querying Soft-Deleted Records

```swift
// Normal query — excludes soft-deleted
let articles = try await Article.query(on: req.db).all()

// Include soft-deleted
let allArticles = try await Article.query(on: req.db)
    .withDeleted()
    .all()

// Only soft-deleted
let trashed = try await Article.query(on: req.db)
    .withDeleted()
    .filter(\.$deletedAt != nil)
    .all()
```

### Restoring and Force Deleting

```swift
// Restore a soft-deleted record
article.deletedAt = nil
try await article.save(on: req.db)

// Permanently delete (bypass soft delete)
try await article.delete(force: true, on: req.db)
```

---

## Timestamps

Fluent provides three timestamp triggers: `.create`, `.update`, and `.delete`.

### All Timestamp Types

```swift
final class Event: Model, Content, @unchecked Sendable {
    static let schema = "events"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String

    // Auto-set on first save
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    // Auto-set on every save
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    // Auto-set on delete (enables soft delete)
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    // Unix timestamp format (seconds since epoch)
    @Timestamp(key: "published_at", on: .none, format: .unix) var publishedAt: Date?

    init() {}
}
```

### Timestamp Formats

- `.default` — ISO 8601 datetime (database native)
- `.unix` — seconds since Unix epoch as `Double`
- `.iso8601` — ISO 8601 string

### Manual Timestamp Control

```swift
// Override automatic timestamp
event.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
try await event.save(on: req.db)

// Timestamps with .none trigger are never auto-set
event.publishedAt = Date()
try await event.save(on: req.db)
```

---

## Enums

Fluent supports Swift enums as model fields via `@Enum` property wrapper and corresponding database enum types.

### String-Backed Enum (Recommended)

```swift
enum UserRole: String, Codable, CaseIterable {
    case admin
    case editor
    case viewer
}

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"
    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Enum(key: "role") var role: UserRole

    init() {}
    init(name: String, role: UserRole) {
        self.name = name
        self.role = role
    }
}
```

### Migration with Database Enum

```swift
struct CreateUserWithRole: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Create the database enum type first
        let roleEnum = try await database.enum("user_role")
            .case("admin")
            .case("editor")
            .case("viewer")
            .create()

        try await database.schema("users")
            .id()
            .field("name", .string, .required)
            .field("role", roleEnum, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users").delete()
        try await database.enum("user_role").delete()
    }
}
```

### Adding Enum Cases via Migration

```swift
struct AddModeratorRole: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Update existing enum to add a new case
        try await database.enum("user_role")
            .case("moderator")
            .update()
    }
    func revert(on database: Database) async throws {
        try await database.enum("user_role")
            .deleteCase("moderator")
            .update()
    }
}
```

### String Field Alternative

If you prefer simplicity or your database doesn't support native enums, store as a plain string:

```swift
@Field(key: "role") var role: String
// Validate in your application logic
```

---

## JSON Columns

Store complex nested data in a single database column using JSON.

### Model with JSON Column

```swift
struct Address: Codable {
    var street: String
    var city: String
    var state: String
    var zip: String
    var country: String
}

struct Preferences: Codable {
    var theme: String
    var language: String
    var notifications: Bool
    var tags: [String]
}

final class Profile: Model, Content, @unchecked Sendable {
    static let schema = "profiles"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "address") var address: Address       // stored as JSON
    @Field(key: "preferences") var preferences: Preferences  // stored as JSON
    @OptionalField(key: "metadata") var metadata: [String: String]?

    init() {}
}
```

### Migration

```swift
struct CreateProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("profiles")
            .id()
            .field("name", .string, .required)
            .field("address", .json, .required)
            .field("preferences", .json, .required)
            .field("metadata", .json)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.schema("profiles").delete()
    }
}
```

### Querying JSON Fields (PostgreSQL)

PostgreSQL supports querying inside JSON columns:

```swift
// Using raw SQL for JSON field queries
let profiles = try await Profile.query(on: req.db)
    .filter(.sql(raw: "address->>'city' = 'Seattle'"))
    .all()
```

---

## Composite Unique Constraints

Enforce uniqueness across multiple columns.

### In Migrations

```swift
struct CreateMembership: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("memberships")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("team_id", .uuid, .required, .references("teams", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("joined_at", .datetime)
            // Composite unique: a user can only be in a team once
            .unique(on: "user_id", "team_id")
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.schema("memberships").delete()
    }
}
```

### Composite Indexes

```swift
struct AddMembershipIndex: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("memberships")
            .unique(on: "user_id", "team_id")
            .update()
    }
    func revert(on database: Database) async throws {
        try await database.schema("memberships")
            .deleteUnique(on: "user_id", "team_id")
            .update()
    }
}
```

### Handling Constraint Violations

```swift
func addMember(req: Request) async throws -> Membership {
    let dto = try req.content.decode(AddMemberDTO.self)
    let membership = Membership(userID: dto.userID, teamID: dto.teamID, role: dto.role)
    do {
        try await membership.save(on: req.db)
    } catch let error as DatabaseError where error.isConstraintFailure {
        throw Abort(.conflict, reason: "User is already a member of this team")
    }
    return membership
}
```

---

## Eager Loading: with vs join

### `.with()` — Separate Queries (Preferred)

Performs a second query to load related models. Best for most use cases.

```swift
// Load user with their posts
let users = try await User.query(on: req.db)
    .with(\.$posts)
    .all()

// Nested eager loading
let users = try await User.query(on: req.db)
    .with(\.$posts) { post in
        post.with(\.$tags)
        post.with(\.$comments) { comment in
            comment.with(\.$author)
        }
    }
    .all()

// Access loaded relations
for user in users {
    print(user.name)
    for post in user.posts {
        print("  - \(post.title)")
        for tag in post.tags {
            print("    #\(tag.name)")
        }
    }
}
```

### `.join()` — SQL JOIN (For Filtering)

Performs a SQL JOIN. Use when you need to filter the parent by child properties.

```swift
// Find users who have published posts
let authors = try await User.query(on: req.db)
    .join(Post.self, on: \Post.$user.$id == \User.$id)
    .filter(Post.self, \.$isPublished == true)
    .unique()
    .all()

// Access joined model fields
let posts = try await Post.query(on: req.db)
    .join(User.self, on: \Post.$user.$id == \User.$id)
    .all()

for post in posts {
    let authorName = try post.joined(User.self).name
    print("\(post.title) by \(authorName)")
}
```

### When to Use Which

| Scenario | Use |
|----------|-----|
| Display related data | `.with()` |
| Filter parent by child fields | `.join()` |
| Avoid N+1 queries | `.with()` |
| Aggregate on related data | `.join()` |
| Nested relations | `.with()` with nesting |
| Complex WHERE on relations | `.join()` |

**Warning:** `.join()` does not populate the relation property on the model. You must use `.joined(Type.self)` to access joined fields.

---

## Sibling Relations and Pivots

Many-to-many relationships require a pivot table.

### Complete Pivot Example

```swift
// Models
final class Student: Model, Content, @unchecked Sendable {
    static let schema = "students"
    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Siblings(through: Enrollment.self, from: \.$student, to: \.$course) var courses: [Course]
    init() {}
}

final class Course: Model, Content, @unchecked Sendable {
    static let schema = "courses"
    @ID(key: .id) var id: UUID?
    @Field(key: "title") var title: String
    @Siblings(through: Enrollment.self, from: \.$course, to: \.$student) var students: [Student]
    init() {}
}

// Pivot with extra fields
final class Enrollment: Model, @unchecked Sendable {
    static let schema = "enrollments"
    @ID(key: .id) var id: UUID?
    @Parent(key: "student_id") var student: Student
    @Parent(key: "course_id") var course: Course
    @Field(key: "grade") var grade: String?
    @Timestamp(key: "enrolled_at", on: .create) var enrolledAt: Date?
    init() {}
}
```

### Pivot Migration

```swift
struct CreateEnrollment: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("enrollments")
            .id()
            .field("student_id", .uuid, .required, .references("students", "id", onDelete: .cascade))
            .field("course_id", .uuid, .required, .references("courses", "id", onDelete: .cascade))
            .field("grade", .string)
            .field("enrolled_at", .datetime)
            .unique(on: "student_id", "course_id")
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.schema("enrollments").delete()
    }
}
```

### Attach, Detach, and Query

```swift
// Attach (creates pivot row)
try await student.$courses.attach(course, on: req.db)

// Attach with pivot data using edit closure
try await student.$courses.attach(course, on: req.db) { pivot in
    pivot.grade = "A"
}

// Detach (removes pivot row)
try await student.$courses.detach(course, on: req.db)

// Detach all
try await student.$courses.detachAll(on: req.db)

// Check if attached
let isEnrolled = try await student.$courses.isAttached(to: course, on: req.db)

// Query through siblings
let courses = try await student.$courses.query(on: req.db)
    .filter(\.$title =~ "Swift")
    .all()

// Eager load siblings
let students = try await Student.query(on: req.db)
    .with(\.$courses)
    .all()
```

---

## Raw SQL

When Fluent's query builder is insufficient, use raw SQL.

### Basic Raw Queries

```swift
// Raw SELECT
let rows = try await (req.db as! SQLDatabase)
    .raw("SELECT id, name, email FROM users WHERE created_at > \(bind: cutoffDate)")
    .all(decoding: UserRow.self)

struct UserRow: Decodable {
    var id: UUID
    var name: String
    var email: String
}
```

### Using SQLDatabase

```swift
import SQLKit

guard let sql = req.db as? SQLDatabase else {
    throw Abort(.internalServerError, reason: "SQL database required")
}

// Parameterized query (prevents SQL injection)
let results = try await sql.raw("""
    SELECT u.name, COUNT(p.id) as post_count
    FROM users u
    LEFT JOIN posts p ON p.user_id = u.id
    WHERE u.created_at > \(bind: startDate)
    GROUP BY u.id, u.name
    HAVING COUNT(p.id) > \(bind: minPosts)
    ORDER BY post_count DESC
    LIMIT \(bind: limit)
""").all()

for row in results {
    let name = try row.decode(column: "name", as: String.self)
    let count = try row.decode(column: "post_count", as: Int.self)
    print("\(name): \(count) posts")
}
```

### Raw SQL in Migrations

```swift
struct AddFullTextIndex: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("""
            CREATE INDEX idx_articles_fulltext
            ON articles USING gin(to_tsvector('english', title || ' ' || body))
        """).run()
    }
    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_articles_fulltext").run()
    }
}
```

**Always use `\(bind:)` for parameters** to prevent SQL injection. Never interpolate user input directly.

---

## Migrations Best Practices

### 1. Never Modify Released Migrations

Once a migration has been deployed, create a new migration for changes. Never edit an existing migration that has run on other environments.

### 2. Naming Convention

```swift
// Use descriptive names with version/date prefix
struct CreateUser: AsyncMigration { }                    // Initial table
struct AddBioToUser: AsyncMigration { }                  // Add column
struct MakeEmailRequiredOnUser: AsyncMigration { }       // Alter column
struct CreatePostTagPivot: AsyncMigration { }            // Pivot table
struct AddFullTextIndexToArticles: AsyncMigration { }    // Index
```

### 3. Always Implement Revert

```swift
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

### 4. Register in Order

```swift
// In configure.swift — order matters!
app.migrations.add(CreateUser())          // 1. Independent tables first
app.migrations.add(CreateTeam())          // 2. Independent tables
app.migrations.add(CreatePost())          // 3. Depends on User
app.migrations.add(CreateMembership())    // 4. Depends on User + Team
app.migrations.add(AddBioToUser())        // 5. Alters existing table
```

### 5. Foreign Key Constraints

```swift
.field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
// onDelete options: .cascade, .setNull, .restrict, .noAction, .setDefault
```

### 6. Data Migrations

```swift
struct SeedDefaultRoles: AsyncMigration {
    func prepare(on database: Database) async throws {
        let roles = ["admin", "editor", "viewer"]
        for roleName in roles {
            let role = Role(name: roleName)
            try await role.save(on: database)
        }
    }
    func revert(on database: Database) async throws {
        try await Role.query(on: database)
            .filter(\.$name ~~ ["admin", "editor", "viewer"])
            .delete()
    }
}
```

---

## Seeding

Populate the database with initial or test data.

### Seed via Migration

```swift
struct SeedTestData: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Create admin user
        let admin = User(
            name: "Admin",
            email: "admin@example.com",
            passwordHash: try Bcrypt.hash("admin123")
        )
        try await admin.save(on: database)

        // Create sample posts
        let posts = [
            Post(title: "Welcome", body: "First post", userID: admin.id!),
            Post(title: "Getting Started", body: "Guide", userID: admin.id!),
        ]
        for post in posts {
            try await post.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await Post.query(on: database).delete()
        try await User.query(on: database)
            .filter(\.$email == "admin@example.com")
            .delete()
    }
}
```

### Conditional Seeding

```swift
// Only seed in development
func configure(_ app: Application) async throws {
    app.migrations.add(CreateUser())
    app.migrations.add(CreatePost())

    if app.environment == .development || app.environment == .testing {
        app.migrations.add(SeedTestData())
    }
}
```

### Command-Based Seeding

```swift
struct SeedCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "count", short: "c", help: "Number of records")
        var count: Int?
    }

    var help: String { "Seed the database with test data" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let count = signature.count ?? 10
        let app = context.application

        for i in 0..<count {
            let user = User(name: "User \(i)", email: "user\(i)@test.com")
            try await user.save(on: app.db)
        }
        context.console.info("Seeded \(count) users")
    }
}

// Register in configure.swift
app.commands.use(SeedCommand(), as: "seed")
// Run: swift run App seed --count 50
```

---

## Database Transactions

Transactions ensure atomicity — all operations succeed or all are rolled back.

### Basic Transaction

```swift
func transferFunds(req: Request) async throws -> HTTPStatus {
    let dto = try req.content.decode(TransferDTO.self)

    try await req.db.transaction { db in
        // All operations in this block use the same transaction
        guard let sender = try await Account.find(dto.senderID, on: db) else {
            throw Abort(.notFound, reason: "Sender not found")
        }
        guard let receiver = try await Account.find(dto.receiverID, on: db) else {
            throw Abort(.notFound, reason: "Receiver not found")
        }

        guard sender.balance >= dto.amount else {
            throw Abort(.badRequest, reason: "Insufficient funds")
        }

        sender.balance -= dto.amount
        receiver.balance += dto.amount

        try await sender.save(on: db)
        try await receiver.save(on: db)

        // Create audit log within same transaction
        let log = TransactionLog(
            senderID: dto.senderID,
            receiverID: dto.receiverID,
            amount: dto.amount
        )
        try await log.save(on: db)
    }
    // If any operation throws, everything is rolled back

    return .ok
}
```

### Nested Operations in Transactions

```swift
try await req.db.transaction { db in
    let order = Order(userID: userID, total: total)
    try await order.save(on: db)

    for item in items {
        let orderItem = OrderItem(orderID: order.id!, productID: item.productID, quantity: item.qty)
        try await orderItem.save(on: db)

        // Decrement inventory
        guard let product = try await Product.find(item.productID, on: db) else {
            throw Abort(.notFound)  // Rolls back entire order
        }
        guard product.stock >= item.qty else {
            throw Abort(.badRequest, reason: "\(product.name) out of stock")
        }
        product.stock -= item.qty
        try await product.save(on: db)
    }
}
```

### Transaction Isolation

Fluent uses the database default isolation level. For PostgreSQL, this is typically `READ COMMITTED`. To use a different level, use raw SQL:

```swift
guard let sql = req.db as? SQLDatabase else {
    throw Abort(.internalServerError)
}
try await sql.raw("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE").run()
```

---

## Advanced Query Patterns

### Group Filtering (OR Conditions)

```swift
let results = try await User.query(on: req.db)
    .group(.or) { group in
        group.filter(\.$name =~ "admin")
        group.filter(\.$email =~ "admin")
    }
    .filter(\.$deletedAt == nil)
    .all()
```

### Subquery-Like Patterns

```swift
// Get users who have at least one published post
let authorIDs = try await Post.query(on: req.db)
    .filter(\.$isPublished == true)
    .unique()
    .all(\.$user.$id)

let authors = try await User.query(on: req.db)
    .filter(\.$id ~~ authorIDs)
    .all()
```

### Batch Operations

```swift
// Batch update
try await User.query(on: req.db)
    .filter(\.$role == .viewer)
    .set(\.$isActive, to: false)
    .update()

// Batch delete
try await Session.query(on: req.db)
    .filter(\.$expiresAt < Date())
    .delete()
```

### Range and Pattern Queries

```swift
// Range
let recentUsers = try await User.query(on: req.db)
    .filter(\.$createdAt >= Calendar.current.date(byAdding: .day, value: -7, to: Date())!)
    .all()

// LIKE / Contains
let matches = try await User.query(on: req.db)
    .filter(\.$name, .custom("ILIKE"), "%swift%")
    .all()

// IN clause
let specific = try await User.query(on: req.db)
    .filter(\.$id ~~ [uuid1, uuid2, uuid3])
    .all()
```

---

## Performance Tips

1. **Always eager-load** relations you'll access — avoid N+1 queries.
2. **Use `.field()` to select specific columns** when you don't need the full model:
   ```swift
   let names = try await User.query(on: req.db)
       .field(\.$name)
       .all(\.$name)
   ```
3. **Paginate large result sets** — never load unbounded queries:
   ```swift
   let page = try await User.query(on: req.db).paginate(for: req)
   ```
4. **Add database indexes** for frequently queried columns:
   ```swift
   try await database.schema("users")
       .field("email", .string, .required)
       .unique(on: "email")  // also creates an index
       .update()
   ```
5. **Use transactions for multi-step writes** to ensure consistency.
6. **Batch operations** over individual saves when updating many records.
7. **Connection pooling** — Fluent manages pools automatically; tune via:
   ```swift
   var config = SQLPostgresConfiguration(...)
   config.options.maximumConnections = 20
   ```
