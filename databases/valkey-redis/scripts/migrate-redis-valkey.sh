#!/usr/bin/env bash
# migrate-redis-valkey.sh — Migration helper from Redis to Valkey
#
# Usage:
#   ./migrate-redis-valkey.sh [COMMAND] [OPTIONS]
#
# Commands:
#   check        Pre-migration compatibility check (default)
#   prepare      Prepare Valkey config from existing Redis config
#   swap         Stop Redis, start Valkey with same data dir
#   verify       Post-migration verification
#   rollback     Rollback to Redis
#
# Options:
#   --redis-conf PATH     Path to redis.conf (default: /etc/redis/redis.conf)
#   --valkey-conf PATH    Path for valkey.conf output (default: /etc/valkey/valkey.conf)
#   --data-dir PATH       Data directory (default: auto-detect from config)
#   --redis-port PORT     Redis port (default: 6379)
#   --dry-run             Show what would be done without doing it
#   -h, --help            Show this help message
#
# Prerequisites:
#   - valkey-server and valkey-cli installed
#   - Backup of Redis data (RDB/AOF files)
#   - Root/sudo access for service management
#
# The migration is a binary swap — Valkey reads Redis data files natively.

set -euo pipefail

# --- Defaults ---
COMMAND="${1:-check}"
REDIS_CONF="/etc/redis/redis.conf"
VALKEY_CONF="/etc/valkey/valkey.conf"
DATA_DIR=""
REDIS_PORT="6379"
DRY_RUN=false

# --- Parse arguments ---
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --redis-conf)   REDIS_CONF="$2"; shift 2 ;;
    --valkey-conf)  VALKEY_CONF="$2"; shift 2 ;;
    --data-dir)     DATA_DIR="$2"; shift 2 ;;
    --redis-port)   REDIS_PORT="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,/^$/s/^# //p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${GREEN}>>>${NC} $1"; }

# --- Detect data dir from config ---
detect_data_dir() {
  if [[ -n "$DATA_DIR" ]]; then
    echo "$DATA_DIR"
    return
  fi
  if [[ -f "$REDIS_CONF" ]]; then
    local dir
    dir=$(grep -E "^dir " "$REDIS_CONF" | awk '{print $2}' | head -1)
    if [[ -n "$dir" ]]; then
      echo "$dir"
      return
    fi
  fi
  # Common defaults
  for d in /var/lib/redis /var/lib/valkey /data; do
    if [[ -d "$d" ]]; then
      echo "$d"
      return
    fi
  done
  echo "/var/lib/redis"
}

# --- Command: check ---
cmd_check() {
  step "Pre-Migration Compatibility Check"
  local issues=0

  # Check Redis version
  info "Checking Redis version..."
  if command -v redis-server &>/dev/null; then
    REDIS_VERSION=$(redis-server --version 2>/dev/null | grep -oP 'v=\K[0-9.]+' || echo "unknown")
    info "  Redis version: $REDIS_VERSION"
    MAJOR=$(echo "$REDIS_VERSION" | cut -d. -f1)
    MINOR=$(echo "$REDIS_VERSION" | cut -d. -f2)
    if [[ "$MAJOR" -gt 7 ]] || [[ "$MAJOR" -eq 7 && "$MINOR" -gt 2 ]]; then
      warn "  Redis $REDIS_VERSION may have features not in Valkey 7.2.x"
      warn "  Check Valkey 8.x for compatibility with newer Redis features"
      issues=$((issues + 1))
    else
      info "  ✓ Compatible with Valkey (Redis ≤7.2.4)"
    fi
  else
    error "  redis-server not found"
    issues=$((issues + 1))
  fi

  # Check Valkey availability
  info "Checking Valkey installation..."
  if command -v valkey-server &>/dev/null; then
    VALKEY_VERSION=$(valkey-server --version 2>/dev/null | grep -oP 'v=\K[0-9.]+' || echo "unknown")
    info "  ✓ valkey-server found (version $VALKEY_VERSION)"
  else
    error "  valkey-server not found — install Valkey first"
    issues=$((issues + 1))
  fi

  if command -v valkey-cli &>/dev/null; then
    info "  ✓ valkey-cli found"
  else
    error "  valkey-cli not found"
    issues=$((issues + 1))
  fi

  # Check config
  info "Checking Redis configuration..."
  if [[ -f "$REDIS_CONF" ]]; then
    info "  ✓ Config found: $REDIS_CONF"

    # Check for Redis-specific modules
    if grep -qE "^loadmodule" "$REDIS_CONF" 2>/dev/null; then
      warn "  Modules detected — verify Valkey module compatibility:"
      grep -E "^loadmodule" "$REDIS_CONF" | sed 's/^/    /'
      issues=$((issues + 1))
    fi

    # Check for renamed commands
    if grep -qE "^rename-command" "$REDIS_CONF" 2>/dev/null; then
      info "  Note: rename-command directives found (will carry over)"
    fi
  else
    warn "  Config not found at $REDIS_CONF"
    issues=$((issues + 1))
  fi

  # Check data directory
  local ddir
  ddir=$(detect_data_dir)
  info "Checking data directory: $ddir"
  if [[ -d "$ddir" ]]; then
    info "  ✓ Directory exists"
    if ls "$ddir"/dump*.rdb &>/dev/null 2>&1; then
      RDB_SIZE=$(du -sh "$ddir"/dump*.rdb 2>/dev/null | head -1 | awk '{print $1}')
      info "  ✓ RDB file found ($RDB_SIZE)"
    fi
    if [[ -d "$ddir/appendonlydir" ]] || ls "$ddir"/appendonly*.aof &>/dev/null 2>&1; then
      info "  ✓ AOF files found"
    fi
  else
    warn "  Data directory not found: $ddir"
    issues=$((issues + 1))
  fi

  # Check running Redis instance
  info "Checking running Redis instance..."
  if redis-cli -p "$REDIS_PORT" PING &>/dev/null 2>&1; then
    info "  ✓ Redis responding on port $REDIS_PORT"
    DBSIZE=$(redis-cli -p "$REDIS_PORT" DBSIZE 2>/dev/null | grep -oP '\d+' || echo "unknown")
    info "  Total keys: $DBSIZE"
    MEM=$(redis-cli -p "$REDIS_PORT" INFO memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '[:space:]')
    info "  Memory usage: $MEM"
  else
    info "  Redis not running on port $REDIS_PORT (or auth required)"
  fi

  # Check client libraries in use (scan common project files)
  info "Checking for client library references..."
  for pattern in "ioredis" "redis-py" "go-redis" "jedis" "lettuce"; do
    if grep -rl "$pattern" . --include="*.json" --include="*.txt" --include="*.toml" --include="*.gradle" --include="*.xml" 2>/dev/null | head -1 >/dev/null 2>&1; then
      info "  Found $pattern reference (no change needed for Valkey compatibility)"
    fi
  done

  # Summary
  echo ""
  if [[ $issues -eq 0 ]]; then
    info "✓ All checks passed — ready for migration"
  else
    warn "$issues issue(s) found — review before proceeding"
  fi

  return $issues
}

# --- Command: prepare ---
cmd_prepare() {
  step "Preparing Valkey Configuration"

  if [[ ! -f "$REDIS_CONF" ]]; then
    error "Redis config not found: $REDIS_CONF"
    exit 1
  fi

  info "Source: $REDIS_CONF"
  info "Target: $VALKEY_CONF"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would create $VALKEY_CONF from $REDIS_CONF"
    info "Changes:"
    info "  - Copy config as-is (Valkey reads redis.conf format)"
    info "  - Add migration metadata comment"
    return
  fi

  # Create target directory
  mkdir -p "$(dirname "$VALKEY_CONF")"

  # Copy config — Valkey reads the same format
  {
    echo "# Valkey configuration"
    echo "# Migrated from Redis config: $REDIS_CONF"
    echo "# Migration date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Original Redis version: $(redis-server --version 2>/dev/null | head -1 || echo 'unknown')"
    echo ""
    cat "$REDIS_CONF"
  } > "$VALKEY_CONF"

  info "✓ Configuration written to $VALKEY_CONF"
  info ""
  info "Review the config, then run:"
  info "  $0 swap"
}

# --- Command: swap ---
cmd_swap() {
  step "Swapping Redis → Valkey"

  if ! command -v valkey-server &>/dev/null; then
    error "valkey-server not found in PATH"
    exit 1
  fi

  local ddir
  ddir=$(detect_data_dir)

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would perform:"
    info "  1. Trigger BGSAVE on Redis"
    info "  2. Stop Redis service"
    info "  3. Backup current data directory"
    info "  4. Start Valkey with data from $ddir"
    info "  5. Verify Valkey is responding"
    return
  fi

  # Step 1: Trigger final save
  info "Triggering Redis BGSAVE..."
  if redis-cli -p "$REDIS_PORT" BGSAVE &>/dev/null 2>&1; then
    sleep 2
    info "  ✓ BGSAVE triggered"
  else
    warn "  Could not trigger BGSAVE (Redis may not be running)"
  fi

  # Step 2: Record key count for verification
  PRE_DBSIZE=$(redis-cli -p "$REDIS_PORT" DBSIZE 2>/dev/null | grep -oP '\d+' || echo "0")
  info "Pre-migration key count: $PRE_DBSIZE"

  # Step 3: Stop Redis
  info "Stopping Redis..."
  if systemctl is-active redis &>/dev/null 2>&1; then
    sudo systemctl stop redis
    info "  ✓ Redis stopped (systemd)"
  elif systemctl is-active redis-server &>/dev/null 2>&1; then
    sudo systemctl stop redis-server
    info "  ✓ Redis stopped (systemd: redis-server)"
  elif redis-cli -p "$REDIS_PORT" SHUTDOWN SAVE &>/dev/null 2>&1; then
    info "  ✓ Redis stopped (SHUTDOWN)"
  else
    warn "  Could not stop Redis automatically"
    warn "  Please stop Redis manually and re-run this command"
    exit 1
  fi

  # Step 4: Backup data directory
  BACKUP_DIR="${ddir}.backup.$(date +%Y%m%d%H%M%S)"
  info "Backing up data to $BACKUP_DIR..."
  cp -a "$ddir" "$BACKUP_DIR"
  info "  ✓ Backup created"

  # Step 5: Start Valkey
  CONF_TO_USE="$VALKEY_CONF"
  if [[ ! -f "$VALKEY_CONF" ]]; then
    CONF_TO_USE="$REDIS_CONF"
    info "Using Redis config directly (Valkey is compatible)"
  fi

  info "Starting Valkey..."
  if [[ -f /etc/systemd/system/valkey.service ]] || systemctl list-unit-files valkey.service &>/dev/null 2>&1; then
    sudo systemctl start valkey
    info "  ✓ Valkey started (systemd)"
  else
    info "  No systemd service found. Starting manually..."
    valkey-server "$CONF_TO_USE" --daemonize yes
    info "  ✓ Valkey started (manual)"
  fi

  # Step 6: Wait and verify
  sleep 2
  info "Verifying Valkey..."
  if valkey-cli -p "$REDIS_PORT" PING 2>/dev/null | grep -q "PONG"; then
    POST_DBSIZE=$(valkey-cli -p "$REDIS_PORT" DBSIZE 2>/dev/null | grep -oP '\d+' || echo "0")
    info "  ✓ Valkey responding on port $REDIS_PORT"
    info "  Key count: $POST_DBSIZE (was $PRE_DBSIZE)"
    if [[ "$PRE_DBSIZE" != "0" && "$POST_DBSIZE" != "$PRE_DBSIZE" ]]; then
      warn "  Key count mismatch — verify data integrity"
    fi
  else
    error "  Valkey not responding on port $REDIS_PORT"
    error "  Check logs and consider rollback: $0 rollback"
    exit 1
  fi

  info ""
  info "✓ Migration complete!"
  info "  Backup: $BACKUP_DIR"
  info "  Run '$0 verify' for full post-migration check"
}

# --- Command: verify ---
cmd_verify() {
  step "Post-Migration Verification"

  # Check Valkey is running
  local cli
  if command -v valkey-cli &>/dev/null; then
    cli="valkey-cli"
  elif command -v redis-cli &>/dev/null; then
    cli="redis-cli"
  else
    error "No CLI tool found"
    exit 1
  fi

  if ! $cli -p "$REDIS_PORT" PING 2>/dev/null | grep -q "PONG"; then
    error "Server not responding on port $REDIS_PORT"
    exit 1
  fi

  info "Server responding: ✓"

  # Version check
  VERSION=$($cli -p "$REDIS_PORT" INFO server 2>/dev/null | grep "redis_version:" | cut -d: -f2 | tr -d '[:space:]')
  SERVER_NAME=$($cli -p "$REDIS_PORT" INFO server 2>/dev/null | grep -i "executable\|server_name" | head -1)
  info "Server version: $VERSION"
  info "Server info: $SERVER_NAME"

  # Key count
  DBSIZE=$($cli -p "$REDIS_PORT" DBSIZE 2>/dev/null | grep -oP '\d+' || echo "unknown")
  info "Total keys: $DBSIZE"

  # Memory
  MEM=$($cli -p "$REDIS_PORT" INFO memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '[:space:]')
  info "Memory usage: $MEM"

  # Replication
  ROLE=$($cli -p "$REDIS_PORT" INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '[:space:]')
  info "Role: $ROLE"

  # Persistence
  AOF=$($cli -p "$REDIS_PORT" INFO persistence 2>/dev/null | grep "aof_enabled:" | cut -d: -f2 | tr -d '[:space:]')
  RDB_STATUS=$($cli -p "$REDIS_PORT" INFO persistence 2>/dev/null | grep "rdb_last_bgsave_status:" | cut -d: -f2 | tr -d '[:space:]')
  info "AOF enabled: $AOF"
  info "RDB last status: $RDB_STATUS"

  # Test basic operations
  info "Testing basic operations..."
  TEST_KEY="__migration_verify_$(date +%s)"
  $cli -p "$REDIS_PORT" SET "$TEST_KEY" "valkey-migration-test" EX 60 &>/dev/null
  TEST_VAL=$($cli -p "$REDIS_PORT" GET "$TEST_KEY" 2>/dev/null)
  $cli -p "$REDIS_PORT" DEL "$TEST_KEY" &>/dev/null

  if [[ "$TEST_VAL" == "valkey-migration-test" ]]; then
    info "  ✓ SET/GET working"
  else
    error "  ✗ SET/GET test failed"
  fi

  info ""
  info "✓ Verification complete"
}

# --- Command: rollback ---
cmd_rollback() {
  step "Rolling Back to Redis"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would perform:"
    info "  1. Stop Valkey"
    info "  2. Restore data from backup"
    info "  3. Start Redis"
    return
  fi

  local ddir
  ddir=$(detect_data_dir)

  # Find most recent backup
  LATEST_BACKUP=$(ls -td "${ddir}.backup."* 2>/dev/null | head -1)
  if [[ -z "$LATEST_BACKUP" ]]; then
    error "No backup found at ${ddir}.backup.*"
    error "Cannot rollback without backup"
    exit 1
  fi

  info "Using backup: $LATEST_BACKUP"

  # Stop Valkey
  info "Stopping Valkey..."
  if systemctl is-active valkey &>/dev/null 2>&1; then
    sudo systemctl stop valkey
  elif valkey-cli -p "$REDIS_PORT" SHUTDOWN NOSAVE &>/dev/null 2>&1; then
    true
  fi
  info "  ✓ Valkey stopped"

  # Restore data
  info "Restoring data from backup..."
  if [[ -d "$ddir" ]]; then
    mv "$ddir" "${ddir}.valkey.$(date +%Y%m%d%H%M%S)"
  fi
  cp -a "$LATEST_BACKUP" "$ddir"
  info "  ✓ Data restored"

  # Start Redis
  info "Starting Redis..."
  if systemctl is-active redis &>/dev/null 2>&1 || systemctl list-unit-files redis.service &>/dev/null 2>&1; then
    sudo systemctl start redis
    info "  ✓ Redis started (systemd)"
  elif systemctl list-unit-files redis-server.service &>/dev/null 2>&1; then
    sudo systemctl start redis-server
    info "  ✓ Redis started (systemd: redis-server)"
  else
    redis-server "$REDIS_CONF" --daemonize yes
    info "  ✓ Redis started (manual)"
  fi

  sleep 2
  if redis-cli -p "$REDIS_PORT" PING 2>/dev/null | grep -q "PONG"; then
    info "✓ Rollback complete — Redis is responding"
  else
    error "Redis not responding after rollback. Check logs."
    exit 1
  fi
}

# --- Main dispatch ---
case "$COMMAND" in
  check)    cmd_check ;;
  prepare)  cmd_prepare ;;
  swap)     cmd_swap ;;
  verify)   cmd_verify ;;
  rollback) cmd_rollback ;;
  *)
    error "Unknown command: $COMMAND"
    echo "Valid commands: check, prepare, swap, verify, rollback"
    exit 1
    ;;
esac
