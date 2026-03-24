#!/usr/bin/env bash
# setup-prometheus-stack.sh — Deploy Prometheus + Alertmanager + Grafana + Node Exporter
# via Docker Compose with sample configs, scrape targets, and alert rules.
#
# Usage:
#   ./setup-prometheus-stack.sh [output_dir]
#
# Default output directory: ./prometheus-stack

set -euo pipefail

OUTPUT_DIR="${1:-./prometheus-stack}"

echo "==> Creating Prometheus monitoring stack in: ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"/{prometheus/rules,alertmanager/templates,grafana/provisioning/datasources}

# ─── prometheus.yml ──────────────────────────────────────────────────────────
cat > "${OUTPUT_DIR}/prometheus/prometheus.yml" <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: local
    environment: development

rule_files:
  - "rules/*.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "alertmanager"
    static_configs:
      - targets: ["alertmanager:9093"]

  - job_name: "node-exporter"
    static_configs:
      - targets: ["node-exporter:9100"]

  - job_name: "cadvisor"
    static_configs:
      - targets: ["cadvisor:8080"]

  - job_name: "grafana"
    static_configs:
      - targets: ["grafana:3000"]
YAML

# ─── Recording rules ────────────────────────────────────────────────────────
cat > "${OUTPUT_DIR}/prometheus/rules/recording-rules.yml" <<'YAML'
groups:
  - name: node_recording_rules
    interval: 30s
    rules:
      - record: instance:node_cpu_utilization:ratio
        expr: |
          1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))

      - record: instance:node_memory_utilization:ratio
        expr: |
          1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

      - record: instance:node_filesystem_utilization:ratio
        expr: |
          1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})
YAML

# ─── Alerting rules ─────────────────────────────────────────────────────────
cat > "${OUTPUT_DIR}/prometheus/rules/alerting-rules.yml" <<'YAML'
groups:
  - name: node_alerts
    rules:
      - alert: TargetDown
        expr: up == 0
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "Target {{ $labels.instance }} ({{ $labels.job }}) is down"

      - alert: HighCPU
        expr: instance:node_cpu_utilization:ratio > 0.85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "CPU above 85% on {{ $labels.instance }}"

      - alert: HighMemory
        expr: instance:node_memory_utilization:ratio > 0.9
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Memory above 90% on {{ $labels.instance }}"

      - alert: DiskSpaceLow
        expr: instance:node_filesystem_utilization:ratio > 0.9
        for: 15m
        labels:
          severity: critical
        annotations:
          summary: "Disk usage above 90% on {{ $labels.instance }} ({{ $labels.mountpoint }})"
YAML

# ─── alertmanager.yml ────────────────────────────────────────────────────────
cat > "${OUTPUT_DIR}/alertmanager/alertmanager.yml" <<'YAML'
global:
  resolve_timeout: 5m

route:
  receiver: default
  group_by: ["alertname", "job"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - match:
        severity: critical
      receiver: critical
      repeat_interval: 1h

receivers:
  - name: default
    webhook_configs:
      - url: "http://localhost:9095/webhook"
        send_resolved: true

  - name: critical
    webhook_configs:
      - url: "http://localhost:9095/webhook"
        send_resolved: true
    # Uncomment to enable Slack:
    # slack_configs:
    #   - api_url: "https://hooks.slack.com/services/T00/B00/XXX"
    #     channel: "#alerts-critical"
    #     send_resolved: true

inhibit_rules:
  - source_matchers:
      - severity = critical
    target_matchers:
      - severity = warning
    equal: ["alertname", "instance"]
YAML

# ─── Grafana datasource provisioning ────────────────────────────────────────
cat > "${OUTPUT_DIR}/grafana/provisioning/datasources/prometheus.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
YAML

# ─── docker-compose.yml ─────────────────────────────────────────────────────
cat > "${OUTPUT_DIR}/docker-compose.yml" <<'YAML'
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=15d"
      - "--storage.tsdb.wal-compression"
      - "--web.enable-lifecycle"
      - "--web.enable-admin-api"

  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    restart: unless-stopped
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - grafana_data:/var/lib/grafana

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--path.rootfs=/rootfs"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    privileged: true
    devices:
      - /dev/kmsg

volumes:
  prometheus_data:
  grafana_data:
YAML

echo ""
echo "==> Prometheus monitoring stack created in: ${OUTPUT_DIR}"
echo ""
echo "Files created:"
find "${OUTPUT_DIR}" -type f | sort | sed 's|^|  |'
echo ""
echo "To start the stack:"
echo "  cd ${OUTPUT_DIR} && docker compose up -d"
echo ""
echo "Endpoints:"
echo "  Prometheus:    http://localhost:9090"
echo "  Alertmanager:  http://localhost:9093"
echo "  Grafana:       http://localhost:3000  (admin/admin)"
echo "  Node Exporter: http://localhost:9100"
echo "  cAdvisor:      http://localhost:8080"
