#!/usr/bin/env bash
#
# setup-sentry.sh — Interactive Sentry SDK setup
#
# Usage:
#   ./setup-sentry.sh
#   ./setup-sentry.sh --non-interactive --framework nextjs
#
# Detects project language/framework, installs the appropriate Sentry SDK,
# creates initial configuration, sets up source map uploads (JS/TS),
# and configures .env with DSN placeholder.
#
# Supported frameworks: Node.js, React, Next.js, Vue, Python (Django/Flask/FastAPI), Go, Ruby (Rails)
#
# Environment variables (optional, used in non-interactive mode):
#   SENTRY_DSN          — Pre-configured DSN
#   SENTRY_ORG          — Organization slug
#   SENTRY_PROJECT      — Project slug
#   SENTRY_AUTH_TOKEN    — Auth token for sentry-cli

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

NONINTERACTIVE=false
FRAMEWORK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NONINTERACTIVE=true; shift ;;
    --framework) FRAMEWORK="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--non-interactive] [--framework <name>]"
      echo "Frameworks: nodejs, react, nextjs, vue, python, django, flask, fastapi, go, ruby, rails"
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Framework Detection ---

detect_framework() {
  if [[ -n "$FRAMEWORK" ]]; then
    echo "$FRAMEWORK"
    return
  fi

  # Next.js
  if [[ -f "next.config.js" || -f "next.config.mjs" || -f "next.config.ts" ]]; then
    echo "nextjs"; return
  fi

  # Package.json-based detection
  if [[ -f "package.json" ]]; then
    if grep -q '"react"' package.json 2>/dev/null; then
      if grep -q '"vue"' package.json 2>/dev/null; then
        echo "nodejs"  # ambiguous, default to node
      else
        echo "react"
      fi
      return
    fi
    if grep -q '"vue"' package.json 2>/dev/null; then
      echo "vue"; return
    fi
    echo "nodejs"; return
  fi

  # Python
  if [[ -f "requirements.txt" || -f "pyproject.toml" || -f "Pipfile" || -f "setup.py" ]]; then
    if [[ -f "manage.py" ]] || grep -rq "django" requirements.txt pyproject.toml 2>/dev/null; then
      echo "django"; return
    fi
    if grep -rq "flask" requirements.txt pyproject.toml 2>/dev/null; then
      echo "flask"; return
    fi
    if grep -rq "fastapi" requirements.txt pyproject.toml 2>/dev/null; then
      echo "fastapi"; return
    fi
    echo "python"; return
  fi

  # Go
  if [[ -f "go.mod" ]]; then
    echo "go"; return
  fi

  # Ruby / Rails
  if [[ -f "Gemfile" ]]; then
    if grep -q "rails" Gemfile 2>/dev/null; then
      echo "rails"; return
    fi
    echo "ruby"; return
  fi

  echo "unknown"
}

prompt_dsn() {
  if [[ -n "${SENTRY_DSN:-}" ]]; then
    echo "$SENTRY_DSN"
    return
  fi
  if [[ "$NONINTERACTIVE" == "true" ]]; then
    echo "https://YOUR_KEY@YOUR_ORG.ingest.sentry.io/YOUR_PROJECT_ID"
    return
  fi
  read -rp "Enter your Sentry DSN (or press Enter for placeholder): " dsn
  echo "${dsn:-https://YOUR_KEY@YOUR_ORG.ingest.sentry.io/YOUR_PROJECT_ID}"
}

# --- Setup .env ---

setup_env() {
  local dsn="$1"
  local env_file=".env"

  if [[ -f "$env_file" ]]; then
    if grep -q "SENTRY_DSN" "$env_file"; then
      warn ".env already contains SENTRY_DSN — skipping"
      return
    fi
  fi

  cat >> "$env_file" <<EOF

# Sentry Configuration
SENTRY_DSN=${dsn}
SENTRY_ENVIRONMENT=development
SENTRY_RELEASE=
# For CI/CD source map uploads:
# SENTRY_ORG=${SENTRY_ORG:-your-org}
# SENTRY_PROJECT=${SENTRY_PROJECT:-your-project}
# SENTRY_AUTH_TOKEN=
EOF

  ok "Added Sentry vars to $env_file"

  # Add .env to .gitignore if not already there
  if [[ -f ".gitignore" ]]; then
    if ! grep -q "^\.env$" .gitignore 2>/dev/null; then
      echo ".env" >> .gitignore
      ok "Added .env to .gitignore"
    fi
  fi
}

# --- Install Functions ---

install_nodejs() {
  local dsn="$1"
  info "Installing @sentry/node..."
  npm install @sentry/node @sentry/profiling-node --save

  if [[ ! -f "src/instrument.ts" && ! -f "src/instrument.js" ]]; then
    local ext="ts"
    [[ ! -f "tsconfig.json" ]] && ext="js"

    mkdir -p src
    cat > "src/instrument.${ext}" <<EOF
import * as Sentry from "@sentry/node";
import { nodeProfilingIntegration } from "@sentry/profiling-node";

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: process.env.NODE_ENV || "development",
  release: process.env.SENTRY_RELEASE,
  tracesSampleRate: process.env.NODE_ENV === "production" ? 0.2 : 1.0,
  profilesSampleRate: 0.1,
  integrations: [nodeProfilingIntegration()],
  beforeSend(event, hint) {
    // Filter non-actionable errors here
    return event;
  },
});
EOF
    ok "Created src/instrument.${ext}"
    info "Import this file at the TOP of your entry point: import './instrument';"
  else
    warn "src/instrument.{ts,js} already exists — skipping"
  fi
}

install_react() {
  local dsn="$1"
  info "Installing @sentry/react..."
  npm install @sentry/react --save

  if [[ ! -f "src/sentry.ts" && ! -f "src/sentry.js" ]]; then
    local ext="ts"
    [[ ! -f "tsconfig.json" ]] && ext="js"

    mkdir -p src
    cat > "src/sentry.${ext}" <<EOF
import * as Sentry from "@sentry/react";

Sentry.init({
  dsn: process.env.REACT_APP_SENTRY_DSN || process.env.VITE_SENTRY_DSN,
  environment: process.env.NODE_ENV || "development",
  release: process.env.REACT_APP_SENTRY_RELEASE || process.env.VITE_SENTRY_RELEASE,
  tracesSampleRate: 0.2,
  replaysSessionSampleRate: 0.1,
  replaysOnErrorSampleRate: 1.0,
  integrations: [
    Sentry.browserTracingIntegration(),
    Sentry.replayIntegration({ maskAllText: true, blockAllMedia: true }),
  ],
});

export const SentryErrorBoundary = Sentry.ErrorBoundary;
EOF
    ok "Created src/sentry.${ext}"
    info "Import this file at the TOP of your index.tsx: import './sentry';"
  fi
}

install_nextjs() {
  local dsn="$1"
  info "Installing @sentry/nextjs..."
  npx @sentry/wizard@latest -i nextjs --uninstall false 2>/dev/null || {
    warn "Sentry wizard failed — installing manually"
    npm install @sentry/nextjs --save

    cat > "sentry.client.config.ts" <<EOF
import * as Sentry from "@sentry/nextjs";

Sentry.init({
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN,
  environment: process.env.NODE_ENV,
  tracesSampleRate: 0.2,
  replaysSessionSampleRate: 0.1,
  replaysOnErrorSampleRate: 1.0,
  integrations: [
    Sentry.replayIntegration({ maskAllText: true, blockAllMedia: true }),
  ],
});
EOF

    cat > "sentry.server.config.ts" <<EOF
import * as Sentry from "@sentry/nextjs";

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: process.env.NODE_ENV,
  tracesSampleRate: 0.2,
  profilesSampleRate: 0.1,
});
EOF

    cat > "sentry.edge.config.ts" <<EOF
import * as Sentry from "@sentry/nextjs";

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: process.env.NODE_ENV,
  tracesSampleRate: 0.2,
});
EOF
    ok "Created sentry.{client,server,edge}.config.ts"
  }
}

install_vue() {
  local dsn="$1"
  info "Installing @sentry/vue..."
  npm install @sentry/vue --save
  ok "Installed @sentry/vue"
  info "Add Sentry.init() in your main.ts — see SKILL.md references for config template."
}

install_python() {
  local dsn="$1"
  local framework="${2:-generic}"
  info "Installing sentry-sdk..."

  if [[ -f "Pipfile" ]]; then
    pipenv install sentry-sdk
  elif [[ -f "pyproject.toml" ]]; then
    pip install sentry-sdk
  else
    pip install sentry-sdk
  fi

  local integrations=""
  case "$framework" in
    django)  integrations='    integrations=[DjangoIntegration()],' ;;
    flask)   integrations='    integrations=[FlaskIntegration()],' ;;
    fastapi) integrations='    integrations=[FastApiIntegration()],' ;;
  esac

  if [[ ! -f "sentry_config.py" ]]; then
    cat > "sentry_config.py" <<EOF
import os
import sentry_sdk

sentry_sdk.init(
    dsn=os.environ.get("SENTRY_DSN"),
    environment=os.environ.get("SENTRY_ENVIRONMENT", "development"),
    release=os.environ.get("SENTRY_RELEASE"),
    traces_sample_rate=0.2,
    profiles_sample_rate=0.1,
    send_default_pii=False,
${integrations}
)
EOF
    ok "Created sentry_config.py"
    info "Import sentry_config at the top of your application entry point."
  fi
}

install_go() {
  local dsn="$1"
  info "Installing sentry-go..."
  go get github.com/getsentry/sentry-go
  ok "Installed sentry-go"
  info "See SKILL.md for Go initialization code. Add sentry.Init() in main()."
}

install_rails() {
  local dsn="$1"
  info "Installing sentry-ruby and sentry-rails..."
  bundle add sentry-ruby sentry-rails 2>/dev/null || {
    warn "bundle add failed — add 'gem \"sentry-ruby\"' and 'gem \"sentry-rails\"' to Gemfile manually"
  }

  mkdir -p config/initializers
  if [[ ! -f "config/initializers/sentry.rb" ]]; then
    cat > "config/initializers/sentry.rb" <<EOF
Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = Rails.env
  config.release = ENV["SENTRY_RELEASE"]
  config.traces_sample_rate = 0.2
  config.profiles_sample_rate = 0.1
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
end
EOF
    ok "Created config/initializers/sentry.rb"
  fi
}

# --- Main ---

main() {
  info "Detecting project framework..."
  local fw
  fw=$(detect_framework)
  ok "Detected: ${fw}"

  local dsn
  dsn=$(prompt_dsn)

  case "$fw" in
    nodejs)          install_nodejs "$dsn" ;;
    react)           install_react "$dsn" ;;
    nextjs)          install_nextjs "$dsn" ;;
    vue)             install_vue "$dsn" ;;
    python)          install_python "$dsn" "generic" ;;
    django)          install_python "$dsn" "django" ;;
    flask)           install_python "$dsn" "flask" ;;
    fastapi)         install_python "$dsn" "fastapi" ;;
    go)              install_go "$dsn" ;;
    ruby)            warn "Generic Ruby — install sentry-ruby gem manually"; exit 0 ;;
    rails)           install_rails "$dsn" ;;
    *)
      err "Could not detect framework. Use --framework flag."
      err "Supported: nodejs, react, nextjs, vue, python, django, flask, fastapi, go, ruby, rails"
      exit 1
      ;;
  esac

  setup_env "$dsn"

  echo ""
  ok "Sentry setup complete!"
  info "Next steps:"
  info "  1. Replace the DSN placeholder in .env with your real DSN"
  info "  2. Set SENTRY_RELEASE to your version/git SHA in CI"
  info "  3. For JS/TS: set up source map uploads (see upload-sourcemaps.sh)"
  info "  4. Test with: Sentry.captureMessage('Hello from Sentry!')"
}

main "$@"
