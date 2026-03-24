// =============================================================================
// ComponentResource Template — Pulumi best-practice patterns
// =============================================================================
//
// This template demonstrates the canonical way to build a Pulumi
// ComponentResource in TypeScript. A ComponentResource groups child resources
// into a logical unit with typed inputs, outputs, and proper parenting.
//
// Key patterns shown:
//   1. Input<T> types for accepting promises and outputs
//   2. Optional args with sensible defaults
//   3. Proper type token (pkg:module:Type)
//   4. Child resources with { parent: this }
//   5. registerOutputs() to finalize the component
//   6. Defensive default merging
// =============================================================================

import * as pulumi from "@pulumi/pulumi";

// ---------------------------------------------------------------------------
// Input interface
// ---------------------------------------------------------------------------
// Use pulumi.Input<T> for every property so callers can pass raw values,
// Promises, or Outputs from other resources. Mark truly optional fields with
// "?". Required fields are enforced at compile time.

export interface StaticSiteArgs {
    /** S3/GCS bucket name. If omitted, a name is auto-generated. */
    bucketName?: pulumi.Input<string>;

    /** Path to the local directory containing site assets. */
    sitePath: pulumi.Input<string>;

    /** Custom domain to attach (e.g., "example.com"). Optional. */
    domain?: pulumi.Input<string>;

    /** Enable CDN in front of the bucket. Defaults to true. */
    enableCdn?: pulumi.Input<boolean>;

    /** Key-value tags applied to all child resources. */
    tags?: pulumi.Input<Record<string, pulumi.Input<string>>>;
}

// ---------------------------------------------------------------------------
// Output interface (optional but recommended for consumers)
// ---------------------------------------------------------------------------
// Describes the shape of the component's outputs for downstream consumers
// and stack references.

export interface StaticSiteOutputs {
    /** The URL of the deployed site. */
    siteUrl: pulumi.Output<string>;

    /** The underlying bucket name. */
    bucketName: pulumi.Output<string>;

    /** CDN distribution ID (if CDN is enabled). */
    cdnId?: pulumi.Output<string>;
}

// ---------------------------------------------------------------------------
// Component Resource
// ---------------------------------------------------------------------------
// The type token follows the convention "pkg:module:Type".
//   - pkg     — your package/project name
//   - module  — logical grouping (e.g., "hosting", "networking")
//   - Type    — PascalCase resource name
//
// Example: "mycompany:hosting:StaticSite"

export class StaticSite
    extends pulumi.ComponentResource
    implements StaticSiteOutputs
{
    // Declare outputs as public readonly properties so they are accessible
    // from the outside and appear in `pulumi stack output`.
    public readonly siteUrl: pulumi.Output<string>;
    public readonly bucketName: pulumi.Output<string>;
    public readonly cdnId?: pulumi.Output<string>;

    constructor(
        name: string,
        args: StaticSiteArgs,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        // ---------------------------------------------------------------
        // 1. Call super() FIRST — registers the component in the resource
        //    tree. No child resources may be created before this call.
        //
        //    Arguments:
        //      - type token  (pkg:module:Type)
        //      - logical name
        //      - input args  (passed for display in the Pulumi Console)
        //      - options     (parent, providers, aliases, etc.)
        // ---------------------------------------------------------------
        super("mycompany:hosting:StaticSite", name, args, opts);

        // ---------------------------------------------------------------
        // 2. Merge defaults for optional args
        // ---------------------------------------------------------------
        const enableCdn = args.enableCdn ?? true;
        const tags = args.tags ?? {};

        // ---------------------------------------------------------------
        // 3. Create child resources — always pass { parent: this } so they
        //    appear nested under this component in the resource tree and
        //    inherit its provider and aliases.
        // ---------------------------------------------------------------

        // Example: S3-style bucket (replace with your real provider resource)
        //
        // const bucket = new aws.s3.BucketV2(`${name}-bucket`, {
        //     bucket: args.bucketName,
        //     tags: {
        //         ...tags,
        //         "pulumi:component": "StaticSite",
        //     },
        // }, { parent: this });
        //
        // // Upload site content
        // const siteFiles = new synced.S3BucketFolder(`${name}-content`, {
        //     bucketName: bucket.bucket,
        //     path: args.sitePath,
        // }, { parent: this });
        //
        // // Optional CDN
        // let distribution: aws.cloudfront.Distribution | undefined;
        // if (enableCdn) {
        //     distribution = new aws.cloudfront.Distribution(`${name}-cdn`, {
        //         origins: [{
        //             domainName: bucket.bucketRegionalDomainName,
        //             originId: bucket.id,
        //         }],
        //         enabled: true,
        //         defaultRootObject: "index.html",
        //         // ... additional CDN config
        //     }, { parent: this });
        // }

        // ---------------------------------------------------------------
        // 4. Assign outputs — use pulumi.interpolate or pulumi.output()
        //    to transform child-resource outputs into component outputs.
        // ---------------------------------------------------------------

        // Placeholder outputs (replace with real values from child resources)
        this.bucketName = pulumi.output(args.bucketName ?? `${name}-bucket`);
        this.siteUrl = pulumi.interpolate`https://${this.bucketName}.example.com`;
        // this.cdnId = distribution?.id;

        // ---------------------------------------------------------------
        // 5. registerOutputs() — MUST be called at the end of the
        //    constructor. This signals that all child resources have been
        //    created and finalizes dependency tracking.
        //
        //    Pass an object mapping output names to values. These outputs
        //    are visible in `pulumi stack output` and to stack references.
        // ---------------------------------------------------------------
        this.registerOutputs({
            siteUrl: this.siteUrl,
            bucketName: this.bucketName,
            cdnId: this.cdnId,
        });
    }
}

// ===========================================================================
// Usage Example
// ===========================================================================
//
// import { StaticSite } from "./static-site";
//
// // Create a static site component
// const site = new StaticSite("my-site", {
//     sitePath: "./public",
//     domain: "example.com",
//     enableCdn: true,
//     tags: {
//         environment: pulumi.getStack(),
//         team: "platform",
//     },
// });
//
// // Export outputs from the stack
// export const siteUrl = site.siteUrl;
// export const bucketName = site.bucketName;
//
// ---------------------------------------------------------------------------
// Advanced patterns:
//
// 1. Accepting provider overrides:
//    const site = new StaticSite("site", args, {
//        providers: { aws: usEast1Provider },
//    });
//
// 2. Protecting from accidental deletion:
//    const site = new StaticSite("site", args, { protect: true });
//
// 3. Using aliases for safe renames:
//    const site = new StaticSite("site-v2", args, {
//        aliases: [{ name: "site" }],
//    });
//
// 4. Nested components (components containing other components):
//    Within StaticSite you can create another ComponentResource and
//    pass { parent: this } to nest it. The entire tree is visible in
//    the Pulumi Console.
// ===========================================================================
