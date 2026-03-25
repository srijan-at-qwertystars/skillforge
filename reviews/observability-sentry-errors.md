# Review: sentry-errors

Accuracy: 4/5
Completeness: 4/5
Actionability: 4/5
Trigger quality: 5/5
Overall: 4.2/5

## Issues

### Accuracy

1. **Deprecated `push_scope` API (SKILL.md L206)** — `sentry_sdk.push_scope()` is deprecated in Python SDK v2.0+. Should use `sentry_sdk.new_scope()` instead. The code still runs but emits a DeprecationWarning.

2. **Deprecated `version` input in `getsentry/action-release@v3` (SKILL.md L305, assets/github-actions-sentry.yml L101)** — The `version` input is deprecated in action-release v3.x in favor of `release`. Same issue in the assets template.

3. **Custom span `setStatus` signature (SKILL.md L245-246)** — `span.setStatus({ code: 1, message: "ok" })` uses an OpenTelemetry-style object. The documented Sentry v8 API is `span.setStatus('ok')` or `span.setStatus('internal_error')` as a simple string.

4. **Next.js `experimental.instrumentationHook` (assets/sentry-nextjs.config.ts L28-30)** — No longer needed in Next.js 15+. Should add a comment noting this is only required for Next.js 13.4–14.x.

### Completeness

5. **No v7→v8 migration notes** — Sentry JS SDK v8 (2024) introduced breaking changes: `startTransaction` removed, separate `instrument.js` file required for Node.js, OpenTelemetry under the hood. Engineers upgrading will hit these. At minimum, a note or link to migration docs would help.

6. **Missing ESM `--import` flag gotcha** — For ESM Node.js projects with Sentry v8, you must use `node --import ./instrument.mjs app.mjs`. This is a common stumbling block not mentioned anywhere in the skill.

### Non-issues (verified correct)

- Self-hosted "~16GB RAM minimum" — confirmed correct per 2024 docs
- `tracesSampler` function signature and usage — correct for v8
- `sentryVitePlugin` config — correct
- sentry-cli commands — correct
- Scripts (`setup-sentry.sh`, `upload-sourcemaps.sh`) — well-structured, correct flags
- References are comprehensive and properly linked
- SKILL.md is exactly 500 lines (at limit)

## Structure

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive triggers (USE when) and negative triggers (DO NOT USE when)
- ✅ Body at 500 lines (at limit, acceptable)
- ✅ Imperative voice, no filler
- ✅ Code examples throughout with clear input/output patterns
- ✅ `references/`, `scripts/`, and `assets/` properly linked from SKILL.md tables

## Verdict

**Pass** — High-quality skill with strong coverage across 7 languages/frameworks, production-ready templates, and useful automation scripts. The deprecated API patterns are functional but should be updated. No blocking issues for an AI consumer.
