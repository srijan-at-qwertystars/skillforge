# Review: ansible-automation

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (positive:/negative: sub-keys).

Outstanding Ansible guide. Covers fundamentals (agentless, idempotency), inventory management (static YAML/dynamic aws_ec2/directory layout/host patterns), playbook structure (pre_tasks/roles/tasks/post_tasks/handlers), imports vs includes, variable precedence (8 levels), Jinja2 templates (filters/validate/ansible_managed), roles (directory structure/meta/dependencies), collections (requirements.yml/FQCN/creating), common modules, conditionals/loops/block-rescue-always, Vault (encrypt/vault-id/indirection pattern), error handling (failed_when/changed_when/assert), performance (ansible.cfg/async/Mitogen/strategy:free/fact caching), testing (Molecule/ansible-lint/check+diff), AWX/AAP (job templates/workflows/RBAC/surveys/execution environments), and anti-patterns.
