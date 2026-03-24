#!/usr/bin/env bash
# =============================================================================
# iptables-template.sh — Production iptables Ruleset Template
# =============================================================================
# Usage: sudo bash iptables-template.sh
#
# This template provides a hardened iptables configuration with:
#   - Default deny on INPUT and FORWARD
#   - Anti-spoofing rules
#   - SYN flood protection
#   - ICMP rate limiting
#   - Logging for dropped/rejected packets
#   - Separate chains for SSH, web, and management traffic
#
# Customize the variables below before applying.
# =============================================================================

# ── Configuration ────────────────────────────────────────────────────────────

SSH_PORT="22"
WEB_PORTS="80,443"
MGMT_SUBNET="10.0.0.0/8"        # Subnet allowed for management access
EXT_IFACE="eth0"                  # External-facing interface
INT_IFACE=""                      # Internal interface (leave empty if none)
ENABLE_NAT=false                  # Set to true for NAT/masquerade
NAT_SOURCE=""                     # e.g., 192.168.0.0/16

# ── Flush existing rules ────────────────────────────────────────────────────

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# ── Default policies ────────────────────────────────────────────────────────

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# ── Loopback ────────────────────────────────────────────────────────────────

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# ── Connection tracking ─────────────────────────────────────────────────────

iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP

# ── Anti-spoofing ───────────────────────────────────────────────────────────

# Drop packets with impossible source addresses on external interface
iptables -A INPUT -i "$EXT_IFACE" -s 127.0.0.0/8 -j DROP
iptables -A INPUT -i "$EXT_IFACE" -s 0.0.0.0/8 -j DROP
iptables -A INPUT -i "$EXT_IFACE" -s 169.254.0.0/16 -j DROP
iptables -A INPUT -i "$EXT_IFACE" -s 224.0.0.0/4 -j DROP
iptables -A INPUT -i "$EXT_IFACE" -s 240.0.0.0/4 -j DROP

# Drop incoming packets claiming to be from the server's own IP
# (uncomment and set SERVER_IP)
# iptables -A INPUT -i "$EXT_IFACE" -s $SERVER_IP -j DROP

# ── SYN flood protection ────────────────────────────────────────────────────

iptables -N SYN_FLOOD 2>/dev/null || iptables -F SYN_FLOOD
iptables -A SYN_FLOOD -p tcp --syn -m limit --limit 30/s --limit-burst 60 -j RETURN
iptables -A SYN_FLOOD -p tcp --syn -m limit --limit 1/s -j LOG --log-prefix "SYN-FLOOD: " --log-level 4
iptables -A SYN_FLOOD -j DROP

iptables -A INPUT -p tcp --syn -j SYN_FLOOD

# ── ICMP ────────────────────────────────────────────────────────────────────

iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s --limit-burst 10 -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT
iptables -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
iptables -A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT
iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT

# ── SSH ─────────────────────────────────────────────────────────────────────

iptables -N SSH_RULES 2>/dev/null || iptables -F SSH_RULES
# Rate limit: max 4 new connections per minute per source
iptables -A SSH_RULES -m conntrack --ctstate NEW -m recent --set --name SSH_RATE
iptables -A SSH_RULES -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 5 --name SSH_RATE \
  -j LOG --log-prefix "SSH-BRUTE: " --log-level 4
iptables -A SSH_RULES -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 5 --name SSH_RATE -j DROP
iptables -A SSH_RULES -j ACCEPT

iptables -A INPUT -p tcp --dport "$SSH_PORT" -j SSH_RULES

# ── Web services ────────────────────────────────────────────────────────────

iptables -N WEB_RULES 2>/dev/null || iptables -F WEB_RULES
iptables -A WEB_RULES -m conntrack --ctstate NEW -m limit --limit 100/s --limit-burst 200 -j ACCEPT
iptables -A WEB_RULES -m conntrack --ctstate NEW -j DROP

for port in ${WEB_PORTS//,/ }; do
    iptables -A INPUT -p tcp --dport "$port" -j WEB_RULES
done

# ── Management (restricted by source subnet) ────────────────────────────────

if [[ -n "$MGMT_SUBNET" ]]; then
    iptables -N MGMT_RULES 2>/dev/null || iptables -F MGMT_RULES
    iptables -A MGMT_RULES -j ACCEPT

    # Add management services here (e.g., monitoring agents, databases)
    # iptables -A INPUT -p tcp --dport 9090 -s "$MGMT_SUBNET" -j MGMT_RULES
    # iptables -A INPUT -p tcp --dport 3306 -s "$MGMT_SUBNET" -j MGMT_RULES
fi

# ── FORWARD chain (if routing/NAT) ──────────────────────────────────────────

if [[ -n "$INT_IFACE" ]]; then
    iptables -A FORWARD -i "$INT_IFACE" -o "$EXT_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$EXT_IFACE" -o "$INT_IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi

# ── NAT ─────────────────────────────────────────────────────────────────────

if $ENABLE_NAT && [[ -n "$NAT_SOURCE" ]]; then
    iptables -t nat -A POSTROUTING -s "$NAT_SOURCE" -o "$EXT_IFACE" -j MASQUERADE
fi

# ── Logging ─────────────────────────────────────────────────────────────────

# Log remaining dropped packets (rate-limited)
iptables -A INPUT -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "IPT-INPUT-DROP: " --log-level 4
iptables -A FORWARD -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "IPT-FWD-DROP: " --log-level 4

# ── Final drop (explicit, matches policy) ───────────────────────────────────

iptables -A INPUT -j DROP
iptables -A FORWARD -j DROP

# ── Save rules ──────────────────────────────────────────────────────────────

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

echo "iptables rules applied and saved to /etc/iptables/rules.v4"
echo "Rule count: $(iptables -L -n | grep -cE '^(ACCEPT|DROP|REJECT|LOG|RETURN)')"
