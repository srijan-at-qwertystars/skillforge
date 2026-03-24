# Review: packer-images

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **Variable precedence order is incorrect (line 212):** The skill lists `-var` before `PKR_VAR_*` env vars, but the actual Packer precedence (lowest → highest) is: defaults → `.auto.pkrvars.hcl` → `-var-file` → `PKR_VAR_*` → `-var`. The skill has the last two swapped, making it appear that env vars override CLI `-var` flags when the opposite is true.

2. **`packer plugins required .` is not a valid command (line 237):** There is no `packer plugins required` subcommand in the Packer CLI. To inspect required plugins, users should check the `required_plugins` block in HCL files or list installed binaries in `~/.config/packer/plugins`. Consider replacing with `packer plugins installed` (v1.10+) or removing.

## Structure Check
- **YAML frontmatter:** ✅ Has `name` and `description` fields
- **Trigger description:** ✅ Clear positive triggers (builders, provisioners, HCL2, HCP Packer, etc.) AND negative triggers (Terraform-only, Docker Compose, Ansible-only, Vagrant-only)
- **Body length:** ✅ 498 lines (under 500 limit)
- **Imperative voice:** ✅ Consistently uses imperative ("Use", "Set", "Pin", "Bake", etc.)
- **Examples with I/O:** ✅ Final section has prompt→output example (multi-cloud golden image)
- **Resources linked:** ✅ References table (3 docs), scripts table (3 scripts), assets table (5 templates) — all properly described

## Content Check (web-verified)
- **CLI commands:** ✅ `packer init`, `build`, `validate`, `fmt`, `inspect`, `console` all verified correct
- **HCL2 syntax:** ✅ Source/build/variable blocks, `required_plugins`, locals, data sources all syntactically correct
- **Builder APIs:** ✅ amazon-ebs, docker, azure-arm, googlecompute, vmware-iso, vagrant — field names and usage verified
- **Provisioner syntax:** ✅ shell (inline, script, execute_command, environment_vars), file, ansible, powershell, puppet/chef all correct
- **HCP Packer API:** ✅ `hcp_packer_artifact` data source with `bucket_name`, `channel_name`, `platform`, `region` matches current Terraform HCP provider docs
- **CIS hardening:** ✅ `ansible-lockdown/UBUNTU22-CIS` confirmed as correct role name; `dev-sec/linux-hardening` is valid; sysctl and SSH checks in scan script align with CIS benchmark items
- **spot_price / spot_instance_types:** ✅ Verified current amazon-ebs builder syntax

## Trigger Check
- **Packer queries:** ✅ Would trigger — comprehensive coverage of `.pkr.hcl` files, builders, provisioners, post-processors, HCP, CLI, hardening
- **Docker-only:** ✅ Would NOT trigger — "Docker Compose" explicitly excluded; Docker builder is Packer-contextualized
- **Terraform-only:** ✅ Would NOT trigger — "Terraform-only IaC without image building" explicitly excluded
- **Ansible-only:** ✅ Would NOT trigger — "Ansible playbooks without Packer" explicitly excluded

## Strengths
- Exceptionally thorough coverage of the Packer ecosystem
- Production-ready assets with spot pricing, encrypted EBS, error-cleanup-provisioner
- Well-structured scripts with proper error handling, cleanup traps, and dry-run support
- CI/CD workflow covers the full validate→build→scan→promote pipeline
- CIS scan script is genuinely useful and operationally sound
- Reference docs cover advanced patterns, security, and troubleshooting comprehensively
