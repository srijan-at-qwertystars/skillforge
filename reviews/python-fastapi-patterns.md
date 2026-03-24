# QA Review: fastapi-patterns

**Reviewed:** SKILL.md, references/ (3 files), scripts/ (3 files), assets/ (5 files)
**Date:** 2025-07-17

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `fastapi-patterns` |
| YAML frontmatter `description` | ✅ Pass | Present, multi-line |
| Positive triggers | ✅ Pass | `USE when`, `TRIGGER on` with specific imports and user intents |
| Negative triggers | ✅ Pass | Three `DO NOT trigger` clauses (Pydantic-only, Django/Flask, general async) |
| Body ≤ 500 lines | ✅ Pass | Exactly 500 lines (at limit) |
| Imperative voice, no filler | ✅ Pass | Crisp, directive language throughout |
| Examples with input/output | ✅ Pass | Every section has runnable code blocks |
| references/ linked | ✅ Pass | Linked in §Custom Middleware, §Performance, §Reference Guides |
| scripts/ linked | ✅ Pass | Linked in §Scripts with usage syntax |
| assets/ linked | ✅ Pass | Linked in §Deployment and §Assets table |

---

## B. Content Check

### Verified Claims (web-searched)

| Claim | Verdict |
|-------|---------|
| `@app.on_event` is deprecated; use `lifespan` context manager | ✅ Correct — deprecated since FastAPI 0.95.0 |
| `BaseHTTPMiddleware` has performance overhead; prefer pure ASGI | ✅ Correct — body consumption + overhead per request; deprecation discussed upstream |
| Sync `def` handlers auto-run in threadpool | ✅ Correct — FastAPI uses `anyio.to_thread.run_sync` |
| `ORJSONResponse` import from `fastapi.responses` | ✅ Correct |
| CORS `allow_origins=["*"]` + `allow_credentials=True` rejected by browsers | ✅ Correct |
| `expire_on_commit=False` required for async SQLAlchemy | ✅ Correct — prevents lazy-load errors |
| Middleware executes in reverse registration order | ✅ Correct |

### Issues Found

1. **`datetime.utcnow()` is deprecated (Python 3.12+)**
   - Used in SKILL.md line 126 (`create_access_token`) and assets/settings.py implicitly through security patterns.
   - Should be `datetime.now(timezone.utc)`. This is a real-world gotcha Python developers will hit.
   - **Severity:** Medium — generates deprecation warnings, naive datetime bugs.

2. **`python-jose` has known CVE (CVE-2024-33663) and uncertain maintenance**
   - SKILL.md and all templates use `from jose import jwt`. The FastAPI community is actively discussing switching to PyJWT.
   - python-jose had a 3-year release gap before v3.5.0. Algorithm confusion vulnerability was patched but shook confidence.
   - Should add a note: _"Consider PyJWT (`import jwt`) as a lighter, better-maintained alternative. python-jose is needed only for JWE/JWK."_
   - **Severity:** Medium — security and maintenance risk.

3. **`event_loop` fixture in assets/conftest.py is deprecated**
   - Lines 50-53 define a custom `event_loop` fixture. With `pytest-asyncio>=0.23` and `asyncio_mode = "auto"`, this fixture is deprecated and triggers warnings.
   - Should be removed; the framework handles the loop automatically.
   - **Severity:** Low — causes deprecation warnings in tests.

4. **Missing `orjson` in dependencies**
   - `ORJSONResponse` is recommended in SKILL.md §Performance but `orjson` is not listed in assets/pyproject.toml dependencies.
   - **Severity:** Low — runtime ImportError if user follows the advice.

### Missing Gotchas

- No mention of `datetime.utcnow()` deprecation (covered above)
- No mention of `python-jose` security concerns (covered above)
- Could note that `Depends()` (with parens) is required for `OAuth2PasswordRequestForm` but optional for callables — a common beginner mistake

### Example Correctness

- All code examples are syntactically correct and follow modern Pydantic v2 / SQLAlchemy 2.0 patterns.
- Scripts (`fastapi-init.sh`, `generate-crud.sh`, `api-test-scaffold.sh`) generate valid, runnable code.
- Assets (Dockerfile, docker-compose, conftest, settings) are production-quality.
- The file upload example correctly uses chunked reading with walrus operator.

### AI Executability

An AI reading this skill would be able to:
- Scaffold a complete FastAPI project ✅
- Implement CRUD endpoints with proper async DB patterns ✅
- Set up authentication (with the `python-jose` caveat) ✅
- Write tests with proper async client fixtures ✅
- Deploy with Docker ✅
- Handle middleware, WebSockets, file uploads ✅

---

## C. Trigger Check

### Positive Trigger Analysis

The description triggers on:
- FastAPI, Starlette, Uvicorn imports ✅
- Key symbols: APIRouter, Depends, HTTPException, BackgroundTasks, WebSocket, UploadFile, OAuth2PasswordBearer ✅
- Intent phrases: "build an API", "web service", "endpoint", "microservice in Python using FastAPI" ✅

**Would it trigger for real user queries?**
- "How do I create a REST API with FastAPI?" → ✅ Yes
- "Add authentication to my FastAPI app" → ✅ Yes
- "FastAPI WebSocket example" → ✅ Yes
- "Deploy FastAPI with Docker" → ✅ Yes

### Negative Trigger Analysis

- "Create a Flask REST API" → ✅ Correctly excluded
- "Django REST framework viewset" → ✅ Correctly excluded
- "Validate data with Pydantic" (no FastAPI) → ✅ Correctly excluded
- "async/await Python tutorial" (no FastAPI) → ✅ Correctly excluded

### Suggestions

- Could add "GraphQL with FastAPI" as a trigger (since Strawberry integration is covered in advanced-patterns.md)
- Could add "SSE" / "Server-Sent Events" as a trigger keyword

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Mostly accurate; `datetime.utcnow()` deprecation and `python-jose` CVE are notable gaps |
| **Completeness** | 5 | Exceptional coverage: 500-line SKILL.md + 3 deep-dive references + 3 scripts + 5 asset templates |
| **Actionability** | 5 | Every concept has runnable code; scripts generate full projects; templates are production-ready |
| **Trigger quality** | 4 | Strong positive/negative triggers with specific symbols; could add GraphQL/SSE keywords |

**Overall: 4.5 / 5.0**

---

## E. GitHub Issues

Overall ≥ 4.0 and no dimension ≤ 2 → **No issues filed.**

Recommended improvements (non-blocking):
1. Replace `datetime.utcnow()` with `datetime.now(timezone.utc)` in JWT examples
2. Add note about `python-jose` maintenance status and PyJWT alternative
3. Remove deprecated `event_loop` fixture from assets/conftest.py
4. Add `orjson` to pyproject.toml dependencies (or note it as optional)

---

## F. Test Status

**Result: PASS**

The skill is high-quality and production-ready. The issues found are minor and non-blocking — the core patterns, architecture guidance, and code examples are accurate and actionable.
