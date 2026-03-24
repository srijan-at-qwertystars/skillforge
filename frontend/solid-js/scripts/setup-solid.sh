#!/usr/bin/env bash
# setup-solid.sh — Scaffold a SolidJS or SolidStart project with recommended config.
#
# Usage:
#   ./setup-solid.sh <project-name> [--start]
#
# Options:
#   --start    Create a SolidStart (full-stack) project instead of plain SolidJS
#
# Examples:
#   ./setup-solid.sh my-app           # Plain SolidJS + Vite
#   ./setup-solid.sh my-app --start   # SolidStart with SSR

set -euo pipefail

PROJECT_NAME="${1:-}"
USE_START=false

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Usage: $0 <project-name> [--start]"
  echo ""
  echo "Options:"
  echo "  --start    Create a SolidStart project (SSR, file-based routing)"
  exit 1
fi

for arg in "$@"; do
  [[ "$arg" == "--start" ]] && USE_START=true
done

if [[ -d "$PROJECT_NAME" ]]; then
  echo "Error: Directory '$PROJECT_NAME' already exists."
  exit 1
fi

# Check for package manager
PM="npm"
command -v pnpm &>/dev/null && PM="pnpm"

echo "==> Creating SolidJS project: $PROJECT_NAME"
echo "    Package manager: $PM"
echo "    Mode: $(if $USE_START; then echo 'SolidStart'; else echo 'SolidJS + Vite'; fi)"
echo ""

if $USE_START; then
  # SolidStart project
  mkdir -p "$PROJECT_NAME"
  cd "$PROJECT_NAME"

  cat > package.json <<'PKGJSON'
{
  "name": "solid-start-app",
  "type": "module",
  "scripts": {
    "dev": "vinxi dev",
    "build": "vinxi build",
    "start": "vinxi start",
    "test": "vitest",
    "test:ui": "vitest --ui"
  }
}
PKGJSON

  $PM install solid-js @solidjs/start @solidjs/router vinxi
  $PM install -D typescript vitest jsdom @solidjs/testing-library vite-plugin-solid @testing-library/jest-dom

  # app.config.ts
  cat > app.config.ts <<'EOF'
import { defineConfig } from "@solidjs/start/config";

export default defineConfig({
  server: {
    preset: "node-server",
  },
});
EOF

  # tsconfig
  cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "preserve",
    "jsxImportSource": "solid-js",
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "types": ["vinxi/types/client"]
  }
}
EOF

  # Source files
  mkdir -p src/routes
  cat > src/app.tsx <<'EOF'
import { Router } from "@solidjs/router";
import { FileRoutes } from "@solidjs/start/router";
import { Suspense } from "solid-js";

export default function App() {
  return (
    <Router root={(props) => <Suspense>{props.children}</Suspense>}>
      <FileRoutes />
    </Router>
  );
}
EOF

  cat > src/entry-server.tsx <<'EOF'
import { createHandler, StartServer } from "@solidjs/start/server";

export default createHandler(() => (
  <StartServer document={({ assets, children, scripts }) => (
    <html lang="en">
      <head><meta charset="utf-8" />{assets}</head>
      <body><div id="app">{children}</div>{scripts}</body>
    </html>
  )} />
));
EOF

  cat > src/entry-client.tsx <<'EOF'
import { mount, StartClient } from "@solidjs/start/client";
mount(() => <StartClient />, document.getElementById("app")!);
EOF

  cat > src/routes/index.tsx <<'EOF'
export default function Home() {
  return <main><h1>Welcome to SolidStart</h1></main>;
}
EOF

else
  # Plain SolidJS + Vite
  mkdir -p "$PROJECT_NAME"
  cd "$PROJECT_NAME"

  cat > package.json <<'PKGJSON'
{
  "name": "solid-app",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview",
    "test": "vitest",
    "test:ui": "vitest --ui"
  }
}
PKGJSON

  $PM install solid-js
  $PM install -D typescript vite vite-plugin-solid vitest jsdom @solidjs/testing-library @testing-library/jest-dom

  cat > vite.config.ts <<'EOF'
import { defineConfig } from "vite";
import solidPlugin from "vite-plugin-solid";

export default defineConfig({
  plugins: [solidPlugin()],
  build: { target: "esnext" },
  test: {
    environment: "jsdom",
    globals: true,
    transformMode: { web: [/\.[jt]sx?$/] },
    deps: { optimizer: { web: { include: ["solid-js"] } } },
  },
});
EOF

  cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "preserve",
    "jsxImportSource": "solid-js",
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
EOF

  mkdir -p src
  cat > src/App.tsx <<'EOF'
import { createSignal } from "solid-js";

function App() {
  const [count, setCount] = createSignal(0);
  return (
    <div>
      <h1>SolidJS App</h1>
      <button onClick={() => setCount(c => c + 1)}>Count: {count()}</button>
    </div>
  );
}

export default App;
EOF

  cat > src/index.tsx <<'EOF'
import { render } from "solid-js/web";
import App from "./App";
render(() => <App />, document.getElementById("root")!);
EOF

  cat > index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8" /><title>Solid App</title></head>
<body><div id="root"></div><script src="/src/index.tsx" type="module"></script></body>
</html>
EOF
fi

# Shared: .gitignore
cat > .gitignore <<'EOF'
node_modules/
dist/
.vinxi/
.output/
*.local
EOF

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  $PM run dev"
