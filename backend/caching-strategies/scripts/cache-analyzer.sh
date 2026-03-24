#!/usr/bin/env bash
# cache-analyzer.sh — Analyze Redis cache: key distribution, memory per prefix, TTL distribution, hot keys
set -euo pipefail

# --- Configuration ---
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
SAMPLE_SIZE="${SAMPLE_SIZE:-5000}"
SCAN_COUNT="${SCAN_COUNT:-1000}"

# --- Helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[ANALYZE]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}═══ $* ═══${NC}\n"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Analyze a Redis instance: key distribution, memory usage per prefix,
TTL distribution, hot keys, and health metrics.

Options:
  -h, --host HOST        Redis host (default: 127.0.0.1)
  -p, --port PORT        Redis port (default: 6379)
  -a, --password PASS    Redis password
  -s, --sample-size N    Number of keys to sample (default: 5000)
  --pattern PATTERN      Only analyze keys matching this pattern (default: *)
  --section SECTION      Run only a specific section:
                           overview, keys, memory, ttl, hotkeys, health, bigkeys
  --help                 Show this help

Environment variables:
  REDIS_HOST, REDIS_PORT, REDIS_PASSWORD, SAMPLE_SIZE

Examples:
  $(basename "$0")                          # Full analysis
  $(basename "$0") --section hotkeys        # Only hot keys
  $(basename "$0") --pattern "user:*" -s 10000
  $(basename "$0") -h redis.prod.internal --section memory
EOF
    exit 0
}

PATTERN="*"
SECTION="all"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--host)        REDIS_HOST="$2"; shift 2 ;;
        -p|--port)        REDIS_PORT="$2"; shift 2 ;;
        -a|--password)    REDIS_PASSWORD="$2"; shift 2 ;;
        -s|--sample-size) SAMPLE_SIZE="$2"; shift 2 ;;
        --pattern)        PATTERN="$2"; shift 2 ;;
        --section)        SECTION="$2"; shift 2 ;;
        --help)           usage ;;
        *)                err "Unknown option: $1"; usage ;;
    esac
done

# --- Redis CLI wrapper ---
CLI_ARGS=(-h "$REDIS_HOST" -p "$REDIS_PORT" --no-auth-warning)
if [[ -n "$REDIS_PASSWORD" ]]; then
    CLI_ARGS+=(-a "$REDIS_PASSWORD")
fi

redis_cmd() { redis-cli "${CLI_ARGS[@]}" "$@" 2>/dev/null; }

# --- Preflight ---
check_connection() {
    if ! command -v redis-cli &>/dev/null; then
        err "redis-cli not found. Install redis-tools."
        exit 1
    fi
    local pong
    pong=$(redis_cmd PING 2>/dev/null)
    if [[ "$pong" != "PONG" ]]; then
        err "Cannot connect to Redis at ${REDIS_HOST}:${REDIS_PORT}"
        exit 1
    fi
    ok "Connected to Redis at ${REDIS_HOST}:${REDIS_PORT}"
}

# --- Sample keys using SCAN ---
TMPDIR_ANALYZER=$(mktemp -d)
SAMPLED_KEYS="$TMPDIR_ANALYZER/sampled_keys.txt"

sample_keys() {
    log "Sampling up to $SAMPLE_SIZE keys matching '$PATTERN'..."
    local cursor=0
    local count=0
    true > "$SAMPLED_KEYS"

    while true; do
        local result
        result=$(redis_cmd SCAN "$cursor" MATCH "$PATTERN" COUNT "$SCAN_COUNT")
        cursor=$(echo "$result" | head -1 | tr -d '\r')
        local keys
        keys=$(echo "$result" | tail -n +2 | tr -d '\r')

        if [[ -n "$keys" ]]; then
            echo "$keys" >> "$SAMPLED_KEYS"
            count=$(wc -l < "$SAMPLED_KEYS")
        fi

        if [[ "$cursor" == "0" ]] || [[ "$count" -ge "$SAMPLE_SIZE" ]]; then
            break
        fi
    done

    # Trim to sample size
    if [[ "$count" -gt "$SAMPLE_SIZE" ]]; then
        head -n "$SAMPLE_SIZE" "$SAMPLED_KEYS" > "$SAMPLED_KEYS.tmp"
        mv "$SAMPLED_KEYS.tmp" "$SAMPLED_KEYS"
    fi

    local final_count
    final_count=$(wc -l < "$SAMPLED_KEYS")
    ok "Sampled $final_count keys"
}

# --- Sections ---

section_overview() {
    header "Server Overview"

    log "Redis version:"
    redis_cmd INFO server | grep -E "redis_version:|redis_mode:|os:|tcp_port:" | tr -d '\r' | sed 's/^/  /'

    echo ""
    log "Database size:"
    redis_cmd INFO keyspace | grep -v "^#" | tr -d '\r' | sed 's/^/  /'

    local dbsize
    dbsize=$(redis_cmd DBSIZE | tr -d '\r')
    echo "  total_keys: $dbsize"

    echo ""
    log "Uptime:"
    redis_cmd INFO server | grep -E "uptime_in_seconds:|uptime_in_days:" | tr -d '\r' | sed 's/^/  /'
}

section_key_distribution() {
    header "Key Distribution by Prefix"

    if [[ ! -s "$SAMPLED_KEYS" ]]; then
        warn "No keys sampled. Skipping."
        return
    fi

    log "Top 20 key prefixes (first segment before ':'):"
    echo ""

    printf "  ${BOLD}%-30s %8s %8s${NC}\n" "PREFIX" "COUNT" "PCT"
    echo "  $(printf '%.0s─' {1..50})"

    local total
    total=$(wc -l < "$SAMPLED_KEYS")

    awk -F: '{
        if (NF > 1) prefix = $1;
        else prefix = "(no-prefix)";
        count[prefix]++
    }
    END {
        for (p in count) print count[p], p
    }' "$SAMPLED_KEYS" | sort -rn | head -20 | while read -r cnt prefix; do
        local pct
        pct=$(awk "BEGIN {printf \"%.1f\", ($cnt/$total)*100}")
        printf "  %-30s %8d %7s%%\n" "$prefix" "$cnt" "$pct"
    done

    echo ""
    log "Key types distribution:"
    echo ""

    local type_counts
    type_counts=$(mktemp)
    head -200 "$SAMPLED_KEYS" | while read -r key; do
        redis_cmd TYPE "$key" | tr -d '\r'
    done | sort | uniq -c | sort -rn > "$type_counts"

    printf "  ${BOLD}%-15s %8s${NC}\n" "TYPE" "COUNT"
    echo "  $(printf '%.0s─' {1..25})"
    while read -r cnt typ; do
        printf "  %-15s %8d\n" "$typ" "$cnt"
    done < "$type_counts"
    rm -f "$type_counts"
}

section_memory() {
    header "Memory Analysis"

    log "Overall memory:"
    redis_cmd INFO memory | grep -E "used_memory_human:|used_memory_peak_human:|used_memory_dataset_perc:|mem_fragmentation_ratio:|maxmemory_human:|maxmemory_policy:" | tr -d '\r' | sed 's/^/  /'

    echo ""
    log "Memory usage by prefix (sampled from first 500 keys):"
    echo ""

    if [[ ! -s "$SAMPLED_KEYS" ]]; then
        warn "No keys sampled. Skipping."
        return
    fi

    local mem_file
    mem_file=$(mktemp)

    head -500 "$SAMPLED_KEYS" | while read -r key; do
        local mem
        mem=$(redis_cmd MEMORY USAGE "$key" 2>/dev/null | tr -d '\r')
        if [[ -n "$mem" && "$mem" =~ ^[0-9]+$ ]]; then
            local prefix
            prefix=$(echo "$key" | cut -d: -f1)
            echo "$prefix $mem"
        fi
    done > "$mem_file"

    if [[ -s "$mem_file" ]]; then
        printf "  ${BOLD}%-25s %10s %8s %10s %10s${NC}\n" "PREFIX" "TOTAL" "COUNT" "AVG" "MAX"
        echo "  $(printf '%.0s─' {1..68})"

        awk '{
            prefix = $1; mem = $2
            total[prefix] += mem
            count[prefix]++
            if (mem > max[prefix]) max[prefix] = mem
        }
        END {
            for (p in total) {
                avg = total[p] / count[p]
                printf "  %-25s %10d %8d %10d %10d\n", p, total[p], count[p], avg, max[p]
            }
        }' "$mem_file" | sort -t' ' -k2 -rn | head -20
    fi
    rm -f "$mem_file"

    echo ""
    log "Eviction stats:"
    redis_cmd INFO stats | grep -E "evicted_keys:|expired_keys:|expired_stale_perc:" | tr -d '\r' | sed 's/^/  /'
}

section_ttl() {
    header "TTL Distribution"

    if [[ ! -s "$SAMPLED_KEYS" ]]; then
        warn "No keys sampled. Skipping."
        return
    fi

    local ttl_file
    ttl_file=$(mktemp)

    log "Sampling TTLs from $(wc -l < "$SAMPLED_KEYS") keys..."

    head -"$SAMPLE_SIZE" "$SAMPLED_KEYS" | while read -r key; do
        local ttl
        ttl=$(redis_cmd TTL "$key" | tr -d '\r')
        echo "$ttl"
    done > "$ttl_file"

    local total no_ttl expired short medium long very_long
    total=$(wc -l < "$ttl_file")
    no_ttl=$(grep -c "^-1$" "$ttl_file" || true)
    expired=$(grep -c "^-2$" "$ttl_file" || true)
    short=$(awk '$1 > 0 && $1 <= 60' "$ttl_file" | wc -l)
    medium=$(awk '$1 > 60 && $1 <= 3600' "$ttl_file" | wc -l)
    long=$(awk '$1 > 3600 && $1 <= 86400' "$ttl_file" | wc -l)
    very_long=$(awk '$1 > 86400' "$ttl_file" | wc -l)

    printf "  ${BOLD}%-25s %8s %8s${NC}\n" "TTL RANGE" "COUNT" "PCT"
    echo "  $(printf '%.0s─' {1..45})"
    printf "  %-25s %8d %7.1f%%\n" "No TTL (persistent)" "$no_ttl" "$(awk "BEGIN{printf \"%.1f\", ($no_ttl/$total)*100}")"
    printf "  %-25s %8d %7.1f%%\n" "Expired/missing" "$expired" "$(awk "BEGIN{printf \"%.1f\", ($expired/$total)*100}")"
    printf "  %-25s %8d %7.1f%%\n" "≤ 1 minute" "$short" "$(awk "BEGIN{printf \"%.1f\", ($short/$total)*100}")"
    printf "  %-25s %8d %7.1f%%\n" "1 min – 1 hour" "$medium" "$(awk "BEGIN{printf \"%.1f\", ($medium/$total)*100}")"
    printf "  %-25s %8d %7.1f%%\n" "1 hour – 1 day" "$long" "$(awk "BEGIN{printf \"%.1f\", ($long/$total)*100}")"
    printf "  %-25s %8d %7.1f%%\n" "> 1 day" "$very_long" "$(awk "BEGIN{printf \"%.1f\", ($very_long/$total)*100}")"

    if [[ "$no_ttl" -gt 0 ]]; then
        echo ""
        warn "$no_ttl keys have no TTL (potential memory leak). Prefixes:"
        head -"$SAMPLE_SIZE" "$SAMPLED_KEYS" | while read -r key; do
            local ttl
            ttl=$(redis_cmd TTL "$key" | tr -d '\r')
            if [[ "$ttl" == "-1" ]]; then
                echo "$key" | cut -d: -f1
            fi
        done | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
    fi

    rm -f "$ttl_file"
}

section_hotkeys() {
    header "Hot Key Detection"

    # Check if LFU mode is enabled
    local policy
    policy=$(redis_cmd CONFIG GET maxmemory-policy | tail -1 | tr -d '\r')

    if [[ "$policy" == *"lfu"* ]]; then
        log "LFU policy detected ($policy). Using OBJECT FREQ for hot key detection."
        echo ""

        local hot_file
        hot_file=$(mktemp)

        head -"$SAMPLE_SIZE" "$SAMPLED_KEYS" | while read -r key; do
            local freq
            freq=$(redis_cmd OBJECT FREQ "$key" 2>/dev/null | tr -d '\r')
            if [[ -n "$freq" && "$freq" =~ ^[0-9]+$ && "$freq" -gt 0 ]]; then
                echo "$freq $key"
            fi
        done | sort -rn > "$hot_file"

        if [[ -s "$hot_file" ]]; then
            printf "  ${BOLD}%-8s %-60s${NC}\n" "FREQ" "KEY"
            echo "  $(printf '%.0s─' {1..70})"
            head -20 "$hot_file" | while read -r freq key; do
                printf "  %-8s %-60s\n" "$freq" "$key"
            done
        else
            warn "No keys with frequency > 0 found in sample."
        fi
        rm -f "$hot_file"
    else
        log "Eviction policy is '$policy' (not LFU). Using OBJECT IDLETIME for cold key detection."
        warn "For hot key detection, enable LFU: CONFIG SET maxmemory-policy allkeys-lfu"
        echo ""

        log "Least idle (most recently accessed) keys:"
        local idle_file
        idle_file=$(mktemp)

        head -"$SAMPLE_SIZE" "$SAMPLED_KEYS" | while read -r key; do
            local idle
            idle=$(redis_cmd OBJECT IDLETIME "$key" 2>/dev/null | tr -d '\r')
            if [[ -n "$idle" && "$idle" =~ ^[0-9]+$ ]]; then
                echo "$idle $key"
            fi
        done | sort -n > "$idle_file"

        if [[ -s "$idle_file" ]]; then
            printf "  ${BOLD}%-12s %-55s${NC}\n" "IDLE (sec)" "KEY"
            echo "  $(printf '%.0s─' {1..70})"
            head -20 "$idle_file" | while read -r idle key; do
                printf "  %-12s %-55s\n" "$idle" "$key"
            done
        fi
        rm -f "$idle_file"
    fi

    echo ""
    log "Hit/miss ratio:"
    local hits misses
    hits=$(redis_cmd INFO stats | grep "keyspace_hits:" | cut -d: -f2 | tr -d '\r')
    misses=$(redis_cmd INFO stats | grep "keyspace_misses:" | cut -d: -f2 | tr -d '\r')
    echo "  Hits:   $hits"
    echo "  Misses: $misses"
    if [[ -n "$hits" && -n "$misses" && "$((hits + misses))" -gt 0 ]]; then
        local ratio
        ratio=$(awk "BEGIN {printf \"%.2f\", ($hits / ($hits + $misses)) * 100}")
        echo "  Hit ratio: ${ratio}%"
        if (( $(awk "BEGIN {print ($ratio < 80) ? 1 : 0}") )); then
            warn "Hit ratio below 80%. Check TTL settings and key patterns."
        else
            ok "Hit ratio is healthy (≥80%)."
        fi
    fi
}

section_bigkeys() {
    header "Big Keys Analysis"

    log "Running redis-cli --bigkeys (sampled)..."
    echo ""
    redis_cmd --bigkeys --no-auth-warning 2>/dev/null | grep -E "Biggest|Summary|keys with" | sed 's/^/  /' || \
        warn "bigkeys scan failed or returned no results"
}

section_health() {
    header "Health Check"

    # Latency
    log "Latency test (100 pings):"
    local latency_output
    latency_output=$(redis_cmd --latency-history -i 1 2>/dev/null &
        local pid=$!
        sleep 3
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    ) || true
    redis_cmd PING >/dev/null
    local start end
    start=$(date +%s%N)
    for _ in $(seq 1 100); do
        redis_cmd PING >/dev/null
    done
    end=$(date +%s%N)
    local avg_us=$(( (end - start) / 100000 ))
    echo "  Average latency: ~${avg_us}µs per PING (100 samples)"

    echo ""

    # Connected clients
    log "Client connections:"
    redis_cmd INFO clients | grep -E "connected_clients:|blocked_clients:|maxclients:" | tr -d '\r' | sed 's/^/  /'

    echo ""

    # Replication
    log "Replication status:"
    local role
    role=$(redis_cmd INFO replication | grep "role:" | cut -d: -f2 | tr -d '\r')
    echo "  Role: $role"
    if [[ "$role" == "master" ]]; then
        redis_cmd INFO replication | grep -E "connected_slaves:|repl_backlog_active:" | tr -d '\r' | sed 's/^/  /'
    elif [[ "$role" == "slave" ]]; then
        redis_cmd INFO replication | grep -E "master_host:|master_port:|master_link_status:|master_last_io_seconds_ago:" | tr -d '\r' | sed 's/^/  /'
    fi

    echo ""

    # Persistence
    log "Persistence:"
    redis_cmd INFO persistence | grep -E "rdb_last_save_time:|rdb_last_bgsave_status:|aof_enabled:|aof_last_bgrewrite_status:" | tr -d '\r' | sed 's/^/  /'

    echo ""

    # Dangerous config checks
    log "Configuration warnings:"
    local maxmem
    maxmem=$(redis_cmd CONFIG GET maxmemory | tail -1 | tr -d '\r')
    if [[ "$maxmem" == "0" ]]; then
        warn "  maxmemory is 0 (unlimited). Set a limit in production."
    else
        ok "  maxmemory is set: $(redis_cmd INFO memory | grep maxmemory_human | cut -d: -f2 | tr -d '\r')"
    fi

    local policy
    policy=$(redis_cmd CONFIG GET maxmemory-policy | tail -1 | tr -d '\r')
    if [[ "$policy" == "noeviction" ]]; then
        warn "  maxmemory-policy is 'noeviction'. Writes will fail when memory is full."
    else
        ok "  maxmemory-policy: $policy"
    fi

    local timeout
    timeout=$(redis_cmd CONFIG GET timeout | tail -1 | tr -d '\r')
    if [[ "$timeout" == "0" ]]; then
        warn "  client timeout is 0 (no idle timeout). Set to avoid connection leaks."
    fi
}

# --- Cleanup ---
cleanup() {
    rm -rf "$TMPDIR_ANALYZER" 2>/dev/null || true
}
trap cleanup EXIT

# --- Main ---
main() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║         Redis Cache Analyzer                 ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""

    check_connection

    if [[ "$SECTION" != "overview" ]]; then
        sample_keys
    fi

    case "$SECTION" in
        all)
            section_overview
            section_key_distribution
            section_memory
            section_ttl
            section_hotkeys
            section_bigkeys
            section_health
            ;;
        overview)  section_overview ;;
        keys)      section_key_distribution ;;
        memory)    section_memory ;;
        ttl)       section_ttl ;;
        hotkeys)   section_hotkeys ;;
        bigkeys)   section_bigkeys ;;
        health)    section_health ;;
        *)         err "Unknown section: $SECTION"; usage ;;
    esac

    echo ""
    ok "Analysis complete!"
    echo ""
}

main
