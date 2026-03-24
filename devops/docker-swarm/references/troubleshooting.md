# Docker Swarm Troubleshooting Guide

## Table of Contents

- [Services Not Scheduling](#services-not-scheduling)
- [Image Pull Failures](#image-pull-failures)
- [Overlay Network Connectivity](#overlay-network-connectivity)
- [DNS Resolution Failures](#dns-resolution-failures)
- [Split-Brain with Even Managers](#split-brain-with-even-managers)
- [Certificate Rotation Failures](#certificate-rotation-failures)
- [Volume Mount Issues Across Nodes](#volume-mount-issues-across-nodes)
- [Log Driver Failures](#log-driver-failures)
- [Ingress Network Congestion](#ingress-network-congestion)
- [Stuck Tasks](#stuck-tasks)
- [Disaster Recovery Procedures](#disaster-recovery-procedures)

---

## Services Not Scheduling

### Symptoms

- `docker service ps <SERVICE>` shows tasks in `Pending` state.
- Task error message: `no suitable node (insufficient resources on N nodes)`.
- Service stuck at 0/N replicas.

### Diagnosis

```bash
# Check task errors (use --no-trunc for full messages)
docker service ps --no-trunc <SERVICE>

# Check node resources
docker node ls
for node in $(docker node ls -q); do
  echo "=== $(docker node inspect --format '{{.Description.Hostname}}' $node) ==="
  docker node inspect --format '{{.Description.Resources}}' "$node"
  docker node inspect --format '{{.Status.State}} / {{.Spec.Availability}}' "$node"
done

# Check placement constraints
docker service inspect --pretty <SERVICE> | grep -A 5 Placement
```

### Resource constraint causes

| Error Message | Cause | Fix |
|---------------|-------|-----|
| `insufficient resources on N nodes` | Memory/CPU reservations exceed available | Reduce reservations or add nodes |
| `no suitable node (scheduling constraints...)` | No node matches placement constraints | Check labels: `docker node inspect --pretty <NODE>` |
| `no suitable node (max replicas per node limit)` | `max_replicas_per_node` reached | Increase limit or add nodes |

### Fixes

```bash
# Reduce resource reservations
docker service update --reserve-memory 128M --reserve-cpu 0.1 <SERVICE>

# Add missing node labels
docker node update --label-add zone=us-east-1a <NODE_ID>

# Check if nodes are drained
docker node ls --format "{{.Hostname}} {{.Availability}}"

# Reactivate drained nodes
docker node update --availability active <NODE_ID>

# Force rescheduling
docker service update --force <SERVICE>
```

---

## Image Pull Failures

### Symptoms

- Task error: `No such image` or `pull access denied` or `manifest unknown`.
- Tasks cycling between `Preparing` and `Rejected`.

### Diagnosis

```bash
# Check exact error
docker service ps --no-trunc <SERVICE> 2>&1 | head -20

# Test pull on a specific node
docker pull <IMAGE>:<TAG>

# Check registry authentication
docker info | grep Registry
cat ~/.docker/config.json
```

### Common causes and fixes

**1. Image doesn't exist or wrong tag:**
```bash
# Verify image exists
docker manifest inspect <IMAGE>:<TAG>

# Fix: use correct image name
docker service update --image <CORRECT_IMAGE>:<TAG> <SERVICE>
```

**2. Private registry authentication:**
```bash
# Workers need registry credentials. Distribute via secrets:
docker login registry.example.com
# config.json is created at ~/.docker/config.json

# Pass to swarm service
docker service update \
  --with-registry-auth \
  --image registry.example.com/myapp:latest \
  <SERVICE>

# Or in stack deploy:
docker stack deploy --with-registry-auth -c docker-compose.yml myapp
```

**3. Registry unreachable from worker nodes:**
```bash
# Test connectivity from worker
curl -v https://registry.example.com/v2/

# Check DNS resolution on worker
nslookup registry.example.com

# Check proxy settings in /etc/docker/daemon.json or systemd env
systemctl show docker --property=Environment
```

**4. Disk space exhaustion:**
```bash
# Check disk space on nodes
docker system df
docker system prune -a --volumes  # WARNING: removes unused data
```

---

## Overlay Network Connectivity

### Symptoms

- Services on the same overlay network cannot reach each other.
- Intermittent connection timeouts between services.
- `docker exec <CONTAINER> ping <SERVICE>` fails.

### Diagnosis

```bash
# Check overlay network
docker network inspect <NETWORK>

# List network peers (shows which nodes have joined)
docker network inspect <NETWORK> --format '{{json .Peers}}' | python3 -m json.tool

# Check required ports between nodes
# TCP 2377 — Swarm management
# TCP/UDP 7946 — Node discovery and gossip
# UDP 4789 — VXLAN overlay data plane
for port in 2377 7946; do nc -zv <NODE_IP> $port; done
nc -zuv <NODE_IP> 4789

# Check if iptables/firewall blocks traffic
iptables -L -n | grep -E '(2377|7946|4789)'
```

### Common causes and fixes

**1. Firewall blocking Swarm ports:**
```bash
# Open required ports (example: firewalld)
firewall-cmd --permanent --add-port=2377/tcp
firewall-cmd --permanent --add-port=7946/tcp
firewall-cmd --permanent --add-port=7946/udp
firewall-cmd --permanent --add-port=4789/udp
firewall-cmd --reload

# Example: ufw
ufw allow 2377/tcp
ufw allow 7946
ufw allow 4789/udp
```

**2. MTU mismatch:**

Overlay networks add a 50-byte VXLAN header. If the underlying network MTU is 1500, the overlay MTU should be 1450.

```bash
# Check current MTU
docker network inspect <NETWORK> --format '{{json .Options}}'

# Create network with explicit MTU
docker network create --driver overlay --opt com.docker.network.driver.mtu=1450 my-net
```

**3. Stale network state:**
```bash
# Force service redeployment to refresh network attachments
docker service update --force <SERVICE>

# Remove and recreate network (requires removing all attached services first)
docker service update --network-rm <NETWORK> <SERVICE>
docker network rm <NETWORK>
docker network create --driver overlay <NETWORK>
docker service update --network-add <NETWORK> <SERVICE>
```

**4. Encrypted overlay performance:**

Encrypted overlays (`--opt encrypted`) use IPsec and add CPU overhead. If performance degrades:
- Check node CPU usage during network-heavy operations.
- Consider encrypting only sensitive networks, not all overlays.

---

## DNS Resolution Failures

### Symptoms

- `nslookup <SERVICE_NAME>` fails inside containers.
- `Could not resolve host` errors in application logs.
- Service discovery works intermittently.

### Diagnosis

```bash
# Test DNS from inside a container
docker exec <CONTAINER_ID> nslookup <SERVICE_NAME>
docker exec <CONTAINER_ID> cat /etc/resolv.conf

# Check the embedded DNS server (127.0.0.11)
docker exec <CONTAINER_ID> dig @127.0.0.11 <SERVICE_NAME>

# Verify services are on the same network
docker network inspect <NETWORK> --format '{{range .Containers}}{{.Name}} {{end}}'
```

### Common causes and fixes

**1. Services on different networks:**
```bash
# Services must share at least one overlay network for DNS to work
docker service inspect <SERVICE_A> --format '{{json .Spec.TaskTemplate.Networks}}'
docker service inspect <SERVICE_B> --format '{{json .Spec.TaskTemplate.Networks}}'

# Add service to a shared network
docker service update --network-add <SHARED_NETWORK> <SERVICE>
```

**2. DNS cache stale after scaling:**

Swarm's embedded DNS uses a short TTL, but applications may cache DNS longer.

```bash
# Force DNS refresh by restarting service
docker service update --force <SERVICE>
```

**3. Custom DNS configuration conflicts:**

If containers specify custom DNS servers via `--dns`, Swarm's internal DNS may be bypassed.

```bash
# Check if custom DNS overrides Swarm DNS
docker inspect <CONTAINER_ID> --format '{{.HostConfig.Dns}}'

# Remove custom DNS to use Swarm's embedded resolver
# In compose: remove `dns:` entries from the service definition
```

**4. Too many services causing DNS overload:**

With hundreds of services, DNS queries can overwhelm the embedded resolver.

```bash
# Reduce DNS pressure: use network segmentation
# Services only resolve names within their attached networks
```

---

## Split-Brain with Even Managers

### The problem

Using an **even number of managers** (2, 4, 6) creates a risk where a network partition splits managers into equal halves. Neither half has a majority, so **both partitions lose quorum** and the entire cluster becomes read-only.

### Example: 2 managers

```
Partition: [Manager1] | [Manager2]
Each side: 1/2 = no quorum
Result: ENTIRE cluster is read-only — no service scheduling or updates
```

### Example: 4 managers

```
Partition: [Manager1, Manager2] | [Manager3, Manager4]
Each side: 2/4 = no quorum
Result: ENTIRE cluster is read-only
```

### With odd numbers (3 or 5), one partition always has majority

```
3 managers, partition: [Manager1, Manager2] | [Manager3]
Left side: 2/3 = quorum ✓ — cluster continues operating
Right side: 1/3 = no quorum — isolated but cluster still works
```

### Fix

```bash
# Check current manager count
docker node ls --filter role=manager

# Add a manager to make count odd
docker swarm join-token manager
# On new node:
docker swarm join --token <MANAGER_TOKEN> <MANAGER_IP>:2377

# Or demote one manager to make count odd
docker node demote <NODE_ID>
```

### Prevention

- **Always use 3 or 5 managers** (7 max for very large clusters).
- Distribute managers across availability zones / failure domains.
- Monitor manager count with alerting.

---

## Certificate Rotation Failures

### Symptoms

- `docker node ls` shows nodes as `Down` after certificate expiry.
- TLS handshake errors in `journalctl -u docker`.
- `error renewing TLS certificate` in daemon logs.

### Diagnosis

```bash
# Check certificate expiry
docker info --format '{{.Swarm.Cluster.TLSInfo.CertIssuerSubject}}'
docker swarm inspect --format '{{.ClusterInfo.TLSInfo}}'

# Check cert expiry setting
docker info --format '{{.Swarm.Cluster.Spec.CAConfig.NodeCertExpiry}}'

# Check node certificate status
openssl x509 -in /var/lib/docker/swarm/certificates/swarm-node.crt \
  -noout -dates

# Check daemon logs for TLS errors
journalctl -u docker --since "1 hour ago" | grep -i -E "(tls|cert|x509)"
```

### Common causes and fixes

**1. Certificate expired (node was offline during rotation):**
```bash
# On the affected node, leave and rejoin swarm
docker swarm leave --force
docker swarm join --token <TOKEN> <MANAGER_IP>:2377
```

**2. Clock skew between nodes:**
```bash
# Check time on all nodes
date
timedatectl

# Fix NTP
systemctl enable --now chronyd   # or ntpd/systemd-timesyncd
chronyc tracking
```

**3. Root CA rotation failed midway:**
```bash
# Check CA rotation status
docker info 2>&1 | grep -i "CA rotation"

# Retry root CA rotation
docker swarm ca --rotate

# If stuck, force with external CA
docker swarm ca --rotate --external-ca \
  protocol=cfssl,url=https://ca.example.com
```

**4. Autolock and lost unlock key:**
```bash
# If unlock key is lost and managers restarted, cluster is unrecoverable
# Prevention: back up unlock key
docker swarm unlock-key
docker swarm unlock-key --rotate  # generates new key, old still works briefly
```

---

## Volume Mount Issues Across Nodes

### Symptoms

- Data missing after task rescheduling to a different node.
- `mount: wrong fs type` or `permission denied` errors.
- Volume mounts succeed on manager but fail on workers.

### Diagnosis

```bash
# Check which node a task is running on
docker service ps <SERVICE> --format "{{.Name}} → {{.Node}}"

# Check volume details
docker volume inspect <VOLUME_NAME>

# Check mount errors
docker service ps --no-trunc <SERVICE>
```

### Common causes and fixes

**1. Local volumes are node-specific:**

Local volumes exist only on the node where they were created. When a task moves to another node, the volume is recreated empty.

```bash
# Solution: Use a distributed storage driver
docker service create --name db \
  --mount 'type=volume,src=pgdata,dst=/var/lib/postgresql/data,volume-driver=local,volume-opt=type=nfs,volume-opt=o=addr=nfs.example.com,volume-opt=device=:/exports/pgdata' \
  postgres:16
```

**2. NFS mount failures:**
```bash
# Verify NFS is available on all nodes
showmount -e nfs.example.com

# Install NFS client on all nodes
apt-get install -y nfs-common   # Debian/Ubuntu
yum install -y nfs-utils        # RHEL/CentOS

# Test manual mount
mount -t nfs nfs.example.com:/exports/data /mnt/test
```

**3. Permission issues with bind mounts:**
```bash
# Ensure path exists on all worker nodes
# Use config management (Ansible, etc.) to create directories

# Check UID/GID inside container matches host
docker exec <CONTAINER> id
ls -la /srv/data
```

**4. Constraint tasks to specific nodes for local volumes:**
```yaml
deploy:
  placement:
    constraints:
      - node.labels.db-host == true
```

---

## Log Driver Failures

### Symptoms

- `docker service logs <SERVICE>` returns `"logs" command is supported only for "json-file" and "journald" logging drivers`.
- Containers fail to start with log driver errors.
- Log entries missing from centralized logging.

### Diagnosis

```bash
# Check service log driver
docker service inspect <SERVICE> --format '{{.Spec.TaskTemplate.LogDriver}}'

# Check default daemon log driver
docker info --format '{{.LoggingDriver}}'

# Check log driver health (fluentd example)
nc -zv localhost 24224

# Check container logs directly (if json-file)
docker inspect <CONTAINER_ID> --format '{{.LogPath}}'
cat $(docker inspect <CONTAINER_ID> --format '{{.LogPath}}')
```

### Common causes and fixes

**1. Remote log driver unreachable:**
```bash
# For fluentd, ensure async mode to prevent container blocking
docker service update \
  --log-opt fluentd-async=true \
  --log-opt fluentd-retry-wait=1s \
  --log-opt fluentd-max-retries=10 \
  <SERVICE>
```

**2. `docker service logs` not available:**

`docker service logs` only works with `json-file` and `journald` drivers. If using fluentd/gelf/syslog, logs must be retrieved from the centralized system.

```bash
# Workaround: use dual logging (Docker 20.10+)
# In /etc/docker/daemon.json on each node:
# { "log-driver": "fluentd", "log-opts": {...}, "log-opts": {"cache-disabled": "false"} }
```

**3. Log driver causing container start failure:**
```bash
# If the log driver fails (e.g., fluentd down), containers may not start
# Use mode=non-blocking to decouple container lifecycle from logging
docker service create --name web \
  --log-driver fluentd \
  --log-opt mode=non-blocking \
  --log-opt max-buffer-size=5m \
  myapp:latest
```

**4. Disk full from excessive logging:**
```bash
# Check disk usage
df -h /var/lib/docker

# Set log rotation in daemon.json
# { "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }

# Or per service
docker service update --log-opt max-size=10m --log-opt max-file=3 <SERVICE>
```

---

## Ingress Network Congestion

### Symptoms

- High latency on published ports.
- `docker service ps` shows healthy tasks but clients timeout.
- Uneven load distribution across replicas.

### Diagnosis

```bash
# Inspect ingress network
docker network inspect ingress

# Check IPVS routing table (routing mesh uses IPVS)
nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t nat -L -n
nsenter --net=/var/run/docker/netns/ingress_sbox ipvsadm -Ln

# Check connections per node
ss -tnp | grep :<PORT> | wc -l
```

### Common causes and fixes

**1. Ingress network exhausted its IP range:**
```bash
# Default ingress subnet is /24 (254 usable IPs)
# With many services publishing ports, IPs can be exhausted

# Recreate ingress with larger subnet
docker network rm ingress  # WARNING: causes brief downtime
docker network create --driver overlay --ingress \
  --subnet 10.0.0.0/16 --gateway 10.0.0.1 ingress
```

**2. Connection-based vs request-based balancing:**

The routing mesh uses layer-4 (connection) load balancing via IPVS. Long-lived connections (WebSockets, HTTP/2) can cause uneven distribution.

```bash
# Solution: use host mode + external L7 load balancer
docker service create --name web --mode global \
  --publish published=8080,target=8080,mode=host myapp

# External LB (HAProxy/Nginx/Traefik) distributes requests across nodes
```

**3. Too many published ports:**

Each published port creates IPVS entries on every node. Reduce by:
- Using a reverse proxy (Traefik) for HTTP services.
- Only publishing ports on services that need external access.

---

## Stuck Tasks

### Symptoms

- Tasks stuck in `Preparing`, `Starting`, `Running (unhealthy)`, or `Shutdown` state.
- `docker service ps` shows tasks not progressing.
- Old tasks not removed after update.

### Diagnosis

```bash
# Show all tasks including stopped
docker service ps --no-trunc <SERVICE>

# Filter stuck tasks
docker service ps <SERVICE> --format "{{.Name}} {{.CurrentState}} {{.Error}}"

# Check node where stuck task is assigned
docker inspect <TASK_ID> --format '{{.NodeID}}'
```

### Fixes by state

**Stuck in `Preparing`:**
```bash
# Usually an image pull issue
docker service ps --no-trunc <SERVICE>  # check for pull errors

# Force update to retry
docker service update --force <SERVICE>
```

**Stuck in `Running (unhealthy)`:**
```bash
# Health check is failing but container keeps running
# Check health check command
docker inspect <CONTAINER_ID> --format '{{json .State.Health}}'

# Fix health check or disable temporarily
docker service update --health-cmd "true" <SERVICE>  # disable
docker service update --health-cmd "curl -f http://localhost:8080/health" <SERVICE>
```

**Stuck in `Shutdown`:**
```bash
# Container stop timeout — SIGTERM not handled, waiting for SIGKILL
# Reduce stop grace period
docker service update --stop-grace-period 10s <SERVICE>
```

**Orphaned tasks after node removal:**
```bash
# Force remove tasks from removed nodes
docker node rm --force <REMOVED_NODE_ID>

# Force update to reschedule
docker service update --force <SERVICE>
```

### Nuclear option: recreate the service

```bash
# Export service spec
docker service inspect <SERVICE> > service-backup.json

# Remove and recreate
docker service rm <SERVICE>
docker service create ... # from spec
```

---

## Disaster Recovery Procedures

### Backup Swarm state

```bash
# Stop Docker on the manager (to get consistent snapshot)
systemctl stop docker

# Backup the swarm directory
cp -a /var/lib/docker/swarm ./swarm-backup-$(date +%Y%m%d-%H%M%S)

# Restart Docker
systemctl start docker
```

### Restore from backup

```bash
# On a clean node:
systemctl stop docker
rm -rf /var/lib/docker/swarm
cp -a ./swarm-backup-YYYYMMDD-HHMMSS /var/lib/docker/swarm
systemctl start docker

# Force new cluster from restored state
docker swarm init --force-new-cluster --advertise-addr <MANAGER_IP>
```

### Single manager failure (quorum maintained)

```bash
# If 1 of 3 managers fails, quorum (2/3) is maintained
# Remove failed manager
docker node demote <FAILED_MANAGER>
docker node rm --force <FAILED_MANAGER>

# Add replacement manager
# On new node:
docker swarm join --token <MANAGER_TOKEN> <MANAGER_IP>:2377
docker node promote <NEW_NODE>
```

### Quorum loss (majority of managers down)

```bash
# Cluster is read-only — cannot schedule or update services
# On a surviving manager:
docker swarm init --force-new-cluster --advertise-addr <THIS_MANAGER_IP>

# This creates a new single-manager cluster preserving state
# Re-add other managers:
docker swarm join-token manager
# On each new manager node:
docker swarm join --token <TOKEN> <MANAGER_IP>:2377
```

### Complete cluster loss

If all managers are lost and no backup exists, state must be recreated:

```bash
# 1. Initialize fresh swarm
docker swarm init --advertise-addr <NEW_MANAGER_IP>

# 2. Recreate networks
docker network create --driver overlay frontend
docker network create --driver overlay --internal backend

# 3. Recreate secrets
echo "password" | docker secret create db_password -

# 4. Redeploy stacks
docker stack deploy -c docker-compose.yml myapp

# 5. Rejoin worker nodes
docker swarm join --token <WORKER_TOKEN> <MANAGER_IP>:2377
```

### Recovery checklist

1. ✅ Identify which managers are alive: `docker node ls`
2. ✅ Check quorum status: `docker info | grep -i raft`
3. ✅ If quorum exists, remove failed managers and add replacements.
4. ✅ If quorum lost, use `--force-new-cluster` on the healthiest manager.
5. ✅ If total loss, restore from backup or recreate from IaC.
6. ✅ Verify services: `docker service ls` and `docker service ps <SERVICE>`
7. ✅ Re-add workers as needed.
8. ✅ Ensure odd number of managers (3 or 5).
9. ✅ Update monitoring and alerting.
10. ✅ Document the incident and update runbooks.

### Prevention

- **Automated backups**: Cron job to backup `/var/lib/docker/swarm` on all managers.
- **Distribute managers**: Across availability zones / racks.
- **Monitor quorum**: Alert when manager count drops.
- **Infrastructure as Code**: Keep stack files, secrets (encrypted), and configs in version control.
- **Test recovery**: Regularly practice disaster recovery procedures.
