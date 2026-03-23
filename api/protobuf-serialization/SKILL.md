---
name: protobuf-serialization
description: |
  Use when user writes .proto files, asks about Protocol Buffers schema design, proto3 syntax,
  message evolution, oneof, maps, well-known types, Buf CLI, or Protobuf editions.
  Do NOT use for gRPC service design (use grpc-protobuf skill), JSON serialization,
  or Avro/Thrift schemas.
---

# Protocol Buffers Serialization

## Proto3 Fundamentals

Declare syntax at file top. Define messages with typed, numbered fields.

```proto
syntax = "proto3";

package acme.inventory.v1;

import "google/protobuf/timestamp.proto";

message Product {
  string id = 1;
  string name = 2;
  string description = 3;
  int32 quantity = 4;
  double price = 5;
  Category category = 6;
  google.protobuf.Timestamp created_at = 7;
}

enum Category {
  CATEGORY_UNSPECIFIED = 0;
  CATEGORY_ELECTRONICS = 1;
  CATEGORY_CLOTHING = 2;
  CATEGORY_FOOD = 3;
}
```

Rules:
- Every `.proto` file starts with `syntax = "proto3";` (or an `edition` declaration).
- Use `package` to namespace messages and avoid collisions.
- Every `enum` must have a zero value as its first entry, named `TYPE_UNSPECIFIED`.
- Field numbers 1–15 use 1 byte on the wire; 16–2047 use 2 bytes. Assign 1–15 to frequently used fields.
- Field numbers 19000–19999 are reserved by the protobuf implementation.

## Scalar Types

| Proto Type | Wire Bytes | Go | Python | Java | Notes |
|------------|-----------|-----|--------|------|-------|
| `int32` | varint | `int32` | `int` | `int` | Negative values use 10 bytes |
| `int64` | varint | `int64` | `int` | `long` | Negative values use 10 bytes |
| `sint32` | varint (zigzag) | `int32` | `int` | `int` | Efficient for negative values |
| `sint64` | varint (zigzag) | `int64` | `int` | `long` | Efficient for negative values |
| `uint32` | varint | `uint32` | `int` | `int` | Unsigned only |
| `uint64` | varint | `uint64` | `int` | `long` | Unsigned only |
| `fixed32` | 4 bytes | `uint32` | `int` | `int` | Always 4 bytes; efficient when values > 2^28 |
| `fixed64` | 8 bytes | `uint64` | `int` | `long` | Always 8 bytes; efficient when values > 2^56 |
| `sfixed32` | 4 bytes | `int32` | `int` | `int` | Signed fixed-width |
| `sfixed64` | 8 bytes | `int64` | `int` | `long` | Signed fixed-width |
| `float` | 4 bytes | `float32` | `float` | `float` | IEEE 754 |
| `double` | 8 bytes | `float64` | `float` | `double` | IEEE 754 |
| `bool` | varint | `bool` | `bool` | `boolean` | |
| `string` | len-delimited | `string` | `str` | `String` | Must be UTF-8 |
| `bytes` | len-delimited | `[]byte` | `bytes` | `ByteString` | Arbitrary bytes |

Choose `sint32`/`sint64` when values are frequently negative. Choose `fixed32`/`fixed64` when values are consistently large.

## Complex Types

### Nested Messages

```proto
message Order {
  string order_id = 1;
  repeated LineItem items = 2;

  message LineItem {
    string product_id = 1;
    int32 quantity = 2;
    double unit_price = 3;
  }
}
```

### Oneof

Use `oneof` for mutually exclusive fields. Only one field in a `oneof` can be set at a time.

```proto
message Payment {
  string id = 1;
  oneof method {
    CreditCard credit_card = 2;
    BankTransfer bank_transfer = 3;
    Wallet wallet = 4;
  }
}
```

- Setting one `oneof` field clears all others.
- Do not use `repeated` inside `oneof`.
- Cannot add or remove fields from an existing `oneof` without breaking compatibility.

### Maps

```proto
message Project {
  string name = 1;
  map<string, string> labels = 2;
  map<string, Member> members = 3;
}
```

- Map keys: any integer or string type. Not `float`, `double`, `bytes`, enums, or messages.
- Maps are unordered. Cannot use `repeated` on map fields.
- Wire-equivalent to `repeated` nested message with `key` and `value` fields.

### Repeated Fields

```proto
message SearchResponse {
  repeated Result results = 1;
  repeated string tags = 2;
}
```

- In proto3, scalar numeric `repeated` fields use packed encoding by default.
- Order is preserved.

### Any

Embed arbitrary message types without importing them:

```proto
import "google/protobuf/any.proto";

message Event {
  string event_id = 1;
  google.protobuf.Any payload = 2;
}
```

Pack/unpack at runtime using the type URL (`type.googleapis.com/full.message.Name`).

## Well-Known Types

Import from `google/protobuf/`:

| Type | Import | Purpose |
|------|--------|---------|
| `Timestamp` | `timestamp.proto` | UTC time as seconds + nanos since epoch |
| `Duration` | `duration.proto` | Signed span of time (seconds + nanos) |
| `Struct` | `struct.proto` | Arbitrary JSON-like structure |
| `Value` | `struct.proto` | Single dynamic value (null, number, string, bool, struct, list) |
| `Empty` | `empty.proto` | Message with no fields (for RPCs with no request/response) |
| `FieldMask` | `field_mask.proto` | Set of field paths for partial reads/updates |
| `Wrappers` | `wrappers.proto` | Nullable scalars: `Int32Value`, `StringValue`, etc. |

```proto
import "google/protobuf/field_mask.proto";
import "google/protobuf/timestamp.proto";

message UpdateUserRequest {
  string user_id = 1;
  User user = 2;
  google.protobuf.FieldMask update_mask = 3;
}
```

Use `FieldMask` for partial updates—send only changed fields. Use `Wrappers` when you need to distinguish "not set" from zero/empty in proto3.

## Schema Evolution

### Rules for Safe Evolution

1. **Never reuse a field number.** Old binaries will misinterpret data.
2. **Never change a field's type.** Add a new field instead.
3. **Adding fields is safe.** Old readers ignore unknown fields; new readers see defaults for missing fields.
4. **Removing fields:** mark as `reserved` to prevent reuse.
5. **Renaming fields** is safe on the wire (wire format uses numbers, not names), but breaks JSON serialization.
6. **Changing `optional` ↔ `repeated`** is not safe.
7. **Enum evolution:** add new values freely. Never change existing numeric values. Reserve removed values.

### Reserved Fields

```proto
message Account {
  reserved 2, 15, 9 to 11;
  reserved "email", "phone";

  string id = 1;
  string username = 3;
}
```

Reserve both number and name when removing a field to prevent accidental reuse.

### Backward and Forward Compatibility

- **Backward compatible**: new code reads old data. Achieved by never removing or renumbering fields.
- **Forward compatible**: old code reads new data. Achieved because proto3 preserves unknown fields.
- Add `optional` keyword to distinguish "field not set" from "field set to default" when explicit presence matters.

## Buf CLI

Buf replaces raw `protoc` with a modern, opinionated toolchain.

### buf.yaml

```yaml
version: v2
modules:
  - path: proto
    name: buf.build/acme/inventory
lint:
  use:
    - STANDARD
breaking:
  use:
    - FILE
deps:
  - buf.build/googleapis/googleapis
  - buf.build/bufbuild/protovalidate
```

### buf.gen.yaml

```yaml
version: v2
plugins:
  - remote: buf.build/protocolbuffers/go
    out: gen/go
    opt: paths=source_relative
  - remote: buf.build/grpc/go
    out: gen/go
    opt: paths=source_relative
  - remote: buf.build/community/timostamm-protobuf-ts
    out: gen/ts
managed:
  enabled: true
  override:
    - file_option: go_package_prefix
      value: github.com/acme/inventory/gen/go
```

### Key Commands

```bash
buf lint                              # Lint .proto files
buf breaking --against .git#branch=main  # Detect breaking changes vs main
buf generate                          # Generate code from buf.gen.yaml
buf format -w                         # Format .proto files in place
buf dep update                        # Update dependencies in buf.lock
buf build                             # Validate .proto files compile
buf push                              # Push module to Buf Schema Registry
```

### CI Integration

Run in CI pipelines:

```bash
buf lint --error-format=github-actions
buf breaking --against "buf.build/acme/inventory" --error-format=github-actions
```

## Code Generation

### protoc (legacy)

```bash
protoc --go_out=. --go_opt=paths=source_relative \
       --go-grpc_out=. --go-grpc_opt=paths=source_relative \
       -I proto/ proto/acme/inventory/v1/*.proto
```

### buf generate (preferred)

Configure `buf.gen.yaml` and run `buf generate`. Benefits:
- Reproducible builds via `buf.lock`.
- Remote plugins—no local plugin binaries needed.
- Managed mode auto-sets `go_package`, `java_package`, etc.

### Language Plugins

| Language | Plugin | Package |
|----------|--------|---------|
| Go | `protoc-gen-go` | `google.golang.org/protobuf` |
| Python | `protoc-gen-python` (built-in) | `protobuf` (pip) |
| TypeScript | `protobuf-ts` | `@protobuf-ts/plugin` |
| Java | `protoc-gen-java` (built-in) | `com.google.protobuf:protobuf-java` |
| Rust | `prost` | `prost`, `prost-build` |
| C++ | built-in to `protoc` | `libprotobuf` |

## Style Guide

### Naming Conventions

- **Files:** `lower_snake_case.proto`. One file per logical group.
- **Messages:** `PascalCase`. E.g., `UserProfile`.
- **Fields:** `lower_snake_case`. E.g., `first_name`.
- **Enums:** `UPPER_SNAKE_CASE` values. Prefix with type name. E.g., `STATUS_ACTIVE`.
- **Enum zero value:** `TYPE_UNSPECIFIED`. E.g., `STATUS_UNSPECIFIED = 0;`.
- **Packages:** `lower.dot.separated`, versioned. E.g., `acme.users.v1`.
- **Oneofs:** `lower_snake_case`.

### File Organization

```
proto/
├── buf.yaml
├── acme/
│   ├── common/
│   │   └── v1/
│   │       └── money.proto
│   ├── inventory/
│   │   └── v1/
│   │       ├── product.proto
│   │       └── warehouse.proto
│   └── orders/
│       └── v1/
│           └── order.proto
```

- Version packages: `v1`, `v2`.
- Separate service definitions from message definitions when schemas are shared across services.
- One top-level message per file when messages grow complex.

## Protobuf Editions

Editions replace `syntax = "proto2"` / `syntax = "proto3"` with numbered editions and feature flags.

### Declaration

```proto
edition = "2024";

package acme.users.v1;

message User {
  string id = 1;
  string name = 2;
}
```

### Feature Flags

Override defaults at file, message, or field level:

```proto
edition = "2024";

message Event {
  // Override field presence behavior for this field
  string name = 1 [features.field_presence = IMPLICIT];

  // Explicit presence (the edition 2024 default)
  optional string description = 2;
}
```

Key features controlled by editions:
- `field_presence`: `EXPLICIT` (default in 2024) vs `IMPLICIT` (proto3 behavior).
- `enum_type`: `OPEN` (unknown values preserved) vs `CLOSED`.
- `repeated_field_encoding`: `PACKED` (default) vs `EXPANDED`.
- `message_encoding`: `LENGTH_PREFIXED` vs `DELIMITED`.

### Edition Timeline

| Edition | Status | Changes |
|---------|--------|---------|
| 2023 | Stable | Unified proto2/proto3 into single model |
| 2024 | Stable | Current recommended edition |
| 2025 | Planned | No-op edition (no behavioral changes); easy upgrade path |

### Migration from proto3

1. Replace `syntax = "proto3";` with `edition = "2024";`.
2. Review default feature flags—edition 2024 defaults to explicit field presence.
3. Add `[features.field_presence = IMPLICIT]` to fields that relied on proto3 implicit presence.
4. Use the Prototiller tool to automate migration and insert necessary overrides.
5. Wire format does not change—full backward/forward compatibility preserved.

## Language Integration

### Go

```go
import "google.golang.org/protobuf/proto"

product := &inventoryv1.Product{
    Id:       "p-123",
    Name:     "Widget",
    Quantity: 42,
    Price:    9.99,
}

// Serialize
data, err := proto.Marshal(product)

// Deserialize
var p inventoryv1.Product
err = proto.Unmarshal(data, &p)
```

### Python

```python
from acme.inventory.v1 import product_pb2

product = product_pb2.Product(
    id="p-123",
    name="Widget",
    quantity=42,
    price=9.99,
)

# Serialize
data = product.SerializeToString()

# Deserialize
p = product_pb2.Product()
p.ParseFromString(data)
```

### TypeScript (protobuf-ts)

```typescript
import { Product } from "./gen/acme/inventory/v1/product";

const product = Product.create({
  id: "p-123",
  name: "Widget",
  quantity: 42,
  price: 9.99,
});

const bytes = Product.toBinary(product);
const decoded = Product.fromBinary(bytes);
```

### Rust (prost)

```rust
use prost::Message;

let product = Product {
    id: "p-123".to_string(),
    name: "Widget".to_string(),
    quantity: 42,
    price: 9.99,
};

let mut buf = Vec::new();
product.encode(&mut buf).unwrap();

let decoded = Product::decode(&buf[..]).unwrap();
```

## Performance

### Wire Format

Five wire types:

| Wire Type | ID | Used For |
|-----------|----|----------|
| Varint | 0 | int32, int64, uint32, uint64, sint32, sint64, bool, enum |
| 64-bit | 1 | fixed64, sfixed64, double |
| Length-delimited | 2 | string, bytes, messages, packed repeated |
| 32-bit | 5 | fixed32, sfixed32, float |

Each field encoded as: `(field_number << 3) | wire_type` followed by the value.

### Varint Encoding

Variable-length encoding. Each byte uses 7 bits for data, 1 bit (MSB) as continuation flag:
- `1` → `0x01` (1 byte)
- `150` → `0x96 0x01` (2 bytes)
- `int32` negative values use 10 bytes—prefer `sint32` for frequently negative values.

### Packed Repeated Fields

In proto3, numeric `repeated` fields default to packed encoding:
- **Unpacked:** each element gets its own tag+value → `[tag][val][tag][val]...`
- **Packed:** single tag + length + concatenated values → `[tag][length][val val val...]`
- Packed saves significant space for large arrays.

### Size Optimization

- Assign field numbers 1–15 to hot fields (1-byte tag).
- Use `sint32`/`sint64` for values that are often negative.
- Use `fixed32`/`fixed64` when values consistently exceed 2^28/2^56.
- Prefer `bytes` over `string` when UTF-8 validation is unnecessary.
- Avoid deeply nested messages—each nesting adds length-prefix overhead.
- Use `optional` to skip serializing default values when using editions with explicit presence.

## Validation (protovalidate)

<!-- tested: pass -->
