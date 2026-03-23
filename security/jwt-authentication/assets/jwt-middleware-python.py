"""
Production-ready FastAPI / Starlette JWT Authentication Middleware

Features:
  - JWKS endpoint support with in-memory caching (httpx)
  - Algorithm pinning (RS256) to prevent algorithm confusion attacks
  - Standard claim validations: exp, nbf, iss, aud
  - FastAPI dependency-injection pattern
  - Proper HTTP error responses (401 / 403)
  - Full type hints throughout

Dependencies:
  pip install PyJWT[crypto] httpx fastapi uvicorn
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Optional, Sequence

import httpx
import jwt
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient, PyJWKClientError

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

# Pluggable blocklist checker: receives the JTI and returns True if revoked.
BlocklistChecker = Callable[[str], Awaitable[bool]]


@dataclass(frozen=True)
class AuthUser:
    """Claims extracted from a verified JWT, attached to the request state."""

    sub: str
    iss: str
    aud: str | list[str]
    exp: int
    iat: int
    scopes: list[str] = field(default_factory=list)
    raw_claims: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# JWKS cache
# ---------------------------------------------------------------------------


class CachedJWKSClient:
    """
    Thin wrapper around PyJWKClient that adds a time-based cache so we don't
    hit the JWKS endpoint on every request.
    """

    def __init__(self, jwks_uri: str, cache_ttl_sec: int = 600) -> None:
        self._jwks_uri = jwks_uri
        self._cache_ttl_sec = cache_ttl_sec
        # PyJWKClient has its own internal cache with a configurable lifespan.
        self._client = PyJWKClient(
            uri=jwks_uri,
            cache_jwk_set=True,
            lifespan=cache_ttl_sec,
        )

    def get_signing_key(self, token: str) -> jwt.algorithms.RSAPublicKey:
        """Return the public key matching the token's ``kid`` header."""
        signing_key = self._client.get_signing_key_from_jwt(token)
        return signing_key.key


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


@dataclass
class JWTConfig:
    """Configuration for the JWT verifier."""

    # URL of the JWKS endpoint
    jwks_uri: str
    # Expected ``iss`` claim
    issuer: str
    # Expected ``aud`` claim(s)
    audience: str | list[str]
    # Allowed signing algorithms – restrict to prevent confusion attacks
    algorithms: list[str] = field(default_factory=lambda: ["RS256"])
    # Clock skew tolerance in seconds
    leeway_sec: int = 0
    # JWKS cache TTL in seconds
    jwks_cache_ttl_sec: int = 600
    # Optional blocklist checker for token revocation
    is_revoked: Optional[BlocklistChecker] = None


# ---------------------------------------------------------------------------
# Core verifier
# ---------------------------------------------------------------------------


class JWTVerifier:
    """
    Verifies JWTs using a remote JWKS endpoint.

    Usage with FastAPI dependency injection::

        config = JWTConfig(
            jwks_uri="https://auth.example.com/.well-known/jwks.json",
            issuer="https://auth.example.com/",
            audience="my-api",
        )
        verifier = JWTVerifier(config)

        @app.get("/api/me")
        async def me(user: AuthUser = Depends(verifier.get_current_user)):
            return {"sub": user.sub, "scopes": user.scopes}
    """

    def __init__(self, config: JWTConfig) -> None:
        self._config = config
        self._jwks_client = CachedJWKSClient(
            jwks_uri=config.jwks_uri,
            cache_ttl_sec=config.jwks_cache_ttl_sec,
        )

    # -- FastAPI dependency injection entry point ----------------------------

    async def get_current_user(
        self,
        request: Request,
        credentials: HTTPAuthorizationCredentials = Depends(HTTPBearer(auto_error=True)),
    ) -> AuthUser:
        """
        FastAPI dependency that extracts and verifies the JWT from the
        ``Authorization: Bearer <token>`` header, returning an ``AuthUser``.
        """
        token = credentials.credentials
        user = await self._verify_token(token)
        # Also store on request.state for middleware / downstream access.
        request.state.user = user
        return user

    # -- Token verification --------------------------------------------------

    async def _verify_token(self, token: str) -> AuthUser:
        """
        Decode and verify a raw JWT string.

        Raises ``HTTPException`` with 401 for all verification failures.
        """
        try:
            # 1. Fetch the signing key that matches the token's ``kid``.
            signing_key = self._jwks_client.get_signing_key(token)

            # 2. Decode and verify signature + standard claims.
            payload: dict[str, Any] = jwt.decode(
                token,
                signing_key,
                algorithms=self._config.algorithms,
                issuer=self._config.issuer,
                audience=self._config.audience,
                leeway=self._config.leeway_sec,
                options={
                    "require": ["exp", "iat", "iss", "aud", "sub"],
                    "verify_exp": True,
                    "verify_nbf": True,
                    "verify_iss": True,
                    "verify_aud": True,
                },
            )

            # 3. Check blocklist (if configured).
            jti = payload.get("jti")
            if self._config.is_revoked and jti:
                if await self._config.is_revoked(jti):
                    raise HTTPException(
                        status_code=status.HTTP_401_UNAUTHORIZED,
                        detail="Token has been revoked",
                    )

            return self._build_user(payload)

        except jwt.ExpiredSignatureError:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Token has expired",
            )
        except jwt.ImmatureSignatureError:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Token is not yet valid (nbf)",
            )
        except jwt.InvalidIssuerError:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid token issuer",
            )
        except jwt.InvalidAudienceError:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid token audience",
            )
        except (jwt.InvalidTokenError, PyJWKClientError) as exc:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=f"Invalid token: {exc}",
            )

    # -- Helpers -------------------------------------------------------------

    @staticmethod
    def _build_user(payload: dict[str, Any]) -> AuthUser:
        """Map a decoded JWT payload to an ``AuthUser`` instance."""
        scopes = _extract_scopes(payload)
        return AuthUser(
            sub=payload["sub"],
            iss=payload["iss"],
            aud=payload["aud"],
            exp=payload["exp"],
            iat=payload["iat"],
            scopes=scopes,
            raw_claims=payload,
        )


# ---------------------------------------------------------------------------
# Scope-checking dependency
# ---------------------------------------------------------------------------


def require_scopes(*required: str) -> Callable[..., Awaitable[AuthUser]]:
    """
    FastAPI dependency factory that ensures the user has **all** specified scopes.

    Usage::

        @app.delete(
            "/api/users/{user_id}",
            dependencies=[Depends(require_scopes("admin", "users:delete"))],
        )
        async def delete_user(user_id: str):
            ...
    """

    async def _checker(
        user: AuthUser = Depends(_get_verifier_stub),
    ) -> AuthUser:
        missing = [s for s in required if s not in user.scopes]
        if missing:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Insufficient scope. Missing: {', '.join(missing)}",
            )
        return user

    return _checker


# A sentinel — in practice, wire this up with your actual verifier instance.
async def _get_verifier_stub() -> AuthUser:
    """
    Placeholder dependency.  Override this in your app by providing the real
    ``JWTVerifier.get_current_user`` dependency via FastAPI's dependency
    override mechanism or by constructing ``require_scopes`` with your
    verifier instance.
    """
    raise NotImplementedError(
        "Wire up JWTVerifier.get_current_user as a dependency override"
    )


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _extract_scopes(payload: dict[str, Any]) -> list[str]:
    """
    Extract scopes from a JWT payload. Handles both space-delimited strings
    (OAuth 2.0 convention) and JSON arrays.
    """
    raw = payload.get("scope") or payload.get("scopes")
    if isinstance(raw, list):
        return [str(s) for s in raw]
    if isinstance(raw, str):
        return [s for s in raw.split(" ") if s]
    return []


# ---------------------------------------------------------------------------
# Example application wiring
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    from fastapi import FastAPI

    app = FastAPI(title="JWT Auth Example")

    config = JWTConfig(
        jwks_uri="https://auth.example.com/.well-known/jwks.json",
        issuer="https://auth.example.com/",
        audience="my-api",
    )
    verifier = JWTVerifier(config)

    @app.get("/api/me")
    async def me(user: AuthUser = Depends(verifier.get_current_user)):
        return {"sub": user.sub, "scopes": user.scopes}

    @app.get("/api/admin")
    async def admin(user: AuthUser = Depends(require_scopes("admin"))):
        return {"message": f"Hello admin {user.sub}"}

    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
