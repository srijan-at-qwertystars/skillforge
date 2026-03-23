# QA Review: networking/wireguard-vpn

**Reviewer**: Copilot QA  
**Date**: 2025-07-17  
**Skill path**: `networking/wireguard-vpn/`

---

## (a) Structure

| Check | Status | Notes |
|-------|--------|-------|
| Frontmatter `name` | ✅ Pass | `wireguard-vpn` |
| Frontmatter `description` | ✅ Pass | Present with both positive and negative triggers |
| Positive triggers | ✅ Pass | Comprehensive: WireGuard, wg, wg-quick, wireguard-tools, key generation commands, wg0, AllowedIPs, topologies, Docker/K8s, cloud, split tunnel, PostUp/PostDown, MTU, DNS, key rotation |
| Negative triggers | ✅ Pass | OpenVPN-only, IPsec/IKEv2-only, Tailscale/Netbird admin, general firewall, SSH tunneling |
| Body under 500 lines | ✅ Pass | 484 lines (tight margin — 16 lines of headroom) |
| Imperative voice | ✅ Pass | "Generate all keys locally", "Set file permissions", "Enable IP forwarding", "Use `nft` over `iptables`" |
| Examples | ✅ Pass | Extensive code blocks in every section; copy-pasteable configs, commands, and scripts |
| Resources linked | ✅ Pass | Tables linking to `references/`, `scripts/`, and `assets/` with descriptions |

**Supplementary files reviewed:**

| File | Lines | Assessment |
|------|-------|------------|
| `references/advanced-patterns.md` | 637 | Excellent: multi-hop, FwMark, TCP wrappers, dynamic peers, namespaces, kernel vs userspace, fail2ban, K8s, Tailscale/Headscale |
| `references/troubleshooting.md` | 893 | Excellent: handshake failures, MTU, DNS leaks, firewall, asymmetric routing, AllowedIPs, kernel module, systemd-resolved, perf debugging, diagnostic checklist |
| `scripts/wg-genconfig.sh` | 267 | Well-structured with arg parsing, validation, PSK support, split-tunnel option |
| `scripts/wg-rotate-keys.sh` | 262 | Good: dry-run, backup, auto-apply, rollback instructions |
| `scripts/wg-status.sh` | 336 | Good: human-readable output, JSON mode, watch mode, health indicators |
| `assets/server.conf` | 71 | Production-ready template with dual-stack, MSS clamping, peer examples |
| `assets/client.conf` | 68 | Clear template with full/split/LAN-preserving tunnel options, kill switch |
| `assets/docker-compose.yml` | 108 | Complete: health checks, named peers, optional web UI, routing example |
| `assets/wg-firewall.nft` | 90 | See content issue below |

---

## (b) Content Accuracy

### Claims verified via web search

| Claim | Verified | Source |
|-------|----------|--------|
| ~4,000-line kernel module | ✅ Correct | wireguard.com, multiple analyses |
| Curve25519, ChaCha20-Poly1305, BLAKE2s, SipHash24 | ✅ Correct | Official protocol docs |
| Linux ≥5.6 inclusion | ✅ Correct | March 2020, kernel 5.6 |
| Rekeying every 2 minutes | ✅ Correct | REKEY_AFTER_TIME ≈ 120s |
| Session expires after 5 min inactivity | ✅ Correct | REJECT_AFTER_TIME |
| Clock skew tolerance ~180s | ✅ Correct | TAI64N, per protocol spec |
| Default MTU 1420 (1500 - 80 overhead) | ✅ Correct | WireGuard adds ~80 bytes headers |
| `wg syncconf` does not remove absent peers | ✅ Correct | Only adds/updates |
| PersistentKeepalive 25 for NAT | ✅ Correct | Standard recommendation |
| wireguard-go ~400-600 Mbps, boringtun ~700-900 Mbps | ✅ Reasonable | Approximate, varies by hardware |

### Inaccuracy found

**Line 410 of SKILL.md**: `"Rekeying: automatic every 2 minutes or 2^64-1 bytes."`

The limit is **2^64 - 1 messages (packets)**, not bytes. The counter increments per-packet, not per-byte. Additionally, proactive rekeying triggers at REKEY_AFTER_MESSAGES (2^60 messages); 2^64-1 is the hard REJECT_AFTER_MESSAGES ceiling. **Severity: Low** — unlikely to cause operational issues but technically incorrect.

### nftables asset bug

**`assets/wg-firewall.nft` lines 46 vs 53**: The unconditional `udp dport $WG_PORT accept` on line 46 matches all WireGuard UDP traffic. The rate-limiting rule on line 53 (`udp dport $WG_PORT ct state new limit rate 30/minute ...`) is **unreachable** — traffic is already accepted before it gets there. The rate-limit rule should come *before* the unconditional accept, or the unconditional accept should be removed. **Severity: Medium** — the rate limiting intended for anti-scan protection is silently ineffective.

### Missing gotchas

1. **`SaveConfig = true` footgun** — Not mentioned anywhere. When enabled, WireGuard overwrites the config file on interface shutdown with runtime state, silently clobbering manual edits. This is a very common surprise for new users.
2. **No guidance on `PreDown`** — While `PostUp`/`PostDown` are well-covered, `PreDown` (available in wg-quick) is not mentioned. It runs before the interface is torn down, useful for graceful cleanup.

### Examples correctness

All config examples, command examples, and scripts are syntactically correct and follow WireGuard best practices. The server/client config relationship is consistent (server AllowedIPs use /32, client uses /24 or /0). Docker Compose file is valid and uses current `lscr.io` image registry.

---

## (c) Trigger Quality

| Test query | Expected | Actual | Result |
|------------|----------|--------|--------|
| "set up WireGuard tunnel" | Trigger | Matches "WireGuard", "VPN tunnel setup" | ✅ |
| "configure wg0 interface" | Trigger | Matches "wg0 interface" | ✅ |
| "wg genkey for new peer" | Trigger | Matches "wg genkey", "peer configuration" | ✅ |
| "WireGuard AllowedIPs routing" | Trigger | Matches "AllowedIPs routing" | ✅ |
| "WireGuard in Docker" | Trigger | Matches "WireGuard in Docker/Kubernetes" | ✅ |
| "configure OpenVPN" | No trigger | Excluded by "OpenVPN-only configs" | ✅ |
| "set up IPsec tunnel" | No trigger | Excluded by "IPsec/IKEv2-only setups" | ✅ |
| "Tailscale ACL policies" | No trigger | Excluded by "Tailscale/Netbird administration" | ✅ |
| "SSH port forwarding" | No trigger | Excluded by "SSH tunneling" | ✅ |
| "iptables firewall hardening" | No trigger | Excluded by "general firewall rules unrelated to VPN" | ✅ |

The trigger description is precise and well-scoped. The positive trigger list is exhaustive without being overly broad. Negative triggers correctly carve out adjacent technologies.

---

## (d) Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | One minor inaccuracy ("bytes" should be "messages" on line 410); nftables asset has unreachable rate-limit rule. All other claims verified. |
| **Completeness** | 5 | Exceptional coverage: key gen, config format, topologies, NAT, DNS, split/full tunnel, PostUp/PostDown, IPv6, perf tuning, containers, cloud providers, monitoring, security, 11 gotchas. Two reference docs, three scripts, four assets. |
| **Actionability** | 5 | Every section has copy-pasteable examples. Config templates, ready-to-use scripts with arg parsing and help text, Docker Compose, nftables ruleset. Step-by-step procedures. |
| **Trigger Quality** | 5 | Comprehensive positive triggers covering all WireGuard concepts. Clear negative exclusions for adjacent technologies. Tested with 10 queries — all correct. |
| **Overall** | **4.75** | Average of (4 + 5 + 5 + 5) / 4 |

---

## Recommendations

1. **Fix**: Change "2^64-1 bytes" to "2^64-1 messages" on line 410 of SKILL.md.
2. **Fix**: Reorder `assets/wg-firewall.nft` so the rate-limit rule (line 53) precedes the unconditional accept (line 46), or merge them into one rule with the limit.
3. **Add**: `SaveConfig = true` gotcha in the anti-patterns section — it silently overwrites manual config edits on shutdown.
4. **Consider**: Mention `PreDown` alongside PostUp/PostDown.

---

## Verdict

**PASS** — Overall score 4.75/5.0. No dimension ≤ 2. No GitHub issues required. Minor fixes recommended but non-blocking.
