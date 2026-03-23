# Gleam Ecosystem Guide

## Table of Contents

- [Key Packages Overview](#key-packages-overview)
  - [gleam_stdlib](#gleam_stdlib)
  - [gleam_http](#gleam_http)
  - [gleam_json](#gleam_json)
  - [gleam_erlang](#gleam_erlang)
  - [gleam_javascript](#gleam_javascript)
- [Testing In Depth](#testing-in-depth)
  - [gleeunit Basics](#gleeunit-basics)
  - [Testing Patterns](#testing-patterns)
  - [Property-Based Testing](#property-based-testing)
- [JSON Handling](#json-handling)
  - [Encoding](#encoding)
  - [Decoding](#decoding)
  - [Complex Decoders](#complex-decoders)
- [File I/O with simplifile](#file-io-with-simplifile)
- [Environment Variables and Configuration](#environment-variables-and-configuration)
- [FFI Patterns](#ffi-patterns)
  - [Erlang FFI](#erlang-ffi)
  - [JavaScript FFI](#javascript-ffi)
  - [Dual-Target FFI](#dual-target-ffi)
  - [FFI Best Practices](#ffi-best-practices)
- [Publishing Packages to Hex](#publishing-packages-to-hex)

---

## Key Packages Overview

### gleam_stdlib

The standard library — always included. Provides core data structures and utilities.

```gleam
import gleam/list
import gleam/string
import gleam/int
import gleam/float
import gleam/result
import gleam/option.{type Option, None, Some}
import gleam/dict.{type Dict}
import gleam/set.{type Set}
import gleam/io
import gleam/bool
import gleam/order
import gleam/iterator.{type Iterator}
import gleam/bit_array
import gleam/bytes_tree
import gleam/string_tree
import gleam/regex
import gleam/uri
import gleam/dynamic
import gleam/dynamic/decode

// --- list ---
list.map([1, 2, 3], fn(x) { x * 2 })             // [2, 4, 6]
list.filter([1, 2, 3, 4], int.is_even)             // [2, 4]
list.fold([1, 2, 3], 0, fn(acc, x) { acc + x })    // 6
list.find([1, 2, 3], fn(x) { x > 1 })              // Ok(2)
list.flat_map([[1, 2], [3]], fn(x) { x })           // [1, 2, 3]
list.zip([1, 2], ["a", "b"])                         // [#(1, "a"), #(2, "b")]
list.chunk([1, 1, 2, 2, 3], fn(x) { x })           // [[1, 1], [2, 2], [3]]
list.window([1, 2, 3, 4], by: 2)                     // [[1, 2], [2, 3], [3, 4]]
list.sort([3, 1, 2], int.compare)                    // [1, 2, 3]
list.unique([1, 2, 2, 3])                            // [1, 2, 3]
list.group([#("a", 1), #("b", 2), #("a", 3)], fn(x) { x.0 })

// --- dict ---
let d = dict.from_list([#("a", 1), #("b", 2)])
dict.get(d, "a")                                     // Ok(1)
dict.insert(d, "c", 3)                               // new dict with c
dict.delete(d, "a")                                  // new dict without a
dict.keys(d)                                          // ["a", "b"]
dict.values(d)                                        // [1, 2]
dict.map_values(d, fn(_k, v) { v * 10 })
dict.filter(d, fn(_k, v) { v > 1 })
dict.merge(d, dict.from_list([#("c", 3)]))

// --- string ---
string.length("hello")                               // 5
string.split("a,b,c", on: ",")                       // ["a", "b", "c"]
string.join(["a", "b"], with: ", ")                  // "a, b"
string.replace("hello", each: "l", with: "r")       // "herro"
string.contains("hello", "ell")                      // True
string.starts_with("hello", "hel")                   // True
string.pad_start("42", to: 5, with: "0")             // "00042"
string.trim("  hello  ")                             // "hello"
string.slice("hello", at_index: 1, length: 3)        // "ell"

// --- iterator (lazy sequences) ---
iterator.range(1, 1000)
|> iterator.filter(fn(x) { x % 3 == 0 })
|> iterator.take(5)
|> iterator.to_list                                  // [3, 6, 9, 12, 15]

// --- regex ---
let assert Ok(re) = regex.from_string("\\d+")
regex.check(re, "abc123")                            // True
regex.scan(re, "a1b22c333")                          // [Match("1", ..), ...]
```

### gleam_http

HTTP types — Request and Response types used by Wisp, Mist, and other HTTP tools.

```gleam
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

// Build a request
let req =
  request.new()
  |> request.set_method(http.Get)
  |> request.set_host("api.example.com")
  |> request.set_path("/users")
  |> request.set_header("authorization", "Bearer token123")
  |> request.set_query([#("page", "1"), #("limit", "10")])

// Build a response
let resp =
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body("{\"users\": []}")

// HTTP methods
http.Get, http.Post, http.Put, http.Patch, http.Delete,
http.Head, http.Options
```

### gleam_json

JSON encoding and decoding.

```gleam
import gleam/json
import gleam/dynamic/decode

// Encode
let j = json.object([
  #("name", json.string("Ada")),
  #("age", json.int(36)),
  #("scores", json.array([95, 87, 92], json.int)),
  #("active", json.bool(True)),
  #("address", json.null()),
])
json.to_string(j)
// {"name":"Ada","age":36,"scores":[95,87,92],"active":true,"address":null}

// Decode
let decoder = {
  use name <- decode.field("name", decode.string)
  use age <- decode.field("age", decode.int)
  decode.success(User(name: name, age: age))
}
json.parse("{\"name\":\"Ada\",\"age\":36}", decoder)
// Ok(User(name: "Ada", age: 36))
```

### gleam_erlang

Erlang-specific functionality. Required for process management, atoms, OS access.

```gleam
import gleam/erlang
import gleam/erlang/process
import gleam/erlang/atom.{type Atom}
import gleam/erlang/os

// System info
erlang.system_time(erlang.Millisecond)               // Unix timestamp ms
erlang.erlang_timestamp()                             // #(mega, sec, micro)

// Process management
process.self()                                        // current Pid
process.sleep(1000)                                   // sleep 1 second
process.sleep_forever()                               // block forever

// Atoms
let assert Ok(my_atom) = atom.from_string("my_atom")
atom.to_string(my_atom)                               // "my_atom"

// OS environment
os.get_env("DATABASE_URL")                            // Result(String, Nil)
os.set_env("KEY", "value")
```

### gleam_javascript

JavaScript target interop. Provides typed access to JS features.

```gleam
// Only available when targeting JavaScript
import gleam/javascript/promise.{type Promise}
import gleam/javascript/array.{type Array}

// Promises
pub fn fetch_data() -> Promise(String) {
  promise.new(fn(resolve) {
    resolve("data")
  })
}

promise.map(fetch_data(), fn(data) { string.uppercase(data) })
promise.await(promise1, fn(result) { promise2(result) })

// JS Arrays (mutable, unlike Gleam List)
let arr = array.from_list([1, 2, 3])
array.to_list(arr)                                    // [1, 2, 3]
```

---

## Testing In Depth

### gleeunit Basics

Dependencies: `gleam add --dev gleeunit`

Test files go in `test/` directory. Test functions must be `pub` and end with `_test`.

```gleam
// test/my_module_test.gleam
import gleeunit
import gleeunit/should
import my_module

pub fn main() {
  gleeunit.main()
}

pub fn addition_test() {
  my_module.add(2, 3)
  |> should.equal(5)
}

pub fn error_handling_test() {
  my_module.parse("abc")
  |> should.be_error

  my_module.parse("123")
  |> should.be_ok
  |> should.equal(123)
}

pub fn list_operations_test() {
  my_module.filter_adults([
    User("Ada", 36),
    User("Bob", 12),
  ])
  |> should.equal([User("Ada", 36)])
}
```

### Testing Patterns

```gleam
// --- Testing Results ---
pub fn result_ok_test() {
  Ok(42)
  |> should.be_ok
  |> should.equal(42)
}

pub fn result_error_test() {
  Error("bad input")
  |> should.be_error
  |> should.equal("bad input")
}

// --- Testing with setup/teardown ---
pub fn with_temp_file_test() {
  let path = "/tmp/test_" <> int.to_string(erlang.system_time(erlang.Millisecond))
  let assert Ok(_) = simplifile.write(path, "test content")

  // Test
  let assert Ok(content) = simplifile.read(path)
  content |> should.equal("test content")

  // Cleanup
  let assert Ok(_) = simplifile.delete(path)
}

// --- Testing actors ---
pub fn counter_actor_test() {
  let assert Ok(counter) = start_counter()

  process.send(counter, Increment)
  process.send(counter, Increment)
  process.send(counter, Increment)

  let count = process.call(counter, GetCount, 1000)
  count |> should.equal(3)
}

// --- Testing JSON round-trips ---
pub fn json_roundtrip_test() {
  let user = User(id: 1, name: "Ada", email: "ada@test.com")
  let encoded = encode_user(user) |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, user_decoder())
  decoded |> should.equal(user)
}

// --- Negative testing ---
pub fn invalid_email_test() {
  email.parse("not-an-email")
  |> should.be_error
  |> should.equal(InvalidFormat)
}
```

### Property-Based Testing

Use `qcheck_gleeunit_utils` for property-based testing (generates random inputs).

Dependencies: `gleam add --dev qcheck qcheck_gleeunit_utils`

```gleam
import qcheck
import qcheck_gleeunit_utils/run as qcheck_run

pub fn reverse_reverse_is_identity_test() {
  use <- qcheck_run.run_result

  qcheck.run(
    config: qcheck.default_config(),
    generator: qcheck.list(qcheck.int()),
    property: fn(xs) {
      let result = list.reverse(list.reverse(xs))
      result == xs
    },
  )
}

pub fn sort_produces_ordered_list_test() {
  use <- qcheck_run.run_result

  qcheck.run(
    config: qcheck.default_config(),
    generator: qcheck.list(qcheck.int()),
    property: fn(xs) {
      let sorted = list.sort(xs, int.compare)
      is_sorted(sorted)
    },
  )
}

fn is_sorted(xs: List(Int)) -> Bool {
  case xs {
    [] | [_] -> True
    [a, b, ..rest] -> a <= b && is_sorted([b, ..rest])
  }
}
```

---

## JSON Handling

### Encoding

```gleam
import gleam/json

// Primitives
json.string("hello")
json.int(42)
json.float(3.14)
json.bool(True)
json.null()

// Objects
json.object([
  #("key", json.string("value")),
  #("count", json.int(10)),
])

// Arrays
json.array([1, 2, 3], json.int)
json.preprocessed_array([json.string("a"), json.int(1)])

// Nested structures
fn encode_order(order: Order) -> json.Json {
  json.object([
    #("id", json.int(order.id)),
    #("items", json.array(order.items, fn(item) {
      json.object([
        #("name", json.string(item.name)),
        #("price", json.float(item.price)),
        #("quantity", json.int(item.quantity)),
      ])
    })),
    #("total", json.float(order.total)),
    #("status", encode_status(order.status)),
  ])
}

fn encode_status(status: OrderStatus) -> json.Json {
  case status {
    Pending -> json.string("pending")
    Shipped -> json.string("shipped")
    Delivered -> json.string("delivered")
  }
}

// Output
json.to_string(encode_order(order))
json.to_string_tree(encode_order(order))  // for response bodies
```

### Decoding

```gleam
import gleam/json
import gleam/dynamic/decode

// Simple decoder
let string_decoder = decode.string
let int_decoder = decode.int

// Object decoder
fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(User(id: id, name: name, email: email))
}

// Parse JSON string
json.parse("{\"id\":1,\"name\":\"Ada\",\"email\":\"ada@example.com\"}", user_decoder())
// Ok(User(id: 1, name: "Ada", email: "ada@example.com"))
```

### Complex Decoders

```gleam
import gleam/dynamic/decode

// Optional fields
fn user_with_optional_decoder() -> decode.Decoder(UserProfile) {
  use name <- decode.field("name", decode.string)
  use bio <- decode.optional_field("bio", "", decode.string)
  use age <- decode.optional_field("age", 0, decode.int)
  decode.success(UserProfile(name: name, bio: bio, age: age))
}

// List fields
fn team_decoder() -> decode.Decoder(Team) {
  use name <- decode.field("name", decode.string)
  use members <- decode.field("members", decode.list(decode.string))
  decode.success(Team(name: name, members: members))
}

// Nested objects
fn order_decoder() -> decode.Decoder(Order) {
  use id <- decode.field("id", decode.int)
  use customer <- decode.field("customer", user_decoder())
  use items <- decode.field("items", decode.list(item_decoder()))
  decode.success(Order(id: id, customer: customer, items: items))
}

// Enum / tagged union decoding
fn status_decoder() -> decode.Decoder(Status) {
  use value <- decode.then(decode.string)
  case value {
    "pending" -> decode.success(Pending)
    "active" -> decode.success(Active)
    "closed" -> decode.success(Closed)
    _ -> decode.failure(Pending, "Status")
  }
}

// One-of (try multiple decoders)
fn flexible_id_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.string, [
    decode.int |> decode.map(int.to_string),
  ])
}
```

---

## File I/O with simplifile

Dependencies: `gleam add simplifile`

```gleam
import simplifile

// Read
let assert Ok(content) = simplifile.read("config.txt")

// Write (creates or overwrites)
let assert Ok(_) = simplifile.write("output.txt", "Hello, world!")

// Append
let assert Ok(_) = simplifile.append("log.txt", "New log entry\n")

// Read/write bit arrays (binary files)
let assert Ok(bytes) = simplifile.read_bits("image.png")
let assert Ok(_) = simplifile.write_bits("copy.png", bytes)

// Directory operations
let assert Ok(_) = simplifile.create_directory("new_dir")
let assert Ok(_) = simplifile.create_directory_all("path/to/nested/dir")
let assert Ok(files) = simplifile.read_directory("src")  // List(String)

// File info
let assert Ok(True) = simplifile.is_file("config.txt")
let assert Ok(True) = simplifile.is_directory("src")
let assert Ok(info) = simplifile.file_info("myfile.txt")
// info.size, info.atime, info.mtime, info.ctime

// Delete
let assert Ok(_) = simplifile.delete("temp.txt")
let assert Ok(_) = simplifile.delete_all(["tmp1.txt", "tmp2.txt"])

// Copy and rename
let assert Ok(_) = simplifile.copy_file("src.txt", "dst.txt")
let assert Ok(_) = simplifile.rename_file("old.txt", "new.txt")
```

---

## Environment Variables and Configuration

```gleam
import gleam/erlang/os

/// Read required env var (crash if missing)
pub fn require_env(name: String) -> String {
  case os.get_env(name) {
    Ok(value) -> value
    Error(_) -> panic as { "Missing required env var: " <> name }
  }
}

/// Configuration from environment
pub type Config {
  Config(
    database_url: String,
    port: Int,
    secret_key: String,
    log_level: String,
    environment: String,
  )
}

pub fn load_config() -> Config {
  Config(
    database_url: require_env("DATABASE_URL"),
    port: os.get_env("PORT")
      |> result.try(int.parse)
      |> result.unwrap(8000),
    secret_key: require_env("SECRET_KEY"),
    log_level: os.get_env("LOG_LEVEL") |> result.unwrap("info"),
    environment: os.get_env("GLEAM_ENV") |> result.unwrap("development"),
  )
}

/// dotenv-style loading (using dot_env package)
// gleam add dot_env
import dot_env

pub fn main() {
  dot_env.load()  // Loads .env file into environment
  let config = load_config()
  start_server(config)
}
```

---

## FFI Patterns

### Erlang FFI

Erlang FFI functions reference an Erlang module and function name.

```gleam
// --- Direct external functions ---
// Reference an existing Erlang module function:
@external(erlang, "erlang", "system_time")
pub fn system_time() -> Int

// Reference OTP modules:
@external(erlang, "timer", "sleep")
pub fn sleep(ms: Int) -> Atom

// With specific arity matching:
@external(erlang, "lists", "keyfind")
fn keyfind(key: a, pos: Int, list: List(b)) -> Dynamic

// --- Custom Erlang module ---
// Create src/app/my_ffi.erl for custom logic:

// src/app/my_ffi.erl
// -module(my_ffi).
// -export([hash_password/1, verify_password/2]).
//
// hash_password(Password) ->
//     Salt = crypto:strong_rand_bytes(16),
//     Hash = crypto:hash(sha256, <<Salt/binary, Password/binary>>),
//     {Salt, Hash}.
//
// verify_password(Password, {Salt, ExpectedHash}) ->
//     Hash = crypto:hash(sha256, <<Salt/binary, Password/binary>>),
//     Hash =:= ExpectedHash.

// src/app/crypto.gleam
@external(erlang, "my_ffi", "hash_password")
pub fn hash_password(password: String) -> #(BitArray, BitArray)

@external(erlang, "my_ffi", "verify_password")
pub fn verify_password(
  password: String,
  hash: #(BitArray, BitArray),
) -> Bool
```

### JavaScript FFI

JavaScript FFI references a `.mjs` file relative to the Gleam source file.

```gleam
// src/app/browser.gleam
@external(javascript, "./browser_ffi.mjs", "getLocalStorage")
pub fn get_local_storage(key: String) -> Result(String, Nil)

@external(javascript, "./browser_ffi.mjs", "setLocalStorage")
pub fn set_local_storage(key: String, value: String) -> Nil

@external(javascript, "./browser_ffi.mjs", "getCurrentUrl")
pub fn get_current_url() -> String
```

```javascript
// src/app/browser_ffi.mjs
import { Ok, Error } from "../gleam.mjs";

export function getLocalStorage(key) {
  const value = globalThis.localStorage?.getItem(key);
  if (value === null || value === undefined) {
    return new Error(undefined);
  }
  return new Ok(value);
}

export function setLocalStorage(key, value) {
  globalThis.localStorage?.setItem(key, value);
  return undefined;  // Nil
}

export function getCurrentUrl() {
  return globalThis.location?.href ?? "";
}
```

**Important JS FFI conventions:**
- File must be `.mjs` (ES modules)
- Path is relative to the Gleam source file
- Import Gleam types from `../gleam.mjs` (or appropriate path)
- `Ok` and `Error` are classes that must be constructed with `new`
- `Nil` is represented as `undefined`
- `List` is a linked list — use `toList()` from gleam.mjs to construct
- `Bool` maps to JS `true`/`false`

### Dual-Target FFI

Provide both Erlang and JavaScript implementations for cross-target packages.

```gleam
// src/app/time.gleam
@external(erlang, "os", "system_time")
@external(javascript, "./time_ffi.mjs", "systemTime")
pub fn system_time_ms() -> Int

@external(erlang, "timer", "sleep")
@external(javascript, "./time_ffi.mjs", "sleep")
pub fn sleep(ms: Int) -> Nil
```

```javascript
// src/app/time_ffi.mjs
export function systemTime() {
  return Date.now();
}

export function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}
```

### FFI Best Practices

1. **Minimize FFI surface area.** Write a thin FFI layer and build Gleam wrappers.
2. **Type annotations are trusted, not verified.** Ensure Erlang/JS types match.
3. **Wrap in Result.** Convert nullable/throwing code to `Result` at the boundary.
4. **Keep FFI files small.** One file per concern, not one giant ffi file.
5. **Test FFI functions.** They're the most likely source of runtime errors.
6. **Document target requirements.** Mark modules as Erlang-only or JS-only.

```gleam
// Good: Thin FFI + Gleam wrapper
@external(erlang, "my_ffi", "unsafe_parse")
fn do_parse(input: String) -> Dynamic

pub fn parse(input: String) -> Result(MyType, ParseError) {
  do_parse(input)
  |> decode.run(my_decoder())
  |> result.map_error(fn(_) { ParseError })
}
```

---

## Publishing Packages to Hex

Gleam packages are published to [Hex](https://hex.pm), the Erlang/Elixir package registry.

### Prerequisites

1. Create a Hex account at https://hex.pm
2. Ensure your `gleam.toml` has required fields

### gleam.toml for Publishing

```toml
name = "my_package"
version = "1.0.0"
description = "A helpful description of your package"

# Required for publishing
licences = ["Apache-2.0"]
repository = { type = "github", user = "username", repo = "my_package" }

# Optional
links = [
  { title = "Website", href = "https://example.com" },
]
gleam = ">= 1.0.0"
# Leaving target blank means it works on both
# target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.60.0 and < 2.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
```

### Publishing Commands

```sh
# Build and verify everything is OK
gleam build
gleam test

# Format check
gleam format --check

# Publish (interactive — asks for confirmation)
gleam publish

# First time: will prompt for Hex credentials
# Subsequent: uses stored credentials

# Retire a version (mark as not recommended)
gleam hex retire my_package 1.0.0 invalid --message "Use 2.0.0 instead"

# Unretire
gleam hex unretire my_package 1.0.0
```

### Publishing Checklist

1. ✅ All tests pass: `gleam test`
2. ✅ Code is formatted: `gleam format --check`
3. ✅ Version is updated in `gleam.toml`
4. ✅ `description`, `licences`, and `repository` are set
5. ✅ CHANGELOG.md is updated
6. ✅ Documentation is written (doc comments with `///`)
7. ✅ If dual-target, test both: `gleam test --target erlang && gleam test --target javascript`
8. ✅ Git tag matches version: `git tag v1.0.0`

### Documentation Comments

```gleam
/// Creates a new user with the given name and email.
///
/// ## Examples
///
/// ```gleam
/// let user = create_user("Ada", "ada@example.com")
/// user.name
/// // -> "Ada"
/// ```
///
pub fn create_user(name: String, email: String) -> User {
  User(name: name, email: email)
}
```

Docs are automatically published to [HexDocs](https://hexdocs.pm) when you
publish your package.
