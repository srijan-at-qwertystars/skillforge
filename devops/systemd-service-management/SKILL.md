---
name: systemd-service-management
description: |
  Use when user creates or manages systemd services, asks about unit files, systemctl commands, timers (cron replacement), socket activation, journald log queries, or systemd security hardening (sandboxing, namespaces). Do NOT use for Docker/container management, init.d/SysVinit scripts, supervisord, or macOS launchd.
---

# systemd Service Management

## Unit File Anatomy

Unit files live in three locations (highest priority first):

1. `/etc/systemd/system/` — admin overrides (use this)
2. `/run/systemd/system/` — runtime units
3. `/usr/lib/systemd/system/` — package-provided (never edit directly)

Use `systemctl edit myapp` to create drop-in overrides under `/etc/systemd/system/myapp.service.d/override.conf`. Survives package upgrades.

### Three Required Sections

```ini
[Unit]
Description=My Application Server
Documentation=https://example.com/docs
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=notify
ExecStart=/usr/bin/myapp --config /etc/myapp/config.toml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
User=myapp
Group=myapp
WorkingDirectory=/var/lib/myapp

[Install]
WantedBy=multi-user.target
```

**[Unit]** — metadata and ordering. `After=` controls startup order. `Requires=` hard-depends; `Wants=` soft-depends.

**[Service]** — execution parameters, restart policy, user/group, environment.

**[Install]** — defines which target enables this unit. `WantedBy=multi-user.target` starts at boot.

## Service Types

| Type | Behavior | Use When |
|------|----------|----------|
| `simple` | Default. `ExecStart` is the main process. | Long-running daemons that stay in foreground |
| `forking` | Process forks; parent exits. Set `PIDFile=`. | Legacy daemons that daemonize themselves |
| `oneshot` | Runs once and exits. Stays "active" after exit with `RemainAfterExit=yes`. | Init scripts, setup tasks |
| `notify` | Like simple, but process sends `sd_notify(READY=1)`. | Apps with sd_notify support (recommended) |
| `dbus` | Ready when specified `BusName=` appears on D-Bus. | D-Bus services |
| `idle` | Like simple, delayed until all jobs dispatched. | Low-priority startup tasks |

Prefer `Type=notify` for new services. Use `Type=exec` (systemd 240+) when you need readiness confirmed at exec time but lack sd_notify support.

## Lifecycle Management

```bash
# Start/stop/restart
systemctl start myapp
systemctl stop myapp
systemctl restart myapp
systemctl reload myapp          # sends SIGHUP (if ExecReload defined)
systemctl reload-or-restart myapp

# Enable/disable at boot
systemctl enable myapp          # creates symlink in target.wants/
systemctl enable --now myapp    # enable + start in one command
systemctl disable myapp

# Status and inspection
systemctl status myapp
systemctl is-active myapp
systemctl is-enabled myapp
systemctl show myapp            # dump all properties
systemctl cat myapp             # show unit file contents
systemctl list-dependencies myapp

# Reload daemon after editing unit files
systemctl daemon-reload
```

## Restart Policies

```ini
[Service]
Restart=on-failure          # restart on non-zero exit, signal, timeout
RestartSec=5                # wait 5s between restarts
StartLimitIntervalSec=300   # rate-limit window (5 min)
StartLimitBurst=5           # max 5 restarts in window
```

| Restart Value | On Clean Exit | On Error Exit | On Signal | On Timeout | On Watchdog |
|---------------|:---:|:---:|:---:|:---:|:---:|
| `no` | — | — | — | — | — |
| `on-failure` | — | ✓ | ✓ | ✓ | ✓ |
| `on-abnormal` | — | — | ✓ | ✓ | ✓ |
| `on-abort` | — | — | ✓ | — | — |
| `always` | ✓ | ✓ | ✓ | ✓ | ✓ |

Set `RestartPreventExitStatus=` to exclude specific exit codes from triggering restart.

When `StartLimitBurst` is hit, the unit enters a failed state. Reset with `systemctl reset-failed myapp`.

## Environment and Working Directory

```ini
[Service]
# Inline variables
Environment=NODE_ENV=production
Environment=PORT=3000

# Load from file (one VAR=value per line)
EnvironmentFile=/etc/myapp/env
EnvironmentFile=-/etc/myapp/env.local   # dash prefix = optional, no error if missing

WorkingDirectory=/var/lib/myapp
RuntimeDirectory=myapp          # creates /run/myapp owned by User=
StateDirectory=myapp            # creates /var/lib/myapp owned by User=
LogsDirectory=myapp             # creates /var/log/myapp owned by User=
CacheDirectory=myapp            # creates /var/cache/myapp owned by User=
ConfigurationDirectory=myapp    # creates /etc/myapp owned by User=
```

Use `RuntimeDirectory=`, `StateDirectory=`, etc. instead of manual `mkdir` in `ExecStartPre=`. systemd manages ownership and cleanup.

## Dependency Management

```ini
[Unit]
# Ordering (does NOT pull in the dependency)
After=network-online.target     # start after network is up
Before=httpd.service            # start before httpd

# Requirement (pulls in the dependency)
Requires=postgresql.service     # hard dependency; if postgres fails, this fails
Wants=redis.service             # soft dependency; redis failure won't stop this
BindsTo=libvirtd.service        # like Requires, but also stops when bound unit stops

# Conflict
Conflicts=sendmail.service      # cannot run alongside sendmail
```

**Common patterns:**
- Network-dependent service: `After=network-online.target` + `Wants=network-online.target`
- Database-dependent service: `After=postgresql.service` + `Requires=postgresql.service`
- Use `PartOf=` for units that should restart/stop together with a parent

## Timers (Cron Replacement)

Create two files: a `.timer` and a matching `.service`.

### Timer Unit

```ini
# /etc/systemd/system/backup.timer
[Unit]
Description=Daily backup timer

[Timer]
OnCalendar=*-*-* 02:00:00      # daily at 2 AM
Persistent=true                  # run missed events after boot
RandomizedDelaySec=600           # spread load up to 10 min
AccuracySec=1min                 # timer coalescing window

[Install]
WantedBy=timers.target
```

### Matching Service

```ini
# /etc/systemd/system/backup.service
[Unit]
Description=Daily backup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup.sh
User=backup
```

### OnCalendar Syntax

```
OnCalendar=hourly               # shorthand
OnCalendar=daily
OnCalendar=weekly
OnCalendar=Mon *-*-* 08:00:00   # every Monday 8 AM
OnCalendar=*-*-01 00:00:00      # first of every month
OnCalendar=*:0/15               # every 15 minutes
```

Validate with: `systemd-analyze calendar "Mon *-*-* 08:00:00"`

### Monotonic Timers```ini
OnBootSec=5min                  # 5 min after boot
OnUnitActiveSec=1h              # 1 hour after last activation
OnStartupSec=10min              # 10 min after systemd started
```

### Timer Management

```bash
systemctl enable --now backup.timer
systemctl list-timers --all
systemctl status backup.timer
journalctl -u backup.service    # check run logs
```

## Socket Activation

systemd listens on sockets and starts the service on first connection. Reduces boot time and memory usage.

### Socket Unit

```ini
# /etc/systemd/system/myapp.socket
[Unit]
Description=My App Socket

[Socket]
ListenStream=8080               # TCP port
# ListenStream=/run/myapp.sock  # Unix socket alternative
# ListenDatagram=514            # UDP
Accept=no                       # pass socket to single long-running service
BindIPv6Only=both

[Install]
WantedBy=sockets.target
```

### Matching Service

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=My App
Requires=myapp.socket

[Service]
Type=notify
ExecStart=/usr/bin/myapp
User=myapp
NonBlocking=yes
```

**`Accept=no`** (default): one service instance receives all connections. Service inherits listening socket as fd 3 (use `sd_listen_fds()`).

**`Accept=yes`**: new instance per connection (inetd-style). Use `myapp@.service` template.

Enable the socket, not the service: `systemctl enable --now myapp.socket`

## Security Hardening

Apply progressively. Test with `systemd-analyze security myapp.service` after each change.

### Minimal Hardened Service

```ini
[Service]
# User isolation
DynamicUser=yes                 # ephemeral user; auto-cleanup
# Or static user:
# User=myapp
# Group=myapp

# Filesystem
ProtectSystem=strict            # /usr, /boot, /etc read-only
ProtectHome=yes                 # /home, /root, /run/user inaccessible
PrivateTmp=yes                  # isolated /tmp
ReadWritePaths=/var/lib/myapp   # explicit write exceptions
StateDirectory=myapp            # auto-creates /var/lib/myapp

# Privilege restriction
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# Kernel
ProtectKernelTunables=yes       # /proc/sys, /sys read-only
ProtectKernelModules=yes        # block module loading
ProtectKernelLogs=yes           # block /dev/kmsg access
ProtectControlGroups=yes        # /sys/fs/cgroup read-only

# Syscall filtering
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallArchitectures=native  # block non-native syscalls

# Network
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
IPAddressDeny=any
IPAddressAllow=localhost
IPAddressAllow=10.0.0.0/8

# Misc hardening
PrivateDevices=yes
MemoryDenyWriteExecute=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
ProtectClock=yes
ProtectHostname=yes
UMask=0077
```

### Audit Security Posture

```bash
systemd-analyze security myapp.service
# Score from 0.0 (hardened) to 10.0 (no hardening)
```

## Journald

### Querying Logs

```bash
journalctl -u myapp.service                    # by unit
journalctl -u myapp -u nginx                   # multiple units
journalctl -u myapp -f                         # follow (tail -f)
journalctl -u myapp --since "1 hour ago"       # time range
journalctl -u myapp -p err                     # priority filter
journalctl -u myapp -b                         # current boot
journalctl -u myapp -b -1                      # previous boot
journalctl -k                                  # kernel messages
journalctl -u myapp -o json-pretty             # JSON output
journalctl -u myapp -n 50                      # last N lines
journalctl _PID=1234                           # by PID
journalctl --disk-usage                        # check space
journalctl --vacuum-time=7d                    # purge old logs
journalctl --vacuum-size=500M
```

### Journald Configuration (`/etc/systemd/journald.conf`)

```ini
[Journal]
Storage=persistent              # survive reboots
SystemMaxUse=500M
MaxRetentionSec=30day
RateLimitIntervalSec=30s
RateLimitBurst=10000
Compress=yes
```

Apply: `systemctl restart systemd-journald`

## Resource Limits

```ini
[Service]
# Memory
MemoryMax=512M                  # hard limit (OOM-killed if exceeded)
MemoryHigh=384M                 # soft limit (throttled)
MemorySwapMax=0                 # disable swap usage

# CPU
CPUQuota=200%                   # 2 full cores max
CPUWeight=50                    # relative weight (default 100)

# IO
IOWeight=50                     # relative IO priority (1-10000)
IOReadBandwidthMax=/dev/sda 10M

# Tasks
TasksMax=64                     # max number of processes/threads

# File descriptors
LimitNOFILE=65536

# Core dumps
LimitCORE=0                     # disable core dumps
```

Inspect current limits: `systemctl show myapp -p MemoryMax -p CPUQuota -p TasksMax`

## User Services

Per-user services run without root, managed by `systemd --user`.

Place unit files in `~/.config/systemd/user/`.

```ini
# ~/.config/systemd/user/syncthing.service
[Unit]
Description=Syncthing File Synchronization

[Service]
ExecStart=/usr/bin/syncthing serve --no-browser
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

```bash
# Manage user services (no sudo)
systemctl --user daemon-reload
systemctl --user enable --now syncthing
systemctl --user status syncthing
journalctl --user -u syncthing

# Allow user services to run without active login session
loginctl enable-linger $USER
```

User services cannot use `User=`, `Group=`, or most security directives requiring root.

## Troubleshooting

### Failed Services

```bash
# List failed units
systemctl --failed

# Inspect failure reason
systemctl status myapp
journalctl -u myapp -b --no-pager -n 100

# Reset failed state
systemctl reset-failed myapp
```

### Dependency Issues

```bash
# Show dependency tree
systemctl list-dependencies myapp

# Reverse dependencies (who needs this?)
systemctl list-dependencies myapp --reverse

# Check for circular dependencies
systemd-analyze verify myapp.service
```

### Boot Performance

```bash
# Total boot time
systemd-analyze

# Per-unit blame
systemd-analyze blame

# Critical chain (blocking path)
systemd-analyze critical-chain

# Plot SVG timeline
systemd-analyze plot > boot.svg
```

### Common Errors

| Symptom | Fix |
|---------|-----|
| `status=203/EXEC` | Binary not found — verify `ExecStart=` uses absolute path |
| `status=217/USER` | User missing — create user or use `DynamicUser=yes` |
| `status=200/CHDIR` | `WorkingDirectory` missing — create dir or remove directive |
| Service starts then stops | Wrong `Type=` — forking daemon needs `Type=forking` + `PIDFile=` |
| `Failed to connect to bus` | No user session — run `loginctl enable-linger $USER` |
| Dependency cycle | Circular `After=`/`Requires=` — break with `Wants=` |

### Useful Diagnostic Commands

```bash
# Verify unit file syntax
systemd-analyze verify /etc/systemd/system/myapp.service

# Show effective unit file (with overrides applied)
systemctl cat myapp

# List all loaded units
systemctl list-units --type=service

# List all unit files (installed)
systemctl list-unit-files --type=service

# Monitor real-time unit state changes
busctl monitor org.freedesktop.systemd1
```

<!-- tested: pass -->
