# Kubernetes Monitoring with Prometheus

## Table of Contents

- [1. kube-prometheus-stack Helm Chart](#1-kube-prometheus-stack-helm-chart)
- [2. ServiceMonitor and PodMonitor CRDs](#2-servicemonitor-and-podmonitor-crds)
- [3. kube-state-metrics Deep Dive](#3-kube-state-metrics-deep-dive)
- [4. node-exporter DaemonSet Setup](#4-node-exporter-daemonset-setup)
- [5. cAdvisor Container Metrics](#5-cadvisor-container-metrics)
- [6. Kubelet Metrics](#6-kubelet-metrics)
- [7. API Server Metrics and Monitoring](#7-api-server-metrics-and-monitoring)
- [8. etcd Monitoring](#8-etcd-monitoring)
- [9. Custom Metrics for HPA](#9-custom-metrics-for-hpa)
- [10. Alert Rules for Cluster Health](#10-alert-rules-for-cluster-health)
  - [10.1 Node Down Detection](#101-node-down-detection)
  - [10.2 Pod Crash Loops](#102-pod-crash-loops)
  - [10.3 PVC Full](#103-pvc-full)
  - [10.4 Certificate Expiry](#104-certificate-expiry)
  - [10.5 Deployment Replicas Mismatch](#105-deployment-replicas-mismatch)
  - [10.6 Job Failures](#106-job-failures)
- [11. Grafana Dashboard Provisioning with ConfigMaps](#11-grafana-dashboard-provisioning-with-configmaps)

---

## 1. kube-prometheus-stack Helm Chart

The `kube-prometheus-stack` Helm chart bundles Prometheus Operator, Prometheus,
Alertmanager, Grafana, kube-state-metrics, and node-exporter into a single
deployable unit with pre-configured alert rules and dashboards.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring

helm install kube-prom-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 58.2.1 \
  --wait
```

Production `values.yaml` overrides:

```yaml
prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: "45GB"
    replicas: 2
    resources:
      requests: { cpu: "1", memory: 4Gi }
      limits:   { cpu: "2", memory: 8Gi }
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
alertmanager:
  alertmanagerSpec:
    replicas: 3
grafana:
  replicas: 2
  persistence:
    enabled: true
    size: 10Gi
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL
kubeEtcd:
  enabled: true
```

```bash
helm upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring -f values.yaml --wait
```

---

## 2. ServiceMonitor and PodMonitor CRDs

The Prometheus Operator uses CRDs to declaratively define scrape targets,
eliminating manual `scrape_configs`. A `ServiceMonitor` selects `Service`
objects by label; a `PodMonitor` targets pods directly.

Discovery flow: App exposes `/metrics` → Service selects pods → ServiceMonitor
selects Service → Operator updates Prometheus config → Prometheus scrapes.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app-monitor
  namespace: monitoring
  labels:
    release: kube-prom-stack
spec:
  namespaceSelector:
    matchNames: [production, staging]
  selector:
    matchLabels:
      app: my-app
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: "go_.*"
          action: drop
```

PodMonitor for sidecar containers without a Service:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: envoy-sidecar-monitor
  namespace: monitoring
spec:
  namespaceSelector:
    any: true
  selector:
    matchLabels:
      sidecar: envoy
  podMetricsEndpoints:
    - port: admin
      path: /stats/prometheus
      interval: 15s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
```

Debug target discovery:

```bash
kubectl -n monitoring port-forward svc/kube-prom-stack-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {scrapePool, scrapeUrl, health}'
```

---

## 3. kube-state-metrics Deep Dive

kube-state-metrics (KSM) generates metrics about Kubernetes object state by
listening to the API server — deployment replica counts, pod phases, resource
requests/limits, and node conditions.

Key PromQL queries:

```promql
# Pods stuck in non-running state
kube_pod_status_phase{phase!="Running", phase!="Succeeded"} == 1

# Containers waiting (excluding normal startup)
kube_pod_container_status_waiting_reason{reason!="ContainerCreating"} > 0

# Deployments with unavailable replicas
kube_deployment_status_replicas_unavailable > 0

# CPU overcommitment ratio per node
sum by (node) (kube_pod_container_resource_requests{resource="cpu"})
  / sum by (node) (kube_node_status_allocatable{resource="cpu"}) * 100

# DaemonSets with missing pods
kube_daemonset_status_desired_number_scheduled - kube_daemonset_status_number_ready > 0
```

Filtering configuration to reduce cardinality:

```yaml
kube-state-metrics:
  collectors:
    - deployments
    - daemonsets
    - statefulsets
    - pods
    - nodes
    - persistentvolumeclaims
    - jobs
    - cronjobs
  metricLabelsAllowlist:
    - pods=[app.kubernetes.io/name,app.kubernetes.io/component]
    - deployments=[app.kubernetes.io/name]
```

---

## 4. node-exporter DaemonSet Setup

The node-exporter runs on every node to collect hardware and OS metrics.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels: { app: node-exporter }
  template:
    metadata:
      labels: { app: node-exporter }
    spec:
      hostPID: true
      hostNetwork: true
      tolerations:
        - effect: NoSchedule
          operator: Exists
      containers:
        - name: node-exporter
          image: prom/node-exporter:v1.8.1
          args:
            - "--path.procfs=/host/proc"
            - "--path.sysfs=/host/sys"
            - "--path.rootfs=/host/root"
            - "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+)($|/)"
          ports:
            - containerPort: 9100
              hostPort: 9100
              name: metrics
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 100m, memory: 128Mi }
          volumeMounts:
            - { name: proc, mountPath: /host/proc, readOnly: true }
            - { name: sys,  mountPath: /host/sys,  readOnly: true }
            - { name: root, mountPath: /host/root, readOnly: true, mountPropagation: HostToContainer }
      volumes:
        - { name: proc, hostPath: { path: /proc } }
        - { name: sys,  hostPath: { path: /sys } }
        - { name: root, hostPath: { path: / } }
```

Key node-level PromQL:

```promql
# CPU utilization per node
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory utilization
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Disk I/O utilization
rate(node_disk_io_time_seconds_total[5m]) * 100

# Filesystem space remaining
(node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100
```

---

## 5. cAdvisor Container Metrics

cAdvisor is embedded in the kubelet and provides container-level resource
usage metrics with the `container_` prefix.

### CPU

```promql
# CPU usage rate per container (cores)
rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m])

# CPU throttling percentage
rate(container_cpu_cfs_throttled_seconds_total{container!=""}[5m])
  / rate(container_cpu_cfs_periods_total{container!=""}[5m]) * 100

# Top 10 CPU-consuming pods
topk(10, sum by (namespace, pod) (
  rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m])
))
```

### Memory

```promql
# Working set memory (what the OOM killer considers)
container_memory_working_set_bytes{container!="", container!="POD"}

# Memory usage vs limits (approaching OOMKill)
container_memory_working_set_bytes{container!=""}
  / kube_pod_container_resource_limits{resource="memory"} * 100
```

### Network

```promql
# Network receive rate per pod
sum by (namespace, pod) (rate(container_network_receive_bytes_total{pod!=""}[5m]))

# Packet drop rate
sum by (namespace, pod) (
  rate(container_network_receive_packets_dropped_total{pod!=""}[5m])
  + rate(container_network_transmit_packets_dropped_total{pod!=""}[5m])
)
```

### Filesystem

```promql
# Container filesystem usage and I/O throughput
container_fs_usage_bytes{container!="", container!="POD"}
rate(container_fs_writes_bytes_total{container!=""}[5m])
```

---

## 6. Kubelet Metrics

The kubelet exposes metrics about pod lifecycle, volume operations, and
container runtime health on each node.

```promql
# Pod start duration — 99th percentile
histogram_quantile(0.99, sum by (le, instance) (
  rate(kubelet_pod_start_duration_seconds_bucket[5m])
))

# PVC usage percentage
kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes * 100

# Container runtime operation errors
rate(kubelet_runtime_operations_errors_total[5m]) > 0

# Running pods per node
kubelet_running_pods

# PLEG relist duration — 99th percentile
histogram_quantile(0.99, sum by (le, instance) (
  rate(kubelet_pleg_relist_duration_seconds_bucket[5m])
))
```

Custom scrape tuning via Helm values:

```yaml
kubelet:
  enabled: true
  serviceMonitor:
    interval: 30s
    metricRelabelings:
      - sourceLabels: [__name__]
        regex: "storage_operation_duration_seconds_bucket"
        action: drop
    cAdvisorMetricRelabelings:
      - sourceLabels: [__name__]
        regex: "container_(cpu|memory|network|fs)_.*"
        action: keep
```

---

## 7. API Server Metrics and Monitoring

The API server is the central hub for all cluster communication.

```promql
# Request latency by verb/resource — 99th percentile
histogram_quantile(0.99, sum by (le, verb, resource) (
  rate(apiserver_request_duration_seconds_bucket{verb!="WATCH"}[5m])
))

# Error rate (5xx responses)
sum(rate(apiserver_request_total{code=~"5.."}[5m]))
  / sum(rate(apiserver_request_total[5m])) * 100

# Availability percentage
(1 - sum(rate(apiserver_request_total{code=~"5.."}[5m]))
  / sum(rate(apiserver_request_total[5m]))) * 100

# Admission webhook latency — 99th percentile
histogram_quantile(0.99, sum by (le, name) (
  rate(apiserver_admission_webhook_admission_duration_seconds_bucket[5m])
))

# In-flight requests and throttled requests
apiserver_current_inflight_requests
rate(apiserver_dropped_requests_total[5m]) > 0
```

---

## 8. etcd Monitoring

etcd is the backing store for all cluster data. On self-managed clusters,
configure TLS access for scraping:

```yaml
kubeEtcd:
  enabled: true
  endpoints: [10.0.1.10, 10.0.1.11, 10.0.1.12]
  serviceMonitor:
    scheme: https
    caFile: /etc/prometheus/secrets/etcd-client-cert/ca.crt
    certFile: /etc/prometheus/secrets/etcd-client-cert/tls.crt
    keyFile: /etc/prometheus/secrets/etcd-client-cert/tls.key
prometheus:
  prometheusSpec:
    secrets: [etcd-client-cert]
```

```bash
kubectl -n monitoring create secret generic etcd-client-cert \
  --from-file=ca.crt=/etc/kubernetes/pki/etcd/ca.crt \
  --from-file=tls.crt=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --from-file=tls.key=/etc/kubernetes/pki/etcd/healthcheck-client.key
```

Critical etcd PromQL:

```promql
# Leader changes — frequent changes indicate instability
increase(etcd_server_leader_changes_seen_total[1h]) > 3

# Disk fsync duration — should be under 10ms
histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))

# Database size and gRPC failure rate
etcd_mvcc_db_total_size_in_bytes
sum(rate(grpc_server_handled_total{grpc_code!="OK"}[5m]))
  / sum(rate(grpc_server_handled_total[5m])) * 100

# Consensus failures
rate(etcd_server_proposals_failed_total[5m]) > 0
```

---

## 9. Custom Metrics for HPA

The Horizontal Pod Autoscaler can scale on custom Prometheus metrics via
`prometheus-adapter`.

```bash
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --set prometheus.url=http://kube-prom-stack-prometheus.monitoring.svc \
  --set prometheus.port=9090
```

Adapter rules mapping PromQL to the custom metrics API:

```yaml
rules:
  custom:
    - seriesQuery: 'http_requests_total{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        matches: "^(.*)_total$"
        as: "${1}_per_second"
      metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
    - seriesQuery: 'request_queue_length{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        matches: "^(.*)"
        as: "${1}"
      metricsQuery: 'avg(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)'
```

HPA resource using custom metrics:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 3
  maxReplicas: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - { type: Percent, value: 50, periodSeconds: 60 }
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - { type: Percent, value: 10, periodSeconds: 120 }
  metrics:
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "1000"
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

---

## 10. Alert Rules for Cluster Health

PrometheusRule CRDs define alerting rules. Below are production-grade alerts
for the most critical cluster health signals.

### 10.1 Node Down Detection

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cluster-health-alerts
  namespace: monitoring
  labels:
    release: kube-prom-stack
spec:
  groups:
    - name: node.rules
      rules:
        - alert: NodeDown
          expr: up{job="node-exporter"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Node {{ $labels.instance }} is down"
            description: "Node exporter unreachable for 5+ minutes."
        - alert: NodeNotReady
          expr: kube_node_status_condition{condition="Ready",status="true"} == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "Node {{ $labels.node }} is NotReady"
```

### 10.2 Pod Crash Loops

```yaml
        - alert: PodCrashLooping
          expr: |
            increase(kube_pod_container_status_restarts_total[1h]) > 5
            and kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} crash looping"
            description: "Container {{ $labels.container }} restarted {{ $value | humanize }} times in 1h."
```

### 10.3 PVC Full

```yaml
        - alert: PersistentVolumeFillingUp
          expr: |
            (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) > 0.85
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is {{ $value | humanizePercentage }} full"
        - alert: PersistentVolumeCritical
          expr: |
            (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) > 0.95
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} critically full"
```

### 10.4 Certificate Expiry

```yaml
        - alert: CertificateExpiringSoon
          expr: |
            apiserver_client_certificate_expiration_seconds_count > 0
            and histogram_quantile(0.01,
              sum by (job, le) (rate(apiserver_client_certificate_expiration_seconds_bucket[5m]))
            ) < 604800
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Client certificate expiring within 7 days"
        - alert: CertificateExpiryCritical
          expr: |
            apiserver_client_certificate_expiration_seconds_count > 0
            and histogram_quantile(0.01,
              sum by (job, le) (rate(apiserver_client_certificate_expiration_seconds_bucket[5m]))
            ) < 86400
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Client certificate expiring within 24 hours"
```

### 10.5 Deployment Replicas Mismatch

```yaml
        - alert: DeploymentReplicasMismatch
          expr: |
            kube_deployment_spec_replicas != kube_deployment_status_replicas_available
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} replicas mismatch"
            description: "Desired replicas do not match available. Check scheduling or resource constraints."
        - alert: StatefulSetReplicasMismatch
          expr: |
            kube_statefulset_status_replicas_ready != kube_statefulset_replicas
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "StatefulSet {{ $labels.namespace }}/{{ $labels.statefulset }} replicas mismatch"
```

### 10.6 Job Failures

```yaml
        - alert: KubeJobFailed
          expr: kube_job_status_failed > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Job {{ $labels.namespace }}/{{ $labels.job_name }} failed"
        - alert: KubeJobNotCompleted
          expr: |
            kube_job_spec_completions - kube_job_status_succeeded > 0
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Job {{ $labels.namespace }}/{{ $labels.job_name }} incomplete after 1h"
        - alert: CronJobSuspended
          expr: kube_cronjob_status_active == 0 and kube_cronjob_spec_suspend == 1
          for: 24h
          labels:
            severity: info
          annotations:
            summary: "CronJob {{ $labels.namespace }}/{{ $labels.cronjob }} suspended for 24h"
```

---

## 11. Grafana Dashboard Provisioning with ConfigMaps

The kube-prometheus-stack Grafana sidecar auto-discovers ConfigMaps with the
label `grafana_dashboard: "1"` and loads them as dashboards.

### Dashboard ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-cluster-overview
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana-folder: "Kubernetes"
data:
  cluster-overview.json: |
    {
      "editable": true,
      "panels": [
        {
          "title": "CPU Usage by Namespace",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
          "targets": [{
            "expr": "sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=\"\"}[5m]))",
            "legendFormat": "{{ namespace }}"
          }]
        },
        {
          "title": "Memory Usage by Namespace",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
          "targets": [{
            "expr": "sum by (namespace) (container_memory_working_set_bytes{container!=\"\"})",
            "legendFormat": "{{ namespace }}"
          }]
        },
        {
          "title": "Pod Count",
          "type": "stat",
          "gridPos": { "h": 4, "w": 6, "x": 0, "y": 8 },
          "targets": [{
            "expr": "sum(kube_pod_status_phase{phase=\"Running\"})",
            "legendFormat": "Running"
          }]
        }
      ],
      "schemaVersion": 39,
      "tags": ["kubernetes", "cluster"],
      "time": { "from": "now-6h", "to": "now" },
      "title": "Cluster Overview",
      "uid": "cluster-overview-001"
    }
```

### Helm-based Provisioning

```yaml
grafana:
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL
      folderAnnotation: grafana-folder
      provider:
        foldersFromFilesStructure: true
  dashboards:
    kubernetes:
      node-exporter-full:
        gnetId: 1860
        revision: 33
        datasource: Prometheus
      kubernetes-cluster:
        gnetId: 7249
        revision: 1
        datasource: Prometheus
```

Automated deployment script for dashboard JSON files:

```bash
#!/usr/bin/env bash
NAMESPACE="monitoring"
DASHBOARD_DIR="./dashboards"

for file in "${DASHBOARD_DIR}"/*.json; do
  name=$(basename "${file}" .json | tr '._' '--')
  kubectl create configmap "grafana-dashboard-${name}" \
    --namespace "${NAMESPACE}" \
    --from-file="${file}" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml \
    | kubectl annotate --local -f - grafana-folder="Custom" -o yaml \
    | kubectl apply -f -
  echo "Deployed dashboard: ${name}"
done
```

---

> **Summary:** This guide covers the full Kubernetes observability stack —
> from Helm-based deployment through service discovery, core component metrics,
> custom HPA scaling, production alert rules, and automated Grafana dashboard
> provisioning. Start with kube-prometheus-stack defaults and layer on custom
> monitors, alerts, and dashboards as your cluster matures.
