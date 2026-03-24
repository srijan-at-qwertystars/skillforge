# KubeRay — Comprehensive Guide

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Installation](#installation)
- [RayCluster CRD](#raycluster-crd)
- [RayJob CRD](#rayjob-crd)
- [RayService CRD](#rayservice-crd)
- [Autoscaling](#autoscaling)
- [Node Groups and Heterogeneous Clusters](#node-groups-and-heterogeneous-clusters)
- [GPU Scheduling](#gpu-scheduling)
- [Persistent Storage](#persistent-storage)
- [Monitoring with Prometheus and Grafana](#monitoring-with-prometheus-and-grafana)
- [Production Cluster Sizing](#production-cluster-sizing)
- [Multi-Tenancy](#multi-tenancy)
- [Security](#security)
- [Networking](#networking)
- [Upgrades and Maintenance](#upgrades-and-maintenance)
- [Troubleshooting KubeRay](#troubleshooting-kuberay)

---

## Overview

KubeRay is the Kubernetes operator for Ray. It manages Ray clusters as native Kubernetes resources via Custom Resource Definitions (CRDs). Three CRDs:

| CRD | Purpose | Use case |
|-----|---------|----------|
| **RayCluster** | Long-lived Ray cluster | Interactive development, shared compute |
| **RayJob** | Cluster + job submission + auto-cleanup | Batch jobs, pipelines, CI/CD |
| **RayService** | Cluster + Ray Serve deployment + zero-downtime upgrades | Model serving, APIs |

KubeRay integrates with Kubernetes ecosystem: HPA, PDB, RBAC, NetworkPolicy, PVC, monitoring.

## Architecture

```
┌─────────────────────────────────────────────┐
│                 Kubernetes                   │
│                                             │
│  ┌─────────────┐   ┌────────────────────┐   │
│  │  KubeRay     │   │  RayCluster CR     │   │
│  │  Operator    │──▶│  (desired state)   │   │
│  └──────┬──────┘   └────────────────────┘   │
│         │                                    │
│         │ reconciles                         │
│         ▼                                    │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │  Head Pod    │  │  Worker Pods         │  │
│  │  - GCS       │  │  - Raylet            │  │
│  │  - Dashboard │  │  - Object Store      │  │
│  │  - Autoscaler│  │  - Worker processes  │  │
│  │  - Raylet    │  │  (autoscaled)        │  │
│  └──────────────┘  └──────────────────────┘  │
│                                             │
│  ┌──────────────┐  ┌──────────────────────┐  │
│  │  Head Service│  │  Worker Service      │  │
│  │  (ClusterIP) │  │  (headless)          │  │
│  └──────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────┘
```

The operator watches for RayCluster/RayJob/RayService CRs, creates/updates/deletes the corresponding pods, services, and ingresses.

## Installation

### Helm (recommended)

```bash
# Add the KubeRay Helm repository
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm repo update

# Install the operator
helm install kuberay-operator kuberay/kuberay-operator \
    --namespace ray-system \
    --create-namespace \
    --version 1.1.0

# Verify
kubectl get pods -n ray-system
# kuberay-operator-xxxxx   1/1   Running
```

### Helm values customization

```yaml
# values.yaml
operator:
  image:
    repository: kuberay/operator
    tag: v1.1.0
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 128Mi

# Watch specific namespaces (empty = all)
watchNamespace: ["ray-production", "ray-staging"]

# Enable leader election for HA
leaderElection:
  enabled: true

# CRD management
crds:
  install: true
```

```bash
helm install kuberay-operator kuberay/kuberay-operator \
    -f values.yaml \
    -n ray-system --create-namespace
```

### Verify installation

```bash
# Check CRDs
kubectl get crd | grep ray
# rayclusters.ray.io
# rayjobs.ray.io
# rayservices.ray.io

# Check operator logs
kubectl logs -l app.kubernetes.io/name=kuberay-operator -n ray-system
```

## RayCluster CRD

### Minimal cluster

```yaml
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: my-cluster
  namespace: ray-workloads
spec:
  rayVersion: "2.9.0"
  headGroupSpec:
    rayStartParams:
      dashboard-host: "0.0.0.0"
    template:
      spec:
        containers:
        - name: ray-head
          image: rayproject/ray:2.9.0-py310
          ports:
          - containerPort: 6379
            name: gcs
          - containerPort: 8265
            name: dashboard
          - containerPort: 10001
            name: client
          resources:
            requests:
              cpu: "2"
              memory: "4Gi"
            limits:
              cpu: "4"
              memory: "8Gi"
  workerGroupSpecs:
  - groupName: default-workers
    replicas: 3
    minReplicas: 1
    maxReplicas: 10
    rayStartParams: {}
    template:
      spec:
        containers:
        - name: ray-worker
          image: rayproject/ray:2.9.0-py310
          resources:
            requests:
              cpu: "4"
              memory: "8Gi"
            limits:
              cpu: "4"
              memory: "8Gi"
```

### Production-ready cluster

```yaml
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: production-cluster
  namespace: ray-production
  labels:
    environment: production
    team: ml-platform
spec:
  rayVersion: "2.9.0"
  enableInTreeAutoscaling: true

  headGroupSpec:
    rayStartParams:
      dashboard-host: "0.0.0.0"
      num-cpus: "0"  # Don't schedule compute on head
      object-store-memory: "1000000000"
    template:
      metadata:
        labels:
          ray.io/node-type: head
        annotations:
          prometheus.io/scrape: "true"
          prometheus.io/port: "8080"
      spec:
        serviceAccountName: ray-head
        nodeSelector:
          node-role: ray-head
        tolerations:
        - key: "ray-head"
          operator: "Exists"
          effect: "NoSchedule"
        containers:
        - name: ray-head
          image: my-registry/ray:2.9.0-custom
          imagePullPolicy: Always
          env:
          - name: RAY_DEDUP_LOGS
            value: "1"
          ports:
          - containerPort: 6379
            name: gcs
          - containerPort: 8265
            name: dashboard
          - containerPort: 10001
            name: client
          - containerPort: 8080
            name: metrics
          resources:
            requests:
              cpu: "4"
              memory: "16Gi"
            limits:
              cpu: "8"
              memory: "32Gi"
          volumeMounts:
          - name: ray-logs
            mountPath: /tmp/ray
          - name: shared-storage
            mountPath: /mnt/shared
          livenessProbe:
            httpGet:
              path: /
              port: 8265
            initialDelaySeconds: 60
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /
              port: 8265
            initialDelaySeconds: 30
            periodSeconds: 10
        volumes:
        - name: ray-logs
          emptyDir:
            sizeLimit: 10Gi
        - name: shared-storage
          persistentVolumeClaim:
            claimName: ray-shared-pvc
        imagePullSecrets:
        - name: registry-credentials

  workerGroupSpecs:
  - groupName: cpu-workers
    replicas: 4
    minReplicas: 2
    maxReplicas: 20
    rayStartParams:
      object-store-memory: "2000000000"
    template:
      metadata:
        labels:
          ray.io/node-type: worker
          worker-type: cpu
      spec:
        serviceAccountName: ray-worker
        nodeSelector:
          node-role: ray-worker
        containers:
        - name: ray-worker
          image: my-registry/ray:2.9.0-custom
          resources:
            requests:
              cpu: "8"
              memory: "32Gi"
            limits:
              cpu: "8"
              memory: "32Gi"
          volumeMounts:
          - name: shared-storage
            mountPath: /mnt/shared
        volumes:
        - name: shared-storage
          persistentVolumeClaim:
            claimName: ray-shared-pvc

  - groupName: gpu-workers
    replicas: 2
    minReplicas: 0
    maxReplicas: 8
    rayStartParams:
      object-store-memory: "4000000000"
    template:
      metadata:
        labels:
          worker-type: gpu
      spec:
        nodeSelector:
          nvidia.com/gpu.present: "true"
        tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
        containers:
        - name: ray-worker
          image: my-registry/ray:2.9.0-gpu-custom
          resources:
            requests:
              cpu: "8"
              memory: "32Gi"
              nvidia.com/gpu: "1"
            limits:
              cpu: "8"
              memory: "32Gi"
              nvidia.com/gpu: "1"
```

### Connecting to the cluster

```bash
# Port-forward for local development
kubectl port-forward svc/production-cluster-head-svc 10001:10001 8265:8265 -n ray-production

# From Python
import ray
ray.init(address="ray://localhost:10001")
```

## RayJob CRD

RayJob creates a cluster, submits a job, and optionally cleans up after completion:

```yaml
apiVersion: ray.io/v1
kind: RayJob
metadata:
  name: training-job
  namespace: ray-workloads
spec:
  # Job configuration
  entrypoint: "python /app/train.py --epochs 100 --lr 0.001"
  runtimeEnvYAML: |
    pip:
      - torch==2.1.0
      - transformers==4.35.0
    working_dir: "s3://my-bucket/training-code/"
    env_vars:
      WANDB_API_KEY: "${WANDB_API_KEY}"

  # Lifecycle
  shutdownAfterJobFinishes: true
  ttlSecondsAfterFinished: 3600  # Clean up 1 hour after completion
  activeDeadlineSeconds: 86400   # Job timeout: 24 hours
  submitterPodTemplate:
    spec:
      restartPolicy: Never

  # Cluster spec (same as RayCluster)
  rayClusterSpec:
    rayVersion: "2.9.0"
    enableInTreeAutoscaling: true
    headGroupSpec:
      rayStartParams:
        dashboard-host: "0.0.0.0"
        num-cpus: "0"
      template:
        spec:
          containers:
          - name: ray-head
            image: rayproject/ray:2.9.0-py310
            resources:
              requests:
                cpu: "2"
                memory: "8Gi"
    workerGroupSpecs:
    - groupName: gpu-workers
      replicas: 4
      minReplicas: 4
      maxReplicas: 4
      template:
        spec:
          containers:
          - name: ray-worker
            image: rayproject/ray:2.9.0-py310-gpu
            resources:
              requests:
                cpu: "8"
                memory: "32Gi"
                nvidia.com/gpu: "1"
```

### RayJob with existing cluster

```yaml
apiVersion: ray.io/v1
kind: RayJob
metadata:
  name: quick-job
spec:
  entrypoint: "python -c 'import ray; ray.init(); print(ray.cluster_resources())'"
  clusterSelector:
    ray.io/cluster: production-cluster  # Use existing cluster
  shutdownAfterJobFinishes: false       # Don't tear down shared cluster
```

### Monitoring RayJob

```bash
# Check job status
kubectl get rayjob training-job -n ray-workloads

# STATUS can be: INITIALIZING, RUNNING, SUCCEEDED, FAILED, STOPPED

# Get job logs
kubectl logs -l ray.io/job=training-job -n ray-workloads --tail=100

# Get submitter pod logs
kubectl logs training-job-submitter -n ray-workloads
```

## RayService CRD

RayService manages Ray Serve deployments with zero-downtime upgrades:

```yaml
apiVersion: ray.io/v1
kind: RayService
metadata:
  name: ml-serving
  namespace: ray-production
spec:
  serviceUnhealthySecondThreshold: 300
  deploymentUnhealthySecondThreshold: 120

  serveConfigV2: |
    applications:
      - name: sentiment
        route_prefix: /sentiment
        import_path: serving.sentiment:app
        runtime_env:
          pip:
            - transformers==4.35.0
            - torch==2.1.0
          working_dir: "s3://models/sentiment/"
        deployments:
          - name: SentimentModel
            num_replicas: auto
            autoscaling_config:
              min_replicas: 2
              max_replicas: 10
              target_num_ongoing_requests_per_replica: 3
            ray_actor_options:
              num_gpus: 1

      - name: translation
        route_prefix: /translate
        import_path: serving.translation:app
        deployments:
          - name: TranslationModel
            num_replicas: 3
            ray_actor_options:
              num_gpus: 1

  rayClusterConfig:
    rayVersion: "2.9.0"
    enableInTreeAutoscaling: true
    headGroupSpec:
      rayStartParams:
        dashboard-host: "0.0.0.0"
        num-cpus: "0"
      template:
        spec:
          containers:
          - name: ray-head
            image: my-registry/ray-serve:2.9.0
            resources:
              requests:
                cpu: "4"
                memory: "8Gi"
    workerGroupSpecs:
    - groupName: gpu-workers
      replicas: 4
      minReplicas: 2
      maxReplicas: 16
      template:
        spec:
          containers:
          - name: ray-worker
            image: my-registry/ray-serve:2.9.0
            resources:
              requests:
                cpu: "4"
                memory: "16Gi"
                nvidia.com/gpu: "1"
```

### Zero-downtime upgrades

When you update the `serveConfigV2` field:
1. KubeRay creates a new Ray cluster (pending cluster)
2. Deploys the new Serve application on the pending cluster
3. Waits for health checks to pass
4. Switches traffic from active to pending cluster
5. Tears down the old cluster

```bash
# Monitor upgrade
kubectl get rayservice ml-serving -n ray-production -o yaml | grep -A5 status
```

### Accessing RayService

```bash
# KubeRay creates two services:
# 1. <name>-serve-svc — for Serve traffic (port 8000)
# 2. <name>-head-svc — for dashboard/client (ports 8265, 10001)

# Port forward Serve endpoint
kubectl port-forward svc/ml-serving-serve-svc 8000:8000 -n ray-production

# Test
curl http://localhost:8000/sentiment -d '{"text": "Ray Serve is great!"}'
```

## Autoscaling

Three tiers of autoscaling work together:

### Tier 1: Ray Serve autoscaling (replicas)

```yaml
# In serveConfigV2
deployments:
  - name: Model
    num_replicas: auto
    autoscaling_config:
      min_replicas: 1
      max_replicas: 20
      target_num_ongoing_requests_per_replica: 5
```

Serve adds/removes actor replicas within the existing cluster.

### Tier 2: Ray Autoscaler (pods)

```yaml
# In RayCluster spec
spec:
  enableInTreeAutoscaling: true
  autoscalerOptions:
    upscalingMode: Default       # Default, Conservative, Aggressive
    idleTimeoutSeconds: 60       # Remove idle workers after 60s
    resources:
      limits:
        cpu: "500m"
        memory: "512Mi"
  workerGroupSpecs:
  - groupName: gpu-workers
    minReplicas: 0    # Allow scale to zero
    maxReplicas: 20   # Upper bound
```

When Serve needs more replicas but no resources are available, Ray Autoscaler requests new worker pods.

### Tier 3: Kubernetes Cluster Autoscaler (nodes)

```yaml
# Kubernetes cluster autoscaler configuration
# (external to KubeRay — configure in cloud provider)
# AWS EKS: Karpenter or Cluster Autoscaler
# GKE: Node Auto-Provisioning
# AKS: Cluster Autoscaler

# Example Karpenter provisioner for Ray GPU workers
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: ray-gpu-workers
spec:
  requirements:
  - key: nvidia.com/gpu
    operator: Exists
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["on-demand"]
  limits:
    resources:
      nvidia.com/gpu: "32"
  ttlSecondsAfterEmpty: 300
  provider:
    instanceTypes: ["p3.2xlarge", "g4dn.xlarge"]
```

### Autoscaling tuning

```yaml
autoscalerOptions:
  upscalingMode: Default
  # Default: scale up quickly, scale down conservatively
  # Conservative: slow scale up, slow scale down
  # Aggressive: fast scale up, fast scale down

  idleTimeoutSeconds: 60
  # How long a worker must be idle before removal
  # Lower = faster scale-down, higher = more stability

  env:
  - name: RAY_AUTOSCALER_SCALE_UP_SPEED
    value: "1.0"
  - name: RAY_AUTOSCALER_SCALE_DOWN_SPEED
    value: "1.0"
```

## Node Groups and Heterogeneous Clusters

Define multiple worker groups for different hardware/workload types:

```yaml
workerGroupSpecs:
# CPU workers for preprocessing
- groupName: cpu-workers
  replicas: 4
  minReplicas: 2
  maxReplicas: 20
  rayStartParams:
    resources: '"{\"preprocessing\": 1}"'
  template:
    spec:
      nodeSelector:
        node.kubernetes.io/instance-type: m5.4xlarge
      containers:
      - name: ray-worker
        image: rayproject/ray:2.9.0-py310
        resources:
          requests:
            cpu: "14"
            memory: "56Gi"

# GPU workers for inference
- groupName: gpu-inference
  replicas: 2
  minReplicas: 1
  maxReplicas: 8
  rayStartParams:
    resources: '"{\"inference\": 1}"'
  template:
    spec:
      nodeSelector:
        nvidia.com/gpu.product: Tesla-T4
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
      containers:
      - name: ray-worker
        image: rayproject/ray:2.9.0-py310-gpu
        resources:
          requests:
            cpu: "4"
            memory: "16Gi"
            nvidia.com/gpu: "1"

# GPU workers for training (larger GPUs)
- groupName: gpu-training
  replicas: 0
  minReplicas: 0
  maxReplicas: 4
  rayStartParams:
    resources: '"{\"training\": 1}"'
  template:
    spec:
      nodeSelector:
        nvidia.com/gpu.product: A100-SXM4-80GB
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
      containers:
      - name: ray-worker
        image: rayproject/ray:2.9.0-py310-gpu
        resources:
          requests:
            cpu: "24"
            memory: "200Gi"
            nvidia.com/gpu: "8"
```

### Targeting specific worker groups

```python
# Target inference GPUs
@ray.remote(resources={"inference": 1}, num_gpus=1)
def run_inference(model_ref, data):
    ...

# Target training GPUs
@ray.remote(resources={"training": 1}, num_gpus=8)
def run_training(config):
    ...

# Target CPU preprocessing
@ray.remote(resources={"preprocessing": 1}, num_cpus=4)
def preprocess(data):
    ...
```

## GPU Scheduling

### NVIDIA GPU operator prerequisites

```bash
# Install NVIDIA GPU Operator (if not using managed K8s with GPU support)
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace
```

### Fractional GPU sharing

```yaml
# Multiple models sharing one GPU
workerGroupSpecs:
- groupName: shared-gpu
  template:
    spec:
      containers:
      - name: ray-worker
        resources:
          requests:
            nvidia.com/gpu: "1"
          limits:
            nvidia.com/gpu: "1"
```

```python
# Two models on one GPU (0.5 each)
@serve.deployment(ray_actor_options={"num_gpus": 0.5})
class ModelA:
    ...

@serve.deployment(ray_actor_options={"num_gpus": 0.5})
class ModelB:
    ...
```

### Multi-GPU workers

```yaml
- groupName: multi-gpu
  template:
    spec:
      containers:
      - name: ray-worker
        resources:
          requests:
            nvidia.com/gpu: "4"
          limits:
            nvidia.com/gpu: "4"
        env:
        - name: CUDA_VISIBLE_DEVICES
          value: "0,1,2,3"
```

### GPU memory management

```python
# Set per-process GPU memory fraction
import torch
torch.cuda.set_per_process_memory_fraction(0.45)  # Leave room for other processes

# Or use environment variable
# CUDA_MPS_ACTIVE_THREAD_PERCENTAGE=50
```

## Persistent Storage

### Shared storage with PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ray-shared-storage
  namespace: ray-workloads
spec:
  accessModes:
  - ReadWriteMany  # Must be RWX for shared access
  storageClassName: efs-sc  # Or nfs-sc, azurefile-sc
  resources:
    requests:
      storage: 100Gi
---
# Reference in RayCluster
spec:
  headGroupSpec:
    template:
      spec:
        containers:
        - name: ray-head
          volumeMounts:
          - name: shared
            mountPath: /mnt/data
        volumes:
        - name: shared
          persistentVolumeClaim:
            claimName: ray-shared-storage

  workerGroupSpecs:
  - template:
      spec:
        containers:
        - name: ray-worker
          volumeMounts:
          - name: shared
            mountPath: /mnt/data
        volumes:
        - name: shared
          persistentVolumeClaim:
            claimName: ray-shared-storage
```

### Model caching with hostPath

```yaml
containers:
- name: ray-worker
  volumeMounts:
  - name: model-cache
    mountPath: /models
volumes:
- name: model-cache
  hostPath:
    path: /mnt/model-cache
    type: DirectoryOrCreate
```

### S3/GCS access

```yaml
containers:
- name: ray-worker
  env:
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: aws-credentials
        key: access-key
  - name: AWS_SECRET_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: aws-credentials
        key: secret-key
  - name: AWS_DEFAULT_REGION
    value: us-east-1
```

Or with IRSA (IAM Roles for Service Accounts) on EKS:
```yaml
spec:
  serviceAccountName: ray-s3-access  # SA annotated with IAM role
```

## Monitoring with Prometheus and Grafana

### ServiceMonitor for Prometheus Operator

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ray-monitor
  namespace: ray-production
  labels:
    release: prometheus  # Match your Prometheus Operator selector
spec:
  selector:
    matchLabels:
      ray.io/cluster: production-cluster
  endpoints:
  - port: metrics
    interval: 15s
    path: /metrics
  namespaceSelector:
    matchNames:
    - ray-production
```

### Prometheus scrape config (without Operator)

```yaml
# prometheus.yml
scrape_configs:
- job_name: ray
  kubernetes_sd_configs:
  - role: pod
    namespaces:
      names: [ray-production]
  relabel_configs:
  - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
    action: keep
    regex: true
  - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
    action: replace
    target_label: __address__
    regex: (.+)
    replacement: ${1}:$1
```

### Key metrics to monitor

| Metric | Description | Alert threshold |
|--------|-------------|-----------------|
| `ray_node_cpu_utilization` | CPU usage per node | >90% sustained |
| `ray_node_mem_used` | Memory usage | >85% |
| `ray_node_gpus_utilization` | GPU utilization | <20% (underutilized) |
| `ray_object_store_used_memory` | Object store usage | >80% |
| `ray_serve_num_ongoing_requests` | Active requests | Sudden spikes |
| `ray_serve_request_latency_ms` | Serve latency | p99 > SLA |
| `ray_serve_num_replicas` | Replica count | At max_replicas |
| `ray_cluster_active_nodes` | Total nodes | Unexpected changes |

### Grafana dashboard

Import the official Ray Grafana dashboard:
- Dashboard ID: 16850 (Ray Overview)
- Dashboard ID: 16851 (Ray Serve)

Or create custom panels:

```json
{
  "title": "Ray Serve Latency p99",
  "targets": [{
    "expr": "histogram_quantile(0.99, sum(rate(ray_serve_request_latency_ms_bucket[5m])) by (le, deployment))",
    "legendFormat": "{{deployment}}"
  }]
}
```

### Alerting rules

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ray-alerts
spec:
  groups:
  - name: ray.rules
    rules:
    - alert: RayObjectStoreNearFull
      expr: ray_object_store_used_memory / ray_object_store_available_memory > 0.85
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Ray object store is above 85% capacity"

    - alert: RayServeHighLatency
      expr: histogram_quantile(0.99, sum(rate(ray_serve_request_latency_ms_bucket[5m])) by (le)) > 1000
      for: 10m
      labels:
        severity: critical
      annotations:
        summary: "Ray Serve p99 latency exceeds 1 second"

    - alert: RayNodeDown
      expr: up{job="ray"} == 0
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Ray node is unreachable"
```

## Production Cluster Sizing

### Sizing guidelines

| Workload | Head node | Workers | Object store |
|----------|-----------|---------|--------------|
| Development | 2 CPU, 4 GB | 2×4 CPU, 8 GB | Default (30%) |
| Batch ML training | 4 CPU, 16 GB | 4-8×8 CPU, 32 GB, 1 GPU | 8-16 GB |
| Model serving (low) | 4 CPU, 8 GB | 2-4×4 CPU, 16 GB, 1 GPU | 4-8 GB |
| Model serving (high) | 8 CPU, 32 GB | 8-20×8 CPU, 32 GB, 1 GPU | 8-16 GB |
| LLM serving | 8 CPU, 32 GB | 4-8×16 CPU, 64 GB, 4 GPU | 16-32 GB |
| Data processing | 4 CPU, 16 GB | 10-50×8 CPU, 32 GB | 16-32 GB |

### Head node sizing rules
- **Always set `num-cpus: "0"`** — head should not run compute tasks
- Memory: 2× the expected GCS metadata size (grows with cluster size)
- For clusters >50 nodes: 8+ CPU, 32+ GB RAM for head
- Use dedicated node pool (nodeSelector + tolerations)

### Worker node sizing rules
- Match CPU/memory to workload granularity
- GPU workers: ensure CUDA memory fits model + batch
- Object store: 30% of RAM by default; increase for data-heavy workloads
- Use pod disruption budgets for graceful scaling

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ray-worker-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      ray.io/node-type: worker
```

## Multi-Tenancy

### Namespace isolation

```yaml
# Per-team namespaces
apiVersion: v1
kind: Namespace
metadata:
  name: ray-team-alpha
  labels:
    team: alpha
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-alpha-quota
  namespace: ray-team-alpha
spec:
  hard:
    requests.cpu: "64"
    requests.memory: "256Gi"
    requests.nvidia.com/gpu: "8"
    pods: "50"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: team-alpha-limits
  namespace: ray-team-alpha
spec:
  limits:
  - default:
      cpu: "4"
      memory: "8Gi"
    defaultRequest:
      cpu: "2"
      memory: "4Gi"
    type: Container
```

### Network isolation

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ray-cluster-isolation
  namespace: ray-team-alpha
spec:
  podSelector:
    matchLabels:
      ray.io/cluster: team-alpha-cluster
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Allow intra-cluster communication
  - from:
    - podSelector:
        matchLabels:
          ray.io/cluster: team-alpha-cluster
  # Allow ingress from load balancer
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-system
    ports:
    - port: 8000
  egress:
  # Allow intra-cluster and DNS
  - to:
    - podSelector:
        matchLabels:
          ray.io/cluster: team-alpha-cluster
  - to:
    - namespaceSelector: {}
    ports:
    - port: 53
      protocol: UDP
```

### Priority classes

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: ray-production
value: 1000000
globalDefault: false
description: "Priority for production Ray clusters"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: ray-development
value: 100000
globalDefault: false
---
# Reference in RayCluster
spec:
  workerGroupSpecs:
  - template:
      spec:
        priorityClassName: ray-production
```

## Security

### RBAC

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ray-head
  namespace: ray-production
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ray-head-role
  namespace: ray-production
rules:
- apiGroups: [""]
  resources: ["pods", "pods/status", "pods/log"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ray-head-binding
  namespace: ray-production
subjects:
- kind: ServiceAccount
  name: ray-head
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ray-head-role
```

### Pod security

```yaml
containers:
- name: ray-worker
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    readOnlyRootFilesystem: false  # Ray needs /tmp
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
```

### Secrets management

```yaml
# Use external secrets operator or vault
containers:
- name: ray-head
  env:
  - name: RAY_TLS_SERVER_CERT
    valueFrom:
      secretKeyRef:
        name: ray-tls
        key: tls.crt
  - name: RAY_TLS_SERVER_KEY
    valueFrom:
      secretKeyRef:
        name: ray-tls
        key: tls.key
  - name: RAY_TLS_CA_CERT
    valueFrom:
      secretKeyRef:
        name: ray-tls
        key: ca.crt
```

## Networking

### Ingress for Ray Serve

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ray-serve-ingress
  namespace: ray-production
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
spec:
  ingressClassName: nginx
  rules:
  - host: ml-api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ml-serving-serve-svc
            port:
              number: 8000
  tls:
  - hosts:
    - ml-api.example.com
    secretName: ml-api-tls
```

### Internal service mesh

```yaml
# Istio VirtualService for traffic management
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ray-serve-vs
spec:
  hosts:
  - ml-api.example.com
  http:
  - route:
    - destination:
        host: ml-serving-serve-svc
        port:
          number: 8000
    timeout: 60s
    retries:
      attempts: 3
      retryOn: 5xx
```

## Upgrades and Maintenance

### Upgrading Ray version

1. Update container images in the CRD
2. Apply with `kubectl apply`
3. For RayService: automatic zero-downtime upgrade
4. For RayCluster: rolling restart required

```bash
# Rolling restart of workers
kubectl rollout restart deployment -l ray.io/cluster=my-cluster -n ray-production
```

### Upgrading KubeRay operator

```bash
helm upgrade kuberay-operator kuberay/kuberay-operator \
    --version 1.2.0 \
    -n ray-system

# CRDs are updated automatically with helm upgrade
```

### Draining a node

```bash
# Cordon the node
kubectl cordon <node-name>

# Wait for Ray autoscaler to move workloads
# Or manually drain
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

## Troubleshooting KubeRay

### Quick diagnostics

```bash
# Operator status
kubectl get pods -n ray-system
kubectl logs -l app.kubernetes.io/name=kuberay-operator -n ray-system --tail=100

# Cluster status
kubectl get rayclusters -A
kubectl describe raycluster <name> -n <ns>

# Pod status
kubectl get pods -l ray.io/cluster=<name> -n <ns>
kubectl describe pod <pod> -n <ns>
kubectl logs <pod> -n <ns> --tail=200

# Events
kubectl get events -n <ns> --sort-by=.metadata.creationTimestamp | tail -20
```

### Common issues

| Issue | Check | Fix |
|-------|-------|-----|
| Pods pending | `kubectl describe pod` → Events | Increase node pool / check resource quotas |
| Image pull error | `kubectl describe pod` → Events | Fix image tag / add imagePullSecrets |
| Head not ready | `kubectl logs <head>` | Check readiness probe / increase resources |
| Workers can't join | Worker logs + DNS | Check head service / network policies |
| Autoscaler not scaling | Autoscaler logs | Check min/maxReplicas / resource availability |
| RayService stuck | Operator logs | Check serveConfigV2 syntax / import paths |
