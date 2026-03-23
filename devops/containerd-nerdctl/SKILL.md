---
name: containerd-nerdctl
description: >
  Guide for managing containers with containerd and nerdctl. Use when working with containerd
  configuration (config.toml), nerdctl CLI commands, CRI-compliant container runtime setup,
  OCI image management, rootless containers, BuildKit image builds, CNI networking, snapshotter
  plugins (overlayfs, stargz, nydus), nerdctl compose, registry mirrors, container namespaces,
  crictl/ctr usage, or migrating from Docker to containerd. Trigger on keywords: containerd,
  nerdctl, container runtime, CRI, OCI runtime, rootless containers, BuildKit, snapshotter,
  stargz, nydus, CNI plugins, containerd config, ctr, crictl, nerdctl compose, containerd
  namespace, image signing, cosign, lazy pulling, containerd-rootless. Do NOT trigger for
  Docker Engine/dockerd-specific issues, Docker Swarm, Docker Desktop, Podman, CRI-O, or
  general Kubernetes cluster administration unrelated to the container runtime layer.
---

# containerd & nerdctl Reference

## What They Are

**containerd** is an industry-standard, CRI-compliant container runtime. It manages the complete container lifecycle — image transfer, storage, container execution, supervision, and networking. It runs as a daemon and exposes a gRPC API. Kubernetes uses containerd via the CRI plugin.

**nerdctl** is a Docker-compatible CLI for containerd. It provides familiar `docker`-style commands (`run`, `build`, `pull`, `push`, `compose`) while talking directly to containerd — no Docker daemon required.

## Installation

### Standalone containerd + nerdctl (full bundle)

```bash
# Download nerdctl full bundle (includes containerd, runc, CNI plugins, BuildKit)
wget https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-full-2.2.1-linux-amd64.tar.gz
sudo tar -C /usr/local -xzf nerdctl-full-2.2.1-linux-amd64.tar.gz
sudo systemctl enable --now containerd buildkit
```

### From OS packages

```bash
# Debian/Ubuntu
sudo apt-get install containerd.io
# RHEL/CentOS
sudo yum install containerd.io
# Install nerdctl separately
wget https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-2.2.1-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf nerdctl-2.2.1-linux-amd64.tar.gz
```

### For Kubernetes nodes

```bash
sudo apt-get install containerd.io
containerd config default | sudo tee /etc/containerd/config.toml
# Set SystemdCgroup = true for cgroup v2 compatibility
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
```

## nerdctl vs Docker CLI Command Mapping

| Docker Command | nerdctl Equivalent | Notes |
|---|---|---|
| `docker run` | `nerdctl run` | Identical flags |
| `docker build` | `nerdctl build` | Requires BuildKit |
| `docker compose up` | `nerdctl compose up` | Compatible with docker-compose.yaml |
| `docker pull/push` | `nerdctl pull/push` | Same syntax |
| `docker ps` | `nerdctl ps` | Same flags |
| `docker exec` | `nerdctl exec` | Same flags |
| `docker logs` | `nerdctl logs` | Same flags |
| `docker network` | `nerdctl network` | Uses CNI instead of libnetwork |
| `docker volume` | `nerdctl volume` | Same syntax |
| `docker inspect` | `nerdctl inspect` | Same output format |
| `docker login` | `nerdctl login` | Same syntax |
| `docker tag` | `nerdctl tag` | Same syntax |

Alias for teams migrating: `alias docker=nerdctl`

## containerd Configuration (config.toml)

Default location: `/etc/containerd/config.toml`. Generate defaults:

```bash
containerd config default > /etc/containerd/config.toml
# Migrate config after containerd upgrade
containerd config migrate /etc/containerd/config.toml
```

### Key configuration sections

```toml
version = 3

[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.10"
  snapshotter = "overlayfs"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

Always restart containerd after modifying config.toml: `sudo systemctl restart containerd`.

## Image Management```bash
nerdctl pull nginx:alpine
nerdctl pull --platform linux/arm64 nginx:alpine
nerdctl tag nginx:alpine myregistry.io/nginx:alpine
nerdctl push myregistry.io/nginx:alpine
nerdctl images
nerdctl rmi nginx:alpine

# Build with BuildKit (requires buildkitd running)
nerdctl build -t myapp:latest .
nerdctl build --platform linux/amd64,linux/arm64 -t myapp:latest .
nerdctl build --sbom=true --provenance=true -t myapp:latest .

# Save/load and convert for lazy pulling
nerdctl save -o myapp.tar myapp:latest
nerdctl load -i myapp.tar
nerdctl image convert --estargz --oci myapp:latest myapp:estargz
nerdctl image convert --nydus myapp:latest myapp:nydus
```

## Container Lifecycle

```bash
nerdctl run -d --name web -p 8080:80 nginx:alpine
nerdctl run -it --rm alpine sh
nerdctl run -d --restart=always --name db -v dbdata:/var/lib/mysql mysql:8
nerdctl exec -it web sh
nerdctl logs -f --tail 100 web
nerdctl inspect --format '{{.State.Status}}' web
nerdctl stop web && nerdctl start web && nerdctl restart web
nerdctl rm -f web
nerdctl stats
nerdctl top web

# Checkpoint and restore
nerdctl checkpoint create web checkpoint1
nerdctl start --checkpoint checkpoint1 web
```

## Namespaces in containerd

containerd uses namespaces to isolate resources. Kubernetes uses the `k8s.io` namespace. nerdctl defaults to `default`.

```bash
# List containers in the Kubernetes namespace
nerdctl --namespace k8s.io ps -a

# List all namespaces
nerdctl namespace ls

# Run in a specific namespace
nerdctl --namespace myns run -d --name test alpine sleep 3600

# ctr namespace operations
ctr namespaces list
ctr --namespace k8s.io containers list
```

Do NOT mix namespaces. Images pulled in one namespace are not visible in another.

## Networking (CNI)
nerdctl uses CNI plugins instead of Docker's libnetwork. Install CNI plugins to `/opt/cni/bin/`.

```bash
# Create a bridge network (default mode)
nerdctl network create mynet

# Create with specific subnet
nerdctl network create --subnet 10.10.0.0/24 mynet

# Create macvlan network
nerdctl network create --driver macvlan --subnet 192.168.1.0/24 -o parent=eth0 macnet

# Use host networking
nerdctl run --net host nginx:alpine

# Connect container to network
nerdctl run -d --name web --net mynet nginx:alpine

# Inspect and remove networks
nerdctl network inspect mynet
nerdctl network rm mynet
nerdctl network ls
```

### CNI config location

- System: `/etc/cni/net.d/`
- Rootless: `~/.config/cni/net.d/`

Default bridge network `nerdctl0` uses subnet `10.4.0.0/24`.

## Storage (Snapshotter Plugins)
### overlayfs (default)

Standard Linux overlay filesystem. Works on most kernels. Default and recommended for general use.

### stargz (lazy pulling)

Enables on-demand layer loading — containers start before full image download.

```toml
# In config.toml — register stargz as proxy plugin
[proxy_plugins.stargz]
  type = "snapshot"
  address = "/run/containerd-stargz-grpc/containerd-stargz-grpc.sock"
```

```bash
# Run with stargz snapshotter
nerdctl --snapshotter stargz run ghcr.io/stargz-containers/nginx:latest
```

### nydus (lazy pulling)

Alternative lazy-pull snapshotter with better performance for large images.

```toml
[proxy_plugins.nydus]
  type = "snapshot"
  address = "/run/nydus-snapshotter/nydus-snapshotter.sock"
```

```bash
nerdctl --snapshotter nydus run myimage:nydus
```

## Rootless Containers

Run containerd and nerdctl without root privileges. Improves security by mapping container root to an unprivileged host user.

```bash
# Install rootless containerd
containerd-rootless-setuptool.sh install

# Install rootless BuildKit
containerd-rootless-setuptool.sh install-buildkit

# Start rootless containerd via systemd user service
systemctl --user start containerd

# Use nerdctl as normal (no sudo)
nerdctl run -d --name web -p 8080:80 nginx:alpine

# Check rootless status
containerd-rootless-setuptool.sh check

# Enable bypass4netns for better rootless network performance
containerd-rootless-setuptool.sh install-bypass4netnsd
```

### Rootless prerequisites

- `uidmap` package (for `newuidmap`/`newgidmap`), entries in `/etc/subuid` and `/etc/subgid`
- Kernel with user namespaces enabled, `slirp4netns` or `bypass4netns` for networking

## nerdctl compose

Docker Compose compatible. Use existing `docker-compose.yaml` files directly.

```bash
nerdctl compose up -d
nerdctl compose down
nerdctl compose logs -f
nerdctl compose up -d --scale web=3
nerdctl compose up -d --build
nerdctl compose ps
nerdctl compose exec web sh
nerdctl compose -f production.yaml up -d
```

Supported: services, networks, volumes, ports, environment, depends_on, restart, healthcheck, build context. Not supported: deploy, configs, secrets (Swarm-only features).

## Registry Mirrors and Insecure Registries

Use the `hosts.toml` directory method (recommended over inline config):

```bash
# Set config_path in config.toml
# [plugins."io.containerd.grpc.v1.cri".registry]
#   config_path = "/etc/containerd/certs.d"

# Create mirror config for Docker Hub
sudo mkdir -p /etc/containerd/certs.d/docker.io
cat <<EOF | sudo tee /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"

[host."https://mirror.example.com"]
  capabilities = ["pull", "resolve"]
EOF

# Insecure (HTTP) registry — set skip_verify = true
sudo mkdir -p /etc/containerd/certs.d/myregistry.local:5000
cat <<EOF | sudo tee /etc/containerd/certs.d/myregistry.local:5000/hosts.toml
server = "http://myregistry.local:5000"
[host."http://myregistry.local:5000"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

# Private registry with TLS — add ca and client keys in hosts.toml
# ca = "/path/to/ca.crt"
# client = [["/path/to/client.cert", "/path/to/client.key"]]
```

For nerdctl without CRI (standalone), use `nerdctl login` or `~/.docker/config.json`.

## Content Trust and Image Verification

### cosign integration

```bash
# Verify image signature
nerdctl pull --verify=cosign --cosign-key cosign.pub myregistry.io/myapp:latest

# Sign an image after pushing
cosign sign --key cosign.key myregistry.io/myapp:latest

# Enforce verification in pull
NERDCTL_EXPERIMENTAL=1 nerdctl pull --verify=cosign myregistry.io/myapp:latest
```

### Image encryption (OCIcrypt)

```bash
# Encrypt an image
nerdctl image encrypt --recipient jwe:mypubkey.pem myapp:latest myapp:encrypted

# Run encrypted image (requires decryption key)
nerdctl run --decryption-keys-path /keys/ myapp:encrypted
```

## Integration with Kubernetes (CRI Plugin)

containerd serves as the CRI runtime for kubelet. Ensure:

```toml
# config.toml — CRI plugin is enabled by default
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.10"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

```bash
# Verify kubelet is using containerd
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock info

# kubelet flag
# --container-runtime-endpoint=unix:///run/containerd/containerd.sock
```

Set `SystemdCgroup = true` when using cgroup v2 (required for modern distros).

## ctr vs nerdctl vs crictl

| Aspect | ctr | nerdctl | crictl |
|---|---|---|---|
| Purpose | Low-level containerd debug | Docker-compatible UX | Kubernetes CRI debug |
| Audience | containerd developers | App developers, ops | K8s node operators |
| Docker compat | No | Yes | No |
| Compose support | No | Yes | No |
| Build support | No | Yes (BuildKit) | No |
| Namespace aware | Yes | Yes | CRI namespace only |
| K8s pod aware | No | No | Yes |
| Image mgmt | Basic | Full | Basic |
| Production use | Debug only | Yes | Debug only |

```bash
# ctr — low-level operations
ctr images pull docker.io/library/alpine:latest
ctr run --rm docker.io/library/alpine:latest test echo hello
ctr tasks list
ctr containers list

# crictl — Kubernetes CRI debugging
crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
crictl pods
crictl logs <container-id>
crictl images
crictl inspect <container-id>
```

Use nerdctl for daily work. Use ctr for containerd internals debugging. Use crictl for Kubernetes node-level container debugging.

## Lazy Pulling (stargz / nydus)

```bash
# Convert existing image to eStargz format
nerdctl image convert --estargz --oci sourceimage:tag targetimage:estargz

# Convert to nydus format
nerdctl image convert --nydus sourceimage:tag targetimage:nydus

# Push converted image
nerdctl push targetimage:estargz

# Run with lazy pulling enabled
nerdctl --snapshotter stargz run targetimage:estargz
nerdctl --snapshotter nydus run targetimage:nydus
```

Benefits: 60-80% faster container startup for large images. Requires snapshotter daemon running alongside containerd.

## Debugging and Troubleshooting

```bash
# Check containerd status
sudo systemctl status containerd
sudo journalctl -u containerd -f

# Verify containerd and CRI
sudo ctr version
sudo nerdctl info
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock info

# Check plugins and snapshotter
sudo ctr plugins ls | grep snapshot
sudo ctr content ls
sudo ctr snapshots ls

# Debug networking
ls /etc/cni/net.d/
cat /etc/cni/net.d/nerdctl-*.conflist

# Rootless troubleshooting
systemctl --user status containerd
containerd-rootless-setuptool.sh check

# Verify BuildKit
sudo systemctl status buildkit

# Socket paths: containerd=/run/containerd/containerd.sock
# BuildKit=/run/buildkit/buildkitd.sock
# Rootless=$XDG_RUNTIME_DIR/containerd/containerd.sock
```

### Common issues

- **"failed to create shim"**: Check runc binary exists at `/usr/local/sbin/runc` or `/usr/bin/runc`.
- **"cgroup mount not found"**: Enable `SystemdCgroup = true` on cgroup v2 systems.
- **"network not found"**: Install CNI plugins to `/opt/cni/bin/`.
- **"permission denied"**: For rootless, ensure `/etc/subuid` and `/etc/subgid` are configured.
- **Build fails**: Ensure `buildkitd` is running (`systemctl start buildkit`).

## Migration from Docker to containerd/nerdctl

1. **Export Docker images**: `docker save -o images.tar $(docker images -q)`
2. **Install containerd + nerdctl** (use full bundle for simplicity).
3. **Load images**: `nerdctl load -i images.tar`
4. **Update scripts**: Replace `docker` with `nerdctl` (or alias).
5. **Migrate compose files**: `nerdctl compose up -d` works with existing YAML.
6. **Update CI/CD pipelines**: Replace Docker CLI invocations.
7. **Validate**: Test networking, volumes, builds, and compose stacks.
8. **For Kubernetes**: Reconfigure kubelet to use containerd socket.

### Key differences to account for

- No Docker daemon socket (`/var/run/docker.sock`) — update any socket mounts
- Log drivers differ — nerdctl uses journald or json-file, not all Docker log drivers
- Docker Swarm features are not available; image storage locations differ
- CNI replaces libnetwork — review custom network configurations

## Common Anti-Patterns

- **Running nerdctl with sudo when rootless containerd is available.** Use rootless mode instead.
- **Mixing namespaces.** Images from `default` namespace are not visible in `k8s.io`.
- **Not running BuildKit daemon.** `nerdctl build` requires `buildkitd`.
- **Using ctr for daily operations.** Use nerdctl — ctr is for debugging only.
- **Inline registry mirrors in config.toml.** Use `hosts.toml` directory method instead.
- **Keeping Docker and containerd running simultaneously.** Wastes resources and causes confusion.
- **Ignoring SystemdCgroup setting.** Mismatched cgroup drivers cause sandbox creation failures.
- **Not configuring CNI plugins.** Container networking silently fails without them.
- **Using deprecated config version.** Set `version = 3` for containerd 2.x.
- **Skipping image conversion for lazy pulling.** Standard images don't benefit from stargz/nydus.

## Resources

### References

- [references/advanced-patterns.md](references/advanced-patterns.md) — Snapshotter plugins, content store, runtime handlers (runc, Kata, gVisor), image encryption, remote snapshotters (eStargz, Nydus, SOCI), shim API, multi-platform builds, GC tuning, NRI.
- [references/troubleshooting.md](references/troubleshooting.md) — Startup failures, pull errors, CNI problems, namespace conflicts, snapshotter corruption, memory issues, socket permissions, CRI/kubelet, BuildKit cache, rootless.
- [references/docker-migration.md](references/docker-migration.md) — Docker→containerd migration: CLI mapping, Dockerfile compat, compose differences, volume/network/auth migration, CI/CD updates, feature gaps.

### Scripts

- [scripts/containerd-install.sh](scripts/containerd-install.sh) — Install containerd + nerdctl + runc + CNI + BuildKit. Flags: `--rootless`.
- [scripts/containerd-health.sh](scripts/containerd-health.sh) — Health check across all components. Flags: `--json`, `--quiet`.
- [scripts/docker-to-nerdctl.sh](scripts/docker-to-nerdctl.sh) — Export Docker images/volumes/networks, import into containerd. Flags: `--dry-run`, `--namespace`, `--volumes`, `--networks`.

### Assets

- [assets/config.toml](assets/config.toml) — Production containerd config with runtime handlers, registry, snapshotter, GC, CRI.
- [assets/buildkitd.toml](assets/buildkitd.toml) — BuildKit daemon config with containerd worker, GC policies, multi-platform.
- [assets/cni-bridge.conflist](assets/cni-bridge.conflist) — CNI bridge network with portmap, firewall, host-local IPAM.
- [assets/nerdctl-compose.yml](assets/nerdctl-compose.yml) — Multi-service compose (web, API, Postgres, Redis, worker) with health checks.
