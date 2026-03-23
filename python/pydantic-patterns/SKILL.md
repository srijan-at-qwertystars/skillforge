---
name: pydantic-patterns
description: >
  Use when writing or editing Pydantic v2 code. Triggers: Pydantic, BaseModel, Field, field_validator,
  model_validator, BaseSettings, data validation, serialization, JSON schema generation, TypeAdapter,
  ConfigDict, computed_field, discriminated union, RootModel, model_dump, model_validate.
  Do NOT use for: Django models or Django ORM without Pydantic, SQLAlchemy models that do not use
  Pydantic (pure SQLAlchemy ORM), marshmallow schemas, attrs/cattrs dataclasses without Pydantic,
  or stdlib dataclasses without Pydantic integration.
---

# Pydantic v2 Patterns

Pydantic v2 uses a Rust-powered core (pydantic-core) for 5–50× faster validation than v1. All
patterns below target Pydantic ≥ 2.0. Always import from `pydantic`, never from `pydantic.v1`.

## BaseModel Fundamentals

```python
from pydantic import BaseModel
from typing import Optional

class User(BaseModel):
    id: int
    name: str
    email: str
    age: Optional[int] = None
```

- Every field must have a type annotation. Fields with defaults are optional.
- `model_validate(data)` parses dicts. `model_validate_json(raw)` parses JSON bytes/str.
- `model_dump()` serializes to dict. `model_dump_json()` produces a JSON string.
- `Model.model_json_schema()` returns the JSON Schema dict.

Supported types: `str`, `int`, `float`, `bool`, `bytes`, `datetime`, `date`, `time`,
`timedelta`, `UUID`, `Decimal`, `Path`, `IPv4Address`, `HttpUrl`, `AnyUrl`, `EmailStr`
(via `pydantic[email]`), `SecretStr`, `Json[T]`, `Enum`, `Literal`, `list[T]`, `set[T]`,
`dict[K, V]`, `tuple[T, ...]`, `Optional[T]`, `Union[A, B]`, nested `BaseModel` subclasses.

## Field() Configuration

```python
from pydantic import BaseModel, Field

class Product(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    price: float = Field(gt=0, description="Price in USD")
    sku: str = Field(alias="product_sku")
    tags: list[str] = Field(default_factory=list)
    quantity: int = Field(default=0, ge=0)
```

Key parameters: `default`/`default_factory`, `alias`, `validation_alias` (parsing only),
`serialization_alias` (output only), `title`/`description`/`examples` (JSON Schema metadata),
`gt`/`ge`/`lt`/`le` (numeric), `min_length`/`max_length` (strings/collections),
`pattern` (regex, was `regex` in v1), `strict` (per-field), `exclude` (from dumps),
`frozen` (immutable field), `json_schema_extra`, `deprecated` (≥ 2.7).

Set `model_config = ConfigDict(populate_by_name=True)` to allow both alias and field name.

## Validators

### field_validator

```python
from pydantic import BaseModel, field_validator

class User(BaseModel):
    name: str
    email: str

    @field_validator("name")
    @classmethod
    def name_must_not_be_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("name must not be blank")
        return v.strip()

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        if "@" not in v:
            raise ValueError("invalid email")
        return v.lower()
```

- Always use `@classmethod`. Signature: `(cls, v)` or `(cls, v, info: FieldValidationInfo)`.
- `mode='before'` — runs before coercion; `v` can be any type.
- `mode='after'` (default) — runs after coercion; `v` is the validated type.
- `mode='wrap'` — `(cls, v, handler, info)`. Call `handler(v)` to run inner chain.
- Multi-field: `@field_validator("field_a", "field_b")`.

### model_validator

```python
from pydantic import BaseModel, model_validator

class DateRange(BaseModel):
    start: date
    end: date

    @model_validator(mode="after")
    def end_after_start(self) -> "DateRange":
        if self.end < self.start:
            raise ValueError("end must be >= start")
        return self
```

- `mode='after'` — `self` is the fully constructed instance. Return `self`.
- `mode='before'` — `@classmethod`, receives raw input (dict/any). Return modified data.
- `mode='wrap'` — `(cls, data, handler)`. Call `handler(data)` to proceed.
- Use for cross-field validation. Never raise from `__init__`.

### Execution order

1. `model_validator(mode='before')` on raw input.
2. Per-field: `field_validator(mode='before')` → core coercion → `field_validator(mode='after')`.
3. `model_validator(mode='after')` on constructed instance.

## Custom Types and Annotated Types

```python
from typing import Annotated
from pydantic import Field, AfterValidator, BeforeValidator

PositiveInt = Annotated[int, Field(gt=0)]
StrippedStr = Annotated[str, AfterValidator(lambda v: v.strip())]
UpperStr = Annotated[str, AfterValidator(str.upper)]

def parse_comma_list(v: str | list[str]) -> list[str]:
    return [s.strip() for s in v.split(",")] if isinstance(v, str) else v

CommaSeparatedList = Annotated[list[str], BeforeValidator(parse_comma_list)]
```

For fully custom types, implement `__get_pydantic_core_schema__`:

```python
from pydantic import GetCoreSchemaHandler
from pydantic_core import CoreSchema, core_schema

class Color:
    def __init__(self, value: str):
        self.value = value

    @classmethod
    def __get_pydantic_core_schema__(cls, source_type, handler: GetCoreSchemaHandler) -> CoreSchema:
        return core_schema.no_info_plain_validator_function(
            lambda v: cls(v) if isinstance(v, str) else v
        )
```

## Serialization

### model_dump / model_dump_json

```python
user.model_dump()                          # dict
user.model_dump(mode="json")               # JSON-compatible dict
user.model_dump(include={"id", "name"})    # whitelist
user.model_dump(exclude={"email"})         # blacklist
user.model_dump(exclude_unset=True)        # omit fields not explicitly set
user.model_dump(exclude_none=True)         # omit None values
user.model_dump(by_alias=True)             # use alias keys
user.model_dump_json(indent=2)             # JSON string
```

### Custom serializers

```python
from pydantic import BaseModel, field_serializer, model_serializer, PlainSerializer
from datetime import datetime
from typing import Annotated

class Event(BaseModel):
    name: str
    timestamp: datetime

    @field_serializer("timestamp")
    def serialize_ts(self, v: datetime, _info) -> str:
        return v.isoformat()

# Type-level serializer via Annotated:
ISODatetime = Annotated[datetime, PlainSerializer(lambda v: v.isoformat(), return_type=str)]

# model_serializer controls entire output:
class Envelope(BaseModel):
    data: dict

    @model_serializer
    def serialize_model(self) -> dict:
        return {"payload": self.data, "version": 2}
```

Use `WrapSerializer` for chaining: receives `(value, nxt)`, call `nxt(value)` for default then
transform. `PlainSerializer` replaces default serialization entirely.

## JSON Schema Generation

```python
User.model_json_schema()                            # validation schema
User.model_json_schema(mode="serialization")        # output schema

from pydantic import TypeAdapter
TypeAdapter(list[int]).json_schema()                 # standalone types
```

Customize with `json_schema_extra` in `Field()` or `ConfigDict`. Implement
`__get_pydantic_json_schema__` on custom types for full control.

## Pydantic Settings

Install: `pip install pydantic-settings`.

```python
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import BaseModel

class DatabaseSettings(BaseModel):
    host: str = "localhost"
    port: int = 5432

class AppSettings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="APP_",
        env_nested_delimiter="__",
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
    )
    debug: bool = False
    database: DatabaseSettings = DatabaseSettings()
```

Env vars: `APP_DEBUG=true`, `APP_DATABASE__HOST=db.example.com`.

- Nested sub-models: use `BaseModel`, not `BaseSettings`.
- Complex values as JSON: `APP_TAGS='["a","b"]'`.
- Priority: init kwargs > env vars > env file > field defaults.
- Use `secrets_dir` for Docker/Kubernetes secrets.

## Discriminated Unions

```python
from typing import Literal, Union
from pydantic import BaseModel, Field

class CreditCard(BaseModel):
    type: Literal["credit_card"]
    card_number: str

class BankTransfer(BaseModel):
    type: Literal["bank_transfer"]
    account_number: str

class Order(BaseModel):
    payment: Union[CreditCard, BankTransfer] = Field(discriminator="type")
```

- O(1) validation vs O(n) for plain unions. Always prefer when data has a type tag.
- Use `Literal` on the discriminator field in each variant.
- For evolving APIs with unknown types: `union_mode='left_to_right'` in `ConfigDict`.

## Generic Models

```python
from typing import TypeVar, Generic
from pydantic import BaseModel

T = TypeVar("T")

class PaginatedResponse(BaseModel, Generic[T]):
    items: list[T]
    total: int
    page: int
```

- Inherit `BaseModel, Generic[T]` directly — no `GenericModel` needed in v2.
- Works with `TypeAdapter(PaginatedResponse[User])`.

## Computed Fields

```python
from pydantic import BaseModel, computed_field

class Rectangle(BaseModel):
    width: float
    height: float

    @computed_field
    @property
    def area(self) -> float:
        return self.width * self.height
```

- Included in `model_dump()`, `model_dump_json()`, and JSON Schema.
- Read-only — never accepted as input. Keep pure, no side effects.

## Strict Mode vs Lax Mode

Lax (default): coerces compatible types (`"123"` → `123`).
Strict: exact types required, no coercion.

```python
from pydantic import BaseModel, ConfigDict, Field

class StrictUser(BaseModel):
    model_config = ConfigDict(strict=True)
    age: int   # "25" raises ValidationError

# Per-field:
class Mixed(BaseModel):
    strict_id: int = Field(strict=True)
    flexible_count: int  # allows coercion
```

Use strict mode for API boundaries; lax mode for ingesting messy external data.

## TypeAdapter

Validate arbitrary types without a model class:

```python
from pydantic import TypeAdapter

ta = TypeAdapter(list[int])
ta.validate_python(["1", "2", "3"])   # [1, 2, 3]
ta.validate_json(b'[1, 2, 3]')       # [1, 2, 3]
ta.dump_python([1, 2, 3])            # [1, 2, 3]
ta.dump_json([1, 2, 3])              # b'[1,2,3]'
ta.json_schema()                     # JSON Schema dict
```

- Works with `Union`, `Annotated`, `TypedDict`, any type Pydantic supports.
- Reuse instances — construction builds the schema (expensive). Thread-safe after init.

## Performance

```python
from pydantic import ConfigDict

model_config = ConfigDict(
    strict=True,                       # skip coercion
    frozen=True,                       # immutable, hashable
    extra="forbid",                    # reject unknown fields early
    validate_default=False,            # trust defaults
    revalidate_instances="never",      # skip re-validating nested models
    defer_build=True,                  # delay schema build until first use
)
```

`defer_build=True` speeds up import for large model hierarchies; first validation incurs a
one-time build cost.

Tips:
- Reuse `TypeAdapter` instances; never recreate per-call.
- Use discriminated unions over plain `Union` for tagged types.
- Prefer `model_validate_json()` over `model_validate(json.loads(...))`.
- Batch-validate: `TypeAdapter(list[Model])` instead of looping.
- Keep validators fast and side-effect-free.

## Integration with FastAPI

```python
from fastapi import FastAPI
from pydantic import BaseModel, Field, ConfigDict

class ItemCreate(BaseModel):
    name: str = Field(min_length=1)
    price: float = Field(gt=0)

class ItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str
    price: float

app = FastAPI()

@app.post("/items", response_model=ItemResponse)
async def create_item(item: ItemCreate) -> ItemResponse: ...
```

- FastAPI uses Pydantic for request parsing, response serialization, and OpenAPI generation.
- Separate input and output models. Use `response_model_exclude_unset=True`.

## Integration with SQLAlchemy

```python
from pydantic import BaseModel, ConfigDict

class UserRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str

user = UserRead.model_validate(orm_user)  # from_orm() is deprecated
```

Set `from_attributes=True` (replaces v1 `orm_mode`). Keep Pydantic and SQLAlchemy models
separate; do not inherit from both.

## Integration with dataclasses

```python
from pydantic.dataclasses import dataclass
from pydantic import Field, ConfigDict

@dataclass(config=ConfigDict(strict=True))
class Point:
    x: float = Field(ge=0)
    y: float = Field(ge=0)
```

Adds Pydantic validation to stdlib dataclass syntax. Supports `Field()` and validators.

## Migration from v1 to v2

### Method renames

| v1 | v2 |
|---|---|
| `.dict()` | `.model_dump()` |
| `.json()` | `.model_dump_json()` |
| `.parse_obj(d)` | `.model_validate(d)` |
| `.parse_raw(d)` | `.model_validate_json(d)` |
| `.from_orm(o)` | `.model_validate(o)` + `from_attributes=True` |
| `.copy()` | `.model_copy()` |
| `.construct()` | `.model_construct()` |
| `.__fields__` | `.model_fields` |
| `.schema()` | `.model_json_schema()` |
| `.update_forward_refs()` | `.model_rebuild()` |
| `@validator` | `@field_validator` |
| `@root_validator` | `@model_validator` |
| `pre=True` | `mode="before"` |
| `class Config:` | `model_config = ConfigDict(...)` |
| `orm_mode=True` | `from_attributes=True` |
| `Field(regex=...)` | `Field(pattern=...)` |
| `__root__` | `RootModel` |

Run `pip install bump-pydantic && bump-pydantic path/to/code/` to auto-refactor syntax.
Review manually — it handles renames but not custom logic.

### Key behavioral changes

- Models no longer compare equal to dicts.
- `Optional[X]` no longer implies `default=None`; set default explicitly.
- Validation errors have richer context and structured `loc` paths.
- The `pydantic.v1` shim is removed in Python ≥ 3.14.

## Common Anti-patterns and Gotchas

**Do not mutate inside validators — return new values:**
```python
# WRONG: v.append("x"); return v
# RIGHT: return [*v, "x"]
```

**Use `default_factory` for mutable defaults:**
```python
# WRONG: items: list[str] = []
# RIGHT: items: list[str] = Field(default_factory=list)
```

**No I/O in validators.** Validators run synchronously during parsing. Validate shape/format
only; verify existence externally.

**Guard `model_validator(mode='before')` input.** Raw input may be dict, list, or any type.
Use `isinstance` checks.

**Extract shared validation into `Annotated` types** instead of copying validators across models.

**Do not mix `BaseModel` and `@dataclass`.** Pick one — mixing causes metaclass conflicts.

**Use `model_construct()` only for trusted data.** It skips all validation. Never use with
user input.

**Handle `ValidationError` at boundaries:**
```python
from pydantic import ValidationError
try:
    user = User.model_validate(data)
except ValidationError as e:
    print(e.error_count(), "errors:", e.errors())
```

**`Optional[X]` changed in v2:** `Optional[str]` means the field accepts `str | None` but is
still **required** unless you set `= None` as the default.

## Resources

**references/** — `advanced-patterns.md` (root types, recursive models, `create_model`, private attrs, context validators, custom encoders, msgpack/protobuf, extra-types, benchmarks) · `troubleshooting.md` (v1→v2 migration, validator ordering, circular refs, Optional/None, mutable defaults, FastAPI/mypy) · `settings-guide.md` (multi env files, secrets, custom sources, nested flattening, 12-factor, testing).

**scripts/** — `pydantic-migrate.sh` (v1→v2 scanner + bump-pydantic) · `pydantic-schema-gen.sh` (JSON Schema from model) · `pydantic-validate-config.py` (validate JSON/YAML against model).

**assets/** — `base_model_template.py` (v2 model template) · `settings_template.py` (BaseSettings template) · `fastapi_models.py` (request/response patterns) · `discriminated_union_example.py` (tagged unions + serialization).

<!-- tested: needs-fix -->
