# Serverless Framework v4 — Advanced Patterns

## Table of Contents

- [Multi-Service Architectures](#multi-service-architectures)
- [Serverless Compose (Monorepo)](#serverless-compose-monorepo)
- [Output Sharing Between Services](#output-sharing-between-services)
- [Composable serverless.yml](#composable-serverlessyml)
- [Shared Resources Pattern](#shared-resources-pattern)
- [Step Functions Integration](#step-functions-integration)
- [Custom Authorizers](#custom-authorizers)
- [Warming Strategies](#warming-strategies)
- [Provisioned Concurrency](#provisioned-concurrency)
- [Canary Deployments](#canary-deployments)
- [Cross-Account Deployment](#cross-account-deployment)
- [Multi-Region Deployment](#multi-region-deployment)
- [Monorepo Patterns](#monorepo-patterns)
- [Event-Driven Patterns](#event-driven-patterns)

---

## Multi-Service Architectures

Split large applications into independent services aligned with domain boundaries. Each service has its own `serverless.yml`, CloudFormation stack, and deployment lifecycle.

### Recommended project layout

```
project/
├── serverless-compose.yml          # Orchestrates all services
├── services/
│   ├── api/
│   │   ├── serverless.yml
│   │   └── src/
│   ├── auth/
│   │   ├── serverless.yml
│   │   └── src/
│   ├── events/
│   │   ├── serverless.yml
│   │   └── src/
│   └── shared-infra/
│       └── serverless.yml          # DynamoDB, SQS, SNS, etc.
└── packages/
    └── shared/                     # Shared TypeScript types, utils
        ├── package.json
        └── src/
```

### Why split services?

| Reason                          | Details                                                  |
| ------------------------------- | -------------------------------------------------------- |
| CloudFormation 500 resource cap | Each stack stays under the limit                         |
| Independent deploy cycles       | Change auth without redeploying API                      |
| Team ownership                  | Each team owns a service                                 |
| Blast radius reduction          | Failed deploy affects one service only                   |
| Faster deployments              | Smaller stacks deploy faster                             |

---

## Serverless Compose (Monorepo)

Serverless Compose orchestrates multiple services from a single root. Deploy all services together or individually.

### serverless-compose.yml

```yaml
services:
  shared-infra:
    path: services/shared-infra

  auth:
    path: services/auth
    params:
      userTableArn: ${shared-infra.UserTableArn}

  api:
    path: services/api
    params:
      userTableArn: ${shared-infra.UserTableArn}
      authFunctionArn: ${auth.AuthorizerFunctionArn}
    dependsOn:
      - shared-infra
      - auth

  events:
    path: services/events
    params:
      orderQueueUrl: ${shared-infra.OrderQueueUrl}
    dependsOn:
      - shared-infra
```

### Compose CLI commands

```bash
serverless deploy                     # Deploy all services (respects dependencies)
serverless deploy --service=api       # Deploy single service
serverless remove                     # Remove all services
serverless logs --service=api -f getUser
serverless info --service=api
serverless refresh-outputs            # Refresh cached outputs from deployed stacks
```

### Key behaviors

- Services deploy in **parallel** unless `dependsOn` or output references create ordering.
- Output references (`${service-name.OutputKey}`) automatically create implicit dependencies.
- Each service gets its own CloudFormation stack — no shared state pollution.
- `serverless refresh-outputs` re-fetches stack outputs without redeploying.

---

## Output Sharing Between Services

### Producer service (shared-infra/serverless.yml)

```yaml
service: shared-infra
frameworkVersion: '4'
provider:
  name: aws
  runtime: nodejs20.x
  stage: ${opt:stage, 'dev'}

resources:
  Resources:
    UserTable:
      Type: AWS::DynamoDB::Table
      Properties:
        TableName: ${self:service}-${sls:stage}-users
        BillingMode: PAY_PER_REQUEST
        AttributeDefinitions:
          - { AttributeName: pk, AttributeType: S }
        KeySchema:
          - { AttributeName: pk, KeyType: HASH }

    OrderQueue:
      Type: AWS::SQS::Queue
      Properties:
        QueueName: ${self:service}-${sls:stage}-orders

  Outputs:
    UserTableArn:
      Value: !GetAtt UserTable.Arn
    UserTableName:
      Value: !Ref UserTable
    OrderQueueUrl:
      Value: !Ref OrderQueue
    OrderQueueArn:
      Value: !GetAtt OrderQueue.Arn
```

### Consumer service (api/serverless.yml)

```yaml
service: order-api
frameworkVersion: '4'
provider:
  name: aws
  runtime: nodejs20.x
  stage: ${opt:stage, 'dev'}
  environment:
    USER_TABLE: ${param:userTableName}
  iam:
    role:
      statements:
        - Effect: Allow
          Action: [dynamodb:GetItem, dynamodb:PutItem, dynamodb:Query]
          Resource: ${param:userTableArn}
```

### Alternative: CloudFormation cross-stack references

When not using Compose, use `Fn::ImportValue`:

```yaml
# Producer: Export in resources.Outputs
Outputs:
  UserTableArn:
    Value: !GetAtt UserTable.Arn
    Export:
      Name: ${sls:stage}-UserTableArn

# Consumer: Import in another stack
provider:
  environment:
    TABLE_ARN: !ImportValue ${sls:stage}-UserTableArn
```

### Alternative: SSM parameter sharing

```yaml
# Producer: Write to SSM
resources:
  Resources:
    UserTableParam:
      Type: AWS::SSM::Parameter
      Properties:
        Name: /${sls:stage}/shared/user-table-arn
        Type: String
        Value: !GetAtt UserTable.Arn

# Consumer: Read from SSM
provider:
  environment:
    TABLE_ARN: ${ssm:/${sls:stage}/shared/user-table-arn}
```

---

## Composable serverless.yml

### File-based composition

Split large configs into multiple files:

```yaml
# serverless.yml
service: my-api
frameworkVersion: '4'
provider: ${file(./config/provider.yml)}
functions: ${file(./config/functions.yml)}
resources: ${file(./config/resources.yml)}
plugins: ${file(./config/plugins.yml)}
custom: ${file(./config/custom.yml)}
stages: ${file(./config/stages.yml)}
```

### Dynamic function loading

```yaml
# config/functions.yml — merge multiple function files
${file(./src/users/functions.yml)}
${file(./src/orders/functions.yml)}
${file(./src/notifications/functions.yml)}
```

Each function module file:

```yaml
# src/users/functions.yml
createUser:
  handler: src/users/handlers.create
  events:
    - httpApi: { path: /users, method: POST }
getUser:
  handler: src/users/handlers.get
  events:
    - httpApi: { path: /users/{id}, method: GET }
```

### Stage-conditional resources

```yaml
resources:
  - ${file(./resources/dynamodb.yml)}
  - ${file(./resources/sqs.yml)}
  # Only include WAF in prod
  - ${self:custom.stages.${sls:stage}.extraResources, ''}

custom:
  stages:
    prod:
      extraResources: ${file(./resources/waf.yml)}
    dev:
      extraResources: ''
```

---

## Shared Resources Pattern

Dedicated infrastructure service pattern for resources shared across multiple services:

```yaml
# services/shared-infra/serverless.yml
service: shared-infra
frameworkVersion: '4'
provider:
  name: aws
  stage: ${opt:stage, 'dev'}
  # No functions — this service is infrastructure only

resources:
  Resources:
    # VPC
    VPC:
      Type: AWS::EC2::VPC
      Properties:
        CidrBlock: 10.0.0.0/16
        EnableDnsHostnames: true

    # DynamoDB tables
    UsersTable:
      Type: AWS::DynamoDB::Table
      DeletionPolicy: Retain
      Properties:
        TableName: ${sls:stage}-users
        BillingMode: PAY_PER_REQUEST
        AttributeDefinitions:
          - { AttributeName: pk, AttributeType: S }
          - { AttributeName: sk, AttributeType: S }
          - { AttributeName: GSI1PK, AttributeType: S }
          - { AttributeName: GSI1SK, AttributeType: S }
        KeySchema:
          - { AttributeName: pk, KeyType: HASH }
          - { AttributeName: sk, KeyType: RANGE }
        GlobalSecondaryIndexes:
          - IndexName: GSI1
            KeySchema:
              - { AttributeName: GSI1PK, KeyType: HASH }
              - { AttributeName: GSI1SK, KeyType: RANGE }
            Projection: { ProjectionType: ALL }
        StreamSpecification:
          StreamViewType: NEW_AND_OLD_IMAGES
        PointInTimeRecoverySpecification:
          PointInTimeRecoveryEnabled: true

    # SQS queues
    EventBus:
      Type: AWS::SQS::Queue
      Properties:
        QueueName: ${sls:stage}-events
        VisibilityTimeout: 300
        RedrivePolicy:
          deadLetterTargetArn: !GetAtt EventDLQ.Arn
          maxReceiveCount: 3
    EventDLQ:
      Type: AWS::SQS::Queue
      Properties:
        QueueName: ${sls:stage}-events-dlq
        MessageRetentionPeriod: 1209600  # 14 days

  Outputs:
    UsersTableArn:
      Value: !GetAtt UsersTable.Arn
    UsersTableName:
      Value: !Ref UsersTable
    UsersTableStreamArn:
      Value: !GetAtt UsersTable.StreamArn
    EventBusUrl:
      Value: !Ref EventBus
    EventBusArn:
      Value: !GetAtt EventBus.Arn
    VpcId:
      Value: !Ref VPC
```

**Key rules:**
- Use `DeletionPolicy: Retain` on stateful resources (DynamoDB, S3, RDS).
- Export every ARN/URL/Name that other services need.
- Keep this stack small — it rarely changes.

---

## Step Functions Integration

### Plugin setup

```bash
npm i -D serverless-step-functions
```

```yaml
plugins:
  - serverless-step-functions

stepFunctions:
  stateMachines:
    orderProcessing:
      name: ${self:service}-${sls:stage}-order-processing
      role: !GetAtt StepFunctionRole.Arn
      tracingConfig:
        enabled: true
      definition:
        Comment: Process new orders
        StartAt: ValidateOrder
        States:
          ValidateOrder:
            Type: Task
            Resource: !GetAtt ValidateOrderLambdaFunction.Arn
            Next: CheckInventory
            Retry:
              - ErrorEquals: [States.TaskFailed]
                IntervalSeconds: 2
                MaxAttempts: 3
                BackoffRate: 2
            Catch:
              - ErrorEquals: [States.ALL]
                Next: HandleError

          CheckInventory:
            Type: Task
            Resource: !GetAtt CheckInventoryLambdaFunction.Arn
            Next: InventoryDecision

          InventoryDecision:
            Type: Choice
            Choices:
              - Variable: $.inStock
                BooleanEquals: true
                Next: ProcessPayment
            Default: BackorderItem

          ProcessPayment:
            Type: Task
            Resource: !GetAtt ProcessPaymentLambdaFunction.Arn
            Next: FulfillOrder

          FulfillOrder:
            Type: Task
            Resource: !GetAtt FulfillOrderLambdaFunction.Arn
            End: true

          BackorderItem:
            Type: Task
            Resource: !GetAtt BackorderItemLambdaFunction.Arn
            End: true

          HandleError:
            Type: Task
            Resource: !GetAtt HandleErrorLambdaFunction.Arn
            End: true

      alarms:
        topics:
          ok: !Ref AlarmSNSTopic
          alarm: !Ref AlarmSNSTopic
        metrics:
          - executionsFailed
          - executionsTimedOut
        treatMissingData: notBreaching

functions:
  validateOrder:
    handler: src/steps/validate.handler
  checkInventory:
    handler: src/steps/inventory.handler
  processPayment:
    handler: src/steps/payment.handler
  fulfillOrder:
    handler: src/steps/fulfill.handler
  backorderItem:
    handler: src/steps/backorder.handler
  handleError:
    handler: src/steps/error.handler
```

### Trigger step function from Lambda

```typescript
import { SFNClient, StartExecutionCommand } from '@aws-sdk/client-sfn';

const sfn = new SFNClient({});

export const handler = async (event: APIGatewayProxyEvent) => {
  const body = JSON.parse(event.body ?? '{}');
  await sfn.send(new StartExecutionCommand({
    stateMachineArn: process.env.STATE_MACHINE_ARN,
    name: `order-${body.orderId}-${Date.now()}`,
    input: JSON.stringify(body),
  }));
  return { statusCode: 202, body: JSON.stringify({ status: 'processing' }) };
};
```

### Express vs Standard workflows

| Feature         | Standard                  | Express                        |
| --------------- | ------------------------- | ------------------------------ |
| Duration        | Up to 1 year              | Up to 5 minutes                |
| Pricing         | Per state transition      | Per execution + duration       |
| Execution model | Exactly-once              | At-least-once                  |
| Best for        | Long-running orchestration| High-volume, short processing  |

```yaml
stepFunctions:
  stateMachines:
    expressWorkflow:
      type: EXPRESS
      loggingConfig:
        level: ALL
        includeExecutionData: true
        destinations:
          - !GetAtt StepFunctionLogGroup.Arn
```

---

## Custom Authorizers

### Lambda authorizer (REST API v1)

```yaml
functions:
  authorizer:
    handler: src/auth/authorizer.handler

  protectedEndpoint:
    handler: src/handlers/protected.handler
    events:
      - http:
          path: /protected
          method: GET
          authorizer:
            name: authorizer
            type: request
            identitySource: method.request.header.Authorization
            resultTtlInSeconds: 300    # Cache auth result
```

Authorizer handler returns IAM policy:

```typescript
export const handler = async (event: APIGatewayRequestAuthorizerEvent) => {
  const token = event.headers?.Authorization?.replace('Bearer ', '');
  try {
    const decoded = verifyJwt(token);
    return {
      principalId: decoded.sub,
      policyDocument: {
        Version: '2012-10-17',
        Statement: [{
          Action: 'execute-api:Invoke',
          Effect: 'Allow',
          Resource: event.methodArn,
        }],
      },
      context: { userId: decoded.sub, role: decoded.role },
    };
  } catch {
    throw new Error('Unauthorized');
  }
};
```

### Cognito authorizer (REST API v1)

```yaml
functions:
  protectedEndpoint:
    handler: src/handlers/protected.handler
    events:
      - http:
          path: /protected
          method: GET
          authorizer:
            type: COGNITO_USER_POOLS
            arn: !GetAtt UserPool.Arn
            scopes:
              - email
              - openid

resources:
  Resources:
    UserPool:
      Type: AWS::Cognito::UserPool
      Properties:
        UserPoolName: ${self:service}-${sls:stage}
        AutoVerifiedAttributes: [email]
        UsernameAttributes: [email]
        Policies:
          PasswordPolicy:
            MinimumLength: 12
            RequireUppercase: true
            RequireLowercase: true
            RequireNumbers: true
    UserPoolClient:
      Type: AWS::Cognito::UserPoolClient
      Properties:
        UserPoolId: !Ref UserPool
        ExplicitAuthFlows: [ALLOW_USER_SRP_AUTH, ALLOW_REFRESH_TOKEN_AUTH]
        GenerateSecret: false
```

### JWT authorizer (HTTP API v2)

```yaml
provider:
  httpApi:
    authorizers:
      jwtAuthorizer:
        type: jwt
        identitySource: $request.header.Authorization
        issuerUrl: !Sub https://cognito-idp.${aws:region}.amazonaws.com/${UserPool}
        audience:
          - !Ref UserPoolClient

functions:
  protectedEndpoint:
    handler: src/handlers/protected.handler
    events:
      - httpApi:
          path: /protected
          method: GET
          authorizer:
            name: jwtAuthorizer
```

### API Key authentication (REST API v1)

```yaml
provider:
  apiGateway:
    apiKeys:
      - free:
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

functions:
  publicEndpoint:
    handler: src/handlers/public.handler
    events:
      - http: { path: /public, method: GET }

  apiKeyEndpoint:
    handler: src/handlers/metered.handler
    events:
      - http:
          path: /metered
          method: GET
          private: true          # Requires x-api-key header
```

---

## Warming Strategies

### Provisioned concurrency (recommended — eliminates cold starts)

```yaml
functions:
  criticalApi:
    handler: src/handlers/critical.handler
    provisionedConcurrency: 5
    events:
      - httpApi: { path: /critical, method: GET }
```

### Provisioned concurrency with auto-scaling

```yaml
plugins:
  - serverless-provisioned-concurrency-autoscaling

functions:
  criticalApi:
    handler: src/handlers/critical.handler
    provisionedConcurrency: 2               # Minimum
    concurrencyAutoscaling:
      enabled: true
      maximum: 20                            # Maximum
      usage: 0.7                             # Scale at 70% utilization
      scaleInCooldown: 300
      scaleOutCooldown: 0
```

### Schedule-based warming (alternative to provisioned concurrency)

```yaml
functions:
  warmer:
    handler: src/utils/warmer.handler
    events:
      - schedule:
          rate: rate(5 minutes)
          enabled: true
          input:
            warmer: true
            concurrency: 3

  myFunction:
    handler: src/handlers/my.handler
    events:
      - httpApi: { path: /api, method: GET }
```

```typescript
// src/utils/warmer.ts
export const handler = async (event: any) => {
  if (event.warmer) {
    // Invoke target functions concurrently
    const lambda = new LambdaClient({});
    const promises = Array(event.concurrency).fill(null).map((_, i) =>
      lambda.send(new InvokeCommand({
        FunctionName: process.env.TARGET_FUNCTION,
        InvocationType: 'Event',
        Payload: JSON.stringify({ __warmup: true }),
      }))
    );
    await Promise.all(promises);
    return { warmed: event.concurrency };
  }
};
```

### Cold start reduction checklist

1. Use `arm64` architecture (~34% faster cold starts).
2. Use esbuild bundling with `minify: true` — smaller packages = faster init.
3. Externalize `@aws-sdk/*` (included in runtime).
4. Lazy-load heavy dependencies inside handler, not at module scope.
5. Avoid VPC unless required (VPC adds ~6-10s cold start without Hyperplane, ~1s with).
6. Use `package.individually: true` to minimize per-function bundle size.
7. Prefer Node.js/Python runtimes (fastest cold starts).

---

## Provisioned Concurrency

### Basic configuration

```yaml
functions:
  apiHandler:
    handler: src/handler.main
    provisionedConcurrency: 5    # Always-warm instances
    reservedConcurrency: 50      # Max concurrent executions
```

### With aliases (for canary/step functions)

When using provisioned concurrency, Lambda creates an alias (`provisioned`) automatically. Reference the alias ARN in Step Functions or other integrations:

```yaml
# In stepFunctions definition, reference the alias:
Resource: !Ref ApiHandlerProvConcLambdaAlias
# NOT: !GetAtt ApiHandlerLambdaFunction.Arn
```

### Cost considerations

- Provisioned concurrency charges **per GB-hour** even when idle.
- Use auto-scaling to reduce cost during low-traffic periods.
- Only provision for latency-critical paths (checkout, auth, health checks).
- Monitor `ProvisionedConcurrencyUtilization` CloudWatch metric.

---

## Canary Deployments

### Plugin setup

```bash
npm i -D serverless-plugin-canary-deployments
```

```yaml
plugins:
  - serverless-plugin-canary-deployments

functions:
  myFunction:
    handler: src/handler.main
    events:
      - httpApi: { path: /api, method: GET }
    deploymentSettings:
      type: Canary10Percent5Minutes    # Shift 10% traffic, wait 5 min
      alias: Live
      preTrafficHook: preDeployValidation
      postTrafficHook: postDeployValidation
      alarms:
        - MyFunctionErrorAlarm

  preDeployValidation:
    handler: src/hooks/preValidate.handler

  postDeployValidation:
    handler: src/hooks/postValidate.handler

resources:
  Resources:
    MyFunctionErrorAlarm:
      Type: AWS::CloudWatch::Alarm
      Properties:
        AlarmName: ${self:service}-${sls:stage}-errors
        Namespace: AWS/Lambda
        MetricName: Errors
        Dimensions:
          - Name: FunctionName
            Value: !Ref MyFunctionLambdaFunction
        Statistic: Sum
        Period: 60
        EvaluationPeriods: 1
        Threshold: 1
        ComparisonOperator: GreaterThanOrEqualToThreshold
```

### Available deployment strategies

| Strategy                       | Behavior                                      |
| ------------------------------ | --------------------------------------------- |
| `Canary10Percent5Minutes`      | 10% for 5 min, then 100%                      |
| `Canary10Percent10Minutes`     | 10% for 10 min, then 100%                     |
| `Canary10Percent15Minutes`     | 10% for 15 min, then 100%                     |
| `Canary10Percent30Minutes`     | 10% for 30 min, then 100%                     |
| `Linear10PercentEvery1Minute`  | 10% increment every 1 min                     |
| `Linear10PercentEvery2Minutes` | 10% increment every 2 min                     |
| `Linear10PercentEvery3Minutes` | 10% increment every 3 min                     |
| `Linear10PercentEvery10Minutes`| 10% increment every 10 min                    |
| `AllAtOnce`                    | Immediate full cutover                         |

---

## Cross-Account Deployment

### Profile-based (simple)

```yaml
provider:
  name: aws
  profile: ${param:awsProfile}

stages:
  dev:
    params:
      awsProfile: dev-account
  staging:
    params:
      awsProfile: staging-account
  prod:
    params:
      awsProfile: prod-account
```

### Role assumption (recommended for CI/CD)

```yaml
provider:
  name: aws
  iam:
    deploymentRole: arn:aws:iam::${param:targetAccountId}:role/ServerlessDeployRole

stages:
  dev:
    params:
      targetAccountId: '111111111111'
  prod:
    params:
      targetAccountId: '222222222222'
```

### CI/CD cross-account (OIDC — no long-lived credentials)

```yaml
# GitHub Actions
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::${{ vars.TARGET_ACCOUNT_ID }}:role/GitHubDeployRole
    aws-region: us-east-1

- run: npx serverless deploy --stage ${{ github.ref_name == 'main' && 'prod' || 'dev' }}
```

---

## Multi-Region Deployment

### Parallel deploy script

```bash
#!/bin/bash
REGIONS=("us-east-1" "eu-west-1" "ap-southeast-1")
STAGE="${1:-dev}"

for region in "${REGIONS[@]}"; do
  echo "Deploying to $region..."
  serverless deploy --stage "$STAGE" --region "$region" &
done
wait
echo "All regions deployed"
```

### Region-aware configuration

```yaml
provider:
  environment:
    REGION: ${aws:region}
    TABLE_NAME: ${self:service}-${sls:stage}-${aws:region}
    CERT_ARN: ${ssm:/${sls:stage}/${aws:region}/cert-arn}
```

### Global table replication

```yaml
resources:
  Resources:
    GlobalTable:
      Type: AWS::DynamoDB::GlobalTable
      Properties:
        TableName: ${self:service}-${sls:stage}
        BillingMode: PAY_PER_REQUEST
        AttributeDefinitions:
          - { AttributeName: pk, AttributeType: S }
        KeySchema:
          - { AttributeName: pk, KeyType: HASH }
        StreamSpecification:
          StreamViewType: NEW_AND_OLD_IMAGES
        Replicas:
          - Region: us-east-1
          - Region: eu-west-1
          - Region: ap-southeast-1
```

---

## Monorepo Patterns

### Turborepo / pnpm workspace integration

```
monorepo/
├── package.json                     # Root workspace config
├── pnpm-workspace.yaml
├── turbo.json
├── serverless-compose.yml
├── packages/
│   ├── shared-types/               # @org/shared-types
│   ├── db-client/                  # @org/db-client
│   └── utils/                      # @org/utils
└── services/
    ├── api/
    │   ├── package.json            # depends on @org/shared-types, @org/db-client
    │   └── serverless.yml
    └── worker/
        ├── package.json
        └── serverless.yml
```

### esbuild handles workspace deps automatically

```yaml
# services/api/serverless.yml
build:
  esbuild:
    bundle: true
    minify: true
    external: ['@aws-sdk/*']
    # esbuild resolves workspace packages (../../packages/shared-types)
    # automatically when bundling — no special config needed
```

### turbo.json pipeline

```json
{
  "pipeline": {
    "deploy": {
      "dependsOn": ["^build"],
      "env": ["AWS_REGION", "STAGE"]
    },
    "deploy:dev": {
      "dependsOn": ["^build"],
      "cache": false
    },
    "test": {
      "dependsOn": ["^build"]
    }
  }
}
```

---

## Event-Driven Patterns

### Fan-out with SNS → SQS

```yaml
functions:
  publisher:
    handler: src/publisher.handler
    events:
      - httpApi: { path: /orders, method: POST }
    environment:
      TOPIC_ARN: !Ref OrderTopic

  emailHandler:
    handler: src/email.handler
    events:
      - sqs:
          arn: !GetAtt EmailQueue.Arn
          batchSize: 10
          functionResponseType: ReportBatchItemFailures

  analyticsHandler:
    handler: src/analytics.handler
    events:
      - sqs:
          arn: !GetAtt AnalyticsQueue.Arn
          batchSize: 50
          maximumBatchingWindow: 30

resources:
  Resources:
    OrderTopic:
      Type: AWS::SNS::Topic
      Properties:
        TopicName: ${self:service}-${sls:stage}-orders

    EmailQueue:
      Type: AWS::SQS::Queue
    EmailSubscription:
      Type: AWS::SNS::Subscription
      Properties:
        TopicArn: !Ref OrderTopic
        Protocol: sqs
        Endpoint: !GetAtt EmailQueue.Arn
        FilterPolicy: { type: ['order_placed', 'order_shipped'] }

    AnalyticsQueue:
      Type: AWS::SQS::Queue
    AnalyticsSubscription:
      Type: AWS::SNS::Subscription
      Properties:
        TopicArn: !Ref OrderTopic
        Protocol: sqs
        Endpoint: !GetAtt AnalyticsQueue.Arn

    # Allow SNS to send to SQS
    EmailQueuePolicy:
      Type: AWS::SQS::QueuePolicy
      Properties:
        Queues: [!Ref EmailQueue]
        PolicyDocument:
          Statement:
            - Effect: Allow
              Principal: { Service: sns.amazonaws.com }
              Action: sqs:SendMessage
              Resource: !GetAtt EmailQueue.Arn
              Condition:
                ArnEquals:
                  aws:SourceArn: !Ref OrderTopic
```

### EventBridge custom bus pattern

```yaml
functions:
  orderCreated:
    handler: src/handlers/orderCreated.handler
    events:
      - eventBridge:
          eventBus: !Ref CustomEventBus
          pattern:
            source: [com.myapp.orders]
            detail-type: [OrderCreated]

  orderCancelled:
    handler: src/handlers/orderCancelled.handler
    events:
      - eventBridge:
          eventBus: !Ref CustomEventBus
          pattern:
            source: [com.myapp.orders]
            detail-type: [OrderCancelled]

resources:
  Resources:
    CustomEventBus:
      Type: AWS::Events::EventBus
      Properties:
        Name: ${self:service}-${sls:stage}
```

### DynamoDB Streams → Lambda with filtering

```yaml
functions:
  onUserChange:
    handler: src/streams/userChange.handler
    events:
      - stream:
          type: dynamodb
          arn: !GetAtt UsersTable.StreamArn
          batchSize: 25
          startingPosition: LATEST
          maximumRetryAttempts: 3
          bisectBatchOnFunctionError: true
          functionResponseType: ReportBatchItemFailures
          filterPatterns:
            - eventName: [INSERT, MODIFY]
              dynamodb:
                NewImage:
                  status: { S: [verified] }
```
