---
name: feature-flags
description:
  positive: "Use when user implements feature flags, asks about feature toggles, gradual rollouts, A/B testing, canary releases, trunk-based development with flags, LaunchDarkly, Unleash, or OpenFeature SDK."
  negative: "Do NOT use for environment variables as config, compile-time feature selection (#ifdef), or Kubernetes canary deployments without application-level flags."
---

# Feature Flags

## Feature Flag Types

Classify every flag into exactly one category. Each has different lifecycle expectations.

| Type | Purpose | Lifespan | Example |
|------|---------|----------|---------|
| **Release** | Hide incomplete features in production | Days–weeks | `new_checkout_flow` |
| **Experiment** | A/B test variants for data-driven decisions | Days–weeks | `pricing_page_variant` |
| **Ops** | Control operational behavior at runtime | Permanent | `enable_cache_layer` |
| **Permission** | Gate access for user segments or tiers | Permanent | `premium_dashboard` |

Treat release and experiment flags as temporary. Schedule removal at creation time. Ops and permission flags are long-lived but still require periodic review.

## Flag Lifecycle

Follow this sequence for every flag:

1. **Create** — Define flag with name, owner, type, description, and expiry date. Open a cleanup ticket immediately.
2. **Implement** — Add evaluation point in code. Default to `false` (off) for release flags.
3. **Enable** — Turn on for internal users or a small cohort first.
4. **Test** — Validate both on/off paths in staging and production.
5. **Rollout** — Gradually increase exposure: 1% → 10% → 50% → 100%.
6. **Stabilize** — Monitor metrics for at least one release cycle at 100%.
7. **Clean up** — Remove flag, delete dead code path, close cleanup ticket.

Skip step 7 only for ops and permission flags. Even those get annual review.

## Architecture Patterns

### Flag Evaluation Flow

```
Request → Extract Context → Evaluate Flag → Return Variant → Execute Code Path
                │                  │
                ▼                  ▼
         User attributes     Rules engine
         (id, email, plan)   (segments, %, overrides)
```

### Context and Targeting

Build an evaluation context from the request. Include attributes the rules engine needs.

```typescript
// TypeScript
const context: EvaluationContext = {
  targetingKey: user.id,
  email: user.email,
  plan: user.subscription.plan,
  country: request.geo.country,
  version: app.version,
};
```

### Fallbacks

Always provide a sensible default. Never let flag evaluation failure break the application.

```python
# Python
def get_flag(flag_key: str, default: bool = False) -> bool:
    try:
        return flag_client.evaluate(flag_key, default, context)
    except FlagEvaluationError:
        logger.warning(f"Flag evaluation failed for {flag_key}, using default={default}")
        return default
```

## OpenFeature Standard

OpenFeature is a CNCF project providing a vendor-agnostic API for feature flags. Use it to avoid vendor lock-in.

### Core Concepts

- **API** — Global singleton. Set provider, register hooks, create clients.
- **Provider** — Connects to a backend (LaunchDarkly, Unleash, Flagsmith, or custom).
- **Client** — Evaluates flags. Scoped to a domain/component.
- **Hook** — Injects logic before/after evaluation (logging, metrics, validation).
- **Evaluation Context** — Attributes for targeting (user ID, plan, geo).

### SDK Setup

```typescript
// TypeScript — OpenFeature with LaunchDarkly provider
import { OpenFeature } from '@openfeature/server-sdk';
import { LaunchDarklyProvider } from '@launchdarkly/openfeature-node-server';

await OpenFeature.setProviderAndWait(new LaunchDarklyProvider(sdkKey));
const client = OpenFeature.getClient();

const showBanner = await client.getBooleanValue('show-banner', false, {
  targetingKey: user.id,
  plan: user.plan,
});
```

```python
# Python — OpenFeature with Unleash provider
from openfeature import api
from openfeature.contrib.provider.unleash import UnleashProvider

api.set_provider(UnleashProvider(url="https://unleash.example.com/api", app_name="myapp"))
client = api.get_client()

show_banner = client.get_boolean_value("show-banner", False, EvaluationContext(
    targeting_key=user.id,
    attributes={"plan": user.plan},
))
```

### Hooks

```java
// Java — Logging hook
public class LoggingHook implements Hook<Boolean> {
    @Override
    public void after(HookContext<Boolean> ctx, FlagEvaluationDetails<Boolean> details, Map<String, Object> hints) {
        logger.info("Flag {} evaluated to {} for user {}",
            ctx.getFlagKey(), details.getValue(), ctx.getCtx().getTargetingKey());
    }
}

OpenFeatureAPI.getInstance().addHooks(new LoggingHook());
```

## Targeting Rules

### User Segments

Define named segments. Evaluate membership before flag rules.

```yaml
# Segment definition
segments:
  beta-testers:
    rules:
      - attribute: email
        operator: ends_with
        value: "@company.com"
      - attribute: opted_in_beta
        operator: equals
        value: true
```

### Percentage Rollouts

Hash the targeting key for deterministic, consistent assignment.

```go
// Go — Deterministic percentage rollout
func isInRollout(userID string, flagKey string, percentage int) bool {
    h := fnv.New32a()
    h.Write([]byte(flagKey + ":" + userID))
    bucket := h.Sum32() % 100
    return int(bucket) < percentage
}
```

### Attribute-Based Targeting

```python
# Target users on premium plan in EU
rules:
  - conditions:
      - attribute: plan
        operator: in
        values: ["pro", "enterprise"]
      - attribute: country
        operator: in
        values: ["DE", "FR", "NL", "SE"]
    variant: enabled
  - variant: disabled  # default
```

### Geo-Targeting

Derive country/region from IP at the edge. Pass as context attribute. Never hard-code geo logic in flag evaluation code.

## Implementation Patterns

### Simple If/Else

Use for straightforward on/off flags. Acceptable for release toggles with short lifespan.

```typescript
if (await flags.isEnabled('new-search', { targetingKey: user.id })) {
  return newSearchEngine.query(term);
}
return legacySearch.query(term);
```

### Strategy Pattern

Use when a flag selects between multiple implementations. Keeps flag evaluation separate from business logic.

```python
# Python — Strategy pattern
class PaymentProcessor(Protocol):
    def charge(self, amount: Decimal, currency: str) -> PaymentResult: ...

class StripeProcessor:
    def charge(self, amount, currency): ...

class NewPaymentProcessor:
    def charge(self, amount, currency): ...

def get_processor(user_context: dict) -> PaymentProcessor:
    variant = flags.get_string_value("payment-processor", "stripe", user_context)
    return {"stripe": StripeProcessor(), "new": NewPaymentProcessor()}[variant]
```

### Flag-Driven Dependency Injection

Register services conditionally at startup. Avoids runtime branching in hot paths.

```csharp
// C# — Flag-driven DI
services.AddScoped<INotificationService>(sp =>
{
    var flags = sp.GetRequiredService<IFeatureClient>();
    return flags.GetBooleanValue("use-new-notifications", false).Result
        ? sp.GetRequiredService<PushNotificationService>()
        : sp.GetRequiredService<EmailNotificationService>();
});
```

## Server-Side vs Client-Side Evaluation

| Aspect | Server-Side | Client-Side |
|--------|------------|-------------|
| **Latency** | Network call per evaluation (cacheable) | Near-zero after initial load |
| **Security** | Rules and segments stay on server | Rules exposed to client |
| **Freshness** | Real-time updates via streaming/SSE | Requires polling or push |
| **Targeting** | Full context available | Limited to client-visible attributes |
| **Use case** | API responses, backend logic | UI rendering, feature gating |

**Guidance:**
- Default to server-side evaluation. Move to client-side only for UI flags where latency matters.
- Never expose sensitive targeting rules (pricing tiers, internal user lists) to the client.
- Use server-side evaluation for anything that controls data access or business logic.
- For client-side, fetch a pre-evaluated flag set at page load. Avoid per-flag API calls from the browser.

## Testing with Flags

### Test All Paths

Every flag introduces a branch. Test both states explicitly.

```python
# Python — pytest parametrize
@pytest.mark.parametrize("flag_value", [True, False])
def test_checkout(flag_value, mock_flags):
    mock_flags.set("new-checkout", flag_value)
    result = checkout_service.process(order)
    assert result.success
```

### Flag-Aware Test Fixtures

Create fixtures that set flag state before each test. Reset after.

```typescript
// TypeScript — Jest
describe('SearchService', () => {
  beforeEach(() => {
    TestFlagProvider.reset();
  });

  it('uses new engine when flag is on', async () => {
    TestFlagProvider.set('new-search', true);
    const results = await searchService.query('test');
    expect(results.engine).toBe('v2');
  });

  it('falls back to legacy when flag is off', async () => {
    TestFlagProvider.set('new-search', false);
    const results = await searchService.query('test');
    expect(results.engine).toBe('v1');
  });
});
```

### Combinatorial Testing

When multiple flags interact, test critical combinations. Do not test the full matrix — focus on flags that share a code path.

```python
# Python — Test interacting flags
@pytest.mark.parametrize("search_v2,ranking_v2", [
    (True, True),
    (True, False),
    (False, False),
    # (False, True) is invalid — ranking_v2 requires search_v2
])
def test_search_with_ranking(search_v2, ranking_v2, mock_flags):
    mock_flags.set("search-v2", search_v2)
    mock_flags.set("ranking-v2", ranking_v2)
    results = search_service.query("test")
    assert len(results) > 0
```

## Flag Management

### Naming Conventions

Use lowercase kebab-case. Prefix with team or domain. Include the toggle type for temporary flags.

```
# Pattern: <team>.<feature>
payments.new-checkout-flow
search.ranking-v2
ops.cache-bypass
experiment.pricing-page-variant-b
```

### Ownership

Assign every flag an owner (team or individual). Store ownership in flag metadata, not comments.

```json
{
  "key": "payments.new-checkout-flow",
  "owner": "payments-team",
  "type": "release",
  "created": "2025-01-15",
  "expires": "2025-03-15",
  "jira": "PAY-1234",
  "description": "New Stripe-based checkout replacing legacy PayPal flow"
}
```

### Stale Flag Cleanup

Automate detection. Flag is stale when:
- Past expiry date
- Serving one variant to 100% of traffic for > 7 days
- No evaluation calls in > 30 days

Enforce cleanup in CI:

```bash
#!/bin/bash
# CI check: fail if stale flags exist
stale_flags=$(flag-cli list --status=stale --format=json)
if [ "$(echo "$stale_flags" | jq length)" -gt 0 ]; then
  echo "ERROR: Stale flags detected. Remove before merging."
  echo "$stale_flags" | jq -r '.[].key'
  exit 1
fi
```

### Technical Debt Prevention

- Create cleanup ticket at flag creation time, not after rollout.
- Set maximum flag count per service. Alert when threshold is exceeded.
- Run quarterly flag audits. Delete flags with no owner or expired tickets.
- Use tools like Piranha (Uber) for automated dead code removal after flag cleanup.

## Platform Comparison

| Platform | Model | Strengths | Considerations |
|----------|-------|-----------|----------------|
| **LaunchDarkly** | SaaS | Real-time streaming, 25+ SDKs, built-in experimentation, audit logs | Cost scales with MAU; vendor lock-in |
| **Unleash** | Open source / SaaS | Self-hosted option, strategy-based toggles, good CI/CD integration | Fewer analytics features than LD |
| **Flagsmith** | Open source / SaaS | Remote config + flags, self-hosted, trait-based targeting | Smaller ecosystem |
| **Flipt** | Open source | GitOps-native, no external dependencies, gRPC + REST | No built-in experimentation |
| **OpenFeature** | Standard | Vendor-agnostic API, swap providers without code changes | Not a platform — needs a provider backend |
| **Custom** | In-house | Full control, no vendor cost | Maintenance burden; reinventing targeting, audit, UI |

**Recommendation:** Start with OpenFeature SDK + one provider. Migrate providers without touching application code.

## Trunk-Based Development

Feature flags enable merging to `main` continuously without exposing unfinished work.

### Workflow

1. Develop on short-lived branch (< 1 day) or directly on `main`.
2. Wrap incomplete code behind a release flag defaulting to `off`.
3. Merge to `main`. Deploy to production. Flag keeps feature hidden.
4. Enable for internal users → QA → gradual rollout.
5. At 100%, remove flag and dead code path.

### Flag-Protected Deploys

```yaml
# GitHub Actions — Deploy with flag verification
- name: Verify new feature is flagged
  run: |
    grep -r "flags.isEnabled.*new-payment" src/ || {
      echo "ERROR: new-payment feature code found without flag guard"
      exit 1
    }
```

### Rules

- Never merge unflagged incomplete code to `main`.
- Keep flags at the highest reasonable abstraction level (route/controller, not deep in utility functions).
- One flag per feature. Do not split a single feature across multiple flags unless targeting requires it.

## Operational Flags

### Circuit Breakers

Disable a degraded dependency without redeploying.

```python
# Python — Circuit breaker flag
def get_recommendations(user_id: str) -> list[Product]:
    if not flags.is_enabled("ops.recommendations-enabled"):
        return []  # graceful degradation
    return recommendation_service.get(user_id)
```

### Kill Switches

Invert the default. Flag is normally `on`; flip to `off` to disable a feature instantly.

```typescript
// TypeScript — Kill switch
const SEARCH_ENABLED = await flags.getBooleanValue('ops.search-kill-switch', true);
if (!SEARCH_ENABLED) {
  return { results: [], message: 'Search is temporarily unavailable' };
}
```

### Load Shedding

Use percentage rollouts on ops flags to shed load progressively.

```go
// Go — Progressive load shedding
func handleRequest(w http.ResponseWriter, r *http.Request) {
    ctx := openfeature.NewEvaluationContext(r.Header.Get("X-User-ID"), nil)
    if shed, _ := client.BooleanValue(r.Context(), "ops.shed-heavy-queries", false, ctx); shed {
        http.Error(w, "Service busy, try again later", http.StatusServiceUnavailable)
        return
    }
    processHeavyQuery(w, r)
}
```

## Anti-Patterns

### Long-Lived Release Flags

**Problem:** A "temporary" release flag stays in code for months. Cognitive load grows. Both code paths drift.
**Fix:** Set hard expiry. Fail CI if flag exists past expiry date.

### Nested Flags

**Problem:** Flag evaluation inside another flag's code path. Combinatorial explosion.
```python
# BAD
if flags.is_enabled("feature-a"):
    if flags.is_enabled("feature-b"):
        do_ab()
    else:
        do_a()
```
**Fix:** Flatten. Create a single flag with string variants if combinations are intentional.

### Flag Coupling

**Problem:** Multiple services evaluate the same flag independently, risking inconsistent state.
**Fix:** Evaluate once at the entry point (API gateway or BFF). Pass the decision downstream as a request attribute.

### Missing Default

**Problem:** No fallback when flag service is unavailable. Application crashes.
**Fix:** Always pass a default value. Design the default to be the safe/existing behavior.

### Flag in Libraries

**Problem:** Shared libraries contain flag evaluations tied to a specific flag service.
**Fix:** Accept behavior as a parameter or interface. Let the calling application control flag evaluation.

### No Cleanup Process

**Problem:** Flags accumulate. Nobody removes them. Codebase becomes unreadable.
**Fix:** Automate. Create cleanup ticket at flag creation. Run stale-flag detection in CI. Set per-service flag limits.

### Testing Only the Happy Path

**Problem:** Tests only run with the flag `on`. The `off` path silently breaks.
**Fix:** Parametrize tests across all flag states. Include flag state in test names for traceability.

<!-- tested: pass -->
