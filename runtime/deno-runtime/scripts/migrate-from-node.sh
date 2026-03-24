#!/usr/bin/env bash
# ============================================================================
# migrate-from-node.sh
#
# Analyzes a Node.js project and generates a migration checklist with
# automated transformations where possible.
#
# Usage:
#   ./migrate-from-node.sh [path-to-node-project]
#
# If no path is given, uses the current directory.
#
# What it does:
#   1. Scans package.json for dependencies and scripts
#   2. Detects CommonJS require() calls and suggests ESM imports
#   3. Identifies Node.js built-in usage needing node: prefix
#   4. Finds __dirname/__filename usage
#   5. Detects testing frameworks and maps to Deno equivalents
#   6. Generates a deno.json starter config
#   7. Generates a migration checklist (migration-report.md)
#
# The script is read-only by default — it does NOT modify your project
# unless --apply is passed.
# ============================================================================

set -euo pipefail

# ── Helpers ──

info()    { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()      { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error()   { echo -e "\033[1;31m[ERR]\033[0m   $*" >&2; exit 1; }
section() { echo -e "\n\033[1;36m══ $* ══\033[0m"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [path-to-node-project]

Analyzes a Node.js project and generates a Deno migration report.

Options:
  --apply     Generate deno.json and migration-report.md in the project
  --help, -h  Show this help message

If no path is given, uses the current directory.
EOF
  exit 0
}

# ── Parse arguments ──

PROJECT_DIR="."
APPLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --help|-h) usage ;;
    -*) error "Unknown flag: $1" ;;
    *) PROJECT_DIR="$1" ;;
  esac
  shift
done

[[ ! -d "$PROJECT_DIR" ]] && error "Directory not found: $PROJECT_DIR"
cd "$PROJECT_DIR"

# ── Verify it's a Node.js project ──

[[ ! -f "package.json" ]] && error "No package.json found in $(pwd). Is this a Node.js project?"

info "Analyzing Node.js project in: $(pwd)"

# ── Extract package.json data ──

section "Package Analysis"

PKG_NAME=$(python3 -c "import json; print(json.load(open('package.json')).get('name','unknown'))" 2>/dev/null || echo "unknown")
PKG_VERSION=$(python3 -c "import json; print(json.load(open('package.json')).get('version','0.0.0'))" 2>/dev/null || echo "0.0.0")
info "Project: $PKG_NAME@$PKG_VERSION"

# Dependencies
DEPS=$(python3 -c "
import json
pkg = json.load(open('package.json'))
deps = list(pkg.get('dependencies', {}).keys())
print('\n'.join(deps) if deps else '')
" 2>/dev/null || echo "")

DEV_DEPS=$(python3 -c "
import json
pkg = json.load(open('package.json'))
deps = list(pkg.get('devDependencies', {}).keys())
print('\n'.join(deps) if deps else '')
" 2>/dev/null || echo "")

SCRIPTS=$(python3 -c "
import json
pkg = json.load(open('package.json'))
for k, v in pkg.get('scripts', {}).items():
    print(f'  {k}: {v}')
" 2>/dev/null || echo "  (none)")

DEP_COUNT=$(echo "$DEPS" | grep -c '.' || echo "0")
DEVDEP_COUNT=$(echo "$DEV_DEPS" | grep -c '.' || echo "0")
info "Dependencies: $DEP_COUNT production, $DEVDEP_COUNT dev"

echo "Scripts:"
echo "$SCRIPTS"

# ── Scan for patterns ──

section "Code Pattern Analysis"

# Count source files
TS_FILES=$(find . -name '*.ts' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | wc -l || echo "0")
JS_FILES=$(find . -name '*.js' -not -path '*/node_modules/*' -not -path '*/.git/*' -not -name '*.config.*' 2>/dev/null | wc -l || echo "0")
TSX_FILES=$(find . -name '*.tsx' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | wc -l || echo "0")
JSX_FILES=$(find . -name '*.jsx' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | wc -l || echo "0")
info "Source files: $TS_FILES .ts, $JS_FILES .js, $TSX_FILES .tsx, $JSX_FILES .jsx"

# CommonJS require() usage
REQUIRE_COUNT=$(grep -r "require(" --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' \
  --exclude-dir=node_modules --exclude-dir=.git -l 2>/dev/null | wc -l || echo "0")
if [[ "$REQUIRE_COUNT" -gt 0 ]]; then
  warn "Found require() in $REQUIRE_COUNT files — needs conversion to ESM import"
  grep -r "require(" --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' \
    --exclude-dir=node_modules --exclude-dir=.git -l 2>/dev/null | head -10 | sed 's/^/  /'
else
  ok "No CommonJS require() found — already using ESM"
fi

# __dirname / __filename usage
DIRNAME_COUNT=$(grep -r "__dirname\|__filename" --include='*.ts' --include='*.js' \
  --exclude-dir=node_modules --exclude-dir=.git -l 2>/dev/null | wc -l || echo "0")
if [[ "$DIRNAME_COUNT" -gt 0 ]]; then
  warn "Found __dirname/__filename in $DIRNAME_COUNT files — needs import.meta.url replacement"
fi

# Node built-ins without node: prefix
BUILTINS="fs|path|http|https|crypto|os|url|util|stream|events|buffer|child_process|cluster|net|tls|dns|assert|zlib|readline|querystring"
BARE_BUILTIN_COUNT=$(grep -rE "from ['\"]($BUILTINS)['\"]|require\(['\"]($BUILTINS)['\"]\)" \
  --include='*.ts' --include='*.js' --exclude-dir=node_modules --exclude-dir=.git -l 2>/dev/null | wc -l || echo "0")
if [[ "$BARE_BUILTIN_COUNT" -gt 0 ]]; then
  warn "Found bare Node.js built-in imports in $BARE_BUILTIN_COUNT files — need node: prefix"
fi

# process.env usage
PROCESS_ENV_COUNT=$(grep -r "process\.env" --include='*.ts' --include='*.js' \
  --exclude-dir=node_modules --exclude-dir=.git -l 2>/dev/null | wc -l || echo "0")
if [[ "$PROCESS_ENV_COUNT" -gt 0 ]]; then
  info "process.env used in $PROCESS_ENV_COUNT files — replace with Deno.env.get()"
fi

# ── Framework Detection ──

section "Framework Detection"

FRAMEWORK="none"
if echo "$DEPS" | grep -q "^express$"; then
  FRAMEWORK="express"
  info "Detected: Express.js → migrate to Hono or Oak"
elif echo "$DEPS" | grep -q "^fastify$"; then
  FRAMEWORK="fastify"
  info "Detected: Fastify → migrate to Hono"
elif echo "$DEPS" | grep -q "^koa$"; then
  FRAMEWORK="koa"
  info "Detected: Koa → migrate to Oak"
elif echo "$DEPS" | grep -q "^next$"; then
  FRAMEWORK="next"
  warn "Detected: Next.js — consider Fresh framework for Deno"
fi

# Test framework
TEST_FRAMEWORK="none"
if echo "$DEV_DEPS" | grep -q "^jest$"; then
  TEST_FRAMEWORK="jest"
  info "Detected: Jest → migrate to Deno.test + @std/assert"
elif echo "$DEV_DEPS" | grep -q "^vitest$"; then
  TEST_FRAMEWORK="vitest"
  info "Detected: Vitest → migrate to Deno.test + @std/testing/bdd"
elif echo "$DEV_DEPS" | grep -q "^mocha$"; then
  TEST_FRAMEWORK="mocha"
  info "Detected: Mocha → migrate to Deno.test + @std/testing/bdd"
fi

# ── Problematic Dependencies ──

section "Dependency Compatibility"

PROBLEM_DEPS=""
while IFS= read -r dep; do
  [[ -z "$dep" ]] && continue
  case "$dep" in
    sharp|canvas|node-gyp|better-sqlite3|bcrypt|node-sass|fsevents|cpu-features|re2)
      warn "Native addon: $dep — may not work in Deno"
      PROBLEM_DEPS="$PROBLEM_DEPS $dep"
      ;;
    typescript|@types/*|eslint*|prettier*|jest|ts-jest|vitest|mocha|chai|nodemon|ts-node|tsx)
      info "Dev-only: $dep — not needed in Deno (built-in tooling)"
      ;;
  esac
done <<< "$DEPS"
while IFS= read -r dep; do
  [[ -z "$dep" ]] && continue
  case "$dep" in
    sharp|canvas|node-gyp|better-sqlite3|bcrypt|node-sass|fsevents|cpu-features|re2)
      warn "Native addon (dev): $dep — may not work in Deno"
      PROBLEM_DEPS="$PROBLEM_DEPS $dep"
      ;;
  esac
done <<< "$DEV_DEPS"

[[ -z "$PROBLEM_DEPS" ]] && ok "No known problematic native addons detected"

# ── Generate deno.json ──

section "Generated deno.json"

IMPORTS=""
while IFS= read -r dep; do
  [[ -z "$dep" ]] && continue
  case "$dep" in
    typescript|@types/*|eslint*|prettier*|jest|ts-jest|vitest|mocha|chai|nodemon|ts-node|tsx)
      continue ;;
    express)
      IMPORTS="$IMPORTS    \"hono\": \"jsr:@hono/hono@^4\","$'\n' ;;
    koa)
      IMPORTS="$IMPORTS    \"oak\": \"jsr:@oak/oak@^16\","$'\n' ;;
    dotenv)
      continue ;; # Deno loads .env natively
    *)
      IMPORTS="$IMPORTS    \"$dep\": \"npm:$dep\","$'\n' ;;
  esac
done <<< "$DEPS"

DENO_JSON=$(cat <<EOF
{
  "compilerOptions": {
    "strict": true
  },
  "imports": {
    "@std/assert": "jsr:@std/assert@^1",
    "@std/testing": "jsr:@std/testing@^1",
${IMPORTS}    "~/": "./src/"
  },
  "tasks": {
    "dev": "deno run --watch --allow-net --allow-read --allow-env main.ts",
    "start": "deno run --allow-net --allow-read --allow-env main.ts",
    "test": "deno test --allow-read --allow-net --allow-env",
    "lint": "deno lint",
    "fmt": "deno fmt"
  },
  "fmt": { "indentWidth": 2, "singleQuote": true },
  "lint": { "rules": { "tags": ["recommended"] } }
}
EOF
)

echo "$DENO_JSON"

# ── Generate migration report ──

REPORT=$(cat <<EOF
# Migration Report: $PKG_NAME

Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Source: $(pwd)

## Summary

| Metric | Count |
|--------|-------|
| TypeScript files | $TS_FILES |
| JavaScript files | $JS_FILES |
| TSX files | $TSX_FILES |
| JSX files | $JSX_FILES |
| Production deps | $DEP_COUNT |
| Dev deps | $DEVDEP_COUNT |
| Files with require() | $REQUIRE_COUNT |
| Files with __dirname | $DIRNAME_COUNT |
| Files with bare builtins | $BARE_BUILTIN_COUNT |
| Files with process.env | $PROCESS_ENV_COUNT |

## Detected Frameworks

- Web: $FRAMEWORK
- Testing: $TEST_FRAMEWORK

## Migration Checklist

### Phase 1: Setup
- [ ] Install Deno 2.x
- [ ] Create deno.json (see generated config above)
- [ ] Remove: tsconfig.json, .eslintrc*, .prettierrc*, jest.config.*

### Phase 2: Code Changes
$(if [[ "$REQUIRE_COUNT" -gt 0 ]]; then echo "- [ ] Convert $REQUIRE_COUNT files from require() to import"; fi)
$(if [[ "$DIRNAME_COUNT" -gt 0 ]]; then echo "- [ ] Replace __dirname/__filename in $DIRNAME_COUNT files with import.meta.url"; fi)
$(if [[ "$BARE_BUILTIN_COUNT" -gt 0 ]]; then echo "- [ ] Add node: prefix to built-in imports in $BARE_BUILTIN_COUNT files"; fi)
$(if [[ "$PROCESS_ENV_COUNT" -gt 0 ]]; then echo "- [ ] Replace process.env with Deno.env.get() in $PROCESS_ENV_COUNT files"; fi)
- [ ] Add .ts extensions to all relative imports
- [ ] Replace module.exports with export

### Phase 3: Framework
$(case "$FRAMEWORK" in
  express) echo "- [ ] Replace Express with Hono (jsr:@hono/hono)" ;;
  fastify) echo "- [ ] Replace Fastify with Hono (jsr:@hono/hono)" ;;
  koa) echo "- [ ] Replace Koa with Oak (jsr:@oak/oak)" ;;
  next) echo "- [ ] Consider migrating to Fresh framework" ;;
  *) echo "- [ ] Review web framework compatibility" ;;
esac)

### Phase 4: Testing
$(case "$TEST_FRAMEWORK" in
  jest) echo "- [ ] Replace Jest with Deno.test + @std/assert + @std/testing/mock" ;;
  vitest) echo "- [ ] Replace Vitest with Deno.test + @std/testing/bdd" ;;
  mocha) echo "- [ ] Replace Mocha/Chai with Deno.test + @std/assert" ;;
  *) echo "- [ ] Set up Deno.test" ;;
esac)

### Phase 5: Infrastructure
- [ ] Update CI/CD pipeline (setup-deno action)
- [ ] Update Dockerfile (use denoland/deno base image)
- [ ] Add permission flags for production
- [ ] Generate deno.lock

### Phase 6: Cleanup
- [ ] Remove node_modules/
- [ ] Remove package-lock.json / yarn.lock
- [ ] Remove tsconfig.json
- [ ] Remove .eslintrc* / eslint.config.*
- [ ] Remove .prettierrc*
- [ ] Remove jest.config.* / vitest.config.*
$(if [[ -n "$PROBLEM_DEPS" ]]; then echo "
### ⚠️ Problematic Dependencies
These packages use native addons and may need alternatives:
$(for dep in $PROBLEM_DEPS; do echo "- [ ] Find Deno-compatible alternative for: $dep"; done)"; fi)
EOF
)

section "Migration Report"
echo "$REPORT"

# ── Apply if requested ──

if [[ "$APPLY" == "true" ]]; then
  section "Applying Changes"

  if [[ ! -f "deno.json" ]]; then
    echo "$DENO_JSON" > deno.json
    ok "Created deno.json"
  else
    warn "deno.json already exists — skipping"
  fi

  echo "$REPORT" > migration-report.md
  ok "Created migration-report.md"
else
  echo ""
  info "Run with --apply to generate deno.json and migration-report.md in your project"
fi

echo ""
ok "Analysis complete!"
