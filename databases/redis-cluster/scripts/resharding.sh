#!/usr/bin/env bash
set -euo pipefail

# Redis Cluster Resharding — automated slot migration with progress & rollback
#
# Usage:
#   resharding.sh --from <node-id> --to <node-id> --slots <count> --host <host:port> [opts]
#
# Required:  --from <node-id>      Source master node ID
#            --to <node-id>        Target master node ID
#            --slots <count>       Number of slots to migrate
#            --host <host:port>    Any cluster node for discovery
#
# Optional:  --password <pass>     Redis AUTH password
#            --batch-size <n>      Slots per batch (default: 100)
#            --pipeline <n>        Keys per MIGRATE pipeline (default: 10)
#            --dry-run             Show plan without migrating
#            --timeout <secs>      Per-slot timeout (default: 60)
#            --rollback <logfile>  Reverse migrations from a previous log

FROM="" TO="" SLOTS=0 HOST="" PORT="" PASSWORD="" AUTH=""
BATCH=100 PIPE=10 DRY=false TIMEOUT=60 ROLLBACK="" LOGFILE=""

die()  { echo "ERROR: $*" >&2; exit 1; }
log()  { local m="[$(date '+%H:%M:%S')] $*"; echo "$m"; [[ -n "$LOGFILE" ]] && echo "$m" >> "$LOGFILE"; }
rcli() { redis-cli -h "$HOST" -p "$PORT" $AUTH "$@" 2>/dev/null; }

parse_args() {
    [[ $# -eq 0 ]] && { sed -n '3,/^$/p' "$0" | sed 's/^# \?//'; exit 1; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)       FROM="$2"; shift 2;;
            --to)         TO="$2"; shift 2;;
            --slots)      SLOTS="$2"; shift 2;;
            --host)       HOST="${2%:*}"; PORT="${2##*:}"; shift 2;;
            --password)   PASSWORD="$2"; shift 2;;
            --batch-size) BATCH="$2"; shift 2;;
            --pipeline)   PIPE="$2"; shift 2;;
            --dry-run)    DRY=true; shift;;
            --timeout)    TIMEOUT="$2"; shift 2;;
            --rollback)   ROLLBACK="$2"; shift 2;;
            -h|--help)    sed -n '3,/^$/p' "$0" | sed 's/^# \?//'; exit 0;;
            *)            die "Unknown option: $1";;
        esac
    done
    [[ -n "$PASSWORD" ]] && AUTH="-a $PASSWORD"
    if [[ -n "$ROLLBACK" ]]; then
        [[ -z "$HOST" ]] && die "--host is required with --rollback"
        return
    fi
    [[ -z "$FROM" ]]    && die "--from is required"
    [[ -z "$TO" ]]      && die "--to is required"
    [[ "$SLOTS" -le 0 ]] && die "--slots must be positive"
    [[ -z "$HOST" ]]    && die "--host is required"
    LOGFILE="reshard_$(date +%Y%m%d_%H%M%S).log"
}

node_line()   { rcli CLUSTER NODES | grep "^${1:?}"; }
is_master()   { node_line "$1" | grep -q "master"; }
node_addr()   { node_line "$1" | awk '{print $2}' | cut -d'@' -f1; }
cluster_ok()  { rcli CLUSTER INFO | grep -q "cluster_state:ok"; }

slots_of() {
    local count=0
    for r in $(node_line "$1" | awk '{for(i=9;i<=NF;i++) print $i}'); do
        [[ "$r" == *"["* ]] && continue
        if [[ "$r" == *-* ]]; then
            count=$(( count + ${r#*-} - ${r%-*} + 1 ))
        else
            count=$(( count + 1 ))
        fi
    done
    echo "$count"
}

slot_list() {
    for r in $(node_line "$1" | awk '{for(i=9;i<=NF;i++) print $i}'); do
        [[ "$r" == *"["* ]] && continue
        if [[ "$r" == *-* ]]; then
            seq "${r%-*}" "${r#*-}"
        else
            echo "$r"
        fi
    done
}

fix_stuck() {
    log "Fixing stuck MIGRATING/IMPORTING slots..."
    local nodes all_slots
    nodes=$(rcli CLUSTER NODES)
    all_slots=$(echo "$nodes" | grep -oP '\[(\d+)-[<>]-' | grep -oP '\d+' | sort -un || true)
    for slot in $all_slots; do
        while IFS= read -r line; do
            local addr nid
            nid=$(echo "$line" | awk '{print $1}')
            addr=$(echo "$line" | awk '{print $2}' | cut -d'@' -f1)
            redis-cli -h "${addr%:*}" -p "${addr##*:}" $AUTH CLUSTER SETSLOT "$slot" STABLE &>/dev/null || true
        done <<< "$nodes"
        log "  Stabilized slot $slot"
    done
}

progress() {
    local cur=$1 tot=$2 elapsed=$3
    local pct=$(( cur * 100 / tot ))
    local filled=$(( pct / 2 )) empty=$(( 50 - pct / 2 ))
    local eta="--:--"
    if [[ $cur -gt 0 ]]; then
        local rem=$(( elapsed * (tot - cur) / cur ))
        eta=$(printf '%02d:%02d' $(( rem/60 )) $(( rem%60 )))
    fi
    printf "\r  [%-50s] %3d%% (%d/%d) ETA %s" \
        "$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')" \
        "$pct" "$cur" "$tot" "$eta"
}

migrate_slot() {
    local slot=$1 src=$2 dst=$3
    local sa da; sa=$(node_addr "$src"); da=$(node_addr "$dst")
    local sh=${sa%:*} sp=${sa##*:} dh=${da%:*} dp=${da##*:}

    redis-cli -h "$dh" -p "$dp" $AUTH CLUSTER SETSLOT "$slot" IMPORTING "$src" >/dev/null
    redis-cli -h "$sh" -p "$sp" $AUTH CLUSTER SETSLOT "$slot" MIGRATING "$dst" >/dev/null

    while true; do
        local keys
        keys=$(redis-cli -h "$sh" -p "$sp" $AUTH CLUSTER GETKEYSINSLOT "$slot" "$PIPE" 2>/dev/null)
        [[ -z "$keys" ]] && break
        local kargs=()
        while IFS= read -r k; do [[ -n "$k" ]] && kargs+=("$k"); done <<< "$keys"
        [[ ${#kargs[@]} -eq 0 ]] && break
        local ma=""; [[ -n "$PASSWORD" ]] && ma="AUTH $PASSWORD"
        redis-cli -h "$sh" -p "$sp" $AUTH \
            MIGRATE "$dh" "$dp" "" 0 "$TIMEOUT" $ma KEYS "${kargs[@]}" >/dev/null || return 1
    done

    # Notify all nodes of new slot ownership
    while IFS= read -r line; do
        local addr
        addr=$(echo "$line" | awk '{print $2}' | cut -d'@' -f1)
        redis-cli -h "${addr%:*}" -p "${addr##*:}" $AUTH CLUSTER SETSLOT "$slot" NODE "$dst" &>/dev/null || true
    done <<< "$(rcli CLUSTER NODES)"
}

preflight() {
    log "Pre-flight checks..."
    cluster_ok                || die "Cluster state is not OK"
    node_line "$FROM" >/dev/null || die "Source node $FROM not found"
    node_line "$TO"   >/dev/null || die "Target node $TO not found"
    is_master "$FROM"         || die "Source $FROM is not a master"
    is_master "$TO"           || die "Target $TO is not a master"

    local src_slots; src_slots=$(slots_of "$FROM")
    [[ $src_slots -lt $SLOTS ]] && die "Source has $src_slots slots, requested $SLOTS"
    log "  ✓ Source owns $src_slots slots (requesting $SLOTS)"
    [[ $src_slots -eq $SLOTS ]] && log "  ⚠ WARNING: source will have 0 slots after migration!"

    local stuck
    stuck=$(rcli CLUSTER NODES | grep -oP '\[\d+-[<>]-[a-f0-9]+\]' || true)
    [[ -n "$stuck" ]] && die "Stuck slots detected: $stuck — resolve before resharding"
    log "  ✓ No stuck slots. All checks passed."
}

post_validate() {
    log "Post-migration validation..."
    cluster_ok && log "  ✓ Cluster healthy" || log "  ✗ Cluster NOT healthy!"

    local chk
    chk=$(redis-cli --cluster check "$HOST:$PORT" $AUTH 2>&1 || true)
    echo "$chk" | grep -q "All 16384 slots covered" \
        && log "  ✓ All 16384 slots covered" \
        || log "  ✗ Slot coverage issue!"

    log "Slot distribution:"
    rcli CLUSTER NODES | grep master | while IFS= read -r line; do
        local nid addr
        nid=$(echo "$line" | awk '{print $1}')
        addr=$(echo "$line" | awk '{print $2}' | cut -d'@' -f1)
        log "  $addr (${nid:0:8}…): $(slots_of "$nid") slots"
    done
}

do_reshard() {
    preflight
    local -a targets
    mapfile -t targets < <(slot_list "$FROM" | head -n "$SLOTS")

    if $DRY; then
        log "[DRY RUN] Would migrate ${#targets[@]} slots: ${targets[*]:0:20}$(( ${#targets[@]}>20 )) && echo '…'"
        log "[DRY RUN] batch=$BATCH pipeline=$PIPE timeout=${TIMEOUT}s"
        exit 0
    fi

    log "Migrating ${#targets[@]} slots ($FROM → $TO), log: $LOGFILE"
    local t0 done=0 total=${#targets[@]}
    t0=$(date +%s)

    for (( i=0; i<total; i+=BATCH )); do
        local end=$(( i+BATCH > total ? total : i+BATCH ))
        local bn=$(( i/BATCH+1 )) bt=$(( (total+BATCH-1)/BATCH ))
        log "Batch $bn/$bt — slots $i..$((end-1))"

        for (( j=i; j<end; j++ )); do
            if ! migrate_slot "${targets[j]}" "$FROM" "$TO"; then
                echo ""
                log "FAIL at slot ${targets[j]}"
                cluster_ok || log "CLUSTERDOWN detected!"
                read -rp "  [c]ontinue / [r]ollback / [a]bort? " choice
                case "${choice,,}" in
                    c) log "Continuing..."; continue;;
                    r) log "Rolling back..."; do_rollback "$LOGFILE"; exit 1;;
                    *) fix_stuck; die "Aborted at slot ${targets[j]}";;
                esac
            fi
            done=$(( done+1 ))
            echo "MIGRATED slot=${targets[j]} from=$FROM to=$TO" >> "$LOGFILE"
            progress "$done" "$total" "$(( $(date +%s) - t0 ))"
        done
        echo ""
        log "Batch $bn done — $done/$total migrated"
    done
    log "Migration complete: $done slots moved."
    post_validate
}

do_rollback() {
    local lf="${1:-$ROLLBACK}"
    [[ ! -f "$lf" ]] && die "Log not found: $lf"
    log "Rolling back from $lf..."
    fix_stuck

    local -a entries
    mapfile -t entries < <(grep '^MIGRATED ' "$lf" | tac)
    local total=${#entries[@]} rev=0 t0
    t0=$(date +%s)

    for e in "${entries[@]}"; do
        local s f t
        s=$(echo "$e" | grep -oP 'slot=\K\d+')
        f=$(echo "$e" | grep -oP 'from=\K\S+')
        t=$(echo "$e" | grep -oP 'to=\K\S+')
        if migrate_slot "$s" "$t" "$f"; then
            rev=$(( rev+1 ))
            progress "$rev" "$total" "$(( $(date +%s) - t0 ))"
        else
            log "WARNING: could not rollback slot $s"; fix_stuck
        fi
    done
    echo ""
    log "Rollback complete: $rev/$total reversed."
    post_validate
}

# --- main ---
parse_args "$@"
[[ -n "$ROLLBACK" ]] && do_rollback || do_reshard