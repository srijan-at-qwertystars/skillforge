# Advanced Linux Networking Patterns

> Deep-dive reference for advanced Linux networking constructs: namespaces, virtual
> devices, tunneling, traffic control, eBPF/XDP, nftables advanced features, policy
> routing, and network bonding.

## Table of Contents

- [Network Namespaces Deep Dive](#network-namespaces-deep-dive)
- [Veth Pairs](#veth-pairs)
- [Linux Bridges — Advanced Usage](#linux-bridges--advanced-usage)
- [Macvlan and Ipvlan](#macvlan-and-ipvlan)
- [Traffic Control (tc) — Bandwidth Shaping](#traffic-control-tc--bandwidth-shaping)
- [eBPF and XDP for Packet Processing](#ebpf-and-xdp-for-packet-processing)
- [Nftables Advanced: Sets, Maps, Flowtables](#nftables-advanced-sets-maps-flowtables)
- [Policy Routing with Multiple Tables](#policy-routing-with-multiple-tables)
- [GRE and VXLAN Tunnels](#gre-and-vxlan-tunnels)
- [Multipath Routing (ECMP)](#multipath-routing-ecmp)
- [Network Bonding Modes](#network-bonding-modes)

---

## Network Namespaces Deep Dive

Network namespaces provide complete isolation of the network stack — each namespace
gets its own interfaces, routing tables, firewall rules, and `/proc/net`. This is the
foundation of container networking.

### Lifecycle management

```bash
# Create and list
ip netns add blue
ip netns add red
ip netns list

# Execute commands inside a namespace
ip netns exec blue ip link show          # only loopback exists initially
ip netns exec blue ip link set lo up     # bring loopback up (important!)

# Persistent namespaces survive reboot via systemd unit or /etc/netns/<name>/
mkdir -p /etc/netns/blue
echo "nameserver 8.8.8.8" > /etc/netns/blue/resolv.conf   # per-ns DNS

# Delete
ip netns del blue
```

### Namespace-aware processes

```bash
# Run a shell inside a namespace
ip netns exec red bash

# Move a running process into a namespace (requires nsenter)
nsenter --net=/var/run/netns/red -- ip addr show

# Inspect which namespace a process uses
ls -la /proc/<PID>/ns/net
readlink /proc/<PID>/ns/net              # inode identifies the namespace
```

### Connecting namespaces to the host network

```bash
# Create namespace with internet access via NAT
ip netns add app
ip link add veth-host type veth peer name veth-app
ip link set veth-app netns app

ip addr add 10.200.0.1/24 dev veth-host
ip link set veth-host up

ip netns exec app ip addr add 10.200.0.2/24 dev veth-app
ip netns exec app ip link set veth-app up
ip netns exec app ip link set lo up
ip netns exec app ip route add default via 10.200.0.1

# Enable forwarding and NAT on host
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 10.200.0.0/24 -o eth0 -j MASQUERADE
iptables -A FORWARD -i veth-host -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o veth-host -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Test from namespace
ip netns exec app ping -c 2 8.8.8.8
```

---

## Veth Pairs

Virtual Ethernet (veth) pairs act as a virtual patch cable — packets sent to one end
appear at the other. Each end can reside in a different namespace.

### Advanced veth topologies

```bash
# Star topology: multiple namespaces connected through a bridge
ip netns add ns1
ip netns add ns2
ip netns add ns3

ip link add name br0 type bridge
ip link set br0 up

for i in 1 2 3; do
  ip link add veth-br-ns${i} type veth peer name veth-ns${i}
  ip link set veth-ns${i} netns ns${i}
  ip link set veth-br-ns${i} master br0
  ip link set veth-br-ns${i} up
  ip netns exec ns${i} ip addr add 10.0.0.${i}/24 dev veth-ns${i}
  ip netns exec ns${i} ip link set veth-ns${i} up
  ip netns exec ns${i} ip link set lo up
done

# All three namespaces can now communicate at L2 via the bridge
ip netns exec ns1 ping -c 1 10.0.0.2
ip netns exec ns2 ping -c 1 10.0.0.3
```

### Veth performance tuning

```bash
# Increase TX queue length for high-throughput scenarios
ip link set veth-host txqueuelen 10000

# Enable GRO/GSO offloads (if supported)
ethtool -K veth-host gro on gso on

# Monitor veth statistics
ip -s link show veth-host
ethtool -S veth-host 2>/dev/null
```

---

## Linux Bridges — Advanced Usage

### Spanning Tree Protocol (STP)

```bash
# Enable STP on bridge
ip link set br0 type bridge stp_state 1

# View STP status
bridge link show
cat /sys/class/net/br0/bridge/stp_state

# Configure bridge priority (lower = more likely root)
echo 4096 > /sys/class/net/br0/bridge/priority

# Set port cost
echo 100 > /sys/class/net/br0/brif/eth0/path_cost
```

### Bridge with VLAN filtering

```bash
# Enable VLAN filtering on bridge
ip link set br0 type bridge vlan_filtering 1

# Assign VLANs to bridge ports
bridge vlan add dev eth0 vid 10
bridge vlan add dev eth1 vid 20
bridge vlan add dev br0 vid 10 self    # bridge participates in VLAN 10

# Show VLAN configuration
bridge vlan show

# PVID (native VLAN) — untagged frames get this VLAN ID
bridge vlan add dev eth0 vid 10 pvid untagged
```

### Forwarding database (FDB)

```bash
bridge fdb show dev br0                  # learned MAC addresses
bridge fdb add 00:11:22:33:44:55 dev eth0 master br0   # static entry
bridge fdb del 00:11:22:33:44:55 dev eth0 master br0
```

---

## Macvlan and Ipvlan

Both create virtual interfaces on top of a physical interface, but differ in
MAC address handling and L2/L3 behavior.

### Macvlan modes

```bash
# Bridge mode — sub-interfaces can communicate with each other and external
ip link add macvlan0 link eth0 type macvlan mode bridge
ip addr add 192.168.1.50/24 dev macvlan0
ip link set macvlan0 up

# Private mode — sub-interfaces isolated from each other, only external traffic
ip link add macvlan1 link eth0 type macvlan mode private

# VEPA mode — all traffic goes through external switch (requires hairpin)
ip link add macvlan2 link eth0 type macvlan mode vepa

# Passthrough — single sub-interface takes over the parent's MAC
ip link add macvlan3 link eth0 type macvlan mode passthru
```

**Key limitation**: macvlan sub-interfaces cannot communicate with the parent
interface (eth0) directly. Use bridge mode or a separate route.

### Ipvlan modes

```bash
# L2 mode — operates at data link layer, shares parent MAC
ip link add ipvlan0 link eth0 type ipvlan mode l2
ip addr add 192.168.1.60/24 dev ipvlan0
ip link set ipvlan0 up

# L3 mode — operates at network layer, routing-based (no ARP on sub-iface)
ip link add ipvlan1 link eth0 type ipvlan mode l3

# L3S mode — L3 with source address validation (iptables/nftables aware)
ip link add ipvlan2 link eth0 type ipvlan mode l3s
```

### When to use which

| Feature        | Macvlan                     | Ipvlan                       |
|----------------|-----------------------------|------------------------------|
| MAC addresses  | Unique per sub-iface        | Shared with parent           |
| Switch compat  | May hit MAC limits          | No MAC concerns              |
| L2 isolation   | Mode-dependent              | L3 mode = full isolation     |
| Performance    | Good                        | Slightly better (fewer MACs) |
| Container use  | Docker macvlan driver       | Docker ipvlan driver         |
| DHCP           | Works (unique MACs)         | Requires static or L2 mode   |

---

## Traffic Control (tc) — Bandwidth Shaping

The `tc` subsystem controls how packets are queued, shaped, and prioritized.

### HTB (Hierarchical Token Bucket)

```bash
# Root qdisc
tc qdisc add dev eth0 root handle 1: htb default 30

# Parent class — total bandwidth cap
tc class add dev eth0 parent 1: classid 1:1 htb rate 1gbit burst 15k

# Child classes — bandwidth allocation
tc class add dev eth0 parent 1:1 classid 1:10 htb rate 500mbit ceil 800mbit burst 15k  # high-prio
tc class add dev eth0 parent 1:1 classid 1:20 htb rate 300mbit ceil 500mbit burst 15k  # medium
tc class add dev eth0 parent 1:1 classid 1:30 htb rate 200mbit ceil 300mbit burst 15k  # default/low

# Add SFQ leaf qdiscs for fairness within each class
tc qdisc add dev eth0 parent 1:10 handle 10: sfq perturb 10
tc qdisc add dev eth0 parent 1:20 handle 20: sfq perturb 10
tc qdisc add dev eth0 parent 1:30 handle 30: sfq perturb 10

# Classify traffic using filters
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
  match ip dport 22 0xffff flowid 1:10                    # SSH → high-prio
tc filter add dev eth0 parent 1: protocol ip prio 2 u32 \
  match ip dport 80 0xffff flowid 1:20                    # HTTP → medium
# All other traffic → default class 1:30
```

### Ingress policing (rate-limit incoming)

```bash
# Add ingress qdisc
tc qdisc add dev eth0 handle ffff: ingress

# Police incoming traffic to 100mbit
tc filter add dev eth0 parent ffff: protocol ip prio 1 u32 \
  match ip src 0.0.0.0/0 police rate 100mbit burst 100k drop flowid :1
```

### Simulating network conditions (netem)

```bash
# Add 100ms latency with 10ms jitter
tc qdisc add dev eth0 root netem delay 100ms 10ms

# Add 1% packet loss
tc qdisc change dev eth0 root netem loss 1%

# Add latency + loss + reordering
tc qdisc change dev eth0 root netem delay 50ms 20ms loss 0.5% reorder 25% 50%

# Rate limit to 10mbit
tc qdisc change dev eth0 root netem rate 10mbit

# Remove all tc rules
tc qdisc del dev eth0 root
```

### Monitoring tc

```bash
tc -s qdisc show dev eth0               # show with statistics
tc -s class show dev eth0               # class stats
tc filter show dev eth0                 # active filters
```

---

## eBPF and XDP for Packet Processing

eBPF (extended Berkeley Packet Filter) runs sandboxed programs in kernel space.
XDP (eXpress Data Path) is an eBPF hook at the earliest point in the NIC driver.

### XDP modes

| Mode       | Description                              | Performance  |
|------------|------------------------------------------|-------------|
| Native     | Driver-level, requires NIC support       | Best (~24Mpps) |
| Offload    | NIC hardware, rare support               | Highest     |
| Generic    | Software fallback, any NIC               | Moderate    |

### XDP actions

| Action       | Effect                                    |
|--------------|-------------------------------------------|
| XDP_PASS     | Continue normal processing                |
| XDP_DROP     | Drop packet (before sk_buff allocation)   |
| XDP_TX       | Bounce packet back out same NIC           |
| XDP_REDIRECT | Forward to another NIC or CPU             |
| XDP_ABORTED  | Error path, drop with trace event         |

### Simple XDP program (drop all)

```c
// drop_all.c — compile with clang -O2 -target bpf
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

SEC("xdp")
int xdp_drop(struct xdp_md *ctx) {
    return XDP_DROP;
}

char _license[] SEC("license") = "GPL";
```

### Loading and managing XDP programs

```bash
# Compile
clang -O2 -target bpf -c drop_all.c -o drop_all.o

# Load with ip
ip link set dev eth0 xdpgeneric obj drop_all.o sec xdp

# Detach
ip link set dev eth0 xdpgeneric off

# Using bpftool
bpftool prog load drop_all.o /sys/fs/bpf/xdp_drop
bpftool net attach xdpgeneric id <PROG_ID> dev eth0
bpftool prog show
bpftool map show
```

### eBPF use cases in networking

- **DDoS mitigation**: Drop malicious packets at XDP before they consume CPU
- **Load balancing**: Facebook's Katran, Cilium's kube-proxy replacement
- **Observability**: Packet-level metrics without tcpdump overhead
- **Custom firewalls**: Cloudflare's L4 DDoS protection
- **Connection tracking**: Replace conntrack with eBPF maps for scalability

---

## Nftables Advanced: Sets, Maps, Flowtables

### Named sets

```bash
# IP address set
nft add set inet filter blocked_ips { type ipv4_addr \; }
nft add element inet filter blocked_ips { 10.0.0.5, 10.0.0.6, 10.0.0.7 }
nft add rule inet filter input ip saddr @blocked_ips drop

# Port set
nft add set inet filter allowed_ports { type inet_service \; }
nft add element inet filter allowed_ports { 22, 80, 443 }
nft add rule inet filter input tcp dport @allowed_ports accept

# Set with timeout (auto-expire entries)
nft add set inet filter rate_limited { type ipv4_addr \; timeout 5m \; }

# Set with flags for dynamic updates from rules
nft add set inet filter dyn_blocked { type ipv4_addr \; flags dynamic, timeout \; timeout 1h \; }
nft add rule inet filter input tcp dport 22 ct state new \
  add @dyn_blocked { ip saddr limit rate over 5/minute } drop
```

### Maps (verdict maps and data maps)

```bash
# Verdict map — action based on port
nft add map inet filter port_policy { type inet_service : verdict \; }
nft add element inet filter port_policy { 22 : accept, 80 : accept, 443 : accept }
nft add rule inet filter input tcp dport vmap @port_policy

# Data map — DNAT based on port
nft add map ip nat dnat_targets { type inet_service : ipv4_addr \; }
nft add element ip nat dnat_targets { 8080 : 192.168.1.10, 8443 : 192.168.1.20 }
nft add rule ip nat prerouting dnat to tcp dport map @dnat_targets

# Concatenated sets/maps (match on multiple fields)
nft add set inet filter svc_access { type ipv4_addr . inet_service \; }
nft add element inet filter svc_access { 10.0.0.5 . 22 }
nft add rule inet filter input ip saddr . tcp dport @svc_access accept
```

### Flowtables (connection offload)

```bash
# Create flowtable for established connection fast-path
nft add flowtable inet filter ft {
  hook ingress priority 0 \;
  devices = { eth0, eth1 } \;
}

# Offload established connections
nft add rule inet filter forward ct state established flow add @ft
nft add rule inet filter forward ct state established,related accept

# Flowtables bypass nftables for offloaded flows → significant throughput gain
# Verify with conntrack
conntrack -L | grep OFFLOAD
```

### Meters (rate limiting without sets)

```bash
# Rate limit SSH per source IP
nft add rule inet filter input tcp dport 22 \
  meter ssh_meter { ip saddr limit rate 3/minute burst 5 packets } accept
nft add rule inet filter input tcp dport 22 drop
```

---

## Policy Routing with Multiple Tables

Policy routing lets you make routing decisions based on source address, fwmark,
incoming interface, TOS, or other packet attributes — not just destination.

### Multiple routing tables

```bash
# Name tables in /etc/iproute2/rt_tables
echo "100 isp1" >> /etc/iproute2/rt_tables
echo "200 isp2" >> /etc/iproute2/rt_tables

# Populate each table
ip route add default via 203.0.113.1 dev eth0 table isp1
ip route add 203.0.113.0/24 dev eth0 src 203.0.113.10 table isp1

ip route add default via 198.51.100.1 dev eth1 table isp2
ip route add 198.51.100.0/24 dev eth1 src 198.51.100.10 table isp2

# Rules: route based on source IP
ip rule add from 203.0.113.10 table isp1 priority 100
ip rule add from 198.51.100.10 table isp2 priority 200

# Verify
ip rule show
ip route show table isp1
ip route show table isp2
```

### Mark-based routing (with iptables/nftables)

```bash
# Mark packets from a specific application/user
iptables -t mangle -A OUTPUT -m owner --uid-owner 1001 -j MARK --set-mark 2

# Route marked packets via ISP2
ip rule add fwmark 2 table isp2

# With nftables
nft add rule inet mangle output meta skuid 1001 meta mark set 2
```

### Dual-WAN failover

```bash
#!/bin/bash
# Simple failover between two ISPs
PRIMARY_GW="203.0.113.1"
BACKUP_GW="198.51.100.1"
CHECK_IP="8.8.8.8"

while true; do
  if ! ping -c 2 -W 2 -I eth0 "$CHECK_IP" &>/dev/null; then
    ip route replace default via "$BACKUP_GW" dev eth1
    logger "Primary WAN down, switched to backup"
  else
    ip route replace default via "$PRIMARY_GW" dev eth0
  fi
  sleep 10
done
```

---

## GRE and VXLAN Tunnels

### GRE (Generic Routing Encapsulation)

```bash
# Point-to-point GRE tunnel (L3)
ip tunnel add gre1 mode gre remote 198.51.100.2 local 203.0.113.1 ttl 255
ip addr add 10.10.10.1/30 dev gre1
ip link set gre1 up
ip route add 172.16.0.0/16 via 10.10.10.2 dev gre1

# GRE tap (L2 tunnel — bridges ethernet frames)
ip link add gretap1 type gretap remote 198.51.100.2 local 203.0.113.1
ip link set gretap1 up

# GRE with key (multiple tunnels to same endpoint)
ip tunnel add gre2 mode gre remote 198.51.100.2 local 203.0.113.1 key 42

# Monitor
ip tunnel show
ip -s link show gre1
```

### VXLAN (Virtual Extensible LAN)

```bash
# Multicast-based VXLAN
ip link add vxlan10 type vxlan id 10 group 239.1.1.1 dev eth0 dstport 4789
ip addr add 10.100.0.1/24 dev vxlan10
ip link set vxlan10 up

# Unicast VXLAN (point-to-point, no multicast needed)
ip link add vxlan20 type vxlan id 20 remote 198.51.100.2 local 203.0.113.1 dstport 4789
ip addr add 10.200.0.1/24 dev vxlan20
ip link set vxlan20 up

# VXLAN with FDB (forwarding database) for known peers
ip link add vxlan30 type vxlan id 30 dev eth0 dstport 4789 nolearning
bridge fdb append 00:00:00:00:00:00 dev vxlan30 dst 198.51.100.2
bridge fdb append 00:00:00:00:00:00 dev vxlan30 dst 198.51.100.3

# VXLAN over bridge (multi-host overlay)
ip link add br-vxlan type bridge
ip link set vxlan10 master br-vxlan
ip link set br-vxlan up
```

### Tunnel MTU considerations

```bash
# GRE overhead: 24 bytes → effective MTU = 1476 (if outer is 1500)
# VXLAN overhead: 50 bytes → effective MTU = 1450
# Always set inner MTU to account for encapsulation
ip link set gre1 mtu 1476
ip link set vxlan10 mtu 1450

# Or enable PMTUD on the tunnel
ip tunnel change gre1 pmtudisc
```

---

## Multipath Routing (ECMP)

Equal-Cost MultiPath distributes flows across multiple next hops.

```bash
# ECMP with two next hops (equal weight)
ip route add default \
  nexthop via 10.0.0.1 dev eth0 weight 1 \
  nexthop via 10.0.0.2 dev eth1 weight 1

# Weighted ECMP (2:1 ratio)
ip route add 10.100.0.0/16 \
  nexthop via 10.0.0.1 dev eth0 weight 2 \
  nexthop via 10.0.0.2 dev eth1 weight 1

# Hash policy — controls how flows are distributed
sysctl net.ipv4.fib_multipath_hash_policy=1
# 0 = L3 (src/dst IP only, default)
# 1 = L4 (src/dst IP + port — better distribution)
# 2 = L3+inner (for tunneled traffic)

# Verify multipath routes
ip route show
ip route get 8.8.8.8                     # shows which nexthop was selected

# Monitor per-nexthop statistics
ip -s route show cache
```

---

## Network Bonding Modes

| Mode | Name            | Description                                    | Use Case                    |
|------|-----------------|------------------------------------------------|-----------------------------|
| 0    | balance-rr      | Round-robin across slaves                      | Increased throughput        |
| 1    | active-backup   | One active, others standby                     | Fault tolerance             |
| 2    | balance-xor     | XOR of src/dst MAC selects slave               | Load balancing              |
| 3    | broadcast       | Send on all slaves                             | Fault tolerance (special)   |
| 4    | 802.3ad (LACP)  | IEEE link aggregation, switch support required | Throughput + fault tolerance |
| 5    | balance-tlb     | Adaptive TX load balancing, no switch support  | TX throughput               |
| 6    | balance-alb     | Adaptive TX+RX load balancing                  | Throughput, no switch req   |

### LACP bond setup

```bash
# Load module
modprobe bonding

# Create bond
ip link add bond0 type bond mode 802.3ad miimon 100 lacp_rate fast \
  xmit_hash_policy layer3+4

# Add slaves
ip link set eth0 down
ip link set eth1 down
ip link set eth0 master bond0
ip link set eth1 master bond0
ip link set bond0 up
ip link set eth0 up
ip link set eth1 up

ip addr add 192.168.1.100/24 dev bond0

# Verify
cat /proc/net/bonding/bond0
# Look for: MII Status: up, Partner Mac Address (LACP), Aggregator ID
```

### Bond monitoring and failover tuning

```bash
# ARP monitoring (alternative to MII — validates L3 connectivity)
ip link add bond0 type bond mode active-backup \
  arp_interval 200 arp_ip_target 192.168.1.1,192.168.1.254

# Primary slave preference
ip link set bond0 type bond primary eth0

# Failover notification
# Monitor /proc/net/bonding/bond0 or use netlink events
ip monitor link | grep bond0
```

### NetworkManager bond creation

```bash
nmcli con add type bond ifname bond0 con-name bond0 \
  bond.options "mode=802.3ad,miimon=100,lacp_rate=fast,xmit_hash_policy=layer3+4"
nmcli con add type ethernet ifname eth0 master bond0
nmcli con add type ethernet ifname eth1 master bond0
nmcli con up bond0
```
