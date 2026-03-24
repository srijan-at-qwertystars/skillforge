#!/usr/bin/env bash
#
# sveltekit-route-generator.sh
#
# Generates SvelteKit route files from a route path.
# Creates +page.svelte, +page.server.ts, and optionally +layout.svelte
# in the correct directory under src/routes/.
#
# Usage:
#   ./sveltekit-route-generator.sh <route-path> [options]
#
# Options:
#   --layout             Also generate +layout.svelte for this route
#   --layout-server      Also generate +layout.server.ts for this route
#   --server-only        Generate +page.server.ts only (API-like page with form actions)
#   --api                Generate +server.ts (API endpoint) instead of page files
#   --load universal     Use +page.ts (universal load) instead of +page.server.ts
#   --error              Also generate +error.svelte
#   --force              Overwrite existing files
#   --dry-run            Show what would be created without writing
#   --root <dir>         Project root directory (default: current directory)
#   -h, --help           Show this help message
#
# Examples:
#   ./sveltekit-route-generator.sh /blog                    # Basic page route
#   ./sveltekit-route-generator.sh /blog/[slug]             # Dynamic route
#   ./sveltekit-route-generator.sh /dashboard --layout      # With layout
#   ./sveltekit-route-generator.sh /api/users --api         # API endpoint
#   ./sveltekit-route-generator.sh /(app)/settings --layout # Grouped route
#   ./sveltekit-route-generator.sh /docs/[...path]          # Catch-all route
#

set -euo pipefail

# --- Defaults ---
ROUTE_PATH=""
GEN_LAYOUT=false
GEN_LAYOUT_SERVER=false
GEN_ERROR=false
SERVER_ONLY=false
API_MODE=false
UNIVERSAL_LOAD=false
FORCE=false
DRY_RUN=false
PROJECT_ROOT="."

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()      { echo -e "${GREEN}[CREATED]${NC} $*"; }
log_skip()    { echo -e "${YELLOW}[SKIP]${NC} $*"; }
log_dry()     { echo -e "${CYAN}[DRY-RUN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

show_help() {
  head -n 26 "$0" | tail -n 24 | sed 's/^# \?//'
  exit 0
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)         show_help ;;
    --layout)          GEN_LAYOUT=true; shift ;;
    --layout-server)   GEN_LAYOUT_SERVER=true; shift ;;
    --server-only)     SERVER_ONLY=true; shift ;;
    --api)             API_MODE=true; shift ;;
    --error)           GEN_ERROR=true; shift ;;
    --force)           FORCE=true; shift ;;
    --dry-run)         DRY_RUN=true; shift ;;
    --root)            PROJECT_ROOT="$2"; shift 2 ;;
    --load)
      if [[ "$2" == "universal" ]]; then
        UNIVERSAL_LOAD=true
      fi
      shift 2 ;;
    -*)
      log_error "Unknown option: $1"
      exit 1 ;;
    *)
      if [[ -z "$ROUTE_PATH" ]]; then
        ROUTE_PATH="$1"
      else
        log_error "Unexpected argument: $1"
        exit 1
      fi
      shift ;;
  esac
done

if [[ -z "$ROUTE_PATH" ]]; then
  log_error "Route path is required."
  echo "Usage: $0 <route-path> [options]"
  echo "Run $0 --help for details."
  exit 1
fi

# Normalize route path
ROUTE_PATH="${ROUTE_PATH#/}"  # Remove leading slash
ROUTE_PATH="${ROUTE_PATH%/}"  # Remove trailing slash

ROUTES_DIR="$PROJECT_ROOT/src/routes"
TARGET_DIR="$ROUTES_DIR/$ROUTE_PATH"

if [[ ! -d "$ROUTES_DIR" ]]; then
  log_error "Cannot find src/routes/ in '$PROJECT_ROOT'. Is this a SvelteKit project?"
  log_error "Use --root to specify the project root directory."
  exit 1
fi

# --- Helpers ---

# Extract a human-readable page name from the route path
get_page_name() {
  local path="$1"
  local name
  name=$(basename "$path")
  # Remove param brackets and group parentheses
  name=$(echo "$name" | sed 's/\[//g; s/\]//g; s/(//g; s/)//g; s/\.\.\.//g')
  # Capitalize first letter
  name="$(echo "${name:0:1}" | tr '[:lower:]' '[:upper:]')${name:1}"
  echo "$name"
}

# Extract params from route path for load function
get_params() {
  local path="$1"
  echo "$path" | grep -oP '\[([^\]]+)\]' | sed 's/\[//;s/\]//' | grep -v '^\.\.\.' || true
}

get_rest_params() {
  local path="$1"
  echo "$path" | grep -oP '\[\.\.\.(.*?)\]' | sed 's/\[\.\.\.//;s/\]//' || true
}

write_file() {
  local filepath="$1"
  local content="$2"

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would create: $filepath"
    return
  fi

  if [[ -f "$filepath" && "$FORCE" != true ]]; then
    log_skip "Already exists: $filepath (use --force to overwrite)"
    return
  fi

  mkdir -p "$(dirname "$filepath")"
  echo "$content" > "$filepath"
  log_ok "$filepath"
}

# --- Generate Files ---
PAGE_NAME=$(get_page_name "$ROUTE_PATH")
PARAMS=$(get_params "$ROUTE_PATH")
REST_PARAMS=$(get_rest_params "$ROUTE_PATH")

log_info "Generating route: /$ROUTE_PATH"
echo ""

# --- API Mode ---
if [[ "$API_MODE" == true ]]; then
  # Build params access code
  PARAMS_CODE=""
  if [[ -n "$PARAMS" ]]; then
    while IFS= read -r param; do
      [[ -z "$param" ]] && continue
      PARAMS_CODE+="  const ${param} = params.${param};
"
    done <<< "$PARAMS"
  fi

  SERVER_CONTENT="import { json, error } from '@sveltejs/kit';
import type { RequestHandler } from '.\\/\$types';

export const GET: RequestHandler = async ({ url, params, locals }) => {
${PARAMS_CODE}  // TODO: Implement GET handler
  return json({ message: 'OK' });
};

export const POST: RequestHandler = async ({ request, params, locals }) => {
${PARAMS_CODE}  if (!locals.user) error(401, 'Unauthorized');
  const body = await request.json();
  // TODO: Implement POST handler
  return json({ created: true }, { status: 201 });
};

export const PUT: RequestHandler = async ({ request, params, locals }) => {
${PARAMS_CODE}  if (!locals.user) error(401, 'Unauthorized');
  const body = await request.json();
  // TODO: Implement PUT handler
  return json({ updated: true });
};

export const DELETE: RequestHandler = async ({ params, locals }) => {
${PARAMS_CODE}  if (!locals.user) error(401, 'Unauthorized');
  // TODO: Implement DELETE handler
  return new Response(null, { status: 204 });
};"

  write_file "$TARGET_DIR/+server.ts" "$SERVER_CONTENT"
  echo ""
  log_info "API route generated at: $TARGET_DIR/+server.ts"
  exit 0
fi

# --- Page Files ---

# Build params access for load function
LOAD_PARAMS=""
if [[ -n "$PARAMS" ]]; then
  while IFS= read -r param; do
    [[ -z "$param" ]] && continue
    LOAD_PARAMS+="  const ${param} = params.${param};
"
  done <<< "$PARAMS"
fi
if [[ -n "$REST_PARAMS" ]]; then
  while IFS= read -r param; do
    [[ -z "$param" ]] && continue
    LOAD_PARAMS+="  const ${param} = params.${param}; // rest parameter, e.g. 'a/b/c'
"
  done <<< "$REST_PARAMS"
fi

# +page.svelte
PAGE_CONTENT="<script lang=\"ts\">
  let { data } = \$props();
</script>

<svelte:head>
  <title>${PAGE_NAME}</title>
</svelte:head>

<main>
  <h1>${PAGE_NAME}</h1>
  <!-- TODO: Add page content -->
</main>"

write_file "$TARGET_DIR/+page.svelte" "$PAGE_CONTENT"

# +page.server.ts or +page.ts
if [[ "$UNIVERSAL_LOAD" == true ]]; then
  LOAD_CONTENT="import type { PageLoad } from './\$types';

export const load: PageLoad = async ({ params, fetch }) => {
${LOAD_PARAMS}  // TODO: Implement data loading
  return {};
};"
  write_file "$TARGET_DIR/+page.ts" "$LOAD_CONTENT"
else
  SERVER_LOAD_CONTENT="import type { PageServerLoad } from './\$types';
import { error } from '@sveltejs/kit';

export const load: PageServerLoad = async ({ params, locals }) => {
${LOAD_PARAMS}  // TODO: Implement data loading
  return {};
};"

  write_file "$TARGET_DIR/+page.server.ts" "$SERVER_LOAD_CONTENT"

  # Add form actions if server-only
  if [[ "$SERVER_ONLY" == true ]]; then
    ACTIONS_CONTENT="import type { PageServerLoad, Actions } from './\$types';
import { fail, redirect } from '@sveltejs/kit';

export const load: PageServerLoad = async ({ params, locals }) => {
${LOAD_PARAMS}  // TODO: Implement data loading
  return {};
};

export const actions: Actions = {
  default: async ({ request, locals }) => {
    const data = await request.formData();
    // TODO: Process form submission

    // Return validation errors:
    // return fail(400, { error: 'Validation failed' });

    // Or redirect on success:
    // redirect(303, '/${ROUTE_PATH}');

    return { success: true };
  }
};"
    # Overwrite the server load file with actions included
    write_file "$TARGET_DIR/+page.server.ts" "$ACTIONS_CONTENT"
  fi
fi

# --- Optional: +layout.svelte ---
if [[ "$GEN_LAYOUT" == true ]]; then
  LAYOUT_CONTENT="<script lang=\"ts\">
  let { children } = \$props();
</script>

<div class=\"${ROUTE_PATH//\//-}-layout\">
  {@render children()}
</div>"

  write_file "$TARGET_DIR/+layout.svelte" "$LAYOUT_CONTENT"
fi

# --- Optional: +layout.server.ts ---
if [[ "$GEN_LAYOUT_SERVER" == true ]]; then
  LAYOUT_SERVER_CONTENT="import type { LayoutServerLoad } from './\$types';
import { redirect } from '@sveltejs/kit';

export const load: LayoutServerLoad = async ({ locals }) => {
  // Example: protect all routes under this layout
  // if (!locals.user) redirect(303, '/login');

  return {
    // user: locals.user
  };
};"

  write_file "$TARGET_DIR/+layout.server.ts" "$LAYOUT_SERVER_CONTENT"
fi

# --- Optional: +error.svelte ---
if [[ "$GEN_ERROR" == true ]]; then
  ERROR_CONTENT="<script lang=\"ts\">
  import { page } from '\$app/state';
</script>

<svelte:head>
  <title>Error {page.status}</title>
</svelte:head>

<main>
  <h1>{page.status}</h1>
  <p>{page.error?.message ?? 'Something went wrong'}</p>
  <a href=\"/\">Go home</a>
</main>"

  write_file "$TARGET_DIR/+error.svelte" "$ERROR_CONTENT"
fi

echo ""
log_info "Route generated at: $TARGET_DIR/"
log_info "URL: /${ROUTE_PATH}"
