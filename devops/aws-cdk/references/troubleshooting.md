# CDK Troubleshooting Guide

## Table of Contents

- [Bootstrap Version Mismatches](#bootstrap-version-mismatches)
- [Cyclic Dependency Errors](#cyclic-dependency-errors)
- [Token Resolution Failures](#token-resolution-failures)
- [Asset Bundling Problems](#asset-bundling-problems)
- [Docker Build Context Issues](#docker-build-context-issues)
- [cdk diff Showing False Positives](#cdk-diff-showing-false-positives)
- [Permission Errors During Deploy](#permission-errors-during-deploy)
- [Stack Rollback Handling](#stack-rollback-handling)
- [CloudFormation Drift Detection](#cloudformation-drift-detection)
- [Synthesis Errors vs Deploy Errors](#synthesis-errors-vs-deploy-errors)

---

## Bootstrap Version Mismatches

### Symptoms

```
❌ This CDK deployment requires bootstrap stack version '21', found '14'.
   Please run 'cdk bootstrap aws://ACCOUNT/REGION' to update.
```

### Cause

Your CDK CLI version expects a newer bootstrap stack than what's deployed in the target account/region. The bootstrap stack provides the S3 bucket, ECR repo, and IAM roles CDK needs.

### Fix

```bash
# Check current bootstrap version
aws cloudformation describe-stacks \
  --stack-name CDKToolkit \
  --query "Stacks[0].Outputs[?OutputKey=='BootstrapVersion'].OutputValue" \
  --output text

# Update bootstrap
npx cdk bootstrap aws://ACCOUNT_ID/REGION

# With qualifier (if using custom qualifier)
npx cdk bootstrap aws://ACCOUNT_ID/REGION --qualifier myapp

# Cross-account: re-bootstrap with trust
npx cdk bootstrap aws://TARGET_ACCOUNT/REGION \
  --trust PIPELINE_ACCOUNT \
  --cloudformation-execution-policies arn:aws:iam::aws:policy/AdministratorAccess
```

### Prevention

- Pin CDK CLI version in CI: `npx cdk@2.150.0 deploy`
- Bootstrap before upgrading CDK in CI
- Use `--toolkit-stack-name` if multiple bootstrap stacks exist

---

## Cyclic Dependency Errors

### Symptoms

```
Error: 'StackA' depends on 'StackB' (StackA -> StackB/Resource.Arn).
       Adding this dependency would create a cyclic reference.
```

Or at deploy time:
```
Circular dependency between resources: [ResourceA, ResourceB, ResourceC]
```

### Cause

Two or more stacks/resources reference each other. Common scenarios:
- Stack A exports a VPC, Stack B creates a security group in it, Stack A needs that security group
- Lambda needs a DynamoDB table ARN, table needs the Lambda's role ARN for streams

### Fix Strategies

**Strategy 1: Move shared resources to a third stack**
```typescript
// Before (cyclic):
// StackA creates VPC, needs SG from StackB
// StackB creates SG, needs VPC from StackA

// After:
class NetworkStack extends Stack {
  public readonly vpc: ec2.IVpc;
  public readonly sg: ec2.ISecurityGroup;
}
class AppStack extends Stack {
  constructor(scope, id, props: { vpc, sg }) { /* uses both */ }
}
```

**Strategy 2: Pass ARN strings instead of constructs**
```typescript
// Instead of passing the construct (creates dependency):
new CfnOutput(this, 'BucketArn', { value: bucket.bucketArn });

// In consuming stack, use fromBucketArn:
const bucket = s3.Bucket.fromBucketArn(this, 'Bucket', importedArn);
```

**Strategy 3: Use `addDependency` carefully**
```typescript
// Explicit dependency ordering
stackB.addDependency(stackA);
// Never create bidirectional dependencies
```

**Strategy 4: Remove the export**
```typescript
// If you see "Cannot remove exports" during update, deploy in two steps:
// Step 1: Remove the consumer's reference, deploy consumer stack
// Step 2: Remove the export, deploy producer stack
```

---

## Token Resolution Failures

### Symptoms

```
Error: Resolution error: Trying to resolve() a Tokenized value in a non-CDK context
```

Or unexpected `${Token[TOKEN.123]}` strings appearing in outputs.

### Cause

Tokens are lazy values that resolve at synthesis or deploy time. Common mistakes:
- Using JavaScript string operations on tokens
- Logging/printing token values during synthesis
- Using tokens in contexts that require concrete values

### Fix

```typescript
// ❌ WRONG: String manipulation on tokens
const region = Stack.of(this).region;
const bucketName = `my-bucket-${region}`.toUpperCase(); // Fails!

// ✅ RIGHT: Use CloudFormation intrinsics
const bucketName = Fn.join('-', ['my-bucket', Stack.of(this).region]);

// ❌ WRONG: Conditional on token
if (bucket.bucketArn === 'arn:aws:s3:::expected') { } // Always false

// ✅ RIGHT: Use CfnCondition for deploy-time conditionals
const cond = new CfnCondition(this, 'Cond', {
  expression: Fn.conditionEquals(param.valueAsString, 'expected'),
});

// ❌ WRONG: Array index on token
const firstSubnet = vpc.publicSubnets[0].subnetId; // OK at synth
const fromSelect = Fn.select(0, tokenizedList); // OK for token lists

// Check if a value is a token
import { Token } from 'aws-cdk-lib';
if (Token.isUnresolved(someValue)) {
  // Handle token case
}
```

### Debugging Tokens

```typescript
// See what a token resolves to
console.log('Token value:', Stack.of(this).resolve(myToken));
```

---

## Asset Bundling Problems

### Symptoms

```
Error: Cannot find module 'esbuild'
Error: spawnSync docker ENOENT
Error: Asset bundling failed for lambda/handler.ts
```

### Common Fixes

**esbuild not found (NodejsFunction)**
```bash
# Install esbuild as a dev dependency
npm install --save-dev esbuild

# Or use Docker bundling fallback
new NodejsFunction(this, 'Fn', {
  bundling: {
    forceDockerBundling: true, // Uses Docker when esbuild unavailable
  },
});
```

**Docker not available**
```typescript
// Use local bundling to avoid Docker dependency
new NodejsFunction(this, 'Fn', {
  bundling: {
    forceDockerBundling: false, // Prefer local esbuild
  },
});
```

**Python Lambda bundling fails**
```bash
# Ensure Docker is running for PythonFunction
docker info

# Or use a requirements layer instead
new lambda.LayerVersion(this, 'DepsLayer', {
  code: lambda.Code.fromAsset('layer/', {
    bundling: {
      image: lambda.Runtime.PYTHON_3_12.bundlingImage,
      command: [
        'bash', '-c',
        'pip install -r requirements.txt -t /asset-output/python',
      ],
    },
  }),
});
```

**Asset hash changes on every synth**
```typescript
// Pin the asset hash to avoid unnecessary redeployments
code: lambda.Code.fromAsset('lambda/', {
  assetHashType: AssetHashType.SOURCE,
  // Or use a custom hash
  assetHash: 'v1.2.3',
});
```

---

## Docker Build Context Issues

### Symptoms

```
Error: COPY failed: file not found in build context
Error: Cannot connect to the Docker daemon
Error: Docker image build failed with exit code 1
```

### Fixes

**Build context too large / wrong directory**
```typescript
// ❌ WRONG: Using project root as context (includes node_modules)
code: lambda.DockerImageCode.fromImageAsset('.');

// ✅ RIGHT: Point to specific directory with Dockerfile
code: lambda.DockerImageCode.fromImageAsset('./docker-lambda');

// Use .dockerignore to exclude files
// docker-lambda/.dockerignore:
// node_modules
// cdk.out
// .git
```

**Docker daemon not running**
```bash
# Check Docker status
docker info

# On Linux
sudo systemctl start docker

# On Mac
open -a Docker
```

**Platform mismatch (M1/ARM vs x86)**
```typescript
code: lambda.DockerImageCode.fromImageAsset('./docker-lambda', {
  platform: ecr_assets.Platform.LINUX_AMD64, // Force x86 for Lambda
});
```

**File not found in COPY**
```
# Ensure files are relative to the build context directory
# If your Dockerfile is in ./docker-lambda/ and says COPY src/ /app/
# Then ./docker-lambda/src/ must exist
```

---

## cdk diff Showing False Positives

### Symptoms

`cdk diff` shows changes even when no code has changed. Common false positive types:

### Asset Hash Changes

```
[-] AWS::Lambda::Function Handler
 [~] Code.S3Key changed from "abc123.zip" to "def456.zip"
```

**Cause**: Asset hash changes on every synth (timestamps, file order).
**Fix**:
```typescript
bundling: {
  // Use source hash instead of output hash
  assetHashType: AssetHashType.SOURCE,
},
```

### CDK Metadata Differences

```
[~] AWS::CDK::Metadata
```

**Fix**: Disable CDK metadata (not recommended for production):
```json
// cdk.json
{
  "context": {
    "aws:cdk:disable-version-reporting": true
  }
}
```

### Parameter Store / Context Lookup Changes

Cached values in `cdk.context.json` may differ from current state.

**Fix**:
```bash
# Refresh context
npx cdk context --clear
npx cdk synth
git diff cdk.context.json
```

### Template Formatting

CloudFormation may reformat your template. Use `--strict` for exact comparison:
```bash
npx cdk diff --strict
```

---

## Permission Errors During Deploy

### Symptoms

```
❌ AccessDenied: User: arn:aws:iam::123:user/deployer is not authorized to perform: cloudformation:CreateStack
```

```
❌ The stack named MyStack failed: UPDATE_ROLLBACK_COMPLETE
   Resource handler returned message: "Access Denied"
```

### Common Fixes

**CloudFormation permissions**
```bash
# The deploying principal needs these minimum permissions:
# - cloudformation:* on the stack
# - sts:AssumeRole on CDK bootstrap roles
# - s3:* on the CDK staging bucket

# Use the bootstrap roles (recommended):
npx cdk deploy --role-arn arn:aws:iam::ACCOUNT:role/cdk-QUALIFIER-deploy-role-ACCOUNT-REGION
```

**Lambda execution role missing permissions**
```typescript
// Use grant methods — CDK generates least-privilege policies
table.grantReadWriteData(lambdaFunction);
bucket.grantRead(lambdaFunction);
queue.grantSendMessages(lambdaFunction);

// If you need custom permissions
lambdaFunction.addToRolePolicy(new iam.PolicyStatement({
  actions: ['ses:SendEmail'],
  resources: ['*'],
}));
```

**Cross-account trust not configured**
```bash
# Re-bootstrap with trust
npx cdk bootstrap aws://TARGET/REGION --trust PIPELINE_ACCOUNT
```

**Service-linked role doesn't exist**
```bash
# Some services need a service-linked role created first
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com
aws iam create-service-linked-role --aws-service-name elasticloadbalancing.amazonaws.com
```

---

## Stack Rollback Handling

### Stack Stuck in ROLLBACK_COMPLETE

This means the initial creation failed and the stack must be deleted:

```bash
# Delete the failed stack
aws cloudformation delete-stack --stack-name MyStack

# Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name MyStack

# Then redeploy
npx cdk deploy MyStack
```

### Stack Stuck in UPDATE_ROLLBACK_FAILED

The rollback itself failed, usually because a resource can't be returned to its previous state:

```bash
# Continue the rollback, skipping problematic resources
aws cloudformation continue-update-rollback \
  --stack-name MyStack \
  --resources-to-skip LogicalResourceId1 LogicalResourceId2

# Then fix the underlying issue and redeploy
```

### Disable Rollback for Debugging

```bash
# Keep failed resources for debugging (dev only)
npx cdk deploy --no-rollback MyStack

# After debugging, clean up
aws cloudformation delete-stack --stack-name MyStack
```

### Handling Replacement Errors

```bash
# If a resource replacement fails (e.g., physical name conflict):
# 1. Check which resource failed in CloudFormation events
aws cloudformation describe-stack-events --stack-name MyStack \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED']"

# 2. Common fix: remove the physical name so CloudFormation can auto-generate
# Change: bucketName: 'my-bucket' → (remove bucketName property)
```

---

## CloudFormation Drift Detection

### Detecting Drift

```bash
# Start drift detection
aws cloudformation detect-stack-drift --stack-name MyStack

# Check detection status
aws cloudformation describe-stack-drift-detection-status \
  --stack-drift-detection-id DETECTION_ID

# View drifted resources
aws cloudformation describe-stack-resource-drifts \
  --stack-name MyStack \
  --stack-resource-drift-status-filters MODIFIED DELETED
```

### Common Drift Causes

1. **Manual console changes** — someone modified a resource outside CDK
2. **Other IaC tools** — Terraform or scripts modifying CDK-managed resources
3. **Auto-scaling** — desired count changes from auto-scaling policies
4. **AWS service updates** — AWS adds default properties

### Resolving Drift

```bash
# Option 1: Bring CDK code in line with actual state
# Update your CDK code to match the drifted state, then deploy

# Option 2: Force CDK state back (overwrite manual changes)
npx cdk deploy MyStack
# CloudFormation will update resources to match the template

# Option 3: Import the drifted resource configuration
# Use escape hatches to match the actual property values
```

### Preventing Drift

```typescript
// Use stack policies to prevent manual changes
const stack = new MyStack(app, 'Protected');
// Deploy with:
// aws cloudformation set-stack-policy --stack-name MyStack \
//   --stack-policy-body '{"Statement":[{"Effect":"Deny","Action":"Update:*","Principal":"*","Resource":"*"}]}'

// Use AWS Config rules to detect drift automatically
// Rule: cloudformation-stack-drift-detection-check
```

---

## Synthesis Errors vs Deploy Errors

Understanding when errors occur helps diagnose them faster.

### Synthesis Errors (cdk synth)

Happen during code execution, before any AWS API calls:

| Error | Cause | Fix |
|-------|-------|-----|
| `Construct with id 'X' already exists` | Duplicate construct IDs in same scope | Use unique IDs within each scope |
| `Cannot determine region/account` | Missing `env` for region-dependent features | Set `env` explicitly or use env-agnostic patterns |
| `Validation failed: X` | Construct-level validation | Check property constraints (e.g., memory must be 128-10240) |
| `Resolution error` | Token used in string context | Use `Fn.join` instead of template literals |
| `Unable to determine stack roots` | Missing `new App()` or orphaned stacks | Ensure all stacks are children of an App |
| `TypeError: Cannot read properties of undefined` | Missing construct dependency | Check import statements and construct order |

### Deploy Errors (cdk deploy)

Happen during CloudFormation stack operations:

| Error | Cause | Fix |
|-------|-------|-----|
| `Resource already exists` | Physical name conflicts | Remove physical names or delete conflicting resource |
| `Export cannot be deleted` | Another stack imports this export | Remove import first, then the export |
| `Insufficient permissions` | IAM policy too restrictive | Add required permissions to deploying role |
| `Rate exceeded` | Too many API calls | Add delays, reduce parallelism |
| `Resource limit exceeded` | Account limits hit | Request limit increase via AWS Support |
| `Template format error` | Template > 1MB or invalid | Split into nested stacks, check template validity |

### Debugging Steps

```bash
# 1. Synthesize with verbose output
npx cdk synth --debug 2>&1 | tee synth-debug.log

# 2. Check synthesized template
cat cdk.out/MyStack.template.json | jq .

# 3. Validate template
aws cloudformation validate-template --template-body file://cdk.out/MyStack.template.json

# 4. Deploy with verbose CloudFormation events
npx cdk deploy --verbose MyStack

# 5. Check CloudFormation events for deploy failures
aws cloudformation describe-stack-events --stack-name MyStack \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || ResourceStatus=='UPDATE_FAILED']" \
  --output table

# 6. Check CloudTrail for permission issues
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateFunction \
  --max-results 5
```

### Common Misdiagnosis

**"cdk diff shows no changes but deploy fails"**
- Diff compares templates; deploy creates real resources. A resource might conflict at creation time.
- Check CloudFormation events, not just the CDK output.

**"synth works locally but fails in CI"**
- Different Node.js version, missing Docker, or missing AWS credentials for context lookups.
- Commit `cdk.context.json` to avoid lookup issues in CI.

**"deploy succeeds but app doesn't work"**
- CDK deployed the infrastructure correctly, but application code (Lambda handler, container) has bugs.
- Check CloudWatch Logs, not CloudFormation events.
