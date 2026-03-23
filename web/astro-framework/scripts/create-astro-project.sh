#!/usr/bin/env bash
#
# create-astro-project.sh — Scaffold an Astro project with common integrations
#
# Usage:
#   ./create-astro-project.sh <project-name> [options]
#
# Options:
#   --ui=react|vue|svelte|solid|preact   UI framework (default: react)
#   --tailwind                           Add Tailwind CSS (default: enabled)
#   --no-tailwind                        Skip Tailwind CSS
#   --sitemap                            Add sitemap integration (default: enabled)
#   --no-sitemap                         Skip sitemap
#   --mdx                               Add MDX support (default: enabled)
#   --no-mdx                            Skip MDX
#   --ssr=vercel|netlify|cloudflare|node SSR adapter (default: none, static)
#   --db                                Add Astro DB
#   --typescript=strict|strictest       TypeScript strictness (default: strict)
#
# Examples:
#   ./create-astro-project.sh my-blog
#   ./create-astro-project.sh my-app --ui=vue --ssr=vercel
#   ./create-astro-project.sh my-site --ui=svelte --no-tailwind --ssr=node
#

set -euo pipefail

# --- Defaults ---
UI_FRAMEWORK="react"
TAILWIND=true
SITEMAP=true
MDX=true
SSR_ADAPTER=""
DB=false
TS_STRICT="strict"
PROJECT_NAME=""

# --- Parse arguments ---
for arg in "$@"; do
  case "$arg" in
    --ui=*)       UI_FRAMEWORK="${arg#--ui=}" ;;
    --tailwind)   TAILWIND=true ;;
    --no-tailwind) TAILWIND=false ;;
    --sitemap)    SITEMAP=true ;;
    --no-sitemap) SITEMAP=false ;;
    --mdx)        MDX=true ;;
    --no-mdx)     MDX=false ;;
    --ssr=*)      SSR_ADAPTER="${arg#--ssr=}" ;;
    --db)         DB=true ;;
    --typescript=*) TS_STRICT="${arg#--typescript=}" ;;
    --help|-h)
      head -25 "$0" | tail -23
      exit 0
      ;;
    -*)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
    *)
      PROJECT_NAME="$arg"
      ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Error: Project name is required." >&2
  echo "Usage: $0 <project-name> [options]" >&2
  exit 1
fi

if [[ -d "$PROJECT_NAME" ]]; then
  echo "Error: Directory '$PROJECT_NAME' already exists." >&2
  exit 1
fi

echo "🚀 Creating Astro project: $PROJECT_NAME"
echo "   UI Framework: $UI_FRAMEWORK"
echo "   Tailwind: $TAILWIND"
echo "   Sitemap: $SITEMAP"
echo "   MDX: $MDX"
echo "   SSR Adapter: ${SSR_ADAPTER:-none (static)}"
echo "   TypeScript: $TS_STRICT"
echo ""

# --- Create project ---
npm create astro@latest -- "$PROJECT_NAME" \
  --template minimal \
  --typescript "$TS_STRICT" \
  --install \
  --no-git \
  --skip-houston

cd "$PROJECT_NAME"

# --- Add integrations ---
INTEGRATIONS=()

case "$UI_FRAMEWORK" in
  react)   INTEGRATIONS+=("@astrojs/react") ;;
  vue)     INTEGRATIONS+=("@astrojs/vue") ;;
  svelte)  INTEGRATIONS+=("@astrojs/svelte") ;;
  solid)   INTEGRATIONS+=("@astrojs/solid-js") ;;
  preact)  INTEGRATIONS+=("@astrojs/preact") ;;
  none)    ;;
  *)
    echo "Error: Unknown UI framework '$UI_FRAMEWORK'" >&2
    exit 1
    ;;
esac

[[ "$TAILWIND" == true ]] && INTEGRATIONS+=("@astrojs/tailwind")
[[ "$SITEMAP" == true ]] && INTEGRATIONS+=("@astrojs/sitemap")
[[ "$MDX" == true ]] && INTEGRATIONS+=("@astrojs/mdx")

if [[ -n "$SSR_ADAPTER" ]]; then
  case "$SSR_ADAPTER" in
    vercel)     INTEGRATIONS+=("@astrojs/vercel") ;;
    netlify)    INTEGRATIONS+=("@astrojs/netlify") ;;
    cloudflare) INTEGRATIONS+=("@astrojs/cloudflare") ;;
    node)       INTEGRATIONS+=("@astrojs/node") ;;
    *)
      echo "Error: Unknown SSR adapter '$SSR_ADAPTER'" >&2
      exit 1
      ;;
  esac
fi

[[ "$DB" == true ]] && INTEGRATIONS+=("@astrojs/db")

for integration in "${INTEGRATIONS[@]}"; do
  echo "📦 Adding integration: $integration"
  npx astro add "${integration##@astrojs/}" --yes 2>/dev/null || {
    echo "   Falling back to npm install for $integration"
    npm install "$integration"
  }
done

# --- Create common directories ---
mkdir -p src/{components,layouts,content/blog,styles,assets}

# --- Create base layout ---
cat > src/layouts/Base.astro << 'LAYOUT'
---
interface Props {
  title: string;
  description?: string;
}

const { title, description = '' } = Astro.props;
---
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="generator" content={Astro.generator} />
    {description && <meta name="description" content={description} />}
    <title>{title}</title>
  </head>
  <body>
    <slot />
  </body>
</html>
LAYOUT

# --- Create index page ---
cat > src/pages/index.astro << 'INDEX'
---
import Base from '../layouts/Base.astro';
---
<Base title="Home">
  <main>
    <h1>Welcome to Astro</h1>
    <p>Edit <code>src/pages/index.astro</code> to get started.</p>
  </main>
</Base>
INDEX

# --- Create content collection config ---
cat > src/content.config.ts << 'CONTENT'
import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    pubDate: z.coerce.date(),
    updatedDate: z.coerce.date().optional(),
    heroImage: z.string().optional(),
    tags: z.array(z.string()).default([]),
    draft: z.boolean().default(false),
  }),
});

export const collections = { blog };
CONTENT

# --- Create sample blog post ---
cat > src/content/blog/hello-world.md << 'POST'
---
title: "Hello World"
description: "My first blog post"
pubDate: 2024-01-15
tags: ["astro", "blogging"]
---

# Hello World

This is a sample blog post created by the Astro project scaffolder.
POST

# --- Initialize git ---
git init
cat > .gitignore << 'GITIGNORE'
node_modules/
dist/
.astro/
.env
.env.*
!.env.example
GITIGNORE

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  npm run dev"
echo ""
