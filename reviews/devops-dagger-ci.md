# Review: dagger-ci

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5

## Issues

### 1. Outdated GitHub Action version (Accuracy)
- SKILL.md and assets reference `dagger/dagger-for-github@v7` throughout
- The current latest major version is **v8** (v8.4.1 as of review date)
- Affected files: SKILL.md (lines 278, 35-39 in assets/github-actions-dagger.yml), ci-integration-setup.sh (line 71), references/migration-guide.md
- Impact: Engineers copying examples will use a stale action version
- Fix: Update all references from `@v7` to `@v8`

### 2. `dag.Host().Directory()` pattern in references (Accuracy, minor)
- `references/troubleshooting.md` uses `dag.Host().Directory(".", ...)` in multiple cache/context examples
- The main SKILL.md correctly teaches the newer pattern of passing directories as function arguments (`--src=.`)
- These two approaches are inconsistent; the `dag.Host()` pattern is legacy (pre-0.12) and may confuse users
- Fix: Update troubleshooting examples to use function-argument pattern or add a note about the difference

### 3. SKILL.md at exactly 500 lines (Structure, borderline)
- The body is exactly 500 lines, right at the "under 500 lines" threshold
- Not a blocker but worth noting for future edits — any additions will push it over

### 4. Missing coverage of newer CLI commands (Completeness, minor)
- No mention of `dagger shell` (interactive module exploration) or `dagger watch` (file-watching mode)
- No coverage of custom object constructors (`New` pattern in Go, `__init__` in Python)
- No mention of `// +default` doc comment annotations beyond `// +optional`

## Strengths

- **Excellent SDK coverage**: Go, Python, and TypeScript examples are all correct with proper idiomatic conventions (snake_case for Python, camelCase for TypeScript, PascalCase for Go)
- **Container API accuracy**: All method names verified correct — `From/from_/from`, `WithExec/with_exec/withExec`, `WithMountedCache/with_mounted_cache/withMountedCache`, `CacheVolume/cache_volume/cacheVolume`, etc.
- **CLI commands correct**: `dagger call`, `dagger init --sdk=`, `dagger develop`, `dagger functions`, `dagger install` — all verified
- **dagger.json format correct**: `name`, `sdk`, `engineVersion` fields properly documented
- **Secret handling patterns**: `env:`, `file:`, `cmd:` prefixes for `--token` args are correct
- **Comprehensive assets**: Both Go and Python modules are well-structured, runnable, and demonstrate real-world patterns (errgroup parallelism, distroless images, ruff linting)
- **Scripts are functional**: init, lint, and CI integration scripts are well-documented with proper error handling
- **Trigger description is thorough**: Covers 10+ positive triggers and 5 negative triggers — specific enough to avoid false positives while catching real queries
- **Migration tables**: GitHub Actions → Dagger concept mapping is excellent for onboarding
- **References are deep**: Advanced patterns (multi-arch, matrix, service deps, module composition), troubleshooting, and migration guide cover real-world scenarios thoroughly
