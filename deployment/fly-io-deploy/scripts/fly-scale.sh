#!/usr/bin/env bash
#
# fly-scale.sh — Scale Fly.io machines across regions
#
# Usage:
#   ./fly-scale.sh <action> [options]
#
# Actions:
#   scale-up       Increase machine count in a region
#   scale-down     Decrease machine count in a region
#   add-region     Add machines to a new region
#   remove-region  Remove all machines from a region
#   status         Show current scaling across all regions
#
# Options:
#   -a, --app      App name (or uses FLY_APP env var, or fly.toml)
#   -c, --count    Number of machines (default: 2)
#   -r, --region   Region code (e.g., iad, cdg, nrt)
#   -s, --size     VM size (e.g., shared-cpu-1x, performance-2x)
#   -g, --group    Process group (e.g., web, worker)
#
# Examples:
#   ./fly-scale.sh scale-up -a my-app -c 3 -r iad
#   ./fly-scale.sh add-region -a my-app -r cdg -c 2
#   ./fly-scale.sh remove-region -a my-app -r nrt
#   ./fly-scale.sh scale-down -a my-app -c 1 -r iad
#   ./fly-scale.sh status -a my-app
#
# Prerequisites:
#   - flyctl installed and authenticated

set -euo pipefail

# --- Defaults ---
ACTION=""
APP=""
COUNT=2
REGION=""
SIZE=""
GROUP=""

# --- Parse Arguments ---

usage() {
  echo "Usage: $0 <action> [options]"
  echo ""
  echo "Actions: scale-up, scale-down, add-region, remove-region, status"
  echo ""
  echo "Options:"
  echo "  -a, --app      App name"
  echo "  -c, --count    Machine count (default: 2)"
  echo "  -r, --region   Region code (e.g., iad, cdg)"
  echo "  -s, --size     VM size (e.g., shared-cpu-1x)"
  echo "  -g, --group    Process group (e.g., web, worker)"
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

ACTION="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--app)    APP="$2"; shift 2 ;;
    -c|--count)  COUNT="$2"; shift 2 ;;
    -r|--region) REGION="$2"; shift 2 ;;
    -s|--size)   SIZE="$2"; shift 2 ;;
    -g|--group)  GROUP="$2"; shift 2 ;;
    *)           echo "Unknown option: $1"; usage ;;
  esac
done

# --- Resolve App Name ---

if [[ -z "$APP" ]]; then
  if [[ -n "${FLY_APP:-}" ]]; then
    APP="$FLY_APP"
  elif [[ -f "fly.toml" ]]; then
    APP=$(grep '^app\s*=' fly.toml | head -1 | sed 's/app\s*=\s*"\?\([^"]*\)"\?/\1/' | tr -d '[:space:]')
  fi
fi

if [[ -z "$APP" ]]; then
  echo "Error: app name required. Use -a flag, FLY_APP env var, or run from directory with fly.toml."
  exit 1
fi

echo "App: $APP"

# --- Build flyctl flags ---

build_flags() {
  local flags="-a $APP"
  if [[ -n "$REGION" ]]; then
    flags="$flags --region $REGION"
  fi
  echo "$flags"
}

# --- Actions ---

case "$ACTION" in
  scale-up)
    if [[ -z "$REGION" ]]; then
      echo "Error: --region required for scale-up"
      exit 1
    fi
    echo "Scaling up $APP to $COUNT machines in $REGION..."
    group_arg=""
    if [[ -n "$GROUP" ]]; then
      group_arg="${GROUP}="
    fi
    fly scale count ${group_arg}${COUNT} --region "$REGION" -a "$APP" --yes
    if [[ -n "$SIZE" ]]; then
      echo "Setting VM size to $SIZE..."
      size_flags="-a $APP"
      if [[ -n "$GROUP" ]]; then
        size_flags="$size_flags --process-group $GROUP"
      fi
      fly scale vm "$SIZE" $size_flags
    fi
    echo "Scale up complete."
    fly status -a "$APP"
    ;;

  scale-down)
    if [[ -z "$REGION" ]]; then
      echo "Error: --region required for scale-down"
      exit 1
    fi
    echo "Scaling down $APP to $COUNT machines in $REGION..."
    group_arg=""
    if [[ -n "$GROUP" ]]; then
      group_arg="${GROUP}="
    fi
    fly scale count ${group_arg}${COUNT} --region "$REGION" -a "$APP" --yes
    echo "Scale down complete."
    fly status -a "$APP"
    ;;

  add-region)
    if [[ -z "$REGION" ]]; then
      echo "Error: --region required for add-region"
      exit 1
    fi
    echo "Adding $COUNT machines in region $REGION for $APP..."

    # Check if volumes are needed
    if grep -q '^\[mounts\]' fly.toml 2>/dev/null; then
      VOL_NAME=$(grep 'source' fly.toml | head -1 | sed 's/.*=\s*"\?\([^"]*\)"\?/\1/' | tr -d '[:space:]')
      if [[ -n "$VOL_NAME" ]]; then
        echo "Creating $COUNT volume(s) '$VOL_NAME' in $REGION..."
        for i in $(seq 1 "$COUNT"); do
          fly volumes create "$VOL_NAME" --region "$REGION" --size 1 -a "$APP" --yes
        done
      fi
    fi

    group_arg=""
    if [[ -n "$GROUP" ]]; then
      group_arg="${GROUP}="
    fi
    fly scale count ${group_arg}${COUNT} --region "$REGION" -a "$APP" --yes

    if [[ -n "$SIZE" ]]; then
      echo "Setting VM size to $SIZE..."
      fly scale vm "$SIZE" -a "$APP"
    fi

    echo "Region $REGION added."
    fly status -a "$APP"
    ;;

  remove-region)
    if [[ -z "$REGION" ]]; then
      echo "Error: --region required for remove-region"
      exit 1
    fi
    echo "Removing all machines from region $REGION for $APP..."
    group_arg=""
    if [[ -n "$GROUP" ]]; then
      group_arg="${GROUP}="
    fi
    fly scale count ${group_arg}0 --region "$REGION" -a "$APP" --yes
    echo "Region $REGION removed."
    fly status -a "$APP"
    ;;

  status)
    echo "Current scaling status for $APP:"
    echo ""
    fly status -a "$APP"
    echo ""
    fly scale show -a "$APP"
    echo ""
    echo "Volumes:"
    fly volumes list -a "$APP" 2>/dev/null || echo "  No volumes"
    ;;

  *)
    echo "Error: unknown action '$ACTION'"
    usage
    ;;
esac
