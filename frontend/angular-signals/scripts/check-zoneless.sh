#!/usr/bin/env bash
# check-zoneless.sh — Analyze an Angular project for zone.js dependencies that block zoneless migration
#
# Usage:
#   ./check-zoneless.sh [project-root]
#   ./check-zoneless.sh /path/to/angular-project
#   ./check-zoneless.sh                            # defaults to current directory
#
# Checks for zone.js references, zone-dependent patterns, and provides a migration readiness score.

set -euo pipefail

TARGET="${1:-.}"
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

issues=0
warnings=0

echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Angular Zoneless Readiness Checker             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Scanning: $TARGET"
echo ""

issue() {
  echo -e "  ${RED}✗ BLOCKER:${NC} $1"
  [ -n "${2:-}" ] && echo -e "    ${CYAN}Fix:${NC} $2"
  issues=$((issues + 1))
}

warn() {
  echo -e "  ${YELLOW}⚠ WARNING:${NC} $1"
  [ -n "${2:-}" ] && echo -e "    ${CYAN}Fix:${NC} $2"
  warnings=$((warnings + 1))
}

ok() {
  echo -e "  ${GREEN}✓${NC} $1"
}

# ── 1. Check angular.json for zone.js polyfill ──
echo -e "${BLUE}[1/7] Checking angular.json polyfills...${NC}"
angular_json=$(find "$TARGET" -maxdepth 2 -name 'angular.json' -not -path '*/node_modules/*' 2>/dev/null | head -1)
if [ -n "$angular_json" ]; then
  if grep -q '"zone.js"' "$angular_json" 2>/dev/null; then
    issue "zone.js is listed in angular.json polyfills" \
      "Remove \"zone.js\" from the polyfills array in angular.json"
  else
    ok "zone.js not in angular.json polyfills"
  fi
else
  warn "angular.json not found — cannot verify polyfill configuration"
fi

# ── 2. Check package.json for zone.js dependency ──
echo -e "${BLUE}[2/7] Checking package.json dependencies...${NC}"
pkg_json=$(find "$TARGET" -maxdepth 2 -name 'package.json' -not -path '*/node_modules/*' 2>/dev/null | head -1)
if [ -n "$pkg_json" ]; then
  if grep -q '"zone.js"' "$pkg_json" 2>/dev/null; then
    warn "zone.js is in package.json dependencies" \
      "Remove zone.js from dependencies after completing migration"
  else
    ok "zone.js not in package.json"
  fi
else
  warn "package.json not found"
fi

# ── 3. Check for zone.js imports in source ──
echo -e "${BLUE}[3/7] Checking for zone.js imports in source files...${NC}"
zone_imports=$(grep -rl "import.*zone.js\|require.*zone.js\|import 'zone.js'\|import \"zone.js\"" \
  "$TARGET" --include='*.ts' --include='*.js' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null || true)
if [ -n "$zone_imports" ]; then
  issue "Direct zone.js imports found:" \
    "Remove these imports after migrating to zoneless"
  echo "$zone_imports" | while read -r f; do echo -e "    ${YELLOW}$f${NC}"; done
else
  ok "No direct zone.js imports in source"
fi

# ── 4. Check for NgZone usage ──
echo -e "${BLUE}[4/7] Checking for NgZone usage...${NC}"
ngzone_files=$(grep -rln "NgZone\|ngZone\|this\._ngZone\|inject(NgZone)" \
  "$TARGET" --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null || true)
if [ -n "$ngzone_files" ]; then
  count=$(echo "$ngzone_files" | wc -l)
  warn "NgZone usage found in $count file(s) — review and remove:" \
    "Replace NgZone.run()/runOutsideAngular() with signal updates"
  echo "$ngzone_files" | head -10 | while read -r f; do echo -e "    ${YELLOW}$f${NC}"; done
  [ "$count" -gt 10 ] && echo -e "    ${YELLOW}... and $((count - 10)) more${NC}"
else
  ok "No NgZone usage found"
fi

# ── 5. Check for zone-dependent async patterns ──
echo -e "${BLUE}[5/7] Checking for zone-dependent async patterns...${NC}"

# setTimeout/setInterval without signal updates
ts_files=$(find "$TARGET" -type f -name '*.ts' \
  ! -path '*/node_modules/*' ! -path '*/dist/*' ! -path '*/.angular/*' \
  ! -name '*.spec.ts' ! -name '*.d.ts' 2>/dev/null || true)

timeout_count=0
if [ -n "$ts_files" ]; then
  while IFS= read -r f; do
    if grep -qE 'setTimeout|setInterval' "$f" 2>/dev/null; then
      timeout_count=$((timeout_count + 1))
    fi
  done <<< "$ts_files"
fi

if [ "$timeout_count" -gt 0 ]; then
  warn "setTimeout/setInterval found in $timeout_count file(s)" \
    "Ensure callbacks update signals to trigger change detection in zoneless mode"
else
  ok "No setTimeout/setInterval patterns found"
fi

# ── 6. Check for ChangeDetectorRef.detectChanges() ──
echo -e "${BLUE}[6/7] Checking for manual change detection calls...${NC}"
cd_files=$(grep -rln "detectChanges()\|ChangeDetectorRef" \
  "$TARGET" --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular \
  --exclude='*.spec.ts' 2>/dev/null || true)
if [ -n "$cd_files" ]; then
  count=$(echo "$cd_files" | wc -l)
  warn "Manual ChangeDetectorRef usage in $count file(s)" \
    "Replace with signal-driven reactivity; markForCheck() still works in zoneless"
  echo "$cd_files" | head -10 | while read -r f; do echo -e "    ${YELLOW}$f${NC}"; done
else
  ok "No manual ChangeDetectorRef usage"
fi

# ── 7. Check for provideExperimentalZonelessChangeDetection ──
echo -e "${BLUE}[7/7] Checking for zoneless provider...${NC}"
zoneless_provider=$(grep -rl "provideExperimentalZonelessChangeDetection\|provideZonelessChangeDetection" \
  "$TARGET" --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null || true)
if [ -n "$zoneless_provider" ]; then
  ok "Zoneless change detection provider is configured"
else
  warn "provideExperimentalZonelessChangeDetection() not found" \
    "Add to app.config.ts providers to enable zoneless mode"
fi

# ── Summary ──
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"

if [ "$issues" -eq 0 ] && [ "$warnings" -eq 0 ]; then
  echo -e "  ${GREEN}🎉 Project appears ready for zoneless migration!${NC}"
elif [ "$issues" -eq 0 ]; then
  echo -e "  ${YELLOW}⚠ $warnings warning(s) — review before going zoneless${NC}"
else
  echo -e "  ${RED}✗ $issues blocker(s), $warnings warning(s)${NC}"
  echo -e "  ${RED}  Resolve blockers before removing zone.js${NC}"
fi

echo ""
echo -e "${CYAN}Migration steps:${NC}"
echo "  1. Fix all blockers above"
echo "  2. Add provideExperimentalZonelessChangeDetection() to app.config.ts"
echo "  3. Remove 'zone.js' from angular.json polyfills"
echo "  4. Remove zone.js from package.json dependencies"
echo "  5. Test all async flows (timers, HTTP, third-party libs)"
