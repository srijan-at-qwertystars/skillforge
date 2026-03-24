# QA Review: networking/grpc-patterns

**Reviewed:** 2026-03-24T18:31:25Z
**Skill path:** `~/skillforge/networking/grpc-patterns/`
**Verdict:** ✅ PASS

---

## Scores

| Dimension      | Score | Notes |
|----------------|:-----:|-------|
| Accuracy       | 4/5   | Two factual errors in Node.js example and troubleshooting reference (see below). Core gRPC/Go/Python/protobuf content is correct. |
| Completeness   | 5/5   | Exceptionally thorough. Covers all 4 RPC types, 3 languages, codegen (protoc + buf), error handling, interceptors, deadlines, metadata, auth, load balancing, health checking, reflection, gRPC-Web, testing, plus 3 reference docs, 2 scripts, 3 assets. |
| Actionability  | 5/5   | Copy-paste ready code for every pattern. Production-ready Go server template. Shell scripts for codegen and testing. Asset templates for proto, buf config, and server scaffolding. |
| Trigger quality| 4/5   | Good positive/negative triggers. One positive trigger ("service-to-service RPC communication") is broad enough to false-match non-gRPC RPC patterns. |
| **Overall**    | **4.5** | |

---

## A. Structure Check

- [x] **YAML frontmatter** — Has `name` and `description` fields
- [x] **Positive triggers** — 7 specific trigger phrases (gRPC services, protobuf definitions, bidirectional streaming, etc.)
- [x] **Negative triggers** — 6 exclusions (REST APIs, GraphQL, WebSocket chat, HTTP routing, etc.)
- [x] **Body under 500 lines** — 499 lines (⚠️ at the limit, no headroom for additions)
- [x] **Imperative voice** — Consistent ("Use `syntax = "proto3"`", "Always set deadlines", "Keep request/response messages per-RPC")
- [x] **Examples** — Extensive code examples in Go, Python, Node.js, protobuf, bash
- [x] **Resources linked** — References, Scripts, and Assets sections all link correctly to sub-files

**Minor structural issue:** Missing blank lines before `## Scripts` (line 489) and `## Assets` (line 493) headings. Some Markdown parsers may not render these as headings.

---

## B. Content Check — Issues Found

### Issue 1: Node.js `server.start()` is deprecated (Medium)
**File:** SKILL.md, line 145
**Problem:** The Node.js example calls `server.start()` after `bindAsync()`:
```javascript
server.bindAsync("0.0.0.0:50051", grpc.ServerCredentials.createInsecure(), () => server.start());
```
Since `@grpc/grpc-js` v1.10.x, `server.start()` is deprecated and removed in later versions. The server starts automatically after `bindAsync` completes.

**Fix:** Remove the `server.start()` call:
```javascript
server.bindAsync("0.0.0.0:50051", grpc.ServerCredentials.createInsecure(), () => {
  console.log("Server running on 0.0.0.0:50051");
});
```

### Issue 2: Incorrect Connect streaming claim in troubleshooting (Medium)
**File:** references/troubleshooting.md, line 592
**Problem:** States "For full streaming in browsers, use **Connect protocol** (`@connectrpc/connect-web`) which supports all RPC types via WebSocket or HTTP/2." This is **incorrect**:
- ConnectRPC in browsers has the **same** streaming limitation as gRPC-Web (no client or bidirectional streaming), due to browser Fetch API limitations.
- ConnectRPC does **not** use WebSocket.

**Fix:** Replace with: "For server streaming in browsers, **Connect protocol** (`@connectrpc/connect-web`) provides a simpler setup than gRPC-Web (no proxy required with connect-go). Full client/bidirectional streaming requires native (non-browser) clients."

### Issue 3: `double` type for monetary value in example (Minor)
**File:** SKILL.md, line 37
**Problem:** `LineItem` uses `double price = 3;` — floating-point for money is a known anti-pattern. The asset template (`assets/service.proto`) correctly uses `int64 price_cents = 4;`.
**Fix:** Either change to `int64 price_cents` or add a comment noting this is simplified.

---

## C. Trigger Check

**Would it trigger correctly?**
- ✅ "I need to set up a gRPC service" → triggers (matches "building gRPC services")
- ✅ "How do I write protobuf definitions?" → triggers
- ✅ "Implement bidirectional streaming" → triggers
- ✅ "gRPC interceptor middleware" → triggers
- ✅ "gRPC-Web browser client" → triggers

**False trigger risks:**
- ⚠️ "service-to-service RPC communication" is broad — could match Thrift, JSON-RPC, or custom RPC frameworks. Consider narrowing to "service-to-service **gRPC** communication".

**Correct non-triggers:**
- ✅ "Build a REST API" → excluded
- ✅ "GraphQL resolvers" → excluded
- ✅ "WebSocket chat app" → excluded

---

## D. Verified Claims (Web Search)

| Claim | Verified |
|-------|----------|
| `grpc.NewClient` is the current Go API (not deprecated `grpc.Dial`) | ✅ Correct (since v1.63.0) |
| gRPC-Web lacks client/bidi streaming support | ✅ Correct |
| ConnectRPC `createClient` is the correct function | ✅ Correct |
| Python `grpc_testing.server_from_dictionary` + `invoke_unary_unary` | ✅ Correct API |
| bufconn test example using `"passthrough:///bufnet"` with `grpc.NewClient` | ✅ Correct (NewClient defaults to dns resolver, passthrough needed for bufconn) |

---

## E. GitHub Issues

No issues filed. Overall score (4.5) ≥ 4.0 and no dimension ≤ 2.

---

## Summary

This is a high-quality, production-ready skill. The two medium-severity issues (deprecated Node.js API, incorrect Connect streaming claim) should be fixed but don't undermine the skill's overall value. The Go and Python content is accurate, the protobuf guidance follows best practices, and the supporting assets/scripts are well-crafted.

**Recommended fixes (priority order):**
1. Remove `server.start()` from Node.js example
2. Correct Connect streaming claim in troubleshooting reference
3. Add blank lines before `## Scripts` / `## Assets` headings
4. Consider narrowing "service-to-service RPC communication" trigger
