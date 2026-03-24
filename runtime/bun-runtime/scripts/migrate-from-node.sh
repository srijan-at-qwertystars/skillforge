#!/usr/bin/env bash
#
# migrate-from-node.sh — Analyze a Node.js project for Bun compatibility
#
# Usage:
#   migrate-from-node.sh [project-dir]
#
# If no directory is specified, the current directory is used.
# Generates a migration checklist with compatibility findings.
#
# Options:
#   --output <file>    Write report to file (default: stdout)
#   --fix              Apply safe automatic fixes (updates tsconfig, removes dotenv)
#   -h, --help         Show this help message
#
# Examples:
#   migrate-from-node.sh ./my-node-project
#   migrate-from-node.sh --output migration-report.md
#   migrate-from-node.sh ./my-project --fix
#
# Requirements: bun must be installed
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
PASS=0
WARN=0
FAIL=0

PROJECT_DIR="."
OUTPUT=""
AUTO_FIX=false

pass() { ((PASS++)); echo -e "  ${GREEN}✓${NC} $1"; }
warn() { ((WARN++)); echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${BLUE}→${NC} $1"; }
header() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

usage() {
  head -16 "$0" | tail -13 | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --output)  OUTPUT="$2"; shift 2 ;;
    --fix)     AUTO_FIX=true; shift ;;
    -h|--help) usage ;;
    -*)        echo "Unknown option: $1"; usage ;;
    *)         PROJECT_DIR="$1"; shift ;;
  esac
done

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo -e "${RED}Error: Directory '$PROJECT_DIR' not found${NC}"
  exit 1
fi

cd "$PROJECT_DIR"

if [[ ! -f "package.json" ]]; then
  echo -e "${RED}Error: No package.json found in '$PROJECT_DIR'${NC}"
  exit 1
fi

# Redirect output if --output specified
if [[ -n "$OUTPUT" ]]; then
  exec > >(tee "$OUTPUT")
fi

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Node.js → Bun Migration Analysis     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo -e "  Project: $(pwd)"
echo -e "  Date: $(date '+%Y-%m-%d %H:%M')"

# ─── 1. Runtime Check ─────────────────────────────────────────────
header "Runtime Environment"

if command -v bun &>/dev/null; then
  pass "Bun installed: $(bun --version)"
else
  fail "Bun not installed — install from https://bun.sh"
fi

if command -v node &>/dev/null; then
  info "Node.js version: $(node --version)"
fi

# ─── 2. Package Manager ──────────────────────────────────────────
header "Package Manager"

if [[ -f "bun.lock" ]]; then
  pass "bun.lock already exists"
elif [[ -f "bun.lockb" ]]; then
  warn "bun.lockb (binary) found — consider upgrading to bun.lock (text-based)"
elif [[ -f "package-lock.json" ]]; then
  info "package-lock.json found — bun install will read it and create bun.lock"
elif [[ -f "yarn.lock" ]]; then
  info "yarn.lock found — bun install will read it and create bun.lock"
elif [[ -f "pnpm-lock.yaml" ]]; then
  info "pnpm-lock.yaml found — bun install will read it and create bun.lock"
else
  warn "No lockfile found"
fi

if [[ -f ".npmrc" ]]; then
  info ".npmrc found — review for Bun compatibility; some settings may need bunfig.toml"
fi

if [[ -f ".nvmrc" ]] || [[ -f ".node-version" ]]; then
  info "Node version file found — not needed for Bun (optional)"
fi

# ─── 3. Dependencies Analysis ────────────────────────────────────
header "Dependencies Analysis"

# Check for packages that have Bun built-in replacements
DEPS=$(cat package.json | grep -E '"[^"]+":' | grep -v '"name"\|"version"\|"scripts"\|"devDependencies"\|"dependencies"\|"peerDependencies"\|"private"\|"main"\|"module"\|"types"\|"license"\|"description"\|"repository"\|"author"\|"keywords"\|"engines"\|"workspaces"\|"files"\|"bin"\|"overrides"\|"resolutions"' | sed 's/.*"\([^"]*\)".*/\1/' 2>/dev/null || true)

# Packages with Bun built-in replacements
for pkg in dotenv dotenv-cli; do
  if echo "$DEPS" | grep -q "^${pkg}$"; then
    warn "'${pkg}' can be removed — Bun loads .env files automatically"
  fi
done

for pkg in bcrypt bcryptjs argon2; do
  if echo "$DEPS" | grep -q "^${pkg}$"; then
    warn "'${pkg}' can be replaced with built-in Bun.password"
  fi
done

if echo "$DEPS" | grep -q "^better-sqlite3$"; then
  warn "'better-sqlite3' can be replaced with built-in bun:sqlite"
fi

for pkg in glob fast-glob globby; do
  if echo "$DEPS" | grep -q "^${pkg}$"; then
    info "'${pkg}' can be replaced with built-in Bun.Glob"
  fi
done

for pkg in node-fetch undici cross-fetch; do
  if echo "$DEPS" | grep -q "^${pkg}$"; then
    warn "'${pkg}' not needed — Bun has built-in fetch"
  fi
done

if echo "$DEPS" | grep -q "^semver$"; then
  info "'semver' can be replaced with built-in Bun.semver"
fi

# Check for native modules that may have issues
for pkg in sharp canvas node-canvas node-sass; do
  if echo "$DEPS" | grep -q "^${pkg}$"; then
    warn "'${pkg}' (native module) — verify it compiles with Bun"
  fi
done

for pkg in cpu-features fsevents; do
  if echo "$DEPS" | grep -q "^${pkg}$"; then
    info "'${pkg}' is optional/native — may need platform-specific handling"
  fi
done

# Check for test frameworks
for pkg in jest vitest mocha @jest/globals ts-jest; do
  if echo "$DEPS" | grep -q "^${pkg}$"; then
    info "'${pkg}' can be replaced with built-in bun:test"
  fi
done

# Check for bundlers
for pkg in webpack webpack-cli esbuild rollup parcel vite; do
  if echo "$DEPS" | grep -q "^${pkg}$"; then
    info "'${pkg}' can potentially be replaced with bun build"
  fi
done

# ─── 4. TypeScript Configuration ─────────────────────────────────
header "TypeScript Configuration"

if [[ -f "tsconfig.json" ]]; then
  pass "tsconfig.json found"

  if grep -q '"moduleResolution"' tsconfig.json 2>/dev/null; then
    MR=$(grep '"moduleResolution"' tsconfig.json | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/' | tr '[:upper:]' '[:lower:]')
    if [[ "$MR" == "bundler" ]]; then
      pass "moduleResolution is 'bundler' (optimal for Bun)"
    elif [[ "$MR" == "node" || "$MR" == "node16" || "$MR" == "nodenext" ]]; then
      warn "moduleResolution is '${MR}' — consider changing to 'bundler'"
    fi
  else
    info "No moduleResolution set — 'bundler' is recommended for Bun"
  fi

  if grep -q '"bun-types"' tsconfig.json 2>/dev/null; then
    pass "bun-types configured"
  else
    warn "Add 'bun-types' to compilerOptions.types for Bun type definitions"
  fi

  if grep -q '"module".*"commonjs"' tsconfig.json 2>/dev/null; then
    warn "module is 'commonjs' — consider 'esnext' for Bun"
  fi
else
  info "No tsconfig.json — Bun runs TypeScript without it, but it's recommended"
fi

# ─── 5. Source Code Analysis ─────────────────────────────────────
header "Source Code Patterns"

# Check for Node.js-specific patterns
if grep -rl "require('dotenv')\|require(\"dotenv\")\|from 'dotenv'\|from \"dotenv\"" --include="*.ts" --include="*.js" --include="*.mjs" . 2>/dev/null | head -1 | grep -q .; then
  warn "dotenv imports found — remove them (Bun loads .env automatically)"
fi

if grep -rl "require('child_process')\|from 'child_process'\|from \"child_process\"\|from 'node:child_process'" --include="*.ts" --include="*.js" . 2>/dev/null | head -1 | grep -q .; then
  info "child_process usage found — consider migrating to Bun.$ (Bun Shell)"
fi

if grep -rl "require('worker_threads')\|from 'worker_threads'\|from 'node:worker_threads'" --include="*.ts" --include="*.js" . 2>/dev/null | head -1 | grep -q .; then
  info "worker_threads usage found — consider migrating to Web Workers"
fi

CLUSTER_FILES=$(grep -rl "require('cluster')\|from 'cluster'\|from 'node:cluster'" --include="*.ts" --include="*.js" . 2>/dev/null || true)
if [[ -n "$CLUSTER_FILES" ]]; then
  warn "cluster module usage found — use Bun's reusePort + Workers instead"
  echo "$CLUSTER_FILES" | head -3 | while read f; do info "  $f"; done
fi

# Check for Express
if grep -rl "from 'express'\|require('express')\|from \"express\"" --include="*.ts" --include="*.js" . 2>/dev/null | head -1 | grep -q .; then
  info "Express usage found — can migrate to Bun.serve() or Hono/Elysia"
fi

# Check for __dirname / __filename usage
if grep -rl "__dirname\|__filename" --include="*.ts" --include="*.js" --include="*.mjs" . 2>/dev/null | grep -v node_modules | head -1 | grep -q .; then
  info "__dirname/__filename used — works in Bun, but import.meta.dir/file is preferred"
fi

# ─── 6. Configuration Files ──────────────────────────────────────
header "Configuration Files"

if [[ -f "bunfig.toml" ]]; then
  pass "bunfig.toml exists"
else
  info "No bunfig.toml — create one for Bun-specific configuration"
fi

if [[ -f ".env" ]]; then
  pass ".env file found (Bun loads it automatically)"
fi

if [[ -f "jest.config.js" ]] || [[ -f "jest.config.ts" ]] || [[ -f "jest.config.mjs" ]]; then
  info "Jest config found — migrate settings to bunfig.toml [test] section"
fi

if [[ -f "Dockerfile" ]]; then
  if grep -q "FROM node:" Dockerfile 2>/dev/null; then
    warn "Dockerfile uses node: base image — change to oven/bun:1"
  elif grep -q "oven/bun" Dockerfile 2>/dev/null; then
    pass "Dockerfile already uses Bun image"
  fi
fi

if [[ -f ".github/workflows/"*.yml ]] 2>/dev/null || [[ -f ".github/workflows/"*.yaml ]] 2>/dev/null; then
  CI_FILES=$(ls .github/workflows/*.{yml,yaml} 2>/dev/null || true)
  if echo "$CI_FILES" | xargs grep -l "actions/setup-node" 2>/dev/null | head -1 | grep -q .; then
    info "GitHub Actions uses setup-node — add/replace with oven-sh/setup-bun@v2"
  fi
fi

# ─── 7. Scripts Analysis ─────────────────────────────────────────
header "package.json Scripts"

if command -v jq &>/dev/null; then
  SCRIPTS=$(jq -r '.scripts // {} | keys[]' package.json 2>/dev/null || true)
else
  SCRIPTS=$(grep -A 100 '"scripts"' package.json | grep -B 0 '}' -m 1 | grep '"' | sed 's/.*"\([^"]*\)".*/\1/' 2>/dev/null || true)
fi

if [[ -n "$SCRIPTS" ]]; then
  while IFS= read -r script; do
    SCRIPT_CMD=$(grep "\"${script}\"" package.json | head -1 | sed 's/.*: *"\(.*\)".*/\1/' 2>/dev/null || true)
    if echo "$SCRIPT_CMD" | grep -q "^node "; then
      info "Script '${script}' uses 'node' — will work with 'bun run ${script}'"
    fi
    if echo "$SCRIPT_CMD" | grep -q "^npx "; then
      info "Script '${script}' uses 'npx' — consider replacing with 'bunx'"
    fi
    if echo "$SCRIPT_CMD" | grep -q "ts-node\|tsx"; then
      info "Script '${script}' uses ts-node/tsx — not needed with Bun (runs TS natively)"
    fi
  done <<< "$SCRIPTS"
fi

# ─── 8. Apply Auto Fixes ─────────────────────────────────────────
if [[ "$AUTO_FIX" == true ]]; then
  header "Applying Auto Fixes"

  # Add @types/bun if not present
  if ! grep -q '"@types/bun"' package.json 2>/dev/null; then
    info "Adding @types/bun..."
    if command -v bun &>/dev/null; then
      bun add -d @types/bun --silent 2>/dev/null && pass "Added @types/bun" || warn "Failed to add @types/bun"
    fi
  fi

  # Create bunfig.toml if not present
  if [[ ! -f "bunfig.toml" ]]; then
    cat > bunfig.toml <<'EOF'
[test]
coverage = true
coverageSkipTestFiles = true
EOF
    pass "Created bunfig.toml"
  fi

  # Run bun install to generate lockfile
  if [[ ! -f "bun.lock" ]] && command -v bun &>/dev/null; then
    info "Running bun install..."
    bun install --silent 2>/dev/null && pass "Generated bun.lock" || warn "bun install had issues"
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────
header "Summary"

echo ""
echo -e "  ${GREEN}Passed:${NC}   $PASS"
echo -e "  ${YELLOW}Warnings:${NC} $WARN"
echo -e "  ${RED}Failed:${NC}   $FAIL"
echo ""

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
  echo -e "  ${GREEN}🎉 Project looks ready for Bun! Run 'bun install && bun run start'${NC}"
elif [[ $FAIL -eq 0 ]]; then
  echo -e "  ${YELLOW}Project is mostly compatible. Review warnings above.${NC}"
  echo -e "  ${YELLOW}Try: bun install && bun run start${NC}"
else
  echo -e "  ${RED}Some issues need attention before migration.${NC}"
fi

echo ""
echo -e "  Next steps:"
echo -e "  1. Run ${CYAN}bun install${NC} to generate bun.lock"
echo -e "  2. Run ${CYAN}bun run start${NC} (or your start script) to test"
echo -e "  3. Run ${CYAN}bun test${NC} to verify tests pass"
echo -e "  4. Address warnings above for optimal Bun usage"
echo ""
