# Advanced AWS Lambda Patterns

Reference for Lambda extensions, custom runtimes, edge computing, powertools,
Step Functions, event-driven architectures, and performance optimization.

---

## Table of Contents

- [1. Lambda Extensions](#1-lambda-extensions)
- [2. Custom Runtimes (provided.al2023)](#2-custom-runtimes-providedal2023)
- [3. Lambda@Edge vs CloudFront Functions](#3-lambdaedge-vs-cloudfront-functions)
- [4. Lambda Powertools Deep Dive](#4-lambda-powertools-deep-dive)
- [5. Step Functions Patterns](#5-step-functions-patterns)
- [6. Event-Driven Architectures](#6-event-driven-architectures)
- [7. Lambda Destinations](#7-lambda-destinations)
- [8. Provisioned Concurrency Auto-Scaling](#8-provisioned-concurrency-auto-scaling)
- [9. Lambda SnapStart Internals](#9-lambda-snapstart-internals)
- [10. Streaming Responses](#10-streaming-responses)
- [11. Recursive Invocation Protection](#11-recursive-invocation-protection)

---

## 1. Lambda Extensions

### Internal vs External Extensions

| Aspect | Internal | External |
|---|---|---|
| Process model | Same process as function | Separate process |
| Language | Must match runtime | Any compiled binary |
| Lifecycle control | Limited — tied to runtime | Full Extensions API |
| Use case | Middleware, APM agents | Log shipping, sidecars |
| Packaging | Layer or bundled | Layer in `/opt/extensions/` |

### Lifecycle Phases

- **Init** (≤10s): Extensions register via Extensions API
- **Invoke**: Lambda sends `INVOKE` event; handler and extensions run in parallel
- **Shutdown** (≤2s): Cleanup before environment destruction

### Building a Custom External Extension

```python
#!/usr/bin/env python3
import os, json, urllib.request

RUNTIME_API = os.environ["AWS_LAMBDA_RUNTIME_API"]
EXT_NAME = os.path.basename(__file__)

def register():
    req = urllib.request.Request(
        f"http://{RUNTIME_API}/2020-01-01/extension/register",
        data=json.dumps({"events": ["INVOKE", "SHUTDOWN"]}).encode(),
        headers={"Lambda-Extension-Name": EXT_NAME}, method="POST")
    return urllib.request.urlopen(req).headers.get("Lambda-Extension-Identifier")

def next_event(ext_id):
    req = urllib.request.Request(
        f"http://{RUNTIME_API}/2020-01-01/extension/event/next",
        headers={"Lambda-Extension-Identifier": ext_id})
    return json.loads(urllib.request.urlopen(req).read())

ext_id = register()
while True:
    event = next_event(ext_id)
    if event["eventType"] == "SHUTDOWN":
        break
```

Package: `chmod +x ext && cp ext extensions/ && zip -r layer.zip extensions/`

### Telemetry API

Subscribe to receive logs/metrics/traces directly (bypassing CloudWatch):

```python
def subscribe_to_telemetry(ext_id):
    payload = json.dumps({
        "schemaVersion": "2022-12-13",
        "destination": {"protocol": "HTTP", "URI": "http://sandbox.localdomain:1060"},
        "types": ["platform", "function", "extension"],
        "buffering": {"maxItems": 1000, "maxBytes": 262144, "timeoutMs": 100}
    }).encode()
    req = urllib.request.Request(
        f"http://{RUNTIME_API}/2022-07-01/telemetry", data=payload, method="PUT",
        headers={"Lambda-Extension-Identifier": ext_id, "Content-Type": "application/json"})
    urllib.request.urlopen(req)
```

---

## 2. Custom Runtimes (provided.al2023)

### Bootstrap Requirements

- Executable named `bootstrap` at package root or `/opt/` (from a layer)
- Must be `chmod +x` and implement the Runtime API loop

### Runtime API Endpoints

Base: `http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime/`

| Endpoint | Method | Purpose |
|---|---|---|
| `invocation/next` | GET | Long-poll for next event |
| `invocation/{id}/response` | POST | Send success response |
| `invocation/{id}/error` | POST | Send error response |
| `init/error` | POST | Report init failure |

Headers from `/invocation/next`: `Lambda-Runtime-Aws-Request-Id`, `Lambda-Runtime-Deadline-Ms`, `Lambda-Runtime-Invoked-Function-Arn`, `Lambda-Runtime-Trace-Id`

### Example: Bash Custom Runtime

```bash
#!/bin/sh
set -euo pipefail
source "$LAMBDA_TASK_ROOT/$(echo "$_HANDLER" | cut -d. -f1).sh"
HANDLER="$(echo "$_HANDLER" | cut -d. -f2)"
API="http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime"

while true; do
    HDR=$(mktemp)
    EVENT=$(curl -sS -LD "$HDR" "${API}/invocation/next")
    RID=$(grep -Fi "Lambda-Runtime-Aws-Request-Id" "$HDR" | tr -d '[:space:]' | cut -d: -f2)
    RESP=$($HANDLER "$EVENT" 2>&1) || {
        curl -sS -X POST "${API}/invocation/${RID}/error" \
            -d '{"errorMessage":"Handler failed","errorType":"RuntimeError"}'
        rm -f "$HDR"; continue
    }
    curl -sS -X POST "${API}/invocation/${RID}/response" -d "$RESP"
    rm -f "$HDR"
done
```

SAM template: set `Runtime: provided.al2023`, `Handler: handler.handler`, `Architectures: [arm64]`.

---

## 3. Lambda@Edge vs CloudFront Functions

### Comparison

| Feature | Lambda@Edge | CloudFront Functions |
|---|---|---|
| Runtime | Node.js, Python | JavaScript (ES 5.1) |
| Location | Regional edge caches | 400+ PoPs |
| Max execution | 5s (viewer) / 30s (origin) | 1 ms |
| Max memory | 128–3008 MB | 2 MB |
| Max package | 1 MB (viewer) / 50 MB (origin) | 10 KB |
| Network access | Yes | No |
| Triggers | Viewer + Origin req/resp | Viewer req/resp only |
| Pricing | Per request + duration | ~1/6th of L@E |
| Request body | Yes | No |

### When to Use Which

| CloudFront Functions | Lambda@Edge |
|---|---|
| URL rewrites/redirects | Dynamic origin selection |
| Header manipulation | Auth with external calls (OAuth) |
| Cache key normalization | Image transformation |
| Simple A/B testing | Bot detection via API |
| Lightweight JWT validation | Response body modification |

### Event Structure

```javascript
// CloudFront Function — headers as simple key-value
function handler(event) {
    var request = event.request;
    request.uri = request.uri.toLowerCase();
    return request;
}

// Lambda@Edge — headers as arrays, accessed via Records[0].cf
exports.handler = async (event) => {
    const request = event.Records[0].cf.request;
    const country = request.headers['cloudfront-viewer-country'][0].value;
    if (country === 'DE') request.uri = '/de' + request.uri;
    return request;
};
```

### Limitations

- **Lambda@Edge**: must deploy in `us-east-1`; no env vars/layers/VPC in viewer triggers; no ARM64
- **CloudFront Functions**: no network calls; 10 KB max; 1 ms max; no request body access

---

## 4. Lambda Powertools Deep Dive

### Batch Processing

Handles partial failures for SQS, Kinesis, and DynamoDB Streams — only failed
records are reported via `batchItemFailures`.

```python
from aws_lambda_powertools.utilities.batch import BatchProcessor, EventType, batch_processor

processor = BatchProcessor(event_type=EventType.SQS)

def record_handler(record):
    payload = record.json_body
    process_order(payload["order_id"], payload["amount"])

@batch_processor(record_handler=record_handler, processor=processor)
def lambda_handler(event, context):
    return processor.response()
```

SAM config — add `FunctionResponseTypes: [ReportBatchItemFailures]` to the event source.
Use `EventType.KinesisDataStreams` or `EventType.DynamoDBStreams` for other sources.

### Feature Flags (AppConfig)

```python
from aws_lambda_powertools.utilities.feature_flags import AppConfigStore, FeatureFlags

app_config = AppConfigStore(environment="production", application="my-app",
                            name="feature-flags", max_age=120)
feature_flags = FeatureFlags(store=app_config)

def lambda_handler(event, context):
    is_premium = feature_flags.evaluate(name="premium_features", default=False)
    has_checkout = feature_flags.evaluate(
        name="new_checkout_flow", default=False,
        context={"tenant_id": event["tenant_id"], "tier": "enterprise"})
    return {"premium": is_premium, "new_checkout": has_checkout}
```

Schema: JSON with `default` value and `rules` containing `when_match`, `conditions`
(action/key/value). Supports `EQUALS`, `STARTSWITH`, `ENDSWITH`, `IN`, etc.

### Parameters Utility

Unified caching interface across SSM, Secrets Manager, AppConfig, and DynamoDB:

```python
from aws_lambda_powertools.utilities import parameters

db_host = parameters.get_parameter("/app/prod/db_host")           # SSM
db_config = parameters.get_parameters("/app/prod/db/")            # SSM prefix
db_creds = parameters.get_secret("prod/db/creds",
    transform="json", max_age=300)                                # Secrets Manager
config = parameters.get_app_config(name="settings",
    environment="prod", application="svc", transform="json")      # AppConfig
secret = parameters.get_secret("prod/api-key", force_fetch=True)  # bypass cache
```

### Streaming Responses

```python
from aws_lambda_powertools.event_handler import APIGatewayHttpResolver, Response
app = APIGatewayHttpResolver()

@app.get("/large-report")
def get_report():
    def generate():
        yield '{"records": ['
        for i in range(10000):
            if i > 0: yield ","
            yield json.dumps({"id": i, "value": f"row-{i}"})
        yield "]}"
    return Response(status_code=200, content_type="application/json", body=generate())

def lambda_handler(event, context):
    return app.resolve(event, context)
```

---

## 5. Step Functions Patterns

### Map State — Inline vs Distributed

**Inline Map** — bounded concurrency within a single execution:

```json
{
  "Type": "Map", "ItemsPath": "$.orders", "MaxConcurrency": 10,
  "Iterator": {
    "StartAt": "Process",
    "States": { "Process": { "Type": "Task", "Resource": "arn:aws:lambda:...:process", "End": true } }
  }
}
```

**Distributed Map** — up to 10K concurrent child executions, reads from S3:

```json
{
  "Type": "Map",
  "ItemProcessor": {
    "ProcessorConfig": { "Mode": "DISTRIBUTED", "ExecutionType": "STANDARD" },
    "StartAt": "Process",
    "States": { "Process": { "Type": "Task", "Resource": "arn:aws:lambda:...:process", "End": true } }
  },
  "ItemReader": {
    "Resource": "arn:aws:states:::s3:getObject",
    "ReaderConfig": { "InputType": "CSV", "CSVHeaderLocation": "FIRST_ROW" },
    "Parameters": { "Bucket": "my-bucket", "Key": "input/data.csv" }
  },
  "MaxConcurrency": 1000
}
```

### Parallel State

Run branches concurrently; output is an array (one element per branch):

```json
{
  "Type": "Parallel",
  "Branches": [
    { "StartAt": "GetProfile", "States": { "GetProfile": { "Type": "Task", "Resource": "arn:aws:lambda:...:get-profile", "End": true } } },
    { "StartAt": "GetOrders", "States": { "GetOrders": { "Type": "Task", "Resource": "arn:aws:lambda:...:get-orders", "End": true } } }
  ],
  "ResultPath": "$.aggregated"
}
```

### Error Handling — Retry and Catch

```json
{
  "Type": "Task", "Resource": "arn:aws:lambda:...:charge",
  "Retry": [
    { "ErrorEquals": ["States.TaskFailed"], "IntervalSeconds": 2, "MaxAttempts": 3, "BackoffRate": 2.0, "JitterStrategy": "FULL" },
    { "ErrorEquals": ["States.Timeout"], "IntervalSeconds": 5, "MaxAttempts": 2 }
  ],
  "Catch": [
    { "ErrorEquals": ["PaymentDeclined"], "ResultPath": "$.error", "Next": "NotifyFailure" },
    { "ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "HandleError" }
  ],
  "TimeoutSeconds": 30, "HeartbeatSeconds": 10
}
```

- **JitterStrategy `FULL`**: randomized jitter prevents thundering herd
- **BackoffRate**: multiplier on `IntervalSeconds` each attempt
- **MaxAttempts**: 0 = no retries; default = 3

### Wait and Choice States

```json
{ "Type": "Wait", "TimestampPath": "$.approvalDeadline", "Next": "CheckStatus" }
```

```json
{
  "Type": "Choice",
  "Choices": [
    { "And": [
        { "Variable": "$.total", "NumericGreaterThan": 1000 },
        { "Variable": "$.tier", "StringEquals": "premium" }
      ], "Next": "PriorityProcessing" },
    { "Variable": "$.type", "StringEquals": "digital", "Next": "DigitalFulfillment" }
  ],
  "Default": "StandardProcessing"
}
```

### Intrinsic Functions

```json
{
  "Type": "Pass",
  "Parameters": {
    "id.$": "States.UUID()",
    "ts.$": "States.Format('{}T{}Z', $.date, $.time)",
    "count.$": "States.ArrayLength($.items)",
    "merged.$": "States.JsonMerge($.defaults, $.overrides, false)",
    "hashed.$": "States.Hash($.input, 'SHA-256')",
    "parts.$": "States.ArrayPartition($.items, 10)",
    "inc.$": "States.MathAdd($.count, 1)"
  }
}
```

### SDK Integrations

Call AWS services directly without Lambda:

```json
{
  "Type": "Task",
  "Resource": "arn:aws:states:::dynamodb:putItem",
  "Parameters": {
    "TableName": "Orders",
    "Item": {
      "orderId": { "S.$": "$.orderId" },
      "status": { "S": "PROCESSING" },
      "createdAt": { "S.$": "$$.State.EnteredTime" }
    }
  }
}
```

Supported: DynamoDB, SNS, SQS, ECS, Glue, Athena, EventBridge, API Gateway, CodeBuild, etc.

### Express vs Standard Workflows

| Feature | Standard | Express |
|---|---|---|
| Max duration | 1 year | 5 minutes |
| Execution model | Exactly-once | At-least-once |
| Start rate | 2,000/sec | 100,000/sec |
| Pricing | Per state transition | Per execution + duration |
| History | 90-day console + API | CloudWatch Logs only |
| Sync invocation | No | Yes (`StartSyncExecution`) |

- **Express**: high-volume events, sync microservices, short workflows, cost-sensitive
- **Standard**: long-running (approvals, batch), exactly-once, audit trail needed

---

## 6. Event-Driven Architectures

### EventBridge + Lambda Patterns

```python
import json, boto3
eb = boto3.client("events")

def publish_event(detail_type, detail, source="com.myapp"):
    eb.put_events(Entries=[{
        "Source": source, "DetailType": detail_type,
        "Detail": json.dumps(detail), "EventBusName": "custom-app-bus",
    }])

def lambda_handler(event, context):
    order = create_order(event)
    publish_event("OrderCreated", {"orderId": order["id"], "total": order["total"]})
    return {"statusCode": 201, "body": json.dumps(order)}
```

### Event Buses and Rules

```yaml
Resources:
  AppEventBus:
    Type: AWS::Events::EventBus
    Properties: { Name: app-domain-events }

  OrderCreatedRule:
    Type: AWS::Events::Rule
    Properties:
      EventBusName: !Ref AppEventBus
      EventPattern:
        source: ["com.myapp.orders"]
        detail-type: ["OrderCreated"]
        detail: { total: [{ numeric: [">=", 100] }] }
      Targets:
        - Arn: !GetAtt HighValueProcessor.Arn
          Id: HighValue
        - Arn: !GetAtt NotifyFunction.Arn
          Id: Notify
          InputTransformer:
            InputPathsMap: { orderId: "$.detail.orderId" }
            InputTemplate: '{"message": "Order <orderId> placed"}'
```

### Archive and Replay

```yaml
  OrderEventsArchive:
    Type: AWS::Events::Archive
    Properties:
      SourceArn: !GetAtt AppEventBus.Arn
      EventPattern: { source: ["com.myapp.orders"] }
      RetentionDays: 90
```

Replay: `aws events start-replay --replay-name "reprocess" --event-source-arn <bus-arn> --destination '{"Arn":"<bus-arn>"}' --event-start-time "2024-01-01T00:00:00Z" --event-end-time "2024-01-31T23:59:59Z"`

### Schema Registry

- Use `AWS::EventSchemas::Discoverer` to auto-discover schemas from bus events
- Use explicit `AWS::EventSchemas::Schema` (OpenApi3) for contract-first design
- Supports code generation from discovered schemas

### Cross-Account Events

- Account B adds resource policy on bus allowing `events:PutEvents` from Account A
- Account A uses full ARN of Account B's bus as `EventBusName`

---

## 7. Lambda Destinations

### OnSuccess / OnFailure

Route async invocation results without custom code:

```yaml
Resources:
  OrderProcessor:
    Type: AWS::Serverless::Function
    Properties:
      EventInvokeConfig:
        MaximumRetryAttempts: 2
        MaximumEventAgeInSeconds: 3600
        DestinationConfig:
          OnSuccess: { Type: SQS, Destination: !GetAtt SuccessQueue.Arn }
          OnFailure: { Type: SNS, Destination: !Ref FailureTopic }
```

Supported types: **SQS**, **SNS**, **Lambda**, **EventBridge**. Payload includes
original event, function response, request ID, condition, and retry count.

### Destinations vs DLQ

| Feature | Destinations | DLQ |
|---|---|---|
| Success handling | ✅ OnSuccess | ❌ |
| Failure handling | ✅ OnFailure | ✅ |
| Targets | SQS, SNS, Lambda, EventBridge | SQS, SNS only |
| Payload | Full context + response | Original event only |
| Invocation context | ✅ request ID, retry count | ❌ |

**Prefer destinations** for richer context and success routing. Use DLQs for
legacy compatibility or event source mapping failures.

### Async Invocation Flow

```
Client ──▶ Lambda ──▶ Internal Queue ──▶ Function
                                           │
                            ┌──────────────┼──────────────┐
                            ▼              ▼              ▼
                         Success        Retry(0–2)     Exhausted
                            ▼                             ▼
                       OnSuccess                     OnFailure
```

- If both DLQ and OnFailure are configured, both receive the event
- Events exceeding `MaximumEventAgeInSeconds` are aged out

---

## 8. Provisioned Concurrency Auto-Scaling

### Target Tracking

```yaml
Resources:
  ApiFunction:
    Type: AWS::Serverless::Function
    Properties:
      AutoPublishAlias: live
      ProvisionedConcurrencyConfig: { ProvisionedConcurrentExecutions: 10 }

  ScalableTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      MaxCapacity: 100
      MinCapacity: 5
      ResourceId: !Sub function:${ApiFunction}:live
      ScalableDimension: lambda:function:ProvisionedConcurrency
      ServiceNamespace: lambda

  TrackingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref ScalableTarget
      TargetTrackingScalingPolicyConfiguration:
        TargetValue: 0.7
        PredefinedMetricSpecification:
          PredefinedMetricType: LambdaProvisionedConcurrencyUtilization
        ScaleInCooldown: 60
        ScaleOutCooldown: 0
```

### Scheduled Scaling

```yaml
  ScheduledTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      ResourceId: !Sub function:${ApiFunction}:live
      ScalableDimension: lambda:function:ProvisionedConcurrency
      ServiceNamespace: lambda
      ScheduledActions:
        - ScheduledActionName: morning-up
          Schedule: "cron(0 8 ? * MON-FRI *)"
          ScalableTargetAction: { MinCapacity: 50, MaxCapacity: 200 }
        - ScheduledActionName: evening-down
          Schedule: "cron(0 20 ? * MON-FRI *)"
          ScalableTargetAction: { MinCapacity: 5, MaxCapacity: 50 }
```

### CDK Example

```typescript
const alias = fn.addAlias('live', { provisionedConcurrentExecutions: 10 });
const target = alias.addAutoScaling({ minCapacity: 5, maxCapacity: 100 });
target.scaleOnUtilization({ utilizationTarget: 0.7 });
target.scaleOnSchedule('MorningBoost', {
  schedule: appscaling.Schedule.cron({ hour: '8', minute: '0', weekDay: 'MON-FRI' }),
  minCapacity: 50,
});
```

---

## 9. Lambda SnapStart Internals

### CRaC Hooks

SnapStart uses Coordinated Restore at Checkpoint (CRaC). Register hooks to
run before snapshot and after restore:

```java
public class Handler implements RequestHandler<...>, Resource {
    private DynamoDbClient client;

    public Handler() {
        Core.getGlobalContext().register(this);
        this.client = DynamoDbClient.builder().build();
    }

    @Override
    public void beforeCheckpoint(Context<? extends Resource> ctx) {
        // Close non-restorable resources (stale connections)
    }

    @Override
    public void afterRestore(Context<? extends Resource> ctx) {
        this.client = DynamoDbClient.builder().build(); // re-establish
    }
}
```

### Runtime Hooks

When you can't modify code, configure via SAM:

```yaml
SnapStartFunction:
  Type: AWS::Serverless::Function
  Properties:
    Runtime: java21
    SnapStart: { ApplyOn: PublishedVersions }
    Environment:
      Variables:
        JAVA_TOOL_OPTIONS: "-XX:+TieredCompilation -XX:TieredStopAtLevel=1"
```

### Uniqueness Considerations

| Problem | Solution |
|---|---|
| `SecureRandom` seeded at init | Re-seed in `afterRestore` |
| UUID generators | Use `UUID.randomUUID()` per-invocation (SnapStart-safe) |
| Encryption IVs/nonces | Generate per-invocation, never at init |
| DB connections | Reconnect in `afterRestore` |

### Performance Benchmarks

| Scenario | Without | With SnapStart | Improvement |
|---|---|---|---|
| Minimal Java 21 | ~3.5s | ~0.4s | ~88% |
| Spring Boot 3 + DynamoDB | ~6.5s | ~0.8s | ~88% |
| Quarkus + AWS clients | ~4.0s | ~0.5s | ~87% |
| Micronaut + RDS | ~3.8s | ~0.6s | ~84% |

Restore time is typically 200–500ms regardless of init complexity.

### Supported Runtimes

- **GA**: Java 11, 17, 21
- **Preview**: Python 3.12+, .NET 8
- **Not supported**: Node.js, ARM64, provisioned concurrency, EFS mounts, packages >256 MB

---

## 10. Streaming Responses

### Function URL Configuration

Set `InvokeMode: RESPONSE_STREAM` on the function URL config:

```yaml
StreamingFunction:
  Type: AWS::Serverless::Function
  Properties:
    Runtime: nodejs20.x
    FunctionUrlConfig: { AuthType: AWS_IAM, InvokeMode: RESPONSE_STREAM }
```

### awslambda.streamifyResponse

```javascript
exports.handler = awslambda.streamifyResponse(async (event, responseStream, ctx) => {
    const metadata = { statusCode: 200, headers: { "Content-Type": "text/html" } };
    responseStream = awslambda.HttpResponseStream.from(responseStream, metadata);
    responseStream.write("<html><body><h1>Report</h1>");
    for (let i = 0; i < 100; i++) {
        responseStream.write(`<p>Batch ${i + 1} done</p>`);
        await processChunk(i);
    }
    responseStream.end();
});
```

### Buffered vs Streaming

| Aspect | Buffered (default) | Streaming |
|---|---|---|
| Delivery | All at once | Progressive |
| Max response | 6 MB | 20 MB (soft) |
| Time-to-first-byte | After completion | After first `write()` |
| Pricing | Standard | + data transfer cost |
| Triggers | All | Function URLs only |

- CloudFront can front function URLs for caching/edge delivery
- Mid-stream errors result in partial data + error trailer

---

## 11. Recursive Invocation Protection

### Detection Mechanisms

Recursive loops: Lambda writes to a resource that re-triggers itself.

```
Lambda ──▶ S3 Put ──▶ S3 Event ──▶ Lambda ──▶ ... (infinite)
```

**Prevent via prefix separation:**

```python
def lambda_handler(event, context):
    for record in event["Records"]:
        key = record["s3"]["object"]["key"]
        if not key.startswith("uploads/"): continue
        output_key = key.replace("uploads/", "processed/", 1)
        s3.put_object(Bucket=record["s3"]["bucket"]["name"],
                      Key=output_key, Body=process(key))
```

Set S3 event filter: `Filter: { S3Key: { Rules: [{ Name: prefix, Value: "uploads/" }] } }`

### Circuit Breaker Pattern

Track invocation count in DynamoDB with a time window. If count exceeds threshold
(e.g., 100 invocations in 60s), halt execution and optionally alert via SNS.

```python
def check_circuit(function_name):
    now = int(time.time())
    resp = circuit_table.update_item(
        Key={"function_name": function_name},
        UpdateExpression="SET invocation_count = if_not_exists(invocation_count, :z) + :one, "
                         "window_start = if_not_exists(window_start, :now)",
        ExpressionAttributeValues={":z": 0, ":one": 1, ":now": now},
        ReturnValues="ALL_NEW")
    item = resp["Attributes"]
    if int(item["window_start"]) < now - 60:
        circuit_table.update_item(Key={"function_name": function_name},
            UpdateExpression="SET invocation_count = :one, window_start = :now",
            ExpressionAttributeValues={":one": 1, ":now": now})
        return False
    return int(item["invocation_count"]) > 100
```

### Lambda Loop Detection (Built-in)

- **Supported**: SQS, SNS, S3 (since 2024)
- **Mechanism**: internal header tracking across invocations
- **Threshold**: stops after **16 recursive invocations**
- **Action**: event sent to DLQ (if configured), logs `RecursiveInvocationException`
- **Default**: enabled since July 2023; configure with `RecursiveLoop: Terminate` (default) or `Allow`

Monitor with CloudWatch alarm on `RecursiveInvocationsDropped` metric.

> **Best practice:** Design to prevent recursion — separate prefixes, distinct
> queues, idempotency keys — even with built-in detection.

---

*Last updated: 2025*
