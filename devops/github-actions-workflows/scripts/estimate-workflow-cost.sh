#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# estimate-workflow-cost.sh
#
# Estimates GitHub Actions usage cost for a workflow file.
#
# Usage:
#   ./estimate-workflow-cost.sh <WORKFLOW_FILE> [OPTIONS]
#
# Arguments:
#   WORKFLOW_FILE  Path to a GitHub Actions workflow YAML file
#
# Options:
#   --minutes-per-job MIN  Override estimated minutes per job (default: 5)
#   --help                 Show this help message
#
# Pricing (per-minute rates for GitHub-hosted runners, as of 2024):
#   Linux (ubuntu):   $0.008/min  (1x multiplier)
#   Windows:          $0.016/min  (2x multiplier)
#   macOS:            $0.08/min   (10x multiplier)
#   Large runners:    varies (estimated at standard rate × core multiplier)
#
# Output:
#   - Per-job breakdown: runner type, matrix dimensions, estimated cost
#   - Total estimated cost per workflow run
#
# Notes:
#   - Estimates are approximate; actual costs depend on execution time
#   - Matrix expansion is calculated as the product of dimension sizes
#   - Requires python3 for YAML parsing
##############################################################################

WORKFLOW_FILE=""
MINUTES_PER_JOB=5

usage() {
    sed -n '/^##/,/^##/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --minutes-per-job)
            MINUTES_PER_JOB="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            if [[ -z "$WORKFLOW_FILE" ]]; then
                WORKFLOW_FILE="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$WORKFLOW_FILE" ]]; then
    echo "Error: WORKFLOW_FILE is required"
    echo "Usage: $0 <WORKFLOW_FILE> [--minutes-per-job MIN]"
    exit 1
fi

if [[ ! -f "$WORKFLOW_FILE" ]]; then
    echo "Error: File not found: ${WORKFLOW_FILE}"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required for YAML parsing"
    exit 1
fi

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
RESET='\033[0m'

# Use python3 to parse YAML and extract job info
python3 - "$WORKFLOW_FILE" "$MINUTES_PER_JOB" << 'PYEOF'
import yaml
import sys
import os
from itertools import product

workflow_file = sys.argv[1]
default_minutes = int(sys.argv[2])

# ANSI codes
BOLD = '\033[1m'
CYAN = '\033[0;36m'
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
DIM = '\033[2m'
RESET = '\033[0m'

# GitHub Actions pricing per minute (USD)
PRICING = {
    'linux':   0.008,
    'windows': 0.016,
    'macos':   0.08,
}

MULTIPLIER_LABELS = {
    'linux':   '1x',
    'windows': '2x',
    'macos':   '10x',
}

def detect_runner_os(runs_on):
    """Determine the OS category from a runs-on value."""
    if isinstance(runs_on, list):
        # Self-hosted or label list — assume linux as fallback
        labels = [str(l).lower() for l in runs_on]
        for label in labels:
            if 'macos' in label or 'mac' in label:
                return 'macos'
            if 'windows' in label or 'win' in label:
                return 'windows'
        return 'linux'

    val = str(runs_on).lower()
    # Handle matrix expressions
    if '${{' in val:
        return None  # Will be resolved per-matrix value
    if 'macos' in val or 'mac' in val:
        return 'macos'
    if 'windows' in val or 'win' in val:
        return 'windows'
    return 'linux'


def get_matrix_combinations(matrix_def):
    """Calculate total combinations from a matrix strategy."""
    if not isinstance(matrix_def, dict):
        return 1, {}

    include = matrix_def.get('include', [])
    exclude = matrix_def.get('exclude', [])

    # Extract dimension lists (skip include/exclude/fail-fast)
    dimensions = {}
    for key, value in matrix_def.items():
        if key in ('include', 'exclude', 'fail-fast'):
            continue
        if isinstance(value, list):
            dimensions[key] = value

    if not dimensions:
        # Only include entries
        return max(len(include), 1), dimensions

    # Total = product of dimension sizes + include entries - exclude entries
    total = 1
    for values in dimensions.values():
        total *= len(values)

    total += len(include)
    total = max(total - len(exclude), 1)

    return total, dimensions


def detect_matrix_os_values(matrix_def, runs_on_str):
    """If runs-on uses a matrix variable for OS, extract the OS values."""
    if not isinstance(matrix_def, dict):
        return None

    runs_on_lower = str(runs_on_str).lower()

    for key, values in matrix_def.items():
        if key in ('include', 'exclude', 'fail-fast'):
            continue
        # Check if the runs-on references this matrix key
        if f'matrix.{key}' in runs_on_lower or f"matrix['{key}']" in runs_on_lower:
            if isinstance(values, list):
                return values
    return None


try:
    with open(workflow_file) as f:
        workflow = yaml.safe_load(f)
except Exception as e:
    print(f"Error parsing YAML: {e}")
    sys.exit(1)

if not workflow or 'jobs' not in workflow:
    print("Error: No 'jobs' key found in workflow")
    sys.exit(1)

workflow_name = workflow.get('name', os.path.basename(workflow_file))
jobs = workflow['jobs']

print(f"{BOLD}Workflow Cost Estimate: {workflow_name}{RESET}")
print(f"{DIM}File: {workflow_file}{RESET}")
print(f"{DIM}Assumed minutes per job: {default_minutes}{RESET}")
print()

total_cost = 0.0
total_jobs = 0

print(f"{'Job':<30} {'Runner':<18} {'Matrix':<12} {'Jobs':<6} {'Min':<6} {'Cost':>10}")
print(f"{'─'*30} {'─'*18} {'─'*12} {'─'*6} {'─'*6} {'─':─>10}")

for job_id, job_def in jobs.items():
    if not isinstance(job_def, dict):
        continue

    runs_on = job_def.get('runs-on', 'ubuntu-latest')
    strategy = job_def.get('strategy', {})
    matrix_def = strategy.get('matrix', {}) if isinstance(strategy, dict) else {}

    combinations, dimensions = get_matrix_combinations(matrix_def)

    # Check if runs-on uses a matrix variable for OS
    os_values = detect_matrix_os_values(matrix_def, runs_on)

    if os_values:
        # Mixed OS matrix: calculate cost for each OS separately
        non_os_combos = max(combinations // len(os_values), 1)
        job_cost = 0.0
        job_total_jobs = 0

        for os_val in os_values:
            runner_os = detect_runner_os(os_val)
            if runner_os is None:
                runner_os = 'linux'
            rate = PRICING.get(runner_os, PRICING['linux'])
            sub_jobs = non_os_combos
            sub_minutes = sub_jobs * default_minutes
            sub_cost = sub_minutes * rate
            job_cost += sub_cost
            job_total_jobs += sub_jobs

        dim_str = 'x'.join(f"{len(v)}" for k, v in dimensions.items() if isinstance(v, list))
        if not dim_str:
            dim_str = f"{combinations}"

        total_minutes = job_total_jobs * default_minutes
        print(f"{job_id:<30} {'(mixed OS)':<18} {dim_str:<12} {job_total_jobs:<6} {total_minutes:<6} ${job_cost:>9.4f}")

        total_cost += job_cost
        total_jobs += job_total_jobs
    else:
        runner_os = detect_runner_os(runs_on)
        if runner_os is None:
            runner_os = 'linux'

        rate = PRICING.get(runner_os, PRICING['linux'])
        runner_label = str(runs_on) if not isinstance(runs_on, list) else ','.join(str(r) for r in runs_on)
        if len(runner_label) > 18:
            runner_label = runner_label[:15] + '...'

        multiplier = MULTIPLIER_LABELS.get(runner_os, '1x')

        dim_str = 'x'.join(f"{len(v)}" for k, v in dimensions.items() if isinstance(v, list))
        if not dim_str:
            dim_str = '1'

        num_jobs = combinations
        total_minutes = num_jobs * default_minutes
        cost = total_minutes * rate

        print(f"{job_id:<30} {runner_label:<18} {dim_str:<12} {num_jobs:<6} {total_minutes:<6} ${cost:>9.4f}")

        total_cost += cost
        total_jobs += num_jobs

print(f"{'─'*30} {'─'*18} {'─'*12} {'─'*6} {'─'*6} {'─':─>10}")
print(f"{'TOTAL':<30} {'':<18} {'':<12} {total_jobs:<6} {total_jobs * default_minutes:<6} ${total_cost:>9.4f}")
print()

# Monthly estimate
runs_per_day = 5
monthly_runs = runs_per_day * 30
monthly_cost = total_cost * monthly_runs

print(f"{BOLD}Projections{RESET}")
print(f"  Per run:                  ${total_cost:.4f}")
print(f"  Per day ({runs_per_day} runs):         ${total_cost * runs_per_day:.4f}")
print(f"  Per month (~{monthly_runs} runs):    ${monthly_cost:.4f}")
print()
print(f"{DIM}Note: Estimates assume {default_minutes} min/job. Actual costs depend on execution time.{RESET}")
print(f"{DIM}GitHub-hosted runner rates: Linux $0.008/min, Windows $0.016/min, macOS $0.08/min{RESET}")
print(f"{DIM}Free tier: 2,000 min/month (Linux) for public repos / GitHub Free plans.{RESET}")

PYEOF
