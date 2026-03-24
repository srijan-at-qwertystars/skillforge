#!/usr/bin/env bash
# deploy-cloud-run.sh — Deploy a Cloud Run service with environment detection,
# traffic management (canary/full), and rollback support.
#
# Usage:
#   ./deploy-cloud-run.sh deploy <service> <image> [region]     # Full deploy (100% traffic)
#   ./deploy-cloud-run.sh canary <service> <image> [region]     # Deploy with 0% traffic + canary tag
#   ./deploy-cloud-run.sh promote <service> [region]            # Send 100% traffic to latest
#   ./deploy-cloud-run.sh rollback <service> [region]           # Rollback to previous revision
#   ./deploy-cloud-run.sh status <service> [region]             # Show current traffic split
#
# Environment variables (optional overrides):
#   CLOUD_RUN_REGION          Default region (default: us-central1)
#   CLOUD_RUN_MIN_INSTANCES   Min instances (default: 0)
#   CLOUD_RUN_MAX_INSTANCES   Max instances (default: 100)
#   CLOUD_RUN_CPU             CPU allocation (default: 1)
#   CLOUD_RUN_MEMORY          Memory limit (default: 512Mi)
#   CLOUD_RUN_CONCURRENCY     Max concurrent requests (default: 80)
#   CLOUD_RUN_SA              Service account email
#   CLOUD_RUN_VPC_CONNECTOR   VPC connector name
#   CLOUD_RUN_ALLOW_UNAUTH    Set to "true" for public access

set -euo pipefail

# --- Defaults ---
DEFAULT_REGION="${CLOUD_RUN_REGION:-us-central1}"
MIN_INSTANCES="${CLOUD_RUN_MIN_INSTANCES:-0}"
MAX_INSTANCES="${CLOUD_RUN_MAX_INSTANCES:-100}"
CPU="${CLOUD_RUN_CPU:-1}"
MEMORY="${CLOUD_RUN_MEMORY:-512Mi}"
CONCURRENCY="${CLOUD_RUN_CONCURRENCY:-80}"
SA="${CLOUD_RUN_SA:-}"
VPC_CONNECTOR="${CLOUD_RUN_VPC_CONNECTOR:-}"
ALLOW_UNAUTH="${CLOUD_RUN_ALLOW_UNAUTH:-false}"

# --- Helpers ---
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

detect_environment() {
    local project
    project=$(gcloud config get-value project 2>/dev/null) || die "No active GCP project. Run: gcloud config set project PROJECT_ID"
    log "Project: $project"
    log "Region:  $1"
    log "Account: $(gcloud config get-value account 2>/dev/null)"
}

build_deploy_flags() {
    local flags=()
    flags+=(--cpu="$CPU" --memory="$MEMORY")
    flags+=(--min-instances="$MIN_INSTANCES" --max-instances="$MAX_INSTANCES")
    flags+=(--concurrency="$CONCURRENCY")
    [[ -n "$SA" ]] && flags+=(--service-account="$SA")
    [[ -n "$VPC_CONNECTOR" ]] && flags+=(--vpc-connector="$VPC_CONNECTOR")
    if [[ "$ALLOW_UNAUTH" == "true" ]]; then
        flags+=(--allow-unauthenticated)
    else
        flags+=(--no-allow-unauthenticated)
    fi
    echo "${flags[@]}"
}

# --- Commands ---
cmd_deploy() {
    local service="$1" image="$2" region="$3"
    detect_environment "$region"
    log "Deploying $service with image $image (full traffic)"

    local flags
    flags=$(build_deploy_flags)
    # shellcheck disable=SC2086
    gcloud run deploy "$service" \
        --image="$image" \
        --region="$region" \
        $flags \
        --quiet

    log "Deploy complete."
    gcloud run services describe "$service" --region="$region" \
        --format="value(status.url)"
}

cmd_canary() {
    local service="$1" image="$2" region="$3"
    detect_environment "$region"
    log "Deploying canary for $service with image $image (0% traffic)"

    local flags
    flags=$(build_deploy_flags)
    # shellcheck disable=SC2086
    gcloud run deploy "$service" \
        --image="$image" \
        --region="$region" \
        --no-traffic \
        --tag=canary \
        $flags \
        --quiet

    log "Canary deployed. Test URL:"
    gcloud run services describe "$service" --region="$region" \
        --format="yaml(status.traffic)" 2>/dev/null | grep -A1 "tag: canary" | grep url || true
    log "Run '$0 promote $service $region' to send 100% traffic."
}

cmd_promote() {
    local service="$1" region="$2"
    detect_environment "$region"
    log "Promoting latest revision to 100% traffic for $service"

    gcloud run services update-traffic "$service" \
        --to-latest --region="$region" --quiet

    log "Promotion complete."
    cmd_status "$service" "$region"
}

cmd_rollback() {
    local service="$1" region="$2"
    detect_environment "$region"

    # Get the second-most-recent ready revision
    local revisions
    revisions=$(gcloud run revisions list --service="$service" --region="$region" \
        --format="value(name)" --sort-by="~creationTimestamp" --limit=5)

    local prev_rev
    prev_rev=$(echo "$revisions" | sed -n '2p')
    [[ -z "$prev_rev" ]] && die "No previous revision found to rollback to."

    log "Rolling back $service to revision: $prev_rev"
    gcloud run services update-traffic "$service" \
        --to-revisions="$prev_rev=100" --region="$region" --quiet

    log "Rollback complete."
    cmd_status "$service" "$region"
}

cmd_status() {
    local service="$1" region="$2"
    log "Traffic allocation for $service:"
    gcloud run services describe "$service" --region="$region" \
        --format="yaml(status.traffic)"
    echo ""
    log "Latest revisions:"
    gcloud run revisions list --service="$service" --region="$region" \
        --limit=5 --format="table(name,active,spec.containers[0].image)"
}

# --- Main ---
ACTION="${1:-}"
SERVICE="${2:-}"
case "$ACTION" in
    deploy|canary)
        IMAGE="${3:-}"
        REGION="${4:-$DEFAULT_REGION}"
        [[ -z "$SERVICE" || -z "$IMAGE" ]] && die "Usage: $0 $ACTION <service> <image> [region]"
        "cmd_$ACTION" "$SERVICE" "$IMAGE" "$REGION"
        ;;
    promote|rollback|status)
        REGION="${3:-$DEFAULT_REGION}"
        [[ -z "$SERVICE" ]] && die "Usage: $0 $ACTION <service> [region]"
        "cmd_$ACTION" "$SERVICE" "$REGION"
        ;;
    *)
        echo "Usage: $0 {deploy|canary|promote|rollback|status} <service> [image] [region]"
        echo ""
        echo "Commands:"
        echo "  deploy   <svc> <image> [region]  Deploy with 100% traffic"
        echo "  canary   <svc> <image> [region]  Deploy with 0% traffic + canary tag"
        echo "  promote  <svc> [region]          Route 100% to latest revision"
        echo "  rollback <svc> [region]          Route 100% to previous revision"
        echo "  status   <svc> [region]          Show traffic split and revisions"
        exit 1
        ;;
esac
