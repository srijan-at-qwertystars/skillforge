#!/usr/bin/env bash
# migrate-from-asdf.sh — Migrate .tool-versions to .mise.toml format
# Usage: ./migrate-from-asdf.sh [path/to/.tool-versions]
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✖${NC} $*" >&2; }

TOOL_VERSIONS_FILE="${1:-.tool-versions}"

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Usage: $(basename "$0") [path/to/.tool-versions]"
  echo ""
  echo "Migrate a .tool-versions file to .mise.toml format."
  echo ""
  echo "If no path is given, looks for .tool-versions in the current directory."
  echo ""
  echo "Tool name mappings applied automatically:"
  echo "  nodejs  → node"
  echo "  golang  → go"
  echo "  python  → python (no change)"
  echo "  ruby    → ruby   (no change)"
  exit 0
fi

if [[ ! -f "$TOOL_VERSIONS_FILE" ]]; then
  err "File not found: $TOOL_VERSIONS_FILE"
  echo "Usage: $(basename "$0") [path/to/.tool-versions]"
  exit 1
fi

OUTPUT_DIR=$(dirname "$TOOL_VERSIONS_FILE")
OUTPUT_FILE="$OUTPUT_DIR/.mise.toml"

# Check for existing .mise.toml
if [[ -f "$OUTPUT_FILE" ]]; then
  warn ".mise.toml already exists at $OUTPUT_FILE"
  read -rp "Overwrite? [y/N] " answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    info "Aborted."
    exit 0
  fi
fi

# --- Tool name mapping (asdf → mise) ---
map_tool_name() {
  local name="$1"
  case "$name" in
    nodejs)   echo "node" ;;
    golang)   echo "go" ;;
    python2)  echo "python" ;;
    python3)  echo "python" ;;
    *)        echo "$name" ;;
  esac
}

# --- Parse .tool-versions ---
info "Parsing $TOOL_VERSIONS_FILE..."

declare -a TOOLS=()
declare -a VERSIONS=()

while IFS= read -r line; do
  # Skip empty lines and comments
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

  # Parse: tool version [version2 ...]
  tool=$(echo "$line" | awk '{print $1}')
  version_str=$(echo "$line" | awk '{$1=""; print $0}' | xargs)

  mapped_tool=$(map_tool_name "$tool")

  if [[ "$tool" != "$mapped_tool" ]]; then
    info "Mapped: $tool → $mapped_tool"
  fi

  TOOLS+=("$mapped_tool")
  VERSIONS+=("$version_str")

done < "$TOOL_VERSIONS_FILE"

if [[ ${#TOOLS[@]} -eq 0 ]]; then
  warn "No tools found in $TOOL_VERSIONS_FILE"
  exit 0
fi

# --- Generate .mise.toml ---
info "Generating $OUTPUT_FILE..."

{
  echo "# Migrated from $TOOL_VERSIONS_FILE"
  echo "# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "[tools]"

  for i in "${!TOOLS[@]}"; do
    tool="${TOOLS[$i]}"
    version_str="${VERSIONS[$i]}"

    # Handle multiple versions (space-separated → TOML array)
    IFS=' ' read -ra ver_array <<< "$version_str"

    if [[ ${#ver_array[@]} -eq 1 ]]; then
      echo "$tool = \"${ver_array[0]}\""
    else
      # Multiple versions → array syntax
      versions_toml=""
      for v in "${ver_array[@]}"; do
        [[ -n "$versions_toml" ]] && versions_toml+=", "
        versions_toml+="\"$v\""
      done
      echo "$tool = [$versions_toml]"
    fi
  done
} > "$OUTPUT_FILE"

ok "Created $OUTPUT_FILE"
echo ""
echo "--- Generated .mise.toml ---"
cat "$OUTPUT_FILE"
echo "---"

# --- Verification ---
echo ""
if command -v mise &>/dev/null; then
  info "Validating with mise..."
  if mise ls --json -C "$OUTPUT_DIR" &>/dev/null; then
    ok "Config is valid"
  else
    warn "Config may have issues — run 'mise doctor' to check"
  fi
fi

# --- Cleanup prompt ---
echo ""
info "Migration complete."
echo ""
echo "Next steps:"
echo "  1. Review $OUTPUT_FILE"
echo "  2. Run 'mise install' to install tools"
echo "  3. Add env vars and tasks to $OUTPUT_FILE as needed"
echo "  4. Remove $TOOL_VERSIONS_FILE when ready:"
echo "     rm $TOOL_VERSIONS_FILE"
