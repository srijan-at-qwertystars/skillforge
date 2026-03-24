#!/usr/bin/env bash
###############################################################################
# stream-manager.sh — Create, update, purge, and manage JetStream streams
#                      and consumers
#
# Usage:
#   ./stream-manager.sh <command> [options]
#
# Commands:
#   create-stream    Create a new JetStream stream
#   update-stream    Update an existing stream's configuration
#   delete-stream    Delete a stream
#   purge-stream     Purge messages from a stream
#   list-streams     List all streams with stats
#   info-stream      Show detailed stream info
#   backup-stream    Backup a stream to file
#   restore-stream   Restore a stream from backup
#
#   create-consumer  Create a durable consumer
#   delete-consumer  Delete a consumer
#   list-consumers   List consumers for a stream
#   info-consumer    Show consumer details and lag
#
#   report           Show full cluster stream/consumer report
#
# Global Options:
#   --server URL     NATS server URL (default: nats://localhost:4222)
#   --creds FILE     Path to credentials file
#   --help           Show help for a command
#
# Examples:
#   ./stream-manager.sh create-stream --name ORDERS --subjects "orders.>"
#   ./stream-manager.sh create-stream --name EVENTS --subjects "events.>" \
#       --storage file --replicas 3 --max-age 72h --max-bytes 10GB
#   ./stream-manager.sh purge-stream --name ORDERS --keep 1000
#   ./stream-manager.sh create-consumer --stream ORDERS --name processor \
#       --filter "orders.created" --ack-wait 60s --max-deliver 5
#   ./stream-manager.sh report
###############################################################################
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SERVER="nats://localhost:4222"
CREDS=""

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; }

# ─── Prerequisites ──────────────────────────────────────────────────────────
check_nats_cli() {
    command -v nats &>/dev/null || {
        err "nats CLI not found. Install from https://github.com/nats-io/natscli"
        exit 2
    }
}

# Build common nats CLI flags
nats_flags=()
build_flags() {
    nats_flags=("--server" "$SERVER")
    [[ -n "$CREDS" ]] && nats_flags+=("--creds" "$CREDS")
}

run_nats() {
    nats "${nats_flags[@]}" "$@"
}

# ─── Parse global options (before command) ───────────────────────────────────
COMMAND=""
ARGS=()

parse_global() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)  SERVER="$2"; shift 2 ;;
            --creds)   CREDS="$2";  shift 2 ;;
            --help|-h)
                if [[ -z "$COMMAND" ]]; then
                    sed -n '2,/^###*$/{ s/^# \{0,1\}//; p; }' "$0"
                    exit 0
                fi
                ARGS+=("$1"); shift ;;
            *)
                if [[ -z "$COMMAND" ]]; then
                    COMMAND="$1"
                else
                    ARGS+=("$1")
                fi
                shift ;;
        esac
    done
}

# ─── Command: create-stream ─────────────────────────────────────────────────
cmd_create_stream() {
    local name="" subjects="" storage="file" replicas="1"
    local max_msgs="-1" max_bytes="-1" max_age="" max_msg_size="-1"
    local retention="limits" discard="old" dupe_window="2m"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)        name="$2";         shift 2 ;;
            --subjects)    subjects="$2";     shift 2 ;;
            --storage)     storage="$2";      shift 2 ;;
            --replicas)    replicas="$2";     shift 2 ;;
            --max-msgs)    max_msgs="$2";     shift 2 ;;
            --max-bytes)   max_bytes="$2";    shift 2 ;;
            --max-age)     max_age="$2";      shift 2 ;;
            --max-msg-size) max_msg_size="$2"; shift 2 ;;
            --retention)   retention="$2";    shift 2 ;;
            --discard)     discard="$2";      shift 2 ;;
            --dupe-window) dupe_window="$2";  shift 2 ;;
            --help|-h)
                echo "Usage: stream-manager.sh create-stream --name NAME --subjects SUBJ [options]"
                echo ""
                echo "Options:"
                echo "  --name NAME          Stream name (required)"
                echo "  --subjects SUBJ      Subject filter (required, e.g., 'orders.>')"
                echo "  --storage TYPE       file or memory (default: file)"
                echo "  --replicas N         Number of replicas (default: 1)"
                echo "  --max-msgs N         Max messages (default: unlimited)"
                echo "  --max-bytes SIZE     Max bytes (e.g., 10GB, default: unlimited)"
                echo "  --max-age DUR        Max age (e.g., 72h, default: unlimited)"
                echo "  --max-msg-size SIZE  Max message size (default: unlimited)"
                echo "  --retention TYPE     limits|workqueue|interest (default: limits)"
                echo "  --discard TYPE       old|new (default: old)"
                echo "  --dupe-window DUR    Dedup window (default: 2m)"
                exit 0 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$name" ]] && { err "--name is required"; exit 1; }
    [[ -z "$subjects" ]] && { err "--subjects is required"; exit 1; }

    info "Creating stream: ${name}"

    local cmd_args=(stream add "$name"
        --subjects "$subjects"
        --storage "$storage"
        --replicas "$replicas"
        --retention "$retention"
        --max-msgs "$max_msgs"
        --max-bytes "$max_bytes"
        --max-msg-size "$max_msg_size"
        --discard "$discard"
        --dupe-window "$dupe_window"
        --defaults
    )

    [[ -n "$max_age" ]] && cmd_args+=(--max-age "$max_age")

    if run_nats "${cmd_args[@]}"; then
        ok "Stream '${name}' created"
    else
        err "Failed to create stream '${name}'"
        exit 1
    fi
}

# ─── Command: update-stream ─────────────────────────────────────────────────
cmd_update_stream() {
    local name=""
    local edit_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)        name="$2";                              shift 2 ;;
            --max-msgs)    edit_args+=(--max-msgs "$2");           shift 2 ;;
            --max-bytes)   edit_args+=(--max-bytes "$2");          shift 2 ;;
            --max-age)     edit_args+=(--max-age "$2");            shift 2 ;;
            --max-msg-size) edit_args+=(--max-msg-size "$2");      shift 2 ;;
            --replicas)    edit_args+=(--replicas "$2");           shift 2 ;;
            --discard)     edit_args+=(--discard "$2");            shift 2 ;;
            --help|-h)
                echo "Usage: stream-manager.sh update-stream --name NAME [--max-msgs N] [--max-bytes SIZE] ..."
                exit 0 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$name" ]] && { err "--name is required"; exit 1; }
    [[ ${#edit_args[@]} -eq 0 ]] && { err "No update options provided"; exit 1; }

    info "Updating stream: ${name}"
    if run_nats stream edit "$name" "${edit_args[@]}" --force; then
        ok "Stream '${name}' updated"
    else
        err "Failed to update stream '${name}'"
        exit 1
    fi
}

# ─── Command: delete-stream ─────────────────────────────────────────────────
cmd_delete_stream() {
    local name="" force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)   name="$2"; shift 2 ;;
            --force)  force=true; shift ;;
            --help|-h) echo "Usage: stream-manager.sh delete-stream --name NAME [--force]"; exit 0 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$name" ]] && { err "--name is required"; exit 1; }

    if ! $force; then
        printf "Delete stream '${name}'? This cannot be undone. [y/N] "
        read -r confirm
        [[ "$confirm" =~ ^[yY] ]] || { info "Cancelled"; exit 0; }
    fi

    if run_nats stream rm "$name" --force; then
        ok "Stream '${name}' deleted"
    else
        err "Failed to delete stream '${name}'"
        exit 1
    fi
}

# ─── Command: purge-stream ──────────────────────────────────────────────────
cmd_purge_stream() {
    local name="" keep="" subject=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)    name="$2";    shift 2 ;;
            --keep)    keep="$2";    shift 2 ;;
            --subject) subject="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: stream-manager.sh purge-stream --name NAME [--keep N] [--subject SUBJ]"
                echo "  --keep N       Keep last N messages"
                echo "  --subject SUBJ Only purge messages matching subject"
                exit 0 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$name" ]] && { err "--name is required"; exit 1; }

    local purge_args=(stream purge "$name" --force)
    [[ -n "$keep" ]] && purge_args+=(--keep "$keep")
    [[ -n "$subject" ]] && purge_args+=(--subject "$subject")

    info "Purging stream: ${name}"
    if run_nats "${purge_args[@]}"; then
        ok "Stream '${name}' purged"
    else
        err "Failed to purge stream '${name}'"
        exit 1
    fi
}

# ─── Command: list-streams ──────────────────────────────────────────────────
cmd_list_streams() {
    printf "${BOLD}%-20s  %-12s  %-12s  %-10s  %-10s  %-8s${NC}\n" \
        "STREAM" "MESSAGES" "BYTES" "CONSUMERS" "REPLICAS" "STORAGE"

    local stream_names
    stream_names=$(run_nats stream ls -n 2>/dev/null) || {
        warn "No streams found or cannot connect"
        return
    }

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        name=$(echo "$name" | xargs)

        local info_json
        info_json=$(run_nats stream info "$name" --json 2>/dev/null) || continue

        if command -v jq &>/dev/null; then
            local msgs bytes consumers replicas storage
            msgs=$(echo "$info_json" | jq -r '.state.messages // 0')
            bytes=$(echo "$info_json" | jq -r '.state.bytes // 0' | numfmt --to=iec 2>/dev/null || echo "?")
            consumers=$(echo "$info_json" | jq -r '.state.consumer_count // 0')
            replicas=$(echo "$info_json" | jq -r '.config.num_replicas // 1')
            storage=$(echo "$info_json" | jq -r '.config.storage // "file"' | sed 's/JetStreamFileStorage/file/;s/JetStreamMemoryStorage/memory/')

            printf "%-20s  %-12s  %-12s  %-10s  %-10s  %-8s\n" \
                "$name" "$msgs" "$bytes" "$consumers" "$replicas" "$storage"
        else
            echo "$name"
        fi
    done <<< "$stream_names"
}

# ─── Command: info-stream ───────────────────────────────────────────────────
cmd_info_stream() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --help|-h) echo "Usage: stream-manager.sh info-stream --name NAME"; exit 0 ;;
            *) name="$1"; shift ;;
        esac
    done

    [[ -z "$name" ]] && { err "--name or stream name is required"; exit 1; }
    run_nats stream info "$name"
}

# ─── Command: backup-stream ─────────────────────────────────────────────────
cmd_backup_stream() {
    local name="" output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)   name="$2";   shift 2 ;;
            --output) output="$2"; shift 2 ;;
            --help|-h) echo "Usage: stream-manager.sh backup-stream --name NAME [--output FILE]"; exit 0 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$name" ]] && { err "--name is required"; exit 1; }
    [[ -z "$output" ]] && output="${name}-$(date +%Y%m%d-%H%M%S).tar.gz"

    info "Backing up stream '${name}' to ${output}..."
    if run_nats stream backup "$name" "$output"; then
        ok "Backup complete: ${output}"
    else
        err "Backup failed"
        exit 1
    fi
}

# ─── Command: restore-stream ────────────────────────────────────────────────
cmd_restore_stream() {
    local name="" input=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)  name="$2";  shift 2 ;;
            --input) input="$2"; shift 2 ;;
            --help|-h) echo "Usage: stream-manager.sh restore-stream --name NAME --input FILE"; exit 0 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$name" ]] && { err "--name is required"; exit 1; }
    [[ -z "$input" ]] && { err "--input is required"; exit 1; }
    [[ -f "$input" ]] || { err "File not found: ${input}"; exit 1; }

    info "Restoring stream '${name}' from ${input}..."
    if run_nats stream restore "$name" "$input"; then
        ok "Restore complete"
    else
        err "Restore failed"
        exit 1
    fi
}

# ─── Command: create-consumer ───────────────────────────────────────────────
cmd_create_consumer() {
    local stream="" name="" filter="" ack_wait="30s" max_deliver="5"
    local deliver_policy="all" ack_policy="explicit" max_pending="1000"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stream)         stream="$2";         shift 2 ;;
            --name)           name="$2";           shift 2 ;;
            --filter)         filter="$2";         shift 2 ;;
            --ack-wait)       ack_wait="$2";       shift 2 ;;
            --max-deliver)    max_deliver="$2";    shift 2 ;;
            --deliver-policy) deliver_policy="$2"; shift 2 ;;
            --ack-policy)     ack_policy="$2";     shift 2 ;;
            --max-pending)    max_pending="$2";    shift 2 ;;
            --help|-h)
                echo "Usage: stream-manager.sh create-consumer --stream STREAM --name NAME [options]"
                echo ""
                echo "Options:"
                echo "  --stream STREAM        Stream name (required)"
                echo "  --name NAME            Consumer name (required)"
                echo "  --filter SUBJECT       Filter subject"
                echo "  --ack-wait DUR         Ack wait duration (default: 30s)"
                echo "  --max-deliver N        Max delivery attempts (default: 5)"
                echo "  --deliver-policy TYPE  all|new|last|last-per-subject (default: all)"
                echo "  --ack-policy TYPE      explicit|all|none (default: explicit)"
                echo "  --max-pending N        Max ack pending (default: 1000)"
                exit 0 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$stream" ]] && { err "--stream is required"; exit 1; }
    [[ -z "$name" ]] && { err "--name is required"; exit 1; }

    info "Creating consumer '${name}' on stream '${stream}'"

    local cmd_args=(consumer add "$stream" "$name"
        --ack "$ack_policy"
        --deliver "$deliver_policy"
        --max-deliver "$max_deliver"
        --wait "$ack_wait"
        --max-pending "$max_pending"
        --pull
        --defaults
    )

    [[ -n "$filter" ]] && cmd_args+=(--filter "$filter")

    if run_nats "${cmd_args[@]}"; then
        ok "Consumer '${name}' created on '${stream}'"
    else
        err "Failed to create consumer"
        exit 1
    fi
}

# ─── Command: delete-consumer ───────────────────────────────────────────────
cmd_delete_consumer() {
    local stream="" name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stream) stream="$2"; shift 2 ;;
            --name)   name="$2";   shift 2 ;;
            --help|-h) echo "Usage: stream-manager.sh delete-consumer --stream STREAM --name NAME"; exit 0 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$stream" ]] && { err "--stream is required"; exit 1; }
    [[ -z "$name" ]] && { err "--name is required"; exit 1; }

    if run_nats consumer rm "$stream" "$name" --force; then
        ok "Consumer '${name}' deleted from '${stream}'"
    else
        err "Failed to delete consumer"
        exit 1
    fi
}

# ─── Command: list-consumers ────────────────────────────────────────────────
cmd_list_consumers() {
    local stream=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stream) stream="$2"; shift 2 ;;
            --help|-h) echo "Usage: stream-manager.sh list-consumers --stream STREAM"; exit 0 ;;
            *) stream="$1"; shift ;;
        esac
    done

    [[ -z "$stream" ]] && { err "--stream is required"; exit 1; }
    run_nats consumer ls "$stream"
}

# ─── Command: info-consumer ─────────────────────────────────────────────────
cmd_info_consumer() {
    local stream="" name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stream) stream="$2"; shift 2 ;;
            --name)   name="$2";   shift 2 ;;
            --help|-h) echo "Usage: stream-manager.sh info-consumer --stream STREAM --name NAME"; exit 0 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$stream" ]] && { err "--stream is required"; exit 1; }
    [[ -z "$name" ]] && { err "--name is required"; exit 1; }
    run_nats consumer info "$stream" "$name"
}

# ─── Command: report ────────────────────────────────────────────────────────
cmd_report() {
    printf "${BOLD}${CYAN}═══ NATS Stream & Consumer Report ═══${NC}\n\n"

    printf "${BOLD}Streams:${NC}\n"
    cmd_list_streams

    echo ""
    printf "${BOLD}Stream Details:${NC}\n"
    local stream_names
    stream_names=$(run_nats stream ls -n 2>/dev/null) || return

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        name=$(echo "$name" | xargs)
        printf "\n${CYAN}── ${name} ──${NC}\n"

        # Consumer list
        local consumers
        consumers=$(run_nats consumer ls "$name" -n 2>/dev/null) || continue

        if [[ -z "$consumers" ]]; then
            echo "  No consumers"
            continue
        fi

        printf "  %-20s  %-12s  %-12s  %-10s\n" "CONSUMER" "ACK PENDING" "REDELIVERED" "DELIVERED"
        while IFS= read -r con; do
            [[ -z "$con" ]] && continue
            con=$(echo "$con" | xargs)

            local con_json
            con_json=$(run_nats consumer info "$name" "$con" --json 2>/dev/null) || continue

            if command -v jq &>/dev/null; then
                local ack_pending redelivered delivered
                ack_pending=$(echo "$con_json" | jq -r '.num_ack_pending // 0')
                redelivered=$(echo "$con_json" | jq -r '.num_redelivered // 0')
                delivered=$(echo "$con_json" | jq -r '.delivered.stream_seq // 0')
                printf "  %-20s  %-12s  %-12s  %-10s\n" "$con" "$ack_pending" "$redelivered" "$delivered"
            else
                echo "  $con"
            fi
        done <<< "$consumers"
    done <<< "$stream_names"

    echo ""
    printf "${BOLD}Cluster JetStream Report:${NC}\n"
    run_nats server report jetstream 2>/dev/null || warn "Could not get cluster report"
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_global "$@"
    check_nats_cli
    build_flags

    case "$COMMAND" in
        create-stream)   cmd_create_stream   "${ARGS[@]}" ;;
        update-stream)   cmd_update_stream   "${ARGS[@]}" ;;
        delete-stream)   cmd_delete_stream   "${ARGS[@]}" ;;
        purge-stream)    cmd_purge_stream    "${ARGS[@]}" ;;
        list-streams)    cmd_list_streams    "${ARGS[@]}" ;;
        info-stream)     cmd_info_stream     "${ARGS[@]}" ;;
        backup-stream)   cmd_backup_stream   "${ARGS[@]}" ;;
        restore-stream)  cmd_restore_stream  "${ARGS[@]}" ;;
        create-consumer) cmd_create_consumer "${ARGS[@]}" ;;
        delete-consumer) cmd_delete_consumer "${ARGS[@]}" ;;
        list-consumers)  cmd_list_consumers  "${ARGS[@]}" ;;
        info-consumer)   cmd_info_consumer   "${ARGS[@]}" ;;
        report)          cmd_report ;;
        "")              sed -n '2,/^###*$/{ s/^# \{0,1\}//; p; }' "$0"; exit 0 ;;
        *)               err "Unknown command: ${COMMAND}"; exit 1 ;;
    esac
}

main "$@"
