#!/usr/bin/env bash
#
# capacity-calculator.sh — Calculate DynamoDB RCU/WCU requirements and costs
#
# Usage:
#   ./capacity-calculator.sh
#   ./capacity-calculator.sh --item-size 2.5 --reads 500 --writes 200 --consistency eventual
#   ./capacity-calculator.sh --item-size 4 --reads 1000 --writes 100 --consistency strong --gsi-count 3 --gsi-item-size 1
#   ./capacity-calculator.sh --help
#
# Parameters:
#   --item-size      Average item size in KB (default: 1)
#   --reads          Read requests per second (default: 100)
#   --writes         Write requests per second (default: 50)
#   --consistency    Read consistency: eventual or strong (default: eventual)
#   --transactional  Use transactional reads/writes (doubles cost)
#   --gsi-count      Number of GSIs (default: 0)
#   --gsi-item-size  Average GSI projected item size in KB (default: same as item-size)
#   --region         AWS region for pricing (default: us-east-1)
#
# Outputs: Required RCU/WCU, estimated monthly cost for provisioned and on-demand modes.
#

set -euo pipefail

# --- Defaults ---
ITEM_SIZE_KB=1
READS_PER_SEC=100
WRITES_PER_SEC=50
CONSISTENCY="eventual"
TRANSACTIONAL=false
GSI_COUNT=0
GSI_ITEM_SIZE_KB=""
REGION="us-east-1"
INTERACTIVE=true

# --- Pricing (us-east-1, as of 2024) ---
PROVISIONED_WCU_HOURLY=0.00065
PROVISIONED_RCU_HOURLY=0.00013
ONDEMAND_WRU=0.00000125   # per write request unit
ONDEMAND_RRU=0.00000025   # per read request unit
HOURS_PER_MONTH=730
SECONDS_PER_MONTH=2628000

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --item-size) ITEM_SIZE_KB="$2"; INTERACTIVE=false; shift 2 ;;
        --reads) READS_PER_SEC="$2"; INTERACTIVE=false; shift 2 ;;
        --writes) WRITES_PER_SEC="$2"; INTERACTIVE=false; shift 2 ;;
        --consistency) CONSISTENCY="$2"; shift 2 ;;
        --transactional) TRANSACTIONAL=true; shift ;;
        --gsi-count) GSI_COUNT="$2"; shift 2 ;;
        --gsi-item-size) GSI_ITEM_SIZE_KB="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        -h|--help) head -20 "$0" | tail -17; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Interactive mode ---
if [[ "$INTERACTIVE" == "true" ]]; then
    echo "=== DynamoDB Capacity Calculator ===" >&2
    echo "" >&2
    read -rp "Average item size in KB [1]: " val; ITEM_SIZE_KB="${val:-1}"
    read -rp "Read requests per second [100]: " val; READS_PER_SEC="${val:-100}"
    read -rp "Write requests per second [50]: " val; WRITES_PER_SEC="${val:-50}"
    read -rp "Read consistency (eventual/strong) [eventual]: " val; CONSISTENCY="${val:-eventual}"
    read -rp "Transactional operations? (y/n) [n]: " val
    [[ "${val:-n}" == "y" ]] && TRANSACTIONAL=true
    read -rp "Number of GSIs [0]: " val; GSI_COUNT="${val:-0}"
    if [[ "$GSI_COUNT" -gt 0 ]]; then
        read -rp "Average GSI projected item size in KB [$ITEM_SIZE_KB]: " val
        GSI_ITEM_SIZE_KB="${val:-$ITEM_SIZE_KB}"
    fi
    echo "" >&2
fi

[[ -z "$GSI_ITEM_SIZE_KB" ]] && GSI_ITEM_SIZE_KB="$ITEM_SIZE_KB"

# --- Calculations ---

# ceiling division: ceil(a / b)
ceildiv() {
    local a="$1" b="$2"
    echo $(( (a + b - 1) / b ))
}

# Convert KB to integer for ceiling math (multiply by 100 for precision)
item_size_x100=$(echo "$ITEM_SIZE_KB * 100" | bc | cut -d. -f1)
gsi_size_x100=$(echo "$GSI_ITEM_SIZE_KB * 100" | bc | cut -d. -f1)

# Read capacity: 1 RCU = 4KB strongly consistent, 8KB eventually consistent
read_unit_kb=400  # in hundredths
if [[ "$CONSISTENCY" == "eventual" ]]; then
    read_unit_kb=800
fi
rcu_per_read=$(ceildiv "$item_size_x100" "$read_unit_kb")

# Write capacity: 1 WCU = 1KB
wcu_per_write=$(ceildiv "$item_size_x100" 100)

# Transactional multiplier
tx_multiplier=1
if [[ "$TRANSACTIONAL" == "true" ]]; then
    tx_multiplier=2
fi

# Base table capacity
base_rcu=$(( READS_PER_SEC * rcu_per_read * tx_multiplier ))
base_wcu=$(( WRITES_PER_SEC * wcu_per_write * tx_multiplier ))

# GSI write capacity (each GSI replicates writes)
gsi_wcu_per_write=$(ceildiv "$gsi_size_x100" 100)
total_gsi_wcu=$(( GSI_COUNT * WRITES_PER_SEC * gsi_wcu_per_write ))

# Totals
total_rcu=$base_rcu
total_wcu=$(( base_wcu + total_gsi_wcu ))

# Cost calculations
provisioned_monthly_cost=$(echo "scale=2; ($total_rcu * $PROVISIONED_RCU_HOURLY + $total_wcu * $PROVISIONED_WCU_HOURLY) * $HOURS_PER_MONTH" | bc)

ondemand_read_monthly=$(echo "scale=2; $READS_PER_SEC * $SECONDS_PER_MONTH * $rcu_per_read * $tx_multiplier * $ONDEMAND_RRU" | bc)
ondemand_write_monthly=$(echo "scale=2; $WRITES_PER_SEC * $SECONDS_PER_MONTH * ($wcu_per_write + $GSI_COUNT * $gsi_wcu_per_write) * $tx_multiplier * $ONDEMAND_WRU" | bc)
ondemand_monthly_cost=$(echo "scale=2; $ondemand_read_monthly + $ondemand_write_monthly" | bc)

# Auto-scaling recommended (70% target utilization)
autoscale_rcu=$(echo "scale=0; $total_rcu * 100 / 70" | bc)
autoscale_wcu=$(echo "scale=0; $total_wcu * 100 / 70" | bc)

# --- Output ---

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           DynamoDB Capacity Estimation                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Input Parameters                                         ║"
echo "║──────────────────────────────────────────────────────────║"
printf "║  Item size:          %-10s KB                        ║\n" "$ITEM_SIZE_KB"
printf "║  Reads/sec:          %-10s                           ║\n" "$READS_PER_SEC"
printf "║  Writes/sec:         %-10s                           ║\n" "$WRITES_PER_SEC"
printf "║  Consistency:        %-10s                           ║\n" "$CONSISTENCY"
printf "║  Transactional:      %-10s                           ║\n" "$TRANSACTIONAL"
printf "║  GSI count:          %-10s                           ║\n" "$GSI_COUNT"
if [[ "$GSI_COUNT" -gt 0 ]]; then
printf "║  GSI item size:      %-10s KB                        ║\n" "$GSI_ITEM_SIZE_KB"
fi
echo "║                                                          ║"
echo "║ Required Capacity                                        ║"
echo "║──────────────────────────────────────────────────────────║"
printf "║  Base table RCU:     %-10s                           ║\n" "$base_rcu"
printf "║  Base table WCU:     %-10s                           ║\n" "$base_wcu"
if [[ "$GSI_COUNT" -gt 0 ]]; then
printf "║  GSI WCU (total):    %-10s                           ║\n" "$total_gsi_wcu"
fi
printf "║  ─────────────────────                                  ║\n"
printf "║  Total RCU:          %-10s                           ║\n" "$total_rcu"
printf "║  Total WCU:          %-10s                           ║\n" "$total_wcu"
echo "║                                                          ║"
echo "║ Auto-Scaling (70% target utilization)                    ║"
echo "║──────────────────────────────────────────────────────────║"
printf "║  Provisioned RCU:    %-10s                           ║\n" "$autoscale_rcu"
printf "║  Provisioned WCU:    %-10s                           ║\n" "$autoscale_wcu"
echo "║                                                          ║"
echo "║ Estimated Monthly Cost                                   ║"
echo "║──────────────────────────────────────────────────────────║"
printf "║  Provisioned mode:   \$%-10s /month                  ║\n" "$provisioned_monthly_cost"
printf "║  On-demand mode:     \$%-10s /month                  ║\n" "$ondemand_monthly_cost"
echo "║                                                          ║"

if (( $(echo "$ondemand_monthly_cost < $provisioned_monthly_cost" | bc -l) )); then
    echo "║  ★ Recommendation: On-demand is cheaper for this load   ║"
else
    savings=$(echo "scale=0; (1 - $provisioned_monthly_cost / $ondemand_monthly_cost) * 100" | bc)
    printf "║  ★ Recommendation: Provisioned saves ~%s%%              ║\n" "$savings"
fi
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"

# --- Formulas reference ---
echo ""
echo "Formulas:"
echo "  RCU (strong)    = reads/s × ⌈item_size / 4KB⌉"
echo "  RCU (eventual)  = reads/s × ⌈item_size / 4KB⌉ / 2"
echo "  WCU             = writes/s × ⌈item_size / 1KB⌉"
echo "  Transactional   = 2× standard cost"
echo "  GSI WCU         = GSI_count × writes/s × ⌈gsi_item_size / 1KB⌉"
