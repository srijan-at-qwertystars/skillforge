---
name: aws-cdk
description: >
  Build and manage AWS infrastructure using AWS CDK (Cloud Development Kit) with TypeScript or Python.
  TRIGGER when: user asks to create CDK stacks, constructs, or infrastructure-as-code with AWS CDK;
  mentions cdk init, cdk deploy, cdk synth, cdk diff; works with L1/L2/L3 constructs; builds
  Lambda+API Gateway, S3+CloudFront, VPC+ECS/Fargate, DynamoDB, SQS/SNS patterns; sets up CDK
  Pipelines; writes CDK tests or custom constructs; uses cdk-nag or CDK Aspects.
  DO NOT TRIGGER when: user works with Terraform, Pulumi, CloudFormation YAML/JSON directly,
  AWS SAM, Serverless Framework, or non-AWS cloud providers.
---

# AWS CDK Skill

## Core Concepts

**App** → top-level scope. One App synthesizes into a `cdk.out` cloud assembly.
**Stack** → unit of deployment, maps 1:1 to a CloudFormation stack. Max 500 resources recommended.
**Construct** → building block. Three levels:
- **L1 (Cfn*)**: 1:1 CloudFormation mapping. Use when L2 doesn't exist or you need every property.
- **L2 (curated)**: Sensible defaults, helper methods (e.g., `Bucket`, `Function`). Prefer these.
- **L3 (patterns)**: Opinionated multi-resource architectures (e.g., `LambdaRestApi`).

**Synthesis** → `cdk synth` converts CDK code into CloudFormation JSON in `cdk.out/`.

## Project Setup

### Initialize
```bash
# TypeScript (recommended)
npx cdk init app --language typescript
# Python
npx cdk init app --language python && source .venv/bin/activate && pip install -r requirements.txt
```

### Bootstrap (once per account/region)
```bash
npx cdk bootstrap aws://ACCOUNT_ID/REGION
# Cross-account with custom policy
npx cdk bootstrap aws://ACCOUNT_ID/REGION \
  --trust PIPELINE_ACCOUNT_ID \
  --cloudformation-execution-policies arn:aws:iam::aws:policy/PowerUserAccess
```

### cdk.json Key Fields
```json
{
  "app": "npx ts-node --prefer-ts-exts bin/app.ts",
  "context": {
    "@aws-cdk/core:stackRelativeExports": true,
    "env": "staging"
  },
  "watch": {
    "include": ["**"],
    "exclude": ["cdk.out", "node_modules", "**/*.js", "**/*.d.ts"]
  }
}
```

## CLI Commands

| Command | Purpose |
|---------|---------|
| `cdk synth` | Synthesize CloudFormation template |
| `cdk diff` | Show pending changes vs deployed |
| `cdk deploy` | Deploy stack(s) |
| `cdk deploy --hotswap` | Fast-deploy Lambda/ECS changes (dev only) |
| `cdk watch` | Auto-deploy on file change (dev only) |
| `cdk destroy` | Tear down stack(s) |
| `cdk ls` | List all stacks in the app |
| `cdk doctor` | Diagnose environment issues |

Use `--require-approval never` in CI. Use `--exclusively` to deploy one stack without dependencies.

## Common Patterns

### Lambda + API Gateway (TypeScript)
```typescript
import { Stack, StackProps } from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigw from 'aws-cdk-lib/aws-apigateway';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';

export class ApiStack extends Stack {
  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props);

    const handler = new NodejsFunction(this, 'Handler', {
      entry: 'lambda/handler.ts',
      runtime: lambda.Runtime.NODEJS_20_X,
      memorySize: 256,
      bundling: {
        minify: true,
        sourceMap: true,
        externalModules: ['@aws-sdk/*'],
      },
    });

    new apigw.LambdaRestApi(this, 'Api', {
      handler,
      proxy: false,
    }).root.addResource('items').addMethod('GET');
  }
}
```

### Lambda + API Gateway (Python)
```python
from aws_cdk import Stack, aws_lambda as _lambda, aws_apigateway as apigw
from constructs import Construct

class ApiStack(Stack):
    def __init__(self, scope: Construct, id: str, **kwargs):
        super().__init__(scope, id, **kwargs)

        handler = _lambda.Function(self, "Handler",
            runtime=_lambda.Runtime.PYTHON_3_12,
            code=_lambda.Code.from_asset("lambda"),
            handler="handler.main",
            memory_size=256,
        )

        api = apigw.LambdaRestApi(self, "Api", handler=handler, proxy=False)
        api.root.add_resource("items").add_method("GET")
```

### S3 + CloudFront
```typescript
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import { RemovalPolicy } from 'aws-cdk-lib';

const bucket = new s3.Bucket(this, 'Site', {
  removalPolicy: RemovalPolicy.DESTROY,
  autoDeleteObjects: true,
  blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
});

new cloudfront.Distribution(this, 'CDN', {
  defaultBehavior: {
    origin: origins.S3BucketOrigin.withOriginAccessControl(bucket),
    viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
  },
  defaultRootObject: 'index.html',
});
```

### VPC + ECS/Fargate

```typescript
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as patterns from 'aws-cdk-lib/aws-ecs-patterns';

const vpc = new ec2.Vpc(this, 'Vpc', { maxAzs: 2 });

new patterns.ApplicationLoadBalancedFargateService(this, 'Service', {
  vpc,
  cpu: 256,
  memoryLimitMiB: 512,
  desiredCount: 2,
  taskImageOptions: {
    image: ecs.ContainerImage.fromAsset('./app'),
    containerPort: 8080,
  },
  publicLoadBalancer: true,
});
```

### DynamoDB + SQS/SNS

```typescript
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as subs from 'aws-cdk-lib/aws-sns-subscriptions';

const table = new dynamodb.Table(this, 'Table', {
  partitionKey: { name: 'pk', type: dynamodb.AttributeType.STRING },
  sortKey: { name: 'sk', type: dynamodb.AttributeType.STRING },
  billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
  removalPolicy: RemovalPolicy.RETAIN,
  pointInTimeRecoveryEnabled: true,
});

const dlq = new sqs.Queue(this, 'DLQ');
const queue = new sqs.Queue(this, 'Queue', {
  deadLetterQueue: { queue: dlq, maxReceiveCount: 3 },
});

const topic = new sns.Topic(this, 'Topic');
topic.addSubscription(new subs.SqsSubscription(queue));
```

## Stack Organization

### Multi-Stack App Entry Point
```typescript
const app = new cdk.App();
const env = { account: '123456789012', region: 'us-east-1' };

const network = new NetworkStack(app, 'Network', { env });
const data = new DataStack(app, 'Data', { env, vpc: network.vpc });
const api = new ApiStack(app, 'Api', { env, table: data.table, vpc: network.vpc });
// CDK resolves deploy order from cross-stack references automatically.
```

### Cross-Stack References
Export via public properties. CDK creates CloudFormation Exports automatically:
```typescript
// In NetworkStack
public readonly vpc: ec2.IVpc;
// In consuming stack constructor
new lambda.Function(this, 'Fn', { vpc: props.vpc, ... });
```

### Environment-Agnostic Stacks
Omit `env` to make stacks deploy to any account/region. Use `Fn.ref('AWS::Region')` for region-dependent logic. Prefer explicit `env` for production stacks.

### Context Values
```typescript
const stage = this.node.tryGetContext('stage') || 'dev';
// Pass via CLI: cdk deploy -c stage=prod
// Or set in cdk.json under "context"
```

## CDK Pipelines

```typescript
import { CodePipeline, CodePipelineSource, ShellStep, ManualApprovalStep } from 'aws-cdk-lib/pipelines';

const pipeline = new CodePipeline(this, 'Pipeline', {
  pipelineName: 'MyPipeline',
  synth: new ShellStep('Synth', {
    input: CodePipelineSource.gitHub('org/repo', 'main'),
    commands: ['npm ci', 'npm run build', 'npx cdk synth'],
    primaryOutputDirectory: 'cdk.out',
  }),
});

// Deploy stages
pipeline.addStage(new AppStage(this, 'Staging', {
  env: { account: '111111111111', region: 'us-east-1' },
}));

pipeline.addStage(new AppStage(this, 'Prod', {
  env: { account: '222222222222', region: 'us-east-1' },
}), {
  pre: [new ManualApprovalStep('PromoteToProd')],
});
```

The pipeline is **self-mutating**: changes to pipeline code auto-update the pipeline itself on next push.

### Stage Definition
```typescript
class AppStage extends cdk.Stage {
  constructor(scope: Construct, id: string, props: cdk.StageProps) {
    super(scope, id, props);
    new ApiStack(this, 'Api');
    new DataStack(this, 'Data');
  }
}
```

## Testing

### Unit Tests with Assertions (TypeScript/Jest)
```typescript
import { Template } from 'aws-cdk-lib/assertions';
import { App } from 'aws-cdk-lib';
import { ApiStack } from '../lib/api-stack';

test('creates Lambda with correct runtime', () => {
  const template = Template.fromStack(new ApiStack(new App(), 'Test'));
  template.hasResourceProperties('AWS::Lambda::Function', {
    Runtime: 'nodejs20.x',
    MemorySize: 256,
  });
  template.resourceCountIs('AWS::ApiGateway::Method', 1);
});
```

### Unit Tests (Python/pytest)
```python
from aws_cdk import App, assertions
from my_app.api_stack import ApiStack

def test_lambda_runtime():
    app = App()
    stack = ApiStack(app, "Test")
    template = assertions.Template.from_stack(stack)
    template.has_resource_properties("AWS::Lambda::Function", {
        "Runtime": "python3.12",
        "MemorySize": 256,
    })
```

### Snapshot Tests
```typescript
test('matches snapshot', () => {
  expect(Template.fromStack(new ApiStack(new App(), 'T')).toJSON()).toMatchSnapshot();
}); // Update: npx jest --updateSnapshot
```

### Integration Tests
```bash
# Deploy test stack, run assertions, destroy
npx cdk deploy TestStack && npm run integ-test && npx cdk destroy TestStack -f
```

## Custom Constructs

### Creating a Reusable L3 Construct
```typescript
import { Construct } from 'constructs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';

export interface CrudApiProps {
  tableName?: string;
  lambdaMemory?: number;
}

export class CrudApi extends Construct {
  public readonly table: dynamodb.Table;
  public readonly handler: lambda.Function;

  constructor(scope: Construct, id: string, props: CrudApiProps = {}) {
    super(scope, id);

    this.table = new dynamodb.Table(this, 'Table', {
      partitionKey: { name: 'id', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      tableName: props.tableName,
    });

    this.handler = new lambda.Function(this, 'Handler', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/crud'),
      memorySize: props.lambdaMemory ?? 256,
      environment: { TABLE_NAME: this.table.tableName },
    });

    this.table.grantReadWriteData(this.handler);
  }
}
```

## CDK Aspects

### Tagging and Compliance
```typescript
import { Aspects, Tags } from 'aws-cdk-lib';
import { AwsSolutionsChecks, NagSuppressions } from 'cdk-nag';

// Tag all resources
Tags.of(app).add('Project', 'MyApp');
Tags.of(app).add('Environment', 'production');

// cdk-nag compliance checks
Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
NagSuppressions.addStackSuppressions(stack, [
  { id: 'AwsSolutions-IAM4', reason: 'Managed policy acceptable for logging role' },
]);
```

### Custom Aspect
```typescript
import { IAspect, Annotations } from 'aws-cdk-lib';
import { IConstruct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';

class BucketVersioningChecker implements IAspect {
  visit(node: IConstruct): void {
    if (node instanceof s3.CfnBucket && !node.versioningConfiguration) {
      Annotations.of(node).addError('S3 buckets must have versioning enabled.');
    }
  }
}
```

## Asset Bundling

### NodejsFunction (esbuild)
```typescript
new NodejsFunction(this, 'Fn', {
  entry: 'src/handler.ts',
  runtime: lambda.Runtime.NODEJS_20_X,
  bundling: {
    minify: true,
    sourceMap: true,
    target: 'node20',
    format: lambda_nodejs.OutputFormat.ESM,
    externalModules: ['@aws-sdk/*'],  // Lambda provides AWS SDK
  },
});
```

## Best Practices

**IAM**: Use `grant*` methods (`table.grantReadData(fn)`). Never use `*` resource in PolicyStatements.
**Removal Policies**: `RETAIN` for production, `DESTROY` + `autoDeleteObjects` for dev only.
**Stack Naming**: Let CDK generate names. Avoid physical names—they prevent replacements.
**Structure**: One stack per bounded context. Keep under 500 resources. Use Stages per environment.
**Secrets**: Use `SecretValue.secretsManager()` or SSM parameters. Never hardcode.
**Outputs**: Use `CfnOutput` for important values (API URLs, ARNs).

## Common Gotchas

1. **Circular dependencies**: Two stacks referencing each other. Fix: move shared resources to a third stack, or pass ARN strings instead of constructs.
2. **Removal policy defaults**: CDK defaults to `RETAIN` for stateful resources. Set `RemovalPolicy.DESTROY` explicitly for dev. Forgetting leaves orphaned resources.
3. **Physical names**: Specifying `bucketName`, `tableName` etc. prevents CloudFormation replacements. Omit unless required.
4. **Cross-stack export locks**: Once an Export exists and another stack imports it, you cannot delete/rename it without first removing the import.
5. **`cdk deploy '*'`**: Deploys all stacks. Use `--concurrency 3` for parallel independent stacks.
6. **Construct IDs must be unique** within their scope. Duplicates cause synthesis errors.
7. **Token resolution**: Tokens resolve at deploy time. Don't use JS string ops on tokens; use `cdk.Fn.join`/`cdk.Fn.select`.

## Reference Documentation

Detailed reference guides in `references/`:

| Document | Contents |
|----------|----------|
| [advanced-patterns.md](references/advanced-patterns.md) | Cross-account deployments, custom resources, CDK Aspects, escape hatches, feature flags, context lookups, stack separation, CDK Migrate, importing resources, CloudFormation compatibility |
| [troubleshooting.md](references/troubleshooting.md) | Bootstrap mismatches, cyclic dependencies, token resolution, asset bundling, Docker issues, false diffs, permission errors, rollback handling, drift detection, synth vs deploy errors |
| [construct-library.md](references/construct-library.md) | jsii multi-language support, projen project management, construct testing, API design, versioning, publishing to npm/PyPI/Maven/NuGet, Construct Hub listing |

## Scripts

Executable helpers in `scripts/` (bash, `chmod +x`):

| Script | Purpose |
|--------|---------|
| [init-cdk-project.sh](scripts/init-cdk-project.sh) | Initialize a new CDK TypeScript project with VPC, common deps, tsconfig, and tests |
| [deploy-pipeline.sh](scripts/deploy-pipeline.sh) | Set up CDK Pipeline with dev/staging/prod stages, cross-account bootstrap, approval steps |
| [cdk-diff-check.sh](scripts/cdk-diff-check.sh) | CI/CD helper: synth + diff, fail on destructive changes (replacements/deletions) |

## Asset Templates

Copy-paste-ready templates in `assets/`:

| Template | Description |
|----------|-------------|
| [stack-template.ts](assets/stack-template.ts) | Production-ready stack with tagging, removal policies, outputs, termination protection, cdk-nag |
| [lambda-api-construct.ts](assets/lambda-api-construct.ts) | Reusable L3 construct: Lambda + API Gateway REST API with CORS, logging, custom domain, alarms |
| [pipeline-stack.ts](assets/pipeline-stack.ts) | CDK Pipeline with dev/staging/prod stages, manual approval, SNS notifications |
| [cdk-nag-setup.ts](assets/cdk-nag-setup.ts) | cdk-nag integration: AwsSolutions/HIPAA/NIST packs, common suppressions, test helpers |
| [Makefile](assets/Makefile) | Common CDK targets: synth, diff, deploy, destroy, test, lint, bootstrap, CI pipeline |

## Example Input/Output

**User**: "Create a CDK stack with an S3 bucket that triggers a Lambda on object upload"

**Output**:
```typescript
import { Stack, StackProps, RemovalPolicy } from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3n from 'aws-cdk-lib/aws-s3-notifications';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import * as lambda from 'aws-cdk-lib/aws-lambda';

export class UploadProcessorStack extends Stack {
  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props);

    const processor = new NodejsFunction(this, 'Processor', {
      entry: 'lambda/process-upload.ts',
      runtime: lambda.Runtime.NODEJS_20_X,
      bundling: { minify: true, externalModules: ['@aws-sdk/*'] },
    });

    const bucket = new s3.Bucket(this, 'Uploads', {
      removalPolicy: RemovalPolicy.RETAIN,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    });

    bucket.addEventNotification(
      s3.EventType.OBJECT_CREATED,
      new s3n.LambdaDestination(processor),
    );
    bucket.grantRead(processor);
  }
}
```

**User**: "Add a DynamoDB table and grant the Lambda write access"

**Output**: Add to the stack constructor:
```typescript
const table = new dynamodb.Table(this, 'Metadata', {
  partitionKey: { name: 'objectKey', type: dynamodb.AttributeType.STRING },
  billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
