# Advanced SSH Patterns

> Deep-dive into advanced SSH techniques beyond basic tunneling: certificates, protocol
> encapsulation, VPN mode, multiplexing internals, container/orchestrator integration, and
> multi-tenant bastion routing.

## Table of Contents

- [SSH Certificates (CA Infrastructure)](#ssh-certificates-ca-infrastructure)
  - [CA Key Generation](#ca-key-generation)
  - [Signing User Keys](#signing-user-keys)
  - [Signing Host Keys](#signing-host-keys)
  - [Principals and Access Control](#principals-and-access-control)
  - [Certificate Validity and Rotation](#certificate-validity-and-rotation)
  - [Automation Tools](#automation-tools)
- [SSH over HTTPS](#ssh-over-https)
  - [Stunnel Wrapping](#stunnel-wrapping)
  - [Socat TLS Tunnel](#socat-tls-tunnel)
  - [Nginx as SSH Reverse Proxy](#nginx-as-ssh-reverse-proxy)
- [Reverse SSH Tunnels for IoT/NAT Traversal](#reverse-ssh-tunnels-for-iotnat-traversal)
  - [Basic Reverse Tunnel](#basic-reverse-tunnel)
  - [Persistent IoT Reverse Tunnel](#persistent-iot-reverse-tunnel)
  - [Security Considerations](#security-considerations-for-reverse-tunnels)
- [SSH Multiplexing Internals](#ssh-multiplexing-internals)
  - [ControlMaster Protocol](#controlmaster-protocol)
  - [Performance Characteristics](#performance-characteristics)
  - [Security Implications](#security-implications)
- [Dynamic SOCKS Proxy Chaining](#dynamic-socks-proxy-chaining)
  - [Single-Hop SOCKS](#single-hop-socks)
  - [Multi-Hop Chaining](#multi-hop-chaining)
  - [Application-Level Proxying](#application-level-proxying)
- [SSH VPN (tun/tap Devices)](#ssh-vpn-tuntap-devices)
  - [Layer 3 (tun) VPN Setup](#layer-3-tun-vpn-setup)
  - [Layer 2 (tap) Bridging](#layer-2-tap-bridging)
  - [Routing and Firewall Configuration](#routing-and-firewall-configuration)
- [SSH + Docker (Remote Docker Daemon)](#ssh--docker-remote-docker-daemon)
  - [Docker over SSH Context](#docker-over-ssh-context)
  - [Remote Docker via Tunnel](#remote-docker-via-tunnel)
  - [Docker Compose Remote](#docker-compose-remote)
- [SSH Forwarding for Kubernetes](#ssh-forwarding-for-kubernetes)
  - [kubectl Through SSH Tunnel](#kubectl-through-ssh-tunnel)
  - [Kubernetes API via Bastion](#kubernetes-api-via-bastion)
  - [Pod-Level SSH Access](#pod-level-ssh-access)
- [SSHPiper for Multi-Tenant Bastion](#sshpiper-for-multi-tenant-bastion)
  - [Architecture Overview](#architecture-overview)
  - [Plugin-Based Routing](#plugin-based-routing)
  - [Docker and Kubernetes Plugins](#docker-and-kubernetes-plugins)

---

## SSH Certificates (CA Infrastructure)

SSH certificates replace scattered `authorized_keys` files with a centralized trust model.
A Certificate Authority (CA) signs user and host keys, and servers/clients trust the CA
rather than individual keys.

### CA Key Generation

Always use separate CAs for user and host certificates to limit blast radius:

```bash
# User CA — signs user certificates
ssh-keygen -t ed25519 -f /etc/ssh/ssh_user_ca -C "User CA" -N ""

# Host CA — signs host certificates
ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ca -C "Host CA" -N ""

# Protect CA private keys
chmod 600 /etc/ssh/ssh_user_ca /etc/ssh/ssh_host_ca
chown root:root /etc/ssh/ssh_user_ca /etc/ssh/ssh_host_ca
```

**Critical:** Store CA private keys on an air-gapped machine or HSM. Never leave them on
a network-accessible server.

### Signing User Keys

```bash
# Sign a user's public key
# -s: CA key  -I: certificate identity  -n: principals (usernames)
# -V: validity period  -z: serial number
ssh-keygen -s /etc/ssh/ssh_user_ca \
  -I "alice-laptop-2024" \
  -n alice,deploy \
  -V +24h \
  -z 1001 \
  ~/.ssh/id_ed25519.pub

# Output: ~/.ssh/id_ed25519-cert.pub

# Inspect the certificate
ssh-keygen -L -f ~/.ssh/id_ed25519-cert.pub
```

**Server configuration** to trust user CA:

```bash
# /etc/ssh/sshd_config
TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub
```

### Signing Host Keys

```bash
# Sign the host's public key
ssh-keygen -s /etc/ssh/ssh_host_ca \
  -I "web-server-prod" \
  -h \
  -n web01.example.com,10.0.1.10 \
  -V +52w \
  /etc/ssh/ssh_host_ed25519_key.pub

# Output: /etc/ssh/ssh_host_ed25519_key-cert.pub
```

**Server configuration** to present the host certificate:

```bash
# /etc/ssh/sshd_config
HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
```

**Client configuration** to trust host CA (add to `~/.ssh/known_hosts` or global):

```
@cert-authority *.example.com ssh-ed25519 AAAA... <contents of ssh_host_ca.pub>
```

### Principals and Access Control

Principals control which usernames a certificate can authenticate as:

```bash
# /etc/ssh/sshd_config
AuthorizedPrincipalsFile /etc/ssh/authorized_principals/%u

# /etc/ssh/authorized_principals/deploy
# One principal per line — certificate must contain one of these
deploy
ci-bot

# /etc/ssh/authorized_principals/root
emergency-admin
```

**Advanced principal options** (in AuthorizedPrincipalsFile):

```
# Restrict by source IP
from="10.0.0.0/8" deploy

# Force a specific command
command="/usr/local/bin/restricted-deploy" ci-bot
```

### Certificate Validity and Rotation

Best practices for certificate lifecycle:

| Use Case | Validity | Rationale |
|----------|----------|-----------|
| Interactive user | 8-24 hours | Short-lived, re-issued via SSO |
| CI/CD service | 1-4 hours | Scoped to pipeline run |
| Host certificate | 26-52 weeks | Rotate with host key rotation |
| Emergency access | 1-2 hours | Audit-triggered, short window |

### Automation Tools

| Tool | Description |
|------|-------------|
| **HashiCorp Vault SSH** | Dynamic SSH certificate issuance with TTL and audit logging |
| **Netflix BLESS** | Lambda-based SSH CA, issues short-lived certificates via SSO |
| **Smallstep step-ca** | Open-source CA with SSH certificate support, OIDC integration |
| **Teleport** | Full SSH access platform with certificates, RBAC, session recording |

---

## SSH over HTTPS

When SSH port 22 is blocked but HTTPS (443) is allowed, encapsulate SSH within TLS.

### Stunnel Wrapping

**Server side** — stunnel listens on 443, forwards to SSH on 22:

```ini
# /etc/stunnel/stunnel.conf
[ssh-over-tls]
accept = 0.0.0.0:443
connect = 127.0.0.1:22
cert = /etc/stunnel/server.pem
key = /etc/stunnel/server.key
```

**Client side** — SSH uses stunnel as ProxyCommand:

```ini
# /etc/stunnel/client.conf
[ssh-client]
client = yes
accept = 127.0.0.1:2222
connect = server.example.com:443
```

```ssh-config
# ~/.ssh/config
Host server-via-tls
    HostName 127.0.0.1
    Port 2222
    # Or directly with ProxyCommand:
    # ProxyCommand stunnel3 -c -r server.example.com:443
```

### Socat TLS Tunnel

A lighter alternative using socat directly in ProxyCommand:

```ssh-config
Host server-via-socat
    HostName server.example.com
    ProxyCommand socat - OPENSSL:%h:443,verify=0
    # With certificate verification:
    # ProxyCommand socat - OPENSSL:%h:443,cafile=/path/to/ca.pem
```

### Nginx as SSH Reverse Proxy

Use Nginx stream module to multiplex SSH and HTTPS on port 443:

```nginx
# /etc/nginx/nginx.conf
stream {
    upstream ssh_backend {
        server 127.0.0.1:22;
    }
    upstream https_backend {
        server 127.0.0.1:8443;
    }

    map $ssl_preread_protocol $upstream {
        default ssh_backend;
        "TLSv1.2" https_backend;
        "TLSv1.3" https_backend;
    }

    server {
        listen 443;
        proxy_pass $upstream;
        ssl_preread on;
    }
}
```

---

## Reverse SSH Tunnels for IoT/NAT Traversal

### Basic Reverse Tunnel

Device behind NAT initiates outbound connection to a public server:

```bash
# On IoT device (behind NAT):
ssh -R 2222:localhost:22 user@public-server -N -f

# From anywhere, connect to device via public server:
ssh -p 2222 device-user@public-server
```

### Persistent IoT Reverse Tunnel

Use autossh + systemd for reliable, always-on tunnels:

```ini
# /etc/systemd/system/reverse-tunnel.service
[Unit]
Description=Persistent reverse SSH tunnel for IoT device
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=tunnel
Environment="AUTOSSH_GATETIME=0"
ExecStart=/usr/bin/autossh -M 0 -N \
  -R 2222:localhost:22 \
  -o "ServerAliveInterval 30" \
  -o "ServerAliveCountMax 3" \
  -o "ExitOnForwardFailure yes" \
  -o "StrictHostKeyChecking accept-new" \
  -i /home/tunnel/.ssh/id_ed25519 \
  tunnel@public-server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### Security Considerations for Reverse Tunnels

- Use dedicated, restricted user accounts on the relay server
- Set `GatewayPorts clientspecified` (not `yes`) on the relay sshd_config
- Limit with `PermitOpen` or `permitlisten` in `authorized_keys`:
  ```
  permitlisten="localhost:2222" ssh-ed25519 AAAA... device-key
  ```
- Use SSH certificates with short validity for device authentication
- Monitor tunnel connections and set up alerting for unexpected disconnects

---

## SSH Multiplexing Internals

### ControlMaster Protocol

SSH multiplexing uses a Unix domain socket to share a single TCP connection:

```
┌──────────┐     ┌───────────────┐     ┌──────────┐
│ SSH #1   │────>│               │     │          │
│ (master) │     │ Control Socket│────>│  Remote  │
│ SSH #2   │────>│ ~/.ssh/cm-*   │     │  Server  │
│ (slave)  │     │               │     │          │
│ SSH #3   │────>│               │     │          │
│ (slave)  │     └───────────────┘     └──────────┘
└──────────┘
```

The master process owns the TCP connection and authentication state. Slave sessions
send channel requests through the Unix socket.

```ssh-config
Host *
    ControlMaster auto       # First connection becomes master
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m       # Keep master alive 10min after last session
```

### Performance Characteristics

| Operation | Without Multiplexing | With Multiplexing |
|-----------|---------------------|-------------------|
| TCP handshake | Every connection | Once |
| Key exchange | Every connection | Once |
| Authentication | Every connection | Once |
| Typical `ssh host true` | ~500ms | ~50ms |
| Concurrent sessions | N TCP connections | 1 TCP connection |

### Security Implications

- The control socket file must be protected (only owner-readable)
- If the master process is compromised, all multiplexed sessions are exposed
- Use `ControlPath` in a protected directory (default `~/.ssh/` is correct)
- Consider `ControlPersist` timeout to limit exposure window
- Use `-S none` to bypass multiplexing for sensitive one-off operations

---

## Dynamic SOCKS Proxy Chaining

### Single-Hop SOCKS

```bash
ssh -D 1080 user@proxy-server -N -f
# All SOCKS5-aware apps can now route through proxy-server
```

### Multi-Hop Chaining

Chain through multiple SSH servers for layered access:

```bash
# Hop 1: Local -> Server A (SOCKS on 1080)
ssh -D 1080 -L 2222:serverB:22 user@serverA -N -f

# Hop 2: Through tunnel to Server B (SOCKS on 1081)
ssh -D 1081 -p 2222 user@localhost -N -f

# Use proxychains to chain SOCKS proxies
# /etc/proxychains.conf:
# [ProxyList]
# socks5 127.0.0.1 1080
# socks5 127.0.0.1 1081
proxychains curl http://internal-service
```

**Using ProxyJump for cleaner chaining:**

```ssh-config
Host proxy-chain
    HostName final-target
    ProxyJump serverA,serverB
    DynamicForward 1080
```

### Application-Level Proxying

```bash
# curl through SOCKS proxy
curl --socks5-hostname localhost:1080 http://internal.corp/api

# git through SOCKS proxy
git -c http.proxy=socks5h://localhost:1080 clone https://internal-git/repo

# Set environment for general use
export ALL_PROXY=socks5h://localhost:1080
```

---

## SSH VPN (tun/tap Devices)

SSH can create true Layer 2/3 VPN tunnels, not just port forwards.

### Layer 3 (tun) VPN Setup

**Prerequisites on both ends:**

```bash
# Server sshd_config
PermitTunnel point-to-point    # or "yes" for both tun and tap
PermitRootLogin forced-commands-only

# Load tun module
sudo modprobe tun
```

**Establish the tunnel:**

```bash
# Client side (must run as root for tun device creation)
sudo ssh -w 0:0 root@remote-server -N &

# Configure client tun0
sudo ip addr add 10.0.200.1/30 dev tun0
sudo ip link set tun0 up

# Configure server tun0 (run on server)
sudo ip addr add 10.0.200.2/30 dev tun0
sudo ip link set tun0 up
```

### Layer 2 (tap) Bridging

```bash
# Use tap devices for Layer 2 bridging (Ethernet frames)
sudo ssh -w 0:0 -o Tunnel=ethernet root@remote-server -N &

# Bridge tap0 with a local interface
sudo brctl addbr br0
sudo brctl addif br0 tap0
sudo brctl addif br0 eth1
sudo ip link set br0 up
```

### Routing and Firewall Configuration

```bash
# Enable IP forwarding on VPN server
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward

# Route remote subnet through tunnel
sudo ip route add 10.0.0.0/16 via 10.0.200.2

# NAT for internet access through tunnel
sudo iptables -t nat -A POSTROUTING -s 10.0.200.0/30 -o eth0 -j MASQUERADE
```

---

## SSH + Docker (Remote Docker Daemon)

### Docker over SSH Context

Docker natively supports SSH as a transport — no tunnel setup needed:

```bash
# Create a Docker context pointing to a remote host
docker context create remote-server --docker "host=ssh://user@remote-server"

# Switch to the remote context
docker context use remote-server

# All docker commands now execute on the remote host
docker ps
docker logs my-container
docker compose up -d
```

### Remote Docker via Tunnel

When direct SSH isn't possible (e.g., Docker host behind bastion):

```bash
# Forward Docker socket through SSH tunnel
ssh -L /tmp/docker-remote.sock:/var/run/docker.sock user@docker-host -N -f

# Use the forwarded socket
DOCKER_HOST=unix:///tmp/docker-remote.sock docker ps

# Through a bastion
ssh -J user@bastion -L /tmp/docker.sock:/var/run/docker.sock user@docker-host -N -f
```

### Docker Compose Remote

```bash
# Use DOCKER_HOST with SSH directly
DOCKER_HOST=ssh://user@remote-server docker compose up -d

# Or with the tunnel socket
DOCKER_HOST=unix:///tmp/docker-remote.sock docker compose ps
```

---

## SSH Forwarding for Kubernetes

### kubectl Through SSH Tunnel

```bash
# Forward Kubernetes API server port
ssh -L 6443:kubernetes-api.internal:6443 user@bastion -N -f

# Configure kubectl to use the tunnel
kubectl config set-cluster my-cluster \
  --server=https://localhost:6443 \
  --certificate-authority=/path/to/ca.crt

# Verify connectivity
kubectl get nodes
```

### Kubernetes API via Bastion

```ssh-config
# ~/.ssh/config
Host k8s-bastion
    HostName bastion.example.com
    User ops
    LocalForward 6443 k8s-api.internal:6443
    LocalForward 8001 k8s-api.internal:8001
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 30m
```

### Pod-Level SSH Access

```bash
# SSH into a pod via kubectl port-forward
kubectl port-forward pod/debug-pod 2222:22 &
ssh -p 2222 root@localhost

# Or run commands directly
kubectl exec -it deployment/my-app -- /bin/bash
```

---

## SSHPiper for Multi-Tenant Bastion

SSHPiper is a reverse proxy for SSH that routes connections to different backends
based on username, public key, or custom plugin logic.

### Architecture Overview

```
                    ┌─────────────┐
User A ────────────>│             │──────> Container A
User B ────────────>│  SSHPiper   │──────> Container B
User C ────────────>│  (Bastion)  │──────> VM C
                    └─────────────┘
                    Routes by username
                    or plugin logic
```

### Plugin-Based Routing

SSHPiper supports multiple routing backends:

| Plugin | Description |
|--------|-------------|
| **yaml** | Static YAML config mapping users to upstreams |
| **docker** | Routes to Docker containers by label |
| **kubernetes** | Routes to Kubernetes pods by annotation |
| **workingdir** | File-based config in working directory |
| **fixed** | All connections go to a single upstream |

**YAML plugin example:**

```yaml
# sshpiper.yaml
version: "1.0"
pipes:
  - from:
      - username: alice
    to:
      host: 10.0.1.10:22
      username: deploy
      authorized_keys: /etc/sshpiper/keys/alice.pub
  - from:
      - username: bob
    to:
      host: 10.0.1.20:22
      username: deploy
```

### Docker and Kubernetes Plugins

**Docker plugin** — route SSH by container label:

```bash
# Start SSHPiper with Docker plugin
docker run -d \
  -p 2222:2222 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  farmer1992/sshpiperd:latest \
  /sshpiperd daemon -p 2222 --plugin docker

# Label a container for SSH routing
docker run -d \
  --label sshpiper.username=alice \
  --label sshpiper.container_username=root \
  my-ssh-container
```

**Kubernetes plugin** — route SSH by pod annotation:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dev-alice
  annotations:
    sshpiper.com/username: "alice"
    sshpiper.com/upstream_host: "localhost"
    sshpiper.com/upstream_port: "22"
spec:
  containers:
    - name: workspace
      image: my-dev-workspace
      ports:
        - containerPort: 22
```
