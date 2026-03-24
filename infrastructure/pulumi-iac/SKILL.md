---
name: pulumi-iac
description: >
  Use when writing infrastructure as code with Pulumi, provisioning cloud resources with
  TypeScript/Python/Go/C#, managing AWS/Azure/GCP/Kubernetes infrastructure programmatically,
  creating reusable component resources, using Pulumi Automation API, importing existing cloud
  resources into Pulumi, writing CrossGuard policies, configuring Pulumi stacks and secrets,
  or testing Pulumi infrastructure code.
  Do NOT use for Terraform HCL, CloudFormation YAML/JSON, Ansible playbooks, CDK for Terraform
  (CDKTF), AWS CDK, general cloud console operations, or Kubernetes manifests without Pulumi.
---

# Pulumi Infrastructure as Code

## Installation and Project Setup

Install the Pulumi CLI:

```bash
curl -fsSL https://get.pulumi.com | sh   # Linux/macOS
brew install pulumi/tap/pulumi            # macOS Homebrew
```

Create a new project from a template:

```bash
pulumi new aws-typescript     # AWS + TypeScript
pulumi new azure-python       # Azure + Python
pulumi new gcp-go             # GCP + Go
pulumi new kubernetes-csharp  # Kubernetes + C#
```

Use `pulumi new --list-templates` to see all templates. Pass `--name`, `--description`, `--stack` to skip prompts in CI.

Project structure after `pulumi new aws-typescript`:

```
├── Pulumi.yaml         # Project metadata (name, runtime, description)
├── Pulumi.dev.yaml     # Stack-specific config
├── index.ts            # Infrastructure code entry point
├── package.json / tsconfig.json
```

## Core Concepts

**Project**: Defined by `Pulumi.yaml`. Contains runtime, name, description, and backend config.

**Stack**: An isolated instance of a project (e.g., `dev`, `staging`, `prod`). Each has its own state and config in `Pulumi.<stack>.yaml`.

**Resource**: The fundamental unit — every cloud object is a resource with inputs and outputs.

**Inputs**: Arguments to resource constructors. Can be raw values or `Output<T>` from other resources (creating implicit dependencies).

**Outputs**: Values produced after creation (IDs, ARNs, endpoints). Use `pulumi.export()` to surface them.

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

const bucket = new aws.s3.Bucket("data-bucket", {
    versioning: { enabled: true },
    tags: { Environment: pulumi.getStack() },
});

// Output chaining — creates implicit dependency
const bucketPolicy = new aws.s3.BucketPolicy("policy", {
    bucket: bucket.id,  // Output<string> — Pulumi resolves order automatically
    policy: bucket.arn.apply(arn => JSON.stringify({
        Version: "2012-10-17",
        Statement: [{ Effect: "Allow", Principal: "*", Action: "s3:GetObject", Resource: `${arn}/*` }],
    })),
});

export const bucketName = bucket.id;
export const bucketArn = bucket.arn;
```

Python equivalent:

```python
import pulumi
import pulumi_aws as aws

bucket = aws.s3.Bucket("data-bucket",
    versioning=aws.s3.BucketVersioningArgs(enabled=True),
    tags={"Environment": pulumi.get_stack()},
)

pulumi.export("bucket_name", bucket.id)
```

## Resource Providers

Install provider SDKs via the language package manager:

```bash
npm install @pulumi/aws @pulumi/azure-native @pulumi/gcp @pulumi/kubernetes @pulumi/docker  # TS/JS
pip install pulumi-aws pulumi-azure-native pulumi-gcp pulumi-kubernetes pulumi-docker        # Python
go get github.com/pulumi/pulumi-aws/sdk/v6/go/aws                                           # Go
```

Use `@pulumi/azure-native` (not `@pulumi/azure`) for full Azure Resource Manager coverage. Use explicit provider instances when managing multiple accounts or regions:

```typescript
const euProvider = new aws.Provider("eu-provider", { region: "eu-west-1" });
const euBucket = new aws.s3.Bucket("eu-bucket", {}, { provider: euProvider });
```

## Configuration and Secrets

Set config values per stack:

```bash
pulumi config set appName myapp
pulumi config set --secret dbPassword s3cretP@ss
pulumi config set aws:region us-west-2
```

Access in code:

```typescript
const config = new pulumi.Config();
const appName = config.require("appName");             // Fails if missing
const dbPassword = config.requireSecret("dbPassword"); // Returns Output<string>
const optional = config.get("featureFlag") ?? "default";
const awsConfig = new pulumi.Config("aws");            // Namespaced provider config
```

```python
config = pulumi.Config()
app_name = config.require("appName")
db_password = config.require_secret("dbPassword")
```

**Pulumi ESC (Environments, Secrets, Configuration)**: Centralized secrets/config management. Define environments in Pulumi Cloud, compose them hierarchically, and inject into stacks or shell sessions:

```bash
pulumi config env add my-org/production    # Attach ESC environment to stack
esc env open my-org/production             # Open environment in shell
```

Secrets providers: Pulumi Cloud (default), AWS KMS, Azure Key Vault, GCP KMS, HashiCorp Vault:

```bash
pulumi stack init prod --secrets-provider="awskms://alias/pulumi-secrets?region=us-east-1"
```

## Stack References and Cross-Stack Dependencies

Share outputs between stacks using `StackReference`:

```typescript
// In the consuming stack
const networkStack = new pulumi.StackReference("org/network-project/prod");
const vpcId = networkStack.getOutput("vpcId");           // Output<any>
const subnetIds = networkStack.getOutput("subnetIds");   // Output<any>
const secret = networkStack.getOutput("dbPassword");     // Automatically decrypted if secret
```

```python
network_stack = pulumi.StackReference("org/network-project/prod")
vpc_id = network_stack.get_output("vpc_id")
```

## Component Resources

Create reusable abstractions by extending `pulumi.ComponentResource`:

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

interface StaticSiteArgs {
    indexDocument?: string;
    errorDocument?: string;
}

class StaticSite extends pulumi.ComponentResource {
    public readonly bucketName: pulumi.Output<string>;
    public readonly websiteUrl: pulumi.Output<string>;

    constructor(name: string, args: StaticSiteArgs, opts?: pulumi.ComponentResourceOptions) {
        super("custom:web:StaticSite", name, {}, opts);

        const bucket = new aws.s3.Bucket(`${name}-bucket`, {
            website: {
                indexDocument: args.indexDocument ?? "index.html",
                errorDocument: args.errorDocument ?? "error.html",
            },
        }, { parent: this });

        this.bucketName = bucket.id;
        this.websiteUrl = bucket.websiteEndpoint;
        this.registerOutputs({ bucketName: this.bucketName, websiteUrl: this.websiteUrl });
    }
}

const site = new StaticSite("my-site", { indexDocument: "index.html" });
export const url = site.websiteUrl;
```

Always pass `{ parent: this }` for child resources. Call `this.registerOutputs()` at the end.

## Dynamic Providers

Implement custom resource lifecycles when no native provider exists:

```typescript
const myProvider: pulumi.dynamic.ResourceProvider = {
    async create(inputs) {
        const id = await callExternalApi(inputs);
        return { id, outs: { endpoint: `https://api.example.com/${id}` } };
    },
    async update(id, olds, news) { return { outs: news }; },
    async delete(id, props) { await deleteExternalApi(id); },
    async read(id, props) { return { id, props }; },
};
const res = new pulumi.dynamic.Resource("custom-res", myProvider, { endpoint: "" });
```

Implement CRUD methods. Dynamic providers run in-process and are language-specific.

## Import Existing Infrastructure

Import via CLI — Pulumi generates the code snippet:

```bash
pulumi import aws:s3/bucket:Bucket my-bucket my-existing-bucket-name
pulumi import aws:ec2/instance:Instance web-server i-0abc123def456
pulumi import --file resources.json   # Bulk import
```

Import via code with the `import` resource option:

```typescript
const bucket = new aws.s3.Bucket("imported-bucket", {
    bucket: "my-existing-bucket-name",
}, { import: "my-existing-bucket-name" });
// After successful `pulumi up`, remove the import option
```

Always run `pulumi preview` after import to verify no diffs. Remove `import` option after adoption.

## Policy as Code (CrossGuard)

Write compliance policies in TypeScript or Python:

```typescript
// policy-pack/index.ts
import { PolicyPack, validateResourceOfType } from "@pulumi/policy";
import * as aws from "@pulumi/aws";

new PolicyPack("aws-best-practices", {
    policies: [{
        name: "no-public-s3",
        description: "S3 buckets must not have public ACLs.",
        enforcementLevel: "mandatory",  // "advisory" | "mandatory" | "remediate"
        validateResource: validateResourceOfType(aws.s3.Bucket, (bucket, args, reportViolation) => {
            if (bucket.acl === "public-read" || bucket.acl === "public-read-write") {
                reportViolation("S3 buckets must not be public.");
            }
        }),
    }, {
        name: "require-tags",
        description: "All resources must have required tags.",
        enforcementLevel: "mandatory",
        validateResource: (args, reportViolation) => {
            if (args.props.tags && !args.props.tags["CostCenter"]) {
                reportViolation("Missing required 'CostCenter' tag.");
            }
        },
    }],
});
```

Run policies locally: `pulumi preview --policy-pack ./policy-pack`. Publish to Pulumi Cloud for org-wide enforcement.

## Testing Infrastructure

**Unit tests** — mock the Pulumi engine, test resource properties:

```typescript
import * as pulumi from "@pulumi/pulumi";
pulumi.runtime.setMocks({
    newResource: (args) => ({ id: `${args.name}-id`, state: args.inputs }),
    call: (args) => args.inputs,
});

describe("S3 bucket", () => {
    let infra: typeof import("../index");
    beforeAll(async () => { infra = await import("../index"); });
    it("should have versioning enabled", (done) => {
        pulumi.all([infra.bucketName]).apply(([name]) => { expect(name).toBeDefined(); done(); });
    });
});
```

**Property tests**: Use CrossGuard `validateStack` to assert global invariants. **Integration tests**: Run `pulumi up` in a test stack, assert outputs, then `pulumi destroy`.

## State Management

Configure the backend where state is stored:

```bash
pulumi login                              # Pulumi Cloud (default)
pulumi login s3://my-state-bucket         # AWS S3
pulumi login azblob://my-container        # Azure Blob
pulumi login gs://my-state-bucket         # GCP GCS
pulumi login file://~/.pulumi-state       # Local filesystem
```

Set via `PULUMI_BACKEND_URL` for CI. Pulumi Cloud provides state locking, audit history, RBAC, and drift detection.

## CI/CD Integration

**GitHub Actions**:

```yaml
name: Pulumi
on: [push]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20" }
      - run: npm ci
      - uses: pulumi/actions@v6
        with:
          command: up
          stack-name: org/prod
        env:
          PULUMI_ACCESS_TOKEN: ${{ secrets.PULUMI_ACCESS_TOKEN }}
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

Use `command: preview` on PRs, `command: up` on merge to main. **Pulumi Deployments**: Managed CI/CD from Pulumi Cloud — configure via UI or `pulumi deployment run`.

## Automation API

Embed Pulumi in applications — build custom CLIs, platforms, self-service portals:

```typescript
import { LocalWorkspace } from "@pulumi/pulumi/automation";
import * as aws from "@pulumi/aws";

const program = async () => {
    const bucket = new aws.s3.Bucket("auto-bucket");
    return { bucketName: bucket.id };
};

async function deploy() {
    const stack = await LocalWorkspace.createOrSelectStack({
        stackName: "dev", projectName: "automation-project", program,
    });
    await stack.setConfig("aws:region", { value: "us-west-2" });
    const result = await stack.up({ onOutput: console.log });
    console.log("Outputs:", result.outputs);
}

async function teardown() {
    const stack = await LocalWorkspace.selectStack({
        stackName: "dev", projectName: "automation-project", program,
    });
    await stack.destroy({ onOutput: console.log });
}
```

Use `LocalWorkspace` for file-based projects or inline programs. Use `RemoteWorkspace` for Pulumi Deployments.

## Common Patterns

**VPC with public/private subnets (AWS)**:

```typescript
import * as awsx from "@pulumi/awsx";
const vpc = new awsx.ec2.Vpc("app-vpc", {
    cidrBlock: "10.0.0.0/16",
    numberOfAvailabilityZones: 3,
    natGateways: { strategy: awsx.ec2.NatGatewayStrategy.Single },
});
export const vpcId = vpc.vpcId;
export const privateSubnetIds = vpc.privateSubnetIds;
```

**EKS cluster**:

```typescript
import * as eks from "@pulumi/eks";
const cluster = new eks.Cluster("my-cluster", {
    vpcId: vpc.vpcId, subnetIds: vpc.privateSubnetIds,
    instanceType: "t3.medium", desiredCapacity: 3, minSize: 2, maxSize: 5,
});
export const kubeconfig = cluster.kubeconfig;
```

**Serverless / Static Site / RDS**: See [`references/cloud-patterns.md`](references/cloud-patterns.md) for full production-ready patterns with Lambda + API Gateway, S3 + CloudFront, RDS with read replicas, GKE, and Azure Container Apps.

## Transformations and Aliases

**Transformations** modify resource properties globally:

```typescript
pulumi.runtime.registerStackTransformation((args) => {
    if (args.type === "aws:s3/bucket:Bucket") {
        args.props["tags"] = { ...args.props["tags"], ManagedBy: "Pulumi" };
        return { props: args.props, opts: args.opts };
    }
});
```

**Aliases** prevent resource replacement during refactors (rename, reparent, retype):

```typescript
const bucket = new aws.s3.Bucket("new-name", {}, {
    aliases: [{ name: "old-name" }],
});
```

## Essential CLI Commands

```bash
# Lifecycle
pulumi up                          # Deploy changes (preview + apply)
pulumi up --yes --skip-preview     # Non-interactive deploy (CI)
pulumi preview                     # Show planned changes without applying
pulumi destroy                     # Tear down all resources in a stack
pulumi refresh                     # Sync state with actual cloud state

# Stack management
pulumi stack init <name>           # Create a new stack
pulumi stack select <name>         # Switch active stack
pulumi stack ls                    # List all stacks
pulumi stack output                # Show stack outputs
pulumi stack export / import       # Export/import state as JSON
pulumi stack rm <name>             # Delete a stack

# Config
pulumi config set <key> <value>    # Set plain config
pulumi config set --secret <key> <value>  # Set encrypted secret
pulumi config get <key>            # Read config value

# Debugging
pulumi logs                        # Stream cloud logs (Lambda, Functions)
pulumi about                       # Show environment info
```

Set `PULUMI_CONFIG_PASSPHRASE` for self-managed backend encryption. Use `--diff` with `pulumi up` or `preview` for detailed change diffs. Use `--target urn` to operate on specific resources. Use `--replace urn` to force resource replacement.

## Reference Documentation

Deep-dive guides for advanced topics:

| Reference | Description |
|-----------|-------------|
| [`references/advanced-patterns.md`](references/advanced-patterns.md) | Multi-stack architectures, component resource design, dynamic providers, Automation API, stack transformations, resource aliases, provider configuration, Pulumi ESC, micro-stacks vs mono-stack, reusable packages, cross-language components |
| [`references/troubleshooting.md`](references/troubleshooting.md) | State conflicts/repair, import failures, drift detection, dependency cycles, preview vs up discrepancies, secret decryption errors, provider version conflicts, resource replacement decisions, performance with large stacks |
| [`references/cloud-patterns.md`](references/cloud-patterns.md) | Production-ready patterns with full TypeScript code: VPC, EKS, serverless API, static website, RDS with replicas, multi-region, GKE, Azure Container Apps |

## Helper Scripts

Executable scripts for common Pulumi workflows:

| Script | Usage | Description |
|--------|-------|-------------|
| [`scripts/scaffold-pulumi-project.sh`](scripts/scaffold-pulumi-project.sh) | `./scaffold-pulumi-project.sh --cloud aws --language ts --template vpc --name my-infra` | Scaffolds a complete Pulumi project with all boilerplate (Pulumi.yaml, config, .gitignore, starter code) |
| [`scripts/pulumi-import-resources.sh`](scripts/pulumi-import-resources.sh) | `./pulumi-import-resources.sh --resource-type ec2 --stack dev` | Discovers existing AWS resources and generates/executes `pulumi import` commands interactively |
| [`scripts/pulumi-ci-setup.sh`](scripts/pulumi-ci-setup.sh) | `./pulumi-ci-setup.sh --platform github --stack prod --cloud aws` | Generates CI/CD pipeline config (GitHub Actions or GitLab CI) with preview on PR and deploy on merge |

## Asset Templates

Ready-to-use project templates and config files:

| Asset | Description |
|-------|-------------|
| [`assets/Pulumi.yaml`](assets/Pulumi.yaml) | Project config template with recommended backend, tags, and runtime settings |
| [`assets/Pulumi.dev.yaml`](assets/Pulumi.dev.yaml) | Stack config template showing secrets, typed config, and provider settings |
| [`assets/index.ts`](assets/index.ts) | TypeScript starter: VPC + ECS Fargate + ALB with config-driven parameters |
| [`assets/github-actions-pulumi.yml`](assets/github-actions-pulumi.yml) | GitHub Actions workflow with OIDC auth, PR preview comments, and deploy on merge |
