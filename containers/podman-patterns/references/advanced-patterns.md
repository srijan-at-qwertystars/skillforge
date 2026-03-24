# Advanced Podman Patterns

## Table of Contents

- [Quadlet Deep Dive](#quadlet-deep-dive)
  - [.container Units](#container-units)
  - [.volume Units](#volume-units)
  - [.network Units](#network-units)
  - [.kube Units](#kube-units)
  - [.image Units](#image-units)
  - [.pod Units](#pod-units)
  - [Quadlet Dependencies and Ordering](#quadlet-dependencies-and-ordering)
  - [Quadlet Environment and Secrets](#quadlet-environment-and-secrets)
- [Podman Farm for Multi-Arch Builds](#podman-farm-for-multi-arch-builds)
  - [Farm Setup](#farm-setup)
  - [Building Multi-Arch Images](#building-multi-arch-images)
  - [Farm Management](#farm-management)
- [Pasta Networking Mode](#pasta-networking-mode)
  - [How Pasta Works](#how-pasta-works)
  - [Pasta Configuration Options](#pasta-configuration-options)
  - [Pasta vs slirp4netns](#pasta-vs-slirp4netns)
- [HyperV and Apple Hypervisor Integration](#hyperv-and-apple-hypervisor-integration)
  - [macOS with Apple Hypervisor](#macos-with-apple-hypervisor)
  - [Windows with HyperV / WSL2](#windows-with-hyperv--wsl2)
  - [Virtiofs File Sharing](#virtiofs-file-sharing)
- [Podman Machine Customization](#podman-machine-customization)
  - [Resource Allocation](#resource-allocation)
  - [Custom Machine Images](#custom-machine-images)
  - [Connection Management](#connection-management)
  - [Provisioning Scripts](#provisioning-scripts)
- [Health Checks](#health-checks)
  - [Defining Health Checks](#defining-health-checks)
  - [Health Check in Quadlet](#health-check-in-quadlet)
  - [Custom Health Check Scripts](#custom-health-check-scripts)
  - [Monitoring Health Status](#monitoring-health-status)
- [Pod Resource Limits](#pod-resource-limits)
  - [CPU Limits](#cpu-limits)
  - [Memory Limits](#memory-limits)
  - [Combined Resource Constraints](#combined-resource-constraints)
- [Init Containers](#init-containers)
  - [Init Container Concepts](#init-container-concepts)
  - [Init Containers in Pods](#init-containers-in-pods)
  - [Init Containers in Quadlet](#init-containers-in-quadlet)
- [Infra Containers](#infra-containers)
  - [Infra Container Role](#infra-container-role)
  - [Custom Infra Containers](#custom-infra-containers)
  - [Infra Container Networking](#infra-container-networking)

---

## Quadlet Deep Dive

Quadlet is the modern systemd integration for Podman (replacing `podman generate systemd`).
Quadlet reads declarative unit files and generates systemd service units at runtime via
a systemd generator (`/usr/lib/systemd/user-generators/podman-user-generator` for rootless,
`/usr/lib/systemd/system-generators/podman-system-generator` for root).

### File locations

| Context   | Path                                  |
|-----------|---------------------------------------|
| Rootless  | `~/.config/containers/systemd/`       |
| Root      | `/etc/containers/systemd/`            |
| RPM/DEB   | `/usr/share/containers/systemd/`      |

Quadlet supports subdirectories. Files can be organized:
```
~/.config/containers/systemd/
├── webapp/
│   ├── webapp.container
│   ├── webapp-data.volume
│   └── webapp.network
└── monitoring/
    ├── prometheus.container
    └── grafana.container
```

### .container Units

Full reference of key directives:

```ini
[Unit]
Description=Application container
After=network-online.target
Requires=app-data.volume app.network
Wants=redis.container

[Container]
# Image source
Image=docker.io/library/nginx:1.27-alpine
Pull=newer                  # always | missing | newer | never

# Naming
ContainerName=webapp

# Networking
PublishPort=8080:80
PublishPort=8443:443/tcp
Network=app.network
HostName=webapp
AddHost=dbhost:10.89.1.5
DNS=8.8.8.8
DNSSearch=example.com
IP=10.89.1.10

# Volumes and mounts
Volume=app-data.volume:/data:Z
Volume=%h/config:/etc/app:ro,Z
Mount=type=tmpfs,destination=/tmp,tmpfs-size=128M
Mount=type=devpts,destination=/dev/pts

# Environment
Environment=APP_ENV=production
Environment=LOG_LEVEL=info
EnvironmentFile=%h/.config/app/env
Secret=db_pass,type=env,target=DB_PASSWORD
Secret=tls_cert,type=mount,target=/certs/server.crt

# Security
SecurityLabelDisable=false
NoNewPrivileges=true
DropCapability=ALL
AddCapability=NET_BIND_SERVICE
ReadOnly=true
ReadOnlyTmpfs=true
SeccompProfile=/path/to/seccomp.json
UserNS=auto
User=1000
Group=1000
Ulimit=nofile=65535:65535

# Resources
PodmanArgs=--memory=512m --cpus=1.5 --pids-limit=200

# Health check
HealthCmd=/bin/sh -c "curl -f http://localhost/ || exit 1"
HealthInterval=30s
HealthRetries=3
HealthStartPeriod=10s
HealthTimeout=5s
HealthOnFailure=restart

# Auto-update
AutoUpdate=registry
Label=io.containers.autoupdate=registry

# Exec
Entrypoint=/docker-entrypoint.sh
Exec=nginx -g "daemon off;"
WorkingDir=/app
StopTimeout=30

# Logging
LogDriver=journald

# Init
RunInit=true

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target default.target
```

### .volume Units

```ini
[Unit]
Description=Application data volume

[Volume]
# Volume name (default: derived from filename)
VolumeName=app-data

# Driver options
Driver=local
# For NFS:
# Options=type=nfs,o=addr=192.168.1.100,rw,nfsvers=4,async

# Labels
Label=app=webapp
Label=env=production

# Ownership
User=1000
Group=1000

# Copy content from image on first use
Copy=true

# Device (for block device mounts)
# Device=/dev/sdb1
# Type=ext4
```

### .network Units

```ini
[Unit]
Description=Application network

[Network]
# Network name
NetworkName=app-net

# Subnets (can specify multiple)
Subnet=10.89.1.0/24
Gateway=10.89.1.1

# IPv6
IPv6=true
Subnet=fd00:dead:beef::/64
Gateway=fd00:dead:beef::1

# DNS
DNS=10.89.1.1
DNSEnabled=true

# Driver
Driver=bridge

# Internal (no outbound connectivity)
Internal=false

# Labels
Label=env=production

# Options
Options=mtu=9000
Options=isolate=true
```

### .kube Units

Deploy Kubernetes YAML via Quadlet:

```ini
[Unit]
Description=Kubernetes deployment via Quadlet
After=network-online.target

[Kube]
# Path to Kubernetes YAML
Yaml=/etc/containers/kube/app-deployment.yaml

# ConfigMap files
ConfigMap=/etc/containers/kube/configmap.yaml

# Auto-update images
AutoUpdate=registry

# Network to use
Network=app.network

# Publish ports (if not in YAML)
PublishPort=8080:80

# Run in existing pod
# SetWorkingDirectory=yaml

# User namespace
UserNS=auto

[Service]
Restart=always

[Install]
WantedBy=default.target
```

### .image Units

Pull and manage images via Quadlet:

```ini
[Unit]
Description=Pull application image

[Image]
# Image to pull
Image=docker.io/library/nginx:1.27-alpine

# Pull policy
AllTags=false

# Architecture
Arch=amd64

# TLS verification
TLSVerify=true

# Auth file
AuthFile=/run/containers/0/auth.json

# Credentials
# Creds=username:password

[Install]
WantedBy=default.target
```

The `.image` unit generates a `<name>-image.service` that pulls the image. Other
`.container` units can depend on it to ensure the image is present before starting.

### .pod Units

```ini
[Unit]
Description=Application pod

[Pod]
PodName=webapp-pod

# Port publishing (applies to all containers in pod)
PublishPort=8080:80
PublishPort=5432:5432

# Network
Network=app.network

# Pod-level resource limits (Podman 5.x)
PodmanArgs=--cpus=4 --memory=2g

# DNS
DNS=8.8.8.8
DNSSearch=example.com

# Infra container customization
InfraImage=registry.k8s.io/pause:3.9

[Install]
WantedBy=default.target
```

Containers join a pod via `Pod=webapp.pod` in their `.container` file.

### Quadlet Dependencies and Ordering

Quadlet automatically creates implicit dependencies:
- `Volume=app-data.volume:...` → depends on `app-data-volume.service`
- `Network=app.network` → depends on `app-network.service`
- `Pod=webapp.pod` → depends on `webapp-pod.service`

For explicit ordering between containers:

```ini
# In worker.container
[Unit]
After=redis.service
Requires=redis.service
```

### Quadlet Environment and Secrets

```ini
[Container]
# Inline variables
Environment=APP_ENV=production
Environment=LOG_LEVEL=info

# From file
EnvironmentFile=%h/.config/app/env
EnvironmentFile=/etc/app/common.env

# Podman secrets (created with `podman secret create`)
Secret=db_pass,type=env,target=DB_PASSWORD
Secret=tls_key,type=mount,target=/certs/key.pem
Secret=app_config,type=mount,target=/etc/app/config.json

# Systemd specifiers in Quadlet
# %h = user home directory
# %n = unit name
# %i = instance name (for template units)
# %t = runtime directory (/run or /run/user/UID)
```

---

## Podman Farm for Multi-Arch Builds

Podman farm enables building multi-architecture container images across multiple
machines without emulation, producing a single manifest list.

### Farm Setup

```bash
# Add remote build nodes via SSH connections
podman system connection add arm-builder ssh://user@arm-host/run/podman/podman.sock
podman system connection add x86-builder ssh://user@x86-host/run/podman/podman.sock

# Create a farm from connections
podman farm create my-farm arm-builder x86-builder

# List farms
podman farm ls

# Inspect farm details
podman farm inspect my-farm
```

Prerequisites:
- SSH access to remote nodes with key-based authentication
- Podman installed on all nodes
- `podman.sock` accessible on remote systems (enable `podman.socket` systemd service)

### Building Multi-Arch Images

```bash
# Build on all farm nodes, push manifest list
podman farm build -t quay.io/user/myapp:latest .

# Build with specific Containerfile
podman farm build -t quay.io/user/myapp:latest -f Containerfile.prod .

# Build and push to registry
podman farm build -t quay.io/user/myapp:latest --push .

# Build specific platforms only
podman farm build -t myapp:latest \
  --platform linux/amd64,linux/arm64 .

# Cleanup local images after push
podman farm build -t myapp:latest --cleanup .
```

### Farm Management

```bash
# Add a node to existing farm
podman farm update --add new-builder my-farm

# Remove a node
podman farm update --remove old-builder my-farm

# Set default farm
podman farm update --default my-farm

# Remove farm
podman farm rm my-farm

# List system connections
podman system connection ls
```

---

## Pasta Networking Mode

Pasta (Pack A Subtle Tap Abstraction) is the default rootless networking in Podman 5.x,
replacing slirp4netns. It provides better performance and more features.

### How Pasta Works

Pasta creates a network namespace with a tap device and connects it to the host using
a translation layer. Unlike slirp4netns (userspace TCP/IP stack), pasta uses kernel
networking for better throughput and lower latency.

Key advantages:
- **Native kernel performance**: No userspace TCP/IP overhead
- **Full IPv6 support**: Dual-stack out of the box
- **Lower memory usage**: Shared kernel network stack
- **Better port forwarding**: Direct kernel handling

### Pasta Configuration Options

```bash
# Use pasta explicitly (default in Podman 5.x)
podman run --network pasta nginx:alpine

# Pasta with specific options
podman run --network pasta:--map-gw nginx:alpine

# Disable DNS forwarding
podman run --network pasta:--no-dns nginx:alpine

# Map specific ports only
podman run --network pasta:--tcp-ports=80,443 nginx:alpine

# Disable IPv6
podman run --network pasta:--no-ipv6 nginx:alpine

# Custom MTU
podman run --network pasta:--mtu=1400 nginx:alpine

# Copy host routes to namespace
podman run --network pasta:--no-copy-routes nginx:alpine
```

Set pasta as default in `containers.conf`:

```ini
[network]
default_rootless_network_cmd = "pasta"
```

### Pasta vs slirp4netns

| Feature              | pasta             | slirp4netns      |
|----------------------|-------------------|------------------|
| TCP throughput       | Near native       | ~50-70% native   |
| IPv6 support         | Full              | Limited          |
| Memory overhead      | Low               | Higher           |
| Port forwarding      | Kernel-based      | Userspace        |
| Availability         | Podman 5.x+       | Podman 3.x+      |
| UDP support          | Full              | Partial          |
| ICMP                 | Supported         | Not supported    |

To fall back to slirp4netns (e.g., on older kernels):
```bash
podman run --network slirp4netns nginx:alpine
```

---

## HyperV and Apple Hypervisor Integration

### macOS with Apple Hypervisor

Podman 5.x on macOS uses `applehv` (Apple Hypervisor framework) by default:

```bash
# Default init uses Apple Hypervisor
podman machine init --cpus 4 --memory 8192 --disk-size 100

# Explicit provider selection
podman machine init --vmtype applehv

# File sharing uses virtiofs (default in 5.x)
# Mount host directories into the VM
podman machine init --volume /Users/dev/projects:/projects

# Rosetta 2 support for running x86_64 containers on Apple Silicon
podman machine init --rosetta
```

The Apple Hypervisor provides:
- Near-native performance (no QEMU overhead)
- Automatic virtiofs mounts for home directory
- Rosetta 2 integration for x86_64 emulation on Apple Silicon
- Lower memory footprint than QEMU-based VMs

### Windows with HyperV / WSL2

```bash
# WSL2 backend (default)
podman machine init

# HyperV backend
podman machine init --vmtype hyperv

# Note: HyperV requires Windows Pro/Enterprise and admin privileges
# WSL2 works on all Windows 11 editions
```

HyperV advantages:
- Better network isolation
- VHD disk management
- Group Policy integration

WSL2 advantages:
- Lower resource usage
- Faster startup
- Works on Windows Home edition

### Virtiofs File Sharing

Virtiofs provides near-native file system performance for host-to-VM mounts:

```bash
# Add mount during init
podman machine init --volume /host/path:/vm/path

# Add mount to existing machine (stop first)
podman machine stop
podman machine set --volume /host/path:/vm/path

# Remove a mount
podman machine set --volume /host/path-

# Inside containers, access via the VM mount path
podman run -v /vm/path:/container/path myapp
```

---

## Podman Machine Customization

### Resource Allocation

```bash
# Set during init
podman machine init \
  --cpus 4 \
  --memory 8192 \     # in MiB
  --disk-size 100     # in GiB

# Modify existing machine (stop first)
podman machine stop
podman machine set --cpus 8
podman machine set --memory 16384
podman machine set --disk-size 200  # disk can only grow, not shrink

# Set rootful mode
podman machine set --rootful

# Set user-mode networking
podman machine set --user-mode-networking
```

### Custom Machine Images

```bash
# Use a custom Fedora CoreOS image
podman machine init --image-path /path/to/custom-fcos.qcow2

# Use a specific FCOS stream
podman machine init --image-path https://builds.coreos.fedoraproject.org/...

# After init, further customize via SSH
podman machine ssh
sudo rpm-ostree install htop vim
sudo systemctl reboot
```

### Connection Management

```bash
# List connections (local and remote)
podman system connection ls

# Add remote connection
podman system connection add remote-host \
  ssh://user@remote-host:22/run/podman/podman.sock

# Set default connection
podman system connection default remote-host

# Remove connection
podman system connection remove remote-host

# Use specific connection for a command
podman --connection remote-host ps
```

### Provisioning Scripts

Automate machine setup with post-init scripts:

```bash
#!/bin/bash
# provision-machine.sh
podman machine init --cpus 4 --memory 8192 --disk-size 100
podman machine start

# Install additional packages
podman machine ssh -- sudo rpm-ostree install podman-compose
podman machine ssh -- sudo systemctl reboot

# Wait for reboot
sleep 30
podman machine ssh -- podman --version

# Configure registries inside the VM
podman machine ssh -- 'cat > /etc/containers/registries.conf.d/local.conf << EOF
[[registry]]
location = "registry.internal:5000"
insecure = true
EOF'
```

---

## Health Checks

### Defining Health Checks

```bash
# In podman run
podman run -d \
  --health-cmd "curl -f http://localhost:8080/health || exit 1" \
  --health-interval 30s \
  --health-retries 3 \
  --health-start-period 10s \
  --health-timeout 5s \
  --health-on-failure restart \
  --name webapp myapp:latest

# In Containerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1
```

### Health Check in Quadlet

```ini
[Container]
Image=myapp:latest
HealthCmd=/bin/sh -c "curl -f http://localhost:8080/health || exit 1"
HealthInterval=30s
HealthRetries=3
HealthStartPeriod=10s
HealthTimeout=5s
HealthOnFailure=restart    # none | kill | restart | stop
HealthStartupCmd=/bin/sh -c "curl -f http://localhost:8080/ready || exit 1"
HealthStartupInterval=5s
HealthStartupRetries=10
HealthStartupTimeout=3s
```

### Custom Health Check Scripts

```bash
#!/bin/sh
# /healthcheck.sh — multi-check health script
set -e

# Check web server responds
curl -sf http://localhost:8080/health > /dev/null

# Check database connection
pg_isready -h localhost -p 5432 -U app > /dev/null

# Check disk space (fail if > 90% used)
USAGE=$(df / | awk 'NR==2 {print int($5)}')
[ "$USAGE" -lt 90 ]

# Check process count
PROCS=$(pgrep -c myapp)
[ "$PROCS" -ge 1 ]
```

### Monitoring Health Status

```bash
# Check health status
podman healthcheck run webapp

# View health in inspect output
podman inspect webapp --format '{{.State.Health.Status}}'
# Returns: healthy | unhealthy | starting

# View health log (last N checks)
podman inspect webapp --format '{{json .State.Health}}' | jq

# List containers with health status
podman ps --format "{{.Names}} {{.Status}}"

# Watch health transitions
podman events --filter event=health_status
```

---

## Pod Resource Limits

### CPU Limits

```bash
# Limit pod to 2 CPUs
podman pod create --name limited-pod --cpus 2

# CPU shares (relative weight)
podman pod create --name weighted-pod --cpu-shares 512

# Pin to specific CPUs
podman pod create --name pinned-pod --cpuset-cpus 0,1
```

### Memory Limits

```bash
# Hard memory limit
podman pod create --name mem-limited --memory 1g

# Memory with swap limit
podman pod create --name swap-limited \
  --memory 1g --memory-swap 2g

# Memory reservation (soft limit)
podman pod create --name soft-limited \
  --memory-reservation 512m --memory 1g
```

### Combined Resource Constraints

```bash
# Production pod with full resource limits
podman pod create --name production \
  --cpus 4 \
  --memory 4g \
  --memory-swap 4g \
  --pids-limit 1000 \
  -p 8080:80 \
  -p 5432:5432

# Per-container limits within a pod
podman run -d --pod production --name web \
  --memory 1g --cpus 1 nginx:alpine

podman run -d --pod production --name api \
  --memory 2g --cpus 2 myapi:latest

podman run -d --pod production --name db \
  --memory 1g --cpus 1 postgres:16-alpine
```

In Quadlet pod files:
```ini
[Pod]
PodName=production
PodmanArgs=--cpus=4 --memory=4g --pids-limit=1000
```

---

## Init Containers

### Init Container Concepts

Init containers run before the main application containers in a pod. They are used for:
- Database schema migrations
- Configuration file generation
- Waiting for dependent services
- Downloading assets or secrets

Init containers run to completion and must exit 0 before main containers start.

### Init Containers in Pods

```bash
# Create pod
podman pod create --name myapp -p 8080:80

# Add init container (runs first, must complete)
podman create --pod myapp --init-ctr=once --name db-migrate \
  myapp-migrate:latest python manage.py migrate

# Add init container that runs before every pod restart
podman create --pod myapp --init-ctr=always --name config-gen \
  busybox sh -c "envsubst < /tmpl/config.tmpl > /shared/config.yaml"

# Add main containers
podman run -d --pod myapp --name web nginx:alpine
podman run -d --pod myapp --name api myapp:latest
```

Init container types:
- `once`: Runs once during pod creation (default)
- `always`: Runs before main containers on every pod start

### Init Containers in Quadlet

```ini
# init-migrate.container
[Container]
Image=myapp-migrate:latest
Pod=myapp.pod
Exec=python manage.py migrate
PodmanArgs=--init-ctr=once

# Shared volume for init → main data passing
Volume=shared-config.volume:/shared:Z
```

---

## Infra Containers

### Infra Container Role

Every pod has an infra (pause) container that:
- Holds the pod's network namespace
- Holds the pod's PID namespace
- Keeps namespaces alive even if all other containers stop
- Has minimal resource footprint (runs the `pause` binary)

The infra container is created automatically when a pod is created.

### Custom Infra Containers

```bash
# Use custom infra image
podman pod create --name myapp \
  --infra-image registry.k8s.io/pause:3.9

# Disable infra container (advanced, containers won't share namespaces)
podman pod create --name myapp --infra=false

# Custom infra command
podman pod create --name myapp \
  --infra-command /custom-pause
```

In Quadlet:
```ini
[Pod]
PodName=myapp
InfraImage=registry.k8s.io/pause:3.9
```

### Infra Container Networking

The infra container owns all port mappings and network configuration:

```bash
# Ports are always mapped on the pod (via infra container)
podman pod create --name webapp -p 8080:80 -p 443:443

# Network is set at pod level
podman pod create --name webapp --network mynet

# Inspect infra container
podman inspect $(podman pod inspect webapp --format '{{.InfraContainerId}}')

# The infra container's network config applies to all pod members
# Individual containers do NOT specify ports when in a pod
```

DNS resolution in pods:
- All containers in a pod share the same network namespace
- They communicate via `localhost`
- External DNS resolution is handled by the infra container's config
- Custom DNS: `podman pod create --dns 8.8.8.8 --name myapp`
