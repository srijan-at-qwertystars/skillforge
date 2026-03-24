#!/usr/bin/env bash
# monitor-cloud-run.sh — Check Cloud Run service health, revision traffic,
# and latency metrics using gcloud.
#
# Usage:
#   ./monitor-cloud-run.sh health  <service> [region]    # Service health + readiness
#   ./monitor-cloud-run.sh traffic <service> [region]    # Revision traffic split details
#   ./monitor-cloud-run.sh metrics <service> [region]    # Latency, request count, error rate
#   ./monitor-cloud-run.sh logs    <service> [region]    # Recent error logs
#   ./monitor-cloud-run.sh all     <service> [region]    # Run all checks
#
# Environment variables:
#   CLOUD_RUN_REGION    Default region (default: us-central1)

set -euo pipefail

DEFAULT_REGION="${CLOUD_RUN_REGION:-us-central1}"

log()  { echo "=== $* ==="; }
info() { echo "  $*"; }

cmd_health() {
    local service="$1" region="$2"
    log "Service Health: $service ($region)"

    # Basic service info
    local url status
    url=$(gcloud run services describe "$service" --region="$region" \
        --format="value(status.url)" 2>/dev/null) || { info "ERROR: Service not found"; return 1; }
    status=$(gcloud run services describe "$service" --region="$region" \
        --format="value(status.conditions[0].status)" 2>/dev/null)

    info "URL:    $url"
    info "Ready:  $status"

    # Conditions
    echo ""
    info "Conditions:"
    gcloud run services describe "$service" --region="$region" \
        --format="table(status.conditions[].type,status.conditions[].status,status.conditions[].message)" 2>/dev/null \
        | sed 's/^/    /'

    # Latest revision
    echo ""
    local latest
    latest=$(gcloud run services describe "$service" --region="$region" \
        --format="value(status.latestReadyRevisionName)" 2>/dev/null)
    info "Latest ready revision: $latest"

    # Quick HTTP check
    if [[ -n "$url" ]]; then
        echo ""
        info "HTTP check:"
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -H "Authorization: Bearer $(gcloud auth print-identity-token 2>/dev/null || echo '')" \
            "$url/" 2>/dev/null) || http_code="timeout"
        info "  Response: $http_code"
    fi
}

cmd_traffic() {
    local service="$1" region="$2"
    log "Traffic Allocation: $service ($region)"

    gcloud run services describe "$service" --region="$region" \
        --format="yaml(status.traffic)" 2>/dev/null | sed 's/^/  /'

    echo ""
    log "Active Revisions"
    gcloud run revisions list --service="$service" --region="$region" \
        --limit=10 \
        --format="table(name,active,spec.containers[0].resources.limits.cpu,spec.containers[0].resources.limits.memory,metadata.creationTimestamp)" 2>/dev/null \
        | sed 's/^/  /'
}

cmd_metrics() {
    local service="$1" region="$2"
    log "Metrics: $service ($region)"

    local project
    project=$(gcloud config get-value project 2>/dev/null)

    # Request count (last 1 hour)
    echo ""
    info "Request count (last 1h):"
    gcloud monitoring time-series list \
        --project="$project" \
        --filter="metric.type=\"run.googleapis.com/request_count\" AND resource.labels.service_name=\"$service\"" \
        --interval-start-time="$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ')" \
        --format="table(metric.labels.response_code_class,points[0].value.int64Value)" \
        2>/dev/null | sed 's/^/    /' || info "    (monitoring API not available or no data)"

    # Request latencies (last 1 hour)
    echo ""
    info "Request latency p50/p95/p99 (last 1h):"
    gcloud monitoring time-series list \
        --project="$project" \
        --filter="metric.type=\"run.googleapis.com/request_latencies\" AND resource.labels.service_name=\"$service\"" \
        --interval-start-time="$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ')" \
        --format="table(points[0].value.distributionValue.mean)" \
        2>/dev/null | sed 's/^/    /' || info "    (monitoring API not available or no data)"

    # Instance count
    echo ""
    info "Instance count (current):"
    gcloud monitoring time-series list \
        --project="$project" \
        --filter="metric.type=\"run.googleapis.com/container/instance_count\" AND resource.labels.service_name=\"$service\"" \
        --interval-start-time="$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')" \
        --format="table(metric.labels.state,points[0].value.int64Value)" \
        2>/dev/null | sed 's/^/    /' || info "    (monitoring API not available or no data)"

    # Container resource usage
    echo ""
    info "Resource configuration:"
    gcloud run services describe "$service" --region="$region" \
        --format="table(spec.template.spec.containers[0].resources.limits.cpu,spec.template.spec.containers[0].resources.limits.memory,spec.template.spec.containerConcurrency,spec.template.spec.timeoutSeconds)" 2>/dev/null \
        | sed 's/^/    /'
}

cmd_logs() {
    local service="$1" region="$2"
    log "Recent Errors: $service ($region)"

    echo ""
    info "Last 20 error-level log entries:"
    gcloud logging read "resource.type=\"cloud_run_revision\" AND \
        resource.labels.service_name=\"$service\" AND \
        resource.labels.location=\"$region\" AND \
        severity>=ERROR" \
        --limit=20 \
        --format="table(timestamp,severity,textPayload)" \
        2>/dev/null | sed 's/^/    /' || info "    (no errors found or logging API not available)"

    echo ""
    info "Last 10 request errors (4xx/5xx):"
    gcloud logging read "resource.type=\"cloud_run_revision\" AND \
        resource.labels.service_name=\"$service\" AND \
        resource.labels.location=\"$region\" AND \
        httpRequest.status>=400" \
        --limit=10 \
        --format="table(timestamp,httpRequest.status,httpRequest.requestUrl,httpRequest.latency)" \
        2>/dev/null | sed 's/^/    /' || info "    (no request errors found)"
}

cmd_all() {
    local service="$1" region="$2"
    cmd_health "$service" "$region"
    echo ""
    cmd_traffic "$service" "$region"
    echo ""
    cmd_metrics "$service" "$region"
    echo ""
    cmd_logs "$service" "$region"
}

# --- Main ---
ACTION="${1:-}"
SERVICE="${2:-}"
REGION="${3:-$DEFAULT_REGION}"

case "$ACTION" in
    health|traffic|metrics|logs|all)
        [[ -z "$SERVICE" ]] && { echo "Usage: $0 $ACTION <service> [region]"; exit 1; }
        "cmd_$ACTION" "$SERVICE" "$REGION"
        ;;
    *)
        echo "Usage: $0 {health|traffic|metrics|logs|all} <service> [region]"
        echo ""
        echo "Commands:"
        echo "  health   Show service status, conditions, and HTTP check"
        echo "  traffic  Show revision traffic allocation"
        echo "  metrics  Show request count, latency, instance count"
        echo "  logs     Show recent error logs"
        echo "  all      Run all checks"
        exit 1
        ;;
esac
