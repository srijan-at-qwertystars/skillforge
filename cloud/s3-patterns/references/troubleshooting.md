# S3 Troubleshooting Guide

## Table of Contents

- [403 Access Denied Debugging](#403-access-denied-debugging)
- [Slow Uploads and Downloads](#slow-uploads-and-downloads)
- [503 Slow Down Errors](#503-slow-down-errors)
- [Presigned URL Expiry Issues](#presigned-url-expiry-issues)
- [CORS Errors with Browser Uploads](#cors-errors-with-browser-uploads)
- [Versioning and Delete Marker Confusion](#versioning-and-delete-marker-confusion)
- [Lifecycle Rule Not Executing](#lifecycle-rule-not-executing)
- [Replication Lag](#replication-lag)
- [Encryption Key Access Errors](#encryption-key-access-errors)
- [Cost Unexpectedly High](#cost-unexpectedly-high)

---

## 403 Access Denied Debugging

The most common S3 issue. Access is evaluated across **multiple layers** — a deny at any layer
blocks the request.

### Debugging Flowchart

```
403 Forbidden
  ├─ Is the bucket in the correct account/region?
  ├─ Is the object key spelled correctly (case-sensitive)?
  ├─ Check IAM policy → does the principal have s3:GetObject / s3:PutObject?
  ├─ Check bucket policy → is there an explicit Deny?
  ├─ Check Block Public Access settings
  ├─ Check ACLs (if not BucketOwnerEnforced)
  ├─ Check VPC endpoint policy (if accessing from VPC)
  ├─ Check S3 Access Point policy (if using access points)
  ├─ Check KMS key policy (if SSE-KMS encrypted)
  ├─ Check AWS Organizations SCP
  └─ Check Permission Boundaries on the IAM role
```

### Step-by-Step Diagnosis

**1. Verify the request identity**

```bash
# Who am I?
aws sts get-caller-identity

# What policies are attached?
aws iam list-attached-user-policies --user-name myuser
aws iam list-attached-role-policies --role-name myrole
```

**2. Use IAM Policy Simulator**

```bash
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:role/myrole \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::my-bucket/path/to/object.txt
```

**3. Check bucket policy for explicit denies**

```bash
aws s3api get-bucket-policy --bucket my-bucket | jq '.Policy | fromjson'
```

Look for `"Effect": "Deny"` statements. Explicit deny always overrides allow.

**4. Check Block Public Access**

```bash
aws s3api get-public-access-block --bucket my-bucket
```

If `RestrictPublicBuckets=true`, bucket policies granting access to `"Principal": "*"` are
ignored for cross-account access.

**5. Check VPC endpoint policy**

If the request originates from within a VPC with an S3 gateway endpoint, the endpoint policy
may restrict which buckets are accessible.

```bash
aws ec2 describe-vpc-endpoints --vpc-endpoint-ids vpce-1a2b3c4d \
  --query 'VpcEndpoints[0].PolicyDocument'
```

**6. Check KMS key policy (SSE-KMS)**

For KMS-encrypted objects, the caller needs `kms:Decrypt` on the key, and the key policy must
allow the caller's account/principal.

```bash
aws kms get-key-policy --key-id <key-id> --policy-name default
```

### Common 403 Scenarios

| Symptom | Likely Cause | Fix |
|---|---|---|
| Cross-account access fails | Bucket policy doesn't grant external account | Add `Principal` with external account ARN |
| Access works from console, fails from CLI | Different credentials or role | Check `aws sts get-caller-identity` |
| Access works outside VPC, fails inside | VPC endpoint policy restricts bucket | Update endpoint policy |
| PutObject succeeds, GetObject fails | Missing `s3:GetObject` in policy | Add the action to IAM or bucket policy |
| New objects from cross-account are inaccessible | Object owned by uploading account | Use `bucket-owner-full-control` ACL or enforce BucketOwnerEnforced |
| Access denied on KMS-encrypted object | Missing kms:Decrypt permission | Add KMS permissions to IAM policy and key policy |

### Enable CloudTrail for S3

CloudTrail logs all S3 API calls with request details. Check `errorCode` and `errorMessage`
for specific denial reasons:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GetObject \
  --max-results 5
```

---

## Slow Uploads and Downloads

### Diagnosis

```bash
# Test basic throughput
time aws s3 cp s3://my-bucket/test-100mb.bin /dev/null

# Check with verbose/debug output
aws s3 cp large-file.bin s3://my-bucket/ --debug 2>&1 | grep -i "speed\|throughput\|retri"
```

### Common Causes and Fixes

**1. Large files without multipart upload**

```bash
# Force multipart with smaller chunks for better parallelism
aws configure set s3.multipart_threshold 64MB
aws configure set s3.multipart_chunksize 64MB
aws configure set s3.max_concurrent_requests 20
```

**2. Cross-region transfers**

- Use Transfer Acceleration for cross-region uploads.
- Deploy compute in the same region as the bucket.

```bash
aws s3api put-bucket-accelerate-configuration \
  --bucket my-bucket \
  --accelerate-configuration Status=Enabled

# Use accelerated endpoint
aws s3 cp large.bin s3://my-bucket/ --endpoint-url https://my-bucket.s3-accelerate.amazonaws.com
```

**3. Small files in bulk**

Thousands of small files are slower than a few large files due to per-request overhead.

```bash
# Tar/compress first, then upload
tar czf bundle.tar.gz many-small-files/
aws s3 cp bundle.tar.gz s3://my-bucket/

# Or increase concurrency for s3 sync
aws configure set s3.max_concurrent_requests 50
aws s3 sync ./many-files/ s3://my-bucket/prefix/
```

**4. Network bottleneck**

- Check EC2 instance type — smaller instances have limited network bandwidth.
- Use placement groups or enhanced networking.
- Monitor with `iftop` or `nload`.

**5. SDK retry overhead**

Excessive retries indicate throttling. Check for 503 errors (see next section).

---

## 503 Slow Down Errors

S3 returns `503 SlowDown` or `ServiceUnavailable` when request rate exceeds partition capacity.

### Understanding S3 Request Limits

- **3,500 PUT/COPY/POST/DELETE** and **5,500 GET/HEAD** requests per second **per prefix**.
- S3 auto-scales but needs time (minutes to hours) for sudden traffic spikes.

### Solutions

**1. Distribute across prefixes**

```
# Bad: all objects under one prefix
s3://bucket/data/file1.json
s3://bucket/data/file2.json

# Better: distribute by hash or date
s3://bucket/data/a1/file1.json
s3://bucket/data/b3/file2.json
```

**2. Add exponential backoff with jitter**

```python
import time, random

def s3_get_with_retry(bucket, key, max_retries=5):
    for attempt in range(max_retries):
        try:
            return s3.get_object(Bucket=bucket, Key=key)
        except s3.exceptions.ClientError as e:
            if e.response['Error']['Code'] == 'SlowDown':
                delay = min(2 ** attempt + random.uniform(0, 1), 30)
                time.sleep(delay)
            else:
                raise
    raise Exception(f"Failed after {max_retries} retries")
```

**3. Use S3 Express One Zone** for workloads needing sustained high throughput.

**4. Pre-warm with gradual ramp-up** for anticipated traffic spikes.

**5. Cache with CloudFront** to reduce direct S3 GET requests.

---

## Presigned URL Expiry Issues

### Common Problems

**1. URL expired sooner than expected**

Presigned URL expiry depends on the credential type used to sign:

| Credential Type | Max Expiry |
|---|---|
| IAM user long-term credentials | 7 days (604800 seconds) |
| STS temporary credentials (assume-role) | Remaining session duration (typically ≤12 hrs) |
| EC2 instance profile | ~6 hours (credential rotation) |
| Lambda execution role | ≤15 minutes (function timeout) |

**Fix:** if you need long-lived URLs, sign with IAM user credentials, not STS/role credentials.

```python
# Use IAM user credentials explicitly for long-lived URLs
from botocore.credentials import Credentials
from botocore.config import Config

session = boto3.Session(
    aws_access_key_id='AKIA...',
    aws_secret_access_key='...'
)
s3 = session.client('s3', config=Config(signature_version='s3v4'))
url = s3.generate_presigned_url('get_object',
    Params={'Bucket': 'my-bucket', 'Key': 'file.pdf'},
    ExpiresIn=604800)  # 7 days
```

**2. URL works in one region, fails in another**

Presigned URLs are region-specific. The client must match the region used during signing.

**3. URL fails with "signature does not match"**

- Ensure `Content-Type` header in the request matches what was specified during signing.
- URL-encoded characters may be double-encoded. Use the URL as-is.
- Clock skew: requester's clock must be within 15 minutes of AWS.

**4. Upload presigned URL returns 403**

- Missing `Content-Type` in the PUT request when it was specified during signing.
- Object size exceeds conditions (if using presigned POST with conditions).

---

## CORS Errors with Browser Uploads

### Symptoms

```
Access to XMLHttpRequest at 'https://my-bucket.s3.us-west-2.amazonaws.com/...'
from origin 'https://myapp.com' has been blocked by CORS policy
```

### Fix: Configure CORS on the Bucket

```json
[
  {
    "AllowedOrigins": ["https://myapp.com", "https://staging.myapp.com"],
    "AllowedMethods": ["GET", "PUT", "POST", "HEAD"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag", "x-amz-request-id", "x-amz-id-2"],
    "MaxAgeSeconds": 3600
  }
]
```

```bash
aws s3api put-bucket-cors --bucket my-bucket \
  --cors-configuration file://cors.json
```

### Common Mistakes

| Mistake | Fix |
|---|---|
| Using `*` for AllowedOrigins in production | Specify exact origins |
| Missing `PUT` in AllowedMethods | Add `PUT` for presigned URL uploads |
| Missing `Content-Type` in AllowedHeaders | Add `Content-Type` or use `*` |
| Not exposing `ETag` header | Add to `ExposeHeaders` for multipart uploads |
| CORS config correct but still failing | Check if CloudFront is stripping/caching CORS headers |

### Browser Upload with Presigned URL

```javascript
// Correct browser upload with presigned PUT URL
const file = document.getElementById('fileInput').files[0];
const response = await fetch(presignedUrl, {
  method: 'PUT',
  headers: { 'Content-Type': file.type },
  body: file
});

// Presigned POST for more control (conditions, metadata)
const formData = new FormData();
Object.entries(presignedPostFields).forEach(([key, value]) => {
  formData.append(key, value);
});
formData.append('file', file);  // file MUST be last

const response = await fetch(presignedPostUrl, {
  method: 'POST',
  body: formData  // Do NOT set Content-Type header — browser sets it with boundary
});
```

---

## Versioning and Delete Marker Confusion

### How Delete Markers Work

When versioning is enabled, `DELETE` without a `VersionId` creates a **delete marker** — a
zero-byte object version that makes the object appear deleted. The data is still there.

```bash
# Object appears deleted (returns 404)
aws s3api head-object --bucket my-bucket --key file.txt
# An error occurred (404) when calling the HeadObject operation

# But all versions still exist
aws s3api list-object-versions --bucket my-bucket --prefix file.txt
# Shows: version v1 (data), version v2 (data), DeleteMarker (latest)
```

### Restoring a Deleted Object

```bash
# Remove the delete marker to restore the latest version
aws s3api delete-object --bucket my-bucket --key file.txt \
  --version-id <delete-marker-version-id>
```

### Common Pitfalls

**1. "I deleted everything but storage usage didn't decrease"**

Previous versions and delete markers still consume storage. Clean up with:

```bash
# List and delete all versions (DESTRUCTIVE)
aws s3api list-object-versions --bucket my-bucket \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
  --output json > versions.json
aws s3api delete-objects --bucket my-bucket --delete file://versions.json
```

Or use lifecycle rules to expire noncurrent versions:

```json
{
  "Rules": [{
    "ID": "CleanupOldVersions",
    "Status": "Enabled",
    "Filter": {},
    "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
    "ExpiredObjectDeleteMarker": true
  }]
}
```

**2. "Replication isn't replicating delete markers"**

Delete marker replication must be explicitly enabled in the replication rule:
`"DeleteMarkerReplication": {"Status": "Enabled"}`.

**3. "I can't enable versioning on an existing bucket with Object Lock"**

Object Lock requires versioning to be enabled at bucket creation time.

---

## Lifecycle Rule Not Executing

### Diagnosis Checklist

1. **Rule is `Enabled`?** Check status field.
2. **Filter matches objects?** Prefix and tag filters are AND-combined. Empty filter `{}` matches all.
3. **Minimum size for transitions?** Objects <128 KB cannot be transitioned to IA/Archive tiers.
4. **Minimum days between transitions?** Must follow the storage class waterfall:
   - STANDARD → STANDARD_IA: min 30 days
   - STANDARD_IA → GLACIER: min 30 days after transition to IA
5. **Timing:** lifecycle runs asynchronously, typically within 24–48 hours of eligibility. Not instant.
6. **Conflicting rules?** If multiple rules match, S3 applies the cheapest transition and earliest
   expiration.

### Verify Lifecycle Configuration

```bash
aws s3api get-bucket-lifecycle-configuration --bucket my-bucket
```

### Monitoring

Enable S3 CloudWatch metrics to monitor lifecycle transitions:

```bash
aws s3api put-bucket-metrics-configuration \
  --bucket my-bucket \
  --id EntireBucket \
  --metrics-configuration '{"Id":"EntireBucket","Filter":{}}'
```

Check CloudTrail for `LifecycleExpiration` events.

### Common Gotchas

| Issue | Cause | Fix |
|---|---|---|
| Objects not transitioning | Objects are <128 KB | Lifecycle silently skips these |
| Transition timing unexpected | Lifecycle runs async, not real-time | Wait 24-48 hours |
| Rule matched wrong objects | Overlapping prefixes | Review prefix filters carefully |
| Noncurrent versions not expiring | Using `Expiration` instead of `NoncurrentVersionExpiration` | Use the correct lifecycle action |
| Delete markers not cleaned up | Missing `ExpiredObjectDeleteMarker: true` | Add to lifecycle rule |

---

## Replication Lag

### Understanding Replication SLAs

- Most objects replicate within 15 minutes.
- S3 Replication Time Control (RTC) guarantees 99.99% of objects within 15 minutes (paid feature).
- Large objects or high request rates can cause longer delays.

### Monitoring Replication

```bash
# Check replication status of a specific object
aws s3api head-object --bucket source-bucket --key file.txt \
  --query 'ReplicationStatus'
# Returns: COMPLETED, PENDING, FAILED, or REPLICA

# Enable replication metrics
aws s3api put-bucket-replication --bucket source-bucket \
  --replication-configuration '{
    "Role": "arn:aws:iam::123456789012:role/replication-role",
    "Rules": [{
      "Status": "Enabled",
      "Priority": 1,
      "Filter": {},
      "Destination": {
        "Bucket": "arn:aws:s3:::dest-bucket",
        "Metrics": {"Status": "Enabled", "EventThreshold": {"Minutes": 15}},
        "ReplicationTime": {"Status": "Enabled", "Time": {"Minutes": 15}}
      },
      "DeleteMarkerReplication": {"Status": "Enabled"}
    }]
  }'
```

### Common Replication Issues

| Issue | Cause | Fix |
|---|---|---|
| `FAILED` replication status | IAM role missing permissions | Check role has s3:ReplicateObject on dest |
| Existing objects not replicated | Replication only applies to new objects | Use S3 Batch Replication |
| Delete markers not replicated | DeleteMarkerReplication disabled | Enable in replication rule |
| KMS-encrypted objects not replicating | Missing KMS permissions in replication role | Add kms:Decrypt (source) and kms:Encrypt (dest) |
| Objects in Glacier not replicating | Replication doesn't restore from Glacier | Restore first, then replicate |

---

## Encryption Key Access Errors

### SSE-KMS Errors

**"AccessDenied" when reading KMS-encrypted object:**

The caller needs **both**:
1. `kms:Decrypt` in their IAM policy.
2. The KMS key policy must allow the caller's account/principal.

```bash
# Check key policy
aws kms get-key-policy --key-id <key-id> --policy-name default

# Test decryption
aws kms decrypt --ciphertext-blob fileb://encrypted-data \
  --key-id <key-id> --query Plaintext --output text
```

**Cross-account KMS access:**

The KMS key policy in the key-owning account must grant the external account:

```json
{
  "Sid": "AllowCrossAccountDecrypt",
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::999888777666:root"},
  "Action": ["kms:Decrypt", "kms:GenerateDataKey"],
  "Resource": "*"
}
```

The external account's IAM policy must also include `kms:Decrypt` on the key ARN.

### SSE-C Errors

**"400 Bad Request" with SSE-C:**

- You must supply the exact same key for GET that was used for PUT.
- The `SSECustomerKeyMD5` must match the MD5 of the key (SDKs compute this automatically).
- SSE-C requests **must** use HTTPS.

### Bucket Default Encryption Mismatch

If a bucket enforces `aws:kms` encryption but the PUT request specifies `AES256` (SSE-S3),
the request is denied if a bucket policy enforces KMS:

```json
{
  "Condition": {
    "StringNotEquals": {"s3:x-amz-server-side-encryption": "aws:kms"}
  }
}
```

**Fix:** either change the upload to use KMS or update the bucket policy.

---

## Cost Unexpectedly High

### Diagnosis Steps

**1. Check S3 cost breakdown in Cost Explorer**

Filter by usage type to identify the cost driver:
- `TimedStorage-ByteHrs` — storage volume
- `Requests-Tier1` — PUT/COPY/POST/LIST
- `Requests-Tier2` — GET/HEAD
- `DataTransfer-Out-Bytes` — egress to internet

**2. Enable and review S3 Storage Lens**

Free tier provides 28 metrics across all buckets. Shows:
- Total storage by class
- Request counts
- Data transfer patterns
- Incomplete multipart uploads

**3. Common cost surprises**

| Surprise | Cause | Fix |
|---|---|---|
| Storage cost much higher than expected | Noncurrent versions accumulating | Add NoncurrentVersionExpiration lifecycle rule |
| High request costs | LIST operations are expensive ($0.005/1000) | Reduce `ListObjectsV2` calls; cache results |
| Data transfer costs | Cross-region or internet egress | Use CloudFront, S3 Transfer Acceleration, or VPC endpoints |
| Incomplete multipart uploads | Aborted uploads leave orphaned parts | Add `AbortIncompleteMultipartUpload` lifecycle rule |
| Glacier retrieval charges | Bulk restore with Expedited tier | Use Bulk or Standard retrieval tier |
| Intelligent-Tiering monitoring fee | Many small objects (<128 KB) | Exclude small objects or use STANDARD_IA directly |
| CloudWatch request metrics | Enabled per-prefix metrics | Disable if not needed |
| S3 Select scans | Scanning entire objects | Use Athena for complex/repeated queries |

**4. Quick cost reduction actions**

```bash
# Find and abort incomplete multipart uploads
aws s3api list-multipart-uploads --bucket my-bucket

# Check storage distribution by class
aws s3api list-buckets --query 'Buckets[].Name' --output text | \
  while read bucket; do
    echo "=== $bucket ==="
    aws cloudwatch get-metric-statistics \
      --namespace AWS/S3 --metric-name BucketSizeBytes \
      --dimensions Name=BucketName,Value=$bucket Name=StorageType,Value=StandardStorage \
      --start-time $(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%S) \
      --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
      --period 86400 --statistics Average \
      --query 'Datapoints[0].Average' --output text
  done

# Check for lifecycle rules
aws s3api get-bucket-lifecycle-configuration --bucket my-bucket 2>/dev/null || \
  echo "WARNING: No lifecycle rules configured!"
```

**5. Set up billing alerts**

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name s3-cost-alarm \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 86400 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=ServiceName,Value=AmazonS3 \
  --evaluation-periods 1 \
  --alarm-actions arn:aws:sns:us-east-1:123456789012:billing-alerts
```
