# Gleam Web Development

## Table of Contents

- [Wisp Framework](#wisp-framework)
  - [Setup and Basic Server](#setup-and-basic-server)
  - [Routing](#routing)
  - [Request Handling](#request-handling)
  - [Responses](#responses)
  - [Middleware](#middleware)
  - [JSON Handling](#json-handling)
  - [Form Handling](#form-handling)
  - [Static Files](#static-files)
  - [Logging](#logging)
- [Lustre Framework](#lustre-framework)
  - [TEA Architecture](#tea-architecture)
  - [Elements and HTML](#elements-and-html)
  - [Events](#events)
  - [Effects](#effects)
  - [Server Components](#server-components)
  - [Lustre Dev Tools](#lustre-dev-tools)
- [Mist HTTP Server](#mist-http-server)
  - [Basic Setup](#basic-setup)
  - [TLS/HTTPS](#tlshttps)
  - [WebSockets with Mist](#websockets-with-mist)
- [Database Access](#database-access)
  - [PostgreSQL with gleam_pgo](#postgresql-with-gleam_pgo)
  - [SQLite with sqlight](#sqlite-with-sqlight)
  - [Database Patterns](#database-patterns)
- [Authentication Patterns](#authentication-patterns)
  - [Session-Based Auth](#session-based-auth)
  - [Token-Based Auth](#token-based-auth)
- [WebSocket Handling](#websocket-handling)
- [API Design Patterns](#api-design-patterns)
  - [REST API Structure](#rest-api-structure)
  - [Error Responses](#error-responses)
  - [Request Validation](#request-validation)

---

## Wisp Framework

Wisp is the primary backend web framework for Gleam. It provides routing,
middleware, request/response helpers, and integrates with Mist as the HTTP server.

Dependencies: `gleam add wisp mist gleam_http gleam_erlang gleam_json`

### Setup and Basic Server

```gleam
// src/app.gleam
import gleam/erlang/process
import mist
import wisp
import wisp/wisp_mist
import app/router

pub fn main() {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let assert Ok(_) =
    wisp_mist.handler(router.handle_request, secret_key_base)
    |> mist.new
    |> mist.port(8000)
    |> mist.start_http

  process.sleep_forever()
}
```

### Routing

Wisp uses `wisp.path_segments(req)` which returns `List(String)` for pattern matching.
Combine with `req.method` for full routing.

```gleam
// src/app/router.gleam
import gleam/http.{Delete, Get, Post, Put}
import wisp.{type Request, type Response}
import app/web/users
import app/web/posts

pub fn handle_request(req: Request) -> Response {
  // Apply global middleware first
  use req <- middleware(req)

  case wisp.path_segments(req) {
    // Static routes
    [] -> home_page(req)
    ["health"] -> wisp.ok() |> wisp.string_body("ok")

    // Resource routes
    ["api", "users"] -> users.collection(req)
    ["api", "users", id] -> users.single(req, id)
    ["api", "users", id, "posts"] -> posts.by_user(req, id)

    // Nested resources
    ["api", "posts"] -> posts.collection(req)
    ["api", "posts", id] -> posts.single(req, id)

    // Catch-all
    _ -> wisp.not_found()
  }
}

fn home_page(req: Request) -> Response {
  case req.method {
    Get -> wisp.ok() |> wisp.string_body("Welcome to the API")
    _ -> wisp.method_not_allowed([Get])
  }
}

fn middleware(req: Request, handle: fn(Request) -> Response) -> Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  handle(req)
}
```

### Request Handling

```gleam
// src/app/web/users.gleam
import gleam/http.{Delete, Get, Post, Put}
import wisp.{type Request, type Response}

pub fn collection(req: Request) -> Response {
  case req.method {
    Get -> list_users(req)
    Post -> create_user(req)
    _ -> wisp.method_not_allowed([Get, Post])
  }
}

pub fn single(req: Request, id: String) -> Response {
  case req.method {
    Get -> get_user(req, id)
    Put -> update_user(req, id)
    Delete -> delete_user(req, id)
    _ -> wisp.method_not_allowed([Get, Put, Delete])
  }
}

fn list_users(_req: Request) -> Response {
  // Query params
  // let query = wisp.get_query(req)
  // let page = list.find(query, fn(pair) { pair.0 == "page" })
  wisp.ok()
}
```

### Responses

```gleam
import gleam/bytes_tree
import gleam/http/response
import wisp

/// Text responses
fn text_response() -> Response {
  wisp.ok()                                // 200
  |> wisp.string_body("Hello!")
}

/// JSON responses
fn json_response(data: json.Json) -> Response {
  wisp.ok()
  |> wisp.json_body(json.to_string_tree(data))
}

/// Status codes
fn status_responses() {
  wisp.ok()                                // 200
  wisp.created()                           // 201
  wisp.accepted()                          // 202
  wisp.no_content()                        // 204
  wisp.bad_request()                       // 400
  wisp.entity_too_large()                  // 413
  wisp.not_found()                         // 404
  wisp.method_not_allowed([Get, Post])     // 405
  wisp.unprocessable_entity()              // 422
  wisp.internal_server_error()             // 500
}

/// Custom response with headers
fn custom_response() -> Response {
  wisp.response(201)
  |> wisp.set_header("x-request-id", "abc123")
  |> wisp.set_header("content-type", "application/json")
  |> wisp.json_body(json.to_string_tree(json.object([
    #("status", json.string("created")),
  ])))
}

/// Redirect
fn redirect_response() -> Response {
  wisp.redirect("/new-location")           // 303 See Other
}

/// HTML response
fn html_response() -> Response {
  wisp.ok()
  |> wisp.set_header("content-type", "text/html")
  |> wisp.html_body(string_tree.from_string("<h1>Hello</h1>"))
}
```

### Middleware

Middleware in Wisp uses the `use` expression pattern — a function that takes
the request and a continuation.

```gleam
import gleam/http
import wisp.{type Request, type Response}

/// Timing middleware — measure request duration
pub fn with_timing(
  req: Request,
  handler: fn(Request) -> Response,
) -> Response {
  let start = erlang.system_time(erlang.Millisecond)
  let response = handler(req)
  let duration = erlang.system_time(erlang.Millisecond) - start
  response
  |> wisp.set_header(
    "x-response-time",
    int.to_string(duration) <> "ms",
  )
}

/// CORS middleware
pub fn with_cors(
  req: Request,
  handler: fn(Request) -> Response,
) -> Response {
  case req.method {
    http.Options ->
      wisp.ok()
      |> set_cors_headers
    _ ->
      handler(req)
      |> set_cors_headers
  }
}

fn set_cors_headers(resp: Response) -> Response {
  resp
  |> wisp.set_header("access-control-allow-origin", "*")
  |> wisp.set_header("access-control-allow-methods", "GET, POST, PUT, DELETE")
  |> wisp.set_header("access-control-allow-headers", "content-type, authorization")
}

/// Compose middleware in router:
pub fn handle_request(req: Request) -> Response {
  use req <- with_timing(req)
  use req <- with_cors(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  route(req)
}
```

### JSON Handling

```gleam
import gleam/json
import gleam/dynamic/decode

pub type CreateUserRequest {
  CreateUserRequest(name: String, email: String, age: Int)
}

/// Decoder for incoming JSON
fn user_request_decoder() -> decode.Decoder(CreateUserRequest) {
  use name <- decode.field("name", decode.string)
  use email <- decode.field("email", decode.string)
  use age <- decode.field("age", decode.int)
  decode.success(CreateUserRequest(name: name, email: email, age: age))
}

/// Encode outgoing JSON
fn encode_user(user: User) -> json.Json {
  json.object([
    #("id", json.int(user.id)),
    #("name", json.string(user.name)),
    #("email", json.string(user.email)),
  ])
}

/// Full request/response cycle
fn create_user(req: Request) -> Response {
  // Read the body as a string
  use body <- wisp.require_string_body(req)

  // Decode JSON
  let result = json.parse(body, user_request_decoder())
  case result {
    Ok(data) -> {
      // Process and respond
      let user = User(id: 1, name: data.name, email: data.email)
      wisp.created()
      |> wisp.json_body(json.to_string_tree(encode_user(user)))
    }
    Error(_) ->
      wisp.unprocessable_entity()
      |> wisp.json_body(json.to_string_tree(json.object([
        #("error", json.string("Invalid JSON body")),
      ])))
  }
}
```

### Form Handling

```gleam
/// Handle URL-encoded form data
fn handle_form(req: Request) -> Response {
  use formdata <- wisp.require_form(req)

  // formdata.values is List(#(String, String))
  let name =
    list.key_find(formdata.values, "name")
    |> result.unwrap("")
  let email =
    list.key_find(formdata.values, "email")
    |> result.unwrap("")

  // formdata.files is List(#(String, UploadedFile))
  // UploadedFile has .file_name and .path (temp file path)
  let avatar = list.key_find(formdata.files, "avatar")

  wisp.ok() |> wisp.string_body("Received: " <> name)
}
```

### Static Files

```gleam
/// Serve static files from a directory
pub fn handle_request(req: Request) -> Response {
  use <- wisp.serve_static(
    req,
    under: "/static",
    from: static_directory(),
  )
  // If not a static file, continue to routing
  route(req)
}

fn static_directory() -> String {
  let assert Ok(priv) = erlang.priv_directory("my_app")
  priv <> "/static"
}
```

### Logging

```gleam
import wisp

pub fn main() {
  // Configure logger (sets up Erlang logger)
  wisp.configure_logger()

  // Log at different levels
  wisp.log_info("Server starting on port 8000")
  wisp.log_warning("Cache miss for key: " <> key)
  wisp.log_error("Database connection failed")
}
```

---

## Lustre Framework

Lustre is a frontend framework inspired by Elm's The Elm Architecture (TEA).
It compiles to JavaScript and runs in the browser.

Dependencies: `gleam add lustre lustre_http`
Dev tools: `gleam add --dev lustre_dev_tools`

### TEA Architecture

Every Lustre app has three parts: Model (state), Update (state transitions),
View (render).

```gleam
import lustre
import lustre/element.{type Element}

// 1. Model — your application state
pub type Model {
  Model(
    todos: List(Todo),
    input: String,
    filter: Filter,
  )
}

pub type Todo {
  Todo(id: Int, text: String, completed: Bool)
}

pub type Filter {
  All
  Active
  Completed
}

fn init(_flags) -> Model {
  Model(todos: [], input: "", filter: All)
}

// 2. Update — handle messages
pub type Msg {
  UserTyped(String)
  UserPressedEnter
  UserToggledTodo(Int)
  UserDeletedTodo(Int)
  UserSetFilter(Filter)
}

fn update(model: Model, msg: Msg) -> Model {
  case msg {
    UserTyped(text) -> Model(..model, input: text)
    UserPressedEnter -> {
      let id = list.length(model.todos) + 1
      let todo = Todo(id: id, text: model.input, completed: False)
      Model(..model, todos: [todo, ..model.todos], input: "")
    }
    UserToggledTodo(id) -> {
      let todos =
        list.map(model.todos, fn(t) {
          case t.id == id {
            True -> Todo(..t, completed: !t.completed)
            False -> t
          }
        })
      Model(..model, todos: todos)
    }
    UserDeletedTodo(id) -> {
      let todos = list.filter(model.todos, fn(t) { t.id != id })
      Model(..model, todos: todos)
    }
    UserSetFilter(filter) -> Model(..model, filter: filter)
  }
}

// 3. View — render HTML
fn view(model: Model) -> Element(Msg) {
  // ... see Elements section
  html.div([], [])
}

// 4. Start the app
pub fn main() {
  let app = lustre.simple(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
}
```

### Elements and HTML

```gleam
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/attribute.{class, id, type_, value, placeholder}

fn view(model: Model) -> Element(Msg) {
  html.div([class("app")], [
    html.h1([], [text("Todo App")]),
    // Input
    html.input([
      type_("text"),
      value(model.input),
      placeholder("What needs to be done?"),
      event.on_input(UserTyped),
      on_enter(UserPressedEnter),
    ]),
    // Todo list
    html.ul([class("todo-list")],
      model.todos
      |> filter_todos(model.filter)
      |> list.map(view_todo),
    ),
    // Filters
    html.div([class("filters")], [
      filter_button("All", All, model.filter),
      filter_button("Active", Active, model.filter),
      filter_button("Done", Completed, model.filter),
    ]),
  ])
}

fn view_todo(todo: Todo) -> Element(Msg) {
  let cls = case todo.completed {
    True -> "todo completed"
    False -> "todo"
  }
  html.li([class(cls)], [
    html.input([
      type_("checkbox"),
      attribute.checked(todo.completed),
      event.on_check(fn(_) { UserToggledTodo(todo.id) }),
    ]),
    html.span([], [text(todo.text)]),
    html.button([event.on_click(UserDeletedTodo(todo.id))], [text("×")]),
  ])
}
```

### Events

```gleam
import lustre/event

// Built-in event handlers:
event.on_click(Msg)                          // click
event.on_input(fn(String) -> Msg)            // input change
event.on_check(fn(Bool) -> Msg)              // checkbox
event.on_submit(Msg)                         // form submit
event.on("keydown", key_decoder)             // custom event

// Custom event decoder:
fn on_enter(msg: Msg) -> Attribute(Msg) {
  event.on("keydown", fn(event) {
    use key <- result.try(dynamic.field("key", dynamic.string)(event))
    case key {
      "Enter" -> Ok(msg)
      _ -> Error([])
    }
  })
}
```

### Effects

For apps with side effects (HTTP requests, timers), use `lustre.application`
instead of `lustre.simple`.

```gleam
import lustre
import lustre/effect.{type Effect}
import lustre_http

pub type Msg {
  UserClickedFetch
  ApiReturnedUsers(Result(List(User), lustre_http.HttpError))
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(Model(users: [], loading: False), effect.none())
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserClickedFetch -> #(
      Model(..model, loading: True),
      fetch_users(),
    )
    ApiReturnedUsers(Ok(users)) -> #(
      Model(users: users, loading: False),
      effect.none(),
    )
    ApiReturnedUsers(Error(_)) -> #(
      Model(..model, loading: False),
      effect.none(),
    )
  }
}

fn fetch_users() -> Effect(Msg) {
  lustre_http.get(
    "https://api.example.com/users",
    lustre_http.expect_json(users_decoder(), ApiReturnedUsers),
  )
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
}
```

### Server Components

Lustre supports server-side rendering and server components that stream
updates over WebSockets.

```gleam
import lustre
import lustre/element
import lustre/server_component

/// Render a Lustre component to static HTML (SSR)
pub fn render_page(model: Model) -> String {
  view(model)
  |> element.to_string
}

/// Server component — runs on the server, streams patches to client
pub fn start_server_component() {
  let app =
    lustre.application(init, update, view)
    |> lustre.start_server_component(Nil)
  // Returns a Subject for sending messages to the component
  app
}
```

### Lustre Dev Tools

```sh
# Install dev tools
gleam add --dev lustre_dev_tools

# Start dev server with hot reload
gleam run -m lustre/dev start

# Build for production
gleam run -m lustre/dev build
# Outputs to priv/static/

# Bundle the app (uses esbuild)
gleam run -m lustre/dev build --minify
```

---

## Mist HTTP Server

Mist is a pure-Gleam HTTP server built on the BEAM. Wisp uses it under the hood,
but you can use it directly for lower-level control.

### Basic Setup

```gleam
import mist
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/bytes_tree
import gleam/erlang/process

pub fn main() {
  let assert Ok(_) =
    fn(req: Request(mist.Connection)) -> Response(mist.ResponseData) {
      let body = bytes_tree.from_string("Hello from Mist!")
      response.new(200)
      |> response.set_body(mist.Bytes(body))
    }
    |> mist.new
    |> mist.port(3000)
    |> mist.start_http

  process.sleep_forever()
}
```

### TLS/HTTPS

```gleam
let assert Ok(_) =
  handler
  |> mist.new
  |> mist.port(443)
  |> mist.start_https(
    certfile: "/path/to/cert.pem",
    keyfile: "/path/to/key.pem",
  )
```

### WebSockets with Mist

```gleam
import mist.{type WebsocketConnection, type WebsocketMessage}

fn handle_ws_request(
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_conn) {
      // Return initial state and optional selector
      #([], None)
    },
    on_close: fn(_state) { io.println("Client disconnected") },
    handler: fn(state, conn, message) {
      case message {
        mist.Text(text) -> {
          let assert Ok(_) =
            mist.send_text_frame(conn, "Echo: " <> text)
          actor.continue(state)
        }
        mist.Binary(_data) -> actor.continue(state)
        mist.Custom(_) -> actor.continue(state)
        mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
      }
    },
  )
}
```

---

## Database Access

### PostgreSQL with gleam_pgo

Dependencies: `gleam add gleam_pgo`

```gleam
import gleam/pgo
import gleam/dynamic/decode

pub fn connect() -> pgo.Connection {
  pgo.connect(
    pgo.Config(
      ..pgo.default_config(),
      host: "localhost",
      port: 5432,
      database: "myapp",
      user: "postgres",
      password: Some("password"),
      pool_size: 10,
    ),
  )
}

// Query with parameters
pub fn get_user(db: pgo.Connection, id: Int) -> Result(User, String) {
  let sql = "SELECT id, name, email FROM users WHERE id = $1"
  let assert Ok(response) =
    pgo.execute(sql, db, [pgo.int(id)], user_row_decoder())

  case response.rows {
    [user] -> Ok(user)
    [] -> Error("User not found")
    _ -> Error("Multiple users found")
  }
}

fn user_row_decoder() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.int)
  use name <- decode.field(1, decode.string)
  use email <- decode.field(2, decode.string)
  decode.success(User(id: id, name: name, email: email))
}

// Insert
pub fn create_user(
  db: pgo.Connection,
  name: String,
  email: String,
) -> Result(User, String) {
  let sql =
    "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id, name, email"
  let assert Ok(response) =
    pgo.execute(sql, db, [pgo.text(name), pgo.text(email)], user_row_decoder())

  case response.rows {
    [user] -> Ok(user)
    _ -> Error("Insert failed")
  }
}

// Transaction
pub fn transfer_funds(
  db: pgo.Connection,
  from: Int,
  to: Int,
  amount: Float,
) -> Result(Nil, String) {
  pgo.transaction(db, fn(tx) {
    let sql1 = "UPDATE accounts SET balance = balance - $1 WHERE id = $2"
    let assert Ok(_) = pgo.execute(sql1, tx, [pgo.float(amount), pgo.int(from)], decode.success(Nil))

    let sql2 = "UPDATE accounts SET balance = balance + $1 WHERE id = $2"
    let assert Ok(_) = pgo.execute(sql2, tx, [pgo.float(amount), pgo.int(to)], decode.success(Nil))

    Ok(Nil)
  })
  |> result.map_error(fn(_) { "Transaction failed" })
}
```

### SQLite with sqlight

Dependencies: `gleam add sqlight`

```gleam
import sqlight

pub fn main() {
  use db <- sqlight.with_connection("myapp.db")

  // Create table
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE IF NOT EXISTS todos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        completed BOOLEAN DEFAULT FALSE
      )",
      db,
    )

  // Insert
  let assert Ok(_) =
    sqlight.query(
      "INSERT INTO todos (title) VALUES (?)",
      on: db,
      with: [sqlight.text("Buy groceries")],
      expecting: decode.success(Nil),
    )

  // Query
  let assert Ok(todos) =
    sqlight.query(
      "SELECT id, title, completed FROM todos WHERE completed = ?",
      on: db,
      with: [sqlight.bool(False)],
      expecting: {
        use id <- decode.field(0, decode.int)
        use title <- decode.field(1, decode.string)
        use completed <- decode.field(2, decode.bool)
        decode.success(Todo(id: id, title: title, completed: completed))
      },
    )
}
```

### Database Patterns

```gleam
/// Repository pattern — abstract database access behind an interface
pub type UserRepository {
  UserRepository(
    find: fn(Int) -> Result(User, DbError),
    find_all: fn() -> Result(List(User), DbError),
    create: fn(String, String) -> Result(User, DbError),
    update: fn(User) -> Result(User, DbError),
    delete: fn(Int) -> Result(Nil, DbError),
  )
}

/// Create a Postgres-backed repository
pub fn postgres_user_repo(db: pgo.Connection) -> UserRepository {
  UserRepository(
    find: fn(id) { get_user(db, id) },
    find_all: fn() { list_users(db) },
    create: fn(name, email) { create_user(db, name, email) },
    update: fn(user) { update_user(db, user) },
    delete: fn(id) { delete_user(db, id) },
  )
}
```

---

## Authentication Patterns

### Session-Based Auth

```gleam
import gleam/crypto
import wisp.{type Request, type Response}

/// Middleware to require authentication via signed cookies
pub fn require_auth(
  req: Request,
  handler: fn(Request, User) -> Response,
) -> Response {
  case wisp.get_cookie(req, "session_id", wisp.Signed) {
    Ok(session_id) -> {
      case lookup_session(session_id) {
        Ok(user) -> handler(req, user)
        Error(_) -> wisp.redirect("/login")
      }
    }
    Error(_) -> wisp.redirect("/login")
  }
}

/// Login handler
fn handle_login(req: Request) -> Response {
  use formdata <- wisp.require_form(req)
  let assert Ok(email) = list.key_find(formdata.values, "email")
  let assert Ok(password) = list.key_find(formdata.values, "password")

  case authenticate(email, password) {
    Ok(user) -> {
      let session_id = wisp.random_string(32)
      save_session(session_id, user)
      wisp.redirect("/dashboard")
      |> wisp.set_cookie(
        req,
        "session_id",
        session_id,
        wisp.Signed,
        60 * 60 * 24,  // 24 hours
      )
    }
    Error(_) -> wisp.redirect("/login?error=invalid")
  }
}
```

### Token-Based Auth

```gleam
/// Extract Bearer token from Authorization header
pub fn require_bearer_token(
  req: Request,
  handler: fn(Request, String) -> Response,
) -> Response {
  case list.key_find(req.headers, "authorization") {
    Ok(header) ->
      case string.split(header, " ") {
        ["Bearer", token] -> handler(req, token)
        _ -> unauthorized()
      }
    Error(_) -> unauthorized()
  }
}

fn unauthorized() -> Response {
  wisp.response(401)
  |> wisp.set_header("www-authenticate", "Bearer")
  |> wisp.json_body(json.to_string_tree(json.object([
    #("error", json.string("Unauthorized")),
  ])))
}
```

---

## WebSocket Handling

Full WebSocket chat example using Mist directly.

```gleam
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import mist

pub type ChatMsg {
  Join(name: String, conn: mist.WebsocketConnection)
  Leave(name: String)
  Broadcast(from: String, text: String)
}

pub type ClientState {
  ClientState(name: String, room: Subject(ChatMsg))
}

/// WebSocket handler for chat
pub fn handle_websocket(
  req: Request(mist.Connection),
  room: Subject(ChatMsg),
) -> Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(conn) {
      let state = ClientState(name: "anonymous", room: room)
      let selector =
        process.new_selector()
        |> process.selecting_anything(fn(msg) { msg })
      #(state, Some(selector))
    },
    on_close: fn(state) {
      process.send(state.room, Leave(state.name))
    },
    handler: fn(state, conn, message) {
      case message {
        mist.Text(text) -> {
          case string.split(text, ":") {
            ["/name", name] -> {
              let name = string.trim(name)
              process.send(state.room, Join(name, conn))
              actor.continue(ClientState(..state, name: name))
            }
            _ -> {
              process.send(state.room, Broadcast(state.name, text))
              actor.continue(state)
            }
          }
        }
        mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
        _ -> actor.continue(state)
      }
    },
  )
}
```

---

## API Design Patterns

### REST API Structure

Organize your web application with clear separation of concerns.

```
src/
  app.gleam                  # Entry point
  app/
    router.gleam             # Top-level routing
    web/
      users.gleam            # User handlers
      posts.gleam            # Post handlers
      middleware.gleam        # Shared middleware
    models/
      user.gleam             # User type, encoders, decoders
      post.gleam             # Post type, encoders, decoders
    db/
      user_repo.gleam        # User database queries
      post_repo.gleam        # Post database queries
    context.gleam            # Request context (db conn, current user)
```

### Error Responses

```gleam
pub type AppError {
  NotFound(resource: String)
  ValidationError(errors: List(#(String, String)))
  Unauthorized
  Forbidden
  DatabaseError(String)
}

pub fn error_to_response(error: AppError) -> Response {
  case error {
    NotFound(resource) ->
      wisp.not_found()
      |> json_error("Not found: " <> resource)

    ValidationError(errors) ->
      wisp.unprocessable_entity()
      |> wisp.json_body(json.to_string_tree(json.object([
        #("error", json.string("Validation failed")),
        #("details", json.array(errors, fn(pair) {
          json.object([
            #("field", json.string(pair.0)),
            #("message", json.string(pair.1)),
          ])
        })),
      ])))

    Unauthorized ->
      wisp.response(401)
      |> json_error("Unauthorized")

    Forbidden ->
      wisp.response(403)
      |> json_error("Forbidden")

    DatabaseError(msg) -> {
      wisp.log_error("Database error: " <> msg)
      wisp.internal_server_error()
      |> json_error("Internal server error")
    }
  }
}

fn json_error(response: Response, message: String) -> Response {
  response
  |> wisp.json_body(json.to_string_tree(json.object([
    #("error", json.string(message)),
  ])))
}
```

### Request Validation

```gleam
pub type ValidationResult(a) =
  Result(a, List(#(String, String)))

pub fn validate_create_user(
  data: CreateUserRequest,
) -> ValidationResult(CreateUserRequest) {
  let errors = []
  let errors = case string.length(data.name) < 2 {
    True -> [#("name", "Must be at least 2 characters"), ..errors]
    False -> errors
  }
  let errors = case string.contains(data.email, "@") {
    False -> [#("email", "Must be a valid email"), ..errors]
    True -> errors
  }
  let errors = case data.age < 0 || data.age > 150 {
    True -> [#("age", "Must be between 0 and 150"), ..errors]
    False -> errors
  }
  case errors {
    [] -> Ok(data)
    errs -> Error(errs)
  }
}
```
