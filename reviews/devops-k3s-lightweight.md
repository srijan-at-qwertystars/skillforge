# QA Review: k3s-lightweight

**Skill path:** `devops/k3s-lightweight/`
**Reviewed:** 2025-07-17
**Reviewer:** Copilot QA

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with +/- triggers present |
| Under 500 lines | ✅ Pass | 497 lines (just under limit) |
| Imperative voice | ✅ Pass | Consistent imperative throughout ("Create…", "Place…", "Check…") |
| Examples | ✅ Pass | Copy-pasteable bash/YAML blocks for every section |
| References linked | ✅ Pass | 3 reference docs, 3 scripts, 5 asset templates — all files exist |

**Supporting file inventory:**
- `references/`: ha-clustering.md (685L), troubleshooting.md (1007L), edge-deployment.md (967L)
- `scripts/`: install-k3s-ha.sh (312L), k3s-health-check.sh (465L), air-gap-prepare.sh (425L)
- `assets/`: k3s-config.yaml, registries.yaml, traefik-values.yaml, helmchart-example.yaml, system-upgrade-plan.yaml

---

## B. Content Check

### Verified Correct ✅
- **Install command:** `curl -sfL https://get.k3s.io | sh -` — matches official docs
- **Config paths:** `/etc/rancher/k3s/config.yaml`, `/etc/rancher/k3s/k3s.yaml`, `/var/lib/rancher/k3s/server/manifests/`, `/var/lib/rancher/k3s/agent/images/` — all correct per docs.k3s.io
- **Air-gap steps:** Binary → images dir → `INSTALL_K3S_SKIP_DOWNLOAD=true` — verified against k3s-io/docs
- **`k3s secrets-encrypt rotate-keys`:** Correct syntax; restart instruction is accurate
- **Encryption config path:** `/var/lib/rancher/k3s/server/cred/encryption-config.json` — confirmed
- **HA embedded etcd:** `--cluster-init` on first server, `--server` on subsequent — correct
- **External DB endpoints:** Postgres and MySQL connection string formats correct
- **Flannel backends:** `vxlan`, `host-gw`, `wireguard-native`, `none` — accurate
- **ServiceLB limitations:** "No failover across nodes" — verified (HostPort-bound, no VIP)
- **Uninstall scripts:** `/usr/local/bin/k3s-uninstall.sh` and `k3s-agent-uninstall.sh` — correct

### Missing Gotchas ⚠️
1. **Firewall ports not documented:** K3s requires TCP 6443, UDP 8472 (Flannel VXLAN), TCP 10250 (kubelet metrics), plus UDP 51820/51821 for WireGuard backend. This is a common deployment blocker.
2. **KUBECONFIG for non-root users:** Skill only shows `sudo cat` of kubeconfig but doesn't cover `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` or copying to `~/.kube/config` — a frequent first-use friction point.
3. **SELinux considerations:** No mention of `k3s-selinux` RPM needed on RHEL/CentOS/Fedora.
4. **Systemd service file paths:** `/etc/systemd/system/k3s.service` and `.env` file not mentioned — useful for debugging.

---

## C. Trigger Check

| Trigger | Assessment |
|---------|------------|
| **Positive: "K3s"** | ✅ Precise, unambiguous |
| **Positive: "lightweight Kubernetes"** | ⚠️ Could match MicroK8s/K0s, but negative triggers mitigate |
| **Positive: "edge Kubernetes"** | ⚠️ Slightly broad; negatives help |
| **Positive: "K3s cluster/installation/HA/air-gap/HelmChart/upgrade"** | ✅ K3s-specific |
| **Positive: "Rancher K3s"** | ✅ Precise |
| **Negative: "kubeadm", "kops"** | ✅ Correctly excludes full K8s |
| **Negative: "EKS", "GKE", "AKS"** | ✅ Correctly excludes managed cloud |
| **Negative: "K0s", "MicroK8s"** | ✅ Correctly excludes competing lightweight distros |
| **Negative: "general Kubernetes without K3s context"** | ⚠️ Fuzzy — depends on matching implementation |

**False-trigger risk:** Low. The "lightweight Kubernetes" and "edge Kubernetes" positives are slightly broad, but the negative list is comprehensive enough to prevent false activation for MicroK8s, K0s, or upstream K8s scenarios.

**Miss risk:** Low. All common K3s-related queries are covered by positive triggers.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 / 5 | All commands, paths, configs, and syntax verified against official K3s docs and web sources. Zero errors found. |
| **Completeness** | 4 / 5 | Excellent coverage of install, HA, networking, storage, Helm, security, upgrades, edge, and troubleshooting. Supporting refs/scripts/assets are thorough. Docked for missing firewall ports, KUBECONFIG setup, and SELinux notes. |
| **Actionability** | 5 / 5 | Every section has copy-pasteable commands and YAML. Troubleshooting section is practical. Scripts are production-ready with pre-flight checks. |
| **Trigger quality** | 4 / 5 | Strong K3s-specific positives with good negative exclusions. Minor fuzziness on "lightweight/edge Kubernetes" and the natural-language negative trigger. |

**Overall: 4.5 / 5**

---

## E. Recommendations

1. **Add firewall ports section** — document TCP 6443, UDP 8472, TCP 10250 (and WireGuard ports) in a "Prerequisites" or "Networking" subsection.
2. **Add KUBECONFIG setup snippet** — show `export KUBECONFIG` or `cp` to `~/.kube/config` for non-root users.
3. **Add SELinux note** — brief mention of `k3s-selinux` RPM for RHEL-family distros.
4. **Tighten trigger** — consider changing "lightweight Kubernetes" → "K3s lightweight Kubernetes" for precision.

---

## F. GitHub Issue

**Not required.** Overall score 4.5 ≥ 4.0 and no dimension ≤ 2.

---

## G. Verdict

**PASS** — Skill is accurate, comprehensive, and actionable. Minor additions recommended but not blocking.
