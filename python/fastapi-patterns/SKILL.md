---
name: fastapi-patterns
description:
  positive: "Use when user builds APIs with FastAPI, asks about path operations, dependency injection, Pydantic models, response models, middleware, background tasks, WebSockets, or FastAPI deployment."
  negative: "Do NOT use for Django REST Framework, Flask, or general Python web (use python-async-concurrency for async patterns without FastAPI context)."
---

# FastAPI Patterns & Best Practices

## App Structure

Organize by domain, not file type. Each domain module owns its router, schemas, models, and service layer.

```
app/
├── main.py              # App factory, lifespan
├── core/
│   ├── config.py        # BaseSettings, env loading
│   └── security.py      # Auth helpers
├── users/
│   ├── router.py
│   ├── schemas.py       # Pydantic models
│   ├── models.py        # ORM models
│   ├── service.py       # Business logic
│   └── repository.py    # DB access
└── db/
    └── session.py       # Engine, session factory
```

### Lifespan Events

Replace deprecated `@app.on_event`. Use `asynccontextmanager`:

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI

@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.db_pool = await create_pool()  # Startup
    yield
    await app.state.db_pool.close()          # Shutdown

app = FastAPI(lifespan=lifespan)
```

### Router Composition

```python
router = APIRouter(prefix="/users", tags=["users"])

@router.get("/")
async def list_users(): ...

# main.py — mount with version prefix
app.include_router(router, prefix="/api/v1")
```

## Path Operations

```python
from fastapi import Path, Query, Body

@router.get("/{user_id}")
async def get_user(user_id: int = Path(..., gt=0), include_email: bool = Query(False)): ...

@router.post("/", status_code=201)
async def create_user(user: UserCreate = Body(...)): ...

@router.put("/{user_id}")
async def update_user(user_id: int, user: UserUpdate): ...

@router.delete("/{user_id}", status_code=204)
async def delete_user(user_id: int): ...
```

## Pydantic v2 Models

```python
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

class UserBase(BaseModel):
    model_config = ConfigDict(from_attributes=True, strict=True)
    name: str = Field(..., min_length=1, max_length=100)
    email: str

class UserCreate(UserBase):
    password: str = Field(..., min_length=8)

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        if "@" not in v:
            raise ValueError("Invalid email")
        return v.lower()

class UserRead(UserBase):
    id: int
```

### model_validator (Cross-Field)

```python
class DateRange(BaseModel):
    start: date
    end: date

    @model_validator(mode="after")
    def check_range(self) -> "DateRange":
        if self.start >= self.end:
            raise ValueError("start must precede end")
        return self
```

### Discriminated Unions

```python
from typing import Annotated, Literal, Union

class EmailNotif(BaseModel):
    type: Literal["email"]
    address: str

class SMSNotif(BaseModel):
    type: Literal["sms"]
    phone: str

Notification = Annotated[Union[EmailNotif, SMSNotif], Field(discriminator="type")]
```

## Dependency Injection

```python
from fastapi import Depends

# Yield dependency — session auto-closes after request
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_maker() as session:
        yield session

@router.get("/")
async def list_users(db: AsyncSession = Depends(get_db)): ...
```

### Sub-Dependencies

```python
async def get_current_user(
    token: str = Depends(oauth2_scheme), db: AsyncSession = Depends(get_db),
) -> User:
    user = await authenticate(token, db)
    if not user:
        raise HTTPException(401, "Invalid credentials")
    return user

async def get_admin_user(user: User = Depends(get_current_user)) -> User:
    if user.role != "admin":
        raise HTTPException(403, "Admin required")
    return user
```

### Class-Based Dependencies

```python
class Pagination:
    def __init__(self, skip: int = Query(0, ge=0), limit: int = Query(20, le=100)):
        self.skip = skip
        self.limit = limit
```

## Response Handling

```python
from fastapi.responses import JSONResponse, StreamingResponse, FileResponse

@router.get("/users", response_model=list[UserRead])
async def list_users(): ...

@router.post("/users", response_model=UserRead, status_code=201)
async def create_user(): ...

@router.get("/download")
async def download():
    return StreamingResponse((chunk async for chunk in generate()), media_type="application/octet-stream")

@router.get("/file")
async def serve_file():
    return FileResponse("report.pdf", filename="report.pdf")
```

## Authentication

### OAuth2 + JWT

```python
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import jwt

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")

@router.post("/auth/token")
async def login(form: OAuth2PasswordRequestForm = Depends()):
    user = await authenticate_user(form.username, form.password)
    if not user:
        raise HTTPException(400, "Incorrect credentials")
    token = jwt.encode({"sub": user.id, "exp": expire}, SECRET, algorithm="HS256")
    return {"access_token": token, "token_type": "bearer"}
```

### API Key Auth

```python
from fastapi.security import APIKeyHeader
api_key_header = APIKeyHeader(name="X-API-Key")

async def verify_api_key(key: str = Depends(api_key_header)):
    if key != settings.API_KEY:
        raise HTTPException(403, "Invalid API key")
```

### Scopes

Use `SecurityScopes` parameter alongside `OAuth2PasswordBearer(scopes={"read": "Read", "write": "Write"})` to enforce per-endpoint scope requirements.

## Middleware

### CORS

```python
from fastapi.middleware.cors import CORSMiddleware
app.add_middleware(CORSMiddleware, allow_origins=["https://example.com"],
                   allow_methods=["*"], allow_headers=["*"], allow_credentials=True)
```

### Custom Middleware (BaseHTTPMiddleware)

```python
from starlette.middleware.base import BaseHTTPMiddleware

class TimingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        response.headers["X-Process-Time"] = f"{time.perf_counter() - start:.4f}"
        return response
```

### Pure ASGI Middleware (Better Performance)

Implement `__init__(self, app: ASGIApp)` and `__call__(self, scope, receive, send)`. Check `scope["type"] == "http"`, mutate state, then `await self.app(scope, receive, send)`.

## Background Tasks

### Built-in BackgroundTasks

Fire-and-forget. Not crash-resilient. Use for emails, logging.

```python
@router.post("/register")
async def register(user: UserCreate, bg: BackgroundTasks):
    new_user = await create_user(user)
    bg.add_task(send_email, new_user.email, "Welcome!")
    return new_user
```

### Celery (Heavy/CPU-Bound)

```python
celery_app = Celery("worker", broker="redis://localhost:6379/0")

@celery_app.task
def generate_report(user_id: int): ...

@router.post("/reports")
async def request_report(user_id: int):
    task = generate_report.delay(user_id)
    return {"task_id": task.id}

@router.get("/reports/{task_id}")
async def get_report_status(task_id: str):
    result = celery_app.AsyncResult(task_id)
    return {"status": result.status, "result": result.result}
```

### ARQ (Async-Native)

Use `arq.create_pool(RedisSettings())` to enqueue jobs. Define worker functions as `async def task(ctx, ...)`. Lighter than Celery, native async/await.

## WebSocket Endpoints

### Connection Manager with Rooms

```python
class ConnectionManager:
    def __init__(self):
        self.rooms: dict[str, list[WebSocket]] = {}

    async def connect(self, room: str, ws: WebSocket):
        await ws.accept()
        self.rooms.setdefault(room, []).append(ws)

    def disconnect(self, room: str, ws: WebSocket):
        self.rooms.get(room, []).remove(ws)

    async def broadcast(self, room: str, message: dict):
        for ws in self.rooms.get(room, []):
            await ws.send_json(message)

manager = ConnectionManager()

@router.websocket("/ws/{room}")
async def websocket_endpoint(ws: WebSocket, room: str):
    await manager.connect(room, ws)
    try:
        while True:
            data = await ws.receive_json()
            await manager.broadcast(room, data)
    except WebSocketDisconnect:
        manager.disconnect(room, ws)
```

### Heartbeat

Spawn `asyncio.create_task` inside the WebSocket handler to send periodic pings. Cancel the task on `WebSocketDisconnect`.

## Database Integration (SQLAlchemy Async)

```python
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker

engine = create_async_engine("postgresql+asyncpg://user:pass@localhost/db",
    pool_size=20, max_overflow=10, pool_pre_ping=True, pool_recycle=3600)
async_session_maker = async_sessionmaker(engine, expire_on_commit=False)

async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_maker() as session:
        yield session
```

### Repository Pattern

```python
class UserRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def get_by_id(self, user_id: int) -> User | None:
        result = await self.session.execute(select(User).where(User.id == user_id))
        return result.scalar_one_or_none()

    async def create(self, user: User) -> User:
        self.session.add(user)
        await self.session.commit()
        await self.session.refresh(user)
        return user

def get_user_repo(db: AsyncSession = Depends(get_db)) -> UserRepository:
    return UserRepository(db)
```

## Testing

```python
# Sync — TestClient
client = TestClient(app)
def test_read_users():
    assert client.get("/api/v1/users").status_code == 200

# Async — httpx + ASGITransport
@pytest.fixture
async def async_client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac

@pytest.mark.anyio
async def test_create_user(async_client):
    resp = await async_client.post("/api/v1/users", json={"name": "Jo", "email": "j@x.com"})
    assert resp.status_code == 201
```

### Dependency Overrides

```python
async def override_get_db():
    async with test_session_maker() as session:
        yield session

app.dependency_overrides[get_db] = override_get_db
# After tests:
app.dependency_overrides.clear()
```

### Factory Fixtures

Create `@pytest.fixture` returning an async factory function that builds and commits test entities with overridable defaults.

## Error Handling

```python
# Built-in
raise HTTPException(status_code=404, detail="User not found")

# Custom domain errors
class DomainError(Exception):
    def __init__(self, message: str, code: str):
        self.message = message
        self.code = code

@app.exception_handler(DomainError)
async def domain_error_handler(request, exc: DomainError):
    return JSONResponse(status_code=400, content={"error": exc.code, "message": exc.message})

@app.exception_handler(RequestValidationError)
async def validation_handler(request, exc):
    return JSONResponse(status_code=422, content={"detail": exc.errors()})
```

## Performance

- Use `async def` for I/O-bound endpoints. Use `def` (sync) for CPU-bound — FastAPI runs it in a threadpool.
- Never call blocking I/O inside `async def` without `run_in_executor`.
- Tune pool: `pool_size`, `max_overflow`, `pool_pre_ping`, `pool_recycle` (see Database section).
- Use `fastapi-cache` with Redis for endpoint caching:

```python
from fastapi_cache.decorator import cache

@router.get("/stats")
@cache(expire=60)
async def get_stats(): return await compute_stats()
```

- Profile with `py-spy` or `yappi`. Use OpenTelemetry for distributed tracing.

## Deployment

```bash
# Development
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

# Production — set workers to CPU core count, --preload shares memory
gunicorn app.main:app -k uvicorn.workers.UvicornWorker \
  --workers 4 --bind 0.0.0.0:8000 --timeout 120 --preload
```

### Dockerfile

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY . .
EXPOSE 8000
USER nobody
CMD ["gunicorn", "app.main:app", "-k", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8000", "--workers", "4"]
```

### Health Checks

```python
@app.get("/healthz")
async def health():
    return {"status": "ok"}

@app.get("/readyz")
async def readiness(db: AsyncSession = Depends(get_db)):
    await db.execute(text("SELECT 1"))
    return {"status": "ready"}
```

```yaml
# docker-compose healthcheck
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8000/healthz"]
  interval: 30s
  timeout: 5s
  retries: 3
```

### Settings

```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    model_config = ConfigDict(env_file=".env")
    DATABASE_URL: str
    SECRET_KEY: str
    DEBUG: bool = False
    WORKERS: int = 4

settings = Settings()

<!-- tested: pass -->
```
