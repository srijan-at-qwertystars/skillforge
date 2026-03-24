// ─────────────────────────────────────────────────────────────────────────────
// index.ts — VPC + ECS Fargate with ALB (Pulumi starter template)
//
// This stack provisions:
//   1. VPC with public & private subnets (via @pulumi/awsx)
//   2. ECS Cluster
//   3. Fargate Service behind an Application Load Balancer
//   4. CloudWatch Log Group for container logs
//   5. Security groups for ALB ↔ Fargate traffic
//
// All resource parameters are config-driven so the same code works across
// dev / staging / prod stacks with different Pulumi.<stack>.yaml files.
// ─────────────────────────────────────────────────────────────────────────────

import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as awsx from "@pulumi/awsx";

// ─── Configuration ──────────────────────────────────────────────────────────

const config = new pulumi.Config();
const env = config.require("environment");           // e.g. "dev"
const containerImage = config.get("containerImage") || "nginx:latest";
const containerPort = config.getNumber("containerPort") || 80;
const cpu = config.getNumber("cpu") || 256;           // 0.25 vCPU
const memory = config.getNumber("memory") || 512;     // 512 MB
const desiredCount = config.getNumber("desiredCount") || 2;
const enableMonitoring = config.getBoolean("enableMonitoring") ?? true;

const defaultTags = { Environment: env, ManagedBy: "pulumi" };

// ─── VPC ────────────────────────────────────────────────────────────────────

// awsx.ec2.Vpc creates public + private subnets, NAT gateways, and route
// tables automatically. One NAT gateway is cheaper for dev; use "OnePerAz"
// in production for high availability.
const vpc = new awsx.ec2.Vpc(`${env}-vpc`, {
  cidrBlock: "10.0.0.0/16",
  numberOfAvailabilityZones: 2,
  natGateways: {
    strategy: awsx.ec2.NatGatewayStrategy.Single,
  },
  tags: defaultTags,
});

// ─── Security Groups ────────────────────────────────────────────────────────

// ALB security group — allows inbound HTTP from the internet
const albSg = new aws.ec2.SecurityGroup(`${env}-alb-sg`, {
  vpcId: vpc.vpcId,
  description: "Allow HTTP inbound to ALB",
  ingress: [
    { protocol: "tcp", fromPort: 80, toPort: 80, cidrBlocks: ["0.0.0.0/0"], description: "HTTP" },
    { protocol: "tcp", fromPort: 443, toPort: 443, cidrBlocks: ["0.0.0.0/0"], description: "HTTPS" },
  ],
  egress: [
    { protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"], description: "Allow all outbound" },
  ],
  tags: { ...defaultTags, Name: `${env}-alb-sg` },
});

// Fargate task security group — allows traffic only from the ALB
const taskSg = new aws.ec2.SecurityGroup(`${env}-task-sg`, {
  vpcId: vpc.vpcId,
  description: "Allow traffic from ALB to Fargate tasks",
  ingress: [
    {
      protocol: "tcp",
      fromPort: containerPort,
      toPort: containerPort,
      securityGroups: [albSg.id],
      description: "Traffic from ALB",
    },
  ],
  egress: [
    { protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"], description: "Allow all outbound" },
  ],
  tags: { ...defaultTags, Name: `${env}-task-sg` },
});

// ─── CloudWatch Logs ────────────────────────────────────────────────────────

const logGroup = new aws.cloudwatch.LogGroup(`${env}-log-group`, {
  name: `/ecs/${env}/app`,
  retentionInDays: enableMonitoring ? 30 : 7,
  tags: defaultTags,
});

// ─── ECS Cluster ────────────────────────────────────────────────────────────

const cluster = new aws.ecs.Cluster(`${env}-cluster`, {
  settings: [{ name: "containerInsights", value: enableMonitoring ? "enabled" : "disabled" }],
  tags: defaultTags,
});

// ─── Application Load Balancer ──────────────────────────────────────────────

const alb = new awsx.lb.ApplicationLoadBalancer(`${env}-alb`, {
  subnetIds: vpc.publicSubnetIds,
  securityGroups: [albSg.id],
  tags: defaultTags,
});

// ─── Fargate Service ────────────────────────────────────────────────────────

// IAM role for the ECS task execution (pulling images, writing logs)
const executionRole = new aws.iam.Role(`${env}-exec-role`, {
  assumeRolePolicy: aws.iam.assumeRolePolicyForPrincipal({
    Service: "ecs-tasks.amazonaws.com",
  }),
  tags: defaultTags,
});

new aws.iam.RolePolicyAttachment(`${env}-exec-policy`, {
  role: executionRole,
  policyArn: "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
});

// IAM role for the running task itself (app-level AWS SDK calls)
const taskRole = new aws.iam.Role(`${env}-task-role`, {
  assumeRolePolicy: aws.iam.assumeRolePolicyForPrincipal({
    Service: "ecs-tasks.amazonaws.com",
  }),
  tags: defaultTags,
});

// Task definition
const taskDefinition = new awsx.ecs.FargateTaskDefinition(`${env}-task-def`, {
  executionRole: { roleArn: executionRole.arn },
  taskRole: { roleArn: taskRole.arn },
  container: {
    name: "app",
    image: containerImage,
    cpu,
    memory,
    essential: true,
    portMappings: [
      {
        containerPort,
        targetGroup: alb.defaultTargetGroup,
      },
    ],
    logConfiguration: {
      logDriver: "awslogs",
      options: {
        "awslogs-group": logGroup.name,
        "awslogs-region": aws.config.region || "us-west-2",
        "awslogs-stream-prefix": "ecs",
      },
    },
  },
});

// Fargate service
const service = new aws.ecs.Service(`${env}-service`, {
  cluster: cluster.arn,
  taskDefinition: taskDefinition.taskDefinition.arn,
  desiredCount,
  launchType: "FARGATE",
  networkConfiguration: {
    subnets: vpc.privateSubnetIds,
    securityGroups: [taskSg.id],
    assignPublicIp: false,
  },
  loadBalancers: [
    {
      targetGroupArn: alb.defaultTargetGroup.arn,
      containerName: "app",
      containerPort,
    },
  ],
  tags: defaultTags,
});

// ─── Exports ────────────────────────────────────────────────────────────────

export const vpcId = vpc.vpcId;
export const clusterName = cluster.name;
export const serviceName = service.name;
export const albEndpoint = pulumi.interpolate`http://${alb.loadBalancer.dnsName}`;
export const logGroupName = logGroup.name;
