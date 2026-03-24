---
name: systemd-services
description: >
  Expert guidance for creating and managing systemd unit files, service management, timer/cron
  replacement, socket activation, path units, process supervision, security hardening, resource
  limits, template units, drop-in overrides, user services, and debugging failed units. Use when
  user needs systemd unit files, service configuration, timer scheduling, socket-activated daemons,
  process supervision, journalctl log analysis, or systemctl operations. NOT for Docker/container
  orchestration, NOT for init.d/SysVinit scripts, NOT for macOS launchd plists, NOT for Windows
  services or NSSM, NOT for supervisord or pm2 process managers.
---
# systemd Services Skill
## Unit File Anatomy
Place system units in `/etc/systemd/system/`. Vendor units in `/usr/lib/systemd/system/`. Run `systemctl daemon-reload` after any unit file change.
### [Unit] — Metadata and Dependencies
```ini
[Unit]
Description=My Application Server
Documentation=https://example.com/docs
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service
BindsTo=critical-dependency.service
Conflicts=legacy-app.service
ConditionPathExists=/etc/myapp/config.yaml
StartLimitIntervalSec=300
StartLimitBurst=5
```
- `Requires=` — hard dependency; required unit failure stops this unit
- `Wants=` — soft dependency; wanted unit failure is ignored
- `After=/Before=` — ordering only; combine with Wants/Requires for both ordering AND dependency
- `BindsTo=` — like Requires, also stops this unit when bound unit stops
- `Conflicts=` — starting this unit stops the conflicting unit
- `ConditionPathExists=` — skip activation silently if path missing
### [Service] — Process Configuration
```ini
[Service]
Type=notify
ExecStartPre=/usr/bin/myapp --validate-config
ExecStart=/usr/bin/myapp --config /etc/myapp/config.yaml
ExecStartPost=/usr/bin/myapp-healthcheck
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/usr/bin/myapp --graceful-shutdown
TimeoutStartSec=30
TimeoutStopSec=30
Restart=on-failure
RestartSec=5
WatchdogSec=30
KillMode=mixed
KillSignal=SIGTERM
```
### [Install] — Enable/Disable Targets
```ini
[Install]
WantedBy=multi-user.target    # Start on normal boot (most services)
Alias=myapp.service
Also=myapp-worker.service     # Enable this unit too when enabling main unit
```
## Service Types
| Type | Use When | Notes |
|------|----------|-------|
| `simple` | Process stays in foreground (default) | Most common for modern apps |
| `exec` | Like simple, waits for exec() success | Catches binary-not-found early |
| `forking` | Daemon forks, parent exits | Set `PIDFile=`; legacy daemons only |
| `oneshot` | Short-lived scripts | Pair with `RemainAfterExit=yes` |
| `notify` | App calls `sd_notify(READY=1)` | Best for apps supporting it |
| `dbus` | Ready when D-Bus name acquired | Set `BusName=` |
| `idle` | Delay until other jobs dispatched | Console output ordering |
**Rule:** Use `notify` if supported, `simple` otherwise. Avoid `forking` for new apps. Use `oneshot` for setup/teardown.
### oneshot Example
```ini
# Input: Configure iptables at boot
# Output: /etc/systemd/system/iptables-setup.service
[Unit]
Description=Load iptables rules
Before=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables-restore /etc/iptables/rules.v4
ExecStop=/usr/sbin/iptables-save -f /etc/iptables/rules.v4
[Install]
WantedBy=multi-user.target
```
## Restart Policies
| Restart= | Triggers on |
|----------|-------------|
| `no` | Never (default) |
| `always` | Any exit, signal, timeout, or watchdog |
| `on-failure` | Non-zero exit, signal, timeout, watchdog |
| `on-abnormal` | Signal, timeout, watchdog (NOT non-zero exit) |
| `on-abort` | Unclean signal only |
| `on-watchdog` | Watchdog timeout only |
Rate limiting (in [Unit]): `StartLimitIntervalSec=600` + `StartLimitBurst=5` — allows 5 restarts per 600s. After exceeding, unit enters failed state. `StartLimitAction=reboot` for critical services.
## Environment Variables
```ini
[Service]
Environment=NODE_ENV=production
Environment="DATABASE_URL=postgres://db:5432/app"
EnvironmentFile=/etc/myapp/env
EnvironmentFile=-/etc/myapp/env.local   # dash = optional, no error if missing
PassEnvironment=LANG TZ
```
Env file format: one `VAR=value` per line, no `export` keyword, no shell expansion.
## Security Hardening
Audit with `systemd-analyze security myapp.service`. Apply progressively.
### Minimal (start here)
```ini
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/myapp /var/log/myapp
```
### Moderate
```ini
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/var/lib/myapp
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
```
### Maximum
```ini
[Service]
DynamicUser=yes
StateDirectory=myapp
LogsDirectory=myapp
CacheDirectory=myapp
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
PrivateUsers=yes
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
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077
```
**ProtectSystem:** `yes` (ro /usr,/boot), `full` (adds /etc), `strict` (entire fs ro; use ReadWritePaths=).
**DynamicUser=yes:** ephemeral user/group; use StateDirectory/LogsDirectory/CacheDirectory for persistence.
**SystemCallFilter groups:** `@system-service` (safe default), `@network-io`, `@file-system`. Prefix `~` to deny: `~@mount`.
## Resource Limits
```ini
[Service]
MemoryMax=512M              # Hard limit, OOM-kills above this
MemoryHigh=400M             # Soft limit, kernel reclaims aggressively
CPUQuota=200%               # 2 full CPU cores
CPUWeight=100               # Relative weight vs other services
TasksMax=512                # Max processes/threads (prevents fork bombs)
LimitNOFILE=65536           # Max open file descriptors
IOWeight=100                # Relative IO weight
IOReadBandwidthMax=/dev/sda 50M
LimitCORE=0                 # Disable core dumps
```
## Socket Activation
Start services on-demand when connections arrive. Enable the socket, NOT the service.
```ini
# Input: Activate web service only when traffic arrives on port 8080
# Output: /etc/systemd/system/webapp.socket
[Unit]
Description=Webapp Socket
[Socket]
ListenStream=8080
Accept=no
NoDelay=yes
[Install]
WantedBy=sockets.target
```
```ini
# /etc/systemd/system/webapp.service
[Unit]
Description=Webapp Service
Requires=webapp.socket
After=webapp.socket
[Service]
Type=notify
ExecStart=/usr/bin/webapp
NonBlocking=yes
```
- `Accept=no` (default) — single service handles all connections
- `Accept=yes` — spawn instance per connection, requires template `webapp@.service`
- Service receives socket as fd 3; use `sd_listen_fds()` or check `$LISTEN_FDS`
- `systemctl enable --now webapp.socket` (not the .service)
## Timer Units (Cron Replacement)
Create paired `.timer` and `.service` files with same basename.
```ini
# Input: Run backup daily at 2:30 AM and 15 min after boot
# Output: /etc/systemd/system/backup.timer
[Unit]
Description=Daily Backup Timer
[Timer]
OnCalendar=*-*-* 02:30:00
OnBootSec=15min
Persistent=true
RandomizedDelaySec=300
AccuracySec=60
[Install]
WantedBy=timers.target
```
```ini
# /etc/systemd/system/backup.service
[Unit]
Description=Backup Job
[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup.sh
Nice=19
IOSchedulingClass=idle
```
**OnCalendar syntax examples:**
- `hourly`, `daily`, `weekly` — built-in shortcuts
- `Mon..Fri *-*-* 09:00:00` — weekdays at 9 AM
- `*-*-01 00:00:00` — first of each month
- `*:0/15` — every 15 minutes
Validate: `systemd-analyze calendar "Mon..Fri *-*-* 09:00:00"`
- `Persistent=true` — catch up missed runs if system was off
- `RandomizedDelaySec=` — jitter to avoid thundering herd
- List timers: `systemctl list-timers --all`
## Path Units
Trigger a service when a file system path changes.
```ini
# Input: Process files landing in /var/spool/incoming
# Output: /etc/systemd/system/file-processor.path
[Unit]
Description=Watch incoming directory
[Path]
PathExistsGlob=/var/spool/incoming/*.csv
MakeDirectory=yes
DirectoryMode=0755
[Install]
WantedBy=multi-user.target
```
| Directive | Triggers when |
|-----------|---------------|
| `PathExists=` | Path exists |
| `PathExistsGlob=` | Glob pattern matches |
| `PathChanged=` | Write close or attribute change |
| `PathModified=` | Write close (content change) |
| `DirectoryNotEmpty=` | Directory becomes non-empty |
## Template Units (@)
Parameterized units using `%i` (escaped instance), `%I` (unescaped instance).
```ini
# Input: Per-tenant worker processes
# Output: /etc/systemd/system/worker@.service
[Unit]
Description=Worker for tenant %i
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/worker --tenant %i
User=worker
EnvironmentFile=/etc/worker/%i.env
Restart=on-failure
[Install]
WantedBy=multi-user.target
```
```bash
systemctl enable --now worker@acme.service
systemctl enable --now worker@globex.service
systemctl status 'worker@*.service'       # Glob to see all instances
```
Specifiers: `%i` instance, `%n` unit name, `%p` prefix (before @), `%H` hostname, `%t` runtime dir.
## Drop-in Overrides
Override vendor units without editing originals.
```bash
systemctl edit myapp.service              # Creates override.conf in .d/ directory
systemctl edit --full myapp.service       # Full copy to /etc/systemd/system/
# Manual override:
mkdir -p /etc/systemd/system/myapp.service.d/
cat > /etc/systemd/system/myapp.service.d/limits.conf << 'EOF'
[Service]
MemoryMax=1G
LimitNOFILE=65536
EOF
systemctl daemon-reload
```
To clear list directives (ExecStart, Environment), set empty first then new value:
```ini
[Service]
ExecStart=
ExecStart=/usr/bin/myapp --new-flags
```
## User Services
Per-user units in `~/.config/systemd/user/`. Manage with `systemctl --user`.
```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/syncthing.service << 'EOF'
[Unit]
Description=Syncthing File Sync
[Service]
ExecStart=/usr/bin/syncthing serve --no-browser
Restart=on-failure
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now syncthing.service
loginctl enable-linger $USER             # Run services without active login
```
Logs: `journalctl --user -u syncthing.service`
## systemctl Quick Reference
```bash
systemctl start|stop|restart|reload myapp.service
systemctl enable --now myapp.service      # Enable at boot + start
systemctl disable myapp.service           # Remove from boot (can still start manually)
systemctl mask myapp.service              # Link to /dev/null, block ALL activation
systemctl unmask myapp.service
systemctl status myapp.service            # Status + recent logs
systemctl show myapp.service              # All properties as key=value
systemctl show -p MainPID myapp.service   # Single property
systemctl cat myapp.service               # Print unit file contents
systemctl list-dependencies myapp.service
systemctl daemon-reload                   # Reload ALL unit files
systemctl list-units --failed
systemctl list-unit-files --type=service
```
## journalctl Reference
```bash
journalctl -u myapp.service               # All logs for unit
journalctl -u myapp.service -f            # Follow (like tail -f)
journalctl -u myapp.service -n 100        # Last 100 lines
journalctl -u myapp.service -p err        # Errors and above
journalctl -u myapp.service --since "1 hour ago"
journalctl -u myapp.service -b            # Current boot only
journalctl -u myapp.service -b -1         # Previous boot
journalctl -u myapp.service -o json-pretty  # JSON output
journalctl --disk-usage                    # Check log disk usage
journalctl --vacuum-size=500M              # Trim logs to 500MB
journalctl --vacuum-time=30d               # Keep only 30 days
```
## Debugging Failed Services
```bash
# 1. Status and logs
systemctl status myapp.service
journalctl -u myapp.service -n 50 --no-pager
# 2. Exit code inspection
systemctl show -p ExecMainStatus -p ExecMainCode myapp.service
# 3. Unit file syntax check
systemd-analyze verify /etc/systemd/system/myapp.service
# 4. Security audit
systemd-analyze security myapp.service
# 5. Boot timing analysis
systemd-analyze blame
systemd-analyze critical-chain myapp.service
# 6. Interactive test run
systemd-run --unit=myapp-debug --pty /usr/bin/myapp
```
Common exit codes: 203 (binary not found/not executable), 217 (User= doesn't exist), 226 (namespace setup failed), 200 (PrivateTmp/ProtectSystem unsupported).
## Production Example
```ini
# Input: Production Node.js API with full hardening, resource limits, auto-restart
# Output: /etc/systemd/system/api-server.service
[Unit]
Description=Production API Server
Documentation=https://internal.docs/api
After=network-online.target postgresql.service redis.service
Wants=network-online.target
Requires=postgresql.service
StartLimitIntervalSec=600
StartLimitBurst=5
[Service]
Type=notify
User=apiserver
Group=apiserver
WorkingDirectory=/opt/api-server
EnvironmentFile=/etc/api-server/env
ExecStart=/usr/bin/node /opt/api-server/dist/main.js
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
WatchdogSec=30
TimeoutStopSec=30
KillMode=mixed
MemoryMax=1G
MemoryHigh=768M
CPUQuota=200%
TasksMax=256
LimitNOFILE=65536
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/var/lib/api-server /var/log/api-server
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallArchitectures=native
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
UMask=0077
[Install]
WantedBy=multi-user.target
```
## Reference Documents
In-depth guides in the `references/` directory:
- **`references/advanced-patterns.md`** — Socket activation deep dive, watchdog (WatchdogSec/sd_notify), cgroup resource controls (CPUWeight, IOWeight, MemoryHigh, Slices), transient units (systemd-run), portable services, systemd-nspawn containers, systemd-resolved/networkd integration, condition directives (ConditionPathExists, ConditionACPower, ConditionVirtualization, etc.), and instantiated unit patterns with template specifiers.
- **`references/troubleshooting.md`** — Boot time analysis (systemd-analyze blame/critical-chain/plot), failed service diagnosis workflow, complete exit code reference, dependency cycle resolution, service ordering issues, journalctl filtering (by unit, priority, time range, boot, process), coredump management (systemd-coredump/coredumpctl), emergency/rescue mode, SELinux/AppArmor conflict resolution, and common failure patterns with fixes.
- **`references/security-reference.md`** — Complete security hardening directive reference (ProtectSystem, ProtectHome, PrivateDevices, ProtectKernelTunables, ProtectControlGroups, RestrictNamespaces, RestrictSUIDSGID, SystemCallFilter), systemd-analyze security scoring interpretation, seccomp filter groups, capability management, namespace isolation, network isolation, hardening profiles by use case (web app, worker, batch job, network daemon), and a progressive hardening checklist.
## Scripts
Executable tools in the `scripts/` directory:
- **`scripts/service-generator.sh`** — Interactive unit file generator with presets for web apps, workers, and cron replacements. Supports `--preset web|worker|cron` and configurable security hardening levels.
- **`scripts/systemd-security-audit.sh`** — Audits services for 24 security directives, scores each unit with a letter grade, and suggests specific improvements. Supports `--all`, `--json`, and `--threshold` options.
- **`scripts/service-monitor.sh`** — Monitors service health: restart counts, memory/CPU usage, task counts, and failure alerts. Supports `--watch` for continuous monitoring, `--alert-restarts`, `--alert-memory`, and `--json` output.
## Templates
Copy-paste ready unit files in the `assets/templates/` directory:
- **`assets/templates/web-app.service`** — Web application template (Node/Python/Go) with full security hardening, resource limits, watchdog, and placeholder documentation.
- **`assets/templates/worker.service`** — Background worker template with restart policies, graceful shutdown, and security hardening.
- **`assets/templates/timer.timer`** + **`assets/templates/timer.service`** — Timer unit pair for cron replacement with persistent scheduling, jitter, and low-priority execution.
- **`assets/templates/socket.socket`** + **`assets/templates/socket.service`** — Socket activation pair with named fd support, backlog configuration, and connection limits.
