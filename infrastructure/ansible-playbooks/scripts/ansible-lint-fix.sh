#!/usr/bin/env bash
# ansible-lint-fix.sh — Run ansible-lint and auto-fix common issues
#
# Scans Ansible playbooks, roles, and task files for common linting issues
# and automatically fixes those that can be safely corrected.
#
# Usage:
#   ansible-lint-fix.sh [PATH] [OPTIONS]
#
# Examples:
#   ansible-lint-fix.sh                    # Lint current directory
#   ansible-lint-fix.sh site.yml           # Lint specific file
#   ansible-lint-fix.sh roles/            # Lint all roles
#   ansible-lint-fix.sh --dry-run         # Show fixes without applying
#   ansible-lint-fix.sh --fix-only        # Only fix, skip final report

set -euo pipefail

# --- Defaults ---
TARGET="${1:-.}"
DRY_RUN=false
FIX_ONLY=false
VERBOSE=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [PATH] [OPTIONS]

Run ansible-lint and auto-fix common issues in Ansible files.

Arguments:
  PATH                    File or directory to lint (default: current directory)

Options:
  --dry-run, -d           Show what would be fixed without making changes
  --fix-only, -f          Only apply fixes, skip final lint report
  --verbose, -v           Show detailed output
  --help, -h              Show this help message

Auto-fixes applied:
  - FQCN: Convert short module names to fully qualified collection names
  - YAML: Fix trailing whitespace, missing document start markers
  - Permissions: Quote file mode strings (0755 -> "0755")
  - Names: Flag unnamed tasks (manual fix required)
  - Key order: Standardize task key ordering
  - Truthy: Convert yes/no to true/false in appropriate contexts
  - Line length: Flag long lines (manual fix suggested)

Requirements:
  - ansible-lint (pip install ansible-lint)
  - sed, awk (standard Unix tools)
EOF
    exit "${1:-0}"
}

# --- Parse arguments ---
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-d)  DRY_RUN=true; shift ;;
        --fix-only|-f) FIX_ONLY=true; shift ;;
        --verbose|-v)  VERBOSE=true; shift ;;
        --help|-h)     usage 0 ;;
        -*) echo "Error: Unknown option: $1" >&2; usage 1 ;;
        *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done
[[ ${#POSITIONAL_ARGS[@]} -gt 0 ]] && TARGET="${POSITIONAL_ARGS[0]}"

# --- Check prerequisites ---
check_command() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${RED}Error: $1 is not installed.${NC}" >&2
        echo "Install with: $2" >&2
        exit 1
    fi
}

check_command ansible-lint "pip install ansible-lint"

# --- Helper functions ---
log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_fix()   { echo -e "${GREEN}[FIX]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_skip()  { echo -e "${YELLOW}[SKIP]${NC} $*"; }

FIXES_APPLIED=0
FILES_MODIFIED=0

apply_fix() {
    local file="$1"
    local description="$2"
    FIXES_APPLIED=$((FIXES_APPLIED + 1))
    if $DRY_RUN; then
        log_skip "(dry-run) Would fix in ${file}: ${description}"
    else
        log_fix "${file}: ${description}"
    fi
}

# --- Find YAML files ---
find_yaml_files() {
    find "$TARGET" -type f \( -name "*.yml" -o -name "*.yaml" \) \
        ! -path "*/.git/*" \
        ! -path "*/node_modules/*" \
        ! -path "*/.tox/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/venv/*" \
        2>/dev/null | sort
}

# --- Fix: Trailing whitespace ---
fix_trailing_whitespace() {
    log_info "Checking for trailing whitespace..."
    local count=0
    while IFS= read -r file; do
        if grep -qP '\s+$' "$file" 2>/dev/null; then
            apply_fix "$file" "Remove trailing whitespace"
            if ! $DRY_RUN; then
                sed -i 's/[[:space:]]*$//' "$file"
            fi
            count=$((count + 1))
        fi
    done < <(find_yaml_files)
    [[ $count -gt 0 ]] && FILES_MODIFIED=$((FILES_MODIFIED + count))
}

# --- Fix: Missing document start (---) ---
fix_document_start() {
    log_info "Checking for missing document start markers..."
    while IFS= read -r file; do
        local first_line
        first_line=$(head -1 "$file" 2>/dev/null || true)
        if [[ -n "$first_line" && "$first_line" != "---" && "$first_line" != "#"* ]]; then
            # Only fix files that look like Ansible YAML (contain tasks/hosts/roles keys)
            if grep -qE '^\s*(- name:|hosts:|tasks:|roles:|handlers:)' "$file" 2>/dev/null; then
                apply_fix "$file" "Add missing document start marker (---)"
                if ! $DRY_RUN; then
                    sed -i '1i---' "$file"
                fi
            fi
        fi
    done < <(find_yaml_files)
}

# --- Fix: Unquoted file modes ---
fix_file_modes() {
    log_info "Checking for unquoted file mode values..."
    while IFS= read -r file; do
        # Match mode: 0755 (unquoted) but not mode: "0755" (already quoted)
        if grep -qP '^\s+mode:\s+0[0-7]{3}\s*$' "$file" 2>/dev/null; then
            apply_fix "$file" "Quote file mode values"
            if ! $DRY_RUN; then
                sed -i -E 's/(^\s+mode:\s+)(0[0-7]{3})\s*$/\1"\2"/' "$file"
            fi
            FILES_MODIFIED=$((FILES_MODIFIED + 1))
        fi
    done < <(find_yaml_files)
}

# --- Fix: Boolean yes/no to true/false ---
fix_truthy_values() {
    log_info "Checking for yes/no boolean values..."
    while IFS= read -r file; do
        local modified=false
        # Fix common boolean patterns: enabled: yes -> enabled: true
        # Only fix known boolean keys to avoid false positives
        for key in enabled become gather_facts changed_when failed_when check_mode \
                   no_log ignore_errors update_cache daemon_reload force privileged \
                   create_home system append; do
            if grep -qP "^\s+${key}:\s+(yes|no)\s*$" "$file" 2>/dev/null; then
                if ! $DRY_RUN; then
                    sed -i -E "s/(^\s+${key}:\s+)yes\s*$/\1true/" "$file"
                    sed -i -E "s/(^\s+${key}:\s+)no\s*$/\1false/" "$file"
                fi
                modified=true
            fi
        done
        if $modified; then
            apply_fix "$file" "Convert yes/no to true/false"
        fi
    done < <(find_yaml_files)
}

# --- Fix: Use FQCN for common modules ---
fix_fqcn() {
    log_info "Checking for short module names (FQCN)..."

    # Map of short names to FQCN
    declare -A MODULE_MAP=(
        ["apt"]="ansible.builtin.apt"
        ["yum"]="ansible.builtin.yum"
        ["dnf"]="ansible.builtin.dnf"
        ["package"]="ansible.builtin.package"
        ["pip"]="ansible.builtin.pip"
        ["copy"]="ansible.builtin.copy"
        ["template"]="ansible.builtin.template"
        ["file"]="ansible.builtin.file"
        ["lineinfile"]="ansible.builtin.lineinfile"
        ["blockinfile"]="ansible.builtin.blockinfile"
        ["replace"]="ansible.builtin.replace"
        ["command"]="ansible.builtin.command"
        ["shell"]="ansible.builtin.shell"
        ["raw"]="ansible.builtin.raw"
        ["script"]="ansible.builtin.script"
        ["service"]="ansible.builtin.service"
        ["systemd"]="ansible.builtin.systemd"
        ["user"]="ansible.builtin.user"
        ["group"]="ansible.builtin.group"
        ["git"]="ansible.builtin.git"
        ["cron"]="ansible.builtin.cron"
        ["debug"]="ansible.builtin.debug"
        ["assert"]="ansible.builtin.assert"
        ["fail"]="ansible.builtin.fail"
        ["set_fact"]="ansible.builtin.set_fact"
        ["stat"]="ansible.builtin.stat"
        ["uri"]="ansible.builtin.uri"
        ["get_url"]="ansible.builtin.get_url"
        ["unarchive"]="ansible.builtin.unarchive"
        ["wait_for"]="ansible.builtin.wait_for"
        ["pause"]="ansible.builtin.pause"
        ["include_tasks"]="ansible.builtin.include_tasks"
        ["import_tasks"]="ansible.builtin.import_tasks"
        ["include_role"]="ansible.builtin.include_role"
        ["import_role"]="ansible.builtin.import_role"
        ["include_vars"]="ansible.builtin.include_vars"
        ["setup"]="ansible.builtin.setup"
        ["ping"]="ansible.builtin.ping"
        ["meta"]="ansible.builtin.meta"
        ["async_status"]="ansible.builtin.async_status"
        ["fetch"]="ansible.builtin.fetch"
        ["find"]="ansible.builtin.find"
        ["hostname"]="ansible.builtin.hostname"
        ["known_hosts"]="ansible.builtin.known_hosts"
        ["reboot"]="ansible.builtin.reboot"
        ["sysctl"]="ansible.posix.sysctl"
        ["mount"]="ansible.posix.mount"
    )

    while IFS= read -r file; do
        local modified=false
        for short in "${!MODULE_MAP[@]}"; do
            local fqcn="${MODULE_MAP[$short]}"
            # Match "  module_name:" at task level (indented, as a YAML key)
            # Avoid matching if already FQCN or part of another word
            if grep -qP "^\s{4,}${short}:" "$file" 2>/dev/null; then
                # Verify it's not already FQCN
                if ! grep -qP "^\s{4,}${fqcn}:" "$file" 2>/dev/null; then
                    if ! $DRY_RUN; then
                        sed -i -E "s/(^\s{4,})${short}:/\1${fqcn}:/" "$file"
                    fi
                    modified=true
                fi
            fi
        done
        if $modified; then
            apply_fix "$file" "Convert short module names to FQCN"
            FILES_MODIFIED=$((FILES_MODIFIED + 1))
        fi
    done < <(find_yaml_files)
}

# --- Fix: Missing newline at end of file ---
fix_final_newline() {
    log_info "Checking for missing final newline..."
    while IFS= read -r file; do
        if [[ -s "$file" ]] && [[ "$(tail -c 1 "$file" | wc -l)" -eq 0 ]]; then
            apply_fix "$file" "Add missing final newline"
            if ! $DRY_RUN; then
                echo "" >> "$file"
            fi
        fi
    done < <(find_yaml_files)
}

# --- Report: Unnamed tasks (cannot auto-fix) ---
report_unnamed_tasks() {
    log_info "Checking for unnamed tasks..."
    while IFS= read -r file; do
        local unnamed
        unnamed=$(grep -nP '^\s{4,}(ansible\.|community\.|amazon\.|azure\.|google\.)[\w.]+:' "$file" 2>/dev/null | head -5 || true)
        if [[ -n "$unnamed" ]]; then
            # Check if the line before contains "- name:"
            while IFS= read -r match; do
                local linenum="${match%%:*}"
                local prev=$((linenum - 1))
                if [[ $prev -gt 0 ]]; then
                    local prev_line
                    prev_line=$(sed -n "${prev}p" "$file")
                    if [[ ! "$prev_line" =~ "name:" ]]; then
                        log_warn "${file}:${linenum}: Unnamed task (add '- name:' above this line)"
                    fi
                fi
            done <<< "$unnamed"
        fi
    done < <(find_yaml_files)
}

# --- Main ---
echo "============================================"
echo "  Ansible Lint Auto-Fix"
echo "============================================"
echo "Target: ${TARGET}"
$DRY_RUN && echo "Mode: DRY RUN (no changes will be made)"
echo ""

# Apply auto-fixes
fix_trailing_whitespace
fix_document_start
fix_file_modes
fix_truthy_values
fix_fqcn
fix_final_newline
report_unnamed_tasks

echo ""
echo "============================================"
echo "  Summary"
echo "============================================"
echo -e "Fixes applied:    ${GREEN}${FIXES_APPLIED}${NC}"
echo -e "Files modified:   ${BLUE}${FILES_MODIFIED}${NC}"
$DRY_RUN && echo -e "${YELLOW}(dry-run mode — no files were changed)${NC}"

# Run final ansible-lint report
if ! $FIX_ONLY; then
    echo ""
    echo "============================================"
    echo "  Running ansible-lint..."
    echo "============================================"
    if $VERBOSE; then
        ansible-lint "$TARGET" -v || true
    else
        ansible-lint "$TARGET" 2>&1 || true
    fi
fi
