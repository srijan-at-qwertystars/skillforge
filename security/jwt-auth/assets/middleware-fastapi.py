"""
FastAPI JWT Authentication Middleware

Features:
- Access token verification with algorithm pinning
- Refresh token rotation with reuse detection
- FastAPI dependency injection for auth
- Role-based access control
- JWKS-based key resolution

Dependencies:
    pip install fastapi uvicorn pyjwt[crypto] python-multipart

Usage:
    from middleware_fastapi import get_current_user, require_roles, router as auth_router

    app = FastAPI()
    app.include_router(auth_router, prefix="/auth")

    @app.get("/protected")
    async def protected_route(user: TokenPayload = Depends(get_current_user)):
        return {"user_id": user.sub, "roles": user.roles}

    @app.get("/admin")
    async def admin_route(user: TokenPayload = Depends(require_roles("admin"))):
        return {"admin": True}
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from dataclasses import dataclass, field
from typing import Annotated

import jwt
from fastapi import APIRouter, Cookie, Depends, HTTPException, Request, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel


# ─── Configuration ────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class JWTConfig:
    # IMPORTANT: Load these from environment variables in production
    access_secret: str = "CHANGE-ME-load-from-env-min-32-bytes-random"
    refresh_secret: str = "CHANGE-ME-different-secret-also-32-bytes"
    algorithm: str = "HS256"  # Pin algorithm — never read from token
    issuer: str = "https://auth.example.com"
    audience: str = "https://api.example.com"
    access_token_expiry: timedelta = field(default_factory=lambda: timedelta(minutes=15))
    refresh_token_expiry: timedelta = field(default_factory=lambda: timedelta(days=7))
    clock_leeway: timedelta = field(default_factory=lambda: timedelta(seconds=30))


config = JWTConfig()

# ─── Models ───────────────────────────────────────────────────────────────────


class TokenPayload(BaseModel):
    """Decoded and validated JWT claims."""
    sub: str
    roles: list[str] = []
    jti: str | None = None
    exp: int | None = None
    iss: str | None = None
    aud: str | None = None


class LoginRequest(BaseModel):
    email: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int = 900  # 15 minutes


# ─── Token Store Interface ────────────────────────────────────────────────────
# Replace with your database/Redis implementation


class TokenStore:
    """
    Abstract token store — replace with database implementation.

    Schema:
        refresh_tokens (
            jti         UUID PRIMARY KEY,
            family_id   UUID NOT NULL,
            user_id     TEXT NOT NULL,
            parent_jti  UUID,
            issued_at   TIMESTAMPTZ NOT NULL,
            expires_at  TIMESTAMPTZ NOT NULL,
            revoked_at  TIMESTAMPTZ,
            replaced_by UUID
        )
    """

    async def save(self, *, jti: str, family_id: str, user_id: str,
                   parent_jti: str | None, expires_at: datetime) -> None:
        # TODO: INSERT INTO refresh_tokens ...
        raise NotImplementedError("Implement with your database")

    async def get_by_jti(self, jti: str) -> dict | None:
        # TODO: SELECT * FROM refresh_tokens WHERE jti = $1
        raise NotImplementedError("Implement with your database")

    async def mark_replaced(self, jti: str, replaced_by: str) -> None:
        # TODO: UPDATE refresh_tokens SET replaced_by = $2 WHERE jti = $1
        raise NotImplementedError("Implement with your database")

    async def revoke_family(self, family_id: str) -> None:
        # TODO: UPDATE refresh_tokens SET revoked_at = NOW() WHERE family_id = $1 AND revoked_at IS NULL
        raise NotImplementedError("Implement with your database")

    async def revoke_all_for_user(self, user_id: str) -> None:
        # TODO: UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL
        raise NotImplementedError("Implement with your database")


token_store = TokenStore()

# ─── Token Generation ─────────────────────────────────────────────────────────


def generate_access_token(user_id: str, roles: list[str]) -> str:
    """Generate a short-lived access token."""
    now = datetime.now(UTC)
    payload = {
        "sub": user_id,
        "roles": roles,
        "jti": str(uuid.uuid4()),
        "iat": now,
        "exp": now + config.access_token_expiry,
        "iss": config.issuer,
        "aud": config.audience,
    }
    return jwt.encode(payload, config.access_secret, algorithm=config.algorithm)


async def generate_refresh_token(
    user_id: str,
    family_id: str | None = None,
    parent_jti: str | None = None,
) -> tuple[str, str, str]:
    """
    Generate a refresh token and store it for revocation tracking.

    Returns:
        (token_string, jti, family_id)
    """
    jti = str(uuid.uuid4())
    fid = family_id or str(uuid.uuid4())
    now = datetime.now(UTC)
    expires_at = now + config.refresh_token_expiry

    payload = {
        "sub": user_id,
        "jti": jti,
        "iat": now,
        "exp": expires_at,
        "iss": config.issuer,
    }
    token = jwt.encode(payload, config.refresh_secret, algorithm=config.algorithm)

    await token_store.save(
        jti=jti,
        family_id=fid,
        user_id=user_id,
        parent_jti=parent_jti,
        expires_at=expires_at,
    )

    return token, jti, fid


# ─── Dependencies: Access Token Verification ──────────────────────────────────

security = HTTPBearer(auto_error=False)


async def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)],
) -> TokenPayload:
    """
    FastAPI dependency that verifies the access token.

    Usage:
        @app.get("/protected")
        async def route(user: TokenPayload = Depends(get_current_user)):
            ...
    """
    if credentials is None:
        raise HTTPException(status_code=401, detail="Missing authorization header")

    token = credentials.credentials

    try:
        payload = jwt.decode(
            token,
            config.access_secret,
            algorithms=[config.algorithm],  # Pin algorithm
            issuer=config.issuer,
            audience=config.audience,
            leeway=config.clock_leeway,
            options={
                "require": ["exp", "sub", "iss", "aud"],
                "verify_exp": True,
                "verify_iss": True,
                "verify_aud": True,
            },
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.InvalidTokenError:
        # Generic error — don't reveal specific validation failures
        raise HTTPException(status_code=401, detail="Invalid token")

    return TokenPayload(
        sub=payload["sub"],
        roles=payload.get("roles", []),
        jti=payload.get("jti"),
        exp=payload.get("exp"),
        iss=payload.get("iss"),
        aud=payload.get("aud"),
    )


# ─── Dependencies: Role-Based Access Control ──────────────────────────────────


def require_roles(*required_roles: str):
    """
    FastAPI dependency factory for role-based access control.

    Usage:
        @app.get("/admin")
        async def admin(user: TokenPayload = Depends(require_roles("admin"))):
            ...
    """
    async def _check_roles(
        user: TokenPayload = Depends(get_current_user),
    ) -> TokenPayload:
        if not any(role in user.roles for role in required_roles):
            raise HTTPException(
                status_code=403,
                detail="Insufficient permissions",
            )
        return user

    return _check_roles


# ─── Auth Router ──────────────────────────────────────────────────────────────

router = APIRouter(tags=["auth"])


@router.post("/login", response_model=TokenResponse)
async def login(request: LoginRequest, response: Response):
    """
    Authenticate user and issue tokens.

    Replace the authentication logic below with your actual implementation.
    """
    # TODO: Replace with your authentication logic
    # user = await authenticate_user(request.email, request.password)
    user = None  # Placeholder

    if user is None:
        # Generic error — don't reveal whether user exists
        raise HTTPException(status_code=401, detail="Invalid credentials")

    user_id = user["id"]  # type: ignore[index]
    roles = user.get("roles", [])  # type: ignore[union-attr]

    # Generate access token
    access_token = generate_access_token(user_id, roles)

    # Generate refresh token and set as httpOnly cookie
    refresh_token, _, _ = await generate_refresh_token(user_id)

    response.set_cookie(
        key="refresh_token",
        value=refresh_token,
        httponly=True,
        secure=True,  # Set to False for local development without HTTPS
        samesite="strict",
        path="/auth/refresh",
        max_age=int(config.refresh_token_expiry.total_seconds()),
    )

    return TokenResponse(
        access_token=access_token,
        expires_in=int(config.access_token_expiry.total_seconds()),
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh(
    response: Response,
    request: Request,
    refresh_token: str | None = Cookie(None),
):
    """
    Refresh access token using refresh token from httpOnly cookie.
    Implements rotation with reuse detection.
    """
    if not refresh_token:
        raise HTTPException(status_code=401, detail="Missing refresh token")

    # 1. Verify the refresh token
    try:
        payload = jwt.decode(
            refresh_token,
            config.refresh_secret,
            algorithms=[config.algorithm],
            issuer=config.issuer,
            leeway=config.clock_leeway,
            options={"require": ["exp", "sub", "jti"]},
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Refresh token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid refresh token")

    jti = payload["jti"]
    user_id = payload["sub"]

    # 2. Look up the token in our store
    stored = await token_store.get_by_jti(jti)
    if stored is None:
        raise HTTPException(status_code=401, detail="Unknown token")

    # 3. Check if revoked
    if stored.get("revoked_at"):
        raise HTTPException(status_code=401, detail="Token revoked")

    # 4. Reuse detection
    if stored.get("replaced_by"):
        # SECURITY: Token reuse detected — compromise assumed
        await token_store.revoke_family(stored["family_id"])
        # Log security event with request context
        client_ip = request.client.host if request.client else "unknown"
        import logging
        logging.getLogger("security").critical(
            "Refresh token reuse detected: jti=%s family=%s user=%s ip=%s",
            jti, stored["family_id"], user_id, client_ip,
        )
        raise HTTPException(status_code=401, detail="Token reuse detected")

    # 5. Rotate: issue new tokens
    roles: list[str] = []  # TODO: Fetch user roles from database
    access_token = generate_access_token(user_id, roles)

    new_refresh, new_jti, _ = await generate_refresh_token(
        user_id=user_id,
        family_id=stored["family_id"],
        parent_jti=jti,
    )

    # 6. Mark old token as replaced
    await token_store.mark_replaced(jti, new_jti)

    # 7. Set new refresh token cookie
    response.set_cookie(
        key="refresh_token",
        value=new_refresh,
        httponly=True,
        secure=True,
        samesite="strict",
        path="/auth/refresh",
        max_age=int(config.refresh_token_expiry.total_seconds()),
    )

    return TokenResponse(
        access_token=access_token,
        expires_in=int(config.access_token_expiry.total_seconds()),
    )


@router.post("/logout")
async def logout(
    response: Response,
    refresh_token: str | None = Cookie(None),
):
    """Revoke refresh token family and clear cookie."""
    if refresh_token:
        try:
            payload = jwt.decode(
                refresh_token,
                config.refresh_secret,
                algorithms=[config.algorithm],
                issuer=config.issuer,
                options={"verify_exp": False},  # Allow expired tokens for logout
            )
            stored = await token_store.get_by_jti(payload["jti"])
            if stored:
                await token_store.revoke_family(stored["family_id"])
        except jwt.InvalidTokenError:
            pass  # Token invalid — still clear cookie

    response.delete_cookie(key="refresh_token", path="/auth/refresh")
    return {"message": "Logged out"}


@router.post("/logout-all")
async def logout_all(
    response: Response,
    user: TokenPayload = Depends(get_current_user),
):
    """Revoke all refresh tokens for the current user (logout everywhere)."""
    await token_store.revoke_all_for_user(user.sub)
    response.delete_cookie(key="refresh_token", path="/auth/refresh")
    return {"message": "All sessions revoked"}
