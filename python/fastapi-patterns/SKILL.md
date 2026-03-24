---
name: fastapi-patterns
description: >
  USE when writing FastAPI web applications, REST APIs, ASGI services, or async Python web servers.
  TRIGGER on imports of fastapi, starlette, uvicorn, or usage of APIRouter, Depends, HTTPException,
  BackgroundTasks, WebSocket, UploadFile, OAuth2PasswordBearer, or FastAPI app instantiation.
  TRIGGER when user asks to build an API, web service, endpoint, or microservice in Python using FastAPI.
  DO NOT trigger for Pydantic-only validation or schemas without FastAPI (use pydantic-patterns instead).
  DO NOT trigger for Django, Flask, or other Python web frameworks.
  DO NOT trigger for general async Python without FastAPI context.
  Covers: path operations, dependency injection, auth, middleware, WebSockets, file uploads,
  database integration, testing, deployment, project structure, and performance patterns.
---

# FastAPI Patterns

## App Instantiation and Lifespan

Create the app with a lifespan context manager. Never use deprecated `@app.on_event`.

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: init DB pools, load ML models, start caches
    app.state.db_engine = create_async_engine(settings.database_url)
    yield
    # Shutdown: dispose connections, flush buffers
    await app.state.db_engine.dispose()

app = FastAPI(
    title="My API",
    version="1.0.0",
    lifespan=lifespan,
)
```

## Path Operations

Use HTTP method decorators. Always set `status_code` for non-200 and `response_model` for type safety.

```python
from fastapi import APIRouter, status
from pydantic import BaseModel

router = APIRouter(prefix="/items", tags=["items"])

class ItemCreate(BaseModel):
    name: str
    price: float

class ItemResponse(BaseModel):
    id: int
    name: str
    price: float
    model_config = {"from_attributes": True}

@router.post("/", response_model=ItemResponse, status_code=status.HTTP_201_CREATED)
async def create_item(item: ItemCreate): ...

@router.get("/{item_id}", response_model=ItemResponse)
async def get_item(item_id: int): ...
```

## Path Parameters, Query Parameters, Request Body

```python
from fastapi import Query, Path

@router.get("/search")
async def search_items(
    q: str = Query(..., min_length=1, max_length=100),
    skip: int = Query(0, ge=0),
    limit: int = Query(20, ge=1, le=100),
    category: str | None = None,
): ...

@router.get("/{item_id}")
async def get_item(item_id: int = Path(..., gt=0)): ...
```

## Dependency Injection

Use `Depends` for reusable logic — functions, classes, or generators.

```python
from fastapi import Depends

def common_params(skip: int = 0, limit: int = 100):
    return {"skip": skip, "limit": limit}

@router.get("/")
async def list_items(params: dict = Depends(common_params)): ...

# Yield dependency for resource cleanup
async def get_db():
    async with SessionLocal() as session:
        yield session

@router.get("/users")
async def list_users(db: AsyncSession = Depends(get_db)):
    return (await db.execute(select(User))).scalars().all()

# Sub-dependencies chain automatically
async def get_current_user(token: str = Depends(oauth2_scheme), db=Depends(get_db)):
    return (await db.execute(select(User).where(User.token == token))).scalar_one_or_none()
```

## Authentication and Security

### OAuth2 with JWT

```python
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import jwt, JWTError
from passlib.context import CryptContext

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
SECRET_KEY = "load-from-env"  # Use pydantic-settings in production
ALGORITHM = "HS256"

def create_access_token(data: dict, expires_delta: timedelta | None = None):
    to_encode = data.copy()
    to_encode["exp"] = datetime.utcnow() + (expires_delta or timedelta(minutes=30))
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

async def get_current_user(token: str = Depends(oauth2_scheme)):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id = payload.get("sub")
        if not user_id:
            raise HTTPException(status_code=401, detail="Invalid token")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
    return await fetch_user(user_id)

@router.post("/auth/token")
async def login(form_data: OAuth2PasswordRequestForm = Depends()):
    user = await authenticate_user(form_data.username, form_data.password)
    if not user:
        raise HTTPException(status_code=401, detail="Incorrect credentials")
    return {"access_token": create_access_token({"sub": str(user.id)}), "token_type": "bearer"}
```

### API Key Authentication

```python
from fastapi.security import APIKeyHeader
api_key_header = APIKeyHeader(name="X-API-Key")

async def verify_api_key(key: str = Depends(api_key_header)):
    if key not in VALID_API_KEYS:
        raise HTTPException(status_code=403, detail="Invalid API key")
```

## Middleware

### CORS, Trusted Hosts
```python
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware

app.add_middleware(CORSMiddleware,
    allow_origins=["https://example.com"],  # Never ["*"] in production
    allow_credentials=True, allow_methods=["*"], allow_headers=["*"])
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["example.com", "*.example.com"])
```

### Custom Middleware

```python
from starlette.middleware.base import BaseHTTPMiddleware
import time

class TimingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        response.headers["X-Process-Time"] = str(time.perf_counter() - start)
        return response

app.add_middleware(TimingMiddleware)
```

For high-performance middleware, use pure ASGI middleware instead of `BaseHTTPMiddleware`.

## Background Tasks

```python
from fastapi import BackgroundTasks

def send_notification(email: str, message: str): ...

@router.post("/orders/", status_code=201)
async def create_order(order: OrderCreate, background_tasks: BackgroundTasks):
    new_order = await save_order(order)
    background_tasks.add_task(send_notification, order.email, "Order confirmed")
    return new_order
```

For CPU-heavy or long-running jobs, use Celery or ARQ instead.

## WebSockets

```python
from fastapi import WebSocket, WebSocketDisconnect

class ConnectionManager:
    def __init__(self):
        self.active: list[WebSocket] = []
    async def connect(self, ws: WebSocket):
        await ws.accept(); self.active.append(ws)
    def disconnect(self, ws: WebSocket):
        self.active.remove(ws)
    async def broadcast(self, msg: str):
        for c in self.active: await c.send_text(msg)

manager = ConnectionManager()

@app.websocket("/ws/{room}")
async def ws_endpoint(ws: WebSocket, room: str):
    await manager.connect(ws)
    try:
        while True:
            data = await ws.receive_text()
            await manager.broadcast(f"{room}: {data}")
    except WebSocketDisconnect:
        manager.disconnect(ws)
```

## File Uploads

Stream large files in chunks. Never load entire file into memory.

```python
from fastapi import UploadFile, File
import uuid; from pathlib import Path

@router.post("/upload/")
async def upload_file(file: UploadFile = File(...)):
    if file.content_type not in ["image/png", "image/jpeg", "application/pdf"]:
        raise HTTPException(status_code=400, detail="Invalid file type")
    dest = Path("uploads") / f"{uuid.uuid4()}{Path(file.filename).suffix}"
    with open(dest, "wb") as f:
        while chunk := await file.read(1024 * 1024):  # 1MB chunks
            f.write(chunk)
    return {"filename": dest.name, "size": dest.stat().st_size}
```

Multiple files: `files: list[UploadFile] = File(...)`.

## Response Models and Custom Responses

```python
from fastapi.responses import StreamingResponse

@router.get("/items/{id}", response_model=ItemResponse, response_model_exclude_unset=True)
async def get_item(id: int): ...

@router.delete("/items/{id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_item(id: int): ...

@router.get("/export")  # Streaming for large data
async def export_csv():
    async def generate():
        yield "id,name\n"
        async for row in fetch_rows(): yield f"{row.id},{row.name}\n"
    return StreamingResponse(generate(), media_type="text/csv")
```

## Error Handling

```python
from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError

@router.get("/items/{id}")
async def get_item(id: int):
    item = await fetch_item(id)
    if not item:
        raise HTTPException(status_code=404, detail=f"Item {id} not found")
    return item

# Custom exception with handler
class AppException(Exception):
    def __init__(self, status_code: int, detail: str):
        self.status_code = status_code
        self.detail = detail

@app.exception_handler(AppException)
async def app_exc_handler(request: Request, exc: AppException):
    return JSONResponse(status_code=exc.status_code, content={"error": exc.detail})

@app.exception_handler(RequestValidationError)
async def validation_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(status_code=422,
        content={"errors": [{"field": e["loc"][-1], "msg": e["msg"]} for e in exc.errors()]})
```

## Database Integration (SQLAlchemy Async)

```python
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy.orm import DeclarativeBase

engine = create_async_engine("postgresql+asyncpg://user:pass@localhost/db",
    pool_size=10, max_overflow=20, pool_pre_ping=True)
SessionLocal = async_sessionmaker(bind=engine, class_=AsyncSession, expire_on_commit=False)

class Base(DeclarativeBase):
    pass

async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        yield session

# Repository pattern
class UserRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def get_by_id(self, user_id: int) -> User | None:
        result = await self.session.execute(select(User).where(User.id == user_id))
        return result.scalar_one_or_none()

    async def create(self, data: UserCreate) -> User:
        user = User(**data.model_dump())
        self.session.add(user)
        await self.session.commit()
        await self.session.refresh(user)
        return user

def get_user_repo(db: AsyncSession = Depends(get_db)) -> UserRepository:
    return UserRepository(db)
```

## Async Patterns

- Use `async def` for I/O-bound operations (DB, HTTP calls, file I/O).
- Use plain `def` for CPU-bound — FastAPI runs sync handlers in a threadpool automatically.
- Never call blocking code inside `async def`. Use `httpx` (not `requests`).

```python
import httpx

@router.get("/proxy")
async def proxy_request():
    async with httpx.AsyncClient() as client:
        resp = await client.get("https://api.example.com/data")
        return resp.json()

@router.get("/compute")
def heavy_compute():  # sync: auto-runs in threadpool
    return {"result": expensive_cpu_operation()}
```

## Testing

```python
from fastapi.testclient import TestClient

def test_read_items():
    with TestClient(app) as client:  # Context manager triggers lifespan events
        resp = client.get("/items/1")
        assert resp.status_code == 200

# Async testing with httpx
import pytest
from httpx import AsyncClient, ASGITransport

@pytest.fixture
async def async_client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c

@pytest.mark.anyio
async def test_create_item(async_client: AsyncClient):
    resp = await async_client.post("/items/", json={"name": "Widget", "price": 9.99})
    assert resp.status_code == 201

# Override dependencies for testing
app.dependency_overrides[get_db] = override_get_db
```

## Project Structure

Organize by layer. Group routers, services, repositories, models, and schemas separately.
```
app/
├── main.py           # App, lifespan, include_router
├── config.py         # pydantic-settings
├── database.py       # Engine, session, Base
├── dependencies.py   # get_db, get_current_user
├── models/           # SQLAlchemy models
├── schemas/          # Pydantic request/response models
├── routers/          # APIRouter modules (auth.py, users.py, items.py)
├── services/         # Business logic
├── repositories/     # Data access layer
└── tests/            # conftest.py, test_*.py
```

Register routers in `main.py`:

```python
app.include_router(auth.router)
app.include_router(users.router, prefix="/api/v1")
app.include_router(items.router, prefix="/api/v1")
```

## Settings Management

```python
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")
    database_url: str
    secret_key: str
    debug: bool = False
    allowed_origins: list[str] = ["http://localhost:3000"]

settings = Settings()  # Reads from env vars / .env file
```

## OpenAPI Customization

```python
app = FastAPI(
    title="My API", version="2.0.0",
    docs_url="/docs",       # Set to None to disable in production
    redoc_url="/redoc",
    openapi_tags=[{"name": "items", "description": "Item operations"}],
)

@router.get("/health", include_in_schema=False)  # Exclude from OpenAPI
async def health():
    return {"status": "ok"}
```

## Deployment

```bash
# Development
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

# Production (gunicorn + uvicorn workers)
gunicorn app.main:app -w 4 -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:8000
```

Dockerfile:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["gunicorn", "app.main:app", "-w", "4", "-k", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8000"]
```

## Performance

- Use `async def` for I/O-bound endpoints, `def` for CPU-bound (auto-threadpooled).
- Configure connection pooling: `pool_size`, `max_overflow`, `pool_pre_ping`.
- Cache with Redis or `cachetools`. Use cursor-based pagination over offset.
- Use `ORJSONResponse` for faster serialization. Set `response_model_exclude_unset=True`.

```python
from fastapi.responses import ORJSONResponse
app = FastAPI(default_response_class=ORJSONResponse)

# Cursor pagination
@router.get("/items/")
async def list_items(cursor: int | None = None, limit: int = Query(20, le=100),
                     db: AsyncSession = Depends(get_db)):
    query = select(Item).order_by(Item.id).limit(limit + 1)
    if cursor:
        query = query.where(Item.id > cursor)
    results = (await db.execute(query)).scalars().all()
    next_cursor = results[-1].id if len(results) > limit else None
    return {"items": results[:limit], "next_cursor": next_cursor}
```

## Common Pitfalls

1. **Blocking in async**: Never use `time.sleep()`, `requests`, or sync DB drivers in `async def`. Use `asyncio.sleep()`, `httpx`, async drivers.
2. **Missing `await`**: Forgetting `await` returns a coroutine object, not the result.
3. **Shared mutable state**: Avoid module-level mutable globals. Use `app.state` or DI.
4. **`expire_on_commit` not disabled**: Async SQLAlchemy requires `expire_on_commit=False`.
5. **CORS with credentials**: `allow_origins=["*"]` + `allow_credentials=True` is rejected by browsers.
6. **No response_model**: Always set it to prevent leaking internal fields.
7. **Large file in memory**: Use chunked `file.read(size)`, not `await file.read()` unbounded.
8. **BackgroundTasks for heavy work**: Shares the event loop. Use Celery/ARQ instead.
9. **Deprecated on_event**: Use `lifespan` context manager instead.
10. **TestClient without context manager**: Use `with TestClient(app) as client:` for lifespan.
10. **TestClient without context manager**: Use `with TestClient(app) as client:` for lifespan.