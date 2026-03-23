# QA Review: pydantic-patterns

**Skill path:** `~/skillforge/python/pydantic-patterns/`
**Reviewed:** $(date -u +%Y-%m-%d)
**Reviewer:** Copilot QA

---

## (a) Structure

| Check | Status | Notes |
|-------|--------|-------|
| Frontmatter `name` | ✅ Pass | `pydantic-patterns` |
| Frontmatter `description` | ✅ Pass | Present with positive and negative triggers |
| Positive triggers | ✅ Pass | Comprehensive: BaseModel, Field, field_validator, model_validator, BaseSettings, TypeAdapter, ConfigDict, computed_field, discriminated union, RootModel, model_dump, model_validate |
| Negative triggers | ✅ Pass | Django ORM, SQLAlchemy-only, marshmallow, attrs/cattrs, stdlib dataclasses |
| Body ≤ 500 lines | ✅ Pass | 496 lines (tight but compliant) |
| Imperative voice | ✅ Pass | Directive tone throughout ("Always use…", "Never raise…", "Use…") |
| Resources linked | ✅ Pass | references/, scripts/, assets/ all catalogued in final section |

**Files reviewed:**

- `SKILL.md` (496 lines)
- `references/advanced-patterns.md` — RootModel, recursive models, create_model, inheritance, PrivateAttr, context validators, custom JSON, msgpack/protobuf, pydantic-extra-types, custom errors, benchmarks
- `references/troubleshooting.md` — v1→v2 migration errors, validator ordering, circular refs, Optional/None, mutable defaults, FastAPI/mypy
- `references/settings-guide.md` — multi env files, secrets, custom sources, nested flattening, 12-factor, testing
- `scripts/pydantic-migrate.sh` — v1→v2 scanner + bump-pydantic wrapper
- `scripts/pydantic-schema-gen.sh` — JSON Schema generation from model
- `scripts/pydantic-validate-config.py` — validate JSON/YAML/TOML against a model
- `assets/base_model_template.py` — v2 model template with validators, serializers, computed fields
- `assets/settings_template.py` — BaseSettings template with nested config, validators, lru_cache singleton
- `assets/fastapi_models.py` — request/response separation, pagination, PATCH, bulk ops, filters
- `assets/discriminated_union_example.py` — tagged unions, custom discriminator functions, TypeAdapter

---

## (b) Content — Pydantic v2 Fact-Check

Verified against official Pydantic docs, GitHub issues, and release notes.

### ❌ Inaccuracy: `FieldValidationInfo` (deprecated)

**SKILL.md line 87** uses `FieldValidationInfo` as the type hint:

```python
(cls, v, info: FieldValidationInfo)
```

`FieldValidationInfo` was deprecated in Pydantic v2.4 and replaced by `ValidationInfo`. The references file (`advanced-patterns.md` line 249) correctly uses `ValidationInfo`, but the main SKILL.md body does not. This inconsistency could lead users to adopt a deprecated API.

**Fix:** Replace `FieldValidationInfo` → `ValidationInfo` on SKILL.md line 87.

### ❌ Inaccuracy: `union_mode` is not a ConfigDict option

**SKILL.md line 263:**

> For evolving APIs with unknown types: `union_mode='left_to_right'` in `ConfigDict`.

`union_mode` is a **per-field** setting via `Field(union_mode='left_to_right')`, not a ConfigDict option. There is no model-wide `union_mode` in ConfigDict.

**Fix:** Change to `Field(union_mode='left_to_right')` and note it's per-field.

### ❌ Inaccuracy: `max_depth` does not exist in ConfigDict

**references/advanced-patterns.md lines 105–106:**

> set `max_depth` in `ConfigDict` or validate depth in a `model_validator`.

Pydantic v2 has no `max_depth` ConfigDict option. Depth limiting must be implemented manually via validators or custom serializers.

**Fix:** Remove the `max_depth` in ConfigDict claim; keep only the model_validator suggestion.

### ⚠️ Minor: `datetime.utcnow()` usage

Both `assets/base_model_template.py` (line 92) and `assets/settings_template.py` (line 153 via `TimestampMixin`) use `datetime.utcnow()`, which is deprecated in Python 3.12+. Should use `datetime.now(datetime.UTC)` or `datetime.now(timezone.utc)`.

### ✅ Verified correct

| Claim | Status |
|-------|--------|
| `model_dump()` / `model_validate()` / `model_dump_json()` API names | ✅ Correct |
| `@field_validator` requires `@classmethod` | ✅ Correct |
| `mode='before'` / `mode='after'` / `mode='wrap'` for validators | ✅ Correct |
| `ConfigDict(populate_by_name=True)` | ✅ Correct |
| `ConfigDict(from_attributes=True)` replaces `orm_mode` | ✅ Correct |
| `ConfigDict(strict=True, frozen=True, extra="forbid", defer_build=True)` | ✅ Correct |
| `Field(pattern=...)` replaces `Field(regex=...)` | ✅ Correct |
| `Field(deprecated=...)` available ≥ 2.7 | ✅ Confirmed (April 2024 release) |
| `pydantic.v1` shim broken on Python ≥ 3.14 | ✅ Confirmed (incompatible, not formally "removed") |
| `RootModel` replaces `__root__` | ✅ Correct |
| `no_info_plain_validator_function` in `__get_pydantic_core_schema__` | ✅ Valid (low-level but correct for custom types) |
| `pydantic-settings` as separate package with `BaseSettings` | ✅ Correct |
| `GenericModel` not needed in v2 | ✅ Correct |
| `model_rebuild()` for circular references | ✅ Correct |
| `TypeAdapter` for standalone type validation | ✅ Correct |
| v1→v2 migration table | ✅ All renames verified correct |
| `Optional[X]` no longer implies `default=None` in v2 | ✅ Correct |
| Validator execution order (before → coercion → after → model_after) | ✅ Correct |
| `bump-pydantic` auto-refactoring tool | ✅ Correct |

### Missing gotchas not covered

1. **`FieldValidationInfo` deprecation** — Users migrating from early v2 (2.0–2.3) will hit this.
2. **`datetime.utcnow()` deprecation** — Python 3.12+ emits `DeprecationWarning`; templates should use timezone-aware alternatives.
3. **`model_config` merging in inheritance** — SKILL.md references section covers it but main body doesn't highlight that child ConfigDict values *merge* (not replace) with parent.

---

## (c) Trigger Quality

**Positive triggers:** Excellent coverage. Includes all major v2 API surface: `BaseModel`, `Field`, `field_validator`, `model_validator`, `BaseSettings`, `TypeAdapter`, `ConfigDict`, `computed_field`, `discriminated union`, `RootModel`, `model_dump`, `model_validate`, plus domain concepts like "data validation", "serialization", "JSON schema generation".

**Negative triggers:** Well-scoped exclusions for Django ORM, SQLAlchemy-only, marshmallow, attrs/cattrs, stdlib dataclasses. Prevents false positives on adjacent Python modeling libraries.

**Edge cases considered:** The "without Pydantic" qualifier on SQLAlchemy and dataclass exclusions is precise — allows the skill to fire when Pydantic is used alongside those tools.

**Verdict:** No trigger gaps identified. Would correctly activate on realistic prompts like "validate API request body with Pydantic" and correctly skip "create a Django model for users".

---

## (d) Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3 / 5 | Three factual errors: deprecated `FieldValidationInfo` type, `union_mode` wrongly attributed to ConfigDict, non-existent `max_depth` ConfigDict option. Core API names and patterns are correct. |
| **Completeness** | 4 / 5 | Comprehensive coverage of v2 features. Minor gaps: `PlainValidator`/`WrapValidator` not in main body, `PrivateAttr` only in references, missing `datetime.utcnow()` deprecation warning. Excellent reference files fill most gaps. |
| **Actionability** | 5 / 5 | Code examples are complete and runnable. Templates are copy-pasteable. Scripts have proper usage docs. Migration table is practical. Anti-patterns section with DO/DON'T pairs is immediately useful. |
| **Trigger Quality** | 5 / 5 | Comprehensive positive triggers, well-scoped negative exclusions, precise qualifiers. No gaps or false-positive risks identified. |

**Overall: 4.25 / 5**

---

## Disposition

- **GitHub issue required?** No (overall ≥ 4.0, no dimension ≤ 2)
- **SKILL.md annotation:** `<!-- tested: needs-fix -->` (3 factual errors require correction before production use)

### Recommended fixes (priority order)

1. **SKILL.md line 87:** Replace `FieldValidationInfo` → `ValidationInfo`
2. **SKILL.md line 263:** Change `union_mode='left_to_right'` in `ConfigDict` → `Field(union_mode='left_to_right')` (per-field)
3. **references/advanced-patterns.md lines 105–106:** Remove `max_depth` in ConfigDict claim
4. **assets/base_model_template.py line 92, assets/settings_template.py:** Replace `datetime.utcnow()` → `datetime.now(timezone.utc)`
