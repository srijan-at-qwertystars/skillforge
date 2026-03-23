---
name: iptables-networking
description: |
  Use when user configures Linux firewalls, asks about iptables rules, nftables, chains, NAT, port forwarding, network namespaces, traffic shaping, or Linux network debugging.
  Do NOT use for cloud security groups (AWS/GCP), Kubernetes network policies (use kubernetes-troubleshooting skill), or application-level firewalls (WAF).
---

# Linux Firewall & Network Configuration

## iptables Fundamentals

### Tables
- **filter** — default table. Controls packet acceptance (INPUT, FORWARD, OUTPUT chains).
- **nat** — network address translation (PREROUTING, POSTROUTING, OUTPUT chains).
- **mangle** — packet header modification (all five chains).
- **raw** — exempts packets from connection tracking (PREROUTING, OUTPUT).

### Chains
- **INPUT** — packets destined for the local host.
- **OUTPUT** — packets originating from the local host.
- **FORWARD** — packets routed through the host.
- **PREROUTING** — packets before routing decision (nat/mangle/raw).
- **POSTROUTING** — packets after routing decision (nat/mangle).

### Targets
- `ACCEPT` — allow packet.
- `DROP` — silently discard.
- `REJECT` — discard and send ICMP error.
- `LOG` — log to syslog, continue processing.
- `RETURN` — return to calling chain.
- `SNAT/DNAT/MASQUERADE` — NAT targets (nat table only).

## iptables Rule Syntax

```bash
# Append rule to INPUT chain
iptables -A INPUT -p tcp --dport 22 -s 10.0.0.0/8 -j ACCEPT

# Insert at position 1
iptables -I INPUT 1 -p icmp -j ACCEPT

# Delete by specification
iptables -D INPUT -p tcp --dport 8080 -j DROP

# Delete by line number
iptables -D INPUT 3
```

Key flags: `-A`/`-I`/`-D` (append/insert/delete), `-p` (protocol), `-s`/`-d` (source/dest IP), `--dport`/`--sport` (port), `-j` (target), `-i`/`-o` (interface), `-m` (match module: conntrack, limit, multiport).

### Connection tracking
```bash
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT  # place FIRST
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
```

## Common Rules

```bash
# Set default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow SSH from specific subnet
iptables -A INPUT -p tcp --dport 22 -s 10.0.0.0/8 -j ACCEPT

# Allow HTTP/HTTPS
iptables -A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT

# Block specific IP
iptables -A INPUT -s 203.0.113.45 -j DROP

# Rate limit SSH connections (max 3 new per minute)
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
  -m limit --limit 3/min --limit-burst 3 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j DROP

# Log dropped packets (place before final DROP)
iptables -A INPUT -j LOG --log-prefix "IPT-DROP: " --log-level 4
iptables -A INPUT -j DROP
```

## NAT Configuration

### SNAT — rewrite source address for outbound traffic
```bash
iptables -t nat -A POSTROUTING -o eth0 -s 10.0.0.0/24 -j SNAT --to-source 203.0.113.1
```

### MASQUERADE — SNAT with dynamic external IP
```bash
iptables -t nat -A POSTROUTING -o eth0 -s 10.0.0.0/24 -j MASQUERADE
```

### DNAT — port forwarding to internal host
```bash
# Forward external port 8080 to internal 10.0.0.5:80
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 10.0.0.5:80
iptables -A FORWARD -p tcp -d 10.0.0.5 --dport 80 -j ACCEPT
```

### Hairpin NAT — internal hosts reach DNAT via external IP
```bash
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -d 10.0.0.5 -p tcp --dport 80 -j MASQUERADE
```

Enable forwarding: `sysctl -w net.ipv4.ip_forward=1` (persist in `/etc/sysctl.d/99-forward.conf`).

## nftables

nftables replaces iptables with unified syntax, atomic rule updates, and native sets/maps.

### Core concepts
- **Tables** — containers with a family (inet, ip, ip6, arp, bridge, netdev).
- **Chains** — attached to netfilter hooks with type, hook, and priority.
- **Sets** — efficient O(1) lookups for IPs, ports, or intervals.
- **Maps** — key-value verdict or data mappings.

### Basic nftables configuration
```bash
# Create table and chain
nft add table inet filter
nft add chain inet filter input { type filter hook input priority 0\; policy drop\; }
nft add chain inet filter forward { type filter hook forward priority 0\; policy drop\; }
nft add chain inet filter output { type filter hook output priority 0\; policy accept\; }

# Allow established/related
nft add rule inet filter input ct state established,related accept

# Allow loopback
nft add rule inet filter input iif lo accept

# Allow SSH, HTTP, HTTPS
nft add rule inet filter input tcp dport { 22, 80, 443 } accept
```

### Named sets
```bash
nft add set inet filter blocked_ips { type ipv4_addr\; flags interval\; }
nft add element inet filter blocked_ips { 203.0.113.0/24, 198.51.100.0/24 }
nft add rule inet filter input ip saddr @blocked_ips drop
```

### Sets with timeout (auto-expiring entries)
```bash
nft add set inet filter temp_ban { type ipv4_addr\; flags timeout\; timeout 1h\; }
nft add element inet filter temp_ban { 192.0.2.50 timeout 30m }
```

### Verdict maps
```bash
nft add map inet filter port_policy { type inet_service : verdict\; }
nft add element inet filter port_policy { 22 : accept, 3306 : drop, 80 : accept }
nft add rule inet filter input tcp dport vmap @port_policy
```

### Named counters
```bash
nft add counter inet filter cnt_ssh
nft add rule inet filter input tcp dport 22 counter name cnt_ssh accept
# View: nft list counter inet filter cnt_ssh
```

### Rate limiting
```bash
# Global limit
nft add rule inet filter input tcp dport 22 ct state new limit rate 10/minute accept

# Per-source-IP limit using meter
nft add rule inet filter input tcp dport 22 ct state new \
  meter ssh_limit { ip saddr limit rate 3/minute } accept
```

### nftables NAT
```bash
nft add table inet nat
nft add chain inet nat prerouting { type nat hook prerouting priority -100\; }
nft add chain inet nat postrouting { type nat hook postrouting priority 100\; }

# Masquerade
nft add rule inet nat postrouting oifname "eth0" masquerade

# DNAT port forward
nft add rule inet nat prerouting tcp dport 8080 dnat to 10.0.0.5:80
```

### Migration from iptables
```bash
# Translate single rule
iptables-translate -A INPUT -p tcp --dport 22 -j ACCEPT
# Output: nft add rule ip filter INPUT tcp dport 22 counter accept

# Bulk translate
iptables-save > legacy.rules
iptables-restore-translate -f legacy.rules > ruleset.nft
# Review ruleset.nft, refactor to use sets/maps, then load:
nft -f ruleset.nft
```

## Firewalld

Firewalld manages iptables/nftables via zones and services. Default backend is nftables on modern distros.

### Zones
```bash
# List zones and active assignments
firewall-cmd --get-zones
firewall-cmd --get-active-zones

# Assign interface to zone
firewall-cmd --zone=internal --change-interface=eth1 --permanent

# Set default zone
firewall-cmd --set-default-zone=public
```

### Services
```bash
# Add/remove service
firewall-cmd --zone=public --add-service=https --permanent
firewall-cmd --zone=public --remove-service=ssh --permanent

# Add custom port
firewall-cmd --zone=public --add-port=8443/tcp --permanent

# Apply changes
firewall-cmd --reload
```

### Rich rules
```bash
# Allow SSH from specific subnet only
firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" service name="ssh" accept' --permanent

# Rate-limited logging
firewall-cmd --zone=public --add-rich-rule='rule service name="ssh" log prefix="SSH: " level="warning" limit value="3/m" accept' --permanent

# Drop all other SSH
firewall-cmd --zone=public --add-rich-rule='rule service name="ssh" drop' --permanent
```

### Runtime vs permanent
- Omit `--permanent` for runtime-only (lost on reload/reboot).
- Add `--permanent` then `--reload` for persistent changes.
- `firewall-cmd --runtime-to-permanent` saves current runtime config.

### Inspect configuration
```bash
firewall-cmd --zone=public --list-all
# public (active)
#   interfaces: eth0
#   services: dhcpv6-client https
#   ports: 8443/tcp
#   rich rules:
#     rule family="ipv4" source address="10.0.0.0/8" service name="ssh" accept
```

## Network Namespaces

Network namespaces provide isolated network stacks — the foundation of container networking.

### Create and manage namespaces
```bash
# Create namespace
ip netns add ns1

# List namespaces
ip netns list

# Execute command in namespace
ip netns exec ns1 ip addr show

# Delete namespace
ip netns delete ns1
```

### Connect namespaces with veth pairs
```bash
# Create veth pair
ip link add veth0 type veth peer name veth1

# Move veth1 into namespace
ip link set veth1 netns ns1

# Configure addresses
ip addr add 10.0.0.1/24 dev veth0
ip link set veth0 up

ip netns exec ns1 ip addr add 10.0.0.2/24 dev veth1
ip netns exec ns1 ip link set veth1 up
ip netns exec ns1 ip link set lo up

# Test connectivity
ip netns exec ns1 ping -c 1 10.0.0.1
```

### Bridge multiple namespaces
```bash
# Create bridge
ip link add br0 type bridge
ip link set br0 up
ip addr add 10.0.0.1/24 dev br0

# For each namespace: create veth, attach one end to bridge
ip link add veth-ns1 type veth peer name eth0-ns1
ip link set eth0-ns1 netns ns1
ip link set veth-ns1 master br0
ip link set veth-ns1 up
ip netns exec ns1 ip addr add 10.0.0.2/24 dev eth0-ns1
ip netns exec ns1 ip link set eth0-ns1 up
```

### Internet access from namespace
```bash
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
ip netns exec ns1 ip route add default via 10.0.0.1
```

## ip Command Reference

```bash
ip addr show                              # list addresses
ip addr add 192.168.1.10/24 dev eth0      # add address
ip addr del 192.168.1.10/24 dev eth0      # remove address
ip route show                             # show routing table
ip route add 172.16.0.0/12 via 10.0.0.1   # static route
ip link show                              # link state
ip link set eth0 up                       # bring up interface
ip link set eth0 mtu 9000                 # set MTU
ip neighbor show                          # ARP table

# Policy routing — route by source IP
ip rule add from 10.0.1.0/24 table 100
ip route add default via 10.0.1.1 table 100
```

## Traffic Control (tc)

### Simple bandwidth limit with TBF
```bash
tc qdisc add dev eth0 root tbf rate 10mbit burst 32kbit latency 400ms

# Verify
tc qdisc show dev eth0
# qdisc tbf 8001: root refcnt 2 rate 10Mbit burst 4Kb lat 400ms

# Remove
tc qdisc del dev eth0 root
```

### Hierarchical Token Bucket (HTB) — class-based shaping
```bash
# Root qdisc
tc qdisc add dev eth0 root handle 1: htb default 30

# Parent class: 100mbit total
tc class add dev eth0 parent 1: classid 1:1 htb rate 100mbit ceil 100mbit

# Child class: 10mbit for web traffic
tc class add dev eth0 parent 1:1 classid 1:10 htb rate 10mbit ceil 50mbit

# Filter: send port 80 traffic to class 1:10
tc filter add dev eth0 protocol ip parent 1: prio 1 u32 \
  match ip dport 80 0xffff flowid 1:10
```

### Latency simulation with netem
```bash
tc qdisc add dev eth0 root netem delay 100ms 10ms            # delay + jitter
tc qdisc add dev eth0 root netem delay 50ms loss 0.5%         # delay + packet loss
```

## Packet Flow and Processing Order

### iptables packet traversal
```
INCOMING PACKET
  → raw/PREROUTING → conntrack → mangle/PREROUTING → nat/PREROUTING (DNAT)
  → ROUTING DECISION
    ├─ Local destination: mangle/INPUT → filter/INPUT → Local Process
    └─ Forward: mangle/FORWARD → filter/FORWARD
                → mangle/POSTROUTING → nat/POSTROUTING (SNAT/MASQUERADE) → OUT

LOCAL PROCESS → raw/OUTPUT → conntrack → mangle/OUTPUT → nat/OUTPUT
  → filter/OUTPUT → mangle/POSTROUTING → nat/POSTROUTING → OUT
```

### nftables hook priorities (lower = earlier)
`-300` raw → `-150` mangle → `-100` dnat → `0` filter → `100` snat → `300` postroute mangle

### Conntrack states
- **NEW** — first packet. **ESTABLISHED** — tracked connection. **RELATED** — related new connection (FTP data, ICMP error). **INVALID** — no matching connection.

```bash
conntrack -L            # view connections
conntrack -L -p tcp --dport 22  # filter by port
conntrack -E            # real-time events
conntrack -C            # count entries
conntrack -F            # flush table
```

## Persistence

### iptables persistence
```bash
iptables-save > /etc/iptables/rules.v4       # save
iptables-restore < /etc/iptables/rules.v4    # restore
# Debian/Ubuntu: apt install iptables-persistent (auto-loads rules.v4/v6 on boot)
```

### nftables persistence
```bash
nft list ruleset > /etc/nftables.conf         # save
systemctl enable nftables                     # loads /etc/nftables.conf on boot
nft -f /etc/nftables.conf                     # manual load
```

### Firewalld persistence
Use `--permanent` flag on all commands, then `firewall-cmd --reload`.

## Debugging

```bash
# List rules with counters (numeric, line numbers)
iptables -L -v -n --line-numbers
iptables -t nat -L -v -n
```

### LOG and TRACE
```bash
# LOG: add before DROP to see what's being filtered
iptables -I INPUT 1 -p tcp --dport 443 -j LOG --log-prefix "DBG-443: "
# View: journalctl -k --grep="DBG-443"

# TRACE: full packet path through all tables/chains
modprobe nf_log_ipv4
iptables -t raw -A PREROUTING -p tcp --dport 80 -j TRACE
# View: dmesg | grep TRACE
# Remove when done:
iptables -t raw -D PREROUTING -p tcp --dport 80 -j TRACE
```

### nftables debugging
```bash
nft list ruleset -a     # -a shows rule handles for deletion
nft monitor             # real-time rule/event monitoring
```

### tcpdump
```bash
tcpdump -i eth0 -nn port 80                    # capture by port
ip netns exec ns1 tcpdump -i eth0-ns1 -nn      # capture in namespace
tcpdump -i eth0 -w /tmp/capture.pcap -c 1000   # write pcap for Wireshark
```

## Anti-Patterns

### Flushing without setting default policy first
```bash
# WRONG — flush removes ESTABLISHED rule, default DROP locks you out
iptables -F && iptables -P INPUT DROP

# CORRECT — keep ACCEPT during rebuild
iptables -P INPUT ACCEPT && iptables -F
# ... add rules ...
iptables -P INPUT DROP
```

### Missing conntrack rule
Place `ESTABLISHED,RELATED` accept rule at the top of INPUT. Without it, return traffic for allowed outbound connections is dropped, breaking all connectivity.

### Order-dependent rules ignored
```bash
# WRONG — DROP before specific ACCEPT; SSH never reaches the ACCEPT rule
iptables -A INPUT -p tcp -j DROP
iptables -A INPUT -p tcp --dport 22 -j ACCEPT  # never reached

# CORRECT — specific rules before generic catch-all
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp -j DROP
```

### Mixing iptables-legacy and nftables
Do not mix backends. Check with `iptables -V`: `(nf_tables)` = nft backend, `(legacy)` = legacy. Use one or the other.

### Not persisting rules
Rules are in-memory only. A reboot wipes everything unless saved. See Persistence section.

### Overly broad ACCEPT rules
Avoid `-j ACCEPT` without protocol/port constraints. Specify protocol, port, source, and interface.
