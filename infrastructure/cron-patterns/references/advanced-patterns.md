# Advanced Cron Patterns

Comprehensive guide to complex scheduling, cloud-native cron, and distributed scheduling.

---

## Table of Contents

- [Complex Scheduling Patterns](#complex-scheduling-patterns)
  - [Nth Weekday of Month](#nth-weekday-of-month)
  - [Last Day of Month](#last-day-of-month)
  - [Business Days Only](#business-days-only)
  - [Complex Interval Patterns](#complex-interval-patterns)
  - [Seasonal and Quarterly Schedules](#seasonal-and-quarterly-schedules)
- [Cron Expression Generators and Tools](#cron-expression-generators-and-tools)
- [Cron in Distributed Systems](#cron-in-distributed-systems)
  - [The Thundering Herd Problem](#the-thundering-herd-problem)
  - [Leader Election](#leader-election)
  - [Jitter Strategies](#jitter-strategies)
  - [Distributed Lock Implementations](#distributed-lock-implementations)
- [Kubernetes CronJobs](#kubernetes-cronjobs)
  - [CronJob Spec Reference](#cronjob-spec-reference)
  - [concurrencyPolicy Deep Dive](#concurrencypolicy-deep-dive)
  - [Handling Missed Schedules](#handling-missed-schedules)
  - [Resource Management](#resource-management)
  - [Production-Ready Template](#production-ready-template)
- [AWS EventBridge Scheduled Rules](#aws-eventbridge-scheduled-rules)
  - [AWS Cron Syntax Differences](#aws-cron-syntax-differences)
  - [EventBridge Scheduler vs Legacy Rules](#eventbridge-scheduler-vs-legacy-rules)
  - [Rate Expressions](#rate-expressions)
  - [Terraform/CloudFormation Examples](#terraformcloudformation-examples)
- [GCP Cloud Scheduler](#gcp-cloud-scheduler)
  - [Configuration and Targets](#configuration-and-targets)
  - [Retry Configuration](#retry-configuration)
  - [gcloud CLI Examples](#gcloud-cli-examples)
- [Cross-Platform Cron Syntax Comparison](#cross-platform-cron-syntax-comparison)

---

## Complex Scheduling Patterns

### Nth Weekday of Month

Standard Unix cron cannot express "Nth weekday of month" directly. Use wrapper scripts or extended cron implementations (Quartz, Spring, AWS).

#### Every 3rd Wednesday

```bash
# Quartz/Spring syntax (6-7 fields):
# sec min hour dom month dow
0 0 0 ? * WED#3

# Standard cron — run every Wednesday, filter in script:
0 0 * * 3 [ "$(date +\%d)" -ge 15 ] && [ "$(date +\%d)" -le 21 ] && /path/to/script.sh

# More robust: count which Wednesday this is
0 0 * * 3 [ $(( ($(date +\%d) - 1) / 7 + 1 )) -eq 3 ] && /path/to/script.sh
```

#### First Monday of Month

```bash
# Quartz: 0 0 0 ? * MON#1
# Standard cron:
0 0 1-7 * 1 /path/to/script.sh
# ↑ CAUTION: due to OR logic between dom and dow, this runs on BOTH
#   days 1-7 AND every Monday. Use a wrapper instead:

0 0 * * 1 [ "$(date +\%d)" -le 7 ] && /path/to/script.sh
```

#### Last Friday of Month

```bash
# Quartz: 0 0 0 ? * 6L
# Standard cron — check if next Friday is in a different month:
0 0 * * 5 [ "$(date -d '+7 days' +\%m)" != "$(date +\%m)" ] && /path/to/script.sh
```

### Last Day of Month

```bash
# Quartz: 0 0 0 L * ?
# Standard cron — check if tomorrow is the 1st:
0 0 28-31 * * [ "$(date -d '+1 day' +\%d)" = "01" ] && /path/to/script.sh

# Works on macOS/BSD (different date syntax):
0 0 28-31 * * [ "$(date -v+1d +\%d)" = "01" ] && /path/to/script.sh

# Last weekday of month (Quartz): 0 0 0 LW * ?
```

### Business Days Only

```bash
# Weekdays (Mon-Fri):
0 9 * * 1-5 /path/to/script.sh

# Skip holidays — maintain a holiday file and check:
0 9 * * 1-5 ! grep -q "$(date +\%Y-\%m-\%d)" /etc/holidays.txt && /path/to/script.sh

# First business day of month:
# Run on 1st-3rd, but only on weekdays
0 9 1-3 * 1-5 /usr/local/bin/first-bizday.sh
# Better — use a script that calculates the actual first business day:
0 9 1-3 * * /usr/local/bin/run-if-first-bizday.sh
```

**Holiday file format** (`/etc/holidays.txt`):
```
2025-01-01
2025-01-20
2025-02-17
2025-05-26
2025-07-04
2025-09-01
2025-11-27
2025-12-25
```

### Complex Interval Patterns

```bash
# Every 90 minutes (not directly expressible — use two entries):
0 0,3,6,9,12,15,18,21 * * * /path/to/script.sh
30 1,4,7,10,13,16,19,22 * * * /path/to/script.sh

# Every 45 minutes:
0,45 * * * *   /path/to/script.sh
30 1,2,4,5,7,8,10,11,13,14,16,17,19,20,22,23 * * * /path/to/script.sh
15 3,6,9,12,15,18,21,0 * * * /path/to/script.sh
# Tip: for non-divisors of 60, generate entries programmatically

# Business hours only, every 30 min, skip lunch:
*/30 9-11 * * 1-5 /path/to/script.sh
*/30 13-17 * * 1-5 /path/to/script.sh

# Bi-weekly (every other week) — cron can't express this natively:
0 0 * * 1 [ $(( $(date +\%V) \% 2 )) -eq 0 ] && /path/to/script.sh
```

### Seasonal and Quarterly Schedules

```bash
# Quarterly — first day of Jan, Apr, Jul, Oct:
0 0 1 1,4,7,10 * /path/to/quarterly-report.sh

# Semi-annually:
0 0 1 1,7 * /path/to/semi-annual.sh

# Winter months only (Nov-Feb):
0 6 * 11,12,1,2 * /path/to/winter-task.sh

# End of fiscal quarter (assuming fiscal year starts April):
0 0 28-30 6,9,12,3 * [ "$(date -d '+1 day' +\%d)" = "01" ] && /path/to/fiscal-close.sh
```

---

## Cron Expression Generators and Tools

| Tool | URL | Features |
|------|-----|----------|
| **crontab.guru** | crontab.guru | Plain-language descriptions, next run times, Unix cron |
| **Crontab.io** | crontab.io | Visual builder with presets and validation |
| **cronhub.io** | cronhub.io | Monitoring + expression generator |
| **CronExpressionToGo** | cronexpressiontogo.com | Unix and Quartz support, pattern library |
| **Orbit2x** | orbit2x.com/cron-builder | Interactive visual builder |
| **AWS Cron Generator** | crongen.com | AWS EventBridge-specific syntax |

### CLI validation tools

```bash
# Python — croniter (pip install croniter)
python3 -c "
from croniter import croniter
from datetime import datetime
cron = croniter('*/15 9-17 * * 1-5', datetime.now())
for _ in range(5):
    print(cron.get_next(datetime))
"

# Node.js — cron-parser (npm install cron-parser)
node -e "
const parser = require('cron-parser');
const interval = parser.parseExpression('*/15 9-17 * * 1-5');
for (let i = 0; i < 5; i++) console.log(interval.next().toString());
"
```

---

## Cron in Distributed Systems

### The Thundering Herd Problem

When many nodes run the same cron schedule, all fire simultaneously:

```
Node-1: 0 * * * * /app/sync.sh   ← All hit the DB at :00
Node-2: 0 * * * * /app/sync.sh
Node-3: 0 * * * * /app/sync.sh
...
Node-N: 0 * * * * /app/sync.sh
```

This causes:
- Database connection spikes
- API rate limit exhaustion
- Cache stampedes
- Network congestion

### Leader Election

Only one node should execute the job. Common approaches:

| Approach | Pros | Cons |
|----------|------|------|
| **Database lock** | Simple, no new infra | DB becomes SPOF |
| **Redis SETNX** | Fast, widely available | Redis must be HA |
| **etcd/Consul lease** | Purpose-built, reliable | Additional infrastructure |
| **Zookeeper** | Battle-tested | Complex to operate |
| **K8s CronJob** | Native, managed | K8s-only |

#### Redis-based leader election

```bash
#!/bin/bash
# Acquire lock with TTL (only one node wins)
LOCK_KEY="cron:hourly-sync"
LOCK_TTL=3500  # slightly less than interval
MY_ID="$(hostname)-$$"

if redis-cli SET "$LOCK_KEY" "$MY_ID" NX EX "$LOCK_TTL" | grep -q OK; then
    echo "Won election, executing job"
    /app/sync.sh
    redis-cli DEL "$LOCK_KEY"
else
    echo "Another node is running this job"
fi
```

### Jitter Strategies

Add randomized delay to spread load:

```bash
# Fixed random delay (0-60 seconds)
sleep $(( RANDOM % 60 ))
/app/sync.sh

# Consistent jitter per node (same delay each time on same host)
JITTER=$(echo "$(hostname)" | cksum | cut -d' ' -f1)
sleep $(( JITTER % 300 ))
/app/sync.sh

# Exponential backoff jitter for retries
MAX_DELAY=60
for attempt in 1 2 3 4 5; do
    if /app/sync.sh; then break; fi
    delay=$(( (2 ** attempt) + (RANDOM % 10) ))
    [ $delay -gt $MAX_DELAY ] && delay=$MAX_DELAY
    sleep $delay
done
```

### Distributed Lock Implementations

#### PostgreSQL advisory lock

```sql
-- In your cron script's SQL:
SELECT pg_try_advisory_lock(12345);
-- Returns true if lock acquired, false if another process holds it
-- Lock auto-releases when session ends
```

#### Consul-based

```bash
# consul lock blocks until acquired, then runs command
consul lock cron/daily-backup /app/backup.sh
```

---

## Kubernetes CronJobs

### CronJob Spec Reference

| Field | Default | Description |
|-------|---------|-------------|
| `schedule` | (required) | Cron expression (standard 5-field) |
| `concurrencyPolicy` | `Allow` | `Allow`, `Forbid`, or `Replace` |
| `startingDeadlineSeconds` | none | Max seconds late a job can start |
| `successfulJobsHistoryLimit` | `3` | Completed jobs to retain |
| `failedJobsHistoryLimit` | `1` | Failed jobs to retain |
| `suspend` | `false` | Pause scheduling without deleting |
| `timeZone` | UTC | IANA timezone (K8s 1.27+) |

### concurrencyPolicy Deep Dive

```yaml
# Allow — jobs can overlap (default, risky for stateful work)
concurrencyPolicy: Allow

# Forbid — skip new run if previous still running (safest)
concurrencyPolicy: Forbid

# Replace — kill running job, start new one (latest-wins)
concurrencyPolicy: Replace
```

**Decision guide:**
- **Idempotent, stateless jobs** → `Allow` is fine
- **Database operations, file writes** → `Forbid`
- **Cache warming, status updates** → `Replace`

### Handling Missed Schedules

```yaml
spec:
  # If the controller was down and missed schedules,
  # allow jobs to start up to 200 seconds late
  startingDeadlineSeconds: 200
  # ⚠️ If >100 schedules are missed, K8s stops trying entirely
```

**Key behaviors:**
- If `startingDeadlineSeconds` is unset and controller was down, ALL missed jobs fire at once
- Set to ≥10 seconds (controller checks every 10s)
- Typical production value: 300 (5 minutes)

### Resource Management

```yaml
jobTemplate:
  spec:
    activeDeadlineSeconds: 3600  # Kill job after 1 hour
    backoffLimit: 3               # Retry failed pods 3 times
    template:
      spec:
        containers:
        - name: job
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
```

### Production-Ready Template

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: db-backup
  labels:
    app: myapp
    component: backup
spec:
  schedule: "0 2 * * *"
  timeZone: "America/New_York"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  successfulJobsHistoryLimit: 5
  failedJobsHistoryLimit: 5
  suspend: false
  jobTemplate:
    spec:
      activeDeadlineSeconds: 7200
      backoffLimit: 2
      template:
        metadata:
          labels:
            app: myapp
            component: backup
        spec:
          serviceAccountName: backup-sa
          restartPolicy: OnFailure
          containers:
          - name: backup
            image: myapp/backup:v1.2.3
            command: ["/app/backup.sh"]
            env:
            - name: DB_HOST
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: host
            resources:
              requests:
                cpu: 250m
                memory: 256Mi
              limits:
                cpu: "1"
                memory: 1Gi
            volumeMounts:
            - name: backup-storage
              mountPath: /backups
          volumes:
          - name: backup-storage
            persistentVolumeClaim:
              claimName: backup-pvc
```

---

## AWS EventBridge Scheduled Rules

### AWS Cron Syntax Differences

AWS uses **6 fields** (adds year), requires `cron()` wrapper, and has stricter rules:

```
cron(minute hour day-of-month month day-of-week year)
```

| Feature | Unix Cron | AWS Cron |
|---------|-----------|----------|
| Fields | 5 | 6 (+ year) |
| Wrapper | none | `cron(...)` |
| `?` character | Not supported | Required in dom OR dow |
| `L` (last) | Not supported | Supported in dom and dow |
| `W` (weekday) | Not supported | Supported in dom |
| `#` (nth) | Not supported | Supported in dow |
| Timezone | System local | UTC (legacy) / configurable (Scheduler) |
| Both dom+dow as `*` | Allowed | Must use `?` for one |

#### Conversion examples

```
# Every weekday at 9 AM
Unix:  0 9 * * 1-5
AWS:   cron(0 9 ? * MON-FRI *)

# First day of month at midnight
Unix:  0 0 1 * *
AWS:   cron(0 0 1 * ? *)

# Every 5 minutes
Unix:  */5 * * * *
AWS:   cron(0/5 * * * ? *)     # Note: AWS uses 0/5 not */5

# Last day of month
Unix:  (not possible)
AWS:   cron(0 0 L * ? *)
```

### EventBridge Scheduler vs Legacy Rules

| Feature | Legacy Rules | EventBridge Scheduler |
|---------|-------------|----------------------|
| Timezone support | UTC only | Any IANA timezone |
| Retry policy | Manual | Built-in (up to 185 retries) |
| Flexible time window | No | Yes (1-15 min jitter) |
| One-time schedules | No | Yes (`at()` expression) |
| Dead-letter queue | No | Native support |
| Targets | 5 per rule | 1 per schedule (with templating) |

**Recommendation:** Use EventBridge Scheduler for new projects.

### Rate Expressions

For simple intervals (no cron complexity needed):

```
rate(1 minute)    # singular when value is 1
rate(5 minutes)
rate(1 hour)
rate(12 hours)
rate(1 day)
rate(7 days)
```

### Terraform/CloudFormation Examples

#### Terraform (EventBridge Scheduler)

```hcl
resource "aws_scheduler_schedule" "daily_backup" {
  name       = "daily-backup"
  group_name = "default"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 15
  }

  schedule_expression          = "cron(0 2 * * ? *)"
  schedule_expression_timezone = "America/New_York"

  target {
    arn      = aws_lambda_function.backup.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 3600
    }

    dead_letter_config {
      arn = aws_sqs_queue.dlq.arn
    }
  }
}
```

#### CloudFormation (Legacy Rule)

```yaml
BackupRule:
  Type: AWS::Events::Rule
  Properties:
    Name: daily-backup
    ScheduleExpression: "cron(0 2 * * ? *)"
    State: ENABLED
    Targets:
      - Arn: !GetAtt BackupFunction.Arn
        Id: backup-target
```

---

## GCP Cloud Scheduler

### Configuration and Targets

Cloud Scheduler uses **standard 5-field cron** with full timezone support. Targets:

- **HTTP/HTTPS** endpoints
- **Pub/Sub** topics
- **App Engine HTTP** targets

```bash
# Create a Cloud Scheduler job
gcloud scheduler jobs create http daily-backup \
  --schedule="0 2 * * *" \
  --time-zone="America/New_York" \
  --uri="https://api.example.com/backup" \
  --http-method=POST \
  --headers="Authorization=Bearer $(gcloud auth print-access-token)" \
  --attempt-deadline=1800s \
  --description="Daily database backup"
```

### Retry Configuration

```bash
gcloud scheduler jobs create http my-job \
  --schedule="*/30 * * * *" \
  --uri="https://api.example.com/process" \
  --time-zone="UTC" \
  --max-retry-attempts=5 \
  --min-backoff=5s \
  --max-backoff=300s \
  --max-doublings=5 \
  --max-retry-duration=3600s
```

| Parameter | Description | Typical Value |
|-----------|-------------|---------------|
| `max-retry-attempts` | Max retries on failure | 3-5 |
| `min-backoff` | Initial retry delay | 5s |
| `max-backoff` | Maximum retry delay | 300s (5 min) |
| `max-doublings` | Times backoff doubles before capping | 5 |
| `max-retry-duration` | Total time to keep retrying | 3600s (1 hour) |
| `attempt-deadline` | Timeout for each attempt | 180s-1800s |

### gcloud CLI Examples

```bash
# List all scheduler jobs
gcloud scheduler jobs list

# Pause a job
gcloud scheduler jobs pause daily-backup

# Resume a job
gcloud scheduler jobs resume daily-backup

# Trigger a job manually (for testing)
gcloud scheduler jobs run daily-backup

# Update schedule
gcloud scheduler jobs update http daily-backup \
  --schedule="0 3 * * *"

# Delete a job
gcloud scheduler jobs delete daily-backup
```

---

## Cross-Platform Cron Syntax Comparison

| Pattern | Unix Cron | Quartz | AWS EventBridge | GCP Scheduler |
|---------|-----------|--------|-----------------|---------------|
| Every 5 min | `*/5 * * * *` | `0 0/5 * * * ?` | `cron(0/5 * * * ? *)` | `*/5 * * * *` |
| Weekdays 9 AM | `0 9 * * 1-5` | `0 0 9 ? * MON-FRI` | `cron(0 9 ? * MON-FRI *)` | `0 9 * * 1-5` |
| Last day of month | *(script)* | `0 0 0 L * ?` | `cron(0 0 L * ? *)` | *(script)* |
| 3rd Wednesday | *(script)* | `0 0 0 ? * WED#3` | `cron(0 0 ? * WED#3 *)` | *(script)* |
| Quarterly | `0 0 1 1,4,7,10 *` | `0 0 0 1 1,4,7,10 ?` | `cron(0 0 1 1,4,7,10 ? *)` | `0 0 1 1,4,7,10 *` |
| Fields | 5 | 6-7 | 6 | 5 |
| Timezone | System | JVM | UTC/configurable | Configurable |
| Seconds | No | Yes (field 1) | No | No |
