# Troubleshooting systemd

## Table of Contents

- [Boot Time Analysis](#boot-time-analysis)
- [Failed Service Diagnosis](#failed-service-diagnosis)
- [Common Exit Codes](#common-exit-codes)
- [Dependency Cycle Resolution](#dependency-cycle-resolution)
- [Service Ordering Issues](#service-ordering-issues)
- [journalctl Filtering](#journalctl-filtering)
- [Coredump Management](#coredump-management)
- [Emergency and Rescue Mode](#emergency-and-rescue-mode)
- [SELinux and AppArmor Conflicts](#selinux-and-apparmor-conflicts)
- [Common Failure Patterns and Fixes](#common-failure-patterns-and-fixes)

---

## Boot Time Analysis

### systemd-analyze blame

Lists all units ordered by startup time:

```bash
# Show units sorted by initialization time
systemd-analyze blame

# Show only top 20 slowest
systemd-analyze blame | head -20

# Output example:
#  32.451s apt-daily.service
#  15.203s NetworkManager-wait-online.service
#   8.121s docker.service
#   3.445s postgresql.service
```

**Note:** `blame` shows wall-clock time per unit but doesn't account for
parallelism. A slow unit may not have blocked boot if it ran in parallel.

### systemd-analyze critical-chain

Shows the actual critical path that determined boot time:

```bash
# Critical path to default target
systemd-analyze critical-chain

# Critical path to a specific unit
systemd-analyze critical-chain myapp.service

# Output example:
# multi-user.target @25.012s
# └─myapp.service @24.100s +0.912s
#   └─postgresql.service @12.300s +11.800s
#     └─network-online.target @12.100s +0.001s
#       └─NetworkManager-wait-online.service @1.200s +10.900s
```

The `@` shows when the unit started; `+` shows how long it took.

### Additional Analysis Commands

```bash
# Total boot time (firmware, loader, kernel, userspace)
systemd-analyze time

# Generate SVG boot timeline
systemd-analyze plot > boot.svg

# Show default target
systemd-analyze default

# Verify all unit files for errors
systemd-analyze verify /etc/systemd/system/*.service

# Check calendar expression
systemd-analyze calendar "Mon..Fri *-*-* 09:00:00"

# Show all timestamps
systemd-analyze timestamp now

# Analyze security posture of a service
systemd-analyze security myapp.service

# Show unit file search paths
systemd-analyze unit-paths

# Dot graph of dependencies (pipe to graphviz)
systemd-analyze dot myapp.service | dot -Tsvg -o deps.svg
```

---

## Failed Service Diagnosis

### Step-by-Step Diagnosis Workflow

```bash
# 1. List all failed units
systemctl --failed

# 2. Get status and recent log lines
systemctl status myapp.service

# 3. Get full journal for this boot
journalctl -u myapp.service -b --no-pager

# 4. Check exit code details
systemctl show myapp.service -p ExecMainStatus -p ExecMainCode \
  -p Result -p ActiveState -p SubState

# 5. Verify unit file syntax
systemd-analyze verify /etc/systemd/system/myapp.service

# 6. Check effective configuration (including drop-ins)
systemctl cat myapp.service

# 7. Show all properties
systemctl show myapp.service --no-pager

# 8. Check dependencies
systemctl list-dependencies myapp.service

# 9. Test run interactively
systemd-run --pty --unit=myapp-debug /usr/bin/myapp

# 10. Reset failed state after fixing
systemctl reset-failed myapp.service
```

### Inspecting Service Properties

```bash
# Key properties to check
systemctl show myapp.service -p MainPID        # Current PID
systemctl show myapp.service -p NRestarts      # Restart count
systemctl show myapp.service -p ExecMainStartTimestamp
systemctl show myapp.service -p ExecMainExitTimestamp
systemctl show myapp.service -p MemoryCurrent  # Current memory usage
systemctl show myapp.service -p CPUUsageNSec   # CPU time consumed
systemctl show myapp.service -p TasksCurrent   # Thread/process count
systemctl show myapp.service -p InvocationID   # Unique run ID
```

---

## Common Exit Codes

| Code | Name | Cause | Fix |
|------|------|-------|-----|
| 0 | SUCCESS | Normal exit | Expected for oneshot; check if `Restart=always` for long-running |
| 1 | FAILURE | Generic error | Check application logs |
| 2 | INVALIDARGUMENT | Bad arguments | Verify `ExecStart=` command line |
| 200 | CHDIR | Can't chdir to `WorkingDirectory=` | Verify directory exists and has correct permissions |
| 201 | RLIMITS | Failed setting resource limits | Check `Limit*=` directives |
| 202 | OOM_ADJUST | Can't write OOM adjust | Check permissions on `/proc/self/oom_score_adj` |
| 203 | EXEC | Binary not found / not executable | Verify `ExecStart=` path, check `chmod +x` |
| 204 | MEMORY | Failed to allocate memory | Reduce `MemoryMax=` or increase system memory |
| 205 | LIMITS | Operation not permitted (seccomp) | Review `SystemCallFilter=` |
| 206 | PERSONALITY | Failed to set personality | Check `Personality=` directive |
| 207 | CAPABILITIES | Failed to drop capabilities | Review `CapabilityBoundingSet=` |
| 208 | CGROUP | Failed to set up cgroup | Check cgroup hierarchy permissions |
| 209 | SETSID | Failed setsid() | Usually a systemd bug or container issue |
| 210 | IOPRIO | Failed setting I/O priority | Check `IOSchedulingClass=` / `IOSchedulingPriority=` |
| 211 | TIMERSLACK | Failed setting timer slack | Check `TimerSlackNSec=` |
| 214 | SETSCHEDULER | Failed setting scheduler | Check `CPUSchedulingPolicy=` |
| 215 | CPUAFFINITY | Failed setting CPU affinity | Check `CPUAffinity=` |
| 216 | GROUP | Group not found | Verify `Group=` exists: `getent group <name>` |
| 217 | USER | User not found | Verify `User=` exists: `getent passwd <name>` |
| 218 | NAMESPACE | Namespace setup failed | Too many namespace restrictions; relax `ProtectSystem=`, `PrivateTmp=` |
| 219 | SECUREBITS | Failed setting secure bits | Review `SecureBits=` |
| 220 | SMACK | SMACK labeling failed | Check SMACK configuration |
| 226 | NAMESPACE | Mount namespace failed | Reduce sandboxing directives |
| 228 | APPARMOR | AppArmor profile error | Check `AppArmorProfile=` |
| 229 | SECCOMP | Seccomp filter error | Review `SystemCallFilter=` |

**Signal-based exits:** If `ExecMainCode=killed`, check `ExecMainStatus` for signal number:
- 9 = SIGKILL (OOM killer or `TimeoutStopSec` exceeded)
- 15 = SIGTERM (normal stop)
- 6 = SIGABRT (application assertion failure)

---

## Dependency Cycle Resolution

### Detecting Cycles

```bash
# systemd logs cycles at boot
journalctl -b -p warning | grep -i cycle

# Example message:
# systemd[1]: Found dependency cycle: a.service → b.service → a.service
# systemd[1]: Breaking cycle by deleting job for a.service

# Visualize dependencies to find the loop
systemd-analyze dot 'myapp.*' | dot -Tsvg -o deps.svg
```

### Common Causes

1. **Circular After/Requires:** `A After B` + `B After A`
2. **Implicit dependencies from socket/service naming**
3. **Generator-created units that conflict with manual units**

### Resolution Steps

```bash
# 1. Find the cycle
systemctl list-dependencies --all myapp.service 2>&1 | grep -i cycle

# 2. Examine each unit's ordering
systemctl show myapp.service -p After -p Before -p Requires -p Wants
systemctl show other.service -p After -p Before -p Requires -p Wants

# 3. Break the cycle:
# - Remove unnecessary After=/Before= directives
# - Change Requires= to Wants= if hard dep isn't needed
# - Use socket activation to decouple startup order
# - Split service into stages

# 4. Verify fix
systemd-analyze verify /etc/systemd/system/myapp.service
systemctl daemon-reload
```

---

## Service Ordering Issues

### Diagnosing "Started Too Early"

```bash
# Check what the service starts after
systemctl show myapp.service -p After
# Check what starts before it
systemctl show myapp.service -p Before

# Verify the target/dependency is actually being waited for
systemctl list-dependencies myapp.service --after
systemctl list-dependencies myapp.service --before
```

### Common Ordering Mistakes

**Problem: Service starts before network is ready**
```ini
# WRONG — network.target only means network mgmt is started, not connected
After=network.target

# RIGHT — waits for at least one network interface to be fully configured
After=network-online.target
Wants=network-online.target
```

**Problem: Service starts before database is ready**
```ini
# This only orders, doesn't ensure the database is LISTENING
After=postgresql.service
Requires=postgresql.service

# Better: Use a pre-start check
ExecStartPre=/usr/local/bin/wait-for-it.sh localhost:5432 --timeout=30
```

**Problem: After= without Wants=/Requires=**
```ini
# WRONG — After only applies IF both units are being started
After=redis.service
# If redis.service is not enabled, After has no effect

# RIGHT — Wants pulls it into the transaction
After=redis.service
Wants=redis.service
```

---

## journalctl Filtering

### By Unit

```bash
journalctl -u myapp.service                      # Single unit
journalctl -u myapp.service -u nginx.service      # Multiple units
journalctl -u 'myapp@*'                           # All instances of template
journalctl _SYSTEMD_UNIT=myapp.service            # Alternative field syntax
```

### By Priority

```bash
journalctl -p emerg    # 0 — System is unusable
journalctl -p alert    # 1 — Immediate action required
journalctl -p crit     # 2 — Critical conditions
journalctl -p err      # 3 — Error conditions
journalctl -p warning  # 4 — Warning conditions
journalctl -p notice   # 5 — Normal but significant
journalctl -p info     # 6 — Informational
journalctl -p debug    # 7 — Debug-level messages

# Range: show errors and above
journalctl -p err
# Range: show only warnings
journalctl -p warning..warning
```

### By Time

```bash
journalctl --since "2024-01-15 09:00:00"
journalctl --since "2024-01-15" --until "2024-01-16"
journalctl --since "1 hour ago"
journalctl --since "30 min ago"
journalctl --since today
journalctl --since yesterday --until today
```

### By Boot

```bash
journalctl -b              # Current boot
journalctl -b -1           # Previous boot
journalctl -b -2           # Two boots ago
journalctl --list-boots    # List all recorded boots
journalctl -b <boot-id>   # Specific boot by ID
```

### By Process / User

```bash
journalctl _PID=1234                    # Specific PID
journalctl _UID=1000                    # Specific user
journalctl _COMM=nginx                  # By command name
journalctl _EXE=/usr/sbin/nginx         # By executable path
journalctl _TRANSPORT=kernel            # Kernel messages only
```

### Output Formats

```bash
journalctl -o short          # Default: timestamp + message
journalctl -o short-precise  # Microsecond timestamps
journalctl -o short-iso      # ISO 8601 timestamps
journalctl -o verbose        # All fields
journalctl -o json           # JSON (one line per entry)
journalctl -o json-pretty    # JSON (formatted)
journalctl -o cat            # Messages only, no metadata
journalctl -o export         # Binary export format (for backup)
```

### Combining Filters

```bash
# Errors from myapp in the last hour during current boot
journalctl -u myapp.service -p err --since "1 hour ago" -b

# Follow with output limited to specific fields
journalctl -u myapp.service -f -o json --output-fields=MESSAGE,PRIORITY
```

### Journal Maintenance

```bash
journalctl --disk-usage                  # Check total size
journalctl --verify                      # Verify journal integrity
journalctl --vacuum-size=500M            # Trim to 500MB
journalctl --vacuum-time=30d             # Keep only 30 days
journalctl --vacuum-files=10             # Keep only 10 journal files
journalctl --rotate                      # Force log rotation
journalctl --sync                        # Flush to disk
```

### Persistent Configuration

```ini
# /etc/systemd/journald.conf
[Journal]
Storage=persistent           # auto, persistent, volatile, none
Compress=yes
SystemMaxUse=2G              # Max disk usage
SystemKeepFree=1G            # Minimum free space to maintain
SystemMaxFileSize=128M       # Max size per journal file
MaxRetentionSec=90day        # Max age
RateLimitIntervalSec=30s     # Rate limiting window
RateLimitBurst=10000         # Max messages per interval
ForwardToSyslog=no
```

---

## Coredump Management

### systemd-coredump

Captures and stores crash dumps for all processes.

```bash
# List all captured coredumps
coredumpctl list

# Show details of the most recent dump
coredumpctl info

# Show dumps for a specific executable
coredumpctl list /usr/bin/myapp

# Show dumps for a specific unit
coredumpctl list --unit=myapp.service

# Launch debugger (gdb) with the most recent dump
coredumpctl gdb

# Launch debugger for specific PID crash
coredumpctl gdb 12345

# Dump core to a file
coredumpctl dump -o /tmp/myapp.core

# Dump for specific executable
coredumpctl dump /usr/bin/myapp -o /tmp/myapp.core
```

### Configuration

```ini
# /etc/systemd/coredump.conf
[Coredump]
Storage=external             # none, external, journal
Compress=yes
ProcessSizeMax=2G            # Max core size to process
ExternalSizeMax=2G           # Max stored core size
MaxUse=10G                   # Max total storage
KeepFree=1G                  # Min free space
```

### Integration with Services

```ini
[Service]
# Allow core dumps (override LimitCORE=0)
LimitCORE=infinity

# Or disable core dumps for security
LimitCORE=0
```

---

## Emergency and Rescue Mode

### Entering Recovery Modes

**At boot (GRUB):**
Add to kernel command line:
- `systemd.unit=rescue.target` — Single-user mode, basic services running
- `systemd.unit=emergency.target` — Minimal shell, almost nothing running
- `rd.break` — Break into initramfs before root mount

**From a running system:**
```bash
systemctl rescue     # Switch to rescue mode
systemctl emergency  # Switch to emergency mode (DANGEROUS on remote!)
```

### Rescue vs Emergency

| Feature | rescue.target | emergency.target |
|---------|--------------|-----------------|
| Root filesystem | Mounted read-write | Mounted read-only |
| Other filesystems | Not mounted | Not mounted |
| Network | Down | Down |
| Services | Basic set running | Almost none |
| Use case | Fix services/config | Fix fstab/root fs |

### Recovery Procedures

```bash
# In emergency mode, remount root read-write
mount -o remount,rw /

# Fix a broken service preventing boot
systemctl mask broken.service
# Or disable it
systemctl disable broken.service

# Fix fstab issues
vi /etc/fstab

# Rebuild initramfs
dracut --force  # RHEL/Fedora
update-initramfs -u  # Debian/Ubuntu

# Exit and continue boot
exit
# Or reboot
systemctl reboot
```

### Debug Shell

Enable a root shell on TTY9 for troubleshooting without interrupting boot:

```bash
systemctl enable debug-shell.service
# Reboot, then switch to TTY9 (Ctrl+Alt+F9)
# DISABLE after debugging (security risk!)
systemctl disable debug-shell.service
```

---

## SELinux and AppArmor Conflicts

### SELinux Troubleshooting

```bash
# Check if SELinux is enforcing
getenforce

# Look for recent denials
ausearch -m avc -ts recent
ausearch -m avc -c myapp

# Use audit2why for explanations
ausearch -m avc -ts recent | audit2why

# Generate a custom policy module
ausearch -m avc -ts recent | audit2allow -M myapp_custom
semodule -i myapp_custom.pp

# Temporarily set permissive for testing (NEVER in production permanently)
setenforce 0
# Or per-domain permissive
semanage permissive -a myapp_t

# Check file contexts
ls -Z /usr/bin/myapp
ls -Z /var/lib/myapp/

# Restore correct contexts
restorecon -Rv /var/lib/myapp/

# Set custom context
semanage fcontext -a -t myapp_var_lib_t "/var/lib/myapp(/.*)?"
restorecon -Rv /var/lib/myapp/
```

### AppArmor Troubleshooting

```bash
# Check AppArmor status
aa-status

# View denials in logs
dmesg | grep apparmor
journalctl -k | grep apparmor

# Set profile to complain mode (log but don't block)
aa-complain /etc/apparmor.d/usr.bin.myapp

# Generate profile from logs
aa-logprof

# Reload profiles
apparmor_parser -r /etc/apparmor.d/usr.bin.myapp
systemctl reload apparmor
```

### systemd Interactions

Systemd sandboxing directives can conflict with MAC policies:

```ini
[Service]
# This creates mount namespaces — may need SELinux/AppArmor exceptions
ProtectSystem=strict
PrivateTmp=yes

# Explicit AppArmor profile
AppArmorProfile=myapp

# SELinux context
SELinuxContext=system_u:system_r:myapp_t:s0
```

**Diagnosis checklist when security frameworks conflict:**

1. Does the error mention "Permission denied" or "Operation not permitted"?
2. Check `ausearch` (SELinux) or `dmesg | grep apparmor` first
3. Temporarily disable the MAC framework to confirm it's the cause
4. If systemd sandboxing + MAC both restrict, they stack — both must allow
5. Create targeted exceptions rather than disabling either framework

---

## Common Failure Patterns and Fixes

### Service Starts Then Immediately Exits

```bash
# Check if Type= matches application behavior
systemctl show myapp.service -p Type
# Type=simple but app forks? → Change to Type=forking + PIDFile=
# Type=notify but app doesn't call sd_notify? → Change to Type=simple
# Type=oneshot without RemainAfterExit=yes? → Shows as "inactive" (normal)
```

### Service Fails with "Permission Denied"

```bash
# Check which sandboxing directive is blocking
systemd-analyze security myapp.service
# Test without sandboxing (debug only!)
systemd-run --pty -p ProtectSystem=no -p ProtectHome=no /usr/bin/myapp
# Check file ownership
ls -la /usr/bin/myapp /etc/myapp/ /var/lib/myapp/
# Check if binary has correct capabilities
getcap /usr/bin/myapp
```

### Service Takes Too Long to Start

```ini
# Increase timeouts
[Service]
TimeoutStartSec=120
# Or disable timeout (not recommended for production)
TimeoutStartSec=infinity
```

### Service Keeps Restarting (Crash Loop)

```bash
# Check restart count
systemctl show myapp.service -p NRestarts
# Check rate limiting
systemctl show myapp.service -p StartLimitIntervalUSec -p StartLimitBurst
# View logs across restarts
journalctl -u myapp.service --since "10 min ago" --no-pager
# Reset failed state
systemctl reset-failed myapp.service
```

### "Start request repeated too quickly"

```ini
[Unit]
# Increase rate limit
StartLimitIntervalSec=600
StartLimitBurst=10

[Service]
# Add delay between restarts
RestartSec=10
```

### OOM Killed Service

```bash
# Check if OOM killer struck
journalctl -k | grep -i oom
journalctl -u myapp.service | grep -i "out of memory\|oom\|killed"
dmesg | grep -i oom

# Check current memory limits
systemctl show myapp.service -p MemoryMax -p MemoryCurrent

# Increase limits
systemctl edit myapp.service
# Add:
# [Service]
# MemoryMax=2G
```

### Socket Activation Not Working

```bash
# Verify socket is enabled and active (not the service!)
systemctl status myapp.socket
# Check socket is actually listening
ss -tlnp | grep <port>
# Verify naming matches (socket and service must have same prefix)
ls /etc/systemd/system/myapp.socket /etc/systemd/system/myapp.service
# Check socket fd passing
systemd-socket-activate -l 8080 /usr/bin/myapp  # Manual test
```
