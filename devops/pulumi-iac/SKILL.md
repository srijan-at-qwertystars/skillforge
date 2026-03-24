---
name: pulumi-iac
description: >
  Use when writing Pulumi infrastructure-as-code programs, creating/editing Pulumi projects (Pulumi.yaml, Pulumi.*.yaml),
  defining cloud resources with @pulumi/* packages or pulumi SDK imports, configuring stacks, managing state backends,
  writing ComponentResources, using StackReferences, setting up Pulumi Automation API, writing CrossGuard policies,
  importing existing cloud resources with pulumi import, or integrating Pulumi into CI/CD pipelines.
  ALSO USE when user mentions pulumi new, pulumi up, pulumi preview, pulumi destroy, pulumi config, pulumi stack,
  Pulumi ESC, or references pulumi.Input/Output/apply/interpolate types.
  DO NOT USE for Terraform/OpenTofu HCL files, AWS CloudFormation templates, AWS CDK constructs, Ansible playbooks,
  Chef/Puppet recipes, or general cloud CLI commands (aws/az/gcloud) without Pulumi context.
---

# Pulumi Infrastructure as Code

## Philosophy

Pulumi uses real programming languages (TypeScript, Python, Go, C#, Java, YAML) to define cloud infrastructure. No DSL. Use loops, conditionals, functions, classes, packages, and IDE tooling. Infrastructure is code — test, refactor, and review it like application code.

## Project Setup

### Initialize a project
```bash
pulumi new aws-typescript   # scaffolds TS project for AWS
pulumi new azure-python      # Python + Azure
pulumi new gcp-go            # Go + GCP
pulumi new kubernetes-typescript
```

### Project structure
```
my-infra/
+-- Pulumi.yaml          # project metadata (name, runtime, description)
+-- Pulumi.dev.yaml      # stack-specific config
+-- index.ts             # entrypoint (TS) or __main__.py or main.go
+-- components/          # reusable ComponentResources
```

### Pulumi.yaml
```yaml
name: my-infra
runtime: nodejs          # nodejs | python | go | dotnet | java | yaml
description: Core infrastructure
```

### Stacks
```bash
pulumi stack init dev && pulumi stack init prod && pulumi stack select dev && pulumi stack ls
```
Each stack has independent state, config, and secrets. Naming: `org/project/stack`.

## TypeScript/JavaScript Provider Usage

### AWS
```typescript
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

const bucket = new aws.s3.Bucket("my-bucket", {
    versioning: { enabled: true }, tags: { Environment: "dev" },
});
export const bucketName = bucket.id;
```

### Azure
```typescript
import * as azure from "@pulumi/azure-native";
const rg = new azure.resources.ResourceGroup("rg", { location: "WestUS2" });
const sa = new azure.storage.StorageAccount("sa", {
    resourceGroupName: rg.name,
    sku: { name: azure.storage.SkuName.Standard_LRS },
    kind: azure.storage.Kind.StorageV2,
});
```

### GCP
```typescript
import * as gcp from "@pulumi/gcp";
const bucket = new gcp.storage.Bucket("my-bucket", { location: "US", uniformBucketLevelAccess: true });
```

### Kubernetes
```typescript
import * as k8s from "@pulumi/kubernetes";

const deployment = new k8s.apps.v1.Deployment("app", {
    metadata: { namespace: "my-app" },
    spec: {
        replicas: 3,
        selector: { matchLabels: { app: "my-app" } },
        template: {
            metadata: { labels: { app: "my-app" } },
            spec: { containers: [{ name: "app", image: "nginx:1.25", ports: [{ containerPort: 80 }] }] },
        },
    },
});
```

## Python Provider Usage

```python
import pulumi
import pulumi_aws as aws

bucket = aws.s3.Bucket("my-bucket",
    versioning=aws.s3.BucketVersioningArgs(enabled=True),
    tags={"Environment": "dev"})
instance = aws.ec2.Instance("web-server",
    instance_type="t3.micro", ami="ami-0c55b159cbfafe1f0", tags={"Name": "web-server"})
pulumi.export("bucket_name", bucket.id)
pulumi.export("instance_ip", instance.public_ip)
```

## Go Provider Usage

```go
package main
import (
    "github.com/pulumi/pulumi-aws/sdk/v6/go/aws/s3"
    "github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)
func main() {
    pulumi.Run(func(ctx *pulumi.Context) error {
        bucket, err := s3.NewBucket(ctx, "my-bucket", &s3.BucketArgs{
            Tags: pulumi.StringMap{"Environment": pulumi.String("dev")},
        })
        if err != nil { return err }
        ctx.Export("bucketName", bucket.ID())
        return nil
    })
}

## Core Concepts

### Resources
Every cloud object is a resource. Args: logical name (unique per stack), properties, resource options.
```typescript
const vpc = new aws.ec2.Vpc("main-vpc", { cidrBlock: "10.0.0.0/16" }, { protect: true, ignoreChanges: ["tags"] });
```
Options: `parent`, `dependsOn`, `protect`, `ignoreChanges`, `provider`, `deleteBeforeReplace`, `aliases`, `import`, `retainOnDelete`.

### Outputs and Inputs
Outputs are values resolved asynchronously after deployment. Inputs accept raw values or Outputs.

```typescript
const bucketArn = bucket.arn;                           // Output<string>
const upperName = bucket.id.apply(id => id.toUpperCase());
const endpoint = pulumi.interpolate`https://${bucket.bucketDomainName}/index.html`;
const combined = pulumi.all([bucket.id, bucket.arn]).apply(([id, arn]) => `${id}: ${arn}`);
```

**Critical rule**: Never call `.apply()` to create new resources -- causes ordering issues. Pass outputs directly as inputs instead.

- `apply(fn)`: transform an output value. Use when you need logic beyond string concatenation.
- `interpolate`: tagged template literal for string building with outputs. Prefer for simple string composition.

## Stack References

Share outputs across stacks:
```typescript
const networkStack = new pulumi.StackReference("org/network-infra/dev");
const vpcId = networkStack.getOutput("vpcId");          // Output<any>
const subnetId = networkStack.requireOutput("subnetId"); // throws if missing
const instance = new aws.ec2.Instance("app", {
    subnetId, vpcSecurityGroupIds: [networkStack.getOutput("sgId")],
    instanceType: "t3.micro", ami: "ami-0c55b159cbfafe1f0",
});
```
Format: `org/project/stack` or `project/stack` for personal orgs.

## Component Resources

Build reusable abstractions by extending `ComponentResource`:
```typescript
interface VpcArgs { cidrBlock: string; azCount: number; }

class Vpc extends pulumi.ComponentResource {
    public readonly vpcId: pulumi.Output<string>;
    public readonly subnetIds: pulumi.Output<string>[];

    constructor(name: string, args: VpcArgs, opts?: pulumi.ComponentResourceOptions) {
        super("custom:network:Vpc", name, args, opts);
        const vpc = new aws.ec2.Vpc(`${name}-vpc`, {
            cidrBlock: args.cidrBlock, enableDnsSupport: true, enableDnsHostnames: true,
        }, { parent: this });
        this.vpcId = vpc.id;
        this.subnetIds = [];
        for (let i = 0; i < args.azCount; i++) {
            const subnet = new aws.ec2.Subnet(`${name}-subnet-${i}`, {
                vpcId: vpc.id, cidrBlock: `10.0.${i}.0/24`,
            }, { parent: this });
            this.subnetIds.push(subnet.id);
        }
        this.registerOutputs({ vpcId: this.vpcId });
    }
}

// Usage
const network = new Vpc("prod", { cidrBlock: "10.0.0.0/16", azCount: 3 });
```

Always pass `{ parent: this }` to child resources. Always call `this.registerOutputs()`.

## Config and Secrets

### CLI
```bash
pulumi config set aws:region us-east-1
pulumi config set appName my-app
pulumi config set --secret dbPassword S3cretP@ss!
pulumi config set --secret apiKey sk-abc123
```

### Code
```typescript
const config = new pulumi.Config();
const appName = config.require("appName");              // throws if missing
const dbPassword = config.requireSecret("dbPassword");  // Output<string>, encrypted
const optional = config.get("optional") ?? "default";
const awsConfig = new pulumi.Config("aws");             // namespaced config
const region = awsConfig.require("region");
```

### Secrets providers
```bash
pulumi stack init dev --secrets-provider="awskms://alias/pulumi"       # AWS KMS
pulumi stack init dev --secrets-provider="azurekeyvault://vault.vault.azure.net/keys/k"
pulumi stack init dev --secrets-provider="gcpkms://projects/p/locations/l/keyRings/r/cryptoKeys/k"
pulumi stack init dev --secrets-provider="passphrase"                  # local passphrase
```

## State Backends

```bash
pulumi login                          # Pulumi Cloud (default, recommended)
pulumi login s3://my-pulumi-state     # AWS S3
pulumi login azblob://my-container    # Azure Blob Storage
pulumi login gs://my-pulumi-state     # Google Cloud Storage
pulumi login --local                  # Local filesystem
```
State maps logical names to cloud IDs. Never edit manually. Use `pulumi state delete` or `pulumi state unprotect`.

## Providers
### Explicit provider configuration
```typescript
const euProvider = new aws.Provider("eu-provider", { region: "eu-west-1", profile: "eu-account" });
const bucket = new aws.s3.Bucket("eu-bucket", { tags: { Region: "eu" } }, { provider: euProvider });
```

### Multi-cloud in one program
```typescript
const awsBucket = new aws.s3.Bucket("aws-bucket");
const gcpBucket = new gcp.storage.Bucket("gcp-bucket", { location: "US" });
```

### Default providers
If no explicit provider, Pulumi uses the default configured via env vars or `pulumi config set aws:region`.

## Dynamic Providers

Create custom resources with arbitrary CRUD logic:
```typescript
const myResourceProvider: pulumi.dynamic.ResourceProvider = {
    async create(inputs) {
        const result = await callExternalApi(inputs.name);
        return { id: result.id, outs: { endpoint: result.endpoint } };
    },
    async update(id, olds, news) {
        return { outs: { endpoint: (await updateExternalApi(id, news.name)).endpoint } };
    },
    async delete(id, props) { await deleteExternalApi(id); },
};

class MyResource extends pulumi.dynamic.Resource {
    public readonly endpoint!: pulumi.Output<string>;
    constructor(name: string, args: { name: string }, opts?: pulumi.CustomResourceOptions) {
        super(myResourceProvider, name, { endpoint: undefined, ...args }, opts);
    }
}
```

Use dynamic providers for resources not covered by existing providers (internal APIs, SaaS integrations).

## Policy as Code (CrossGuard)

```typescript
import { PolicyPack, validateResourceOfType } from "@pulumi/policy";
import * as aws from "@pulumi/aws";

new PolicyPack("aws-security", {
    policies: [{
        name: "no-public-s3",
        description: "S3 buckets must not have public ACLs",
        enforcementLevel: "mandatory",  // "advisory" | "mandatory" | "disabled"
        validateResource: validateResourceOfType(aws.s3.Bucket, (bucket, args, reportViolation) => {
            if (bucket.acl === "public-read" || bucket.acl === "public-read-write") {
                reportViolation("S3 bucket must not be publicly readable.");
            }
        }),
    }, {
        name: "require-tags",
        description: "All resources must have required tags",
        enforcementLevel: "mandatory",
        validateResource: (args, reportViolation) => {
            if (args.props.tags && !args.props.tags["CostCenter"]) {
                reportViolation("Resource must have a CostCenter tag.");
            }
        },
    }],
});
```

### Run policies
```bash
pulumi preview --policy-pack ./policy-pack
pulumi up --policy-pack ./policy-pack
```

## Testing

### Unit tests (TypeScript with mocks)
```typescript
import * as pulumi from "@pulumi/pulumi";

pulumi.runtime.setMocks({
    newResource: (args: pulumi.runtime.MockResourceArgs) => ({
        id: `${args.name}-id`, state: args.inputs,
    }),
    call: (args: pulumi.runtime.MockCallArgs) => args.inputs,
});

describe("infrastructure", () => {
    let infra: typeof import("./index");
    beforeAll(async () => { infra = await import("./index"); });

    it("bucket should have versioning enabled", (done) => {
        infra.bucket.versioning.apply(v => { expect(v?.enabled).toBe(true); done(); });
    });
});
```

### Unit tests (Python with mocks)
```python
import pulumi
class MyMocks(pulumi.runtime.Mocks):
    def new_resource(self, args): return [args.name + "_id", args.inputs]
    def call(self, args): return {}
pulumi.runtime.set_mocks(MyMocks())
from my_infra import bucket  # import after setting mocks
@pulumi.runtime.test
def test_bucket_tags():
    def check_tags(tags): assert "Environment" in tags
    return bucket.tags.apply(check_tags)
```

### Integration tests
Use the Automation API to deploy real infrastructure and run assertions:
```typescript
const stack = await LocalWorkspace.createOrSelectStack({
    stackName: "test", projectName: "integration-test",
    program: async () => { /* inline program */ },
});
await stack.up();
const outputs = await stack.outputs();
assert(outputs["url"].value.startsWith("https://"));
await stack.destroy();
```

## Import Existing Resources

```bash
pulumi import aws:s3/bucket:Bucket my-bucket my-existing-bucket-name
pulumi import aws:ec2/instance:Instance web i-1234567890abcdef0
pulumi import -f resources.json                                      # bulk import
pulumi import aws:s3/bucket:Bucket my-bucket my-bucket-name --out index.ts  # code-gen only
```

After import, paste generated code into your program. Import in code with resource options:
```typescript
const bucket = new aws.s3.Bucket("my-bucket", {
    bucket: "my-existing-bucket-name",
}, { import: "my-existing-bucket-name" });  // remove after first pulumi up
```

## Automation API

Drive Pulumi programmatically without the CLI:
```typescript
import { LocalWorkspace } from "@pulumi/pulumi/automation";
const program = async () => {
    const bucket = new aws.s3.Bucket("auto-bucket");
    return { bucketName: bucket.id };
};
const stack = await LocalWorkspace.createOrSelectStack({
    stackName: "dev", projectName: "auto-deploy", program,
});
await stack.setConfig("aws:region", { value: "us-west-2" });
const upResult = await stack.up({ onOutput: console.log });
```
Use cases: self-service portals, multi-tenant provisioning, integration tests. See `references/advanced-patterns.md` for patterns.

## CI/CD Integration

### GitHub Actions
```yaml
name: Pulumi
on: { push: { branches: [main] }, pull_request: {} }
jobs:
  preview:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20" }
      - run: npm ci
      - uses: pulumi/actions@v5
        with: { command: preview, stack-name: org/project/dev, comment-on-pr: true }
        env: { PULUMI_ACCESS_TOKEN: "${{ secrets.PULUMI_ACCESS_TOKEN }}" }
  deploy:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20" }
      - run: npm ci
      - uses: pulumi/actions@v5
        with: { command: up, stack-name: org/project/prod }
        env: { PULUMI_ACCESS_TOKEN: "${{ secrets.PULUMI_ACCESS_TOKEN }}" }
```

See `assets/github-actions-pulumi.yml` for a production-grade version with OIDC, drift detection, and multi-env matrix.

### GitLab CI
```yaml
pulumi-preview:
  stage: preview
  image: pulumi/pulumi-nodejs:latest
  script: [npm ci, pulumi stack select dev, pulumi preview]
  only: [merge_requests]
pulumi-deploy:
  stage: deploy
  image: pulumi/pulumi-nodejs:latest
  script: [npm ci, pulumi stack select prod, pulumi up --yes]
  only: [main]
```

## Pulumi vs Terraform

Real languages vs HCL DSL. Pulumi: native loops/conditionals, standard test frameworks, built-in secret encryption, full IDE support, classes/functions/packages for reuse. Terraform: larger provider ecosystem (3000+ vs 150+). Pulumi bridges Terraform providers. Migrate with `pulumi convert --from terraform`.

## Common Pitfalls

**Circular dependencies**: Never create resource A depending on B which depends on A. Use `dependsOn` only when implicit Output dependencies are insufficient.

**Using apply() to create resources**: Do NOT create resources inside `.apply()`. Pass Outputs directly as inputs.
```typescript
// WRONG
bucket.id.apply(id => new aws.s3.BucketObject("obj", { bucket: id }));
// CORRECT
new aws.s3.BucketObject("obj", { bucket: bucket.id, key: "index.html", source: new pulumi.asset.FileAsset("index.html") });
```

**Secret leakage**: Use `config.requireSecret()` for sensitive values. Use `pulumi.secret()` to mark outputs. Never log secret values.

**State drift**: Run `pulumi refresh` to detect drift. Use `pulumi up --refresh` to refresh and update in one step.

**Naming collisions**: Pulumi auto-names with random suffixes. Set explicit names but ensure uniqueness across stacks.

**Forgetting registerOutputs**: Always call `this.registerOutputs()` in ComponentResource constructors.

**Import cleanup**: Remove `{ import: "..." }` from resource options after the first `pulumi up`.

## Additional Resources

### References

In-depth guides in `references/`:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Component deep dive, multi-stack architectures, stack references for microservices, dynamic providers, resource transformations, aliases, protect/retain, Automation API, provider invoke, Pulumi ESC.
- **[troubleshooting.md](references/troubleshooting.md)** — Dependency cycles, state corruption, import failures, provider conflicts, secret decryption, pending operations, refresh vs up, safe replacements, API throttling, verbose debugging.
- **[aws-patterns.md](references/aws-patterns.md)** — VPC, ECS Fargate, Lambda + API Gateway, S3 + CloudFront, RDS + Secrets Manager, IAM patterns, cross-account, EKS + IRSA, Step Functions.

### Scripts

Operational scripts in `scripts/` (all executable):

- **[init-project.sh](scripts/init-project.sh)** — Initialize Pulumi project with `--lang` (ts/py/go/csharp/yaml) and `--cloud` (aws/azure/gcp/k8s).
- **[stack-manager.sh](scripts/stack-manager.sh)** — Stack lifecycle: create, list, select, destroy, export/import state, clone/diff config.
- **[drift-detector.sh](scripts/drift-detector.sh)** — Detect drift via `pulumi refresh --diff`. JSON output, CI fail-on-drift, Slack webhooks.

### Assets

Starter templates in `assets/`:

- **[Pulumi.yaml](assets/Pulumi.yaml)** — Annotated project file with typed config schema and backend options.
- **[index.ts](assets/index.ts)** — TypeScript starter: VPC, security groups, ECS Fargate + ALB, RDS PostgreSQL.
- **[github-actions-pulumi.yml](assets/github-actions-pulumi.yml)** — CI/CD: preview on PR, deploy on merge, OIDC auth, drift checks.
- **[component-template.ts](assets/component-template.ts)** — Reusable ComponentResource template (WebService) with full lifecycle.
<!-- tested: pass -->
