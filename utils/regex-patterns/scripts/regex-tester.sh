#!/usr/bin/env bash
# regex-tester.sh — Test a regex pattern against input strings
#
# Usage:
#   ./regex-tester.sh <pattern> <string1> [string2] [string3] ...
#   echo "input" | ./regex-tester.sh <pattern> -
#   ./regex-tester.sh <pattern> -f <file>       # test each line
#
# Options:
#   -i          Case-insensitive matching
#   -g          Show all matches (global), not just the first
#   -t          Show execution timing
#   -f <file>   Read input strings from file (one per line)
#   -            Read input from stdin
#
# Examples:
#   ./regex-tester.sh '\d{4}-\d{2}-\d{2}' '2024-01-15' 'not-a-date'
#   ./regex-tester.sh -i -g '[a-z]+' 'Hello World'
#   echo "test123" | ./regex-tester.sh '\d+' -
#
# Requires: grep (with -P for PCRE), or perl as fallback

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Defaults
CASE_INSENSITIVE=false
GLOBAL=false
SHOW_TIMING=false
INPUT_FILE=""
USE_STDIN=false

usage() {
    head -n 17 "$0" | tail -n +2 | sed 's/^# \?//'
    exit "${1:-0}"
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i) CASE_INSENSITIVE=true; shift ;;
        -g) GLOBAL=true; shift ;;
        -t) SHOW_TIMING=true; shift ;;
        -f) INPUT_FILE="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        -) USE_STDIN=true; shift ;;
        -*) echo "Unknown option: $1"; usage 1 ;;
        *)  break ;;
    esac
done

if [[ $# -lt 1 ]]; then
    echo -e "${RED}Error: pattern is required${RESET}"
    usage 1
fi

PATTERN="$1"
shift

# Build inputs array
INPUTS=()
if [[ "$USE_STDIN" == true ]]; then
    while IFS= read -r line; do
        INPUTS+=("$line")
    done
elif [[ -n "$INPUT_FILE" ]]; then
    if [[ ! -f "$INPUT_FILE" ]]; then
        echo -e "${RED}Error: file not found: $INPUT_FILE${RESET}"
        exit 1
    fi
    while IFS= read -r line; do
        INPUTS+=("$line")
    done < "$INPUT_FILE"
else
    INPUTS=("$@")
fi

if [[ ${#INPUTS[@]} -eq 0 ]]; then
    echo -e "${RED}Error: no input strings provided${RESET}"
    usage 1
fi

echo -e "${BOLD}Pattern:${RESET} ${CYAN}${PATTERN}${RESET}"
echo -e "${BOLD}Flags:${RESET}  ${CASE_INSENSITIVE:+case-insensitive }${GLOBAL:+global }${SHOW_TIMING:+timing}"
echo "---"

# Check if grep supports -P (PCRE)
HAS_PCRE_GREP=false
if echo "test" | grep -P "test" &>/dev/null 2>&1; then
    HAS_PCRE_GREP=true
fi

# Check if perl is available
HAS_PERL=false
if command -v perl &>/dev/null; then
    HAS_PERL=true
fi

match_with_perl() {
    local pattern="$1"
    local input="$2"
    local flags=""
    [[ "$CASE_INSENSITIVE" == true ]] && flags="i"
    [[ "$GLOBAL" == true ]] && flags="${flags}g"

    perl -e '
        use strict;
        use warnings;
        use Time::HiRes qw(gettimeofday tv_interval);

        my $pattern = $ARGV[0];
        my $input = $ARGV[1];
        my $flags = $ARGV[2];
        my $show_timing = $ARGV[3];
        my $global = ($flags =~ /g/);
        my $case_i = ($flags =~ /i/);

        my $re_flags = "";
        $re_flags .= "i" if $case_i;

        my $t0 = [gettimeofday];
        my $match_count = 0;

        if ($global) {
            my $re = $case_i ? qr/(?i)$pattern/ : qr/$pattern/;
            while ($input =~ /($pattern)/g) {
                $match_count++;
                my $pos = pos($input) - length($&);
                print "  Match $match_count: \"$&\" at position $pos\n";
                # Print numbered groups
                for my $i (1..20) {
                    no strict "refs";
                    last unless defined $$i;
                    print "    Group $i: \"$$i\"\n";
                }
            }
        } else {
            my $re = $case_i ? qr/(?i)$pattern/ : qr/$pattern/;
            if ($input =~ $re) {
                $match_count = 1;
                print "  Match: \"$&\" at position $-[0]\n";
                for my $i (1..20) {
                    no strict "refs";
                    last unless defined $$i;
                    print "    Group $i: \"$$i\"\n";
                }
            }
        }

        my $elapsed = tv_interval($t0);
        if ($show_timing eq "true") {
            printf "  Time: %.6f seconds\n", $elapsed;
        }

        exit($match_count > 0 ? 0 : 1);
    ' "$pattern" "$input" "$flags" "$SHOW_TIMING"
}

match_with_grep() {
    local pattern="$1"
    local input="$2"
    local grep_flags="-P"
    [[ "$CASE_INSENSITIVE" == true ]] && grep_flags="${grep_flags}i"
    [[ "$GLOBAL" == true ]] && grep_flags="${grep_flags}"

    local start_time
    [[ "$SHOW_TIMING" == true ]] && start_time=$(date +%s%N)

    local result
    if result=$(echo "$input" | grep ${grep_flags} -o "$pattern" 2>/dev/null); then
        local count=0
        while IFS= read -r match; do
            count=$((count + 1))
            echo -e "  Match ${count}: \"${match}\""
            if [[ "$GLOBAL" != true ]]; then
                break
            fi
        done <<< "$result"

        if [[ "$SHOW_TIMING" == true ]]; then
            local end_time
            end_time=$(date +%s%N)
            local elapsed=$(( (end_time - start_time) ))
            printf "  Time: %.6f seconds\n" "$(echo "scale=6; $elapsed / 1000000000" | bc)"
        fi
        return 0
    else
        if [[ "$SHOW_TIMING" == true ]]; then
            local end_time
            end_time=$(date +%s%N)
            local elapsed=$(( (end_time - start_time) ))
            printf "  Time: %.6f seconds\n" "$(echo "scale=6; $elapsed / 1000000000" | bc)"
        fi
        return 1
    fi
}

TOTAL=0
MATCHED=0

for input in "${INPUTS[@]}"; do
    TOTAL=$((TOTAL + 1))
    echo -e "${BOLD}Input:${RESET} \"${input}\""

    if [[ "$HAS_PERL" == true ]]; then
        if match_with_perl "$PATTERN" "$input"; then
            echo -e "  ${GREEN}✅ MATCH${RESET}"
            MATCHED=$((MATCHED + 1))
        else
            echo -e "  ${RED}❌ NO MATCH${RESET}"
        fi
    elif [[ "$HAS_PCRE_GREP" == true ]]; then
        if match_with_grep "$PATTERN" "$input"; then
            echo -e "  ${GREEN}✅ MATCH${RESET}"
            MATCHED=$((MATCHED + 1))
        else
            echo -e "  ${RED}❌ NO MATCH${RESET}"
        fi
    else
        echo -e "  ${YELLOW}⚠ Neither perl nor grep -P available. Using basic grep.${RESET}"
        if echo "$input" | grep -qE "$PATTERN"; then
            echo -e "  ${GREEN}✅ MATCH${RESET}"
            MATCHED=$((MATCHED + 1))
        else
            echo -e "  ${RED}❌ NO MATCH${RESET}"
        fi
    fi
    echo ""
done

echo "---"
echo -e "${BOLD}Summary:${RESET} ${MATCHED}/${TOTAL} strings matched"
