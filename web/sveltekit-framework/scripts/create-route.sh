#!/usr/bin/env bash
# create-route.sh — Generate a SvelteKit route with page, server load, layout,
# and error boundary files.
#
# Usage:
#   ./create-route.sh <route-path> [options]
#
# Examples:
#   ./create-route.sh blog                          # creates src/routes/blog/
#   ./create-route.sh blog/[slug]                   # dynamic route
#   ./create-route.sh "(auth)/login"                # grouped route
#   ./create-route.sh api/users --api-only          # API route only (+server.ts)
#   ./create-route.sh dashboard --with-layout       # include +layout.svelte
#   ./create-route.sh products --with-error         # include +error.svelte
#   ./create-route.sh settings --full               # all files
#   ./create-route.sh admin --server-load           # +page.server.ts instead of +page.ts
#
# Options:
#   --api-only       Only create +server.ts (API endpoint)
#   --with-layout    Also create +layout.svelte and +layout.server.ts
#   --with-error     Also create +error.svelte
#   --full           Create all files (page, server load, layout, error)
#   --server-load    Use +page.server.ts (default: +page.ts universal load)
#   --no-load        Skip load function file
#   --dry-run        Show what would be created without writing files
#   -h, --help       Show this help message

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[route]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }
info()  { echo -e "${CYAN}[info]${NC} $*"; }

usage() {
    sed -n '2,/^$/s/^# //p' "$0"
    exit 0
}

# --- Defaults ---
API_ONLY=false
WITH_LAYOUT=false
WITH_ERROR=false
SERVER_LOAD=false
NO_LOAD=false
DRY_RUN=false
ROUTE_PATH=""

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --api-only)     API_ONLY=true; shift ;;
        --with-layout)  WITH_LAYOUT=true; shift ;;
        --with-error)   WITH_ERROR=true; shift ;;
        --full)         WITH_LAYOUT=true; WITH_ERROR=true; SERVER_LOAD=true; shift ;;
        --server-load)  SERVER_LOAD=true; shift ;;
        --no-load)      NO_LOAD=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)      usage ;;
        -*)             error "Unknown option: $1"; usage ;;
        *)
            if [[ -z "$ROUTE_PATH" ]]; then
                ROUTE_PATH="$1"
            else
                error "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "$ROUTE_PATH" ]]; then
    error "Missing required argument: route-path"
    usage
fi

# --- Locate project root ---
ROUTES_DIR="src/routes"
if [[ ! -d "$ROUTES_DIR" ]]; then
    error "Cannot find $ROUTES_DIR. Run this script from the SvelteKit project root."
    exit 1
fi

TARGET_DIR="${ROUTES_DIR}/${ROUTE_PATH}"
ROUTE_NAME=$(basename "$ROUTE_PATH" | sed 's/[[\]()]//g')

# --- Helper: write file ---
write_file() {
    local filepath="$1"
    local content="$2"
    if [[ "$DRY_RUN" == true ]]; then
        info "Would create: $filepath"
        return
    fi
    if [[ -f "$filepath" ]]; then
        warn "Skipping existing file: $filepath"
        return
    fi
    echo "$content" > "$filepath"
    log "Created: $filepath"
}

# --- Create directory ---
if [[ "$DRY_RUN" == true ]]; then
    info "Would create directory: $TARGET_DIR"
else
    mkdir -p "$TARGET_DIR"
    log "Created directory: $TARGET_DIR"
fi

# --- API-only route ---
if [[ "$API_ONLY" == true ]]; then
    write_file "$TARGET_DIR/+server.ts" "import { json, error } from '@sveltejs/kit';
import type { RequestHandler } from './\$types';

export const GET: RequestHandler = async ({ url }) => {
    // TODO: implement GET handler
    return json({ message: 'OK' });
};

export const POST: RequestHandler = async ({ request }) => {
    const body = await request.json();
    // TODO: implement POST handler
    return json({ success: true }, { status: 201 });
};

export const PUT: RequestHandler = async ({ params, request }) => {
    const body = await request.json();
    // TODO: implement PUT handler
    return json({ success: true });
};

export const DELETE: RequestHandler = async ({ params }) => {
    // TODO: implement DELETE handler
    return new Response(null, { status: 204 });
};"
    echo ""
    log "✅ API route created at $TARGET_DIR"
    exit 0
fi

# --- +page.svelte ---
write_file "$TARGET_DIR/+page.svelte" "<script lang=\"ts\">
    let { data, form } = \$props();
</script>

<svelte:head>
    <title>${ROUTE_NAME}</title>
    <meta name=\"description\" content=\"${ROUTE_NAME} page\" />
</svelte:head>

<main>
    <h1>${ROUTE_NAME}</h1>
    <!-- TODO: page content -->
</main>"

# --- Load function ---
if [[ "$NO_LOAD" != true ]]; then
    if [[ "$SERVER_LOAD" == true ]]; then
        write_file "$TARGET_DIR/+page.server.ts" "import type { PageServerLoad, Actions } from './\$types';
import { fail, redirect } from '@sveltejs/kit';

export const load: PageServerLoad = async ({ params, locals }) => {
    // TODO: load data from database or API
    return {};
};

export const actions: Actions = {
    default: async ({ request, cookies }) => {
        const formData = await request.formData();
        // TODO: handle form submission
        return { success: true };
    }
};"
    else
        write_file "$TARGET_DIR/+page.ts" "import type { PageLoad } from './\$types';

export const load: PageLoad = async ({ params, fetch }) => {
    // TODO: load data
    return {};
};"
    fi
fi

# --- +layout.svelte ---
if [[ "$WITH_LAYOUT" == true ]]; then
    write_file "$TARGET_DIR/+layout.svelte" "<script lang=\"ts\">
    let { children, data } = \$props();
</script>

<div class=\"${ROUTE_NAME}-layout\">
    {@render children()}
</div>"

    write_file "$TARGET_DIR/+layout.server.ts" "import type { LayoutServerLoad } from './\$types';

export const load: LayoutServerLoad = async ({ locals }) => {
    // TODO: load shared layout data
    return {};
};"
fi

# --- +error.svelte ---
if [[ "$WITH_ERROR" == true ]]; then
    write_file "$TARGET_DIR/+error.svelte" "<script lang=\"ts\">
    import { page } from '\$app/state';
</script>

<div class=\"error-page\">
    <h1>{page.status}</h1>
    <p>{page.error?.message ?? 'Something went wrong'}</p>
    <a href=\"/\">Go home</a>
</div>"
fi

# --- Summary ---
echo ""
log "✅ Route '/${ROUTE_PATH}' created at $TARGET_DIR"
if [[ "$DRY_RUN" == true ]]; then
    info "(dry run — no files were written)"
fi
