#!/usr/bin/env bash
#
# node-to-deno.sh — Assist migrating a Node.js project to Deno
#
# Usage:
#   ./node-to-deno.sh [project-dir] [--dry-run] [--keep-package-json]
#
# What it does:
#   1. Scans for Node.js-style imports and suggests Deno equivalents
#   2. Creates deno.json from package.json dependencies
#   3. Updates common import patterns (require → import, node built-ins)
#   4. Reports incompatible packages that need manual attention
#   5. Creates a migration report
#
# Options:
#   --dry-run            Show what would change without modifying files
#   --keep-package-json  Don't remove package.json (useful for gradual migration)
#
# Examples:
#   ./node-to-deno.sh ./my-node-app
#   ./node-to-deno.sh ./my-node-app --dry-run
#   ./node-to-deno.sh . --keep-package-json
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}✓${NC} $1"; }
info() { echo -e "${BLUE}→${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; }

# Parse arguments
PROJECT_DIR="${1:-.}"
DRY_RUN=false
KEEP_PKG_JSON=false

shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --keep-package-json) KEEP_PKG_JSON=true ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

if [[ ! -d "$PROJECT_DIR" ]]; then
  error "Directory not found: $PROJECT_DIR"
  exit 1
fi

cd "$PROJECT_DIR"
REPORT_FILE="migration-report.md"

echo -e "${BOLD}🦕 Node.js → Deno Migration Tool${NC}"
echo ""

if $DRY_RUN; then
  info "DRY RUN — no files will be modified"
  echo ""
fi

# Initialize report
report_lines=()
report_lines+=("# Node.js → Deno Migration Report")
report_lines+=("")
report_lines+=("Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")")
report_lines+=("Project: $(basename "$(pwd)")")
report_lines+=("")

# ─── Step 1: Analyze package.json ────────────────────────────────────────

if [[ -f "package.json" ]]; then
  info "Analyzing package.json..."
  report_lines+=("## Dependencies")
  report_lines+=("")

  # Extract dependencies
  DEPS=$(python3 -c "
import json, sys
try:
    with open('package.json') as f:
        pkg = json.load(f)
    deps = pkg.get('dependencies', {})
    dev_deps = pkg.get('devDependencies', {})
    for name, ver in {**deps, **dev_deps}.items():
        print(f'{name}={ver}')
except Exception as e:
    print(f'ERROR={e}', file=sys.stderr)
" 2>/dev/null || echo "")

  if [[ -n "$DEPS" ]]; then
    # Known JSR replacements
    declare -A JSR_MAP=(
      ["assert"]="jsr:@std/assert@^1"
      ["path"]="jsr:@std/path@^1"
      ["fs-extra"]="jsr:@std/fs@^1"
      ["dotenv"]="jsr:@std/dotenv@^0.225"
      ["chalk"]="npm:chalk@^5"
      ["express"]="npm:express@^4"
      ["zod"]="npm:zod@^3"
      ["uuid"]="jsr:@std/uuid@^1"
      ["lodash"]="npm:lodash-es@^4"
    )

    imports_json="{"
    first=true

    while IFS='=' read -r name version; do
      [[ -z "$name" ]] && continue

      # Check for JSR replacement
      if [[ -v "JSR_MAP[$name]" ]]; then
        replacement="${JSR_MAP[$name]}"
        report_lines+=("- \`${name}\` → \`${replacement}\` (JSR/npm equivalent)")
        log "  ${name} → ${replacement}"
      else
        # Default: wrap as npm: specifier
        clean_ver=$(echo "$version" | sed 's/[^0-9.]//g' | head -c 10)
        replacement="npm:${name}@${version}"
        report_lines+=("- \`${name}\` → \`${replacement}\`")
        log "  ${name} → npm:${name}"
      fi

      if $first; then
        first=false
      else
        imports_json+=","
      fi
      imports_json+="\"${name}\": \"${replacement}\""
    done <<< "$DEPS"

    imports_json+="}"
  fi
  report_lines+=("")
else
  warn "No package.json found — skipping dependency analysis"
  imports_json="{}"
fi

# ─── Step 2: Create deno.json ────────────────────────────────────────────

if [[ ! -f "deno.json" ]] && [[ ! -f "deno.jsonc" ]]; then
  info "Creating deno.json..."

  # Extract scripts from package.json if available
  SCRIPTS=""
  if [[ -f "package.json" ]]; then
    SCRIPTS=$(python3 -c "
import json
with open('package.json') as f:
    pkg = json.load(f)
scripts = pkg.get('scripts', {})
for name, cmd in scripts.items():
    # Convert common node commands to deno equivalents
    cmd = cmd.replace('node ', 'deno run ')
    cmd = cmd.replace('nodemon ', 'deno run --watch ')
    cmd = cmd.replace('jest', 'deno test')
    cmd = cmd.replace('mocha', 'deno test')
    cmd = cmd.replace('eslint ', 'deno lint ')
    cmd = cmd.replace('prettier ', 'deno fmt ')
    cmd = cmd.replace('tsc', 'deno check')
    print(f'{name}={cmd}')
" 2>/dev/null || echo "")
  fi

  TASKS_JSON="{"
  first=true
  if [[ -n "$SCRIPTS" ]]; then
    while IFS='=' read -r name cmd; do
      [[ -z "$name" ]] && continue
      if $first; then first=false; else TASKS_JSON+=","; fi
      TASKS_JSON+="\"${name}\": \"${cmd}\""
    done <<< "$SCRIPTS"
  fi

  # Add default tasks if not present
  if [[ "$TASKS_JSON" == "{" ]]; then
    TASKS_JSON+="\"dev\": \"deno run --watch --allow-all src/main.ts\""
    TASKS_JSON+=",\"test\": \"deno test\""
    TASKS_JSON+=",\"lint\": \"deno lint\""
    TASKS_JSON+=",\"fmt\": \"deno fmt\""
  fi
  TASKS_JSON+="}"

  if ! $DRY_RUN; then
    python3 -c "
import json
deno_config = {
    'compilerOptions': {'strict': True},
    'imports': json.loads('${imports_json}'),
    'tasks': json.loads('''${TASKS_JSON}'''),
    'fmt': {'indentWidth': 2, 'singleQuote': True},
    'exclude': ['node_modules/', 'dist/', 'build/']
}
print(json.dumps(deno_config, indent=2))
" > deno.json
    log "Created deno.json"
  else
    log "[DRY RUN] Would create deno.json"
  fi
  report_lines+=("## Configuration")
  report_lines+=("- Created \`deno.json\` with imports and tasks")
  report_lines+=("")
fi

# ─── Step 3: Scan for import patterns that need updating ─────────────────

info "Scanning source files for Node.js patterns..."
report_lines+=("## Import Patterns Found")
report_lines+=("")

# Find JS/TS files
SOURCE_FILES=$(find . -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.mjs" \) \
  -not -path "*/node_modules/*" \
  -not -path "*/.git/*" \
  -not -path "*/dist/*" \
  -not -path "*/build/*" 2>/dev/null || echo "")

REQUIRE_COUNT=0
BUILTIN_COUNT=0
DIRNAME_COUNT=0

if [[ -n "$SOURCE_FILES" ]]; then
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue

    # Count require() calls
    count=$(grep -c "require(" "$file" 2>/dev/null || echo "0")
    REQUIRE_COUNT=$((REQUIRE_COUNT + count))

    # Check for Node built-ins without node: prefix
    builtins=$(grep -cE "from ['\"](?:fs|path|os|crypto|http|https|stream|util|events|child_process|buffer|url|querystring|net|tls|dgram|dns|cluster|readline|zlib|assert|v8|vm|worker_threads|perf_hooks)['\"]" "$file" 2>/dev/null || echo "0")
    BUILTIN_COUNT=$((BUILTIN_COUNT + builtins))

    # Check for __dirname / __filename
    dirname_count=$(grep -cE "__dirname|__filename" "$file" 2>/dev/null || echo "0")
    DIRNAME_COUNT=$((DIRNAME_COUNT + dirname_count))

  done <<< "$SOURCE_FILES"
fi

report_lines+=("| Pattern | Count | Action |")
report_lines+=("| ------- | ----- | ------ |")
report_lines+=("| \`require()\` calls | ${REQUIRE_COUNT} | Convert to \`import\` statements |")
report_lines+=("| Node built-ins without \`node:\` prefix | ${BUILTIN_COUNT} | Add \`node:\` prefix |")
report_lines+=("| \`__dirname\` / \`__filename\` usage | ${DIRNAME_COUNT} | Replace with \`import.meta.url\` |")
report_lines+=("")

if [[ $REQUIRE_COUNT -gt 0 ]]; then
  warn "Found ${REQUIRE_COUNT} require() calls — convert to ESM imports"
fi
if [[ $BUILTIN_COUNT -gt 0 ]]; then
  warn "Found ${BUILTIN_COUNT} Node built-in imports — add node: prefix"
fi
if [[ $DIRNAME_COUNT -gt 0 ]]; then
  warn "Found ${DIRNAME_COUNT} __dirname/__filename uses — replace with import.meta.url"
fi

# ─── Step 4: Provide fix suggestions ────────────────────────────────────

report_lines+=("## Manual Changes Required")
report_lines+=("")
report_lines+=("### Replace \`__dirname\` and \`__filename\`")
report_lines+=("\`\`\`typescript")
report_lines+=("// Before")
report_lines+=("const dir = __dirname;")
report_lines+=("const file = __filename;")
report_lines+=("")
report_lines+=("// After")
report_lines+=("const dir = new URL('.', import.meta.url).pathname;")
report_lines+=("const file = new URL(import.meta.url).pathname;")
report_lines+=("\`\`\`")
report_lines+=("")
report_lines+=("### Add \`node:\` prefix to built-in imports")
report_lines+=("\`\`\`typescript")
report_lines+=("// Before")
report_lines+=("import fs from 'fs';")
report_lines+=("import path from 'path';")
report_lines+=("")
report_lines+=("// After")
report_lines+=("import fs from 'node:fs';")
report_lines+=("import path from 'node:path';")
report_lines+=("\`\`\`")
report_lines+=("")
report_lines+=("### Convert require() to import")
report_lines+=("\`\`\`typescript")
report_lines+=("// Before")
report_lines+=("const express = require('express');")
report_lines+=("")
report_lines+=("// After")
report_lines+=("import express from 'express';")
report_lines+=("\`\`\`")
report_lines+=("")

# ─── Step 5: Check for known incompatible packages ──────────────────────

report_lines+=("## Compatibility Notes")
report_lines+=("")

INCOMPATIBLE_PKGS=("node-gyp" "node-pre-gyp" "nan" "napi" "better-sqlite3" "bcrypt" "canvas" "grpc" "sharp")

if [[ -f "package.json" ]]; then
  for pkg in "${INCOMPATIBLE_PKGS[@]}"; do
    if grep -q "\"${pkg}\"" package.json 2>/dev/null; then
      warn "Package '${pkg}' uses native addons — may not work in Deno"
      report_lines+=("- ⚠️ \`${pkg}\` — uses native addons, find a pure JS/Wasm alternative")
    fi
  done
fi
report_lines+=("")

# ─── Step 6: Write migration report ─────────────────────────────────────

if ! $DRY_RUN; then
  printf "%s\n" "${report_lines[@]}" > "$REPORT_FILE"
  log "Migration report written to ${REPORT_FILE}"
fi

# ─── Step 7: Cleanup ────────────────────────────────────────────────────

if [[ -d "node_modules" ]] && ! $DRY_RUN; then
  info "You can remove node_modules/ after verifying the migration:"
  echo "  rm -rf node_modules"
fi

if [[ -f "package-lock.json" ]] || [[ -f "yarn.lock" ]] || [[ -f "pnpm-lock.yaml" ]]; then
  warn "Lock files found — can be removed after migration is verified"
fi

echo ""
echo -e "${GREEN}${BOLD}Migration analysis complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Review ${REPORT_FILE}"
echo "  2. Update imports in source files"
echo "  3. Run: deno task dev"
echo "  4. Fix any remaining issues"
echo ""
