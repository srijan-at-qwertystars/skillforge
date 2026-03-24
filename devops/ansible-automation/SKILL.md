---
name: ansible-automation
description: >
  Use this skill when the user asks about Ansible playbooks, roles, inventories, modules, collections,
  Ansible Vault, Jinja2 templates, Molecule testing, ansible-lint, AWX/Tower, or any Ansible
  configuration management and automation task. Triggers on: writing playbooks, creating roles,
  managing inventory, encrypting secrets with Vault, deploying with Ansible, ansible-galaxy,
  handler notifications, task delegation, async tasks, fact gathering, variable precedence,
  block/rescue error handling, ansible.cfg tuning, pipelining, mitogen, check mode, diff mode,
  or debugging Ansible runs. Do NOT trigger for Terraform/Pulumi/OpenTofu (infrastructure-as-code
  provisioning), Nomad/Kubernetes (container orchestration), Chef/Puppet (competing config mgmt),
  or general SSH/shell scripting unrelated to Ansible.
---

# Ansible Automation

## Architecture

Ansible is agentless. The **control node** (Linux/macOS only) executes playbooks over **SSH** (Linux/Unix) or **WinRM** (Windows) against **managed nodes**. No agent runs on targets.

Components: **Inventory** (hosts/groups), **Playbooks** (YAML desired-state), **Modules** (units of work), **Plugins** (connection, callback, lookup, filter, strategy), **Collections** (packaged modules+roles+plugins).

Flow: parse inventory → load playbook → compile tasks → fork connections to hosts → transfer/execute modules → return JSON → fire handlers.

## Inventory

Static INI: groups in `[brackets]`, children via `[group:children]`, group vars via `[group:vars]`.
Static YAML: nested `all.children.<group>.hosts` with per-host vars.

```yaml
# inventory/hosts.yml
all:
  children:
    webservers:
      hosts:
        web1.example.com: { ansible_host: 10.0.1.10 }
      vars: { http_port: 8080 }
    dbservers:
      hosts:
        db1.example.com: { ansible_port: 2222 }
```

**Dynamic inventory**: use plugins (`aws_ec2`, `azure_rm`, `gcp_compute`). Enable in `ansible.cfg` under `[inventory] enable_plugins`. Plugin files are YAML with `plugin:` key.

**Host/group vars**: place in `inventory/group_vars/<group>.yml` and `inventory/host_vars/<host>.yml`.

**Patterns**: `webservers` (group), `web*` (glob), `webservers:&production` (intersection), `webservers:!web2` (exclusion).

## Playbooks

```yaml
- name: Configure web servers
  hosts: webservers
  become: true
  vars:
    app_port: 8080
  pre_tasks:
    - name: Update apt cache
      ansible.builtin.apt: { update_cache: true, cache_valid_time: 3600 }
  tasks:
    - name: Install nginx
      ansible.builtin.apt: { name: nginx, state: present }
      notify: restart nginx
    - name: Deploy config
      ansible.builtin.template:
        src: nginx.conf.j2
        dest: /etc/nginx/nginx.conf
        mode: '0644'
      notify: restart nginx
    - name: Ensure running
      ansible.builtin.service: { name: nginx, state: started, enabled: true }
  handlers:
    - name: restart nginx
      ansible.builtin.service: { name: nginx, state: restarted }
  post_tasks:
    - name: Health check
      ansible.builtin.uri: { url: "http://localhost:{{ app_port }}", status_code: 200 }
```

**Conditionals**: `when: ansible_os_family == "Debian"`. Chain with `and`/`or` or use list (implicit AND).

**Loops**: `loop:` with list of items. Access via `{{ item }}`. For dicts: `loop: "{{ mydict | dict2items }}"`.

**Register**: capture output with `register: result`, use `result.stdout`, `result.rc`, `result.stdout_lines`.

## Modules

Always use FQCN. Key modules:

| Module | Purpose |
|--------|---------|
| `ansible.builtin.command` | Run command (no shell expansion) |
| `ansible.builtin.shell` | Run via shell (pipes, redirects) |
| `ansible.builtin.copy` | Copy files to remote |
| `ansible.builtin.template` | Render Jinja2 → remote |
| `ansible.builtin.file` | Manage files/dirs/links/perms |
| `ansible.builtin.apt` / `yum` / `dnf` | Package management |
| `ansible.builtin.service` | Start/stop/restart services |
| `ansible.builtin.user` | Manage users |
| `ansible.builtin.git` | Clone/update repos |
| `ansible.builtin.lineinfile` | Edit single line in file |
| `ansible.builtin.uri` | HTTP requests |
| `community.docker.docker_container` | Manage Docker containers |

## Roles

Structure: `defaults/main.yml` (lowest-precedence vars), `vars/main.yml` (high-precedence), `tasks/main.yml`, `handlers/main.yml`, `files/`, `templates/`, `meta/main.yml` (dependencies).

```yaml
# Use in playbook
- hosts: webservers
  roles:
    - role: webserver
      vars: { http_port: 8080 }
```

Role deps in `meta/main.yml`: `dependencies: [{role: common}, {role: firewall}]`.

**Galaxy**: `ansible-galaxy role init myrole` (scaffold), `ansible-galaxy install -r requirements.yml` (install).

```yaml
# requirements.yml
roles:
  - name: geerlingguy.nginx
    version: "3.2.0"
collections:
  - name: community.general
    version: ">=8.0.0"
```

## Collections

Namespace-scoped bundles of modules, roles, plugins. Install: `ansible-galaxy collection install community.general`. Pin versions in `requirements.yml`. Structure: `galaxy.yml`, `plugins/{modules,inventory,callback}`, `roles/`, `playbooks/`.

Build: `ansible-galaxy collection build`. Publish: `ansible-galaxy collection publish`.

## Jinja2 Templates

```jinja2
server {
    listen {{ http_port | default(80) }};
    server_name {{ ansible_fqdn }};
    {% for loc in app_locations %}
    location {{ loc.path }} {
        proxy_pass http://{{ loc.backend }}:{{ loc.port }};
    }
    {% endfor %}
    {% if ssl_enabled | default(false) %}
    ssl_certificate {{ ssl_cert_path }};
    {% endif %}
}
```

**Filters**: `| default('x')`, `| join(',')`, `| password_hash('sha512')`, `| basename`, `| to_nice_yaml`, `| selectattr('active')`, `| regex_replace('old','new')`, `| map('extract', hostvars, 'ansible_host')`.

**Lookups**: `lookup('file','/etc/hostname')`, `lookup('env','HOME')`, `lookup('password','/dev/null length=16')`, `query('fileglob','files/*.conf')`.

## Variables

**Precedence** (lowest→highest): role defaults → inventory group_vars/all → inventory group_vars/* → inventory host_vars → playbook group_vars → playbook host_vars → facts/set_fact/registered → play vars → play vars_files → role vars/main.yml → block vars → task vars → include_vars → set_fact/registered → **extra vars (`-e`) always win**.

```yaml
- ansible.builtin.set_fact:
    full_url: "https://{{ domain }}:{{ port }}/{{ path }}"
- ansible.builtin.include_vars:
    file: "{{ env }}.yml"
```

## Ansible Vault

```bash
ansible-vault create secrets.yml                     # create encrypted
ansible-vault edit secrets.yml                        # edit in-place
ansible-vault encrypt vars/prod.yml                   # encrypt existing
ansible-vault encrypt_string 'secret' --name 'db_pw'  # inline encrypted var
ansible-vault rekey secrets.yml                       # change password
```

Run: `ansible-playbook site.yml --vault-password-file ~/.vault_pass` or `--ask-vault-pass`.

**Multiple vaults**: use `--vault-id prod@prompt --vault-id dev@~/.dev_pass`. Encrypt with `--vault-id prod@prompt`.

Store vault password files outside the repo. Never commit plaintext secrets. Keep vault files separate from regular vars.

## Error Handling

**ignore_errors**: task continues on failure. **failed_when**: custom failure condition.
**changed_when**: override change detection (critical for command/shell).

```yaml
- ansible.builtin.command: systemctl status myapp
  register: svc
  ignore_errors: true
  changed_when: false
```

**block/rescue/always**: try/catch/finally for tasks.

```yaml
- block:
    - ansible.builtin.copy: { src: app-v2.tar.gz, dest: /opt/app/ }
    - ansible.builtin.service: { name: myapp, state: restarted }
  rescue:
    - ansible.builtin.copy: { src: app-v1.tar.gz, dest: /opt/app/ }
    - ansible.builtin.service: { name: myapp, state: restarted }
  always:
    - ansible.builtin.uri:
        url: https://hooks.slack.com/...
        method: POST
        body: '{"text":"deploy finished"}'
        body_format: json
```

**any_errors_fatal: true**: stop all hosts if any host fails. Combine with `serial: "30%"` for rolling deploys.

## Async and Polling

```yaml
- name: Start migration
  ansible.builtin.command: /opt/app/migrate.sh
  async: 3600       # max runtime
  poll: 0           # fire and forget
  register: mig_job

- name: Wait for migration
  ansible.builtin.async_status:
    jid: "{{ mig_job.ansible_job_id }}"
  register: result
  until: result.finished
  retries: 60
  delay: 30
```

Set `poll: N` (N>0) to poll every N seconds inline instead.

## Delegation and Local Actions

```yaml
- name: Register with LB
  ansible.builtin.uri:
    url: "https://lb.example.com/api/members"
    method: POST
    body: '{"host":"{{ inventory_hostname }}"}'
    body_format: json
  delegate_to: localhost

- name: Wait for reboot
  ansible.builtin.wait_for_connection: { delay: 30, timeout: 300 }
```

`delegate_to: localhost` runs task on control node. Use `delegate_facts: true` to assign gathered facts to the delegated host.

## Tags and Limits

Tag tasks: `tags: [install, nginx]`. Run: `--tags configure`, `--skip-tags install`.
Limit hosts: `--limit web1.example.com`, `--limit "webservers:&staging"`.

## Testing

**Molecule**: test framework for roles. `pip install molecule molecule-docker`. Commands: `molecule test` (full lifecycle), `molecule converge` (apply), `molecule verify` (assert), `molecule login` (shell into container).

```yaml
# molecule/default/molecule.yml
driver: { name: docker }
platforms:
  - { name: ubuntu-test, image: "ubuntu:22.04", pre_build_image: true }
provisioner: { name: ansible }
verifier: { name: ansible }
```

**ansible-lint**: `pip install ansible-lint && ansible-lint playbooks/`. Enforces best practices.

**Check/diff mode**: `--check` (dry run), `--check --diff` (dry run + diffs), `--diff` (apply + show diffs).

## Best Practices

**Project layout**:
```
ansible-project/
  ansible.cfg
  inventory/{production,staging}/{hosts.yml,group_vars/,host_vars/}
  playbooks/{site.yml,webservers.yml}
  roles/{common,webserver,database}/
  collections/requirements.yml
  vault/{prod_secrets.yml,dev_secrets.yml}
```

- Write idempotent tasks. Prefer modules over command/shell.
- Always use FQCN (`ansible.builtin.copy` not `copy`).
- Apply `become: true` per-task, not play-wide.
- Name every task. Unnamed tasks are undebuggable.
- Pin collection/role versions in `requirements.yml`.
- Add `changed_when`/`failed_when` to all command/shell tasks.
- Avoid `vars_prompt` in CI — use extra-vars or vault.

## Performance

```ini
[defaults]
forks = 20                    # default 5; scale to hardware
gathering = smart             # cache facts across plays
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 7200
callbacks_enabled = timer, profile_tasks
[ssh_connection]
pipelining = True             # modules via stdin, not scp
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
```

**Mitogen**: drop-in strategy plugin, 2-7x speedup via persistent Python channel. Set `strategy = mitogen_linear`.

**Other**: `gather_facts: false` when unused. `serial: [1, 5, "100%"]` for canary deploys. `strategy: free` for independent hosts. `max_fail_percentage: 10` for partial-failure tolerance.

## AWX / Automation Platform

AWX (open-source) / AAP (Red Hat) add: web UI + REST API, RBAC, job templates with surveys, scheduling, credential management, smart inventories (cloud-synced), notifications (Slack/email/webhook), workflow templates (chained jobs with conditionals).

## Common Pitfalls

| Pitfall | Fix |
|---------|-----|
| `command`/`shell` for everything | Use dedicated modules for idempotency |
| Bare module names | Always use FQCN |
| Play-level `become: true` | Per-task become for least privilege |
| Missing `changed_when` on commands | Add `changed_when: false` to check commands |
| Hardcoded hosts in playbooks | Use inventory groups + `--limit` |
| Plaintext secrets in vars | Use ansible-vault |
| No role testing | Molecule + ansible-lint in CI |
| Monolithic playbooks | Split into roles, use `import_role`/`include_role` |
| Ignoring variable precedence | Know the 15 levels; extra-vars for overrides only |
| Unpinned collection versions | Pin in `requirements.yml` |

## References

Detailed deep-dive guides in `references/`:

| Reference | Topics |
|-----------|--------|
| [advanced-patterns.md](references/advanced-patterns.md) | Custom modules (Python), filter/lookup/callback/connection/strategy plugins, dynamic inventory (AWS/GCP/Azure), collections development, execution environments, Ansible Navigator, Molecule testing, Terraform integration |
| [troubleshooting.md](references/troubleshooting.md) | SSH failures, privilege escalation, variable precedence, Jinja2 errors, handlers not running, idempotency failures, slow execution profiling, fact caching, vault passwords, module-not-found, Python interpreter discovery, WinRM setup, become issues, async tracking, debug techniques |
| [security-hardening.md](references/security-hardening.md) | Vault best practices (multi-vault, vault-id, rekeying), secret rotation, SSH key management, least-privilege playbooks, CIS benchmark automation, security scanning (Trivy, OpenSCAP), certificate management, firewall automation, user/access management, audit logging, compliance-as-code |

## Scripts

Ready-to-use scaffolding tools in `scripts/`:

| Script | Purpose | Usage |
|--------|---------|-------|
| [ansible-init.sh](scripts/ansible-init.sh) | Scaffold full Ansible project (inventories, roles, ansible.cfg, .gitignore) | `./scripts/ansible-init.sh my-project` |
| [role-init.sh](scripts/role-init.sh) | Create role with Molecule test scaffold | `./scripts/role-init.sh nginx --path roles/` |
| [vault-helper.sh](scripts/vault-helper.sh) | Vault operations wrapper (encrypt, decrypt, rekey, find, check) | `./scripts/vault-helper.sh encrypt secrets.yml --vault-id prod` |

## Assets

Reusable templates and configs in `assets/`:

| Asset | Description |
|-------|-------------|
| [ansible.cfg](assets/ansible.cfg) | Production config with SSH pipelining, fact caching, performance tuning |
| [playbook-template.yml](assets/playbook-template.yml) | Full playbook with pre_tasks, roles, block/rescue/always, handlers, post_tasks |
| [role-template/](assets/role-template/) | Complete role skeleton (tasks, defaults, handlers, meta, templates, vars) |
| [inventory-template.yml](assets/inventory-template.yml) | YAML inventory with groups, children, host_vars, group_vars examples |
| [docker-compose.yml](assets/docker-compose.yml) | Dev environment: control node + Ubuntu/Rocky/Debian managed nodes |

## Examples

### Input: "Set up Docker on Ubuntu"

```yaml
- name: Configure Docker host
  hosts: docker_hosts
  become: true
  vars: { docker_users: [deploy] }
  tasks:
    - name: Install prereqs
      ansible.builtin.apt:
        name: [ca-certificates, curl, gnupg]
        state: present
        update_cache: true
    - name: Add Docker GPG key
      ansible.builtin.apt_key:
        url: https://download.docker.com/linux/ubuntu/gpg
    - name: Add Docker repo
      ansible.builtin.apt_repository:
        repo: "deb https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable"
    - name: Install Docker
      ansible.builtin.apt:
        name: [docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin]
        state: present
      notify: restart docker
    - name: Add users to docker group
      ansible.builtin.user: { name: "{{ item }}", groups: docker, append: true }
      loop: "{{ docker_users }}"
    - name: Ensure running
      ansible.builtin.service: { name: docker, state: started, enabled: true }
  handlers:
    - name: restart docker
      ansible.builtin.service: { name: docker, state: restarted }
```

### Input: "Create Molecule test for nginx role"

```bash
ansible-galaxy role init nginx_role && cd nginx_role
molecule init scenario --driver-name docker
```

```yaml
# molecule/default/verify.yml
- name: Verify nginx
  hosts: all
  tasks:
    - name: Check nginx installed
      ansible.builtin.command: nginx -v
      changed_when: false
    - name: Gather services
      ansible.builtin.service_facts:
    - name: Assert running
      ansible.builtin.assert:
        that:
          - "'nginx' in services"
          - "services['nginx'].state == 'running'"
```

<!-- tested: pass -->
