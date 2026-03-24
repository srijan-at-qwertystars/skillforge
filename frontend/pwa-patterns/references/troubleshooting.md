# PWA Troubleshooting Guide

## Table of Contents

- [Service Worker Not Updating](#service-worker-not-updating)
- [Cache Invalidation Problems](#cache-invalidation-problems)
- [iOS Safari Limitations](#ios-safari-limitations)
- [Cross-Origin Requests in Service Workers](#cross-origin-requests-in-service-workers)
- [CORS and Opaque Responses](#cors-and-opaque-responses)
- [Debugging Service Workers in DevTools](#debugging-service-workers-in-devtools)
- [Manifest Not Detected](#manifest-not-detected)
- [Install Prompt Timing](#install-prompt-timing)

---

## Service Worker Not Updating

### Symptoms

- Users stuck on old version of app
- Code changes not reflected after deploy
- SW `install` event doesn't fire

### Root Causes & Fixes

**1. Browser byte-comparison check not triggered**

The browser checks for SW updates only when: navigating to an in-scope page, a push/sync event fires, or `registration.update()` is called. If `sw.js` is HTTP-cached, the browser won't even fetch it.

```
# Serve sw.js with no-cache headers (nginx)
location /sw.js {
  add_header Cache-Control "no-cache, no-store, must-revalidate";
  add_header Pragma "no-cache";
}
```

**2. Waiting SW not activated**

A new SW installs but waits until all tabs using the old SW close.

```js
// Option A: Force immediate activation (use cautiously)
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', () => self.clients.claim());

// Option B: Prompt user (safer)
// See advanced-patterns.md → Service Worker Update UX
```

**3. Build tool not changing SW content**

If your build injects a version/hash into SW, ensure it actually changes between deploys:

```js
// workbox-config.js — injectManifest updates __WB_MANIFEST automatically
// Manual SW: include a version constant
const SW_VERSION = '2.1.0'; // Change on each deploy
```

**4. importScripts cached**

If your SW uses `importScripts()`, those scripts are also byte-checked. Ensure they're versioned or served with `no-cache`.

### Debug Checklist

```
1. DevTools → Application → Service Workers → check "Update on reload"
2. Verify sw.js response headers: Cache-Control should be no-cache
3. Check if a waiting worker exists: registration.waiting !== null
4. Force update: registration.update() in console
5. Nuclear option: DevTools → Application → Unregister SW → hard refresh
```

---

## Cache Invalidation Problems

### Stale Assets Served

```js
// Problem: Old CSS/JS served from cache after deploy
// Fix: Use content-hashed filenames
// main.js → main.a1b2c3.js (webpack/vite do this by default)

// In SW: version your cache and clean old ones
const CACHE_VERSION = 'v3';
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k)))
    )
  );
});
```

### Cache Storage Full

Mobile browsers enforce storage quotas. Safari is especially aggressive (~50MB eviction threshold per origin).

```js
// Check available quota
const { usage, quota } = await navigator.storage.estimate();
console.log(`Using ${(usage / 1e6).toFixed(1)}MB of ${(quota / 1e6).toFixed(1)}MB`);

// Request persistent storage (prevents eviction)
if (navigator.storage?.persist) {
  const granted = await navigator.storage.persist();
  console.log(`Persistent storage: ${granted}`);
}
```

### Precache Manifest Out of Sync

If using Workbox `injectManifest`, forgetting to rebuild causes the manifest to reference old files:

```bash
# Always run before deploy
workbox injectManifest workbox-config.js
# Or integrate into build: "build": "vite build && workbox injectManifest"
```

---

## iOS Safari Limitations

### What Doesn't Work (as of iOS 17/18)

| Feature | Status | Workaround |
|---------|--------|------------|
| Push notifications | ✅ Since iOS 16.4 | Requires user to install PWA to home screen first |
| `beforeinstallprompt` | ❌ Not supported | Show manual A2HS instructions |
| Background Sync | ❌ Not supported | Retry on app foreground |
| Periodic Background Sync | ❌ Not supported | Refresh on page visibility change |
| Background Fetch | ❌ Not supported | Standard fetch with progress |
| Badging API | ❌ Not supported | Push notification badges only |
| Content Indexing | ❌ Not supported | No workaround |
| `display: window-controls-overlay` | ❌ Not supported | Falls back to `standalone` |
| Persistent storage | ⚠️ Unreliable | Data may be evicted after 7 days of inactivity |
| Web Share Target | ❌ Not supported | Web Share API (outbound) works |

### Storage Eviction

Safari evicts all website data (caches, IndexedDB, SW registration) after **7 days without user interaction** in non-installed mode. For installed PWAs, data persists longer but can still be evicted under storage pressure.

```js
// Defensive coding: always handle missing cache/DB data
async function getData(key) {
  try {
    const cached = await db.get('store', key);
    if (cached) return cached;
  } catch {
    // IndexedDB may have been wiped — reinitialize
    await initDB();
  }
  return fetchFromNetwork(key);
}
```

### Push Notifications on iOS

Requires: HTTPS, installed to home screen (not browser tab), user grant via Notification.requestPermission(). The permission prompt only appears when triggered by user gesture.

```js
// Feature detection for iOS push
function canUsePush() {
  return 'PushManager' in window
    && 'Notification' in window
    && navigator.serviceWorker;
}

// Guide user to install first
function showIOSInstallGuide() {
  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
  const isStandalone = window.matchMedia('(display-mode: standalone)').matches;
  if (isIOS && !isStandalone) {
    showBanner('Install this app to enable notifications: tap Share → Add to Home Screen');
  }
}
```

### Scope and Navigation

iOS doesn't handle out-of-scope navigation well. External links open in the PWA window without browser controls.

```js
// Force external links to open in Safari
document.addEventListener('click', (e) => {
  const anchor = e.target.closest('a[href]');
  if (anchor && new URL(anchor.href).origin !== location.origin) {
    e.preventDefault();
    window.open(anchor.href, '_blank');
  }
});
```

---

## Cross-Origin Requests in Service Workers

### The Problem

SWs can intercept cross-origin requests but face restrictions:

```js
self.addEventListener('fetch', (event) => {
  // This is a cross-origin request
  if (new URL(event.request.url).origin !== self.location.origin) {
    // Cannot read response body if no CORS headers
    // Response type will be "opaque"
  }
});
```

### Solutions

**1. Use CORS mode for cross-origin fetches**

```js
// Client-side: request with CORS
fetch('https://api.example.com/data', { mode: 'cors' });
// Server must respond with: Access-Control-Allow-Origin: *
```

**2. Cache cross-origin with CacheableResponsePlugin**

```js
import { CacheableResponsePlugin } from 'workbox-cacheable-response';

registerRoute(
  ({ url }) => url.origin === 'https://cdn.example.com',
  new CacheFirst({
    cacheName: 'cdn-assets',
    plugins: [
      // Status 0 = opaque response — cache it anyway for CDN assets
      new CacheableResponsePlugin({ statuses: [0, 200] }),
    ],
  })
);
```

**3. Skip non-CORS requests entirely**

```js
self.addEventListener('fetch', (event) => {
  if (event.request.url.startsWith(self.location.origin)) {
    event.respondWith(/* your caching logic */);
  }
  // Let cross-origin requests pass through
});
```

---

## CORS and Opaque Responses

### What Is an Opaque Response?

When you `fetch()` a cross-origin resource in `no-cors` mode, you get an opaque response (`response.type === 'opaque'`). You **cannot**:
- Read `response.status` (always 0)
- Read `response.body`
- Read `response.headers`

### The Cache Padding Problem

Each opaque response uses **~7MB of cache quota** (padded for security). Caching many opaque responses rapidly exhausts storage.

```js
// BAD: Caching all opaque responses
cache.put(request, opaqueResponse); // 7MB each!

// GOOD: Only cache CORS responses
if (response.type === 'cors' || response.type === 'basic') {
  cache.put(request, response.clone());
}
```

### Fix: Add CORS Headers

```
# CDN/Server config
Access-Control-Allow-Origin: https://yourdomain.com
Access-Control-Allow-Methods: GET
```

```html
<!-- HTML: Use crossorigin attribute -->
<img src="https://cdn.example.com/photo.jpg" crossorigin="anonymous">
<link rel="stylesheet" href="https://fonts.googleapis.com/css" crossorigin>
```

---

## Debugging Service Workers in DevTools

### Chrome DevTools

```
Application tab:
├── Manifest — validate all fields, installability warnings
├── Service Workers — status, update, skipWaiting, unregister
│   ├── ☑ "Update on reload" — forces new SW on every load (dev only)
│   ├── ☑ "Bypass for network" — SW doesn't intercept (debugging)
│   └── Offline checkbox — simulate offline mode
├── Cache Storage — inspect cached URLs and responses
├── IndexedDB — browse offline data stores
└── Storage — clear site data, view quota
```

### SW-Specific Debugging

```
chrome://inspect/#service-workers     — all registered SWs across origins
chrome://serviceworker-internals/     — detailed SW internals, force-stop
```

### Debug Fetch Events

```js
// Add to sw.js during development
self.addEventListener('fetch', (event) => {
  console.log(`[SW] ${event.request.method} ${event.request.url}`);
  console.log(`  Mode: ${event.request.mode}, Destination: ${event.request.destination}`);
});
```

### Safari/iOS Debugging

1. Connect iOS device via USB to Mac
2. Safari → Develop → [Device] → [Page]
3. Service Workers appear under the page listing
4. Console and Network tabs work, but Cache Storage inspection is limited
5. Use `Web Inspector` on the SW context to set breakpoints

### Firefox Debugging

```
about:debugging#/runtime/this-firefox → Service Workers section
— Inspect individual SWs
— Push and debug events manually
```

---

## Manifest Not Detected

### Diagnostic Checklist

```
1. ✅ <link rel="manifest" href="/manifest.json"> in <head>
2. ✅ Correct MIME type: application/manifest+json (or application/json)
3. ✅ Manifest returns HTTP 200 (not redirect or error)
4. ✅ Valid JSON (no trailing commas, no comments)
5. ✅ Required fields present: name, start_url, display, icons
6. ✅ At least one icon ≥192px and one ≥512px
7. ✅ start_url is within scope
8. ✅ No CORS errors if manifest is cross-origin (rare)
```

### Common Mistakes

```json
// ❌ Wrong: icon src is relative but doesn't resolve correctly
{ "src": "icons/icon-192.png" }
// ✅ Correct: use absolute paths
{ "src": "/icons/icon-192.png" }

// ❌ Wrong: missing display mode
{ "name": "App", "start_url": "/" }
// ✅ Correct: include display
{ "name": "App", "start_url": "/", "display": "standalone" }

// ❌ Wrong: start_url outside scope
{ "scope": "/app/", "start_url": "/" }
// ✅ Correct: start_url within scope
{ "scope": "/app/", "start_url": "/app/" }
```

### MIME Type Fix

```nginx
# nginx
location /manifest.json {
  types { application/manifest+json json; }
}
```

```apache
# Apache .htaccess
AddType application/manifest+json .json .webmanifest
```

---

## Install Prompt Timing

### Why `beforeinstallprompt` Doesn't Fire

1. **Not on HTTPS** (localhost is exempt for dev)
2. **Missing or invalid manifest** (see section above)
3. **No registered SW with fetch handler**
4. **User already installed the app** — event won't fire again
5. **User dismissed prompt recently** — browser enforces cooldown (~90 days Chrome)
6. **`prefer_related_applications: true`** in manifest — suppresses web install
7. **iOS/Firefox** — these browsers never fire `beforeinstallprompt`

### Engagement Heuristics (Chrome)

Chrome requires "sufficient engagement" — roughly 30 seconds of interaction. The exact formula is opaque and changes.

### Best Practices

```js
let deferredPrompt = null;

window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredPrompt = e;
  // Don't show immediately — wait for natural moment
  // E.g., after completing a task, after 3rd visit, after a save action
});

// Trigger at contextually appropriate time
function offerInstall() {
  if (!deferredPrompt) return;
  deferredPrompt.prompt();
  deferredPrompt.userChoice.then((result) => {
    console.log('Install:', result.outcome); // 'accepted' or 'dismissed'
    deferredPrompt = null;
  });
}

// Track installed state
window.addEventListener('appinstalled', () => {
  console.log('PWA installed');
  hideInstallPromotion();
  // Analytics: track install conversion
});
```

### iOS Install Guidance

```js
function showIOSInstall() {
  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream;
  const isStandalone = window.matchMedia('(display-mode: standalone)').matches
    || navigator.standalone;

  if (isIOS && !isStandalone) {
    // Show custom UI: "Tap the Share button, then 'Add to Home Screen'"
    showInstallGuide({
      steps: ['Tap the Share icon (□↑)', 'Scroll and tap "Add to Home Screen"', 'Tap "Add"'],
    });
  }
}
```
