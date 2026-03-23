#!/usr/bin/env bash
# new-gleam-web.sh — Scaffold a Gleam web project with Wisp + Mist + common dependencies
#
# Usage:
#   ./new-gleam-web.sh myapp              # Create web project named "myapp"
#   ./new-gleam-web.sh myapp --with-db    # Include database dependencies (gleam_pgo, sqlight)
#   ./new-gleam-web.sh myapp --with-auth  # Include auth-related deps (gleam_crypto)
#   ./new-gleam-web.sh myapp --full       # Include all optional dependencies
#
# Creates a Gleam project pre-configured for web development with:
#   - wisp (web framework)
#   - mist (HTTP server)
#   - gleam_http, gleam_json, gleam_erlang
#   - Structured directory layout (router, handlers, middleware)

set -euo pipefail

WITH_DB=false
WITH_AUTH=false
PROJECT_NAME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-db)   WITH_DB=true; shift ;;
    --with-auth) WITH_AUTH=true; shift ;;
    --full)      WITH_DB=true; WITH_AUTH=true; shift ;;
    -h|--help)   head -12 "$0" | tail -10; exit 0 ;;
    -*)          echo "Unknown option: $1" >&2; exit 1 ;;
    *)           PROJECT_NAME="$1"; shift ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Usage: $0 <project-name> [--with-db] [--with-auth] [--full]" >&2
  exit 1
fi

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# Check prerequisites
command -v gleam &>/dev/null || error "Gleam is not installed. Run setup-gleam.sh first."

# ── Create Project ─────────────────────────────────────────────────────────────
info "Creating Gleam web project: $PROJECT_NAME"
gleam new "$PROJECT_NAME"
cd "$PROJECT_NAME"

# ── Add Dependencies ──────────────────────────────────────────────────────────
info "Adding web dependencies..."
gleam add wisp mist gleam_http gleam_json gleam_erlang

if $WITH_DB; then
  info "Adding database dependencies..."
  gleam add gleam_pgo sqlight
fi

if $WITH_AUTH; then
  info "Adding auth dependencies..."
  gleam add gleam_crypto
fi

# ── Create Directory Structure ────────────────────────────────────────────────
info "Creating project structure..."
mkdir -p src/"${PROJECT_NAME}"/web
mkdir -p src/"${PROJECT_NAME}"/models
mkdir -p test

# ── Main Entry Point ──────────────────────────────────────────────────────────
cat > src/"${PROJECT_NAME}".gleam << 'GLEAM'
import gleam/erlang/process
import mist
import wisp
import wisp/wisp_mist

import APP_NAME/router

pub fn main() {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let assert Ok(_) =
    wisp_mist.handler(router.handle_request, secret_key_base)
    |> mist.new
    |> mist.port(8000)
    |> mist.start_http

  wisp.log_info("Server started on http://localhost:8000")
  process.sleep_forever()
}
GLEAM
# Replace APP_NAME with actual project name
sed -i "s/APP_NAME/${PROJECT_NAME}/g" src/"${PROJECT_NAME}".gleam

# ── Router ────────────────────────────────────────────────────────────────────
cat > src/"${PROJECT_NAME}"/router.gleam << 'GLEAM'
import gleam/http.{Get, Post}
import gleam/json
import wisp.{type Request, type Response}

pub fn handle_request(req: Request) -> Response {
  use req <- middleware(req)

  case wisp.path_segments(req) {
    [] -> home(req)
    ["health"] -> health(req)
    ["api", ..rest] -> handle_api(req, rest)
    _ -> wisp.not_found()
  }
}

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

fn home(req: Request) -> Response {
  case req.method {
    Get ->
      wisp.ok()
      |> wisp.string_body("Welcome! Visit /health to check status.")
    _ -> wisp.method_not_allowed([Get])
  }
}

fn health(_req: Request) -> Response {
  wisp.ok()
  |> wisp.json_body(json.to_string_tree(
    json.object([#("status", json.string("ok"))]),
  ))
}

fn handle_api(req: Request, path: List(String)) -> Response {
  case path {
    ["hello"] ->
      case req.method {
        Get ->
          wisp.ok()
          |> wisp.json_body(json.to_string_tree(
            json.object([#("message", json.string("Hello from Gleam!"))]),
          ))
        _ -> wisp.method_not_allowed([Get])
      }
    _ -> wisp.not_found()
  }
}
GLEAM

# ── Test File ─────────────────────────────────────────────────────────────────
cat > test/"${PROJECT_NAME}"_test.gleam << GLEAM
import gleeunit
import gleeunit/should
import ${PROJECT_NAME}

pub fn main() {
  gleeunit.main()
}

pub fn hello_world_test() {
  1 |> should.equal(1)
}
GLEAM

# ── .env.example ──────────────────────────────────────────────────────────────
cat > .env.example << 'ENV'
# Server
PORT=8000
SECRET_KEY_BASE=change_me_to_a_random_64_char_string

# Database (if using --with-db)
# DATABASE_URL=postgres://user:pass@localhost:5432/myapp

# Environment
GLEAM_ENV=development
ENV

# ── .gitignore additions ──────────────────────────────────────────────────────
cat >> .gitignore << 'IGNORE'

# Environment
.env
*.env.local

# Editor
.vscode/
.idea/
IGNORE

# ── Build and Verify ─────────────────────────────────────────────────────────
info "Building project..."
gleam build

info "Running tests..."
gleam test

# ── Done ──────────────────────────────────────────────────────────────────────
ok "Web project '$PROJECT_NAME' created!"
echo ""
echo "  cd $PROJECT_NAME"
echo "  gleam run                # Start server on :8000"
echo "  curl localhost:8000      # Test the server"
echo "  curl localhost:8000/health"
echo "  curl localhost:8000/api/hello"
echo ""
echo "Project structure:"
find src -name '*.gleam' | sort | sed 's/^/  /'
