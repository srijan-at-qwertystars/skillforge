#!/usr/bin/env bash
# role-init.sh — Create an Ansible role with Molecule testing scaffold.
#
# Usage: ./role-init.sh <role-name> [--path <roles-dir>]
#
# Creates a role with:
#   defaults/main.yml, tasks/main.yml, handlers/main.yml, meta/main.yml,
#   vars/main.yml, files/, templates/, molecule/default/ (full test setup)
#
# Examples:
#   ./role-init.sh nginx
#   ./role-init.sh webserver --path ./roles

set -euo pipefail

ROLE_NAME=""
ROLES_PATH="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            ROLES_PATH="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 <role-name> [--path <roles-dir>]"
            echo ""
            echo "Options:"
            echo "  --path <dir>  Directory to create role in (default: current dir)"
            echo ""
            echo "Example: $0 nginx --path ./roles"
            exit 0
            ;;
        *)
            ROLE_NAME="$1"
            shift
            ;;
    esac
done

if [[ -z "$ROLE_NAME" ]]; then
    echo "Error: Role name is required."
    echo "Usage: $0 <role-name> [--path <roles-dir>]"
    exit 1
fi

ROLE_DIR="$ROLES_PATH/$ROLE_NAME"

if [[ -d "$ROLE_DIR" ]]; then
    echo "Error: Role directory '$ROLE_DIR' already exists."
    exit 1
fi

echo "Creating role: $ROLE_NAME in $ROLE_DIR"

# Create directory structure
mkdir -p "$ROLE_DIR"/{defaults,tasks,handlers,meta,vars,files,templates,molecule/default}

# defaults/main.yml
cat > "$ROLE_DIR/defaults/main.yml" << EOF
---
# Default variables for $ROLE_NAME (lowest precedence — safe to override)
${ROLE_NAME}_enabled: true
# ${ROLE_NAME}_port: 8080
# ${ROLE_NAME}_config_path: /etc/${ROLE_NAME}
EOF

# vars/main.yml
cat > "$ROLE_DIR/vars/main.yml" << EOF
---
# Role-internal variables (high precedence — not meant to be overridden)
# _${ROLE_NAME}_packages:
#   - ${ROLE_NAME}
EOF

# tasks/main.yml
cat > "$ROLE_DIR/tasks/main.yml" << EOF
---
# Main task list for $ROLE_NAME

- name: Include OS-specific variables
  ansible.builtin.include_vars: "{{ item }}"
  with_first_found:
    - files:
        - "{{ ansible_distribution | lower }}-{{ ansible_distribution_major_version }}.yml"
        - "{{ ansible_os_family | lower }}.yml"
        - default.yml
      paths: ../vars
      skip: true

- name: Install ${ROLE_NAME} packages
  ansible.builtin.package:
    name: "{{ _${ROLE_NAME}_packages | default([]) }}"
    state: present
  become: true
  when: _${ROLE_NAME}_packages is defined

# - name: Deploy ${ROLE_NAME} configuration
#   ansible.builtin.template:
#     src: config.j2
#     dest: "{{ ${ROLE_NAME}_config_path }}/config.yml"
#     mode: '0644'
#   become: true
#   notify: restart ${ROLE_NAME}

# - name: Ensure ${ROLE_NAME} is running
#   ansible.builtin.service:
#     name: ${ROLE_NAME}
#     state: started
#     enabled: true
#   become: true
EOF

# handlers/main.yml
cat > "$ROLE_DIR/handlers/main.yml" << EOF
---
# Handlers for $ROLE_NAME

- name: restart ${ROLE_NAME}
  ansible.builtin.service:
    name: ${ROLE_NAME}
    state: restarted
  become: true

- name: reload ${ROLE_NAME}
  ansible.builtin.service:
    name: ${ROLE_NAME}
    state: reloaded
  become: true
EOF

# meta/main.yml
cat > "$ROLE_DIR/meta/main.yml" << EOF
---
galaxy_info:
  author: Your Name
  description: Ansible role for ${ROLE_NAME}
  license: MIT
  min_ansible_version: "2.14"
  platforms:
    - name: Ubuntu
      versions: [jammy, noble]
    - name: EL
      versions: [8, 9]
  galaxy_tags:
    - ${ROLE_NAME}

dependencies: []
  # - role: common
EOF

# molecule/default/molecule.yml
cat > "$ROLE_DIR/molecule/default/molecule.yml" << 'EOF'
---
dependency:
  name: galaxy
driver:
  name: docker
platforms:
  - name: ubuntu2204
    image: geerlingguy/docker-ubuntu2204-ansible
    pre_build_image: true
    command: ""
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
    cgroupns_mode: host
    privileged: true
  - name: rocky9
    image: geerlingguy/docker-rockylinux9-ansible
    pre_build_image: true
    command: ""
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
    cgroupns_mode: host
    privileged: true
provisioner:
  name: ansible
verifier:
  name: ansible
scenario:
  test_sequence:
    - dependency
    - lint
    - cleanup
    - destroy
    - syntax
    - create
    - prepare
    - converge
    - idempotence
    - verify
    - cleanup
    - destroy
EOF

# molecule/default/converge.yml
cat > "$ROLE_DIR/molecule/default/converge.yml" << EOF
---
- name: Converge
  hosts: all
  become: true
  roles:
    - role: ${ROLE_NAME}
EOF

# molecule/default/verify.yml
cat > "$ROLE_DIR/molecule/default/verify.yml" << EOF
---
- name: Verify
  hosts: all
  become: true
  tasks:
    - name: Gather package facts
      ansible.builtin.package_facts:
        manager: auto

    # - name: Assert ${ROLE_NAME} package is installed
    #   ansible.builtin.assert:
    #     that:
    #       - "'${ROLE_NAME}' in ansible_facts.packages"
    #     fail_msg: "${ROLE_NAME} package is not installed"

    # - name: Check ${ROLE_NAME} service is running
    #   ansible.builtin.service_facts:
    #
    # - name: Assert ${ROLE_NAME} service is active
    #   ansible.builtin.assert:
    #     that:
    #       - "services['${ROLE_NAME}.service'].state == 'running'"
    #     fail_msg: "${ROLE_NAME} is not running"
EOF

# molecule/default/prepare.yml
cat > "$ROLE_DIR/molecule/default/prepare.yml" << 'EOF'
---
- name: Prepare
  hosts: all
  become: true
  tasks:
    - name: Update package cache (Debian)
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600
      when: ansible_os_family == "Debian"
EOF

# README
cat > "$ROLE_DIR/README.md" << EOF
# $ROLE_NAME

Ansible role for $ROLE_NAME.

## Requirements

- Ansible >= 2.14

## Role Variables

See \`defaults/main.yml\` for configurable variables.

## Example Playbook

\`\`\`yaml
- hosts: servers
  roles:
    - role: $ROLE_NAME
\`\`\`

## Testing

\`\`\`bash
pip install molecule molecule-plugins[docker]
cd $ROLE_DIR
molecule test
\`\`\`

## License

MIT
EOF

echo ""
echo "✓ Role '$ROLE_NAME' created at $ROLE_DIR"
echo ""
echo "Structure:"
find "$ROLE_DIR" -type f | sort | sed "s|$ROLES_PATH/||" | sed 's/^/  /'
echo ""
echo "Next steps:"
echo "  cd $ROLE_DIR"
echo "  # Edit tasks/main.yml with your tasks"
echo "  molecule test  # run full test lifecycle"
