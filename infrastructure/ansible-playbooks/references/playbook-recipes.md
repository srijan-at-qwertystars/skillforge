# Ansible Playbook Recipes

## Table of Contents

- [Web Server Setup (Nginx + Certbot)](#web-server-setup-nginx--certbot)
- [Database Server (PostgreSQL with Replication)](#database-server-postgresql-with-replication)
- [Docker Host Provisioning](#docker-host-provisioning)
- [Kubernetes Node Preparation](#kubernetes-node-preparation)
- [Zero-Downtime Rolling Deployment](#zero-downtime-rolling-deployment)
- [User Management and SSH Key Distribution](#user-management-and-ssh-key-distribution)
- [Security Hardening (CIS Benchmarks)](#security-hardening-cis-benchmarks)
- [Monitoring Agent Deployment](#monitoring-agent-deployment)
- [Backup Configuration](#backup-configuration)
- [CI/CD Runner Setup](#cicd-runner-setup)

---

## Web Server Setup (Nginx + Certbot)

```yaml
---
- name: Configure production web server
  hosts: webservers
  become: true
  vars:
    domains:
      - { name: app.example.com, upstream_port: 8080 }
    certbot_email: admin@example.com

  handlers:
    - name: Reload nginx
      ansible.builtin.systemd: { name: nginx, state: reloaded }

  tasks:
    - name: Install nginx and certbot
      ansible.builtin.apt:
        name: [nginx, certbot, python3-certbot-nginx, ssl-cert]
        state: present
        update_cache: true
        cache_valid_time: 3600

    - name: Deploy SSL params snippet
      ansible.builtin.copy:
        dest: /etc/nginx/snippets/ssl-params.conf
        mode: "0644"
        content: |
          ssl_protocols TLSv1.2 TLSv1.3;
          ssl_prefer_server_ciphers off;
          ssl_session_timeout 1d;
          ssl_session_cache shared:SSL:10m;
          add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
          add_header X-Frame-Options DENY always;
          add_header X-Content-Type-Options nosniff always;
      notify: Reload nginx

    - name: Deploy vhost configs
      ansible.builtin.template:
        src: vhost.conf.j2
        dest: "/etc/nginx/sites-available/{{ item.name }}"
        mode: "0644"
      loop: "{{ domains }}"
      notify: Reload nginx

    - name: Enable vhosts
      ansible.builtin.file:
        src: "/etc/nginx/sites-available/{{ item.name }}"
        dest: "/etc/nginx/sites-enabled/{{ item.name }}"
        state: link
      loop: "{{ domains }}"

    - name: Ensure nginx is running
      ansible.builtin.systemd: { name: nginx, state: started, enabled: true }

    - name: Flush handlers before certbot
      ansible.builtin.meta: flush_handlers

    - name: Obtain SSL certificates
      ansible.builtin.command: >
        certbot certonly --nginx --non-interactive --agree-tos
        --email {{ certbot_email }} -d {{ item.name }}
      args:
        creates: "/etc/letsencrypt/live/{{ item.name }}/fullchain.pem"
      loop: "{{ domains }}"

    - name: Certbot auto-renewal cron
      ansible.builtin.cron:
        name: "certbot renewal"
        minute: "30"
        hour: "2"
        job: "certbot renew --quiet --post-hook 'systemctl reload nginx'"
```

---

## Database Server (PostgreSQL with Replication)

```yaml
---
- name: Configure PostgreSQL primary
  hosts: db_primary
  become: true
  vars:
    pg_version: "16"
    pg_conf_dir: "/etc/postgresql/{{ pg_version }}/main"
    pg_shared_buffers: "{{ (ansible_memtotal_mb * 0.25) | int }}MB"
    pg_users:
      - { name: appuser, password: "{{ vault_pg_app_password }}", flags: LOGIN }
      - { name: replicator, password: "{{ vault_pg_repl_password }}", flags: "LOGIN,REPLICATION" }
    pg_databases:
      - { name: appdb, owner: appuser }

  handlers:
    - name: Restart postgresql
      ansible.builtin.systemd: { name: postgresql, state: restarted }

  tasks:
    - name: Install PostgreSQL
      ansible.builtin.apt:
        name: ["postgresql-{{ pg_version }}", "postgresql-contrib-{{ pg_version }}", python3-psycopg2]
        state: present
        update_cache: true

    - name: Configure postgresql.conf
      ansible.builtin.lineinfile:
        path: "{{ pg_conf_dir }}/postgresql.conf"
        regexp: "^#?{{ item.key }}\\s*="
        line: "{{ item.key }} = {{ item.value }}"
      loop:
        - { key: listen_addresses, value: "'*'" }
        - { key: shared_buffers, value: "{{ pg_shared_buffers }}" }
        - { key: wal_level, value: replica }
        - { key: max_wal_senders, value: "5" }
        - { key: hot_standby, value: "on" }
        - { key: log_min_duration_statement, value: "1000" }
      notify: Restart postgresql

    - name: Configure pg_hba.conf
      ansible.builtin.template:
        src: pg_hba.conf.j2
        dest: "{{ pg_conf_dir }}/pg_hba.conf"
        owner: postgres
        mode: "0640"
      notify: Restart postgresql

    - name: Start PostgreSQL
      ansible.builtin.systemd: { name: postgresql, state: started, enabled: true }

    - name: Flush handlers
      ansible.builtin.meta: flush_handlers

    - name: Create users
      community.postgresql.postgresql_user:
        name: "{{ item.name }}"
        password: "{{ item.password }}"
        role_attr_flags: "{{ item.flags }}"
      become_user: postgres
      loop: "{{ pg_users }}"
      no_log: true

    - name: Create databases
      community.postgresql.postgresql_db:
        name: "{{ item.name }}"
        owner: "{{ item.owner }}"
      become_user: postgres
      loop: "{{ pg_databases }}"

- name: Configure PostgreSQL replica
  hosts: db_replica
  become: true
  vars:
    pg_version: "16"
    pg_primary_host: "{{ hostvars[groups['db_primary'][0]]['ansible_host'] }}"

  tasks:
    - name: Install PostgreSQL
      ansible.builtin.apt:
        name: ["postgresql-{{ pg_version }}"]
        state: present

    - name: Stop PostgreSQL for replica setup
      ansible.builtin.systemd: { name: postgresql, state: stopped }

    - name: Create base backup from primary
      ansible.builtin.command: >
        pg_basebackup -h {{ pg_primary_host }} -U replicator
        -D /var/lib/postgresql/{{ pg_version }}/main -Fp -Xs -P -R
      become_user: postgres
      environment: { PGPASSWORD: "{{ vault_pg_repl_password }}" }
      args:
        creates: "/var/lib/postgresql/{{ pg_version }}/main/PG_VERSION"

    - name: Start replica
      ansible.builtin.systemd: { name: postgresql, state: started, enabled: true }
```

---

## Docker Host Provisioning

```yaml
---
- name: Provision Docker host
  hosts: docker_hosts
  become: true
  vars:
    docker_users: ["{{ ansible_user }}"]
    docker_daemon_config:
      log-driver: json-file
      log-opts: { max-size: "50m", max-file: "3" }
      storage-driver: overlay2
      live-restore: true

  handlers:
    - name: Restart docker
      ansible.builtin.systemd: { name: docker, state: restarted, daemon_reload: true }

  tasks:
    - name: Install prerequisites
      ansible.builtin.apt:
        name: [apt-transport-https, ca-certificates, curl, gnupg, python3-docker]
        state: present
        update_cache: true

    - name: Add Docker GPG key and repo
      ansible.builtin.apt_key:
        url: "https://download.docker.com/linux/{{ ansible_distribution | lower }}/gpg"

    - name: Add Docker repository
      ansible.builtin.apt_repository:
        repo: "deb https://download.docker.com/linux/{{ ansible_distribution | lower }} {{ ansible_distribution_release }} stable"

    - name: Install Docker
      ansible.builtin.apt:
        name: [docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin]
        state: present
        update_cache: true

    - name: Configure daemon
      ansible.builtin.copy:
        content: "{{ docker_daemon_config | to_nice_json }}\n"
        dest: /etc/docker/daemon.json
        mode: "0644"
      notify: Restart docker

    - name: Add users to docker group
      ansible.builtin.user: { name: "{{ item }}", groups: docker, append: true }
      loop: "{{ docker_users }}"

    - name: Kernel parameters for Docker
      ansible.posix.sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        reload: true
      loop:
        - { key: net.bridge.bridge-nf-call-iptables, value: "1" }
        - { key: net.ipv4.ip_forward, value: "1" }

    - name: Start Docker
      ansible.builtin.systemd: { name: docker, state: started, enabled: true }
```

---

## Kubernetes Node Preparation

```yaml
---
- name: Prepare Kubernetes nodes
  hosts: k8s_nodes
  become: true
  vars:
    k8s_version: "1.29"

  handlers:
    - name: Restart containerd
      ansible.builtin.systemd: { name: containerd, state: restarted, daemon_reload: true }

  tasks:
    - name: Disable swap
      ansible.builtin.command: swapoff -a
      changed_when: false

    - name: Remove swap from fstab
      ansible.builtin.lineinfile: { path: /etc/fstab, regexp: '\sswap\s', state: absent }

    - name: Load kernel modules
      community.general.modprobe: { name: "{{ item }}", state: present, persistent: present }
      loop: [overlay, br_netfilter]

    - name: Set kernel parameters
      ansible.posix.sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_file: /etc/sysctl.d/k8s.conf
        reload: true
      loop:
        - { key: net.bridge.bridge-nf-call-iptables, value: "1" }
        - { key: net.bridge.bridge-nf-call-ip6tables, value: "1" }
        - { key: net.ipv4.ip_forward, value: "1" }

    - name: Install containerd
      ansible.builtin.apt: { name: [containerd, curl, apt-transport-https], state: present, update_cache: true }

    - name: Generate containerd config
      ansible.builtin.shell: containerd config default > /etc/containerd/config.toml
      args: { creates: /etc/containerd/config.toml }

    - name: Enable SystemdCgroup
      ansible.builtin.lineinfile:
        path: /etc/containerd/config.toml
        regexp: 'SystemdCgroup\s*='
        line: '            SystemdCgroup = true'
      notify: Restart containerd

    - name: Add Kubernetes repo
      ansible.builtin.apt_repository:
        repo: "deb https://pkgs.k8s.io/core:/stable:/v{{ k8s_version }}/deb/ /"

    - name: Install Kubernetes packages
      ansible.builtin.apt: { name: [kubelet, kubeadm, kubectl], state: present, update_cache: true }

    - name: Hold Kubernetes packages
      ansible.builtin.dpkg_selections: { name: "{{ item }}", selection: hold }
      loop: [kubelet, kubeadm, kubectl]
```

---

## Zero-Downtime Rolling Deployment

```yaml
---
- name: Rolling deployment
  hosts: appservers
  become: true
  serial: 1
  max_fail_percentage: 0
  vars:
    app_name: myapp
    app_version: "{{ deploy_version }}"
    app_dir: "/opt/{{ app_name }}"

  pre_tasks:
    - name: Drain from load balancer
      ansible.builtin.uri:
        url: "https://{{ lb_host }}/api/backends/{{ inventory_hostname }}/drain"
        method: POST
        headers: { Authorization: "Bearer {{ lb_api_token }}" }
      delegate_to: localhost
      become: false

    - name: Wait for connections to drain
      ansible.builtin.pause: { seconds: 10 }

  tasks:
    - name: Create release directory
      ansible.builtin.file:
        path: "{{ app_dir }}/releases/{{ app_version }}"
        state: directory
        owner: app
        mode: "0755"

    - name: Download artifact
      ansible.builtin.get_url:
        url: "https://artifacts.example.com/{{ app_name }}/{{ app_version }}/{{ app_name }}.tar.gz"
        dest: "/tmp/{{ app_name }}-{{ app_version }}.tar.gz"
        checksum: "sha256:{{ artifact_checksum }}"

    - name: Extract
      ansible.builtin.unarchive:
        src: "/tmp/{{ app_name }}-{{ app_version }}.tar.gz"
        dest: "{{ app_dir }}/releases/{{ app_version }}"
        remote_src: true

    - name: Update symlink
      ansible.builtin.file:
        src: "{{ app_dir }}/releases/{{ app_version }}"
        dest: "{{ app_dir }}/current"
        state: link
      notify: Restart app

    - name: Flush handlers
      ansible.builtin.meta: flush_handlers

    - name: Health check
      ansible.builtin.uri: { url: "http://localhost:8080/health", status_code: 200 }
      retries: 30
      delay: 5

    - name: Cleanup old releases
      ansible.builtin.shell: ls -dt {{ app_dir }}/releases/*/ | tail -n +6 | xargs rm -rf
      changed_when: false

  post_tasks:
    - name: Re-register with LB
      ansible.builtin.uri:
        url: "https://{{ lb_host }}/api/backends/{{ inventory_hostname }}/enable"
        method: POST
        headers: { Authorization: "Bearer {{ lb_api_token }}" }
      delegate_to: localhost
      become: false

  handlers:
    - name: Restart app
      ansible.builtin.systemd: { name: "{{ app_name }}", state: restarted, daemon_reload: true }
```

---

## User Management and SSH Key Distribution

```yaml
---
- name: Manage users and SSH keys
  hosts: all
  become: true
  vars:
    user_accounts:
      - username: alice
        groups: [sudo, docker]
        ssh_keys: ["ssh-ed25519 AAAA... alice@laptop"]
        state: present
      - username: bob
        groups: [docker]
        ssh_keys: ["ssh-ed25519 AAAA... bob@laptop"]
        state: present
      - username: charlie
        state: absent

  handlers:
    - name: Restart sshd
      ansible.builtin.systemd: { name: sshd, state: restarted }

  tasks:
    - name: Manage user accounts
      ansible.builtin.user:
        name: "{{ item.username }}"
        groups: "{{ item.groups | default([]) }}"
        state: "{{ item.state }}"
        remove: "{{ item.state == 'absent' }}"
        append: true
      loop: "{{ user_accounts }}"

    - name: Set authorized keys
      ansible.posix.authorized_key:
        user: "{{ item.0.username }}"
        key: "{{ item.1 }}"
      loop: "{{ user_accounts | selectattr('state', 'eq', 'present') | subelements('ssh_keys', skip_missing=True) }}"

    - name: Harden SSH config
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: "^#?{{ item.key }}\\s"
        line: "{{ item.key }} {{ item.value }}"
        validate: 'sshd -t -f %s'
      loop:
        - { key: PermitRootLogin, value: "no" }
        - { key: PasswordAuthentication, value: "no" }
        - { key: MaxAuthTries, value: "3" }
      notify: Restart sshd
```

---

## Security Hardening (CIS Benchmarks)

```yaml
---
- name: CIS security hardening
  hosts: all
  become: true

  handlers:
    - name: Restart auditd
      ansible.builtin.service: { name: auditd, state: restarted }

  tasks:
    - name: Mount /tmp with noexec
      ansible.posix.mount:
        path: /tmp
        src: tmpfs
        fstype: tmpfs
        opts: "defaults,nodev,nosuid,noexec,size=2G"
        state: mounted

    - name: Set restrictive file permissions
      ansible.builtin.file:
        path: "{{ item.path }}"
        owner: root
        group: root
        mode: "{{ item.mode }}"
      loop:
        - { path: /etc/shadow, mode: "0600" }
        - { path: /etc/gshadow, mode: "0600" }
        - { path: /etc/crontab, mode: "0600" }
        - { path: /etc/ssh/sshd_config, mode: "0600" }

    - name: Kernel security parameters
      ansible.posix.sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_file: /etc/sysctl.d/99-security.conf
        reload: true
      loop:
        - { key: net.ipv4.conf.all.accept_redirects, value: "0" }
        - { key: net.ipv4.conf.all.send_redirects, value: "0" }
        - { key: net.ipv4.conf.all.accept_source_route, value: "0" }
        - { key: net.ipv4.tcp_syncookies, value: "1" }
        - { key: kernel.randomize_va_space, value: "2" }
        - { key: fs.suid_dumpable, value: "0" }
        - { key: kernel.dmesg_restrict, value: "1" }

    - name: Password aging policy
      ansible.builtin.lineinfile:
        path: /etc/login.defs
        regexp: "^{{ item.key }}\\s"
        line: "{{ item.key }}\t{{ item.value }}"
      loop:
        - { key: PASS_MAX_DAYS, value: "90" }
        - { key: PASS_MIN_DAYS, value: "7" }
        - { key: PASS_WARN_AGE, value: "14" }

    - name: Disable unnecessary services
      ansible.builtin.systemd: { name: "{{ item }}", state: stopped, enabled: false, masked: true }
      loop: [avahi-daemon, cups, rpcbind]
      failed_when: false

    - name: Install and configure auditd
      ansible.builtin.apt: { name: [auditd, audispd-plugins], state: present }

    - name: Deploy audit rules
      ansible.builtin.copy:
        dest: /etc/audit/rules.d/cis.rules
        mode: "0640"
        content: |
          -w /etc/sudoers -p wa -k scope
          -w /etc/sudoers.d/ -p wa -k scope
          -w /etc/passwd -p wa -k identity
          -w /etc/shadow -p wa -k identity
          -w /etc/ssh/sshd_config -p rwxa -k sshd
          -e 2
      notify: Restart auditd

    - name: Enable automatic security updates
      ansible.builtin.apt: { name: [unattended-upgrades, apt-listchanges], state: present }
```

---

## Monitoring Agent Deployment

```yaml
---
- name: Deploy node_exporter + Filebeat
  hosts: all
  become: true
  vars:
    node_exporter_version: "1.7.0"
    filebeat_version: "8.12.0"

  handlers:
    - name: Restart node_exporter
      ansible.builtin.systemd: { name: node_exporter, state: restarted, daemon_reload: true }
    - name: Restart filebeat
      ansible.builtin.systemd: { name: filebeat, state: restarted }

  tasks:
    - name: Create node_exporter user
      ansible.builtin.user: { name: node_exporter, system: true, shell: /usr/sbin/nologin, create_home: false }

    - name: Download and install node_exporter
      ansible.builtin.unarchive:
        src: "https://github.com/prometheus/node_exporter/releases/download/v{{ node_exporter_version }}/node_exporter-{{ node_exporter_version }}.linux-amd64.tar.gz"
        dest: /tmp/
        remote_src: true

    - name: Copy binary
      ansible.builtin.copy:
        src: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64/node_exporter"
        dest: /usr/local/bin/node_exporter
        remote_src: true
        mode: "0755"
      notify: Restart node_exporter

    - name: Deploy systemd unit
      ansible.builtin.copy:
        dest: /etc/systemd/system/node_exporter.service
        mode: "0644"
        content: |
          [Unit]
          Description=Prometheus Node Exporter
          After=network-online.target
          [Service]
          User=node_exporter
          Type=simple
          ExecStart=/usr/local/bin/node_exporter --collector.systemd --collector.processes
          Restart=always
          [Install]
          WantedBy=multi-user.target
      notify: Restart node_exporter

    - name: Start node_exporter
      ansible.builtin.systemd: { name: node_exporter, state: started, enabled: true, daemon_reload: true }

    - name: Install Filebeat
      ansible.builtin.apt: { name: "filebeat={{ filebeat_version }}", state: present, update_cache: true }

    - name: Deploy Filebeat config
      ansible.builtin.template:
        src: filebeat.yml.j2
        dest: /etc/filebeat/filebeat.yml
        mode: "0600"
      notify: Restart filebeat

    - name: Start Filebeat
      ansible.builtin.systemd: { name: filebeat, state: started, enabled: true }
```

---

## Backup Configuration

```yaml
---
- name: Configure backups
  hosts: all
  become: true
  vars:
    backup_dir: /var/backups/automated
    backup_retention_days: 30
    backup_targets:
      - { name: etc, path: /etc, hour: "2", minute: "0" }
      - { name: app_data, path: /opt/app/data, hour: "3", minute: "0" }

  tasks:
    - name: Create backup user and dirs
      ansible.builtin.user: { name: backup, system: true, shell: /bin/bash }

    - name: Create backup directories
      ansible.builtin.file:
        path: "{{ backup_dir }}/{{ item.name }}"
        state: directory
        owner: backup
        mode: "0750"
      loop: "{{ backup_targets }}"

    - name: Install tools
      ansible.builtin.apt: { name: [rsync, pigz], state: present }

    - name: Deploy backup script
      ansible.builtin.copy:
        dest: /usr/local/bin/run-backup.sh
        mode: "0750"
        content: |
          #!/bin/bash
          set -euo pipefail
          NAME="$1"; SRC="$2"; DIR="{{ backup_dir }}/${NAME}"
          STAMP=$(date +%Y%m%d_%H%M%S)
          tar czf "${DIR}/${NAME}_${STAMP}.tar.gz" -C "$(dirname "$SRC")" "$(basename "$SRC")"
          find "$DIR" -name "*.tar.gz" -mtime +{{ backup_retention_days }} -delete

    - name: Configure cron jobs
      ansible.builtin.cron:
        name: "Backup {{ item.name }}"
        user: backup
        hour: "{{ item.hour }}"
        minute: "{{ item.minute }}"
        job: "/usr/local/bin/run-backup.sh {{ item.name }} {{ item.path }}"
      loop: "{{ backup_targets }}"
```

---

## CI/CD Runner Setup

```yaml
---
- name: Configure GitLab Runner
  hosts: runners
  become: true
  vars:
    gitlab_url: "https://gitlab.example.com"
    gitlab_token: "{{ vault_gitlab_runner_token }}"
    gitlab_runner_tags: [docker, linux]

  tasks:
    - name: Install dependencies
      ansible.builtin.apt:
        name: [curl, git, docker.io]
        state: present
        update_cache: true

    - name: Add GitLab Runner repo
      ansible.builtin.shell: |
        curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | bash
      args:
        creates: /etc/apt/sources.list.d/runner_gitlab-runner.list

    - name: Install gitlab-runner
      ansible.builtin.apt: { name: gitlab-runner, state: present, update_cache: true }

    - name: Register runner
      ansible.builtin.command: >
        gitlab-runner register --non-interactive
        --url "{{ gitlab_url }}" --token "{{ gitlab_token }}"
        --executor docker --docker-image ubuntu:22.04
        --tag-list "{{ gitlab_runner_tags | join(',') }}"
      args:
        creates: /etc/gitlab-runner/config.toml
      no_log: true

    - name: Set concurrency
      ansible.builtin.lineinfile:
        path: /etc/gitlab-runner/config.toml
        regexp: '^concurrent\s*='
        line: "concurrent = {{ ansible_processor_vcpus | default(4) }}"
      notify: Restart gitlab-runner

  handlers:
    - name: Restart gitlab-runner
      ansible.builtin.systemd: { name: gitlab-runner, state: restarted }
```
