# Advanced Pydantic v2 Patterns

## Table of Contents

- [Custom Root Types (RootModel)](#custom-root-types-rootmodel)
- [Recursive Models](#recursive-models)
- [Dynamic Model Creation](#dynamic-model-creation)
- [Model Inheritance](#model-inheritance)
- [Private Attributes](#private-attributes)
- [Context in Validators](#context-in-validators)
- [Custom JSON Encoders and Decoders](#custom-json-encoders-and-decoders)
- [Pydantic with Alternative Serialization Formats](#pydantic-with-alternative-serialization-formats)
- [pydantic-extra-types](#pydantic-extra-types)
- [Custom Error Messages](#custom-error-messages)
- [Performance Benchmarks and Optimization](#performance-benchmarks-and-optimization)

---

## Custom Root Types (RootModel)

`RootModel` replaces v1's `__root__`. Use it when the top-level value isn't a dict.

```python
from pydantic import RootModel

class Tags(RootModel[list[str]]):
    """A list of string tags as the root value."""
    pass

tags = Tags.model_validate(["python", "pydantic"])
print(tags.root)             # ['python', 'pydantic']
print(tags.model_dump())     # ['python', 'pydantic']
print(tags[0])               # 'python' — __getitem__ delegates to root

# Dict-based root
class Lookup(RootModel[dict[str, int]]):
    pass

lookup = Lookup.model_validate({"a": 1, "b": 2})
print(lookup.root["a"])      # 1
```

Key points:
- Access the value via `.root`.
- `RootModel` supports `__iter__`, `__getitem__` for list/dict roots.
- `model_dump()` returns the unwrapped value directly, not `{"root": ...}`.
- Combine with validators for constrained collections:

```python
from pydantic import RootModel, model_validator

class UniqueStrings(RootModel[list[str]]):
    @model_validator(mode="after")
    def check_unique(self) -> "UniqueStrings":
        if len(self.root) != len(set(self.root)):
            raise ValueError("All items must be unique")
        return self
```

---

## Recursive Models

Pydantic v2 handles self-referencing models natively.

```python
from __future__ import annotations
from pydantic import BaseModel

class TreeNode(BaseModel):
    value: str
    children: list[TreeNode] = []

tree = TreeNode.model_validate({
    "value": "root",
    "children": [
        {"value": "child1", "children": []},
        {"value": "child2", "children": [
            {"value": "grandchild", "children": []}
        ]}
    ]
})
```

For mutually recursive models, call `model_rebuild()` after both classes are defined:

```python
from __future__ import annotations
from pydantic import BaseModel

class Parent(BaseModel):
    name: str
    children: list[Child] = []

class Child(BaseModel):
    name: str
    parent: Parent | None = None

Parent.model_rebuild()
Child.model_rebuild()
```

Tips:
- Always use `from __future__ import annotations` or string-quoted annotations.
- Deeply nested recursive data can cause stack overflows — set `max_depth` in
  `ConfigDict` or validate depth in a `model_validator`.
- JSON Schema generation handles `$ref` for recursive types automatically.

---

## Dynamic Model Creation

Use `create_model()` to build models at runtime.

```python
from pydantic import create_model, Field

# Basic: create_model(name, **field_definitions)
# Each field: FieldName=(type, default) or FieldName=(type, FieldInfo)
DynamicUser = create_model(
    "DynamicUser",
    name=(str, ...),                         # required
    age=(int, 0),                            # default=0
    email=(str, Field(pattern=r".+@.+\..+")),
)

user = DynamicUser(name="Alice", email="a@b.com")
```

With validators:

```python
from pydantic import create_model, field_validator

def name_not_empty(cls, v):
    if not v.strip():
        raise ValueError("name cannot be blank")
    return v.strip()

DynamicModel = create_model(
    "DynamicModel",
    name=(str, ...),
    __validators__={"name_check": field_validator("name")(classmethod(name_not_empty))},
)
```

With a base class:

```python
from pydantic import BaseModel, create_model

class TimestampMixin(BaseModel):
    created_at: datetime = Field(default_factory=datetime.utcnow)

DynamicItem = create_model(
    "DynamicItem",
    __base__=TimestampMixin,
    title=(str, ...),
)
```

Use cases: schema-driven APIs, plugin systems, dynamic form generation, config from
database column definitions.

---

## Model Inheritance

```python
from pydantic import BaseModel, ConfigDict

class BaseEntity(BaseModel):
    model_config = ConfigDict(from_attributes=True, strict=True)
    id: int
    created_at: datetime

class User(BaseEntity):
    name: str
    email: str

class AdminUser(User):
    permissions: list[str] = []
```

Rules:
- Child inherits fields, validators, and `model_config` from parent.
- Child `model_config` merges with parent (child values override).
- Validators are inherited and can be overridden by redefining with the same name.
- Fields can be overridden — the child's annotation replaces the parent's for that field.
- Use abstract base models (no instances, just shared config/fields) for DRY schemas.

Overriding fields with narrower types:

```python
class Base(BaseModel):
    status: str

class Strict(Base):
    status: Literal["active", "inactive"]  # narrows str → Literal
```

---

## Private Attributes

Use `PrivateAttr` for internal state excluded from validation, serialization, and schema.

```python
from pydantic import BaseModel, PrivateAttr
from datetime import datetime

class Service(BaseModel):
    name: str
    _start_time: datetime = PrivateAttr(default_factory=datetime.utcnow)
    _request_count: int = PrivateAttr(default=0)

    def log_request(self) -> None:
        self._request_count += 1

svc = Service(name="api")
svc.log_request()
print(svc._request_count)    # 1
print(svc.model_dump())      # {'name': 'api'} — private attrs excluded
```

Key behavior:
- Must start with `_` prefix.
- Set in `model_post_init(self, __context)` for computed private attrs.
- Not included in `model_dump()`, `model_dump_json()`, or JSON Schema.
- Not validated — you can store any object.

```python
class ModelWithInit(BaseModel):
    data: dict

    _cache: dict = PrivateAttr(default_factory=dict)

    def model_post_init(self, __context) -> None:
        self._cache = {k: v for k, v in self.data.items() if v is not None}
```

---

## Context in Validators

Pass runtime context via `info.context` in validators.

```python
from pydantic import BaseModel, field_validator, ValidationInfo

class User(BaseModel):
    name: str
    role: str

    @field_validator("role")
    @classmethod
    def validate_role(cls, v: str, info: ValidationInfo) -> str:
        allowed = info.context.get("allowed_roles", []) if info.context else []
        if allowed and v not in allowed:
            raise ValueError(f"role must be one of {allowed}")
        return v

# Pass context at validation time
user = User.model_validate(
    {"name": "Alice", "role": "admin"},
    context={"allowed_roles": ["admin", "user", "viewer"]},
)
```

Works with `model_validator` too:

```python
from pydantic import model_validator

class Config(BaseModel):
    feature_flags: dict[str, bool]

    @model_validator(mode="after")
    def check_required_flags(self, info: ValidationInfo) -> "Config":
        required = info.context.get("required_flags", []) if info.context else []
        missing = [f for f in required if f not in self.feature_flags]
        if missing:
            raise ValueError(f"Missing required flags: {missing}")
        return self
```

Context is also available with `TypeAdapter.validate_python(..., context={...})`.

---

## Custom JSON Encoders and Decoders

### Custom serializers (replaces v1 `json_encoders`)

```python
from pydantic import BaseModel, field_serializer, model_serializer
from datetime import datetime, date
from decimal import Decimal

class Invoice(BaseModel):
    amount: Decimal
    issued: date
    due: datetime

    @field_serializer("amount")
    def ser_amount(self, v: Decimal, _info) -> str:
        return f"{v:.2f}"

    @field_serializer("issued")
    def ser_date(self, v: date, _info) -> str:
        return v.strftime("%Y-%m-%d")

    @field_serializer("due")
    def ser_datetime(self, v: datetime, _info) -> int:
        return int(v.timestamp())
```

### Custom deserialization with BeforeValidator

```python
from typing import Annotated
from pydantic import BeforeValidator
from datetime import datetime

def parse_flexible_datetime(v):
    if isinstance(v, (int, float)):
        return datetime.fromtimestamp(v)
    if isinstance(v, str):
        for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S", "%d/%m/%Y"):
            try:
                return datetime.strptime(v, fmt)
            except ValueError:
                continue
    return v  # let pydantic handle or raise

FlexibleDatetime = Annotated[datetime, BeforeValidator(parse_flexible_datetime)]
```

### Global JSON schema customization

```python
from pydantic import ConfigDict

class MyModel(BaseModel):
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [{"field": "value"}],
            "$schema": "https://json-schema.org/draft/2020-12/schema",
        }
    )
```

---

## Pydantic with Alternative Serialization Formats

### msgpack

```python
import msgpack
from pydantic import BaseModel

class Event(BaseModel):
    type: str
    payload: dict

event = Event(type="click", payload={"x": 10, "y": 20})

# Serialize: model → dict (json mode) → msgpack bytes
packed = msgpack.packb(event.model_dump(mode="json"))

# Deserialize: msgpack bytes → dict → model
data = msgpack.unpackb(packed)
restored = Event.model_validate(data)
```

### Protocol Buffers (via dict intermediary)

```python
from google.protobuf.json_format import MessageToDict, ParseDict

# protobuf → pydantic
proto_dict = MessageToDict(proto_message, preserving_proto_field_name=True)
model = MyModel.model_validate(proto_dict)

# pydantic → protobuf
proto_msg = ParseDict(model.model_dump(mode="json"), MyProtoMessage())
```

### CBOR / BSON

Same pattern: use `model_dump(mode="json")` for serialization-safe dicts, then pass
to the format's encoder. Use `model_validate()` on the decoded dict.

---

## pydantic-extra-types

Install: `pip install pydantic-extra-types`

Provides validated types for common domains:

```python
from pydantic import BaseModel
from pydantic_extra_types.color import Color
from pydantic_extra_types.country import CountryAlpha2
from pydantic_extra_types.coordinate import Coordinate, Latitude, Longitude
from pydantic_extra_types.mac_address import MacAddress
from pydantic_extra_types.payment import PaymentCardNumber
from pydantic_extra_types.phone_numbers import PhoneNumber  # requires phonenumbers
from pydantic_extra_types.isbn import ISBN

class Product(BaseModel):
    color: Color                # "red", "#ff0000", "rgb(255,0,0)"
    origin: CountryAlpha2       # "US", "GB", etc.
    location: Coordinate        # (lat, lon) tuple
    mac: MacAddress             # "00:11:22:33:44:55"
```

Other available types: `Timezone`, `CurrencyCode`, `LanguageCode`, `SemanticVersion`,
`ULIDType`, `PendulumDatetime` (requires pendulum).

---

## Custom Error Messages

### Per-field custom messages

```python
from pydantic import BaseModel, Field, field_validator

class Registration(BaseModel):
    username: str = Field(min_length=3, max_length=20)
    password: str = Field(min_length=8)

    @field_validator("username")
    @classmethod
    def validate_username(cls, v):
        if not v.isalnum():
            raise ValueError(
                "Username must contain only letters and numbers"
            )
        return v
```

### Structured error customization

```python
from pydantic import BaseModel, ValidationError
from pydantic_core import PydanticCustomError

class StrictModel(BaseModel):
    code: str

    @field_validator("code")
    @classmethod
    def validate_code(cls, v):
        if not v.startswith("PRD-"):
            raise PydanticCustomError(
                "invalid_code_format",        # error type
                "Code must start with 'PRD-', got '{value}'",  # message template
                {"value": v},                 # context dict
            )
        return v
```

### Custom error handler for APIs

```python
from pydantic import ValidationError

def format_errors(exc: ValidationError) -> list[dict]:
    errors = []
    for err in exc.errors():
        errors.append({
            "field": " → ".join(str(loc) for loc in err["loc"]),
            "message": err["msg"],
            "type": err["type"],
            "input": err.get("input"),
        })
    return errors
```

---

## Performance Benchmarks and Optimization

### Benchmark: v2 vs v1 (typical results)

| Operation                    | v1 (µs) | v2 (µs) | Speedup |
|------------------------------|---------|---------|---------|
| Simple model validation      | 12.0    | 1.8     | ~7×     |
| Nested model (3 levels)      | 45.0    | 5.2     | ~9×     |
| List of 100 models           | 1200    | 95      | ~13×    |
| JSON parsing + validation    | 28.0    | 3.1     | ~9×     |
| Serialization (model_dump)   | 8.5     | 1.2     | ~7×     |
| JSON Schema generation       | 35.0    | 4.0     | ~9×     |

### Optimization checklist

1. **Use `model_validate_json()` over `json.loads()` + `model_validate()`** — avoids
   intermediate Python dict creation.

2. **Reuse `TypeAdapter` instances** — schema compilation happens once at construction.

3. **Enable `strict=True`** at model or field level to skip coercion overhead.

4. **Use discriminated unions** — O(1) lookup vs O(n) trial-and-error matching.

5. **`defer_build=True`** — delays schema compilation until first use. Speeds up import
   for apps with hundreds of models.

6. **`frozen=True`** — enables `__hash__`, allows caching/memoization of instances.

7. **`model_construct()`** for trusted data — skips all validation (use carefully).

8. **Avoid expensive operations in validators** — validators run on every parse call.

9. **Batch validation** — `TypeAdapter(list[Model]).validate_python(items)` is faster
   than looping `Model.model_validate()` per item.

10. **Profile with `pydantic.plugin`** — write a plugin to trace validation times:

```python
from pydantic.plugin import PydanticPluginProtocol

class TimingPlugin(PydanticPluginProtocol):
    def new_schema_validator(self, schema, schema_type, schema_type_path, ...):
        # Return handlers that measure validation duration
        ...
```

### Memory optimization

- Use `__slots__` via `ConfigDict(slots=True)` (default in v2 dataclasses).
- Use `RootModel[list[T]]` instead of a model with a single list field.
- For very large datasets, validate in streaming chunks rather than loading all at once.
