#!/usr/bin/env bash
#
# migrate-from-node.sh — Analyze a Node.js project for Bun compatibility.
#
# Usage:
#   ./migrate-from-node.sh [project-directory]
#
# Defaults to current directory if no path given.
# Outputs a compatibility report with actionable recommendations.

set -euo pipefail

PROJECT_DIR="${1:-.}"

if [[ ! -f "$PROJECT_DIR/package.json" ]]; then
  echo "Error: No package.json found in '$PROJECT_DIR'"
  echo "Usage: $0 [project-directory]"
  exit 1
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Bun Migration Compatibility Report                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Project: $(cd "$PROJECT_DIR" && pwd)"
echo "Date:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

ISSUES=0
WARNINGS=0

report_issue() {
  echo "  ❌ ISSUE: $1"
  ISSUES=$((ISSUES + 1))
}

report_warning() {
  echo "  ⚠️  WARN:  $1"
  WARNINGS=$((WARNINGS + 1))
}

report_ok() {
  echo "  ✅ OK:    $1"
}

report_action() {
  echo "  💡 ACTION: $1"
}

# ── 1. Check for native addons ──────────────────────────────────
echo "━━━ 1. Native Addon Check ━━━"

if [[ -d "$PROJECT_DIR/node_modules" ]]; then
  NATIVE_COUNT=$(find "$PROJECT_DIR/node_modules" -name "binding.gyp" -o -name "*.node" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$NATIVE_COUNT" -gt 0 ]]; then
    report_issue "Found $NATIVE_COUNT native addon(s)"
    find "$PROJECT_DIR/node_modules" -name "binding.gyp" 2>/dev/null | while read -r f; do
      PKG_DIR=$(dirname "$f")
      PKG_NAME=$(basename "$PKG_DIR")
      echo "           → $PKG_NAME"
    done
  else
    report_ok "No native addons found"
  fi
else
  report_warning "node_modules not found — run 'npm install' first for full analysis"
fi

echo ""

# ── 2. Known problematic packages ───────────────────────────────
echo "━━━ 2. Package Compatibility ━━━"

KNOWN_ISSUES=(
  "bcrypt:bcryptjs or Bun.password"
  "sharp:wait for N-API support or use external service"
  "canvas:no Bun alternative yet"
  "better-sqlite3:bun:sqlite (built-in)"
  "cpu-features:V8-specific — remove"
  "v8-profiler:use Bun built-in profiler"
  "v8-profiler-next:use Bun built-in profiler"
  "isolated-vm:no Bun alternative yet"
  "node-gyp:native build tool — check dependencies"
  "node-pre-gyp:native build tool — check dependencies"
  "prebuild-install:native build tool — check dependencies"
  "fsevents:macOS only — typically optional"
)

DEPS=$(cat "$PROJECT_DIR/package.json" | grep -E '^\s+"[^"]+":' | sed 's/.*"\([^"]*\)".*/\1/' 2>/dev/null || true)

FOUND_ISSUES=false
for entry in "${KNOWN_ISSUES[@]}"; do
  PKG="${entry%%:*}"
  ALT="${entry#*:}"
  if echo "$DEPS" | grep -qx "$PKG"; then
    report_warning "$PKG — Replace with: $ALT"
    FOUND_ISSUES=true
  fi
done

if [[ "$FOUND_ISSUES" == "false" ]]; then
  report_ok "No known problematic packages detected"
fi

echo ""

# ── 3. Dev tool replacements ────────────────────────────────────
echo "━━━ 3. Dev Tool Replacements ━━━"

DEV_REPLACEMENTS=(
  "nodemon:bun --watch"
  "ts-node:bun (direct TS execution)"
  "ts-node-dev:bun --watch"
  "tsx:bun (direct TS execution)"
  "jest:bun test"
  "ts-jest:bun test (native TS)"
  "@jest/globals:bun:test"
  "mocha:bun test"
  "webpack:bun build"
  "webpack-cli:bun build"
  "esbuild:bun build"
  "rollup:bun build"
  "parcel:bun build"
)

for entry in "${DEV_REPLACEMENTS[@]}"; do
  PKG="${entry%%:*}"
  ALT="${entry#*:}"
  if echo "$DEPS" | grep -qx "$PKG"; then
    report_action "$PKG → $ALT"
  fi
done

echo ""

# ── 4. Scripts analysis ─────────────────────────────────────────
echo "━━━ 4. Scripts Analysis ━━━"

if command -v python3 &>/dev/null; then
  python3 -c "
import json, sys
with open('$PROJECT_DIR/package.json') as f:
    pkg = json.load(f)
scripts = pkg.get('scripts', {})
if not scripts:
    print('  No scripts found in package.json')
    sys.exit(0)
for name, cmd in scripts.items():
    issues = []
    if 'node ' in cmd or cmd.startswith('node '):
        issues.append('node → bun run')
    if 'nodemon' in cmd:
        issues.append('nodemon → bun --watch')
    if 'ts-node' in cmd:
        issues.append('ts-node → bun')
    if 'npx ' in cmd:
        issues.append('npx → bunx')
    if 'jest' in cmd and 'bun' not in cmd:
        issues.append('jest → bun test')
    if issues:
        print(f'  📝 \"{name}\": {\" | \".join(issues)}')
    else:
        print(f'  ✅ \"{name}\": looks compatible')
" 2>/dev/null || echo "  (Could not parse scripts)"
else
  echo "  (python3 not available for script analysis)"
fi

echo ""

# ── 5. Config files ─────────────────────────────────────────────
echo "━━━ 5. Configuration Files ━━━"

[[ -f "$PROJECT_DIR/.nvmrc" ]] && report_warning ".nvmrc found — not needed for Bun"
[[ -f "$PROJECT_DIR/.node-version" ]] && report_warning ".node-version found — not needed for Bun"
[[ -f "$PROJECT_DIR/jest.config.js" ]] && report_action "jest.config.js → migrate to bunfig.toml [test]"
[[ -f "$PROJECT_DIR/jest.config.ts" ]] && report_action "jest.config.ts → migrate to bunfig.toml [test]"
[[ -f "$PROJECT_DIR/nodemon.json" ]] && report_action "nodemon.json → remove (use bun --watch)"
[[ -f "$PROJECT_DIR/webpack.config.js" ]] && report_action "webpack.config.js → migrate to Bun.build or bunfig.toml"
[[ -f "$PROJECT_DIR/tsconfig.json" ]] && report_ok "tsconfig.json found — Bun reads it automatically"
[[ -f "$PROJECT_DIR/package-lock.json" ]] && report_action "package-lock.json → will be replaced by bun.lockb"
[[ -f "$PROJECT_DIR/yarn.lock" ]] && report_action "yarn.lock → will be replaced by bun.lockb"

echo ""

# ── 6. Engine requirements ──────────────────────────────────────
echo "━━━ 6. Engine Requirements ━━━"

if command -v python3 &>/dev/null; then
  python3 -c "
import json
with open('$PROJECT_DIR/package.json') as f:
    pkg = json.load(f)
engines = pkg.get('engines', {})
if engines:
    for engine, ver in engines.items():
        if engine == 'node':
            print(f'  ⚠️  Node.js engine constraint: {ver}')
            print(f'      Remove or add \"bun\" engine field')
        else:
            print(f'  ℹ️  {engine}: {ver}')
else:
    print('  ✅ No engine constraints')
" 2>/dev/null || echo "  (Could not parse engines)"
fi

echo ""

# ── Summary ─────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Summary: $ISSUES issue(s), $WARNINGS warning(s)"
echo ""

if [[ "$ISSUES" -eq 0 ]]; then
  echo "🎉 Project looks ready for Bun migration!"
  echo ""
  echo "Quick start:"
  echo "  1. rm -rf node_modules package-lock.json yarn.lock"
  echo "  2. bun install"
  echo "  3. bun test"
  echo "  4. bun run dev"
else
  echo "⚠️  Resolve the issues above before migrating."
  echo "   Native addon dependencies must be replaced with pure-JS alternatives."
fi
echo ""
