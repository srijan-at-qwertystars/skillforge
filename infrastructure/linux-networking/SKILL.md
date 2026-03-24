---
name: linux-networking
description: >
  Linux network configuration, diagnostics, and troubleshooting skill.
  Covers ip commands, DNS resolution, firewall management, TCP/UDP debugging,
  network namespaces, bridges, VLANs, bonding, routing, NAT, port forwarding,
  MTU tuning, performance testing, kernel tunables, WireGuard VPN, SSH tunneling,
  curl/wget, TLS certificate debugging, systemd-networkd, and NetworkManager.
  Use when user needs Linux network configuration, firewall rules, TCP debugging,
  DNS troubleshooting, VPN setup, port forwarding, interface management, routing
  tables, network performance tuning, or packet capture analysis.
  NOT for Windows networking, NOT for cloud-specific networking (AWS VPC, Azure
  VNet, GCP networking, security groups), NOT for application-layer protocols
  (HTTP/2 framing, gRPC internals), NOT for container orchestration networking
  (Kubernetes CNI, service mesh).
---

# Linux Networking

## Network Interfaces
```bash
ip addr show                              # list all interfaces with addresses
ip -br a                                  # brief format
ip addr show dev eth0                     # single interface
ip link set eth0 up                       # bring up
ip link set eth0 down                     # bring down
ip addr add 192.168.1.100/24 dev eth0     # add IP
ip addr del 192.168.1.100/24 dev eth0     # remove IP
ip link set dev eth0 mtu 9000            # set MTU
ip -s link show dev eth0                  # link statistics
```

## Routing
```bash
ip route show                             # show routing table
ip route add default via 192.168.1.1 dev eth0
ip route add 10.0.0.0/8 via 192.168.1.254 # static route
ip route del 10.0.0.0/8
ip route get 8.8.8.8                      # show route to host
```

### Policy routing
```bash
ip rule show
ip route add default via 10.0.0.1 table 100
ip rule add from 192.168.2.0/24 table 100 # source-based routing
ip rule add fwmark 1 table 100            # route marked packets
```

## DNS Resolution

### systemd-resolved
```bash
resolvectl status                         # per-interface DNS servers
resolvectl query example.com              # query through resolved
resolvectl flush-caches                   # flush DNS cache
resolvectl statistics                     # cache stats
# Fix broken resolv.conf symlink
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
# Configure: /etc/systemd/resolved.conf
# [Resolve]
# DNS=1.1.1.1 8.8.8.8
# FallbackDNS=9.9.9.9
# Domains=~.
sudo systemctl restart systemd-resolved
```

### dig and nslookup
```bash
dig example.com                           # A record
dig example.com MX                        # MX record
dig @8.8.8.8 example.com                  # query specific nameserver
dig +short example.com                    # short output
dig +trace example.com                    # trace delegation path
dig -x 93.184.216.34                      # reverse DNS
nslookup example.com 8.8.8.8             # interactive-friendly
```

## Firewall Management

### iptables
```bash
iptables -L -n -v --line-numbers          # list all rules
iptables -t nat -L -n -v                  # list NAT table
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -j DROP                 # default deny
iptables -D INPUT 3                       # delete rule by number
iptables-save > /etc/iptables/rules.v4    # persist
iptables-restore < /etc/iptables/rules.v4
```

### nftables (modern replacement)
```bash
nft list ruleset
nft add table inet filter
nft add chain inet filter input { type filter hook input priority 0 \; policy drop \; }
nft add rule inet filter input tcp dport 22 accept
nft add rule inet filter input ct state established,related accept
nft list ruleset > /etc/nftables.conf     # save
nft -f /etc/nftables.conf                 # load
```

### ufw (Ubuntu/Debian)
```bash
ufw status verbose
ufw allow 22/tcp
ufw allow from 192.168.1.0/24 to any port 3306
ufw deny 23/tcp
ufw enable
ufw delete allow 22/tcp
```

### firewalld (RHEL/Fedora)
```bash
firewall-cmd --state
firewall-cmd --list-all
firewall-cmd --add-port=80/tcp --permanent
firewall-cmd --add-service=https --permanent
firewall-cmd --reload
firewall-cmd --zone=trusted --add-source=10.0.0.0/8 --permanent
```

## TCP/UDP Debugging

### ss (socket statistics)
```bash
ss -tlnp                                  # listening TCP with process
ss -tn state established                  # established connections
ss -ulnp                                  # UDP sockets
ss -tn sport = :443                       # filter by port
ss -tn -o state established              # with timer info
ss -s                                     # connection summary by state
```

### tcpdump
```bash
tcpdump -i eth0                           # capture on interface
tcpdump -nn -i eth0 host 10.0.0.5 and port 443  # filter, no DNS
tcpdump -i eth0 -w capture.pcap -c 1000  # write to file
tcpdump -nn -r capture.pcap              # read pcap
tcpdump -A -i eth0 port 80               # show ASCII content
tcpdump -i eth0 'tcp[tcpflags] & tcp-syn != 0'  # SYN packets only
```

### tshark (Wireshark CLI)
```bash
tshark -i eth0 -f "port 443" -c 100
tshark -r capture.pcap -Y "http.request.method == GET"
tshark -r capture.pcap -T fields -e ip.src -e ip.dst -e tcp.dstport
```

## Network Namespaces
```bash
ip netns add red                          # create namespace
ip netns exec red ip addr show            # exec in namespace
# Create veth pair connecting namespaces
ip link add veth0 type veth peer name veth1
ip link set veth1 netns red
ip addr add 10.0.0.1/24 dev veth0
ip netns exec red ip addr add 10.0.0.2/24 dev veth1
ip link set veth0 up
ip netns exec red ip link set veth1 up
ip netns exec red ping 10.0.0.1           # test connectivity
ip netns list                             # list namespaces
ip netns del red                          # delete
```

## Bridges and VLANs

### Bridge
```bash
ip link add name br0 type bridge
ip link set br0 up
ip link set eth0 master br0               # add to bridge
ip link set eth1 master br0
ip addr add 192.168.1.1/24 dev br0
bridge link show
bridge fdb show
```

### VLAN
```bash
ip link add link eth0 name eth0.10 type vlan id 10
ip addr add 192.168.10.1/24 dev eth0.10
ip link set eth0.10 up
```

## Bonding
```bash
# Create bond (active-backup)
ip link add bond0 type bond mode active-backup miimon 100
ip link set eth0 master bond0
ip link set eth1 master bond0
ip link set bond0 up
ip addr add 192.168.1.100/24 dev bond0
cat /proc/net/bonding/bond0               # check status
# Via NetworkManager (LACP)
nmcli con add type bond ifname bond0 bond.options "mode=802.3ad,miimon=100"
nmcli con add type ethernet ifname eth0 master bond0
nmcli con add type ethernet ifname eth1 master bond0
```

## NAT and Port Forwarding

### Enable IP forwarding
```bash
echo 1 > /proc/sys/net/ipv4/ip_forward   # temporary
# Persistent: net.ipv4.ip_forward = 1 in /etc/sysctl.conf
sysctl -p
```

### SNAT / Masquerade
```bash
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE          # dynamic IP
iptables -t nat -A POSTROUTING -o eth0 -j SNAT --to-source 203.0.113.1  # static IP
```

### DNAT / Port forwarding
```bash
# Forward external:8080 → internal 192.168.1.10:80
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 \
  -j DNAT --to-destination 192.168.1.10:80
iptables -A FORWARD -p tcp -d 192.168.1.10 --dport 80 -j ACCEPT
```

### nftables NAT
```bash
nft add table ip nat
nft add chain ip nat prerouting { type nat hook prerouting priority 0 \; }
nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
nft add rule ip nat postrouting oifname "eth0" masquerade
nft add rule ip nat prerouting iifname "eth0" tcp dport 8080 dnat to 192.168.1.10:80
```

## MTU and Path MTU Discovery
```bash
ip link show dev eth0 | grep mtu          # check current MTU
ip link set dev eth0 mtu 9000            # set MTU (jumbo frames)
ping -M do -s 1472 -c 3 10.0.0.1         # test path MTU (DF bit set)
# Output: "message too long, mtu=1500" → path MTU is 1500
sysctl net.ipv4.ip_no_pmtu_disc           # 0 = PMTUD enabled
ip route get 10.0.0.1 | grep mtu         # check PMTU cache
```

## Network Performance
```bash
# iperf3 TCP throughput
iperf3 -s                                 # server
iperf3 -c 10.0.0.1 -t 30 -P 4           # client, 4 parallel streams
# Output: [ SUM]  0.00-30.00 sec  27.5 GBytes  7.87 Gbits/sec  receiver
iperf3 -c 10.0.0.1 -u -b 1G -t 10       # UDP test
ping -c 10 -i 0.2 10.0.0.1               # latency measurement
```

## Kernel Network Tunables

Add to `/etc/sysctl.d/99-network.conf` for high-performance servers:
```bash
net.core.somaxconn = 4096                 # listen backlog (default 128)
net.core.netdev_max_backlog = 5000        # input queue length
net.ipv4.tcp_max_syn_backlog = 4096       # half-open connections
net.ipv4.tcp_keepalive_time = 600         # idle before keepalive (default 7200)
net.ipv4.tcp_keepalive_intvl = 30         # probe interval
net.ipv4.tcp_keepalive_probes = 10        # probes before drop
net.ipv4.tcp_tw_reuse = 1                 # reuse TIME_WAIT sockets
net.ipv4.tcp_fin_timeout = 15             # FIN_WAIT2 timeout
net.ipv4.ip_local_port_range = 1024 65535 # ephemeral port range
net.core.rmem_max = 16777216              # max receive buffer
net.core.wmem_max = 16777216              # max send buffer
net.ipv4.tcp_rmem = 4096 87380 16777216   # TCP receive buffer (min/default/max)
net.ipv4.tcp_wmem = 4096 65536 16777216   # TCP send buffer
# Apply:
sysctl -p /etc/sysctl.d/99-network.conf
# NEVER use net.ipv4.tcp_tw_recycle — deprecated, breaks NAT
```

## WireGuard VPN
```bash
wg genkey | tee privatekey | wg pubkey > publickey
# Server config /etc/wireguard/wg0.conf:
# [Interface]
# PrivateKey = <server-private-key>
# Address = 10.0.0.1/24
# ListenPort = 51820
# PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
# [Peer]
# PublicKey = <client-public-key>
# AllowedIPs = 10.0.0.2/32
wg-quick up wg0
wg-quick down wg0
wg show                                   # status
```

## SSH Tunneling
```bash
# Local forward: access remote:5432 via localhost:5432
ssh -L 5432:localhost:5432 user@bastion
# Remote forward: expose local:3000 on remote as :8080
ssh -R 8080:localhost:3000 user@remote
# Dynamic SOCKS proxy
ssh -D 9090 user@remote
curl --socks5-hostname localhost:9090 http://ifconfig.me
# Background tunnel (no shell)
ssh -fN -L 5432:db-host:5432 user@bastion
# Jump host
ssh -J user@bastion user@internal-host
```

## curl and wget Advanced
```bash
curl -v -I https://example.com            # verbose headers
curl -X POST -H 'Content-Type: application/json' \
  -d '{"key":"value"}' https://api.example.com/endpoint
curl -o /dev/null -s -w "%{http_code}" -L https://example.com  # response code only
curl -C - -O -L https://example.com/file.tar.gz               # resume download
curl --cert client.pem --key client-key.pem https://mtls.example.com
# Timing breakdown
curl -o /dev/null -s -w "DNS: %{time_namelookup}s\nConnect: %{time_connect}s\nTLS: %{time_appconnect}s\nTotal: %{time_total}s\n" https://example.com
# wget recursive mirror
wget --mirror --convert-links --adjust-extension --no-parent https://docs.example.com/
```

## TLS Certificate Debugging
```bash
# Show certificate chain
openssl s_client -connect example.com:443 -showcerts </dev/null
# Certificate details with SNI
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -text
# Check expiration
openssl s_client -connect example.com:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -dates
# Output: notAfter=Dec 15 23:59:59 2025 GMT
# Verify against CA bundle
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt server.pem
# Test specific TLS version
openssl s_client -connect example.com:443 -tls1_2
```

## systemd-networkd
```bash
# Config: /etc/systemd/network/20-wired.network
# [Match]
# Name=eth0
# [Network]
# Address=192.168.1.100/24
# Gateway=192.168.1.1
# DNS=1.1.1.1
systemctl enable --now systemd-networkd
networkctl status                         # overview
networkctl status eth0                    # per-interface
```

## NetworkManager (nmcli)
```bash
nmcli dev status                          # device overview
nmcli con show                            # list connections
# Static IP
nmcli con add type ethernet ifname eth0 con-name static-eth0 \
  ip4 192.168.1.100/24 gw4 192.168.1.1
nmcli con mod static-eth0 ipv4.dns "1.1.1.1 8.8.8.8"
nmcli con up static-eth0
# Switch to DHCP
nmcli con mod static-eth0 ipv4.method auto
nmcli con up static-eth0
# Wi-Fi
nmcli dev wifi list
nmcli dev wifi connect "SSID" password "pass"
```

## Troubleshooting Patterns

### No connectivity
```bash
ip -br a                                  # 1. interface up with IP?
ip route show default                     # 2. default route?
ping -c 2 $(ip route show default | awk '{print $3}')  # 3. ping gateway
ping -c 2 8.8.8.8                         # 4. external IP (bypass DNS)
dig +short google.com                     # 5. DNS working?
iptables -L -n | head -20                 # 6. firewall blocking?
```

### Port not reachable
```bash
ss -tlnp | grep :8080                     # service listening?
curl -v localhost:8080                     # local test
iptables -L INPUT -n -v | grep 8080       # firewall rule?
nc -zv target-host 8080                   # remote test
traceroute -T -p 8080 target-host         # trace path
```

### High latency / packet loss
```bash
ping -D -i 0.5 target-host               # continuous with timestamps
mtr -n --report target-host              # find bottleneck hop
ip -s link show dev eth0 | grep -E "errors|dropped"
tc qdisc show dev eth0                    # check queueing discipline
```

### DNS resolution failure
```bash
ls -l /etc/resolv.conf                    # check symlink
cat /etc/resolv.conf                      # verify nameserver
resolvectl status                         # systemd-resolved state
dig @1.1.1.1 example.com                  # test explicit nameserver
ss -ulnp | grep :53                       # port 53 conflict?
```

---

## Reference Guides

In-depth references in `references/`:

### Advanced Networking Patterns — `references/advanced-patterns.md`
Network namespaces deep dive, veth pairs, bridges (STP/VLAN filtering),
macvlan vs ipvlan, traffic control (tc/HTB/netem), eBPF/XDP packet processing,
nftables sets/maps/flowtables, policy routing with multiple tables,
GRE/VXLAN tunnels, multipath routing (ECMP), network bonding modes (all 7).

### Network Troubleshooting — `references/troubleshooting.md`
OSI layer-by-layer methodology, ARP issues, DNS resolution failures,
MTU/fragmentation (PMTUD, MSS clamping, tunnel overhead table),
tcpdump BPF filters and TCP flag filters, tshark display filters and field extraction,
TCP debugging (SYN floods, TIME_WAIT, RST analysis, retransmissions),
firewall debugging (iptables TRACE, nftables monitor), routing conflicts,
performance diagnosis, quick diagnostic checklists.

### Security Hardening — `references/security-hardening.md`
Firewall best practices (default deny, rate limiting, logging), fail2ban setup,
port knocking (knockd + iptables-based), TCP Wrappers, sysctl hardening
(rp_filter, tcp_syncookies, ICMP, redirects, martians), SSH hardening
(key-only, sshd_config, jump hosts, certificate-based auth),
TLS certificate management (Let's Encrypt, self-signed CA, monitoring),
VPN comparison: WireGuard vs OpenVPN vs IPsec (feature table, setup).

---

## Scripts

Executable diagnostic and setup scripts in `scripts/`:

| Script | Purpose |
|--------|---------|
| `scripts/net-diagnostics.sh` | Comprehensive network diagnostic (interfaces, routes, DNS, ports, connections, firewall, latency). Supports `--full`, `--quick`, `--section <name>` modes. |
| `scripts/firewall-setup.sh` | Interactive firewall setup supporting iptables/nftables/ufw with presets (minimal, web, database, docker). Supports `--dry-run` for preview. |
| `scripts/bandwidth-test.sh` | Bandwidth testing with iperf3 — server/client modes, multi-stream progressive testing, UDP mode, result reporting. |

```bash
# Quick examples
sudo ./scripts/net-diagnostics.sh --quick
sudo ./scripts/firewall-setup.sh --dry-run --preset web --backend nftables
./scripts/bandwidth-test.sh client 10.0.0.1 --multi --report results.txt
```

---

## Assets (Copy-Paste Templates)

Production-ready configuration templates in `assets/`:

| Asset | Purpose |
|-------|---------|
| `assets/iptables-template.sh` | Production iptables ruleset: anti-spoofing, SYN flood protection, rate-limited SSH, web chains, logging, NAT support. |
| `assets/nftables-template.nft` | Equivalent nftables ruleset: named sets, dynamic SSH brute-force tracking, flowtable support, organized chains. |
| `assets/sysctl-network.conf` | Network sysctl parameters for security (rp_filter, syncookies, redirects) and performance (buffers, keepalive, congestion). |
| `assets/wireguard-template.conf` | WireGuard templates: server config, full-tunnel client, split-tunnel client, site-to-site example. |

```bash
# Apply sysctl
sudo cp assets/sysctl-network.conf /etc/sysctl.d/90-network.conf
sudo sysctl -p /etc/sysctl.d/90-network.conf

# Apply nftables
sudo nft -f assets/nftables-template.nft
```
<!-- tested: pass -->
