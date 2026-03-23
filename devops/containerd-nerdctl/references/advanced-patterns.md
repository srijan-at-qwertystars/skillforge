# Advanced containerd Patterns

## Table of Contents

- [Custom Snapshotter Plugins](#custom-snapshotter-plugins)
- [Content Store Internals](#content-store-internals)
- [Runtime Handlers](#runtime-handlers)
- [Image Encryption](#image-encryption)
- [Remote Snapshotters](#remote-snapshotters)
- [Containerd Shim API](#containerd-shim-api)
- [Multi-Platform Builds](#multi-platform-builds)
- [Garbage Collection Tuning](#garbage-collection-tuning)
- [NRI Plugins](#nri-plugins)

---

## Custom Snapshotter Plugins

Snapshotters manage filesystem layers for container images. containerd supports pluggable snapshotters via the snapshot plugin interface.

### Built-in Snapshotters

| Snapshotter | Use Case | Filesystem |
|---|---|---|
| overlayfs | Default, general-purpose | OverlayFS |
| native | Fallback when overlayfs unavailable | Copy-based |
| btrfs | Btrfs volumes, snapshot-efficient | Btrfs |
| zfs | ZFS volumes | ZFS |
| devmapper | Devicemapper thin-provisioning | Devicemapper |

### Writing a Custom Snapshotter

Custom snapshotters implement the `snapshots.Snapshotter` Go interface:

```go
type Snapshotter interface {
    Stat(ctx context.Context, key string) (Info, error)
    Update(ctx context.Context, info Info, fieldpaths ...string) (Info, error)
    Usage(ctx context.Context, key string) (Usage, error)
    Mounts(ctx context.Context, key string) ([]mount.Mount, error)
    Prepare(ctx context.Context, key, parent string, opts ...Opt) ([]mount.Mount, error)
    View(ctx context.Context, key, parent string, opts ...Opt) ([]mount.Mount, error)
    Commit(ctx context.Context, name, key string, opts ...Opt) error
    Remove(ctx context.Context, key string) error
    Walk(ctx context.Context, fn WalkFunc, filters ...string) error
    Close() error
}
```

### Proxy Snapshotter (out-of-process)

Proxy snapshotters run as separate processes communicating via gRPC. Register them in `config.toml`:

```toml
[proxy_plugins.mysnapshotter]
  type = "snapshot"
  address = "/run/mysnapshotter/mysnapshotter.sock"
```

Key considerations:
- Proxy snapshotters must start before containerd
- The socket must exist when containerd starts, or configure `[timeouts]` to allow startup delay
- Use `ctr plugins ls | grep snapshot` to verify registration

### Devmapper Snapshotter Configuration

Useful for production workloads requiring thin provisioning:

```toml
[plugins."io.containerd.snapshotter.v1.devmapper"]
  root_path = "/var/lib/containerd/devmapper"
  pool_name = "containerd-pool"
  base_image_size = "10GB"
  async_remove = false
  discard_blocks = true
```

Setup the thin pool before enabling:

```bash
sudo pvcreate /dev/sdb
sudo vgcreate containerd-vg /dev/sdb
sudo lvcreate --thin-pool containerd-pool -L 100G containerd-vg
```

---

## Content Store Internals

The content store manages immutable blobs (image layers, manifests, configs) addressed by digest.

### Content Store Location

Default: `/var/lib/containerd/io.containerd.content.v1.content/`

```
blobs/
  sha256/
    <digest1>  # image manifest
    <digest2>  # config blob
    <digest3>  # layer tar.gz
ingest/
  <ref>/       # in-progress writes
```

### Content Store Operations

```bash
# List all content
ctr content ls

# Fetch specific content by digest
ctr content get sha256:abc123...

# Inspect an image manifest
ctr content get sha256:<manifest-digest> | jq .

# Ingest content from a file
ctr content ingest --ref my-blob < data.tar.gz

# Delete specific content
ctr content delete sha256:abc123...

# Show active ingests (in-progress downloads)
ctr content active
```

### Programmatic Access (Go)

```go
import "github.com/containerd/containerd/v2/core/content"

// Read content by digest
ra, err := store.ReaderAt(ctx, ocispec.Descriptor{Digest: dgst})
defer ra.Close()

// Write content
writer, err := store.Writer(ctx, content.WithRef("my-ref"))
defer writer.Close()
_, err = writer.Write(data)
err = writer.Commit(ctx, int64(len(data)), dgst)
```

### Content Store Garbage Collection

Unreferenced blobs are cleaned up by GC. Content pinned by image references or leases is protected.

```bash
# Manually trigger garbage collection
ctr content prune

# List leases that protect content
ctr leases ls
```

---

## Runtime Handlers

containerd supports multiple OCI runtimes via runtime handlers. Configure alternate runtimes for workloads requiring different isolation levels.

### runc (Default)

Standard OCI runtime using Linux namespaces and cgroups:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
  BinaryName = "/usr/local/sbin/runc"
```

### Kata Containers (VM-based isolation)

Kata runs containers inside lightweight VMs for stronger isolation:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = true

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata.options]
  ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration.toml"
```

```bash
# Install Kata
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kata-containers/kata-containers/main/utils/kata-manager.sh) install"

# Test with nerdctl
nerdctl run --runtime kata-runtime -it --rm alpine uname -r

# In Kubernetes — use RuntimeClass
cat <<EOF | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
EOF
```

### gVisor (user-space kernel)

gVisor intercepts syscalls in user space for sandboxed execution:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
  TypeUrl = "io.containerd.runsc.v1.options"
```

```bash
# Install gVisor
curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | sudo tee /etc/apt/sources.list.d/gvisor.list
sudo apt-get update && sudo apt-get install -y runsc

# Test with nerdctl
nerdctl run --runtime io.containerd.runsc.v1 -it --rm alpine echo "Hello from gVisor"
```

### Choosing a Runtime

| Runtime | Isolation | Performance | Compatibility | Use Case |
|---|---|---|---|---|
| runc | Namespace/cgroup | Native | Full | General workloads |
| Kata | VM-level | ~5-10% overhead | Most workloads | Multi-tenant, untrusted code |
| gVisor | User-space kernel | ~15-30% overhead | Limited syscalls | Untrusted code, security-critical |

### Setting Default Runtime

```toml
[plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "runc"
```

---

## Image Encryption

containerd supports OCI image encryption via imgcrypt/OCIcrypt for protecting sensitive container images at rest.

### Setup imgcrypt

```bash
# Install imgcrypt
go install github.com/containerd/imgcrypt/cmd/ctd-decoder@latest

# Register the stream processor in config.toml
[stream_processors."io.containerd.ocicrypt.decoder.v1.tar"]
  accepts = ["application/vnd.oci.image.layer.v1.tar+encrypted"]
  returns = "application/vnd.oci.image.layer.v1.tar"
  path = "/usr/local/bin/ctd-decoder"

[stream_processors."io.containerd.ocicrypt.decoder.v1.tar.gzip"]
  accepts = ["application/vnd.oci.image.layer.v1.tar+gzip+encrypted"]
  returns = "application/vnd.oci.image.layer.v1.tar+gzip"
  path = "/usr/local/bin/ctd-decoder"
```

### JWE Encryption (Asymmetric)

```bash
# Generate key pair
openssl genrsa -out mykey.pem 4096
openssl rsa -in mykey.pem -pubout -out mypubkey.pem

# Encrypt image
nerdctl image encrypt --recipient jwe:mypubkey.pem sourceimage:tag encryptedimage:tag

# Push encrypted image
nerdctl push encryptedimage:tag

# Decrypt and run (requires private key)
nerdctl run --decryption-keys-path /path/to/keys/ encryptedimage:tag
```

### PKCS7 Encryption

```bash
# Encrypt with x509 certificate
nerdctl image encrypt --recipient pkcs7:mycert.pem sourceimage:tag encryptedimage:tag

# Decrypt
nerdctl run --decryption-keys-path /path/to/certs/ encryptedimage:tag
```

### Key Management Best Practices

- Store decryption keys in hardware security modules (HSMs) or secret managers
- Rotate encryption keys periodically
- Use separate keys per environment (dev, staging, prod)
- Audit key access via containerd logs
- Combine with image signing (cosign) for full supply chain security

---

## Remote Snapshotters

Remote snapshotters enable lazy pulling — containers start before the full image is downloaded by fetching layers on demand.

### eStargz (Seekable tar.gz)

eStargz reformats tar.gz layers to allow random access:

```bash
# Install stargz-snapshotter
wget https://github.com/containerd/stargz-snapshotter/releases/latest/download/stargz-snapshotter-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf stargz-snapshotter-linux-amd64.tar.gz
sudo systemctl enable --now stargz-snapshotter

# Convert image to eStargz
nerdctl image convert --estargz --oci sourceimage:tag sourceimage:estargz
nerdctl push sourceimage:estargz

# Run with lazy pulling
nerdctl --snapshotter stargz run sourceimage:estargz
```

Configuration in `config.toml`:

```toml
[proxy_plugins.stargz]
  type = "snapshot"
  address = "/run/containerd-stargz-grpc/containerd-stargz-grpc.sock"
```

Stargz snapshotter config (`/etc/containerd-stargz-grpc/config.toml`):

```toml
[cri_keychain]
  enable_keychain = true
  image_service_path = "/run/containerd/containerd.sock"

[[resolver.host."registry-1.docker.io".mirrors]]
  host = "mirror.example.com"
```

### Nydus

Nydus provides a filesystem-level lazy loading approach with better deduplication:

```bash
# Install nydus-snapshotter
wget https://github.com/containerd/nydus-snapshotter/releases/latest/download/nydus-snapshotter-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf nydus-snapshotter-linux-amd64.tar.gz
sudo systemctl enable --now nydus-snapshotter

# Convert image to nydus format
nerdctl image convert --nydus sourceimage:tag sourceimage:nydus
nerdctl push sourceimage:nydus

# Run with lazy pulling
nerdctl --snapshotter nydus run sourceimage:nydus
```

Configuration in `config.toml`:

```toml
[proxy_plugins.nydus]
  type = "snapshot"
  address = "/run/nydus-snapshotter/nydus-snapshotter.sock"
```

### SOCI (Seekable OCI)

SOCI (by AWS) enables lazy loading without converting images — it creates a separate index:

```bash
# Install SOCI snapshotter
wget https://github.com/awslabs/soci-snapshotter/releases/latest/download/soci-snapshotter-grpc-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf soci-snapshotter-grpc-linux-amd64.tar.gz
sudo systemctl enable --now soci-snapshotter-grpc

# Create SOCI index for existing image (no conversion needed)
sudo soci create myimage:tag
sudo soci push --user <username> myregistry.io/myimage:tag

# Run with SOCI lazy pulling
nerdctl --snapshotter soci run myregistry.io/myimage:tag
```

Configuration in `config.toml`:

```toml
[proxy_plugins.soci]
  type = "snapshot"
  address = "/run/soci-snapshotter-grpc/soci-snapshotter-grpc.sock"
```

### Comparison of Remote Snapshotters

| Feature | eStargz | Nydus | SOCI |
|---|---|---|---|
| Requires image conversion | Yes | Yes | No (index only) |
| Startup time reduction | 60-80% | 60-80% | 40-60% |
| Deduplication | Layer-level | Block-level | Layer-level |
| Prefetching | Landmark-based | On-demand | Span-based |
| Registry compatibility | OCI registries | OCI registries | OCI + referrers API |
| Maintained by | containerd | CNCF/Dragonfly | AWS |

---

## Containerd Shim API

The shim is the process that manages a container's lifecycle on behalf of containerd. Each container gets its own shim process.

### Shim v2 Architecture

```
containerd daemon
  └── shim v2 process (per container)
        └── runc / kata / runsc
              └── container process
```

### Writing a Custom Shim

A shim v2 binary must implement the `task.TaskService` gRPC interface:

```go
package main

import (
    "github.com/containerd/containerd/v2/pkg/shim"
    taskAPI "github.com/containerd/containerd/v2/api/runtime/task/v3"
)

type myShim struct{}

func (s *myShim) Create(ctx context.Context, r *taskAPI.CreateTaskRequest) (*taskAPI.CreateTaskResponse, error) {
    // Initialize container
}

func (s *myShim) Start(ctx context.Context, r *taskAPI.StartRequest) (*taskAPI.StartResponse, error) {
    // Start container process
}

func (s *myShim) Delete(ctx context.Context, r *taskAPI.DeleteRequest) (*taskAPI.DeleteResponse, error) {
    // Clean up container
}

func (s *myShim) Kill(ctx context.Context, r *taskAPI.KillRequest) (*emptypb.Empty, error) {
    // Send signal to container
}

// ... implement remaining methods: State, Exec, Pids, Pause, Resume, Checkpoint, etc.

func main() {
    shim.Run("io.containerd.myshim.v1", &myShim{})
}
```

### Shim Binary Naming Convention

Binary name follows the pattern: `containerd-shim-<name>-<version>`

Example: `containerd-shim-myshim-v1` for runtime type `io.containerd.myshim.v1`

The binary must be in `$PATH`. containerd resolves the shim binary from the runtime type.

### Shim Lifecycle

1. containerd starts the shim binary via `containerd-shim-<type>-<version> start`
2. Shim returns its address (unix socket) to containerd
3. containerd communicates with shim via gRPC
4. When container exits, shim reports exit status
5. containerd calls `Delete` to clean up the shim

---

## Multi-Platform Builds

nerdctl supports multi-platform builds via BuildKit's cross-compilation and QEMU emulation.

### Setup QEMU for Cross-Platform Builds

```bash
# Install QEMU static binaries
sudo apt-get install qemu-user-static binfmt-support
# Or use the tonistiigi/binfmt image
nerdctl run --privileged --rm tonistiigi/binfmt --install all

# Verify registered platforms
ls /proc/sys/fs/binfmt_misc/
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
```

### Building Multi-Platform Images

```bash
# Build for multiple platforms simultaneously
nerdctl build --platform linux/amd64,linux/arm64,linux/arm/v7 -t myapp:latest .

# Push multi-platform manifest
nerdctl push --all-platforms myapp:latest

# Build and push in one step
nerdctl build --platform linux/amd64,linux/arm64 -t myregistry.io/myapp:latest --push .

# Inspect manifest list
nerdctl manifest inspect myregistry.io/myapp:latest
```

### Dockerfile Best Practices for Multi-Platform

```dockerfile
# Use multi-platform base images
FROM --platform=$BUILDPLATFORM golang:1.22 AS builder

ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH

# Cross-compile using Go's built-in cross-compilation
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /app .

FROM alpine:3.20
COPY --from=builder /app /app
ENTRYPOINT ["/app"]
```

### BuildKit Worker Configuration for Multi-Platform

```toml
# buildkitd.toml
[worker.oci]
  platforms = ["linux/amd64", "linux/arm64", "linux/arm/v7"]
  max-parallelism = 4

[worker.containerd]
  platforms = ["linux/amd64", "linux/arm64"]
```

---

## Garbage Collection Tuning

containerd's garbage collector removes unreferenced content and snapshots. Tuning GC is critical for production nodes.

### GC Configuration

```toml
# config.toml — scheduling section
[plugins."io.containerd.gc.v1.scheduler"]
  pause_threshold = 0.02
  deletion_threshold = 0
  mutation_threshold = 100
  schedule_delay = "0s"
  startup_delay = "100ms"
```

### GC Labels and Policies

Use labels to control GC behavior:

```go
// Pin content to prevent GC
_, err = client.ImageService().Create(ctx, images.Image{
    Name: "pinned-image",
    Target: desc,
    Labels: map[string]string{
        "containerd.io/gc.root": time.Now().String(),
    },
})
```

### Leases

Leases protect content from GC during operations:

```bash
# List active leases
ctr leases ls

# Create a lease
ctr leases create --id my-lease --expiry 24h

# Delete a lease (allows GC to collect protected content)
ctr leases delete my-lease
```

### GC Triggers

GC runs automatically when:
- Mutation count exceeds `mutation_threshold`
- An image is deleted
- A snapshot is removed

Manual trigger:

```bash
# Force garbage collection
ctr content prune
ctr snapshots rm <key>

# For Kubernetes CRI — garbage collection is managed by kubelet
# Configure in kubelet: --image-gc-high-threshold=85 --image-gc-low-threshold=80
```

### Monitoring GC

```bash
# Check content store size
du -sh /var/lib/containerd/io.containerd.content.v1.content/

# Check snapshot size
du -sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/

# Monitor via containerd metrics (Prometheus)
# containerd exposes metrics on :10257/v1/metrics by default
curl -s http://localhost:10257/v1/metrics | grep gc
```

### Production GC Recommendations

- Set `mutation_threshold` based on workload churn (higher for CI nodes)
- Monitor content store size with alerts
- Use `schedule_delay` to batch GC operations during low-traffic periods
- For Kubernetes: let kubelet manage image GC, but monitor containerd content store independently
- Set lease expiry for long-running builds to prevent premature GC

---

## NRI Plugins

NRI (Node Resource Interface) is a framework for hooking into container lifecycle events at the node level. It enables plugins to modify container resources, OCI spec, and environment without modifying the container runtime.

### NRI Architecture

```
kubelet → containerd → NRI plugin(s)
                         ├── Resource allocation
                         ├── Device injection
                         ├── Topology-aware scheduling
                         └── OCI spec modification
```

### Enabling NRI in containerd

```toml
# config.toml
[plugins."io.containerd.nri.v1.nri"]
  disable = false
  disable_connections = false
  plugin_config_path = "/etc/nri/conf.d"
  plugin_path = "/opt/nri/plugins"
  plugin_registration_timeout = "5s"
  plugin_request_timeout = "2s"
  socket_path = "/var/run/nri/nri.sock"
```

### Writing an NRI Plugin (Go)

```go
package main

import (
    "context"
    "github.com/containerd/nri/pkg/api"
    "github.com/containerd/nri/pkg/stub"
)

type myPlugin struct {
    stub stub.Stub
}

func (p *myPlugin) Configure(ctx context.Context, config, runtime, version string) (stub.EventMask, error) {
    return api.MustParseEventMask("RunPodSandbox,CreateContainer"), nil
}

func (p *myPlugin) CreateContainer(ctx context.Context, pod *api.PodSandbox, ctr *api.Container) (*api.ContainerAdjustment, []*api.ContainerUpdate, error) {
    adjust := &api.ContainerAdjustment{}
    // Inject environment variable
    adjust.AddEnv("INJECTED_BY_NRI", "true")
    // Add annotation
    adjust.AddAnnotation("nri.example.com/processed", "true")
    // Modify resources
    adjust.SetLinuxCPUShares(512)
    adjust.SetLinuxMemoryLimit(256 * 1024 * 1024) // 256Mi
    return adjust, nil, nil
}

func main() {
    p := &myPlugin{}
    s, _ := stub.New(p, stub.WithPluginName("my-plugin"), stub.WithPluginIdx("00"))
    p.stub = s
    _ = s.Run(context.Background())
}
```

### NRI Plugin Types

| Type | Purpose | Example |
|---|---|---|
| Resource allocation | CPU, memory, device assignment | Topology-aware scheduling |
| Device injection | GPU, FPGA, SR-IOV | Device plugin replacement |
| Security | OCI spec hardening | Seccomp profile injection |
| Monitoring | Event logging, metrics | Container lifecycle auditing |
| Networking | Network namespace setup | Custom CNI chain integration |

### Pre-built NRI Plugins

```bash
# Install topology-aware resource policy
git clone https://github.com/containers/nri-plugins.git
cd nri-plugins
make build-topology-aware-policy
sudo cp build/bin/nri-resource-policy-topology-aware /opt/nri/plugins/

# Install memory-qos plugin
make build-memoryqos
sudo cp build/bin/nri-memoryqos /opt/nri/plugins/
```

### NRI Plugin Configuration

Place plugin configs in `/etc/nri/conf.d/`:

```yaml
# /etc/nri/conf.d/00-topology-aware.conf
policy:
  Active: topology-aware
  ReservedResources:
    CPU: 500m
  AvailableResources:
    CPU: system
instrumentation:
  ReportPeriod: 60s
```

### Debugging NRI

```bash
# Check NRI socket
ls -la /var/run/nri/nri.sock

# Check registered plugins
journalctl -u containerd | grep -i nri

# Test plugin manually
/opt/nri/plugins/my-plugin --idx 00 --name my-plugin

# Monitor NRI events
journalctl -u containerd -f | grep "nri"
```
