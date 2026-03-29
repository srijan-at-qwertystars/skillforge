---
name: buf
description: |
  Protocol Buffer toolchain for linting/generation. Use for proto code quality.
  NOT for general API design or gRPC implementation.
tested: true
---

# Buf Skill

## Quick Reference

| Command | Purpose |
|---------|---------|
| `buf lint` | Lint proto files against rules |
| `buf breaking --against .git#branch=main` | Detect breaking changes |
| `buf generate` | Generate code from protos |
| `buf build` | Validate and build proto image |
| `buf format -w` | Format proto files |

## Configuration Files

### buf.yaml (Module Config)

```yaml
version: v1
name: buf.build/acme/petapis
deps:
  - buf.build/googleapis/googleapis
breaking:
  use:
    - FILE
lint:
  use:
    - DEFAULT
  except:
    - PACKAGE_VERSION_SUFFIX
  enum_zero_value_suffix: _UNSPECIFIED
  rpc_allow_same_request_response: false
  service_suffix: Service
```

### buf.gen.yaml (Generation Config)

```yaml
version: v1
managed:
  enabled: true
plugins:
  - plugin: go
    out: gen/go
    opt:
      - paths=source_relative
  - plugin: go-grpc
    out: gen/go
    opt:
      - paths=source_relative
  - plugin: python
    out: gen/python
  - plugin: protoc-gen-grpc-python
    out: gen/python
```

## Core Commands

### Lint

Check proto files against lint rules:

```bash
# Lint current module
buf lint

# Lint specific paths
buf lint proto/ api/

# Lint with custom config
buf lint --config buf.yaml

# Output as JSON
buf lint --error-format=json
```

**Output:**
```
api/v1/pet.proto:12:1:Package name "api.v1" should be suffixed with a version (e.g., "api.v1beta1", "api.v1").
api/v1/pet.proto:15:3:Field "petID" should use lower_snake_case.
```

### Breaking Change Detection

Detect breaking changes against a reference:

```bash
# Against git branch
buf breaking --against .git#branch=main

# Against previous commit
buf breaking --against .git#tag=v1.0.0

# Against BSR module
buf breaking --against buf.build/acme/petapis:v1.0.0

# Against local directory
buf breaking --against ../previous-version
```

**Output:**
```
api/v1/pet.proto:15:3:Field "1" on message "Pet" changed type from "string" to "int32".
api/v1/pet.proto:18:1:Previously present message "OldMessage" was deleted.
```

### Generate

Generate code from proto files:

```bash
# Generate with buf.gen.yaml
buf generate

# Generate specific proto files
buf generate proto/v1/*.proto

# Generate with template
buf generate --template buf.gen.yaml

# Generate from BSR
buf generate buf.build/googleapis/googleapis
```

**Output:**
```
gen/go/api/v1/pet.pb.go
gen/go/api/v1/pet_grpc.pb.go
gen/python/api/v1/pet_pb2.py
gen/python/api/v1/pet_pb2_grpc.py
```

### Build

Build and validate proto image:

```bash
# Build current module
buf build -o image.binpb

# Build as JSON
buf build -o image.json

# Build and validate imports
buf build --error-format=json
```

### Format

Format proto files:

```bash
# Check formatting (dry run)
buf format --diff

# Write formatted output
buf format -w

# Format specific file
buf format proto/v1/pet.proto -w
```

## Lint Rules

### Categories

| Category | Rules |
|----------|-------|
| `MINIMAL` | Basic proto3 validity |
| `BASIC` | Common style conventions |
| `DEFAULT` | Recommended rules |
| `COMMENTS` | Documentation requirements |
| `UNARY_RPC` | Unary RPC constraints |
| `PACKAGE_AFFINITY` | Package structure |

### Common Rule Exceptions

```yaml
lint:
  use:
    - DEFAULT
  except:
    - PACKAGE_VERSION_SUFFIX      # Skip version suffix requirement
    - PACKAGE_DIRECTORY_MATCH     # Skip directory/package matching
    - SERVICE_SUFFIX              # Skip Service suffix requirement
    - RPC_REQUEST_RESPONSE_UNIQUE # Allow same request/response types
```

### Breaking Categories

| Category | Checks |
|----------|--------|
| `FILE` | File-level changes |
| `PACKAGE` | Package-level changes |
| `WIRE` | Wire compatibility |
| `WIRE_JSON` | JSON wire compatibility |

## Best Practices

### Proto Structure

```
proto/
├── buf.yaml
├── acme/
│   └── pet/
│       └── v1/
│           ├── pet.proto
│           └── pet_service.proto
```

### Proto File Template

```protobuf
syntax = "proto3";

package acme.pet.v1;

import "google/protobuf/timestamp.proto";

// Pet represents an animal in the system.
message Pet {
  // Unique identifier for the pet.
  string pet_id = 1;

  // Display name of the pet.
  string name = 2;

  // Type of animal.
  enum Type {
    TYPE_UNSPECIFIED = 0;
    TYPE_DOG = 1;
    TYPE_CAT = 2;
  }
  Type type = 3;

  // When the pet was created.
  google.protobuf.Timestamp create_time = 4;
}

// PetService manages pets.
service PetService {
  // GetPet retrieves a pet by ID.
  rpc GetPet(GetPetRequest) returns (GetPetResponse);
}

message GetPetRequest {
  string pet_id = 1;
}

message GetPetResponse {
  Pet pet = 1;
}
```

### CI Integration

```yaml
# .github/workflows/buf.yaml
name: Buf
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: bufbuild/buf-action@v1
        with:
          lint: true
          breaking: true
          against: 'https://github.com/${{ github.repository }}.git#branch=main'
```

### Pre-commit Hook

```yaml
# .pre-commit-config.yaml
repos:
  - repo: local
    hooks:
      - id: buf-lint
        name: buf lint
        entry: buf lint
        language: system
        files: \.proto$
      - id: buf-breaking
        name: buf breaking
        entry: buf breaking --against .git#branch=main
        language: system
        files: \.proto$
        pass_filenames: false
```

## Common Patterns

### Multi-Language Generation

```yaml
# buf.gen.yaml
version: v1
managed:
  enabled: true
plugins:
  # Go
  - plugin: go
    out: gen/go
    opt: paths=source_relative
  - plugin: go-grpc
    out: gen/go
    opt: paths=source_relative
  
  # Python
  - plugin: python
    out: gen/python
  - plugin: grpc_python
    out: gen/python
    path: grpc_python_plugin
  
  # TypeScript
  - plugin: es
    out: gen/ts
    opt: target=ts
  - plugin: connect-es
    out: gen/ts
    opt: target=ts
```

### Remote Plugins (BSR)

```yaml
# buf.gen.yaml - no local plugin installation needed
version: v1
managed:
  enabled: true
plugins:
  - plugin: buf.build/protocolbuffers/go:v1.31.0
    out: gen/go
    opt: paths=source_relative
  - plugin: buf.build/grpc/go:v1.3.0
    out: gen/go
    opt: paths=source_relative
```

### Workspace Configuration

```yaml
# buf.work.yaml (root)
version: v1
directories:
  - proto
  - vendor/protos
```

## Troubleshooting

### Import Errors

```bash
# Check imports resolve
buf build --error-format=json

# List available imports
buf export -o /tmp/exports
```

### Plugin Not Found

```bash
# Verify plugin in PATH
which protoc-gen-go

# Or specify path in buf.gen.yaml
plugins:
  - plugin: go
    out: gen/go
    path: /usr/local/bin/protoc-gen-go
```

### Breaking Detection Fails

```bash
# Ensure git history available
buf breaking --against .git#branch=main,ref=HEAD~1

# Use explicit commit
buf breaking --against .git#commit=abc123
```

## BSR (Buf Schema Registry)

### Push Module

```bash
buf push
```

### Use Remote Module

```yaml
# buf.yaml
deps:
  - buf.build/googleapis/googleapis
  - buf.build/bufbuild/protovalidate
```

### Generate from Remote

```bash
buf generate buf.build/acme/petapis:v1.0.0
```

## Migration

### From protoc

```bash
# Old: protoc --go_out=. --go_opt=paths=source_relative *.proto
# New: buf generate

# Create buf.gen.yaml mapping protoc options to plugins
```

### From custom scripts

```bash
# Replace shell scripts with buf.gen.yaml
# Version pin plugins in config instead of manual management
```
