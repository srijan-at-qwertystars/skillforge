---
name: serverless-framework
description: >
  Expert guidance for Serverless Framework v4 projects on AWS. Use when: building or configuring serverless.yml files, deploying AWS Lambda functions, setting up API Gateway endpoints, configuring event sources (S3, SQS, SNS, DynamoDB Streams, Schedule, WebSocket), managing serverless plugins (serverless-offline, serverless-esbuild, serverless-domain-manager), packaging functions, creating layers, defining custom CloudFormation resources, configuring stages/environments, using Serverless Dashboard, or setting up CI/CD pipelines for serverless deployments. Do NOT use for: AWS SAM templates (template.yaml/sam build), Terraform or Pulumi serverless infrastructure, AWS CDK serverless constructs, Vercel or Netlify deployment workflows, Kubernetes or container orchestration (ECS/EKS/Fargate), or general CloudFormation authoring outside Serverless Framework context.
---

# Serverless Framework v4 — Skill Reference

## Installation & Setup
```bash
npm install -g serverless
serverless login                    # Dashboard auth
export SERVERLESS_ACCESS_KEY=<key>  # CI auth alternative
serverless create --template aws-nodejs-typescript --path my-svc && cd my-svc && npm i
```
Templates: `aws-nodejs`, `aws-nodejs-typescript`, `aws-python3`, `aws-java-maven`, `aws-go`.

## Core serverless.yml Structure
```yaml
service: my-service
org: my-org                        # Dashboard org (optional)
app: my-app                        # Dashboard app (optional)
frameworkVersion: '4'
provider:
  name: aws
  runtime: nodejs20.x
  stage: ${opt:stage, 'dev'}
  region: ${opt:region, 'us-east-1'}
  memorySize: 512
  timeout: 10
  architecture: arm64              # Graviton — ~20% cheaper
  environment:
    TABLE_NAME: ${self:service}-${sls:stage}
  tags: { project: '${self:service}' }
  deploymentBucket:
    name: ${self:service}-deploys-${aws:accountId}
    serverSideEncryption: AES256
build:
  esbuild:                         # Built-in TS/ESM in v4 (no plugin needed)
    bundle: true
    minify: true
    external: ['@aws-sdk/*']
    sourcemap: { type: linked, setNodeOptions: true }
functions:
  # see Functions section
plugins:
  - serverless-domain-manager
  - serverless-offline             # Keep offline last
resources:
  # see Custom Resources section
```

## Functions Configuration
```yaml
functions:
  createUser:
    handler: src/handlers/user.create   # file: src/handlers/user.ts → export const create
    runtime: nodejs20.x                 # Override provider default
    memorySize: 256
    timeout: 30
    description: Create a new user
    environment: { SPECIFIC_VAR: value }
    reservedConcurrency: 10             # Max concurrent executions
    provisionedConcurrency: 5           # Pre-warmed instances
    ephemeralStorageSize: 1024          # /tmp in MB (512-10240)
    layers:
      - { Ref: SharedLibLambdaLayer }
    events:
      - httpApi: { path: /users, method: POST }
```

## Event Sources

### HTTP API (API Gateway v2 — preferred)
```yaml
- httpApi:
    path: /users/{id}
    method: GET
    authorizer: { type: jwt, id: !Ref HttpApiAuthorizerId }
```

### REST API (API Gateway v1) — use when you need usage plans, API keys, request validation
```yaml
- http:
    path: /users/{id}
    method: GET
    cors: true
    authorizer:
      name: auth
      type: COGNITO_USER_POOLS
      arn: !GetAtt UserPool.Arn
    request:
      parameters: { paths: { id: true } }
```

### S3
```yaml
- s3:
    bucket: uploads-${sls:stage}
    event: s3:ObjectCreated:*
    rules: [{ prefix: images/ }, { suffix: .jpg }]
    existing: true                      # Use pre-existing bucket
```

### SQS
```yaml
- sqs:
    arn: !GetAtt MyQueue.Arn
    batchSize: 10
    maximumBatchingWindow: 5
    functionResponseType: ReportBatchItemFailures   # Always enable this
```

### SNS
```yaml
- sns:
    topicName: notifications-${sls:stage}
    filterPolicy: { type: [order_placed] }
```

### DynamoDB Streams
```yaml
- stream:
    type: dynamodb
    arn: !GetAtt MyTable.StreamArn
    batchSize: 100
    startingPosition: LATEST
    maximumRetryAttempts: 3
    bisectBatchOnFunctionError: true
    filterPatterns:
      - eventName: [MODIFY]
        dynamodb: { NewImage: { status: { S: [active] } } }
```

### Schedule (EventBridge)
```yaml
- schedule:
    rate: rate(1 hour)                 # Or: cron(0 9 * * ? *)
    enabled: true
    input: { action: cleanup }
```

### WebSocket
```yaml
- websocket: { route: $connect }
- websocket: { route: $disconnect }
- websocket: { route: sendMessage }
```

### Kinesis
```yaml
- stream:
    type: kinesis
    arn: !GetAtt MyStream.Arn
    batchSize: 100
    startingPosition: TRIM_HORIZON
    parallelizationFactor: 10
```

### EventBridge
```yaml
- eventBridge:
    pattern:
      source: [my.custom.source]
      detail-type: [OrderPlaced]
```

## Packaging

### Global patterns
```yaml
package:
  patterns:
    - '!./**'                          # Exclude all first
    - 'src/**'                         # Include source
    - '!src/**/*.test.*'               # Exclude tests
    - '!.env*'
```

### Individual packaging (recommended for 3+ functions)
```yaml
package:
  individually: true
functions:
  fnA:
    handler: src/a/handler.main
    package:
      patterns: ['!./**', 'src/a/**', 'src/shared/**']
  fnB:
    handler: src/b/handler.main
    package:
      artifact: dist/fnB.zip          # Pre-built artifact
```

## Layers
```yaml
layers:
  sharedLib:
    path: layers/shared               # Must contain nodejs/node_modules/ for Node
    name: ${self:service}-shared-${sls:stage}
    compatibleRuntimes: [nodejs20.x]
    retain: false
functions:
  myFn:
    handler: handler.main
    layers:
      - { Ref: SharedLibLambdaLayer }  # Auto-generated logical ID: <TitleCase>LambdaLayer
      - arn:aws:lambda:us-east-1:123456789:layer:ext-layer:3  # External ARN
```

## IAM Roles

### Provider-level (shared role for all functions)
```yaml
provider:
  iam:
    role:
      statements:
        - Effect: Allow
          Action: [dynamodb:GetItem, dynamodb:PutItem, dynamodb:Query]
          Resource: [!GetAtt MyTable.Arn, !Sub '${MyTable.Arn}/index/*']
        - Effect: Allow
          Action: [s3:GetObject, s3:PutObject]
          Resource: arn:aws:s3:::${self:service}-*/*
        - Effect: Allow
          Action: sqs:SendMessage
          Resource: !GetAtt MyQueue.Arn
```

### Per-function roles (serverless-iam-roles-per-function plugin)
```yaml
plugins: [serverless-iam-roles-per-function]
functions:
  readOnly:
    handler: handler.read
    iamRoleStatements:
      - Effect: Allow
        Action: dynamodb:GetItem
        Resource: !GetAtt MyTable.Arn
```

## VPC Configuration
```yaml
provider:
  vpc:
    securityGroupIds: [sg-xxxxxxxx]
    subnetIds: [subnet-aaaa, subnet-bbbb]
  iam:
    role:
      managedPolicies:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole
functions:
  dbWriter:
    handler: handler.write
    vpc:                               # Per-function override
      securityGroupIds: [sg-yyyyyyyy]
      subnetIds: [subnet-cccc]
```

## Plugins

### serverless-offline — local API Gateway + Lambda emulation
```bash
npm i -D serverless-offline
serverless offline start --httpPort 3000 --stage dev
```

### serverless-domain-manager — custom domains
```yaml
custom:
  customDomain:
    domainName: api.${param:domain}
    basePath: ''
    stage: ${sls:stage}
    certificateName: '*.example.com'
    createRoute53Record: true
    endpointType: regional
    securityPolicy: tls_1_2
    autoDomain: true                   # Auto-create on deploy
```
Run `serverless create_domain` before first deploy. `serverless delete_domain` to clean up.

### Built-in esbuild (v4) — replaces serverless-webpack and serverless-esbuild plugins
```yaml
build:
  esbuild:
    bundle: true
    minify: true
    external: ['@aws-sdk/*']
    buildConcurrency: 3
```

## Stages, Variables & Parameters

### Stage-specific params (v4 syntax)
```yaml
stages:
  default:
    params:
      tableName: ${self:service}-${sls:stage}
      logLevel: info
  prod:
    params: { logLevel: warn }
  dev:
    params: { logLevel: debug }
provider:
  environment:
    TABLE_NAME: ${param:tableName}
    LOG_LEVEL: ${param:logLevel}
```

### Variable resolution
```yaml
${self:service}              # Self-reference this config
${sls:stage}                 # Current stage name
${aws:accountId}             # AWS account ID
${aws:region}                # Deployed region
${opt:stage}                 # CLI --stage option
${env:MY_VAR}                # Environment variable
${param:key}                 # Stage parameter
${file(./config.json):key}   # External file value
${ssm:/path/to/param}        # SSM Parameter Store (auto-decrypts SecureString)
${ssm(raw):/path/to/param}   # SSM without decryption
${terraform:outputs:vpc_id}  # Terraform state integration
```

### .env files (auto-loaded in v4)
Files loaded: `.env` (always), `.env.dev` (when `--stage dev`), `.env.prod` (when `--stage prod`).

## Custom Resources (CloudFormation)
```yaml
resources:
  Resources:
    OrderTable:
      Type: AWS::DynamoDB::Table
      Properties:
        TableName: ${param:tableName}
        BillingMode: PAY_PER_REQUEST
        AttributeDefinitions:
          - { AttributeName: pk, AttributeType: S }
          - { AttributeName: sk, AttributeType: S }
        KeySchema:
          - { AttributeName: pk, KeyType: HASH }
          - { AttributeName: sk, KeyType: RANGE }
        StreamSpecification: { StreamViewType: NEW_AND_OLD_IMAGES }
    OrderQueue:
      Type: AWS::SQS::Queue
      Properties:
        QueueName: ${self:service}-${sls:stage}-queue
        VisibilityTimeout: 60
        RedrivePolicy: { deadLetterTargetArn: !GetAtt DLQ.Arn, maxReceiveCount: 3 }
    DLQ:
      Type: AWS::SQS::Queue
      Properties: { QueueName: '${self:service}-${sls:stage}-dlq' }
  Outputs:
    TableArn:
      Value: !GetAtt OrderTable.Arn
      Export: { Name: '${self:service}-${sls:stage}-table-arn' }
    ApiUrl:
      Value: !Sub 'https://${HttpApi}.execute-api.${aws:region}.amazonaws.com'
```

## Serverless Dashboard
Connect with `org`/`app`/`service` keys in config. Features: encrypted stage params/secrets via `${param:key}`, real-time invocation metrics, error rate alerts, cold start tracking, distributed tracing, RBAC, built-in CI/CD from Git branches.

## CI/CD Deployment

### GitHub Actions
```yaml
# .github/workflows/deploy.yml
name: Deploy
on: { push: { branches: [main] } }
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npx serverless deploy --stage prod
        env:
          SERVERLESS_ACCESS_KEY: ${{ secrets.SERVERLESS_ACCESS_KEY }}
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

### CLI commands
```bash
serverless deploy                           # Full stack deploy
serverless deploy --stage prod              # Deploy to specific stage
serverless deploy function -f myFn          # Single function (fast)
serverless remove --stage dev               # Tear down stack
serverless invoke -f myFn -d '{"k":"v"}'   # Remote invoke
serverless invoke local -f myFn -p ev.json  # Local invoke
serverless logs -f myFn --tail              # Stream CloudWatch logs
serverless info --stage prod                # Show endpoints/resources
serverless dev                              # v4 live dev mode
serverless package                          # Package without deploying
```

## Multi-Region
Deploy across regions: `for r in us-east-1 eu-west-1; do serverless deploy --stage prod --region $r; done`
Use SSM for region-specific config: `${ssm:/certs/${aws:region}/arn}`.

## Monitoring & Observability
```yaml
provider:
  logRetentionInDays: 14
  logs:
    httpApi: true                          # API Gateway v2 access logs
  tracing: { lambda: true, apiGateway: true }  # X-Ray
```

## Key Rules
- Use `${sls:stage}` (not `${opt:stage}`) in resource names for consistency.
- Set `package.individually: true` for services with 3+ functions — reduces cold starts.
- Use `arm64` architecture for ~20% cost savings on compatible runtimes.
- Prefer `httpApi` (v2) over `http` (v1) unless you need usage plans/API keys/request validation.
- Never hardcode AWS account IDs — use `${aws:accountId}`.
- Set `reservedConcurrency` to protect downstream services from Lambda auto-scaling.
- Always enable `functionResponseType: ReportBatchItemFailures` on SQS triggers.
- Use `.env.{stage}` for local secrets; Dashboard params for deployed secrets.
- Use `serverless deploy function -f <name>` for fast single-function iteration.
- Use `serverless dev` for live local development connected to real AWS events.

---

## Extended Resources

### Reference Documentation

| Document | What's Inside |
|---|---|
| `references/advanced-patterns.md` | Multi-service architectures, Serverless Compose, output sharing, Step Functions, custom authorizers (Lambda/Cognito/JWT/API key), warming strategies, provisioned concurrency, canary deployments, cross-account and multi-region deployment, monorepo patterns, event-driven architectures |
| `references/troubleshooting.md` | CloudFormation 500 resource limit, deployment failures, rollback recovery, permission errors, cold start mitigation, large package optimization, timeout issues, API Gateway limits, plugin conflicts, serverless-offline quirks, esbuild issues, debugging Lambda |
| `references/api-reference.md` | Complete serverless.yml reference: all provider options, function properties, every event type with full options, package config, layers, stages/parameters, variables syntax, custom resources with extensions, plugin API hooks, build config, CLI commands |

### Scripts

| Script | Purpose |
|---|---|
| `scripts/init-serverless.sh` | Scaffold a new Serverless v4 project with TypeScript, esbuild, offline plugin, sample handlers, tests, and config. Usage: `./init-serverless.sh my-api [--org acme]` |
| `scripts/deploy-ops.sh` | Deployment operations wrapper: deploy, remove, invoke, logs, info, print, package, rollback, prune. With stage selection, confirmation prompts, and timing. Usage: `./deploy-ops.sh deploy -s prod` |

### Templates

| Template | Purpose |
|---|---|
| `assets/serverless.template.yml` | Production serverless.yml with REST + HTTP API, JWT/Cognito auth, API keys with usage plans, DynamoDB (single-table with GSI), SQS with DLQ, scheduled tasks, DynamoDB Streams, CloudWatch alarms |
| `assets/webpack.config.template.js` | Webpack config for TypeScript bundling with ts-loader, source maps, tree-shaking, AWS SDK externals (for projects not using built-in esbuild) |
| `assets/ci-workflow.template.yml` | GitHub Actions multi-stage pipeline: test → package → dev → staging → prod, with OIDC auth, manual approval for prod, smoke tests, rollback job |
