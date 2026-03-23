# Advanced WireGuard Patterns

## Table of Contents

- [Multi-Hop Routing](#multi-hop-routing)
- [Policy-Based Routing with FwMark](#policy-based-routing-with-fwmark)
- [WireGuard over TCP](#wireguard-over-tcp)
- [Dynamic Peer Management](#dynamic-peer-management)
- [WireGuard with Network Namespaces](#wireguard-with-network-namespaces)
- [Kernel vs Userspace Implementations](#kernel-vs-userspace-implementations)
- [Integration with fail2ban](#integration-with-fail2ban)
- [WireGuard in Kubernetes](#wireguard-in-kubernetes)
- [Tailscale and Headscale Architecture](#tailscale-and-headscale-architecture)

---

## Multi-Hop Routing

Multi-hop WireGuard chains tunnels through intermediate nodes, useful for geographic
routing, traffic obfuscation, or reaching isolated networks.

### Two-Hop Chain: Client → Relay → Destination

**Client config:**

```ini
[Interface]
Address = 10.0.1.2/24
PrivateKey = <client_private>

[Peer]
# Relay server
PublicKey = <relay_public>
Endpoint = relay.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

**Relay config (`/etc/wireguard/wg0.conf`):**

```ini
[Interface]
Address = 10.0.1.1/24
ListenPort = 51820
PrivateKey = <relay_private>
# Forward between wg interfaces
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -A FORWARD -i wg0 -o wg1 -j ACCEPT
PostUp = iptables -A FORWARD -i wg1 -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -o wg1 -j ACCEPT
PostDown = iptables -D FORWARD -i wg1 -o wg0 -j ACCEPT

[Peer]
# Client
PublicKey = <client_public>
AllowedIPs = 10.0.1.2/32
```

**Relay config (`/etc/wireguard/wg1.conf`):**

```ini
[Interface]
Address = 10.0.2.1/24
PrivateKey = <relay_private_2>

[Peer]
# Destination server
PublicKey = <dest_public>
Endpoint = dest.example.com:51820
AllowedIPs = 10.0.2.0/24, 192.168.0.0/16
PersistentKeepalive = 25
```

### Key Considerations

- Each hop adds latency (~1-5ms per hop on good links).
- MTU decreases per hop: 1420 → 1340 → 1260 (subtract 80 bytes per encapsulation).
- The relay sees metadata (timing, packet size) but cannot decrypt payload.
- Use separate WireGuard interfaces per hop on the relay to avoid AllowedIPs conflicts.
- Enable IP forwarding between wg interfaces on the relay.

### Three-Hop and Beyond

For more than two hops, repeat the relay pattern. Each relay:
1. Runs two WireGuard interfaces (inbound and outbound).
2. Forwards traffic between them with iptables/nftables.
3. Decreases MTU by 80 bytes per additional encapsulation.

Beyond 3 hops is rarely justified — latency and MTU overhead compound quickly.

---

## Policy-Based Routing with FwMark

FwMark enables fine-grained control over which traffic enters the WireGuard tunnel.

### Basic FwMark Setup

```ini
[Interface]
Address = 10.0.0.2/24
PrivateKey = <private_key>
FwMark = 51820
Table = off
PostUp = ip rule add not fwmark 51820 table 51820
PostUp = ip route add default dev %i table 51820
PostDown = ip rule del not fwmark 51820 table 51820
PostDown = ip route del default dev %i table 51820
```

Setting `Table = off` prevents wg-quick from auto-managing routes. FwMark = 51820 marks
WireGuard's own encapsulated UDP packets so they bypass the tunnel routing rule
(preventing loops).

### Routing Specific Applications Through VPN

Use cgroups + nftables to route by process:

```bash
# Create a cgroup for VPN-routed processes
mkdir -p /sys/fs/cgroup/net_cls/vpn
echo 51821 > /sys/fs/cgroup/net_cls/vpn/net_cls.classid

# nftables rule to mark traffic from that cgroup
nft add table inet mangle
nft add chain inet mangle output { type route hook output priority mangle \; }
nft add rule inet mangle output meta cgroup 51821 meta mark set 51820

# Route marked traffic through WireGuard
ip rule add fwmark 51820 table 51820
ip route add default dev wg0 table 51820

# Run a process through VPN
cgexec -g net_cls:vpn curl https://ifconfig.me
```

### Routing by Destination

```bash
# Create an nftables set of destinations
nft add set inet mangle vpn_dests { type ipv4_addr \; flags interval \; }
nft add element inet mangle vpn_dests { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
nft add rule inet mangle output ip daddr @vpn_dests meta mark set 51820
```

### Routing by Source IP

For multi-homed servers with multiple WireGuard tunnels:

```bash
# Traffic from 10.1.0.0/24 goes through wg0
ip rule add from 10.1.0.0/24 table 100
ip route add default dev wg0 table 100

# Traffic from 10.2.0.0/24 goes through wg1
ip rule add from 10.2.0.0/24 table 200
ip route add default dev wg1 table 200
```

---

## WireGuard over TCP

WireGuard is UDP-only by design. When UDP is blocked (corporate firewalls, restrictive
networks), wrap WireGuard traffic in TCP using a tunneling tool.

### udp2raw

Tunnels UDP over a fake TCP connection (raw sockets). Low overhead but requires root
on both sides.

**Server:**

```bash
udp2raw -s -l 0.0.0.0:443 -r 127.0.0.1:51820 \
  --raw-mode faketcp --cipher-mode xor --auth-mode simple \
  -k "shared_secret"
```

**Client:**

```bash
udp2raw -c -l 127.0.0.1:51821 -r server.example.com:443 \
  --raw-mode faketcp --cipher-mode xor --auth-mode simple \
  -k "shared_secret"
```

Then point WireGuard client Endpoint to `127.0.0.1:51821`.

### wstunnel

Tunnels over WebSocket (HTTP/HTTPS). Works through HTTP proxies. No raw socket
requirement.

**Server:**

```bash
wstunnel server wss://0.0.0.0:443 \
  --restrict-to 127.0.0.1:51820
```

**Client:**

```bash
wstunnel client -L udp://127.0.0.1:51821:127.0.0.1:51820 \
  wss://server.example.com:443
```

### Comparison

| Feature | udp2raw | wstunnel |
|---------|---------|----------|
| Protocol | Fake TCP/ICMP | WebSocket (HTTP/S) |
| Root required | Yes (raw sockets) | No |
| Works through HTTP proxy | No | Yes |
| Overhead | Low (~2%) | Medium (~5-10%) |
| Detection resistance | Moderate | High (looks like HTTPS) |
| MTU impact | -20 bytes | -40 to -60 bytes |

### Performance Considerations

- TCP-over-TCP introduces head-of-line blocking and retransmission amplification.
- Expect 10-30% throughput reduction compared to native UDP.
- Latency increases due to TCP acknowledgment overhead.
- Set lower MTU (1300-1360) to account for additional encapsulation headers.

---

## Dynamic Peer Management

For environments with many peers that change frequently (VPN services, IoT fleets),
manage peers programmatically.

### wg set (Runtime Changes)

```bash
# Add peer at runtime (no restart)
wg set wg0 peer <PUBLIC_KEY> \
  allowed-ips 10.0.0.5/32 \
  endpoint 203.0.113.5:51820 \
  persistent-keepalive 25

# Remove peer at runtime
wg set wg0 peer <PUBLIC_KEY> remove

# Update AllowedIPs for existing peer
wg set wg0 peer <PUBLIC_KEY> allowed-ips 10.0.0.5/32,10.0.1.0/24
```

### wg syncconf (Bulk Updates)

```bash
# Generate stripped config and apply — adds new peers, updates existing,
# but does NOT remove peers absent from the new config
wg syncconf wg0 <(wg-quick strip wg0)

# For full sync (remove peers not in config), restart is required
wg-quick down wg0 && wg-quick up wg0
```

### API-Driven Peer Management

Build an API that generates configs and manages peers:

```python
#!/usr/bin/env python3
"""Minimal WireGuard peer management API."""
import subprocess
import json

def add_peer(interface: str, public_key: str, allowed_ips: str,
             endpoint: str = None, keepalive: int = 25) -> bool:
    cmd = ["wg", "set", interface, "peer", public_key,
           "allowed-ips", allowed_ips,
           "persistent-keepalive", str(keepalive)]
    if endpoint:
        cmd.extend(["endpoint", endpoint])
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0

def remove_peer(interface: str, public_key: str) -> bool:
    cmd = ["wg", "set", interface, "peer", public_key, "remove"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0

def list_peers(interface: str) -> list:
    result = subprocess.run(["wg", "show", interface, "dump"],
                            capture_output=True, text=True)
    peers = []
    for line in result.stdout.strip().split("\n")[1:]:  # skip header
        fields = line.split("\t")
        peers.append({
            "public_key": fields[0],
            "endpoint": fields[2] if fields[2] != "(none)" else None,
            "allowed_ips": fields[3],
            "latest_handshake": int(fields[4]),
            "transfer_rx": int(fields[5]),
            "transfer_tx": int(fields[6]),
        })
    return peers
```

### Automatic Peer Expiration

Use a cron job to remove peers with stale handshakes:

```bash
#!/bin/bash
# Remove peers with no handshake in the last 7 days
THRESHOLD=$((7 * 86400))
NOW=$(date +%s)

wg show wg0 dump | tail -n +2 | while IFS=$'\t' read -r pubkey _ _ _ handshake _ _; do
    if [ "$handshake" -eq 0 ] || [ $((NOW - handshake)) -gt $THRESHOLD ]; then
        wg set wg0 peer "$pubkey" remove
        echo "Removed stale peer: $pubkey"
    fi
done
```

---

## WireGuard with Network Namespaces

Network namespaces isolate WireGuard from the host network stack. This is the
recommended approach for preventing leaks.

### Full Namespace Isolation

```bash
# Create namespace
ip netns add vpn

# Create WireGuard interface in the default namespace
ip link add wg0 type wireguard

# Move it to the vpn namespace
ip link set wg0 netns vpn

# Configure inside the namespace
ip netns exec vpn wg setconf wg0 /etc/wireguard/wg0.conf
ip netns exec vpn ip addr add 10.0.0.2/24 dev wg0
ip netns exec vpn ip link set wg0 up
ip netns exec vpn ip link set lo up
ip netns exec vpn ip route add default dev wg0

# Run applications inside the namespace
ip netns exec vpn curl https://ifconfig.me
ip netns exec vpn firefox  # all traffic forced through VPN
```

### Why Namespaces Prevent Leaks

Applications inside the namespace can only see the WireGuard interface (and loopback).
There is no access to the host's physical interfaces. Even if DNS settings are
misconfigured, there is no path for traffic to leak outside the tunnel.

### Namespace with veth Pair

To allow selective access between host and namespace:

```bash
# Create veth pair
ip link add veth-host type veth peer name veth-vpn

# Move one end to namespace
ip link set veth-vpn netns vpn

# Configure addresses
ip addr add 172.16.0.1/30 dev veth-host
ip link set veth-host up
ip netns exec vpn ip addr add 172.16.0.2/30 dev veth-vpn
ip netns exec vpn ip link set veth-vpn up

# Now host and namespace can communicate over 172.16.0.0/30
# while VPN traffic stays in the namespace
```

### Persistent Namespace with systemd

```ini
# /etc/systemd/system/wg-netns@.service
[Unit]
Description=WireGuard in namespace %i
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/wg-netns-up.sh %i
ExecStop=/usr/local/bin/wg-netns-down.sh %i

[Install]
WantedBy=multi-user.target
```

---

## Kernel vs Userspace Implementations

### Linux Kernel Module (Default)

- Ships with Linux ≥5.6.
- Best performance: ~1 Gbps+ with ChaCha20-Poly1305.
- Runs in kernel space — zero context switch overhead.
- Load with `modprobe wireguard`. Check with `lsmod | grep wireguard`.
- On older kernels (3.10-5.5), install via DKMS or backport packages.

### wireguard-go

- Official userspace Go implementation by the WireGuard project.
- Cross-platform: macOS, Windows, FreeBSD, OpenBSD.
- Performance: ~400-600 Mbps typical (CPU-bound).
- Used by default on macOS and Windows.
- Set `WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go` to force userspace on Linux.

```bash
# Run wireguard-go manually
WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go wg-quick up wg0
```

### boringtun

- Userspace Rust implementation by Cloudflare.
- Higher performance than wireguard-go (~700-900 Mbps).
- Supports both standalone and library mode.
- Used in Cloudflare WARP and some embedded systems.

```bash
# Install and use boringtun
cargo install boringtun-cli
WG_QUICK_USERSPACE_IMPLEMENTATION=boringtun-cli wg-quick up wg0
```

### Comparison

| Implementation | Language | Performance | Platform | Use Case |
|----------------|----------|-------------|----------|----------|
| Kernel module | C | ~1+ Gbps | Linux ≥5.6 | Production Linux servers |
| wireguard-go | Go | ~400-600 Mbps | Cross-platform | macOS, Windows, BSD |
| boringtun | Rust | ~700-900 Mbps | Cross-platform | Embedded, Cloudflare |

Always prefer the kernel module on Linux. Use userspace only when the kernel module
is unavailable (containers without CAP_SYS_MODULE, non-Linux OS, old kernels).

---

## Integration with fail2ban

WireGuard itself is resistant to brute-force (no response to unauthenticated packets),
but you can monitor for suspicious activity on the WireGuard port.

### Monitor UDP Connection Attempts

Since WireGuard silently drops unauthenticated packets, fail2ban cannot detect failed
WireGuard authentications directly. Instead, monitor at the network level.

**nftables logging for excessive connection attempts:**

```bash
# /etc/nftables.d/wg-monitor.conf
table inet wg_monitor {
    set wg_rate_limit {
        type ipv4_addr
        flags dynamic,timeout
        timeout 5m
    }

    chain input {
        type filter hook input priority filter - 1; policy accept;
        udp dport 51820 ct state new \
            add @wg_rate_limit { ip saddr limit rate over 10/minute } \
            log prefix "WG_RATELIMIT: " drop
    }
}
```

**fail2ban filter (`/etc/fail2ban/filter.d/wireguard.conf`):**

```ini
[Definition]
failregex = WG_RATELIMIT: .*SRC=<HOST>
ignoreregex =
```

**fail2ban jail (`/etc/fail2ban/jail.d/wireguard.conf`):**

```ini
[wireguard]
enabled = true
filter = wireguard
logpath = /var/log/kern.log
maxretry = 5
findtime = 300
bantime = 3600
action = nftables-allports[name=wireguard]
```

### Protecting the Management API

If you expose a WireGuard management API, protect it with fail2ban monitoring for
failed auth attempts, rate limiting, and IP allowlisting.

---

## WireGuard in Kubernetes

### Kilo

Kilo creates a WireGuard mesh between Kubernetes nodes across different networks
or cloud providers.

**Architecture:**
- Runs as a DaemonSet on each node.
- Uses node annotations to determine topology.
- Creates WireGuard tunnels between nodes in different locations.
- Nodes in the same location communicate directly (no tunnel).
- Integrates with the Kubernetes CNI.

```bash
# Install Kilo
kubectl apply -f https://raw.githubusercontent.com/squat/kilo/main/manifests/kilo-kubeadm.yaml

# Annotate nodes with their location
kubectl annotate node node1 kilo.squat.ai/location="us-east"
kubectl annotate node node2 kilo.squat.ai/location="eu-west"

# Nodes in different locations auto-connect via WireGuard
# Nodes in the same location use direct routing
```

**Use cases:** Multi-cloud Kubernetes, edge computing, hybrid cloud.

### Netbird

Netbird (formerly Wiretrustee) provides a WireGuard-based overlay network with:
- Central management server for peer coordination.
- NAT traversal using ICE (STUN/TURN).
- ACLs and network policies.
- SSO integration (OIDC).
- Client runs as an agent on each node.

```bash
# Install Netbird agent
curl -fsSL https://pkgs.netbird.io/install.sh | sh

# Connect to management server
netbird up --management-url https://netbird.example.com
```

### Pod-to-Pod Encryption with WireGuard

Some CNI plugins (Calico, Cilium) support WireGuard for pod-to-pod encryption:

```bash
# Calico: enable WireGuard encryption
kubectl patch felixconfiguration default --type='merge' \
  -p '{"spec":{"wireguardEnabled":true}}'

# Cilium: enable WireGuard encryption
cilium config set enable-wireguard true
cilium config set encrypt-node true
```

This encrypts all pod-to-pod traffic at the node level without modifying applications.

---

## Tailscale and Headscale Architecture

### Tailscale

Tailscale builds a mesh VPN on top of WireGuard with a control plane for coordination.

**Architecture Components:**
- **Control server** (coordination.tailscale.com): Distributes public keys, manages
  ACLs, coordinates NAT traversal. Never sees traffic.
- **DERP relays**: Relay encrypted WireGuard traffic when direct connections fail.
  Traffic is end-to-end encrypted — relays cannot decrypt.
- **Client (tailscaled)**: Runs on each device. Manages WireGuard interface,
  handles NAT traversal via ICE/STUN, connects to DERP as fallback.

**How it works:**
1. Client registers with control server, uploads public key.
2. Control server distributes peer public keys and endpoints.
3. Clients attempt direct WireGuard connections (STUN, port mapping).
4. If direct fails, traffic routes through DERP relay (still encrypted).
5. ACLs are enforced by each client based on policy from control server.

**Key insight:** Tailscale replaces manual Endpoint configuration and key distribution
with an automated control plane. The data plane is pure WireGuard.

### Headscale

Open-source, self-hosted implementation of the Tailscale control server.

```bash
# Install Headscale
wget https://github.com/juanfont/headscale/releases/latest/download/headscale_linux_amd64
chmod +x headscale_linux_amd64
mv headscale_linux_amd64 /usr/local/bin/headscale

# Create config
headscale generate private-key > /etc/headscale/private.key
```

**Headscale config (`/etc/headscale/config.yaml`):**

```yaml
server_url: https://headscale.example.com
listen_addr: 0.0.0.0:8080
private_key_path: /etc/headscale/private.key
ip_prefixes:
  - 100.64.0.0/10
  - fd7a:115c:a1e0::/48
derp:
  server:
    enabled: true
    region_id: 999
    stun_listen_addr: 0.0.0.0:3478
```

**Connecting Tailscale clients to Headscale:**

```bash
tailscale up --login-server https://headscale.example.com
```

### When to Use What

| Approach | Use Case |
|----------|----------|
| Raw WireGuard | Full control, few peers, infrastructure-as-code |
| Tailscale | Quick setup, managed service OK, many devices |
| Headscale | Self-hosted, Tailscale client compatibility, privacy |
| Netbird | Enterprise features, SSO, granular ACLs |
| Kilo | Kubernetes multi-cluster networking |
