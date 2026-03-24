---
name: ssh-tunneling
description: >
  SSH tunneling, port forwarding, and secure connectivity expert. Use when user needs SSH tunnels
  (local -L, remote -R, dynamic -D), port forwarding, jump hosts (ProxyJump, -J), SOCKS proxy,
  SSH config (~/.ssh/config) patterns, key management (ssh-keygen, ssh-agent, ssh-add), connection
  multiplexing (ControlMaster), autossh persistent tunnels, bastion host architectures, SSH
  certificates, sshfs mounting, SSH hardening, reverse tunnels, SSH over HTTP proxy, X11 forwarding,
  or SSH troubleshooting. NOT for VPN setup (use WireGuard/OpenVPN instead), NOT for SCP/rsync file
  transfer details, NOT for web server configuration (Nginx/Apache/Caddy), NOT for container
  networking (use Docker/Kubernetes networking), NOT for DNS configuration.
---

# SSH Tunneling & Secure Connectivity

## Core Principles

- Always prefer Ed25519 keys over RSA. Use key-based auth exclusively.
- Use ProxyJump over agent forwarding. Never forward agents to untrusted hosts.
- Apply least-privilege: restrict forwarding, users, and ports in sshd_config.
- Use ControlMaster multiplexing for repeated connections to the same host.
- Use autossh or systemd for any tunnel that must survive disconnects.
- Add `-N` (no remote command) and `-f` (background) for tunnel-only connections.

## Key Management

### Generate Keys

```bash
# Preferred: Ed25519 (fast, secure, small keys)
ssh-keygen -t ed25519 -a 100 -C "user@host" -f ~/.ssh/id_ed25519
# Legacy: ssh-keygen -t rsa -b 4096 -a 100 -C "user@host" -f ~/.ssh/id_rsa
```

Always set a strong passphrase. Use `-a 100` for extra KDF rounds.

### ssh-agent and ssh-add

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519          # Add key (prompts for passphrase once)
ssh-add -l                         # List loaded keys
ssh-add -D                         # Remove all keys
ssh-add -t 4h ~/.ssh/id_ed25519   # Add with auto-expiry
```

### Deploy Public Key

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@remote-host
```

## Port Forwarding

### Local Port Forwarding (-L)

Forward a local port to a remote service through the SSH server.

```bash
# Syntax: ssh -L [bind_address:]local_port:remote_host:remote_port user@ssh-server
ssh -L 8080:internal-app:80 user@bastion -N
# Access internal-app:80 at localhost:8080

# Database access through bastion
ssh -L 5432:db.internal:5432 user@bastion -N -f
# Connect: psql -h localhost -p 5432 -U dbuser mydb

# MySQL through tunnel
ssh -L 3306:mysql.internal:3306 user@bastion -N -f
# Connect: mysql -h 127.0.0.1 -P 3306 -u dbuser -p

# Multiple forwards in one connection
ssh -L 5432:db1:5432 -L 3306:db2:3306 -L 6379:redis:6379 user@bastion -N

# Bind to all interfaces (allow other machines to use your tunnel)
ssh -L 0.0.0.0:8080:internal:80 user@bastion -N
```

### Remote Port Forwarding (-R)

Expose a local service on the remote server (reverse tunnel).

```bash
# Syntax: ssh -R [bind_address:]remote_port:local_host:local_port user@ssh-server
ssh -R 9090:localhost:3000 user@public-server -N
# public-server:9090 now reaches your localhost:3000

# Expose local dev server publicly (requires GatewayPorts yes in sshd_config)
ssh -R 0.0.0.0:80:localhost:8080 user@public-server -N
```

### Dynamic Port Forwarding / SOCKS Proxy (-D)

Create a local SOCKS5 proxy that tunnels all traffic through the SSH server.

```bash
# Syntax: ssh -D [bind_address:]port user@ssh-server
ssh -D 1080 user@remote-server -N -f

# Use with curl
curl --socks5-hostname localhost:1080 http://internal-site.corp

# Configure browser: SOCKS5 proxy localhost:1080
# Bind to all interfaces for LAN sharing: ssh -D 0.0.0.0:1080 user@remote -N
```

## Jump Hosts & Bastion Patterns

### ProxyJump (-J)

```bash
ssh -J user@bastion user@internal-host                          # Single jump
ssh -J user@bastion1,user@bastion2 user@final-target            # Chained jumps
ssh -J user@bastion -L 5432:db:5432 user@app-server -N          # Jump + forward
# Legacy (OpenSSH < 7.3): ssh -o ProxyCommand="ssh -W %h:%p user@bastion" user@host
```

### Bastion Architecture in SSH Config

```ssh-config
# ~/.ssh/config

# Bastion / Jump host
Host bastion
    HostName bastion.example.com
    User ops
    IdentityFile ~/.ssh/id_ed25519_bastion
    ForwardAgent no

# Internal hosts accessed via bastion
Host app-*.internal
    ProxyJump bastion
    User deploy
    IdentityFile ~/.ssh/id_ed25519_deploy

Host db.internal
    HostName 10.0.1.50
    ProxyJump bastion
    User postgres
    LocalForward 5432 localhost:5432

# Multi-hop: bastion -> middleware -> target
Host deep-internal
    HostName 10.10.0.5
    ProxyJump bastion,middleware
    User admin
```

## SSH Config File (~/.ssh/config)

See [`assets/ssh-config-template`](assets/ssh-config-template) for a full production template.

```ssh-config
# Global defaults
Host *
    AddKeysToAgent yes
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    HashKnownHosts yes
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m

# Specific host
Host prod
    HostName prod.example.com
    User deploy
    Port 2222
    IdentityFile ~/.ssh/id_ed25519_prod
    ForwardAgent no
```

## Connection Multiplexing

ControlMaster reuses a single TCP connection for multiple SSH sessions (configured above in global defaults).

```bash
ssh -O check user@host              # Check if master exists
ssh -O stop user@host               # Stop master connection
ssh -S none user@host               # Bypass multiplexing
ssh -O forward -L 8080:localhost:80 user@host  # Add forward to existing connection
```

## Persistent Tunnels with autossh

```bash
sudo apt install autossh  # Debian/Ubuntu; brew install autossh on macOS

# Persistent local forward (-M 0 uses SSH keepalives instead of monitor port)
autossh -M 0 -f -N -L 5432:db:5432 user@bastion \
  -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3"

# Persistent SOCKS proxy
autossh -M 0 -f -N -D 1080 user@proxy-server

# Persistent reverse tunnel
autossh -M 0 -f -N -R 2222:localhost:22 user@public-server
```

### systemd Service for autossh

```ini
# /etc/systemd/system/ssh-tunnel-db.service
[Unit]
Description=SSH tunnel to database
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tunnel-user
Environment="AUTOSSH_GATETIME=0"
ExecStart=/usr/bin/autossh -M 0 -N -L 5432:db.internal:5432 ops@bastion \
  -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" \
  -o "ExitOnForwardFailure yes" -i /home/tunnel-user/.ssh/id_ed25519
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now ssh-tunnel-db
sudo systemctl status ssh-tunnel-db
journalctl -u ssh-tunnel-db -f
```

## SSH over HTTP Proxy

When SSH is blocked and only HTTP/HTTPS proxies are available.

```ssh-config
# Using netcat (nc/ncat)
Host remote-via-proxy
    HostName remote.example.com
    ProxyCommand nc -X connect -x proxy.corp.com:3128 %h %p

# Using socat
Host remote-via-socat
    HostName remote.example.com
    ProxyCommand socat - PROXY:proxy.corp.com:%h:%p,proxyport=3128

# Using corkscrew (HTTP CONNECT)
Host remote-via-corkscrew
    HostName remote.example.com
    ProxyCommand corkscrew proxy.corp.com 3128 %h %p

# With proxy authentication (corkscrew)
# Create ~/.ssh/proxy_auth with: username:password
Host remote-auth-proxy
    ProxyCommand corkscrew proxy.corp.com 3128 %h %p ~/.ssh/proxy_auth
```

## SSHFS - Remote Filesystem Mounting

```bash
# Mount remote directory locally
sshfs user@remote:/var/www /mnt/remote-www

# With options for better performance
sshfs user@remote:/path /mnt/point \
  -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \
  -o cache=yes,kernel_cache,compression=yes

# Through jump host
sshfs -o ProxyJump=user@bastion user@internal:/data /mnt/data

# Unmount
fusermount -u /mnt/remote-www   # Linux
umount /mnt/remote-www          # macOS

# fstab entry for persistent mount
# user@remote:/path /mnt/point fuse.sshfs defaults,_netdev,reconnect,IdentityFile=/home/user/.ssh/id_ed25519 0 0
```

## SSH Certificates (CA-Signed Keys)

Scalable alternative to managing authorized_keys on every host.

```bash
# Generate CA key pair (do once, protect private key)
ssh-keygen -t ed25519 -f /etc/ssh/ca_key -C "SSH CA"

# Sign a user key (valid 52 weeks, for user "alice", identity "alice-laptop")
ssh-keygen -s /etc/ssh/ca_key -I alice-laptop -n alice -V +52w ~/.ssh/id_ed25519.pub
# Produces: ~/.ssh/id_ed25519-cert.pub

# Sign a host key
ssh-keygen -s /etc/ssh/ca_key -I web-server -h -V +52w /etc/ssh/ssh_host_ed25519_key.pub

# Server: TrustedUserCAKeys /etc/ssh/ca_key.pub  (in sshd_config)
# Client: @cert-authority *.example.com <ca_key.pub contents>  (in known_hosts)

# Inspect certificate
ssh-keygen -L -f ~/.ssh/id_ed25519-cert.pub
```

## X11 Forwarding

```bash
# Forward X11 (restricted)
ssh -X user@remote
# Then run GUI apps: firefox, xterm, etc.

# Trusted X11 forwarding (less secure, fewer restrictions)
ssh -Y user@remote

# Verify DISPLAY is set on remote
echo $DISPLAY   # Should show localhost:10.0 or similar
```

Server requires `X11Forwarding yes` in sshd_config. Install `xauth` on server.

## SSH Escape Sequences

While in an SSH session, press Enter then:

| Sequence | Action |
|----------|--------|
| `~.` | Terminate connection (kill hung session) |
| `~^Z` | Suspend SSH (background the client) |
| `~#` | List forwarded connections |
| `~C` | Open SSH command line (add forwards on-the-fly) |
| `~&` | Background SSH when waiting for forwarded connections to close |
| `~?` | Show all escape sequences |

Using `~C` to add forwards dynamically:

```
ssh> -L 8080:localhost:80    # Add local forward
ssh> -R 9090:localhost:3000  # Add remote forward
ssh> -D 1080                 # Add SOCKS proxy
ssh> -KL 8080               # Cancel local forward
```

## SSH Hardening (sshd_config)

See [`assets/sshd-hardened.conf`](assets/sshd-hardened.conf) for a complete hardened template
and [`references/security-hardening.md`](references/security-hardening.md) for crypto rationale.

```ssh-config
# /etc/ssh/sshd_config — Key settings
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
AllowUsers alice bob deploy
AllowTcpForwarding local
X11Forwarding no
AllowAgentForwarding no
LogLevel VERBOSE
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
```

### fail2ban for SSH

```ini
# /etc/fail2ban/jail.local
[sshd]
enabled = true
port = 2222
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
```

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

## Agent Forwarding - Risks and Alternatives

**Risks of -A / ForwardAgent yes:**
- Any root user on intermediate hosts can hijack your forwarded agent socket.
- Compromised jump host = attacker can authenticate as you to any downstream host.

**Safer alternatives:**
1. **ProxyJump** - preferred. No keys exposed on intermediate hosts.
2. **Per-host deploy keys** - each server gets its own key pair.
3. **SSH certificates** - time-limited, revocable, centrally managed.
4. If you must forward: use `ForwardAgent` only for specific trusted hosts, never globally.

```ssh-config
# WRONG - global agent forwarding
Host *
    ForwardAgent yes

# RIGHT - only to trusted host
Host trusted-server
    ForwardAgent yes
Host *
    ForwardAgent no
```

## Troubleshooting

### Verbose Output

```bash
ssh -v user@host       # Basic debug
ssh -vv user@host      # More detail
ssh -vvv user@host     # Maximum verbosity - shows key exchange, auth attempts

# Common issues visible in debug output:
# - "Permission denied (publickey)" -> key not accepted, wrong user, key not in authorized_keys
# - "Connection refused" -> sshd not running or wrong port
# - "Connection timed out" -> firewall blocking, wrong host
# - "Host key verification failed" -> host key changed (MITM or server rebuilt)
```

### Common Fixes

```bash
# Fix permissions (SSH is strict about this)
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519 ~/.ssh/config ~/.ssh/authorized_keys
chmod 644 ~/.ssh/id_ed25519.pub ~/.ssh/known_hosts

# Remove stale known_hosts entry
ssh-keygen -R hostname

# Test config syntax (server-side)
sshd -t

# Check if sshd is listening
ss -tlnp | grep ssh

# Check auth log
sudo tail -f /var/log/auth.log         # Debian/Ubuntu
sudo tail -f /var/log/secure           # RHEL/CentOS

# Test specific key
ssh -i ~/.ssh/id_ed25519 -v user@host

# Port forwarding not working? Check:
# 1. AllowTcpForwarding in sshd_config
# 2. Target service is actually listening
# 3. Firewall rules on both ends
# 4. GatewayPorts if binding to 0.0.0.0
```

## Quick Reference: Common Tunnel Patterns

```bash
# Access remote Postgres through bastion
ssh -L 5432:db.internal:5432 -J user@bastion user@db-host -N

# Access remote Redis
ssh -L 6379:redis.internal:6379 user@bastion -N

# Expose local dev to the internet via VPS
ssh -R 80:localhost:3000 user@vps -N

# SOCKS proxy for all traffic through remote
ssh -D 1080 user@remote -N

# Mount remote filesystem
sshfs -o ProxyJump=user@bastion user@app:/var/log /mnt/logs

# Persistent database tunnel via systemd + autossh
autossh -M 0 -N -L 5432:db:5432 user@bastion -o ExitOnForwardFailure=yes
```

---

## Additional Resources

### References (Deep-Dive Guides)

| File | Description |
|------|-------------|
| [`references/advanced-patterns.md`](references/advanced-patterns.md) | SSH certificates (CA setup, signing, principals), SSH over HTTPS (stunnel/socat), reverse tunnels for IoT/NAT, SSH multiplexing internals, SOCKS proxy chaining, SSH VPN (tun/tap), Docker/Kubernetes integration, SSHPiper multi-tenant bastion |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Systematic SSH debugging: timeout analysis, key auth failures, agent forwarding, tunnel diagnosis, "channel open failed" errors, broken pipe fixes, DNS in tunnels, MTU issues, SELinux/firewall, sshd_config mistakes |
| [`references/security-hardening.md`](references/security-hardening.md) | Hardened crypto config (KEX, ciphers, MACs), key rotation strategies, SSH CA vs authorized_keys at scale, bastion architecture, session recording, 2FA (TOTP, FIDO2/U2F), audit tools, port knocking, AllowUsers/AllowGroups patterns |

### Scripts (Executable Tools)

| File | Description |
|------|-------------|
| [`scripts/ssh-tunnel-manager.sh`](scripts/ssh-tunnel-manager.sh) | Create, list, destroy, and auto-reconnect persistent SSH tunnels with optional systemd integration |
| [`scripts/ssh-key-setup.sh`](scripts/ssh-key-setup.sh) | Automated key generation, deployment, agent setup, and SSH config entry creation for new hosts |
| [`scripts/ssh-audit.sh`](scripts/ssh-audit.sh) | Audit local or remote SSH server configuration: cipher strength, key types, auth methods, security recommendations |

### Assets (Copy-Paste Ready)

| File | Description |
|------|-------------|
| [`assets/ssh-config-template`](assets/ssh-config-template) | Production `~/.ssh/config` with bastion, multiplexing, per-host keys, tunnels, and SOCKS proxy patterns |
| [`assets/sshd-hardened.conf`](assets/sshd-hardened.conf) | Hardened `sshd_config` template with modern crypto, strict auth, access control, and per-group overrides |
| [`assets/autossh.service`](assets/autossh.service) | Systemd service template for persistent SSH tunnels via autossh with security hardening |
| [`assets/ssh-ca-setup.md`](assets/ssh-ca-setup.md) | Step-by-step SSH Certificate Authority setup: CA generation, user/host signing, client trust, revocation, Vault integration |
<!-- tested: pass -->
