# K3s Edge and IoT Deployment Guide

## Table of Contents

- [Overview](#overview)
- [Minimal Resource Requirements](#minimal-resource-requirements)
  - [Hardware Minimums](#hardware-minimums)
  - [Tuning for Constrained Devices](#tuning-for-constrained-devices)
  - [Disabling Unnecessary Components](#disabling-unnecessary-components)
- [Air-Gap Installation](#air-gap-installation)
  - [Preparing the Bundle](#preparing-the-bundle)
  - [Installing Without Internet](#installing-without-internet)
  - [Updating Air-Gap Installations](#updating-air-gap-installations)
- [Private Registry Mirrors](#private-registry-mirrors)
  - [Mirror Configuration](#mirror-configuration)
  - [Authentication](#authentication)
  - [Local Registry on Edge](#local-registry-on-edge)
- [Auto-Deploying Manifests](#auto-deploying-manifests)
  - [Manifest Directory](#manifest-directory)
  - [HelmChart CRD for Edge](#helmchart-crd-for-edge)
  - [GitOps with Auto-Deploy](#gitops-with-auto-deploy)
- [Remote Management with Rancher](#remote-management-with-rancher)
  - [Registering K3s with Rancher](#registering-k3s-with-rancher)
  - [Rancher Downstream Cluster Management](#rancher-downstream-cluster-management)
  - [Remote kubectl Access](#remote-kubectl-access)
- [Fleet Management](#fleet-management)
  - [Rancher Fleet Overview](#rancher-fleet-overview)
  - [Fleet GitOps Workflow](#fleet-gitops-workflow)
  - [Fleet Bundle Targets](#fleet-bundle-targets)
  - [Scaling to Thousands of Clusters](#scaling-to-thousands-of-clusters)
- [ARM Support](#arm-support)
  - [ARM64 (aarch64)](#arm64-aarch64)
  - [ARMv7 (armhf)](#armv7-armhf)
  - [Multi-Architecture Images](#multi-architecture-images)
  - [Raspberry Pi Deployment](#raspberry-pi-deployment)
- [Read-Only Root Filesystem](#read-only-root-filesystem)
  - [Configuring Read-Only Root](#configuring-read-only-root)
  - [Required Writable Mounts](#required-writable-mounts)
  - [Overlay Filesystem Pattern](#overlay-filesystem-pattern)
- [Agent-Only Nodes](#agent-only-nodes)
  - [When to Use Agent-Only Nodes](#when-to-use-agent-only-nodes)
  - [Agent Configuration](#agent-configuration)
  - [Hub-and-Spoke Topology](#hub-and-spoke-topology)
- [Network Constraints](#network-constraints)
  - [Low-Bandwidth Links](#low-bandwidth-links)
  - [High-Latency Connections](#high-latency-connections)
  - [Intermittent Connectivity](#intermittent-connectivity)
  - [Network Address Translation](#network-address-translation)
- [Satellite and Disconnected Operation](#satellite-and-disconnected-operation)
  - [Fully Disconnected Clusters](#fully-disconnected-clusters)
  - [Store-and-Forward Patterns](#store-and-forward-patterns)
  - [Autonomous Edge Operation](#autonomous-edge-operation)
  - [Reconnection and Reconciliation](#reconnection-and-reconciliation)
- [Edge Security Considerations](#edge-security-considerations)
- [Edge Deployment Patterns](#edge-deployment-patterns)

---

## Overview

K3s is designed for edge computing and IoT environments where resources are limited, connectivity is unreliable, and physical access may be restricted. Its single-binary architecture, low memory footprint, and support for ARM processors make it ideal for:

- **Retail:** Point-of-sale systems, digital signage, inventory management
- **Manufacturing:** Factory floor controllers, quality inspection, SCADA integration
- **Telecommunications:** Cell tower compute, 5G MEC (Multi-access Edge Computing)
- **Agriculture:** Sensor aggregation, autonomous equipment, greenhouse control
- **Transportation:** Vehicle fleet computing, traffic management, logistics
- **Healthcare:** Medical device gateways, patient monitoring, lab automation
- **Energy:** Wind turbine controllers, solar farm monitoring, smart grid nodes

## Minimal Resource Requirements

### Hardware Minimums

| Role | CPU | RAM | Disk | Notes |
|------|-----|-----|------|-------|
| Server (minimal) | 1 core | 512 MB | 2 GB | Single-node, minimal workload |
| Server (production) | 2 cores | 2 GB | 20 GB | With system pods and workloads |
| Agent (minimal) | 1 core | 256 MB | 1 GB | Running 1-2 simple pods |
| Agent (production) | 2 cores | 1 GB | 10 GB | Running multiple workloads |

K3s binary itself is ~60-70 MB. The air-gap image tarball is ~200-400 MB depending on version.

### Tuning for Constrained Devices

```yaml
# /etc/rancher/k3s/config.yaml — minimal edge server
disable:
  - traefik
  - servicelb
  - metrics-server
  - local-path-provisioner    # Only if no PVCs needed

kubelet-arg:
  - max-pods=20
  - eviction-hard=memory.available<50Mi,nodefs.available<5%
  - eviction-soft=memory.available<100Mi,nodefs.available<10%
  - eviction-soft-grace-period=memory.available=30s,nodefs.available=1m
  - system-reserved=cpu=100m,memory=128Mi
  - kube-reserved=cpu=100m,memory=128Mi
  - image-gc-high-threshold=90
  - image-gc-low-threshold=80
  - serialize-image-pulls=true

kube-apiserver-arg:
  - max-requests-inflight=100
  - max-mutating-requests-inflight=50

kube-controller-manager-arg:
  - node-monitor-period=30s
  - node-monitor-grace-period=120s
```

### Disabling Unnecessary Components

```yaml
# Aggressive component trimming for minimal footprint
disable:
  - traefik            # -20 MB RAM; use NodePort or custom ingress
  - servicelb          # -10 MB RAM per LB service
  - metrics-server     # -15 MB RAM; skip if not monitoring
  - local-path-provisioner  # -10 MB RAM; skip if using hostPath directly

# Disable network policy controller (if not using NetworkPolicy resources)
disable-network-policy: true

# Disable cloud controller
disable-cloud-controller: true

# Use lighter flannel backend
flannel-backend: host-gw    # Less overhead than VXLAN; requires L2 adjacency
```

Approximate memory savings:

| Component Disabled | RAM Saved |
|-------------------|-----------|
| Traefik | ~20-50 MB |
| ServiceLB | ~10-20 MB per service |
| metrics-server | ~15-30 MB |
| local-path-provisioner | ~10-15 MB |
| Network policy controller | ~10-15 MB |

## Air-Gap Installation

### Preparing the Bundle

On an internet-connected machine, download all components:

```bash
#!/bin/bash
K3S_VERSION="v1.30.2+k3s1"
ARCH="amd64"  # or arm64, arm

# Create staging directory
mkdir -p k3s-airgap-bundle && cd k3s-airgap-bundle

# Download K3s binary
curl -fSL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s" -o k3s
chmod +x k3s

# Download air-gap images
curl -fSL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-airgap-images-${ARCH}.tar.zst" \
  -o k3s-airgap-images-${ARCH}.tar.zst

# Download install script
curl -fSL https://get.k3s.io -o install.sh
chmod +x install.sh

# Download checksums for verification
curl -fSL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/sha256sum-${ARCH}.txt" \
  -o sha256sum.txt

# Bundle everything
cd ..
tar czf k3s-airgap-bundle-${K3S_VERSION}-${ARCH}.tar.gz k3s-airgap-bundle/
```

### Installing Without Internet

```bash
# Transfer bundle to edge device (USB, SCP, satellite link, etc.)
tar xzf k3s-airgap-bundle-*.tar.gz
cd k3s-airgap-bundle

# Verify checksums
sha256sum -c sha256sum.txt --ignore-missing

# Install binary
sudo cp k3s /usr/local/bin/k3s
sudo chmod +x /usr/local/bin/k3s

# Place images
sudo mkdir -p /var/lib/rancher/k3s/agent/images/
sudo cp k3s-airgap-images-*.tar.zst /var/lib/rancher/k3s/agent/images/

# Create config
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml << 'EOF'
disable:
  - traefik
  - servicelb
write-kubeconfig-mode: "0644"
EOF

# Run install script (skip download)
INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh

# Verify
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
```

### Updating Air-Gap Installations

```bash
# 1. Prepare new version bundle on internet-connected machine
# 2. Transfer to edge device
# 3. Replace binary and images
sudo systemctl stop k3s
sudo cp k3s-new /usr/local/bin/k3s
sudo cp k3s-airgap-images-*.tar.zst /var/lib/rancher/k3s/agent/images/
sudo systemctl start k3s

# Or use the install script with INSTALL_K3S_SKIP_DOWNLOAD
INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh
```

## Private Registry Mirrors

### Mirror Configuration

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  # Mirror Docker Hub to local registry
  docker.io:
    endpoint:
      - "https://registry.edge-site.local:5000"
  # Mirror GitHub Container Registry
  ghcr.io:
    endpoint:
      - "https://registry.edge-site.local:5000"
  # Wildcard — mirror all registries
  "*":
    endpoint:
      - "https://registry.edge-site.local:5000"
```

### Authentication

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  docker.io:
    endpoint:
      - "https://registry.edge-site.local:5000"
configs:
  "registry.edge-site.local:5000":
    auth:
      username: edge-user
      password: edge-password
    tls:
      ca_file: /etc/rancher/k3s/certs/registry-ca.crt
```

### Local Registry on Edge

Run a local registry on each edge site for caching:

```yaml
# Deploy registry as a K3s auto-deploy manifest
# /var/lib/rancher/k3s/server/manifests/local-registry.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
        - name: registry
          image: registry:2
          ports:
            - containerPort: 5000
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
          env:
            - name: REGISTRY_PROXY_REMOTEURL
              value: "https://registry-1.docker.io"
      volumes:
        - name: data
          hostPath:
            path: /opt/registry-data
            type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: registry
spec:
  type: NodePort
  ports:
    - port: 5000
      nodePort: 30500
  selector:
    app: registry
```

## Auto-Deploying Manifests

### Manifest Directory

K3s watches `/var/lib/rancher/k3s/server/manifests/` and automatically applies any YAML files placed there:

```bash
# Place manifests for auto-deployment
sudo cp my-app.yaml /var/lib/rancher/k3s/server/manifests/

# K3s applies manifests on startup and when files change
# Deleting a file does NOT delete the deployed resources (by default)
# To track deletions, rename with .skip extension
sudo mv my-app.yaml my-app.yaml.skip
```

This is ideal for edge devices that receive pre-configured SD cards or USB provisioning bundles.

### HelmChart CRD for Edge

Deploy Helm charts without the Helm CLI — perfect for constrained devices:

```yaml
# /var/lib/rancher/k3s/server/manifests/edge-monitoring.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: node-exporter
  namespace: kube-system
spec:
  repo: https://prometheus-community.github.io/helm-charts
  chart: prometheus-node-exporter
  version: "4.24.0"
  targetNamespace: monitoring
  createNamespace: true
  valuesContent: |-
    resources:
      requests:
        cpu: 50m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 64Mi
```

### GitOps with Auto-Deploy

For sites with intermittent connectivity, use a pull-based GitOps approach:

```bash
# Simple cron-based git sync (lightweight alternative to Flux/Argo)
cat > /etc/cron.d/k3s-gitops << 'EOF'
*/5 * * * * root cd /opt/gitops-repo && git pull --ff-only 2>/dev/null && \
  rsync -av --delete manifests/ /var/lib/rancher/k3s/server/manifests/custom/
EOF
```

## Remote Management with Rancher

### Registering K3s with Rancher

```bash
# From Rancher UI: Cluster Management → Import Existing → Generic
# Copy the registration command and run on K3s server:

kubectl apply -f https://rancher.example.com/v3/import/CLUSTER_TOKEN.yaml

# For air-gap: download the YAML, transfer to edge, apply locally
curl -sfL https://rancher.example.com/v3/import/CLUSTER_TOKEN.yaml -o import.yaml
kubectl apply -f import.yaml
```

### Rancher Downstream Cluster Management

Once registered, Rancher provides:
- **Centralized monitoring** — Prometheus/Grafana dashboards per cluster
- **User management** — RBAC across all clusters
- **App catalog** — Deploy apps to edge clusters from a central catalog
- **Cluster templates** — Standardize edge configurations
- **Backup/restore** — Centralized backup management

### Remote kubectl Access

```bash
# Via Rancher proxy (no direct access to edge cluster needed)
# Rancher UI → Cluster → Download KubeConfig

# Or via Rancher CLI
rancher login https://rancher.example.com --token <API_TOKEN>
rancher kubectl --cluster <CLUSTER_NAME> get nodes
```

## Fleet Management

### Rancher Fleet Overview

Fleet is a GitOps engine designed to manage thousands of Kubernetes clusters. It runs on a central management cluster and pushes configurations to downstream clusters.

```
┌─────────────────────────┐
│   Management Cluster    │
│   (Rancher + Fleet)     │
│         │                │
│    Git Repository        │
│    ┌──────────┐          │
│    │ manifests│          │
│    └──────────┘          │
└─────────┬───────────────┘
          │
    ┌─────┼─────┬─────────┐
    ▼     ▼     ▼         ▼
┌──────┐┌──────┐┌──────┐┌──────┐
│Edge 1││Edge 2││Edge 3││Edge N│
│(K3s) ││(K3s) ││(K3s) ││(K3s) │
└──────┘└──────┘└──────┘└──────┘
```

### Fleet GitOps Workflow

```yaml
# fleet.yaml — controls how Fleet deploys to target clusters
defaultNamespace: edge-apps
helm:
  releaseName: edge-monitoring
  chart: ./charts/monitoring
  values:
    replicas: 1
    resources:
      limits:
        memory: 128Mi

targetCustomizations:
  - name: high-resource-sites
    clusterSelector:
      matchLabels:
        tier: high
    helm:
      values:
        replicas: 2
        resources:
          limits:
            memory: 256Mi
```

### Fleet Bundle Targets

```yaml
# GitRepo targeting specific clusters
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: edge-apps
  namespace: fleet-default
spec:
  repo: https://git.example.com/edge/manifests
  branch: main
  paths:
    - /base
    - /overlays/production
  targets:
    - name: all-edge
      clusterSelector:
        matchLabels:
          location: edge
    - name: gpu-sites
      clusterSelector:
        matchExpressions:
          - key: gpu
            operator: In
            values: ["nvidia", "amd"]
```

### Scaling to Thousands of Clusters

Fleet design considerations for large-scale edge:
- **Cluster labels** — Use a consistent labeling scheme (region, site-id, tier, hardware)
- **Bundle size** — Keep Git repos small; split by function
- **Reconciliation interval** — Increase for constrained networks (default 15 min)
- **Agent resources** — Fleet agent runs on each downstream cluster (~50 MB RAM)
- **Cluster groups** — Organize clusters into logical groups for targeted deployments

## ARM Support

### ARM64 (aarch64)

K3s fully supports ARM64. Download the ARM64 binary:

```bash
# ARM64 install
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -

# The install script auto-detects architecture
# Or specify explicitly:
curl -fSL https://github.com/k3s-io/k3s/releases/download/v1.30.2+k3s1/k3s-arm64 -o k3s
```

### ARMv7 (armhf)

```bash
# ARMv7 install
curl -sfL https://get.k3s.io | sh -

# Manual download
curl -fSL https://github.com/k3s-io/k3s/releases/download/v1.30.2+k3s1/k3s-armhf -o k3s
```

### Multi-Architecture Images

When building images for edge deployment across architectures:

```dockerfile
# Use multi-arch base images
FROM --platform=$TARGETPLATFORM alpine:3.19
# Application code works on both amd64 and arm64
```

```bash
# Build multi-arch with Docker Buildx
docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 \
  -t registry.example.com/edge-app:v1.0 --push .
```

### Raspberry Pi Deployment

```bash
# Raspberry Pi 4/5 (ARM64) — recommended config
# /etc/rancher/k3s/config.yaml
write-kubeconfig-mode: "0644"
disable:
  - traefik
  - servicelb
kubelet-arg:
  - max-pods=30
  - eviction-hard=memory.available<100Mi,nodefs.available<10%
  - system-reserved=cpu=200m,memory=256Mi
```

Additional Raspberry Pi considerations:
- **cgroup memory:** Add `cgroup_memory=1 cgroup_enable=memory` to `/boot/cmdline.txt`
- **Storage:** Use a quality SD card (A2 class) or USB SSD. Avoid cheap SD cards — they fail under sustained writes.
- **Power:** Use official power supply. Brown-outs cause filesystem corruption.
- **Swap:** Enable a small swap file (1-2 GB) for resilience:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
```

## Read-Only Root Filesystem

### Configuring Read-Only Root

Edge devices often use read-only root filesystems for reliability and security:

```bash
# Boot with read-only root
# In /etc/fstab:
# /dev/mmcblk0p2  /  ext4  ro,noatime  0  1

# Or remount at runtime:
sudo mount -o remount,ro /
```

### Required Writable Mounts

K3s needs certain paths writable. Mount these as tmpfs or on a separate writable partition:

```bash
# /etc/fstab entries for K3s on read-only root
tmpfs  /var/lib/rancher  tmpfs  rw,size=512M  0  0
tmpfs  /var/log          tmpfs  rw,size=128M  0  0
tmpfs  /tmp              tmpfs  rw,size=64M   0  0
tmpfs  /run              tmpfs  rw,mode=755   0  0

# If using persistent storage, use a separate writable partition:
/dev/mmcblk0p3  /var/lib/rancher  ext4  rw,noatime  0  2
```

### Overlay Filesystem Pattern

Use overlayfs for a read-only base with writable overlay:

```bash
# Create overlay for /etc (needed for K3s config)
mount -t overlay overlay \
  -o lowerdir=/etc,upperdir=/run/overlay-etc/upper,workdir=/run/overlay-etc/work \
  /etc
```

K3s configuration for read-only root:

```yaml
# /etc/rancher/k3s/config.yaml
data-dir: /var/lib/rancher/k3s    # Must be writable
write-kubeconfig-mode: "0644"
# If /tmp is tmpfs, ensure enough space for containerd:
# containerd uses /tmp for image extraction
```

## Agent-Only Nodes

### When to Use Agent-Only Nodes

Agent-only nodes run kubelet and containerd but not the control plane. Use them for:
- **Compute-only edge devices** — sensors, cameras, actuators
- **Resource-constrained hardware** — devices that can't run API server
- **Hub-and-spoke topology** — central server(s) with remote agents

### Agent Configuration

```bash
# Install agent only
curl -sfL https://get.k3s.io | K3S_URL=https://<SERVER_OR_LB>:6443 \
  K3S_TOKEN=<TOKEN> sh -
```

```yaml
# /etc/rancher/k3s/config.yaml (agent)
server: https://hub.example.com:6443
token: "<TOKEN>"
node-label:
  - role=edge-worker
  - location=building-a
kubelet-arg:
  - max-pods=10
  - eviction-hard=memory.available<50Mi
```

### Hub-and-Spoke Topology

```
                 ┌─────────────────────┐
     Internet    │   Cloud/DC Hub      │
    ─────────────│  K3s Server (HA)    │
                 │  + Load Balancer    │
                 └──────────┬──────────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
    ┌─────────▼──┐  ┌──────▼─────┐  ┌───▼──────────┐
    │  Site A    │  │  Site B    │  │  Site C      │
    │  Agent(s)  │  │  Agent(s)  │  │  Agent(s)    │
    │  + Workload│  │  + Workload│  │  + Workload  │
    └────────────┘  └────────────┘  └──────────────┘
```

Considerations:
- Agents tolerate API server disconnection (pods keep running)
- kubelet caches pod specs and continues operation during outages
- New pods cannot be scheduled during disconnection
- Use `node-status-update-frequency` to reduce heartbeat traffic:

```yaml
# Agent config — reduce heartbeat frequency for slow links
kubelet-arg:
  - node-status-update-frequency=60s   # Default is 10s
```

## Network Constraints

### Low-Bandwidth Links

```yaml
# Reduce K3s network overhead
flannel-backend: host-gw       # No encapsulation overhead (requires L2 adjacency)
# Or for cross-subnet:
flannel-backend: wireguard-native  # Encrypted but efficient

kubelet-arg:
  - node-status-update-frequency=30s
  - image-pull-progress-deadline=30m     # Allow slow pulls
  - serialize-image-pulls=true           # Don't saturate bandwidth

kube-controller-manager-arg:
  - node-monitor-period=30s
  - node-monitor-grace-period=120s       # Don't evict nodes prematurely
```

### High-Latency Connections

For satellite, cellular, or other high-latency links:

```yaml
# Server config
kube-apiserver-arg:
  - request-timeout=300s                 # Increase for slow clients
  - min-request-timeout=300

# Agent config
kubelet-arg:
  - node-status-update-frequency=60s
  - http-check-frequency=60s
  - sync-frequency=120s                  # Reduce kubelet sync frequency

# etcd (if using HA — not recommended over high-latency links)
# etcd-arg:
#   - heartbeat-interval=1000
#   - election-timeout=10000
```

### Intermittent Connectivity

K3s agents handle intermittent connectivity gracefully:

- **Pods keep running** during API server disconnection
- **kubelet caches** pod specs and container states
- **Node status** becomes `NotReady` after grace period, but pods aren't evicted immediately

Tuning for intermittent links:

```yaml
# Server config — be patient with disconnected nodes
kube-controller-manager-arg:
  - node-monitor-grace-period=300s       # 5 minutes before NotReady
  - pod-eviction-timeout=600s            # 10 minutes before evicting pods

# Agent config
kubelet-arg:
  - node-status-update-frequency=30s
```

### Network Address Translation

Agents behind NAT connecting to a remote server:

```bash
# Agent behind NAT — specify the external IP
curl -sfL https://get.k3s.io | K3S_URL=https://<SERVER_PUBLIC_IP>:6443 \
  K3S_TOKEN=<TOKEN> sh -s - agent \
  --node-external-ip=<AGENT_PUBLIC_IP> \
  --node-ip=<AGENT_PRIVATE_IP>
```

For Flannel across NAT:

```yaml
# Use WireGuard which handles NAT traversal
flannel-backend: wireguard-native
```

## Satellite and Disconnected Operation

### Fully Disconnected Clusters

For sites with no connectivity to a central control plane:

```bash
# Install a full K3s server at each site (not just agent)
# Each site is an independent, self-contained cluster

# Air-gap install with all images pre-loaded
INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh

# Pre-load application images
sudo k3s ctr images import /path/to/app-images.tar
```

### Store-and-Forward Patterns

For sites with periodic connectivity (e.g., daily satellite window):

```bash
#!/bin/bash
# sync-when-connected.sh — runs via cron or connectivity trigger

CENTRAL_API="https://central.example.com"
LOCAL_MANIFESTS="/var/lib/rancher/k3s/server/manifests/managed/"

# Check connectivity
if curl -sf --max-time 10 "${CENTRAL_API}/health" > /dev/null 2>&1; then
  echo "$(date): Connection available — syncing"

  # Pull latest manifests
  rsync -avz --delete \
    central-server:/opt/fleet-manifests/ \
    "${LOCAL_MANIFESTS}"

  # Push metrics/logs
  kubectl get --raw /metrics | \
    curl -X POST -d @- "${CENTRAL_API}/api/v1/metrics/$(hostname)"

  # Push events
  kubectl get events -A -o json | \
    curl -X POST -d @- "${CENTRAL_API}/api/v1/events/$(hostname)"
else
  echo "$(date): No connection — operating autonomously"
fi
```

### Autonomous Edge Operation

Design workloads for autonomous operation:

```yaml
# Edge application with local data persistence
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-collector
  namespace: edge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: edge-collector
  template:
    metadata:
      labels:
        app: edge-collector
    spec:
      containers:
        - name: collector
          image: registry.local:5000/edge-collector:v1.0
          env:
            - name: DATA_BUFFER_SIZE
              value: "10000"       # Buffer data locally
            - name: SYNC_ENDPOINT
              value: "https://central.example.com/api/data"
            - name: SYNC_RETRY_INTERVAL
              value: "300"         # Retry sync every 5 min
            - name: OFFLINE_MODE
              value: "auto"        # Detect connectivity
          volumeMounts:
            - name: data-buffer
              mountPath: /data
      volumes:
        - name: data-buffer
          hostPath:
            path: /opt/edge-data
            type: DirectoryOrCreate
```

### Reconnection and Reconciliation

When connectivity is restored:

1. **Agent reconnects automatically** — kubelet re-establishes API server connection
2. **Node status updates** — transitions from `NotReady` to `Ready`
3. **Pending changes apply** — any queued scheduling decisions execute
4. **Fleet/GitOps syncs** — pull latest desired state from Git

Handle reconciliation conflicts:

```yaml
# Use server-side apply to handle conflicts
# In Fleet or ArgoCD:
spec:
  syncPolicy:
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
```

## Edge Security Considerations

Security is critical at the edge where physical access may not be controlled:

```yaml
# /etc/rancher/k3s/config.yaml — hardened edge config
secrets-encryption: true
protect-kernel-defaults: true

kube-apiserver-arg:
  - anonymous-auth=false
  - enable-admission-plugins=NodeRestriction,PodSecurity
  - audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log
  - audit-log-maxage=7
  - audit-log-maxsize=50

# Restrict kubelet
kubelet-arg:
  - read-only-port=0                # Disable unauthenticated port
  - streaming-connection-idle-timeout=5m
  - protect-kernel-defaults=true
```

Additional edge security measures:
- **Encrypt disks** — Use LUKS/dm-crypt for data at rest
- **Secure boot** — Enable UEFI Secure Boot if hardware supports it
- **Network segmentation** — Isolate K3s management traffic from workload traffic
- **Certificate pinning** — Use custom CA certificates
- **Physical tamper detection** — Monitor for case intrusion events

## Edge Deployment Patterns

### Pattern 1: Single-Node Edge

```
┌─────────────────────┐
│  Edge Device         │
│  K3s Server+Agent    │
│  ┌─────┐ ┌─────┐   │
│  │App 1│ │App 2│   │
│  └─────┘ └─────┘   │
│  Local storage      │
└─────────────────────┘
```

Use for: Simple workloads, single-purpose devices.

### Pattern 2: Multi-Node Edge Site

```
┌──────────────────────────────────┐
│  Edge Site                        │
│  ┌─────────┐  ┌─────────┐       │
│  │ Server  │──│ Agent 1 │       │
│  │ (K3s HA)│  │ (Worker)│       │
│  └─────────┘  └─────────┘       │
│       │       ┌─────────┐       │
│       └───────│ Agent 2 │       │
│               │ (Worker)│       │
│               └─────────┘       │
└──────────────────────────────────┘
```

Use for: Sites needing redundancy, multiple workloads, or specialized hardware (GPU nodes).

### Pattern 3: Hub and Spoke

```
Hub (Cloud/DC)              Edge Sites
┌──────────┐           ┌──────────────┐
│ K3s HA   │◄─────────►│ Site A Agent │
│ Server   │           └──────────────┘
│ + Rancher│           ┌──────────────┐
│ + Fleet  │◄─────────►│ Site B Agent │
└──────────┘           └──────────────┘
                       ┌──────────────┐
               ◄──────►│ Site C Agent │
                       └──────────────┘
```

Use for: Centralized management, consistent policy, sites with reliable connectivity to hub.

### Pattern 4: Mesh Federation

```
┌──────────┐     ┌──────────┐     ┌──────────┐
│ Cluster A│◄───►│ Cluster B│◄───►│ Cluster C│
│ (K3s)    │     │ (K3s)    │     │ (K3s)    │
└──────────┘     └──────────┘     └──────────┘
```

Use for: Peer-to-peer edge computing, distributed processing, multi-site service mesh.
