# Review: linux-networking

**Reviewed**: 2025-07-17
**Skill path**: `infrastructure/linux-networking/`

## Scores

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.8/5

## Structure Check

- [x] YAML frontmatter has `name` and `description` fields
- [x] Positive triggers present (Linux network configuration, firewall rules, TCP debugging, DNS troubleshooting, VPN setup, port forwarding, interface management, routing tables, network performance tuning, packet capture analysis)
- [x] Negative triggers present (NOT Windows, NOT cloud-specific AWS/Azure/GCP, NOT application-layer HTTP/2/gRPC, NOT container orchestration Kubernetes CNI/service mesh)
- [x] SKILL.md body is 478 lines (under 500 limit) ✓
- [x] Imperative voice used throughout (commands shown directly, not described passively)
- [x] Examples include input commands with inline comment output annotations
- [x] References linked from SKILL.md: `references/advanced-patterns.md`, `references/troubleshooting.md`, `references/security-hardening.md` — all present ✓
- [x] Scripts linked from SKILL.md: `scripts/net-diagnostics.sh`, `scripts/firewall-setup.sh`, `scripts/bandwidth-test.sh` — all present ✓
- [x] Assets linked from SKILL.md: `assets/iptables-template.sh`, `assets/nftables-template.nft`, `assets/sysctl-network.conf`, `assets/wireguard-template.conf` — all present ✓

## Content Check

### Commands & Flags Verified (web-searched)

| Claim | Verdict | Notes |
|-------|---------|-------|
| `ping -M do -s 1472` for PMTUD | ✅ Correct | `-M do` sets DF bit; 1472 + 28 = 1500 MTU |
| `tcp_tw_recycle` deprecated, breaks NAT | ✅ Correct | Removed in kernel 4.12; skill correctly warns "NEVER use" |
| `tcp_tw_reuse = 1` safe for outbound | ✅ Correct | Modern default is 2 (loopback only); skill sets 1 for high-perf, acceptable |
| `tcp_keepalive_time` default 7200 | ✅ Correct | 2 hours is the documented kernel default |
| GRE overhead 24 bytes → MTU 1476 | ✅ Correct | 20 (outer IP) + 4 (GRE header) = 24 |
| VXLAN overhead 50 bytes → MTU 1450 | ✅ Correct | 14 (outer Eth) + 20 (outer IP) + 8 (UDP) + 8 (VXLAN) = 50 |
| `ss -tn sport = :443` filter syntax | ✅ Correct | Valid ss filter expression |
| `somaxconn` default 128 | ✅ Correct | Historical default; modern kernels may differ but comment is accurate |
| `net.ipv4.fib_multipath_hash_policy` values 0/1/2 | ✅ Correct | L3/L4/L3+inner documented correctly |

### Gotchas & Coverage

- ✅ Warns against `tcp_tw_recycle` — critical gotcha covered
- ✅ PMTUD output explanation included ("message too long, mtu=1500")
- ✅ Firewall persistence covered (iptables-save/restore, nft -f)
- ✅ WireGuard PostUp/PostDown NAT rules included
- ✅ SSH tunneling covers local/remote/dynamic/jump host patterns
- ✅ curl timing breakdown for latency diagnosis
- ✅ Troubleshooting section has systematic layer-by-layer methodology
- ✅ Security hardening covers rp_filter, syncookies, ICMP hardening, SSH hardening
- ✅ Scripts all use `set -euo pipefail` for safety
- ✅ Scripts support `--dry-run` where destructive

### Minor Notes (not issues)

- `tcp_tw_reuse` is set to `1` in the sysctl template; modern kernels default to `2` (loopback only). Value `1` is appropriate for the stated "high-performance server" context but could note the default changed.
- The `ss -tn sport = :443` example in SKILL.md shows source port filtering; best practice is to quote the filter (`'sport = :443'`), though it works without quotes in many shells.

## Trigger Check

- **Description coverage**: Thorough — lists 20+ specific topics (ip commands, DNS, firewall, TCP/UDP, namespaces, bridges, VLANs, bonding, routing, NAT, port forwarding, MTU, performance, kernel tunables, WireGuard, SSH tunneling, curl/wget, TLS, systemd-networkd, NetworkManager)
- **Trigger phrases**: Good variety — "Linux network configuration", "firewall rules", "TCP debugging", "DNS troubleshooting", "VPN setup", "port forwarding", "interface management", "routing tables", "network performance tuning", "packet capture analysis"
- **Negative triggers**: Well-defined exclusions for Windows, cloud-provider networking, app-layer protocols, and container orchestration
- **Potential false triggers**: Low risk. "port forwarding" could overlap with SSH port forwarding skills, but the description scopes to Linux. "VPN setup" is appropriately narrowed to WireGuard/Linux context.
- **Missing trigger phrases**: Could add "iptables", "nftables", "tcpdump", "ss command", "ip route" as explicit triggers to catch more direct searches. Description is slightly long but within acceptable bounds.

## Issues

1. **Minor**: Trigger description could explicitly mention key tool names (iptables, nftables, tcpdump, ss) to improve discoverability for direct tool-name queries. Current triggers focus on task categories rather than tool names.

## Verdict

**PASS** — Exceptionally well-crafted skill. Accurate commands verified against current documentation. Comprehensive coverage from basics through advanced topics (eBPF/XDP, tc/HTB, nftables flowtables, policy routing). All references, scripts, and assets are present and properly linked. Scripts are production-quality with error handling, help text, and dry-run support. An AI could execute these commands correctly.
