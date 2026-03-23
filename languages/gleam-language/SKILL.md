---
name: gleam-language
description: >
  Use this skill when writing, editing, debugging, or reviewing Gleam (.gleam) code,
  creating Gleam projects, working with gleam.toml, using gleam CLI commands (gleam new,
  gleam build, gleam run, gleam test, gleam add), writing code for the BEAM/Erlang VM or
  JavaScript targets, using Gleam libraries (gleam_stdlib, gleam_otp, gleam_http, gleam_json,
  wisp, lustre, mist), or doing Erlang/Elixir/JavaScript FFI from Gleam. Triggers on any
  mention of Gleam language, .gleam files, gleam.toml, Hex packages in Gleam context,
  gleam_erlang, gleam_otp actors/supervisors, Wisp web framework, Lustre frontend framework,
  or mist HTTP server. Do NOT use for Erlang, Elixir, or JavaScript code that does not
  involve Gleam. Do NOT use for other BEAM languages unless Gleam interop is explicitly
  involved. Do NOT use for general functional programming questions unrelated to Gleam.
---

# Gleam Language Skill

Gleam is a statically-typed functional language compiling to Erlang (BEAM) and JavaScript.
All data is immutable. No nulls, no exceptions. Errors are values via `Result` type.

## Syntax Fundamentals

```gleam
// Variables and constants
let name = "Gleam"           // immutable binding, type inferred
let age: Int = 1             // explicit annotation
const max_size = 100         // module-level constant

// Basic types: Int, Float, String, Bool, List(a), BitArray, Nil
let greeting = "Hello, " <> "world!"   // string concat with <>
let numbers = [1, 2, 3]
let pair = #("key", 42)                // tuple

// Functions with labelled arguments
pub fn greet(name n: String, greeting g: String) -> String {
  g <> ", " <> n <> "!"
}
greet(greeting: "Hi", name: "Lucy")    // labels allow any order

// Anonymous functions and captures
let add = fn(a, b) { a + b }
let add_one = int.add(1, _)            // partial application shorthand

// Pipe operator: value pipes into first argument
"hello" |> string.uppercase |> string.append(", WORLD!")
// => "HELLO, WORLD!"

// Blocks are expressions; last expression is the value
let value = { let x = 1  let y = 2  x + y }  // value = 3
```

Last expression is the return value. No `return` keyword. No early returns.

## Type System

### Custom Types (Algebraic Data Types)

```gleam
pub type User { User(name: String, age: Int) }          // record
pub type Color { Red  Green  Blue  Custom(r: Int, g: Int, b: Int) }  // enum

let user = User(name: "Ada", age: 36)
user.name  // => "Ada"
```

### Generics

```gleam
pub type Box(inner) { Box(value: inner) }
pub fn unwrap(box: Box(a)) -> a { box.value }
let int_box = Box(42)        // Box(Int)
```

### Result Type

Primary error handling mechanism. No exceptions.

```gleam
// Result(value, error) = Ok(value) | Error(error)
pub type FileError { NotFound  PermissionDenied }

pub fn read_file(path: String) -> Result(String, FileError) {
  case path {
    "exists.txt" -> Ok("file contents")
    _ -> Error(NotFound)
  }
}
```

### Option Pattern

No built-in `Option`. Use `gleam/option.Option(a)` or `Result(a, Nil)`.

```gleam
import gleam/option.{type Option, None, Some}
pub fn find_user(id: Int) -> Option(User) {
  case id { 1 -> Some(User("Ada", 36))  _ -> None }
}
```

Type aliases: `pub type Headers = List(#(String, String))`

## Pattern Matching

Exhaustive matching required. Compiler errors on missing variants.

```gleam
// Case expressions
case color {
  Red -> "red"
  Green -> "green"
  Blue -> "blue"
  Custom(r, _, _) -> "rgb(" <> int.to_string(r) <> ")"
}

// Multiple subjects
case x, y {
  0, 0 -> "origin"
  0, _ -> "y-axis"
  _, _ -> "elsewhere"
}

// Guards
case temperature {
  t if t > 35 -> "hot"
  t if t > 15 -> "warm"
  _ -> "cold"
}

// String prefix matching
case greeting { "Hello, " <> name -> name  _ -> "stranger" }

// Let assert (panics on mismatch — use only when failure is a bug)
let assert Ok(value) = might_fail()

// Destructuring in let
let User(name: name, age: _) = user
let #(first, second) = pair
let [head, ..tail] = non_empty_list
```

## Error Handling

### Result Chaining with use

`use` flattens nested callbacks. The callback body becomes the rest of the function.

```gleam
// Without use (nested)                    // With use (flat)
pub fn process() {                          pub fn process() {
  case step_one() {                           use a <- result.try(step_one())
    Error(e) -> Error(e)                      use b <- result.try(step_two(a))
    Ok(a) -> case step_two(a) {               Ok(format(b))
      Error(e) -> Error(e)                  }
      Ok(b) -> Ok(format(b))
    }
  }
}
```

### Result Module Helpers

```gleam
import gleam/result
result.map(Ok(1), fn(x) { x + 1 })          // Ok(2)
result.unwrap(Ok(1), 0)                       // 1
result.try(Ok(1), fn(x) { Ok(x + 1) })      // Ok(2)
result.all([Ok(1), Ok(2)])                    // Ok([1, 2])
result.all([Ok(1), Error("e")])              // Error("e")
```

### Bool Guards

```gleam
import gleam/bool
pub fn divide(a: Float, b: Float) -> Result(Float, String) {
  use <- bool.guard(when: b == 0.0, return: Error("division by zero"))
  Ok(a /. b)
}
```

## Modules and Imports

One file = one module. Path determines name: `src/app/user.gleam` → `app/user`.

```gleam
import gleam/io                          // import module
import gleam/string.{uppercase}          // import specific function
import gleam/int as integer              // aliased import
import app/user.{type User, User}       // import type + constructor
string.length("hello")                  // qualified access
uppercase("hello")                      // unqualified (after import)
```

`pub` = public. No `pub` = module-private. `pub opaque type` = type exported, constructors hidden.

## Project Setup

```sh
gleam new my_app                 # create project (or --template lib)
cd my_app && gleam build         # compile
gleam run                        # run main
gleam test                       # run tests
gleam format                     # format all .gleam files
gleam add gleam_json             # add dependency (updates gleam.toml)
gleam add --dev gleeunit         # add dev dependency
gleam deps download              # fetch all deps
gleam deps update                # upgrade to latest allowed
```

Structure: `gleam.toml` at root, `src/` for code, `test/` for tests, `build/` for output.

```toml
# gleam.toml
name = "my_app"
version = "1.0.0"
target = "erlang"   # or "javascript"

[dependencies]
gleam_stdlib = ">= 0.60.0 and < 2.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
```

## Targets

Compile to Erlang (default) or JavaScript. Set in gleam.toml or CLI flags.

```sh
gleam build --target javascript
gleam run --target javascript    # run on Node.js
```

Some packages are target-specific: `gleam_otp` requires Erlang, `lustre` works on both.

## Testing

Uses `gleeunit` (default). Test files in `test/`. Functions must be `pub` and end with `_test`.

```gleam
// test/my_app_test.gleam
import gleeunit
import gleeunit/should
import my_app

pub fn main() { gleeunit.main() }

pub fn hello_world_test() {
  my_app.hello_world() |> should.equal("Hello, world!")
}

pub fn error_test() {
  my_app.divide(1.0, 0.0) |> should.be_error
}
```

## OTP / Concurrency (Erlang Target Only)

Requires `gleam add gleam_otp gleam_erlang`.

### Processes

```gleam
import gleam/erlang/process
let subject = process.new_subject()
process.start(fn() { process.send(subject, "hello") }, linked: True)
let assert Ok(msg) = process.receive(subject, within: 1000)
```

### Actors (gen_server equivalent)

```gleam
import gleam/otp/actor

pub type Msg {
  Increment
  GetCount(reply_with: process.Subject(Int))
}

fn handle_message(message: Msg, count: Int) -> actor.Next(Msg, Int) {
  case message {
    Increment -> actor.continue(count + 1)
    GetCount(client) -> {
      process.send(client, count)
      actor.continue(count)
    }
  }
}

// Start and interact
let assert Ok(counter) = actor.start(0, handle_message)
process.send(counter, Increment)
process.send(counter, Increment)
let count = process.call(counter, GetCount, 1000)  // => 2
```

### Supervisors

```gleam
import gleam/otp/supervisor
supervisor.start(fn(children) {
  children |> supervisor.add(supervisor.worker(fn(_) { start_counter() }))
})
```

## Web Development

### Wisp (Backend) — `gleam add wisp mist gleam_http gleam_erlang`

```gleam
import wisp.{type Request, type Response}
import mist
import wisp/wisp_mist
import gleam/erlang/process

pub fn main() {
  wisp.configure_logger()
  let secret = wisp.random_string(64)
  let assert Ok(_) =
    wisp_mist.handler(handle_request, secret)
    |> mist.new |> mist.port(8000) |> mist.start_http
  process.sleep_forever()
}

fn handle_request(req: Request) -> Response {
  case wisp.path_segments(req) {
    [] -> wisp.ok() |> wisp.string_body("Hello!")
    ["users", id] -> wisp.ok() |> wisp.string_body("User: " <> id)
    _ -> wisp.not_found()
  }
}
```

### Lustre (Frontend, Elm-style) — `gleam add lustre`

```gleam
import lustre
import lustre/element.{text}
import lustre/element/html.{button, div, p}
import lustre/event.{on_click}

pub type Msg { Incr  Decr }

pub fn main() {
  let app = lustre.simple(fn(_) { 0 }, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
}

fn update(model: Int, msg: Msg) -> Int {
  case msg { Incr -> model + 1  Decr -> model - 1 }
}

fn view(model: Int) {
  div([], [
    button([on_click(Decr)], [text("-")]),
    p([], [text(int.to_string(model))]),
    button([on_click(Incr)], [text("+")]),
  ])
}
```

## FFI (Foreign Function Interface)

```gleam
// Erlang FFI — call Erlang's lists:reverse/1
@external(erlang, "lists", "reverse")
pub fn reverse_list(items: List(a)) -> List(a)

// JavaScript FFI — reference a .mjs file relative to the Gleam source
@external(javascript, "./app_ffi.mjs", "readFile")
pub fn read_file(path: String) -> String

// Dual-target: provide both, correct one selected by compile target
@external(erlang, "calendar", "local_time")
@external(javascript, "./time_ffi.mjs", "now")
pub fn current_time() -> #(#(Int, Int, Int), #(Int, Int, Int))
```

```javascript
// src/app/app_ffi.mjs
import fs from "fs";
export function readFile(path) { return fs.readFileSync(path, "utf8"); }
```

Type annotations on externals are trusted, not checked. Mismatches cause runtime errors.

## Common Patterns

### Pipeline Style — data-first, transform-chain

```gleam
pub fn process_names(names: List(String)) -> List(String) {
  names
  |> list.map(string.trim)
  |> list.filter(fn(n) { n != "" })
  |> list.map(string.uppercase)
  |> list.sort(string.compare)
}
```

### Builder Pattern with Record Update

```gleam
pub type Config { Config(host: String, port: Int, debug: Bool) }
pub fn default() -> Config { Config(host: "localhost", port: 8080, debug: False) }
pub fn with_port(config: Config, port: Int) -> Config { Config(..config, port: port) }
pub fn with_debug(config: Config, debug: Bool) -> Config { Config(..config, debug: debug) }

let config = default() |> with_port(3000) |> with_debug(True)
let updated_user = User(..user, name: "New Name")  // record update syntax
```

## Key Ecosystem Packages

| Package | Purpose |
|---------|---------|
| `gleam_stdlib` | Core data structures, string, list, result, option, dict, io |
| `gleam_erlang` | Erlang-specific: processes, atoms, OS interaction |
| `gleam_otp` | Actors, supervisors, tasks (Erlang target) |
| `gleam_http` | HTTP request/response types |
| `gleam_json` | JSON encoding/decoding |
| `wisp` | Backend web framework |
| `mist` | HTTP server (BEAM) |
| `lustre` | Frontend framework (Elm architecture) |
| `gleeunit` | Test runner |
| `gleam_crypto` | Hashing, HMAC, encryption |
| `sqlight` | SQLite bindings |
| `gleam_pgo` | PostgreSQL client |

## Common Pitfalls

1. **No implicit returns or early returns.** Last expression is the value. Structure logic with `case` and `use`.
2. **No variable mutation.** Use recursion or `list.fold` instead of loops.
3. **No `if/else`.** Use `case Bool { True -> ... False -> ... }` or `bool.guard`.
4. **String concatenation is `<>`, not `+`.** `+` is only for numbers.
5. **Float ops use different operators.** `+.` `-.` `*.` `/.` for floats, `+` `-` `*` `/` for ints.
6. **Exhaustive matching enforced.** Every `case` must handle all variants or use `_` wildcard.
7. **No methods on types.** Use module functions: `string.length(s)` not `s.length()`.
8. **Field access works but no method chaining.** Use pipe `|>` instead.
9. **`let assert` panics on mismatch.** Reserve for truly impossible states, not error handling.
10. **`use` is not `async/await`.** It's callback flattening sugar that works with any function taking a callback as its last argument.
