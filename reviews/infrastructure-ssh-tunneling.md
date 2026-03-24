# QA Review: ssh-tunneling

**Skill path:** `~/skillforge/infrastructure/ssh-tunneling/`
**Reviewer:** Copilot CLI (automated QA)
**Date:** 2025-07-15

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter: `name` | ✅ Pass | `name: ssh-tunneling` |
| YAML frontmatter: `description` | ✅ Pass | Multi-line, detailed |
| Positive triggers | ✅ Pass | 20+ specific keywords: `-L`, `-R`, `-D`, ProxyJump, SOCKS, ssh-keygen, ssh-agent, ControlMaster, autossh, bastion, SSH certificates, sshfs, X11, escape sequences, hardening, troubleshooting |
| Negative triggers | ✅ Pass | 5 exclusions: VPN setup, SCP/rsync, web server config, container networking, DNS configuration |
| Body ≤ 500 lines | ✅ Pass | 499 lines (tight but compliant) |
| Imperative voice | ✅ Pass | Core principles use imperative throughout ("Always prefer…", "Use ProxyJump…", "Apply least-privilege…", "Add `-N`…") |
| Examples with I/O | ✅ Pass | Every section has copy-paste code blocks with inline comments explaining expected behavior |
| References linked from SKILL.md | ✅ Pass | All 3 references, 3 scripts, and 4 assets linked in the "Additional Resources" section with table descriptions |

**Structure verdict:** All criteria met.

---

## B. Content Check (Web-Verified)

### Commands & Syntax

| Item | Skill says | Verified | Status |
|------|-----------|----------|--------|
| `-L` syntax | `ssh -L [bind_address:]local_port:remote_host:remote_port user@ssh-server` | Matches OpenSSH man page and multiple sources | ✅ |
| `-R` syntax | `ssh -R [bind_address:]remote_port:local_host:local_port user@ssh-server` | Correct | ✅ |
| `-D` syntax | `ssh -D [bind_address:]port user@ssh-server` | Correct | ✅ |
| `-J` ProxyJump | `ssh -J user@bastion user@internal-host` | Correct (OpenSSH 7.3+) | ✅ |
| Legacy ProxyCommand | `ssh -o ProxyCommand="ssh -W %h:%p user@bastion" user@host` | Correct for OpenSSH < 7.3 | ✅ |
| `ssh-keygen -t ed25519 -a 100` | Recommended key type + KDF rounds | Best practice confirmed (100-120 rounds recommended) | ✅ |
| `autossh -M 0` + ServerAliveInterval | Disables monitor port, uses SSH keepalives | Correct, best modern practice | ✅ |
| `curl --socks5-hostname` | Uses remote DNS resolution via SOCKS5 | Correct (vs `--socks5` for local DNS) | ✅ |
| ControlMaster/ControlPath | `~/.ssh/cm-%r@%h:%p` | Valid token syntax | ✅ |

### Security Recommendations

| Recommendation | Verified | Status |
|----------------|----------|--------|
| Ed25519 over RSA | Current best practice (2024/2025 consensus) | ✅ |
| ProxyJump over agent forwarding | Correct — eliminates key exposure on intermediate hosts | ✅ |
| Agent forwarding risks documented | Correct — root on intermediate host can hijack socket | ✅ |
| `ExitOnForwardFailure yes` for tunnels | Correct best practice | ✅ |
| KexAlgorithms: curve25519-sha256 | Current strong recommendation | ✅ |
| Ciphers: chacha20-poly1305, aes256-gcm | Current AEAD-only recommendation | ✅ |
| MACs: hmac-sha2-*-etm | EtM variants, current best practice | ✅ |
| fail2ban configuration | Correct syntax and settings | ✅ |

### Examples Correctness

- Local/remote/dynamic forwarding examples: All syntactically correct with realistic scenarios (DB access, SOCKS proxy, reverse tunnel)
- SSH config stanzas: Valid syntax, sensible defaults
- systemd unit files: Correct structure, appropriate `After=`, `Wants=`, `Restart=` directives
- Certificate commands (`ssh-keygen -s`, `-I`, `-n`, `-V`, `-h`): All flags verified correct
- Escape sequences table: Accurate (`~.`, `~^Z`, `~#`, `~C`, `~&`, `~?`)

### Missing Gotchas (Minor)

1. **Post-quantum KEX**: No mention of `sntrup761x25519-sha512@openssh.com` (available in OpenSSH 9+). Worth noting for forward-looking deployments.
2. **ControlPath socket length limit**: On macOS/some BSDs, Unix socket paths are limited to ~104 chars. Long hostnames + username can exceed this. Consider mentioning `%C` (connection hash) as an alternative.
3. **`-R` default bind**: The skill mentions `GatewayPorts` but could be more explicit that `-R` binds to `127.0.0.1` by default (only loopback), not all interfaces.

**Content verdict:** Technically accurate across the board. Minor enhancement opportunities only.

---

## C. Trigger Check

### Description Analysis

**Positive triggers (strength: strong)**
The description covers a comprehensive set of SSH-related keywords. A user asking about any of these topics would correctly trigger the skill: tunnels, port forwarding, jump hosts, SOCKS proxy, SSH config, key management, multiplexing, autossh, bastion, certificates, sshfs, hardening, reverse tunnels, SSH over HTTP proxy, X11 forwarding, troubleshooting.

**Negative triggers (strength: good)**
Five well-chosen exclusions prevent false triggers for adjacent topics: VPN (WireGuard/OpenVPN), SCP/rsync, web server config, container networking, DNS configuration.

**False trigger risk: Low**
The description is specific to SSH. Unlikely to falsely trigger on unrelated topics. The only borderline area would be "secure connectivity" which is quite broad, but the surrounding context (SSH-specific keywords) anchors it.

**Potential improvement:**
- Could add negative trigger for general "firewall/iptables configuration" (the skill covers fail2ban but not firewall management broadly)
- Could add negative trigger for "SSL/TLS certificate management" to disambiguate from SSH certificates

**Trigger verdict:** Strong positive coverage, good negative exclusions, low false-trigger risk.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All commands, flags, syntax, and security recommendations verified correct against current docs and best practices |
| **Completeness** | 5 | Exceptionally thorough: covers all major SSH tunneling topics in SKILL.md, with 3 deep-dive references (648 lines advanced patterns, 697 lines security, 613 lines troubleshooting), 3 executable scripts, and 4 copy-paste-ready assets |
| **Actionability** | 5 | Every concept backed by copy-paste code blocks with inline comments. Scripts are well-documented with usage examples. Assets are production-ready templates. Quick reference section at the end |
| **Trigger quality** | 4 | Strong positive coverage (20+ keywords), good negative exclusions (5). Minor room to add 1-2 more negative triggers for disambiguation |
| **Overall** | **4.75** | — |

---

## E. Issue Filing

- Overall score (4.75) ≥ 4.0: **No issues required**
- No dimension ≤ 2: **No issues required**

---

## F. Recommendations (Non-Blocking)

1. **Add post-quantum KEX note**: Mention `sntrup761x25519-sha512@openssh.com` as a forward-looking option for OpenSSH 9+ deployments.
2. **ControlPath `%C` shorthand**: Note `ControlPath ~/.ssh/cm-%C` as a shorter alternative that avoids socket path length limits.
3. **Explicit `-R` default bind**: Clarify that remote forwards bind to `127.0.0.1` by default; `0.0.0.0:` prefix + `GatewayPorts` needed for external access.
4. **Add 1-2 negative triggers**: "NOT for SSL/TLS certificate management" and "NOT for firewall/iptables administration" to reduce edge-case ambiguity.
5. **Line count buffer**: At 499/500 lines, the SKILL.md is at the limit. Consider moving the Quick Reference section to an asset if more content is added.

---

**Result: PASS** ✅
