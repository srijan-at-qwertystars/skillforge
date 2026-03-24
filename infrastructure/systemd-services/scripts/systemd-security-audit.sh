#!/usr/bin/env bash
# =============================================================================
# systemd-security-audit.sh — Audit systemd services for security hardening
# =============================================================================
# Usage: ./systemd-security-audit.sh [SERVICE_NAME...] [--all] [--json] [--threshold SCORE]
#
# Audits systemd service units for security hardening gaps. For each service,
# it checks key directives, reports missing hardening, suggests improvements,
# and assigns a letter grade.
#
# Examples:
#   ./systemd-security-audit.sh nginx.service          # Audit one service
#   ./systemd-security-audit.sh --all                  # Audit all loaded services
#   ./systemd-security-audit.sh --all --threshold 5.0  # Show only services scoring > 5.0
#   ./systemd-security-audit.sh myapp.service --json   # JSON output
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

AUDIT_ALL=false
JSON_OUTPUT=false
THRESHOLD=10.1
SERVICES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) AUDIT_ALL=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --help|-h)
            head -14 "$0" | tail -12
            exit 0
            ;;
        *) SERVICES+=("$1"); shift ;;
    esac
done

if ! command -v systemctl &>/dev/null; then
    echo "Error: systemctl not found. This script requires systemd." >&2
    exit 1
fi

# Directives to check with weights (impact on security)
declare -A DIRECTIVES=(
    [NoNewPrivileges]=3
    [PrivateTmp]=2
    [PrivateDevices]=2
    [ProtectSystem]=3
    [ProtectHome]=2
    [ProtectKernelTunables]=2
    [ProtectKernelModules]=2
    [ProtectKernelLogs]=1
    [ProtectControlGroups]=2
    [ProtectClock]=1
    [ProtectHostname]=1
    [RestrictNamespaces]=2
    [RestrictRealtime]=1
    [RestrictSUIDSGID]=1
    [RestrictAddressFamilies]=2
    [LockPersonality]=1
    [MemoryDenyWriteExecute]=2
    [SystemCallFilter]=3
    [SystemCallArchitectures]=2
    [CapabilityBoundingSet]=3
    [PrivateNetwork]=3
    [PrivateUsers]=2
    [UMask]=1
    [DynamicUser]=2
)

# Acceptable values for directives
declare -A ACCEPTABLE=(
    [NoNewPrivileges]="yes"
    [PrivateTmp]="yes"
    [PrivateDevices]="yes"
    [ProtectSystem]="yes full strict"
    [ProtectHome]="yes read-only tmpfs"
    [ProtectKernelTunables]="yes"
    [ProtectKernelModules]="yes"
    [ProtectKernelLogs]="yes"
    [ProtectControlGroups]="yes"
    [ProtectClock]="yes"
    [ProtectHostname]="yes"
    [RestrictNamespaces]="yes"
    [RestrictRealtime]="yes"
    [RestrictSUIDSGID]="yes"
    [LockPersonality]="yes"
    [MemoryDenyWriteExecute]="yes"
    [SystemCallArchitectures]="native"
    [PrivateNetwork]="yes"
    [PrivateUsers]="yes"
    [DynamicUser]="yes"
)

get_service_list() {
    if [[ "$AUDIT_ALL" == true ]]; then
        systemctl list-units --type=service --state=loaded --no-legend --no-pager \
            | awk '{print $1}' | grep -v '^$'
    else
        printf '%s\n' "${SERVICES[@]}"
    fi
}

check_directive() {
    local service="$1" directive="$2"
    local value
    value=$(systemctl show "$service" -p "$directive" --no-pager 2>/dev/null | cut -d= -f2-)

    if [[ -z "$value" || "$value" == "no" || "$value" == "(not set)" ]]; then
        return 1
    fi

    # Special cases
    case "$directive" in
        ProtectSystem)
            [[ "$value" == "yes" || "$value" == "full" || "$value" == "strict" ]]
            ;;
        ProtectHome)
            [[ "$value" == "yes" || "$value" == "read-only" || "$value" == "tmpfs" ]]
            ;;
        SystemCallFilter)
            [[ -n "$value" && "$value" != "" ]]
            ;;
        CapabilityBoundingSet)
            # Empty is actually most secure (drop all)
            [[ "$value" != "cap_chown cap_dac_override"* ]] 2>/dev/null || return 1
            ;;
        RestrictAddressFamilies)
            [[ -n "$value" && "$value" != "none" ]]
            ;;
        UMask)
            [[ "$value" == "0077" || "$value" == "0027" || "$value" == "077" || "$value" == "027" ]]
            ;;
        *)
            if [[ -n "${ACCEPTABLE[$directive]:-}" ]]; then
                local acceptable="${ACCEPTABLE[$directive]}"
                echo "$acceptable" | grep -qw "$value"
            else
                [[ -n "$value" && "$value" != "no" ]]
            fi
            ;;
    esac
}

grade_score() {
    local pct="$1"
    if (( pct >= 90 )); then echo "A+"
    elif (( pct >= 80 )); then echo "A"
    elif (( pct >= 70 )); then echo "B"
    elif (( pct >= 60 )); then echo "C"
    elif (( pct >= 50 )); then echo "D"
    else echo "F"
    fi
}

grade_color() {
    local grade="$1"
    case "$grade" in
        A+|A) echo "$GREEN" ;;
        B) echo "$YELLOW" ;;
        C) echo "$YELLOW" ;;
        *) echo "$RED" ;;
    esac
}

audit_service() {
    local service="$1"
    local total_weight=0 secured_weight=0
    local missing=() present=()

    for directive in "${!DIRECTIVES[@]}"; do
        local weight="${DIRECTIVES[$directive]}"
        total_weight=$((total_weight + weight))

        if check_directive "$service" "$directive"; then
            secured_weight=$((secured_weight + weight))
            present+=("$directive")
        else
            missing+=("$directive:$weight")
        fi
    done

    local pct=0
    if (( total_weight > 0 )); then
        pct=$((secured_weight * 100 / total_weight))
    fi
    local grade
    grade=$(grade_score "$pct")

    # Check against threshold (approximate 0-10 score)
    local score_10
    score_10=$(awk "BEGIN {printf \"%.1f\", 10 - ($pct / 10.0)}")
    if awk "BEGIN {exit !($score_10 < $THRESHOLD)}" 2>/dev/null; then
        if [[ "$JSON_OUTPUT" != true ]]; then
            return 0
        fi
    fi

    if [[ "$JSON_OUTPUT" == true ]]; then
        local missing_json=""
        for m in "${missing[@]}"; do
            local d="${m%%:*}" w="${m##*:}"
            missing_json="${missing_json:+$missing_json,}{\"directive\":\"$d\",\"weight\":$w}"
        done
        printf '{"service":"%s","score":"%s","grade":"%s","pct":%d,"missing":[%s]}\n' \
            "$service" "$score_10" "$grade" "$pct" "$missing_json"
        return
    fi

    local color
    color=$(grade_color "$grade")
    echo -e "\n${BOLD}━━━ ${service} ━━━${NC}"
    echo -e "Grade: ${color}${BOLD}${grade}${NC} (${pct}% hardened, exposure: ${score_10}/10)"
    echo -e "Secured: ${GREEN}${#present[@]}${NC}/${#DIRECTIVES[@]} directives"

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "\n${YELLOW}Missing hardening (sorted by impact):${NC}"
        # Sort by weight descending
        local sorted
        sorted=$(printf '%s\n' "${missing[@]}" | sort -t: -k2 -rn)
        while IFS=: read -r directive weight; do
            local stars=""
            for ((i=0; i<weight; i++)); do stars+="★"; done
            printf "  ${RED}✗${NC} %-30s  impact: %s\n" "$directive" "$stars"
        done <<< "$sorted"

        echo -e "\n${BLUE}Suggested additions:${NC}"
        echo "  systemctl edit ${service}"
        echo "  # Add under [Service]:"
        while IFS=: read -r directive weight; do
            case "$directive" in
                ProtectSystem) echo "  ${directive}=strict" ;;
                UMask) echo "  ${directive}=0077" ;;
                SystemCallFilter) echo "  ${directive}=@system-service" ;;
                SystemCallArchitectures) echo "  ${directive}=native" ;;
                CapabilityBoundingSet) echo "  ${directive}=" ;;
                RestrictAddressFamilies) echo "  ${directive}=AF_INET AF_INET6 AF_UNIX" ;;
                *) echo "  ${directive}=yes" ;;
            esac
        done <<< "$sorted"
    else
        echo -e "${GREEN}All checked directives are configured!${NC}"
    fi
}

# Main
if [[ "$AUDIT_ALL" == false && ${#SERVICES[@]} -eq 0 ]]; then
    echo "Usage: $0 [SERVICE_NAME...] [--all] [--json] [--threshold SCORE]" >&2
    exit 1
fi

if [[ "$JSON_OUTPUT" != true ]]; then
    echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║    systemd Security Hardening Audit       ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
fi

services_list=$(get_service_list)
count=0

while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    audit_service "$service"
    count=$((count + 1))
done <<< "$services_list"

if [[ "$JSON_OUTPUT" != true ]]; then
    echo -e "\n${BOLD}Audited ${count} service(s)${NC}"
    echo -e "Run ${CYAN}systemd-analyze security <service>${NC} for the official systemd assessment"
fi
