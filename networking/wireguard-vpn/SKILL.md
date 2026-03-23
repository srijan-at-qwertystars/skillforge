---
name: wireguard-vpn
description: >
  Configure, deploy, and troubleshoot WireGuard VPN tunnels across Linux, containers, and cloud
  environments. TRIGGER when: user mentions WireGuard, wg, wg-quick, wireguard-tools, VPN tunnel
  setup, peer configuration, WireGuard key generation (wg genkey, wg pubkey, wg genpsk),
  /etc/wireguard config files, wg0 interface, AllowedIPs routing, site-to-site VPN, mesh VPN
  topology, PersistentKeepalive, WireGuard in Docker/Kubernetes, or cloud VPN with WireGuard on
  AWS/GCP/Azure. Also trigger for VPN split tunneling, PostUp/PostDown firewall scripts, WireGuard
  MTU tuning, WireGuard DNS leak prevention, or WireGuard key rotation. DO NOT trigger for:
  OpenVPN-only configs, IPsec/IKEv2-only setups, Tailscale/Netbird administration (unless
  WireGuard internals are involved), general firewall rules unrelated to VPN, or SSH tunneling.
---

# WireGuard VPN

## Overview

WireGuard is a kernel-level VPN protocol using Curve25519 (key exchange), ChaCha20-Poly1305
(symmetric encryption), BLAKE2s (hashing), and SipHash24 (hashtable keys). Its ~4,000-line
kernel module is auditable and ships in Linux ≥5.6. Prefer WireGuard over OpenVPN (userspace,
TLS complexity, slower) and IPsec (massive codebase, complex IKE negotiation, config sprawl).

WireGuard is stateless — it identifies peers solely by public key. There are no certificates,
no handshake negotiation, no cipher suite selection. This is a feature, not a limitation.

## Key Generation

Generate all keys locally. Never transmit private keys over the network.

```bash
# Generate private key (restrict permissions first)
umask 077
wg genkey > /etc/wireguard/private.key

# Derive public key
wg pubkey < /etc/wireguard/private.key > /etc/wireguard/public.key

# Generate preshared key (optional, adds symmetric encryption layer for post-quantum resistance)
wg genpsk > /etc/wireguard/preshared.key

# One-liner for keypair
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
```

Set file permissions: `chmod 600 /etc/wireguard/*.key /etc/wireguard/*.conf`.

## Configuration File Format

Place configs in `/etc/wireguard/<interface>.conf`. The file has `[Interface]` (local) and
one or more `[Peer]` (remote) sections.

### Server Config (`/etc/wireguard/wg0.conf`)

```ini
[Interface]
Address = 10.0.0.1/24, fd00::1/64
ListenPort = 51820
PrivateKey = <server_private_key>
DNS = 1.1.1.1, 2606:4700:4700::1111
MTU = 1420

PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# Client 1
PublicKey = <client1_public_key>
PresharedKey = <preshared_key>
AllowedIPs = 10.0.0.2/32, fd00::2/128
```

### Client Config (`/etc/wireguard/wg0.conf`)

```ini
[Interface]
Address = 10.0.0.2/24, fd00::2/64
PrivateKey = <client_private_key>
DNS = 1.1.1.1

[Peer]
PublicKey = <server_public_key>
PresharedKey = <preshared_key>
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

### Key Fields

| Field | Description |
|-------|-------------|
| `Address` | VPN IP with CIDR. Use /24 for interface, peers get /32 in AllowedIPs |
| `ListenPort` | UDP port. Only required on server/publicly-reachable side |
| `PrivateKey` | Base64-encoded Curve25519 private key |
| `DNS` | Pushed to client via wg-quick; uses resolvconf/systemd-resolved |
| `AllowedIPs` | Acts as both ACL and routing table. `0.0.0.0/0` = full tunnel |
| `Endpoint` | `host:port` of remote peer. Not needed if peer connects first |
| `PersistentKeepalive` | Seconds between keepalive packets. Set 25 for NAT traversal |
| `PresharedKey` | Optional symmetric key added to Noise handshake |

## wg-quick and systemd

```bash
# Bring interface up/down
wg-quick up wg0
wg-quick down wg0

# Enable on boot via systemd
systemctl enable --now wg-quick@wg0

# Reload config without dropping connections (limited — adds/removes peers only)
wg syncconf wg0 <(wg-quick strip wg0)

# Check status
systemctl status wg-quick@wg0
```

`wg-quick` handles: setting addresses, adding routes from AllowedIPs, configuring DNS,
executing PostUp/PostDown, and setting MTU. Use `wg-quick strip` to extract the raw
`wg`-compatible config (strips wg-quick-specific fields like Address, DNS, PostUp/PostDown).

## Topologies

### Hub-Spoke (Server/Client)

One server with `ListenPort`, all clients connect to it. Server has a `[Peer]` block per
client. Clients set server as `Endpoint`. Set `AllowedIPs = 0.0.0.0/0` on client for full
tunnel, or specific subnets for split tunnel.

Enable IP forwarding on server:

```bash
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
# Persist in /etc/sysctl.d/99-wireguard.conf
```

### Site-to-Site (Mesh)

Each node has a `[Peer]` for every other node. Set `AllowedIPs` to the remote site's subnet.
Both sides need `Endpoint` unless one is behind NAT.

```ini
# Site A (10.1.0.0/24) -> Site B (10.2.0.0/24)
[Peer]
PublicKey = <site_b_pubkey>
Endpoint = site-b.example.com:51820
AllowedIPs = 10.2.0.0/24, fd00:b::/64

# Site B -> Site A
[Peer]
PublicKey = <site_a_pubkey>
Endpoint = site-a.example.com:51820
AllowedIPs = 10.1.0.0/24, fd00:a::/64
```

For full mesh with N nodes, each node needs N-1 peer blocks. Never overlap AllowedIPs
across peers — WireGuard uses cryptokey routing and the most-specific AllowedIPs match wins.

## NAT Traversal and PersistentKeepalive

WireGuard uses UDP only. NAT mappings expire if idle. Set `PersistentKeepalive = 25` on the
peer behind NAT. This sends an authenticated empty packet every 25 seconds to keep the
NAT mapping alive.

- Both peers behind NAT: at least one needs a publicly reachable relay, or use a STUN-like
  approach (WireGuard has no built-in NAT hole-punching).
- UDP port 51820 must be forwarded or allowed through firewalls on the listening side.
- WireGuard handles roaming natively — if a peer's IP changes, WireGuard updates the
  endpoint automatically after receiving an authenticated packet from the new address.

## DNS Configuration and Leak Prevention

Set `DNS =` in `[Interface]` to force DNS through the tunnel when using wg-quick. On Linux,
wg-quick calls `resolvconf` or `systemd-resolved` to install the DNS servers.

Prevent leaks:

```bash
# Kill switch via PostUp — drop all traffic not going through wg0
PostUp = iptables -I OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
PostDown = iptables -D OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
```

For systemd-resolved, set DNS domain routing:

```bash
resolvectl dns wg0 10.0.0.1
resolvectl domain wg0 "~."    # Route ALL DNS queries through wg0
```

## Split Tunneling vs Full Tunneling

**Full tunnel**: `AllowedIPs = 0.0.0.0/0, ::/0` — all traffic routes through VPN.

**Split tunnel**: `AllowedIPs = 10.0.0.0/24, 192.168.1.0/24` — only specified subnets
route through VPN. Default gateway unchanged.

For domain-based split tunneling, use FwMark + policy routing:

```bash
# Mark packets in nftables
nft add rule inet mangle output ip daddr @vpn_destinations meta mark set 51820

# Policy route marked packets through WireGuard
ip rule add fwmark 51820 table 51820
ip route add default dev wg0 table 51820
```

Set `Table = off` in `[Interface]` to prevent wg-quick from adding routes automatically
when you manage routing manually.

## PostUp/PostDown Scripts

Use for firewall rules, routing, logging. `%i` expands to interface name.

### iptables (legacy)

```ini
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostUp = ip6tables -A FORWARD -i %i -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
PostDown = ip6tables -D FORWARD -i %i -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
```

### nftables (modern, preferred)

```ini
PostUp = nft add table inet wg_nat; \
  nft add chain inet wg_nat postrouting { type nat hook postrouting priority srcnat\; policy accept\; }; \
  nft add rule inet wg_nat postrouting oifname "eth0" masquerade
PostDown = nft delete table inet wg_nat
```

Use `nft` over `iptables` on systems running nftables backend (Debian 11+, Ubuntu 22.04+,
RHEL 9+). Check with `nft list ruleset`.

## IPv6 Support

WireGuard supports IPv6 natively. Assign dual-stack addresses:

```ini
[Interface]
Address = 10.0.0.1/24, fd00:vpn::1/64
```

Enable IPv6 forwarding: `sysctl -w net.ipv6.conf.all.forwarding=1`.
Add IPv6 ranges to AllowedIPs. Apply masquerade rules for both `ip` and `ip6` families
(or use `inet` family in nftables to cover both).

Avoid ULA (fd00::/8) collisions — use a randomly generated /48 prefix per deployment.

## Performance Tuning

### MTU

Default WireGuard MTU is 1420 (1500 - 80 bytes overhead). Adjust for your environment:

| Environment | Recommended MTU |
|-------------|----------------|
| Standard ethernet | 1420 |
| PPPoE | 1412 |
| Cloud VM (AWS/GCP/Azure) | 1380–1400 |
| Docker overlay | 1370–1400 |
| Double encapsulation | 1360–1380 |

Discover optimal MTU empirically:

```bash
ping -M do -s 1392 -c 4 <remote_wg_ip>   # Reduce until no fragmentation
# Optimal MTU = largest working size + 28
```

Set MSS clamping to prevent TCP fragmentation:

```bash
iptables -t mangle -A FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

### Kernel Buffer Tuning (high-throughput)

```bash
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sysctl -w net.ipv4.tcp_wmem="4096 87380 16777216"
```

### FwMark

Use `FwMark` in `[Interface]` to mark WireGuard's own encapsulated packets, preventing
routing loops when `AllowedIPs = 0.0.0.0/0`. wg-quick sets this automatically.

```ini
[Interface]
FwMark = 51820
```

Then add: `ip rule add not fwmark 51820 table 51820` to route unmarked traffic through VPN.

## Container/Docker Networking

### WireGuard inside a container

```yaml
# docker-compose.yml
services:
  wireguard:
    image: linuxserver/wireguard
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
    volumes:
      - ./config:/config
    ports:
      - "51820:51820/udp"
    environment:
      - PUID=1000
      - PGID=1000
```

### Route container traffic through WireGuard

Use `network_mode: "service:wireguard"` on other containers to route their traffic through
the WireGuard container's network namespace.

### MTU considerations

Set `MTU = 1380` in WireGuard config inside containers. Docker bridge adds overhead.
Always test with `ping -M do` from inside the container.

## Cloud Providers

### AWS

- Open UDP 51820 in Security Group (inbound).
- Disable source/destination check on the WireGuard EC2 instance.
- Use elastic IP for stable endpoint. MTU: start at 1400.
- For VPC peering through WireGuard, add VPC CIDR to AllowedIPs.

### GCP

- Create firewall rule allowing UDP 51820.
- Use static external IP. MTU: start at 1380.
- Enable IP forwarding on the VM instance at creation time.

### Azure

- Add NSG rule for UDP 51820.
- Enable IP forwarding on NIC. MTU: start at 1380.
- Use Standard SKU public IP for zone redundancy.

All clouds: use cloud-init or startup scripts to install wireguard-tools and deploy configs
at boot. Store private keys in secrets manager (AWS Secrets Manager, GCP Secret Manager,
Azure Key Vault), fetch at boot, write to tmpfs.

## Monitoring and Debugging

```bash
# Show interface status, peers, last handshake, transfer stats
wg show
wg show wg0

# Detailed per-peer info
wg show wg0 dump

# Monitor handshakes in real time
watch -n 1 wg show wg0

# Capture WireGuard traffic (encrypted)
tcpdump -i eth0 udp port 51820

# Capture decrypted tunnel traffic
tcpdump -i wg0

# Check kernel module
lsmod | grep wireguard

# Verify routes
ip route show table all | grep wg0
ip rule show

# Debug DNS resolution over tunnel
resolvectl status wg0
dig @10.0.0.1 example.com
```

**Handshake troubleshooting**: if `latest handshake` is missing or stale (>2 min), check:
firewall rules, endpoint reachability (UDP), key mismatch, AllowedIPs mismatch, clock skew
(WireGuard uses TAI64N timestamps — clocks must be within ~180s).

## Security Considerations

- **Private key protection**: `chmod 600`, never in version control, never in logs. Use
  `wg show` (does not print private keys by default).
- **PresharedKey**: adds post-quantum resistance via an additional symmetric key in the
  Noise handshake. Use unique PSK per peer pair.
- **No user authentication**: WireGuard authenticates by key, not by user. Layer additional
  auth (RADIUS, SSO) on top if needed.
- **Minimal attack surface**: unresponsive to unauthenticated packets — does not respond to
  port scans. WireGuard interface appears invisible to scanners.
- **Rekeying**: automatic every 2 minutes or 2^64-1 bytes. No manual intervention needed.
- **Timer-based expiration**: sessions expire after 5 minutes of inactivity (no handshake).

### Key Rotation Procedure

1. Generate new keypair on the peer device locally.
2. Update the peer's config with new private key.
3. Update all remote peers with the new public key.
4. Restart the rotated peer: `systemctl restart wg-quick@wg0`.
5. Verify handshake with `wg show wg0`.
6. Remove old public key from all peer configs after confirmation.
7. Retain old private key for 24–48h as rollback.

## Common Anti-Patterns and Gotchas

**Overlapping AllowedIPs across peers**: causes routing ambiguity. Each IP/subnet must
appear in exactly one peer's AllowedIPs.

**Using 0.0.0.0/0 on server side**: this routes ALL server traffic into the client tunnel.
On the server, set AllowedIPs to the client's specific VPN IP (/32).

**Forgetting IP forwarding**: WireGuard brings up the tunnel but nothing routes through.
Enable `net.ipv4.ip_forward=1` and persist it.

**Wrong MTU causing silent failures**: large packets drop, small ones work. Manifests as
SSH works but HTTPS/SCP stalls. Always verify MTU with `ping -M do`.

**DNS leaks on Linux**: wg-quick DNS only works with resolvconf or systemd-resolved
installed. Verify with `resolvectl status` or `cat /etc/resolv.conf`.

**PostUp/PostDown syntax errors**: semicolons and backslashes must be escaped in the config
file. Test commands manually before adding to config.

**Clock skew**: WireGuard uses timestamps to prevent replay attacks. NTP must be configured
on all peers. Skew >180s causes handshake failure.

**Running wg-quick as non-root**: requires `CAP_NET_ADMIN`. Use systemd service instead of
manual invocation.

**AllowedIPs = 0.0.0.0/0 breaks LAN access**: the default route goes through VPN. Exclude
LAN with: `AllowedIPs = 0.0.0.0/1, 128.0.0.0/1` (covers all IPs without being the default
route) or add explicit LAN routes in PostUp.

**Firewall blocking UDP**: WireGuard is UDP-only. If UDP 51820 is blocked, WireGuard cannot
connect. No TCP fallback exists. Use a UDP-to-TCP wrapper (e.g., udp2raw, wstunnel) or
change port to 443/UDP if needed.

**Restarting vs reloading**: `wg-quick down && wg-quick up` drops all connections. Use
`wg syncconf wg0 <(wg-quick strip wg0)` to apply peer changes without disruption.

## Resources

### References

| File | Description |
|------|-------------|
| [references/advanced-patterns.md](references/advanced-patterns.md) | Multi-hop routing, policy-based routing with FwMark, WireGuard over TCP (udp2raw/wstunnel), dynamic peer management, network namespaces, kernel vs userspace implementations, fail2ban integration, Kubernetes (Kilo/Netbird), and Tailscale/Headscale architecture |
| [references/troubleshooting.md](references/troubleshooting.md) | Handshake failures, MTU/fragmentation issues, DNS leaks, firewall blocking UDP, asymmetric routing, AllowedIPs conflicts, kernel module loading, systemd-resolved problems, and performance debugging |

### Scripts

| File | Description |
|------|-------------|
| [scripts/wg-genconfig.sh](scripts/wg-genconfig.sh) | Generate server + client configs from endpoint, subnet, and client count. Supports PSK, split tunneling, custom DNS |
| [scripts/wg-status.sh](scripts/wg-status.sh) | Enhanced `wg show` — human-readable handshake ages, transfer rates, health indicators, JSON output, watch mode |
| [scripts/wg-rotate-keys.sh](scripts/wg-rotate-keys.sh) | Key rotation — generates new keypair, updates local config, outputs peer update commands. Supports backup and auto-apply |

### Assets

| File | Description |
|------|-------------|
| [assets/server.conf](assets/server.conf) | Production server config template with iptables NAT, MSS clamping, dual-stack, and peer examples |
| [assets/client.conf](assets/client.conf) | Client config template with full/split tunnel options, kill switch, and DNS leak prevention |
| [assets/docker-compose.yml](assets/docker-compose.yml) | Docker Compose for WireGuard with automatic config generation, health checks, and optional web UI |
| [assets/wg-firewall.nft](assets/wg-firewall.nft) | nftables ruleset — input filtering, forwarding, NAT masquerade, MSS clamping, rate limiting |
