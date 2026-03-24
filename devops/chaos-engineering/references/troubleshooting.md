# Chaos Engineering Troubleshooting Guide

## Table of Contents

- [Experiments Escaping Blast Radius](#experiments-escaping-blast-radius)
- [Monitoring Blind Spots](#monitoring-blind-spots)
- [Team Pushback & Cultural Resistance](#team-pushback--cultural-resistance)
- [Compliance Concerns](#compliance-concerns)
- [Rollback Failures](#rollback-failures)
- [False Positives & False Negatives](#false-positives--false-negatives)
- [Quick Diagnostic Flowchart](#quick-diagnostic-flowchart)

---

## Experiments Escaping Blast Radius

### Symptoms
- Services outside the experiment scope show degradation
- Customer-facing errors spike unexpectedly
- Alerts fire for unrelated systems
- Post-experiment: damage exceeds what was planned

### Root Causes

| Cause | Example | Fix |
|-------|---------|-----|
| Selector too broad | `labelSelectors: app=svc` matches 12 pods across namespaces | Add `namespaces` filter + specific labels |
| Shared dependency hit | Auth service used by all; chaos on auth cascades everywhere | Map dependencies first; exclude shared services initially |
| Missing network isolation | `tc` applied to node NIC affects all pods on that node | Use pod-level injection (Chaos Mesh) or sidecar (Toxiproxy) |
| No kill switch | Experiment runs unattended, nobody can stop it | Pre-configure abort conditions + manual halt button |
| Tool misconfiguration | Gremlin agent targets all hosts matching a regex | Use explicit host/container targeting, never wildcards in prod |

### Prevention Checklist

```
Pre-experiment blast radius review:
  [ ] Experiment targets explicitly named (not wildcarded)
  [ ] Namespace or tag scoping verified with dry-run
  [ ] Dependency map reviewed — shared deps excluded or approved
  [ ] Kill switch tested (can you halt in <30s?)
  [ ] Blast radius approved by service owner
  [ ] Duration hard-capped (tool-enforced, not just documented)
```

### Emergency Response

```bash
# Chaos Mesh: delete all active experiments
kubectl delete networkchaos,podchaos,stresschaos,iochaos,httpchaos --all -n chaos-testing

# Gremlin: halt all attacks
gremlin halt --all

# AWS FIS: stop experiment
aws fis stop-experiment --id <experiment-id>

# tc/iptables: flush all rules
tc qdisc del dev eth0 root 2>/dev/null
iptables -F
```

---

## Monitoring Blind Spots

### Common Blind Spots

**1. Missing downstream metrics**
You monitor the service under chaos but not its downstream consumers.
```
Problem: Payment-svc latency injected → checkout-svc fails silently
Fix: Add dashboards for ALL services in the dependency chain
```

**2. Infrastructure-only monitoring**
CPU/memory/disk look fine, but users see errors.
```
Problem: Monitoring infra health ≠ monitoring user experience
Fix: Add synthetic transactions, real-user monitoring (RUM), business KPIs
```

**3. Aggregated metrics hiding localized failures**
Average latency is fine, but p99 is 30s for 1% of users.
```
Problem: Averages mask tail latency spikes
Fix: Always monitor p50, p95, p99 separately; alert on p99
```

**4. Alert lag**
Alerts configured with 5-minute evaluation windows miss fast-moving failures.
```
Problem: Experiment runs 3 minutes; alert fires after experiment ends
Fix: Use ≤30s evaluation windows for chaos abort conditions
```

**5. No distributed tracing**
Can't see where in the call chain the failure propagates.
```
Problem: "Something is slow" but no trace to identify the bottleneck
Fix: Deploy OpenTelemetry/Jaeger before running cross-service experiments
```

### Monitoring Readiness Checklist

Before ANY chaos experiment, verify:

```
Observability coverage:
  [ ] Target service: request rate, error rate, latency (p50/p95/p99)
  [ ] Upstream services: error rate, timeout rate
  [ ] Downstream services: request rate, error rate
  [ ] Infrastructure: CPU, memory, disk, network I/O, connections
  [ ] Business metrics: orders/min, signups/min, revenue impact
  [ ] Synthetic monitors: health check endpoints, key user journeys
  [ ] Distributed traces: end-to-end latency breakdown

Alert configuration:
  [ ] Abort condition alerts fire within 30 seconds
  [ ] Alert channels verified (PagerDuty, Slack, email)
  [ ] Alert tested with a dry-run fault before real experiment
```

### Dashboard Template for Chaos Experiments

```
Row 1: Experiment metadata (name, target, duration, status)
Row 2: Target service — req/s, error%, p50/p95/p99
Row 3: Upstream impact — error%, timeout%, retry rate
Row 4: Downstream impact — error%, latency, queue depth
Row 5: Infrastructure — CPU, mem, disk, connections, network
Row 6: Business — transactions/min, conversion rate, revenue
Row 7: Alerts — active alerts, abort condition status
```

---

## Team Pushback & Cultural Resistance

### Common Objections and Responses

**"We'll cause an outage"**
> Start in staging. Use blast radius controls. One pod, one minute. The risk of NOT testing is discovering failures during a real incident at 3am.

**"We already have integration tests"**
> Integration tests verify expected behavior. Chaos engineering reveals unexpected failure modes — the things your tests don't cover because you didn't think of them.

**"We don't have time"**
> Frame it as risk reduction with ROI. One 2-hour GameDay that finds a missing circuit breaker prevents a potential 4-hour production outage.

**"Management won't approve breaking production"**
> Start with staging. Build a track record. Show findings from staging experiments. Graduate to production only after demonstrating safety and value.

**"What if it goes wrong?"**
> This is why abort conditions exist. Every experiment has a kill switch. The blast radius is defined before the experiment starts. We stop immediately if thresholds are breached.

### Building Chaos Culture — Step by Step

1. **Start with education**: Run a lunch-and-learn on chaos engineering principles. Share Netflix, Amazon, Google war stories.

2. **Find an ally**: Identify one team willing to try. Run their first experiment together. Success breeds adoption.

3. **Celebrate findings**: When chaos reveals a bug, celebrate publicly. "Chaos experiment found that payment-svc doesn't retry on 503 — fixed before it hit customers."

4. **Make it low-risk**: First experiments in staging, single pod, short duration. Let skeptics observe without participating.

5. **Show ROI data**: Track metrics:
   - Number of production incidents prevented by chaos findings
   - MTTR improvement (teams who practice chaos respond faster)
   - Resilience gaps closed per quarter

6. **Integrate into existing processes**: Add chaos checks to deployment checklists. Make it part of the workflow, not extra work.

7. **Gamify**: Leaderboards for teams, "chaos champion" recognition, incentivize experiment creation.

### Executive Pitch Template

```
Problem: We had X production incidents last quarter, costing Y hours of engineering
         time and $Z in customer impact.

Proposal: Monthly chaos GameDays to proactively find and fix resilience gaps.

Investment: 4 hours/month per participating team.

Expected ROI: 30-50% reduction in severity-1 incidents within 6 months.
              Faster MTTR from practiced incident response.
              SOC2/compliance evidence for resilience validation.

Risk: Minimal — all experiments have blast radius controls and abort conditions.
      Start in staging, graduate to production after 3 successful rounds.
```

---

## Compliance Concerns

### Regulatory Frameworks and Chaos Engineering

| Framework | Relevant Control | How Chaos Helps |
|-----------|-----------------|-----------------|
| SOC 2 | A1.2 (Availability), CC7.5 (Incident Response) | Validates recovery mechanisms, tests incident response |
| PCI DSS | 11.4 (Penetration testing), 12.10 (Incident response) | Tests data protection under fault conditions |
| HIPAA | §164.308(a)(7) (Contingency plan) | Validates disaster recovery and data integrity |
| ISO 27001 | A.17 (Business continuity) | Tests continuity controls under simulated failures |
| FedRAMP | CA-8 (Penetration testing) | Validates control effectiveness under stress |

### Compliance-Safe Chaos Practices

**1. Documentation Requirements**
Every experiment needs:
- Pre-approved change request with hypothesis, scope, risk assessment
- Sign-off from service owner AND compliance/security representative
- Timestamped audit log (start, actions, observations, end)
- Post-experiment report stored for audit retention period (typically 12 months)

**2. Data Protection During Chaos**
```
Rules:
  - NEVER inject faults that could cause data exfiltration
  - NEVER disable encryption, auth, or access controls as part of chaos
  - NEVER target PII/PHI data stores without explicit compliance approval
  - ALWAYS verify data integrity post-experiment
  - ALWAYS use synthetic/anonymized data for new experiment types
```

**3. Environment Restrictions**
- Regulated workloads: start in staging, require additional approval for production
- PCI cardholder data environments: additional change control procedures
- Healthcare systems: schedule outside patient-care hours, notify clinical teams

**4. Audit Trail Template**
```
Experiment ID: CE-2024-042
Change Ticket: CHG-9182
Approval Chain: [Service Owner] → [SRE Lead] → [Compliance Officer]
Pre-Experiment Risk Assessment: [Low/Medium/High]
Data Classification of Target: [Public/Internal/Confidential/Restricted]
Start Time: 2024-03-15T14:00:00Z
End Time: 2024-03-15T14:15:00Z
Parameters: { target: "payment-svc", fault: "pod-kill", blast_radius: "2/6 pods" }
Outcome: PASS — service maintained SLO during experiment
Data Integrity Check: PASS — no data loss or corruption detected
Report Location: s3://chaos-reports/CE-2024-042.pdf
```

---

## Rollback Failures

### Why Rollbacks Fail

| Failure Mode | Example | Prevention |
|-------------|---------|------------|
| Orphaned rules | `tc` or `iptables` rules persist after script crash | Use trap handlers; verify cleanup on exit |
| Tool crash | Chaos Mesh controller pod OOMKilled mid-experiment | Set resource limits on chaos tooling; monitor controller health |
| State drift | Experiment deletes a pod; replacement pod has different config | Use declarative tools (Chaos Mesh CRDs) with auto-revert |
| Manual cleanup forgotten | Engineer runs `tc` manually, forgets to revert | Script all experiments; never run ad-hoc commands in prod |
| Cascading damage | Rollback succeeds but downstream services already degraded | Include downstream recovery validation in rollback procedure |

### Rollback Best Practices

**1. Always use trap handlers in scripts**
```bash
cleanup() {
    echo "[ROLLBACK] Reverting chaos injection..."
    tc qdisc del dev eth0 root 2>/dev/null || true
    iptables -F 2>/dev/null || true
    echo "[ROLLBACK] Complete"
}
trap cleanup EXIT INT TERM
```

**2. Verify rollback before experimenting**
```bash
# Inject → immediately rollback → verify clean state
tc qdisc add dev eth0 root netem delay 100ms
tc qdisc del dev eth0 root
# Confirm: tc qdisc show dev eth0 → should show default only
```

**3. Use declarative tools with TTL**
```yaml
# Chaos Mesh: auto-reverts after duration expires
spec:
  duration: "5m"   # Experiment auto-reverts after 5 minutes
```

**4. Post-rollback validation checklist**
```
  [ ] Injected faults removed (verify with tool-specific status commands)
  [ ] Target service healthy (health check passes)
  [ ] Metrics returned to baseline (error rate, latency)
  [ ] Downstream services recovered
  [ ] No orphaned resources (pods, connections, temp files)
```

### Emergency Rollback Commands

```bash
# Nuclear option: remove ALL chaos injections

# Linux networking
tc qdisc del dev eth0 root 2>/dev/null
iptables -F && iptables -X

# Kubernetes (Chaos Mesh)
kubectl delete networkchaos,podchaos,stresschaos,iochaos --all -A

# Kubernetes (LitmusChaos)
kubectl delete chaosengine --all -A

# stress-ng
pkill -f stress-ng

# Gremlin
gremlin halt --all
```

---

## False Positives & False Negatives

### False Positives (Experiment Fails, But System Is Actually Fine)

**Causes:**
- Steady-state baseline captured during anomalous period (deploy, traffic spike)
- Thresholds too tight — normal variance triggers abort
- Monitoring lag — metric spikes briefly then recovers, but abort fires
- Test environment differs from production — failure only in test

**Fixes:**
- Baseline over ≥24 hours (capture daily patterns)
- Use statistical thresholds, not absolute: `> 3σ from baseline` instead of hard numbers
- Add `for: 30s` to abort conditions — require sustained breach, not momentary spike
- Run same experiment 3x — consistent failure = real issue, intermittent = investigate

### False Negatives (Experiment Passes, But System Has Real Vulnerabilities)

**Causes:**
- Blast radius too small to trigger the actual failure mode
- Experiment runs during low traffic — failure only manifests under load
- Wrong fault type — testing pod kill when the real risk is network partition
- Monitoring gaps — failure happens but isn't observed

**Fixes:**
- Progressively increase blast radius: 1 pod → 10% → 50%
- Combine chaos with load testing: inject faults under realistic traffic
- Map real incidents to experiment types — prioritize faults that mirror past outages
- Verify monitoring catches the fault: inject a known-bad scenario and confirm detection

### Validation Matrix

| Scenario | Expected Behavior | Metric to Watch | Pass Criteria |
|----------|-------------------|-----------------|---------------|
| 1 pod killed | Replacement scheduled in <30s | Pod count, request errors | Error rate <1% |
| 200ms latency added | Circuit breaker trips | p99 latency, CB state | p99 <2s after CB trips |
| 50% packet loss | Retries succeed, no data loss | Success rate, data checks | >99% success |
| DB primary killed | Failover completes | Connection errors, failover time | Failover <60s |
| DNS blocked | Cached resolution used | DNS errors, request success | No customer impact |

### Improving Experiment Quality Over Time

1. **Correlate with real incidents**: Every production incident → check if chaos experiments would have caught it. If not, add that experiment.
2. **Track experiment effectiveness**: Measure % of incidents that were "predicted" by chaos experiments.
3. **Peer review hypotheses**: Bad hypotheses lead to meaningless experiments.
4. **Rotate experiment runners**: Fresh eyes catch assumptions that regulars miss.
5. **Review abort threshold data**: If experiments never abort, thresholds may be too loose.

---

## Quick Diagnostic Flowchart

```
Chaos experiment went wrong?
│
├─ Blast radius exceeded?
│  ├─ YES → Emergency rollback (see commands above)
│  │        → Post-mortem: why did targeting fail?
│  │        → Fix: tighten selectors, add namespace isolation
│  └─ NO  → Continue diagnosis
│
├─ Can't rollback?
│  ├─ YES → Manual intervention: flush iptables, delete CRDs, kill processes
│  │        → Fix: add trap handlers, use declarative tools with TTL
│  └─ NO  → Rollback, then continue diagnosis
│
├─ Unexpected results?
│  ├─ Passed but shouldn't have → Check for false negative (see above)
│  └─ Failed but shouldn't have → Check for false positive (see above)
│
├─ Team refusing to run experiments?
│  └─ See "Building Chaos Culture" section
│
└─ Compliance blocking experiments?
   └─ See "Compliance Concerns" section — document, get approval, use audit trails
```
