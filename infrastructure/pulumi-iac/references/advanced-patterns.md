---
title: "Pulumi Advanced Patterns Reference"
description: "Dense, actionable reference for advanced Pulumi IaC patterns: component resources, multi-stack architectures, stack references, dynamic providers, Automation API, micro-stacks, resource transforms, and aliases."
version: "2.0"
last_updated: "2025-07-14"
audience: "Platform engineers and infrastructure teams using Pulumi at scale"
language: "TypeScript primary (Python where noted)"
---

# Pulumi Advanced Patterns Reference

## Table of Contents

- [1. Component Resources](#1-component-resources)
  - [1.1 Inputs Interface Pattern](#11-inputs-interface-pattern)
  - [1.2 Constructor & registerOutputs](#12-constructor--registeroutputs)
  - [1.3 ComponentResourceOptions](#13-componentresourceoptions)
  - [1.4 Nested Components](#14-nested-components)
  - [1.5 Multi-Cloud Components](#15-multi-cloud-components)
- [2. Multi-Stack Architectures](#2-multi-stack-architectures)
  - [2.1 Mono-Repo vs Poly-Repo](#21-mono-repo-vs-poly-repo)
  - [2.2 Environment-per-Stack vs Project-per-Stack](#22-environment-per-stack-vs-project-per-stack)
  - [2.3 When to Split](#23-when-to-split)
- [3. Stack References](#3-stack-references)
  - [3.1 Cross-Stack Output Sharing](#31-cross-stack-output-sharing)
  - [3.2 getOutput vs requireOutput vs getOutputDetails](#32-getoutput-vs-requireoutput-vs-getoutputdetails)
  - [3.3 Typed Outputs](#33-typed-outputs)
  - [3.4 Secrets Across Stacks](#34-secrets-across-stacks)
- [4. Dynamic Providers](#4-dynamic-providers)
  - [4.1 Full CRUD Lifecycle](#41-full-crud-lifecycle)
  - [4.2 Diff and Check](#42-diff-and-check)
  - [4.3 Serialization Gotchas](#43-serialization-gotchas)
  - [4.4 When to Use vs Native Provider](#44-when-to-use-vs-native-provider)
  - [4.5 Python Example](#45-python-example)
- [5. Automation API Deep-Dive](#5-automation-api-deep-dive)
  - [5.1 LocalWorkspace vs RemoteWorkspace](#51-localworkspace-vs-remoteworkspace)
  - [5.2 Inline vs Local Programs](#52-inline-vs-local-programs)
  - [5.3 Programmatic Config](#53-programmatic-config)
  - [5.4 Event Streams](#54-event-streams)
  - [5.5 Error Handling](#55-error-handling)
  - [5.6 Self-Service Platforms](#56-self-service-platforms)
  - [5.7 Multi-Stack Orchestration](#57-multi-stack-orchestration)
- [6. Micro-Stacks Pattern](#6-micro-stacks-pattern)
  - [6.1 Splitting Monoliths](#61-splitting-monoliths)
  - [6.2 Dependency DAGs](#62-dependency-dags)
  - [6.3 Orchestrating Deploy Order](#63-orchestrating-deploy-order)
  - [6.4 Anti-Patterns](#64-anti-patterns)
- [7. Resource Transformations](#7-resource-transformations)
  - [7.1 New Transforms API (registerResourceTransform)](#71-new-transforms-api-registerresourcetransform)
  - [7.2 Old transformations API (Deprecated)](#72-old-transformations-api-deprecated)
  - [7.3 Stack-Level vs Resource-Level Transforms](#73-stack-level-vs-resource-level-transforms)
  - [7.4 Async Transforms](#74-async-transforms)
  - [7.5 Transforms with Packaged Components (awsx)](#75-transforms-with-packaged-components-awsx)
  - [7.6 Injecting Tags and Options Globally](#76-injecting-tags-and-options-globally)
- [8. Aliases](#8-aliases)
  - [8.1 Renaming Resources](#81-renaming-resources)
  - [8.2 Moving Between Components](#82-moving-between-components)
  - [8.3 Alias Types](#83-alias-types)
  - [8.4 Bulk Aliasing](#84-bulk-aliasing)

---

## 1. Component Resources

Component resources group child resources into a reusable abstraction. They do **not** create cloud resources themselves — they are logical containers.

### 1.1 Inputs Interface Pattern

Always define a separate inputs interface. Use `pulumi.Input<T>` for properties that may be outputs from other resources:

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

export interface VpcArgs {
  cidrBlock: pulumi.Input<string>;
  azCount: pulumi.Input<number>;
  enableNatGateway?: pulumi.Input<boolean>;
  tags?: pulumi.Input<Record<string, pulumi.Input<string>>>;
}
```

Key rules:
- Required fields have no `?` — Pulumi validates at plan time.
- Use `pulumi.Input<T>` everywhere. Callers can pass raw values or outputs.
- Keep the interface in the same file or a shared `types.ts`.

### 1.2 Constructor & registerOutputs

```typescript
export class Vpc extends pulumi.ComponentResource {
  public readonly vpcId: pulumi.Output<string>;
  public readonly publicSubnetIds: pulumi.Output<string[]>;
  public readonly privateSubnetIds: pulumi.Output<string[]>;

  constructor(name: string, args: VpcArgs, opts?: pulumi.ComponentResourceOptions) {
    // Type token format: "pkg:module:Class"
    super("acme:network:Vpc", name, {}, opts);

    const defaultOpts: pulumi.ResourceOptions = { parent: this };

    const vpc = new aws.ec2.Vpc(`${name}-vpc`, {
      cidrBlock: args.cidrBlock,
      enableDnsSupport: true,
      enableDnsHostnames: true,
      tags: args.tags,
    }, defaultOpts);

    const publicSubnets: aws.ec2.Subnet[] = [];
    const privateSubnets: aws.ec2.Subnet[] = [];

    // Use apply to unwrap Input<number>
    const azCountOutput = pulumi.output(args.azCount);
    const azs = aws.getAvailabilityZonesOutput({ state: "available" });

    // Build subnets — note we set { parent: this } on ALL children
    for (let i = 0; i < 3; i++) {
      publicSubnets.push(new aws.ec2.Subnet(`${name}-pub-${i}`, {
        vpcId: vpc.id,
        cidrBlock: `10.0.${i}.0/24`,
        availabilityZone: azs.names[i],
        mapPublicIpOnLaunch: true,
        tags: args.tags,
      }, defaultOpts));

      privateSubnets.push(new aws.ec2.Subnet(`${name}-priv-${i}`, {
        vpcId: vpc.id,
        cidrBlock: `10.0.${i + 100}.0/24`,
        availabilityZone: azs.names[i],
        tags: args.tags,
      }, defaultOpts));
    }

    this.vpcId = vpc.id;
    this.publicSubnetIds = pulumi.output(publicSubnets.map(s => s.id));
    this.privateSubnetIds = pulumi.output(privateSubnets.map(s => s.id));

    // REQUIRED: signals that child resource registration is complete
    this.registerOutputs({
      vpcId: this.vpcId,
      publicSubnetIds: this.publicSubnetIds,
      privateSubnetIds: this.privateSubnetIds,
    });
  }
}
```

**Critical details:**
- `super()` third arg `{}` is the initial input bag — pass `{}` for components.
- Always pass `{ parent: this }` to children. This establishes the URN hierarchy.
- `registerOutputs()` must be called at the end of the constructor. Omitting it causes `pulumi up` to hang when the stack uses `dependsOn` on the component.
- Type token (`"acme:network:Vpc"`) must be globally unique. Convention: `"<org>:<module>:<Class>"`.

### 1.3 ComponentResourceOptions

`ComponentResourceOptions` extends `ResourceOptions` with:

```typescript
const vpc = new Vpc("prod", args, {
  providers: {                    // Map of provider instances by package name
    aws: awsUsEast1Provider,
    random: randomProvider,
  },
  parent: parentComponent,        // Establishes URN hierarchy
  dependsOn: [otherResource],     // Explicit ordering
  protect: true,                  // Prevent accidental deletion
  aliases: [{ name: "old-name" }],
  transformations: [],            // Deprecated — use transforms
});
```

`providers` is only on `ComponentResourceOptions` (not plain `ResourceOptions`). It propagates the provider to all children automatically — no need to pass `provider` to each child individually.

### 1.4 Nested Components

Components can nest. Always propagate the parent:

```typescript
export class Platform extends pulumi.ComponentResource {
  constructor(name: string, args: PlatformArgs, opts?: pulumi.ComponentResourceOptions) {
    super("acme:platform:Platform", name, {}, opts);

    // Child component — pass { parent: this }
    const network = new Vpc(`${name}-net`, {
      cidrBlock: "10.0.0.0/16",
      azCount: 3,
    }, { parent: this });

    const cluster = new EksCluster(`${name}-eks`, {
      vpcId: network.vpcId,
      subnetIds: network.privateSubnetIds,
      nodeCount: args.nodeCount,
    }, { parent: this, dependsOn: [network] });

    this.registerOutputs({ kubeconfig: cluster.kubeconfig });
  }
}
```

The URN tree becomes: `Platform -> Vpc -> aws:ec2:Vpc, Subnet...` and `Platform -> EksCluster -> ...`. This is visible in `pulumi stack --show-urns`.

### 1.5 Multi-Cloud Components

Use `providers` to pass multiple cloud providers into a single component:

```typescript
export interface MultiCdnArgs {
  domain: string;
  originBucket: pulumi.Input<string>;
}

export class MultiCdn extends pulumi.ComponentResource {
  constructor(name: string, args: MultiCdnArgs, opts?: pulumi.ComponentResourceOptions) {
    super("acme:cdn:MultiCdn", name, {}, opts);

    // Children inherit the correct provider from opts.providers
    const cfDistro = new aws.cloudfront.Distribution(`${name}-cf`, {
      /* ... */
    }, { parent: this });

    const azCdn = new azure.cdn.Endpoint(`${name}-azcdn`, {
      /* ... */
    }, { parent: this });

    this.registerOutputs({});
  }
}

// Usage: pass explicit providers
const cdn = new MultiCdn("global-cdn", { domain: "cdn.example.com", originBucket: "my-bucket" }, {
  providers: {
    aws: new aws.Provider("aws-us", { region: "us-east-1" }),
    azure: new azure.Provider("az-west", { location: "westus2" }),
  },
});
```

---

## 2. Multi-Stack Architectures

### 2.1 Mono-Repo vs Poly-Repo

**Mono-repo** (recommended for most teams):
```
infra/
├── Pulumi.yaml              # shared project
├── stacks/
│   ├── network/
│   │   ├── Pulumi.yaml
│   │   ├── Pulumi.dev.yaml
│   │   ├── Pulumi.prod.yaml
│   │   └── index.ts
│   ├── data/
│   │   ├── Pulumi.yaml
│   │   └── index.ts
│   └── app/
│       ├── Pulumi.yaml
│       └── index.ts
├── components/               # shared component library
│   ├── vpc.ts
│   └── cluster.ts
├── package.json
└── tsconfig.json
```

**Poly-repo** (use when teams/orgs own different layers):
```
# Repo: infra-network
network/
├── Pulumi.yaml
├── Pulumi.dev.yaml
└── index.ts

# Repo: infra-app (separate repo, separate CI)
app/
├── Pulumi.yaml
└── index.ts         # uses StackReference to read from network
```

| Criteria | Mono-repo | Poly-repo |
|---|---|---|
| Code sharing | Direct imports | NPM packages or StackReference |
| CI/CD | Single pipeline, path filters | Separate pipelines |
| Team autonomy | Lower | Higher |
| Refactoring | Easier | Cross-repo PRs |
| Dependency drift | Low | High risk |

### 2.2 Environment-per-Stack vs Project-per-Stack

**Environment-per-stack** — one Pulumi project, multiple stacks (`dev`, `staging`, `prod`):

```yaml
# Pulumi.yaml
name: webapp
runtime: nodejs

# Pulumi.dev.yaml
config:
  webapp:instanceCount: "2"
  aws:region: us-west-2

# Pulumi.prod.yaml
config:
  webapp:instanceCount: "10"
  aws:region: us-east-1
```

```typescript
const config = new pulumi.Config();
const instanceCount = config.requireNumber("instanceCount");
const stack = pulumi.getStack(); // "dev" | "staging" | "prod"
```

**Project-per-stack** — separate Pulumi projects for each concern:

```
network/Pulumi.yaml     -> project: "network"     stacks: dev, prod
database/Pulumi.yaml    -> project: "database"     stacks: dev, prod
app/Pulumi.yaml         -> project: "app"          stacks: dev, prod
```

These are orthogonal — you typically combine both: multiple projects, each with per-environment stacks.

### 2.3 When to Split

Split into separate stacks when:
- **Different lifecycle cadences**: networking changes monthly, app deploys hourly.
- **Different permissions**: network team vs app team.
- **Blast radius**: a bad app deploy shouldn't touch the VPC.
- **State file size**: stacks with >200 resources get slow.
- **Different destroy semantics**: you never `pulumi destroy` the database stack.

Keep together when:
- Resources have tight coupling (e.g., Lambda + API Gateway).
- You need atomic deploys (all-or-nothing).
- State file is small (<100 resources).

---

## 3. Stack References

### 3.1 Cross-Stack Output Sharing

**Producer stack** (network):
```typescript
// network/index.ts
const vpc = new aws.ec2.Vpc("main", { cidrBlock: "10.0.0.0/16" });

// Export values for consumers
export const vpcId = vpc.id;
export const privateSubnetIds = vpc.privateSubnets.map(s => s.id);
export const dbSecurityGroupId = pulumi.secret(dbSg.id); // exported as secret
```

**Consumer stack** (app):
```typescript
// app/index.ts
const networkStack = new pulumi.StackReference("acme/network/prod");

const vpcId = networkStack.getOutput("vpcId");             // Output<any>
const subnetIds = networkStack.getOutput("privateSubnetIds"); // Output<any>
```

The stack reference name format is `<org>/<project>/<stack>`. For self-managed backends it's just `<org>/<stack>`.

### 3.2 getOutput vs requireOutput vs getOutputDetails

```typescript
const ref = new pulumi.StackReference("acme/network/prod");

// getOutput: returns Output<any>. Returns undefined if key doesn't exist.
const maybeVpc = ref.getOutput("vpcId");

// requireOutput: returns Output<any>. THROWS if the key doesn't exist.
// Use this in production — fail fast on missing dependencies.
const vpcId = ref.requireOutput("vpcId");

// getOutputDetails: returns Promise<{value?: T, secretValue?: T}>
// Useful when you need to check if a value is secret, or need the raw value
// in non-Output context (e.g., Automation API).
const details = await ref.getOutputDetails("dbPassword");
if (details.secretValue !== undefined) {
  console.log("Got secret value");
}
```

**Decision matrix:**

| Method | Missing key | Return type | Secret-aware |
|---|---|---|---|
| `getOutput` | Returns `undefined` | `Output<any>` | Yes (stays secret) |
| `requireOutput` | Throws error | `Output<any>` | Yes (stays secret) |
| `getOutputDetails` | `value` is `undefined` | `Promise<OutputDetails>` | Yes (separate field) |

### 3.3 Typed Outputs

Stack references return `Output<any>`. Cast for type safety:

```typescript
const vpcId = ref.requireOutput("vpcId") as pulumi.Output<string>;
const subnetIds = ref.requireOutput("privateSubnetIds") as pulumi.Output<string[]>;

// Or use apply for complex types:
interface NetworkOutputs {
  vpcId: string;
  subnetIds: string[];
  cidr: string;
}

const networkConfig = pulumi.all([
  ref.requireOutput("vpcId"),
  ref.requireOutput("subnetIds"),
  ref.requireOutput("cidr"),
]).apply(([vpcId, subnetIds, cidr]): NetworkOutputs => ({
  vpcId, subnetIds, cidr,
}));
```

### 3.4 Secrets Across Stacks

Secrets exported from a producer stack remain encrypted in state. When consumed via `StackReference`, they are automatically treated as secrets in the consumer:

```typescript
// Producer
export const dbPassword = pulumi.secret("hunter2");

// Consumer — this is already a secret Output, no action needed
const pw = ref.requireOutput("dbPassword");
// pw is Output<string> and marked secret — it won't appear in plaintext in state/logs

// If you need to verify:
const details = await ref.getOutputDetails("dbPassword");
// details.secretValue is set, details.value is undefined
```

**Warning:** If both stacks use different secrets providers (e.g., one uses `awskms://`, another uses `passphrase`), each stack encrypts with its own provider. The reference mechanism decrypts on read and re-encrypts for the consumer's state. This works transparently.

---

## 4. Dynamic Providers

Dynamic providers let you manage resources that have no native Pulumi provider — APIs, scripts, shell commands, custom workflows.

### 4.1 Full CRUD Lifecycle

```typescript
import * as pulumi from "@pulumi/pulumi";

interface GrafanaDashboardInputs {
  orgId: number;
  title: string;
  dashboardJson: string;
  folderUid?: string;
}

interface GrafanaDashboardOutputs extends GrafanaDashboardInputs {
  uid: string;
  url: string;
  version: number;
}

const grafanaDashboardProvider: pulumi.dynamic.ResourceProvider = {
  async create(inputs: GrafanaDashboardInputs): Promise<pulumi.dynamic.CreateResult> {
    const fetch = (await import("node-fetch")).default;
    const resp = await fetch(`${process.env.GRAFANA_URL}/api/dashboards/db`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${process.env.GRAFANA_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        dashboard: { ...JSON.parse(inputs.dashboardJson), title: inputs.title },
        folderId: 0,
        overwrite: false,
      }),
    });
    const data = await resp.json() as any;
    return {
      id: data.uid,
      outs: {
        ...inputs,
        uid: data.uid,
        url: data.url,
        version: data.version,
      } satisfies GrafanaDashboardOutputs,
    };
  },

  async read(id: string, props: GrafanaDashboardOutputs): Promise<pulumi.dynamic.ReadResult> {
    const fetch = (await import("node-fetch")).default;
    const resp = await fetch(`${process.env.GRAFANA_URL}/api/dashboards/uid/${id}`, {
      headers: { "Authorization": `Bearer ${process.env.GRAFANA_TOKEN}` },
    });
    if (!resp.ok) {
      // Returning an empty id signals the resource was deleted out-of-band
      return { id: "", props: {} };
    }
    const data = await resp.json() as any;
    return {
      id,
      props: {
        ...props,
        title: data.dashboard.title,
        version: data.meta.version,
        uid: id,
        url: data.meta.url,
      },
    };
  },

  async update(id: string, olds: GrafanaDashboardOutputs, news: GrafanaDashboardInputs): Promise<pulumi.dynamic.UpdateResult> {
    const fetch = (await import("node-fetch")).default;
    const resp = await fetch(`${process.env.GRAFANA_URL}/api/dashboards/db`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${process.env.GRAFANA_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        dashboard: {
          ...JSON.parse(news.dashboardJson),
          title: news.title,
          uid: id,
          version: olds.version, // optimistic concurrency
        },
        overwrite: true,
      }),
    });
    const data = await resp.json() as any;
    return {
      outs: {
        ...news,
        uid: id,
        url: data.url,
        version: data.version,
      },
    };
  },

  async delete(id: string, props: GrafanaDashboardOutputs): Promise<void> {
    const fetch = (await import("node-fetch")).default;
    await fetch(`${process.env.GRAFANA_URL}/api/dashboards/uid/${id}`, {
      method: "DELETE",
      headers: { "Authorization": `Bearer ${process.env.GRAFANA_TOKEN}` },
    });
  },
};

class GrafanaDashboard extends pulumi.dynamic.Resource {
  public readonly uid!: pulumi.Output<string>;
  public readonly url!: pulumi.Output<string>;
  public readonly version!: pulumi.Output<number>;

  constructor(name: string, args: GrafanaDashboardInputs, opts?: pulumi.CustomResourceOptions) {
    super(grafanaDashboardProvider, name, { ...args, uid: undefined, url: undefined, version: undefined }, opts);
  }
}

// Usage
const dashboard = new GrafanaDashboard("my-dashboard", {
  orgId: 1,
  title: "API Metrics",
  dashboardJson: JSON.stringify({ panels: [/* ... */] }),
});
```

### 4.2 Diff and Check

```typescript
const provider: pulumi.dynamic.ResourceProvider = {
  // diff: controls what changes trigger update vs replace
  async diff(id: string, olds: any, news: any): Promise<pulumi.dynamic.DiffResult> {
    const changes = olds.title !== news.title || olds.dashboardJson !== news.dashboardJson;
    const replaces: string[] = [];

    // If orgId changed, must replace (delete + create)
    if (olds.orgId !== news.orgId) {
      replaces.push("orgId");
    }

    return {
      changes,
      replaces,
      stables: ["uid"],     // fields that won't change even on update
      deleteBeforeReplace: true,
    };
  },

  // check: validate + set defaults BEFORE diff/create/update
  async check(olds: any, news: any): Promise<pulumi.dynamic.CheckResult> {
    const failures: pulumi.dynamic.CheckFailure[] = [];

    if (!news.title || news.title.length === 0) {
      failures.push({ property: "title", reason: "Title must not be empty" });
    }
    try {
      JSON.parse(news.dashboardJson);
    } catch {
      failures.push({ property: "dashboardJson", reason: "Must be valid JSON" });
    }

    // Set defaults
    const inputs = { ...news };
    inputs.folderUid = inputs.folderUid ?? "general";

    return { inputs, failures };
  },

  async create(inputs: any) { /* ... */ },
  async update(id: string, olds: any, news: any) { /* ... */ },
  async delete(id: string, props: any) { /* ... */ },
};
```

### 4.3 Serialization Gotchas

Dynamic providers are **serialized and deserialized** by the Pulumi engine. This means:

1. **No closures over external state.** The provider object is serialized. Anything captured by closure must itself be serializable.

```typescript
// BAD: httpClient is a class instance — not serializable
const httpClient = new HttpClient();
const provider: pulumi.dynamic.ResourceProvider = {
  async create(inputs) {
    await httpClient.post(...); // FAILS at runtime
  },
};

// GOOD: create the client inside the method
const provider: pulumi.dynamic.ResourceProvider = {
  async create(inputs) {
    const fetch = (await import("node-fetch")).default;
    await fetch(...); // works
  },
};
```

2. **Dynamic imports only.** Use `await import("module")` inside methods, not top-level `import`.

3. **All inputs/outputs must be JSON-serializable.** No `Date`, `Buffer`, `Map`, `Set`, or class instances. Convert to strings/arrays/objects.

4. **`id` must be a string.** Even if the upstream API uses numeric IDs, return `String(numericId)`.

5. **Provider state is re-deserialized on every operation.** Don't rely on in-memory caching.

### 4.4 When to Use vs Native Provider

| Use dynamic provider when... | Use native/bridged provider when... |
|---|---|
| Internal API with no Terraform/Pulumi provider | Provider already exists on Pulumi Registry |
| One-off resource (webhook, DNS record in custom system) | You need full schema validation |
| Prototyping before building a full provider | Multiple resource types with relationships |
| Shell command wrapper | You need `pulumi import` support |
| < 5 resource types | > 5 resource types with shared auth |

### 4.5 Python Example

```python
from pulumi import ResourceOptions, Output
from pulumi.dynamic import Resource, ResourceProvider, CreateResult, UpdateResult

class SlackChannelProvider(ResourceProvider):
    def create(self, inputs: dict) -> CreateResult:
        import requests
        resp = requests.post("https://slack.com/api/conversations.create", json={
            "name": inputs["channel_name"],
            "is_private": inputs.get("is_private", False),
        }, headers={"Authorization": f"Bearer {inputs['token']}"})
        data = resp.json()
        return CreateResult(
            id_=data["channel"]["id"],
            outs={**inputs, "channel_id": data["channel"]["id"]},
        )

    def update(self, id: str, olds: dict, news: dict) -> UpdateResult:
        import requests
        requests.post("https://slack.com/api/conversations.rename", json={
            "channel": id,
            "name": news["channel_name"],
        }, headers={"Authorization": f"Bearer {news['token']}"})
        return UpdateResult(outs={**news, "channel_id": id})

    def delete(self, id: str, props: dict) -> None:
        import requests
        requests.post("https://slack.com/api/conversations.archive", json={
            "channel": id,
        }, headers={"Authorization": f"Bearer {props['token']}"})

class SlackChannel(Resource):
    channel_id: Output[str]

    def __init__(self, name: str, channel_name: str, token: str,
                 is_private: bool = False, opts: ResourceOptions = None):
        super().__init__(
            SlackChannelProvider(),
            name,
            {"channel_name": channel_name, "token": token,
             "is_private": is_private, "channel_id": None},
            opts,
        )

# Usage
channel = SlackChannel("alerts", channel_name="prod-alerts", token=slack_token)
```

---

## 5. Automation API Deep-Dive

The Automation API embeds the Pulumi engine as a library. No CLI needed.

### 5.1 LocalWorkspace vs RemoteWorkspace

```typescript
import { LocalWorkspace, RemoteWorkspace } from "@pulumi/pulumi/automation";

// LocalWorkspace: runs against local filesystem
const localStack = await LocalWorkspace.createOrSelectStack({
  stackName: "dev",
  projectName: "my-infra",
  program: async () => { /* inline program */ },
});

// LocalWorkspace with existing project on disk
const diskStack = await LocalWorkspace.createOrSelectStack({
  stackName: "dev",
  workDir: "/path/to/pulumi/project", // must contain Pulumi.yaml
});

// RemoteWorkspace: runs in Pulumi Cloud (Deployments)
const remoteStack = await RemoteWorkspace.createOrSelectStack({
  stackName: "acme/my-infra/prod",
  url: "https://github.com/acme/infra.git",
  branch: "refs/heads/main",
  projectPath: "stacks/app",
}, {
  envVars: {
    AWS_ACCESS_KEY_ID: { value: "AKIA...", secret: false },
    AWS_SECRET_ACCESS_KEY: { value: "wJal...", secret: true },
  },
});
```

**Key differences:**

| | LocalWorkspace | RemoteWorkspace |
|---|---|---|
| Execution | Your machine/CI runner | Pulumi Cloud |
| State backend | Any (local, S3, Pulumi Cloud) | Pulumi Cloud only |
| Source code | Local files or inline | Git repo |
| Use case | CI/CD, local scripts, self-service | Pulumi Deployments |

### 5.2 Inline vs Local Programs

**Inline programs** — define infrastructure as a function, no Pulumi.yaml needed:

```typescript
import { LocalWorkspace } from "@pulumi/pulumi/automation";
import * as aws from "@pulumi/aws";

const program = async () => {
  const bucket = new aws.s3.Bucket("auto-bucket", {
    website: { indexDocument: "index.html" },
  });
  return { bucketName: bucket.bucket, bucketArn: bucket.arn };
};

const stack = await LocalWorkspace.createOrSelectStack({
  stackName: "dev",
  projectName: "auto-buckets",
  program,
});

const result = await stack.up({ onOutput: console.log });
console.log(`Bucket: ${result.outputs.bucketName.value}`);
```

**Local programs** — point to a directory with `Pulumi.yaml` + `index.ts`:

```typescript
const stack = await LocalWorkspace.createOrSelectStack({
  stackName: "dev",
  workDir: path.join(__dirname, "../my-project"),
});
// No program arg — it uses the project's entry point
const result = await stack.up({ onOutput: console.log });
```

Use inline for: embedding in APIs, tests, dynamic infrastructure.
Use local for: wrapping existing projects with automation (CI, orchestration).

### 5.3 Programmatic Config

```typescript
// Set individual config values
await stack.setConfig("aws:region", { value: "us-west-2" });
await stack.setConfig("app:instanceCount", { value: "5" });
await stack.setConfig("app:dbPassword", { value: "s3cr3t", secret: true });

// Set all config at once
await stack.setAllConfig({
  "aws:region": { value: "us-west-2" },
  "app:replicas": { value: "3" },
  "app:apiKey": { value: "abc123", secret: true },
});

// Read config
const cfg = await stack.getConfig("app:instanceCount");
console.log(cfg.value); // "5"

// Get all config
const allCfg = await stack.getAllConfig();

// Remove config
await stack.removeConfig("app:oldKey");

// Set the secrets provider
const stack = await LocalWorkspace.createStack({
  stackName: "prod",
  projectName: "my-app",
  program,
}, {
  secretsProvider: "awskms://alias/pulumi-secrets",
});
```

### 5.4 Event Streams

```typescript
const result = await stack.up({
  onOutput: (msg) => process.stdout.write(msg), // simple text streaming
  onEvent: (event) => {
    // Structured events for building UIs
    if (event.resourcePreEvent) {
      const { metadata } = event.resourcePreEvent;
      console.log(`${metadata.op} ${metadata.type} ${metadata.urn}`);
    }
    if (event.resOutputsEvent) {
      console.log("Resource outputs available:", event.resOutputsEvent.metadata.urn);
    }
    if (event.diagnosticEvent) {
      if (event.diagnosticEvent.severity === "error") {
        console.error(event.diagnosticEvent.message);
      }
    }
    if (event.summaryEvent) {
      console.log(`Changes: ${JSON.stringify(event.summaryEvent.resourceChanges)}`);
    }
  },
});
```

Event types: `preludeEvent`, `resourcePreEvent`, `resOutputsEvent`, `diagnosticEvent`, `policyEvent`, `summaryEvent`, `cancelEvent`, `engineEvent`.

### 5.5 Error Handling

```typescript
import {
  LocalWorkspace,
  ConcurrentUpdateError,
  StackAlreadyExistsError,
  StackNotFoundError,
  CommandError,
  InlineProgramArgs,
} from "@pulumi/pulumi/automation";

try {
  const result = await stack.up({ onOutput: console.log });
  if (result.summary.result === "succeeded") {
    console.log("Deployed successfully");
  }
} catch (e) {
  if (e instanceof ConcurrentUpdateError) {
    // Another update is already in progress
    console.log("Stack is locked. Retry later.");
  } else if (e instanceof CommandError) {
    // The Pulumi command failed — check stderr
    console.error("Command failed:", e.message);
  } else {
    throw e;
  }
}

// Stack lifecycle error handling
try {
  const stack = await LocalWorkspace.createStack(args);
} catch (e) {
  if (e instanceof StackAlreadyExistsError) {
    const stack = await LocalWorkspace.selectStack(args);
  }
}

// Preview with error handling
const preview = await stack.preview();
if (preview.changeSummary.create > 0 || preview.changeSummary.update > 0) {
  console.log("Changes detected, proceeding with up...");
  await stack.up();
}
```

### 5.6 Self-Service Platforms

Pattern for a REST API that provisions infrastructure on demand:

```typescript
import express from "express";
import { LocalWorkspace, Stack } from "@pulumi/pulumi/automation";
import * as aws from "@pulumi/aws";

const app = express();
app.use(express.json());

// Each tenant gets their own stack
app.post("/api/environments", async (req, res) => {
  const { tenantId, size } = req.body;
  const stackName = `tenant-${tenantId}`;

  const program = async () => {
    const bucket = new aws.s3.Bucket("data", {
      tags: { Tenant: tenantId },
    });
    const db = new aws.rds.Instance("db", {
      instanceClass: size === "large" ? "db.r5.xlarge" : "db.t3.medium",
      engine: "postgres",
      allocatedStorage: 20,
      tags: { Tenant: tenantId },
    });
    return { bucketName: bucket.bucket, dbEndpoint: db.endpoint };
  };

  try {
    const stack = await LocalWorkspace.createOrSelectStack({
      stackName,
      projectName: "tenant-infra",
      program,
    });
    await stack.setConfig("aws:region", { value: "us-west-2" });
    const result = await stack.up({ onOutput: console.log });
    res.json({
      status: "provisioned",
      outputs: {
        bucket: result.outputs.bucketName?.value,
        db: result.outputs.dbEndpoint?.value,
      },
    });
  } catch (e: any) {
    res.status(500).json({ error: e.message });
  }
});

app.delete("/api/environments/:tenantId", async (req, res) => {
  const stackName = `tenant-${req.params.tenantId}`;
  try {
    const stack = await LocalWorkspace.selectStack({
      stackName,
      projectName: "tenant-infra",
      program: async () => {}, // program required but not used for destroy
    });
    await stack.destroy({ onOutput: console.log });
    await stack.workspace.removeStack(stackName);
    res.json({ status: "destroyed" });
  } catch (e: any) {
    res.status(500).json({ error: e.message });
  }
});
```

### 5.7 Multi-Stack Orchestration

Deploy stacks in dependency order with the Automation API:

```typescript
import { LocalWorkspace, Stack } from "@pulumi/pulumi/automation";
import path from "path";

interface StackDef {
  name: string;
  workDir: string;
  dependencies: string[];
}

const stacks: StackDef[] = [
  { name: "network", workDir: "./stacks/network", dependencies: [] },
  { name: "data", workDir: "./stacks/data", dependencies: ["network"] },
  { name: "app", workDir: "./stacks/app", dependencies: ["network", "data"] },
  { name: "monitoring", workDir: "./stacks/monitoring", dependencies: ["app"] },
];

async function deployAll(env: string) {
  const deployed = new Set<string>();
  const results = new Map<string, any>();

  async function deploy(def: StackDef): Promise<void> {
    // Wait for dependencies
    for (const dep of def.dependencies) {
      while (!deployed.has(dep)) {
        await new Promise(r => setTimeout(r, 1000));
      }
    }

    const stack = await LocalWorkspace.createOrSelectStack({
      stackName: env,
      workDir: path.resolve(def.workDir),
    });

    await stack.setConfig("env", { value: env });
    console.log(`Deploying ${def.name}...`);
    const result = await stack.up({ onOutput: (s) => process.stdout.write(`[${def.name}] ${s}`) });
    results.set(def.name, result.outputs);
    deployed.add(def.name);
    console.log(`Done: ${def.name} deployed`);
  }

  // Deploy with maximum concurrency respecting dependency order
  await Promise.all(stacks.map(deploy));
  return results;
}

deployAll("prod").catch(console.error);
```

---

## 6. Micro-Stacks Pattern

### 6.1 Splitting Monoliths

A monolith stack managing VPC + RDS + EKS + apps becomes unwieldy. Split by **lifecycle boundary**:

```
Before (monolith):
  my-infra/
  +-- index.ts  -> VPC, Subnets, NAT, RDS, EKS, Helm charts, DNS (400+ resources)

After (micro-stacks):
  network/       -> VPC, Subnets, NAT, IGW, Route Tables (~30 resources)
  database/      -> RDS, ElastiCache, Security Groups (~15 resources)
  cluster/       -> EKS, Node Groups, IRSA Roles (~40 resources)
  platform/      -> Helm charts (ingress, cert-manager, external-dns) (~20 resources)
  app-api/       -> Deployment, Service, Ingress for API (~10 resources)
  app-web/       -> Deployment, Service, Ingress for web (~10 resources)
  monitoring/    -> CloudWatch dashboards, alarms, SNS (~25 resources)
```

**Migration strategy**: Use `pulumi state move` (Pulumi v3.134+) or import/alias resources into new stacks.

### 6.2 Dependency DAGs

Model inter-stack dependencies explicitly:

```
network --> database --> app-api
   |                       ^
   +----> cluster --> platform
                         ^
                     monitoring
```

Each arrow is a `StackReference`. The DAG determines deploy order.

```typescript
// database/index.ts
const network = new pulumi.StackReference(`acme/network/${pulumi.getStack()}`);
const vpcId = network.requireOutput("vpcId") as pulumi.Output<string>;
const privateSubnetIds = network.requireOutput("privateSubnetIds") as pulumi.Output<string[]>;

const db = new aws.rds.Instance("main", {
  dbSubnetGroupName: new aws.rds.SubnetGroup("db-subnets", {
    subnetIds: privateSubnetIds,
  }).name,
  vpcSecurityGroupIds: [/* ... */],
  /* ... */
});

export const dbEndpoint = db.endpoint;
export const dbPort = db.port;
export const dbPassword = pulumi.secret(db.password);
```

### 6.3 Orchestrating Deploy Order

**Option A: Shell script with dependency awareness**

```bash
#!/bin/bash
set -euo pipefail

ENV="${1:-dev}"

deploy_stack() {
  local dir="$1"
  echo "==> Deploying $dir ($ENV)"
  pushd "$dir" > /dev/null
  pulumi stack select "$ENV" 2>/dev/null || pulumi stack init "$ENV"
  pulumi up --yes --skip-preview
  popd > /dev/null
}

# Layer 0: no dependencies
deploy_stack "stacks/network"

# Layer 1: depends on network
deploy_stack "stacks/database" &
deploy_stack "stacks/cluster" &
wait

# Layer 2: depends on cluster
deploy_stack "stacks/platform"

# Layer 3: depends on platform + database
deploy_stack "stacks/app-api" &
deploy_stack "stacks/app-web" &
wait

# Layer 4: depends on app
deploy_stack "stacks/monitoring"

echo "All stacks deployed"
```

**Option B: Turborepo (mono-repo)**

```jsonc
// turbo.json
{
  "pipeline": {
    "deploy": {
      "dependsOn": ["^deploy"],
      "cache": false
    }
  }
}
```

```jsonc
// stacks/database/package.json
{
  "name": "@infra/database",
  "scripts": { "deploy": "pulumi up --yes --skip-preview" },
  "dependencies": { "@infra/network": "*" }
}
```

```bash
npx turbo run deploy --concurrency=4
```

**Option C: Automation API** — see section 5.7 above.

### 6.4 Anti-Patterns

| Anti-Pattern | Problem | Fix |
|---|---|---|
| **Circular stack refs** | A refs B refs A -> deadlock | Refactor shared state into a third stack |
| **Too many micro-stacks** | 50 stacks for 200 resources -> operational overhead | Consolidate stacks that always deploy together |
| **Leaking implementation details** | Exporting internal resource IDs that consumers shouldn't depend on | Export only stable, intentional contracts |
| **No versioning on outputs** | Renaming an export breaks all consumers | Treat exports as a public API — deprecate, don't delete |
| **Shared state via SSM/Secrets Manager** | Using AWS SSM instead of StackReference -> no dependency tracking | Use StackReference for infra dependencies |
| **Manual deploy order** | Relying on humans to run stacks in order | Automate with scripts, Turborepo, or Automation API |

---

## 7. Resource Transformations

### 7.1 New Transforms API (registerResourceTransform)

The new `transforms` API (Pulumi v3.99+) replaces the deprecated `transformations`. Key improvement: it receives a `ResourceTransformArgs` with `props` as an `Inputs` bag and `opts` as a mutable `ResourceOptions`.

```typescript
import * as pulumi from "@pulumi/pulumi";

// Register a stack-level transform — applies to ALL resources in the stack
pulumi.runtime.registerResourceTransform((args) => {
  // args.type: string          — resource type (e.g., "aws:s3/bucket:Bucket")
  // args.name: string          — resource name
  // args.props: Inputs         — the resource's input properties
  // args.opts: ResourceOptions — mutable options (parent, protect, etc.)

  // Add tags to every AWS resource that supports them
  if (args.type.startsWith("aws:") && args.props) {
    const existingTags = args.props["tags"] || {};
    args.props["tags"] = {
      ...existingTags,
      ManagedBy: "pulumi",
      Stack: pulumi.getStack(),
      Project: pulumi.getProject(),
    };
  }
  return { props: args.props, opts: args.opts };
});
```

### 7.2 Old transformations API (Deprecated)

The old API used `transformations` on `ResourceOptions`. It still works but should be migrated:

```typescript
// DEPRECATED — avoid in new code
const bucket = new aws.s3.Bucket("my-bucket", {}, {
  transformations: [(args) => {
    if (args.type === "aws:s3/bucket:Bucket") {
      args.props["tags"] = { ...args.props["tags"], Env: "prod" };
    }
    return { props: args.props, opts: args.opts };
  }],
});
```

**Migration: `transformations` -> `registerResourceTransform`**

| Old (`transformations`) | New (`registerResourceTransform`) |
|---|---|
| Passed via `ResourceOptions` | Called globally or on components |
| Receives `ResourceTransformationArgs` | Receives `ResourceTransformArgs` |
| Returns `{ props, opts } | undefined` | Returns `{ props, opts } | undefined` |
| Only applies to that resource + children | Stack-level: all resources. Resource-level: that subtree |
| Synchronous only | Supports async transforms |

### 7.3 Stack-Level vs Resource-Level Transforms

**Stack-level** — applied before any resources are created:

```typescript
// Runs for every resource in the stack
pulumi.runtime.registerResourceTransform((args) => {
  // Force all resources to be protected
  args.opts.protect = true;
  return { props: args.props, opts: args.opts };
});
```

**Resource-level** — applied to a specific component and all its children via `transforms` option:

```typescript
const vpc = new Vpc("prod-vpc", { cidrBlock: "10.0.0.0/16" }, {
  transforms: [(args) => {
    // Only applies to this Vpc component and its children
    if (args.type === "aws:ec2/subnet:Subnet") {
      args.props["mapPublicIpOnLaunch"] = false;
    }
    return { props: args.props, opts: args.opts };
  }],
});
```

### 7.4 Async Transforms

The new API supports async transforms, useful for fetching external data during transformation:

```typescript
pulumi.runtime.registerResourceTransform(async (args) => {
  if (args.type === "aws:ec2/instance:Instance") {
    // Look up the latest approved AMI asynchronously
    const ami = await aws.ec2.getAmi({
      mostRecent: true,
      owners: ["self"],
      filters: [{ name: "tag:Approved", values: ["true"] }],
    });
    args.props["ami"] = ami.id;
  }
  return { props: args.props, opts: args.opts };
});
```

### 7.5 Transforms with Packaged Components (awsx)

Transforms penetrate into packaged components like `@pulumi/awsx`. This lets you modify resources inside third-party components:

```typescript
import * as awsx from "@pulumi/awsx";

// Force all SecurityGroup resources inside awsx VPC to have specific rules
pulumi.runtime.registerResourceTransform((args) => {
  if (args.type === "aws:ec2/securityGroup:SecurityGroup") {
    // Inject a tag on all security groups, even those created by awsx internally
    args.props["tags"] = {
      ...(args.props["tags"] || {}),
      SecurityReview: "pending",
    };
  }
  return { props: args.props, opts: args.opts };
});

// awsx creates security groups internally — the transform above applies to them
const vpc = new awsx.ec2.Vpc("app-vpc", { natGateways: { strategy: "Single" } });
```

### 7.6 Injecting Tags and Options Globally

**Comprehensive tagging transform:**

```typescript
const defaultTags: Record<string, string> = {
  Environment: pulumi.getStack(),
  Project: pulumi.getProject(),
  ManagedBy: "pulumi",
  Team: "platform",
  CostCenter: "eng-platform-42",
};

pulumi.runtime.registerResourceTransform((args) => {
  // AWS resources: merge into `tags`
  if (args.type.startsWith("aws:")) {
    if ("tags" in (args.props || {})) {
      args.props["tags"] = { ...defaultTags, ...(args.props["tags"] || {}) };
    }
  }

  // Azure resources: merge into `tags`
  if (args.type.startsWith("azure-native:") || args.type.startsWith("azure:")) {
    if ("tags" in (args.props || {})) {
      args.props["tags"] = { ...defaultTags, ...(args.props["tags"] || {}) };
    }
  }

  // GCP resources: merge into `labels`
  if (args.type.startsWith("gcp:")) {
    if ("labels" in (args.props || {})) {
      args.props["labels"] = { ...defaultTags, ...(args.props["labels"] || {}) };
    }
  }

  return { props: args.props, opts: args.opts };
});
```

**Global option injection** — e.g., protect all databases:

```typescript
pulumi.runtime.registerResourceTransform((args) => {
  const protectedTypes = [
    "aws:rds/instance:Instance",
    "aws:rds/cluster:Cluster",
    "aws:dynamodb/table:Table",
    "aws:s3/bucket:Bucket",
  ];
  if (protectedTypes.includes(args.type)) {
    args.opts.protect = true;
  }

  // Force deletion protection on RDS
  if (args.type === "aws:rds/instance:Instance") {
    args.props["deletionProtection"] = true;
  }

  return { props: args.props, opts: args.opts };
});
```

---

## 8. Aliases

Aliases tell Pulumi that a resource's old identity maps to a new identity, preventing delete-and-recreate on rename/move operations.

### 8.1 Renaming Resources

```typescript
// Before: resource named "my-bucket"
const bucket = new aws.s3.Bucket("my-bucket", { /* ... */ });

// After: rename to "data-bucket" without replacing
const bucket = new aws.s3.Bucket("data-bucket", { /* ... */ }, {
  aliases: [{ name: "my-bucket" }],
});
```

The alias tells the engine: "the resource previously known as `my-bucket` is now `data-bucket`." The URN changes but the physical resource is preserved.

### 8.2 Moving Between Components

When moving a resource from one parent component to another, or from no parent to a component:

```typescript
// Before: bucket was a top-level resource (no parent)
const bucket = new aws.s3.Bucket("data", {});

// After: moved inside a component
class DataLayer extends pulumi.ComponentResource {
  constructor(name: string, opts?: pulumi.ComponentResourceOptions) {
    super("acme:data:DataLayer", name, {}, opts);

    const bucket = new aws.s3.Bucket("data", {}, {
      parent: this,
      aliases: [{
        // The old URN had no parent, so alias with noParent: true
        name: "data",
        noParent: true,
      }],
    });

    this.registerOutputs({});
  }
}
```

**Moving between two components:**

```typescript
const bucket = new aws.s3.Bucket("data", {}, {
  parent: newParentComponent,
  aliases: [{
    name: "data",
    parent: oldParentComponent, // reference to the old parent
  }],
});
```

### 8.3 Alias Types

An alias can be a full URN string or a structured object with these fields:

```typescript
interface Alias {
  name?: string;          // Old resource name
  type?: string;          // Old resource type (for type migrations)
  parent?: Resource;      // Old parent resource
  noParent?: boolean;     // Old resource had no parent (was top-level)
  project?: string;       // Old project name
  stack?: string;         // Old stack name
}
```

**Full URN alias** — when you know the exact old URN:
```typescript
{
  aliases: ["urn:pulumi:dev::my-project::aws:s3/bucket:Bucket::old-name"],
}
```

**Name-only alias** — just the name changed:
```typescript
{ aliases: [{ name: "old-name" }] }
```

**Type alias** — the resource type changed (rare, e.g., provider upgrade):
```typescript
{ aliases: [{ type: "aws:s3/bucket:Bucket" }] }
```

**Project/stack alias** — moved to a different project or stack name:
```typescript
{
  aliases: [{
    name: "my-resource",
    project: "old-project-name",
    stack: "old-stack-name",
  }],
}
```

**Parent alias** — moved between parents:
```typescript
{
  aliases: [{
    name: "my-resource",
    parent: oldParentComponent,
  }],
}
```

**Combining multiple aliases** — resource went through multiple renames:
```typescript
const bucket = new aws.s3.Bucket("data-bucket-v3", {}, {
  aliases: [
    { name: "data-bucket-v2" },
    { name: "data-bucket" },
    { name: "my-bucket" },     // original name
  ],
});
```

### 8.4 Bulk Aliasing

When refactoring a component (e.g., renaming the component class or changing its type token), all children get new URNs. Use aliases on the component itself:

```typescript
// Before: type token was "acme:storage:DataBucket"
// After: renamed to "acme:data:StorageLayer"
class StorageLayer extends pulumi.ComponentResource {
  constructor(name: string, opts?: pulumi.ComponentResourceOptions) {
    super("acme:data:StorageLayer", name, {}, {
      ...opts,
      aliases: [
        // Alias the component itself to its old type
        { type: "acme:storage:DataBucket" },
      ],
    });

    // Children automatically resolve because the parent alias
    // establishes the URN mapping for the entire subtree.
    const bucket = new aws.s3.Bucket(`${name}-bucket`, {}, { parent: this });
    const table = new aws.dynamodb.Table(`${name}-table`, {
      hashKey: "id",
      attributes: [{ name: "id", type: "S" }],
    }, { parent: this });

    this.registerOutputs({});
  }
}
```

**Bulk aliasing when changing component name:**

```typescript
// Before: new StorageLayer("old-storage", ...)
// After:  new StorageLayer("new-storage", ...)
const storage = new StorageLayer("new-storage", {
  aliases: [{ name: "old-storage" }],
  // All children URNs are recalculated. If children names are derived from
  // the component name (e.g., `${name}-bucket`), they also need aliases.
});
```

If child names derive from the component name, each child needs its own alias:

```typescript
class StorageLayer extends pulumi.ComponentResource {
  constructor(name: string, opts?: pulumi.ComponentResourceOptions) {
    super("acme:data:StorageLayer", name, {}, opts);

    // If someone changes the component name from "old" to "new",
    // the bucket name changes from "old-bucket" to "new-bucket".
    // Use aliasable naming to avoid this:
    const bucket = new aws.s3.Bucket(`${name}-bucket`, {}, {
      parent: this,
      aliases: opts?.aliases ? [{ name: "old-storage-bucket", parent: this }] : [],
    });

    this.registerOutputs({});
  }
}
```

**Best practice:** Use stable child names that don't derive from the component's `name` parameter, or accept that renaming the component requires aliases on every child.

---

## Quick Reference: When to Use What

| Pattern | Use When |
|---|---|
| **Component Resource** | Grouping related resources into a reusable abstraction |
| **Multi-stack** | Different lifecycle, team ownership, or blast radius requirements |
| **Stack Reference** | Consuming outputs from another stack (VPC IDs, endpoints, etc.) |
| **Dynamic Provider** | Managing a resource with no native Pulumi provider |
| **Automation API** | Building self-service platforms, CI/CD orchestration, testing infra code |
| **Micro-stacks** | Decomposing monoliths, enabling independent deploys per layer |
| **Resource Transform** | Injecting tags, enforcing policies, modifying third-party component internals |
| **Alias** | Refactoring resource names, types, or parent hierarchy without replacement |
