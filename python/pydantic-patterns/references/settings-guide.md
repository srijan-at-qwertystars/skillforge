# Pydantic Settings Deep Dive

## Table of Contents

- [Basics](#basics)
- [Multiple Env File Support](#multiple-env-file-support)
- [Secrets Directory](#secrets-directory)
- [Custom Settings Sources](#custom-settings-sources)
- [Nested Settings Flattening](#nested-settings-flattening)
- [Settings Validation](#settings-validation)
- [12-Factor App Patterns](#12-factor-app-patterns)
- [Testing with Settings Overrides](#testing-with-settings-overrides)

---

## Basics

Install: `pip install pydantic-settings`

```python
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field

class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="APP_",
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    debug: bool = False
    database_url: str
    secret_key: str = Field(min_length=32)
    max_connections: int = 10
```

Priority (highest wins): init kwargs → env vars → env file → secrets dir → field defaults.

---

## Multiple Env File Support

Load from multiple files with cascading priority:

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(".env", ".env.local", ".env.production"),
        env_file_encoding="utf-8",
    )
    debug: bool = False
    api_key: str = ""
```

Later files override earlier ones. Missing files are silently skipped.

Common pattern for environments:

```python
import os

def get_env_files() -> tuple[str, ...]:
    env = os.getenv("APP_ENV", "development")
    return (".env", f".env.{env}", ".env.local")

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=get_env_files())
```

Typical file hierarchy:
```
.env                 # shared defaults (committed)
.env.development     # dev overrides (committed)
.env.production      # prod overrides (committed or in CI)
.env.local           # local overrides (gitignored)
```

---

## Secrets Directory

For Docker/Kubernetes secrets mounted as files:

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        secrets_dir="/run/secrets",
    )
    db_password: str    # reads from /run/secrets/db_password
    api_key: str        # reads from /run/secrets/api_key
```

Each secret is a file whose name matches the field (case-insensitive by default).
File content is stripped of trailing whitespace.

With `env_prefix`:

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="APP_",
        secrets_dir="/run/secrets",
    )
    db_password: str  # reads from /run/secrets/app_db_password
```

Priority: env vars > secrets dir > defaults.

Multiple secrets directories:

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        secrets_dir=["/run/secrets", "/etc/app/secrets"],
    )
```

---

## Custom Settings Sources

Override `settings_customise_sources()` to add or reorder sources.

### AWS SSM Parameter Store

```python
import boto3
from pydantic_settings import BaseSettings, PydanticBaseSettingsSource

class AWSSSMSource(PydanticBaseSettingsSource):
    def __init__(self, settings_cls: type[BaseSettings], ssm_prefix: str = "/app/"):
        super().__init__(settings_cls)
        self.ssm_prefix = ssm_prefix
        self.client = boto3.client("ssm")

    def get_field_value(self, field, field_name):
        try:
            param = self.client.get_parameter(
                Name=f"{self.ssm_prefix}{field_name}",
                WithDecryption=True,
            )
            return param["Parameter"]["Value"], field_name, False
        except self.client.exceptions.ParameterNotFound:
            return None, field_name, False

    def __call__(self):
        d = {}
        for field_name, field_info in self.settings_cls.model_fields.items():
            val, _, _ = self.get_field_value(field_info, field_name)
            if val is not None:
                d[field_name] = val
        return d

class Settings(BaseSettings):
    database_url: str
    api_key: str

    @classmethod
    def settings_customise_sources(cls, settings_cls, **kwargs):
        return (
            kwargs["init_settings"],
            kwargs["env_settings"],
            AWSSSMSource(settings_cls, ssm_prefix="/myapp/prod/"),
            kwargs["dotenv_settings"],
            kwargs["file_secret_settings"],
        )
```

### HashiCorp Vault

```python
import hvac

class VaultSource(PydanticBaseSettingsSource):
    def __init__(self, settings_cls, vault_path="secret/data/app"):
        super().__init__(settings_cls)
        self.client = hvac.Client()
        self.vault_path = vault_path

    def __call__(self):
        try:
            secret = self.client.secrets.kv.v2.read_secret_version(
                path=self.vault_path
            )
            return secret["data"]["data"]
        except Exception:
            return {}
```

### YAML config file

```python
from pathlib import Path
import yaml

class YamlSource(PydanticBaseSettingsSource):
    def __init__(self, settings_cls, yaml_file: str = "config.yaml"):
        super().__init__(settings_cls)
        self.yaml_file = yaml_file

    def __call__(self):
        path = Path(self.yaml_file)
        if path.exists():
            with open(path) as f:
                return yaml.safe_load(f) or {}
        return {}

class Settings(BaseSettings):
    debug: bool = False
    database_url: str = "sqlite:///db.sqlite3"

    @classmethod
    def settings_customise_sources(cls, settings_cls, **kwargs):
        return (
            kwargs["init_settings"],
            kwargs["env_settings"],
            YamlSource(settings_cls, "config.yaml"),
            kwargs["dotenv_settings"],
            kwargs["file_secret_settings"],
        )
```

---

## Nested Settings Flattening

Use `env_nested_delimiter` to map flat env vars to nested structures:

```python
from pydantic import BaseModel
from pydantic_settings import BaseSettings, SettingsConfigDict

class DatabaseConfig(BaseModel):
    host: str = "localhost"
    port: int = 5432
    name: str = "mydb"
    pool_size: int = 5

class RedisConfig(BaseModel):
    url: str = "redis://localhost:6379"
    ttl: int = 300

class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="APP_",
        env_nested_delimiter="__",
    )
    database: DatabaseConfig = DatabaseConfig()
    redis: RedisConfig = RedisConfig()
```

Environment variables:
```bash
APP_DATABASE__HOST=db.prod.example.com
APP_DATABASE__PORT=5432
APP_DATABASE__NAME=proddb
APP_DATABASE__POOL_SIZE=20
APP_REDIS__URL=redis://redis.prod:6379
APP_REDIS__TTL=600
```

Deeply nested: `APP_DATABASE__POOL__MIN_SIZE=5` maps to `database.pool.min_size`.

Complex nested values as JSON:
```bash
APP_DATABASE='{"host": "db.prod", "port": 5432}'
```

---

## Settings Validation

Apply all standard Pydantic validators to settings:

```python
from pydantic_settings import BaseSettings
from pydantic import field_validator, model_validator, Field
import re

class Settings(BaseSettings):
    database_url: str
    redis_url: str = "redis://localhost:6379"
    log_level: str = "INFO"
    workers: int = Field(default=4, ge=1, le=32)

    @field_validator("database_url")
    @classmethod
    def validate_database_url(cls, v):
        if not re.match(r"^(postgresql|mysql|sqlite)", v):
            raise ValueError("database_url must start with a valid scheme")
        return v

    @field_validator("log_level")
    @classmethod
    def validate_log_level(cls, v):
        allowed = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}
        upper = v.upper()
        if upper not in allowed:
            raise ValueError(f"log_level must be one of {allowed}")
        return upper

    @model_validator(mode="after")
    def check_production_settings(self):
        if not self.debug and self.log_level == "DEBUG":
            raise ValueError("DEBUG log level not allowed in production")
        return self
```

### Startup validation pattern

```python
def create_settings() -> Settings:
    """Validate all settings at startup. Fail fast on misconfiguration."""
    try:
        return Settings()
    except ValidationError as e:
        print("Configuration error:")
        for err in e.errors():
            field = ".".join(str(x) for x in err["loc"])
            print(f"  {field}: {err['msg']}")
        raise SystemExit(1)

settings = create_settings()
```

---

## 12-Factor App Patterns

### Factor III: Config in environment

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="APP_")

    # Backing services as URLs (Factor IV)
    database_url: str
    redis_url: str
    smtp_url: str = ""

    # Port binding (Factor VII)
    host: str = "0.0.0.0"
    port: int = 8000

    # Concurrency (Factor VIII)
    workers: int = 4

    # Logs as streams (Factor XI)
    log_level: str = "INFO"
    log_format: str = "json"
```

### Singleton settings with caching

```python
from functools import lru_cache

@lru_cache
def get_settings() -> Settings:
    return Settings()

# FastAPI dependency
from fastapi import Depends

def settings_dependency() -> Settings:
    return get_settings()

@app.get("/info")
async def info(settings: Settings = Depends(settings_dependency)):
    return {"debug": settings.debug}
```

### Environment-specific settings

```python
from typing import Literal

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="APP_")

    environment: Literal["development", "staging", "production"] = "development"

    @property
    def is_production(self) -> bool:
        return self.environment == "production"

    @property
    def is_development(self) -> bool:
        return self.environment == "development"
```

### Dev/prod parity (Factor X)

Keep the same Settings class across environments. Vary only the environment variable
values, not the code.

---

## Testing with Settings Overrides

### Direct instantiation

```python
def test_with_custom_settings():
    settings = Settings(
        database_url="sqlite:///test.db",
        debug=True,
        secret_key="a" * 32,
    )
    app = create_app(settings)
    # init kwargs have highest priority, override everything
```

### Environment variable patching

```python
import os
from unittest.mock import patch

def test_settings_from_env():
    env = {
        "APP_DATABASE_URL": "sqlite:///test.db",
        "APP_DEBUG": "true",
        "APP_SECRET_KEY": "x" * 32,
    }
    with patch.dict(os.environ, env, clear=False):
        settings = Settings()
        assert settings.debug is True

# pytest with monkeypatch
def test_settings(monkeypatch):
    monkeypatch.setenv("APP_DEBUG", "true")
    monkeypatch.setenv("APP_DATABASE_URL", "sqlite:///test.db")
    settings = Settings()
    assert settings.debug is True
```

### FastAPI dependency override

```python
from fastapi.testclient import TestClient

def get_test_settings() -> Settings:
    return Settings(
        database_url="sqlite:///test.db",
        debug=True,
        secret_key="test" * 8,
    )

app.dependency_overrides[get_settings] = get_test_settings
client = TestClient(app)

def test_endpoint():
    response = client.get("/info")
    assert response.json()["debug"] is True

# Clean up
app.dependency_overrides.clear()
```

### Fixture pattern for pytest

```python
import pytest

@pytest.fixture
def settings(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text("APP_DEBUG=true\nAPP_DATABASE_URL=sqlite:///test.db\n")
    return Settings(_env_file=str(env_file), secret_key="x" * 32)

@pytest.fixture
def app(settings):
    return create_app(settings)

@pytest.fixture
def client(app):
    return TestClient(app)
```

### Temporary env files

```python
def test_env_file_loading(tmp_path):
    env = tmp_path / ".env"
    env.write_text("APP_DATABASE_URL=sqlite:///test.db\n")

    settings = Settings(_env_file=str(env))
    assert "test.db" in settings.database_url
```
