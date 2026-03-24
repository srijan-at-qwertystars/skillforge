---
name: feature-flags
description: >
  Implement, integrate, and manage feature flags across platforms (LaunchDarkly, Unleash, Flagsmith,
  PostHog, Flipt) and the OpenFeature standard. Covers flag types (release, experiment, ops,
  permission), implementation patterns (boolean, multivariate, percentage rollout, user targeting),
  server-side and client-side SDKs, flag lifecycle management, testing strategies, A/B testing,
  trunk-based development with flags, architecture (edge evaluation, caching), and flag debt cleanup.
  Trigger when user asks about feature flags, feature toggles, progressive rollouts, canary releases
  via flags, kill switches, dark launches, OpenFeature SDK setup, flag provider integration,
  experiment flags, or flag hygiene. Do NOT trigger for general CI/CD pipelines, environment
  variables without flag semantics, simple config files, A/B testing without flags, or general
  deployment strategies unrelated to feature flagging.
---

# Feature Flags

## Flag Types

Classify every flag by type. Type determines lifecycle, ownership, and cleanup rules.

| Type | Purpose | Lifetime | Example |
|------|---------|----------|---------|
| **Release** | Hide incomplete features in trunk | Days–weeks | `enable-new-checkout` |
| **Experiment** | A/B test variants | Weeks–months | `exp-pricing-page-v2` |
| **Ops** | Runtime operational control | Permanent (reviewed quarterly) | `kill-switch-recommendations` |
| **Permission** | Gate access by entitlement | Permanent | `feature-advanced-analytics` |

Naming convention: `<type-prefix>.<team>.<feature>` — e.g., `release.payments.stripe-v3`, `ops.infra.cache-bypass`.

## Platforms

### LaunchDarkly
- Enterprise SaaS. Advanced targeting, audit logs, SOC2/HIPAA. SDKs for 25+ languages.
- Relay Proxy for air-gapped/edge evaluation. Streaming updates via SSE.
- Best for: large orgs needing compliance, advanced segmentation, enterprise support.

### Unleash
- Open-source, self-hosted or managed cloud. Custom activation strategies.
- Unleash Edge for low-latency evaluation. GitOps-friendly via API.
- Best for: teams needing data sovereignty, open-source flexibility.

### Flagsmith
- Open-source core with SaaS option. Remote config + flags in one. REST API-first.
- Edge proxy available. Multi-tenant support.
- Best for: teams wanting open-source with enterprise features, remote config bundled.

### PostHog
- All-in-one: flags, analytics, session replay, A/B testing. Open-source.
- Flags evaluated server-side with local evaluation option.
- Best for: product-led teams wanting integrated analytics + experimentation.

### Flipt
- Lightweight, Go-based, API-first. GitOps native (flags as code in YAML/JSON).
- No external dependencies. GRPC + REST APIs.
- Best for: developers wanting simple, fast, infra-as-code flags.

## OpenFeature Standard

OpenFeature is a CNCF vendor-neutral API for feature flag evaluation. Use it to avoid vendor lock-in.

### Core Concepts
- **Provider**: Adapter connecting OpenFeature API to a backend (LaunchDarkly, Flagsmith, etc.)
- **Client**: Application-facing API for evaluating flags
- **Evaluation Context**: Key-value attributes (user ID, role, region) passed to evaluation
- **Hooks**: Lifecycle callbacks (before/after/error/finally) for logging, metrics, context enrichment

### Server-Side Setup (Node.js)

```typescript
import { OpenFeature } from '@openfeature/server-sdk';
import { LaunchDarklyProvider } from '@launchdarkly/openfeature-node-server';

// Register provider once at startup
await OpenFeature.setProviderAndWait(
  new LaunchDarklyProvider(process.env.LD_SDK_KEY)
);

const client = OpenFeature.getClient();

// Evaluate with context
const showFeature = await client.getBooleanValue('new-dashboard', false, {
  targetingKey: user.id,
  email: user.email,
  plan: user.plan,
});
```

### Server-Side Setup (Python)

```python
from openfeature import api
from openfeature.contrib.provider.flagd import FlagdProvider
from openfeature.evaluation_context import EvaluationContext

api.set_provider(FlagdProvider())
client = api.get_client()

context = EvaluationContext(targeting_key="user-123", attributes={"role": "admin"})
enabled = client.get_boolean_value("new-dashboard", False, context)
```

### Server-Side Setup (Go)

```go
openfeature.SetProvider(flagd.NewProvider())
client := openfeature.NewClient("my-service")
ctx := openfeature.NewEvaluationContext("user-123", map[string]interface{}{"role": "admin"})
enabled, _ := client.BooleanValue(ctx, "new-dashboard", false, openfeature.EvaluationContext{})
```

### Server-Side Setup (Java)

```java
OpenFeatureAPI api = OpenFeatureAPI.getInstance();
api.setProvider(new FlagdProvider()); // dev.openfeature.contrib.providers.flagd
Client client = api.getClient();
EvaluationContext ctx = new ImmutableContext("user-123", Map.of("role", new Value("admin")));
boolean enabled = client.getBooleanValue("new-dashboard", false, ctx);
```

### Hooks

```typescript
const loggingHook: Hook = {
  before: (hookContext) => {
    console.log(`Evaluating: ${hookContext.flagKey}`);
  },
  after: (hookContext, details) => {
    metrics.increment('flag.evaluation', { flag: hookContext.flagKey, value: String(details.value) });
  },
  error: (hookContext, err) => { logger.error(`Flag error: ${hookContext.flagKey}`, err); },
};
client.addHooks(loggingHook);
```

## Implementation Patterns

### Simple Boolean

```typescript
if (await client.getBooleanValue('enable-new-checkout', false, ctx)) {
  return renderNewCheckout();
}
return renderLegacyCheckout();
```

### Multivariate

```typescript
const variant = await client.getStringValue('checkout-layout', 'control', ctx);
switch (variant) {
  case 'single-page': return renderSinglePage();
  case 'multi-step':  return renderMultiStep();
  default:            return renderControl();
}
```

### Percentage Rollout
Configure in flag platform: set rollout percentage based on hash of `targetingKey`. Users get consistent assignment. Ramp: 1% → 5% → 25% → 50% → 100%.

```yaml
# Unleash strategy example
strategies:
  - name: flexibleRollout
    parameters:
      rollout: "25"
      stickiness: "userId"
      groupId: "new-checkout"
```

### User Targeting
Target by attributes in evaluation context: plan, role, region, email domain, user ID list.

```yaml
# LaunchDarkly targeting rule (conceptual)
rules:
  - clauses:
      - attribute: plan
        op: in
        values: ["enterprise"]
    variation: true
fallthrough:
  rollout:
    variations:
      - variation: true
        weight: 10000  # 10%
      - variation: false
        weight: 90000
```

## Client-Side Flags (React)

### React SDK with OpenFeature

```tsx
import { OpenFeatureProvider, useBooleanFlagValue } from '@openfeature/react-sdk';
import { FlagdWebProvider } from '@openfeature/flagd-web-provider';

// Bootstrap with server-rendered values to avoid flicker
const bootstrapValues = window.__FLAG_VALUES__;

function App() {
  return (
    <OpenFeatureProvider>
      <Dashboard />
    </OpenFeatureProvider>
  );
}

function Dashboard() {
  const showNewUI = useBooleanFlagValue('new-dashboard', false);
  return showNewUI ? <NewDashboard /> : <LegacyDashboard />;
}
```

### Key Client-Side Concerns
- **Bootstrap values**: Inject server-evaluated flags into initial HTML to prevent flash of wrong content.
- **Streaming updates**: Use SSE/WebSocket connections for real-time flag changes without page reload.
- **Local evaluation**: Download ruleset to client, evaluate locally for zero-latency checks. Trade-off: exposes targeting rules.
- **Stale-while-revalidate**: Serve cached flag values immediately, update in background.

## Flag Lifecycle

### 1. Create
- Assign owner (person/team). Set flag type. Document purpose and expected removal date.
- Add flag to tracking system with TTL. Create removal ticket in backlog immediately.

### 2. Test
- Verify both on/off paths in staging. Run integration tests with flag in both states.
- For experiment flags: validate metric instrumentation before rollout.

### 3. Rollout
- Start at 1% for release flags. Monitor error rates, latency, business metrics.
- Ramp gradually: 1% → 5% → 25% → 50% → 100%. Minimum 24h between ramp-ups.
- For ops flags: enable in non-prod first, then prod with monitoring.

### 4. Cleanup
- Remove flag within 30 days of reaching 100% rollout.
- Steps: remove conditional code → remove flag from platform → remove tests specific to flag.
- Automate stale flag detection: alert when flags exceed TTL or have been 100% for >14 days.

## Testing with Flags

### Unit Testing — Mock the Provider

```typescript
// Use InMemoryProvider for deterministic tests
import { OpenFeature, InMemoryProvider } from '@openfeature/server-sdk';

beforeEach(async () => {
  await OpenFeature.setProviderAndWait(
    new InMemoryProvider({
      'new-checkout': { defaultVariant: 'on', variants: { on: true, off: false },
        disabled: false },
    })
  );
});

test('renders new checkout when flag is on', async () => {
  const client = OpenFeature.getClient();
  const enabled = await client.getBooleanValue('new-checkout', false);
  expect(enabled).toBe(true);
});
```

### Unit Testing — Python

```python
from openfeature.contrib.provider.in_memory import InMemoryProvider, InMemoryFlag

flags = {"new-checkout": InMemoryFlag("on", {"on": True, "off": False})}
api.set_provider(InMemoryProvider(flags))
client = api.get_client()
assert client.get_boolean_value("new-checkout", False) is True
```

### Integration Testing
- Run test suite with all flags ON and all flags OFF as separate CI jobs.
- Use pairwise testing for flag combinations: 10 flags = 1024 states → ~20 pairwise combos.
- Maintain a "flag matrix" CI step that tests critical flag interactions.

### Testing Anti-Patterns
- Never hardcode flag values in tests. Always use mock providers.
- Never test only the "on" path. Both paths are production code paths.
- Never skip cleanup: remove test fixtures when removing flags.

## Architecture

### Flag Evaluation Flow
`Dashboard → Flag Store (Rules DB) → Evaluation SDKs (in-process) → App Logic`. Updates pushed via SSE/Webhooks.

### Edge Evaluation
- Deploy rulesets to CDN edge (CloudFront, Cloudflare Workers) for sub-ms latency.
- Relay proxies (LaunchDarkly Relay, Unleash Edge) for self-hosted edge.
- Trade-off: eventual consistency (seconds) vs strong consistency.

### Caching
- **In-memory SDK cache**: Rulesets in memory, updated via streaming. Default for server-side.
- **Background polling**: Fallback if streaming disconnects. 30s–60s typical.
- **Push-based invalidation**: SSE/webhook preferred over TTL polling.

## Trunk-Based Development with Flags

### Short-Lived Release Flags
- Every feature branch merges to trunk behind a release flag. Flag is OFF by default.
- Maximum flag lifetime: 2 weeks for release flags. Enforce via CI lint.
- Merge cadence: at least daily. Flag protects incomplete work.

### Flag-Driven Development Workflow
1. Create flag before writing feature code.
2. Wrap new code paths in flag conditional.
3. Merge to trunk immediately (flag OFF). Deploy continuously.
4. Enable flag in staging for testing. Ramp in production.
5. Remove flag + old code path within 30 days of 100% rollout.

### CI Enforcement
Use `scripts/flag-cleanup.sh` or `assets/github-actions.yml` for CI enforcement. See [advanced-patterns.md](references/advanced-patterns.md) for governance details.

## A/B Testing Integration

### Experiment Flag Pattern

```typescript
const variant = await client.getStringValue('exp-pricing-v2', 'control', ctx);
analytics.track('experiment_exposure', {
  experiment: 'exp-pricing-v2',
  variant,
  userId: ctx.targetingKey,
});

if (variant === 'treatment-a') return <PricingV2A />;
if (variant === 'treatment-b') return <PricingV2B />;
return <PricingControl />;
```

### Requirements for Valid Experiments
- Deterministic assignment: same user always sees same variant (hash-based).
- Track exposure at assignment, not at render. Avoid multiple exposure events.
- Define primary metric and guardrail metrics before starting experiment.
- Run for minimum sample size (calculate with power analysis). Typical: 1–4 weeks.
- Statistical significance threshold: p < 0.05 or 95% credible interval (Bayesian).
- Do not peek at results and stop early. Pre-register stopping criteria.

### Metric Tracking Integration
```typescript
// PostHog experiment integration
posthog.capture('$feature_flag_called', {
  $feature_flag: 'exp-pricing-v2',
  $feature_flag_response: variant,
});
// Track conversion
posthog.capture('purchase_completed', { revenue: order.total });
```

## Operational Flags

### Kill Switches
Ops flags that instantly disable non-critical features under load.

```typescript
// Kill switch pattern — default to ON (feature enabled), flip OFF under pressure
const recsEnabled = await client.getBooleanValue('ops.kill.recommendations', true, ctx);
if (!recsEnabled) {
  return { recommendations: [], source: 'disabled' };
}
return await fetchRecommendations(user);
```

Rules: kill switches default to feature-enabled. Flipping to OFF disables. Name clearly: `ops.kill.<feature>`.

### Circuit Breakers
Combine flags with health checks for automatic degradation.

```typescript
async function withCircuitBreaker(flagKey: string, fn: () => Promise<any>, fallback: any) {
  const enabled = await client.getBooleanValue(flagKey, true);
  if (!enabled) return fallback;
  try {
    return await fn();
  } catch (err) {
    // Auto-disable via API if error rate exceeds threshold
    if (errorRate(flagKey) > 0.5) {
      await flagService.updateFlag(flagKey, false);
    }
    return fallback;
  }
}
```

### Gradual Rollouts for Infrastructure Changes
Use percentage rollouts for infrastructure migrations (new DB, new API version):

```python
# Python: gradual migration to new database
use_new_db = client.get_boolean_value("ops.migrate.new-db", False, context)
if use_new_db:
    result = new_db.query(sql)
    # Shadow-read from old DB to compare
    old_result = old_db.query(sql)
    if result != old_result:
        logger.warning("DB migration mismatch", extra={"query": sql})
    return result
return old_db.query(sql)
```

## Best Practices

### Flag Naming
- Format: `<type>.<team>.<feature>` — e.g., `release.checkout.apple-pay`
- Use kebab-case. No abbreviations. Be descriptive.
- Prefix with type: `release.`, `exp.`, `ops.`, `perm.`

### Flag Hygiene
- Maximum 20–30 active short-term flags per service.
- Review flags weekly in standup. Assign cleanup to sprint backlog.
- Automate: lint for flag references without matching platform definition.
- Track flag age in dashboards. Alert at 14 days (release), 60 days (experiment).

### Stale Flag Detection

Use `scripts/flag-cleanup.sh` or inline:

```typescript
const FLAG_RE = /client\.(getBooleanValue|getStringValue)\(['"]([^'"]+)['"]/g;
const codeFlags = new Set<string>();
for (const file of glob.sync('src/**/*.{ts,tsx,js,jsx}'))
  for (const m of readFileSync(file, 'utf-8').matchAll(FLAG_RE)) codeFlags.add(m[2]);
const platformFlags = await fetchPlatformFlags();
const orphaned = [...codeFlags].filter(f => !platformFlags.has(f));
const unused = [...platformFlags].filter(f => !codeFlags.has(f));
```

## Common Gotchas

- **Flag debt**: Every flag is tech debt from birth. Create removal ticket at creation. Enforce TTLs.
- **Combinatorial explosion**: 10 flags = 1024 states. Use pairwise testing (~20 combos). See [testing-strategies.md](references/testing-strategies.md).

- **Cache invalidation**: Use streaming (SSE) over polling. Never cache flag results in CDN — values are per-user.
- **Hot-path evaluation**: Evaluate once per request, store result. Don't call SDK in loops.
- **Default value mismatch**: SDK default must match "safe" behavior. Kill switches default to enabled.
- **Missing context**: Forgetting `targetingKey` causes all users to get same variant.
- **Nested flags**: `if (flagA && flagB)` creates implicit dependency. See [advanced-patterns.md](references/advanced-patterns.md).
- **Client-side exposure**: Flag names visible in client bundles leak experiment info.

---

## Reference Docs

Deep-dive references in `references/`:

| Document | Contents |
|----------|----------|
| [advanced-patterns.md](references/advanced-patterns.md) | Multi-armed bandit allocation, flag dependencies & prerequisites, mutual exclusion groups, scheduled rollouts, flag-driven DB migrations, governance, canary releases with flags, dynamic config vs flags, server-side vs client-side evaluation trade-offs, flag archival & cleanup automation |
| [platform-comparison.md](references/platform-comparison.md) | LaunchDarkly vs Unleash vs Flagsmith vs PostHog vs Flipt vs CloudBees vs Split — pricing, SDKs, targeting, RBAC, edge evaluation, OpenFeature compatibility, compliance (SOC2/HIPAA), decision guide by org type |
| [testing-strategies.md](references/testing-strategies.md) | Unit testing with mock providers, combinatorial/pairwise strategies, integration testing with flag states, evaluation logic testing, contract testing, load testing with flag changes, rollback scenario testing, flag-aware test fixtures |

## Scripts

Executable scripts in `scripts/` (bash, `chmod +x`):

| Script | Purpose | Key Flags |
|--------|---------|-----------|
| [init-openfeature.sh](scripts/init-openfeature.sh) | Set up OpenFeature in a project — detects language (Node/Python/Go/Java), installs SDK + provider, creates config file, generates usage example | `--lang`, `--provider`, `--dir`, `--dry-run` |
| [flag-cleanup.sh](scripts/flag-cleanup.sh) | Find stale flags — scans codebase for flag references, compares against platform API, reports orphaned/unused/fully-rolled-out flags | `--src`, `--provider`, `--api-url`, `--output [text\|json]` |
| [flag-audit.sh](scripts/flag-audit.sh) | Audit all flags — lists states, targeting rules, age, owner; flags beyond age threshold; governance checks | `--provider`, `--max-age`, `--output [text\|json\|csv\|markdown]` |

## Assets / Templates

Copy-paste-ready templates in `assets/`:

| Template | Language | What It Provides |
|----------|----------|------------------|
| [openfeature-provider.ts](assets/openfeature-provider.ts) | TypeScript | Custom OpenFeature provider with in-memory flag store, targeting rules engine (attribute matching, percentage rollout), event emission (READY, CHANGED, ERROR, STALE) |
| [react-feature-flag.tsx](assets/react-feature-flag.tsx) | React/TSX | `FeatureFlagProvider`, `useFeatureFlag` hook, `FeatureGate` component, typed convenience hooks, `withFeatureFlag` HOC, debug panel, error boundary |
| [flag-middleware.ts](assets/flag-middleware.ts) | TypeScript | Express middleware + Fastify plugin for flag evaluation with request context extraction, LRU caching, Prometheus metrics, JWT-based context builder |
| [flag-config.yaml](assets/flag-config.yaml) | YAML | Flag configuration template for Unleash/Flipt — strategies, variants, segments, metadata, scheduling; annotated with platform compatibility notes |
| [github-actions.yml](assets/github-actions.yml) | GitHub Actions | Flag lifecycle workflow — stale flag detection (weekly), PR checks for new flags, cleanup reminders (daily), monthly audit report |

---

## Quick Reference

| Task | Pattern |
|------|---------|
| Hide WIP feature | Release flag, default OFF, wrap in conditional |
| A/B test | Experiment flag, multivariate, track exposure event |
| Kill switch | Ops flag, default ON (enabled), flip OFF to disable |
| Entitlement gate | Permission flag, permanent, target by plan/role |
| Infra migration | Ops flag, percentage rollout, shadow-read comparison |
| Vendor-neutral SDK | OpenFeature + provider for your platform |
| Avoid flag debt | TTL at creation, CI lint, weekly review, removal ticket |
| Set up OpenFeature | Run `scripts/init-openfeature.sh` in project root |
| Find stale flags | Run `scripts/flag-cleanup.sh --src ./src` |
| Audit flag inventory | Run `scripts/flag-audit.sh --provider unleash` |
| Custom provider | Copy `assets/openfeature-provider.ts`, customize rules |
| React integration | Copy `assets/react-feature-flag.tsx`, wrap app |
| Server middleware | Copy `assets/flag-middleware.ts` for Express/Fastify |
| CI flag hygiene | Copy `assets/github-actions.yml` into `.github/workflows/` |

<!-- tested: needs-fix -->
