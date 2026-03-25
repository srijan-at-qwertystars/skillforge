#!/usr/bin/env bash
# =============================================================================
# setup-netlify.sh — Initialize a project for Netlify deployment
#
# Usage:
#   ./setup-netlify.sh [--framework <name>] [--functions-dir <path>]
#
# Options:
#   --framework <name>   Specify framework (react, next, gatsby, hugo, astro,
#                        sveltekit, vue, nuxt, eleventy, static). Auto-detected
#                        if omitted.
#   --functions-dir <p>  Functions directory (default: netlify/functions)
#
# What it does:
#   1. Detects the project framework from package.json / config files
#   2. Creates netlify.toml with optimal settings for the framework
#   3. Sets up functions directory structure
#   4. Creates _redirects boilerplate for SPAs
#   5. Generates .env.example with common Netlify env vars
#   6. Creates .netlify/ gitignore entry
#
# Examples:
#   ./setup-netlify.sh                          # auto-detect everything
#   ./setup-netlify.sh --framework next         # force Next.js config
#   ./setup-netlify.sh --functions-dir functions # custom functions path
# =============================================================================
set -euo pipefail

# Defaults
FRAMEWORK=""
FUNCTIONS_DIR="netlify/functions"
EDGE_FUNCTIONS_DIR="netlify/edge-functions"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --framework) FRAMEWORK="$2"; shift 2 ;;
    --functions-dir) FUNCTIONS_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^# =====/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Framework Detection ---

detect_framework() {
  if [[ -n "$FRAMEWORK" ]]; then
    echo "$FRAMEWORK"
    return
  fi

  if [[ -f "package.json" ]]; then
    local deps
    deps=$(cat package.json)

    if echo "$deps" | grep -q '"next"'; then echo "next"; return; fi
    if echo "$deps" | grep -q '"gatsby"'; then echo "gatsby"; return; fi
    if echo "$deps" | grep -q '"astro"'; then echo "astro"; return; fi
    if echo "$deps" | grep -q '"@sveltejs/kit"'; then echo "sveltekit"; return; fi
    if echo "$deps" | grep -q '"nuxt"'; then echo "nuxt"; return; fi
    if echo "$deps" | grep -q '"@11ty/eleventy"'; then echo "eleventy"; return; fi
    if echo "$deps" | grep -q '"vue"'; then echo "vue"; return; fi
    if echo "$deps" | grep -q '"react-scripts"'; then echo "react-cra"; return; fi
    if echo "$deps" | grep -q '"react"'; then echo "react"; return; fi
  fi

  if [[ -f "hugo.toml" ]] || [[ -f "config.toml" && -d "content" ]]; then
    echo "hugo"; return
  fi

  if [[ -f "Gemfile" ]] && grep -q "jekyll" Gemfile 2>/dev/null; then
    echo "jekyll"; return
  fi

  echo "static"
}

FRAMEWORK=$(detect_framework)
echo "✓ Detected framework: $FRAMEWORK"

# --- Framework-Specific Settings ---

get_build_command() {
  case "$FRAMEWORK" in
    next)       echo "npm run build" ;;
    gatsby)     echo "gatsby build" ;;
    react|react-cra) echo "npm run build" ;;
    vue)        echo "npm run build" ;;
    astro)      echo "npm run build" ;;
    sveltekit)  echo "npm run build" ;;
    nuxt)       echo "npm run build" ;;
    hugo)       echo "hugo --minify" ;;
    eleventy)   echo "npx @11ty/eleventy" ;;
    jekyll)     echo "jekyll build" ;;
    static)     echo "echo 'No build step'" ;;
    *)          echo "npm run build" ;;
  esac
}

get_publish_dir() {
  case "$FRAMEWORK" in
    next)       echo ".next" ;;
    gatsby)     echo "public" ;;
    react|react-cra) echo "build" ;;
    vue)        echo "dist" ;;
    astro)      echo "dist" ;;
    sveltekit)  echo "build" ;;
    nuxt)       echo ".output/public" ;;
    hugo)       echo "public" ;;
    eleventy)   echo "_site" ;;
    jekyll)     echo "_site" ;;
    static)     echo "." ;;
    *)          echo "dist" ;;
  esac
}

get_dev_command() {
  case "$FRAMEWORK" in
    next)       echo "npm run dev" ;;
    gatsby)     echo "gatsby develop" ;;
    react|react-cra) echo "npm start" ;;
    vue)        echo "npm run dev" ;;
    astro)      echo "npm run dev" ;;
    sveltekit)  echo "npm run dev" ;;
    nuxt)       echo "npm run dev" ;;
    hugo)       echo "hugo server" ;;
    eleventy)   echo "npx @11ty/eleventy --serve" ;;
    jekyll)     echo "jekyll serve" ;;
    static)     echo "" ;;
    *)          echo "npm run dev" ;;
  esac
}

get_dev_port() {
  case "$FRAMEWORK" in
    next)       echo "3000" ;;
    gatsby)     echo "8000" ;;
    react|react-cra) echo "3000" ;;
    vue)        echo "5173" ;;
    astro)      echo "4321" ;;
    sveltekit)  echo "5173" ;;
    nuxt)       echo "3000" ;;
    hugo)       echo "1313" ;;
    eleventy)   echo "8080" ;;
    jekyll)     echo "4000" ;;
    static)     echo "8888" ;;
    *)          echo "3000" ;;
  esac
}

get_plugins() {
  case "$FRAMEWORK" in
    next)       echo '[[plugins]]\n  package = "@netlify/plugin-nextjs"' ;;
    gatsby)     echo '[[plugins]]\n  package = "@netlify/plugin-gatsby"' ;;
    sveltekit)  echo "# SvelteKit: use @sveltejs/adapter-netlify in svelte.config.js" ;;
    *)          echo "" ;;
  esac
}

BUILD_CMD=$(get_build_command)
PUBLISH_DIR=$(get_publish_dir)
DEV_CMD=$(get_dev_command)
DEV_PORT=$(get_dev_port)
PLUGINS=$(get_plugins)

# --- Create netlify.toml ---

if [[ -f "netlify.toml" ]]; then
  echo "⚠ netlify.toml already exists — backing up to netlify.toml.bak"
  cp netlify.toml netlify.toml.bak
fi

cat > netlify.toml << TOML
# Netlify configuration — generated by setup-netlify.sh
# Docs: https://docs.netlify.com/configure-builds/file-based-configuration/

[build]
  command = "${BUILD_CMD}"
  publish = "${PUBLISH_DIR}"
  functions = "${FUNCTIONS_DIR}"
  edge_functions = "${EDGE_FUNCTIONS_DIR}"

[build.environment]
  NODE_VERSION = "20"

TOML

# Add dev block if framework has a dev command
if [[ -n "$DEV_CMD" ]]; then
  cat >> netlify.toml << TOML
[dev]
  command = "${DEV_CMD}"
  targetPort = ${DEV_PORT}

TOML
fi

# Add functions config
cat >> netlify.toml << 'TOML'
[functions]
  node_bundler = "esbuild"

# --- Deploy Contexts ---

[context.production]
  command = ""  # inherits from [build]

[context.deploy-preview]
  command = ""  # inherits from [build]
  [context.deploy-preview.environment]
    CONTEXT = "deploy-preview"

[context.branch-deploy]
  command = ""  # inherits from [build]
  [context.branch-deploy.environment]
    CONTEXT = "branch-deploy"

# --- Redirects ---

# API proxy to serverless functions
[[redirects]]
  from = "/api/*"
  to = "/.netlify/functions/:splat"
  status = 200

TOML

# Add SPA fallback for SPA frameworks
case "$FRAMEWORK" in
  react|react-cra|vue)
    cat >> netlify.toml << 'TOML'
# SPA fallback — serve index.html for all routes
[[redirects]]
  from = "/*"
  to = "/index.html"
  status = 200

TOML
    ;;
esac

# Add headers
cat >> netlify.toml << 'TOML'
# --- Headers ---

[[headers]]
  for = "/*"
  [headers.values]
    X-Frame-Options = "DENY"
    X-Content-Type-Options = "nosniff"
    Referrer-Policy = "strict-origin-when-cross-origin"

[[headers]]
  for = "/assets/*"
  [headers.values]
    Cache-Control = "public, max-age=31536000, immutable"

# --- Build Processing ---

[build.processing.css]
  bundle = true
  minify = true

[build.processing.js]
  bundle = true
  minify = true

[build.processing.html]
  pretty_urls = true

[build.processing.images]
  compress = true
TOML

# Add plugins if any
if [[ -n "$PLUGINS" ]]; then
  echo "" >> netlify.toml
  echo -e "$PLUGINS" >> netlify.toml
fi

echo "✓ Created netlify.toml"

# --- Create Functions Directory ---

mkdir -p "$FUNCTIONS_DIR"
mkdir -p "$EDGE_FUNCTIONS_DIR"

# Create a hello world serverless function
cat > "$FUNCTIONS_DIR/hello.ts" << 'TS'
import type { Handler, HandlerEvent } from "@netlify/functions";

export const handler: Handler = async (event: HandlerEvent) => {
  const name = event.queryStringParameters?.name || "World";

  return {
    statusCode: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ message: `Hello, ${name}!` }),
  };
};
TS

echo "✓ Created ${FUNCTIONS_DIR}/ with hello.ts example"

# --- Create _redirects Boilerplate ---

REDIRECTS_DIR="${PUBLISH_DIR}"
if [[ "$PUBLISH_DIR" == "." ]]; then
  REDIRECTS_DIR="."
fi

mkdir -p "$REDIRECTS_DIR" 2>/dev/null || true
if [[ ! -f "${REDIRECTS_DIR}/_redirects" ]]; then
  cat > "${REDIRECTS_DIR}/_redirects" << 'REDIRECTS'
# Netlify _redirects file
# Docs: https://docs.netlify.com/routing/redirects/
# Note: netlify.toml [[redirects]] are processed BEFORE this file.
#
# Format: from  to  status
# /old-path  /new-path  301
# /api/*     /.netlify/functions/:splat  200
REDIRECTS
  echo "✓ Created ${REDIRECTS_DIR}/_redirects"
fi

# --- Create .env.example ---

if [[ ! -f ".env.example" ]]; then
  cat > .env.example << 'ENV'
# Netlify Environment Variables Template
# Copy to .env for local development: cp .env.example .env
# Set production values in Netlify UI: Site Settings > Environment variables

# App
# SITE_URL=https://your-site.netlify.app
# API_URL=https://api.example.com

# Auth / Secrets (NEVER commit actual values)
# API_KEY=
# DATABASE_URL=
# JWT_SECRET=

# Netlify-specific (auto-set in builds, set manually for local dev)
# CONTEXT=dev
# URL=http://localhost:8888

# Third-party integrations
# STRIPE_SECRET_KEY=
# STRIPE_WEBHOOK_SECRET=
# SLACK_WEBHOOK_URL=
# SENDGRID_API_KEY=
ENV
  echo "✓ Created .env.example"
fi

# --- Update .gitignore ---

touch .gitignore
ENTRIES=(".netlify" ".env" ".env.local")
for entry in "${ENTRIES[@]}"; do
  if ! grep -qxF "$entry" .gitignore 2>/dev/null; then
    echo "$entry" >> .gitignore
  fi
done
echo "✓ Updated .gitignore"

# --- Summary ---

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Netlify setup complete!                    ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Framework:  ${FRAMEWORK}"
echo "║  Build cmd:  ${BUILD_CMD}"
echo "║  Publish:    ${PUBLISH_DIR}"
echo "║  Functions:  ${FUNCTIONS_DIR}"
echo "╠══════════════════════════════════════════════╣"
echo "║  Next steps:                                 ║"
echo "║  1. npm install -g netlify-cli               ║"
echo "║  2. netlify login                            ║"
echo "║  3. netlify init   (or netlify link)         ║"
echo "║  4. netlify dev    (local development)       ║"
echo "║  5. netlify deploy --prod                    ║"
echo "╚══════════════════════════════════════════════╝"
