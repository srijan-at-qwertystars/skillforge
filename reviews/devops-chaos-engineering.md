# QA Review: chaos-engineering

**Skill path:** `devops/chaos-engineering/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17
**Verdict:** ✅ PASS

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `chaos-engineering` |
| YAML frontmatter `description` | ✅ | Multi-line, comprehensive |
| Positive triggers | ✅ | 8 triggers: "chaos testing", "fault injection", "resilience testing", "chaos experiment", "GameDay planning", "failure injection", "chaos monkey setup", "blast radius" |
| Negative triggers | ✅ | 4 exclusions: load testing, unit/integration testing, penetration testing, DR without fault injection |
| Body ≤ 500 lines | ✅ | 491 lines |
| Imperative voice | ✅ | Consistent throughout ("Define steady state", "Inject real-world failures", "Apply to every experiment", "Define BEFORE every experiment") |
| Examples with I/O | ✅ | 3 examples with explicit Input/Output pairs (DB failover, K8s network chaos, CI/CD chaos gate) |
| Resources linked | ✅ | All 11 supplementary files linked with relative paths in tables; references/ (3), scripts/ (3), assets/ (5) |

**Structure score: No issues.**

---

## B. Content Check

### Tool & API Verification

| Item | Skill Value | Verified | Status |
|------|-------------|----------|--------|
| Chaos Mesh CRD API | `chaos-mesh.org/v1alpha1` | v1alpha1 remains current across v2.7–v2.8.x releases (CNCF docs, GitHub releases) | ✅ |
| LitmusChaos CRD API | `litmuschaos.io/v1alpha1` | v1alpha1 confirmed current for ChaosEngine CRDs (official docs, CNCF blog 2024) | ✅ |
| AWS FIS `aws:ec2:stop-instances` | Used in FIS template | Confirmed valid action ID (AWS FIS Actions Reference) | ✅ |
| AWS FIS `aws:rds:failover-db-cluster` | Used in FIS template | Confirmed valid action ID (AWS FIS Actions Reference) | ✅ |
| AWS FIS `startInstancesAfterDuration` | `PT5M` (ISO 8601) | Correct parameter and format | ✅ |
| tc netem syntax | `tc qdisc add dev eth0 root netem delay 200ms 50ms distribution normal` | Correct iproute2/netem syntax | ✅ |
| tc packet loss | `tc qdisc add dev eth0 root netem loss 10%` | Correct | ✅ |
| iptables partition | `iptables -A OUTPUT -d 10.0.2.0/24 -j DROP` | Correct iptables syntax | ✅ |
| iptables DNS block | `-p udp --dport 53 -j DROP` + `-p tcp --dport 53` | Correct — covers both UDP and TCP DNS | ✅ |
| Toxiproxy CLI | `toxiproxy-cli create ... -t latency -a latency=2000` | Correct Toxiproxy CLI syntax | ✅ |

### Principles of Chaos Engineering (principlesofchaos.org)

The skill lists 6 principles which faithfully map to the 5 canonical principles:

| principlesofchaos.org | Skill's Principle | Match |
|-----------------------|-------------------|-------|
| Build hypothesis around steady state behavior | #1 Define steady state + #2 Hypothesize continuity | ✅ (split for clarity) |
| Vary real-world events | #3 Inject real-world failures | ✅ |
| Run experiments in production | #4 Run in production | ✅ |
| Automate experiments to run continuously | #6 Automate | ✅ |
| Minimize blast radius | #5 Minimize blast radius | ✅ |

The skill splits principle #1 into two steps (define → hypothesize), which is a pedagogical improvement. All canonical principles are covered. No contradictions found.

### Template & Asset Accuracy

- **Chaos Mesh templates** (`assets/chaos-mesh-experiment.yaml`): 7 CRD kinds (NetworkChaos, PodChaos, StressChaos, IOChaos, DNSChaos, HTTPChaos) — all valid Chaos Mesh CRD types with correct spec fields.
- **Litmus templates** (`assets/litmus-experiment.yaml`): 7 ChaosEngine templates with probes (httpProbe, promProbe) — correct format including `appinfo`, `chaosServiceAccount`, `engineState`.
- **AWS FIS templates** (`assets/aws-fis-template.json`): 6 experiment templates + IAM policy — correct structure with `targets`, `actions`, `stopConditions`, `roleArn`. Includes multi-action AZ failure template.
- **Scripts**: All 3 scripts have correct shebang, `set -euo pipefail`, trap handlers for cleanup, usage docs, and dependency checks.

**Content score: No inaccuracies found.**

---

## C. Trigger Check

| Query | Should Trigger? | Would Trigger? | Status |
|-------|-----------------|----------------|--------|
| "Set up chaos testing for our K8s cluster" | Yes | ✅ Yes — matches "chaos testing" | ✅ |
| "Design a fault injection experiment" | Yes | ✅ Yes — matches "fault injection" | ✅ |
| "Plan a GameDay for resilience testing" | Yes | ✅ Yes — matches "GameDay planning", "resilience testing" | ✅ |
| "How do I use Chaos Monkey?" | Yes | ✅ Yes — matches "chaos monkey setup" | ✅ |
| "Define blast radius for our experiment" | Yes | ✅ Yes — matches "blast radius" | ✅ |
| "Run a load test with k6" | No | ✅ No — excluded by "NOT for load testing" | ✅ |
| "Performance benchmark our API" | No | ✅ No — excluded by "NOT for...performance benchmarks" | ✅ |
| "Set up OWASP ZAP for pen testing" | No | ✅ No — excluded by "NOT for security penetration testing" | ✅ |
| "Write unit tests for our service" | No | ✅ No — excluded by "NOT for unit testing" | ✅ |
| "Create a disaster recovery plan" | No | ✅ No — excluded by "NOT for disaster recovery without fault injection" | ✅ |
| "Stress test our CPU under load" | Ambiguous | ⚠️ Could trigger — "stress" is in skill body but not explicitly in trigger list | ⚠️ Minor |

**Trigger analysis:** Strong positive and negative trigger coverage. One minor edge case: "stress testing" is ambiguous between chaos (resource stress injection) and performance (load stress), but the negative trigger for "load testing" partially disambiguates. Not significant enough to warrant an issue.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5/5 | All API versions, CLI syntax, CRD formats, and FIS action IDs verified correct against current docs. Principles faithful to principlesofchaos.org. |
| **Completeness** | 5/5 | Covers 7 tools, 4 failure categories, GameDay planning, CI/CD integration, observability, compliance/SOC2, maturity model. 3 reference docs, 3 executable scripts, 5 asset templates. Advanced patterns include multi-region, cascading failure, serverless, database, stateful workloads. |
| **Actionability** | 5/5 | Every concept backed by working code. Scripts are production-ready with cleanup/trap handlers. Templates are copy-paste with clear placeholders. 10-step experiment workflow. Pre-flight checklists. Report templates. |
| **Trigger quality** | 4/5 | 8 positive triggers + 4 negative exclusions cover the core domain well. Minor edge case around "stress testing" ambiguity. |
| **Overall** | **4.75/5** | |

---

## E. Supplementary File Quality

| File | Lines | Quality Notes |
|------|-------|---------------|
| `references/advanced-patterns.md` | 432 | Excellent coverage of 7 advanced topics with code examples |
| `references/tool-comparison.md` | 399 | Comprehensive feature matrix, architecture diagrams, pricing, selection guide |
| `references/troubleshooting.md` | 397 | Practical diagnostic flowchart, 6 failure categories, actionable fixes |
| `scripts/network-chaos.sh` | 207 | Production-grade: root check, dep check, trap handlers, auto-revert, colored output |
| `scripts/k8s-pod-chaos.sh` | 241 | Full-featured: 8 commands, continuous kill mode, status checks |
| `scripts/stress-test.sh` | 233 | Comprehensive: CPU/mem/disk/combined, system state monitoring, cleanup |
| `assets/chaos-mesh-experiment.yaml` | 220 | 7 CRD templates covering all major Chaos Mesh fault types |
| `assets/litmus-experiment.yaml` | 249 | 7 ChaosEngine templates with probes and cloud chaos |
| `assets/aws-fis-template.json` | 287 | 6 FIS templates + IAM policy, includes multi-action AZ failure |
| `assets/gameday-template.md` | 181 | Complete planning doc with 13 sections and checklists |
| `assets/experiment-report.md` | 163 | Thorough report template with compliance and data integrity sections |

---

## F. Recommendations (non-blocking)

1. **Consider adding** `"stress testing"` disambiguation to the description — clarify that resource stress injection (CPU/mem) is in-scope but load/performance stress testing is not.
2. **Minor**: The `stress-test.sh` script's `cmd_stop` function uses `pgrep` pattern-based process finding which could match unintended processes in shared environments. Consider using PID files.
3. **Nice-to-have**: A `references/glossary.md` defining terms like "blast radius", "steady-state hypothesis", "GameDay" for newcomers.

---

## Verdict

**PASS** — Overall 4.75/5, no dimension ≤ 2, no accuracy issues found. Skill is production-ready.
