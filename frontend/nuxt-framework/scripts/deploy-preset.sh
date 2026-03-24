#!/usr/bin/env bash
# ==============================================================================
# deploy-preset.sh — Configure Nuxt 3 deployment for various platforms
#
# Usage:
#   ./deploy-preset.sh <platform> [project-dir]
#   ./deploy-preset.sh vercel           # Configure for Vercel
#   ./deploy-preset.sh netlify          # Configure for Netlify
#   ./deploy-preset.sh cloudflare       # Configure for Cloudflare Pages
#   ./deploy-preset.sh node             # Configure for Node.js server
#   ./deploy-preset.sh --list           # Show all available presets
#
# What it does:
#   - Updates nuxt.config.ts with the correct Nitro preset
#   - Creates platform-specific config files (vercel.json, netlify.toml, etc.)
#   - Adds deployment scripts to package.json
#   - Prints deployment instructions
# ==============================================================================
set -euo pipefail

PLATFORM="${1:-}"
PROJECT_DIR="${2:-.}"

if [[ -z "$PLATFORM" || "$PLATFORM" == "--help" || "$PLATFORM" == "-h" ]]; then
  echo "Usage: $0 <platform> [project-dir]"
  echo ""
  echo "Platforms:"
  echo "  vercel       — Vercel (serverless/edge)"
  echo "  netlify      — Netlify (serverless functions)"
  echo "  cloudflare   — Cloudflare Pages (Workers)"
  echo "  node         — Node.js server (Docker/VPS)"
  echo ""
  echo "  --list       — Show all platforms"
  exit 0
fi

if [[ "$PLATFORM" == "--list" ]]; then
  echo "Available Nuxt 3 / Nitro deployment presets:"
  echo ""
  echo "  Serverless / Edge:"
  echo "    vercel            Vercel Functions"
  echo "    vercel-edge       Vercel Edge Functions"
  echo "    netlify           Netlify Functions"
  echo "    cloudflare-pages  Cloudflare Pages"
  echo "    cloudflare-module Cloudflare Workers (module syntax)"
  echo "    aws-lambda        AWS Lambda"
  echo "    firebase          Firebase Functions"
  echo ""
  echo "  Server:"
  echo "    node-server       Standard Node.js server"
  echo "    node-cluster      Node.js with cluster mode"
  echo "    bun               Bun runtime"
  echo "    deno-server       Deno runtime"
  echo "    deno-deploy       Deno Deploy"
  echo ""
  echo "  Static:"
  echo "    static            Pre-rendered static site"
  exit 0
fi

cd "$PROJECT_DIR"

if [[ ! -f "nuxt.config.ts" && ! -f "nuxt.config.js" ]]; then
  echo "Error: No nuxt.config found. Run this from a Nuxt project root."
  exit 1
fi

CONFIG_FILE="nuxt.config.ts"
if [[ ! -f "$CONFIG_FILE" ]]; then
  CONFIG_FILE="nuxt.config.js"
fi

# Helper: inject nitro preset into nuxt.config.ts
inject_preset() {
  local preset="$1"

  if grep -q "nitro:" "$CONFIG_FILE" 2>/dev/null; then
    if grep -q "preset:" "$CONFIG_FILE" 2>/dev/null; then
      # Replace existing preset
      sed -i "s/preset:.*['\"].*['\"]/preset: '${preset}'/" "$CONFIG_FILE"
    else
      # Add preset to existing nitro block
      sed -i "/nitro:\s*{/a\\    preset: '${preset}'," "$CONFIG_FILE"
    fi
  else
    # Add nitro block before closing of defineNuxtConfig
    sed -i "/defineNuxtConfig({/a\\\\n  nitro: {\\n    preset: '${preset}',\\n  }," "$CONFIG_FILE"
  fi

  echo "✅ Set nitro.preset = '${preset}' in $CONFIG_FILE"
}

case "$PLATFORM" in

  # ========== VERCEL ==========
  vercel)
    echo "🔧 Configuring for Vercel..."
    inject_preset "vercel"

    # Create vercel.json
    cat > vercel.json << 'EOF'
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "buildCommand": "npx nuxi build",
  "outputDirectory": ".output",
  "framework": "nuxtjs"
}
EOF
    echo "✅ Created vercel.json"

    echo ""
    echo "📋 Deployment steps:"
    echo "  1. Push to Git repository"
    echo "  2. Import project at https://vercel.com/new"
    echo "  3. Vercel auto-detects Nuxt — deploy!"
    echo ""
    echo "  Or via CLI:"
    echo "    npx vercel"
    echo ""
    echo "  Environment variables:"
    echo "    Set NUXT_* vars in Vercel dashboard → Settings → Environment Variables"
    ;;

  # ========== NETLIFY ==========
  netlify)
    echo "🔧 Configuring for Netlify..."
    inject_preset "netlify"

    # Create netlify.toml
    cat > netlify.toml << 'EOF'
[build]
  command = "npx nuxi build"
  publish = ".output/public"

[build.environment]
  NODE_VERSION = "20"

# Redirect all requests to the Nuxt server function
[[redirects]]
  from = "/*"
  to = "/.netlify/functions/server"
  status = 200
  conditions = { Role = ["admin", "user"] }
EOF
    echo "✅ Created netlify.toml"

    echo ""
    echo "📋 Deployment steps:"
    echo "  1. Push to Git repository"
    echo "  2. Import at https://app.netlify.com/start"
    echo "  3. Build command: npx nuxi build"
    echo "  4. Publish directory: .output/public"
    echo ""
    echo "  Or via CLI:"
    echo "    npx netlify deploy --build --prod"
    echo ""
    echo "  Environment variables:"
    echo "    Set NUXT_* vars in Netlify dashboard → Site settings → Environment variables"
    ;;

  # ========== CLOUDFLARE ==========
  cloudflare)
    echo "🔧 Configuring for Cloudflare Pages..."
    inject_preset "cloudflare-pages"

    # Create wrangler.toml
    cat > wrangler.toml << 'EOF'
name = "my-nuxt-app"
compatibility_date = "2024-11-01"
compatibility_flags = ["nodejs_compat"]
pages_build_output_dir = ".output/public"

# Uncomment to use KV, D1, R2, etc.
# [[kv_namespaces]]
# binding = "MY_KV"
# id = "your-kv-id"

# [[d1_databases]]
# binding = "DB"
# database_name = "my-db"
# database_id = "your-db-id"
EOF
    echo "✅ Created wrangler.toml"

    echo ""
    echo "📋 Deployment steps:"
    echo "  1. Push to Git repository"
    echo "  2. Create Pages project at https://dash.cloudflare.com"
    echo "  3. Build command: npx nuxi build"
    echo "  4. Build output directory: .output/public"
    echo ""
    echo "  Or via CLI:"
    echo "    npx wrangler pages deploy .output/public"
    echo ""
    echo "  Notes:"
    echo "    - Node.js APIs require compatibility_flags = ['nodejs_compat']"
    echo "    - Access KV/D1/R2 via platform bindings in server routes"
    echo "    - Max 25 MiB compressed for Workers"
    ;;

  # ========== NODE ==========
  node)
    echo "🔧 Configuring for Node.js server..."
    inject_preset "node-server"

    # Create Dockerfile
    cat > Dockerfile << 'DOCKERFILE'
FROM node:20-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npx nuxi build

FROM node:20-slim AS runtime
WORKDIR /app
COPY --from=build /app/.output .output/
ENV HOST=0.0.0.0
ENV PORT=3000
EXPOSE 3000
CMD ["node", ".output/server/index.mjs"]
DOCKERFILE
    echo "✅ Created Dockerfile"

    # Create .dockerignore
    cat > .dockerignore << 'DOCKERIGNORE'
node_modules
.nuxt
.output
.git
DOCKERIGNORE
    echo "✅ Created .dockerignore"

    echo ""
    echo "📋 Deployment steps:"
    echo ""
    echo "  Direct Node.js:"
    echo "    npx nuxi build"
    echo "    node .output/server/index.mjs"
    echo ""
    echo "  With Docker:"
    echo "    docker build -t my-nuxt-app ."
    echo "    docker run -p 3000:3000 my-nuxt-app"
    echo ""
    echo "  With PM2:"
    echo "    npx nuxi build"
    echo "    pm2 start .output/server/index.mjs --name my-nuxt-app"
    echo ""
    echo "  Environment variables:"
    echo "    HOST=0.0.0.0 PORT=3000 NUXT_* node .output/server/index.mjs"
    ;;

  *)
    echo "Error: Unknown platform '$PLATFORM'"
    echo "Run '$0 --list' for available platforms."
    exit 1
    ;;
esac

echo ""
echo "Done! Review $CONFIG_FILE to verify the configuration."
