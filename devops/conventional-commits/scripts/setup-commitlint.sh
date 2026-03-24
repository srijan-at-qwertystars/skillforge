#!/usr/bin/env bash
#
# setup-commitlint.sh — Install and configure commitlint + Husky + lint-staged
#
# Usage:
#   ./setup-commitlint.sh                  # Auto-detect package manager, default config
#   ./setup-commitlint.sh --pm npm         # Force npm
#   ./setup-commitlint.sh --pm pnpm        # Force pnpm
#   ./setup-commitlint.sh --pm yarn        # Force yarn
#   ./setup-commitlint.sh --scopes "api,auth,ui"   # Restrict allowed scopes
#   ./setup-commitlint.sh --no-lint-staged  # Skip lint-staged setup
#   ./setup-commitlint.sh --no-commitizen   # Skip commitizen setup
#
# What it does:
#   1. Installs @commitlint/cli + @commitlint/config-conventional
#   2. Installs and initializes Husky v9
#   3. Creates .husky/commit-msg hook for commitlint
#   4. Optionally installs lint-staged with pre-commit hook
#   5. Optionally installs commitizen with cz-conventional-changelog
#   6. Creates commitlint.config.js
#   7. Adds scripts to package.json
#
# Requirements:
#   - Node.js >= 18
#   - A package.json in the current directory (or --init to create one)
#   - Git repository initialized

set -euo pipefail

# --- Defaults ---
PM=""
SCOPES=""
INSTALL_LINT_STAGED=true
INSTALL_COMMITIZEN=true

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC}  $*"; }
ok()    { echo -e "${GREEN}✔${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
fail()  { echo -e "${RED}✖${NC}  $*" >&2; exit 1; }

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pm)           PM="$2"; shift 2 ;;
    --scopes)       SCOPES="$2"; shift 2 ;;
    --no-lint-staged)  INSTALL_LINT_STAGED=false; shift ;;
    --no-commitizen)   INSTALL_COMMITIZEN=false; shift ;;
    -h|--help)
      sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
      exit 0
      ;;
    *) fail "Unknown option: $1" ;;
  esac
done

# --- Checks ---
[[ -f "package.json" ]] || fail "No package.json found. Run 'npm init -y' first."
git rev-parse --git-dir &>/dev/null || fail "Not a git repository. Run 'git init' first."
command -v node &>/dev/null || fail "Node.js is required."

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
[[ "$NODE_VERSION" -ge 18 ]] || fail "Node.js >= 18 required (found v$NODE_VERSION)."

# --- Detect package manager ---
detect_pm() {
  if [[ -n "$PM" ]]; then return; fi
  if [[ -f "pnpm-lock.yaml" ]]; then PM="pnpm"
  elif [[ -f "yarn.lock" ]]; then PM="yarn"
  elif [[ -f "package-lock.json" ]] || [[ -f "npm-shrinkwrap.json" ]]; then PM="npm"
  else PM="npm"
  fi
}
detect_pm

install_dev() {
  case "$PM" in
    npm)  npm install --save-dev "$@" ;;
    yarn) yarn add --dev "$@" ;;
    pnpm) pnpm add --save-dev "$@" ;;
  esac
}

info "Using package manager: ${PM}"
echo ""

# --- Step 1: Install commitlint ---
info "Installing commitlint..."
install_dev @commitlint/cli @commitlint/config-conventional
ok "commitlint installed"

# --- Step 2: Create commitlint config ---
if [[ -f "commitlint.config.js" ]] || [[ -f "commitlint.config.cjs" ]] || [[ -f ".commitlintrc.js" ]]; then
  warn "commitlint config already exists — skipping"
else
  if [[ -n "$SCOPES" ]]; then
    IFS=',' read -ra SCOPE_ARRAY <<< "$SCOPES"
    SCOPE_LIST=$(printf "'%s', " "${SCOPE_ARRAY[@]}")
    SCOPE_LIST="${SCOPE_LIST%, }"

    cat > commitlint.config.js << CONFIGEOF
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'header-max-length': [2, 'always', 100],
    'body-max-line-length': [2, 'always', 200],
    'scope-enum': [2, 'always', [${SCOPE_LIST}]],
    'scope-case': [2, 'always', 'lower-case'],
    'subject-case': [2, 'never', ['start-case', 'pascal-case', 'upper-case']],
    'subject-full-stop': [2, 'never', '.'],
    'type-case': [2, 'always', 'lower-case'],
    'type-empty': [2, 'never'],
  },
};
CONFIGEOF
  else
    cat > commitlint.config.js << 'CONFIGEOF'
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'header-max-length': [2, 'always', 100],
    'body-max-line-length': [2, 'always', 200],
    'scope-case': [2, 'always', 'lower-case'],
    'subject-case': [2, 'never', ['start-case', 'pascal-case', 'upper-case']],
    'subject-full-stop': [2, 'never', '.'],
    'type-case': [2, 'always', 'lower-case'],
    'type-empty': [2, 'never'],
  },
};
CONFIGEOF
  fi
  ok "Created commitlint.config.js"
fi

# --- Step 3: Install and init Husky ---
info "Installing Husky..."
install_dev husky
ok "Husky installed"

info "Initializing Husky..."
npx husky init 2>/dev/null || true
ok "Husky initialized (.husky/ directory created)"

# --- Step 4: Create commit-msg hook ---
echo 'npx --no -- commitlint --edit "$1"' > .husky/commit-msg
ok "Created .husky/commit-msg hook"

# --- Step 5: lint-staged (optional) ---
if [[ "$INSTALL_LINT_STAGED" == true ]]; then
  info "Installing lint-staged..."
  install_dev lint-staged
  echo 'npx lint-staged' > .husky/pre-commit
  ok "Created .husky/pre-commit hook"

  # Add default lint-staged config if not present
  if ! grep -q '"lint-staged"' package.json 2>/dev/null; then
    node -e "
      const pkg = require('./package.json');
      pkg['lint-staged'] = pkg['lint-staged'] || {
        '*.{js,jsx,ts,tsx}': ['eslint --fix', 'prettier --write'],
        '*.{json,md,yml,yaml}': ['prettier --write']
      };
      require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
    "
    ok "Added lint-staged config to package.json"
  fi
fi

# --- Step 6: Commitizen (optional) ---
if [[ "$INSTALL_COMMITIZEN" == true ]]; then
  info "Installing commitizen..."
  install_dev commitizen cz-conventional-changelog
  node -e "
    const pkg = require('./package.json');
    pkg.config = pkg.config || {};
    pkg.config.commitizen = pkg.config.commitizen || { path: 'cz-conventional-changelog' };
    pkg.scripts = pkg.scripts || {};
    pkg.scripts.commit = pkg.scripts.commit || 'cz';
    require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
  "
  ok "Commitizen configured (run 'npm run commit' for interactive commits)"
fi

# --- Step 7: Verify ---
echo ""
info "Verifying setup..."
echo "feat: test message" | npx commitlint 2>/dev/null && ok "commitlint validation works" || warn "commitlint validation test failed"
echo "bad message" | npx commitlint 2>/dev/null && warn "commitlint should have rejected this" || ok "commitlint correctly rejects bad messages"

echo ""
echo -e "${GREEN}━━━ Setup complete! ━━━${NC}"
echo ""
echo "  Hooks installed:     .husky/commit-msg"
[[ "$INSTALL_LINT_STAGED" == true ]] && echo "                       .husky/pre-commit (lint-staged)"
echo "  Config:              commitlint.config.js"
echo "  Test:                echo 'feat: test' | npx commitlint"
[[ "$INSTALL_COMMITIZEN" == true ]] && echo "  Interactive commit:  npm run commit"
echo ""
