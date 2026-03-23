# Celery Production Deployment Guide

## Table of Contents

- [Systemd Unit Files](#systemd-unit-files)
  - [Celery Worker Service](#celery-worker-service)
  - [Celery Beat Service](#celery-beat-service)
  - [Managing Services](#managing-services)
- [Docker Compose Deployment](#docker-compose-deployment)
- [Kubernetes Deployment](#kubernetes-deployment)
  - [Worker Deployment with HPA](#worker-deployment-with-hpa)
  - [Beat Deployment](#beat-deployment)
  - [Flower Deployment](#flower-deployment)
- [Monitoring Stack](#monitoring-stack)
  - [Flower](#flower)
  - [Prometheus Metrics](#prometheus-metrics)
  - [Grafana Dashboards](#grafana-dashboards)
  - [Alerting Rules](#alerting-rules)
- [Log Aggregation](#log-aggregation)
- [Security Hardening](#security-hardening)
- [Scaling Strategies](#scaling-strategies)
  - [Horizontal vs Vertical Scaling](#horizontal-vs-vertical-scaling)
  - [Pool Types: Prefork vs Eventlet vs Gevent](#pool-types-prefork-vs-eventlet-vs-gevent)
  - [Autoscaling](#autoscaling)
  - [Queue-Based Scaling](#queue-based-scaling)

---

## Systemd Unit Files

### Celery Worker Service

```ini
# /etc/systemd/system/celery-worker.service
[Unit]
Description=Celery Worker Service
After=network.target redis.service postgresql.service
Wants=redis.service

[Service]
Type=forking
User=celery
Group=celery
WorkingDirectory=/srv/myproject
EnvironmentFile=/etc/conf.d/celery
ExecStart=/bin/sh -c '${CELERY_BIN} -A ${CELERY_APP} multi start ${CELERYD_NODES} \
    --pidfile=${CELERYD_PID_FILE} \
    --logfile=${CELERYD_LOG_FILE} \
    --loglevel=${CELERYD_LOG_LEVEL} \
    ${CELERYD_OPTS}'
ExecStop=/bin/sh -c '${CELERY_BIN} multi stopwait ${CELERYD_NODES} \
    --pidfile=${CELERYD_PID_FILE}'
ExecReload=/bin/sh -c '${CELERY_BIN} multi restart ${CELERYD_NODES} \
    --pidfile=${CELERYD_PID_FILE} \
    --logfile=${CELERYD_LOG_FILE} \
    --loglevel=${CELERYD_LOG_LEVEL} \
    ${CELERYD_OPTS}'
Restart=always
RestartSec=10
LimitNOFILE=65536

# Security hardening
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

**Environment file** (`/etc/conf.d/celery`):

```bash
# Name of nodes to start
CELERYD_NODES="worker1 worker2"

# Celery binary path
CELERY_BIN="/srv/myproject/venv/bin/celery"

# App instance to use
CELERY_APP="myproject"

# Extra arguments
CELERYD_OPTS="--time-limit=300 --concurrency=8 --max-tasks-per-child=200"

# Log and PID directories
CELERYD_PID_FILE="/var/run/celery/%n.pid"
CELERYD_LOG_FILE="/var/log/celery/%n%I.log"
CELERYD_LOG_LEVEL="INFO"
```

### Celery Beat Service

```ini
# /etc/systemd/system/celery-beat.service
[Unit]
Description=Celery Beat Scheduler
After=network.target redis.service
Wants=redis.service

[Service]
Type=simple
User=celery
Group=celery
WorkingDirectory=/srv/myproject
EnvironmentFile=/etc/conf.d/celery
ExecStart=/srv/myproject/venv/bin/celery -A myproject beat \
    --loglevel=INFO \
    --schedule=/var/lib/celery/celerybeat-schedule \
    --pidfile=/var/run/celery/beat.pid
Restart=always
RestartSec=10

# Security hardening
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Managing Services

```bash
# Create required directories
sudo mkdir -p /var/run/celery /var/log/celery /var/lib/celery
sudo chown celery:celery /var/run/celery /var/log/celery /var/lib/celery

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable celery-worker celery-beat
sudo systemctl start celery-worker celery-beat

# Operations
sudo systemctl status celery-worker
sudo systemctl restart celery-worker   # graceful restart
sudo journalctl -u celery-worker -f    # tail logs
```

---

## Docker Compose Deployment

Full production stack with health checks, resource limits, and proper configuration.

```yaml
# docker-compose.yml
version: "3.8"

x-celery-common: &celery-common
  build:
    context: .
    dockerfile: Dockerfile
  env_file: .env
  environment:
    CELERY_BROKER_URL: redis://redis:6379/0
    CELERY_RESULT_BACKEND: redis://redis:6379/1
  depends_on:
    redis:
      condition: service_healthy
  restart: unless-stopped
  volumes:
    - app-data:/srv/myproject/data

services:
  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes --maxmemory 256mb --maxmemory-policy allkeys-lru
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: "1.0"

  worker-default:
    <<: *celery-common
    command: >
      celery -A myproject worker
      --loglevel=INFO
      --concurrency=8
      --max-tasks-per-child=200
      --max-memory-per-child=200000
      -Q default
      -n default-worker@%h
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: "2.0"
      replicas: 2

  worker-priority:
    <<: *celery-common
    command: >
      celery -A myproject worker
      --loglevel=INFO
      --concurrency=4
      --max-tasks-per-child=100
      -Q high_priority
      -n priority-worker@%h
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: "1.0"

  beat:
    <<: *celery-common
    command: >
      celery -A myproject beat
      --loglevel=INFO
      --schedule=/tmp/celerybeat-schedule
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: "0.5"
      # CRITICAL: only one beat instance
      replicas: 1

  flower:
    <<: *celery-common
    command: >
      celery -A myproject flower
      --port=5555
      --broker_api=redis://redis:6379/0
      --basic_auth=${FLOWER_USER}:${FLOWER_PASSWORD}
      --persistent=True
      --db=/data/flower.db
    ports:
      - "5555:5555"
    volumes:
      - flower-data:/data
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: "0.5"

volumes:
  redis-data:
  app-data:
  flower-data:
```

**Dockerfile** for Celery workers:

```dockerfile
FROM python:3.12-slim

RUN groupadd -r celery && useradd -r -g celery celery
WORKDIR /srv/myproject

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

USER celery
```

---

## Kubernetes Deployment

### Worker Deployment with HPA

```yaml
# celery-worker-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: celery-worker
  labels:
    app: celery-worker
spec:
  replicas: 3
  selector:
    matchLabels:
      app: celery-worker
  template:
    metadata:
      labels:
        app: celery-worker
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9808"
    spec:
      containers:
        - name: worker
          image: myproject:latest
          command:
            - celery
            - -A
            - myproject
            - worker
            - --loglevel=INFO
            - --concurrency=4
            - --max-tasks-per-child=200
            - -Q
            - default,high_priority
          env:
            - name: CELERY_BROKER_URL
              valueFrom:
                secretKeyRef:
                  name: celery-secrets
                  key: broker-url
            - name: CELERY_RESULT_BACKEND
              valueFrom:
                secretKeyRef:
                  name: celery-secrets
                  key: result-backend
          resources:
            requests:
              memory: "256Mi"
              cpu: "500m"
            limits:
              memory: "1Gi"
              cpu: "2"
          livenessProbe:
            exec:
              command:
                - celery
                - -A
                - myproject
                - inspect
                - ping
                - --timeout=10
            initialDelaySeconds: 30
            periodSeconds: 60
            timeoutSeconds: 15
          readinessProbe:
            exec:
              command:
                - celery
                - -A
                - myproject
                - inspect
                - ping
                - --timeout=5
            initialDelaySeconds: 15
            periodSeconds: 30
      terminationGracePeriodSeconds: 300  # allow tasks to finish
---
# Horizontal Pod Autoscaler
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: celery-worker-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: celery-worker
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: Pods
      pods:
        metric:
          name: celery_queue_length
        target:
          type: AverageValue
          averageValue: "50"
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 4
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 2
          periodSeconds: 120
```

### Beat Deployment

```yaml
# celery-beat-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: celery-beat
spec:
  replicas: 1  # MUST be exactly 1
  strategy:
    type: Recreate  # prevent two beat instances during rollout
  selector:
    matchLabels:
      app: celery-beat
  template:
    metadata:
      labels:
        app: celery-beat
    spec:
      containers:
        - name: beat
          image: myproject:latest
          command:
            - celery
            - -A
            - myproject
            - beat
            - --loglevel=INFO
          env:
            - name: CELERY_BROKER_URL
              valueFrom:
                secretKeyRef:
                  name: celery-secrets
                  key: broker-url
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
```

### Flower Deployment

```yaml
# flower-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flower
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flower
  template:
    metadata:
      labels:
        app: flower
    spec:
      containers:
        - name: flower
          image: myproject:latest
          command:
            - celery
            - -A
            - myproject
            - flower
            - --port=5555
          ports:
            - containerPort: 5555
          env:
            - name: CELERY_BROKER_URL
              valueFrom:
                secretKeyRef:
                  name: celery-secrets
                  key: broker-url
            - name: FLOWER_BASIC_AUTH
              valueFrom:
                secretKeyRef:
                  name: celery-secrets
                  key: flower-auth
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: flower
spec:
  selector:
    app: flower
  ports:
    - port: 5555
      targetPort: 5555
```

---

## Monitoring Stack

### Flower

```bash
# Basic setup
celery -A myproject flower --port=5555 --basic_auth=admin:secretpass

# Persistent with broker API
celery -A myproject flower \
    --port=5555 \
    --persistent=True \
    --db=flower.db \
    --broker_api=redis://localhost:6379/0 \
    --basic_auth=admin:secretpass

# Behind reverse proxy
celery -A myproject flower \
    --url_prefix=flower \
    --port=5555
```

Key Flower metrics to watch:
- Active/reserved/scheduled task counts per worker
- Task success/failure rates
- Task execution time distribution
- Worker uptime and last heartbeat

### Prometheus Metrics

Use `celery-exporter` to expose Celery metrics for Prometheus:

```bash
pip install celery-exporter
celery-exporter --broker-url=redis://localhost:6379/0 --listen-address=0.0.0.0:9808
```

Alternatively, instrument within your app:

```python
from prometheus_client import Counter, Histogram, start_http_server
from celery.signals import task_prerun, task_postrun, task_failure

TASK_COUNTER = Counter("celery_tasks_total", "Total tasks", ["name", "state"])
TASK_DURATION = Histogram("celery_task_duration_seconds", "Task duration", ["name"])

@task_prerun.connect
def task_prerun_metric(sender=None, **kw):
    sender._metric_start = time.monotonic()

@task_postrun.connect
def task_postrun_metric(sender=None, state=None, **kw):
    elapsed = time.monotonic() - getattr(sender, "_metric_start", 0)
    TASK_COUNTER.labels(name=sender.name, state=state).inc()
    TASK_DURATION.labels(name=sender.name).observe(elapsed)

@task_failure.connect
def task_failure_metric(sender=None, **kw):
    TASK_COUNTER.labels(name=sender.name, state="FAILURE").inc()

# Start metrics server in worker
from celery.signals import worker_ready

@worker_ready.connect
def start_metrics_server(**kw):
    start_http_server(9808)
```

**Prometheus scrape config**:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: "celery"
    static_configs:
      - targets: ["celery-exporter:9808"]
    scrape_interval: 15s
```

### Grafana Dashboards

Key panels to include in your Celery dashboard:

| Panel | Query | Purpose |
|---|---|---|
| Task throughput | `rate(celery_tasks_total[5m])` | Tasks processed per second |
| Failure rate | `rate(celery_tasks_total{state="FAILURE"}[5m])` | Error rate |
| Task duration P95 | `histogram_quantile(0.95, celery_task_duration_seconds_bucket)` | Latency |
| Queue depth | `celery_queue_length` | Backlog |
| Active workers | `celery_workers` | Capacity |
| Worker memory | `process_resident_memory_bytes{job="celery"}` | Resource usage |

### Alerting Rules

```yaml
# prometheus-alerts.yml
groups:
  - name: celery
    rules:
      - alert: CeleryNoWorkers
        expr: celery_workers == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "No Celery workers running"

      - alert: CeleryHighFailureRate
        expr: rate(celery_tasks_total{state="FAILURE"}[5m]) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High task failure rate: {{ $value }}/s"

      - alert: CeleryQueueBacklog
        expr: celery_queue_length > 1000
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Queue backlog: {{ $value }} tasks"

      - alert: CeleryTaskLatency
        expr: histogram_quantile(0.95, rate(celery_task_duration_seconds_bucket[5m])) > 60
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "P95 task latency > 60s"
```

---

## Log Aggregation

### Structured JSON logging

```python
# celeryconfig.py
import logging
import json

class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_data = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "task_id": getattr(record, "task_id", None),
            "task_name": getattr(record, "task_name", None),
        }
        if record.exc_info:
            log_data["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_data)

# Apply to celery logger
worker_hijack_root_logger = False  # let us configure our own

from celery.signals import setup_logging

@setup_logging.connect
def configure_logging(**kwargs):
    handler = logging.StreamHandler()
    handler.setFormatter(JSONFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.INFO)
```

### Task context in logs

```python
from celery.utils.log import get_task_logger

logger = get_task_logger(__name__)  # automatically includes task_id in log records

@shared_task
def process_order(order_id):
    logger.info(f"Processing order {order_id}")
    # Log output: [task_id] Processing order 12345
```

### Collecting logs

```yaml
# Filebeat config for Celery logs
filebeat.inputs:
  - type: log
    paths:
      - /var/log/celery/*.log
    json.keys_under_root: true
    json.add_error_key: true
    fields:
      service: celery
output.elasticsearch:
  hosts: ["elasticsearch:9200"]
  index: "celery-logs-%{+yyyy.MM.dd}"
```

For Docker: logs go to stdout/stderr by default. Use Docker log driver
(`json-file`, `fluentd`, `gelf`) or a sidecar container.

---

## Security Hardening

### Message signing

```python
# Sign messages to prevent tampering
security_key = "/path/to/private.key"
security_certificate = "/path/to/cert.pem"
security_cert_store = "/path/to/certs/"  # trusted CA certs

# Enable auth serializer
from celery.security import setup_security
setup_security(
    allowed_serializers=["auth", "json"],
    key=security_key,
    cert=security_certificate,
    store=security_cert_store,
)
```

### Serializer restrictions

```python
# NEVER accept pickle in production
accept_content = ["json"]
task_serializer = "json"
result_serializer = "json"

# If pickle is required (trusted internal services only):
accept_content = ["json", "auth"]  # use auth serializer with message signing
```

### Broker security

```python
# Redis: require authentication
broker_url = "redis://:strongpassword@redis-host:6379/0"

# Redis over TLS
broker_url = "rediss://:password@redis-host:6380/0"
broker_use_ssl = {
    "ssl_cert_reqs": ssl.CERT_REQUIRED,
    "ssl_ca_certs": "/path/to/ca.pem",
    "ssl_certfile": "/path/to/client-cert.pem",
    "ssl_keyfile": "/path/to/client-key.pem",
}

# RabbitMQ: use dedicated vhost and user
broker_url = "amqp://celery_user:strongpass@rabbitmq:5672/celery_vhost"

# RabbitMQ over TLS
broker_use_ssl = {
    "keyfile": "/path/to/client-key.pem",
    "certfile": "/path/to/client-cert.pem",
    "ca_certs": "/path/to/ca.pem",
    "cert_reqs": ssl.CERT_REQUIRED,
}
```

### Worker process isolation

```bash
# Run as unprivileged user
celery -A myproject worker --uid=celery --gid=celery

# Systemd hardening (see unit file above)
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true
ReadOnlyDirectories=/
ReadWriteDirectories=/var/log/celery /var/run/celery /srv/myproject/data
```

### Network security

- Place broker on internal network, not publicly accessible
- Use network policies (Kubernetes) or security groups (AWS) to restrict access
- Enable TLS for all broker connections
- Rotate credentials regularly

---

## Scaling Strategies

### Horizontal vs Vertical Scaling

| Strategy | When to use | How |
|---|---|---|
| **Vertical** | CPU-bound tasks, single-node | Increase `--concurrency`, add CPU/RAM |
| **Horizontal** | I/O-bound, need redundancy | Add more worker containers/nodes |
| **Queue-based** | Mixed workloads | Dedicated workers per queue type |

### Pool Types: Prefork vs Eventlet vs Gevent

```bash
# Prefork (default) — best for CPU-bound tasks
# Creates child processes, true parallelism
celery -A myproject worker --pool=prefork --concurrency=8

# Gevent — best for I/O-bound tasks (HTTP calls, DB queries)
# Cooperative multitasking with green threads
pip install gevent
celery -A myproject worker --pool=gevent --concurrency=500

# Eventlet — similar to gevent, different patching mechanism
pip install eventlet
celery -A myproject worker --pool=eventlet --concurrency=500

# Solo — single-threaded, no child processes
# Useful for debugging or tasks that can't be forked
celery -A myproject worker --pool=solo
```

**Pool comparison**:

| Pool | Parallelism | Memory | Best for | Caveats |
|---|---|---|---|---|
| prefork | Multi-process | High | CPU-bound | ~30MB per child |
| gevent | Green threads | Low | I/O-bound | Must use gevent-compatible libs |
| eventlet | Green threads | Low | I/O-bound | Must use eventlet-compatible libs |
| solo | None | Minimal | Debugging | No concurrency |

**Critical**: With gevent/eventlet, all libraries must be cooperative (non-blocking).
Blocking calls (e.g., `time.sleep`, synchronous DB drivers) will block the entire
worker. Use `gevent.sleep`, async DB drivers, etc.

### Autoscaling

```bash
# Built-in autoscaling: min 2, max 10 processes
celery -A myproject worker --autoscale=10,2

# Scales based on task load — adds processes when busy, removes when idle
```

**Kubernetes HPA with custom metrics**:

```python
# Expose queue length as a Prometheus metric
# Then use prometheus-adapter to make it available as a Kubernetes metric
# HPA scales based on tasks-per-worker ratio
```

### Queue-Based Scaling

```python
# Separate queues for different workload types
app.conf.task_queues = [
    Queue("cpu_heavy"),
    Queue("io_bound"),
    Queue("batch"),
]

# Route tasks
app.conf.task_routes = {
    "myapp.tasks.render_video": {"queue": "cpu_heavy"},
    "myapp.tasks.fetch_data": {"queue": "io_bound"},
    "myapp.tasks.bulk_import": {"queue": "batch"},
}
```

```bash
# CPU-heavy worker: prefork, low concurrency, high resources
celery -A myproject worker -Q cpu_heavy --pool=prefork --concurrency=4

# I/O-bound worker: gevent, high concurrency
celery -A myproject worker -Q io_bound --pool=gevent --concurrency=500

# Batch worker: prefork, autoscale based on load
celery -A myproject worker -Q batch --pool=prefork --autoscale=20,2
```
