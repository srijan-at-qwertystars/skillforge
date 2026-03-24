# Ansible Troubleshooting Guide

## Table of Contents

- [SSH Connection Failures](#ssh-connection-failures)
- [Privilege Escalation Problems](#privilege-escalation-problems)
- [Variable Precedence Confusion](#variable-precedence-confusion)
- [Template Rendering Errors](#template-rendering-errors)
- [Module Idempotency Failures](#module-idempotency-failures)
- [Handler Timing Issues](#handler-timing-issues)
- [Vault Password Management](#vault-password-management)
- [Collection Version Conflicts](#collection-version-conflicts)
- [Python Interpreter Discovery](#python-interpreter-discovery)
- [Windows WinRM Setup](#windows-winrm-setup)
- [Slow Playbook Execution](#slow-playbook-execution)
- [Fact Gathering Performance](#fact-gathering-performance)

---

## SSH Connection Failures

### Key Authentication Issues

**Symptom**: `Permission denied (publickey)`

```bash
ansible all -m ping -vvvv  # Max verbosity shows SSH negotiation
ssh -vvv -i /path/to/key user@host  # Test SSH directly

# Fix key permissions
chmod 600 ~/.ssh/id_rsa && chmod 700 ~/.ssh
```

```ini
# ansible.cfg — specify key
[defaults]
private_key_file = ~/.ssh/ansible_key
remote_user = ansible
```

**Symptom**: `Too many authentication failures`

```ini
# ansible.cfg — limit auth attempts
[ssh_connection]
ssh_args = -o IdentitiesOnly=yes -o ControlMaster=auto -o ControlPersist=60s
```

### Host Key Checking

**Symptom**: `Host key verification failed`

```ini
# Development only
[defaults]
host_key_checking = False

# Production — auto-accept new keys
[ssh_connection]
ssh_args = -o StrictHostKeyChecking=accept-new
```

### Connection Timeouts

```ini
# ansible.cfg
[defaults]
timeout = 30

[ssh_connection]
ssh_args = -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ControlMaster=auto -o ControlPersist=60s
retries = 3
```

```yaml
# Per-host in inventory
[slow_hosts]
legacy1 ansible_ssh_timeout=60
```

---

## Privilege Escalation Problems

### become/sudo Failures

**Symptom**: `Missing sudo password`

```bash
ansible-playbook site.yml -K  # Prompt for become password
```

```yaml
# Configure passwordless sudo on target
- name: Configure sudoers
  ansible.builtin.lineinfile:
    path: /etc/sudoers.d/ansible
    line: "{{ ansible_user }} ALL=(ALL) NOPASSWD: ALL"
    validate: 'visudo -cf %s'
    create: true
    mode: '0440'
```

**Symptom**: `no tty present and no askpass program specified`

```ini
# ansible.cfg — enable pipelining (avoids tty requirement)
[ssh_connection]
pipelining = True
```

Or add to sudoers: `Defaults:ansible !requiretty`

### SELinux Interactions

**Symptom**: `Failed to set permissions on temporary files`

```yaml
- ansible.builtin.package:
    name: python3-libselinux
    state: present
```

---

## Variable Precedence Confusion

### Diagnosing Variable Values

```yaml
- ansible.builtin.debug:
    msg: "app_port={{ app_port }}, type={{ app_port | type_debug }}"

# Dump all variables for a host
- ansible.builtin.debug:
    var: hostvars[inventory_hostname]
```

```bash
ansible -m debug -a "var=app_port" web1 -i inventory/
ansible -m setup -a "filter=ansible_distribution*" web1
```

### Common Precedence Mistakes

```yaml
# MISTAKE 1: Using roles/x/vars/ for overridable values
# roles/myapp/vars/main.yml has app_port: 8080 (HIGH precedence)
# inventory/group_vars/prod.yml has app_port: 9090
# Result: app_port = 8080 — role vars win!
# FIX: Put overridable values in defaults/main.yml

# MISTAKE 2: Extra vars silently override everything
# -e "app_port=9090" ALWAYS wins, even over set_fact

# MISTAKE 3: set_fact persists across plays
- hosts: all
  tasks:
    - ansible.builtin.set_fact:
        my_var: "from play 1"
# In play 2, my_var is still "from play 1"!

# MISTAKE 4: Hash replace vs merge
# Default: entire dict is replaced, not merged
# FIX: Use combine filter
- ansible.builtin.set_fact:
    config: "{{ defaults | combine(overrides, recursive=True) }}"
```

---

## Template Rendering Errors

### Undefined Variable Errors

**Symptom**: `AnsibleUndefinedVariable: 'xxx' is undefined`

```yaml
# Use default filter
server_name: "{{ custom_name | default('localhost') }}"

# Skip optional params
- ansible.builtin.apt:
    default_release: "{{ apt_release | default(omit) }}"
```

```jinja2
{# In templates #}
worker_processes {{ workers | default(ansible_processor_vcpus | default(2)) }};
{% if extra_config is defined %}
include {{ extra_config }};
{% endif %}
```

### Type Errors in Filters

```yaml
# Boolean string vs actual boolean
when: enable_ssl | bool         # Always cast!

# Integer as string
worker_count: "{{ num_workers | int }}"

# Dict vs list confusion
msg: "{{ config if config is mapping else {} }}"
```

### Whitespace and Formatting

```jinja2
{# Remove extra newlines with whitespace control #}
{% for item in list -%}
{{ item }}
{% endfor -%}

{# Or set in template header #}
#jinja2: trim_blocks: True, lstrip_blocks: True
```

---

## Module Idempotency Failures

### Command/Shell Always Changed

```yaml
# PROBLEM: Always reports changed
- ansible.builtin.command: /opt/app/check.sh

# FIX 1: creates/removes
- ansible.builtin.command: /opt/app/init.sh
  args:
    creates: /opt/app/.initialized

# FIX 2: changed_when
- ansible.builtin.command: /opt/app/check.sh
  changed_when: false

# FIX 3: Conditional changed
- ansible.builtin.shell: /opt/app/migrate.sh
  register: result
  changed_when: "'Applied' in result.stdout"
  failed_when: result.rc not in [0, 2]
```

### Package and File Issues

```yaml
# state: latest causes changes every run — use present
- ansible.builtin.apt: { name: nginx, state: present }

# Always quote file modes as strings
- ansible.builtin.file:
    path: /opt/app
    mode: "0755"   # NOT 755 (integer interpreted wrong)
```

---

## Handler Timing Issues

### Handlers Not Running

```yaml
# PROBLEM: Name mismatch (case-sensitive!)
notify: restart nginx
# ...
handlers:
  - name: Restart nginx   # Doesn't match!

# FIX: Use listen for flexible matching
handlers:
  - name: Restart nginx
    ansible.builtin.systemd: { name: nginx, state: restarted }
    listen: "restart nginx"

# PROBLEM: Task didn't change → handler not notified
# PROBLEM: Handler in wrong scope (role handlers are role-scoped)
```

### Handler Ordering and Flushing

```yaml
# Handlers fire in DEFINITION order, not notify order
# Force handlers mid-play:
- ansible.builtin.meta: flush_handlers

- name: Test after handler ran
  ansible.builtin.uri:
    url: http://localhost/health
```

---

## Vault Password Management

### Common Errors

**`no vault secrets were found that could decrypt`** — wrong password or vault-id mismatch.

```bash
# Check vault-id from file header
head -1 vars/secrets.yml
# $ANSIBLE_VAULT;1.2;AES256;prod  ← vault-id is "prod"

ansible-vault view vars/secrets.yml --ask-vault-pass
```

### Multi-Vault Setup

```bash
ansible-playbook site.yml --vault-id dev@~/.vault_dev --vault-id prod@~/.vault_prod
ansible-vault encrypt --vault-id prod@prompt vars/prod.yml
```

```ini
# ansible.cfg
[defaults]
vault_identity_list = dev@~/.vault_dev, prod@~/.vault_prod
```

### CI/CD Integration

```yaml
# GitHub Actions
- run: |
    echo "$ANSIBLE_VAULT_PASSWORD" > /tmp/.vault_pass
    chmod 600 /tmp/.vault_pass
    ansible-playbook site.yml --vault-password-file /tmp/.vault_pass
    rm -f /tmp/.vault_pass
  env:
    ANSIBLE_VAULT_PASSWORD: ${{ secrets.VAULT_PASSWORD }}
```

---

## Collection Version Conflicts

### Diagnosing and Resolving

```bash
ansible-galaxy collection list                    # Show installed versions
ansible-galaxy collection install -r requirements.yml -vvv  # Verbose install
ansible-galaxy collection install -r requirements.yml --force  # Force reinstall
```

```yaml
# requirements.yml — pin versions
collections:
  - { name: community.general, version: ">=8.0.0,<9.0.0" }
  - { name: amazon.aws, version: "7.2.0" }   # Exact pin
```

```bash
# Isolated install path
ansible-galaxy collection install -r requirements.yml -p ./collections
# ansible.cfg: collections_path = ./collections:~/.ansible/collections
```

---

## Python Interpreter Discovery

### Interpreter Not Found

```yaml
# Set explicitly
[all:vars]
ansible_python_interpreter=/usr/bin/python3

# Per-host
[legacy]
old_server ansible_python_interpreter=/usr/bin/python2.7
```

```ini
# ansible.cfg
[defaults]
interpreter_python = auto_silent
```

**`No module named 'apt_pkg'`** — interpreter doesn't match system Python:

```yaml
- ansible.builtin.apt:
    name: python3-apt
  vars:
    ansible_python_interpreter: /usr/bin/python3
```

---

## Windows WinRM Setup

### Configuration

```powershell
# On Windows target (Administrator):
winrm quickconfig -q
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}'
```

### Inventory Variables

```yaml
# group_vars/windows.yml
ansible_connection: winrm
ansible_winrm_transport: ntlm     # basic, ntlm, kerberos, credssp
ansible_winrm_server_cert_validation: ignore  # Self-signed certs
ansible_port: 5986
ansible_user: ansible@DOMAIN.COM
ansible_password: "{{ vault_win_password }}"
```

```bash
pip install pywinrm[kerberos,credssp]
```

**Kerberos issues**: verify `kinit user@DOMAIN.COM` works and check `/etc/krb5.conf`.

---

## Slow Playbook Execution

### Diagnosing Bottlenecks

```ini
# ansible.cfg — enable profiling
[defaults]
callbacks_enabled = profile_tasks, profile_roles, timer
```

### Performance Checklist

1. **Enable `profile_tasks`** to find slow tasks
2. **Disable/limit `gather_facts`**: `gather_subset: ['!all', '!min', network]`
3. **Enable SSH pipelining**: `pipelining = True`
4. **Increase `forks`**: default 5 → 50+
5. **Use `strategy: free`** when host order doesn't matter
6. **Batch package installs** as list, not loop
7. **Cache facts**: `gathering: smart` + `fact_caching = jsonfile`
8. **Use `async`** for long independent tasks
9. **Consider Mitogen**: 2–7× speedup
10. **Check network latency** between controller and targets

```yaml
# SLOW — loop installs
- ansible.builtin.apt:
    name: "{{ item }}"
  loop: [nginx, certbot, git]

# FAST — list install
- ansible.builtin.apt:
    name: [nginx, certbot, git]
    state: present
```

---

## Fact Gathering Performance

```yaml
# Disable when not needed
- hosts: all
  gather_facts: false

# Gather only what you need
- hosts: all
  gather_subset: ['!all', '!min', network, hardware]
```

```ini
# Cache facts between runs
[defaults]
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 86400

# Redis cache (faster for large inventories)
# fact_caching = redis
# fact_caching_connection = localhost:6379:0
```
