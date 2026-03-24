# AWS Lambda Deployment Patterns

Complete guide covering SAM, CDK, Serverless Framework, Terraform, CI/CD,
blue-green, canary, multi-environment, and infrastructure testing.

## Table of Contents

- [SAM Templates](#sam-templates)
- [CDK Constructs (TypeScript)](#cdk-constructs-typescript)
- [Serverless Framework Configs](#serverless-framework-configs)
- [Terraform Modules](#terraform-modules)
- [CI/CD Pipelines (GitHub Actions)](#cicd-pipelines-github-actions)
- [Blue-Green Deployments](#blue-green-deployments)
- [Canary Deployments](#canary-deployments)
- [Multi-Environment Setup](#multi-environment-setup)
- [Infrastructure Testing](#infrastructure-testing)

---

## SAM Templates

### Full Template with Globals, Parameters, Cognito, Layers, and DynamoDB

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Parameters:
  Environment:
    Type: String
    Default: dev
    AllowedValues: [dev, staging, prod]
  LogLevel:
    Type: String
    Default: INFO
Globals:
  Function:
    Runtime: python3.12
    Timeout: 30
    MemorySize: 256
    Tracing: Active
    Environment:
      Variables: { ENVIRONMENT: !Ref Environment, LOG_LEVEL: !Ref LogLevel, TABLE_NAME: !Ref OrdersTable }
    Layers: [!Ref SharedDepsLayer]
    Tags: { Project: order-api }
  Api:
    TracingEnabled: true
    Cors: { AllowMethods: "'GET,POST,PUT,DELETE,OPTIONS'", AllowHeaders: "'Content-Type,Authorization'", AllowOrigin: "'*'" }
Resources:
  OrderApi:
    Type: AWS::Serverless::HttpApi
    Properties:
      StageName: !Ref Environment
      Auth:
        DefaultAuthorizer: CognitoAuth
        Authorizers:
          CognitoAuth:
            AuthorizationScopes: [email, openid]
            IdentitySource: $request.header.Authorization
            JwtConfiguration:
              issuer: !Sub 'https://cognito-idp.${AWS::Region}.amazonaws.com/${CognitoPoolId}'
              audience: [!Sub '{{resolve:ssm:/${Environment}/cognito/client-id}}']
  CognitoPoolId:
    Type: AWS::SSM::Parameter::Value<String>
    Default: !Sub '/${Environment}/cognito/user-pool-id'
  SharedDepsLayer:
    Type: AWS::Serverless::LayerVersion
    Properties:
      ContentUri: layers/dependencies/
      CompatibleRuntimes: [python3.12]
      RetentionPolicy: Retain
    Metadata: { BuildMethod: python3.12 }
  CreateOrderFunction:
    Type: AWS::Serverless::Function
    Properties:
      Handler: handlers/create_order.handler
      CodeUri: src/
      MemorySize: 512
      Events:
        Api: { Type: HttpApi, Properties: { ApiId: !Ref OrderApi, Path: /orders, Method: POST } }
      Policies:
        - DynamoDBCrudPolicy: { TableName: !Ref OrdersTable }
  GetOrderFunction:
    Type: AWS::Serverless::Function
    Properties:
      Handler: handlers/get_order.handler
      CodeUri: src/
      Events:
        Api: { Type: HttpApi, Properties: { ApiId: !Ref OrderApi, Path: /orders/{orderId}, Method: GET } }
      Policies:
        - DynamoDBReadPolicy: { TableName: !Ref OrdersTable }
  OrdersTable:
    Type: AWS::DynamoDB::Table
    DeletionPolicy: Retain
    Properties:
      TableName: !Sub 'orders-${Environment}'
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - { AttributeName: PK, AttributeType: S }
        - { AttributeName: SK, AttributeType: S }
        - { AttributeName: GSI1PK, AttributeType: S }
      KeySchema: [{ AttributeName: PK, KeyType: HASH }, { AttributeName: SK, KeyType: RANGE }]
      GlobalSecondaryIndexes:
        - IndexName: GSI1
          KeySchema: [{ AttributeName: GSI1PK, KeyType: HASH }, { AttributeName: SK, KeyType: RANGE }]
          Projection: { ProjectionType: ALL }
      PointInTimeRecoverySpecification: { PointInTimeRecoveryEnabled: true }
Outputs:
  ApiEndpoint:
    Value: !Sub 'https://${OrderApi}.execute-api.${AWS::Region}.amazonaws.com/${Environment}'
  TableName: { Value: !Ref OrdersTable }
```

### Nested Applications

```yaml
Resources:
  DatabaseStack:
    Type: AWS::Serverless::Application
    Properties:
      Location: ./stacks/database/template.yaml
      Parameters: { Environment: !Ref Environment }
  ApiStack:
    Type: AWS::Serverless::Application
    DependsOn: DatabaseStack
    Properties:
      Location: ./stacks/api/template.yaml
      Parameters:
        TableName: !GetAtt DatabaseStack.Outputs.TableName
        TableArn: !GetAtt DatabaseStack.Outputs.TableArn
```

---

## CDK Constructs (TypeScript)

### Complete Stack with Custom Construct and Asset Bundling

```typescript
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigw from 'aws-cdk-lib/aws-apigateway';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as logs from 'aws-cdk-lib/aws-logs';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import { PythonFunction } from '@aws-cdk/aws-lambda-python-alpha';

// --- L3 Custom Construct ---
export class ApiLambda extends Construct {
  public readonly fn: lambda.Function;
  constructor(scope: Construct, id: string, props: {
    handler: string; code: string; env: Record<string, string>;
    memory?: number; layers?: lambda.ILayerVersion[];
  }) {
    super(scope, id);
    this.fn = new lambda.Function(this, 'Fn', {
      runtime: lambda.Runtime.PYTHON_3_12, handler: props.handler,
      code: lambda.Code.fromAsset(props.code), memorySize: props.memory ?? 256,
      timeout: cdk.Duration.seconds(30), environment: props.env,
      layers: props.layers, tracing: lambda.Tracing.ACTIVE,
      logRetention: logs.RetentionDays.TWO_WEEKS,
    });
  }
}

// --- Main Stack ---
interface Props extends cdk.StackProps { environment: string; logLevel: string; }

export class OrderApiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: Props) {
    super(scope, id, props);
    const { environment, logLevel } = props;

    const table = new dynamodb.Table(this, 'Table', {
      tableName: `orders-${environment}`,
      partitionKey: { name: 'PK', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'SK', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecovery: true,
      removalPolicy: environment === 'prod' ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });

    const layer = new lambda.LayerVersion(this, 'Deps', {
      code: lambda.Code.fromAsset('layers/dependencies'),
      compatibleRuntimes: [lambda.Runtime.PYTHON_3_12],
    });
    const env = { ENVIRONMENT: environment, LOG_LEVEL: logLevel, TABLE_NAME: table.tableName };

    const createFn = new ApiLambda(this, 'Create', { handler: 'handlers/create_order.handler', code: 'src', env, memory: 512, layers: [layer] });
    const getFn = new ApiLambda(this, 'Get', { handler: 'handlers/get_order.handler', code: 'src', env, layers: [layer] });
    table.grantReadWriteData(createFn.fn);
    table.grantReadData(getFn.fn);

    const pool = new cognito.UserPool(this, 'Pool', { selfSignUpEnabled: true, signInAliases: { email: true } });
    const api = new apigw.RestApi(this, 'Api', {
      restApiName: `order-api-${environment}`,
      deployOptions: { stageName: environment, tracingEnabled: true },
      defaultCorsPreflightOptions: { allowOrigins: apigw.Cors.ALL_ORIGINS, allowMethods: apigw.Cors.ALL_METHODS },
    });
    const auth = new apigw.CognitoUserPoolsAuthorizer(this, 'Auth', { cognitoUserPools: [pool] });
    const opts = { authorizer: auth, authorizationType: apigw.AuthorizationType.COGNITO };
    const orders = api.root.addResource('orders');
    orders.addMethod('POST', new apigw.LambdaIntegration(createFn.fn), opts);
    orders.addMethod('GET', new apigw.LambdaIntegration(getFn.fn), opts);
    orders.addResource('{orderId}').addMethod('GET', new apigw.LambdaIntegration(getFn.fn), opts);

    // Asset bundling: NodejsFunction (esbuild) and PythonFunction
    new NodejsFunction(this, 'TsHandler', { entry: 'functions/process/index.ts',
      runtime: lambda.Runtime.NODEJS_20_X,
      bundling: { minify: true, sourceMap: true, target: 'es2022', externalModules: ['@aws-sdk/*'] } });
    new PythonFunction(this, 'PyHandler', { entry: 'functions/analyze',
      runtime: lambda.Runtime.PYTHON_3_12,
      bundling: { assetExcludes: ['*.pyc', '__pycache__', 'tests'] } });

    new cdk.CfnOutput(this, 'ApiUrl', { value: api.url });
  }
}
```

### Environment Configuration (cdk.json)

```jsonc
{
  "app": "npx ts-node bin/app.ts",
  "context": { "environments": {
    "dev":     { "account": "111111111111", "region": "us-east-1", "logLevel": "DEBUG" },
    "staging": { "account": "222222222222", "region": "us-east-1", "logLevel": "INFO" },
    "prod":    { "account": "333333333333", "region": "us-east-1", "logLevel": "WARN" }
  }}
}
```

```typescript
// bin/app.ts — deploy with: cdk deploy -c targetEnv=staging
const app = new cdk.App();
const targetEnv = app.node.tryGetContext('targetEnv') ?? 'dev';
const cfg = app.node.tryGetContext('environments')[targetEnv];
new OrderApiStack(app, `OrderApi-${targetEnv}`, {
  env: { account: cfg.account, region: cfg.region },
  environment: targetEnv, logLevel: cfg.logLevel,
});
```

---

## Serverless Framework Configs

### Full serverless.yml with Plugins, Custom Resources, Packaging

```yaml
service: order-api
frameworkVersion: '3'
plugins: [serverless-offline, serverless-webpack, serverless-python-requirements]
provider:
  name: aws
  runtime: python3.12
  stage: ${opt:stage, 'dev'}
  region: ${opt:region, 'us-east-1'}
  memorySize: 256
  timeout: 30
  tracing: { lambda: true, apiGateway: true }
  environment:
    ENVIRONMENT: ${self:provider.stage}
    TABLE_NAME: ${self:custom.tableName}
    LOG_LEVEL: ${self:custom.logLevel.${self:provider.stage}, 'INFO'}
  iam:
    role:
      statements:
        - Effect: Allow
          Action: [dynamodb:GetItem, dynamodb:PutItem, dynamodb:Query, dynamodb:Scan]
          Resource: [!GetAtt OrdersTable.Arn, !Sub '${OrdersTable.Arn}/index/*']
custom:
  tableName: orders-${self:provider.stage}
  logLevel: { dev: DEBUG, staging: INFO, prod: WARN }
  webpack: { webpackConfig: ./webpack.config.js, includeModules: true }
  pythonRequirements: { dockerizePip: non-linux, layer: true, slim: true }
  serverless-offline: { httpPort: 3000 }
functions:
  createOrder:
    handler: src/handlers/create_order.handler
    memorySize: 512
    events: [{ http: { path: /orders, method: post, cors: true } }]
  getOrder:
    handler: src/handlers/get_order.handler
    events: [{ http: { path: /orders/{orderId}, method: get, cors: true } }]
resources:
  Resources:
    OrdersTable:
      Type: AWS::DynamoDB::Table
      DeletionPolicy: Retain
      Properties:
        TableName: ${self:custom.tableName}
        BillingMode: PAY_PER_REQUEST
        AttributeDefinitions: [{ AttributeName: PK, AttributeType: S }, { AttributeName: SK, AttributeType: S }]
        KeySchema: [{ AttributeName: PK, KeyType: HASH }, { AttributeName: SK, KeyType: RANGE }]
package:
  individually: true
  patterns: ['!.git/**', '!tests/**', '!coverage/**', '!*.md']
```

---

## Terraform Modules

### Complete Module with Variables, IAM, API Gateway, CloudWatch Alarms

```hcl
# variables.tf
variable "project_name"        { type = string }
variable "environment"         { type = string
  validation { condition = contains(["dev","staging","prod"], var.environment)
               error_message = "Must be dev, staging, or prod." } }
variable "lambda_memory_size"  { type = number; default = 256 }
variable "lambda_timeout"      { type = number; default = 30 }
variable "enable_alarms"       { type = bool;   default = true }
variable "alarm_sns_topic_arn" { type = string;  default = "" }
variable "tags"                { type = map(string); default = {} }

# main.tf
data "aws_caller_identity" "current" {}
data "archive_file" "lambda_zip" {
  type = "zip"; source_dir = "${path.module}/../../src"; output_path = "${path.module}/../../build/lambda.zip"
}
resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-${var.environment}-role"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Action = "sts:AssumeRole", Effect = "Allow",
    Principal = { Service = "lambda.amazonaws.com" } }] })
}
resource "aws_iam_role_policy" "dynamo" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow",
    Action = ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:Query","dynamodb:Scan"],
    Resource = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/*"] }] })
}
resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_lambda_function" "this" {
  function_name    = "${var.project_name}-${var.environment}"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler = "handlers/create_order.handler"; runtime = "python3.12"
  role = aws_iam_role.lambda.arn; memory_size = var.lambda_memory_size; timeout = var.lambda_timeout
  environment { variables = { ENVIRONMENT = var.environment, TABLE_NAME = aws_dynamodb_table.this.name } }
  tracing_config { mode = "Active" }
  lifecycle { create_before_destroy = true }
  tags = var.tags
}
resource "aws_dynamodb_table" "this" {
  name = "${var.project_name}-${var.environment}"; billing_mode = "PAY_PER_REQUEST"
  hash_key = "PK"; range_key = "SK"
  attribute { name = "PK"; type = "S" }; attribute { name = "SK"; type = "S" }
  point_in_time_recovery { enabled = true }
  lifecycle { prevent_destroy = true }; tags = var.tags
}
resource "aws_apigatewayv2_api" "this" {
  name = "${var.project_name}-${var.environment}"; protocol_type = "HTTP"
  cors_configuration {
    allow_headers = ["Content-Type","Authorization"]
    allow_methods = ["GET","POST","PUT","DELETE"]; allow_origins = ["*"]
  }
}
resource "aws_apigatewayv2_stage" "this" { api_id = aws_apigatewayv2_api.this.id; name = var.environment; auto_deploy = true }
resource "aws_apigatewayv2_integration" "lambda" {
  api_id = aws_apigatewayv2_api.this.id; integration_type = "AWS_PROXY"
  integration_uri = aws_lambda_function.this.invoke_arn; payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "post" { api_id = aws_apigatewayv2_api.this.id; route_key = "POST /orders"; target = "integrations/${aws_apigatewayv2_integration.lambda.id}" }
resource "aws_apigatewayv2_route" "get"  { api_id = aws_apigatewayv2_api.this.id; route_key = "GET /orders/{orderId}"; target = "integrations/${aws_apigatewayv2_integration.lambda.id}" }
resource "aws_lambda_permission" "apigw" {
  action = "lambda:InvokeFunction"; function_name = aws_lambda_function.this.function_name
  principal = "apigateway.amazonaws.com"; source_arn = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

# cloudwatch.tf — alarms auto-rollback canary/blue-green deploys
resource "aws_cloudwatch_metric_alarm" "errors" {
  count = var.enable_alarms ? 1 : 0
  alarm_name = "${var.project_name}-${var.environment}-errors"
  comparison_operator = "GreaterThanThreshold"; evaluation_periods = 2
  metric_name = "Errors"; namespace = "AWS/Lambda"; period = 60; statistic = "Sum"; threshold = 5
  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  dimensions = { FunctionName = aws_lambda_function.this.function_name }
}

# outputs.tf
output "function_arn" { value = aws_lambda_function.this.arn }
output "api_endpoint" { value = aws_apigatewayv2_stage.this.invoke_url }
output "table_name"   { value = aws_dynamodb_table.this.name }
```

Root module usage:

```hcl
module "order_api" {
  source = "../../modules/lambda-api"
  project_name = "order-api"; environment = "prod"; lambda_memory_size = 1024
  enable_alarms = true; alarm_sns_topic_arn = aws_sns_topic.alerts.arn
  tags = { Project = "order-api", ManagedBy = "terraform" }
}
```

---

## CI/CD Pipelines (GitHub Actions)

### SAM Deployment Workflow

```yaml
name: SAM Deploy
on: { push: { branches: [main, develop] } }
permissions: { id-token: write, contents: read }
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.12', cache: pip }
      - run: pip install -r requirements-dev.txt cfn-lint
      - run: cfn-lint template.yaml
      - run: pytest tests/unit/ -v --cov=src
  deploy-dev:
    needs: test
    if: github.ref == 'refs/heads/develop'
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/setup-sam@v2
      - uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: '${{ secrets.AWS_ROLE_DEV }}', aws-region: us-east-1 }
      - uses: actions/cache@v4
        with: { path: .aws-sam, key: 'sam-${{ hashFiles(''template.yaml'',''requirements.txt'') }}' }
      - run: sam build --use-container
      - run: sam deploy --config-env dev --no-confirm-changeset --no-fail-on-empty-changeset
      - name: Integration tests
        run: |
          API=$(aws cloudformation describe-stacks --stack-name order-api-dev \
            --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' --output text)
          pytest tests/integration/ --api-url="$API"
  deploy-prod:
    needs: test
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: prod    # approval gate via GitHub environment protection rules
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/setup-sam@v2
      - uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: '${{ secrets.AWS_ROLE_PROD }}', aws-region: us-east-1 }
      - run: sam build --use-container
      - run: sam deploy --config-env prod --no-confirm-changeset --no-fail-on-empty-changeset
```

### CDK Deployment Workflow

Same structure as SAM above — build/test, then environment-gated deploys:

```yaml
name: CDK Deploy
on: { push: { branches: [main, develop] } }
permissions: { id-token: write, contents: read }
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20', cache: npm }
      - run: npm ci && npx cdk synth -c targetEnv=dev --quiet && npm test
      - uses: actions/upload-artifact@v4
        with: { name: cdk-out, path: cdk.out/ }
  deploy-dev:
    needs: build
    if: github.ref == 'refs/heads/develop'
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20', cache: npm }
      - run: npm ci
      - uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: '${{ secrets.AWS_ROLE_DEV }}', aws-region: us-east-1 }
      - run: npx cdk deploy --all -c targetEnv=dev --require-approval never
  deploy-prod:   # environment: prod provides the approval gate
    needs: build
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: prod
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20', cache: npm }
      - run: npm ci
      - uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: '${{ secrets.AWS_ROLE_PROD }}', aws-region: us-east-1 }
      - run: npx cdk deploy --all -c targetEnv=prod --require-approval never
```

---

## Blue-Green Deployments

### AutoPublishAlias with Traffic Shifting and Hooks

```yaml
Resources:
  ProcessOrderFunction:
    Type: AWS::Serverless::Function
    Properties:
      Handler: handlers/process_order.handler
      CodeUri: src/
      Runtime: python3.12
      AutoPublishAlias: live
      DeploymentPreference:
        Type: AllAtOnce
        Alarms: [!Ref ErrorAlarm, !Ref DurationAlarm]
        Hooks: { PreTraffic: !Ref PreTrafficHook, PostTraffic: !Ref PostTrafficHook }
  ErrorAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      MetricName: Errors
      Namespace: AWS/Lambda
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 1
      Threshold: 1
      ComparisonOperator: GreaterThanOrEqualToThreshold
      Dimensions:
        - { Name: FunctionName, Value: !Ref ProcessOrderFunction }
  CodeDeployApp:
    Type: AWS::CodeDeploy::Application
    Properties: { ComputePlatform: Lambda }
  DeploymentGroup:
    Type: AWS::CodeDeploy::DeploymentGroup
    Properties:
      ApplicationName: !Ref CodeDeployApp
      DeploymentConfigName: CodeDeployDefault.LambdaAllAtOnce
      ServiceRoleArn: !GetAtt CodeDeployRole.Arn
      DeploymentStyle: { DeploymentType: BLUE_GREEN, DeploymentOption: WITH_TRAFFIC_CONTROL }
      AutoRollbackConfiguration: { Enabled: true, Events: [DEPLOYMENT_FAILURE, DEPLOYMENT_STOP_ON_ALARM] }
      AlarmConfiguration: { Enabled: true, Alarms: [{ Name: !Ref ErrorAlarm }] }
```

### Pre-Traffic Hook Implementation

```python
# src/hooks/pre_traffic.py — validates new version before traffic shift
import json, boto3
codedeploy, lam = boto3.client('codedeploy'), boto3.client('lambda')

def handler(event, context):
    status = 'Succeeded'
    try:
        resp = lam.invoke(FunctionName=context.function_name,
            InvocationType='RequestResponse',
            Payload=json.dumps({'httpMethod': 'GET', 'path': '/health'}))
        if resp['StatusCode'] != 200: status = 'Failed'
    except Exception: status = 'Failed'
    codedeploy.put_lifecycle_event_hook_execution_status(
        deploymentId=event['DeploymentId'],
        lifecycleEventHookExecutionId=event['LifecycleEventHookExecutionId'],
        status=status)
```

---

## Canary Deployments

### Canary with CodeDeploy and Custom Configurations

```yaml
  PaymentFunction:
    Type: AWS::Serverless::Function
    Properties:
      Handler: handlers/payment.handler
      CodeUri: src/
      Runtime: python3.12
      AutoPublishAlias: live
      DeploymentPreference:
        Type: Canary10Percent5Minutes
        Alarms: [!Ref PaymentErrorAlarm, !Ref PaymentLatencyAlarm]
        Hooks: { PreTraffic: !Ref PaymentPreTrafficHook }
```

| Configuration                   | Behavior                          |
|---------------------------------|-----------------------------------|
| `Canary10Percent5Minutes`       | 10% for 5 min, then 100%         |
| `Canary10Percent10Minutes`      | 10% for 10 min, then 100%        |
| `Canary10Percent30Minutes`      | 10% for 30 min, then 100%        |
| `Linear10PercentEvery1Minute`   | +10% every 1 min over 10 min     |
| `Linear10PercentEvery10Minutes` | +10% every 10 min over 100 min   |
| `AllAtOnce`                     | Immediate full shift              |

### Custom Configurations and Alarm-Based Rollback

```yaml
  CustomCanary:
    Type: AWS::CodeDeploy::DeploymentConfig
    Properties:
      DeploymentConfigName: Canary25Percent10Minutes
      ComputePlatform: Lambda
      TrafficRoutingConfig:
        Type: TimeBasedCanary
        TimeBasedCanary: { CanaryPercentage: 25, CanaryInterval: 10 }
  CustomLinear:
    Type: AWS::CodeDeploy::DeploymentConfig
    Properties:
      DeploymentConfigName: Linear5PercentEvery2Minutes
      ComputePlatform: Lambda
      TrafficRoutingConfig:
        Type: TimeBasedLinear
        TimeBasedLinear: { LinearPercentage: 5, LinearInterval: 2 }
  PaymentErrorAlarm:  # triggers automatic rollback during deployment
    Type: AWS::CloudWatch::Alarm
    Properties:
      MetricName: Errors
      Namespace: AWS/Lambda
      Statistic: Sum
      Period: 60
      EvaluationPeriods: 1
      Threshold: 1
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching
      Dimensions:
        - { Name: FunctionName, Value: !Ref PaymentFunction }
        - { Name: Resource, Value: !Sub '${PaymentFunction}:live' }
```

---

## Multi-Environment Setup

### Parameter Store and Cross-Account Roles

```bash
aws ssm put-parameter --name "/dev/database/url" --type SecureString --value "host=dev-db.example.com"
aws ssm put-parameter --name "/prod/database/url" --type SecureString --value "host=prod-db.example.com"
```

Reference: `!Sub '{{resolve:ssm:/${Environment}/database/url}}'`

```yaml
# OIDC provider for GitHub Actions cross-account access
Resources:
  GitHubOIDCProvider:
    Type: AWS::IAM::OIDCProvider
    Properties:
      Url: https://token.actions.githubusercontent.com
      ClientIdList: [sts.amazonaws.com]
  DeployRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: github-actions-deploy
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: { Federated: !Ref GitHubOIDCProvider }
            Action: sts:AssumeRoleWithWebIdentity
            Condition:
              StringEquals: { 'token.actions.githubusercontent.com:aud': sts.amazonaws.com }
              StringLike: { 'token.actions.githubusercontent.com:sub': 'repo:your-org/your-repo:*' }
      ManagedPolicyArns: ['arn:aws:iam::aws:policy/AdministratorAccess']
```

### samconfig.toml Per Environment

```toml
version = 0.1
[dev.deploy.parameters]
stack_name = "order-api-dev"
resolve_s3 = true
capabilities = "CAPABILITY_IAM CAPABILITY_AUTO_EXPAND"
parameter_overrides = "Environment=dev LogLevel=DEBUG"
confirm_changeset = false
[staging.deploy.parameters]
stack_name = "order-api-staging"
parameter_overrides = "Environment=staging LogLevel=INFO"
confirm_changeset = true
[prod.deploy.parameters]
stack_name = "order-api-prod"
parameter_overrides = "Environment=prod LogLevel=WARN"
confirm_changeset = true
```

### CDK Environment Stacks

```typescript
const envs = {
  dev:     { account: '111111111111', region: 'us-east-1', logLevel: 'DEBUG' },
  staging: { account: '222222222222', region: 'us-east-1', logLevel: 'INFO' },
  prod:    { account: '333333333333', region: 'us-east-1', logLevel: 'WARN' },
};
for (const [name, cfg] of Object.entries(envs)) {
  new OrderApiStack(app, `OrderApi-${name}`, {
    env: { account: cfg.account, region: cfg.region },
    environment: name, logLevel: cfg.logLevel,
  });
}
```

---

## Infrastructure Testing

### cfn-lint for CloudFormation

```bash
pip install cfn-lint && cfn-lint template.yaml
cfn-lint template.yaml --include-checks I --configure-rule E3012:strict=true
```

### CDK Assertions (Snapshot and Fine-Grained)

```typescript
import * as cdk from 'aws-cdk-lib';
import { Template, Match, Capture } from 'aws-cdk-lib/assertions';
import { OrderApiStack } from '../lib/order-api-stack';

describe('OrderApiStack', () => {
  const tpl = Template.fromStack(
    new OrderApiStack(new cdk.App(), 'T', { environment: 'dev', logLevel: 'DEBUG' }));

  test('snapshot', () => expect(tpl.toJSON()).toMatchSnapshot());

  test('DynamoDB key schema', () => {
    tpl.hasResourceProperties('AWS::DynamoDB::Table', {
      KeySchema: [{ AttributeName: 'PK', KeyType: 'HASH' }, { AttributeName: 'SK', KeyType: 'RANGE' }],
      BillingMode: 'PAY_PER_REQUEST',
    });
  });

  test('Lambda runtime and tracing', () => {
    tpl.hasResourceProperties('AWS::Lambda::Function', {
      Runtime: 'python3.12', TracingConfig: { Mode: 'Active' },
    });
  });

  test('Lambda env vars', () => {
    const cap = new Capture();
    tpl.hasResourceProperties('AWS::Lambda::Function', { Environment: { Variables: cap } });
    expect(cap.asObject()).toHaveProperty('ENVIRONMENT', 'dev');
  });

  test('IAM grants DynamoDB access', () => {
    tpl.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: { Statement: Match.arrayWith([Match.objectLike({
        Action: Match.arrayWith(['dynamodb:GetItem']), Effect: 'Allow' })]) },
    });
  });
});
```

### Serverless Framework and Terraform Validation

```bash
npx serverless print --stage dev       # validate config
npx serverless package --stage dev     # package without deploying
terraform init && terraform fmt -check -recursive && terraform validate
terraform plan -var-file=environments/prod.tfvars -out=tfplan
```

```yaml
# .github/workflows/terraform.yml — CI validation
jobs:
  validate:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: terraform } }
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform fmt -check -recursive && terraform init -backend=false && terraform validate
```

### Integration Test Patterns

```python
# tests/integration/test_api.py
import os, requests
API, HDR = os.environ['API_URL'], {'Authorization': f'Bearer {os.environ.get("AUTH_TOKEN","")}', 'Content-Type': 'application/json'}

def test_create_and_get():
    r = requests.post(f'{API}/orders', json={'customerId': 'c-1', 'items': [{'productId': 'p-1', 'qty': 2}]}, headers=HDR)
    assert r.status_code == 201
    r = requests.get(f'{API}/orders/{r.json()["orderId"]}', headers=HDR)
    assert r.status_code == 200 and r.json()['customerId'] == 'c-1'

def test_invalid_payload(): assert requests.post(f'{API}/orders', json={}, headers=HDR).status_code == 400
def test_not_found():       assert requests.get(f'{API}/orders/missing', headers=HDR).status_code == 404
def test_unauthenticated(): assert requests.get(f'{API}/orders').status_code == 401
```

Run after deploy: `API_URL=$(aws cloudformation describe-stacks --stack-name order-api-dev --query 'Stacks[0].Outputs[?OutputKey==\`ApiEndpoint\`].OutputValue' --output text) pytest tests/integration/ -v`
