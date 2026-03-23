# Review: fastapi-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (positive:/negative: sub-keys).

Excellent FastAPI guide. Covers app structure (domain-based organization, lifespan events replacing deprecated on_event, router composition), path operations (Path/Query/Body parameters, status codes), Pydantic v2 models (ConfigDict, from_attributes, field_validator, model_validator, discriminated unions), dependency injection (Depends, yield dependencies, sub-dependencies, class-based deps), response handling (JSONResponse, StreamingResponse, FileResponse, response_model), authentication (OAuth2PasswordBearer with JWT, API key auth, scopes), middleware (CORS, BaseHTTPMiddleware, pure ASGI middleware), background tasks (built-in BackgroundTasks, Celery for heavy work, ARQ for async-native), WebSocket endpoints (ConnectionManager with rooms, heartbeat), database integration (SQLAlchemy async with asyncpg, async_sessionmaker, repository pattern), testing (TestClient sync, AsyncClient with ASGITransport, dependency overrides, factory fixtures), error handling (HTTPException, custom domain exception handlers), performance (async vs sync def, pool tuning, fastapi-cache with Redis), and deployment (uvicorn/gunicorn, multi-stage Dockerfile, health checks, pydantic-settings).
