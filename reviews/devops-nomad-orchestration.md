# Review: nomad-orchestration

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **Workload Identity version mismatch (SKILL.md line 326)**: States "Workload Identity (v1.10+)" but the feature was introduced in Nomad v1.7. The `assets/nomad-server.hcl` correctly notes "(v1.7+)" on its own line 117, creating an internal inconsistency. Suggest changing to "(v1.7+)" in SKILL.md to match both the asset file and official HashiCorp documentation.

2. **Minor: nomad-server.hcl `ca_path` vs `ca_file` for Vault** (line 114): Uses `ca_path` (directory of CA certs) rather than `ca_file` (single CA cert). Both are valid Nomad config options, but `ca_file` is more common in examples and documentation. Not an error, but worth noting for consistency with the TLS block which uses `ca_file`.

## Detailed Assessment

### a. Structure check — PASS
- YAML frontmatter has `name` and `description` ✅
- Description includes positive triggers ("TRIGGER when") AND negative triggers ("DO NOT TRIGGER when") ✅
- Body is 483 lines (under 500 limit) ✅
- Imperative voice throughout, no filler ✅
- Extensive examples with HCL input and CLI commands ✅
- `references/` (3 files) and `scripts/` (3 files) properly linked from SKILL.md with relative paths ✅
- `assets/` (5 files) also linked and described ✅

### b. Content check — STRONG
- Architecture description (servers, clients, regions, datacenters, data flow) is accurate ✅
- Job hierarchy (job → group → task) and all four job types correct ✅
- HCL syntax in all examples is valid ✅
- CLI commands (`nomad job plan`, `nomad job run -check-index`, `nomad deployment promote`, `nomad acl bootstrap`, etc.) are correct ✅
- Dynamic Host Volumes correctly attributed to v1.10+ ✅
- Consul Connect / service mesh integration accurately described ✅
- CSI plugin architecture (controller + node) correct ✅
- Canary/blue-green deployment pattern (canary = count) is correct ✅
- Autoscaler configuration and scaling block syntax correct ✅
- Anti-patterns section covers real-world gotchas engineers would hit ✅
- Troubleshooting reference covers all major failure modes (placement, OOM, networking, Raft) ✅
- Security hardening reference is comprehensive (ACLs, mTLS, gossip, Sentinel, namespaces, task security) ✅
- Scripts are well-structured, handle edge cases, and would work in production ✅
- Latest Nomad version is v1.11.3; skill targets v1.10+ which is reasonable ✅
- One inaccuracy: Workload Identity version (see issue #1 above)

### c. Trigger check — STRONG
- Would trigger for "deploy a service to Nomad" ✅ (matches "deploys containers or non-containerized workloads via Nomad")
- Would trigger for "configure Nomad cluster" ✅ (matches "configures Nomad servers/clients")
- Would trigger for "write a Nomad job spec" ✅ (matches "writes Nomad job specs (HCL)")
- Would trigger for "set up Nomad with Consul" ✅ (matches "integrates Nomad with Consul or Vault")
- Would NOT falsely trigger for K8s/Docker Compose/ECS ✅ (explicit exclusions)
- Would NOT falsely trigger for standalone Consul/Vault ✅ (explicitly excluded)
- Keywords list is comprehensive and covers common query terms ✅

### d. Scores

| Dimension | Score | Notes |
|-----------|-------|-------|
| Accuracy | 4/5 | One version misattribution (Workload Identity v1.10+ → should be v1.7+); all other facts, HCL syntax, CLI commands verified correct |
| Completeness | 5/5 | Covers architecture, job specs, all job types, task drivers, networking, storage (host + CSI), deployments (rolling/canary/blue-green), autoscaling, Vault, ACLs, federation, monitoring, anti-patterns. References add troubleshooting, security hardening, and advanced patterns. Assets provide 5 production-ready templates. |
| Actionability | 5/5 | An AI can execute any Nomad task from this skill alone. Ready-to-use templates, validation/deploy/health scripts, step-by-step troubleshooting. |
| Trigger quality | 5/5 | Description is detailed with specific positive/negative triggers and keyword list. Precise boundary conditions prevent false triggers. |
| **Overall** | **4.8/5** | |

### Verdict: PASS

The skill is production-quality. The single version inaccuracy is minor and does not affect usability. No GitHub issues required (overall ≥ 4.0 and no dimension ≤ 2).
