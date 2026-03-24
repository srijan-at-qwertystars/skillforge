# Advanced FastAPI Patterns

## Table of Contents

- [Custom Middleware Chains](#custom-middleware-chains)
- [Dependency Injection Patterns](#dependency-injection-patterns)
  - [Scoped Dependencies](#scoped-dependencies)
  - [Class-Based Dependencies](#class-based-dependencies)
  - [Parameterized Dependencies](#parameterized-dependencies)
- [Background Task Patterns](#background-task-patterns)
- [Streaming Responses](#streaming-responses)
- [Server-Sent Events (SSE)](#server-sent-events-sse)
- [GraphQL Integration (Strawberry)](#graphql-integration-strawberry)
- [WebSocket Rooms and Broadcasting](#websocket-rooms-and-broadcasting)
- [Rate Limiting](#rate-limiting)
- [Request Validation Hooks](#request-validation-hooks)
- [Custom OpenAPI Schema Modifications](#custom-openapi-schema-modifications)
- [Multi-Tenancy Patterns](#multi-tenancy-patterns)
- [API Versioning Strategies](#api-versioning-strategies)

---

## Custom Middleware Chains

### Pure ASGI Middleware (Preferred for Performance)

`BaseHTTPMiddleware` consumes the request body and creates a new `Response` object, which
breaks streaming and adds overhead. Use pure ASGI middleware for production:

```python
from starlette.types import ASGIApp, Receive, Scope, Send
import time

class TimingMiddleware:
    """Pure ASGI middleware — no request body consumption overhead."""
    def __init__(self, app: ASGIApp):
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        start = time.perf_counter()

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                headers = dict(message.get("headers", []))
                elapsed = f"{time.perf_counter() - start:.4f}"
                message["headers"] = [
                    *message.get("headers", []),
                    (b"x-process-time", elapsed.encode()),
                ]
            await send(message)

        await self.app(scope, receive, send_wrapper)

app.add_middleware(TimingMiddleware)
```

### Middleware Ordering

Middleware executes in **reverse registration order** (last added = outermost).
Design chains intentionally:

```python
# Execution order: Auth → Logging → CORS (outermost runs first)
app.add_middleware(CORSMiddleware, ...)       # 3rd registered → runs 1st
app.add_middleware(LoggingMiddleware)          # 2nd registered → runs 2nd
app.add_middleware(AuthMiddleware)             # 1st registered → runs 3rd (innermost)
```

### Request ID Propagation Middleware

```python
import uuid
from contextvars import ContextVar

request_id_ctx: ContextVar[str] = ContextVar("request_id", default="")

class RequestIDMiddleware:
    def __init__(self, app: ASGIApp):
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        rid = scope.get("headers", {})
        # Check for incoming request ID header
        req_id = None
        for key, val in scope.get("headers", []):
            if key == b"x-request-id":
                req_id = val.decode()
                break
        req_id = req_id or str(uuid.uuid4())
        token = request_id_ctx.set(req_id)

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                message["headers"] = [
                    *message.get("headers", []),
                    (b"x-request-id", req_id.encode()),
                ]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            request_id_ctx.reset(token)
```

### Conditional Middleware (Skip Paths)

```python
class ConditionalMiddleware:
    def __init__(self, app: ASGIApp, skip_paths: set[str] | None = None):
        self.app = app
        self.skip_paths = skip_paths or set()

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] == "http" and scope["path"] not in self.skip_paths:
            # Apply middleware logic here
            pass
        await self.app(scope, receive, send)
```

---

## Dependency Injection Patterns

### Scoped Dependencies

Use `yield` dependencies for request-scoped resources (DB sessions, transactions):

```python
from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

async def get_db_session() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise

# Scoped to request — each request gets its own session
@router.post("/users/")
async def create_user(data: UserCreate, db: AsyncSession = Depends(get_db_session)):
    user = User(**data.model_dump())
    db.add(user)
    # commit happens automatically in dependency cleanup
    return user
```

### Class-Based Dependencies

Class-based deps are cleaner when you need state or complex initialization:

```python
class Paginator:
    def __init__(self, max_limit: int = 100):
        self.max_limit = max_limit

    def __call__(self, page: int = Query(1, ge=1), limit: int = Query(20, ge=1)):
        limit = min(limit, self.max_limit)
        offset = (page - 1) * limit
        return {"offset": offset, "limit": limit, "page": page}

paginate = Paginator(max_limit=50)

@router.get("/items/")
async def list_items(pagination: dict = Depends(paginate)):
    # pagination = {"offset": 0, "limit": 20, "page": 1}
    ...
```

### Parameterized Dependencies

Factory functions that return dependencies based on configuration:

```python
def require_role(*roles: str):
    """Dependency factory: require user to have one of the specified roles."""
    async def role_checker(current_user: User = Depends(get_current_user)):
        if current_user.role not in roles:
            raise HTTPException(
                status_code=403,
                detail=f"Requires one of: {', '.join(roles)}",
            )
        return current_user
    return role_checker

@router.delete("/users/{user_id}")
async def delete_user(
    user_id: int,
    admin: User = Depends(require_role("admin", "superadmin")),
): ...

@router.get("/reports/")
async def get_reports(
    user: User = Depends(require_role("admin", "analyst")),
): ...
```

### Dependency Overrides for Feature Flags

```python
def feature_flag(flag_name: str, fallback=None):
    async def checker(request: Request):
        flags = request.app.state.feature_flags
        if not flags.get(flag_name, False):
            if fallback:
                return fallback
            raise HTTPException(status_code=404, detail="Feature not available")
        return True
    return checker

@router.get("/beta/dashboard", dependencies=[Depends(feature_flag("beta_dashboard"))])
async def beta_dashboard(): ...
```

---

## Background Task Patterns

### Chained Background Tasks

```python
from fastapi import BackgroundTasks

async def step_one(order_id: int):
    await update_inventory(order_id)

async def step_two(order_id: int, email: str):
    await send_confirmation(order_id, email)

async def step_three(order_id: int):
    await notify_warehouse(order_id)

@router.post("/orders/")
async def create_order(order: OrderCreate, bg: BackgroundTasks):
    saved = await save_order(order)
    bg.add_task(step_one, saved.id)
    bg.add_task(step_two, saved.id, order.email)
    bg.add_task(step_three, saved.id)
    return saved  # Tasks run after response is sent, in order
```

### Background Tasks in Dependencies

```python
async def audit_log(request: Request, bg: BackgroundTasks):
    """Dependency that logs every request in the background."""
    bg.add_task(
        write_audit_log,
        path=request.url.path,
        method=request.method,
        timestamp=datetime.utcnow(),
    )

@router.get("/sensitive-data", dependencies=[Depends(audit_log)])
async def get_sensitive_data(): ...
```

### When to Use Celery/ARQ Instead

Use `BackgroundTasks` for: email sending, logging, cache invalidation (< 1 second).
Use Celery/ARQ for: report generation, image processing, ML inference, anything > 5 seconds.

```python
# ARQ example with FastAPI
from arq import create_pool
from arq.connections import RedisSettings

@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.arq_pool = await create_pool(RedisSettings())
    yield
    await app.state.arq_pool.close()

@router.post("/reports/")
async def generate_report(request: Request, params: ReportParams):
    job = await request.app.state.arq_pool.enqueue_job(
        "generate_report_task", params.model_dump()
    )
    return {"job_id": job.job_id, "status": "queued"}
```

---

## Streaming Responses

### Generator-Based Streaming

```python
from fastapi.responses import StreamingResponse
import asyncio

async def generate_large_csv(query_params: dict):
    yield "id,name,email,created_at\n"
    async for batch in fetch_users_in_batches(query_params, batch_size=1000):
        for user in batch:
            yield f"{user.id},{user.name},{user.email},{user.created_at}\n"
        await asyncio.sleep(0)  # Yield control to event loop

@router.get("/export/users")
async def export_users(status: str = "active"):
    return StreamingResponse(
        generate_large_csv({"status": status}),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=users.csv"},
    )
```

### Streaming JSON (NDJSON)

```python
import json

async def stream_ndjson(query):
    async for record in execute_streaming_query(query):
        yield json.dumps(record) + "\n"

@router.get("/stream/events")
async def stream_events():
    return StreamingResponse(
        stream_ndjson(select(Event).order_by(Event.created_at)),
        media_type="application/x-ndjson",
    )
```

### File Download Streaming

```python
from pathlib import Path
import aiofiles

async def stream_file(path: Path, chunk_size: int = 64 * 1024):
    async with aiofiles.open(path, "rb") as f:
        while chunk := await f.read(chunk_size):
            yield chunk

@router.get("/download/{file_id}")
async def download_file(file_id: str):
    path = resolve_file_path(file_id)
    if not path.exists():
        raise HTTPException(404, "File not found")
    return StreamingResponse(
        stream_file(path),
        media_type="application/octet-stream",
        headers={"Content-Disposition": f"attachment; filename={path.name}"},
    )
```

---

## Server-Sent Events (SSE)

### Basic SSE Endpoint

```python
import asyncio
import json

async def event_generator(user_id: int):
    while True:
        events = await poll_user_events(user_id)
        for event in events:
            yield f"event: {event['type']}\ndata: {json.dumps(event['data'])}\n\n"
        if not events:
            yield ": keepalive\n\n"  # Comment line to keep connection alive
        await asyncio.sleep(1)

@router.get("/events/{user_id}")
async def sse_endpoint(user_id: int):
    return StreamingResponse(
        event_generator(user_id),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",  # Disable nginx buffering
        },
    )
```

### SSE with Redis Pub/Sub

```python
import redis.asyncio as redis

async def redis_event_stream(channel: str):
    r = redis.from_url("redis://localhost")
    pubsub = r.pubsub()
    await pubsub.subscribe(channel)
    try:
        async for message in pubsub.listen():
            if message["type"] == "message":
                data = message["data"].decode()
                yield f"data: {data}\n\n"
    finally:
        await pubsub.unsubscribe(channel)
        await r.close()

@router.get("/stream/{channel}")
async def stream_channel(channel: str):
    return StreamingResponse(
        redis_event_stream(channel),
        media_type="text/event-stream",
    )
```

---

## GraphQL Integration (Strawberry)

### Setup with FastAPI

```python
import strawberry
from strawberry.fastapi import GraphQLRouter

@strawberry.type
class UserType:
    id: int
    name: str
    email: str

@strawberry.type
class Query:
    @strawberry.field
    async def user(self, id: int, info: strawberry.types.Info) -> UserType | None:
        db = info.context["db"]
        user = await db.get(User, id)
        return UserType(id=user.id, name=user.name, email=user.email) if user else None

    @strawberry.field
    async def users(self, info: strawberry.types.Info) -> list[UserType]:
        db = info.context["db"]
        result = await db.execute(select(User))
        return [UserType(id=u.id, name=u.name, email=u.email) for u in result.scalars()]

@strawberry.type
class Mutation:
    @strawberry.mutation
    async def create_user(self, name: str, email: str, info: strawberry.types.Info) -> UserType:
        db = info.context["db"]
        user = User(name=name, email=email)
        db.add(user)
        await db.commit()
        await db.refresh(user)
        return UserType(id=user.id, name=user.name, email=user.email)

schema = strawberry.Schema(query=Query, mutation=Mutation)

async def get_context(db: AsyncSession = Depends(get_db)):
    return {"db": db}

graphql_router = GraphQLRouter(schema, context_getter=get_context)
app.include_router(graphql_router, prefix="/graphql")
```

### Strawberry with DataLoaders (N+1 Prevention)

```python
from strawberry.dataloader import DataLoader

async def load_users(ids: list[int]) -> list[User]:
    async with SessionLocal() as db:
        result = await db.execute(select(User).where(User.id.in_(ids)))
        users_by_id = {u.id: u for u in result.scalars()}
        return [users_by_id.get(uid) for uid in ids]

@strawberry.type
class PostType:
    id: int
    title: str
    author_id: int

    @strawberry.field
    async def author(self, info: strawberry.types.Info) -> UserType:
        user = await info.context["user_loader"].load(self.author_id)
        return UserType(id=user.id, name=user.name, email=user.email)

async def get_context(db: AsyncSession = Depends(get_db)):
    return {"db": db, "user_loader": DataLoader(load_fn=load_users)}
```

---

## WebSocket Rooms and Broadcasting

### Room-Based Connection Manager

```python
from fastapi import WebSocket, WebSocketDisconnect
from collections import defaultdict
import json

class RoomManager:
    def __init__(self):
        self.rooms: dict[str, dict[str, WebSocket]] = defaultdict(dict)

    async def connect(self, room: str, user_id: str, ws: WebSocket):
        await ws.accept()
        self.rooms[room][user_id] = ws
        await self.broadcast(room, {
            "type": "system",
            "message": f"{user_id} joined",
            "users": list(self.rooms[room].keys()),
        }, exclude=user_id)

    async def disconnect(self, room: str, user_id: str):
        self.rooms[room].pop(user_id, None)
        if not self.rooms[room]:
            del self.rooms[room]
        else:
            await self.broadcast(room, {
                "type": "system",
                "message": f"{user_id} left",
                "users": list(self.rooms[room].keys()),
            })

    async def broadcast(self, room: str, message: dict, exclude: str | None = None):
        dead = []
        for uid, ws in self.rooms.get(room, {}).items():
            if uid == exclude:
                continue
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(uid)
        for uid in dead:
            self.rooms[room].pop(uid, None)

    async def send_to_user(self, room: str, user_id: str, message: dict):
        ws = self.rooms.get(room, {}).get(user_id)
        if ws:
            await ws.send_json(message)

rooms = RoomManager()

@app.websocket("/ws/{room}/{user_id}")
async def websocket_room(ws: WebSocket, room: str, user_id: str):
    await rooms.connect(room, user_id, ws)
    try:
        while True:
            data = await ws.receive_json()
            await rooms.broadcast(room, {
                "type": "message",
                "user": user_id,
                "data": data,
            }, exclude=user_id)
    except WebSocketDisconnect:
        await rooms.disconnect(room, user_id)
```

### WebSocket with Authentication

```python
from fastapi import WebSocket, Query, status

async def ws_auth(ws: WebSocket, token: str = Query(...)):
    try:
        user = await verify_token(token)
        return user
    except Exception:
        await ws.close(code=status.WS_1008_POLICY_VIOLATION)
        return None

@app.websocket("/ws/chat")
async def authenticated_ws(ws: WebSocket, token: str = Query(...)):
    user = await ws_auth(ws, token)
    if not user:
        return
    await ws.accept()
    # ... handle messages
```

---

## Rate Limiting

### In-Memory Rate Limiter (Single Process)

```python
import time
from collections import defaultdict
from fastapi import Request, HTTPException

class RateLimiter:
    def __init__(self, requests_per_minute: int = 60):
        self.rpm = requests_per_minute
        self.requests: dict[str, list[float]] = defaultdict(list)

    def __call__(self, request: Request):
        client_ip = request.client.host
        now = time.time()
        window_start = now - 60

        # Remove expired entries
        self.requests[client_ip] = [
            t for t in self.requests[client_ip] if t > window_start
        ]

        if len(self.requests[client_ip]) >= self.rpm:
            raise HTTPException(
                status_code=429,
                detail="Rate limit exceeded",
                headers={"Retry-After": "60"},
            )
        self.requests[client_ip].append(now)

rate_limit = RateLimiter(requests_per_minute=60)

@router.get("/api/data", dependencies=[Depends(rate_limit)])
async def get_data(): ...
```

### Redis-Based Rate Limiter (Distributed)

```python
import redis.asyncio as redis

class RedisRateLimiter:
    def __init__(self, redis_url: str, limit: int = 100, window: int = 60):
        self.redis = redis.from_url(redis_url)
        self.limit = limit
        self.window = window

    async def __call__(self, request: Request):
        key = f"ratelimit:{request.client.host}:{request.url.path}"
        pipe = self.redis.pipeline()
        pipe.incr(key)
        pipe.expire(key, self.window)
        count, _ = await pipe.execute()

        if count > self.limit:
            raise HTTPException(
                status_code=429,
                detail="Rate limit exceeded",
                headers={
                    "X-RateLimit-Limit": str(self.limit),
                    "X-RateLimit-Remaining": "0",
                    "Retry-After": str(self.window),
                },
            )

rate_limit = RedisRateLimiter("redis://localhost", limit=100, window=60)
```

### Parameterized Rate Limiting Per Endpoint

```python
def rate_limit(limit: int = 60, window: int = 60):
    limiter = RateLimiter(requests_per_minute=limit)
    return Depends(limiter)

@router.get("/search", dependencies=[rate_limit(limit=30, window=60)])
async def search(): ...

@router.get("/public", dependencies=[rate_limit(limit=200, window=60)])
async def public_data(): ...
```

---

## Request Validation Hooks

### Custom Request Validators

```python
from fastapi import Request
import hashlib, hmac

async def verify_webhook_signature(request: Request):
    """Validate incoming webhook signatures."""
    body = await request.body()
    signature = request.headers.get("X-Signature-256", "")
    secret = settings.webhook_secret.encode()
    expected = "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        raise HTTPException(status_code=401, detail="Invalid signature")

@router.post("/webhooks/github", dependencies=[Depends(verify_webhook_signature)])
async def handle_github_webhook(request: Request):
    payload = await request.json()
    ...
```

### Request Body Size Limiter

```python
class MaxBodySizeMiddleware:
    def __init__(self, app: ASGIApp, max_size: int = 10 * 1024 * 1024):  # 10MB
        self.app = app
        self.max_size = max_size

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        total = 0
        async def sized_receive():
            nonlocal total
            message = await receive()
            if message["type"] == "http.request":
                total += len(message.get("body", b""))
                if total > self.max_size:
                    raise HTTPException(413, "Request body too large")
            return message

        await self.app(scope, sized_receive, send)
```

---

## Custom OpenAPI Schema Modifications

### Adding Custom Headers/Security to All Operations

```python
from fastapi.openapi.utils import get_openapi

def custom_openapi():
    if app.openapi_schema:
        return app.openapi_schema
    schema = get_openapi(
        title=app.title,
        version=app.version,
        routes=app.routes,
    )
    # Add global security scheme
    schema["components"]["securitySchemes"] = {
        "BearerAuth": {
            "type": "http",
            "scheme": "bearer",
            "bearerFormat": "JWT",
        }
    }
    # Add custom extension to all paths
    for path in schema.get("paths", {}).values():
        for method in path.values():
            method.setdefault("security", [{"BearerAuth": []}])

    app.openapi_schema = schema
    return schema

app.openapi = custom_openapi
```

### Grouping Operations with Tags Metadata

```python
tags_metadata = [
    {"name": "users", "description": "User management", "externalDocs": {
        "description": "User docs", "url": "https://docs.example.com/users"}},
    {"name": "items", "description": "Item CRUD operations"},
    {"name": "admin", "description": "Admin-only operations"},
]

app = FastAPI(openapi_tags=tags_metadata)
```

---

## Multi-Tenancy Patterns

### Header-Based Tenant Resolution

```python
from contextvars import ContextVar

current_tenant: ContextVar[str] = ContextVar("current_tenant")

async def get_tenant(request: Request) -> str:
    tenant_id = request.headers.get("X-Tenant-ID")
    if not tenant_id:
        raise HTTPException(400, "X-Tenant-ID header required")
    if tenant_id not in await get_valid_tenants():
        raise HTTPException(404, "Tenant not found")
    current_tenant.set(tenant_id)
    return tenant_id

@router.get("/data")
async def get_data(tenant: str = Depends(get_tenant)):
    return await fetch_tenant_data(tenant)
```

### Schema-Per-Tenant (PostgreSQL)

```python
from sqlalchemy import event, text

async def get_tenant_session(
    tenant: str = Depends(get_tenant),
) -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        await session.execute(text(f"SET search_path TO {tenant}, public"))
        yield session
        await session.commit()

@router.get("/users")
async def list_users(db: AsyncSession = Depends(get_tenant_session)):
    result = await db.execute(select(User))  # Queries tenant-specific schema
    return result.scalars().all()
```

### Subdomain-Based Tenancy

```python
async def get_tenant_from_subdomain(request: Request) -> str:
    host = request.headers.get("host", "")
    subdomain = host.split(".")[0]
    if subdomain in ("www", "api", ""):
        raise HTTPException(400, "Tenant subdomain required")
    return subdomain
```

---

## API Versioning Strategies

### URL-Based Versioning (Recommended)

```python
from fastapi import APIRouter

v1_router = APIRouter(prefix="/api/v1")
v2_router = APIRouter(prefix="/api/v2")

# v1 — original schema
@v1_router.get("/users/{user_id}")
async def get_user_v1(user_id: int):
    user = await fetch_user(user_id)
    return {"id": user.id, "name": user.name}  # Flat response

# v2 — richer schema
@v2_router.get("/users/{user_id}")
async def get_user_v2(user_id: int):
    user = await fetch_user(user_id)
    return {
        "id": user.id,
        "profile": {"name": user.name, "email": user.email},
        "metadata": {"created_at": user.created_at},
    }

app.include_router(v1_router)
app.include_router(v2_router)
```

### Header-Based Versioning

```python
async def get_api_version(request: Request) -> int:
    version = request.headers.get("X-API-Version", "1")
    try:
        return int(version)
    except ValueError:
        raise HTTPException(400, "Invalid API version")

@router.get("/users/{user_id}")
async def get_user(user_id: int, version: int = Depends(get_api_version)):
    user = await fetch_user(user_id)
    if version >= 2:
        return UserResponseV2.model_validate(user)
    return UserResponseV1.model_validate(user)
```

### Router-Level Version Mounting

```python
# app/api/v1/__init__.py
from fastapi import APIRouter
from .users import router as users_router
from .items import router as items_router

router = APIRouter()
router.include_router(users_router, prefix="/users", tags=["users"])
router.include_router(items_router, prefix="/items", tags=["items"])

# main.py
from app.api.v1 import router as v1_router
from app.api.v2 import router as v2_router

app.include_router(v1_router, prefix="/api/v1")
app.include_router(v2_router, prefix="/api/v2")
```
