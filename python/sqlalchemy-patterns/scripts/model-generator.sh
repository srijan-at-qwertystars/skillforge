#!/usr/bin/env bash
# model-generator.sh — Generate a SQLAlchemy 2.0 model file
#
# Usage:
#   ./model-generator.sh <ModelName> <column_specs...>
#
# Column spec format: name:type[:nullable][:unique][:index]
#   Types: str, int, float, bool, text, datetime, date, uuid, json
#
# Examples:
#   ./model-generator.sh User "email:str:unique:index" "name:str" "bio:text:nullable" "age:int:nullable"
#   ./model-generator.sh Product "name:str" "price:float" "in_stock:bool" "metadata:json:nullable"
#   ./model-generator.sh Order "total:float" "status:str:index" "placed_at:datetime"
#
# Output: writes <model_name>.py to current directory (or MODELS_DIR if set).
# Also prints a suggested Alembic command.

set -euo pipefail

MODEL_NAME="${1:?Usage: $0 <ModelName> <column_specs...>}"
shift
COLUMNS=("$@")

if [ ${#COLUMNS[@]} -eq 0 ]; then
    echo "Error: At least one column spec required." >&2
    echo "Format: name:type[:nullable][:unique][:index]" >&2
    echo "Example: $0 User 'email:str:unique:index' 'name:str'" >&2
    exit 1
fi

# Convert CamelCase to snake_case for table name
TABLE_NAME=$(echo "$MODEL_NAME" | sed -r 's/([A-Z])/_\L\1/g' | sed 's/^_//')s
FILE_NAME=$(echo "$MODEL_NAME" | sed -r 's/([A-Z])/_\L\1/g' | sed 's/^_//')

OUTPUT_DIR="${MODELS_DIR:-.}"
OUTPUT_FILE="$OUTPUT_DIR/${FILE_NAME}.py"

if [ -f "$OUTPUT_FILE" ]; then
    echo "Error: $OUTPUT_FILE already exists. Remove it first or choose a different name." >&2
    exit 1
fi

# Track which imports we need
NEEDS_STRING=false
NEEDS_TEXT=false
NEEDS_FLOAT=false
NEEDS_BOOLEAN=false
NEEDS_DATETIME=false
NEEDS_DATE=false
NEEDS_UUID=false
NEEDS_JSON=false
NEEDS_OPTIONAL=false

# Parse columns and build column definitions
COLUMN_DEFS=""

for col_spec in "${COLUMNS[@]}"; do
    IFS=':' read -ra PARTS <<< "$col_spec"
    COL_NAME="${PARTS[0]}"
    COL_TYPE="${PARTS[1]:-str}"

    # Parse modifiers
    IS_NULLABLE=false
    IS_UNIQUE=false
    IS_INDEX=false
    for ((i=2; i<${#PARTS[@]}; i++)); do
        case "${PARTS[$i]}" in
            nullable) IS_NULLABLE=true ;;
            unique) IS_UNIQUE=true ;;
            index) IS_INDEX=true ;;
        esac
    done

    # Map type to SQLAlchemy
    case "$COL_TYPE" in
        str|string)
            SA_TYPE="String(255)"
            PY_TYPE="str"
            NEEDS_STRING=true
            ;;
        int|integer)
            SA_TYPE=""
            PY_TYPE="int"
            ;;
        float|decimal)
            SA_TYPE=""
            PY_TYPE="float"
            ;;
        bool|boolean)
            SA_TYPE=""
            PY_TYPE="bool"
            ;;
        text)
            SA_TYPE="Text"
            PY_TYPE="str"
            NEEDS_TEXT=true
            ;;
        datetime)
            SA_TYPE=""
            PY_TYPE="datetime"
            NEEDS_DATETIME=true
            ;;
        date)
            SA_TYPE=""
            PY_TYPE="date"
            NEEDS_DATE=true
            ;;
        uuid)
            SA_TYPE="Uuid"
            PY_TYPE="uuid.UUID"
            NEEDS_UUID=true
            ;;
        json)
            SA_TYPE="JSON"
            PY_TYPE="dict"
            NEEDS_JSON=true
            ;;
        *)
            echo "Warning: Unknown type '$COL_TYPE', defaulting to String" >&2
            SA_TYPE="String(255)"
            PY_TYPE="str"
            NEEDS_STRING=true
            ;;
    esac

    # Build Mapped type annotation
    if $IS_NULLABLE; then
        MAPPED_TYPE="Mapped[Optional[$PY_TYPE]]"
        NEEDS_OPTIONAL=true
    else
        MAPPED_TYPE="Mapped[$PY_TYPE]"
    fi

    # Build mapped_column args
    MC_ARGS=""
    if [ -n "$SA_TYPE" ]; then
        MC_ARGS="$SA_TYPE"
    fi
    if $IS_UNIQUE; then
        [ -n "$MC_ARGS" ] && MC_ARGS="$MC_ARGS, "
        MC_ARGS="${MC_ARGS}unique=True"
    fi
    if $IS_INDEX; then
        [ -n "$MC_ARGS" ] && MC_ARGS="$MC_ARGS, "
        MC_ARGS="${MC_ARGS}index=True"
    fi

    # Generate line
    if [ -n "$MC_ARGS" ]; then
        COLUMN_DEFS="${COLUMN_DEFS}    ${COL_NAME}: ${MAPPED_TYPE} = mapped_column(${MC_ARGS})\n"
    else
        COLUMN_DEFS="${COLUMN_DEFS}    ${COL_NAME}: ${MAPPED_TYPE} = mapped_column()\n"
    fi
done

# Build imports
SA_IMPORTS="from sqlalchemy import"
SA_IMPORT_LIST=""
[ "$NEEDS_STRING" = true ] && SA_IMPORT_LIST="$SA_IMPORT_LIST String,"
[ "$NEEDS_TEXT" = true ] && SA_IMPORT_LIST="$SA_IMPORT_LIST Text,"
[ "$NEEDS_JSON" = true ] && SA_IMPORT_LIST="$SA_IMPORT_LIST JSON,"
# Remove trailing comma
SA_IMPORT_LIST="${SA_IMPORT_LIST%,}"

TYPING_IMPORTS=""
if [ "$NEEDS_OPTIONAL" = true ]; then
    TYPING_IMPORTS="from typing import Optional"
fi

STDLIB_IMPORTS=""
if [ "$NEEDS_DATETIME" = true ] || [ "$NEEDS_DATE" = true ]; then
    DT_PARTS=""
    [ "$NEEDS_DATETIME" = true ] && DT_PARTS="datetime"
    [ "$NEEDS_DATE" = true ] && { [ -n "$DT_PARTS" ] && DT_PARTS="$DT_PARTS, date" || DT_PARTS="date"; }
    STDLIB_IMPORTS="from datetime import $DT_PARTS"
fi
if [ "$NEEDS_UUID" = true ]; then
    [ -n "$STDLIB_IMPORTS" ] && STDLIB_IMPORTS="$STDLIB_IMPORTS\nimport uuid" || STDLIB_IMPORTS="import uuid"
fi

# Write the model file
{
    echo '"""'
    echo "SQLAlchemy model: $MODEL_NAME"
    echo ""
    echo "Auto-generated by model-generator.sh"
    echo '"""'
    echo ""

    # stdlib imports
    if [ -n "$STDLIB_IMPORTS" ]; then
        echo -e "$STDLIB_IMPORTS"
        echo ""
    fi

    # typing imports
    if [ -n "$TYPING_IMPORTS" ]; then
        echo "$TYPING_IMPORTS"
        echo ""
    fi

    # sqlalchemy imports
    if [ -n "$SA_IMPORT_LIST" ]; then
        echo "$SA_IMPORTS$SA_IMPORT_LIST"
    fi
    echo "from sqlalchemy.orm import Mapped, mapped_column"
    echo ""
    echo "from .base import Base"
    echo ""
    echo ""
    echo "class ${MODEL_NAME}(Base):"
    echo "    __tablename__ = \"${TABLE_NAME}\""
    echo ""
    echo -e "$COLUMN_DEFS"
} > "$OUTPUT_FILE"

echo "✅ Model written to: $OUTPUT_FILE"
echo ""
echo "Don't forget to import the model in your models/__init__.py:"
echo "  from .${FILE_NAME} import ${MODEL_NAME}"
echo ""
echo "Generate migration:"
echo "  alembic revision --autogenerate -m 'add ${TABLE_NAME} table'"
echo "  alembic upgrade head"
