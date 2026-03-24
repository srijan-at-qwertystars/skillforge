#!/usr/bin/env bash
# jq-playground.sh — Interactive jq testing tool
#
# Usage:
#   jq-playground.sh <file.json>            # Load JSON from file
#   cat data.json | jq-playground.sh        # Load JSON from stdin
#   jq-playground.sh                        # Start with sample JSON
#
# Features:
#   - Interactive REPL for testing jq filters
#   - Colored output with syntax highlighting
#   - Command history (up/down arrows)
#   - Built-in commands: :help, :input, :reset, :save, :raw, :compact, :quit
#
# Requirements: jq, bash 4+

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly DIM='\033[2m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# State
TMPDIR="${TMPDIR:-/tmp}"
INPUT_FILE="$(mktemp "${TMPDIR}/jq-playground-XXXXXX.json")"
HISTORY_FILE="${HOME}/.jq_playground_history"
RAW_MODE=false
COMPACT_MODE=false

cleanup() {
    rm -f "$INPUT_FILE"
}
trap cleanup EXIT

print_banner() {
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║       jq Playground — Interactive    ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}"
    echo -e "${DIM}Type a jq filter, or :help for commands${NC}"
    echo
}

print_help() {
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${GREEN}:help${NC}           Show this help message"
    echo -e "  ${GREEN}:input${NC}          Show current input JSON"
    echo -e "  ${GREEN}:load <file>${NC}    Load new JSON from file"
    echo -e "  ${GREEN}:set <json>${NC}     Set input to inline JSON"
    echo -e "  ${GREEN}:reset${NC}          Reset to original input"
    echo -e "  ${GREEN}:save <file>${NC}    Save last output to file"
    echo -e "  ${GREEN}:raw${NC}            Toggle raw output mode (-r)"
    echo -e "  ${GREEN}:compact${NC}        Toggle compact output mode (-c)"
    echo -e "  ${GREEN}:type${NC}           Show type of current input"
    echo -e "  ${GREEN}:keys${NC}           Show top-level keys"
    echo -e "  ${GREEN}:length${NC}         Show length of current input"
    echo -e "  ${GREEN}:quit${NC}           Exit playground"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  ${DIM}.${NC}                       Pretty-print input"
    echo -e "  ${DIM}.users[] | .name${NC}        Extract names"
    echo -e "  ${DIM}[.[] | select(.age>25)]${NC}  Filter array"
    echo -e "  ${DIM}keys${NC}                     Show object keys"
    echo
}

show_input_summary() {
    local type size
    type=$(jq -r 'type' "$INPUT_FILE" 2>/dev/null || echo "unknown")
    size=$(wc -c < "$INPUT_FILE" | tr -d ' ')

    echo -e "${DIM}Input: ${type}, ${size} bytes${NC}"

    case "$type" in
        object)
            local keys
            keys=$(jq -r 'keys | join(", ")' "$INPUT_FILE" 2>/dev/null)
            echo -e "${DIM}Keys: ${keys}${NC}"
            ;;
        array)
            local len
            len=$(jq 'length' "$INPUT_FILE" 2>/dev/null)
            echo -e "${DIM}Elements: ${len}${NC}"
            ;;
    esac
    echo
}

load_input() {
    local source="$1"
    if [[ -f "$source" ]]; then
        if jq empty "$source" 2>/dev/null; then
            cp "$source" "$INPUT_FILE"
            echo -e "${GREEN}✓ Loaded: ${source}${NC}"
            show_input_summary
        else
            echo -e "${RED}✗ Invalid JSON: ${source}${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ File not found: ${source}${NC}"
        return 1
    fi
}

run_filter() {
    local filter="$1"
    local flags=()
    local last_output

    [[ "$RAW_MODE" == true ]] && flags+=("-r")
    [[ "$COMPACT_MODE" == true ]] && flags+=("-c")

    last_output=$(jq "${flags[@]}" --color-output "$filter" "$INPUT_FILE" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "$last_output"
        # Store for :save
        echo "$last_output" > "${INPUT_FILE}.lastout"
    else
        echo -e "${RED}Error:${NC} $last_output"
    fi

    return $exit_code
}

# Load input
ORIGINAL_INPUT=""
SAMPLE_JSON='{"users":[{"name":"alice","age":30,"active":true},{"name":"bob","age":25,"active":false},{"name":"charlie","age":35,"active":true}],"meta":{"total":3,"page":1}}'

if [[ $# -ge 1 && -f "$1" ]]; then
    # File argument
    if jq empty "$1" 2>/dev/null; then
        cp "$1" "$INPUT_FILE"
        ORIGINAL_INPUT="$1"
    else
        echo -e "${RED}Error: Invalid JSON file: $1${NC}" >&2
        exit 1
    fi
elif [[ ! -t 0 ]]; then
    # Stdin
    cat > "$INPUT_FILE"
    if ! jq empty "$INPUT_FILE" 2>/dev/null; then
        echo -e "${RED}Error: Invalid JSON from stdin${NC}" >&2
        exit 1
    fi
else
    # Sample data
    echo "$SAMPLE_JSON" | jq '.' > "$INPUT_FILE"
fi

# Main loop
print_banner
show_input_summary

while true; do
    echo -en "${BLUE}jq>${NC} "
    if ! IFS= read -r -e line; then
        echo
        break
    fi

    # Skip empty lines
    [[ -z "${line// /}" ]] && continue

    # Add to history
    history -s "$line"

    case "$line" in
        :help|:h)
            print_help
            ;;
        :input|:i)
            jq -C '.' "$INPUT_FILE"
            ;;
        :load\ *)
            load_input "${line#:load }"
            ;;
        :set\ *)
            local_json="${line#:set }"
            if echo "$local_json" | jq empty 2>/dev/null; then
                echo "$local_json" | jq '.' > "$INPUT_FILE"
                echo -e "${GREEN}✓ Input updated${NC}"
                show_input_summary
            else
                echo -e "${RED}✗ Invalid JSON${NC}"
            fi
            ;;
        :reset|:r)
            if [[ -n "$ORIGINAL_INPUT" && -f "$ORIGINAL_INPUT" ]]; then
                cp "$ORIGINAL_INPUT" "$INPUT_FILE"
            else
                echo "$SAMPLE_JSON" | jq '.' > "$INPUT_FILE"
            fi
            echo -e "${GREEN}✓ Input reset${NC}"
            ;;
        :save\ *)
            local_file="${line#:save }"
            if [[ -f "${INPUT_FILE}.lastout" ]]; then
                cp "${INPUT_FILE}.lastout" "$local_file"
                echo -e "${GREEN}✓ Saved to: ${local_file}${NC}"
            else
                echo -e "${YELLOW}No previous output to save${NC}"
            fi
            ;;
        :raw)
            RAW_MODE=$([[ "$RAW_MODE" == true ]] && echo false || echo true)
            echo -e "${CYAN}Raw mode: ${RAW_MODE}${NC}"
            ;;
        :compact|:c)
            COMPACT_MODE=$([[ "$COMPACT_MODE" == true ]] && echo false || echo true)
            echo -e "${CYAN}Compact mode: ${COMPACT_MODE}${NC}"
            ;;
        :type|:t)
            jq -r 'type' "$INPUT_FILE"
            ;;
        :keys|:k)
            jq -C 'keys' "$INPUT_FILE" 2>/dev/null || echo -e "${RED}Input has no keys${NC}"
            ;;
        :length|:l)
            jq 'length' "$INPUT_FILE"
            ;;
        :quit|:q|:exit)
            echo -e "${DIM}Goodbye!${NC}"
            break
            ;;
        :*)
            echo -e "${RED}Unknown command: ${line}. Type :help for available commands.${NC}"
            ;;
        *)
            run_filter "$line"
            ;;
    esac
    echo
done
