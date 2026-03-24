# AWS Lambda Troubleshooting Guide

Diagnosis, debugging, and resolution of common AWS Lambda issues.

---

## Table of Contents

- [1. Cold Start Diagnosis and Mitigation](#1-cold-start-diagnosis-and-mitigation)
- [2. Timeout Debugging](#2-timeout-debugging)
- [3. Memory Tuning](#3-memory-tuning)
- [4. VPC Connectivity Issues](#4-vpc-connectivity-issues)
- [5. Permission Errors](#5-permission-errors)
- [6. Package Size Limits and Layer Conflicts](#6-package-size-limits-and-layer-conflicts)
- [7. Dependency Packaging](#7-dependency-packaging)
- [8. CloudWatch Logs Troubleshooting](#8-cloudwatch-logs-troubleshooting)
- [9. X-Ray Trace Analysis](#9-x-ray-trace-analysis)
- [10. Event Source Mapping Failures](#10-event-source-mapping-failures)
- [11. Concurrent Execution Throttling](#11-concurrent-execution-throttling)

---

## 1. Cold Start Diagnosis and Mitigation

Cold starts occur when Lambda initializes a new execution environment, adding latency on first invocation or after inactivity. The `InitDuration` field in the `REPORT` log line signals a cold start.

```bash
aws logs filter-log-events \
  --log-group-name "/aws/lambda/my-function" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --filter-pattern "InitDuration" \
  --query 'events[*].message' --output text
```

**CloudWatch Logs Insights — cold start stats:**

```
fields @timestamp, @message
| filter @message like /InitDuration/
| parse @message "InitDuration: * ms" as initDuration
| stats count() as coldStarts, avg(initDuration) as avgInit,
        max(initDuration) as maxInit, pct(initDuration, 99) as p99Init
  by bin(1h)
```

**X-Ray:** Cold starts appear as an `Initialization` subsegment showing runtime startup, extension init, and handler module loading time.

**Powertools cold_start metric:**

```python
from aws_lambda_powertools import Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit

metrics = Metrics(namespace="MyApp", service="OrderService")
tracer = Tracer()

@metrics.log_metrics
@tracer.capture_lambda_handler
def handler(event, context):
    metrics.add_metric(name="ColdStart", unit=MetricUnit.Count,
                       value=1 if tracer.provider._is_cold_start else 0)
```

### Mitigation Strategies

- **Provisioned Concurrency** — pre-initializes environments:
  ```bash
  aws lambda put-provisioned-concurrency-config \
    --function-name my-function --qualifier my-alias \
    --provisioned-concurrent-executions 10
  ```
- **SnapStart (Java)** — snapshots initialized environment:
  ```bash
  aws lambda update-function-configuration \
    --function-name my-java-function --snap-start ApplyOn=PublishedVersions
  aws lambda publish-version --function-name my-java-function
  ```
- **Smaller packages** — tree-shake with esbuild, strip `__pycache__`/`.dist-info`
- **Lazy loading** — defer heavy imports until needed:
  ```python
  _dynamodb = None
  def get_dynamodb():
      global _dynamodb
      if _dynamodb is None:
          import boto3
          _dynamodb = boto3.resource("dynamodb")
      return _dynamodb
  ```

---

## 2. Timeout Debugging

Default timeout: 3 s. Maximum: 900 s (15 min).

### Common Timeout Causes

| Cause | Symptom | Solution |
|---|---|---|
| Downstream API unresponsive | Runs to full timeout | Set explicit HTTP/SDK timeouts |
| DNS resolution in VPC | Sporadic 10+ s delays | Use VPC endpoints |
| No connection pooling | New TCP handshake per call | Reuse HTTP agent |
| Large S3 object download | Timeout on big files | Stream objects, increase timeout |
| Deadlock in async code | Hangs indefinitely | Audit Promises / async/await |

```bash
aws logs filter-log-events \
  --log-group-name "/aws/lambda/my-function" \
  --filter-pattern "Task timed out" \
  --start-time $(date -d '24 hours ago' +%s000) \
  --query 'events[*].message' --output text
```

### X-Ray Subsegments for Diagnosis

```python
from aws_xray_sdk.core import xray_recorder

def handler(event, context):
    subsegment = xray_recorder.begin_subsegment("call-payment-api")
    try:
        response = requests.get("https://api.payments.example.com/status", timeout=5)
        subsegment.put_annotation("status_code", response.status_code)
    except requests.exceptions.Timeout:
        subsegment.add_exception(Exception("Payment API timed out"))
        raise
    finally:
        xray_recorder.end_subsegment()
```

### SDK Client Timeouts

```python
import boto3
from botocore.config import Config

config = Config(connect_timeout=5, read_timeout=10,
                retries={"max_attempts": 2, "mode": "adaptive"})
dynamodb = boto3.client("dynamodb", config=config)
```

### Circuit Breaker Pattern

```python
import time

class CircuitBreaker:
    def __init__(self, failure_threshold=3, reset_timeout=30):
        self.failure_count = 0
        self.failure_threshold = failure_threshold
        self.reset_timeout = reset_timeout
        self.last_failure_time = 0
        self.state = "CLOSED"

    def call(self, func, *args, **kwargs):
        if self.state == "OPEN":
            if time.time() - self.last_failure_time > self.reset_timeout:
                self.state = "HALF_OPEN"
            else:
                raise Exception("Circuit breaker OPEN")
        try:
            result = func(*args, **kwargs)
            if self.state == "HALF_OPEN":
                self.state = "CLOSED"
                self.failure_count = 0
            return result
        except Exception:
            self.failure_count += 1
            self.last_failure_time = time.time()
            if self.failure_count >= self.failure_threshold:
                self.state = "OPEN"
            raise

breaker = CircuitBreaker(failure_threshold=3, reset_timeout=60)
```

---

## 3. Memory Tuning

Lambda allocates CPU proportional to memory — tuning affects both performance and cost.

### Power Tuning Tool

```bash
# Deploy via SAR, then run the state machine
aws stepfunctions start-execution \
  --state-machine-arn <state-machine-arn> \
  --input '{
    "lambdaARN": "arn:aws:lambda:us-east-1:123456789012:function:my-function",
    "powerValues": [128, 256, 512, 1024, 1769, 3008],
    "num": 20, "payload": "{\"test\": true}",
    "parallelInvocation": true, "strategy": "cost"
  }'
```

Key output metrics: **averageDuration**, **averageCost**, and a **visualization URL**. Choose the memory at the "knee" of the cost-performance curve (often 512–1024 MB).

### Memory-to-CPU Relationship

| Memory (MB) | vCPUs | Notes |
|---|---|---|
| 128 | 0.083 | Minimum; very slow for CPU work |
| 512 | 0.333 | |
| 1769 | 1.0 | First full vCPU — good baseline |
| 3538 | 2.0 | Multi-threaded workloads benefit |
| 10240 | 6.0 | Maximum |

### Detecting OOM Kills

```
fields @timestamp, @message, @memorySize, @maxMemoryUsed
| filter @message like /Runtime.ExitError|signal: killed|OutOfMemoryError|JavaScript heap out of memory|MemoryError/
| sort @timestamp desc | limit 50
```

**Memory utilization check:**

```
fields @maxMemoryUsed, @memorySize
| stats avg(@maxMemoryUsed) as avgUsed, max(@maxMemoryUsed) as maxUsed,
        avg(@maxMemoryUsed / @memorySize * 100) as avgUtilPct
  by bin(1h)
```

### Right-Sizing

1. Collect baseline metrics for ≥ 24 hours under typical load
2. Run Power Tuning with realistic payloads
3. Keep 20–30% headroom above peak memory usage
4. For CPU-bound work, use ≥ 1769 MB (1 full vCPU)
5. Re-evaluate after code or dependency changes

---

## 4. VPC Connectivity Issues

### NAT Gateway for Internet Access

Lambda in a VPC runs in private subnets — route to internet via NAT Gateway in a public subnet.

> **Common mistake:** Lambda in a public subnet with an IGW does NOT work — Lambda ENIs don't get public IPs.

```bash
# Check function VPC config
aws lambda get-function-configuration --function-name my-function \
  --query 'VpcConfig.{SubnetIds:SubnetIds, SecurityGroupIds:SecurityGroupIds}'

# Check route table for NAT Gateway route (0.0.0.0/0 → nat-xxxx)
SUBNET_ID="subnet-0abc123"
RT=$(aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 describe-route-tables --route-table-ids "$RT" \
  --query 'RouteTables[0].Routes' --output table
```

### VPC Endpoints for AWS Services

Avoid NAT Gateway for AWS services — use VPC endpoints for lower latency and cost.

| Type | Services | Attach To |
|---|---|---|
| Gateway | S3, DynamoDB | Route table |
| Interface | SQS, Secrets Manager, KMS, etc. | Subnet + security group |

```bash
# Gateway endpoint for S3
aws ec2 create-vpc-endpoint --vpc-id vpc-0abc123 \
  --service-name com.amazonaws.us-east-1.s3 --route-table-ids rtb-0abc123

# Interface endpoint for SQS
aws ec2 create-vpc-endpoint --vpc-id vpc-0abc123 \
  --vpc-endpoint-type Interface \
  --service-name com.amazonaws.us-east-1.sqs \
  --subnet-ids subnet-0abc123 --security-group-ids sg-0abc123 \
  --private-dns-enabled
```

### ENI Limits and Cold Start Impact

- Hyperplane ENIs are shared across functions with the same subnet/SG combo
- Initial ENI attachment adds 1–2 s; subsequent cold starts reuse existing ENIs

### Security Group Checklist

- Lambda SG needs **outbound** rules for every service it calls
- Target SGs (e.g., RDS) need **inbound** rules allowing the Lambda SG
- VPC endpoint interface SGs need inbound on port 443 from the Lambda SG

```bash
SG_ID=$(aws lambda get-function-configuration --function-name my-function \
  --query 'VpcConfig.SecurityGroupIds[0]' --output text)
aws ec2 describe-security-groups --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissionsEgress' --output table
```

---

## 5. Permission Errors

### Execution Role vs Resource Policy

| Policy Type | Purpose |
|---|---|
| Execution role | What the function **can do** (attached IAM role) |
| Resource policy | Who **can invoke** the function |

```bash
# View execution role policies
ROLE_NAME=$(aws lambda get-function-configuration --function-name my-function \
  --query 'Role' --output text | awk -F'/' '{print $NF}')
aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output table

# View resource-based policy
aws lambda get-policy --function-name my-function \
  --query 'Policy' --output text | python3 -m json.tool
```

### Common Access Denied Scenarios

| Scenario | Fix |
|---|---|
| Missing DynamoDB access | Add `dynamodb:PutItem` to execution role |
| S3 cross-account | Add bucket policy AND execution role permission |
| KMS decryption | Add `kms:Decrypt` and key policy grant |
| Secrets Manager | Add `secretsmanager:GetSecretValue` |
| SNS publish | Add `sns:Publish` with correct topic ARN |
| Invoke another Lambda | Add `lambda:InvokeFunction` to caller role |

### CloudTrail for Permission Debugging

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=PutItem \
  --start-time $(date -u -d '1 hour ago' +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) \
  --query 'Events[?contains(CloudTrailEvent, `AccessDenied`)].{
    Time:EventTime, Event:EventName}' --output table
```

**CloudWatch Logs Insights:**

```
fields @timestamp, @message
| filter @message like /AccessDeni|Unauthorized|Forbidden|AuthorizationError/
| sort @timestamp desc | limit 20
```

### IAM Policy Simulator

```bash
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:role/my-lambda-role \
  --action-names dynamodb:PutItem s3:GetObject \
  --resource-arns arn:aws:dynamodb:us-east-1:123456789012:table/my-table \
    arn:aws:s3:::my-bucket/* \
  --query 'EvaluationResults[*].{Action:EvalActionName,Decision:EvalDecision}' \
  --output table
```

---

## 6. Package Size Limits and Layer Conflicts

### Size Limits

| Deployment Type | Limit |
|---|---|
| Direct upload (.zip) | 50 MB compressed |
| Unzipped package (incl. layers) | 250 MB |
| Container image | 10 GB |
| Single layer (zipped) | 50 MB |
| Layers per function | 5 |

### Diagnosing Size Issues

```bash
aws lambda get-function --function-name my-function \
  --query 'Configuration.{CodeSize:CodeSize, Layers:Layers}' --output json

# Find largest files in a local package
du -sh my-deployment-package.zip
mkdir -p /tmp/pkg && unzip -o my-deployment-package.zip -d /tmp/pkg
find /tmp/pkg -type f -exec du -h {} + | sort -rh | head -20

# Remove bloat
find /tmp/pkg -type d \( -name "tests" -o -name "__pycache__" \
  -o -name "*.dist-info" \) -exec rm -rf {} + 2>/dev/null
find /tmp/pkg -name "*.so" -exec strip {} + 2>/dev/null
```

### Layer Version Conflicts

```bash
aws lambda get-function-configuration --function-name my-function \
  --query 'Layers[*].{Arn:Arn, CodeSize:CodeSize}' --output table

aws lambda update-function-configuration --function-name my-function \
  --layers arn:aws:lambda:us-east-1:123456789012:layer:my-shared-utils:5 \
           arn:aws:lambda:us-east-1:123456789012:layer:my-common-deps:3
```

### Dependency Collision Between Layers

Layers extract in order into `/opt` — if two layers have the same file, the later one wins silently. **Fix:** consolidate conflicts into one layer or include the dependency in the function package (takes precedence).

---

## 7. Dependency Packaging

### Native Module Compilation

Native modules compiled on macOS/Windows won't run on Lambda's Amazon Linux.

**Node.js:**

```bash
docker run --rm -v "$PWD":/var/task \
  public.ecr.aws/lambda/nodejs:20 \
  bash -c "cd /var/task && npm rebuild --build-from-source"
```

**Python:**

```bash
pip install --platform manylinux2014_x86_64 --target ./package \
  --only-binary=:all: --python-version 3.12 numpy pandas
```

### Docker-Based Builds

```dockerfile
FROM public.ecr.aws/lambda/python:3.12
COPY requirements.txt .
RUN pip install -r requirements.txt -t /opt/python
FROM scratch
COPY --from=0 /opt/python /opt/python
```

```bash
docker build -t lambda-deps -f Dockerfile.deps . && docker create --name deps lambda-deps
docker cp deps:/opt/python ./layer/python && docker rm deps
cd layer && zip -r ../my-deps-layer.zip python/
aws lambda publish-layer-version --layer-name my-python-deps \
  --zip-file fileb://../my-deps-layer.zip --compatible-runtimes python3.12
```

### Architecture-Specific Builds

```bash
# ARM64 (Graviton2 — lower cost, often faster)
docker run --rm --platform linux/arm64 -v "$PWD":/var/task \
  public.ecr.aws/lambda/python:3.12 \
  bash -c "pip install -r /var/task/requirements.txt -t /var/task/package"

# Verify: file package/numpy/core/_multiarray_umath.cpython-312-*.so
```

Architecture mismatch causes `Runtime.ImportModuleError: cannot open shared object file`. Verify with `file` and rebuild for the correct target.

---

## 8. CloudWatch Logs Troubleshooting

### Missing Logs

Common causes and fixes:

- **No logging permissions** — role needs `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`
- **Log group doesn't exist** — check region and name
- **Function crashed before logging** — check `Errors` metric

```bash
# Add logging permissions
aws iam put-role-policy --role-name my-lambda-role \
  --policy-name LambdaBasicLogging --policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
    "Resource":"arn:aws:logs:*:*:*"}]}'

# Check for errors even without logs
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda --metric-name Errors \
  --dimensions Name=FunctionName,Value=my-function \
  --start-time $(date -u -d '1 hour ago' +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) \
  --period 300 --statistics Sum --output table
```

### Useful Logs Insights Queries

```
# Slowest invocations
fields @timestamp, @duration, @memorySize, @maxMemoryUsed
| filter @type = "REPORT" | sort @duration desc | limit 20

# Error rate by hour
fields @timestamp | filter @type = "REPORT"
| stats count() as invocations, sum(strcontains(@message, "Error")) as errors by bin(1h)

# Trace a single invocation
fields @timestamp, @message
| filter @requestId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
| sort @timestamp asc
```

### Filtering and Searching

```bash
aws logs filter-log-events \
  --log-group-name "/aws/lambda/my-function" \
  --filter-pattern '{ $.level = "ERROR" }' \
  --start-time $(date -d '1 hour ago' +%s000) --limit 50
```

### Cost Optimization

- Set retention on all log groups (14 or 30 days typical)
- Use structured JSON logging; ship only errors via subscription filters
- Use Lambda's built-in log level filtering

```bash
aws logs put-retention-policy \
  --log-group-name "/aws/lambda/my-function" --retention-in-days 30

# Find log groups with no retention (never expire)
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/" \
  --query 'logGroups[?!retentionInDays].logGroupName' --output text
```

---

## 9. X-Ray Trace Analysis

### Enabling Active Tracing

```bash
aws lambda update-function-configuration \
  --function-name my-function --tracing-config Mode=Active

aws iam attach-role-policy --role-name my-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess
```

### Reading Trace Maps

```bash
# Service map
aws xray get-service-graph \
  --start-time $(date -u -d '1 hour ago' +%FT%TZ) \
  --end-time $(date -u +%FT%TZ)

# Slow traces
aws xray get-trace-summaries \
  --start-time $(date -u -d '1 hour ago' +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) \
  --filter-expression 'duration > 5 AND service("my-function")'
```

### Custom Subsegments

```python
from aws_xray_sdk.core import xray_recorder, patch_all
patch_all()

def handler(event, context):
    with xray_recorder.in_subsegment("process-data") as sub:
        sub.put_annotation("order_id", event.get("order_id"))
        result = transform_data(event["payload"])
    with xray_recorder.in_subsegment("save-results"):
        boto3.client("s3").put_object(Bucket="results", Key="out.json", Body=result)
    return {"statusCode": 200}
```

### Trace Sampling Configuration

```bash
aws xray create-sampling-rule --cli-input-json '{
  "SamplingRule": {
    "RuleName": "my-function-sampling", "Priority": 100,
    "FixedRate": 0.05, "ReservoirSize": 1,
    "ServiceName": "my-function", "ServiceType": "AWS::Lambda::Function",
    "Host": "*", "ResourceARN": "*", "HTTPMethod": "*", "URLPath": "*", "Version": 1
  }}'
```

- **ReservoirSize**: traces/sec guaranteed recorded
- **FixedRate**: percentage sampled after reservoir fills

### Common Trace Patterns

| Pattern | Indicates | Action |
|---|---|---|
| Long `Initialization` | Slow cold start | Reduce package size, use SnapStart |
| Long `Invocation`, no subsegments | Untraced downstream call | Add X-Ray patching |
| `Throttle` on downstream | AWS API rate limiting | Retries with backoff |
| `Fault` on HTTP call | 5xx from downstream | Circuit breaker |
| Gaps between subsegments | CPU-bound processing | Increase memory |

---

## 10. Event Source Mapping Failures

### SQS Message Visibility Timeout

Visibility timeout must be **≥ 6× Lambda timeout** to avoid duplicate processing.

```bash
TIMEOUT=$(aws lambda get-function-configuration \
  --function-name my-sqs-processor --query 'Timeout' --output text)

aws sqs set-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/123456789012/my-queue \
  --attributes "VisibilityTimeout=$((TIMEOUT * 6))"
```

Signs of misconfiguration: duplicate processing, high `ReceiveCount`, premature DLQ delivery.

### Kinesis Shard Iterator Expiration

Iterators expire after 5 min. Monitor `IteratorAge` — if growing, records may be lost.

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda --metric-name IteratorAge \
  --dimensions Name=FunctionName,Value=my-kinesis-processor \
  --start-time $(date -u -d '1 hour ago' +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) \
  --period 300 --statistics Maximum --output table
```

**Fixes:** increase batch size, increase parallelization factor, add shards, optimize function.

```bash
aws lambda update-event-source-mapping \
  --uuid "<mapping-uuid>" --parallelization-factor 10 --batch-size 1000
```

### DynamoDB Stream Record Age

Streams retain records 24 hours. Set alarms to detect lag:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "ddb-stream-lag" --namespace AWS/Lambda \
  --metric-name IteratorAge \
  --dimensions Name=FunctionName,Value=my-ddb-processor \
  --statistic Maximum --period 300 --threshold 72000000 \
  --comparison-operator GreaterThanThreshold --evaluation-periods 3 \
  --alarm-actions arn:aws:sns:us-east-1:123456789012:ops-alerts
```

### Bisect on Error

Isolate poison messages by splitting failed batches:

```bash
aws lambda update-event-source-mapping \
  --uuid "<mapping-uuid>" \
  --bisect-batch-on-function-error --maximum-retry-attempts 3
```

**For SQS — use partial batch response:**

```python
def handler(event, context):
    failures = []
    for record in event["Records"]:
        try:
            process_message(record)
        except Exception:
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
```

Enable with: `--function-response-types ReportBatchItemFailures`

### Failure Destinations

```bash
# Stream-based mapping: on-failure destination
aws lambda update-event-source-mapping --uuid "<mapping-uuid>" \
  --destination-config '{"OnFailure":{"Destination":"arn:aws:sqs:us-east-1:123456789012:my-dlq"}}'

# Async invocations: function-level destinations
aws lambda put-function-event-invoke-config --function-name my-function \
  --maximum-retry-attempts 2 --destination-config '{
    "OnSuccess":{"Destination":"arn:aws:sqs:us-east-1:123456789012:success-q"},
    "OnFailure":{"Destination":"arn:aws:sqs:us-east-1:123456789012:failure-q"}}'
```

---

## 11. Concurrent Execution Throttling

### Account-Level Limits

Default: **1,000 concurrent executions per region** (shared across all functions).

```bash
aws lambda get-account-settings \
  --query '{Concurrent:AccountLimit.ConcurrentExecutions,
            Unreserved:AccountLimit.UnreservedConcurrentExecutions}' --output table
```

### Reserved and Provisioned Concurrency

- **Reserved** — guarantees AND caps capacity
- **Provisioned** — pre-initializes environments (eliminates cold starts)

```bash
aws lambda put-function-concurrency \
  --function-name my-function --reserved-concurrent-executions 100

aws lambda put-provisioned-concurrency-config \
  --function-name my-function --qualifier my-alias \
  --provisioned-concurrent-executions 50
```

**Auto-scaling provisioned concurrency:**

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace lambda \
  --resource-id function:my-function:prod \
  --scalable-dimension lambda:function:ProvisionedConcurrency \
  --min-capacity 5 --max-capacity 100

aws application-autoscaling put-scaling-policy \
  --service-namespace lambda \
  --resource-id function:my-function:prod \
  --scalable-dimension lambda:function:ProvisionedConcurrency \
  --policy-name scaling --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue":0.7,"PredefinedMetricSpecification":{
    "PredefinedMetricType":"LambdaProvisionedConcurrencyUtilization"}}'
```

### Burst Limits

| Region | Burst Limit |
|---|---|
| us-east-1, us-west-2, eu-west-1 | 3,000 |
| ap-northeast-1, eu-central-1, us-east-2 | 1,000 |
| All other regions | 500 |

After initial burst, concurrency grows by 500/min.

### Handling 429 Errors

```python
import boto3, time, random
client = boto3.client("lambda")

def invoke_with_retry(function_name, payload, max_retries=5):
    for attempt in range(max_retries):
        try:
            resp = client.invoke(FunctionName=function_name, Payload=payload)
            if resp["StatusCode"] == 429:
                raise Exception("Throttled")
            return resp
        except Exception:
            if attempt == max_retries - 1:
                raise
            time.sleep(min(2 ** attempt + random.uniform(0, 1), 30))
```

**Throttle behavior by source:**

| Source | Behavior |
|---|---|
| SQS | Messages return to queue, retried automatically |
| Kinesis / DynamoDB Streams | Retries until records expire (24h–7d) |
| API Gateway (sync) | Returns 429 to caller |
| SNS / S3 events | Retries with backoff up to 6 hours |

### Requesting Limit Increases

```bash
aws service-quotas get-service-quota \
  --service-code lambda --quota-code L-B99A9384 \
  --query 'Quota.{Name:QuotaName,Value:Value}' --output table

aws service-quotas request-service-quota-increase \
  --service-code lambda --quota-code L-B99A9384 --desired-value 5000
```

- Provide business justification and current utilization metrics
- Request incremental increases; for 10,000+ contact your AWS account team first
