---
name: pulumi-iac
description:
  positive: "Use when user builds infrastructure with Pulumi, asks about Pulumi programs, component resources, stack references, Pulumi ESC (environments), automation API, or Pulumi with TypeScript/Python/Go."
  negative: "Do NOT use for Terraform (use terraform-aws-patterns skill), CloudFormation, CDK, or Bicep."
---

# Pulumi Infrastructure as Code

## Fundamentals

A Pulumi **program** is code in TypeScript, Python, Go, Java, or C# that declares cloud resources. A **project** is a directory containing `Pulumi.yaml` and program code. A **stack** is an isolated instance of a project (e.g., `dev`, `staging`, `prod`).

**Resources** are the core primitive — each represents a cloud object (S3 bucket, Lambda, VPC). Pulumi tracks CRUD lifecycle automatically.

**Inputs** are values passed to resource constructors. **Outputs** are asynchronous values resolved after provisioning (`pulumi.Output<T>`). Never treat Outputs as plain values — use `.apply()` or `pulumi.all()` to unwrap them.

Export stack outputs with `pulumi.export()` (Python) or `export const` (TypeScript) to expose values for consumption by other stacks or CI/CD.

```typescript
// TypeScript: create a bucket and export its ARN
import * as aws from "@pulumi/aws";

const bucket = new aws.s3.Bucket("data", {
  versioning: { enabled: true },
});

export const bucketArn = bucket.arn;
```

```python
# Python: same pattern
import pulumi
import pulumi_aws as aws

bucket = aws.s3.Bucket("data", versioning={"enabled": True})
pulumi.export("bucket_arn", bucket.arn)
```

## Resource Options

Apply resource options as the last argument to any resource constructor:

- **`dependsOn`** — explicit ordering when Pulumi cannot infer dependency.
- **`protect`** — prevent accidental deletion (`protect: true`).
- **`parent`** — set logical parent for grouping in the resource tree.
- **`provider`** — override which provider instance manages the resource.
- **`aliases`** — preserve state when renaming or refactoring resources.
- **`deleteBeforeReplace`** — force delete-then-create instead of create-then-delete.
- **`ignoreChanges`** — skip drift detection on specified properties.
- **`retainOnDelete`** — remove from state without destroying the cloud resource.

```typescript
const db = new aws.rds.Instance("main", { /* ... */ }, {
  protect: true,
  dependsOn: [vpc],
  ignoreChanges: ["tags"],
});
```

## Component Resources

Use component resources to encapsulate related infrastructure into reusable, self-contained units. Always call `registerOutputs()` at the end.

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

interface VpcArgs {
  cidrBlock: string;
  azCount: number;
}

class Vpc extends pulumi.ComponentResource {
  public readonly vpcId: pulumi.Output<string>;
  public readonly subnetIds: pulumi.Output<string>[];

  constructor(name: string, args: VpcArgs, opts?: pulumi.ComponentResourceOptions) {
    super("custom:network:Vpc", name, {}, opts);

    const vpc = new aws.ec2.Vpc(`${name}-vpc`, {
      cidrBlock: args.cidrBlock,
    }, { parent: this });

    this.vpcId = vpc.id;
    this.subnetIds = [];

    for (let i = 0; i < args.azCount; i++) {
      const subnet = new aws.ec2.Subnet(`${name}-subnet-${i}`, {
        vpcId: vpc.id,
        cidrBlock: `10.0.${i}.0/24`,
      }, { parent: this });
      this.subnetIds.push(subnet.id);
    }

    this.registerOutputs({ vpcId: this.vpcId });
  }
}

const network = new Vpc("prod", { cidrBlock: "10.0.0.0/16", azCount: 3 });
export const vpcId = network.vpcId;
```

```python
import pulumi
import pulumi_aws as aws

class Vpc(pulumi.ComponentResource):
    vpc_id: pulumi.Output[str]

    def __init__(self, name: str, cidr_block: str, az_count: int,
                 opts: pulumi.ResourceOptions = None):
        super().__init__("custom:network:Vpc", name, None, opts)

        vpc = aws.ec2.Vpc(f"{name}-vpc", cidr_block=cidr_block,
                          opts=pulumi.ResourceOptions(parent=self))
        self.vpc_id = vpc.id
        self.subnet_ids = []

        for i in range(az_count):
            subnet = aws.ec2.Subnet(f"{name}-subnet-{i}",
                vpc_id=vpc.id,
                cidr_block=f"10.0.{i}.0/24",
                opts=pulumi.ResourceOptions(parent=self))
            self.subnet_ids.append(subnet.id)

        self.register_outputs({"vpc_id": self.vpc_id})
```

## Stack References

Share outputs across stacks without hardcoding values. The producing stack exports; the consuming stack reads via `StackReference`.

```typescript
// Consumer stack reads from the network stack
const networkStack = new pulumi.StackReference("org/network/prod");
const vpcId = networkStack.getOutput("vpcId");
const privateSubnetIds = networkStack.getOutput("privateSubnetIds");

const cluster = new aws.ecs.Cluster("app", {});
```

```python
network = pulumi.StackReference("org/network/prod")
vpc_id = network.get_output("vpc_id")
```

Design multi-stack architectures in layers: **network → data → compute → app**. Each layer is a separate project/stack. Keep cross-stack surface area minimal — export only what consumers need.

## Configuration and Secrets

Use `pulumi config set` to store per-stack config in `Pulumi.<stack>.yaml`. Access in code:

```typescript
const config = new pulumi.Config();
const instanceType = config.require("instanceType");       // plain
const dbPassword = config.requireSecret("dbPassword");     // encrypted Output
```

```python
config = pulumi.Config()
instance_type = config.require("instanceType")
db_password = config.require_secret("dbPassword")
```

Set secrets via CLI: `pulumi config set --secret dbPassword hunter2`.

### Pulumi ESC (Environments, Secrets, Configuration)

Pulumi ESC centralizes secrets and environment config across stacks and applications. Define environments in YAML with composition via imports:

```yaml
# ESC environment definition
imports:
  - common/base
values:
  region: us-west-2
  dbPassword:
    fn::secret: "super-secure"
environmentVariables:
  AWS_REGION: ${region}
pulumiConfig:
  aws:region: ${region}
  app:dbPassword: ${dbPassword}
```

Link ESC environments to stacks: `pulumi config env add myorg/prod`. ESC integrates with AWS Secrets Manager, Azure Key Vault, GCP Secret Manager, HashiCorp Vault, and 1Password.

Use the `esc` CLI to inject secrets into any command: `esc run myorg/prod -- ./deploy.sh`.

## Providers

Pulumi supports AWS, Azure, GCP, Kubernetes, and 100+ providers. Configure via stack config or explicit provider instances.

```typescript
// Explicit provider for cross-account/region deployments
const usWest = new aws.Provider("us-west", { region: "us-west-2" });
const bucket = new aws.s3.Bucket("west-bucket", {}, { provider: usWest });

// Kubernetes provider from kubeconfig
const k8s = new k8s.Provider("cluster", { kubeconfig: kubeConfigOutput });
```

Use explicit providers when deploying to multiple regions, accounts, or clusters within a single stack. Set default provider config via `pulumi config set aws:region us-east-1`.

## State Management

Pulumi state tracks all managed resources. Backend options:

| Backend | Command | Use Case |
|---------|---------|----------|
| Pulumi Cloud | `pulumi login` (default) | Teams, RBAC, audit, secrets |
| S3 | `pulumi login s3://my-bucket` | Self-managed, AWS-native |
| Azure Blob | `pulumi login azblob://container` | Self-managed, Azure-native |
| Local | `pulumi login --local` | Development only |

Export state: `pulumi stack export > state.json`. Import state: `pulumi stack import < state.json`. Import existing cloud resources: `pulumi import aws:s3/bucket:Bucket myBucket my-bucket-id`.

Never edit state files manually. Use `pulumi state delete` to remove orphaned resources.

## TypeScript Patterns

Use `pulumi.interpolate` for safe string interpolation with Outputs:

```typescript
const url = pulumi.interpolate`https://${lb.dnsName}:${port}/api`;
```

Use `pulumi.all()` to combine multiple Outputs:

```typescript
const connectionString = pulumi.all([db.endpoint, db.port, db.name])
  .apply(([endpoint, port, name]) => `postgresql://${endpoint}:${port}/${name}`);
```

Never create resources inside `.apply()` — it breaks the dependency graph and preview. Pass Outputs directly as resource inputs instead.

Use async/await in the top-level program. Pulumi programs run to completion, building a resource graph, then the engine executes operations.

## Python Patterns

```python
# Output.all for combining values
conn_str = pulumi.Output.all(db.endpoint, db.port, db.name).apply(
    lambda args: f"postgresql://{args[0]}:{args[1]}/{args[2]}"
)

# Output.concat for string joining
url = pulumi.Output.concat("https://", lb.dns_name, "/api")

# Conditional resources
config = pulumi.Config()
if config.get_bool("enableMonitoring"):
    dashboard = aws.cloudwatch.Dashboard("main", dashboard_body="...")
```

Use type hints (`pulumi.Output[str]`) on component resource fields. Use `__all__` in `__init__.py` when packaging components as Python modules.

## Go Patterns

```go
// Component resource in Go
type MyDatabase struct {
    pulumi.ResourceState
    Endpoint pulumi.StringOutput `pulumi:"endpoint"`
    Port     pulumi.IntOutput    `pulumi:"port"`
}

func NewMyDatabase(ctx *pulumi.Context, name string, opts ...pulumi.ResourceOption) (*MyDatabase, error) {
    comp := &MyDatabase{}
    err := ctx.RegisterComponentResource("custom:data:MyDatabase", name, comp, opts...)
    if err != nil {
        return nil, err
    }

    db, err := rds.NewInstance(ctx, name+"-db", &rds.InstanceArgs{
        InstanceClass: pulumi.String("db.t3.micro"),
        Engine:        pulumi.String("postgres"),
    }, pulumi.Parent(comp))
    if err != nil {
        return nil, err
    }

    comp.Endpoint = db.Endpoint
    comp.Port = db.Port
    ctx.RegisterResourceOutputs(comp, pulumi.Map{
        "endpoint": db.Endpoint,
        "port":     db.Port,
    })
    return comp, nil
}
```

Use `ApplyT` for typed transformations. Handle errors explicitly — Go Pulumi programs return `error` from every resource constructor.

## Testing

### Unit Testing with Mocks

Mock the Pulumi engine to test resource creation logic without deploying:

```typescript
import * as pulumi from "@pulumi/pulumi";

pulumi.runtime.setMocks({
  newResource: (args) => ({ id: `${args.name}-id`, state: args.inputs }),
  call: (args) => ({ }),
});

describe("S3 Bucket", () => {
  let bucket: typeof import("./index");
  beforeAll(async () => { bucket = await import("./index"); });

  it("has versioning enabled", (done) => {
    bucket.dataBucket.versioning.apply(v => {
      expect(v?.enabled).toBe(true);
      done();
    });
  });
});
```

```python
# Python unit test with mocks
import pulumi

class MyMocks(pulumi.runtime.Mocks):
    def new_resource(self, args):
        return [args.name + "_id", args.inputs]
    def call(self, args):
        return {}

pulumi.runtime.set_mocks(MyMocks())

from myproject import bucket  # import after setting mocks

@pulumi.runtime.test
def test_versioning():
    def check(versioning):
        assert versioning["enabled"] is True
    return bucket.versioning.apply(check)
```

### Integration Testing

Run `pulumi up` in a test stack, validate deployed resources with cloud SDK calls, then `pulumi destroy`. Use ephemeral stacks for CI.

### Property Testing

Use CrossGuard policy packs (see Policy as Code) to validate resource properties at preview time across all stacks.

## Automation API

Embed Pulumi in applications, CLIs, or services for programmatic infrastructure management:

```typescript
import { LocalWorkspace } from "@pulumi/pulumi/automation";

async function deploy() {
  const stack = await LocalWorkspace.createOrSelectStack({
    stackName: "dev",
    projectName: "my-service",
    program: async () => {
      const bucket = new aws.s3.Bucket("auto-bucket");
      return { bucketName: bucket.id };
    },
  });

  await stack.setConfig("aws:region", { value: "us-west-2" });

  const preview = await stack.preview({ onOutput: console.log });
  console.log(`Changes: ${preview.changeSummary}`);

  const result = await stack.up({ onOutput: console.log });
  console.log(`Outputs: ${JSON.stringify(result.outputs)}`);
}
```

Use cases for Automation API:
- **Self-service portals** — let users provision infrastructure via a web UI.
- **Multi-tenant SaaS** — spin up per-customer stacks programmatically.
- **CI/CD orchestration** — sequence multi-stack deployments with custom logic.
- **Drift detection** — run `stack.preview()` on a schedule and alert on changes.

Use `LocalWorkspace` for file-based projects or inline programs. Use `stack.up()`, `stack.preview()`, `stack.destroy()`, `stack.refresh()` for lifecycle operations.

## Policy as Code (CrossGuard)

Write compliance rules that run during `pulumi preview` and `pulumi up`:

```typescript
import { PolicyPack, validateResourceOfType } from "@pulumi/policy";
import * as aws from "@pulumi/aws";

new PolicyPack("security", {
  policies: [
    {
      name: "s3-no-public-read",
      description: "S3 buckets must not have public-read ACL.",
      enforcementLevel: "mandatory",  // "advisory" | "mandatory" | "disabled"
      validateResource: validateResourceOfType(aws.s3.Bucket, (bucket, args, reportViolation) => {
        if (bucket.acl === "public-read") {
          reportViolation("S3 bucket must not be publicly readable.");
        }
      }),
    },
    {
      name: "require-tags",
      description: "All resources must have a 'team' tag.",
      enforcementLevel: "mandatory",
      validateResource: (args, reportViolation) => {
        if (args.props.tags && !args.props.tags["team"]) {
          reportViolation("Missing required 'team' tag.");
        }
      },
    },
  ],
});
```

Enforcement levels: `advisory` (warn), `mandatory` (block), `disabled`. Run locally: `pulumi preview --policy-pack ./policy`. Publish to Pulumi Cloud for org-wide enforcement.

## Migration from Terraform

### Convert HCL to Pulumi

```bash
# Convert a Terraform project to TypeScript
pulumi convert --from terraform --language typescript

# Or target Python/Go
pulumi convert --from terraform --language python
```

Review and refine generated code — conversion handles most resources but may need manual adjustment for complex modules or provisioners.

### Import Existing Resources

```bash
# Import a single resource
pulumi import aws:s3/bucket:Bucket myBucket my-existing-bucket-name

# Bulk import from Terraform state
pulumi import --from terraform ./terraform.tfstate
```

### Coexistence Strategy

Run Terraform and Pulumi side-by-side during migration. Use Terraform remote state data sources in Pulumi via the `terraform` provider, or read Terraform outputs via stack references. Migrate stack-by-stack: network first, then data, then compute.

## Anti-Patterns

- **Hardcoded names** — Use auto-naming (Pulumi default) or `pulumi.interpolate` with stack/project name. Hardcoded names cause collisions across stacks.
- **Missing stack outputs** — Always export values other stacks or humans need. Silent infrastructure is hard to integrate.
- **Monolithic stacks** — Split stacks by lifecycle and team ownership. A single stack with 500+ resources is slow and risky to deploy.
- **Resources inside `.apply()`** — Breaks the dependency graph, prevents accurate previews, causes race conditions.
- **Secrets in plain config** — Always use `--secret` flag or Pulumi ESC. Never store credentials in `Pulumi.<stack>.yaml` as plaintext.
- **No state backend for teams** — Local state does not support collaboration. Use Pulumi Cloud or a remote backend.
- **Ignoring `protect` for stateful resources** — Databases, storage, and DNS should always set `protect: true`.
- **Copy-paste infrastructure** — Extract repeated patterns into component resources. Duplication leads to config drift.
- **Skipping `pulumi preview`** — Always preview before `up` in CI/CD. Treat preview output as a change plan.

<!-- tested: pass -->
