# Linux Network Security Hardening

> Comprehensive guide to hardening Linux network services and infrastructure,
> from kernel parameters through application-level security.

## Table of Contents

- [Firewall Best Practices](#firewall-best-practices)
- [Fail2ban Setup and Configuration](#fail2ban-setup-and-configuration)
- [Port Knocking](#port-knocking)
- [TCP Wrappers](#tcp-wrappers)
- [Sysctl Hardening for Network Security](#sysctl-hardening-for-network-security)
- [SSH Hardening](#ssh-hardening)
- [TLS Certificate Management](#tls-certificate-management)
- [VPN Comparison: WireGuard vs OpenVPN vs IPsec](#vpn-comparison-wireguard-vs-openvpn-vs-ipsec)
- [Additional Hardening Measures](#additional-hardening-measures)

---

## Firewall Best Practices

### Core principles

1. **Default deny** — Drop all traffic not explicitly permitted
2. **Least privilege** — Open only required ports for required sources
3. **Defense in depth** — Layer firewall with application-level controls
4. **Stateful filtering** — Allow established/related connections, block new unsolicited
5. **Log before drop** — Log denied traffic for auditing (rate-limit logs)
6. **Egress filtering** — Restrict outbound traffic, not just inbound

### iptables best practices

```bash
# Set default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT                  # or DROP for strict egress control

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections (stateful)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Rate-limit new SSH connections
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
  -m recent --set --name SSH
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
  -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Log dropped packets (rate-limited to avoid log flooding)
iptables -A INPUT -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "IPT-DROP: " --log-level 4
iptables -A INPUT -j DROP

# Persist rules
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
```

### nftables best practices

```bash
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  set allowed_ssh {
    type ipv4_addr
    flags interval
    elements = { 10.0.0.0/8, 192.168.0.0/16 }
  }

  chain input {
    type filter hook input priority 0; policy drop;

    iif lo accept
    ct state established,related accept
    ct state invalid drop

    # Rate-limit SSH from allowed networks only
    ip saddr @allowed_ssh tcp dport 22 ct state new \
      limit rate 4/minute burst 8 packets accept

    # ICMP (allow but rate-limit)
    ip protocol icmp limit rate 10/second accept

    # Logging
    limit rate 5/minute burst 10 packets log prefix "NFT-DROP: " level warn
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
```

### UFW quick hardening

```bash
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp                           # rate-limited SSH
ufw allow from 10.0.0.0/8 to any port 443  # HTTPS from internal only
ufw logging on                             # enable logging
ufw enable
```

---

## Fail2ban Setup and Configuration

### Installation and basic setup

```bash
# Install
apt install fail2ban        # Debian/Ubuntu
dnf install fail2ban        # RHEL/Fedora

# Create local config (never edit jail.conf directly)
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
```

### Essential jail configuration

```ini
# /etc/fail2ban/jail.local

[DEFAULT]
bantime  = 3600            # 1 hour ban
findtime = 600             # 10-minute window
maxretry = 5               # 5 failures before ban
banaction = iptables-multiport
# For nftables: banaction = nftables-multiport

# Email notification (optional)
destemail = admin@example.com
sender = fail2ban@example.com
action = %(action_mwl)s    # ban + mail with whois + log lines

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log           # Debian/Ubuntu
# logpath = /var/log/secure           # RHEL/CentOS
maxretry = 3
bantime = 86400             # 24 hours for SSH

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log

[nginx-botsearch]
enabled = true
port = http,https
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 2
```

### Fail2ban management

```bash
# Service control
systemctl enable --now fail2ban

# Check status
fail2ban-client status
fail2ban-client status sshd             # specific jail

# Manually ban/unban
fail2ban-client set sshd banip 1.2.3.4
fail2ban-client set sshd unbanip 1.2.3.4

# Test filter against log
fail2ban-regex /var/log/auth.log /etc/fail2ban/filter.d/sshd.conf

# View banned IPs
fail2ban-client get sshd banned
```

### Custom filter example

```ini
# /etc/fail2ban/filter.d/custom-app.conf
[Definition]
failregex = ^.*Authentication failed for user .* from <HOST>.*$
ignoreregex =
```

---

## Port Knocking

Port knocking adds a stealth layer by keeping ports closed until a secret
sequence of connection attempts is made.

### Using knockd

```bash
# Install
apt install knockd

# /etc/knockd.conf
[options]
  UseSyslog

[openSSH]
  sequence    = 7000,8000,9000
  seq_timeout = 5
  command     = /usr/sbin/iptables -A INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
  tcpflags    = syn

[closeSSH]
  sequence    = 9000,8000,7000
  seq_timeout = 5
  command     = /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
  tcpflags    = syn
```

### Client-side knocking

```bash
# Using knock client
knock server-ip 7000 8000 9000
ssh user@server-ip

# Using nmap (no client needed)
for port in 7000 8000 9000; do
  nmap -Pn --host-timeout 100 --max-retries 0 -p $port server-ip
done
ssh user@server-ip
```

### iptables-based port knocking (without knockd)

```bash
# Stage 1: first knock
iptables -N KNOCKING
iptables -A INPUT -p tcp --dport 7000 -m recent --name KNOCK1 --set -j DROP
# Stage 2: second knock within 5s of first
iptables -A INPUT -p tcp --dport 8000 -m recent --name KNOCK1 --rcheck --seconds 5 \
  -m recent --name KNOCK2 --set -j DROP
# Stage 3: open SSH for 30s after sequence
iptables -A INPUT -p tcp --dport 9000 -m recent --name KNOCK2 --rcheck --seconds 5 \
  -m recent --name AUTHORIZED --set -j DROP
iptables -A INPUT -p tcp --dport 22 -m recent --name AUTHORIZED --rcheck --seconds 30 -j ACCEPT
```

**Note**: Port knocking is security through obscurity. Use as an additional
layer, never as the sole protection. Always combine with key-based SSH auth.

---

## TCP Wrappers

TCP Wrappers (`/etc/hosts.allow` and `/etc/hosts.deny`) provide host-based
access control for services compiled with libwrap support.

### Check if a service supports TCP Wrappers

```bash
ldd /usr/sbin/sshd | grep libwrap
# If output: libwrap.so → TCP Wrappers supported
```

### Configuration

```bash
# /etc/hosts.deny — default deny all
ALL: ALL

# /etc/hosts.allow — explicit allows (processed first)
sshd: 10.0.0.0/8 192.168.0.0/16
sshd: .example.com                        # allow by domain
vsftpd: 10.0.0.0/8

# With logging
sshd: ALL: spawn /bin/echo "SSH from %c to %s" >> /var/log/tcpwrap.log : DENY

# Except syntax
ALL: ALL EXCEPT 10.0.0.0/8
```

**Note**: TCP Wrappers are deprecated in many modern distributions. Prefer
firewall rules (iptables/nftables) for access control.

---

## Sysctl Hardening for Network Security

### Anti-spoofing and source validation

```bash
# Reverse path filtering — drop packets with impossible source addresses
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# 1 = strict (recommended for hosts)
# 2 = loose (required for asymmetric routing / multi-homed)

# Don't accept source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
```

### ICMP hardening

```bash
# Ignore ICMP echo (ping) — controversial, breaks monitoring
# net.ipv4.icmp_echo_ignore_all = 1       # uncomment only if needed

# Ignore broadcast pings (Smurf attack prevention)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Don't accept ICMP redirects (prevents MITM via gateway injection)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Don't send ICMP redirects (only routers should)
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Log suspicious packets (martians)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
```

### TCP hardening

```bash
# SYN cookies — protect against SYN flood attacks
net.ipv4.tcp_syncookies = 1

# Reduce SYN-ACK retries (faster timeout for SYN flood)
net.ipv4.tcp_synack_retries = 3            # default 5

# TIME-WAIT management
net.ipv4.tcp_tw_reuse = 1                  # safe to enable
# NEVER use tcp_tw_recycle (removed from kernel 4.12+)

# Reduce FIN timeout
net.ipv4.tcp_fin_timeout = 15              # default 60

# Disable TCP timestamps if not needed (reduces info leakage)
# net.ipv4.tcp_timestamps = 0
# WARNING: breaks tcp_tw_reuse and PAWS — only disable if you understand impact
```

### IP forwarding (disable unless routing)

```bash
# Disable IPv4 forwarding (unless this is a router/firewall)
net.ipv4.ip_forward = 0

# Disable IPv6 forwarding
net.ipv6.conf.all.forwarding = 0

# If forwarding IS needed, still harden:
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
```

### Apply and persist

```bash
# Save to file
cat > /etc/sysctl.d/90-network-security.conf << 'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
EOF

sysctl -p /etc/sysctl.d/90-network-security.conf
```

---

## SSH Hardening

### Key-only authentication

```bash
# Generate strong key (Ed25519 preferred)
ssh-keygen -t ed25519 -C "user@host"

# Or RSA with minimum 4096 bits
ssh-keygen -t rsa -b 4096 -C "user@host"

# Copy to server
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@server
```

### sshd_config hardening

```bash
# /etc/ssh/sshd_config

# Authentication
PermitRootLogin no                         # never allow root login
PasswordAuthentication no                  # key-only
PubkeyAuthentication yes
AuthenticationMethods publickey            # explicit
MaxAuthTries 3                             # limit attempts

# Access control
AllowUsers deploy admin                    # whitelist users
# AllowGroups sshusers                     # or whitelist by group
DenyUsers root                             # explicit deny

# Network
Port 2222                                  # non-standard port (reduces noise)
AddressFamily inet                         # IPv4 only (if no IPv6)
ListenAddress 0.0.0.0                      # or specific IP
LoginGraceTime 30                          # 30s to authenticate

# Security
X11Forwarding no                           # disable X forwarding
AllowTcpForwarding no                      # unless needed for tunnels
AllowAgentForwarding no                    # unless needed
PermitTunnel no                            # unless VPN
Banner /etc/ssh/banner                     # legal warning banner

# Crypto (restrict to strong algorithms)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256

# Idle timeout
ClientAliveInterval 300                    # 5 min
ClientAliveCountMax 2                      # disconnect after 10 min idle

# Logging
LogLevel VERBOSE                           # detailed auth logging
```

### Apply and validate

```bash
# Test config before restarting
sshd -t

# Restart
systemctl restart sshd

# Audit SSH config
ssh-audit server-ip                        # requires ssh-audit tool
```

### Jump hosts (bastion)

```bash
# ~/.ssh/config on client
Host bastion
  Hostname bastion.example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/id_ed25519

Host internal-*
  ProxyJump bastion
  User admin
  IdentityFile ~/.ssh/id_ed25519

Host internal-db
  Hostname 10.0.1.50

Host internal-app
  Hostname 10.0.1.60
```

```bash
# Usage
ssh internal-db                            # auto-jumps through bastion
scp file.txt internal-app:/tmp/           # SCP through bastion

# One-liner without config
ssh -J deploy@bastion:2222 admin@10.0.1.50
```

### SSH key management best practices

```bash
# Use ssh-agent (avoid keys on disk without passphrase)
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# Key lifetime limits
ssh-add -t 3600 ~/.ssh/id_ed25519         # key expires from agent in 1 hour

# Restrict authorized_keys options
# In ~/.ssh/authorized_keys:
# command="/usr/bin/rsync",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA... backup-key
# from="10.0.0.0/8",no-port-forwarding ssh-ed25519 AAAA... restricted-key

# Certificate-based SSH (for large fleets)
# Sign user key with CA
ssh-keygen -s /path/to/ca_key -I user_id -n username -V +52w user_key.pub
# Trust CA on servers: add to /etc/ssh/sshd_config
# TrustedUserCAKeys /etc/ssh/ca.pub
```

---

## TLS Certificate Management

### Let's Encrypt with Certbot

```bash
# Install
apt install certbot                        # standalone
apt install certbot python3-certbot-nginx  # with nginx plugin

# Obtain certificate
certbot certonly --standalone -d example.com -d www.example.com
certbot --nginx -d example.com             # auto-configure nginx

# Auto-renewal (cron or systemd timer)
certbot renew --dry-run                    # test renewal
# Certbot installs a systemd timer by default
systemctl list-timers | grep certbot

# Manual renewal hooks
certbot renew --deploy-hook "systemctl reload nginx"
```

### Self-signed certificates (development/internal)

```bash
# Generate CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/CN=Internal CA"

# Generate server certificate
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr \
  -subj "/CN=server.internal"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365 \
  -extfile <(printf "subjectAltName=DNS:server.internal,IP:10.0.0.1")
```

### Certificate monitoring

```bash
# Check expiration
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -enddate

# Check expiration in days
EXPIRY=$(openssl s_client -connect example.com:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -enddate | cut -d= -f2)
echo $(( ($(date -d "$EXPIRY" +%s) - $(date +%s)) / 86400 )) days remaining

# Verify certificate chain
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt server.crt

# Check for weak algorithms
openssl s_client -connect example.com:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -E "Signature Algorithm|Public-Key"
```

### TLS configuration best practices

```bash
# Nginx example
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_stapling on;
ssl_stapling_verify on;

# Use Mozilla SSL Configuration Generator for current recommendations:
# https://ssl-config.mozilla.org/
```

---

## VPN Comparison: WireGuard vs OpenVPN vs IPsec

### Feature comparison

| Feature            | WireGuard              | OpenVPN                 | IPsec (StrongSwan)     |
|--------------------|------------------------|-------------------------|------------------------|
| **Protocol**       | UDP only               | UDP or TCP              | ESP/AH (UDP 500/4500)  |
| **Encryption**     | ChaCha20, Curve25519   | Configurable (AES, etc) | Configurable (AES, etc)|
| **Code size**      | ~4,000 lines           | ~100,000+ lines         | ~400,000+ lines        |
| **Runs in**        | Kernel space           | User space              | Kernel space            |
| **Performance**    | Excellent (~900Mbps)   | Good (~500Mbps)         | Very good (~800Mbps)   |
| **Setup**          | Simple                 | Moderate                | Complex                 |
| **NAT traversal**  | Excellent              | Good                    | Requires NAT-T          |
| **Mobile support** | Good (iOS/Android)     | Good (all platforms)    | Native on most OS       |
| **Key exchange**   | Static keys + Noise    | TLS/PKI                 | IKEv2                   |
| **Audit status**   | Formally verified      | Audited                 | Standardized (IETF)     |
| **Stealth**        | Limited                | TCP mode (port 443)     | Limited                 |
| **Enterprise**     | Growing                | Mature                  | Standard                |

### WireGuard setup

```bash
# Install
apt install wireguard

# Generate keys
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

# Server config: /etc/wireguard/wg0.conf
[Interface]
PrivateKey = <SERVER_PRIVATE_KEY>
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = <CLIENT_PUBLIC_KEY>
AllowedIPs = 10.0.0.2/32

# Enable
wg-quick up wg0
systemctl enable wg-quick@wg0
```

### OpenVPN hardened setup

```bash
# Key points for security:
# 1. Use tls-crypt (not just tls-auth) for HMAC protection
# 2. Use AES-256-GCM cipher
# 3. Use tls-version-min 1.2
# 4. Generate DH parameters: openssl dhparam -out dh4096.pem 4096
# 5. Use CRL for certificate revocation
# 6. Enable duplicate-cn only if needed

# Server config highlights:
proto udp
port 1194
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
tls-crypt ta.key
dh dh4096.pem
# Restrict ciphers
ncp-ciphers AES-256-GCM:AES-128-GCM
```

### IPsec (StrongSwan) setup

```bash
# Install
apt install strongswan strongswan-pki

# Generate CA and certificates
ipsec pki --gen --type rsa --size 4096 --outform pem > ca-key.pem
ipsec pki --self --ca --lifetime 3650 --in ca-key.pem \
  --type rsa --dn "CN=VPN CA" --outform pem > ca-cert.pem

# /etc/ipsec.conf
conn ikev2-vpn
  auto=add
  type=tunnel
  keyexchange=ikev2
  ike=aes256-sha256-modp2048!
  esp=aes256-sha256!
  left=%defaultroute
  leftcert=server-cert.pem
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  right=%any
  rightauth=eap-mschapv2
  rightsourceip=10.10.10.0/24
  rightdns=8.8.8.8,8.8.4.4
  eap_identity=%identity
```

### When to choose which VPN

- **WireGuard**: New deployments, mobile users, site-to-site, highest performance
- **OpenVPN**: Legacy compatibility, TCP fallback needed (restrictive firewalls), user-space flexibility
- **IPsec**: Enterprise interop (Cisco, Juniper, etc.), Windows native support, standards compliance

---

## Additional Hardening Measures

### Disable unused services and protocols

```bash
# List listening services
ss -tlnp
# Disable unnecessary ones
systemctl disable --now rpcbind avahi-daemon cups

# Disable unused network protocols
cat >> /etc/modprobe.d/hardening.conf << 'EOF'
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true
EOF
```

### Automatic security updates

```bash
# Debian/Ubuntu
apt install unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades

# RHEL/Fedora
dnf install dnf-automatic
systemctl enable --now dnf-automatic-install.timer
```

### Network monitoring and alerting

```bash
# Monitor open ports
ss -tlnp | diff - /root/baseline-ports.txt

# Watch for new connections
conntrack -E                               # real-time connection events

# Detect port scans (with psad)
apt install psad
# psad monitors iptables LOG rules for scan patterns

# Network IDS (lightweight)
apt install snort                          # or suricata for modern alternative
```

### Audit and compliance

```bash
# OpenSCAP security scanning
apt install openscap-scanner scap-security-guide
oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_standard \
  --results results.xml /usr/share/xml/scap/ssg/content/ssg-ubuntu2204-ds.xml

# Lynis security audit
apt install lynis
lynis audit system --quick

# Check for world-accessible network config files
find /etc -name "*.conf" -perm /o+r -path "*/network*" -ls
```
