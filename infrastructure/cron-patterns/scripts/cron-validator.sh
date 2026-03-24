#!/usr/bin/env bash
# cron-validator.sh — Validate cron expressions and show next N run times
#
# Usage:
#   ./cron-validator.sh "*/15 9-17 * * 1-5"         # Validate and show next 5 runs
#   ./cron-validator.sh "*/15 9-17 * * 1-5" 10       # Show next 10 runs
#   ./cron-validator.sh --check-crontab               # Validate current user's crontab
#   ./cron-validator.sh --check-file /etc/cron.d/jobs  # Validate a crontab file
#
# Dependencies: Python 3 with croniter (pip3 install croniter)
#               Falls back to basic validation if croniter is unavailable.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat <<'EOF'
Usage:
  cron-validator.sh "EXPRESSION" [NUM_RUNS]    Validate expression, show next N runs (default: 5)
  cron-validator.sh --check-crontab            Validate current user's crontab
  cron-validator.sh --check-file FILE          Validate a crontab file
  cron-validator.sh --help                     Show this help

Examples:
  cron-validator.sh "*/5 * * * *"
  cron-validator.sh "0 9 * * 1-5" 10
  cron-validator.sh --check-crontab
  cron-validator.sh --check-file /etc/cron.d/myapp
EOF
}

# Basic cron field validation (no external deps)
validate_field() {
    local value="$1" name="$2" min="$3" max="$4"
    if [[ "$value" == "*" ]]; then return 0; fi

    # Handle step values: */N or M/N
    local base="$value"
    if [[ "$value" == */* ]]; then
        local step="${value##*/}"
        base="${value%%/*}"
        if [[ "$step" =~ ^[0-9]+$ ]] && (( step < 1 || step > max )); then
            echo -e "${RED}✗ $name: step value '$step' out of range (1-$max)${NC}"
            return 1
        fi
        if [[ "$base" == "*" ]]; then return 0; fi
    fi

    # Handle comma-separated lists
    IFS=',' read -ra parts <<< "$base"
    for part in "${parts[@]}"; do
        # Handle ranges: M-N
        if [[ "$part" == *-* ]]; then
            local lo="${part%%-*}" hi="${part##*-}"
            if [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]]; then
                if (( lo < min || lo > max || hi < min || hi > max )); then
                    echo -e "${RED}✗ $name: range '$part' out of bounds ($min-$max)${NC}"
                    return 1
                fi
                if (( lo > hi )); then
                    echo -e "${YELLOW}⚠ $name: range '$part' has start > end${NC}"
                fi
            fi
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if (( part < min || part > max )); then
                echo -e "${RED}✗ $name: value '$part' out of range ($min-$max)${NC}"
                return 1
            fi
        elif [[ "$part" =~ ^[A-Za-z]+$ ]]; then
            : # Named values (MON, JAN, etc.) — allow
        else
            echo -e "${RED}✗ $name: invalid value '$part'${NC}"
            return 1
        fi
    done
    return 0
}

detect_common_mistakes() {
    local expr="$1"
    local warnings=0

    # Check for unescaped %
    if [[ "$expr" == *%* ]] && [[ "$expr" != *\\%* ]]; then
        echo -e "${YELLOW}⚠ Expression contains unescaped '%' — in crontab, % is treated as newline${NC}"
        ((warnings++))
    fi

    # Check for @reboot and other specials
    if [[ "$expr" == @* ]]; then
        case "$expr" in
            @reboot|@yearly|@annually|@monthly|@weekly|@daily|@midnight|@hourly)
                echo -e "${GREEN}✓ Valid predefined schedule: $expr${NC}"
                return 0
                ;;
            *)
                echo -e "${RED}✗ Unknown predefined schedule: $expr${NC}"
                return 1
                ;;
        esac
    fi

    # Split into fields
    IFS=' ' read -ra fields <<< "$expr"
    local num_fields=${#fields[@]}

    if (( num_fields < 5 )); then
        echo -e "${RED}✗ Too few fields ($num_fields). Cron requires 5 fields: min hour dom month dow${NC}"
        return 1
    fi

    if (( num_fields == 6 )); then
        echo -e "${YELLOW}⚠ 6 fields detected. If this is a system crontab (/etc/cron.d/), field 6 is the user.${NC}"
        echo -e "${YELLOW}  If this is a user crontab (crontab -e), you have an extra field.${NC}"
    fi

    if (( num_fields > 6 )); then
        echo -e "${YELLOW}⚠ $num_fields fields detected. Standard cron uses 5 fields. Extra fields may be the command.${NC}"
    fi

    # Validate each field
    local errors=0
    validate_field "${fields[0]}" "minute"       0 59 || ((errors++))
    validate_field "${fields[1]}" "hour"         0 23 || ((errors++))
    validate_field "${fields[2]}" "day-of-month" 1 31 || ((errors++))
    validate_field "${fields[3]}" "month"        1 12 || ((errors++))
    validate_field "${fields[4]}" "day-of-week"  0  7 || ((errors++))

    # Check for dom + dow both set (OR logic warning)
    if [[ "${fields[2]}" != "*" && "${fields[4]}" != "*" ]]; then
        echo -e "${YELLOW}⚠ Both day-of-month and day-of-week are set — cron uses OR logic (runs on either match)${NC}"
        ((warnings++))
    fi

    # Every-second pattern
    if [[ "${fields[0]}" == "* " || "$expr" == "* * * * *" ]]; then
        echo -e "${YELLOW}⚠ This runs every minute — is that intentional?${NC}"
        ((warnings++))
    fi

    if (( errors > 0 )); then
        echo -e "${RED}✗ Validation failed with $errors error(s)${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Basic syntax validation passed${NC}"
    if (( warnings > 0 )); then
        echo -e "${YELLOW}  ($warnings warning(s) above)${NC}"
    fi
    return 0
}

show_next_runs() {
    local expr="$1" count="${2:-5}"

    python3 -c "
import sys
try:
    from croniter import croniter
except ImportError:
    print('croniter not installed. Install with: pip3 install croniter', file=sys.stderr)
    sys.exit(2)

from datetime import datetime

expr = '''$expr'''
count = $count

try:
    cron = croniter(expr, datetime.now())
    print(f'\nNext {count} scheduled runs:')
    for i in range(count):
        next_time = cron.get_next(datetime)
        day_name = next_time.strftime('%a')
        formatted = next_time.strftime('%Y-%m-%d %H:%M:%S')
        print(f'  {i+1:>2}. {day_name} {formatted}')
except (ValueError, KeyError) as e:
    print(f'Invalid cron expression: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1
}

describe_expression() {
    local expr="$1"
    python3 -c "
try:
    from croniter import croniter
    from datetime import datetime, timedelta

    expr = '''$expr'''
    now = datetime.now()
    cron = croniter(expr, now)

    # Calculate approximate frequency
    runs = []
    c = croniter(expr, now)
    for _ in range(100):
        runs.append(c.get_next(datetime))

    if len(runs) >= 2:
        intervals = [(runs[i+1] - runs[i]).total_seconds() for i in range(len(runs)-1)]
        avg_interval = sum(intervals) / len(intervals)
        if avg_interval < 120:
            freq = f'~every {int(avg_interval)} seconds'
        elif avg_interval < 7200:
            freq = f'~every {int(avg_interval/60)} minutes'
        elif avg_interval < 172800:
            freq = f'~every {avg_interval/3600:.1f} hours'
        else:
            freq = f'~every {avg_interval/86400:.1f} days'
        print(f'Frequency: {freq}')
        print(f'Runs per day: ~{int(86400/avg_interval)}')
        print(f'Runs per month: ~{int(2592000/avg_interval)}')
except ImportError:
    pass
except Exception:
    pass
" 2>&1
}

check_crontab_file() {
    local file="$1"
    local line_num=0
    local errors=0
    local entries=0

    echo -e "${BLUE}Validating: $file${NC}"
    echo "─────────────────────────────────"

    while IFS= read -r line; do
        ((line_num++))
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip variable assignments
        [[ "$line" =~ ^[A-Z_]+= ]] && continue
        # Skip predefined schedules
        if [[ "$line" =~ ^@ ]]; then
            local sched
            sched=$(echo "$line" | awk '{print $1}')
            echo -e "Line $line_num: ${GREEN}$sched${NC} (predefined)"
            ((entries++))
            continue
        fi

        # Extract the cron expression (first 5 fields)
        local expr
        expr=$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')
        if [[ -n "$expr" ]]; then
            echo -e "\nLine $line_num: $expr"
            if ! detect_common_mistakes "$expr"; then
                ((errors++))
            fi
            ((entries++))
        fi
    done < "$file"

    echo ""
    echo "─────────────────────────────────"
    echo -e "Entries found: $entries"
    if (( errors > 0 )); then
        echo -e "${RED}Errors: $errors${NC}"
        return 1
    else
        echo -e "${GREEN}All entries valid${NC}"
        return 0
    fi
}

# --- Main ---

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

case "$1" in
    --help|-h)
        usage
        exit 0
        ;;
    --check-crontab)
        tmpfile=$(mktemp)
        trap 'rm -f "$tmpfile"' EXIT
        if ! crontab -l > "$tmpfile" 2>/dev/null; then
            echo -e "${YELLOW}No crontab found for current user${NC}"
            exit 0
        fi
        check_crontab_file "$tmpfile"
        ;;
    --check-file)
        if [[ -z "${2:-}" ]]; then
            echo "Error: --check-file requires a file path"
            exit 1
        fi
        if [[ ! -f "$2" ]]; then
            echo "Error: File not found: $2"
            exit 1
        fi
        check_crontab_file "$2"
        ;;
    *)
        EXPR="$1"
        NUM_RUNS="${2:-5}"

        echo -e "${BLUE}Validating: $EXPR${NC}"
        echo "─────────────────────────────────"

        if detect_common_mistakes "$EXPR"; then
            describe_expression "$EXPR"
            show_next_runs "$EXPR" "$NUM_RUNS"
        fi
        ;;
esac
