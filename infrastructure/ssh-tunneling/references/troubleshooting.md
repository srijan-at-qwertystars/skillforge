# SSH Troubleshooting Guide

> Systematic diagnosis and resolution for SSH connectivity, authentication, tunneling,
> and forwarding problems. Each section includes symptoms, diagnostic commands, root
> causes, and fixes.

## Table of Contents

- [General Debugging Approach](#general-debugging-approach)
- [Connection Timeout Analysis](#connection-timeout-analysis)
  - [Client-Side Timeouts](#client-side-timeouts)
  - [Network-Level Diagnosis](#network-level-diagnosis)
  - [Firewall and Routing Issues](#firewall-and-routing-issues)
- [Key Authentication Failures](#key-authentication-failures)
  - [Permission Denied (publickey)](#permission-denied-publickey)
  - [Wrong Key Offered](#wrong-key-offered)
  - [Certificate Authentication Issues](#certificate-authentication-issues)
- [Agent Forwarding Issues](#agent-forwarding-issues)
  - [Agent Not Available on Jump Host](#agent-not-available-on-jump-host)
  - [Agent Conflict with Local Agent](#agent-conflict-with-local-agent)
  - [Debugging Agent Forwarding](#debugging-agent-forwarding)
- [Tunnel Not Working Diagnosis](#tunnel-not-working-diagnosis)
  - [Local Forward Not Accessible](#local-forward-not-accessible)
  - [Remote Forward Not Binding](#remote-forward-not-binding)
  - [Dynamic Forward (SOCKS) Issues](#dynamic-forward-socks-issues)
- [Channel Open Failed Errors](#channel-open-failed-errors)
  - [Administratively Prohibited](#administratively-prohibited)
  - [Connect Failed](#connect-failed)
  - [Resource Shortage](#resource-shortage)
- [Broken Pipe Fixes](#broken-pipe-fixes)
  - [Keepalive Configuration](#keepalive-configuration)
  - [Network Stability Issues](#network-stability-issues)
  - [Session Persistence Tools](#session-persistence-tools)
- [DNS Resolution in Tunnels](#dns-resolution-in-tunnels)
- [MTU Issues Through Tunnels](#mtu-issues-through-tunnels)
- [SELinux/Firewall Blocking](#selinuxfirewall-blocking)
- [Common sshd_config Mistakes](#common-sshd_config-mistakes)

---

## General Debugging Approach

Always start with verbose output and work through layers systematically:

```bash
# Increasing verbosity levels
ssh -v user@host        # Basic: connection, auth methods, key offers
ssh -vv user@host       # Detailed: key exchange, cipher negotiation
ssh -vvv user@host      # Maximum: packet-level, channel operations

# Server-side debugging (run temporarily for diagnosis)
sudo /usr/sbin/sshd -d -p 2222    # Debug mode on alternate port
# Then connect: ssh -p 2222 -vvv user@host

# Check effective server configuration
sudo sshd -T                       # Dump resolved sshd_config
sudo sshd -T -C user=alice         # Config for specific user
sudo sshd -t                       # Syntax check only

# Real-time log monitoring
sudo journalctl -u sshd -f                    # systemd
sudo tail -f /var/log/auth.log                 # Debian/Ubuntu
sudo tail -f /var/log/secure                   # RHEL/CentOS
```

---

## Connection Timeout Analysis

### Client-Side Timeouts

**Symptom:** `ssh: connect to host X port 22: Connection timed out`

**Diagnostic steps:**

```bash
# 1. Verify DNS resolution
dig +short host.example.com
nslookup host.example.com

# 2. Test TCP connectivity
nc -zv host.example.com 22 -w 5
# or
timeout 5 bash -c 'echo >/dev/tcp/host.example.com/22' && echo "Open" || echo "Closed"

# 3. Trace the network path
traceroute -T -p 22 host.example.com
mtr --tcp --port 22 host.example.com

# 4. Check if SSH is on a non-standard port
nmap -p 22,2222,443 host.example.com
```

### Network-Level Diagnosis

```bash
# Check local routing
ip route get <target-ip>

# Check for packet loss
ping -c 10 host.example.com

# Capture SSH handshake packets
sudo tcpdump -i eth0 -n host <target-ip> and port 22 -c 20

# Check for TCP RST (connection reset)
sudo tcpdump -i eth0 'tcp[tcpflags] & (tcp-rst) != 0' and host <target-ip>
```

### Firewall and Routing Issues

**Common causes and fixes:**

| Cause | Diagnostic | Fix |
|-------|-----------|-----|
| Local firewall blocking | `iptables -L -n \| grep 22` | `iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT` |
| ISP/corporate firewall | `traceroute -T -p 22` (drops at certain hop) | Use SSH over HTTPS (port 443) |
| AWS Security Group | Check SG inbound rules in console | Add inbound rule for port 22 from your IP |
| Host firewall (remote) | Check with hosting provider | `ufw allow 22` or `firewall-cmd --add-port=22/tcp` |
| Wrong subnet/VPC | `ip route get` shows no route | Check VPN connection, VPC peering |

---

## Key Authentication Failures

### Permission Denied (publickey)

**Symptom:** `Permission denied (publickey).`

**Systematic diagnosis:**

```bash
# 1. Check which keys are being offered (look for "Offering" lines)
ssh -vvv user@host 2>&1 | grep -E "Offering|Trying|Authentications"

# 2. Verify the right key exists locally
ls -la ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub

# 3. Check key is loaded in agent
ssh-add -l

# 4. Verify authorized_keys on server
# (connect via console or other method)
cat ~/.ssh/authorized_keys
# Check for: correct key, correct format, no line breaks in key

# 5. Check permissions (SSH is VERY strict)
# On server:
ls -la ~ ~/.ssh ~/.ssh/authorized_keys
# Required:
#   ~ (home dir):           755 or stricter (NOT group/world writable)
#   ~/.ssh:                 700
#   ~/.ssh/authorized_keys: 600
```

**Common fixes:**

```bash
# Fix permissions on server
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chmod go-w ~/

# Fix ownership
chown -R user:user ~/.ssh

# Fix SELinux context (RHEL/CentOS)
restorecon -Rv ~/.ssh

# Verify sshd_config allows pubkey auth
sudo grep -E "PubkeyAuthentication|AuthorizedKeysFile" /etc/ssh/sshd_config
# Should show: PubkeyAuthentication yes
```

### Wrong Key Offered

**Symptom:** SSH offers RSA key when server expects Ed25519, or vice versa.

```bash
# Force a specific key
ssh -i ~/.ssh/id_ed25519 user@host

# In config, use IdentitiesOnly to prevent agent keys from being tried
Host target
    HostName target.example.com
    IdentityFile ~/.ssh/id_ed25519_target
    IdentitiesOnly yes    # ONLY use the specified key
```

### Certificate Authentication Issues

```bash
# Verify certificate is valid
ssh-keygen -L -f ~/.ssh/id_ed25519-cert.pub
# Check: Valid from/to, Principals, Key ID

# Common issues:
# - Certificate expired (check "Valid:" line)
# - Principal mismatch (cert principal != login username)
# - CA not trusted (TrustedUserCAKeys not set on server)
# - Clock skew (certificate appears not yet valid)

# Check server trusts the CA
sudo grep TrustedUserCAKeys /etc/ssh/sshd_config
sudo cat /etc/ssh/ssh_user_ca.pub   # Verify CA pubkey matches

# Debug certificate auth
ssh -vvv user@host 2>&1 | grep -i cert
```

---

## Agent Forwarding Issues

### Agent Not Available on Jump Host

**Symptom:** `Could not open a connection to your authentication agent` on intermediate host.

```bash
# 1. Verify agent is running locally
echo $SSH_AUTH_SOCK    # Should be set
ssh-add -l             # Should list your keys

# 2. Ensure ForwardAgent is enabled for the hop
ssh -A user@jump-host
# or in config:
Host jump-host
    ForwardAgent yes

# 3. On the jump host, check:
echo $SSH_AUTH_SOCK    # Should be set (forwarded socket)
ssh-add -l             # Should show your keys

# 4. Check server allows forwarding
sudo grep AllowAgentForwarding /etc/ssh/sshd_config
# Must be: AllowAgentForwarding yes
```

### Agent Conflict with Local Agent

**Symptom:** Keys visible locally but not on jump host; or wrong keys on jump host.

```bash
# Common cause: shell profile on jump host starts a new agent
# Check ~/.bashrc, ~/.bash_profile, ~/.profile for:
#   eval "$(ssh-agent -s)"
# This overrides the forwarded SSH_AUTH_SOCK!

# Fix: Guard agent startup
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval "$(ssh-agent -s)"
fi
```

### Debugging Agent Forwarding

```bash
# Trace agent socket
ssh -vvv -A user@host 2>&1 | grep -i agent

# Look for:
# "Requesting authentication agent forwarding"  -> client requested
# "Authentication agent forwarding enabled"      -> server allowed it
# "agent_request_forwarding: ..."               -> any errors
```

---

## Tunnel Not Working Diagnosis

### Local Forward Not Accessible

**Symptom:** `ssh -L 8080:target:80 user@host` succeeds but `curl localhost:8080` fails.

```bash
# 1. Verify tunnel is actually established
ssh -O check user@host            # If using multiplexing

# 2. Check if port is listening locally
ss -tlnp | grep 8080
# If not listed, tunnel creation failed silently

# 3. Check if target service is reachable from SSH server
# SSH to the server first, then:
curl http://target:80             # Direct test
nc -zv target 80                  # Port test

# 4. Check sshd_config allows forwarding
sudo sshd -T | grep allowtcpforwarding
# Must be: allowtcpforwarding yes  (or "local" for -L only)

# 5. Check if binding to the right address
ssh -L 127.0.0.1:8080:target:80 user@host -N     # localhost only
ssh -L 0.0.0.0:8080:target:80 user@host -N       # all interfaces
# For 0.0.0.0 binding: needs GatewayPorts yes or clientspecified
```

### Remote Forward Not Binding

**Symptom:** `ssh -R 9090:localhost:3000 user@host` succeeds but remote port isn't accessible.

```bash
# 1. Check if port is listening on remote
# On the SSH server:
ss -tlnp | grep 9090

# 2. By default, remote forwards bind to 127.0.0.1 only
# To bind to all interfaces, on server:
# sshd_config: GatewayPorts yes
# Or per-connection: GatewayPorts clientspecified
# Then: ssh -R 0.0.0.0:9090:localhost:3000 user@host

# 3. Check if port is already in use
ss -tlnp | grep 9090
# "Address already in use" in ssh -vvv output

# 4. Check remote firewall allows the port
sudo iptables -L -n | grep 9090
sudo ufw status | grep 9090
```

### Dynamic Forward (SOCKS) Issues

```bash
# Verify SOCKS proxy is listening
ss -tlnp | grep 1080

# Test SOCKS proxy directly
curl --socks5 localhost:1080 http://ifconfig.me
# Use socks5h for remote DNS resolution:
curl --socks5-hostname localhost:1080 http://internal.corp

# Common issue: application not using SOCKS properly
# Many apps need socks5h:// (not socks5://) for DNS through tunnel
```

---

## Channel Open Failed Errors

### Administratively Prohibited

**Symptom:** `channel N: open failed: administratively prohibited: open failed`

**Root causes and fixes:**

```bash
# 1. TCP forwarding disabled on server
sudo sshd -T | grep allowtcpforwarding
# Fix: AllowTcpForwarding yes (or local/remote)

# 2. User-specific Match block overriding
sudo sshd -T -C user=myuser | grep allowtcpforwarding
# Check for Match blocks in sshd_config

# 3. X11 forwarding disabled
sudo sshd -T | grep x11forwarding
# Fix: X11Forwarding yes (if needed)

# 4. Tunnel device forwarding disabled
sudo sshd -T | grep permittunnel
# Fix: PermitTunnel yes (for -w flag)

# 5. authorized_keys restrictions
# Check for restrict, no-port-forwarding, no-X11-forwarding options
grep "no-port-forwarding\|restrict" ~/.ssh/authorized_keys
```

### Connect Failed

**Symptom:** `channel N: open failed: connect failed: Connection refused`

This means SSH server tried to connect to the forwarding target but failed:

```bash
# The target service isn't running or isn't listening
# If tunneling -L 5432:db.internal:5432, verify:
# ON THE SSH SERVER (not locally):
nc -zv db.internal 5432
# If this fails, the issue is target reachability, not SSH

# Check if target resolves correctly from SSH server
dig db.internal    # DNS resolution on SSH server
```

### Resource Shortage

**Symptom:** `channel N: open failed: resource shortage: Connection refused`

```bash
# Too many channels/sessions open
sudo sshd -T | grep maxsessions
# Increase MaxSessions if needed (default is 10)

# System-level limits
ulimit -n                          # File descriptor limit
sudo sshd -T | grep maxstartups   # Connection rate limiting
```

---

## Broken Pipe Fixes

### Keepalive Configuration

**Symptom:** `client_loop: send disconnect: Broken pipe` or `Write failed: Broken pipe`

```bash
# Client-side keepalive (~/.ssh/config)
Host *
    ServerAliveInterval 60       # Send keepalive every 60 seconds
    ServerAliveCountMax 3        # Disconnect after 3 missed responses
    TCPKeepAlive yes             # TCP-level keepalive

# Server-side keepalive (/etc/ssh/sshd_config)
ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
```

### Network Stability Issues

```bash
# Check for intermittent connectivity
mtr --report --report-cycles 100 host.example.com

# Check for NAT timeout (common with stateful firewalls)
# NAT tables expire idle connections — keepalives prevent this
# Typical NAT timeout: 5-15 minutes

# IPQoS issues (some networks drop DSCP-marked packets)
Host problematic-network
    IPQoS none                   # Disable QoS marking
```

### Session Persistence Tools

```bash
# Use mosh for unreliable connections
mosh user@host               # Survives network changes, roaming

# Use tmux/screen on the remote host
ssh user@host -t 'tmux attach || tmux new'

# Use autossh for persistent tunnels
autossh -M 0 -N -L 5432:db:5432 user@host \
  -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3"
```

---

## DNS Resolution in Tunnels

**Key concept:** With `-L` and `-R`, the target hostname is resolved by the SSH server,
not the client. With SOCKS `-D`, it depends on the protocol variant.

```bash
# SOCKS5 with remote DNS (correct for internal names)
curl --socks5-hostname localhost:1080 http://internal.corp
# The "h" in socks5h means hostname resolution happens on the SOCKS server

# SOCKS5 with local DNS (won't resolve internal names)
curl --socks5 localhost:1080 http://internal.corp
# DNS resolves locally — will fail for internal hostnames

# Force DNS through tunnel in applications
# Firefox: network.proxy.socks_remote_dns = true
# Chrome: --proxy-server="socks5://localhost:1080" --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost"

# For -L tunnels, use IP if DNS is inconsistent
ssh -L 5432:10.0.1.50:5432 user@bastion -N    # IP instead of hostname
```

---

## MTU Issues Through Tunnels

**Symptom:** SSH connects but hangs during data transfer, large files fail, or
interactive sessions freeze after initial login.

```bash
# 1. Diagnose MTU issues
# Find the maximum working MTU
ping -M do -s 1400 -c 3 host.example.com     # Start at 1400
ping -M do -s 1300 -c 3 host.example.com     # Reduce until it works
# The largest working size + 28 (ICMP+IP headers) = path MTU

# 2. Reduce MTU on the interface
sudo ip link set dev eth0 mtu 1400

# 3. Enable PMTU discovery
sudo sysctl -w net.ipv4.ip_no_pmtu_disc=0

# 4. Set MSS clamping (common fix for VPN/tunnel scenarios)
sudo iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu

# 5. SSH-specific workaround
# Use compression to reduce packet sizes
ssh -C user@host

# 6. For SSH tun/tap VPN: set MTU on tunnel interface
sudo ip link set dev tun0 mtu 1400
```

---

## SELinux/Firewall Blocking

### SELinux Issues

```bash
# Check if SELinux is blocking SSH
sudo ausearch -m avc -ts recent | grep ssh
sudo sealert -a /var/log/audit/audit.log 2>/dev/null | grep ssh

# Common SELinux issues:
# - Non-standard SSH port
sudo semanage port -a -t ssh_port_t -p tcp 2222

# - Home directory context wrong
sudo restorecon -Rv /home/user/.ssh

# - Custom authorized_keys path
sudo semanage fcontext -a -t ssh_home_t '/custom/path/authorized_keys'
sudo restorecon -v /custom/path/authorized_keys

# Temporarily disable SELinux for testing (re-enable after!)
sudo setenforce 0    # Permissive mode
# Check: getenforce
sudo setenforce 1    # Re-enable
```

### Firewall Troubleshooting

```bash
# UFW (Ubuntu)
sudo ufw status verbose
sudo ufw allow 22/tcp
sudo ufw allow from 10.0.0.0/8 to any port 22

# firewalld (RHEL/CentOS)
sudo firewall-cmd --list-all
sudo firewall-cmd --add-port=22/tcp --permanent
sudo firewall-cmd --reload

# iptables (direct)
sudo iptables -L -n -v | grep -E "22|ssh"
sudo iptables -I INPUT -p tcp --dport 22 -j ACCEPT

# nftables (modern)
sudo nft list ruleset | grep -E "22|ssh"
```

---

## Common sshd_config Mistakes

### Configuration Errors

| Mistake | Symptom | Fix |
|---------|---------|-----|
| `PasswordAuthentication no` without key deployed | Locked out completely | Use console access; deploy key first |
| Duplicate directives (first wins) | Unexpected behavior | Check with `sshd -T`; remove duplicates |
| `Match` block not terminated | Settings leak to wrong users | Ensure `Match` blocks are at end of file |
| `AllowUsers` without current user | Locked out | Always include your own user |
| Wrong `AuthorizedKeysFile` path | Key auth fails | Verify path with `sshd -T` |
| `ListenAddress` on wrong IP | Can't connect | Check bound IPs with `ss -tlnp` |
| `UsePAM no` with password auth | Auth fails | Either use PAM or handle auth directly |
| Tabs vs spaces inconsistency | Parse errors | Use `sshd -t` to validate syntax |

### Debugging Configuration

```bash
# Validate syntax before restarting
sudo sshd -t
# If OK: no output. If error: shows line number.

# Test effective config for a specific connection
sudo sshd -T -C user=alice,host=10.0.0.5,addr=10.0.0.5

# Check which config file is being used
sudo sshd -T 2>&1 | head -5

# Common gotcha: editing wrong config file
# Ubuntu/Debian may use /etc/ssh/sshd_config.d/*.conf
ls /etc/ssh/sshd_config.d/
# Files here can override main config via Include directive

# Restart SSH safely (don't disconnect yourself!)
# Method 1: Test first, then restart
sudo sshd -t && sudo systemctl restart sshd

# Method 2: Start a second sshd on different port for safety
sudo /usr/sbin/sshd -d -p 2222
# Test connection on port 2222, then restart main sshd
```

### Recovery from Lockout

```bash
# If locked out of SSH:
# 1. Use cloud provider console (AWS, GCP, Azure)
# 2. Use out-of-band management (IPMI, iDRAC, iLO)
# 3. Boot into single-user mode
# 4. Mount filesystem from another instance

# Prevention:
# - Always keep an existing session open when changing sshd_config
# - Test config syntax before restarting: sshd -t
# - Use a second SSH listener on a different port as backup
# - Set up console access before hardening
```
