# QA Review: django-advanced

**Skill path:** `~/skillforge/backend/django-advanced/`
**Reviewer:** Copilot CLI automated QA
**Date:** 2025-07-17

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter (`name`, `description`) | ✅ Pass | `name: django-advanced`, multiline `description` present |
| Positive triggers | ✅ Pass | Covers: models, ORM (Q/F/Subquery/annotations/aggregations/window), CBVs, middleware, signals, caching, async views, DRF (serializers/viewsets/permissions/auth/throttling/filtering), Channels/WebSockets, deployment, migrations, management commands, testing, security, Django 5.x features |
| Negative triggers | ✅ Pass | Excludes: Flask, FastAPI, SQLAlchemy (without Django), general Python, Node.js/Express, Rails, PHP/Laravel |
| Body under 500 lines | ✅ Pass | 494 lines (`wc -l`) — just within limit |
| Imperative voice | ✅ Pass | Consistent use throughout ("Use `db_default`…", "Use sparingly…", "Never hand-edit…") |
| Code examples | ✅ Pass | Every section includes runnable, copy-paste-ready Python/bash snippets |
| References/scripts linked | ✅ Pass | Tables at bottom link all 3 reference docs, 2 scripts, 3 asset templates |

---

## B. Content Check

### Verified correct against Django 5.x / DRF 3.15 docs

- **`db_default` / `GeneratedField`** — API usage, parameter names (`expression`, `output_field`, `db_persist`) all correct per Django 5.0 docs.
- **ORM methods** — `Q`, `F`, `Subquery`, `OuterRef`, `Exists`, `Avg`, `Count`, `Sum`, `Case`/`When`, `Window`, `Rank`, `Lag`, `TruncMonth` — all correct.
- **DRF patterns** — `ModelSerializer`, `ModelViewSet`, `@action`, `IsOwnerOrReadOnly` permission, `DjangoFilterBackend`, `SearchFilter`, `OrderingFilter`, throttle scopes — all match DRF 3.15 API.
- **Channels** — `AsyncWebsocketConsumer` lifecycle (`connect`/`disconnect`/`receive`/custom handler) is correct.
- **Management commands** — `BaseCommand`, `add_arguments`, `self.style.SUCCESS` — correct.
- **Security settings** — All settings names verified (HSTS, CSP, CSRF, SSL redirect).
- **Deployment** — Gunicorn worker formula, nginx proxy config — correct.

### Issues found

| Severity | Location | Issue |
|---|---|---|
| ⚠️ Minor | `references/troubleshooting.md` — Connection Pooling §  | Uses `"pool": True` + separate `"pool_options": { "min_size": 2, "max_size": 10 }`. The correct Django 5.1+ API is `"pool": { "min_size": 2, "max_size": 10 }` (a dict replaces `True`). There is no `pool_options` key. |
| ⚠️ Minor | `references/troubleshooting.md` — Connection Pooling § | Missing critical requirement: `CONN_MAX_AGE` must be `0` when connection pooling is enabled; Django raises an error otherwise. |
| ⚠️ Minor | SKILL.md — `db_default` section | Missing gotcha: when only `db_default` is set (no `default`), the Python attribute is a `DatabaseDefault` sentinel before `save()`, which can break pre-save logic. Recommend noting to set both `default` and `db_default` for safety. |
| 💡 Suggestion | SKILL.md triggers | Consider adding "Django admin customization", "Celery tasks", and "Django forms" as positive triggers — these are covered in `references/advanced-patterns.md` but not called out in the description. |
| 💡 Suggestion | SKILL.md | `transaction.atomic()` / `select_for_update()` patterns are in references but not in the main body. These are common enough to warrant a brief section or cross-reference in SKILL.md. |

### Missing gotchas (minor)

- No mention of `QuerySet.aiterator()` for async chunked iteration (Django 4.1+).
- Async ORM note could mention that not all ORM operations are async-native yet (e.g., `aggregate()` and `raw()` still require `sync_to_async`).

---

## C. Trigger Check

| Aspect | Assessment |
|---|---|
| **Specificity** | Good — description enumerates concrete APIs (Q/F/Subquery, serializers/viewsets) so the model can match on exact terms. |
| **False-positive risk** | Low — negative triggers cover the main competing frameworks. Edge case: "SQLAlchemy with Django" queries _should_ partially trigger (Django side), and they will since the exclusion is "SQLAlchemy _without_ Django". |
| **False-negative risk** | Low-to-medium — Django admin, forms, and Celery-with-Django queries might not trigger since they aren't listed. These topics are covered in references but the trigger might be missed. |
| **Pushiness** | Adequate — description uses imperative "Use when:" phrasing, which is direct enough for trigger matching. |

---

## D. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 / 5 | All main SKILL.md code is correct. One incorrect API example (`pool_options`) and one missing gotcha (`db_default` sentinel) in supporting files. |
| **Completeness** | 4 / 5 | Excellent breadth — 15+ topics with depth. References cover remaining patterns well. Minor gaps: transactions in main body, async ORM limitations, admin/forms triggers. |
| **Actionability** | 5 / 5 | Every section has copy-paste-ready code. Scripts scaffold full projects. Templates are production-ready. Troubleshooting guide follows symptoms→cause→fix→prevention. |
| **Trigger quality** | 4 / 5 | Comprehensive positive/negative list. Minor gaps for admin, forms, Celery. No false-trigger risk. |
| **Overall** | **4.25 / 5** | High-quality skill. Address the connection pooling API error and `db_default` gotcha; the rest is polish. |

---

## E. GitHub Issues

**Not required.** Overall score (4.25) ≥ 4.0 and no individual dimension ≤ 2.

---

## F. Tested Status

**Result: PASS**

Recommended follow-ups (non-blocking):
1. Fix `pool_options` → `pool: { dict }` in `references/troubleshooting.md`.
2. Add `CONN_MAX_AGE=0` note to pooling section.
3. Add `db_default` gotcha note in SKILL.md.
4. Consider adding "admin", "forms", "Celery" to trigger description.
