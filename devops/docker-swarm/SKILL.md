---
name: docker-swarm
description: >
  Docker Swarm mode orchestration skill for multi-node container deployments.
  Use when: user mentions Docker Swarm, swarm mode, swarm init, service orchestration,
  docker service create, docker stack deploy, overlay networks, swarm rolling updates,
  swarm secrets, swarm configs, ingress routing mesh, manager/worker nodes, swarm cluster,
  multi-node Docker deployment, or service discovery in swarm.
  Do NOT use when: user asks about Kubernetes (k8s/kubectl/helm), standalone Docker Compose
  on a single host without swarm, AWS ECS/Fargate, HashiCorp Nomad, single-host Docker run
  commands, Docker Desktop local development, or container runtimes like containerd/CRI-O
  without swarm context.
---

# Docker Swarm Mode

## Swarm Initialization and Node Management

Initialize a swarm on the first manager node. Specify `--advertise-addr` when the host has multiple interfaces.

```bash
# Initialize swarm (first manager)
docker swarm init --advertise-addr <MANAGER_IP>

# Output includes a join token for workers. Retrieve tokens later:
docker swarm join-token worker
docker swarm join-token manager

# Join a worker node
docker swarm join --token <WORKER_TOKEN> <MANAGER_IP>:2377

# Join an additional manager node
docker swarm join --token <MANAGER_TOKEN> <MANAGER_IP>:2377

# List nodes
docker node ls

# Promote a worker to manager
docker node promote <NODE_ID>

# Demote a manager to worker
docker node demote <NODE_ID>

# Remove a node (run on manager)
docker node rm <NODE_ID>

# Force-remove a node that is down
docker node rm --force <NODE_ID>

# Label a node for placement constraints
docker node update --label-add zone=us-east-1a <NODE_ID>
docker node update --label-add type=gpu <NODE_ID>
```

Use 3 or 5 manager nodes for production. Never use an even number — Raft consensus requires a majority quorum. Distribute managers across failure domains.

## Services: Create, Scale, Update, Rollback

```bash
# Create a service
docker service create \
  --name web \
  --replicas 3 \
  --publish published=80,target=8080 \
  --env APP_ENV=production \
  --limit-cpu 0.5 \
  --limit-memory 512M \
  --reserve-cpu 0.25 \
  --reserve-memory 256M \
  nginx:1.27

# List services
docker service ls

# Inspect a service
docker service inspect --pretty web

# View service tasks/containers
docker service ps web

# Scale a service
docker service scale web=5

# Scale multiple services
docker service scale web=5 api=3 worker=10

# Update a service image
docker service update --image nginx:1.28 web

# Rollback to previous version
docker service rollback web

# Remove a service
docker service rm web
```

### Global Services

Deploy exactly one task per node (useful for monitoring agents, log collectors):

```bash
docker service create --name node-exporter --mode global \
  --mount type=bind,src=/proc,dst=/host/proc,readonly prom/node-exporter
```

## Stack Deploy with docker-compose.yml

Stacks deploy multi-service applications from a Compose file (version 3.x+).

```yaml
# docker-compose.yml
version: "3.8"
services:
  web:
    image: myapp:2.1
    deploy:
      replicas: 3
      update_config: { parallelism: 1, delay: 10s, order: start-first, failure_action: rollback }
      rollback_config: { parallelism: 1, delay: 5s }
      restart_policy: { condition: on-failure, delay: 5s, max_attempts: 3 }
      resources:
        limits: { cpus: "0.5", memory: 512M }
        reservations: { cpus: "0.25", memory: 256M }
      placement:
        constraints: [node.role == worker, node.labels.zone == us-east-1a]
        preferences: [{ spread: node.labels.zone }]
    ports: ["80:8080"]
    networks: [frontend, backend]
    secrets: [db_password]
    configs:
      - source: app_config
        target: /app/config.yml
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
  db:
    image: postgres:16
    deploy:
      replicas: 1
      placement: { constraints: [node.labels.type == database] }
    volumes: [db_data:/var/lib/postgresql/data]
    networks: [backend]
    secrets: [db_password]
    environment: { POSTGRES_PASSWORD_FILE: /run/secrets/db_password }
networks:
  frontend: { driver: overlay }
  backend: { driver: overlay, internal: true }
volumes:
  db_data: { driver: local }
secrets:
  db_password: { external: true }
configs:
  app_config: { file: ./config.yml }
```

```bash
# Deploy a stack
docker stack deploy -c docker-compose.yml myapp

# List stacks
docker stack ls

# List services in a stack
docker stack services myapp

# List tasks in a stack
docker stack ps myapp

# Remove a stack
docker stack rm myapp

# Deploy with multiple compose files (overrides)
docker stack deploy -c base.yml -c production.yml myapp
```

## Overlay Networks and Service Discovery

```bash
docker network create --driver overlay --attachable my-overlay
docker network create --driver overlay --opt encrypted secure-net  # encrypted
docker network create --driver overlay --internal backend-net      # no external access
docker service update --network-add my-overlay web                 # attach to existing service
```

Services on the same overlay resolve each other by service name via built-in DNS (e.g., `http://api:8080`).

Required ports between swarm nodes: TCP 2377 (management), TCP/UDP 7946 (node comms), UDP 4789 (VXLAN overlay).

## Secrets and Configs Management

### Secrets

Secrets are encrypted at rest in the Raft log and mounted at `/run/secrets/<name>` inside containers.

```bash
docker secret create db_password ./db_password.txt               # from file
echo "s3cureP@ss" | docker secret create db_password -           # from stdin
docker secret ls                                                  # list
docker secret inspect db_password                                 # metadata only

# Rotate a secret
echo "newP@ss" | docker secret create db_password_v2 -
docker service update --secret-rm db_password \
  --secret-add source=db_password_v2,target=db_password web
docker secret rm db_password
```

### Configs

Configs store non-sensitive data and mount into containers.

```bash
docker config create app_config ./config.yml
docker config ls
docker service create --name web \
  --config source=app_config,target=/app/config.yml,mode=0444 myapp:latest

# Rotate a config
docker config create app_config_v2 ./config_v2.yml
docker service update --config-rm app_config \
  --config-add source=app_config_v2,target=/app/config.yml web
```

## Rolling Updates and Health Checks

Configure update behavior to achieve zero-downtime deployments.

```bash
# Update with rolling strategy
docker service update \
  --image myapp:2.2 \
  --update-parallelism 2 \
  --update-delay 10s \
  --update-order start-first \
  --update-failure-action rollback \
  --update-max-failure-ratio 0.25 \
  --update-monitor 30s \
  web
```

- `parallelism`: number of tasks updated simultaneously.
- `delay`: wait time between updating batches.
- `order`: `start-first` starts new task before stopping old (blue-green); `stop-first` stops old first.
- `failure_action`: `rollback` auto-reverts on failure; `pause` halts the update.
- `max-failure-ratio`: tolerated failure fraction before triggering failure_action.
- `monitor`: observation window after each task update to detect failures.

### Health Check Configuration

```bash
docker service create \
  --name api \
  --health-cmd "curl -f http://localhost:8080/health || exit 1" \
  --health-interval 15s \
  --health-timeout 5s \
  --health-retries 3 \
  --health-start-period 30s \
  myapp:latest
```

Swarm uses health checks to determine task readiness during rolling updates. Unhealthy tasks trigger restart or rollback depending on configuration.

## Placement Constraints and Preferences

```bash
docker service create --constraint 'node.role == worker' --name web myapp
docker service create --constraint 'node.labels.zone == us-east-1a' --name web myapp

# Multiple constraints (AND logic)
docker service create --constraint 'node.role == worker' \
  --constraint 'node.labels.type == compute' --name web myapp

# Spread across zones
docker service create --placement-pref 'spread=node.labels.zone' --name web myapp
```

Constraint fields: `node.id`, `node.hostname`, `node.role`, `node.platform.os`, `node.platform.arch`, `node.labels.<key>`, `engine.labels.<key>`.

## Volumes and Persistent Storage

```bash
# Named volume (local driver)
docker service create --name db \
  --mount type=volume,src=pgdata,dst=/var/lib/postgresql/data postgres:16

# Bind mount (ties to host path, use sparingly)
docker service create --name web \
  --mount type=bind,src=/srv/static,dst=/app/static,readonly myapp

# NFS volume (shared across nodes)
docker service create --name web \
  --mount 'type=volume,src=shared,dst=/data,volume-driver=local,volume-opt=type=nfs,volume-opt=o=addr=nfs.example.com,volume-opt=device=:/exports/data' myapp

# tmpfs mount (in-memory)
docker service create --name cache \
  --mount type=tmpfs,dst=/tmp,tmpfs-size=100M redis:7
```

For multi-node persistence, use NFS, GlusterFS, or volume plugins (REX-Ray, Portworx). Local volumes only persist on the scheduled node.

## Load Balancing: Routing Mesh and Ingress

Swarm uses an ingress routing mesh by default — publishing a port makes it accessible on every node.

```bash
# Routing mesh (default)
docker service create --name web --publish published=80,target=8080 myapp

# Host mode (bypass mesh, preserves client IP)
docker service create --name web --mode global \
  --publish published=80,target=8080,mode=host myapp
```

Use host mode with an external load balancer (HAProxy, Nginx, Traefik) for client IP preservation.

```bash
# Traefik as ingress controller
docker service create --name traefik --publish 80:80 --publish 443:443 \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock,readonly \
  --network frontend --constraint 'node.role == manager' \
  traefik:v3.0 --providers.swarm.endpoint=unix:///var/run/docker.sock
```

## Monitoring and Logging

```bash
docker service logs web                          # view logs
docker service logs --follow --tail 100 web      # follow recent
docker service logs --since 1h web               # last hour

# Set log driver per service
docker service create --name web \
  --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 myapp
```

Use centralized logging (fluentd, Loki, GELF driver) in production. For monitoring, deploy Prometheus + Grafana + node-exporter (global) + cAdvisor as a stack.

```bash
# Expose Docker metrics (add to /etc/docker/daemon.json on each node)
# { "metrics-addr": "0.0.0.0:9323", "experimental": true }
docker stats                                     # quick resource check
docker service ps --format "table {{.Name}}\t{{.Node}}\t{{.CurrentState}}" web
```

## High Availability: Manager Quorum and Drain

### Manager Quorum

| Managers | Quorum | Tolerated Failures |
|----------|--------|--------------------|
| 3        | 2      | 1                  |
| 5        | 3      | 2                  |
| 7        | 4      | 3                  |

Never exceed 7 managers — more adds latency without benefit.

### Node Drain and Maintenance

```bash
docker node update --availability drain <NODE_ID>    # reschedule tasks away
docker node update --availability active <NODE_ID>   # return to active
docker node update --availability pause <NODE_ID>    # no new tasks, keep existing
```

### Disaster Recovery

```bash
cp -r /var/lib/docker/swarm ./swarm-backup-$(date +%Y%m%d)      # backup state
docker swarm init --force-new-cluster --advertise-addr <MANAGER_IP>  # last resort recovery
```

## Security: TLS and Certificate Rotation

Swarm enables mutual TLS by default for all node communication with auto-rotating certificates.

```bash
docker info --format '{{.Swarm.Cluster.TLSInfo}}'    # view CA info
docker swarm update --cert-expiry 720h                # set rotation interval
docker swarm ca --rotate                              # rotate root CA
docker swarm update --autolock=true                   # require unlock key on restart
docker swarm unlock                                   # unlock after restart
```

Keep the unlock key secure and backed up.

### Additional Hardening

- Set `--availability drain` on managers to avoid scheduling app containers on them.
- Never expose TCP 2375 without TLS; restrict Docker socket access.
- Scan images before deploying (`docker scout`, Trivy, Snyk).
- Use `--read-only` containers where possible.

## Troubleshooting Common Issues

### Service Not Starting

```bash
docker service ps --no-trunc web    # check task errors
docker inspect <TASK_ID>            # inspect specific task
```

Common causes: image not found, insufficient resources, over-constrained placement, port conflicts.

### Network and Node Troubleshooting

```bash
nc -zv <NODE_IP> 2377 && nc -zvu <NODE_IP> 4789 && nc -zv <NODE_IP> 7946  # port check
docker network inspect my-overlay                                          # network peers
docker exec <CONTAINER_ID> nslookup api                                    # DNS test
docker node inspect --pretty <NODE_ID>                                     # node status
docker service update --force web                                          # force rebalance
docker node demote <LOST_NODE> && docker node rm --force <LOST_NODE>       # remove lost node
```

### Raft/Quorum Loss

If quorum is lost (majority of managers down), the cluster becomes read-only. Recover by restoring managers or using `--force-new-cluster` as last resort.

### Debugging Checklist

1. `docker service ps --no-trunc <SERVICE>` — task errors.
2. `docker service logs <SERVICE>` — application logs.
3. `docker node ls` — all nodes Ready/Active.
4. `docker network inspect <NETWORK>` — network peers.
5. Check firewall rules for ports 2377, 7946, 4789.
6. Verify DNS resolution between services on overlay.
7. `docker node inspect --pretty <NODE>` — resource availability.
8. `journalctl -u docker` on affected nodes — daemon logs.

## References

In-depth guides in the `references/` directory:

- **[Advanced Patterns](references/advanced-patterns.md)** — Blue-green deployments, canary releases, multi-stack architectures, global services for monitoring agents, configs/secrets rotation patterns, overlay network segmentation, Swarm + Traefik/Nginx reverse proxy, resource reservation vs limits, logging drivers (fluentd, GELF, syslog), and Swarm vs Kubernetes decision matrix.
- **[Troubleshooting](references/troubleshooting.md)** — Services not scheduling, image pull failures, overlay network connectivity, DNS resolution failures, split-brain with even managers, certificate rotation failures, volume mount issues across nodes, log driver failures, ingress network congestion, stuck tasks, and disaster recovery procedures.

## Scripts

Ready-to-use operational scripts in `scripts/` (all executable):

| Script | Purpose |
|--------|---------|
| [`init-swarm.sh`](scripts/init-swarm.sh) | Initialize a Swarm cluster: create manager, join workers via SSH, configure autolock, set cert expiry, create overlay network |
| [`deploy-stack.sh`](scripts/deploy-stack.sh) | Deploy a stack with pre-flight checks: image availability, network existence, secret creation, port conflicts, convergence wait |
| [`health-check.sh`](scripts/health-check.sh) | Cluster health check: node status, quorum, service replicas, task states, network connectivity, certificate expiry, disk usage |

### Quick usage

```bash
# Initialize a 3-node cluster
./scripts/init-swarm.sh --advertise-addr 10.0.1.1 --workers 10.0.1.2,10.0.1.3 --autolock

# Deploy with pre-flight checks
./scripts/deploy-stack.sh -f docker-compose.yml -n myapp --with-registry-auth --create-networks

# Run health check
./scripts/health-check.sh
./scripts/health-check.sh --quiet            # failures/warnings only
./scripts/health-check.sh --cert-warn 14     # warn if certs expire within 14 days
```

## Assets

Production-ready stack templates in `assets/`:

| Template | Description |
|----------|-------------|
| [`docker-stack.yml`](assets/docker-stack.yml) | Full stack: Nginx reverse proxy, web app, PostgreSQL, Redis, Prometheus, Node Exporter (global), Grafana — with secrets, configs, health checks, resource limits, and rolling update configuration |
| [`traefik-stack.yml`](assets/traefik-stack.yml) | Traefik v3 reverse proxy: automatic Let's Encrypt SSL, Swarm service discovery, dashboard with basic auth, security headers, rate limiting, compression, Prometheus metrics endpoint |

### Deploying with assets

```bash
# Create prerequisites
docker network create --driver overlay --attachable frontend
docker network create --driver overlay --internal backend
docker network create --driver overlay monitoring
echo "db-pass" | docker secret create db_password -

# Deploy production stack
docker stack deploy -c assets/docker-stack.yml myapp

# Deploy Traefik ingress
docker network create --driver overlay --attachable traefik-public
docker stack deploy -c assets/traefik-stack.yml traefik
```
<!-- tested: pass -->
