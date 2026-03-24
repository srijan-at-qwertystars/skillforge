---
name: pwa-patterns
description: >
  Build production-grade Progressive Web Apps with offline-first architecture, service workers,
  caching strategies, push notifications, and platform integration APIs. Covers Web App Manifest
  configuration (display modes, icons, shortcuts, share_target), Service Worker lifecycle
  (install/activate/fetch), caching patterns (cache-first, network-first, stale-while-revalidate,
  cache-only, network-only), Workbox library, Push API with VAPID keys, background sync, periodic
  background sync, IndexedDB offline storage, App Shell architecture, installability criteria,
  PWA in frameworks (Next.js, Nuxt, SvelteKit), Web Share API, Badging API, File Handling API,
  protocol handling, and Lighthouse PWA audits.
  Triggers: "PWA", "service worker", "offline-first", "web app manifest", "Workbox",
  "push notification", "cache strategy", "installable web app", "app shell", "background sync".
  NOT for native mobile apps (React Native, Flutter, Swift, Kotlin), NOT for Electron desktop apps,
  NOT for browser extensions (Chrome extensions, Firefox add-ons), NOT for server-side caching
  (Redis, Memcached, CDN config).
---

# PWA Patterns Skill

## Web App Manifest

Generate `manifest.json` at the site root. Link it in HTML `<head>`:

```html
<link rel="manifest" href="/manifest.json">
```

### Required Fields

```json
{
  "name": "My App", "short_name": "App", "start_url": "/",
  "display": "standalone", "background_color": "#ffffff", "theme_color": "#1a73e8",
  "icons": [
    { "src": "/icons/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/icons/icon-512.png", "sizes": "512x512", "type": "image/png" },
    { "src": "/icons/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
```

### Display Modes

Use `display_override` for progressive fallback: `["window-controls-overlay", "standalone", "minimal-ui"]`.
Modes: `fullscreen` (games), `standalone` (default app-like), `minimal-ui` (back/reload), `window-controls-overlay` (custom title bar).
Detect in CSS: `@media (display-mode: standalone) { ... }`

### Shortcuts

Limit to 3-4, URLs must be within manifest `scope`:

```json
"shortcuts": [
  { "name": "New Message", "short_name": "New", "url": "/compose",
    "icons": [{ "src": "/icons/compose.png", "sizes": "192x192" }] }
]
```

### Share Target

```json
"share_target": {
  "action": "/share-handler", "method": "POST", "enctype": "multipart/form-data",
  "params": { "title": "name", "text": "description", "url": "link",
    "files": [{ "name": "media", "accept": ["image/*", "video/*"] }] }
}
```

Handle the POST in service worker or server route. Validate all params — any may be absent.

### File Handlers and Protocol Handlers

```json
"file_handlers": [
  { "action": "/open-file", "accept": { "text/csv": [".csv"] } }
],
"protocol_handlers": [
  { "protocol": "web+myapp", "url": "/handle?url=%s" }
]
```

## Service Worker Lifecycle

### Registration

```js
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js', { scope: '/' });
  });
}
```

### Lifecycle Events

```js
// sw.js
const CACHE_NAME = 'app-v1';
const PRECACHE_URLS = ['/', '/styles.css', '/app.js', '/offline.html'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(PRECACHE_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(
        names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))
      )
    ).then(() => self.clients.claim())
  );
});
```

Always call `skipWaiting()` + `clients.claim()` for immediate control. Delete stale caches on activate.

## Caching Strategies

### Cache-First (Static Assets)

```js
self.addEventListener('fetch', (event) => {
  if (event.request.destination === 'style' || event.request.destination === 'script') {
    event.respondWith(
      caches.match(event.request).then((cached) => cached || fetch(event.request))
    );
  }
});
```

### Network-First (Dynamic Content)

```js
event.respondWith(
  fetch(event.request)
    .then((response) => {
      const clone = response.clone();
      caches.open('dynamic-v1').then((cache) => cache.put(event.request, clone));
      return response;
    })
    .catch(() => caches.match(event.request))
);
```

### Stale-While-Revalidate

```js
event.respondWith(
  caches.match(event.request).then((cached) => {
    const fetchPromise = fetch(event.request).then((response) => {
      caches.open('swr-v1').then((cache) => cache.put(event.request, response.clone()));
      return response;
    });
    return cached || fetchPromise;
  })
);
```

### Strategy Selection Guide

| Strategy | Assets | Freshness | Offline |
|----------|--------|-----------|---------|
| Cache-first | CSS, JS, fonts, images | Low | Excellent |
| Network-first | HTML, API responses | High | Good |
| Stale-while-revalidate | Avatars, non-critical data | Medium | Good |
| Cache-only | Precached app shell | None | Excellent |
| Network-only | Analytics, payments | Realtime | None |

## Workbox

Use Workbox for production service workers. Install: `npm install workbox-cli --save-dev`.

### Workbox Configuration

```js
// sw.js (using workbox modules)
import { precacheAndRoute } from 'workbox-precaching';
import { registerRoute } from 'workbox-routing';
import { CacheFirst, NetworkFirst, StaleWhileRevalidate } from 'workbox-strategies';
import { ExpirationPlugin } from 'workbox-expiration';
import { CacheableResponsePlugin } from 'workbox-cacheable-response';

precacheAndRoute(self.__WB_MANIFEST);

registerRoute(
  ({ request }) => request.destination === 'image',
  new CacheFirst({
    cacheName: 'images',
    plugins: [
      new ExpirationPlugin({ maxEntries: 60, maxAgeSeconds: 30 * 24 * 60 * 60 }),
      new CacheableResponsePlugin({ statuses: [0, 200] }),
    ],
  })
);

registerRoute(
  ({ request }) => request.mode === 'navigate',
  new NetworkFirst({
    cacheName: 'pages',
    plugins: [new ExpirationPlugin({ maxEntries: 50 })],
  })
);

registerRoute(
  ({ url }) => url.pathname.startsWith('/api/'),
  new StaleWhileRevalidate({ cacheName: 'api-cache' })
);
```

### Workbox Build (workbox-config.js)

```js
module.exports = {
  globDirectory: 'dist/',
  globPatterns: ['**/*.{html,js,css,png,svg,woff2}'],
  swDest: 'dist/sw.js',
  swSrc: 'src/sw.js',
};
```

Run: `workbox injectManifest workbox-config.js`.

## Push Notifications

### VAPID Key Generation

```bash
npx web-push generate-vapid-keys
```

### Client Subscription

```js
async function subscribeToPush() {
  const registration = await navigator.serviceWorker.ready;
  const subscription = await registration.pushManager.subscribe({
    userVisuallyIndicatesPermission: true,
    applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
  });
  await fetch('/api/push/subscribe', {
    method: 'POST',
    body: JSON.stringify(subscription),
    headers: { 'Content-Type': 'application/json' },
  });
}

function urlBase64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - base64String.length % 4) % 4);
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
}
```

### Push Handler (Service Worker)

```js
self.addEventListener('push', (event) => {
  const data = event.data?.json() ?? { title: 'Notification', body: '' };
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body, icon: '/icons/icon-192.png', badge: '/icons/badge-72.png',
      data: { url: data.url || '/' },
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data.url));
});
```

### Server Push (Node.js)

```js
const webpush = require('web-push');
webpush.setVapidDetails('mailto:admin@example.com', VAPID_PUBLIC, VAPID_PRIVATE);
await webpush.sendNotification(subscription, JSON.stringify({ title: 'Update', body: 'New content' }));
```

Always request notification permission contextually with clear value proposition. Never on page load.

## Background Sync

```js
// Client: queue sync when offline
async function sendData(data) {
  try { await fetch('/api/data', { method: 'POST', body: JSON.stringify(data) }); }
  catch {
    await saveToIndexedDB('outbox', data);
    const reg = await navigator.serviceWorker.ready;
    await reg.sync.register('outbox-sync');
  }
}

// Service worker: replay queue
self.addEventListener('sync', (event) => {
  if (event.tag === 'outbox-sync') event.waitUntil(replayOutbox());
});

async function replayOutbox() {
  const items = await getAllFromIndexedDB('outbox');
  for (const item of items) {
    await fetch('/api/data', { method: 'POST', body: JSON.stringify(item) });
    await deleteFromIndexedDB('outbox', item.id);
  }
}
```

## Periodic Background Sync

```js
const reg = await navigator.serviceWorker.ready;
if ('periodicSync' in reg) {
  await reg.periodicSync.register('content-refresh', { minInterval: 12 * 60 * 60 * 1000 });
}
// In service worker
self.addEventListener('periodicsync', (event) => {
  if (event.tag === 'content-refresh') event.waitUntil(fetchAndCacheLatestContent());
});
```

Chromium-only. Always provide fallback for unsupported browsers.

## IndexedDB Offline Storage

Use `idb` library for promise-based IndexedDB:

```js
import { openDB } from 'idb';
const db = await openDB('my-app', 1, {
  upgrade(db) {
    const store = db.createObjectStore('posts', { keyPath: 'id', autoIncrement: true });
    store.createIndex('timestamp', 'timestamp');
  },
});
await db.put('posts', { title: 'Draft', body: 'Content', timestamp: Date.now() });
const allPosts = await db.getAll('posts');
```

Combine with Background Sync: write to IndexedDB offline, replay to server on reconnect.

## App Shell Architecture

Precache the shell (HTML skeleton, nav, CSS, core JS). Load dynamic content via fetch/IndexedDB.

```js
// Network-first for navigation with offline fallback
registerRoute(
  ({ request }) => request.mode === 'navigate',
  new NetworkFirst({
    cacheName: 'shell',
    plugins: [new ExpirationPlugin({ maxEntries: 20 })],
    networkTimeoutSeconds: 3,
  })
);

// Offline fallback
import { setCatchHandler } from 'workbox-routing';
setCatchHandler(({ event }) => {
  if (event.request.mode === 'navigate') return caches.match('/offline.html');
  return Response.error();
});
```

## Installability Criteria

`beforeinstallprompt` fires when: HTTPS, valid manifest (`name`, `start_url`, `display` standalone/fullscreen/minimal-ui, icons 192px+512px), registered service worker with fetch handler, `prefer_related_applications` NOT `true`.

### Install Prompt

```js
let deferredPrompt;
window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); deferredPrompt = e; showInstallButton(); });
installButton.addEventListener('click', async () => { deferredPrompt.prompt(); await deferredPrompt.userChoice; deferredPrompt = null; });
```

## Platform APIs

### Web Share API

```js
if (navigator.canShare?.(data)) await navigator.share({ title: data.title, text: data.text, url: data.url });
```

### Badging API

```js
navigator.setAppBadge(unreadCount); // Chromium-only, installed PWAs only
navigator.clearAppBadge();
```

## PWA in Frameworks

### Next.js

Use `next-pwa` or `@ducanh2912/next-pwa`. In `next.config.js`:

```js
const withPWA = require('next-pwa')({ dest: 'public', disable: process.env.NODE_ENV === 'development' });
module.exports = withPWA({ /* next config */ });
```

Place `manifest.json` in `public/`. Add to `app/layout.tsx`:

```tsx
export const metadata = { manifest: '/manifest.json' };
```

### Nuxt 3

Install `@vite-pwa/nuxt`. In `nuxt.config.ts`:

```ts
export default defineNuxtConfig({
  modules: ['@vite-pwa/nuxt'],
  pwa: {
    manifest: { name: 'My App', short_name: 'App', theme_color: '#1a73e8' },
    workbox: { navigateFallback: '/' },
  },
});
```

### SvelteKit

Place `manifest.json` in `static/`. Create `src/service-worker.js` (SvelteKit auto-registers it):

```js
import { build, files, version } from '$service-worker';

const CACHE = `cache-${version}`;
const ASSETS = [...build, ...files];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)));
});
```

## Testing and Auditing

Run Lighthouse: `npx lighthouse https://example.com --only-categories=pwa --output=json`

### DevTools Checklist

1. Application > Manifest: validate fields, check installability
2. Application > Service Workers: verify registration, test update, force offline
3. Application > Cache Storage: inspect cached assets
4. Network tab: throttle Offline, verify app shell renders
5. Console: check SW errors, push permission state

## Examples

### Example 1: Add PWA support to existing React app

**Input:** "Make my React app installable with offline support"

**Output:** Generate these files:
- `public/manifest.json` with name, icons, display, start_url, theme_color
- `src/sw.js` with Workbox precaching for build output and network-first for navigation
- `src/index.js` registration: `navigator.serviceWorker.register('/sw.js')`
- `workbox-config.js` with injectManifest targeting dist output

### Example 2: Implement offline-first data sync

**Input:** "Users need to create records offline and sync when back online"

**Output:** Implement:
- IndexedDB store via `idb` for pending records
- Background Sync registration on save failure
- Service worker `sync` event handler replaying IndexedDB queue to API
- Conflict resolution: server timestamp comparison, last-write-wins or merge prompt
- UI indicator showing sync status (pending/syncing/synced)

### Example 3: Add push notifications to Next.js PWA

**Input:** "Set up web push notifications for my Next.js app"

**Output:** Implement:
- Generate VAPID keys, store in `.env` (NEXT_PUBLIC_VAPID_PUBLIC, VAPID_PRIVATE)
- API route `POST /api/push/subscribe` storing subscriptions in DB
- API route `POST /api/push/send` using `web-push` library
- Client hook `usePushSubscription` handling permission request + subscription
- Service worker `push` and `notificationclick` handlers
- Permission request triggered by user action, never on page load
