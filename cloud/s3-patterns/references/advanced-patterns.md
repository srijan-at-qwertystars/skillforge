# Advanced S3 Patterns

## Table of Contents

- [S3 Express One Zone](#s3-express-one-zone)
- [S3 Object Lambda](#s3-object-lambda)
- [S3 Batch Operations](#s3-batch-operations)
- [S3 Access Grants](#s3-access-grants)
- [S3 Inventory and Analytics](#s3-inventory-and-analytics)
- [Data Lake Patterns: S3 + Athena + Glue](#data-lake-patterns-s3--athena--glue)
- [S3 Event-Driven Architectures](#s3-event-driven-architectures)
- [Cost Optimization with Intelligent-Tiering](#cost-optimization-with-intelligent-tiering)
- [S3 Object Lock for Compliance](#s3-object-lock-for-compliance)
- [CloudFront Signed URLs vs S3 Presigned URLs](#cloudfront-signed-urls-vs-s3-presigned-urls)

---

## S3 Express One Zone

S3 Express One Zone uses **directory buckets** for single-digit millisecond latency, ideal for
ML training, financial modeling, media processing, and real-time analytics.

### Key Characteristics

- **Latency:** consistent single-digit ms (vs. ~tens of ms for Standard).
- **Availability zone:** data resides in one AZ — choose the same AZ as compute.
- **Naming:** bucket names end with `--<az-id>--x-s3` (e.g., `my-bucket--usw2-az1--x-s3`).
- **Authentication:** uses `CreateSession` for session-based auth; SDKs handle this automatically.
- **No versioning, lifecycle, replication, or Object Lock** — it's purpose-built for speed.

### When to Use

| Use Express One Zone | Use Standard |
|---|---|
| Latency-sensitive compute co-located in one AZ | Multi-AZ durability required |
| Temporary/intermediate processing data | Long-term storage |
| ML training data that is replicated elsewhere | Compliance/regulatory archives |

### Setup

```bash
# Create directory bucket
aws s3api create-bucket \
  --bucket my-fast-bucket--usw2-az1--x-s3 \
  --region us-west-2 \
  --create-bucket-configuration '{
    "Location": {"Type": "AvailabilityZone", "Name": "usw2-az1"},
    "Bucket": {"Type": "Directory", "DataRedundancy": "SingleAvailabilityZone"}
  }'

# Upload object
aws s3api put-object \
  --bucket my-fast-bucket--usw2-az1--x-s3 \
  --key model-weights/epoch-42.bin \
  --body epoch-42.bin
```

### Performance Tips

- Place compute (EC2, EKS, Lambda) in the same AZ as the directory bucket.
- Use VPC gateway endpoint for S3 Express — no internet traversal.
- Batch small objects into larger ones to reduce per-request overhead.
- Express One Zone supports up to 10× the baseline throughput of Standard buckets.

---

## S3 Object Lambda

Transform objects on read using a Lambda function attached to an Object Lambda Access Point.
The original object stays unchanged — the transformation is applied per-request.

### Use Cases

- Redact PII before returning data to certain consumers.
- Resize images on-the-fly based on requesting device.
- Decompress or transcode files.
- Enrich data with additional metadata.
- Convert formats (XML → JSON, CSV → Parquet).

### Architecture

```
Client → Object Lambda Access Point → Lambda Function → Supporting Access Point → S3 Bucket
```

### Setup

```python
import boto3

s3control = boto3.client('s3control')

# 1. Create supporting access point
s3control.create_access_point(
    AccountId='123456789012',
    Name='base-ap',
    Bucket='my-bucket'
)

# 2. Create Object Lambda access point
s3control.create_access_point_for_object_lambda(
    AccountId='123456789012',
    Name='redact-ap',
    Configuration={
        'SupportingAccessPoint': 'arn:aws:s3:us-west-2:123456789012:accesspoint/base-ap',
        'TransformationConfigurations': [{
            'Actions': ['GetObject'],
            'ContentTransformation': {
                'AwsLambda': {
                    'FunctionArn': 'arn:aws:lambda:us-west-2:123456789012:function:redact-pii'
                }
            }
        }]
    }
)
```

### Lambda Function Pattern

```python
import boto3
import requests

def handler(event, context):
    # Get the original object from S3
    object_context = event['getObjectContext']
    request_route = object_context['outputRoute']
    request_token = object_context['outputToken']
    s3_url = object_context['inputS3Url']

    # Fetch original object
    response = requests.get(s3_url)
    original = response.text

    # Transform: redact SSNs
    import re
    transformed = re.sub(r'\d{3}-\d{2}-\d{4}', '***-**-****', original)

    # Write transformed object back
    s3 = boto3.client('s3')
    s3.write_get_object_response(
        Body=transformed.encode(),
        RequestRoute=request_route,
        RequestToken=request_token,
        ContentType='text/plain'
    )
    return {'statusCode': 200}
```

---

## S3 Batch Operations

Run large-scale operations across billions of objects with a single API call.

### Supported Operations

- Copy objects (across buckets, regions, storage classes)
- Invoke Lambda function per object
- Replace tags / delete tags / replace ACLs
- Restore from Glacier
- Apply Object Lock retention
- Replicate existing objects (Batch Replication)

### Workflow

1. **Generate manifest:** use S3 Inventory report (CSV) or provide your own CSV/JSON manifest.
2. **Create job:** specify operation, manifest, IAM role, and priority.
3. **Confirm job:** jobs start in `Suspended` state; confirm to begin processing.
4. **Monitor:** track via completion reports and CloudWatch metrics.

```bash
# Create batch job to change storage class
aws s3control create-job \
  --account-id 123456789012 \
  --operation '{"S3PutObjectCopy":{"TargetResource":"arn:aws:s3:::my-bucket","StorageClass":"GLACIER_IR"}}' \
  --manifest '{"Spec":{"Format":"S3InventoryReport_CSV_20211130","Fields":["Bucket","Key"]},"Location":{"ObjectArn":"arn:aws:s3:::inventory-bucket/manifest.json","ETag":"abc123"}}' \
  --report '{"Bucket":"arn:aws:s3:::report-bucket","Prefix":"batch-reports/","Format":"Report_CSV_20180820","Enabled":true,"ReportScope":"AllTasks"}' \
  --role-arn arn:aws:iam::123456789012:role/s3-batch-role \
  --priority 10 \
  --confirmation-required

# Confirm the job
aws s3control update-job-status \
  --account-id 123456789012 \
  --job-id <job-id> \
  --requested-job-status Ready
```

### Cost Tips

- Batch Operations charges per object + per job. Compare cost vs. scripted approach for <10K objects.
- Use S3 Inventory as manifest source — it's cheaper than listing objects.
- Set appropriate priority when running multiple concurrent jobs.

---

## S3 Access Grants

Map identities from corporate directories (Entra ID, Okta via IAM Identity Center) to S3
locations without writing bucket policies per user.

### How It Works

1. **Create an S3 Access Grants instance** in your account.
2. **Register a location** (bucket or prefix) with an IAM role.
3. **Create grants** mapping identity (IAM principal or directory user/group) to location + permission.
4. Applications call `GetDataAccess` to obtain temporary credentials scoped to the grant.

```bash
# Create instance
aws s3control create-access-grants-instance --account-id 123456789012

# Register location
aws s3control create-access-grants-location \
  --account-id 123456789012 \
  --access-grants-location-configuration S3SubPrefix="*" \
  --iam-role-arn arn:aws:iam::123456789012:role/access-grants-role \
  --location-scope s3://my-data-lake/

# Create grant for a directory group
aws s3control create-access-grant \
  --account-id 123456789012 \
  --access-grants-location-id <location-id> \
  --access-grants-location-configuration S3SubPrefix="analytics/" \
  --grantee GranteeType=DIRECTORY_GROUP,GranteeIdentifier=<group-id> \
  --permission READWRITE
```

### When to Use

- Large organizations with many users needing scoped S3 access.
- You want to avoid managing hundreds of bucket policy statements.
- Integration with corporate identity providers is required.
- Audit trail of who accessed what data is needed (CloudTrail logs grant usage).

---

## S3 Inventory and Analytics

### S3 Inventory

Generates daily or weekly reports of objects and their metadata (size, storage class,
encryption status, replication status, etc.). Use as input for Batch Operations or cost analysis.

```bash
aws s3api put-bucket-inventory-configuration \
  --bucket my-bucket \
  --id weekly-full-inventory \
  --inventory-configuration '{
    "Id": "weekly-full-inventory",
    "IsEnabled": true,
    "Destination": {
      "S3BucketDestination": {
        "Bucket": "arn:aws:s3:::inventory-bucket",
        "Format": "CSV",
        "Prefix": "inventory/my-bucket"
      }
    },
    "Schedule": {"Frequency": "Weekly"},
    "IncludedObjectVersions": "Current",
    "OptionalFields": [
      "Size", "StorageClass", "LastModifiedDate",
      "EncryptionStatus", "ReplicationStatus", "IntelligentTieringAccessTier"
    ]
  }'
```

### Storage Class Analysis

Identifies objects that could benefit from transitioning to Infrequent Access tiers.
Generates recommendations after 30 days of observation.

```bash
aws s3api put-bucket-analytics-configuration \
  --bucket my-bucket \
  --id cost-analysis \
  --analytics-configuration '{
    "Id": "cost-analysis",
    "Filter": {"Prefix": "data/"},
    "StorageClassAnalysis": {
      "DataExport": {
        "OutputSchemaVersion": "V_1",
        "Destination": {
          "S3BucketDestination": {
            "Bucket": "arn:aws:s3:::analytics-bucket",
            "Format": "CSV",
            "Prefix": "analytics/"
          }
        }
      }
    }
  }'
```

### S3 Storage Lens

Account- or organization-level dashboard showing usage, activity, and cost optimization
recommendations across all buckets. Enable advanced metrics for prefix-level insights.

---

## Data Lake Patterns: S3 + Athena + Glue

### Architecture Overview

```
Data Sources → S3 (Raw Zone) → Glue ETL → S3 (Curated Zone) → Athena/Redshift Spectrum
                                  ↓
                            Glue Data Catalog
```

### Partitioning Strategy

Partition data in S3 by frequently-queried dimensions to minimize scan cost:

```
s3://data-lake/events/year=2024/month=12/day=15/hour=08/data.parquet
```

Register partitions in the Glue Data Catalog. Use `MSCK REPAIR TABLE` or Glue Crawlers for
partition discovery.

### File Format Best Practices

| Format | Use Case | Compression |
|---|---|---|
| Parquet | Analytical queries (columnar) | Snappy (default) |
| ORC | Hive ecosystem, heavy aggregation | Zlib |
| JSON Lines | Streaming ingestion, schema evolution | Gzip |
| CSV | Legacy compatibility, simple data | Gzip |

**Target file sizes:** 128 MB – 512 MB for optimal Athena/Spark performance. Avoid many small
files ("small file problem") — use Glue compaction jobs to merge.

### Athena Query Optimization

```sql
-- Use partition pruning
SELECT * FROM events
WHERE year = '2024' AND month = '12' AND day = '15';

-- Use columnar projection
SELECT user_id, event_type, COUNT(*)
FROM events
WHERE year = '2024'
GROUP BY user_id, event_type;

-- CTAS to materialize results in optimized format
CREATE TABLE curated.daily_summary
WITH (format = 'PARQUET', partitioned_by = ARRAY['dt'],
      external_location = 's3://curated-bucket/daily-summary/')
AS SELECT ..., date_format(event_time, '%Y-%m-%d') AS dt FROM raw.events;
```

### Glue ETL Pattern

```python
# Glue ETL script (PySpark)
from awsglue.context import GlueContext
from pyspark.context import SparkContext

sc = SparkContext()
glueContext = GlueContext(sc)

# Read from catalog
source = glueContext.create_dynamic_frame.from_catalog(
    database="raw_db", table_name="events"
)

# Transform
from awsglue.transforms import Filter, ApplyMapping
filtered = Filter.apply(frame=source, f=lambda x: x["status"] == "success")
mapped = ApplyMapping.apply(frame=filtered, mappings=[
    ("user_id", "string", "user_id", "string"),
    ("event_type", "string", "event_type", "string"),
    ("timestamp", "string", "event_time", "timestamp"),
])

# Write to curated zone as Parquet
glueContext.write_dynamic_frame.from_options(
    frame=mapped,
    connection_type="s3",
    connection_options={"path": "s3://curated-bucket/events/"},
    format="parquet"
)
```

---

## S3 Event-Driven Architectures

### Pattern 1: Fan-Out with EventBridge

```
S3 Put → EventBridge → Rule 1 → Lambda (thumbnail)
                      → Rule 2 → SQS → ECS (virus scan)
                      → Rule 3 → Step Functions (workflow)
```

EventBridge advantages over native S3 notifications:
- Content-based filtering on any event field.
- Multiple targets per rule.
- Archive and replay events.
- Cross-account / cross-region event routing.

### Pattern 2: Event Sourcing

Store immutable event objects in S3, use DynamoDB or a database for the current state view.

```
Producer → S3 (append-only event log) → Lambda → DynamoDB (materialized view)
                                       → Athena (historical queries)
```

### Pattern 3: S3 → SQS → Worker Fleet

For high-throughput processing with backpressure:

```
S3 ObjectCreated → SQS Queue (with DLQ) → EC2/ECS workers (auto-scaled on queue depth)
```

Configure SQS visibility timeout > Lambda/worker timeout to prevent duplicate processing.
Use SQS message deduplication or idempotent processing.

### Pattern 4: Step Functions Orchestration

For multi-step processing (e.g., upload → validate → transform → index):

```python
# Step Functions state machine definition (excerpt)
{
    "StartAt": "ValidateUpload",
    "States": {
        "ValidateUpload": {
            "Type": "Task",
            "Resource": "arn:aws:lambda:...:validate",
            "Next": "CheckResult"
        },
        "CheckResult": {
            "Type": "Choice",
            "Choices": [
                {"Variable": "$.valid", "BooleanEquals": True, "Next": "Transform"},
                {"Variable": "$.valid", "BooleanEquals": False, "Next": "Quarantine"}
            ]
        }
    }
}
```

---

## Cost Optimization with Intelligent-Tiering

### How Intelligent-Tiering Works

Objects move automatically between access tiers based on observed access patterns:

| Tier | Activation | Access Pattern |
|---|---|---|
| Frequent Access | Default | Recently accessed |
| Infrequent Access | Automatic (30 days) | Not accessed for 30 days |
| Archive Instant Access | Automatic (90 days) | Not accessed for 90 days |
| Archive Access | Opt-in | Not accessed for 90+ days |
| Deep Archive Access | Opt-in | Not accessed for 180+ days |

### Enabling Archive Tiers

```bash
aws s3api put-bucket-intelligent-tiering-configuration \
  --bucket my-bucket \
  --id full-tiering \
  --intelligent-tiering-configuration '{
    "Id": "full-tiering",
    "Status": "Enabled",
    "Filter": {"Prefix": "data/"},
    "Tierings": [
      {"Days": 90, "AccessTier": "ARCHIVE_ACCESS"},
      {"Days": 180, "AccessTier": "DEEP_ARCHIVE_ACCESS"}
    ]
  }'
```

### Cost Analysis Checklist

1. **Enable S3 Storage Lens** to identify per-bucket cost breakdown.
2. **Run Storage Class Analysis** for 30+ days to see access patterns.
3. **Review S3 Inventory** for object count and size distribution by storage class.
4. **Check for incomplete multipart uploads** — these accrue storage charges silently.
5. **Evaluate Intelligent-Tiering monitoring fee** ($0.0025 per 1,000 objects/month) vs savings.
6. **Set lifecycle rules** to expire old noncurrent versions and delete markers.
7. **Use S3 Batch Operations** to transition existing objects in bulk.

### When NOT to Use Intelligent-Tiering

- Objects <128 KB are not transitioned (stored in Frequent Access tier, still charged monitoring).
- If you **know** access patterns are infrequent, use STANDARD_IA or ONEZONE_IA directly.
- For write-heavy, rarely-read archives, use GLACIER or DEEP_ARCHIVE with lifecycle rules.

---

## S3 Object Lock for Compliance

Object Lock enforces WORM (Write Once Read Many) for regulatory compliance (SEC 17a-4,
FINRA, HIPAA). Requires versioning. Must be enabled at bucket creation.

### Retention Modes

- **Governance mode:** users with `s3:BypassGovernanceRetention` can delete/overwrite.
  Good for testing and soft compliance.
- **Compliance mode:** **nobody** can delete or shorten retention, including root. Irreversible.
  Use for regulatory requirements.

### Legal Hold

Separate from retention — an indefinite hold that can be placed/removed independently.
Objects under legal hold cannot be deleted regardless of retention settings.

```python
# Set retention on upload
s3.put_object(
    Bucket='compliance-bucket',
    Key='financial/report-2024.pdf',
    Body=data,
    ObjectLockMode='COMPLIANCE',
    ObjectLockRetainUntilDate='2031-12-31T00:00:00Z'
)

# Apply legal hold
s3.put_object_legal_hold(
    Bucket='compliance-bucket',
    Key='financial/report-2024.pdf',
    LegalHold={'Status': 'ON'}
)

# Set default retention for the bucket
s3.put_object_lock_configuration(
    Bucket='compliance-bucket',
    ObjectLockConfiguration={
        'ObjectLockEnabled': 'Enabled',
        'Rule': {
            'DefaultRetention': {
                'Mode': 'GOVERNANCE',
                'Days': 365
            }
        }
    }
)
```

### Compliance Checklist

- [ ] Enable Object Lock at bucket creation (cannot be added later).
- [ ] Enable versioning (required for Object Lock).
- [ ] Set default retention to avoid accidentally unlocked objects.
- [ ] Use Compliance mode for regulatory requirements — Governance for internal policies.
- [ ] Monitor with CloudTrail for lock bypass attempts.
- [ ] Test retention behavior in a separate bucket before production deployment.

---

## CloudFront Signed URLs vs S3 Presigned URLs

### Comparison

| Feature | S3 Presigned URL | CloudFront Signed URL |
|---|---|---|
| **Origin** | Direct to S3 | Via CloudFront edge |
| **Latency** | Regional | Edge-cached, global |
| **Max expiry** | 7 days (IAM user) / 12 hrs (STS) | Unlimited |
| **IP restriction** | No | Yes (signed cookies/URLs) |
| **Path patterns** | Single object | Wildcard paths with signed cookies |
| **Caching** | No edge caching | Full CloudFront caching |
| **Cost** | S3 request pricing | CloudFront pricing (often cheaper at scale) |
| **Setup complexity** | Low | Medium (key pairs, distribution) |

### When to Use Each

**Use S3 presigned URLs when:**
- Simple, short-lived access to individual objects.
- No CDN is needed (e.g., internal tools, server-to-server).
- Upload URLs (CloudFront does not support signed upload URLs natively).

**Use CloudFront signed URLs/cookies when:**
- Global audience needing low-latency access.
- Streaming media or large file downloads.
- Need IP-based restrictions.
- Wildcard path access (e.g., all files under `/premium/`).
- Want edge caching to reduce S3 costs.

### CloudFront Signed URL Example

```python
from datetime import datetime, timedelta
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
import base64

def sign_cloudfront_url(url, key_pair_id, private_key_path, expiry_hours=24):
    """Generate a CloudFront signed URL."""
    from botocore.signers import CloudFrontSigner

    def rsa_signer(message):
        with open(private_key_path, 'rb') as f:
            private_key = serialization.load_pem_private_key(f.read(), password=None)
        return private_key.sign(message, padding.PKCS1v15(), hashes.SHA1())

    cf_signer = CloudFrontSigner(key_pair_id, rsa_signer)
    expires = datetime.utcnow() + timedelta(hours=expiry_hours)
    return cf_signer.generate_presigned_url(url, date_less_than=expires)

signed = sign_cloudfront_url(
    'https://d111111abcdef8.cloudfront.net/premium/video.mp4',
    'K2JCJMDEHXQW7F',
    '/path/to/private_key.pem'
)
```

### Signed Cookies for Multi-File Access

Use signed cookies when users need access to many files (e.g., all assets for a web app):

```python
from botocore.signers import CloudFrontSigner

cf_signer = CloudFrontSigner(key_pair_id, rsa_signer)
policy = cf_signer.build_policy(
    'https://d111111abcdef8.cloudfront.net/premium/*',
    datetime.utcnow() + timedelta(hours=8)
)
cookies = cf_signer.generate_presigned_url(
    'https://d111111abcdef8.cloudfront.net/premium/*',
    policy=policy
)
# Set cookies: CloudFront-Policy, CloudFront-Signature, CloudFront-Key-Pair-Id
```
