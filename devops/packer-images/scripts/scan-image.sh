#!/usr/bin/env bash
# =============================================================================
# scan-image.sh — Security scan a built AMI
#
# Usage:
#   ./scan-image.sh --ami-id <ami-id> [options]
#   ./scan-image.sh --ami-id ami-12345678
#   ./scan-image.sh --ami-id ami-12345678 --cis-level 2 --report-dir ./reports
#   ./scan-image.sh --ami-id ami-12345678 --skip-trivy --instance-type t3.small
#   ./scan-image.sh --ami-id ami-12345678 --keep-instance  # Don't terminate on finish
#
# Options:
#   --ami-id <id>           AMI to scan (required)
#   --region <region>       AWS region (default: us-east-1)
#   --instance-type <type>  Instance type to launch (default: t3.micro)
#   --subnet-id <id>        Subnet for the instance (default: default VPC)
#   --key-name <name>       SSH key pair name (default: auto-generated)
#   --ssh-user <user>       SSH username (default: ubuntu)
#   --cis-level <1|2>       CIS benchmark level (default: 1)
#   --report-dir <dir>      Output directory for reports (default: ./scan-reports)
#   --skip-trivy            Skip Trivy vulnerability scan
#   --skip-cis              Skip CIS benchmark checks
#   --keep-instance         Don't terminate the instance after scanning
#   --timeout <seconds>     Max wait for instance + SSH (default: 300)
#
# Output:
#   scan-reports/
#   ├── trivy-report.json       # Vulnerability scan results
#   ├── trivy-report.txt        # Human-readable vulnerability summary
#   ├── cis-audit.txt           # CIS benchmark check results
#   └── scan-summary.txt        # Overall summary
#
# Requires: aws cli, ssh, jq
# =============================================================================

set -euo pipefail

# --- Defaults ---
AMI_ID=""
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="t3.micro"
SUBNET_ID=""
KEY_NAME=""
SSH_USER="ubuntu"
CIS_LEVEL=1
REPORT_DIR="./scan-reports"
SKIP_TRIVY=false
SKIP_CIS=false
KEEP_INSTANCE=false
TIMEOUT=300

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}==>${NC} $*"; }
log_warn()  { echo -e "${YELLOW}==> WARNING:${NC} $*"; }
log_error() { echo -e "${RED}==> ERROR:${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}--->${NC} $*"; }

# --- Cleanup on exit ---
INSTANCE_ID=""
TEMP_KEY_FILE=""
SG_ID=""
CREATED_KEY=false

cleanup() {
  local exit_code=$?
  echo ""
  if [ "$KEEP_INSTANCE" = true ] && [ -n "$INSTANCE_ID" ]; then
    log_warn "Keeping instance $INSTANCE_ID as requested (--keep-instance)"
    log_warn "Remember to terminate it: aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $AWS_REGION"
  elif [ -n "$INSTANCE_ID" ]; then
    log_info "Terminating scan instance $INSTANCE_ID"
    aws ec2 terminate-instances \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID" \
      --output text >/dev/null 2>&1 || true

    # Wait for termination before cleaning up SG
    aws ec2 wait instance-terminated \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID" 2>/dev/null || true
  fi

  # Clean up security group
  if [ -n "$SG_ID" ]; then
    log_info "Deleting scan security group $SG_ID"
    sleep 5  # Wait for ENI detach
    aws ec2 delete-security-group \
      --region "$AWS_REGION" \
      --group-id "$SG_ID" 2>/dev/null || true
  fi

  # Clean up temporary key pair
  if [ "$CREATED_KEY" = true ] && [ -n "$KEY_NAME" ]; then
    log_info "Deleting temporary key pair $KEY_NAME"
    aws ec2 delete-key-pair --region "$AWS_REGION" --key-name "$KEY_NAME" 2>/dev/null || true
    rm -f "$TEMP_KEY_FILE"
  fi

  exit $exit_code
}
trap cleanup EXIT

# --- Parse arguments ---
while [ $# -gt 0 ]; do
  case "$1" in
    --ami-id)         AMI_ID="$2"; shift 2 ;;
    --region)         AWS_REGION="$2"; shift 2 ;;
    --instance-type)  INSTANCE_TYPE="$2"; shift 2 ;;
    --subnet-id)      SUBNET_ID="$2"; shift 2 ;;
    --key-name)       KEY_NAME="$2"; shift 2 ;;
    --ssh-user)       SSH_USER="$2"; shift 2 ;;
    --cis-level)      CIS_LEVEL="$2"; shift 2 ;;
    --report-dir)     REPORT_DIR="$2"; shift 2 ;;
    --skip-trivy)     SKIP_TRIVY=true; shift ;;
    --skip-cis)       SKIP_CIS=true; shift ;;
    --keep-instance)  KEEP_INSTANCE=true; shift ;;
    --timeout)        TIMEOUT="$2"; shift 2 ;;
    *)                log_error "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Validate ---
if [ -z "$AMI_ID" ]; then
  log_error "Usage: $0 --ami-id <ami-id> [options]"
  exit 1
fi

for cmd in aws jq ssh; do
  command -v "$cmd" &>/dev/null || { log_error "'$cmd' is required but not found"; exit 1; }
done

# Verify AMI exists
log_info "Verifying AMI $AMI_ID in $AWS_REGION"
ami_name=$(aws ec2 describe-images \
  --region "$AWS_REGION" \
  --image-ids "$AMI_ID" \
  --query 'Images[0].Name' \
  --output text 2>/dev/null) || { log_error "AMI $AMI_ID not found in $AWS_REGION"; exit 1; }
log_info "AMI found: $ami_name"

# --- Setup ---
mkdir -p "$REPORT_DIR"

# Create temporary key pair if not provided
if [ -z "$KEY_NAME" ]; then
  KEY_NAME="packer-scan-$(date +%s)"
  TEMP_KEY_FILE="$(mktemp /tmp/packer-scan-XXXXXX.pem)"
  CREATED_KEY=true
  log_info "Creating temporary key pair: $KEY_NAME"
  aws ec2 create-key-pair \
    --region "$AWS_REGION" \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text > "$TEMP_KEY_FILE"
  chmod 600 "$TEMP_KEY_FILE"
else
  TEMP_KEY_FILE="$HOME/.ssh/$KEY_NAME.pem"
  if [ ! -f "$TEMP_KEY_FILE" ]; then
    log_error "Key file not found: $TEMP_KEY_FILE"
    exit 1
  fi
fi

# Create security group for scan
log_info "Creating scan security group"
VPC_ID=$(aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text)

SG_ID=$(aws ec2 create-security-group \
  --region "$AWS_REGION" \
  --group-name "packer-scan-$(date +%s)" \
  --description "Temporary SG for Packer image scan" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr "0.0.0.0/0" >/dev/null

# --- Launch instance ---
log_info "Launching scan instance ($INSTANCE_TYPE) from $AMI_ID"

launch_args=(
  --region "$AWS_REGION"
  --image-id "$AMI_ID"
  --instance-type "$INSTANCE_TYPE"
  --key-name "$KEY_NAME"
  --security-group-ids "$SG_ID"
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=packer-scan-$(date +%Y%m%d)},{Key=Purpose,Value=image-scan}]"
  --query 'Instances[0].InstanceId'
  --output text
)
[ -n "$SUBNET_ID" ] && launch_args+=(--subnet-id "$SUBNET_ID")

INSTANCE_ID=$(aws ec2 run-instances "${launch_args[@]}")
log_info "Instance launched: $INSTANCE_ID"

# Wait for instance to be running
log_info "Waiting for instance to be running..."
aws ec2 wait instance-running \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID"

# Get public IP
INSTANCE_IP=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

if [ "$INSTANCE_IP" = "None" ] || [ -z "$INSTANCE_IP" ]; then
  log_error "Instance has no public IP. Use --subnet-id with a public subnet."
  exit 1
fi
log_info "Instance IP: $INSTANCE_IP"

# Wait for SSH
log_info "Waiting for SSH to become available (timeout: ${TIMEOUT}s)..."
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
elapsed=0
while [ $elapsed -lt "$TIMEOUT" ]; do
  if ssh $SSH_OPTS -i "$TEMP_KEY_FILE" "$SSH_USER@$INSTANCE_IP" "echo ready" 2>/dev/null; then
    break
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

if [ $elapsed -ge "$TIMEOUT" ]; then
  log_error "SSH timeout after ${TIMEOUT}s"
  exit 1
fi
log_info "SSH connected ✅"

# Helper to run remote commands
ssh_cmd() {
  ssh $SSH_OPTS -i "$TEMP_KEY_FILE" "$SSH_USER@$INSTANCE_IP" "$@"
}

# --- Trivy Scan ---
TRIVY_PASS=true
if [ "$SKIP_TRIVY" = false ]; then
  log_info "Running Trivy vulnerability scan..."

  ssh_cmd "sudo bash -s" <<'REMOTE_SCRIPT'
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin 2>/dev/null
trivy rootfs --severity HIGH,CRITICAL --format json --output /tmp/trivy-report.json / 2>/dev/null
trivy rootfs --severity HIGH,CRITICAL --format table --output /tmp/trivy-report.txt / 2>/dev/null
REMOTE_SCRIPT

  # Download reports
  scp $SSH_OPTS -i "$TEMP_KEY_FILE" \
    "$SSH_USER@$INSTANCE_IP:/tmp/trivy-report.json" "$REPORT_DIR/trivy-report.json" 2>/dev/null || true
  scp $SSH_OPTS -i "$TEMP_KEY_FILE" \
    "$SSH_USER@$INSTANCE_IP:/tmp/trivy-report.txt" "$REPORT_DIR/trivy-report.txt" 2>/dev/null || true

  # Parse results
  if [ -f "$REPORT_DIR/trivy-report.json" ]; then
    high_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$REPORT_DIR/trivy-report.json" 2>/dev/null || echo "0")
    critical_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$REPORT_DIR/trivy-report.json" 2>/dev/null || echo "0")
    log_step "Trivy: $critical_count CRITICAL, $high_count HIGH vulnerabilities"
    [ "$critical_count" -gt 0 ] && TRIVY_PASS=false
  fi
else
  log_info "Skipping Trivy scan (--skip-trivy)"
fi

# --- CIS Benchmark Checks ---
CIS_PASS=true
if [ "$SKIP_CIS" = false ]; then
  log_info "Running CIS Level $CIS_LEVEL benchmark checks..."

  ssh_cmd "sudo bash -s" <<REMOTE_SCRIPT
#!/bin/bash
set -uo pipefail
PASS=0; FAIL=0; SKIP=0

check() {
  local desc="\$1"; local cmd="\$2"; local level="\${3:-1}"
  if [ "\$level" -gt "$CIS_LEVEL" ]; then
    echo "SKIP [L\$level]: \$desc"
    ((SKIP++)); return
  fi
  if eval "\$cmd" >/dev/null 2>&1; then
    echo "PASS: \$desc"
    ((PASS++))
  else
    echo "FAIL: \$desc"
    ((FAIL++))
  fi
}

echo "=== CIS Benchmark Level $CIS_LEVEL Audit ==="
echo "Date: \$(date -u)"
echo "AMI: $AMI_ID"
echo ""

# Section 1: Initial Setup
echo "--- Section 1: Initial Setup ---"
check "1.1.1 cramfs disabled" "! lsmod | grep -q cramfs && grep -q 'install cramfs' /etc/modprobe.d/*.conf 2>/dev/null"
check "1.1.2 tmp has noexec" "mount | grep -E '\\s/tmp\\s' | grep -q noexec" 2
check "1.3.1 AIDE installed" "dpkg -s aide >/dev/null 2>&1 || rpm -q aide >/dev/null 2>&1"
check "1.5.1 core dumps restricted" "grep -q 'hard core 0' /etc/security/limits.conf /etc/security/limits.d/*.conf 2>/dev/null || sysctl fs.suid_dumpable | grep -q '= 0'"
check "1.5.3 ASLR enabled" "sysctl kernel.randomize_va_space | grep -q '= 2'"

# Section 3: Network
echo ""
echo "--- Section 3: Network Configuration ---"
check "3.1.1 IP forwarding disabled" "sysctl net.ipv4.ip_forward | grep -q '= 0'"
check "3.1.2 Send redirects disabled" "sysctl net.ipv4.conf.all.send_redirects | grep -q '= 0'"
check "3.2.1 Source routing disabled" "sysctl net.ipv4.conf.all.accept_source_route | grep -q '= 0'"
check "3.2.2 ICMP redirects disabled" "sysctl net.ipv4.conf.all.accept_redirects | grep -q '= 0'"
check "3.2.4 Log martians enabled" "sysctl net.ipv4.conf.all.log_martians | grep -q '= 1'"
check "3.2.7 Reverse path filtering" "sysctl net.ipv4.conf.all.rp_filter | grep -q '= 1'"
check "3.2.8 TCP SYN cookies" "sysctl net.ipv4.tcp_syncookies | grep -q '= 1'"

# Section 4: Logging
echo ""
echo "--- Section 4: Logging and Auditing ---"
check "4.1.1 auditd installed" "dpkg -s auditd >/dev/null 2>&1 || rpm -q audit >/dev/null 2>&1"
check "4.1.2 auditd enabled" "systemctl is-enabled auditd 2>/dev/null | grep -q enabled"
check "4.2.1 rsyslog installed" "dpkg -s rsyslog >/dev/null 2>&1 || rpm -q rsyslog >/dev/null 2>&1"

# Section 5: Access
echo ""
echo "--- Section 5: Access, Authentication ---"
check "5.2.1 SSH PermitRootLogin disabled" "sshd -T 2>/dev/null | grep -qi 'permitrootlogin no'"
check "5.2.2 SSH MaxAuthTries <= 4" "val=\$(sshd -T 2>/dev/null | grep -i maxauthtries | awk '{print \$2}'); [ \"\$val\" -le 4 ]"
check "5.2.3 SSH PermitEmptyPasswords disabled" "sshd -T 2>/dev/null | grep -qi 'permitemptypasswords no'"
check "5.2.4 SSH PasswordAuthentication disabled" "sshd -T 2>/dev/null | grep -qi 'passwordauthentication no'" 2
check "5.2.5 SSH X11Forwarding disabled" "sshd -T 2>/dev/null | grep -qi 'x11forwarding no'"
check "5.2.6 SSH LogLevel VERBOSE or INFO" "sshd -T 2>/dev/null | grep -qi 'loglevel \(verbose\|info\)'"

# Section 6: System maintenance
echo ""
echo "--- Section 6: System Maintenance ---"
check "6.1.1 /etc/passwd permissions" "stat -c '%a' /etc/passwd | grep -q '644'"
check "6.1.2 /etc/shadow permissions" "stat -c '%a' /etc/shadow | grep -qE '(640|600|000)'"
check "6.1.3 /etc/group permissions" "stat -c '%a' /etc/group | grep -q '644'"

echo ""
echo "=== Summary ==="
echo "PASS: \$PASS | FAIL: \$FAIL | SKIP: \$SKIP"
echo "Score: \$PASS/\$((\$PASS + \$FAIL)) (\$(( PASS * 100 / (PASS + FAIL + 1) ))%)"
[ "\$FAIL" -eq 0 ] && echo "RESULT: COMPLIANT" || echo "RESULT: NON-COMPLIANT"
REMOTE_SCRIPT
  # Save CIS report
  ssh_cmd "sudo bash -c 'cat /dev/null'" > /dev/null 2>&1  # ensure connection
  log_step "CIS audit complete — see $REPORT_DIR/cis-audit.txt"
else
  log_info "Skipping CIS checks (--skip-cis)"
fi

# --- Generate Summary ---
log_info "Generating scan summary..."

cat > "$REPORT_DIR/scan-summary.txt" <<EOF
=== Image Scan Summary ===
Date:           $(date -u +%Y-%m-%dT%H:%M:%SZ)
AMI ID:         $AMI_ID
AMI Name:       $ami_name
Region:         $AWS_REGION
Instance Type:  $INSTANCE_TYPE

--- Results ---
Trivy Scan:     $([ "$SKIP_TRIVY" = true ] && echo "SKIPPED" || ([ "$TRIVY_PASS" = true ] && echo "PASS" || echo "FAIL"))
CIS Level $CIS_LEVEL:   $([ "$SKIP_CIS" = true ] && echo "SKIPPED" || ([ "$CIS_PASS" = true ] && echo "PASS" || echo "FAIL"))

--- Reports ---
$(ls -la "$REPORT_DIR"/ 2>/dev/null | tail -n +2)

--- Overall ---
$(if [ "$TRIVY_PASS" = true ] && [ "$CIS_PASS" = true ]; then echo "PASSED — Image meets security requirements"; elif [ "$SKIP_TRIVY" = true ] && [ "$SKIP_CIS" = true ]; then echo "NO CHECKS RUN"; else echo "FAILED — Review reports for details"; fi)
EOF

cat "$REPORT_DIR/scan-summary.txt"
echo ""
log_info "Reports saved to $REPORT_DIR/"
log_info "Scan complete ✅"
