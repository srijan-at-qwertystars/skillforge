#!/usr/bin/env bash
#
# scaffold-astro-project.sh — Scaffold a new Astro project with common templates and integrations.
#
# Usage:
#   ./scaffold-astro-project.sh [OPTIONS] <project-name>
#
# Options:
#   --template <type>       Project template: blog, docs, portfolio, ecommerce (default: blog)
#   --integrations <list>   Comma-separated integrations: react,vue,svelte,tailwind (default: tailwind)
#   --output <mode>         Output mode: static, server (default: static)
#   --adapter <name>        SSR adapter: node, vercel, netlify, cloudflare (requires --output server)
#   --typescript <level>    TypeScript strictness: base, strict, strictest (default: strict)
#   --package-manager <pm>  Package manager: npm, pnpm, yarn (default: npm)
#   --dry-run               Show what would be created without making changes
#   -h, --help              Show this help message
#
# Examples:
#   ./scaffold-astro-project.sh my-blog
#   ./scaffold-astro-project.sh --template docs --integrations react,tailwind my-docs-site
#   ./scaffold-astro-project.sh --template ecommerce --output server --adapter vercel my-shop

set -euo pipefail

# --- Defaults ---
TEMPLATE="blog"
INTEGRATIONS="tailwind"
OUTPUT_MODE="static"
ADAPTER=""
TS_STRICTNESS="strict"
PKG_MANAGER="npm"
DRY_RUN=false
PROJECT_NAME=""

# --- Color helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template)       TEMPLATE="$2"; shift 2 ;;
    --integrations)   INTEGRATIONS="$2"; shift 2 ;;
    --output)         OUTPUT_MODE="$2"; shift 2 ;;
    --adapter)        ADAPTER="$2"; shift 2 ;;
    --typescript)     TS_STRICTNESS="$2"; shift 2 ;;
    --package-manager) PKG_MANAGER="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)        usage ;;
    -*)               error "Unknown option: $1"; usage ;;
    *)                PROJECT_NAME="$1"; shift ;;
  esac
done

# --- Validate inputs ---
if [[ -z "$PROJECT_NAME" ]]; then
  error "Project name is required."
  usage
fi

if [[ ! "$TEMPLATE" =~ ^(blog|docs|portfolio|ecommerce)$ ]]; then
  error "Invalid template: $TEMPLATE. Must be one of: blog, docs, portfolio, ecommerce"
  exit 1
fi

if [[ ! "$OUTPUT_MODE" =~ ^(static|server)$ ]]; then
  error "Invalid output mode: $OUTPUT_MODE. Must be: static or server"
  exit 1
fi

if [[ "$OUTPUT_MODE" == "server" && -n "$ADAPTER" ]]; then
  if [[ ! "$ADAPTER" =~ ^(node|vercel|netlify|cloudflare)$ ]]; then
    error "Invalid adapter: $ADAPTER. Must be one of: node, vercel, netlify, cloudflare"
    exit 1
  fi
fi

if [[ "$OUTPUT_MODE" == "server" && -z "$ADAPTER" ]]; then
  warn "Server mode selected without an adapter. Defaulting to node."
  ADAPTER="node"
fi

if [[ ! "$TS_STRICTNESS" =~ ^(base|strict|strictest)$ ]]; then
  error "Invalid TypeScript strictness: $TS_STRICTNESS. Must be: base, strict, or strictest"
  exit 1
fi

if [[ ! "$PKG_MANAGER" =~ ^(npm|pnpm|yarn)$ ]]; then
  error "Invalid package manager: $PKG_MANAGER. Must be: npm, pnpm, or yarn"
  exit 1
fi

if [[ -d "$PROJECT_NAME" ]]; then
  error "Directory '$PROJECT_NAME' already exists."
  exit 1
fi

# --- Split integrations into array ---
IFS=',' read -ra INTEGRATION_LIST <<< "$INTEGRATIONS"

# Validate integrations
for int in "${INTEGRATION_LIST[@]}"; do
  if [[ ! "$int" =~ ^(react|vue|svelte|tailwind|solid|preact|mdx|sitemap|db)$ ]]; then
    error "Invalid integration: $int"
    exit 1
  fi
done

# --- Dry run summary ---
info "Project Configuration:"
echo "  Name:           $PROJECT_NAME"
echo "  Template:       $TEMPLATE"
echo "  Integrations:   ${INTEGRATION_LIST[*]}"
echo "  Output:         $OUTPUT_MODE"
[[ -n "$ADAPTER" ]] && echo "  Adapter:        $ADAPTER"
echo "  TypeScript:     $TS_STRICTNESS"
echo "  Package Manager: $PKG_MANAGER"
echo ""

if $DRY_RUN; then
  info "Dry run — no files created."
  exit 0
fi

# --- Check prerequisites ---
if ! command -v node &>/dev/null; then
  error "Node.js is required. Install from https://nodejs.org/"
  exit 1
fi

if ! command -v "$PKG_MANAGER" &>/dev/null; then
  error "$PKG_MANAGER is not installed."
  exit 1
fi

# --- Create project ---
info "Creating Astro project: $PROJECT_NAME"
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Initialize package.json
"$PKG_MANAGER" init -y >/dev/null 2>&1

# Install Astro
info "Installing Astro..."
case "$PKG_MANAGER" in
  npm)  npm install astro@latest --save-dev --quiet 2>/dev/null ;;
  pnpm) pnpm add astro@latest -D --silent 2>/dev/null ;;
  yarn) yarn add astro@latest --dev --silent 2>/dev/null ;;
esac

# --- Create directory structure ---
info "Creating project structure..."
mkdir -p src/{pages,components,layouts,content,assets,styles}
mkdir -p public

# Template-specific directories
case "$TEMPLATE" in
  blog)
    mkdir -p src/content/blog src/content/authors
    ;;
  docs)
    mkdir -p src/content/docs src/content/docs/{getting-started,guides,reference}
    ;;
  portfolio)
    mkdir -p src/content/projects src/content/testimonials
    ;;
  ecommerce)
    mkdir -p src/content/products src/content/categories
    mkdir -p src/actions src/pages/api
    ;;
esac

# --- Create tsconfig.json ---
cat > tsconfig.json <<EOF
{
  "extends": "astro/tsconfigs/${TS_STRICTNESS}",
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"],
      "@components/*": ["src/components/*"],
      "@layouts/*": ["src/layouts/*"],
      "@content/*": ["src/content/*"]
    }
  }
}
EOF

# --- Build astro.config.mjs ---
CONFIG_IMPORTS="import { defineConfig } from 'astro/config';"
CONFIG_INTEGRATIONS=""
CONFIG_ADAPTER=""
INTEGRATION_PKGS=()

for int in "${INTEGRATION_LIST[@]}"; do
  CONFIG_IMPORTS="$CONFIG_IMPORTS
import ${int} from '@astrojs/${int}';"
  INTEGRATION_PKGS+=("@astrojs/${int}")
  if [[ -n "$CONFIG_INTEGRATIONS" ]]; then
    CONFIG_INTEGRATIONS="$CONFIG_INTEGRATIONS, ${int}()"
  else
    CONFIG_INTEGRATIONS="${int}()"
  fi
done

# Install framework deps as needed
for int in "${INTEGRATION_LIST[@]}"; do
  case "$int" in
    react) INTEGRATION_PKGS+=("react" "react-dom") ;;
    vue)   INTEGRATION_PKGS+=("vue") ;;
    svelte) INTEGRATION_PKGS+=("svelte") ;;
  esac
done

if [[ "$OUTPUT_MODE" == "server" && -n "$ADAPTER" ]]; then
  ADAPTER_PKG="@astrojs/${ADAPTER}"
  CONFIG_IMPORTS="$CONFIG_IMPORTS
import ${ADAPTER}Adapter from '${ADAPTER_PKG}';"
  INTEGRATION_PKGS+=("$ADAPTER_PKG")

  case "$ADAPTER" in
    node)       CONFIG_ADAPTER="adapter: ${ADAPTER}Adapter({ mode: 'standalone' })," ;;
    vercel)     CONFIG_ADAPTER="adapter: ${ADAPTER}Adapter()," ;;
    netlify)    CONFIG_ADAPTER="adapter: ${ADAPTER}Adapter()," ;;
    cloudflare) CONFIG_ADAPTER="adapter: ${ADAPTER}Adapter()," ;;
  esac
fi

# Add sitemap and MDX for blog/docs
case "$TEMPLATE" in
  blog|docs)
    CONFIG_IMPORTS="$CONFIG_IMPORTS
import sitemap from '@astrojs/sitemap';
import mdx from '@astrojs/mdx';"
    CONFIG_INTEGRATIONS="$CONFIG_INTEGRATIONS, sitemap(), mdx()"
    INTEGRATION_PKGS+=("@astrojs/sitemap" "@astrojs/mdx")
    ;;
esac

cat > astro.config.mjs <<EOF
${CONFIG_IMPORTS}

export default defineConfig({
  site: 'https://example.com',
  output: '${OUTPUT_MODE}',
  ${CONFIG_ADAPTER}
  integrations: [${CONFIG_INTEGRATIONS}],
  image: {
    domains: [],
  },
});
EOF

# --- Install integration packages ---
info "Installing integrations: ${INTEGRATION_PKGS[*]}"
case "$PKG_MANAGER" in
  npm)  npm install "${INTEGRATION_PKGS[@]}" --save-dev --quiet 2>/dev/null ;;
  pnpm) pnpm add "${INTEGRATION_PKGS[@]}" -D --silent 2>/dev/null ;;
  yarn) yarn add "${INTEGRATION_PKGS[@]}" --dev --silent 2>/dev/null ;;
esac

# --- Create content config ---
cat > content.config.ts <<'CONTENTEOF'
import { defineCollection, z } from 'astro:content';
import { glob, file } from 'astro/loaders';

const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    date: z.coerce.date(),
    updatedDate: z.coerce.date().optional(),
    draft: z.boolean().default(false),
    tags: z.array(z.string()).default([]),
    image: z.string().optional(),
    author: z.string().optional(),
  }),
});

export const collections = { blog };
CONTENTEOF

# --- Create base layout ---
cat > src/layouts/Base.astro <<'LAYOUTEOF'
---
interface Props {
  title: string;
  description?: string;
  image?: string;
}

const { title, description = 'Built with Astro', image } = Astro.props;
const canonicalURL = new URL(Astro.url.pathname, Astro.site);
---
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="generator" content={Astro.generator} />
  <title>{title}</title>
  <meta name="description" content={description} />
  <link rel="canonical" href={canonicalURL} />
  <meta property="og:title" content={title} />
  <meta property="og:description" content={description} />
  <meta property="og:type" content="website" />
  <meta property="og:url" content={canonicalURL} />
  {image && <meta property="og:image" content={new URL(image, Astro.site)} />}
  <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
</head>
<body>
  <header>
    <nav>
      <a href="/">Home</a>
      <a href="/blog">Blog</a>
      <a href="/about">About</a>
    </nav>
  </header>
  <main>
    <slot />
  </main>
  <footer>
    <p>&copy; {new Date().getFullYear()} My Site. Built with Astro.</p>
  </footer>
</body>
</html>
LAYOUTEOF

# --- Create index page ---
cat > src/pages/index.astro <<'INDEXEOF'
---
import Base from '../layouts/Base.astro';
---
<Base title="Home">
  <h1>Welcome to your new Astro site!</h1>
  <p>Get started by editing <code>src/pages/index.astro</code>.</p>
</Base>
INDEXEOF

# --- Create 404 page ---
cat > src/pages/404.astro <<'NOTFOUNDEOF'
---
import Base from '../layouts/Base.astro';
---
<Base title="404 — Not Found">
  <h1>404 — Page Not Found</h1>
  <p>The page you're looking for doesn't exist.</p>
  <a href="/">Go Home</a>
</Base>
NOTFOUNDEOF

# --- Create sample content ---
case "$TEMPLATE" in
  blog)
    cat > src/content/blog/first-post.md <<'SAMPLEEOF'
---
title: "Welcome to My Blog"
description: "This is the first post on my new Astro blog."
date: 2024-01-15
tags: ["astro", "blogging"]
---

# Welcome!

This is your first blog post. Edit or delete it, then start writing!
SAMPLEEOF
    ;;
  docs)
    cat > src/content/docs/getting-started/introduction.md <<'SAMPLEEOF'
---
title: "Introduction"
description: "Getting started with the documentation."
date: 2024-01-15
tags: ["docs"]
---

# Introduction

Welcome to the documentation. Start here to get up and running.
SAMPLEEOF
    ;;
esac

# --- Create .env.example ---
cat > .env.example <<'ENVEOF'
# Public variables (available in client & server code)
PUBLIC_SITE_URL=https://example.com

# Private variables (server-side only)
# DATABASE_URL=
# CMS_API_KEY=
# AUTH_SECRET=
ENVEOF

# --- Create .gitignore ---
cat > .gitignore <<'GITEOF'
node_modules/
dist/
.astro/
.env
.env.local
.DS_Store
*.log
GITEOF

# --- Create public assets ---
cat > public/favicon.svg <<'FAVEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36" fill="none">
  <rect width="36" height="36" rx="8" fill="#7c3aed"/>
  <text x="18" y="26" text-anchor="middle" font-size="22" fill="white" font-family="system-ui">A</text>
</svg>
FAVEOF

cat > public/robots.txt <<'ROBOTEOF'
User-agent: *
Allow: /
Sitemap: https://example.com/sitemap-index.xml
ROBOTEOF

# --- Update package.json scripts ---
# Use node to update package.json properly
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.scripts = {
  dev: 'astro dev',
  build: 'astro build',
  preview: 'astro preview',
  sync: 'astro sync',
  check: 'astro check',
};
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"

# --- Tailwind config ---
for int in "${INTEGRATION_LIST[@]}"; do
  if [[ "$int" == "tailwind" ]]; then
    cat > tailwind.config.mjs <<'TWEOF'
/** @type {import('tailwindcss').Config} */
export default {
  content: ['./src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}'],
  theme: {
    extend: {},
  },
  plugins: [],
};
TWEOF

    mkdir -p src/styles
    cat > src/styles/global.css <<'CSSEOF'
@tailwind base;
@tailwind components;
@tailwind utilities;
CSSEOF
    break
  fi
done

# --- Done! ---
echo ""
ok "Project '$PROJECT_NAME' created successfully!"
echo ""
info "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  $PKG_MANAGER run dev"
echo ""
