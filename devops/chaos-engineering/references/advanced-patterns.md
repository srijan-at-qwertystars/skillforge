# Advanced Chaos Engineering Patterns

## Table of Contents

- [Multi-Region Failure Injection](#multi-region-failure-injection)
- [Cascading Failure Injection](#cascading-failure-injection)
- [Chaos in Serverless Architectures](#chaos-in-serverless-architectures)
- [Database Chaos](#database-chaos)
- [Chaos for Stateful Workloads](#chaos-for-stateful-workloads)
- [Progressive Delivery + Chaos](#progressive-delivery--chaos)
- [Chaos Maturity Model](#chaos-maturity-model)

---

## Multi-Region Failure Injection

### Why It Matters

Most production systems span multiple regions/AZs. Multi-region chaos validates that failover, data replication, and routing actually work — not just in theory.

### Patterns

**1. Full Region Blackout**
Simulate complete region unavailability by blocking all traffic to/from a region.

```bash
# AWS FIS: Stop all tagged EC2 in us-east-1a
aws fis create-experiment-template \
  --description "AZ blackout us-east-1a" \
  --targets '{"instances":{"resourceType":"aws:ec2:instance","selectionMode":"ALL","resourceTags":{"chaos-enabled":"true"},"filters":[{"path":"Placement.AvailabilityZone","values":["us-east-1a"]}]}}' \
  --actions '{"stop":{"actionId":"aws:ec2:stop-instances","parameters":{"startInstancesAfterDuration":"PT10M"},"targets":{"Instances":"instances"}}}'
```

**2. Cross-Region Latency Injection**
Add 200ms+ latency between regions to simulate degraded inter-region links.

```yaml
# Chaos Mesh: Inter-region latency simulation
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: cross-region-latency
spec:
  action: delay
  mode: all
  selector:
    namespaces: [production]
    labelSelectors:
      region: us-east-1
  delay:
    latency: "250ms"
    jitter: "50ms"
  direction: to
  target:
    selector:
      labelSelectors:
        region: eu-west-1
  duration: "10m"
```

**3. DNS Failover Validation**
Block DNS resolution for primary region endpoints; verify Route 53 / Global Accelerator reroutes.

```bash
# Block DNS for specific hosted zone endpoint
iptables -A OUTPUT -d <primary-region-endpoint-ip> -j DROP
# Monitor: dig +short service.example.com should resolve to secondary
```

### Key Metrics to Watch
- Failover time (seconds from fault to full reroute)
- Data consistency between regions post-failover
- Client error rate during failover window
- Replication lag after failback

---

## Cascading Failure Injection

### The Problem

Cascading failures occur when one component's failure triggers failures in dependent components, creating a domino effect. These are the #1 cause of large-scale outages.

### Patterns

**1. Dependency Starvation**
Slow down a critical dependency (e.g., auth service) and observe upstream impact.

```bash
# Inject 5s latency to auth-service via Toxiproxy
toxiproxy-cli toxic add auth-svc -t latency -a latency=5000 -a jitter=1000
# Watch: Do callers timeout? Do they retry? Do retries amplify load?
```

**2. Connection Pool Exhaustion**
Pause a downstream service to exhaust connection pools in callers.

```bash
# Pause the database container to hold connections open
docker pause postgres-primary
# Monitor: Connection pool utilization in callers
# Expected: Circuit breakers trip within 30s
```

**3. Retry Storm Simulation**
Inject intermittent failures (50% error rate) to trigger retry cascades.

```yaml
# Chaos Mesh: 50% HTTP errors from payment-svc
apiVersion: chaos-mesh.org/v1alpha1
kind: HTTPChaos
metadata:
  name: payment-errors
spec:
  mode: all
  selector:
    labelSelectors:
      app: payment-svc
  target: Response
  port: 8080
  abort: true
  duration: "5m"
```

**4. Queue Backpressure**
Fill message queues to capacity and verify producers handle backpressure gracefully.

### Detection Checklist
- [ ] Circuit breakers trip correctly (verify with metrics)
- [ ] Retry budgets are respected (no exponential retry storms)
- [ ] Bulkheads isolate failures (unrelated services unaffected)
- [ ] Graceful degradation activates (cached responses, fallbacks)
- [ ] Load shedding engages before total collapse

---

## Chaos in Serverless Architectures

### Unique Challenges

Serverless (Lambda, Cloud Functions, Azure Functions) lacks persistent infrastructure — traditional chaos tools don't apply directly. Focus on:
- Event source failures (SQS, SNS, DynamoDB Streams, EventBridge)
- Cold start amplification under load
- Concurrency throttling
- IAM permission revocation
- Downstream dependency failures

### Patterns

**1. Lambda Concurrency Throttling**
```bash
# Set reserved concurrency to 1 to simulate throttling
aws lambda put-function-concurrency \
  --function-name order-processor \
  --reserved-concurrent-executions 1
# Revert
aws lambda delete-function-concurrency --function-name order-processor
```

**2. Event Source Disruption**
```bash
# Disable SQS event source mapping
aws lambda update-event-source-mapping \
  --uuid <mapping-uuid> --enabled false
# Monitor: DLQ depth, message age, consumer lag
```

**3. Downstream Timeout Injection**
Use Lambda layers or middleware to inject latency into outbound calls:

```python
# chaos_middleware.py — Lambda layer for chaos injection
import os, time, random

def maybe_inject_chaos(service_name):
    if os.environ.get("CHAOS_ENABLED") != "true":
        return
    fault_rate = float(os.environ.get("CHAOS_FAULT_RATE", "0"))
    latency_ms = int(os.environ.get("CHAOS_LATENCY_MS", "0"))
    if random.random() < fault_rate:
        raise Exception(f"[CHAOS] Injected failure for {service_name}")
    if latency_ms > 0:
        time.sleep(latency_ms / 1000.0)
```

**4. IAM Permission Chaos**
Temporarily remove a permission from the Lambda execution role (staging only).

### Safety Controls for Serverless Chaos
- Feature flags (LaunchDarkly, AWS AppConfig) to enable/disable chaos
- Environment variable toggles per function
- Always test in staging first — serverless has less isolation
- Monitor DLQ depth as primary abort signal

---

## Database Chaos

### Split-Brain Simulation

Split-brain occurs when a network partition causes two nodes to both believe they are primary.

**PostgreSQL / Patroni:**
```bash
# Partition the primary from the rest of the cluster
iptables -A INPUT -s <replica1-ip> -j DROP
iptables -A INPUT -s <replica2-ip> -j DROP
iptables -A OUTPUT -d <replica1-ip> -j DROP
iptables -A OUTPUT -d <replica2-ip> -j DROP
# Monitor: Does Patroni elect a new leader? Do writes fail-safe?
# Revert after observation
iptables -F
```

**Validation Checklist:**
- [ ] Fencing mechanism activates (STONITH, leader lease expiry)
- [ ] Application detects read-only state and retries against new primary
- [ ] No data loss or duplicate writes
- [ ] Cluster reconverges after partition heals

### Replication Lag Injection

```bash
# MySQL: Inject artificial replication delay on replica
mysql -e "STOP SLAVE; CHANGE MASTER TO MASTER_DELAY = 30; START SLAVE;"
# PostgreSQL: Add latency to WAL receiver via tc
tc qdisc add dev eth0 root netem delay 500ms
# Monitor: pg_stat_replication.replay_lag, application read-after-write consistency
```

### Failover Testing

```bash
# RDS: Force failover
aws rds reboot-db-instance --db-instance-identifier mydb --force-failover
# Aurora: Trigger failover
aws rds failover-db-cluster --db-cluster-identifier mycluster
# Monitor: Connection errors, failover duration, transaction rollbacks
```

### Data Integrity Validation
After any database chaos experiment:
1. Run consistency checks (`pg_catalog.pg_stat_activity`, checksums)
2. Verify application-level data integrity (order counts, account balances)
3. Check for orphaned transactions or partial writes
4. Validate replication has fully caught up

---

## Chaos for Stateful Workloads

### Challenges

Stateful workloads (databases, queues, caches, session stores) require special care:
- Data can be corrupted or lost permanently
- Recovery may require manual intervention
- PVCs and storage classes add complexity in Kubernetes

### Patterns

**1. PersistentVolume Disruption (Kubernetes)**
```yaml
# Chaos Mesh: I/O chaos on stateful workload
apiVersion: chaos-mesh.org/v1alpha1
kind: IOChaos
metadata:
  name: db-io-latency
spec:
  action: latency
  mode: one
  selector:
    labelSelectors:
      app: postgresql
      role: primary
  volumePath: /var/lib/postgresql/data
  path: "*"
  delay: "100ms"
  percent: 50
  duration: "5m"
```

**2. StatefulSet Pod Kill with Ordered Recovery**
```bash
# Kill specific ordinal in StatefulSet
kubectl delete pod kafka-2 -n messaging --grace-period=0
# Verify: Pod recreated, PVC reattached, partition leadership reassigned
```

**3. Cache Eviction / Redis Failover**
```bash
# Simulate Redis primary failure
kubectl exec redis-master -- redis-cli DEBUG SLEEP 30
# Or kill the pod
kubectl delete pod redis-master-0 -n cache --grace-period=0
# Verify: Sentinel promotes replica, clients reconnect, no cache stampede
```

**4. Message Queue Chaos**
```bash
# Kill Kafka broker
kubectl delete pod kafka-0 -n messaging --grace-period=0
# Verify: Partition leaders re-elected, consumers rebalance, no message loss
# Check: kafka-consumer-groups.sh --describe --group <group>
```

### Safety Rules for Stateful Chaos
1. **Always back up** before experiments on data stores
2. **Start with replicas**, never the primary (until maturity level 3+)
3. **Verify data integrity** post-experiment with checksums or app-level validation
4. **Use non-production** data for initial experiments
5. **Monitor storage metrics**: IOPS, throughput, queue depth, PVC status

---

## Progressive Delivery + Chaos

### Concept

Combine chaos experiments with progressive delivery (canary, blue/green, feature flags) to validate resilience of new code under fault conditions before full rollout.

### Integration Pattern

```
Deploy canary (5% traffic)
  → Run baseline chaos experiment against canary
    → If canary survives: increase to 25%
      → Run expanded chaos experiment
        → If survives: promote to 100%
          → Run production chaos suite
```

### Implementation with Argo Rollouts + Chaos Mesh

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payment-svc
spec:
  strategy:
    canary:
      steps:
        - setWeight: 5
        - pause: { duration: 2m }
        # Chaos gate: inject network latency to canary pods
        - analysis:
            templates:
              - templateName: chaos-network-latency
            args:
              - name: canary-hash
                valueFrom:
                  podTemplateHashValue: Latest
        - setWeight: 25
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: chaos-pod-kill
        - setWeight: 100
```

### Feature Flag Chaos
```python
# Use feature flags to enable chaos only for specific cohorts
if feature_flags.is_enabled("chaos-payment-latency", user_context):
    time.sleep(2.0)  # Simulate slow payment processing
# Monitor: Does the canary cohort maintain SLOs?
```

### Benefits
- Catches resilience regressions before they reach 100% of users
- Automates the "is this deployment resilient?" question
- Provides quantitative evidence for promotion decisions

---

## Chaos Maturity Model

### Level 0: No Chaos
- No intentional fault injection
- Resilience discovered only via real incidents
- **Action**: Start with a single GameDay

### Level 1: Ad-Hoc / Manual
- Occasional manual GameDays (quarterly)
- Kill a pod, observe dashboards
- No documented hypotheses or formal process
- **Indicators**: GameDay runbooks exist, team has done ≥1 experiment
- **Action**: Document hypotheses, establish steady-state metrics

### Level 2: Scripted & Scheduled
- Automated experiment scripts (tc, kubectl, stress-ng)
- Documented hypotheses and reports
- Experiments run in staging on schedule (weekly/monthly)
- Blast radius controls and abort conditions defined
- **Indicators**: Experiment library, cron-triggered runs, post-experiment reports
- **Action**: Integrate into CI/CD, add production experiments

### Level 3: CI/CD Integrated + Production
- Chaos gate in deployment pipeline — deploy fails if resilience regresses
- Continuous experiments in production with limited blast radius
- Automated abort conditions with monitoring integration
- Compliance-ready audit trails
- **Indicators**: Pipeline chaos stage, production experiment cadence, dashboards
- **Action**: Expand scope, add cross-service experiments, train all teams

### Level 4: Continuous & Autonomous
- Continuous chaos in production across all services
- ML-driven anomaly detection for abort conditions
- Self-healing systems validated by chaos
- Chaos experiments auto-generated from dependency maps
- Organization-wide chaos culture — every team runs experiments
- **Indicators**: Full automation, org-wide adoption, chaos metrics in SLO reviews

### Assessment Checklist

| Dimension | L1 | L2 | L3 | L4 |
|-----------|----|----|----|----|
| Hypothesis documented | ✗ | ✓ | ✓ | ✓ |
| Automated injection | ✗ | ✓ | ✓ | ✓ |
| Production experiments | ✗ | ✗ | ✓ | ✓ |
| CI/CD integration | ✗ | ✗ | ✓ | ✓ |
| Cross-service scope | ✗ | ✗ | ✗ | ✓ |
| Auto-generated experiments | ✗ | ✗ | ✗ | ✓ |
| Org-wide adoption | ✗ | ✗ | ✗ | ✓ |

### Progressing Between Levels

- **L0→L1**: Pick one critical service, run one GameDay, debrief
- **L1→L2**: Script your GameDay, schedule monthly runs, add reporting
- **L2→L3**: Add chaos stage to pipeline, run first production experiment
- **L3→L4**: Automate experiment generation, expand to all teams, tie to SLOs
