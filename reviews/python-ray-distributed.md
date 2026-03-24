# QA Review: ray-distributed

**Skill path:** `~/skillforge/python/ray-distributed/SKILL.md`
**Reviewed:** $(date -u +%Y-%m-%d)
**Verdict:** needs-fix

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ | name, description, positive + negative triggers present |
| Description with +/- triggers | ✅ | 21 positive, 9 negative triggers |
| Under 500 lines | ✅ | 406 lines |
| Imperative voice | ✅ | Consistently uses imperative ("Always call", "Use", "Set", "Avoid") |
| Code examples | ✅ | 10+ code blocks covering all Ray subsystems |
| References linked | ✅ | 3 deep-dive guides (ray-serve-guide.md, troubleshooting.md, kuberay-guide.md) — all exist |
| Scripts linked | ✅ | 3 operational scripts (setup, deploy, benchmark) — all exist and executable |
| Assets linked | ✅ | 5 assets (YAML configs, Python examples, docker-compose) — all exist |
| `globs:` field | ⚠️ | Empty — consider adding `**/*ray*`, `**/ray_*.py` |

**Structure score: strong.** Excellent organization with clear sections, anti-patterns, comparison table, and production checklist.

---

## b. Content Check — API Accuracy

### ❌ `local_mode=True` is deprecated/removed (Line 369)

The Production Checklist recommends:
> `ray.init(local_mode=True)` for debugging serialization issues

`local_mode` was deprecated in Ray 2.0 and removed in recent versions. Modern Ray will raise an error on this parameter. The recommended replacement is the **Ray Distributed Debugger** or using `ray debug` CLI.

**Severity: HIGH** — following this advice produces a runtime error in Ray ≥2.10.

### ⚠️ `target_num_ongoing_requests_per_replica` renamed (Line 137)

The autoscaling config example uses:
```python
"target_num_ongoing_requests_per_replica": 5,
```

In Ray 2.32+, this was renamed to `target_ongoing_requests`. The old name may still work as a deprecated alias but will eventually be removed.

**Severity: MEDIUM** — still functional but deprecated.

### ✅ `ActorPoolStrategy(min_size, max_size)` (Line 220)

Correctly uses `min_size=2, max_size=8` — matches current Ray 2.54 API. Both `size` (fixed) and `min_size`/`max_size` (autoscaling) forms are valid.

### ✅ Ray Serve `num_replicas="auto"` (Line 133)

Correct — `"auto"` enables autoscaling and is the recommended pattern.

### ✅ KubeRay CRD `apiVersion: ray.io/v1` (Line 262)

Correct — `ray.io/v1` is the current stable API version.

### ℹ️ KubeRay example pinned to Ray 2.9.0 (Lines 269, 278, 291)

Acceptable as an illustrative example, but Ray 2.9 is old. Users on Ray 2.11–2.37 may hit KubeRay health check bugs. Consider noting this is illustrative.

### Missing Gotchas

1. **LLM serving patterns** — Ray Serve is now heavily used for LLM inference (vLLM, TGI integration). No mention of streaming SSE responses or LLM-specific batching.
2. **V2 autoscaler** — Ray's new-generation autoscaler (default in recent versions) is not mentioned.
3. **`max_ongoing_requests` default change** — Default changed from 100 to 5 in Ray 2.32+; this is a breaking behavioral change worth noting.
4. **`ray.data` lazy execution caveats** — No mention of `materialize()` for forcing execution or debugging lazy pipelines.

---

## c. Trigger Check

### Positive Triggers

| Trigger | Specific to Ray? | Risk |
|---------|-----------------|------|
| `"ray"` | ⚠️ Ambiguous | Could match "X-ray", "ray tracing", "stingray" in non-Ray contexts |
| `"ray.remote"`, `"ray.init"`, `"ray.put"`, `"ray.get"` | ✅ | API-specific |
| `"Ray Serve"`, `"Ray Tune"`, `"Ray Data"`, `"Ray Train"` | ✅ | Product-specific |
| `"KubeRay"`, `"RayCluster CRD"` | ✅ | Infra-specific |
| `"placement group"` | ⚠️ | AWS EC2 and K8s also have placement groups |
| `"ActorPoolStrategy"` | ✅ | Ray-specific class |

### Negative Triggers

Good exclusions for competing frameworks: Dask, PySpark, Celery, multiprocessing. The `"general ML without Ray"` and `"general Python parallelism"` are useful catch-alls.

### False Trigger Analysis

- **Dask/Spark/Celery:** Would NOT trigger — explicit negative triggers. ✅
- **General Python parallelism:** Would NOT trigger — negative trigger covers it. ✅
- **"ray tracing" in graphics code:** MIGHT trigger on bare `"ray"`. Low-medium risk.
- **AWS placement groups:** MIGHT trigger on `"placement group"`. Low risk.

**Recommendation:** Change `"ray"` to `"Ray framework"` or `"import ray"` for precision.

---

## d. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3.5/5 | `local_mode=True` error is a real bug; `target_num_ongoing_requests_per_replica` is deprecated |
| **Completeness** | 4/5 | Excellent breadth across Ray ecosystem; missing LLM serving, V2 autoscaler, recent API defaults |
| **Actionability** | 5/5 | Outstanding — production checklist, anti-patterns, comparison table, scripts, assets, examples |
| **Trigger quality** | 4/5 | Good positive/negative coverage; bare `"ray"` and `"placement group"` slightly too broad |
| **Overall** | **4.1/5** | Strong skill with fixable accuracy issues |

---

## e. Required Fixes

1. **Remove `local_mode=True`** from Production Checklist (line 369). Replace with: "Use Ray Distributed Debugger (`ray debug`) for debugging serialization issues"
2. **Update `target_num_ongoing_requests_per_replica`** to `target_ongoing_requests` in the Serve autoscaling example (line 137)
3. **Narrow `"ray"` trigger** to `"import ray"` or `"Ray framework"` to avoid false matches

## f. Suggested Improvements (non-blocking)

- Add LLM serving section or reference (vLLM + Ray Serve pattern)
- Note V2 autoscaler as default in recent Ray versions
- Add `globs:` patterns for file-based triggering
- Note `max_ongoing_requests` default change (100→5) in Ray 2.32+
- Add `materialize()` mention for Ray Data debugging

---

## f. GitHub Issues

**Not filed.** Overall score 4.1 ≥ 4.0 and no dimension ≤ 2.

---

## g. Status

**`needs-fix`** — Two accuracy issues must be corrected before production use.
