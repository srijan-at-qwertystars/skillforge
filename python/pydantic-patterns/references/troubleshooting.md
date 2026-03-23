# Pydantic Troubleshooting Guide

## Table of Contents

- [v1 → v2 Migration Errors](#v1--v2-migration-errors)
- [Validator Ordering Gotchas](#validator-ordering-gotchas)
- [Circular Reference Models](#circular-reference-models)
- [Optional vs None Defaults](#optional-vs-none-defaults)
- [Mutable Default Gotchas](#mutable-default-gotchas)
- [Serialization of Complex Types](#serialization-of-complex-types)
- [FastAPI Integration Issues](#fastapi-integration-issues)
- [Mypy Plugin Problems](#mypy-plugin-problems)
- [Runtime vs Validation Errors](#runtime-vs-validation-errors)

---

## v1 → v2 Migration Errors

### `PydanticUserError: validator 'X' should be a class method`

v2 requires `@classmethod` on all `@field_validator` functions.

```python
# WRONG (v1 style)
@field_validator("name")
def check_name(cls, v):
    return v.strip()

# RIGHT (v2)
@field_validator("name")
@classmethod
def check_name(cls, v):
    return v.strip()
```

### `AttributeError: 'X' has no attribute 'dict'`

v2 renamed `.dict()` → `.model_dump()`, `.json()` → `.model_dump_json()`.

```python
# v1
data = user.dict()
raw = user.json()

# v2
data = user.model_dump()
raw = user.model_dump_json()
```

### `PydanticUserError: 'Config' is deprecated`

Replace inner `class Config` with `model_config = ConfigDict(...)`.

```python
# v1
class User(BaseModel):
    class Config:
        orm_mode = True

# v2
from pydantic import ConfigDict
class User(BaseModel):
    model_config = ConfigDict(from_attributes=True)
```

### `ImportError: cannot import name 'validator' from 'pydantic'`

`validator` and `root_validator` are removed in v2. Use `field_validator` and
`model_validator`.

### `TypeError: __root__ is not supported in v2`

Replace `__root__` with `RootModel`.

```python
# v1
class Tags(BaseModel):
    __root__: list[str]

# v2
from pydantic import RootModel
class Tags(RootModel[list[str]]):
    pass
```

### Running bump-pydantic

```bash
pip install bump-pydantic
bump-pydantic path/to/your/code/

# Preview changes without applying
bump-pydantic path/to/your/code/ --diff
```

bump-pydantic handles most renames automatically but does NOT handle:
- Custom `json_encoders` → `field_serializer` / `PlainSerializer`
- Complex `root_validator` logic → `model_validator(mode="before"/"after")`
- `__get_validators__` → `__get_pydantic_core_schema__`

Always review changes manually after running.

---

## Validator Ordering Gotchas

### Validators run per-field, not in definition order across fields

```python
class Model(BaseModel):
    first: str
    second: str

    @field_validator("second")
    @classmethod
    def check_second(cls, v, info):
        # info.data["first"] is available here because "first" is defined before "second"
        return v

    @field_validator("first")
    @classmethod
    def check_first(cls, v, info):
        # info.data has NO "second" key yet — it hasn't been validated
        return v
```

**Rule:** In `field_validator(mode='after')`, `info.data` contains only fields defined
*before* the current field in the class body.

### Multiple validators on the same field

If multiple validators target the same field, they run in definition order:

```python
class Model(BaseModel):
    value: str

    @field_validator("value")
    @classmethod
    def strip_whitespace(cls, v):  # runs first
        return v.strip()

    @field_validator("value")
    @classmethod
    def to_lower(cls, v):  # runs second
        return v.lower()
```

### model_validator timing

```
model_validator(mode="before")  → raw input (dict/any)
  ↓
field_validator(mode="before")  → per field, pre-coercion
  ↓
core type coercion
  ↓
field_validator(mode="after")   → per field, post-coercion
  ↓
model_validator(mode="after")   → fully constructed instance
```

**Gotcha:** In `model_validator(mode="before")`, the input may not be a dict (could be
another model instance, a string, etc.). Always guard with `isinstance`:

```python
@model_validator(mode="before")
@classmethod
def pre_process(cls, data):
    if isinstance(data, dict):
        data["computed"] = data.get("a", 0) + data.get("b", 0)
    return data
```

---

## Circular Reference Models

### Problem: `NameError` or `PydanticUndefinedAnnotation`

```python
class Parent(BaseModel):
    child: "Child"       # forward reference

class Child(BaseModel):
    parent: "Parent"     # circular
```

### Solution: `model_rebuild()` + `from __future__ import annotations`

```python
from __future__ import annotations
from pydantic import BaseModel

class Parent(BaseModel):
    name: str
    children: list[Child] = []

class Child(BaseModel):
    name: str
    parent: Parent | None = None

# MUST call after both classes are defined
Parent.model_rebuild()
Child.model_rebuild()
```

### Avoiding infinite recursion in serialization

Circular object graphs cause infinite recursion in `model_dump()`. Solutions:

```python
# Option 1: Exclude the back-reference
class Child(BaseModel):
    name: str
    parent: Parent | None = Field(default=None, exclude=True)

# Option 2: Use a simpler reference type
class ChildRef(BaseModel):
    name: str
    parent_id: int  # reference by ID instead of nesting

# Option 3: Custom serializer with depth control
class Child(BaseModel):
    name: str
    parent: Parent | None = None

    @field_serializer("parent")
    def serialize_parent(self, v, _info):
        return {"name": v.name} if v else None  # shallow
```

---

## Optional vs None Defaults

### v2 breaking change: `Optional[X]` no longer implies `default=None`

```python
# v1 behavior: Optional[str] had implicit default=None
# v2 behavior: Optional[str] is REQUIRED, accepts str or None

class User(BaseModel):
    # REQUIRED — must be provided, but can be None
    nickname: str | None

    # OPTIONAL with default — can be omitted
    nickname: str | None = None

    # REQUIRED, cannot be None
    name: str
```

### Common migration error

```python
# This worked in v1 (nickname was optional with default None)
class UserV1(BaseModel):
    nickname: Optional[str]

# In v2, this requires nickname to be passed:
UserV1(nickname=None)     # OK
UserV1()                  # ValidationError: nickname is required

# Fix: add explicit default
class UserV2(BaseModel):
    nickname: str | None = None
```

### `Union[X, None]` vs `Optional[X]` vs `X | None`

All three are equivalent in v2 — they all mean "accepts X or None" and all are **required**
unless you add `= None`.

---

## Mutable Default Gotchas

### Shared mutable defaults across instances

```python
# WRONG — all instances share the same list object
class Model(BaseModel):
    items: list[str] = []

# Pydantic v2 actually deep-copies defaults, so this is SAFE in practice.
# However, use default_factory for clarity and to match best practices:
class Model(BaseModel):
    items: list[str] = Field(default_factory=list)
    metadata: dict[str, str] = Field(default_factory=dict)
    tags: set[str] = Field(default_factory=set)
```

### Custom objects as defaults

```python
# WRONG — mutable custom object
class Model(BaseModel):
    config: MyConfig = MyConfig()  # shared if MyConfig is mutable

# RIGHT
class Model(BaseModel):
    config: MyConfig = Field(default_factory=MyConfig)
```

### Validator mutation gotcha

```python
# WRONG — mutating the input value
@field_validator("items")
@classmethod
def process_items(cls, v):
    v.append("default_item")  # mutates caller's list!
    return v

# RIGHT — return a new value
@field_validator("items")
@classmethod
def process_items(cls, v):
    return [*v, "default_item"]
```

---

## Serialization of Complex Types

### `datetime` objects

```python
# Default: serializes to ISO 8601 string in JSON mode
user.model_dump()           # datetime object preserved
user.model_dump(mode="json")  # "2024-01-15T10:30:00"
user.model_dump_json()        # JSON string with ISO format
```

### `Decimal` precision loss

```python
from decimal import Decimal

class Price(BaseModel):
    amount: Decimal

# model_dump() preserves Decimal
# model_dump_json() converts to string by default to avoid float precision issues
# To force float output:
@field_serializer("amount")
def ser_amount(self, v: Decimal, _info) -> float:
    return float(v)
```

### `Enum` serialization

```python
from enum import Enum

class Status(str, Enum):
    ACTIVE = "active"
    INACTIVE = "inactive"

class User(BaseModel):
    status: Status

user = User(status="active")
user.model_dump()                 # {'status': <Status.ACTIVE: 'active'>}
user.model_dump(mode="json")      # {'status': 'active'}
```

### Bytes and binary data

```python
class File(BaseModel):
    content: bytes

# model_dump_json() base64-encodes bytes by default
# Custom encoding:
@field_serializer("content")
def ser_content(self, v: bytes, _info) -> str:
    return v.hex()
```

### Non-serializable types

If `model_dump_json()` raises `PydanticSerializationError`, add a `field_serializer`
or use `PlainSerializer` in an `Annotated` type.

```python
from typing import Annotated
from pydantic import PlainSerializer
import re

SerializablePattern = Annotated[
    re.Pattern,
    PlainSerializer(lambda v: v.pattern, return_type=str),
]
```

---

## FastAPI Integration Issues

### `ResponseValidationError` in responses

FastAPI validates response data against `response_model`. Common causes:

```python
# Problem: ORM object not converted properly
@app.get("/users/{id}", response_model=UserResponse)
async def get_user(id: int):
    orm_user = db.query(User).get(id)
    return orm_user  # fails if UserResponse lacks from_attributes=True

# Fix:
class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str
```

### Query parameters with complex types

```python
# WRONG — Pydantic model as query param doesn't work directly
@app.get("/search")
async def search(filters: FilterModel): ...

# RIGHT — use Depends or individual params
from fastapi import Depends, Query

@app.get("/search")
async def search(
    q: str = Query(min_length=1),
    limit: int = Query(default=10, ge=1, le=100),
): ...
```

### `ValidationError` vs `RequestValidationError`

- `pydantic.ValidationError` — raised by Pydantic during model validation.
- `fastapi.exceptions.RequestValidationError` — wraps Pydantic errors for HTTP context.
- Handle in FastAPI exception handler:

```python
from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=422,
        content={"detail": exc.errors(), "body": exc.body},
    )
```

### Pydantic v2 + older FastAPI

FastAPI ≥ 0.100.0 is required for Pydantic v2 support. Older versions only work with
Pydantic v1. Check compatibility:

```bash
pip show fastapi pydantic
```

---

## Mypy Plugin Problems

### Setup

```ini
# pyproject.toml
[tool.mypy]
plugins = ["pydantic.mypy"]

[tool.pydantic-mypy]
init_forbid_extra = true
init_typed = true
warn_required_dynamic_aliases = true
```

### Common issues

**`error: Untyped fields disallowed`** — every field needs a type annotation.

**`error: unexpected keyword argument`** — mypy plugin requires `init_typed = true` to
recognize `Field()` defaults.

**`Incompatible types in assignment`** with validators — ensure return type matches field type:

```python
@field_validator("name")
@classmethod
def check_name(cls, v: str) -> str:  # must return str, not None
    return v.strip()
```

**Plugin not recognizing `model_config`** — ensure pydantic mypy plugin version matches
your pydantic version. Update both together.

**Generic models** — mypy sometimes struggles with `BaseModel, Generic[T]`. Use
`# type: ignore[misc]` on the class definition if needed and file a bug.

### Alternative: pyright/pylance

Pydantic v2 has built-in pyright support without a plugin. If mypy causes too many issues,
consider switching to pyright for Pydantic-heavy projects.

---

## Runtime vs Validation Errors

### `ValidationError` — expected, catchable, user-facing

Raised when data doesn't match the schema. Always has structured error details.

```python
from pydantic import BaseModel, ValidationError

class User(BaseModel):
    age: int

try:
    User(age="not_a_number")
except ValidationError as e:
    print(e.error_count())   # 1
    print(e.errors())        # [{'type': 'int_parsing', 'loc': ('age',), ...}]
    print(e.json())          # JSON representation
```

### `PydanticUserError` — developer bug, fix your code

Raised at class definition time when the model itself is invalid.

```python
# Causes PydanticUserError at import time:
class Bad(BaseModel):
    @field_validator("nonexistent_field")
    @classmethod
    def check(cls, v): ...
```

### `PydanticSchemaGenerationError` — type not supported

Pydantic can't generate a schema for the type. Implement `__get_pydantic_core_schema__`.

### `PydanticSerializationError` — can't serialize

Raised by `model_dump_json()` when a value can't be converted to JSON. Add a
`field_serializer` or `PlainSerializer`.

### Error hierarchy

```
Exception
├── ValidationError              # data doesn't match schema
├── PydanticUserError           # model definition bug
├── PydanticSchemaGenerationError  # unsupported type
├── PydanticSerializationError  # serialization failure
└── PydanticUndefinedAnnotation # unresolved forward ref
```

### Best practice: handle at boundaries

```python
from pydantic import ValidationError
from fastapi import HTTPException

def parse_request(data: dict) -> User:
    try:
        return User.model_validate(data)
    except ValidationError as e:
        raise HTTPException(status_code=422, detail=e.errors())
```

Never catch `PydanticUserError` — fix the code instead. Only catch `ValidationError`
in application logic.
