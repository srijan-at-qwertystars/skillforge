#!/usr/bin/env bash
# =============================================================================
# vercel-env-sync.sh — Vercel Environment Variable Management
# =============================================================================
# Usage:
#   ./vercel-env-sync.sh pull                  # Pull env vars from Vercel → .env.local
#   ./vercel-env-sync.sh push                  # Push local .env.local → Vercel
#   ./vercel-env-sync.sh diff                  # Diff local vs remote env vars
#   ./vercel-env-sync.sh sync                  # Sync across environments
#   ./vercel-env-sync.sh export                # Export env vars to .env.production
#   ./vercel-env-sync.sh list                  # List remote env vars
#
# Options:
#   --env <environment>     Target environment: production|preview|development (default: development)
#   --file <path>           Local env file path (default: .env.local)
#   --dry-run               Preview changes without applying
#   --token <token>         Vercel token (or set VERCEL_TOKEN env var)
#   -h, --help              Show help
#
# Prerequisites:
#   - Vercel CLI installed: npm i -g vercel
#   - Project linked: vercel link
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
COMMAND=""
ENVIRONMENT="development"
ENV_FILE=".env.local"
DRY_RUN=false
TOKEN="${VERCEL_TOKEN:-}"
TEMP_DIR=""

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_diff_add() { echo -e "${GREEN}+ $1${NC}"; }
log_diff_rm()  { echo -e "${RED}- $1${NC}"; }
log_diff_mod() { echo -e "${YELLOW}~ $1${NC}"; }

cleanup() {
  if [[ -n "$TEMP_DIR" ]] && [[ -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  echo "Usage: $0 <command> [OPTIONS]"
  echo ""
  echo "Commands:"
  echo "  pull      Pull env vars from Vercel to local file"
  echo "  push      Push local env vars to Vercel"
  echo "  diff      Compare local vs remote env vars"
  echo "  sync      Sync env vars across environments"
  echo "  export    Export remote env vars to a file"
  echo "  list      List remote env vars (keys only)"
  echo ""
  echo "Options:"
  echo "  --env <env>        Target: production|preview|development (default: development)"
  echo "  --file <path>      Local env file (default: .env.local)"
  echo "  --dry-run          Preview changes without applying"
  echo "  --token <token>    Vercel API token"
  echo "  -h, --help         Show this help"
  exit 0
}

# ---- Argument Parsing ----
if [[ $# -lt 1 ]]; then
  usage
fi

COMMAND="$1"
shift

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)      ENVIRONMENT="$2"; shift 2 ;;
    --file)     ENV_FILE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --token)    TOKEN="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *)          log_error "Unknown option: $1"; usage ;;
  esac
done

# ---- Validation ----
check_vercel_cli() {
  if ! command -v vercel &>/dev/null; then
    log_error "Vercel CLI not found. Install: npm i -g vercel"
    exit 1
  fi
}

check_linked() {
  if [[ ! -d ".vercel" ]]; then
    log_error "Project not linked. Run: vercel link"
    exit 1
  fi
}

validate_environment() {
  case "$ENVIRONMENT" in
    production|preview|development) ;;
    *) log_error "Invalid environment: $ENVIRONMENT (use production|preview|development)"; exit 1 ;;
  esac
}

# ---- Parse .env File ----
# Reads a .env file and outputs KEY=VALUE pairs, skipping comments and empty lines
parse_env_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    log_error "File not found: $file"
    return 1
  fi
  grep -v '^\s*#' "$file" | grep -v '^\s*$' | grep '=' || true
}

# Extract just the key names from a .env file
get_env_keys() {
  local file="$1"
  parse_env_file "$file" | cut -d'=' -f1 | sort
}

# Get value for a specific key from .env file
get_env_value() {
  local file="$1"
  local key="$2"
  parse_env_file "$file" | grep "^${key}=" | head -1 | cut -d'=' -f2-
}

# ---- Commands ----

cmd_pull() {
  log_info "Pulling env vars from Vercel ($ENVIRONMENT) → $ENV_FILE"
  check_vercel_cli
  check_linked

  local token_arg=""
  if [[ -n "$TOKEN" ]]; then
    token_arg="--token=$TOKEN"
  fi

  if $DRY_RUN; then
    log_info "[DRY RUN] Would run: vercel env pull $ENV_FILE --environment=$ENVIRONMENT"
    return
  fi

  # Backup existing file
  if [[ -f "$ENV_FILE" ]]; then
    cp "$ENV_FILE" "${ENV_FILE}.bak"
    log_info "Backed up existing $ENV_FILE → ${ENV_FILE}.bak"
  fi

  # shellcheck disable=SC2086
  vercel env pull "$ENV_FILE" --environment="$ENVIRONMENT" --yes $token_arg
  log_ok "Pulled env vars to $ENV_FILE"

  local count
  count=$(parse_env_file "$ENV_FILE" | wc -l | tr -d ' ')
  log_info "Total variables: $count"
}

cmd_push() {
  log_info "Pushing env vars from $ENV_FILE → Vercel ($ENVIRONMENT)"
  check_vercel_cli
  check_linked

  if [[ ! -f "$ENV_FILE" ]]; then
    log_error "File not found: $ENV_FILE"
    exit 1
  fi

  local token_arg=""
  if [[ -n "$TOKEN" ]]; then
    token_arg="--token=$TOKEN"
  fi

  local count=0
  local skipped=0

  while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    local key value
    key=$(echo "$line" | cut -d'=' -f1)
    value=$(echo "$line" | cut -d'=' -f2-)

    # Skip Vercel system variables
    if [[ "$key" =~ ^VERCEL_ ]] || [[ "$key" =~ ^NEXT_RUNTIME ]]; then
      log_warn "Skipping system variable: $key"
      ((skipped++)) || true
      continue
    fi

    if $DRY_RUN; then
      log_info "[DRY RUN] Would set: $key ($ENVIRONMENT)"
    else
      echo "$value" | vercel env add "$key" "$ENVIRONMENT" --yes $token_arg 2>/dev/null || {
        # Variable might already exist — try removing first
        vercel env rm "$key" "$ENVIRONMENT" --yes $token_arg 2>/dev/null || true
        echo "$value" | vercel env add "$key" "$ENVIRONMENT" --yes $token_arg
      }
      log_ok "Set: $key"
    fi
    ((count++)) || true
  done < "$ENV_FILE"

  echo ""
  log_ok "Pushed $count variable(s) to $ENVIRONMENT"
  [[ $skipped -gt 0 ]] && log_info "Skipped $skipped system variable(s)"
}

cmd_diff() {
  log_info "Comparing local ($ENV_FILE) vs remote ($ENVIRONMENT)"
  check_vercel_cli
  check_linked

  if [[ ! -f "$ENV_FILE" ]]; then
    log_error "Local file not found: $ENV_FILE"
    exit 1
  fi

  local token_arg=""
  if [[ -n "$TOKEN" ]]; then
    token_arg="--token=$TOKEN"
  fi

  TEMP_DIR=$(mktemp -d)
  local remote_file="$TEMP_DIR/.env.remote"

  # Pull remote vars
  # shellcheck disable=SC2086
  vercel env pull "$remote_file" --environment="$ENVIRONMENT" --yes $token_arg 2>/dev/null

  local local_keys remote_keys
  local_keys=$(get_env_keys "$ENV_FILE")
  remote_keys=$(get_env_keys "$remote_file")

  echo ""
  echo "========================================"
  echo "  Environment Variable Diff"
  echo "  Local: $ENV_FILE"
  echo "  Remote: Vercel $ENVIRONMENT"
  echo "========================================"
  echo ""

  local has_diff=false

  # Keys only in local
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if ! echo "$remote_keys" | grep -q "^${key}$"; then
      log_diff_add "$key (local only — not in remote)"
      has_diff=true
    fi
  done <<< "$local_keys"

  # Keys only in remote
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if ! echo "$local_keys" | grep -q "^${key}$"; then
      log_diff_rm "$key (remote only — not in local)"
      has_diff=true
    fi
  done <<< "$remote_keys"

  # Keys in both but with different values
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if echo "$remote_keys" | grep -q "^${key}$"; then
      local local_val remote_val
      local_val=$(get_env_value "$ENV_FILE" "$key")
      remote_val=$(get_env_value "$remote_file" "$key")
      if [[ "$local_val" != "$remote_val" ]]; then
        log_diff_mod "$key (values differ)"
        has_diff=true
      fi
    fi
  done <<< "$local_keys"

  if ! $has_diff; then
    log_ok "No differences found!"
  fi
  echo ""
}

cmd_sync() {
  log_info "Syncing env vars across environments"
  check_vercel_cli
  check_linked

  local token_arg=""
  if [[ -n "$TOKEN" ]]; then
    token_arg="--token=$TOKEN"
  fi

  local source_env="production"
  local target_envs=("preview" "development")

  echo ""
  echo "This will sync env vars from '$source_env' to: ${target_envs[*]}"
  echo ""

  if $DRY_RUN; then
    log_info "[DRY RUN] Would sync from $source_env to ${target_envs[*]}"

    TEMP_DIR=$(mktemp -d)
    local source_file="$TEMP_DIR/.env.source"
    # shellcheck disable=SC2086
    vercel env pull "$source_file" --environment="$source_env" --yes $token_arg 2>/dev/null

    log_info "Variables that would be synced:"
    parse_env_file "$source_file" | cut -d'=' -f1 | while read -r key; do
      # Skip system variables
      [[ "$key" =~ ^VERCEL_ ]] && continue
      echo "  $key"
    done
    return
  fi

  TEMP_DIR=$(mktemp -d)
  local source_file="$TEMP_DIR/.env.source"
  # shellcheck disable=SC2086
  vercel env pull "$source_file" --environment="$source_env" --yes $token_arg 2>/dev/null

  for target in "${target_envs[@]}"; do
    log_info "Syncing to $target..."
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      local key value
      key=$(echo "$line" | cut -d'=' -f1)
      value=$(echo "$line" | cut -d'=' -f2-)
      [[ "$key" =~ ^VERCEL_ ]] && continue

      # shellcheck disable=SC2086
      vercel env rm "$key" "$target" --yes $token_arg 2>/dev/null || true
      # shellcheck disable=SC2086
      echo "$value" | vercel env add "$key" "$target" --yes $token_arg 2>/dev/null
    done < <(parse_env_file "$source_file")
    log_ok "Synced to $target"
  done

  echo ""
  log_ok "Sync complete!"
  log_warn "Remember to redeploy preview/development to pick up changes."
}

cmd_export() {
  log_info "Exporting env vars from Vercel ($ENVIRONMENT)"
  check_vercel_cli
  check_linked

  local output_file=".env.${ENVIRONMENT}"
  local token_arg=""
  if [[ -n "$TOKEN" ]]; then
    token_arg="--token=$TOKEN"
  fi

  if $DRY_RUN; then
    log_info "[DRY RUN] Would export to $output_file"
    return
  fi

  # shellcheck disable=SC2086
  vercel env pull "$output_file" --environment="$ENVIRONMENT" --yes $token_arg
  log_ok "Exported to $output_file"

  local count
  count=$(parse_env_file "$output_file" | wc -l | tr -d ' ')
  log_info "Total variables: $count"
}

cmd_list() {
  log_info "Listing remote env vars ($ENVIRONMENT)"
  check_vercel_cli
  check_linked

  local token_arg=""
  if [[ -n "$TOKEN" ]]; then
    token_arg="--token=$TOKEN"
  fi

  TEMP_DIR=$(mktemp -d)
  local remote_file="$TEMP_DIR/.env.remote"
  # shellcheck disable=SC2086
  vercel env pull "$remote_file" --environment="$ENVIRONMENT" --yes $token_arg 2>/dev/null

  echo ""
  echo "========================================"
  echo "  Vercel Env Vars ($ENVIRONMENT)"
  echo "========================================"
  echo ""

  local count=0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    local key value
    key=$(echo "$line" | cut -d'=' -f1)
    value=$(echo "$line" | cut -d'=' -f2-)
    # Mask sensitive values
    local masked
    if [[ ${#value} -gt 8 ]]; then
      masked="${value:0:4}****${value: -4}"
    else
      masked="****"
    fi
    printf "  %-40s %s\n" "$key" "$masked"
    ((count++)) || true
  done < <(parse_env_file "$remote_file")

  echo ""
  log_info "Total: $count variable(s)"
}

# ---- Main ----
validate_environment

case "$COMMAND" in
  pull)   cmd_pull ;;
  push)   cmd_push ;;
  diff)   cmd_diff ;;
  sync)   cmd_sync ;;
  export) cmd_export ;;
  list)   cmd_list ;;
  *)      log_error "Unknown command: $COMMAND"; usage ;;
esac
