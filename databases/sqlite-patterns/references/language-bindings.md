# SQLite Language Bindings

## Table of Contents

- [Python](#python)
  - [sqlite3 (stdlib)](#sqlite3-stdlib)
  - [aiosqlite](#aiosqlite)
  - [SQLAlchemy](#sqlalchemy)
  - [Python Migration Tools](#python-migration-tools)
- [Node.js](#nodejs)
  - [better-sqlite3](#better-sqlite3)
  - [sql.js](#sqljs)
  - [Drizzle ORM](#drizzle-orm)
  - [Node.js Migration Tools](#nodejs-migration-tools)
- [Go](#go)
  - [modernc.org/sqlite](#moderncorgsqlite)
  - [mattn/go-sqlite3](#mattngo-sqlite3)
  - [Go Migration Tools](#go-migration-tools)
- [Rust](#rust)
  - [rusqlite](#rusqlite)
  - [Diesel](#diesel)
  - [Rust Migration Tools](#rust-migration-tools)

---

## Python

### sqlite3 (stdlib)

The `sqlite3` module is part of the Python standard library. Zero dependencies.

**Connection patterns:**

```python
import sqlite3
from contextlib import contextmanager

# Basic connection with recommended PRAGMAs
def get_connection(db_path: str, readonly: bool = False) -> sqlite3.Connection:
    conn = sqlite3.connect(
        db_path,
        isolation_level=None,          # autocommit mode (manual transaction control)
        check_same_thread=False,       # allow multi-threaded access
        detect_types=sqlite3.PARSE_DECLTYPES | sqlite3.PARSE_COLNAMES,
    )
    conn.row_factory = sqlite3.Row     # dict-like row access
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA cache_size=-64000")
    if readonly:
        conn.execute("PRAGMA query_only=ON")
    return conn

# Context manager for transactions
@contextmanager
def transaction(conn: sqlite3.Connection):
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise

# Usage
conn = get_connection("app.db")
with transaction(conn):
    conn.execute("INSERT INTO users (name) VALUES (?)", ("Alice",))
    conn.execute("INSERT INTO users (name) VALUES (?)", ("Bob",))
```

**Error handling:**

```python
import sqlite3

try:
    conn.execute("INSERT INTO users (email) VALUES (?)", (email,))
except sqlite3.IntegrityError as e:
    # UNIQUE constraint, FK violation, NOT NULL, CHECK
    if "UNIQUE" in str(e):
        print(f"Duplicate email: {email}")
    elif "FOREIGN KEY" in str(e):
        print("Referenced record does not exist")
except sqlite3.OperationalError as e:
    if "locked" in str(e) or "busy" in str(e):
        print("Database is busy, retry later")
    elif "no such table" in str(e):
        print("Table does not exist — run migrations")
    else:
        raise
except sqlite3.DatabaseError as e:
    if "malformed" in str(e) or "corrupt" in str(e):
        print("Database corruption detected!")
        raise
```

**Custom functions and aggregates:**

```python
import sqlite3
import json
import hashlib

conn = sqlite3.connect("app.db")

# Scalar function
conn.create_function("sha256", 1, lambda x: hashlib.sha256(x.encode()).hexdigest())

# Deterministic function (3.8+, can be used in indexes)
conn.create_function("json_valid_strict", 1,
    lambda x: 1 if x and json.loads(x) else 0,
    deterministic=True)

# Aggregate function
class Median:
    def __init__(self):
        self.values = []
    def step(self, value):
        if value is not None:
            self.values.append(value)
    def finalize(self):
        if not self.values:
            return None
        s = sorted(self.values)
        n = len(s)
        if n % 2 == 1:
            return s[n // 2]
        return (s[n // 2 - 1] + s[n // 2]) / 2

conn.create_aggregate("median", 1, Median)
```

**Backup API:**

```python
import sqlite3

def backup_database(src_path: str, dst_path: str, pages_per_step: int = 100):
    src = sqlite3.connect(src_path)
    dst = sqlite3.connect(dst_path)
    with dst:
        src.backup(dst, pages=pages_per_step, sleep=0.05)
    dst.close()
    src.close()
```

### aiosqlite

Async wrapper around `sqlite3` for asyncio applications. Runs sqlite3 in a background
thread.

```python
import aiosqlite

async def main():
    async with aiosqlite.connect("app.db") as db:
        db.row_factory = aiosqlite.Row
        await db.execute("PRAGMA journal_mode=WAL")
        await db.execute("PRAGMA foreign_keys=ON")
        await db.execute("PRAGMA busy_timeout=5000")

        # Insert
        await db.execute("INSERT INTO users (name) VALUES (?)", ("Alice",))
        await db.commit()

        # Query
        async with db.execute("SELECT * FROM users WHERE active = 1") as cursor:
            async for row in cursor:
                print(dict(row))

        # Transaction
        async with db.execute("BEGIN IMMEDIATE"):
            await db.execute("UPDATE accounts SET balance = balance - ?", (100,))
            await db.execute("UPDATE accounts SET balance = balance + ?", (100,))
            await db.commit()
```

**Connection pool pattern for aiosqlite:**

```python
import aiosqlite
import asyncio
from contextlib import asynccontextmanager

class AsyncSQLitePool:
    """Single writer + multiple reader connections for aiosqlite."""
    def __init__(self, db_path: str, max_readers: int = 4):
        self.db_path = db_path
        self._writer: aiosqlite.Connection | None = None
        self._write_lock = asyncio.Lock()
        self._readers: asyncio.Queue[aiosqlite.Connection] = asyncio.Queue()
        self._max_readers = max_readers

    async def initialize(self):
        self._writer = await aiosqlite.connect(self.db_path)
        await self._configure(self._writer, readonly=False)
        for _ in range(self._max_readers):
            reader = await aiosqlite.connect(self.db_path)
            await self._configure(reader, readonly=True)
            await self._readers.put(reader)

    async def _configure(self, conn, readonly: bool):
        await conn.execute("PRAGMA journal_mode=WAL")
        await conn.execute("PRAGMA foreign_keys=ON")
        await conn.execute("PRAGMA busy_timeout=5000")
        if readonly:
            await conn.execute("PRAGMA query_only=ON")

    @asynccontextmanager
    async def reader(self):
        conn = await self._readers.get()
        try:
            yield conn
        finally:
            await self._readers.put(conn)

    @asynccontextmanager
    async def writer(self):
        async with self._write_lock:
            yield self._writer

    async def close(self):
        if self._writer:
            await self._writer.close()
        while not self._readers.empty():
            conn = await self._readers.get()
            await conn.close()
```

### SQLAlchemy

SQLAlchemy works with SQLite but requires specific configuration for WAL mode
and connection pooling.

```python
from sqlalchemy import create_engine, event, text
from sqlalchemy.orm import sessionmaker, DeclarativeBase, Mapped, mapped_column

# Engine configuration
engine = create_engine(
    "sqlite:///app.db",
    pool_size=5,                  # reader pool
    pool_pre_ping=True,           # check connections before use
    connect_args={"check_same_thread": False},
)

# Apply PRAGMAs to every new connection
@event.listens_for(engine, "connect")
def set_sqlite_pragma(dbapi_connection, connection_record):
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.execute("PRAGMA busy_timeout=5000")
    cursor.execute("PRAGMA cache_size=-64000")
    cursor.execute("PRAGMA synchronous=NORMAL")
    cursor.close()

# ORM model
class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str]
    email: Mapped[str] = mapped_column(unique=True)

# Session usage
Session = sessionmaker(bind=engine)

def create_user(name: str, email: str) -> User:
    with Session() as session:
        user = User(name=name, email=email)
        session.add(user)
        session.commit()
        session.refresh(user)
        return user
```

**SQLAlchemy with separate read/write engines:**

```python
from sqlalchemy import create_engine, event

write_engine = create_engine("sqlite:///app.db", pool_size=1)
read_engine = create_engine("sqlite:///app.db", pool_size=5)

@event.listens_for(read_engine, "connect")
def set_read_pragma(dbapi_conn, _):
    cursor = dbapi_conn.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA query_only=ON")
    cursor.close()
```

### Python Migration Tools

**Alembic** (with SQLAlchemy):

```bash
pip install alembic
alembic init migrations
```

```python
# alembic/env.py — configure for SQLite
# Batch mode is required because SQLite has limited ALTER TABLE support
context.configure(
    connection=connection,
    target_metadata=target_metadata,
    render_as_batch=True,  # critical for SQLite
)
```

**yoyo-migrations** (standalone, no ORM):

```bash
pip install yoyo-migrations
yoyo new -m "Add users table" ./migrations
```

```python
# migrations/0001_add_users.py
from yoyo import step
step(
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
    "DROP TABLE users"
)
```

---

## Node.js

### better-sqlite3

Synchronous SQLite binding for Node.js. Fastest option. Recommended for most use cases.

```javascript
const Database = require('better-sqlite3');

// Connection with recommended pragmas
function openDatabase(path, { readonly = false } = {}) {
    const db = new Database(path, {
        readonly,
        fileMustExist: false,
        verbose: process.env.NODE_ENV === 'development' ? console.log : undefined,
    });
    db.pragma('journal_mode = WAL');
    db.pragma('foreign_keys = ON');
    db.pragma('busy_timeout = 5000');
    db.pragma('cache_size = -64000');
    db.pragma('synchronous = NORMAL');
    if (readonly) {
        db.pragma('query_only = ON');
    }
    return db;
}

const db = openDatabase('app.db');

// Prepared statements (compile once, run many)
const getUser = db.prepare('SELECT * FROM users WHERE id = ?');
const insertUser = db.prepare('INSERT INTO users (name, email) VALUES (@name, @email)');

// Single row
const user = getUser.get(42);

// All rows
const users = db.prepare('SELECT * FROM users WHERE active = ?').all(1);

// Insert with named parameters
const info = insertUser.run({ name: 'Alice', email: 'alice@example.com' });
console.log(info.lastInsertRowid, info.changes);

// Transaction (automatic BEGIN/COMMIT/ROLLBACK)
const transferFunds = db.transaction((from, to, amount) => {
    db.prepare('UPDATE accounts SET balance = balance - ? WHERE id = ?').run(amount, from);
    db.prepare('UPDATE accounts SET balance = balance + ? WHERE id = ?').run(amount, to);
    return { from, to, amount };
});

try {
    const result = transferFunds(1, 2, 100);
} catch (err) {
    console.error('Transfer failed:', err.message);
}

// Batch insert (100x faster than individual inserts)
const bulkInsert = db.transaction((users) => {
    const stmt = db.prepare('INSERT INTO users (name, email) VALUES (?, ?)');
    for (const u of users) {
        stmt.run(u.name, u.email);
    }
});
bulkInsert(usersArray);
```

**Error handling:**

```javascript
const Database = require('better-sqlite3');

try {
    db.prepare('INSERT INTO users (email) VALUES (?)').run(email);
} catch (err) {
    if (err.code === 'SQLITE_CONSTRAINT_UNIQUE') {
        console.log('Duplicate email');
    } else if (err.code === 'SQLITE_CONSTRAINT_FOREIGNKEY') {
        console.log('Foreign key violation');
    } else if (err.code === 'SQLITE_BUSY') {
        console.log('Database is busy');
    } else if (err.code === 'SQLITE_CORRUPT') {
        console.error('Database corruption detected!');
        process.exit(1);
    } else {
        throw err;
    }
}
```

**Custom functions:**

```javascript
// Scalar function
db.function('sha256', (text) => {
    const crypto = require('crypto');
    return crypto.createHash('sha256').update(text).digest('hex');
});

// Aggregate function
db.aggregate('median', {
    start: () => [],
    step: (arr, value) => { if (value != null) arr.push(value); },
    result: (arr) => {
        arr.sort((a, b) => a - b);
        const mid = Math.floor(arr.length / 2);
        return arr.length % 2 ? arr[mid] : (arr[mid - 1] + arr[mid]) / 2;
    },
});
```

### sql.js

SQLite compiled to WebAssembly via Emscripten. Runs in browsers and Node.js
without native bindings.

```javascript
const initSqlJs = require('sql.js');

async function main() {
    const SQL = await initSqlJs();

    // In-memory database
    const db = new SQL.Database();

    // Or load from file/ArrayBuffer
    const fileBuffer = fs.readFileSync('app.db');
    const db2 = new SQL.Database(fileBuffer);

    // Execute SQL
    db.run('CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)');
    db.run('INSERT INTO test VALUES (?, ?)', [1, 'hello']);

    // Query
    const results = db.exec('SELECT * FROM test');
    // results = [{ columns: ['id', 'value'], values: [[1, 'hello']] }]

    // Prepared statement
    const stmt = db.prepare('SELECT * FROM test WHERE id = $id');
    stmt.bind({ $id: 1 });
    while (stmt.step()) {
        console.log(stmt.getAsObject());  // { id: 1, value: 'hello' }
    }
    stmt.free();

    // Export database as Uint8Array
    const data = db.export();
    const buffer = Buffer.from(data);
    fs.writeFileSync('output.db', buffer);

    db.close();
}
```

**Use cases for sql.js:**
- Browser-based applications (no server needed).
- Serverless environments where native modules aren't available.
- Wasm-based edge computing (Cloudflare Workers, Deno Deploy).
- Testing without native SQLite installation.

**Limitations:**
- Entire database must fit in memory.
- No WAL mode (runs in memory, no file I/O).
- Slower than native bindings (2-5x for most operations).

### Drizzle ORM

Type-safe ORM with excellent SQLite support. Works with better-sqlite3 or sql.js.

```typescript
import { drizzle } from 'drizzle-orm/better-sqlite3';
import { sqliteTable, text, integer } from 'drizzle-orm/sqlite-core';
import { eq, and, gt, sql } from 'drizzle-orm';
import Database from 'better-sqlite3';

// Schema definition
const users = sqliteTable('users', {
    id: integer('id').primaryKey({ autoIncrement: true }),
    name: text('name').notNull(),
    email: text('email').notNull().unique(),
    createdAt: text('created_at').default(sql`datetime('now')`),
});

const posts = sqliteTable('posts', {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id').references(() => users.id),
    title: text('title').notNull(),
    body: text('body'),
});

// Database setup
const sqlite = new Database('app.db');
sqlite.pragma('journal_mode = WAL');
const db = drizzle(sqlite, { schema: { users, posts } });

// Type-safe queries
const allUsers = db.select().from(users).all();

const activeUsers = db.select()
    .from(users)
    .where(and(
        eq(users.active, true),
        gt(users.createdAt, '2024-01-01')
    ))
    .all();

// Insert with returning
const [newUser] = db.insert(users)
    .values({ name: 'Alice', email: 'alice@example.com' })
    .returning()
    .all();

// Joins
const userPosts = db.select({
    userName: users.name,
    postTitle: posts.title,
})
    .from(users)
    .leftJoin(posts, eq(users.id, posts.userId))
    .all();

// Transactions
db.transaction((tx) => {
    tx.insert(users).values({ name: 'Bob', email: 'bob@example.com' }).run();
    tx.insert(posts).values({ userId: 1, title: 'Hello' }).run();
});
```

### Node.js Migration Tools

**drizzle-kit** (for Drizzle ORM):

```bash
npx drizzle-kit generate:sqlite
npx drizzle-kit push:sqlite
npx drizzle-kit studio   # visual database browser
```

**knex.js** (standalone migrations):

```bash
npx knex migrate:make create_users --knexfile knexfile.js
npx knex migrate:latest
npx knex migrate:rollback
```

```javascript
// knexfile.js
module.exports = {
    client: 'better-sqlite3',
    connection: { filename: './app.db' },
    useNullAsDefault: true,
    pool: {
        afterCreate: (conn, cb) => {
            conn.pragma('journal_mode = WAL');
            conn.pragma('foreign_keys = ON');
            cb(null, conn);
        },
    },
};
```

---

## Go

### modernc.org/sqlite

Pure Go SQLite implementation (no CGO required). Recommended for most Go projects.

```go
package main

import (
    "database/sql"
    "fmt"
    "log"
    _ "modernc.org/sqlite"
)

func openDB(path string) (*sql.DB, error) {
    // Connection string with PRAGMAs
    dsn := fmt.Sprintf(
        "file:%s?_journal_mode=WAL&_busy_timeout=5000&_foreign_keys=ON&_synchronous=NORMAL&_cache_size=-64000",
        path,
    )
    db, err := sql.Open("sqlite", dsn)
    if err != nil {
        return nil, err
    }
    // Single writer connection
    db.SetMaxOpenConns(1)
    db.SetMaxIdleConns(1)
    // Verify connection
    if err := db.Ping(); err != nil {
        return nil, err
    }
    return db, nil
}

func main() {
    db, err := openDB("app.db")
    if err != nil {
        log.Fatal(err)
    }
    defer db.Close()

    // Create table
    _, err = db.Exec(`CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT UNIQUE NOT NULL
    ) STRICT`)
    if err != nil {
        log.Fatal(err)
    }

    // Insert
    result, err := db.Exec("INSERT INTO users (name, email) VALUES (?, ?)", "Alice", "alice@example.com")
    if err != nil {
        log.Fatal(err)
    }
    id, _ := result.LastInsertId()
    fmt.Printf("Inserted user ID: %d\n", id)

    // Query
    rows, err := db.Query("SELECT id, name, email FROM users WHERE name LIKE ?", "%Ali%")
    if err != nil {
        log.Fatal(err)
    }
    defer rows.Close()
    for rows.Next() {
        var id int64
        var name, email string
        rows.Scan(&id, &name, &email)
        fmt.Printf("User: %d, %s, %s\n", id, name, email)
    }

    // Transaction
    tx, err := db.Begin()
    if err != nil {
        log.Fatal(err)
    }
    defer tx.Rollback()
    tx.Exec("UPDATE accounts SET balance = balance - ? WHERE id = ?", 100, 1)
    tx.Exec("UPDATE accounts SET balance = balance + ? WHERE id = ?", 100, 2)
    if err := tx.Commit(); err != nil {
        log.Fatal(err)
    }
}
```

**Error handling in Go:**

```go
import (
    "database/sql"
    "errors"
    "strings"

    sqlite3 "modernc.org/sqlite/lib"
)

func isUniqueViolation(err error) bool {
    return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}

func isBusy(err error) bool {
    return err != nil && strings.Contains(err.Error(), "database is locked")
}

// Retry pattern for busy errors
func execWithRetry(db *sql.DB, query string, args ...any) (sql.Result, error) {
    var result sql.Result
    var err error
    for attempt := 0; attempt < 5; attempt++ {
        result, err = db.Exec(query, args...)
        if err == nil || !isBusy(err) {
            return result, err
        }
        time.Sleep(time.Duration(attempt*100) * time.Millisecond)
    }
    return result, err
}
```

**Read/write splitting in Go:**

```go
func openReadWriteDBs(path string) (writer *sql.DB, reader *sql.DB, err error) {
    // Writer: single connection
    writer, err = sql.Open("sqlite",
        fmt.Sprintf("file:%s?_journal_mode=WAL&_busy_timeout=5000&_foreign_keys=ON", path))
    if err != nil {
        return nil, nil, err
    }
    writer.SetMaxOpenConns(1)

    // Reader: multiple connections, query_only
    reader, err = sql.Open("sqlite",
        fmt.Sprintf("file:%s?_journal_mode=WAL&_query_only=ON", path))
    if err != nil {
        writer.Close()
        return nil, nil, err
    }
    reader.SetMaxOpenConns(4)
    return writer, reader, nil
}
```

### mattn/go-sqlite3

CGO-based SQLite binding. Faster than pure Go, but requires a C compiler.

```go
import (
    "database/sql"
    _ "github.com/mattn/go-sqlite3"
)

func openDB(path string) (*sql.DB, error) {
    db, err := sql.Open("sqlite3",
        fmt.Sprintf("file:%s?_journal_mode=WAL&_busy_timeout=5000&_fk=ON&cache=shared", path))
    if err != nil {
        return nil, err
    }
    db.SetMaxOpenConns(1)
    return db, nil
}
```

**When to use mattn/go-sqlite3 vs modernc.org/sqlite:**

| Feature               | mattn/go-sqlite3         | modernc.org/sqlite       |
|-----------------------|--------------------------|--------------------------|
| CGO required          | Yes                      | No (pure Go)             |
| Performance           | ~10-20% faster           | Slightly slower          |
| Cross-compilation     | Complex (needs C toolchain)| Simple (`GOOS=... go build`) |
| Custom functions      | Yes (via C)              | Yes (via Go)             |
| Docker image size     | Larger (C libs)          | Smaller                  |
| Recommendation        | Performance-critical     | Default choice           |

### Go Migration Tools

**goose:**

```bash
go install github.com/pressly/goose/v3/cmd/goose@latest
goose -dir migrations sqlite3 app.db up
goose -dir migrations sqlite3 app.db status
```

```sql
-- migrations/001_create_users.sql
-- +goose Up
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
-- +goose Down
DROP TABLE users;
```

**golang-migrate:**

```bash
go install -tags 'sqlite3' github.com/golang-migrate/migrate/v4/cmd/migrate@latest
migrate -path migrations -database "sqlite3://app.db" up
```

---

## Rust

### rusqlite

The most popular Rust SQLite binding. Safe wrapper around the C SQLite library.

```rust
use rusqlite::{Connection, Result, params, OptionalExtension};

fn open_db(path: &str) -> Result<Connection> {
    let conn = Connection::open(path)?;
    conn.execute_batch("
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        PRAGMA busy_timeout=5000;
        PRAGMA cache_size=-64000;
        PRAGMA synchronous=NORMAL;
    ")?;
    Ok(conn)
}

#[derive(Debug)]
struct User {
    id: i64,
    name: String,
    email: String,
}

fn main() -> Result<()> {
    let conn = open_db("app.db")?;

    // Create table
    conn.execute_batch("
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            email TEXT UNIQUE NOT NULL
        ) STRICT
    ")?;

    // Insert
    conn.execute(
        "INSERT INTO users (name, email) VALUES (?1, ?2)",
        params!["Alice", "alice@example.com"],
    )?;

    // Query single row (optional)
    let user: Option<User> = conn.query_row(
        "SELECT id, name, email FROM users WHERE id = ?1",
        params![1],
        |row| Ok(User {
            id: row.get(0)?,
            name: row.get(1)?,
            email: row.get(2)?,
        }),
    ).optional()?;

    // Query multiple rows
    let mut stmt = conn.prepare("SELECT id, name, email FROM users WHERE name LIKE ?1")?;
    let users = stmt.query_map(params!["%Ali%"], |row| {
        Ok(User {
            id: row.get(0)?,
            name: row.get(1)?,
            email: row.get(2)?,
        })
    })?;
    for user in users {
        println!("{:?}", user?);
    }

    // Transaction
    let tx = conn.transaction()?;
    tx.execute("UPDATE accounts SET balance = balance - ?1 WHERE id = ?2", params![100, 1])?;
    tx.execute("UPDATE accounts SET balance = balance + ?1 WHERE id = ?2", params![100, 2])?;
    tx.commit()?;

    Ok(())
}
```

**Error handling in Rust:**

```rust
use rusqlite::{Error, ErrorCode};

fn insert_user(conn: &Connection, name: &str, email: &str) -> Result<i64> {
    match conn.execute(
        "INSERT INTO users (name, email) VALUES (?1, ?2)",
        params![name, email],
    ) {
        Ok(_) => Ok(conn.last_insert_rowid()),
        Err(Error::SqliteFailure(err, msg)) => {
            match err.code {
                ErrorCode::ConstraintViolation => {
                    eprintln!("Constraint violated: {:?}", msg);
                    Err(Error::SqliteFailure(err, msg))
                }
                ErrorCode::DatabaseBusy => {
                    eprintln!("Database busy, consider retry");
                    Err(Error::SqliteFailure(err, msg))
                }
                ErrorCode::DatabaseCorrupt => {
                    eprintln!("CRITICAL: Database corruption!");
                    std::process::exit(1);
                }
                _ => Err(Error::SqliteFailure(err, msg)),
            }
        }
        Err(e) => Err(e),
    }
}
```

**Connection pool with r2d2:**

```rust
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;

fn create_pool(path: &str) -> Result<Pool<SqliteConnectionManager>, r2d2::Error> {
    let manager = SqliteConnectionManager::file(path)
        .with_init(|conn| {
            conn.execute_batch("
                PRAGMA journal_mode=WAL;
                PRAGMA foreign_keys=ON;
                PRAGMA busy_timeout=5000;
            ")?;
            Ok(())
        });
    Pool::builder()
        .max_size(4)
        .build(manager)
}

// Usage
let pool = create_pool("app.db")?;
let conn = pool.get()?;
conn.execute("INSERT INTO logs (msg) VALUES (?1)", params!["hello"])?;
```

### Diesel

Type-safe ORM and query builder for Rust.

```rust
// Cargo.toml
// [dependencies]
// diesel = { version = "2", features = ["sqlite", "returning_clauses_for_sqlite_3_35"] }

use diesel::prelude::*;

// Schema (generated by diesel CLI)
diesel::table! {
    users (id) {
        id -> Integer,
        name -> Text,
        email -> Text,
    }
}

#[derive(Queryable, Selectable, Debug)]
#[diesel(table_name = users)]
struct User {
    id: i32,
    name: String,
    email: String,
}

#[derive(Insertable)]
#[diesel(table_name = users)]
struct NewUser<'a> {
    name: &'a str,
    email: &'a str,
}

fn establish_connection(url: &str) -> SqliteConnection {
    let mut conn = SqliteConnection::establish(url)
        .expect("Error connecting to database");
    diesel::sql_query("PRAGMA journal_mode=WAL").execute(&mut conn).unwrap();
    diesel::sql_query("PRAGMA foreign_keys=ON").execute(&mut conn).unwrap();
    diesel::sql_query("PRAGMA busy_timeout=5000").execute(&mut conn).unwrap();
    conn
}

fn create_user(conn: &mut SqliteConnection, name: &str, email: &str) -> QueryResult<User> {
    let new_user = NewUser { name, email };
    diesel::insert_into(users::table)
        .values(&new_user)
        .returning(User::as_returning())
        .get_result(conn)
}

fn find_users(conn: &mut SqliteConnection, search: &str) -> QueryResult<Vec<User>> {
    users::table
        .filter(users::name.like(format!("%{search}%")))
        .order(users::name.asc())
        .load::<User>(conn)
}
```

### Rust Migration Tools

**diesel_migrations:**

```bash
diesel setup --database-url app.db
diesel migration generate create_users
diesel migration run --database-url app.db
```

```sql
-- migrations/2024-01-15-000000_create_users/up.sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL
) STRICT;

-- migrations/2024-01-15-000000_create_users/down.sql
DROP TABLE users;
```

**Embedded migrations (run on startup):**

```rust
use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};

pub const MIGRATIONS: EmbeddedMigrations = embed_migrations!("migrations");

fn run_migrations(conn: &mut SqliteConnection) {
    conn.run_pending_migrations(MIGRATIONS)
        .expect("Failed to run migrations");
}
```

**refinery** (standalone, no ORM):

```rust
use refinery::embed_migrations;

embed_migrations!("migrations");

fn main() {
    let mut conn = rusqlite::Connection::open("app.db").unwrap();
    migrations::runner().run(&mut conn).unwrap();
}
```
