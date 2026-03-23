# QA Review: devops/argocd-gitops

**Reviewer**: Copilot CLI (automated)
**Date**: 2025-07-17
**Skill path**: `devops/argocd-gitops/`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `argocd-gitops` |
| YAML frontmatter `description` | ✅ Pass | Comprehensive, multi-line |
| Positive triggers | ✅ Pass | 15+ specific use cases (Application, ApplicationSet, AppProject, sync policies, hooks, RBAC, SSO, notifications, multi-cluster, Helm/Kustomize, health checks, secrets, CLI, HA, DR) |
| Negative triggers | ✅ Pass | Explicitly excludes Argo Workflows, Argo Events, Argo Rollouts, Flux CD, generic K8s manifests, CI tools, container builds |
| Body under 500 lines | ✅ Pass | 480 lines |
| Imperative voice, no filler | ✅ Pass | Terse, direct language throughout |
| Examples with input/output | ✅ Pass | 3 input/output examples at end (OCI Helm chart, ApplicationSet cluster generator, PreSync migration Job) |
| `references/` linked | ✅ Pass | Table links 3 guides: advanced-patterns.md, troubleshooting.md, security-guide.md |
| `scripts/` linked | ✅ Pass | Table links 3 scripts: install-argocd.sh, backup-restore.sh, app-health-check.sh |
| `assets/` linked | ✅ Pass | Table links 4 templates: application.yaml, applicationset.yaml, project.yaml, argocd-values.yaml |

---

## b. Content Check (verified via web search)

### CRD Accuracy
- ✅ `apiVersion: argoproj.io/v1alpha1` for Application, ApplicationSet, AppProject — correct per current stable
- ✅ Application spec fields (`project`, `source`, `destination`, `syncPolicy`, `ignoreDifferences`, `revisionHistoryLimit`) — all accurate
- ✅ ApplicationSet `goTemplate: true` + `goTemplateOptions: ["missingkey=error"]` in assets — correct, recommended best practice
- ✅ AppProject spec fields (`sourceRepos`, `destinations`, `clusterResourceWhitelist`, `namespaceResourceBlacklist`, `roles`, `syncWindows`, `orphanedResources`, `signatureKeys`, `destinationServiceAccounts`) — all accurate
- ⚠️ **Minor**: SKILL.md health check key `certmanager.io_Certificate` (line 255) should be `cert-manager.io_Certificate` (missing hyphen). The argocd-values.yaml asset has it correct.

### CLI Command Accuracy
- ✅ `argocd login`, `argocd app create/sync/get/diff/history/rollback/delete/wait` — all correct
- ✅ `argocd repo list/add` — correct
- ✅ `argocd cluster add/list/rm` — correct
- ✅ `argocd proj create` — correct

### Sync Strategies & Policies
- ✅ Manual / Auto / Self-heal / Prune / Selective — all accurately described
- ✅ `retry` with `backoff` fields (duration, factor, maxDuration) — correct
- ✅ `syncOptions` list values (CreateNamespace, PrunePropagationPolicy, PruneLast, ServerSideApply, ApplyOutOfSyncOnly, RespectIgnoreDifferences, Replace, FailOnSharedResource) — all valid

### ApplicationSet Generator Syntax
- ✅ Git Directory/File, List, Cluster, Matrix, Merge, Pull Request generators — all syntactically correct
- ✅ Template variables (`path.basename`, `path.path`, `name`, `server`, `number`, `head_sha`) — correct
- ⚠️ **Minor**: SKILL.md examples use old template syntax `{{path.basename}}` (non-Go-template). Assets correctly use `{{ .path.basename }}` with `goTemplate: true`. Both syntaxes are valid but Go templates are now recommended.
- ✅ `templatePatch` (v2.8+) documented in assets — correct
- ✅ `strategy` field with RollingSync documented in assets — correct

### RBAC Policy Format
- ✅ Casbin `p, <subject>, <resource>, <action>, <object>, <effect>` — correct
- ✅ Group mapping `g, <group>, <role>` — correct
- ✅ Resources list (applications, clusters, repositories, certificates, accounts, gpgkeys, logs, exec) — correct
- ✅ Project-scoped roles format `proj:<project>:<role>` — correct
- ✅ JWT token generation with `argocd proj role create-token` — correct

### SSO/OIDC Configuration
- ✅ `oidc.config` in `argocd-cm` — correct
- ✅ `requestedScopes` and `requestedIDTokenClaims` — correct
- ✅ Secret reference with `$oidc.okta.clientSecret` pattern — correct
- ✅ Dex connector config — correct
- ✅ Azure AD and Okta examples in security-guide.md — accurate

### Missing Gotchas
- ⚠️ Helm pre-install/pre-upgrade hooks run on every Argo CD sync (not just first install). This is a common surprise not mentioned in the skill.
- ⚠️ `PostDelete` hook phase (v2.10+) is covered in advanced-patterns.md but not in SKILL.md main hook phases list. Acceptable since referenced.
- ⚠️ Multi-source apps (`sources`) are only in the asset template comment, not in SKILL.md body. Minor gap since it's a common feature (v2.6+).

---

## c. Trigger Check

| Question | Assessment |
|----------|------------|
| Is the description pushy enough? | ✅ Yes — 15+ positive trigger scenarios explicitly listed |
| Would it falsely trigger for Argo Workflows? | ✅ No — explicitly excluded: "DO NOT use for Argo Workflows, Argo Events, Argo Rollouts" |
| Would it falsely trigger for Flux CD? | ✅ No — explicitly excluded |
| Would it falsely trigger for generic K8s? | ✅ No — requires "Argo CD context" |
| Would it falsely trigger for CI/CD? | ✅ No — Jenkins, GitHub Actions excluded |

The negative triggers are precise and cover all likely confusion points with sibling Argo projects.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | One typo (`certmanager.io` → `cert-manager.io`). Old-style ApplicationSet template syntax in SKILL.md (valid but not best practice). All other content verified correct against official docs. |
| **Completeness** | 5 | Exceptionally thorough. Covers CRDs, sync policies, hooks, generators, RBAC, SSO/OIDC, secrets (4 methods), multi-cluster, health checks, notifications, DR, CLI, network policies, audit logging, supply chain security, CMP plugins, repo structures. 3 reference guides, 3 scripts, 4 asset templates. |
| **Actionability** | 5 | Every section has copy-paste YAML/bash. Scripts have proper arg parsing, dry-run, error handling. Asset templates are heavily commented. Helm values file covers production deployment end-to-end. Input/output examples included. |
| **Trigger quality** | 5 | Specific positive triggers, explicit negative triggers for all related products. No false-positive risk. |

### **Overall: 4.75 / 5 — PASS**

---

## e. GitHub Issues

No issues filed. Overall ≥ 4.0 and no dimension ≤ 2.

---

## f. Recommended Fixes (non-blocking)

1. **Fix health check key typo** in SKILL.md line 255: `certmanager.io_Certificate` → `cert-manager.io_Certificate`
2. **Consider updating** SKILL.md ApplicationSet examples to use Go template syntax (`{{ .path.basename }}` with `goTemplate: true`) since this is now recommended.
3. **Consider adding** a note that Helm pre-install/pre-upgrade hooks run on every Argo CD sync.
4. **Consider mentioning** multi-source apps (`sources` field, v2.6+) in the SKILL.md body.
