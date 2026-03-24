"""
fastapi-oauth2.py — FastAPI OAuth2 dependency injection template

Provides reusable dependencies for JWT-based OAuth2 token validation,
scope enforcement, and OIDC userinfo integration in FastAPI applications.

Usage:
    from fastapi_oauth2 import create_oauth2_deps

    oauth2 = create_oauth2_deps(
        issuer="https://auth.example.com",
        audience="https://api.example.com",
        jwks_url="https://auth.example.com/.well-known/jwks.json",
    )

    @app.get("/protected")
    async def protected(user: dict = Depends(oauth2.require_auth)):
        return {"message": f"Hello {user['sub']}"}

    @app.get("/admin")
    async def admin(user: dict = Depends(oauth2.require_scopes("admin:read"))):
        return {"admin_data": "..."}

Dependencies:
    pip install fastapi uvicorn python-jose[cryptography] httpx
"""

import time
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Optional

import httpx
from fastapi import Depends, HTTPException, Security, status
from fastapi.security import (
    HTTPAuthorizationCredentials,
    HTTPBearer,
    OAuth2AuthorizationCodeBearer,
    SecurityScopes,
)
from jose import JWTError, jwt
from jose.backends import RSAKey

# Security scheme for Swagger UI
bearer_scheme = HTTPBearer(auto_error=False)


@dataclass
class JWKSCache:
    """Caches JWKS keys with TTL and automatic refresh on unknown kid."""

    jwks_url: str
    ttl: int = 3600
    min_refresh_interval: int = 60
    _keys: dict = field(default_factory=dict, repr=False)
    _fetched_at: float = 0

    async def get_key(self, kid: str) -> dict:
        if kid in self._keys and not self._is_expired():
            return self._keys[kid]

        if time.time() - self._fetched_at < self.min_refresh_interval:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=f"Signing key '{kid}' not found (rate-limited)",
            )
        await self._refresh()

        if kid not in self._keys:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=f"Signing key '{kid}' not found in JWKS",
            )
        return self._keys[kid]

    async def _refresh(self):
        async with httpx.AsyncClient() as client:
            resp = await client.get(self.jwks_url, timeout=10)
            resp.raise_for_status()
            jwks = resp.json()
            self._keys = {k["kid"]: k for k in jwks.get("keys", [])}
            self._fetched_at = time.time()

    def _is_expired(self) -> bool:
        return time.time() - self._fetched_at > self.ttl


@dataclass
class OAuth2Deps:
    """Container for OAuth2 FastAPI dependencies."""

    issuer: str
    audience: str
    jwks_cache: JWKSCache
    algorithms: list = field(default_factory=lambda: ["RS256"])
    clock_skew: int = 30

    async def _validate_token(self, token: str) -> dict:
        """Validate a JWT access token and return its claims."""
        try:
            unverified_header = jwt.get_unverified_header(token)
        except JWTError:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid token format",
                headers={"WWW-Authenticate": "Bearer"},
            )

        kid = unverified_header.get("kid")
        if not kid:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Token header missing 'kid'",
                headers={"WWW-Authenticate": "Bearer"},
            )

        key = await self.jwks_cache.get_key(kid)

        try:
            claims = jwt.decode(
                token,
                key,
                algorithms=self.algorithms,
                audience=self.audience,
                issuer=self.issuer,
                options={
                    "verify_aud": True,
                    "verify_iss": True,
                    "verify_exp": True,
                    "verify_iat": True,
                    "leeway": self.clock_skew,
                },
            )
            return claims
        except jwt.ExpiredSignatureError:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Token has expired",
                headers={"WWW-Authenticate": "Bearer"},
            )
        except jwt.JWTClaimsError as e:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=f"Token claims validation failed: {str(e)}",
                headers={"WWW-Authenticate": "Bearer"},
            )
        except JWTError as e:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=f"Token validation failed: {str(e)}",
                headers={"WWW-Authenticate": "Bearer"},
            )

    async def require_auth(
        self,
        credentials: Optional[HTTPAuthorizationCredentials] = Security(bearer_scheme),
    ) -> dict:
        """Dependency: Require a valid access token. Returns claims dict."""
        if not credentials:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Missing authorization header",
                headers={"WWW-Authenticate": "Bearer"},
            )
        return await self._validate_token(credentials.credentials)

    def require_scopes(self, *required_scopes: str):
        """
        Dependency factory: Require specific scopes in the access token.

        Usage:
            @app.get("/admin")
            async def admin(user: dict = Depends(oauth2.require_scopes("admin:read", "admin:write"))):
                ...
        """

        async def _check_scopes(
            credentials: Optional[HTTPAuthorizationCredentials] = Security(
                bearer_scheme
            ),
        ) -> dict:
            if not credentials:
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="Missing authorization header",
                    headers={"WWW-Authenticate": "Bearer"},
                )
            claims = await self._validate_token(credentials.credentials)
            token_scopes = set(claims.get("scope", "").split())
            missing = set(required_scopes) - token_scopes
            if missing:
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail=f"Missing required scopes: {', '.join(sorted(missing))}",
                    headers={
                        "WWW-Authenticate": f'Bearer scope="{" ".join(required_scopes)}"'
                    },
                )
            return claims

        return _check_scopes

    def require_roles(self, *required_roles: str, claim: str = "roles"):
        """
        Dependency factory: Require specific roles in the access token.
        Works with Auth0/Keycloak-style role claims.
        """

        async def _check_roles(
            credentials: Optional[HTTPAuthorizationCredentials] = Security(
                bearer_scheme
            ),
        ) -> dict:
            if not credentials:
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="Missing authorization header",
                    headers={"WWW-Authenticate": "Bearer"},
                )
            claims = await self._validate_token(credentials.credentials)
            user_roles = set(claims.get(claim, []))
            if not user_roles.intersection(required_roles):
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail=f"Required role(s): {', '.join(required_roles)}",
                )
            return claims

        return _check_roles

    async def optional_auth(
        self,
        credentials: Optional[HTTPAuthorizationCredentials] = Security(bearer_scheme),
    ) -> Optional[dict]:
        """Dependency: Optionally validate token. Returns claims or None."""
        if not credentials:
            return None
        try:
            return await self._validate_token(credentials.credentials)
        except HTTPException:
            return None


def create_oauth2_deps(
    issuer: str,
    audience: str,
    jwks_url: str,
    algorithms: list = None,
    jwks_ttl: int = 3600,
) -> OAuth2Deps:
    """
    Create OAuth2 dependencies for FastAPI.

    Args:
        issuer: Expected token issuer (e.g., "https://auth.example.com")
        audience: Expected token audience (e.g., "https://api.example.com")
        jwks_url: JWKS endpoint URL
        algorithms: Allowed signing algorithms (default: ["RS256"])
        jwks_ttl: JWKS cache TTL in seconds (default: 3600)

    Returns:
        OAuth2Deps instance with .require_auth, .require_scopes(), etc.
    """
    return OAuth2Deps(
        issuer=issuer,
        audience=audience,
        jwks_cache=JWKSCache(jwks_url=jwks_url, ttl=jwks_ttl),
        algorithms=algorithms or ["RS256"],
    )


# --- Example usage ---
# Uncomment to run as a standalone FastAPI app:
#
# from fastapi import FastAPI
#
# app = FastAPI(title="OAuth2 Protected API")
#
# oauth2 = create_oauth2_deps(
#     issuer="https://auth.example.com",
#     audience="https://api.example.com",
#     jwks_url="https://auth.example.com/.well-known/jwks.json",
# )
#
# @app.get("/public")
# async def public():
#     return {"message": "This is public"}
#
# @app.get("/protected")
# async def protected(user: dict = Depends(oauth2.require_auth)):
#     return {"message": f"Hello {user['sub']}", "claims": user}
#
# @app.get("/admin")
# async def admin(user: dict = Depends(oauth2.require_scopes("admin:read"))):
#     return {"admin_data": "secret", "user": user["sub"]}
#
# @app.get("/optional")
# async def optional(user: Optional[dict] = Depends(oauth2.optional_auth)):
#     if user:
#         return {"message": f"Hello {user['sub']}"}
#     return {"message": "Hello anonymous"}
