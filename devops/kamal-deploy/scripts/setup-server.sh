#!/usr/bin/env bash
#
# setup-server.sh — Prepare a fresh Ubuntu/Debian server for Kamal 2 deployments
#
# Usage:
#   ./setup-server.sh <server-ip> [ssh-user] [deploy-user]
#
# Arguments:
#   server-ip    IP address or hostname of the target server
#   ssh-user     User to SSH as initially (default: root)
#   deploy-user  User to create for deployments (default: deploy)
#
# Prerequisites:
#   - SSH key-based access to the server as ssh-user
#   - Target server runs Ubuntu 22.04+ or Debian 12+
#
# What this script does:
#   1. Updates system packages
#   2. Installs Docker (official repository)
#   3. Creates a deploy user with Docker access
#   4. Configures SSH hardening
#   5. Sets up UFW firewall (ports 22, 80, 443)
#   6. Installs fail2ban
#   7. Enables automatic security updates

set -euo pipefail

# --- Configuration ---
SERVER="${1:?Usage: $0 <server-ip> [ssh-user] [deploy-user]}"
SSH_USER="${2:-root}"
DEPLOY_USER="${3:-deploy}"
SSH_PORT=22
LOCAL_SSH_KEY="${HOME}/.ssh/id_ed25519.pub"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

# --- Pre-flight checks ---
if [[ ! -f "$LOCAL_SSH_KEY" ]]; then
    err "SSH public key not found at $LOCAL_SSH_KEY"
    echo "Generate one with: ssh-keygen -t ed25519"
    exit 1
fi

echo "============================================"
echo " Kamal Server Setup"
echo "============================================"
echo " Server:      $SERVER"
echo " SSH User:    $SSH_USER"
echo " Deploy User: $DEPLOY_USER"
echo " SSH Key:     $LOCAL_SSH_KEY"
echo "============================================"
echo ""
read -rp "Continue? (y/N) " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new ${SSH_USER}@${SERVER}"

# --- Step 1: System Update ---
log "Updating system packages..."
$SSH_CMD "DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get upgrade -y -qq"

# --- Step 2: Install Docker ---
log "Installing Docker..."
$SSH_CMD bash <<'DOCKER_INSTALL'
set -euo pipefail

if command -v docker &>/dev/null; then
    echo "Docker already installed: $(docker --version)"
else
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repo
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin

    systemctl enable docker
    systemctl start docker
    echo "Docker installed: $(docker --version)"
fi
DOCKER_INSTALL

# --- Step 3: Configure Docker daemon ---
log "Configuring Docker daemon..."
$SSH_CMD bash <<'DOCKER_CONFIG'
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "live-restore": true
}
EOF
systemctl restart docker
DOCKER_CONFIG

# --- Step 4: Create deploy user ---
log "Creating deploy user '${DEPLOY_USER}'..."
$SSH_CMD bash <<DEPLOY_USER_SETUP
set -euo pipefail

if id "${DEPLOY_USER}" &>/dev/null; then
    echo "User '${DEPLOY_USER}' already exists"
else
    adduser --disabled-password --gecos "Kamal Deploy" "${DEPLOY_USER}"
fi

# Add to docker group
usermod -aG docker "${DEPLOY_USER}"

# Set up SSH directory
mkdir -p /home/${DEPLOY_USER}/.ssh
chmod 700 /home/${DEPLOY_USER}/.ssh
DEPLOY_USER_SETUP

# Copy SSH key to deploy user
log "Copying SSH key to deploy user..."
SSH_PUB_KEY=$(cat "$LOCAL_SSH_KEY")
$SSH_CMD bash <<COPY_KEY
set -euo pipefail
echo "${SSH_PUB_KEY}" >> /home/${DEPLOY_USER}/.ssh/authorized_keys
sort -u /home/${DEPLOY_USER}/.ssh/authorized_keys -o /home/${DEPLOY_USER}/.ssh/authorized_keys
chmod 600 /home/${DEPLOY_USER}/.ssh/authorized_keys
chown -R ${DEPLOY_USER}:${DEPLOY_USER} /home/${DEPLOY_USER}/.ssh
COPY_KEY

# --- Step 5: SSH Hardening ---
log "Hardening SSH configuration..."
$SSH_CMD bash <<'SSH_HARDEN'
set -euo pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"

# Apply hardened settings via drop-in config
cat > /etc/ssh/sshd_config.d/99-kamal-hardening.conf <<EOF
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF

# Validate config before restart
sshd -t && systemctl restart ssh
echo "SSH hardened successfully"
SSH_HARDEN

# --- Step 6: Firewall (UFW) ---
log "Configuring firewall..."
$SSH_CMD bash <<'UFW_SETUP'
set -euo pipefail

apt-get install -y -qq ufw

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

echo "y" | ufw enable
ufw status verbose
UFW_SETUP

# --- Step 7: Fail2ban ---
log "Installing fail2ban..."
$SSH_CMD bash <<'FAIL2BAN'
set -euo pipefail

apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF

systemctl enable fail2ban
systemctl restart fail2ban
echo "fail2ban configured"
FAIL2BAN

# --- Step 8: Automatic security updates ---
log "Enabling automatic security updates..."
$SSH_CMD bash <<'AUTO_UPDATES'
set -euo pipefail
apt-get install -y -qq unattended-upgrades
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/51auto-upgrades
dpkg-reconfigure -plow unattended-upgrades || true
AUTO_UPDATES

# --- Step 9: Create swap (if none exists) ---
log "Checking swap..."
$SSH_CMD bash <<'SWAP_CHECK'
if [ "$(swapon --show | wc -l)" -eq 0 ]; then
    echo "Creating 2G swap file..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "Swap created"
else
    echo "Swap already configured"
fi
SWAP_CHECK

# --- Verification ---
echo ""
echo "============================================"
log "Server setup complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Test SSH as deploy user:"
echo "     ssh ${DEPLOY_USER}@${SERVER}"
echo ""
echo "  2. Test Docker access:"
echo "     ssh ${DEPLOY_USER}@${SERVER} 'docker ps'"
echo ""
echo "  3. Configure deploy.yml with:"
echo "     ssh:"
echo "       user: ${DEPLOY_USER}"
echo ""
echo "  4. Run first deploy:"
echo "     kamal setup"
echo ""

# Quick verification
log "Verifying setup..."
ssh -o StrictHostKeyChecking=accept-new "${DEPLOY_USER}@${SERVER}" "docker --version && echo 'SSH + Docker: OK'" && \
    log "Verification passed!" || \
    warn "Verification failed — check SSH access for '${DEPLOY_USER}'"
