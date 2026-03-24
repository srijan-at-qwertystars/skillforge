# Pulumi SDK API Reference

> **Primary language:** TypeScript (`@pulumi/pulumi`)
> Python (`pulumi`) and Go (`github.com/pulumi/pulumi/sdk/v3`) equivalents noted where behavior diverges.

---

## Table of Contents

- [1. Output\<T\>](#1-outputt)
  - [Constructor & Creation](#constructor--creation)
  - [apply](#apply)
  - [apply Chaining](#apply-chaining)
  - [Output.create](#outputcreate)
  - [Output.isInstance](#outputisinstance)
  - [Output.all](#outputall)
  - [Output.concat](#outputconcat)
  - [Output.secret / Output.unsecret / Output.isSecret](#outputsecret--outputunsecret--outputissecret)
  - [get() — Testing Only](#get--testing-only)
- [2. Input\<T\>](#2-inputt)
  - [Type Definition](#type-definition)
  - [Inputs / InputObject](#inputs--inputobject)
  - [When to Use Input vs Output](#when-to-use-input-vs-output)
- [3. pulumi.interpolate](#3-pulumiinterpolate)
  - [Tagged Template Literal](#tagged-template-literal)
  - [Comparison with apply](#comparison-with-apply)
- [4. pulumi.all](#4-pulumiall)
  - [Combining Multiple Outputs](#combining-multiple-outputs)
  - [Destructuring](#destructuring)
  - [pulumi.all vs Output.all](#pulumiall-vs-outputall)
- [5. ComponentResource](#5-componentresource)
  - [Class Signature](#class-signature)
  - [Constructor Pattern & Type Token](#constructor-pattern--type-token)
  - [registerOutputs](#registeroutputs)
  - [ComponentResourceOptions](#componentresourceoptions)
  - [Building Reusable Libraries](#building-reusable-libraries)
- [6. StackReference](#6-stackreference)
  - [Constructor](#stackreference-constructor)
  - [getOutput / requireOutput](#getoutput--requireoutput)
  - [getOutputDetails](#getoutputdetails)
  - [Typing Outputs & Secret Outputs](#typing-outputs--secret-outputs)
  - [Cross-Org References](#cross-org-references)
- [7. Config](#7-config)
  - [Constructor & Namespacing](#constructor--namespacing)
  - [get / require / getSecret / requireSecret](#get--require--getsecret--requiresecret)
  - [Typed Accessors](#typed-accessors)
  - [Structured Config](#structured-config)
- [8. Provider](#8-provider)
  - [Explicit Providers](#explicit-providers)
  - [Multi-Region / Multi-Account](#multi-region--multi-account)
  - [Provider Inheritance](#provider-inheritance)
  - [Default Providers](#default-providers)
- [9. InvokeOptions](#9-invokeoptions)
- [10. ResourceOptions](#10-resourceoptions)
  - [Full Options Reference](#full-options-reference)
  - [aliases](#aliases)
  - [customTimeouts](#customtimeouts)
  - [deletedWith](#deletedwith)
  - [dependsOn](#dependson)
  - [ignoreChanges](#ignorechanges)
  - [import](#import)
  - [parent](#parent)
  - [protect](#protect)
  - [provider / providers](#provider--providers)
  - [replaceOnChanges](#replaceonchanges)
  - [retainOnDelete](#retainondelete)
  - [transformations / transforms](#transformations--transforms)
  - [additionalSecretOutputs](#additionalsecretoutputs)
  - [deleteBeforeReplace](#deletebeforereplace)
  - [version](#version)
- [11. Dynamic Providers](#11-dynamic-providers)
  - [ResourceProvider Interface](#resourceprovider-interface)
  - [dynamic.Resource Class](#dynamicresource-class)
- [12. Asset & Archive](#12-asset--archive)
  - [Assets: StringAsset, FileAsset, RemoteAsset](#assets-stringasset-fileasset-remoteasset)
  - [Archives: AssetArchive, FileArchive, RemoteArchive](#archives-assetarchive-filearchive-remotearchive)
- [13. Log](#13-log)
  - [Log Functions](#log-functions)
  - [Structured Logging](#structured-logging)
- [14. Runtime Functions](#14-runtime-functions)
  - [getStack / getProject / getOrganization](#getstack--getproject--getorganization)
  - [runtime.setMocks (Testing)](#runtimesetmocks-testing)

---

## 1. Output\<T\>

`Output<T>` is Pulumi's core primitive — a value that may not be known until the resource is created during `pulumi up`. All resource properties are `Output`s. They are monadic: you transform them with `apply`, never by unwrapping directly.

### Constructor & Creation

You rarely construct `Output` directly. Resources produce them, and helper functions wrap plain values:

```typescript
// Wrap a plain value as an Output
const fixed = pulumi.output("us-east-1");        // Output<string>
const fromPromise = pulumi.output(fetchAmi());    // Output<string> from Promise<string>

// Wrap an object whose fields are Inputs into an Output of the resolved object
const obj = pulumi.output({
    vpcId: vpc.id,              // Output<string>
    name: "my-vpc",             // string
    ready: Promise.resolve(true) // Promise<boolean>
});
// obj is Output<{ vpcId: string; name: string; ready: boolean }>
```

```python
# Python
fixed = pulumi.Output.from_input("us-east-1")
obj = pulumi.Output.all(vpc_id=vpc.id, name="my-vpc").apply(lambda args: args)
```

```go
// Go
fixed := pulumi.String("us-east-1")  // pulumi.StringOutput via StringInput
```

### apply

```typescript
apply<U>(func: (value: T) => Input<U>): Output<U>
```

Transform the inner value once it is resolved. The callback receives the **plain** resolved value and returns a plain value, a `Promise`, or another `Output`.

```typescript
const bucket = new aws.s3.Bucket("data");
const bucketUrl: Output<string> = bucket.bucket.apply(name => `s3://${name}`);

// Returning a Promise from apply
const enriched: Output<string> = bucket.arn.apply(async arn => {
    const tags = await fetchTags(arn);
    return `${arn} [${tags.join(",")}]`;
});

// Returning an Output from apply (auto-flattened — no Output<Output<T>>)
const sg = bucket.arn.apply(arn => {
    return new aws.ec2.SecurityGroup("sg", { tags: { bucket: arn } }).id;
});
// sg is Output<string>, not Output<Output<string>>
```

**Gotchas:**
- **Never** call `apply` to create resources conditionally based on the resolved value at preview time — the value may be `undefined` during preview. Guard with `pulumi.runtime.isDryRun()` or use `if` on config values instead.
- The callback must be **synchronous with respect to resource registration**. If you create resources inside `apply`, they will register correctly, but readability suffers — prefer `pulumi.all` or `interpolate` when combining values.
- `apply` callbacks run during both `preview` and `update`. During preview, unknown values appear as `undefined`.

```python
# Python
bucket_url = bucket.bucket.apply(lambda name: f"s3://{name}")
```

```go
// Go
bucketUrl := bucket.Bucket.ApplyT(func(name string) string {
    return fmt.Sprintf("s3://%s", name)
}).(pulumi.StringOutput)
```

### apply Chaining

Chained applies are flattened automatically:

```typescript
const result = vpc.id
    .apply(id => fetchSubnets(id))          // Output<string[]>
    .apply(subnets => subnets.join(","));    // Output<string>
```

Prefer `pulumi.all` when combining values from **different** resources to avoid deeply nested callbacks:

```typescript
// ❌ Nested applies — hard to read
const combined = vpc.id.apply(vpcId =>
    subnet.id.apply(subnetId => `${vpcId}/${subnetId}`)
);

// ✅ Use pulumi.all instead
const combined = pulumi.all([vpc.id, subnet.id])
    .apply(([vpcId, subnetId]) => `${vpcId}/${subnetId}`);
```

### Output.create

```typescript
static create<T>(val: Input<T>): Output<T>
```

Converts any `Input<T>` (plain value, Promise, or Output) into an `Output<T>`. Equivalent to `pulumi.output(val)`.

```typescript
const out = Output.create("hello");           // Output<string>
const out2 = Output.create(Promise.resolve(5)); // Output<number>
```

### Output.isInstance

```typescript
static isInstance<T>(obj: any): obj is Output<T>
```

Type guard for checking if a value is an `Output`.

```typescript
function normalize(val: string | Output<string>): Output<string> {
    if (Output.isInstance(val)) {
        return val;
    }
    return pulumi.output(val);
}
```

### Output.all

```typescript
// Array form
static all<T>(values: Input<T>[]): Output<T[]>

// Tuple form (preserves types)
static all<T1, T2>(values: [Input<T1>, Input<T2>]): Output<[T1, T2]>
// ... overloads up to 8 elements

// Record form
static all<T>(values: { [K in keyof T]: Input<T[K]> }): Output<T>
```

Combine multiple `Input`s into a single `Output`. Resolves when all inputs resolve.

```typescript
// Array form
const ids = Output.all([vpc.id, subnet.id, sg.id]);
// ids: Output<[string, string, string]>

// Record/object form
const info = Output.all({ vpcId: vpc.id, region: "us-east-1", cidr: vpc.cidrBlock });
// info: Output<{ vpcId: string; region: string; cidr: string }>

info.apply(({ vpcId, region, cidr }) => {
    // All values are plain strings here
});
```

**Gotcha:** `Output.all` and `pulumi.all` are the same function. Use whichever reads better in context.

### Output.concat

```typescript
static concat(...values: Input<string>[]): Output<string>
```

Concatenate strings and `Output<string>`s. Simpler than `all` + `apply` for string building.

```typescript
const greeting = Output.concat("Hello, ", user.name, "! Your ID is ", user.id);
// greeting: Output<string>
```

**Gotcha:** Only works with string inputs. For non-string Outputs, convert inside `apply` first, or use `pulumi.interpolate`.

### Output.secret / Output.unsecret / Output.isSecret

```typescript
static secret<T>(val: Input<T>): Output<T>     // marks as secret
static unsecret<T>(val: Output<T>): Output<T>  // removes secret marking
static isSecret<T>(val: Output<T>): Promise<boolean>
```

Secrets are encrypted in state. Any `Output` derived from a secret (via `apply`) is automatically secret.

```typescript
const dbPassword = pulumi.secret("hunter2");
// dbPassword is encrypted in the state file

const connectionString = pulumi.interpolate`postgres://admin:${dbPassword}@${db.endpoint}/mydb`;
// connectionString is automatically secret because dbPassword is secret

// Check if an output is secret
const isSecret = await Output.isSecret(connectionString); // true

// Explicitly remove secret marking (use with caution)
const plainPassword = Output.unsecret(dbPassword);
```

```python
# Python
db_password = pulumi.Output.secret("hunter2")
plain = pulumi.Output.unsecret(db_password)
```

**Gotcha:** `Output.unsecret` does NOT decrypt anything — it only removes the metadata that tells Pulumi to encrypt the value in state. The value is still the same.

### get() — Testing Only

```typescript
get(): T  // THROWS at runtime outside of unit tests
```

Synchronously retrieves the underlying value. **Only works when mocks are enabled** via `pulumi.runtime.setMocks()`. Throws `Error` in normal Pulumi programs.

```typescript
// ✅ In a test file with setMocks active:
const name = bucket.bucket.get(); // "my-bucket-abc123"

// ❌ In a real Pulumi program:
const name = bucket.bucket.get(); // throws Error
```

---

## 2. Input\<T\>

### Type Definition

```typescript
type Input<T> = T | Promise<T> | OutputInstance<T>;
```

`Input<T>` is the **parameter type** for resource properties. It means: "I accept a plain value, a Promise, or an Output." This is why you can pass both literal strings and Outputs to resource constructors.

```typescript
// All valid — the constructor accepts Input<string>
new aws.s3.Bucket("b", { bucket: "literal" });
new aws.s3.Bucket("b", { bucket: Promise.resolve("from-promise") });
new aws.s3.Bucket("b", { bucket: otherBucket.bucket }); // Output<string>
```

### Inputs / InputObject

```typescript
// Unwrap all properties of T to their Input forms
type Inputs<T> = {
    [K in keyof T]: Input<T[K]>;
};

// Recursive: every nested property also becomes Input
type InputObject<T> = {
    [K in keyof T]: Input<T[K]> extends object ? InputObject<T[K]> : Input<T[K]>;
};
```

Resource `Args` types use `Inputs` so every property accepts plain values or Outputs:

```typescript
interface BucketArgs {
    bucket?: Input<string>;
    acl?: Input<string>;
    tags?: Input<{ [key: string]: Input<string> }>;
}
```

### When to Use Input vs Output

| Scenario | Use |
|---|---|
| Function/resource **parameter** | `Input<T>` |
| Function **return value** | `Output<T>` |
| Internal transformation result | `Output<T>` |
| Component property exposed to consumers | `Output<T>` |
| Config value passed to resource | `Input<T>` (Config returns plain) |

```typescript
// Component that accepts Inputs and exposes Outputs
interface VpcArgs {
    cidrBlock: Input<string>;          // accept flexible input
    enableDns?: Input<boolean>;
}

class MyVpc extends pulumi.ComponentResource {
    public readonly vpcId: Output<string>;   // expose resolved output
    // ...
}
```

---

## 3. pulumi.interpolate

### Tagged Template Literal

```typescript
function interpolate(literals: TemplateStringsArray, ...placeholders: Input<any>[]): Output<string>
```

A tagged template literal that handles `Output` values. The cleanest way to build strings from mixed plain values and Outputs.

```typescript
const url = pulumi.interpolate`https://${lb.dnsName}:${port}/api/v1`;
// url: Output<string>

const policy = pulumi.interpolate`arn:aws:s3:::${bucket.bucket}/*`;

// Multi-line works fine
const userData = pulumi.interpolate`#!/bin/bash
echo "Cluster endpoint: ${cluster.endpoint}"
echo "Region: ${region}"
apt-get update -y
`;
```

```python
# Python — use Output.concat or f-string inside apply; no tagged template equivalent
url = pulumi.Output.concat("https://", lb.dns_name, ":", port, "/api/v1")
```

### Comparison with apply

| Feature | `interpolate` | `apply` |
|---|---|---|
| String building | ✅ Ideal | Works but verbose |
| Non-string transforms | ❌ | ✅ Required |
| Multiple Outputs | ✅ Handles automatically | Needs `all` for multiple |
| Readability | ✅ Natural template syntax | ❌ Callback nesting |
| Conditional logic | ❌ | ✅ Full JS inside callback |

```typescript
// ✅ interpolate — for string composition
const connStr = pulumi.interpolate`Server=${db.address};Port=${db.port};Database=app`;

// ✅ apply — for transformations, logic, non-string results
const upperName = bucket.bucket.apply(n => n.toUpperCase());
const port = endpoint.apply(ep => parseInt(ep.split(":")[1]));
```

**Gotchas:**
- `interpolate` calls `.toString()` on each resolved value. For objects, you get `[object Object]`. Use `apply` to extract specific fields first.
- Every expression in `${}` is treated as `Input<any>`. Passing an array will stringify it, not iterate it.

---

## 4. pulumi.all

### Combining Multiple Outputs

```typescript
function all<T extends any[]>(values: [...InputTuple<T>]): Output<T>
function all<T extends object>(values: InputMap<T>): Output<T>
```

`pulumi.all` is an alias for `Output.all`. It waits for all inputs to resolve, then provides them as plain values.

```typescript
const info = pulumi.all([vpc.id, vpc.cidrBlock, subnet.id]);
// info: Output<[string, string, string]>

info.apply(([vpcId, cidr, subnetId]) => {
    console.log(`VPC ${vpcId} (${cidr}), Subnet: ${subnetId}`);
});
```

### Destructuring

```typescript
// Array destructuring inside apply
pulumi.all([cluster.endpoint, cluster.kubeconfig]).apply(([endpoint, kubeconfig]) => {
    return buildKubeConfig(endpoint, kubeconfig);
});

// Object form — named access
pulumi.all({ ep: cluster.endpoint, kc: cluster.kubeconfig }).apply(({ ep, kc }) => {
    return buildKubeConfig(ep, kc);
});
```

```python
# Python
combined = pulumi.Output.all(vpc.id, subnet.id).apply(lambda args: f"{args[0]}/{args[1]}")

# Or with keyword arguments (Python 3)
combined = pulumi.Output.all(vpc_id=vpc.id, subnet_id=subnet.id).apply(
    lambda args: f"{args['vpc_id']}/{args['subnet_id']}"
)
```

```go
// Go
pulumi.All(vpc.ID(), subnet.ID()).ApplyT(func(args []interface{}) string {
    vpcId := args[0].(string)
    subnetId := args[1].(string)
    return fmt.Sprintf("%s/%s", vpcId, subnetId)
})
```

### pulumi.all vs Output.all

They are **identical** — `pulumi.all` is re-exported from `Output.all`. Use whichever reads better:

```typescript
// These are the same
pulumi.all([a, b, c]).apply(...)
Output.all([a, b, c]).apply(...)
```

---

## 5. ComponentResource

### Class Signature

```typescript
abstract class ComponentResource extends Resource {
    constructor(
        type: string,
        name: string,
        args?: Inputs,
        opts?: ComponentResourceOptions,
        remote?: boolean,
    );

    protected registerOutputs(outputs?: Inputs): void;
}
```

### Constructor Pattern & Type Token

The `type` string is a **type token** with the format `<package>:<module>:<type>`. This is a stable identifier used across state snapshots. **Never change it** after resources are deployed, or you will orphan existing state.

```typescript
class MyVpc extends pulumi.ComponentResource {
    public readonly vpcId: Output<string>;
    public readonly publicSubnetIds: Output<string[]>;

    constructor(name: string, args: MyVpcArgs, opts?: pulumi.ComponentResourceOptions) {
        // Type token: "custom:networking:MyVpc"
        super("custom:networking:MyVpc", name, args, opts);

        // Create child resources with { parent: this }
        const vpc = new aws.ec2.Vpc(`${name}-vpc`, {
            cidrBlock: args.cidrBlock,
        }, { parent: this });

        const subnets = args.azs.map((az, i) =>
            new aws.ec2.Subnet(`${name}-subnet-${i}`, {
                vpcId: vpc.id,
                availabilityZone: az,
                cidrBlock: `10.0.${i}.0/24`,
            }, { parent: this })
        );

        this.vpcId = vpc.id;
        this.publicSubnetIds = pulumi.output(subnets.map(s => s.id));

        // MUST call registerOutputs at end of constructor
        this.registerOutputs({
            vpcId: this.vpcId,
            publicSubnetIds: this.publicSubnetIds,
        });
    }
}
```

```python
# Python
class MyVpc(pulumi.ComponentResource):
    def __init__(self, name: str, args: MyVpcArgs, opts: pulumi.ResourceOptions = None):
        super().__init__("custom:networking:MyVpc", name, {}, opts)

        vpc = aws.ec2.Vpc(f"{name}-vpc",
            cidr_block=args.cidr_block,
            opts=pulumi.ResourceOptions(parent=self))

        self.vpc_id = vpc.id
        self.register_outputs({"vpc_id": self.vpc_id})
```

```go
// Go
func NewMyVpc(ctx *pulumi.Context, name string, args *MyVpcArgs, opts ...pulumi.ResourceOption) (*MyVpc, error) {
    component := &MyVpc{}
    err := ctx.RegisterComponentResource("custom:networking:MyVpc", name, component, opts...)
    if err != nil {
        return nil, err
    }
    // ... create child resources with pulumi.Parent(component)
    ctx.RegisterResourceOutputs(component, pulumi.Map{
        "vpcId": vpc.ID(),
    })
    return component, nil
}
```

**Type token gotchas:**
- Format must be `pkg:module:Type`. Using `::` (empty module) is valid: `"mycompany::MyVpc"`.
- Never use `pulumi:providers:*` — that namespace is reserved for provider resources.
- Changing the type token is a **breaking change** — Pulumi matches resources by type + name in state.

### registerOutputs

```typescript
protected registerOutputs(outputs?: Inputs): void
```

Signals that the component's child resources are fully declared. **Always call this at the end of the constructor.** Forgetting it causes:
- `pulumi up` may not display component outputs.
- Dependent resources across stack references may not resolve properly.

Pass the component's public outputs as a map:

```typescript
this.registerOutputs({
    vpcId: this.vpcId,
    endpoint: this.endpoint,
});

// For components with no outputs, still call it:
this.registerOutputs();
```

### ComponentResourceOptions

```typescript
interface ComponentResourceOptions extends ResourceOptions {
    providers?: Record<string, ProviderResource> | ProviderResource[];
}
```

Extends `ResourceOptions` with `providers` — a map of provider instances, keyed by package name, inherited by all child resources.

```typescript
const usEast = new aws.Provider("us-east", { region: "us-east-1" });
const usWest = new aws.Provider("us-west", { region: "us-west-2" });

const stack = new MyMultiRegionStack("prod", {}, {
    providers: {
        aws: usEast,          // child aws resources use us-east-1
        kubernetes: k8sProvider,
    },
});

// Or as an array (package name inferred from provider type)
const stack2 = new MyStack("prod", {}, {
    providers: [usEast, k8sProvider],
});
```

### Building Reusable Libraries

Best practices for publishable components:

```typescript
// 1. Export Args interface
export interface StaticSiteArgs {
    sitePath: Input<string>;
    domain?: Input<string>;
    certificateArn?: Input<string>;
}

// 2. Use stable type token with your package name
export class StaticSite extends pulumi.ComponentResource {
    public readonly bucketName: Output<string>;
    public readonly url: Output<string>;

    constructor(name: string, args: StaticSiteArgs, opts?: pulumi.ComponentResourceOptions) {
        super("acme:web:StaticSite", name, args, opts);

        // 3. Always pass { parent: this } to children
        const bucket = new aws.s3.Bucket(`${name}-bucket`, {
            website: { indexDocument: "index.html" },
        }, { parent: this });

        this.bucketName = bucket.bucket;
        this.url = pulumi.interpolate`http://${bucket.websiteEndpoint}`;

        // 4. Always register outputs
        this.registerOutputs({
            bucketName: this.bucketName,
            url: this.url,
        });
    }
}
```

---

## 6. StackReference

### StackReference Constructor

```typescript
class StackReference extends CustomResource {
    constructor(name: string, args?: StackReferenceArgs, opts?: CustomResourceOptions);
}

interface StackReferenceArgs {
    name?: Input<string>;  // fully qualified stack name: "org/project/stack"
}
```

```typescript
// Reference another stack's outputs
const networkStack = new pulumi.StackReference("network", {
    name: "acme-corp/networking/production",
    //     org      / project   / stack
});
```

**Gotcha:** The `name` arg to the constructor (first arg) is the Pulumi resource name — the `args.name` is the **stack reference string**. They can differ:

```typescript
// Resource name is "infra-ref", stack being referenced is "acme/infra/prod"
const infra = new pulumi.StackReference("infra-ref", {
    name: "acme/infra/prod",
});
```

### getOutput / requireOutput

```typescript
getOutput(name: Input<string>): Output<any>
requireOutput(name: Input<string>): Output<any>   // fails if output doesn't exist
```

```typescript
const vpcId = networkStack.getOutput("vpcId");            // Output<any>
const subnetIds = networkStack.requireOutput("subnetIds"); // throws if missing

// Use in another resource
const sg = new aws.ec2.SecurityGroup("sg", {
    vpcId: vpcId,   // Output<any> is assignable to Input<string>
});
```

```python
# Python
vpc_id = network_stack.get_output("vpcId")
subnet_ids = network_stack.require_output("subnetIds")
```

**Gotcha:** `getOutput` returns `Output<any>`. There is no compile-time type checking. Cast explicitly if needed:

```typescript
const vpcId = networkStack.getOutput("vpcId") as Output<string>;
```

### getOutputDetails

```typescript
getOutputDetails(name: string): Promise<StackReferenceOutputDetails>

interface StackReferenceOutputDetails {
    value?: any;
    secretValue?: any;
}
```

Returns the resolved value **and** indicates whether it is a secret. Only one of `value` or `secretValue` will be set.

```typescript
const details = await networkStack.getOutputDetails("dbPassword");
if (details.secretValue !== undefined) {
    // It's a secret
    const password = details.secretValue as string;
}
```

### Typing Outputs & Secret Outputs

Stack references are untyped by default. Create a helper for type safety:

```typescript
// Wrapper with typed outputs
interface NetworkOutputs {
    vpcId: string;
    subnetIds: string[];
    dbPassword: string; // secret
}

function getNetworkOutput<K extends keyof NetworkOutputs>(
    stack: pulumi.StackReference,
    key: K,
): Output<NetworkOutputs[K]> {
    return stack.getOutput(key) as Output<NetworkOutputs[K]>;
}

const vpcId = getNetworkOutput(networkStack, "vpcId"); // Output<string>
```

Secret outputs from the referenced stack remain secret in the referencing stack automatically.

### Cross-Org References

```typescript
// Reference a stack in a different org
const shared = new pulumi.StackReference("shared-infra", {
    name: "other-org/shared-services/production",
});
```

Requires the current identity to have read access to the referenced stack in the other org.

---

## 7. Config

### Constructor & Namespacing

```typescript
class Config {
    constructor(name?: string);
    readonly name: string;
}
```

Config is namespaced. If no name is given, the current project name is used.

```typescript
const cfg = new pulumi.Config();           // namespace = project name
const awsCfg = new pulumi.Config("aws");   // namespace = "aws"

// Values set via CLI:
// pulumi config set myproject:environment production
// pulumi config set aws:region us-east-1
```

```python
# Python
cfg = pulumi.Config()
aws_cfg = pulumi.Config("aws")
```

### get / require / getSecret / requireSecret

```typescript
get(key: string): string | undefined
require(key: string): string                  // throws if missing
getSecret(key: string): Output<string> | undefined
requireSecret(key: string): Output<string>    // throws if missing, returns secret Output
```

```typescript
const cfg = new pulumi.Config();

const env = cfg.get("environment") ?? "dev";   // optional with default
const domain = cfg.require("domain");          // throws if not set

// Secrets — returned as Output<string>, encrypted in state
const dbPass = cfg.requireSecret("dbPassword");
```

**Gotcha:** `get`/`require` return **plain strings**, not Outputs. Only `getSecret`/`requireSecret` return `Output<string>`. If you need to pass a config value to a resource, plain strings work fine as `Input<string>`.

### Typed Accessors

```typescript
getNumber(key: string): number | undefined
requireNumber(key: string): number
getBoolean(key: string): boolean | undefined
requireBoolean(key: string): boolean
getObject<T>(key: string): T | undefined
requireObject<T>(key: string): T

// Secret variants
getSecretNumber(key: string): Output<number> | undefined
requireSecretNumber(key: string): Output<number>
getSecretBoolean(key: string): Output<boolean> | undefined
requireSecretBoolean(key: string): Output<boolean>
getSecretObject<T>(key: string): Output<T> | undefined
requireSecretObject<T>(key: string): Output<T>
```

```typescript
const replicas = cfg.getNumber("replicas") ?? 3;
const enableMonitoring = cfg.requireBoolean("enableMonitoring");

// Structured config (JSON stored as string)
// Set via: pulumi config set --path 'database.host' db.example.com
// Or:      pulumi config set database '{"host":"db.example.com","port":5432}'
interface DbConfig { host: string; port: number; }
const dbCfg = cfg.requireObject<DbConfig>("database");
console.log(dbCfg.host); // "db.example.com"
```

### Structured Config

Pulumi supports structured (nested) config via `--path`:

```bash
pulumi config set --path 'network.cidr' '10.0.0.0/16'
pulumi config set --path 'network.azCount' 3
pulumi config set --path 'network.public' true
```

```yaml
# Pulumi.dev.yaml
config:
  myproject:network:
    cidr: "10.0.0.0/16"
    azCount: 3
    public: true
```

```typescript
interface NetworkConfig {
    cidr: string;
    azCount: number;
    public: boolean;
}
const netCfg = cfg.requireObject<NetworkConfig>("network");
```

---

## 8. Provider

### Explicit Providers

Every Pulumi resource has an implicit default provider. You can create **explicit** provider instances to control configuration.

```typescript
const euProvider = new aws.Provider("eu", {
    region: "eu-west-1",
    profile: "eu-account",
});

// Pass explicit provider via ResourceOptions
const euBucket = new aws.s3.Bucket("eu-data", {
    bucket: "my-eu-data",
}, { provider: euProvider });
```

```python
# Python
eu_provider = aws.Provider("eu", region="eu-west-1")
eu_bucket = aws.s3.Bucket("eu-data",
    bucket="my-eu-data",
    opts=pulumi.ResourceOptions(provider=eu_provider))
```

### Multi-Region / Multi-Account

```typescript
const regions = ["us-east-1", "us-west-2", "eu-west-1"];

const providers = regions.map(region =>
    new aws.Provider(`aws-${region}`, { region })
);

const buckets = providers.map((provider, i) =>
    new aws.s3.Bucket(`bucket-${regions[i]}`, {}, { provider })
);

// Multi-account via different profiles or assumeRole
const devProvider = new aws.Provider("dev", {
    profile: "dev-account",
    region: "us-east-1",
});

const prodProvider = new aws.Provider("prod", {
    assumeRole: {
        roleArn: "arn:aws:iam::123456789012:role/DeployRole",
    },
    region: "us-east-1",
});
```

### Provider Inheritance

Child resources inherit the provider from their parent. This is the primary mechanism for multi-provider ComponentResources.

```typescript
class RegionalInfra extends pulumi.ComponentResource {
    constructor(name: string, args: {}, opts?: pulumi.ComponentResourceOptions) {
        super("mycompany:infra:RegionalInfra", name, args, opts);

        // This bucket inherits the aws provider from the component's opts
        const bucket = new aws.s3.Bucket(`${name}-bucket`, {}, {
            parent: this,
            // No explicit provider — inherited from component
        });

        this.registerOutputs({});
    }
}

// All child resources use us-west-2
new RegionalInfra("west", {}, {
    providers: { aws: new aws.Provider("west", { region: "us-west-2" }) },
});
```

### Default Providers

If no explicit provider is set and no parent provides one, Pulumi uses the **default provider** — configured via stack config (e.g., `aws:region` in `Pulumi.dev.yaml`). There is one default provider per package per stack.

```yaml
# Pulumi.dev.yaml — configures the default aws provider
config:
  aws:region: us-east-1
```

**Gotcha:** Mixing default and explicit providers for the same package in one program can cause confusion. If you use explicit providers, be consistent.

---

## 9. InvokeOptions

```typescript
interface InvokeOptions {
    provider?: ProviderResource;    // explicit provider for the invoke
    parent?: Resource;              // inherit provider from parent
    async?: boolean;                // deprecated; invokes are always async in modern SDKs
    version?: string;               // provider plugin version
    pluginDownloadURL?: string;     // custom plugin download location
}
```

Used with provider **invoke/lookup** functions (data sources):

```typescript
const ami = await aws.ec2.getAmi({
    mostRecent: true,
    owners: ["amazon"],
    filters: [{ name: "name", values: ["amzn2-ami-hvm-*-x86_64-gp2"] }],
}, { provider: usEastProvider });

// Or with Output-returning variant
const ami = aws.ec2.getAmiOutput({
    mostRecent: true,
    owners: ["amazon"],
}, { provider: usEastProvider });
```

```python
# Python
ami = aws.ec2.get_ami(
    most_recent=True,
    owners=["amazon"],
    opts=pulumi.InvokeOptions(provider=us_east_provider),
)
```

**Gotcha:** The `getXxxOutput` variants (suffix `Output`) return `Output<T>` and participate in the dependency graph. Plain `getXxx` returns `Promise<T>` and does **not** track dependencies. Prefer the `Output` variant when the result feeds into other resources.

---

## 10. ResourceOptions

### Full Options Reference

```typescript
interface ResourceOptions {
    aliases?: Input<URN | Alias>[];
    customTimeouts?: CustomTimeouts;
    deletedWith?: Resource;
    dependsOn?: Input<Resource[]> | Input<Resource>;
    id?: Input<string>;               // for import
    ignoreChanges?: string[];
    import?: string;                   // import existing resource
    parent?: Resource;
    protect?: boolean;
    provider?: ProviderResource;
    providers?: Record<string, ProviderResource> | ProviderResource[];  // ComponentResource only
    replaceOnChanges?: string[];
    retainOnDelete?: boolean;
    transformations?: ResourceTransformation[];  // deprecated
    transforms?: ResourceTransform[];
    version?: string;
    pluginDownloadURL?: string;
    additionalSecretOutputs?: string[];
    deleteBeforeReplace?: boolean;
}
```

### aliases

Rename or re-type a resource without destroying it:

```typescript
const bucket = new aws.s3.Bucket("new-name", {}, {
    aliases: [
        { name: "old-name" },                           // renamed
        { name: "old-name", parent: oldParent },         // reparented
        "urn:pulumi:stack::project::aws:s3/bucket:Bucket::old-name", // full URN
    ],
});
```

### customTimeouts

```typescript
interface CustomTimeouts {
    create?: string;   // e.g. "30m", "1h"
    update?: string;
    delete?: string;
}
```

```typescript
const db = new aws.rds.Instance("prod-db", { /* ... */ }, {
    customTimeouts: {
        create: "60m",
        update: "40m",
        delete: "30m",
    },
});
```

### deletedWith

Skip explicit deletion when the specified parent resource is being deleted (optimization for resources that are implicitly deleted, like child cloud resources):

```typescript
const role = new aws.iam.Role("role", { /* ... */ });
const policy = new aws.iam.RolePolicy("policy", {
    role: role.name,
}, { deletedWith: role });
// When role is deleted, policy deletion is skipped (AWS handles it)
```

### dependsOn

Explicit dependency when there is no natural data dependency:

```typescript
const setup = new Command("setup", { create: "echo done" });
const app = new aws.lambda.Function("app", { /* ... */ }, {
    dependsOn: [setup],  // wait for setup even though no Output is passed
});

// Also accepts a single resource
new aws.s3.BucketObject("obj", { /* ... */ }, {
    dependsOn: bucket,
});
```

**Gotcha:** If you pass an Output from one resource to another, Pulumi automatically creates a dependency. Use `dependsOn` **only** for dependencies that can't be expressed through data flow.

### ignoreChanges

Ignore changes to specific properties on subsequent updates:

```typescript
const vm = new aws.ec2.Instance("web", {
    ami: "ami-12345",
    instanceType: "t3.micro",
    tags: { Name: "web" },
}, {
    ignoreChanges: [
        "ami",          // don't replace when AMI changes
        "tags",         // ignore external tag changes
        "userData",     // ignore user data drift
    ],
});
```

**Gotcha:** Property names use the **Pulumi property name** (camelCase in TS), not the cloud provider's API name. Use `"*"` to ignore all changes (effectively making the resource read-only after creation).

### import

Adopt an existing cloud resource into Pulumi state:

```typescript
const existing = new aws.s3.Bucket("imported", {
    bucket: "my-existing-bucket-name",
}, { import: "my-existing-bucket-name" });
// The import ID is provider-specific (ARN, name, etc.)
```

After importing, run `pulumi up` — Pulumi reads the resource and records it in state. Remove the `import` option on the next run.

**Gotcha:** You must set all required properties to match the existing resource, or `pulumi preview` will show a diff and potentially try to update the resource.

### parent

Establishes a parent-child relationship in the resource tree:

```typescript
const component = new MyComponent("app", {});
const bucket = new aws.s3.Bucket("data", {}, { parent: component });
// URN: urn:pulumi:stack::project::mycompany:app:MyComponent$aws:s3/bucket:Bucket::data
```

Effects: child inherits provider from parent, displays nested in `pulumi up` output, and URN reflects the hierarchy.

### protect

Prevent accidental deletion:

```typescript
const db = new aws.rds.Instance("prod-db", { /* ... */ }, {
    protect: true,
});
// `pulumi destroy` will fail unless protect is first set to false
```

Remove protection: set `protect: false`, run `pulumi up`, then you can destroy.

### provider / providers

See [Provider](#8-provider) section. `provider` sets a single explicit provider; `providers` (ComponentResource only) sets a map for child resource inheritance.

### replaceOnChanges

Force replacement (delete + create) when specified properties change, even if the provider would normally do an in-place update:

```typescript
const instance = new aws.ec2.Instance("web", { /* ... */ }, {
    replaceOnChanges: ["tags.Environment"],
});
// Changing tags.Environment triggers full replacement
```

Use `["*"]` to replace on any change.

### retainOnDelete

Keep the cloud resource when it's removed from the Pulumi program or destroyed:

```typescript
const logs = new aws.s3.Bucket("audit-logs", {}, {
    retainOnDelete: true,
});
// `pulumi destroy` removes it from state but does NOT delete the bucket
```

### transformations / transforms

`transformations` (deprecated) and `transforms` (current) allow programmatic modification of child resource properties and options.

```typescript
// transforms (current API)
const autoTags: pulumi.ResourceTransform = (args) => {
    if (args.type.startsWith("aws:")) {
        return {
            props: {
                ...args.props,
                tags: { ...args.props.tags, ManagedBy: "pulumi", Stack: pulumi.getStack() },
            },
            opts: args.opts,
        };
    }
    return undefined; // no change
};

const component = new MyComponent("app", {}, {
    transforms: [autoTags],
});

// Register a stack-level transform (applies to ALL resources)
pulumi.runtime.registerStackTransform(autoTags);
```

```typescript
// ResourceTransform type signature
type ResourceTransform = (args: ResourceTransformArgs) => ResourceTransformResult | undefined;

interface ResourceTransformArgs {
    resource: Resource;
    type: string;
    name: string;
    props: Record<string, any>;
    opts: ResourceOptions;
}

type ResourceTransformResult = {
    props: Record<string, any>;
    opts: ResourceOptions;
};
```

### additionalSecretOutputs

Mark resource output properties as secret, even if the provider doesn't mark them:

```typescript
const cluster = new aws.eks.Cluster("prod", { /* ... */ }, {
    additionalSecretOutputs: ["certificateAuthority"],
});
// certificateAuthority is now encrypted in state
```

### deleteBeforeReplace

Delete the existing resource **before** creating the replacement (default is create-before-delete):

```typescript
const record = new aws.route53.Record("api", { /* ... */ }, {
    deleteBeforeReplace: true,
});
// Useful when two resources can't coexist (unique constraints)
```

**Gotcha:** This causes downtime. The resource is unavailable between deletion and creation. Use only when create-before-delete isn't possible.

### version

Pin to a specific provider plugin version:

```typescript
const bucket = new aws.s3.Bucket("b", {}, {
    version: "6.0.0",
});
```

Rarely needed — version is typically managed via package.json / requirements.txt.

---

## 11. Dynamic Providers

Dynamic providers let you implement custom CRUD logic in your language of choice, without writing a full Pulumi provider plugin.

### ResourceProvider Interface

```typescript
interface ResourceProvider {
    // Called to validate and optionally transform inputs before create/update
    check?: (olds: any, news: any) => Promise<CheckResult>;

    // Called to compute the diff between old and new inputs
    diff?: (id: string, olds: any, news: any) => Promise<DiffResult>;

    // Create a new resource, return its ID and output properties
    create: (inputs: any) => Promise<CreateResult>;

    // Read the current state of an existing resource
    read?: (id: string, props?: any) => Promise<ReadResult>;

    // Update an existing resource in place
    update?: (id: string, olds: any, news: any) => Promise<UpdateResult>;

    // Delete an existing resource
    delete?: (id: string, props: any) => Promise<void>;
}

interface CreateResult {
    id: string;           // unique ID for the resource
    outs?: any;           // output properties
}

interface DiffResult {
    changes?: boolean;       // true if the resource needs updating
    replaces?: string[];     // properties that force replacement
    stables?: string[];      // properties guaranteed not to change
    deleteBeforeReplace?: boolean;
}

interface CheckResult {
    inputs: any;           // validated/transformed inputs
    failures?: CheckFailure[];
}
```

### dynamic.Resource Class

```typescript
class dynamic.Resource extends CustomResource {
    constructor(
        provider: ResourceProvider,
        name: string,
        props: Inputs,
        opts?: CustomResourceOptions,
    );
}
```

Complete example — a dynamic resource that manages a random password:

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as crypto from "crypto";

const passwordProvider: pulumi.dynamic.ResourceProvider = {
    async create(inputs) {
        const password = crypto.randomBytes(inputs.length || 16).toString("hex");
        return {
            id: crypto.randomUUID(),
            outs: { password, length: inputs.length },
        };
    },

    async diff(id, olds, news) {
        return {
            changes: olds.length !== news.length,
            replaces: olds.length !== news.length ? ["length"] : [],
        };
    },

    async delete(id, props) {
        // Nothing to clean up
    },
};

class RandomPassword extends pulumi.dynamic.Resource {
    public readonly password!: pulumi.Output<string>;
    public readonly length!: pulumi.Output<number>;

    constructor(name: string, args: { length: number }, opts?: pulumi.CustomResourceOptions) {
        super(passwordProvider, name, {
            password: undefined,    // output-only — set by create
            length: args.length,
        }, opts);
    }
}

// Usage
const pwd = new RandomPassword("db-pass", { length: 32 });
export const dbPassword = pulumi.secret(pwd.password);
```

**Gotchas:**
- Dynamic providers run **in-process** during `pulumi up`. They cannot run during `pulumi preview` in all cases — `create` returns `undefined` outputs during preview.
- All inputs and outputs must be **JSON-serializable**. No functions, classes, or circular references.
- Dynamic providers are **TypeScript/Python/Go only** — they are not cross-language. If you need cross-language support, build a native Pulumi provider.
- The `id` returned from `create` must be a stable, unique string. It is used to identify the resource in state.

---

## 12. Asset & Archive

Assets and Archives represent file content for resources like Lambda functions, Cloud Functions, and S3 objects.

### Assets: StringAsset, FileAsset, RemoteAsset

```typescript
class StringAsset extends Asset {
    constructor(text: string);
}

class FileAsset extends Asset {
    constructor(path: string);       // path relative to working directory
}

class RemoteAsset extends Asset {
    constructor(uri: string);        // https://, file://, etc.
}
```

```typescript
import * as pulumi from "@pulumi/pulumi";

// Inline code
const lambdaInline = new aws.lambda.Function("inline", {
    code: new pulumi.asset.AssetArchive({
        "index.js": new pulumi.asset.StringAsset(`
            exports.handler = async (event) => {
                return { statusCode: 200, body: "Hello" };
            };
        `),
    }),
    handler: "index.handler",
    runtime: "nodejs18.x",
    role: role.arn,
});

// File on disk
const configFile = new aws.s3.BucketObject("config", {
    bucket: bucket.id,
    source: new pulumi.asset.FileAsset("./config.json"),
});

// Remote file
const remoteScript = new aws.s3.BucketObject("script", {
    bucket: bucket.id,
    source: new pulumi.asset.RemoteAsset("https://example.com/install.sh"),
});
```

### Archives: AssetArchive, FileArchive, RemoteArchive

```typescript
class AssetArchive extends Archive {
    constructor(assets: Record<string, Asset | Archive>);  // virtual filesystem
}

class FileArchive extends Archive {
    constructor(path: string);       // path to directory or .zip/.tar.gz
}

class RemoteArchive extends Archive {
    constructor(uri: string);        // URL to .zip/.tar.gz
}
```

```typescript
// Directory as Lambda code
const lambdaFromDir = new aws.lambda.Function("app", {
    code: new pulumi.asset.FileArchive("./lambda-src"),
    handler: "index.handler",
    runtime: "nodejs18.x",
    role: role.arn,
});

// Composed archive — virtual directory from mixed sources
const composedArchive = new pulumi.asset.AssetArchive({
    "index.js": new pulumi.asset.FileAsset("./src/handler.js"),
    "config.json": new pulumi.asset.StringAsset(JSON.stringify({ env: "prod" })),
    "lib/": new pulumi.asset.FileArchive("./node_modules"),
});

// Remote zip
const prebuilt = new aws.lambda.Function("prebuilt", {
    code: new pulumi.asset.RemoteArchive(
        "https://releases.example.com/app-v1.2.3.zip"
    ),
    handler: "main.handler",
    runtime: "python3.9",
    role: role.arn,
});
```

**Gotchas:**
- `FileAsset` and `FileArchive` paths are relative to the **working directory** (where `pulumi up` runs), not the source file. Use `path.join(__dirname, ...)` for reliability.
- Pulumi hashes asset content to detect changes. If the content hasn't changed, no update occurs.
- `RemoteAsset`/`RemoteArchive` are fetched at deployment time by the Pulumi engine, not at preview time.

---

## 13. Log

### Log Functions

```typescript
namespace log {
    function debug(msg: string, resource?: Resource, streamId?: number, ephemeral?: boolean): void;
    function info(msg: string, resource?: Resource, streamId?: number, ephemeral?: boolean): void;
    function warn(msg: string, resource?: Resource, streamId?: number, ephemeral?: boolean): void;
    function error(msg: string, resource?: Resource, streamId?: number, ephemeral?: boolean): void;
}
```

```typescript
pulumi.log.info("Deploying to production");
pulumi.log.warn("Using deprecated API version");
pulumi.log.error("Failed to configure database");
pulumi.log.debug("VPC CIDR: 10.0.0.0/16");  // only shown with --debug
```

```python
# Python
pulumi.log.info("Deploying to production")
pulumi.log.warn("Using deprecated API version")
```

```go
// Go
ctx.Log.Info("Deploying to production", nil)
ctx.Log.Warn("Using deprecated API version", nil)
```

### Structured Logging

Associate log messages with specific resources for better `pulumi up` output:

```typescript
const bucket = new aws.s3.Bucket("data");
pulumi.log.info("Bucket created with versioning enabled", bucket);
// Output: "data (aws:s3/bucket:Bucket): Bucket created with versioning enabled"

// Stream ID groups related messages
pulumi.log.info("Step 1: downloading...", bucket, 1);
pulumi.log.info("Step 2: extracting...", bucket, 1);
pulumi.log.info("Step 3: installing...", bucket, 1);

// Ephemeral messages are not persisted in the log history
pulumi.log.info("Progress: 50%...", bucket, undefined, true);
```

**Gotchas:**
- `pulumi.log.error` does **not** throw or halt execution. It marks the deployment as failed but continues processing. Use `throw new Error(...)` to halt.
- `console.log` in Pulumi programs works but messages are interleaved with engine output and may appear at unexpected times. Prefer `pulumi.log.*`.
- Log messages inside `apply` callbacks fire when the output resolves, which may be during preview (with undefined values) or update.

---

## 14. Runtime Functions

### getStack / getProject / getOrganization

```typescript
function getStack(): string;          // current stack name, e.g. "production"
function getProject(): string;        // current project name from Pulumi.yaml
function getOrganization(): string;   // current org name
```

```typescript
const stack = pulumi.getStack();       // "dev"
const project = pulumi.getProject();   // "my-infra"
const org = pulumi.getOrganization();  // "acme-corp"

// Common pattern: use in resource naming and tagging
const baseName = `${project}-${stack}`;

const bucket = new aws.s3.Bucket("data", {
    bucket: `${baseName}-data`,
    tags: {
        Project: project,
        Stack: stack,
        Organization: org,
    },
});

// Stack-conditional logic
if (stack === "production") {
    pulumi.log.warn("Deploying to production!");
}
```

```python
# Python
stack = pulumi.get_stack()
project = pulumi.get_project()
org = pulumi.get_organization()
```

```go
// Go — available on ctx
stack := ctx.Stack()
project := ctx.Project()
org := ctx.Organization()
```

### runtime.setMocks (Testing)

```typescript
function runtime.setMocks(
    mocks: Mocks,
    project?: string,
    stack?: string,
    preview?: boolean,
): void;

interface Mocks {
    // Mock resource creation — return { id, state }
    newResource(args: MockResourceArgs): { id: string; state: Record<string, any> };

    // Mock invoke/data-source calls
    call(args: MockCallArgs): Record<string, any>;
}

interface MockResourceArgs {
    type: string;          // resource type token, e.g. "aws:s3/bucket:Bucket"
    name: string;          // resource name
    inputs: any;           // input properties
    provider: string;      // provider reference
    id: string;            // resource ID (empty for new resources)
    custom: boolean;       // true for CustomResource, false for ComponentResource
}

interface MockCallArgs {
    token: string;         // invoke function token
    args: any;             // invoke arguments
    provider: string;      // provider reference
}
```

Full testing example with Mocha:

```typescript
import * as pulumi from "@pulumi/pulumi";
import { expect } from "chai";

// Set mocks BEFORE importing your Pulumi code
pulumi.runtime.setMocks({
    newResource(args) {
        switch (args.type) {
            case "aws:s3/bucket:Bucket":
                return {
                    id: `${args.name}-id`,
                    state: {
                        ...args.inputs,
                        arn: `arn:aws:s3:::${args.inputs.bucket || args.name}`,
                        bucket: args.inputs.bucket || `${args.name}-bucket`,
                    },
                };
            default:
                return {
                    id: `${args.name}-id`,
                    state: args.inputs,
                };
        }
    },

    call(args) {
        switch (args.token) {
            case "aws:ec2/getAmi:getAmi":
                return { id: "ami-0123456789abcdef0", architecture: "x86_64" };
            default:
                return args.args;
        }
    },
}, "test-project", "test-stack");

// NOW import your infrastructure code
import { bucket, bucketArn } from "../index";

describe("Infrastructure", () => {
    it("bucket should have correct tags", async () => {
        const tags = await bucket.tags.get();
        expect(tags).to.have.property("Environment", "test-stack");
    });

    it("bucket ARN should be well-formed", async () => {
        const arn = bucketArn.get();
        expect(arn).to.match(/^arn:aws:s3:::/);
    });
});
```

```python
# Python testing with setMocks
import pulumi

class MyMocks(pulumi.runtime.Mocks):
    def new_resource(self, args: pulumi.runtime.MockResourceArgs):
        return [f"{args.name}-id", args.inputs]

    def call(self, args: pulumi.runtime.MockCallArgs):
        return {}

pulumi.runtime.set_mocks(MyMocks(), project="test", stack="dev")

# Import infrastructure after setting mocks
from infra import bucket

@pulumi.runtime.test
def test_bucket_name():
    def check(name):
        assert "data" in name
    return bucket.bucket.apply(check)
```

**Gotchas:**
- `setMocks` must be called **before** any Pulumi resource code is imported or executed.
- The `get()` method on Outputs **only works** when mocks are active. It throws in real deployments.
- Mock functions must return values for **every** resource type and invoke token your program uses. Missing mocks cause the test to fail with unclear errors.
- Preview mode (`preview: true`) means all resource outputs are unknown — `get()` returns `undefined`. Test with `preview: false` (the default) to get resolved values.
