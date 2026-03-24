import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

// ─── Config ──────────────────────────────────────────────────────────
const config = new pulumi.Config();
const appName = config.get("appName") ?? "myapp";
const env = pulumi.getStack();
const azs = aws.getAvailabilityZonesOutput({ state: "available" });

function t(tags: Record<string, string> = {}): Record<string, string> {
    return { ...tags, Environment: env, ManagedBy: "pulumi", Project: appName };
}

// ─── VPC ─────────────────────────────────────────────────────────────
const vpc = new aws.ec2.Vpc("vpc", {
    cidrBlock: "10.0.0.0/16",
    enableDnsSupport: true,
    enableDnsHostnames: true,
    tags: t({ Name: `${appName}-vpc` }),
});

const igw = new aws.ec2.InternetGateway("igw", {
    vpcId: vpc.id,
    tags: t({ Name: `${appName}-igw` }),
});

const publicSubnets: aws.ec2.Subnet[] = [];
const privateSubnets: aws.ec2.Subnet[] = [];

for (let i = 0; i < 2; i++) {
    publicSubnets.push(
        new aws.ec2.Subnet(`public-${i}`, {
            vpcId: vpc.id,
            cidrBlock: `10.0.${i}.0/24`,
            availabilityZone: azs.names[i],
            mapPublicIpOnLaunch: true,
            tags: t({ Name: `${appName}-public-${i}`, Tier: "public" }),
        }),
    );
    privateSubnets.push(
        new aws.ec2.Subnet(`private-${i}`, {
            vpcId: vpc.id,
            cidrBlock: `10.0.${i + 100}.0/24`,
            availabilityZone: azs.names[i],
            tags: t({ Name: `${appName}-private-${i}`, Tier: "private" }),
        }),
    );
}

const publicRt = new aws.ec2.RouteTable("public-rt", {
    vpcId: vpc.id,
    routes: [{ cidrBlock: "0.0.0.0/0", gatewayId: igw.id }],
    tags: t({ Name: `${appName}-public-rt` }),
});
publicSubnets.forEach((s, i) =>
    new aws.ec2.RouteTableAssociation(`public-rta-${i}`, {
        subnetId: s.id,
        routeTableId: publicRt.id,
    }),
);

const natEip = new aws.ec2.Eip("nat-eip", { domain: "vpc", tags: t() });
const natGw = new aws.ec2.NatGateway("nat", {
    allocationId: natEip.id,
    subnetId: publicSubnets[0].id,
    tags: t({ Name: `${appName}-nat` }),
});
const privateRt = new aws.ec2.RouteTable("private-rt", {
    vpcId: vpc.id,
    routes: [{ cidrBlock: "0.0.0.0/0", natGatewayId: natGw.id }],
    tags: t({ Name: `${appName}-private-rt` }),
});
privateSubnets.forEach((s, i) =>
    new aws.ec2.RouteTableAssociation(`private-rta-${i}`, {
        subnetId: s.id,
        routeTableId: privateRt.id,
    }),
);

// ─── Security Groups ─────────────────────────────────────────────────
const albSg = new aws.ec2.SecurityGroup("alb-sg", {
    vpcId: vpc.id,
    description: "Allow HTTP/HTTPS inbound to ALB",
    ingress: [
        { fromPort: 80, toPort: 80, protocol: "tcp", cidrBlocks: ["0.0.0.0/0"], description: "HTTP" },
        { fromPort: 443, toPort: 443, protocol: "tcp", cidrBlocks: ["0.0.0.0/0"], description: "HTTPS" },
    ],
    egress: [{ fromPort: 0, toPort: 0, protocol: "-1", cidrBlocks: ["0.0.0.0/0"] }],
    tags: t({ Name: `${appName}-alb-sg` }),
});

const appSg = new aws.ec2.SecurityGroup("app-sg", {
    vpcId: vpc.id,
    description: "Allow traffic from ALB to app containers",
    ingress: [{
        fromPort: 80,
        toPort: 80,
        protocol: "tcp",
        securityGroups: [albSg.id],
        description: "From ALB",
    }],
    egress: [{ fromPort: 0, toPort: 0, protocol: "-1", cidrBlocks: ["0.0.0.0/0"] }],
    tags: t({ Name: `${appName}-app-sg` }),
});

const dbSg = new aws.ec2.SecurityGroup("db-sg", {
    vpcId: vpc.id,
    description: "Allow Postgres from app",
    ingress: [{
        fromPort: 5432,
        toPort: 5432,
        protocol: "tcp",
        securityGroups: [appSg.id],
        description: "Postgres from app",
    }],
    egress: [{ fromPort: 0, toPort: 0, protocol: "-1", cidrBlocks: ["0.0.0.0/0"] }],
    tags: t({ Name: `${appName}-db-sg` }),
});

// ─── ECS Cluster + Fargate Service ──────────────────────────────────
const cluster = new aws.ecs.Cluster("cluster", {
    settings: [{ name: "containerInsights", value: "enabled" }],
    tags: t(),
});

const execRole = new aws.iam.Role("exec-role", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{ Effect: "Allow", Principal: { Service: "ecs-tasks.amazonaws.com" }, Action: "sts:AssumeRole" }],
    }),
    tags: t(),
});
new aws.iam.RolePolicyAttachment("exec-policy", {
    role: execRole.name,
    policyArn: "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
});

const taskRole = new aws.iam.Role("task-role", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{ Effect: "Allow", Principal: { Service: "ecs-tasks.amazonaws.com" }, Action: "sts:AssumeRole" }],
    }),
    tags: t(),
});

const logGroup = new aws.cloudwatch.LogGroup("app-logs", {
    retentionInDays: env === "prod" ? 90 : 14,
    tags: t(),
});

const taskDef = new aws.ecs.TaskDefinition("task", {
    family: `${appName}-${env}`,
    cpu: "256",
    memory: "512",
    networkMode: "awsvpc",
    requiresCompatibilities: ["FARGATE"],
    executionRoleArn: execRole.arn,
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
                "awslogs-region": aws.getRegionOutput().name,
                "awslogs-stream-prefix": "ecs",
            },
        },
    }]),
    tags: t(),
});

const alb = new aws.lb.LoadBalancer("alb", {
    internal: false,
    loadBalancerType: "application",
    securityGroups: [albSg.id],
    subnets: publicSubnets.map(s => s.id),
    tags: t({ Name: `${appName}-alb` }),
});

const tg = new aws.lb.TargetGroup("tg", {
    port: 80,
    protocol: "HTTP",
    targetType: "ip",
    vpcId: vpc.id,
    healthCheck: { path: "/", healthyThreshold: 2, unhealthyThreshold: 3, interval: 30 },
    tags: t(),
});

const listener = new aws.lb.Listener("listener", {
    loadBalancerArn: alb.arn,
    port: 80,
    defaultActions: [{ type: "forward", targetGroupArn: tg.arn }],
});

const service = new aws.ecs.Service("service", {
    cluster: cluster.arn,
    taskDefinition: taskDef.arn,
    desiredCount: env === "prod" ? 2 : 1,
    launchType: "FARGATE",
    networkConfiguration: {
        subnets: privateSubnets.map(s => s.id),
        securityGroups: [appSg.id],
        assignPublicIp: false,
    },
    loadBalancers: [{ targetGroupArn: tg.arn, containerName: "app", containerPort: 80 }],
    tags: t(),
}, { dependsOn: [listener] });

// ─── RDS ─────────────────────────────────────────────────────────────
const dbSubnetGroup = new aws.rds.SubnetGroup("db-subnets", {
    subnetIds: privateSubnets.map(s => s.id),
    tags: t(),
});

const dbPassword = config.requireSecret("dbPassword");

const db = new aws.rds.Instance("db", {
    engine: "postgres",
    engineVersion: "16.4",
    instanceClass: env === "prod" ? "db.t4g.medium" : "db.t4g.micro",
    allocatedStorage: 20,
    maxAllocatedStorage: env === "prod" ? 200 : 50,
    dbName: `${appName.replace(/-/g, "_")}_db`,
    username: "app_admin",
    password: dbPassword,
    dbSubnetGroupName: dbSubnetGroup.name,
    vpcSecurityGroupIds: [dbSg.id],
    multiAz: env === "prod",
    storageEncrypted: true,
    backupRetentionPeriod: env === "prod" ? 14 : 1,
    skipFinalSnapshot: env !== "prod",
    finalSnapshotIdentifier: env === "prod" ? `${appName}-final-snapshot` : undefined,
    deletionProtection: env === "prod",
    tags: t({ Name: `${appName}-db` }),
}, { protect: env === "prod" });

// ─── Exports ─────────────────────────────────────────────────────────
export const vpcId = vpc.id;
export const publicSubnetIds = publicSubnets.map(s => s.id);
export const privateSubnetIds = privateSubnets.map(s => s.id);
export const albDnsName = alb.dnsName;
export const albUrl = pulumi.interpolate`http://${alb.dnsName}`;
export const dbEndpoint = db.endpoint;
export const ecsClusterName = cluster.name;
