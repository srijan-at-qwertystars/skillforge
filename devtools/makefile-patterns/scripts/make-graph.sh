#!/usr/bin/env bash
# make-graph.sh — Visualize Makefile dependency graph using Graphviz (dot).
#
# Usage:
#   make-graph.sh [options] [makefile]
#
# Options:
#   -o FILE    Output file (default: makefile-graph.png)
#   -f FORMAT  Output format: png, svg, pdf, dot (default: png)
#   -t TARGET  Only show graph rooted at TARGET
#   -d DEPTH   Maximum depth to traverse (default: unlimited)
#   -p         Include .PHONY annotations
#   -h         Show help
#
# Requires: graphviz (dot), GNU make
#
# Examples:
#   make-graph.sh                          # Graph ./Makefile → makefile-graph.png
#   make-graph.sh -f svg -o deps.svg       # SVG output
#   make-graph.sh -t build                 # Only show 'build' subtree
#   make-graph.sh -f dot                   # Output raw DOT to stdout
#   make-graph.sh path/to/Makefile         # Graph a specific Makefile

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────
OUTPUT="makefile-graph.png"
FORMAT="png"
TARGET=""
DEPTH=""
SHOW_PHONY=false
MAKEFILE=""

# ─── Parse Arguments ────────────────────────────────────────
usage() {
    sed -n '2,/^$/s/^# //p' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) OUTPUT="$2"; shift 2 ;;
        -f) FORMAT="$2"; shift 2 ;;
        -t) TARGET="$2"; shift 2 ;;
        -d) DEPTH="$2"; shift 2 ;;
        -p) SHOW_PHONY=true; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $1" >&2; usage 1 ;;
        *)  MAKEFILE="$1"; shift ;;
    esac
done

# ─── Check Dependencies ────────────────────────────────────
if ! command -v dot >/dev/null 2>&1; then
    echo "Error: graphviz (dot) is required but not installed." >&2
    echo "Install: apt install graphviz / brew install graphviz" >&2
    exit 1
fi

if ! command -v make >/dev/null 2>&1; then
    echo "Error: GNU make is required but not installed." >&2
    exit 1
fi

# ─── Determine Makefile ────────────────────────────────────
if [[ -z "$MAKEFILE" ]]; then
    if [[ -f "Makefile" ]]; then
        MAKEFILE="Makefile"
    elif [[ -f "makefile" ]]; then
        MAKEFILE="makefile"
    elif [[ -f "GNUmakefile" ]]; then
        MAKEFILE="GNUmakefile"
    else
        echo "Error: No Makefile found in current directory." >&2
        exit 1
    fi
fi

if [[ ! -f "$MAKEFILE" ]]; then
    echo "Error: Makefile not found: $MAKEFILE" >&2
    exit 1
fi

# ─── Extract Dependencies ──────────────────────────────────
# Use make -p to dump the database, then parse target: prerequisite lines

TMPFILE=$(mktemp)
PHONY_FILE=$(mktemp)
trap 'rm -f "$TMPFILE" "$PHONY_FILE"' EXIT

# Get make database (suppress errors from missing commands)
make -p -f "$MAKEFILE" --no-builtin-rules --no-builtin-variables \
    -q __no_target___ 2>/dev/null > "$TMPFILE" || true

# Extract .PHONY targets
grep -E '\.PHONY' "$TMPFILE" | sed 's/\.PHONY.*://; s/^ *//' | tr ' ' '\n' | \
    sort -u > "$PHONY_FILE"

# ─── Generate DOT Graph ────────────────────────────────────

generate_dot() {
    echo 'digraph makefile {'
    echo '  rankdir=LR;'
    echo '  node [shape=box, style=filled, fillcolor="#E8F4FD", fontname="Helvetica", fontsize=10];'
    echo '  edge [color="#666666", arrowsize=0.7];'
    echo ''

    # Style .PHONY targets differently
    if $SHOW_PHONY; then
        while IFS= read -r phony; do
            [[ -n "$phony" ]] && echo "  \"$phony\" [fillcolor=\"#FFF3CD\", style=\"filled,dashed\"];"
        done < "$PHONY_FILE"
        echo ''
    fi

    local depth_filter=""
    if [[ -n "$DEPTH" ]]; then
        depth_filter="$DEPTH"
    fi

    # Parse target: prerequisite lines from make -p output
    # Skip built-in rules (lines starting with # or containing %)
    awk '
    /^# Not a target/ { skip=1; next }
    /^[^\t#%][^%]*:/ && !/^\./ {
        skip=0
        split($0, parts, ":")
        target = parts[1]
        gsub(/^[ \t]+|[ \t]+$/, "", target)
        if (target == "" || target ~ /^#/) next
        # Get prerequisites (everything after the colon)
        prereqs = $0
        sub(/^[^:]+:[ \t]*/, "", prereqs)
        gsub(/\|.*$/, "", prereqs)  # Remove order-only prerequisites marker
        n = split(prereqs, deps, /[ \t]+/)
        for (i = 1; i <= n; i++) {
            dep = deps[i]
            gsub(/^[ \t]+|[ \t]+$/, "", dep)
            if (dep != "" && dep !~ /^\$/ && dep !~ /%/) {
                printf "  \"%s\" -> \"%s\";\n", target, dep
            }
        }
    }
    ' "$TMPFILE"

    echo '}'
}

# ─── Filter by Target ──────────────────────────────────────

filter_by_target() {
    local dot_content="$1"
    local root="$2"

    if [[ -z "$root" ]]; then
        echo "$dot_content"
        return
    fi

    # Extract all reachable nodes from the target
    local edges
    edges=$(echo "$dot_content" | grep '^\s*"')

    # BFS to find all reachable nodes
    local -A visited=()
    local queue=("$root")
    local result_edges=""

    while [[ ${#queue[@]} -gt 0 ]]; do
        local current="${queue[0]}"
        queue=("${queue[@]:1}")

        [[ -n "${visited[$current]:-}" ]] && continue
        visited[$current]=1

        # Find all edges from current
        while IFS= read -r edge; do
            result_edges+="$edge"$'\n'
            # Extract the target of this edge
            local dep
            dep=$(echo "$edge" | sed -n 's/.*-> "\([^"]*\)".*/\1/p')
            if [[ -n "$dep" && -z "${visited[$dep]:-}" ]]; then
                queue+=("$dep")
            fi
        done < <(echo "$edges" | grep "\"$current\"" | grep "->")
    done

    echo 'digraph makefile {'
    echo '  rankdir=LR;'
    echo '  node [shape=box, style=filled, fillcolor="#E8F4FD", fontname="Helvetica", fontsize=10];'
    echo '  edge [color="#666666", arrowsize=0.7];'
    echo "  \"$root\" [fillcolor=\"#D4EDDA\", penwidth=2];"
    echo "$result_edges"
    echo '}'
}

# ─── Output ─────────────────────────────────────────────────

DOT_CONTENT=$(generate_dot)

if [[ -n "$TARGET" ]]; then
    DOT_CONTENT=$(filter_by_target "$DOT_CONTENT" "$TARGET")
fi

if [[ "$FORMAT" == "dot" ]]; then
    echo "$DOT_CONTENT"
else
    echo "$DOT_CONTENT" | dot -T"$FORMAT" -o "$OUTPUT"
    echo "Generated dependency graph → $OUTPUT" >&2
    echo "Targets found: $(echo "$DOT_CONTENT" | grep -c '\->')" >&2
fi
