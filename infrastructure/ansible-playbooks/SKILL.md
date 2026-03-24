---
name: ansible-playbooks
description: >
  Use when writing Ansible playbooks, roles, tasks, inventory files, handlers,
  templates, or automating server configuration and deployment with Ansible.
  Triggers for YAML automation with hosts/tasks/become keywords, Jinja2
  templates for Ansible, ansible-galaxy roles/collections, ansible-vault
  encryption, molecule testing, ansible-lint, AWX/Tower job templates, and
  Ansible Automation Platform workflows. Do NOT use for Puppet/Chef/SaltStack
  configuration management, Terraform/Pulumi infrastructure provisioning,
  shell scripting without Ansible, or Kubernetes-only deployments without
  Ansible. Do NOT use for plain Docker Compose, CloudFormation, or CDK unless
  Ansible is orchestrating them.
---

# Ansible Playbooks Skill

Ansible is an agentless automation platform using SSH and YAML. Current releases: ansible-core 2.17+ / Ansible 10+. Collections are the primary distribution unit for modules and plugins. Always use fully qualified collection names (FQCNs).

## Inventory

Define targets in INI or YAML. Prefer YAML for complex environments.

```yaml
# Static YAML inventory
all:
  children:
    webservers:
      hosts:
        web1.example.com: { http_port: 80 }
        web2.example.com: { http_port: 8080 }
    dbservers:
      hosts:
        db1.example.com: { ansible_user: postgres }
  vars:
    ansible_python_interpreter: /usr/bin/python3
```

```ini
; Static INI inventory
[webservers]
web1.example.com http_port=80
web2.example.com http_port=8080
[dbservers]
db1.example.com ansible_user=postgres
[all:vars]
ansible_python_interpreter=/usr/bin/python3
```

Use dynamic inventory plugins (`amazon.aws.aws_ec2`, `azure.azcollection.azure_rm`, `google.cloud.gcp_compute`) or custom scripts returning JSON. Enable in `ansible.cfg` under `[inventory] enable_plugins`.

Place per-host/group overrides in `host_vars/<hostname>.yml` and `group_vars/<groupname>.yml` adjacent to the inventory file. These auto-load.

## Playbook Structure

Execution order: `pre_tasks` → `roles` → `tasks` → `post_tasks`. Handlers fire after each section that notifies them.

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
      ansible.builtin.apt: { update_cache: true, cache_valid_time: 3600 }
  roles:
    - role: geerlingguy.nginx
      vars: { nginx_vhosts: [] }
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
      retries: 5
      delay: 3
  handlers:
    - name: Restart app
      ansible.builtin.systemd:
        name: myapp
        state: restarted
        daemon_reload: true
```

## Modules

### Command execution

```yaml
- ansible.builtin.command: /usr/bin/uptime        # no shell features
- ansible.builtin.shell: cat /etc/hosts | grep db  # pipes/redirects OK
- ansible.builtin.script: scripts/bootstrap.sh     # copy + execute
- ansible.builtin.raw: yum install -y python3      # pre-Python bootstrap
```

### File management

```yaml
- ansible.builtin.file:
    path: /opt/app
    state: directory
    owner: app
    mode: "0755"
- ansible.builtin.copy:
    src: config.conf
    dest: /etc/myapp/config.conf
    backup: true
- ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
    validate: nginx -t -c %s
  notify: Reload nginx
- ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: "^PermitRootLogin"
    line: "PermitRootLogin no"
  notify: Restart sshd
```

### Package management

```yaml
- ansible.builtin.apt:
    name: [nginx, certbot]
    state: present
    update_cache: true
- ansible.builtin.dnf: { name: httpd, state: latest }     # RHEL 9+/Fedora
- ansible.builtin.yum: { name: httpd, state: present }    # RHEL 7-8
- ansible.builtin.package: { name: git, state: present }  # OS-agnostic
```

### Services, users, git, containers, HTTP, debugging

```yaml
- ansible.builtin.systemd:
    name: nginx
    state: started
    enabled: true
    daemon_reload: true
- ansible.builtin.user:
    name: deploy
    groups: [sudo, docker]
    shell: /bin/bash
- ansible.builtin.group: { name: docker, state: present }
- ansible.builtin.git:
    repo: https://github.com/org/app.git
    dest: /opt/app
    version: "v{{ app_version }}"
- community.docker.docker_container:
    name: redis
    image: redis:7-alpine
    ports: ["6379:6379"]
    restart_policy: unless-stopped
- ansible.builtin.uri:
    url: https://api.example.com/deploy
    method: POST
    body_format: json
    body: { "version": "{{ app_version }}" }
    headers: { Authorization: "Bearer {{ api_token }}" }
    status_code: [200, 201]
- ansible.builtin.debug: { msg: "Version {{ app_version }}" }
- ansible.builtin.assert:
    that: ["app_version is version('2.0', '>=')", "http_port > 0"]
    fail_msg: "Invalid configuration"
- ansible.builtin.fail:
    msg: "Unsupported OS: {{ ansible_distribution }}"
  when: ansible_distribution not in ['Ubuntu', 'Debian', 'RedHat']
```

## Variables and Precedence

22 precedence levels (lowest → highest): command-line values → role defaults → inventory file/group/host vars → playbook group/host vars → host facts → play vars → vars_prompt → vars_files → role vars → block vars → task vars → include_vars → set_facts → registered vars → role params → include params → extra vars (`-e`).

```yaml
- ansible.builtin.command: cat /etc/os-release
  register: os_info                              # registered variable
- ansible.builtin.set_fact:
    full_version: "{{ app_version }}.{{ build }}"
    cacheable: true                              # persists with fact caching
# In play-level: vars_files, vars_prompt
- hosts: all
  vars_files: ["vars/common.yml", "vars/{{ ansible_os_family }}.yml"]
  vars_prompt:
    - { name: deploy_pass, prompt: "Password", private: true }
```

## Conditionals

```yaml
- ansible.builtin.apt: { name: nginx }
  when: ansible_os_family == "Debian"
- ansible.builtin.service: { name: nginx, state: restarted }
  when: config_result is changed
- ansible.builtin.command: /opt/app/migrate.sh
  register: migrate
  changed_when: "'Applied' in migrate.stdout"
  failed_when: migrate.rc not in [0, 2]
```

### Block / rescue / always

```yaml
- block:
    - ansible.builtin.apt: { name: myapp, state: latest }
    - ansible.builtin.command: /opt/app/migrate.sh
  rescue:
    - ansible.builtin.apt: { name: "myapp={{ prev_ver }}", state: present }
  always:
    - ansible.builtin.service: { name: myapp, state: started }
```

## Loops

```yaml
- name: Create users
  ansible.builtin.user:
    name: "{{ item.name }}"
    groups: "{{ item.groups }}"
  loop:
    - { name: alice, groups: [sudo] }
    - { name: bob, groups: [docker] }
- name: From dict
  ansible.builtin.apt: { name: "{{ item.key }}", state: "{{ item.value }}" }
  with_dict: { nginx: present, apache2: absent }
- name: Glob templates
  ansible.builtin.template:
    src: "{{ item }}"
    dest: "/etc/myapp/{{ item | basename | regex_replace('\\.j2$','') }}"
  with_fileglob: "templates/myapp/*.j2"
- name: With loop control
  ansible.builtin.include_tasks: provision.yml
  loop: "{{ server_list }}"
  loop_control: { loop_var: server, label: "{{ server.name }}", pause: 2 }
```

## Templates (Jinja2)

```jinja2
{# nginx.conf.j2 #}
upstream app {
{% for host in groups['appservers'] %}
    server {{ hostvars[host]['ansible_host'] }}:{{ app_port | default(8080) }};
{% endfor %}
}
server {
    listen {{ http_port }};
    server_name {{ server_name | lower }};
    {% if enable_ssl | bool %}
    listen 443 ssl;
    ssl_certificate {{ ssl_cert_path }};
    {% endif %}
    location / { proxy_pass http://app; }
}
```

Key filters: `default()`, `lower`, `upper`, `replace()`, `regex_replace()`, `to_json`, `to_yaml`, `b64encode`, `hash('sha256')`, `join(',')`, `map()`, `select()`, `reject()`, `combine()`, `dict2items`, `items2dict`, `flatten`.

Lookups: `"{{ lookup('file', '/etc/hostname') }}"`, `"{{ lookup('env', 'HOME') }}"`, `"{{ lookup('pipe', 'date +%Y%m%d') }}"`.

## Roles

```
roles/webserver/
├── defaults/main.yml    # lowest-precedence defaults
├── vars/main.yml        # high-precedence variables
├── tasks/main.yml       # task entry point
├── handlers/main.yml    # handlers
├── templates/           # Jinja2 templates
├── files/               # static files
├── meta/main.yml        # metadata + dependencies
└── README.md
```

```yaml
# meta/main.yml - dependencies
dependencies:
  - { role: common, vars: { ntp_server: pool.ntp.org } }
  - role: geerlingguy.firewall
# Using roles in playbook
roles:
  - common
  - { role: webserver, vars: { http_port: 8080 }, tags: [web] }
  - { role: monitoring, when: "enable_monitoring | bool" }
```

## Collections

```bash
ansible-galaxy collection install community.docker
ansible-galaxy collection install -r requirements.yml
```

```yaml
# requirements.yml
collections:
  - { name: community.docker, version: ">=3.0.0" }
  - { name: amazon.aws, version: ">=7.0.0" }
  - name: ansible.posix
roles:
  - { name: geerlingguy.docker, version: "7.1.0" }
```

Reference by FQCN: `community.docker.docker_container`, `amazon.aws.ec2_instance`, `ansible.posix.synchronize`.

## Vault

```bash
ansible-vault encrypt vars/secrets.yml                            # encrypt file
ansible-vault encrypt --vault-id prod@prompt vars/prod.yml        # with vault-id
ansible-vault edit vars/secrets.yml                                # edit in-place
ansible-vault encrypt_string 'Secret123' --name 'db_password'     # inline string
ansible-playbook site.yml --ask-vault-pass                         # prompt at run
ansible-playbook site.yml --vault-id dev@~/.vdev --vault-id prod@~/.vprod  # multi
```

Inline vault in var files: `db_password: !vault |` followed by the encrypted blob.

## Handlers and Notifications

```yaml
tasks:
  - ansible.builtin.template:
      src: nginx.conf.j2
      dest: /etc/nginx/nginx.conf
    notify: [Validate nginx, Reload nginx]
handlers:
  - name: Validate nginx
    ansible.builtin.command: nginx -t
    listen: "restart web stack"
  - name: Reload nginx
    ansible.builtin.systemd: { name: nginx, state: reloaded }
    listen: "restart web stack"
```

Force mid-play handler execution: `- ansible.builtin.meta: flush_handlers`.

## Tags

```yaml
- ansible.builtin.apt: { name: nginx }
  tags: [install, nginx]
- ansible.builtin.template: { src: nginx.conf.j2, dest: /etc/nginx/nginx.conf }
  tags: [configure, nginx]
```

Run: `--tags "configure"`, `--skip-tags "install"`. Use `always` tag for must-run tasks. Use `never` tag for opt-in-only tasks. Apply tags to roles or blocks.

## Delegation and Local Actions

```yaml
- ansible.builtin.uri:
    url: "https://lb.example.com/api/deregister"
    method: POST
    body: '{"host": "{{ inventory_hostname }}"}'
  delegate_to: localhost
- ansible.builtin.script: check_health.sh
  delegate_to: "{{ monitoring_host }}"
- ansible.builtin.command: "nsupdate -k /etc/rndc.key"
  connection: local           # alternative to delegate_to: localhost
```

## Async and Polling

```yaml
- ansible.builtin.command: /opt/app/heavy_migration.sh
  async: 3600                 # max seconds
  poll: 30                    # check interval
- ansible.builtin.command: /opt/app/rebuild_index.sh
  async: 3600
  poll: 0                     # fire-and-forget
  register: rebuild_job
- ansible.builtin.async_status:
    jid: "{{ rebuild_job.ansible_job_id }}"
  register: job_result
  until: job_result.finished
  retries: 60
  delay: 30
```

## Error Handling

```yaml
- ansible.builtin.command: /opt/app/optional.sh
  ignore_errors: true
- hosts: webservers
  any_errors_fatal: true      # abort entire play on any failure
  tasks: [...]
- hosts: webservers
  max_fail_percentage: 30     # tolerate partial failure
  serial: 5
  tasks: [...]
- ansible.builtin.ping:
  ignore_unreachable: true    # skip unreachable hosts
```

## Performance Tuning

```ini
# ansible.cfg
[defaults]
forks = 50
pipelining = True
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 86400
strategy = free
callbacks_enabled = profile_tasks
[ssh_connection]
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
```

Use `serial: "30%"` or `serial: [1, 5, 10]` for rolling deploys. Use Mitogen (`strategy: mitogen_linear`) for 2-7× speedup. Limit facts: `gather_subset: [network, hardware]`. Use `async` + `poll: 0` to parallelize slow tasks across hosts.

## Testing

```bash
# Molecule - role testing
pip install molecule molecule-plugins[docker]
cd roles/webserver && molecule init scenario -d docker
molecule test    # lint → create → converge → idempotence → verify → destroy
# ansible-lint
ansible-lint site.yml roles/
# Check + diff mode (dry run)
ansible-playbook site.yml --check --diff
```

Use `check_mode: true` per-task for always-dry-run. Use `check_mode: false` to force execution even in check mode.

## AWX / Automation Controller (Tower)

- **Job Templates**: playbook + inventory + credentials + extra vars
- **Workflows**: chain templates with success/failure/always paths
- **Inventories**: sync from cloud, SCM, or static sources
- **Credentials**: vault passwords, SSH keys, cloud tokens (RBAC-secured)
- **Surveys**: prompt for extra vars at launch via web UI
- **Execution Environments**: containerized images replacing virtualenvs
- **Webhooks**: trigger from GitHub/GitLab for GitOps

```yaml
- awx.awx.job_template:
    name: "Deploy App"
    project: "MyProject"
    playbook: "deploy.yml"
    inventory: "Production"
    credentials: ["Machine SSH", "Vault Password"]
    controller_host: "https://awx.example.com"
    controller_oauthtoken: "{{ awx_token }}"
```
