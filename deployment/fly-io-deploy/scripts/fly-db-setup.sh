#!/usr/bin/env bash
#
# fly-db-setup.sh — Set up Fly Postgres cluster with optional read replicas
#
# Usage:
#   ./fly-db-setup.sh <app-name> <primary-region> [replica-regions...]
#
# Arguments:
#   app-name         Required. Name for the Postgres app (e.g., my-app-db).
#   primary-region   Required. Region for primary Postgres (e.g., iad).
#   replica-regions  Optional. Space-separated regions for read replicas (e.g., cdg nrt).
#
# Options:
#   --attach <app>   Attach database to this Fly app (sets DATABASE_URL secret).
#   --size <vm>      VM size for Postgres (default: shared-cpu-1x).
#   --volume <gb>    Volume size in GB (default: 10).
#   --ha             Enable high-availability (2 nodes in primary region).
#
# Examples:
#   ./fly-db-setup.sh my-db iad
#   ./fly-db-setup.sh my-db iad cdg nrt --attach my-app
#   ./fly-db-setup.sh my-db iad --ha --size shared-cpu-2x --volume 20
#   ./fly-db-setup.sh my-db iad cdg --attach my-app --ha --volume 20
#
# Prerequisites:
#   - flyctl installed and authenticated
#   - Sufficient org permissions to create Postgres clusters

set -euo pipefail

# --- Defaults ---
DB_NAME=""
PRIMARY_REGION=""
REPLICA_REGIONS=()
ATTACH_APP=""
VM_SIZE="shared-cpu-1x"
VOLUME_SIZE=10
HA=false

# --- Parse Arguments ---

usage() {
  echo "Usage: $0 <app-name> <primary-region> [replica-regions...] [options]"
  echo ""
  echo "Options:"
  echo "  --attach <app>   Attach to a Fly app"
  echo "  --size <vm>      VM size (default: shared-cpu-1x)"
  echo "  --volume <gb>    Volume size in GB (default: 10)"
  echo "  --ha             Enable high-availability"
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
fi

DB_NAME="$1"; shift
PRIMARY_REGION="$1"; shift

# Parse remaining args: positional regions first, then flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --attach)  ATTACH_APP="$2"; shift 2 ;;
    --size)    VM_SIZE="$2"; shift 2 ;;
    --volume)  VOLUME_SIZE="$2"; shift 2 ;;
    --ha)      HA=true; shift ;;
    --help|-h) usage ;;
    --*)       echo "Unknown option: $1"; usage ;;
    *)         REPLICA_REGIONS+=("$1"); shift ;;
  esac
done

echo "============================================"
echo "  Fly Postgres Setup"
echo "============================================"
echo "  Database:     $DB_NAME"
echo "  Primary:      $PRIMARY_REGION"
echo "  VM Size:      $VM_SIZE"
echo "  Volume:       ${VOLUME_SIZE}GB"
echo "  HA:           $HA"
if [[ ${#REPLICA_REGIONS[@]} -gt 0 ]]; then
  echo "  Replicas:     ${REPLICA_REGIONS[*]}"
fi
if [[ -n "$ATTACH_APP" ]]; then
  echo "  Attach to:    $ATTACH_APP"
fi
echo "============================================"
echo ""

# --- Create Primary Cluster ---

echo "Creating Postgres cluster '$DB_NAME' in $PRIMARY_REGION..."

CREATE_FLAGS="--name $DB_NAME --region $PRIMARY_REGION --vm-size $VM_SIZE --volume-size $VOLUME_SIZE"

if [[ "$HA" == true ]]; then
  CREATE_FLAGS="$CREATE_FLAGS --initial-cluster-size 2"
else
  CREATE_FLAGS="$CREATE_FLAGS --initial-cluster-size 1"
fi

fly postgres create $CREATE_FLAGS

echo ""
echo "Primary cluster created successfully."

# --- Wait for Primary to be Ready ---

echo "Waiting for primary to become healthy..."
sleep 10

MAX_RETRIES=30
for i in $(seq 1 $MAX_RETRIES); do
  if fly status -a "$DB_NAME" 2>/dev/null | grep -q "started"; then
    echo "Primary is healthy."
    break
  fi
  if [[ $i -eq $MAX_RETRIES ]]; then
    echo "Warning: primary may not be fully ready yet. Proceeding anyway."
  fi
  sleep 5
done

# --- Create Read Replicas ---

if [[ ${#REPLICA_REGIONS[@]} -gt 0 ]]; then
  echo ""
  echo "Setting up read replicas..."

  # Get primary machine ID
  PRIMARY_MACHINE_ID=$(fly machine list -a "$DB_NAME" --json 2>/dev/null | \
    python3 -c "import sys,json; machines=json.load(sys.stdin); print(machines[0]['id'])" 2>/dev/null || echo "")

  if [[ -z "$PRIMARY_MACHINE_ID" ]]; then
    echo "Warning: Could not detect primary machine ID automatically."
    echo "You can create replicas manually with:"
    for REGION in "${REPLICA_REGIONS[@]}"; do
      echo "  fly machines clone <primary-machine-id> --region $REGION -a $DB_NAME"
    done
  else
    for REGION in "${REPLICA_REGIONS[@]}"; do
      echo "Creating read replica in $REGION..."
      fly machines clone "$PRIMARY_MACHINE_ID" --region "$REGION" -a "$DB_NAME"
      echo "Replica in $REGION created."
      sleep 5
    done
  fi

  echo ""
  echo "All replicas created."
fi

# --- Attach to Application ---

if [[ -n "$ATTACH_APP" ]]; then
  echo ""
  echo "Attaching $DB_NAME to $ATTACH_APP..."
  fly postgres attach "$DB_NAME" -a "$ATTACH_APP"
  echo "Database attached. DATABASE_URL secret has been set on $ATTACH_APP."
fi

# --- Final Status ---

echo ""
echo "============================================"
echo "  Postgres Cluster Status"
echo "============================================"
fly status -a "$DB_NAME"

echo ""
echo "============================================"
echo "  Connection Info"
echo "============================================"
echo "  Internal: postgres://...@${DB_NAME}.internal:5432"
echo "  Console:  fly postgres connect -a ${DB_NAME}"
echo "  Proxy:    fly proxy 5432:5432 -a ${DB_NAME}"
echo ""

if [[ ${#REPLICA_REGIONS[@]} -gt 0 ]]; then
  echo "Multi-region notes:"
  echo "  - Set PRIMARY_REGION=$PRIMARY_REGION in your app's fly.toml [env]"
  echo "  - Add fly-replay middleware for write forwarding (see references/multi-region-guide.md)"
  echo "  - Monitor replication lag: fly postgres connect -a $DB_NAME -C \"SELECT now() - pg_last_xact_replay_timestamp();\""
  echo ""
fi

echo "Next steps:"
echo "  1. Verify connection: fly postgres connect -a $DB_NAME"
if [[ -z "$ATTACH_APP" ]]; then
  echo "  2. Attach to your app: fly postgres attach $DB_NAME -a <your-app>"
fi
echo "  3. Run migrations: fly ssh console -a <your-app> -C 'bin/rails db:migrate'"
echo "  4. Set up backups: fly postgres barman-backup -a $DB_NAME"
