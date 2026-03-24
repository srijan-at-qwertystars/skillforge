---
name: pulumi-iac
description: >
  Guide for building and managing cloud infrastructure using Pulumi IaC with real programming languages.
  TRIGGER when: user asks about Pulumi projects, infrastructure as code with TypeScript/Python/Go/C#/Java/YAML,
  cloud resource provisioning via Pulumi, Pulumi stack management, Pulumi Automation API, component resources,
  Pulumi config/secrets, CrossGuard policies, or importing existing cloud resources into Pulumi.
  DO NOT TRIGGER when: user asks about Terraform/HCL/OpenTofu, AWS CloudFormation, AWS CDK, Ansible playbooks,
  Chef/Puppet, pure Kubernetes manifests without Pulumi, or general Docker/container questions unrelated to Pulumi.
---

# Pulumi Infrastructure as Code

## Installation & Setup

```bash
# Install CLI
curl -fsSL https://get.pulumi.com | sh
# Or: brew install pulumi/tap/pulumi

# Login to backend
pulumi login                          # Pulumi Cloud (default)
pulumi login s3://my-state-bucket     # S3 backend
pulumi login file://~/.pulumi-state   # Local filesystem
pulumi login azblob://container       # Azure Blob
pulumi login gs://bucket              # GCS

# Create new project
pulumi new typescript    # Also: python, go, csharp, java, yaml
pulumi new aws-typescript  # Cloud-specific templates
```

## Project Structure

Standard layout for a TypeScript Pulumi project:
```
my-infra/
├── Pulumi.yaml              # Project definition
├── Pulumi.dev.yaml           # Stack config (dev)
├── Pulumi.prod.yaml          # Stack config (prod)
├── index.ts                  # Entry point
├── components/               # Reusable component resources
├── config.ts                 # Config helpers
├── package.json
└── tsconfig.json
```

### Pulumi.yaml — Project Definition
```yaml
name: my-infra
runtime:
  name: nodejs           # nodejs | python | go | dotnet | java | yaml
  options:
    typescript: true
description: Production infrastructure
config:
  pulumi:tags:
    value:
      pulumi:template: aws-typescript
```

### Pulumi.{stack}.yaml — Stack Configuration
```yaml
config:
  aws:region: us-west-2
  my-infra:instanceType: t3.micro
  my-infra:dbPassword:
    secure: AAABADQXFlU0mxC...   # Encrypted secret
```

## Resource Creation

### AWS Example (TypeScript)
```typescript
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

const config = new pulumi.Config();
const bucket = new aws.s3.Bucket("app-bucket", {
    versioning: { enabled: true },
    serverSideEncryptionConfiguration: {
        rule: { applyServerSideEncryptionByDefault: { sseAlgorithm: "aws:kms" } },
    },
    tags: { Environment: pulumi.getStack() },
});
export const bucketName = bucket.id;
export const bucketArn = bucket.arn;
```

### Azure Example (Python)
```python
import pulumi
from pulumi_azure_native import resources, storage

rg = resources.ResourceGroup("rg", location="WestUS2")
account = storage.StorageAccount("sa",
    resource_group_name=rg.name,
    sku=storage.SkuArgs(name=storage.SkuName.STANDARD_LRS),
    kind=storage.Kind.STORAGE_V2,
    location=rg.location)
pulumi.export("account_name", account.name)
```

### GCP Example (Go)
```go
package main
import (
    "github.com/pulumi/pulumi-gcp/sdk/v7/go/gcp/storage"
    "github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)
func main() {
    pulumi.Run(func(ctx *pulumi.Context) error {
        bucket, err := storage.NewBucket(ctx, "my-bucket", &storage.BucketArgs{
            Location: pulumi.String("US"),
            UniformBucketLevelAccess: pulumi.Bool(true),
        })
        if err != nil { return err }
        ctx.Export("bucketURL", bucket.Url)
        return nil
    })
}
```

## Stack Management

```bash
pulumi stack init dev              # Create stack
pulumi stack select prod           # Switch stack
pulumi stack ls                    # List stacks
pulumi stack rm staging            # Remove stack
pulumi stack output bucketName     # Get specific output
pulumi stack export > state.json   # Export state
pulumi stack import < state.json   # Import state
pulumi preview                     # Dry-run changes
pulumi up --yes                    # Deploy (skip confirmation)
pulumi refresh                     # Sync state with cloud
pulumi destroy --yes               # Tear down all resources
```

## State Backends

| Backend | Login Command | Use Case |
|---------|--------------|----------|
| Pulumi Cloud | `pulumi login` | Teams, audit, RBAC, secrets |
| S3 | `pulumi login s3://bucket?region=us-east-1` | Self-hosted, AWS-native |
| S3 + locking | `pulumi login s3://bucket?region=us-east-1&awssdk=v2` | Concurrent access safety |
| Azure Blob | `pulumi login azblob://container` | Azure-native teams |
| GCS | `pulumi login gs://bucket` | GCP-native teams |
| Local | `pulumi login --local` | Dev/testing only |

Set `PULUMI_BACKEND_URL` env var to configure backend without interactive login.

## Secrets Management

```bash
# Set secrets (encrypted in stack config)
pulumi config set --secret dbPassword 'S3cur3P@ss!'
pulumi config set --secret apiKey 'sk-abc123'

# Choose secrets provider
pulumi stack init dev --secrets-provider="awskms://alias/pulumi"
pulumi stack init dev --secrets-provider="azurekeyvault://vault.vault.azure.net/keys/key"
pulumi stack init dev --secrets-provider="gcpkms://projects/p/locations/l/keyRings/r/cryptoKeys/k"
pulumi stack init dev --secrets-provider="passphrase"  # Local passphrase

# Change provider on existing stack
pulumi stack change-secrets-provider "awskms://alias/pulumi"
```

In code, secret outputs propagate automatically:
```typescript
const config = new pulumi.Config();
const pw = config.requireSecret("dbPassword"); // Output<string>, always encrypted
const connStr = pulumi.interpolate`postgres://admin:${pw}@host/db`; // Also secret
```

## Config System

```bash
pulumi config set key value                  # Plain config
pulumi config set --secret key value         # Secret config
pulumi config set --path 'data.nums[0]' 1    # Structured config
pulumi config get key                        # Read config
pulumi config rm key                         # Remove config
```

```typescript
const config = new pulumi.Config();
const name = config.require("name");            // Fails if missing
const port = config.getNumber("port") ?? 8080;  // Optional with default
const pw = config.requireSecret("dbPassword");  // Secret output
const obj = config.requireObject<{a: string}>("settings"); // Structured
```

## Component Resources

Create reusable, encapsulated infrastructure patterns:

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

interface SecureBucketArgs {
    prefix: string;
    expirationDays?: number;
}

class SecureBucket extends pulumi.ComponentResource {
    public readonly bucket: aws.s3.Bucket;
    public readonly bucketName: pulumi.Output<string>;

    constructor(name: string, args: SecureBucketArgs, opts?: pulumi.ComponentResourceOptions) {
        super("custom:storage:SecureBucket", name, args, opts);
        this.bucket = new aws.s3.Bucket(`${name}-bucket`, {
            acl: "private",
            versioning: { enabled: true },
            serverSideEncryptionConfiguration: {
                rule: { applyServerSideEncryptionByDefault: { sseAlgorithm: "AES256" } },
            },
            lifecycleRules: [{
                enabled: true,
                expiration: { days: args.expirationDays ?? 90 },
            }],
            tags: { ManagedBy: "pulumi", Prefix: args.prefix },
        }, { parent: this });
        this.bucketName = this.bucket.id;
        this.registerOutputs({ bucketName: this.bucketName });
    }
}

// Usage
const logs = new SecureBucket("app-logs", { prefix: "logs", expirationDays: 30 });
```

## Provider Configuration

```typescript
// Default provider (uses stack config aws:region)
const bucket = new aws.s3.Bucket("b1");

// Explicit provider for multi-region/multi-account
const euProvider = new aws.Provider("eu", { region: "eu-west-1" });
const euBucket = new aws.s3.Bucket("eu-b1", {}, { provider: euProvider });

// Assume role
const crossAcct = new aws.Provider("cross", {
    assumeRole: { roleArn: "arn:aws:iam::123456789012:role/deploy" },
    region: "us-east-1",
});
```

## Automation API

Embed Pulumi operations in application code for platforms, CLIs, and CI systems:

```typescript
import { LocalWorkspace, InlineProgramArgs } from "@pulumi/pulumi/automation";
import * as aws from "@pulumi/aws";

async function deploy() {
    const program = async () => {
        const bucket = new aws.s3.Bucket("auto-bucket");
        return { bucketName: bucket.id };
    };
    const args: InlineProgramArgs = {
        stackName: "dev",
        projectName: "auto-project",
        program,
    };
    const stack = await LocalWorkspace.createOrSelectStack(args);
    await stack.setConfig("aws:region", { value: "us-west-2" });

    const upRes = await stack.up({ onOutput: console.log });
    console.log(`Bucket: ${upRes.outputs.bucketName.value}`);

    // Cleanup
    // await stack.destroy({ onOutput: console.log });
    // await stack.workspace.removeStack("dev");
}
deploy();
```

Key Automation API patterns:
- **Inline programs**: Define infrastructure as functions — ideal for dynamic, runtime-driven infra.
- **Local programs**: Point to existing Pulumi project directories.
- **Stack operations**: `stack.up()`, `stack.preview()`, `stack.refresh()`, `stack.destroy()`.
- **Config**: `stack.setConfig()`, `stack.setAllConfig()`, `stack.getAllConfig()`.
- **Outputs**: `upResult.outputs` returns a map of output values.

## Policy as Code (CrossGuard)

```bash
mkdir policy && cd policy && pulumi policy new aws-typescript
```

```typescript
// policy/index.ts
import { PolicyPack, validateResourceOfType } from "@pulumi/policy";
import * as aws from "@pulumi/aws";

new PolicyPack("security-policies", {
    policies: [
        {
            name: "s3-no-public-read",
            description: "S3 buckets must not have public-read ACL.",
            enforcementLevel: "mandatory", // mandatory | advisory | disabled
            validateResource: validateResourceOfType(aws.s3.Bucket, (bucket, args, reportViolation) => {
                if (bucket.acl === "public-read" || bucket.acl === "public-read-write") {
                    reportViolation("S3 buckets must not be publicly readable.");
                }
            }),
        },
        {
            name: "required-tags",
            description: "All resources must have required tags.",
            enforcementLevel: "mandatory",
            validateResource: (args, reportViolation) => {
                if (args.props.tags && !args.props.tags["Environment"]) {
                    reportViolation("Missing required 'Environment' tag.");
                }
            },
        },
    ],
});
```

```bash
pulumi preview --policy-pack ./policy    # Local enforcement
pulumi up --policy-pack ./policy
pulumi policy publish ./policy           # Org-wide via Pulumi Cloud
pulumi policy enable my-org/security-policies latest
```

## Testing Infrastructure

### Unit Tests (TypeScript + Jest)
```typescript
import * as pulumi from "@pulumi/pulumi";
pulumi.runtime.setMocks({
    newResource: (args) => ({ id: `${args.name}-id`, state: args.inputs }),
    call: (args) => args.inputs,
});

describe("Infrastructure", () => {
    let infra: typeof import("./index");
    beforeAll(async () => { infra = await import("./index"); });
    test("S3 bucket has versioning", (done) => {
        infra.bucket.versioning.apply(v => { expect(v?.enabled).toBe(true); done(); });
    });
});
```

### Integration Tests
```bash
pulumi up --stack test --yes && pulumi stack output --stack test --json | jq '.bucketName'
curl -s "$(pulumi stack output --stack test endpoint)" && pulumi destroy --stack test --yes
```

## CI/CD Integration (GitHub Actions)

```yaml
name: Pulumi
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
concurrency: { group: pulumi-${{ github.ref }}, cancel-in-progress: false }
permissions: { id-token: write, contents: read, pull-requests: write }
jobs:
  preview:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20', cache: 'npm' }
      - run: npm ci
      - uses: pulumi/actions@v6
        with: { command: preview, stack-name: dev, comment-on-pr: true, diff: true }
        env:
          PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
  deploy:
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20', cache: 'npm' }
      - run: npm ci
      - uses: pulumi/actions@v6
        with: { command: up, stack-name: prod }
        env:
          PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
# See assets/github-actions.template.yml for full template with OIDC, drift detection, multi-stack matrix
```

## Import Existing Resources

```bash
# Import single resource (generates code)
pulumi import aws:s3/bucket:Bucket my-bucket my-existing-bucket-name
# Bulk import from JSON file
pulumi import --file import.json --generate-code=true --out index.ts
```

In code (adopt without re-creating):
```typescript
const existing = new aws.s3.Bucket("imported", {
    bucket: "my-existing-bucket",
}, { import: "my-existing-bucket" });
// After first `pulumi up`, remove the import option
```

## Dynamic Providers

Custom CRUD lifecycle for unsupported resources (TypeScript/Python only):

```typescript
const myProvider: pulumi.dynamic.ResourceProvider = {
    async create(inputs) {
        const id = `resource-${Date.now()}`;
        return { id, outs: { ...inputs, createdAt: new Date().toISOString() } };
    },
    async update(id, olds, news) {
        return { outs: { ...news, updatedAt: new Date().toISOString() } };
    },
    async delete(id, props) { /* call external API */ },
    async read(id, props) { return { id, props }; },
};

class CustomResource extends pulumi.dynamic.Resource {
    public readonly createdAt!: pulumi.Output<string>;
    constructor(name: string, props: Record<string, any>, opts?: pulumi.CustomResourceOptions) {
        super(myProvider, name, { createdAt: undefined, ...props }, opts);
    }
}
```

Note: Dynamic providers do not work with pnpm or Bun runtimes.

## CLI Quick Reference

| Command | Purpose |
|---------|---------|
| `pulumi new <template>` | Scaffold project |
| `pulumi up [--yes]` / `pulumi preview` | Deploy / dry-run |
| `pulumi destroy [--yes]` | Tear down stack |
| `pulumi refresh` | Sync state with cloud |
| `pulumi import <type> <name> <id>` | Import existing resource |
| `pulumi config set [--secret] k v` | Set config/secret |
| `pulumi stack output [--json]` | Get outputs |
| `pulumi cancel` | Cancel in-progress update |
| `pulumi watch` | Continuous deployment mode |
| `pulumi convert --language python` | Convert YAML to code |

## Common Patterns

**Stack references**: `const net = new pulumi.StackReference("org/network/prod"); const vpcId = net.getOutput("vpcId");`

**Protect**: `{ protect: true }` · **Dependencies**: `{ dependsOn: [db] }` · **Retain on delete**: `{ retainOnDelete: true }`

**Aliases** (rename without replace): `{ aliases: [{ name: "old-name" }] }`

**Transforms** (new API — works with packaged components like awsx):
```typescript
pulumi.runtime.registerResourceTransform(args => {
    if (args.props.tags !== undefined) {
        return { props: { ...args.props, tags: { ...args.props.tags, Team: "platform" } }, opts: args.opts };
    }
    return undefined;
});
```

## Skill Resources

### Reference Docs (`references/`)
| File | Topics |
|------|--------|
| `advanced-patterns.md` | Component resources, multi-stack architectures, stack references, dynamic providers, Automation API deep-dive, micro-stacks pattern, resource transforms, aliases |
| `troubleshooting.md` | State management, drift detection, import failures, provider conflicts, dependency resolution, pending operations, stack corruption recovery, 20+ error messages |
| `api-reference.md` | Output/Input types, apply/interpolate, ComponentResource, StackReference, Config, Provider, ResourceOptions (all options), Dynamic Providers, Assets, Logging |
| `cloud-patterns.md` | AWS/Azure/GCP resource patterns, networking, compute, serverless, databases, Kubernetes |

### Scripts (`scripts/`)
| Script | Usage |
|--------|-------|
| `init-project.sh` | `./init-project.sh --name my-infra --runtime nodejs --backend s3 --stack dev` — scaffold project with best practices |
| `stack-ops.sh` | `./stack-ops.sh preview \| up \| destroy \| refresh \| import \| export \| status \| unlock` — safe stack operations with guards |
| `scaffold-pulumi-project.sh` | `./scaffold-pulumi-project.sh --cloud aws --language ts --template vpc --name my-net` — cloud-specific templates |
| `pulumi-ci-setup.sh` | `./pulumi-ci-setup.sh --platform github --cloud aws --stack prod` — generate CI/CD config |
| `pulumi-import-resources.sh` | `./pulumi-import-resources.sh --resource-type s3 --execute` — discover and import AWS resources |

### Templates (`assets/`)
| Template | Purpose |
|----------|---------|
| `Pulumi.yaml.template` | Project file with all options documented |
| `component-resource.template.ts` | TypeScript ComponentResource with typed inputs/outputs |
| `github-actions.template.yml` | CI/CD: PR preview, deploy on merge, drift detection, multi-stack matrix |
| `index.ts` | VPC + ECS Fargate starter template |
| `Pulumi.dev.yaml` | Stack config example with secrets and structured values |
<!-- tested: pass -->
