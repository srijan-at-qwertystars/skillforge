# K3s Troubleshooting Guide

## Table of Contents

- [Diagnostic Commands](#diagnostic-commands)
- [Log Locations](#log-locations)
- [Installation Failures](#installation-failures)
  - [Install Script Fails](#install-script-fails)
  - [SELinux Issues](#selinux-issues)
  - [Firewall Blocking Ports](#firewall-blocking-ports)
  - [Unsupported OS or Kernel](#unsupported-os-or-kernel)
- [Node Not Joining Cluster](#node-not-joining-cluster)
  - [Agent Cannot Reach Server](#agent-cannot-reach-server)
  - [Token Mismatch](#token-mismatch)
  - [Certificate Errors on Join](#certificate-errors-on-join)
  - [Server Registration Port](#server-registration-port)
- [Certificate Errors](#certificate-errors)
  - [Certificate Expired](#certificate-expired)
  - [TLS SAN Missing](#tls-san-missing)
  - [CA Certificate Rotation](#ca-certificate-rotation)
  - [Custom Certificate Issues](#custom-certificate-issues)
- [CoreDNS Not Resolving](#coredns-not-resolving)
  - [CoreDNS CrashLoopBackOff](#coredns-crashloopbackoff)
  - [DNS Resolution Fails Inside Pods](#dns-resolution-fails-inside-pods)
  - [Host resolv.conf Issues](#host-resolvconf-issues)
  - [DNS Policy Configuration](#dns-policy-configuration)
- [Traefik Ingress Not Working](#traefik-ingress-not-working)
  - [Traefik Not Starting](#traefik-not-starting)
  - [Ingress Not Routing](#ingress-not-routing)
  - [TLS/HTTPS Issues](#tlshttps-issues)
  - [Customizing Traefik via HelmChartConfig](#customizing-traefik-via-helmchartconfig)
- [local-path-provisioner Stuck](#local-path-provisioner-stuck)
  - [PVC Stuck in Pending](#pvc-stuck-in-pending)
  - [Pod Stuck Waiting for Volume](#pod-stuck-waiting-for-volume)
  - [Storage Path Permissions](#storage-path-permissions)
  - [Node Affinity Issues](#node-affinity-issues)
- [ServiceLB Issues](#servicelb-issues)
  - [LoadBalancer Pending Forever](#loadbalancer-pending-forever)
  - [Port Conflicts](#port-conflicts)
  - [Switching to MetalLB](#switching-to-metallb)
- [containerd Problems](#containerd-problems)
  - [Image Pull Failures](#image-pull-failures)
  - [Container Runtime Errors](#container-runtime-errors)
  - [containerd Socket Issues](#containerd-socket-issues)
  - [Image Garbage Collection](#image-garbage-collection)
- [Air-Gap and Registry Configuration](#air-gap-and-registry-configuration)
  - [Air-Gap Image Load Failures](#air-gap-image-load-failures)
  - [Private Registry Authentication](#private-registry-authentication)
  - [Registry Mirror Configuration](#registry-mirror-configuration)
  - [Self-Signed Certificate Registries](#self-signed-certificate-registries)
- [Upgrade Failures](#upgrade-failures)
  - [Manual Upgrade Issues](#manual-upgrade-issues)
  - [System Upgrade Controller Problems](#system-upgrade-controller-problems)
  - [Version Skew Issues](#version-skew-issues)
  - [Rollback Procedure](#rollback-procedure)
- [etcd Issues](#etcd-issues)
  - [etcd Leader Election Failures](#etcd-leader-election-failures)
  - [etcd Database Size](#etcd-database-size)
  - [Slow etcd Performance](#slow-etcd-performance)
- [Systemd Journal Debugging](#systemd-journal-debugging)
  - [Filtering K3s Logs](#filtering-k3s-logs)
  - [Log Verbosity](#log-verbosity)
  - [Structured Log Analysis](#structured-log-analysis)

---

## Diagnostic Commands

Quick diagnostic commands to run first when troubleshooting:

```bash
# Cluster state
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A -o wide
sudo k3s kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# K3s service status
sudo systemctl status k3s          # Server
sudo systemctl status k3s-agent    # Agent

# K3s version and config
k3s --version
sudo k3s check-config

# Resource usage
sudo k3s kubectl top nodes
sudo k3s kubectl top pods -A

# Component health
sudo k3s kubectl get componentstatuses 2>/dev/null
sudo k3s kubectl get --raw /healthz
sudo k3s kubectl get --raw /readyz

# etcd health (embedded etcd)
sudo k3s etcd-snapshot list
curl -sfk --cert /var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
  --key /var/lib/rancher/k3s/server/tls/etcd/server-client.key \
  https://127.0.0.1:2379/health
```

## Log Locations

| Log | Location |
|-----|----------|
| K3s server | `journalctl -u k3s` |
| K3s agent | `journalctl -u k3s-agent` |
| containerd | Embedded in K3s logs |
| Pod logs | `kubectl logs <pod> -n <ns>` |
| etcd logs | Embedded in K3s server logs, filter with `grep etcd` |
| Traefik | `kubectl logs -n kube-system -l app.kubernetes.io/name=traefik` |
| CoreDNS | `kubectl logs -n kube-system -l k8s-app=kube-dns` |
| Audit logs | `/var/lib/rancher/k3s/server/logs/audit.log` (if configured) |
| Install log | `/var/log/k3s-install.log` (if redirected) |

## Installation Failures

### Install Script Fails

**Symptom:** `curl -sfL https://get.k3s.io | sh -` exits with error.

**Common causes and fixes:**

```bash
# 1. No internet connectivity
# Test: curl -sfL https://get.k3s.io > /dev/null && echo "OK"
# Fix: Use air-gap install or configure proxy

# 2. Missing dependencies
# K3s needs: iptables, mount, nsenter
# Check:
which iptables mount nsenter

# 3. Proxy required
export HTTPS_PROXY=http://proxy.example.com:3128
export HTTP_PROXY=http://proxy.example.com:3128
export NO_PROXY=127.0.0.1,localhost,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
curl -sfL https://get.k3s.io | sh -

# 4. cgroup v2 issues (older K3s versions)
# Verify cgroup version:
stat -fc %T /sys/fs/cgroup
# "cgroup2fs" = v2, "tmpfs" = v1
# K3s v1.24+ supports cgroup v2 natively
```

### SELinux Issues

```bash
# Symptom: Permission denied errors, pods can't start
# Check SELinux status
getenforce

# Option 1: Install K3s SELinux policy
yum install -y k3s-selinux

# Option 2: Set SELinux to permissive (not recommended for production)
sudo setenforce 0
sudo sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

### Firewall Blocking Ports

Required ports for K3s:

| Port | Protocol | Component | Direction |
|------|----------|-----------|-----------|
| 6443 | TCP | Kubernetes API | Server ↔ Agent, External |
| 9345 | TCP | K3s supervisor | Agent → Server |
| 8472 | UDP | Flannel VXLAN | All nodes |
| 10250 | TCP | Kubelet metrics | Server → Agent |
| 2379-2380 | TCP | etcd (HA only) | Server ↔ Server |
| 51820 | UDP | WireGuard (if used) | All nodes |

```bash
# firewalld
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --permanent --add-port=9345/tcp
sudo firewall-cmd --permanent --add-port=8472/udp
sudo firewall-cmd --permanent --add-port=10250/tcp
sudo firewall-cmd --reload

# ufw
sudo ufw allow 6443/tcp
sudo ufw allow 9345/tcp
sudo ufw allow 8472/udp
sudo ufw allow 10250/tcp

# iptables
sudo iptables -A INPUT -p tcp --dport 6443 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 9345 -j ACCEPT
sudo iptables -A INPUT -p udp --dport 8472 -j ACCEPT
```

### Unsupported OS or Kernel

```bash
# Check kernel version (3.10+ required, 4.x+ recommended)
uname -r

# Check OS compatibility
cat /etc/os-release

# Common issue: missing kernel modules
# K3s needs: br_netfilter, overlay, ip_tables, ip6_tables
for mod in br_netfilter overlay ip_tables ip6_tables; do
  modprobe $mod 2>/dev/null && echo "$mod: OK" || echo "$mod: MISSING"
done
```

## Node Not Joining Cluster

### Agent Cannot Reach Server

```bash
# Test connectivity from agent to server
curl -k https://<SERVER_IP>:6443/ping
# Should return: pong

# Test supervisor port
curl -k https://<SERVER_IP>:9345/ping

# Check for network issues
traceroute <SERVER_IP>
nc -zv <SERVER_IP> 6443
nc -zv <SERVER_IP> 9345

# If using LB, verify LB is healthy
curl -k https://<LB_IP>:6443/ping
```

### Token Mismatch

```bash
# On the server, get the actual token
sudo cat /var/lib/rancher/k3s/server/node-token

# Compare with what the agent is using
# Check agent logs for "401 Unauthorized"
sudo journalctl -u k3s-agent | grep -i "unauthorized\|401\|token"

# Fix: reinstall agent with correct token
K3S_URL=https://<SERVER>:6443 K3S_TOKEN=<CORRECT_TOKEN> /usr/local/bin/k3s-agent
```

### Certificate Errors on Join

```bash
# Symptom: x509 certificate errors in agent logs
# Check server certificates
openssl s_client -connect <SERVER_IP>:6443 </dev/null 2>/dev/null | \
  openssl x509 -noout -dates -subject -issuer

# Verify TLS SANs include the address agent uses
openssl s_client -connect <SERVER_IP>:6443 </dev/null 2>/dev/null | \
  openssl x509 -noout -ext subjectAltName

# Fix: add missing SANs and restart server
# In /etc/rancher/k3s/config.yaml:
# tls-san:
#   - <MISSING_IP_OR_HOSTNAME>
sudo systemctl restart k3s
```

### Server Registration Port

K3s uses port 9345 for initial node registration. If only 6443 is open, agents may fail to join:

```bash
# Agent log showing registration failure
# "Remotedialer proxy error" or "connection refused on 9345"

# Fix: ensure port 9345 is open and accessible
# If using LB, add 9345 to LB configuration
```

## Certificate Errors

### Certificate Expired

K3s auto-rotates certificates, but issues can arise:

```bash
# Check certificate expiry dates
for cert in /var/lib/rancher/k3s/server/tls/*.crt; do
  echo "=== $cert ==="
  openssl x509 -in "$cert" -noout -dates 2>/dev/null
done

# Force certificate rotation
sudo k3s certificate rotate

# Restart K3s to pick up new certificates
sudo systemctl restart k3s

# Restart agents so they get new client certs
# On each agent node:
sudo systemctl restart k3s-agent
```

### TLS SAN Missing

```bash
# Symptom: "x509: certificate is valid for X, not Y"
# Add the missing SAN

# In /etc/rancher/k3s/config.yaml:
# tls-san:
#   - new-hostname.example.com
#   - 10.0.0.200

# Restart to regenerate certificates with new SANs
sudo systemctl restart k3s
```

### CA Certificate Rotation

```bash
# Full CA rotation (K3s v1.27+)
sudo k3s certificate rotate-ca

# This generates new CA certs and re-signs all leaf certificates
# All nodes must be restarted afterward
```

### Custom Certificate Issues

When using custom certificates:

```bash
# Verify certificate chain
openssl verify -CAfile /path/to/ca.crt /path/to/server.crt

# Ensure key matches certificate
openssl x509 -noout -modulus -in /path/to/server.crt | openssl md5
openssl rsa -noout -modulus -in /path/to/server.key | openssl md5
# Both MD5 hashes must match

# Place custom certs before first K3s start:
# /var/lib/rancher/k3s/server/tls/server-ca.crt
# /var/lib/rancher/k3s/server/tls/server-ca.key
```

## CoreDNS Not Resolving

### CoreDNS CrashLoopBackOff

```bash
# Check CoreDNS pod status
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check logs
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50

# Common causes:
# 1. Loop detection — CoreDNS detects a forwarding loop
# Fix: Edit CoreDNS ConfigMap to remove "loop" plugin or fix host DNS
kubectl edit configmap coredns -n kube-system

# 2. Host /etc/resolv.conf points to 127.0.0.53 (systemd-resolved)
# Fix: Use resolv-conf flag
# In /etc/rancher/k3s/config.yaml:
# kubelet-arg:
#   - resolv-conf=/run/systemd/resolve/resolv.conf
```

### DNS Resolution Fails Inside Pods

```bash
# Test DNS from a pod
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local

# Check CoreDNS service
kubectl get svc -n kube-system kube-dns

# Verify endpoints
kubectl get endpoints -n kube-system kube-dns

# Check if the service CIDR overlaps with node network
# Default service CIDR: 10.43.0.0/16
# Default pod CIDR: 10.42.0.0/16
```

### Host resolv.conf Issues

```bash
# Check what CoreDNS is using as upstream
kubectl get configmap coredns -n kube-system -o yaml | grep -A5 forward

# On systemd-resolved systems, use the resolved config
# /etc/rancher/k3s/config.yaml:
kubelet-arg:
  - resolv-conf=/run/systemd/resolve/resolv.conf

# On systems with NetworkManager:
kubelet-arg:
  - resolv-conf=/run/NetworkManager/resolv.conf
```

### DNS Policy Configuration

```yaml
# Pod-level DNS override for debugging
apiVersion: v1
kind: Pod
metadata:
  name: dns-debug
spec:
  dnsPolicy: "None"
  dnsConfig:
    nameservers:
      - 8.8.8.8
    searches:
      - default.svc.cluster.local
      - svc.cluster.local
      - cluster.local
  containers:
    - name: debug
      image: busybox:1.36
      command: ["sleep", "3600"]
```

## Traefik Ingress Not Working

### Traefik Not Starting

```bash
# Check if Traefik is enabled
kubectl get helmcharts -n kube-system traefik

# Check Traefik pod
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
kubectl describe pod -n kube-system -l app.kubernetes.io/name=traefik

# Check Helm job that deploys Traefik
kubectl get jobs -n kube-system | grep traefik
kubectl logs -n kube-system job/helm-install-traefik

# If Traefik was disabled at install, re-enable:
# Remove the skip file
sudo rm /var/lib/rancher/k3s/server/manifests/traefik.yaml.skip
sudo systemctl restart k3s
```

### Ingress Not Routing

```bash
# Verify Ingress resource
kubectl get ingress -A
kubectl describe ingress <NAME> -n <NS>

# Check Traefik is listening on expected ports
kubectl get svc -n kube-system traefik

# Verify the backend service exists and has endpoints
kubectl get svc <BACKEND_SERVICE> -n <NS>
kubectl get endpoints <BACKEND_SERVICE> -n <NS>

# Check Traefik logs for routing errors
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=50

# Common fix: ensure ingressClassName is set
# apiVersion: networking.k8s.io/v1
# kind: Ingress
# spec:
#   ingressClassName: traefik  # Required in newer K3s versions
```

### TLS/HTTPS Issues

```bash
# Check if TLS secret exists
kubectl get secret <TLS_SECRET> -n <NS>

# Verify certificate in secret
kubectl get secret <TLS_SECRET> -n <NS> -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -dates -subject

# For Let's Encrypt with cert-manager, check certificate status
kubectl get certificate -A
kubectl describe certificate <NAME> -n <NS>
```

### Customizing Traefik via HelmChartConfig

```yaml
# /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        redirectTo:
          entry_point: websecure
      websecure:
        tls:
          enabled: true
    logs:
      access:
        enabled: true
    additionalArguments:
      - "--api.dashboard=true"
```

## local-path-provisioner Stuck

### PVC Stuck in Pending

```bash
# Check PVC status
kubectl get pvc -A
kubectl describe pvc <NAME> -n <NS>

# Verify StorageClass exists
kubectl get sc

# Check local-path-provisioner pod
kubectl get pods -n kube-system -l app=local-path-provisioner
kubectl logs -n kube-system -l app=local-path-provisioner

# Verify the storage path exists on the target node
# Default: /opt/local-path-provisioner/
ssh <NODE> "ls -la /opt/local-path-provisioner/"
```

### Pod Stuck Waiting for Volume

```bash
# Check if PV was created
kubectl get pv

# Describe the PV for details
kubectl describe pv <PV_NAME>

# Check events
kubectl get events -n <NS> --field-selector reason=FailedMount

# local-path volumes are WaitForFirstConsumer — PV is only created
# when a pod is scheduled to a node
```

### Storage Path Permissions

```bash
# Ensure the storage directory exists and is writable
sudo mkdir -p /opt/local-path-provisioner
sudo chmod 777 /opt/local-path-provisioner

# Custom storage path via ConfigMap
kubectl get configmap local-path-config -n kube-system -o yaml
# Edit paths in the "config.json" key
```

### Node Affinity Issues

local-path PVs are bound to a specific node. If the node is unavailable, pods using those PVs cannot be scheduled:

```bash
# Check PV node affinity
kubectl get pv <PV_NAME> -o yaml | grep -A5 nodeAffinity

# If node is gone, delete the PV and PVC to allow re-provisioning
kubectl delete pvc <NAME> -n <NS>
# WARNING: This deletes the data
```

## ServiceLB Issues

### LoadBalancer Pending Forever

```bash
# Check ServiceLB (klipper-lb) pods
kubectl get pods -n kube-system -l svccontroller.k3s.cattle.io/svcname

# Check the service
kubectl describe svc <SERVICE_NAME> -n <NS>

# Common cause: ServiceLB was disabled at install
kubectl get ds -n kube-system | grep svclb

# Verify ServiceLB is not disabled in config
grep -i servicelb /etc/rancher/k3s/config.yaml
```

### Port Conflicts

```bash
# ServiceLB uses host ports — check for conflicts
sudo ss -tlnp | grep <PORT>

# If another service uses the same host port, ServiceLB can't bind
# Fix: change the service port or stop the conflicting process
```

### Switching to MetalLB

```bash
# 1. Disable ServiceLB
# Add to /etc/rancher/k3s/config.yaml:
#   disable:
#     - servicelb

# 2. Restart K3s
sudo systemctl restart k3s

# 3. Install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/main/config/manifests/metallb-native.yaml

# 4. Configure address pool
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
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
EOF
```

## containerd Problems

### Image Pull Failures

```bash
# Check pod events for pull errors
kubectl describe pod <POD> -n <NS> | grep -A5 "Events"

# Test image pull directly via containerd
sudo k3s crictl pull <IMAGE>

# Check containerd status
sudo k3s crictl info

# DNS issues preventing pulls — verify containerd can resolve registries
sudo k3s crictl pull docker.io/library/busybox:latest

# Rate limiting (Docker Hub)
# Fix: configure registry mirrors in /etc/rancher/k3s/registries.yaml
```

### Container Runtime Errors

```bash
# List containers and their states
sudo k3s crictl ps -a

# Inspect a specific container
sudo k3s crictl inspect <CONTAINER_ID>

# Check container logs
sudo k3s crictl logs <CONTAINER_ID>

# List images
sudo k3s crictl images

# Common fix: restart containerd (embedded in K3s)
sudo systemctl restart k3s
```

### containerd Socket Issues

```bash
# Default socket location
ls -la /run/k3s/containerd/containerd.sock

# If crictl can't connect:
export CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock
export CRI_CONFIG_FILE=/var/lib/rancher/k3s/agent/etc/crictl.yaml

# Or use K3s wrapper
sudo k3s crictl ps
```

### Image Garbage Collection

```bash
# containerd GC is managed by kubelet
# Check kubelet GC settings
ps aux | grep kubelet | grep -o 'image-gc.*'

# Configure in /etc/rancher/k3s/config.yaml:
# kubelet-arg:
#   - image-gc-high-threshold=85
#   - image-gc-low-threshold=80

# Manual cleanup
sudo k3s crictl rmi --prune
```

## Air-Gap and Registry Configuration

### Air-Gap Image Load Failures

```bash
# Verify images are in the correct directory
ls -la /var/lib/rancher/k3s/agent/images/

# Supported formats: .tar, .tar.gz, .tar.zst
# Filenames don't matter, but format must be a valid container image tarball

# Check K3s can read the images
sudo journalctl -u k3s | grep -i "image\|import\|airgap"

# If images aren't loading, check file permissions
sudo chmod 644 /var/lib/rancher/k3s/agent/images/*

# Place images BEFORE starting K3s
# If K3s is already running, restart after placing images
sudo systemctl restart k3s
```

### Private Registry Authentication

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  docker.io:
    endpoint:
      - "https://registry.example.com"
configs:
  "registry.example.com":
    auth:
      username: myuser
      password: mypassword
    tls:
      cert_file: /etc/k3s/certs/client.crt
      key_file: /etc/k3s/certs/client.key
      ca_file: /etc/k3s/certs/ca.crt
```

After editing, restart K3s:

```bash
sudo systemctl restart k3s
# Or on agent nodes:
sudo systemctl restart k3s-agent
```

### Registry Mirror Configuration

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  docker.io:
    endpoint:
      - "https://mirror1.example.com"
      - "https://mirror2.example.com"
  "ghcr.io":
    endpoint:
      - "https://ghcr-mirror.example.com"
  "*":
    endpoint:
      - "https://catch-all-mirror.example.com"
```

### Self-Signed Certificate Registries

```yaml
# /etc/rancher/k3s/registries.yaml
configs:
  "registry.local:5000":
    tls:
      insecure_skip_verify: true
      # Or provide the CA certificate:
      # ca_file: /etc/k3s/certs/registry-ca.crt
```

```bash
# If using ca_file, ensure the cert is accessible
sudo cp registry-ca.crt /etc/k3s/certs/
sudo chmod 644 /etc/k3s/certs/registry-ca.crt
sudo systemctl restart k3s
```

## Upgrade Failures

### Manual Upgrade Issues

```bash
# Symptom: K3s fails to start after upgrade
# Check logs
sudo journalctl -u k3s --since "5 minutes ago"

# Common causes:
# 1. Database migration failure
#    - Restore from backup and retry
# 2. Incompatible flags removed in new version
#    - Review release notes for deprecated flags
# 3. Binary not replaced correctly
which k3s
k3s --version

# Rollback to previous version
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.29.6+k3s1 sh -
```

### System Upgrade Controller Problems

```bash
# Check the controller is running
kubectl get pods -n system-upgrade

# Check upgrade plans
kubectl get plans -n system-upgrade
kubectl describe plan server-plan -n system-upgrade

# Check upgrade jobs
kubectl get jobs -n system-upgrade
kubectl logs -n system-upgrade job/<JOB_NAME>

# Common issues:
# 1. ServiceAccount missing
kubectl get sa system-upgrade -n system-upgrade
# Fix: Apply the RBAC manifests from the system-upgrade-controller release

# 2. Plan stuck — node selector doesn't match
kubectl get nodes --show-labels | grep -i upgrade

# 3. Concurrency too high — multiple nodes upgrading simultaneously
# Fix: Set concurrency: 1 in the plan
```

### Version Skew Issues

```bash
# K3s follows Kubernetes version skew policy:
# - Agents can be at most 2 minor versions behind servers
# - Always upgrade servers first, then agents

# Check version of all nodes
kubectl get nodes -o wide

# If agents are too old:
# Upgrade agents to an intermediate version first
```

### Rollback Procedure

```bash
# 1. Stop K3s
sudo systemctl stop k3s

# 2. Restore etcd snapshot from before upgrade
sudo k3s server --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<PRE_UPGRADE_SNAPSHOT>

# 3. Install the previous K3s version
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<PREVIOUS_VERSION> sh -

# 4. On other servers: clear data and rejoin
sudo rm -rf /var/lib/rancher/k3s/server/db
sudo systemctl start k3s

# 5. Downgrade agents
curl -sfL https://get.k3s.io | K3S_URL=https://<SERVER>:6443 \
  K3S_TOKEN=<TOKEN> INSTALL_K3S_VERSION=<PREVIOUS_VERSION> sh -
```

## etcd Issues

### etcd Leader Election Failures

```bash
# Symptom: "etcdserver: leader changed" or "election timeout" in logs
sudo journalctl -u k3s | grep -i "etcd.*leader\|election"

# Causes:
# 1. High disk latency — etcd needs fast storage
#    Check disk latency:
sudo dd if=/dev/zero of=/tmp/testfile bs=1M count=100 oflag=dsync 2>&1 | tail -1
#    Target: < 10ms per write

# 2. Network partitions between servers
#    Check connectivity:
for ip in 10.0.0.11 10.0.0.12 10.0.0.13; do
  echo -n "$ip: "; ping -c3 -W1 $ip | tail -1
done

# 3. CPU starvation
top -bn1 | head -20

# 4. Clock skew between servers
date
# Install and enable NTP/chrony
```

### etcd Database Size

```bash
# Check database size
sudo du -sh /var/lib/rancher/k3s/server/db/

# etcd has a default 8GB limit
# If approaching the limit, compact and defragment:

# Check etcd endpoint status (shows DB size)
sudo k3s kubectl exec -n kube-system \
  $(kubectl get pods -n kube-system -l component=etcd -o name | head -1) -- \
  etcdctl endpoint status --write-out=table 2>/dev/null

# Defragmentation happens automatically, but to force:
# Compact and defrag via the K3s binary
sudo k3s etcd-snapshot save --name pre-defrag
# Then restart K3s — it compacts on startup
sudo systemctl restart k3s
```

### Slow etcd Performance

```bash
# Check for slow etcd operations in logs
sudo journalctl -u k3s | grep "slow\|took too long\|apply request took"

# Performance tuning in config.yaml:
# etcd-arg:
#   - heartbeat-interval=250       # Increase for high-latency networks
#   - election-timeout=5000        # Must be 5-10x heartbeat interval
#   - snapshot-count=10000
#   - quota-backend-bytes=8589934592  # 8GB max DB size

# Move etcd data to SSD
# 1. Stop K3s
# 2. Move /var/lib/rancher/k3s/server/db to SSD
# 3. Symlink or update config
# 4. Start K3s
```

## Systemd Journal Debugging

### Filtering K3s Logs

```bash
# Follow K3s server logs
sudo journalctl -u k3s -f

# Follow K3s agent logs
sudo journalctl -u k3s-agent -f

# Logs since last boot
sudo journalctl -u k3s -b

# Logs since a specific time
sudo journalctl -u k3s --since "2024-01-15 10:00:00"
sudo journalctl -u k3s --since "1 hour ago"

# Logs between two times
sudo journalctl -u k3s --since "2024-01-15 10:00" --until "2024-01-15 11:00"

# Only errors and warnings
sudo journalctl -u k3s -p err
sudo journalctl -u k3s -p warning

# Filter by grep
sudo journalctl -u k3s --no-pager | grep -i "error\|fail\|panic"

# Output as JSON for parsing
sudo journalctl -u k3s -o json --no-pager | jq '.MESSAGE' | head -20
```

### Log Verbosity

```bash
# Increase K3s log verbosity
# In /etc/rancher/k3s/config.yaml:
# debug: true

# Or specific component verbosity:
# kube-apiserver-arg:
#   - v=4
# kube-controller-manager-arg:
#   - v=4
# kubelet-arg:
#   - v=4

# Runtime log level change (no restart needed for kubelet):
# curl -X PUT -d '{"level": 4}' http://localhost:10248/debug/flags/v
```

### Structured Log Analysis

```bash
# Count error types
sudo journalctl -u k3s --no-pager | grep -i error | \
  sed 's/.*msg="\([^"]*\)".*/\1/' | sort | uniq -c | sort -rn | head -20

# Find repeated warnings
sudo journalctl -u k3s --no-pager --since "1 hour ago" | \
  grep -i warn | wc -l

# Check for OOM kills
sudo journalctl -k | grep -i "oom\|killed process"

# Monitor K3s resource usage
sudo systemctl show k3s --property=MemoryCurrent,CPUUsageNSec
```
