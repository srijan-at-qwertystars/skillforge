# Buf Ecosystem Deep Dive

> Complete reference for the Buf CLI, BSR, and protobuf toolchain.

## Table of Contents

- [Installation](#installation)
- [buf.yaml v2](#bufyaml-v2)
- [buf.gen.yaml](#bufgenyaml)
- [Lint Rules](#lint-rules)
- [Breaking Change Detection](#breaking-change-detection)
- [BSR (Buf Schema Registry)](#bsr-buf-schema-registry)
- [Managed Mode](#managed-mode)
- [Remote Plugins](#remote-plugins)
- [buf curl](#buf-curl)
- [Migration from protoc](#migration-from-protoc)
- [CI Integration](#ci-integration)

---

## Installation

```bash
# macOS
brew install bufbuild/buf/buf

# Linux (binary)
BIN="/usr/local/bin" && \
VERSION="1.50.0" && \
curl -sSL "https://github.com/bufbuild/buf/releases/download/v${VERSION}/buf-$(uname -s)-$(uname -m)" \
  -o "${BIN}/buf" && chmod +x "${BIN}/buf"

# Go install
go install github.com/bufbuild/buf/cmd/buf@latest

# npm (for CI)
npm install --save-dev @bufbuild/buf

# Verify
buf --version
```

---

## buf.yaml v2

v2 is the current config format. Key differences from v1:
- `modules` array replaces top-level `name`/`root`.
- Multiple modules in one workspace.
- `deps` at top level.

### Minimal Config

```yaml
version: v2
modules:
  - path: proto
lint:
  use: [STANDARD]
breaking:
  use: [FILE]
```

### Full Config

```yaml
version: v2

# Module definitions
modules:
  - path: proto
    name: buf.build/acme/payments  # BSR module name (optional for local)
    excludes:
      - proto/vendor  # Exclude vendored protos

# Dependencies from BSR
deps:
  - buf.build/googleapis/googleapis
  - buf.build/grpc/grpc
  - buf.build/bufbuild/protovalidate

# Lint configuration
lint:
  use:
    - STANDARD            # All recommended rules
  except:
    - PACKAGE_VERSION_SUFFIX  # If you don't version packages
  ignore:
    - proto/vendor        # Skip vendored files
  ignore_only:
    ENUM_VALUE_PREFIX:
      - proto/legacy/old.proto  # Granular ignore
  enum_zero_value_suffix: _UNSPECIFIED
  rpc_allow_same_request_response: false
  rpc_allow_google_protobuf_empty_requests: true
  rpc_allow_google_protobuf_empty_responses: true
  service_suffix: Service
  allow_comment_ignores: true  # Enable // buf:lint:ignore RULE

# Breaking change config
breaking:
  use:
    - FILE                # Strictest: per-file checks
  except: []
  ignore:
    - proto/experimental  # Skip experimental protos
  ignore_unstable_packages: true  # Ignore alpha/beta packages
```

### Multi-Module Workspace

```yaml
version: v2
modules:
  - path: proto/payments
    name: buf.build/acme/payments
  - path: proto/users
    name: buf.build/acme/users
  - path: proto/common
    name: buf.build/acme/common
```

### After Editing buf.yaml

```bash
# Update dependencies lock file
buf dep update

# Verify config
buf build
```

---

## buf.gen.yaml

Controls code generation. Replaces `protoc` plugin flags.

### v2 Format

```yaml
version: v2

# Managed mode — auto-set language-specific options
managed:
  enabled: true
  override:
    - file_option: go_package_prefix
      value: github.com/acme/payments/gen/go

# Plugins
plugins:
  # Go protobuf
  - remote: buf.build/protocolbuffers/go
    out: gen/go
    opt: paths=source_relative

  # Go gRPC
  - remote: buf.build/grpc/go
    out: gen/go
    opt: paths=source_relative

  # Connect-Go
  - remote: buf.build/connectrpc/go
    out: gen/go
    opt: paths=source_relative

  # TypeScript (Connect-ES)
  - remote: buf.build/connectrpc/es
    out: gen/ts
    opt: target=ts

  # Protobuf-ES (base TS types)
  - remote: buf.build/bufbuild/es
    out: gen/ts
    opt: target=ts

  # Python
  - remote: buf.build/protocolbuffers/python
    out: gen/python

  # Python gRPC
  - remote: buf.build/grpc/python
    out: gen/python

  # Validate (protovalidate)
  - remote: buf.build/bufbuild/protovalidate-go
    out: gen/go
    opt: paths=source_relative

# Clean output dirs before generating
clean: true

# Only generate for specific inputs
inputs:
  - directory: proto
```

### Local Plugins (Instead of Remote)

```yaml
plugins:
  - local: protoc-gen-go
    out: gen/go
    opt: paths=source_relative

  - local:
      - go
      - run
      - github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway
    out: gen/go
    opt: paths=source_relative
```

### Generate

```bash
# Generate all
buf generate

# Generate from specific input
buf generate proto/payments

# Generate from BSR
buf generate buf.build/googleapis/googleapis

# Dry run (check config without generating)
buf generate --dry-run
```

---

## Lint Rules

### Rule Categories

| Category | Description |
|----------|-------------|
| `MINIMAL` | Bare minimum (unique names, valid syntax) |
| `BASIC` | MINIMAL + naming conventions |
| `STANDARD` | BASIC + style rules (recommended) |
| `COMMENTS` | Require comments on services/RPCs |

### Key Rules in STANDARD

| Rule | What It Checks | Example Violation |
|------|---------------|-------------------|
| `DIRECTORY_SAME_PACKAGE` | Files in same dir = same package | `a/foo.proto` and `a/bar.proto` with different packages |
| `PACKAGE_DEFINED` | Package must be set | Missing `package` statement |
| `PACKAGE_DIRECTORY_MATCH` | Package path = directory path | `package a.b;` in `c/d/file.proto` |
| `PACKAGE_VERSION_SUFFIX` | Package ends with version | `acme.payments` without `.v1` |
| `ENUM_VALUE_PREFIX` | Enum values prefixed with enum name | `PENDING` instead of `STATUS_PENDING` |
| `ENUM_ZERO_VALUE_SUFFIX` | Zero value ends with `_UNSPECIFIED` | `STATUS_UNKNOWN = 0` |
| `FIELD_LOWER_SNAKE_CASE` | Fields use snake_case | `firstName` instead of `first_name` |
| `MESSAGE_PASCAL_CASE` | Messages use PascalCase | `payment_request` |
| `SERVICE_SUFFIX` | Services end with `Service` | `Payments` instead of `PaymentService` |
| `RPC_REQUEST_RESPONSE_UNIQUE` | Each RPC has unique req/resp types | Two RPCs sharing `GenericRequest` |
| `RPC_REQUEST_STANDARD_NAME` | Request named `<Method>Request` | `CreateReq` |
| `RPC_RESPONSE_STANDARD_NAME` | Response named `<Method>Response` | `CreateResp` |

### Running Lint

```bash
# Lint all proto files
buf lint

# Lint specific directory
buf lint proto/payments

# Lint with specific config
buf lint --config buf-strict.yaml

# Show all available rules
buf lint --list-rules
```

### Inline Ignores

```protobuf
// buf:lint:ignore ENUM_VALUE_PREFIX
// buf:lint:ignore FIELD_LOWER_SNAKE_CASE
message LegacyMessage {
    string FirstName = 1; // buf:lint:ignore FIELD_LOWER_SNAKE_CASE
}
```

Requires `allow_comment_ignores: true` in buf.yaml.

### Custom Lint Config Examples

**Strict (all rules + comments):**
```yaml
lint:
  use: [STANDARD, COMMENTS]
```

**Relaxed (for legacy protos):**
```yaml
lint:
  use: [MINIMAL]
  ignore:
    - proto/legacy
```

---

## Breaking Change Detection

### Detection Levels

| Level | Checks | Strictness |
|-------|--------|-----------|
| `FILE` | Per-file changes | Strictest — renaming files breaks |
| `PACKAGE` | Per-package changes | Medium — moving between files in same package OK |
| `WIRE` | Wire compatibility only | Least strict — only catches wire format breaks |
| `WIRE_JSON` | Wire + JSON compatibility | Wire + JSON serialization |

### Commands

```bash
# Against git branch
buf breaking --against '.git#branch=main'

# Against git tag
buf breaking --against '.git#tag=v1.0.0'

# Against specific commit
buf breaking --against '.git#ref=abc123'

# Against BSR
buf breaking --against 'buf.build/acme/payments'

# Against local directory
buf breaking --against '../old-protos'

# Against archive
buf breaking --against 'https://example.com/protos.tar.gz'
```

### What Each Level Catches

**FILE level catches:**
- Removing files, services, methods, messages, fields, enums, enum values, oneofs.
- Changing field types, numbers, labels (optional→repeated).
- Changing RPC input/output types.
- Changing enum value numbers.
- File-level moves and renames.

**WIRE level only catches:**
- Field number changes.
- Incompatible type changes.
- Required field additions (proto2).

### Ignoring Specific Breaks

```yaml
breaking:
  use: [FILE]
  except:
    - FILE_SAME_PACKAGE  # Allow moving files between packages
  ignore_unstable_packages: true  # Ignore packages with "alpha"/"beta"
```

### Per-File Ignores

```protobuf
// buf:lint:ignore — no equivalent for breaking
// Use buf.yaml ignore list instead
```

---

## BSR (Buf Schema Registry)

Central registry for protobuf modules. Like npm for protos.

### Authentication

```bash
# Login to BSR
buf registry login

# Set token via environment
export BUF_TOKEN=your-token-here
```

### Push to BSR

```bash
# Push module
buf push

# Push with labels
buf push --label v1.2.0
```

### Consume from BSR

```yaml
# buf.yaml — add dependency
deps:
  - buf.build/googleapis/googleapis
  - buf.build/grpc/grpc
```

```bash
# Update lock file
buf dep update
```

### Generated SDKs

BSR can generate SDKs on demand:

```bash
# Go
go get buf.build/gen/go/acme/payments/protocolbuffers/go@latest

# npm
npm install @buf/acme_payments.connectrpc_es@latest
```

### Module Management

```bash
# Create module on BSR
buf beta registry module create buf.build/acme/payments --visibility public

# List modules
buf beta registry module list --owner acme

# View module
buf beta registry module info buf.build/acme/payments
```

---

## Managed Mode

Automatically sets language-specific options so you don't have to put them in every `.proto` file.

### Go Package Management

```yaml
managed:
  enabled: true
  override:
    # Set go_package prefix for all files
    - file_option: go_package_prefix
      value: github.com/acme/monorepo/gen/go

    # Except for specific modules
    - file_option: go_package_prefix
      module: buf.build/googleapis/googleapis
      value: google.golang.org/genproto

    # Override specific file
    - file_option: go_package
      path: acme/payments/v1/payments.proto
      value: github.com/acme/payments/v1;paymentsv1
```

### Java

```yaml
managed:
  enabled: true
  override:
    - file_option: java_multiple_files
      value: true
    - file_option: java_package_prefix
      value: com.acme.proto
```

### Disable for Specific Files

```yaml
managed:
  enabled: true
  disable:
    - file_option: go_package
      module: buf.build/googleapis/googleapis
```

---

## Remote Plugins

BSR hosts pre-built codegen plugins. No local plugin installation needed.

### Available Plugins

| Plugin | Purpose |
|--------|---------|
| `buf.build/protocolbuffers/go` | Go protobuf types |
| `buf.build/grpc/go` | Go gRPC service stubs |
| `buf.build/connectrpc/go` | Connect-Go service stubs |
| `buf.build/bufbuild/es` | TypeScript protobuf types |
| `buf.build/connectrpc/es` | Connect-ES service stubs |
| `buf.build/protocolbuffers/python` | Python protobuf types |
| `buf.build/grpc/python` | Python gRPC stubs |
| `buf.build/protocolbuffers/java` | Java protobuf types |
| `buf.build/grpc/java` | Java gRPC stubs |
| `buf.build/community/neoeinstein-prost` | Rust prost types |
| `buf.build/community/neoeinstein-tonic` | Rust tonic gRPC stubs |
| `buf.build/bufbuild/protovalidate-go` | Go validation |
| `buf.build/grpc-ecosystem/gateway` | gRPC-Gateway REST proxy |

### Pinning Plugin Versions

```yaml
plugins:
  - remote: buf.build/protocolbuffers/go:v1.36.6
    out: gen/go
    opt: paths=source_relative
```

---

## buf curl

Make RPC calls from the command line. Works with Connect, gRPC, and gRPC-Web.

```bash
# Unary call (Connect protocol — uses JSON by default)
buf curl --data '{"amount":{"currency_code":"USD","units":100}}' \
  http://localhost:8080/acme.payments.v1.PaymentService/CreatePayment

# gRPC protocol
buf curl --protocol grpc --data '{"id":"pay_1"}' \
  http://localhost:50051/acme.payments.v1.PaymentService/GetPayment

# gRPC-Web protocol
buf curl --protocol grpcweb --data '{}' \
  http://localhost:8080/acme.payments.v1.PaymentService/ListPayments

# With headers
buf curl -H 'Authorization: Bearer tok123' \
  --data '{}' \
  http://localhost:8080/acme.payments.v1.PaymentService/ListPayments

# Using schema from BSR (no reflection needed)
buf curl --schema buf.build/acme/payments \
  --data '{}' \
  http://localhost:8080/acme.payments.v1.PaymentService/ListPayments

# Using local schema
buf curl --schema proto \
  --data '{}' \
  http://localhost:8080/acme.payments.v1.PaymentService/ListPayments

# Server streaming
buf curl --data '{"filter":"active"}' \
  http://localhost:8080/acme.payments.v1.PaymentService/WatchPayments

# Verbose output
buf curl -v --data '{}' \
  http://localhost:8080/acme.payments.v1.PaymentService/ListPayments
```

### buf curl vs grpcurl

| Feature | buf curl | grpcurl |
|---------|----------|---------|
| Connect protocol | ✅ | ❌ |
| gRPC protocol | ✅ | ✅ |
| gRPC-Web protocol | ✅ | ❌ |
| BSR schema | ✅ | ❌ |
| Reflection | ✅ | ✅ |
| Streaming | ✅ | ✅ |
| Installation | Bundled with buf | Separate install |

---

## Migration from protoc

### Step 1: Create buf.yaml

```bash
# In your proto root directory
buf config init
```

### Step 2: Map protoc Flags to buf.gen.yaml

**Before (protoc):**
```bash
protoc \
  -I proto \
  -I third_party/googleapis \
  --go_out=gen/go --go_opt=paths=source_relative \
  --go-grpc_out=gen/go --go-grpc_opt=paths=source_relative \
  proto/payments/v1/payments.proto
```

**After (buf):**
```yaml
# buf.gen.yaml
version: v2
managed:
  enabled: true
  override:
    - file_option: go_package_prefix
      value: github.com/acme/project/gen/go
plugins:
  - remote: buf.build/protocolbuffers/go
    out: gen/go
    opt: paths=source_relative
  - remote: buf.build/grpc/go
    out: gen/go
    opt: paths=source_relative
```

### Step 3: Replace Third-Party Proto Imports

**Before:** Vendored `google/api/annotations.proto` in your repo.

**After:**
```yaml
# buf.yaml
deps:
  - buf.build/googleapis/googleapis
```

```bash
buf dep update
```

### Step 4: Replace Makefile/Scripts

**Before:**
```makefile
proto:
    protoc -I proto -I third_party/... --go_out=... proto/**/*.proto
```

**After:**
```makefile
proto:
    buf generate
```

### Step 5: Validate

```bash
buf build           # Verify all protos compile
buf lint            # Check style
buf generate        # Generate code
diff -r gen/ old-gen/  # Compare output
```

### Common Migration Issues

| Issue | Fix |
|-------|-----|
| Import paths differ | Adjust `modules[].path` in buf.yaml |
| Missing googleapis | Add `buf.build/googleapis/googleapis` to deps |
| `option go_package` everywhere | Use managed mode to auto-set |
| Custom protoc plugins | Use `local:` plugin in buf.gen.yaml |
| Makefile parallel builds | `buf generate` handles parallelism internally |

---

## CI Integration

### GitHub Actions

```yaml
name: Proto CI
on: [push, pull_request]

jobs:
  proto:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: bufbuild/buf-setup-action@v1
        with:
          version: "1.50.0"

      - uses: bufbuild/buf-lint-action@v1
        with:
          input: proto

      - uses: bufbuild/buf-breaking-action@v1
        with:
          input: proto
          against: "https://github.com/${{ github.repository }}.git#branch=${{ github.event.pull_request.base.ref }}"

      # Optional: push to BSR on main
      - uses: bufbuild/buf-push-action@v1
        if: github.ref == 'refs/heads/main'
        with:
          input: proto
          buf_token: ${{ secrets.BUF_TOKEN }}
```

### GitLab CI

```yaml
proto:
  image: bufbuild/buf:latest
  script:
    - buf lint
    - buf breaking --against "${CI_REPOSITORY_URL}#branch=${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}"
  rules:
    - if: $CI_MERGE_REQUEST_ID
```

### Pre-Commit Hook

```bash
#!/usr/bin/env bash
# .git/hooks/pre-commit
if git diff --cached --name-only | grep -q '\.proto$'; then
    buf lint || exit 1
    buf breaking --against '.git#branch=main' || exit 1
fi
```

### Makefile Integration

```makefile
.PHONY: proto-lint proto-breaking proto-generate proto-check

proto-lint:
	buf lint

proto-breaking:
	buf breaking --against '.git#branch=main'

proto-generate:
	buf generate

proto-check: proto-lint proto-breaking
	@echo "Proto checks passed"

proto: proto-check proto-generate
	@echo "Proto pipeline complete"
```
