# Review: argocd-gitops

Accuracy: 5/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5
Issues: [minor, listed below]

---

## a. Structure Check — PASS

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter (name+description) | ✅ | Lines 1-12: `name: argocd-gitops`, multi-line `description` |
| Positive triggers | ✅ | ArgoCD, Argo CD, GitOps, ArgoCD Application, ApplicationSet, ArgoCD sync, argocd app create, GitOps deployment |
| Negative triggers | ✅ | FluxCD, Jenkins CD, Spinnaker, manual kubectl apply, Helm-only deployments without GitOps |
| Under 500 lines (SKILL.md) | ✅ | 465 lines |
| Imperative voice | ✅ | "Install ArgoCD", "Register and label external clusters", "Configure argocd-notifications-cm" |
| Examples | ✅ | 3 full input→output examples (Helm Application, cluster ApplicationSet, PreSync hook) at lines 377-445 |
| Links to references/scripts | ✅ | Lines 447-465 describe all 3 references, 5 scripts, 4 asset templates |

**Supporting files verified present:**
- `references/` — 3 files (advanced-patterns.md: 1310 lines, troubleshooting.md: 1122 lines, security-guide.md: 1448 lines). All have TOCs and comprehensive subsections.
- `scripts/` — 5 executable shell scripts (install, bootstrap, sync-check, health-check, backup-restore). All use `set -euo pipefail`, have usage headers, `--help`, `--dry-run`, proper argument parsing.
- `assets/` — 4 YAML templates (Application, ApplicationSet, AppProject, Helm values). All have inline comments with `CHANGEME` markers and docs links.

## b. Content Check — PASS (minor gaps)

### Verified Correct via Web Search & Official Docs

| Item | Status | Notes |
|------|--------|-------|
| Application CRD `apiVersion: argoproj.io/v1alpha1` | ✅ | Correct |
| `spec.source` fields (repoURL, path, targetRevision, helm, kustomize) | ✅ | All valid |
| `spec.destination` fields (server, namespace) | ✅ | Correct |
| `syncPolicy.automated.prune` / `selfHeal` | ✅ | Verified against official docs |
| `syncOptions` (CreateNamespace, ApplyOutOfSyncOnly, ServerSideApply, PrunePropagationPolicy, PruneLast, RespectIgnoreDifferences, Replace, FailOnSharedResource) | ✅ | All valid options |
| `syncPolicy.retry` with backoff | ✅ | Correct fields: limit, duration, factor, maxDuration |
| Hook phases: PreSync, Sync, PostSync, SyncFail, Skip | ✅ | Confirmed in official docs |
| Hook phases: PreDelete (v3.3+), PostDelete (v2.10+) | ✅ | Correct — newer additions, properly listed |
| Hook delete policies: HookSucceeded, HookFailed, BeforeHookCreation | ✅ | All three confirmed |
| Sync wave annotation `argocd.argoproj.io/sync-wave` | ✅ | Correct |
| Sync ordering: Phase → Wave → Kind → Name | ✅ | Correct |
| CLI: `argocd app sync --resource apps:Deployment:name` | ✅ | GROUP:KIND:NAME syntax verified |
| CLI: `argocd app create` flags | ✅ | --repo, --path, --dest-server, --dest-namespace, --sync-policy, --auto-prune, --self-heal all valid |
| CLI: `argocd cluster add`, `argocd cluster set --label` | ✅ | Correct |
| Multi-source Application (sources + ref) | ✅ | Correct syntax using `$values` ref |
| ApplicationSet generators (list, git directory, git file, cluster, matrix, merge) | ✅ | All verified |
| RBAC policy format `p, subject, resource, action, object, effect` | ✅ | Casbin syntax correct |
| OIDC config in argocd-cm | ✅ | Correct placement and field names |
| Notification annotations format | ✅ | `notifications.argoproj.io/subscribe.<trigger>.<service>` correct |
| Image Updater annotations | ✅ | Correct annotation keys and strategies |
| `ignoreDifferences` with jsonPointers and jqPathExpressions | ✅ | Both methods correct |
| Resource tracking methods (label, annotation, annotation+label) | ✅ | Correct |

### Minor Gaps (not errors)

1. **`automated.allowEmpty` not mentioned** — Prevents accidental deletion of all resources when Git source is temporarily empty. Useful safety guardrail.
2. **`automated.enabled` field not mentioned** — Newer explicit toggle (2024+). Omitting is fine since presence of `automated:` block implies enabled, but worth noting for completeness.
3. **Hooks don't execute on selective syncs** — Known gotcha that could surprise users. Not mentioned in SKILL.md main body.
4. **`Validate=false` syncOption** — Useful when deploying CRDs where schema validation isn't yet available. Not listed in the syncOptions examples.
5. **Sync windows** — Mentioned in the DO list but not explained in the SKILL.md main body. Covered in references/assets which is acceptable.

### Gotchas Coverage

The "Patterns and Anti-Patterns" section (lines 372-375) is solid. Covers:
- ✅ Separate config repos from app source
- ✅ Don't store secrets in plain Git (lists alternatives)
- ✅ Don't use Replace=true
- ✅ Don't put Application CRDs with workloads (circular sync)
- ✅ Don't disable pruning in prod
- ✅ Don't rely solely on polling
- ✅ Use ServerSideApply for large CRDs
- ✅ Use RespectIgnoreDifferences
- ✅ Pin targetRevision

## c. Trigger Check — PASS (minor risk)

### Would it trigger for ArgoCD queries?

| Query | Would Trigger? | Why |
|-------|---------------|-----|
| "Create an ArgoCD Application for my Helm chart" | ✅ Yes | Matches "ArgoCD Application", "ArgoCD" |
| "How do I set up ApplicationSet for multiple clusters?" | ✅ Yes | Matches "ApplicationSet" |
| "argocd app sync failing" | ✅ Yes | Matches "ArgoCD sync", "argocd app" |
| "GitOps deployment pipeline with ArgoCD" | ✅ Yes | Matches "GitOps deployment", "ArgoCD" |
| "Argo CD RBAC configuration" | ✅ Yes | Matches "Argo CD" |
| "How to configure ArgoCD notifications" | ✅ Yes | Matches "ArgoCD" |

### Would it false-trigger for non-ArgoCD?

| Query | Would Trigger? | Risk |
|-------|---------------|------|
| "Set up FluxCD for GitOps" | ❌ No | Negative trigger: "FluxCD" |
| "Jenkins CD pipeline" | ❌ No | Negative trigger: "Jenkins CD" |
| "Spinnaker deployment" | ❌ No | Negative trigger: "Spinnaker" |
| "Deploy with Helm without GitOps" | ❌ No | Negative trigger: "Helm-only deployments without GitOps" |
| "How to set up GitOps" (no ArgoCD mention) | ⚠️ Possible | "GitOps" alone is a positive trigger. Low risk — description scopes GitOps to ArgoCD context. |
| "Argo Workflows" | ⚠️ Possible | "Argo" prefix could match. Low risk — description is specific to "ArgoCD" not "Argo Workflows". |

**Recommendation:** Consider adding "Argo Workflows" and "Argo Events" to negative triggers to prevent false matches on other Argo projects.

## d. Score Justification

| Dimension | Score | Reasoning |
|-----------|-------|-----------|
| **Accuracy** | 5/5 | Every CRD field, CLI command, annotation, sync option, and hook phase verified correct against official ArgoCD docs. No errors found. |
| **Completeness** | 4/5 | Excellent breadth — covers Application, ApplicationSet (6 generators), sync strategies, hooks, multi-cluster, SSO/RBAC, notifications, App of Apps, Helm/Kustomize, diff customization, CI/CD, Image Updater. 3 deep-dive references (~3,880 lines combined), 5 operational scripts, 4 production templates. Minor gaps: `allowEmpty`, hooks-on-selective-sync gotcha, `Validate=false`. |
| **Actionability** | 5/5 | Copy-paste-ready YAML for every concept. Real CLI commands with correct flags. Operational scripts with `--dry-run`, `--help`, error handling. Asset templates with `CHANGEME` markers. Clear DO/DON'T list. |
| **Trigger quality** | 4/5 | Good positive triggers covering key terms. Explicit negative triggers for FluxCD/Jenkins/Spinnaker. Minor risk: bare "GitOps" or "Argo" could match unrelated queries. Missing negative triggers for Argo Workflows/Events. |

## e. Issue Filing Decision

- Overall: 4.5/5 — **≥ 4.0, no issue needed**
- No dimension ≤ 2 — **no issue needed**

## f. SKILL.md Annotation

Appended `<!-- tested: pass -->` to SKILL.md.
