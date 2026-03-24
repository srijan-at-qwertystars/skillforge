# Production Infrastructure Patterns with Pulumi

> Battle-tested cloud infrastructure patterns in TypeScript with inline commentary on key decisions.

## Table of Contents

1. [VPC with Public/Private Subnets (AWS)](#1-vpc-with-publicprivate-subnets-aws)
2. [EKS Cluster with Managed Node Groups](#2-eks-cluster-with-managed-node-groups)
3. [Serverless API (Lambda + API Gateway)](#3-serverless-api-lambda--api-gateway)
4. [Static Website (S3 + CloudFront)](#4-static-website-s3--cloudfront)
5. [RDS with Read Replicas](#5-rds-with-read-replicas)
6. [Multi-Region Setup](#6-multi-region-setup)
7. [Kubernetes Deployment on GKE](#7-kubernetes-deployment-on-gke)
8. [Azure Container Apps](#8-azure-container-apps)

---

## 1. VPC with Public/Private Subnets (AWS)

Full VPC using raw `@pulumi/aws` resources for maximum control over networking topology.

```typescript
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

const env = pulumi.getStack();
const vpcCidr = "10.0.0.0/16"; // /16 gives 65,536 addresses — room for growth
const azs = ["us-east-1a", "us-east-1b", "us-east-1c"];
const commonTags = { Environment: env, ManagedBy: "pulumi", Project: "skillforge" };

const vpc = new aws.ec2.Vpc("main-vpc", {
  cidrBlock: vpcCidr,
  enableDnsSupport: true,
  enableDnsHostnames: true, // Required for EKS and service DNS resolution
  tags: { ...commonTags, Name: `${env}-main-vpc` },
});

const igw = new aws.ec2.InternetGateway("igw", {
  vpcId: vpc.id,
  tags: { ...commonTags, Name: `${env}-igw` },
});

// Public subnets — one per AZ, /24 each (256 addresses)
const publicSubnets = azs.map((az, i) =>
  new aws.ec2.Subnet(`public-${i}`, {
    vpcId: vpc.id,
    cidrBlock: `10.0.${i}.0/24`,
    availabilityZone: az,
    mapPublicIpOnLaunch: true, // Instances get public IPs for internet access
    tags: { ...commonTags, Name: `${env}-public-${az}`,
      "kubernetes.io/role/elb": "1" }, // EKS auto-discovery tag
  })
);

// Private subnets — offset by 100 to leave room for future subnet tiers
const privateSubnets = azs.map((az, i) =>
  new aws.ec2.Subnet(`private-${i}`, {
    vpcId: vpc.id,
    cidrBlock: `10.0.${100 + i}.0/24`,
    availabilityZone: az,
    tags: { ...commonTags, Name: `${env}-private-${az}`,
      "kubernetes.io/role/internal-elb": "1" },
  })
);

// Single NAT GW to reduce cost; for HA use one per AZ
const eip = new aws.ec2.Eip("nat-eip", { domain: "vpc", tags: commonTags });
const natGw = new aws.ec2.NatGateway("nat-gw", {
  subnetId: publicSubnets[0].id,
  allocationId: eip.id,
  tags: { ...commonTags, Name: `${env}-nat-gw` },
});

// Public route table — default route through IGW
const publicRt = new aws.ec2.RouteTable("public-rt", {
  vpcId: vpc.id,
  routes: [{ cidrBlock: "0.0.0.0/0", gatewayId: igw.id }],
  tags: { ...commonTags, Name: `${env}-public-rt` },
});
publicSubnets.forEach((s, i) =>
  new aws.ec2.RouteTableAssociation(`pub-rta-${i}`, { subnetId: s.id, routeTableId: publicRt.id })
);

// Private route table — outbound through NAT Gateway
const privateRt = new aws.ec2.RouteTable("private-rt", {
  vpcId: vpc.id,
  routes: [{ cidrBlock: "0.0.0.0/0", natGatewayId: natGw.id }],
  tags: { ...commonTags, Name: `${env}-private-rt` },
});
privateSubnets.forEach((s, i) =>
  new aws.ec2.RouteTableAssociation(`priv-rta-${i}`, { subnetId: s.id, routeTableId: privateRt.id })
);

// NACL for private subnets — restrict inbound to VPC CIDR only
new aws.ec2.NetworkAcl("private-nacl", {
  vpcId: vpc.id,
  subnetIds: privateSubnets.map((s) => s.id),
  ingress: [{ ruleNo: 100, protocol: "-1", action: "allow",
    cidrBlock: vpcCidr, fromPort: 0, toPort: 0 }],
  egress: [{ ruleNo: 100, protocol: "-1", action: "allow",
    cidrBlock: "0.0.0.0/0", fromPort: 0, toPort: 0 }],
  tags: { ...commonTags, Name: `${env}-private-nacl` },
});
// VPC Flow Logs — essential for network auditing
const flowLogGroup = new aws.cloudwatch.LogGroup("vpc-flow-logs", {
  retentionInDays: 30, tags: commonTags,
});
const flowLogRole = new aws.iam.Role("flow-log-role", {
  assumeRolePolicy: JSON.stringify({
    Version: "2012-10-17",
    Statement: [{ Effect: "Allow",
      Principal: { Service: "vpc-flow-logs.amazonaws.com" }, Action: "sts:AssumeRole" }],
  }),
});
new aws.ec2.FlowLog("vpc-flow-log", {
  vpcId: vpc.id, trafficType: "ALL",
  logDestinationType: "cloud-watch-logs",
  logGroupName: flowLogGroup.name, iamRoleArn: flowLogRole.arn, tags: commonTags,
});
```

## 2. EKS Cluster with Managed Node Groups

Production EKS with IRSA support, managed node groups, and essential add-ons.

```typescript
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";
import * as tls from "@pulumi/tls";

const clusterName = `${env}-eks-cluster`;

// Cluster IAM role — EKS control plane needs these managed policies
const clusterRole = new aws.iam.Role("eks-cluster-role", {
  assumeRolePolicy: JSON.stringify({
    Version: "2012-10-17",
    Statement: [{ Effect: "Allow",
      Principal: { Service: "eks.amazonaws.com" }, Action: "sts:AssumeRole" }],
  }),
});
["AmazonEKSClusterPolicy", "AmazonEKSVPCResourceController"].forEach((p) =>
  new aws.iam.RolePolicyAttachment(`cluster-${p}`, {
    role: clusterRole.name, policyArn: `arn:aws:iam::aws:policy/${p}`,
  })
);

const clusterSg = new aws.ec2.SecurityGroup("eks-cluster-sg", {
  vpcId: vpc.id, description: "EKS cluster security group",
  ingress: [{ protocol: "tcp", fromPort: 443, toPort: 443, cidrBlocks: [vpcCidr] }],
  egress: [{ protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"] }],
  tags: { ...commonTags, Name: `${clusterName}-sg` },
});

const eksCluster = new aws.eks.Cluster(clusterName, {
  roleArn: clusterRole.arn, version: "1.29",
  vpcConfig: {
    subnetIds: privateSubnets.map((s) => s.id),
    securityGroupIds: [clusterSg.id],
    endpointPrivateAccess: true,
    endpointPublicAccess: false, // Keep API private; access via VPN/bastion
  },
  enabledClusterLogTypes: ["api", "audit", "authenticator"],
  tags: commonTags,
});

// OIDC provider for IAM Roles for Service Accounts (IRSA)
const oidcUrl = eksCluster.identities[0].oidcs[0].issuer;
const oidcThumbprint = tls.getCertificateOutput({ url: oidcUrl })
  .certificates[0].sha1Fingerprint;
new aws.iam.OpenIdConnectProvider("eks-oidc", {
  url: oidcUrl, clientIdLists: ["sts.amazonaws.com"],
  thumbprintLists: [oidcThumbprint], tags: commonTags,
});

// Node group IAM role
const nodeRole = new aws.iam.Role("eks-node-role", {
  assumeRolePolicy: JSON.stringify({
    Version: "2012-10-17",
    Statement: [{ Effect: "Allow",
      Principal: { Service: "ec2.amazonaws.com" }, Action: "sts:AssumeRole" }],
  }),
});
["AmazonEKSWorkerNodePolicy", "AmazonEKS_CNI_Policy",
 "AmazonEC2ContainerRegistryReadOnly",
 "AmazonSSMManagedInstanceCore", // SSM access for node debugging
].forEach((p) =>
  new aws.iam.RolePolicyAttachment(`node-${p}`, {
    role: nodeRole.name, policyArn: `arn:aws:iam::aws:policy/${p}`,
  })
);

// Launch template — encrypted storage and IMDSv2 to prevent SSRF credential theft
const lt = new aws.ec2.LaunchTemplate("eks-node-lt", {
  instanceType: "m6i.large",
  blockDeviceMappings: [{ deviceName: "/dev/xvda",
    ebs: { volumeSize: 50, volumeType: "gp3", encrypted: true } }],
  monitoring: { enabled: true },
  metadataOptions: { httpTokens: "required", httpPutResponseHopLimit: 2 },
  tags: commonTags,
});

new aws.eks.NodeGroup("primary-nodes", {
  clusterName: eksCluster.name, nodeRoleArn: nodeRole.arn,
  subnetIds: privateSubnets.map((s) => s.id),
  launchTemplate: { id: lt.id, version: pulumi.interpolate`${lt.latestVersion}` },
  scalingConfig: { desiredSize: 3, minSize: 2, maxSize: 10 },
  updateConfig: { maxUnavailable: 1 },
  tags: commonTags,
});

// Essential cluster add-ons managed by AWS
["coredns", "kube-proxy", "vpc-cni"].forEach((addon) =>
  new aws.eks.Addon(`addon-${addon}`, {
    clusterName: eksCluster.name, addonName: addon,
    resolveConflictsOnUpdate: "OVERWRITE", // Let Pulumi own the config
  })
);

// Export kubeconfig for kubectl access
export const kubeconfig = pulumi.interpolate`apiVersion: v1
clusters:
- cluster:
    server: ${eksCluster.endpoint}
    certificate-authority-data: ${eksCluster.certificateAuthorities[0].data}
  name: ${clusterName}
contexts:
- context: { cluster: ${clusterName}, user: ${clusterName} }
  name: ${clusterName}
current-context: ${clusterName}
kind: Config
users:
- name: ${clusterName}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args: ["eks", "get-token", "--cluster-name", "${clusterName}"]`;
```
## 3. Serverless API (Lambda + API Gateway)

HTTP API with Lambda backend, DynamoDB storage, and custom domain.

```typescript
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

const domainName = new pulumi.Config().require("apiDomain");

// DynamoDB with on-demand billing for unpredictable traffic
const table = new aws.dynamodb.Table("api-data", {
  billingMode: "PAY_PER_REQUEST",
  hashKey: "pk", rangeKey: "sk",
  attributes: [{ name: "pk", type: "S" }, { name: "sk", type: "S" }],
  pointInTimeRecovery: { enabled: true }, // Production data safety
  serverSideEncryption: { enabled: true },
  tags: commonTags,
});

const lambdaRole = new aws.iam.Role("api-lambda-role", {
  assumeRolePolicy: JSON.stringify({
    Version: "2012-10-17",
    Statement: [{ Effect: "Allow",
      Principal: { Service: "lambda.amazonaws.com" }, Action: "sts:AssumeRole" }],
  }),
});
new aws.iam.RolePolicyAttachment("lambda-basic-exec", {
  role: lambdaRole.name,
  policyArn: "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
});
// Scoped policy — only allow access to this specific table
new aws.iam.RolePolicy("lambda-dynamo-policy", {
  role: lambdaRole.id,
  policy: table.arn.apply((arn) => JSON.stringify({
    Version: "2012-10-17",
    Statement: [{ Effect: "Allow",
      Action: ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query", "dynamodb:DeleteItem"],
      Resource: [arn, `${arn}/index/*`] }],
  })),
});

const layer = new aws.lambda.LayerVersion("shared-deps", {
  compatibleRuntimes: ["nodejs20.x"],
  code: new pulumi.asset.FileArchive("./layers/shared-deps"),
  layerName: `${env}-shared-deps`,
});

const logGroup = new aws.cloudwatch.LogGroup("api-lambda-logs", {
  name: pulumi.interpolate`/aws/lambda/${env}-api-handler`,
  retentionInDays: 14, tags: commonTags,
});

const fn = new aws.lambda.Function("api-handler", {
  runtime: "nodejs20.x", handler: "index.handler",
  role: lambdaRole.arn, code: new pulumi.asset.FileArchive("./dist/api"),
  memorySize: 512, timeout: 30, layers: [layer.arn],
  environment: { variables: { TABLE_NAME: table.name, NODE_ENV: "production" } },
  tracingConfig: { mode: "Active" }, // X-Ray for distributed tracing
  tags: commonTags,
}, { dependsOn: [logGroup] });

// API Gateway v2 HTTP API — cheaper and faster than REST API
const api = new aws.apigatewayv2.Api("http-api", {
  protocolType: "HTTP",
  corsConfiguration: {
    allowOrigins: [`https://${domainName}`],
    allowMethods: ["GET", "POST", "PUT", "DELETE"],
    allowHeaders: ["Content-Type", "Authorization"], maxAge: 3600,
  },
  tags: commonTags,
});

const integration = new aws.apigatewayv2.Integration("lambda-int", {
  apiId: api.id, integrationType: "AWS_PROXY",
  integrationUri: fn.arn, payloadFormatVersion: "2.0",
});
// Catch-all route — Lambda handles internal routing
new aws.apigatewayv2.Route("default-route", {
  apiId: api.id, routeKey: "$default",
  target: pulumi.interpolate`integrations/${integration.id}`,
});

new aws.apigatewayv2.Stage("prod-stage", {
  apiId: api.id, name: "$default", autoDeploy: true,
  accessLogSettings: {
    destinationArn: logGroup.arn,
    format: JSON.stringify({ requestId: "$context.requestId",
      ip: "$context.identity.sourceIp", status: "$context.status" }),
  },
});
new aws.lambda.Permission("apigw-invoke", {
  action: "lambda:InvokeFunction", function: fn.name,
  principal: "apigateway.amazonaws.com",
  sourceArn: pulumi.interpolate`${api.executionArn}/*/*`,
});

// Custom domain with ACM certificate
const cert = new aws.acm.Certificate("api-cert", {
  domainName, validationMethod: "DNS", tags: commonTags,
});
const apiDomain = new aws.apigatewayv2.DomainName("api-domain", {
  domainName,
  domainNameConfiguration: {
    certificateArn: cert.arn, endpointType: "REGIONAL", securityPolicy: "TLS_1_2",
  },
  tags: commonTags,
});
new aws.apigatewayv2.ApiMapping("api-mapping", {
  apiId: api.id, domainName: apiDomain.domainName, stage: "$default",
});
```

## 4. Static Website (S3 + CloudFront)

S3 origin with Origin Access Control (OAC), CloudFront, and Route53 DNS.

```typescript
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

const siteDomain = new pulumi.Config().require("siteDomain");

// S3 bucket — completely private; CloudFront accesses via OAC
const siteBucket = new aws.s3.BucketV2("site-bucket", {
  bucket: `${env}-${siteDomain}`, tags: commonTags,
});
// Block ALL public access — OAC handles authorized reads
new aws.s3.BucketPublicAccessBlock("site-pab", {
  bucket: siteBucket.id,
  blockPublicAcls: true, blockPublicPolicy: true,
  ignorePublicAcls: true, restrictPublicBuckets: true,
});
new aws.s3.BucketVersioningV2("site-versioning", {
  bucket: siteBucket.id,
  versioningConfiguration: { status: "Enabled" },
});

// ACM cert MUST be in us-east-1 for CloudFront
const usEast1 = new aws.Provider("us-east-1", { region: "us-east-1" });
const cert = new aws.acm.Certificate("site-cert", {
  domainName: siteDomain,
  subjectAlternativeNames: [`www.${siteDomain}`],
  validationMethod: "DNS", tags: commonTags,
}, { provider: usEast1 });

// OAC replaces legacy OAI; supports SSE-KMS and newer S3 features
const oac = new aws.cloudfront.OriginAccessControl("site-oac", {
  name: `${env}-site-oac`, originAccessControlOriginType: "s3",
  signingBehavior: "always", signingProtocol: "sigv4",
});

const distribution = new aws.cloudfront.Distribution("site-cdn", {
  enabled: true, defaultRootObject: "index.html",
  aliases: [siteDomain, `www.${siteDomain}`],
  origins: [{ domainName: siteBucket.bucketRegionalDomainName,
    originId: "s3-origin", originAccessControlId: oac.id }],
  defaultCacheBehavior: {
    targetOriginId: "s3-origin", viewerProtocolPolicy: "redirect-to-https",
    allowedMethods: ["GET", "HEAD", "OPTIONS"], cachedMethods: ["GET", "HEAD"],
    compress: true,
    cachePolicyId: "658327ea-f89d-4fab-a63d-7e88639e58f6", // CachingOptimized
  },
  // SPA routing — return index.html for 403/404 so client-side router works
  customErrorResponses: [
    { errorCode: 403, responseCode: 200, responsePagePath: "/index.html", errorCachingMinTtl: 10 },
    { errorCode: 404, responseCode: 200, responsePagePath: "/index.html", errorCachingMinTtl: 10 },
  ],
  restrictions: { geoRestriction: { restrictionType: "none" } },
  viewerCertificate: { acmCertificateArn: cert.arn,
    sslSupportMethod: "sni-only", minimumProtocolVersion: "TLSv1.2_2021" },
  priceClass: "PriceClass_All", tags: commonTags,
});

// Bucket policy granting CloudFront OAC read access
new aws.s3.BucketPolicy("site-bucket-policy", {
  bucket: siteBucket.id,
  policy: pulumi.all([siteBucket.arn, distribution.arn]).apply(([bArn, dArn]) =>
    JSON.stringify({ Version: "2012-10-17",
      Statement: [{ Effect: "Allow",
        Principal: { Service: "cloudfront.amazonaws.com" },
        Action: "s3:GetObject", Resource: `${bArn}/*`,
        Condition: { StringEquals: { "AWS:SourceArn": dArn } } }],
    })),
});

// Route53 A records pointing to CloudFront
const zone = aws.route53.getZoneOutput({ name: siteDomain });
[siteDomain, `www.${siteDomain}`].forEach((name) =>
  new aws.route53.Record(`record-${name}`, {
    zoneId: zone.zoneId, name, type: "A",
    aliases: [{ name: distribution.domainName,
      zoneId: distribution.hostedZoneId, evaluateTargetHealth: false }],
  })
);
```

## 5. RDS with Read Replicas

Production PostgreSQL with read replica, enhanced monitoring, and automated backups.

```typescript
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";
import * as random from "@pulumi/random";

// Generate password — never hardcode credentials
const dbPassword = new random.RandomPassword("db-pw", {
  length: 32, special: true, overrideSpecial: "!#$%^&*()-_=+",
});
const dbSecret = new aws.secretsmanager.Secret("db-creds", {
  name: `${env}/rds/credentials`, tags: commonTags,
});
new aws.secretsmanager.SecretVersion("db-creds-val", {
  secretId: dbSecret.id,
  secretString: pulumi.interpolate`{"username":"appuser","password":"${dbPassword.result}"}`,
});

const dbSubnetGroup = new aws.rds.SubnetGroup("db-subnets", {
  subnetIds: privateSubnets.map((s) => s.id), tags: commonTags,
});
// Restrict DB access to application security groups only
const dbSg = new aws.ec2.SecurityGroup("db-sg", {
  vpcId: vpc.id, description: "RDS — inbound from app tier only",
  ingress: [{ protocol: "tcp", fromPort: 5432, toPort: 5432,
    securityGroups: [clusterSg.id] }],
  egress: [{ protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"] }],
  tags: { ...commonTags, Name: `${env}-db-sg` },
});

// Custom parameter group for PostgreSQL tuning
const paramGroup = new aws.rds.ParameterGroup("pg-params", {
  family: "postgres16",
  parameters: [
    { name: "shared_preload_libraries", value: "pg_stat_statements", applyMethod: "pending-reboot" },
    { name: "log_min_duration_statement", value: "1000" }, // Log slow queries > 1s
    { name: "idle_in_transaction_session_timeout", value: "60000" },
  ],
  tags: commonTags,
});

// IAM role for RDS Enhanced Monitoring
const monitorRole = new aws.iam.Role("rds-monitor-role", {
  assumeRolePolicy: JSON.stringify({ Version: "2012-10-17",
    Statement: [{ Effect: "Allow",
      Principal: { Service: "monitoring.rds.amazonaws.com" }, Action: "sts:AssumeRole" }] }),
});
new aws.iam.RolePolicyAttachment("rds-monitor-attach", {
  role: monitorRole.name,
  policyArn: "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole",
});

const primary = new aws.rds.Instance("db-primary", {
  engine: "postgres", engineVersion: "16.3",
  instanceClass: "db.r6g.large",
  allocatedStorage: 100, maxAllocatedStorage: 500, // Autoscale up to 500 GB
  dbName: "appdb", username: "appuser", password: dbPassword.result,
  dbSubnetGroupName: dbSubnetGroup.name,
  vpcSecurityGroupIds: [dbSg.id], parameterGroupName: paramGroup.name,
  multiAz: true, // Standby in another AZ for automatic failover
  storageEncrypted: true, storageType: "gp3",
  backupRetentionPeriod: 14,
  backupWindow: "03:00-04:00", maintenanceWindow: "sun:04:00-sun:05:00",
  monitoringInterval: 60, monitoringRoleArn: monitorRole.arn,
  performanceInsightsEnabled: true, performanceInsightsRetentionPeriod: 7,
  deletionProtection: true,
  skipFinalSnapshot: false, finalSnapshotIdentifier: `${env}-db-final`,
  tags: { ...commonTags, Name: `${env}-db-primary` },
});

const replica = new aws.rds.Instance("db-replica", {
  replicateSourceDb: primary.identifier,
  instanceClass: "db.r6g.large", storageEncrypted: true,
  vpcSecurityGroupIds: [dbSg.id], parameterGroupName: paramGroup.name,
  monitoringInterval: 60, monitoringRoleArn: monitorRole.arn,
  performanceInsightsEnabled: true,
  multiAz: false, // Replica doesn't need multi-AZ unless promoted
  skipFinalSnapshot: true,
  tags: { ...commonTags, Name: `${env}-db-replica` },
});

export const primaryEndpoint = primary.endpoint;
export const replicaEndpoint = replica.endpoint;
```

## 6. Multi-Region Setup

Active-passive failover with explicit providers, Route53 health checks, and S3 replication.

```typescript
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

// Explicit providers — never rely on ambient credentials for multi-region
const primaryProvider = new aws.Provider("primary", { region: "us-east-1" });
const secondaryProvider = new aws.Provider("secondary", { region: "eu-west-1" });

const primaryBucket = new aws.s3.BucketV2("primary-bucket", {
  bucket: `${env}-primary-data`, tags: commonTags,
}, { provider: primaryProvider });
new aws.s3.BucketVersioningV2("primary-ver", {
  bucket: primaryBucket.id,
  versioningConfiguration: { status: "Enabled" }, // Required for replication
}, { provider: primaryProvider });

const secondaryBucket = new aws.s3.BucketV2("secondary-bucket", {
  bucket: `${env}-secondary-data`, tags: commonTags,
}, { provider: secondaryProvider });
new aws.s3.BucketVersioningV2("secondary-ver", {
  bucket: secondaryBucket.id,
  versioningConfiguration: { status: "Enabled" },
}, { provider: secondaryProvider });

// Replication role with least-privilege S3 permissions
const replRole = new aws.iam.Role("s3-repl-role", {
  assumeRolePolicy: JSON.stringify({ Version: "2012-10-17",
    Statement: [{ Effect: "Allow",
      Principal: { Service: "s3.amazonaws.com" }, Action: "sts:AssumeRole" }] }),
}, { provider: primaryProvider });

new aws.iam.RolePolicy("s3-repl-policy", {
  role: replRole.id,
  policy: pulumi.all([primaryBucket.arn, secondaryBucket.arn]).apply(
    ([src, dst]) => JSON.stringify({ Version: "2012-10-17",
      Statement: [
        { Effect: "Allow", Action: ["s3:GetReplicationConfiguration", "s3:ListBucket"], Resource: src },
        { Effect: "Allow", Action: ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl"], Resource: `${src}/*` },
        { Effect: "Allow", Action: ["s3:ReplicateObject", "s3:ReplicateDelete"], Resource: `${dst}/*` },
      ] })),
}, { provider: primaryProvider });

new aws.s3.BucketReplicationConfig("crr", {
  bucket: primaryBucket.id, role: replRole.arn,
  rules: [{ id: "replicate-all", status: "Enabled",
    destination: { bucket: secondaryBucket.arn, storageClass: "STANDARD_IA" } }],
}, { provider: primaryProvider });

// Route53 health check monitors primary region
const healthCheck = new aws.route53.HealthCheck("primary-hc", {
  fqdn: "api-primary.example.com", port: 443, type: "HTTPS",
  resourcePath: "/health", failureThreshold: 3, requestInterval: 30,
  tags: { ...commonTags, Name: "primary-health" },
});

const zone = aws.route53.getZoneOutput({ name: "example.com" });

// Failover routing: primary with health check, secondary as passive fallback
new aws.route53.Record("fo-primary", {
  zoneId: zone.zoneId, name: "api.example.com", type: "A",
  setIdentifier: "primary",
  failoverRoutingPolicies: [{ type: "PRIMARY" }],
  healthCheckId: healthCheck.id,
  aliases: [{ name: "primary-alb.us-east-1.elb.amazonaws.com",
    zoneId: "Z35SXDOTRQ7X7K", evaluateTargetHealth: true }],
});
new aws.route53.Record("fo-secondary", {
  zoneId: zone.zoneId, name: "api.example.com", type: "A",
  setIdentifier: "secondary",
  failoverRoutingPolicies: [{ type: "SECONDARY" }],
  aliases: [{ name: "secondary-alb.eu-west-1.elb.amazonaws.com",
    zoneId: "Z32O12XQLNTSW2", evaluateTargetHealth: true }],
});
```

## 7. Kubernetes Deployment on GKE

GKE Standard cluster with a sample app deployed via `@pulumi/kubernetes`.

```typescript
import * as gcp from "@pulumi/gcp";
import * as k8s from "@pulumi/kubernetes";
import * as pulumi from "@pulumi/pulumi";

const project = gcp.config.project!;

// Dedicated VPC for cluster network isolation
const network = new gcp.compute.Network("gke-net", { autoCreateSubnetworks: false });
const subnet = new gcp.compute.Subnetwork("gke-sub", {
  network: network.id, ipCidrRange: "10.10.0.0/20", region: "us-central1",
  secondaryIpRanges: [
    { rangeName: "pods", ipCidrRange: "10.20.0.0/14" },     // Large range for pods
    { rangeName: "services", ipCidrRange: "10.24.0.0/20" },
  ],
});

const cluster = new gcp.container.Cluster("gke-cluster", {
  location: "us-central1", network: network.id, subnetwork: subnet.id,
  removeDefaultNodePool: true, initialNodeCount: 1,
  ipAllocationPolicy: {
    clusterSecondaryRangeName: "pods", servicesSecondaryRangeName: "services",
  },
  workloadIdentityConfig: { workloadPool: `${project}.svc.id.goog` },
  privateClusterConfig: {
    enablePrivateNodes: true,
    enablePrivateEndpoint: false, // Allow kubectl from authorized networks
    masterIpv4CidrBlock: "172.16.0.0/28",
  },
  masterAuthorizedNetworksConfig: {
    cidrBlocks: [{ cidrBlock: "10.0.0.0/8", displayName: "internal" }],
  },
  releaseChannel: { channel: "REGULAR" },
});

new gcp.container.NodePool("primary-pool", {
  cluster: cluster.name, location: "us-central1", nodeCount: 3,
  nodeConfig: {
    machineType: "e2-standard-4",
    oauthScopes: ["https://www.googleapis.com/auth/cloud-platform"],
    workloadMetadataConfig: { mode: "GKE_METADATA" },
    shieldedInstanceConfig: { enableSecureBoot: true, enableIntegrityMonitoring: true },
    diskSizeGb: 50, diskType: "pd-ssd",
  },
  management: { autoRepair: true, autoUpgrade: true },
});

// K8s provider configured with GKE cluster credentials
const k8sProvider = new k8s.Provider("gke-k8s", {
  kubeconfig: pulumi.interpolate`apiVersion: v1
clusters:
- cluster:
    server: https://${cluster.endpoint}
    certificate-authority-data: ${cluster.masterAuth.clusterCaCertificate}
  name: gke
contexts:
- context: { cluster: gke, user: gke }
  name: gke
current-context: gke
kind: Config
users:
- name: gke
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: gke-gcloud-auth-plugin
      installHint: Install gke-gcloud-auth-plugin
      provideClusterInfo: true`,
});

const appLabels = { app: "demo-api", env };
const ns = new k8s.core.v1.Namespace("demo-ns", {
  metadata: { name: `demo-${env}` },
}, { provider: k8sProvider });

new k8s.apps.v1.Deployment("demo-deploy", {
  metadata: { namespace: ns.metadata.name },
  spec: {
    replicas: 3, selector: { matchLabels: appLabels },
    template: {
      metadata: { labels: appLabels },
      spec: { containers: [{
        name: "api", image: "gcr.io/my-project/demo-api:latest",
        ports: [{ containerPort: 8080 }],
        resources: { requests: { cpu: "250m", memory: "256Mi" },
          limits: { cpu: "500m", memory: "512Mi" } },
        livenessProbe: { httpGet: { path: "/healthz", port: 8080 }, initialDelaySeconds: 10 },
        readinessProbe: { httpGet: { path: "/readyz", port: 8080 }, initialDelaySeconds: 5 },
      }] },
    },
  },
}, { provider: k8sProvider });

const svc = new k8s.core.v1.Service("demo-svc", {
  metadata: { namespace: ns.metadata.name, labels: appLabels },
  spec: { type: "ClusterIP", selector: appLabels,
    ports: [{ port: 80, targetPort: 8080 }] },
}, { provider: k8sProvider });

new k8s.networking.v1.Ingress("demo-ingress", {
  metadata: { namespace: ns.metadata.name,
    annotations: { "kubernetes.io/ingress.class": "gce",
      "networking.gke.io/managed-certificates": "demo-cert" } },
  spec: { rules: [{ host: "demo.example.com",
    http: { paths: [{ path: "/", pathType: "Prefix",
      backend: { service: { name: svc.metadata.name, port: { number: 80 } } } }] } }] },
}, { provider: k8sProvider });
```

## 8. Azure Container Apps

Container App with autoscaling, managed identity, ACR integration, and logging.

```typescript
import * as azure from "@pulumi/azure-native";
import * as pulumi from "@pulumi/pulumi";

const rg = new azure.resources.ResourceGroup("app-rg", {
  resourceGroupName: `${env}-containerapp-rg`, location: "eastus2", tags: commonTags,
});

// Log Analytics — required by Container App Environment
const logAnalytics = new azure.operationalinsights.Workspace("logs", {
  resourceGroupName: rg.name, workspaceName: `${env}-logs`,
  sku: { name: "PerGB2018" }, retentionInDays: 30, tags: commonTags,
});
const logKeys = azure.operationalinsights.getSharedKeysOutput({
  resourceGroupName: rg.name, workspaceName: logAnalytics.name,
});

const appEnv = new azure.app.ManagedEnvironment("app-env", {
  resourceGroupName: rg.name, environmentName: `${env}-container-env`,
  appLogsConfiguration: { destination: "log-analytics",
    logAnalyticsConfiguration: {
      customerId: logAnalytics.customerId, sharedKey: logKeys.primarySharedKey! } },
  zoneRedundant: true, // Spread across AZs for HA
  tags: commonTags,
});

// ACR with admin disabled — use managed identity for pulls
const acr = new azure.containerregistry.Registry("app-acr", {
  resourceGroupName: rg.name, registryName: `${env}appacr`,
  sku: { name: "Standard" }, adminUserEnabled: false, tags: commonTags,
});

const identity = new azure.managedidentity.UserAssignedIdentity("app-id", {
  resourceGroupName: rg.name, resourceName: `${env}-app-identity`, tags: commonTags,
});

// AcrPull role so Container App can pull images securely
new azure.authorization.RoleAssignment("acr-pull", {
  principalId: identity.principalId, principalType: "ServicePrincipal",
  roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d",
  scope: acr.id,
});

const app = new azure.app.ContainerApp("demo-app", {
  resourceGroupName: rg.name, containerAppName: `${env}-demo-app`,
  managedEnvironmentId: appEnv.id,
  identity: { type: "UserAssigned", userAssignedIdentities: [identity.id] },
  configuration: {
    ingress: { external: true, targetPort: 8080, transport: "http",
      traffic: [{ latestRevision: true, weight: 100 }] },
    registries: [{ server: acr.loginServer, identity: identity.id }],
    secrets: [{ name: "db-conn", value: "Server=...;Database=...;" }],
  },
  template: {
    containers: [{
      name: "demo-api",
      image: pulumi.interpolate`${acr.loginServer}/demo-api:latest`,
      resources: { cpu: 0.5, memory: "1Gi" },
      env: [
        { name: "ASPNETCORE_ENVIRONMENT", value: "Production" },
        { name: "DB_CONN", secretRef: "db-conn" },
      ],
      probes: [{ type: "Liveness",
        httpGet: { path: "/healthz", port: 8080 },
        initialDelaySeconds: 10, periodSeconds: 30 }],
    }],
    scale: {
      minReplicas: 2, maxReplicas: 10, // Keep 2 replicas minimum for availability
      rules: [{ name: "http-scaling",
        http: { metadata: { concurrentRequests: "50" } } }],
    },
  },
  tags: commonTags,
});

export const appUrl = pulumi.interpolate`https://${app.configuration.apply(
  (c) => c?.ingress?.fqdn)}`;
```

> **Note:** Patterns assume shared variables (`commonTags`, `vpc`, `privateSubnets`, etc.)
> are defined in project scope. Adapt imports and references to your project structure.
