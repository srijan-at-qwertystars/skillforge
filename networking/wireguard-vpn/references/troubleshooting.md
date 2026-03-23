# WireGuard Troubleshooting Guide

## Table of Contents

- [Handshake Failures](#handshake-failures)
- [MTU Problems and Fragmentation](#mtu-problems-and-fragmentation)
- [DNS Leaks](#dns-leaks)
- [Firewall Blocking UDP](#firewall-blocking-udp)
- [Asymmetric Routing](#asymmetric-routing)
- [AllowedIPs Conflicts](#allowedips-conflicts)
- [Kernel Module Loading Issues](#kernel-module-loading-issues)
- [systemd-resolved Integration Problems](#systemd-resolved-integration-problems)
- [Performance Debugging](#performance-debugging)
- [Quick Diagnostic Checklist](#quick-diagnostic-checklist)

---

## Handshake Failures

The WireGuard handshake is a 1-RTT Noise IK exchange. If `wg show` displays no
`latest handshake` or it's older than 2-3 minutes, the handshake is failing.

### Symptoms

- `wg show wg0` shows peer with no `latest handshake` timestamp.
- Tunnel interface is up but no traffic passes.
- `ping` across the tunnel returns `Destination Host Unreachable` or times out.

### Diagnosis

```bash
# Check if handshake has ever succeeded
wg show wg0

# Look for the latest handshake field
# "latest handshake: X seconds ago" = working
# No "latest handshake" line = never connected

# Monitor in real time
watch -n 1 'wg show wg0'

# Check kernel logs for WireGuard messages
dmesg | grep -i wireguard
journalctl -k | grep -i wireguard

# Verify UDP connectivity to endpoint
nc -zuv <endpoint_ip> 51820
# Or with nmap
nmap -sU -p 51820 <endpoint_ip>
```

### Common Causes and Fixes

**1. Key mismatch**

The most common cause. Verify that each side has the correct peer public key.

```bash
# Show local public key
wg show wg0 public-key

# Show configured peer public keys
wg show wg0 peers

# Regenerate and redistribute keys if uncertain
wg genkey | tee private.key | wg pubkey > public.key
```

**2. Endpoint unreachable**

```bash
# Test UDP connectivity
nc -zuv <endpoint_ip> 51820

# Check if endpoint resolves correctly
dig +short <endpoint_hostname>
host <endpoint_hostname>

# Verify from server that it's listening
ss -ulnp | grep 51820
```

**3. Clock skew**

WireGuard uses TAI64N timestamps in the handshake to prevent replay attacks.
Clocks must be within ~180 seconds.

```bash
# Check time on both peers
date -u
timedatectl status

# Fix with NTP
systemctl restart systemd-timesyncd
# Or
ntpdate -u pool.ntp.org
chronyc -a makestep
```

**4. AllowedIPs mismatch**

The initiator sends from an IP that must be in the responder's AllowedIPs for
that peer. If the source IP isn't allowed, traffic is silently dropped.

```bash
# Verify AllowedIPs on both sides
wg show wg0 allowed-ips

# Common mistake: server has AllowedIPs = 10.0.0.2/32 but client sends
# from 10.0.0.3 (wrong IP configured in client [Interface] Address)
```

**5. Firewall blocking WireGuard UDP port**

```bash
# Check iptables
iptables -L INPUT -n -v | grep 51820

# Check nftables
nft list ruleset | grep 51820

# Check firewalld
firewall-cmd --list-all

# Check ufw
ufw status verbose
```

**6. NAT timeout (for peers behind NAT)**

```bash
# If peer is behind NAT, ensure PersistentKeepalive is set
# on the peer behind NAT (not on the public-facing side)
wg set wg0 peer <PUBKEY> persistent-keepalive 25
```

---

## MTU Problems and Fragmentation

MTU issues are the second most common WireGuard problem. They manifest as
partial connectivity — small packets work, large packets fail.

### Symptoms

- SSH connections work, but SCP/SFTP stalls or is extremely slow.
- HTTPS connections hang after initial handshake.
- `ping` with small packets works, large packets fail.
- Intermittent connection drops under load.
- `curl` to any URL hangs or times out.

### Diagnosis

```bash
# Test MTU from inside the tunnel
# Start from 1420 and decrease until it works
ping -M do -s 1392 -c 4 <remote_wg_ip>    # 1392 + 28 = 1420
ping -M do -s 1372 -c 4 <remote_wg_ip>    # 1372 + 28 = 1400
ping -M do -s 1352 -c 4 <remote_wg_ip>    # 1352 + 28 = 1380

# Check current MTU
ip link show wg0

# Check for ICMP fragmentation needed messages (should NOT be blocked)
tcpdump -i eth0 'icmp[icmptype] == 3 and icmp[icmpcode] == 4'

# Check for packet drops
cat /proc/net/dev | grep wg0
```

### Fixes

**1. Set correct MTU in WireGuard config**

```ini
[Interface]
MTU = 1380  # Conservative value that works in most environments
```

```bash
# Change MTU at runtime
ip link set dev wg0 mtu 1380
```

**2. Enable MSS clamping**

Clamps TCP MSS to prevent fragmentation. Essential when MTU is non-standard.

```bash
# iptables
iptables -t mangle -A FORWARD -i wg0 -p tcp \
  --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# nftables
nft add rule inet mangle forward iifname "wg0" tcp flags syn / syn,rst \
  tcp option maxseg size set rt mtu
```

**3. Environment-specific MTU values**

| Environment | MTU | Calculation |
|-------------|-----|-------------|
| Standard Ethernet | 1420 | 1500 - 80 (WG overhead) |
| PPPoE | 1412 | 1492 - 80 |
| AWS | 1400 | 1500 - 80 - 20 (encapsulation) |
| GCP | 1380 | 1460 - 80 |
| Azure | 1380 | 1500 - 80 - 40 (VNet) |
| Docker bridge | 1380 | 1500 - 80 - 40 (bridge) |
| WG over WG (multi-hop) | 1340 | 1420 - 80 |
| WG over TCP (udp2raw) | 1340 | 1420 - 60 - 20 |

**4. Path MTU Discovery**

Ensure ICMP type 3, code 4 (Fragmentation Needed) is not blocked anywhere
in the path. Blocking PMTUD breaks MTU negotiation.

```bash
# Verify PMTUD is not disabled
sysctl net.ipv4.ip_no_pmtu_disc
# Should be 0

# Never block ICMP fragmentation-needed
iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT
```

---

## DNS Leaks

DNS leaks occur when DNS queries bypass the VPN tunnel and reach the ISP's
DNS servers, revealing browsing activity.

### Symptoms

- DNS queries resolve when using the ISP's DNS but not through the tunnel.
- `resolvectl status` shows wrong DNS server for wg0.
- `dig` returns results from ISP DNS when tunnel is up.
- DNS leak test websites show ISP DNS servers.

### Diagnosis

```bash
# Check which DNS server is being used
resolvectl status
cat /etc/resolv.conf
nmcli dev show | grep DNS

# Test DNS through tunnel
dig @<wg_dns_server> example.com

# Test for leaks
dig +short whoami.akamai.net  # shows the DNS resolver IP
# Should show VPN DNS, not ISP DNS

# Check DNS routing domains
resolvectl domain
```

### Fixes

**1. Set DNS in WireGuard config**

```ini
[Interface]
DNS = 10.0.0.1, 1.1.1.1
```

wg-quick will configure systemd-resolved or resolvconf automatically.

**2. Force all DNS through tunnel**

```bash
# Set wg0 as the default DNS route
resolvectl dns wg0 10.0.0.1
resolvectl domain wg0 "~."   # "~." = route ALL domains through this interface

# Verify
resolvectl status wg0
```

**3. Kill switch to prevent leaks**

Block DNS on all interfaces except wg0:

```bash
# PostUp rules
PostUp = iptables -I OUTPUT -p udp --dport 53 ! -o %i -j REJECT
PostUp = iptables -I OUTPUT -p tcp --dport 53 ! -o %i -j REJECT
# Allow DNS to the WireGuard endpoint (needed for initial resolution)
PostUp = iptables -I OUTPUT -p udp --dport 53 -d <endpoint_ip> -j ACCEPT

PostDown = iptables -D OUTPUT -p udp --dport 53 ! -o %i -j REJECT
PostDown = iptables -D OUTPUT -p tcp --dport 53 ! -o %i -j REJECT
PostDown = iptables -D OUTPUT -p udp --dport 53 -d <endpoint_ip> -j ACCEPT
```

**4. Network namespace isolation**

The most reliable leak prevention — run applications in a network namespace
that only has access to the WireGuard interface:

```bash
ip netns add vpn
ip link set wg0 netns vpn
ip netns exec vpn ip addr add 10.0.0.2/24 dev wg0
ip netns exec vpn ip link set wg0 up
ip netns exec vpn ip route add default dev wg0
# All processes in this namespace can only use wg0
```

---

## Firewall Blocking UDP

WireGuard requires UDP connectivity. If UDP is blocked, WireGuard cannot function.

### Symptoms

- Handshake never completes.
- `nc -zuv <endpoint> 51820` fails or times out.
- Works on some networks but not others.
- Works on mobile data but not on corporate WiFi.

### Diagnosis

```bash
# Test UDP connectivity
nc -zuv <endpoint_ip> 51820

# Test if ANY UDP works
nc -zuv 1.1.1.1 53

# Check local firewall
iptables -L -n -v | grep -E '51820|DROP|REJECT'
nft list ruleset | grep -E '51820|drop|reject'

# Check from server side that port is open
ss -ulnp | grep 51820

# Capture to see if packets arrive
tcpdump -i eth0 udp port 51820 -c 10
```

### Fixes

**1. Open the port in local firewall**

```bash
# iptables
iptables -A INPUT -p udp --dport 51820 -j ACCEPT

# nftables
nft add rule inet filter input udp dport 51820 accept

# firewalld
firewall-cmd --permanent --add-port=51820/udp
firewall-cmd --reload

# ufw
ufw allow 51820/udp
```

**2. Change to a common port**

Some firewalls block non-standard UDP ports. Try port 53 (DNS) or 443:

```ini
[Interface]
ListenPort = 443   # Often allowed through firewalls
```

**3. Use TCP tunneling as a last resort**

If UDP is completely blocked, wrap WireGuard in TCP. See the
[advanced patterns](advanced-patterns.md#wireguard-over-tcp) document for
udp2raw and wstunnel setups.

**4. Cloud provider firewall rules**

```bash
# AWS Security Group
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxx \
  --protocol udp --port 51820 --cidr 0.0.0.0/0

# GCP firewall rule
gcloud compute firewall-rules create allow-wireguard \
  --allow udp:51820 --direction INGRESS --target-tags wireguard

# Azure NSG
az network nsg rule create --nsg-name wg-nsg --name allow-wg \
  --priority 100 --protocol Udp --destination-port-ranges 51820
```

---

## Asymmetric Routing

Asymmetric routing occurs when traffic takes different paths in and out, causing
response packets to be dropped by stateful firewalls or RPF (Reverse Path
Filtering).

### Symptoms

- One direction works, the other doesn't.
- `ping` from A to B works, but not B to A.
- TCP connections hang after SYN-ACK (firewall drops the asymmetric return).
- Works with RPF disabled but fails when enabled.

### Diagnosis

```bash
# Check RPF setting
sysctl net.ipv4.conf.all.rp_filter
sysctl net.ipv4.conf.wg0.rp_filter
# 0 = disabled, 1 = strict, 2 = loose

# Check routing tables
ip route show
ip route show table all | grep wg0
ip rule show

# Trace the path
traceroute -U -p 51820 <endpoint>
mtr <remote_wg_ip>
```

### Fixes

**1. Set loose RPF on WireGuard interfaces**

```bash
# Loose mode (recommended for WireGuard)
sysctl -w net.ipv4.conf.wg0.rp_filter=2
sysctl -w net.ipv4.conf.all.rp_filter=2

# Persist
echo "net.ipv4.conf.wg0.rp_filter=2" >> /etc/sysctl.d/99-wireguard.conf
echo "net.ipv4.conf.all.rp_filter=2" >> /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf
```

**2. Use FwMark to prevent routing loops**

```ini
[Interface]
FwMark = 51820
Table = 51820
PostUp = ip rule add not fwmark 51820 table 51820
PostUp = ip rule add table main suppress_prefixlength 0
PostDown = ip rule del not fwmark 51820 table 51820
PostDown = ip rule del table main suppress_prefixlength 0
```

**3. Source-based routing**

When the server has multiple interfaces:

```bash
# Ensure responses go back out the same interface they came in on
ip rule add from 10.0.0.0/24 table 100
ip route add default dev wg0 table 100
```

---

## AllowedIPs Conflicts

AllowedIPs serves dual purpose in WireGuard: it's both an ACL (incoming filter)
and a routing table (outgoing). Conflicts cause traffic to route to the wrong peer
or be dropped.

### Symptoms

- Traffic destined for one peer arrives at a different peer.
- Some subnets are unreachable while others work.
- Adding a new peer breaks connectivity to an existing one.
- `wg show` reports transfer on the wrong peer.

### Diagnosis

```bash
# List all peers and their AllowedIPs
wg show wg0 allowed-ips

# Check for overlapping ranges
wg show wg0 allowed-ips | awk '{print $2}' | sort

# Check which peer owns a specific route
ip route get 10.0.1.5
ip route show table all | grep wg0
```

### Rules

1. **No overlapping AllowedIPs** across peers on the same interface.
2. **Most specific match wins** — if peer A has `10.0.0.0/24` and peer B has
   `10.0.0.5/32`, traffic to 10.0.0.5 goes to peer B.
3. **Server AllowedIPs = client's VPN IP** (use /32 for individual clients).
4. **Client AllowedIPs = what to route through VPN** (0.0.0.0/0 for full tunnel).
5. **Each IP can appear in at most one peer's AllowedIPs**.

### Fixes

**1. Audit AllowedIPs for overlaps**

```bash
# Script to detect overlapping AllowedIPs
wg show wg0 dump | tail -n +2 | while IFS=$'\t' read -r pubkey _ _ allowed _ _ _; do
    echo "$pubkey: $allowed"
done | sort -t: -k2
```

**2. Use /32 for point-to-point peers**

```ini
# Correct: each client gets exactly one IP
[Peer]
PublicKey = <client1>
AllowedIPs = 10.0.0.2/32

[Peer]
PublicKey = <client2>
AllowedIPs = 10.0.0.3/32
```

**3. Use subnets only for site-to-site**

```ini
# Site A routes its entire subnet through peer
[Peer]
PublicKey = <site_a>
AllowedIPs = 10.1.0.0/24  # Site A's LAN
```

---

## Kernel Module Loading Issues

### Symptoms

- `wg-quick up wg0` fails with "RTNETLINK answers: Operation not supported".
- `ip link add wg0 type wireguard` fails.
- `lsmod | grep wireguard` shows no output.
- `modprobe wireguard` fails with "Module not found".

### Diagnosis

```bash
# Check if module is loaded
lsmod | grep wireguard

# Try loading it
modprobe wireguard
# If this fails, check:

# Kernel version (need ≥5.6 for built-in)
uname -r

# Check if module exists
find /lib/modules/$(uname -r) -name 'wireguard*'
modinfo wireguard

# Check dmesg for loading errors
dmesg | tail -20

# Check Secure Boot (may block unsigned modules)
mokutil --sb-state
```

### Fixes

**1. Install WireGuard for your distribution**

```bash
# Ubuntu/Debian
apt update && apt install wireguard wireguard-tools

# Fedora
dnf install wireguard-tools

# CentOS/RHEL 8+
dnf install epel-release elrepo-release
dnf install kmod-wireguard wireguard-tools

# Arch
pacman -S wireguard-tools

# Alpine
apk add wireguard-tools
```

**2. DKMS for older kernels**

```bash
# Ubuntu/Debian with kernel < 5.6
apt install wireguard-dkms wireguard-tools

# Verify DKMS built the module
dkms status | grep wireguard
```

**3. Secure Boot workaround**

If Secure Boot blocks the unsigned WireGuard module:

```bash
# Option 1: Sign the module
# Option 2: Use userspace implementation
apt install wireguard-go  # or boringtun
WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go wg-quick up wg0
```

**4. Container environments**

Containers typically cannot load kernel modules. Options:
- Load `wireguard` module on the host before starting the container.
- Use userspace implementation (wireguard-go, boringtun) inside the container.
- Grant `CAP_SYS_MODULE` (security risk).

```bash
# Load on host
modprobe wireguard

# Then the container can use the kernel module if it has CAP_NET_ADMIN
docker run --cap-add=NET_ADMIN ...
```

---

## systemd-resolved Integration Problems

### Symptoms

- DNS doesn't work after `wg-quick up` even though `DNS =` is set.
- `resolvectl status` doesn't show wg0.
- DNS works with `dig @<dns_server>` directly but not with normal resolution.
- `/etc/resolv.conf` points to 127.0.0.53 but queries fail.

### Diagnosis

```bash
# Check if systemd-resolved is running
systemctl status systemd-resolved

# Check resolv.conf symlink
ls -la /etc/resolv.conf
# Should be: /etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf

# Check per-interface DNS configuration
resolvectl status
resolvectl status wg0

# Check which DNS domains route through which interface
resolvectl domain

# Test DNS resolution through resolved
resolvectl query example.com

# Check if resolvconf is installed (wg-quick needs it or systemd-resolved)
which resolvconf
dpkg -l | grep resolvconf
```

### Fixes

**1. Install resolvconf compatibility**

wg-quick uses `resolvconf` to configure DNS. On systemd-resolved systems,
install the compatibility package:

```bash
# Ubuntu/Debian
apt install systemd-resolved  # Usually pre-installed
# If resolvconf command is missing:
ln -sf /usr/bin/resolvectl /usr/local/bin/resolvconf
# Or install the shim package:
apt install systemd-resolved  # provides resolvconf via alternatives
```

**2. Fix resolv.conf symlink**

```bash
# Ensure resolv.conf points to the stub resolver
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Restart resolved
systemctl restart systemd-resolved
```

**3. Manual DNS configuration with PostUp**

If automatic DNS config fails, configure it manually:

```ini
PostUp = resolvectl dns %i 10.0.0.1
PostUp = resolvectl domain %i "~."
PostDown = resolvectl revert %i
```

**4. Split DNS (only route specific domains through VPN)**

```ini
# Only route *.internal.company.com through VPN DNS
PostUp = resolvectl dns %i 10.0.0.1
PostUp = resolvectl domain %i "~internal.company.com"
PostDown = resolvectl revert %i
```

**5. NetworkManager conflicts**

NetworkManager can override DNS settings. Prevent this:

```bash
# /etc/NetworkManager/conf.d/dns.conf
[main]
dns=systemd-resolved

# Restart
systemctl restart NetworkManager
```

---

## Performance Debugging

### Symptoms

- Throughput is significantly lower than expected.
- High CPU usage during transfers.
- Latency spikes under load.
- Performance degrades over time.

### Diagnosis

```bash
# Baseline: test without WireGuard
iperf3 -s  # On server
iperf3 -c <server_ip>  # On client

# Test through WireGuard
iperf3 -c <server_wg_ip>

# Compare the results — expect ~5-10% overhead with kernel module

# Check CPU usage during transfer
top -d 1  # Look for ksoftirqd, wireguard processes

# Check for packet loss
wg show wg0  # Compare rx/tx bytes
ping -c 100 -i 0.1 <remote_wg_ip>

# Check interface errors and drops
ip -s link show wg0
cat /proc/net/dev | grep wg0

# Check buffer sizes
sysctl net.core.rmem_max
sysctl net.core.wmem_max

# Check if running kernel or userspace
# Kernel: no wireguard process visible, handled in ksoftirqd
# Userspace: wireguard-go or boringtun process visible
ps aux | grep -E 'wireguard-go|boringtun'
```

### Fixes

**1. Ensure kernel module (not userspace)**

```bash
# Check implementation
lsmod | grep wireguard  # If loaded = kernel module

# If using userspace inadvertently, switch to kernel
modprobe wireguard
wg-quick down wg0
unset WG_QUICK_USERSPACE_IMPLEMENTATION
wg-quick up wg0
```

**2. Optimize kernel buffer sizes**

```bash
# /etc/sysctl.d/99-wireguard-perf.conf
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.core.netdev_max_backlog = 5000
net.core.optmem_max = 65536

# Apply
sysctl -p /etc/sysctl.d/99-wireguard-perf.conf
```

**3. CPU affinity for multi-core systems**

WireGuard kernel module processes packets in softirq context. On multi-queue NICs,
distribute interrupt handling across cores:

```bash
# Check current IRQ affinity
cat /proc/interrupts | grep eth0
# Spread IRQs across cores
echo 1 > /proc/irq/<irq_num>/smp_affinity
echo 2 > /proc/irq/<irq_num>/smp_affinity
```

**4. Disable offloading if causing issues**

```bash
# Some NIC offload features can conflict with WireGuard
ethtool -K eth0 gro off gso off tso off

# Test performance after disabling
iperf3 -c <server_wg_ip>
```

**5. MTU optimization**

Wrong MTU causes fragmentation, which kills performance:

```bash
# Find optimal MTU
for mtu in 1420 1400 1380 1360 1340; do
    echo -n "MTU $mtu: "
    ping -M do -s $((mtu - 28)) -c 3 -q <remote_wg_ip> 2>&1 | grep -oP '\d+% packet loss'
done
```

**6. Check for throttling**

Some ISPs throttle UDP or specific ports:

```bash
# Test with different ports
# On server: change ListenPort to 443
# If performance improves, ISP is throttling port 51820
```

---

## Quick Diagnostic Checklist

Run through this checklist when WireGuard isn't working:

```bash
#!/bin/bash
# WireGuard diagnostic checklist
echo "=== WireGuard Diagnostics ==="

echo -e "\n--- Kernel Module ---"
lsmod | grep wireguard || echo "WARNING: wireguard module not loaded"

echo -e "\n--- Interface Status ---"
ip link show wg0 2>/dev/null || echo "WARNING: wg0 interface does not exist"

echo -e "\n--- WireGuard Status ---"
wg show wg0 2>/dev/null || echo "WARNING: cannot show wg0 status"

echo -e "\n--- IP Addresses ---"
ip addr show wg0 2>/dev/null

echo -e "\n--- Routing ---"
ip route show | grep wg0
ip rule show 2>/dev/null | grep -v "^0:" | head -10

echo -e "\n--- IP Forwarding ---"
echo "IPv4 forwarding: $(sysctl -n net.ipv4.ip_forward)"
echo "IPv6 forwarding: $(sysctl -n net.ipv6.conf.all.forwarding)"

echo -e "\n--- DNS ---"
resolvectl status wg0 2>/dev/null || echo "No DNS configured for wg0"

echo -e "\n--- Firewall (UDP 51820) ---"
iptables -L INPUT -n 2>/dev/null | grep 51820 || echo "No iptables rule for 51820"
nft list ruleset 2>/dev/null | grep 51820 || echo "No nftables rule for 51820"

echo -e "\n--- Listening Ports ---"
ss -ulnp | grep 51820 || echo "Nothing listening on UDP 51820"

echo -e "\n--- Recent Kernel Messages ---"
dmesg | grep -i wireguard | tail -5

echo -e "\n--- Config File ---"
ls -la /etc/wireguard/wg0.conf 2>/dev/null || echo "No config file found"
```

Save this as a diagnostic script and run it first when troubleshooting any
WireGuard issue. It covers the most common failure points in seconds.
