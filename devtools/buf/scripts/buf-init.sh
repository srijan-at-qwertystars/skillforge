#!/bin/bash
# buf-init.sh - Initialize a new Buf project
# Usage: ./buf-init.sh [module-name] [output-dir]

set -euo pipefail

MODULE_NAME="${1:-$(basename "$PWD")}"
OUTPUT_DIR="${2:-.}"
ORG_NAME="${ORG_NAME:-acme}"

echo "=== Initializing Buf Project ==="
echo "Module: $MODULE_NAME"
echo "Output: $OUTPUT_DIR"
echo ""

mkdir -p "$OUTPUT_DIR/proto/$ORG_NAME/$MODULE_NAME/v1"

# Create buf.yaml
cat > "$OUTPUT_DIR/buf.yaml" << 'EOF'
version: v1
name: buf.build/ORG_NAME/MODULE_NAME
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
EOF

# Replace placeholders
sed -i.bak "s/ORG_NAME/$ORG_NAME/g" "$OUTPUT_DIR/buf.yaml"
sed -i.bak "s/MODULE_NAME/$MODULE_NAME/g" "$OUTPUT_DIR/buf.yaml"
rm -f "$OUTPUT_DIR/buf.yaml.bak"

# Create buf.gen.yaml
cat > "$OUTPUT_DIR/buf.gen.yaml" << 'EOF'
version: v1
managed:
  enabled: true
plugins:
  # Go
  - plugin: go
    out: gen/go
    opt:
      - paths=source_relative
  - plugin: go-grpc
    out: gen/go
    opt:
      - paths=source_relative
EOF

# Create example proto file
cat > "$OUTPUT_DIR/proto/$ORG_NAME/$MODULE_NAME/v1/${MODULE_NAME}.proto" << EOF
syntax = "proto3";

package $ORG_NAME.$MODULE_NAME.v1;

option go_package = "github.com/$ORG_NAME/$MODULE_NAME/gen/go/$ORG_NAME/$MODULE_NAME/v1;${MODULE_NAME}v1";

// ${MODULE_NAME^} represents the main entity.
message $(echo "$MODULE_NAME" | sed 's/.*/\u&/') {
  // Unique identifier.
  string id = 1;

  // Display name.
  string name = 2;

  // When the entity was created.
  string create_time = 3;
}

// Service for managing $(echo "$MODULE_NAME" | sed 's/.*/\u&/')s.
service $(echo "$MODULE_NAME" | sed 's/.*/\u&/')Service {
  // Get retrieves an entity by ID.
  rpc Get(GetRequest) returns (GetResponse);
}

message GetRequest {
  string id = 1;
}

message GetResponse {
  $(echo "$MODULE_NAME" | sed 's/.*/\u&/') $(echo "$MODULE_NAME" | tr '[:upper:]' '[:lower:]') = 1;
}
EOF

# Create .gitignore
cat > "$OUTPUT_DIR/.gitignore" << 'EOF'
# Buf generated code
gen/
*.binpb
*.json

# IDE
.idea/
.vscode/
*.swp
*.swo
*~
EOF

echo "✓ Created buf.yaml"
echo "✓ Created buf.gen.yaml"
echo "✓ Created example proto file"
echo "✓ Created .gitignore"
echo ""
echo "Next steps:"
echo "  1. Update buf.yaml with your organization name"
echo "  2. Add/remove plugins in buf.gen.yaml as needed"
echo "  3. Run 'buf generate' to generate code"
echo "  4. Run 'buf lint' to check your protos"
