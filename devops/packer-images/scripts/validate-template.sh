#!/usr/bin/env bash
# =============================================================================
# validate-template.sh — Validate Packer templates, check required plugins,
#                        verify credentials, and lint configuration
#
# Usage:
#   ./validate-template.sh [options] [PACKER_DIR]
#   ./validate-template.sh                           # Validate current dir
#   ./validate-template.sh packer/                   # Validate specific dir
#   ./validate-template.sh -f prod.pkrvars.hcl .     # With var file
#   ./validate-template.sh --check-creds .           # Also verify cloud creds
#   ./validate-template.sh --strict .                # Fail on warnings
#   ./validate-template.sh --fix .                   # Auto-fix formatting
#
# Options:
#   -f, --var-file FILE    Variable file for validation (repeatable)
#   --var KEY=VALUE        Set a variable (repeatable)
#   --check-creds          Verify cloud provider credentials
#   --check-plugins        Verify all required plugins are installed
#   --strict               Treat warnings as errors (fmt issues, etc.)
#   --fix                  Auto-fix formatting issues
#   --json                 Output results as JSON
#   --quiet                Suppress informational output
#   -h, --help             Show this help message
#
# Checks Performed:
#   1. Packer binary version check
#   2. HCL file syntax validation (packer validate)
#   3. Format check (packer fmt -check)
#   4. Plugin installation verification (packer init)
#   5. Required plugins version check
#   6. [Optional] Cloud credential verification
#   7. [Optional] Variable file existence check
#
# Exit Codes:
#   0  All checks passed
#   1  Validation failure
#   2  Missing dependency
#   3  Invalid arguments
#   4  Credential check failure
# =============================================================================

set -euo pipefail

# --- Defaults ---
PACKER_DIR=""
VAR_FILES=()
VARS=()
CHECK_CREDS=false
CHECK_PLUGINS=true
STRICT=false
FIX_FMT=false
JSON_OUTPUT=false
QUIET=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_ICON="✓"
FAIL_ICON="✗"
WARN_ICON="⚠"
SKIP_ICON="⊘"

# --- Output helpers ---
log_info()  { [ "$QUIET" = true ] && return; echo -e "${GREEN}${PASS_ICON}${NC} $*"; }
log_warn()  { [ "$QUIET" = true ] && return; echo -e "${YELLOW}${WARN_ICON}${NC} $*"; }
log_fail()  { echo -e "${RED}${FAIL_ICON}${NC} $*" >&2; }
log_skip()  { [ "$QUIET" = true ] && return; echo -e "${CYAN}${SKIP_ICON}${NC} $*"; }
log_check() { [ "$QUIET" = true ] && return; echo -e "${CYAN}▸${NC} $*"; }

# --- Results tracking ---
TOTAL=0; PASSED=0; FAILED=0; WARNED=0; SKIPPED=0
RESULTS=()

record_result() {
  local check="$1" status="$2" msg="$3"
  TOTAL=$((TOTAL + 1))
  case "$status" in
    pass) PASSED=$((PASSED + 1)); log_info "$check — $msg" ;;
    fail) FAILED=$((FAILED + 1)); log_fail "$check — $msg" ;;
    warn) WARNED=$((WARNED + 1)); log_warn "$check — $msg" ;;
    skip) SKIPPED=$((SKIPPED + 1)); log_skip "$check — $msg" ;;
  esac
  RESULTS+=("{\"check\":\"$check\",\"status\":\"$status\",\"message\":\"$msg\"}")
}

# --- Help ---
show_help() {
  sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//' | head -n -1
  exit 0
}

# --- Argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--var-file)    VAR_FILES+=("$2"); shift 2 ;;
    --var)            VARS+=("$2"); shift 2 ;;
    --check-creds)    CHECK_CREDS=true; shift ;;
    --check-plugins)  CHECK_PLUGINS=true; shift ;;
    --strict)         STRICT=true; shift ;;
    --fix)            FIX_FMT=true; shift ;;
    --json)           JSON_OUTPUT=true; QUIET=true; shift ;;
    --quiet|-q)       QUIET=true; shift ;;
    -h|--help)        show_help ;;
    -*)               echo "Unknown option: $1" >&2; exit 3 ;;
    *)
      [ -z "$PACKER_DIR" ] && PACKER_DIR="$1" || { echo "Unexpected arg: $1" >&2; exit 3; }
      shift ;;
  esac
done

PACKER_DIR="${PACKER_DIR:-.}"

# =========================================================================
# Check 1: Packer binary
# =========================================================================
log_check "Checking Packer installation"

if ! command -v packer &>/dev/null; then
  record_result "packer-binary" "fail" "packer not found in PATH"
  echo "Install: https://developer.hashicorp.com/packer/downloads"
  exit 2
fi

PACKER_VER=$(packer version -machine-readable 2>/dev/null | grep version | head -1 | cut -d, -f3 || packer version | head -1)
record_result "packer-binary" "pass" "packer $PACKER_VER"

# Check minimum version
MIN_VERSION="1.9.0"
CURRENT_VER=$(echo "$PACKER_VER" | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ -n "$CURRENT_VER" ]; then
  if printf '%s\n' "$MIN_VERSION" "$CURRENT_VER" | sort -V | head -1 | grep -q "^${MIN_VERSION}$"; then
    record_result "packer-version" "pass" ">= $MIN_VERSION (have $CURRENT_VER)"
  else
    record_result "packer-version" "warn" "Recommended >= $MIN_VERSION (have $CURRENT_VER)"
  fi
fi

# =========================================================================
# Check 2: Template directory
# =========================================================================
log_check "Checking template directory"

if [ ! -d "$PACKER_DIR" ]; then
  record_result "template-dir" "fail" "Directory not found: $PACKER_DIR"
  exit 3
fi

HCL_COUNT=$(find "$PACKER_DIR" -maxdepth 1 -name '*.pkr.hcl' | wc -l)
if [ "$HCL_COUNT" -eq 0 ]; then
  record_result "template-files" "fail" "No .pkr.hcl files in $PACKER_DIR"
  exit 3
fi
record_result "template-files" "pass" "Found $HCL_COUNT .pkr.hcl file(s) in $PACKER_DIR"

# Check for deprecated JSON templates
JSON_COUNT=$(find "$PACKER_DIR" -maxdepth 1 -name '*.json' -not -name 'manifest.json' -not -name 'package.json' | wc -l)
if [ "$JSON_COUNT" -gt 0 ]; then
  record_result "json-templates" "warn" "Found $JSON_COUNT .json template(s) — migrate to HCL2"
fi

# =========================================================================
# Check 3: Variable files
# =========================================================================
log_check "Checking variable files"

for vf in "${VAR_FILES[@]}"; do
  if [ -f "$vf" ]; then
    record_result "var-file" "pass" "$vf exists"
  else
    record_result "var-file" "fail" "Variable file not found: $vf"
  fi
done

# Check for auto-loaded var files
AUTO_VARS=$(find "$PACKER_DIR" -maxdepth 1 -name '*.auto.pkrvars.hcl' 2>/dev/null | wc -l)
if [ "$AUTO_VARS" -gt 0 ]; then
  record_result "auto-vars" "pass" "Found $AUTO_VARS auto-loaded variable file(s)"
fi

# =========================================================================
# Check 4: Plugin initialization
# =========================================================================
log_check "Initializing and checking plugins"

INIT_OUTPUT=$(packer init "$PACKER_DIR" 2>&1) || {
  record_result "plugin-init" "fail" "packer init failed: $INIT_OUTPUT"
}

if [ $? -eq 0 ] 2>/dev/null; then
  record_result "plugin-init" "pass" "All plugins installed"
fi

# Check if plugins are up to date
if [ "$CHECK_PLUGINS" = true ]; then
  UPGRADE_OUTPUT=$(packer init -upgrade "$PACKER_DIR" 2>&1 || true)
  if echo "$UPGRADE_OUTPUT" | grep -qi "upgraded"; then
    record_result "plugin-versions" "warn" "Plugin updates available (run: packer init -upgrade $PACKER_DIR)"
  else
    record_result "plugin-versions" "pass" "All plugins up to date"
  fi
fi

# =========================================================================
# Check 5: Format check
# =========================================================================
log_check "Checking formatting"

FMT_OUTPUT=$(packer fmt -check -diff "$PACKER_DIR" 2>&1)
FMT_EXIT=$?

if [ $FMT_EXIT -eq 0 ]; then
  record_result "formatting" "pass" "All files properly formatted"
else
  if [ "$FIX_FMT" = true ]; then
    packer fmt "$PACKER_DIR" >/dev/null 2>&1
    record_result "formatting" "pass" "Files auto-formatted (--fix)"
  elif [ "$STRICT" = true ]; then
    record_result "formatting" "fail" "Files need formatting (run: packer fmt $PACKER_DIR)"
  else
    record_result "formatting" "warn" "Files need formatting (run: packer fmt $PACKER_DIR)"
  fi
fi

# =========================================================================
# Check 6: Template validation
# =========================================================================
log_check "Validating template"

VALIDATE_ARGS=()
for vf in "${VAR_FILES[@]}"; do
  VALIDATE_ARGS+=("-var-file=$vf")
done
for v in "${VARS[@]}"; do
  VALIDATE_ARGS+=("-var" "$v")
done

VALIDATE_OUTPUT=$(packer validate "${VALIDATE_ARGS[@]}" "$PACKER_DIR" 2>&1)
VALIDATE_EXIT=$?

if [ $VALIDATE_EXIT -eq 0 ]; then
  record_result "validation" "pass" "Template is valid"
else
  record_result "validation" "fail" "$VALIDATE_OUTPUT"
fi

# =========================================================================
# Check 7: Credential verification (optional)
# =========================================================================
if [ "$CHECK_CREDS" = true ]; then
  log_check "Verifying cloud credentials"

  # Detect which builders are used
  BUILDERS=$(grep -rh 'source\s*"' "$PACKER_DIR"/*.pkr.hcl 2>/dev/null | grep -oP '"[a-z-]+"' | tr -d '"' | sort -u || true)

  # AWS credentials
  if echo "$BUILDERS" | grep -q "amazon"; then
    if command -v aws &>/dev/null; then
      if aws sts get-caller-identity &>/dev/null; then
        AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
        AWS_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
        record_result "aws-creds" "pass" "Account $AWS_ACCOUNT ($AWS_ARN)"
      else
        record_result "aws-creds" "fail" "AWS credentials not configured or expired"
      fi
    else
      record_result "aws-creds" "skip" "aws CLI not installed"
    fi
  fi

  # Azure credentials
  if echo "$BUILDERS" | grep -q "azure"; then
    if command -v az &>/dev/null; then
      if az account show &>/dev/null; then
        AZ_SUB=$(az account show --query name -o tsv 2>/dev/null)
        record_result "azure-creds" "pass" "Subscription: $AZ_SUB"
      else
        record_result "azure-creds" "fail" "Azure credentials not configured (run: az login)"
      fi
    else
      record_result "azure-creds" "skip" "az CLI not installed"
    fi
  fi

  # GCP credentials
  if echo "$BUILDERS" | grep -q "googlecompute"; then
    if command -v gcloud &>/dev/null; then
      if gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 | grep -q '@'; then
        GCP_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
        GCP_PROJECT=$(gcloud config get-value project 2>/dev/null)
        record_result "gcp-creds" "pass" "Account: $GCP_ACCOUNT, Project: $GCP_PROJECT"
      else
        record_result "gcp-creds" "fail" "GCP credentials not configured (run: gcloud auth login)"
      fi
    else
      record_result "gcp-creds" "skip" "gcloud CLI not installed"
    fi
  fi

  # Docker
  if echo "$BUILDERS" | grep -q "docker"; then
    if command -v docker &>/dev/null; then
      if docker info &>/dev/null 2>&1; then
        record_result "docker" "pass" "Docker daemon is running"
      else
        record_result "docker" "fail" "Docker daemon not accessible"
      fi
    else
      record_result "docker" "skip" "docker CLI not installed"
    fi
  fi
else
  log_skip "Credential check — skipped (use --check-creds to enable)"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""

if [ "$JSON_OUTPUT" = true ]; then
  echo "{"
  echo "  \"total\": $TOTAL,"
  echo "  \"passed\": $PASSED,"
  echo "  \"failed\": $FAILED,"
  echo "  \"warned\": $WARNED,"
  echo "  \"skipped\": $SKIPPED,"
  echo "  \"results\": [$(IFS=,; echo "${RESULTS[*]}")]"
  echo "}"
else
  echo "━━━ Validation Summary ━━━"
  echo -e "  ${GREEN}Passed${NC}: $PASSED"
  [ "$FAILED" -gt 0 ] && echo -e "  ${RED}Failed${NC}: $FAILED"
  [ "$WARNED" -gt 0 ] && echo -e "  ${YELLOW}Warned${NC}: $WARNED"
  [ "$SKIPPED" -gt 0 ] && echo -e "  ${CYAN}Skipped${NC}: $SKIPPED"
  echo ""

  if [ "$FAILED" -gt 0 ]; then
    echo -e "  ${RED}RESULT: FAILED${NC}"
  elif [ "$WARNED" -gt 0 ] && [ "$STRICT" = true ]; then
    echo -e "  ${YELLOW}RESULT: FAILED (strict mode)${NC}"
  else
    echo -e "  ${GREEN}RESULT: PASSED${NC}"
  fi
fi

# --- Exit code ---
if [ "$FAILED" -gt 0 ]; then
  exit 1
elif [ "$WARNED" -gt 0 ] && [ "$STRICT" = true ]; then
  exit 1
else
  exit 0
fi
