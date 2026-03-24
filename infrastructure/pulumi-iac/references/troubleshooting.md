# Pulumi Troubleshooting Guide

> Comprehensive reference for diagnosing and resolving common Pulumi infrastructure-as-code issues.

---

## Table of Contents

1. [State Conflicts and Repair](#1-state-conflicts-and-repair)
2. [Import Failures and Drift Detection](#2-import-failures-and-drift-detection)
3. [Dependency Cycles](#3-dependency-cycles)
4. [Preview vs Up Discrepancies](#4-preview-vs-up-discrepancies)
5. [Secret Decryption Errors](#5-secret-decryption-errors)
6. [Provider Version Conflicts](#6-provider-version-conflicts)
7. [Stack Reference Circular Dependencies](#7-stack-reference-circular-dependencies)
8. [Resource Replacement vs Update Decisions](#8-resource-replacement-vs-update-decisions)
9. [Plugin Installation Failures](#9-plugin-installation-failures)
10. [Performance with Large Stacks (500+ Resources)](#10-performance-with-large-stacks-500-resources)

---

## 1. State Conflicts and Repair

### Locked State Files

```
error: the stack is currently locked by 1 lock(s).
       reason: update; name: user@host; created: 2024-01-15 10:30:00
```

**Cause:** A previous `pulumi up` or `pulumi destroy` was interrupted and the lock was not released.

**Resolution:**

```bash
# Cancel the pending operation to release the lock
pulumi cancel

# If cancel fails, force-unlock via export/import cycle
pulumi stack export | pulumi stack import
```

**Prevention:** Avoid terminating Pulumi commands mid-execution. In CI/CD, set generous timeouts and use `pulumi cancel` in cleanup steps.

### Concurrent Modification Errors

```
error: [409] Conflict: Another update is already in progress.
```

**Cause:** Two users or CI pipelines are running `pulumi up` on the same stack simultaneously.

**Resolution:** Wait for the other operation to finish, or run `pulumi cancel` if it is stale. Use CI/CD concurrency groups to serialize deployments per stack.

### Removing Orphaned Resources from State

```
error: resource 'urn:pulumi:prod::myproject::aws:s3/bucket:Bucket::my-bucket' does not exist
```

**Cause:** A resource was deleted outside Pulumi but its record remains in state.

```bash
pulumi stack --show-urns
pulumi state unprotect 'urn:pulumi:prod::myproject::aws:s3/bucket:Bucket::my-bucket'
pulumi state delete 'urn:pulumi:prod::myproject::aws:s3/bucket:Bucket::my-bucket'
```

### Recovering from Corrupt State

```
error: could not deserialize deployment: invalid character '}' looking for beginning of value
```

**Cause:** The state file was manually edited incorrectly or storage corruption occurred.

```bash
pulumi stack export --file state-backup.json
# Fix the JSON, then re-import
jq '.' state-backup.json > state-fixed.json
pulumi stack import --file state-fixed.json
```

For severe corruption, restore a previous version:

```bash
pulumi stack export --version 42 --file state-v42.json
pulumi stack import --file state-v42.json
```

### Pending Operations Blocking Deployments

```
error: the current deployment has 2 resource(s) with pending operations:
  * creating urn:pulumi:dev::app::aws:ec2/instance:Instance::webserver
```

**Resolution:** Export state, clear the `"pending_operations"` array, re-import, then run `pulumi refresh` to reconcile.

---

## 2. Import Failures and Drift Detection

### Resource Not Found During Import

```
error: resource 'my-existing-vpc' does not exist
  importing aws:ec2/vpc:Vpc (id: vpc-abc123def)
```

**Cause:** Wrong resource ID, wrong region, or misconfigured provider.

**Resolution:**

1. Verify the resource exists: `aws ec2 describe-vpcs --vpc-ids vpc-abc123def`
2. Ensure the provider region matches: `pulumi config set aws:region us-east-1`
3. Use the correct import ID format for the resource type.

### Property Mismatch on Import

```
error: inputs to import do not match the existing resource
  property "cidrBlock": value "10.0.0.0/16" does not match "10.1.0.0/16"
```

**Cause:** Your Pulumi code properties don't match the existing cloud resource.

**Resolution:** Query the real resource values and update your code to match exactly. After successful import, modify properties in subsequent `pulumi up` runs.

### Resolving Drift with `pulumi refresh`

```
warning: resource urn:pulumi:prod::app::aws:ec2/securityGroup:SecurityGroup::web-sg
         has drifted from its expected configuration
```

**Cause:** Someone modified the resource directly in the cloud console.

```bash
# Sync state with reality (does not change cloud resources)
pulumi refresh

# Then either update your code to match, or run pulumi up to enforce your code
pulumi up
```

**Prevention:** Run `pulumi refresh` in CI before every `pulumi up`. Restrict manual cloud console access for production.

### Bulk Import

```bash
pulumi import --file import.json --generate-code --out generated.ts
```

---

## 3. Dependency Cycles

### Cycle Detection Error

```
error: circular dependency detected:
  aws:ec2/securityGroup:SecurityGroup (sg-a) ->
  aws:ec2/securityGroupRule:SecurityGroupRule (rule-b) ->
  aws:ec2/securityGroup:SecurityGroup (sg-b) ->
  aws:ec2/securityGroupRule:SecurityGroupRule (rule-a) ->
  aws:ec2/securityGroup:SecurityGroup (sg-a)
```

**Cause:** Two or more resources reference each other's outputs, creating a loop.

**Resolution:** Break the cycle by using standalone rule resources:

```typescript
// BAD: Inline rules create a cycle
const sgA = new aws.ec2.SecurityGroup("sg-a", {
    ingress: [{ securityGroups: [sgB.id] }],
});

// GOOD: Standalone rules break the cycle
const sgA = new aws.ec2.SecurityGroup("sg-a", {});
const sgB = new aws.ec2.SecurityGroup("sg-b", {});
const ruleA = new aws.ec2.SecurityGroupRule("rule-a-from-b", {
    securityGroupId: sgA.id,
    sourceSecurityGroupId: sgB.id,
    type: "ingress", fromPort: 443, toPort: 443, protocol: "tcp",
});
```

### Misuse of `dependsOn`

```typescript
// BAD: Circular dependsOn
const a = new Resource("a", {}, { dependsOn: [b] });
const b = new Resource("b", {}, { dependsOn: [a] });

// GOOD: Implicit dependency via Output references
const a = new Resource("a", {});
const b = new Resource("b", { prop: a.output });
```

**Prevention:** Prefer implicit dependencies (passing Outputs) over explicit `dependsOn`. Only use `dependsOn` for side-effect ordering with no data dependency.

---

## 4. Preview vs Up Discrepancies

### Unknown Values at Preview Time

```
Previewing update (dev):
     Type                     Name            Plan       Info
 +   aws:ec2:Instance         web-server      create
     - publicIp:             "<computed>"
```

**Cause:** Some values are only known after resource creation. Logic depending on these values behaves differently during preview.

```typescript
// BAD: Conditional logic on computed values diverges in preview vs up
const dns = pulumi.all([instance.publicIp]).apply(([ip]) => {
    if (ip === undefined) return "fallback.example.com";
    return `${ip}.nip.io`;
});

// GOOD: Let apply handle unknown values naturally
const dns = instance.publicIp.apply(ip => `${ip}.nip.io`);
```

### Apply-Time Failures Not Caught in Preview

```
error: creating resource: InvalidParameterValue:
  The instance type 't2.micro' is not available in az us-east-1e
```

**Cause:** Cloud provider rejects the request due to constraints not checked during preview (capacity, quotas, AZ restrictions).

**Prevention:** Test in staging first. Use `pulumi preview --diff` for detailed comparison. Check cloud provider quotas before large deployments.

---

## 5. Secret Decryption Errors

### Wrong Passphrase

```
error: failed to decrypt config value: incorrect passphrase
  for key 'myproject:databasePassword'
```

**Resolution:**

```bash
export PULUMI_CONFIG_PASSPHRASE="your-correct-passphrase"
pulumi config get myproject:databasePassword
```

If the passphrase is lost, create a new stack and re-set all secret config values.

### KMS Key Access Denied

```
error: failed to decrypt: AccessDeniedException:
  User: arn:aws:iam::123456789012:user/deploy is not authorized
  to perform: kms:Decrypt on resource: arn:aws:kms:us-east-1:123456789012:key/abc-123
```

**Resolution:** Grant `kms:Encrypt`, `kms:Decrypt`, and `kms:GenerateDataKey` permissions to the IAM principal. Verify the key exists and is enabled.

### Migrating Between Secrets Providers

```bash
pulumi stack change-secrets-provider "awskms://alias/pulumi-secrets?region=us-east-1"
```

All secrets are automatically re-encrypted. Use team-accessible KMS keys rather than individual passphrases.

---

## 6. Provider Version Conflicts

### Plugin Version Mismatch

```
error: could not load plugin aws [v6.0.0]:
  no resource plugin 'aws-v6.0.0' found in the workspace
```

**Resolution:**

```bash
pulumi plugin install resource aws v6.0.0
```

### Managing Plugins

```bash
pulumi plugin ls                           # List installed plugins
pulumi plugin rm resource aws v5.40.0      # Remove a specific version
pulumi plugin install resource aws v6.0.0  # Install a specific version
pulumi plugin rm --all --yes               # Clear entire plugin cache
```

### Pinning Provider Versions

```json
{
    "dependencies": {
        "@pulumi/aws": "6.0.0",
        "@pulumi/pulumi": "3.100.0"
    }
}
```

### Breaking Changes After Upgrade

```
error: "acl": [DEPRECATED] Use aws.s3.BucketAclV2 instead
```

**Resolution:** Read the provider changelog. Preview changes with `pulumi preview --diff`. Deploy incrementally with `pulumi up --target <URN>`. Test upgrades in dev before production.

---

## 7. Stack Reference Circular Dependencies

### Detecting Circular Stack References

```
error: getting stack reference outputs: stack 'org/network/prod'
  has circular references with the current stack
```

**Cause:** Stack A references outputs from Stack B, and Stack B references outputs from Stack A.

**Resolution:** Ensure the stack dependency graph is acyclic. Extract shared data into a base stack:

```typescript
// base/index.ts — no stack references, only exports
export const vpcId = vpc.id;

// network/index.ts — reads from base only
const baseStack = new pulumi.StackReference("org/base/prod");

// compute/index.ts — reads from base and network, never circular
const networkStack = new pulumi.StackReference("org/network/prod");
```

**Guidelines:** Stacks should form layers: base → network → compute → application. Data flows downward only.

---

## 8. Resource Replacement vs Update Decisions

### Unintended Resource Replacement

```
Previewing update (prod):
 +-  aws:rds:Instance         prod-db       replace     [diff: ~identifier]
```

**Cause:** A property change triggers `forceNew` in the provider. Common triggers: RDS `identifier`, EC2 `ami`, S3 `bucket` name.

**Resolution:** Use `pulumi preview --diff` to see what triggers replacement. Revert the property if unintended, or plan data migration if necessary.

### Protecting Critical Resources

```typescript
// Prevent accidental deletion
const db = new aws.rds.Instance("prod-db", { /* ... */ }, {
    protect: true,
});

// Retain cloud resource even if removed from code
const bucket = new aws.s3.Bucket("data-lake", { /* ... */ }, {
    retainOnDelete: true,
});
```

To remove a protected resource intentionally:

```bash
pulumi state unprotect '<URN>'
pulumi up
```

### Aliases for Safe Renames

```typescript
const server = new aws.ec2.Instance("app-server", { /* ... */ }, {
    aliases: [{ name: "web-server" }],  // Old name — prevents replacement
});
```

---

## 9. Plugin Installation Failures

### Network Connectivity Issues

```
error: failed to download plugin: aws-6.0.0:
  dial tcp: lookup api.pulumi.com: no such host
```

**Resolution:**

```bash
export HTTPS_PROXY=http://proxy.corp.example.com:8080
pulumi plugin install resource aws v6.0.0
```

### Manual Plugin Installation (Air-Gapped Environments)

```bash
# On a machine with internet
curl -L -o pulumi-resource-aws-v6.0.0-linux-amd64.tar.gz \
  https://api.pulumi.com/releases/plugins/pulumi-resource-aws-v6.0.0-linux-amd64.tar.gz

# Transfer and install on the target machine
pulumi plugin install resource aws v6.0.0 \
  --file pulumi-resource-aws-v6.0.0-linux-amd64.tar.gz
```

### Checksum Verification Failures

```
error: plugin checksum mismatch: expected sha256:abc123..., got sha256:def456...
```

**Cause:** Corrupted download or network appliance modified the binary.

**Resolution:** Clear the cached plugin with `pulumi plugin rm`, then retry. For persistent issues, download manually and verify the checksum.

**Prevention:** Cache plugins in an internal artifact repository. Include them in CI/CD Docker images.

---

## 10. Performance with Large Stacks (500+ Resources)

### Slow Previews and Deployments

**Cause:** Large state files, excessive provider API calls, and serial dependency chains.

```bash
# Increase parallelism (default is 10)
pulumi up --parallel 50

# Target specific resources
pulumi up --target '<URN>'

# Selective refresh
pulumi refresh --target '<URN>'
```

### State File Size

```bash
# Check state size
pulumi stack export | wc -c

# Clean up deleted resources
pulumi refresh --yes

# Audit resource count
pulumi stack --show-urns | wc -l
```

### Splitting Large Stacks

When a stack exceeds 500 resources, split into layers:

```
my-app-network/    (~50 resources: VPC, subnets, NAT gateways)
my-app-data/       (~80 resources: RDS, ElastiCache, S3)
my-app-compute/    (~200 resources: ECS, ALB, auto-scaling)
my-app-cdn/        (~50 resources: CloudFront, WAF, Route53)
```

Connect with stack references:

```typescript
const networkStack = new pulumi.StackReference("org/my-app-network/prod");
const vpcId = networkStack.getOutput("vpcId");
```

### Targeted Operations

```bash
pulumi up --target-dependents --target '<URN>'
pulumi up --replace '<URN>'
```

**Prevention:** Monitor resource count and plan stack boundaries early. Set `--parallel` appropriately for your cloud provider's rate limits.

---

## Quick Reference

| Scenario | Command |
|---|---|
| Unlock stuck stack | `pulumi cancel` |
| Remove resource from state | `pulumi state delete <URN>` |
| Sync state with reality | `pulumi refresh` |
| View resource URNs | `pulumi stack --show-urns` |
| Export state for editing | `pulumi stack export --file state.json` |
| Import edited state | `pulumi stack import --file state.json` |
| List installed plugins | `pulumi plugin ls` |
| Install specific plugin | `pulumi plugin install resource <name> <ver>` |
| Deploy single resource | `pulumi up --target <URN>` |
| Increase parallelism | `pulumi up --parallel 50` |
| Change secrets provider | `pulumi stack change-secrets-provider <url>` |
