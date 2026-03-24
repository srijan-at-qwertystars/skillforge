---
name: s3-patterns
description: >
  AWS S3 object storage patterns: bucket creation, object operations (put/get/delete/copy),
  multipart upload, presigned URLs for upload and download, bucket policies, IAM policies,
  access points, versioning, MFA delete, lifecycle rules (transitions/expiration),
  storage classes (Standard/IA/Glacier/Deep Archive/Intelligent-Tiering), replication (CRR/SRR),
  event notifications (Lambda/SQS/SNS/EventBridge), S3 Select, Athena integration,
  performance optimization (prefixes/Transfer Acceleration), security (SSE-S3/SSE-KMS/SSE-C,
  VPC endpoints, access logging), static website hosting, CloudFront + S3 integration,
  and SDK usage (AWS CLI, boto3, AWS SDK JS v3).
  Use when: working with S3, object storage, presigned URLs, bucket policies, S3 lifecycle rules,
  multipart upload, S3 event notifications, CloudFront + S3 origins.
  Do NOT use for: EFS/EBS block storage, DynamoDB key-value lookups, RDS relational data,
  local filesystem operations, GCS or Azure Blob unless S3-compatible API is involved.
---

# AWS S3 Patterns

## Bucket Creation and Configuration

Create buckets with globally unique, DNS-compliant names (3-63 chars, lowercase, no underscores).
Choose the region closest to consumers to minimize latency and meet data residency requirements.

```bash
# AWS CLI
aws s3api create-bucket --bucket my-app-prod-assets \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

# Enable versioning immediately
aws s3api put-bucket-versioning --bucket my-app-prod-assets \
  --versioning-configuration Status=Enabled

# Block all public access (default for new buckets, enforce explicitly)
aws s3api put-public-access-block --bucket my-app-prod-assets \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

```python
# boto3
import boto3
s3 = boto3.client('s3', region_name='us-west-2')
s3.create_bucket(
    Bucket='my-app-prod-assets',
    CreateBucketConfiguration={'LocationConstraint': 'us-west-2'}
)
```

## Object Operations

### Put, Get, Delete, Copy

```python
# PUT
s3.put_object(Bucket='my-bucket', Key='data/file.json', Body=b'{"key":"value"}',
              ContentType='application/json')

# GET
resp = s3.get_object(Bucket='my-bucket', Key='data/file.json')
body = resp['Body'].read()

# DELETE
s3.delete_object(Bucket='my-bucket', Key='data/file.json')

# DELETE multiple (max 1000 per request)
s3.delete_objects(Bucket='my-bucket', Delete={
    'Objects': [{'Key': 'a.txt'}, {'Key': 'b.txt'}]
})

# COPY (within or across buckets)
s3.copy_object(Bucket='dest-bucket', Key='dest/file.json',
               CopySource={'Bucket': 'src-bucket', 'Key': 'src/file.json'})
```

### Multipart Upload

Use multipart for files >100 MB. Required for files >5 GB. Max 10,000 parts, each 5 MB–5 GB.

```python
# boto3 managed upload handles multipart automatically
from boto3.s3.transfer import TransferConfig
config = TransferConfig(multipart_threshold=100 * 1024 * 1024,  # 100 MB
                        max_concurrency=10,
                        multipart_chunksize=100 * 1024 * 1024)
s3.upload_file('large-file.zip', 'my-bucket', 'uploads/large-file.zip', Config=config)
```

```bash
# AWS CLI handles multipart automatically for large files
aws s3 cp large-file.zip s3://my-bucket/uploads/large-file.zip
```

## Presigned URLs

Generate server-side only. Set short expiration (default 3600s, max 7 days with IAM user creds).
Use signature v4 (`s3v4`) for all regions.

```python
from botocore.client import Config

s3 = boto3.client('s3', region_name='us-west-2',
                  config=Config(signature_version='s3v4'))

# Download URL
download_url = s3.generate_presigned_url('get_object',
    Params={'Bucket': 'my-bucket', 'Key': 'reports/q4.pdf'},
    ExpiresIn=900)  # 15 minutes

# Upload URL (PUT)
upload_url = s3.generate_presigned_url('put_object',
    Params={'Bucket': 'my-bucket', 'Key': 'uploads/user-photo.jpg',
            'ContentType': 'image/jpeg'},
    ExpiresIn=300)
# Client uploads with: curl -X PUT -H "Content-Type: image/jpeg" --data-binary @photo.jpg "<upload_url>"
```

```javascript
// AWS SDK JS v3
import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

const client = new S3Client({ region: 'us-west-2' });
const downloadUrl = await getSignedUrl(client,
  new GetObjectCommand({ Bucket: 'my-bucket', Key: 'file.pdf' }),
  { expiresIn: 900 });
const uploadUrl = await getSignedUrl(client,
  new PutObjectCommand({ Bucket: 'my-bucket', Key: 'upload/file.jpg' }),
  { expiresIn: 300 });
```

## Bucket Policies and IAM Policies

Prefer bucket policies for cross-account access and public-facing rules.
Use IAM policies for per-user/role permissions. Combine both; explicit deny always wins.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowReadFromVPC",
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::my-bucket/*",
      "Condition": {
        "StringEquals": { "aws:sourceVpce": "vpce-1a2b3c4d" }
      }
    },
    {
      "Sid": "EnforceEncryption",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::my-bucket/*",
      "Condition": {
        "StringNotEquals": { "s3:x-amz-server-side-encryption": "aws:kms" }
      }
    },
    {
      "Sid": "EnforceTLS",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::my-bucket", "arn:aws:s3:::my-bucket/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
```

## Access Control

ACLs are deprecated — disable with `BucketOwnerEnforced` object ownership setting.
Use bucket policies for bucket-wide rules. Use S3 Access Points for per-application
scoped access with dedicated hostnames and policies.

```bash
# Disable ACLs
aws s3api put-bucket-ownership-controls --bucket my-bucket \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

# Create access point
aws s3control create-access-point --account-id 123456789012 \
  --name analytics-ap --bucket my-bucket \
  --vpc-configuration VpcId=vpc-abc123
```

## Versioning and MFA Delete

Enable versioning before replication or Object Lock. Versioning cannot be disabled once enabled
(only suspended). Delete markers hide objects; permanently delete by specifying VersionId.

```bash
aws s3api put-bucket-versioning --bucket my-bucket \
  --versioning-configuration Status=Enabled,MFADelete=Enabled \
  --mfa "arn:aws:iam::123456789012:mfa/root-device 123456"
```

```python
# List object versions
versions = s3.list_object_versions(Bucket='my-bucket', Prefix='data/')
for v in versions.get('Versions', []):
    print(f"{v['Key']} | {v['VersionId']} | {v['LastModified']}")

# Permanently delete a specific version
s3.delete_object(Bucket='my-bucket', Key='data/file.json', VersionId='abc123')
```

## Lifecycle Rules

Automate transitions, expiration, and cleanup. Apply rules by prefix or tag filter.

```json
{
  "Rules": [
    {
      "ID": "ArchiveOldData",
      "Status": "Enabled",
      "Filter": { "Prefix": "logs/" },
      "Transitions": [
        { "Days": 30, "StorageClass": "STANDARD_IA" },
        { "Days": 90, "StorageClass": "GLACIER" },
        { "Days": 365, "StorageClass": "DEEP_ARCHIVE" }
      ],
      "Expiration": { "Days": 730 },
      "NoncurrentVersionTransitions": [
        { "NoncurrentDays": 30, "StorageClass": "GLACIER" }
      ],
      "NoncurrentVersionExpiration": { "NoncurrentDays": 90 },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```

```bash
aws s3api put-bucket-lifecycle-configuration --bucket my-bucket \
  --lifecycle-configuration file://lifecycle.json
```

Always set `AbortIncompleteMultipartUpload` to avoid orphaned parts accumulating cost.

## Storage Classes

| Class | Use Case | Min Duration | Retrieval |
|---|---|---|---|
| STANDARD | Frequent access | None | Instant |
| INTELLIGENT_TIERING | Unknown/changing patterns | None | Instant |
| STANDARD_IA | Infrequent, rapid access needed | 30 days | Instant |
| ONEZONE_IA | Infrequent, reproducible data | 30 days | Instant |
| GLACIER_IR | Archive, millisecond retrieval | 90 days | Instant |
| GLACIER | Archive, minutes-to-hours retrieval | 90 days | 1-12 hrs |
| DEEP_ARCHIVE | Long-term archive | 180 days | 12-48 hrs |

Set storage class at upload: `--storage-class STANDARD_IA` or use lifecycle rules.
Use Intelligent-Tiering when access patterns are unpredictable — it has no retrieval fees.

## Replication

Enable versioning on source and destination. Use IAM role with replication permissions.

```json
{
  "Role": "arn:aws:iam::123456789012:role/s3-replication-role",
  "Rules": [
    {
      "ID": "ReplicateAll",
      "Status": "Enabled",
      "Priority": 1,
      "Filter": {},
      "Destination": {
        "Bucket": "arn:aws:s3:::dest-bucket",
        "StorageClass": "STANDARD_IA"
      },
      "DeleteMarkerReplication": { "Status": "Enabled" }
    }
  ]
}
```

- **CRR (Cross-Region):** disaster recovery, latency reduction, compliance.
- **SRR (Same-Region):** log aggregation, live replication between accounts.

Replication does not replicate existing objects — use S3 Batch Replication for backfill.

## Event Notifications

Trigger on `s3:ObjectCreated:*`, `s3:ObjectRemoved:*`, `s3:ObjectRestore:*`, etc.
Filter by prefix and suffix.

```python
s3.put_bucket_notification_configuration(Bucket='my-bucket', NotificationConfiguration={
    'LambdaFunctionConfigurations': [{
        'LambdaFunctionArn': 'arn:aws:lambda:us-west-2:123456789012:function:process-upload',
        'Events': ['s3:ObjectCreated:*'],
        'Filter': {'Key': {'FilterRules': [
            {'Name': 'prefix', 'Value': 'uploads/'},
            {'Name': 'suffix', 'Value': '.jpg'}
        ]}}
    }],
    'QueueConfigurations': [{
        'QueueArn': 'arn:aws:sqs:us-west-2:123456789012:image-queue',
        'Events': ['s3:ObjectCreated:Put']
    }]
})
```

Prefer **EventBridge** for advanced routing — it receives all S3 events with richer filtering,
multiple targets, and replay capability. Enable with:

```bash
aws s3api put-bucket-notification-configuration --bucket my-bucket \
  --notification-configuration '{"EventBridgeConfiguration":{}}'
```

## S3 Select and Athena

Use S3 Select for simple queries on individual CSV/JSON/Parquet objects.
Use Athena for SQL across entire datasets (schema-on-read over S3).

```python
resp = s3.select_object_content(
    Bucket='my-bucket', Key='data/sales.csv',
    ExpressionType='SQL',
    Expression="SELECT s.product, s.revenue FROM S3Object s WHERE CAST(s.revenue AS FLOAT) > 1000",
    InputSerialization={'CSV': {'FileHeaderInfo': 'USE'}, 'CompressionType': 'GZIP'},
    OutputSerialization={'JSON': {}}
)
for event in resp['Payload']:
    if 'Records' in event:
        print(event['Records']['Payload'].decode())
```

## Performance Optimization

- **Prefix distribution:** S3 scales per-prefix (3,500 PUT/5,500 GET per second per prefix).
  Distribute keys across prefixes for high-throughput workloads.
- **Multipart upload:** parallelize large uploads across threads/connections.
- **Byte-range fetches:** download parts of objects in parallel with `Range` header.
- **Transfer Acceleration:** route uploads through CloudFront edge locations.

```python
# Enable Transfer Acceleration
s3.put_bucket_accelerate_configuration(
    Bucket='my-bucket', AccelerateConfiguration={'Status': 'Enabled'})

# Use accelerated endpoint
s3_accel = boto3.client('s3', endpoint_url='https://my-bucket.s3-accelerate.amazonaws.com')
s3_accel.upload_file('bigfile.tar.gz', 'my-bucket', 'uploads/bigfile.tar.gz')
```

- **S3 Express One Zone:** use directory buckets for single-digit-ms latency workloads.
- **ListObjects pagination:** always paginate; never list unbounded. Use `StartAfter` for ordering.

## Security

### Encryption

- **SSE-S3 (default):** AES-256, AWS-managed keys. Zero config — enabled by default on new buckets.
- **SSE-KMS:** AWS KMS keys. Provides audit trail via CloudTrail and key rotation control.
- **SSE-C:** customer-provided keys. You manage key material; supply key on every request.

```python
# SSE-KMS
s3.put_object(Bucket='my-bucket', Key='secret.dat', Body=data,
              ServerSideEncryption='aws:kms', SSEKMSKeyId='alias/my-key')

# SSE-C
import hashlib, base64, os
key = os.urandom(32)
s3.put_object(Bucket='my-bucket', Key='encrypted.dat', Body=data,
              SSECustomerAlgorithm='AES256',
              SSECustomerKey=base64.b64encode(key).decode(),
              SSECustomerKeyMD5=base64.b64encode(hashlib.md5(key).digest()).decode())
```

### VPC Endpoints

Use gateway endpoints for S3 (free, no NAT needed). Restrict bucket access to VPC endpoint
via bucket policy condition `aws:sourceVpce`.

### Access Logging

Enable server access logging to a separate logging bucket. Do not log to the same bucket.

```bash
aws s3api put-bucket-logging --bucket my-bucket --bucket-logging-status '{
  "LoggingEnabled": {"TargetBucket": "my-logs-bucket", "TargetPrefix": "s3-access/"}
}'
```

## Static Website Hosting and CloudFront

```bash
# Enable static hosting
aws s3 website s3://my-bucket --index-document index.html --error-document error.html
```

Use CloudFront with Origin Access Control (OAC) — not legacy OAI.
Keep bucket private; grant access only through CloudFront.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::my-bucket/*",
    "Condition": {
      "StringEquals": {
        "AWS:SourceArn": "arn:aws:cloudfront::123456789012:distribution/EDFDVBD6EXAMPLE"
      }
    }
  }]
}
```

Set Cache-Control headers on objects. Use CloudFront Functions or Lambda@Edge
for URL rewrites, auth, or header manipulation.

## SDK Quick Reference

```bash
# AWS CLI common operations
aws s3 ls s3://my-bucket/prefix/ --recursive
aws s3 sync ./local-dir s3://my-bucket/prefix/ --delete --exclude "*.tmp"
aws s3 mv s3://my-bucket/old-key s3://my-bucket/new-key
aws s3 cp s3://my-bucket/file.txt - | head  # stream to stdout
aws s3api head-object --bucket my-bucket --key file.txt  # metadata only
```

```javascript
// AWS SDK JS v3 — put and get
import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
const client = new S3Client({ region: 'us-west-2' });

await client.send(new PutObjectCommand({
  Bucket: 'my-bucket', Key: 'data.json',
  Body: JSON.stringify({ key: 'value' }),
  ContentType: 'application/json'
}));

const { Body } = await client.send(new GetObjectCommand({
  Bucket: 'my-bucket', Key: 'data.json'
}));
const text = await Body.transformToString();
```
