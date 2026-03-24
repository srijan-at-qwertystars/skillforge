# QA Review: Ruby on Rails Skill

**Skill path:** `backend/ruby-on-rails/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-18

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `ruby-on-rails` |
| YAML frontmatter `description` | ✅ Pass | Comprehensive, covers all major subsystems |
| Positive triggers | ✅ Pass | 11 positive triggers: Rails, Ruby on Rails, Active Record, Rails API, Turbo, Hotwire, Stimulus, Action Cable, Solid Queue, Rails controller, Rails migration |
| Negative triggers | ✅ Pass | NOT for plain Ruby, NOT for Sinatra/Hanami/Roda, NOT for Django/Laravel/Express |
| Body under 500 lines | ✅ Pass | 498 lines (2 lines of margin) |
| Imperative voice | ✅ Pass | "Follow Convention over Configuration", "Use generators", "Never edit schema.rb", "Always add null: false" |
| Examples with I/O | ✅ Pass | Migration generator (input: CLI command → output: migration class), auth generator (input → output), query composition, N+1 before/after |
| Resources linked | ✅ Pass | 3 references, 3 scripts, 5 asset templates — all listed in tables with descriptions |

**Structure verdict: PASS** — all criteria met.

---

## B. Content Check

### Rails 8 Features (verified via web search against official release notes)

| Feature | Skill Claims | Verified | Status |
|---------|-------------|----------|--------|
| Solid Queue | DB-backed job queue, no Redis, recurring jobs in `config/recurring.yml` | ✅ Correct | Pass |
| Solid Cache | DB-backed persistent cache, replaces Redis/Memcached | ✅ Correct | Pass |
| Solid Cable | DB-backed Action Cable adapter, no Redis | ✅ Correct | Pass |
| Authentication generator | `rails g authentication` → User model + has_secure_password, Session model/controller, views, migrations | ✅ Correct | Pass |
| Propshaft | Simpler asset pipeline, replaces Sprockets | ✅ Correct | Minor nit: "HTTP/2" in features table is more a Thruster characteristic than Propshaft itself |
| Kamal 2 + Thruster | Docker zero-downtime deploy with built-in proxy | ✅ Correct | Pass |
| `params.expect` | Replaces `params.require.permit`, safer strong params | ✅ Correct | Syntax `params.expect(article: [:title, ...])` verified accurate |

### Active Record Query Interface (verified against Rails API docs)

| Method | Accuracy |
|--------|----------|
| `find_sole_by` / `sole` | ✅ Correct — raises `SoleRecordExceeded` / `RecordNotFound` |
| `where.missing(:assoc)` | ✅ Correct — LEFT OUTER JOIN WHERE NULL (Rails 7+) |
| `where.associated(:assoc)` | ✅ Correct — INNER JOIN EXISTS (Rails 7+) |
| `invert_where` | ✅ Correct — negates previous where |
| `load_async` / `count_async` | ✅ Correct — concurrent queries |
| `includes` / `preload` / `eager_load` | ✅ Correct semantics described |
| `strict_loading` | ✅ Correct — per-query, per-association, per-record, app-wide |

### Gemfile Versions

| Gem | Specified | Current Stable | Status |
|-----|-----------|---------------|--------|
| `rails` | `~> 8.0` | 8.1.2 | ✅ OK — `~> 8.0` means `>= 8.0, < 9.0`, matches latest |
| `ruby` | `>= 3.2.0` | 3.4.x | ✅ Correct minimum for Rails 8 |
| `puma` | `>= 6.0` | 6.x | ✅ Current |
| `solid_queue` / `solid_cache` / `solid_cable` | Unpinned | Tracks Rails 8.x | ✅ Best practice — Bundler resolves |

**Issue found:** `assets/Gemfile` line 55 includes `gem "actiontext", require: "action_text"` — Action Text is bundled with Rails 8 and does not need a separate gem declaration. This is misleading for users copying the template.

### Hotwire / Turbo / Stimulus

- ✅ Import path `@hotwired/stimulus` is correct
- ✅ `turbo_frame_tag`, `turbo_stream.append`, `broadcasts_refreshes_to` — all accurate APIs
- ✅ Stimulus targets, values (with types/defaults), actions, outlets — correct syntax
- ✅ `data-controller`, `data-action`, `data-*-target` naming conventions correct
- ✅ Morph streams (`broadcasts_refreshes_to`) correctly attributed to Rails 8

**Content verdict: PASS** — one minor Gemfile template issue (actiontext), one minor Propshaft/HTTP2 attribution nit. No factual errors in SKILL.md body.

---

## C. Trigger Check

### Positive triggers (should activate)

| Query | Would Trigger? | Via |
|-------|---------------|-----|
| "How do I create a Rails migration?" | ✅ Yes | "Rails migration" |
| "Active Record N+1 query problem" | ✅ Yes | "Active Record" |
| "Turbo Streams broadcasting" | ✅ Yes | "Turbo" |
| "Solid Queue recurring jobs setup" | ✅ Yes | "Solid Queue" |
| "Rails 8 authentication generator" | ✅ Yes | "Rails" |
| "Hotwire Stimulus controller" | ✅ Yes | "Hotwire", "Stimulus" |
| "Rails API versioning" | ✅ Yes | "Rails API" |
| "Action Cable WebSocket" | ✅ Yes | "Action Cable" |

### Negative triggers (should NOT activate)

| Query | Would Trigger? | Correct? |
|-------|---------------|----------|
| "Ruby string manipulation" | ❌ No | ✅ Correct — no Rails keyword |
| "Sinatra REST API" | ❌ No | ✅ Correct — explicit exclusion |
| "Hanami router setup" | ❌ No | ✅ Correct — explicit exclusion |
| "Django ORM query" | ❌ No | ✅ Correct — explicit exclusion |
| "Laravel controller" | ❌ No | ✅ Correct — explicit exclusion |
| "Ruby gem packaging" | ❌ No | ✅ Correct — no Rails keyword |

### Edge cases

| Query | Would Trigger? | Assessment |
|-------|---------------|------------|
| "Turbo C++ compiler" | ⚠️ Possible false positive | Low risk — context disambiguates |
| "Active Record design pattern (non-Rails)" | ⚠️ Possible false positive | Low risk — rare query |
| "Roda web framework" | ❌ No | ✅ Correct — Roda explicitly excluded |

**Trigger verdict: PASS** — strong discrimination between Rails and non-Rails contexts. Minor false-positive risk on "Turbo" alone is acceptable.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4/5 | All Rails 8 features verified correct. Active Record API accurate. Minor: Propshaft/HTTP2 attribution blurred with Thruster; `actiontext` gem in Gemfile template is unnecessary for Rails 8. |
| **Completeness** | 5/5 | Exceptional breadth: MVC, Active Record (migrations, associations, validations, scopes, N+1, callbacks), Controllers, Hotwire (Turbo Frames/Streams, Stimulus), Active Job + Solid Queue, Action Cable, Mailer, API mode, Auth (Rails 8 + Devise), Pundit, Service objects, Concerns, Caching, Testing (RSpec + Minitest + FactoryBot), Rails 8 features table, Anti-patterns. 3 reference docs, 3 scripts, 5 asset templates. |
| **Actionability** | 5/5 | Every section has production-ready code. Templates are copy-paste usable. Scripts are executable with `--help`. Service object, model, and controller templates follow community best practices. Anti-patterns list is immediately applicable. |
| **Trigger quality** | 4/5 | 11 positive triggers covering main Rails terms. 6 explicit negative exclusions. Good discrimination. Minor false-positive risk on standalone "Turbo". Could add "Devise" and "Pundit" as positive triggers. |

### Overall Score: **4.5 / 5.0**

---

## Recommendations (non-blocking)

1. **`assets/Gemfile`:** Remove `gem "actiontext"` line — Action Text ships with Rails 8 by default.
2. **SKILL.md line 458:** Propshaft's benefit column says "HTTP/2" — this is Thruster's contribution, not Propshaft. Consider: "Simpler asset pipeline, no preprocessor dependency."
3. **Triggers:** Consider adding "Devise" and "Pundit" as positive triggers since the skill covers both extensively.
4. **SKILL.md line count:** At 498/500 lines, there's almost no room. If content is added, consider moving the Anti-Patterns section to a reference file.

---

## Verdict

**PASS** — Overall 4.5/5, no dimension ≤ 2, all structure criteria met. No GitHub issues required.
