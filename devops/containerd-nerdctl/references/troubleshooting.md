# containerd & nerdctl Troubleshooting Guide

## Table of Contents

- [Container Startup Failures](#container-startup-failures)
- [Image Pull Errors](#image-pull-errors)
- [CNI Configuration Problems](#cni-configuration-problems)
- [Namespace Conflicts](#namespace-conflicts)
- [Snapshotter Corruption](#snapshotter-corruption)
- [High Memory Usage](#high-memory-usage)
- [Socket Permission Errors](#socket-permission-errors)
- [CRI Plugin Issues with Kubelet](#cri-plugin-issues-with-kubelet)
- [BuildKit Cache Cleanup](#buildkit-cache-cleanup)
- [Rootless Mode Limitations](#rootless-mode-limitations)

---

## Container Startup Failures

### "failed to create shim task"

**Symptoms:** Container fails to start with shim creation errors.

**Causes and fixes:**

```bash
# Cause 1: runc binary missing or not in PATH
which runc
# Fix: install runc
sudo apt-get install runc
# Or download directly
wget https://github.com/opencontainers/runc/releases/latest/download/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

# Cause 2: runc binary incompatible with kernel
runc --version
uname -r
# Fix: upgrade runc or kernel

# Cause 3: shim binary not found for specified runtime
ls /usr/local/bin/containerd-shim-*
# Fix: install the correct shim for the configured runtime
```

### "OCI runtime create failed"

**Symptoms:** runc reports errors creating the container.

```bash
# Cause 1: cgroup v2 with SystemdCgroup = false
# Error: "cgroup mount not found" or "failed to create cgroup"
# Fix: enable SystemdCgroup in config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

# Cause 2: seccomp profile issue
# Error: "operation not permitted" for certain syscalls
# Fix: use a compatible seccomp profile or --security-opt seccomp=unconfined (dev only)
nerdctl run --security-opt seccomp=unconfined myimage

# Cause 3: AppArmor profile missing
# Error: "applying apparmor profile: no such file or directory"
# Fix: load the AppArmor profile
sudo apparmor_parser -r /etc/apparmor.d/containerd-default
```

### Container Exits Immediately

```bash
# Check container logs
nerdctl logs <container>

# Check container exit code
nerdctl inspect --format '{{.State.ExitCode}}' <container>

# Exit code 127: command not found
# Fix: verify the entrypoint/cmd exists in the image
nerdctl run --entrypoint sh myimage -c "ls /usr/local/bin/"

# Exit code 137: OOM killed
# Fix: increase memory limit
nerdctl run -m 512m myimage
# Check kernel OOM logs
dmesg | grep -i oom

# Exit code 139: segfault
# Fix: check for architecture mismatch
nerdctl inspect myimage | grep Architecture
uname -m
```

### "failed to reserve sandbox name"

```bash
# Cause: stale container metadata
# Fix: clean up dead containers
nerdctl rm -f $(nerdctl ps -aq)
# Or remove specific container
nerdctl rm -f <container-name>
```

---

## Image Pull Errors

### TLS Certificate Errors

**Symptoms:** `x509: certificate signed by unknown authority` or `tls: handshake failure`

```bash
# Cause 1: self-signed or corporate CA cert not trusted
# Fix: add CA cert to system trust store
sudo cp myca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates

# Fix: add CA cert via hosts.toml for specific registry
sudo mkdir -p /etc/containerd/certs.d/myregistry.io
cat <<EOF | sudo tee /etc/containerd/certs.d/myregistry.io/hosts.toml
server = "https://myregistry.io"
[host."https://myregistry.io"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/myregistry.io/ca.crt"
EOF

# Cause 2: expired certificate
openssl s_client -connect myregistry.io:443 -servername myregistry.io 2>/dev/null | openssl x509 -noout -dates

# Cause 3: hostname mismatch
# Fix: use the exact hostname in the certificate
openssl s_client -connect myregistry.io:443 2>/dev/null | openssl x509 -noout -text | grep "Subject Alternative Name" -A1
```

### Authentication Errors

**Symptoms:** `401 Unauthorized` or `403 Forbidden`

```bash
# Fix 1: log in to registry
nerdctl login myregistry.io

# Fix 2: check stored credentials
cat ~/.docker/config.json | jq '.auths'

# Fix 3: for Kubernetes CRI, configure imagePullSecrets
# containerd CRI uses /var/lib/kubelet/config.json by default

# Fix 4: for ECR, use ecr-credential-helper
# Install and configure in ~/.docker/config.json:
# { "credHelpers": { "123456789.dkr.ecr.us-east-1.amazonaws.com": "ecr-login" } }

# Fix 5: token expired — re-authenticate
nerdctl logout myregistry.io
nerdctl login myregistry.io
```

### "failed to resolve reference" / Image Not Found

```bash
# Cause 1: wrong image name or tag
# containerd requires fully qualified image names (unlike Docker)
# Wrong: nerdctl pull nginx
# Right: nerdctl pull docker.io/library/nginx:latest

# Cause 2: registry mirror misconfigured
cat /etc/containerd/certs.d/docker.io/hosts.toml

# Cause 3: network connectivity
curl -v https://registry-1.docker.io/v2/

# Cause 4: rate limiting (Docker Hub)
# Fix: authenticate or use a mirror
nerdctl login docker.io
```

### Slow Image Pulls

```bash
# Check if using a remote mirror
cat /etc/containerd/certs.d/docker.io/hosts.toml

# Enable parallel layer downloads (nerdctl >= 1.5)
# Set max-concurrent-downloads in containerd config
# [plugins."io.containerd.grpc.v1.cri"]
#   max_concurrent_downloads = 10

# Use lazy pulling for faster startup (doesn't reduce total download)
nerdctl --snapshotter stargz pull myimage:estargz
```

---

## CNI Configuration Problems

### "network not found" / No Network Connectivity

```bash
# Cause 1: CNI plugins not installed
ls /opt/cni/bin/
# Fix: install CNI plugins
CNI_VERSION="v1.5.1"
wget https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz
sudo mkdir -p /opt/cni/bin
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-${CNI_VERSION}.tgz

# Cause 2: CNI config missing
ls /etc/cni/net.d/
# Fix: create default bridge config
cat <<EOF | sudo tee /etc/cni/net.d/10-containerd-net.conflist
{
  "cniVersion": "1.0.0",
  "name": "containerd-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "ranges": [[{"subnet": "10.88.0.0/16"}]],
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    },
    {
      "type": "firewall"
    },
    {
      "type": "tuning"
    }
  ]
}
EOF

# Cause 3: iptables issues
sudo iptables -L -n -v | grep -i cni
# Fix: ensure ip_forward is enabled
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
# Make persistent
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.d/99-containerd.conf
sudo sysctl -p /etc/sysctl.d/99-containerd.conf
```

### Port Mapping Not Working

```bash
# Cause 1: portmap plugin missing
ls /opt/cni/bin/portmap
# Fix: install CNI plugins (portmap is included)

# Cause 2: firewall blocking
sudo iptables -L -t nat | grep -i cni
sudo iptables -L -t filter | grep -i cni

# Cause 3: port already in use
sudo ss -tlnp | grep :8080

# Cause 4: rootless mode — ports below 1024 require special config
# Fix for rootless: use ports >= 1024 or set sysctl
sudo sysctl net.ipv4.ip_unprivileged_port_start=80
```

### DNS Resolution Failing Inside Containers

```bash
# Test DNS from inside container
nerdctl exec <container> nslookup google.com

# Cause 1: /etc/resolv.conf not propagated
# Fix: specify DNS server
nerdctl run --dns 8.8.8.8 myimage

# Cause 2: CNI config missing DNS
# Add to CNI config:
# "dns": { "nameservers": ["8.8.8.8", "8.8.4.4"] }

# Cause 3: host firewall blocking container DNS
sudo iptables -I FORWARD -j ACCEPT
```

---

## Namespace Conflicts

### Images Not Visible Across Namespaces

```bash
# containerd namespaces are fully isolated
# Images pulled in "default" are NOT visible in "k8s.io"

# List images in each namespace
nerdctl --namespace default images
nerdctl --namespace k8s.io images
ctr --namespace moby images ls  # Docker's namespace

# Fix: pull images in the correct namespace
nerdctl --namespace k8s.io pull nginx:alpine

# Or copy between namespaces
nerdctl --namespace default save nginx:alpine | nerdctl --namespace k8s.io load
```

### "namespace already exists" Errors

```bash
# List namespaces
ctr namespaces ls

# Delete unused namespace (removes all resources!)
ctr namespaces remove --force myns

# Note: never delete k8s.io or moby namespaces
```

### Kubernetes Pods Can't Find Images Pulled by nerdctl

```bash
# nerdctl uses "default" namespace, Kubernetes uses "k8s.io"
# Fix: pull in the k8s.io namespace
nerdctl --namespace k8s.io pull myimage:tag

# Or use crictl (always uses k8s.io)
crictl pull myimage:tag

# Verify
crictl images | grep myimage
```

---

## Snapshotter Corruption

### "failed to prepare snapshot"

```bash
# Cause: corrupted overlay metadata
# Check snapshotter status
ctr snapshots --snapshotter overlayfs ls 2>&1 | head -20
ctr snapshots --snapshotter overlayfs info <key>

# Fix 1: remove specific snapshot
ctr snapshots --snapshotter overlayfs rm <key>

# Fix 2: full cleanup (destructive — removes all containers and images!)
sudo systemctl stop containerd
sudo rm -rf /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/
sudo systemctl start containerd
# Re-pull all images after cleanup
```

### "mount failed: no such device"

```bash
# Cause: overlayfs not supported (old kernel or unsupported filesystem)
modprobe overlay
cat /proc/filesystems | grep overlay

# Fix: use native snapshotter as fallback
# In config.toml:
# [plugins."io.containerd.grpc.v1.cri"]
#   snapshotter = "native"

# Check underlying filesystem (overlayfs requires ext4/xfs)
df -T /var/lib/containerd/
```

### Disk Space Exhaustion from Snapshots

```bash
# Check snapshot disk usage
du -sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/
du -sh /var/lib/containerd/io.containerd.content.v1.content/

# Clean up unused images
nerdctl image prune -a

# Clean up unused containers
nerdctl container prune

# Force garbage collection
ctr content prune
ctr leases ls
ctr leases rm <expired-lease>
```

---

## High Memory Usage

### containerd Daemon Memory Growth

```bash
# Check containerd memory usage
ps aux | grep containerd
cat /proc/$(pidof containerd)/status | grep -i vmrss

# Cause 1: large number of images/containers
nerdctl images | wc -l
nerdctl ps -a | wc -l

# Fix: prune unused resources
nerdctl system prune -a

# Cause 2: event backlog
# containerd stores events in memory
# Fix: configure event TTL in config.toml
# [plugins."io.containerd.grpc.v1.cri"]
#   max_container_log_line_size = 16384

# Cause 3: leaked shim processes
ps aux | grep containerd-shim
# Fix: kill orphaned shims
# Identify shims without corresponding containers, then:
# kill <orphaned-shim-pid>

# Cause 4: memory leak (bug) — upgrade containerd
containerd --version
```

### Shim Process Memory

```bash
# Each container has a shim process
# High shim memory may indicate container issues
ps aux | grep "containerd-shim" | awk '{sum += $6} END {print sum/1024 "MB total"}'

# Per-shim breakdown
ps aux | grep "containerd-shim" | awk '{print $2, $6/1024 "MB"}'
```

### Memory Limits for containerd Itself

```bash
# Use systemd to limit containerd memory
sudo systemctl edit containerd
# Add:
# [Service]
# MemoryMax=2G
# MemoryHigh=1.5G
sudo systemctl daemon-reload
sudo systemctl restart containerd
```

---

## Socket Permission Errors

### "permission denied" on containerd Socket

```bash
# Default socket: /run/containerd/containerd.sock
ls -la /run/containerd/containerd.sock

# Fix 1: run with sudo
sudo nerdctl ps

# Fix 2: add user to containerd group
sudo groupadd containerd
sudo usermod -aG containerd $USER
# Configure containerd socket ownership in systemd override
sudo systemctl edit containerd
# Add:
# [Service]
# ExecStartPost=/bin/chmod 660 /run/containerd/containerd.sock
# ExecStartPost=/bin/chgrp containerd /run/containerd/containerd.sock
sudo systemctl daemon-reload
sudo systemctl restart containerd
# Log out and back in for group membership to take effect

# Fix 3: use rootless containerd instead (recommended)
containerd-rootless-setuptool.sh install
```

### BuildKit Socket Permission Errors

```bash
# Default: /run/buildkit/buildkitd.sock
ls -la /run/buildkit/buildkitd.sock

# Fix: similar group-based approach
sudo groupadd buildkit
sudo usermod -aG buildkit $USER
sudo systemctl edit buildkit
# Add:
# [Service]
# ExecStartPost=/bin/chmod 660 /run/buildkit/buildkitd.sock
# ExecStartPost=/bin/chgrp buildkit /run/buildkit/buildkitd.sock
sudo systemctl daemon-reload
sudo systemctl restart buildkit
```

### Rootless Socket Location

```bash
# Rootless containerd socket
echo $XDG_RUNTIME_DIR/containerd/containerd.sock
# Usually: /run/user/<uid>/containerd/containerd.sock

# If XDG_RUNTIME_DIR is not set
export XDG_RUNTIME_DIR=/run/user/$(id -u)

# Set CONTAINERD_ADDRESS for rootless
export CONTAINERD_ADDRESS=$XDG_RUNTIME_DIR/containerd/containerd.sock
```

---

## CRI Plugin Issues with Kubelet

### "failed to get sandbox image"

```bash
# Cause: sandbox (pause) image not available
# Check configured sandbox image
grep sandbox_image /etc/containerd/config.toml

# Fix: ensure sandbox image is available
sudo crictl pull registry.k8s.io/pause:3.10

# Or update config.toml to use a reachable image
# sandbox_image = "myregistry.io/pause:3.10"
sudo systemctl restart containerd
```

### "CRI: unable to retrieve cri grpc client"

```bash
# Cause 1: containerd not running
sudo systemctl status containerd

# Cause 2: CRI plugin disabled
grep -A5 'cri' /etc/containerd/config.toml
# Fix: remove CRI from disabled_plugins list
# disabled_plugins = []  (not ["cri"])
sudo systemctl restart containerd

# Cause 3: wrong socket path in kubelet config
# Verify kubelet is pointing to the right endpoint
ps aux | grep kubelet | grep container-runtime-endpoint
# Should be: --container-runtime-endpoint=unix:///run/containerd/containerd.sock
```

### Pod Sandbox Creation Failures

```bash
# Cause 1: cgroup driver mismatch
# kubelet and containerd must use the same cgroup driver
# Check containerd
grep SystemdCgroup /etc/containerd/config.toml
# Check kubelet
cat /var/lib/kubelet/config.yaml | grep cgroupDriver

# Fix: align both to systemd
# In config.toml: SystemdCgroup = true
# In kubelet config: cgroupDriver: systemd

# Cause 2: CNI not configured for CRI
ls /etc/cni/net.d/
ls /opt/cni/bin/
# Fix: install CNI plugins and config (see CNI section)

# Cause 3: AppArmor / SELinux blocking
sudo journalctl -u containerd | grep -i "denied\|apparmor\|selinux"
# Fix: load appropriate profiles or set permissive mode for debugging
```

### Image GC Not Working

```bash
# kubelet garbage collects images when disk is above threshold
# Check kubelet GC config
cat /var/lib/kubelet/config.yaml | grep -i image

# Defaults:
# imageGCHighThresholdPercent: 85
# imageGCLowThresholdPercent: 80
# imageMinimumGCAge: 2m

# Check disk usage
df -h /var/lib/containerd/

# Manually trigger CRI image removal
crictl images | grep -v "IMAGE ID" | awk '{print $3}' | sort | uniq -c | sort -rn | head
crictl rmi <image-id>
```

---

## BuildKit Cache Cleanup

### BuildKit Cache Growing Unbounded

```bash
# Check BuildKit cache size
nerdctl system df
du -sh /var/lib/buildkit/

# Prune build cache
nerdctl builder prune

# Prune all cache (including base image layers)
nerdctl builder prune --all

# Prune cache older than 24 hours
nerdctl builder prune --filter "until=24h"

# Set max cache size in buildkitd.toml
# [worker.oci]
#   gc = true
#   gckeepstorage = 10000  # 10GB in MB
#   [[worker.oci.gcpolicy]]
#     keepBytes = 10737418240  # 10GB
#     keepDuration = 604800    # 7 days in seconds
#     all = true
```

### BuildKit Daemon Not Responding

```bash
# Check BuildKit status
sudo systemctl status buildkit
sudo journalctl -u buildkit -f

# Restart BuildKit
sudo systemctl restart buildkit

# Verify socket
ls -la /run/buildkit/buildkitd.sock

# Check if buildkitd is actually running
ps aux | grep buildkitd

# For rootless BuildKit
systemctl --user status buildkit
systemctl --user restart buildkit
```

### "failed to solve" Build Errors

```bash
# Cause 1: Dockerfile syntax error
# Check the Dockerfile for syntax issues
nerdctl build --no-cache -t test .

# Cause 2: BuildKit version incompatibility
buildkitd --version
nerdctl version

# Cause 3: build context too large
# Fix: use .dockerignore
echo -e "node_modules\n.git\n*.tar.gz" > .dockerignore

# Cause 4: multi-stage build reference error
# Fix: verify stage names match between FROM and COPY --from=
```

---

## Rootless Mode Limitations

### Known Limitations

| Feature | Rootless Support | Workaround |
|---|---|---|
| Overlay snapshotter | Kernel ≥5.11 only | Use fuse-overlayfs |
| Port < 1024 | Not supported by default | `sysctl net.ipv4.ip_unprivileged_port_start=0` |
| AppArmor | Not supported | Use seccomp instead |
| Cgroup v1 | Limited support | Upgrade to cgroup v2 |
| ping | Requires sysctl | `sysctl net.ipv4.ping_group_range="0 2147483647"` |
| IP forwarding | Limited | Use bypass4netns |
| NFS root dir | Not supported | Use local filesystem |

### "rootless: failed to configure network"

```bash
# Cause 1: slirp4netns not installed
which slirp4netns
# Fix:
sudo apt-get install slirp4netns

# Cause 2: use bypass4netns for better performance
containerd-rootless-setuptool.sh install-bypass4netnsd
# Requires kernel >= 5.9

# Check rootless setup
containerd-rootless-setuptool.sh check
```

### fuse-overlayfs for Older Kernels

```bash
# On kernels < 5.11, overlayfs requires fuse-overlayfs for rootless
sudo apt-get install fuse-overlayfs

# Verify it works
fuse-overlayfs --version

# containerd-rootless will use fuse-overlayfs automatically if kernel
# doesn't support unprivileged overlayfs
```

### Rootless UID/GID Mapping Issues

```bash
# Check subuid/subgid configuration
grep $USER /etc/subuid
grep $USER /etc/subgid

# Expected output like: username:100000:65536
# If missing, add entries:
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER

# Verify uidmap tools
which newuidmap newgidmap

# Install if missing
sudo apt-get install uidmap

# Check user namespace support
cat /proc/sys/kernel/unprivileged_userns_clone
# Should be 1. If 0:
echo 1 | sudo tee /proc/sys/kernel/unprivileged_userns_clone
```

### Rootless Debugging Checklist

```bash
#!/bin/bash
echo "=== Rootless containerd Debug ==="

echo "1. User namespace support:"
cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo "not restricted"

echo "2. subuid/subgid:"
grep $(whoami) /etc/subuid /etc/subgid

echo "3. uidmap tools:"
which newuidmap newgidmap

echo "4. slirp4netns:"
which slirp4netns && slirp4netns --version

echo "5. XDG_RUNTIME_DIR:"
echo $XDG_RUNTIME_DIR

echo "6. containerd socket:"
ls -la ${XDG_RUNTIME_DIR}/containerd/containerd.sock 2>/dev/null || echo "not found"

echo "7. systemd user service:"
systemctl --user status containerd 2>&1 | head -5

echo "8. Kernel version (overlayfs needs >= 5.11):"
uname -r

echo "9. fuse-overlayfs:"
which fuse-overlayfs 2>/dev/null || echo "not installed"
```
