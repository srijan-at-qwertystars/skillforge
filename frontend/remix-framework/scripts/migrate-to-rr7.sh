#!/usr/bin/env bash
set -euo pipefail

# migrate-to-rr7.sh — Migrate a Remix v2 project to React Router v7
#
# Usage:
#   ./migrate-to-rr7.sh [--dry-run] [project-dir]
#
# This script:
#   1. Checks prerequisites (Remix v2 project with Vite)
#   2. Updates package.json dependencies
#   3. Renames/updates config files
#   4. Updates imports across source files
#   5. Creates app/routes.ts if missing
#   6. Runs typegen
#
# Run with --dry-run first to preview changes without modifying files.

DRY_RUN=false
PROJECT_DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      PROJECT_DIR="$1"
      shift
      ;;
  esac
done

cd "$PROJECT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ "$DRY_RUN" == true ]]; then
  echo -e "${YELLOW}=== DRY RUN MODE — No files will be modified ===${NC}"
  echo ""
fi

# ---------- Step 0: Verify this is a Remix v2 project ----------

if [[ ! -f "package.json" ]]; then
  err "No package.json found. Run this from a Remix project root."
  exit 1
fi

if ! grep -q "@remix-run" package.json; then
  err "This doesn't appear to be a Remix project (no @remix-run dependencies found)."
  exit 1
fi

info "Detected Remix project. Starting migration analysis..."

# ---------- Step 1: Dependency mapping ----------

info ""
info "=== Step 1: Dependency Updates ==="

declare -A DEP_MAP=(
  ["@remix-run/react"]="react-router"
  ["@remix-run/node"]="@react-router/node"
  ["@remix-run/serve"]="@react-router/serve"
  ["@remix-run/dev"]="@react-router/dev"
  ["@remix-run/express"]="@react-router/express"
  ["@remix-run/cloudflare"]="@react-router/cloudflare"
  ["@remix-run/cloudflare-pages"]="@react-router/cloudflare"
  ["@remix-run/deno"]="@react-router/deno"
  ["@remix-run/architect"]="@react-router/architect"
  ["@remix-run/testing"]="react-router"
)

for old_dep in "${!DEP_MAP[@]}"; do
  new_dep="${DEP_MAP[$old_dep]}"
  if grep -q "\"$old_dep\"" package.json; then
    info "  $old_dep → $new_dep"
  fi
done

# Also need @react-router/fs-routes for flat routes convention
info "  + @react-router/fs-routes (new dependency for flat routes)"

if [[ "$DRY_RUN" == false ]]; then
  # Remove old deps and add new ones
  OLD_DEPS=()
  NEW_DEPS=()
  NEW_DEV_DEPS=()

  for old_dep in "${!DEP_MAP[@]}"; do
    if grep -q "\"$old_dep\"" package.json; then
      OLD_DEPS+=("$old_dep")
      new_dep="${DEP_MAP[$old_dep]}"
      if [[ "$old_dep" == "@remix-run/dev" ]]; then
        NEW_DEV_DEPS+=("$new_dep")
      else
        NEW_DEPS+=("$new_dep")
      fi
    fi
  done

  # Uninstall old deps
  if [[ ${#OLD_DEPS[@]} -gt 0 ]]; then
    info "Removing old Remix dependencies..."
    npm uninstall "${OLD_DEPS[@]}" 2>/dev/null || true
  fi

  # Install new deps
  if [[ ${#NEW_DEPS[@]} -gt 0 ]]; then
    info "Installing new React Router dependencies..."
    npm install "${NEW_DEPS[@]}" @react-router/fs-routes 2>/dev/null || warn "npm install failed — you may need to install manually"
  fi

  if [[ ${#NEW_DEV_DEPS[@]} -gt 0 ]]; then
    info "Installing new dev dependencies..."
    npm install -D "${NEW_DEV_DEPS[@]}" 2>/dev/null || warn "npm install -D failed — you may need to install manually"
  fi

  ok "Dependencies updated"
fi

# ---------- Step 2: Config files ----------

info ""
info "=== Step 2: Config File Updates ==="

# Vite config: remix() → reactRouter()
if [[ -f "vite.config.ts" ]]; then
  if grep -q "remix()" vite.config.ts || grep -q "@remix-run/dev" vite.config.ts; then
    info "  Updating vite.config.ts: remix() → reactRouter()"
    if [[ "$DRY_RUN" == false ]]; then
      sed -i 's|@remix-run/dev/vite|@react-router/dev/vite|g' vite.config.ts
      sed -i 's|import { remix }|import { reactRouter }|g' vite.config.ts
      sed -i 's|import { vitePlugin as remix }|import { reactRouter }|g' vite.config.ts
      sed -i 's|remix()|reactRouter()|g' vite.config.ts
      sed -i 's|remix({|reactRouter({|g' vite.config.ts
      ok "  vite.config.ts updated"
    fi
  else
    ok "  vite.config.ts already uses reactRouter()"
  fi
fi

# Create react-router.config.ts if remix.config.js exists
if [[ -f "remix.config.js" && ! -f "react-router.config.ts" ]]; then
  info "  Creating react-router.config.ts from remix.config.js"
  if [[ "$DRY_RUN" == false ]]; then
    cat > react-router.config.ts << 'EOF'
import type { Config } from "@react-router/dev/config";

export default {
  appDirectory: "app",
  ssr: true,
} satisfies Config;
EOF
    ok "  react-router.config.ts created"
    warn "  Review react-router.config.ts — some remix.config.js options may need manual migration"
  fi
fi

# Create app/routes.ts if it doesn't exist
APP_DIR="app"
if [[ -f "react-router.config.ts" ]]; then
  DETECTED=$(grep -oP 'appDirectory:\s*"([^"]+)"' react-router.config.ts 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  if [[ -n "$DETECTED" ]]; then
    APP_DIR="$DETECTED"
  fi
fi

if [[ ! -f "$APP_DIR/routes.ts" ]]; then
  info "  Creating $APP_DIR/routes.ts with flatRoutes()"
  if [[ "$DRY_RUN" == false ]]; then
    cat > "$APP_DIR/routes.ts" << 'EOF'
import { type RouteConfig } from "@react-router/dev/routes";
import { flatRoutes } from "@react-router/fs-routes";

export default flatRoutes() satisfies RouteConfig;
EOF
    ok "  $APP_DIR/routes.ts created"
  fi
fi

# ---------- Step 3: Update imports ----------

info ""
info "=== Step 3: Import Updates ==="

# Find all TS/TSX/JS/JSX files in the app directory
FILE_COUNT=0
if [[ -d "$APP_DIR" ]]; then
  while IFS= read -r -d '' file; do
    if grep -q "@remix-run" "$file" 2>/dev/null; then
      FILE_COUNT=$((FILE_COUNT + 1))
      if [[ "$DRY_RUN" == true ]]; then
        info "  Would update: $file"
        grep -n "@remix-run" "$file" | head -5 | while read -r line; do
          info "    $line"
        done
      else
        # Replace imports
        sed -i 's|@remix-run/react|react-router|g' "$file"
        sed -i 's|@remix-run/node|@react-router/node|g' "$file"
        sed -i 's|@remix-run/serve|@react-router/serve|g' "$file"
        sed -i 's|@remix-run/cloudflare|@react-router/cloudflare|g' "$file"
        sed -i 's|@remix-run/express|@react-router/express|g' "$file"
        sed -i 's|@remix-run/deno|@react-router/deno|g' "$file"
        sed -i 's|@remix-run/architect|@react-router/architect|g' "$file"
        sed -i 's|@remix-run/testing|react-router|g' "$file"

        # Replace removed APIs
        # json() is removed — this needs manual attention
        if grep -q "from \"react-router\"" "$file" || grep -q "from 'react-router'" "$file"; then
          if grep -q "\bjson\b" "$file" && grep -qP "import.*\bjson\b.*from" "$file"; then
            warn "  $file uses json() — replace with plain returns or data() utility"
          fi
        fi
      fi
    fi
  done < <(find "$APP_DIR" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) -print0)
fi

info "  Found $FILE_COUNT files with @remix-run imports"
if [[ "$DRY_RUN" == false && $FILE_COUNT -gt 0 ]]; then
  ok "  Imports updated in $FILE_COUNT files"
fi

# ---------- Step 4: Update package.json scripts ----------

info ""
info "=== Step 4: Package Scripts Updates ==="

if grep -q "remix " package.json; then
  info "  Updating package.json scripts"
  if [[ "$DRY_RUN" == false ]]; then
    sed -i 's|"remix dev"|"react-router dev"|g' package.json
    sed -i 's|"remix build"|"react-router build"|g' package.json
    sed -i 's|"remix-serve |"react-router-serve |g' package.json
    sed -i 's|"remix typegen"|"react-router typegen"|g' package.json
    sed -i 's|"remix vite:dev"|"react-router dev"|g' package.json
    sed -i 's|"remix vite:build"|"react-router build"|g' package.json
    ok "  Package scripts updated"
  else
    grep -n "remix" package.json | grep -E '"(dev|build|start|typecheck)"' | while read -r line; do
      info "  Would update: $line"
    done
  fi
fi

# ---------- Step 5: Type updates ----------

info ""
info "=== Step 5: Type Migration Notes ==="

# Check for old type patterns
OLD_TYPE_COUNT=0
if [[ -d "$APP_DIR" ]]; then
  OLD_TYPE_COUNT=$(grep -rl "LoaderFunctionArgs\|ActionFunctionArgs\|MetaFunction\|LinksFunction\|HeadersFunction" "$APP_DIR" 2>/dev/null | wc -l || echo 0)
fi

if [[ "$OLD_TYPE_COUNT" -gt 0 ]]; then
  warn "  $OLD_TYPE_COUNT files use old Remix type names (LoaderFunctionArgs, etc.)"
  warn "  These should be migrated to Route.LoaderArgs, Route.ActionArgs, etc."
  warn "  Run 'npx react-router typegen' to generate the new Route types"
  warn "  Then update imports: import type { Route } from './+types/route-name'"
fi

# ---------- Step 6: Run typegen ----------

info ""
info "=== Step 6: Type Generation ==="

if [[ "$DRY_RUN" == false ]]; then
  info "Running react-router typegen..."
  if npx react-router typegen 2>/dev/null; then
    ok "Types generated successfully"
  else
    warn "typegen failed — you may need to fix config issues first"
  fi
fi

# ---------- Summary ----------

echo ""
echo "=============================="
if [[ "$DRY_RUN" == true ]]; then
  echo -e "${YELLOW}DRY RUN COMPLETE${NC}"
  echo "Run without --dry-run to apply changes."
else
  echo -e "${GREEN}MIGRATION COMPLETE${NC}"
fi
echo "=============================="
echo ""
echo "Manual steps remaining:"
echo "  1. Replace json() calls with plain returns (or use data() for status/headers)"
echo "  2. Update type annotations: LoaderFunctionArgs → Route.LoaderArgs"
echo "  3. Update components: useLoaderData<typeof loader>() → props.loaderData"
echo "  4. Review react-router.config.ts settings"
echo "  5. Run 'npx react-router typegen --watch' during development"
echo "  6. Test the application thoroughly"
echo ""
echo "Resources:"
echo "  - Migration guide: https://reactrouter.com/upgrading/remix"
echo "  - Codemod: npx codemod remix/2/react-router/upgrade"
echo ""
