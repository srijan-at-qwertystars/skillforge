#!/usr/bin/env bash
# setup-pwa.sh — Add PWA support to an existing web project
#
# Usage: ./setup-pwa.sh [project-dir] [app-name]
#   project-dir  Path to web project root (default: current directory)
#   app-name     Application name for manifest (default: "My PWA")
#
# Creates: manifest.json, sw.js, offline.html, and updates index.html if found.
# Does NOT overwrite existing files (skips with warning).

set -euo pipefail

PROJECT_DIR="${1:-.}"
APP_NAME="${2:-My PWA}"
SHORT_NAME="${APP_NAME:0:12}"

cd "$PROJECT_DIR"
echo "📦 Setting up PWA in: $(pwd)"
echo "   App name: $APP_NAME"

# Detect public directory
PUBLIC_DIR="."
for dir in public dist build src/main/resources/static www; do
  if [ -d "$dir" ]; then
    PUBLIC_DIR="$dir"
    break
  fi
done
echo "   Public dir: $PUBLIC_DIR"

# --- manifest.json ---
MANIFEST="$PUBLIC_DIR/manifest.json"
if [ -f "$MANIFEST" ]; then
  echo "⚠️  Skipping $MANIFEST (already exists)"
else
  cat > "$MANIFEST" << MANIFEST_EOF
{
  "name": "$APP_NAME",
  "short_name": "$SHORT_NAME",
  "description": "$APP_NAME — Progressive Web App",
  "start_url": "/",
  "id": "/",
  "display": "standalone",
  "background_color": "#ffffff",
  "theme_color": "#1a73e8",
  "orientation": "any",
  "icons": [
    { "src": "/icons/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/icons/icon-512.png", "sizes": "512x512", "type": "image/png" },
    { "src": "/icons/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ],
  "screenshots": [
    { "src": "/screenshots/desktop.png", "sizes": "1280x720", "type": "image/png", "form_factor": "wide" },
    { "src": "/screenshots/mobile.png", "sizes": "640x1136", "type": "image/png", "form_factor": "narrow" }
  ]
}
MANIFEST_EOF
  echo "✅ Created $MANIFEST"
fi

# --- Service Worker ---
SW_FILE="$PUBLIC_DIR/sw.js"
if [ -f "$SW_FILE" ]; then
  echo "⚠️  Skipping $SW_FILE (already exists)"
else
  cat > "$SW_FILE" << 'SW_EOF'
const CACHE_NAME = 'app-v1';
const PRECACHE_URLS = ['/', '/offline.html'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(PRECACHE_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((names) => Promise.all(
        names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request).catch(() => caches.match('/offline.html'))
    );
    return;
  }
  event.respondWith(
    caches.match(event.request).then((cached) => cached || fetch(event.request))
  );
});
SW_EOF
  echo "✅ Created $SW_FILE"
fi

# --- Offline page ---
OFFLINE="$PUBLIC_DIR/offline.html"
if [ -f "$OFFLINE" ]; then
  echo "⚠️  Skipping $OFFLINE (already exists)"
else
  cat > "$OFFLINE" << 'OFFLINE_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Offline</title>
  <style>
    body { font-family: system-ui, sans-serif; display: flex; align-items: center;
           justify-content: center; min-height: 100vh; margin: 0; background: #f5f5f5; color: #333; }
    .container { text-align: center; padding: 2rem; }
    h1 { font-size: 1.5rem; margin-bottom: 0.5rem; }
    p { color: #666; }
    button { margin-top: 1rem; padding: 0.5rem 1.5rem; border: none; border-radius: 4px;
             background: #1a73e8; color: white; cursor: pointer; font-size: 1rem; }
  </style>
</head>
<body>
  <div class="container">
    <h1>You're offline</h1>
    <p>Check your internet connection and try again.</p>
    <button onclick="window.location.reload()">Retry</button>
  </div>
</body>
</html>
OFFLINE_EOF
  echo "✅ Created $OFFLINE"
fi

# --- Icons directory ---
ICONS_DIR="$PUBLIC_DIR/icons"
if [ ! -d "$ICONS_DIR" ]; then
  mkdir -p "$ICONS_DIR"
  echo "✅ Created $ICONS_DIR/ (add icon-192.png and icon-512.png)"
fi

# --- Inject manifest link into index.html ---
INDEX_HTML="$PUBLIC_DIR/index.html"
if [ -f "$INDEX_HTML" ]; then
  if grep -q 'rel="manifest"' "$INDEX_HTML"; then
    echo "⚠️  index.html already has manifest link"
  else
    # Insert before </head>
    sed -i 's|</head>|  <link rel="manifest" href="/manifest.json">\n  <meta name="theme-color" content="#1a73e8">\n</head>|' "$INDEX_HTML"
    echo "✅ Added manifest link to $INDEX_HTML"
  fi

  if grep -q 'serviceWorker' "$INDEX_HTML"; then
    echo "⚠️  index.html already registers a service worker"
  else
    # Insert SW registration before </body>
    sed -i 's|</body>|  <script>\n    if ("serviceWorker" in navigator) {\n      window.addEventListener("load", () => navigator.serviceWorker.register("/sw.js"));\n    }\n  </script>\n</body>|' "$INDEX_HTML"
    echo "✅ Added SW registration to $INDEX_HTML"
  fi
else
  echo "ℹ️  No index.html found — add manifest link and SW registration manually:"
  echo '   <link rel="manifest" href="/manifest.json">'
  echo '   <script>navigator.serviceWorker?.register("/sw.js")</script>'
fi

echo ""
echo "🎉 PWA setup complete! Next steps:"
echo "   1. Add icon-192.png and icon-512.png to $ICONS_DIR/"
echo "   2. Run: npx lighthouse http://localhost:3000 --only-categories=pwa"
echo "   3. For production, use Workbox: npm install workbox-cli --save-dev"
