---
name: aws-lambda
description: >
  Use when creating AWS Lambda functions, configuring triggers/event sources,
  writing Lambda handlers in Node.js/Python/Go/Java/Rust, setting up API Gateway
  integrations, managing Lambda layers, optimizing cold starts, deploying with
  SAM/CDK/Serverless Framework/Terraform, configuring Lambda URLs, Step Functions
  orchestration, or using Powertools for AWS Lambda.
  Do NOT use for Azure Functions, Google Cloud Functions, Cloudflare Workers,
  general AWS services without Lambda, or container-based ECS/EKS deployments.
---

# AWS Lambda

## Handler Patterns

### Node.js (ES modules or CommonJS)

```javascript
// ESM handler (index.mjs or set "type": "module" in package.json)
export const handler = async (event, context) => {
  const body = JSON.parse(event.body || '{}');
  return { statusCode: 200, body: JSON.stringify({ message: 'ok', requestId: context.awsRequestId }) };
};
```

### Python

```python
import json

def handler(event, context):
    body = json.loads(event.get("body", "{}"))
    return {"statusCode": 200, "body": json.dumps({"message": "ok", "requestId": context.aws_request_id})}
```

### Go (provided.al2023 runtime)

```go
package main

import (
    "context"
    "github.com/aws/aws-lambda-go/events"
    "github.com/aws/aws-lambda-go/lambda"
)

func handler(ctx context.Context, req events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
    return events.APIGatewayProxyResponse{StatusCode: 200, Body: `{"message":"ok"}`}, nil
}

func main() { lambda.Start(handler) }
```

Build with `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o bootstrap main.go` and zip the `bootstrap` binary.

### Rust (provided.al2023 runtime)

```rust
use lambda_runtime::{service_fn, LambdaEvent, Error};
use serde_json::{json, Value};

async fn handler(_event: LambdaEvent<Value>) -> Result<Value, Error> {
    Ok(json!({ "statusCode": 200, "body": "ok" }))
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    lambda_runtime::run(service_fn(handler)).await
}
```

Build with `cargo lambda build --release`. The binary must be named `bootstrap` at the zip root.

### Java

```java
package example;
import com.amazonaws.services.lambda.runtime.*;
import java.util.Map;

public class Handler implements RequestHandler<Map<String, Object>, Map<String, Object>> {
    @Override
    public Map<String, Object> handleRequest(Map<String, Object> event, Context context) {
        return Map.of("statusCode", 200, "body", "{\"message\":\"ok\"}");
    }
}
```

Initialize SDK clients outside the handler to reuse across warm invocations.

## Event Sources

### API Gateway (REST API v1 / HTTP API v2)

REST API sends v1 payload (`event.httpMethod`, `event.pathParameters`). HTTP API sends v2 payload (`event.requestContext.http.method`). Use proxy integration to pass the full request to Lambda.

### SQS

```python
def handler(event, context):
    failed = []
    for record in event["Records"]:
        try:
            process(record["body"])
        except Exception:
            failed.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failed}
```

Enable `ReportBatchItemFailures` in the event source mapping for partial batch failure reporting.

### SNS

Lambda receives `event["Records"][i]["Sns"]["Message"]`. Configure the SNS subscription to target the Lambda ARN.

### S3

Triggered on object events (e.g., `s3:ObjectCreated:*`). Access bucket/key via `event["Records"][0]["s3"]["bucket"]["name"]` and `event["Records"][0]["s3"]["object"]["key"]`.

### DynamoDB Streams

Process `event["Records"]` where each record has `dynamodb.NewImage` and `dynamodb.OldImage`. Set `StartingPosition` to `TRIM_HORIZON` or `LATEST`. Use `FilterCriteria` on the event source mapping to reduce invocations.

### EventBridge

Pattern-matched rules route events to Lambda. Access event data via `event["detail"]`. Use `DetailType` and `Source` in rules for filtering.

### Kinesis

Similar to DynamoDB Streams. Process `event["Records"]` with base64-encoded `data` field. Configure `BatchSize`, `MaximumBatchingWindowInSeconds`, and `ParallelizationFactor` (up to 10) on the event source mapping.

### CloudWatch Events / Scheduled

Use EventBridge rules with `schedule(rate(5 minutes))` or `schedule(cron(0 12 * * ? *))` to invoke Lambda on a schedule.

## Configuration

| Setting | Details |
|---------|---------|
| Memory | 128 MB–10,240 MB. CPU scales proportionally. 1,769 MB = 1 vCPU. |
| Timeout | Max 900 seconds (15 min). Set below the API Gateway limit (29s) for HTTP-triggered functions. |
| Env vars | Set via console, CLI, or IaC. Access via `process.env` (Node), `os.environ` (Python), `os.Getenv` (Go). |
| VPC | Attach to VPC for private resource access. Requires ENI in subnets. Use VPC endpoints for AWS services. |
| Reserved concurrency | Guarantees capacity and caps max concurrent executions. Set to 0 to throttle. |
| Provisioned concurrency | Pre-initializes execution environments. Eliminates cold starts. Combine with Application Auto Scaling. |
| Ephemeral storage | `/tmp` configurable from 512 MB to 10,240 MB. |
| Architecture | `x86_64` (default) or `arm64` (Graviton2 — ~20% cheaper, often faster). |

## Lambda Layers

Create layers for shared libraries, custom runtimes, or large dependencies. Each function supports up to 5 layers. Total unzipped size (function + layers) must be under 250 MB for ZIP deployments.

```bash
# Create a Python layer
mkdir -p layer/python
pip install requests -t layer/python/
cd layer && zip -r ../my-layer.zip python/
aws lambda publish-layer-version \
  --layer-name my-shared-libs \
  --zip-file fileb://my-layer.zip \
  --compatible-runtimes python3.12 python3.13

# Attach to function
aws lambda update-function-configuration \
  --function-name my-func \
  --layers arn:aws:lambda:us-east-1:123456789012:layer:my-shared-libs:1
```

Share layers across accounts by adding permissions with `aws lambda add-layer-version-permission`.

## Deployment

### SAM (Serverless Application Model)

```yaml
# template.yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Resources:
  MyFunction:
    Type: AWS::Serverless::Function
    Properties:
      Handler: index.handler
      Runtime: nodejs20.x
      CodeUri: src/
      MemorySize: 256
      Timeout: 30
      Events:
        Api:
          Type: HttpApi
          Properties:
            Path: /items
            Method: GET
```

Deploy: `sam build && sam deploy --guided`.

### CDK (TypeScript)

```typescript
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';

const fn = new lambda.Function(this, 'Handler', {
  runtime: lambda.Runtime.PYTHON_3_12,
  handler: 'index.handler',
  code: lambda.Code.fromAsset('lambda/'),
  memorySize: 256,
  timeout: cdk.Duration.seconds(30),
});
new apigateway.LambdaRestApi(this, 'Api', { handler: fn });
```

### Serverless Framework

```yaml
# serverless.yml
service: my-service
provider:
  name: aws
  runtime: nodejs20.x
  memorySize: 256
functions:
  hello:
    handler: handler.hello
    events:
      - httpApi:
          path: /hello
          method: get
```

Deploy: `serverless deploy`.

### Terraform

```hcl
resource "aws_lambda_function" "this" {
  function_name = "my-func"
  role          = aws_iam_role.lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  filename      = "lambda.zip"
  memory_size   = 256
  timeout       = 30
}
```

### Raw CloudFormation

Use `AWS::Lambda::Function` resource type. SAM is preferred for serverless workloads as it reduces boilerplate.

## API Gateway Integration

### REST API vs HTTP API

- **HTTP API**: Lower latency, ~70% cheaper, supports JWT/Cognito authorizers, OpenID Connect. Use for most new APIs.
- **REST API**: Full-featured — API keys, usage plans, request validation, WAF integration, caching, resource policies. Use when you need these features.

### Proxy vs Non-Proxy Integration

- **Proxy** (default): Entire request forwarded to Lambda. Return `statusCode`, `headers`, `body`.
- **Non-proxy**: Configure request/response mapping templates in API Gateway (VTL). Rarely needed.

### Authorizers

- **JWT authorizer** (HTTP API): Validates JWT tokens from any OIDC provider. Simplest setup.
- **Cognito authorizer** (REST API): Validates tokens from a Cognito User Pool.
- **Lambda authorizer**: Custom auth logic. Return an IAM policy document with `execute-api:Invoke` action. Cache results with `authorizationResultTtlInSeconds`.

## Cold Start Optimization

1. **Minimize package size**: Tree-shake, exclude dev dependencies, use `--production` installs. Smaller ZIPs load faster.
2. **Choose efficient runtimes**: Node.js and Python have the fastest cold starts. Go and Rust (custom runtime) are also fast.
3. **SnapStart (Java, Python 3.12+, .NET 8+)**: Snapshots the initialized runtime at publish time. Restores on cold start, reducing latency by up to 90%. Enable via `SnapStart: {ApplyOn: PublishedVersions}`. Avoid caching timestamps or random values during init.
4. **Provisioned concurrency**: Pre-warms instances. Use for latency-sensitive workloads. Not compatible with SnapStart.
5. **Init code optimization**: Move SDK client initialization outside the handler (global scope). Lazy-load rarely-used modules.
6. **ARM64 architecture**: Graviton2 often provides faster cold starts and lower cost.

## Lambda URLs (Function URLs)

Simple HTTPS endpoints directly on a Lambda function. No API Gateway required.

```bash
aws lambda create-function-url-config \
  --function-name my-func \
  --auth-type NONE \
  --cors '{"AllowOrigins":["*"],"AllowMethods":["GET","POST"]}'
```

Auth types: `NONE` (public) or `AWS_IAM`. No support for custom authorizers, WAF, or usage plans. Best for webhooks, simple backends, and internal tools.

## Step Functions Integration

Use Step Functions for orchestrating multi-step workflows. Invoke Lambda from Task states:

```json
{
  "StartAt": "Process",
  "States": {
    "Process": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:us-east-1:123456789012:function:process",
      "Retry": [{"ErrorEquals": ["States.TaskFailed"], "MaxAttempts": 3, "IntervalSeconds": 2, "BackoffRate": 2.0}],
      "Catch": [{"ErrorEquals": ["States.ALL"], "Next": "HandleError"}],
      "Next": "Done"
    },
    "HandleError": { "Type": "Task", "Resource": "arn:aws:lambda:us-east-1:123456789012:function:error-handler", "End": true },
    "Done": { "Type": "Succeed" }
  }
}
```

Use Express Workflows for high-volume, short-duration tasks (up to 5 min). Use Standard Workflows for long-running processes (up to 1 year).

## Powertools for AWS Lambda

Available for Python, TypeScript, and Java. Install via pip/npm/Maven.

```python
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.utilities.idempotency import idempotent, DynamoDBPersistenceLayer

logger = Logger()
tracer = Tracer()
metrics = Metrics()
persistence = DynamoDBPersistenceLayer(table_name="IdempotencyTable")

@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
@idempotent(persistence_store=persistence)
def handler(event, context):
    logger.info("Processing event", extra={"detail": event})
    metrics.add_metric(name="OrderProcessed", unit="Count", value=1)
    return {"statusCode": 200, "body": "ok"}
```

Key utilities: **Logger** (structured JSON logging), **Tracer** (X-Ray tracing), **Metrics** (CloudWatch EMF), **Idempotency** (exactly-once processing with DynamoDB), **Validation** (JSON Schema), **Event Handler** (API Gateway/ALB routing).

## Error Handling

### Asynchronous Invocations

Lambda retries failed async invocations twice. Configure `MaximumRetryAttempts` (0–2) and a dead-letter queue (SQS or SNS) or `OnFailure` destination.

```yaml
# SAM
Properties:
  DeadLetterQueue:
    Type: SQS
    TargetArn: !GetAtt DLQ.Arn
  EventInvokeConfig:
    MaximumRetryAttempts: 1
    OnFailure:
      Type: SQS
      Destination: !GetAtt FailureQueue.Arn
```

### Event Source Mapping (SQS, Kinesis, DynamoDB)

- **SQS**: Failed messages return to the queue. Use `RedrivePolicy` on the SQS queue for DLQ routing. Enable `FunctionResponseTypes: [ReportBatchItemFailures]` for partial batch failure.
- **Kinesis/DynamoDB Streams**: Failed batches block the shard. Configure `MaximumRetryAttempts`, `BisectBatchOnFunctionError` (splits failed batches), and `OnFailure` destination.

### Synchronous Invocations

No built-in retry. The caller receives the error and handles retry logic.

## Testing

### Local Testing with SAM CLI

```bash
# Invoke locally with a test event
sam local invoke MyFunction -e events/test.json

# Start local API Gateway
sam local start-api

# Generate sample events
sam local generate-event s3 put --bucket my-bucket --key my-key > events/s3.json
```

### Unit Testing

Mock the event and context objects. Test handler logic in isolation.

```python
# test_handler.py
from handler import handler

def test_handler():
    event = {"body": '{"name": "test"}'}
    context = type("Context", (), {"aws_request_id": "test-123"})()
    result = handler(event, context)
    assert result["statusCode"] == 200
```

### Integration Testing

Deploy to a test stage/account. Invoke via AWS SDK or HTTP. Use `aws lambda invoke` for direct testing.

## Observability

- **CloudWatch Logs**: Automatic. Each invocation logs to `/aws/lambda/<function-name>`. Set log retention to avoid unbounded costs.
- **X-Ray Tracing**: Enable active tracing. Use Powertools `Tracer` or AWS X-Ray SDK to add subsegments for downstream calls.
- **CloudWatch Metrics**: Built-in: `Invocations`, `Errors`, `Duration`, `Throttles`, `ConcurrentExecutions`, `InitDuration`. Create alarms on `Errors` and `Throttles`.
- **Custom Metrics**: Use CloudWatch Embedded Metric Format (EMF) via Powertools `Metrics` for zero-overhead custom metrics.

## Packaging

### ZIP Deployment

Default method. Upload code as a ZIP archive (max 50 MB direct upload, 250 MB unzipped). Use S3 for larger packages.

### Container Images

Package as a Docker image (up to 10 GB). Push to Amazon ECR. Use AWS base images or any image implementing the Lambda Runtime API.

```dockerfile
FROM public.ecr.aws/lambda/python:3.12
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY app.py .
CMD ["app.handler"]
```

Deploy: `docker build -t my-func . && docker push <ecr-uri>`. Set `PackageType: Image` in configuration.

## IAM

### Execution Role

Every Lambda function needs an execution role. Start with `AWSLambdaBasicExecutionRole` (CloudWatch Logs access), then add only the permissions the function needs. Scope IAM actions and resources narrowly — avoid `*` wildcards, use separate roles per function, and use IAM Access Analyzer to identify unused permissions.

### Resource Policies

Control who can invoke the function. API Gateway, S3, SNS, and other services need `lambda:InvokeFunction` permission via resource-based policy.

### Least Privilege

Scope IAM actions and resources narrowly. Avoid `*` wildcards. Use separate roles per function. Use IAM Access Analyzer to identify unused permissions.

## Best Practices

1. **Single responsibility**: One function per task. Avoid monolithic Lambda functions with routing logic.
2. **Shared code via layers**: Extract common utilities, SDKs, and data models into layers.
3. **Environment-specific config**: Use environment variables for stage-specific values (table names, API URLs). Never hardcode ARNs or endpoints.
4. **Keep functions stateless**: Store state in DynamoDB, S3, or ElastiCache. Use `/tmp` only for ephemeral processing.
5. **Right-size memory**: Use AWS Lambda Power Tuning to find the optimal memory/cost balance.
6. **Set appropriate timeouts**: Match timeout to expected duration plus buffer. Avoid the 900s maximum unless necessary.
7. **Use structured logging**: JSON-formatted logs with correlation IDs for traceability across services.
8. **Implement idempotency**: Use Powertools idempotency utility or DynamoDB conditional writes to handle retries safely.
9. **Monitor and alert**: Set CloudWatch alarms on `Errors`, `Throttles`, and `Duration` p99. Track `InitDuration` for cold start trends.
10. **Pin dependency versions**: Lock dependency versions in `package-lock.json`, `requirements.txt`, or equivalent to ensure reproducible builds.

## Reference Guides

Deep-dive documentation in `references/`:

| Guide | Topics |
|-------|--------|
| [Advanced Patterns](references/advanced-patterns.md) | Lambda extensions, custom runtimes, Lambda@Edge vs CloudFront Functions, Powertools deep dive (batch, feature flags, parameters, streaming), Step Functions patterns, EventBridge architectures, destinations, provisioned concurrency auto-scaling, SnapStart internals, streaming responses, recursive invocation protection |
| [Troubleshooting](references/troubleshooting.md) | Cold start diagnosis, timeout debugging, memory tuning (power tuning tool), VPC connectivity, permission errors, package size limits, dependency packaging, CloudWatch Logs, X-Ray traces, event source mapping failures, concurrency throttling |
| [Deployment Patterns](references/deployment-patterns.md) | SAM/CDK/Serverless Framework/Terraform full examples, GitHub Actions CI/CD, blue-green and canary deployments, multi-environment setup, infrastructure testing |

## Helper Scripts

Executable scripts in `scripts/`:

| Script | Usage |
|--------|-------|
| `scaffold-lambda.sh` | `./scaffold-lambda.sh --runtime node\|python\|go\|rust --trigger api\|sqs\|s3\|schedule --deploy sam\|cdk\|serverless` |
| `lambda-local-test.sh` | `./lambda-local-test.sh --function MyFunc --event event.json` or `--generate api\|sqs\|s3\|sns\|dynamodb\|schedule` |
| `lambda-optimize.sh` | `./lambda-optimize.sh --function my-func --region us-east-1` — analyzes config and CloudWatch metrics, suggests optimizations |

## Asset Templates

Production-ready templates in `assets/`:

| Template | Description |
|----------|-------------|
| [sam-template.yaml](assets/sam-template.yaml) | Complete SAM template with HTTP API, DynamoDB (GSI), Lambda layers, SQS/DLQ, CloudWatch alarms |
| [cdk-stack.ts](assets/cdk-stack.ts) | CDK TypeScript stack with NodejsFunction, REST API, DynamoDB, SQS, IAM grants |
| [github-actions-deploy.yml](assets/github-actions-deploy.yml) | GitHub Actions workflow with OIDC auth, multi-environment deploy (dev/staging/prod), testing, caching |

<!-- tested: pass -->
