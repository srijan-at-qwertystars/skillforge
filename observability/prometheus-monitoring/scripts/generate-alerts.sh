#!/usr/bin/env bash
# generate-alerts.sh — Generate Prometheus alerting rules from templates.
#
# Creates alerting rule files for common scenarios: SLO-based alerts,
# infrastructure monitoring, and application health checks.
#
# Usage:
#   ./generate-alerts.sh [template] [options]
#
# Templates:
#   all           — Generate all rule sets (default)
#   slo           — SLO burn-rate alerts (multi-window, multi-burn-rate)
#   infra         — Infrastructure alerts (node, disk, network)
#   app           — Application alerts (RED method, error budget)
#   k8s           — Kubernetes cluster alerts
#   prometheus    — Prometheus self-monitoring alerts
#
# Options:
#   -o, --output DIR     Output directory (default: ./generated-rules)
#   -s, --slo-target N   SLO target as decimal (default: 0.999)
#   -l, --latency-ms N   Latency SLO threshold in ms (default: 300)
#   -n, --namespace NS   Kubernetes namespace filter (default: all)
#   --dry-run            Print to stdout instead of writing files
#
# Examples:
#   ./generate-alerts.sh all -o /etc/prometheus/rules/
#   ./generate-alerts.sh slo --slo-target 0.995
#   ./generate-alerts.sh infra --dry-run
#   ./generate-alerts.sh k8s -n production

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────

TEMPLATE="${1:-all}"
shift || true

OUTPUT_DIR="./generated-rules"
SLO_TARGET="0.999"
LATENCY_MS="300"
NAMESPACE=""
DRY_RUN=false

# ─── Parse options ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)     OUTPUT_DIR="$2"; shift 2 ;;
    -s|--slo-target) SLO_TARGET="$2"; shift 2 ;;
    -l|--latency-ms) LATENCY_MS="$2"; shift 2 ;;
    -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=true; shift ;;
    *)               echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Calculate error budget from SLO target
ERROR_BUDGET=$(echo "1 - ${SLO_TARGET}" | bc -l 2>/dev/null || python3 -c "print(1 - ${SLO_TARGET})")
LATENCY_SECS=$(echo "scale=3; ${LATENCY_MS} / 1000" | bc -l 2>/dev/null || python3 -c "print(${LATENCY_MS}/1000)")

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }

# ─── Output helper ────────────────────────────────────────────────────────────

write_rules() {
  local filename="$1"
  local content="$2"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "# === ${filename} ==="
    echo "${content}"
    echo ""
  else
    mkdir -p "${OUTPUT_DIR}"
    echo "${content}" > "${OUTPUT_DIR}/${filename}"
    log_info "Generated ${OUTPUT_DIR}/${filename}"
  fi
}

# ─── SLO burn-rate alerts ─────────────────────────────────────────────────────

generate_slo_rules() {
  local rules
  rules=$(cat << YAML
# SLO Burn Rate Alerts — Multi-window, multi-burn-rate
# SLO Target: ${SLO_TARGET} (error budget: ${ERROR_BUDGET})
# Reference: https://sre.google/workbook/alerting-on-slos/

groups:
  - name: slo_recording_rules
    interval: 30s
    rules:
      - record: slo:http_error_ratio:rate5m
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[5m]))
          / sum by (service) (rate(http_requests_total[5m]))
      - record: slo:http_error_ratio:rate30m
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[30m]))
          / sum by (service) (rate(http_requests_total[30m]))
      - record: slo:http_error_ratio:rate1h
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[1h]))
          / sum by (service) (rate(http_requests_total[1h]))
      - record: slo:http_error_ratio:rate2h
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[2h]))
          / sum by (service) (rate(http_requests_total[2h]))
      - record: slo:http_error_ratio:rate6h
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[6h]))
          / sum by (service) (rate(http_requests_total[6h]))
      - record: slo:http_error_ratio:rate1d
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[1d]))
          / sum by (service) (rate(http_requests_total[1d]))
      - record: slo:http_error_ratio:rate3d
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[3d]))
          / sum by (service) (rate(http_requests_total[3d]))

  - name: slo_availability_alerts
    rules:
      # 14.4x burn — budget exhausted in ~1h → page immediately
      - alert: SLOBudgetBurn_Critical_Fast
        expr: |
          slo:http_error_ratio:rate1h > (14.4 * ${ERROR_BUDGET})
          and
          slo:http_error_ratio:rate5m > (14.4 * ${ERROR_BUDGET})
        for: 2m
        labels:
          severity: critical
          slo: availability
          slo_target: "${SLO_TARGET}"
        annotations:
          summary: "{{ \$labels.service }} burning error budget at 14.4x"
          description: "1h error ratio: {{ \$value | humanizePercentage }}. Budget exhausted in ~1h."
          runbook_url: "https://runbooks.example.com/slo-budget-burn"

      # 6x burn — budget exhausted in ~5h → page
      - alert: SLOBudgetBurn_Critical_Slow
        expr: |
          slo:http_error_ratio:rate6h > (6 * ${ERROR_BUDGET})
          and
          slo:http_error_ratio:rate30m > (6 * ${ERROR_BUDGET})
        for: 5m
        labels:
          severity: critical
          slo: availability
          slo_target: "${SLO_TARGET}"
        annotations:
          summary: "{{ \$labels.service }} burning error budget at 6x"
          description: "6h error ratio: {{ \$value | humanizePercentage }}. Budget exhausted in ~5h."

      # 3x burn — budget exhausted in ~10d → ticket
      - alert: SLOBudgetBurn_Warning
        expr: |
          slo:http_error_ratio:rate1d > (3 * ${ERROR_BUDGET})
          and
          slo:http_error_ratio:rate2h > (3 * ${ERROR_BUDGET})
        for: 15m
        labels:
          severity: warning
          slo: availability
          slo_target: "${SLO_TARGET}"
        annotations:
          summary: "{{ \$labels.service }} burning error budget at 3x"

  - name: slo_latency_alerts
    rules:
      - alert: SLOLatencyBurn_Critical
        expr: |
          (
            1 - sum by (service) (rate(http_request_duration_seconds_bucket{le="${LATENCY_SECS}"}[1h]))
                / sum by (service) (rate(http_request_duration_seconds_count[1h]))
          ) > (14.4 * 0.005)
          and
          (
            1 - sum by (service) (rate(http_request_duration_seconds_bucket{le="${LATENCY_SECS}"}[5m]))
                / sum by (service) (rate(http_request_duration_seconds_count[5m]))
          ) > (14.4 * 0.005)
        for: 2m
        labels:
          severity: critical
          slo: latency
          latency_threshold: "${LATENCY_MS}ms"
        annotations:
          summary: "{{ \$labels.service }} latency SLO burning at 14.4x"
YAML
)
  write_rules "slo-alerts.yml" "${rules}"
}

# ─── Infrastructure alerts ───────────────────────────────────────────────────

generate_infra_rules() {
  local rules
  rules=$(cat << 'YAML'
# Infrastructure Alerting Rules
# Covers: node health, CPU, memory, disk, network

groups:
  - name: node_health
    rules:
      - alert: NodeDown
        expr: up{job=~"node.*"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Node {{ $labels.instance }} is unreachable"
          runbook_url: "https://runbooks.example.com/node-down"

      - alert: NodeHighCPU
        expr: |
          1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.9
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "CPU > 90% on {{ $labels.instance }}"
          description: "Current: {{ $value | humanizePercentage }}"

      - alert: NodeHighCPUCritical
        expr: |
          1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.95
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "CPU > 95% on {{ $labels.instance }}"

      - alert: NodeHighMemory
        expr: |
          1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Memory > 90% on {{ $labels.instance }}"

      - alert: NodeHighMemoryCritical
        expr: |
          1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.95
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Memory > 95% on {{ $labels.instance }}"
          runbook_url: "https://runbooks.example.com/high-memory"

      - alert: NodeHighLoadAverage
        expr: |
          node_load15 / count without (cpu) (node_cpu_seconds_total{mode="idle"}) > 2
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Load average > 2x CPU count on {{ $labels.instance }}"

  - name: disk_health
    rules:
      - alert: DiskSpaceLow
        expr: |
          1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"}
               / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs"}) > 0.85
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Disk > 85% on {{ $labels.instance }} ({{ $labels.mountpoint }})"

      - alert: DiskSpaceCritical
        expr: |
          1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"}
               / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs"}) > 0.95
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "Disk > 95% on {{ $labels.instance }} ({{ $labels.mountpoint }})"

      - alert: DiskWillFillIn4Hours
        expr: |
          predict_linear(
            node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"}[6h], 4*3600
          ) < 0
        for: 30m
        labels:
          severity: critical
        annotations:
          summary: "Disk predicted full in 4h on {{ $labels.instance }}"

      - alert: DiskIOHigh
        expr: rate(node_disk_io_time_seconds_total[5m]) > 0.9
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Disk I/O saturation on {{ $labels.instance }} ({{ $labels.device }})"

  - name: network_health
    rules:
      - alert: NetworkReceiveErrors
        expr: |
          rate(node_network_receive_errs_total{device!~"lo|veth.*"}[5m]) > 0
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Network receive errors on {{ $labels.instance }} ({{ $labels.device }})"

      - alert: NetworkTransmitErrors
        expr: |
          rate(node_network_transmit_errs_total{device!~"lo|veth.*"}[5m]) > 0
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Network transmit errors on {{ $labels.instance }} ({{ $labels.device }})"

      - alert: ConntrackTableNearFull
        expr: |
          node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.8
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Conntrack table > 80% on {{ $labels.instance }}"
YAML
)
  write_rules "infra-alerts.yml" "${rules}"
}

# ─── Application alerts ──────────────────────────────────────────────────────

generate_app_rules() {
  local rules
  rules=$(cat << 'YAML'
# Application Alerting Rules (RED Method)
# Covers: request rate anomalies, error rates, latency, saturation

groups:
  - name: app_red_alerts
    rules:
      - alert: HighErrorRate
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[5m]))
          / sum by (service) (rate(http_requests_total[5m])) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: ">5% error rate on {{ $labels.service }}"
          description: "Error rate: {{ $value | humanizePercentage }}"
          runbook_url: "https://runbooks.example.com/high-error-rate"

      - alert: HighLatencyP99
        expr: |
          histogram_quantile(0.99,
            sum by (le, service) (rate(http_request_duration_seconds_bucket[5m]))
          ) > 1
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "P99 latency > 1s on {{ $labels.service }}"
          description: "P99: {{ $value | humanizeDuration }}"

      - alert: HighLatencyP99Critical
        expr: |
          histogram_quantile(0.99,
            sum by (le, service) (rate(http_request_duration_seconds_bucket[5m]))
          ) > 5
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "P99 latency > 5s on {{ $labels.service }}"

      - alert: TrafficDrop
        expr: |
          sum by (service) (rate(http_requests_total[5m]))
          < 0.1 * sum by (service) (rate(http_requests_total[1h] offset 1d))
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Traffic drop >90% on {{ $labels.service }} vs yesterday"

      - alert: TargetDown
        expr: up == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Target {{ $labels.instance }} ({{ $labels.job }}) is down"

      - alert: EndpointMissing
        expr: absent(up{job="critical-service"})
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "No targets found for critical-service"

  - name: app_saturation_alerts
    rules:
      - alert: HighGoroutineCount
        expr: go_goroutines > 10000
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} has {{ $value }} goroutines"

      - alert: HighOpenFileDescriptors
        expr: process_open_fds / process_max_fds > 0.8
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "FD usage > 80% on {{ $labels.instance }}"
YAML
)
  write_rules "app-alerts.yml" "${rules}"
}

# ─── Kubernetes alerts ────────────────────────────────────────────────────────

generate_k8s_rules() {
  local ns_filter=""
  if [[ -n "${NAMESPACE}" ]]; then
    ns_filter=",namespace=\"${NAMESPACE}\""
  fi

  local rules
  rules=$(cat << YAML
# Kubernetes Cluster Alerting Rules
# Covers: pod health, deployments, PVCs, certificates, jobs

groups:
  - name: k8s_pod_alerts
    rules:
      - alert: PodCrashLooping
        expr: |
          increase(kube_pod_container_status_restarts_total{${ns_filter:+${ns_filter#,}}}[1h]) > 5
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "Pod {{ \$labels.namespace }}/{{ \$labels.pod }} is crash-looping"
          description: "{{ \$value }} restarts in the last hour"
          runbook_url: "https://runbooks.example.com/pod-crashloop"

      - alert: PodNotReady
        expr: |
          kube_pod_status_ready{condition="true"${ns_filter}} == 0
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Pod {{ \$labels.namespace }}/{{ \$labels.pod }} is not ready"

      - alert: PodOOMKilled
        expr: |
          kube_pod_container_status_last_terminated_reason{reason="OOMKilled"${ns_filter}} == 1
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "Container {{ \$labels.container }} in {{ \$labels.namespace }}/{{ \$labels.pod }} was OOM killed"

      - alert: ContainerHighCPU
        expr: |
          sum by (namespace, pod, container) (
            rate(container_cpu_usage_seconds_total{container!="POD",container!=""${ns_filter}}[5m])
          ) / sum by (namespace, pod, container) (
            kube_pod_container_resource_limits{resource="cpu"${ns_filter}}
          ) > 0.9
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Container {{ \$labels.container }} CPU > 90% of limit"

      - alert: ContainerHighMemory
        expr: |
          sum by (namespace, pod, container) (
            container_memory_working_set_bytes{container!="POD",container!=""${ns_filter}}
          ) / sum by (namespace, pod, container) (
            kube_pod_container_resource_limits{resource="memory"${ns_filter}}
          ) > 0.9
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Container {{ \$labels.container }} memory > 90% of limit"

  - name: k8s_deployment_alerts
    rules:
      - alert: DeploymentReplicasMismatch
        expr: |
          kube_deployment_spec_replicas${ns_filter:+{${ns_filter#,}\}}
          != kube_deployment_status_replicas_available${ns_filter:+{${ns_filter#,}\}}
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Deployment {{ \$labels.namespace }}/{{ \$labels.deployment }} replicas mismatch"

      - alert: StatefulSetReplicasMismatch
        expr: |
          kube_statefulset_status_replicas_ready${ns_filter:+{${ns_filter#,}\}}
          != kube_statefulset_status_replicas${ns_filter:+{${ns_filter#,}\}}
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "StatefulSet {{ \$labels.namespace }}/{{ \$labels.statefulset }} replicas mismatch"

      - alert: DaemonSetMissScheduled
        expr: kube_daemonset_status_number_misscheduled > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "DaemonSet {{ \$labels.namespace }}/{{ \$labels.daemonset }} has misscheduled pods"

  - name: k8s_storage_alerts
    rules:
      - alert: PVCNearFull
        expr: |
          kubelet_volume_stats_used_bytes${ns_filter:+{${ns_filter#,}\}}
          / kubelet_volume_stats_capacity_bytes${ns_filter:+{${ns_filter#,}\}} > 0.85
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "PVC {{ \$labels.namespace }}/{{ \$labels.persistentvolumeclaim }} > 85% full"

      - alert: PVCCritical
        expr: |
          kubelet_volume_stats_used_bytes${ns_filter:+{${ns_filter#,}\}}
          / kubelet_volume_stats_capacity_bytes${ns_filter:+{${ns_filter#,}\}} > 0.95
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "PVC {{ \$labels.namespace }}/{{ \$labels.persistentvolumeclaim }} > 95% full"

  - name: k8s_certificate_alerts
    rules:
      - alert: CertificateExpiringSoon
        expr: |
          (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 30
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Certificate {{ \$labels.name }} expires in {{ \$value | humanize }} days"

      - alert: CertificateExpiryCritical
        expr: |
          (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 7
        for: 1h
        labels:
          severity: critical
        annotations:
          summary: "Certificate {{ \$labels.name }} expires in {{ \$value | humanize }} days"

  - name: k8s_job_alerts
    rules:
      - alert: JobFailed
        expr: kube_job_status_failed > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Job {{ \$labels.namespace }}/{{ \$labels.job_name }} has failed pods"

      - alert: JobStuck
        expr: |
          kube_job_status_active > 0
          and on(job_name, namespace) kube_job_status_start_time < (time() - 3600)
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Job {{ \$labels.namespace }}/{{ \$labels.job_name }} running > 1h"
YAML
)
  write_rules "k8s-alerts.yml" "${rules}"
}

# ─── Prometheus self-monitoring ───────────────────────────────────────────────

generate_prometheus_rules() {
  local rules
  rules=$(cat << 'YAML'
# Prometheus Self-Monitoring Alerts

groups:
  - name: prometheus_self_alerts
    rules:
      - alert: PrometheusHighCardinality
        expr: prometheus_tsdb_head_series > 2000000
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Prometheus has {{ $value | humanize }} active series"

      - alert: PrometheusHighSeriesChurn
        expr: rate(prometheus_tsdb_head_series_created_total[5m]) > 1000
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Series churn: {{ $value | humanize }}/sec"

      - alert: PrometheusRuleFailures
        expr: rate(prometheus_rule_evaluation_failures_total[5m]) > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Rule evaluation failures detected"

      - alert: PrometheusNotificationsDropped
        expr: rate(prometheus_notifications_dropped_total[5m]) > 0
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "Alertmanager notifications being dropped"

      - alert: PrometheusRemoteWriteFailing
        expr: rate(prometheus_remote_storage_samples_failed_total[5m]) > 0
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Remote write failing at {{ $value | humanize }} samples/sec"

      - alert: PrometheusWALCorruption
        expr: prometheus_tsdb_wal_corruptions_total > 0
        labels:
          severity: critical
        annotations:
          summary: "WAL corruption detected"
          runbook_url: "https://runbooks.example.com/wal-corruption"

      - alert: PrometheusHighQueryLatency
        expr: |
          prometheus_engine_query_duration_seconds{quantile="0.99",slice="inner_eval"} > 30
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Query evaluation P99 > 30s"

      - alert: PrometheusConfigReloadFailed
        expr: prometheus_config_last_reload_successful == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Prometheus config reload failed"

      - alert: AlertmanagerClusterDegraded
        expr: |
          alertmanager_cluster_members
          < on(job) group_left count by (job) (alertmanager_cluster_members)
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Alertmanager cluster has missing members"
YAML
)
  write_rules "prometheus-self-alerts.yml" "${rules}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

if [[ "${DRY_RUN}" == "false" ]]; then
  log_info "Generating alerting rules (template=${TEMPLATE}, slo=${SLO_TARGET}, output=${OUTPUT_DIR})"
fi

case "${TEMPLATE}" in
  all)
    generate_slo_rules
    generate_infra_rules
    generate_app_rules
    generate_k8s_rules
    generate_prometheus_rules
    ;;
  slo)         generate_slo_rules ;;
  infra)       generate_infra_rules ;;
  app)         generate_app_rules ;;
  k8s)         generate_k8s_rules ;;
  prometheus)  generate_prometheus_rules ;;
  *)
    echo "Unknown template: ${TEMPLATE}" >&2
    echo "Available: all, slo, infra, app, k8s, prometheus" >&2
    exit 1
    ;;
esac

if [[ "${DRY_RUN}" == "false" ]]; then
  log_info "Done. Generated rules in ${OUTPUT_DIR}/"
  echo ""
  echo "Validate with: promtool check rules ${OUTPUT_DIR}/*.yml"
  echo "Copy to Prometheus rules dir and reload:"
  echo "  curl -X POST http://localhost:9090/-/reload"
fi
