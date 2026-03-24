# Ansible Security Hardening

> Vault best practices, secret rotation, SSH management, compliance automation, and security-as-code patterns.

## Table of Contents

- [Vault Best Practices](#vault-best-practices)
- [Secret Rotation Automation](#secret-rotation-automation)
- [SSH Key Management](#ssh-key-management)
- [Least Privilege Playbooks](#least-privilege-playbooks)
- [CIS Benchmark Automation](#cis-benchmark-automation)
- [Security Scanning Integration](#security-scanning-integration)
- [Certificate Management](#certificate-management)
- [Firewall Rule Automation](#firewall-rule-automation)
- [User and Access Management](#user-and-access-management)
- [Audit Logging](#audit-logging)
- [Compliance as Code](#compliance-as-code)

---

## Vault Best Practices

### Multiple Vaults with vault-id

Separate secrets by environment or sensitivity level:

```bash
# Create environment-specific vaults
ansible-vault create --vault-id prod@prompt vault/prod.yml
ansible-vault create --vault-id staging@prompt vault/staging.yml
ansible-vault create --vault-id shared@prompt vault/shared.yml

# Encrypt inline strings with vault-id
ansible-vault encrypt_string --vault-id prod@prompt 'SuperSecret123' --name 'db_password'

# Run with multiple vault IDs
ansible-playbook site.yml \
  --vault-id prod@~/.vault/prod_pass \
  --vault-id staging@~/.vault/staging_pass \
  --vault-id shared@~/.vault/shared_pass
```

### Vault Password from External Sources

```bash
#!/bin/bash
# vault-pass-client.sh — fetch from HashiCorp Vault
export VAULT_ADDR="https://vault.internal:8200"
vault kv get -field=ansible_vault_pass secret/ansible/prod

#!/bin/bash
# vault-pass-aws.sh — fetch from AWS Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id ansible/vault-password \
  --query SecretString --output text

#!/bin/bash
# vault-pass-1password.sh — fetch from 1Password
op read "op://Infrastructure/Ansible Vault/password"
```

```ini
# ansible.cfg — use script as vault password
[defaults]
vault_password_file = ./vault-pass-client.sh
# Or multiple:
vault_identity_list = prod@vault-pass-prod.sh, dev@vault-pass-dev.sh
```

### Vault File Organization

```
vault/
├── prod_secrets.yml        # vault-id: prod
├── staging_secrets.yml     # vault-id: staging
├── shared_secrets.yml      # vault-id: shared
└── README.md               # documents vault structure (no secrets!)

# Keep encrypted and unencrypted vars separate
group_vars/
├── all/
│   ├── vars.yml            # plaintext variables
│   └── vault.yml           # vault-encrypted (prefix vars with vault_)
├── production/
│   ├── vars.yml
│   └── vault.yml
```

### Variable Indirection Pattern

```yaml
# group_vars/production/vault.yml (encrypted)
vault_db_password: "EncryptedValue"
vault_api_key: "EncryptedValue"

# group_vars/production/vars.yml (plaintext — easy to audit)
db_password: "{{ vault_db_password }}"
api_key: "{{ vault_api_key }}"
```

### Rekeying Strategy

```bash
# Rekey all vault files after team changes
find . -name "*.yml" -exec grep -l '^\$ANSIBLE_VAULT' {} \; | \
while read vault_file; do
  echo "Rekeying: $vault_file"
  ansible-vault rekey "$vault_file" \
    --vault-password-file=~/.vault/old_pass \
    --new-vault-password-file=~/.vault/new_pass
done

# Verify after rekey
ansible-vault view vault/prod.yml --vault-password-file=~/.vault/new_pass
```

### Vault Encryption at Rest

```yaml
# Encrypt specific variables inline (mixed files)
db_config:
  host: db.example.com        # plaintext
  port: 5432                   # plaintext
  password: !vault |
    $ANSIBLE_VAULT;1.2;AES256;prod
    66386439653236336462626566...
```

---

## Secret Rotation Automation

### Database Password Rotation

```yaml
- name: Rotate database passwords
  hosts: localhost
  vars:
    password_length: 32
  tasks:
    - name: Generate new password
      ansible.builtin.set_fact:
        new_db_password: "{{ lookup('password', '/dev/null length=' ~ password_length ~ ' chars=ascii_letters,digits,punctuation') }}"

    - name: Update database user password
      community.postgresql.postgresql_user:
        name: app_user
        password: "{{ new_db_password }}"
        login_host: "{{ db_host }}"
        login_user: postgres
        login_password: "{{ vault_postgres_admin_pass }}"

    - name: Update application config
      ansible.builtin.template:
        src: db-config.j2
        dest: /etc/myapp/db.conf
        mode: '0600'
        owner: appuser
      delegate_to: "{{ item }}"
      loop: "{{ groups['appservers'] }}"
      notify: restart application

    - name: Update vault with new password
      ansible.builtin.shell: |
        ansible-vault encrypt_string '{{ new_db_password }}' \
          --vault-id prod@~/.vault/prod_pass \
          --name 'vault_db_password'
      register: new_vault_string
      no_log: true

    - name: Store rotation timestamp
      ansible.builtin.lineinfile:
        path: /var/log/secret-rotation.log
        line: "{{ ansible_date_time.iso8601 }} - db_password rotated"
        create: true
        mode: '0600'
```

### API Key Rotation

```yaml
- name: Rotate API keys
  hosts: localhost
  tasks:
    - name: Generate new API key via provider
      ansible.builtin.uri:
        url: "https://api.provider.com/v1/keys/rotate"
        method: POST
        headers:
          Authorization: "Bearer {{ vault_admin_token }}"
        body_format: json
        body:
          key_id: "{{ current_key_id }}"
      register: new_key
      no_log: true

    - name: Deploy new key to app servers
      ansible.builtin.copy:
        content: "API_KEY={{ new_key.json.key }}"
        dest: /etc/myapp/api.env
        mode: '0600'
        owner: appuser
      delegate_to: "{{ item }}"
      loop: "{{ groups['appservers'] }}"
      no_log: true
      notify: restart application

    - name: Revoke old key
      ansible.builtin.uri:
        url: "https://api.provider.com/v1/keys/{{ current_key_id }}"
        method: DELETE
        headers:
          Authorization: "Bearer {{ vault_admin_token }}"
```

### Scheduled Rotation with AWX/Cron

```yaml
# AWX: Create job template with schedule (every 90 days)
# Cron fallback:
# 0 2 1 */3 * ansible-playbook /opt/ansible/rotate-secrets.yml --vault-password-file=/root/.vault_pass >> /var/log/rotation.log 2>&1
```

---

## SSH Key Management

### Key Distribution

```yaml
- name: Manage SSH keys
  hosts: all
  become: true
  vars:
    ssh_users:
      - name: deploy
        authorized_keys:
          - "ssh-ed25519 AAAA... deploy@ci"
          - "ssh-ed25519 AAAA... deploy@admin"
        state: present
      - name: former_employee
        authorized_keys: []
        state: absent
  tasks:
    - name: Manage user accounts
      ansible.builtin.user:
        name: "{{ item.name }}"
        state: "{{ item.state }}"
        shell: /bin/bash
        create_home: true
      loop: "{{ ssh_users }}"

    - name: Set authorized keys (exclusive — removes unlisted keys)
      ansible.posix.authorized_key:
        user: "{{ item.name }}"
        key: "{{ item.authorized_keys | join('\n') }}"
        exclusive: true  # removes keys not in list
        state: present
      loop: "{{ ssh_users }}"
      when: item.state == 'present' and item.authorized_keys | length > 0
```

### SSH Hardening

```yaml
- name: Harden SSH configuration
  hosts: all
  become: true
  tasks:
    - name: Configure sshd
      ansible.builtin.template:
        src: sshd_config.j2
        dest: /etc/ssh/sshd_config
        mode: '0600'
        owner: root
        validate: '/usr/sbin/sshd -t -f %s'
      notify: restart sshd

    - name: Disable root login
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?PermitRootLogin'
        line: 'PermitRootLogin no'
      notify: restart sshd

    - name: Disable password authentication
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?PasswordAuthentication'
        line: 'PasswordAuthentication no'
      notify: restart sshd

    - name: Set SSH idle timeout
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: "{{ item.regexp }}"
        line: "{{ item.line }}"
      loop:
        - { regexp: '^#?ClientAliveInterval', line: 'ClientAliveInterval 300' }
        - { regexp: '^#?ClientAliveCountMax', line: 'ClientAliveCountMax 2' }
      notify: restart sshd

    - name: Limit SSH access to specific groups
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?AllowGroups'
        line: 'AllowGroups sshusers admins'
      notify: restart sshd

  handlers:
    - name: restart sshd
      ansible.builtin.service: { name: sshd, state: restarted }
```

### Key Rotation

```yaml
- name: Rotate SSH host keys
  hosts: all
  become: true
  tasks:
    - name: Generate new host keys
      ansible.builtin.command: ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ''
      args:
        creates: /etc/ssh/ssh_host_ed25519_key.new
      notify: restart sshd

    - name: Remove weak host key types
      ansible.builtin.file:
        path: "/etc/ssh/{{ item }}"
        state: absent
      loop:
        - ssh_host_dsa_key
        - ssh_host_dsa_key.pub
      notify: restart sshd
```

---

## Least Privilege Playbooks

### Per-Task Become

```yaml
# WRONG: play-level become gives root to everything
- hosts: webservers
  become: true  # every task runs as root
  tasks: [...]

# RIGHT: per-task become — only elevate when needed
- hosts: webservers
  tasks:
    - name: Install packages (needs root)
      ansible.builtin.apt:
        name: [nginx, certbot]
        state: present
      become: true

    - name: Deploy app config (as app user)
      ansible.builtin.template:
        src: app.conf.j2
        dest: /home/appuser/app.conf
        owner: appuser
        mode: '0644'
      become: true
      become_user: appuser

    - name: Check app health (no privilege needed)
      ansible.builtin.uri:
        url: http://localhost:8080/health
      # no become — runs as ansible_user
```

### Restricted sudo Configuration

```yaml
# Deploy granular sudoers rules instead of blanket NOPASSWD ALL
- name: Configure minimal sudo for Ansible
  ansible.builtin.copy:
    dest: /etc/sudoers.d/ansible
    content: |
      # Ansible automation user — limited sudo
      ansible ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/systemctl, /usr/bin/tee
      ansible ALL=(appuser) NOPASSWD: /usr/local/bin/deploy.sh
    mode: '0440'
    validate: '/usr/sbin/visudo -cf %s'
```

### no_log for Sensitive Tasks

```yaml
- name: Set database password
  ansible.builtin.command: "mysql -e \"ALTER USER 'app'@'%' IDENTIFIED BY '{{ db_password }}'\""
  no_log: true  # prevents password appearing in logs/output

- name: Deploy secrets file
  ansible.builtin.template:
    src: secrets.env.j2
    dest: /etc/myapp/secrets.env
    mode: '0600'
    owner: appuser
    group: appuser
  no_log: true
  diff: false  # also hide diff output
```

---

## CIS Benchmark Automation

### CIS Level 1 — Filesystem

```yaml
- name: CIS filesystem hardening
  hosts: all
  become: true
  tasks:
    - name: "CIS 1.1.1 — Disable unused filesystems"
      ansible.builtin.copy:
        dest: /etc/modprobe.d/cis-filesystems.conf
        content: |
          install cramfs /bin/true
          install freevxfs /bin/true
          install jffs2 /bin/true
          install hfs /bin/true
          install hfsplus /bin/true
          install squashfs /bin/true
          install udf /bin/true
        mode: '0644'

    - name: "CIS 1.1.2 — Ensure /tmp is separate partition with noexec"
      ansible.posix.mount:
        path: /tmp
        src: tmpfs
        fstype: tmpfs
        opts: "defaults,nodev,nosuid,noexec,size=2G"
        state: mounted

    - name: "CIS 1.4.1 — Ensure permissions on bootloader config"
      ansible.builtin.file:
        path: /boot/grub/grub.cfg
        owner: root
        group: root
        mode: '0400'
      when: ansible_os_family == "Debian"
```

### CIS Level 1 — Network

```yaml
    - name: "CIS 3.1 — Network parameters"
      ansible.posix.sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_set: true
        state: present
        reload: true
      loop:
        - { key: 'net.ipv4.ip_forward', value: '0' }
        - { key: 'net.ipv4.conf.all.send_redirects', value: '0' }
        - { key: 'net.ipv4.conf.all.accept_source_route', value: '0' }
        - { key: 'net.ipv4.conf.all.accept_redirects', value: '0' }
        - { key: 'net.ipv4.conf.all.log_martians', value: '1' }
        - { key: 'net.ipv4.conf.all.rp_filter', value: '1' }
        - { key: 'net.ipv4.icmp_echo_ignore_broadcasts', value: '1' }
        - { key: 'net.ipv4.tcp_syncookies', value: '1' }
        - { key: 'net.ipv6.conf.all.accept_redirects', value: '0' }
```

### CIS Level 1 — Logging and Auditing

```yaml
    - name: "CIS 4.1 — Configure auditd"
      ansible.builtin.package:
        name: [auditd, audispd-plugins]
        state: present

    - name: "CIS 4.1.3 — Audit rules for privilege escalation"
      ansible.builtin.copy:
        dest: /etc/audit/rules.d/cis.rules
        content: |
          # Monitor sudo usage
          -a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k privilege_escalation
          # Monitor file permission changes
          -a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -k perm_mod
          # Monitor user/group changes
          -w /etc/passwd -p wa -k identity
          -w /etc/group -p wa -k identity
          -w /etc/shadow -p wa -k identity
          -w /etc/sudoers -p wa -k sudoers
          # Monitor SSH config
          -w /etc/ssh/sshd_config -p wa -k sshd_config
        mode: '0640'
      notify: restart auditd

  handlers:
    - name: restart auditd
      ansible.builtin.service: { name: auditd, state: restarted }
```

---

## Security Scanning Integration

### Trivy Container Scanning

```yaml
- name: Security scan containers
  hosts: localhost
  tasks:
    - name: Scan Docker images with Trivy
      ansible.builtin.command: >
        trivy image --severity HIGH,CRITICAL --format json
        --output /tmp/trivy-{{ item | replace(':', '-') | replace('/', '-') }}.json
        {{ item }}
      loop: "{{ docker_images }}"
      register: scan_results
      changed_when: false
      failed_when: false

    - name: Parse scan results
      ansible.builtin.set_fact:
        vulnerabilities: "{{ lookup('file', '/tmp/trivy-' ~ (item | replace(':', '-') | replace('/', '-')) ~ '.json') | from_json }}"
      loop: "{{ docker_images }}"
      register: parsed_results

    - name: Fail if critical vulnerabilities found
      ansible.builtin.fail:
        msg: "Critical vulnerabilities found in {{ item.item }}"
      loop: "{{ parsed_results.results }}"
      when: item.ansible_facts.vulnerabilities.Results | default([]) |
            selectattr('Vulnerabilities', 'defined') |
            map(attribute='Vulnerabilities') | flatten |
            selectattr('Severity', 'equalto', 'CRITICAL') | list | length > 0
```

### OSCAP (OpenSCAP) Integration

```yaml
- name: Run OpenSCAP compliance scan
  hosts: all
  become: true
  tasks:
    - name: Install OpenSCAP
      ansible.builtin.package:
        name: [openscap-scanner, scap-security-guide]
        state: present

    - name: Run SCAP scan
      ansible.builtin.command: >
        oscap xccdf eval
        --profile xccdf_org.ssgproject.content_profile_cis_level1_server
        --results /tmp/oscap-results.xml
        --report /tmp/oscap-report.html
        /usr/share/xml/scap/ssg/content/ssg-{{ ansible_distribution | lower }}{{ ansible_distribution_major_version }}-ds.xml
      register: oscap_result
      failed_when: false
      changed_when: false

    - name: Fetch report
      ansible.builtin.fetch:
        src: /tmp/oscap-report.html
        dest: "reports/{{ inventory_hostname }}-oscap.html"
        flat: true
```

---

## Certificate Management

### Let's Encrypt with Certbot

```yaml
- name: Manage TLS certificates
  hosts: webservers
  become: true
  vars:
    certbot_domains:
      - example.com
      - www.example.com
    certbot_email: admin@example.com
  tasks:
    - name: Install certbot
      ansible.builtin.package:
        name: [certbot, python3-certbot-nginx]
        state: present

    - name: Obtain certificate
      ansible.builtin.command: >
        certbot certonly --nginx --non-interactive --agree-tos
        --email {{ certbot_email }}
        -d {{ certbot_domains | join(' -d ') }}
      args:
        creates: "/etc/letsencrypt/live/{{ certbot_domains[0] }}/fullchain.pem"

    - name: Configure auto-renewal
      ansible.builtin.cron:
        name: certbot-renew
        special_time: daily
        job: "certbot renew --quiet --post-hook 'systemctl reload nginx'"

    - name: Check certificate expiry
      ansible.builtin.command: >
        openssl x509 -enddate -noout
        -in /etc/letsencrypt/live/{{ certbot_domains[0] }}/fullchain.pem
      register: cert_expiry
      changed_when: false

    - name: Alert if cert expires within 14 days
      ansible.builtin.debug:
        msg: "WARNING: Certificate expires {{ cert_expiry.stdout }}"
      when: cert_expiry.stdout | regex_replace('notAfter=', '') |
            to_datetime('%b %d %H:%M:%S %Y %Z') <
            (ansible_date_time.iso8601 | to_datetime('%Y-%m-%dT%H:%M:%SZ')) +
            (14 * 86400) | string | to_datetime
      failed_when: false
```

### Internal CA Certificate Distribution

```yaml
- name: Distribute internal CA certificates
  hosts: all
  become: true
  tasks:
    - name: Deploy internal CA cert
      ansible.builtin.copy:
        src: "certs/internal-ca.pem"
        dest: "/usr/local/share/ca-certificates/internal-ca.crt"
        mode: '0644'
      notify: update ca certificates

  handlers:
    - name: update ca certificates
      ansible.builtin.command: update-ca-certificates
      when: ansible_os_family == "Debian"

    - name: update ca trust
      ansible.builtin.command: update-ca-trust
      when: ansible_os_family == "RedHat"
```

---

## Firewall Rule Automation

### UFW (Ubuntu/Debian)

```yaml
- name: Configure UFW firewall
  hosts: all
  become: true
  vars:
    firewall_allowed_tcp: [22, 80, 443]
    firewall_allowed_from:
      - { src: "10.0.0.0/8", port: 5432, proto: tcp }  # DB from internal
  tasks:
    - name: Install UFW
      ansible.builtin.apt: { name: ufw, state: present }

    - name: Set default deny incoming
      community.general.ufw: { direction: incoming, default: deny }

    - name: Set default allow outgoing
      community.general.ufw: { direction: outgoing, default: allow }

    - name: Allow standard TCP ports
      community.general.ufw:
        rule: allow
        port: "{{ item }}"
        proto: tcp
      loop: "{{ firewall_allowed_tcp }}"

    - name: Allow specific source rules
      community.general.ufw:
        rule: allow
        from_ip: "{{ item.src }}"
        to_port: "{{ item.port }}"
        proto: "{{ item.proto }}"
      loop: "{{ firewall_allowed_from }}"

    - name: Enable UFW
      community.general.ufw: { state: enabled }
```

### firewalld (RHEL/CentOS)

```yaml
- name: Configure firewalld
  hosts: all
  become: true
  tasks:
    - name: Ensure firewalld running
      ansible.builtin.service: { name: firewalld, state: started, enabled: true }

    - name: Configure public zone
      ansible.posix.firewalld:
        zone: public
        service: "{{ item }}"
        permanent: true
        immediate: true
        state: enabled
      loop: [ssh, http, https]

    - name: Add rich rule for internal access
      ansible.posix.firewalld:
        zone: internal
        rich_rule: 'rule family="ipv4" source address="10.0.0.0/8" port protocol="tcp" port="5432" accept'
        permanent: true
        immediate: true
        state: enabled
```

---

## User and Access Management

### Centralized User Management

```yaml
- name: Manage system users
  hosts: all
  become: true
  vars:
    system_users:
      - name: deploy
        groups: [sudo, docker]
        ssh_keys: ["ssh-ed25519 AAAA... deploy@ci"]
        shell: /bin/bash
        state: present
      - name: monitor
        groups: []
        ssh_keys: ["ssh-ed25519 AAAA... monitor@nagios"]
        shell: /bin/bash
        sudo_commands: ["/usr/lib/nagios/plugins/*"]
        state: present
      - name: ex_employee
        state: absent
  tasks:
    - name: Create/remove users
      ansible.builtin.user:
        name: "{{ item.name }}"
        groups: "{{ item.groups | default([]) }}"
        append: true
        shell: "{{ item.shell | default('/bin/bash') }}"
        state: "{{ item.state }}"
        remove: "{{ item.state == 'absent' }}"
      loop: "{{ system_users }}"

    - name: Deploy SSH keys
      ansible.posix.authorized_key:
        user: "{{ item.name }}"
        key: "{{ item.ssh_keys | join('\n') }}"
        exclusive: true
      loop: "{{ system_users }}"
      when: item.state == 'present' and item.ssh_keys is defined

    - name: Configure granular sudo
      ansible.builtin.copy:
        dest: "/etc/sudoers.d/{{ item.name }}"
        content: "{{ item.name }} ALL=(ALL) NOPASSWD: {{ item.sudo_commands | join(', ') }}\n"
        mode: '0440'
        validate: '/usr/sbin/visudo -cf %s'
      loop: "{{ system_users }}"
      when: item.state == 'present' and item.sudo_commands is defined

    - name: Remove sudo for removed users
      ansible.builtin.file:
        path: "/etc/sudoers.d/{{ item.name }}"
        state: absent
      loop: "{{ system_users }}"
      when: item.state == 'absent'

    - name: Lock inactive accounts (90 days)
      ansible.builtin.command: >
        chage --inactive 90 {{ item.name }}
      loop: "{{ system_users }}"
      when: item.state == 'present'
      changed_when: false
```

### Password Policy

```yaml
- name: Enforce password policy
  hosts: all
  become: true
  tasks:
    - name: Install password quality library
      ansible.builtin.package:
        name: libpam-pwquality
        state: present

    - name: Configure password complexity
      ansible.builtin.lineinfile:
        path: /etc/security/pwquality.conf
        regexp: "^{{ item.key }}"
        line: "{{ item.key }} = {{ item.value }}"
      loop:
        - { key: 'minlen', value: '14' }
        - { key: 'dcredit', value: '-1' }
        - { key: 'ucredit', value: '-1' }
        - { key: 'lcredit', value: '-1' }
        - { key: 'ocredit', value: '-1' }
        - { key: 'maxrepeat', value: '3' }

    - name: Set password aging
      ansible.builtin.lineinfile:
        path: /etc/login.defs
        regexp: "^{{ item.key }}"
        line: "{{ item.key }}   {{ item.value }}"
      loop:
        - { key: 'PASS_MAX_DAYS', value: '90' }
        - { key: 'PASS_MIN_DAYS', value: '1' }
        - { key: 'PASS_WARN_AGE', value: '14' }
```

---

## Audit Logging

### Ansible Run Audit Trail

```yaml
# callback_plugins/audit_log.py pattern
# Log every Ansible run to central syslog / SIEM

# ansible.cfg
[defaults]
log_path = /var/log/ansible/ansible.log
callbacks_enabled = timer, profile_tasks

# Playbook-level audit
- name: Log deployment start
  hosts: localhost
  tasks:
    - name: Record deployment
      ansible.builtin.uri:
        url: "https://audit.internal/api/events"
        method: POST
        body_format: json
        body:
          event: deployment_started
          playbook: "{{ ansible_play_name }}"
          user: "{{ lookup('env', 'USER') }}"
          timestamp: "{{ ansible_date_time.iso8601 }}"
          hosts: "{{ ansible_play_hosts }}"
        headers:
          Authorization: "Bearer {{ vault_audit_token }}"
```

### System Audit Configuration

```yaml
- name: Configure system auditing
  hosts: all
  become: true
  tasks:
    - name: Ensure auditd is installed and running
      ansible.builtin.package: { name: auditd, state: present }

    - name: Deploy audit rules
      ansible.builtin.copy:
        dest: /etc/audit/rules.d/hardening.rules
        content: |
          # Delete all existing rules
          -D
          # Set buffer size
          -b 8192
          # Failure mode (1=printk, 2=panic)
          -f 1

          # Identity changes
          -w /etc/passwd -p wa -k identity
          -w /etc/group -p wa -k identity
          -w /etc/shadow -p wa -k identity
          -w /etc/gshadow -p wa -k identity

          # Privileged commands
          -a always,exit -F path=/usr/bin/sudo -F perm=x -k privileged
          -a always,exit -F path=/usr/bin/su -F perm=x -k privileged

          # File deletions
          -a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat -F auid>=1000 -k delete

          # System administration
          -w /etc/sudoers -p wa -k sudoers
          -w /etc/sudoers.d/ -p wa -k sudoers

          # Network configuration
          -a always,exit -F arch=b64 -S sethostname,setdomainname -k network

          # Make immutable (requires reboot to change)
          -e 2
        mode: '0640'
      notify: restart auditd

    - name: Configure audit log rotation
      ansible.builtin.copy:
        dest: /etc/audit/auditd.conf
        content: |
          log_file = /var/log/audit/audit.log
          log_format = ENRICHED
          max_log_file = 50
          max_log_file_action = ROTATE
          num_logs = 10
          space_left = 75
          space_left_action = SYSLOG
          admin_space_left = 50
          admin_space_left_action = HALT
        mode: '0640'
      notify: restart auditd

  handlers:
    - name: restart auditd
      ansible.builtin.service: { name: auditd, state: restarted }
```

---

## Compliance as Code

### Compliance Framework Playbook Structure

```
compliance/
├── playbooks/
│   ├── cis-level1.yml         # CIS Level 1 benchmark
│   ├── cis-level2.yml         # CIS Level 2 benchmark
│   ├── pci-dss.yml            # PCI DSS requirements
│   ├── hipaa.yml              # HIPAA controls
│   └── soc2.yml               # SOC 2 controls
├── roles/
│   ├── cis_filesystem/
│   ├── cis_network/
│   ├── cis_logging/
│   ├── cis_access/
│   └── cis_services/
├── reports/                   # generated compliance reports
└── vars/
    ├── cis_controls.yml       # control definitions
    └── exceptions.yml         # documented exceptions
```

### Compliance Check and Remediate Pattern

```yaml
- name: Compliance audit and remediation
  hosts: all
  become: true
  vars:
    compliance_mode: audit  # audit | remediate
  tasks:
    - name: "CIS 5.2.1 — Check SSH Protocol"
      ansible.builtin.command: grep -E "^Protocol" /etc/ssh/sshd_config
      register: ssh_protocol
      changed_when: false
      failed_when: false

    - name: "CIS 5.2.1 — Report finding"
      ansible.builtin.set_fact:
        compliance_findings: "{{ compliance_findings | default([]) + [finding] }}"
      vars:
        finding:
          control: "CIS 5.2.1"
          description: "Ensure SSH Protocol is set to 2"
          status: "{{ 'PASS' if 'Protocol 2' in ssh_protocol.stdout | default('') else 'FAIL' }}"
          host: "{{ inventory_hostname }}"

    - name: "CIS 5.2.1 — Remediate"
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?Protocol'
        line: 'Protocol 2'
      when: compliance_mode == 'remediate'
      notify: restart sshd

    - name: Generate compliance report
      ansible.builtin.template:
        src: compliance-report.j2
        dest: "/tmp/compliance-{{ inventory_hostname }}-{{ ansible_date_time.date }}.json"
      delegate_to: localhost

  handlers:
    - name: restart sshd
      ansible.builtin.service: { name: sshd, state: restarted }
```

### Compliance Report Template

```jinja2
{# compliance-report.j2 #}
{
  "host": "{{ inventory_hostname }}",
  "scan_date": "{{ ansible_date_time.iso8601 }}",
  "framework": "CIS Level 1",
  "findings": [
    {% for finding in compliance_findings | default([]) %}
    {
      "control": "{{ finding.control }}",
      "description": "{{ finding.description }}",
      "status": "{{ finding.status }}"
    }{{ "," if not loop.last }}
    {% endfor %}
  ],
  "summary": {
    "total": {{ compliance_findings | default([]) | length }},
    "passed": {{ compliance_findings | default([]) | selectattr('status', 'equalto', 'PASS') | list | length }},
    "failed": {{ compliance_findings | default([]) | selectattr('status', 'equalto', 'FAIL') | list | length }}
  }
}
```
