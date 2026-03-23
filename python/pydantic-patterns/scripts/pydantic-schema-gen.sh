#!/usr/bin/env bash
# pydantic-schema-gen.sh — Generate JSON Schema from a Pydantic model module.
#
# Usage:
#   pydantic-schema-gen.sh <module_path> <ModelName>
#   pydantic-schema-gen.sh <module_path> <ModelName> --output schema.json
#   pydantic-schema-gen.sh <module_path> <ModelName> --mode serialization
#
# Examples:
#   pydantic-schema-gen.sh app/models.py User
#   pydantic-schema-gen.sh app.models User --output user_schema.json
#   pydantic-schema-gen.sh app/models.py User --mode serialization --indent 4

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <module> <model_name> [OPTIONS]"
    echo ""
    echo "Generate JSON Schema from a Pydantic model."
    echo ""
    echo "Arguments:"
    echo "  module       Python module path (e.g., app.models or app/models.py)"
    echo "  model_name   Name of the Pydantic model class"
    echo ""
    echo "Options:"
    echo "  --output, -o FILE   Write schema to file (default: stdout)"
    echo "  --mode MODE         Schema mode: 'validation' (default) or 'serialization'"
    echo "  --indent N          JSON indentation (default: 2)"
    echo "  --help              Show this help message"
}

MODULE=""
MODEL=""
OUTPUT=""
MODE="validation"
INDENT=2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output|-o)  OUTPUT="$2"; shift 2 ;;
        --mode)       MODE="$2"; shift 2 ;;
        --indent)     INDENT="$2"; shift 2 ;;
        --help)       usage; exit 0 ;;
        -*)           echo "Unknown option: $1"; usage; exit 1 ;;
        *)
            if [[ -z "$MODULE" ]]; then
                MODULE="$1"
            elif [[ -z "$MODEL" ]]; then
                MODEL="$1"
            else
                echo "Unexpected argument: $1"; usage; exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$MODULE" || -z "$MODEL" ]]; then
    echo "Error: module and model_name are required."
    usage
    exit 1
fi

# Convert file path to module path if needed
if [[ "$MODULE" == *.py ]]; then
    if [[ ! -f "$MODULE" ]]; then
        echo "Error: File '$MODULE' not found."
        exit 1
    fi
    MODULE="${MODULE%.py}"
    MODULE="${MODULE//\//.}"
fi

PYTHON_SCRIPT=$(cat <<PYEOF
import sys
import json
import importlib

try:
    mod = importlib.import_module("${MODULE}")
except ModuleNotFoundError as e:
    print(f"Error: Could not import module '${MODULE}': {e}", file=sys.stderr)
    sys.exit(1)

model_cls = getattr(mod, "${MODEL}", None)
if model_cls is None:
    available = [name for name in dir(mod) if not name.startswith("_")]
    print(f"Error: Model '${MODEL}' not found in '${MODULE}'.", file=sys.stderr)
    print(f"Available names: {', '.join(available)}", file=sys.stderr)
    sys.exit(1)

if not hasattr(model_cls, "model_json_schema"):
    print(f"Error: '{MODEL}' does not appear to be a Pydantic model.", file=sys.stderr)
    sys.exit(1)

schema = model_cls.model_json_schema(mode="${MODE}")
output = json.dumps(schema, indent=${INDENT}, default=str)
print(output)
PYEOF
)

if [[ -n "$OUTPUT" ]]; then
    python3 -c "$PYTHON_SCRIPT" > "$OUTPUT"
    echo "Schema written to $OUTPUT"
else
    python3 -c "$PYTHON_SCRIPT"
fi
