"""Application settings using pydantic-settings.

Copy this file to app/core/config.py (or app/config.py) and adjust for your project.
Reads from environment variables and .env file.

Usage:
    from app.core.config import settings
    print(settings.database_url)
"""
from functools import lru_cache
from pathlib import Path

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings.

    All fields can be set via environment variables (case-insensitive).
    A .env file in the project root is loaded automatically.
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",  # Ignore unknown env vars
        case_sensitive=False,
    )

    # --- Application ---
    project_name: str = "FastAPI App"
    version: str = "0.1.0"
    debug: bool = False
    environment: str = Field(default="development", pattern="^(development|staging|production)$")

    # --- Server ---
    host: str = "0.0.0.0"
    port: int = 8000
    workers: int = 4

    # --- Database ---
    database_url: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/app"
    db_pool_size: int = 10
    db_max_overflow: int = 20
    db_echo: bool = False

    # --- Auth / Security ---
    secret_key: str = "change-me-in-production"
    access_token_expire_minutes: int = 30
    refresh_token_expire_days: int = 7
    algorithm: str = "HS256"

    # --- CORS ---
    allowed_origins: list[str] = ["http://localhost:3000"]

    # --- Redis ---
    redis_url: str = "redis://localhost:6379/0"

    # --- Email (optional) ---
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    emails_from: str = "noreply@example.com"

    # --- External APIs (optional) ---
    sentry_dsn: str = ""

    # --- Validators ---
    @field_validator("secret_key")
    @classmethod
    def validate_secret_key(cls, v: str) -> str:
        if v == "change-me-in-production":
            import warnings
            warnings.warn(
                "SECRET_KEY is set to default value. Set a strong key in production!",
                UserWarning,
                stacklevel=2,
            )
        return v

    @field_validator("database_url")
    @classmethod
    def validate_database_url(cls, v: str) -> str:
        if not v:
            raise ValueError("DATABASE_URL must be set")
        return v

    # --- Computed properties ---
    @property
    def is_production(self) -> bool:
        return self.environment == "production"

    @property
    def docs_url(self) -> str | None:
        """Disable docs in production."""
        return None if self.is_production else "/docs"

    @property
    def redoc_url(self) -> str | None:
        return None if self.is_production else "/redoc"


@lru_cache
def get_settings() -> Settings:
    """Cached settings instance. Use this in dependencies."""
    return Settings()


# Module-level convenience instance
settings = get_settings()
