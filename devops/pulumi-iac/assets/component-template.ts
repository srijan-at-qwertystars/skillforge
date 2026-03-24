import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

// ──────────────────────────────────────────────────────────────────────
// ComponentResource Template
// ──────────────────────────────────────────────────────────────────────
// Copy this file and adapt it for your own reusable infrastructure
// components. A ComponentResource groups related resources under a
// single logical unit with typed inputs and outputs.
// ──────────────────────────────────────────────────────────────────────

// ─── Input Args ──────────────────────────────────────────────────────
// Define all configurable properties. Use pulumi.Input<T> for values
// that may come from other resources' outputs.

export interface WebServiceArgs {
    /** VPC ID to deploy into */
    vpcId: pulumi.Input<string>;
    /** Subnet IDs for the load balancer (public subnets) */
    publicSubnetIds: pulumi.Input<string>[];
    /** Subnet IDs for the service (private subnets) */
    privateSubnetIds: pulumi.Input<string>[];
    /** Container image to deploy (e.g., "nginx:1.25") */
    image: pulumi.Input<string>;
    /** Container port to expose */
    containerPort?: pulumi.Input<number>;
    /** Number of desired tasks */
    desiredCount?: pulumi.Input<number>;
    /** CPU units (256 = 0.25 vCPU) */
    cpu?: pulumi.Input<string>;
    /** Memory in MiB */
    memory?: pulumi.Input<string>;
    /** Additional tags to apply to all resources */
    tags?: pulumi.Input<Record<string, string>>;
}

// ─── Component Resource ──────────────────────────────────────────────
// The type token ("company:module:Name") uniquely identifies this
// component type. Never change it after initial deployment.

export class WebService extends pulumi.ComponentResource {
    /** The ALB DNS name */
    public readonly url: pulumi.Output<string>;
    /** The ECS service ARN */
    public readonly serviceArn: pulumi.Output<string>;
    /** The security group ID for the service */
    public readonly securityGroupId: pulumi.Output<string>;

    constructor(
        name: string,
        args: WebServiceArgs,
        opts?: pulumi.ComponentResourceOptions,
    ) {
        // Register this component. Pass args for display in Pulumi Cloud.
        super("company:containers:WebService", name, args, opts);

        // All child resources must use { parent: this }
        const defaultResourceOpts: pulumi.ResourceOptions = { parent: this };

        const containerPort = args.containerPort ?? 80;
        const desiredCount = args.desiredCount ?? 2;
        const cpu = args.cpu ?? "256";
        const memory = args.memory ?? "512";

        // ── Security Groups ──────────────────────────────────────────
        const albSg = new aws.ec2.SecurityGroup(`${name}-alb-sg`, {
            vpcId: args.vpcId,
            description: `ALB security group for ${name}`,
            ingress: [
                { fromPort: 80, toPort: 80, protocol: "tcp", cidrBlocks: ["0.0.0.0/0"] },
                { fromPort: 443, toPort: 443, protocol: "tcp", cidrBlocks: ["0.0.0.0/0"] },
            ],
            egress: [{ fromPort: 0, toPort: 0, protocol: "-1", cidrBlocks: ["0.0.0.0/0"] }],
        }, defaultResourceOpts);

        const svcSg = new aws.ec2.SecurityGroup(`${name}-svc-sg`, {
            vpcId: args.vpcId,
            description: `Service security group for ${name}`,
            ingress: [{
                fromPort: containerPort,
                toPort: containerPort,
                protocol: "tcp",
                securityGroups: [albSg.id],
            }],
            egress: [{ fromPort: 0, toPort: 0, protocol: "-1", cidrBlocks: ["0.0.0.0/0"] }],
        }, defaultResourceOpts);

        // ── IAM Roles ────────────────────────────────────────────────
        const execRole = new aws.iam.Role(`${name}-exec`, {
            assumeRolePolicy: JSON.stringify({
                Version: "2012-10-17",
                Statement: [{
                    Effect: "Allow",
                    Principal: { Service: "ecs-tasks.amazonaws.com" },
                    Action: "sts:AssumeRole",
                }],
            }),
        }, defaultResourceOpts);

        new aws.iam.RolePolicyAttachment(`${name}-exec-policy`, {
            role: execRole.name,
            policyArn: "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
        }, defaultResourceOpts);

        const taskRole = new aws.iam.Role(`${name}-task`, {
            assumeRolePolicy: JSON.stringify({
                Version: "2012-10-17",
                Statement: [{
                    Effect: "Allow",
                    Principal: { Service: "ecs-tasks.amazonaws.com" },
                    Action: "sts:AssumeRole",
                }],
            }),
        }, defaultResourceOpts);

        // ── Log Group ────────────────────────────────────────────────
        const logGroup = new aws.cloudwatch.LogGroup(`${name}-logs`, {
            retentionInDays: 14,
        }, defaultResourceOpts);

        // ── ECS Task Definition ──────────────────────────────────────
        const taskDef = new aws.ecs.TaskDefinition(`${name}-task`, {
            family: name,
            cpu,
            memory,
            networkMode: "awsvpc",
            requiresCompatibilities: ["FARGATE"],
            executionRoleArn: execRole.arn,
            taskRoleArn: taskRole.arn,
            containerDefinitions: pulumi.jsonStringify([{
                name: "app",
                image: args.image,
                essential: true,
                portMappings: [{ containerPort, protocol: "tcp" }],
                logConfiguration: {
                    logDriver: "awslogs",
                    options: {
                        "awslogs-group": logGroup.name,
                        "awslogs-region": aws.getRegionOutput().name,
                        "awslogs-stream-prefix": name,
                    },
                },
            }]),
        }, defaultResourceOpts);

        // ── ALB ──────────────────────────────────────────────────────
        const alb = new aws.lb.LoadBalancer(`${name}-alb`, {
            internal: false,
            loadBalancerType: "application",
            securityGroups: [albSg.id],
            subnets: args.publicSubnetIds,
        }, defaultResourceOpts);

        const tg = new aws.lb.TargetGroup(`${name}-tg`, {
            port: containerPort,
            protocol: "HTTP",
            targetType: "ip",
            vpcId: args.vpcId,
            healthCheck: {
                path: "/",
                healthyThreshold: 2,
                unhealthyThreshold: 3,
                interval: 30,
            },
        }, defaultResourceOpts);

        const listener = new aws.lb.Listener(`${name}-listener`, {
            loadBalancerArn: alb.arn,
            port: 80,
            defaultActions: [{ type: "forward", targetGroupArn: tg.arn }],
        }, defaultResourceOpts);

        // ── ECS Service ──────────────────────────────────────────────
        const svc = new aws.ecs.Service(`${name}-svc`, {
            cluster: clusterArn(name, defaultResourceOpts),
            taskDefinition: taskDef.arn,
            desiredCount,
            launchType: "FARGATE",
            networkConfiguration: {
                subnets: args.privateSubnetIds,
                securityGroups: [svcSg.id],
                assignPublicIp: false,
            },
            loadBalancers: [{
                targetGroupArn: tg.arn,
                containerName: "app",
                containerPort,
            }],
        }, { ...defaultResourceOpts, dependsOn: [listener] });

        // ── Set Outputs ──────────────────────────────────────────────
        this.url = pulumi.interpolate`http://${alb.dnsName}`;
        this.serviceArn = svc.id;
        this.securityGroupId = svcSg.id;

        // REQUIRED: Always call registerOutputs at the end.
        this.registerOutputs({
            url: this.url,
            serviceArn: this.serviceArn,
            securityGroupId: this.securityGroupId,
        });
    }
}

// Helper to create or reuse a shared ECS cluster
function clusterArn(
    name: string,
    opts: pulumi.ResourceOptions,
): pulumi.Output<string> {
    const cluster = new aws.ecs.Cluster(`${name}-cluster`, {
        settings: [{ name: "containerInsights", value: "enabled" }],
    }, opts);
    return cluster.arn;
}

// ──────────────────────────────────────────────────────────────────────
// Usage Example
// ──────────────────────────────────────────────────────────────────────
//
// import { WebService } from "./component-template";
//
// const api = new WebService("api", {
//     vpcId: network.vpcId,
//     publicSubnetIds: network.publicSubnetIds,
//     privateSubnetIds: network.privateSubnetIds,
//     image: "my-app:latest",
//     containerPort: 8080,
//     desiredCount: 3,
//     cpu: "512",
//     memory: "1024",
// });
//
// export const apiUrl = api.url;
