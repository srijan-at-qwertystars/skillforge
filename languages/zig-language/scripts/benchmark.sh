#!/usr/bin/env bash
#
# benchmark.sh — Run Zig benchmarks with std.time and comparison reporting
#
# Usage:
#   ./benchmark.sh [OPTIONS]
#
# Options:
#   --file <path>        Zig file containing benchmarks (default: src/bench.zig)
#   --iterations <n>     Number of benchmark iterations (default: 1000)
#   --warmup <n>         Warmup iterations (default: 100)
#   --output <format>    Output format: text|csv|json (default: text)
#   --compare <file>     Compare against a previous benchmark JSON result
#   -h, --help           Show this help
#
# Benchmark functions must follow this naming convention:
#   pub fn bench_<name>() void { ... }
#
# Example bench.zig:
#   const std = @import("std");
#   pub fn bench_array_sum() u64 {
#       var sum: u64 = 0;
#       for (0..1000) |i| sum += i;
#       return sum;
#   }
#

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Default Configuration ---
BENCH_FILE="src/bench.zig"
ITERATIONS=1000
WARMUP=100
OUTPUT_FORMAT="text"
COMPARE_FILE=""

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)       BENCH_FILE="$2"; shift 2 ;;
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --warmup)     WARMUP="$2"; shift 2 ;;
        --output)     OUTPUT_FORMAT="$2"; shift 2 ;;
        --compare)    COMPARE_FILE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: ${SCRIPT_NAME} [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --file <path>        Zig benchmark file (default: src/bench.zig)"
            echo "  --iterations <n>     Benchmark iterations (default: 1000)"
            echo "  --warmup <n>         Warmup iterations (default: 100)"
            echo "  --output <format>    text|csv|json (default: text)"
            echo "  --compare <file>     Compare with previous JSON results"
            echo "  -h, --help           Show this help"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Validation ---
if ! command -v zig &>/dev/null; then
    log_error "Zig not found in PATH."
    exit 1
fi

if [[ ! -f "$BENCH_FILE" ]]; then
    log_warn "Benchmark file '${BENCH_FILE}' not found."
    log_info "Creating a sample benchmark file..."

    mkdir -p "$(dirname "$BENCH_FILE")"
    cat > "$BENCH_FILE" << 'BENCHEOF'
const std = @import("std");

/// Benchmark harness — measures wall-clock time for each bench_ function
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    const iterations: usize = if (args.len > 1) std.fmt.parseInt(usize, args[1], 10) catch 1000 else 1000;
    const warmup: usize = if (args.len > 2) std.fmt.parseInt(usize, args[2], 10) catch 100 else 100;

    try stdout.print("Running benchmarks ({} iterations, {} warmup)\n", .{ iterations, warmup });
    try stdout.print("{s:<30} {s:>12} {s:>12} {s:>12}\n", .{ "Benchmark", "Min (ns)", "Mean (ns)", "Max (ns)" });
    try stdout.print("{s}\n", .{"-" ** 70});

    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, "bench_")) {
            const func = @field(@This(), decl.name);
            var times: [1024]u64 = undefined;
            const n = @min(iterations, times.len);

            // Warmup
            for (0..warmup) |_| {
                _ = @call(.never_inline, func, .{});
            }

            // Measure
            for (0..n) |i| {
                const start = std.time.nanoTimestamp();
                _ = @call(.never_inline, func, .{});
                const end = std.time.nanoTimestamp();
                times[i] = @intCast(end - start);
            }

            // Stats
            var min_t: u64 = std.math.maxInt(u64);
            var max_t: u64 = 0;
            var sum: u64 = 0;
            for (times[0..n]) |t| {
                min_t = @min(min_t, t);
                max_t = @max(max_t, t);
                sum += t;
            }
            const mean = sum / n;

            try stdout.print("{s:<30} {d:>12} {d:>12} {d:>12}\n", .{
                decl.name, min_t, mean, max_t,
            });
        }
    }
}

// ---- Add your benchmark functions below ----

pub fn bench_array_sum() u64 {
    var sum: u64 = 0;
    for (0..10_000) |i| sum +%= i;
    return sum;
}

pub fn bench_hash_map_insert() u64 {
    var map = std.AutoHashMap(u64, u64).init(std.heap.page_allocator);
    defer map.deinit();
    for (0..100) |i| {
        map.put(i, i *% 31) catch {};
    }
    return map.count();
}

pub fn bench_mem_copy() u64 {
    var src: [4096]u8 = undefined;
    var dst: [4096]u8 = undefined;
    @memset(&src, 0xAA);
    @memcpy(&dst, &src);
    return dst[0];
}
BENCHEOF
    log_ok "Created sample benchmark: ${BENCH_FILE}"
fi

# --- Build and Run ---
log_info "Building benchmarks (ReleaseFast)..."

BENCH_BIN=".zig-cache/bench_runner"

if ! zig build-exe "$BENCH_FILE" \
    -OReleaseFast \
    --name bench_runner \
    --cache-dir .zig-cache \
    --global-cache-dir .zig-cache/global \
    -femit-bin="$BENCH_BIN" 2>&1; then
    log_error "Failed to compile benchmarks."
    exit 1
fi
log_ok "Build complete"

# --- Run Benchmarks ---
log_info "Running benchmarks..."
echo ""

RESULT=$("$BENCH_BIN" "$ITERATIONS" "$WARMUP" 2>&1)

case "$OUTPUT_FORMAT" in
    text)
        echo "$RESULT"
        ;;
    csv)
        echo "benchmark,min_ns,mean_ns,max_ns"
        echo "$RESULT" | tail -n +3 | while read -r name min mean max rest; do
            [[ "$name" == -* ]] && continue
            [[ -z "$name" ]] && continue
            echo "${name},${min},${mean},${max}"
        done
        ;;
    json)
        echo "{"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"zig_version\": \"$(zig version)\","
        echo "  \"iterations\": ${ITERATIONS},"
        echo "  \"warmup\": ${WARMUP},"
        echo "  \"benchmarks\": ["
        FIRST=true
        echo "$RESULT" | tail -n +3 | while read -r name min mean max rest; do
            [[ "$name" == -* ]] && continue
            [[ -z "$name" ]] && continue
            if [[ "$FIRST" == true ]]; then
                FIRST=false
            else
                echo ","
            fi
            printf '    {"name": "%s", "min_ns": %s, "mean_ns": %s, "max_ns": %s}' \
                "$name" "$min" "$mean" "$max"
        done
        echo ""
        echo "  ]"
        echo "}"
        ;;
    *)
        log_error "Unknown output format: ${OUTPUT_FORMAT}"
        exit 1
        ;;
esac

# --- Comparison ---
if [[ -n "$COMPARE_FILE" ]] && [[ -f "$COMPARE_FILE" ]]; then
    echo ""
    log_info "Comparing with: ${COMPARE_FILE}"
    echo ""
    echo -e "${CYAN}Benchmark               Current (ns)  Previous (ns)  Change${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo "$RESULT" | tail -n +3 | while read -r name min mean max rest; do
        [[ "$name" == -* ]] && continue
        [[ -z "$name" ]] && continue

        prev_mean=$(grep -o "\"name\": \"${name}\"[^}]*\"mean_ns\": [0-9]*" "$COMPARE_FILE" 2>/dev/null \
            | grep -o '[0-9]*$' || echo "")

        if [[ -n "$prev_mean" ]] && [[ "$prev_mean" -gt 0 ]]; then
            if [[ "$mean" -gt 0 ]]; then
                change=$(( (mean - prev_mean) * 100 / prev_mean ))
                if [[ $change -lt -5 ]]; then
                    indicator="${GREEN}↓ ${change}%${NC}"
                elif [[ $change -gt 5 ]]; then
                    indicator="${RED}↑ +${change}%${NC}"
                else
                    indicator="~ ${change}%"
                fi
            else
                indicator="N/A"
            fi
            printf "%-24s %12s  %13s  %b\n" "$name" "$mean" "$prev_mean" "$indicator"
        else
            printf "%-24s %12s  %13s  %s\n" "$name" "$mean" "N/A" "new"
        fi
    done
fi

# --- Cleanup ---
rm -f "$BENCH_BIN"

echo ""
log_ok "Benchmarks complete"
