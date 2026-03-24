#!/usr/bin/env bash
#
# proto-init.sh — Initialize a protobuf project with buf.yaml, buf.gen.yaml,
# proper directory structure, and .gitignore for generated code.
#
# Usage:
#   ./proto-init.sh <project-name> <language>
#
# Arguments:
#   project-name  Name of the project (e.g., "payments", "users")
#   language      Target language: go, ts, python
#
# Examples:
#   ./proto-init.sh payments go
#   ./proto-init.sh users ts
#   ./proto-init.sh auth python
#
# Creates:
#   <project-name>/
#   ├── buf.yaml
#   ├── buf.gen.yaml
#   ├── .gitignore
#   ├── proto/
#   │   └── <project-name>/
#   │       └── v1/
#   │           └── <project-name>.proto
#   └── gen/              (gitignored)

set -euo pipefail

# --- Argument validation ---

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <project-name> <language>"
    echo "  language: go | ts | python"
    exit 1
fi

PROJECT="$1"
LANG="$2"

if [[ ! "$PROJECT" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    echo "Error: project name must be lowercase alphanumeric (a-z, 0-9, -, _), starting with a letter."
    exit 1
fi

if [[ "$LANG" != "go" && "$LANG" != "ts" && "$LANG" != "python" ]]; then
    echo "Error: language must be one of: go, ts, python"
    exit 1
fi

if [[ -d "$PROJECT" ]]; then
    echo "Error: directory '$PROJECT' already exists."
    exit 1
fi

# --- Helper: convert kebab-case to PascalCase ---
to_pascal() {
    echo "$1" | sed -E 's/(^|[-_])([a-z])/\U\2/g'
}

SERVICE_NAME="$(to_pascal "$PROJECT")Service"
MSG_NAME="$(to_pascal "$PROJECT")"

# --- Create directory structure ---

echo "Creating project: $PROJECT (language: $LANG)"

mkdir -p "$PROJECT/proto/$PROJECT/v1"
mkdir -p "$PROJECT/gen"

# --- buf.yaml ---

cat > "$PROJECT/buf.yaml" << 'BUFYAML'
version: v2
modules:
  - path: proto
lint:
  use: [STANDARD]
  enum_zero_value_suffix: _UNSPECIFIED
  rpc_allow_google_protobuf_empty_requests: true
  rpc_allow_google_protobuf_empty_responses: true
  service_suffix: Service
  allow_comment_ignores: true
breaking:
  use: [FILE]
BUFYAML

# --- buf.gen.yaml (language-specific) ---

case "$LANG" in
  go)
    cat > "$PROJECT/buf.gen.yaml" << GENEOF
version: v2
managed:
  enabled: true
  override:
    - file_option: go_package_prefix
      value: github.com/yourorg/$PROJECT/gen/go
plugins:
  - remote: buf.build/protocolbuffers/go
    out: gen/go
    opt: paths=source_relative
  - remote: buf.build/grpc/go
    out: gen/go
    opt: paths=source_relative
clean: true
GENEOF
    ;;
  ts)
    cat > "$PROJECT/buf.gen.yaml" << 'GENEOF'
version: v2
plugins:
  - remote: buf.build/bufbuild/es
    out: gen/ts
    opt: target=ts
  - remote: buf.build/connectrpc/es
    out: gen/ts
    opt: target=ts
clean: true
GENEOF
    ;;
  python)
    cat > "$PROJECT/buf.gen.yaml" << 'GENEOF'
version: v2
plugins:
  - remote: buf.build/protocolbuffers/python
    out: gen/python
  - remote: buf.build/grpc/python
    out: gen/python
clean: true
GENEOF
    ;;
esac

# --- .gitignore ---

cat > "$PROJECT/.gitignore" << 'GITIGNORE'
# Generated code
gen/

# Buf lock file (optional — some teams commit this)
# buf.lock
GITIGNORE

# --- Starter proto file ---

cat > "$PROJECT/proto/$PROJECT/v1/$PROJECT.proto" << PROTOEOF
syntax = "proto3";
package $PROJECT.v1;

import "google/protobuf/timestamp.proto";
import "google/protobuf/field_mask.proto";

// $MSG_NAME represents a $PROJECT resource.
message $MSG_NAME {
  string id = 1;
  string name = 2;
  google.protobuf.Timestamp created_at = 3;
  google.protobuf.Timestamp updated_at = 4;
}

// Create

message Create${MSG_NAME}Request {
  $MSG_NAME $PROJECT = 1;
}

message Create${MSG_NAME}Response {
  $MSG_NAME $PROJECT = 1;
}

// Get

message Get${MSG_NAME}Request {
  string id = 1;
}

message Get${MSG_NAME}Response {
  $MSG_NAME $PROJECT = 1;
}

// List

message List${MSG_NAME}sRequest {
  int32 page_size = 1;
  string page_token = 2;
  google.protobuf.FieldMask read_mask = 3;
}

message List${MSG_NAME}sResponse {
  repeated $MSG_NAME ${PROJECT}s = 1;
  string next_page_token = 2;
}

// Update

message Update${MSG_NAME}Request {
  $MSG_NAME $PROJECT = 1;
  google.protobuf.FieldMask update_mask = 2;
}

message Update${MSG_NAME}Response {
  $MSG_NAME $PROJECT = 1;
}

// Delete

message Delete${MSG_NAME}Request {
  string id = 1;
}

message Delete${MSG_NAME}Response {}

// Service

service $SERVICE_NAME {
  rpc Create$MSG_NAME(Create${MSG_NAME}Request) returns (Create${MSG_NAME}Response);
  rpc Get$MSG_NAME(Get${MSG_NAME}Request) returns (Get${MSG_NAME}Response);
  rpc List${MSG_NAME}s(List${MSG_NAME}sRequest) returns (List${MSG_NAME}sResponse);
  rpc Update$MSG_NAME(Update${MSG_NAME}Request) returns (Update${MSG_NAME}Response);
  rpc Delete$MSG_NAME(Delete${MSG_NAME}Request) returns (Delete${MSG_NAME}Response);
}
PROTOEOF

# --- Done ---

echo ""
echo "Project initialized at ./$PROJECT/"
echo ""
echo "Structure:"
find "$PROJECT" -type f | sort | sed 's/^/  /'
echo ""
echo "Next steps:"
echo "  cd $PROJECT"
echo "  buf dep update    # Fetch dependencies"
echo "  buf lint          # Validate proto files"
echo "  buf generate      # Generate code"
