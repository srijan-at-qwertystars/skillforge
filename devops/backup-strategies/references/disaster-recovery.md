# Disaster Recovery Planning

> Complete disaster recovery guide covering RPO/RTO classification, DR runbooks, failover testing,
> cross-cloud DR, automation with Terraform, tabletop exercises, and compliance requirements.

## Table of Contents

- [RPO/RTO Matrix by Service Tier](#rporto-matrix-by-service-tier)
  - [Tier Definitions](#tier-definitions)
  - [RPO/RTO Matrix Template](#rporto-matrix-template)
  - [Mapping Systems to Tiers](#mapping-systems-to-tiers)
- [DR Runbook Template](#dr-runbook-template)
  - [Runbook Structure](#runbook-structure)
  - [Incident Declaration Criteria](#incident-declaration-criteria)
  - [Communication Plan](#communication-plan)
  - [Step-by-Step Recovery Procedures](#step-by-step-recovery-procedures)
- [Failover Testing Procedures](#failover-testing-procedures)
  - [Test Types and Frequency](#test-types-and-frequency)
  - [Failover Test Checklist](#failover-test-checklist)
  - [Automated Failover Testing](#automated-failover-testing)
- [Data Consistency Verification](#data-consistency-verification)
  - [Post-Restore Validation](#post-restore-validation)
  - [Cross-Service Consistency Checks](#cross-service-consistency-checks)
  - [Automated Verification Scripts](#automated-verification-scripts)
- [Point-in-Time Recovery Workflows](#point-in-time-recovery-workflows)
  - [PostgreSQL PITR](#postgresql-pitr)
  - [MySQL PITR](#mysql-pitr)
  - [MongoDB PITR](#mongodb-pitr)
- [Cross-Cloud DR](#cross-cloud-dr)
  - [DR Architecture Patterns](#dr-architecture-patterns)
  - [Multi-Cloud Data Replication](#multi-cloud-data-replication)
  - [DNS Failover Strategies](#dns-failover-strategies)
- [DR Automation with Terraform](#dr-automation-with-terraform)
  - [Infrastructure-as-Code DR](#infrastructure-as-code-dr)
  - [Terraform DR Module Pattern](#terraform-dr-module-pattern)
  - [Automated Failover with Terraform](#automated-failover-with-terraform)
- [Tabletop Exercises](#tabletop-exercises)
  - [Exercise Planning](#exercise-planning)
  - [Scenario Library](#scenario-library)
  - [Post-Exercise Review](#post-exercise-review)
- [Compliance Requirements](#compliance-requirements)
  - [SOC 2 Backup Controls](#soc-2-backup-controls)
  - [HIPAA Backup Requirements](#hipaa-backup-requirements)
  - [Compliance Evidence Collection](#compliance-evidence-collection)

---

## RPO/RTO Matrix by Service Tier

### Tier Definitions

| Tier | Name | RPO | RTO | Description | Example Systems |
|------|------|-----|-----|-------------|-----------------|
| 0 | Mission Critical | 0 (zero loss) | <15 min | Active-active, synchronous replication | Payment processing, trading |
| 1 | Business Critical | <15 min | <1 hr | Near-real-time replication, hot standby | Primary database, auth service |
| 2 | Important | <1 hr | <4 hr | Frequent backups, warm standby | Web app, API gateway, CMS |
| 3 | Standard | <4 hr | <8 hr | Regular backups, cold standby | Internal tools, staging |
| 4 | Non-Critical | <24 hr | <24 hr | Daily backups, manual recovery | Dev environments, archives |

### RPO/RTO Matrix Template

```markdown
| System | Owner | Tier | RPO | RTO | Backup Method | Backup Freq | DR Strategy | Last Test | Test Result |
|--------|-------|------|-----|-----|---------------|-------------|-------------|-----------|-------------|
| Orders DB | @db-team | 1 | 15min | 1hr | pg_basebackup+WAL | Continuous | Hot standby | 2024-01-15 | PASS |
| User Auth | @platform | 1 | 15min | 30min | Streaming replication | Continuous | Multi-AZ RDS | 2024-01-10 | PASS |
| Product API | @backend | 2 | 1hr | 4hr | pg_dump + restic | Hourly | Pilot light | 2024-01-08 | PASS |
| CMS | @content | 3 | 4hr | 8hr | restic filesystem | 4-hourly | Cold standby | 2024-02-01 | PASS |
| CI/CD | @devops | 3 | 4hr | 8hr | Velero + etcd snap | 4-hourly | Rebuild | 2024-01-20 | PASS |
| Dev Env | @dev | 4 | 24hr | 24hr | Daily snapshot | Daily | Rebuild | 2024-03-01 | PASS |
```

### Mapping Systems to Tiers

**Decision criteria for tier assignment:**

```
1. Revenue Impact
   - Direct revenue loss per hour of downtime → Higher tier
   - Customer-facing vs internal → Customer-facing gets higher tier

2. Regulatory Requirements
   - HIPAA/PCI/SOX mandated availability → Tier 0-1
   - Data retention requirements → Affects RPO

3. Dependency Analysis
   - Systems that many others depend on → Higher tier
   - Single points of failure → Higher tier

4. Data Criticality
   - Irreplaceable data → Lower RPO (higher tier)
   - Easily regenerated data → Higher RPO acceptable (lower tier)

5. Cost-Benefit Analysis
   - Tier 0: $$$$ (active-active infra)
   - Tier 1: $$$ (hot standby + replication)
   - Tier 2: $$ (warm standby + frequent backups)
   - Tier 3: $ (cold standby + regular backups)
   - Tier 4: ¢ (daily backups + manual recovery)
```

---

## DR Runbook Template

### Runbook Structure

```markdown
# Disaster Recovery Runbook: [System Name]

## Document Control
- **Version**: 1.0
- **Last Updated**: YYYY-MM-DD
- **Owner**: [Team/Individual]
- **Review Frequency**: Quarterly
- **Next Review**: YYYY-MM-DD
- **Approver**: [VP Engineering / CTO]

## System Overview
- **Description**: [What this system does]
- **Tier**: [0-4]
- **RPO**: [target]
- **RTO**: [target]
- **Architecture**: [link to diagram]
- **Dependencies**: [upstream/downstream systems]

## Contact Information
| Role | Name | Phone | Email | Escalation |
|------|------|-------|-------|------------|
| Primary On-Call | [name] | [phone] | [email] | Pager |
| Backup On-Call | [name] | [phone] | [email] | Pager |
| DB Admin | [name] | [phone] | [email] | Phone |
| VP Engineering | [name] | [phone] | [email] | Phone/SMS |
| Cloud Provider Support | N/A | [number] | [email] | Portal |

## Pre-Requisites
- [ ] DR environment credentials available (location: [vault path])
- [ ] VPN access to DR site configured
- [ ] DNS management access confirmed
- [ ] Latest backup verified (check: [monitoring URL])

## Recovery Procedures
[See Step-by-Step Recovery Procedures section]

## Verification Steps
[See Data Consistency Verification section]

## Rollback Plan
[Steps to fail back to primary after DR event]

## Lessons Learned Log
| Date | Incident | Finding | Action | Status |
|------|----------|---------|--------|--------|
```

### Incident Declaration Criteria

```markdown
## When to Declare a DR Incident

### Automatic Declaration (immediate DR activation)
- Primary data center unreachable for > 15 minutes
- Primary database unrecoverable corruption detected
- Ransomware confirmed on production systems
- Cloud provider reports region-level outage

### Assessed Declaration (on-call judgment)
- Primary system degraded > 50% capacity for > 30 minutes
- Data inconsistency detected across multiple services
- Security breach requiring infrastructure isolation
- Hardware failure affecting multiple systems

### Escalation Path
1. On-call engineer assesses situation (0-15 min)
2. Incident commander notified if DR likely (15-30 min)
3. DR decision made by IC + VP Engineering (30-45 min)
4. DR activation begins (45+ min)
```

### Communication Plan

```markdown
## Communication During DR

### Internal Communication
- **Slack**: #incident-[number] channel (create immediately)
- **Status Page**: Update within 15 minutes of declaration
- **Email**: All-hands notification for Tier 0-1 systems
- **Bridge Call**: Zoom/Teams link: [URL]

### External Communication
- **Customers**: Status page update + email for service degradation
- **Partners**: Direct notification for API consumers
- **Regulators**: Notify within [X hours] per compliance requirements

### Communication Templates

#### Initial Notification
Subject: [DR ACTIVATED] [System Name] - [Date]
Body:
  We have declared a disaster recovery event for [System Name].
  Impact: [description of service impact]
  Current Status: DR activation in progress
  ETA for Recovery: [estimated time based on RTO]
  Next Update: [time]

#### Resolution Notification
Subject: [RESOLVED] [System Name] DR Event - [Date]
Body:
  The DR event for [System Name] has been resolved.
  Root Cause: [brief description]
  Data Loss: [amount, if any, relative to RPO]
  Recovery Time: [actual time vs RTO target]
  Post-mortem: Scheduled for [date]
```

### Step-by-Step Recovery Procedures

```bash
#!/bin/bash
# dr-recovery.sh — Automated DR recovery procedure
# This script implements the recovery runbook steps
# Run with: sudo ./dr-recovery.sh <system-name>
set -euo pipefail

SYSTEM="${1:?Usage: $0 <system-name>}"
DR_REGION="us-west-2"
PRIMARY_REGION="us-east-1"
LOG="/var/log/dr-recovery-$(date +%F-%H%M).log"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }
checkpoint() { log "CHECKPOINT: $*"; }

# Step 1: Verify DR environment
checkpoint "Verifying DR environment"
aws sts get-caller-identity --region "$DR_REGION" | tee -a "$LOG"
log "DR environment accessible"

# Step 2: Activate DR infrastructure
checkpoint "Activating DR infrastructure"
cd /infrastructure/terraform/dr
terraform init -backend-config="region=${DR_REGION}"
terraform apply -auto-approve -var="active=true" 2>&1 | tee -a "$LOG"
log "DR infrastructure activated"

# Step 3: Restore latest backup
checkpoint "Restoring database from latest backup"
LATEST_SNAPSHOT=$(aws rds describe-db-snapshots \
  --db-instance-identifier "prod-${SYSTEM}" \
  --query 'sort_by(DBSnapshots,&SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text --region "$PRIMARY_REGION")
log "Restoring from snapshot: $LATEST_SNAPSHOT"

aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "dr-${SYSTEM}" \
  --db-snapshot-identifier "$LATEST_SNAPSHOT" \
  --db-instance-class db.r6g.xlarge \
  --availability-zone "${DR_REGION}a" \
  --region "$DR_REGION" 2>&1 | tee -a "$LOG"

# Step 4: Wait for database
checkpoint "Waiting for database to become available"
aws rds wait db-instance-available \
  --db-instance-identifier "dr-${SYSTEM}" \
  --region "$DR_REGION"
log "Database available"

# Step 5: Update DNS
checkpoint "Updating DNS to DR environment"
# Update Route53 to point to DR
aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.company.com",
        "Type": "CNAME",
        "TTL": 60,
        "ResourceRecords": [{"Value": "dr-lb.us-west-2.elb.amazonaws.com"}]
      }
    }]
  }' 2>&1 | tee -a "$LOG"

# Step 6: Verify recovery
checkpoint "Verifying recovery"
sleep 60  # wait for DNS propagation
curl -sf https://api.company.com/health || {
  log "ERROR: Health check failed after DNS switch"
  exit 1
}
log "DR recovery COMPLETE"
checkpoint "Recovery verified — system operational in DR region"
```

---

## Failover Testing Procedures

### Test Types and Frequency

| Test Type | Description | Frequency | Duration | Risk |
|-----------|-------------|-----------|----------|------|
| Tabletop Exercise | Walk through runbook on paper | Monthly | 1-2 hours | None |
| Backup Restore Test | Restore backup to test env | Weekly | 1-4 hours | None |
| Component Failover | Fail one component (DB, app) | Monthly | 2-4 hours | Low |
| Partial DR Test | Activate DR for non-critical | Quarterly | 4-8 hours | Medium |
| Full DR Test | Complete failover and failback | Semi-annual | 8-24 hours | High |
| Chaos Engineering | Random failure injection | Continuous | Varies | Medium |

### Failover Test Checklist

```markdown
## Pre-Test
- [ ] Notify stakeholders of test window
- [ ] Confirm current backup is fresh (<1 hour old)
- [ ] Verify DR environment credentials
- [ ] Prepare rollback plan
- [ ] Set up monitoring for test metrics
- [ ] Brief participating team members

## During Test
- [ ] Record start time: __________
- [ ] Initiate failover per runbook
- [ ] Record time to first response: __________
- [ ] Monitor error rates during transition
- [ ] Verify data consistency after failover
- [ ] Test all critical user paths
- [ ] Record recovery completion time: __________
- [ ] Calculate actual RTO: __________
- [ ] Calculate actual RPO (data loss): __________

## Post-Test
- [ ] Initiate failback to primary
- [ ] Verify primary is fully operational
- [ ] Compare actual vs target RTO/RPO
- [ ] Document issues encountered
- [ ] Update runbook with findings
- [ ] File compliance evidence
- [ ] Schedule post-mortem if issues found
```

### Automated Failover Testing

```bash
#!/bin/bash
# dr-test.sh — Automated DR failover test
set -euo pipefail

TEST_ID="dr-test-$(date +%F-%H%M)"
REPORT="/var/log/dr-tests/${TEST_ID}.json"
mkdir -p /var/log/dr-tests

START_TIME=$(date +%s)

record_metric() {
  local key="$1" value="$2"
  jq --arg k "$key" --arg v "$value" '. + {($k): $v}' "$REPORT" > "${REPORT}.tmp"
  mv "${REPORT}.tmp" "$REPORT"
}

echo '{}' > "$REPORT"
record_metric "test_id" "$TEST_ID"
record_metric "start_time" "$(date -Is)"

# Test 1: Verify backup exists and is fresh
echo "Testing backup freshness..."
LAST_BACKUP=$(restic -r "$REPO" snapshots --latest 1 --json | jq -r '.[0].time')
BACKUP_AGE=$(($(date +%s) - $(date -d "$LAST_BACKUP" +%s)))
record_metric "backup_age_seconds" "$BACKUP_AGE"

if [ "$BACKUP_AGE" -gt 3600 ]; then
  record_metric "backup_freshness" "FAIL"
  echo "FAIL: Backup is too old (${BACKUP_AGE}s)"
else
  record_metric "backup_freshness" "PASS"
fi

# Test 2: Restore to test environment
echo "Testing restore..."
RESTORE_START=$(date +%s)
restic -r "$REPO" restore latest --target /tmp/dr-test-restore 2>&1
RESTORE_DURATION=$(($(date +%s) - RESTORE_START))
record_metric "restore_duration_seconds" "$RESTORE_DURATION"

# Test 3: Verify restored data
echo "Verifying data integrity..."
if [ -f /tmp/dr-test-restore/etc/hostname ]; then
  record_metric "data_integrity" "PASS"
else
  record_metric "data_integrity" "FAIL"
fi

# Test 4: Database restore test
echo "Testing database restore..."
DB_RESTORE_START=$(date +%s)
pg_restore -U postgres -d dr_test_db --clean --if-exists \
  /tmp/dr-test-restore/backup/prod.dump 2>/dev/null || true
DB_RESTORE_DURATION=$(($(date +%s) - DB_RESTORE_START))
record_metric "db_restore_duration_seconds" "$DB_RESTORE_DURATION"

# Verify row counts
EXPECTED_ROWS=1000
ACTUAL_ROWS=$(psql -U postgres -d dr_test_db -t -c "SELECT count(*) FROM users;" 2>/dev/null | tr -d ' ')
if [ "${ACTUAL_ROWS:-0}" -ge "$EXPECTED_ROWS" ]; then
  record_metric "db_data_validation" "PASS"
else
  record_metric "db_data_validation" "FAIL"
  record_metric "db_expected_rows" "$EXPECTED_ROWS"
  record_metric "db_actual_rows" "${ACTUAL_ROWS:-0}"
fi

# Cleanup
rm -rf /tmp/dr-test-restore
psql -U postgres -c "DROP DATABASE IF EXISTS dr_test_db;" 2>/dev/null

# Calculate total test duration
TOTAL_DURATION=$(($(date +%s) - START_TIME))
record_metric "total_duration_seconds" "$TOTAL_DURATION"
record_metric "end_time" "$(date -Is)"

echo "DR Test complete. Report: $REPORT"
cat "$REPORT" | jq .
```

---

## Data Consistency Verification

### Post-Restore Validation

```bash
#!/bin/bash
# verify-restore.sh — Post-restore data consistency checks

echo "=== Post-Restore Validation ==="

# 1. Row count comparison
echo "--- Row Count Check ---"
TABLES=(users orders products payments)
for table in "${TABLES[@]}"; do
  COUNT=$(psql -U postgres -d restored_db -t -c "SELECT count(*) FROM $table;" | tr -d ' ')
  EXPECTED=$(cat /backup/meta/row-counts.txt | grep "^$table" | awk '{print $2}')
  if [ "$COUNT" -eq "$EXPECTED" ]; then
    echo "  $table: OK ($COUNT rows)"
  else
    echo "  $table: MISMATCH (got $COUNT, expected $EXPECTED)"
  fi
done

# 2. Checksum comparison for critical tables
echo "--- Checksum Check ---"
CHECKSUM=$(psql -U postgres -d restored_db -t -c \
  "SELECT md5(string_agg(md5(t.*::text), '')) FROM (SELECT * FROM users ORDER BY id) t;")
EXPECTED_CHECKSUM=$(cat /backup/meta/checksums.txt | grep "^users" | awk '{print $2}')
[ "$CHECKSUM" = "$EXPECTED_CHECKSUM" ] && echo "  users: OK" || echo "  users: MISMATCH"

# 3. Foreign key integrity
echo "--- Referential Integrity ---"
ORPHANS=$(psql -U postgres -d restored_db -t -c "
  SELECT count(*) FROM orders o
  LEFT JOIN users u ON o.user_id = u.id
  WHERE u.id IS NULL;
" | tr -d ' ')
[ "$ORPHANS" -eq 0 ] && echo "  FK integrity: OK" || echo "  FK integrity: $ORPHANS orphans"

# 4. Timestamp sanity check
echo "--- Timestamp Sanity ---"
LATEST=$(psql -U postgres -d restored_db -t -c \
  "SELECT max(updated_at) FROM orders;" | tr -d ' ')
echo "  Latest record: $LATEST"
echo "  Backup taken: $(cat /backup/meta/backup-time.txt)"
```

### Cross-Service Consistency Checks

```bash
# Verify consistency across multiple databases restored to the same point
echo "=== Cross-Service Consistency ==="

# Orders in orders_db should match payments in payments_db
ORDER_COUNT=$(psql -U postgres -d orders_db -t -c \
  "SELECT count(*) FROM orders WHERE status='paid' AND created_at > '2024-01-01';" | tr -d ' ')
PAYMENT_COUNT=$(psql -U postgres -d payments_db -t -c \
  "SELECT count(*) FROM payments WHERE status='completed' AND created_at > '2024-01-01';" | tr -d ' ')

DIFF=$((ORDER_COUNT - PAYMENT_COUNT))
if [ "${DIFF#-}" -le 5 ]; then
  echo "Orders vs Payments: OK (diff: $DIFF within tolerance)"
else
  echo "Orders vs Payments: MISMATCH (orders: $ORDER_COUNT, payments: $PAYMENT_COUNT)"
fi
```

### Automated Verification Scripts

```bash
# Record verification metadata during backup
#!/bin/bash
# backup-metadata.sh — Run during backup to record verification data
META_DIR="/backup/meta"
mkdir -p "$META_DIR"

# Record timestamp
date -Is > "$META_DIR/backup-time.txt"

# Record row counts
psql -U postgres -d production -t -c "
  SELECT schemaname || '.' || relname || ' ' || n_live_tup
  FROM pg_stat_user_tables ORDER BY relname;
" > "$META_DIR/row-counts.txt"

# Record checksums for critical tables
for table in users orders payments; do
  CHECKSUM=$(psql -U postgres -d production -t -c \
    "SELECT md5(string_agg(md5(t.*::text), '')) FROM (SELECT * FROM $table ORDER BY id) t;")
  echo "$table $CHECKSUM" >> "$META_DIR/checksums.txt"
done

# Record schema version
psql -U postgres -d production -t -c \
  "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;" \
  > "$META_DIR/schema-version.txt"
```

---

## Point-in-Time Recovery Workflows

### PostgreSQL PITR

```bash
# === PostgreSQL Point-in-Time Recovery ===

# Pre-requisite: WAL archiving must be configured
# postgresql.conf:
#   wal_level = replica
#   archive_mode = on
#   archive_command = 'test ! -f /backup/wal/%f && cp %p /backup/wal/%f'

# Step 1: Identify the target recovery point
# Find the time just before the incident
psql -U postgres -c "SELECT pg_current_wal_lsn(), now();"
# Check the logs for the problematic transaction time

# Step 2: Stop PostgreSQL
systemctl stop postgresql

# Step 3: Preserve current data directory (safety)
mv /var/lib/postgresql/15/main /var/lib/postgresql/15/main.broken

# Step 4: Restore base backup
tar xzf /backup/base/2024-01-15/base.tar.gz -C /var/lib/postgresql/15/main

# Step 5: Configure recovery
cat >> /var/lib/postgresql/15/main/postgresql.auto.conf << EOF
restore_command = 'cp /backup/wal/%f %p'
recovery_target_time = '2024-01-15 14:30:00 UTC'
recovery_target_action = 'pause'
EOF

# Step 6: Create recovery signal file
touch /var/lib/postgresql/15/main/recovery.signal

# Step 7: Fix permissions and start
chown -R postgres:postgres /var/lib/postgresql/15/main
systemctl start postgresql

# Step 8: Verify recovery point
psql -U postgres -c "SELECT pg_is_in_recovery(), pg_last_xact_replay_timestamp();"

# Step 9: Accept the recovery point (resume normal operations)
psql -U postgres -c "SELECT pg_wal_replay_resume();"
```

### MySQL PITR

```bash
# === MySQL Point-in-Time Recovery with Binary Logs ===

# Pre-requisite: binary logging enabled
# my.cnf: log_bin = mysql-bin

# Step 1: Identify binlog position before incident
mysqlbinlog --start-datetime="2024-01-15 14:00:00" \
  --stop-datetime="2024-01-15 14:35:00" \
  /var/log/mysql/mysql-bin.000042 | grep -B5 "DROP TABLE"
# Note the position just before the bad statement

# Step 2: Restore the full backup
mysql -u root -p < /backup/full-2024-01-15.sql

# Step 3: Replay binary logs up to the incident
mysqlbinlog --stop-position=12345 /var/log/mysql/mysql-bin.000042 | mysql -u root -p

# Step 4: If needed, skip the bad event and replay the rest
mysqlbinlog --start-position=12400 /var/log/mysql/mysql-bin.000042 | mysql -u root -p
```

### MongoDB PITR

```bash
# === MongoDB Point-in-Time Recovery with Oplog ===

# Step 1: Restore the base dump with oplog
mongorestore --oplogReplay --gzip /backup/mongo-2024-01-15/

# Step 2: For more precise PITR, replay oplog to specific timestamp
# Dump the oplog
mongodump --db local --collection oplog.rs --out /tmp/oplog-dump/

# Step 3: Replay oplog entries up to target timestamp
mongorestore --oplogReplay \
  --oplogLimit "$(date -d '2024-01-15 14:30:00' +%s):1" \
  /tmp/oplog-dump/

# Step 4: Verify data state
mongosh --eval "db.orders.find().sort({_id: -1}).limit(5)"
```

---

## Cross-Cloud DR

### DR Architecture Patterns

```
Pattern 1: Pilot Light (Cost: $, RTO: 1-4h)
┌──────────────────┐          ┌──────────────────┐
│   PRIMARY (AWS)  │          │    DR (GCP)       │
│ ┌──────────────┐ │  replicate│ ┌──────────────┐ │
│ │ App (active) │ │ ────────→│ │ DB replica   │ │
│ │ DB (active)  │ │          │ │ (warm)       │ │
│ │ Cache        │ │          │ │              │ │
│ └──────────────┘ │          │ └──────────────┘ │
└──────────────────┘          └──────────────────┘
On failover: provision app servers, point DNS

Pattern 2: Warm Standby (Cost: $$, RTO: 15-60m)
┌──────────────────┐          ┌──────────────────┐
│   PRIMARY (AWS)  │          │    DR (GCP)       │
│ ┌──────────────┐ │  replicate│ ┌──────────────┐ │
│ │ App (active) │ │ ────────→│ │ App (standby)│ │
│ │ DB (active)  │ │          │ │ DB (replica) │ │
│ │ Cache        │ │          │ │ Cache (warm) │ │
│ └──────────────┘ │          │ └──────────────┘ │
└──────────────────┘          └──────────────────┘
On failover: promote DB, start app, point DNS

Pattern 3: Active-Active (Cost: $$$, RTO: <5m)
┌──────────────────┐          ┌──────────────────┐
│   REGION A (AWS) │  bi-dir   │   REGION B (GCP) │
│ ┌──────────────┐ │ ←──────→ │ ┌──────────────┐ │
│ │ App (active) │ │          │ │ App (active) │ │
│ │ DB (active)  │ │          │ │ DB (active)  │ │
│ │ Cache        │ │          │ │ Cache        │ │
│ └──────────────┘ │          │ └──────────────┘ │
└──────────────────┘          └──────────────────┘
Global load balancer routes traffic to both
```

### Multi-Cloud Data Replication

```bash
# AWS to GCP database replication using logical replication
# On AWS (publisher):
psql -U postgres -c "
  CREATE PUBLICATION dr_pub FOR ALL TABLES;
"

# On GCP (subscriber):
psql -U postgres -c "
  CREATE SUBSCRIPTION dr_sub
  CONNECTION 'host=aws-db.example.com port=5432 dbname=prod user=repl password=secret sslmode=require'
  PUBLICATION dr_pub;
"

# File-based replication with rclone
rclone sync aws-s3:prod-backups gcs:dr-backups \
  --transfers 32 \
  --checkers 64 \
  --fast-list \
  --log-file /var/log/rclone-dr.log \
  --log-level INFO
```

### DNS Failover Strategies

```bash
# Route53 health check + failover routing
aws route53 create-health-check --caller-reference "$(date +%s)" \
  --health-check-config '{
    "IPAddress": "1.2.3.4",
    "Port": 443,
    "Type": "HTTPS",
    "ResourcePath": "/health",
    "FullyQualifiedDomainName": "api.company.com",
    "RequestInterval": 10,
    "FailureThreshold": 3
  }'

# Primary record (failover routing)
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.company.com",
        "Type": "A",
        "SetIdentifier": "primary",
        "Failover": "PRIMARY",
        "AliasTarget": {
          "HostedZoneId": "'$ALB_ZONE'",
          "DNSName": "'$PRIMARY_ALB'",
          "EvaluateTargetHealth": true
        },
        "HealthCheckId": "'$HC_ID'"
      }
    }]
  }'
```

---

## DR Automation with Terraform

### Infrastructure-as-Code DR

```hcl
# terraform/modules/dr/main.tf

variable "dr_active" {
  description = "Whether DR environment is active"
  type        = bool
  default     = false
}

variable "primary_region" {
  default = "us-east-1"
}

variable "dr_region" {
  default = "us-west-2"
}

# DR database (always provisioned, but minimal when inactive)
resource "aws_db_instance" "dr_database" {
  identifier     = "dr-production"
  instance_class = var.dr_active ? "db.r6g.xlarge" : "db.t3.micro"
  engine         = "postgres"
  engine_version = "15.4"

  replicate_source_db = var.dr_active ? null : aws_db_instance.primary.arn

  multi_az          = var.dr_active
  storage_encrypted = true

  tags = {
    Environment = "dr"
    ManagedBy   = "terraform"
  }
}

# Application servers (only when DR is active)
resource "aws_autoscaling_group" "dr_app" {
  count = var.dr_active ? 1 : 0

  name                = "dr-app-asg"
  min_size            = 2
  max_size            = 10
  desired_capacity    = 4
  vpc_zone_identifier = var.dr_subnet_ids

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
}

# DNS failover (always configured)
resource "aws_route53_record" "api_primary" {
  zone_id = var.zone_id
  name    = "api.company.com"
  type    = "A"

  set_identifier = "primary"
  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = aws_lb.primary.dns_name
    zone_id                = aws_lb.primary.zone_id
    evaluate_target_health = true
  }

  health_check_id = aws_route53_health_check.primary.id
}

resource "aws_route53_record" "api_dr" {
  zone_id = var.zone_id
  name    = "api.company.com"
  type    = "A"

  set_identifier = "secondary"
  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = var.dr_active ? aws_lb.dr[0].dns_name : ""
    zone_id                = var.dr_active ? aws_lb.dr[0].zone_id : ""
    evaluate_target_health = true
  }
}
```

### Terraform DR Module Pattern

```hcl
# terraform/environments/dr/main.tf

module "dr" {
  source = "../../modules/dr"

  dr_active      = var.activate_dr
  primary_region = "us-east-1"
  dr_region      = "us-west-2"

  db_snapshot_id = var.db_snapshot_id
  vpc_id         = module.networking.vpc_id
  subnet_ids     = module.networking.private_subnet_ids
  zone_id        = data.aws_route53_zone.main.zone_id
}

# Terraform state backup (critical for DR)
terraform {
  backend "s3" {
    bucket         = "terraform-state-dr"
    key            = "dr/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true

    # Cross-region replication enabled on this bucket
  }
}
```

### Automated Failover with Terraform

```bash
#!/bin/bash
# terraform-dr-failover.sh — Activate DR with Terraform
set -euo pipefail

DR_DIR="/infrastructure/terraform/environments/dr"
LOG="/var/log/dr-failover-$(date +%F-%H%M).log"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }

log "Starting DR failover with Terraform"

cd "$DR_DIR"

# Get latest DB snapshot from primary region
SNAPSHOT_ID=$(aws rds describe-db-snapshots \
  --db-instance-identifier prod-db \
  --query 'sort_by(DBSnapshots,&SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text --region us-east-1)

log "Using DB snapshot: $SNAPSHOT_ID"

# Activate DR
terraform apply -auto-approve \
  -var="activate_dr=true" \
  -var="db_snapshot_id=$SNAPSHOT_ID" \
  2>&1 | tee -a "$LOG"

log "DR failover complete"

# Verify
DR_ENDPOINT=$(terraform output -raw dr_api_endpoint)
curl -sf "$DR_ENDPOINT/health" && log "DR health check PASSED" || log "DR health check FAILED"
```

---

## Tabletop Exercises

### Exercise Planning

```markdown
## Tabletop Exercise Planning Guide

### Preparation (1-2 weeks before)
1. Select scenario from Scenario Library
2. Identify participants (on-call, DBAs, management, comms)
3. Prepare scenario briefing document
4. Reserve conference room / video call
5. Designate facilitator and scribe
6. Print/share relevant runbooks

### During Exercise (1-2 hours)
1. Facilitator presents scenario (10 min)
2. Team discusses detection: "How would we know?" (15 min)
3. Team walks through response: "What do we do?" (30 min)
4. Facilitator introduces complications (15 min)
5. Team discusses communication plan (10 min)
6. Debrief and identify gaps (20 min)

### After Exercise
1. Scribe publishes findings within 48 hours
2. Create action items with owners and deadlines
3. Update runbooks with identified gaps
4. Schedule follow-up for action items
5. File exercise report for compliance evidence
```

### Scenario Library

```markdown
## DR Tabletop Scenarios

### Scenario 1: Database Corruption
"A developer accidentally ran DELETE FROM orders WHERE 1=1 in production
at 2:47 PM. The on-call is paged at 2:55 PM when monitoring detects
zero orders in the last 10 minutes."
- When do we realize the scope of the problem?
- What's our recovery path? PITR or restore from backup?
- How much data do we lose? What's our actual RPO?
- Who communicates to customers?

### Scenario 2: Ransomware Attack
"At 3 AM Saturday, the monitoring system detects that backup files in
the primary S3 bucket are being encrypted. Investigation reveals
compromised IAM credentials. The attack has been running for 6 hours."
- Are our backups safe? Which ones?
- Do we have immutable backups?
- How do we isolate the blast radius?
- When do we involve law enforcement?

### Scenario 3: Cloud Region Outage
"AWS us-east-1 experiences a complete outage. All services in the region
are unreachable. AWS reports ETA of 4-8 hours for recovery."
- Can we fail over to another region?
- How long will failover take?
- What data might we lose?
- What manual steps are needed?

### Scenario 4: Backup System Failure
"The backup monitoring alerts that no successful backup has run in
72 hours. Investigation reveals the backup storage is full and the
alerting for storage was misconfigured."
- How much data exposure do we have?
- Can we recover the backup system quickly?
- What's the blast radius if we lose data from the last 72 hours?
- How do we prevent this in the future?

### Scenario 5: Insider Threat
"A departing employee with admin access has deleted the primary database,
the backup repository, and rotated the backup encryption keys before
their access was revoked."
- Do we have offline/air-gapped backups?
- Can we recover encryption keys?
- What access controls failed?
- How do we handle the HR/legal aspects?
```

### Post-Exercise Review

```markdown
## Post-Exercise Review Template

### Exercise Summary
- **Date**: YYYY-MM-DD
- **Scenario**: [scenario name]
- **Participants**: [list]
- **Duration**: [time]

### Findings

#### What Went Well
1. [finding]
2. [finding]

#### Gaps Identified
| # | Gap | Severity | Owner | Action | Deadline |
|---|-----|----------|-------|--------|----------|
| 1 | [gap] | High | [owner] | [action] | [date] |
| 2 | [gap] | Medium | [owner] | [action] | [date] |

#### Runbook Updates Needed
- [ ] [specific update]
- [ ] [specific update]

#### Metrics
- **Estimated RTO**: [time] (target: [time])
- **Estimated RPO**: [data loss] (target: [data loss])
- **Detection Time**: [time]
- **Decision Time**: [time]
```

---

## Compliance Requirements

### SOC 2 Backup Controls

SOC 2 Trust Services Criteria relevant to backup:

| Control ID | Requirement | Evidence |
|------------|------------|----------|
| CC6.1 | Logical and physical access controls for backup systems | IAM policies, encryption config |
| CC7.2 | Monitor backup systems for anomalies | Monitoring dashboards, alert configs |
| CC7.3 | Evaluate and respond to backup failures | Incident response procedures |
| CC7.4 | Respond to identified backup vulnerabilities | Patch management records |
| A1.2 | Recovery procedures documented and tested | DR runbooks, test reports |
| A1.3 | Recovery testing performed periodically | Test results, compliance evidence |

**SOC 2 backup evidence checklist:**
```markdown
- [ ] Documented backup policy (retention, frequency, encryption)
- [ ] Automated backup schedules with monitoring
- [ ] Backup encryption at rest and in transit
- [ ] Access controls on backup systems (principle of least privilege)
- [ ] Quarterly backup restore tests with documented results
- [ ] Annual DR failover test with documented results
- [ ] Backup monitoring and alerting configuration
- [ ] Change management for backup infrastructure
- [ ] Backup retention compliance (per policy)
- [ ] Immutable/WORM backup for critical data
```

### HIPAA Backup Requirements

HIPAA Security Rule requirements for backup (45 CFR §164.308, §164.310, §164.312):

| Requirement | HIPAA Reference | Implementation |
|-------------|----------------|----------------|
| Data backup plan | §164.308(a)(7)(ii)(A) | Documented backup procedures |
| Disaster recovery plan | §164.308(a)(7)(ii)(B) | DR runbooks, tested annually |
| Emergency mode operation | §164.308(a)(7)(ii)(C) | Procedures for critical operations during DR |
| Testing and revision | §164.308(a)(7)(ii)(D) | Periodic testing, update procedures |
| Encryption | §164.312(a)(2)(iv) | AES-256 for PHI at rest and in transit |
| Access controls | §164.312(a)(1) | Role-based access to backup systems |
| Audit controls | §164.312(b) | Logging of backup access and operations |
| Integrity controls | §164.312(c)(1) | Checksums, integrity verification |
| Transmission security | §164.312(e)(1) | TLS/SSH for backup data in transit |

**HIPAA-specific backup requirements:**
```bash
# All backups containing PHI must be encrypted
# AES-256 encryption is required
restic -r "$REPO" backup /var/lib/health-records
# restic always encrypts with AES-256 ✓

# Backup access must be logged
# Enable CloudTrail for S3 backup bucket
aws cloudtrail create-trail --name backup-audit-trail \
  --s3-bucket-name audit-logs \
  --include-global-service-events

# Backup retention must meet minimum requirements (6 years for HIPAA)
restic forget --keep-yearly 7  # 7 years retention

# Access to backup systems requires unique user IDs
# No shared credentials for backup operations
```

### Compliance Evidence Collection

```bash
#!/bin/bash
# compliance-evidence.sh — Generate compliance evidence report
set -euo pipefail

REPORT_DIR="/var/log/compliance/$(date +%Y-%m)"
mkdir -p "$REPORT_DIR"

echo "=== Compliance Evidence Report ===" > "$REPORT_DIR/report.txt"
echo "Generated: $(date -Is)" >> "$REPORT_DIR/report.txt"

# 1. Backup schedule evidence
echo -e "\n--- Backup Schedule ---" >> "$REPORT_DIR/report.txt"
systemctl list-timers --all | grep backup >> "$REPORT_DIR/report.txt" 2>/dev/null
crontab -l 2>/dev/null | grep backup >> "$REPORT_DIR/report.txt"

# 2. Backup success/failure log
echo -e "\n--- Backup Results (Last 30 days) ---" >> "$REPORT_DIR/report.txt"
journalctl -u restic-backup.service --since "30 days ago" --no-pager | \
  grep -E "(Started|Succeeded|Failed)" >> "$REPORT_DIR/report.txt"

# 3. Encryption verification
echo -e "\n--- Encryption Status ---" >> "$REPORT_DIR/report.txt"
restic -r "$REPO" cat config 2>/dev/null | jq '.chunker_polynomial' >> "$REPORT_DIR/report.txt"
echo "Repository is encrypted: YES (restic default)" >> "$REPORT_DIR/report.txt"

# 4. Access control evidence
echo -e "\n--- Access Controls ---" >> "$REPORT_DIR/report.txt"
aws s3api get-bucket-policy --bucket "$BACKUP_BUCKET" >> "$REPORT_DIR/report.txt" 2>/dev/null
aws s3api get-bucket-encryption --bucket "$BACKUP_BUCKET" >> "$REPORT_DIR/report.txt" 2>/dev/null

# 5. DR test results
echo -e "\n--- DR Test Results ---" >> "$REPORT_DIR/report.txt"
ls -la /var/log/dr-tests/ >> "$REPORT_DIR/report.txt" 2>/dev/null
cat /var/log/dr-tests/latest.json >> "$REPORT_DIR/report.txt" 2>/dev/null

# 6. Retention policy evidence
echo -e "\n--- Retention Policy ---" >> "$REPORT_DIR/report.txt"
restic -r "$REPO" snapshots --json 2>/dev/null | \
  jq '[.[].time | split("T")[0]] | sort | {oldest: first, newest: last, count: length}' \
  >> "$REPORT_DIR/report.txt"

echo "Report generated: $REPORT_DIR/report.txt"
```
