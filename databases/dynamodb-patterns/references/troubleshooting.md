# DynamoDB Troubleshooting Guide

## Table of Contents

- [Throttling Diagnosis](#throttling-diagnosis)
- [Hot Partitions](#hot-partitions)
- [GSI Backpressure](#gsi-backpressure)
- [Scan Performance](#scan-performance)
- [Large Item Issues](#large-item-issues)
- [Transaction Conflicts](#transaction-conflicts)
- [Stream Processing Lag](#stream-processing-lag)
- [Capacity Estimation Errors](#capacity-estimation-errors)
- [Cost Optimization](#cost-optimization)
- [Common Error Codes](#common-error-codes)
- [Monitoring and Alerting](#monitoring-and-alerting)

---

## Throttling Diagnosis

### Symptoms

- `ProvisionedThroughputExceededException` errors in application logs
- CloudWatch `ThrottledRequests` metric > 0
- Elevated latency on reads/writes
- `UnprocessedItems` / `UnprocessedKeys` in batch responses

### Step-by-step diagnosis

1. **Check CloudWatch metrics** (5-minute granularity):
   - `ConsumedReadCapacityUnits` vs `ProvisionedReadCapacityUnits`
   - `ConsumedWriteCapacityUnits` vs `ProvisionedWriteCapacityUnits`
   - If consumed < provisioned but throttling occurs → hot partition (per-partition limit hit)

2. **Enable Contributor Insights**:
   ```bash
   aws dynamodb update-contributor-insights \
     --table-name MyTable \
     --contributor-insights-action ENABLE
   ```
   This shows the most-accessed and most-throttled partition keys.

3. **Check per-partition metrics**: Each partition supports up to 3,000 RCU and 1,000 WCU per second. Even with sufficient table-level capacity, one hot partition can throttle.

4. **Check GSI throttling**: GSI throttling propagates back to the base table. If a GSI is throttled, writes to the base table are also rejected.

### Resolution

| Cause | Fix |
|-------|-----|
| Table-level capacity insufficient | Increase provisioned capacity or switch to on-demand |
| Hot partition (single key) | Redesign key or add write sharding |
| Burst exceeds burst credits | Smooth traffic with SQS buffer or increase base capacity |
| GSI backpressure | Address GSI throttling (see GSI section) |
| Auto-scaling lag | Increase minimum capacity or reduce scale-in cooldown |

### Auto-scaling pitfalls

- Default scale-up takes 1-2 minutes; spikes within that window are throttled
- Scale-in cooldown defaults to 15 minutes — too aggressive settings cause oscillation
- Scale-up target utilization: set to 50-70% for headroom
- If traffic is spiky, consider on-demand mode instead

```bash
# Check current auto-scaling settings
aws application-autoscaling describe-scalable-targets \
  --service-namespace dynamodb \
  --resource-ids "table/MyTable"
```

---

## Hot Partitions

### Identification

1. **Contributor Insights** (best method):
   ```bash
   aws dynamodb describe-contributor-insights \
     --table-name MyTable
   # View in CloudWatch: DynamoDB > Contributor Insights
   ```

2. **CloudWatch per-partition metrics**: Available via the DynamoDB console under "Metrics" tab for the table.

3. **Application-side logging**: Log partition keys for throttled operations. Pattern:
   ```python
   try:
       table.put_item(Item=item)
   except ClientError as e:
       if e.response['Error']['Code'] == 'ProvisionedThroughputExceededException':
           logger.error(f"Throttled on PK={item['PK']}")
           raise
   ```

### Common causes

| Pattern | Example | Why it's hot |
|---------|---------|-------------|
| Current time bucket | `LOGS#2024-03-15` | All writes go to today |
| Popular entity | `PRODUCT#best-seller` | Millions read this item |
| Counter/accumulator | `VIEWS#homepage` | Every page view hits this key |
| Sequential ID | `ORDER#00001`, `ORDER#00002` | Nearby keys land in same partition |

### Fixes by scenario

**Read-hot key (popular item)**:
- Add DAX cache in front of reads
- Replicate the item across multiple keys (read sharding)
- Cache in application layer (Redis, local cache)

**Write-hot key (counter, event log)**:
- Write sharding: append random suffix to PK
- Buffer writes in SQS, batch-aggregate into DynamoDB
- Use a dedicated counter service (e.g., ElastiCache atomic increment)

**Time-series hot partition**:
- Pre-create future time buckets with write sharding
- Use finer-grained time buckets (per-minute vs per-day)
- Table-per-time-period pattern

---

## GSI Backpressure

### The problem

When a GSI cannot keep up with base table writes, DynamoDB throttles the base table. This is called GSI backpressure. Your writes fail even though the base table has capacity.

### Symptoms

- `ThrottledRequests` on the base table
- `ConsumedWriteCapacityUnits` on the GSI approaches its provisioned capacity
- Base table writes fail, but base table capacity is under-utilized

### Diagnosis

```bash
# Check GSI consumed capacity
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name ConsumedWriteCapacityUnits \
  --dimensions Name=TableName,Value=MyTable Name=GlobalSecondaryIndexName,Value=GSI1 \
  --start-time 2024-03-15T00:00:00Z \
  --end-time 2024-03-15T23:59:59Z \
  --period 300 \
  --statistics Sum
```

### Resolution

1. **Increase GSI write capacity**: GSI capacity is independent of base table. Match it to your write throughput.

2. **Reduce GSI write amplification**:
   - Use `KEYS_ONLY` or `INCLUDE` projection instead of `ALL`
   - Fewer projected attributes = less write volume to the GSI

3. **Remove unused GSIs**: Each GSI replicates every write. An unused GSI is pure waste.
   ```bash
   aws dynamodb update-table --table-name MyTable \
     --global-secondary-index-updates '[{"Delete":{"IndexName":"UnusedGSI"}}]'
   ```

4. **Use sparse indexes**: If only a subset of items need the GSI, make the GSI key attribute conditional. Items without the GSI key are not replicated.

5. **GSI auto-scaling**: Ensure GSI has its own auto-scaling policy:
   ```bash
   aws application-autoscaling register-scalable-target \
     --service-namespace dynamodb \
     --resource-id "table/MyTable/index/GSI1" \
     --scalable-dimension "dynamodb:index:WriteCapacityUnits" \
     --min-capacity 5 --max-capacity 1000
   ```

### GSI replication lag

GSIs are eventually consistent. During high write throughput, GSI may lag seconds behind the base table. This is normal, but if lag grows:
- GSI is throttled and falling behind
- Check GSI capacity and increase it

---

## Scan Performance

### Why scans are expensive

A `Scan` reads every item in the table (or index), consuming RCU for all data read — not just matching items. A table with 10M items and a filter returning 100 items still reads all 10M.

### Optimizing scans when unavoidable

1. **Parallel scan**: Split the table into segments and scan concurrently:
   ```python
   import concurrent.futures

   def scan_segment(segment, total_segments):
       items = []
       response = table.scan(
           Segment=segment,
           TotalSegments=total_segments,
           FilterExpression=Attr('status').eq('active')
       )
       items.extend(response['Items'])
       while 'LastEvaluatedKey' in response:
           response = table.scan(
               Segment=segment,
               TotalSegments=total_segments,
               FilterExpression=Attr('status').eq('active'),
               ExclusiveStartKey=response['LastEvaluatedKey']
           )
           items.extend(response['Items'])
       return items

   with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
       futures = [executor.submit(scan_segment, i, 10) for i in range(10)]
       all_items = []
       for f in concurrent.futures.as_completed(futures):
           all_items.extend(f.result())
   ```

2. **Projection**: Use `ProjectionExpression` to fetch only needed attributes, reducing RCU.

3. **Limit per call**: Set `Limit` to control items per page, preventing one scan from consuming all burst capacity.

4. **Rate limiting**: Add delays between scan pages to avoid throttling other traffic.

5. **Scan a GSI instead**: If the GSI has fewer items (sparse index) or fewer projected attributes, scanning it is cheaper.

### Alternatives to scans

| Need | Alternative |
|------|------------|
| Full-text search | Export to OpenSearch/Elasticsearch |
| Analytics | Export to S3 → Athena/Redshift |
| Filter by non-key attribute | Add a GSI on that attribute |
| Count all items | Maintain a counter item updated on writes |
| Data export | Use DynamoDB Export to S3 (no RCU consumed) |

---

## Large Item Issues

### Size limits

- Single item max: **400 KB** (including attribute names and values)
- `BatchWriteItem` total request: **16 MB**
- `Query`/`Scan` response: **1 MB** per page

### Symptoms of large items

- `ValidationException: Item size has exceeded the maximum allowed size`
- High RCU consumption: 1 RCU reads 4 KB; a 100 KB item costs 25 RCU
- Slow queries with few results (hitting 1 MB response limit quickly)

### Solutions

1. **Compress attribute values**:
   ```python
   import gzip, base64
   compressed = base64.b64encode(gzip.compress(json.dumps(large_data).encode()))
   item['data'] = compressed  # Store as Binary type
   ```

2. **Offload to S3**:
   ```python
   s3.put_object(Bucket='my-bucket', Key=f'items/{item_id}/data.json', Body=large_payload)
   item['dataRef'] = f's3://my-bucket/items/{item_id}/data.json'
   ```

3. **Vertical partitioning**: Split the item into multiple items:
   ```
   PK=USER#u001, SK=PROFILE      → name, email (frequently accessed)
   PK=USER#u001, SK=PREFERENCES  → notification settings (rarely accessed)
   PK=USER#u001, SK=AVATAR       → large binary data (moved to S3)
   ```

4. **Attribute name compression**: Short attribute names save space:
   ```
   Instead of: {"firstName": "John", "lastName": "Doe", "emailAddress": "..."}
   Use:        {"fn": "John", "ln": "Doe", "em": "..."}
   ```
   Trade-off: reduced readability. Document the mapping.

### Monitoring item sizes

```python
import sys
item_size = sys.getsizeof(json.dumps(item))  # Approximate
# More accurate: use dynamodb_item_size calculation
# DynamoDB counts: attribute name length + attribute value size + overhead per attribute
```

---

## Transaction Conflicts

### `TransactionCanceledException`

Transactions fail entirely if any condition check fails or any item is being modified by another transaction.

### Common causes

1. **Concurrent transactions on same item**: Two transactions target the same PK+SK
2. **Condition check failure**: `ConditionExpression` not met (item already exists, etc.)
3. **Item locked by another transaction**: DynamoDB applies pessimistic locking during transaction execution

### Handling conflicts

```python
import time
from botocore.exceptions import ClientError

def transact_with_retry(items, max_retries=5):
    for attempt in range(max_retries):
        try:
            client.transact_write_items(TransactItems=items)
            return
        except ClientError as e:
            code = e.response['Error']['Code']
            if code == 'TransactionCanceledException':
                reasons = e.response.get('CancellationReasons', [])
                # Check if it's a conflict vs condition failure
                if any(r.get('Code') == 'TransactionConflict' for r in reasons):
                    time.sleep(0.1 * (2 ** attempt))  # retry on conflict
                    continue
                else:
                    raise  # condition check failure — don't retry
            raise
    raise Exception("Transaction failed after max retries")
```

### Debugging cancellation reasons

The `CancellationReasons` array has one entry per operation in the transaction:

```python
except ClientError as e:
    if e.response['Error']['Code'] == 'TransactionCanceledException':
        reasons = e.response.get('CancellationReasons', [])
        for i, reason in enumerate(reasons):
            if reason.get('Code') != 'None':
                print(f"Operation {i} failed: {reason['Code']} - {reason.get('Message')}")
```

Codes:
- `ConditionalCheckFailed` — condition expression was false
- `TransactionConflict` — another transaction touched the same item
- `ItemCollectionSizeLimitExceeded` — LSI partition exceeded 10 GB
- `ValidationError` — malformed expression or invalid attribute

### Prevention

- Minimize transaction scope: fewer items = fewer conflict opportunities
- Avoid long-lived transactions (prepare data first, transact only at commit)
- If two services frequently conflict on the same item, redesign to avoid shared writes

---

## Stream Processing Lag

### Healthy vs unhealthy lag

- **Normal**: 100-500ms between write and Stream record availability
- **Concerning**: >5 seconds consistently
- **Critical**: >60 seconds or growing over time

### CloudWatch metrics for Streams

- `IteratorAge` (via Lambda metrics) — age of the oldest record in the batch. This is the key lag metric.
- `GetRecords.IteratorAgeMilliseconds` — similar, from DynamoDB side

### Causes of lag

| Cause | Fix |
|-------|-----|
| Lambda slow / error | Optimize Lambda, increase memory, fix errors |
| Lambda concurrency limit | Increase reserved concurrency |
| Large batch size | Reduce `BatchSize` in event source mapping |
| Lambda cold starts | Use provisioned concurrency |
| High write throughput | Increase `ParallelizationFactor` (up to 10) |
| Error retries | Fix the error; Lambda retries block the shard |

### Increasing parallelism

```bash
aws lambda update-event-source-mapping \
  --uuid <mapping-uuid> \
  --parallelization-factor 5 \
  --batch-size 100 \
  --maximum-batching-window-in-seconds 5
```

- `ParallelizationFactor`: up to 10 concurrent Lambda invocations per shard
- `BatchSize`: 1-10000 records per invocation
- `MaximumBatchingWindowInSeconds`: wait up to N seconds to fill a batch

### Handling poison records

A failing record blocks the entire shard. Configure:

```bash
aws lambda update-event-source-mapping \
  --uuid <mapping-uuid> \
  --maximum-retry-attempts 3 \
  --bisect-batch-on-function-error \
  --destination-config '{"OnFailure":{"Destination":"arn:aws:sqs:..."}}'
```

- `BisectBatchOnFunctionError`: halves the batch to isolate the bad record
- `MaximumRetryAttempts`: limits retries before sending to DLQ
- `OnFailure Destination`: SQS or SNS to capture failed records

---

## Capacity Estimation Errors

### Common mistakes

1. **Using average item size instead of max**: RCU/WCU are based on actual item sizes, rounded up to 4 KB (reads) or 1 KB (writes). A 4.1 KB item costs 2 RCU.

2. **Forgetting GSI write cost**: Every write to the base table is replicated to all GSIs. 5 GSIs = up to 6x write cost.

3. **Ignoring eventually consistent reads**: Eventually consistent reads cost half the RCU. Default for Query/Scan. Must explicitly request strong consistency.

4. **Not accounting for retries**: Throttled requests are retried by the SDK. This doubles the load during throttling events.

5. **Mixing up on-demand pricing**: On-demand costs ~5x more per request than provisioned at steady state. It's not "free auto-scaling."

### Estimation formulas

```
WCU (per second) = writes_per_second × ceil(avg_item_size_bytes / 1024)
  For transactions: × 2

RCU (per second, strongly consistent) = reads_per_second × ceil(avg_item_size_bytes / 4096)
RCU (per second, eventually consistent) = reads_per_second × ceil(avg_item_size_bytes / 4096) / 2
  For transactions: × 2

GSI WCU = base_table_WCU × (for each GSI, if item has GSI keys: ceil(gsi_item_size / 1024))

Total monthly cost (provisioned):
  = (total_WCU × $0.00065 + total_RCU × $0.00013) × 720 hours + storage
```

### Rightsizing methodology

1. Start with on-demand for 2-4 weeks
2. Analyze CloudWatch consumed capacity metrics
3. Identify p95 usage patterns
4. Set provisioned capacity at p95 + 20% headroom
5. Enable auto-scaling for burst handling
6. Review monthly and adjust

---

## Cost Optimization

### Quick wins

| Action | Savings |
|--------|---------|
| Switch reads to eventually consistent | 50% RCU reduction |
| Add ProjectionExpression to all queries | Reduces bytes read |
| Remove unused GSIs | Eliminates GSI write replication |
| Enable TTL for temporary data | Avoids manual deletes (free) |
| Compress large attributes | Reduces item size → fewer RCU/WCU |
| Move large blobs to S3 | Reduces item size dramatically |

### Reserved capacity

For stable workloads:
- 1-year commitment: ~50% savings
- 3-year commitment: ~77% savings
- Applies to base table and GSI capacity
- Purchased per region, per account

### On-demand vs provisioned decision tree

```
Is traffic predictable?
├── No → On-demand
│   ├── Spiky traffic (>10x peaks)? → On-demand
│   └── New table (unknown traffic)? → Start on-demand, switch later
└── Yes → Provisioned + auto-scaling
    ├── Steady with occasional spikes? → Provisioned, 70% target
    └── Very steady (batch jobs)? → Provisioned, consider reserved capacity
```

### Export to S3 for analytics

Instead of scanning the table (expensive), use DynamoDB Export to S3:

```bash
aws dynamodb export-table-to-point-in-time \
  --table-arn arn:aws:dynamodb:us-east-1:123456789012:table/MyTable \
  --s3-bucket my-export-bucket \
  --s3-prefix exports/ \
  --export-format DYNAMODB_JSON
```

- No RCU consumed
- Full table export for analytics
- Query with Athena/Redshift Spectrum

---

## Common Error Codes

| Error Code | Meaning | Action |
|-----------|---------|--------|
| `ProvisionedThroughputExceededException` | Capacity exceeded | Increase capacity, fix hot partitions |
| `ThrottlingException` | API-level throttle (control plane) | Retry with backoff |
| `ValidationException` | Invalid request (bad expression, oversized item) | Fix the request |
| `ConditionalCheckFailedException` | Condition expression was false | Expected flow; handle in app logic |
| `TransactionCanceledException` | Transaction condition/conflict failure | Check CancellationReasons |
| `ItemCollectionSizeLimitExceededException` | LSI partition >10 GB | Remove LSI or reduce data |
| `ResourceNotFoundException` | Table/index doesn't exist | Check table name and region |
| `ResourceInUseException` | Table being created/deleted | Wait and retry |
| `LimitExceededException` | Account limits (table count, GSI count) | Request limit increase |
| `InternalServerError` | AWS-side failure | Retry with exponential backoff |
| `RequestLimitExceeded` | Too many API calls per second | Slow down control plane calls |

### Retry strategy

```python
import time
from botocore.config import Config

# AWS SDK built-in retry (recommended)
config = Config(
    retries={'max_attempts': 10, 'mode': 'adaptive'}
)
client = boto3.client('dynamodb', config=config)

# Manual retry for custom logic
def with_retry(func, max_retries=5):
    for attempt in range(max_retries):
        try:
            return func()
        except ClientError as e:
            if e.response['Error']['Code'] in [
                'ProvisionedThroughputExceededException',
                'ThrottlingException',
                'InternalServerError'
            ]:
                time.sleep(min(2 ** attempt * 0.1, 30))
                continue
            raise
    raise Exception("Max retries exceeded")
```

---

## Monitoring and Alerting

### Essential CloudWatch alarms

```bash
# Throttling alarm (any throttling is worth investigating)
aws cloudwatch put-metric-alarm \
  --alarm-name "DynamoDB-Throttles-MyTable" \
  --metric-name ThrottledRequests \
  --namespace AWS/DynamoDB \
  --dimensions Name=TableName,Value=MyTable \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789012:alerts

# System errors alarm
aws cloudwatch put-metric-alarm \
  --alarm-name "DynamoDB-SystemErrors-MyTable" \
  --metric-name SystemErrors \
  --namespace AWS/DynamoDB \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789012:alerts

# Capacity utilization alarm (near provisioned limit)
aws cloudwatch put-metric-alarm \
  --alarm-name "DynamoDB-HighWriteCapacity-MyTable" \
  --metric-name ConsumedWriteCapacityUnits \
  --namespace AWS/DynamoDB \
  --dimensions Name=TableName,Value=MyTable \
  --statistic Average \
  --period 300 \
  --evaluation-periods 3 \
  --threshold 800 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789012:alerts
```

### Key metrics dashboard

Build a CloudWatch dashboard with:
- `ConsumedReadCapacityUnits` vs `ProvisionedReadCapacityUnits`
- `ConsumedWriteCapacityUnits` vs `ProvisionedWriteCapacityUnits`
- `ThrottledRequests` (should be 0)
- `SystemErrors` (should be 0)
- `UserErrors` (track spikes — may indicate application bugs)
- `SuccessfulRequestLatency` (p50, p99)
- `ReturnedItemCount` vs `ScannedCount` (large gap = inefficient filters)
- Stream `IteratorAge` via Lambda (should be <1000 ms)
