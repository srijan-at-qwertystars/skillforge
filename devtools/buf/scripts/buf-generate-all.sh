#!/bin/bash
# buf-generate-all.sh - Generate code for multiple languages using remote BSR plugins
# Usage: ./buf-generate-all.sh [output-dir]

set -euo pipefail

OUTPUT_DIR="${1:-gen}"

echo "=== Buf Multi-Language Generation ==="
echo "Output directory: $OUTPUT_DIR"
echo ""

# Create temporary buf.gen.yaml
TMP_CONFIG=$(mktemp)
cat > "$TMP_CONFIG" << EOF
version: v1
managed:
  enabled: true
plugins:
  # Go
  - plugin: buf.build/protocolbuffers/go
    out: $OUTPUT_DIR/go
    opt:
      - paths=source_relative
  - plugin: buf.build/grpc/go
    out: $OUTPUT_DIR/go
    opt:
      - paths=source_relative

  # Python
  - plugin: buf.build/protocolbuffers/python
    out: $OUTPUT_DIR/python
  - plugin: buf.build/grpc/python
    out: $OUTPUT_DIR/python

  # TypeScript/Connect
  - plugin: buf.build/bufbuild/es
    out: $OUTPUT_DIR/ts
    opt:
      - target=ts
  - plugin: buf.build/connectrpc/es
    out: $OUTPUT_DIR/ts
    opt:
      - target=ts

  # Java
  - plugin: buf.build/protocolbuffers/java
    out: $OUTPUT_DIR/java
  - plugin: buf.build/grpc/java
    out: $OUTPUT_DIR/java

  # C#
  - plugin: buf.build/protocolbuffers/csharp
    out: $OUTPUT_DIR/csharp

  # Ruby
  - plugin: buf.build/protocolbuffers/ruby
    out: $OUTPUT_DIR/ruby

  # PHP
  - plugin: buf.build/protocolbuffers/php
    out: $OUTPUT_DIR/php

  # Swift
  - plugin: buf.build/grpc/swift
    out: $OUTPUT_DIR/swift
EOF

echo "Generating code with remote BSR plugins..."
buf generate --template "$TMP_CONFIG"

# Cleanup
rm -f "$TMP_CONFIG"

echo ""
echo "=== Generated code in $OUTPUT_DIR/ ==="
find "$OUTPUT_DIR" -type f | head -20
