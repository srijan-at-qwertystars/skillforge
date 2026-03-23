# Kamal 2 Production Checklist

## Table of Contents

- [Pre-Deployment Checklist](#pre-deployment-checklist)
- [Server Hardening](#server-hardening)
- [Monitoring Setup](#monitoring-setup)
- [Backup Strategies for Accessories](#backup-strategies-for-accessories)
- [Secrets Rotation](#secrets-rotation)
- [CI/CD Pipeline Patterns](#cicd-pipeline-patterns)
- [Rollback Procedures](#rollback-procedures)

---

## Pre-Deployment Checklist

### First-Time Setup

- [ ] **DNS**: A records point to all server IPs (`dig +short myapp.example.com`)
- [ ] **SSH**: Key-based access works for all servers (`ssh deploy@server "hostname"`)
- [ ] **Docker Registry**: Credentials valid, can push/pull images
- [ ] **Secrets**: `.kamal/secrets` populated with all required env vars
- [ ] **Gitignore**: `.kamal/secrets` is in `.gitignore`
- [ ] **Health endpoint**: `/up` (or custom path) returns HTTP 200
- [ ] **Dockerfile**: Builds locally (`docker build -t test .`)
- [ ] **Port config**: `proxy.app_port` matches application listen port
- [ ] **Firewall**: Ports 22, 80, 443 open on all servers
- [ ] **Ruby**: Kamal CLI installed (`kamal version` shows 2.x)

### Every Deploy

- [ ] Tests pass in CI
- [ ] No pending destructive database migrations (use expand-contract pattern)
- [ ] Secrets unchanged or intentionally updated
- [ ] `kamal config` resolves without errors
- [ ] No active deploy lock (`kamal lock status`)
- [ ] Disk space sufficient on servers (`df -h` — need space for Docker images)
- [ ] Previous deploy is healthy (`kamal app details`)

### Pre-Production Validation

```bash
# Verify config resolves
kamal config

# Check all servers are reachable
kamal server exec "hostname && docker --version"

# Verify registry access
kamal registry login

# Dry-run build
docker build -t myapp:test .
docker run --rm -e PORT=3000 -p 3000:3000 myapp:test &
curl -s http://localhost:3000/up
```

---

## Server Hardening

### SSH Hardening

```bash
# /etc/ssh/sshd_config — apply these settings
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
Protocol 2
```

Restart SSH: `sudo systemctl restart ssh`

**Important**: Test SSH access in a separate terminal before closing your current session.

### Create Deploy User

```bash
# Create user with Docker access
sudo adduser --disabled-password deploy
sudo usermod -aG docker deploy

# Set up SSH key
sudo mkdir -p /home/deploy/.ssh
sudo cp ~/.ssh/authorized_keys /home/deploy/.ssh/
sudo chown -R deploy:deploy /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
sudo chmod 600 /home/deploy/.ssh/authorized_keys
```

### Firewall (UFW)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP - kamal-proxy + ACME challenges'
sudo ufw allow 443/tcp comment 'HTTPS - kamal-proxy'
sudo ufw enable
sudo ufw status verbose
```

**Do NOT** open accessory ports (5432, 6379) to the internet. They should only be
accessible via Docker network.

### Fail2ban

```bash
sudo apt install -y fail2ban

# /etc/fail2ban/jail.local
cat <<EOF | sudo tee /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF

sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

### Automatic Security Updates

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### Docker Hardening

```bash
# Limit Docker daemon exposure — only allow local socket (default)
# Do NOT enable Docker TCP socket without TLS

# Enable Docker content trust
export DOCKER_CONTENT_TRUST=1

# Log driver with rotation
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "live-restore": true,
  "userns-remap": "default"
}
EOF
sudo systemctl restart docker
```

### Kernel Tuning (Optional)

```bash
# /etc/sysctl.d/99-kamal.conf
cat <<EOF | sudo tee /etc/sysctl.d/99-kamal.conf
# Network performance
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1

# File descriptors
fs.file-max = 2097152

# VM tuning for databases
vm.swappiness = 10
vm.overcommit_memory = 1
EOF
sudo sysctl --system
```

---

## Monitoring Setup

### Application Health Monitoring

Create a lightweight monitoring script (see `scripts/health-check.sh` in this skill):

```bash
# Cron job — check every 5 minutes
*/5 * * * * /opt/kamal-monitoring/health-check.sh >> /var/log/kamal-health.log 2>&1
```

### kamal-proxy Metrics

kamal-proxy exposes request metrics via its logs. Parse them for monitoring:

```bash
# Extract request counts and response times from proxy logs
ssh deploy@server "docker logs kamal-proxy --since 1h 2>&1 | \
  grep -oP 'status=\K\d+' | sort | uniq -c | sort -rn"
```

### External Uptime Monitoring

Set up external HTTP checks with services like UptimeRobot, Pingdom, or self-hosted:

```bash
# Simple uptime check script
curl -sf -o /dev/null -w "%{http_code}" https://myapp.example.com/up || \
  curl -X POST "$ALERT_WEBHOOK" -d '{"text":"myapp is DOWN"}'
```

### Docker Resource Monitoring

```bash
# docker-stats-exporter.sh — run as cron
#!/bin/bash
docker stats --no-stream --format \
  "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" \
  >> /var/log/docker-stats.log
```

### Prometheus + Grafana Stack (via Accessories)

```yaml
accessories:
  prometheus:
    image: prom/prometheus:latest
    host: 10.0.1.10
    port: "9090:9090"
    volumes:
      - "prometheus_data:/prometheus"
      - "prometheus_config:/etc/prometheus"
  grafana:
    image: grafana/grafana:latest
    host: 10.0.1.10
    port: "3001:3000"
    volumes:
      - "grafana_data:/var/lib/grafana"
    env:
      clear:
        GF_SECURITY_ADMIN_PASSWORD: admin
```

### Log Aggregation

Ship container logs to a centralized service:

```yaml
servers:
  web:
    hosts: [10.0.1.10]
    options:
      log-driver: "fluentd"
      log-opt: "fluentd-address=localhost:24224"
      log-opt: "tag=myapp.web"
```

Or use Vector as a sidecar accessory:

```yaml
accessories:
  vector:
    image: timberio/vector:latest-alpine
    roles: [web]
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "vector_data:/var/lib/vector"
```

---

## Backup Strategies for Accessories

### PostgreSQL Backups

```bash
#!/bin/bash
# backup-postgres.sh — run via cron
BACKUP_DIR="/opt/backups/postgres"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CONTAINER="myapp-db"

mkdir -p "$BACKUP_DIR"

# Dump database
docker exec "$CONTAINER" pg_dumpall -U postgres | gzip > "$BACKUP_DIR/pg_${TIMESTAMP}.sql.gz"

# Keep last 7 daily backups
find "$BACKUP_DIR" -name "pg_*.sql.gz" -mtime +7 -delete

# Offsite copy (S3, B2, rsync)
aws s3 cp "$BACKUP_DIR/pg_${TIMESTAMP}.sql.gz" "s3://myapp-backups/postgres/"
```

Cron schedule:
```
0 2 * * * /opt/scripts/backup-postgres.sh >> /var/log/backup.log 2>&1
```

### Redis Backups

```bash
#!/bin/bash
BACKUP_DIR="/opt/backups/redis"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

# Trigger RDB save and copy
docker exec myapp-redis redis-cli BGSAVE
sleep 5
docker cp myapp-redis:/data/dump.rdb "$BACKUP_DIR/redis_${TIMESTAMP}.rdb"

find "$BACKUP_DIR" -name "redis_*.rdb" -mtime +7 -delete
```

### SQLite Backups (Litestream)

For apps using SQLite (Rails 8 default):

```yaml
accessories:
  litestream:
    image: litestream/litestream:latest
    host: 10.0.1.10
    volumes:
      - "myapp_storage:/data"
      - "litestream_config:/etc/litestream"
    cmd: replicate -config /etc/litestream/litestream.yml
```

### Backup Verification

```bash
# Test restore monthly
docker run --rm -v "$BACKUP_DIR:/backups" postgres:16-alpine \
  sh -c "createdb test_restore && pg_restore -d test_restore /backups/latest.sql.gz"
```

---

## Secrets Rotation

### Rotation Procedure

1. **Generate new credentials** (API keys, database passwords, etc.)
2. **Update `.kamal/secrets`** with new values
3. **Update external services** if applicable (registry tokens, API keys)
4. **Deploy**: `kamal deploy` — containers get new env vars
5. **Verify**: `kamal app exec "echo $ROTATED_VAR | head -c5"` (partial check)
6. **Invalidate old credentials** after confirming new ones work

### Registry Token Rotation

```bash
# GitHub — generate new PAT with packages:write scope
# Update .kamal/secrets
KAMAL_REGISTRY_PASSWORD=ghp_NEW_TOKEN_HERE

# Test
kamal registry login
kamal deploy
```

### Database Password Rotation

```bash
# 1. Update password in PostgreSQL
kamal accessory exec db "psql -U postgres -c \"ALTER USER myapp WITH PASSWORD 'new_password';\""

# 2. Update .kamal/secrets
DATABASE_URL=postgres://myapp:new_password@myapp-db:5432/myapp_production

# 3. Deploy with new credentials
kamal deploy

# 4. Verify
kamal app exec "bin/rails runner 'ActiveRecord::Base.connection.execute(\"SELECT 1\")'"
```

### Secrets from External Vaults

```bash
# .kamal/secrets — pull from 1Password
RAILS_MASTER_KEY=$(op read "op://Production/Rails/master-key")
DATABASE_URL=$(op read "op://Production/Postgres/url")

# Or AWS Secrets Manager
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id myapp/db \
  --query SecretString --output text | jq -r .password)
```

### Rotation Schedule

| Secret | Rotation Frequency | Method |
|---|---|---|
| Registry token | Every 90 days | Regenerate PAT |
| Database password | Every 90 days | ALTER USER + redeploy |
| Rails master key | Annually or on breach | Re-encrypt credentials |
| SSH keys | Annually | Generate new keypair |
| API keys | Per vendor policy | Regenerate + update secrets |
| SSL certs (LE) | Automatic | kamal-proxy handles renewal |

---

## CI/CD Pipeline Patterns

### Basic: Deploy on Push to Main

```yaml
name: Deploy
on:
  push:
    branches: [main]
concurrency:
  group: deploy-production
  cancel-in-progress: false
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bin/rails test
  deploy:
    needs: test
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: "3.3", bundler-cache: true }
      - uses: webfactory/ssh-agent@v0.9.0
        with: { ssh-private-key: "${{ secrets.SSH_DEPLOY_KEY }}" }
      - uses: docker/setup-buildx-action@v3
      - run: bundle exec kamal deploy
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.KAMAL_REGISTRY_PASSWORD }}
          RAILS_MASTER_KEY: ${{ secrets.RAILS_MASTER_KEY }}
```

### Multi-Environment: Staging + Production

```yaml
name: Deploy
on:
  push:
    branches: [main]
    tags: ['v*']
jobs:
  deploy-staging:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: "3.3", bundler-cache: true }
      - uses: webfactory/ssh-agent@v0.9.0
        with: { ssh-private-key: "${{ secrets.SSH_DEPLOY_KEY }}" }
      - run: bundle exec kamal deploy -d staging
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.KAMAL_REGISTRY_PASSWORD }}

  deploy-production:
    if: startsWith(github.ref, 'refs/tags/v')
    runs-on: ubuntu-latest
    environment: production     # Requires approval
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: "3.3", bundler-cache: true }
      - uses: webfactory/ssh-agent@v0.9.0
        with: { ssh-private-key: "${{ secrets.SSH_DEPLOY_KEY }}" }
      - run: bundle exec kamal deploy -d production
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.KAMAL_REGISTRY_PASSWORD }}
          RAILS_MASTER_KEY: ${{ secrets.RAILS_MASTER_KEY }}
```

### With Review Apps

```yaml
deploy-review:
  if: github.event_name == 'pull_request'
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: ruby/setup-ruby@v1
      with: { ruby-version: "3.3", bundler-cache: true }
    - uses: webfactory/ssh-agent@v0.9.0
      with: { ssh-private-key: "${{ secrets.SSH_DEPLOY_KEY }}" }
    - run: |
        export REVIEW_APP_HOST="pr-${{ github.event.number }}.review.example.com"
        bundle exec kamal deploy -d review
      env:
        KAMAL_REGISTRY_PASSWORD: ${{ secrets.KAMAL_REGISTRY_PASSWORD }}
```

---

## Rollback Procedures

### Immediate Rollback

```bash
# 1. List available versions
kamal app details   # Shows running + retained containers

# 2. Rollback to specific version
kamal rollback <VERSION_TAG>

# 3. Verify
kamal app details
curl -sf https://myapp.example.com/up
```

### Rollback with Database Consideration

If the failed deploy included database migrations:

```bash
# 1. Rollback app (instant — just switches container)
kamal rollback <PREVIOUS_VERSION>

# 2. If migration was non-destructive (add column), leave DB as-is
#    Old code simply ignores the new column

# 3. If migration was destructive, restore from backup
kamal accessory exec db "psql -U postgres -c 'SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 5;'"
# Then manually run down migrations if needed
```

### Automated Rollback on Health Check Failure

Kamal already does this automatically:
- If health check fails during deploy → old container keeps serving
- No manual rollback needed

For post-deploy issues detected by monitoring:

```bash
# In post-deploy hook or monitoring script
if ! curl -sf https://myapp.example.com/up; then
  kamal rollback "$PREVIOUS_VERSION"
  curl -X POST "$SLACK_WEBHOOK" -d '{"text":"⚠️ Auto-rollback triggered"}'
fi
```

### Container Retention for Rollback

```yaml
# deploy.yml
retain_containers: 5   # Keep 5 old containers for rollback
```

More retained containers = more rollback options but more disk usage.
Check disk: `ssh deploy@server "docker system df"`.

### Rollback Runbook

1. **Detect**: Monitoring alert or user report
2. **Assess**: Is it app code, config, or infrastructure?
3. **Communicate**: Notify team in Slack/chat
4. **Rollback**: `kamal rollback <version>` (takes seconds)
5. **Verify**: Check `/up`, test critical user flows
6. **Investigate**: Review logs, identify root cause
7. **Fix**: Create fix, test in staging, deploy when ready
8. **Post-mortem**: Document what happened and how to prevent it
