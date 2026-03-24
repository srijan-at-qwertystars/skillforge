# systemd Security Hardening Reference

## Table of Contents

- [Security Assessment](#security-assessment)
- [Filesystem Protection](#filesystem-protection)
- [Device and Kernel Protection](#device-and-kernel-protection)
- [User and Privilege Controls](#user-and-privilege-controls)
- [Capability Management](#capability-management)
- [System Call Filtering](#system-call-filtering)
- [Namespace Isolation](#namespace-isolation)
- [Network Isolation](#network-isolation)
- [Miscellaneous Hardening](#miscellaneous-hardening)
- [Hardening Profiles by Use Case](#hardening-profiles-by-use-case)
- [Directive Quick Reference](#directive-quick-reference)

---

## Security Assessment

### systemd-analyze security

Audits a unit's security posture and assigns a score from 0.0 (fully hardened) to 10.0 (fully exposed).

```bash
# Audit a single service
systemd-analyze security myapp.service

# Audit all running services
systemd-analyze security

# JSON output for scripting
systemd-analyze security myapp.service --json=short

# Output example:
# → Overall exposure level for myapp.service: 9.6 UNSAFE 😨
#   NAME                          DESCRIPTION                    EXPOSURE
#   PrivateNetwork=               ...                            0.5
#   PrivateTmp=                   ...                            0.1
#   ...
```

### Interpreting Scores

| Score Range | Rating | Action |
|-------------|--------|--------|
| 0.0 – 2.0 | 🟢 OK | Well hardened |
| 2.1 – 4.0 | 🟡 MEDIUM | Acceptable for most workloads |
| 4.1 – 7.0 | 🟠 EXPOSED | Should harden further |
| 7.1 – 10.0 | 🔴 UNSAFE | Immediate attention needed |

**Goal:** Aim for ≤ 4.0 for production services. Each directive you add reduces the score.

---

## Filesystem Protection

### ProtectSystem

Controls read-only mounting of system directories.

| Value | Effect |
|-------|--------|
| `no` | No protection (default) |
| `yes` | `/usr` and `/boot` are read-only |
| `full` | `/usr`, `/boot`, and `/etc` are read-only |
| `strict` | Entire filesystem is read-only; use `ReadWritePaths=` for exceptions |

```ini
[Service]
ProtectSystem=strict
ReadWritePaths=/var/lib/myapp /var/log/myapp
ReadOnlyPaths=/etc/myapp
InaccessiblePaths=/etc/shadow /etc/gshadow
```

### ProtectHome

Controls access to user home directories.

| Value | Effect |
|-------|--------|
| `no` | Full access (default) |
| `yes` | `/home`, `/root`, `/run/user` are inaccessible |
| `read-only` | Mounted read-only |
| `tmpfs` | Empty tmpfs mounted over home directories |

```ini
[Service]
ProtectHome=yes
```

### PrivateTmp

Creates a private `/tmp` and `/var/tmp` for the service.

```ini
[Service]
PrivateTmp=yes
# Service sees its own empty /tmp, isolated from other processes
# Automatically cleaned up when service stops
```

### Directory Management Directives

Let systemd manage directories with correct ownership automatically:

```ini
[Service]
# systemd creates these directories owned by the service's User/Group
StateDirectory=myapp           # /var/lib/myapp
LogsDirectory=myapp            # /var/log/myapp
CacheDirectory=myapp           # /var/cache/myapp
ConfigurationDirectory=myapp   # /etc/myapp
RuntimeDirectory=myapp         # /run/myapp (tmpfs, cleaned on stop)
RuntimeDirectoryPreserve=yes   # Keep runtime dir across restarts

# Set permissions
StateDirectoryMode=0750
LogsDirectoryMode=0750
```

### Bind Mount Controls

```ini
[Service]
ProtectSystem=strict
# Allow writing to specific paths
ReadWritePaths=/var/lib/myapp /var/log/myapp
# Force read-only
ReadOnlyPaths=/etc/myapp /opt/shared-config
# Make paths invisible
InaccessiblePaths=/home /root /etc/shadow
# Overlay empty tmpfs (hides contents but path exists)
TemporaryFileSystem=/var:ro
BindPaths=/host/data:/container/data
BindReadOnlyPaths=/host/certs:/etc/ssl/certs
```

---

## Device and Kernel Protection

### PrivateDevices

```ini
[Service]
# Only exposes pseudo-devices: /dev/null, /dev/zero, /dev/full,
# /dev/random, /dev/urandom, /dev/tty
# Blocks access to physical hardware devices
PrivateDevices=yes
# Implicitly sets: DevicePolicy=closed
```

### ProtectKernelTunables

```ini
[Service]
# Mounts /proc/sys, /sys, /proc/sysrq-trigger,
# /proc/latency_stats, /proc/acpi, /proc/timer_stats,
# /proc/fs, /proc/irq as read-only
ProtectKernelTunables=yes
```

### ProtectKernelModules

```ini
[Service]
# Prevents loading/unloading kernel modules
# Removes CAP_SYS_MODULE from capability set
ProtectKernelModules=yes
```

### ProtectKernelLogs

```ini
[Service]
# Prevents access to kernel log ring buffer (/dev/kmsg, /proc/kmsg)
# Removes CAP_SYSLOG capability
ProtectKernelLogs=yes
```

### ProtectControlGroups

```ini
[Service]
# Mounts /sys/fs/cgroup as read-only
# Prevents service from modifying cgroup hierarchy
ProtectControlGroups=yes
```

### ProtectClock

```ini
[Service]
# Prevents setting hardware or system clock
# Removes CAP_SYS_TIME, CAP_WAKE_ALARM
ProtectClock=yes
```

### ProtectHostname

```ini
[Service]
# Prevents changing the system hostname
# Removes CAP_SYS_ADMIN for hostname-related syscalls
ProtectHostname=yes
```

### ProtectProc

```ini
[Service]
# Control /proc visibility
ProtectProc=invisible    # Hide other users' processes in /proc
# Options: default, invisible, noaccess, ptraceable
ProcSubset=pid           # Only expose /proc/pid (hide /proc/sys etc.)
# Options: all, pid
```

---

## User and Privilege Controls

### DynamicUser

```ini
[Service]
# Allocates an ephemeral UID/GID at runtime
# User/group created on start, removed on stop
# REQUIRES StateDirectory/LogsDirectory for persistent data
DynamicUser=yes
StateDirectory=myapp
LogsDirectory=myapp
CacheDirectory=myapp
```

**Limitations:** Cannot use with `User=` or `Group=`. Incompatible with services
that need stable UIDs across restarts (some databases).

### NoNewPrivileges

```ini
[Service]
# Prevents the process and all children from gaining new privileges
# setuid/setgid bits are ignored
# Highly recommended for all services
NoNewPrivileges=yes
```

### RestrictSUIDSGID

```ini
[Service]
# Prevents creating files with SUID/SGID bits
# Blocks chmod with S_ISUID or S_ISGID
RestrictSUIDSGID=yes
```

### LockPersonality

```ini
[Service]
# Prevents changing the execution domain (personality)
# Blocks personality() syscall from changing ABI
LockPersonality=yes
```

### UMask

```ini
[Service]
# Set restrictive default file creation mask
UMask=0077    # Owner-only access for new files
# Default is 0022 (world-readable)
```

---

## Capability Management

### Linux Capabilities Overview

Instead of running as root, grant only specific privileges:

```ini
[Service]
# Drop ALL capabilities
CapabilityBoundingSet=

# Only keep what's needed
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
# For an unprivileged user to bind to ports < 1024
AmbientCapabilities=CAP_NET_BIND_SERVICE
```

### Common Capabilities Reference

| Capability | Purpose | Services That Need It |
|-----------|---------|----------------------|
| `CAP_NET_BIND_SERVICE` | Bind ports < 1024 | Web servers, DNS |
| `CAP_NET_RAW` | Raw sockets, ICMP | Ping, network monitoring |
| `CAP_NET_ADMIN` | Network configuration | VPN, firewall, DHCP |
| `CAP_SYS_PTRACE` | Process tracing | Debuggers, strace |
| `CAP_DAC_OVERRIDE` | Bypass file permissions | Backup tools |
| `CAP_DAC_READ_SEARCH` | Read any file | Backup, search indexing |
| `CAP_CHOWN` | Change file ownership | Package managers |
| `CAP_FOWNER` | Bypass permission checks | File managers |
| `CAP_SETUID` / `CAP_SETGID` | Change UID/GID | Login services |
| `CAP_SYS_ADMIN` | Catch-all admin cap | Avoid if possible |
| `CAP_SYS_TIME` | Set system clock | NTP |
| `CAP_SYSLOG` | Kernel log access | Syslog daemons |
| `CAP_KILL` | Send signals to any process | Init systems, supervisors |

### Capability Strategy

```ini
[Service]
# Start by dropping everything
CapabilityBoundingSet=

# Add back only what's needed
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH

# For non-root users, must use AmbientCapabilities
User=myapp
AmbientCapabilities=CAP_NET_BIND_SERVICE

# Verify effective capabilities
# Run: grep Cap /proc/<PID>/status
```

---

## System Call Filtering

### SystemCallFilter Basics

Uses seccomp-bpf to restrict which kernel system calls the process can make.

```ini
[Service]
# Whitelist approach (recommended): only allow listed syscall groups
SystemCallFilter=@system-service

# Blacklist approach: deny specific dangerous groups
SystemCallFilter=~@clock ~@debug ~@module ~@mount ~@obsolete ~@reboot ~@swap ~@raw-io

# Architecture restriction (prevent 32-bit syscall bypass on 64-bit)
SystemCallArchitectures=native

# What happens on violation
SystemCallErrorNumber=EPERM    # Return error (default: kill process)
```

### Syscall Filter Groups

List all groups: `systemd-analyze syscall-filter`

| Group | Purpose | Typical Services |
|-------|---------|-----------------|
| `@system-service` | Common service syscalls (safe default) | Most services |
| `@basic-io` | Basic I/O (read, write, close) | All |
| `@file-system` | File operations (open, stat, mkdir) | Most |
| `@io-event` | I/O event handling (epoll, poll, select) | Servers |
| `@network-io` | Network operations (socket, connect, bind) | Network services |
| `@ipc` | IPC operations (shared memory, semaphores) | Some databases |
| `@process` | Process management (fork, exec, wait) | Services that spawn children |
| `@signal` | Signal handling | All |
| `@timer` | Timer operations | Most |
| `@default` | Syscalls always permitted | Baseline |

### Dangerous Groups (Usually Deny)

| Group | Risk | Why Deny |
|-------|------|----------|
| `@clock` | Time manipulation | Can break cryptographic protocols |
| `@debug` | Process debugging | Can read other processes' memory |
| `@module` | Kernel module loading | Can load malicious kernel code |
| `@mount` | Filesystem mounting | Can escape chroot/namespace |
| `@obsolete` | Legacy syscalls | No longer needed, potential exploit vectors |
| `@raw-io` | Raw I/O port access | Direct hardware access |
| `@reboot` | System reboot | Can disrupt system |
| `@swap` | Swap management | Can cause OOM |
| `@cpu-emulation` | CPU emulation | Rarely needed |
| `@privileged` | Privileged operations | Broad category of dangerous calls |
| `@resources` | Resource management | cgroup, rlimit manipulation |
| `@sandbox` | Namespace/sandbox creation | Escape from confinement |
| `@setuid` | UID/GID changes | Privilege escalation |

### Building a Custom Filter

```bash
# 1. Find what syscalls your app actually uses
strace -c -f -p $(pgrep myapp)
# Or start with tracing
strace -c -f /usr/bin/myapp --duration 60

# 2. Start with @system-service and test
# 3. If app fails, check journal for seccomp violations:
journalctl -u myapp.service | grep -i seccomp
# 4. Add specific groups as needed
```

---

## Namespace Isolation

### RestrictNamespaces

Controls which Linux namespaces the process can create.

```ini
[Service]
# Deny all namespace creation
RestrictNamespaces=yes

# Or selectively allow specific namespaces
RestrictNamespaces=~user ~pid ~net ~ipc ~mnt ~cgroup ~uts ~time
```

| Namespace | Flag | Purpose |
|-----------|------|---------|
| `cgroup` | Cgroup isolation | Usually deny |
| `ipc` | IPC isolation | Allow if using shared memory |
| `mnt` | Mount namespace | Allow if service needs mounts |
| `net` | Network namespace | Allow for network isolation |
| `pid` | PID namespace | Usually deny |
| `user` | User namespace | Usually deny |
| `uts` | Hostname namespace | Usually deny |
| `time` | Time namespace | Usually deny |

### PrivateUsers

```ini
[Service]
# Run in a user namespace with no mapping to real users
# UID/GID inside the namespace don't map to host UIDs
PrivateUsers=yes
# Note: Incompatible with some capabilities and SUID binaries
```

### PrivateMounts

```ini
[Service]
# Ensure service's mount namespace is private
# Mount changes don't propagate to/from the host
PrivateMounts=yes
```

---

## Network Isolation

### PrivateNetwork

```ini
[Service]
# Complete network isolation — only loopback (lo) available
# Service cannot make ANY network connections
PrivateNetwork=yes
```

### RestrictAddressFamilies

Control which socket address families can be used:

```ini
[Service]
# Whitelist approach: only allow IPv4, IPv6, and Unix sockets
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# For services that don't need networking
RestrictAddressFamilies=AF_UNIX

# For services that only need local IPC
RestrictAddressFamilies=AF_UNIX AF_NETLINK
```

| Address Family | Purpose |
|---------------|---------|
| `AF_UNIX` | Local Unix domain sockets |
| `AF_INET` | IPv4 networking |
| `AF_INET6` | IPv6 networking |
| `AF_NETLINK` | Kernel communication (routing, firewall) |
| `AF_PACKET` | Raw packet access (tcpdump) |
| `AF_BLUETOOTH` | Bluetooth |

### IPAddressDeny / IPAddressAllow

```ini
[Service]
# Deny all network traffic, then allow specific ranges
IPAddressDeny=any
IPAddressAllow=localhost
IPAddressAllow=192.168.1.0/24
IPAddressAllow=10.0.0.0/8
```

### Network Filtering with BPF

```ini
[Service]
# Attach BPF programs for fine-grained network filtering
IPIngressFilterPath=/etc/bpf/ingress.o
IPEgressFilterPath=/etc/bpf/egress.o
```

---

## Miscellaneous Hardening

### RestrictRealtime

```ini
[Service]
# Prevent acquiring realtime scheduling priority
# Blocks sched_setscheduler() for RT policies
RestrictRealtime=yes
```

### MemoryDenyWriteExecute

```ini
[Service]
# Prevent creating memory mappings that are both writable and executable
# Blocks JIT compilation (breaks Node.js, Java, .NET, Python with some extensions)
# Excellent for compiled binaries (Go, Rust, C)
MemoryDenyWriteExecute=yes
```

**Warning:** Do NOT use with JIT-compiled languages (Node.js, Java, Python).

### KeyringMode

```ini
[Service]
# Isolate or disable kernel keyring
KeyringMode=private    # Own private keyring
# Options: inherit, private, shared
```

### ProtectProc + ProcSubset

```ini
[Service]
# Hide other processes from service's view of /proc
ProtectProc=invisible
# Only show PID-related entries in /proc
ProcSubset=pid
```

### Logging and Audit Controls

```ini
[Service]
# Set syslog identifier
SyslogIdentifier=myapp
# Set log level filter (don't send debug to journal)
LogLevelMax=info
# Rate limiting for log output
LogRateLimitIntervalSec=30s
LogRateLimitBurst=1000
# Namespace journal logs
LogNamespace=myapp
```

---

## Hardening Profiles by Use Case

### Web Application (Node.js, Python, Go)

```ini
[Service]
User=webapp
Group=webapp
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ReadWritePaths=/var/lib/webapp /var/log/webapp
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
# For Go/Rust (compiled): MemoryDenyWriteExecute=yes
# For Node.js/Python: do NOT set MemoryDenyWriteExecute
SystemCallFilter=@system-service
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077
```

### Background Worker / Queue Consumer

```ini
[Service]
DynamicUser=yes
StateDirectory=worker
LogsDirectory=worker
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
PrivateNetwork=no              # Needs network for queue access
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallArchitectures=native
CapabilityBoundingSet=
UMask=0077
```

### Batch Job / Cron Replacement

```ini
[Service]
Type=oneshot
DynamicUser=yes
StateDirectory=batchjob
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/var/spool/batchjob
RestrictNamespaces=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallArchitectures=native
CapabilityBoundingSet=
UMask=0077
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
```

### Network Daemon (DNS, DHCP, VPN)

```ini
[Service]
User=netdaemon
Group=netdaemon
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallFilter=@system-service @network-io
SystemCallArchitectures=native
# Network daemons need specific capabilities
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UMask=0077
```

---

## Directive Quick Reference

### Impact on Security Score

Sorted by typical impact (highest reduction first):

| Directive | Score Impact | Compatibility Risk |
|-----------|-------------|-------------------|
| `PrivateNetwork=yes` | ★★★★★ | 🔴 High — breaks networked services |
| `SystemCallFilter=@system-service` | ★★★★☆ | 🟡 Medium — may break some apps |
| `CapabilityBoundingSet=` | ★★★★☆ | 🟡 Medium — may need specific caps |
| `ProtectSystem=strict` | ★★★☆☆ | 🟢 Low — use ReadWritePaths= |
| `DynamicUser=yes` | ★★★☆☆ | 🟡 Medium — needs StateDirectory |
| `MemoryDenyWriteExecute=yes` | ★★★☆☆ | 🔴 High — breaks JIT languages |
| `ProtectHome=yes` | ★★☆☆☆ | 🟢 Low |
| `PrivateTmp=yes` | ★★☆☆☆ | 🟢 Low |
| `PrivateDevices=yes` | ★★☆☆☆ | 🟢 Low — unless hardware access needed |
| `ProtectKernelTunables=yes` | ★★☆☆☆ | 🟢 Low |
| `ProtectKernelModules=yes` | ★★☆☆☆ | 🟢 Low |
| `ProtectControlGroups=yes` | ★★☆☆☆ | 🟢 Low |
| `NoNewPrivileges=yes` | ★★☆☆☆ | 🟢 Low — almost always safe |
| `RestrictNamespaces=yes` | ★★☆☆☆ | 🟢 Low |
| `RestrictSUIDSGID=yes` | ★☆☆☆☆ | 🟢 Low |
| `LockPersonality=yes` | ★☆☆☆☆ | 🟢 Low |
| `RestrictRealtime=yes` | ★☆☆☆☆ | 🟢 Low |
| `ProtectClock=yes` | ★☆☆☆☆ | 🟢 Low |
| `ProtectHostname=yes` | ★☆☆☆☆ | 🟢 Low |
| `UMask=0077` | ★☆☆☆☆ | 🟢 Low |

### Progressive Hardening Checklist

Apply in order, testing after each step:

1. ☐ `NoNewPrivileges=yes`
2. ☐ `PrivateTmp=yes`
3. ☐ `ProtectSystem=strict` + `ReadWritePaths=`
4. ☐ `ProtectHome=yes`
5. ☐ `PrivateDevices=yes`
6. ☐ `ProtectKernelTunables=yes`
7. ☐ `ProtectKernelModules=yes`
8. ☐ `ProtectControlGroups=yes`
9. ☐ `ProtectClock=yes` + `ProtectHostname=yes`
10. ☐ `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`
11. ☐ `RestrictNamespaces=yes`
12. ☐ `RestrictRealtime=yes` + `RestrictSUIDSGID=yes`
13. ☐ `LockPersonality=yes`
14. ☐ `SystemCallFilter=@system-service`
15. ☐ `SystemCallArchitectures=native`
16. ☐ `CapabilityBoundingSet=` (empty = drop all)
17. ☐ `UMask=0077`
18. ☐ `MemoryDenyWriteExecute=yes` (only if no JIT)
19. ☐ `DynamicUser=yes` (if no stable UID needed)
20. ☐ `PrivateNetwork=yes` (if no network needed)

Run `systemd-analyze security myapp.service` after each step to track progress.
