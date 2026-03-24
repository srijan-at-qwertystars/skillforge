# Advanced Docker Swarm Patterns

## Table of Contents

- [Blue-Green Deployments](#blue-green-deployments)
- [Canary Releases](#canary-releases)
- [Multi-Stack Architectures](#multi-stack-architectures)
- [Global Services for Monitoring Agents](#global-services-for-monitoring-agents)
- [Configs and Secrets Rotation Patterns](#configs-and-secrets-rotation-patterns)
- [Overlay Network Segmentation](#overlay-network-segmentation)
- [Swarm + Reverse Proxy (Traefik / Nginx)](#swarm--reverse-proxy-traefik--nginx)
- [Resource Reservation vs Limits](#resource-reservation-vs-limits)
- [Logging Drivers (Fluentd, GELF, Syslog)](#logging-drivers-fluentd-gelf-syslog)
- [Swarm vs Kubernetes Decision Matrix](#swarm-vs-kubernetes-decision-matrix)

---

## Blue-Green Deployments

Blue-green deployments in Swarm maintain two full service stacks simultaneously, switching traffic between them once the new version is validated.

### Strategy

1. Deploy the **blue** version as the active stack.
2. Deploy the **green** version alongside on a separate service name or port.
3. Validate green via health checks and smoke tests.
4. Update the reverse proxy / load balancer to route traffic to green.
5. Tear down blue after a soak period.

### Implementation

```yaml
# blue-green-web-blue.yml
version: "3.8"
services:
  web-blue:
    image: myapp:2.0
    deploy:
      replicas: 3
      labels:
        - "traefik.http.routers.web.rule=Host(`app.example.com`)"
        - "traefik.http.services.web.loadbalancer.server.port=8080"
    networks: [frontend]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 10s
      retries: 3

  web-green:
    image: myapp:2.1
    deploy:
      replicas: 3
      labels:
        - "traefik.http.routers.web-canary.rule=Host(`canary.app.example.com`)"
        - "traefik.http.services.web-canary.loadbalancer.server.port=8080"
    networks: [frontend]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 10s
      retries: 3

networks:
  frontend:
    external: true
```

### Switching traffic

```bash
# After validating green, update Traefik labels to point the production router to green
docker service update \
  --label-add "traefik.http.routers.web.rule=Host(\`app.example.com\`)" \
  --label-rm "traefik.http.routers.web-canary.rule" \
  myapp_web-green

# Scale down blue
docker service scale myapp_web-blue=0

# After soak period, remove blue entirely
docker service rm myapp_web-blue
```

### Alternative: DNS-based switching

Use an external DNS or load balancer (HAProxy, AWS ALB) to shift traffic between two Swarm services bound to different published ports.

```bash
# Blue on port 8080, green on port 8081
docker service create --name web-blue --publish 8080:8080 myapp:2.0
docker service create --name web-green --publish 8081:8080 myapp:2.1

# LB health check confirms green is healthy, shift VIP to port 8081
```

---

## Canary Releases

Canary releases route a fraction of traffic to the new version while the majority remains on the stable version.

### Using service update with parallelism

```bash
# Deploy v1 with 10 replicas
docker service create --name web --replicas 10 myapp:1.0

# Canary: update only 1 replica, then pause
docker service update \
  --image myapp:1.1 \
  --update-parallelism 1 \
  --update-delay 0s \
  --update-failure-action pause \
  --update-monitor 5m \
  --rollback-parallelism 1 \
  web

# Swarm updates 1 task, then pauses. Monitor:
docker service ps web
# If healthy, continue rollout:
docker service update --image myapp:1.1 web
# If unhealthy, rollback:
docker service rollback web
```

### Weighted canary with two services

For finer traffic control, run two separate services behind Traefik's weighted round-robin:

```yaml
version: "3.8"
services:
  web-stable:
    image: myapp:1.0
    deploy:
      replicas: 9
      labels:
        - "traefik.http.services.web-stable.loadbalancer.server.port=8080"
        - "traefik.http.services.web.weighted.services=web-stable@swarm,web-canary@swarm"
        - "traefik.http.services.web.weighted.services.web-stable@swarm.weight=90"
    networks: [frontend]

  web-canary:
    image: myapp:1.1
    deploy:
      replicas: 1
      labels:
        - "traefik.http.services.web-canary.loadbalancer.server.port=8080"
        - "traefik.http.services.web.weighted.services.web-canary@swarm.weight=10"
    networks: [frontend]

networks:
  frontend:
    external: true
```

Gradually increase `web-canary` weight and replicas while decreasing `web-stable`.

---

## Multi-Stack Architectures

Organize large deployments across multiple stacks for isolation, independent lifecycles, and team ownership.

### Pattern: Shared infrastructure + application stacks

```
infra-stack/          # Traefik, monitoring, logging
├── traefik
├── prometheus
├── grafana
└── fluentd

app-team-a-stack/     # Team A microservices
├── api
├── worker
└── db

app-team-b-stack/     # Team B microservices
├── frontend
├── backend
└── cache
```

### Cross-stack networking

Stacks cannot directly share networks by name. Use **external networks** created outside any stack:

```bash
# Create shared networks before deploying stacks
docker network create --driver overlay --attachable shared-frontend
docker network create --driver overlay --attachable shared-backend
```

```yaml
# In each stack's compose file
networks:
  frontend:
    external: true
    name: shared-frontend
  backend:
    external: true
    name: shared-backend
```

### Stack naming conventions

Use prefixes to avoid collisions:

- `infra-` for infrastructure stacks
- `app-<team>-` for application stacks
- `mon-` for monitoring stacks

Services are accessible as `<stack>_<service>` on shared networks.

### Independent lifecycle management

```bash
# Deploy infrastructure first
docker stack deploy -c infra-stack.yml infra

# Deploy app stacks independently
docker stack deploy -c team-a-stack.yml app-team-a
docker stack deploy -c team-b-stack.yml app-team-b

# Update only one team's stack
docker stack deploy -c team-a-stack.yml app-team-a
```

---

## Global Services for Monitoring Agents

Global services run exactly one task per node. Ideal for infrastructure agents.

### Typical global service pattern

```yaml
version: "3.8"
services:
  node-exporter:
    image: prom/node-exporter:v1.8.1
    deploy:
      mode: global
      resources:
        limits: { cpus: "0.1", memory: 64M }
        reservations: { cpus: "0.05", memory: 32M }
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
    networks: [monitoring]

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    deploy:
      mode: global
      resources:
        limits: { cpus: "0.2", memory: 128M }
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    networks: [monitoring]

  fluentd:
    image: fluent/fluentd:v1.17-1
    deploy:
      mode: global
      resources:
        limits: { cpus: "0.2", memory: 256M }
    volumes:
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
    configs:
      - source: fluentd_conf
        target: /fluentd/etc/fluent.conf
    networks: [monitoring]

networks:
  monitoring:
    driver: overlay

configs:
  fluentd_conf:
    file: ./fluentd/fluent.conf
```

### Constraining global services

```yaml
deploy:
  mode: global
  placement:
    constraints:
      - node.labels.monitoring == true
```

This restricts the global service to labeled nodes only — useful for GPU nodes or edge nodes where you want selective agent coverage.

---

## Configs and Secrets Rotation Patterns

Swarm configs and secrets are **immutable**. Rotation requires creating a new version and updating the service.

### Secret rotation workflow

```bash
# 1. Create new version of the secret
echo "new-password-value" | docker secret create db_password_v2 -

# 2. Update service: remove old secret, add new with same target name
docker service update \
  --secret-rm db_password \
  --secret-add source=db_password_v2,target=db_password \
  myapp_web

# 3. Verify service is healthy
docker service ps myapp_web

# 4. Remove old secret
docker secret rm db_password

# 5. Optionally rename for consistency (create v3 from v2 content)
docker secret inspect db_password_v2 --format '{{.Spec.Data}}' | \
  base64 -d | docker secret create db_password -
```

### Config rotation workflow

```bash
# 1. Create new config version
docker config create app_config_v2 ./config-v2.yml

# 2. Update service
docker service update \
  --config-rm app_config \
  --config-add source=app_config_v2,target=/app/config.yml,mode=0444 \
  myapp_web

# 3. Cleanup old config
docker config rm app_config
```

### Automated rotation with naming convention

Use timestamped names for tracking:

```bash
VERSION=$(date +%Y%m%d%H%M%S)
echo "rotated-password" | docker secret create "db_password_${VERSION}" -

docker service update \
  --secret-rm "$(docker service inspect myapp_web --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{.SecretName}} {{end}}' | tr ' ' '\n' | grep db_password)" \
  --secret-add "source=db_password_${VERSION},target=db_password" \
  myapp_web
```

### Rotation in stack deploy

When using `docker stack deploy`, update the compose file with a new config/secret name and redeploy. Swarm performs a rolling update automatically:

```yaml
secrets:
  db_password:
    name: db_password_v3   # Change version here
    external: true
```

```bash
docker stack deploy -c docker-compose.yml myapp
```

---

## Overlay Network Segmentation

Isolate services using multiple overlay networks to enforce network-level security boundaries.

### Network topology patterns

```
┌─────────────────────────────────────────────┐
│                 DMZ Network                  │
│  ┌─────────┐                                │
│  │ Traefik  │ ← external traffic            │
│  └────┬─────┘                                │
│       │                                      │
├───────┼──────────────────────────────────────┤
│       │       Frontend Network               │
│  ┌────┴─────┐  ┌──────────┐                 │
│  │   Web    │  │   API    │                  │
│  └──────────┘  └────┬─────┘                  │
│                     │                         │
├─────────────────────┼────────────────────────┤
│                     │  Backend Network        │
│               ┌─────┴────┐  ┌──────────┐    │
│               │  Worker   │  │   DB     │    │
│               └──────────┘  └──────────┘     │
└─────────────────────────────────────────────┘
```

### Creating segmented networks

```bash
# DMZ: only reverse proxy exposed externally
docker network create --driver overlay dmz

# Frontend: web and API services
docker network create --driver overlay frontend

# Backend: internal only, no external egress
docker network create --driver overlay --internal backend

# Encrypted sensitive network
docker network create --driver overlay --opt encrypted --internal secure-data
```

### Subnet allocation

```bash
docker network create --driver overlay \
  --subnet 10.10.1.0/24 \
  --gateway 10.10.1.1 \
  frontend

docker network create --driver overlay \
  --subnet 10.10.2.0/24 \
  --gateway 10.10.2.1 \
  backend
```

### Service-to-network mapping in compose

```yaml
services:
  traefik:
    networks: [dmz, frontend]
  web:
    networks: [frontend]
  api:
    networks: [frontend, backend]
  db:
    networks: [backend]
  cache:
    networks: [backend]
```

The database and cache are unreachable from the DMZ network — only the API bridges frontend and backend.

---

## Swarm + Reverse Proxy (Traefik / Nginx)

### Traefik with automatic service discovery

Traefik integrates natively with Swarm via Docker socket or API.

```yaml
version: "3.8"
services:
  traefik:
    image: traefik:v3.1
    command:
      - "--api.dashboard=true"
      - "--providers.swarm.endpoint=unix:///var/run/docker.sock"
      - "--providers.swarm.exposedByDefault=false"
      - "--entryPoints.web.address=:80"
      - "--entryPoints.websecure.address=:443"
      - "--certificatesResolvers.le.acme.httpChallenge.entryPoint=web"
      - "--certificatesResolvers.le.acme.email=admin@example.com"
      - "--certificatesResolvers.le.acme.storage=/acme/acme.json"
    deploy:
      placement:
        constraints: [node.role == manager]
      labels:
        - "traefik.http.routers.dashboard.rule=Host(`traefik.example.com`)"
        - "traefik.http.routers.dashboard.service=api@internal"
        - "traefik.http.routers.dashboard.middlewares=auth"
        - "traefik.http.middlewares.auth.basicauth.users=admin:$$apr1$$..."
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - acme-data:/acme
    networks:
      - frontend

  web:
    image: myapp:latest
    deploy:
      replicas: 3
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.web.rule=Host(`app.example.com`)"
        - "traefik.http.routers.web.entrypoints=websecure"
        - "traefik.http.routers.web.tls.certresolver=le"
        - "traefik.http.services.web.loadbalancer.server.port=8080"
    networks:
      - frontend

volumes:
  acme-data:

networks:
  frontend:
    driver: overlay
```

### Nginx reverse proxy pattern

For Nginx, use templated configs and reload on service changes:

```yaml
version: "3.8"
services:
  nginx:
    image: nginx:1.27
    deploy:
      replicas: 2
      placement:
        constraints: [node.role == manager]
    ports:
      - "80:80"
      - "443:443"
    configs:
      - source: nginx_conf
        target: /etc/nginx/nginx.conf
    networks:
      - frontend

configs:
  nginx_conf:
    file: ./nginx.conf
```

```nginx
# nginx.conf — upstream uses Swarm DNS
upstream web_backend {
    server web:8080;
}

server {
    listen 80;
    server_name app.example.com;

    location / {
        proxy_pass http://web_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Swarm's built-in DNS resolves `web` to the VIP of the service, load-balancing across replicas.

---

## Resource Reservation vs Limits

Understanding the difference is critical for cluster stability and scheduling.

| Aspect        | Reservation                            | Limit                                 |
|---------------|----------------------------------------|---------------------------------------|
| **Purpose**   | Guarantee minimum resources            | Cap maximum resources                 |
| **Scheduling**| Swarm uses reservations to decide placement | Not considered during scheduling |
| **Enforcement**| Soft guarantee (resources reserved)   | Hard cap (OOM kill if exceeded)       |
| **CPU**       | Shares of CPU time guaranteed          | Max CPU time allowed                  |
| **Memory**    | Minimum memory guaranteed              | Max memory before OOM kill            |

### Best practices

```yaml
deploy:
  resources:
    reservations:
      cpus: "0.25"
      memory: 256M
    limits:
      cpus: "1.0"
      memory: 1G
```

**Rules of thumb:**
- Set reservations to the **average** resource usage.
- Set limits to the **peak** resource usage + a safety margin.
- Total reservations across all services on a node must not exceed node capacity.
- Over-committing reservations prevents scheduling — services will show `no suitable node`.
- Under-setting limits causes OOM kills or CPU throttling.

### Checking available resources

```bash
# See node resources
docker node inspect --pretty <NODE_ID> | grep -A 5 Resources

# Check if scheduling failures are resource-related
docker service ps --no-trunc <SERVICE> | grep -i reject
```

### Memory reservation without limit (anti-pattern)

Without limits, a runaway container can consume all node memory and trigger the kernel OOM killer, potentially killing other containers or system processes. Always set memory limits.

---

## Logging Drivers (Fluentd, GELF, Syslog)

### Fluentd driver

```bash
docker service create --name web \
  --log-driver fluentd \
  --log-opt fluentd-address=fluentd.example.com:24224 \
  --log-opt fluentd-async=true \
  --log-opt fluentd-retry-wait=1s \
  --log-opt fluentd-max-retries=10 \
  --log-opt tag="docker.{{.Name}}.{{.ID}}" \
  myapp:latest
```

### GELF driver (Graylog Extended Log Format)

```bash
docker service create --name web \
  --log-driver gelf \
  --log-opt gelf-address=udp://graylog.example.com:12201 \
  --log-opt gelf-compression-type=gzip \
  --log-opt tag="{{.Name}}" \
  myapp:latest
```

### Syslog driver

```bash
docker service create --name web \
  --log-driver syslog \
  --log-opt syslog-address=tcp://syslog.example.com:514 \
  --log-opt syslog-facility=daemon \
  --log-opt syslog-format=rfc5424 \
  --log-opt tag="{{.Name}}/{{.ID}}" \
  myapp:latest
```

### Daemon-level default log driver

Set in `/etc/docker/daemon.json` on each node:

```json
{
  "log-driver": "fluentd",
  "log-opts": {
    "fluentd-address": "localhost:24224",
    "fluentd-async": "true",
    "tag": "docker.{{.Name}}"
  }
}
```

### Important considerations

- **`docker service logs` only works** with `json-file` and `journald` drivers. With other drivers, retrieve logs from the centralized logging system.
- Use `fluentd-async=true` to prevent container blocking if fluentd is unreachable.
- GELF over UDP is fire-and-forget — consider TCP for reliability.
- Set `max-buffer-size` to prevent memory exhaustion during log driver outages.

---

## Swarm vs Kubernetes Decision Matrix

| Criterion                   | Docker Swarm                        | Kubernetes                              |
|-----------------------------|-------------------------------------|-----------------------------------------|
| **Complexity**              | Low — built into Docker Engine      | High — separate control plane, etcd, etc.|
| **Learning curve**          | Hours to days                       | Weeks to months                         |
| **Setup time**              | Minutes (`swarm init`)              | Hours (kubeadm, managed, or distro)     |
| **Scaling**                 | Hundreds of nodes                   | Thousands of nodes                      |
| **Auto-scaling**            | Manual or custom scripts            | HPA, VPA, Cluster Autoscaler built-in   |
| **Service mesh**            | None built-in                       | Istio, Linkerd, Cilium                  |
| **Ingress**                 | Routing mesh + external LB          | Ingress controllers (many options)      |
| **Storage**                 | Volume plugins                      | CSI drivers, PV/PVC, StorageClasses     |
| **Secrets management**      | Built-in (encrypted Raft)           | Built-in (etcd, external vault)         |
| **Health checks**           | Container health checks             | Liveness, readiness, startup probes     |
| **Rolling updates**         | Built-in, simple config             | Built-in, sophisticated strategies      |
| **Ecosystem**               | Smaller, Docker-native              | Massive (CNCF landscape)               |
| **CI/CD integration**       | Simple (docker stack deploy)        | Helm, ArgoCD, Flux, many tools          |
| **Multi-tenancy**           | Stack-level isolation               | Namespace-level, RBAC, network policies |
| **Monitoring**              | Docker stats + external tools       | Prometheus operator, metrics server     |
| **Community & support**     | Smaller, declining                  | Largest container orchestration community|

### When to choose Swarm

- Small to medium deployments (< 100 nodes).
- Team already familiar with Docker Compose.
- Simple orchestration needs without service mesh.
- Rapid prototyping or staging environments.
- Resource-constrained environments (edge, IoT).
- No dedicated platform/DevOps team.

### When to choose Kubernetes

- Large-scale production (hundreds+ of nodes).
- Need auto-scaling, service mesh, advanced networking.
- Multi-team, multi-tenant environments.
- Regulatory compliance requiring RBAC and audit logging.
- Long-term investment with strong ecosystem needs.
- Managed Kubernetes available (EKS, GKE, AKS).
