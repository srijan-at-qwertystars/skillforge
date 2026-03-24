# QA Review: pwa-patterns

**Skill path:** `frontend/pwa-patterns/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `name: pwa-patterns` |
| YAML frontmatter `description` | ✅ Pass | Comprehensive multi-line description |
| Positive triggers | ✅ Pass | 10 triggers: PWA, service worker, offline-first, web app manifest, Workbox, push notification, cache strategy, installable web app, app shell, background sync |
| Negative triggers | ✅ Pass | 4 exclusions: native mobile (RN/Flutter/Swift/Kotlin), Electron, browser extensions, server-side caching (Redis/Memcached/CDN) |
| Body under 500 lines | ✅ Pass | 489 lines |
| Imperative voice | ✅ Pass | "Generate manifest.json", "Use Workbox", "Run Lighthouse", etc. |
| Examples with I/O | ✅ Pass | 3 examples (React installability, offline sync, Next.js push) each with Input and Output |
| Resources linked | ✅ Pass | 3 references, 3 scripts, 5 assets — all linked with descriptions |

**Structure verdict: PASS** — All criteria met.

---

## B. Content Check (API Verification)

### Service Worker Lifecycle Events
✅ **Accurate.** `install`, `activate`, `fetch` events are correctly named. `event.waitUntil()`, `self.skipWaiting()`, `self.clients.claim()` are correctly used. The pattern of calling `skipWaiting()` in install and `clients.claim()` in activate is correct per web.dev and MDN.

### Cache API Methods
✅ **Accurate.** `caches.open()`, `cache.add()`, `cache.addAll()`, `cache.put()`, `cache.match()`, `cache.delete()`, `cache.keys()`, `cache.matchAll()` — all correctly documented in `api-reference.md`. Notes about `addAll` atomicity, response consumption, and per-origin sharing are correct.

### Push API with VAPID
⚠️ **Bug found in SKILL.md line 261.** The subscription code uses `userVisuallyIndicatesPermission: true` — this is **not a valid property name**. The correct property is **`userVisibleOnly: true`** (per MDN PushManager.subscribe spec). This typo would cause push subscription to silently use defaults or fail. The `api-reference.md` (line 150) correctly uses `userVisibleOnly: true`. The VAPID key utility function, subscription object shape, and server-side `web-push` usage are all correct.

### Workbox Strategies API
✅ **Accurate.** `CacheFirst`, `NetworkFirst`, `StaleWhileRevalidate`, `NetworkOnly`, `CacheOnly` strategies are correctly imported and configured. `registerRoute`, `precacheAndRoute`, `ExpirationPlugin`, `CacheableResponsePlugin`, `BackgroundSyncPlugin` are all correctly used per Chrome Developers docs. `workbox-recipes` one-liners (`pageCache`, `imageCache`, `staticResourceCache`, `offlineFallback`) match current API.

### Web App Manifest Fields
✅ **Accurate.** Installability criteria (name/short_name, start_url, display standalone/fullscreen/minimal-ui, icons 192px + 512px, HTTPS, registered SW with fetch handler) match Chrome's 2024 requirements. The comprehensive field table in `api-reference.md` is thorough and correct. `display_override`, `share_target`, `file_handlers`, `protocol_handlers`, `launch_handler`, `scope_extensions` are all documented.

### iOS Safari Limitations
✅ **Largely accurate** with minor nuance:

| Feature | Skill says | Verified status | Match? |
|---------|-----------|----------------|--------|
| Push notifications | ✅ Since iOS 16.4 | ✅ Correct | ✅ |
| `beforeinstallprompt` | ❌ | ❌ Correct | ✅ |
| Background Sync | ❌ | ❌ Correct | ✅ |
| Periodic Background Sync | ❌ | ❌ Correct | ✅ |
| Background Fetch | ❌ | ❌ Correct | ✅ |
| Badging API | ❌ | ⚠️ Partial since 16.4 | ~✅ |
| Content Indexing | ❌ | ❌ Correct | ✅ |
| Window Controls Overlay | ❌ | ❌ Correct | ✅ |
| Persistent storage | ⚠️ Unreliable | ⚠️ 7-day eviction | ✅ |
| Web Share Target | ❌ | ❌ Correct | ✅ |

**Minor note:** Badging API has very limited/partial support on iOS 16.4+ but is effectively non-functional for the primary use case (`setAppBadge`), so ❌ is defensible. The iOS push notification section does not mention the EU restriction (iOS 17.4+) where PWAs cannot use push notifications; this is a completeness gap.

### Content verdict: PASS with one bug to fix.

---

## C. Trigger Check

### Would trigger for (correct positives):
- ✅ "How do I add offline support to my web app?"
- ✅ "Set up a service worker for caching"
- ✅ "Configure Workbox for my React app"
- ✅ "Web push notifications with VAPID keys"
- ✅ "Make my site an installable PWA"
- ✅ "Background sync for offline form submissions"

### Would NOT trigger for (correct negatives):
- ✅ "Build a React Native app" — excluded (native mobile)
- ✅ "Create an Electron desktop app" — excluded
- ✅ "Build a Chrome extension" — excluded (browser extensions)
- ✅ "Set up Redis caching for my API" — excluded (server-side caching)
- ✅ "CDN configuration for static assets" — excluded

### Edge cases:
- ⚠️ "Web Workers for parallel computation" — not explicitly excluded but unlikely to trigger (different keyword space)
- ⚠️ "Service mesh configuration" — not explicitly excluded

**Trigger verdict: PASS** — Good selectivity with well-defined positive and negative triggers.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4/5 | One API property name bug (`userVisuallyIndicatesPermission` → `userVisibleOnly`) in SKILL.md. All other APIs verified correct against current specs. |
| **Completeness** | 5/5 | Exceptional coverage: manifest, SW lifecycle, 5 caching strategies, Workbox modules, Push/VAPID, background sync, periodic sync, IndexedDB, App Shell, framework integrations (Next.js, Nuxt, SvelteKit), iOS workarounds, testing/auditing. 3 references + 3 scripts + 5 assets. |
| **Actionability** | 5/5 | All code examples are copy-pasteable and production-ready. Scripts are practical (setup-pwa.sh, generate-icons.sh, audit-pwa.sh). Strategy selection table is immediately useful. Assets include a complete service worker, push server, and offline page. |
| **Trigger quality** | 4/5 | Good positive/negative trigger coverage. Could add "NOT for web workers" and "NOT for service mesh" exclusions for clarity. |
| **Overall** | **4.5/5** | High-quality, production-ready skill with one API bug to fix. |

---

## Issues Found

### 🐛 Bug: Wrong Push API property name (SKILL.md:261)
**Severity:** Medium — code would fail at runtime if copied directly.
**Location:** SKILL.md, line 261, Push Notifications → Client Subscription
**Current:** `userVisuallyIndicatesPermission: true`
**Expected:** `userVisibleOnly: true`
**Note:** The `api-reference.md` (line 150) correctly uses `userVisibleOnly`. Only the main SKILL.md has this typo.

### 📝 Suggestion: Add EU push notification caveat
**Severity:** Low — completeness improvement.
**Location:** `references/troubleshooting.md`, iOS Safari Limitations → Push Notifications
**Detail:** iOS 17.4+ in the EU removed PWA home screen app support (later partially restored) and push notifications may be affected. Worth a brief note.

### 📝 Suggestion: Refine Badging API iOS status
**Severity:** Low — minor accuracy improvement.
**Detail:** Could change from ❌ to ⚠️ with note about limited/partial support since iOS 16.4.

---

## Verdict

**Result: PASS** — Overall 4.5/5, no dimension ≤ 2. No GitHub issues required.

The skill is comprehensive, well-structured, and technically accurate with one API property name bug that should be fixed. The reference files, scripts, and assets are all production-quality and properly linked.
