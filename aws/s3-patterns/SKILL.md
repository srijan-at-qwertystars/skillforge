---
name: s3-patterns
description:
  positive: "Use when user works with AWS S3, asks about bucket configuration, object storage, presigned URLs, S3 lifecycle policies, S3 security (bucket policies, ACLs), multipart upload, S3 Express, or S3 event notifications."
  negative: "Do NOT use for R2/Cloudflare storage (use cloudflare-workers skill), MinIO, or general object storage without AWS S3 context."
---

# AWS S3 Patterns and Best Practices

## S3 Fundamentals

- **Buckets**: Globally unique containers for objects. Scoped to a region. Flat namespace internally.
- **Objects**: Files stored in buckets. Max size 5 TiB. Identified by key (full path).
- **Keys**: The unique identifier for an object within a bucket. Use `/` delimiters for logical hierarchy.
- **Regions**: Choose region closest to users or compute. Data never leaves region unless explicitly replicated.
- **Consistency model**: Strong read-after-write consistency for all operations (PUT, DELETE, LIST) since December 2020. No eventual consistency caveats remain.

## Bucket Configuration

```bash
# Create bucket
aws s3api create-bucket --bucket my-app-prod-assets \
  --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning --bucket my-app-prod-assets \
  --versioning-configuration Status=Enabled

# Enable default encryption (SSE-S3)
aws s3api put-bucket-encryption --bucket my-app-prod-assets \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]
  }'

# Enable access logging
aws s3api put-bucket-logging --bucket my-app-prod-assets \
  --bucket-logging-status '{
    "LoggingEnabled": {"TargetBucket": "my-app-logs", "TargetPrefix": "s3-access/"}
  }'
```

- **Naming**: Use lowercase, DNS-compliant names. Include environment and purpose (e.g., `myco-prod-uploads`).
- **Versioning**: Enable for production buckets. Required for replication and Object Lock.
- **Tags**: Tag buckets with `Environment`, `Team`, `CostCenter` for billing and policy scoping.

## Security

### Bucket Policies

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnforceHTTPS",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::my-bucket", "arn:aws:s3:::my-bucket/*"],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}
    },
    {
      "Sid": "DenyUnencryptedUploads",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::my-bucket/*",
      "Condition": {"StringNotEquals": {"s3:x-amz-server-side-encryption": "aws:kms"}}
    }
  ]
}
```

### Block Public Access

```bash
# Enable all four Block Public Access settings (do this on every bucket)
aws s3api put-public-access-block --bucket my-bucket \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### Key Principles

- Enable Block Public Access at the account level as the default.
- Prefer IAM policies over bucket policies for same-account access. Use bucket policies for cross-account.
- Never use ACLs for new buckets — use bucket-owner-enforced ownership.
- Use VPC endpoints (gateway type, free) to keep S3 traffic off the public internet.
- Enable MFA Delete on versioned buckets storing critical data.
- Use S3 Access Points to scope policies per application or team.

## Presigned URLs

### Download

```typescript
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const client = new S3Client({ region: "us-east-1" });
const url = await getSignedUrl(client,
  new GetObjectCommand({ Bucket: "my-bucket", Key: "reports/q4.pdf" }),
  { expiresIn: 3600 } // 1 hour
);
```

### Upload

```typescript
import { PutObjectCommand } from "@aws-sdk/client-s3";

const url = await getSignedUrl(client,
  new PutObjectCommand({
    Bucket: "my-bucket",
    Key: `uploads/${userId}/${crypto.randomUUID()}.jpg`,
    ContentType: "image/jpeg",
  }),
  { expiresIn: 600 }
);
// Client PUTs directly to this URL
```

### POST Policies (Browser Form Uploads)

```typescript
import { createPresignedPost } from "@aws-sdk/s3-presigned-post";

const { url, fields } = await createPresignedPost(client, {
  Bucket: "my-bucket",
  Key: "uploads/${filename}",
  Conditions: [
    ["content-length-range", 0, 10_000_000],       // max 10 MB
    ["starts-with", "$Content-Type", "image/"],     // images only
  ],
  Expires: 600,
});
```

- Set the shortest feasible expiration. Default to 15 minutes for uploads, 1 hour for downloads.
- Presigned URLs inherit the signer's permissions — scope IAM roles tightly.
- Always set `ContentType` on upload presigned URLs to prevent MIME confusion.

## Storage Classes

| Class | Use Case | Availability | Min Duration |
|-------|----------|-------------|-------------|
| **Standard** | Frequent access | 99.99% | None |
| **Intelligent-Tiering** | Unknown/changing access patterns | 99.9% | None |
| **Standard-IA** | Infrequent access, rapid retrieval | 99.9% | 30 days |
| **One Zone-IA** | Non-critical infrequent data | 99.5% | 30 days |
| **Glacier Instant** | Archive with ms retrieval | 99.9% | 90 days |
| **Glacier Flexible** | Archive, minutes–hours retrieval | 99.99% | 90 days |
| **Glacier Deep Archive** | Compliance/long-term, 12-hour retrieval | 99.99% | 180 days |
| **Express One Zone** | Ultra-low latency, high throughput | 99.95% | 1 hour |

- Use S3 Storage Class Analysis to identify transition candidates — run for 30+ days before acting.
- Intelligent-Tiering has no retrieval fees — use it when access patterns are unpredictable.
- Standard-IA has a minimum object size charge of 128 KB. Do not store small objects there.

## Lifecycle Policies

```json
{
  "Rules": [
    {
      "ID": "TransitionAndExpire",
      "Status": "Enabled",
      "Filter": {"Prefix": "logs/"},
      "Transitions": [
        {"Days": 30, "StorageClass": "STANDARD_IA"},
        {"Days": 90, "StorageClass": "GLACIER"}
      ],
      "Expiration": {"Days": 365}
    },
    {
      "ID": "CleanupMultipart",
      "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    },
    {
      "ID": "ExpireOldVersions",
      "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "NoncurrentVersionTransitions": [
        {"NoncurrentDays": 30, "StorageClass": "GLACIER"}
      ],
      "NoncurrentVersionExpiration": {"NoncurrentDays": 90}
    }
  ]
}
```

- Always add an `AbortIncompleteMultipartUpload` rule — orphaned parts accumulate cost silently.
- Use `NoncurrentVersionExpiration` on versioned buckets to prevent unbounded storage growth.
- Transitions must respect minimum storage duration or incur early deletion charges.
- Use object tags in filters for fine-grained lifecycle control across mixed data in one bucket.

## Multipart Upload

```typescript
import {
  CreateMultipartUploadCommand,
  UploadPartCommand,
  CompleteMultipartUploadCommand,
  AbortMultipartUploadCommand,
} from "@aws-sdk/client-s3";

// 1. Initiate
const { UploadId } = await client.send(
  new CreateMultipartUploadCommand({ Bucket: "my-bucket", Key: "large-file.zip" })
);

// 2. Upload parts in parallel (min 5 MB per part, except last)
const partSize = 10 * 1024 * 1024; // 10 MB
const parts = [];
for (let i = 0; i < totalParts; i++) {
  const { ETag } = await client.send(new UploadPartCommand({
    Bucket: "my-bucket", Key: "large-file.zip",
    UploadId, PartNumber: i + 1,
    Body: fileChunks[i],
  }));
  parts.push({ ETag, PartNumber: i + 1 });
}

// 3. Complete
await client.send(new CompleteMultipartUploadCommand({
  Bucket: "my-bucket", Key: "large-file.zip",
  UploadId,
  MultipartUpload: { Parts: parts },
}));
```

```bash
# CLI multipart (automatic for large files)
aws s3 cp large-file.zip s3://my-bucket/ --expected-size 5368709120
```

- Use multipart for objects > 100 MB. Required for objects > 5 GB.
- Upload parts in parallel (4–8 concurrent connections) for maximum throughput.
- Always implement abort logic in error handlers — incomplete uploads accrue storage costs.
- Use `@aws-sdk/lib-storage` `Upload` class for managed multipart with progress tracking.

## Performance Optimization

### Prefix Partitioning

S3 supports 5,500 GET/HEAD and 3,500 PUT/DELETE requests per second per prefix. Distribute keys:

```
# Bad — single prefix hot spot
uploads/file1.jpg
uploads/file2.jpg

# Good — distributed by hash or date
uploads/a1b2/file1.jpg
uploads/c3d4/file2.jpg
```

### Byte-Range Fetches

```typescript
// Download only first 1 MB of a file
const resp = await client.send(new GetObjectCommand({
  Bucket: "my-bucket", Key: "large-dataset.parquet",
  Range: "bytes=0-1048575",
}));
```

- Use byte-range fetches for parallel download of large objects or reading file headers.
- Enable S3 Transfer Acceleration for cross-region uploads (uses CloudFront edge network).
- Use S3 Select or Athena to query data in place instead of downloading entire objects.

```bash
# Enable Transfer Acceleration
aws s3api put-bucket-accelerate-configuration --bucket my-bucket \
  --accelerate-configuration Status=Enabled

# Upload via accelerate endpoint
aws s3 cp file.zip s3://my-bucket/ --endpoint-url https://my-bucket.s3-accelerate.amazonaws.com
```

## S3 Express One Zone

Directory buckets for single-digit millisecond latency with up to 10x performance over Standard.

```bash
# Create directory bucket (name must end with --azid--x-s3)
aws s3api create-bucket --bucket my-express-bucket--use1-az4--x-s3 \
  --region us-east-1 \
  --create-bucket-configuration '{
    "Location": {"Type": "AvailabilityZone", "Name": "use1-az4"},
    "Bucket": {"Type": "Directory", "DataRedundancy": "SingleAvailabilityZone"}
  }'
```

- **Use cases**: ML training data, real-time analytics, HPC scratch, media processing.
- **Performance**: Up to 200K reads + 100K writes/sec per bucket (requestable higher limits).
- **Sessions**: Uses session-based auth via `CreateSession` — SDK handles this automatically.
- **Cost**: 85% lower request costs and 31% lower storage cost per GB vs Standard for high-throughput workloads.
- **Limitation**: Single AZ — not for data requiring multi-AZ durability. No lifecycle transitions, no versioning, no replication.
- Co-locate compute (EC2, Lambda, EKS) in the same AZ as the directory bucket.

## Event Notifications

### S3 → Lambda

```bash
aws s3api put-bucket-notification-configuration --bucket my-bucket \
  --notification-configuration '{
    "LambdaFunctionConfigurations": [{
      "LambdaFunctionArn": "arn:aws:lambda:us-east-1:123456789012:function:ProcessUpload",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {"FilterRules": [
          {"Name": "prefix", "Value": "uploads/"},
          {"Name": "suffix", "Value": ".jpg"}
        ]}
      }
    }]
  }'
```

### S3 → EventBridge

```bash
# Enable EventBridge notifications (supports all S3 events + advanced filtering)
aws s3api put-bucket-notification-configuration --bucket my-bucket \
  --notification-configuration '{"EventBridgeConfiguration": {}}'
```

- Prefer EventBridge over direct SQS/SNS for complex routing, filtering, and replay.
- Use prefix and suffix filters to reduce invocations and cost.
- Lambda destination requires a resource-based policy granting S3 `lambda:InvokeFunction`.
- Use SQS for fan-out to multiple consumers or when you need message buffering.

## Static Website Hosting

```bash
aws s3 website s3://my-site-bucket/ \
  --index-document index.html \
  --error-document error.html
```

- Always front with CloudFront — provides HTTPS, caching, WAF, and hides the S3 origin.
- Use Origin Access Control (OAC) instead of Origin Access Identity (OAI) for CloudFront → S3.
- Set `Cache-Control` headers on objects. Use content hashing in filenames for cache busting.
- Configure redirect rules in the website configuration or use CloudFront Functions for routing.

## Cross-Region Replication (CRR)

```bash
aws s3api put-bucket-replication --bucket my-source-bucket \
  --replication-configuration '{
    "Role": "arn:aws:iam::123456789012:role/S3ReplicationRole",
    "Rules": [{
      "Status": "Enabled",
      "Priority": 1,
      "Filter": {"Prefix": ""},
      "Destination": {
        "Bucket": "arn:aws:s3:::my-dest-bucket",
        "StorageClass": "STANDARD_IA"
      },
      "DeleteMarkerReplication": {"Status": "Enabled"}
    }]
  }'
```

- Versioning must be enabled on both source and destination buckets.
- Same-Region Replication (SRR) works identically — use for log aggregation or compliance copies.
- Delete marker replication is optional — enable for true bi-directional sync.
- Replication does not retroactively copy existing objects — use S3 Batch Operations for backfill.
- Replication Time Control (RTC) guarantees 99.99% of objects replicate within 15 minutes.

## SDK Patterns (AWS SDK v3)

### Streaming

```typescript
import { Readable } from "stream";

const response = await client.send(
  new GetObjectCommand({ Bucket: "b", Key: "k" })
);
// response.Body is a Readable stream in Node.js
const stream = response.Body as Readable;
stream.pipe(fs.createWriteStream("/tmp/output"));
```

### Pagination

```typescript
import { paginateListObjectsV2 } from "@aws-sdk/client-s3";

for await (const page of paginateListObjectsV2(
  { client, pageSize: 1000 },
  { Bucket: "my-bucket", Prefix: "data/" }
)) {
  for (const obj of page.Contents ?? []) {
    console.log(obj.Key, obj.Size);
  }
}
```

### Retry Configuration

```typescript
const client = new S3Client({
  region: "us-east-1",
  maxAttempts: 5,
  retryMode: "adaptive", // exponential backoff with token bucket
});
```

- Always use SDK v3 (`@aws-sdk/client-s3`) — v2 is in maintenance mode.
- Use `@aws-sdk/lib-storage` `Upload` for managed multipart with progress events.
- Use `adaptive` retry mode for high-throughput applications.
- Destroy S3Client when done in short-lived processes to avoid connection leaks.

## Cost Optimization

- **Storage class transitions**: Move infrequently accessed data to IA/Glacier via lifecycle rules.
- **Intelligent-Tiering**: Use for data with unpredictable access — no retrieval fees, small monitoring fee.
- **Abort incomplete multipart uploads**: Lifecycle rule saves hidden storage costs.
- **Request costs**: GET is cheaper than LIST. Cache listing results. Avoid polling with LIST.
- **Data transfer**: Use VPC endpoints (free for gateway). Use CloudFront for repeated downloads.
- **S3 Storage Lens**: Monitor cost drivers across accounts and buckets with free and advanced tiers.
- **Object size**: Aggregate small objects into archives. S3 charges per-request and has 128 KB min for IA.
- **Compression**: Gzip/Zstd objects before upload to reduce storage and transfer costs.

## Anti-Patterns

| Anti-Pattern | Why It's Bad | Do This Instead |
|---|---|---|
| Millions of small objects (< 1 KB) | High per-request cost, poor throughput | Batch into larger objects or use DynamoDB |
| `ListObjects` to check existence | Slow, expensive, eventually consistent listing | Use `HeadObject` — single O(1) call |
| Public bucket ACLs | Security risk, data exposure | CloudFront + OAC, presigned URLs |
| No default encryption | Data at rest exposed | Enable SSE-KMS or SSE-S3 on every bucket |
| Sequential key names | Hot partition, throttling | Random/hashed prefixes |
| No lifecycle rules | Unbounded storage growth, orphaned parts | Add transition + expiration + abort rules |
| Polling S3 for new objects | Wasteful, slow, expensive | Use S3 Event Notifications or EventBridge |
| Hardcoded bucket names | Breaks across environments | Use SSM Parameter Store or env vars |
| Syncing entire buckets client-side | Bandwidth waste | Use `aws s3 sync --delete` or rsync patterns |
| Ignoring 503 SlowDown errors | Request failures cascade | Implement exponential backoff, spread prefixes |

<!-- tested: pass -->
