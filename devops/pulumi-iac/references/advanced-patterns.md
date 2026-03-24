# Advanced Pulumi Patterns

## Table of Contents
- [Component Resources Deep Dive](#component-resources-deep-dive)
- [Multi-Stack Architectures](#multi-stack-architectures)
- [Stack References for Microservices](#stack-references-for-microservices)
- [Dynamic Providers](#dynamic-providers)
- [Resource Transformations](#resource-transformations)
- [Aliases for Refactoring](#aliases-for-refactoring)
- [Protect and Retain for Stateful Resources](#protect-and-retain-for-stateful-resources)
- [Automation API Patterns](#automation-api-patterns)
- [Provider-Side Functions (Invoke)](#provider-side-functions-invoke)
- [Custom Serialization](#custom-serialization)
- [Pulumi ESC (Environments)](#pulumi-esc-environments)

---

## Component Resources Deep Dive

### Nested Components

Components can contain other components, forming a resource tree:

```typescript
class AppStack extends pulumi.ComponentResource {
    constructor(name: string, args: AppArgs, opts?: pulumi.ComponentResourceOptions) {
        super("custom:app:AppStack", name, args, opts);

        const network = new VpcComponent(`${name}-net`, {
            cidrBlock: args.cidrBlock,
        }, { parent: this });

        const db = new DatabaseComponent(`${name}-db`, {
            vpcId: network.vpcId,
            subnetIds: network.privateSubnetIds,
        }, { parent: this });

        const service = new ServiceComponent(`${name}-svc`, {
            vpcId: network.vpcId,
            subnetIds: network.publicSubnetIds,
            dbEndpoint: db.endpoint,
        }, { parent: this });

        this.registerOutputs({
            vpcId: network.vpcId,
            serviceUrl: service.url,
        });
    }
}
```

### Component Design Rules

1. **Always pass `{ parent: this }`** to child resources — builds the resource tree correctly.
2. **Always call `this.registerOutputs()`** — signals completion, enables dependency tracking.
3. **Use a stable type token**: `"company:module:Name"` — never change this after deployment.
4. **Forward resource options**: Pass `opts` to the `super()` constructor so callers can set `provider`, `protect`, etc.
5. **Expose Outputs, not raw values**: All public properties should be `pulumi.Output<T>`.

### Default Child Options

Propagate options to all children automatically:

```typescript
class Vpc extends pulumi.ComponentResource {
    constructor(name: string, args: VpcArgs, opts?: pulumi.ComponentResourceOptions) {
        super("custom:network:Vpc", name, args, opts);
        const defaultOpts = { parent: this, ...opts };
        // All children inherit protect, provider, etc.
        const vpc = new aws.ec2.Vpc(`${name}-vpc`, { ... }, defaultOpts);
    }
}
```

---

## Multi-Stack Architectures

### When to Split Stacks

| Pattern | Use Case |
|---------|----------|
| **Single stack** | Small projects, prototyping |
| **Per-environment** | Same infra across dev/staging/prod |
| **Per-layer** | Network → Data → Compute (independent lifecycles) |
| **Per-service** | Microservices with separate teams |
| **Per-region** | Multi-region deployments |

### Layer Pattern

```
network-stack/     → VPC, subnets, NAT gateways, transit gateways
  ├── data-stack/  → RDS, ElastiCache, S3 buckets
  └── app-stack/   → ECS services, ALBs, Lambda functions
```

Each layer references the one below via StackReference. Destroy order: app → data → network.

### Deployment Orchestration

Use the Automation API for ordered multi-stack deployments:

```typescript
async function deployAll(env: string) {
    const network = await deployStack("network", env);
    const data = await deployStack("data", env, { dependsOn: [network] });
    const app = await deployStack("app", env, { dependsOn: [data] });
}

async function deployStack(name: string, env: string) {
    const stack = await LocalWorkspace.selectStack({
        stackName: `org/${name}/${env}`,
        workDir: path.join(__dirname, name),
    });
    return stack.up({ onOutput: console.log });
}
```

---

## Stack References for Microservices

### Service Discovery Pattern

Each microservice exports its endpoints, ARNs, and security group IDs:

```typescript
// In user-service stack:
export const serviceArn = service.arn;
export const securityGroupId = sg.id;
export const endpoint = pulumi.interpolate`http://${alb.dnsName}/users`;

// In order-service stack:
const userStack = new pulumi.StackReference("org/user-service/prod");
const userEndpoint = userStack.requireOutput("endpoint");
const userSgId = userStack.requireOutput("securityGroupId");

// Allow traffic from order-service to user-service
const ingressRule = new aws.ec2.SecurityGroupRule("user-ingress", {
    securityGroupId: userSgId,
    sourceSecurityGroupId: orderSg.id,
    type: "ingress",
    fromPort: 80,
    toPort: 80,
    protocol: "tcp",
});
```

### Typed Stack References

Wrap StackReference in a helper for type safety:

```typescript
class ServiceRef {
    private ref: pulumi.StackReference;
    constructor(org: string, service: string, env: string) {
        this.ref = new pulumi.StackReference(`${org}/${service}/${env}`);
    }
    get endpoint(): pulumi.Output<string> {
        return this.ref.requireOutput("endpoint") as pulumi.Output<string>;
    }
    get securityGroupId(): pulumi.Output<string> {
        return this.ref.requireOutput("securityGroupId") as pulumi.Output<string>;
    }
}
```

---

## Dynamic Providers

### Full CRUD Example

```typescript
interface GithubRepoInputs { name: string; description: string; private: boolean; }

const githubRepoProvider: pulumi.dynamic.ResourceProvider = {
    async create(inputs: GithubRepoInputs) {
        const resp = await fetch("https://api.github.com/user/repos", {
            method: "POST",
            headers: { Authorization: `token ${process.env.GITHUB_TOKEN}` },
            body: JSON.stringify(inputs),
        });
        const repo = await resp.json();
        return { id: repo.full_name, outs: { htmlUrl: repo.html_url, cloneUrl: repo.clone_url } };
    },
    async read(id: string, props: any) {
        const resp = await fetch(`https://api.github.com/repos/${id}`);
        const repo = await resp.json();
        return { id, props: { ...props, htmlUrl: repo.html_url } };
    },
    async update(id: string, olds: any, news: GithubRepoInputs) {
        await fetch(`https://api.github.com/repos/${id}`, {
            method: "PATCH",
            headers: { Authorization: `token ${process.env.GITHUB_TOKEN}` },
            body: JSON.stringify({ description: news.description, private: news.private }),
        });
        return { outs: { ...olds, description: news.description } };
    },
    async delete(id: string) {
        await fetch(`https://api.github.com/repos/${id}`, {
            method: "DELETE",
            headers: { Authorization: `token ${process.env.GITHUB_TOKEN}` },
        });
    },
    async diff(id: string, olds: any, news: any) {
        const replaces = olds.name !== news.name ? ["name"] : [];
        return { changes: olds.description !== news.description || replaces.length > 0, replaces };
    },
};
```

### When to Use Dynamic Providers

- Internal APIs with no existing Pulumi provider
- SaaS configuration management (Datadog monitors, PagerDuty schedules)
- Custom DNS or certificate management
- Database schema migrations as resources

**Limitations**: TypeScript/JavaScript only. State is serialized as JSON. No automatic diff — implement `diff()` for efficiency.

---

## Resource Transformations

Apply transformations to all resources in a stack:

```typescript
// Tag every resource that supports tags
pulumi.runtime.registerStackTransformation(args => {
    if (args.props.tags !== undefined) {
        args.props.tags = {
            ...args.props.tags,
            ManagedBy: "pulumi",
            Stack: pulumi.getStack(),
            Project: pulumi.getProject(),
        };
    }
    return { props: args.props, opts: args.opts };
});

// Force all S3 buckets to use a specific provider
pulumi.runtime.registerStackTransformation(args => {
    if (args.type === "aws:s3/bucket:Bucket") {
        args.opts.provider = euProvider;
    }
    return { props: args.props, opts: args.opts };
});
```

Use cases: enforce tagging policies, inject providers, add default resource options, audit resource creation.

---

## Aliases for Refactoring

Rename or restructure resources without replacing them:

```typescript
// Moved from flat structure to component
const bucket = new aws.s3.Bucket("data-bucket", { ... }, {
    aliases: [{ name: "data-bucket" }],  // old name
    parent: storageComponent,             // new parent
});

// Renamed module token
class NewVpc extends pulumi.ComponentResource {
    constructor(name: string, args: any, opts?: pulumi.ComponentResourceOptions) {
        super("company:network:Vpc", name, args, {
            ...opts,
            aliases: [{ type: "custom:infra:Vpc" }],  // old type token
        });
    }
}

// Moved resource between parents
const db = new aws.rds.Instance("main-db", { ... }, {
    aliases: [
        { parent: oldParent },           // was under oldParent
        { name: "old-db-name" },          // also had a different name
    ],
});
```

**Rules**: Add aliases when renaming, reparenting, or changing type tokens. Remove aliases after one successful deployment. Test with `pulumi preview` first.

---

## Protect and Retain for Stateful Resources

```typescript
// Protect: prevent accidental deletion via Pulumi
const db = new aws.rds.Instance("prod-db", { ... }, { protect: true });

// RetainOnDelete: keep cloud resource when removed from Pulumi program
const logs = new aws.s3.Bucket("audit-logs", { ... }, { retainOnDelete: true });

// Combine both for critical data stores
const vault = new aws.dynamodb.Table("vault", { ... }, {
    protect: true,
    retainOnDelete: true,
});

// Unprotect when you actually need to destroy
// CLI: pulumi state unprotect urn:pulumi:prod::project::aws:rds/instance:Instance::prod-db
```

**Strategy**: Protect all production databases, storage, and encryption keys. Use retainOnDelete for audit logs and compliance data.

---

## Automation API Patterns

### Self-Service Portal

```typescript
import { LocalWorkspace, Stack } from "@pulumi/pulumi/automation";

async function provisionTenant(tenantId: string, tier: "basic" | "premium") {
    const stack = await LocalWorkspace.createOrSelectStack({
        stackName: tenantId,
        projectName: "multi-tenant",
        program: async () => {
            const config = new pulumi.Config();
            const db = new aws.rds.Instance(`${tenantId}-db`, {
                instanceClass: tier === "premium" ? "db.r6g.xlarge" : "db.t4g.micro",
                allocatedStorage: tier === "premium" ? 100 : 20,
            });
            return { dbEndpoint: db.endpoint };
        },
    });

    await stack.setConfig("aws:region", { value: "us-west-2" });
    const result = await stack.up({ onOutput: console.log });
    return result.outputs;
}
```

### Ephemeral Environments

```typescript
async function createPreviewEnv(prNumber: number) {
    const stackName = `pr-${prNumber}`;
    const stack = await LocalWorkspace.createStack({
        stackName,
        projectName: "preview-envs",
        program: previewProgram,
    });
    const result = await stack.up();
    return result.outputs.url.value;
}

async function destroyPreviewEnv(prNumber: number) {
    const stack = await LocalWorkspace.selectStack({
        stackName: `pr-${prNumber}`,
        projectName: "preview-envs",
        program: previewProgram,
    });
    await stack.destroy();
    await stack.workspace.removeStack(`pr-${prNumber}`);
}
```

---

## Provider-Side Functions (Invoke)

Use `invoke` to call provider functions that read data without creating resources:

```typescript
// Look up existing resources
const vpc = await aws.ec2.getVpc({ default: true });
const ami = await aws.ec2.getAmi({
    mostRecent: true,
    owners: ["amazon"],
    filters: [{ name: "name", values: ["amzn2-ami-hvm-*-x86_64-gp2"] }],
});
const zones = await aws.getAvailabilityZones({ state: "available" });
const callerIdentity = await aws.getCallerIdentity();
const partition = await aws.getPartition();

// Use in resource definitions
const instance = new aws.ec2.Instance("web", {
    ami: ami.id,
    instanceType: "t3.micro",
    subnetId: vpc.id,
    availabilityZone: zones.names[0],
});

// Output-returning variant for use within apply()
const amiOutput = aws.ec2.getAmiOutput({
    mostRecent: true,
    owners: ["amazon"],
    filters: [{ name: "name", values: ["amzn2-ami-hvm-*-x86_64-gp2"] }],
});
```

**Rule**: Use `getX()` (async) at top level, `getXOutput()` (Output-returning) when inputs are Outputs.

---

## Custom Serialization

Control how values are serialized to/from state:

```typescript
// Use JSON-serializable types for stack outputs
export const config = pulumi.output({
    endpoints: {
        api: apiGateway.url,
        web: cdn.domainName,
    },
    versions: {
        api: "v2",
        deployed: new Date().toISOString(),
    },
});

// Transform complex outputs for consumption
export const connectionString = pulumi.all([db.endpoint, db.port, db.name]).apply(
    ([endpoint, port, name]) => `postgresql://app@${endpoint}:${port}/${name}`
);

// Secret outputs stay encrypted in state
export const dbPassword = pulumi.secret(config.requireSecret("dbPassword"));
```

---

## Pulumi ESC (Environments)

Pulumi ESC manages secrets and configuration across stacks and tools:

```yaml
# environments/aws-dev.yaml
values:
  aws:
    login:
      fn::open::aws-login:
        oidc:
          roleArn: arn:aws:iam::123456789:role/pulumi-esc
          sessionName: pulumi-dev
    secrets:
      fn::open::aws-secrets:
        region: us-west-2
        login: ${aws.login}
        get:
          dbPassword:
            secretId: prod/db/password
  environmentVariables:
    AWS_ACCESS_KEY_ID: ${aws.login.accessKeyId}
    AWS_SECRET_ACCESS_KEY: ${aws.login.secretAccessKey}
    AWS_SESSION_TOKEN: ${aws.login.sessionToken}
    DB_PASSWORD: ${aws.secrets.dbPassword}
  pulumiConfig:
    aws:region: us-west-2
    app:dbPassword: ${aws.secrets.dbPassword}
```

### Using ESC in Stacks

```yaml
# Pulumi.dev.yaml
environment:
  - aws-dev       # imports ESC environment
config:
  app:name: my-app
```

### ESC CLI

```bash
esc env init org/aws-dev
esc env set org/aws-dev key value
esc env open org/aws-dev              # retrieve all values
esc run org/aws-dev -- aws s3 ls      # inject env vars into command
```

ESC integrates with: Pulumi stacks, AWS OIDC, Azure OIDC, GCP Workload Identity, Vault, 1Password, local env vars. Use it to eliminate static credentials everywhere.
