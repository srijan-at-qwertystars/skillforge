#!/usr/bin/env bash
#
# setup-project.sh — Initialize semantic-release in a Node.js project
#
# Usage:
#   ./setup-project.sh                  # Interactive setup in current directory
#   ./setup-project.sh --ci github      # Non-interactive, GitHub Actions
#   ./setup-project.sh --ci gitlab      # Non-interactive, GitLab CI
#   ./setup-project.sh --no-commitlint  # Skip commitlint+husky setup
#   ./setup-project.sh --dry-run        # Show what would be done without doing it
#
# Prerequisites:
#   - Node.js >= 18 and npm installed
#   - Git repository initialized
#   - package.json exists
#
# What this script does:
#   1. Installs semantic-release and common plugins
#   2. Creates .releaserc.json configuration
#   3. Optionally sets up commitlint + husky for commit message linting
#   4. Creates CI workflow file (GitHub Actions or GitLab CI)
#   5. Adds release script to package.json

set -euo pipefail

# --- Defaults ---
CI_PLATFORM=""
SKIP_COMMITLINT=false
DRY_RUN=false
BRANCH="main"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci)        CI_PLATFORM="$2"; shift 2 ;;
    --branch)    BRANCH="$2"; shift 2 ;;
    --no-commitlint) SKIP_COMMITLINT=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    -h|--help)
      head -20 "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Preflight checks ---
if ! command -v node &>/dev/null; then
  err "Node.js is not installed. Install Node.js >= 18 first."
  exit 1
fi

if ! command -v npm &>/dev/null; then
  err "npm is not installed."
  exit 1
fi

if [[ ! -f package.json ]]; then
  err "No package.json found. Run 'npm init' first or cd to your project root."
  exit 1
fi

if [[ ! -d .git ]]; then
  err "Not a Git repository. Run 'git init' first."
  exit 1
fi

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [[ "$NODE_VERSION" -lt 18 ]]; then
  warn "Node.js version $(node -v) detected. semantic-release requires Node.js >= 18."
fi

# Detect default branch
if git rev-parse --verify "$BRANCH" &>/dev/null; then
  info "Using branch: $BRANCH"
elif git rev-parse --verify main &>/dev/null; then
  BRANCH="main"
  info "Using detected branch: main"
elif git rev-parse --verify master &>/dev/null; then
  BRANCH="master"
  info "Using detected branch: master"
fi

# --- Interactive CI selection if not specified ---
if [[ -z "$CI_PLATFORM" ]]; then
  echo ""
  echo "Select CI platform:"
  echo "  1) GitHub Actions"
  echo "  2) GitLab CI"
  echo "  3) Skip CI setup"
  read -rp "Choice [1]: " choice
  case "${choice:-1}" in
    1) CI_PLATFORM="github" ;;
    2) CI_PLATFORM="gitlab" ;;
    3) CI_PLATFORM="none" ;;
    *) CI_PLATFORM="github" ;;
  esac
fi

if $DRY_RUN; then
  info "Dry-run mode — showing what would be done:"
  echo ""
  echo "  1. Install: semantic-release + 6 plugins"
  echo "  2. Create: .releaserc.json"
  [[ "$CI_PLATFORM" == "github" ]] && echo "  3. Create: .github/workflows/release.yml"
  [[ "$CI_PLATFORM" == "gitlab" ]] && echo "  3. Create: .gitlab-ci.yml (release stage)"
  $SKIP_COMMITLINT || echo "  4. Install & configure: commitlint + husky"
  echo "  5. Add 'release' script to package.json"
  exit 0
fi

# --- Step 1: Install semantic-release + plugins ---
info "Installing semantic-release and plugins..."
npm install --save-dev \
  semantic-release \
  @semantic-release/commit-analyzer \
  @semantic-release/release-notes-generator \
  @semantic-release/changelog \
  @semantic-release/npm \
  @semantic-release/github \
  @semantic-release/git

log "semantic-release and plugins installed"

# --- Step 2: Create .releaserc.json ---
if [[ -f .releaserc.json || -f .releaserc || -f .releaserc.yml || -f release.config.js || -f release.config.cjs || -f release.config.mjs ]]; then
  warn "Release config already exists — skipping .releaserc.json creation"
else
  cat > .releaserc.json << 'RELEASERC'
{
  "branches": ["main"],
  "plugins": [
    ["@semantic-release/commit-analyzer", {
      "preset": "conventionalcommits",
      "releaseRules": [
        { "type": "feat", "release": "minor" },
        { "type": "fix", "release": "patch" },
        { "type": "perf", "release": "patch" },
        { "type": "revert", "release": "patch" },
        { "breaking": true, "release": "major" }
      ]
    }],
    ["@semantic-release/release-notes-generator", {
      "preset": "conventionalcommits"
    }],
    ["@semantic-release/changelog", {
      "changelogFile": "CHANGELOG.md"
    }],
    ["@semantic-release/npm"],
    ["@semantic-release/github"],
    ["@semantic-release/git", {
      "assets": ["CHANGELOG.md", "package.json", "package-lock.json"],
      "message": "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}"
    }]
  ]
}
RELEASERC

  # Update branch name if not main
  if [[ "$BRANCH" != "main" ]]; then
    sed -i "s/\"main\"/\"$BRANCH\"/" .releaserc.json
  fi

  log "Created .releaserc.json"
fi

# --- Step 3: CI workflow ---
case "$CI_PLATFORM" in
  github)
    mkdir -p .github/workflows
    cat > .github/workflows/release.yml << 'GHACTION'
name: Release
on:
  push:
    branches: [main]

permissions:
  contents: write
  issues: write
  pull-requests: write

jobs:
  release:
    name: Semantic Release
    runs-on: ubuntu-latest
    if: "!contains(github.event.head_commit.message, '[skip ci]')"
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: lts/*
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Release
        run: npx semantic-release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
GHACTION

    if [[ "$BRANCH" != "main" ]]; then
      sed -i "s/branches: \[main\]/branches: [$BRANCH]/" .github/workflows/release.yml
    fi

    log "Created .github/workflows/release.yml"
    ;;

  gitlab)
    if [[ -f .gitlab-ci.yml ]]; then
      warn ".gitlab-ci.yml already exists — appending release stage"
      cat >> .gitlab-ci.yml << 'GITLABCI'

# --- semantic-release ---
release:
  image: node:lts
  stage: release
  script:
    - npm ci
    - npx semantic-release
  only:
    - main
  variables:
    GITLAB_TOKEN: $GITLAB_TOKEN
    NPM_TOKEN: $NPM_TOKEN
GITLABCI
    else
      cat > .gitlab-ci.yml << 'GITLABCI'
stages:
  - test
  - release

release:
  image: node:lts
  stage: release
  script:
    - npm ci
    - npx semantic-release
  only:
    - main
  variables:
    GITLAB_TOKEN: $GITLAB_TOKEN
    NPM_TOKEN: $NPM_TOKEN
GITLABCI
    fi

    if [[ "$BRANCH" != "main" ]]; then
      sed -i "s/- main/- $BRANCH/" .gitlab-ci.yml
    fi

    log "Created/updated .gitlab-ci.yml with release stage"
    ;;

  none|"")
    info "Skipping CI setup"
    ;;
esac

# --- Step 4: commitlint + husky ---
if ! $SKIP_COMMITLINT; then
  info "Setting up commitlint + husky..."

  npm install --save-dev \
    @commitlint/cli \
    @commitlint/config-conventional \
    husky

  # Create commitlint config
  if [[ ! -f commitlint.config.js && ! -f .commitlintrc.js && ! -f .commitlintrc.json ]]; then
    cat > commitlint.config.js << 'COMMITLINT'
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [2, 'always', [
      'feat', 'fix', 'docs', 'style', 'refactor',
      'perf', 'test', 'build', 'ci', 'chore', 'revert',
    ]],
    'subject-case': [2, 'never', ['start-case', 'pascal-case', 'upper-case']],
    'header-max-length': [2, 'always', 100],
    'body-max-line-length': [1, 'always', 200],
  },
};
COMMITLINT
    log "Created commitlint.config.js"
  fi

  # Initialize husky
  npx husky init 2>/dev/null || npx husky install 2>/dev/null || true
  mkdir -p .husky

  cat > .husky/commit-msg << 'HUSKY'
#!/usr/bin/env sh
. "$(dirname -- "$0")/_/husky.sh" 2>/dev/null || true
npx --no -- commitlint --edit "$1"
HUSKY
  chmod +x .husky/commit-msg

  log "Configured commitlint + husky"
fi

# --- Step 5: Add release script to package.json ---
if command -v npx &>/dev/null && npx -y json --version &>/dev/null 2>&1; then
  npx -y json -I -f package.json -e 'this.scripts = this.scripts || {}; this.scripts.release = "semantic-release"'
  log "Added 'release' script to package.json"
else
  # Fallback: check if scripts.release exists
  if ! grep -q '"release"' package.json 2>/dev/null; then
    warn "Add this to package.json scripts manually:"
    echo '    "release": "semantic-release"'
  fi
fi

# --- Done ---
echo ""
log "semantic-release setup complete!"
echo ""
info "Next steps:"
echo "  1. Ensure your commits follow Conventional Commits format"
echo "     Example: feat(auth): add login page"
echo "  2. Set required CI secrets:"
[[ "$CI_PLATFORM" == "github" ]] && echo "     - GITHUB_TOKEN (automatic in GitHub Actions)"
[[ "$CI_PLATFORM" == "gitlab" ]] && echo "     - GITLAB_TOKEN (create in Settings > Access Tokens)"
echo "     - NPM_TOKEN (create at npmjs.com > Access Tokens > Automation)"
echo "  3. Push to '$BRANCH' branch to trigger your first release"
echo "  4. Test locally: npx semantic-release --dry-run --no-ci"
