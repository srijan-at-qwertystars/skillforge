/**
 * Production-ready CDK stack template.
 *
 * Features:
 *   - Proper tagging strategy
 *   - Configurable removal policies per environment
 *   - CfnOutputs for key resources
 *   - Stack termination protection for prod
 *   - Structured props with defaults
 *
 * Usage:
 *   Copy this file and adapt to your needs.
 */

import {
  Stack,
  StackProps,
  CfnOutput,
  Tags,
  RemovalPolicy,
  Duration,
  Aspects,
} from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as logs from 'aws-cdk-lib/aws-logs';
import { AwsSolutionsChecks, NagSuppressions } from 'cdk-nag';

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

export interface AppStackProps extends StackProps {
  /** Deployment stage: dev, staging, or prod */
  readonly stage: string;
  /** Project name used for tagging and naming */
  readonly projectName: string;
  /** Team that owns this stack */
  readonly teamName?: string;
  /** Cost center for billing attribution */
  readonly costCenter?: string;
  /** Enable cdk-nag compliance checks */
  readonly enableNagChecks?: boolean;
}

// ---------------------------------------------------------------------------
// Stack
// ---------------------------------------------------------------------------

export class AppStack extends Stack {
  public readonly vpc: ec2.IVpc;
  public readonly logBucket: s3.IBucket;

  constructor(scope: Construct, id: string, props: AppStackProps) {
    super(scope, id, props);

    const {
      stage,
      projectName,
      teamName = 'platform',
      costCenter = 'engineering',
      enableNagChecks = true,
    } = props;

    const isProd = stage === 'prod';

    // -----------------------------------------------------------------------
    // Stack-level settings
    // -----------------------------------------------------------------------
    if (isProd) {
      this.terminationProtection = true;
    }

    // -----------------------------------------------------------------------
    // Tags — applied to all resources in this stack
    // -----------------------------------------------------------------------
    Tags.of(this).add('Project', projectName);
    Tags.of(this).add('Stage', stage);
    Tags.of(this).add('Team', teamName);
    Tags.of(this).add('CostCenter', costCenter);
    Tags.of(this).add('ManagedBy', 'cdk');

    // -----------------------------------------------------------------------
    // Removal policy helper
    // -----------------------------------------------------------------------
    const removalPolicy = isProd ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY;

    // -----------------------------------------------------------------------
    // Logging bucket
    // -----------------------------------------------------------------------
    this.logBucket = new s3.Bucket(this, 'LogBucket', {
      removalPolicy,
      autoDeleteObjects: !isProd,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: isProd,
      lifecycleRules: [
        {
          expiration: Duration.days(isProd ? 365 : 30),
          transitions: isProd
            ? [{ storageClass: s3.StorageClass.INFREQUENT_ACCESS, transitionAfter: Duration.days(90) }]
            : [],
        },
      ],
    });

    // -----------------------------------------------------------------------
    // VPC
    // -----------------------------------------------------------------------
    this.vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: isProd ? 3 : 2,
      natGateways: isProd ? 2 : 1,
      subnetConfiguration: [
        { name: 'Public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        { name: 'Private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 24 },
        { name: 'Isolated', subnetType: ec2.SubnetType.PRIVATE_ISOLATED, cidrMask: 24 },
      ],
    });

    this.vpc.addFlowLog('FlowLog', {
      destination: ec2.FlowLogDestination.toS3(this.logBucket, 'vpc-flow-logs'),
    });

    // -----------------------------------------------------------------------
    // Add your resources below
    // -----------------------------------------------------------------------

    // Example: Application log group
    new logs.LogGroup(this, 'AppLogs', {
      logGroupName: `/${projectName}/${stage}/app`,
      retention: isProd ? logs.RetentionDays.ONE_YEAR : logs.RetentionDays.ONE_WEEK,
      removalPolicy,
    });

    // -----------------------------------------------------------------------
    // cdk-nag compliance
    // -----------------------------------------------------------------------
    if (enableNagChecks) {
      Aspects.of(this).add(new AwsSolutionsChecks({ verbose: true }));

      // Suppress rules with documented justification
      NagSuppressions.addStackSuppressions(this, [
        {
          id: 'AwsSolutions-VPC7',
          reason: 'VPC flow logs are sent to S3 instead of CloudWatch',
        },
      ]);
    }

    // -----------------------------------------------------------------------
    // Outputs
    // -----------------------------------------------------------------------
    new CfnOutput(this, 'VpcId', {
      value: this.vpc.vpcId,
      description: `VPC ID for ${projectName} (${stage})`,
      exportName: `${projectName}-${stage}-vpc-id`,
    });

    new CfnOutput(this, 'LogBucketName', {
      value: this.logBucket.bucketName,
      description: 'Centralized logging bucket',
    });
  }
}
