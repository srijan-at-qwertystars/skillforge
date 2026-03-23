# Review: iptables-networking
Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5
Issues: none

Outstanding Linux firewall and networking guide with standard description format. Covers iptables fundamentals (tables/chains/targets), rule syntax (append/insert/delete, key flags, conntrack), common rules (policies, loopback, SSH rate limiting, logging), NAT (SNAT/MASQUERADE/DNAT/hairpin), nftables (tables/chains/sets/maps/verdict maps/named counters/rate limiting/NAT, migration from iptables), firewalld (zones/services/rich rules/runtime vs permanent), network namespaces (create/veth pairs/bridge/internet access), ip command reference (addresses/routes/policy routing/ARP), traffic control (TBF/HTB class-based shaping/netem latency simulation), packet flow diagram (iptables traversal path), nftables hook priorities, conntrack states/commands, persistence (iptables-persistent/nftables systemd/firewalld), debugging (LOG/TRACE/nft monitor/tcpdump), and anti-patterns (flush before policy, missing conntrack, rule ordering, backend mixing).
