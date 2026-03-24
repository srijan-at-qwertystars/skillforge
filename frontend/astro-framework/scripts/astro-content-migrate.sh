#!/usr/bin/env bash
#
# astro-content-migrate.sh — Migrate markdown files with frontmatter into Astro Content Collections.
#
# This script:
#   1. Scans a directory of markdown files
#   2. Extracts frontmatter fields from all files
#   3. Infers Zod schema types from field values
#   4. Generates a content.config.ts with proper Zod schemas
#   5. Optionally reorganizes files into Astro's content directory structure
#
# Usage:
#   ./astro-content-migrate.sh [OPTIONS]
#
# Options:
#   --source <dir>         Source directory containing markdown files (required)
#   --collection <name>    Collection name (default: derived from source dir name)
#   --output <file>        Output path for content.config.ts (default: ./content.config.ts)
#   --move                 Move source files to src/content/<collection>/
#   --content-dir <dir>    Content directory base (default: ./src/content)
#   --pattern <glob>       File glob pattern (default: **/*.md)
#   --analyze-only         Only show field analysis, don't generate config
#   --dry-run              Show what would be done without making changes
#   -h, --help             Show this help message
#
# Examples:
#   ./astro-content-migrate.sh --source ./posts --collection blog
#   ./astro-content-migrate.sh --source ./docs --collection docs --move
#   ./astro-content-migrate.sh --source ./content --analyze-only

set -euo pipefail

# --- Defaults ---
SOURCE_DIR=""
COLLECTION_NAME=""
OUTPUT_FILE="./content.config.ts"
MOVE_FILES=false
CONTENT_DIR="./src/content"
FILE_PATTERN="**/*.md"
ANALYZE_ONLY=false
DRY_RUN=false

# --- Color helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)       SOURCE_DIR="$2"; shift 2 ;;
    --collection)   COLLECTION_NAME="$2"; shift 2 ;;
    --output)       OUTPUT_FILE="$2"; shift 2 ;;
    --move)         MOVE_FILES=true; shift ;;
    --content-dir)  CONTENT_DIR="$2"; shift 2 ;;
    --pattern)      FILE_PATTERN="$2"; shift 2 ;;
    --analyze-only) ANALYZE_ONLY=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage ;;
    -*)             error "Unknown option: $1"; usage ;;
    *)              error "Unexpected argument: $1"; usage ;;
  esac
done

# --- Validate inputs ---
if [[ -z "$SOURCE_DIR" ]]; then
  error "Source directory is required. Use --source <dir>"
  exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  error "Source directory does not exist: $SOURCE_DIR"
  exit 1
fi

# Derive collection name from directory if not provided
if [[ -z "$COLLECTION_NAME" ]]; then
  COLLECTION_NAME=$(basename "$SOURCE_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
  info "Collection name derived from directory: $COLLECTION_NAME"
fi

# --- Find markdown files ---
FOUND_FILES=()
while IFS= read -r -d '' file; do
  FOUND_FILES+=("$file")
done < <(find "$SOURCE_DIR" -name "*.md" -o -name "*.mdx" | sort | tr '\n' '\0')

if [[ ${#FOUND_FILES[@]} -eq 0 ]]; then
  error "No markdown files found in $SOURCE_DIR"
  exit 1
fi

info "Found ${#FOUND_FILES[@]} markdown file(s) in $SOURCE_DIR"

# --- Extract and analyze frontmatter ---
declare -A FIELD_TYPES
declare -A FIELD_COUNTS
declare -A FIELD_EXAMPLES
TOTAL_FILES=${#FOUND_FILES[@]}

# Function to infer Zod type from a value
infer_type() {
  local value="$1"

  # Remove surrounding quotes if present
  value=$(echo "$value" | sed 's/^["'"'"']\(.*\)["'"'"']$/\1/')

  # Boolean
  if [[ "$value" =~ ^(true|false)$ ]]; then
    echo "boolean"
    return
  fi

  # Integer
  if [[ "$value" =~ ^-?[0-9]+$ ]]; then
    echo "number"
    return
  fi

  # Float
  if [[ "$value" =~ ^-?[0-9]+\.[0-9]+$ ]]; then
    echo "number"
    return
  fi

  # Date (ISO format or common date formats)
  if [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    echo "date"
    return
  fi

  # Array (YAML list on single line)
  if [[ "$value" =~ ^\[.*\]$ ]]; then
    echo "array"
    return
  fi

  # Default to string
  echo "string"
}

# Parse frontmatter from all files
info "Analyzing frontmatter fields..."

for file in "${FOUND_FILES[@]}"; do
  in_frontmatter=false
  frontmatter_started=false
  current_key=""
  is_array=false

  while IFS= read -r line; do
    # Detect frontmatter boundaries
    if [[ "$line" == "---" ]]; then
      if $frontmatter_started; then
        break  # End of frontmatter
      else
        frontmatter_started=true
        in_frontmatter=true
        continue
      fi
    fi

    if ! $in_frontmatter; then
      continue
    fi

    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Detect YAML array items (lines starting with "  -")
    if [[ "$line" =~ ^[[:space:]]+-[[:space:]] ]]; then
      if [[ -n "$current_key" ]]; then
        FIELD_TYPES["$current_key"]="array"
      fi
      continue
    fi

    # Detect key: value pairs
    if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_-]*)[[:space:]]*:[[:space:]]*(.*) ]]; then
      current_key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"

      # Trim whitespace
      value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

      # Count occurrences
      FIELD_COUNTS["$current_key"]=$(( ${FIELD_COUNTS["$current_key"]:-0} + 1 ))

      # Store example value (first non-empty)
      if [[ -n "$value" && -z "${FIELD_EXAMPLES["$current_key"]:-}" ]]; then
        FIELD_EXAMPLES["$current_key"]="$value"
      fi

      # Infer type (only if we have a value and no array follows)
      if [[ -n "$value" ]]; then
        inferred=$(infer_type "$value")

        existing="${FIELD_TYPES["$current_key"]:-}"
        if [[ -z "$existing" ]]; then
          FIELD_TYPES["$current_key"]="$inferred"
        elif [[ "$existing" != "$inferred" && "$existing" != "string" ]]; then
          # Type conflict — fall back to string unless one is more specific
          if [[ "$inferred" == "string" ]]; then
            FIELD_TYPES["$current_key"]="string"
          fi
        fi
      fi
    fi
  done < "$file"
done

# --- Display analysis ---
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Frontmatter Analysis: ${COLLECTION_NAME}${NC}"
echo -e "${CYAN}  Files scanned: ${TOTAL_FILES}${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

printf "  %-25s %-12s %-10s %s\n" "FIELD" "TYPE" "COUNT" "EXAMPLE"
printf "  %-25s %-12s %-10s %s\n" "─────" "────" "─────" "───────"

# Sort fields for consistent output
SORTED_FIELDS=($(echo "${!FIELD_TYPES[@]}" | tr ' ' '\n' | sort))

for field in "${SORTED_FIELDS[@]}"; do
  type="${FIELD_TYPES[$field]}"
  count="${FIELD_COUNTS[$field]:-0}"
  example="${FIELD_EXAMPLES[$field]:-}"
  optional=""
  if [[ "$count" -lt "$TOTAL_FILES" ]]; then
    optional=" (optional)"
  fi

  # Truncate long examples
  if [[ ${#example} -gt 40 ]]; then
    example="${example:0:37}..."
  fi

  printf "  %-25s %-12s %-10s %s%s\n" "$field" "$type" "${count}/${TOTAL_FILES}" "$example" "$optional"
done

echo ""

if $ANALYZE_ONLY; then
  info "Analysis complete (--analyze-only mode)."
  exit 0
fi

# --- Generate Zod schema ---
generate_zod_field() {
  local field="$1"
  local type="${FIELD_TYPES[$field]}"
  local count="${FIELD_COUNTS[$field]:-0}"
  local is_optional=$( [[ "$count" -lt "$TOTAL_FILES" ]] && echo true || echo false )

  local zod_type=""
  case "$type" in
    string)  zod_type="z.string()" ;;
    number)  zod_type="z.number()" ;;
    boolean) zod_type="z.boolean()" ;;
    date)    zod_type="z.coerce.date()" ;;
    array)   zod_type="z.array(z.string())" ;;
    *)       zod_type="z.string()" ;;
  esac

  # Add defaults for common patterns
  case "$field" in
    draft)     zod_type="z.boolean().default(false)" ;;
    tags|categories) zod_type="z.array(z.string()).default([])" ;;
  esac

  if $is_optional && [[ ! "$zod_type" =~ \.default\( ]]; then
    zod_type="${zod_type}.optional()"
  fi

  echo "    ${field}: ${zod_type},"
}

# --- Build content.config.ts ---
info "Generating content configuration..."

CONFIG_CONTENT="import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const ${COLLECTION_NAME} = defineCollection({
  loader: glob({ pattern: '${FILE_PATTERN}', base: './${CONTENT_DIR}/${COLLECTION_NAME}' }),
  schema: z.object({
"

for field in "${SORTED_FIELDS[@]}"; do
  CONFIG_CONTENT+="$(generate_zod_field "$field")
"
done

CONFIG_CONTENT+="  }),
});

export const collections = { ${COLLECTION_NAME} };
"

if $DRY_RUN; then
  echo ""
  info "Generated content.config.ts (dry run):"
  echo "─────────────────────────────────────"
  echo "$CONFIG_CONTENT"
  echo "─────────────────────────────────────"

  if $MOVE_FILES; then
    echo ""
    info "Would move ${#FOUND_FILES[@]} files to ${CONTENT_DIR}/${COLLECTION_NAME}/"
    for file in "${FOUND_FILES[@]}"; do
      rel_path="${file#"$SOURCE_DIR"/}"
      echo "  $file → ${CONTENT_DIR}/${COLLECTION_NAME}/$rel_path"
    done
  fi
  exit 0
fi

# --- Write config file ---
if [[ -f "$OUTPUT_FILE" ]]; then
  warn "$OUTPUT_FILE already exists. Backing up to ${OUTPUT_FILE}.bak"
  cp "$OUTPUT_FILE" "${OUTPUT_FILE}.bak"
fi

echo "$CONFIG_CONTENT" > "$OUTPUT_FILE"
ok "Generated $OUTPUT_FILE"

# --- Move files if requested ---
if $MOVE_FILES; then
  DEST_DIR="${CONTENT_DIR}/${COLLECTION_NAME}"
  info "Moving files to $DEST_DIR..."

  mkdir -p "$DEST_DIR"

  moved=0
  for file in "${FOUND_FILES[@]}"; do
    rel_path="${file#"$SOURCE_DIR"/}"
    dest="${DEST_DIR}/$rel_path"

    # Create subdirectories as needed
    mkdir -p "$(dirname "$dest")"

    if [[ "$file" != "$dest" ]]; then
      cp "$file" "$dest"
      ((moved++))
    fi
  done

  ok "Copied $moved file(s) to $DEST_DIR"
  info "Original files in $SOURCE_DIR are preserved. Remove them manually if desired."
fi

# --- Summary ---
echo ""
ok "Migration complete!"
echo ""
info "Next steps:"
echo "  1. Review the generated schema in $OUTPUT_FILE"
echo "  2. Adjust field types as needed (e.g., add z.enum() for fixed values)"
echo "  3. Run 'npx astro sync' to generate TypeScript types"
echo "  4. Use getCollection('${COLLECTION_NAME}') to query your content"
echo ""
echo "  Example usage in a page:"
echo ""
echo "  ---"
echo "  import { getCollection, render } from 'astro:content';"
echo "  const entries = await getCollection('${COLLECTION_NAME}');"
echo "  ---"
echo ""
