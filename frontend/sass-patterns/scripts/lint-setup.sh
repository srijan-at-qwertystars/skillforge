#!/usr/bin/env bash
# lint-setup.sh — Set up stylelint with SCSS plugin and recommended rules
#
# Usage:
#   ./lint-setup.sh                   # Set up in current directory
#   ./lint-setup.sh --config-only     # Only generate config, skip install
#   ./lint-setup.sh --with-prettier   # Also add prettier integration
#
# Creates: .stylelintrc.json, .stylelintignore, adds lint scripts to package.json
# Prerequisites: Node.js 18+, existing package.json

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_ONLY=false
WITH_PRETTIER=false

log()   { echo -e "${GREEN}[lint-setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-only)   CONFIG_ONLY=true; shift ;;
    --with-prettier) WITH_PRETTIER=true; shift ;;
    -h|--help)       sed -n '2,9p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)               error "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Check prerequisites ---
[[ -f package.json ]] || { error "No package.json found. Run from project root."; exit 1; }

# --- Install packages ---
if ! $CONFIG_ONLY; then
  PACKAGES=(
    stylelint
    stylelint-config-standard-scss
    stylelint-order
  )
  $WITH_PRETTIER && PACKAGES+=(stylelint-config-prettier-scss)

  log "Installing: ${PACKAGES[*]}"
  npm install --save-dev "${PACKAGES[@]}"
fi

# --- Generate .stylelintrc.json ---
EXTENDS='"stylelint-config-standard-scss"'
$WITH_PRETTIER && EXTENDS="$EXTENDS, \"stylelint-config-prettier-scss\""

log "Creating .stylelintrc.json..."
cat > .stylelintrc.json << STYLELINT_EOF
{
  "extends": [$EXTENDS],
  "plugins": ["stylelint-order"],
  "rules": {
    "max-nesting-depth": [3, {
      "ignoreAtRules": ["media", "supports", "container", "include"]
    }],
    "selector-max-compound-selectors": 4,
    "selector-max-id": 0,
    "selector-class-pattern": [
      "^[a-z][a-z0-9]*(-[a-z0-9]+)*(__[a-z0-9]+(-[a-z0-9]+)*)*(--[a-z0-9]+(-[a-z0-9]+)*)?$",
      { "message": "Use kebab-case BEM: block__element--modifier" }
    ],
    "scss/no-global-function-names": true,
    "scss/at-rule-no-unknown": [true, {
      "ignoreAtRules": ["tailwind", "apply", "layer", "container"]
    }],
    "scss/dollar-variable-pattern": "^[a-z][a-z0-9]*(-[a-z0-9]+)*$",
    "scss/percent-placeholder-pattern": "^[a-z][a-z0-9]*(-[a-z0-9]+)*$",
    "declaration-block-no-redundant-longhand-properties": true,
    "shorthand-property-no-redundant-values": true,
    "color-named": "never",
    "color-no-hex": null,
    "order/order": [
      "custom-properties",
      "dollar-variables",
      { "type": "at-rule", "name": "extend" },
      { "type": "at-rule", "name": "include", "hasBlock": false },
      "declarations",
      { "type": "at-rule", "name": "include", "hasBlock": true },
      "rules"
    ],
    "order/properties-order": [
      { "groupName": "position", "properties": ["position", "inset", "top", "right", "bottom", "left", "z-index"] },
      { "groupName": "display", "properties": ["display", "flex", "flex-direction", "flex-wrap", "flex-flow", "justify-content", "align-items", "align-content", "gap", "order", "flex-grow", "flex-shrink", "flex-basis", "align-self"] },
      { "groupName": "grid", "properties": ["grid", "grid-template", "grid-template-columns", "grid-template-rows", "grid-template-areas", "grid-gap", "grid-column", "grid-row", "grid-area"] },
      { "groupName": "box-model", "properties": ["width", "min-width", "max-width", "height", "min-height", "max-height", "margin", "padding", "overflow"] },
      { "groupName": "typography", "properties": ["font", "font-family", "font-size", "font-weight", "line-height", "letter-spacing", "text-align", "text-decoration", "text-transform", "color"] },
      { "groupName": "visual", "properties": ["background", "border", "border-radius", "box-shadow", "opacity", "outline"] },
      { "groupName": "animation", "properties": ["transition", "animation", "transform"] }
    ]
  },
  "ignoreFiles": ["**/node_modules/**", "**/dist/**", "**/build/**", "**/coverage/**"]
}
STYLELINT_EOF

# --- Generate .stylelintignore ---
if [[ ! -f .stylelintignore ]]; then
  log "Creating .stylelintignore..."
  cat > .stylelintignore << 'IGNORE_EOF'
node_modules/
dist/
build/
coverage/
*.min.css
vendor/
IGNORE_EOF
fi

# --- Add npm scripts ---
if command -v node &>/dev/null; then
  HAS_LINT=$(node -e "const p=require('./package.json'); console.log(p.scripts?.['lint:scss'] ? 'yes' : 'no')" 2>/dev/null || echo "no")
  if [[ "$HAS_LINT" == "no" ]]; then
    log "Adding lint scripts to package.json..."
    node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.scripts = pkg.scripts || {};
pkg.scripts['lint:scss'] = 'stylelint \"src/**/*.{scss,css}\"';
pkg.scripts['lint:scss:fix'] = 'stylelint \"src/**/*.{scss,css}\" --fix';
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
  fi
fi

# --- Summary ---
echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Stylelint SCSS setup complete!"
echo ""
echo "  Run:     npm run lint:scss"
echo "  Autofix: npm run lint:scss:fix"
echo ""
echo "  Config:  .stylelintrc.json"
echo "  Ignore:  .stylelintignore"
echo ""
log "Customize rules in .stylelintrc.json as needed."
