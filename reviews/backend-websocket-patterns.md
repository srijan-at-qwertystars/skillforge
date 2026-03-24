# QA Review: websocket-patterns

**Reviewed:** SKILL.md + 3 references + 3 scripts + 5 assets  
**Date:** 2025-07-17  
**Verdict:** ✅ PASS

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `websocket-patterns` |
| YAML frontmatter `description` | ✅ | Present, multi-line |
| Positive triggers | ✅ | 17 specific triggers (WebSocket server/client, Socket.IO, real-time chat, reconnection logic, heartbeat, etc.) |
| Negative triggers | ✅ | 9 explicit exclusions (REST, GraphQL w/o subscriptions, SSE alone, cron, batch, etc.) |
| Body ≤ 500 lines | ✅ | 499 lines total (body: 487 lines) — just under the limit |
| Imperative voice | ✅ | Consistent: "Send server-side pings", "Always validate Origin header", "Pass token in handshake" |
| Examples with I/O | ✅ | 4 example interactions with input query → expected output behavior |
| Resources linked | ✅ | 3 reference docs, 3 scripts, 5 asset templates — all linked with relative paths and descriptions |

**Structure score: Excellent.** Clean hierarchy with protocol fundamentals → implementations → patterns → security → testing → decision guides → architecture → gotchas → examples → references.

---

## B. Content Check

### Protocol Fundamentals — VERIFIED ✅

- **Frame opcodes** (0x0–0xA): All correct per RFC 6455 §5.2.
- **Close codes**: Listed codes (1000, 1001, 1002, 1003, 1006, 1008, 1011, 1012, 1013) are accurate. Descriptions match RFC semantics.
- **Handshake headers**: Correct (Upgrade, Connection, Sec-WebSocket-Key, Sec-WebSocket-Version: 13, 101 response).

**Minor gap:** Close code **1009 (Message Too Big)** is omitted. It's a commonly used code and arguably more standard than 1012/1013. The description for 1008 mentions "message too large" which conflates it with 1009's purpose.

### ws Library (Node.js) — VERIFIED ✅

- `WebSocketServer` constructor, `connection` event signature `(ws, req)`, `ws.on('pong')`, `ws.ping()`, `ws.terminate()`, `ws.readyState`, `wss.clients` — all correct for ws v8.x (current).
- `maxPayload` option: correct.
- `isBinary` parameter on message event: correct (added in ws v8).

### Socket.IO — VERIFIED ✅

- `io.of('/namespace')`, `socket.join(room)`, `socket.handshake.auth`, acknowledgement callbacks, `socket.to(room).emit()` — all current Socket.IO v4 API.
- `connectionStateRecovery` option in assets: correct (added in Socket.IO v4.6).
- Typed events interface pattern: correct.

### Redis Adapter — VERIFIED ✅

- `@socket.io/redis-adapter` package name: correct (not the old `socket.io-redis`).
- `createAdapter(pubClient, subClient)` API: correct and current.
- `pubClient.duplicate()` pattern: correct.
- Requirement for `await connect()` on both clients: correct.

### Nginx Configuration — VERIFIED ✅

- `proxy_http_version 1.1` (required for Upgrade): correct.
- `proxy_set_header Upgrade $http_upgrade`: correct.
- `proxy_set_header Connection $connection_upgrade` (with map): correct and best-practice.
- `proxy_read_timeout 86400s`: correct for persistent connections.
- `proxy_buffering off`: correct for WebSocket frames.
- `ip_hash` for sticky sessions: correct.
- `limit_req_zone` / `limit_req` for rate limiting: correct syntax.

### Go Example — ⚠️ ISSUE FOUND

The Go example uses `gorilla/websocket`, which was **archived in late 2022** and is no longer maintained. The code is still functional but the skill should note the archived status and mention `coder/websocket` (nhooyr/websocket) as the actively maintained alternative.

### Python Example — 🐛 BUG FOUND

Line 88: `from typing import list` — lowercase `list` is **not a valid import** from `typing`. Should be:
- `from typing import List` (Python <3.9), or
- Remove the import entirely and use `list[WebSocket]` (Python 3.9+)

This will cause an `ImportError` at runtime.

### Assets & Scripts — VERIFIED ✅

- **ws-server.ts**: Production-quality with JWT auth, rate limiting, room management, graceful shutdown, health/metrics endpoints. Code compiles logically.
- **ws-client.ts**: Full state machine, request/response correlation, offline queue, heartbeat. Well-structured.
- **socket-io-server.ts**: Typed events, Redis adapter, namespaces, graceful shutdown. Correct API usage.
- **nginx-websocket.conf**: Comprehensive with SSL, map directive, rate limiting, health checks. Production-ready.
- **k6-ws-test.js**: Proper staged ramp-up, custom metrics, thresholds. Correct k6 WebSocket API.
- **Scripts**: All three are well-documented with usage examples, argument parsing, and error handling.

### Reference Documents — VERIFIED ✅

All three reference files exist and cover the topics described in the SKILL.md table. Topic coverage is thorough (838 + 906 + 746 = 2,490 lines of supplementary material).

---

## C. Trigger Check

| Scenario | Should Trigger? | Would Trigger? | Status |
|----------|----------------|----------------|--------|
| "Add WebSocket to my Express app" | Yes | Yes — matches "WebSocket server implementation" | ✅ |
| "Scale my Socket.IO app" | Yes | Yes — matches "scaling WebSocket servers, Redis adapter, sticky sessions" | ✅ |
| "WebSocket vs SSE for my dashboard" | Yes | Yes — matches "SSE vs WebSocket decisions" | ✅ |
| "Implement reconnection with backoff" | Yes | Yes — matches "reconnection logic" | ✅ |
| "WebSocket auth with JWT" | Yes | Yes — matches "WebSocket authentication" | ✅ |
| "Build a REST API with Express" | No | No — excluded by "plain HTTP REST APIs" | ✅ |
| "Set up GraphQL with Apollo Server" | No | No — excluded by "GraphQL queries without subscriptions" | ✅ |
| "Send emails with Nodemailer" | No | No — excluded by "email sending" | ✅ |
| "Implement SSE for notifications" | No | No — excluded by "Server-Sent Events without WebSocket comparison context" | ✅ |
| "Set up a cron job" | No | No — excluded by "cron jobs" | ✅ |
| "WebSocket binary messages for game" | Yes | Yes — matches "binary WebSocket messages" | ✅ |

**Trigger quality: Excellent.** No false-positive or false-negative scenarios identified. The "SSE without WebSocket comparison context" clause is particularly well-crafted.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All protocol specs, APIs, and Nginx directives verified correct. Deducted for: Python `typing.list` bug (runtime error), gorilla/websocket archived status unmentioned, close code 1009 omitted while 1008 description bleeds into 1009 territory. |
| **Completeness** | 5 | Exceptional coverage: protocol fundamentals, 3 server languages, client reconnection, Socket.IO, Redis scaling, auth, message patterns, binary, security checklist, testing, comparison table, architecture patterns, production gotchas, 3 reference docs (2,490 lines), 3 scripts, 5 asset templates. |
| **Actionability** | 5 | Every section has copy-paste code. Assets are production-ready TypeScript with full feature sets. Scripts are executable with argument parsing. Decision matrix for WebSocket vs SSE vs Long Polling. Gotchas table with cause + fix. |
| **Trigger quality** | 5 | 17 positive triggers covering all major WebSocket use cases. 9 negative triggers with precise exclusions. SSE boundary is well-defined ("without WebSocket comparison context"). |

**Overall: 4.75 / 5.0** ✅

---

## Issues Found (Non-blocking)

### 1. 🐛 Python `typing.list` ImportError (Accuracy)
- **File:** SKILL.md line 88
- **Problem:** `from typing import list` — lowercase `list` is not exported from `typing`
- **Fix:** Change to `from typing import List` or remove import and use `list[WebSocket]` (Python 3.9+)
- **Severity:** Medium — code will fail at import time

### 2. ⚠️ gorilla/websocket Archived (Accuracy)
- **File:** SKILL.md lines 121–144
- **Problem:** `gorilla/websocket` was archived in late 2022. Still functional but no longer maintained.
- **Fix:** Add a note: _"Note: gorilla/websocket is archived. For new projects, consider [`coder/websocket`](https://github.com/coder/websocket)."_
- **Severity:** Low — code works, but recommendation is outdated

### 3. 📝 Missing Close Code 1009 (Completeness)
- **File:** SKILL.md close codes table
- **Problem:** 1009 (Message Too Big) is a commonly used close code, omitted from the table. Meanwhile, 1008's description includes "message too large" which is 1009's domain.
- **Fix:** Add `1009 | Message too big | Frame or message exceeds size limit` and narrow 1008 to "Auth failure or policy violation"
- **Severity:** Low — table is still useful, just incomplete

---

## Recommendation

**PASS** — Overall score 4.75/5.0, no dimension ≤ 2. The three issues found are minor and non-blocking. The skill is exceptionally comprehensive and well-structured with high-quality production-ready code examples and supporting materials.

No GitHub issues required (overall ≥ 4.0, all dimensions > 2).
