# Review: grpc-services

Accuracy: 5/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

- **Minor completeness gap: proto3 zero-value ambiguity** — No mention that proto3 fields
  cannot distinguish "not set" from "set to zero/empty". Engineers hit this with booleans,
  ints, and strings. The skill recommends well-known wrapper types but doesn't explain *why*
  they're needed. Addressed partially by suggesting `google.protobuf.FieldMask` for updates.

- **Minor completeness gap: no Rust/Java coverage** — Trigger description mentions `tonic`
  but the body has no Rust examples. Java is absent entirely. Acceptable given the 500-line
  limit; Go/TS/Python cover the most common use cases.

## Structure Check

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description includes positive triggers (USE when) AND negative triggers (DO NOT USE for)
- ✅ Body is 484 lines (under 500)
- ✅ Imperative voice, no filler — concise and direct throughout
- ✅ Extensive examples with code for proto definitions, Go, TypeScript, Python
- ✅ `references/`, `scripts/`, `assets/` all properly linked from SKILL.md (lines 439-485)

## Content Check

- ✅ **grpc.NewClient** — Correctly uses modern API (not deprecated `grpc.Dial`)
- ✅ **buf.yaml v2** — Correct format with `modules` array, verified against official docs
- ✅ **Default 4MB message size** — Confirmed accurate
- ✅ **nice-grpc API** — `createServer()`, `server.add()`, `server.listen()` pattern verified
- ✅ **Connect-ES/Fastify** — `fastifyConnectPlugin`, `ConnectRouter` pattern verified
- ✅ **betterproto** — `Server([...])` and `await server.start(host, port)` pattern verified
- ✅ **Error codes table** — All 10 codes with correct semantics
- ✅ **Proto3 encoding** — Tags 1-15 use 1-byte varint, correct
- ✅ **gRPC-Web** — Correctly notes "no client streaming"
- ✅ **K8s health probe** — `livenessProbe.grpc.port` syntax correct (K8s ≥ 1.24)
- ✅ **insecure.NewCredentials()** — Uses correct modern API, not deprecated `WithInsecure()`
- ✅ **10 common pitfalls** — All accurate and relevant for production use
- ✅ **Connect httptest pattern** — Multi-return from `NewPaymentServiceHandler` valid in Go
- ✅ References (advanced-patterns, troubleshooting, buf-guide) are thorough and accurate
- ✅ Scripts (proto-init, health-check, breaking-check) are well-structured with proper arg validation
- ✅ Assets (service.proto, buf configs, go-server-template, docker-compose) are production-quality

## Trigger Check

- ✅ Triggers cover all major gRPC libraries: grpc-go, grpc-js, nice-grpc, connect-rpc,
  connect-es, connect-go, grpcio, betterproto, tonic, grpcurl
- ✅ Triggers cover key concepts: unary, streaming, interceptors, metadata, deadlines,
  health checks, reflection, load balancing
- ✅ Negative triggers cleanly exclude REST, GraphQL, WebSocket-only, OpenAPI, message queues
- ✅ Low false-trigger risk — "plain protobuf without gRPC context" excluded

## Verdict

**PASS** — High-quality skill with accurate, modern content across three languages.
Minor completeness gaps are within acceptable bounds given line limits.
