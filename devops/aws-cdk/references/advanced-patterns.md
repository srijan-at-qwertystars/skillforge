# Advanced CDK Patterns

## Table of Contents

- [Cross-Account Deployments](#cross-account-deployments)
- [Custom Resources with Lambda](#custom-resources-with-lambda)
- [CDK Aspects for Compliance and Tagging](#cdk-aspects-for-compliance-and-tagging)
- [Escape Hatches (L1 Overrides)](#escape-hatches-l1-overrides)
- [Feature Flags](#feature-flags)
- [Context Lookups](#context-lookups)
- [Stack Separation Strategies](#stack-separation-strategies)
- [CDK Migrate](#cdk-migrate)
- [Importing Existing Resources](#importing-existing-resources)
- [CloudFormation Compatibility](#cloudformation-compatibility)

---

## Cross-Account Deployments

### Bootstrap Target Accounts

Every target account must be bootstrapped with trust to the pipeline account:

```bash
# From the target account (e.g., staging/prod)
npx cdk bootstrap aws://TARGET_ACCOUNT/REGION \
  --trust PIPELINE_ACCOUNT_ID \
  --cloudformation-execution-policies arn:aws:iam::aws:policy/AdministratorAccess \
  --qualifier myapp

# Qualifier scopes the bootstrap stack — use it when multiple teams share an account.
```

### Pipeline with Cross-Account Stages

```typescript
import { CodePipeline, CodePipelineSource, ShellStep } from 'aws-cdk-lib/pipelines';

const pipeline = new CodePipeline(this, 'Pipeline', {
  crossAccountKeys: true, // Enables KMS for cross-account artifact encryption
  synth: new ShellStep('Synth', {
    input: CodePipelineSource.gitHub('org/repo', 'main'),
    commands: ['npm ci', 'npx cdk synth'],
  }),
});

pipeline.addStage(new AppStage(this, 'Staging', {
  env: { account: '111111111111', region: 'us-east-1' },
}));

pipeline.addStage(new AppStage(this, 'Prod', {
  env: { account: '222222222222', region: 'us-east-1' },
}));
```

### Cross-Account Resource Access

```typescript
// Granting cross-account access to an S3 bucket
import * as iam from 'aws-cdk-lib/aws-iam';

bucket.addToResourcePolicy(new iam.PolicyStatement({
  actions: ['s3:GetObject'],
  resources: [bucket.arnForObjects('*')],
  principals: [new iam.AccountPrincipal('TARGET_ACCOUNT_ID')],
}));

// Cross-account role assumption
const crossAccountRole = iam.Role.fromRoleArn(this, 'CrossRole',
  `arn:aws:iam::${targetAccount}:role/MyCrossAccountRole`
);
```

### Cross-Account Stack References

Cross-account stacks cannot use direct cross-stack references. Use SSM Parameter Store or custom resources:

```typescript
// In producing stack (account A)
new ssm.StringParameter(this, 'ExportedArn', {
  parameterName: '/shared/api-endpoint',
  stringValue: api.url,
});

// In consuming stack (account B) — use a custom resource or read at deploy time
const endpoint = ssm.StringParameter.valueFromLookup(this, '/shared/api-endpoint');
// NOTE: valueFromLookup resolves at synth time. Use valueForStringParameter for deploy-time.
```

---

## Custom Resources with Lambda

### Provider Framework (Recommended)

The `Provider` framework handles request routing, error handling, and response:

```typescript
import * as cr from 'aws-cdk-lib/custom-resources';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { CustomResource, Duration } from 'aws-cdk-lib';

const onEventHandler = new lambda.Function(this, 'OnEvent', {
  runtime: lambda.Runtime.NODEJS_20_X,
  handler: 'index.onEvent',
  code: lambda.Code.fromAsset('lambda/custom-resource'),
  timeout: Duration.minutes(5),
});

const provider = new cr.Provider(this, 'Provider', {
  onEventHandler,
  // Optional: for long-running operations
  isCompleteHandler: new lambda.Function(this, 'IsComplete', {
    runtime: lambda.Runtime.NODEJS_20_X,
    handler: 'index.isComplete',
    code: lambda.Code.fromAsset('lambda/custom-resource'),
  }),
  totalTimeout: Duration.minutes(30),
  queryInterval: Duration.seconds(30),
});

const resource = new CustomResource(this, 'MyResource', {
  serviceToken: provider.serviceToken,
  properties: {
    DatabaseName: 'mydb',
    SchemaVersion: '2',
  },
});

// Access return values
const result = resource.getAttString('ConnectionString');
```

### Lambda Handler Pattern

```typescript
// lambda/custom-resource/index.ts
import { CdkCustomResourceEvent, CdkCustomResourceResponse } from 'aws-lambda';

export async function onEvent(
  event: CdkCustomResourceEvent
): Promise<CdkCustomResourceResponse> {
  const { RequestType, ResourceProperties } = event;

  switch (RequestType) {
    case 'Create':
      const result = await createResource(ResourceProperties);
      return {
        PhysicalResourceId: result.id,
        Data: { ConnectionString: result.connStr },
      };
    case 'Update':
      await updateResource(event.PhysicalResourceId, ResourceProperties);
      return { PhysicalResourceId: event.PhysicalResourceId };
    case 'Delete':
      await deleteResource(event.PhysicalResourceId);
      return { PhysicalResourceId: event.PhysicalResourceId };
  }
}
```

### AwsCustomResource (SDK Calls)

For simple cases where you just need to call an AWS SDK API:

```typescript
import * as cr from 'aws-cdk-lib/custom-resources';

const describeCluster = new cr.AwsCustomResource(this, 'DescribeCluster', {
  onCreate: {
    service: 'ECS',
    action: 'describeClusters',
    parameters: { clusters: [clusterArn] },
    physicalResourceId: cr.PhysicalResourceId.of('ClusterDesc'),
  },
  policy: cr.AwsCustomResourcePolicy.fromSdkCalls({
    resources: cr.AwsCustomResourcePolicy.ANY_RESOURCE,
  }),
});

const clusterStatus = describeCluster.getResponseField('clusters.0.status');
```

---

## CDK Aspects for Compliance and Tagging

### Built-in Tagging

```typescript
import { Tags, Aspects } from 'aws-cdk-lib';

// Tag everything in the app
Tags.of(app).add('CostCenter', '12345');
Tags.of(app).add('Environment', stage);

// Tag only a specific construct tree
Tags.of(myConstruct).add('Team', 'Platform');

// Exclude specific resource types from tagging
Tags.of(app).add('Backup', 'daily', {
  excludeResourceTypes: ['AWS::CloudFront::Distribution'],
});
```

### Custom Compliance Aspect

```typescript
import { IAspect, Annotations, Stack } from 'aws-cdk-lib';
import { IConstruct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as ec2 from 'aws-cdk-lib/aws-ec2';

class SecurityComplianceAspect implements IAspect {
  visit(node: IConstruct): void {
    // Enforce S3 encryption
    if (node instanceof s3.CfnBucket) {
      if (!node.bucketEncryption) {
        Annotations.of(node).addError(
          'S3 buckets must have encryption enabled (SEC-001)'
        );
      }
    }

    // Enforce RDS deletion protection
    if (node instanceof rds.CfnDBInstance) {
      if (node.deletionProtection === false) {
        Annotations.of(node).addError(
          'RDS instances must have deletion protection (SEC-002)'
        );
      }
    }

    // No public subnets for databases
    if (node instanceof rds.CfnDBSubnetGroup) {
      Annotations.of(node).addWarning(
        'Verify DB subnet group uses private subnets only (SEC-003)'
      );
    }

    // Enforce encrypted EBS volumes
    if (node instanceof ec2.CfnVolume) {
      if (!node.encrypted) {
        Annotations.of(node).addError(
          'EBS volumes must be encrypted (SEC-004)'
        );
      }
    }
  }
}

// Apply to the entire app
Aspects.of(app).add(new SecurityComplianceAspect());
```

### Aspect for Auto-Remediation

```typescript
class AutoEncryptBuckets implements IAspect {
  visit(node: IConstruct): void {
    if (node instanceof s3.CfnBucket) {
      node.addPropertyOverride('BucketEncryption', {
        ServerSideEncryptionConfiguration: [{
          ServerSideEncryptionByDefault: {
            SSEAlgorithm: 'aws:kms',
          },
        }],
      });
    }
  }
}
```

### cdk-nag Integration

```typescript
import { AwsSolutionsChecks, HIPAASecurityChecks, NagSuppressions } from 'cdk-nag';

// Apply rule packs
Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
Aspects.of(app).add(new HIPAASecurityChecks());

// Suppress specific rules with justification
NagSuppressions.addResourceSuppressions(myBucket, [
  {
    id: 'AwsSolutions-S1',
    reason: 'Access logging is handled by CloudTrail for this bucket',
  },
]);

// Suppress at stack level
NagSuppressions.addStackSuppressions(stack, [
  { id: 'AwsSolutions-IAM4', reason: 'Managed policies acceptable for this service' },
], true); // true = apply to all children
```

---

## Escape Hatches (L1 Overrides)

When L2 constructs don't expose a property, drop to L1:

### addPropertyOverride

```typescript
import * as s3 from 'aws-cdk-lib/aws-s3';

const bucket = new s3.Bucket(this, 'Bucket');

// Access the underlying CfnBucket (L1)
const cfnBucket = bucket.node.defaultChild as s3.CfnBucket;

// Override a property not exposed by L2
cfnBucket.addPropertyOverride('IntelligentTieringConfigurations', [{
  Id: 'AutoTier',
  Status: 'Enabled',
  Tierings: [
    { AccessTier: 'ARCHIVE_ACCESS', Days: 90 },
    { AccessTier: 'DEEP_ARCHIVE_ACCESS', Days: 180 },
  ],
}]);

// Delete a property
cfnBucket.addPropertyDeletionOverride('LifecycleConfiguration');

// Override metadata
cfnBucket.cfnOptions.metadata = {
  'cfn-lint': { config: { ignore_checks: ['E3012'] } },
};
```

### addOverride (Any CloudFormation Property)

```typescript
cfnBucket.addOverride('DependsOn', ['OtherResourceLogicalId']);
cfnBucket.addOverride('UpdatePolicy', {
  AutoScalingRollingUpdate: { MinInstancesInService: 1 },
});
```

### Replacing L1 Entirely

```typescript
// Remove the default child and add your own
const construct = new s3.Bucket(this, 'Bucket');
construct.node.tryRemoveChild('Resource');

new s3.CfnBucket(construct, 'Resource', {
  bucketName: 'my-fully-custom-bucket',
  // Full L1 control
});
```

---

## Feature Flags

Feature flags control CDK behavior across versions. Set in `cdk.json`:

```json
{
  "context": {
    "@aws-cdk/aws-lambda:recognizeLayerVersion": true,
    "@aws-cdk/core:stackRelativeExports": true,
    "@aws-cdk/aws-apigateway:usagePlanKeyOrderInsensitiveId": true,
    "@aws-cdk/aws-ecs:arnFormatIncludesClusterName": true,
    "@aws-cdk/aws-s3:createDefaultLoggingPolicy": true,
    "@aws-cdk/core:target-partitions": ["aws", "aws-cn"]
  }
}
```

### Recommended Flags for New Projects

Run `cdk init` to get the latest recommended flags. For existing projects, add flags incrementally and test:

```bash
# See what flags are available
npx cdk context --clear  # Reset all cached context
npx cdk doctor            # Shows flag recommendations
```

### Custom Context Values for Feature Toggling

```typescript
const enableWaf = this.node.tryGetContext('enableWaf') === 'true';

if (enableWaf) {
  new wafv2.CfnWebACL(this, 'WAF', { /* ... */ });
}

// Deploy with: cdk deploy -c enableWaf=true
```

---

## Context Lookups

CDK can look up existing AWS resources at synthesis time. Values are cached in `cdk.context.json`.

### VPC Lookup

```typescript
// Look up existing VPC by tags
const vpc = ec2.Vpc.fromLookup(this, 'Vpc', {
  vpcId: 'vpc-1234567890abcdef0',
});

// Or by tags
const vpc = ec2.Vpc.fromLookup(this, 'Vpc', {
  tags: { 'aws:cloudformation:stack-name': 'NetworkStack' },
});

// Or by name
const vpc = ec2.Vpc.fromLookup(this, 'Vpc', {
  vpcName: 'production-vpc',
});
```

### AMI Lookup

```typescript
const ami = ec2.MachineImage.lookup({
  name: 'my-golden-image-*',
  owners: ['self'],
  filters: {
    'tag:Environment': ['production'],
  },
});
```

### Availability Zone Lookup

```typescript
// Automatically looked up based on env
const azs = Stack.of(this).availabilityZones;

// Or from VPC
const vpc = ec2.Vpc.fromLookup(this, 'Vpc', { isDefault: true });
// vpc.availabilityZones is populated from the lookup
```

### Hosted Zone Lookup

```typescript
const zone = route53.HostedZone.fromLookup(this, 'Zone', {
  domainName: 'example.com',
});
```

### Managing Context Cache

```bash
# View cached context
npx cdk context

# Clear specific key
npx cdk context --reset KEY_NUMBER

# Clear all cached lookups (forces re-lookup on next synth)
npx cdk context --clear

# cdk.context.json should be committed to version control
# It ensures deterministic synthesis in CI
```

**Important**: Context lookups require AWS credentials at synth time. For CI, either:
1. Commit `cdk.context.json` (recommended)
2. Provide credentials during synth

---

## Stack Separation Strategies

### Strategy 1: By Lifecycle

```
├── NetworkStack      (rarely changes: VPC, subnets, NAT)
├── DataStack         (careful changes: RDS, DynamoDB, S3)
├── ComputeStack      (frequent changes: Lambda, ECS, API Gateway)
└── MonitoringStack   (independent: CloudWatch, alarms, dashboards)
```

### Strategy 2: By Team Ownership

```
├── PlatformStack     (platform team: VPC, DNS, shared resources)
├── AuthStack         (auth team: Cognito, API keys)
├── ApiStack          (backend team: Lambda, API GW, queues)
└── FrontendStack     (frontend team: S3, CloudFront)
```

### Strategy 3: By Blast Radius

Isolate resources that could cause outages if misconfigured:

```typescript
// Separate stateful from stateless
class StatefulStack extends Stack {
  public readonly table: dynamodb.ITable;
  public readonly bucket: s3.IBucket;
  constructor(scope: Construct, id: string, props: StackProps) {
    super(scope, id, props);
    // RemovalPolicy.RETAIN for everything here
    // termination protection ON
    this.terminationProtection = true;
  }
}

class StatelessStack extends Stack {
  constructor(scope: Construct, id: string, props: StatelessProps) {
    super(scope, id, props);
    // Lambdas, API Gateways — safe to tear down and recreate
  }
}
```

### Avoiding Cross-Stack Reference Pitfalls

```typescript
// AVOID: Direct construct references between stacks create CloudFormation exports
// These exports cannot be deleted while imported by another stack.

// PREFER: Use SSM parameters or pass string ARNs
const tableArn = ssm.StringParameter.valueForStringParameter(
  this, '/app/table-arn'
);
const table = dynamodb.Table.fromTableArn(this, 'ImportedTable', tableArn);
```

---

## CDK Migrate

Convert existing CloudFormation templates or deployed stacks to CDK code:

```bash
# From a CloudFormation template file
npx cdk migrate --from-path template.json --stack-name MyStack --language typescript

# From a deployed stack (pulls the current template)
npx cdk migrate --from-stack --stack-name MyStack --language typescript

# Specify output directory
npx cdk migrate --from-stack --stack-name MyStack \
  --language typescript --output-path ./migrated-stack
```

### Post-Migration Steps

1. **Review generated code** — CDK Migrate produces L1 (Cfn*) constructs. Refactor to L2 where possible.
2. **Run `cdk diff`** — should show zero changes if migration is accurate.
3. **Add construct IDs** — generated IDs may be ugly; rename them (will cause resource replacement if physical names change).
4. **Extract constructs** — group related resources into logical constructs.

---

## Importing Existing Resources

### Stateful Resources (Zero Downtime)

```typescript
// Import an existing DynamoDB table
const table = dynamodb.Table.fromTableAttributes(this, 'ImportedTable', {
  tableArn: 'arn:aws:dynamodb:us-east-1:123456789012:table/MyTable',
  globalIndexes: ['GSI1'],
});

// Import an existing S3 bucket
const bucket = s3.Bucket.fromBucketAttributes(this, 'ImportedBucket', {
  bucketArn: 'arn:aws:s3:::my-existing-bucket',
  region: 'us-east-1',
});

// Import an existing VPC
const vpc = ec2.Vpc.fromVpcAttributes(this, 'ImportedVpc', {
  vpcId: 'vpc-12345',
  availabilityZones: ['us-east-1a', 'us-east-1b'],
  publicSubnetIds: ['subnet-aaa', 'subnet-bbb'],
  privateSubnetIds: ['subnet-ccc', 'subnet-ddd'],
});
```

### Import Into CloudFormation Management

To have CDK manage an existing resource (not just reference it):

1. Add the resource to your CDK stack with matching configuration
2. Use `cdk import` to adopt it:

```bash
npx cdk import MyStack
# CDK will prompt you for the resource identifier of each new resource
```

**Key rule**: The resource configuration in CDK must match the actual resource, or CloudFormation will try to modify it.

---

## CloudFormation Compatibility

### Using Raw CloudFormation

```typescript
import { CfnResource, Fn } from 'aws-cdk-lib';

// Include arbitrary CloudFormation
new CfnResource(this, 'CustomAlarm', {
  type: 'AWS::CloudWatch::Alarm',
  properties: {
    AlarmName: 'MyAlarm',
    MetricName: 'Errors',
    Namespace: 'MyApp',
    Statistic: 'Sum',
    Period: 300,
    EvaluationPeriods: 1,
    Threshold: 1,
    ComparisonOperator: 'GreaterThanOrEqualToThreshold',
  },
});
```

### Including CloudFormation Templates

```typescript
import { CfnInclude } from 'aws-cdk-lib/cloudformation-include';

const template = new CfnInclude(this, 'Template', {
  templateFile: 'existing-template.json',
  preserveLogicalIds: true,
});

// Access resources from the included template
const cfnBucket = template.getResource('MyBucket') as s3.CfnBucket;

// Modify included resources
cfnBucket.addPropertyOverride('VersioningConfiguration.Status', 'Enabled');
```

### CloudFormation Intrinsic Functions

```typescript
import { Fn, CfnCondition, CfnParameter } from 'aws-cdk-lib';

// Fn::Select, Fn::Split
const firstAz = Fn.select(0, Fn.getAzs());

// Conditions
const isProd = new CfnCondition(this, 'IsProd', {
  expression: Fn.conditionEquals(stage, 'prod'),
});

// Conditional resources
const resource = new s3.CfnBucket(this, 'Bucket');
resource.cfnOptions.condition = isProd;

// Parameters (prefer context values instead)
const param = new CfnParameter(this, 'InstanceType', {
  type: 'String',
  default: 't3.micro',
  allowedValues: ['t3.micro', 't3.small', 't3.medium'],
});
```

### CloudFormation Macros and Transforms

```typescript
// Add a transform
this.addTransform('AWS::Serverless-2016-10-31');

// Stack-level transforms
stack.addTransform('AWS::LanguageExtensions');
```
