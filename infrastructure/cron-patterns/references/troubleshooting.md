# Cron Troubleshooting Guide

Systematic debugging for cron jobs that don't run, fail silently, or behave unexpectedly.

---

## Table of Contents

- [Diagnostic Flowchart](#diagnostic-flowchart)
- [Why Cron Jobs Don't Run](#why-cron-jobs-dont-run)
  - [Cron Daemon Not Running](#cron-daemon-not-running)
  - [Syntax Errors](#syntax-errors)
  - [Environment and PATH Issues](#environment-and-path-issues)
  - [Permission Problems](#permission-problems)
  - [Shell Issues](#shell-issues)
  - [User Crontab vs System Crontab](#user-crontab-vs-system-crontab)
- [Checking Cron Logs](#checking-cron-logs)
  - [syslog](#syslog)
  - [journalctl](#journalctl)
  - [Per-Distribution Log Locations](#per-distribution-log-locations)
  - [Enabling Verbose Cron Logging](#enabling-verbose-cron-logging)
- [Testing Cron Expressions](#testing-cron-expressions)
  - [Online Validators](#online-validators)
  - [CLI Testing Tools](#cli-testing-tools)
  - [Simulating the Cron Environment](#simulating-the-cron-environment)
- [Email Delivery Issues](#email-delivery-issues)
  - [MAILTO Configuration](#mailto-configuration)
  - [Mail Transport Agent Setup](#mail-transport-agent-setup)
  - [Diagnosing Missing Emails](#diagnosing-missing-emails)
- [Timezone Confusion](#timezone-confusion)
  - [Determining Cron's Timezone](#determining-crons-timezone)
  - [CRON_TZ Variable](#cron_tz-variable)
  - [System Timezone Changes](#system-timezone-changes)
- [DST Transitions](#dst-transitions)
  - [Spring Forward Behavior](#spring-forward-behavior)
  - [Fall Back Behavior](#fall-back-behavior)
  - [Safe Scheduling Practices](#safe-scheduling-practices)
- [Cron vs Anacron](#cron-vs-anacron)
  - [When Jobs Are Missed](#when-jobs-are-missed)
  - [Anacron Limitations](#anacron-limitations)
  - [Choosing Between Them](#choosing-between-them)
- [Debugging in Containers](#debugging-in-containers)
  - [Docker Cron Issues](#docker-cron-issues)
  - [Kubernetes CronJob Debugging](#kubernetes-cronjob-debugging)
  - [Container-Specific Pitfalls](#container-specific-pitfalls)
- [Common Mistakes Reference](#common-mistakes-reference)

---

## Diagnostic Flowchart

```
Job not running?
│
├─ Is cron daemon running?
│  └─ NO → systemctl start cron
│
├─ Does crontab exist?
│  └─ crontab -l returns nothing → crontab -e to create
│
├─ Is syntax valid?
│  └─ Paste into crontab.guru → fix errors
│
├─ Is script executable?
│  └─ ls -la /path/to/script → chmod +x
│
├─ Does it work manually?
│  └─ Run: env -i PATH=/usr/bin:/bin /path/to/script.sh
│     ├─ Works → timing/env issue
│     └─ Fails → fix the script first
│
├─ Check logs
│  └─ grep CRON /var/log/syslog
│     ├─ No entries → cron never tried to run it
│     └─ Entries exist → script is running but failing
│
└─ Still stuck?
   └─ Add debugging: * * * * * /path/to/script.sh >> /tmp/debug.log 2>&1
```

---

## Why Cron Jobs Don't Run

### Cron Daemon Not Running

```bash
# Check status
systemctl status cron       # Debian/Ubuntu
systemctl status crond      # RHEL/CentOS/Fedora
service cron status         # Older SysV init

# Start if not running
sudo systemctl start cron
sudo systemctl enable cron  # Persist across reboots

# Verify process exists
ps aux | grep -v grep | grep cron
# Expected: /usr/sbin/cron or /usr/sbin/crond
```

### Syntax Errors

**The most common mistakes:**

```bash
# ✗ WRONG: 6 fields (system crontab format in user crontab)
*/5 * * * * root /path/to/script.sh

# ✓ CORRECT: 5 fields for user crontab
*/5 * * * * /path/to/script.sh

# ✗ WRONG: unescaped % characters
0 2 * * * /usr/bin/date +%Y-%m-%d > /tmp/date.log

# ✓ CORRECT: escape % with backslash
0 2 * * * /usr/bin/date +\%Y-\%m-\%d > /tmp/date.log

# ✗ WRONG: no newline at end of file
# (some cron implementations silently ignore last line)

# ✓ CORRECT: always end crontab with empty line

# ✗ WRONG: invalid range
0 9 * * 7-5 /path/to/script.sh   # 7-5 is invalid range

# ✓ CORRECT:
0 9 * * 1-5 /path/to/script.sh   # Mon-Fri

# ✗ WRONG: mixing formats
0 9 * * Monday /path/to/script.sh  # Inconsistent naming

# ✓ CORRECT: use numbers or 3-letter abbreviations
0 9 * * MON /path/to/script.sh
0 9 * * 1 /path/to/script.sh
```

### Environment and PATH Issues

Cron provides a minimal environment — typically only:
```
SHELL=/bin/sh
PATH=/usr/bin:/bin
HOME=/home/username
LOGNAME=username
```

**Debugging the environment:**
```bash
# Capture cron's actual environment
* * * * * env > /tmp/cron-env-$(date +\%s).txt 2>&1
# Wait 1 minute, then inspect:
cat /tmp/cron-env-*.txt

# Compare with your shell
env > /tmp/shell-env.txt
diff /tmp/cron-env-*.txt /tmp/shell-env.txt
```

**Fixes:**

```bash
# Option 1: Set PATH in crontab header
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Option 2: Use absolute paths in commands
0 * * * * /usr/local/bin/python3 /home/user/scripts/process.py

# Option 3: Source your profile
0 * * * * bash -lc '/home/user/scripts/process.sh'

# Option 4: Source specific environment
0 * * * * . /home/user/.env && /home/user/scripts/process.sh

# Option 5: Inline PATH
0 * * * * PATH=/usr/local/bin:$PATH /home/user/scripts/process.sh
```

**Common missing-environment scenarios:**

| Tool | Problem | Fix |
|------|---------|-----|
| `nvm`/`rbenv`/`pyenv` | Version managers rely on shell init | Source the init script or use absolute path |
| `virtualenv` | Not activated in cron | `source /path/to/venv/bin/activate &&` |
| `docker` | Socket permissions | Add user to docker group or use full path |
| `aws` CLI | Credentials not found | Set `AWS_SHARED_CREDENTIALS_FILE` |
| GUI apps | No `DISPLAY` variable | Set `DISPLAY=:0` if needed |

### Permission Problems

```bash
# Check script permissions
ls -la /path/to/script.sh
# Must have execute bit: -rwxr-xr-x

# Fix permissions
chmod +x /path/to/script.sh

# Check who owns the crontab
crontab -l                    # Current user
sudo crontab -u www-data -l   # Specific user

# Check if user is allowed to use cron
cat /etc/cron.allow   # If exists, only these users can use cron
cat /etc/cron.deny    # If cron.allow missing, these users are blocked

# Check script can write to its log file
sudo -u www-data touch /var/log/myjob.log
# Permission denied? → fix log directory ownership

# Check SELinux (RHEL/CentOS)
getenforce              # If "Enforcing", SELinux may block cron
ausearch -m avc -ts recent | grep cron
# Fix: restorecon -Rv /path/to/script.sh
```

### Shell Issues

```bash
# Cron defaults to /bin/sh, not /bin/bash
# bash-specific syntax may fail silently

# ✗ WRONG in cron (bash-isms in sh):
0 * * * * if [[ -f /tmp/flag ]]; then echo "yes"; fi
0 * * * * echo {1..10}
0 * * * * source ~/.bashrc

# ✓ CORRECT: set SHELL or use explicit bash
SHELL=/bin/bash
0 * * * * if [[ -f /tmp/flag ]]; then echo "yes"; fi

# Or call bash explicitly:
0 * * * * /bin/bash -c 'if [[ -f /tmp/flag ]]; then echo "yes"; fi'
```

### User Crontab vs System Crontab

```
User crontab (crontab -e):
┌─────── minute
│ ┌───── hour
│ │ ┌─── day of month
│ │ │ ┌─ month
│ │ │ │ ┌ day of week
│ │ │ │ │
* * * * * command

System crontab (/etc/cron.d/*, /etc/crontab):
┌─────── minute
│ ┌───── hour
│ │ ┌─── day of month
│ │ │ ┌─ month
│ │ │ │ ┌ day of week
│ │ │ │ │ ┌── user
│ │ │ │ │ │
* * * * * root command
```

**Mixing formats causes silent failure.** A user field in `crontab -e` is interpreted as the command name.

---

## Checking Cron Logs

### syslog

```bash
# Debian/Ubuntu — cron logs to /var/log/syslog
grep CRON /var/log/syslog | tail -20
grep "CRON\[" /var/log/syslog | grep "$(whoami)" | tail -20

# Filter for specific script
grep CRON /var/log/syslog | grep "backup" | tail -10

# RHEL/CentOS — dedicated cron log
tail -50 /var/log/cron
grep "backup" /var/log/cron | tail -10

# Watch in real-time
tail -f /var/log/syslog | grep CRON
```

### journalctl

```bash
# Recent cron activity
journalctl -u cron --since "1 hour ago"
journalctl -u crond --since "1 hour ago"   # RHEL

# Follow live
journalctl -u cron -f

# Today's cron entries only
journalctl -u cron --since today

# Filter by priority (errors only)
journalctl -u cron -p err --since "24 hours ago"

# Specific user's cron activity
journalctl -u cron --since "1 hour ago" | grep "(username)"
```

### Per-Distribution Log Locations

| Distribution | Log File | Service Name |
|-------------|----------|-------------|
| Debian/Ubuntu | `/var/log/syslog` | `cron` |
| RHEL/CentOS 7+ | `/var/log/cron` | `crond` |
| Fedora | `/var/log/cron` | `crond` |
| Alpine | `/var/log/cron` | `crond` |
| Arch Linux | journalctl only | `cronie` |
| Amazon Linux | `/var/log/cron` | `crond` |

### Enabling Verbose Cron Logging

```bash
# rsyslog: create /etc/rsyslog.d/50-cron.conf
cron.*  /var/log/cron.log

# Then restart rsyslog
sudo systemctl restart rsyslog

# For extra verbosity on some cron daemons
# Edit /etc/default/cron (Debian) or /etc/sysconfig/crond (RHEL)
# Add -L 2 for debug level logging
EXTRA_OPTS="-L 2"
```

---

## Testing Cron Expressions

### Online Validators

- **crontab.guru** — paste expression, see human-readable description + next 5 runs
- **cronhub.io/cron-expression-generator** — visual builder with presets
- **crontab.io** — validation + preset templates

### CLI Testing Tools

```bash
# Python: croniter
pip3 install croniter
python3 -c "
from croniter import croniter
from datetime import datetime
c = croniter('30 2 * * 1-5', datetime.now())
print('Next 5 runs:')
for _ in range(5):
    print(f'  {c.get_next(datetime)}')
"

# systemd-analyze (if available)
systemd-analyze calendar '*-*-* 02:30:00'

# Node.js: cron-parser
npx -y cron-parser '*/15 9-17 * * 1-5'
```

### Simulating the Cron Environment

```bash
# Method 1: env -i (strip all environment)
env -i \
  SHELL=/bin/sh \
  PATH=/usr/bin:/bin \
  HOME="$HOME" \
  /path/to/your/script.sh

# Method 2: Use captured cron environment
# First, add to crontab temporarily:
#   * * * * * env > /tmp/cronenv.txt
# Then:
env -i $(cat /tmp/cronenv.txt | tr '\n' ' ') /path/to/your/script.sh

# Method 3: chronic (from moreutils) — only output on error
sudo apt-get install moreutils
chronic /path/to/script.sh
# Silent on success, shows output on non-zero exit
```

---

## Email Delivery Issues

### MAILTO Configuration

```bash
# Send output to specific address
MAILTO=admin@example.com

# Send to multiple addresses
MAILTO=admin@example.com,ops@example.com

# Disable email completely
MAILTO=""

# Per-job MAILTO (set before the entry, affects all below)
MAILTO=team-a@example.com
0 * * * * /path/to/team-a-job.sh

MAILTO=team-b@example.com
30 * * * * /path/to/team-b-job.sh
```

### Mail Transport Agent Setup

Cron uses the system MTA (sendmail/postfix/exim) to deliver mail.

```bash
# Check if MTA is installed and running
which sendmail
systemctl status postfix

# Test mail delivery
echo "Test from cron" | mail -s "Cron test" user@example.com

# Check mail queue
mailq

# Install minimal MTA if missing
sudo apt-get install postfix       # Debian/Ubuntu
sudo yum install postfix           # RHEL/CentOS
```

### Diagnosing Missing Emails

```bash
# 1. Check local mailbox
cat /var/mail/$USER
mail  # Interactive mail reader

# 2. Check mail log
grep "cron" /var/log/mail.log | tail -20

# 3. Verify MAILTO is set
crontab -l | grep MAILTO

# 4. Common causes:
#    - No MTA installed → install postfix
#    - MAILTO="" set → emails suppressed
#    - Firewall blocks outbound SMTP (port 25)
#    - Output redirected to /dev/null → nothing to email
#    - SPF/DKIM failures → emails rejected by recipient
```

---

## Timezone Confusion

### Determining Cron's Timezone

```bash
# Check system timezone
timedatectl show --property=Timezone
cat /etc/timezone
date +%Z

# Verify what cron sees
# Add temporarily to crontab:
* * * * * date '+\%Z \%Y-\%m-\%d \%H:\%M' > /tmp/cron-tz.txt
```

### CRON_TZ Variable

```bash
# Set timezone for specific jobs (Vixie cron, not all implementations)
CRON_TZ=UTC
0 9 * * * /path/to/utc-job.sh

CRON_TZ=America/New_York
0 9 * * * /path/to/ny-job.sh

# ⚠️ CRON_TZ is NOT universally supported
# Check: man 5 crontab | grep -i timezone
```

### System Timezone Changes

```bash
# After changing timezone, restart cron!
sudo timedatectl set-timezone America/Chicago
sudo systemctl restart cron

# Verify cron picked up the change
# (add temp entry and check output)
```

---

## DST Transitions

### Spring Forward Behavior

When clocks jump forward (e.g., 2:00 AM → 3:00 AM):

- Jobs scheduled between 2:00-2:59 **do not run at all**
- Jobs at 3:00+ run normally

```bash
# This job WILL NOT RUN on spring-forward night:
30 2 * * * /path/to/critical-job.sh

# Safe alternative: schedule outside the transition window
30 3 * * * /path/to/critical-job.sh
```

### Fall Back Behavior

When clocks fall back (e.g., 2:00 AM → 1:00 AM):

- Jobs scheduled between 1:00-1:59 **may run twice**
- Behavior depends on cron implementation:
  - Vixie cron: runs jobs only during the first occurrence
  - Some others: may run during both occurrences

```bash
# This job MIGHT RUN TWICE on fall-back night:
30 1 * * * /path/to/non-idempotent-job.sh

# If double-run is dangerous, add a lock:
30 1 * * * flock -n /tmp/job.lock /path/to/job.sh
```

### Safe Scheduling Practices

1. **Use UTC** for servers and critical jobs
2. **Avoid 1:00-3:00 AM local time** for important jobs
3. **Make jobs idempotent** — safe to run twice
4. **Use flock** to prevent double execution
5. **Monitor DST dates** in your operational calendar

```bash
# Safest approach for critical daily jobs:
CRON_TZ=UTC
0 7 * * * /path/to/critical-job.sh    # 7 AM UTC, never affected by DST
```

---

## Cron vs Anacron

### When Jobs Are Missed

| Scenario | Cron | Anacron |
|----------|------|---------|
| System off at scheduled time | Job skipped permanently | Job runs when system comes up |
| System suspended/sleeping | Job skipped | Job runs after wake |
| System rebooted | Job skipped | Job runs after boot (with delay) |
| Sub-hourly schedules | Supported | Not supported (daily minimum) |

### Anacron Limitations

```bash
# /etc/anacrontab format:
# period(days)  delay(min)  job-id        command
1               5           daily-backup  /usr/local/bin/backup.sh
7               10          weekly-audit  /usr/local/bin/audit.sh
30              15          monthly-clean /usr/local/bin/cleanup.sh

# Limitations:
# - Minimum period: 1 day (no hourly/minutely)
# - Runs sequentially, not in parallel
# - No specific time-of-day control
# - Typically runs as root only
# - Stores timestamps in /var/spool/anacron/
```

### Choosing Between Them

| Use Case | Recommendation |
|----------|---------------|
| Server (24/7 uptime) | Cron |
| Desktop/laptop | Anacron for daily+, cron for sub-daily |
| Must run at exact time | Cron |
| Must not be missed | Anacron or systemd timer with `Persistent=true` |
| Sub-minute precision | Neither — use systemd timer or custom loop |
| Container workloads | Neither — use K8s CronJob or external scheduler |

---

## Debugging in Containers

### Docker Cron Issues

**Problem 1: Cron daemon not running**
```dockerfile
# ✗ WRONG: cron isn't PID 1 and never starts
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y cron
COPY crontab /etc/cron.d/my-cron
CMD ["/app/main"]

# ✓ Option A: cron as PID 1 (dedicated cron container)
CMD ["cron", "-f"]

# ✓ Option B: start cron in entrypoint
COPY entrypoint.sh /entrypoint.sh
CMD ["/entrypoint.sh"]
# entrypoint.sh:
# #!/bin/bash
# cron
# exec "$@"
```

**Problem 2: Environment variables not available**
```bash
# Docker env vars are NOT passed to cron processes
# Fix: dump env to file and source it

# In entrypoint.sh:
printenv | grep -v "no_proxy" >> /etc/environment
cron
exec "$@"

# Or in crontab:
* * * * * . /etc/environment && /app/script.sh
```

**Problem 3: Logs go to syslog, not stdout**
```bash
# Cron logs to syslog by default — invisible in Docker

# Fix 1: Redirect in crontab
* * * * * /app/script.sh >> /proc/1/fd/1 2>> /proc/1/fd/2

# Fix 2: Use supercronic (recommended)
# Logs to stdout natively, inherits env, handles signals
FROM alpine:3.19
RUN apk add --no-cache supercronic
COPY crontab /etc/crontab
CMD ["supercronic", "/etc/crontab"]
```

**Problem 4: Signal handling**
```bash
# Standard cron doesn't forward SIGTERM to child processes
# Container stop may leave zombie processes

# Fix: Use supercronic, tini, or dumb-init
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y tini cron
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["cron", "-f"]
```

### Kubernetes CronJob Debugging

```bash
# List CronJobs and their status
kubectl get cronjobs
kubectl get cronjobs -o wide

# Check recent job runs
kubectl get jobs --sort-by=.metadata.creationTimestamp | tail -10

# See why a CronJob isn't creating Jobs
kubectl describe cronjob <name>
# Look for:
#   - "Cannot determine if job needs to be started" → startingDeadlineSeconds too low
#   - "Missed scheduled time" → controller was down too long
#   - "Forbidden: concurrencyPolicy" → previous job still running

# Check job pod logs
kubectl get pods --selector=job-name=<job-name>
kubectl logs <pod-name>

# Check for failed pods
kubectl get pods --field-selector=status.phase=Failed

# Debug: run job manually
kubectl create job --from=cronjob/<cronjob-name> manual-test-$(date +%s)

# Check events
kubectl get events --sort-by=.metadata.creationTimestamp | grep -i cron

# Common K8s CronJob issues:
# 1. Image pull failures → kubectl describe pod
# 2. Resource limits too low → OOMKilled
# 3. ServiceAccount missing permissions → RBAC errors
# 4. PVC not mounted → volume errors
# 5. Timezone wrong → spec.timeZone field (K8s 1.27+)
```

### Container-Specific Pitfalls

| Issue | Symptom | Fix |
|-------|---------|-----|
| No cron daemon | Jobs never run | Use `cron -f` as CMD or supercronic |
| Missing env vars | Scripts fail with "command not found" | Dump env to `/etc/environment` |
| No syslog | No visible logs | Redirect to `/proc/1/fd/1` |
| Wrong timezone | Jobs run at unexpected times | Set `TZ` env var, install tzdata |
| Ephemeral filesystem | Results disappear | Use volumes for output |
| Read-only filesystem | Cron can't create temp files | Mount tmpfs or writable volume |
| Non-root user | crontab access denied | Use supercronic or custom entrypoint |
| Alpine Linux | Missing dependencies | Install with `apk add` |

---

## Common Mistakes Reference

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Unescaped `%` | Command truncated at first `%` | Escape: `\%` |
| No trailing newline | Last cron entry ignored | Add blank line at end |
| Relative paths | "command not found" | Use absolute paths everywhere |
| Wrong user in crontab format | Command treated as user name | Match format to file type |
| Both dom + dow set | Job runs more than expected (OR logic) | Use wrapper script for AND logic |
| No output redirect | Cron tries to email (may fail silently) | Add `>> /var/log/job.log 2>&1` |
| Using `~` in paths | Expansion may not work in cron | Use `$HOME` or full path |
| Locale-dependent commands | Different output in cron | Set `LANG=C` or `LC_ALL=C` |
| Script sources `.bashrc` | File not found (different HOME) | Use absolute path to config |
| `crontab -r` typo | Entire crontab deleted (near `crontab -e`) | Keep backups: `crontab -l > backup` |
| Editor not set | `crontab -e` fails | `export EDITOR=vim` (or nano) |
| Daylight saving time | Job skipped or runs twice | Use UTC or avoid 1-3 AM local |
