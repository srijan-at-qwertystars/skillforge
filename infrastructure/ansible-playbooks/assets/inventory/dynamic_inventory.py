#!/usr/bin/env python3
"""Dynamic inventory script template for Ansible.

This script demonstrates the interface for a custom dynamic inventory.
Replace the get_inventory() function with your own logic to query
an API, database, or cloud provider.

Usage:
  ./dynamic_inventory.py --list      # Return full inventory JSON
  ./dynamic_inventory.py --host HOST # Return host variables for HOST

The script must output valid JSON. Use --list for the full inventory
and --host for per-host variables.

Make executable: chmod +x dynamic_inventory.py
Configure in ansible.cfg:
  [defaults]
  inventory = ./dynamic_inventory.py
"""

import argparse
import json
import os
import sys


def get_inventory():
    """Build and return the inventory dictionary.

    Replace this function with your own logic to query an API, CMDB,
    cloud provider, or database.

    Returns:
        dict: Ansible inventory in the expected JSON format.
    """
    # Example: read configuration from environment
    env = os.getenv('DEPLOY_ENV', 'staging')

    inventory = {
        # _meta with hostvars avoids per-host --host calls
        '_meta': {
            'hostvars': {
                'web1.example.com': {
                    'ansible_host': '10.0.1.10',
                    'ansible_user': 'deploy',
                    'http_port': 80,
                },
                'web2.example.com': {
                    'ansible_host': '10.0.1.11',
                    'ansible_user': 'deploy',
                    'http_port': 80,
                },
                'db1.example.com': {
                    'ansible_host': '10.0.3.10',
                    'ansible_user': 'postgres',
                    'pg_role': 'primary',
                },
            }
        },
        'webservers': {
            'hosts': ['web1.example.com', 'web2.example.com'],
            'vars': {
                'nginx_worker_processes': 'auto',
            },
        },
        'dbservers': {
            'hosts': ['db1.example.com'],
            'vars': {
                'pg_version': '16',
            },
        },
        'all': {
            'vars': {
                'env': env,
                'ansible_python_interpreter': '/usr/bin/python3',
            },
        },
    }

    return inventory


def get_host_vars(hostname):
    """Return variables for a specific host.

    Args:
        hostname: The hostname to look up.

    Returns:
        dict: Variables for the host, or empty dict if not found.
    """
    inventory = get_inventory()
    return inventory.get('_meta', {}).get('hostvars', {}).get(hostname, {})


def main():
    parser = argparse.ArgumentParser(
        description='Ansible dynamic inventory script'
    )
    parser.add_argument(
        '--list',
        action='store_true',
        help='Return the full inventory',
    )
    parser.add_argument(
        '--host',
        type=str,
        help='Return variables for the specified host',
    )
    args = parser.parse_args()

    if args.list:
        output = get_inventory()
    elif args.host:
        output = get_host_vars(args.host)
    else:
        parser.print_help()
        sys.exit(1)

    print(json.dumps(output, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
