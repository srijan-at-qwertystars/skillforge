# Review: ansible-playbooks

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues:
- `ansible.builtin.yum` annotated as `# RHEL 7-8` but RHEL 8 uses dnf natively; yum on RHEL 8 is a thin wrapper. Should read `# RHEL 7` for yum and `# RHEL 8+/Fedora` for dnf.
- Version claim "Current releases: ansible-core 2.17+ / Ansible 10+" is outdated; ansible-core is now at 2.20.x and the community package is at Ansible 12. Consider using "minimum supported" phrasing or updating periodically.
- Mitogen strategy (`mitogen_linear`) is mentioned without a compatibility caveat — it now requires the `serverscom.mitogen` collection for ansible-core 2.17+ and is not officially maintained by the Ansible project.

## Structure

- **Frontmatter**: ✅ YAML frontmatter with `name` and `description` present.
- **Trigger description**: ✅ Positive triggers (playbooks, roles, tasks, inventory, vault, molecule, AWX, Jinja2 for Ansible, etc.) AND negative triggers (Puppet/Chef/SaltStack, Terraform/Pulumi, shell-only, K8s-only, Docker Compose, CloudFormation, CDK).
- **Body length**: ✅ 485 lines (under 500 limit).
- **Imperative voice**: ✅ Consistent ("Define targets", "Prefer YAML", "Use dynamic inventory plugins", "Force mid-play handler execution").
- **Examples**: ✅ Extensive code examples in every section with correct YAML/Jinja2/INI/bash syntax. Examples show input configurations rather than input/output pairs, which is appropriate for declarative config management.
- **References linked**: ✅ All 3 references (`advanced-patterns.md`, `troubleshooting.md`, `playbook-recipes.md`) exist and are described with content summaries.
- **Scripts linked**: ✅ All 3 scripts (`scaffold-role.sh`, `ansible-lint-fix.sh`, `vault-helper.sh`) exist, are executable (`chmod +x`), and documented with usage/examples.
- **Assets**: ✅ All 6 assets exist and are production-quality templates.

## Content Accuracy (web-verified)

- ✅ 22 variable precedence levels — confirmed correct per official docs.
- ✅ Module FQCNs all valid (`ansible.builtin.apt`, `community.docker.docker_container`, `ansible.posix.synchronize`, etc.).
- ✅ Execution order (`pre_tasks → roles → tasks → post_tasks`) — correct.
- ✅ Dynamic inventory plugin FQCNs (`amazon.aws.aws_ec2`, `azure.azcollection.azure_rm`, `google.cloud.gcp_compute`) — correct.
- ✅ Vault commands and syntax — all correct.
- ✅ Molecule workflow (`lint → create → converge → idempotence → verify → destroy`) — correct.
- ✅ `ansible.cfg` options (`forks`, `pipelining`, `gathering`, `fact_caching`, `strategy`) — all valid.
- ⚠️ `ansible.builtin.yum` labeled `# RHEL 7-8` — RHEL 8 natively uses dnf; yum there is a compatibility shim.
- ⚠️ `ansible-core 2.17+` cited as "current" — now at 2.20.x.
- ⚠️ Mitogen lacks compatibility/support caveat for modern ansible-core.

## Trigger Quality

- Positive triggers are comprehensive and specific — covers playbooks, roles, tasks, inventory, handlers, templates, Jinja2 for Ansible, Galaxy, Vault, Molecule, ansible-lint, AWX/Tower/AAP.
- Negative triggers clearly exclude adjacent tools (Puppet, Chef, SaltStack, Terraform, Pulumi, plain Docker Compose, CloudFormation, CDK, K8s-only).
- Edge case: "Jinja2 template" alone could false-trigger, but description qualifies "Jinja2 templates for Ansible" — acceptable.
- Would correctly trigger for: "write Ansible playbook for nginx", "Ansible role for postgres", "ansible-vault encrypt", "molecule test", "AWX workflow".
- Would correctly NOT trigger for: "Terraform AWS module", "Chef cookbook", "Docker Compose stack", "kubectl deployment".

## AI Executability

An AI would produce correct, production-quality Ansible code from this skill. FQCNs are used throughout, examples are copy-paste ready, and the references cover edge cases (troubleshooting, advanced patterns, complete recipes). The only risk is the yum/dnf RHEL version guidance.
