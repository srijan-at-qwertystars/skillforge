# Ansible Troubleshooting Guide

> Systematic diagnosis and fixes for common Ansible problems.

## Table of Contents

- [SSH Connection Failures](#ssh-connection-failures)
- [Privilege Escalation Problems](#privilege-escalation-problems)
- [Variable Precedence Confusion](#variable-precedence-confusion)
- [Jinja2 Template Errors](#jinja2-template-errors)
- [Handler Not Running](#handler-not-running)
- [Idempotency Failures](#idempotency-failures)
- [Slow Execution Diagnosis](#slow-execution-diagnosis)
- [Fact Caching Issues](#fact-caching-issues)
- [Vault Password Management](#vault-password-management)
- [Module Not Found Errors](#module-not-found-errors)
- [Python Interpreter Discovery](#python-interpreter-discovery)
- [Windows WinRM Setup](#windows-winrm-setup)
- [Become Method Issues](#become-method-issues)
- [Async Task Tracking](#async-task-tracking)
- [Debugging Techniques](#debugging-techniques)

---

## SSH Connection Failures

### Symptom: "Permission denied (publickey)"

```bash
# Diagnose
ansible all -m ping -vvvv  # verbose SSH debug
ssh -vvv user@host          # test raw SSH

# Common fixes
# 1. Wrong user
ansible_user: correct_user

# 2. Wrong key
ansible_ssh_private_key_file: /path/to/correct/key

# 3. Key permissions
chmod 600 ~/.ssh/id_rsa
chmod 700 ~/.ssh

# 4. ssh-agent not running
eval $(ssh-agent -s)
ssh-add ~/.ssh/deploy_key
```

### Symptom: "Connection timed out"

```ini
# ansible.cfg — increase timeouts
[defaults]
timeout = 60

[ssh_connection]
ssh_args = -o ConnectTimeout=30 -o ConnectionAttempts=3
```

```yaml
# Check network access
- name: Test connectivity
  ansible.builtin.wait_for:
    host: "{{ ansible_host }}"
    port: 22
    timeout: 10
  delegate_to: localhost
```

### Symptom: "Host key verification failed"

```ini
# ansible.cfg — disable for lab environments (NOT production)
[defaults]
host_key_checking = False

# Production: use known_hosts
[ssh_connection]
ssh_args = -o UserKnownHostsFile=/path/to/known_hosts -o StrictHostKeyChecking=yes
```

### Symptom: SSH through bastion / jump host

```ini
# ansible.cfg
[ssh_connection]
ssh_args = -o ProxyJump=bastion.example.com

# Or per-host in inventory
bastion_target:
  ansible_ssh_common_args: '-o ProxyJump=user@bastion:22'
```

### Symptom: "Shared connection to X closed" / multiplexing errors

```ini
[ssh_connection]
# Disable ControlMaster if causing issues
ssh_args = -o ControlMaster=no
# Or use unique socket path
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o ControlPath=/tmp/ansible-ssh-%h-%p-%r
```

---

## Privilege Escalation Problems

### Symptom: "sudo: a password is required"

```yaml
# Option 1: ansible.cfg
[privilege_escalation]
become_ask_pass = True

# Option 2: command line
ansible-playbook site.yml --ask-become-pass

# Option 3: inventory var (vault-encrypt the password!)
ansible_become_password: "{{ vault_become_pass }}"

# Option 4: passwordless sudo (configure on target)
# /etc/sudoers.d/ansible
# ansible ALL=(ALL) NOPASSWD: ALL
```

### Symptom: "sudo: sorry, you must have a tty"

```ini
# ansible.cfg — enable pipelining and disable requiretty
[ssh_connection]
pipelining = True

# On target: visudo → comment out "Defaults requiretty"
```

### Symptom: become works for root but not other users

```yaml
- name: Run as app user
  ansible.builtin.command: whoami
  become: true
  become_user: appuser
  become_method: sudo
  become_flags: '-i'  # login shell — needed for env vars
```

### Symptom: Environment variables missing after become

```yaml
- name: Task needing env vars
  ansible.builtin.command: /opt/app/bin/start
  become: true
  become_user: appuser
  become_flags: '-i'  # forces login shell
  environment:
    PATH: "/opt/app/bin:{{ ansible_env.PATH }}"
    APP_HOME: /opt/app
```

---

## Variable Precedence Confusion

### The 22-Level Precedence (lowest → highest)

```
 1. command line values (not variables, e.g., -u user)
 2. role defaults (defaults/main.yml)
 3. inventory file or script group vars
 4. inventory group_vars/all
 5. playbook group_vars/all
 6. inventory group_vars/*
 7. playbook group_vars/*
 8. inventory file or script host vars
 9. inventory host_vars/*
10. playbook host_vars/*
11. host facts / cached set_facts
12. play vars
13. play vars_prompt
14. play vars_files
15. role vars (vars/main.yml)
16. block vars
17. task vars (only for the task)
18. include_vars
19. set_facts / registered vars
20. role params (roles: - role: x, var: val)
21. include params
22. extra vars (-e "var=value") — ALWAYS WIN
```

### Common Mistakes

```yaml
# WRONG: setting in defaults/main.yml then wondering why
# group_vars override it. Defaults are lowest precedence.

# FIX: Use defaults for safe fallbacks only.
# Override in group_vars / host_vars as intended.

# DEBUG: Show where a variable comes from
ansible -m debug -a "var=hostvars[inventory_hostname]" host1
ansible-inventory --host host1 --yaml  # shows merged vars
```

### Debugging Variable Origin

```yaml
# In playbook
- name: Debug variable precedence
  ansible.builtin.debug:
    msg: |
      http_port = {{ http_port }}
      from hostvars: {{ hostvars[inventory_hostname].http_port | default('undefined') }}

# Command line
ansible-playbook site.yml -e "http_port=9999"  # always wins
```

---

## Jinja2 Template Errors

### Symptom: "AnsibleUndefinedVariable"

```yaml
# Problem: variable not defined
# Fix 1: default filter
{{ my_var | default('fallback_value') }}
{{ my_var | default(omit) }}  # omit the parameter entirely

# Fix 2: conditional check
{% if my_var is defined and my_var %}
  value: {{ my_var }}
{% endif %}
```

### Symptom: "TemplateSyntaxError: unexpected char"

```yaml
# Problem: YAML/Jinja2 conflict with curly braces
# WRONG
msg: {{ my_var }}

# RIGHT — quote when starting with Jinja2
msg: "{{ my_var }}"

# Problem: literal braces in template (e.g., JSON)
# Use {% raw %} block
{% raw %}
{"key": "{{ not_a_variable }}"}
{% endraw %}
```

### Symptom: "dict object has no attribute"

```yaml
# Problem: accessing nested dict that may not exist
# WRONG
{{ server.config.port }}

# RIGHT — chain defaults
{{ server.config.port | default(8080) }}
# Or use Python dict .get() equivalent
{{ (server.config | default({})).port | default(8080) }}
```

### Symptom: Type errors in comparisons

```yaml
# Problem: comparing string to int
when: ansible_memtotal_mb > 1024  # might fail if string

# Fix: explicit int conversion
when: ansible_memtotal_mb | int > 1024

# Fix: explicit bool
when: enable_feature | bool
```

### Common Template Patterns

```jinja2
{# Iterate with index #}
{% for item in items %}
server-{{ loop.index }}: {{ item }}
{% endfor %}

{# Conditional inclusion #}
{% if groups['dbservers'] | length > 0 %}
db_host: {{ groups['dbservers'][0] }}
{% endif %}

{# Multi-line YAML in template #}
{% for vhost in vhosts | default([]) %}
- server_name: {{ vhost.name }}
  port: {{ vhost.port | default(80) }}
  {% if vhost.ssl | default(false) %}
  ssl: true
  {% endif %}
{% endfor %}

{# Whitespace control: use minus sign #}
{%- for item in list -%}
{{ item }}
{%- endfor -%}
```

---

## Handler Not Running

### Common Causes and Fixes

```yaml
# Cause 1: Task didn't report changed
# Fix: check if the task actually changes anything
- name: Deploy config
  ansible.builtin.template:
    src: app.conf.j2
    dest: /etc/app/app.conf
  notify: restart app
  # Handler only fires if this task reports changed=true

# Cause 2: Handler name mismatch (case-sensitive!)
# WRONG
  notify: Restart App
handlers:
  - name: restart app  # ← case mismatch!

# Cause 3: Play failed before handlers ran
# Fix: use force_handlers
- hosts: all
  force_handlers: true  # handlers run even if play fails
  # Or: ansible-playbook site.yml --force-handlers

# Cause 4: Handler in wrong scope
# Handlers are per-play. A handler in play 1 can't be
# notified from play 2.

# Cause 5: Need handler to run mid-play
- name: Deploy config
  ansible.builtin.template: { src: app.conf.j2, dest: /etc/app/app.conf }
  notify: restart app

- name: Flush handlers now (don't wait until end)
  ansible.builtin.meta: flush_handlers

- name: Task that needs app already restarted
  ansible.builtin.uri: { url: "http://localhost:8080/health" }

# Cause 6: Handler notified multiple times — runs once (by design)
# This is correct behavior. Handlers deduplicate.
```

### Listen Directive (Multiple Triggers)

```yaml
handlers:
  - name: restart nginx
    ansible.builtin.service: { name: nginx, state: restarted }
    listen: "restart web stack"

  - name: restart php-fpm
    ansible.builtin.service: { name: php-fpm, state: restarted }
    listen: "restart web stack"

tasks:
  - name: Update web config
    ansible.builtin.template: { src: web.conf.j2, dest: /etc/web.conf }
    notify: "restart web stack"  # triggers BOTH handlers
```

---

## Idempotency Failures

### Symptom: Task reports "changed" every run

```yaml
# Problem: command/shell always reports changed
# Fix: add changed_when
- name: Check if app is installed
  ansible.builtin.command: dpkg -l myapp
  register: app_check
  changed_when: false  # this is a check, never "changes" anything
  failed_when: false

# Problem: command does work but should only run conditionally
- name: Initialize database
  ansible.builtin.command: /opt/app/init-db.sh
  args:
    creates: /opt/app/.db_initialized  # skip if file exists

# Problem: shell script not idempotent
- name: Run migration
  ansible.builtin.command: /opt/app/migrate.sh
  register: migrate_result
  changed_when: "'Migrated' in migrate_result.stdout"
  failed_when: migrate_result.rc != 0
```

### Idempotent Patterns

```yaml
# WRONG: always downloads
- ansible.builtin.command: curl -o /tmp/app.tar.gz https://example.com/app.tar.gz

# RIGHT: use get_url with checksum
- ansible.builtin.get_url:
    url: https://example.com/app.tar.gz
    dest: /tmp/app.tar.gz
    checksum: "sha256:abc123..."

# WRONG: appends every run
- ansible.builtin.shell: echo "export PATH=/opt/bin:$PATH" >> ~/.bashrc

# RIGHT: use lineinfile (idempotent)
- ansible.builtin.lineinfile:
    path: ~/.bashrc
    line: 'export PATH=/opt/bin:$PATH'
    state: present
```

---

## Slow Execution Diagnosis

### Profiling

```ini
# ansible.cfg — enable profiling
[defaults]
callbacks_enabled = timer, profile_tasks, profile_roles

# Output shows per-task timing:
# Thursday 01 January 2024  12:00:00 +0000 (0:00:03.456)  0:01:23.456 ****
# Install packages ---------------------------------------------------- 45.23s
# Deploy config ------------------------------------------------------- 3.12s
```

### Common Bottlenecks and Fixes

```ini
# 1. Low fork count (default=5)
[defaults]
forks = 50  # match your host count

# 2. Gathering facts every play
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 7200

# Or disable entirely for plays that don't need facts
# gather_facts: false

# 3. SSH overhead
[ssh_connection]
pipelining = True  # huge speedup — requires !requiretty
ssh_args = -o ControlMaster=auto -o ControlPersist=600s

# 4. Slow callbacks
stdout_callback = minimal  # less output = faster

# 5. Package installs — batch them
```

```yaml
# SLOW: one apt call per package
- ansible.builtin.apt: { name: "{{ item }}" }
  loop: [nginx, curl, git, vim]

# FAST: single apt call
- ansible.builtin.apt:
    name: [nginx, curl, git, vim]
    state: present
```

```yaml
# 6. Use free strategy for independent hosts
- hosts: all
  strategy: free

# 7. Mitogen — 2-7x speedup
# pip install mitogen
[defaults]
strategy = mitogen_linear

# 8. Limit to subset for testing
ansible-playbook site.yml --limit web1 --tags deploy
```

---

## Fact Caching Issues

### Symptom: Stale facts

```bash
# Clear fact cache
rm -rf /tmp/ansible_facts/*

# Or per-host
rm /tmp/ansible_facts/hostname

# Force fresh gather in playbook
- hosts: all
  gather_facts: true  # explicitly gather
  tasks:
    - ansible.builtin.setup:  # force re-gather
      tags: [always]
```

### Symptom: Redis/JSON cache not working

```ini
# JSON file cache
[defaults]
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts  # must exist!
fact_caching_timeout = 86400

# Redis cache
fact_caching = redis
fact_caching_connection = localhost:6379:0
fact_caching_timeout = 86400
# pip install redis on control node
```

```bash
# Verify cache is being populated
ls -la /tmp/ansible_facts/
# Should see one file per host after first run
```

---

## Vault Password Management

### Symptom: "Decryption failed" / wrong password

```bash
# Check which vault-id was used to encrypt
head -1 secrets.yml
# $ANSIBLE_VAULT;1.2;AES256;prod  ← vault-id is "prod"

# Must supply matching vault-id
ansible-playbook site.yml --vault-id prod@prompt
```

### Multiple Vault Passwords

```bash
# Encrypt with specific ID
ansible-vault encrypt --vault-id prod@prompt prod_secrets.yml
ansible-vault encrypt --vault-id dev@~/.dev_vault_pass dev_secrets.yml

# Run with multiple IDs
ansible-playbook site.yml \
  --vault-id prod@~/.prod_vault_pass \
  --vault-id dev@~/.dev_vault_pass
```

### Vault Password File Security

```bash
# Password file permissions
chmod 600 ~/.vault_pass
echo '.vault_pass' >> .gitignore

# Script as password source
# vault_pass.sh — fetch from secret manager
#!/bin/bash
aws secretsmanager get-secret-value --secret-id ansible-vault \
  --query SecretString --output text

chmod 700 vault_pass.sh
ansible-playbook site.yml --vault-password-file=./vault_pass.sh
```

### Rekeying

```bash
# Rekey single file
ansible-vault rekey secrets.yml --new-vault-password-file=~/.new_vault_pass

# Rekey with vault-id
ansible-vault rekey --vault-id prod@prompt --new-vault-id prod@~/.new_pass secrets.yml

# Bulk rekey (find all vault files)
grep -rl '\$ANSIBLE_VAULT' . | while read f; do
  ansible-vault rekey "$f" --vault-password-file=~/.old_pass --new-vault-password-file=~/.new_pass
done
```

---

## Module Not Found Errors

### Symptom: "couldn't resolve module/action 'community.general.xxx'"

```bash
# Check if collection is installed
ansible-galaxy collection list | grep community.general

# Install missing collection
ansible-galaxy collection install community.general

# Install from requirements.yml
ansible-galaxy install -r requirements.yml

# Check collection search path
ansible-config dump | grep COLLECTIONS_PATH
```

### Symptom: Module works locally but not in CI/EE

```bash
# Ensure requirements.yml is complete
cat collections/requirements.yml
# Must list ALL collections used in playbooks

# In execution environments — add to EE definition
# execution-environment.yml → dependencies.galaxy
```

### Symptom: "No module named 'xxx'" (Python dependency)

```bash
# Module needs Python library on TARGET host
# e.g., community.docker needs docker SDK
- name: Install Docker SDK
  ansible.builtin.pip:
    name: docker
    state: present

# Or on CONTROL node for local modules
pip install docker
```

---

## Python Interpreter Discovery

### Symptom: "interpreter discovery" warnings / wrong Python

```yaml
# Explicit interpreter per host/group
webservers:
  vars:
    ansible_python_interpreter: /usr/bin/python3

# Or auto discovery (default in Ansible 2.12+)
ansible_python_interpreter: auto_silent  # suppress warnings
ansible_python_interpreter: auto         # show discovery info
```

```ini
# ansible.cfg
[defaults]
interpreter_python = auto_silent

# Force specific version
interpreter_python = /usr/bin/python3.11
```

### Symptom: Modules fail with Python errors on target

```bash
# Check what Python Ansible is using on target
ansible host1 -m ansible.builtin.setup -a 'filter=ansible_python*'

# Verify Python and required modules on target
ansible host1 -m ansible.builtin.command -a 'python3 -c "import json; print(json.__file__)"'
```

---

## Windows WinRM Setup

### Target Setup (PowerShell)

```powershell
# Run as Administrator on Windows target
# Download and run the ConfigureRemotingForAnsible.ps1 script
$url = "https://raw.githubusercontent.com/ansible/ansible-documentation/ae8772176a5c645655c91328e93196bcf741732d/examples/scripts/ConfigureRemotingForAnsible.ps1"
$file = "$env:temp\ConfigureRemotingForAnsible.ps1"
(New-Object -TypeName System.Net.WebClient).DownloadFile($url, $file)
powershell.exe -ExecutionPolicy ByPass -File $file

# Verify
winrm get winrm/config/Service
winrm get winrm/config/Winrs
```

### Inventory for Windows

```yaml
windows:
  hosts:
    win1.example.com:
  vars:
    ansible_connection: winrm
    ansible_winrm_transport: ntlm  # or kerberos, credssp
    ansible_winrm_server_cert_validation: ignore
    ansible_user: Administrator
    ansible_password: "{{ vault_win_password }}"
    ansible_port: 5986  # HTTPS (5985 for HTTP)
```

### Common Windows Issues

```yaml
# "winrm or requests is not installed"
# Fix: install pywinrm on control node
pip install pywinrm

# Kerberos auth
pip install pywinrm[kerberos]
# Configure /etc/krb5.conf

# Certificate validation
ansible_winrm_server_cert_validation: ignore  # dev only
ansible_winrm_ca_trust_path: /path/to/ca.pem  # production

# SSL/TLS errors — check PowerShell on target
Get-ChildItem WSMan:\localhost\Listener
# Ensure HTTPS listener exists with valid cert
```

---

## Become Method Issues

### Available Become Methods

| Method | Use Case |
|--------|----------|
| `sudo` | Default Linux escalation |
| `su` | Switch user (needs target user password) |
| `runas` | Windows privilege escalation |
| `doas` | OpenBSD |
| `machinectl` | systemd containers |
| `enable` | Network device enable mode |

### Symptom: "Failed to set permissions on the temporary files"

```yaml
# Usually ACL issue with become_user
# Fix 1: install acl package on target
- ansible.builtin.package: { name: acl, state: present }

# Fix 2: use pipelining (bypasses temp file permissions)
# ansible.cfg
[ssh_connection]
pipelining = True

# Fix 3: set allow_world_readable_tmpfiles (less secure)
[defaults]
allow_world_readable_tmpfiles = True
```

### Symptom: become_user can't access files

```yaml
# The become process: ssh as ansible_user → sudo to become_user
# Temp files owned by ansible_user may not be readable

# Fix: use pipelining to avoid temp files entirely
[ssh_connection]
pipelining = True

# Or ensure common group membership
```

---

## Async Task Tracking

### Symptom: Async job lost / can't check status

```yaml
# Correct async pattern
- name: Start long task
  ansible.builtin.command: /opt/app/long-task.sh
  async: 3600   # max seconds to run
  poll: 0       # fire and forget
  register: long_task

- name: Do other work...
  ansible.builtin.debug: { msg: "Working on other things" }

- name: Check on long task
  ansible.builtin.async_status:
    jid: "{{ long_task.ansible_job_id }}"
  register: job_result
  until: job_result.finished
  retries: 120
  delay: 30
```

### Symptom: Async task on wrong host

```yaml
# async_status must run on SAME host as original task
# If you delegated the async task, delegate the status check too
- name: Async on localhost
  ansible.builtin.command: /opt/build.sh
  async: 600
  poll: 0
  register: build
  delegate_to: localhost

- name: Check build
  ansible.builtin.async_status:
    jid: "{{ build.ansible_job_id }}"
  delegate_to: localhost  # must match!
  register: result
  until: result.finished
  retries: 30
  delay: 10
```

---

## Debugging Techniques

### Verbosity Levels

```bash
ansible-playbook site.yml -v     # task results
ansible-playbook site.yml -vv    # task input
ansible-playbook site.yml -vvv   # connection details
ansible-playbook site.yml -vvvv  # full SSH debug + scripts
```

### Debug Module

```yaml
- name: Show variable
  ansible.builtin.debug:
    var: my_complex_var

- name: Show expression
  ansible.builtin.debug:
    msg: "Host {{ inventory_hostname }} has IP {{ ansible_host }} and {{ ansible_memtotal_mb }}MB RAM"

- name: Show all hostvars for this host
  ansible.builtin.debug:
    var: hostvars[inventory_hostname]
```

### Strategy: debug

```yaml
- hosts: all
  strategy: debug
  tasks:
    - name: Failing task
      ansible.builtin.command: /bin/false

# Interactive debugger commands:
# p task        — print task details
# p task.args   — print task arguments
# p result      — print task result
# p vars        — print all variables
# redo          — re-run the task
# continue      — move to next task
# quit          — abort
```

### Environment Dump

```yaml
- name: Full environment debug
  ansible.builtin.debug:
    msg:
      ansible_version: "{{ ansible_version }}"
      python_version: "{{ ansible_python_version }}"
      os_family: "{{ ansible_os_family }}"
      distribution: "{{ ansible_distribution }} {{ ansible_distribution_version }}"
      connection: "{{ ansible_connection }}"
      user: "{{ ansible_user_id }}"
```

### Keep Remote Files for Inspection

```bash
# Don't delete module files on remote
ANSIBLE_KEEP_REMOTE_FILES=1 ansible-playbook site.yml -vvv
# Check on remote: ls ~/.ansible/tmp/
```
