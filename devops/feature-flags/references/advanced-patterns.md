# Advanced Feature Flag Patterns

> A dense reference for senior engineers covering allocation algorithms, dependency
> modeling, governance, migration strategies, and lifecycle automation.

---

## Table of Contents

1. [Multi-Armed Bandit Allocation](#1-multi-armed-bandit-allocation)
   - [When MAB Beats Traditional A/B](#when-mab-beats-traditional-ab)
   - [Algorithm Comparison](#algorithm-comparison)
   - [Implementation Example](#mab-implementation)
2. [Flag Dependencies and Prerequisite Flags](#2-flag-dependencies-and-prerequisite-flags)
   - [Dependency Graphs](#dependency-graphs)
   - [Circular Dependency Detection](#circular-dependency-detection)
   - [Evaluation Ordering](#evaluation-ordering)
3. [Mutual Exclusion Groups](#3-mutual-exclusion-groups)
   - [Use Cases](#mutex-use-cases)
   - [Group-Level Evaluation](#group-level-evaluation)
4. [Scheduled Rollouts](#4-scheduled-rollouts)
   - [Cron-Based Schedules](#cron-based-schedules)
   - [Gradual Ramp Schedules](#gradual-ramp-schedules)
   - [Timezone Handling](#timezone-handling)
5. [Flag-Driven Database Migrations](#5-flag-driven-database-migrations)
   - [Dual-Write Pattern](#dual-write-pattern)
   - [Shadow Reads](#shadow-reads)
   - [Data Backfill Under Flags](#data-backfill-under-flags)
6. [Feature Flag Governance](#6-feature-flag-governance)
   - [Approval Workflows](#approval-workflows)
   - [RBAC for Flag Changes](#rbac-for-flag-changes)
   - [Audit Trails and Compliance](#audit-trails-and-compliance)
7. [Canary Releases with Flags](#7-canary-releases-with-flags)
   - [Progressive Delivery](#progressive-delivery)
   - [Automated Rollback Triggers](#automated-rollback-triggers)
   - [Health-Check Integration](#health-check-integration)
8. [Dynamic Configuration vs Feature Flags](#8-dynamic-configuration-vs-feature-flags)
   - [Lifecycle Differences](#lifecycle-differences)
   - [Evaluation Model Differences](#evaluation-model-differences)
   - [Anti-Patterns](#config-anti-patterns)
9. [Server-Side vs Client-Side Evaluation](#9-server-side-vs-client-side-evaluation)
   - [Trade-off Analysis](#trade-off-analysis)
   - [Decision Matrix](#decision-matrix)
   - [Hybrid Architectures](#hybrid-architectures)
10. [Flag Archival and Cleanup Automation](#10-flag-archival-and-cleanup-automation)
    - [Stale Flag Detection](#stale-flag-detection)
    - [Automated PR Generation](#automated-pr-generation)
    - [Metrics on Flag Debt](#metrics-on-flag-debt)

---

## 1. Multi-Armed Bandit Allocation

Traditional A/B tests split traffic evenly and wait for statistical significance.
Multi-armed bandit (MAB) algorithms **shift traffic toward winning variants during
the experiment**, reducing opportunity cost.

### When MAB Beats Traditional A/B

| Scenario | Use A/B | Use MAB |
|---|---|---|
| Need rigorous p-values for a report | ✅ | ❌ |
| Optimizing a checkout flow in production | ❌ | ✅ |
| Short-lived promo with high revenue impact | ❌ | ✅ |
| Regulatory requirement for fixed test plan | ✅ | ❌ |
| Continuous optimization of recommendations | ❌ | ✅ |

**Rule of thumb:** Use MAB when the cost of showing a losing variant is high and
you care more about cumulative reward than clean confidence intervals.

### Algorithm Comparison

**Epsilon-Greedy** — Exploit the best arm `(1 - ε)` of the time; explore randomly
`ε` of the time. Simple but wastes exploration budget uniformly.

```
P(explore) = ε          → pick random variant
P(exploit) = 1 - ε      → pick variant with highest observed reward
```

**Thompson Sampling** — Model each variant's reward as a Beta distribution.
Sample from each, pick the variant whose sample is highest. Naturally balances
exploration and exploitation — explores uncertain variants more.

```
For each variant i:
  sample_i ~ Beta(α_i, β_i)
  where α_i = successes + 1, β_i = failures + 1

Select variant with max(sample_i)
```

**UCB (Upper Confidence Bound)** — Pick the variant with the highest upper
confidence bound on its reward estimate. Deterministic, good theoretical regret
bounds.

```
UCB_i = x̄_i + c * sqrt(ln(N) / n_i)

x̄_i  = observed mean reward for variant i
N    = total observations across all variants
n_i  = observations for variant i
c    = exploration constant (typically sqrt(2))
```

### MAB Implementation

```typescript
// feature-flags/mab-allocator.ts

interface Variant {
  key: string;
  successes: number;
  failures: number;
}

interface MABAllocator {
  selectVariant(variants: Variant[]): string;
  recordOutcome(variantKey: string, success: boolean): void;
}

// Thompson Sampling — preferred for most feature flag use cases
class ThompsonSamplingAllocator implements MABAllocator {
  private variants: Map<string, Variant> = new Map();

  selectVariant(variants: Variant[]): string {
    let bestSample = -1;
    let bestKey = variants[0].key;

    for (const v of variants) {
      // Beta distribution sampling via Jinks' method
      const alpha = v.successes + 1;
      const beta = v.failures + 1;
      const sample = this.sampleBeta(alpha, beta);

      if (sample > bestSample) {
        bestSample = sample;
        bestKey = v.key;
      }
    }
    return bestKey;
  }

  recordOutcome(variantKey: string, success: boolean): void {
    const v = this.variants.get(variantKey);
    if (!v) return;
    if (success) v.successes++;
    else v.failures++;
  }

  private sampleBeta(alpha: number, beta: number): number {
    // Use gamma distribution sampling: Beta(a,b) = Ga(a) / (Ga(a) + Ga(b))
    const x = this.sampleGamma(alpha);
    const y = this.sampleGamma(beta);
    return x / (x + y);
  }

  private sampleGamma(shape: number): number {
    // Marsaglia and Tsang's method for shape >= 1
    if (shape < 1) return this.sampleGamma(shape + 1) * Math.random() ** (1 / shape);
    const d = shape - 1 / 3;
    const c = 1 / Math.sqrt(9 * d);
    while (true) {
      let x: number, v: number;
      do {
        x = this.randomNormal();
        v = (1 + c * x) ** 3;
      } while (v <= 0);
      const u = Math.random();
      if (u < 1 - 0.0331 * x ** 4 || Math.log(u) < 0.5 * x * x + d * (1 - v + Math.log(v))) {
        return d * v;
      }
    }
  }

  private randomNormal(): number {
    const u1 = Math.random();
    const u2 = Math.random();
    return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
  }
}

// Integration with flag evaluation
async function evaluateWithMAB(
  flagKey: string,
  userId: string,
  allocator: MABAllocator,
  store: FlagStore
): Promise<string> {
  const flag = await store.getFlag(flagKey);
  if (!flag.mabEnabled) {
    return flag.evaluateStatic(userId);
  }

  // Sticky assignment — check if user already has a variant
  const existing = await store.getAssignment(flagKey, userId);
  if (existing) return existing;

  const variant = allocator.selectVariant(flag.variants);
  await store.saveAssignment(flagKey, userId, variant);
  return variant;
}
```

**Operational note:** Store MAB state (successes/failures) in Redis or a similar
low-latency store. Batch-update counters to avoid write amplification. Set a
minimum sample size per variant (e.g., 100 observations) before allowing the
algorithm to skew traffic heavily.

---

## 2. Flag Dependencies and Prerequisite Flags

When flag B should only evaluate if flag A is enabled, you have a **prerequisite
relationship**. Without explicit modeling, these implicit dependencies cause
subtle, hard-to-debug evaluation errors.

### Dependency Graphs

```
┌──────────┐
│ new-ui   │
└────┬─────┘
     │ requires
     ▼
┌──────────┐     ┌────────────┐
│ new-api  │────▶│ new-schema │
└──────────┘     └────────────┘
                       │
                       ▼
                 ┌────────────┐
                 │ db-v2      │
                 └────────────┘
```

A flag's **effective state** is: `self_enabled AND all_prerequisites_enabled`.

### Circular Dependency Detection

Use topological sort at flag-save time. Reject any update that would introduce a cycle.

```python
# flag_dependencies.py

from collections import defaultdict, deque
from typing import Dict, List, Set

class FlagDependencyGraph:
    def __init__(self):
        self.edges: Dict[str, Set[str]] = defaultdict(set)  # flag -> prerequisites

    def add_prerequisite(self, flag: str, prerequisite: str) -> None:
        """Add a prerequisite. Raises if it would create a cycle."""
        # Temporarily add the edge
        self.edges[flag].add(prerequisite)

        if self._has_cycle():
            self.edges[flag].discard(prerequisite)
            raise ValueError(
                f"Adding prerequisite {prerequisite} -> {flag} "
                f"would create a circular dependency"
            )

    def _has_cycle(self) -> bool:
        """Kahn's algorithm — returns True if the graph has a cycle."""
        in_degree: Dict[str, int] = defaultdict(int)
        all_nodes: Set[str] = set()

        for node, deps in self.edges.items():
            all_nodes.add(node)
            for dep in deps:
                all_nodes.add(dep)
                in_degree[dep] += 1

        queue = deque(n for n in all_nodes if in_degree[n] == 0)
        visited = 0

        while queue:
            node = queue.popleft()
            visited += 1
            for dep in self.edges.get(node, set()):
                in_degree[dep] -= 1
                if in_degree[dep] == 0:
                    queue.append(dep)

        return visited != len(all_nodes)

    def evaluation_order(self) -> List[str]:
        """Return flags in dependency-safe evaluation order (topological)."""
        in_degree: Dict[str, int] = defaultdict(int)
        all_nodes: Set[str] = set()

        for node, deps in self.edges.items():
            all_nodes.add(node)
            for dep in deps:
                all_nodes.add(dep)
                in_degree[node] += 1  # node depends on dep

        queue = deque(n for n in all_nodes if in_degree[n] == 0)
        order: List[str] = []

        while queue:
            node = queue.popleft()
            order.append(node)
            for dependent, deps in self.edges.items():
                if node in deps:
                    in_degree[dependent] -= 1
                    if in_degree[dependent] == 0:
                        queue.append(dependent)

        return order
```

### Evaluation Ordering

```typescript
// flag-evaluator.ts

interface FlagDefinition {
  key: string;
  enabled: boolean;
  prerequisites: string[];
  rules: TargetingRule[];
}

async function evaluateWithPrerequisites(
  flagKey: string,
  context: EvalContext,
  flagStore: Map<string, FlagDefinition>,
  cache: Map<string, boolean> = new Map()
): Promise<boolean> {
  // Memoize to avoid re-evaluation in diamond dependencies
  if (cache.has(flagKey)) return cache.get(flagKey)!;

  const flag = flagStore.get(flagKey);
  if (!flag) {
    cache.set(flagKey, false);
    return false;
  }

  // Check all prerequisites recursively
  for (const prereq of flag.prerequisites) {
    const prereqResult = await evaluateWithPrerequisites(
      prereq, context, flagStore, cache
    );
    if (!prereqResult) {
      cache.set(flagKey, false);
      return false;  // Short-circuit: prerequisite not met
    }
  }

  // All prerequisites met — evaluate this flag's own rules
  const result = flag.enabled && evaluateRules(flag.rules, context);
  cache.set(flagKey, result);
  return result;
}
```

**Guardrails to enforce:**
- Maximum dependency depth (e.g., 5 levels) to keep evaluation latency bounded.
- Cycle detection at write time, not evaluation time.
- Dashboard visualization of the dependency graph so humans can reason about it.

---

## 3. Mutual Exclusion Groups

When two features would conflict at runtime — competing UI layouts, incompatible
API behaviors, overlapping experiments — use a **mutex group** to guarantee at most
one is active per evaluation context.

### Mutex Use Cases

- **Competing experiments:** Two teams testing changes to the same checkout page.
- **Incompatible backends:** New cache layer vs. new database — can't run both.
- **UI exclusivity:** Redesigned nav can't coexist with legacy nav.

### Group-Level Evaluation

```typescript
// mutex-groups.ts

interface MutexGroup {
  id: string;
  flagKeys: string[];
  priority: number[];  // Parallel array — higher number = higher priority
}

interface FlagEvalResult {
  key: string;
  enabled: boolean;
  variant: string | null;
}

function evaluateMutexGroup(
  group: MutexGroup,
  context: EvalContext,
  evaluateFlag: (key: string, ctx: EvalContext) => FlagEvalResult
): Map<string, FlagEvalResult> {
  const results = new Map<string, FlagEvalResult>();

  // Evaluate all flags in priority order
  const flagsWithPriority = group.flagKeys.map((key, i) => ({
    key,
    priority: group.priority[i],
  }));
  flagsWithPriority.sort((a, b) => b.priority - a.priority);

  let winnerFound = false;

  for (const { key } of flagsWithPriority) {
    const result = evaluateFlag(key, context);

    if (result.enabled && !winnerFound) {
      // First enabled flag wins
      results.set(key, result);
      winnerFound = true;
    } else {
      // Force-disable all others in the group
      results.set(key, { key, enabled: false, variant: null });
    }
  }

  return results;
}
```

```python
# Alternative: hash-based deterministic mutex allocation

import hashlib

def mutex_allocate(
    group_id: str,
    flag_keys: list[str],
    user_id: str,
    weights: list[float] | None = None,
) -> str | None:
    """
    Deterministically assign a user to at most one flag in the mutex group.
    Returns the winning flag key, or None if the user falls outside all allocations.
    """
    if weights is None:
        weights = [1.0 / len(flag_keys)] * len(flag_keys)

    hash_input = f"{group_id}:{user_id}".encode()
    hash_val = int(hashlib.sha256(hash_input).hexdigest(), 16)
    bucket = (hash_val % 10000) / 10000  # [0, 1) with 0.01% granularity

    cumulative = 0.0
    for key, weight in zip(flag_keys, weights):
        cumulative += weight
        if bucket < cumulative:
            return key

    return None  # User falls outside total allocation (if weights sum < 1)
```

**Key design decisions:**
- Use **priority-based** mutex when one flag should always win ties.
- Use **hash-based** mutex when you want deterministic, evenly distributed allocation.
- Store mutex group definitions alongside flag definitions — they are part of the evaluation contract.

---

## 4. Scheduled Rollouts

Flags that activate or deactivate based on time enable launch coordination,
maintenance windows, and gradual ramps without human intervention.

### Cron-Based Schedules

```typescript
// scheduled-flags.ts

interface ScheduleWindow {
  start: string;       // ISO 8601 datetime
  end?: string;        // ISO 8601 datetime — omit for permanent activation
  timezone: string;    // IANA timezone (e.g., "America/New_York")
  percentage?: number; // Optional: rollout percentage during this window
}

interface ScheduledFlag {
  key: string;
  defaultEnabled: boolean;
  schedules: ScheduleWindow[];
}

function isScheduleActive(schedule: ScheduleWindow, now: Date): boolean {
  // Convert "now" to the schedule's timezone for comparison
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: schedule.timezone,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
    hour12: false,
  });
  const localNow = new Date(formatter.format(now));

  const start = new Date(schedule.start);
  const end = schedule.end ? new Date(schedule.end) : null;

  if (localNow < start) return false;
  if (end && localNow > end) return false;
  return true;
}
```

### Gradual Ramp Schedules

A ramp schedule increases rollout percentage over time automatically:

```yaml
# LaunchDarkly-style ramp configuration
flag: new-pricing-page
ramp_schedule:
  timezone: "America/Los_Angeles"
  stages:
    - at: "2025-03-01T06:00:00"
      percentage: 1
    - at: "2025-03-02T06:00:00"
      percentage: 5
    - at: "2025-03-03T06:00:00"
      percentage: 25
    - at: "2025-03-05T06:00:00"
      percentage: 50
    - at: "2025-03-07T06:00:00"
      percentage: 100
  rollback_on:
    error_rate_increase: 5%   # relative increase from baseline
    p99_latency_increase: 20%
```

```python
# ramp_evaluator.py

from datetime import datetime, timezone
from bisect import bisect_right
from dataclasses import dataclass
from zoneinfo import ZoneInfo

@dataclass
class RampStage:
    at: datetime
    percentage: float

def current_ramp_percentage(
    stages: list[RampStage],
    tz: str,
    now: datetime | None = None,
) -> float:
    """Return the active rollout percentage based on the current time."""
    now = now or datetime.now(ZoneInfo(tz))
    timestamps = [s.at for s in stages]
    idx = bisect_right(timestamps, now) - 1

    if idx < 0:
        return 0.0  # Before first stage
    return stages[idx].percentage
```

### Timezone Handling

**Critical pitfalls:**

1. **Always store schedule times with explicit IANA timezones** — never UTC offsets
   alone. UTC-5 is ambiguous (EST or CDT?). `America/New_York` handles DST.
2. **Evaluate in the schedule's timezone**, not the server's timezone.
3. **DST transitions:** A schedule set for 2:30 AM on a spring-forward day may
   not exist. Handle this by rounding to the next valid time.
4. **Global rollouts:** Use multiple schedule windows with different timezones if
   you need region-aware activation (e.g., launch at 9 AM local in each region).

---

## 5. Flag-Driven Database Migrations

Feature flags decouple **code deployment** from **data migration**, letting you
ship schema changes incrementally without downtime.

### Dual-Write Pattern

Write to both old and new storage simultaneously, behind a flag. This ensures the
new store has data parity before you cut reads over.

```
Phase 1: Write old only          (flag off)
Phase 2: Write old + new         (flag: dual-write)
Phase 3: Write old + new, read new  (flag: shadow-read)
Phase 4: Write new only, read new   (flag: new-primary)
Phase 5: Remove old schema       (flag archived)

┌─────────┐    ┌─────────┐    ┌─────────┐
│  App     │───▶│ Old DB  │    │ New DB  │
│  Code    │    └─────────┘    └─────────┘
│          │         │              ▲
│          │         │  dual-write  │
│          │─────────┴──────────────┘
└─────────┘
```

```python
# dual_write_repository.py

from enum import Enum
from typing import Any

class MigrationPhase(Enum):
    OLD_ONLY = "old_only"
    DUAL_WRITE = "dual_write"
    SHADOW_READ = "shadow_read"
    NEW_PRIMARY = "new_primary"

class DualWriteRepository:
    def __init__(self, old_repo, new_repo, flag_client):
        self.old = old_repo
        self.new = new_repo
        self.flags = flag_client

    def _phase(self) -> MigrationPhase:
        raw = self.flags.variation("db-migration-phase", "old_only")
        return MigrationPhase(raw)

    async def write(self, entity_id: str, data: Any) -> None:
        phase = self._phase()

        if phase == MigrationPhase.OLD_ONLY:
            await self.old.write(entity_id, data)

        elif phase in (MigrationPhase.DUAL_WRITE, MigrationPhase.SHADOW_READ):
            # Write to both; old is still source of truth
            await self.old.write(entity_id, data)
            try:
                await self.new.write(entity_id, data)
            except Exception as e:
                # Log but don't fail — new store is not primary yet
                logger.warning(f"Dual-write to new store failed: {e}")
                metrics.increment("dual_write.new_store.error")

        elif phase == MigrationPhase.NEW_PRIMARY:
            await self.new.write(entity_id, data)

    async def read(self, entity_id: str) -> Any:
        phase = self._phase()

        if phase in (MigrationPhase.OLD_ONLY, MigrationPhase.DUAL_WRITE):
            return await self.old.read(entity_id)

        elif phase == MigrationPhase.SHADOW_READ:
            primary = await self.old.read(entity_id)
            try:
                shadow = await self.new.read(entity_id)
                if primary != shadow:
                    metrics.increment("shadow_read.mismatch")
                    logger.error(
                        f"Shadow read mismatch for {entity_id}: "
                        f"old={primary}, new={shadow}"
                    )
            except Exception:
                metrics.increment("shadow_read.error")
            return primary  # Old is still authoritative

        elif phase == MigrationPhase.NEW_PRIMARY:
            return await self.new.read(entity_id)
```

### Shadow Reads

Shadow reads compare results from old and new storage **without affecting the
response**. They surface data inconsistencies before you cut over.

Key metrics to track:
- **Mismatch rate:** `shadow_read.mismatch / shadow_read.total` — must be < 0.01%
  before advancing to `NEW_PRIMARY`.
- **Latency delta:** New store p99 should be ≤ old store p99.
- **Error rate:** Any read errors from the new store.

### Data Backfill Under Flags

```python
# backfill_worker.py

import asyncio

async def backfill_under_flag(
    flag_client,
    old_repo,
    new_repo,
    batch_size: int = 500,
    concurrency: int = 4,
):
    """
    Backfill data from old store to new store.
    Controlled by a flag so it can be paused instantly.
    """
    cursor = None
    semaphore = asyncio.Semaphore(concurrency)

    while True:
        if not flag_client.variation("backfill-enabled", False):
            logger.info("Backfill paused by flag")
            await asyncio.sleep(30)
            continue

        batch, cursor = await old_repo.scan(cursor=cursor, count=batch_size)
        if not batch:
            logger.info("Backfill complete")
            break

        async def process(item):
            async with semaphore:
                existing = await new_repo.read(item.id)
                if existing is None:
                    await new_repo.write(item.id, item.data)
                    metrics.increment("backfill.written")

        await asyncio.gather(*[process(item) for item in batch])
        metrics.gauge("backfill.cursor_position", cursor)
```

**Sequencing the full migration:**

1. Deploy code with dual-write behind flag (Phase 1 → 2).
2. Start backfill worker (flag-controlled).
3. Monitor shadow reads for mismatches.
4. When mismatch rate ≈ 0, advance to `NEW_PRIMARY` (Phase 3 → 4).
5. After soak period, drop old schema. Archive all migration flags.

---

## 6. Feature Flag Governance

At scale, ungoverned flags become a liability. Governance frameworks prevent
unauthorized changes, ensure traceability, and satisfy compliance requirements.

### Approval Workflows

```
Developer requests flag change
         │
         ▼
┌────────────────────┐
│  Automated checks  │  ← Lint rules, impact analysis
└────────┬───────────┘
         │ pass
         ▼
┌────────────────────┐
│  Peer review       │  ← Required for production environments
│  (four-eyes)       │
└────────┬───────────┘
         │ approved
         ▼
┌────────────────────┐
│  Environment gate  │  ← staging → canary → production
└────────┬───────────┘
         │ promoted
         ▼
   Flag change applied
```

```typescript
// governance/approval.ts

interface FlagChangeRequest {
  id: string;
  flagKey: string;
  environment: "development" | "staging" | "production";
  changeType: "enable" | "disable" | "update_rules" | "update_percentage";
  requestedBy: string;
  approvedBy: string[];
  payload: Record<string, unknown>;
}

interface ApprovalPolicy {
  environment: string;
  requiredApprovals: number;
  requiredRoles: string[];
  autoApproveFor?: string[];  // e.g., ["development"] — auto-approve dev changes
}

const POLICIES: ApprovalPolicy[] = [
  {
    environment: "development",
    requiredApprovals: 0,
    requiredRoles: [],
    autoApproveFor: ["engineer", "lead", "admin"],
  },
  {
    environment: "staging",
    requiredApprovals: 1,
    requiredRoles: ["lead", "admin"],
  },
  {
    environment: "production",
    requiredApprovals: 2,
    requiredRoles: ["lead", "admin"],  // Four-eyes: 2 different leads/admins
  },
];

function canApplyChange(
  request: FlagChangeRequest,
  approverRoles: Map<string, string[]>
): { allowed: boolean; reason?: string } {
  const policy = POLICIES.find(p => p.environment === request.environment);
  if (!policy) return { allowed: false, reason: "No policy for environment" };

  // Self-approval check
  const nonSelfApprovers = request.approvedBy.filter(
    a => a !== request.requestedBy
  );

  if (nonSelfApprovers.length < policy.requiredApprovals) {
    return {
      allowed: false,
      reason: `Need ${policy.requiredApprovals} non-self approvals, have ${nonSelfApprovers.length}`,
    };
  }

  // Role check
  for (const approver of nonSelfApprovers) {
    const roles = approverRoles.get(approver) ?? [];
    if (!policy.requiredRoles.some(r => roles.includes(r))) {
      return { allowed: false, reason: `${approver} lacks required role` };
    }
  }

  return { allowed: true };
}
```

### RBAC for Flag Changes

| Role | Dev | Staging | Production |
|---|---|---|---|
| Engineer | Create, enable, disable | Create, enable | View only |
| Lead | Full access | Full access | Approve, enable, disable |
| Admin | Full access | Full access | Full access |
| Auditor | View only | View only | View only |

**Environment promotion rules:**
- A flag must exist in staging before it can be created in production.
- Percentage increases in production are capped at +10% per change without
  additional approval (prevents accidental 0% → 100% jumps).
- Kill switches (disable to 0%) bypass approval for incident response but
  generate an automatic post-incident review ticket.

### Audit Trails and Compliance

Every flag mutation must produce an immutable audit record:

```python
# governance/audit.py

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

@dataclass
class FlagAuditEntry:
    timestamp: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    flag_key: str = ""
    environment: str = ""
    action: str = ""          # "created" | "enabled" | "disabled" | "rules_updated" | ...
    actor: str = ""           # Authenticated user or service account
    previous_state: dict[str, Any] = field(default_factory=dict)
    new_state: dict[str, Any] = field(default_factory=dict)
    approval_chain: list[str] = field(default_factory=list)
    ip_address: str = ""
    change_request_id: str = ""

    def to_immutable_log(self) -> str:
        """Serialize to append-only log (e.g., S3, CloudTrail, SIEM)."""
        import json
        return json.dumps({
            "ts": self.timestamp.isoformat(),
            "flag": self.flag_key,
            "env": self.environment,
            "action": self.action,
            "actor": self.actor,
            "prev": self.previous_state,
            "next": self.new_state,
            "approvers": self.approval_chain,
            "ip": self.ip_address,
            "cr": self.change_request_id,
        }, default=str)
```

**Compliance checklist:**
- Audit logs shipped to immutable storage (S3 with Object Lock, or WORM storage).
- Retention period aligned with regulatory requirements (SOX: 7 years, GDPR: varies).
- Automated alerts on flag changes in production outside change windows.
- Quarterly review of flag ownership — orphaned flags assigned to a team or archived.

---

## 7. Canary Releases with Flags

Feature flags and canary deployments are complementary. Flags control **what code
runs**; canaries control **where code is deployed**. Combining them gives
fine-grained progressive delivery.

### Progressive Delivery

```
          ┌─────────────────────────────────────────────┐
          │              Progressive Delivery            │
          │                                             │
Time ────▶│  1%  ──▶  5%  ──▶  25%  ──▶  50%  ──▶ 100% │
          │  │       │        │         │         │     │
          │  ▼       ▼        ▼         ▼         ▼     │
          │ Health  Health   Health    Health    Full    │
          │ check   check    check     check    GA      │
          └─────────────────────────────────────────────┘
```

```typescript
// canary/progressive-delivery.ts

interface RolloutStage {
  percentage: number;
  minDurationMinutes: number;
  healthCriteria: HealthCriteria;
}

interface HealthCriteria {
  maxErrorRatePercent: number;
  maxP99LatencyMs: number;
  minSuccessRate: number;
  customChecks?: Array<() => Promise<boolean>>;
}

interface CanaryConfig {
  flagKey: string;
  stages: RolloutStage[];
  rollbackOnFailure: boolean;
  notifyChannels: string[];
}

const STANDARD_CANARY: CanaryConfig = {
  flagKey: "new-recommendation-engine",
  stages: [
    {
      percentage: 1,
      minDurationMinutes: 30,
      healthCriteria: {
        maxErrorRatePercent: 0.5,
        maxP99LatencyMs: 200,
        minSuccessRate: 0.995,
      },
    },
    {
      percentage: 5,
      minDurationMinutes: 60,
      healthCriteria: {
        maxErrorRatePercent: 1.0,
        maxP99LatencyMs: 250,
        minSuccessRate: 0.99,
      },
    },
    {
      percentage: 25,
      minDurationMinutes: 120,
      healthCriteria: {
        maxErrorRatePercent: 1.5,
        maxP99LatencyMs: 300,
        minSuccessRate: 0.985,
      },
    },
    {
      percentage: 100,
      minDurationMinutes: 0,
      healthCriteria: {
        maxErrorRatePercent: 2.0,
        maxP99LatencyMs: 500,
        minSuccessRate: 0.98,
      },
    },
  ],
  rollbackOnFailure: true,
  notifyChannels: ["#releases", "#oncall"],
};
```

### Automated Rollback Triggers

```python
# canary/rollback.py

import asyncio
from dataclasses import dataclass

@dataclass
class HealthSnapshot:
    error_rate: float
    p99_latency_ms: float
    success_rate: float
    sample_size: int

async def canary_health_loop(
    flag_client,
    metrics_client,
    config: dict,
    check_interval_seconds: int = 60,
):
    """
    Continuously monitor health during a canary rollout.
    Automatically rolls back if health degrades beyond thresholds.
    """
    flag_key = config["flag_key"]
    current_stage_idx = 0
    stage_start = asyncio.get_event_loop().time()
    stages = config["stages"]

    while current_stage_idx < len(stages):
        await asyncio.sleep(check_interval_seconds)

        stage = stages[current_stage_idx]
        health = await collect_health_snapshot(metrics_client, flag_key)

        # Check minimum sample size to avoid noisy signals
        if health.sample_size < 100:
            continue

        if not meets_criteria(health, stage["health_criteria"]):
            # ROLLBACK
            await flag_client.update_percentage(flag_key, 0)
            await notify(
                config["notify_channels"],
                f"🚨 Auto-rollback: {flag_key} failed health check at "
                f"{stage['percentage']}%. "
                f"Error rate: {health.error_rate:.2%}, "
                f"P99: {health.p99_latency_ms}ms"
            )
            return False

        # Check if enough time has passed at this stage
        elapsed = asyncio.get_event_loop().time() - stage_start
        if elapsed >= stage["min_duration_minutes"] * 60:
            current_stage_idx += 1
            if current_stage_idx < len(stages):
                next_pct = stages[current_stage_idx]["percentage"]
                await flag_client.update_percentage(flag_key, next_pct)
                stage_start = asyncio.get_event_loop().time()
                await notify(
                    config["notify_channels"],
                    f"✅ {flag_key} advanced to {next_pct}%"
                )

    return True  # Full rollout complete

def meets_criteria(health: HealthSnapshot, criteria: dict) -> bool:
    return (
        health.error_rate <= criteria["max_error_rate_percent"] / 100
        and health.p99_latency_ms <= criteria["max_p99_latency_ms"]
        and health.success_rate >= criteria["min_success_rate"]
    )
```

### Health-Check Integration

Integrate flag health with existing observability:

| Signal | Source | Threshold |
|---|---|---|
| Error rate (flagged vs unflagged) | Application metrics | < 1.5× baseline |
| Latency (p50, p95, p99) | APM (Datadog, New Relic) | < 1.2× baseline |
| Saturation (CPU, memory) | Infrastructure metrics | < 80% |
| Business KPI (conversion, revenue) | Analytics pipeline | > 0.95× baseline |

**Compare flagged cohort against unflagged cohort**, not against historical
baselines, to control for external factors (traffic spikes, time-of-day effects).

---

## 8. Dynamic Configuration vs Feature Flags

Both change system behavior at runtime. They are **not interchangeable**.

### Lifecycle Differences

| Dimension | Feature Flag | Dynamic Config |
|---|---|---|
| **Lifespan** | Temporary (days to weeks) | Long-lived (months to years) |
| **Purpose** | Gate unreleased code | Tune operational parameters |
| **Values** | Boolean or small enum | Any type (string, number, JSON) |
| **Targeting** | Per-user, per-segment | Per-environment, per-service |
| **Cleanup** | Must be removed after rollout | Lives as long as the parameter exists |
| **Examples** | `show-new-checkout`, `enable-v2-api` | `max-connections: 100`, `cache-ttl: 300` |

### Evaluation Model Differences

```typescript
// Feature flag: evaluated per-request with user context
const showNewUI = flagClient.boolVariation("new-ui", {
  userId: req.user.id,
  country: req.geo.country,
  plan: req.user.plan,
});

// Dynamic config: evaluated per-service with environment context
const maxPoolSize = configClient.getInt("db.pool.max-size", {
  service: "api-gateway",
  environment: "production",
});
```

**Caching characteristics:**

- **Flags:** Evaluated in real-time or near-real-time (SSE/streaming updates).
  Stale evaluations cause incorrect user experiences.
- **Config:** Cached aggressively (30s–5min TTL is fine). Stale config values are
  generally acceptable for short periods.

### Config Anti-Patterns

❌ **Using flags as permanent config:**
```typescript
// BAD — this flag will never be cleaned up
const pageSize = flagClient.intVariation("results-page-size", user, 20);
```

❌ **Using config as feature flags:**
```yaml
# BAD — no targeting, no gradual rollout, no kill switch
features:
  new_checkout: true  # deployed to everyone at once
```

❌ **Mixing flag and config in the same system without clear boundaries:**
```typescript
// BAD — flag SDK used for config, loses config-specific tooling
// (no schema validation, no drift detection, no config diffing)
const timeout = flagClient.intVariation("api-timeout-ms", user, 5000);
```

✅ **Correct separation:**
```typescript
// Flag: temporary, targeted, will be cleaned up
if (await flagClient.boolVariation("enable-v2-search", userContext)) {
  results = await searchV2(query);
} else {
  results = await searchV1(query);
}

// Config: permanent, operational, environment-scoped
const searchTimeout = configClient.getInt("search.timeout-ms", 3000);
results = await search(query, { timeout: searchTimeout });
```

---

## 9. Server-Side vs Client-Side Evaluation

Where you evaluate flags has deep implications for latency, security,
consistency, and developer experience.

### Trade-off Analysis

**Server-side evaluation:**
```
Client ──request──▶ Server ──evaluate──▶ Flag Service
                     │                        │
                     │◀── flag values ────────┘
                     │
                     ▼
              Render response
              (flag values baked in)
```

**Client-side evaluation:**
```
Client ──init SDK──▶ Flag Service
  │                       │
  │◀── all rules ─────────┘
  │
  ▼
Evaluate locally
(no server round-trip per flag)
```

| Dimension | Server-Side | Client-Side |
|---|---|---|
| **Latency** | Network hop to flag service per request | Zero after initial load |
| **Security** | Targeting rules never leave server | Rules shipped to client (visible in JS bundle) |
| **Consistency** | Single source of truth per request | Can drift between SDK init refreshes |
| **Bundle size** | No impact on client payload | SDK + rules add to bundle (10–50KB typical) |
| **Targeting** | Full access to server-side context (DB, auth) | Limited to client-known attributes |
| **Offline support** | None — requires connectivity | Can evaluate from cached rules |
| **Rule exposure** | Hidden from end users | Visible via browser DevTools |

### Decision Matrix

```
                         ┌────────────────────────────┐
                         │  Does the flag gate         │
                         │  security-sensitive logic?  │
                         └─────────┬──────────────────┘
                                   │
                          Yes      │      No
                          ▼        │      ▼
                    Server-side    │  ┌─────────────────────┐
                                   │  │ Is sub-100ms eval    │
                                   │  │ latency critical?    │
                                   │  └────────┬────────────┘
                                   │    Yes    │    No
                                   │    ▼      │    ▼
                                   │  Client   │  Either works.
                                   │  -side    │  Default to server-side.
                                   │           │
```

**Practical guidance:**
- Default to server-side for backend services, APIs, and anything with sensitive
  targeting rules (pricing tiers, internal employee flags).
- Use client-side for UI personalization, A/B tests on visual elements, and
  scenarios where initial page load with correct variants matters.
- Client-side evaluation **must not** include business-sensitive rule details.
  Use the "relay proxy" pattern to pre-evaluate on an edge node if you need
  client-speed with server-security.

### Hybrid Architectures

```typescript
// Hybrid: server evaluates sensitive flags, client evaluates UI flags

// Server-side (API response includes pre-evaluated flags)
app.get("/api/dashboard", async (req, res) => {
  const serverFlags = {
    pricingTier: await flagClient.stringVariation("pricing-tier", req.user),
    maxApiCalls: await flagClient.intVariation("api-rate-limit", req.user),
  };

  res.json({
    data: await getDashboardData(req.user, serverFlags),
    _flags: serverFlags,  // Ship evaluated values to client
  });
});

// Client-side (evaluates non-sensitive UI flags locally)
import { useFlagClient } from "./flags";

function Dashboard({ data, serverFlags }: Props) {
  const clientFlags = useFlagClient();

  return (
    <div>
      {/* Server-evaluated: pricing logic never exposed to client */}
      <PricingBanner tier={serverFlags.pricingTier} />

      {/* Client-evaluated: visual preference, no security concern */}
      {clientFlags.boolVariation("show-new-sidebar") && <NewSidebar />}
    </div>
  );
}
```

---

## 10. Flag Archival and Cleanup Automation

Feature flags are **technical debt by design**. Every flag that outlives its
purpose increases evaluation overhead, cognitive load, and bug surface area.
Automate their lifecycle.

### Stale Flag Detection

```python
# cleanup/stale_detector.py

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

@dataclass
class FlagHealth:
    key: str
    created_at: datetime
    last_modified: datetime
    last_evaluated: datetime | None
    evaluation_count_30d: int
    served_variation_count: int  # How many distinct variations were served
    has_code_references: bool

def classify_staleness(flag: FlagHealth) -> str:
    """
    Classify a flag into a lifecycle stage for cleanup prioritization.

    Categories:
      - active:     Recently modified or actively evaluated
      - stale:      Not modified in 30+ days AND serving single variation
      - zombie:     Not evaluated in 30+ days
      - abandoned:  No code references found in any repository
    """
    now = datetime.now(timezone.utc)

    if not flag.has_code_references:
        return "abandoned"

    if flag.last_evaluated is None or (now - flag.last_evaluated) > timedelta(days=30):
        return "zombie"

    is_old = (now - flag.last_modified) > timedelta(days=30)
    single_variation = flag.served_variation_count <= 1

    if is_old and single_variation:
        return "stale"

    return "active"


def detect_stale_flags(flags: list[FlagHealth]) -> dict[str, list[FlagHealth]]:
    """Group all flags by staleness category."""
    result: dict[str, list[FlagHealth]] = {
        "active": [], "stale": [], "zombie": [], "abandoned": []
    }
    for flag in flags:
        category = classify_staleness(flag)
        result[category].append(flag)
    return result
```

### Automated PR Generation

```typescript
// cleanup/auto-cleanup.ts
// Generates PRs to remove stale flag references from code.

import { Octokit } from "@octokit/rest";

interface FlagReference {
  filePath: string;
  lineNumber: number;
  lineContent: string;
  flagKey: string;
}

async function generateCleanupPR(
  flagKey: string,
  defaultVariation: string | boolean,
  references: FlagReference[],
  octokit: Octokit,
  repo: { owner: string; repo: string }
): Promise<string> {
  const branchName = `flag-cleanup/${flagKey}`;
  const baseBranch = "main";

  // Group references by file
  const fileGroups = new Map<string, FlagReference[]>();
  for (const ref of references) {
    const group = fileGroups.get(ref.filePath) ?? [];
    group.push(ref);
    fileGroups.set(ref.filePath, group);
  }

  // Create branch
  const baseRef = await octokit.git.getRef({
    ...repo,
    ref: `heads/${baseBranch}`,
  });

  await octokit.git.createRef({
    ...repo,
    ref: `refs/heads/${branchName}`,
    sha: baseRef.data.object.sha,
  });

  // For each file, replace flag checks with the hardcoded default
  for (const [filePath, refs] of fileGroups) {
    const file = await octokit.repos.getContent({
      ...repo,
      path: filePath,
      ref: branchName,
    });

    if (!("content" in file.data)) continue;

    let content = Buffer.from(file.data.content, "base64").toString();

    // Replace flag evaluation calls with the resolved value
    // Pattern: flagClient.boolVariation("flag-key", ctx, default)
    const pattern = new RegExp(
      `(?:flagClient|flags)\\.(?:bool|string|int)Variation\\(\\s*["']${flagKey}["'][^)]*\\)`,
      "g"
    );
    content = content.replace(pattern, JSON.stringify(defaultVariation));

    await octokit.repos.createOrUpdateFileContents({
      ...repo,
      path: filePath,
      message: `chore: remove stale flag "${flagKey}"`,
      content: Buffer.from(content).toString("base64"),
      sha: (file.data as { sha: string }).sha,
      branch: branchName,
    });
  }

  // Create PR
  const pr = await octokit.pulls.create({
    ...repo,
    title: `🧹 Remove stale feature flag: ${flagKey}`,
    body: [
      `## Automated Flag Cleanup`,
      ``,
      `Flag \`${flagKey}\` has been identified as stale:`,
      `- Serving a single variation for 30+ days`,
      `- Resolved value: \`${defaultVariation}\``,
      ``,
      `### Files modified:`,
      ...Array.from(fileGroups.keys()).map(f => `- \`${f}\``),
      ``,
      `> This PR was auto-generated by the flag cleanup pipeline.`,
      `> Please review the changes and ensure no conditional logic is lost.`,
    ].join("\n"),
    head: branchName,
    base: baseBranch,
  });

  return pr.data.html_url;
}
```

### Metrics on Flag Debt

Track these metrics on a dashboard to keep flag hygiene visible:

```
┌─────────────────────────────────────────────────────────────┐
│                    Flag Debt Dashboard                       │
├──────────────┬──────────────┬───────────────┬───────────────┤
│  Total Flags │  Active      │  Stale        │  Zombie       │
│     142      │    89 (63%)  │    31 (22%)   │    22 (15%)   │
├──────────────┴──────────────┴───────────────┴───────────────┤
│                                                             │
│  Avg Flag Age: 47 days    │  Flags > 90 days old: 23       │
│  Cleanup PRs open: 8     │  Cleanup PRs merged (30d): 14  │
│  Flags w/o owner: 5      │  Flags w/o code refs: 3        │
│                                                             │
│  ────── Flag Age Distribution ──────                        │
│  0-7d   ████████████████ 28                                 │
│  8-30d  ████████████████████████████████ 41                 │
│  31-90d ████████████████████ 27                             │
│  91d+   ██████████████ 23                                   │
│                                                             │
│  ────── Weekly Trend ──────                                 │
│  Created: +12  │  Archived: -8  │  Net: +4                 │
└─────────────────────────────────────────────────────────────┘
```

```python
# cleanup/metrics.py

from dataclasses import dataclass

@dataclass
class FlagDebtMetrics:
    total_flags: int
    active_count: int
    stale_count: int
    zombie_count: int
    abandoned_count: int
    avg_age_days: float
    flags_over_90_days: int
    flags_without_owner: int
    cleanup_prs_open: int
    cleanup_prs_merged_30d: int

    @property
    def debt_ratio(self) -> float:
        """Fraction of flags that are not actively needed."""
        if self.total_flags == 0:
            return 0.0
        return (self.stale_count + self.zombie_count + self.abandoned_count) / self.total_flags

    @property
    def health_grade(self) -> str:
        """Letter grade for overall flag hygiene."""
        ratio = self.debt_ratio
        if ratio < 0.10:
            return "A"
        elif ratio < 0.20:
            return "B"
        elif ratio < 0.35:
            return "C"
        elif ratio < 0.50:
            return "D"
        return "F"

def emit_flag_debt_metrics(metrics: FlagDebtMetrics, client) -> None:
    """Push flag debt metrics to your observability platform."""
    client.gauge("flags.total", metrics.total_flags)
    client.gauge("flags.active", metrics.active_count)
    client.gauge("flags.stale", metrics.stale_count)
    client.gauge("flags.zombie", metrics.zombie_count)
    client.gauge("flags.abandoned", metrics.abandoned_count)
    client.gauge("flags.debt_ratio", metrics.debt_ratio)
    client.gauge("flags.avg_age_days", metrics.avg_age_days)
    client.gauge("flags.over_90_days", metrics.flags_over_90_days)
    client.gauge("flags.without_owner", metrics.flags_without_owner)
    client.gauge("flags.cleanup_prs.open", metrics.cleanup_prs_open)
    client.gauge("flags.cleanup_prs.merged_30d", metrics.cleanup_prs_merged_30d)
```

**Recommended automation cadence:**

| Action | Frequency | Trigger |
|---|---|---|
| Stale flag scan | Daily | Cron job |
| Cleanup PR generation | Weekly | For flags stale > 14 days |
| Owner verification | Monthly | Email/Slack to flag owners |
| Abandoned flag deletion | Quarterly | After 2 failed owner pings |
| Flag debt report to leadership | Monthly | Automated dashboard email |

**Operational tip:** Set a per-team flag budget (e.g., max 15 active flags per
team). When a team exceeds budget, new flag creation requires archiving an
existing one first. This creates natural pressure to clean up.

---

## Quick Reference: Pattern Selection Guide

| Problem | Pattern | Section |
|---|---|---|
| Optimize conversion during experiment | Multi-Armed Bandit | [§1](#1-multi-armed-bandit-allocation) |
| Flag B depends on flag A | Prerequisites | [§2](#2-flag-dependencies-and-prerequisite-flags) |
| Two features must not coexist | Mutual Exclusion | [§3](#3-mutual-exclusion-groups) |
| Launch at a specific time automatically | Scheduled Rollout | [§4](#4-scheduled-rollouts) |
| Zero-downtime schema migration | Flag-Driven Migration | [§5](#5-flag-driven-database-migrations) |
| Controlled changes in regulated env | Governance | [§6](#6-feature-flag-governance) |
| Gradual rollout with auto-rollback | Canary + Flags | [§7](#7-canary-releases-with-flags) |
| Tuning params vs gating features | Config vs Flags | [§8](#8-dynamic-configuration-vs-feature-flags) |
| Where to evaluate flags | Server vs Client | [§9](#9-server-side-vs-client-side-evaluation) |
| Tech debt from old flags | Cleanup Automation | [§10](#10-flag-archival-and-cleanup-automation) |
