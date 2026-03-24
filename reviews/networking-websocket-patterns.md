# QA Review: networking/websocket-patterns

**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17
**Skill path:** `~/skillforge/networking/websocket-patterns/`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter: `name` | ✅ Pass | `websocket-patterns` |
| YAML frontmatter: `description` | ✅ Pass | Clear, multi-line description |
| Positive triggers | ✅ Pass | WebSocket servers/clients, Socket.IO, ws library, bidirectional messaging, live updates, chat, notifications, collaborative editing, multiplayer |
| Negative triggers | ✅ Pass | REST API, SSE, gRPC, HTTP polling, static content |
| Body ≤ 500 lines | ✅ Pass | 489 body lines (499 total, 10 frontmatter) |
| Imperative voice | ✅ Pass | Uses imperative/descriptive throughout |
| Code examples | ✅ Pass | Extensive — 20+ code blocks across JS, Python, Go, nginx, YAML |
| Resources linked from SKILL.md | ✅ Pass | References (2), Scripts (2), Assets (3) all linked with descriptions |

**Structure verdict:** Pass — well-organized with clear sections.

---

## b. Content Check

### Verified Claims

| Claim | Verification | Status |
|-------|-------------|--------|
| Sec-WebSocket-Accept computed from SHA-1 + base64 | RFC 6455 §4.2.2 | ✅ Correct |
| Handshake example (`s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`) | Recomputed with OpenSSL | ✅ Correct |
| Close code 1006 is internal-use only | RFC 6455 §7.4.1 — MUST NOT be sent in close frame | ✅ Correct |
| Socket.IO connection state recovery added in v4.6+ | Socket.IO changelog confirms v4.6.0 (Feb 2023) | ✅ Correct |
| Client-to-server frames MUST be masked | RFC 6455 §5.3 | ✅ Correct |
| Opcode table (0x0–0xA) | RFC 6455 §5.2 | ✅ Correct |
| Close codes (1000–4999 range) | RFC 6455 §7.4 | ✅ Correct |
| Artillery WS load test config | Artillery docs | ⚠️ Minor — see issues |

### Issues Found

#### 🔴 Issue 1: Wrong WebSocket Magic GUID (Accuracy)

**Location:** SKILL.md line 38
**Severity:** High
**Details:** The RFC 6455 magic GUID is written as `258EAFA5-E914-47DA-95CA-5AB9DC85B711` but the correct value per RFC 6455 §1.3 is `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`. The last segment differs: `5AB9DC85B711` vs `C5AB0DC85B11`. The handshake example values are correct (verified by computation), but the explanatory text contains the wrong GUID. This would mislead anyone implementing a WebSocket server from scratch using this text.

#### 🟡 Issue 2: gorilla/websocket Is Archived (Accuracy/Currency)

**Location:** SKILL.md lines 122–132
**Severity:** Medium
**Details:** The Go example uses `gorilla/websocket`, which was archived in late 2022 and is no longer maintained. The code still works but receives no security patches. The skill should note this and recommend `github.com/coder/websocket` (formerly nhooyr/websocket) as the actively maintained alternative.

#### 🟡 Issue 3: Artillery Config Uses v1 Syntax (Accuracy)

**Location:** SKILL.md lines 427–437
**Severity:** Low
**Details:** The Artillery YAML uses `engines: { ws: {} }` which is Artillery v1 syntax. In Artillery v2 (current), you only need `engine: ws` in the scenario block; the `engines` config key is not required. The config works but is outdated.

### Missing Gotchas

- No mention that browser `WebSocket` API lacks a `ping()` method (only Node.js `ws` has it). The troubleshooting.md line 527 uses `ws.ping?.()` with optional chaining as a workaround, which is clever but should be explicitly called out.
- No mention of `WebSocket.binaryType` property (defaults to `"blob"` in browsers, often needs to be set to `"arraybuffer"` for binary handling).

### Code Quality Assessment

- **ws-server.ts:** Production-quality. Proper auth, rate limiting, rooms, graceful shutdown, health endpoint. ✅
- **socket-io-server.ts:** Production-quality. Redis adapter, namespaces, middleware, recovery. ✅
- **nginx-websocket.conf:** Comprehensive. Upgrade map, SSL, rate limiting, sticky sessions. ✅
- **ws-load-test.sh:** Functional. Good arg parsing, parallel connections, result aggregation. ✅
- **ws-debug.sh:** Functional. Timestamps, JSON pretty-print, interactive mode. ✅
- **references/advanced-patterns.md:** Thorough coverage of multiplexing, binary protocols, compression, HTTP/2, WebTransport, CRDT/OT. ✅
- **references/troubleshooting.md:** Excellent real-world scenarios with specific proxy configs, mobile transitions, tab throttling. ✅

---

## c. Trigger Check

| Aspect | Assessment |
|--------|-----------|
| Would description trigger correctly? | ✅ Yes — covers common WebSocket-related keywords well |
| False positive risk | ⚠️ Low — "live updates" could overlap with SSE, but negative trigger for SSE mitigates this |
| Missing positive triggers | Minor — could add "Phoenix channels", "ActionCable", "Pusher" as framework-specific WebSocket triggers |
| Negative trigger coverage | ✅ Good — REST, SSE, gRPC, HTTP polling, static content |

**Trigger verdict:** Good. Description is well-scoped with clear positive and negative boundaries.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3 | Wrong GUID in protocol fundamentals; archived library recommended without disclaimer |
| **Completeness** | 5 | Exceptional breadth — protocol spec, 4 languages, auth patterns, scaling, testing, security, debugging, advanced patterns, troubleshooting |
| **Actionability** | 5 | Production-ready code assets, utility scripts, nginx config, copy-paste examples throughout |
| **Trigger quality** | 4 | Good positive/negative triggers; minor overlap risk with SSE |
| **Overall** | **4.25** | Strong skill with factual errors that need correction |

---

## e. GitHub Issues

No GitHub issues filed. Overall score (4.25) ≥ 4.0 and no dimension ≤ 2.

The GUID error and gorilla/websocket deprecation should be fixed but do not warrant issue filing per the scoring thresholds.

---

## f. Test Status

**Result: PASS** (with noted corrections needed)

Priority fixes:
1. Correct the WebSocket magic GUID on SKILL.md line 38
2. Add deprecation note for gorilla/websocket with alternative recommendation
3. Update Artillery config to v2 syntax

---

*Review generated by Copilot CLI automated QA*
