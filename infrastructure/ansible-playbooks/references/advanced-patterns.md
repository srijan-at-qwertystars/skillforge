# Advanced Ansible Patterns

## Table of Contents

- [Custom Modules and Plugins](#custom-modules-and-plugins)
- [Dynamic Inventory Scripts](#dynamic-inventory-scripts)
- [Ansible Collections Development](#ansible-collections-development)
- [Molecule Testing Deep Dive](#molecule-testing-deep-dive)
- [Role Dependencies and Meta](#role-dependencies-and-meta)
- [Complex Variable Precedence](#complex-variable-precedence)
- [Jinja2 Advanced Techniques](#jinja2-advanced-techniques)
- [Performance Optimization](#performance-optimization)
- [AWX/AAP Workflows and Surveys](#awxaap-workflows-and-surveys)
- [Ansible Navigator](#ansible-navigator)

---

## Custom Modules and Plugins

### Action Plugins

Action plugins run on the controller and intercept module calls before they reach targets.

```python
# plugins/action/my_validated_copy.py
from ansible.plugins.action import ActionBase
from ansible.errors import AnsibleActionFail
import os

class ActionModule(ActionBase):
    TRANSFERS_FILES = True

    def run(self, tmp=None, task_vars=None):
        super().run(tmp, task_vars)
        source = self._task.args.get('src')
        dest = self._task.args.get('dest')
        if not source or not dest:
            raise AnsibleActionFail("src and dest are required")
        source = self._find_needle('files', source)
        if os.path.getsize(source) == 0:
            raise AnsibleActionFail(f"Source file is empty: {source}")
        new_args = self._task.args.copy()
        new_args['src'] = source
        return self._execute_module(
            module_name='ansible.builtin.copy',
            module_args=new_args, task_vars=task_vars,
        )
```

### Callback Plugins

Callback plugins respond to playbook events for logging, notifications, or metrics.

```python
# plugins/callback/slack_notify.py
from ansible.plugins.callback import CallbackBase
import json, urllib.request

DOCUMENTATION = '''
    name: slack_notify
    type: notification
    short_description: Send Slack notifications on play events
    options:
        webhook_url:
            description: Slack incoming webhook URL
            env: [{ name: SLACK_WEBHOOK_URL }]
            required: true
'''

class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'notification'
    CALLBACK_NAME = 'slack_notify'
    CALLBACK_NEEDS_ENABLED = True

    def set_options(self, task_keys=None, var_options=None, direct=None):
        super().set_options(task_keys=task_keys, var_options=var_options, direct=direct)
        self.webhook_url = self.get_option('webhook_url')

    def _post_slack(self, message, color='good'):
        payload = {'attachments': [{'color': color, 'text': message}]}
        data = json.dumps(payload).encode('utf-8')
        req = urllib.request.Request(self.webhook_url, data=data,
                                     headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req)

    def v2_runner_on_failed(self, result, ignore_errors=False):
        if not ignore_errors:
            host = result._host.get_name()
            self._post_slack(f':x: Failed on *{host}*: `{result._task.get_name()}`', 'danger')

    def v2_playbook_on_stats(self, stats):
        hosts = sorted(stats.processed.keys())
        parts = [f'{h}: ok={stats.summarize(h)["ok"]} fail={stats.summarize(h)["failures"]}' for h in hosts]
        self._post_slack(f':bar_chart: Complete:\n```{"chr(10)".join(parts)}```')
```

Enable: `callbacks_enabled = slack_notify` in `ansible.cfg`.

### Filter and Lookup Plugins

```python
# plugins/filter/network_filters.py
class FilterModule:
    def filters(self):
        return {
            'cidr_to_netmask': self.cidr_to_netmask,
            'is_private_ip': self.is_private_ip,
        }

    @staticmethod
    def cidr_to_netmask(cidr):
        mask = (0xFFFFFFFF >> (32 - int(cidr))) << (32 - int(cidr))
        return '.'.join([str((mask >> (8 * i)) & 0xFF) for i in range(3, -1, -1)])

    @staticmethod
    def is_private_ip(ip):
        p = list(map(int, ip.split('.')))
        return p[0] == 10 or (p[0] == 172 and 16 <= p[1] <= 31) or (p[0] == 192 and p[1] == 168)
```

```python
# plugins/lookup/consul_kv.py
from ansible.plugins.lookup import LookupBase
from ansible.errors import AnsibleLookupError
import json, urllib.request

class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        self.set_options(var_options=variables, direct=kwargs)
        consul_url = self.get_option('consul_url')
        results = []
        for term in terms:
            try:
                resp = urllib.request.urlopen(f'{consul_url}/v1/kv/{term}?raw')
                results.append(resp.read().decode('utf-8'))
            except Exception as e:
                raise AnsibleLookupError(f'Error looking up {term}: {e}')
        return results
```

### Custom Module with Check Mode

```python
# plugins/modules/app_config.py
from ansible.module_utils.basic import AnsibleModule
import json, os

def main():
    module = AnsibleModule(
        argument_spec=dict(
            path=dict(required=True, type='path'),
            settings=dict(required=True, type='dict'),
            backup=dict(type='bool', default=False),
        ),
        supports_check_mode=True,
    )
    path, settings = module.params['path'], module.params['settings']
    existing = json.load(open(path)) if os.path.exists(path) else {}
    merged = {**existing, **settings}
    changed = merged != existing
    result = {'changed': changed, 'path': path}
    if changed and module.check_mode:
        result['diff'] = {'before': json.dumps(existing, indent=2), 'after': json.dumps(merged, indent=2)}
        module.exit_json(**result)
    if changed:
        if module.params['backup'] and os.path.exists(path):
            result['backup_file'] = module.backup_local(path)
        json.dump(merged, open(path, 'w'), indent=2)
    module.exit_json(**result)

if __name__ == '__main__':
    main()
```

---

## Dynamic Inventory Scripts

### AWS (`amazon.aws.aws_ec2`)

```yaml
# inventory/aws_ec2.yml
plugin: amazon.aws.aws_ec2
regions: [us-east-1, us-west-2]
keyed_groups:
  - { key: "tags.Environment", prefix: env, separator: '_' }
  - { key: instance_type, prefix: instance_type }
groups:
  webservers: "'web' in (tags.Role | default(''))"
filters:
  instance-state-name: running
  "tag:ManagedBy": ansible
compose:
  ansible_host: private_ip_address
```

### GCP (`google.cloud.gcp_compute`)

```yaml
plugin: google.cloud.gcp_compute
projects: [my-gcp-project-id]
zones: [us-central1-a, us-east1-b]
filters: ["status = RUNNING"]
keyed_groups:
  - { key: "labels.environment", prefix: env }
compose:
  ansible_host: networkInterfaces[0].networkIP
auth_kind: serviceaccount
service_account_file: /etc/ansible/gcp-sa.json
```

### Azure (`azure.azcollection.azure_rm`)

```yaml
plugin: azure.azcollection.azure_rm
auth_source: auto
include_vm_resource_groups: [production-rg, staging-rg]
keyed_groups:
  - { key: "tags.environment | default('untagged')", prefix: env }
conditional_groups:
  webservers: "'web' in (tags.role | default(''))"
hostvar_expressions:
  ansible_host: private_ipv4_addresses[0]
```

---

## Ansible Collections Development

### Collection Structure

```
namespace/collection_name/
├── galaxy.yml          # Metadata (namespace, name, version, dependencies)
├── meta/runtime.yml    # Plugin routing, deprecations, requires_ansible
├── plugins/
│   ├── modules/        # Custom modules
│   ├── inventory/      # Inventory plugins
│   ├── callback/       # Callback plugins
│   ├── filter/         # Filter plugins
│   └── lookup/         # Lookup plugins
├── roles/              # Bundled roles
└── tests/              # Integration, unit, sanity tests
```

```yaml
# galaxy.yml
namespace: mycompany
name: infrastructure
version: 1.2.0
dependencies: { "ansible.builtin": ">=2.15.0", "community.general": ">=8.0.0" }
```

```bash
ansible-galaxy collection build                             # Build tarball
ansible-galaxy collection install ./mycompany-infrastructure-1.2.0.tar.gz -p ./collections
ansible-galaxy collection publish ./mycompany-infrastructure-1.2.0.tar.gz --api-key "$KEY"
ansible-test sanity --docker default                        # Sanity tests
ansible-test units --docker default                         # Unit tests
ansible-test integration --docker default my_module_name    # Integration tests
```

---

## Molecule Testing Deep Dive

### Drivers and Platforms

```yaml
# molecule/default/molecule.yml — Docker driver
driver:
  name: docker
platforms:
  - name: ubuntu-test
    image: geerlingguy/docker-ubuntu2204-ansible
    pre_build_image: true
    privileged: true
    volumes: ["/sys/fs/cgroup:/sys/fs/cgroup:rw"]
    cgroupns_mode: host
  - name: rocky-test
    image: geerlingguy/docker-rockylinux9-ansible
    pre_build_image: true
    privileged: true
```

### Scenarios and Verifiers

```yaml
# molecule/default/molecule.yml
provisioner:
  name: ansible
  playbooks:
    prepare: prepare.yml      # Pre-converge setup
    converge: converge.yml    # Run the role
    verify: verify.yml        # Assert expected state
verifier:
  name: ansible
scenario:
  test_sequence: [dependency, lint, destroy, syntax, create, prepare,
                  converge, idempotence, verify, destroy]
```

```yaml
# molecule/default/verify.yml
- name: Verify
  hosts: all
  become: true
  tasks:
    - name: Check service running
      ansible.builtin.service_facts:
    - name: Assert nginx is running
      ansible.builtin.assert:
        that:
          - "'nginx.service' in services"
          - "services['nginx.service']['state'] == 'running'"
    - name: Check port 80
      ansible.builtin.wait_for: { port: 80, timeout: 10 }
```

### Multi-Platform CI

```yaml
# .github/workflows/molecule.yml
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        distro: [ubuntu2204, ubuntu2004, rockylinux9, debian12]
    steps:
      - uses: actions/checkout@v4
      - run: pip install molecule molecule-plugins[docker] ansible-lint
      - run: molecule test
        env: { MOLECULE_DISTRO: "${{ matrix.distro }}" }
```

---

## Role Dependencies and Meta

```yaml
# roles/webserver/meta/main.yml
galaxy_info:
  role_name: webserver
  min_ansible_version: "2.15"
  platforms:
    - { name: Ubuntu, versions: [jammy, noble] }
    - { name: EL, versions: [8, 9] }

dependencies:
  - role: common
    vars: { common_timezone: UTC }
  - role: firewall
    vars: { firewall_allowed_ports: ["80/tcp", "443/tcp"] }
  - role: ssl_certificates
    when: webserver_ssl_enabled | default(true)

# Parameterized role with allow_duplicates
  - role: virtual_host
    vars: { vhost_name: api.example.com, vhost_port: 8080 }
    allow_duplicates: true
```

Use `include_role` for runtime conditional dependencies instead of static `dependencies`.

---

## Complex Variable Precedence

Full order (lowest → highest, 22 levels):

1. Command-line values (`-u user`)
2. Role defaults (`defaults/main.yml`)
3. Inventory file group vars
4. Inventory `group_vars/all` → 5. Playbook `group_vars/all`
6. Inventory `group_vars/*` → 7. Playbook `group_vars/*`
8. Inventory file host vars
9. Inventory `host_vars/*` → 10. Playbook `host_vars/*`
11. Host facts / cached `set_fact`
12. Play `vars` → 13. `vars_prompt` → 14. `vars_files`
15. Role vars (`vars/main.yml`) → 16. Block vars → 17. Task vars
18. `include_vars` → 19. `set_fact` / registered vars
20. Role parameters → 21. Include parameters
22. **Extra vars (`-e`)** — always wins

**Key pitfalls:**
- Role `vars/` (level 15) overrides inventory vars — use `defaults/` for overridable values
- `set_fact` persists across plays for the same host
- `hash_behaviour=merge` is global — prefer `combine(recursive=True)` filter

```yaml
# Explicit merge instead of global hash_behaviour
- ansible.builtin.set_fact:
    config: "{{ defaults | combine(overrides, recursive=True) }}"
```

---

## Jinja2 Advanced Techniques

### Macros

```jinja2
{# templates/macros/nginx.j2 #}
{% macro upstream_block(name, servers, port=8080) %}
upstream {{ name }} {
{% for server in servers %}
    server {{ hostvars[server]['ansible_host'] }}:{{ port }};
{% endfor %}
}
{% endmacro %}

{% macro server_block(name, listen_port=80, upstream=none, ssl=false) %}
server {
    listen {{ listen_port }}{% if ssl %} ssl{% endif %};
    server_name {{ name }};
    {% if ssl %}
    ssl_certificate /etc/letsencrypt/live/{{ name }}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{ name }}/privkey.pem;
    {% endif %}
    {% if upstream %}
    location / { proxy_pass http://{{ upstream }}; }
    {% endif %}
}
{% endmacro %}
```

### Template Inheritance

```jinja2
{# base_config.j2 #}
# Managed by Ansible - DO NOT EDIT
{% block header %}{% endblock %}
{% block main %}{% endblock %}

{# app_config.j2 #}
{% extends "base_config.j2" %}
{% block main %}
[database]
host = {{ db_host }}
port = {{ db_port | default(5432) }}
{% endblock %}
```

### Advanced Filter Chains

```yaml
# Complex data transformations
active_ips: >-
  {{ groups['appservers']
     | map('extract', hostvars, 'ansible_host')
     | select('defined') | list | join(',') }}

merged_config: >-
  {{ defaults | combine(env_overrides, recursive=True)
              | combine(host_overrides, recursive=True) }}

nginx_upstreams: >-
  {{ services | selectattr('type', 'equalto', 'web')
     | map(attribute='endpoints') | flatten | unique | sort | list }}
```

---

## Performance Optimization

### Pipelining and SSH Tuning

```ini
[ssh_connection]
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o PreferredAuthentications=publickey
control_path_dir = ~/.ansible/cp
```

Requires `!requiretty` in `/etc/sudoers`.

### Mitogen Strategy (2–7× speedup)

```ini
[defaults]
strategy_plugins = /path/to/mitogen/ansible_mitogen/plugins/strategy
strategy = mitogen_linear
```

### Fact Caching

```ini
[defaults]
gathering = smart
fact_caching = jsonfile                      # or redis
fact_caching_connection = /tmp/ansible_facts # or localhost:6379:0
fact_caching_timeout = 86400
```

### Async for Slow Tasks

```yaml
- ansible.builtin.apt: { upgrade: dist }
  async: 3600
  poll: 0
  register: apt_job

- ansible.builtin.async_status:
    jid: "{{ apt_job.ansible_job_id }}"
  until: result.finished
  retries: 120
  delay: 30
  register: result
```

### General Tips

- Increase `forks` (default 5 → 50+)
- Use `strategy: free` when host order doesn't matter
- Batch package installs as list instead of loop
- Limit facts: `gather_subset: ['!all', '!min', network]`

---

## AWX/AAP Workflows and Surveys

### Workflow Job Templates

```yaml
- awx.awx.workflow_job_template:
    name: "Full Deployment Pipeline"
    organization: "Engineering"
    survey_enabled: true
    survey_spec: "{{ lookup('file', 'survey_spec.json') }}"

- awx.awx.workflow_job_template_node:
    workflow_job_template: "Full Deployment Pipeline"
    identifier: "deploy"
    unified_job_template: "Deploy Application"
    success_nodes: ["smoke_test"]
    failure_nodes: ["rollback"]
```

### Surveys

```json
{
  "spec": [
    { "variable": "deploy_env", "type": "multiplechoice", "choices": ["staging", "production"], "required": true },
    { "variable": "app_version", "type": "text", "required": true, "min": 5, "max": 20 },
    { "variable": "run_migrations", "type": "multiplechoice", "choices": ["yes", "no"], "default": "no" }
  ]
}
```

### Execution Environments

```yaml
# execution-environment.yml
version: 3
dependencies:
  galaxy: { collections: [amazon.aws, community.docker] }
  python: [boto3>=1.28.0, docker>=6.0.0]
  system: [openssh-clients]
images:
  base_image: { name: quay.io/ansible/ansible-runner:latest }
```

Build: `ansible-builder build --tag mycompany/ee-deploy:latest --container-runtime docker`

---

## Ansible Navigator

Modern TUI replacement for `ansible-playbook`:

```bash
ansible-navigator run site.yml -i inventory/ --mode stdout  # CLI mode
ansible-navigator run site.yml -i inventory/                 # Interactive TUI
ansible-navigator images                                     # Inspect EEs
ansible-navigator doc ansible.builtin.copy                   # Browse docs
ansible-navigator replay /tmp/artifact.json                  # Replay runs
```

```yaml
# ansible-navigator.yml
ansible-navigator:
  execution-environment:
    enabled: true
    image: mycompany/ee-deploy:latest
    pull: { policy: missing }
  mode: stdout
  playbook-artifact:
    enable: true
    save-as: ./artifacts/{playbook_name}-{ts_utc}.json
```
