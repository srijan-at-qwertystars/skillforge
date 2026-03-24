#!/usr/bin/env bash
# ansible-init.sh — Scaffold an Ansible project with standard directory layout.
#
# Usage: ./ansible-init.sh <project-name>
#
# Creates:
#   <project-name>/
#     ansible.cfg
#     inventories/{production,staging}/{hosts.yml,group_vars/all.yml,host_vars/}
#     playbooks/site.yml
#     roles/
#     group_vars/all.yml
#     collections/requirements.yml
#     vault/
#     files/
#     templates/
#     filter_plugins/
#     library/
#     callback_plugins/
#     .gitignore
#     .ansible-lint
#     README.md

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <project-name>"
    echo "Example: $0 my-infra"
    exit 1
fi

PROJECT="$1"

if [[ -d "$PROJECT" ]]; then
    echo "Error: Directory '$PROJECT' already exists."
    exit 1
fi

echo "Creating Ansible project: $PROJECT"

# Directory structure
mkdir -p "$PROJECT"/{inventories/{production,staging}/{group_vars,host_vars},playbooks,roles,group_vars,collections,vault,files,templates,filter_plugins,library,callback_plugins}

# ansible.cfg
cat > "$PROJECT/ansible.cfg" << 'EOF'
[defaults]
inventory = inventories/production/hosts.yml
roles_path = roles:~/.ansible/roles:/usr/share/ansible/roles
collections_path = collections:~/.ansible/collections
remote_user = deploy
ask_pass = false
forks = 20
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 7200
stdout_callback = yaml
callbacks_enabled = timer, profile_tasks
retry_files_enabled = false
host_key_checking = true
interpreter_python = auto_silent

[privilege_escalation]
become = false
become_method = sudo
become_user = root
become_ask_pass = false

[ssh_connection]
pipelining = true
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o PreferredAuthentications=publickey
control_path_dir = /tmp/ansible-cp

[diff]
always = true
context = 3
EOF

# Production inventory
cat > "$PROJECT/inventories/production/hosts.yml" << 'EOF'
---
all:
  children:
    webservers:
      hosts:
        # web1.example.com:
        #   ansible_host: 10.0.1.10
    dbservers:
      hosts:
        # db1.example.com:
        #   ansible_host: 10.0.2.10
    monitoring:
      hosts:
        # mon1.example.com:
EOF

cat > "$PROJECT/inventories/production/group_vars/all.yml" << 'EOF'
---
# Variables for all production hosts
env: production
ntp_servers:
  - 0.pool.ntp.org
  - 1.pool.ntp.org
EOF

# Staging inventory
cat > "$PROJECT/inventories/staging/hosts.yml" << 'EOF'
---
all:
  children:
    webservers:
      hosts:
        # staging-web1.example.com:
    dbservers:
      hosts:
        # staging-db1.example.com:
EOF

cat > "$PROJECT/inventories/staging/group_vars/all.yml" << 'EOF'
---
env: staging
EOF

# Global group_vars
cat > "$PROJECT/group_vars/all.yml" << 'EOF'
---
# Global variables (apply to all inventories)
ansible_python_interpreter: auto_silent
EOF

# Main playbook
cat > "$PROJECT/playbooks/site.yml" << 'EOF'
---
# Master playbook — includes all role assignments

- name: Apply common configuration
  hosts: all
  become: true
  roles:
    - role: common
      tags: [common]

# - name: Configure web servers
#   hosts: webservers
#   become: true
#   roles:
#     - role: webserver
#       tags: [webserver]

# - name: Configure database servers
#   hosts: dbservers
#   become: true
#   roles:
#     - role: database
#       tags: [database]
EOF

# Collections requirements
cat > "$PROJECT/collections/requirements.yml" << 'EOF'
---
collections:
  - name: ansible.posix
    version: ">=1.5.0"
  - name: community.general
    version: ">=8.0.0"
  # - name: amazon.aws
  # - name: community.docker
EOF

# .gitignore
cat > "$PROJECT/.gitignore" << 'EOF'
*.retry
*.pyc
__pycache__/
.vault_pass
*.vault_pass
/tmp/
.ansible/
collections/ansible_collections/
EOF

# .ansible-lint
cat > "$PROJECT/.ansible-lint" << 'EOF'
---
skip_list:
  - yaml[line-length]
warn_list:
  - no-changed-when
  - command-instead-of-module
EOF

# README
cat > "$PROJECT/README.md" << EOF
# $PROJECT

Ansible automation project.

## Quick Start

\`\`\`bash
# Install dependencies
ansible-galaxy install -r collections/requirements.yml

# Test connectivity
ansible all -i inventories/staging/hosts.yml -m ping

# Run playbook (staging)
ansible-playbook playbooks/site.yml -i inventories/staging/hosts.yml

# Run playbook (production)
ansible-playbook playbooks/site.yml -i inventories/production/hosts.yml
\`\`\`

## Structure

- \`inventories/\` — Per-environment inventory and vars
- \`playbooks/\` — Top-level playbooks
- \`roles/\` — Reusable roles
- \`collections/\` — Collection dependencies
- \`vault/\` — Encrypted secrets
EOF

echo ""
echo "✓ Project '$PROJECT' created successfully."
echo ""
echo "Next steps:"
echo "  cd $PROJECT"
echo "  ansible-galaxy install -r collections/requirements.yml"
echo "  # Edit inventories/staging/hosts.yml with your hosts"
echo "  ansible all -i inventories/staging/hosts.yml -m ping"
