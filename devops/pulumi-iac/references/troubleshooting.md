# Pulumi Troubleshooting Guide

## Table of Contents
- [Dependency Cycles](#dependency-cycles)
- [State File Corruption](#state-file-corruption)
- [Import Failures](#import-failures)
- [Provider Version Conflicts](#provider-version-conflicts)
- [Secret Decryption Errors](#secret-decryption-errors)
- [Pending Operations](#pending-operations)
- [Refresh vs Up](#refresh-vs-up)
- [Replacing Resources Safely](#replacing-resources-safely)
- [Handling Cloud API Throttling](#handling-cloud-api-throttling)
- [Debugging with Verbose Logging](#debugging-with-verbose-logging)

---

## Dependency Cycles

### Symptom
```
error: circular dependency detected between resources
```

### Common Causes

1. **Security group self-reference**: SG allows ingress from itself.
2. **IAM role ↔ policy**: Role references policy ARN, policy references role name.
3. **DNS ↔ load balancer**: ALB needs cert, cert needs DNS validation on the ALB's domain.

### Solutions

**Break the cycle with explicit ordering:**
```typescript
// WRONG: Circular — SG references itself
const sg = new aws.ec2.SecurityGroup("sg", {
    ingress: [{ securityGroups: [sg.id] }],  // can't reference itself during creation
});

// CORRECT: Separate the self-referencing rule
const sg = new aws.ec2.SecurityGroup("sg", {});
const selfRule = new aws.ec2.SecurityGroupRule("self-ingress", {
    securityGroupId: sg.id,
    sourceSecurityGroupId: sg.id,
    type: "ingress",
    fromPort: 0,
    toPort: 65535,
    protocol: "tcp",
});
```

**Break IAM cycles:**
```typescript
const role = new aws.iam.Role("role", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{ Effect: "Allow", Principal: { Service: "lambda.amazonaws.com" }, Action: "sts:AssumeRole" }],
    }),
});
// Attach policy separately to avoid circular reference
const policyAttachment = new aws.iam.RolePolicyAttachment("attach", {
    role: role.name,
    policyArn: policy.arn,
});
```

### Diagnosis
```bash
pulumi preview --verbose=9 2>&1 | grep -i "depend"
```

---

## State File Corruption

### Symptoms
- `error: could not deserialize deployment`
- Resources exist in cloud but not in state
- Duplicate resource URNs

### Recovery Steps

**1. Export the state:**
```bash
pulumi stack export > state-backup.json
```

**2. Inspect the state:**
```bash
# Find specific resources
cat state-backup.json | jq '.deployment.resources[] | select(.urn | contains("my-bucket"))'

# Count resources
cat state-backup.json | jq '.deployment.resources | length'
```

**3. Fix and re-import:**
```bash
# Edit state-backup.json (remove duplicates, fix URNs)
pulumi stack import < state-fixed.json
```

**4. For orphaned cloud resources, re-import:**
```bash
pulumi import aws:s3/bucket:Bucket my-bucket actual-bucket-name
```

### Prevention
- Use Pulumi Cloud or versioned S3 backends with locking
- Never run concurrent updates on the same stack
- Enable state locking: S3 backend uses DynamoDB by default

---

## Import Failures

### Common Errors

**Resource not found:**
```
error: Preview failed: importing <urn>: the resource was not found
```
Fix: Verify the resource ID is correct. For AWS, use the full resource identifier:
```bash
# EC2 instance — use instance ID
pulumi import aws:ec2/instance:Instance web i-0abc123def456
# S3 bucket — use bucket name (not ARN)
pulumi import aws:s3/bucket:Bucket data my-bucket-name
# IAM role — use role name (not ARN)
pulumi import aws:iam/role:Role app my-role-name
# RDS — use DB identifier
pulumi import aws:rds/instance:Instance db my-db-identifier
```

**Property mismatch after import:**
```
warning: inputs to import do not match the existing resource
```
Fix: After import, run `pulumi preview`. Adjust your code to match the actual cloud resource properties. Common mismatches: tags, encryption settings, lifecycle rules.

**Bulk import from file:**
```json
{
    "resources": [
        { "type": "aws:s3/bucket:Bucket", "name": "data", "id": "my-data-bucket" },
        { "type": "aws:ec2/instance:Instance", "name": "web", "id": "i-0abc123" }
    ]
}
```
```bash
pulumi import -f resources.json --out index.ts --generate-code
```

### Post-Import Checklist
1. Run `pulumi preview` — should show no changes
2. Remove `{ import: "..." }` from resource options
3. Run `pulumi preview` again — still no changes
4. Commit the code

---

## Provider Version Conflicts

### Symptoms
- `error: could not load plugin aws-6.x.x`
- Type errors after upgrading
- Missing properties on resources

### Diagnosis and Fix

```bash
# Check installed plugin versions
pulumi plugin ls

# Check what the project requires
cat package.json | grep @pulumi

# Remove old plugins
pulumi plugin rm resource aws 5.0.0

# Force install specific version
pulumi plugin install resource aws 6.52.0

# Pin provider version in package.json
npm install @pulumi/aws@6.52.0 --save-exact
```

### Version Pinning Strategy

```json
{
    "dependencies": {
        "@pulumi/pulumi": "3.130.0",
        "@pulumi/aws": "6.52.0",
        "@pulumi/awsx": "2.14.0"
    }
}
```

**Rule**: Pin exact versions in production. Use `npm ci` (not `npm install`) in CI/CD. Test upgrades in a dev stack first.

### Provider vs SDK Version

The Pulumi SDK (`@pulumi/pulumi`) and provider packages (`@pulumi/aws`) are independently versioned. They must be compatible:
- Check the provider changelog for minimum SDK requirements
- Upgrade SDK first, then providers

---

## Secret Decryption Errors

### Symptoms
```
error: failed to decrypt config value: incorrect passphrase
error: failed to load config: [secret] could not be decrypted
```

### Fixes by Secrets Provider

**Passphrase provider:**
```bash
# Set the passphrase environment variable
export PULUMI_CONFIG_PASSPHRASE="my-passphrase"
# Or for non-interactive (empty passphrase)
export PULUMI_CONFIG_PASSPHRASE=""
```

**Cloud KMS (AWS/Azure/GCP):**
```bash
# Verify KMS access
aws kms describe-key --key-id alias/pulumi
# Re-wrap secrets with new key
pulumi stack change-secrets-provider "awskms://alias/new-key"
```

**Pulumi Cloud:**
Secrets managed automatically. Ensure `PULUMI_ACCESS_TOKEN` is valid and the token has access to the org.

### Rotating Secrets
```bash
# Change the secrets provider for a stack
pulumi stack change-secrets-provider "awskms://alias/new-key"
# All secrets re-encrypted with new provider
```

### Copy Secrets Between Stacks
```bash
pulumi config cp --dest dev --path "app:dbPassword"
# Or copy all config:
pulumi stack export -s source | pulumi stack import -s dest
```

---

## Pending Operations

### Symptom
```
error: the current deployment has N pending operation(s):
  * creating urn:pulumi:dev::project::aws:s3/bucket:Bucket::my-bucket
```

This happens when a previous `pulumi up` was interrupted (Ctrl+C, timeout, crash).

### Fix

**Option 1 — Complete or cancel the operation:**
```bash
# Refresh to reconcile state with reality
pulumi refresh --yes

# If the resource was actually created, refresh picks it up
# If it wasn't, refresh removes the pending operation
```

**Option 2 — Manually clear pending operations:**
```bash
pulumi stack export > state.json
# Edit state.json: find and remove the "pending_operations" array
# "pending_operations": []  ← set to empty
pulumi stack import < state.json
```

**Option 3 — Cancel the update (if stack is locked):**
```bash
pulumi cancel
```

### Prevention
- Don't Ctrl+C during `pulumi up` — if you must cancel, use `pulumi cancel` in another terminal
- Set `PULUMI_SKIP_CONFIRMATIONS=true` for non-interactive CI
- Use `--yes` flag to skip prompts in automated pipelines

---

## Refresh vs Up

### `pulumi refresh`
Reads actual cloud state and updates the Pulumi state file to match reality. **Does NOT modify cloud resources.**

```bash
pulumi refresh                    # interactive — shows diff, asks for confirmation
pulumi refresh --yes              # non-interactive
pulumi refresh --diff             # show detailed diff
pulumi refresh -t urn:...         # refresh specific resource
```

Use when:
- Someone modified resources outside Pulumi (console, CLI)
- State file is stale or suspect
- Before importing resources to verify current state

### `pulumi up`
Reads desired state from code, computes diff against state file, and applies changes to cloud resources.

```bash
pulumi up                         # interactive
pulumi up --yes                   # non-interactive
pulumi up --refresh               # refresh state first, then apply
pulumi up -t urn:...              # target specific resource
pulumi up --replace urn:...       # force replacement
```

### `pulumi preview`
Same diffing as `up` but without applying. Use in CI for PRs:
```bash
pulumi preview --diff             # detailed property-level diff
pulumi preview --json             # machine-readable output
pulumi preview --expect-no-changes  # fail if any changes detected (drift check)
```

### Decision Tree
1. "Cloud resources were changed manually" → `pulumi refresh`
2. "I changed my code, deploy it" → `pulumi up`
3. "Is my state accurate?" → `pulumi refresh --diff` (review, don't apply)
4. "What would my code changes do?" → `pulumi preview --diff`

---

## Replacing Resources Safely

### When Replacement Happens
Some property changes force resource replacement (delete old + create new). Examples:
- Changing an EC2 instance AMI
- Changing an RDS instance engine
- Changing a Lambda function name

### Force Delete-Before-Replace
```typescript
const instance = new aws.ec2.Instance("web", { ... }, {
    deleteBeforeReplace: true,
});
```

**Default behavior**: create-before-delete (less downtime but may hit naming conflicts).
**deleteBeforeReplace**: delete first, then create (brief downtime but avoids conflicts).

### Targeted Replacement
```bash
# Replace a specific resource
pulumi up --replace "urn:pulumi:dev::project::aws:ec2/instance:Instance::web"

# Preview first
pulumi preview --replace "urn:pulumi:dev::project::aws:ec2/instance:Instance::web"

# Find the URN
pulumi stack --show-urns
```

### Zero-Downtime Replacement Strategy

1. Create new resource with a temporary name
2. Update dependent resources to point to new resource
3. Remove old resource from code
4. Run `pulumi up`
5. Rename new resource to final name and add alias

---

## Handling Cloud API Throttling

### Symptoms
- `error: operation timed out`
- `error: Rate exceeded` / `ThrottlingException`
- Sporadic failures in large stacks

### Solutions

**Limit parallelism:**
```bash
# Reduce concurrent operations (default is 10)
pulumi up --parallel 4
pulumi up --parallel 1    # fully serial — slowest but safest
```

**Add retry logic in dynamic providers:**
```typescript
async function withRetry<T>(fn: () => Promise<T>, retries = 3, delay = 1000): Promise<T> {
    for (let i = 0; i < retries; i++) {
        try { return await fn(); }
        catch (e: any) {
            if (i === retries - 1) throw e;
            if (e.code === "ThrottlingException" || e.code === "TooManyRequestsException") {
                await new Promise(r => setTimeout(r, delay * Math.pow(2, i)));
            } else throw e;
        }
    }
    throw new Error("unreachable");
}
```

**Use explicit dependencies to serialize resource creation:**
```typescript
const resources: aws.ec2.Instance[] = [];
for (let i = 0; i < 50; i++) {
    resources.push(new aws.ec2.Instance(`web-${i}`, { ... }, {
        dependsOn: i > 0 ? [resources[i-1]] : [],
    }));
}
```

**AWS-specific**: Configure the provider with custom retry settings:
```typescript
const provider = new aws.Provider("custom", {
    maxRetries: 10,
    region: "us-west-2",
});
```

---

## Debugging with Verbose Logging

### Verbosity Levels

```bash
# Basic verbose output
pulumi up --verbose=3

# Maximum verbosity — shows gRPC calls, plugin communication
pulumi up --verbose=9

# Log to stderr (useful with JSON output)
pulumi up --logtostderr --verbose=5

# Log to file
pulumi up --logflow --logtostderr 2> pulumi-debug.log

# Debug specific resource
pulumi up -t "urn:pulumi:dev::proj::aws:s3/bucket:Bucket::my-bucket" --verbose=9
```

### Environment Variables for Debugging

```bash
# Show full gRPC messages
export PULUMI_DEBUG_GRPC=grpc.log

# Trace Pulumi engine operations
export PULUMI_TRACING_TAG_MAP="component=engine"

# Show all config resolution
export PULUMI_CONFIG_PASSPHRASE_FILE=/dev/null  # (when not using passphrase)
```

### Common Debug Workflows

**"Why is this resource being replaced?"**
```bash
pulumi preview --diff --verbose=5 2>&1 | grep -A 10 "replace"
```

**"What API calls is Pulumi making?"**
```bash
# AWS: enable SDK debug logging
export AWS_SDK_LOAD_CONFIG=true
export AWS_DEBUG=true
pulumi up --verbose=9 --logtostderr 2> debug.log
```

**"Which dependency is causing this ordering?"**
```bash
pulumi preview --verbose=9 2>&1 | grep "depends on"
```

**"Show me the full state of a resource:"**
```bash
pulumi stack export | jq '.deployment.resources[] | select(.urn | contains("my-resource"))'
```

### Tracing with Pulumi Cloud
If using Pulumi Cloud, every update is recorded with full logs, diffs, and resource timelines in the web console. Use `pulumi console` to open the current stack's dashboard.
