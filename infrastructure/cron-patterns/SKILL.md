---
name: cron-patterns
description: >
  Guide for cron job scheduling, crontab syntax, and periodic task execution on Unix/Linux systems.
  Use when user needs cron job setup, scheduled tasks, crontab syntax, periodic job execution,
  cron expressions, cron debugging, crontab management, cron output handling, cron security,
  cron in containers, or cron monitoring. Covers expression syntax, special characters,
  predefined schedules, environment variables, overlapping job prevention, and common pitfalls.
  NOT for systemd timers (see systemd-services), NOT for CI/CD scheduled pipelines,
  NOT for application-level job schedulers like Celery/Bull/Sidekiq.
---

# Cron Patterns

## Cron Expression Syntax

Five space-separated fields define the schedule:

```
┌───────────── minute       (0-59)
│ ┌─────────── hour         (0-23)
│ │ ┌───────── day of month (1-31)
│ │ │ ┌─────── month        (1-12 or JAN-DEC)
│ │ │ │ ┌───── day of week  (0-7 or SUN-SAT; 0 and 7 = Sunday)
│ │ │ │ │
* * * * *  command
```

When both day-of-month and day-of-week are set (non-`*`), they are ORed, not ANDed.

## Special Characters

| Char | Name | Fields | Meaning |
|------|------|--------|---------|
| `*` | Wildcard | All | Match every value |
| `,` | List | All | `1,15,30` = at 1, 15, and 30 |
| `-` | Range | All | `9-17` = 9 through 17 inclusive |
| `/` | Step | All | `*/5` = every 5 units; `3/15` = at 3, 18, 33, 48 |
| `L` | Last | dom/dow (Quartz) | `L` in dom = last day of month; `5L` = last Friday |
| `W` | Weekday | dom (Quartz) | `15W` = nearest weekday to 15th |
| `#` | Nth | dow (Quartz) | `5#3` = third Friday of the month |
| `?` | Any | dom/dow (Quartz) | No specific value (use when other field is set) |

> `L`, `W`, `#`, `?` are Quartz/Spring/AWS extensions — standard Unix cron supports only `*`, `,`, `-`, `/`.

## Predefined Schedules

```
@reboot           Run once at daemon startup
@yearly (@annually)  0 0 1 1 *    Midnight, January 1
@monthly          0 0 1 * *    Midnight, first of month
@weekly           0 0 * * 0    Midnight, Sunday
@daily (@midnight)   0 0 * * *    Midnight daily
@hourly           0 * * * *    Top of every hour
```

## Common Cron Expressions

```bash
# Every 5 minutes
*/5 * * * *

# Every 15 minutes, offset by 3
3/15 * * * *

# Hourly at minute 30
30 * * * *

# Daily at 2:30 AM
30 2 * * *

# Weekdays at 9 AM (business hours start)
0 9 * * 1-5

# Every 2 hours from 8-18, weekdays only
0 8-18/2 * * 1-5

# First day of every month at midnight
0 0 1 * *

# Every quarter (Jan, Apr, Jul, Oct) on the 1st
0 0 1 1,4,7,10 *

# Last day of month at 11 PM (requires Quartz or wrapper script)
0 23 L * *

# First Monday of month (Quartz only)
0 0 * * 1#1

# Every Sunday at 3 AM
0 3 * * 0

# Twice daily at 8 AM and 8 PM
0 8,20 * * *

# Every 10 minutes during business hours
*/10 9-17 * * 1-5
```

## Crontab Management

```bash
# Edit current user's crontab
crontab -e

# List current user's crontab
crontab -l

# Remove current user's crontab (dangerous — no confirmation on some systems)
crontab -r

# Edit crontab for specific user (requires root)
crontab -u username -e

# Install crontab from file
crontab /path/to/crontab-file

# Backup crontab
crontab -l > ~/crontab-backup-$(date +%Y%m%d).txt

# Restore crontab
crontab ~/crontab-backup-20240101.txt
```

### /etc/cron.d/ Directory

Drop individual cron files here. Each file uses an extended format with a user field:

```
# /etc/cron.d/myapp-cleanup
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=ops@example.com

# min hour dom month dow user  command
*/30 *    *   *     *   www-data  /usr/local/bin/cleanup.sh
```

System-level cron directories (scripts placed here run automatically):
- `/etc/cron.hourly/` — run every hour
- `/etc/cron.daily/` — run daily
- `/etc/cron.weekly/` — run weekly
- `/etc/cron.monthly/` — run monthly

## Cron Environment Variables

Cron runs with a minimal environment. Set variables at the top of the crontab:

```bash
# Essential variables to set in crontab
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=admin@example.com
HOME=/home/deploy
# Disable email notifications
MAILTO=""
# Set timezone (if supported by your cron implementation)
CRON_TZ=America/New_York

# Application-specific variables
APP_ENV=production
DATABASE_URL=postgres://localhost/myapp
```

Default cron environment is extremely limited (`PATH=/usr/bin:/bin`). Always:
- Use absolute paths for commands: `/usr/local/bin/python3` not `python3`
- Source profiles if needed: `* * * * * . /home/user/.profile && /path/to/script.sh`

### Audit cron's environment

```bash
# Add temporarily to crontab to see what cron provides
* * * * * env > /tmp/cron-env.txt 2>&1
# Compare with: diff /tmp/cron-env.txt <(env)
```

## Output Handling

```bash
# Redirect stdout and stderr to a log file
* * * * * /path/to/script.sh >> /var/log/myjob.log 2>&1

# Discard all output (silent)
* * * * * /path/to/script.sh > /dev/null 2>&1

# Log stdout and stderr separately
* * * * * /path/to/script.sh >> /var/log/myjob.out 2>> /var/log/myjob.err

# Log with timestamp
* * * * * /path/to/script.sh 2>&1 | ts '[%Y-%m-%d %H:%M:%S]' >> /var/log/myjob.log

# Pipe to logger (sends to syslog)
* * * * * /path/to/script.sh 2>&1 | logger -t myjob

# Email output to specific address (overrides MAILTO)
MAILTO=alerts@example.com
0 * * * * /path/to/hourly-report.sh
```

Without redirection or MAILTO="", cron attempts to email output to the crontab owner. If mail is unconfigured, output is silently lost.

## Debugging Cron Jobs

### Check cron daemon status

```bash
systemctl status cron          # Debian/Ubuntu
systemctl status crond         # RHEL/CentOS
ps aux | grep cron
```

### Read cron logs

```bash
# Debian/Ubuntu
grep CRON /var/log/syslog | tail -20

# RHEL/CentOS
tail -50 /var/log/cron

# systemd-based
journalctl -u cron --since "1 hour ago"
journalctl -u cron -f          # Follow live
```

### Simulate cron environment for testing

```bash
# Run script with minimal environment (like cron does)
env -i SHELL=/bin/sh PATH=/usr/bin:/bin HOME=$HOME /path/to/script.sh

# Or source the captured cron environment
env -i $(cat /tmp/cron-env.txt | xargs) /path/to/script.sh
```

### Common failure checklist

1. **Cron daemon running?** — `systemctl status cron`
2. **Syntax valid?** — Paste into crontab.guru
3. **Script executable?** — `chmod +x /path/to/script.sh`
4. **Absolute paths used?** — For commands AND file references
5. **Correct user?** — `crontab -l` vs `sudo crontab -u www-data -l`
6. **Dependencies available?** — Test with `env -i`
7. **Shebang line present?** — `#!/bin/bash` at top of script

## Cron vs systemd Timers

| Feature | Cron | systemd Timers |
|---------|------|----------------|
| Setup complexity | Simple (one line) | Two unit files (.timer + .service) |
| Logging | Manual (redirect/syslog) | Built-in (`journalctl -u myservice`) |
| Missed job catchup | No (use anacron) | `Persistent=true` |
| Dependencies | None | Full systemd dependency graph |
| Granularity | 1 minute minimum | Sub-second capable |
| Monitoring | External tools | `systemctl list-timers` |
| Resource control | None | cgroups, CPU/memory limits |
| Randomized delay | No | `RandomizedDelaySec=` |
| Availability | Universal | systemd-based Linux only |

Use cron for simple scheduled tasks. Use systemd timers for logging, dependencies, resource limits, or missed-job recovery.

## Anacron for Missed Jobs

Anacron ensures periodic jobs run even if the system was off at the scheduled time. It tracks last-run timestamps, not clock time.

```bash
# /etc/anacrontab format:
# period  delay  job-id          command
1         5      daily-backup    /usr/local/bin/backup.sh
7         10     weekly-report   /usr/local/bin/report.sh
30        15     monthly-audit   /usr/local/bin/audit.sh
```

- `period`: days between runs
- `delay`: minutes to wait after anacron starts before running
- Anacron is typically invoked by cron itself (via `/etc/cron.d/anacron`); not suitable for sub-daily schedules

## Cron Security

### cron.allow and cron.deny

```bash
# /etc/cron.allow — if exists, ONLY listed users can use cron
echo "deploy" >> /etc/cron.allow
echo "appuser" >> /etc/cron.allow

# /etc/cron.deny — if cron.allow doesn't exist, listed users are blocked
echo "guest" >> /etc/cron.deny
```

Precedence: (1) `cron.allow` exists → only listed users. (2) `cron.allow` absent, `cron.deny` exists → all except listed. (3) Neither → only root (varies by distro).

### Security best practices

- Never store secrets directly in crontab; source from protected files
- Use dedicated service accounts for cron jobs
- Set restrictive permissions on cron scripts: `chmod 700`
- Audit crontabs regularly: `for u in $(cut -f1 -d: /etc/passwd); do echo "=== $u ==="; crontab -u $u -l 2>/dev/null; done`

## Timezone Handling

```bash
# Set timezone in crontab (if CRON_TZ is supported)
CRON_TZ=UTC
0 9 * * * /path/to/script.sh    # Runs at 9 AM UTC regardless of system TZ

# Alternative: use TZ in the command
0 * * * * TZ=America/Chicago date >> /tmp/tz-test.log

# Check system timezone
timedatectl show --property=Timezone
cat /etc/timezone
```

Cron uses the system timezone by default. After changing system timezone, restart the cron daemon. Be cautious during DST transitions — jobs scheduled in the skipped or repeated hour may run zero or two times.

## Overlapping Job Prevention

### flock (preferred)

```bash
# Skip if already running (-n = nonblocking)
* * * * * /usr/bin/flock -n /tmp/myjob.lock /path/to/script.sh

# Wait up to 60 seconds for lock, then skip
* * * * * /usr/bin/flock -w 60 /tmp/myjob.lock /path/to/script.sh

# With verbose error on conflict
* * * * * /usr/bin/flock -n /tmp/myjob.lock -c '/path/to/script.sh' || echo "SKIPPED: lock held" >> /var/log/myjob.log
```

### PID file approach

```bash
#!/bin/bash
PIDFILE="/var/run/myjob.pid"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "Already running (PID $(cat $PIDFILE))"
    exit 1
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
# ... actual work here ...
```

Prefer `flock` — it's atomic and handles stale locks automatically.

## Cron in Containers

Traditional cron has container issues: loses env vars, logs to syslog (not stdout), mishandles signals.

### Supercronic (recommended)

```dockerfile
FROM alpine:3.19
RUN apk add --no-cache supercronic
COPY crontab /etc/crontab
CMD ["supercronic", "/etc/crontab"]
# Benefits: inherits Docker env vars, logs to stdout/stderr, handles SIGTERM
```

### Host cron + docker exec

```bash
# Run command inside existing container
*/5 * * * * docker exec myapp_container /app/cleanup.sh >> /var/log/cleanup.log 2>&1
# Or spin up a new container each time
0 * * * * docker run --rm myapp:latest /app/hourly-task.sh
```

### Kubernetes CronJobs

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: db-backup
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid       # Prevent overlapping
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: myapp:latest
            command: ["/app/backup.sh"]
          restartPolicy: OnFailure
```

## Monitoring Cron Jobs

### healthchecks.io

```bash
# Ping start and finish (measures duration)
0 2 * * * curl -fsS https://hc-ping.com/UUID/start > /dev/null; /path/to/backup.sh; curl -fsS https://hc-ping.com/UUID/$? > /dev/null
```

### Cronitor

```bash
# Wrap command with cronitor
* * * * * cronitor exec JOB_KEY /path/to/script.sh
```

### DIY monitoring pattern

```bash
#!/bin/bash
set -euo pipefail
START=$(date +%s)
if /path/to/actual-work.sh >> /var/log/myjob.log 2>&1; then
    echo "[$(date)] Succeeded in $(( $(date +%s) - START ))s" >> /var/log/myjob.log
    curl -fsS "https://hc-ping.com/UUID" > /dev/null 2>&1 || true
else
    echo "[$(date)] FAILED (exit $?)" >> /var/log/myjob.log
    curl -fsS "https://hc-ping.com/UUID/fail" > /dev/null 2>&1 || true
    exit 1
fi
```

## Critical Gotchas

### % is a special character in crontab

```bash
# WRONG — % is treated as newline, breaks the command
0 2 * * * /usr/bin/date +%Y-%m-%d > /tmp/date.log

# CORRECT — escape % with backslash
0 2 * * * /usr/bin/date +\%Y-\%m-\%d > /tmp/date.log

# BETTER — move complex commands to a script
0 2 * * * /usr/local/bin/datelog.sh
```

### Environment pitfalls

```bash
# Cron does NOT source .bashrc, .profile, or .bash_profile
# WRONG: * * * * * my-ruby-app process
# CORRECT:
* * * * * /usr/local/bin/ruby /home/deploy/app/process.rb
* * * * * bash -lc '/home/deploy/app/process.rb'
```

### Day-of-month + day-of-week ORing

```bash
# This runs on the 15th AND every Friday (OR logic), not "15th if it's Friday"
0 0 15 * 5 /path/to/script.sh

# To run only if 15th is a Friday, use a wrapper:
0 0 15 * * [ "$(date +\%u)" = "5" ] && /path/to/script.sh
```

### Other gotchas

- Ensure crontab ends with a newline — some implementations silently ignore the last line without one.
- User crontabs (`crontab -e`): 5 fields + command. System crontabs (`/etc/cron.d/*`): 5 fields + **user** + command. Mixing formats causes silent failures.

---

## Additional Resources

This skill includes supplementary references, scripts, and assets for deeper coverage.

### References

In-depth guides in `references/`:

| File | Description |
|------|-------------|
| [`advanced-patterns.md`](references/advanced-patterns.md) | Complex scheduling (Nth weekday, last day of month, business days), cron in distributed systems (leader election, jitter), Kubernetes CronJobs, AWS EventBridge rules, GCP Cloud Scheduler, cross-platform syntax comparison |
| [`troubleshooting.md`](references/troubleshooting.md) | Diagnostic flowchart, why cron jobs don't run (environment, PATH, permissions, shell), checking logs (syslog, journalctl), testing expressions, email delivery, timezone/DST issues, cron vs anacron, debugging in containers |

### Scripts

Executable utilities in `scripts/` (all `chmod +x`, with usage comments):

| Script | Description |
|--------|-------------|
| [`cron-validator.sh`](scripts/cron-validator.sh) | Validates cron expressions, shows next N run times, detects common mistakes (unescaped `%`, OR logic, wrong field count). Supports `--check-crontab` and `--check-file` modes |
| [`cron-wrapper.sh`](scripts/cron-wrapper.sh) | Generic cron job wrapper: logging with rotation, flock-based locking, execution time tracking, healthchecks.io integration, configurable timeout, failure notification hooks |
| [`cron-monitor.sh`](scripts/cron-monitor.sh) | Monitors cron job health: register jobs, send heartbeats, check if jobs ran on schedule, generate JSON/text reports, healthchecks.io ping integration |

### Assets

Copy-paste ready templates in `assets/`:

| File | Description |
|------|-------------|
| [`crontab-templates.md`](assets/crontab-templates.md) | Production crontab entries for backups (PostgreSQL, MySQL, MongoDB, S3), log rotation, system maintenance, health checks, reports, queue processing, security scans |
| [`cron-expression-cheatsheet.md`](assets/cron-expression-cheatsheet.md) | Visual quick reference: field layout, special characters, predefined schedules, ASCII timeline diagrams, frequency table, platform differences |
| [`k8s-cronjob.yaml`](assets/k8s-cronjob.yaml) | Production-ready Kubernetes CronJob template with security context, resource limits, history retention, concurrency policy, RBAC scaffolding, and inline decision documentation |

<!-- tested: pass -->

