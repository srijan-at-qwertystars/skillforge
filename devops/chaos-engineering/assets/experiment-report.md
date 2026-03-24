# Chaos Experiment Report

## Metadata

| Field | Value |
|-------|-------|
| **Experiment ID** | CE-YYYY-NNN |
| **Date** | YYYY-MM-DD HH:MM–HH:MM UTC |
| **Experimenter** | [Name] |
| **Approver** | [Name, Role] |
| **Change Ticket** | CHG-XXXXX |
| **Related GameDay** | GD-YYYY-NNN (if applicable) |

---

## Hypothesis

```
Steady State:
  [metric] is within [threshold] during normal operation.

Hypothesis:
  When [fault] is injected into [target],
  [metric] remains within [threshold] OR recovers within [duration].
```

---

## Experiment Configuration

| Parameter | Value |
|-----------|-------|
| **Target service** | |
| **Target environment** | |
| **Fault type** | [e.g., pod-kill, network-latency, CPU stress] |
| **Fault tool** | [e.g., Chaos Mesh, LitmusChaos, AWS FIS, tc/iptables] |
| **Blast radius** | [e.g., 2 of 6 pods, 33%] |
| **Duration** | |
| **Abort conditions** | [e.g., error_rate > 5% for 30s] |

**Experiment manifest/command:**
```
[Paste the exact command, YAML, or JSON used to run the experiment]
```

---

## Results

**Outcome:** PASS / FAIL / ABORT / INCONCLUSIVE

**Hypothesis confirmed?** Yes / No / Partial

---

## Timeline

| Time (UTC) | Event | Observation |
|------------|-------|-------------|
| HH:MM:SS | Baseline captured | [Baseline values: error_rate=0.1%, p99=200ms] |
| HH:MM:SS | Fault injected | [What was injected] |
| HH:MM:SS | First impact observed | [What changed] |
| HH:MM:SS | [Recovery / Abort / Escalation] | [What happened] |
| HH:MM:SS | Experiment ended | [How it concluded] |
| HH:MM:SS | Steady state restored | [Verified metrics] |

---

## Metrics

### During Experiment

| Metric | Baseline | During Fault | Peak Impact | Post-Recovery |
|--------|----------|-------------|-------------|---------------|
| Error rate | | | | |
| p50 latency | | | | |
| p95 latency | | | | |
| p99 latency | | | | |
| Request rate | | | | |
| CPU utilization | | | | |
| Memory utilization | | | | |

### Dashboard Screenshots

_Attach or link Grafana/CloudWatch screenshots showing the experiment impact._

- Baseline: [link/image]
- During fault: [link/image]
- Recovery: [link/image]

---

## Findings

### What Worked Well
1. [e.g., Circuit breaker tripped within 5s as expected]
2. [e.g., Auto-scaling responded to increased load]

### Issues Discovered
1. **[Issue title]** — [Description of the problem found]
   - Severity: Critical / High / Medium / Low
   - Impact: [What could happen in a real incident]
   - Root cause: [Why this vulnerability exists]

2. **[Issue title]** — [Description]
   - Severity:
   - Impact:
   - Root cause:

### Unexpected Observations
- [Anything surprising that wasn't part of the hypothesis]

---

## Action Items

| # | Action | Priority | Owner | Due Date | Ticket |
|---|--------|----------|-------|----------|--------|
| 1 | | P1/P2/P3 | | | |
| 2 | | | | | |
| 3 | | | | | |

---

## Data Integrity Check

| Check | Result | Notes |
|-------|--------|-------|
| No data loss detected | PASS / FAIL | |
| No duplicate records | PASS / FAIL | |
| Replication caught up | PASS / FAIL / N/A | |
| Application consistency | PASS / FAIL | |

---

## Compliance & Audit

| Item | Status |
|------|--------|
| Pre-approval obtained | Yes / No |
| Experiment logged with timestamps | Yes / No |
| Report stored in audit repository | Yes / No |
| Retention period | 12 months |
| Evidence artifacts attached | Yes / No |

---

## Follow-Up Experiments

| Experiment | Rationale | Priority |
|-----------|-----------|----------|
| [Next experiment based on findings] | [Why] | High / Medium / Low |

---

## Sign-Off

| Role | Name | Date |
|------|------|------|
| Experimenter | | |
| Service Owner | | |
| SRE Lead | | |
