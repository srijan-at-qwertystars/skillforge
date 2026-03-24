# Review: helm-charts

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **Values override hierarchy is wrong (lines 224-228).** The skill lists:
   1. Parent chart's `values.yaml`
   2. Subchart's `values.yaml`

   Correct order (lowest to highest) per Helm docs is:
   1. Subchart's `values.yaml` (defaults)
   2. Parent chart's `values.yaml` (overrides subchart defaults)

   Items 1 and 2 are swapped. Additionally, `--set-json` is listed as a separate tier (#5) above `--set` (#4), but they share the same precedence level — they're interleaved by command-line order, not layered.

2. **Missing `--reuse-values` vs `--reset-values` gotcha.** This is one of the most common pitfalls engineers hit. `--reuse-values` on `helm upgrade` silently merges old values, which can mask removed keys. `--reset-values` drops all prior values. Neither is mentioned in SKILL.md or troubleshooting.md.

## Structure Check

- ✅ YAML frontmatter has `name` and `description`
- ✅ Positive triggers: 23 keywords (helm chart, helm install, helm upgrade, etc.)
- ✅ Negative triggers: Kustomize, plain K8s YAML, Docker Compose, Skaffold, Terraform, Pulumi, generic Go templates
- ✅ Body: 465 lines (under 500 limit)
- ✅ Imperative voice throughout, no filler
- ✅ Examples with correct YAML/bash input throughout; template function table includes purpose + example
- ✅ `references/` linked with relative paths in table at bottom: advanced-patterns.md, troubleshooting.md, template-functions.md
- ✅ `scripts/` linked with relative paths in table: create-chart.sh, lint-chart.sh, publish-chart.sh
- ✅ `assets/` linked: _helpers.tpl, ci-pipeline.yaml, values-schema.json

## Content Check

- All Helm CLI commands verified correct: `helm install`, `upgrade --install`, `template`, `lint --strict`, `rollback`, `uninstall`, `package`, `push`, `registry login`, `repo add/update/index`, `show values`, `get values -a`, `history`, `dependency update/build`, `test`, `plugin install`, `diff upgrade`, `create`
- Template functions verified correct: `toYaml`, `nindent`, `indent`, `include` vs `template`, `required`, `tpl`, `lookup`, `default`, `quote`, `printf`, `trimSuffix`, `b64enc`, `sha256sum`, `ternary`
- `ternary` pipeline usage (`condition | ternary trueVal falseVal`) is correct
- Hook types and delete policies are accurate and complete
- Chart.yaml `apiVersion: v2`, dependency fields, condition/tags/alias/import-values all correct
- OCI registry workflow (login → package → push → install) is correct
- `kubeconform` usage and flags are current
- Troubleshooting guide (708 lines) is thorough: covers failed/stuck/pending releases, rollback edge cases, hook failures, template errors, dependency issues, OCI problems, upgrade conflicts, RBAC, resource conflicts, performance
- Template functions reference (746 lines) is comprehensive: Go template basics, all Sprig categories, Helm builtins, common idioms
- Advanced patterns (1027 lines) covers library charts, umbrella charts, CRD management, operators, multi-cluster, GitOps (ArgoCD/Flux), testing strategies, Helm SDK, advanced templating
- Scripts are production-quality with proper error handling, color output, and graceful degradation when tools are missing
- Assets provide ready-to-copy templates with security hardening defaults

## Trigger Check

- Description is aggressive enough — 23 specific trigger phrases cover the full Helm surface area
- Negative triggers explicitly exclude Kustomize, plain K8s YAML, kubectl-only, Docker Compose, Skaffold, Terraform, Pulumi, and generic Go templates
- False trigger risk is low: "helm" combined with chart/install/upgrade/template keywords is unambiguous
- Edge case: "Go template" queries could match if in "Kubernetes context" qualifier — this is correctly handled by the negative trigger carve-out
