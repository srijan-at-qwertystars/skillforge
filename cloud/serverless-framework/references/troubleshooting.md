# Serverless Framework v4 — Troubleshooting Guide

## Table of Contents

- [CloudFormation Errors](#cloudformation-errors)
- [Deployment Failures](#deployment-failures)
- [Rollback Issues](#rollback-issues)
- [Permission Errors](#permission-errors)
- [Cold Start Issues](#cold-start-issues)
- [Large Deployment Packages](#large-deployment-packages)
- [Timeout Issues](#timeout-issues)
- [API Gateway Limits](#api-gateway-limits)
- [Plugin Conflicts](#plugin-conflicts)
- [serverless-offline Quirks](#serverless-offline-quirks)
- [Debugging Lambda Functions](#debugging-lambda-functions)
- [esbuild / Bundling Issues](#esbuild--bundling-issues)
- [Environment & Auth Errors](#environment--auth-errors)

---

## CloudFormation Errors

### 500 resource limit exceeded

**Error:** `Template format error: Number of resources, 516, is greater than maximum allowed, 500`

**Cause:** CloudFormation hard-limits each stack to 500 resources. A function with HTTP event creates ~5 resources (Function, LogGroup, Role, Permission, API route).

**Solutions (pick one):**

1. **Split into multiple services** (recommended):
   ```yaml
   # serverless-compose.yml
   services:
     api-users:
       path: services/api-users
     api-orders:
       path: services/api-orders
   ```

2. **Use split-stacks plugin:**
   ```bash
   npm i -D serverless-plugin-split-stacks
   ```
   ```yaml
   plugins:
     - serverless-plugin-split-stacks
   custom:
     splitStacks:
       perFunction: false
       perType: true           # Split by resource type
       perGroupFunction: false
       nestedStackCount: 20    # Max nested stacks
   ```

3. **Reduce resource count:**
   - Share IAM roles across functions (default behavior — avoid per-function roles plugin).
   - Use `httpApi` (v2) instead of `http` (v1) — v2 creates fewer resources.
   - Remove unused functions and resources.

### Resource already exists

**Error:** `my-service-dev-MyTable already exists in stack`

**Cause:** Resource with same physical name exists from a previous failed/partial deployment.

**Fix:**
```bash
# Check if resource exists
aws dynamodb describe-table --table-name my-service-dev-MyTable 2>/dev/null

# Option 1: Delete the orphaned resource manually, then redeploy
aws dynamodb delete-table --table-name my-service-dev-MyTable

# Option 2: Import existing resource into stack (CloudFormation)
# Use AWS Console → CloudFormation → Import resources
```

### Circular dependency detected

**Error:** `Circular dependency between resources: [ResourceA, ResourceB]`

**Fix:** Break the cycle using `Fn::Sub` with explicit dependencies or `DependsOn`:
```yaml
resources:
  Resources:
    LambdaPermission:
      Type: AWS::Lambda::Permission
      Properties:
        FunctionName: !GetAtt MyFunctionLambdaFunction.Arn
        Action: lambda:InvokeFunction
        Principal: s3.amazonaws.com
        SourceArn: !Sub arn:aws:s3:::${self:service}-${sls:stage}-bucket
        # Use !Sub with hardcoded bucket name instead of !Ref to break cycle
```

### Output limit exceeded

**Error:** `Maximum number of outputs (200) exceeded`

**Fix:** Reduce exported outputs. Only export values consumed by other stacks. Use SSM parameters instead of CloudFormation outputs for cross-stack references when you have many values to share.

---

## Deployment Failures

### Stack stuck in UPDATE_ROLLBACK_FAILED

**Symptoms:** Deploy hangs or fails. Console shows `UPDATE_ROLLBACK_FAILED`.

**Fix:**
```bash
# 1. Identify failed resources in AWS Console → CloudFormation → Events

# 2. Continue rollback, skipping problematic resources
aws cloudformation continue-update-rollback \
  --stack-name my-service-dev \
  --resources-to-skip MyFailedResource

# 3. Once in UPDATE_ROLLBACK_COMPLETE, deploy again
serverless deploy --stage dev
```

### Stack stuck in DELETE_FAILED

**Cause:** Resources with `DeletionPolicy: Retain` or resources that can't be deleted (non-empty S3 bucket, etc.).

**Fix:**
```bash
# 1. Empty the S3 bucket
aws s3 rm s3://my-bucket --recursive

# 2. Retry delete
aws cloudformation delete-stack --stack-name my-service-dev

# 3. Or skip specific resources
aws cloudformation delete-stack \
  --stack-name my-service-dev \
  --retain-resources MyS3Bucket
```

### Deployment too large

**Error:** `An error occurred: ServerlessDeploymentBucket - The bucket policy exceeds the maximum allowed document size`

Or: `Code storage limit exceeded` (75 GB across all Lambda function versions)

**Fix:**
```bash
# Clean old versions
serverless prune -n 3 --stage dev      # Keep last 3 versions (requires serverless-prune-plugin)

# Or manually via AWS CLI
aws lambda list-versions-by-function --function-name my-func | \
  jq -r '.Versions[:-3][] | .Version' | \
  xargs -I{} aws lambda delete-function --function-name my-func --qualifier {}
```

```yaml
# Install prune plugin for automatic cleanup
plugins:
  - serverless-prune-plugin
custom:
  prune:
    automatic: true
    number: 3
```

### No changes to deploy

**Message:** `No changes to deploy. Deployment skipped.`

**Cause:** CloudFormation detects no diff. This happens when you change only code but use `serverless deploy` (full stack).

**Fix:** Use function-level deploy for code-only changes:
```bash
serverless deploy function -f myFunction --stage dev
```

---

## Rollback Issues

### Manual rollback to previous version

```bash
# 1. List deployment history
aws cloudformation list-stacks --stack-status-filter UPDATE_COMPLETE

# 2. Find the previous deployment artifact
serverless deploy list --stage dev

# 3. Rollback by deploying the previous package
serverless rollback --timestamp <timestamp> --stage dev
```

### Prevent data loss during rollback

```yaml
resources:
  Resources:
    MyTable:
      Type: AWS::DynamoDB::Table
      DeletionPolicy: Retain           # Keep table even if stack is deleted
      UpdateReplacePolicy: Retain      # Keep during replacement
```

### Automatic rollback on alarm

```yaml
provider:
  deploymentBucket:
    name: ${self:service}-deploys
  rollbackConfiguration:
    monitoringTimeInMinutes: 10
    rollbackTriggers:
      - arn: !Ref ErrorAlarm
        type: AWS::CloudWatch::Alarm
```

---

## Permission Errors

### Access denied during deployment

**Error:** `User: arn:aws:iam::123:user/deployer is not authorized to perform: cloudformation:CreateStack`

**Minimum deployment permissions:**
```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudformation:*",
        "s3:*",
        "lambda:*",
        "apigateway:*",
        "iam:GetRole", "iam:CreateRole", "iam:DeleteRole",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:PassRole",
        "logs:*",
        "events:*",
        "sqs:*", "sns:*",
        "dynamodb:*"
      ],
      "Resource": "*"
    }
  ]
}
```

**Best practice:** Use a dedicated CloudFormation deployment role:
```yaml
provider:
  iam:
    deploymentRole: arn:aws:iam::${aws:accountId}:role/ServerlessDeployRole
```

### Lambda can't access resource

**Error:** `AccessDeniedException: User is not authorized to perform dynamodb:PutItem`

**Fix:** Ensure IAM statements cover all required actions and resources:
```yaml
provider:
  iam:
    role:
      statements:
        - Effect: Allow
          Action:
            - dynamodb:GetItem
            - dynamodb:PutItem
            - dynamodb:UpdateItem
            - dynamodb:DeleteItem
            - dynamodb:Query
            - dynamodb:Scan
          Resource:
            - !GetAtt MyTable.Arn
            - !Sub '${MyTable.Arn}/index/*'    # Don't forget GSI ARNs
```

---

## Cold Start Issues

### Diagnosing cold starts

```bash
# Check init duration in CloudWatch Logs
aws logs filter-log-events \
  --log-group-name /aws/lambda/my-service-dev-myFunction \
  --filter-pattern '"Init Duration"' \
  --limit 20

# Or via X-Ray traces
# Enable tracing:
```
```yaml
provider:
  tracing:
    lambda: true
    apiGateway: true
```

### Cold start mitigation matrix

| Technique                  | Cold Start Impact | Cost Impact  | Complexity |
| -------------------------- | ----------------- | ------------ | ---------- |
| `arm64` architecture       | -34% duration     | -20% cost    | Trivial    |
| esbuild bundling + minify  | -40-60% duration  | None         | Low        |
| Externalize `@aws-sdk/*`   | -20% package size | None         | Low        |
| `package.individually`     | -30-50% size      | None         | Low        |
| Provisioned concurrency    | Eliminates        | $$$          | Low        |
| Lazy-load heavy deps       | -20-40% init      | None         | Medium     |
| Avoid VPC (if possible)    | -1-10s            | None         | Medium     |
| SnapStart (Java only)      | -90% duration     | None         | Medium     |

### Lazy loading pattern

```typescript
// BAD — loaded on every cold start even if not needed
import { S3Client } from '@aws-sdk/client-s3';
const s3 = new S3Client({});

// GOOD — loaded only when the code path is hit
let s3: S3Client;
function getS3() {
  if (!s3) {
    const { S3Client } = require('@aws-sdk/client-s3');
    s3 = new S3Client({});
  }
  return s3;
}
```

---

## Large Deployment Packages

### Diagnosing package size

```bash
# Check packaged sizes
serverless package --stage dev
ls -lhS .serverless/*.zip

# Inspect contents
unzip -l .serverless/my-function.zip | tail -20
unzip -l .serverless/my-function.zip | wc -l
```

### Size reduction checklist

1. **Enable individual packaging:**
   ```yaml
   package:
     individually: true
   ```

2. **Use esbuild bundling (v4 built-in):**
   ```yaml
   build:
     esbuild:
       bundle: true
       minify: true
       external: ['@aws-sdk/*']
   ```

3. **Aggressive exclusions:**
   ```yaml
   package:
     patterns:
       - '!node_modules/**'
       - '!.git/**'
       - '!test/**'
       - '!**/*.test.*'
       - '!**/*.spec.*'
       - '!**/*.map'
       - '!docs/**'
       - '!coverage/**'
       - '!.env*'
       - '!tsconfig.json'
       - '!jest.config.*'
   ```

4. **Move large deps to layers:**
   ```yaml
   layers:
     sharpLayer:
       path: layers/sharp
       compatibleRuntimes: [nodejs20.x]
       compatibleArchitectures: [arm64]
   functions:
     imageProcessor:
       handler: src/image.handler
       layers: [{ Ref: SharpLayerLambdaLayer }]
   ```

### AWS Lambda size limits

| Item                        | Limit         |
| --------------------------- | ------------- |
| Deployment package (zipped) | 50 MB         |
| Unzipped package + layers   | 250 MB        |
| `/tmp` storage              | 512 MB–10 GB  |
| Total code storage          | 75 GB         |
| Layers per function         | 5             |
| Layer version               | 50 MB zipped  |

---

## Timeout Issues

### API Gateway integration timeout

**Error:** `504 Gateway Timeout` even though Lambda hasn't finished.

**Cause:** API Gateway default integration timeout is 29 seconds.

**Fix (v4.4.13+):**
```yaml
functions:
  longRunning:
    handler: src/handler.main
    timeout: 60
    events:
      - http:
          path: /process
          method: POST
          timeout: 60          # API GW integration timeout (requires quota increase)
```

**Alternative: async pattern for long operations:**
```yaml
functions:
  startProcess:
    handler: src/handler.start
    timeout: 10
    events:
      - httpApi: { path: /process, method: POST }
    # Returns 202 with job ID immediately

  processWorker:
    handler: src/handler.process
    timeout: 900              # 15 min max
    events:
      - sqs:
          arn: !GetAtt ProcessQueue.Arn
```

### Lambda timeout

**Error:** `Task timed out after X seconds`

**Diagnostic:**
```typescript
// Add remaining time logging
export const handler = async (event: any, context: Context) => {
  console.log('Remaining time:', context.getRemainingTimeInMillis(), 'ms');
  // ... your logic
  console.log('After work, remaining:', context.getRemainingTimeInMillis(), 'ms');
};
```

**Common causes:**
- VPC Lambda waiting for ENI attachment.
- Downstream service (DB, API) responding slowly.
- Unresolved promises / missing `await`.

---

## API Gateway Limits

### Key limits reference

| Limit                           | REST API (v1)  | HTTP API (v2)  |
| ------------------------------- | -------------- | -------------- |
| Integration timeout             | 29s (default)  | 30s (max)      |
| Payload size                    | 10 MB          | 10 MB          |
| Routes per API                  | 300            | 300            |
| Stages per API                  | 10             | 10             |
| Authorizers per API             | 10             | 10             |
| Throttle (account-level)        | 10,000 rps     | 10,000 rps     |
| Burst limit                     | 5,000          | 5,000          |
| WebSocket message payload       | 128 KB         | 128 KB         |
| WebSocket connection duration   | 2 hours        | 2 hours        |

### Working around payload limits

```typescript
// For large uploads: use presigned S3 URLs
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

export const getUploadUrl = async () => {
  const url = await getSignedUrl(
    new S3Client({}),
    new PutObjectCommand({ Bucket: process.env.BUCKET, Key: `uploads/${Date.now()}` }),
    { expiresIn: 3600 }
  );
  return { statusCode: 200, body: JSON.stringify({ uploadUrl: url }) };
};
```

### Throttling errors (429)

```yaml
# Configure usage plans to prevent abuse
provider:
  apiGateway:
    throttle:
      burstLimit: 200
      rateLimit: 100

# Per-function throttle
functions:
  expensiveOp:
    handler: handler.main
    reservedConcurrency: 10    # Limits concurrent executions
```

---

## Plugin Conflicts

### Common conflict: built-in esbuild vs plugin esbuild

**Error:** `Cannot use both built-in esbuild and serverless-esbuild plugin`

**Fix:** Choose one. If using the plugin:
```yaml
build:
  esbuild: false               # Disable built-in (v4)
plugins:
  - serverless-esbuild
custom:
  esbuild:
    bundle: true
    minify: true
```

### Common conflict: webpack + esbuild

Never use both. Pick one bundler:
- **esbuild** (v4 built-in): Fast, zero-config, handles most cases.
- **webpack**: More control, complex config, needed for advanced transforms.

### Plugin load order matters

```yaml
plugins:
  # Build plugins first
  - serverless-webpack            # or serverless-esbuild
  # Feature plugins
  - serverless-step-functions
  - serverless-domain-manager
  - serverless-iam-roles-per-function
  - serverless-plugin-canary-deployments
  # Local dev last
  - serverless-offline
```

**Rule:** `serverless-offline` should always be **last** in the plugins list.

### Check plugin v4 compatibility

```bash
# Check if plugin supports Serverless v4
npm info serverless-plugin-name peerDependencies
# Look for: "serverless": "^4.0.0" or ">=3.0.0"

# Test with --debug flag
serverless deploy --debug
```

---

## serverless-offline Quirks

### TypeScript not compiling

**Problem:** Handlers return module-not-found errors with serverless-offline in v4.

**Fix:** Ensure the build plugin is listed before offline:
```yaml
build:
  esbuild:
    bundle: true
plugins:
  - serverless-offline           # v4 built-in esbuild runs before plugins
```

Or if using external esbuild plugin:
```yaml
build:
  esbuild: false
plugins:
  - serverless-esbuild           # Must be before offline
  - serverless-offline
```

### Environment variables not loading

**Problem:** `.env` values not available in offline mode.

**Fix:** v4 auto-loads `.env` and `.env.{stage}`. Verify:
```bash
serverless offline --stage dev   # Loads .env and .env.dev
```

For explicit loading:
```yaml
useDotenv: true                  # Explicit opt-in (usually not needed in v4)
```

### API Gateway v2 (httpApi) differences

- `serverless-offline` emulates httpApi differently from http.
- JWT authorizers are **not emulated** — requests pass through without auth locally.
- Event format differs: httpApi uses payload format 2.0.

**Workaround for auth testing:**
```typescript
// Middleware to skip auth check locally
const isOffline = process.env.IS_OFFLINE === 'true';
if (!isOffline) {
  await validateAuth(event);
}
```

### WebSocket emulation issues

```bash
# WebSocket support requires additional flag
serverless offline --websocketPort 3001

# Known limitations:
# - Connection management differs from production
# - $connect/$disconnect timing differs
# - No API Gateway request context emulation
```

### Hot reload not working

```bash
# Ensure reloadHandler is enabled
serverless offline --reloadHandler

# With esbuild, use watch mode in a separate terminal:
npx esbuild src/**/*.ts --bundle --outdir=.esbuild --watch
```

### Port conflicts

```bash
# Default ports: HTTP=3000, Lambda=3002, WebSocket=3001
serverless offline --httpPort 4000 --lambdaPort 4002

# Or in serverless.yml
custom:
  serverless-offline:
    httpPort: 4000
    lambdaPort: 4002
    websocketPort: 4001
```

---

## Debugging Lambda Functions

### Local invocation

```bash
# Invoke locally with event data
serverless invoke local -f myFunction -d '{"key": "value"}'

# With event file
serverless invoke local -f myFunction -p events/test-event.json

# With environment variables
serverless invoke local -f myFunction -e KEY=value

# v4 live dev mode (connects to real AWS, live reload)
serverless dev
```

### Remote debugging

```bash
# Tail logs in real-time
serverless logs -f myFunction --tail --stage dev

# Filter logs
serverless logs -f myFunction --filter "ERROR" --startTime 1h

# Invoke deployed function
serverless invoke -f myFunction -d '{"test": true}' --stage dev --log
```

### Debug with Node.js inspector

```bash
# Start offline with debug port
node --inspect ./node_modules/.bin/serverless offline

# Or
SLS_DEBUG=* serverless offline
```

### Enable verbose logging

```bash
# Maximum verbosity
SLS_DEBUG=* serverless deploy --verbose --debug

# CloudFormation events during deploy
serverless deploy --verbose         # Shows CF events as they happen
```

### X-Ray tracing setup

```yaml
provider:
  tracing:
    lambda: true
    apiGateway: true
  iam:
    role:
      managedPolicies:
        - arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess
```

```typescript
// Instrument AWS SDK calls
import { captureAWSv3Client } from 'aws-xray-sdk-core';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';

const ddb = captureAWSv3Client(new DynamoDBClient({}));
```

---

## esbuild / Bundling Issues

### Native modules not bundling

**Error:** `Error: Cannot find module 'sharp'` (or bcrypt, canvas, etc.)

**Fix:** Mark native modules as external and use layers:
```yaml
build:
  esbuild:
    bundle: true
    external: ['@aws-sdk/*', 'sharp', 'bcrypt']
```

### ESM / CommonJS conflicts

**Error:** `require() of ES Module` or `ERR_REQUIRE_ESM`

**Fix for v4:**
```yaml
build:
  esbuild:
    bundle: true
    format: cjs                  # Force CommonJS output (default)
    # OR for ESM:
    format: esm
    banner:
      js: |
        import { createRequire } from 'module';
        const require = createRequire(import.meta.url);
```

### Source maps not working

```yaml
build:
  esbuild:
    sourcemap:
      type: linked               # 'inline' | 'linked' | 'external'
      setNodeOptions: true        # Adds --enable-source-maps to NODE_OPTIONS
```

### Build too slow

```yaml
build:
  esbuild:
    buildConcurrency: 3          # Parallel function builds (default: 3)
    minify: false                # Disable in dev for speed
    external: ['@aws-sdk/*']     # Don't bundle what's in the runtime
```

---

## Environment & Auth Errors

### Serverless Dashboard auth failure

**Error:** `Serverless Framework CLI could not be authenticated`

**Fix:**
```bash
# Re-authenticate
serverless login

# Or use access key (CI/CD)
export SERVERLESS_ACCESS_KEY=<your-key>

# Or use license key (v4)
export SERVERLESS_LICENSE_KEY=<your-key>
```

### AWS credentials not found

**Error:** `AWS provider credentials not found`

**Fix priority order:**
1. Environment variables: `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`
2. AWS profile: `--aws-profile myprofile` or `provider.profile`
3. Default profile: `~/.aws/credentials [default]`
4. EC2/ECS instance role (in CI/CD)

```bash
# Verify credentials
aws sts get-caller-identity

# Use specific profile
serverless deploy --aws-profile prod-account --stage prod
```

### Stage variable not resolving

**Error:** `Variable resolution errored with: Cannot resolve variable at "provider.environment.MY_VAR"`

**Common causes:**
- SSM parameter doesn't exist in the target region.
- Missing fallback for optional variables.

**Fix:**
```yaml
provider:
  environment:
    # Add fallback value
    MY_VAR: ${ssm:/${sls:stage}/my-var, 'default-value'}
    # Or make it optional
    OPTIONAL_VAR: ${env:MAYBE_SET, ''}
```
