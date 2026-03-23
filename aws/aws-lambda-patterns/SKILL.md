---
name: aws-lambda-patterns
description:
  positive: >
    Use when user builds AWS Lambda functions, asks about cold start optimization,
    Lambda Powertools, Lambda layers, event source mappings, SAM/CDK deployment,
    handler patterns, or Lambda@Edge/CloudFront Functions.
  negative: >
    Do NOT use for Terraform AWS (use terraform-aws-patterns skill), general AWS
    architecture, or non-Lambda serverless (Step Functions, Fargate).
---

# AWS Lambda Patterns

## Handler Patterns

### Single Responsibility + Dependency Injection

One function = one event source = one purpose. Initialize clients at module scope. Pass them to pure business logic functions for testability.

```python
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext
import boto3, os

logger = Logger()
tracer = Tracer()

# Module-scope init — reused across warm invocations
table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])

@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    return process_order(event, table)

def process_order(event: dict, table) -> dict:
    """Pure business logic — testable without Lambda context."""
    order = event["detail"]
    table.put_item(Item=order)
    return {"statusCode": 200, "body": order["id"]}
```

### Middleware Pattern (Node.js with Middy)

```javascript
import middy from '@middy/core';
import httpJsonBodyParser from '@middy/http-json-body-parser';
import httpErrorHandler from '@middy/http-error-handler';
import { Logger, injectLambdaContext } from '@aws-lambda-powertools/logger';
import { Tracer, captureLambdaHandler } from '@aws-lambda-powertools/tracer';

const logger = new Logger();
const tracer = new Tracer();

const baseHandler = async (event) => {
  logger.info('Processing request', { path: event.path });
  return { statusCode: 200, body: JSON.stringify({ ok: true }) };
};

export const handler = middy(baseHandler)
  .use(injectLambdaContext(logger))
  .use(captureLambdaHandler(tracer))
  .use(httpJsonBodyParser())
  .use(httpErrorHandler());
```

---

## Lambda Powertools

### Logger, Tracer, Metrics

```python
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit

logger = Logger()    # Structured JSON, auto-injects request_id, cold_start
tracer = Tracer()    # X-Ray subsegments via @tracer.capture_method
metrics = Metrics(namespace="Payments", service="payment-service")

@logger.inject_lambda_context(log_event=True)
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event, context):
    logger.append_keys(order_id=event["order_id"])
    metrics.add_metric(name="SuccessfulPayment", unit=MetricUnit.Count, value=1)
    return charge_card(event)

@tracer.capture_method
def charge_card(event):
    pass  # Auto-traced subsegment
```

### Event Handler (API Gateway)

```python
from aws_lambda_powertools.event_handler import APIGatewayRestResolver

app = APIGatewayRestResolver()

@app.get("/orders/<order_id>")
def get_order(order_id: str):
    return {"id": order_id, "status": "shipped"}

@app.post("/orders")
def create_order():
    return {"id": "new-123"}, 201

def handler(event, context):
    return app.resolve(event, context)
```

### Parameters, Secrets, and Idempotency

```python
from aws_lambda_powertools.utilities import parameters
from aws_lambda_powertools.utilities.idempotency import (
    DynamoDBPersistenceLayer, IdempotencyConfig, idempotent
)

# SSM (cached 5 min), Secrets Manager, AppConfig
api_key = parameters.get_parameter("/prod/api-key", decrypt=True)
db_creds = parameters.get_secret("prod/db-credentials", transform="json")

# Idempotency — prevents duplicate processing
persistence = DynamoDBPersistenceLayer(table_name="IdempotencyTable")

@idempotent(persistence_store=persistence, config=IdempotencyConfig(
    event_key_jmespath="body.order_id", expires_after_seconds=3600,
))
def handler(event, context):
    return process_payment(event["body"])
```

---

## Cold Start Optimization

### Strategies by Impact

| Strategy | Latency Reduction | Cost | Complexity |
|---|---|---|---|
| Smaller packages | 10-40% | Free | Low |
| ARM64 (Graviton) | 5-15% + 20% cheaper | Savings | Low |
| SnapStart (Python 3.12+/Java/.NET) | Up to 90% | Free | Medium |
| Provisioned Concurrency | 100% (zero cold start) | $$$ | Medium |
| Higher memory allocation | 10-50% | Variable | Low |

### SnapStart (SAM)

```yaml
Resources:
  MyFunction:
    Type: AWS::Serverless::Function
    Properties:
      Runtime: python3.12
      SnapStart:
        ApplyOn: PublishedVersions
      AutoPublishAlias: live
```

Constraints: Incompatible with Provisioned Concurrency, EFS, ephemeral storage >512MB. Avoid non-deterministic init (random seeds, unique connections). As of 2025, AWS bills Init Duration for on-demand ZIP Lambdas — optimize init to reduce both latency and cost.

### Init Phase Optimization

- Move imports to top level; lazy-import only rarely-used heavy modules.
- Strip unused deps: `pip install -t package/ --only-binary=:all:` then prune `*.pyc`, `__pycache__`.
- `boto3` is pre-loaded in Python runtime — do not bundle it.

### Package Size Reduction

```bash
# Python
pip install -r requirements.txt -t package/ --platform manylinux2014_x86_64 --only-binary=:all:
cd package && find . -name "*.pyc" -delete && find . -name "__pycache__" -delete
zip -r9 ../function.zip .

# Node.js — esbuild tree-shaking
npx esbuild src/handler.ts --bundle --platform=node --target=node20 \
  --outfile=dist/handler.js --minify --external:@aws-sdk/*
```

---

## Event Sources

### Configuration Cheat Sheet

| Source | Invocation | Retry | Batch | Scaling |
|---|---|---|---|---|
| API Gateway | Synchronous | Client retries | N/A | Auto |
| SQS | Polling | maxReceiveCount → DLQ | 1-10,000 | Up to 1,250/min |
| SNS | Async push | 3 retries → DLQ | N/A | Auto |
| DynamoDB Streams | Polling | ∞ until expiry | 1-10,000 | Per shard |
| EventBridge | Async push | 185 retries/24h | N/A | Auto |
| S3 | Async push | 2 retries | N/A | Auto |
| Kinesis | Polling | ∞ until expiry | 1-10,000 | Per shard |

### SQS Partial Batch Failure

```python
from aws_lambda_powertools.utilities.batch import (
    BatchProcessor, EventType, process_partial_response
)

processor = BatchProcessor(event_type=EventType.SQS)

def record_handler(record):
    process_message(record["body"])  # Raise on failure

def handler(event, context):
    return process_partial_response(
        event=event, record_handler=record_handler,
        processor=processor, context=context
    )
```

Enable in SAM: set `FunctionResponseTypes: [ReportBatchItemFailures]` on the SQS event.

---

## Error Handling

### Dead Letter Queues and Destinations

- **Async invocations** (SNS, S3, EventBridge): Attach DLQ or use `OnFailure` destination.
- **Event source mappings** (SQS, Kinesis, DynamoDB): Use `DestinationConfig.OnFailure`.

```yaml
# SAM — DLQ for async
DeadLetterQueue:
  Type: SQS
  TargetArn: !GetAtt MyDLQ.Arn

# SAM — OnFailure for ESM
DestinationConfig:
  OnFailure:
    Destination: !GetAtt FailureQueue.Arn
```

### Retry Behavior per Source

- **SQS**: Returns to queue on failure. After `maxReceiveCount` → DLQ. Set visibility timeout ≥ 6× function timeout.
- **Kinesis/DynamoDB Streams**: Retries indefinitely (blocks shard). Use `BisectBatchOnFunctionError`, `MaximumRetryAttempts`, `MaximumRecordAgeInSeconds`.
- **Async (SNS, S3, EventBridge)**: 2 retries with backoff. Configure `MaximumRetryAttempts` (0-2) and DLQ/destination.

---

## Lambda Layers

### Structure and Usage

```
my-layer/
├── python/lib/python3.12/site-packages/   # Python deps
└── nodejs/node_modules/                    # Node.js deps
```

```yaml
# SAM
Resources:
  SharedDepsLayer:
    Type: AWS::Serverless::LayerVersion
    Properties:
      LayerName: shared-deps
      ContentUri: layers/shared-deps/
      CompatibleRuntimes: [python3.12]
    Metadata:
      BuildMethod: python3.12
  MyFunction:
    Type: AWS::Serverless::Function
    Properties:
      Layers: [!Ref SharedDepsLayer]
```

Use for: shared deps across functions, runtime extensions, monitoring agents. Limit: 5 layers/function, 250MB total unzipped.

---

## Deployment

### SAM vs CDK vs Serverless Framework

| Feature | SAM | CDK | Serverless Framework |
|---|---|---|---|
| Language | YAML/JSON | TypeScript/Python/etc. | YAML + plugins |
| Learning curve | Low | Medium | Low |
| AWS-native | Yes | Yes | Third-party |
| Local testing | `sam local invoke` | Limited | `sls invoke local` |
| Best for | Small-medium projects | Complex infra, teams | Multi-cloud, rapid |

### SAM Template

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Globals:
  Function:
    Runtime: python3.12
    Architectures: [arm64]
    Timeout: 30
    MemorySize: 256
    Tracing: Active
    Environment:
      Variables:
        POWERTOOLS_SERVICE_NAME: my-service
        LOG_LEVEL: INFO
Resources:
  OrdersFunction:
    Type: AWS::Serverless::Function
    Properties:
      Handler: app.handler
      CodeUri: src/
      Policies:
        - DynamoDBCrudPolicy: { TableName: !Ref OrdersTable }
      Events:
        GetOrder:
          Type: Api
          Properties: { Path: /orders/{id}, Method: get }
```

### CDK (TypeScript)

```typescript
const fn = new lambda.Function(this, 'OrdersHandler', {
  runtime: lambda.Runtime.PYTHON_3_12,
  architecture: lambda.Architecture.ARM_64,
  handler: 'app.handler',
  code: lambda.Code.fromAsset('src'),
  memorySize: 256,
  timeout: cdk.Duration.seconds(30),
  environment: { TABLE_NAME: table.tableName, POWERTOOLS_SERVICE_NAME: 'orders' },
  tracing: lambda.Tracing.ACTIVE,
});
table.grantReadWriteData(fn);
```

---

## Environment and Configuration

1. **Environment variables** — static per deployment, fast. Use for table names, service names.
2. **SSM Parameter Store** — dynamic config. Cache with Powertools (5 min TTL default).
3. **Secrets Manager** — credentials, API keys. Auto-rotation. Use Powertools or Lambda Extensions.
4. **AppConfig** — feature flags with validation and safe rollout.

Rules: Never hardcode ARNs or endpoints. Store secrets in Secrets Manager, not env vars (visible in console). Cache parameter lookups to avoid cold-start overhead.

---

## Performance

### Memory and Power Tuning

CPU scales linearly with memory. At 1,769 MB = 1 full vCPU. Use **AWS Lambda Power Tuning** to find the cost/performance sweet spot:

```bash
aws serverlessrepo create-cloud-formation-change-set \
  --application-id arn:aws:serverlessrepo:us-east-1:451282441545:applications/aws-lambda-power-tuning \
  --stack-name lambda-power-tuning
```

### Connection Reuse

```python
import boto3
from botocore.config import Config

config = Config(retries={"max_attempts": 3, "mode": "adaptive"}, max_pool_connections=10)
table = boto3.resource("dynamodb", config=config).Table(os.environ["TABLE_NAME"])

def handler(event, context):
    return table.get_item(Key={"pk": event["id"]})
```

```javascript
// Node.js SDK v3 reuses connections by default
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
const client = new DynamoDBClient({});  // Module scope = reused on warm starts
```

### /tmp Caching

Use `/tmp` (up to 10GB) to cache files between invocations. Check existence before fetching.

---

## Testing

### Unit Tests (moto)

```python
import boto3, pytest
from moto import mock_aws

@mock_aws
def test_process_order():
    table = boto3.resource("dynamodb", region_name="us-east-1").create_table(
        TableName="Orders",
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    from app import process_order
    result = process_order({"detail": {"id": "123", "item": "widget"}}, table)
    assert result["statusCode"] == 200
```

### Integration Tests

- **LocalStack**: `docker run -p 4566:4566 localstack/localstack`. Point boto3 with `endpoint_url="http://localhost:4566"`.
- **SAM Local**: `sam local invoke MyFunction -e events/order.json` or `sam local start-api`.

---

## Security

### IAM Least Privilege

- Use SAM policy templates (`DynamoDBCrudPolicy`, `SQSPollerPolicy`) over wildcard `*`.
- Scope resource ARNs to specific tables/queues. Use separate execution roles per function.

### VPC

- Only attach to VPC when accessing VPC resources (RDS, ElastiCache).
- Use VPC endpoints for DynamoDB, S3, Secrets Manager to avoid NAT Gateway costs.
- Ensure sufficient ENIs: Lambda reserves one per subnet/security-group combination.

### Resource Policies

Use resource-based policies to restrict who can invoke functions. Limit API Gateway invocation to specific API IDs.

---

## Observability

### X-Ray and CloudWatch

Enable tracing globally: `Globals.Function.Tracing: Active`. Use Powertools Tracer for auto subsegments.

```sql
-- CloudWatch Logs Insights: slow invocations
filter @type = "REPORT"
| stats avg(@duration) as avg_ms, max(@duration) as max_ms, count(*) by bin(1h)
| sort bin desc

-- Cold starts
filter @type = "REPORT" and @initDuration > 0
| stats count(*) as cold_starts, avg(@initDuration) as avg_init_ms by bin(1h)
```

### Key Alarms

Set CloudWatch alarms on: `ConcurrentExecutions` (near account limit), `Throttles`, `Errors`, `Duration` p99, iterator age (stream sources).

---

## Common Anti-Patterns

- **Monolith Lambda**: Do not route all API paths through one function. Split by domain for independent scaling and least-privilege IAM.
- **Synchronous chains**: Never call Lambda → Lambda directly. Use SQS, EventBridge, or Step Functions.
- **Oversized packages**: Do not bundle `aws-sdk` v2 in Node.js (pre-installed). Exclude test files and dev deps. Target <5MB zipped.
- **Hardcoded config**: Use env vars or SSM, never constants.
- **Missing timeouts**: Set function timeout < API Gateway timeout (29s). Set client timeouts < function timeout.
- **No idempotency**: Every source can deliver duplicates. Use Powertools Idempotency or conditional writes.
- **Ignoring concurrency**: Set reserved concurrency to protect downstream services. Monitor throttles.
- **Logging secrets**: Never log raw event payloads containing PII or credentials.
