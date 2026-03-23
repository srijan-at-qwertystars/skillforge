---
name: ssh-configuration
description: |
  Use when user configures SSH, asks about ssh_config, key generation, ProxyJump, tunneling,
  port forwarding, agent forwarding, sshd_config hardening, or SSH troubleshooting.
  Do NOT use for TLS/HTTPS certificates, VPN configuration, or general network security
  without SSH specifics.
---

# SSH Configuration and Best Practices

## Key Management

### Key Types

Prefer Ed25519. Fall back to RSA 4096 only for legacy systems.

```bash
ssh-keygen -t ed25519 -C "user@host" -f ~/.ssh/id_ed25519          # recommended
ssh-keygen -t rsa -b 4096 -C "user@host" -f ~/.ssh/id_rsa          # legacy fallback
ssh-keygen -t ed25519-sk -C "hardware-key" -f ~/.ssh/id_ed25519_sk  # FIDO2
```

### Passphrases and ssh-agent

Always set a passphrase. Use ssh-agent to avoid re-entering it.

```bash
eval "$(ssh-agent -s)"
ssh-add -t 3600 ~/.ssh/id_ed25519   # add with 1-hour timeout
ssh-add -l                           # list loaded keys
ssh-add -D                           # remove all (do before leaving workstation)
```

### Key Rotation

- Rotate keys annually or on personnel changes.
- Audit: `ssh-keygen -l -f ~/.ssh/authorized_keys` to list fingerprints.
- Remove stale entries from `authorized_keys` on all hosts.
- Use certificate-based auth for automated rotation at scale.

---

## ssh_config Patterns

### Host Blocks

Place in `~/.ssh/config`. More specific Host entries go first; `Host *` defaults go last.

```sshconfig
Host prod-web
    HostName 10.0.1.50
    User deploy
    Port 2222
    IdentityFile ~/.ssh/id_ed25519_prod
    IdentitiesOnly yes

Host staging-*
    User admin
    IdentityFile ~/.ssh/id_ed25519_staging
    ProxyJump bastion-staging

Host *
    AddKeysToAgent yes
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    HashKnownHosts yes
```

### Match Blocks

Use `Match` for conditional configuration based on user, host, or network.

```sshconfig
Match Host *.internal exec "ip route | grep -q 10.0.0.0/8"
    ProxyJump none
    ForwardAgent no

Match User deployer
    IdentityFile ~/.ssh/id_ed25519_deploy
    ForwardAgent no
```

---

## Port Forwarding

### Local Forwarding

```bash
ssh -L 5432:remote-db.internal:5432 user@ssh-host -N      # access remote DB locally
ssh -L 0.0.0.0:8080:internal-app:80 user@ssh-host -N      # bind to all interfaces
```

### Remote Forwarding

```bash
ssh -R 9000:localhost:3000 user@remote-host -N   # expose local:3000 as remote:9000
```

### Dynamic Forwarding (SOCKS Proxy)

```bash
ssh -D 1080 user@ssh-host -N                                        # SOCKS5 proxy
curl --socks5-hostname localhost:1080 http://internal-service.corp   # use it
```

### Persistent Tunnels with autossh

```bash
autossh -M 20000 -f -N -L 5432:db.internal:5432 user@bastion
```

---

## Tunneling Patterns

### Database Access Through Bastion

```sshconfig
Host db-tunnel
    HostName bastion.example.com
    User tunnel-user
    LocalForward 5432 postgres.internal:5432
    LocalForward 6379 redis.internal:6379
    IdentityFile ~/.ssh/id_ed25519_tunnel
    RequestTTY no
    ExitOnForwardFailure yes
```

```bash
ssh -f -N db-tunnel
psql -h localhost -p 5432 -U dbuser mydb
```

### Reverse Tunnel for NAT Traversal

```bash
# On NATted machine — expose its port 22 via public-server:2222
ssh -R 2222:localhost:22 user@public-server -N

# Connect from anywhere through public-server
ssh -p 2222 user@public-server
```

---

## Agent Forwarding

### How It Works

Agent forwarding exposes `SSH_AUTH_SOCK` on the remote host, letting it use keys from your local agent.

```sshconfig
Host trusted-bastion
    ForwardAgent yes       # enable ONLY for trusted hosts
```

### Risks

- Root on the remote host can hijack your forwarded agent socket.
- Compromised intermediaries gain access to all loaded keys.

### Prefer ProxyJump Instead

ProxyJump never exposes keys or agent sockets on intermediate hosts.

```bash
ssh -J bastion.example.com internal-host          # CLI

# ssh_config equivalent
Host internal-host
    ProxyJump bastion.example.com
```

---

## sshd_config Hardening

### Essential Settings

```sshconfig
# /etc/ssh/sshd_config

# Authentication
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 20

# Access control
AllowUsers deploy admin
AllowGroups ssh-users

# Network
Port 2222
ListenAddress 10.0.1.1
AddressFamily inet

# Features to disable
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no

# Crypto hardening
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512

# Logging
LogLevel VERBOSE
```

### fail2ban Integration

```ini
# /etc/fail2ban/jail.d/sshd.conf
[sshd]
enabled = true
port = 2222
maxretry = 3
bantime = 3600
findtime = 600
```

### Two-Factor Authentication (TOTP)

```bash
apt install libpam-google-authenticator
google-authenticator -t -d -f -r 3 -R 30 -w 3    # run per user
```

Add to `/etc/pam.d/sshd`: `auth required pam_google_authenticator.so`

Set in sshd_config:
```
AuthenticationMethods publickey,keyboard-interactive
KbdInteractiveAuthentication yes
```

---

## Certificate-Based Authentication

### Set Up a CA

```bash
# Generate CA key pair (protect this private key!)
ssh-keygen -t ed25519 -f /etc/ssh/ca_user_key -C "SSH User CA"
ssh-keygen -t ed25519 -f /etc/ssh/ca_host_key -C "SSH Host CA"
```

### Sign User Keys

```bash
# Sign a user's public key with validity period
ssh-keygen -s /etc/ssh/ca_user_key \
  -I "user@example.com" \
  -n deploy,admin \
  -V +52w \
  ~/.ssh/id_ed25519.pub
# Produces ~/.ssh/id_ed25519-cert.pub
```

### Sign Host Keys

```bash
# Sign a host key to eliminate TOFU warnings
ssh-keygen -s /etc/ssh/ca_host_key \
  -I "web-01.example.com" \
  -h \
  -n web-01.example.com,10.0.1.50 \
  -V +52w \
  /etc/ssh/ssh_host_ed25519_key.pub
```

### Configure Trust

On servers (`sshd_config`):
```
TrustedUserCAKeys /etc/ssh/ca_user_key.pub
```

On clients (`~/.ssh/known_hosts` or `ssh_config`):
```
@cert-authority *.example.com ssh-ed25519 AAAA...
```

### Revocation

```bash
# Create or update a Key Revocation List
ssh-keygen -k -f /etc/ssh/revoked_keys -s /etc/ssh/ca_user_key compromised_key.pub
```

In `sshd_config`:
```
RevokedKeys /etc/ssh/revoked_keys
```

---

## Multiplexing

### Configuration

```sshconfig
Host *
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

### Management

```bash
ssh -O check prod-web   # check status
ssh -O exit prod-web    # graceful close
ssh -O stop prod-web    # force stop
```

- Eliminates TCP handshake and key exchange on subsequent connections.
- If the master drops, all multiplexed sessions fail — set reasonable `ControlPersist`.
- Use distinct `ControlPath` patterns to avoid socket collisions.

---

## Jump Hosts and Bastion Patterns

### ProxyJump Chains

```sshconfig
Host bastion
    HostName bastion.example.com
    User jump-user
    IdentityFile ~/.ssh/id_ed25519_bastion

Host internal-app
    HostName 10.0.5.20
    User app-user
    ProxyJump bastion

# Multi-hop chain
Host deep-internal
    HostName 172.16.0.10
    ProxyJump bastion,mid-tier-host
```

```bash
# CLI multi-hop
ssh -J bastion.example.com,mid.example.com user@172.16.0.10
```

### Session Recording and Audit

- Use `script` or `ttyrec` on bastion hosts. Configure `ForceCommand` to wrap sessions.
- Ship auth logs to a SIEM (journald → Elasticsearch/Splunk).

```sshconfig
Match Group bastion-users
    ForceCommand /usr/local/bin/record-session.sh
    AllowTcpForwarding yes
```

---

## SCP/SFTP/rsync Over SSH

### SCP

```bash
scp -i ~/.ssh/id_ed25519 file.tar.gz user@host:/tmp/
scp -o ProxyJump=bastion file.tar.gz user@internal:/tmp/    # through jump host
```

### SFTP

```bash
sftp -i ~/.ssh/id_ed25519 user@host      # interactive
sftp -b commands.txt user@host            # batch mode
```

### rsync Over SSH

```bash
rsync -avz --partial --progress --bwlimit=5000 \
  -e "ssh -i ~/.ssh/id_ed25519" ./data/ user@host:/backup/data/

rsync -avz -e "ssh -J bastion" ./data/ user@internal:/backup/   # through jump host
```

---

## Troubleshooting

### Verbose Connection Debugging

```bash
ssh -v user@host      # basic
ssh -vv user@host     # detailed
ssh -vvv user@host    # maximum verbosity
```

### Common Issues and Fixes

| Symptom | Likely Cause | Fix |
|---|---|---|
| `Permission denied (publickey)` | Wrong key, key not in authorized_keys, file permissions | Check `IdentityFile`, run `ssh-add -l`, verify `~/.ssh` is 700 and keys are 600 |
| `Connection refused` | sshd not running or wrong port | Verify `systemctl status sshd`, check `Port` in sshd_config |
| `Connection timed out` | Firewall blocking, wrong IP | Check `iptables`/`nftables`, security groups, verify host reachability |
| `Host key verification failed` | Host key changed (reinstall, MITM) | Verify legitimacy, then `ssh-keygen -R hostname` |
| `Too many authentication failures` | Agent offering too many keys | Use `IdentitiesOnly yes` in ssh_config |
| `Broken pipe` | Idle timeout | Set `ServerAliveInterval 60` and `ServerAliveCountMax 3` |

### Permission Requirements

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
chmod 644 ~/.ssh/authorized_keys   # 600 also acceptable
chmod 644 ~/.ssh/config
```

---

## Modern Features

### FIDO2 / Security Keys

Hardware-backed keys provide phishing-resistant auth requiring physical touch.

```bash
ssh-keygen -t ed25519-sk -O resident -C "yubikey"         # resident key on device
ssh-keygen -t ed25519-sk -O verify-required -C "yubikey"   # require touch
ssh-keygen -K                                               # import on new machine
```

### SSH Over HTTPS (Port 443)

Bypass restrictive firewalls by wrapping SSH in HTTPS.

```nginx
# nginx stream proxy: route SSH vs HTTPS by protocol detection
stream {
    upstream ssh_backend  { server 127.0.0.1:22; }
    upstream web_backend  { server 127.0.0.1:8443; }

    map $ssl_preread_protocol $upstream {
        ""        ssh_backend;
        default   web_backend;
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass $upstream;
    }
}
```

### QUIC-Based SSH (SSH3/SSHOQ)

Experimental. Runs SSH over HTTP/3 (QUIC) for faster handshakes, connection migration, and UDP forwarding. Not yet in mainline OpenSSH — evaluate for forward-looking architectures.

---

## Anti-Patterns

Avoid these configurations:

```sshconfig
# DANGEROUS: wildcard agent forwarding
Host *
    ForwardAgent yes           # Exposes keys to every host

# DANGEROUS: permissive server config
PermitRootLogin yes            # Never allow direct root SSH
PasswordAuthentication yes     # Brute-force target
PermitEmptyPasswords yes       # Obvious risk

# DANGEROUS: weak crypto
Ciphers aes128-cbc             # CBC mode is vulnerable
MACs hmac-sha1                 # SHA-1 is deprecated
KexAlgorithms diffie-hellman-group1-sha1   # Weak DH group
```

**Other anti-patterns:**
- Sharing private keys between users or machines.
- Storing private keys without passphrases in automation (use ssh-agent or deploy keys).
- Using `StrictHostKeyChecking no` in production.
- Running sshd on port 22 without fail2ban or rate limiting.
- Leaving default `authorized_keys` entries from former employees.

<!-- tested: pass -->
