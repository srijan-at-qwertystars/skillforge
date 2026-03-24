# Podman Troubleshooting Guide

## Table of Contents

- [Rootless Networking Issues](#rootless-networking-issues)
  - [slirp4netns Problems](#slirp4netns-problems)
  - [Pasta Networking Issues](#pasta-networking-issues)
  - [Port Binding Failures](#port-binding-failures)
  - [IPv6 Issues in Rootless Mode](#ipv6-issues-in-rootless-mode)
- [SELinux Denials](#selinux-denials)
  - [Volume Mount Denials](#volume-mount-denials)
  - [:Z and :z Volume Labels](#z-and-z-volume-labels)
  - [Diagnosing SELinux Denials](#diagnosing-selinux-denials)
  - [SELinux and Quadlet](#selinux-and-quadlet)
- [Cgroup v2 Problems](#cgroup-v2-problems)
  - [Detecting Cgroup Version](#detecting-cgroup-version)
  - [Rootless Cgroup Delegation](#rootless-cgroup-delegation)
  - [Resource Limits Not Working](#resource-limits-not-working)
  - [Migrating from Cgroup v1](#migrating-from-cgroup-v1)
- [Storage Driver Issues](#storage-driver-issues)
  - [Overlay vs Fuse-Overlayfs](#overlay-vs-fuse-overlayfs)
  - [Storage Corruption Recovery](#storage-corruption-recovery)
  - [Disk Space Issues](#disk-space-issues)
  - [UID Mapping and Storage](#uid-mapping-and-storage)
- [Podman Machine Disk and Memory](#podman-machine-disk-and-memory)
  - [Expanding Disk Size](#expanding-disk-size)
  - [Memory Exhaustion](#memory-exhaustion)
  - [VM Won't Start](#vm-wont-start)
  - [Machine Reset and Recovery](#machine-reset-and-recovery)
- [Migration from Docker](#migration-from-docker)
  - [Common Incompatibilities](#common-incompatibilities)
  - [Docker Socket Compatibility](#docker-socket-compatibility)
  - [Compose Migration](#compose-migration)
  - [Volume Migration](#volume-migration)
- [Permission Denied Errors](#permission-denied-errors)
  - [Rootless File Ownership](#rootless-file-ownership)
  - [Subuid/Subgid Configuration](#subuidsubgid-configuration)
  - [Namespace Mapping Issues](#namespace-mapping-issues)
  - [Socket Permission Errors](#socket-permission-errors)
- [DNS Resolution Issues](#dns-resolution-issues)
  - [Aardvark-DNS Problems](#aardvark-dns-problems)
  - [Container-to-Container DNS](#container-to-container-dns)
  - [External DNS Resolution](#external-dns-resolution)
  - [DNS in Pods](#dns-in-pods)

---

## Rootless Networking Issues

### slirp4netns Problems

slirp4netns was the default rootless networking prior to Podman 5.x.

**Symptom**: Extremely slow network performance in rootless containers.

```bash
# Check which network mode is active
podman info --format '{{.Host.NetworkBackendInfo.Backend}}'

# Force slirp4netns if needed
podman run --network slirp4netns myimage

# Increase slirp4netns port handler
podman run --network slirp4netns:port_handler=slirp4netns,enable_ipv6=true myimage
```

**Symptom**: `slirp4netns: slirp_input: error: guest sent a too large packet`

```bash
# Reduce MTU
podman run --network slirp4netns:mtu=1300 myimage
```

**Symptom**: Cannot reach host services from rootless container.

```bash
# Enable outbound connectivity via slirp4netns
podman run --network slirp4netns:allow_host_loopback=true myimage

# Access host at 10.0.2.2 (default slirp4netns gateway)
curl http://10.0.2.2:8080  # from inside container
```

### Pasta Networking Issues

**Symptom**: `pasta` binary not found.

```bash
# Install passt package
# Fedora/RHEL
sudo dnf install passt

# Debian/Ubuntu
sudo apt install passt

# Verify
which pasta
```

**Symptom**: Pasta fails with kernel too old.

Pasta requires Linux kernel 5.7+. Check with:
```bash
uname -r
# If < 5.7, fall back to slirp4netns
podman run --network slirp4netns myimage
```

**Symptom**: Port conflicts with pasta.

```bash
# Pasta maps host ports directly — check for conflicts
ss -tlnp | grep :8080

# Use specific port mapping
podman run --network pasta -p 8081:80 myimage
```

### Port Binding Failures

**Symptom**: `Error: rootlessport listen tcp 0.0.0.0:80: bind: permission denied`

```bash
# Allow unprivileged ports below 1024
echo 'net.ipv4.ip_unprivileged_port_start=0' | sudo tee /etc/sysctl.d/podman-rootless.conf
sudo sysctl --system

# Or use rootful mode for low ports
podman machine set --rootful   # on macOS/Windows

# Or map to higher port
podman run -p 8080:80 myimage
```

**Symptom**: Port already in use after container crash.

```bash
# Find and kill orphaned port handler
ss -tlnp | grep :8080
# Kill the rootlessport process
kill $(lsof -t -i:8080)

# Or reset rootless networking
podman system reset --force
```

### IPv6 Issues in Rootless Mode

```bash
# Enable IPv6 in rootless with pasta (default in 5.x)
podman run --network pasta myimage

# slirp4netns IPv6
podman run --network slirp4netns:enable_ipv6=true myimage

# Verify IPv6 inside container
podman exec mycontainer ip -6 addr show
podman exec mycontainer curl -6 http://ipv6.example.com
```

---

## SELinux Denials

### Volume Mount Denials

**Symptom**: `Permission denied` when accessing bind-mounted files inside container,
even though file permissions look correct.

Root cause: SELinux labels on host files don't match container context.

```bash
# Check SELinux status
getenforce   # Enforcing = SELinux is active

# Check file context
ls -lZ /path/to/volume/
# Output: unconfined_u:object_r:user_home_t:s0 file.txt
# Container expects: container_file_t
```

### :Z and :z Volume Labels

```bash
# :Z — Private relabel (only this container can access)
podman run -v /host/path:/container/path:Z myimage
# Sets: system_u:object_r:container_file_t:s0:c123,c456

# :z — Shared relabel (multiple containers can access)
podman run -v /host/path:/container/path:z myimage
# Sets: system_u:object_r:container_file_t:s0

# WARNING: :Z on system directories can break the host!
# NEVER use :Z with /home, /etc, /var, /usr
# SAFE: :Z on project-specific directories

# Skip labeling entirely
podman run --security-opt label=disable -v /host/path:/container/path myimage
```

**When to use which**:
| Label | Use case |
|-------|----------|
| `:Z`  | Single container exclusive access (most common) |
| `:z`  | Multiple containers share the same volume |
| none  | NFS/CIFS mounts (no SELinux support on network FS) |
| `label=disable` | Debugging, or when SELinux is not needed |

### Diagnosing SELinux Denials

```bash
# View recent SELinux denials
sudo ausearch -m avc -ts recent

# Get human-readable explanation
sudo ausearch -m avc -ts recent | audit2why

# Generate policy to allow the denial
sudo ausearch -m avc -ts recent | audit2allow -M mycontainer
sudo semodule -i mycontainer.pp

# Watch denials in real-time
sudo tail -f /var/log/audit/audit.log | grep 'avc:.*denied'

# Temporarily set SELinux to permissive (for debugging only!)
sudo setenforce 0   # permissive
# Test your container
sudo setenforce 1   # re-enable
```

### SELinux and Quadlet

```ini
[Container]
# Volume with SELinux relabeling
Volume=/data/app:/app:Z

# Disable SELinux for this container
SecurityLabelDisable=true

# Custom SELinux label
SecurityLabelType=container_runtime_t
SecurityLabelLevel=s0:c100,c200
```

---

## Cgroup v2 Problems

### Detecting Cgroup Version

```bash
# Check cgroup version
stat -fc %T /sys/fs/cgroup/
# tmpfs = cgroup v1
# cgroup2fs = cgroup v2

# Or via Podman
podman info --format '{{.Host.CgroupsVersion}}'

# Check if hybrid mode
mount | grep cgroup
```

### Rootless Cgroup Delegation

**Symptom**: Resource limits not applied in rootless mode.

```bash
# Check if delegation is enabled
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers

# Enable cgroup delegation for your user
sudo mkdir -p /etc/systemd/system/user@.service.d/
sudo tee /etc/systemd/system/user@.service.d/delegate.conf << 'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload

# Verify after re-login
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
# Should show: cpu cpuset io memory pids
```

### Resource Limits Not Working

**Symptom**: `--memory`, `--cpus` flags silently ignored.

```bash
# Verify cgroup v2 controllers are available
cat /sys/fs/cgroup/cgroup.controllers

# Check container cgroup
podman inspect mycontainer --format '{{.HostConfig.Memory}}'

# Verify enforcement
podman stats --no-stream mycontainer

# Common fix: ensure systemd cgroup manager
podman info --format '{{.Host.CgroupManager}}'
# Should be: systemd (not cgroupfs)

# Fix in containers.conf:
# [engine]
# cgroup_manager = "systemd"
```

### Migrating from Cgroup v1

```bash
# Switch to cgroup v2 (Fedora/RHEL)
sudo grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"
sudo reboot

# After reboot, verify
stat -fc %T /sys/fs/cgroup/  # should show cgroup2fs

# Reset Podman storage (may be needed)
podman system reset
```

---

## Storage Driver Issues

### Overlay vs Fuse-Overlayfs

```bash
# Check current storage driver
podman info --format '{{.Store.GraphDriverName}}'

# Rootless on older kernels needs fuse-overlayfs
# Install: sudo dnf install fuse-overlayfs  (or apt)

# Configure in ~/.config/containers/storage.conf
# [storage]
# driver = "overlay"
# [storage.options.overlay]
# mount_program = "/usr/bin/fuse-overlayfs"
```

**Symptom**: `overlay: kernel does not support overlay fs`

```bash
# Check kernel support
modprobe overlay
grep overlay /proc/filesystems

# For rootless, check user namespace overlay support
cat /proc/sys/kernel/unprivileged_userns_clone  # should be 1

# If native overlay not supported, use fuse-overlayfs
sudo dnf install fuse-overlayfs
# Then set mount_program in storage.conf
```

**Symptom**: `ERRO[0000] User-selected graph driver "overlay" overwritten by graph driver "vfs"`

```bash
# VFS fallback means overlay isn't working
# Check for missing fuse-overlayfs
which fuse-overlayfs

# Check /etc/subuid and /etc/subgid entries exist
grep $USER /etc/subuid /etc/subgid

# Recreate user namespace mappings
podman system migrate
```

### Storage Corruption Recovery

**Symptom**: `Error: error creating read-write layer` or `invalid layer` errors.

```bash
# List and verify storage
podman system check

# Attempt repair
podman system check --repair

# Nuclear option: full reset (destroys all containers/images/volumes)
podman system reset

# For rootless, manually clean storage
rm -rf ~/.local/share/containers/storage/

# Re-initialize
podman pull alpine  # triggers storage re-init
```

**Symptom**: SQLite database locked (Podman 5.x with SQLite backend).

```bash
# Check for lock files
ls -la ~/.local/share/containers/storage/db.sql*

# Kill any stuck Podman processes
ps aux | grep -E 'podman|conmon' | grep -v grep

# Remove lock and retry
rm -f ~/.local/share/containers/storage/db.sql-journal
```

### Disk Space Issues

```bash
# Check storage usage
podman system df
podman system df -v  # verbose

# Prune unused resources
podman system prune           # dangling images + stopped containers
podman system prune --all     # all unused images
podman system prune --all --volumes  # include volumes

# Prune specific resource types
podman image prune --all
podman container prune
podman volume prune

# Find large images
podman images --sort size --format "{{.Size}}\t{{.Repository}}:{{.Tag}}"

# Find large volumes
podman volume ls --format "{{.Name}}" | while read v; do
  echo "$(podman volume inspect $v --format '{{.Mountpoint}}') $v"
done | xargs -I{} du -sh {}
```

### UID Mapping and Storage

**Symptom**: Files in volumes owned by unexpected UID (like `nobody` or `65534`).

```bash
# Check current UID mappings
podman unshare cat /proc/self/uid_map

# Check subuid/subgid allocations
grep $USER /etc/subuid /etc/subgid
# Expected: username:100000:65536 (start:count)

# Fix file ownership in volume (map host UID to container UID)
podman unshare chown -R 1000:1000 ~/.local/share/containers/storage/volumes/myvolume/_data/

# Understand mapping: container UID 0 = host UID (your UID)
# container UID 1 = host subuid start
# container UID 1000 = host subuid start + 999
```

---

## Podman Machine Disk and Memory

### Expanding Disk Size

```bash
# Check current disk usage
podman machine ssh -- df -h /

# Increase disk (can only grow, not shrink)
podman machine stop
podman machine set --disk-size 200  # GiB
podman machine start

# If disk-size flag doesn't work, expand inside VM
podman machine ssh
sudo growpart /dev/vda 4  # adjust partition number
sudo xfs_growfs /         # or resize2fs for ext4
```

### Memory Exhaustion

**Symptom**: Containers killed by OOM, machine becomes unresponsive.

```bash
# Check VM memory
podman machine ssh -- free -h

# Increase memory (stop first)
podman machine stop
podman machine set --memory 8192  # MiB
podman machine start

# Check container memory usage
podman stats --no-stream

# Set memory limits on containers to prevent OOM
podman run --memory 512m --memory-swap 512m myimage
```

### VM Won't Start

```bash
# Check machine status
podman machine ls

# View logs (macOS)
cat ~/Library/Logs/podman/podman-machine-default.log

# View logs (Linux with QEMU)
journalctl --user -u podman-machine-default

# Common fixes:
# 1. Stop conflicting VMs
podman machine stop
podman machine ls  # verify none running

# 2. Remove stale socket
rm -f /tmp/podman-*.sock
rm -f "$XDG_RUNTIME_DIR/podman/"*

# 3. Reset if corrupt
podman machine rm -f
podman machine init --cpus 4 --memory 4096
podman machine start
```

### Machine Reset and Recovery

```bash
# Full reset (removes all machines)
podman machine reset

# Remove specific machine
podman machine rm myvm

# Force remove (when stuck)
podman machine rm -f myvm

# After Podman major upgrade (4.x → 5.x)
podman machine reset  # required due to VM format changes
podman machine init --cpus 4 --memory 4096 --disk-size 60
podman machine start
```

---

## Migration from Docker

### Common Incompatibilities

| Docker Feature | Podman Equivalent | Notes |
|----------------|-------------------|-------|
| `docker.sock` | `podman.sock` | Enable via `systemctl --user enable podman.socket` |
| Docker Swarm | Not supported | Use Kubernetes or Podman pods |
| Docker BuildKit | Buildah | Similar features, different syntax |
| `--link` (legacy) | Networks | Use custom networks instead |
| `docker-compose` | `podman compose` | Or `podman-compose` package |
| `DOCKER_HOST` | `CONTAINER_HOST` | Environment variable |
| Docker Desktop | Podman Desktop | Free, open-source alternative |

### Docker Socket Compatibility

```bash
# Enable Podman socket (Docker API compatible)
systemctl --user enable --now podman.socket

# Verify socket
curl --unix-socket /run/user/$(id -u)/podman/podman.sock \
  http://localhost/_ping

# For tools expecting Docker socket
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock

# Symlink for hardcoded paths (root mode)
sudo ln -sf /run/podman/podman.sock /var/run/docker.sock

# Test compatibility
docker --host unix:///run/user/$(id -u)/podman/podman.sock ps
```

### Compose Migration

```bash
# Most docker-compose.yml files work as-is
podman compose up -d

# Common issues:
# 1. `network_mode: host` — works but rootless may need adjustments
# 2. `volumes` with relative paths — ensure :Z for SELinux
# 3. `depends_on` with conditions — supported in Podman 5.x
# 4. `deploy.resources` — limited support, use direct flags

# Convert compose to Quadlet (recommended for production)
# Manual process: create .container files matching compose services

# Workaround for compose features not supported
# Use podman-compose (Python) for better compatibility
pip install podman-compose
podman-compose up -d
```

### Volume Migration

```bash
# Export Docker volume
docker run --rm -v myvolume:/data -v $(pwd):/backup \
  alpine tar czf /backup/myvolume.tar.gz -C /data .

# Import to Podman volume
podman volume create myvolume
podman run --rm -v myvolume:/data -v $(pwd):/backup \
  alpine tar xzf /backup/myvolume.tar.gz -C /data

# Migrate all volumes
for vol in $(docker volume ls -q); do
  echo "Migrating volume: $vol"
  docker run --rm -v "$vol":/data -v /tmp/migration:/backup \
    alpine tar czf "/backup/${vol}.tar.gz" -C /data .
  podman volume create "$vol"
  podman run --rm -v "$vol":/data -v /tmp/migration:/backup \
    alpine tar xzf "/backup/${vol}.tar.gz" -C /data
done
```

---

## Permission Denied Errors

### Rootless File Ownership

**Symptom**: Container processes can't write to bind-mounted directories.

```bash
# Container runs as root (UID 0) inside, mapped to your host UID
# Check mapping
podman unshare id  # shows your mapped IDs

# Fix: adjust ownership to match container's expected UID
# If container runs as UID 1000 inside:
podman unshare chown 1000:1000 /host/path/to/data

# Or run container as your UID
podman run --user $(id -u):$(id -g) -v ./data:/data myimage
```

### Subuid/Subgid Configuration

**Symptom**: `Error: cannot set up namespace mapping: [...] may not be in subuid/subgid`

```bash
# Check entries
grep $USER /etc/subuid /etc/subgid

# Add if missing
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER

# Or manually edit
echo "$USER:100000:65536" | sudo tee -a /etc/subuid
echo "$USER:100000:65536" | sudo tee -a /etc/subgid

# Apply changes
podman system migrate
```

### Namespace Mapping Issues

**Symptom**: `ERRO[0000] cannot find UID/GID for user` or `newuidmap: write to uid_map failed`

```bash
# Check if newuidmap/newgidmap have proper capabilities
ls -l /usr/bin/newuidmap /usr/bin/newgidmap
# Should have setuid bit or capabilities

# Fix capabilities
sudo setcap cap_setuid+ep /usr/bin/newuidmap
sudo setcap cap_setgid+ep /usr/bin/newgidmap

# Or set setuid (alternative)
sudo chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap

# Check user_namespaces enabled
cat /proc/sys/user/max_user_namespaces  # should be > 0
echo 28633 | sudo tee /proc/sys/user/max_user_namespaces

# Make persistent
echo 'user.max_user_namespaces=28633' | sudo tee /etc/sysctl.d/userns.conf
```

### Socket Permission Errors

**Symptom**: `Error: unable to connect to Podman socket`

```bash
# Check socket exists
ls -la /run/user/$(id -u)/podman/podman.sock

# Enable and start socket
systemctl --user enable --now podman.socket

# Check XDG_RUNTIME_DIR is set
echo $XDG_RUNTIME_DIR  # should be /run/user/$(id -u)

# If using SSH, XDG_RUNTIME_DIR may not be set
export XDG_RUNTIME_DIR=/run/user/$(id -u)

# Check loginctl for lingering (required for socket to persist)
loginctl show-user $USER --property=Linger
loginctl enable-linger $USER
```

---

## DNS Resolution Issues

### Aardvark-DNS Problems

**Symptom**: Container-to-container DNS not working on custom networks.

```bash
# Check Aardvark is installed
which aardvark-dns
podman info --format '{{.Host.NetworkBackendInfo.DNS}}'
# Should show: aardvark-dns

# Install if missing
sudo dnf install aardvark-dns  # Fedora/RHEL
sudo apt install aardvark-dns  # Debian/Ubuntu

# Restart Aardvark
podman network reload --all
```

**Symptom**: DNS works on `podman network create` networks but not the default `podman` network.

```bash
# The default "podman" network does not enable DNS by default
# Create a custom network with DNS
podman network create --dns-enabled mynet

# Or enable DNS on default network
podman network create --dns-enabled podman-dns
podman run --network podman-dns myimage
```

### Container-to-Container DNS

```bash
# Containers must be on the same custom network
podman network create mynet
podman run -d --network mynet --name svc1 nginx:alpine
podman run -d --network mynet --name svc2 alpine sleep 3600

# Test resolution
podman exec svc2 nslookup svc1
podman exec svc2 ping -c1 svc1

# DNS uses container name by default
# Hostname can be set explicitly
podman run -d --network mynet --name svc3 --hostname web.local nginx:alpine
podman exec svc2 nslookup web.local  # resolves via hostname
podman exec svc2 nslookup svc3       # also resolves via container name
```

### External DNS Resolution

**Symptom**: Containers can't resolve external domains.

```bash
# Check host DNS
cat /etc/resolv.conf

# Check container DNS
podman run --rm alpine cat /etc/resolv.conf

# Override DNS servers
podman run --dns 8.8.8.8 --dns 8.8.4.4 myimage

# Set in containers.conf for all containers
# [containers]
# dns_servers = ["8.8.8.8", "8.8.4.4"]

# Fix systemd-resolved issues (Ubuntu/Fedora with resolved)
# The stub resolver at 127.0.0.53 may not work in containers
podman run --dns $(resolvectl status | grep 'DNS Servers' | head -1 | awk '{print $NF}') myimage
```

### DNS in Pods

```bash
# Pod-level DNS settings
podman pod create --name myapp \
  --dns 8.8.8.8 \
  --dns-search example.com \
  --add-host dbhost:10.0.0.5

# All containers in the pod share DNS config
podman run -d --pod myapp --name web nginx:alpine
podman run -d --pod myapp --name api myapi:latest

# Containers in same pod use localhost, not DNS
# DNS is only needed for external or cross-pod communication

# Debug DNS inside pod
podman exec web cat /etc/resolv.conf
podman exec web nslookup google.com
```
