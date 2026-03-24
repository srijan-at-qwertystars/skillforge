# Building and Publishing CDK Construct Libraries

## Table of Contents

- [Overview](#overview)
- [jsii for Multi-Language Support](#jsii-for-multi-language-support)
- [Projen for Project Management](#projen-for-project-management)
- [Construct Testing Patterns](#construct-testing-patterns)
- [API Design Best Practices](#api-design-best-practices)
- [Versioning Strategies](#versioning-strategies)
- [Publishing to Package Registries](#publishing-to-package-registries)
- [Construct Hub Listing](#construct-hub-listing)

---

## Overview

A CDK construct library packages reusable infrastructure patterns as an installable module. Libraries can target a single language or use jsii to publish to npm, PyPI, Maven, and NuGet simultaneously from a single TypeScript codebase.

### Decision: Single-Language vs jsii

| Factor | Single-Language | jsii (Multi-Language) |
|--------|----------------|----------------------|
| Setup complexity | Low | Medium |
| Build time | Fast | Slower (generates bindings) |
| Target audience | Single team | Open-source / org-wide |
| Supported languages | One | TypeScript, Python, Java, C#, Go |
| Recommended for | Internal tools | Published libraries |

---

## jsii for Multi-Language Support

jsii compiles TypeScript into language-specific packages for Python, Java, C#, and Go.

### Project Structure

```
my-construct/
├── src/
│   ├── index.ts           # Public API entry point
│   ├── my-construct.ts    # Main construct
│   └── utils.ts           # Internal utilities
├── test/
│   └── my-construct.test.ts
├── package.json
├── tsconfig.json
├── .jsii                  # Generated: jsii assembly
└── .projenrc.ts           # If using projen
```

### package.json for jsii

```json
{
  "name": "@myorg/my-construct",
  "version": "1.0.0",
  "main": "lib/index.js",
  "types": "lib/index.d.ts",
  "jsii": {
    "outdir": "dist",
    "targets": {
      "python": {
        "distName": "myorg.my-construct",
        "module": "myorg.my_construct"
      },
      "java": {
        "package": "com.myorg.constructs",
        "maven": {
          "groupId": "com.myorg",
          "artifactId": "my-construct"
        }
      },
      "dotnet": {
        "namespace": "MyOrg.Constructs",
        "packageId": "MyOrg.Constructs"
      },
      "go": {
        "moduleName": "github.com/myorg/my-construct-go"
      }
    }
  },
  "peerDependencies": {
    "aws-cdk-lib": "^2.100.0",
    "constructs": "^10.0.0"
  },
  "devDependencies": {
    "aws-cdk-lib": "2.100.0",
    "constructs": "10.0.0",
    "jsii": "~5.0.0",
    "jsii-pacmak": "^1.90.0",
    "jsii-rosetta": "~5.0.0"
  },
  "stability": "stable"
}
```

### jsii Constraints

jsii enforces stricter TypeScript rules than standard TypeScript:

```typescript
// ✅ DO: Export interfaces for all props
export interface MyConstructProps {
  readonly bucketName?: string;
  readonly enableEncryption?: boolean;
}

// ✅ DO: Use readonly properties
export class MyConstruct extends Construct {
  public readonly bucket: s3.IBucket;
}

// ❌ DON'T: Use TypeScript features unsupported by jsii
// - Mapped types, conditional types, template literal types
// - Default exports
// - Overloaded functions
// - Union types (use separate props or enums)

// ❌ DON'T: Use union types
// readonly storage: s3.Bucket | string;

// ✅ DO: Use separate props
// readonly bucket?: s3.IBucket;
// readonly bucketArn?: string;
```

### Building with jsii

```bash
# Compile TypeScript with jsii (instead of tsc)
npx jsii

# Watch mode
npx jsii --watch

# Generate language packages
npx jsii-pacmak

# Output in dist/:
# dist/
#   js/     → npm tarball
#   python/ → wheel + sdist
#   java/   → Maven jar
#   dotnet/ → NuGet nupkg
#   go/     → Go module source
```

---

## Projen for Project Management

projen generates and manages project configuration files. It prevents configuration drift.

### Initialize a Construct Library with projen

```bash
npx projen new awscdk-construct --name my-construct
```

### .projenrc.ts Configuration

```typescript
import { awscdk } from 'projen';

const project = new awscdk.AwsCdkConstructLibrary({
  author: 'Your Name',
  authorAddress: 'you@example.com',
  name: '@myorg/my-construct',
  repositoryUrl: 'https://github.com/myorg/my-construct',
  description: 'A reusable CDK construct for X',

  // CDK version
  cdkVersion: '2.100.0',

  // jsii multi-language targets
  publishToPypi: {
    distName: 'myorg.my-construct',
    module: 'myorg.my_construct',
  },
  publishToMaven: {
    javaPackage: 'com.myorg.constructs',
    mavenGroupId: 'com.myorg',
    mavenArtifactId: 'my-construct',
    mavenServerId: 'ossrh',
    mavenRepositoryUrl: 'https://s01.oss.sonatype.org/service/local/staging/deploy/maven2/',
  },
  publishToNuget: {
    dotNetNamespace: 'MyOrg.Constructs',
    packageId: 'MyOrg.Constructs',
  },
  publishToGo: {
    moduleName: 'github.com/myorg/my-construct-go',
  },

  // Dependencies
  deps: [],
  peerDeps: [],
  devDeps: ['cdk-nag'],

  // Testing
  jestOptions: {
    jestConfig: {
      testPathIgnorePatterns: ['/node_modules/', '/cdk.out/'],
    },
  },

  // Automation
  autoApproveUpgrades: true,
  autoApproveOptions: {
    allowedUsernames: ['github-bot'],
  },

  // Stability
  stability: 'experimental',

  // License
  license: 'Apache-2.0',
});

project.synth();
```

### Key projen Commands

```bash
# Regenerate all managed files (after editing .projenrc.ts)
npx projen

# Build (compile + test + package)
npx projen build

# Run tests
npx projen test

# Bump version
npx projen bump

# Release
npx projen release
```

**Important**: Never edit projen-managed files directly. They have a header:
```
# ~~ Generated by projen. To modify, edit .projenrc.ts and run "npx projen".
```

---

## Construct Testing Patterns

### Unit Testing with Assertions

```typescript
import { App, Stack } from 'aws-cdk-lib';
import { Template, Match, Capture } from 'aws-cdk-lib/assertions';
import { MyConstruct } from '../src';

describe('MyConstruct', () => {
  let template: Template;

  beforeEach(() => {
    const app = new App();
    const stack = new Stack(app, 'TestStack');
    new MyConstruct(stack, 'Test', {
      bucketName: 'test-bucket',
      enableEncryption: true,
    });
    template = Template.fromStack(stack);
  });

  test('creates an encrypted S3 bucket', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketEncryption: {
        ServerSideEncryptionConfiguration: Match.arrayWith([
          Match.objectLike({
            ServerSideEncryptionByDefault: {
              SSEAlgorithm: 'aws:kms',
            },
          }),
        ]),
      },
    });
  });

  test('creates exactly one bucket', () => {
    template.resourceCountIs('AWS::S3::Bucket', 1);
  });

  test('bucket has correct removal policy', () => {
    template.hasResource('AWS::S3::Bucket', {
      DeletionPolicy: 'Retain',
      UpdateReplacePolicy: 'Retain',
    });
  });
});
```

### Testing with Captures

```typescript
test('Lambda has correct environment variables', () => {
  const envCapture = new Capture();

  template.hasResourceProperties('AWS::Lambda::Function', {
    Environment: {
      Variables: envCapture,
    },
  });

  expect(envCapture.asObject()).toEqual(
    expect.objectContaining({
      TABLE_NAME: expect.any(Object), // Token reference
    })
  );
});
```

### Testing with Match Patterns

```typescript
test('IAM policy grants least-privilege access', () => {
  template.hasResourceProperties('AWS::IAM::Policy', {
    PolicyDocument: {
      Statement: Match.arrayWith([
        Match.objectLike({
          Action: Match.arrayWith(['dynamodb:GetItem', 'dynamodb:PutItem']),
          Effect: 'Allow',
        }),
      ]),
    },
  });
});

test('no wildcard IAM actions', () => {
  const policies = template.findResources('AWS::IAM::Policy');
  for (const [, policy] of Object.entries(policies)) {
    const statements = policy.Properties?.PolicyDocument?.Statement || [];
    for (const stmt of statements) {
      if (Array.isArray(stmt.Action)) {
        expect(stmt.Action).not.toContain('*');
      } else {
        expect(stmt.Action).not.toBe('*');
      }
    }
  }
});
```

### Snapshot Testing

```typescript
test('matches snapshot', () => {
  const app = new App();
  const stack = new Stack(app, 'Test');
  new MyConstruct(stack, 'Test', { enableEncryption: true });
  const template = Template.fromStack(stack);
  expect(template.toJSON()).toMatchSnapshot();
});

// Update snapshots: npx jest --updateSnapshot
```

### Testing Validation Logic

```typescript
test('throws if invalid memory size', () => {
  const app = new App();
  const stack = new Stack(app, 'Test');
  expect(() => {
    new MyConstruct(stack, 'Test', { memorySize: 64 });
  }).toThrow(/memorySize must be between 128 and 10240/);
});
```

### Testing Aspects and cdk-nag

```typescript
import { Annotations } from 'aws-cdk-lib/assertions';
import { AwsSolutionsChecks } from 'cdk-nag';

test('passes cdk-nag AwsSolutions checks', () => {
  const app = new App();
  const stack = new Stack(app, 'Test');
  new MyConstruct(stack, 'Test', { enableEncryption: true });
  Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
  app.synth();

  const warnings = Annotations.fromStack(stack).findWarning(
    '*', Match.stringLikeRegexp('AwsSolutions-.*')
  );
  const errors = Annotations.fromStack(stack).findError(
    '*', Match.stringLikeRegexp('AwsSolutions-.*')
  );

  expect(errors).toHaveLength(0);
  expect(warnings).toHaveLength(0);
});
```

---

## API Design Best Practices

### Props Interface Design

```typescript
// 1. Use descriptive, consistent naming
export interface SecureApiProps {
  // Required props first, then optional
  readonly handler: lambda.IFunction;

  // Group related props with JSDoc
  /** Domain configuration for custom domain names */
  readonly domainName?: string;
  readonly certificate?: acm.ICertificate;
  readonly hostedZone?: route53.IHostedZone;

  // Use enums for constrained choices
  readonly logLevel?: LogLevel;

  // Use Duration, Size types (not raw numbers)
  readonly timeout?: Duration;
  readonly memorySize?: Size;

  // Accept interfaces (I-prefixed), not concrete classes
  readonly vpc?: ec2.IVpc;
  readonly table?: dynamodb.ITable;

  // Provide sensible defaults — document them
  /**
   * Enable WAF protection.
   * @default true
   */
  readonly enableWaf?: boolean;
}

export enum LogLevel {
  DEBUG = 'DEBUG',
  INFO = 'INFO',
  WARN = 'WARN',
  ERROR = 'ERROR',
}
```

### Expose Underlying Resources

```typescript
export class SecureApi extends Construct {
  /** The API Gateway REST API */
  public readonly api: apigw.RestApi;
  /** The CloudWatch log group for API access logs */
  public readonly logGroup: logs.LogGroup;
  /** The WAF Web ACL (if enabled) */
  public readonly webAcl?: wafv2.CfnWebACL;

  // Allow consumers to customize underlying resources
  // They can use escape hatches on exposed constructs
}
```

### Validation

```typescript
constructor(scope: Construct, id: string, props: SecureApiProps) {
  super(scope, id);

  // Validate early with clear messages
  if (props.domainName && !props.certificate) {
    throw new Error('certificate is required when domainName is specified');
  }

  if (props.timeout && props.timeout.toSeconds() > 900) {
    throw new Error('timeout cannot exceed 900 seconds (15 minutes)');
  }
}
```

### Grant Methods

```typescript
export class SecureApi extends Construct {
  public grantInvoke(grantee: iam.IGrantable): iam.Grant {
    return this.api.arnForExecuteApi().grant(grantee, 'execute-api:Invoke');
  }

  public grantRead(grantee: iam.IGrantable): iam.Grant {
    return iam.Grant.addToPrincipal({
      grantee,
      actions: ['execute-api:GET'],
      resourceArns: [this.api.arnForExecuteApi('GET')],
    });
  }
}
```

### Metric Methods

```typescript
export class SecureApi extends Construct {
  public metricLatency(props?: cloudwatch.MetricOptions): cloudwatch.Metric {
    return new cloudwatch.Metric({
      namespace: 'AWS/ApiGateway',
      metricName: 'Latency',
      dimensionsMap: { ApiName: this.api.restApiName },
      statistic: 'p99',
      ...props,
    });
  }
}
```

---

## Versioning Strategies

### Semantic Versioning

Follow semver strictly:
- **MAJOR**: Breaking changes to the construct API (removed props, renamed constructs)
- **MINOR**: New features, new optional props, new constructs
- **PATCH**: Bug fixes, dependency updates, documentation

### Stability Levels

```json
{
  "stability": "experimental"
}
```

| Level | Meaning | Semver |
|-------|---------|--------|
| `experimental` | API may change in any release | Minor = breaking OK |
| `stable` | Strict semver | Major = breaking only |
| `deprecated` | Will be removed | Migration guide required |

### Managing Breaking Changes

```typescript
// 1. Deprecate before removing
/** @deprecated Use `enableEncryptionV2` instead. Will be removed in v3.0. */
readonly enableEncryption?: boolean;
readonly enableEncryptionV2?: EncryptionConfig;

// 2. Support both old and new API temporarily
const encryption = props.enableEncryptionV2 ??
  (props.enableEncryption ? { algorithm: 'AES256' } : undefined);

// 3. Document migration in CHANGELOG.md and README
```

### Automated Versioning with Conventional Commits

```
feat: add WAF support          → minor bump
fix: correct IAM policy        → patch bump
feat!: rename BucketProps      → major bump
BREAKING CHANGE: removed X     → major bump
```

---

## Publishing to Package Registries

### npm (TypeScript/JavaScript)

```bash
# Build and package
npx jsii
npx jsii-pacmak --targets js

# Publish
npm publish dist/js/*.tgz --access public

# Or with scope
npm publish dist/js/*.tgz --access public --registry https://registry.npmjs.org
```

### PyPI (Python)

```bash
npx jsii-pacmak --targets python

# Publish with twine
pip install twine
twine upload dist/python/*

# Requires ~/.pypirc or TWINE_USERNAME/TWINE_PASSWORD env vars
```

### Maven Central (Java)

```bash
npx jsii-pacmak --targets java

# Publish requires:
# 1. GPG key for signing
# 2. Sonatype OSSRH account
# 3. Maven settings.xml with credentials

cd dist/java && mvn deploy
```

### NuGet (.NET)

```bash
npx jsii-pacmak --targets dotnet

# Publish
dotnet nuget push dist/dotnet/*.nupkg \
  --api-key $NUGET_API_KEY \
  --source https://api.nuget.org/v3/index.json
```

### GitHub Actions Release Workflow

```yaml
name: Release
on:
  push:
    branches: [main]
jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm ci
      - run: npx projen release
      - run: npx projen publish:npm
        env:
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
      - run: npx projen publish:pypi
        env:
          TWINE_USERNAME: __token__
          TWINE_PASSWORD: ${{ secrets.PYPI_TOKEN }}
```

---

## Construct Hub Listing

[Construct Hub](https://constructs.dev/) automatically indexes constructs published to npm with the `awscdk` keyword.

### Requirements for Listing

1. **package.json keywords**: Include `awscdk` and `cdk`
```json
{
  "keywords": ["awscdk", "cdk", "aws", "infrastructure"]
}
```

2. **Stability marker**: Set in package.json
```json
{
  "stability": "stable"
}
```

3. **API documentation**: Use JSDoc/TSDoc comments
```typescript
/**
 * A secure API construct that creates an API Gateway REST API
 * with WAF, logging, and custom domain support.
 *
 * @example
 * new SecureApi(this, 'Api', {
 *   handler: myFunction,
 *   domainName: 'api.example.com',
 * });
 */
export class SecureApi extends Construct { }
```

4. **README.md**: Construct Hub renders your README as the landing page. Include:
   - Overview and use case
   - Installation instructions for all target languages
   - Usage examples
   - API documentation link
   - Architecture diagram (optional)

5. **rosetta examples**: Use `jsii-rosetta` to translate TypeScript examples to other languages:
```bash
npx jsii-rosetta extract  # Validates examples compile
```

### Multi-Language Installation in README

````markdown
### TypeScript
```bash
npm install @myorg/my-construct
```

### Python
```bash
pip install myorg.my-construct
```

### Java
```xml
<dependency>
  <groupId>com.myorg</groupId>
  <artifactId>my-construct</artifactId>
  <version>1.0.0</version>
</dependency>
```

### C#
```bash
dotnet add package MyOrg.Constructs
```
````

### Monitoring Your Listing

- Check [constructs.dev](https://constructs.dev/) within 24 hours of publishing
- Ensure documentation renders correctly
- Monitor download stats via npm/PyPI dashboards
