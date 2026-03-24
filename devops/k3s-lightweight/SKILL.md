---
name: k3s-lightweight
description: >
  Guide for deploying and managing K3s lightweight Kubernetes clusters. Covers single-node and
  multi-node installation, HA with embedded etcd or external databases, networking (Flannel,
  ServiceLB, MetalLB, custom CNI), storage (local-path, Longhorn), HelmChart CRD and auto-deploy
  manifests, air-gap installation, edge/IoT patterns, CIS security hardening, secrets encryption,
  system-upgrade-controller, and Rancher multi-cluster management. Use for K3s-specific tasks;
  do not use for full upstream Kubernetes (kubeadm/kops), managed cloud Kubernetes (EKS/GKE/AKS),
  or alternative lightweight distros (K0s, MicroK8s).
triggers:
  positive:
    - K3s
    - lightweight Kubernetes
    - edge Kubernetes
    - K3s cluster
    - K3s installation
    - Rancher K3s
    - K3s HA
    - K3s air-gap
    - K3s HelmChart
    - K3s upgrade
  negative:
    - kubeadm
    - kops
    - EKS
    - GKE
    - AKS
    - K0s
    - MicroK8s
    - general Kubernetes without K3s context
---

# K3s Lightweight Kubernetes

## Architecture

K3s is a CNCF-certified Kubernetes distribution packaged as a single binary (<100 MB). It bundles:
- **containerd** runtime (no Docker dependency)
- **Flannel** CNI (VXLAN overlay by default)
- **CoreDNS** for cluster DNS
- **Traefik** ingress controller (optional, can disable)
- **ServiceLB** (klipper-lb) for LoadBalancer services
- **local-path-provisioner** for PersistentVolumeClaims
- **metrics-server**
- **Helm controller** with HelmChart/HelmChartConfig CRDs
- **Embedded SQLite** datastore (single-node default)

K3s removes alpha APIs, legacy cloud providers, and non-essential storage drivers from upstream K8s. It retains full Kubernetes API conformance.

### Process Model

Server node runs: kube-apiserver, kube-controller-manager, kube-scheduler, kubelet, kube-proxy (all in one process).
Agent node runs: kubelet, kube-proxy, containerd.

### Key Paths

```
/etc/rancher/k3s/config.yaml          # Main config file
/etc/rancher/k3s/registries.yaml      # Private registry mirrors
/etc/rancher/k3s/k3s.yaml             # Generated kubeconfig (server only)
/var/lib/rancher/k3s/server/manifests/ # Auto-deploy manifests directory
/var/lib/rancher/k3s/server/node-token # Join token for agents
/var/lib/rancher/k3s/agent/images/     # Air-gap image tarballs
/var/lib/rancher/k3s/server/db/        # SQLite database
/var/lib/rancher/k3s/server/cred/      # Encryption config and credentials
```

## Installation

### Standard Install (Server)

```bash
curl -sfL https://get.k3s.io | sh -
# Verify
sudo systemctl status k3s
sudo k3s kubectl get nodes
```

### Install with Options

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
  --disable=traefik \
  --disable=servicelb \
  --tls-san=lb.example.com \
  --node-label=role=control-plane
```

### Config File Install

Create `/etc/rancher/k3s/config.yaml` before running the install script:

```yaml
write-kubeconfig-mode: "0644"
tls-san:
  - lb.example.com
  - 10.0.0.100
disable:
  - traefik
  - servicelb
node-label:
  - environment=production
kubelet-arg:
  - max-pods=110
  - eviction-hard=memory.available<200Mi
```

### Agent Node Join

```bash
# Get token from server
sudo cat /var/lib/rancher/k3s/server/node-token

# Install agent
curl -sfL https://get.k3s.io | K3S_URL=https://<SERVER_IP>:6443 \
  K3S_TOKEN=<NODE_TOKEN> sh -
```

### Air-Gap Install

```bash
# 1. Download on internet-connected machine
wget https://github.com/k3s-io/k3s/releases/download/<VERSION>/k3s
wget https://github.com/k3s-io/k3s/releases/download/<VERSION>/k3s-airgap-images-amd64.tar.zst
wget https://get.k3s.io -O install.sh

# 2. Transfer to air-gapped node, then:
sudo cp k3s /usr/local/bin/k3s && sudo chmod +x /usr/local/bin/k3s
sudo mkdir -p /var/lib/rancher/k3s/agent/images/
sudo cp k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/
chmod +x install.sh
INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh
```

For private registries in air-gap, configure `/etc/rancher/k3s/registries.yaml`:

```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://registry.internal:5000"
configs:
  "registry.internal:5000":
    tls:
      insecure_skip_verify: true
```

## High Availability

### Embedded etcd (Recommended)

Require odd number of server nodes (minimum 3). Place a load balancer in front.

```bash
# First server — initializes etcd cluster
curl -sfL https://get.k3s.io | K3S_TOKEN=<SHARED_SECRET> sh -s - server \
  --cluster-init \
  --tls-san=<LB_IP>

# Additional servers — join existing cluster
curl -sfL https://get.k3s.io | K3S_TOKEN=<SHARED_SECRET> sh -s - server \
  --server https://<FIRST_SERVER_IP>:6443 \
  --tls-san=<LB_IP>
```

Manage etcd snapshots:

```yaml
# config.yaml
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 10
etcd-snapshot-dir: /backup/etcd
```

### External Database

```bash
# PostgreSQL
curl -sfL https://get.k3s.io | sh -s - server \
  --datastore-endpoint="postgres://user:pass@db-host:5432/k3s"

# MySQL
curl -sfL https://get.k3s.io | sh -s - server \
  --datastore-endpoint="mysql://user:pass@tcp(db-host:3306)/k3s"

# External etcd
curl -sfL https://get.k3s.io | sh -s - server \
  --datastore-endpoint="https://etcd1:2379,https://etcd2:2379,https://etcd3:2379" \
  --datastore-cafile=/path/to/ca.crt \
  --datastore-certfile=/path/to/client.crt \
  --datastore-keyfile=/path/to/client.key
```

## Networking

### Flannel (Default)

Flannel uses VXLAN by default. Change backend:

```yaml
# config.yaml
flannel-backend: wireguard-native   # Options: vxlan, host-gw, wireguard-native, none
```

### Disable Flannel for Custom CNI

```yaml
# config.yaml
flannel-backend: none
disable-network-policy: true
```

Then apply Calico, Cilium, or other CNI manifests manually after cluster bootstrap.

### ServiceLB vs MetalLB

**ServiceLB (klipper-lb):** Built-in. Creates DaemonSet pods using host ports. Simple but limited — no failover across nodes.

**MetalLB:** Install after disabling ServiceLB for true bare-metal load balancing:

```bash
# Disable ServiceLB at install
curl -sfL https://get.k3s.io | sh -s - server --disable=servicelb

# Install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/main/config/manifests/metallb-native.yaml
```

```yaml
# MetalLB L2 address pool
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.200-192.168.1.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
```

## Storage

### local-path-provisioner (Default)

Creates hostPath PVs on the node. Data is node-local and does not survive node failure. Set as default StorageClass automatically.

### Longhorn (Distributed Storage)

```bash
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/longhorn.yaml
# Or via HelmChart CRD (see below)
```

Set Longhorn as default StorageClass:

```bash
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl patch storageclass longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## Helm Controller and Auto-Deploy Manifests

### HelmChart CRD

K3s includes a Helm controller that watches for `HelmChart` resources (API: `helm.cattle.io/v1`). Deploy Helm charts declaratively without the Helm CLI:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: prometheus
  namespace: kube-system
spec:
  repo: https://prometheus-community.github.io/helm-charts
  chart: kube-prometheus-stack
  version: "55.0.0"
  targetNamespace: monitoring
  createNamespace: true
  valuesContent: |-
    grafana:
      enabled: true
    alertmanager:
      enabled: false
```

### HelmChartConfig (Override Packaged Charts)

Override values for default-packaged charts like Traefik:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      websecure:
        tls:
          enabled: true
    logs:
      access:
        enabled: true
```

### Auto-Deploy Directory

Place any Kubernetes manifest or HelmChart YAML in `/var/lib/rancher/k3s/server/manifests/`. K3s watches this directory and applies files automatically on server start and on change. Delete the file to remove the resource.

## Security Hardening

### CIS Benchmark Compliance

```yaml
# /etc/rancher/k3s/config.yaml
protect-kernel-defaults: true
secrets-encryption: true
kube-apiserver-arg:
  - enable-admission-plugins=NodeRestriction,EventRateLimit
  - audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log
  - audit-log-maxage=30
  - audit-log-maxbackup=10
  - audit-log-maxsize=100
kube-controller-manager-arg:
  - terminated-pod-gc-threshold=10
```

Set kernel parameters:

```bash
cat > /etc/sysctl.d/90-kubelet.conf << EOF
vm.panic_on_oom=0
vm.overcommit_memory=1
kernel.panic=10
kernel.panic_on_oops=1
EOF
sysctl --system
```

### Secrets Encryption at Rest

Enable via config or flag:

```yaml
secrets-encryption: true
```

Verify: check `/var/lib/rancher/k3s/server/cred/encryption-config.json` exists. Rotate keys:

```bash
k3s secrets-encrypt rotate-keys
sudo systemctl restart k3s
```

### Network Policies

Flannel does not enforce NetworkPolicy. For enforcement, use Calico or Cilium as CNI, or add a network policy controller.

### Pod Security

Apply Pod Security Standards (PSS) with restricted profile:

```yaml
kube-apiserver-arg:
  - enable-admission-plugins=PodSecurity
pod-security-admission-config-file: /etc/rancher/k3s/psa.yaml
```

## Upgrades

### System Upgrade Controller

```bash
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml
```

Create upgrade plans (server-plan upgrades control-plane nodes first, agent-plan waits then upgrades workers):

```yaml
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: server-plan
  namespace: system-upgrade
spec:
  concurrency: 1
  cordon: true
  nodeSelector:
    matchExpressions:
      - {key: node-role.kubernetes.io/control-plane, operator: Exists}
  serviceAccountName: system-upgrade
  upgrade:
    image: rancher/k3s-upgrade
  version: v1.30.2+k3s1
---
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: agent-plan
  namespace: system-upgrade
spec:
  concurrency: 2
  cordon: true
  nodeSelector:
    matchExpressions:
      - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
  prepare:
    args: ["prepare", "server-plan"]
    image: rancher/k3s-upgrade
  serviceAccountName: system-upgrade
  upgrade:
    image: rancher/k3s-upgrade
  version: v1.30.2+k3s1
```

### Manual Upgrade

```bash
# Server nodes first, then agents
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -
# Or specific version
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.30.2+k3s1 sh -
```

## Edge and IoT Patterns

### Resource-Constrained Nodes

```yaml
# config.yaml for edge devices
disable:
  - traefik
  - servicelb
  - metrics-server
kubelet-arg:
  - max-pods=30
  - eviction-hard=memory.available<100Mi,nodefs.available<10%
  - system-reserved=cpu=200m,memory=256Mi
  - kube-reserved=cpu=200m,memory=256Mi
```

### Single-Node Edge

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init" sh -s - \
  --disable=traefik --disable=servicelb \
  --write-kubeconfig-mode=0644
```

### Fleet Management

Use Rancher Fleet or GitOps (Flux, ArgoCD) to manage K3s clusters at the edge. Push manifests to a Git repository; each edge cluster syncs on connectivity.

## K3s vs K8s Quick Reference

| Aspect | K3s | Upstream K8s |
|---|---|---|
| Binary | Single ~70 MB | Multiple binaries, 100s MB |
| Default datastore | SQLite | etcd (mandatory) |
| Container runtime | Bundled containerd | Install separately |
| CNI | Bundled Flannel | Install separately |
| Ingress | Bundled Traefik | Install separately |
| Alpha APIs | Removed | Included |
| Cloud providers | Removed (add externally) | Built-in |
| Min RAM | ~512 MB | ~2 GB |
| Target | Edge, IoT, dev, CI | Large-scale production |

## Common Operations

```bash
k3s kubectl get nodes -o wide          # Cluster status
k3s kubectl get pods -A                # All pods
sudo cat /etc/rancher/k3s/k3s.yaml    # Kubeconfig (update server IP for remote)
/usr/local/bin/k3s-uninstall.sh        # Uninstall server
/usr/local/bin/k3s-agent-uninstall.sh  # Uninstall agent
k3s etcd-snapshot save --name backup-$(date +%Y%m%d)  # Snapshot etcd
k3s --version                          # Check version
sudo journalctl -u k3s -f             # Server logs
kubectl get helmcharts,helmchartconfigs -A  # Helm resources
```

## Troubleshooting

- **Node NotReady:** Check `journalctl -u k3s -f` (server) or `journalctl -u k3s-agent -f` (agent). Verify port 6443 connectivity.
- **Pod stuck Pending:** Run `kubectl describe pod <name>`. Verify StorageClass exists (`kubectl get sc`). Check node resources.
- **CoreDNS CrashLoopBackOff:** Check host `/etc/resolv.conf`. Use `--resolv-conf` flag for custom DNS.
- **etcd leader failures:** Ensure odd server count. Use fast disks (not SD cards).
- **Air-gap image pull errors:** Verify tarballs in `/var/lib/rancher/k3s/agent/images/` and `registries.yaml`.
- **HelmChart stuck:** Check job logs: `kubectl logs -n kube-system job/<helmchart-name>`.
