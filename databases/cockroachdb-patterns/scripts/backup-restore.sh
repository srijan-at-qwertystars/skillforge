#!/usr/bin/env bash
#
# backup-restore.sh
# Perform full/incremental backups and restore for CockroachDB.
# Uses BACKUP/RESTORE SQL statements via cockroach sql CLI.
#
# Usage:
#   ./backup-restore.sh full-backup    <destination>  [--database DB]
#   ./backup-restore.sh inc-backup     <destination>  [--database DB]
#   ./backup-restore.sh restore        <source>       [--database DB]
#   ./backup-restore.sh restore-table  <source>       --table TABLE [--database DB]
#   ./backup-restore.sh schedule       <destination>  [--database DB] [--frequency CRON]
#   ./backup-restore.sh show-backups   <location>
#   ./backup-restore.sh show-schedules
#
# Options:
#   --host HOST          CockroachDB host (default: localhost)
#   --port PORT          CockroachDB port (default: 26257)
#   --insecure           Use insecure connection
#   --database DB        Database name (omit for full cluster backup)
#   --table TABLE        Table name for single-table restore
#   --as-of TIMESTAMP    Point-in-time for backup/restore
#   --frequency CRON     Schedule frequency (default: '@daily')
#
# Examples:
#   ./backup-restore.sh full-backup 'nodelocal://1/backups' --insecure
#   ./backup-restore.sh full-backup 's3://my-bucket/backups?AUTH=implicit' --database mydb --insecure
#   ./backup-restore.sh inc-backup 's3://my-bucket/backups?AUTH=implicit' --insecure
#   ./backup-restore.sh restore 's3://my-bucket/backups?AUTH=implicit' --insecure
#   ./backup-restore.sh restore-table 's3://my-bucket/backups?AUTH=implicit' --table orders --insecure
#   ./backup-restore.sh schedule 'gs://bucket/backups?AUTH=implicit' --frequency '@hourly' --insecure

set -euo pipefail

HOST="localhost"
PORT="26257"
INSECURE_FLAG=""
CERTS_DIR=""
DATABASE=""
TABLE=""
AS_OF=""
FREQUENCY="@daily"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    head -30 "$0" | grep '^#' | sed 's/^# \?//'
    exit 1
}

ACTION="${1:-}"
DESTINATION="${2:-}"

if [[ -z "${ACTION}" ]]; then
    usage
fi

shift 2 2>/dev/null || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       HOST="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --insecure)   INSECURE_FLAG="--insecure"; shift ;;
        --certs-dir)  CERTS_DIR="--certs-dir=$2"; shift 2 ;;
        --database)   DATABASE="$2"; shift 2 ;;
        --table)      TABLE="$2"; shift 2 ;;
        --as-of)      AS_OF="$2"; shift 2 ;;
        --frequency)  FREQUENCY="$2"; shift 2 ;;
        *)            log_error "Unknown option: $1"; usage ;;
    esac
done

CONN_FLAGS="${INSECURE_FLAG} ${CERTS_DIR} --host=${HOST}:${PORT}"

run_sql() {
    log_info "Executing: $1"
    cockroach sql ${CONN_FLAGS} -e "$1"
}

do_full_backup() {
    if [[ -z "${DESTINATION}" ]]; then
        log_error "Destination required for backup."
        usage
    fi

    local as_of_clause=""
    if [[ -n "${AS_OF}" ]]; then
        as_of_clause="AS OF SYSTEM TIME '${AS_OF}'"
    else
        as_of_clause="AS OF SYSTEM TIME '-10s'"
    fi

    if [[ -n "${DATABASE}" ]]; then
        log_info "Full backup of database '${DATABASE}' to ${DESTINATION}"
        run_sql "BACKUP DATABASE ${DATABASE} INTO '${DESTINATION}' ${as_of_clause};"
    else
        log_info "Full cluster backup to ${DESTINATION}"
        run_sql "BACKUP INTO '${DESTINATION}' ${as_of_clause};"
    fi

    log_info "Full backup completed successfully."
}

do_inc_backup() {
    if [[ -z "${DESTINATION}" ]]; then
        log_error "Destination required for incremental backup."
        usage
    fi

    local as_of_clause=""
    if [[ -n "${AS_OF}" ]]; then
        as_of_clause="AS OF SYSTEM TIME '${AS_OF}'"
    fi

    if [[ -n "${DATABASE}" ]]; then
        log_info "Incremental backup of database '${DATABASE}' to ${DESTINATION}"
        run_sql "BACKUP DATABASE ${DATABASE} INTO LATEST IN '${DESTINATION}' ${as_of_clause};"
    else
        log_info "Incremental cluster backup to ${DESTINATION}"
        run_sql "BACKUP INTO LATEST IN '${DESTINATION}' ${as_of_clause};"
    fi

    log_info "Incremental backup completed successfully."
}

do_restore() {
    if [[ -z "${DESTINATION}" ]]; then
        log_error "Source location required for restore."
        usage
    fi

    local as_of_clause=""
    if [[ -n "${AS_OF}" ]]; then
        as_of_clause="AS OF SYSTEM TIME '${AS_OF}'"
    fi

    if [[ -n "${DATABASE}" ]]; then
        log_info "Restoring database '${DATABASE}' from ${DESTINATION}"
        run_sql "RESTORE DATABASE ${DATABASE} FROM LATEST IN '${DESTINATION}' ${as_of_clause};"
    else
        log_info "Full cluster restore from ${DESTINATION}"
        run_sql "RESTORE FROM LATEST IN '${DESTINATION}' ${as_of_clause};"
    fi

    log_info "Restore completed successfully."
}

do_restore_table() {
    if [[ -z "${DESTINATION}" ]]; then
        log_error "Source location required for restore."
        usage
    fi
    if [[ -z "${TABLE}" ]]; then
        log_error "Table name required (--table)."
        usage
    fi

    local as_of_clause=""
    if [[ -n "${AS_OF}" ]]; then
        as_of_clause="AS OF SYSTEM TIME '${AS_OF}'"
    fi

    local full_table="${TABLE}"
    if [[ -n "${DATABASE}" ]]; then
        full_table="${DATABASE}.public.${TABLE}"
    fi

    log_info "Restoring table '${full_table}' from ${DESTINATION}"
    run_sql "RESTORE TABLE ${full_table} FROM LATEST IN '${DESTINATION}' ${as_of_clause};"

    log_info "Table restore completed successfully."
}

do_schedule() {
    if [[ -z "${DESTINATION}" ]]; then
        log_error "Destination required for scheduled backup."
        usage
    fi

    local schedule_name="backup_schedule_$(date +%Y%m%d_%H%M%S)"

    if [[ -n "${DATABASE}" ]]; then
        log_info "Creating scheduled backup for database '${DATABASE}'"
        run_sql "
            CREATE SCHEDULE ${schedule_name}
            FOR BACKUP DATABASE ${DATABASE} INTO '${DESTINATION}'
            RECURRING '${FREQUENCY}'
            FULL BACKUP ALWAYS
            WITH SCHEDULE OPTIONS first_run = 'now';
        "
    else
        log_info "Creating scheduled full cluster backup"
        run_sql "
            CREATE SCHEDULE ${schedule_name}
            FOR BACKUP INTO '${DESTINATION}'
            RECURRING '${FREQUENCY}'
            FULL BACKUP ALWAYS
            WITH SCHEDULE OPTIONS first_run = 'now';
        "
    fi

    log_info "Backup schedule '${schedule_name}' created."
}

do_show_backups() {
    if [[ -z "${DESTINATION}" ]]; then
        log_error "Backup location required."
        usage
    fi

    log_info "Listing backups in ${DESTINATION}"
    run_sql "SHOW BACKUPS IN '${DESTINATION}';"
}

do_show_schedules() {
    log_info "Listing backup schedules"
    run_sql "SHOW SCHEDULES;"
}

main() {
    echo "============================================"
    echo " CockroachDB Backup & Restore"
    echo "============================================"

    case "${ACTION}" in
        full-backup)     do_full_backup ;;
        inc-backup)      do_inc_backup ;;
        restore)         do_restore ;;
        restore-table)   do_restore_table ;;
        schedule)        do_schedule ;;
        show-backups)    do_show_backups ;;
        show-schedules)  do_show_schedules ;;
        *)
            log_error "Unknown action: ${ACTION}"
            usage
            ;;
    esac
}

main
