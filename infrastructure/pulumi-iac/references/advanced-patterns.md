---
title: "Pulumi Advanced Patterns Reference"
description: "Deep-dive guide covering multi-stack architectures, component resources, dynamic providers, Automation API, and other advanced Pulumi patterns."
version: "1.0"
last_updated: "2025-01-15"
audience: "Platform engineers and infrastructure teams using Pulumi at scale"
language: "TypeScript (unless noted otherwise)"
---

# Pulumi Advanced Patterns Reference

## Table of Contents

- [1. Multi-Stack Architectures](#1-multi-stack-architectures)
- [2. Component Resource Design](#2-component-resource-design)
- [3. Dynamic Providers (Custom CRUD)](#3-dynamic-providers-custom-crud)
- [4. Automation API Patterns](#4-automation-api-patterns)
- [5. Stack Transformations](#5-stack-transformations)
- [6. Resource Aliases for Refactoring](#6-resource-aliases-for-refactoring)
- [7. Provider Configuration](#7-provider-configuration)
- [8. Pulumi ESC (Environments, Secrets, Config)](#8-pulumi-esc-environments-secrets-config)
- [9. Micro-Stacks vs Mono-Stack Trade-offs](#9-micro-stacks-vs-mono-stack-trade-offs)
- [10. Reusable Infrastructure Packages](#10-reusable-infrastructure-packages)
- [11. Cross-Language Components](#11-cross-language-components)

---

## 1. Multi-Stack Architectures

Split stacks when different infrastructure layers have distinct lifecycle cadences,
ownership boundaries, or blast-radius requirements. A network layer changes rarely;
application deployments happen daily. Coupling them means every app deploy reconciles
the entire network state, slowing feedback and increasing risk.

**Naming convention**: `<org>/<project>/<stack>` — e.g. `acme/network/prod`,
`acme/compute/prod`, `acme/data/prod`.

### StackReference Usage

```typescript
// ── network stack (producer) ── index.ts
import * as aws from "@pulumi/aws";

const vpc = new aws.ec2.Vpc("main", {
  cidrBlock: "10.0.0.0/16",
  enableDnsSupport: true,
  enableDnsHostnames: true,
});

const privateSubnets = [0, 1, 2].map(
  (i) => new aws.ec2.Subnet(`private-${i}`, {
    vpcId: vpc.id,
    cidrBlock: `10.0.${i + 10}.0/24`,
    availabilityZone: aws.getAvailabilityZones().then((azs) => azs.names[i]),
  })
);

export const vpcId = vpc.id;
export const privateSubnetIds = privateSubnets.map((s) => s.id);
```

```typescript
// ── compute stack (consumer) ── index.ts
import * as pulumi from "@pulumi/pulumi";
import * as eks from "@pulumi/eks";

const networkStack = new pulumi.StackReference("acme/network/prod");
const vpcId = networkStack.requireOutput("vpcId");       // fails fast if missing
const subnetIds = networkStack.requireOutput("privateSubnetIds");

const cluster = new eks.Cluster("main", {
  vpcId, subnetIds, instanceType: "t3.large",
  desiredCapacity: 3, minSize: 2, maxSize: 5,
});

export const kubeconfig = cluster.kubeconfig;
```

---

## 2. Component Resource Design

### Args Interface and Constructor Pattern

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

export interface WebServiceArgs {
  imageUri: pulumi.Input<string>;
  containerPort: number;
  cpu?: number;
  memory?: number;
  subnetIds: pulumi.Input<pulumi.Input<string>[]>;
  securityGroupIds: pulumi.Input<pulumi.Input<string>[]>;
  tags?: pulumi.Input<Record<string, pulumi.Input<string>>>;
}

export class WebService extends pulumi.ComponentResource {
  public readonly url: pulumi.Output<string>;
  public readonly taskDefinitionArn: pulumi.Output<string>;

  constructor(name: string, args: WebServiceArgs, opts?: pulumi.ComponentResourceOptions) {
    super("skillforge:aws:WebService", name, {}, opts);

    // parent: this ensures children appear under this component in state
    // provider forwarding lets callers control which AWS account/region is used
    const childOpts: pulumi.CustomResourceOptions = { parent: this, provider: opts?.provider };

    const taskDef = new aws.ecs.TaskDefinition(`${name}-task`, {
      family: name,
      networkMode: "awsvpc",
      requiresCompatibilities: ["FARGATE"],
      cpu: String(args.cpu ?? 256),
      memory: String(args.memory ?? 512),
      containerDefinitions: pulumi.output(args.imageUri).apply((uri) =>
        JSON.stringify([{ name, image: uri, portMappings: [{ containerPort: args.containerPort }] }])
      ),
    }, childOpts);

    const service = new aws.ecs.Service(`${name}-svc`, {
      launchType: "FARGATE",
      taskDefinition: taskDef.arn,
      desiredCount: 2,
      networkConfiguration: { subnets: args.subnetIds, securityGroups: args.securityGroupIds },
    }, childOpts);

    this.url = pulumi.interpolate`https://${name}.internal`;
    this.taskDefinitionArn = taskDef.arn;
    this.registerOutputs({ url: this.url, taskDefinitionArn: this.taskDefinitionArn });
  }
}
```

### Nesting Components

Components can contain other components, forming a tree that mirrors your architecture:

```typescript
export class Platform extends pulumi.ComponentResource {
  constructor(name: string, opts?: pulumi.ComponentResourceOptions) {
    super("skillforge:platform:Platform", name, {}, opts);

    const api = new WebService("api", {
      imageUri: "123456789.dkr.ecr.us-east-1.amazonaws.com/api:latest",
      containerPort: 8080, subnetIds, securityGroupIds,
    }, { parent: this });

    const worker = new WebService("worker", {
      imageUri: "123456789.dkr.ecr.us-east-1.amazonaws.com/worker:latest",
      containerPort: 9090, cpu: 1024, memory: 2048, subnetIds, securityGroupIds,
    }, { parent: this });

    this.registerOutputs({});
  }
}
```

---

## 3. Dynamic Providers (Custom CRUD)

Use dynamic providers when Pulumi has no native provider for a resource. The provider
implements CRUD operations; Pulumi calls them during the resource lifecycle.

```typescript
import * as pulumi from "@pulumi/pulumi";
import fetch from "node-fetch";

interface DnsRecordInputs {
  zone: string; name: string; type: string; value: string; ttl: number;
}

const API = "https://dns.internal.acme.com/api/v1";

const dnsProvider: pulumi.dynamic.ResourceProvider = {
  async check(olds: DnsRecordInputs, news: DnsRecordInputs) {
    const failures: pulumi.dynamic.CheckFailure[] = [];
    if (!news.zone) failures.push({ property: "zone", reason: "required" });
    if (!["A", "AAAA", "CNAME", "TXT"].includes(news.type))
      failures.push({ property: "type", reason: `Unsupported: ${news.type}` });
    if (news.ttl < 60 || news.ttl > 86400)
      failures.push({ property: "ttl", reason: "Must be 60–86400" });
    return { inputs: news, failures };
  },

  async diff(id: string, olds: DnsRecordInputs, news: DnsRecordInputs) {
    const replaces: string[] = [];
    if (olds.zone !== news.zone) replaces.push("zone");
    if (olds.name !== news.name) replaces.push("name");
    if (olds.type !== news.type) replaces.push("type");
    return { changes: replaces.length > 0 || olds.value !== news.value || olds.ttl !== news.ttl,
             replaces, deleteBeforeReplace: true };
  },

  async create(inputs: DnsRecordInputs) {
    const resp = await fetch(`${API}/zones/${inputs.zone}/records`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(inputs),
    });
    if (!resp.ok) throw new Error(`Create failed: ${resp.status} ${await resp.text()}`);
    const data = (await resp.json()) as { id: string };
    return { id: data.id, outs: { ...inputs, recordId: data.id } };
  },

  async read(id: string, props: DnsRecordInputs) {
    const resp = await fetch(`${API}/records/${id}`);
    if (resp.status === 404) return { id, props: {} as any };
    if (!resp.ok) throw new Error(`Read failed: ${resp.status}`);
    return { id, props: (await resp.json()) as DnsRecordInputs };
  },

  async update(id: string, olds: DnsRecordInputs, news: DnsRecordInputs) {
    const resp = await fetch(`${API}/records/${id}`, {
      method: "PUT", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(news),
    });
    if (!resp.ok) throw new Error(`Update failed: ${resp.status}`);
    return { outs: { ...news, recordId: id } };
  },

  async delete(id: string) {
    const resp = await fetch(`${API}/records/${id}`, { method: "DELETE" });
    if (!resp.ok && resp.status !== 404) throw new Error(`Delete failed: ${resp.status}`);
  },
};

export class DnsRecord extends pulumi.dynamic.Resource {
  public readonly recordId!: pulumi.Output<string>;
  constructor(name: string, args: DnsRecordInputs, opts?: pulumi.CustomResourceOptions) {
    super(dnsProvider, name, { recordId: undefined, ...args }, opts);
  }
}
```

**Serialization note**: Dynamic provider code is serialized into state. Avoid closures
capturing large objects, connections, or secrets. Keep CRUD methods pure and stateless.

---

## 4. Automation API Patterns

The Automation API embeds Pulumi inside application code — no CLI shelling out required.

### Inline Program with LocalWorkspace

```typescript
import { InlineProgramArgs, LocalWorkspace } from "@pulumi/pulumi/automation";
import * as aws from "@pulumi/aws";

async function deployBucket(envName: string, region: string) {
  const stackArgs: InlineProgramArgs = {
    stackName: envName,
    projectName: "data-lake",
    program: async () => {
      const bucket = new aws.s3.Bucket("data-lake", {
        bucket: `acme-data-lake-${envName}`, versioning: { enabled: true },
      });
      return { bucketArn: bucket.arn };
    },
  };

  const stack = await LocalWorkspace.createOrSelectStack(stackArgs);
  await stack.setConfig("aws:region", { value: region });
  const result = await stack.up({ onOutput: console.log });
  console.log(`ARN: ${result.outputs.bucketArn.value}`);
}
```

### File-Based Program

```typescript
import { LocalWorkspace } from "@pulumi/pulumi/automation";

async function deployFromDir(stackName: string) {
  const stack = await LocalWorkspace.createOrSelectStack({
    stackName,
    workDir: path.resolve(__dirname, "../infra/network"),
  });
  const preview = await stack.preview();
  if (preview.changeSummary.create || preview.changeSummary.update) {
    return (await stack.up({ onOutput: console.log })).summary;
  }
  return null;
}
```

### Self-Service Platform Pattern

```typescript
import express from "express";
import { LocalWorkspace, ConcurrentUpdateError } from "@pulumi/pulumi/automation";

const app = express();
app.use(express.json());

app.post("/api/environments", async (req, res) => {
  const { team, environment, tier } = req.body;
  try {
    const stack = await LocalWorkspace.createOrSelectStack({
      stackName: `${team}-${environment}`,
      projectName: "self-service-env",
      program: async () => { /* build infra based on tier */ },
    });
    await stack.setAllConfig({
      "app:tier": { value: tier }, "app:team": { value: team },
    });
    const result = await stack.up({ onOutput: () => {} });
    res.json({ status: "deployed", outputs: result.outputs });
  } catch (err) {
    if (err instanceof ConcurrentUpdateError) {
      res.status(409).json({ error: "Update already in progress" });
    } else {
      res.status(500).json({ error: (err as Error).message });
    }
  }
});
```

---

## 5. Stack Transformations

Stack transformations intercept every resource registration to modify inputs or options.

### Global Tag Injection

```typescript
import * as pulumi from "@pulumi/pulumi";

const mandatoryTags = {
  Environment: pulumi.getStack(),
  ManagedBy: "pulumi",
  CostCenter: "eng-42",
};

pulumi.runtime.registerStackTransformation((args) => {
  if (args.props?.tags !== undefined) {
    args.props.tags = { ...mandatoryTags, ...args.props.tags };
    return { props: args.props, opts: args.opts };
  }
  return undefined;
});
```

### Enforce S3 Encryption

```typescript
pulumi.runtime.registerStackTransformation((args) => {
  if (args.type === "aws:s3/bucket:Bucket") {
    args.props.serverSideEncryptionConfiguration = {
      rule: { applyServerSideEncryptionByDefault: { sseAlgorithm: "aws:kms" } },
    };
    return { props: args.props, opts: args.opts };
  }
  return undefined;
});
```

### Protect Database Resources from Deletion

```typescript
pulumi.runtime.registerStackTransformation((args) => {
  const protectedTypes = [
    "aws:rds/instance:Instance", "aws:rds/cluster:Cluster", "aws:dynamodb/table:Table",
  ];
  if (protectedTypes.includes(args.type)) {
    args.opts.protect = true;
    return { props: args.props, opts: args.opts };
  }
  return undefined;
});
```

---

## 6. Resource Aliases for Refactoring

Aliases tell Pulumi that a resource's new identity maps to an existing one in state,
preventing destroy-and-recreate during refactors.

### Renaming a Resource

```typescript
const sg = new aws.ec2.SecurityGroup("api-security-group", {
  vpcId, description: "API tier security group",
}, {
  aliases: [{ name: "web-sg" }],  // old name
});
```

### Reparenting into a Component

```typescript
const apiComponent = new ApiService("api", { /* ... */ });

const sg = new aws.ec2.SecurityGroup("api-sg", { vpcId }, {
  parent: apiComponent,
  aliases: [{ name: "api-sg", parent: pulumi.rootStackResource }],  // was at root
});
```

### Retyping a Component

```typescript
export class DatabaseCluster extends pulumi.ComponentResource {
  constructor(name: string, args: DbClusterArgs, opts?: pulumi.ComponentResourceOptions) {
    super("skillforge:v2:DatabaseCluster", name, {}, {
      ...opts,
      aliases: [{ type: "skillforge:v1:RdsCluster" }],
    });
  }
}
```

### Multi-Level Migration

When restructuring deeply nested components, provide multiple aliases:

```typescript
const cache = new aws.elasticache.Cluster("redis", {
  engine: "redis", nodeType: "cache.t3.micro", numCacheNodes: 1,
}, {
  parent: newDataLayer,
  aliases: [
    { name: "redis", parent: oldCacheComponent },
    { name: "redis", parent: pulumi.rootStackResource },
  ],
});
```

---

## 7. Provider Configuration

### Explicit Providers for Multi-Region

```typescript
const usEast1 = new aws.Provider("us-east-1", { region: "us-east-1" });
const euWest1 = new aws.Provider("eu-west-1", { region: "eu-west-1" });

const usBucket = new aws.s3.Bucket("us-data", { bucket: "acme-us" }, { provider: usEast1 });
const euBucket = new aws.s3.Bucket("eu-data", { bucket: "acme-eu" }, { provider: euWest1 });
```

### Multi-Account with AssumeRole

```typescript
const devAccount = new aws.Provider("dev", {
  region: "us-east-1",
  assumeRole: {
    roleArn: "arn:aws:iam::111111111111:role/PulumiDeployRole",
    sessionName: "pulumi-dev",
    externalId: "pulumi-ext-id",
  },
});

const prodAccount = new aws.Provider("prod", {
  region: "us-east-1",
  assumeRole: {
    roleArn: "arn:aws:iam::222222222222:role/PulumiDeployRole",
    sessionName: "pulumi-prod",
  },
});

const devVpc = new aws.ec2.Vpc("dev-vpc", { cidrBlock: "10.0.0.0/16" }, { provider: devAccount });
const prodVpc = new aws.ec2.Vpc("prod-vpc", { cidrBlock: "10.1.0.0/16" }, { provider: prodAccount });
```

### Provider Inheritance in Component Trees

Pass a provider to a ComponentResource and all children created with `parent: this`
inherit it automatically — no explicit wiring needed per child:

```typescript
const euProvider = new aws.Provider("eu", { region: "eu-central-1" });
const euPlatform = new Platform("eu-platform", { /* ... */ }, { provider: euProvider });
// Every aws.* resource inside Platform with { parent: this } uses euProvider
```

---

## 8. Pulumi ESC (Environments, Secrets, Config)

Pulumi ESC centralizes configuration and secrets across stacks, CI/CD, and local dev.

### Environment Definition with OIDC

```yaml
# environments/aws-dev.yaml
values:
  aws:
    login:
      fn::open::aws-login:
        oidc:
          roleArn: arn:aws:iam::111111111111:role/PulumiOIDC
          sessionName: pulumi-esc-dev
          duration: 1h
    region: us-east-1
  environmentVariables:
    AWS_ACCESS_KEY_ID: ${aws.login.accessKeyId}
    AWS_SECRET_ACCESS_KEY: ${aws.login.secretAccessKey}
    AWS_SESSION_TOKEN: ${aws.login.sessionToken}
  pulumiConfig:
    aws:region: ${aws.region}
```

### Environment Composition

Environments import other environments to form layered configuration:

```yaml
# environments/app-dev.yaml
imports:
  - aws-dev
  - team-defaults
values:
  pulumiConfig:
    app:dbInstanceClass: db.t3.micro
    app:replicaCount: "1"
  environmentVariables:
    APP_ENV: development
    LOG_LEVEL: debug
```

### Injecting into Stacks

```yaml
# Pulumi.yaml
name: my-app
runtime: nodejs
environment:
  - aws-dev
  - app-dev
```

### Shell Integration

```bash
pulumi env run aws-dev -- aws s3 ls           # run a command with env loaded
eval $(pulumi env open aws-dev --format shell) # export into current shell
```

---

## 9. Micro-Stacks vs Mono-Stack Trade-offs

| Dimension              | Mono-Stack                          | Micro-Stacks                        |
|------------------------|-------------------------------------|--------------------------------------|
| **Blast radius**       | Large — one bad change risks all    | Small — failures are isolated        |
| **Deploy speed**       | Slow as resource count grows        | Fast per stack                       |
| **State file size**    | Can exceed 100 MB, slow refreshes   | Small, fast operations               |
| **Cross-resource refs**| Direct in-program references        | Requires StackReference              |
| **Refactoring**        | Easy — move resources freely        | Needs import/export across stacks    |
| **Cognitive overhead** | Single codebase                     | Many stacks to navigate              |
| **CI/CD complexity**   | One pipeline                        | Dependency-ordered pipelines needed  |
| **Permissions**        | One credential set                  | Fine-grained per-stack IAM possible  |
| **Rollback**           | All-or-nothing                      | Independent per layer                |

**Use mono-stack**: Small teams, <50 resources, tightly coupled components, prototyping.

**Use micro-stacks**: Separate lifecycle cadences, multi-team ownership, state >20 MB,
compliance requiring independent blast-radius containment.

**Recommended split boundaries**: Network → Security → Data → Compute → Application.

---

## 10. Reusable Infrastructure Packages

### Component Schema for Multi-Language SDK Generation

```json
{
  "name": "skillforge-vpc",
  "version": "0.1.0",
  "resources": {
    "skillforge-vpc:index:Vpc": {
      "isComponent": true,
      "inputProperties": {
        "cidrBlock": { "type": "string" },
        "enableNatGateway": { "type": "boolean", "default": true },
        "azCount": { "type": "integer", "default": 3 }
      },
      "requiredInputs": ["cidrBlock"],
      "properties": {
        "vpcId": { "type": "string" },
        "publicSubnetIds": { "type": "array", "items": { "type": "string" } },
        "privateSubnetIds": { "type": "array", "items": { "type": "string" } }
      },
      "required": ["vpcId", "publicSubnetIds", "privateSubnetIds"]
    }
  },
  "language": {
    "nodejs": { "packageName": "@skillforge/vpc" },
    "python": { "packageName": "skillforge_vpc" },
    "go": { "importBasePath": "github.com/skillforge/vpc/sdk/go/vpc" }
  }
}
```

### NPM Package Structure

```
skillforge-vpc/
├── package.json
├── tsconfig.json
├── schema.json
├── src/
│   ├── index.ts
│   └── vpc.ts
└── README.md
```

```json
{
  "name": "@skillforge/vpc",
  "version": "0.1.0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "scripts": { "build": "tsc", "prepublishOnly": "npm run build" },
  "peerDependencies": { "@pulumi/pulumi": "^3.0.0", "@pulumi/aws": "^6.0.0" }
}
```

### Versioning Strategy

- **Patch** — Bug fixes, docs; no state impact
- **Minor** — New optional inputs/outputs; additive only
- **Major** — Renamed inputs, removed properties, state migration required

Always include resource aliases for renames so consumers upgrade without replacements.

---

## 11. Cross-Language Components

### How the Multi-Language System Works

1. **Author** writes a ComponentResource in their language of choice
2. **Schema** (`schema.json`) defines inputs, outputs, and types
3. **Provider binary** implements `Construct` gRPC calls
4. **SDK generation** produces typed SDKs for each target language
5. **Consumer** uses the generated SDK; Pulumi routes calls to the provider

### Writing the Provider

```typescript
import * as pulumi from "@pulumi/pulumi";
import { Vpc, VpcArgs } from "./vpc";

class Provider implements pulumi.provider.Provider {
  readonly version = "0.1.0";

  async construct(
    name: string, type: string,
    inputs: pulumi.Inputs, options: pulumi.ComponentResourceOptions,
  ): Promise<pulumi.provider.ConstructResult> {
    if (type === "skillforge-vpc:index:Vpc") {
      const vpc = new Vpc(name, inputs as VpcArgs, options);
      return {
        urn: vpc.urn,
        state: { vpcId: vpc.vpcId, publicSubnetIds: vpc.publicSubnetIds,
                 privateSubnetIds: vpc.privateSubnetIds },
      };
    }
    throw new Error(`Unknown resource type: ${type}`);
  }
}

export function main(args: string[]) {
  return pulumi.provider.main(new Provider(), args);
}
main(process.argv.slice(2));
```

### Consuming from Python

```python
import skillforge_vpc as vpc
import pulumi

network = vpc.Vpc("main-vpc", cidr_block="10.0.0.0/16", az_count=3, enable_nat_gateway=True)
pulumi.export("vpc_id", network.vpc_id)
```

### Consuming from Go

```go
func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		network, err := vpc.NewVpc(ctx, "main-vpc", &vpc.VpcArgs{
			CidrBlock: pulumi.String("10.0.0.0/16"),
			AzCount:   pulumi.Int(3),
		})
		if err != nil { return err }
		ctx.Export("vpcId", network.VpcId)
		return nil
	})
}
```

### SDK Generation

```bash
pulumi package gen-sdk ./schema.json --language nodejs
pulumi package gen-sdk ./schema.json --language python
pulumi package gen-sdk ./schema.json --language go
pulumi package gen-sdk ./schema.json --language dotnet
```

### Practical Considerations

- **State compatibility**: Stacks created with one language SDK work with another if
  the provider version matches.
- **Testing**: Test the provider natively; test generated SDKs in CI per target language.
- **Versioning**: Bump schema version and regenerate all SDKs together.
- **Performance**: Each `Construct` call crosses a gRPC boundary — negligible for most
  workloads, but relevant for latency-sensitive automation pipelines.
