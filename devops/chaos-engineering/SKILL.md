---
name: chaos-engineering
description: |
  Guide chaos engineering experiments: fault injection, resilience testing, GameDay planning, steady-state hypothesis, blast radius control, and abort conditions. Covers tools (Chaos Monkey, Litmus, Chaos Mesh, Gremlin, AWS FIS, Toxiproxy, tc/iptables), failure types (network latency/partition, CPU/memory/disk stress, pod/container kill, DNS failures), observability integration, chaos in CI/CD pipelines, and compliance (SOC2). Triggers: "chaos testing", "fault injection", "resilience testing", "chaos experiment", "GameDay planning", "failure injection", "chaos monkey setup", "blast radius". NOT for load testing or performance benchmarks. NOT for unit testing or integration testing frameworks. NOT for security penetration testing or vulnerability scanning. NOT for disaster recovery planning without fault injection.
---

# Chaos Engineering

## Core Principles (principlesofchaos.org)

1. **Define steady state** — Measurable normal behavior: throughput, error rate, latency p50/p95/p99.
2. **Hypothesize continuity** — "When [fault], [metric] stays within [tolerance]."
3. **Inject real-world failures** — Simulate actual production failure modes.
4. **Run in production** — Staging diverges from reality. Prefer production with controls.
5. **Minimize blast radius** — One pod, one AZ, one dependency. Expand after validation.
6. **Automate** — Codify experiments as version-controlled, CI/CD-integrated artifacts.

## Steady-State Hypothesis

Every experiment MUST start with a hypothesis:

```
Title: [Name]
Steady State: [Metric] within [threshold] during normal operation
Hypothesis: When [fault] injected into [target], [metric] remains
            within [threshold] OR recovers within [duration]
Abort When: [metric] exceeds [critical threshold] for [duration]
```

## Failure Injection Types

### Network Failures

**Latency injection (tc):**
```bash
# Add 200ms ± 50ms jitter
tc qdisc add dev eth0 root netem delay 200ms 50ms distribution normal
# Targeted to specific destination
tc qdisc add dev eth0 root handle 1: prio
tc qdisc add dev eth0 parent 1:3 handle 30: netem delay 200ms
tc filter add dev eth0 parent 1:0 protocol ip u32 match ip dst 10.0.1.0/24 flowid 1:3
# Remove
tc qdisc del dev eth0 root
```

**Packet loss/corruption (tc):**
```bash
tc qdisc add dev eth0 root netem loss 10%               # 10% loss
tc qdisc add dev eth0 root netem corrupt 5%              # 5% corruption
tc qdisc add dev eth0 root netem delay 100ms loss 5% corrupt 1%  # combined
```

**Network partition (iptables):**
```bash
iptables -A OUTPUT -d 10.0.2.0/24 -j DROP               # block service
iptables -A OUTPUT -p tcp --dport 5432 -j DROP           # block port
iptables -D OUTPUT -d 10.0.2.0/24 -j DROP               # revert
```

**DNS failure:**
```bash
iptables -A OUTPUT -p udp --dport 53 -j DROP             # block DNS
iptables -A OUTPUT -p tcp --dport 53 -j DROP
```

**Toxiproxy (app-level):**
```bash
toxiproxy-cli create payment_svc -l 0.0.0.0:8474 -u payment-svc:8080
toxiproxy-cli toxic add payment_svc -t latency -a latency=2000 -a jitter=500
toxiproxy-cli toxic add payment_svc -t timeout -a timeout=5000
toxiproxy-cli toxic add payment_svc -t bandwidth -a rate=10    # 10 KB/s
```

### Resource Stress

```bash
# CPU: 4 cores for 60s
stress-ng --cpu 4 --timeout 60s
# CPU: 80% load
stress-ng --cpu 0 --cpu-load 80 --timeout 120s
# Memory: allocate 2GB
stress-ng --vm 1 --vm-bytes 2G --timeout 60s
# Disk I/O saturation
stress-ng --io 4 --timeout 60s
# Disk fill
fallocate -l 50G /tmp/disk-pressure-test && rm /tmp/disk-pressure-test
```

### Container/Pod Kill

```bash
# Kubernetes: kill specific pod
kubectl delete pod payment-svc-abc123 -n production --grace-period=0
# Kill random pod by label
kubectl get pods -n production -l app=payment-svc -o name | shuf -n 1 | \
  xargs kubectl delete -n production --grace-period=0
# Drain node (simulate node failure)
kubectl drain node-1 --ignore-daemonsets --delete-emptydir-data --force
# Docker: SIGKILL
docker kill --signal=SIGKILL <container_id>
# Docker: freeze/unfreeze
docker pause <container_id> && sleep 30 && docker unpause <container_id>
```

## Tool Selection

| Tool | Platform | Best For | Fault Types |
|------|----------|----------|-------------|
| **Chaos Monkey** | AWS/GCP/K8s | Instance/pod kill | Kill only |
| **LitmusChaos** | Kubernetes | Orchestrated experiments, CI/CD | Network, pod, node, disk, DNS |
| **Chaos Mesh** | Kubernetes | CRD-based fine-grained faults | Pod, network, I/O, CPU, time, DNS |
| **Gremlin** | Any (SaaS) | Enterprise, multi-env, managed | All types, GUI-driven |
| **AWS FIS** | AWS | AWS-native resource faults | EC2, ECS, RDS, network, AZ |
| **Toxiproxy** | Any | App-level network simulation | Latency, bandwidth, timeout |
| **tc/iptables** | Linux | Low-level network manipulation | Latency, loss, partition |

### LitmusChaos Example

```yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: payment-svc-pod-kill
  namespace: production
spec:
  appinfo:
    appns: production
    applabel: app=payment-svc
    appkind: deployment
  chaosServiceAccount: litmus-admin
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "60"
            - name: CHAOS_INTERVAL
              value: "10"
            - name: FORCE
              value: "true"
            - name: PODS_AFFECTED_PERC
              value: "50"
```

### Chaos Mesh Example

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: payment-svc-latency
  namespace: production
spec:
  action: delay
  mode: all
  selector:
    namespaces: [production]
    labelSelectors:
      app: payment-svc
  delay:
    latency: "500ms"
    jitter: "100ms"
    correlation: "50"
  duration: "5m"
```

### AWS FIS Example

```json
{
  "description": "Terminate 30% of EC2 in us-east-1a",
  "targets": {
    "ec2-instances": {
      "resourceType": "aws:ec2:instance",
      "selectionMode": "PERCENT(30)",
      "resourceTags": { "chaos-enabled": "true" },
      "filters": [
        { "path": "Placement.AvailabilityZone", "values": ["us-east-1a"] }
      ]
    }
  },
  "actions": {
    "stop-instances": {
      "actionId": "aws:ec2:stop-instances",
      "parameters": { "startInstancesAfterDuration": "PT5M" },
      "targets": { "Instances": "ec2-instances" }
    }
  },
  "stopConditions": [
    { "source": "aws:cloudwatch:alarm", "value": "arn:aws:cloudwatch:...:alarm:HighErrorRate" }
  ],
  "roleArn": "arn:aws:iam::ACCOUNT:role/FISRole"
}
```

## Blast Radius Control

Apply to every experiment:

1. **Scope** — One service, one AZ, or one replica. Never full-fleet initially.
2. **Time-box** — Set max duration with auto-revert on expiry.
3. **Namespace isolation** — Dedicated namespace or tag-selected resources only.
4. **Traffic fraction** — Route partial traffic through fault path via feature flags or weighted routing.
5. **Progressive escalation** — 1 pod → 10% → 50% → full service → cross-service.
6. **Opt-in tagging** — Only target resources tagged `chaos-enabled: true`.

## Abort Conditions

Define BEFORE every experiment. Automate enforcement:

```yaml
abort_conditions:
  - metric: error_rate_5xx
    threshold: "> 5%"
    duration: "30s"
    action: rollback
  - metric: p99_latency_ms
    threshold: "> 10000"
    duration: "15s"
    action: rollback
  - metric: customer_impact_detected
    threshold: "true"
    action: immediate_halt
  - metric: data_loss_indicator
    threshold: "any"
    action: immediate_halt_and_page
```

Implement via: CloudWatch Alarms → FIS stop conditions, Prometheus rules → webhook, Gremlin halt conditions (built-in), or manual kill switch accessible to all team members.

## GameDay Planning

### Pre-GameDay Checklist

- [ ] Hypothesis documented and reviewed
- [ ] Steady-state metrics baselined (24h minimum)
- [ ] Blast radius defined and approved
- [ ] Abort conditions configured and tested
- [ ] Rollback procedure validated
- [ ] Stakeholders notified (engineering, support, management)
- [ ] Observability dashboards prepared
- [ ] Communication channel established (dedicated Slack channel)
- [ ] GameDay commander assigned
- [ ] Incident response team on standby
- [ ] Change management ticket filed (required for SOC2)
- [ ] Experiment runbook peer-reviewed

### Execution Flow

1. **Brief** — Review hypothesis, scope, abort criteria with all participants.
2. **Baseline** — Capture steady-state. Screenshot dashboards.
3. **Inject** — Start fault. Begin timer.
4. **Observe** — Monitor dashboards, logs, alerts. Document anomalies live.
5. **Evaluate** — Did system match hypothesis? Record deviations.
6. **Abort/Complete** — Trigger abort if thresholds breached, or let experiment finish.
7. **Recover** — Verify return to steady state. Validate data integrity.
8. **Debrief** — Blameless retro. Document findings, action items, next experiments.

## Observability Integration

Instrument BEFORE any experiment:

- **Metrics**: Request rate, error rate, latency percentiles, saturation (CPU/mem/disk/connections).
- **Logs**: Structured with correlation IDs. Centralized (ELK, Loki, CloudWatch Logs).
- **Traces**: Distributed tracing (Jaeger, Zipkin, X-Ray, OpenTelemetry) for cascading failure detection.
- **Alerts**: Pre-configured for abort conditions. Must fire within seconds.

### Prometheus Abort Rules

```yaml
groups:
  - name: chaos-experiment-safety
    rules:
      - alert: ChaosAbortErrorRate
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[1m]))
          / sum(rate(http_requests_total[1m])) > 0.05
        for: 30s
        labels: { severity: critical, chaos: abort }
        annotations:
          summary: "Error rate >5% — abort chaos experiment"
      - alert: ChaosAbortLatency
        expr: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[1m])) > 10
        for: 15s
        labels: { severity: critical, chaos: abort }
```

### Chaos Dashboard Layout

```
Row 1: Experiment Status | Blast Radius | Time Remaining
Row 2: Request Rate | Error Rate (4xx/5xx) | p50/p95/p99 Latency
Row 3: CPU/Memory/Disk per target | Network I/O | Connection Pool
Row 4: Upstream/Downstream Impact | Customer-Facing Metrics | Alert Status
```

## Chaos in CI/CD Pipelines

### Pipeline Integration (GitHub Actions)

```yaml
name: Chaos Gate
on:
  push:
    branches: [main]
jobs:
  deploy-staging:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./deploy.sh staging
  chaos-test:
    needs: deploy-staging
    runs-on: ubuntu-latest
    steps:
      - name: Baseline steady state
        run: ./scripts/capture-baseline.sh
      - name: Run chaos experiment
        run: |
          chaos run experiment.json \
            --rollback-strategy=automatic \
            --abort-on-error-rate=5 \
            --duration=300
      - name: Validate recovery
        run: ./scripts/validate-steady-state.sh
      - name: Report results
        if: always()
        run: ./scripts/report-chaos-results.sh
  promote-production:
    needs: chaos-test
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh production
```

### Maturity Levels

| Level | Practice | Automation |
|-------|----------|------------|
| 1 | Ad-hoc GameDays, manual injection | None |
| 2 | Scripted experiments, documented hypotheses | Cron-triggered |
| 3 | Chaos gate in CI/CD, auto-abort | Pipeline-native |
| 4 | Continuous chaos in production, self-healing | Full automation + ML detection |

## Compliance / SOC2

Chaos engineering provides evidence for SOC2 Trust Service Criteria:
- **A1.2 (Availability)**: Recovery mechanisms function under failure.
- **PI1.4 (Processing Integrity)**: Data integrity maintained during faults.
- **CC7.5 (Common Criteria)**: Incident response procedures validated.

### Requirements

1. **Change management** — File change request before every experiment with hypothesis, scope, risk, abort plan.
2. **Approval** — Sign-off from service owner + SRE lead.
3. **Audit trail** — Log start/stop times, parameters, participants, outcomes.
4. **Evidence retention** — Store reports for audit period (typically 12 months).
5. **Risk assessment** — Document potential customer impact and mitigation.
6. **Opt-in only** — Target resources tagged `chaos-enabled: true`.

### Experiment Report Template

```markdown
## Chaos Experiment Report
- **ID**: CE-2024-042
- **Date**: 2024-03-15 14:00-15:30 UTC
- **Approver**: Jane Smith (SRE Lead)
- **Change Ticket**: CHG-9182
- **Hypothesis**: [stated hypothesis]
- **Target**: payment-svc (production, us-east-1)
- **Blast Radius**: 2 of 6 pods (33%)
- **Duration**: 5 minutes
- **Abort Conditions**: error_rate > 5%, p99 > 10s
- **Result**: PASS / FAIL
- **Findings**: [observations]
- **Action Items**: [follow-ups with owners and dates]
```

## Experiment Design Workflow

1. **Identify risk** — Review incidents, architecture diagrams, dependency maps.
2. **Formulate hypothesis** — State expected behavior under specific failure.
3. **Choose injection** — Match failure type to risk (network, resource, process).
4. **Select tool** — Match platform and fault type to tool.
5. **Define blast radius** — Scope to minimum viable impact.
6. **Set abort conditions** — Quantitative thresholds, automated enforcement.
7. **Prepare observability** — Verify dashboards, alerts, traces active.
8. **Execute** — Run with team present. Document live.
9. **Analyze** — Compare observed vs expected. Identify gaps.
10. **Remediate** — Fix weaknesses. Update runbooks.
11. **Iterate** — Expand scope progressively. Repeat.

## Examples

### Example 1: Database failover experiment

**Input**: "Design a chaos experiment to test if our order service handles database failover"

**Output**:
```
Experiment: Order Service DB Failover

Steady State: order success rate >99.9%, p99 <800ms, no data loss
Hypothesis: When primary PostgreSQL is killed, service fails over to
  replica within 30s, maintaining >99% success, p99 <3s during failover.
Injection: aws fis (aws:rds:reboot-db-instances) OR kubectl delete pod <primary>
Blast Radius: Single DB instance, non-peak hours (2am UTC)
Abort: success rate <95% for 60s OR duplicate orders detected
Duration: 10 minutes
Rollback: RDS auto-failback + manual order consistency verification
```

### Example 2: Kubernetes network chaos

**Input**: "Add network latency between frontend and backend in K8s"

**Output**:
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: frontend-backend-latency
  namespace: chaos-testing
spec:
  action: delay
  mode: all
  selector:
    namespaces: [production]
    labelSelectors: { app: frontend }
  delay:
    latency: "300ms"
    jitter: "50ms"
  direction: to
  target:
    selector:
      namespaces: [production]
      labelSelectors: { app: backend-api }
  duration: "5m"
# Apply: kubectl apply -f network-latency-experiment.yaml
# Abort: kubectl delete networkchaos frontend-backend-latency -n chaos-testing
```

### Example 3: CI/CD chaos gate

**Input**: "Add a chaos test step to my deployment pipeline"

**Output**:
```yaml
chaos-validation:
  stage: validate
  script:
    - BASELINE=$(curl -s $METRICS_URL | jq '.error_rate')
    - litmus run pod-delete --app=my-app --namespace=staging --duration=120
    - sleep 150
    - CURRENT=$(curl -s $METRICS_URL | jq '.error_rate')
    - |
      if (( $(echo "$CURRENT > 0.01" | bc -l) )); then
        echo "FAIL: Error rate $CURRENT exceeds threshold"; exit 1
      fi
    - echo "PASS: System recovered. Promoting to production."
  allow_failure: false
```
