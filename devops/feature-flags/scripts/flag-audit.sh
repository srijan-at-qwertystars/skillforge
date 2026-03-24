#!/usr/bin/env bash
#
# flag-audit.sh — Audit feature flags across flag service providers.
#
# Queries a feature flag platform's API and produces a report covering:
#   • Full inventory with key, type, state, owner, age, and environment
#   • Age analysis with configurable thresholds and color-coded output
#   • Governance checks (missing owners, stale flags, removal candidates)
#
# Usage:
#   flag-audit.sh --api-url <url> --api-key <key> --provider <provider> [options]
#
# Examples:
#   # Basic audit against LaunchDarkly production
#   flag-audit.sh --api-url https://app.launchdarkly.com --api-key sdk-xxx --provider launchdarkly
#
#   # Unleash audit with 60-day threshold, JSON output
#   flag-audit.sh --api-url https://unleash.example.com/api --api-key '*:*.xxx' \
#       --provider unleash --max-age 60 --output json
#
#   # Flagsmith audit for staging, verbose, markdown output
#   flag-audit.sh --api-url https://api.flagsmith.com/api/v1 --api-key key-xxx \
#       --provider flagsmith --environment staging --output markdown --verbose
#
#   # Flipt audit with CSV export
#   flag-audit.sh --api-url http://flipt:8080 --api-key tok-xxx \
#       --provider flipt --output csv
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly NOW_EPOCH="$(date +%s)"

readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_RESET='\033[0m'

readonly DEFAULT_MAX_AGE=30
readonly DEFAULT_OUTPUT="text"
readonly DEFAULT_ENVIRONMENT="production"
readonly EXPERIMENT_MAX_AGE=90

# ---------------------------------------------------------------------------
# Global variables (set by parse_args)
# ---------------------------------------------------------------------------
API_URL=""
API_KEY=""
PROVIDER=""
MAX_AGE="$DEFAULT_MAX_AGE"
OUTPUT_FORMAT="$DEFAULT_OUTPUT"
ENVIRONMENT="$DEFAULT_ENVIRONMENT"
VERBOSE=0

# Collected flag data (newline-delimited JSON objects)
FLAGS_JSON=""

# ---------------------------------------------------------------------------
# Usage / Help
# ---------------------------------------------------------------------------
show_usage() {
    cat <<EOF
${SCRIPT_NAME} v${VERSION} — Feature Flag Audit Tool

USAGE
  ${SCRIPT_NAME} --api-url <url> --api-key <key> --provider <provider> [options]

REQUIRED FLAGS
  --api-url  <url>        Flag service API base URL
  --api-key  <key>        API key / token for authentication
  --provider <provider>   Flag platform: launchdarkly | unleash | flagsmith | flipt

OPTIONS
  --max-age  <days>       Age threshold in days for flagging stale flags (default: ${DEFAULT_MAX_AGE})
  --output   <format>     Output format: text | json | csv | markdown (default: ${DEFAULT_OUTPUT})
  --environment <env>     Environment to audit (default: ${DEFAULT_ENVIRONMENT})
  --verbose               Show detailed targeting rules in output
  --help                  Show this help message and exit

EXAMPLES
  ${SCRIPT_NAME} --api-url https://app.launchdarkly.com --api-key sdk-xxx --provider launchdarkly
  ${SCRIPT_NAME} --api-url https://unleash.example.com/api --api-key '*:*.xxx' \\
      --provider unleash --max-age 60 --output json
  ${SCRIPT_NAME} --api-url https://api.flagsmith.com/api/v1 --api-key key-xxx \\
      --provider flagsmith --environment staging --output markdown --verbose
EOF
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*" >&2; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*" >&2; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && echo -e "[DEBUG] $*" >&2 || true; }

die() { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    for cmd in curl jq date; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required dependencies: ${missing[*]}"
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-url)
                [[ -z "${2:-}" ]] && die "--api-url requires a value"
                API_URL="$2"; shift 2 ;;
            --api-key)
                [[ -z "${2:-}" ]] && die "--api-key requires a value"
                API_KEY="$2"; shift 2 ;;
            --provider)
                [[ -z "${2:-}" ]] && die "--provider requires a value"
                PROVIDER="$2"; shift 2 ;;
            --max-age)
                [[ -z "${2:-}" ]] && die "--max-age requires a value"
                MAX_AGE="$2"; shift 2 ;;
            --output)
                [[ -z "${2:-}" ]] && die "--output requires a value"
                OUTPUT_FORMAT="$2"; shift 2 ;;
            --environment)
                [[ -z "${2:-}" ]] && die "--environment requires a value"
                ENVIRONMENT="$2"; shift 2 ;;
            --verbose)
                VERBOSE=1; shift ;;
            --help|-h)
                show_usage; exit 0 ;;
            *)
                die "Unknown option: $1 (see --help)" ;;
        esac
    done

    # Validate required arguments
    [[ -z "$API_URL" ]]  && die "--api-url is required"
    [[ -z "$API_KEY" ]]  && die "--api-key is required"
    [[ -z "$PROVIDER" ]] && die "--provider is required"

    # Validate provider
    case "$PROVIDER" in
        launchdarkly|unleash|flagsmith|flipt) ;;
        *) die "Unsupported provider '$PROVIDER'. Choose: launchdarkly, unleash, flagsmith, flipt" ;;
    esac

    # Validate output format
    case "$OUTPUT_FORMAT" in
        text|json|csv|markdown) ;;
        *) die "Unsupported output format '$OUTPUT_FORMAT'. Choose: text, json, csv, markdown" ;;
    esac

    # Validate max-age is a positive integer
    if ! [[ "$MAX_AGE" =~ ^[0-9]+$ ]] || [[ "$MAX_AGE" -eq 0 ]]; then
        die "--max-age must be a positive integer"
    fi
}

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------
api_get() {
    local endpoint="$1"
    local url="${API_URL%/}/${endpoint#/}"
    local http_code body

    log_debug "GET $url"

    local tmp_file
    tmp_file="$(mktemp)"
    trap "rm -f '$tmp_file'" RETURN

    case "$PROVIDER" in
        launchdarkly)
            http_code=$(curl -s -w '%{http_code}' -o "$tmp_file" \
                -H "Authorization: ${API_KEY}" \
                -H "Content-Type: application/json" \
                "$url") ;;
        unleash)
            http_code=$(curl -s -w '%{http_code}' -o "$tmp_file" \
                -H "Authorization: ${API_KEY}" \
                -H "Content-Type: application/json" \
                "$url") ;;
        flagsmith)
            http_code=$(curl -s -w '%{http_code}' -o "$tmp_file" \
                -H "X-Environment-Key: ${API_KEY}" \
                -H "Content-Type: application/json" \
                "$url") ;;
        flipt)
            http_code=$(curl -s -w '%{http_code}' -o "$tmp_file" \
                -H "Authorization: Bearer ${API_KEY}" \
                -H "Content-Type: application/json" \
                "$url") ;;
    esac

    body="$(cat "$tmp_file")"

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        log_error "API returned HTTP $http_code for $url"
        log_debug "Response body: $body"
        return 1
    fi

    echo "$body"
}

# ---------------------------------------------------------------------------
# Provider-specific flag fetching & normalisation
#
# Every provider function must emit one JSON object per flag (line-delimited)
# with this schema:
#   { key, name, type, enabled, description, owner, created_date,
#     last_evaluated, environments, targeting_rules, rollout_percentage }
# ---------------------------------------------------------------------------
fetch_flags_launchdarkly() {
    local raw
    raw="$(api_get "/api/v2/flags/${ENVIRONMENT}")" || return 1

    echo "$raw" | jq -c --arg env "$ENVIRONMENT" '
        .items[]? // . as $items |
        ($items // [.]) | .[] |
        {
            key:                .key,
            name:               (.name // .key),
            type:               (.kind // "boolean"),
            enabled:            (if .environments[$env].on then true else false end),
            description:        (.description // ""),
            owner:              (._maintainer.email // .maintainer // ""),
            created_date:       (.creationDate // "" | tostring),
            last_evaluated:     (.environments[$env].lastModified // "" | tostring),
            environments:       ([ .environments | keys[]? ] | join(",")),
            targeting_rules:    ([ .environments[$env].rules[]?.clauses[]?.attribute? ] | join("; ")),
            rollout_percentage: (.environments[$env].fallthrough.rollout.variations[0].weight // null |
                                 if . then (. / 1000) else null end),
            tags:               (.tags // [])
        }
    ' 2>/dev/null || echo "$raw" | jq -c '
        .items[] |
        {
            key:                .key,
            name:               (.name // .key),
            type:               (.kind // "boolean"),
            enabled:            false,
            description:        (.description // ""),
            owner:              (._maintainer.email // ""),
            created_date:       (.creationDate // "" | tostring),
            last_evaluated:     "",
            environments:       "",
            targeting_rules:    "",
            rollout_percentage: null,
            tags:               (.tags // [])
        }
    '
}

fetch_flags_unleash() {
    local raw
    raw="$(api_get "/api/admin/features")" || return 1

    echo "$raw" | jq -c '
        .features[] |
        {
            key:                .name,
            name:               (.name // ""),
            type:               (.type // "boolean"),
            enabled:            (.enabled // false),
            description:        (.description // ""),
            owner:              (.createdBy // ""),
            created_date:       (.createdAt // "" | tostring),
            last_evaluated:     (.lastSeenAt // "" | tostring),
            environments:       ([ .environments[]?.name? ] | join(",")),
            targeting_rules:    ([ .strategies[]?.name? ] | join("; ")),
            rollout_percentage: ([ .strategies[]? |
                                   select(.name == "flexibleRollout") |
                                   .parameters.rollout? ] | first // null |
                                 if . then (. | tonumber) else null end),
            tags:               ([ .tags[]?.value? ] // [])
        }
    '
}

fetch_flags_flagsmith() {
    local raw
    raw="$(api_get "/features/")" || return 1

    echo "$raw" | jq -c '
        (.results // .) | .[] |
        {
            key:                (.name // ""),
            name:               (.name // ""),
            type:               (if .is_server_key_only then "server" elif .type then .type else "boolean" end),
            enabled:            (.enabled // false),
            description:        (.description // ""),
            owner:              (.owners[0].email // ""),
            created_date:       (.created_date // "" | tostring),
            last_evaluated:     "",
            environments:       "",
            targeting_rules:    ([ .segment_overrides[]?.segment?.name? ] | join("; ")),
            rollout_percentage: (.initial_value // null),
            tags:               ([ .tags[]? ] // [])
        }
    '
}

fetch_flags_flipt() {
    local raw
    raw="$(api_get "/api/v1/namespaces/default/flags")" || return 1

    echo "$raw" | jq -c '
        .flags[] |
        {
            key:                .key,
            name:               (.name // .key),
            type:               (.type // "VARIANT_FLAG_TYPE" |
                                 if . == "BOOLEAN_FLAG_TYPE" then "boolean"
                                 elif . == "VARIANT_FLAG_TYPE" then "string"
                                 else "string" end),
            enabled:            (.enabled // false),
            description:        (.description // ""),
            owner:              "",
            created_date:       (.createdAt // "" | tostring),
            last_evaluated:     (.updatedAt // "" | tostring),
            environments:       "default",
            targeting_rules:    ([ .rules[]?.segmentKey? ] | join("; ")),
            rollout_percentage: ([ .rules[]?.distributions[]?.rollout? ] |
                                 if length > 0 then (.[0]) else null end),
            tags:               []
        }
    '
}

fetch_flags() {
    log_info "Fetching flags from ${PROVIDER} (env: ${ENVIRONMENT})..."
    case "$PROVIDER" in
        launchdarkly) fetch_flags_launchdarkly ;;
        unleash)      fetch_flags_unleash ;;
        flagsmith)    fetch_flags_flagsmith ;;
        flipt)        fetch_flags_flipt ;;
    esac
}

# ---------------------------------------------------------------------------
# Date / age helpers
# ---------------------------------------------------------------------------
iso_to_epoch() {
    local datestr="$1"
    [[ -z "$datestr" || "$datestr" == "null" ]] && echo "" && return
    # Handle epoch-millis (LaunchDarkly)
    if [[ "$datestr" =~ ^[0-9]{13}$ ]]; then
        echo $(( datestr / 1000 ))
        return
    fi
    date -d "$datestr" +%s 2>/dev/null || echo ""
}

epoch_to_iso() {
    local epoch="$1"
    [[ -z "$epoch" ]] && echo "N/A" && return
    date -d "@${epoch}" '+%Y-%m-%d' 2>/dev/null || echo "N/A"
}

days_since_epoch() {
    local epoch="$1"
    [[ -z "$epoch" ]] && echo "" && return
    echo $(( (NOW_EPOCH - epoch) / 86400 ))
}

age_color() {
    local age="$1"
    local threshold="$2"
    local warn_threshold=$(( threshold * 3 / 4 ))

    if [[ "$age" -ge "$threshold" ]]; then
        echo "$COLOR_RED"
    elif [[ "$age" -ge "$warn_threshold" ]]; then
        echo "$COLOR_YELLOW"
    else
        echo "$COLOR_GREEN"
    fi
}

# ---------------------------------------------------------------------------
# Analysis helpers
# ---------------------------------------------------------------------------

compute_flag_age() {
    local created_date="$1"
    local epoch
    epoch="$(iso_to_epoch "$created_date")"
    if [[ -n "$epoch" ]]; then
        days_since_epoch "$epoch"
    else
        echo ""
    fi
}

get_effective_threshold() {
    local tags="$1"
    # Experiment flags get a longer threshold
    if echo "$tags" | grep -qi "experiment"; then
        echo "$EXPERIMENT_MAX_AGE"
    else
        echo "$MAX_AGE"
    fi
}

# ---------------------------------------------------------------------------
# Governance checks — returns JSON array of issues per flag
# ---------------------------------------------------------------------------
run_governance_checks() {
    local flags_data="$1"

    echo "$flags_data" | jq -c '
        . as $flag |
        [
            (if (.owner == "" or .owner == null) then "no-owner" else empty end),
            (if (.description == "" or .description == null) then "no-description" else empty end),
            (if (.targeting_rules == "" or .targeting_rules == null) then "no-targeting" else empty end),
            (if (.rollout_percentage != null and .rollout_percentage >= 100) then "full-rollout" else empty end)
        ]
    '
}

# ---------------------------------------------------------------------------
# Build enriched flag records (flags + computed fields)
# ---------------------------------------------------------------------------
build_report_data() {
    local line
    local enriched_flags="[]"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local key name flag_type enabled description owner created_date
        local last_evaluated environments targeting_rules rollout tags
        local age threshold issues

        key="$(echo "$line" | jq -r '.key')"
        name="$(echo "$line" | jq -r '.name')"
        flag_type="$(echo "$line" | jq -r '.type')"
        enabled="$(echo "$line" | jq -r '.enabled')"
        description="$(echo "$line" | jq -r '.description')"
        owner="$(echo "$line" | jq -r '.owner')"
        created_date="$(echo "$line" | jq -r '.created_date')"
        last_evaluated="$(echo "$line" | jq -r '.last_evaluated')"
        environments="$(echo "$line" | jq -r '.environments')"
        targeting_rules="$(echo "$line" | jq -r '.targeting_rules')"
        rollout="$(echo "$line" | jq -r '.rollout_percentage')"
        tags="$(echo "$line" | jq -c '.tags')"

        age="$(compute_flag_age "$created_date")"
        threshold="$(get_effective_threshold "$tags")"
        issues="$(run_governance_checks "$line")"

        # Check for stale evaluation
        if [[ -n "$last_evaluated" && "$last_evaluated" != "null" && "$last_evaluated" != "" ]]; then
            local eval_epoch eval_age
            eval_epoch="$(iso_to_epoch "$last_evaluated")"
            if [[ -n "$eval_epoch" ]]; then
                eval_age="$(days_since_epoch "$eval_epoch")"
                if [[ -n "$eval_age" && "$eval_age" -gt "$MAX_AGE" ]]; then
                    issues="$(echo "$issues" | jq -c '. + ["stale-evaluation"]')"
                fi
            fi
        fi

        local created_display
        local eval_display
        local created_epoch
        created_epoch="$(iso_to_epoch "$created_date")"
        created_display="$(epoch_to_iso "$created_epoch")"
        eval_display="$last_evaluated"
        [[ -z "$eval_display" || "$eval_display" == "null" ]] && eval_display="N/A"

        local state_str
        [[ "$enabled" == "true" ]] && state_str="ON" || state_str="OFF"

        enriched_flags="$(echo "$enriched_flags" | jq -c \
            --arg key "$key" \
            --arg name "$name" \
            --arg type "$flag_type" \
            --arg state "$state_str" \
            --arg desc "$description" \
            --arg owner "$owner" \
            --arg created "$created_display" \
            --arg age "${age:-unknown}" \
            --arg threshold "$threshold" \
            --arg last_eval "$eval_display" \
            --arg envs "$environments" \
            --arg targeting "$targeting_rules" \
            --arg rollout "$rollout" \
            --argjson issues "$issues" \
            '. + [{
                key:              $key,
                name:             $name,
                type:             $type,
                state:            $state,
                description:      $desc,
                owner:            $owner,
                created:          $created,
                age_days:         ($age | if . == "unknown" then null else tonumber end),
                threshold_days:   ($threshold | tonumber),
                last_evaluated:   $last_eval,
                environments:     $envs,
                targeting_rules:  $targeting,
                rollout_pct:      (if $rollout == "null" then null else ($rollout | tonumber) end),
                issues:           $issues
            }]'
        )"
    done <<< "$FLAGS_JSON"

    echo "$enriched_flags"
}

# ---------------------------------------------------------------------------
# Output: Text table
# ---------------------------------------------------------------------------
output_text() {
    local data="$1"
    local total on off

    total="$(echo "$data" | jq 'length')"
    on="$(echo "$data" | jq '[ .[] | select(.state == "ON") ] | length')"
    off="$(echo "$data" | jq '[ .[] | select(.state == "OFF") ] | length')"

    echo ""
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  Feature Flag Audit Report${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  Provider: ${PROVIDER}  |  Environment: ${ENVIRONMENT}${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')${COLOR_RESET}"
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""

    # ---- Flag inventory ----
    echo -e "${COLOR_BOLD}── Flag Inventory (${total} flags: ${on} ON / ${off} OFF) ──${COLOR_RESET}"
    echo ""
    printf "  %-30s %-10s %-6s %-20s %-12s %-8s %s\n" \
        "KEY" "TYPE" "STATE" "OWNER" "CREATED" "AGE(d)" "ENV"
    printf "  %-30s %-10s %-6s %-20s %-12s %-8s %s\n" \
        "------------------------------" "----------" "------" "--------------------" "------------" "--------" "---"

    echo "$data" | jq -c '.[]' | while IFS= read -r row; do
        local rkey rtype rstate rowner rcreated rage renvs rthreshold
        rkey="$(echo "$row" | jq -r '.key')"
        rtype="$(echo "$row" | jq -r '.type')"
        rstate="$(echo "$row" | jq -r '.state')"
        rowner="$(echo "$row" | jq -r '.owner // "—"')"
        rcreated="$(echo "$row" | jq -r '.created')"
        rage="$(echo "$row" | jq -r '.age_days // "?"')"
        renvs="$(echo "$row" | jq -r '.environments // "—"')"
        rthreshold="$(echo "$row" | jq -r '.threshold_days')"

        # Truncate long values
        [[ ${#rkey} -gt 30 ]] && rkey="${rkey:0:27}..."
        [[ ${#rowner} -gt 20 ]] && rowner="${rowner:0:17}..."
        [[ ${#renvs} -gt 20 ]] && renvs="${renvs:0:17}..."

        local state_color=""
        [[ "$rstate" == "ON" ]] && state_color="$COLOR_GREEN" || state_color="$COLOR_RED"

        local age_color_val="$COLOR_RESET"
        if [[ "$rage" =~ ^[0-9]+$ ]]; then
            age_color_val="$(age_color "$rage" "$rthreshold")"
        fi

        printf "  %-30s %-10s ${state_color}%-6s${COLOR_RESET} %-20s %-12s ${age_color_val}%-8s${COLOR_RESET} %s\n" \
            "$rkey" "$rtype" "$rstate" "$rowner" "$rcreated" "$rage" "$renvs"

        if [[ "$VERBOSE" -eq 1 ]]; then
            local rtargeting rlast_eval rrollout
            rtargeting="$(echo "$row" | jq -r '.targeting_rules')"
            rlast_eval="$(echo "$row" | jq -r '.last_evaluated')"
            rrollout="$(echo "$row" | jq -r '.rollout_pct // "—"')"
            [[ -n "$rtargeting" && "$rtargeting" != "null" ]] && \
                printf "    ${COLOR_CYAN}Targeting:${COLOR_RESET} %s\n" "$rtargeting"
            printf "    ${COLOR_CYAN}Last eval:${COLOR_RESET} %s  ${COLOR_CYAN}Rollout:${COLOR_RESET} %s%%\n" \
                "$rlast_eval" "$rrollout"
        fi
    done

    echo ""

    # ---- Age analysis ----
    echo -e "${COLOR_BOLD}── Age Analysis ──${COLOR_RESET}"
    echo ""

    local bucket_fresh bucket_aging bucket_stale bucket_unknown
    bucket_fresh="$(echo "$data" | jq --argjson t "$MAX_AGE" \
        '[ .[] | select(.age_days != null and .age_days < ($t * 3 / 4)) ] | length')"
    bucket_aging="$(echo "$data" | jq --argjson t "$MAX_AGE" \
        '[ .[] | select(.age_days != null and .age_days >= ($t * 3 / 4) and .age_days < $t) ] | length')"
    bucket_stale="$(echo "$data" | jq --argjson t "$MAX_AGE" \
        '[ .[] | select(.age_days != null and .age_days >= $t) ] | length')"
    bucket_unknown="$(echo "$data" | jq \
        '[ .[] | select(.age_days == null) ] | length')"

    echo -e "  ${COLOR_GREEN}■${COLOR_RESET} Fresh (< $(( MAX_AGE * 3 / 4 ))d):        ${bucket_fresh}"
    echo -e "  ${COLOR_YELLOW}■${COLOR_RESET} Approaching ($(( MAX_AGE * 3 / 4 ))–${MAX_AGE}d): ${bucket_aging}"
    echo -e "  ${COLOR_RED}■${COLOR_RESET} Exceeded (> ${MAX_AGE}d):        ${bucket_stale}"
    echo -e "  Unknown age:                ${bucket_unknown}"
    echo ""

    # ---- Governance checks ----
    echo -e "${COLOR_BOLD}── Governance Report ──${COLOR_RESET}"
    echo ""

    local no_owner no_desc no_target stale_eval full_rollout
    no_owner="$(echo "$data" | jq '[ .[] | select(.issues | index("no-owner")) ] | length')"
    no_desc="$(echo "$data" | jq '[ .[] | select(.issues | index("no-description")) ] | length')"
    no_target="$(echo "$data" | jq '[ .[] | select(.issues | index("no-targeting")) ] | length')"
    stale_eval="$(echo "$data" | jq '[ .[] | select(.issues | index("stale-evaluation")) ] | length')"
    full_rollout="$(echo "$data" | jq '[ .[] | select(.issues | index("full-rollout")) ] | length')"

    local issue_total=$(( no_owner + no_desc + no_target + stale_eval + full_rollout ))

    if [[ "$issue_total" -eq 0 ]]; then
        echo -e "  ${COLOR_GREEN}✓ No governance issues found.${COLOR_RESET}"
    else
        [[ "$no_owner" -gt 0 ]]     && echo -e "  ${COLOR_RED}✗${COLOR_RESET} Flags without owners:              ${no_owner}"
        [[ "$no_desc" -gt 0 ]]      && echo -e "  ${COLOR_RED}✗${COLOR_RESET} Flags without descriptions:        ${no_desc}"
        [[ "$no_target" -gt 0 ]]    && echo -e "  ${COLOR_YELLOW}!${COLOR_RESET} Flags with no targeting rules:     ${no_target}"
        [[ "$stale_eval" -gt 0 ]]   && echo -e "  ${COLOR_YELLOW}!${COLOR_RESET} Flags not evaluated recently:      ${stale_eval}"
        [[ "$full_rollout" -gt 0 ]] && echo -e "  ${COLOR_YELLOW}!${COLOR_RESET} Flags at 100% rollout (removable): ${full_rollout}"

        echo ""
        echo -e "  ${COLOR_BOLD}Affected flags:${COLOR_RESET}"
        echo "$data" | jq -r '.[] | select(.issues | length > 0) |
            "    \(.key): \(.issues | join(", "))"'
    fi

    echo ""
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════════════════${COLOR_RESET}"
}

# ---------------------------------------------------------------------------
# Output: JSON
# ---------------------------------------------------------------------------
output_json() {
    local data="$1"

    local summary
    summary="$(echo "$data" | jq '{
        total:       length,
        on:          ([ .[] | select(.state == "ON") ] | length),
        off:         ([ .[] | select(.state == "OFF") ] | length),
        governance: {
            no_owner:         ([ .[] | select(.issues | index("no-owner")) ] | length),
            no_description:   ([ .[] | select(.issues | index("no-description")) ] | length),
            no_targeting:     ([ .[] | select(.issues | index("no-targeting")) ] | length),
            stale_evaluation: ([ .[] | select(.issues | index("stale-evaluation")) ] | length),
            full_rollout:     ([ .[] | select(.issues | index("full-rollout")) ] | length)
        }
    }')"

    jq -n \
        --arg provider "$PROVIDER" \
        --arg env "$ENVIRONMENT" \
        --arg generated "$(date -Iseconds)" \
        --argjson summary "$summary" \
        --argjson flags "$data" \
        '{
            meta: {
                provider:    $provider,
                environment: $env,
                generated:   $generated
            },
            summary: $summary,
            flags:   $flags
        }'
}

# ---------------------------------------------------------------------------
# Output: CSV
# ---------------------------------------------------------------------------
output_csv() {
    local data="$1"

    echo "key,name,type,state,owner,created,age_days,last_evaluated,environments,targeting_rules,rollout_pct,issues"

    echo "$data" | jq -r '.[] |
        [
            .key,
            .name,
            .type,
            .state,
            (.owner // ""),
            .created,
            (.age_days // "" | tostring),
            .last_evaluated,
            .environments,
            .targeting_rules,
            (.rollout_pct // "" | tostring),
            (.issues | join(";"))
        ] | @csv'
}

# ---------------------------------------------------------------------------
# Output: Markdown
# ---------------------------------------------------------------------------
output_markdown() {
    local data="$1"
    local total on off

    total="$(echo "$data" | jq 'length')"
    on="$(echo "$data" | jq '[ .[] | select(.state == "ON") ] | length')"
    off="$(echo "$data" | jq '[ .[] | select(.state == "OFF") ] | length')"

    echo "# Feature Flag Audit Report"
    echo ""
    echo "- **Provider:** ${PROVIDER}"
    echo "- **Environment:** ${ENVIRONMENT}"
    echo "- **Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- **Total flags:** ${total} (${on} ON / ${off} OFF)"
    echo ""

    # Flag table
    echo "## Flag Inventory"
    echo ""
    echo "| Key | Type | State | Owner | Created | Age (days) | Environment |"
    echo "|-----|------|-------|-------|---------|------------|-------------|"

    echo "$data" | jq -r '.[] |
        "| \(.key) | \(.type) | \(.state) | \(.owner // "—") | \(.created) | \(.age_days // "?") | \(.environments // "—") |"'

    if [[ "$VERBOSE" -eq 1 ]]; then
        echo ""
        echo "### Targeting Details"
        echo ""
        echo "| Key | Targeting Rules | Last Evaluated | Rollout % |"
        echo "|-----|-----------------|----------------|-----------|"
        echo "$data" | jq -r '.[] |
            "| \(.key) | \(.targeting_rules // "—") | \(.last_evaluated) | \(.rollout_pct // "—") |"'
    fi

    echo ""

    # Age analysis
    echo "## Age Analysis"
    echo ""

    local bucket_fresh bucket_aging bucket_stale
    bucket_fresh="$(echo "$data" | jq --argjson t "$MAX_AGE" \
        '[ .[] | select(.age_days != null and .age_days < ($t * 3 / 4)) ] | length')"
    bucket_aging="$(echo "$data" | jq --argjson t "$MAX_AGE" \
        '[ .[] | select(.age_days != null and .age_days >= ($t * 3 / 4) and .age_days < $t) ] | length')"
    bucket_stale="$(echo "$data" | jq --argjson t "$MAX_AGE" \
        '[ .[] | select(.age_days != null and .age_days >= $t) ] | length')"

    echo "| Bucket | Count |"
    echo "|--------|-------|"
    echo "| 🟢 Fresh (< $(( MAX_AGE * 3 / 4 ))d) | ${bucket_fresh} |"
    echo "| 🟡 Approaching ($(( MAX_AGE * 3 / 4 ))–${MAX_AGE}d) | ${bucket_aging} |"
    echo "| 🔴 Exceeded (> ${MAX_AGE}d) | ${bucket_stale} |"
    echo ""

    # Governance
    echo "## Governance Issues"
    echo ""

    local no_owner no_desc no_target stale_eval full_rollout
    no_owner="$(echo "$data" | jq '[ .[] | select(.issues | index("no-owner")) ] | length')"
    no_desc="$(echo "$data" | jq '[ .[] | select(.issues | index("no-description")) ] | length')"
    no_target="$(echo "$data" | jq '[ .[] | select(.issues | index("no-targeting")) ] | length')"
    stale_eval="$(echo "$data" | jq '[ .[] | select(.issues | index("stale-evaluation")) ] | length')"
    full_rollout="$(echo "$data" | jq '[ .[] | select(.issues | index("full-rollout")) ] | length')"

    echo "| Issue | Count |"
    echo "|-------|-------|"
    echo "| Flags without owners | ${no_owner} |"
    echo "| Flags without descriptions | ${no_desc} |"
    echo "| Flags with no targeting rules | ${no_target} |"
    echo "| Flags not recently evaluated | ${stale_eval} |"
    echo "| Flags at 100% rollout | ${full_rollout} |"
    echo ""

    local affected
    affected="$(echo "$data" | jq -r '.[] | select(.issues | length > 0) |
        "- **\(.key)**: \(.issues | join(", "))"')"
    if [[ -n "$affected" ]]; then
        echo "### Affected Flags"
        echo ""
        echo "$affected"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_dependencies
    parse_args "$@"

    log_info "Starting feature flag audit..."
    log_info "Provider: ${PROVIDER} | Environment: ${ENVIRONMENT} | Max age: ${MAX_AGE}d"

    # Fetch raw flag data
    FLAGS_JSON="$(fetch_flags)"

    if [[ -z "$FLAGS_JSON" ]]; then
        die "No flags returned from the API. Check your --api-url, --api-key, and --provider."
    fi

    local flag_count
    flag_count="$(echo "$FLAGS_JSON" | wc -l)"
    log_info "Fetched ${flag_count} flag(s). Building report..."

    # Build enriched report data
    local report_data
    report_data="$(build_report_data)"

    # Emit in the requested format
    case "$OUTPUT_FORMAT" in
        text)     output_text "$report_data" ;;
        json)     output_json "$report_data" ;;
        csv)      output_csv "$report_data" ;;
        markdown) output_markdown "$report_data" ;;
    esac

    log_info "Audit complete."
}

main "$@"
