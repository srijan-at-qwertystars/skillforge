# PWA API Reference

## Table of Contents

- [Cache API](#cache-api)
- [Service Worker Registration](#service-worker-registration)
- [Push API](#push-api)
- [Notification API](#notification-api)
- [Background Sync API](#background-sync-api)
- [IndexedDB Basics](#indexeddb-basics)
- [Web App Manifest Fields](#web-app-manifest-fields)
- [Workbox Modules](#workbox-modules)

---

## Cache API

### `caches` (CacheStorage)

```js
// Open or create a named cache
const cache = await caches.open('my-cache-v1');

// Check if a request matches any cache
const response = await caches.match(request); // searches all caches

// List all cache names
const names = await caches.keys(); // ['my-cache-v1', 'images-v2']

// Delete a cache entirely
const deleted = await caches.delete('old-cache'); // true/false

// Check existence
const exists = await caches.has('my-cache-v1'); // true/false
```

### `Cache` Instance Methods

```js
const cache = await caches.open('v1');

// Add (fetches URL and stores response)
await cache.add('/styles.css');
await cache.addAll(['/', '/app.js', '/styles.css']); // atomic — all or nothing

// Put (store request/response pair directly)
await cache.put(request, response); // response is consumed — clone first if reusing

// Match (retrieve)
const resp = await cache.match(request, {
  ignoreSearch: false,    // ignore query string
  ignoreMethod: false,    // match regardless of HTTP method
  ignoreVary: false,      // ignore Vary header
});

// List all cached requests
const requests = await cache.keys();

// Match all (returns array of responses)
const responses = await cache.matchAll('/api/', { ignoreSearch: true });

// Delete entry
const removed = await cache.delete(request); // true/false
```

### Important Notes

- `cache.add/addAll` only caches successful responses (status 200). Non-OK responses throw.
- `cache.put` stores any response including error responses — validate first.
- Responses are consumed on read. Always `.clone()` before caching if you also return it.
- Cache storage is per-origin, not per-SW. Multiple SWs on same origin share caches.

---

## Service Worker Registration

### `navigator.serviceWorker`

```js
// Register
const registration = await navigator.serviceWorker.register('/sw.js', {
  scope: '/',              // URL scope the SW controls
  type: 'classic',         // 'classic' | 'module' (ES modules in SW)
  updateViaCache: 'none',  // 'imports' | 'all' | 'none'
});

// Get current controller
const sw = navigator.serviceWorker.controller; // null if page not controlled

// Listen for controller changes
navigator.serviceWorker.addEventListener('controllerchange', () => {
  // New SW took control
});

// Message the controller
navigator.serviceWorker.controller.postMessage({ type: 'HELLO' });

// Wait until a SW is active
const reg = await navigator.serviceWorker.ready; // resolves with active registration
```

### `ServiceWorkerRegistration` Properties

```js
registration.active;        // ServiceWorker | null — currently controlling
registration.waiting;       // ServiceWorker | null — installed, waiting to activate
registration.installing;    // ServiceWorker | null — currently installing
registration.scope;         // string — URL scope
registration.updateViaCache; // 'imports' | 'all' | 'none'

// Sub-APIs
registration.pushManager;          // PushManager
registration.sync;                 // SyncManager
registration.periodicSync;         // PeriodicSyncManager
registration.navigationPreload;    // NavigationPreloadManager
registration.backgroundFetch;      // BackgroundFetchManager
registration.index;                // ContentIndex
```

### `ServiceWorkerRegistration` Methods

```js
await registration.update();       // Check for new SW
const success = await registration.unregister(); // Remove registration
await registration.showNotification(title, options); // Show notification
const notifications = await registration.getNotifications({ tag: 'msg' });
```

### `ServiceWorker` (active/waiting/installing)

```js
sw.state;        // 'parsed' | 'installing' | 'installed' | 'activating' | 'activated' | 'redundant'
sw.scriptURL;    // URL of the SW script
sw.postMessage(data); // Send message to the SW

sw.addEventListener('statechange', (e) => {
  console.log('SW state:', e.target.state);
});
```

---

## Push API

### `PushManager` (via `registration.pushManager`)

```js
// Subscribe to push
const subscription = await registration.pushManager.subscribe({
  userVisibleOnly: true,  // required — must show notification for each push
  applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
});

// subscription object shape:
// {
//   endpoint: 'https://fcm.googleapis.com/fcm/send/...',
//   keys: { p256dh: '...', auth: '...' },
//   expirationTime: null
// }
// Send this to your server to store

// Get existing subscription
const sub = await registration.pushManager.getSubscription(); // null if none

// Check permission
const state = await registration.pushManager.permissionState({
  userVisibleOnly: true,
  applicationServerKey: key,
}); // 'granted' | 'denied' | 'prompt'

// Unsubscribe
await subscription.unsubscribe();
```

### Push Event (Service Worker)

```js
self.addEventListener('push', (event) => {
  const data = event.data; // PushMessageData | null

  // Reading push data
  const text = data?.text();         // as string
  const json = data?.json();         // as parsed JSON
  const blob = data?.blob();         // as Blob
  const buffer = data?.arrayBuffer(); // as ArrayBuffer

  event.waitUntil(
    self.registration.showNotification('Title', { body: json?.message })
  );
});
```

### VAPID Key Utility

```js
function urlBase64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  const rawData = atob(base64);
  return Uint8Array.from([...rawData].map((char) => char.charCodeAt(0)));
}
```

---

## Notification API

### `Notification.requestPermission()`

```js
const permission = await Notification.requestPermission();
// 'granted' | 'denied' | 'default'
// MUST be triggered by user gesture
```

### `registration.showNotification(title, options)`

```js
await registration.showNotification('New Message', {
  body: 'You have a new message from Alice',
  icon: '/icons/icon-192.png',          // large icon
  badge: '/icons/badge-72.png',         // small monochrome icon (Android)
  image: '/images/preview.jpg',         // large image in notification body
  tag: 'message-alice',                 // group/replace notifications with same tag
  renotify: true,                       // vibrate again even if same tag
  requireInteraction: false,            // stay visible until dismissed (desktop)
  silent: false,                        // suppress sound/vibration
  vibrate: [200, 100, 200],             // vibration pattern [vibrate, pause, ...]
  timestamp: Date.now(),                // when the event occurred
  dir: 'auto',                          // 'auto' | 'ltr' | 'rtl'
  lang: 'en',
  data: { url: '/messages/alice', id: 42 }, // arbitrary data for click handler
  actions: [                            // max 2 on mobile, 3 on desktop
    { action: 'reply', title: 'Reply', icon: '/icons/reply.png' },
    { action: 'dismiss', title: 'Dismiss' },
  ],
});
```

### Notification Events (Service Worker)

```js
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const action = event.action;      // '' if main body clicked, 'reply'/'dismiss' for actions
  const url = event.notification.data?.url || '/';

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      // Focus existing tab or open new
      const existing = clientList.find((c) => c.url === url);
      if (existing) return existing.focus();
      return clients.openWindow(url);
    })
  );
});

self.addEventListener('notificationclose', (event) => {
  // Track dismissed notifications for analytics
});
```

---

## Background Sync API

### `SyncManager` (via `registration.sync`)

```js
// Register a sync
await registration.sync.register('outbox-sync');

// List pending syncs
const tags = await registration.sync.getTags(); // ['outbox-sync']
```

### Sync Event (Service Worker)

```js
self.addEventListener('sync', (event) => {
  if (event.tag === 'outbox-sync') {
    event.waitUntil(processOutbox());
    // event.lastChance — true if browser will stop retrying after this
  }
});

async function processOutbox() {
  const db = await openDB('app', 1);
  const items = await db.getAll('outbox');
  for (const item of items) {
    await fetch('/api/submit', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(item),
    });
    await db.delete('outbox', item.id);
  }
}
```

### Periodic Sync

```js
// Register
await registration.periodicSync.register('content-sync', {
  minInterval: 24 * 60 * 60 * 1000, // 24 hours
});

// Unregister
await registration.periodicSync.unregister('content-sync');

// List tags
const tags = await registration.periodicSync.getTags();

// Handler (SW)
self.addEventListener('periodicsync', (event) => {
  if (event.tag === 'content-sync') {
    event.waitUntil(refreshContent());
  }
});
```

---

## IndexedDB Basics

Using the `idb` library (promise wrapper):

```bash
npm install idb
```

### Open/Upgrade

```js
import { openDB } from 'idb';

const db = await openDB('my-app', 2, {
  upgrade(db, oldVersion, newVersion, transaction) {
    if (oldVersion < 1) {
      const store = db.createObjectStore('posts', { keyPath: 'id', autoIncrement: true });
      store.createIndex('by-date', 'createdAt');
      store.createIndex('by-category', 'category');
    }
    if (oldVersion < 2) {
      db.createObjectStore('settings', { keyPath: 'key' });
    }
  },
  blocked() { console.warn('DB upgrade blocked by other tab'); },
  blocking() { db.close(); }, // close so other tab can upgrade
  terminated() { console.error('DB unexpectedly terminated'); },
});
```

### CRUD

```js
// Create / Update
await db.put('posts', { id: 1, title: 'Hello', createdAt: Date.now(), category: 'news' });
await db.add('posts', { title: 'Auto ID', createdAt: Date.now() }); // auto-increment

// Read
const post = await db.get('posts', 1);
const all = await db.getAll('posts');
const count = await db.count('posts');

// Read by index
const byDate = await db.getAllFromIndex('posts', 'by-date');
const newsOnly = await db.getAllFromIndex('posts', 'by-category', 'news');

// Delete
await db.delete('posts', 1);
await db.clear('posts'); // delete all entries

// Transactions (multiple operations)
const tx = db.transaction('posts', 'readwrite');
await Promise.all([
  tx.store.put({ id: 1, title: 'Updated' }),
  tx.store.delete(2),
  tx.done,
]);
```

### Key Ranges

```js
import { IDBKeyRange } from 'idb';
// Useful for paginated queries or date ranges
const range = IDBKeyRange.bound(startDate, endDate);
const results = await db.getAllFromIndex('posts', 'by-date', range);
```

---

## Web App Manifest Fields

### Required for Installability

```json
{
  "name": "My Application",
  "short_name": "MyApp",
  "start_url": "/",
  "display": "standalone",
  "icons": [
    { "src": "/icons/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/icons/icon-512.png", "sizes": "512x512", "type": "image/png" }
  ]
}
```

### All Standard Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Full app name (install dialog, splash) |
| `short_name` | string | Abbreviated name (home screen) |
| `start_url` | string | URL opened when app launches |
| `id` | string | Unique app identity (for updates) |
| `display` | string | `fullscreen` \| `standalone` \| `minimal-ui` \| `browser` |
| `display_override` | string[] | Ordered fallback: `["window-controls-overlay","standalone"]` |
| `orientation` | string | `any` \| `natural` \| `portrait` \| `landscape` (and `-primary`/`-secondary`) |
| `scope` | string | URL scope for navigation containment |
| `lang` | string | Primary language (BCP47: `"en-US"`) |
| `dir` | string | Text direction: `ltr` \| `rtl` \| `auto` |
| `theme_color` | string | Browser chrome / status bar color |
| `background_color` | string | Splash screen background |
| `description` | string | App description |
| `categories` | string[] | `["productivity","utilities"]` — hint for stores |
| `icons` | object[] | `{src, sizes, type, purpose}` — purpose: `any` \| `maskable` \| `monochrome` |
| `screenshots` | object[] | `{src, sizes, type, form_factor, label}` — form_factor: `wide` \| `narrow` |
| `shortcuts` | object[] | `{name, short_name, url, description, icons}` — max 4 recommended |
| `share_target` | object | `{action, method, enctype, params:{title,text,url,files}}` |
| `protocol_handlers` | object[] | `{protocol, url}` — `"web+myapp"` scheme |
| `file_handlers` | object[] | `{action, accept}` — open files of specific types |
| `launch_handler` | object | `{client_mode}`: `auto` \| `navigate-new` \| `navigate-existing` \| `focus-existing` |
| `related_applications` | object[] | `{platform, url, id}` — native app alternatives |
| `prefer_related_applications` | boolean | If `true`, browser promotes native app instead |
| `edge_side_panel` | object | `{preferred_width}` — Edge sidebar PWA |
| `handle_links` | string | `auto` \| `preferred` \| `not-preferred` |
| `scope_extensions` | object[] | `{origin}` — extend scope to other origins |

---

## Workbox Modules

### workbox-precaching

```js
import { precacheAndRoute, cleanupOutdatedCaches, createHandlerBoundToURL } from 'workbox-precaching';

// Precache and route the build manifest (injected by build tool)
precacheAndRoute(self.__WB_MANIFEST);

// Clean up caches from previous precache versions
cleanupOutdatedCaches();

// Create a handler for navigation requests to a specific URL (app shell)
const handler = createHandlerBoundToURL('/index.html');
```

Manifest entry format: `{ url: '/app.js', revision: 'abc123' }` or just `'/app.js'` (no revisioning).

### workbox-routing

```js
import { registerRoute, setCatchHandler, setDefaultHandler, NavigationRoute, Route } from 'workbox-routing';

// Match by callback
registerRoute(
  ({ request, url, event, sameOrigin }) => request.destination === 'image',
  handler
);

// Match by regex
registerRoute(/\/api\/.*\.json$/, handler);

// Navigation route (HTML pages)
registerRoute(new NavigationRoute(handler, {
  allowlist: [/^\/app/],
  denylist: [/^\/api/, /^\/admin/],
}));

// Default handler for unmatched requests
setDefaultHandler(new NetworkFirst());

// Catch handler for failures
setCatchHandler(async ({ event }) => {
  if (event.request.destination === 'document') {
    return caches.match('/offline.html');
  }
  return Response.error();
});
```

### workbox-strategies

```js
import { CacheFirst, NetworkFirst, StaleWhileRevalidate, NetworkOnly, CacheOnly, Strategy } from 'workbox-strategies';

// All strategies accept:
new CacheFirst({
  cacheName: 'my-cache',                    // custom cache name
  plugins: [/* array of plugins */],
  fetchOptions: { credentials: 'include' },  // passed to fetch()
  matchOptions: { ignoreSearch: true },       // passed to cache.match()
});

// NetworkFirst-specific:
new NetworkFirst({
  networkTimeoutSeconds: 3,  // fall back to cache after 3s
  cacheName: 'pages',
  plugins: [],
});
```

| Strategy | Network | Cache | Best For |
|----------|---------|-------|----------|
| `CacheFirst` | Fallback | Primary | Static assets, fonts, images |
| `NetworkFirst` | Primary | Fallback | HTML pages, API data needing freshness |
| `StaleWhileRevalidate` | Background update | Immediate | Semi-dynamic content |
| `NetworkOnly` | Only | Never | Analytics, real-time data |
| `CacheOnly` | Never | Only | Precached app shell |

### workbox-expiration

```js
import { ExpirationPlugin } from 'workbox-expiration';

new CacheFirst({
  cacheName: 'images',
  plugins: [
    new ExpirationPlugin({
      maxEntries: 100,                    // max items in cache
      maxAgeSeconds: 30 * 24 * 60 * 60,  // 30 days
      purgeOnQuotaError: true,            // delete this cache if storage quota exceeded
    }),
  ],
});
```

### workbox-cacheable-response

```js
import { CacheableResponsePlugin } from 'workbox-cacheable-response';

new StaleWhileRevalidate({
  plugins: [
    new CacheableResponsePlugin({
      statuses: [0, 200],   // 0 = opaque cross-origin responses
      headers: { 'X-Is-Cacheable': 'true' }, // optional header check
    }),
  ],
});
```

### workbox-background-sync

```js
import { BackgroundSyncPlugin, Queue } from 'workbox-background-sync';

// As a plugin (simple)
registerRoute(
  /\/api\/submit/,
  new NetworkOnly({
    plugins: [
      new BackgroundSyncPlugin('submit-queue', {
        maxRetentionTime: 24 * 60,  // minutes (24 hours)
        onSync: async ({ queue }) => {
          // Custom replay logic (optional)
          let entry;
          while ((entry = await queue.shiftRequest())) {
            await fetch(entry.request.clone());
          }
        },
      }),
    ],
  }),
  'POST'
);

// As standalone queue (advanced)
const queue = new Queue('my-queue', {
  maxRetentionTime: 60,
  onSync: async ({ queue }) => { /* custom replay */ },
});

self.addEventListener('fetch', (event) => {
  if (event.request.url.endsWith('/api/data') && event.request.method === 'POST') {
    const bgSyncLogic = async () => {
      try {
        return await fetch(event.request.clone());
      } catch {
        await queue.pushRequest({ request: event.request });
        return new Response(JSON.stringify({ queued: true }), {
          headers: { 'Content-Type': 'application/json' },
        });
      }
    };
    event.respondWith(bgSyncLogic());
  }
});
```

### workbox-window (Client-Side)

```js
import { Workbox } from 'workbox-window';

const wb = new Workbox('/sw.js');

wb.addEventListener('installed', (event) => {
  if (!event.isUpdate) console.log('First install');
});
wb.addEventListener('waiting', (event) => {
  // New SW waiting — prompt user
});
wb.addEventListener('activated', (event) => {
  // New SW activated
});
wb.addEventListener('controlling', (event) => {
  // This page now controlled by new SW
});

wb.register();
wb.messageSW({ type: 'GET_VERSION' }); // send message to SW
wb.messageSkipWaiting();               // tell waiting SW to skipWaiting
```

### workbox-recipes (Shortcuts)

```js
import { pageCache, imageCache, staticResourceCache, googleFontsCache, warmStrategyCache, offlineFallback } from 'workbox-recipes';

pageCache();                           // NetworkFirst for navigations
staticResourceCache();                 // StaleWhileRevalidate for JS/CSS
imageCache({ maxEntries: 60 });        // CacheFirst for images
googleFontsCache();                    // Cache Google Fonts
offlineFallback({                      // Serve fallback pages
  pageFallback: '/offline.html',
  imageFallback: '/images/offline.svg',
  fontFallback: false,
});

// Pre-warm cache with specific URLs
warmStrategyCache({
  urls: ['/api/config', '/api/user'],
  strategy: new StaleWhileRevalidate({ cacheName: 'api' }),
});
```
