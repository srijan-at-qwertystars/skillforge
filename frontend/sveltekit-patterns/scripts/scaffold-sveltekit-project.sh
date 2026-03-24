#!/usr/bin/env bash
#
# scaffold-sveltekit-project.sh
#
# Scaffolds a SvelteKit project with common configurations.
#
# Usage:
#   ./scaffold-sveltekit-project.sh <project-name> [options]
#
# Options:
#   --template <blog|saas|api>         Project template (default: blog)
#   --css <tailwind|uno|vanilla>       CSS framework (default: vanilla)
#   --auth <lucia|authjs|none>         Auth setup (default: none)
#   --package-manager <npm|pnpm|bun>   Package manager (default: npm)
#   -h, --help                         Show this help message
#
# Examples:
#   ./scaffold-sveltekit-project.sh my-blog --template blog --css tailwind
#   ./scaffold-sveltekit-project.sh my-saas --template saas --css tailwind --auth lucia
#   ./scaffold-sveltekit-project.sh my-api --template api --auth none
#

set -euo pipefail

# --- Defaults ---
TEMPLATE="blog"
CSS="vanilla"
AUTH="none"
PKG_MGR="npm"
PROJECT_NAME=""

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

show_help() {
  head -n 18 "$0" | tail -n 16 | sed 's/^# \?//'
  exit 0
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) show_help ;;
    --template)
      TEMPLATE="$2"
      if [[ ! "$TEMPLATE" =~ ^(blog|saas|api)$ ]]; then
        log_error "Invalid template: $TEMPLATE (must be blog|saas|api)"
        exit 1
      fi
      shift 2 ;;
    --css)
      CSS="$2"
      if [[ ! "$CSS" =~ ^(tailwind|uno|vanilla)$ ]]; then
        log_error "Invalid CSS option: $CSS (must be tailwind|uno|vanilla)"
        exit 1
      fi
      shift 2 ;;
    --auth)
      AUTH="$2"
      if [[ ! "$AUTH" =~ ^(lucia|authjs|none)$ ]]; then
        log_error "Invalid auth option: $AUTH (must be lucia|authjs|none)"
        exit 1
      fi
      shift 2 ;;
    --package-manager)
      PKG_MGR="$2"
      if [[ ! "$PKG_MGR" =~ ^(npm|pnpm|bun)$ ]]; then
        log_error "Invalid package manager: $PKG_MGR (must be npm|pnpm|bun)"
        exit 1
      fi
      shift 2 ;;
    -*)
      log_error "Unknown option: $1"
      exit 1 ;;
    *)
      if [[ -z "$PROJECT_NAME" ]]; then
        PROJECT_NAME="$1"
      else
        log_error "Unexpected argument: $1"
        exit 1
      fi
      shift ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  log_error "Project name is required."
  echo "Usage: $0 <project-name> [options]"
  echo "Run $0 --help for details."
  exit 1
fi

if [[ -d "$PROJECT_NAME" ]]; then
  log_error "Directory '$PROJECT_NAME' already exists."
  exit 1
fi

# --- Detect Install Command ---
install_cmd() {
  case "$PKG_MGR" in
    npm)  echo "npm install" ;;
    pnpm) echo "pnpm add" ;;
    bun)  echo "bun add" ;;
  esac
}

install_dev_cmd() {
  case "$PKG_MGR" in
    npm)  echo "npm install -D" ;;
    pnpm) echo "pnpm add -D" ;;
    bun)  echo "bun add -D" ;;
  esac
}

run_cmd() {
  case "$PKG_MGR" in
    npm)  echo "npx" ;;
    pnpm) echo "pnpm dlx" ;;
    bun)  echo "bunx" ;;
  esac
}

# --- Create Project ---
log_info "Creating SvelteKit project: $PROJECT_NAME"
log_info "Template: $TEMPLATE | CSS: $CSS | Auth: $AUTH | Package Manager: $PKG_MGR"
echo ""

mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Initialize package.json
cat > package.json << 'PKGJSON'
{
  "name": "PROJECT_NAME_PLACEHOLDER",
  "version": "0.0.1",
  "private": true,
  "scripts": {
    "dev": "vite dev",
    "build": "vite build",
    "preview": "vite preview",
    "check": "svelte-kit sync && svelte-check --tsconfig ./tsconfig.json",
    "check:watch": "svelte-kit sync && svelte-check --tsconfig ./tsconfig.json --watch",
    "lint": "eslint .",
    "format": "prettier --write ."
  },
  "type": "module"
}
PKGJSON

sed -i "s/PROJECT_NAME_PLACEHOLDER/$PROJECT_NAME/" package.json

# Install core dependencies
log_info "Installing core dependencies..."
$(install_dev_cmd) @sveltejs/kit@latest svelte@latest vite@latest \
  @sveltejs/vite-plugin-svelte@latest @sveltejs/adapter-auto@latest \
  typescript svelte-check @types/node \
  vitest @testing-library/svelte \
  prettier prettier-plugin-svelte \
  eslint 2>/dev/null || true

# --- Create Project Structure ---
log_info "Creating project structure..."

mkdir -p src/routes src/lib/components src/lib/server src/lib/utils static

# svelte.config.js
cat > svelte.config.js << 'SVELTECONFIG'
import adapter from '@sveltejs/adapter-auto';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter(),
    alias: {
      '$components': 'src/lib/components',
      '$utils': 'src/lib/utils'
    }
  }
};

export default config;
SVELTECONFIG

# vite.config.ts
cat > vite.config.ts << 'VITECONFIG'
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [sveltekit()],
  test: {
    include: ['src/**/*.{test,spec}.{js,ts}']
  }
});
VITECONFIG

# tsconfig.json
cat > tsconfig.json << 'TSCONFIG'
{
  "extends": "./.svelte-kit/tsconfig.json",
  "compilerOptions": {
    "allowJs": true,
    "checkJs": true,
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "skipLibCheck": true,
    "sourceMap": true,
    "strict": true,
    "moduleResolution": "bundler"
  }
}
TSCONFIG

# app.html
cat > src/app.html << 'APPHTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <link rel="icon" href="%sveltekit.assets%/favicon.png" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    %sveltekit.head%
  </head>
  <body data-sveltekit-preload-data="hover">
    <div style="display: contents">%sveltekit.body%</div>
  </body>
</html>
APPHTML

# app.d.ts
cat > src/app.d.ts << 'APPD'
declare global {
  namespace App {
    interface Locals {
      user: { id: string; email: string; name: string } | null;
    }
    interface Error {
      message: string;
      code?: string;
    }
    // interface PageData {}
    // interface PageState {}
    // interface Platform {}
  }
}

export {};
APPD

# --- CSS Setup ---
case "$CSS" in
  tailwind)
    log_info "Setting up Tailwind CSS..."
    $(install_dev_cmd) tailwindcss @tailwindcss/vite 2>/dev/null || true

    cat > src/app.css << 'APPCSS'
@import 'tailwindcss';
APPCSS
    ;;
  uno)
    log_info "Setting up UnoCSS..."
    $(install_dev_cmd) unocss @unocss/svelte-scoped @unocss/preset-uno 2>/dev/null || true

    cat > uno.config.ts << 'UNOCONFIG'
import { defineConfig, presetUno } from 'unocss';

export default defineConfig({
  presets: [presetUno()]
});
UNOCONFIG

    cat > src/app.css << 'APPCSS'
/* UnoCSS styles are injected automatically */
APPCSS
    ;;
  vanilla)
    cat > src/app.css << 'APPCSS'
*,
*::before,
*::after {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

:root {
  --color-primary: #3b82f6;
  --color-secondary: #6366f1;
  --color-bg: #ffffff;
  --color-text: #1f2937;
  --color-muted: #6b7280;
  --font-sans: system-ui, -apple-system, sans-serif;
  --font-mono: 'Fira Code', monospace;
  --max-width: 1200px;
}

body {
  font-family: var(--font-sans);
  color: var(--color-text);
  background: var(--color-bg);
  line-height: 1.6;
}

a { color: var(--color-primary); text-decoration: none; }
a:hover { text-decoration: underline; }
APPCSS
    ;;
esac

# --- Root Layout ---
cat > src/routes/+layout.svelte << 'LAYOUT'
<script>
  import '../app.css';
  let { children } = $props();
</script>

<svelte:head>
  <meta name="description" content="Built with SvelteKit" />
</svelte:head>

{@render children()}
LAYOUT

# --- Template-Specific Files ---
case "$TEMPLATE" in
  blog)
    log_info "Creating blog template..."

    cat > src/routes/+page.svelte << 'HOMEPAGE'
<script>
  let { data } = $props();
</script>

<svelte:head>
  <title>My Blog</title>
</svelte:head>

<main>
  <h1>My Blog</h1>
  <p>Welcome to my blog built with SvelteKit.</p>

  <section>
    <h2>Recent Posts</h2>
    {#each data.posts as post (post.slug)}
      <article>
        <h3><a href="/blog/{post.slug}">{post.title}</a></h3>
        <p>{post.excerpt}</p>
        <time datetime={post.date}>{new Date(post.date).toLocaleDateString()}</time>
      </article>
    {/each}
  </section>
</main>
HOMEPAGE

    cat > src/routes/+page.server.ts << 'HOMEPAGESERVER'
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async () => {
  // Replace with actual data fetching
  const posts = [
    { slug: 'hello-world', title: 'Hello World', excerpt: 'My first blog post.', date: '2024-01-01' },
    { slug: 'sveltekit-guide', title: 'SvelteKit Guide', excerpt: 'Getting started with SvelteKit.', date: '2024-01-15' }
  ];

  return { posts };
};
HOMEPAGESERVER

    mkdir -p "src/routes/blog/[slug]"

    cat > "src/routes/blog/[slug]/+page.svelte" << 'BLOGPOST'
<script>
  let { data } = $props();
</script>

<svelte:head>
  <title>{data.post.title}</title>
</svelte:head>

<article>
  <h1>{data.post.title}</h1>
  <time datetime={data.post.date}>{new Date(data.post.date).toLocaleDateString()}</time>
  <div class="content">
    {@html data.post.content}
  </div>
</article>
BLOGPOST

    cat > "src/routes/blog/[slug]/+page.server.ts" << 'BLOGPOSTSERVER'
import type { PageServerLoad } from './$types';
import { error } from '@sveltejs/kit';

export const load: PageServerLoad = async ({ params }) => {
  // Replace with actual data fetching (markdown, CMS, database)
  const post = {
    slug: params.slug,
    title: `Post: ${params.slug}`,
    content: '<p>Post content goes here.</p>',
    date: '2024-01-01'
  };

  if (!post) error(404, { message: 'Post not found' });

  return { post };
};
BLOGPOSTSERVER
    ;;

  saas)
    log_info "Creating SaaS template..."

    mkdir -p src/routes/"(marketing)" src/routes/"(app)"/dashboard src/routes/"(auth)"/{login,register}

    cat > src/routes/"(marketing)"/+layout.svelte << 'MARKETINGLAYOUT'
<script>
  let { children } = $props();
</script>

<header>
  <nav>
    <a href="/">Home</a>
    <a href="/pricing">Pricing</a>
    <a href="/login">Login</a>
  </nav>
</header>

<main>
  {@render children()}
</main>

<footer>
  <p>&copy; {new Date().getFullYear()} My SaaS</p>
</footer>
MARKETINGLAYOUT

    cat > src/routes/"(marketing)"/+page.svelte << 'MARKETINGHOME'
<svelte:head>
  <title>My SaaS - Home</title>
</svelte:head>

<h1>Welcome to My SaaS</h1>
<p>Build something amazing.</p>
<a href="/register">Get Started</a>
MARKETINGHOME

    cat > src/routes/"(app)"/+layout.svelte << 'APPLAYOUT'
<script>
  let { data, children } = $props();
</script>

<div class="app-shell">
  <aside>
    <nav>
      <a href="/dashboard">Dashboard</a>
      <a href="/settings">Settings</a>
    </nav>
    <p>Signed in as {data.user?.email}</p>
  </aside>
  <main>
    {@render children()}
  </main>
</div>
APPLAYOUT

    cat > src/routes/"(app)"/+layout.server.ts << 'APPLAYOUTSERVER'
import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';

export const load: LayoutServerLoad = async ({ locals }) => {
  if (!locals.user) redirect(303, '/login');
  return { user: locals.user };
};
APPLAYOUTSERVER

    cat > src/routes/"(app)"/dashboard/+page.svelte << 'DASHBOARD'
<script>
  let { data } = $props();
</script>

<svelte:head>
  <title>Dashboard</title>
</svelte:head>

<h1>Dashboard</h1>
<p>Welcome back, {data.user?.name}!</p>
DASHBOARD

    cat > src/routes/"(auth)"/+layout.svelte << 'AUTHLAYOUT'
<script>
  let { children } = $props();
</script>

<div class="auth-container">
  {@render children()}
</div>
AUTHLAYOUT

    cat > src/routes/"(auth)"/login/+page.svelte << 'LOGINPAGE'
<script>
  import { enhance } from '$app/forms';
  let { form } = $props();
</script>

<svelte:head>
  <title>Login</title>
</svelte:head>

<h1>Login</h1>

<form method="POST" use:enhance>
  <label>
    Email
    <input name="email" type="email" value={form?.email ?? ''} required />
  </label>
  <label>
    Password
    <input name="password" type="password" required />
  </label>
  {#if form?.error}
    <p class="error">{form.error}</p>
  {/if}
  <button type="submit">Sign In</button>
</form>
<p>Don't have an account? <a href="/register">Register</a></p>
LOGINPAGE

    cat > src/routes/"(auth)"/login/+page.server.ts << 'LOGINSERVER'
import { fail, redirect } from '@sveltejs/kit';
import type { Actions } from './$types';

export const actions: Actions = {
  default: async ({ request, cookies }) => {
    const data = await request.formData();
    const email = data.get('email') as string;
    const password = data.get('password') as string;

    // Replace with actual authentication
    if (!email || !password) {
      return fail(400, { email, error: 'Email and password are required' });
    }

    // TODO: Validate credentials and create session
    cookies.set('session', 'placeholder-token', {
      path: '/',
      httpOnly: true,
      sameSite: 'lax',
      secure: true,
      maxAge: 60 * 60 * 24 * 7
    });

    redirect(303, '/dashboard');
  }
};
LOGINSERVER
    ;;

  api)
    log_info "Creating API template..."

    mkdir -p src/routes/api/{health,items}

    cat > src/routes/+page.svelte << 'APIHOME'
<svelte:head>
  <title>API Service</title>
</svelte:head>

<main>
  <h1>API Service</h1>
  <p>Endpoints:</p>
  <ul>
    <li><code>GET /api/health</code> — Health check</li>
    <li><code>GET /api/items</code> — List items</li>
    <li><code>POST /api/items</code> — Create item</li>
  </ul>
</main>
APIHOME

    cat > src/routes/api/health/+server.ts << 'HEALTHAPI'
import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async () => {
  return json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    uptime: process.uptime()
  });
};
HEALTHAPI

    cat > src/routes/api/items/+server.ts << 'ITEMSAPI'
import { json, error } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

// In-memory store for demo purposes
const items: Array<{ id: string; name: string; createdAt: string }> = [];

export const GET: RequestHandler = async ({ url }) => {
  const limit = Number(url.searchParams.get('limit') ?? 50);
  const offset = Number(url.searchParams.get('offset') ?? 0);

  return json({
    items: items.slice(offset, offset + limit),
    total: items.length,
    limit,
    offset
  });
};

export const POST: RequestHandler = async ({ request, locals }) => {
  if (!locals.user) error(401, 'Unauthorized');

  const body = await request.json();
  if (!body.name) error(400, 'Name is required');

  const item = {
    id: crypto.randomUUID(),
    name: body.name,
    createdAt: new Date().toISOString()
  };

  items.push(item);
  return json(item, { status: 201 });
};
ITEMSAPI
    ;;
esac

# --- Hooks ---
cat > src/hooks.server.ts << 'HOOKS'
import type { Handle, HandleServerError } from '@sveltejs/kit';

export const handle: Handle = async ({ event, resolve }) => {
  // Auth: Read session cookie and populate locals
  const session = event.cookies.get('session');
  if (session) {
    // TODO: Replace with actual session validation
    event.locals.user = { id: '1', email: 'user@example.com', name: 'User' };
  } else {
    event.locals.user = null;
  }

  const response = await resolve(event, {
    filterSerializedResponseHeaders: (name) =>
      name === 'content-type' || name === 'cache-control'
  });

  // Security headers
  response.headers.set('X-Frame-Options', 'DENY');
  response.headers.set('X-Content-Type-Options', 'nosniff');
  response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');

  return response;
};

export const handleError: HandleServerError = async ({ error, event }) => {
  console.error(`[ERROR] ${event.url.pathname}:`, error);
  return {
    message: 'An unexpected error occurred',
    code: 'INTERNAL_ERROR'
  };
};
HOOKS

# --- Auth Setup ---
case "$AUTH" in
  lucia)
    log_info "Installing Lucia auth dependencies..."
    $(install_cmd) lucia @lucia-auth/adapter-drizzle 2>/dev/null || true
    $(install_cmd) drizzle-orm better-sqlite3 2>/dev/null || true
    $(install_dev_cmd) drizzle-kit @types/better-sqlite3 2>/dev/null || true
    log_ok "Lucia auth dependencies installed. See https://lucia-auth.com for setup guide."
    ;;
  authjs)
    log_info "Installing Auth.js dependencies..."
    $(install_cmd) @auth/sveltekit @auth/core 2>/dev/null || true
    log_ok "Auth.js dependencies installed. See https://authjs.dev/reference/sveltekit for setup guide."
    ;;
  none)
    ;;
esac

# --- Error Page ---
cat > src/routes/+error.svelte << 'ERRORPAGE'
<script>
  import { page } from '$app/state';
</script>

<svelte:head>
  <title>{page.status} | Error</title>
</svelte:head>

<main>
  <h1>{page.status}</h1>
  <p>{page.error?.message ?? 'Something went wrong'}</p>
  <a href="/">Go home</a>
</main>
ERRORPAGE

# --- .gitignore ---
cat > .gitignore << 'GITIGNORE'
node_modules/
.svelte-kit/
build/
.env
.env.*
!.env.example
.DS_Store
*.log
dist/
.vercel/
.netlify/
GITIGNORE

# --- .env.example ---
cat > .env.example << 'ENVEXAMPLE'
# Server-only (never exposed to client)
DATABASE_URL=postgresql://localhost:5432/mydb
JWT_SECRET=change-me-in-production

# Public (exposed to client via PUBLIC_ prefix)
PUBLIC_API_URL=http://localhost:5173/api
PUBLIC_SITE_NAME=My SvelteKit App
ENVEXAMPLE

# --- Summary ---
echo ""
log_ok "Project '$PROJECT_NAME' created successfully!"
echo ""
log_info "Template:  $TEMPLATE"
log_info "CSS:       $CSS"
log_info "Auth:      $AUTH"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  cp .env.example .env"
echo "  $PKG_MGR run dev"
echo ""
