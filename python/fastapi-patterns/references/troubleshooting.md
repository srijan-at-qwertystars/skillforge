# FastAPI Troubleshooting Guide

## Table of Contents

- [Async vs Sync Performance Traps](#async-vs-sync-performance-traps)
- [SQLAlchemy Session Leaks](#sqlalchemy-session-leaks)
- [Dependency Injection Circular References](#dependency-injection-circular-references)
- [CORS Preflight Failures](#cors-preflight-failures)
- [Large File Upload OOM](#large-file-upload-oom)
- [WebSocket Disconnection Handling](#websocket-disconnection-handling)
- [Pydantic v2 Migration Issues](#pydantic-v2-migration-issues)
- [Uvicorn Worker Crashes](#uvicorn-worker-crashes)
- [Slow Startup with Many Routes](#slow-startup-with-many-routes)
- [Testing Async Endpoints](#testing-async-endpoints)
- [422 Validation Error Debugging](#422-validation-error-debugging)
- [OpenAPI Schema Conflicts](#openapi-schema-conflicts)

---

## Async vs Sync Performance Traps

### Problem: Blocking Calls in Async Handlers

Using synchronous libraries (e.g., `requests`, `time.sleep()`, sync DB drivers) inside
`async def` blocks the entire event loop, causing all concurrent requests to stall.

**Symptoms**: Requests queue up, response times spike under concurrency, timeouts.

```python
# BAD — blocks the event loop
@router.get("/data")
async def get_data():
    response = requests.get("https://api.example.com")  # BLOCKS!
    time.sleep(1)  # BLOCKS!
    return response.json()

# GOOD — use async libraries
@router.get("/data")
async def get_data():
    async with httpx.AsyncClient() as client:
        response = await client.get("https://api.example.com")
    await asyncio.sleep(1)
    return response.json()
```

### Problem: Making CPU-Bound Work Async

CPU-heavy tasks in `async def` starve the event loop.

```python
# BAD — CPU work in async def blocks the event loop
@router.get("/compute")
async def compute():
    return heavy_computation()  # Blocks for 5 seconds

# GOOD — use sync def (FastAPI auto-runs it in a threadpool)
@router.get("/compute")
def compute():
    return heavy_computation()  # Runs in threadpool, doesn't block event loop

# GOOD — for truly heavy work, use run_in_executor explicitly
@router.get("/compute")
async def compute():
    loop = asyncio.get_event_loop()
    result = await loop.run_in_executor(None, heavy_computation)
    return result
```

### Problem: Mixing Sync and Async Incorrectly

```python
# BAD — calling sync function with await
async def get_user():
    user = await sync_db_call()  # TypeError: object int can't be used in await

# BAD — calling async without await
async def get_user():
    user = async_db_call()  # Returns coroutine, not the result!
    print(user)  # <coroutine object async_db_call at 0x...>
```

### Debugging Tip: Detect Blocking Calls

```python
# Add to development to catch blocking calls
import asyncio

# Python 3.12+
asyncio.get_event_loop().slow_callback_duration = 0.1  # Log if callback takes >100ms

# Or use the debug mode
# PYTHONASYNCIODEBUG=1 uvicorn app.main:app
```

---

## SQLAlchemy Session Leaks

### Problem: Sessions Not Properly Closed

**Symptoms**: Connection pool exhausted, `TimeoutError`, database connections accumulate.

```python
# BAD — session leak if exception occurs before yield
async def get_db():
    session = SessionLocal()
    yield session  # If error before this, session leaks
    await session.close()

# GOOD — use async context manager
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        yield session  # Context manager handles cleanup on any exit path

# EVEN BETTER — with transaction management
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
```

### Problem: expire_on_commit Not Disabled

```python
# BAD — accessing attributes after commit raises DetachedInstanceError
SessionLocal = async_sessionmaker(bind=engine)  # expire_on_commit defaults to True

async def create_user(db: AsyncSession):
    user = User(name="Alice")
    db.add(user)
    await db.commit()
    return user.name  # DetachedInstanceError! Attribute expired after commit

# GOOD — disable expire_on_commit for async sessions
SessionLocal = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,  # Required for async
)
```

### Problem: Lazy Loading in Async Context

```python
# BAD — lazy loading doesn't work with async
user = await db.get(User, 1)
print(user.posts)  # MissingGreenlet error — can't do lazy load in async

# GOOD — use eager loading
from sqlalchemy.orm import selectinload, joinedload

result = await db.execute(
    select(User).options(selectinload(User.posts)).where(User.id == 1)
)
user = result.scalar_one()
print(user.posts)  # Works — posts were eagerly loaded
```

### Monitoring Connection Pool

```python
from sqlalchemy import event

@event.listens_for(engine.sync_engine, "checkout")
def receive_checkout(dbapi_conn, connection_record, connection_proxy):
    logger.debug(f"Connection checked out. Pool: {engine.pool.status()}")

@event.listens_for(engine.sync_engine, "checkin")
def receive_checkin(dbapi_conn, connection_record):
    logger.debug(f"Connection returned. Pool: {engine.pool.status()}")
```

---

## Dependency Injection Circular References

### Problem: Dependencies That Reference Each Other

```python
# BAD — circular dependency
async def get_service_a(b = Depends(get_service_b)):
    return ServiceA(b)

async def get_service_b(a = Depends(get_service_a)):  # Circular!
    return ServiceB(a)
```

**Fix**: Break the cycle with an interface or mediator pattern:

```python
# GOOD — break the cycle with an event bus or mediator
class EventBus:
    def __init__(self):
        self._handlers: dict[str, list[Callable]] = {}

    def subscribe(self, event: str, handler: Callable):
        self._handlers.setdefault(event, []).append(handler)

    async def publish(self, event: str, data: Any):
        for handler in self._handlers.get(event, []):
            await handler(data)

async def get_event_bus() -> EventBus:
    return app.state.event_bus

async def get_service_a(bus: EventBus = Depends(get_event_bus)):
    return ServiceA(bus)

async def get_service_b(bus: EventBus = Depends(get_event_bus)):
    return ServiceB(bus)
```

### Problem: Heavy Dependencies Re-Created Per Request

```python
# BAD — ML model loaded on every request
async def get_model():
    return load_heavy_model()  # 10 seconds to load!

# GOOD — load once in lifespan, access via app.state
@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.model = load_heavy_model()
    yield

async def get_model(request: Request):
    return request.app.state.model
```

---

## CORS Preflight Failures

### Problem: OPTIONS Requests Return 405 or 403

**Symptoms**: Browser console shows `CORS policy` error, preflight `OPTIONS` returns error.

```python
# BAD — middleware added after route registration, or wrong order
app.include_router(router)
app.add_middleware(CORSMiddleware, ...)  # This actually works in FastAPI but check config

# Common misconfigurations:
# 1. allow_origins=["*"] WITH allow_credentials=True (browsers reject this)
# 2. Missing required headers in allow_headers
# 3. Forgetting to include the actual origin (not just "*")
```

**Fix checklist**:

```python
app.add_middleware(
    CORSMiddleware,
    # For credentials, list specific origins — never "*"
    allow_origins=["https://app.example.com", "http://localhost:3000"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
    expose_headers=["X-Request-ID"],  # Headers the browser can read
    max_age=600,  # Cache preflight for 10 minutes
)
```

### Problem: CORS Works Locally but Not in Production

Check for:
1. **Reverse proxy stripping headers**: Ensure nginx/traefik forwards CORS headers.
2. **Different origins**: `http://localhost:3000` ≠ `https://app.example.com`.
3. **Missing scheme**: `example.com` ≠ `https://example.com`.

```nginx
# nginx — don't add CORS headers if FastAPI already handles them
location /api {
    proxy_pass http://app:8000;
    # Do NOT add add_header Access-Control-* here if FastAPI handles CORS
}
```

---

## Large File Upload OOM

### Problem: Reading Entire File Into Memory

```python
# BAD — loads entire file into memory
@router.post("/upload")
async def upload(file: UploadFile):
    content = await file.read()  # 2GB file → 2GB in memory → OOM
    save_to_disk(content)

# GOOD — stream in chunks
@router.post("/upload")
async def upload(file: UploadFile):
    dest = Path("uploads") / file.filename
    async with aiofiles.open(dest, "wb") as f:
        while chunk := await file.read(1024 * 1024):  # 1MB chunks
            await f.write(chunk)
    return {"size": dest.stat().st_size}
```

### Problem: Request Body Size Not Limited

By default, FastAPI/Starlette doesn't limit request body size. Use middleware or
reverse proxy limits:

```python
# Middleware approach
from starlette.types import ASGIApp, Receive, Scope, Send

class LimitUploadSizeMiddleware:
    def __init__(self, app: ASGIApp, max_size: int = 100 * 1024 * 1024):  # 100MB
        self.app = app
        self.max_size = max_size

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] == "http":
            content_length = 0
            for header, value in scope.get("headers", []):
                if header == b"content-length":
                    content_length = int(value)
                    break
            if content_length > self.max_size:
                response = JSONResponse(
                    status_code=413,
                    content={"detail": f"File too large. Max: {self.max_size} bytes"},
                )
                await response(scope, receive, send)
                return
        await self.app(scope, receive, send)
```

```nginx
# nginx — simpler approach
client_max_body_size 100m;
```

---

## WebSocket Disconnection Handling

### Problem: Unhandled Disconnections Crash the Server

```python
# BAD — no disconnect handling
@app.websocket("/ws")
async def ws(websocket: WebSocket):
    await websocket.accept()
    while True:
        data = await websocket.receive_text()  # Raises on disconnect
        await websocket.send_text(f"Echo: {data}")
        # WebSocketDisconnect exception propagates, connection leaks

# GOOD — proper cleanup
@app.websocket("/ws")
async def ws(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            data = await websocket.receive_text()
            await websocket.send_text(f"Echo: {data}")
    except WebSocketDisconnect:
        logger.info("Client disconnected normally")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
    finally:
        # Clean up resources (remove from manager, close DB sessions, etc.)
        manager.disconnect(websocket)
```

### Problem: Zombie WebSocket Connections

Clients may disconnect without sending a close frame (network drop, browser crash).

```python
import asyncio

@app.websocket("/ws")
async def ws(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            try:
                data = await asyncio.wait_for(
                    websocket.receive_text(),
                    timeout=30.0,  # Heartbeat timeout
                )
                await websocket.send_text(f"Echo: {data}")
            except asyncio.TimeoutError:
                # Send ping to check if client is alive
                try:
                    await websocket.send_json({"type": "ping"})
                except Exception:
                    break  # Client is gone
    except WebSocketDisconnect:
        pass
```

---

## Pydantic v2 Migration Issues

### Common Breaking Changes

```python
# v1 → v2: class Config → model_config
# BAD (v1)
class UserResponse(BaseModel):
    class Config:
        orm_mode = True

# GOOD (v2)
class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

# v1 → v2: .dict() → .model_dump()
user.dict()         # v1 (deprecated)
user.model_dump()   # v2

# v1 → v2: .parse_obj() → .model_validate()
User.parse_obj(data)      # v1 (deprecated)
User.model_validate(data) # v2

# v1 → v2: @validator → @field_validator
# BAD (v1)
from pydantic import validator
class User(BaseModel):
    name: str
    @validator("name")
    def name_must_not_be_empty(cls, v):
        if not v.strip():
            raise ValueError("Name cannot be empty")
        return v.strip()

# GOOD (v2)
from pydantic import field_validator
class User(BaseModel):
    name: str
    @field_validator("name")
    @classmethod
    def name_must_not_be_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("Name cannot be empty")
        return v.strip()

# v1 → v2: @root_validator → @model_validator
# BAD (v1)
from pydantic import root_validator
class DateRange(BaseModel):
    start: date
    end: date
    @root_validator
    def check_dates(cls, values):
        if values["start"] > values["end"]:
            raise ValueError("start must be before end")
        return values

# GOOD (v2)
from pydantic import model_validator
class DateRange(BaseModel):
    start: date
    end: date
    @model_validator(mode="after")
    def check_dates(self) -> "DateRange":
        if self.start > self.end:
            raise ValueError("start must be before end")
        return self
```

### Pydantic v2 Performance Gotchas

```python
# v2 uses strict mode by default for some types
# int fields no longer accept string "123" — use coerce or annotate
class Item(BaseModel):
    quantity: int  # "123" → ValidationError in strict mode

# Fix: use lenient types or mode="before" validator
from annotated_types import Gt
from pydantic import BeforeValidator
from typing import Annotated

def coerce_int(v):
    return int(v) if isinstance(v, str) else v

CoercedInt = Annotated[int, BeforeValidator(coerce_int)]

class Item(BaseModel):
    quantity: CoercedInt  # "123" → 123
```

---

## Uvicorn Worker Crashes

### Problem: Workers Dying Without Logs

**Symptoms**: Random 502s, worker processes disappear, gunicorn shows `WORKER TIMEOUT`.

**Common causes**:

1. **Sync blocking in async handler**: Causes worker timeout.
   ```bash
   # Increase timeout for debugging (don't keep in production)
   gunicorn app.main:app -k uvicorn.workers.UvicornWorker --timeout 120
   ```

2. **Memory leaks**: Workers grow in memory until OOM-killed.
   ```bash
   # Restart workers after N requests to limit memory growth
   gunicorn app.main:app -k uvicorn.workers.UvicornWorker --max-requests 1000 --max-requests-jitter 100
   ```

3. **Unhandled exceptions in lifespan**: Crash before any request handling.
   ```python
   @asynccontextmanager
   async def lifespan(app: FastAPI):
       try:
           app.state.db = create_engine(...)
           yield
       except Exception as e:
           logger.critical(f"Lifespan error: {e}")
           raise  # Don't swallow — let supervisor restart
       finally:
           await cleanup()
   ```

### Problem: Uvicorn Reload Not Working in Docker

```dockerfile
# Mount source code as volume for reload to work
# docker-compose.yml
services:
  app:
    volumes:
      - ./app:/app/app
    command: uvicorn app.main:app --reload --host 0.0.0.0 --reload-dir /app/app
```

### Production Configuration

```bash
# Recommended production setup
gunicorn app.main:app \
    -k uvicorn.workers.UvicornWorker \
    -w $(( 2 * $(nproc) + 1 )) \
    --bind 0.0.0.0:8000 \
    --timeout 30 \
    --graceful-timeout 10 \
    --keep-alive 5 \
    --max-requests 2000 \
    --max-requests-jitter 200 \
    --access-logfile - \
    --error-logfile -
```

---

## Slow Startup with Many Routes

### Problem: App Takes >10s to Start

**Common causes**:

1. **Too many routes with complex dependencies**: Each route resolves its dependency tree at startup.

2. **Heavy imports at module level**: Models, ML libraries loaded on import.
   ```python
   # BAD — heavy import at module level
   from transformers import pipeline  # Loads PyTorch, downloads model
   
   # GOOD — lazy import
   def get_model():
       if not hasattr(app.state, "model"):
           from transformers import pipeline
           app.state.model = pipeline("sentiment-analysis")
       return app.state.model
   ```

3. **OpenAPI schema generation**: Many routes with complex models slow schema gen.
   ```python
   # Disable OpenAPI in production if not needed
   app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
   ```

4. **Profiling startup**:
   ```python
   import time
   
   @asynccontextmanager
   async def lifespan(app: FastAPI):
       start = time.perf_counter()
       # ... startup
       logger.info(f"Startup took {time.perf_counter() - start:.2f}s")
       yield
   ```

---

## Testing Async Endpoints

### Problem: `async def` Tests Don't Run

```python
# BAD — test is async but pytest doesn't know how to run it
async def test_create_user():
    # This test silently passes without running!
    ...

# GOOD — use pytest-anyio or pytest-asyncio
import pytest
from httpx import AsyncClient, ASGITransport

@pytest.fixture
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as c:
        yield c

@pytest.mark.anyio
async def test_create_user(client: AsyncClient):
    resp = await client.post("/users/", json={"name": "Alice"})
    assert resp.status_code == 201
```

### Problem: Database State Leaks Between Tests

```python
# GOOD — rollback after each test
@pytest.fixture
async def db_session():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    async with SessionLocal() as session:
        async with session.begin():
            yield session
            await session.rollback()  # Undo all changes

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)

# Override dependency for tests
@pytest.fixture
async def client(db_session):
    async def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()
```

### Problem: Mocking Dependencies

```python
# Override dependencies in tests
from unittest.mock import AsyncMock

@pytest.fixture
def mock_email_service():
    mock = AsyncMock()
    mock.send.return_value = True
    app.dependency_overrides[get_email_service] = lambda: mock
    yield mock
    app.dependency_overrides.clear()

@pytest.mark.anyio
async def test_registration_sends_email(client, mock_email_service):
    resp = await client.post("/register", json={"email": "test@example.com"})
    assert resp.status_code == 201
    mock_email_service.send.assert_called_once()
```

---

## 422 Validation Error Debugging

### Problem: Cryptic 422 Errors

FastAPI returns 422 when request data doesn't match the Pydantic model.

**Debugging steps**:

1. **Read the error detail**: The response body contains specifics.
   ```json
   {
     "detail": [
       {
         "type": "missing",
         "loc": ["body", "price"],
         "msg": "Field required",
         "input": {"name": "Widget"}
       }
     ]
   }
   ```

2. **Common causes**:
   - Missing `Content-Type: application/json` header
   - Sending form data to a JSON endpoint (or vice versa)
   - Camel case vs snake case mismatch
   - Query param sent as path param

3. **Custom 422 handler for better errors**:
   ```python
   from fastapi.exceptions import RequestValidationError
   
   @app.exception_handler(RequestValidationError)
   async def validation_exception_handler(request: Request, exc: RequestValidationError):
       errors = []
       for err in exc.errors():
           field = " → ".join(str(loc) for loc in err["loc"])
           errors.append({"field": field, "message": err["msg"], "type": err["type"]})
       
       logger.warning(f"Validation error on {request.method} {request.url}: {errors}")
       return JSONResponse(
           status_code=422,
           content={"detail": "Validation failed", "errors": errors},
       )
   ```

### Problem: Form Data vs JSON Body

```python
# If your endpoint expects JSON:
@router.post("/items/")
async def create_item(item: ItemCreate):  # Expects JSON body
    ...

# Client must send: Content-Type: application/json
# Sending form data → 422

# If your endpoint expects form data:
from fastapi import Form

@router.post("/login/")
async def login(username: str = Form(...), password: str = Form(...)):
    ...
# Client must send: Content-Type: application/x-www-form-urlencoded
```

---

## OpenAPI Schema Conflicts

### Problem: Duplicate Model Names

```python
# BAD — two models named "Item" in different modules
# app/schemas/v1.py
class Item(BaseModel): name: str

# app/schemas/v2.py
class Item(BaseModel): name: str; description: str

# OpenAPI will only show one, or show Item and Item1 — confusing

# GOOD — namespace models explicitly
class ItemV1(BaseModel): name: str
class ItemV2(BaseModel): name: str; description: str

# OR use model_config to set schema name
class Item(BaseModel):
    model_config = ConfigDict(json_schema_extra={"title": "ItemV2"})
```

### Problem: Circular Model References

```python
# This can cause infinite recursion in schema generation
class User(BaseModel):
    posts: list["Post"]

class Post(BaseModel):
    author: "User"  # Circular!

# Fix: use forward refs and model_rebuild
User.model_rebuild()
Post.model_rebuild()

# Or break the cycle with a simpler ref model
class PostSummary(BaseModel):
    id: int
    title: str

class UserWithPosts(BaseModel):
    id: int
    name: str
    posts: list[PostSummary]  # No circular ref
```

### Problem: Custom Types Not Serializable in Schema

```python
# BAD — custom type breaks OpenAPI schema
from decimal import Decimal

class Price(BaseModel):
    amount: Decimal  # Works but schema may be unclear

# GOOD — annotate for clear schema
from pydantic import Field

class Price(BaseModel):
    amount: float = Field(..., description="Price in USD", examples=[29.99])
```
