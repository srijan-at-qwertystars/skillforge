# QA Review: ansible-automation

**Skill path:** `~/skillforge/devops/ansible-automation/`
**Reviewed:** 2026-03-24T01:41:49Z
**Verdict:** PASS

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `ansible-automation` |
| YAML frontmatter `description` | ✅ | Present, multi-line |
| Positive triggers | ✅ | 20+ trigger phrases (playbooks, roles, Vault, Molecule, etc.) |
| Negative triggers | ✅ | Excludes Terraform, Pulumi, OpenTofu, Chef, Puppet, Nomad, K8s |
| Body under 500 lines | ✅ | 424 lines |
| Imperative voice, no filler | ✅ | Dense, direct, zero fluff |
| Input/output examples | ✅ | Docker install + Molecule test with full YAML |
| references/ linked | ✅ | 3 files linked in table with topic summaries |
| scripts/ linked | ✅ | 3 scripts linked with usage examples |
| assets/ linked | ✅ | 5 assets linked with descriptions |

**Structure score: Excellent.** Clean layout, good use of tables, progressive disclosure via references.

---

## B. Content Check

### Accurate claims
- Agentless architecture, SSH/WinRM transports — ✅ correct
- Inventory patterns (INI, YAML, dynamic plugins) — ✅ correct
- FQCN enforcement — ✅ correct and well-emphasized
- Vault commands and multi-vault with `--vault-id` — ✅ correct
- block/rescue/always semantics — ✅ correct
- async/poll pattern — ✅ correct
- `ansible.cfg` performance settings (pipelining, fact caching, forks) — ✅ correct
- Role structure and Galaxy commands — ✅ correct

### Inaccuracies found

1. **`ansible.builtin.apt_key` is deprecated** (Docker example, line 378). Deprecated since Ansible 2.15; `apt-key` removed from Ubuntu 24.04+/Debian 13+. Modern approach: `ansible.builtin.get_url` to download GPG key to `/etc/apt/keyrings/` + `ansible.builtin.apt_repository` with `signed-by`, or use `ansible.builtin.deb822_repository`.

2. **Variable precedence claims "15 levels"** (line 160) but official Ansible docs list 21 levels. The condensed list omits: `vars_prompt`, role params, include params, inventory file/script host vars. Misleading count.

3. **`molecule-docker` is legacy** (line 260). Modern install: `pip install molecule molecule-plugins[docker]`. The `molecule-docker` package is effectively superseded.

4. **`ansible.builtin.yum` listed without deprecation note** (module table, line 98). `yum` module deprecated as of Ansible 2.17; redirects to `dnf` internally. Should note this or recommend `ansible.builtin.dnf`/`ansible.builtin.package`.

### Missing gotchas

- No mention of `ansible.builtin.package` (cross-platform package module)
- No `ansible.cfg` search order (current dir → `ANSIBLE_CONFIG` env → `~/.ansible.cfg` → `/etc/ansible/ansible.cfg`)
- Missing `ansible.builtin.deb822_repository` — the modern replacement for apt_key + apt_repository
- No mention of `collections_path` vs `collections_paths` config key confusion
- SaltStack not listed as negative trigger (minor)

### Scripts quality
- `ansible-init.sh` — ✅ Well-structured, `set -euo pipefail`, creates complete project scaffold
- `role-init.sh` — ✅ Good Molecule scaffold, argument parsing, error handling
- `vault-helper.sh` — ✅ Comprehensive vault wrapper with colored output and safety checks

### Assets quality
- `ansible.cfg` — ✅ Production-grade with Automation Hub config
- `playbook-template.yml` — ✅ Excellent: pre_tasks, block/rescue/always, health checks, rollback
- `inventory-template.yml` — ✅ Comprehensive multi-env example with companion file docs
- `docker-compose.yml` — ✅ Functional dev environment with 3 managed node distros
- `role-template/` — ✅ Complete skeleton with OS-specific var loading

### References quality
- `advanced-patterns.md` (963 lines) — Custom modules, plugins, collections dev, execution environments
- `troubleshooting.md` (893 lines) — 15 problem categories with diagnosis steps
- `security-hardening.md` (1012 lines) — Vault, CIS benchmarks, compliance-as-code

All three are substantial and well-organized.

---

## C. Trigger Check

**Would it trigger for real Ansible queries?** — Yes. The description covers playbooks, roles, inventory, Vault, Molecule, Galaxy, handlers, delegation, async, facts, variable precedence, block/rescue, ansible.cfg, pipelining, Mitogen, check/diff mode, and debugging. This is comprehensive.

**Would it falsely trigger for Terraform?** — No. Explicit exclusion: "Do NOT trigger for Terraform/Pulumi/OpenTofu."

**Would it falsely trigger for Puppet/Chef?** — No. Explicit exclusion.

**Would it falsely trigger for SSH scripting?** — No. Excludes "general SSH/shell scripting unrelated to Ansible."

**Edge cases:** Could potentially miss Ansible Lightspeed or Ansible Navigator queries (only Navigator is in references, not in trigger description). Could also add Event-Driven Ansible (EDA) as a trigger.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3 | Deprecated `apt_key` in example, wrong variable precedence count, outdated `molecule-docker`, undisclosed `yum` deprecation |
| **Completeness** | 4 | Excellent breadth across Ansible topics; minor gaps (`package` module, `deb822_repository`, config search order) |
| **Actionability** | 4 | Examples are clear and near-runnable; scripts are production-ready; an AI could execute most tasks successfully with caveats on deprecated modules |
| **Trigger quality** | 5 | Outstanding trigger description — broad positive coverage, precise negative exclusions, no false-positive risk |

**Overall: 4.0 / 5.0**

---

## E. Issues

No GitHub issues filed. Overall = 4.0 (not < 4.0) and no dimension ≤ 2.

### Recommended improvements (non-blocking)

1. Replace `ansible.builtin.apt_key` in Docker example with `get_url` + `apt_repository` using `signed-by`
2. Fix variable precedence count (21 levels, not 15) or drop the number
3. Update Molecule install to `molecule-plugins[docker]`
4. Add deprecation note to `ansible.builtin.yum` in module table; add `ansible.builtin.package`
5. Add `ansible.builtin.deb822_repository` to modules table
6. Add Event-Driven Ansible (EDA) and Ansible Lightspeed to trigger list

---

## F. Test Status

**PASS** — Skill is well-structured, comprehensive, and actionable. Accuracy issues are non-blocking (deprecated modules still function) but should be addressed in a future revision.
