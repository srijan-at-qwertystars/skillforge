#!/usr/bin/env bash
# search-packages.sh — Search nixpkgs for packages with version and description
#
# Usage: search-packages.sh <query> [options]
#   Options:
#     --json       Output results as JSON
#     --channel C  Use a specific channel/ref (default: nixpkgs)
#     --limit N    Maximum results to show (default: 20)
#     -h, --help   Show help
#
# Examples:
#   search-packages.sh python
#   search-packages.sh "rust-analyzer" --limit 5
#   search-packages.sh nodejs --json

set -euo pipefail

QUERY=""
OUTPUT_FORMAT="table"
CHANNEL="nixpkgs"
LIMIT=20

usage() {
  cat <<EOF
Usage: $(basename "$0") <query> [options]

Search nixpkgs for packages with version info and description.

Options:
  --json       Output as JSON
  --channel C  Nixpkgs channel/flakeref (default: nixpkgs)
  --limit N    Max results (default: 20)
  -h, --help   Show help

Examples:
  $(basename "$0") python
  $(basename "$0") "language-server" --limit 10
  $(basename "$0") nodejs --json
  $(basename "$0") terraform --channel nixpkgs/nixos-24.11
EOF
}

# Check prerequisites
if ! command -v nix &>/dev/null; then
  echo "Error: 'nix' is not installed." >&2
  exit 1
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --json)
      OUTPUT_FORMAT="json"
      shift
      ;;
    --channel)
      CHANNEL="${2:?--channel requires a value}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:?--limit requires a value}"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      QUERY="$1"
      shift
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  echo "Error: No search query provided." >&2
  echo ""
  usage >&2
  exit 1
fi

echo "Searching '${CHANNEL}' for '${QUERY}'..." >&2
echo "" >&2

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  # JSON output using nix search --json
  nix search "${CHANNEL}" "${QUERY}" --json 2>/dev/null \
    | python3 -c "
import sys, json

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print('[]')
    sys.exit(0)

results = []
count = 0
limit = ${LIMIT}

for key, val in sorted(data.items()):
    if count >= limit:
        break
    results.append({
        'attribute': key,
        'name': val.get('pname', ''),
        'version': val.get('version', ''),
        'description': val.get('description', '')
    })
    count += 1

print(json.dumps(results, indent=2))
" 2>/dev/null || echo "[]"
else
  # Table output
  nix search "${CHANNEL}" "${QUERY}" 2>/dev/null \
    | head -n $((LIMIT * 3)) \
    | while IFS= read -r line; do
        if [[ "$line" =~ ^\*[[:space:]] ]]; then
          # Package name line: "* legacyPackages.x86_64-linux.python3 (3.12.4)"
          pkg_info="${line#\* }"
          # Extract attribute path and version
          attr_path="${pkg_info%% (*}"
          # Simplify: remove legacyPackages.system prefix
          attr_path="${attr_path#legacyPackages.*.}"
          version=""
          if [[ "$pkg_info" =~ \(([^)]+)\) ]]; then
            version="${BASH_REMATCH[1]}"
          fi
          printf "📦 %-40s %s\n" "$attr_path" "$version"
        elif [[ -n "$line" && ! "$line" =~ ^[[:space:]]*$ ]]; then
          # Description line
          desc="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
          printf "   %s\n\n" "$desc"
        fi
      done

  echo "---" >&2
  echo "Showing up to ${LIMIT} results. Use --limit N for more." >&2
  echo "Install: nix profile install ${CHANNEL}#<package>" >&2
  echo "Try:     nix shell ${CHANNEL}#<package>" >&2
fi
