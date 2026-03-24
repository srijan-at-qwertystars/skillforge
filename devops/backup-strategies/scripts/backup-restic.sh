#!/bin/bash
# =============================================================================
# backup-restic.sh — Complete restic backup with init, backup, prune, check, notify
# =============================================================================
#
# Usage:
#   ./backup-restic.sh [init|backup|prune|check|full]
#
#   init    — Initialize a new restic repository
#   backup  — Run backup with configured paths and exclusions
#   prune   — Apply retention policy and reclaim space
#   check   — Verify repository integrity
#   full    — Run backup + prune + check (default)
#
# Configuration:
#   Set environment variables directly or via /etc/restic-env.sh:
#     RESTIC_REPOSITORY   — Repository URL (s3:, sftp:, rest:, or local path)
#     RESTIC_PASSWORD      — Repository password (or use RESTIC_PASSWORD_FILE)
#     AWS_ACCESS_KEY_ID    — For S3 backends
#     AWS_SECRET_ACCESS_KEY — For S3 backends
#     BACKUP_PATHS         — Space-separated paths to back up (default: /etc /home /var/lib)
#     BACKUP_EXCLUDES      — Comma-separated exclude patterns
#     BACKUP_TAGS          — Comma-separated tags for snapshots
#     SLACK_WEBHOOK_URL    — Slack webhook for notifications (optional)
#     HEALTHCHECK_URL      — Healthchecks.io ping URL (optional)
#
# Examples:
#   RESTIC_REPOSITORY=s3:s3.amazonaws.com/my-backups ./backup-restic.sh init
#   ./backup-restic.sh backup
#   ./backup-restic.sh full
#
# =============================================================================
set -euo pipefail

# Load environment file if it exists
[[ -f /etc/restic-env.sh ]] && source /etc/restic-env.sh

# Configuration with defaults
REPO="${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set}"
BACKUP_PATHS="${BACKUP_PATHS:-/etc /home /var/lib}"
BACKUP_EXCLUDES="${BACKUP_EXCLUDES:-*.cache,*.tmp,.cache,node_modules,__pycache__,.venv,.git}"
BACKUP_TAGS="${BACKUP_TAGS:-$(hostname -s)}"
LOG_DIR="${LOG_DIR:-/var/log/restic}"
LOG_FILE="${LOG_DIR}/backup-$(date +%F).log"
LOCK_FILE="/var/run/restic-backup.lock"

# Retention policy (GFS scheme)
KEEP_HOURLY="${KEEP_HOURLY:-24}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEEP_YEARLY="${KEEP_YEARLY:-3}"

# Notifications
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

# ---- Functions ----

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -Is)] $*" | tee -a "$LOG_FILE"
}

notify_slack() {
    local emoji="$1" msg="$2"
    if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
        curl -sf -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "{\"text\":\"${emoji} [$(hostname -s)] ${msg}\"}" \
            >/dev/null 2>&1 || true
    fi
}

notify_healthcheck() {
    local status="${1:-}"  # empty for success, "/fail" for failure
    if [[ -n "$HEALTHCHECK_URL" ]]; then
        curl -sf -m 10 "${HEALTHCHECK_URL}${status}" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR: Backup failed with exit code $exit_code"
        notify_slack "🚨" "Backup FAILED (exit code: $exit_code)"
        notify_healthcheck "/fail"
    fi
}
trap cleanup EXIT

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log "ERROR: Another backup is running (PID: $lock_pid)"
            exit 1
        fi
        log "WARN: Removing stale lock file"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

build_exclude_args() {
    local args=""
    IFS=',' read -ra EXCL <<< "$BACKUP_EXCLUDES"
    for pattern in "${EXCL[@]}"; do
        args="$args --exclude=${pattern}"
    done
    echo "$args"
}

build_tag_args() {
    local args=""
    IFS=',' read -ra TAGS <<< "$BACKUP_TAGS"
    for tag in "${TAGS[@]}"; do
        args="$args --tag=${tag}"
    done
    echo "$args"
}

# ---- Commands ----

cmd_init() {
    log "Initializing restic repository: $REPO"
    if restic -r "$REPO" cat config >/dev/null 2>&1; then
        log "Repository already initialized"
        return 0
    fi
    restic -r "$REPO" init 2>&1 | tee -a "$LOG_FILE"
    log "Repository initialized successfully"
}

cmd_backup() {
    acquire_lock
    log "Starting backup to: $REPO"
    log "Paths: $BACKUP_PATHS"

    notify_healthcheck "/start"

    local exclude_args tag_args
    exclude_args=$(build_exclude_args)
    tag_args=$(build_tag_args)

    local start_time
    start_time=$(date +%s)

    # shellcheck disable=SC2086
    restic -r "$REPO" backup \
        $BACKUP_PATHS \
        $exclude_args \
        $tag_args \
        --exclude-caches \
        --one-file-system \
        --verbose 2>&1 | tee -a "$LOG_FILE"

    local duration=$(( $(date +%s) - start_time ))
    log "Backup completed in ${duration}s"
    notify_slack "✅" "Backup completed in ${duration}s"
}

cmd_prune() {
    log "Applying retention policy"
    log "Keep: ${KEEP_HOURLY}h ${KEEP_DAILY}d ${KEEP_WEEKLY}w ${KEEP_MONTHLY}m ${KEEP_YEARLY}y"

    restic -r "$REPO" forget \
        --keep-hourly "$KEEP_HOURLY" \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" \
        --keep-yearly "$KEEP_YEARLY" \
        --prune \
        --verbose 2>&1 | tee -a "$LOG_FILE"

    log "Retention policy applied"
}

cmd_check() {
    log "Verifying repository integrity"

    # Use --read-data-subset to check ~5% of packs (fast daily check)
    # Full --read-data check should be run weekly
    local check_mode="--read-data-subset=5%"
    if [[ "$(date +%u)" -eq 7 ]]; then
        check_mode="--read-data"
        log "Sunday: running full data verification"
    fi

    restic -r "$REPO" check $check_mode 2>&1 | tee -a "$LOG_FILE"
    log "Integrity check passed"
}

cmd_full() {
    cmd_backup
    cmd_prune
    cmd_check
    notify_healthcheck ""  # success ping
    log "Full backup cycle completed successfully"
}

# ---- Main ----

ACTION="${1:-full}"

case "$ACTION" in
    init)   cmd_init ;;
    backup) cmd_backup ;;
    prune)  cmd_prune ;;
    check)  cmd_check ;;
    full)   cmd_full ;;
    *)
        echo "Usage: $0 [init|backup|prune|check|full]"
        exit 1
        ;;
esac
