# Advanced Backup Patterns

> Deep-dive into advanced backup strategies for production infrastructure: deduplication internals,
> pipeline orchestration, immutable storage, microservices backup, and large-dataset techniques.

## Table of Contents

- [Deduplication Strategies](#deduplication-strategies)
  - [Content-Defined Chunking (CDC)](#content-defined-chunking-cdc)
  - [Restic Chunking Implementation](#restic-chunking-implementation)
  - [BorgBackup Chunking Implementation](#borgbackup-chunking-implementation)
  - [Deduplication Ratio Optimization](#deduplication-ratio-optimization)
- [Backup Pipeline Orchestration](#backup-pipeline-orchestration)
  - [Pipeline Architecture](#pipeline-architecture)
  - [Orchestration with borgmatic](#orchestration-with-borgmatic)
  - [CI/CD-Integrated Backup Pipelines](#cicd-integrated-backup-pipelines)
  - [Multi-Stage Pipeline Example](#multi-stage-pipeline-example)
- [Cross-Region Replication](#cross-region-replication)
  - [Active-Passive Replication](#active-passive-replication)
  - [S3 Cross-Region Replication](#s3-cross-region-replication)
  - [Rclone-Based Replication](#rclone-based-replication)
- [Immutable Backups](#immutable-backups)
  - [S3 Object Lock and WORM](#s3-object-lock-and-worm)
  - [Borg Append-Only Mode](#borg-append-only-mode)
  - [Restic with Immutable Storage](#restic-with-immutable-storage)
  - [MinIO Object Lock](#minio-object-lock)
- [Backup for Microservices](#backup-for-microservices)
  - [Per-Service vs Coordinated Backup](#per-service-vs-coordinated-backup)
  - [Coordinated Snapshot Strategy](#coordinated-snapshot-strategy)
  - [Service Mesh Considerations](#service-mesh-considerations)
- [Kubernetes Backup Patterns](#kubernetes-backup-patterns)
  - [etcd Backup](#etcd-backup)
  - [etcd Restore Procedure](#etcd-restore-procedure)
  - [Velero Advanced Patterns](#velero-advanced-patterns)
- [Secrets and Vault Backup](#secrets-and-vault-backup)
  - [HashiCorp Vault Backup](#hashicorp-vault-backup)
  - [Kubernetes Secrets Backup](#kubernetes-secrets-backup)
- [GitOps State Backup](#gitops-state-backup)
  - [ArgoCD State Backup](#argocd-state-backup)
  - [Flux State Backup](#flux-state-backup)
- [Large Dataset Strategies](#large-dataset-strategies)
  - [Parallel Backup Streams](#parallel-backup-streams)
  - [Incremental Forever](#incremental-forever)
  - [Block-Level Backup](#block-level-backup)
  - [Bandwidth and Resource Management](#bandwidth-and-resource-management)

---

## Deduplication Strategies

### Content-Defined Chunking (CDC)

CDC splits data into variable-sized chunks based on content fingerprints rather than fixed
byte offsets. This is critical for backup deduplication because insertions or deletions in
a file only affect the chunks near the change—not the entire file.

**How CDC works:**
1. A rolling hash (e.g., Rabin fingerprint, Buzhash) slides over the byte stream
2. When the hash value matches a boundary condition (e.g., lowest N bits are zero), a chunk boundary is set
3. The resulting chunks are content-addressed (SHA-256 or similar) and stored only once

**Why CDC outperforms fixed-size chunking:**
```
Fixed chunking (4KB blocks):
  File v1: [block1][block2][block3][block4]
  File v2: [block1][MODIFIED_block2][block3_shifted][block4_shifted]
  → 3 new blocks stored (shift cascades)

Content-defined chunking:
  File v1: [chunk_a][chunk_b][chunk_c][chunk_d]
  File v2: [chunk_a][MODIFIED_chunk_b][chunk_c][chunk_d]
  → Only 1 new chunk stored (boundaries self-align)
```

**Key parameters:**
- **Minimum chunk size**: Prevents excessively small chunks (typically 512B–1KB)
- **Maximum chunk size**: Upper bound to prevent huge chunks (typically 8MB)
- **Average chunk size**: Target average, controlled by the bitmask width (typically 1–8MB)
- **Window size**: Rolling hash window (typically 48–64 bytes)

### Restic Chunking Implementation

Restic uses Rabin fingerprints with content-defined chunking:
- Default chunk size: min 512KB, max 8MB, target average ~1MB
- Polynomial-based rolling hash for boundary detection
- SHA-256 for chunk addressing after boundary determination
- All chunks encrypted with AES-256-CTR + Poly1305 before storage
- Pack files group multiple chunks into larger blobs (reducing small-object overhead on backends)

```bash
# Restic automatically handles chunking — no user configuration needed
# View chunking statistics after a backup
restic -r /backup/repo stats --mode raw-data

# Check pack file efficiency
restic -r /backup/repo stats --mode blobs-per-file
```

### BorgBackup Chunking Implementation

Borg uses Buzhash rolling hash with configurable chunk parameters:
- Default: min 256KB (`CHUNK_MIN_EXP=19`), max 2MB (`CHUNK_MAX_EXP=23`)
- Configurable at repository init time
- Global chunk index enables cross-archive deduplication
- Chunks compressed (lz4/zstd/zlib/lzma) then optionally encrypted (AES-256-CTR)

```bash
# Initialize with custom chunker parameters
# Larger chunks = less metadata overhead but lower dedup ratio
borg init --encryption=repokey-blake2 \
  --chunker-params=buzhash,19,23,21,4095 /backup/borg-repo
# Parameters: algorithm, min_exp, max_exp, hash_mask_bits, hash_window_size

# View deduplication statistics
borg info /backup/borg-repo

# Check specific archive dedup efficiency
borg info /backup/borg-repo::archive-name
# Shows: Original size, Deduplicated size, Unique data
```

### Deduplication Ratio Optimization

**Strategies to maximize deduplication:**

| Strategy | Impact | Notes |
|----------|--------|-------|
| Exclude cache/temp files | High | `.cache/`, `node_modules/`, `__pycache__/` |
| Exclude generated files | High | Build artifacts, compiled objects |
| Consistent file ordering | Medium | Sort file lists before archiving |
| Avoid compressing before backup | Critical | Pre-compressed files break CDC |
| Tune chunk size for workload | Medium | Smaller chunks = better dedup but more metadata |
| Use same repo for similar hosts | High | Cross-host dedup (Borg excels here) |

**Anti-patterns that kill deduplication:**
- Compressing or encrypting files before feeding to the backup tool
- Using `tar.gz` archives as backup input (opaque blobs)
- Frequently changing binary files (databases, VM images) without snapshot support
- Re-encoding media files with different parameters

---

## Backup Pipeline Orchestration

### Pipeline Architecture

A production backup pipeline consists of sequential stages with error handling:

```
┌─────────┐   ┌──────────┐   ┌───────────┐   ┌────────────┐   ┌──────────┐
│ Pre-hook │ → │ Snapshot  │ → │  Backup   │ → │ Retention  │ → │ Verify   │
│ (quiesce)│   │ (freeze) │   │ (transfer)│   │ (prune)    │   │ (check)  │
└─────────┘   └──────────┘   └───────────┘   └────────────┘   └──────────┘
     │              │              │               │               │
     └──────────────┴──────────────┴───────────────┴───────────────┘
                              Notify (success/failure)
```

### Orchestration with borgmatic

borgmatic wraps BorgBackup with YAML-driven pipeline configuration:

```yaml
# /etc/borgmatic/config.yaml
source_directories:
  - /etc
  - /home
  - /var/lib/postgresql

repositories:
  - path: ssh://backup@remote:22/./borg-repo
    label: offsite
  - path: /mnt/usb-backup/borg-repo
    label: local

storage:
  compression: zstd,3
  encryption_passcommand: cat /etc/borg-passphrase

retention:
  keep_hourly: 24
  keep_daily: 7
  keep_weekly: 4
  keep_monthly: 12
  keep_yearly: 3

hooks:
  before_backup:
    - echo "Starting backup at $(date)"
    - pg_dump -U postgres -Fc production > /tmp/prod.dump
  after_backup:
    - rm -f /tmp/prod.dump
    - echo "Backup completed at $(date)"
  on_error:
    - curl -s -X POST "$SLACK_WEBHOOK" -d '{"text":"❌ Backup FAILED on '$(hostname)'"}'
  healthchecks:
    ping_url: https://hc-ping.com/YOUR-UUID

consistency:
  checks:
    - name: repository
      frequency: 1 week
    - name: archives
      frequency: 1 month
```

### CI/CD-Integrated Backup Pipelines

For GitOps-managed infrastructure, integrate backup validation into CI:

```yaml
# .github/workflows/backup-validation.yml
name: Backup Validation
on:
  schedule:
    - cron: '0 6 * * 1'  # Weekly Monday 6AM
jobs:
  validate:
    runs-on: self-hosted
    steps:
      - name: Check backup freshness
        run: |
          LAST=$(restic -r "$REPO" snapshots --latest 1 --json | jq -r '.[0].time')
          AGE_H=$(( ($(date +%s) - $(date -d "$LAST" +%s)) / 3600 ))
          [ "$AGE_H" -lt 26 ] || exit 1

      - name: Test restore
        run: |
          restic -r "$REPO" restore latest --target /tmp/restore-test
          test -f /tmp/restore-test/etc/hostname
          rm -rf /tmp/restore-test

      - name: Verify integrity
        run: restic -r "$REPO" check
```

### Multi-Stage Pipeline Example

```bash
#!/bin/bash
# Multi-stage backup pipeline with error handling and notifications
set -euo pipefail

STAGES=("pre_hook" "database_dump" "filesystem_backup" "retention" "verify" "replicate")
CURRENT_STAGE=""

cleanup() {
  if [ $? -ne 0 ]; then
    notify_failure "$CURRENT_STAGE"
  fi
  rm -f /tmp/*.dump 2>/dev/null
}
trap cleanup EXIT

for stage in "${STAGES[@]}"; do
  CURRENT_STAGE="$stage"
  log "Starting stage: $stage"

  case "$stage" in
    pre_hook)      quiesce_applications ;;
    database_dump) dump_databases ;;
    filesystem_backup) run_restic_backup ;;
    retention)     apply_retention_policy ;;
    verify)        verify_backup_integrity ;;
    replicate)     replicate_to_secondary ;;
  esac

  log "Completed stage: $stage"
done

notify_success
```

---

## Cross-Region Replication

### Active-Passive Replication

Maintain a secondary backup repository in a different geographic region:

```bash
# Primary backup to local/regional storage
restic -r s3:s3.us-east-1.amazonaws.com/backups-primary backup /data

# Replicate to secondary region using restic copy
restic -r s3:s3.us-east-1.amazonaws.com/backups-primary \
  copy --repo2 s3:s3.eu-west-1.amazonaws.com/backups-secondary

# Or use rclone for backend-agnostic replication
rclone sync s3:backups-primary s3-eu:backups-secondary \
  --transfers 16 --checkers 32 --fast-list
```

### S3 Cross-Region Replication

Native AWS CRR for automatic replication:

```bash
# Enable versioning (required for CRR)
aws s3api put-bucket-versioning \
  --bucket backups-primary \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-versioning \
  --bucket backups-secondary \
  --versioning-configuration Status=Enabled

# Configure replication
aws s3api put-bucket-replication --bucket backups-primary \
  --replication-configuration '{
    "Role": "arn:aws:iam::ACCOUNT:role/s3-replication-role",
    "Rules": [{
      "Status": "Enabled",
      "Priority": 1,
      "Filter": {"Prefix": ""},
      "Destination": {
        "Bucket": "arn:aws:s3:::backups-secondary",
        "StorageClass": "STANDARD_IA"
      },
      "DeleteMarkerReplication": {"Status": "Enabled"}
    }]
  }'
```

### Rclone-Based Replication

Cross-cloud replication using rclone:

```bash
# Replicate from AWS S3 to Google Cloud Storage
rclone sync aws-s3:backups gcs:backups-dr \
  --transfers 32 \
  --checkers 64 \
  --fast-list \
  --s3-upload-concurrency 8 \
  --log-file /var/log/rclone-replicate.log \
  --log-level INFO

# Replicate from AWS S3 to Azure Blob
rclone sync aws-s3:backups azure:backups-dr \
  --transfers 16 \
  --bwlimit "08:00,10M 23:00,off"  # Rate-limit during business hours
```

---

## Immutable Backups

### S3 Object Lock and WORM

Object Lock prevents deletion or modification for a defined retention period:

```bash
# Create bucket with Object Lock enabled (must be set at creation)
aws s3api create-bucket \
  --bucket immutable-backups \
  --object-lock-enabled-for-object-store

# Set default retention (Governance or Compliance mode)
aws s3api put-object-lock-configuration \
  --bucket immutable-backups \
  --object-lock-configuration '{
    "ObjectLockEnabled": "Enabled",
    "Rule": {
      "DefaultRetention": {
        "Mode": "COMPLIANCE",
        "Days": 365
      }
    }
  }'
# COMPLIANCE mode: Nobody can delete or shorten retention, not even root
# GOVERNANCE mode: Users with s3:BypassGovernanceRetention can override
```

**Compliance vs Governance mode:**

| Feature | Compliance | Governance |
|---------|-----------|------------|
| Override by admin | No | Yes (with permission) |
| Shorten retention | No | Yes (with permission) |
| Delete object | No until expiry | Yes with bypass |
| Use case | Regulatory (HIPAA, SEC) | Ransomware protection |

### Borg Append-Only Mode

Restrict the backup server to only accept new data:

```bash
# On the backup server, restrict the SSH key in authorized_keys:
command="borg serve --restrict-to-path /backup/borg-repo --append-only",\
restrict ssh-ed25519 AAAA... backup@client

# The client can create archives but cannot delete or prune
# Pruning must be done by an admin directly on the server
```

### Restic with Immutable Storage

```bash
# Use restic with an S3 bucket that has Object Lock
restic -r s3:s3.amazonaws.com/immutable-backups init

# Backups are automatically protected by Object Lock
restic -r s3:s3.amazonaws.com/immutable-backups backup /data

# For forget/prune, use a separate role with bypass permissions
# Or use Governance mode and a dedicated prune service account
```

### MinIO Object Lock

On-premises immutable storage with MinIO:

```bash
# Create bucket with object locking
mc mb --with-lock minio/immutable-backups

# Set default retention
mc retention set --default COMPLIANCE 90d minio/immutable-backups

# Use with restic
restic -r s3:http://minio.internal:9000/immutable-backups init
```

---

## Backup for Microservices

### Per-Service vs Coordinated Backup

**Per-service backup** (recommended for most cases):
- Each service owns its backup lifecycle
- Backup schedules match service RPO requirements
- Services use sidecar or init containers for backup agents
- Works well when services have independent datastores

**Coordinated backup** (needed for cross-service consistency):
- Required when services share transactions or eventual consistency windows matter
- Uses a central orchestrator to coordinate quiesce → snapshot → resume
- More complex but ensures cross-service data consistency

```yaml
# Per-service backup annotation for a Kubernetes operator
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    backup.company.io/enabled: "true"
    backup.company.io/schedule: "0 */6 * * *"
    backup.company.io/type: "postgres"
    backup.company.io/retention: "7d"
```

### Coordinated Snapshot Strategy

For services that require cross-service consistency:

```bash
#!/bin/bash
# Coordinated multi-service backup
set -euo pipefail

# Phase 1: Quiesce all services (stop writes)
for svc in order-service payment-service inventory-service; do
  kubectl exec -n production deploy/$svc -- /app/quiesce.sh
done

# Phase 2: Take consistent snapshots
SNAPSHOT_ID="coordinated-$(date +%s)"
pg_dump -U postgres orders_db > "/tmp/${SNAPSHOT_ID}-orders.dump"
pg_dump -U postgres payments_db > "/tmp/${SNAPSHOT_ID}-payments.dump"
mongodump --db inventory --out "/tmp/${SNAPSHOT_ID}-inventory/"

# Phase 3: Resume all services
for svc in order-service payment-service inventory-service; do
  kubectl exec -n production deploy/$svc -- /app/resume.sh
done

# Phase 4: Upload snapshots
restic backup /tmp/${SNAPSHOT_ID}-* --tag coordinated --tag "$SNAPSHOT_ID"
```

### Service Mesh Considerations

When backing up in a service mesh environment:
- **Drain connections** before quiescing to avoid in-flight request loss
- **Circuit breakers** should handle backup-induced latency gracefully
- **Sidecar proxies** (Envoy/Istio) may need bypass rules for backup traffic
- **mTLS certificates** used by the mesh must also be backed up

---

## Kubernetes Backup Patterns

### etcd Backup

etcd stores all Kubernetes cluster state. Loss of etcd = loss of entire cluster config.

```bash
# Backup etcd snapshot (run on a control plane node)
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd/snapshot-$(date +%F-%H%M).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify the snapshot
ETCDCTL_API=3 etcdctl snapshot status /backup/etcd/snapshot-2024-01-15-0200.db \
  --write-table

# Upload to offsite storage
restic -r s3:s3.amazonaws.com/k8s-backups backup \
  /backup/etcd/ --tag etcd --tag "$(kubectl version --short 2>/dev/null | head -1)"
```

**Automated etcd backup with CronJob:**

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: etcd-backup
  namespace: kube-system
spec:
  schedule: "0 */4 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          hostNetwork: true
          containers:
          - name: etcd-backup
            image: bitnami/etcd:3.5
            command: ["/bin/sh", "-c"]
            args:
            - |
              etcdctl snapshot save /backup/etcd-$(date +%F-%H%M).db \
                --endpoints=https://127.0.0.1:2379 \
                --cacert=/etc/kubernetes/pki/etcd/ca.crt \
                --cert=/etc/kubernetes/pki/etcd/server.crt \
                --key=/etc/kubernetes/pki/etcd/server.key
              find /backup -name "etcd-*.db" -mtime +7 -delete
            volumeMounts:
            - name: etcd-certs
              mountPath: /etc/kubernetes/pki/etcd
              readOnly: true
            - name: backup-volume
              mountPath: /backup
          volumes:
          - name: etcd-certs
            hostPath:
              path: /etc/kubernetes/pki/etcd
          - name: backup-volume
            persistentVolumeClaim:
              claimName: etcd-backup-pvc
          restartPolicy: OnFailure
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          tolerations:
          - effect: NoSchedule
            key: node-role.kubernetes.io/control-plane
```

### etcd Restore Procedure

```bash
# 1. Stop all API servers and etcd instances
systemctl stop kube-apiserver kubelet

# 2. Restore snapshot to a new data directory
ETCDCTL_API=3 etcdutl snapshot restore /backup/etcd/snapshot.db \
  --data-dir=/var/lib/etcd-restored \
  --name=master-1 \
  --initial-cluster=master-1=https://10.0.0.1:2380 \
  --initial-cluster-token=etcd-cluster-1 \
  --initial-advertise-peer-urls=https://10.0.0.1:2380

# 3. Replace the data directory
mv /var/lib/etcd /var/lib/etcd.bak
mv /var/lib/etcd-restored /var/lib/etcd
chown -R etcd:etcd /var/lib/etcd

# 4. Start etcd and verify
systemctl start etcd
ETCDCTL_API=3 etcdctl endpoint health

# 5. Start API server and kubelet
systemctl start kube-apiserver kubelet

# 6. Force controller resync (revision bump)
kubectl create configmap etcd-restore-marker --from-literal=restored=$(date +%s)
kubectl delete configmap etcd-restore-marker
```

### Velero Advanced Patterns

```bash
# Backup with volume snapshots (CSI)
velero backup create full-backup \
  --include-namespaces production,staging \
  --snapshot-volumes \
  --csi-snapshot-timeout 30m \
  --default-volumes-to-fs-backup=false

# Backup with resource filtering
velero backup create config-backup \
  --include-resources configmaps,secrets,deployments,services \
  --include-namespaces production \
  --exclude-resources events

# Disaster recovery: restore to a different cluster
# On the new cluster, configure Velero with the same backup location
velero backup-location create primary \
  --provider aws --bucket velero-backups \
  --config region=us-east-1

velero restore create --from-backup full-backup \
  --namespace-mappings production:production \
  --restore-volumes
```

---

## Secrets and Vault Backup

### HashiCorp Vault Backup

```bash
# Raft snapshot (integrated storage)
vault operator raft snapshot save /backup/vault/raft-$(date +%F).snap

# Verify snapshot
vault operator raft snapshot inspect /backup/vault/raft-$(date +%F).snap

# Consul backend: backup Consul KV
consul snapshot save /backup/consul/consul-$(date +%F).snap

# Restore Raft snapshot
vault operator raft snapshot restore /backup/vault/raft-2024-01-15.snap

# CRITICAL: Also backup
# - Vault unseal keys (stored separately, encrypted, multi-party)
# - Vault root token (rotate after restore)
# - TLS certificates used by Vault
# - Audit log configuration
```

### Kubernetes Secrets Backup

```bash
# Export all secrets (encrypted at rest in etcd, plaintext in export)
kubectl get secrets --all-namespaces -o yaml > /tmp/secrets-backup.yaml

# Encrypt before storing
gpg --symmetric --cipher-algo AES256 \
  --batch --passphrase-file /etc/backup-key \
  /tmp/secrets-backup.yaml

restic backup /tmp/secrets-backup.yaml.gpg --tag secrets
rm -f /tmp/secrets-backup.yaml /tmp/secrets-backup.yaml.gpg

# Sealed Secrets: backup the controller's sealing key
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > /backup/sealed-secrets-key.yaml
```

---

## GitOps State Backup

### ArgoCD State Backup

```bash
# Export ArgoCD applications
kubectl get applications -n argocd -o yaml > /backup/argocd/applications.yaml

# Export AppProjects
kubectl get appprojects -n argocd -o yaml > /backup/argocd/appprojects.yaml

# Export ArgoCD configuration (ConfigMaps and Secrets)
kubectl get cm argocd-cm argocd-rbac-cm argocd-cmd-params-cm \
  -n argocd -o yaml > /backup/argocd/config.yaml
kubectl get secret argocd-secret -n argocd -o yaml > /backup/argocd/secret.yaml

# Backup repository credentials
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repository \
  -o yaml > /backup/argocd/repo-creds.yaml
```

### Flux State Backup

```bash
# Export Flux custom resources
for resource in gitrepositories helmrepositories helmreleases kustomizations; do
  kubectl get $resource --all-namespaces -o yaml > /backup/flux/${resource}.yaml
done

# Export Flux system namespace
kubectl get all -n flux-system -o yaml > /backup/flux/system.yaml

# Backup Flux deploy keys
kubectl get secrets -n flux-system \
  -l toolkit.fluxcd.io/component=source-controller \
  -o yaml > /backup/flux/deploy-keys.yaml
```

---

## Large Dataset Strategies

### Parallel Backup Streams

For datasets exceeding 1TB, use parallelism to reduce backup windows:

```bash
# Restic: automatic parallelism (uses GOMAXPROCS)
# Increase pack upload parallelism for fast networks
restic -r s3:s3.amazonaws.com/backups backup /data \
  -o s3.connections=20 \
  --read-concurrency 8

# Borg: use multiple repositories for parallel streams
# Split data across repos by directory
borg create /backup/repo-data1::archive /data/shard1 &
borg create /backup/repo-data2::archive /data/shard2 &
borg create /backup/repo-data3::archive /data/shard3 &
wait

# pg_dump with parallel jobs (custom format only)
pg_dump -U postgres -d bigdb -Fd -j 8 -f /backup/bigdb-parallel/

# pg_restore with parallel jobs
pg_restore -U postgres -d bigdb -j 8 /backup/bigdb-parallel/
```

### Incremental Forever

Eliminate periodic full backups entirely — only ever take incrementals:

**How it works:**
1. Initial full backup (once)
2. All subsequent backups are incremental (forever)
3. Synthetic full backups are constructed server-side when needed
4. Retention policies reference logical snapshots, not backup chains

**Tools supporting incremental-forever:**
- **Restic**: All backups are inherently incremental (dedup at chunk level)
- **Borg**: Same — dedup means every backup is effectively incremental
- **ZFS send -i**: Incremental ZFS stream between snapshots
- **pg_basebackup + WAL**: Continuous WAL archiving = incremental forever

```bash
# Restic: every backup is incremental-forever by design
# First backup stores all chunks; subsequent backups only store new/changed chunks
restic backup /data  # "full" — stores everything
restic backup /data  # "incremental" — only new chunks
restic backup /data  # still incremental — no need for periodic full

# ZFS incremental-forever
zfs snapshot tank/data@daily-$(date +%F)
zfs send -i tank/data@daily-$(date -d yesterday +%F) \
  tank/data@daily-$(date +%F) | ssh backup zfs recv backup/data
```

### Block-Level Backup

For large databases or VMs, back up at the block level instead of file level:

```bash
# LVM thin snapshot + block-level backup with changed blocks only
lvcreate -s -n data-snap /dev/vg0/data

# Use ddrescue or partclone for block-level copy
partclone.ext4 -c -s /dev/vg0/data-snap -o /backup/data-blocks.img

# Ceph RBD incremental backup
rbd export-diff pool/volume@snap2 --from-snap snap1 /backup/volume-diff.rbd

# Restore Ceph RBD
rbd import-diff /backup/volume-diff.rbd pool/volume
```

### Bandwidth and Resource Management

```bash
# Restic: limit bandwidth
restic -r s3:s3.amazonaws.com/backups backup /data \
  --limit-upload 50000 \    # 50 MB/s upload limit
  --limit-download 100000   # 100 MB/s download limit

# Borg: limit bandwidth via SSH
borg create --remote-ratelimit 50000 \
  ssh://backup@remote/./repo::archive /data

# ionice + nice: reduce system impact
ionice -c3 nice -n 19 restic backup /data

# Cgroup-based resource limits (systemd)
# In the backup service unit:
# [Service]
# CPUQuota=50%
# MemoryMax=2G
# IOWeight=100
# IOReadBandwidthMax=/dev/sda 100M
# IOWriteBandwidthMax=/dev/sda 50M
```

**Scheduling around business hours:**
```bash
# Bandwidth scheduling with rclone
rclone sync /data remote:backup \
  --bwlimit "08:00,10M 18:00,off 23:00,100M"
# 10 MB/s during business hours, unlimited evenings, 100 MB/s overnight
```
