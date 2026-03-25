#!/usr/bin/env bash
# =============================================================================
# setup-vercel.sh — Vercel Project Setup Script
# =============================================================================
# Usage:
#   ./setup-vercel.sh                     # Auto-detect framework, create config
#   ./setup-vercel.sh --framework nextjs  # Force framework type
#   ./setup-vercel.sh --monorepo          # Configure for monorepo
#   ./setup-vercel.sh --dry-run           # Preview changes without writing files
#
# What it does:
#   1. Detects framework type from package.json / config files
#   2. Creates vercel.json with optimal settings for the framework
#   3. Generates .env.example template
#   4. Configures monorepo settings if --monorepo is passed
#   5. Creates .vercelignore if missing
#
# Prerequisites:
#   - Run from the project root (or monorepo app directory)
#   - Node.js and npm/pnpm/yarn installed
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
FRAMEWORK=""
MONOREPO=false
DRY_RUN=false
ROOT_DIR="."

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --framework <name>   Force framework (nextjs|sveltekit|nuxt|astro|remix|vite)"
  echo "  --monorepo           Configure monorepo settings"
  echo "  --root-dir <path>    Set root directory for monorepo app (default: .)"
  echo "  --dry-run            Preview changes without writing files"
  echo "  -h, --help           Show this help message"
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --framework)  FRAMEWORK="$2"; shift 2 ;;
    --monorepo)   MONOREPO=true; shift ;;
    --root-dir)   ROOT_DIR="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    usage ;;
    *)            log_error "Unknown option: $1"; usage ;;
  esac
done

# ---- Framework Detection ----
detect_framework() {
  if [[ -n "$FRAMEWORK" ]]; then
    log_info "Framework forced to: $FRAMEWORK"
    return
  fi

  log_info "Detecting framework..."

  if [[ ! -f "package.json" ]]; then
    log_error "No package.json found in $(pwd). Run from project root."
    exit 1
  fi

  local deps
  deps=$(cat package.json)

  # Check for frameworks in order of specificity
  if echo "$deps" | grep -q '"next"'; then
    FRAMEWORK="nextjs"
  elif echo "$deps" | grep -q '"@sveltejs/kit"'; then
    FRAMEWORK="sveltekit"
  elif echo "$deps" | grep -q '"nuxt"'; then
    FRAMEWORK="nuxt"
  elif echo "$deps" | grep -q '"astro"'; then
    FRAMEWORK="astro"
  elif echo "$deps" | grep -q '"@remix-run/dev"'; then
    FRAMEWORK="remix"
  elif echo "$deps" | grep -q '"vite"'; then
    FRAMEWORK="vite"
  elif [[ -f "index.html" ]]; then
    FRAMEWORK="static"
  else
    log_warn "Could not detect framework. Defaulting to static."
    FRAMEWORK="static"
  fi

  log_ok "Detected framework: $FRAMEWORK"
}

# ---- Package Manager Detection ----
detect_package_manager() {
  if [[ -f "pnpm-lock.yaml" ]]; then
    echo "pnpm"
  elif [[ -f "yarn.lock" ]]; then
    echo "yarn"
  elif [[ -f "bun.lockb" ]] || [[ -f "bun.lock" ]]; then
    echo "bun"
  else
    echo "npm"
  fi
}

# ---- Generate vercel.json ----
generate_vercel_json() {
  local pm
  pm=$(detect_package_manager)
  local install_cmd
  case $pm in
    pnpm) install_cmd="pnpm install --frozen-lockfile" ;;
    yarn) install_cmd="yarn install --frozen-lockfile" ;;
    bun)  install_cmd="bun install --frozen-lockfile" ;;
    *)    install_cmd="npm ci" ;;
  esac

  local config
  case $FRAMEWORK in
    nextjs)
      config=$(cat <<EOF
{
  "\$schema": "https://openapi.vercel.sh/vercel.json",
  "framework": "nextjs",
  "installCommand": "${install_cmd}",
  "regions": ["iad1"],
  "functions": {
    "app/api/**/*.ts": {
      "memory": 1024,
      "maxDuration": 30
    }
  },
  "headers": [
    {
      "source": "/(.*)",
      "headers": [
        { "key": "X-Content-Type-Options", "value": "nosniff" },
        { "key": "X-Frame-Options", "value": "DENY" },
        { "key": "Referrer-Policy", "value": "strict-origin-when-cross-origin" }
      ]
    }
  ]
}
EOF
      )
      ;;
    sveltekit)
      config=$(cat <<EOF
{
  "\$schema": "https://openapi.vercel.sh/vercel.json",
  "framework": "svelte",
  "installCommand": "${install_cmd}",
  "outputDirectory": "build",
  "regions": ["iad1"]
}
EOF
      )
      ;;
    nuxt)
      config=$(cat <<EOF
{
  "\$schema": "https://openapi.vercel.sh/vercel.json",
  "framework": "nuxt",
  "installCommand": "${install_cmd}",
  "regions": ["iad1"]
}
EOF
      )
      ;;
    astro)
      config=$(cat <<EOF
{
  "\$schema": "https://openapi.vercel.sh/vercel.json",
  "framework": "astro",
  "installCommand": "${install_cmd}",
  "outputDirectory": "dist",
  "regions": ["iad1"]
}
EOF
      )
      ;;
    remix)
      config=$(cat <<EOF
{
  "\$schema": "https://openapi.vercel.sh/vercel.json",
  "framework": "remix",
  "installCommand": "${install_cmd}",
  "regions": ["iad1"]
}
EOF
      )
      ;;
    vite)
      config=$(cat <<EOF
{
  "\$schema": "https://openapi.vercel.sh/vercel.json",
  "installCommand": "${install_cmd}",
  "buildCommand": "${pm} run build",
  "outputDirectory": "dist",
  "rewrites": [
    { "source": "/(.*)", "destination": "/index.html" }
  ],
  "headers": [
    {
      "source": "/assets/(.*)",
      "headers": [
        { "key": "Cache-Control", "value": "public, max-age=31536000, immutable" }
      ]
    }
  ]
}
EOF
      )
      ;;
    static)
      config=$(cat <<EOF
{
  "\$schema": "https://openapi.vercel.sh/vercel.json",
  "outputDirectory": "public",
  "cleanUrls": true,
  "trailingSlash": false,
  "headers": [
    {
      "source": "/(.*)",
      "headers": [
        { "key": "X-Content-Type-Options", "value": "nosniff" }
      ]
    }
  ]
}
EOF
      )
      ;;
  esac

  if $MONOREPO && [[ "$ROOT_DIR" != "." ]]; then
    config=$(echo "$config" | python3 -c "
import sys, json
c = json.load(sys.stdin)
c['rootDirectory'] = '${ROOT_DIR}'
print(json.dumps(c, indent=2))
" 2>/dev/null || echo "$config")
  fi

  if $DRY_RUN; then
    log_info "[DRY RUN] Would create vercel.json:"
    echo "$config"
  else
    if [[ -f "vercel.json" ]]; then
      log_warn "vercel.json already exists. Backing up to vercel.json.bak"
      cp vercel.json vercel.json.bak
    fi
    echo "$config" > vercel.json
    log_ok "Created vercel.json"
  fi
}

# ---- Generate .env.example ----
generate_env_template() {
  local env_content
  env_content="# =============================================================================
# Environment Variables Template
# Copy to .env.local and fill in values: cp .env.example .env.local
# =============================================================================

# ---- Vercel System (auto-populated, do not set manually) ----
# VERCEL_ENV=development|preview|production
# VERCEL_URL=<deployment-url>
# VERCEL_GIT_COMMIT_SHA=<sha>

"

  case $FRAMEWORK in
    nextjs)
      env_content+="# ---- Public (exposed to browser) ----
NEXT_PUBLIC_APP_URL=http://localhost:3000
NEXT_PUBLIC_API_URL=http://localhost:3000/api
# NEXT_PUBLIC_ANALYTICS_ID=

# ---- Server Only ----
DATABASE_URL=postgresql://user:password@localhost:5432/mydb
# UPSTASH_REDIS_REST_URL=
# UPSTASH_REDIS_REST_TOKEN=
# BLOB_READ_WRITE_TOKEN=

# ---- Auth ----
# AUTH_SECRET=  # Generate: openssl rand -base64 32
# GITHUB_CLIENT_ID=
# GITHUB_CLIENT_SECRET=

# ---- Cron Security ----
# CRON_SECRET=  # Generate: openssl rand -hex 32
"
      ;;
    sveltekit)
      env_content+="# ---- Public (exposed to browser) ----
PUBLIC_APP_URL=http://localhost:5173
# PUBLIC_API_URL=

# ---- Server Only ----
DATABASE_URL=postgresql://user:password@localhost:5432/mydb
# SECRET_KEY=  # Generate: openssl rand -base64 32
"
      ;;
    nuxt)
      env_content+="# ---- Public Runtime Config ----
NUXT_PUBLIC_APP_URL=http://localhost:3000
# NUXT_PUBLIC_API_BASE=

# ---- Server Only ----
DATABASE_URL=postgresql://user:password@localhost:5432/mydb
# NUXT_SECRET=  # Generate: openssl rand -base64 32
"
      ;;
    vite)
      env_content+="# ---- Public (exposed to browser, must use VITE_ prefix) ----
VITE_APP_URL=http://localhost:5173
VITE_API_URL=http://localhost:3000/api
# VITE_ANALYTICS_ID=
"
      ;;
    *)
      env_content+="# ---- App Configuration ----
APP_URL=http://localhost:3000
# API_URL=
# DATABASE_URL=
"
      ;;
  esac

  if $DRY_RUN; then
    log_info "[DRY RUN] Would create .env.example:"
    echo "$env_content"
  else
    if [[ -f ".env.example" ]]; then
      log_warn ".env.example already exists. Skipping."
    else
      echo "$env_content" > .env.example
      log_ok "Created .env.example"
    fi
  fi
}

# ---- Generate .vercelignore ----
generate_vercelignore() {
  if [[ -f ".vercelignore" ]]; then
    log_info ".vercelignore already exists. Skipping."
    return
  fi

  local content="# Files and directories to exclude from Vercel deployments
.git
.github
.vscode
.idea
*.md
!README.md
docs/
tests/
__tests__/
*.test.*
*.spec.*
.env
.env.local
.env.*.local
coverage/
.nyc_output/
*.psd
*.sketch
*.fig
"

  if $DRY_RUN; then
    log_info "[DRY RUN] Would create .vercelignore"
  else
    echo "$content" > .vercelignore
    log_ok "Created .vercelignore"
  fi
}

# ---- Monorepo Setup ----
setup_monorepo() {
  if ! $MONOREPO; then return; fi

  log_info "Configuring monorepo settings..."

  # Check for turbo.json
  if [[ ! -f "turbo.json" ]] && [[ -f "package.json" ]]; then
    local has_turbo
    has_turbo=$(grep -c '"turbo"' package.json 2>/dev/null || echo "0")
    if [[ "$has_turbo" -gt 0 ]]; then
      if $DRY_RUN; then
        log_info "[DRY RUN] Would create turbo.json"
      else
        cat > turbo.json <<'EOF'
{
  "$schema": "https://turbo.build/schema.json",
  "globalDependencies": ["tsconfig.json"],
  "globalEnv": ["VERCEL_ENV", "CI", "NODE_ENV"],
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": [".next/**", "!.next/cache/**", "dist/**", "build/**"],
      "env": ["DATABASE_URL", "NEXT_PUBLIC_*"]
    },
    "dev": {
      "cache": false,
      "persistent": true
    },
    "lint": {
      "dependsOn": ["^build"],
      "outputs": []
    },
    "test": {
      "dependsOn": ["^build"],
      "outputs": ["coverage/**"]
    }
  }
}
EOF
        log_ok "Created turbo.json"
      fi
    fi
  fi

  log_ok "Monorepo configuration complete"
  log_info "Remember to:"
  echo "  1. Create separate Vercel projects per app"
  echo "  2. Set Root Directory in each project's settings"
  echo "  3. Add 'npx turbo-ignore' as Ignored Build Step"
}

# ---- Main ----
main() {
  echo "========================================"
  echo "  Vercel Project Setup"
  echo "========================================"
  echo ""

  detect_framework
  generate_vercel_json
  generate_env_template
  generate_vercelignore
  setup_monorepo

  echo ""
  echo "========================================"
  log_ok "Setup complete!"
  echo "========================================"
  echo ""
  echo "Next steps:"
  echo "  1. Install Vercel CLI:    npm i -g vercel"
  echo "  2. Link your project:    vercel link"
  echo "  3. Pull env vars:        vercel env pull .env.local"
  echo "  4. Start dev server:     vercel dev"
  echo "  5. Deploy preview:       vercel deploy"
  echo "  6. Deploy production:    vercel deploy --prod"
}

main
