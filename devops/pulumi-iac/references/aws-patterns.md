# AWS Patterns for Pulumi

## Table of Contents
- [VPC with Public/Private Subnets](#vpc-with-publicprivate-subnets)
- [ECS Fargate Service](#ecs-fargate-service)
- [Lambda with API Gateway](#lambda-with-api-gateway)
- [S3 + CloudFront](#s3--cloudfront)
- [RDS with Secrets](#rds-with-secrets)
- [IAM Patterns](#iam-patterns)
- [Cross-Account Access](#cross-account-access)
- [EKS Cluster](#eks-cluster)
- [Step Functions](#step-functions)

---

## VPC with Public/Private Subnets

```typescript
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

const azs = aws.getAvailabilityZonesOutput({ state: "available" });

const vpc = new aws.ec2.Vpc("main", {
    cidrBlock: "10.0.0.0/16",
    enableDnsSupport: true,
    enableDnsHostnames: true,
    tags: { Name: "main-vpc" },
});

const igw = new aws.ec2.InternetGateway("igw", {
    vpcId: vpc.id,
});

const publicSubnets: aws.ec2.Subnet[] = [];
const privateSubnets: aws.ec2.Subnet[] = [];

for (let i = 0; i < 3; i++) {
    const publicSubnet = new aws.ec2.Subnet(`public-${i}`, {
        vpcId: vpc.id,
        cidrBlock: `10.0.${i}.0/24`,
        availabilityZone: azs.names[i],
        mapPublicIpOnLaunch: true,
        tags: { Name: `public-${i}`, Tier: "public" },
    });
    publicSubnets.push(publicSubnet);

    const privateSubnet = new aws.ec2.Subnet(`private-${i}`, {
        vpcId: vpc.id,
        cidrBlock: `10.0.${i + 100}.0/24`,
        availabilityZone: azs.names[i],
        tags: { Name: `private-${i}`, Tier: "private" },
    });
    privateSubnets.push(privateSubnet);
}

const publicRt = new aws.ec2.RouteTable("public-rt", {
    vpcId: vpc.id,
    routes: [{ cidrBlock: "0.0.0.0/0", gatewayId: igw.id }],
});

publicSubnets.forEach((subnet, i) => {
    new aws.ec2.RouteTableAssociation(`public-rta-${i}`, {
        subnetId: subnet.id,
        routeTableId: publicRt.id,
    });
});

// NAT Gateway for private subnets (one per AZ for HA)
const natEips = publicSubnets.map((_, i) =>
    new aws.ec2.Eip(`nat-eip-${i}`, { domain: "vpc" })
);

const natGateways = publicSubnets.map((subnet, i) =>
    new aws.ec2.NatGateway(`nat-${i}`, {
        allocationId: natEips[i].id,
        subnetId: subnet.id,
    })
);

privateSubnets.forEach((subnet, i) => {
    const rt = new aws.ec2.RouteTable(`private-rt-${i}`, {
        vpcId: vpc.id,
        routes: [{ cidrBlock: "0.0.0.0/0", natGatewayId: natGateways[i].id }],
    });
    new aws.ec2.RouteTableAssociation(`private-rta-${i}`, {
        subnetId: subnet.id,
        routeTableId: rt.id,
    });
});

export const vpcId = vpc.id;
export const publicSubnetIds = publicSubnets.map(s => s.id);
export const privateSubnetIds = privateSubnets.map(s => s.id);
```

**Cost tip**: Use a single NAT Gateway for dev/staging. Use one per AZ for production HA.

---

## ECS Fargate Service

```typescript
const cluster = new aws.ecs.Cluster("app", {
    settings: [{ name: "containerInsights", value: "enabled" }],
});

const taskRole = new aws.iam.Role("task-role", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{ Effect: "Allow", Principal: { Service: "ecs-tasks.amazonaws.com" }, Action: "sts:AssumeRole" }],
    }),
});

const executionRole = new aws.iam.Role("exec-role", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{ Effect: "Allow", Principal: { Service: "ecs-tasks.amazonaws.com" }, Action: "sts:AssumeRole" }],
    }),
});

new aws.iam.RolePolicyAttachment("exec-policy", {
    role: executionRole.name,
    policyArn: "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
});

const logGroup = new aws.cloudwatch.LogGroup("app-logs", {
    retentionInDays: 14,
});

const taskDef = new aws.ecs.TaskDefinition("app-task", {
    family: "app",
    cpu: "256",
    memory: "512",
    networkMode: "awsvpc",
    requiresCompatibilities: ["FARGATE"],
    executionRoleArn: executionRole.arn,
    taskRoleArn: taskRole.arn,
    containerDefinitions: pulumi.jsonStringify([{
        name: "app",
        image: "nginx:1.25-alpine",
        essential: true,
        portMappings: [{ containerPort: 80, protocol: "tcp" }],
        logConfiguration: {
            logDriver: "awslogs",
            options: {
                "awslogs-group": logGroup.name,
                "awslogs-region": "us-west-2",
                "awslogs-stream-prefix": "app",
            },
        },
        healthCheck: {
            command: ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
            interval: 30,
            timeout: 5,
            retries: 3,
        },
    }]),
});

const alb = new aws.lb.LoadBalancer("app-alb", {
    internal: false,
    loadBalancerType: "application",
    securityGroups: [albSg.id],
    subnets: publicSubnetIds,
});

const tg = new aws.lb.TargetGroup("app-tg", {
    port: 80,
    protocol: "HTTP",
    targetType: "ip",
    vpcId: vpcId,
    healthCheck: { path: "/", healthyThreshold: 2, interval: 15 },
});

const listener = new aws.lb.Listener("app-listener", {
    loadBalancerArn: alb.arn,
    port: 443,
    protocol: "HTTPS",
    certificateArn: certArn,
    defaultActions: [{ type: "forward", targetGroupArn: tg.arn }],
});

const service = new aws.ecs.Service("app-svc", {
    cluster: cluster.arn,
    taskDefinition: taskDef.arn,
    desiredCount: 2,
    launchType: "FARGATE",
    networkConfiguration: {
        subnets: privateSubnetIds,
        securityGroups: [appSg.id],
        assignPublicIp: false,
    },
    loadBalancers: [{
        targetGroupArn: tg.arn,
        containerName: "app",
        containerPort: 80,
    }],
}, { dependsOn: [listener] });

// Auto-scaling
const scalingTarget = new aws.appautoscaling.Target("app-scaling", {
    maxCapacity: 10,
    minCapacity: 2,
    resourceId: pulumi.interpolate`service/${cluster.name}/${service.name}`,
    scalableDimension: "ecs:service:DesiredCount",
    serviceNamespace: "ecs",
});

new aws.appautoscaling.Policy("cpu-scaling", {
    policyType: "TargetTrackingScaling",
    resourceId: scalingTarget.resourceId,
    scalableDimension: scalingTarget.scalableDimension,
    serviceNamespace: scalingTarget.serviceNamespace,
    targetTrackingScalingPolicyConfiguration: {
        predefinedMetricSpecification: { predefinedMetricType: "ECSServiceAverageCPUUtilization" },
        targetValue: 70,
        scaleInCooldown: 60,
        scaleOutCooldown: 60,
    },
});
```

---

## Lambda with API Gateway

```typescript
const lambdaRole = new aws.iam.Role("lambda-role", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{ Effect: "Allow", Principal: { Service: "lambda.amazonaws.com" }, Action: "sts:AssumeRole" }],
    }),
});

new aws.iam.RolePolicyAttachment("lambda-basic", {
    role: lambdaRole.name,
    policyArn: "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
});

const fn = new aws.lambda.Function("api-handler", {
    runtime: "nodejs20.x",
    handler: "index.handler",
    role: lambdaRole.arn,
    code: new pulumi.asset.AssetArchive({
        "index.js": new pulumi.asset.StringAsset(`
            exports.handler = async (event) => ({
                statusCode: 200,
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ message: "Hello", path: event.rawPath }),
            });
        `),
    }),
    memorySize: 256,
    timeout: 30,
    environment: { variables: { NODE_ENV: "production" } },
});

// HTTP API (API Gateway v2 — simpler, cheaper)
const api = new aws.apigatewayv2.Api("http-api", {
    protocolType: "HTTP",
    corsConfiguration: {
        allowOrigins: ["https://example.com"],
        allowMethods: ["GET", "POST"],
        allowHeaders: ["Content-Type", "Authorization"],
    },
});

const integration = new aws.apigatewayv2.Integration("lambda-int", {
    apiId: api.id,
    integrationType: "AWS_PROXY",
    integrationUri: fn.arn,
    payloadFormatVersion: "2.0",
});

const route = new aws.apigatewayv2.Route("default-route", {
    apiId: api.id,
    routeKey: "$default",
    target: pulumi.interpolate`integrations/${integration.id}`,
});

const stage = new aws.apigatewayv2.Stage("prod", {
    apiId: api.id,
    name: "$default",
    autoDeploy: true,
    accessLogSettings: {
        destinationArn: logGroup.arn,
        format: JSON.stringify({
            requestId: "$context.requestId",
            ip: "$context.identity.sourceIp",
            method: "$context.httpMethod",
            path: "$context.path",
            status: "$context.status",
        }),
    },
});

new aws.lambda.Permission("api-invoke", {
    action: "lambda:InvokeFunction",
    function: fn.name,
    principal: "apigateway.amazonaws.com",
    sourceArn: pulumi.interpolate`${api.executionArn}/*/*`,
});

export const apiUrl = api.apiEndpoint;
```

---

## S3 + CloudFront

```typescript
const bucket = new aws.s3.BucketV2("site", {
    tags: { Purpose: "static-site" },
});

new aws.s3.BucketPublicAccessBlock("site-block", {
    bucket: bucket.id,
    blockPublicAcls: true,
    blockPublicPolicy: true,
    ignorePublicAcls: true,
    restrictPublicBuckets: true,
});

const oai = new aws.cloudfront.OriginAccessIdentity("oai", {
    comment: "OAI for static site",
});

new aws.s3.BucketPolicy("site-policy", {
    bucket: bucket.id,
    policy: pulumi.jsonStringify({
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Principal: { AWS: oai.iamArn },
            Action: "s3:GetObject",
            Resource: pulumi.interpolate`${bucket.arn}/*`,
        }],
    }),
});

const distribution = new aws.cloudfront.Distribution("cdn", {
    enabled: true,
    defaultRootObject: "index.html",
    aliases: ["www.example.com"],
    origins: [{
        originId: "s3",
        domainName: bucket.bucketRegionalDomainName,
        s3OriginConfig: { originAccessIdentity: oai.cloudfrontAccessIdentityPath },
    }],
    defaultCacheBehavior: {
        targetOriginId: "s3",
        viewerProtocolPolicy: "redirect-to-https",
        allowedMethods: ["GET", "HEAD"],
        cachedMethods: ["GET", "HEAD"],
        forwardedValues: { queryString: false, cookies: { forward: "none" } },
        compress: true,
        minTtl: 0,
        defaultTtl: 3600,
        maxTtl: 86400,
    },
    customErrorResponses: [{
        errorCode: 404,
        responseCode: 200,
        responsePagePath: "/index.html",  // SPA routing
        errorCachingMinTtl: 10,
    }],
    restrictions: { geoRestriction: { restrictionType: "none" } },
    viewerCertificate: {
        acmCertificateArn: certArn,  // must be in us-east-1
        sslSupportMethod: "sni-only",
        minimumProtocolVersion: "TLSv1.2_2021",
    },
    priceClass: "PriceClass_100",  // US + Europe only
});

export const cdnUrl = pulumi.interpolate`https://${distribution.domainName}`;
```

**Note**: ACM certificate for CloudFront must be in `us-east-1`. Use an explicit provider if your stack region differs.

---

## RDS with Secrets

```typescript
const dbSubnetGroup = new aws.rds.SubnetGroup("db-subnets", {
    subnetIds: privateSubnetIds,
});

const dbPassword = new aws.secretsmanager.Secret("db-password", {});
const dbPasswordValue = new aws.secretsmanager.SecretVersion("db-password-val", {
    secretId: dbPassword.id,
    secretString: pulumi.secret(
        new random.RandomPassword("db-pass", { length: 32, special: false }).result
    ),
});

const dbSg = new aws.ec2.SecurityGroup("db-sg", {
    vpcId: vpcId,
    ingress: [{
        fromPort: 5432,
        toPort: 5432,
        protocol: "tcp",
        securityGroups: [appSg.id],  // only app can reach DB
    }],
    egress: [{ fromPort: 0, toPort: 0, protocol: "-1", cidrBlocks: ["0.0.0.0/0"] }],
});

const db = new aws.rds.Instance("main-db", {
    engine: "postgres",
    engineVersion: "16.4",
    instanceClass: "db.t4g.medium",
    allocatedStorage: 50,
    maxAllocatedStorage: 200,  // auto-scaling
    dbName: "appdb",
    username: "admin",
    password: dbPasswordValue.secretString,
    dbSubnetGroupName: dbSubnetGroup.name,
    vpcSecurityGroupIds: [dbSg.id],
    multiAz: true,
    storageEncrypted: true,
    backupRetentionPeriod: 14,
    deletionProtection: true,
    performanceInsightsEnabled: true,
    monitoringInterval: 60,
    monitoringRoleArn: rdsMonitoringRole.arn,
    skipFinalSnapshot: false,
    finalSnapshotIdentifier: "main-db-final",
    tags: { Environment: "production" },
}, { protect: true });

// Secret rotation (Lambda-based)
const rotationFn = new aws.lambda.Function("db-rotator", { ... });
new aws.secretsmanager.SecretRotation("db-rotation", {
    secretId: dbPassword.id,
    rotationLambdaArn: rotationFn.arn,
    rotationRules: { automaticallyAfterDays: 30 },
});

export const dbEndpoint = db.endpoint;
export const dbSecretArn = dbPassword.arn;
```

---

## IAM Patterns

### Least-Privilege Role

```typescript
const appRole = new aws.iam.Role("app-role", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Principal: { Service: "ecs-tasks.amazonaws.com" },
            Action: "sts:AssumeRole",
        }],
    }),
    maxSessionDuration: 3600,
});

// Inline policy for specific permissions
new aws.iam.RolePolicy("app-policy", {
    role: appRole.name,
    policy: pulumi.jsonStringify({
        Version: "2012-10-17",
        Statement: [
            {
                Effect: "Allow",
                Action: ["s3:GetObject", "s3:PutObject"],
                Resource: pulumi.interpolate`${dataBucket.arn}/*`,
            },
            {
                Effect: "Allow",
                Action: ["secretsmanager:GetSecretValue"],
                Resource: [dbSecret.arn],
            },
            {
                Effect: "Allow",
                Action: ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage"],
                Resource: [jobQueue.arn],
            },
        ],
    }),
});
```

### Permission Boundary

```typescript
const boundary = new aws.iam.Policy("dev-boundary", {
    policy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [
            {
                Effect: "Allow",
                Action: ["s3:*", "dynamodb:*", "lambda:*", "logs:*", "sqs:*", "sns:*"],
                Resource: "*",
            },
            {
                Effect: "Deny",
                Action: ["iam:*", "organizations:*", "account:*"],
                Resource: "*",
            },
        ],
    }),
});

const devRole = new aws.iam.Role("dev-role", {
    assumeRolePolicy: trustPolicy,
    permissionsBoundary: boundary.arn,
});
```

### Service-Linked Role Check

```typescript
// Some services need service-linked roles created first
const emrSlr = new aws.iam.ServiceLinkedRole("emr-slr", {
    awsServiceName: "elasticmapreduce.amazonaws.com",
});
```

---

## Cross-Account Access

```typescript
// In the target account (where resources live):
const crossAccountRole = new aws.iam.Role("cross-account", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Principal: { AWS: "arn:aws:iam::111111111111:root" },  // source account
            Action: "sts:AssumeRole",
            Condition: { StringEquals: { "sts:ExternalId": "shared-secret-id" } },
        }],
    }),
});

new aws.iam.RolePolicyAttachment("cross-account-policy", {
    role: crossAccountRole.name,
    policyArn: "arn:aws:iam::aws:policy/ReadOnlyAccess",
});

// In the source account (where Pulumi runs):
const targetProvider = new aws.Provider("target-account", {
    region: "us-west-2",
    assumeRole: {
        roleArn: "arn:aws:iam::222222222222:role/cross-account",
        externalId: "shared-secret-id",
        sessionName: "pulumi-deploy",
    },
});

// Create resources in the target account
const remoteBucket = new aws.s3.Bucket("remote-data", {
    tags: { ManagedBy: "pulumi-source-account" },
}, { provider: targetProvider });
```

**Pattern**: Use one Pulumi program to manage resources across multiple AWS accounts. Create a provider per account, each assuming a different role.

---

## EKS Cluster

```typescript
import * as eks from "@pulumi/eks";

// Using @pulumi/eks (higher-level component)
const cluster = new eks.Cluster("prod", {
    vpcId: vpcId,
    subnetIds: privateSubnetIds,
    instanceType: "t3.large",
    desiredCapacity: 3,
    minSize: 2,
    maxSize: 10,
    enabledClusterLogTypes: ["api", "audit", "authenticator"],
    createOidcProvider: true,
    tags: { Environment: "production" },
});

// Managed node group with spot instances
const spotNodeGroup = new eks.ManagedNodeGroup("spot-workers", {
    cluster: cluster,
    instanceTypes: ["t3.large", "t3.xlarge", "t3a.large"],
    capacityType: "SPOT",
    scalingConfig: {
        desiredSize: 3,
        minSize: 1,
        maxSize: 20,
    },
    labels: { "node-type": "spot" },
    taints: { "spot": { value: "true", effect: "PreferNoSchedule" } },
});

// Deploy a Kubernetes workload to the cluster
const k8sProvider = new k8s.Provider("k8s", {
    kubeconfig: cluster.kubeconfigJson,
});

const appNs = new k8s.core.v1.Namespace("app", {
    metadata: { name: "app" },
}, { provider: k8sProvider });

const appDeployment = new k8s.apps.v1.Deployment("app", {
    metadata: { namespace: appNs.metadata.name },
    spec: {
        replicas: 3,
        selector: { matchLabels: { app: "web" } },
        template: {
            metadata: { labels: { app: "web" } },
            spec: {
                containers: [{
                    name: "web",
                    image: "nginx:1.25",
                    ports: [{ containerPort: 80 }],
                    resources: {
                        requests: { cpu: "100m", memory: "128Mi" },
                        limits: { cpu: "500m", memory: "256Mi" },
                    },
                }],
            },
        },
    },
}, { provider: k8sProvider });

export const kubeconfig = cluster.kubeconfig;
```

### IRSA (IAM Roles for Service Accounts)

```typescript
const saRole = new aws.iam.Role("app-sa-role", {
    assumeRolePolicy: pulumi.all([cluster.core.oidcProvider!.arn, cluster.core.oidcProvider!.url])
        .apply(([arn, url]) => JSON.stringify({
            Version: "2012-10-17",
            Statement: [{
                Effect: "Allow",
                Principal: { Federated: arn },
                Action: "sts:AssumeRoleWithWebIdentity",
                Condition: {
                    StringEquals: {
                        [`${url}:sub`]: "system:serviceaccount:app:app-sa",
                        [`${url}:aud`]: "sts.amazonaws.com",
                    },
                },
            }],
        })),
});

const sa = new k8s.core.v1.ServiceAccount("app-sa", {
    metadata: {
        namespace: "app",
        annotations: { "eks.amazonaws.com/role-arn": saRole.arn },
    },
}, { provider: k8sProvider });
```

---

## Step Functions

```typescript
const stateMachineRole = new aws.iam.Role("sfn-role", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{
            Effect: "Allow",
            Principal: { Service: "states.amazonaws.com" },
            Action: "sts:AssumeRole",
        }],
    }),
});

new aws.iam.RolePolicyAttachment("sfn-lambda", {
    role: stateMachineRole.name,
    policyArn: "arn:aws:iam::aws:policy/service-role/AWSLambdaRole",
});

const orderWorkflow = new aws.sfn.StateMachine("order-workflow", {
    roleArn: stateMachineRole.arn,
    definition: pulumi.all([validateFn.arn, chargeFn.arn, shipFn.arn, notifyFn.arn])
        .apply(([validateArn, chargeArn, shipArn, notifyArn]) => JSON.stringify({
            Comment: "Order processing workflow",
            StartAt: "ValidateOrder",
            States: {
                ValidateOrder: {
                    Type: "Task",
                    Resource: validateArn,
                    Next: "ChargePayment",
                    Retry: [{ ErrorEquals: ["States.TaskFailed"], MaxAttempts: 2, IntervalSeconds: 5 }],
                    Catch: [{ ErrorEquals: ["States.ALL"], Next: "NotifyFailure" }],
                },
                ChargePayment: {
                    Type: "Task",
                    Resource: chargeArn,
                    Next: "ShipOrder",
                    Retry: [{ ErrorEquals: ["States.TaskFailed"], MaxAttempts: 3, BackoffRate: 2 }],
                    Catch: [{ ErrorEquals: ["States.ALL"], Next: "NotifyFailure" }],
                },
                ShipOrder: {
                    Type: "Task",
                    Resource: shipArn,
                    Next: "NotifySuccess",
                },
                NotifySuccess: {
                    Type: "Task",
                    Resource: notifyArn,
                    Parameters: { "status": "success", "input.$": "$" },
                    End: true,
                },
                NotifyFailure: {
                    Type: "Task",
                    Resource: notifyArn,
                    Parameters: { "status": "failed", "error.$": "$.Error", "cause.$": "$.Cause" },
                    End: true,
                },
            },
        })),
    type: "STANDARD",
    loggingConfiguration: {
        logDestination: pulumi.interpolate`${sfnLogGroup.arn}:*`,
        includeExecutionData: true,
        level: "ALL",
    },
});

// Trigger from EventBridge
const rule = new aws.cloudwatch.EventRule("order-trigger", {
    eventPattern: JSON.stringify({
        source: ["custom.orders"],
        "detail-type": ["OrderCreated"],
    }),
});

new aws.cloudwatch.EventTarget("sfn-target", {
    rule: rule.name,
    arn: orderWorkflow.arn,
    roleArn: eventBridgeRole.arn,
});

export const stateMachineArn = orderWorkflow.arn;
```

### Express vs Standard Workflows

| Feature | Standard | Express |
|---------|----------|---------|
| Duration | Up to 1 year | Up to 5 minutes |
| Pricing | Per state transition | Per execution + duration |
| Exactly-once | Yes | At-least-once |
| Use case | Long-running orchestration | High-volume data processing |

```typescript
// Express workflow for high-volume processing
const expressWorkflow = new aws.sfn.StateMachine("etl-express", {
    type: "EXPRESS",
    // ...
});
```
