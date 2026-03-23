#!/usr/bin/env bash
# jest-to-vitest.sh — Automated Jest-to-Vitest migration.
# Transforms jest.* calls to vi.*, updates config, and optionally renames files.
# Usage: ./jest-to-vitest.sh [--dry-run] [--dir <path>] [--rename-config]

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[info]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }

# Defaults
DRY_RUN=false
TARGET_DIR="src"
RENAME_CONFIG=false
CHANGED_FILES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Automated Jest-to-Vitest migration tool. Transforms test files in place.

Options:
  --dry-run        Show what would be changed without modifying files
  --dir <path>     Directory to scan for test files (default: src)
  --rename-config  Rename jest.config.* to vitest.config.ts
  -h, --help       Show this help

What it does:
  1. Replaces jest.fn/mock/spyOn/etc with vi.fn/mock/spyOn/etc
  2. Converts jest.requireActual to vi.importActual (marks async)
  3. Adds 'import { vi } from "vitest"' where needed
  4. Replaces @types/jest with vitest types
  5. Updates @testing-library/jest-dom import
  6. Optionally renames jest.config to vitest.config

ALWAYS review changes manually after running. The jest.requireActual → vi.importActual
conversion makes the call async, which may require wrapping in async functions.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true; shift ;;
    --dir)           TARGET_DIR="$2"; shift 2 ;;
    --rename-config) RENAME_CONFIG=true; shift ;;
    -h|--help)       usage ;;
    *) error "Unknown option: $1"; usage ;;
  esac
done

if [[ ! -d "$TARGET_DIR" ]]; then
  error "Directory not found: $TARGET_DIR"
  exit 1
fi

# Find test files
TEST_FILES=$(find "$TARGET_DIR" -type f \( \
  -name "*.test.ts" -o -name "*.test.tsx" -o \
  -name "*.test.js" -o -name "*.test.jsx" -o \
  -name "*.spec.ts" -o -name "*.spec.tsx" -o \
  -name "*.spec.js" -o -name "*.spec.jsx" \
\) 2>/dev/null || true)

if [[ -z "$TEST_FILES" ]]; then
  warn "No test files found in $TARGET_DIR"
  exit 0
fi

FILE_COUNT=$(echo "$TEST_FILES" | wc -l | tr -d ' ')
info "Found $FILE_COUNT test file(s) in $TARGET_DIR"

transform_file() {
  local file="$1"
  local tmp="${file}.vitest-migrate.tmp"
  local modified=false

  cp "$file" "$tmp"

  # 1. Replace jest.* namespace calls with vi.*
  local replacements=(
    's/\bjest\.fn\b/vi.fn/g'
    's/\bjest\.mock\b/vi.mock/g'
    's/\bjest\.unmock\b/vi.unmock/g'
    's/\bjest\.spyOn\b/vi.spyOn/g'
    's/\bjest\.useFakeTimers\b/vi.useFakeTimers/g'
    's/\bjest\.useRealTimers\b/vi.useRealTimers/g'
    's/\bjest\.advanceTimersByTime\b/vi.advanceTimersByTime/g'
    's/\bjest\.advanceTimersToNextTimer\b/vi.advanceTimersToNextTimer/g'
    's/\bjest\.runAllTimers\b/vi.runAllTimers/g'
    's/\bjest\.runOnlyPendingTimers\b/vi.runOnlyPendingTimers/g'
    's/\bjest\.clearAllTimers\b/vi.clearAllTimers/g'
    's/\bjest\.clearAllMocks\b/vi.clearAllMocks/g'
    's/\bjest\.resetAllMocks\b/vi.resetAllMocks/g'
    's/\bjest\.restoreAllMocks\b/vi.restoreAllMocks/g'
    's/\bjest\.resetModules\b/vi.resetModules/g'
    's/\bjest\.setSystemTime\b/vi.setSystemTime/g'
    's/\bjest\.getRealSystemTime\b/vi.getRealSystemTime/g'
    's/\bjest\.isMockFunction\b/vi.isMockFunction/g'
    's/\bjest\.mocked\b/vi.mocked/g'
  )

  for pattern in "${replacements[@]}"; do
    if grep -qP "$(echo "$pattern" | sed 's|s/||;s|/.*||;s|\\b||g')" "$tmp" 2>/dev/null; then
      sed -i -E "$pattern" "$tmp"
      modified=true
    fi
  done

  # 2. Convert jest.requireActual → vi.importActual (async!)
  if grep -q 'jest\.requireActual' "$tmp" 2>/dev/null; then
    sed -i -E 's/\bjest\.requireActual\b/vi.importActual/g' "$tmp"
    modified=true
    warn "  ⚠ $file: jest.requireActual → vi.importActual (now async — review needed)"
  fi

  # 3. Convert jest.requireMock → vi.importMock
  if grep -q 'jest\.requireMock' "$tmp" 2>/dev/null; then
    sed -i -E 's/\bjest\.requireMock\b/vi.importMock/g' "$tmp"
    modified=true
  fi

  # 4. Replace @jest/globals imports with vitest
  if grep -q "@jest/globals" "$tmp" 2>/dev/null; then
    sed -i "s|from '@jest/globals'|from 'vitest'|g" "$tmp"
    sed -i 's|from "@jest/globals"|from "vitest"|g' "$tmp"
    modified=true
  fi

  # 5. Replace @testing-library/jest-dom with vitest variant
  if grep -q "@testing-library/jest-dom'" "$tmp" 2>/dev/null || \
     grep -q '@testing-library/jest-dom"' "$tmp" 2>/dev/null; then
    # Only replace the bare import, not /vitest
    if ! grep -q "@testing-library/jest-dom/vitest" "$tmp" 2>/dev/null; then
      sed -i "s|@testing-library/jest-dom'|@testing-library/jest-dom/vitest'|g" "$tmp"
      sed -i 's|@testing-library/jest-dom"|@testing-library/jest-dom/vitest"|g' "$tmp"
      modified=true
    fi
  fi

  # 6. Add vi import if vi.* is used but not imported
  if grep -q '\bvi\.' "$tmp" 2>/dev/null; then
    if ! grep -qE "from ['\"]vitest['\"]" "$tmp" 2>/dev/null; then
      # Determine which vitest exports are used
      local imports="vi"
      grep -q '\bdescribe\b' "$tmp" && imports="${imports}, describe"
      grep -q '\b\(it\|test\)\b' "$tmp" && imports="${imports}, it, test"
      grep -q '\bexpect\b' "$tmp" && imports="${imports}, expect"
      grep -q '\bbeforeEach\b' "$tmp" && imports="${imports}, beforeEach"
      grep -q '\bafterEach\b' "$tmp" && imports="${imports}, afterEach"
      grep -q '\bbeforeAll\b' "$tmp" && imports="${imports}, beforeAll"
      grep -q '\bafterAll\b' "$tmp" && imports="${imports}, afterAll"

      # Add import at top of file (after any existing imports or at line 1)
      sed -i "1i import { ${imports} } from 'vitest';" "$tmp"
      modified=true
    fi
  fi

  if [[ "$modified" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo -e "  ${YELLOW}[dry-run]${NC} Would modify: $file"
      diff --color=auto "$file" "$tmp" 2>/dev/null || true
      rm "$tmp"
    else
      mv "$tmp" "$file"
      ok "  Modified: $file"
    fi
    CHANGED_FILES=$((CHANGED_FILES + 1))
  else
    rm "$tmp"
  fi
}

# Process all test files
info "Transforming test files..."
while IFS= read -r file; do
  transform_file "$file"
done <<< "$TEST_FILES"

# Also process setup files
for setup_file in test/setup.ts test/setup.js test/setup.tsx setupTests.ts setupTests.js; do
  if [[ -f "$setup_file" ]]; then
    info "Processing setup file: $setup_file"
    transform_file "$setup_file"
  fi
done

# Rename jest.config if requested
if [[ "$RENAME_CONFIG" == true ]]; then
  for config in jest.config.ts jest.config.js jest.config.mjs jest.config.cjs; do
    if [[ -f "$config" ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} Would rename: $config → vitest.config.ts"
      else
        warn "  $config found — create vitest.config.ts manually (configs are not 1:1)"
        warn "  See migration-from-jest.md for config mapping"
      fi
    fi
  done
fi

echo ""
echo "================================"
if [[ "$DRY_RUN" == true ]]; then
  info "Dry run complete. $CHANGED_FILES file(s) would be modified."
else
  ok "Migration complete. $CHANGED_FILES file(s) modified."
fi
echo ""
warn "Important post-migration steps:"
echo "  1. Review all changes, especially jest.requireActual → vi.importActual (async)"
echo "  2. Create vitest.config.ts from jest.config (see migration-from-jest.md)"
echo "  3. Install vitest: npm install -D vitest @vitest/coverage-v8"
echo "  4. Remove jest: npm uninstall jest ts-jest babel-jest @types/jest"
echo "  5. Update package.json scripts"
echo "  6. Run tests: npx vitest run"
echo "  7. Update snapshots if needed: npx vitest run --update"
