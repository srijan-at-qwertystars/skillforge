#!/usr/bin/env bash
# cron-wrapper.sh — Generic cron job wrapper with logging, locking, and notifications
#
# Usage:
#   cron-wrapper.sh [OPTIONS] -- COMMAND [ARGS...]
#
# Options:
#   -n, --name NAME         Job name (used in logs and lock file; default: command basename)
#   -l, --logdir DIR        Log directory (default: /var/log/cron-jobs)
#   -L, --lockdir DIR       Lock file directory (default: /tmp)
#   --no-lock               Disable lock file (allow concurrent runs)
#   --lock-wait SECONDS     Wait for lock instead of skipping (0 = skip immediately)
#   --notify-cmd CMD        Command to run on failure (receives job name and exit code as args)
#   --healthcheck-url URL   Ping URL on success (healthchecks.io, cronitor, etc.)
#   --timeout SECONDS       Kill job after N seconds (0 = no timeout)
#   --max-log-size MB       Rotate log when it exceeds this size (default: 50)
#   --quiet                 Suppress wrapper output (only log job output)
#   -h, --help              Show this help
#
# Examples:
#   # Basic: wrap a backup script with logging and locking
#   cron-wrapper.sh -n daily-backup -- /usr/local/bin/backup.sh
#
#   # With healthcheck ping and failure notification
#   cron-wrapper.sh -n db-sync \
#     --healthcheck-url https://hc-ping.com/YOUR-UUID \
#     --notify-cmd "/usr/local/bin/slack-alert.sh" \
#     -- /app/sync.sh
#
#   # In crontab:
#   0 2 * * * /usr/local/bin/cron-wrapper.sh -n nightly-backup -- /app/backup.sh
#   */5 * * * * /usr/local/bin/cron-wrapper.sh -n health-check --timeout 60 -- /app/check.sh

set -uo pipefail

# --- Defaults ---
JOB_NAME=""
LOG_DIR="/var/log/cron-jobs"
LOCK_DIR="/tmp"
USE_LOCK=true
LOCK_WAIT=0
NOTIFY_CMD=""
HEALTHCHECK_URL=""
TIMEOUT=0
MAX_LOG_SIZE_MB=50
QUIET=false

# --- Parse arguments ---
COMMAND=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)       JOB_NAME="$2"; shift 2 ;;
        -l|--logdir)     LOG_DIR="$2"; shift 2 ;;
        -L|--lockdir)    LOCK_DIR="$2"; shift 2 ;;
        --no-lock)       USE_LOCK=false; shift ;;
        --lock-wait)     LOCK_WAIT="$2"; shift 2 ;;
        --notify-cmd)    NOTIFY_CMD="$2"; shift 2 ;;
        --healthcheck-url) HEALTHCHECK_URL="$2"; shift 2 ;;
        --timeout)       TIMEOUT="$2"; shift 2 ;;
        --max-log-size)  MAX_LOG_SIZE_MB="$2"; shift 2 ;;
        --quiet)         QUIET=true; shift ;;
        -h|--help)
            sed -n '2,/^$/s/^# \?//p' "$0"
            exit 0
            ;;
        --)              shift; COMMAND=("$@"); break ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ ${#COMMAND[@]} -eq 0 ]]; then
    echo "Error: No command specified. Use -- before the command." >&2
    echo "Usage: cron-wrapper.sh [OPTIONS] -- COMMAND [ARGS...]" >&2
    exit 1
fi

# --- Setup ---
if [[ -z "$JOB_NAME" ]]; then
    JOB_NAME=$(basename "${COMMAND[0]}" | sed 's/\.[^.]*$//')
fi

SAFE_NAME=$(echo "$JOB_NAME" | tr -cs 'a-zA-Z0-9_-' '_')
LOG_FILE="$LOG_DIR/${SAFE_NAME}.log"
LOCK_FILE="$LOCK_DIR/cron-${SAFE_NAME}.lock"
START_TIME=$(date +%s)
START_DATE=$(date '+%Y-%m-%d %H:%M:%S %Z')

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$SAFE_NAME] $1"
    echo "$msg" >> "$LOG_FILE"
    if [[ "$QUIET" != "true" ]]; then
        echo "$msg"
    fi
}

# Create log directory
mkdir -p "$LOG_DIR" 2>/dev/null || {
    echo "Error: Cannot create log directory: $LOG_DIR" >&2
    exit 1
}

# --- Log rotation ---
if [[ -f "$LOG_FILE" ]]; then
    log_size_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    max_size_bytes=$((MAX_LOG_SIZE_MB * 1024 * 1024))
    if (( log_size_bytes > max_size_bytes )); then
        mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
        log "Log rotated (previous log exceeded ${MAX_LOG_SIZE_MB}MB)"
    fi
fi

log "=== Job started ==="
log "Command: ${COMMAND[*]}"
log "PID: $$"

# --- Lock file ---
if [[ "$USE_LOCK" == "true" ]]; then
    LOCK_FD=200
    eval "exec $LOCK_FD>\"$LOCK_FILE\""

    if (( LOCK_WAIT > 0 )); then
        if ! flock -w "$LOCK_WAIT" $LOCK_FD 2>/dev/null; then
            log "SKIPPED: Could not acquire lock within ${LOCK_WAIT}s (another instance running)"
            exit 0
        fi
    else
        if ! flock -n $LOCK_FD 2>/dev/null; then
            log "SKIPPED: Another instance is already running (lock held: $LOCK_FILE)"
            exit 0
        fi
    fi
    log "Lock acquired: $LOCK_FILE"
fi

# --- Ping healthcheck start (if URL supports /start) ---
if [[ -n "$HEALTHCHECK_URL" ]]; then
    curl -fsS -m 10 "${HEALTHCHECK_URL}/start" > /dev/null 2>&1 || true
fi

# --- Execute command ---
EXIT_CODE=0

if (( TIMEOUT > 0 )); then
    log "Timeout: ${TIMEOUT}s"
    timeout "$TIMEOUT" "${COMMAND[@]}" >> "$LOG_FILE" 2>&1
    EXIT_CODE=$?
    if (( EXIT_CODE == 124 )); then
        log "ERROR: Job timed out after ${TIMEOUT}s"
    fi
else
    "${COMMAND[@]}" >> "$LOG_FILE" 2>&1
    EXIT_CODE=$?
fi

# --- Calculate duration ---
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
if (( DURATION >= 3600 )); then
    DURATION_FMT="$((DURATION / 3600))h $((DURATION % 3600 / 60))m $((DURATION % 60))s"
elif (( DURATION >= 60 )); then
    DURATION_FMT="$((DURATION / 60))m $((DURATION % 60))s"
else
    DURATION_FMT="${DURATION}s"
fi

# --- Handle result ---
if (( EXIT_CODE == 0 )); then
    log "=== Job succeeded (duration: $DURATION_FMT) ==="

    # Ping healthcheck success
    if [[ -n "$HEALTHCHECK_URL" ]]; then
        curl -fsS -m 10 "$HEALTHCHECK_URL" > /dev/null 2>&1 || true
    fi
else
    log "=== Job FAILED (exit code: $EXIT_CODE, duration: $DURATION_FMT) ==="

    # Ping healthcheck failure
    if [[ -n "$HEALTHCHECK_URL" ]]; then
        curl -fsS -m 10 "${HEALTHCHECK_URL}/fail" > /dev/null 2>&1 || true
    fi

    # Run notification command
    if [[ -n "$NOTIFY_CMD" ]]; then
        log "Running notification: $NOTIFY_CMD"
        $NOTIFY_CMD "$JOB_NAME" "$EXIT_CODE" "$DURATION_FMT" "$LOG_FILE" 2>&1 | head -5 >> "$LOG_FILE" || true
    fi
fi

exit $EXIT_CODE
