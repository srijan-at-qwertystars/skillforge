# Review: feature-flags

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **Go OpenFeature SDK API is incorrect (SKILL.md line 109):** `client.BooleanValue(ctx, "new-dashboard", false, openfeature.EvaluationContext{})` passes an `openfeature.EvaluationContext` as the first argument where `context.Context` is required. The correct signature is `client.BooleanValue(context.Background(), "new-dashboard", false, evalCtx)`. Users who copy-paste this code will get a compile error.

2. **LaunchDarkly pricing model is wrong (platform-comparison.md line 74):** Foundation plan is listed as "~$12/seat/month" but LaunchDarkly prices by **service connection** ($12/connection/month, or $10 billed annually), not per seat. Seats are unlimited on all paid plans. This is a meaningful factual error for teams evaluating cost.

3. **Flipt license is outdated (SKILL.md line 56, platform-comparison.md):** Listed as "Open-source (GPL 3.0)" but Flipt v2 moved to the Fair Core License (FCL), a Fair Source license. GPL-3.0 only applies to pre-v2 releases. SDKs remain MIT.

## Structure Check

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive triggers (feature flags, toggles, progressive rollouts, canary releases, kill switches, dark launches, OpenFeature, flag hygiene)
- ✅ Description has negative triggers (CI/CD pipelines, env vars without flag semantics, simple config, A/B testing without flags, general deployment)
- ✅ Body is 499 lines (under 500 limit)
- ✅ Imperative voice ("Classify every flag by type", "Use it to avoid vendor lock-in", "Assign owner")
- ✅ Examples with I/O in 4 languages (TypeScript, Python, Go, Java) plus React, YAML config
- ✅ Resources properly linked: 3 reference docs, 3 scripts, 5 assets — all with relative paths and description tables

## Content Check

- ✅ OpenFeature Node.js/Python/Java SDK APIs are accurate (`getBooleanValue`, `get_boolean_value`, `getBooleanValue`)
- ❌ OpenFeature Go SDK API has wrong parameter order (see issue #1)
- ✅ OpenFeature core concepts (Provider, Client, EvaluationContext, Hooks) are correct
- ✅ Unleash activation strategies (`flexibleRollout`, stickiness, groupId) are accurate per current docs
- ❌ LaunchDarkly Foundation pricing is per-service-connection, not per-seat (see issue #2)
- ❌ Flipt license changed from GPL-3.0 to Fair Core License in v2 (see issue #3)
- ✅ Flag evaluation patterns (boolean, multivariate, percentage rollout, user targeting) are correct
- ✅ Flag lifecycle, testing strategies, architecture patterns are solid
- ✅ Platform-comparison.md includes appropriate "Last reviewed: 2025" disclaimer
- ✅ Scripts are well-structured with proper usage docs, option parsing, error handling
- ✅ Assets are production-quality TypeScript/React with proper types and error handling

## Trigger Check

- ✅ Would correctly trigger for: feature flags, feature toggles, progressive rollouts, canary releases via flags, kill switches, dark launches, OpenFeature SDK setup, flag provider integration, experiment flags, flag hygiene
- ✅ Would correctly NOT trigger for: general CI/CD pipelines, environment variables without flag semantics, simple config files, general deployment strategies
- ✅ A/B testing boundary is well-drawn: triggers for A/B with flags, not for standalone A/B tools (Optimizely, Google Optimize)
- ✅ No false-positive risk for general config management queries (explicitly excluded)

## Summary

Exceptionally comprehensive skill covering the full feature flag domain. The 3 reference docs (4,671 lines), 3 executable scripts (2,186 lines), and 5 copy-paste assets (4,426 lines) provide deep, actionable content. The main SKILL.md is well-structured with a quick-reference table. Only issues are the Go SDK API bug, LaunchDarkly pricing model error, and outdated Flipt license — all fixable with minor edits.
