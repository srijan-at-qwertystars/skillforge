#!/usr/bin/env bash
#
# flag-cleanup.sh — Find stale feature flags in a codebase
#
# Scans source files for common feature-flag evaluation patterns across
# multiple platforms (OpenFeature, LaunchDarkly, Unleash, Flagsmith) and
# optionally compares findings against a flag-service API to identify
# orphaned, unused, or fully-rolled-out flags.
#
# Usage:
#   flag-cleanup.sh [OPTIONS]
#
# Options:
#   --src <path>            Source directory to scan (default: ./src)
#   --extensions <ext,...>  File extensions to scan (default: ts,tsx,js,jsx,py,go,java)
#   --pattern <regex>       Additional regex pattern for flag detection
#   --api-url <url>         Flag service API URL
#   --api-key <key>         Flag service API key
#   --provider <name>       Flag platform: launchdarkly|unleash|flagsmith|flipt
#   --output <format>       Output format: text|json (default: text)
#   --help                  Show this help message
#
# Examples:
#   # Scan default ./src directory
#   flag-cleanup.sh
#
#   # Scan a custom directory for TypeScript files only
#   flag-cleanup.sh --src ./app --extensions ts,tsx
#
#   # Scan with a custom pattern
#   flag-cleanup.sh --pattern 'featureIsActive\(\s*["\x27]([^"\x27]+)'
#
#   # Compare against a LaunchDarkly project
#   flag-cleanup.sh --api-url https://app.launchdarkly.com/api/v2 \
#                   --api-key sdk-xxxx --provider launchdarkly
#
#   # Output as JSON for CI pipelines
#   flag-cleanup.sh --output json

set -euo pipefail

# ─── Defaults ──────────────────────────────────────────────────────────────────

SRC_DIR="./src"
EXTENSIONS="ts,tsx,js,jsx,py,go,java"
CUSTOM_PATTERN=""
API_URL=""
API_KEY=""
PROVIDER=""
OUTPUT_FORMAT="text"

# Temp files cleaned up on exit
TMPDIR_WORK=""

# ─── Helpers ───────────────────────────────────────────────────────────────────

cleanup() {
    if [[ -n "${TMPDIR_WORK}" && -d "${TMPDIR_WORK}" ]]; then
        rm -rf "${TMPDIR_WORK}"
    fi
}
trap cleanup EXIT

die() {
    echo "error: $*" >&2
    exit 1
}

init_tmpdir() {
    TMPDIR_WORK="$(mktemp -d)"
}

# ─── Usage ─────────────────────────────────────────────────────────────────────

show_help() {
    sed -n '2,/^$/{ s/^# \?//; p }' "$0"
    exit 0
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --src)
                [[ -n "${2:-}" ]] || die "--src requires a path argument"
                SRC_DIR="$2"; shift 2 ;;
            --extensions)
                [[ -n "${2:-}" ]] || die "--extensions requires a comma-separated list"
                EXTENSIONS="$2"; shift 2 ;;
            --pattern)
                [[ -n "${2:-}" ]] || die "--pattern requires a regex argument"
                CUSTOM_PATTERN="$2"; shift 2 ;;
            --api-url)
                [[ -n "${2:-}" ]] || die "--api-url requires a URL argument"
                API_URL="$2"; shift 2 ;;
            --api-key)
                [[ -n "${2:-}" ]] || die "--api-key requires a key argument"
                API_KEY="$2"; shift 2 ;;
            --provider)
                [[ -n "${2:-}" ]] || die "--provider requires a name argument"
                case "$2" in
                    launchdarkly|unleash|flagsmith|flipt) ;;
                    *) die "unknown provider '$2' — expected launchdarkly|unleash|flagsmith|flipt" ;;
                esac
                PROVIDER="$2"; shift 2 ;;
            --output)
                [[ -n "${2:-}" ]] || die "--output requires a format argument"
                case "$2" in
                    text|json) ;;
                    *) die "unknown output format '$2' — expected text|json" ;;
                esac
                OUTPUT_FORMAT="$2"; shift 2 ;;
            --help|-h)
                show_help ;;
            *)
                die "unknown option '$1' — run with --help for usage" ;;
        esac
    done
}

# ─── Build grep include flags ─────────────────────────────────────────────────

build_include_args() {
    local IFS=','
    local include_args=()
    for ext in $EXTENSIONS; do
        include_args+=("--include=*.${ext}")
    done
    echo "${include_args[@]}"
}

# ─── Built-in flag patterns ───────────────────────────────────────────────────
#
# Each pattern captures the flag key in group 1.  We use extended-regex (-E)
# with grep and look for the quoted string argument that represents the flag
# name.  The quote style ([\"']) handles both single and double quotes.

builtin_patterns() {
    local patterns=()

    # OpenFeature: getBooleanValue, getStringValue, getNumberValue, getObjectValue
    patterns+=('(getBooleanValue|getStringValue|getNumberValue|getObjectValue)\(\s*[\"'"'"']([^\"'"'"']+)[\"'"'"']')

    # LaunchDarkly: variation, boolVariation, stringVariation
    patterns+=('(variation|boolVariation|stringVariation)\(\s*[\"'"'"']([^\"'"'"']+)[\"'"'"']')

    # Unleash: isEnabled, getVariant
    patterns+=('(isEnabled|getVariant)\(\s*[\"'"'"']([^\"'"'"']+)[\"'"'"']')

    # Flagsmith: has_feature, get_feature
    patterns+=('(has_feature|get_feature)\(\s*[\"'"'"']([^\"'"'"']+)[\"'"'"']')

    printf '%s\n' "${patterns[@]}"
}

# ─── Scan codebase for flag references ────────────────────────────────────────

scan_codebase() {
    local src_dir="$1"
    local flags_file="$2"

    [[ -d "$src_dir" ]] || die "source directory '$src_dir' does not exist"

    local include_args
    include_args="$(build_include_args)"

    local patterns
    patterns="$(builtin_patterns)"

    if [[ -n "$CUSTOM_PATTERN" ]]; then
        patterns+=$'\n'"$CUSTOM_PATTERN"
    fi

    local combined_pattern
    combined_pattern="$(echo "$patterns" | paste -sd'|')"

    # Grep for all matching lines, then extract flag keys
    # shellcheck disable=SC2086
    grep -rEnoh $include_args "$combined_pattern" "$src_dir" 2>/dev/null \
        | grep -oE '[\"'"'"'][^\"'"'"']+[\"'"'"']' \
        | head -1000 \
        | sed "s/^[\"']//; s/[\"']$//" \
        | sort -u \
        > "$flags_file" || true
}

# Collect per-flag location details (flag → file:line)
scan_codebase_details() {
    local src_dir="$1"
    local details_file="$2"

    local include_args
    include_args="$(build_include_args)"

    local patterns
    patterns="$(builtin_patterns)"

    if [[ -n "$CUSTOM_PATTERN" ]]; then
        patterns+=$'\n'"$CUSTOM_PATTERN"
    fi

    local combined_pattern
    combined_pattern="$(echo "$patterns" | paste -sd'|')"

    # shellcheck disable=SC2086
    grep -rEn $include_args "$combined_pattern" "$src_dir" 2>/dev/null \
        > "$details_file" || true
}

# ─── Platform API integration ─────────────────────────────────────────────────

fetch_platform_flags() {
    local platform_file="$1"

    [[ -n "$API_URL" && -n "$API_KEY" ]] || return 0

    local response
    response="$(mktemp)"

    case "$PROVIDER" in
        launchdarkly)
            curl -sf -H "Authorization: ${API_KEY}" \
                "${API_URL}/flags" -o "$response" \
                || die "failed to fetch flags from LaunchDarkly API"
            jq -r '.items[].key' "$response" | sort -u > "$platform_file"
            ;;
        unleash)
            curl -sf -H "Authorization: ${API_KEY}" \
                "${API_URL}/api/admin/features" -o "$response" \
                || die "failed to fetch flags from Unleash API"
            jq -r '.features[].name' "$response" | sort -u > "$platform_file"
            ;;
        flagsmith)
            curl -sf -H "X-Environment-Key: ${API_KEY}" \
                "${API_URL}/api/v1/flags/" -o "$response" \
                || die "failed to fetch flags from Flagsmith API"
            jq -r '.[].feature.name' "$response" | sort -u > "$platform_file"
            ;;
        flipt)
            curl -sf -H "Authorization: Bearer ${API_KEY}" \
                "${API_URL}/api/v1/flags" -o "$response" \
                || die "failed to fetch flags from Flipt API"
            jq -r '.flags[].key' "$response" | sort -u > "$platform_file"
            ;;
        *)
            die "provider must be set via --provider when using --api-url"
            ;;
    esac

    rm -f "$response"
}

# Fetch rollout percentages where supported
fetch_rollout_percentages() {
    local platform_file="$1"
    local rollout_file="$2"

    [[ -n "$API_URL" && -n "$API_KEY" ]] || return 0

    local response
    response="$(mktemp)"

    case "$PROVIDER" in
        launchdarkly)
            curl -sf -H "Authorization: ${API_KEY}" \
                "${API_URL}/flags" -o "$response" 2>/dev/null || return 0
            jq -r '
                .items[] |
                select(.environments != null) |
                . as $flag |
                .environments | to_entries[] |
                select(.value.fallthrough.rollout != null) |
                "\($flag.key)\t\(.value.fallthrough.rollout.variations | map(.weight) | max / 1000)"
            ' "$response" 2>/dev/null > "$rollout_file" || true
            ;;
        unleash)
            curl -sf -H "Authorization: ${API_KEY}" \
                "${API_URL}/api/admin/features" -o "$response" 2>/dev/null || return 0
            jq -r '
                .features[] |
                select(.strategies != null) |
                . as $f |
                .strategies[] |
                select(.parameters.rollout != null) |
                "\($f.name)\t\(.parameters.rollout)"
            ' "$response" 2>/dev/null > "$rollout_file" || true
            ;;
        *)
            # Rollout percentage detection not implemented for this provider
            touch "$rollout_file"
            ;;
    esac

    rm -f "$response"
}

# ─── Comparison logic ─────────────────────────────────────────────────────────

compute_diff() {
    local code_flags="$1"
    local platform_flags="$2"
    local orphaned_file="$3"
    local unused_file="$4"

    # Orphaned: in code but not in platform
    comm -23 "$code_flags" "$platform_flags" > "$orphaned_file"

    # Unused: in platform but not in code
    comm -13 "$code_flags" "$platform_flags" > "$unused_file"
}

# ─── Report: Text ─────────────────────────────────────────────────────────────

report_text() {
    local code_flags="$1"
    local platform_flags="$2"
    local orphaned_file="$3"
    local unused_file="$4"
    local rollout_file="$5"
    local details_file="$6"

    local code_count platform_count orphaned_count unused_count
    code_count="$(wc -l < "$code_flags" | tr -d ' ')"
    platform_count="$(wc -l < "$platform_flags" | tr -d ' ')"
    orphaned_count="$(wc -l < "$orphaned_file" | tr -d ' ')"
    unused_count="$(wc -l < "$unused_file" | tr -d ' ')"

    echo "═══════════════════════════════════════════════════════════"
    echo "  Feature Flag Cleanup Report"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "  Source directory : ${SRC_DIR}"
    echo "  Extensions       : ${EXTENSIONS}"
    echo ""
    echo "── Summary ────────────────────────────────────────────────"
    echo "  Flags found in code     : ${code_count}"

    if [[ -n "$API_URL" ]]; then
        echo "  Flags in platform       : ${platform_count}"
        echo "  Orphaned (code only)    : ${orphaned_count}"
        echo "  Unused   (platform only): ${unused_count}"
    fi

    # Fully rolled-out flags
    local rolled_out_count=0
    if [[ -s "$rollout_file" ]]; then
        rolled_out_count="$(awk -F'\t' '$2 >= 100 { count++ } END { print count+0 }' "$rollout_file")"
        echo "  Fully rolled out (100%) : ${rolled_out_count}"
    fi

    echo ""

    # List code flags
    if [[ "$code_count" -gt 0 ]]; then
        echo "── Flags Found in Code ────────────────────────────────────"
        while IFS= read -r flag; do
            local locations
            locations="$(grep -c "$(printf '%s' "$flag" | sed 's/[.[\*^$()+?{|\\]/\\&/g')" "$details_file" 2>/dev/null || echo 0)"
            echo "  • ${flag}  (${locations} reference(s))"
        done < "$code_flags"
        echo ""
    fi

    # Orphaned flags
    if [[ -n "$API_URL" && "$orphaned_count" -gt 0 ]]; then
        echo "── Orphaned Flags (in code, NOT in platform) ────────────"
        echo "  These flags are referenced in code but missing from the"
        echo "  flag platform. They may be typos or stale references."
        echo ""
        while IFS= read -r flag; do
            echo "  ⚠  ${flag}"
        done < "$orphaned_file"
        echo ""
    fi

    # Unused flags
    if [[ -n "$API_URL" && "$unused_count" -gt 0 ]]; then
        echo "── Unused Flags (in platform, NOT in code) ──────────────"
        echo "  These flags exist in the platform but have no code"
        echo "  references. They may be safe to archive or delete."
        echo ""
        while IFS= read -r flag; do
            echo "  🗑  ${flag}"
        done < "$unused_file"
        echo ""
    fi

    # Fully rolled-out flags
    if [[ -s "$rollout_file" ]]; then
        local has_full_rollout=false
        while IFS=$'\t' read -r flag pct; do
            if awk "BEGIN { exit ($pct >= 100) ? 0 : 1 }"; then
                if [[ "$has_full_rollout" == false ]]; then
                    echo "── Fully Rolled-Out Flags (100%) ─────────────────────────"
                    echo "  These flags are serving 100% rollout and can likely be"
                    echo "  removed from both the platform and code."
                    echo ""
                    has_full_rollout=true
                fi
                echo "  ✅ ${flag}  (${pct}%)"
            fi
        done < "$rollout_file"
        if [[ "$has_full_rollout" == true ]]; then
            echo ""
        fi
    fi

    # Suggested actions
    echo "── Suggested Actions ──────────────────────────────────────"
    if [[ -n "$API_URL" && "$orphaned_count" -gt 0 ]]; then
        echo "  • Review ${orphaned_count} orphaned flag(s) — fix or remove stale references"
    fi
    if [[ -n "$API_URL" && "$unused_count" -gt 0 ]]; then
        echo "  • Consider archiving ${unused_count} unused platform flag(s)"
    fi
    if [[ "$rolled_out_count" -gt 0 ]]; then
        echo "  • Remove ${rolled_out_count} fully rolled-out flag(s) from code and platform"
    fi
    if [[ "$code_count" -gt 0 && -z "$API_URL" ]]; then
        echo "  • Provide --api-url, --api-key, and --provider to compare"
        echo "    code flags against your flag platform for deeper analysis"
    fi
    if [[ "$code_count" -eq 0 ]]; then
        echo "  • No flags detected. Verify --src path and --extensions are correct."
    fi
    echo ""
    echo "═══════════════════════════════════════════════════════════"
}

# ─── Report: JSON ──────────────────────────────────────────────────────────────

report_json() {
    local code_flags="$1"
    local platform_flags="$2"
    local orphaned_file="$3"
    local unused_file="$4"
    local rollout_file="$5"
    local details_file="$6"

    local code_count platform_count orphaned_count unused_count
    code_count="$(wc -l < "$code_flags" | tr -d ' ')"
    platform_count="$(wc -l < "$platform_flags" | tr -d ' ')"
    orphaned_count="$(wc -l < "$orphaned_file" | tr -d ' ')"
    unused_count="$(wc -l < "$unused_file" | tr -d ' ')"

    local rolled_out_count=0
    if [[ -s "$rollout_file" ]]; then
        rolled_out_count="$(awk -F'\t' '$2 >= 100 { count++ } END { print count+0 }' "$rollout_file")"
    fi

    # Build JSON with jq if available, otherwise construct manually
    if command -v jq &>/dev/null; then
        local code_arr platform_arr orphaned_arr unused_arr rolled_arr

        code_arr="$(jq -R -s 'split("\n") | map(select(length > 0))' < "$code_flags")"
        platform_arr="$(jq -R -s 'split("\n") | map(select(length > 0))' < "$platform_flags")"
        orphaned_arr="$(jq -R -s 'split("\n") | map(select(length > 0))' < "$orphaned_file")"
        unused_arr="$(jq -R -s 'split("\n") | map(select(length > 0))' < "$unused_file")"

        if [[ -s "$rollout_file" ]]; then
            rolled_arr="$(awk -F'\t' '$2 >= 100 { printf "%s\n", $1 }' "$rollout_file" \
                | jq -R -s 'split("\n") | map(select(length > 0))')"
        else
            rolled_arr="[]"
        fi

        jq -n \
            --arg src "$SRC_DIR" \
            --arg ext "$EXTENSIONS" \
            --arg provider "${PROVIDER:-none}" \
            --argjson code_count "$code_count" \
            --argjson platform_count "$platform_count" \
            --argjson orphaned_count "$orphaned_count" \
            --argjson unused_count "$unused_count" \
            --argjson rolled_out_count "$rolled_out_count" \
            --argjson code_flags "$code_arr" \
            --argjson platform_flags "$platform_arr" \
            --argjson orphaned_flags "$orphaned_arr" \
            --argjson unused_flags "$unused_arr" \
            --argjson rolled_out_flags "$rolled_arr" \
            '{
                config: {
                    src: $src,
                    extensions: $ext,
                    provider: $provider
                },
                summary: {
                    code_flags_count: $code_count,
                    platform_flags_count: $platform_count,
                    orphaned_count: $orphaned_count,
                    unused_count: $unused_count,
                    rolled_out_count: $rolled_out_count
                },
                code_flags: $code_flags,
                platform_flags: $platform_flags,
                orphaned_flags: $orphaned_flags,
                unused_flags: $unused_flags,
                rolled_out_flags: $rolled_out_flags
            }'
    else
        # Fallback: manual JSON construction
        echo "{"
        echo "  \"config\": {"
        echo "    \"src\": \"${SRC_DIR}\","
        echo "    \"extensions\": \"${EXTENSIONS}\","
        echo "    \"provider\": \"${PROVIDER:-none}\""
        echo "  },"
        echo "  \"summary\": {"
        echo "    \"code_flags_count\": ${code_count},"
        echo "    \"platform_flags_count\": ${platform_count},"
        echo "    \"orphaned_count\": ${orphaned_count},"
        echo "    \"unused_count\": ${unused_count},"
        echo "    \"rolled_out_count\": ${rolled_out_count}"
        echo "  },"
        printf '  "code_flags": ['
        paste -sd',' < "$code_flags" | sed 's/[^,]*/"&"/g'
        echo "],"
        printf '  "orphaned_flags": ['
        paste -sd',' < "$orphaned_file" | sed 's/[^,]*/"&"/g'
        echo "],"
        printf '  "unused_flags": ['
        paste -sd',' < "$unused_file" | sed 's/[^,]*/"&"/g'
        echo "]"
        echo "}"
    fi
}

# ─── Main ──────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    init_tmpdir

    local code_flags="${TMPDIR_WORK}/code_flags.txt"
    local platform_flags="${TMPDIR_WORK}/platform_flags.txt"
    local orphaned_file="${TMPDIR_WORK}/orphaned.txt"
    local unused_file="${TMPDIR_WORK}/unused.txt"
    local rollout_file="${TMPDIR_WORK}/rollout.txt"
    local details_file="${TMPDIR_WORK}/details.txt"

    touch "$code_flags" "$platform_flags" "$orphaned_file" \
          "$unused_file" "$rollout_file" "$details_file"

    # Step 1: Scan codebase
    scan_codebase "$SRC_DIR" "$code_flags"
    scan_codebase_details "$SRC_DIR" "$details_file"

    # Step 2: Fetch platform flags (if configured)
    if [[ -n "$API_URL" && -n "$API_KEY" ]]; then
        fetch_platform_flags "$platform_flags"
        fetch_rollout_percentages "$platform_flags" "$rollout_file"
        compute_diff "$code_flags" "$platform_flags" "$orphaned_file" "$unused_file"
    fi

    # Step 3: Report
    case "$OUTPUT_FORMAT" in
        text) report_text "$code_flags" "$platform_flags" "$orphaned_file" \
                          "$unused_file" "$rollout_file" "$details_file" ;;
        json) report_json "$code_flags" "$platform_flags" "$orphaned_file" \
                          "$unused_file" "$rollout_file" "$details_file" ;;
    esac
}

main "$@"
