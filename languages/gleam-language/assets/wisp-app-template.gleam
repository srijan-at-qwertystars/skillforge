// wisp-app-template.gleam — Starter Wisp web application
//
// A complete, runnable Gleam web server with:
//   - Structured routing (home, health, API)
//   - JSON responses
//   - Middleware stack (logging, crash recovery, method override)
//   - Example CRUD endpoint pattern
//
// Dependencies (gleam.toml):
//   wisp, mist, gleam_http, gleam_json, gleam_erlang, gleam_stdlib
//
// Run:
//   gleam run

import gleam/erlang/process
import gleam/http.{Delete, Get, Post, Put}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist
import wisp.{type Request, type Response}
import wisp/wisp_mist

// ── Types ────────────────────────────────────────────────────────────────────

pub type Context {
  Context(static_path: String)
}

pub type Item {
  Item(id: Int, name: String, done: Bool)
}

// ── Entry Point ──────────────────────────────────────────────────────────────

pub fn main() {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)
  let ctx = Context(static_path: "priv/static")

  let handler = fn(req: Request) -> Response { handle_request(req, ctx) }

  let assert Ok(_) =
    wisp_mist.handler(handler, secret_key_base)
    |> mist.new
    |> mist.port(8000)
    |> mist.start_http

  wisp.log_info("Started on http://localhost:8000")
  process.sleep_forever()
}

// ── Router ───────────────────────────────────────────────────────────────────

fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- middleware(req)

  case wisp.path_segments(req) {
    [] -> home(req)
    ["health"] -> health_check(req)
    ["api", "items"] -> items_collection(req)
    ["api", "items", id] -> items_single(req, id)
    _ -> wisp.not_found()
  }
}

// ── Middleware ────────────────────────────────────────────────────────────────

fn middleware(
  req: Request,
  handler: fn(Request) -> Response,
) -> Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  handler(req)
}

// ── Handlers ─────────────────────────────────────────────────────────────────

fn home(req: Request) -> Response {
  case req.method {
    Get ->
      wisp.ok()
      |> wisp.string_body(
        "Gleam Web App — GET /health, GET /api/items",
      )
    _ -> wisp.method_not_allowed([Get])
  }
}

fn health_check(_req: Request) -> Response {
  wisp.ok()
  |> wisp.json_body(json.to_string_tree(
    json.object([
      #("status", json.string("healthy")),
      #("version", json.string("1.0.0")),
    ]),
  ))
}

fn items_collection(req: Request) -> Response {
  case req.method {
    Get -> {
      let items = get_sample_items()
      wisp.ok()
      |> wisp.json_body(json.to_string_tree(
        json.object([
          #("items", json.array(items, encode_item)),
          #("count", json.int(list.length(items))),
        ]),
      ))
    }
    Post -> {
      use body <- wisp.require_string_body(req)
      case json.parse(body, item_decoder()) {
        Ok(item) ->
          wisp.created()
          |> wisp.json_body(json.to_string_tree(encode_item(item)))
        Error(_) ->
          wisp.unprocessable_entity()
          |> wisp.json_body(json.to_string_tree(
            json.object([
              #("error", json.string("Invalid JSON")),
            ]),
          ))
      }
    }
    _ -> wisp.method_not_allowed([Get, Post])
  }
}

fn items_single(req: Request, id_str: String) -> Response {
  case int.parse(id_str) {
    Error(_) -> wisp.bad_request()
    Ok(id) ->
      case req.method {
        Get -> {
          let items = get_sample_items()
          case list.find(items, fn(i) { i.id == id }) {
            Ok(item) ->
              wisp.ok()
              |> wisp.json_body(json.to_string_tree(encode_item(item)))
            Error(_) ->
              wisp.not_found()
              |> wisp.json_body(json.to_string_tree(
                json.object([
                  #("error", json.string("Item not found")),
                ]),
              ))
          }
        }
        Delete ->
          wisp.ok()
          |> wisp.json_body(json.to_string_tree(
            json.object([
              #("deleted", json.int(id)),
            ]),
          ))
        _ -> wisp.method_not_allowed([Get, Delete])
      }
  }
}

// ── JSON Encoding / Decoding ─────────────────────────────────────────────────

fn encode_item(item: Item) -> json.Json {
  json.object([
    #("id", json.int(item.id)),
    #("name", json.string(item.name)),
    #("done", json.bool(item.done)),
  ])
}

import gleam/dynamic/decode

fn item_decoder() -> decode.Decoder(Item) {
  use id <- decode.optional_field("id", 0, decode.int)
  use name <- decode.field("name", decode.string)
  use done <- decode.optional_field("done", False, decode.bool)
  decode.success(Item(id: id, name: name, done: done))
}

// ── Sample Data ──────────────────────────────────────────────────────────────

fn get_sample_items() -> List(Item) {
  [
    Item(id: 1, name: "Learn Gleam", done: True),
    Item(id: 2, name: "Build a web app", done: False),
    Item(id: 3, name: "Deploy to production", done: False),
  ]
}
