# Serverless Framework v4 — API Reference

Complete `serverless.yml` configuration reference for AWS provider.

## Table of Contents

- [Top-Level Properties](#top-level-properties)
- [Provider Options](#provider-options)
- [Function Properties](#function-properties)
- [Event Types](#event-types)
- [Package Configuration](#package-configuration)
- [Layers](#layers)
- [Stages & Parameters](#stages--parameters)
- [Variables Syntax](#variables-syntax)
- [Custom Resources](#custom-resources)
- [Plugins](#plugins)
- [Plugin API](#plugin-api)
- [Build Configuration](#build-configuration)
- [CLI Commands](#cli-commands)

---

## Top-Level Properties

```yaml
service: my-service              # REQUIRED — service name (used in stack name)
frameworkVersion: '4'            # Recommended — enforce Serverless version
org: my-org                      # Dashboard organization
app: my-app                      # Dashboard application name
useDotenv: true                  # Auto-load .env files (default: true in v4)

provider: {}                     # AWS provider configuration
functions: {}                    # Lambda function definitions
layers: {}                       # Lambda layer definitions
resources: {}                    # CloudFormation resources
plugins: []                      # Plugin list
custom: {}                       # Custom variables for plugins
stages: {}                       # Stage-specific parameters (v4)
build: {}                        # Build configuration (v4 esbuild)
package: {}                      # Packaging configuration
```

---

## Provider Options

```yaml
provider:
  name: aws                           # REQUIRED — only 'aws' supported in v4

  # Runtime & Architecture
  runtime: nodejs20.x                  # Default runtime for all functions
  architecture: arm64                  # 'arm64' (Graviton) or 'x86_64'

  # Deployment Target
  stage: ${opt:stage, 'dev'}           # Default stage
  region: ${opt:region, 'us-east-1'}   # Default region
  profile: my-aws-profile             # AWS credentials profile
  stackName: custom-stack-name         # Override CloudFormation stack name
  deploymentMethod: direct             # 'direct' (default) or 'changesets'
  disableRollback: false               # true = don't rollback on failure (debug)

  # Function Defaults
  memorySize: 512                      # Default memory (MB) — 128–10240
  timeout: 10                          # Default timeout (seconds) — 1–900
  ephemeralStorageSize: 512            # /tmp size (MB) — 512–10240
  reservedConcurrency: 100             # Max concurrent executions

  # Environment Variables
  environment:
    GLOBAL_VAR: value
    TABLE_NAME: ${param:tableName}

  # Tags
  tags:
    project: ${self:service}
    environment: ${sls:stage}
  stackTags:
    ManagedBy: serverless

  # Deployment Bucket
  deploymentBucket:
    name: ${self:service}-deploys-${aws:accountId}
    serverSideEncryption: AES256       # or aws:kms
    sseKMSKeyId: alias/my-key          # When using aws:kms
    blockPublicAccess: true
    skipPolicySetup: false
    maxPreviousDeploymentArtifacts: 5
    versioning: true

  # IAM Configuration
  iam:
    role:
      name: ${self:service}-${sls:stage}-role
      path: /my-service/
      statements:
        - Effect: Allow
          Action: ['dynamodb:*']
          Resource: '*'
      managedPolicies:
        - arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess
      permissionsBoundary: arn:aws:iam::123:policy/boundary
      tags:
        project: ${self:service}
    deploymentRole: arn:aws:iam::123:role/DeployRole

  # VPC
  vpc:
    securityGroupIds: [sg-xxxxxxxx]
    subnetIds: [subnet-aaaa, subnet-bbbb]

  # Logging
  logRetentionInDays: 14               # CloudWatch log retention (1,3,5,7,14,30,60,90,etc.)
  logs:
    httpApi: true                       # HTTP API access logs
    restApi:                            # REST API access logs
      accessLogging: true
      executionLogging: true
      level: INFO                       # ERROR | INFO
      fullExecutionData: true
    websocket: true
    frameworkLambda: true

  # Tracing
  tracing:
    lambda: true                        # X-Ray tracing for Lambda
    apiGateway: true                    # X-Ray tracing for API Gateway

  # API Gateway (REST API v1)
  apiGateway:
    restApiId: xxxxxxxxxx               # Use existing API
    restApiRootResourceId: xxxxxxxxxx
    restApiResources:
      /users: xxxxxxxxxx
    description: My REST API
    binaryMediaTypes:
      - '*/*'
    minimumCompressionSize: 1024
    apiKeys:
      - name: myKey
        value: myKeyValue               # Optional custom value
        description: My API key
        enabled: true
      - free:                           # Named group
          - freeKey
      - premium:
          - premiumKey
    usagePlan:
      - free:
          quota: { limit: 1000, period: MONTH }
          throttle: { burstLimit: 20, rateLimit: 10 }
      - premium:
          quota: { limit: 100000, period: MONTH }
          throttle: { burstLimit: 200, rateLimit: 100 }
    metrics: true                       # Enable detailed metrics
    shouldStartNameWithService: true

  # HTTP API (API Gateway v2)
  httpApi:
    id: xxxxxxxxxx                      # Use existing HTTP API
    name: ${self:service}-${sls:stage}
    payload: '2.0'                      # Payload format version
    cors:                               # CORS configuration
      allowedOrigins:
        - https://example.com
      allowedHeaders:
        - Content-Type
        - Authorization
      allowedMethods:
        - GET
        - POST
        - PUT
        - DELETE
      allowCredentials: true
      maxAge: 86400
    authorizers:
      jwtAuth:
        type: jwt
        identitySource: $request.header.Authorization
        issuerUrl: https://cognito-idp.us-east-1.amazonaws.com/us-east-1_xxxxx
        audience:
          - xxxxxxxxx
    metrics: true
    disableDefaultEndpoint: false

  # Lambda Function URLs
  url: true                             # Enable for all functions (or per-function)

  # CloudFront Lambda@Edge
  # (configure at function level)

  # Rollback Configuration
  rollbackConfiguration:
    monitoringTimeInMinutes: 10
    rollbackTriggers:
      - arn: !Ref ErrorAlarm
        type: AWS::CloudWatch::Alarm
```

---

## Function Properties

```yaml
functions:
  myFunction:
    # Core
    handler: src/handlers/my.handler     # REQUIRED — file.exportName
    name: ${self:service}-${sls:stage}-myFunction  # Override function name
    description: My function description
    runtime: nodejs20.x                  # Override provider default
    architecture: arm64                  # Override provider default

    # Performance
    memorySize: 256                      # MB (128–10240)
    timeout: 30                          # Seconds (1–900)
    ephemeralStorageSize: 1024           # /tmp MB (512–10240)
    reservedConcurrency: 10              # Max concurrent (0 = disabled)
    provisionedConcurrency: 5            # Pre-warmed instances

    # Environment
    environment:
      FUNC_SPECIFIC_VAR: value

    # Networking
    vpc:
      securityGroupIds: [sg-xxxxxxxx]
      subnetIds: [subnet-aaaa]

    # Lambda URL
    url:
      cors:
        allowedOrigins: ['*']
        allowedMethods: ['GET', 'POST']
      authorizer: aws_iam               # 'aws_iam' or 'none'
      invokeMode: BUFFERED               # 'BUFFERED' or 'RESPONSE_STREAM'

    # Layers
    layers:
      - { Ref: SharedLibLambdaLayer }
      - arn:aws:lambda:us-east-1:123:layer:my-layer:3

    # Tags
    tags:
      team: backend

    # Tracing
    tracing: Active                      # 'Active' or 'PassThrough'

    # Packaging (per-function override)
    package:
      patterns:
        - '!./**'
        - 'src/handlers/my.*'
        - 'src/shared/**'
      artifact: dist/my-function.zip     # Use pre-built artifact

    # Dead Letter Queue
    onError: arn:aws:sqs:us-east-1:123:my-dlq
    # Or: onError: arn:aws:sns:us-east-1:123:my-topic

    # KMS Key for environment variable encryption
    kmsKeyArn: arn:aws:kms:us-east-1:123:key/xxxxx

    # File system (EFS)
    fileSystemConfig:
      arn: arn:aws:elasticfilesystem:us-east-1:123:access-point/fsap-xxxxx
      localMountPath: /mnt/data

    # Condition (deploy only in certain stages)
    condition: IsProduction

    # Events
    events: []                           # See Event Types section
```

---

## Event Types

### httpApi — API Gateway v2 (preferred)

```yaml
events:
  - httpApi:
      path: /users/{id}
      method: GET
      authorizer:
        name: jwtAuth                    # Reference provider.httpApi.authorizers
        scopes:
          - user.read
  - httpApi: '*'                         # Catch-all route
  - httpApi:
      path: /users
      method: POST
```

### http — REST API (API Gateway v1)

```yaml
events:
  - http:
      path: /users/{id}
      method: GET
      cors: true                          # Simple CORS
      cors:                               # Detailed CORS
        origin: '*'
        headers:
          - Content-Type
          - Authorization
        allowCredentials: true
      private: true                       # Require API key
      authorizer:
        name: myAuthorizer
        type: request                     # 'token' | 'request' | 'COGNITO_USER_POOLS'
        arn: !GetAtt UserPool.Arn         # For Cognito
        identitySource: method.request.header.Authorization
        resultTtlInSeconds: 300
        claims:
          - email
          - sub
      request:
        parameters:
          paths:
            id: true                      # Required path param
          querystrings:
            page: false                   # Optional query param
          headers:
            x-custom: false
        schemas:
          application/json: ${file(schemas/create-user.json)}
        passThrough: NEVER                # WHEN_NO_MATCH | WHEN_NO_TEMPLATES | NEVER
      timeout: 29                         # API GW integration timeout (v4.4.13+)
```

### schedule — EventBridge Schedule

```yaml
events:
  - schedule:
      rate: rate(1 hour)                  # rate() or cron() expression
      # cron: cron(0 9 * * ? *)
      name: daily-cleanup
      description: Run daily cleanup
      enabled: true                       # false to disable
      input:                              # Static input
        action: cleanup
      inputPath: '$.detail'               # JSONPath from event
      inputTransformer:
        inputPathsMap:
          source: '$.source'
        inputTemplate: '{"src": <source>}'
```

### s3 — S3 Bucket Events

```yaml
events:
  - s3:
      bucket: my-bucket                   # Creates bucket if not existing
      event: s3:ObjectCreated:*           # s3:ObjectRemoved:*, etc.
      rules:
        - prefix: uploads/
        - suffix: .jpg
      existing: true                      # Use pre-existing bucket
      forceDeploy: true                   # Force update notification config
```

### sqs — SQS Queue Events

```yaml
events:
  - sqs:
      arn: !GetAtt MyQueue.Arn
      # arn: arn:aws:sqs:us-east-1:123:my-queue
      batchSize: 10                       # 1–10000 (default: 10)
      maximumBatchingWindow: 5            # Seconds — wait for batch fill
      functionResponseType: ReportBatchItemFailures  # ALWAYS set this
      enabled: true
      filterPatterns:
        - body:
            type: [order]
      maximumConcurrency: 10              # Max concurrent Lambda invocations
```

### sns — SNS Topic Events

```yaml
events:
  - sns:
      arn: !Ref MyTopic
      # topicName: my-topic               # Creates topic
      filterPolicy:
        type: [order_placed]
        status: [{ anything-but: [cancelled] }]
      filterPolicyScope: MessageBody       # or MessageAttributes (default)
      redrivePolicy:
        deadLetterTargetArn: !GetAtt SnsDLQ.Arn
```

### stream — DynamoDB / Kinesis Streams

```yaml
events:
  # DynamoDB Stream
  - stream:
      type: dynamodb
      arn: !GetAtt MyTable.StreamArn
      batchSize: 100                      # 1–10000
      startingPosition: LATEST            # LATEST | TRIM_HORIZON
      maximumRetryAttempts: 3
      bisectBatchOnFunctionError: true
      maximumRecordAgeInSeconds: 3600
      parallelizationFactor: 1            # 1–10
      functionResponseType: ReportBatchItemFailures
      filterPatterns:
        - eventName: [INSERT, MODIFY]
          dynamodb:
            NewImage:
              status: { S: [active] }
      destinations:
        onFailure: arn:aws:sqs:us-east-1:123:stream-dlq
      tumblingWindowInSeconds: 60         # Aggregation window

  # Kinesis Stream
  - stream:
      type: kinesis
      arn: !GetAtt MyStream.Arn
      batchSize: 100
      startingPosition: TRIM_HORIZON
      parallelizationFactor: 10
      batchWindow: 5
```

### websocket — WebSocket API

```yaml
events:
  - websocket:
      route: $connect
      authorizer:
        name: auth
        identitySource: route.request.querystring.token
  - websocket:
      route: $disconnect
  - websocket:
      route: $default                     # Catch-all route
  - websocket:
      route: sendMessage
      routeResponseSelectionExpression: $default
```

### eventBridge — EventBridge Events

```yaml
events:
  - eventBridge:
      # Default event bus
      pattern:
        source: [aws.ec2]
        detail-type: [EC2 Instance State-change Notification]
        detail:
          state: [stopped]

  - eventBridge:
      eventBus: !Ref CustomBus            # Custom event bus
      pattern:
        source: [com.myapp.orders]
        detail-type: [OrderCreated]
      inputTransformer:
        inputPathsMap:
          orderId: '$.detail.orderId'
        inputTemplate: '{"id": <orderId>}'
      retryPolicy:
        maximumEventAge: 3600
        maximumRetryAttempts: 3
      deadLetterQueueArn: !GetAtt EventDLQ.Arn

  - eventBridge:
      schedule: rate(1 hour)              # Schedule on EventBridge
      input:
        action: cleanup
```

### cognitoUserPool — Cognito Triggers

```yaml
events:
  - cognitoUserPool:
      pool: MyUserPool
      trigger: PreSignUp                  # PreSignUp, PostConfirmation,
                                          # PreAuthentication, PostAuthentication,
                                          # PreTokenGeneration, CustomMessage,
                                          # DefineAuthChallenge, CreateAuthChallenge,
                                          # VerifyAuthChallengeResponse, UserMigration
      existing: true
```

### alb — Application Load Balancer

```yaml
events:
  - alb:
      listenerArn: arn:aws:elasticloadbalancing:...
      priority: 1
      conditions:
        path: /api/*
        method: GET
      healthCheck:
        path: /health
        intervalSeconds: 30
      multiValueHeaders: true
```

### iot — IoT Rule

```yaml
events:
  - iot:
      name: myIoTRule
      sql: "SELECT * FROM 'my/topic'"
      sqlVersion: '2016-03-23'
      enabled: true
```

### cloudwatchEvent — CloudWatch Events (legacy)

```yaml
events:
  - cloudwatchEvent:
      event:
        source: [aws.ec2]
        detail-type: [EC2 Instance State-change Notification]
```

### cloudwatchLog — CloudWatch Log Subscriptions

```yaml
events:
  - cloudwatchLog:
      logGroup: /aws/lambda/other-function
      filter: ERROR
```

### alexaSkill, alexaSmartHome, kafka, activemq, rabbitmq, msk

```yaml
events:
  - alexaSkill: amzn1.ask.skill.xxxxx
  - kafka:
      accessConfigurations:
        saslScram512Auth: arn:aws:secretsmanager:...
      bootstrapServers:
        - broker1:9092
      topic: my-topic
      batchSize: 100
  - activemq:
      arn: arn:aws:mq:...
      queue: my-queue
      basicAuthArn: arn:aws:secretsmanager:...
      batchSize: 10
  - rabbitmq:
      arn: arn:aws:mq:...
      queue: my-queue
      basicAuthArn: arn:aws:secretsmanager:...
```

---

## Package Configuration

```yaml
package:
  individually: true                     # Separate zip per function (recommended)
  patterns:                              # Include/exclude patterns
    - '!./**'                            # Exclude everything
    - 'src/**'                           # Include source
    - '!src/**/*.test.*'                 # Exclude tests
    - '!src/**/*.spec.*'
    - '!node_modules/**'
    - '!.git/**'
    - '!docs/**'
    - '!coverage/**'
    - '!.env*'
  excludeDevDependencies: true           # Exclude devDependencies (default: true)
  artifact: dist/my-service.zip          # Pre-built artifact (skips packaging)
```

---

## Layers

```yaml
layers:
  sharedUtils:
    path: layers/shared                  # Must contain nodejs/node_modules/ for Node.js
    name: ${self:service}-${sls:stage}-shared
    description: Shared utility functions
    compatibleRuntimes:
      - nodejs20.x
      - nodejs18.x
    compatibleArchitectures:
      - arm64
      - x86_64
    licenseInfo: MIT
    retain: false                        # true = keep old versions on deploy
    allowedAccounts:                     # Cross-account sharing
      - '123456789012'
      - '*'                              # All accounts
```

**Logical ID convention:** `<TitleCaseName>LambdaLayer` (e.g., `SharedUtilsLambdaLayer`).

Reference in functions:
```yaml
functions:
  myFunc:
    layers:
      - { Ref: SharedUtilsLambdaLayer }  # Same-stack layer
      - arn:aws:lambda:us-east-1:123:layer:ext:3  # External layer ARN
```

Layer directory structure:
```
layers/shared/
└── nodejs/
    ├── node_modules/
    │   └── my-utils/
    └── package.json
```

---

## Stages & Parameters

```yaml
stages:
  default:                               # Applies to all stages unless overridden
    params:
      tableName: ${self:service}-${sls:stage}
      logLevel: info
      domainName: ${sls:stage}.api.example.com
    observability: true                  # Enable Dashboard monitoring

  dev:
    params:
      logLevel: debug
      domainName: dev.api.example.com
    observability: false

  staging:
    params:
      logLevel: info
      domainName: staging.api.example.com

  prod:
    params:
      logLevel: warn
      domainName: api.example.com
    observability: true
    resolvers:                           # Stage-specific variable resolvers
      terraform:
        type: terraform
        backend: s3
        bucket: my-tf-state
        key: prod/terraform.tfstate
```

Reference: `${param:tableName}`, `${param:logLevel}`, etc.

---

## Variables Syntax

### Built-in variable sources

```yaml
# Self-reference
${self:service}                          # Service name
${self:provider.stage}                   # Provider stage
${self:custom.myVar}                     # Custom variable

# Framework
${sls:stage}                             # Resolved stage name
${sls:instanceId}                        # Unique deployment ID

# AWS
${aws:accountId}                         # AWS account ID
${aws:region}                            # Deployed region

# CLI Options
${opt:stage}                             # --stage value
${opt:region}                            # --region value
${opt:verbose}                           # --verbose flag

# Environment Variables
${env:MY_VAR}                            # Process env variable
${env:MY_VAR, 'fallback'}               # With fallback

# Stage Parameters
${param:key}                             # From stages.{stage}.params
${param:key, 'default'}                  # With fallback

# External Files
${file(./config.json)}                   # Entire file
${file(./config.json):key}               # Specific key
${file(./config.yml):nested.key}         # Nested key
${file(./config.js):handler}             # JS module export

# AWS SSM Parameter Store
${ssm:/path/to/param}                    # Auto-decrypts SecureString
${ssm(raw):/path/to/param}              # Without decryption
${ssm:/path/${sls:stage}/key}           # With variable interpolation

# Terraform State
${terraform:outputs:vpc_id}              # Terraform output value

# CloudFormation
${cf:stack-name.OutputKey}               # Cross-stack output
${cf:stack-name.OutputKey, 'default'}    # With fallback

# S3
${s3:bucket/key}                         # S3 object content
```

### Variable resolution rules

1. Variables resolve **at deploy time**, not runtime.
2. Nested variables are supported: `${ssm:/${sls:stage}/key}`.
3. Fallback values: `${env:VAR, 'default'}` or `${env:VAR, ${self:custom.default}}`.
4. **Cannot use variables in `service` or `frameworkVersion`** fields.

---

## Custom Resources

```yaml
resources:
  # CloudFormation Resources
  Resources:
    MyResource:
      Type: AWS::Service::Resource
      DependsOn: OtherResource
      DeletionPolicy: Retain
      UpdateReplacePolicy: Retain
      Condition: IsProduction
      Properties: {}

  # CloudFormation Outputs
  Outputs:
    MyOutput:
      Description: My output value
      Value: !GetAtt MyResource.Arn
      Export:
        Name: ${self:service}-${sls:stage}-MyOutput
      Condition: IsProduction

  # CloudFormation Conditions
  Conditions:
    IsProduction:
      !Equals [${sls:stage}, prod]
    IsNotDev:
      !Not [!Equals [${sls:stage}, dev]]

  # CloudFormation extensions (override generated resources)
  extensions:
    # Override API Gateway settings
    MyFunctionLambdaFunction:
      Properties:
        ReservedConcurrentExecutions: 10
    # Override log group retention
    MyFunctionLogGroup:
      Properties:
        RetentionInDays: 30
    # DependsOn injection
    MyOtherFunctionLambdaFunction:
      DependsOn:
        - CustomResource
```

### Common resource overrides via extensions

```yaml
resources:
  extensions:
    # Set CORS on REST API
    ApiGatewayRestApi:
      Properties:
        Description: My REST API

    # Modify generated IAM role
    IamRoleLambdaExecution:
      Properties:
        RoleName: ${self:service}-${sls:stage}-role

    # Override function configuration
    CreateUserLambdaFunction:
      DependsOn:
        - MyCustomResource
```

---

## Plugins

### Installation and configuration

```yaml
plugins:
  - serverless-offline
  - serverless-domain-manager
  - ./local-plugins/my-plugin           # Local plugin path
```

### Popular plugins reference

| Plugin                                    | Purpose                                  |
| ----------------------------------------- | ---------------------------------------- |
| `serverless-offline`                      | Local API Gateway + Lambda emulation     |
| `serverless-domain-manager`               | Custom domain management                 |
| `serverless-step-functions`               | AWS Step Functions definitions           |
| `serverless-plugin-canary-deployments`    | Canary/linear deploy via CodeDeploy      |
| `serverless-iam-roles-per-function`       | Per-function IAM roles                   |
| `serverless-plugin-split-stacks`          | Nested stacks for 500 resource limit     |
| `serverless-prune-plugin`                 | Auto-prune old Lambda versions           |
| `serverless-plugin-warmup`                | Lambda warming scheduler                 |
| `serverless-provisioned-concurrency-autoscaling` | Auto-scale provisioned concurrency |
| `serverless-plugin-log-retention`         | Manage CloudWatch log retention          |
| `serverless-api-gateway-caching`          | API Gateway response caching             |
| `serverless-plugin-common-excludes`       | Smart default package excludes           |
| `serverless-plugin-typescript`            | TypeScript compilation                   |
| `serverless-dotenv-plugin`                | Enhanced .env file loading               |

---

## Plugin API

### Plugin structure (v4)

```javascript
// my-plugin/index.js
class MyPlugin {
  constructor(serverless, options, { log, progress, writeText }) {
    this.serverless = serverless;
    this.options = options;
    this.log = log;

    this.hooks = {
      'before:deploy:deploy': this.beforeDeploy.bind(this),
      'after:deploy:deploy': this.afterDeploy.bind(this),
      'before:package:finalize': this.modifyTemplate.bind(this),
    };

    this.commands = {
      mycommand: {
        usage: 'Description of my command',
        lifecycleEvents: ['init', 'run'],
        options: {
          target: {
            usage: 'Target environment',
            shortcut: 't',
            required: true,
            type: 'string',
          },
        },
      },
    };
  }

  async beforeDeploy() {
    this.log.notice('Running pre-deploy checks...');
    const stage = this.serverless.service.provider.stage;
    const functions = this.serverless.service.functions;
  }

  async afterDeploy() {
    this.log.success('Deployment complete!');
  }

  async modifyTemplate() {
    const template = this.serverless.service.provider.compiledCloudFormationTemplate;
    // Modify template.Resources, template.Outputs, etc.
  }
}

module.exports = MyPlugin;
```

### Key lifecycle hooks

```
before:package:cleanup
before:package:initialize
package:initialize
before:package:setupProviderConfiguration
after:package:setupProviderConfiguration
before:package:createDeploymentArtifacts
after:package:createDeploymentArtifacts
before:package:compileFunctions
package:compileFunctions
after:package:compileFunctions
before:package:finalize
package:finalize

before:deploy:deploy
deploy:deploy
after:deploy:deploy
after:deploy:finalize

before:remove:remove
remove:remove
after:remove:remove

before:invoke:invoke
invoke:invoke
```

---

## Build Configuration

### Built-in esbuild (v4)

```yaml
build:
  esbuild:
    bundle: true                         # Bundle dependencies
    minify: true                         # Minify output
    sourcemap:
      type: linked                       # 'inline' | 'linked' | 'external'
      setNodeOptions: true               # Add --enable-source-maps
    target: node20                       # esbuild target
    platform: node                       # 'node' | 'browser'
    format: cjs                          # 'cjs' | 'esm'
    mainFields: [module, main]           # Package.json field resolution
    external:                            # Don't bundle these
      - '@aws-sdk/*'
      - sharp
    define:                              # Compile-time constants
      'process.env.VERSION': '"1.0.0"'
    banner:
      js: '/* Built with Serverless */'
    loader:                              # File type loaders
      '.png': 'dataurl'
      '.json': 'json'
    buildConcurrency: 3                  # Parallel function builds
    plugins: ./esbuild-plugins.js        # Custom esbuild plugins file
```

### Disable built-in esbuild (use plugin instead)

```yaml
build:
  esbuild: false
plugins:
  - serverless-webpack                   # or serverless-esbuild
```

---

## CLI Commands

### Deployment

```bash
serverless deploy                        # Full stack deploy
serverless deploy --stage prod           # Deploy to stage
serverless deploy --region eu-west-1     # Deploy to region
serverless deploy --verbose              # Show CloudFormation events
serverless deploy --force                # Force deploy even with no changes
serverless deploy --aws-profile prod     # Use specific AWS profile
serverless deploy function -f myFn       # Deploy single function (fast)
```

### Development

```bash
serverless dev                           # Live dev mode (v4)
serverless dev -f myFunction             # Dev mode for specific function
serverless offline                       # Local emulation (plugin)
serverless invoke local -f myFn          # Local invocation
serverless invoke local -f myFn -p event.json
serverless invoke local -f myFn -d '{"key":"val"}'
```

### Operations

```bash
serverless invoke -f myFn               # Remote invocation
serverless invoke -f myFn --log          # With CloudWatch logs
serverless logs -f myFn                  # View logs
serverless logs -f myFn --tail           # Stream logs
serverless logs -f myFn --startTime 1h   # Last hour
serverless logs -f myFn --filter ERROR   # Filter by pattern
serverless info                          # Stack info
serverless info --stage prod             # Stage-specific info
serverless metrics -f myFn              # Function metrics
```

### Management

```bash
serverless remove                        # Remove entire stack
serverless remove --stage dev            # Remove specific stage
serverless package                       # Package without deploying
serverless print                         # Print resolved config
serverless print --path provider         # Print specific section
serverless rollback --timestamp <ts>     # Rollback to timestamp
```

### Compose commands

```bash
serverless deploy                        # Deploy all services
serverless deploy --service=api          # Deploy single service
serverless remove                        # Remove all
serverless logs --service=api -f myFn    # Logs for specific service
serverless info --service=api
serverless refresh-outputs               # Refresh cross-service outputs
```

### Dashboard & Auth

```bash
serverless login                         # Authenticate with Dashboard
serverless logout
serverless --org myOrg --app myApp       # Set org/app
```
