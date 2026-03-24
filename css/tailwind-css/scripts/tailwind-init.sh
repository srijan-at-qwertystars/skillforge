#!/usr/bin/env bash
# tailwind-init.sh — Initialize Tailwind CSS v4 in a project
#
# Usage:
#   ./tailwind-init.sh              # Auto-detect framework
#   ./tailwind-init.sh nextjs       # Force Next.js setup
#   ./tailwind-init.sh vite         # Force Vite setup
#   ./tailwind-init.sh remix        # Force Remix setup
#   ./tailwind-init.sh plain        # Plain/static site (CLI)
#
# Supports: Next.js, Vite (React/Vue/Svelte/SvelteKit), Remix, plain sites
# Requires: Node.js 18+, npm/pnpm/yarn

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; }

# --- Detect package manager ---
detect_pm() {
  if [ -f "pnpm-lock.yaml" ]; then echo "pnpm"
  elif [ -f "yarn.lock" ]; then echo "yarn"
  elif [ -f "bun.lockb" ]; then echo "bun"
  else echo "npm"
  fi
}

# --- Install dev dependency ---
install_dev() {
  local pm
  pm=$(detect_pm)
  info "Installing with $pm: $*"
  case $pm in
    pnpm) pnpm add -D "$@" ;;
    yarn) yarn add -D "$@" ;;
    bun)  bun add -d "$@" ;;
    *)    npm install -D "$@" ;;
  esac
}

# --- Detect framework ---
detect_framework() {
  if [ -n "${1:-}" ]; then
    echo "$1"
    return
  fi

  if [ -f "next.config.js" ] || [ -f "next.config.mjs" ] || [ -f "next.config.ts" ]; then
    echo "nextjs"
  elif [ -f "remix.config.js" ] || [ -f "remix.config.mjs" ] || grep -q '"@remix-run"' package.json 2>/dev/null; then
    echo "remix"
  elif [ -f "vite.config.ts" ] || [ -f "vite.config.js" ] || [ -f "vite.config.mjs" ]; then
    echo "vite"
  elif [ -f "svelte.config.js" ]; then
    echo "vite"
  elif [ -f "astro.config.mjs" ] || [ -f "astro.config.ts" ]; then
    echo "astro"
  else
    echo "plain"
  fi
}

# --- Check prerequisites ---
if ! command -v node &>/dev/null; then
  error "Node.js is required. Install from https://nodejs.org"
  exit 1
fi

if [ ! -f "package.json" ]; then
  warn "No package.json found. Initializing..."
  npm init -y > /dev/null 2>&1
  ok "Created package.json"
fi

FRAMEWORK=$(detect_framework "${1:-}")
info "Detected framework: ${FRAMEWORK}"

# --- Framework-specific setup ---
case $FRAMEWORK in
  nextjs)
    info "Setting up Tailwind v4 for Next.js (PostCSS)"
    install_dev tailwindcss @tailwindcss/postcss postcss

    # Create PostCSS config
    if [ ! -f "postcss.config.mjs" ]; then
      cat > postcss.config.mjs << 'EOF'
export default {
  plugins: {
    "@tailwindcss/postcss": {},
  },
};
EOF
      ok "Created postcss.config.mjs"
    else
      warn "postcss.config.mjs already exists — verify it includes @tailwindcss/postcss"
    fi

    # Find or create CSS entry file
    CSS_FILE=""
    for candidate in "src/app/globals.css" "app/globals.css" "styles/globals.css" "src/styles/globals.css"; do
      if [ -f "$candidate" ]; then
        CSS_FILE="$candidate"
        break
      fi
    done

    if [ -z "$CSS_FILE" ]; then
      CSS_FILE="src/app/globals.css"
      mkdir -p "$(dirname "$CSS_FILE")"
    fi

    if [ ! -f "$CSS_FILE" ] || ! grep -q '@import "tailwindcss"' "$CSS_FILE" 2>/dev/null; then
      cat > "$CSS_FILE" << 'EOF'
@import "tailwindcss";

@theme {
  --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif;
}
EOF
      ok "Created $CSS_FILE with Tailwind v4 import"
    else
      warn "$CSS_FILE already contains Tailwind import"
    fi
    ;;

  vite)
    info "Setting up Tailwind v4 for Vite"
    install_dev tailwindcss @tailwindcss/vite

    # Determine vite config file
    VITE_CONFIG=""
    for f in vite.config.ts vite.config.js vite.config.mjs; do
      if [ -f "$f" ]; then VITE_CONFIG="$f"; break; fi
    done

    if [ -n "$VITE_CONFIG" ]; then
      if ! grep -q "tailwindcss" "$VITE_CONFIG" 2>/dev/null; then
        warn "Add tailwindcss() to your Vite plugins in $VITE_CONFIG:"
        echo ""
        echo "  import tailwindcss from '@tailwindcss/vite'"
        echo "  // Add to plugins array: tailwindcss()"
        echo ""
      else
        ok "Tailwind already in $VITE_CONFIG"
      fi
    fi

    # Create CSS entry file
    CSS_FILE=""
    for candidate in "src/index.css" "src/app.css" "src/style.css" "src/styles.css"; do
      if [ -f "$candidate" ]; then
        CSS_FILE="$candidate"
        break
      fi
    done
    CSS_FILE="${CSS_FILE:-src/index.css}"
    mkdir -p "$(dirname "$CSS_FILE")"

    if [ ! -f "$CSS_FILE" ] || ! grep -q '@import "tailwindcss"' "$CSS_FILE" 2>/dev/null; then
      cat > "$CSS_FILE" << 'EOF'
@import "tailwindcss";

@theme {
  --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif;
}
EOF
      ok "Created $CSS_FILE with Tailwind v4 import"
    fi
    ;;

  remix)
    info "Setting up Tailwind v4 for Remix (PostCSS)"
    install_dev tailwindcss @tailwindcss/postcss postcss

    if [ ! -f "postcss.config.mjs" ]; then
      cat > postcss.config.mjs << 'EOF'
export default {
  plugins: {
    "@tailwindcss/postcss": {},
  },
};
EOF
      ok "Created postcss.config.mjs"
    fi

    CSS_FILE="app/tailwind.css"
    mkdir -p app
    if [ ! -f "$CSS_FILE" ]; then
      cat > "$CSS_FILE" << 'EOF'
@import "tailwindcss";

@theme {
  --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif;
}
EOF
      ok "Created $CSS_FILE"
      warn "Import this CSS in app/root.tsx: import './tailwind.css'"
    fi
    ;;

  astro)
    info "Setting up Tailwind for Astro"
    echo "Run: npx astro add tailwind"
    echo "Astro's integration handles everything automatically."
    exit 0
    ;;

  plain)
    info "Setting up Tailwind v4 with CLI (plain/static site)"
    install_dev @tailwindcss/cli

    CSS_FILE="src/input.css"
    mkdir -p src dist

    if [ ! -f "$CSS_FILE" ]; then
      cat > "$CSS_FILE" << 'EOF'
@import "tailwindcss";

@theme {
  --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif;
}
EOF
      ok "Created $CSS_FILE"
    fi

    # Create example HTML
    if [ ! -f "index.html" ]; then
      cat > index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Tailwind CSS</title>
  <link href="dist/output.css" rel="stylesheet" />
</head>
<body class="bg-gray-50 text-gray-900 min-h-screen flex items-center justify-center">
  <div class="text-center">
    <h1 class="text-4xl font-bold text-blue-600">Hello, Tailwind v4!</h1>
    <p class="mt-2 text-gray-600">Edit index.html and start building.</p>
  </div>
</body>
</html>
EOF
      ok "Created index.html"
    fi

    # Add scripts to package.json
    info "Add to package.json scripts:"
    echo '  "dev": "npx @tailwindcss/cli -i src/input.css -o dist/output.css --watch"'
    echo '  "build": "npx @tailwindcss/cli -i src/input.css -o dist/output.css --minify"'
    ;;

  *)
    error "Unknown framework: $FRAMEWORK"
    echo "Supported: nextjs, vite, remix, astro, plain"
    exit 1
    ;;
esac

echo ""
ok "Tailwind CSS v4 setup complete for ${FRAMEWORK}!"
info "Run your dev server and start using utility classes."
