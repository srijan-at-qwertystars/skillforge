# Linux Network Troubleshooting Guide

> Systematic approach to diagnosing and resolving Linux network issues, from
> physical layer through application layer.

## Table of Contents

- [Systematic Approach — OSI Layer-by-Layer](#systematic-approach--osi-layer-by-layer)
- [Layer 1–2: Physical and Data Link](#layer-12-physical-and-data-link)
- [Layer 3: Network — IP and Routing](#layer-3-network--ip-and-routing)
- [ARP Issues](#arp-issues)
- [DNS Resolution Failures](#dns-resolution-failures)
- [MTU and Fragmentation Issues](#mtu-and-fragmentation-issues)
- [Packet Capture with tcpdump](#packet-capture-with-tcpdump)
- [Advanced Capture with tshark](#advanced-capture-with-tshark)
- [TCP Connection Debugging](#tcp-connection-debugging)
- [Firewall Rule Debugging](#firewall-rule-debugging)
- [Routing Table Conflicts](#routing-table-conflicts)
- [Network Performance Diagnosis](#network-performance-diagnosis)
- [Quick Diagnostic Checklists](#quick-diagnostic-checklists)

---

## Systematic Approach — OSI Layer-by-Layer

Always troubleshoot bottom-up. Each layer depends on the one below.

```
Layer 7 — Application     curl, wget, application logs
Layer 6 — Presentation    TLS/SSL (openssl s_client)
Layer 5 — Session         Connection state (ss, netstat)
Layer 4 — Transport       TCP/UDP (ss, tcpdump, nc)
Layer 3 — Network         IP routing (ip route, traceroute, ping)
Layer 2 — Data Link       ARP, MAC, switch (ip neigh, bridge, ethtool)
Layer 1 — Physical        Cable, NIC, link state (ethtool, dmesg)
```

**Golden rule**: Confirm each layer works before moving up. A DNS failure
might actually be a routing issue; a "connection refused" might be a firewall.

---

## Layer 1–2: Physical and Data Link

### Check link state

```bash
# Is the interface physically connected and up?
ip -br link show
# Output: eth0  UP  aa:bb:cc:dd:ee:ff  <BROADCAST,MULTICAST,UP,LOWER_UP>
# LOWER_UP means physical link is detected

ethtool eth0                              # link speed, duplex, link detected
ethtool eth0 | grep "Link detected"       # quick check

# Check for link flapping in logs
dmesg | grep -i "link"
journalctl -u NetworkManager --since "1 hour ago" | grep -i "link\|carrier"
```

### Interface errors and drops

```bash
ip -s link show eth0
# Look for: RX errors, TX errors, drops, overruns, frame errors

# Detailed NIC statistics
ethtool -S eth0 | grep -E "error|drop|miss|fifo"

# Ring buffer — increase if seeing drops under load
ethtool -g eth0                           # show current ring buffer sizes
ethtool -G eth0 rx 4096 tx 4096          # increase
```

### Driver and hardware issues

```bash
ethtool -i eth0                           # driver, firmware, bus info
lspci | grep -i ethernet                  # PCI NIC info
dmesg | grep -i eth0                      # driver messages
modinfo <driver_name>                     # module details
```

---

## Layer 3: Network — IP and Routing

### Verify IP configuration

```bash
ip -br addr show                          # brief: interface, state, IPs
ip addr show dev eth0                     # detailed single interface

# Check for missing or duplicate IPs
ip addr show | grep "inet " | awk '{print $2}' | sort | uniq -d

# Verify correct subnet
ipcalc 192.168.1.100/24                   # shows network, broadcast, range
```

### Test routing step by step

```bash
# 1. Can I reach my gateway?
ip route show default                     # what's my default gateway?
ping -c 2 $(ip route show default | awk '{print $3}')

# 2. Can I reach an external IP? (bypasses DNS)
ping -c 2 8.8.8.8

# 3. Can I reach a hostname? (tests DNS)
ping -c 2 google.com

# 4. Where does the path break?
traceroute -n 8.8.8.8                     # -n skips DNS for speed
mtr -n --report -c 20 8.8.8.8           # combined ping+traceroute

# 5. Is traffic being routed correctly?
ip route get 10.0.0.5                     # which route/interface is used?
```

### Source-based routing issues

```bash
# Traffic not returning? Check if reply goes out correct interface
ip route get 8.8.8.8 from 192.168.1.100   # which path from this source?

# Asymmetric routing check
ip rule show                               # any policy routing rules?
ip route show table all | head -30        # routes across all tables
```

---

## ARP Issues

### Symptoms
- "No route to host" or "Host unreachable" on local subnet
- Intermittent connectivity between local hosts
- Duplicate IP address warnings

### Diagnosis

```bash
# View ARP/neighbor table
ip neigh show
# States: REACHABLE, STALE, DELAY, PROBE, FAILED, INCOMPLETE

# INCOMPLETE = sent ARP request but no reply (host down or wrong VLAN)
# FAILED = ARP resolution failed entirely

# Watch ARP in real time
ip monitor neigh

# Capture ARP traffic
tcpdump -i eth0 -nn arp
# Look for:
#   ARP, Request who-has 10.0.0.5 tell 10.0.0.1   → request sent
#   ARP, Reply 10.0.0.5 is-at aa:bb:cc:dd:ee:ff    → response received
```

### Common ARP problems

```bash
# 1. IP conflict — two hosts claim same IP
arping -D -I eth0 192.168.1.100           # Duplicate Address Detection
# If reply received → conflict exists

# 2. Stale ARP cache
ip neigh flush all                         # clear and let re-learn

# 3. Gratuitous ARP not working (VRRP/keepalived failover issues)
arping -U -c 3 -I eth0 192.168.1.100     # send gratuitous ARP

# 4. ARP flood / ARP storm
tcpdump -i eth0 arp -c 100 | wc -l       # high count = problem
# Check for broadcast storms, loops (enable STP on bridges)

# 5. Proxy ARP
sysctl net.ipv4.conf.eth0.proxy_arp       # 1 = proxy ARP enabled
# Proxy ARP can cause unexpected behavior across subnets
```

---

## DNS Resolution Failures

### Systematic DNS debugging

```bash
# 1. What DNS resolver is configured?
cat /etc/resolv.conf
resolvectl status 2>/dev/null || systemd-resolve --status 2>/dev/null

# 2. Is the resolv.conf correct?
ls -la /etc/resolv.conf                   # is it a symlink?
# Common issue: symlink broken after NetworkManager/systemd-resolved change

# 3. Test with explicit nameserver
dig @8.8.8.8 example.com                  # bypass local resolver
dig @127.0.0.53 example.com              # test systemd-resolved stub

# 4. Is something blocking DNS (port 53)?
ss -ulnp | grep :53                       # local DNS service?
tcpdump -i eth0 -nn port 53 -c 10        # DNS traffic leaving?
iptables -L -n -v | grep 53              # firewall blocking?

# 5. NXDOMAIN vs SERVFAIL vs timeout
dig example.com
# NXDOMAIN = domain doesn't exist
# SERVFAIL = upstream server error
# ;; connection timed out = can't reach DNS server
```

### Common DNS problems and fixes

```bash
# Problem: resolv.conf gets overwritten
# Fix for systemd-resolved:
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Fix for NetworkManager:
# In /etc/NetworkManager/NetworkManager.conf:
# [main]
# dns=none
# Then manage /etc/resolv.conf manually

# Problem: search domain causing wrong lookups
# In resolv.conf, "search example.com" appends to short names
# "host myserver" actually queries "myserver.example.com" first
dig +search myserver                      # shows what's actually queried
dig +nosearch myserver                    # force exact name

# Problem: nsswitch.conf order
cat /etc/nsswitch.conf | grep hosts
# "hosts: files dns" → /etc/hosts checked first
# "hosts: files resolve [!UNAVAIL=return] dns" → systemd-resolved, then dns

# Problem: DNS-over-TLS/HTTPS not working
resolvectl dns eth0 1.1.1.1               # set DNS
resolvectl dnsovertls eth0 yes            # enable DoT
```

### DNS cache debugging

```bash
# systemd-resolved cache
resolvectl statistics                      # hit/miss counts
resolvectl flush-caches                   # clear cache

# nscd (Name Service Cache Daemon)
nscd -g | grep -A 5 "hosts cache"        # cache stats
nscd -i hosts                             # invalidate hosts cache

# dnsmasq (if used)
kill -USR1 $(pidof dnsmasq)               # dump stats to syslog
```

---

## MTU and Fragmentation Issues

### Symptoms
- Small packets work, large transfers hang or fail
- SSH works but SCP/SFTP stalls
- VPN connected but no traffic flows
- "message too long" errors

### Diagnosis

```bash
# 1. Check interface MTU
ip link show | grep mtu

# 2. Test Path MTU Discovery
ping -M do -s 1472 -c 3 target-host      # DF bit set, 1472+28=1500 total
# Decrease -s value until ping succeeds to find actual PMTU
# 1472 → 1500 MTU (standard ethernet)
# 1422 → 1450 MTU (VXLAN overhead)
# 1372 → 1400 MTU (VPN/tunnel overhead)

# 3. Check for ICMP "fragmentation needed" being blocked
tcpdump -i eth0 'icmp and icmp[0]=3 and icmp[1]=4' -nn
# If no ICMP type 3/code 4 responses → PMTUD is broken (black hole)

# 4. Check cached PMTU
ip route get 10.0.0.5 | grep mtu

# 5. Check for PMTUD being disabled
sysctl net.ipv4.ip_no_pmtu_disc           # 0 = PMTUD enabled (good)
```

### Fixes

```bash
# Fix 1: Set correct MTU on interface
ip link set eth0 mtu 1400                 # match lowest link in path

# Fix 2: MSS clamping (for TCP through firewalls/NAT)
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu
# Or set explicit MSS
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --set-mss 1360

# Fix 3: Allow ICMP fragmentation-needed through firewall
iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT
iptables -A FORWARD -p icmp --icmp-type fragmentation-needed -j ACCEPT

# Fix 4: Clear PMTU cache
ip route flush cache
```

### Tunnel MTU calculations

```
Standard Ethernet MTU:     1500
GRE overhead:              -24   →  MTU 1476
GRE + IPsec:               -58   →  MTU 1442
VXLAN overhead:            -50   →  MTU 1450
WireGuard overhead:        -60   →  MTU 1440 (IPv4) / -80 → 1420 (IPv6)
OpenVPN (UDP):             -28   →  MTU 1472
OpenVPN (TCP):             -40   →  MTU 1460
```

---

## Packet Capture with tcpdump

### Essential capture filters (BPF syntax)

```bash
# By host
tcpdump -i eth0 host 10.0.0.5
tcpdump -i eth0 src host 10.0.0.5
tcpdump -i eth0 dst host 10.0.0.5
tcpdump -i eth0 not host 10.0.0.5

# By network
tcpdump -i eth0 net 192.168.1.0/24

# By port
tcpdump -i eth0 port 443
tcpdump -i eth0 dst port 53
tcpdump -i eth0 portrange 8000-8100

# By protocol
tcpdump -i eth0 tcp
tcpdump -i eth0 udp
tcpdump -i eth0 icmp
tcpdump -i eth0 arp

# Combined filters
tcpdump -i eth0 'host 10.0.0.5 and port 443'
tcpdump -i eth0 'src 10.0.0.5 and (dst port 80 or dst port 443)'
tcpdump -i eth0 'not port 22 and not arp'          # exclude SSH and ARP noise
```

### TCP flag filters

```bash
# SYN only (new connections)
tcpdump -i eth0 'tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0'

# SYN-ACK (connection accepted)
tcpdump -i eth0 'tcp[tcpflags] & (tcp-syn|tcp-ack) == (tcp-syn|tcp-ack)'

# RST packets (connection reset)
tcpdump -i eth0 'tcp[tcpflags] & tcp-rst != 0'

# FIN packets (connection close)
tcpdump -i eth0 'tcp[tcpflags] & tcp-fin != 0'

# PSH-ACK (data transfer)
tcpdump -i eth0 'tcp[tcpflags] & (tcp-push|tcp-ack) == (tcp-push|tcp-ack)'
```

### Practical capture recipes

```bash
# Capture to file for analysis (use -s 0 for full packets)
tcpdump -i eth0 -nn -s 0 -w /tmp/capture.pcap -c 10000

# Capture with rotation (10 files of 100MB each)
tcpdump -i eth0 -nn -w /tmp/cap-%Y%m%d-%H%M%S.pcap -G 3600 -W 10 -s 0

# Show packet contents as ASCII
tcpdump -i eth0 -A port 80 -c 20

# Show hex + ASCII
tcpdump -i eth0 -XX port 80 -c 5

# Timestamps in readable format
tcpdump -i eth0 -nn -tttt port 443 -c 10

# Capture only headers (save space)
tcpdump -i eth0 -nn -s 96 -w headers.pcap
```

---

## Advanced Capture with tshark

### Display filters (applied post-capture, different from BPF)

```bash
# HTTP requests
tshark -i eth0 -Y 'http.request.method == "GET"'

# DNS queries
tshark -i eth0 -Y 'dns.flags.response == 0'

# TCP retransmissions
tshark -i eth0 -Y 'tcp.analysis.retransmission'

# TCP window size issues
tshark -i eth0 -Y 'tcp.analysis.window_full || tcp.analysis.zero_window'

# TLS handshake
tshark -i eth0 -Y 'tls.handshake.type == 1'   # Client Hello

# Specific error responses
tshark -i eth0 -Y 'http.response.code >= 400'
```

### Field extraction for analysis

```bash
# Extract specific fields as CSV
tshark -r capture.pcap -T fields -E separator=, \
  -e frame.time -e ip.src -e ip.dst -e tcp.dstport -e tcp.len

# Top talkers by source IP
tshark -r capture.pcap -T fields -e ip.src | sort | uniq -c | sort -rn | head

# Connection summary
tshark -r capture.pcap -q -z conv,tcp

# Protocol hierarchy
tshark -r capture.pcap -q -z io,phs

# Follow a TCP stream
tshark -r capture.pcap -z follow,tcp,ascii,0

# DNS response times
tshark -r capture.pcap -Y dns -T fields -e dns.qry.name -e dns.time \
  | sort -t$'\t' -k2 -rn | head
```

### Live monitoring

```bash
# I/O statistics every 5 seconds
tshark -i eth0 -q -z io,stat,5

# Endpoint statistics
tshark -i eth0 -q -z endpoints,tcp -a duration:30

# Expert info (anomalies)
tshark -i eth0 -q -z expert -a duration:60
```

---

## TCP Connection Debugging

### Connection state analysis

```bash
# Count connections by state
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn
# Healthy: mostly ESTAB, few TIME-WAIT, minimal SYN-RECV

# Alternative with /proc
cat /proc/net/snmp | grep Tcp
# Fields: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens
#         AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts
```

### SYN flood detection

```bash
# Count SYN_RECV (half-open connections)
ss -tan state syn-recv | wc -l
# Normal: < 10. High: > 100 indicates possible SYN flood

# Check SYN cookies status
sysctl net.ipv4.tcp_syncookies             # 1 = enabled (good)
sysctl net.ipv4.tcp_max_syn_backlog        # max half-open connections

# Monitor SYN flood in real time
watch -n 1 'ss -tan state syn-recv | wc -l'

# Capture SYN packets per source
tcpdump -i eth0 'tcp[tcpflags] == tcp-syn' -nn -c 1000 \
  | awk '{print $3}' | cut -d. -f1-4 | sort | uniq -c | sort -rn | head
```

### TIME_WAIT accumulation

```bash
# Count TIME_WAIT sockets
ss -tan state time-wait | wc -l
# Thousands of TIME_WAIT = normal for busy servers, but excessive = problem

# Solutions
sysctl -w net.ipv4.tcp_tw_reuse=1          # reuse TIME_WAIT for new connections
sysctl -w net.ipv4.tcp_fin_timeout=15      # reduce FIN_WAIT2 timeout (default 60)
sysctl -w net.ipv4.ip_local_port_range="1024 65535"  # widen ephemeral port range

# NEVER use tcp_tw_recycle — removed from kernel 4.12+ (broke NAT)
```

### RST analysis

```bash
# Capture RST packets
tcpdump -i eth0 'tcp[tcpflags] & tcp-rst != 0' -nn -c 50

# Common RST causes:
# 1. Connection to closed port → immediate RST from kernel
# 2. Firewall REJECT rule → RST sent
# 3. Application crash → kernel sends RST for open connections
# 4. TCP timeout → RST after retransmission limit
# 5. Load balancer health check → RST after probe

# Differentiate RST causes
tshark -r capture.pcap -Y 'tcp.flags.reset == 1' -T fields \
  -e ip.src -e ip.dst -e tcp.srcport -e tcp.dstport -e tcp.seq
```

### Retransmission analysis

```bash
# Check retransmission counter
cat /proc/net/snmp | grep Tcp | tail -1 | awk '{print "Retransmits:", $12}'

# Watch retransmission rate
watch -n 5 'cat /proc/net/snmp | grep Tcp'

# Capture retransmissions
tshark -i eth0 -Y 'tcp.analysis.retransmission' -c 50

# High retransmission causes:
# - Network congestion
# - Packet loss on path (bad cable, overloaded switch)
# - MTU issues causing fragmentation/drops
# - CPU overload causing socket buffer overflows
```

---

## Firewall Rule Debugging

### iptables debugging

```bash
# List all rules with packet counters
iptables -L -n -v --line-numbers
iptables -t nat -L -n -v --line-numbers
iptables -t mangle -L -n -v --line-numbers

# Watch counters in real time
watch -n 2 'iptables -L -n -v --line-numbers'

# Zero counters, then reproduce issue, then check which rule matched
iptables -Z                                # zero all counters
# ... reproduce the problem ...
iptables -L -n -v                         # check which rules have hits

# Add LOG rule before DROP to see what's being dropped
iptables -I INPUT 1 -j LOG --log-prefix "IPT-INPUT-DROP: " --log-level 4
# Check: journalctl -k | grep "IPT-INPUT-DROP"
# IMPORTANT: Remove LOG rule after debugging to avoid log flooding

# Trace packet through all chains
iptables -t raw -A PREROUTING -p tcp --dport 80 -j TRACE
iptables -t raw -A OUTPUT -p tcp --dport 80 -j TRACE
# View: journalctl -k | grep TRACE
# Don't forget to remove trace rules!
```

### nftables debugging

```bash
# List full ruleset with handles (for deletion)
nft -a list ruleset

# Add counter to specific rule
nft add rule inet filter input tcp dport 443 counter accept

# Monitor nftables events
nft monitor

# Trace packets through nftables
nft add rule inet filter prerouting meta nftrace set 1
nft monitor trace
```

### Common firewall debugging patterns

```bash
# "Connection refused" — service not listening or firewall REJECT
ss -tlnp | grep :8080                     # is service listening?
iptables -L INPUT -n -v | grep 8080       # is port allowed?

# "No route to host" — ICMP host-unreachable or REJECT --reject-with
iptables -L -n -v | grep REJECT

# "Connection timed out" — DROP rule or no route
# DROP = silent, no response → client times out
iptables -L -n -v | grep DROP

# Traffic passes locally but not from outside
# Check: is the service bound to 0.0.0.0 or just 127.0.0.1?
ss -tlnp | grep :8080
# "127.0.0.1:8080" → only local access
# "0.0.0.0:8080" or "*:8080" → all interfaces
```

---

## Routing Table Conflicts

### Diagnosis

```bash
# Show all routing tables
ip route show table all

# Check rule priority
ip rule show
# Rules are evaluated in priority order (lower number = higher priority)

# Which route is actually used for a destination?
ip route get 10.0.0.5
ip route get 10.0.0.5 from 192.168.1.100  # from specific source

# Show route with nexthop details
ip route show match 10.0.0.0/8

# Check for conflicting/overlapping routes
ip route show | grep "10.0.0"
```

### Common routing problems

```bash
# Problem: wrong default gateway after VPN connect
ip route show default                      # multiple defaults?
# Fix: set metric to prefer one
ip route del default via 10.8.0.1
ip route add default via 10.8.0.1 metric 100  # lower = preferred

# Problem: asymmetric routing (traffic enters eth0, exits eth1)
# Symptoms: TCP connections fail, stateful firewall drops returns
# Fix: source-based routing
ip rule add from 203.0.113.10 table 100
ip route add default via 203.0.113.1 table 100

# Problem: blackhole route blocking traffic
ip route show table all | grep blackhole
ip route del blackhole 10.0.0.0/8          # remove if unintended

# Problem: cached route pointing to old path
ip route flush cache
```

---

## Network Performance Diagnosis

### Bandwidth testing

```bash
# iperf3 — most reliable bandwidth test
# Server side:
iperf3 -s

# Client TCP test:
iperf3 -c server -t 30 -P 4              # 30 sec, 4 parallel streams
iperf3 -c server -t 30 -R                 # reverse (server → client)

# Client UDP test:
iperf3 -c server -u -b 1G -t 10          # 1Gbps target rate

# Key metrics in output:
# Bandwidth (Gbits/sec), Retransmits, Cwnd (congestion window)
```

### Latency analysis

```bash
# Basic latency
ping -c 20 -i 0.2 target                  # 20 pings, 0.2s interval

# Path latency with mtr (combined traceroute + ping)
mtr -n --report -c 100 target
# Look for: sudden latency jump (indicates bottleneck hop)
# Note: ICMP deprioritization can cause false high latency at intermediate hops

# Application-level latency
curl -o /dev/null -s -w "DNS:%{time_namelookup} TCP:%{time_connect} TLS:%{time_appconnect} TTFB:%{time_starttransfer} Total:%{time_total}\n" https://target
```

### Throughput bottleneck identification

```bash
# 1. Check for interface errors/drops
ip -s link show eth0 | grep -E "errors|dropped"

# 2. Check NIC ring buffers
ethtool -S eth0 | grep -E "drop|miss|error"

# 3. Check socket buffer sizes
sysctl net.core.rmem_max                   # max receive buffer
sysctl net.core.wmem_max                   # max send buffer
sysctl net.ipv4.tcp_rmem                   # TCP receive (min/default/max)
sysctl net.ipv4.tcp_wmem                   # TCP send

# 4. Check for CPU bottleneck (softirq)
cat /proc/softirqs | grep NET
mpstat -P ALL 1 5                          # per-CPU utilization
# High si% (softirq) on one CPU = NIC interrupt affinity issue

# 5. Check interrupt affinity
cat /proc/interrupts | grep eth0
# All on one CPU? Spread with irqbalance or manual affinity

# 6. Check TCP congestion control
sysctl net.ipv4.tcp_congestion_control     # cubic, bbr, etc.
# BBR often performs better on long-distance/lossy links
sysctl -w net.ipv4.tcp_congestion_control=bbr
```

### Network quality monitoring

```bash
# Packet loss test
ping -c 1000 -i 0.01 -q target
# "X% packet loss" — even 1% causes significant TCP performance degradation

# Jitter measurement
ping -c 100 target | tail -1
# "rtt min/avg/max/mdev" — mdev is jitter (standard deviation)

# Bandwidth over time
iperf3 -c server -t 60 -i 1              # report every second for 60 seconds
```

---

## Quick Diagnostic Checklists

### "I can't reach anything"

```bash
ip -br link show                          # 1. Interface UP?
ip -br addr show                          # 2. Has IP address?
ip route show default                     # 3. Default gateway set?
ping -c 2 $(ip r | awk '/default/{print $3}')  # 4. Gateway reachable?
ping -c 2 8.8.8.8                         # 5. Internet reachable?
dig +short google.com @8.8.8.8           # 6. DNS works?
iptables -L -n | grep -c DROP            # 7. Firewall blocking?
```

### "Service is running but not reachable from outside"

```bash
ss -tlnp | grep :<PORT>                  # 1. Listening on correct address?
curl -v localhost:<PORT>                  # 2. Works locally?
iptables -L INPUT -n -v | grep <PORT>    # 3. Firewall allows?
tcpdump -i eth0 port <PORT> -nn -c 5     # 4. Packets arriving?
ip route get <CLIENT_IP>                  # 5. Return route exists?
```

### "Network is slow"

```bash
mtr -n --report target                    # 1. Where is latency?
ip -s link show eth0                      # 2. Interface errors?
ss -ti dst target                         # 3. TCP metrics (rto, cwnd)?
iperf3 -c target -t 10                    # 4. Raw bandwidth OK?
sysctl net.ipv4.tcp_congestion_control    # 5. Congestion algorithm?
ethtool -S eth0 | grep drop              # 6. NIC drops?
dmesg | grep -i "eth0\|oom\|drop"        # 7. Kernel messages?
```

### "Intermittent connectivity"

```bash
ping -D -i 0.5 target | tee /tmp/ping.log  # 1. Continuous ping w/ timestamps
mtr -n --report -c 500 target              # 2. Long-running path analysis
tcpdump -i eth0 -nn -w /tmp/debug.pcap &   # 3. Background capture
ip monitor all                              # 4. Watch for link/route changes
journalctl -f -u NetworkManager            # 5. NM events
dmesg -w                                    # 6. Kernel messages
```
