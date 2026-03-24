#!/usr/bin/env bash
# json-transform.sh — Common JSON transformations
#
# Usage:
#   json-transform.sh flatten <file.json>           Flatten nested JSON to dot-notation
#   json-transform.sh unflatten <file.json>          Unflatten dot-notation to nested JSON
#   json-transform.sh merge <file1> <file2> [...]    Deep merge multiple JSON files
#   json-transform.sh diff <file1> <file2>            Diff two JSON files
#   json-transform.sh validate <file1> [file2] ...   Validate JSON files
#   json-transform.sh minify <file.json>              Compact/minify JSON
#   json-transform.sh prettify <file.json>            Pretty-print JSON
#   json-transform.sh sort-keys <file.json>           Sort all keys recursively
#   json-transform.sh to-csv <file.json>              Convert array of objects to CSV
#   json-transform.sh from-csv <file.csv>             Convert CSV to array of objects
#   json-transform.sh keys <file.json>                Show all unique key paths
#   json-transform.sh strip-nulls <file.json>         Remove all null values
#
# Requirements: jq, bash 4+, diff (for diff command)

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

usage() {
    echo -e "${BOLD}json-transform.sh${NC} — Common JSON transformations"
    echo
    echo -e "${BOLD}Usage:${NC}"
    echo "  json-transform.sh <command> [options] <files...>"
    echo
    echo -e "${BOLD}Commands:${NC}"
    echo "  flatten      Flatten nested JSON to dot-notation keys"
    echo "  unflatten    Unflatten dot-notation keys to nested JSON"
    echo "  merge        Deep merge multiple JSON files (last wins)"
    echo "  diff         Show structural differences between two JSON files"
    echo "  validate     Validate one or more JSON files"
    echo "  minify       Compact JSON output (single line)"
    echo "  prettify     Pretty-print JSON with indentation"
    echo "  sort-keys    Sort all object keys recursively"
    echo "  to-csv       Convert array of objects to CSV"
    echo "  from-csv     Convert CSV to JSON array of objects"
    echo "  keys         Show all unique key paths in document"
    echo "  strip-nulls  Remove all null values recursively"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo "  json-transform.sh flatten config.json"
    echo "  json-transform.sh merge defaults.json overrides.json > merged.json"
    echo "  json-transform.sh diff old.json new.json"
    echo "  json-transform.sh validate *.json"
    exit 1
}

require_file() {
    if [[ ! -f "$1" ]]; then
        echo -e "${RED}Error: File not found: $1${NC}" >&2
        exit 1
    fi
    if ! jq empty "$1" 2>/dev/null; then
        echo -e "${RED}Error: Invalid JSON: $1${NC}" >&2
        exit 1
    fi
}

cmd_flatten() {
    local file="${1:--}"
    [[ "$file" != "-" ]] && require_file "$file"
    jq '
      [paths(scalars) as $p |
        {key: ($p | map(tostring) | join(".")),
         value: getpath($p)}
      ] | from_entries
    ' "$file"
}

cmd_unflatten() {
    local file="${1:--}"
    [[ "$file" != "-" ]] && require_file "$file"
    jq '
      to_entries
      | reduce .[] as $e ({};
          setpath($e.key | split(".") | map(if test("^[0-9]+$") then tonumber else . end); $e.value)
        )
    ' "$file"
}

cmd_merge() {
    if [[ $# -lt 2 ]]; then
        echo -e "${RED}Error: merge requires at least 2 files${NC}" >&2
        exit 1
    fi
    for f in "$@"; do require_file "$f"; done
    jq -s 'reduce .[] as $obj ({}; . * $obj)' "$@"
}

cmd_diff() {
    if [[ $# -ne 2 ]]; then
        echo -e "${RED}Error: diff requires exactly 2 files${NC}" >&2
        exit 1
    fi
    require_file "$1"
    require_file "$2"

    echo -e "${BOLD}Structural diff: $1 vs $2${NC}"
    echo

    # Keys only in first file
    local only_in_first
    only_in_first=$(jq -n --slurpfile a "$1" --slurpfile b "$2" '
      [$a[0] | paths(scalars) | map(tostring) | join(".")] as $pa |
      [$b[0] | paths(scalars) | map(tostring) | join(".")] as $pb |
      [$pa[] | select(. as $p | $pb | index($p) | not)]
    ')

    local only_in_second
    only_in_second=$(jq -n --slurpfile a "$1" --slurpfile b "$2" '
      [$a[0] | paths(scalars) | map(tostring) | join(".")] as $pa |
      [$b[0] | paths(scalars) | map(tostring) | join(".")] as $pb |
      [$pb[] | select(. as $p | $pa | index($p) | not)]
    ')

    local changed
    changed=$(jq -n --slurpfile a "$1" --slurpfile b "$2" '
      [$a[0] | paths(scalars)] as $paths |
      [$paths[] |
        . as $p |
        ($a[0] | getpath($p)) as $av |
        ($b[0] | getpath($p)) as $bv |
        select($bv != null and $av != $bv) |
        {path: (map(tostring) | join(".")), before: $av, after: $bv}
      ]
    ')

    if [[ "$only_in_first" != "[]" ]]; then
        echo -e "${RED}Only in $1:${NC}"
        echo "$only_in_first" | jq -r '.[] | "  - \(.)"'
        echo
    fi

    if [[ "$only_in_second" != "[]" ]]; then
        echo -e "${GREEN}Only in $2:${NC}"
        echo "$only_in_second" | jq -r '.[] | "  + \(.)"'
        echo
    fi

    if [[ "$changed" != "[]" ]]; then
        echo -e "${YELLOW}Changed values:${NC}"
        echo "$changed" | jq -r '.[] | "  ~ \(.path): \(.before) → \(.after)"'
        echo
    fi

    if [[ "$only_in_first" == "[]" && "$only_in_second" == "[]" && "$changed" == "[]" ]]; then
        echo -e "${GREEN}Files are identical (structurally)${NC}"
    fi
}

cmd_validate() {
    local errors=0
    local total=0

    for f in "$@"; do
        total=$((total + 1))
        if [[ ! -f "$f" ]]; then
            echo -e "${RED}✗ Not found: $f${NC}"
            errors=$((errors + 1))
        elif jq empty "$f" 2>/dev/null; then
            echo -e "${GREEN}✓ Valid:     $f${NC}"
        else
            echo -e "${RED}✗ Invalid:  $f${NC}"
            jq empty "$f" 2>&1 | head -3 | sed 's/^/  /'
            errors=$((errors + 1))
        fi
    done

    echo
    echo -e "${BOLD}Results: ${total} files, $((total - errors)) valid, ${errors} invalid${NC}"
    return $errors
}

cmd_minify() {
    local file="${1:--}"
    [[ "$file" != "-" ]] && require_file "$file"
    jq -c '.' "$file"
}

cmd_prettify() {
    local file="${1:--}"
    [[ "$file" != "-" ]] && require_file "$file"
    jq '.' "$file"
}

cmd_sort_keys() {
    local file="${1:--}"
    [[ "$file" != "-" ]] && require_file "$file"
    jq -S '.' "$file"
}

cmd_to_csv() {
    local file="${1:--}"
    [[ "$file" != "-" ]] && require_file "$file"
    jq -r '
      (.[0] | keys_unsorted) as $headers
      | $headers,
        (.[] | [.[$headers[]]] | map(. // "" | tostring))
      | @csv
    ' "$file"
}

cmd_from_csv() {
    local file="${1:--}"
    if [[ "$file" != "-" && ! -f "$file" ]]; then
        echo -e "${RED}Error: File not found: $file${NC}" >&2
        exit 1
    fi
    jq -Rs '
      split("\n") | map(select(length > 0))
      | (.[0] | split(",") | map(gsub("\""; ""))) as $headers
      | .[1:]
      | map(
          split(",")
          | map(gsub("\""; ""))
          | [$headers, .] | transpose
          | map({(.[0]): .[1]}) | add
        )
    ' "$file"
}

cmd_keys() {
    local file="${1:--}"
    [[ "$file" != "-" ]] && require_file "$file"
    jq '[paths(scalars) | map(tostring) | join(".")] | unique | .[]' -r "$file"
}

cmd_strip_nulls() {
    local file="${1:--}"
    [[ "$file" != "-" ]] && require_file "$file"
    jq 'walk(
      if type == "object" then with_entries(select(.value != null))
      elif type == "array" then map(select(. != null))
      else . end
    )' "$file"
}

# Main dispatcher
[[ $# -lt 1 ]] && usage

command="$1"
shift

case "$command" in
    flatten)     cmd_flatten "$@" ;;
    unflatten)   cmd_unflatten "$@" ;;
    merge)       cmd_merge "$@" ;;
    diff)        cmd_diff "$@" ;;
    validate)    cmd_validate "$@" ;;
    minify)      cmd_minify "$@" ;;
    prettify)    cmd_prettify "$@" ;;
    sort-keys)   cmd_sort_keys "$@" ;;
    to-csv)      cmd_to_csv "$@" ;;
    from-csv)    cmd_from_csv "$@" ;;
    keys)        cmd_keys "$@" ;;
    strip-nulls) cmd_strip_nulls "$@" ;;
    help|--help|-h) usage ;;
    *)
        echo -e "${RED}Unknown command: $command${NC}" >&2
        echo "Run with --help for usage" >&2
        exit 1
        ;;
esac
