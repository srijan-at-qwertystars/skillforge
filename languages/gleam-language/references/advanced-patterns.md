# Advanced Gleam Patterns

## Table of Contents

- [Advanced Type System](#advanced-type-system)
  - [Opaque Types](#opaque-types)
  - [Phantom Types](#phantom-types)
  - [Type Aliases](#type-aliases)
- [Use Expressions for Error Handling](#use-expressions-for-error-handling)
  - [Use with Result](#use-with-result)
  - [Use with Other Patterns](#use-with-other-patterns)
  - [Chaining Multiple Use](#chaining-multiple-use)
- [Builder Pattern with Labeled Arguments](#builder-pattern-with-labeled-arguments)
- [Bit Arrays and Binary Protocol Parsing](#bit-arrays-and-binary-protocol-parsing)
  - [Bit Array Basics](#bit-array-basics)
  - [Binary Protocol Parsing](#binary-protocol-parsing)
  - [Bit Array Patterns in Case](#bit-array-patterns-in-case)
- [Advanced Pattern Matching](#advanced-pattern-matching)
  - [Guards](#guards)
  - [Alternative Patterns](#alternative-patterns)
  - [Nested Pattern Matching](#nested-pattern-matching)
  - [String Prefix Matching](#string-prefix-matching)
  - [As Patterns](#as-patterns)
- [Higher-Order Functions and Function Composition](#higher-order-functions-and-function-composition)
  - [Passing Functions](#passing-functions)
  - [Returning Functions](#returning-functions)
  - [Function Captures](#function-captures)
  - [Composing Pipelines](#composing-pipelines)
- [Concurrency with gleam_otp](#concurrency-with-gleam_otp)
  - [Processes and Subjects](#processes-and-subjects)
  - [Actors](#actors)
  - [Selectors](#selectors)
  - [Supervisors](#supervisors)
  - [Tasks](#tasks)
  - [ETS Tables](#ets-tables)
- [Process Architecture Patterns](#process-architecture-patterns)
  - [Request-Reply](#request-reply)
  - [Pub-Sub](#pub-sub)
  - [Process Registry](#process-registry)
  - [Graceful Shutdown](#graceful-shutdown)

---

## Advanced Type System

### Opaque Types

Opaque types export the type name but hide constructors. Consumers cannot construct
or pattern match on them — only the defining module can. Use for enforcing invariants.

```gleam
// src/email.gleam
pub opaque type Email {
  Email(value: String)
}

pub type EmailError {
  InvalidFormat
  TooLong
}

/// The only way to create an Email — validation guaranteed.
pub fn parse(input: String) -> Result(Email, EmailError) {
  case string.contains(input, "@") {
    False -> Error(InvalidFormat)
    True ->
      case string.length(input) > 254 {
        True -> Error(TooLong)
        False -> Ok(Email(input))
      }
  }
}

/// Safe accessor — the only way to read the inner value.
pub fn to_string(email: Email) -> String {
  email.value
}
```

```gleam
// In another module:
import email.{type Email}

let assert Ok(addr) = email.parse("user@example.com")
email.to_string(addr)  // "user@example.com"
// email.Email("bad")  // Compile error! Constructor is hidden.
```

### Phantom Types

Use type parameters that don't appear in any constructor to encode state at the
type level. The compiler prevents invalid state transitions.

```gleam
/// Phantom type parameters Unvalidated/Validated are never constructed.
pub type Unvalidated
pub type Validated

pub opaque type Form(state) {
  Form(name: String, email: String)
}

/// Only way to create a form — starts Unvalidated.
pub fn new(name: String, email: String) -> Form(Unvalidated) {
  Form(name: name, email: email)
}

/// Transitions from Unvalidated → Validated. Can only be called once.
pub fn validate(form: Form(Unvalidated)) -> Result(Form(Validated), String) {
  case form.name, form.email {
    "", _ -> Error("Name required")
    _, e ->
      case string.contains(e, "@") {
        True -> Ok(Form(name: form.name, email: form.email))
        False -> Error("Invalid email")
      }
  }
}

/// Only accepts validated forms — compile-time guarantee.
pub fn submit(form: Form(Validated)) -> String {
  "Submitted: " <> form.name
}
```

```gleam
// Usage:
let form = new("Ada", "ada@example.com")
// submit(form)  // Compile error! Form(Unvalidated) ≠ Form(Validated)
let assert Ok(valid) = validate(form)
submit(valid)  // Works: Form(Validated)
```

### Type Aliases

Type aliases create shorthand names for complex types. They do not create new
types — they are purely for readability.

```gleam
pub type Headers = List(#(String, String))
pub type Middleware = fn(Request, fn() -> Response) -> Response
pub type Handler = fn(Request) -> Response
pub type JsonResult = Result(json.Json, List(dynamic.DecodeError))

/// Aliases make function signatures clearer:
pub fn add_headers(headers: Headers, response: Response) -> Response {
  // ...
}
```

---

## Use Expressions for Error Handling

### Use with Result

`use` rewrites callback-based code into flat sequential code. The rest of the
function body becomes the callback argument to the right-hand function.

```gleam
import gleam/result

pub fn create_user(
  name: String,
  email_str: String,
) -> Result(User, String) {
  // Each use short-circuits on Error, like Rust's ? operator.
  use email <- result.try(
    email.parse(email_str) |> result.map_error(fn(_) { "Invalid email" }),
  )
  use name <- result.try(validate_name(name))
  use id <- result.try(save_to_db(name, email))
  Ok(User(id: id, name: name, email: email))
}
```

### Use with Other Patterns

`use` works with any function that takes a callback as its last argument.

```gleam
import gleam/bool

/// bool.guard: early return on condition
pub fn divide(a: Float, b: Float) -> Result(Float, String) {
  use <- bool.guard(when: b == 0.0, return: Error("Division by zero"))
  use <- bool.guard(when: a == 0.0, return: Ok(0.0))
  Ok(a /. b)
}

/// bool.lazy_guard: deferred computation
pub fn process(input: String) -> Result(String, String) {
  use <- bool.lazy_guard(when: string.is_empty(input), return: fn() {
    Error("Empty input")
  })
  Ok(string.uppercase(input))
}

/// result.map with use
pub fn get_user_name(id: Int) -> Result(String, DbError) {
  use user <- result.map(find_user(id))
  user.name
}

/// list.map with use
pub fn format_all(items: List(Item)) -> List(String) {
  use item <- list.map(items)
  item.name <> ": " <> int.to_string(item.quantity)
}

/// list.filter with use
pub fn adults(people: List(Person)) -> List(Person) {
  use person <- list.filter(people)
  person.age >= 18
}

/// list.filter_map with use
pub fn parse_ints(strings: List(String)) -> List(Int) {
  use s <- list.filter_map(strings)
  int.parse(s)
}
```

### Chaining Multiple Use

```gleam
pub fn handle_request(req: Request) -> Response {
  // Validate method
  use <- bool.guard(
    when: req.method != http.Post,
    return: wisp.method_not_allowed([http.Post]),
  )
  // Parse body
  use body <- wisp.require_string_body(req)
  // Decode JSON
  use data <- result_to_response(json.decode(body, user_decoder()))
  // Save
  use saved <- result_to_response(db.insert_user(data))
  wisp.created() |> wisp.json_body(encode_user(saved))
}
```

---

## Builder Pattern with Labeled Arguments

Use labeled arguments and pipeline-friendly functions to build configuration
or complex objects step by step.

```gleam
pub type QueryBuilder {
  QueryBuilder(
    table: String,
    conditions: List(String),
    order_by: Option(String),
    limit: Option(Int),
    offset: Int,
  )
}

pub fn from(table: String) -> QueryBuilder {
  QueryBuilder(
    table: table,
    conditions: [],
    order_by: None,
    limit: None,
    offset: 0,
  )
}

pub fn where(query: QueryBuilder, condition: String) -> QueryBuilder {
  QueryBuilder(..query, conditions: [condition, ..query.conditions])
}

pub fn order_by(query: QueryBuilder, field: String) -> QueryBuilder {
  QueryBuilder(..query, order_by: Some(field))
}

pub fn limit(query: QueryBuilder, n: Int) -> QueryBuilder {
  QueryBuilder(..query, limit: Some(n))
}

pub fn offset(query: QueryBuilder, n: Int) -> QueryBuilder {
  QueryBuilder(..query, offset: n)
}

pub fn to_sql(query: QueryBuilder) -> String {
  let base = "SELECT * FROM " <> query.table
  let where_clause = case query.conditions {
    [] -> ""
    conds -> " WHERE " <> string.join(list.reverse(conds), " AND ")
  }
  let order = case query.order_by {
    None -> ""
    Some(field) -> " ORDER BY " <> field
  }
  let lim = case query.limit {
    None -> ""
    Some(n) -> " LIMIT " <> int.to_string(n)
  }
  base <> where_clause <> order <> lim
}

// Usage with pipeline:
let sql =
  from("users")
  |> where("active = true")
  |> where("age > 18")
  |> order_by("name")
  |> limit(10)
  |> to_sql
// "SELECT * FROM users WHERE active = true AND age > 18 ORDER BY name LIMIT 10"
```

---

## Bit Arrays and Binary Protocol Parsing

### Bit Array Basics

Bit arrays represent sequences of bits/bytes. Useful for binary protocols,
file formats, and network packets.

```gleam
// Literal bit arrays
let bytes = <<0, 255, 128>>           // 3 bytes
let hello = <<"Hello":utf8>>          // UTF-8 encoded string
let big = <<1024:16>>                 // 16-bit big-endian integer
let little = <<1024:16-little>>       // 16-bit little-endian
let bits = <<1:1, 0:1, 1:1>>         // individual bits

// Concatenation
let combined = <<bytes:bits, hello:bits>>

// Size and inspection
bit_array.byte_size(bytes)            // 3
bit_array.to_string(<<"Hello":utf8>>) // Ok("Hello")
```

### Binary Protocol Parsing

```gleam
/// Parse a simple network packet:
/// [version:8][type:8][length:16-big][payload:length-bytes][checksum:32]
pub type Packet {
  Packet(version: Int, packet_type: Int, payload: BitArray, checksum: Int)
}

pub fn parse_packet(data: BitArray) -> Result(Packet, String) {
  case data {
    <<
      version:8,
      packet_type:8,
      length:16-big,
      payload:bytes-size(length),
      checksum:32-big,
    >> ->
      Ok(Packet(
        version: version,
        packet_type: packet_type,
        payload: payload,
        checksum: checksum,
      ))
    _ -> Error("Invalid packet format")
  }
}

/// Encode a packet back to binary
pub fn encode_packet(packet: Packet) -> BitArray {
  let payload_size = bit_array.byte_size(packet.payload)
  <<
    packet.version:8,
    packet.packet_type:8,
    payload_size:16-big,
    packet.payload:bits,
    packet.checksum:32-big,
  >>
}
```

### Bit Array Patterns in Case

```gleam
pub fn parse_utf8_codepoint(data: BitArray) -> Result(#(Int, BitArray), Nil) {
  case data {
    // Single byte: 0xxxxxxx
    <<cp:7, rest:bits>> if cp < 128 -> Ok(#(cp, rest))
    // Two bytes: 110xxxxx 10xxxxxx
    <<0b110:3, a:5, 0b10:2, b:6, rest:bits>> ->
      Ok(#(bit_array.shift_left(a, 6) + b, rest))
    _ -> Error(Nil)
  }
}
```

---

## Advanced Pattern Matching

### Guards

Guards add boolean conditions to pattern branches. Only certain expressions
are allowed (comparisons, arithmetic, boolean ops).

```gleam
pub type Category {
  Child
  Teen
  Adult
  Senior
}

pub fn categorize(age: Int) -> Category {
  case age {
    a if a < 0 -> panic as "Negative age"
    a if a < 13 -> Child
    a if a < 18 -> Teen
    a if a < 65 -> Adult
    _ -> Senior
  }
}

pub fn classify_http_status(code: Int) -> String {
  case code {
    c if c >= 200 && c < 300 -> "success"
    c if c >= 300 && c < 400 -> "redirect"
    c if c >= 400 && c < 500 -> "client error"
    c if c >= 500 -> "server error"
    _ -> "informational"
  }
}
```

### Alternative Patterns

Use `|` to match multiple patterns with the same handler. All alternatives
must bind the same variables.

```gleam
pub fn is_weekend(day: Day) -> Bool {
  case day {
    Saturday | Sunday -> True
    Monday | Tuesday | Wednesday | Thursday | Friday -> False
  }
}

pub fn parse_bool(s: String) -> Result(Bool, Nil) {
  case string.lowercase(s) {
    "true" | "yes" | "1" | "on" -> Ok(True)
    "false" | "no" | "0" | "off" -> Ok(False)
    _ -> Error(Nil)
  }
}
```

### Nested Pattern Matching

Destructure deeply nested data in a single case expression.

```gleam
pub type Expr {
  Lit(Int)
  Add(Expr, Expr)
  Mul(Expr, Expr)
  Neg(Expr)
}

pub fn simplify(expr: Expr) -> Expr {
  case expr {
    // Double negation elimination
    Neg(Neg(inner)) -> simplify(inner)
    // Multiplication by zero
    Mul(Lit(0), _) | Mul(_, Lit(0)) -> Lit(0)
    // Multiplication by one
    Mul(Lit(1), other) | Mul(other, Lit(1)) -> simplify(other)
    // Addition of zero
    Add(Lit(0), other) | Add(other, Lit(0)) -> simplify(other)
    // Constant folding
    Add(Lit(a), Lit(b)) -> Lit(a + b)
    Mul(Lit(a), Lit(b)) -> Lit(a * b)
    Neg(Lit(a)) -> Lit(-a)
    // Recurse
    Add(a, b) -> Add(simplify(a), simplify(b))
    Mul(a, b) -> Mul(simplify(a), simplify(b))
    Neg(a) -> Neg(simplify(a))
    other -> other
  }
}
```

### String Prefix Matching

```gleam
pub fn parse_command(input: String) -> Result(Command, String) {
  case string.trim(input) {
    "/help" -> Ok(Help)
    "/quit" -> Ok(Quit)
    "/say " <> message -> Ok(Say(message))
    "/nick " <> name -> Ok(SetNick(name))
    "/" <> unknown -> Error("Unknown command: /" <> unknown)
    text -> Ok(Message(text))
  }
}
```

### As Patterns

Bind a name to the whole value while also destructuring.

```gleam
pub fn process_result(r: Result(Int, String)) -> String {
  case r {
    Ok(n) as _original if n > 100 -> "Big: " <> int.to_string(n)
    Ok(n) -> "Normal: " <> int.to_string(n)
    Error(msg) -> "Error: " <> msg
  }
}
```

---

## Higher-Order Functions and Function Composition

### Passing Functions

```gleam
pub fn apply_twice(f: fn(a) -> a, value: a) -> a {
  f(f(value))
}

apply_twice(fn(x) { x * 2 }, 3)  // 12
apply_twice(string.uppercase, "hi")  // "HI" (already uppercase after first)
```

### Returning Functions

```gleam
/// Create a function that adds a fixed value.
pub fn adder(n: Int) -> fn(Int) -> Int {
  fn(x) { x + n }
}

let add5 = adder(5)
add5(10)  // 15

/// Create a predicate combiner.
pub fn both(
  pred_a: fn(a) -> Bool,
  pred_b: fn(a) -> Bool,
) -> fn(a) -> Bool {
  fn(value) { pred_a(value) && pred_b(value) }
}

let is_adult_named_ada =
  both(fn(u: User) { u.age >= 18 }, fn(u: User) { u.name == "Ada" })
```

### Function Captures

The `_` placeholder creates a new function from a partial application.

```gleam
// These are equivalent:
let add_one = int.add(1, _)
let add_one = fn(x) { int.add(1, x) }

// Useful in pipelines:
[1, 2, 3]
|> list.map(int.multiply(_, 2))     // [2, 4, 6]
|> list.filter(int.is_even)          // [2, 4, 6]
|> list.map(int.to_string)           // ["2", "4", "6"]

// Multi-argument capture fills the first hole:
let greet = string.append("Hello, ", _)
greet("world")  // "Hello, world"
```

### Composing Pipelines

Gleam's pipe operator is the primary composition mechanism.

```gleam
/// Transform pipeline as a reusable function:
pub fn normalize_email(input: String) -> String {
  input
  |> string.trim
  |> string.lowercase
  |> string.replace(each: " ", with: "")
}

/// Combining list operations:
pub fn summarize(orders: List(Order)) -> Summary {
  let total =
    orders
    |> list.filter(fn(o) { o.status == Completed })
    |> list.map(fn(o) { o.amount })
    |> list.fold(0.0, fn(acc, x) { acc +. x })

  let count = list.length(orders)
  Summary(total: total, count: count, average: total /. int.to_float(count))
}
```

---

## Concurrency with gleam_otp

Requires: `gleam add gleam_otp gleam_erlang` (Erlang target only).

### Processes and Subjects

```gleam
import gleam/erlang/process.{type Subject}

/// Subjects are typed mailboxes for inter-process communication.
pub fn spawn_worker() {
  // Create a subject the child will send results to.
  let result_subject: Subject(String) = process.new_subject()

  // Spawn a linked process.
  process.start(
    fn() {
      let result = do_expensive_work()
      process.send(result_subject, result)
    },
    linked: True,
  )

  // Wait for the result (timeout in ms).
  let assert Ok(result) = process.receive(result_subject, within: 5000)
  result
}
```

### Actors

Actors are the Gleam equivalent of `gen_server`. They manage state and handle
messages sequentially, ensuring thread safety.

```gleam
import gleam/otp/actor

pub type CacheMsg {
  Get(key: String, reply_with: Subject(Option(String)))
  Set(key: String, value: String)
  Delete(key: String)
  Clear
}

pub type CacheState = dict.Dict(String, String)

fn handle_cache_message(
  message: CacheMsg,
  state: CacheState,
) -> actor.Next(CacheMsg, CacheState) {
  case message {
    Get(key, client) -> {
      process.send(client, dict.get(state, key) |> option.from_result)
      actor.continue(state)
    }
    Set(key, value) -> {
      actor.continue(dict.insert(state, key, value))
    }
    Delete(key) -> {
      actor.continue(dict.delete(state, key))
    }
    Clear -> {
      actor.continue(dict.new())
    }
  }
}

pub fn start_cache() -> Result(Subject(CacheMsg), actor.StartError) {
  actor.start(dict.new(), handle_cache_message)
}

// Usage:
pub fn main() {
  let assert Ok(cache) = start_cache()
  process.send(cache, Set("key", "value"))
  let result = process.call(cache, Get("key", _), 1000)
  // result == Some("value")
}
```

### Selectors

Selectors allow a process to wait on messages from multiple subjects simultaneously.

```gleam
import gleam/erlang/process.{type Selector}

pub type Event {
  UserEvent(String)
  SystemEvent(String)
  Timeout
}

pub fn wait_for_events(
  user_subject: Subject(String),
  system_subject: Subject(String),
) -> Event {
  let selector: Selector(Event) =
    process.new_selector()
    |> process.selecting(user_subject, UserEvent)
    |> process.selecting(system_subject, SystemEvent)

  // Block until any message arrives (5s timeout).
  case process.select(selector, 5000) {
    Ok(event) -> event
    Error(Nil) -> Timeout
  }
}
```

### Supervisors

Supervisors restart child processes when they crash.

```gleam
import gleam/otp/supervisor

pub fn start_application() {
  supervisor.start(fn(children) {
    children
    |> supervisor.add(supervisor.worker(fn(_arg) {
      start_cache()
    }))
    |> supervisor.add(supervisor.worker(fn(_arg) {
      start_event_logger()
    }))
    |> supervisor.add(supervisor.worker(fn(_arg) {
      start_web_server()
    }))
  })
}
```

### Tasks

Tasks run a function in a separate process and return the result.

```gleam
import gleam/otp/task

pub fn parallel_fetch() {
  let task1 = task.async(fn() { fetch_users() })
  let task2 = task.async(fn() { fetch_orders() })

  let assert Ok(users) = task.try_await(task1, 5000)
  let assert Ok(orders) = task.try_await(task2, 5000)

  #(users, orders)
}
```

### ETS Tables

ETS (Erlang Term Storage) provides concurrent in-memory key-value storage.
Access via Erlang FFI since there is no official Gleam wrapper.

```gleam
// src/app/ets_ffi.erl
-module(ets_ffi).
-export([new/1, insert/3, lookup/2, delete/2]).

new(Name) ->
    ets:new(Name, [named_table, public, set]).

insert(Table, Key, Value) ->
    ets:insert(Table, {Key, Value}),
    nil.

lookup(Table, Key) ->
    case ets:lookup(Table, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, nil}
    end.

delete(Table, Key) ->
    ets:delete(Table, Key),
    nil.
```

```gleam
// src/app/ets.gleam
@external(erlang, "ets_ffi", "new")
pub fn new(name: atom.Atom) -> atom.Atom

@external(erlang, "ets_ffi", "insert")
pub fn insert(table: atom.Atom, key: String, value: String) -> Nil

@external(erlang, "ets_ffi", "lookup")
pub fn lookup(table: atom.Atom, key: String) -> Result(String, Nil)

@external(erlang, "ets_ffi", "delete")
pub fn delete(table: atom.Atom, key: String) -> Nil
```

---

## Process Architecture Patterns

### Request-Reply

The standard pattern for synchronous calls to actors.

```gleam
/// process.call wraps the pattern of:
/// 1. Create a temporary subject
/// 2. Send message with the subject as reply_with
/// 3. Wait for the reply
pub fn get_count(counter: Subject(CounterMsg)) -> Int {
  // process.call handles the subject creation and waiting:
  process.call(counter, fn(reply) { GetCount(reply_with: reply) }, 1000)
}
```

### Pub-Sub

```gleam
pub type PubSubMsg(event) {
  Subscribe(Subject(event))
  Unsubscribe(Subject(event))
  Publish(event)
}

fn handle_pubsub(
  msg: PubSubMsg(event),
  subscribers: List(Subject(event)),
) -> actor.Next(PubSubMsg(event), List(Subject(event))) {
  case msg {
    Subscribe(sub) -> actor.continue([sub, ..subscribers])
    Unsubscribe(sub) -> {
      let remaining = list.filter(subscribers, fn(s) { s != sub })
      actor.continue(remaining)
    }
    Publish(event) -> {
      list.each(subscribers, fn(sub) { process.send(sub, event) })
      actor.continue(subscribers)
    }
  }
}
```

### Process Registry

Register named actors for global access.

```gleam
import gleam/erlang/process
import gleam/erlang/atom

/// Register a subject under a name.
pub fn register(subject: Subject(msg), name: String) -> Result(Nil, Nil) {
  let assert Ok(name_atom) = atom.from_string(name)
  do_register(process.subject_owner(subject), name_atom)
}

@external(erlang, "erlang", "register")
fn do_register(pid: process.Pid, name: atom.Atom) -> Result(Nil, Nil)
```

### Graceful Shutdown

Actors can respond to shutdown signals using `actor.Stop`.

```gleam
pub type WorkerMsg {
  DoWork(String)
  Shutdown
}

fn handle_worker(
  msg: WorkerMsg,
  state: WorkerState,
) -> actor.Next(WorkerMsg, WorkerState) {
  case msg {
    DoWork(item) -> {
      let new_state = process_item(state, item)
      actor.continue(new_state)
    }
    Shutdown -> {
      cleanup(state)
      actor.Stop(process.Normal)
    }
  }
}
```
