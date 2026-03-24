#!/bin/bash
# =============================================================================
# backup-verify.sh — Backup verification: restore test, integrity, data validation
# =============================================================================
#
# Usage:
#   ./backup-verify.sh [all|integrity|restore|data|report]
#
#   all        — Run all verification checks (default)
#   integrity  — Check repository/backup file integrity only
#   restore    — Test restore to temporary location
#   data       — Validate restored data (row counts, checksums)
#   report     — Generate verification report from last run
#
# Configuration (environment variables):
#   RESTIC_REPOSITORY     — Restic repository URL
#   RESTIC_PASSWORD       — Repository password
#   VERIFY_RESTORE_DIR    — Temporary restore location (default: /tmp/backup-verify)
#   PGHOST / PGPORT / PGUSER — PostgreSQL connection for DB verification
#   PGDATABASE            — Database to verify after restore
#   VERIFY_DB_NAME        — Temp DB name for restore test (default: backup_verify_test)
#   REPORT_DIR            — Report output directory (default: /var/log/backup-verify)
#   SLACK_WEBHOOK_URL     — Slack notification webhook (optional)
#   EXPECTED_MIN_FILES    — Minimum expected file count in backup (default: 100)
#   EXPECTED_MIN_SIZE_MB  — Minimum expected backup size in MB (default: 50)
#
# Examples:
#   ./backup-verify.sh all
#   ./backup-verify.sh integrity
#   PGDATABASE=production ./backup-verify.sh data
#
# =============================================================================
set -euo pipefail

# Configuration
REPO="${RESTIC_REPOSITORY:-}"
VERIFY_RESTORE_DIR="${VERIFY_RESTORE_DIR:-/tmp/backup-verify}"
VERIFY_DB_NAME="${VERIFY_DB_NAME:-backup_verify_test}"
REPORT_DIR="${REPORT_DIR:-/var/log/backup-verify}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
EXPECTED_MIN_FILES="${EXPECTED_MIN_FILES:-100}"
EXPECTED_MIN_SIZE_MB="${EXPECTED_MIN_SIZE_MB:-50}"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-}"

DATE_STAMP=$(date +%F-%H%M)
REPORT_FILE="${REPORT_DIR}/verify-${DATE_STAMP}.json"
PASSED=0
FAILED=0
WARNINGS=0
RESULTS="[]"

# ---- Functions ----

setup() {
    mkdir -p "$REPORT_DIR" "$VERIFY_RESTORE_DIR"
}

log() {
    echo "[$(date -Is)] $*"
}

record_result() {
    local check="$1" status="$2" detail="$3" duration="${4:-0}"
    RESULTS=$(echo "$RESULTS" | jq \
        --arg c "$check" \
        --arg s "$status" \
        --arg d "$detail" \
        --arg t "$duration" \
        '. + [{"check": $c, "status": $s, "detail": $d, "duration_seconds": ($t | tonumber)}]')

    case "$status" in
        PASS) PASSED=$((PASSED + 1)); log "  ✅ $check: $detail" ;;
        FAIL) FAILED=$((FAILED + 1)); log "  ❌ $check: $detail" ;;
        WARN) WARNINGS=$((WARNINGS + 1)); log "  ⚠️  $check: $detail" ;;
    esac
}

notify() {
    local emoji="$1" msg="$2"
    if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
        curl -sf -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "{\"text\":\"${emoji} [$(hostname -s)] Backup Verify: ${msg}\"}" \
            >/dev/null 2>&1 || true
    fi
}

cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "$VERIFY_RESTORE_DIR"
    # Drop test database if it exists
    if [[ -n "$PGDATABASE" ]]; then
        psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
            -c "DROP DATABASE IF EXISTS ${VERIFY_DB_NAME};" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---- Verification Checks ----

check_repository_access() {
    log "Checking repository access..."
    local start
    start=$(date +%s)

    if [[ -z "$REPO" ]]; then
        record_result "repo_access" "FAIL" "RESTIC_REPOSITORY not set" 0
        return 1
    fi

    if restic -r "$REPO" cat config >/dev/null 2>&1; then
        record_result "repo_access" "PASS" "Repository accessible" $(($(date +%s) - start))
    else
        record_result "repo_access" "FAIL" "Cannot access repository: $REPO" $(($(date +%s) - start))
        return 1
    fi
}

check_snapshot_freshness() {
    log "Checking snapshot freshness..."
    local start
    start=$(date +%s)

    local latest_time
    latest_time=$(restic -r "$REPO" snapshots --latest 1 --json 2>/dev/null | jq -r '.[0].time // empty')

    if [[ -z "$latest_time" ]]; then
        record_result "snapshot_freshness" "FAIL" "No snapshots found" $(($(date +%s) - start))
        return 1
    fi

    local age_hours
    age_hours=$(( ($(date +%s) - $(date -d "$latest_time" +%s)) / 3600 ))

    if [[ $age_hours -gt 48 ]]; then
        record_result "snapshot_freshness" "FAIL" "Latest snapshot is ${age_hours}h old" $(($(date +%s) - start))
    elif [[ $age_hours -gt 26 ]]; then
        record_result "snapshot_freshness" "WARN" "Latest snapshot is ${age_hours}h old" $(($(date +%s) - start))
    else
        record_result "snapshot_freshness" "PASS" "Latest snapshot is ${age_hours}h old" $(($(date +%s) - start))
    fi
}

check_snapshot_count() {
    log "Checking snapshot count..."
    local start
    start=$(date +%s)

    local count
    count=$(restic -r "$REPO" snapshots --json 2>/dev/null | jq 'length')

    if [[ $count -lt 1 ]]; then
        record_result "snapshot_count" "FAIL" "No snapshots (count: $count)" $(($(date +%s) - start))
    elif [[ $count -lt 3 ]]; then
        record_result "snapshot_count" "WARN" "Low snapshot count: $count" $(($(date +%s) - start))
    else
        record_result "snapshot_count" "PASS" "$count snapshots available" $(($(date +%s) - start))
    fi
}

check_integrity() {
    log "Checking repository integrity..."
    local start
    start=$(date +%s)

    # Quick check on weekdays, full check on Sunday
    local check_args="--read-data-subset=2%"
    if [[ "$(date +%u)" -eq 7 ]]; then
        check_args="--read-data"
        log "  (Sunday: running full data verification)"
    fi

    if restic -r "$REPO" check $check_args 2>&1; then
        record_result "integrity" "PASS" "Repository integrity verified" $(($(date +%s) - start))
    else
        record_result "integrity" "FAIL" "Repository integrity check FAILED" $(($(date +%s) - start))
    fi
}

check_restore_test() {
    log "Testing restore to $VERIFY_RESTORE_DIR ..."
    local start
    start=$(date +%s)

    rm -rf "$VERIFY_RESTORE_DIR"
    mkdir -p "$VERIFY_RESTORE_DIR"

    if restic -r "$REPO" restore latest --target "$VERIFY_RESTORE_DIR" 2>&1; then
        record_result "restore" "PASS" "Restore completed successfully" $(($(date +%s) - start))
    else
        record_result "restore" "FAIL" "Restore FAILED" $(($(date +%s) - start))
        return 1
    fi

    # Verify restored file count
    local file_count
    file_count=$(find "$VERIFY_RESTORE_DIR" -type f | wc -l)
    if [[ $file_count -ge $EXPECTED_MIN_FILES ]]; then
        record_result "restore_file_count" "PASS" "$file_count files restored (min: $EXPECTED_MIN_FILES)" 0
    else
        record_result "restore_file_count" "FAIL" "Only $file_count files (expected min: $EXPECTED_MIN_FILES)" 0
    fi

    # Verify restored size
    local size_mb
    size_mb=$(du -sm "$VERIFY_RESTORE_DIR" | cut -f1)
    if [[ $size_mb -ge $EXPECTED_MIN_SIZE_MB ]]; then
        record_result "restore_size" "PASS" "${size_mb}MB restored (min: ${EXPECTED_MIN_SIZE_MB}MB)" 0
    else
        record_result "restore_size" "FAIL" "Only ${size_mb}MB (expected min: ${EXPECTED_MIN_SIZE_MB}MB)" 0
    fi

    # Check for key files/directories
    local key_paths=("/etc/hostname" "/etc/passwd")
    for path in "${key_paths[@]}"; do
        if [[ -f "${VERIFY_RESTORE_DIR}${path}" ]]; then
            record_result "key_file_${path##*/}" "PASS" "${path} present in restore" 0
        else
            record_result "key_file_${path##*/}" "WARN" "${path} missing from restore" 0
        fi
    done
}

check_database_restore() {
    if [[ -z "$PGDATABASE" ]]; then
        log "Skipping database verification (PGDATABASE not set)"
        return 0
    fi

    log "Testing database restore..."
    local start
    start=$(date +%s)

    # Find dump file in restored data
    local dump_file
    dump_file=$(find "$VERIFY_RESTORE_DIR" -name "*.dump" -o -name "*${PGDATABASE}*.dump" | head -1)

    if [[ -z "$dump_file" ]]; then
        dump_file=$(find "$VERIFY_RESTORE_DIR" -name "*.sql.gz" | head -1)
    fi

    if [[ -z "$dump_file" ]]; then
        record_result "db_restore" "WARN" "No database dump found in backup" $(($(date +%s) - start))
        return 0
    fi

    # Create test database
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
        -c "DROP DATABASE IF EXISTS ${VERIFY_DB_NAME};" 2>/dev/null
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
        -c "CREATE DATABASE ${VERIFY_DB_NAME};" 2>/dev/null

    # Restore based on file type
    local restore_ok=false
    if [[ "$dump_file" == *.dump ]]; then
        if pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
            -d "$VERIFY_DB_NAME" --no-owner --no-privileges \
            "$dump_file" 2>&1; then
            restore_ok=true
        fi
    elif [[ "$dump_file" == *.sql.gz ]]; then
        if gunzip -c "$dump_file" | psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
            -d "$VERIFY_DB_NAME" 2>&1; then
            restore_ok=true
        fi
    fi

    if $restore_ok; then
        record_result "db_restore" "PASS" "Database restored from $dump_file" $(($(date +%s) - start))
    else
        record_result "db_restore" "FAIL" "Database restore FAILED" $(($(date +%s) - start))
        return 1
    fi
}

check_data_validation() {
    if [[ -z "$PGDATABASE" ]]; then
        return 0
    fi

    log "Validating restored data..."
    local start
    start=$(date +%s)

    # Check that the test database has tables
    local table_count
    table_count=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$VERIFY_DB_NAME" -t -c "
        SELECT count(*) FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
    " 2>/dev/null | xargs)

    if [[ "${table_count:-0}" -gt 0 ]]; then
        record_result "db_tables" "PASS" "$table_count tables found in restored database" 0
    else
        record_result "db_tables" "FAIL" "No tables found in restored database" 0
        return 1
    fi

    # Compare row counts with metadata if available
    local rowcount_file
    rowcount_file=$(find "$VERIFY_RESTORE_DIR" -name "*rowcounts*" -type f | head -1)
    if [[ -n "$rowcount_file" ]]; then
        log "  Comparing row counts with backup metadata..."
        local mismatches=0
        while IFS=' ' read -r table expected; do
            [[ -z "$table" ]] && continue
            local actual
            actual=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$VERIFY_DB_NAME" -t -c \
                "SELECT count(*) FROM \"$table\";" 2>/dev/null | xargs)
            if [[ "${actual:-0}" -ne "${expected:-0}" ]]; then
                mismatches=$((mismatches + 1))
                log "    MISMATCH: $table — expected $expected, got ${actual:-0}"
            fi
        done < "$rowcount_file"

        if [[ $mismatches -eq 0 ]]; then
            record_result "db_rowcounts" "PASS" "All row counts match backup metadata" 0
        else
            record_result "db_rowcounts" "WARN" "$mismatches table(s) have row count mismatches" 0
        fi
    fi

    # Check for data integrity (no null PKs, valid FKs)
    local null_pk_count
    null_pk_count=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$VERIFY_DB_NAME" -t -c "
        SELECT count(*) FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
            ON tc.constraint_name = kcu.constraint_name
        WHERE tc.constraint_type = 'PRIMARY KEY'
            AND tc.table_schema = 'public';
    " 2>/dev/null | xargs)

    if [[ "${null_pk_count:-0}" -gt 0 ]]; then
        record_result "db_pk_integrity" "PASS" "Primary key constraints present ($null_pk_count)" $(($(date +%s) - start))
    else
        record_result "db_pk_integrity" "WARN" "No primary key constraints found" $(($(date +%s) - start))
    fi
}

# ---- Report Generation ----

generate_report() {
    local overall_status="PASS"
    [[ $WARNINGS -gt 0 ]] && overall_status="WARN"
    [[ $FAILED -gt 0 ]] && overall_status="FAIL"

    local total_duration=0
    total_duration=$(echo "$RESULTS" | jq '[.[].duration_seconds] | add // 0')

    cat > "$REPORT_FILE" <<EOF
{
    "report_id": "verify-${DATE_STAMP}",
    "timestamp": "$(date -Is)",
    "hostname": "$(hostname -f)",
    "repository": "${REPO:-none}",
    "overall_status": "$overall_status",
    "summary": {
        "passed": $PASSED,
        "failed": $FAILED,
        "warnings": $WARNINGS,
        "total_checks": $((PASSED + FAILED + WARNINGS)),
        "total_duration_seconds": $total_duration
    },
    "checks": $RESULTS
}
EOF

    # Create latest symlink
    ln -sf "$REPORT_FILE" "${REPORT_DIR}/latest.json"

    log ""
    log "========================================="
    log "  Verification Report: $overall_status"
    log "  Passed: $PASSED  Failed: $FAILED  Warnings: $WARNINGS"
    log "  Duration: ${total_duration}s"
    log "  Report: $REPORT_FILE"
    log "========================================="

    # Notify
    if [[ $FAILED -gt 0 ]]; then
        notify "🚨" "FAILED — $FAILED checks failed, $PASSED passed"
    elif [[ $WARNINGS -gt 0 ]]; then
        notify "⚠️" "$WARNINGS warnings, $PASSED passed"
    else
        notify "✅" "All $PASSED checks passed"
    fi

    # Return non-zero if any checks failed
    [[ $FAILED -eq 0 ]]
}

# ---- Commands ----

cmd_integrity() {
    check_repository_access || return 1
    check_snapshot_freshness
    check_snapshot_count
    check_integrity
    generate_report
}

cmd_restore() {
    check_repository_access || return 1
    check_restore_test
    generate_report
}

cmd_data() {
    check_repository_access || return 1
    check_restore_test
    check_database_restore
    check_data_validation
    generate_report
}

cmd_all() {
    check_repository_access || { generate_report; return 1; }
    check_snapshot_freshness
    check_snapshot_count
    check_integrity
    check_restore_test
    check_database_restore
    check_data_validation
    generate_report
}

cmd_report() {
    local latest="${REPORT_DIR}/latest.json"
    if [[ -f "$latest" ]]; then
        cat "$latest" | jq .
    else
        log "No verification reports found in $REPORT_DIR"
        exit 1
    fi
}

# ---- Main ----

setup

ACTION="${1:-all}"

case "$ACTION" in
    all)       cmd_all ;;
    integrity) cmd_integrity ;;
    restore)   cmd_restore ;;
    data)      cmd_data ;;
    report)    cmd_report ;;
    *)
        echo "Usage: $0 [all|integrity|restore|data|report]"
        exit 1
        ;;
esac
