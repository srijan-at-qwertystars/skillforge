#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# lint-workflow.sh
#
# A wrapper that runs actionlint with helpful defaults, falling back to
# basic YAML validation if actionlint is not installed.
#
# Usage:
#   ./lint-workflow.sh [WORKFLOW_FILE|REPO_ROOT]
#   ./lint-workflow.sh                      # Lint all workflows in .github/workflows/
#   ./lint-workflow.sh ci.yml               # Lint a specific file
#   ./lint-workflow.sh /path/to/repo        # Lint all workflows in a repo
#
# Options:
#   --help    Show this help message
#
# Behavior:
#   - If actionlint is installed, runs it with color and format options
#   - If actionlint is not installed, prints install instructions and
#     falls back to basic YAML validation checks
#   - Categorizes output by severity (error, warning, info)
#
# Exit codes:
#   0  No issues found
#   1  One or more issues found
##############################################################################

TARGET="${1:-.}"

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

usage() {
    sed -n '/^##/,/^##/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
fi

# Determine files to lint
resolve_files() {
    local target="$1"
    local files=()

    if [[ -f "$target" ]]; then
        files+=("$target")
    elif [[ -d "$target/.github/workflows" ]]; then
        shopt -s nullglob
        files+=("$target"/.github/workflows/*.yml "$target"/.github/workflows/*.yaml)
        shopt -u nullglob
    elif [[ -d "$target" ]]; then
        # Maybe they passed the workflows dir directly
        shopt -s nullglob
        files+=("$target"/*.yml "$target"/*.yaml)
        shopt -u nullglob
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        echo -e "${RED}Error${RESET}: No workflow files found for: ${target}" >&2
        echo "  Looked in: ${target}/.github/workflows/" >&2
        exit 1
    fi

    printf '%s\n' "${files[@]}"
}

# --- actionlint path ---

run_actionlint() {
    local files=("$@")
    local error_count=0
    local warning_count=0
    local info_count=0
    local exit_code=0

    echo -e "${BOLD}Running actionlint...${RESET}"
    echo ""

    # Capture actionlint output
    local output
    output=$(actionlint -color "${files[@]}" 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]] && [[ -z "$output" ]]; then
        echo -e "${GREEN}✔ All workflows passed actionlint validation${RESET}"
        return 0
    fi

    # Categorize and display output
    local current_severity=""
    local errors=()
    local warnings=()
    local infos=()

    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi

        # actionlint format: file:line:col: error/warning message [rule-name]
        if echo "$line" | grep -qi 'error'; then
            errors+=("$line")
            error_count=$((error_count + 1))
        elif echo "$line" | grep -qi 'warning'; then
            warnings+=("$line")
            warning_count=$((warning_count + 1))
        else
            infos+=("$line")
            info_count=$((info_count + 1))
        fi
    done <<< "$output"

    if [[ ${#errors[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}Errors (${#errors[@]})${RESET}"
        for e in "${errors[@]}"; do
            echo -e "  ${RED}✖${RESET} $e"
        done
        echo ""
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${BOLD}Warnings (${#warnings[@]})${RESET}"
        for w in "${warnings[@]}"; do
            echo -e "  ${YELLOW}⚠${RESET} $w"
        done
        echo ""
    fi

    if [[ ${#infos[@]} -gt 0 ]]; then
        echo -e "${CYAN}${BOLD}Info (${#infos[@]})${RESET}"
        for i in "${infos[@]}"; do
            echo -e "  ${CYAN}ℹ${RESET} $i"
        done
        echo ""
    fi

    echo -e "${BOLD}Summary${RESET}: ${error_count} error(s), ${warning_count} warning(s), ${info_count} info"

    if [[ $error_count -gt 0 ]]; then
        return 1
    fi
    return 0
}

# --- Fallback: basic YAML validation ---

run_basic_validation() {
    local files=("$@")
    local total_errors=0
    local total_warnings=0

    echo -e "${YELLOW}actionlint not found — running basic YAML validation${RESET}"
    echo ""

    for file in "${files[@]}"; do
        local filename
        filename=$(basename "$file")
        local file_errors=0
        local file_warnings=0

        echo -e "${BOLD}── ${filename} ──${RESET}"

        # 1. YAML syntax check
        if command -v python3 &>/dev/null; then
            local yaml_error
            yaml_error=$(python3 -c "
import yaml, sys
try:
    with open(sys.argv[1]) as f:
        yaml.safe_load(f)
except yaml.YAMLError as e:
    print(str(e))
" "$file" 2>&1)

            if [[ -n "$yaml_error" ]]; then
                echo -e "  ${RED}✖ ERROR${RESET}: Invalid YAML syntax"
                echo -e "    ${DIM}${yaml_error}${RESET}"
                file_errors=$((file_errors + 1))
            else
                echo -e "  ${GREEN}✔${RESET} Valid YAML syntax"
            fi
        else
            echo -e "  ${YELLOW}⚠${RESET} Cannot check YAML syntax (python3 not available)"
        fi

        # 2. Required top-level keys
        if ! grep -qE "^(on|'on'|\"on\"|true):" "$file"; then
            echo -e "  ${RED}✖ ERROR${RESET}: Missing required key 'on' (trigger definition)"
            file_errors=$((file_errors + 1))
        fi

        if ! grep -qE "^jobs:" "$file"; then
            echo -e "  ${RED}✖ ERROR${RESET}: Missing required key 'jobs'"
            file_errors=$((file_errors + 1))
        fi

        # 3. Check for common issues
        if grep -qn '::set-output' "$file"; then
            local lines
            lines=$(grep -n '::set-output' "$file" | cut -d: -f1 | tr '\n' ', ' | sed 's/,$//')
            echo -e "  ${YELLOW}⚠ WARN${RESET}: Deprecated 'set-output' on line(s): ${lines}"
            echo -e "    ${DIM}Use: echo \"name=value\" >> \$GITHUB_OUTPUT${RESET}"
            file_warnings=$((file_warnings + 1))
        fi

        if grep -qn '::save-state' "$file"; then
            local lines
            lines=$(grep -n '::save-state' "$file" | cut -d: -f1 | tr '\n' ', ' | sed 's/,$//')
            echo -e "  ${YELLOW}⚠ WARN${RESET}: Deprecated 'save-state' on line(s): ${lines}"
            echo -e "    ${DIM}Use: echo \"name=value\" >> \$GITHUB_STATE${RESET}"
            file_warnings=$((file_warnings + 1))
        fi

        # 4. Check for expression syntax issues
        while IFS=: read -r line_num content; do
            echo -e "  ${YELLOW}⚠ WARN${RESET}: Possible unclosed expression on line ${line_num}"
            file_warnings=$((file_warnings + 1))
        done < <(grep -n '\${{[^}]*$' "$file" 2>/dev/null || true)

        # 5. Check runs-on is present in jobs
        if command -v python3 &>/dev/null; then
            local missing_runs_on
            missing_runs_on=$(python3 -c "
import yaml, sys
try:
    with open(sys.argv[1]) as f:
        wf = yaml.safe_load(f)
    if wf and 'jobs' in wf:
        for job_id, job_def in wf['jobs'].items():
            if isinstance(job_def, dict) and 'runs-on' not in job_def and 'uses' not in job_def:
                print(job_id)
except:
    pass
" "$file" 2>&1)

            while IFS= read -r job_id; do
                if [[ -n "$job_id" ]]; then
                    echo -e "  ${RED}✖ ERROR${RESET}: Job '${job_id}' missing 'runs-on' (and is not a reusable workflow call)"
                    file_errors=$((file_errors + 1))
                fi
            done <<< "$missing_runs_on"
        fi

        # 6. Check for tabs (YAML doesn't allow tabs for indentation)
        if grep -Pn '^\t' "$file" &>/dev/null; then
            local tab_lines
            tab_lines=$(grep -Pn '^\t' "$file" | head -5 | cut -d: -f1 | tr '\n' ', ' | sed 's/,$//')
            echo -e "  ${RED}✖ ERROR${RESET}: Tab indentation found on line(s): ${tab_lines} (YAML requires spaces)"
            file_errors=$((file_errors + 1))
        fi

        if [[ $file_errors -eq 0 ]] && [[ $file_warnings -eq 0 ]]; then
            echo -e "  ${GREEN}✔ No issues found${RESET}"
        fi

        total_errors=$((total_errors + file_errors))
        total_warnings=$((total_warnings + file_warnings))
        echo ""
    done

    echo -e "${BOLD}Summary${RESET}: ${total_errors} error(s), ${total_warnings} warning(s)"

    if [[ $total_errors -gt 0 ]]; then
        return 1
    fi
    return 0
}

# --- Main ---

mapfile -t workflow_files < <(resolve_files "$TARGET")

echo -e "${BOLD}Linting GitHub Actions workflows${RESET}"
echo -e "${DIM}Files: ${#workflow_files[@]}${RESET}"
echo ""

if command -v actionlint &>/dev/null; then
    run_actionlint "${workflow_files[@]}"
else
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}actionlint is not installed.${RESET}"
    echo ""
    echo "  Install it for comprehensive workflow linting:"
    echo ""
    echo "  ${BOLD}macOS:${RESET}   brew install actionlint"
    echo "  ${BOLD}Linux:${RESET}   go install github.com/rhysd/actionlint/cmd/actionlint@latest"
    echo "  ${BOLD}Docker:${RESET}  docker run --rm -v \$(pwd):/repo rhysd/actionlint:latest"
    echo "  ${BOLD}Binary:${RESET}  https://github.com/rhysd/actionlint/releases"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    run_basic_validation "${workflow_files[@]}"
fi
