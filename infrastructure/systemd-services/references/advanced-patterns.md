# Advanced systemd Patterns

## Table of Contents

- [Socket Activation Deep Dive](#socket-activation-deep-dive)
- [Watchdog Integration](#watchdog-integration)
- [Cgroup Resource Controls](#cgroup-resource-controls)
- [Slices and Resource Hierarchies](#slices-and-resource-hierarchies)
- [Transient Units with systemd-run](#transient-units-with-systemd-run)
- [Portable Services](#portable-services)
- [systemd-nspawn Containers](#systemd-nspawn-containers)
- [systemd-resolved and networkd Integration](#systemd-resolved-and-networkd-integration)
- [Condition and Assert Directives](#condition-and-assert-directives)
- [Instantiated Unit Patterns](#instantiated-unit-patterns)

---

## Socket Activation Deep Dive

Socket activation lets systemd create listening sockets before launching services,
enabling on-demand startup and zero-downtime deployments.

### How It Works

1. systemd creates the socket (fd 3+) based on the `.socket` unit
2. When a connection arrives, systemd starts the matching `.service`
3. The service inherits the pre-opened file descriptor(s)
4. The service processes connections; systemd manages the lifecycle

### Accept Modes

**`Accept=no`** (default) — One long-running service handles all connections:

```ini
# /etc/systemd/system/myapp.socket
[Unit]
Description=MyApp Listening Socket

[Socket]
ListenStream=8080
# Queue up to 128 connections before service is ready
Backlog=128
# Pass socket ownership semantics
FileDescriptorName=http
# Bind to specific address
BindIPv6Only=both
NoDelay=yes

[Install]
WantedBy=sockets.target
```

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=MyApp Service
Requires=myapp.socket
After=myapp.socket

[Service]
Type=notify
ExecStart=/usr/bin/myapp
NonBlocking=yes
# Receive named fd
FileDescriptorStoreMax=1
```

**`Accept=yes`** — Spawn one instance per connection (inetd-style):

```ini
# /etc/systemd/system/myapp.socket
[Socket]
ListenStream=8080
Accept=yes
MaxConnections=100
MaxConnectionsPerSource=10

[Install]
WantedBy=sockets.target
```

```ini
# /etc/systemd/system/myapp@.service  (template required!)
[Service]
Type=simple
ExecStart=/usr/bin/myapp-handler
StandardInput=socket
StandardOutput=socket
StandardError=journal
```

### Multiple Sockets per Service

```ini
[Socket]
ListenStream=80
ListenStream=443
ListenStream=/run/myapp.sock
FileDescriptorName=http
```

Use `sd_listen_fds_with_names()` or `$LISTEN_FDNAMES` to identify which fd is which.

### Application-Side Integration

**Python:**
```python
import socket, os
# fd 3 is the first passed socket
LISTEN_FDS_START = 3
n_fds = int(os.environ.get('LISTEN_FDS', 0))
if n_fds > 0:
    sock = socket.fromfd(LISTEN_FDS_START, socket.AF_INET, socket.SOCK_STREAM)
```

**Go:**
```go
import "github.com/coreos/go-systemd/v22/activation"
listeners, _ := activation.Listeners()
http.Serve(listeners[0], handler)
```

**Node.js:**
```javascript
const fd = parseInt(process.env.LISTEN_FDS) > 0 ? 3 : null;
if (fd) {
  server.listen({ fd });
}
```

### Zero-Downtime Deployment

1. Socket remains open during service restart
2. Connections queue in the kernel backlog
3. New service instance picks up the existing socket

```bash
# Socket stays active, service restarts cleanly
systemctl restart myapp.service
# Verify socket is still listening
ss -tlnp | grep 8080
```

---

## Watchdog Integration

### WatchdogSec and sd_notify

The watchdog monitors service liveness. The service must periodically send heartbeats.

```ini
[Service]
Type=notify
WatchdogSec=30
# What to do on watchdog timeout
Restart=on-watchdog
# Optional: action when restart limit exceeded
StartLimitAction=reboot-force
```

### sd_notify Messages

| Message | Purpose |
|---------|---------|
| `READY=1` | Service is fully started |
| `WATCHDOG=1` | Heartbeat ping |
| `WATCHDOG=trigger` | Force immediate watchdog action |
| `RELOADING=1` | About to reload config |
| `STOPPING=1` | Beginning shutdown |
| `STATUS=Processing requests...` | Free-form status text |
| `MAINPID=<pid>` | Update main PID after fork |
| `ERRNO=<errno>` | Report errno for failure diagnosis |
| `EXTEND_TIMEOUT_USEC=<usec>` | Extend startup/stop timeout |

### Implementation Examples

**Python:**
```python
import systemd.daemon
import time, threading

systemd.daemon.notify('READY=1')

def watchdog_loop():
    interval = float(os.environ.get('WATCHDOG_USEC', 30000000)) / 1000000 / 2
    while True:
        if health_check_passes():
            systemd.daemon.notify('WATCHDOG=1')
        time.sleep(interval)

threading.Thread(target=watchdog_loop, daemon=True).start()
```

**C:**
```c
#include <systemd/sd-daemon.h>

sd_notify(0, "READY=1");
// In main loop:
sd_notify(0, "WATCHDOG=1");
// On reload:
sd_notify(0, "RELOADING=1");
// After reload complete:
sd_notify(0, "READY=1");
```

**Shell wrapper** (when app doesn't support sd_notify):
```ini
[Service]
Type=notify
ExecStart=/usr/local/bin/watchdog-wrapper.sh /usr/bin/myapp
NotifyAccess=all
```

```bash
#!/bin/bash
"$@" &
APP_PID=$!
systemd-notify --ready
WATCHDOG_USEC=${WATCHDOG_USEC:-30000000}
INTERVAL=$(( WATCHDOG_USEC / 2000000 ))
while kill -0 "$APP_PID" 2>/dev/null; do
    if curl -sf http://localhost:8080/health >/dev/null; then
        systemd-notify --status="healthy" WATCHDOG=1
    fi
    sleep "$INTERVAL"
done
wait "$APP_PID"
```

---

## Cgroup Resource Controls

### CPU Controls

```ini
[Service]
# Proportional weight (1-10000, default 100)
CPUWeight=500
# Idle weight (used only when system is idle)
StartupCPUWeight=200
# Hard limit as percentage of total CPU (100% = 1 core)
CPUQuota=200%
# Pin to specific CPUs
AllowedCPUs=0-3
# NUMA nodes
AllowedMemoryNodes=0
```

### Memory Controls

```ini
[Service]
# Hard limit — process is OOM-killed above this
MemoryMax=1G
# Soft limit — kernel reclaims aggressively above this
MemoryHigh=800M
# Memory reservation — guaranteed minimum
MemoryLow=256M
# Minimum guaranteed (stronger than MemoryLow)
MemoryMin=128M
# Swap hard limit
MemorySwapMax=0
# Startup variants (apply only during startup)
StartupMemoryHigh=1500M
StartupMemoryMax=2G
```

### I/O Controls

```ini
[Service]
# Proportional weight (1-10000, default 100)
IOWeight=200
StartupIOWeight=50
# Per-device bandwidth limits
IOReadBandwidthMax=/dev/sda 100M
IOWriteBandwidthMax=/dev/sda 50M
# IOPS limits
IOReadIOPSMax=/dev/sda 1000
IOWriteIOPSMax=/dev/sda 500
# Latency target
IODeviceLatencyTargetSec=/dev/sda 25ms
```

### Task and File Limits

```ini
[Service]
# Maximum number of processes/threads (fork bomb protection)
TasksMax=512
# File descriptor limit
LimitNOFILE=65536
# Address space limit
LimitAS=4G
# Core dump size (0 = disabled)
LimitCORE=0
# Max file size
LimitFSIZE=2G
```

---

## Slices and Resource Hierarchies

Slices provide hierarchical resource grouping. All services live in a slice tree:

```
-.slice
├── system.slice        (system services, default)
├── user.slice          (user sessions)
│   ├── user-1000.slice
│   └── user-1001.slice
├── machine.slice       (VMs and containers)
└── mycompany.slice     (custom)
    ├── mycompany-frontend.slice
    └── mycompany-backend.slice
```

### Custom Slice Definition

```ini
# /etc/systemd/system/mycompany.slice
[Unit]
Description=MyCompany Application Slice

[Slice]
CPUWeight=200
MemoryMax=8G
MemoryHigh=6G
TasksMax=4096
```

```ini
# /etc/systemd/system/mycompany-frontend.slice
[Unit]
Description=Frontend Services
Requires=mycompany.slice
Before=mycompany.slice

[Slice]
CPUWeight=300
MemoryMax=4G
```

### Assigning Services to Slices

```ini
[Service]
Slice=mycompany-frontend.slice
```

### Inspecting Slice Hierarchy

```bash
systemd-cgls                              # Tree view of all cgroups
systemd-cgtop                             # Top-like resource usage per cgroup
systemctl show mycompany.slice -p CPUUsageNSec -p MemoryCurrent
```

---

## Transient Units with systemd-run

Run ad-hoc commands as systemd units with full resource control and logging.

### Basic Usage

```bash
# Simple one-shot
systemd-run --unit=my-backup tar czf /backup/data.tar.gz /var/data

# With resource limits
systemd-run --unit=heavy-task \
  --property=CPUQuota=50% \
  --property=MemoryMax=512M \
  --property=IOWeight=50 \
  /usr/local/bin/heavy-compute

# Interactive (PTY attached)
systemd-run --pty --unit=debug-shell /bin/bash

# In a specific slice
systemd-run --slice=batch.slice --unit=etl-job /usr/local/bin/etl.sh

# As a specific user
systemd-run --uid=appuser --gid=appgroup /usr/local/bin/task

# With environment variables
systemd-run --setenv=NODE_ENV=production --unit=app node /app/server.js

# Timer-based (run once in 30 minutes)
systemd-run --on-active=30min /usr/local/bin/cleanup.sh

# Calendar-based transient timer
systemd-run --on-calendar="*-*-* 03:00:00" --timer-property=Persistent=true \
  /usr/local/bin/nightly-job.sh
```

### Scope Units (for Existing Processes)

```bash
# Wrap running PID in a scope with resource limits
systemd-run --scope --property=MemoryMax=1G -p CPUQuota=100% \
  /usr/local/bin/app
```

### Monitoring Transient Units

```bash
systemctl status my-backup.service
journalctl -u my-backup.service
systemctl list-units --type=service 'run-*'  # Auto-named units
```

---

## Portable Services

Self-contained service images that attach/detach without modifying the host system.

### Creating a Portable Service Image

```bash
# 1. Build a directory tree with os-release and unit files
mkdir -p /tmp/myservice/{usr/lib/systemd/system,usr/local/bin,etc}

cat > /tmp/myservice/etc/os-release << 'EOF'
ID=myservice
VERSION_ID=1.0
EOF

cat > /tmp/myservice/usr/lib/systemd/system/myservice.service << 'EOF'
[Unit]
Description=My Portable Service

[Service]
Type=simple
ExecStart=/usr/local/bin/myservice
DynamicUser=yes
StateDirectory=myservice
EOF

cp /path/to/binary /tmp/myservice/usr/local/bin/myservice

# 2. Create squashfs image
mksquashfs /tmp/myservice myservice_1.0.raw -noappend

# 3. Attach to host
portablectl attach myservice_1.0.raw --profile=default --enable --now

# 4. Manage as a normal service
systemctl status myservice.service

# 5. Update: reattach new version
portablectl reattach myservice_2.0.raw

# 6. Remove
portablectl detach myservice_1.0.raw
```

### Security Profiles

Portable services support profiles: `default`, `strict`, `trusted`, `nonetwork`.

```bash
portablectl attach myimage.raw --profile=strict
```

---

## systemd-nspawn Containers

Lightweight OS-level container runtime integrated with systemd.

### Basic Usage

```bash
# Boot a container from a directory
systemd-nspawn -D /var/lib/machines/mycontainer --boot

# Boot from an image
systemd-nspawn -i /var/lib/machines/mycontainer.raw --boot

# Network isolation
systemd-nspawn -D /path --network-veth --boot

# Bind mount host directory
systemd-nspawn -D /path --bind=/host/data:/container/data --boot

# Resource limits via machinectl
machinectl set-limit mycontainer 2G
```

### Managing as a Service

```ini
# /etc/systemd/system/systemd-nspawn@mycontainer.service.d/override.conf
[Service]
Environment=SYSTEMD_NSPAWN_LOCK=0
```

```bash
machinectl enable mycontainer
machinectl start mycontainer
machinectl status mycontainer
machinectl shell mycontainer /bin/bash
```

### Container Settings

```ini
# /etc/systemd/nspawn/mycontainer.nspawn
[Exec]
Boot=yes
Parameters=--user=appuser

[Files]
Bind=/host/data:/data
BindReadOnly=/host/config:/etc/app/config

[Network]
Zone=containers
Port=tcp:8080:80
```

---

## systemd-resolved and networkd Integration

### Configuring systemd-resolved

```ini
# /etc/systemd/resolved.conf
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=9.9.9.9
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
Cache=yes
DNSStubListener=yes
```

```bash
# Link stub resolver
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable --now systemd-resolved
```

### Per-Interface DNS with networkd

```ini
# /etc/systemd/network/10-eth0.network
[Match]
Name=eth0

[Network]
DHCP=yes
DNS=10.0.0.53
Domains=~corp.example.com    # ~ = routing domain (split DNS)

[DHCPv4]
UseDNS=false                 # Ignore DHCP-provided DNS
```

### Diagnostics

```bash
resolvectl status                    # Per-link DNS config
resolvectl query example.com         # Test resolution
resolvectl dns eth0 10.0.0.53        # Set DNS per link
resolvectl flush-caches              # Clear DNS cache
resolvectl statistics                # Cache hit/miss stats
```

---

## Condition and Assert Directives

Conditions are silent skips; asserts cause hard failures.

### Complete Condition Reference

| Directive | Check |
|-----------|-------|
| `ConditionPathExists=` | File/dir exists (`!` prefix = must NOT exist) |
| `ConditionPathExistsGlob=` | Glob pattern matches any file |
| `ConditionPathIsDirectory=` | Path is a directory |
| `ConditionPathIsSymbolicLink=` | Path is a symlink |
| `ConditionPathIsMountPoint=` | Path is a mount point |
| `ConditionPathIsReadWrite=` | Path is on a read-write filesystem |
| `ConditionPathIsEncrypted=` | Path is on an encrypted block device |
| `ConditionDirectoryNotEmpty=` | Directory is non-empty |
| `ConditionFileNotEmpty=` | File exists and is non-empty |
| `ConditionFileIsExecutable=` | File is executable |
| `ConditionACPower=true` | System is on AC power |
| `ConditionVirtualization=` | Running in VM/container (`!container`) |
| `ConditionHost=` | Hostname matches |
| `ConditionKernelCommandLine=` | Kernel cmdline contains string |
| `ConditionKernelVersion=` | Kernel version comparison (`>=5.10`) |
| `ConditionArchitecture=` | CPU architecture (`x86-64`, `arm64`) |
| `ConditionFirmware=` | Firmware type (`uefi`, `device-tree`) |
| `ConditionSecurity=` | Security framework active (`selinux`, `apparmor`) |
| `ConditionCapability=` | Running process has capability |
| `ConditionUser=` | Running as specific user |
| `ConditionGroup=` | Running as specific group |
| `ConditionMemory=` | System memory comparison (`>=4G`) |
| `ConditionCPUs=` | CPU count comparison (`>=4`) |
| `ConditionCPUFeature=` | CPU feature present (`rdrand`) |
| `ConditionEnvironment=` | Environment variable is set |
| `ConditionFirstBoot=` | System's first boot |

### Practical Examples

```ini
[Unit]
# Only start on physical servers with enough resources
ConditionVirtualization=no
ConditionMemory=>=8G
ConditionCPUs=>=4

# Only on UEFI systems
ConditionFirmware=uefi

# Only when config exists
ConditionPathExists=/etc/myapp/config.yaml
ConditionFileNotEmpty=/etc/myapp/license.key

# Only on AC power (laptops)
ConditionACPower=true

# Not in containers
ConditionVirtualization=!container
```

### Assert vs Condition

```ini
[Unit]
# Condition: silent skip if not met (unit shows "inactive")
ConditionPathExists=/etc/myapp/optional.conf

# Assert: hard failure if not met (unit shows "failed")
AssertPathExists=/etc/myapp/required.conf
```

---

## Instantiated Unit Patterns

### Advanced Template Patterns

**Multi-port web server:**
```ini
# /etc/systemd/system/webserver@.service
[Unit]
Description=Web Server on port %i
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/webserver --port %i --config /etc/webserver/%i.conf
User=www-data
EnvironmentFile=-/etc/webserver/%i.env
Restart=on-failure
RestartSec=5

# Security (inherited by all instances)
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/log/webserver

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now webserver@8080.service
systemctl enable --now webserver@8081.service
systemctl enable --now webserver@8082.service
```

**Database replica set:**
```ini
# /etc/systemd/system/db-replica@.service
[Unit]
Description=Database Replica %i
After=network-online.target db-primary.service
PartOf=db-cluster.target

[Service]
Type=notify
ExecStart=/usr/bin/db --replica --id=%i --data-dir=/var/lib/db/%i
User=dbuser
StateDirectory=db/%i
MemoryMax=2G
CPUQuota=100%

[Install]
WantedBy=db-cluster.target
```

### Grouping Instances with Targets

```ini
# /etc/systemd/system/db-cluster.target
[Unit]
Description=Database Cluster
Wants=db-replica@1.service db-replica@2.service db-replica@3.service
After=db-replica@1.service db-replica@2.service db-replica@3.service

[Install]
WantedBy=multi-user.target
```

```bash
# Start entire cluster
systemctl start db-cluster.target
# Stop entire cluster
systemctl stop db-cluster.target
```

### Template Specifiers Reference

| Specifier | Meaning | Example |
|-----------|---------|---------|
| `%i` | Instance name (escaped) | `8080` |
| `%I` | Instance name (unescaped) | `8080` |
| `%p` | Prefix (unit name before @) | `webserver` |
| `%P` | Prefix (unescaped) | `webserver` |
| `%n` | Full unit name | `webserver@8080.service` |
| `%N` | Full unit name (unescaped) | `webserver@8080.service` |
| `%f` | Instance as path (unescaped, / prefixed) | `/8080` |
| `%H` | Hostname | `server01` |
| `%m` | Machine ID | `a1b2c3...` |
| `%b` | Boot ID | `x9y8z7...` |
| `%t` | Runtime directory | `/run` (system), `$XDG_RUNTIME_DIR` (user) |
| `%S` | State directory | `/var/lib` (system) |
| `%C` | Cache directory | `/var/cache` (system) |
| `%L` | Logs directory | `/var/log` (system) |
