---
name: ansible-automation
description:
  positive: "Use when user writes Ansible playbooks, asks about inventory, roles, collections, modules, handlers, variables, templates (Jinja2), vault, or AWX/AAP automation."
  negative: "Do NOT use for Terraform (infrastructure provisioning), Chef/Puppet, SaltStack, or shell scripts without Ansible context."
---

# Ansible Automation Best Practices

## Fundamentals

Ansible is agentless configuration management over SSH. Core concepts:
- **Control node**: machine running `ansible` or `ansible-playbook`.
- **Managed nodes**: target hosts (no agent required).
- **Inventory**: list of managed nodes (hosts and groups).
- **Playbook**: YAML file containing ordered lists of plays.
- **Play**: maps a group of hosts to tasks.
- **Task**: single call to an Ansible module.
- **Module**: unit of work (e.g., `ansible.builtin.copy`).
- **Idempotency**: running the same playbook twice produces the same state. Prefer declarative modules over `command`/`shell`.

## Inventory Management

### Static Inventory (YAML preferred)
```yaml
all:
  children:
    webservers:
      hosts:
        web1.example.com:
        web2.example.com:
      vars:
        http_port: 80
    dbservers:
      hosts:
        db1.example.com:
          ansible_port: 2222
```

### Dynamic Inventory
```yaml
# inventories/aws_ec2.yml
plugin: amazon.aws.aws_ec2
regions: [us-east-1]
keyed_groups:
  - key: tags.Environment
    prefix: env
filters:
  instance-state-name: running
```

### Directory Layout
```
inventories/
├── production/
│   ├── hosts.yml
│   ├── group_vars/
│   │   ├── all.yml
│   │   └── dbservers/
│   │       ├── vars.yml
│   │       └── vault.yml    # encrypted
│   └── host_vars/
│       └── web1.example.com.yml
└── staging/
    └── hosts.yml
```
Split vault-encrypted vars into separate files (`vault.yml`) alongside plaintext `vars.yml`.

### Host Patterns
```bash
ansible webservers -m ping                      # group
ansible 'webservers:&production' -m ping        # intersection
ansible 'webservers:!web1.example.com' -m ping  # exclusion
```

## Playbook Structure
```yaml
---
- name: Configure web servers
  hosts: webservers
  become: true
  gather_facts: true
  vars:
    app_version: "2.4.1"
  pre_tasks:
    - name: Update apt cache
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600
  roles:
    - role: common
    - role: nginx
      vars:
        nginx_worker_processes: 4
  tasks:
    - name: Deploy application
      ansible.builtin.copy:
        src: "app-{{ app_version }}.tar.gz"
        dest: /opt/app/
      notify: Restart app
  post_tasks:
    - name: Verify health
      ansible.builtin.uri:
        url: "http://localhost:{{ http_port }}/health"
        status_code: 200
  handlers:
    - name: Restart app
      ansible.builtin.systemd:
        name: myapp
        state: restarted
```

### imports vs includes

| Feature | `import_*` | `include_*` |
|---------|-----------|-------------|
| Processing | Static (pre-processed) | Dynamic (at runtime) |
| Tags/when | Applied to all child tasks | Applied only to include |
| Loops | Cannot loop | Can loop |

```yaml
- import_tasks: common_setup.yml                              # static
- include_tasks: "{{ ansible_os_family | lower }}_packages.yml"  # dynamic
```
Prefer `import_*` for predictability. Use `include_*` only for runtime conditionals or loops.

## Variables

### Precedence (lowest → highest)
1. Role defaults (`defaults/main.yml`)
2. Inventory `group_vars/all`
3. Inventory `group_vars/<group>`
4. Inventory `host_vars/<host>`
5. Play vars
6. Role vars (`vars/main.yml`)
7. Task vars (`set_fact`, registered)
8. Extra vars (`-e`) — **always win**

### Facts and Registered Variables
```yaml
- name: Gather disk info
  ansible.builtin.command: df -h /
  register: disk_info
  changed_when: false
- name: Set custom fact
  ansible.builtin.set_fact:
    app_memory_mb: "{{ ansible_memtotal_mb // 2 }}"
```
Set `changed_when: false` on informational commands.

## Jinja2 Templates

### Common Filters
```yaml
"{{ hostname | upper }}"                                    # string
"{{ optional_var | default('fallback') }}"                  # default
"{{ dict_var | dict2items }}"                               # data structure
"{{ users | map(attribute='name') | list }}"                # map/filter
"{{ items | selectattr('active', 'equalto', true) | list }}"
"{{ port_string | int }}"                                   # type cast
```

### Template File
```jinja2
{# templates/nginx.conf.j2 #}
# {{ ansible_managed }}
upstream backend {
{% for server in backend_servers %}
    server {{ server.host }}:{{ server.port | default(8080) }};
{% endfor %}
}
server {
    listen {{ http_port | default(80) }};
    server_name {{ server_name }};
{% if ssl_enabled | default(false) %}
    listen 443 ssl;
    ssl_certificate {{ ssl_cert_path }};
{% endif %}
}
```
```yaml
- name: Deploy nginx config
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/conf.d/app.conf
    mode: "0644"
    validate: nginx -t -c %s
  notify: Reload nginx
```
Include `{{ ansible_managed }}` in templates. Use `validate` to check config before deploying.

## Roles

### Directory Structure
```
roles/nginx/
├── tasks/main.yml       # entry point
├── handlers/main.yml    # handler definitions
├── templates/           # Jinja2 templates
├── files/               # static files
├── vars/main.yml        # high-priority vars (don't override)
├── defaults/main.yml    # low-priority vars (meant to be overridden)
├── meta/main.yml        # dependencies, galaxy metadata
└── README.md
```

### Meta and Dependencies
```yaml
# roles/nginx/meta/main.yml
galaxy_info:
  author: your_name
  description: Install and configure nginx
  min_ansible_version: "2.15"
  platforms:
    - name: Ubuntu
      versions: [jammy, noble]
dependencies:
  - role: common
  - role: firewall
    vars:
      firewall_allowed_ports: [80, 443]
```
Place tunables in `defaults/main.yml`. Use `vars/main.yml` only for internal constants.

## Collections

### Installing
```yaml
# requirements.yml
collections:
  - name: amazon.aws
    version: ">=7.0.0"
  - name: community.general
    version: ">=9.0.0"
roles:
  - name: geerlingguy.docker
    version: "7.4.1"
```
```bash
ansible-galaxy install -r requirements.yml
```

### FQCN (Fully Qualified Collection Name)
Always use FQCN — never short names:
```yaml
- ansible.builtin.copy:       # correct
    src: file.txt
    dest: /tmp/
```

### Creating a Collection
```bash
ansible-galaxy collection init myorg.myapp
ansible-galaxy collection build
ansible-galaxy collection publish myorg-myapp-1.0.0.tar.gz
```

## Common Modules
```yaml
- ansible.builtin.file:
    path: /opt/app
    state: directory
    owner: app
    mode: "0755"
- ansible.builtin.copy:
    src: config.yml
    dest: /etc/app/config.yml
    backup: true
- ansible.builtin.package:
    name: [nginx, curl]
    state: present
- ansible.builtin.systemd:
    name: nginx
    state: started
    enabled: true
    daemon_reload: true
- ansible.builtin.user:
    name: deploy
    groups: [sudo, docker]
    shell: /bin/bash
- ansible.builtin.uri:
    url: https://api.example.com/health
    status_code: [200, 201]
  register: api_response
- ansible.builtin.command:
    cmd: /opt/app/bin/migrate
    creates: /opt/app/.migrated     # idempotent — skip if exists
- ansible.builtin.shell:
    cmd: cat /etc/hosts | grep myhost
  changed_when: false
```
Prefer `command` over `shell` (avoids injection). Prefer dedicated modules over both.

## Conditionals and Loops

```yaml
- name: Install on Debian-family
  ansible.builtin.apt:
    name: nginx
    state: present
  when: ansible_os_family == "Debian"

- name: Create users
  ansible.builtin.user:
    name: "{{ item.name }}"
    groups: "{{ item.groups }}"
  loop:
    - { name: alice, groups: [sudo] }
    - { name: bob, groups: [docker] }

- name: Wait for services
  ansible.builtin.uri:
    url: "http://localhost:{{ item }}/health"
  loop: [8080, 8081, 8082]
  retries: 5
  delay: 3
  until: result.status == 200
  register: result
```

### Block / Rescue / Always
```yaml
- name: Deploy with rollback
  block:
    - name: Deploy new version
      ansible.builtin.copy:
        src: "app-{{ new_version }}.tar.gz"
        dest: /opt/app/
    - name: Run migrations
      ansible.builtin.command: /opt/app/migrate
  rescue:
    - name: Rollback
      ansible.builtin.copy:
        src: "app-{{ old_version }}.tar.gz"
        dest: /opt/app/
    - name: Alert on failure
      ansible.builtin.uri:
        url: "{{ slack_webhook }}"
        method: POST
        body_format: json
        body:
          text: "Deploy failed on {{ inventory_hostname }}"
  always:
    - name: Restart service
      ansible.builtin.systemd:
        name: myapp
        state: restarted
```

## Vault

```bash
ansible-vault encrypt group_vars/production/vault.yml
ansible-vault encrypt_string 'SuperSecret123' --name 'db_password'
# Multi-vault with vault-id
ansible-vault encrypt --vault-id prod@prompt secrets_prod.yml
ansible-playbook site.yml --vault-id prod@prompt --vault-id dev@~/.vault_dev_pass
```

### Best Practices
- Store vault password files outside the repo. Add to `.gitignore`.
- Prefix vault vars with `vault_` and reference via indirection:
```yaml
# group_vars/production/vault.yml (encrypted)
vault_db_password: "SuperSecret123"
# group_vars/production/vars.yml (plaintext)
db_password: "{{ vault_db_password }}"
```
- Add `no_log: true` to tasks handling sensitive data.

## Error Handling
```yaml
- name: Check optional service
  ansible.builtin.command: systemctl status optional-svc
  ignore_errors: true
- name: Check app version
  ansible.builtin.command: /opt/app/version
  register: version_check
  failed_when: "'2.0' not in version_check.stdout"
- name: Query database
  ansible.builtin.command: psql -c "SELECT count(*) FROM users"
  changed_when: false
- name: Validate input
  ansible.builtin.fail:
    msg: "app_version must be defined"
  when: app_version is not defined
- name: Pre-flight checks
  ansible.builtin.assert:
    that:
      - ansible_memtotal_mb >= 2048
      - ansible_distribution == "Ubuntu"
    fail_msg: "Host does not meet requirements"
```

## Performance Optimization

### ansible.cfg Tuning
```ini
[defaults]
forks = 50
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 3600
callbacks_enabled = profile_tasks
stdout_callback = yaml

[ssh_connection]
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
```

### Async Tasks
```yaml
- name: Long-running update
  ansible.builtin.apt:
    upgrade: dist
  async: 600
  poll: 0
  register: apt_job
- name: Wait for update
  ansible.builtin.async_status:
    jid: "{{ apt_job.ansible_job_id }}"
  register: job_result
  until: job_result.finished
  retries: 60
  delay: 10
```

### Key Optimizations
- Set `gather_facts: false` when facts not needed. Use `gather_subset` for selective gathering.
- Enable **Mitogen** for 2–7x speedup (persistent Python RPC replaces SSH file-copy).
- Use `strategy: free` so hosts proceed independently.
- Use `serial` for rolling deployments to limit blast radius.
- Cache facts with Redis or JSON between runs.
- Profile with `profile_tasks` callback to find bottlenecks.

## Testing

```bash
# Molecule — test role lifecycle
molecule init role myorg.myrole --driver-name docker
molecule test          # full: create → converge → idempotence → verify → destroy

# ansible-lint — enforce standards
ansible-lint playbooks/ roles/

# Dry run with diff
ansible-playbook site.yml --check --diff --limit web1.example.com
```
Use `check_mode: true` on individual tasks for permanent dry-run.

## AWX / Ansible Automation Platform (AAP)

### Core Concepts
- **Job Template**: playbook + inventory + credentials + variables. Use "Prompt on Launch" for flexibility.
- **Workflow Template**: chains job templates with success/failure/always paths. Nest workflows for scale.
- **Inventory**: static or cloud-sourced (synced on schedule).
- **Credentials**: stored encrypted — SSH keys, vault passwords, cloud tokens.
- **RBAC**: per-object permissions (admin, execute, read) for users and teams.
- **Surveys**: user-facing forms for self-service automation.
- **Execution Environments**: containerized runtime replacing virtualenvs. Pin dependencies.

### Best Practices
- Define workflows as code using `controller_configuration` collection.
- Use workflow visualizer for debugging complex chains.
- Parameterize with surveys and extra vars — never hardcode.
- Enforce least-privilege RBAC on credentials and templates.
- Enable webhook triggers for CI/CD integration (GitHub, GitLab).
- Schedule recurring jobs for drift detection and compliance.
- Configure notification templates (Slack, email, PagerDuty) on job outcomes.

## Anti-Patterns to Avoid

1. **Overusing `command`/`shell`** — use dedicated modules. Add `creates`/`removes` or `changed_when`.
2. **Ignoring idempotency** — test with `--check` and molecule idempotence.
3. **Secrets in plaintext** — use Vault or external secret manager. Add `no_log: true`.
4. **Monolithic playbooks** — break into roles. One role = one concern.
5. **Hardcoded values** — use variables with defaults via `group_vars` or `--extra-vars`.
6. **Missing task names** — every task needs a descriptive `name:`.
7. **Short module names** — always use FQCN (`ansible.builtin.copy`, not `copy`).
8. **Skipping lint** — run `ansible-lint` in CI.
9. **No error handling** — use `block/rescue/always`. Set `failed_when`/`changed_when`.
10. **Running as root everywhere** — use `become: true` only on tasks that need it.

<!-- tested: pass -->
