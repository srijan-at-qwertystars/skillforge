#!/usr/bin/env bash
#
# s3-setup.sh — Create and configure an S3 bucket with production best practices.
#
# Features: versioning, default encryption (SSE-S3 or SSE-KMS), lifecycle rules,
# access logging, block public access, and optional CORS configuration.
#
# Usage:
#   ./s3-setup.sh <bucket-name> <region> [--kms-key-id <key-id>] [--logging-bucket <bucket>]
#
# Examples:
#   ./s3-setup.sh my-app-prod-data us-west-2
#   ./s3-setup.sh my-app-prod-data us-west-2 --kms-key-id alias/my-key
#   ./s3-setup.sh my-app-prod-data us-west-2 --logging-bucket my-logs-bucket
#
set -euo pipefail

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${GREEN}[STEP]${NC} $*"; }

# --- Argument parsing ---
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <bucket-name> <region> [--kms-key-id <key-id>] [--logging-bucket <bucket>]"
    exit 1
fi

BUCKET_NAME="$1"
REGION="$2"
shift 2

KMS_KEY_ID=""
LOGGING_BUCKET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kms-key-id)
            KMS_KEY_ID="$2"
            shift 2
            ;;
        --logging-bucket)
            LOGGING_BUCKET="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Validate prerequisites ---
if ! command -v aws &>/dev/null; then
    error "AWS CLI is not installed. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
    error "AWS credentials not configured. Run 'aws configure' first."
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
info "AWS Account: ${ACCOUNT_ID}"
info "Region:      ${REGION}"
info "Bucket:      ${BUCKET_NAME}"

# --- Step 1: Create bucket ---
step "Creating S3 bucket: ${BUCKET_NAME}"
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
    warn "Bucket already exists. Skipping creation."
else
    if [[ "${REGION}" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}"
    else
        aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
            --create-bucket-configuration LocationConstraint="${REGION}"
    fi
    info "Bucket created."
fi

# --- Step 2: Block all public access ---
step "Blocking all public access"
aws s3api put-public-access-block --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
info "Public access blocked."

# --- Step 3: Disable ACLs (BucketOwnerEnforced) ---
step "Enforcing bucket owner for object ownership (disabling ACLs)"
aws s3api put-bucket-ownership-controls --bucket "${BUCKET_NAME}" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
info "ACLs disabled."

# --- Step 4: Enable versioning ---
step "Enabling versioning"
aws s3api put-bucket-versioning --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled
info "Versioning enabled."

# --- Step 5: Configure default encryption ---
step "Configuring default encryption"
if [[ -n "${KMS_KEY_ID}" ]]; then
    aws s3api put-bucket-encryption --bucket "${BUCKET_NAME}" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "aws:kms",
                    "KMSMasterKeyID": "'"${KMS_KEY_ID}"'"
                },
                "BucketKeyEnabled": true
            }]
        }'
    info "Default encryption: SSE-KMS (key: ${KMS_KEY_ID}) with Bucket Key enabled."
else
    aws s3api put-bucket-encryption --bucket "${BUCKET_NAME}" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'
    info "Default encryption: SSE-S3 (AES-256)."
fi

# --- Step 6: Enforce TLS-only access via bucket policy ---
step "Enforcing TLS-only access"
POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "EnforceTLS",
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}",
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ],
            "Condition": {
                "Bool": {
                    "aws:SecureTransport": "false"
                }
            }
        }
    ]
}
EOF
)
aws s3api put-bucket-policy --bucket "${BUCKET_NAME}" --policy "${POLICY}"
info "TLS-only bucket policy applied."

# --- Step 7: Configure lifecycle rules ---
step "Configuring lifecycle rules"
LIFECYCLE=$(cat <<EOF
{
    "Rules": [
        {
            "ID": "TransitionInfrequentAccess",
            "Status": "Enabled",
            "Filter": {},
            "Transitions": [
                {
                    "Days": 90,
                    "StorageClass": "STANDARD_IA"
                }
            ]
        },
        {
            "ID": "ExpireNoncurrentVersions",
            "Status": "Enabled",
            "Filter": {},
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 30
            }
        },
        {
            "ID": "AbortIncompleteUploads",
            "Status": "Enabled",
            "Filter": {},
            "AbortIncompleteMultipartUpload": {
                "DaysAfterInitiation": 7
            }
        },
        {
            "ID": "CleanupExpiredDeleteMarkers",
            "Status": "Enabled",
            "Filter": {},
            "Expiration": {
                "ExpiredObjectDeleteMarker": true
            }
        }
    ]
}
EOF
)
aws s3api put-bucket-lifecycle-configuration --bucket "${BUCKET_NAME}" \
    --lifecycle-configuration "${LIFECYCLE}"
info "Lifecycle rules configured:"
info "  - Transition to STANDARD_IA after 90 days"
info "  - Expire noncurrent versions after 30 days"
info "  - Abort incomplete multipart uploads after 7 days"
info "  - Clean up expired delete markers"

# --- Step 8: Enable access logging (if logging bucket specified) ---
if [[ -n "${LOGGING_BUCKET}" ]]; then
    step "Enabling server access logging → ${LOGGING_BUCKET}"
    aws s3api put-bucket-logging --bucket "${BUCKET_NAME}" \
        --bucket-logging-status '{
            "LoggingEnabled": {
                "TargetBucket": "'"${LOGGING_BUCKET}"'",
                "TargetPrefix": "s3-access-logs/'"${BUCKET_NAME}"'/"
            }
        }'
    info "Access logging enabled."
else
    warn "No --logging-bucket specified. Skipping access logging setup."
    warn "Recommendation: enable access logging for production buckets."
fi

# --- Step 9: Enable CloudWatch request metrics ---
step "Enabling CloudWatch request metrics"
aws s3api put-bucket-metrics-configuration --bucket "${BUCKET_NAME}" \
    --id EntireBucket \
    --metrics-configuration '{"Id":"EntireBucket","Filter":{}}'
info "CloudWatch request metrics enabled."

# --- Summary ---
echo ""
echo "=============================================="
echo -e "${GREEN}  S3 Bucket Setup Complete${NC}"
echo "=============================================="
echo "  Bucket:       ${BUCKET_NAME}"
echo "  Region:       ${REGION}"
echo "  Versioning:   Enabled"
echo "  Encryption:   $(if [[ -n "${KMS_KEY_ID}" ]]; then echo "SSE-KMS (${KMS_KEY_ID})"; else echo "SSE-S3 (AES-256)"; fi)"
echo "  Public Access: Blocked"
echo "  ACLs:         Disabled (BucketOwnerEnforced)"
echo "  TLS:          Enforced (bucket policy)"
echo "  Logging:      $(if [[ -n "${LOGGING_BUCKET}" ]]; then echo "Enabled → ${LOGGING_BUCKET}"; else echo "Not configured"; fi)"
echo "  Lifecycle:    4 rules active"
echo "  Metrics:      CloudWatch enabled"
echo "=============================================="
