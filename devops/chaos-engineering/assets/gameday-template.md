# GameDay Planning Document

## Metadata

| Field | Value |
|-------|-------|
| **GameDay ID** | GD-YYYY-NNN |
| **Date** | YYYY-MM-DD HH:MM–HH:MM UTC |
| **Commander** | [Name] |
| **Participants** | [Names and roles] |
| **Slack Channel** | #gameday-YYYY-MM-DD |
| **Change Ticket** | CHG-XXXXX |
| **Status** | Draft / Approved / Completed / Cancelled |

---

## 1. Objective

_What are we trying to learn? What resilience property are we validating?_

> [Example: Validate that the order service maintains >99% success rate during a database primary failover.]

---

## 2. Hypothesis

```
Steady State:
  [metric] is within [threshold] during normal operation.

Hypothesis:
  When [specific fault] is injected into [specific target],
  [metric] remains within [threshold] OR recovers within [duration].

Abort When:
  [metric] exceeds [critical threshold] for [duration].
```

---

## 3. Scope & Blast Radius

| Dimension | Value |
|-----------|-------|
| **Target service(s)** | |
| **Target environment** | staging / production |
| **Target resources** | [e.g., 2 of 6 pods, 1 AZ, specific node] |
| **Expected user impact** | None / Minimal / Moderate |
| **Traffic percentage affected** | |
| **Duration** | |

---

## 4. Fault Injection Plan

| Step | Time | Action | Tool | Rollback |
|------|------|--------|------|----------|
| 1 | T+0 | Capture baseline metrics | Grafana/Prometheus | — |
| 2 | T+2m | [Inject fault] | [Tool] | [Revert command] |
| 3 | T+Xm | Observe steady state | Dashboards | — |
| 4 | T+Ym | Stop fault / auto-expire | [Tool] | — |
| 5 | T+Zm | Validate recovery | Synthetic checks | — |

---

## 5. Abort Conditions

| Metric | Threshold | Duration | Action |
|--------|-----------|----------|--------|
| Error rate (5xx) | > 5% | 30s | Rollback |
| p99 latency | > 10s | 15s | Rollback |
| Customer impact | Any | Immediate | Halt + page |
| Data loss indicator | Any | Immediate | Halt + page |

**Kill switch**: [How to immediately stop the experiment]

---

## 6. Pre-GameDay Checklist

- [ ] Hypothesis documented and peer-reviewed
- [ ] Steady-state metrics baselined (≥24h)
- [ ] Blast radius defined and approved by service owner
- [ ] Abort conditions configured in monitoring
- [ ] Rollback procedure tested (dry-run)
- [ ] Stakeholders notified (engineering, support, management)
- [ ] Observability dashboards prepared and shared
- [ ] Communication channel created
- [ ] GameDay commander assigned
- [ ] Incident response team on standby
- [ ] Change management ticket filed
- [ ] Runbook peer-reviewed
- [ ] Approvals obtained: [ ] Service Owner [ ] SRE Lead [ ] Compliance (if applicable)

---

## 7. Observability Setup

**Dashboards:**
- [ ] Target service dashboard: [URL]
- [ ] Upstream services dashboard: [URL]
- [ ] Infrastructure dashboard: [URL]
- [ ] Business metrics dashboard: [URL]
- [ ] Chaos experiment status: [URL]

**Alerts:**
- [ ] Abort condition alerts configured and tested
- [ ] Alert routing verified (PagerDuty / Slack / email)

**Traces:**
- [ ] Distributed tracing enabled for target service
- [ ] Trace sampling rate adequate for experiment duration

---

## 8. Communication Plan

| When | What | Channel |
|------|------|---------|
| T-1 day | Notify stakeholders | Email / Slack |
| T-30m | Final go/no-go check | GameDay Slack channel |
| T+0 | "Experiment starting" | GameDay Slack channel |
| During | Live observations | GameDay Slack channel |
| Abort | "ABORT — [reason]" | GameDay Slack + PagerDuty |
| Complete | "Experiment complete" | GameDay Slack channel |
| T+1 day | Results and findings | Email / Confluence |

---

## 9. Execution Log

_Fill in during the GameDay._

| Time (UTC) | Event | Observation |
|------------|-------|-------------|
| | Baseline captured | |
| | Fault injected | |
| | [Observation] | |
| | Fault stopped / expired | |
| | Recovery confirmed | |

---

## 10. Results

**Outcome:** PASS / FAIL / ABORT

**Hypothesis confirmed?** Yes / No / Partial

**Summary:**
> [2-3 sentence summary of what happened]

---

## 11. Findings & Action Items

| # | Finding | Severity | Action Item | Owner | Due Date |
|---|---------|----------|-------------|-------|----------|
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |

---

## 12. Follow-Up Experiments

_Based on findings, what should we test next?_

| Experiment | Hypothesis | Priority | Target Date |
|-----------|-----------|----------|-------------|
| | | | |

---

## 13. Approvals

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Service Owner | | | |
| SRE Lead | | | |
| Compliance (if required) | | | |
