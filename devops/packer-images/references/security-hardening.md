# Image Security Hardening Guide

## Table of Contents

- [CIS Benchmark Implementation](#cis-benchmark-implementation)
  - [Ubuntu 22.04](#ubuntu-2204-cis)
  - [Amazon Linux 2023](#amazon-linux-2023-cis)
  - [Windows Server 2022](#windows-server-2022-cis)
- [Automated Security Scanning](#automated-security-scanning)
  - [Trivy](#trivy)
  - [Grype](#grype)
  - [Anchore](#anchore)
- [STIG Compliance](#stig-compliance)
- [SSH Hardening](#ssh-hardening)
- [Firewall Configuration](#firewall-configuration)
- [Audit Logging](#audit-logging)
- [Removing Build-Time Credentials](#removing-build-time-credentials)
- [Image Signing](#image-signing)
  - [Cosign](#cosign)
  - [Notation](#notation)
- [Supply Chain Security](#supply-chain-security)
- [SBOM Generation](#sbom-generation)

---

## CIS Benchmark Implementation

### Ubuntu 22.04 CIS

#### Automated with Ansible

```hcl
provisioner "ansible" {
  playbook_file = "ansible/cis-ubuntu.yml"
  user          = "ubuntu"
  extra_arguments = [
    "--extra-vars", "cis_level=1 cis_ubuntu2204cis_section1=true cis_ubuntu2204cis_section2=true",
    "--tags", "scored"
  ]
  galaxy_file = "ansible/requirements.yml"
  ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
}
```

```yaml
# ansible/requirements.yml
roles:
  - name: ansible-lockdown.ubuntu22_cis
    version: "1.3.0"
  - name: dev-sec.os-hardening
    version: "7.0.0"
  - name: dev-sec.ssh-hardening
    version: "10.0.0"
```

```yaml
# ansible/cis-ubuntu.yml
---
- name: Apply CIS Level 1 Benchmark
  hosts: all
  become: true
  vars:
    # CIS Section 1: Initial Setup
    ubtu22cis_rule_1_1_1_1: true   # Disable cramfs
    ubtu22cis_rule_1_1_1_2: true   # Disable freevxfs
    ubtu22cis_rule_1_1_1_3: true   # Disable jffs2
    ubtu22cis_rule_1_1_1_4: true   # Disable hfs
    ubtu22cis_rule_1_1_1_5: true   # Disable hfsplus
    ubtu22cis_rule_1_1_1_6: true   # Disable squashfs
    ubtu22cis_rule_1_1_1_7: true   # Disable udf

    # CIS Section 5: Access, Authentication and Authorization
    ubtu22cis_rule_5_2_1: true     # Configure sudo
    ubtu22cis_rule_5_3_1: true     # SSH daemon configuration

    # Exceptions for cloud environments
    ubtu22cis_rule_1_4_1: false    # Don't set GRUB password (cloud-init manages boot)
    ubtu22cis_rule_3_4_1_1: false  # Skip nftables (use cloud SGs instead)
  roles:
    - ansible-lockdown.ubuntu22_cis
```

#### Manual Shell Provisioner (Key Controls)

```hcl
provisioner "shell" {
  execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
  inline = [
    # 1.1 — Filesystem configuration
    "echo 'install cramfs /bin/true' >> /etc/modprobe.d/CIS.conf",
    "echo 'install freevxfs /bin/true' >> /etc/modprobe.d/CIS.conf",
    "echo 'install jffs2 /bin/true' >> /etc/modprobe.d/CIS.conf",
    "echo 'install hfs /bin/true' >> /etc/modprobe.d/CIS.conf",
    "echo 'install hfsplus /bin/true' >> /etc/modprobe.d/CIS.conf",
    "echo 'install udf /bin/true' >> /etc/modprobe.d/CIS.conf",
    "echo 'install usb-storage /bin/true' >> /etc/modprobe.d/CIS.conf",

    # 1.3 — Filesystem integrity checking
    "apt-get install -y aide aide-common",
    "aideinit",

    # 1.5 — Secure boot settings
    "chown root:root /boot/grub/grub.cfg",
    "chmod 600 /boot/grub/grub.cfg",

    # 3.1 — Network parameters
    "cat >> /etc/sysctl.d/99-cis.conf <<'SYSCTL'",
    "net.ipv4.ip_forward = 0",
    "net.ipv4.conf.all.send_redirects = 0",
    "net.ipv4.conf.default.send_redirects = 0",
    "net.ipv4.conf.all.accept_source_route = 0",
    "net.ipv4.conf.default.accept_source_route = 0",
    "net.ipv4.conf.all.accept_redirects = 0",
    "net.ipv4.conf.default.accept_redirects = 0",
    "net.ipv4.conf.all.log_martians = 1",
    "net.ipv4.conf.default.log_martians = 1",
    "net.ipv4.icmp_echo_ignore_broadcasts = 1",
    "net.ipv4.icmp_ignore_bogus_error_responses = 1",
    "net.ipv4.conf.all.rp_filter = 1",
    "net.ipv4.conf.default.rp_filter = 1",
    "net.ipv4.tcp_syncookies = 1",
    "net.ipv6.conf.all.accept_ra = 0",
    "net.ipv6.conf.default.accept_ra = 0",
    "SYSCTL",
    "sysctl -p /etc/sysctl.d/99-cis.conf",

    # 4.2 — Configure logging
    "apt-get install -y rsyslog",
    "systemctl enable rsyslog",

    # 5.2 — Configure SSH server (see SSH Hardening section below)

    # 5.4 — User accounts and environment
    "useradd -D -f 30",   # Inactive accounts disabled after 30 days

    # 6.1 — File permissions
    "chmod 644 /etc/passwd",
    "chmod 600 /etc/shadow",
    "chmod 644 /etc/group",
    "chmod 600 /etc/gshadow",
    "chmod 600 /etc/passwd-",
    "chmod 600 /etc/shadow-",
    "chmod 600 /etc/group-",
    "chmod 600 /etc/gshadow-"
  ]
}
```

### Amazon Linux 2023 CIS

```hcl
provisioner "shell" {
  execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
  inline = [
    # AL2023-specific: disable unnecessary services
    "systemctl disable rpcbind 2>/dev/null || true",
    "systemctl disable avahi-daemon 2>/dev/null || true",
    "systemctl disable cups 2>/dev/null || true",

    # Install and configure aide
    "dnf install -y aide",
    "aide --init",
    "mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz",

    # Kernel parameters
    "cat >> /etc/sysctl.d/99-cis.conf <<'SYSCTL'",
    "kernel.randomize_va_space = 2",
    "fs.suid_dumpable = 0",
    "kernel.exec-shield = 1",
    "SYSCTL",
    "sysctl -p /etc/sysctl.d/99-cis.conf",

    # Password policies
    "sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 90/' /etc/login.defs",
    "sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS 7/' /etc/login.defs",
    "sed -i 's/^PASS_MIN_LEN.*/PASS_MIN_LEN 14/' /etc/login.defs",
    "sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE 7/' /etc/login.defs",

    # Remove unnecessary packages
    "dnf remove -y telnet-server rsh-server tftp-server ypbind ypserv 2>/dev/null || true"
  ]
}
```

### Windows Server 2022 CIS

```hcl
provisioner "powershell" {
  inline = [
    # Install DSC module for CIS
    "Install-Module -Name CISBenchmarkAudit -Force -Scope AllUsers",
    "Install-Module -Name SecurityPolicyDsc -Force -Scope AllUsers",

    # Account policies
    "net accounts /minpwlen:14 /maxpwage:90 /minpwage:1 /uniquepw:24",

    # Audit policies
    "auditpol /set /subcategory:'Logon' /success:enable /failure:enable",
    "auditpol /set /subcategory:'Logoff' /success:enable",
    "auditpol /set /subcategory:'Account Lockout' /success:enable /failure:enable",
    "auditpol /set /subcategory:'Process Creation' /success:enable",
    "auditpol /set /subcategory:'Credential Validation' /success:enable /failure:enable",

    # Disable unnecessary services
    "Set-Service -Name 'Browser' -StartupType Disabled -ErrorAction SilentlyContinue",
    "Set-Service -Name 'IISADMIN' -StartupType Disabled -ErrorAction SilentlyContinue",
    "Set-Service -Name 'TlntSvr' -StartupType Disabled -ErrorAction SilentlyContinue",

    # Windows Firewall
    "Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True",
    "Set-NetFirewallProfile -DefaultInboundAction Block -DefaultOutboundAction Allow",

    # Security settings via registry
    "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa' -Name 'LmCompatibilityLevel' -Value 5",
    "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa' -Name 'RestrictAnonymous' -Value 1",
    "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name 'EnableLUA' -Value 1",
    "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name 'ConsentPromptBehaviorAdmin' -Value 2"
  ]
}
```

---

## Automated Security Scanning

### Trivy

#### Scan During Build (Rootfs)

```hcl
provisioner "shell" {
  inline = [
    "curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin v0.50.0",
    "sudo trivy rootfs --severity HIGH,CRITICAL --exit-code 1 --format table /",
    "sudo trivy rootfs --severity HIGH,CRITICAL --format json --output /tmp/trivy-report.json /",
    "sudo rm /usr/local/bin/trivy"
  ]
}

# Download the report
provisioner "file" {
  source      = "/tmp/trivy-report.json"
  destination = "reports/trivy-report.json"
  direction   = "download"
}
```

#### Scan Container Image

```hcl
# Post-build scan for Docker images
post-processor "shell-local" {
  inline = [
    "trivy image --severity HIGH,CRITICAL --exit-code 1 myapp:latest",
    "trivy image --format sarif --output trivy-results.sarif myapp:latest"
  ]
}
```

#### Trivy Configuration File

```yaml
# trivy.yaml — place in project root
severity:
  - HIGH
  - CRITICAL
exit-code: 1
format: table
ignore-unfixed: true
vuln-type:
  - os
  - library
skip-dirs:
  - /proc
  - /sys
  - /dev
  - /tmp
```

### Grype

```hcl
# Install and scan with Grype
provisioner "shell" {
  inline = [
    "curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sudo sh -s -- -b /usr/local/bin",
    "sudo grype dir:/ --fail-on high --output table",
    "sudo grype dir:/ --output json > /tmp/grype-report.json",
    "sudo rm /usr/local/bin/grype"
  ]
}

# For containers
post-processor "shell-local" {
  inline = [
    "grype myapp:latest --fail-on high",
    "grype myapp:latest --output sarif > grype-results.sarif"
  ]
}
```

### Anchore

```hcl
# Anchore inline scan for containers
post-processor "shell-local" {
  inline = [
    "curl -sSfL https://anchorectl-releases.anchore.io/anchorectl/install.sh | sh -s -- -b /usr/local/bin",
    "anchorectl image add myapp:latest --wait --annotations 'built-by=packer'",
    "anchorectl image check myapp:latest --fail-based-on-results"
  ]
  environment_vars = [
    "ANCHORECTL_URL=${var.anchore_url}",
    "ANCHORECTL_USERNAME=${var.anchore_user}",
    "ANCHORECTL_PASSWORD=${var.anchore_password}"
  ]
}
```

### Combined Scan Pipeline

```hcl
build {
  sources = ["source.amazon-ebs.ubuntu"]

  # ... provisioners ...

  # Scan 1: OS vulnerabilities with Trivy
  provisioner "shell" {
    inline = [
      "curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin",
      "sudo trivy rootfs --severity CRITICAL --exit-code 1 /",
      "sudo rm /usr/local/bin/trivy"
    ]
  }

  # Scan 2: CIS benchmark audit
  provisioner "shell" {
    script = "scripts/cis-audit.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
  }

  # Scan 3: Custom compliance checks
  provisioner "shell" {
    inline = [
      "echo '=== Compliance Checks ==='",
      "test ! -f /etc/ssh/ssh_host_dsa_key || (echo 'FAIL: DSA key exists' && exit 1)",
      "grep -q 'PermitRootLogin no' /etc/ssh/sshd_config || (echo 'FAIL: Root login enabled' && exit 1)",
      "grep -q 'PasswordAuthentication no' /etc/ssh/sshd_config || (echo 'FAIL: Password auth enabled' && exit 1)",
      "echo 'All compliance checks passed'"
    ]
  }
}
```

---

## STIG Compliance

### Applying DISA STIGs

```hcl
# Use DISA STIG Ansible roles
provisioner "ansible" {
  playbook_file = "ansible/stig.yml"
  user          = "ubuntu"
  galaxy_file   = "ansible/stig-requirements.yml"
  extra_arguments = [
    "--extra-vars", "rhel9stig_cat1_patch=true rhel9stig_cat2_patch=true",
    "--skip-tags", "reboot"
  ]
  ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
}
```

```yaml
# ansible/stig-requirements.yml
roles:
  - name: ansible-lockdown.rhel9_stig
    version: "1.0.0"
  - name: ansible-lockdown.ubuntu22_stig
    version: "1.0.0"
```

```yaml
# ansible/stig.yml
---
- name: Apply DISA STIG
  hosts: all
  become: true
  vars:
    # CAT I (High) — all enabled
    rhel9stig_cat1_patch: true
    # CAT II (Medium) — selective
    rhel9stig_cat2_patch: true
    # CAT III (Low) — skip in base image
    rhel9stig_cat3_patch: false
    # Exceptions
    rhel9stig_gui: false  # No GUI on server images
  roles:
    - ansible-lockdown.rhel9_stig
```

### STIG Audit Script

```bash
#!/usr/bin/env bash
# Minimal STIG audit checks for Linux
set -euo pipefail

PASS=0
FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then
    echo "PASS: $1"
    ((PASS++))
  else
    echo "FAIL: $1"
    ((FAIL++))
  fi
}

check "V-230222: FIPS mode enabled" "cat /proc/sys/crypto/fips_enabled | grep -q 1"
check "V-230223: SSH root login disabled" "grep -q '^PermitRootLogin no' /etc/ssh/sshd_config"
check "V-230224: SSH protocol 2" "grep -q '^Protocol 2' /etc/ssh/sshd_config || ! grep -q '^Protocol' /etc/ssh/sshd_config"
check "V-230225: Audit system enabled" "systemctl is-enabled auditd"
check "V-230226: Ctrl-Alt-Del disabled" "systemctl is-masked ctrl-alt-del.target"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

---

## SSH Hardening

```hcl
provisioner "shell" {
  execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
  inline = [
    # Backup original config
    "cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak",

    # Write hardened SSH config
    "cat > /etc/ssh/sshd_config.d/hardening.conf <<'SSHD'",
    "# Authentication",
    "PermitRootLogin no",
    "PasswordAuthentication no",
    "PermitEmptyPasswords no",
    "PubkeyAuthentication yes",
    "AuthenticationMethods publickey",
    "MaxAuthTries 3",
    "MaxSessions 4",
    "LoginGraceTime 60",

    "# Protocol and ciphers",
    "Protocol 2",
    "KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256",
    "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr",
    "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256",
    "HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256",

    "# Security",
    "X11Forwarding no",
    "AllowTcpForwarding no",
    "AllowAgentForwarding no",
    "PermitTunnel no",
    "GatewayPorts no",
    "Banner /etc/ssh/banner",
    "PermitUserEnvironment no",
    "ClientAliveInterval 300",
    "ClientAliveCountMax 2",
    "UseDNS no",

    "# Logging",
    "LogLevel VERBOSE",
    "SyslogFacility AUTH",
    "SSHD",

    # Remove weak host keys
    "rm -f /etc/ssh/ssh_host_dsa_key /etc/ssh/ssh_host_dsa_key.pub",
    "rm -f /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ecdsa_key.pub",

    # Regenerate strong host keys
    "ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N '' -q <<< 'y' || true",
    "ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N '' -q <<< 'y' || true",

    # Set permissions
    "chmod 600 /etc/ssh/ssh_host_*_key",
    "chmod 644 /etc/ssh/ssh_host_*_key.pub",

    # Create login banner
    "echo 'Authorized access only. All activity is monitored and recorded.' > /etc/ssh/banner",

    # Validate config
    "sshd -t"
  ]
}
```

---

## Firewall Configuration

### UFW (Ubuntu)

```hcl
provisioner "shell" {
  execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
  inline = [
    "apt-get install -y ufw",
    "ufw default deny incoming",
    "ufw default allow outgoing",

    # Allow only necessary ports
    "ufw allow 22/tcp comment 'SSH'",
    # Add application-specific ports as needed:
    # "ufw allow 443/tcp comment 'HTTPS'",
    # "ufw allow 8080/tcp comment 'App'",

    # Rate limit SSH
    "ufw limit 22/tcp",

    # Enable (non-interactive)
    "echo 'y' | ufw enable",
    "ufw status verbose"
  ]
}
```

### iptables (Any Linux)

```hcl
provisioner "shell" {
  execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
  inline = [
    # Flush existing rules
    "iptables -F",
    "iptables -X",

    # Default policies
    "iptables -P INPUT DROP",
    "iptables -P FORWARD DROP",
    "iptables -P OUTPUT ACCEPT",

    # Allow loopback
    "iptables -A INPUT -i lo -j ACCEPT",
    "iptables -A OUTPUT -o lo -j ACCEPT",

    # Allow established connections
    "iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",

    # Allow SSH
    "iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m limit --limit 3/min --limit-burst 3 -j ACCEPT",

    # Log dropped packets
    "iptables -A INPUT -j LOG --log-prefix 'iptables-dropped: ' --log-level 4",

    # Save rules
    "apt-get install -y iptables-persistent",
    "netfilter-persistent save"
  ]
}
```

---

## Audit Logging

```hcl
provisioner "shell" {
  execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
  inline = [
    # Install auditd
    "apt-get install -y auditd audispd-plugins",

    # Configure audit rules
    "cat > /etc/audit/rules.d/hardening.rules <<'AUDIT'",
    "# Delete all existing rules",
    "-D",
    "# Set buffer size",
    "-b 8192",
    "# Failure mode: 1=printk, 2=panic",
    "-f 1",

    "# Monitor authentication events",
    "-w /etc/pam.d/ -p wa -k pam_changes",
    "-w /etc/shadow -p wa -k shadow_changes",
    "-w /etc/passwd -p wa -k passwd_changes",
    "-w /etc/group -p wa -k group_changes",

    "# Monitor SSH configuration",
    "-w /etc/ssh/sshd_config -p wa -k sshd_config",
    "-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config",

    "# Monitor sudo usage",
    "-w /etc/sudoers -p wa -k sudoers",
    "-w /etc/sudoers.d/ -p wa -k sudoers",
    "-w /var/log/sudo.log -p wa -k sudo_log",

    "# Monitor file deletions",
    "-a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat -k file_deletion",

    "# Monitor kernel module loading",
    "-w /sbin/insmod -p x -k kernel_modules",
    "-w /sbin/rmmod -p x -k kernel_modules",
    "-w /sbin/modprobe -p x -k kernel_modules",

    "# Monitor cron",
    "-w /etc/crontab -p wa -k cron",
    "-w /etc/cron.d/ -p wa -k cron",
    "-w /var/spool/cron/ -p wa -k cron",

    "# Make audit configuration immutable (requires reboot to change)",
    "-e 2",
    "AUDIT",

    # Enable and start auditd
    "systemctl enable auditd",
    "systemctl restart auditd",

    # Configure log rotation
    "cat > /etc/audit/auditd.conf.d/rotation.conf <<'CONF' || true",
    "max_log_file = 50",
    "max_log_file_action = rotate",
    "num_logs = 10",
    "CONF"
  ]
}
```

---

## Removing Build-Time Credentials

**Critical**: Always clean up credentials, keys, and build artifacts as the last provisioner step.

```hcl
# This MUST be the last provisioner (or second-to-last before Azure waagent)
provisioner "shell" {
  execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
  inline = [
    "echo '=== Cleaning build-time credentials ==='",

    # Remove SSH authorized keys (cloud-init will re-add on launch)
    "rm -f /home/*/.ssh/authorized_keys",
    "rm -f /root/.ssh/authorized_keys",

    # Remove SSH host keys (will be regenerated on first boot)
    "rm -f /etc/ssh/ssh_host_*",

    # Clear shell history
    "find /home -name '.bash_history' -delete",
    "find /root -name '.bash_history' -delete 2>/dev/null || true",
    "unset HISTFILE",
    "history -c",

    # Remove temporary files and caches
    "rm -rf /tmp/* /var/tmp/*",
    "rm -rf /var/cache/apt/archives/*.deb",
    "apt-get clean",

    # Remove cloud-init artifacts (will re-run on next boot)
    "cloud-init clean --logs --seed",

    # Remove Packer-specific artifacts
    "rm -rf /tmp/packer-*",
    "rm -rf /var/log/packer*",

    # Remove any downloaded credentials/tokens
    "rm -f /root/.aws/credentials",
    "rm -f /home/*/.aws/credentials",
    "rm -rf /root/.config/gcloud",

    # Remove build-time environment variables from any profile
    "sed -i '/PKR_VAR_/d' /etc/environment 2>/dev/null || true",
    "sed -i '/AWS_/d' /etc/environment 2>/dev/null || true",
    "sed -i '/HCP_/d' /etc/environment 2>/dev/null || true",

    # Remove package manager caches
    "apt-get autoremove -y",
    "apt-get clean",
    "rm -rf /var/lib/apt/lists/*",

    # Zero out free space (optional, reduces AMI size)
    "dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true",
    "rm -f /EMPTY",

    # Final sync
    "sync"
  ]
}
```

### Credential Verification Provisioner

```hcl
# Run AFTER cleanup to verify no secrets remain
provisioner "shell" {
  inline = [
    "echo '=== Verifying credential cleanup ==='",
    "FAIL=0",

    # Check for AWS credentials
    "if find / -name 'credentials' -path '*/.aws/*' 2>/dev/null | grep -q '.'; then echo 'FAIL: AWS credentials found'; FAIL=1; fi",

    # Check for private keys (excluding SSH host keys placeholder)
    "if find /home /root -name '*.pem' -o -name '*_rsa' -o -name '*_dsa' -o -name '*_ecdsa' 2>/dev/null | grep -q '.'; then echo 'FAIL: Private keys found'; FAIL=1; fi",

    # Check for .env files with secrets
    "if find /opt /srv /app -name '.env' 2>/dev/null | grep -q '.'; then echo 'WARN: .env files found — verify no secrets'; fi",

    # Check for shell history
    "if find /home /root -name '.bash_history' -size +0 2>/dev/null | grep -q '.'; then echo 'FAIL: Shell history not cleared'; FAIL=1; fi",

    "if [ $FAIL -eq 0 ]; then echo 'All credential checks passed'; else exit 1; fi"
  ]
}
```

---

## Image Signing

### Cosign

#### Sign AMI Manifest

```hcl
# Post-processor to sign the manifest with cosign
post-processor "shell-local" {
  inline = [
    # Sign the manifest file
    "cosign sign-blob --key cosign.key --output-signature manifest.sig packer-manifest.json",

    # Verify
    "cosign verify-blob --key cosign.pub --signature manifest.sig packer-manifest.json",

    # Upload signature as AMI tag
    "AMI_ID=$(jq -r '.builds[-1].artifact_id' packer-manifest.json | cut -d: -f2)",
    "SIGNATURE=$(base64 -w0 manifest.sig)",
    "aws ec2 create-tags --resources $AMI_ID --tags Key=cosign-signature,Value=$SIGNATURE"
  ]
}
```

#### Sign Container Images

```hcl
post-processor "shell-local" {
  inline = [
    # Sign with cosign keyless (using OIDC)
    "cosign sign --yes ${var.registry}/myapp:${var.version}",

    # Or sign with a key
    "cosign sign --key cosign.key ${var.registry}/myapp:${var.version}",

    # Attach SBOM
    "cosign attach sbom --sbom sbom.spdx.json ${var.registry}/myapp:${var.version}",

    # Verify
    "cosign verify --key cosign.pub ${var.registry}/myapp:${var.version}"
  ]
  environment_vars = [
    "COSIGN_EXPERIMENTAL=1"   # For keyless signing
  ]
}
```

#### Cosign Key Management

```bash
# Generate a key pair
cosign generate-key-pair

# Generate with KMS
cosign generate-key-pair --kms awskms:///alias/cosign-packer

# Sign with KMS key
cosign sign --key awskms:///alias/cosign-packer myimage:latest
```

### Notation

```hcl
post-processor "shell-local" {
  inline = [
    # Sign with notation (CNCF standard)
    "notation sign ${var.registry}/myapp:${var.version}",

    # Sign with a specific key
    "notation sign --key mykey ${var.registry}/myapp:${var.version}",

    # Verify
    "notation verify ${var.registry}/myapp:${var.version}"
  ]
}
```

```bash
# Setup notation with AWS Signer
notation key add --plugin com.amazonaws.signer.notation.plugin \
  --id arn:aws:signer:us-east-1:111111111111:/signing-profiles/PackerImages \
  --default mykey

# Sign
notation sign --key mykey myregistry.com/myapp:v1.0

# Configure trust policy
cat > ~/.config/notation/trustpolicy.json <<'EOF'
{
  "version": "1.0",
  "trustPolicies": [{
    "name": "packer-images",
    "registryScopes": ["myregistry.com/myapp"],
    "signatureVerification": { "level": "strict" },
    "trustStores": ["ca:mystore"],
    "trustedIdentities": ["*"]
  }]
}
EOF
```

---

## Supply Chain Security

### SLSA Framework Integration

```hcl
build {
  sources = ["source.amazon-ebs.ubuntu"]

  # Record provenance metadata
  hcp_packer_registry {
    bucket_name = "ubuntu-base"
    build_labels = {
      git_sha     = var.git_sha
      git_ref     = var.git_ref
      ci_pipeline = var.ci_pipeline_url
      builder     = "github-actions"
      slsa_level  = "2"
    }
  }

  # ... provisioners ...

  # Generate provenance attestation
  post-processor "shell-local" {
    inline = [
      "AMI_ID=$(jq -r '.builds[-1].artifact_id' packer-manifest.json | cut -d: -f2)",
      "cat > provenance.json <<EOF",
      "{",
      "  \"_type\": \"https://in-toto.io/Statement/v0.1\",",
      "  \"subject\": [{\"name\": \"$AMI_ID\"}],",
      "  \"predicateType\": \"https://slsa.dev/provenance/v0.2\",",
      "  \"predicate\": {",
      "    \"builder\": {\"id\": \"${var.ci_pipeline_url}\"},",
      "    \"buildType\": \"packer\",",
      "    \"invocation\": {",
      "      \"configSource\": {",
      "        \"uri\": \"git+https://github.com/${var.repo}\",",
      "        \"digest\": {\"sha1\": \"${var.git_sha}\"},",
      "        \"entryPoint\": \"packer/\"",
      "      }",
      "    },",
      "    \"metadata\": {",
      "      \"buildStartedOn\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",",
      "      \"completeness\": {\"parameters\": true, \"environment\": true, \"materials\": true}",
      "    }",
      "  }",
      "}",
      "EOF",
      "cosign attest --key cosign.key --predicate provenance.json --type slsaprovenance $AMI_ID || true"
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
```

### Dependency Pinning

```hcl
packer {
  required_version = "= 1.10.3"   # Exact Packer version
  required_plugins {
    amazon = {
      version = "= 1.3.2"         # Exact plugin versions
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# Pin package versions in provisioners
provisioner "shell" {
  inline = [
    "apt-get install -y nginx=1.24.0-1ubuntu1 --allow-downgrades",
    "apt-mark hold nginx"           # Prevent auto-upgrade
  ]
}
```

---

## SBOM Generation

### Syft (SPDX and CycloneDX)

```hcl
# Generate SBOM during build
provisioner "shell" {
  inline = [
    "curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin",

    # SPDX format
    "sudo syft dir:/ --output spdx-json=/tmp/sbom-spdx.json",

    # CycloneDX format
    "sudo syft dir:/ --output cyclonedx-json=/tmp/sbom-cdx.json",

    "sudo rm /usr/local/bin/syft"
  ]
}

# Download SBOM
provisioner "file" {
  source      = "/tmp/sbom-spdx.json"
  destination = "reports/sbom-spdx.json"
  direction   = "download"
}

provisioner "file" {
  source      = "/tmp/sbom-cdx.json"
  destination = "reports/sbom-cdx.json"
  direction   = "download"
}
```

### Container SBOM

```hcl
post-processor "shell-local" {
  inline = [
    # Generate SBOM for container
    "syft ${var.registry}/myapp:${var.version} -o spdx-json > sbom.spdx.json",
    "syft ${var.registry}/myapp:${var.version} -o cyclonedx-json > sbom.cdx.json",

    # Attach SBOM to image with cosign
    "cosign attach sbom --sbom sbom.spdx.json ${var.registry}/myapp:${var.version}",

    # Scan SBOM for vulnerabilities
    "grype sbom:sbom.spdx.json --fail-on high"
  ]
}
```

### SBOM in CI/CD Pipeline

```yaml
# In GitHub Actions
- name: Generate and Upload SBOM
  run: |
    # Generate SBOM from built image
    syft dir:/ -o spdx-json > sbom.spdx.json

    # Upload as build artifact
    aws s3 cp sbom.spdx.json s3://my-sboms/$(date +%Y%m%d)/$AMI_ID/sbom.spdx.json

    # Tag AMI with SBOM location
    aws ec2 create-tags --resources $AMI_ID \
      --tags Key=sbom-url,Value=s3://my-sboms/$(date +%Y%m%d)/$AMI_ID/sbom.spdx.json
```

### Hardening Verification Checklist

| Category | Check | Tool |
|----------|-------|------|
| Vulnerabilities | No HIGH/CRITICAL CVEs | Trivy, Grype |
| CIS Benchmark | Level 1 compliant | ansible-lockdown, InSpec |
| STIG | CAT I/II findings resolved | DISA SCAP, OpenSCAP |
| SSH | Hardened config, no weak keys | `sshd -T`, manual audit |
| Firewall | Default deny, minimal allow | `ufw status`, `iptables -L` |
| Audit | auditd enabled, rules loaded | `auditctl -l` |
| Credentials | No secrets in image | Custom scan script |
| Signing | Image/manifest signed | cosign verify |
| SBOM | Generated and attached | Syft, `cosign verify-attestation` |
| Supply Chain | Provenance attestation | SLSA verifier |
