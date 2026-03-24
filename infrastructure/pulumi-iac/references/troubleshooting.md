# Pulumi IaC Troubleshooting Reference

> Dense, actionable reference for diagnosing and resolving Pulumi failures. Every section includes real error messages, exact CLI commands, and root-cause analysis. Intended to be searched, not read end-to-end.

---

## Table of Contents

1. [State Management Issues](#1-state-management-issues)
   - [Locked State Files](#11-locked-state-files)
   - [Concurrent Modification Errors](#12-concurrent-modification-errors)
   - [Orphaned Resources](#13-orphaned-resources)
   - [State Version History and Rollback](#14-state-version-history-and-rollback)
   - [State File Format and Structure](#15-state-file-format-and-structure)
   - [Export/Import Workflow](#16-exportimport-workflow)
   - [`pulumi state` Subcommands Reference](#17-pulumi-state-subcommands-reference)
2. [Drift Detection and Reconciliation](#2-drift-detection-and-reconciliation)
   - [`pulumi refresh` Mechanics](#21-pulumi-refresh-mechanics)
   - [`--expect-no-changes` in CI](#22---expect-no-changes-in-ci)
   - [Automated Drift Detection Pipelines](#23-automated-drift-detection-pipelines)
   - [Reconciling Manual Changes](#24-reconciling-manual-changes)
   - [Partial Refresh with `--target`](#25-partial-refresh-with---target)
3. [Import Failures](#3-import-failures)
   - [Wrong Resource ID Formats by Provider](#31-wrong-resource-id-formats-by-provider)
   - [Property Mismatches and Debugging](#32-property-mismatches-and-debugging)
   - [Bulk Import from JSON](#33-bulk-import-from-json)
   - [`--generate-code` Workflow](#34---generate-code-workflow)
   - [Common Import Pitfalls per Provider](#35-common-import-pitfalls-per-provider)
4. [Provider Version Conflicts](#4-provider-version-conflicts)
   - [Plugin Cache and Resolution](#41-plugin-cache-and-resolution)
   - [Pinning Versions](#42-pinning-versions)
   - [Breaking Changes Across Major Versions](#43-breaking-changes-across-major-versions)
   - [Multi-Provider Version Coexistence](#44-multi-provider-version-coexistence)
   - [`pluginDownloadURL` for Custom Providers](#45-plugindownloadurl-for-custom-providers)
5. [Dependency Resolution](#5-dependency-resolution)
   - [Circular Dependency Errors](#51-circular-dependency-errors)
   - [Implicit vs Explicit Dependencies](#52-implicit-vs-explicit-dependencies)
   - [`dependsOn` Misuse Patterns](#53-dependson-misuse-patterns)
   - [Delete Ordering and `deletedWith`](#54-delete-ordering-and-deletedwith)
6. [Pending Operations](#6-pending-operations)
   - [`--clear-pending-creates`](#61---clear-pending-creates)
   - [`--import-pending-creates`](#62---import-pending-creates)
   - [Manual State Surgery with `jq`](#63-manual-state-surgery-with-jq)
   - [Diagnosing Partial Creates](#64-diagnosing-partial-creates)
7. [Stack Corruption Recovery](#7-stack-corruption-recovery)
   - [Corrupt JSON State](#71-corrupt-json-state)
   - [Missing Resources in State](#72-missing-resources-in-state)
   - [Version Rollback (`--version N`)](#73-version-rollback---version-n)
   - [State Backup Strategies](#74-state-backup-strategies)
   - [Migrating Between Backends](#75-migrating-between-backends)
8. [Common Error Messages Reference](#8-common-error-messages-reference)
9. [Performance Optimization](#9-performance-optimization)
   - [Large Stacks (500+ Resources)](#91-large-stacks-500-resources)
   - [Parallelism Tuning](#92-parallelism-tuning)
   - [Targeted Operations](#93-targeted-operations)
   - [State File Size Reduction](#94-state-file-size-reduction)
   - [Splitting Stacks](#95-splitting-stacks)
10. [Secrets and Encryption](#10-secrets-and-encryption)
    - [Wrong Passphrase Recovery](#101-wrong-passphrase-recovery)
    - [KMS Issues](#102-kms-issues)
    - [Migrating Secrets Providers](#103-migrating-secrets-providers)
    - [Secret Propagation Debugging](#104-secret-propagation-debugging)
11. [Quick Reference Tables](#11-quick-reference-tables)

---

## 1. State Management Issues

### 1.1 Locked State Files

```
error: the stack is currently locked by 1 lock(s).
       reason: update; name: user@host; created: 2024-01-15 10:30:00
```

**Root cause:** A `pulumi up`, `pulumi destroy`, or `pulumi refresh` was interrupted (Ctrl-C, CI timeout, OOM kill, network drop) and the lock was not released. Pulumi Cloud and S3 backends both use lease-based locking.

**Resolution sequence:**

```bash
# Step 1: Try graceful cancel (works if the Pulumi process is still running somewhere)
pulumi cancel

# Step 2: If cancel fails with "no update in progress", force-release via export/import
pulumi stack export | pulumi stack import

# Step 3: For S3 backend, locks are stored as .pulumi/locks/<stack>/<lock-id>.json
# List locks:
aws s3 ls s3://my-state-bucket/.pulumi/locks/my-stack/
# Delete the stale lock:
aws s3 rm s3://my-state-bucket/.pulumi/locks/my-stack/<lock-id>.json
```

**For Pulumi Cloud backend**, `pulumi cancel` is the only option. If it fails, contact Pulumi support or wait for the 10-minute lock timeout.

**CI/CD prevention pattern (GitHub Actions):**

```yaml
jobs:
  deploy:
    concurrency:
      group: pulumi-${{ github.ref }}-${{ matrix.stack }}
      cancel-in-progress: false
    steps:
      - run: pulumi cancel --yes --stack ${{ matrix.stack }} || true
        if: always()
        name: Release stale lock
```

### 1.2 Concurrent Modification Errors

```
error: [409] Conflict: Another update is already in progress.
```

**Root cause:** Two processes target the same stack simultaneously. Common triggers: duplicate CI jobs, developer running `pulumi up` while CI is deploying, parallel GitHub Actions runs without concurrency groups.

**Resolution:**

```bash
# Check who holds the lock (Pulumi Cloud)
pulumi stack --show-name
pulumi cancel  # Cancels the other operation

# For S3 backends, inspect the lock file
aws s3 cp s3://my-state-bucket/.pulumi/locks/org/project/stack/<id>.json - | jq .
```

**Prevention:** Serialize all operations per stack. Never parallelize `pulumi up` across the same stack. Parallelize across different stacks only.

### 1.3 Orphaned Resources

Orphaned resources exist in two directions:

**Direction 1: Resource exists in state but not in cloud** (deleted out-of-band).

```
error: deleting urn:pulumi:prod::app::aws:s3/bucket:Bucket::old-bucket:
  NoSuchBucket: The specified bucket does not exist
```

```bash
# Remove from state without attempting cloud deletion
pulumi state delete 'urn:pulumi:prod::app::aws:s3/bucket:Bucket::old-bucket'
```

**Direction 2: Resource exists in cloud but not in state** (created out-of-band, or lost during state corruption).

```bash
# Re-import the resource into state
pulumi import aws:s3/bucket:Bucket old-bucket my-actual-bucket-name

# Or run refresh to detect all drift — but this only updates known resources,
# it won't discover resources that were never in state
pulumi refresh
```

**Bulk orphan cleanup:**

```bash
# List all URNs in state
pulumi stack export | jq -r '.deployment.resources[].urn'

# Find resources that will error on refresh (they no longer exist)
pulumi refresh --yes 2>&1 | grep -E "error:|warning:" | tee orphan-candidates.txt

# Delete each orphan from state
while IFS= read -r urn; do
  pulumi state delete "$urn" --yes
done < orphan-urns.txt
```

### 1.4 State Version History and Rollback

Pulumi Cloud and self-managed backends both support state versioning (Pulumi Cloud stores every version; S3 requires bucket versioning enabled).

```bash
# List recent state versions (Pulumi Cloud)
pulumi stack history

# Export a specific historical version
pulumi stack export --version 42 --file state-v42.json

# Inspect what changed between versions
diff <(pulumi stack export --version 41 | jq '.deployment.resources | length') \
     <(pulumi stack export --version 42 | jq '.deployment.resources | length')

# Roll back to a previous version (DANGER: does not change cloud resources)
pulumi stack export --version 42 --file state-v42.json
pulumi stack import --file state-v42.json

# After rollback, ALWAYS refresh to reconcile state with reality
pulumi refresh --yes
```

**Warning:** Rolling back state does not undo cloud changes. If version 43 created an EC2 instance, rolling back to version 42 removes the instance from state — the instance still exists in AWS. Always `pulumi refresh` after a rollback.

### 1.5 State File Format and Structure

The state file is a JSON document with this structure:

```json
{
  "version": 3,
  "deployment": {
    "manifest": {
      "time": "2024-01-15T10:30:00.000Z",
      "magic": "...",
      "version": "v3.100.0"
    },
    "secrets_providers": { "type": "passphrase", "state": { "salt": "..." } },
    "resources": [
      {
        "urn": "urn:pulumi:dev::myproject::pulumi:pulumi:Stack::myproject-dev",
        "custom": false,
        "type": "pulumi:pulumi:Stack"
      },
      {
        "urn": "urn:pulumi:dev::myproject::aws:s3/bucket:Bucket::my-bucket",
        "custom": true,
        "id": "my-actual-bucket-name",
        "type": "aws:s3/bucket:Bucket",
        "inputs": { "bucket": "my-actual-bucket-name", "acl": "private" },
        "outputs": { "arn": "arn:aws:s3:::my-actual-bucket-name", "bucket": "my-actual-bucket-name" },
        "parent": "urn:pulumi:dev::myproject::pulumi:pulumi:Stack::myproject-dev",
        "protect": false,
        "dependencies": [],
        "provider": "urn:pulumi:dev::myproject::pulumi:providers:aws::default_6_0_0::a1b2c3d4"
      }
    ],
    "pending_operations": []
  }
}
```

Key fields for manual surgery:
- `resources[].urn` — Unique resource name, format: `urn:pulumi:<stack>::<project>::<type>::<name>`
- `resources[].id` — Cloud provider ID (e.g., `i-0abc123def`, `vpc-456`)
- `resources[].inputs` — What Pulumi sent to the provider
- `resources[].outputs` — What the provider returned
- `resources[].protect` — If `true`, resource cannot be deleted
- `resources[].dependencies` — URN array of resources this depends on
- `pending_operations` — Array of in-flight operations (see §6)

### 1.6 Export/Import Workflow

The export/import cycle is the escape hatch for almost all state issues.

```bash
# Export current state
pulumi stack export --file state.json

# Validate the JSON
python3 -c "import json; json.load(open('state.json'))" && echo "Valid JSON"

# Make edits (e.g., remove a resource, fix a URN, clear pending ops)
# Use jq for surgical edits — see §6.3 for examples

# Import modified state
pulumi stack import --file state.json

# ALWAYS refresh after import to reconcile
pulumi refresh --yes
```

**Common export/import use cases:**
- Clearing pending operations (§6)
- Removing orphaned resources that `pulumi state delete` cannot handle
- Fixing corrupt provider references
- Moving resources between stacks (combine with `pulumi state move`)
- Bulk unprotecting resources

### 1.7 `pulumi state` Subcommands Reference

```bash
# ── Inspect ──
pulumi stack --show-urns                 # List all resource URNs
pulumi stack --show-urns | grep "Instance"  # Filter by type

# ── Move resources between stacks ──
# Move a resource from the current stack to another stack
pulumi state move --source dev --dest staging \
  'urn:pulumi:dev::app::aws:ec2/instance:Instance::webserver'

# ── Rename a resource (change its logical name in state) ──
pulumi state rename \
  'urn:pulumi:dev::app::aws:s3/bucket:Bucket::old-name' \
  'urn:pulumi:dev::app::aws:s3/bucket:Bucket::new-name'

# ── Unprotect (remove the protect flag so the resource can be deleted) ──
pulumi state unprotect 'urn:pulumi:prod::app::aws:rds/instance:Instance::prod-db'

# ── Delete from state (does NOT delete the cloud resource) ──
pulumi state delete 'urn:pulumi:dev::app::aws:ec2/instance:Instance::old-server'

# Force delete even if other resources depend on this one
pulumi state delete --force 'urn:pulumi:dev::app::aws:ec2/instance:Instance::old-server'

# ── Upgrade state format ──
pulumi state upgrade  # Upgrades to latest state format version
```

**Danger zone:** `pulumi state delete --force` removes a resource even if dependents exist. Those dependents will have dangling dependency references. Always `pulumi refresh` afterward.

---

## 2. Drift Detection and Reconciliation

### 2.1 `pulumi refresh` Mechanics

`pulumi refresh` reads the actual state of every resource from the cloud provider and updates the Pulumi state file to match reality. It does **not** modify cloud resources — it only modifies state.

```bash
# Interactive refresh — shows diff, asks for confirmation
pulumi refresh

# Non-interactive (CI/CD)
pulumi refresh --yes

# Refresh and show detailed property-level diff
pulumi refresh --diff
```

**What refresh does:**
1. Reads every resource's current cloud state via the provider's `Read` gRPC call
2. Compares cloud state to stored state
3. Updates `inputs` and `outputs` in state to match cloud reality
4. Reports resources that were modified, deleted, or unchanged

**What refresh does NOT do:**
- Does not modify cloud resources
- Does not discover resources that were never in state
- Does not update your Pulumi program source code

**Common refresh output:**

```
     Type                        Name           Status       Info
     pulumi:pulumi:Stack         myproject-dev
 ~   aws:ec2/instance:Instance   webserver      updated      [diff: ~instanceType,~tags]
 -   aws:s3/bucket:Bucket        temp-bucket    deleted      [resource deleted externally]
```

### 2.2 `--expect-no-changes` in CI

Use `--expect-no-changes` as a drift detection gate. If any resource has drifted, the command exits with a non-zero code.

```bash
# Fails if ANY resource has drifted from state
pulumi refresh --expect-no-changes --yes

# Exit code 0 = no drift, non-zero = drift detected
```

```
error: BAIL: --expect-no-changes was specified and changes were detected:
  ~ aws:ec2/instance:Instance (webserver) updated [diff: ~tags]
```

**GitHub Actions drift detection job:**

```yaml
name: Drift Detection
on:
  schedule:
    - cron: '0 6 * * *'  # Daily at 6 AM
jobs:
  detect-drift:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        stack: [dev, staging, prod]
    steps:
      - uses: actions/checkout@v4
      - uses: pulumi/actions@v5
        with:
          command: refresh
          stack-name: org/myproject/${{ matrix.stack }}
          expect-no-changes: true
        env:
          PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
      - name: Alert on drift
        if: failure()
        run: |
          curl -X POST "$SLACK_WEBHOOK" \
            -d '{"text":"⚠️ Drift detected in stack ${{ matrix.stack }}"}'
```

### 2.3 Automated Drift Detection Pipelines

**Full pipeline pattern:** detect → report → optionally auto-remediate.

```bash
#!/usr/bin/env bash
set -euo pipefail

STACK="$1"
pulumi stack select "$STACK"

# Capture refresh output
if pulumi refresh --expect-no-changes --yes --diff 2>&1 | tee /tmp/drift-output.txt; then
  echo "No drift detected in $STACK"
  exit 0
fi

# Drift detected — extract changed resources
grep -E "^\s+[~+-]" /tmp/drift-output.txt > /tmp/drifted-resources.txt

# Option A: Accept drift (update state to match reality)
pulumi refresh --yes

# Option B: Reject drift (revert cloud to match code)
# pulumi up --yes

# Option C: Alert and do nothing (manual review required)
# exit 1
```

### 2.4 Reconciling Manual Changes

When someone modifies a resource in the AWS/Azure/GCP console:

**Scenario 1: Keep the manual change** (update your code to match):

```bash
# Step 1: Refresh to update state
pulumi refresh --yes

# Step 2: Run preview to see what Pulumi would change back
pulumi preview --diff

# Step 3: Update your source code to match the manual change
# Step 4: Verify preview shows no changes
pulumi preview --expect-no-changes
```

**Scenario 2: Revert the manual change** (enforce your code):

```bash
# Step 1: Do NOT refresh (state still has your intended values)
# Step 2: Run up to push your code's values to the cloud
pulumi up --yes
```

**Scenario 3: Mixed — keep some changes, revert others:**

```bash
# Step 1: Refresh only the resources whose manual changes you want to keep
pulumi refresh --target 'urn:pulumi:prod::app::aws:ec2/instance:Instance::webserver' --yes

# Step 2: Update code for those resources
# Step 3: Run up to enforce code on everything else
pulumi up --yes
```

### 2.5 Partial Refresh with `--target`

Full refreshes on large stacks are slow (every resource makes an API call). Target specific resources:

```bash
# Refresh a single resource
pulumi refresh --target 'urn:pulumi:prod::app::aws:rds/instance:Instance::prod-db' --yes

# Refresh multiple resources
pulumi refresh \
  --target 'urn:pulumi:prod::app::aws:ec2/instance:Instance::web-1' \
  --target 'urn:pulumi:prod::app::aws:ec2/instance:Instance::web-2' \
  --yes

# Refresh by type (via shell expansion)
for urn in $(pulumi stack --show-urns | grep "aws:ec2/instance:Instance"); do
  pulumi refresh --target "$urn" --yes
done
```

**When to use targeted refresh:**
- Debugging a single resource that may have drifted
- Large stacks where full refresh takes >5 minutes
- When you know exactly which resource was modified manually
- CI pipelines that need fast feedback

---

## 3. Import Failures

### 3.1 Wrong Resource ID Formats by Provider

Every provider has different ID format expectations. Using the wrong format is the #1 cause of import failures.

**AWS — most resources use the cloud-assigned ID:**

```bash
# EC2 Instance — use the instance ID
pulumi import aws:ec2/instance:Instance myvm i-0abc123def456789a

# S3 Bucket — use the bucket NAME (not ARN)
pulumi import aws:s3/bucket:Bucket mybucket my-actual-bucket-name

# IAM Role — use the role NAME (not ARN)
pulumi import aws:iam/role:Role myrole MyRoleName

# Security Group — use the security group ID
pulumi import aws:ec2/securityGroup:SecurityGroup mysg sg-0abc123def456789a

# VPC Subnet — use the subnet ID
pulumi import aws:ec2/subnet:Subnet mysub subnet-0abc123def456789a

# RDS Instance — use the DB identifier (name), not the ARN
pulumi import aws:rds/instance:Instance mydb my-database-identifier

# Lambda Function — use the function NAME
pulumi import aws:lambda/function:Function myfn my-function-name

# Route53 Record — use ZONEID_NAME_TYPE format
pulumi import aws:route53/record:Record myrec Z123456_example.com_A

# IAM Policy Attachment — use ARN/role-name format
pulumi import aws:iam/rolePolicyAttachment:RolePolicyAttachment attach \
  MyRoleName/arn:aws:iam::aws:policy/ReadOnlyAccess
```

**Azure — most resources use the full Azure resource ID:**

```bash
# Resource Group
pulumi import azure-native:resources:ResourceGroup myrg \
  /subscriptions/SUB_ID/resourceGroups/my-rg

# Storage Account
pulumi import azure-native:storage:StorageAccount mysa \
  /subscriptions/SUB_ID/resourceGroups/my-rg/providers/Microsoft.Storage/storageAccounts/mystorageacct

# Virtual Network
pulumi import azure-native:network:VirtualNetwork myvnet \
  /subscriptions/SUB_ID/resourceGroups/my-rg/providers/Microsoft.Network/virtualNetworks/my-vnet

# IMPORTANT: Azure resource IDs are case-sensitive in some providers
# The azure-native provider requires exact API casing
# The classic azure provider is more lenient
```

**GCP — resources use the self-link or `projects/PROJECT/...` format:**

```bash
# Compute Instance — projects/PROJECT/zones/ZONE/instances/NAME
pulumi import gcp:compute/instance:Instance myvm \
  projects/my-project/zones/us-central1-a/instances/my-vm

# GCS Bucket — just the bucket name
pulumi import gcp:storage/bucket:Bucket mybucket my-bucket-name

# GKE Cluster — projects/PROJECT/locations/LOCATION/clusters/NAME
pulumi import gcp:container/cluster:Cluster mycluster \
  projects/my-project/locations/us-central1/clusters/my-cluster

# IAM Member — use the ID format from `gcloud` output or Terraform docs
# Format varies significantly per resource
```

**To find the correct ID format:** check the provider's Terraform registry docs (Pulumi providers are built on Terraform providers). Look for the "Import" section at the bottom of each resource page.

### 3.2 Property Mismatches and Debugging

```
error: inputs to import do not match the existing resource;
  the following properties differed:
  property "cidrBlock": value "10.0.0.0/16" does not match "10.1.0.0/16"
  property "enableDnsHostnames": value "false" does not match "true"
```

**Root cause:** Your Pulumi code specifies properties that differ from the actual cloud resource.

**Debugging workflow:**

```bash
# Step 1: Query the real resource from the cloud
aws ec2 describe-vpcs --vpc-ids vpc-abc123 | jq '.Vpcs[0]'

# Step 2: Compare with your code's inputs
# Step 3: Update your code to match EXACTLY, then retry import

# Step 4: After successful import, change properties in a subsequent `pulumi up`
```

**Common mismatch traps:**
- **Default values:** Your code omits a field, but the cloud resource has a non-default value. You must explicitly set it.
- **Computed fields:** Don't set fields that are computed by the provider (e.g., `arn`, `id`). Only set input properties.
- **Case sensitivity:** `"True"` vs `"true"`, `"Enabled"` vs `"enabled"` — some providers are strict.
- **Empty lists vs null:** `tags: {}` vs omitting tags entirely may differ.
- **Normalization:** CIDR blocks, IAM policy JSON (whitespace/key ordering), and security group rules can be semantically identical but syntactically different.

**IAM Policy mismatch (most common):**

```typescript
// BAD: Policy JSON whitespace/ordering may not match
const policy = new aws.iam.Policy("mypolicy", {
    policy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{ Effect: "Allow", Action: "s3:*", Resource: "*" }],
    }),
}, { import: "arn:aws:iam::123456789012:policy/MyPolicy" });

// GOOD: Fetch the actual policy document and use it verbatim
// aws iam get-policy-version --policy-arn ARN --version-id v1
```

### 3.3 Bulk Import from JSON

Create an `import.json` file describing all resources to import:

```json
{
  "nameTable": {
    "my-vpc": "my-vpc-resource-name",
    "my-subnet-a": "subnet-public-a",
    "my-subnet-b": "subnet-public-b"
  },
  "resources": [
    {
      "type": "aws:ec2/vpc:Vpc",
      "name": "my-vpc",
      "id": "vpc-0abc123def456789a"
    },
    {
      "type": "aws:ec2/subnet:Subnet",
      "name": "my-subnet-a",
      "id": "subnet-0aaa111222333444a"
    },
    {
      "type": "aws:ec2/subnet:Subnet",
      "name": "my-subnet-b",
      "id": "subnet-0bbb555666777888b"
    }
  ]
}
```

```bash
# Dry-run: generate code without actually importing
pulumi preview --import-file import.json

# Import and generate TypeScript code
pulumi import --file import.json --generate-code --out generated.ts --yes

# Import and generate Python code
pulumi import --file import.json --generate-code --out generated.py --yes
```

**Building `import.json` from AWS CLI:**

```bash
# Generate import entries for all EC2 instances
aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId' --output json | \
  jq '[.[] | {type: "aws:ec2/instance:Instance", name: ("instance-" + .), id: .}]' | \
  jq '{resources: .}' > import.json
```

### 3.4 `--generate-code` Workflow

```bash
# Import a single resource and generate matching code
pulumi import aws:s3/bucket:Bucket my-bucket my-actual-bucket \
  --generate-code --out bucket.ts

# The generated code matches the cloud resource exactly
# Review it, integrate into your project, then test:
pulumi preview --expect-no-changes
```

**Generated code caveats:**
- Code is generated for the language of the current project (detected from `Pulumi.yaml`)
- Generated code includes ALL properties, including defaults — prune to only what you need
- Generated code uses the `import` resource option — remove this after the first successful `pulumi up`
- Component resources and parent/child relationships are NOT generated — you must restructure manually
- Provider configuration (region, profile) is not included in generated code

### 3.5 Common Import Pitfalls per Provider

**AWS pitfalls:**
- Route53 records require `ZONEID_NAME_TYPE` format — forgetting the zone ID is the #1 mistake
- S3 bucket ACLs: `aws:s3/bucketAclV2:BucketAclV2` requires `bucket,expected-bucket-owner` as the import ID
- CloudWatch Log Groups: use the log group NAME, not ARN
- IAM Instance Profiles: use the profile NAME, not the role name
- Security Group Rules: inline rules (in the SG resource) cannot be imported separately — use standalone `SecurityGroupRule` resources

**Azure pitfalls:**
- `azure-native` vs `azure` (classic) providers have DIFFERENT import ID formats
- `azure-native` uses the exact ARM resource ID with correct casing
- Nested resources (subnets within VNets) require the full nested path
- Some resources require additional URL parameters (e.g., API version)

**GCP pitfalls:**
- Projects must be referenced by project ID, not project number (in most cases)
- IAM bindings: `google_project_iam_binding` uses `PROJECT ROLE` as the import ID
- Firewall rules: `projects/PROJECT/global/firewalls/NAME`
- Some resources support both self-link and short-form IDs — be consistent

---

## 4. Provider Version Conflicts

### 4.1 Plugin Cache and Resolution

```
error: could not load plugin aws [v6.0.0]:
  no resource plugin 'aws-v6.0.0' found in the workspace at
  /home/user/.pulumi/plugins/resource-aws-v6.0.0
```

**How Pulumi resolves plugins:**
1. Checks the local plugin cache (`~/.pulumi/plugins/`)
2. Downloads from the Pulumi plugin registry if not cached
3. Uses `pluginDownloadURL` if specified in the provider resource

```bash
# Inspect plugin cache
ls -la ~/.pulumi/plugins/
pulumi plugin ls

# Install a specific version
pulumi plugin install resource aws v6.0.0

# Clear the entire cache (forces re-download)
pulumi plugin rm --all --yes

# Remove a specific version
pulumi plugin rm resource aws v5.40.0

# Check which plugin a resource is using (from state)
pulumi stack export | jq '.deployment.resources[] | select(.type | startswith("aws:")) | .provider' | head -5
```

### 4.2 Pinning Versions

**Node.js (`package.json`):**

```json
{
  "dependencies": {
    "@pulumi/pulumi": "3.127.0",
    "@pulumi/aws": "6.52.0",
    "@pulumi/awsx": "2.14.0"
  }
}
```

Use exact versions (no `^` or `~`) for reproducible deployments. Lock files (`package-lock.json`, `yarn.lock`) provide additional protection.

**Python (`requirements.txt`):**

```
pulumi>=3.127.0,<4.0.0
pulumi-aws==6.52.0
```

**Go (`go.mod`):**

```go
require (
    github.com/pulumi/pulumi/sdk/v3 v3.127.0
    github.com/pulumi/pulumi-aws/sdk/v6 v6.52.0
)
```

**Pulumi.yaml (runtime-agnostic version constraint):**

```yaml
name: myproject
runtime: nodejs
plugins:
  providers:
    - name: aws
      version: 6.52.0
```

### 4.3 Breaking Changes Across Major Versions

**Detection workflow:**

```bash
# Step 1: Preview BEFORE upgrading in production
npm install @pulumi/aws@latest
pulumi preview --diff 2>&1 | tee upgrade-preview.txt

# Step 2: Look for replacements (!!!) and deprecations
grep -E "replace|DEPRECATED|error" upgrade-preview.txt

# Step 3: If replacements appear, check the changelog
# https://github.com/pulumi/pulumi-aws/releases
```

**Common breaking changes (AWS provider v5 → v6):**
- `aws.s3.Bucket` `acl` property removed → use `aws.s3.BucketAclV2`
- `aws.s3.Bucket` `website` property removed → use `aws.s3.BucketWebsiteConfigurationV2`
- Some resource types renamed or split into multiple resources
- Default values changed for some properties

**Migration strategy:**

```bash
# Step 1: Upgrade in a dev stack first
pulumi stack select dev
npm install @pulumi/aws@6.52.0
pulumi preview --diff

# Step 2: Fix deprecation warnings and breaking changes
# Step 3: Run `pulumi up` in dev, verify
# Step 4: Repeat for staging, then prod

# If a resource replacement is unacceptable, use aliases:
```

```typescript
// Avoid replacement when a resource type was renamed in the provider
const bucket = new aws.s3.BucketV2("my-bucket", { /* ... */ }, {
    aliases: [{ type: "aws:s3/bucket:Bucket" }],
});
```

### 4.4 Multi-Provider Version Coexistence

You can use multiple versions of the same provider simultaneously via explicit provider instances:

```typescript
import * as aws from "@pulumi/aws";

// Default provider (v6)
const defaultBucket = new aws.s3.Bucket("default-bucket", {});

// Explicit provider for a different region (same version)
const euProvider = new aws.Provider("eu-provider", { region: "eu-west-1" });
const euBucket = new aws.s3.Bucket("eu-bucket", {}, { provider: euProvider });

// For a truly different plugin version, use pluginDownloadURL or
// install both versions and create providers pinned to each
```

**Cross-account pattern:**

```typescript
const prodProvider = new aws.Provider("prod-aws", {
    region: "us-east-1",
    assumeRole: { roleArn: "arn:aws:iam::111111111111:role/PulumiDeployRole" },
});
const prodBucket = new aws.s3.Bucket("prod-data", {}, { provider: prodProvider });
```

### 4.5 `pluginDownloadURL` for Custom Providers

For private providers or custom plugin registries:

```typescript
const provider = new custom.Provider("my-provider", {}, {
    pluginDownloadURL: "https://artifacts.corp.example.com/pulumi-plugins/",
});
```

**Self-hosted plugin registry setup:**

```bash
# Host plugins at a URL matching Pulumi's expected path format:
# ${pluginDownloadURL}/pulumi-resource-${name}-v${version}-${os}-${arch}.tar.gz

# Example structure:
# https://artifacts.corp.example.com/pulumi-plugins/
#   pulumi-resource-custom-v1.0.0-linux-amd64.tar.gz
#   pulumi-resource-custom-v1.0.0-darwin-amd64.tar.gz

# Install from custom URL
pulumi plugin install resource custom v1.0.0 \
  --server https://artifacts.corp.example.com/pulumi-plugins/
```

---

## 5. Dependency Resolution

### 5.1 Circular Dependency Errors

```
error: circular dependency detected:
  aws:ec2/securityGroup:SecurityGroup (sg-a) ->
  aws:ec2/securityGroupRule:SecurityGroupRule (rule-b) ->
  aws:ec2/securityGroup:SecurityGroup (sg-b) ->
  aws:ec2/securityGroupRule:SecurityGroupRule (rule-a) ->
  aws:ec2/securityGroup:SecurityGroup (sg-a)
```

**Root cause:** Two resources reference each other's outputs, or `dependsOn` creates a loop.

**Fix pattern — break cycles with standalone child resources:**

```typescript
// ❌ CYCLE: Inline rules reference each other's SG IDs
const sgA = new aws.ec2.SecurityGroup("sg-a", {
    ingress: [{ securityGroups: [sgB.id], fromPort: 443, toPort: 443, protocol: "tcp" }],
});
const sgB = new aws.ec2.SecurityGroup("sg-b", {
    ingress: [{ securityGroups: [sgA.id], fromPort: 443, toPort: 443, protocol: "tcp" }],
});

// ✅ FIXED: Create SGs first, then add rules as separate resources
const sgA = new aws.ec2.SecurityGroup("sg-a", { description: "SG A" });
const sgB = new aws.ec2.SecurityGroup("sg-b", { description: "SG B" });

new aws.ec2.SecurityGroupRule("a-from-b", {
    securityGroupId: sgA.id,
    sourceSecurityGroupId: sgB.id,
    type: "ingress", fromPort: 443, toPort: 443, protocol: "tcp",
});
new aws.ec2.SecurityGroupRule("b-from-a", {
    securityGroupId: sgB.id,
    sourceSecurityGroupId: sgA.id,
    type: "ingress", fromPort: 443, toPort: 443, protocol: "tcp",
});
```

**Other common cycles and fixes:**
- **IAM role ↔ policy:** Create the role, then the policy, then the attachment
- **ECS service ↔ ALB listener:** Create ALB + target group first, then the service with `dependsOn: [listener]`
- **DNS ↔ load balancer:** Create the LB first, then the DNS record pointing to it

### 5.2 Implicit vs Explicit Dependencies

**Implicit dependencies** (preferred): Pulumi tracks dependencies automatically when you pass an `Output<T>` from one resource as input to another.

```typescript
const vpc = new aws.ec2.Vpc("vpc", { cidrBlock: "10.0.0.0/16" });
// Implicit dep: subnet depends on vpc because vpc.id is an Output<string>
const subnet = new aws.ec2.Subnet("subnet", { vpcId: vpc.id, cidrBlock: "10.0.1.0/24" });
```

**Explicit dependencies** (`dependsOn`): Only needed when there is a side-effect ordering requirement with no data flow.

```typescript
// IAM policy must propagate before Lambda can assume the role
// There's no output from the attachment that Lambda needs — it's a timing dependency
const attachment = new aws.iam.RolePolicyAttachment("attach", {
    role: role.name, policyArn: policy.arn,
});
const fn = new aws.lambda.Function("fn", { role: role.arn, /* ... */ }, {
    dependsOn: [attachment],  // Explicit: no data flows, but ordering matters
});
```

**Debugging dependency chains:**

```bash
# View the full dependency graph
pulumi stack export | jq '[.deployment.resources[] | {urn: .urn, deps: .dependencies}]'

# Find what depends on a specific resource
pulumi stack export | jq --arg urn "urn:pulumi:dev::app::aws:ec2/vpc:Vpc::main-vpc" \
  '[.deployment.resources[] | select(.dependencies[]? == $urn) | .urn]'
```

### 5.3 `dependsOn` Misuse Patterns

**Anti-pattern 1: Using `dependsOn` when an Output reference suffices.**

```typescript
// ❌ BAD: Redundant dependsOn — Pulumi already knows subnet depends on vpc
const subnet = new aws.ec2.Subnet("subnet", { vpcId: vpc.id }, {
    dependsOn: [vpc],  // Unnecessary!
});

// ✅ GOOD: The Output reference creates the dependency automatically
const subnet = new aws.ec2.Subnet("subnet", { vpcId: vpc.id });
```

**Anti-pattern 2: Circular `dependsOn`.**

```typescript
// ❌ FATAL: Circular dependency — Pulumi will error
const a = new ResourceA("a", {}, { dependsOn: [b] });
const b = new ResourceB("b", {}, { dependsOn: [a] });
```

**Anti-pattern 3: Overly broad `dependsOn` causing serial execution.**

```typescript
// ❌ SLOW: Every instance depends on every other, forcing serial creation
const instances = [];
for (let i = 0; i < 50; i++) {
    instances.push(new aws.ec2.Instance(`inst-${i}`, { /* ... */ }, {
        dependsOn: instances,  // Creates O(n²) dependencies!
    }));
}

// ✅ FAST: No artificial dependencies, all 50 create in parallel
const instances = [];
for (let i = 0; i < 50; i++) {
    instances.push(new aws.ec2.Instance(`inst-${i}`, { /* ... */ }));
}
```

### 5.4 Delete Ordering and `deletedWith`

When Pulumi destroys resources, it reverses the dependency order. Problems arise when:
- A parent is deleted before its children
- A dependency is deleted before the dependent resource's cleanup logic runs

**`deletedWith` option (Pulumi 3.60+):** Tells Pulumi that a child resource will be automatically deleted when its parent is deleted, so Pulumi doesn't need to make a separate delete API call.

```typescript
const cluster = new aws.ecs.Cluster("cluster", {});

// ECS services are auto-deleted when the cluster is deleted
// Without deletedWith, Pulumi would try to delete the service THEN the cluster,
// but the cluster delete might fail because the service still exists (race condition)
const service = new aws.ecs.Service("service", {
    cluster: cluster.arn, /* ... */
}, { deletedWith: cluster });
```

**Use `deletedWith` when:**
- The cloud provider auto-deletes children (e.g., deleting a resource group in Azure deletes everything in it)
- You're hitting "resource not found" errors during destroy because a parent was already deleted
- You want faster destroys (fewer API calls)

**Delete ordering debugging:**

```bash
# Preview destroy order
pulumi destroy --preview

# If destroy fails because resources are deleted in wrong order, use targeted destroy:
pulumi destroy --target 'urn:...:child-resource' --yes
pulumi destroy --target 'urn:...:parent-resource' --yes
```

---

## 6. Pending Operations

### 6.1 `--clear-pending-creates`

```
error: the current deployment has 1 resource(s) with pending operations:
  * creating urn:pulumi:dev::app::aws:ec2/instance:Instance::webserver

These resources are in an unknown state because a previous deployment
was interrupted. To clear these pending operations, run:
    pulumi up --clear-pending-creates
```

**Root cause:** `pulumi up` was interrupted (Ctrl-C, CI timeout, crash) while creating a resource. Pulumi doesn't know if the resource was actually created in the cloud.

```bash
# Option A: Clear pending creates — removes them from state
# Use when you know the resource was NOT created (e.g., failure happened before the API call)
pulumi up --clear-pending-creates

# IMPORTANT: This removes the resource from state. If the resource WAS actually created,
# it becomes an orphan in the cloud. Run `pulumi refresh` afterward to re-discover it.
```

### 6.2 `--import-pending-creates`

```bash
# Option B: Import pending creates — assumes the resource WAS created
# Use when you know the resource was created (check the cloud console)
pulumi up --import-pending-creates

# This tells Pulumi to treat the pending resource as successfully created,
# reads its current state from the cloud, and continues normally.
```

**Decision tree:**

```
Was the resource actually created in the cloud?
├─ YES → pulumi up --import-pending-creates
├─ NO  → pulumi up --clear-pending-creates
└─ UNSURE → Check the cloud console/CLI first
            aws ec2 describe-instances --filters "Name=tag:Name,Values=webserver"
```

### 6.3 Manual State Surgery with `jq`

For complex pending operation scenarios, manual state editing is sometimes necessary.

```bash
# Export state
pulumi stack export --file state.json

# View pending operations
jq '.deployment.pending_operations' state.json

# Clear ALL pending operations
jq '.deployment.pending_operations = []' state.json > state-fixed.json

# Clear only pending creates (keep pending deletes)
jq '.deployment.pending_operations |= map(select(.type != "creating"))' \
  state.json > state-fixed.json

# Remove a specific resource from state entirely
jq '.deployment.resources |= map(select(.urn != "urn:pulumi:dev::app::aws:ec2/instance:Instance::webserver"))' \
  state.json > state-fixed.json

# Unprotect all resources (bulk)
jq '.deployment.resources |= map(.protect = false)' \
  state.json > state-fixed.json

# Fix a provider reference that points to a non-existent provider
jq '(.deployment.resources[] | select(.provider | test("bad-provider"))) .provider = "urn:pulumi:dev::app::pulumi:providers:aws::default_6_52_0::aaaa-bbbb"' \
  state.json > state-fixed.json

# Validate the fixed JSON
python3 -c "import json; json.load(open('state-fixed.json'))" && echo "Valid"

# Import the fixed state
pulumi stack import --file state-fixed.json

# ALWAYS reconcile afterward
pulumi refresh --yes
```

### 6.4 Diagnosing Partial Creates

When `pulumi up` creates 10 out of 15 resources and then fails:

```bash
# Step 1: Check what was actually created
pulumi stack export | jq '[.deployment.resources[] | select(.id != null) | {urn: .urn, id: .id}]'

# Step 2: Check pending operations
pulumi stack export | jq '.deployment.pending_operations'

# Step 3: Check the cloud directly for resources that may have been created
aws ec2 describe-instances --filters "Name=tag:pulumi:stack,Values=dev"

# Step 4: Resolve — either clear or import pending creates
# If the resource exists in the cloud:
pulumi up --import-pending-creates
# If it doesn't:
pulumi up --clear-pending-creates

# Step 5: Re-run the deployment
pulumi up --yes
```

**Preventing partial create pain:**
- Use `protect: true` on critical resources
- In CI, capture the full output and state on failure
- Use `--on-error continue` (Pulumi 3.x) to attempt remaining resources even if one fails (use carefully)

---

## 7. Stack Corruption Recovery

### 7.1 Corrupt JSON State

```
error: could not deserialize deployment: invalid character '}' looking for beginning of value
```

```
error: could not deserialize deployment: unexpected end of JSON input
```

**Recovery steps:**

```bash
# Step 1: Try to export (may work even with partial corruption)
pulumi stack export --file corrupt-state.json 2>/dev/null

# Step 2: If export fails, get the raw state file
# Pulumi Cloud: Contact support
# S3 backend:
aws s3 cp s3://my-state-bucket/.pulumi/stacks/org/project/stack.json corrupt-state.json
# Local backend:
cp ~/.pulumi/stacks/stack.json corrupt-state.json

# Step 3: Attempt JSON repair
# Try jq (fails fast on invalid JSON, shows the error location)
jq '.' corrupt-state.json
# Output: parse error (invalid numeric literal at line 1542, column 30)

# Step 4: Fix at the reported location
# Common fixes: missing comma, extra comma, unclosed brace, truncated file

# Step 5: If the file is truncated, restore from a previous version
# S3 with versioning:
aws s3api list-object-versions --bucket my-state-bucket \
  --prefix .pulumi/stacks/org/project/stack.json | jq '.Versions[:5]'
aws s3api get-object --bucket my-state-bucket \
  --key .pulumi/stacks/org/project/stack.json \
  --version-id "VERSION_ID" restored-state.json

# Step 6: Import the fixed state
pulumi stack import --file fixed-state.json
pulumi refresh --yes
```

### 7.2 Missing Resources in State

**Symptom:** A resource exists in the cloud and your code references it, but it's missing from state (perhaps due to state corruption or accidental `pulumi state delete`).

```
error: resource 'urn:pulumi:prod::app::aws:ec2/vpc:Vpc::main-vpc'
  registered twice
```

Or: `pulumi up` tries to create a resource that already exists:

```
error: creating urn:pulumi:prod::app::aws:s3/bucket:Bucket::data:
  BucketAlreadyOwnedByYou: Your previous request to create the named bucket succeeded
```

**Fix:**

```bash
# Re-import the existing resource
pulumi import aws:s3/bucket:Bucket data my-actual-bucket-name --yes

# Or, if you have a known-good state version:
pulumi stack export --version 50 --file good-state.json
pulumi stack import --file good-state.json
pulumi refresh --yes
```

### 7.3 Version Rollback (`--version N`)

```bash
# List available versions (Pulumi Cloud)
pulumi stack history | head -20

# Example output:
# Version  Date                 Message
# 53       2024-01-15 10:30:00  Update
# 52       2024-01-14 09:15:00  Update
# 51       2024-01-13 14:00:00  Refresh

# Export a specific version
pulumi stack export --version 51 --file state-v51.json

# Inspect what resources existed at that version
jq '.deployment.resources | length' state-v51.json
jq '[.deployment.resources[].urn]' state-v51.json

# Roll back
pulumi stack import --file state-v51.json

# CRITICAL: Refresh to reconcile with current cloud reality
pulumi refresh --yes

# Then preview to see what Pulumi will do
pulumi preview --diff
```

**Warning:** State rollback is a state-only operation. Cloud resources created between the target version and the current version still exist. After rollback + refresh, Pulumi will see those resources as "not in code" but refresh will add them back to state. You may need to import them or manually clean them up.

### 7.4 State Backup Strategies

**Pulumi Cloud backend:** Automatic versioning, no action needed. Every `pulumi up` creates a new version.

**S3 backend — enable versioning:**

```bash
# Enable versioning on the state bucket
aws s3api put-bucket-versioning --bucket my-pulumi-state \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption --bucket my-pulumi-state \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]
  }'

# Block public access
aws s3api put-public-access-block --bucket my-pulumi-state \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

**Cross-region backup:**

```bash
# Replicate state bucket to another region
aws s3api put-bucket-replication --bucket my-pulumi-state \
  --replication-configuration file://replication-config.json
```

**Local backup cron (for any backend):**

```bash
#!/usr/bin/env bash
# Run daily: backs up every stack's state
BACKUP_DIR="/backups/pulumi-state/$(date +%Y-%m-%d)"
mkdir -p "$BACKUP_DIR"
for stack in $(pulumi stack ls --json | jq -r '.[].name'); do
  pulumi stack select "$stack"
  pulumi stack export --file "$BACKUP_DIR/${stack}.json"
done
```

### 7.5 Migrating Between Backends

```bash
# Migrate from local to Pulumi Cloud
pulumi login  # Logs into Pulumi Cloud
pulumi stack select dev
pulumi stack export --file state-export.json
# Switch backend
pulumi login https://api.pulumi.com
pulumi stack init dev
pulumi stack import --file state-export.json

# Migrate from Pulumi Cloud to S3
pulumi stack export --file state-export.json
pulumi logout
pulumi login s3://my-pulumi-state-bucket
pulumi stack init dev
pulumi stack import --file state-export.json

# Migrate from S3 to Azure Blob
pulumi stack export --file state-export.json
pulumi login azblob://my-container
pulumi stack init dev
pulumi stack import --file state-export.json
```

**Post-migration checklist:**
1. `pulumi refresh --yes` to verify state matches cloud
2. `pulumi preview --expect-no-changes` to verify no unintended changes
3. Update CI/CD `PULUMI_BACKEND_URL` or `pulumi login` commands
4. Update secrets provider if it changed (see §10.3)
5. Decommission the old backend after verification period

---

## 8. Common Error Messages Reference

| Error Message | Cause | Fix |
|---|---|---|
| `error: the stack is currently locked by 1 lock(s)` | Previous operation interrupted without releasing lock | `pulumi cancel` or `pulumi stack export \| pulumi stack import` |
| `error: [409] Conflict: Another update is already in progress` | Concurrent `pulumi up` on same stack | Wait or `pulumi cancel`; add CI concurrency groups |
| `error: could not load plugin aws [v6.0.0]` | Plugin not in local cache | `pulumi plugin install resource aws v6.0.0` |
| `error: failed to decrypt config value: incorrect passphrase` | Wrong `PULUMI_CONFIG_PASSPHRASE` | Set correct passphrase or re-create secrets |
| `error: inputs to import do not match the existing resource` | Code properties differ from cloud resource | Query cloud resource, update code to match exactly |
| `error: circular dependency detected` | Resources reference each other's outputs | Break cycle with standalone child resources (§5.1) |
| `error: the current deployment has N resource(s) with pending operations` | Interrupted create/delete/update | `--clear-pending-creates` or `--import-pending-creates` (§6) |
| `error: could not deserialize deployment` | Corrupt state JSON | Fix JSON manually or rollback to previous version (§7.1) |
| `error: preview failed: refusing to proceed` | Preview detects issues that would cause data loss | Review diff carefully; use `--target` for incremental changes |
| `error: creating ...: already exists` | Resource exists in cloud but not in state | `pulumi import` the existing resource (§3) |
| `error: deleting ...: resource not found` | Resource in state was deleted out-of-band | `pulumi state delete <URN>` to remove from state |
| `error: updating ...: is not authorized to perform` | IAM/RBAC permissions insufficient | Fix cloud IAM permissions for the deploying principal |
| `error: Program exited with non-zero exit code: 1` | Runtime error in Pulumi program (JS/Python/Go) | Check program stderr; usually a syntax or logic error in user code |
| `error: failed to load language plugin nodejs` | Node.js not installed or wrong version | Install Node.js; check `runtime` in `Pulumi.yaml` |
| `error: pulumi:pulumi:Stack resource '...' has a problem: ...` | Stack-level configuration or output error | Check stack outputs and config; often a missing config value |
| `error: this resource is protected` | `protect: true` prevents deletion/replacement | `pulumi state unprotect <URN>` then retry |
| `error: replacing ...: the resource cannot be replaced because it is protected` | Replacement attempted on protected resource | Unprotect, or change code to avoid replacement trigger |
| `error: failed to check ...: timeout` | Provider API call timed out | Retry; increase provider timeout config; check network |
| `error: duplicate resource URN` | Two resources with the same logical name and type | Rename one resource or use different parent components |
| `error: BAIL: --expect-no-changes was specified and changes were detected` | Drift detected during CI refresh | Investigate drift, refresh to accept or `pulumi up` to fix |

---

## 9. Performance Optimization

### 9.1 Large Stacks (500+ Resources)

**Symptoms:**
- `pulumi preview` takes >5 minutes
- `pulumi up` takes >30 minutes
- `pulumi refresh` takes >10 minutes
- State file >50 MB

**Diagnosis:**

```bash
# Count resources
pulumi stack export | jq '.deployment.resources | length'

# State file size
pulumi stack export | wc -c

# Resources by type (find the bulk)
pulumi stack export | jq '[.deployment.resources[].type] | group_by(.) | map({type: .[0], count: length}) | sort_by(-.count)' | head -30

# Time a preview
time pulumi preview --json 2>/dev/null | jq '.steps | length'
```

**Thresholds:**
- <200 resources: No action needed
- 200–500 resources: Tune parallelism, consider splitting
- 500–1000 resources: Split stacks, use targeted operations
- 1000+ resources: Mandatory split, aggressive parallelism tuning

### 9.2 Parallelism Tuning

```bash
# Default parallelism is 10 concurrent operations
# Increase for large stacks with independent resources
pulumi up --parallel 50

# Decrease if hitting cloud API rate limits
pulumi up --parallel 5

# Set via environment variable
export PULUMI_PARALLEL=50
pulumi up
```

**Optimal values by provider:**
- **AWS:** 30–50 (higher causes throttling on some APIs like IAM, CloudFormation)
- **Azure:** 20–30 (Azure ARM has stricter rate limits)
- **GCP:** 30–50 (varies by API; Compute Engine is generous, IAM is strict)
- **Kubernetes:** 10–20 (API server can get overwhelmed)

**Rate limit errors indicate parallelism is too high:**

```
error: creating ...: Throttling: Rate exceeded
error: creating ...: 429 Too Many Requests
```

Lower `--parallel` or add retry logic in the provider configuration.

### 9.3 Targeted Operations

```bash
# Deploy only one resource
pulumi up --target 'urn:pulumi:prod::app::aws:ec2/instance:Instance::webserver'

# Deploy a resource and all its dependents
pulumi up --target-dependents --target 'urn:pulumi:prod::app::aws:ec2/vpc:Vpc::main-vpc'

# Deploy multiple specific resources
pulumi up \
  --target 'urn:pulumi:prod::app::aws:ec2/instance:Instance::web-1' \
  --target 'urn:pulumi:prod::app::aws:ec2/instance:Instance::web-2'

# Force replace a specific resource
pulumi up --replace 'urn:pulumi:prod::app::aws:ec2/instance:Instance::webserver'

# Destroy a single resource
pulumi destroy --target 'urn:pulumi:prod::app::aws:ec2/instance:Instance::old-server'

# Refresh a single resource
pulumi refresh --target 'urn:pulumi:prod::app::aws:rds/instance:Instance::prod-db'
```

**Finding URNs efficiently:**

```bash
# Search by resource name
pulumi stack --show-urns | grep "webserver"

# Search by type
pulumi stack --show-urns | grep "aws:ec2/instance"

# Get URN from state with jq
pulumi stack export | jq -r '.deployment.resources[] | select(.type == "aws:ec2/instance:Instance") | .urn'
```

### 9.4 State File Size Reduction

```bash
# Check state size
pulumi stack export | wc -c
# If >20 MB, state is bloated

# Common causes of bloat:
# 1. Large outputs stored in state (e.g., rendered Kubernetes manifests)
# 2. Many deleted resources that haven't been cleaned up
# 3. Resources with huge property bags

# Clean up with refresh (removes deleted resources from state)
pulumi refresh --yes

# Identify large resources
pulumi stack export | jq '[.deployment.resources[] | {urn: .urn, size: (. | tostring | length)}] | sort_by(-.size) | .[0:10]'

# If a resource has unnecessarily large outputs (e.g., Helm chart),
# consider splitting it into a separate stack
```

### 9.5 Splitting Stacks

**When to split:** stack >500 resources, deploys >15 minutes, multiple teams own different parts, different deployment cadences.

**Recommended layering:**

```
Layer 1: foundation/     (VPC, subnets, NAT, DNS zones)     ~30-50 resources
Layer 2: data/           (RDS, ElastiCache, S3, SQS)        ~50-100 resources
Layer 3: compute/        (ECS/EKS, ALB, ASG)                ~100-300 resources
Layer 4: application/    (Lambda, API GW, CloudFront)        ~50-200 resources
Layer 5: monitoring/     (CloudWatch, alarms, dashboards)    ~50-100 resources
```

**Connecting stacks with StackReferences:**

```typescript
// foundation/index.ts — exports shared outputs
export const vpcId = vpc.id;
export const privateSubnetIds = privateSubnets.map(s => s.id);
export const publicSubnetIds = publicSubnets.map(s => s.id);

// compute/index.ts — reads from foundation
const foundation = new pulumi.StackReference("org/foundation/prod");
const vpcId = foundation.getOutput("vpcId");
const privateSubnetIds = foundation.getOutput("privateSubnetIds");

const cluster = new aws.ecs.Cluster("cluster", {});
const service = new aws.ecs.Service("service", {
    cluster: cluster.arn,
    networkConfiguration: {
        subnets: privateSubnetIds,
    },
});
```

**Stack reference rules:**
- Data flows one direction only (no cycles between stacks)
- Lower layers must not reference higher layers
- Use explicit output typing with `requireOutput` for fail-fast behavior
- Keep the number of exported outputs minimal (just IDs and ARNs)

**Migrating resources between stacks:**

```bash
# Step 1: Export the resource from the source stack
pulumi stack select source-stack
pulumi stack export --file source-state.json

# Step 2: Use `pulumi state move` (Pulumi 3.90+)
pulumi state move --source org/source-project/source-stack --dest org/dest-project/dest-stack \
  'urn:pulumi:source-stack::source-project::aws:ec2/instance:Instance::webserver'

# Step 3: Add matching code in the destination stack
# Step 4: Remove the code from the source stack
# Step 5: Verify both stacks
pulumi stack select source-stack && pulumi preview --expect-no-changes
pulumi stack select dest-stack && pulumi preview --expect-no-changes
```

---

## 10. Secrets and Encryption

### 10.1 Wrong Passphrase Recovery

```
error: failed to decrypt config value: incorrect passphrase
  for key 'myproject:databasePassword'
```

**With `passphrase` secrets provider:** The passphrase is set via `PULUMI_CONFIG_PASSPHRASE` or `PULUMI_CONFIG_PASSPHRASE_FILE`. There is no recovery mechanism — the passphrase IS the encryption key.

**Recovery options:**

```bash
# Option A: Remember/find the passphrase
export PULUMI_CONFIG_PASSPHRASE="correct-passphrase"
pulumi config get myproject:databasePassword

# Option B: Check CI/CD secrets, password managers, shell history
history | grep PULUMI_CONFIG_PASSPHRASE

# Option C: If passphrase is truly lost, you must re-create all secrets
# First, export the non-secret config
pulumi config --json | jq 'to_entries | map(select(.value.secret != true)) | from_entries'

# Create a new stack with a new passphrase
export PULUMI_CONFIG_PASSPHRASE="new-secure-passphrase"
pulumi stack init new-dev --secrets-provider passphrase

# Re-set all secret values manually
pulumi config set --secret myproject:databasePassword "new-password"

# Import the state from the old stack (state is not encrypted by the passphrase —
# only config values are)
pulumi stack export --stack old-dev --file state.json
pulumi stack import --file state.json
```

**Important:** The passphrase encrypts config values in `Pulumi.<stack>.yaml`. The state file uses its own secrets provider (which may be different). These are separate encryption layers.

### 10.2 KMS Issues

**AWS KMS:**

```
error: failed to decrypt: AccessDeniedException:
  User: arn:aws:iam::123456789012:user/deploy is not authorized
  to perform: kms:Decrypt on resource: arn:aws:kms:us-east-1:123456789012:key/abc-123
```

**Required KMS permissions:**

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ],
    "Resource": "arn:aws:kms:us-east-1:123456789012:key/YOUR-KEY-ID"
  }]
}
```

**Common KMS issues:**
- Key is in a different region than expected
- Key is disabled or pending deletion
- Key policy does not allow the IAM principal
- Cross-account key access requires both IAM policy AND key policy grants

**Debugging:**

```bash
# Check key status
aws kms describe-key --key-id "alias/pulumi-secrets" | jq '.KeyMetadata.KeyState'

# Test encryption/decryption
echo "test" | aws kms encrypt --key-id "alias/pulumi-secrets" \
  --plaintext fileb:///dev/stdin --output text --query CiphertextBlob

# Check which secrets provider the stack uses
pulumi stack export | jq '.deployment.secrets_providers'
```

**GCP KMS:**

```bash
# Required role: roles/cloudkms.cryptoKeyEncrypterDecrypter
gcloud kms keys list --location global --keyring pulumi-keyring

# Verify access
gcloud kms encrypt --location global --keyring pulumi-keyring \
  --key pulumi-key --plaintext-file=- --ciphertext-file=- <<< "test"
```

**Azure Key Vault:**

```bash
# Required: Key Vault Crypto User role
az keyvault key list --vault-name my-pulumi-vault

# Verify access
az keyvault key encrypt --vault-name my-pulumi-vault --name pulumi-key \
  --algorithm RSA-OAEP --value "dGVzdA=="
```

### 10.3 Migrating Secrets Providers

```bash
# Change from passphrase to AWS KMS
pulumi stack change-secrets-provider \
  "awskms://alias/pulumi-secrets?region=us-east-1"

# Change from passphrase to GCP KMS
pulumi stack change-secrets-provider \
  "gcpkms://projects/my-project/locations/global/keyRings/pulumi/cryptoKeys/pulumi-key"

# Change from passphrase to Azure Key Vault
pulumi stack change-secrets-provider \
  "azurekeyvault://my-vault.vault.azure.net/keys/pulumi-key"

# Change from KMS to Pulumi Cloud managed secrets
pulumi stack change-secrets-provider "default"

# Change from any provider to passphrase
export PULUMI_CONFIG_PASSPHRASE="new-passphrase"
pulumi stack change-secrets-provider "passphrase"
```

**What `change-secrets-provider` does:**
1. Decrypts all secrets using the old provider
2. Re-encrypts all secrets using the new provider
3. Updates the `secrets_providers` field in state
4. Updates `encryptedkey` in `Pulumi.<stack>.yaml`

**Migration checklist:**
- Ensure all team members and CI/CD systems have access to the new provider
- Update `PULUMI_CONFIG_PASSPHRASE` / KMS key references in CI/CD
- Test `pulumi config get --secret <key>` after migration
- Verify `pulumi preview` works (it decrypts secrets during preview)

### 10.4 Secret Propagation Debugging

Secrets in Pulumi are tracked through the type system. An `Output<string>` marked as secret remains secret when passed to other resources.

**Problem: Secret leaking into non-secret output:**

```typescript
// This logs the secret in plaintext!
const password = config.requireSecret("dbPassword");
password.apply(p => console.log(p));  // ❌ Prints plaintext to stdout

// Pulumi warns about this:
// warning: Outputs with secret values should not be logged
```

**Problem: Secret not propagating:**

```typescript
// If you extract a secret value and re-wrap it, mark it as secret
const rawValue = config.requireSecret("apiKey");
const processed = rawValue.apply(v => v.toUpperCase());
// 'processed' is automatically secret because its input was secret ✅

// But if you construct a new Output, you must mark it manually
const manualOutput = pulumi.output("sensitive-value");  // NOT secret ❌
const secretOutput = pulumi.secret("sensitive-value");   // Secret ✅
```

**Debugging secret status:**

```bash
# Check if a stack output is secret
pulumi stack output --json | jq 'to_entries[] | {key: .key, secret: (.value | type == "object" and has("4dabf18193072939515e22adb298388d"))}'

# Check secrets in state
pulumi stack export | jq '[.deployment.resources[].outputs | to_entries[]? | select(.value | type == "object" and has("4dabf18193072939515e22adb298388d")) | .key]' | sort -u

# The magic string "4dabf18193072939515e22adb298388d" is Pulumi's secret sentinel
# If you see it in state, the value is encrypted
```

**Forcing an output to be secret:**

```typescript
// In resource options
const db = new aws.rds.Instance("db", {
    password: config.requireSecret("dbPassword"),
}, {
    additionalSecretOutputs: ["address"],  // Marks 'address' output as secret too
});

// In stack outputs
export const dbPassword = pulumi.secret(db.password);
```

---

## 11. Quick Reference Tables

### Essential Commands

| Scenario | Command |
|---|---|
| Unlock stuck stack | `pulumi cancel` |
| Force-unlock via export/import | `pulumi stack export \| pulumi stack import` |
| Remove resource from state only | `pulumi state delete '<URN>'` |
| Sync state with cloud reality | `pulumi refresh --yes` |
| Check for drift (CI gate) | `pulumi refresh --expect-no-changes --yes` |
| View all resource URNs | `pulumi stack --show-urns` |
| Export state to file | `pulumi stack export --file state.json` |
| Import state from file | `pulumi stack import --file state.json` |
| Export historical state version | `pulumi stack export --version N --file state-vN.json` |
| Import existing cloud resource | `pulumi import <type> <name> <id>` |
| Bulk import from JSON | `pulumi import --file import.json --generate-code --out gen.ts` |
| List installed plugins | `pulumi plugin ls` |
| Install specific plugin version | `pulumi plugin install resource <name> <ver>` |
| Clear plugin cache | `pulumi plugin rm --all --yes` |
| Deploy single resource | `pulumi up --target '<URN>'` |
| Deploy with dependents | `pulumi up --target-dependents --target '<URN>'` |
| Force replace a resource | `pulumi up --replace '<URN>'` |
| Increase parallelism | `pulumi up --parallel 50` |
| Unprotect a resource | `pulumi state unprotect '<URN>'` |
| Change secrets provider | `pulumi stack change-secrets-provider '<url>'` |
| Move resource between stacks | `pulumi state move --source <stack> --dest <stack> '<URN>'` |
| Clear pending creates | `pulumi up --clear-pending-creates` |
| Import pending creates | `pulumi up --import-pending-creates` |
| Preview with full diff | `pulumi preview --diff` |
| Count resources in stack | `pulumi stack export \| jq '.deployment.resources \| length'` |
| View deployment history | `pulumi stack history` |

### State Surgery `jq` Recipes

| Operation | Command |
|---|---|
| Count resources | `jq '.deployment.resources \| length' state.json` |
| List all URNs | `jq -r '.deployment.resources[].urn' state.json` |
| View pending operations | `jq '.deployment.pending_operations' state.json` |
| Clear all pending ops | `jq '.deployment.pending_operations = []' state.json` |
| Unprotect all resources | `jq '.deployment.resources[].protect = false' state.json` |
| Find resources by type | `jq '[.deployment.resources[] \| select(.type \| test("Instance"))]' state.json` |
| Remove a specific resource | `jq '.deployment.resources \|= map(select(.urn != "TARGET_URN"))' state.json` |
| Find provider references | `jq '[.deployment.resources[].provider // empty] \| unique' state.json` |
| Check secrets provider | `jq '.deployment.secrets_providers' state.json` |
| List resource dependencies | `jq '[.deployment.resources[] \| {urn, deps: .dependencies}]' state.json` |

### Environment Variables

| Variable | Purpose |
|---|---|
| `PULUMI_ACCESS_TOKEN` | Auth token for Pulumi Cloud backend |
| `PULUMI_BACKEND_URL` | Backend URL (e.g., `s3://bucket`, `azblob://container`) |
| `PULUMI_CONFIG_PASSPHRASE` | Passphrase for secrets encryption |
| `PULUMI_CONFIG_PASSPHRASE_FILE` | File containing the passphrase |
| `PULUMI_PARALLEL` | Default parallelism for operations |
| `PULUMI_SKIP_UPDATE_CHECK` | Skip CLI update check (`true` for CI) |
| `PULUMI_SKIP_CONFIRMATIONS` | Auto-approve all prompts (equivalent to `--yes`) |
| `PULUMI_HOME` | Override Pulumi home directory (default `~/.pulumi`) |
| `PULUMI_DEBUG_COMMANDS` | Enable debug logging for CLI commands |
