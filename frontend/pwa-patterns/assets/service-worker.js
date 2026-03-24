/**
 * Production Service Worker with Workbox
 *
 * Features: precaching, runtime caching strategies, offline fallback,
 * navigation preload, push notifications, background sync.
 *
 * Build: workbox injectManifest workbox-config.js
 * This file is the swSrc — __WB_MANIFEST is replaced at build time.
 */

import { precacheAndRoute, cleanupOutdatedCaches, createHandlerBoundToURL } from 'workbox-precaching';
import { registerRoute, NavigationRoute, setCatchHandler } from 'workbox-routing';
import { CacheFirst, NetworkFirst, StaleWhileRevalidate } from 'workbox-strategies';
import { ExpirationPlugin } from 'workbox-expiration';
import { CacheableResponsePlugin } from 'workbox-cacheable-response';
import { BackgroundSyncPlugin } from 'workbox-background-sync';
import { clientsClaim } from 'workbox-core';

// ─── Core Setup ──────────────────────────────────────────────

// Take control immediately
self.skipWaiting();
clientsClaim();

// Precache build assets (injected by workbox-cli or webpack plugin)
precacheAndRoute(self.__WB_MANIFEST);
cleanupOutdatedCaches();

// ─── Navigation Preload ──────────────────────────────────────

// Speed up navigation requests by starting network fetch during SW boot
if (self.registration.navigationPreload) {
  self.addEventListener('activate', (event) => {
    event.waitUntil(self.registration.navigationPreload.enable());
  });
}

// ─── Navigation (HTML Pages) ─────────────────────────────────

// Network-first for page navigations with 3s timeout
const pageHandler = new NetworkFirst({
  cacheName: 'pages',
  networkTimeoutSeconds: 3,
  plugins: [
    new ExpirationPlugin({ maxEntries: 50 }),
    new CacheableResponsePlugin({ statuses: [0, 200] }),
  ],
});

registerRoute(new NavigationRoute(pageHandler, {
  // Exclude API and static asset paths from navigation handling
  denylist: [/^\/api\//, /^\/admin\//],
}));

// ─── Static Assets (JS, CSS) ────────────────────────────────

registerRoute(
  ({ request }) => request.destination === 'script' || request.destination === 'style',
  new StaleWhileRevalidate({
    cacheName: 'static-assets',
    plugins: [
      new ExpirationPlugin({ maxEntries: 60, maxAgeSeconds: 30 * 24 * 60 * 60 }),
    ],
  })
);

// ─── Images ──────────────────────────────────────────────────

registerRoute(
  ({ request }) => request.destination === 'image',
  new CacheFirst({
    cacheName: 'images',
    plugins: [
      new ExpirationPlugin({ maxEntries: 100, maxAgeSeconds: 60 * 24 * 60 * 60 }),
      new CacheableResponsePlugin({ statuses: [0, 200] }),
    ],
  })
);

// ─── Fonts ───────────────────────────────────────────────────

registerRoute(
  ({ request }) => request.destination === 'font',
  new CacheFirst({
    cacheName: 'fonts',
    plugins: [
      new ExpirationPlugin({ maxEntries: 20, maxAgeSeconds: 365 * 24 * 60 * 60 }),
      new CacheableResponsePlugin({ statuses: [0, 200] }),
    ],
  })
);

// ─── API Responses ───────────────────────────────────────────

registerRoute(
  ({ url }) => url.pathname.startsWith('/api/') && url.pathname !== '/api/submit',
  new StaleWhileRevalidate({
    cacheName: 'api-cache',
    plugins: [
      new ExpirationPlugin({ maxEntries: 50, maxAgeSeconds: 5 * 60 }),
      new CacheableResponsePlugin({ statuses: [0, 200] }),
    ],
  })
);

// ─── Background Sync (Offline Form Submissions) ──────────────

registerRoute(
  ({ url }) => url.pathname === '/api/submit',
  new NetworkFirst({
    cacheName: 'api-submit',
    plugins: [
      new BackgroundSyncPlugin('submit-queue', {
        maxRetentionTime: 24 * 60, // 24 hours in minutes
      }),
    ],
  }),
  'POST'
);

// ─── Offline Fallback ────────────────────────────────────────

setCatchHandler(async ({ event }) => {
  if (event.request.destination === 'document') {
    return caches.match('/offline.html');
  }
  if (event.request.destination === 'image') {
    return caches.match('/icons/icon-192.png');
  }
  return Response.error();
});

// ─── Push Notifications ──────────────────────────────────────

self.addEventListener('push', (event) => {
  const defaults = { title: 'Notification', body: '', url: '/' };
  let data = defaults;
  try {
    data = { ...defaults, ...event.data?.json() };
  } catch {
    data.body = event.data?.text() || '';
  }

  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: '/icons/icon-192.png',
      badge: '/icons/icon-72.png',
      tag: data.tag || 'default',
      data: { url: data.url },
      actions: data.actions || [],
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = event.notification.data?.url || '/';

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      const existing = clientList.find((c) => new URL(c.url).pathname === url);
      if (existing) return existing.focus();
      return clients.openWindow(url);
    })
  );
});

// ─── Message Handling ────────────────────────────────────────

self.addEventListener('message', (event) => {
  if (event.data?.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
  if (event.data?.type === 'GET_VERSION') {
    event.ports[0]?.postMessage({ version: '1.0.0' });
  }
});
