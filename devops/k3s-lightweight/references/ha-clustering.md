# K3s High Availability Clustering

## Table of Contents

- [Overview](#overview)
- [HA Architecture Options](#ha-architecture-options)
- [Embedded etcd Mode](#embedded-etcd-mode)
  - [Initializing the First Server](#initializing-the-first-server)
  - [Joining Additional Servers](#joining-additional-servers)
  - [etcd Cluster Requirements](#etcd-cluster-requirements)
- [External Database Mode](#external-database-mode)
  - [PostgreSQL Backend](#postgresql-backend)
  - [MySQL Backend](#mysql-backend)
  - [External etcd Backend](#external-etcd-backend)
  - [Datastore Endpoint Configuration](#datastore-endpoint-configuration)
- [Load Balancer for API Server](#load-balancer-for-api-server)
  - [HAProxy Configuration](#haproxy-configuration)
  - [Nginx Configuration](#nginx-configuration)
  - [Cloud Load Balancers](#cloud-load-balancers)
- [Token Management](#token-management)
  - [Server Token](#server-token)
  - [Agent Token](#agent-token)
  - [Token Rotation](#token-rotation)
- [etcd Backup and Restore](#etcd-backup-and-restore)
  - [Automatic Snapshots](#automatic-snapshots)
  - [On-Demand Snapshots](#on-demand-snapshots)
  - [Snapshot Storage Locations](#snapshot-storage-locations)
  - [Restoring from Snapshot](#restoring-from-snapshot)
  - [S3 Snapshot Storage](#s3-snapshot-storage)
- [Cluster Recovery](#cluster-recovery)
  - [Single Server Failure](#single-server-failure)
  - [Quorum Loss Recovery](#quorum-loss-recovery)
  - [Full Cluster Restore](#full-cluster-restore)
- [Adding and Removing Nodes](#adding-and-removing-nodes)
  - [Adding Server Nodes](#adding-server-nodes)
  - [Removing Server Nodes](#removing-server-nodes)
  - [Adding Agent Nodes](#adding-agent-nodes)
  - [Removing Agent Nodes](#removing-agent-nodes)
- [Node Labels and Taints](#node-labels-and-taints)
  - [Applying Labels at Install](#applying-labels-at-install)
  - [Runtime Label Management](#runtime-label-management)
  - [Taints for Workload Isolation](#taints-for-workload-isolation)
  - [Control Plane Taints](#control-plane-taints)
- [Production Checklist](#production-checklist)

---

## Overview

K3s supports two high-availability (HA) topologies:

1. **Embedded etcd** — K3s manages its own etcd cluster across server nodes. Recommended for most deployments. Requires minimum 3 server nodes.
2. **External datastore** — K3s connects to an existing PostgreSQL, MySQL, or etcd cluster. The control plane is stateless; the database handles durability.

Both topologies require a **load balancer** in front of the K3s API servers (port 6443) so agents and kubectl clients have a stable endpoint.

```
                    ┌──────────────────┐
                    │   Load Balancer  │
                    │   (TCP 6443)     │
                    └────────┬─────────┘
               ┌─────────────┼─────────────┐
               ▼             ▼             ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │ Server 1 │  │ Server 2 │  │ Server 3 │
        │  (etcd)  │  │  (etcd)  │  │  (etcd)  │
        └──────────┘  └──────────┘  └──────────┘
               │             │             │
        ┌──────┴──────┬──────┴──────┬──────┴──────┐
        ▼             ▼             ▼             ▼
   ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐
   │ Agent 1 │  │ Agent 2 │  │ Agent 3 │  │ Agent N │
   └─────────┘  └─────────┘  └─────────┘  └─────────┘
```

## HA Architecture Options

| Feature | Embedded etcd | External Database |
|---------|--------------|-------------------|
| Minimum servers | 3 (odd number) | 2 (can be even) |
| Database management | Automatic | User-managed |
| Backup/restore | Built-in snapshots | Database-native tools |
| Complexity | Lower | Higher (separate DB) |
| Latency sensitivity | Server-to-server | Server-to-DB |
| Recommended for | Most deployments | Existing DB infra |

## Embedded etcd Mode

### Initializing the First Server

The first server bootstraps the etcd cluster with `--cluster-init`:

```bash
# First server — initializes the etcd cluster
curl -sfL https://get.k3s.io | K3S_TOKEN=<SHARED_SECRET> sh -s - server \
  --cluster-init \
  --tls-san=<LB_HOSTNAME_OR_IP> \
  --tls-san=<ADDITIONAL_SAN>
```

The `K3S_TOKEN` is a shared secret used by all servers and agents to authenticate. Generate a strong token:

```bash
# Generate a secure token
openssl rand -hex 32
```

Using a config file (`/etc/rancher/k3s/config.yaml`):

```yaml
token: "<SHARED_SECRET>"
cluster-init: true
tls-san:
  - lb.example.com
  - 10.0.0.100
write-kubeconfig-mode: "0644"
```

Then install:

```bash
curl -sfL https://get.k3s.io | sh -
```

### Joining Additional Servers

Subsequent servers join the existing cluster by pointing to the first server:

```bash
# Second and third servers
curl -sfL https://get.k3s.io | K3S_TOKEN=<SHARED_SECRET> sh -s - server \
  --server https://<FIRST_SERVER_IP>:6443 \
  --tls-san=<LB_HOSTNAME_OR_IP>
```

Using a config file:

```yaml
token: "<SHARED_SECRET>"
server: https://<FIRST_SERVER_IP>:6443
tls-san:
  - lb.example.com
  - 10.0.0.100
```

**Important:** After all servers are running, agents and kubectl should target the **load balancer** address, not any individual server.

### etcd Cluster Requirements

- **Odd number of servers:** 3, 5, or 7. Even numbers provide no quorum benefit and waste resources.
- **Fault tolerance:** A 3-node cluster tolerates 1 failure; 5-node tolerates 2.
- **Disk performance:** etcd is sensitive to disk latency. Use SSDs; avoid SD cards and network-attached storage with high latency.
- **Network latency:** Keep server-to-server latency under 10 ms. Higher latency causes leader election instability.
- **Ports:** Servers communicate on ports 2379 (etcd client) and 2380 (etcd peer) in addition to 6443 (API server) and 8472 (VXLAN).

| Cluster Size | Quorum | Tolerated Failures |
|-------------|--------|-------------------|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

## External Database Mode

### PostgreSQL Backend

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --datastore-endpoint="postgres://k3s_user:password@db.example.com:5432/k3s?sslmode=require" \
  --tls-san=lb.example.com
```

PostgreSQL requirements:
- Version 10+ recommended
- Create dedicated database and user:

```sql
CREATE DATABASE k3s;
CREATE USER k3s_user WITH ENCRYPTED PASSWORD 'strong_password';
GRANT ALL PRIVILEGES ON DATABASE k3s TO k3s_user;
-- For PostgreSQL 15+, also grant schema permissions:
\c k3s
GRANT ALL ON SCHEMA public TO k3s_user;
```

- SSL is strongly recommended (`sslmode=require` or `sslmode=verify-full`)
- For HA PostgreSQL, use managed services (RDS, Cloud SQL) or Patroni/Stolon

### MySQL Backend

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --datastore-endpoint="mysql://k3s_user:password@tcp(db.example.com:3306)/k3s" \
  --tls-san=lb.example.com
```

MySQL requirements:
- Version 5.7+ or MariaDB 10.4+
- Create dedicated database and user:

```sql
CREATE DATABASE k3s;
CREATE USER 'k3s_user'@'%' IDENTIFIED BY 'strong_password';
GRANT ALL PRIVILEGES ON k3s.* TO 'k3s_user'@'%';
FLUSH PRIVILEGES;
```

- Use InnoDB engine (default)
- Enable TLS by appending `?tls=true` to the connection string

### External etcd Backend

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --datastore-endpoint="https://etcd1:2379,https://etcd2:2379,https://etcd3:2379" \
  --datastore-cafile=/etc/k3s/etcd-ca.crt \
  --datastore-certfile=/etc/k3s/etcd-client.crt \
  --datastore-keyfile=/etc/k3s/etcd-client.key \
  --tls-san=lb.example.com
```

- Manage etcd separately (use etcdadm, kubeadm-based etcd, or a managed service)
- Backups are your responsibility — use `etcdctl snapshot save`
- Client TLS is required for production

### Datastore Endpoint Configuration

The `--datastore-endpoint` flag accepts these URL schemes:

| Scheme | Database | Example |
|--------|----------|---------|
| `postgres://` | PostgreSQL | `postgres://user:pass@host:5432/db` |
| `mysql://` | MySQL/MariaDB | `mysql://user:pass@tcp(host:3306)/db` |
| `https://` | External etcd | `https://host1:2379,https://host2:2379` |
| `http://` | External etcd (insecure) | `http://host:2379` |

Connection string parameters:
- PostgreSQL: `sslmode`, `connect_timeout`, `sslcert`, `sslkey`, `sslrootcert`
- MySQL: `tls`, `timeout`, `readTimeout`, `writeTimeout`

Via config file:

```yaml
datastore-endpoint: "postgres://user:pass@host:5432/k3s?sslmode=require"
datastore-cafile: /etc/k3s/ca.crt
datastore-certfile: /etc/k3s/client.crt
datastore-keyfile: /etc/k3s/client.key
```

## Load Balancer for API Server

All HA deployments require a TCP load balancer on port 6443. The LB must:
- Perform TCP (Layer 4) load balancing (not HTTP/HTTPS termination)
- Health-check each server on port 6443
- Distribute traffic to all healthy K3s servers

### HAProxy Configuration

```
# /etc/haproxy/haproxy.cfg
frontend k3s_api
    bind *:6443
    mode tcp
    option tcplog
    default_backend k3s_servers

backend k3s_servers
    mode tcp
    option tcp-check
    balance roundrobin
    server server1 10.0.0.11:6443 check fall 3 rise 2
    server server2 10.0.0.12:6443 check fall 3 rise 2
    server server3 10.0.0.13:6443 check fall 3 rise 2

frontend k3s_api_register
    bind *:9345
    mode tcp
    default_backend k3s_register

backend k3s_register
    mode tcp
    option tcp-check
    balance roundrobin
    server server1 10.0.0.11:9345 check fall 3 rise 2
    server server2 10.0.0.12:9345 check fall 3 rise 2
    server server3 10.0.0.13:9345 check fall 3 rise 2
```

Port 9345 is the K3s supervisor port used during node registration. Include it in the LB for reliable agent joins.

### Nginx Configuration

```nginx
# /etc/nginx/nginx.conf (stream module)
stream {
    upstream k3s_api {
        least_conn;
        server 10.0.0.11:6443 max_fails=3 fail_timeout=10s;
        server 10.0.0.12:6443 max_fails=3 fail_timeout=10s;
        server 10.0.0.13:6443 max_fails=3 fail_timeout=10s;
    }

    upstream k3s_register {
        least_conn;
        server 10.0.0.11:9345 max_fails=3 fail_timeout=10s;
        server 10.0.0.12:9345 max_fails=3 fail_timeout=10s;
        server 10.0.0.13:9345 max_fails=3 fail_timeout=10s;
    }

    server {
        listen 6443;
        proxy_pass k3s_api;
    }

    server {
        listen 9345;
        proxy_pass k3s_register;
    }
}
```

### Cloud Load Balancers

For cloud deployments:
- **AWS:** Network Load Balancer (NLB) — TCP, target group on port 6443 and 9345
- **GCP:** TCP/UDP Load Balancer with health checks on port 6443
- **Azure:** Azure Load Balancer (Standard SKU) with TCP rules

Ensure the LB IP/hostname is included in `--tls-san` on all servers.

## Token Management

### Server Token

The server token authenticates server-to-server communication. Set it at install time:

```bash
# Via environment variable
K3S_TOKEN=my-secure-token

# Via config file
token: "my-secure-token"
```

After installation, the token is stored at `/var/lib/rancher/k3s/server/token`. All servers in the cluster must use the same token.

### Agent Token

By default, agents use the same token as servers. For separation, set an agent-specific token:

```yaml
# Server config
token: "server-token"
agent-token: "agent-specific-token"
```

Agents then join with:

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://lb:6443 K3S_TOKEN=agent-specific-token sh -
```

### Token Rotation

To rotate the server token (K3s v1.25+):

```bash
# 1. On one server, prepare the new token
k3s token rotate --new-token <NEW_TOKEN>

# 2. Restart all servers with the new token
# Update config.yaml on each server, then:
sudo systemctl restart k3s

# 3. Re-join agents with new token (or update and restart)
```

**Caution:** Token rotation requires restarting all servers and agents. Plan for a maintenance window.

## etcd Backup and Restore

### Automatic Snapshots

Configure scheduled snapshots in `/etc/rancher/k3s/config.yaml`:

```yaml
etcd-snapshot-schedule-cron: "0 */6 * * *"   # Every 6 hours
etcd-snapshot-retention: 10                    # Keep 10 snapshots
etcd-snapshot-dir: /var/lib/rancher/k3s/server/db/snapshots
etcd-snapshot-compress: true                   # Compress snapshots (v1.26+)
```

### On-Demand Snapshots

```bash
# Create a named snapshot
k3s etcd-snapshot save --name pre-upgrade-$(date +%Y%m%d-%H%M%S)

# List existing snapshots
k3s etcd-snapshot list

# Delete a snapshot
k3s etcd-snapshot delete <SNAPSHOT_NAME>
```

### Snapshot Storage Locations

Default location: `/var/lib/rancher/k3s/server/db/snapshots/`

Each snapshot file is named: `<name>-<node>-<timestamp>`

### Restoring from Snapshot

**Stop K3s on ALL servers before restoring:**

```bash
# 1. Stop K3s on all servers
sudo systemctl stop k3s  # On every server node

# 2. Restore on the first server
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<SNAPSHOT_FILE>

# 3. After restore completes, start K3s normally on the first server
sudo systemctl start k3s

# 4. On remaining servers, delete the data directory and rejoin
sudo rm -rf /var/lib/rancher/k3s/server/db
sudo systemctl start k3s
```

**Important:** `--cluster-reset` resets the cluster to a single-member etcd cluster. Other servers must rejoin.

### S3 Snapshot Storage

Store snapshots in S3-compatible storage for off-site backup:

```yaml
etcd-snapshot-schedule-cron: "0 */12 * * *"
etcd-snapshot-retention: 30
etcd-s3: true
etcd-s3-endpoint: s3.amazonaws.com
etcd-s3-bucket: k3s-backups
etcd-s3-region: us-east-1
etcd-s3-access-key: AKIAIOSFODNN7EXAMPLE
etcd-s3-secret-key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
etcd-s3-folder: cluster-prod
```

On-demand S3 snapshot:

```bash
k3s etcd-snapshot save \
  --name manual-backup \
  --s3 \
  --s3-bucket k3s-backups \
  --s3-endpoint s3.amazonaws.com \
  --s3-region us-east-1
```

Restore from S3:

```bash
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=<SNAPSHOT_NAME> \
  --etcd-s3 \
  --etcd-s3-bucket k3s-backups \
  --etcd-s3-endpoint s3.amazonaws.com \
  --etcd-s3-region us-east-1
```

## Cluster Recovery

### Single Server Failure

If one of three servers fails:
1. The cluster continues operating (2/3 quorum maintained)
2. Replace the failed node:

```bash
# Remove failed node from cluster
kubectl delete node <FAILED_NODE_NAME>

# Provision replacement server with same config
curl -sfL https://get.k3s.io | K3S_TOKEN=<TOKEN> sh -s - server \
  --server https://<LB_IP>:6443 \
  --tls-san=<LB_IP>
```

### Quorum Loss Recovery

If quorum is lost (e.g., 2 of 3 servers down), the cluster is read-only. Recovery:

**Option A: Restore quorum by bringing servers back online**

```bash
# Start the failed servers
sudo systemctl start k3s
# etcd will automatically rejoin and recover
```

**Option B: Reset to single node and rebuild**

```bash
# On the surviving server
sudo k3s server --cluster-reset

# This creates a new single-member etcd cluster
# Rejoin other servers after restart
sudo systemctl start k3s
```

### Full Cluster Restore

If all servers are lost and you have a snapshot:

```bash
# 1. Provision a new server
# 2. Copy snapshot to the new server
# 3. Restore from snapshot
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/path/to/snapshot

# 4. Start K3s
sudo systemctl start k3s

# 5. Join additional servers
curl -sfL https://get.k3s.io | K3S_TOKEN=<TOKEN> sh -s - server \
  --server https://<NEW_SERVER_IP>:6443

# 6. Rejoin agents
# Agents should reconnect automatically if they can reach the LB
```

## Adding and Removing Nodes

### Adding Server Nodes

When scaling the control plane, always maintain an odd number of servers:

```bash
# New server joins existing cluster
curl -sfL https://get.k3s.io | K3S_TOKEN=<TOKEN> sh -s - server \
  --server https://<LB_IP>:6443 \
  --tls-san=<LB_IP>
```

Update the load balancer backend to include the new server.

### Removing Server Nodes

```bash
# 1. Cordon and drain the node
kubectl cordon <NODE_NAME>
kubectl drain <NODE_NAME> --ignore-daemonsets --delete-emptydir-data

# 2. Stop K3s on the node
sudo systemctl stop k3s

# 3. Remove the node from the cluster
kubectl delete node <NODE_NAME>

# 4. Remove the etcd member (if using embedded etcd)
# This happens automatically when the node is deleted

# 5. Uninstall K3s
sudo /usr/local/bin/k3s-uninstall.sh

# 6. Update the load balancer to remove the server
```

**Warning:** Never remove more than one server at a time. Ensure quorum is maintained at every step. Going from 3 servers to 2 is dangerous — go 3 → 5 → (remove old ones one at a time).

### Adding Agent Nodes

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://<LB_IP>:6443 \
  K3S_TOKEN=<TOKEN> sh -
```

### Removing Agent Nodes

```bash
# 1. Cordon and drain
kubectl cordon <NODE_NAME>
kubectl drain <NODE_NAME> --ignore-daemonsets --delete-emptydir-data

# 2. Delete from cluster
kubectl delete node <NODE_NAME>

# 3. Uninstall on the agent node
sudo /usr/local/bin/k3s-agent-uninstall.sh
```

## Node Labels and Taints

### Applying Labels at Install

Set labels during installation via config or flags:

```yaml
# /etc/rancher/k3s/config.yaml
node-label:
  - environment=production
  - tier=backend
  - topology.kubernetes.io/zone=us-east-1a
```

Or via flags:

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --node-label=environment=production \
  --node-label=tier=backend
```

### Runtime Label Management

```bash
# Add label
kubectl label node <NODE> disktype=ssd

# Update label (overwrite)
kubectl label node <NODE> environment=staging --overwrite

# Remove label
kubectl label node <NODE> environment-
```

### Taints for Workload Isolation

Apply taints at install:

```yaml
# config.yaml
node-taint:
  - dedicated=gpu:NoSchedule
  - environment=production:PreferNoSchedule
```

Runtime taint management:

```bash
# Add taint
kubectl taint nodes <NODE> dedicated=gpu:NoSchedule

# Remove taint
kubectl taint nodes <NODE> dedicated=gpu:NoSchedule-
```

### Control Plane Taints

By default, K3s server nodes are schedulable (no taint). To prevent workloads on control plane:

```yaml
# config.yaml for server nodes
node-taint:
  - CriticalAddonsOnly=true:NoExecute
```

Or use the standard Kubernetes control-plane taint:

```bash
kubectl taint nodes <SERVER_NODE> node-role.kubernetes.io/control-plane:NoSchedule
```

## Production Checklist

- [ ] **Odd number of server nodes** (3 or 5 recommended)
- [ ] **Load balancer** in front of API servers (ports 6443 and 9345)
- [ ] **TLS SANs** include LB hostname/IP on all servers
- [ ] **Shared token** set before installation (strong, random)
- [ ] **etcd on SSD storage** (not SD cards or slow disks)
- [ ] **Automatic snapshots** configured (every 6-12 hours)
- [ ] **Off-site snapshot storage** (S3 or remote location)
- [ ] **Snapshot restore tested** in staging
- [ ] **Network latency < 10 ms** between servers
- [ ] **Firewall rules** open for required ports (6443, 9345, 2379, 2380, 8472, 10250)
- [ ] **Monitoring** for etcd health, leader elections, and disk latency
- [ ] **Upgrade plan** using system-upgrade-controller
- [ ] **Node labels and taints** applied for workload scheduling
- [ ] **Separate agent token** if agents are in a different trust zone
