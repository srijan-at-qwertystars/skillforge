#!/usr/bin/env bash
# scaffold-role.sh — Scaffold an Ansible role with best practices
#
# Creates a complete Ansible role directory structure following Galaxy
# conventions, including template files with sensible defaults.
#
# Usage:
#   scaffold-role.sh --name <role_name> [--collection <namespace.collection>]
#                    [--output-dir <path>] [--license <license>]
#
# Examples:
#   scaffold-role.sh --name webserver
#   scaffold-role.sh --name webserver --collection mycompany.infrastructure
#   scaffold-role.sh --name database --output-dir ./roles --license MIT

set -euo pipefail

# --- Defaults ---
ROLE_NAME=""
COLLECTION=""
OUTPUT_DIR="."
LICENSE="MIT"
AUTHOR="${USER:-ansible}"

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") --name <role_name> [OPTIONS]

Scaffold an Ansible role with best-practice directory structure.

Required:
  --name, -n NAME           Role name (lowercase, hyphens allowed)

Options:
  --collection, -c NS.COLL  Collection namespace.name (creates collection-style layout)
  --output-dir, -o PATH     Output directory (default: current directory)
  --license, -l LICENSE      License type (default: MIT)
  --author, -a AUTHOR        Author name (default: \$USER)
  --help, -h                 Show this help message

Examples:
  $(basename "$0") --name webserver
  $(basename "$0") --name database --collection mycompany.infra --output-dir ./roles
EOF
    exit "${1:-0}"
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name|-n)     ROLE_NAME="$2"; shift 2 ;;
        --collection|-c) COLLECTION="$2"; shift 2 ;;
        --output-dir|-o) OUTPUT_DIR="$2"; shift 2 ;;
        --license|-l)  LICENSE="$2"; shift 2 ;;
        --author|-a)   AUTHOR="$2"; shift 2 ;;
        --help|-h)     usage 0 ;;
        *) echo "Error: Unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ -z "$ROLE_NAME" ]]; then
    echo "Error: --name is required" >&2
    usage 1
fi

# Validate role name (lowercase, alphanumeric, hyphens, underscores)
if [[ ! "$ROLE_NAME" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    echo "Error: Role name must start with a lowercase letter and contain only [a-z0-9_-]" >&2
    exit 1
fi

# --- Determine paths ---
if [[ -n "$COLLECTION" ]]; then
    NAMESPACE="${COLLECTION%%.*}"
    COLL_NAME="${COLLECTION##*.}"
    ROLE_BASE="${OUTPUT_DIR}/${NAMESPACE}/${COLL_NAME}/roles/${ROLE_NAME}"
else
    ROLE_BASE="${OUTPUT_DIR}/${ROLE_NAME}"
fi

if [[ -d "$ROLE_BASE" ]]; then
    echo "Error: Directory already exists: ${ROLE_BASE}" >&2
    exit 1
fi

echo "Scaffolding role: ${ROLE_NAME}"
[[ -n "$COLLECTION" ]] && echo "  Collection: ${COLLECTION}"
echo "  Path: ${ROLE_BASE}"

# --- Create directory structure ---
DIRS=(
    defaults
    vars
    tasks
    handlers
    templates
    files
    meta
    tests
    molecule/default
)

for dir in "${DIRS[@]}"; do
    mkdir -p "${ROLE_BASE}/${dir}"
done

# --- defaults/main.yml ---
cat > "${ROLE_BASE}/defaults/main.yml" <<EOF
---
# defaults/main.yml — Default variables for ${ROLE_NAME}
# These have the lowest precedence and are easily overridden.

# ${ROLE_NAME}_enabled: true
# ${ROLE_NAME}_version: "latest"
# ${ROLE_NAME}_port: 8080
EOF

# --- vars/main.yml ---
cat > "${ROLE_BASE}/vars/main.yml" <<EOF
---
# vars/main.yml — Role-internal variables for ${ROLE_NAME}
# These have high precedence. Use defaults/ for user-overridable values.

_${ROLE_NAME//-/_}_packages:
  Debian:
    - "{{ ${ROLE_NAME//-/_}_package_name | default('${ROLE_NAME}') }}"
  RedHat:
    - "{{ ${ROLE_NAME//-/_}_package_name | default('${ROLE_NAME}') }}"
EOF

# --- tasks/main.yml ---
cat > "${ROLE_BASE}/tasks/main.yml" <<EOF
---
# tasks/main.yml — Main task entry point for ${ROLE_NAME}

- name: Include OS-specific variables
  ansible.builtin.include_vars: "{{ item }}"
  with_first_found:
    - files:
        - "{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml"
        - "{{ ansible_distribution }}.yml"
        - "{{ ansible_os_family }}.yml"
        - default.yml
      paths: ../vars
      skip: true

- name: Include installation tasks
  ansible.builtin.include_tasks: install.yml

- name: Include configuration tasks
  ansible.builtin.include_tasks: configure.yml

- name: Include service tasks
  ansible.builtin.include_tasks: service.yml
EOF

# --- tasks/install.yml ---
cat > "${ROLE_BASE}/tasks/install.yml" <<EOF
---
# tasks/install.yml — Installation tasks for ${ROLE_NAME}

- name: Install ${ROLE_NAME} packages
  ansible.builtin.package:
    name: "{{ ${ROLE_NAME//-/_}_packages | default(['${ROLE_NAME}']) }}"
    state: present
  become: true
EOF

# --- tasks/configure.yml ---
cat > "${ROLE_BASE}/tasks/configure.yml" <<EOF
---
# tasks/configure.yml — Configuration tasks for ${ROLE_NAME}

- name: Deploy ${ROLE_NAME} configuration
  ansible.builtin.template:
    src: config.j2
    dest: "/etc/${ROLE_NAME}/config.yml"
    owner: root
    group: root
    mode: "0644"
  become: true
  notify: Restart ${ROLE_NAME}
EOF

# --- tasks/service.yml ---
cat > "${ROLE_BASE}/tasks/service.yml" <<EOF
---
# tasks/service.yml — Service management for ${ROLE_NAME}

- name: Ensure ${ROLE_NAME} service is started and enabled
  ansible.builtin.systemd:
    name: "${ROLE_NAME}"
    state: started
    enabled: true
    daemon_reload: true
  become: true
EOF

# --- handlers/main.yml ---
cat > "${ROLE_BASE}/handlers/main.yml" <<EOF
---
# handlers/main.yml — Handlers for ${ROLE_NAME}

- name: Restart ${ROLE_NAME}
  ansible.builtin.systemd:
    name: "${ROLE_NAME}"
    state: restarted
    daemon_reload: true
  become: true

- name: Reload ${ROLE_NAME}
  ansible.builtin.systemd:
    name: "${ROLE_NAME}"
    state: reloaded
  become: true
EOF

# --- templates/config.j2 ---
cat > "${ROLE_BASE}/templates/config.j2" <<'EOF'
# {{ ansible_managed }}
# Configuration for {{ role_name | default('service') }}
# Generated on {{ ansible_date_time.iso8601 }}
EOF

# --- meta/main.yml ---
cat > "${ROLE_BASE}/meta/main.yml" <<EOF
---
galaxy_info:
  role_name: ${ROLE_NAME}
  author: ${AUTHOR}
  description: Ansible role for ${ROLE_NAME}
  license: ${LICENSE}
  min_ansible_version: "2.15"
  platforms:
    - name: Ubuntu
      versions:
        - jammy
        - noble
    - name: EL
      versions:
        - "8"
        - "9"
    - name: Debian
      versions:
        - bookworm
  galaxy_tags:
    - ${ROLE_NAME}

dependencies: []
EOF

# --- tests/inventory ---
cat > "${ROLE_BASE}/tests/inventory" <<EOF
[test]
localhost ansible_connection=local
EOF

# --- tests/test.yml ---
cat > "${ROLE_BASE}/tests/test.yml" <<EOF
---
- name: Test ${ROLE_NAME} role
  hosts: test
  become: true
  roles:
    - ${ROLE_NAME}
EOF

# --- molecule/default/molecule.yml ---
cat > "${ROLE_BASE}/molecule/default/molecule.yml" <<EOF
---
dependency:
  name: galaxy
driver:
  name: docker
platforms:
  - name: ${ROLE_NAME}-ubuntu
    image: geerlingguy/docker-ubuntu2204-ansible
    pre_build_image: true
    command: ""
    privileged: true
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
    cgroupns_mode: host
provisioner:
  name: ansible
verifier:
  name: ansible
EOF

# --- molecule/default/converge.yml ---
cat > "${ROLE_BASE}/molecule/default/converge.yml" <<EOF
---
- name: Converge
  hosts: all
  become: true
  roles:
    - role: "\${MOLECULE_PROJECT_DIRECTORY##*/}"
EOF

# --- molecule/default/verify.yml ---
cat > "${ROLE_BASE}/molecule/default/verify.yml" <<EOF
---
- name: Verify
  hosts: all
  become: true
  gather_facts: true
  tasks:
    - name: Example verification
      ansible.builtin.assert:
        that: true
        success_msg: "Verification passed"
EOF

# --- README.md ---
cat > "${ROLE_BASE}/README.md" <<EOF
# ${ROLE_NAME}

Ansible role for ${ROLE_NAME}.

## Requirements

- Ansible >= 2.15
- Supported platforms: Ubuntu 22.04/24.04, RHEL/Rocky 8/9, Debian 12

## Role Variables

See \`defaults/main.yml\` for all configurable variables.

## Dependencies

None.

## Example Playbook

\`\`\`yaml
- hosts: servers
  become: true
  roles:
    - role: ${ROLE_NAME}
\`\`\`

## Testing

\`\`\`bash
cd ${ROLE_NAME}
molecule test
\`\`\`

## License

${LICENSE}

## Author

${AUTHOR}
EOF

# --- .yamllint ---
cat > "${ROLE_BASE}/.yamllint" <<EOF
---
extends: default
rules:
  line-length:
    max: 120
  truthy:
    allowed-values: ['true', 'false', 'yes', 'no']
  comments:
    min-spaces-from-content: 1
EOF

# --- .ansible-lint ---
cat > "${ROLE_BASE}/.ansible-lint" <<EOF
---
skip_list:
  - yaml[line-length]
warn_list:
  - role-name[path]
EOF

echo ""
echo "Role scaffolded successfully!"
echo ""
echo "Directory structure:"
find "${ROLE_BASE}" -type f | sort | sed "s|${ROLE_BASE}/|  ${ROLE_NAME}/|"
echo ""
echo "Next steps:"
echo "  1. Edit defaults/main.yml with your role's default variables"
echo "  2. Implement tasks in tasks/install.yml, configure.yml, service.yml"
echo "  3. Add templates to templates/"
echo "  4. Run: cd ${ROLE_BASE} && molecule test"
