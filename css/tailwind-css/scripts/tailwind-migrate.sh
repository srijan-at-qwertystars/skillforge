#!/usr/bin/env bash
# tailwind-migrate.sh — Helper to migrate a project from Tailwind CSS v3 to v4
#
# Usage:
#   ./tailwind-migrate.sh [project-path]
#
# What it does:
#   1. Checks for v3 config (tailwind.config.js/ts)
#   2. Converts theme config to @theme CSS directives (generates output)
#   3. Updates import syntax (@tailwind → @import "tailwindcss")
#   4. Flags deprecated utilities and breaking changes
#   5. Suggests plugin migration
#
# For automated migration, also run: npx @tailwindcss/upgrade
# This script provides analysis + manual guidance for what the auto tool misses.

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; }
header(){ echo -e "\n${BOLD}═══ $1 ═══${NC}"; }

PROJECT_DIR="${1:-.}"

if [ ! -d "$PROJECT_DIR" ]; then
  error "Directory not found: $PROJECT_DIR"
  exit 1
fi

cd "$PROJECT_DIR"
info "Analyzing project in: $(pwd)"

ISSUES=0
WARNINGS=0

# ─── Step 1: Check for v3 config ───
header "Configuration Files"

CONFIG_FILE=""
for f in tailwind.config.js tailwind.config.ts tailwind.config.cjs tailwind.config.mjs; do
  if [ -f "$f" ]; then
    CONFIG_FILE="$f"
    break
  fi
done

if [ -n "$CONFIG_FILE" ]; then
  warn "Found v3 config: $CONFIG_FILE"
  echo "  → v4 uses CSS-first config. Run: npx @tailwindcss/upgrade"
  echo "  → This converts $CONFIG_FILE → @theme blocks in your CSS"
  echo "  → After migration, delete $CONFIG_FILE"
  ((ISSUES++)) || true

  # Check for content array
  if grep -q "content:" "$CONFIG_FILE" 2>/dev/null; then
    warn "content array found in config"
    echo "  → v4 auto-detects files. Remove the content array."
    echo "  → For external paths, use @source in CSS instead."
    ((ISSUES++)) || true
  fi

  # Check for plugins
  if grep -q "require(" "$CONFIG_FILE" 2>/dev/null; then
    warn "JS plugins found (require syntax)"
    PLUGINS=$(grep -oP "require\(['\"]([^'\"]+)['\"]\)" "$CONFIG_FILE" | head -10 || true)
    if [ -n "$PLUGINS" ]; then
      echo "  → Convert to CSS @plugin directives:"
      echo "$PLUGINS" | while read -r line; do
        PLUGIN=$(echo "$line" | grep -oP "(?<=[\'\"])[^'\"]+(?=['\"])")
        echo "    @plugin \"$PLUGIN\";"
      done
    fi
    ((ISSUES++)) || true
  fi

  # Check for theme extensions
  if grep -q "theme:" "$CONFIG_FILE" 2>/dev/null; then
    info "Theme customizations detected"
    echo "  → Convert to @theme {} block in CSS"
    echo "  → Example: theme.extend.colors.brand → --color-brand: #hex;"
    echo "  → Example: theme.extend.fontFamily.sans → --font-sans: 'Inter', sans-serif;"
  fi
else
  ok "No v3 config file found (already migrated or fresh project)"
fi

# ─── Step 2: Check CSS import syntax ───
header "CSS Import Syntax"

OLD_IMPORTS=$(grep -rl "@tailwind " --include="*.css" . 2>/dev/null || true)
if [ -n "$OLD_IMPORTS" ]; then
  warn "v3 @tailwind directives found:"
  echo "$OLD_IMPORTS" | while read -r file; do
    echo "  → $file"
    echo "    Replace:"
    echo "      @tailwind base;"
    echo "      @tailwind components;"
    echo "      @tailwind utilities;"
    echo "    With:"
    echo "      @import \"tailwindcss\";"
  done
  ((ISSUES++)) || true
else
  ok "No legacy @tailwind directives found"
fi

# Check for @import "tailwindcss"
MODERN_IMPORT=$(grep -rl '@import "tailwindcss"' --include="*.css" . 2>/dev/null || true)
if [ -n "$MODERN_IMPORT" ]; then
  ok "v4 import found in: $MODERN_IMPORT"
fi

# ─── Step 3: Deprecated utilities ───
header "Deprecated Utilities"

DEPRECATED_PATTERNS=(
  "flex-shrink-0:shrink-0"
  "flex-shrink:shrink"
  "flex-grow-0:grow-0"
  "flex-grow:grow"
  "overflow-ellipsis:text-ellipsis"
  "decoration-clone:box-decoration-clone"
  "decoration-slice:box-decoration-slice"
)

for pattern in "${DEPRECATED_PATTERNS[@]}"; do
  OLD="${pattern%%:*}"
  NEW="${pattern##*:}"
  MATCHES=$(grep -rn "\b${OLD}\b" --include="*.html" --include="*.jsx" --include="*.tsx" --include="*.vue" --include="*.svelte" --include="*.astro" . 2>/dev/null | head -5 || true)
  if [ -n "$MATCHES" ]; then
    warn "Deprecated: $OLD → $NEW"
    echo "$MATCHES" | while read -r line; do
      echo "  $line"
    done
    ((WARNINGS++)) || true
  fi
done

# Check for opacity utilities
OPACITY_UTILS=$(grep -rn "\b\(bg-opacity-\|text-opacity-\|border-opacity-\|ring-opacity-\|placeholder-opacity-\)" --include="*.html" --include="*.jsx" --include="*.tsx" --include="*.vue" --include="*.svelte" . 2>/dev/null | head -10 || true)
if [ -n "$OPACITY_UTILS" ]; then
  warn "Opacity utilities removed in v4"
  echo "  → Use /modifier syntax instead: bg-blue-500/50, text-gray-900/75"
  echo "$OPACITY_UTILS" | head -5 | while read -r line; do
    echo "  $line"
  done
  ((ISSUES++)) || true
else
  ok "No deprecated opacity utilities found"
fi

# Check for placeholder- prefix
PLACEHOLDER_OLD=$(grep -rn "\bplaceholder-\(gray\|red\|blue\|green\|yellow\|white\|black\)" --include="*.html" --include="*.jsx" --include="*.tsx" --include="*.vue" --include="*.svelte" . 2>/dev/null | head -5 || true)
if [ -n "$PLACEHOLDER_OLD" ]; then
  warn "placeholder-{color} → placeholder:text-{color}"
  echo "$PLACEHOLDER_OLD" | head -3 | while read -r line; do
    echo "  $line"
  done
  ((WARNINGS++)) || true
fi

# ─── Step 4: Check @layer usage ───
header "@layer / @apply Usage"

LAYER_COMPONENTS=$(grep -rn "@layer components" --include="*.css" . 2>/dev/null || true)
if [ -n "$LAYER_COMPONENTS" ]; then
  warn "@layer components found — convert to @utility in v4"
  echo "$LAYER_COMPONENTS" | while read -r line; do
    echo "  $line"
  done
  echo "  → @layer components { .btn { @apply ... } }"
  echo "  → @utility btn { @apply ... }"
  ((WARNINGS++)) || true
fi

APPLY_COUNT=$(grep -rc "@apply" --include="*.css" . 2>/dev/null | awk -F: '{sum += $2} END {print sum+0}')
if [ "$APPLY_COUNT" -gt 0 ]; then
  info "@apply used $APPLY_COUNT times across CSS files"
  if [ "$APPLY_COUNT" -gt 20 ]; then
    warn "Heavy @apply usage — consider refactoring to component abstractions"
  fi
fi

# ─── Step 5: PostCSS config ───
header "PostCSS Configuration"

if [ -f "postcss.config.js" ] || [ -f "postcss.config.cjs" ]; then
  POSTCSS_FILE=""
  for f in postcss.config.js postcss.config.cjs postcss.config.mjs; do
    [ -f "$f" ] && POSTCSS_FILE="$f" && break
  done

  if [ -n "$POSTCSS_FILE" ]; then
    if grep -q "tailwindcss" "$POSTCSS_FILE" 2>/dev/null && ! grep -q "@tailwindcss/postcss" "$POSTCSS_FILE" 2>/dev/null; then
      warn "PostCSS uses old tailwindcss plugin"
      echo "  → Replace 'tailwindcss' with '@tailwindcss/postcss' in $POSTCSS_FILE"
      ((ISSUES++)) || true
    fi

    if grep -q "autoprefixer" "$POSTCSS_FILE" 2>/dev/null; then
      info "autoprefixer found — v4 handles prefixing automatically"
      echo "  → You can remove autoprefixer from PostCSS config"
      ((WARNINGS++)) || true
    fi
  fi
fi

# Check for Vite projects using PostCSS instead of Vite plugin
if [ -f "vite.config.ts" ] || [ -f "vite.config.js" ]; then
  if [ -f "postcss.config.mjs" ] || [ -f "postcss.config.js" ]; then
    info "Vite project with PostCSS config"
    echo "  → Consider using @tailwindcss/vite instead of @tailwindcss/postcss"
    echo "  → Faster builds, no PostCSS config needed"
  fi
fi

# ─── Step 6: Check dependencies ───
header "Dependencies"

if [ -f "package.json" ]; then
  # Check Tailwind version
  TW_VER=$(grep -o '"tailwindcss": *"[^"]*"' package.json 2>/dev/null | grep -o '[0-9][^"]*' || true)
  if [ -n "$TW_VER" ]; then
    info "Current tailwindcss version: $TW_VER"
    case $TW_VER in
      3.*) warn "Still on v3. Run: npm install -D tailwindcss@latest" ; ((ISSUES++)) || true ;;
      4.*) ok "Already on v4" ;;
      *)   info "Unknown version format" ;;
    esac
  fi

  # Check for old packages
  for pkg in "postcss7-compat" "@tailwindcss/jit"; do
    if grep -q "$pkg" package.json 2>/dev/null; then
      warn "Remove deprecated package: $pkg"
      ((ISSUES++)) || true
    fi
  done
fi

# ─── Step 7: Custom variant migration ───
header "Custom Variants"

if [ -n "$CONFIG_FILE" ] && grep -q "addVariant" "$CONFIG_FILE" 2>/dev/null; then
  warn "JS addVariant() calls found — convert to @custom-variant in CSS"
  echo "  → Example: addVariant('hocus', ['&:hover', '&:focus'])"
  echo "  → Becomes: @custom-variant hocus (&:hover, &:focus);"
  ((ISSUES++)) || true
fi

# ─── Summary ───
header "Migration Summary"

echo ""
if [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  ok "No migration issues found! Project appears v4-ready."
else
  [ "$ISSUES" -gt 0 ] && error "$ISSUES issue(s) require changes"
  [ "$WARNINGS" -gt 0 ] && warn "$WARNINGS warning(s) — recommended changes"
  echo ""
  info "Recommended steps:"
  echo "  1. Run: npx @tailwindcss/upgrade (handles most changes automatically)"
  echo "  2. Review the diff and fix any issues flagged above"
  echo "  3. Test: npm run build && npm run dev"
  echo "  4. Delete tailwind.config.js after confirming everything works"
fi
