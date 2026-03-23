"""Pydantic Settings template with env vars, .env files, and validators.

Copy and adapt this template for application configuration.
Install: pip install pydantic-settings
"""

from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic import (
    BaseModel,
    Field,
    SecretStr,
    field_validator,
    model_validator,
)
from pydantic_settings import BaseSettings, SettingsConfigDict


# ---------------------------------------------------------------------------
# Nested configuration groups (use BaseModel, NOT BaseSettings)
# ---------------------------------------------------------------------------


class DatabaseConfig(BaseModel):
    """Database connection settings."""

    host: str = "localhost"
    port: int = Field(default=5432, ge=1, le=65535)
    name: str = "myapp"
    user: str = "postgres"
    password: SecretStr = SecretStr("")
    pool_min: int = Field(default=2, ge=1)
    pool_max: int = Field(default=10, ge=1)
    echo_sql: bool = False

    @model_validator(mode="after")
    def validate_pool(self) -> DatabaseConfig:
        if self.pool_min > self.pool_max:
            raise ValueError("pool_min must be <= pool_max")
        return self

    @property
    def url(self) -> str:
        pwd = self.password.get_secret_value()
        return f"postgresql://{self.user}:{pwd}@{self.host}:{self.port}/{self.name}"


class RedisConfig(BaseModel):
    """Redis cache settings."""

    url: str = "redis://localhost:6379/0"
    ttl: int = Field(default=300, ge=0, description="Default TTL in seconds")
    prefix: str = "myapp:"


class CorsConfig(BaseModel):
    """CORS configuration for web APIs."""

    origins: list[str] = Field(default_factory=lambda: ["http://localhost:3000"])
    allow_credentials: bool = True
    allow_methods: list[str] = Field(default_factory=lambda: ["*"])
    allow_headers: list[str] = Field(default_factory=lambda: ["*"])


# ---------------------------------------------------------------------------
# Main application settings
# ---------------------------------------------------------------------------


class AppSettings(BaseSettings):
    """Application settings loaded from environment variables and .env files.

    Environment variables:
        APP_ENV                     — deployment environment
        APP_DEBUG                   — enable debug mode
        APP_LOG_LEVEL               — logging level
        APP_SECRET_KEY              — application secret key
        APP_DATABASE__HOST          — database host (nested delimiter: __)
        APP_DATABASE__PORT          — database port
        APP_REDIS__URL              — Redis connection URL
    """

    model_config = SettingsConfigDict(
        # Prefix all env vars with APP_
        env_prefix="APP_",
        # Use __ to represent nested structure in env vars
        env_nested_delimiter="__",
        # Load from .env files; later files override earlier ones
        env_file=(".env", ".env.local"),
        env_file_encoding="utf-8",
        # Case-insensitive env var matching
        case_sensitive=False,
        # Ignore extra env vars
        extra="ignore",
    )

    # -- Core settings -------------------------------------------------------

    env: Literal["development", "staging", "production"] = "development"
    debug: bool = False
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    secret_key: SecretStr = Field(min_length=32)

    # -- Server settings -----------------------------------------------------

    host: str = "0.0.0.0"
    port: int = Field(default=8000, ge=1, le=65535)
    workers: int = Field(default=1, ge=1, le=32)

    # -- Nested settings groups ----------------------------------------------

    database: DatabaseConfig = DatabaseConfig()
    redis: RedisConfig = RedisConfig()
    cors: CorsConfig = CorsConfig()

    # -- Validators ----------------------------------------------------------

    @field_validator("log_level")
    @classmethod
    def normalize_log_level(cls, v: str) -> str:
        return v.upper()

    @model_validator(mode="after")
    def validate_production(self) -> AppSettings:
        """Enforce stricter rules in production."""
        if self.env == "production":
            if self.debug:
                raise ValueError("debug must be False in production")
            if self.log_level == "DEBUG":
                raise ValueError("DEBUG log level not allowed in production")
            if self.workers < 2:
                raise ValueError("production should use at least 2 workers")
        return self

    # -- Convenience properties ----------------------------------------------

    @property
    def is_production(self) -> bool:
        return self.env == "production"

    @property
    def is_development(self) -> bool:
        return self.env == "development"


# ---------------------------------------------------------------------------
# Settings accessor — cached singleton
# ---------------------------------------------------------------------------


@lru_cache
def get_settings() -> AppSettings:
    """Return cached application settings. Call once at startup."""
    return AppSettings()


# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import os

    # Set minimum required env vars for demo
    os.environ.setdefault("APP_SECRET_KEY", "a" * 32)
    os.environ.setdefault("APP_DATABASE__HOST", "db.example.com")
    os.environ.setdefault("APP_DATABASE__PASSWORD", "s3cret")

    settings = AppSettings()
    print(f"Environment: {settings.env}")
    print(f"Debug: {settings.debug}")
    print(f"Database URL: {settings.database.url}")
    print(f"Redis URL: {settings.redis.url}")
    print(f"Workers: {settings.workers}")
    print(f"Log Level: {settings.log_level}")
