#!/usr/bin/env bash
# =============================================================================
# purge-and-inspect.sh — Common celery inspect/control commands
#
# Usage:
#   ./purge-and-inspect.sh <command> [options]
#
# Commands:
#   status          — Show worker status (ping all workers)
#   active          — List currently executing tasks
#   reserved        — List prefetched (reserved) tasks
#   scheduled       — List ETA-scheduled tasks
#   registered      — List registered task names
#   stats           — Show worker statistics
#   queues          — Show active queue bindings
#   report          — Full worker report
#   purge           — Purge all messages from all queues (DESTRUCTIVE)
#   purge-queue     — Purge a specific queue (DESTRUCTIVE)
#   revoke          — Revoke a task by ID
#   revoke-kill     — Revoke and terminate a running task
#   rate-limit      — Set rate limit for a task
#   shutdown        — Gracefully shut down all workers
#
# Environment:
#   CELERY_APP      — Celery app name (default: myproject)
#   CELERY_BROKER   — Broker URL (optional, uses app config if not set)
#
# Examples:
#   ./purge-and-inspect.sh status
#   ./purge-and-inspect.sh active
#   CELERY_APP=myapp ./purge-and-inspect.sh purge
#   ./purge-and-inspect.sh revoke abc123-task-id
#   ./purge-and-inspect.sh rate-limit myapp.tasks.send_email 10/m
# =============================================================================
set -euo pipefail

APP="${CELERY_APP:-myproject}"
CMD="${1:-help}"

celery_cmd() {
    celery -A "$APP" "$@"
}

case "$CMD" in
    status)
        echo "=== Worker Status ==="
        celery_cmd status
        ;;

    active)
        echo "=== Active Tasks ==="
        celery_cmd inspect active
        ;;

    reserved)
        echo "=== Reserved (Prefetched) Tasks ==="
        celery_cmd inspect reserved
        ;;

    scheduled)
        echo "=== Scheduled Tasks ==="
        celery_cmd inspect scheduled
        ;;

    registered)
        echo "=== Registered Tasks ==="
        celery_cmd inspect registered
        ;;

    stats)
        echo "=== Worker Statistics ==="
        celery_cmd inspect stats
        ;;

    queues)
        echo "=== Active Queues ==="
        celery_cmd inspect active_queues
        ;;

    report)
        echo "=== Full Worker Report ==="
        celery_cmd inspect report
        ;;

    purge)
        echo "WARNING: This will purge ALL messages from ALL queues."
        read -rp "Are you sure? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            celery_cmd purge -f
            echo "All queues purged."
        else
            echo "Aborted."
        fi
        ;;

    purge-queue)
        QUEUE="${2:-}"
        if [[ -z "$QUEUE" ]]; then
            echo "Usage: $0 purge-queue <queue_name>"
            exit 1
        fi
        echo "WARNING: This will purge all messages from queue '$QUEUE'."
        read -rp "Are you sure? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            celery_cmd amqp queue.purge "$QUEUE"
            echo "Queue '$QUEUE' purged."
        else
            echo "Aborted."
        fi
        ;;

    revoke)
        TASK_ID="${2:-}"
        if [[ -z "$TASK_ID" ]]; then
            echo "Usage: $0 revoke <task_id>"
            exit 1
        fi
        celery_cmd control revoke "$TASK_ID"
        echo "Task $TASK_ID revoked."
        ;;

    revoke-kill)
        TASK_ID="${2:-}"
        if [[ -z "$TASK_ID" ]]; then
            echo "Usage: $0 revoke-kill <task_id>"
            exit 1
        fi
        echo "WARNING: This will terminate the running task $TASK_ID."
        read -rp "Are you sure? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            celery_cmd control revoke "$TASK_ID" --terminate --signal=SIGTERM
            echo "Task $TASK_ID revoked and terminated."
        else
            echo "Aborted."
        fi
        ;;

    rate-limit)
        TASK_NAME="${2:-}"
        RATE="${3:-}"
        if [[ -z "$TASK_NAME" || -z "$RATE" ]]; then
            echo "Usage: $0 rate-limit <task_name> <rate>"
            echo "  Rate format: '10/s', '100/m', '1000/h'"
            exit 1
        fi
        celery_cmd control rate_limit "$TASK_NAME" "$RATE"
        echo "Rate limit for $TASK_NAME set to $RATE."
        ;;

    shutdown)
        echo "WARNING: This will gracefully shut down ALL workers."
        read -rp "Are you sure? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            celery_cmd control shutdown
            echo "Shutdown signal sent to all workers."
        else
            echo "Aborted."
        fi
        ;;

    help|--help|-h)
        head -30 "$0" | grep -E "^#" | sed 's/^# \?//'
        ;;

    *)
        echo "Unknown command: $CMD"
        echo "Run '$0 help' for usage."
        exit 1
        ;;
esac
