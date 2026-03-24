# Advanced Ansible Patterns

> Dense reference for custom modules, plugins, dynamic inventory, execution environments, collections development, and integration patterns.

## Table of Contents

- [Custom Modules (Python)](#custom-modules-python)
- [Custom Filter Plugins](#custom-filter-plugins)
- [Custom Lookup Plugins](#custom-lookup-plugins)
- [Callback Plugins](#callback-plugins)
- [Connection Plugins](#connection-plugins)
- [Strategy Plugins](#strategy-plugins)
- [Inventory Plugins](#inventory-plugins)
- [Dynamic Inventory Scripts](#dynamic-inventory-scripts)
- [Collections Development](#collections-development)
- [Execution Environments](#execution-environments)
- [Ansible Navigator](#ansible-navigator)
- [Role Testing with Molecule](#role-testing-with-molecule)
- [Ansible + Terraform Integration](#ansible--terraform-integration)

---

## Custom Modules (Python)

Custom modules live in `library/` at playbook level or `plugins/modules/` in collections.

### Minimal Module Skeleton

```python
#!/usr/bin/python
# -*- coding: utf-8 -*-

from ansible.module_utils.basic import AnsibleModule

DOCUMENTATION = r'''
---
module: my_app_config
short_description: Manage application configuration
description:
  - Creates or updates application config files with validation.
version_added: "1.0.0"
options:
  path:
    description: Path to the config file.
    required: true
    type: str
  settings:
    description: Dictionary of key-value settings.
    required: true
    type: dict
  backup:
    description: Create backup before modifying.
    required: false
    type: bool
    default: true
author:
  - Your Name (@github)
'''

EXAMPLES = r'''
- name: Configure application
  my_app_config:
    path: /etc/myapp/config.yml
    settings:
      db_host: db.example.com
      db_port: 5432
    backup: true
'''

RETURN = r'''
changed:
  description: Whether the config was modified.
  type: bool
backup_path:
  description: Path to the backup file if created.
  type: str
  returned: when backup=true and file existed
'''


def run_module():
    module_args = dict(
        path=dict(type='str', required=True),
        settings=dict(type='dict', required=True),
        backup=dict(type='bool', default=True),
    )

    module = AnsibleModule(
        argument_spec=module_args,
        supports_check_mode=True,
    )

    path = module.params['path']
    settings = module.params['settings']
    backup = module.params['backup']

    result = dict(changed=False, path=path)

    # Read existing config
    import os
    import json

    current = {}
    if os.path.exists(path):
        try:
            with open(path, 'r') as f:
                current = json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            module.fail_json(msg=f"Failed to read {path}: {e}", **result)

    # Determine if changes needed
    if current != settings:
        result['changed'] = True
        result['diff'] = dict(before=current, after=settings)

        if module.check_mode:
            module.exit_json(**result)

        # Backup
        if backup and os.path.exists(path):
            backup_path = module.backup_local(path)
            result['backup_path'] = backup_path

        # Write new config
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'w') as f:
                json.dump(settings, f, indent=2)
        except IOError as e:
            module.fail_json(msg=f"Failed to write {path}: {e}", **result)

    module.exit_json(**result)


if __name__ == '__main__':
    run_module()
```

### Key Patterns

- **Always support `check_mode`** — return what would change without changing.
- **Use `module.fail_json(msg=...)`** for errors, `module.exit_json(**result)` for success.
- **Set `result['changed']`** accurately — this drives idempotency.
- **Include `diff`** for `--diff` mode support.
- **Use `module_utils`** for shared code across modules:

```python
# plugins/module_utils/my_api.py
class MyAPIClient:
    def __init__(self, base_url, token):
        self.base_url = base_url
        self.token = token
    def get(self, endpoint):
        # shared HTTP logic
        ...

# In module:
from ansible_collections.myns.mycoll.plugins.module_utils.my_api import MyAPIClient
```

### Testing Custom Modules

```python
# tests/unit/plugins/modules/test_my_app_config.py
import pytest
from unittest.mock import patch, mock_open
from plugins.modules.my_app_config import run_module

@pytest.fixture
def module_args():
    return {
        'path': '/etc/myapp/config.yml',
        'settings': {'key': 'value'},
        'backup': False,
    }

def test_create_new_config(module_args):
    with patch('plugins.modules.my_app_config.AnsibleModule') as mock_mod:
        mock_mod.return_value.params = module_args
        mock_mod.return_value.check_mode = False
        run_module()
        mock_mod.return_value.exit_json.assert_called_once()
        call_args = mock_mod.return_value.exit_json.call_args
        assert call_args[1]['changed'] is True
```

---

## Custom Filter Plugins

Place in `filter_plugins/` at playbook level or `plugins/filter/` in collections.

```python
# filter_plugins/netutils.py

class FilterModule:
    """Network utility filters."""

    def filters(self):
        return {
            'cidr_to_netmask': self.cidr_to_netmask,
            'increment_ip': self.increment_ip,
            'sort_by_key': self.sort_by_key,
            'flatten_dict': self.flatten_dict,
        }

    @staticmethod
    def cidr_to_netmask(cidr):
        """Convert CIDR prefix length to subnet mask. E.g., 24 → '255.255.255.0'"""
        bits = int(cidr)
        mask = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF
        return '.'.join(str((mask >> (8 * i)) & 0xFF) for i in range(3, -1, -1))

    @staticmethod
    def increment_ip(ip, offset=1):
        """Increment IP address by offset."""
        parts = list(map(int, ip.split('.')))
        num = sum(p << (8 * (3 - i)) for i, p in enumerate(parts))
        num += offset
        return '.'.join(str((num >> (8 * (3 - i))) & 0xFF) for i in range(4))

    @staticmethod
    def sort_by_key(items, key, reverse=False):
        """Sort list of dicts by key."""
        return sorted(items, key=lambda x: x.get(key, ''), reverse=reverse)

    @staticmethod
    def flatten_dict(d, parent_key='', sep='_'):
        """Flatten nested dict: {'a': {'b': 1}} → {'a_b': 1}"""
        items = []
        for k, v in d.items():
            new_key = f"{parent_key}{sep}{k}" if parent_key else k
            if isinstance(v, dict):
                items.extend(FilterModule.flatten_dict(v, new_key, sep).items())
            else:
                items.append((new_key, v))
        return dict(items)
```

Usage in templates/playbooks:

```yaml
- name: Set network mask
  ansible.builtin.set_fact:
    netmask: "{{ 24 | cidr_to_netmask }}"       # → 255.255.255.0
    next_ip: "{{ '10.0.1.5' | increment_ip(3) }}" # → 10.0.1.8

- name: Sort hosts by priority
  ansible.builtin.debug:
    msg: "{{ host_list | sort_by_key('priority') }}"
```

---

## Custom Lookup Plugins

Place in `lookup_plugins/` or `plugins/lookup/` in collections.

```python
# lookup_plugins/consul_kv.py

from ansible.errors import AnsibleError
from ansible.plugins.lookup import LookupBase

DOCUMENTATION = r'''
name: consul_kv
description: Look up values from Consul KV store.
options:
  _terms:
    description: Key paths in Consul.
  consul_url:
    description: Consul URL.
    default: http://localhost:8500
    env:
      - name: CONSUL_HTTP_ADDR
'''

class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        self.set_options(var_options=variables, direct=kwargs)
        consul_url = self.get_option('consul_url')
        ret = []
        for term in terms:
            try:
                import requests
                resp = requests.get(f"{consul_url}/v1/kv/{term}?raw")
                resp.raise_for_status()
                ret.append(resp.text)
            except Exception as e:
                raise AnsibleError(f"Consul lookup failed for '{term}': {e}")
        return ret
```

```yaml
# Usage
- name: Get DB password from Consul
  ansible.builtin.debug:
    msg: "{{ lookup('consul_kv', 'myapp/db_password', consul_url='http://consul:8500') }}"
```

---

## Callback Plugins

Control output formatting and event hooks. Place in `callback_plugins/` or `plugins/callback/`.

```python
# callback_plugins/slack_notify.py

from ansible.plugins.callback import CallbackBase
import json
import os

DOCUMENTATION = '''
name: slack_notify
type: notification
description: Send play results to Slack.
requirements:
  - SLACK_WEBHOOK_URL environment variable
'''

class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'notification'
    CALLBACK_NAME = 'slack_notify'
    CALLBACK_NEEDS_ENABLED = True  # must enable in ansible.cfg

    def __init__(self):
        super().__init__()
        self.webhook = os.environ.get('SLACK_WEBHOOK_URL')
        self.results = {'ok': 0, 'changed': 0, 'failed': 0, 'skipped': 0}

    def v2_runner_on_ok(self, result, **kwargs):
        if result._result.get('changed', False):
            self.results['changed'] += 1
        else:
            self.results['ok'] += 1

    def v2_runner_on_failed(self, result, ignore_errors=False, **kwargs):
        if not ignore_errors:
            self.results['failed'] += 1

    def v2_playbook_on_stats(self, stats):
        if not self.webhook:
            return
        import urllib.request
        payload = json.dumps({
            'text': f"Ansible run complete: {self.results}"
        }).encode()
        req = urllib.request.Request(
            self.webhook, data=payload,
            headers={'Content-Type': 'application/json'}
        )
        urllib.request.urlopen(req)
```

Enable in `ansible.cfg`:

```ini
[defaults]
callbacks_enabled = slack_notify, timer, profile_tasks
```

### Callback Types

| Type | Purpose | Examples |
|------|---------|---------|
| `stdout` | Replace default output | `yaml`, `json`, `dense`, `minimal` |
| `notification` | Side-channel alerts | Slack, email, PagerDuty |
| `aggregate` | Collect stats | `timer`, `profile_tasks`, `profile_roles` |

---

## Connection Plugins

Override how Ansible connects to hosts. Built-in: `ssh`, `local`, `docker`, `winrm`, `network_cli`.

```yaml
# Use per-host in inventory
all:
  hosts:
    container1:
      ansible_connection: community.docker.docker
      ansible_docker_extra_args: "--tls"
    bastion_target:
      ansible_connection: ansible.builtin.ssh
      ansible_ssh_common_args: '-o ProxyJump=bastion.example.com'
    win_host:
      ansible_connection: ansible.builtin.winrm
      ansible_winrm_transport: ntlm
      ansible_winrm_server_cert_validation: ignore
```

---

## Strategy Plugins

Control task execution order across hosts.

| Strategy | Behavior | Use Case |
|----------|----------|----------|
| `linear` (default) | All hosts execute task N before task N+1 | Standard deploys |
| `free` | Each host proceeds independently | Independent hosts, speed |
| `debug` | Interactive debugger on failures | Development |
| `host_pinned` | Like free but groups by host | Mixed workloads |
| `mitogen_linear` | Linear via Mitogen (2-7x faster) | Performance |

```yaml
# Per-play strategy
- name: Fast independent setup
  hosts: all
  strategy: free
  tasks: [...]

# Debug strategy (interactive)
- name: Debug failing play
  hosts: problem_host
  strategy: debug
  tasks: [...]
# At debug prompt: p task.args, p result._result, redo, continue, quit
```

```ini
# ansible.cfg — set default
[defaults]
strategy = linear
# strategy_plugins = ./strategy_plugins  # custom strategy path
```

---

## Inventory Plugins

### AWS EC2

```yaml
# inventory/aws_ec2.yml
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1
  - us-west-2
filters:
  tag:Environment:
    - production
    - staging
  instance-state-name: running
keyed_groups:
  - key: tags.Environment
    prefix: env
    separator: "_"
  - key: instance_type
    prefix: type
  - key: placement.availability_zone
    prefix: az
compose:
  ansible_host: private_ip_address
  instance_name: tags.Name
hostnames:
  - tag:Name
  - private-ip-address
```

### GCP Compute

```yaml
# inventory/gcp_compute.yml
plugin: google.cloud.gcp_compute
projects:
  - my-gcp-project
zones:
  - us-central1-a
  - us-central1-b
filters:
  - status = RUNNING
  - labels.env = production
keyed_groups:
  - key: labels.env
    prefix: env
  - key: zone
    prefix: zone
compose:
  ansible_host: networkInterfaces[0].accessConfigs[0].natIP
auth_kind: serviceaccount
service_account_file: /path/to/sa.json
```

### Azure RM

```yaml
# inventory/azure_rm.yml
plugin: azure.azcollection.azure_rm
auth_source: auto
include_vm_resource_groups:
  - my-resource-group
keyed_groups:
  - key: tags.environment | default('untagged')
    prefix: env
  - key: location
    prefix: region
  - key: os_profile.system | default('linux')
    prefix: os
conditional_groups:
  webservers: "'web' in tags.role | default('')"
compose:
  ansible_host: private_ipv4_addresses[0]
```

Enable plugins in `ansible.cfg`:

```ini
[inventory]
enable_plugins = host_list, script, auto, yaml, ini, toml,
    amazon.aws.aws_ec2, google.cloud.gcp_compute, azure.azcollection.azure_rm
```

---

## Dynamic Inventory Scripts

Legacy approach (prefer inventory plugins). Script must output JSON on `--list` and `--host <hostname>`.

```python
#!/usr/bin/env python3
"""Dynamic inventory from internal CMDB API."""

import argparse
import json
import requests
import sys

CMDB_URL = "https://cmdb.internal/api/v1"

def get_inventory():
    resp = requests.get(f"{CMDB_URL}/hosts", headers={"Accept": "application/json"})
    resp.raise_for_status()
    hosts = resp.json()

    inventory = {"_meta": {"hostvars": {}}}

    for host in hosts:
        group = host.get("role", "ungrouped")
        inventory.setdefault(group, {"hosts": [], "vars": {}})
        inventory[group]["hosts"].append(host["fqdn"])
        inventory["_meta"]["hostvars"][host["fqdn"]] = {
            "ansible_host": host["ip"],
            "ansible_port": host.get("ssh_port", 22),
            "datacenter": host.get("dc", "unknown"),
        }

    return inventory

def get_host(hostname):
    resp = requests.get(f"{CMDB_URL}/hosts/{hostname}")
    resp.raise_for_status()
    return resp.json()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--host")
    args = parser.parse_args()

    if args.list:
        print(json.dumps(get_inventory(), indent=2))
    elif args.host:
        print(json.dumps(get_host(args.host), indent=2))
    else:
        parser.print_help()
        sys.exit(1)
```

```bash
chmod +x inventory/cmdb.py
ansible-playbook -i inventory/cmdb.py site.yml
```

---

## Collections Development

### Collection Structure

```
my_namespace/my_collection/
├── galaxy.yml              # metadata
├── README.md
├── plugins/
│   ├── modules/            # custom modules
│   ├── module_utils/       # shared Python code
│   ├── inventory/          # inventory plugins
│   ├── callback/           # callback plugins
│   ├── filter/             # filter plugins
│   └── lookup/             # lookup plugins
├── roles/
│   └── my_role/
├── playbooks/
├── docs/
├── tests/
│   ├── unit/
│   ├── integration/
│   └── sanity/
├── changelogs/
│   └── changelog.yaml
└── meta/
    └── runtime.yml         # deprecations, redirects
```

### galaxy.yml

```yaml
namespace: mycompany
name: infrastructure
version: 1.2.0
readme: README.md
authors:
  - Platform Team <platform@company.com>
description: Internal infrastructure automation collection
license: GPL-3.0-or-later
tags: [infrastructure, networking, security]
dependencies:
  ansible.netcommon: ">=5.0.0"
  community.general: ">=8.0.0"
repository: https://github.com/mycompany/ansible-infrastructure
```

### Build and Publish

```bash
# Build
ansible-galaxy collection build
# → mycompany-infrastructure-1.2.0.tar.gz

# Publish to Galaxy
ansible-galaxy collection publish mycompany-infrastructure-1.2.0.tar.gz --api-key=$GALAXY_TOKEN

# Publish to private Automation Hub
ansible-galaxy collection publish mycompany-infrastructure-1.2.0.tar.gz \
  --server https://hub.internal/api/galaxy/content/published/ \
  --api-key=$HUB_TOKEN

# Install from private source
ansible-galaxy collection install mycompany.infrastructure \
  --server https://hub.internal/api/galaxy/content/published/
```

### meta/runtime.yml — Redirects and Deprecations

```yaml
requires_ansible: ">=2.14.0"
plugin_routing:
  modules:
    old_module_name:
      redirect: mycompany.infrastructure.new_module_name
      deprecation:
        removal_version: "2.0.0"
        warning_text: "Use new_module_name instead"
```

---

## Execution Environments

Container images with Ansible + dependencies. Built with `ansible-builder`.

### execution-environment.yml

```yaml
---
version: 3
dependencies:
  galaxy: requirements.yml
  python: requirements.txt
  system: bindep.txt

build_arg_defaults:
  ANSIBLE_GALAXY_CLI_COLLECTION_OPTS: "--pre"

images:
  base_image:
    name: quay.io/ansible/ansible-runner:latest

additional_build_steps:
  prepend_galaxy:
    - ADD galaxy-certs/ /usr/share/pki/ca-trust-source/anchors/
    - RUN update-ca-trust
  append_final:
    - RUN microdnf install -y gcc python3-devel
    - COPY --from=quay.io/ansible/receptor:latest /usr/bin/receptor /usr/bin/receptor
```

```bash
# Build EE
pip install ansible-builder
ansible-builder build --tag mycompany/ee-prod:1.0 --container-runtime podman

# Run playbook in EE
ansible-navigator run site.yml --eei mycompany/ee-prod:1.0 --mode stdout
```

---

## Ansible Navigator

Interactive TUI replacement for `ansible-playbook`, `ansible-doc`, `ansible-inventory`.

```bash
pip install ansible-navigator

# Run playbook
ansible-navigator run site.yml --mode stdout          # non-interactive
ansible-navigator run site.yml --mode interactive      # TUI

# Explore docs
ansible-navigator doc ansible.builtin.copy
ansible-navigator collections

# Inspect inventory
ansible-navigator inventory -i inventory/ --mode interactive

# Replay past runs
ansible-navigator replay /path/to/artifact.json
```

### ansible-navigator.yml (project config)

```yaml
ansible-navigator:
  execution-environment:
    container-engine: podman
    enabled: true
    image: mycompany/ee-prod:1.0
    pull:
      policy: missing
  logging:
    level: debug
    file: /tmp/navigator.log
  playbook-artifact:
    enable: true
    save-as: artifacts/{playbook_name}-{ts_utc}.json
  mode: stdout
```

---

## Role Testing with Molecule

### Full Molecule Setup

```bash
pip install molecule molecule-plugins[docker] ansible-lint pytest-testinfra
cd roles/my_role/
molecule init scenario --driver-name docker
```

### molecule/default/molecule.yml

```yaml
dependency:
  name: galaxy
  options:
    requirements-file: requirements.yml
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
  inventory:
    group_vars:
      all:
        test_var: molecule_test
  lint:
    name: ansible-lint
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
    - side_effect
    - verify
    - cleanup
    - destroy
```

### molecule/default/converge.yml

```yaml
- name: Converge
  hosts: all
  become: true
  roles:
    - role: my_role
      vars:
        my_role_setting: test_value
```

### molecule/default/verify.yml

```yaml
- name: Verify
  hosts: all
  become: true
  tasks:
    - name: Check service is running
      ansible.builtin.service_facts:

    - name: Assert service active
      ansible.builtin.assert:
        that:
          - "'myservice.service' in services"
          - "services['myservice.service'].state == 'running'"
        fail_msg: "myservice is not running"

    - name: Check config file content
      ansible.builtin.slurp:
        src: /etc/myapp/config.yml
      register: config_content

    - name: Validate config
      ansible.builtin.assert:
        that:
          - "'db_host' in (config_content.content | b64decode)"
```

### CI Integration (GitHub Actions)

```yaml
name: Molecule Test
on: [push, pull_request]
jobs:
  molecule:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        scenario: [default, centos]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.11' }
      - run: pip install molecule molecule-plugins[docker] ansible-lint
      - run: molecule test -s ${{ matrix.scenario }}
        working-directory: roles/my_role
```

---

## Ansible + Terraform Integration

### Pattern 1: Terraform Provisions, Ansible Configures

```hcl
# terraform/main.tf
resource "aws_instance" "web" {
  count         = 3
  ami           = "ami-0abcdef1234567890"
  instance_type = "t3.medium"
  key_name      = "deploy-key"

  tags = {
    Name        = "web-${count.index}"
    Role        = "webserver"
    Environment = "production"
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo '${self.private_ip} ansible_user=ubuntu' >> ../inventory/terraform_hosts
    EOT
  }
}

# Output for Ansible dynamic inventory
output "web_ips" {
  value = aws_instance.web[*].private_ip
}
```

### Pattern 2: Terraform Dynamic Inventory via Plugin

```yaml
# inventory/terraform.yml
plugin: cloud.terraform.terraform_provider
project_path: ../terraform/
```

### Pattern 3: Ansible Calling Terraform

```yaml
- name: Provision infrastructure
  hosts: localhost
  tasks:
    - name: Run Terraform
      community.general.terraform:
        project_path: "{{ playbook_dir }}/../terraform"
        state: present
        variables:
          environment: "{{ env }}"
          instance_count: "{{ instance_count }}"
      register: tf_output

    - name: Add provisioned hosts
      ansible.builtin.add_host:
        name: "{{ item }}"
        groups: new_instances
        ansible_user: ubuntu
      loop: "{{ tf_output.outputs.web_ips.value }}"

- name: Configure new instances
  hosts: new_instances
  become: true
  roles:
    - common
    - webserver
```

### Pattern 4: Shared State

```yaml
# Read Terraform state for inventory data
- name: Read Terraform outputs
  ansible.builtin.command: terraform output -json
  args:
    chdir: "{{ terraform_dir }}"
  register: tf_state
  delegate_to: localhost
  changed_when: false

- name: Parse outputs
  ansible.builtin.set_fact:
    infra: "{{ tf_state.stdout | from_json }}"
```

### Best Practices for Integration

1. **Terraform owns infrastructure** (VMs, networks, LBs, DNS). **Ansible owns configuration** (packages, services, files).
2. Use Terraform outputs as Ansible inventory source.
3. Store Terraform state remotely (S3, GCS) so Ansible can read it.
4. Run Terraform before Ansible in CI pipelines.
5. Use `cloud.terraform` collection for tight integration.
6. Tag resources in Terraform to drive Ansible dynamic inventory grouping.
