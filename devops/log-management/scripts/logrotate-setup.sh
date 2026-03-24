#!/usr/bin/env bash
# =============================================================================
# logrotate-setup.sh — Configure logrotate for common applications
# =============================================================================
# Sets up logrotate configurations with best-practice defaults for:
#   - Generic application logs
#   - Nginx access/error logs
#   - Docker container logs (JSON file driver)
#   - Systemd journal (journald)
#   - Custom application with reload signal
#
# Usage:
#   ./logrotate-setup.sh [OPTIONS]
#
# Options:
#   --app NAME LOG_PATH    Add custom app rotation (e.g., --app myapi /var/log/myapi/*.log)
#   --nginx                Add Nginx log rotation
#   --docker               Configure Docker log driver limits
#   --journal              Configure journald retention
#   --retention DAYS       Retention period in days (default: 14)
#   --max-size SIZE        Max file size before rotation (default: 100M)
#   --compress             Enable compression (default: yes)
#   --dry-run              Show configs without installing
#   --test                 Run logrotate in debug mode after install
#   --help                 Show this help message
#
# Examples:
#   sudo ./logrotate-setup.sh --nginx --docker --journal
#   sudo ./logrotate-setup.sh --app myapi /var/log/myapi/*.log --retention 30
#   ./logrotate-setup.sh --app webapp /opt/app/logs/*.log --dry-run
#
# Requires: root/sudo for installing to /etc/logrotate.d/
# =============================================================================
set -euo pipefail

RETENTION=14
MAX_SIZE="100M"
COMPRESS=true
DRY_RUN=false
TEST_MODE=false
APPS=()
INSTALL_NGINX=false
INSTALL_DOCKER=false
INSTALL_JOURNAL=false

usage() {
    sed -n '/^# Usage:/,/^# =====/p' "$0" | head -n -1 | sed 's/^# //'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)       APPS+=("$2:$3"); shift 3 ;;
        --nginx)     INSTALL_NGINX=true; shift ;;
        --docker)    INSTALL_DOCKER=true; shift ;;
        --journal)   INSTALL_JOURNAL=true; shift ;;
        --retention) RETENTION="$2"; shift 2 ;;
        --max-size)  MAX_SIZE="$2"; shift 2 ;;
        --compress)  COMPRESS=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --test)      TEST_MODE=true; shift ;;
        --help|-h)   usage ;;
        *)           echo "Unknown option: $1"; usage ;;
    esac
done

COMPRESS_BLOCK=""
if $COMPRESS; then
    COMPRESS_BLOCK="    compress
    delaycompress"
fi

install_config() {
    local name="$1"
    local content="$2"

    if $DRY_RUN; then
        echo "═══════════════════════════════════════════"
        echo "📄 /etc/logrotate.d/$name"
        echo "═══════════════════════════════════════════"
        echo "$content"
        echo ""
    else
        echo "$content" > "/etc/logrotate.d/$name"
        chmod 644 "/etc/logrotate.d/$name"
        echo "✅ Installed /etc/logrotate.d/$name"
    fi
}

# ---- Custom Application Logs ----
for app_spec in "${APPS[@]}"; do
    IFS=':' read -r app_name log_path <<< "$app_spec"
    config="${log_path} {
    daily
    rotate ${RETENTION}
    maxsize ${MAX_SIZE}
${COMPRESS_BLOCK}
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        # Send SIGUSR1 to reload log file handles (adjust per app)
        # pkill -USR1 -f ${app_name} 2>/dev/null || true
        :
    endscript
}"
    install_config "$app_name" "$config"
done

# ---- Nginx ----
if $INSTALL_NGINX; then
    config="/var/log/nginx/*.log {
    daily
    rotate ${RETENTION}
    maxsize ${MAX_SIZE}
${COMPRESS_BLOCK}
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        if [ -f /var/run/nginx.pid ]; then
            kill -USR1 \$(cat /var/run/nginx.pid) 2>/dev/null || true
        fi
    endscript
}"
    install_config "nginx-custom" "$config"
fi

# ---- Docker JSON File Driver ----
if $INSTALL_DOCKER; then
    docker_config='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "'"${MAX_SIZE}"'",
    "max-file": "'"${RETENTION}"'",
    "compress": "true",
    "labels": "service,environment",
    "tag": "{{.Name}}/{{.ID}}"
  }
}'

    if $DRY_RUN; then
        echo "═══════════════════════════════════════════"
        echo "📄 /etc/docker/daemon.json (merge with existing)"
        echo "═══════════════════════════════════════════"
        echo "$docker_config"
        echo ""
        echo "⚠️  After updating daemon.json, run: sudo systemctl restart docker"
    else
        if [[ -f /etc/docker/daemon.json ]]; then
            echo "⚠️  /etc/docker/daemon.json already exists. Please merge manually:"
            echo "$docker_config"
        else
            mkdir -p /etc/docker
            echo "$docker_config" > /etc/docker/daemon.json
            echo "✅ Installed /etc/docker/daemon.json"
            echo "⚠️  Restart Docker to apply: sudo systemctl restart docker"
        fi
    fi
fi

# ---- Journald ----
if $INSTALL_JOURNAL; then
    journal_config="[Journal]
Storage=persistent
SystemMaxUse=2G
SystemKeepFree=1G
MaxRetentionSec=${RETENTION}day
MaxFileSec=1day
Compress=yes
ForwardToSyslog=no
RateLimitIntervalSec=30s
RateLimitBurst=10000"

    if $DRY_RUN; then
        echo "═══════════════════════════════════════════"
        echo "📄 /etc/systemd/journald.conf.d/retention.conf"
        echo "═══════════════════════════════════════════"
        echo "$journal_config"
        echo ""
        echo "⚠️  After updating, run: sudo systemctl restart systemd-journald"
    else
        mkdir -p /etc/systemd/journald.conf.d
        echo "$journal_config" > /etc/systemd/journald.conf.d/retention.conf
        echo "✅ Installed /etc/systemd/journald.conf.d/retention.conf"
        echo "⚠️  Restart journald to apply: sudo systemctl restart systemd-journald"
    fi
fi

# ---- Test Mode ----
if $TEST_MODE && ! $DRY_RUN; then
    echo ""
    echo "🧪 Testing logrotate configuration..."
    logrotate -d /etc/logrotate.conf 2>&1 | tail -20
fi

if $DRY_RUN; then
    echo "ℹ️  Dry run complete. No files were modified."
else
    echo ""
    echo "✅ Logrotate setup complete."
    echo "   Test with: sudo logrotate -d /etc/logrotate.conf"
    echo "   Force run: sudo logrotate -f /etc/logrotate.conf"
fi
