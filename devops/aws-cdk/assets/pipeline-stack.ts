/**
 * CDK Pipeline stack template with dev/staging/prod stages.
 *
 * Features:
 *   - Self-mutating pipeline from GitHub or CodeCommit
 *   - Dev → Staging (with integration tests) → Prod (with manual approval)
 *   - SNS notifications for pipeline events
 *   - Configurable source and build commands
 *
 * Usage:
 *   1. Copy this file into your project
 *   2. Update AppStage to include your stacks
 *   3. Configure accounts/regions in the entry point
 *   4. Deploy: npx cdk deploy PipelineStack
 */

import {
  Stack,
  StackProps,
  Stage,
  StageProps,
  CfnOutput,
  Tags,
} from 'aws-cdk-lib';
import { Construct } from 'constructs';
import {
  CodePipeline,
  CodePipelineSource,
  ShellStep,
  ManualApprovalStep,
} from 'aws-cdk-lib/pipelines';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as subscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';

// ---------------------------------------------------------------------------
// Application Stage — contains all stacks for one environment
// ---------------------------------------------------------------------------

export interface AppStageProps extends StageProps {
  readonly stage: string;
}

export class AppStage extends Stage {
  constructor(scope: Construct, id: string, props: AppStageProps) {
    super(scope, id, props);

    // Add your application stacks here:
    //
    // const network = new NetworkStack(this, 'Network', { stage: props.stage });
    // const data = new DataStack(this, 'Data', {
    //   stage: props.stage,
    //   vpc: network.vpc,
    // });
    // const api = new ApiStack(this, 'Api', {
    //   stage: props.stage,
    //   vpc: network.vpc,
    //   table: data.table,
    // });

    Tags.of(this).add('Stage', props.stage);
  }
}

// ---------------------------------------------------------------------------
// Pipeline Stack Props
// ---------------------------------------------------------------------------

export interface PipelineStackProps extends StackProps {
  /** GitHub repository in OWNER/REPO format */
  readonly repo: string;
  /** Branch to track. @default 'main' */
  readonly branch?: string;
  /** AWS CodeStar connection ARN for GitHub */
  readonly connectionArn?: string;

  /** Dev account ID */
  readonly devAccount: string;
  /** Staging account ID */
  readonly stagingAccount: string;
  /** Prod account ID */
  readonly prodAccount: string;
  /** Target region for all stages */
  readonly targetRegion: string;

  /** Email for pipeline failure notifications */
  readonly notificationEmail?: string;

  /** Additional build commands before synth */
  readonly preBuildCommands?: string[];
}

// ---------------------------------------------------------------------------
// Pipeline Stack
// ---------------------------------------------------------------------------

export class PipelineStack extends Stack {
  public readonly pipeline: CodePipeline;
  public readonly notificationTopic?: sns.Topic;

  constructor(scope: Construct, id: string, props: PipelineStackProps) {
    super(scope, id, props);

    const branch = props.branch ?? 'main';

    // --- Source ---
    const source = props.connectionArn
      ? CodePipelineSource.connection(props.repo, branch, {
          connectionArn: props.connectionArn,
        })
      : CodePipelineSource.gitHub(props.repo, branch);

    // --- Build commands ---
    const buildCommands = [
      ...(props.preBuildCommands ?? []),
      'npm ci',
      'npm run build',
      'npm test',
      'npx cdk synth',
    ];

    // --- Pipeline ---
    this.pipeline = new CodePipeline(this, 'Pipeline', {
      pipelineName: `${id}-pipeline`,
      crossAccountKeys: true,
      selfMutation: true,
      synth: new ShellStep('Synth', {
        input: source,
        commands: buildCommands,
        primaryOutputDirectory: 'cdk.out',
      }),
      dockerEnabledForSynth: true,
    });

    // --- Dev Stage ---
    this.pipeline.addStage(
      new AppStage(this, 'Dev', {
        stage: 'dev',
        env: { account: props.devAccount, region: props.targetRegion },
      }),
      {
        post: [
          new ShellStep('DevSmokeTest', {
            commands: [
              'echo "Running dev smoke tests..."',
              '# Add your smoke test commands here',
              '# curl -f https://dev-api.example.com/health || exit 1',
            ],
          }),
        ],
      }
    );

    // --- Staging Stage ---
    this.pipeline.addStage(
      new AppStage(this, 'Staging', {
        stage: 'staging',
        env: { account: props.stagingAccount, region: props.targetRegion },
      }),
      {
        post: [
          new ShellStep('IntegrationTests', {
            commands: [
              'echo "Running integration tests..."',
              '# npm run test:integration',
              '# npx playwright test',
            ],
          }),
          new ShellStep('LoadTest', {
            commands: [
              'echo "Running load tests..."',
              '# artillery run load-test.yml',
            ],
          }),
        ],
      }
    );

    // --- Prod Stage ---
    this.pipeline.addStage(
      new AppStage(this, 'Prod', {
        stage: 'prod',
        env: { account: props.prodAccount, region: props.targetRegion },
      }),
      {
        pre: [
          new ManualApprovalStep('PromoteToProd', {
            comment: [
              'Review the staging deployment before promoting to production.',
              'Check: integration tests passed, no error spikes in staging,',
              'deployment plan reviewed by team lead.',
            ].join('\n'),
          }),
        ],
      }
    );

    // --- Notifications ---
    if (props.notificationEmail) {
      this.notificationTopic = new sns.Topic(this, 'PipelineNotifications', {
        topicName: `${id}-pipeline-notifications`,
      });

      this.notificationTopic.addSubscription(
        new subscriptions.EmailSubscription(props.notificationEmail)
      );

      // Notify on pipeline failures
      const rule = new events.Rule(this, 'PipelineFailedRule', {
        eventPattern: {
          source: ['aws.codepipeline'],
          detailType: ['CodePipeline Pipeline Execution State Change'],
          detail: {
            state: ['FAILED'],
          },
        },
      });
      rule.addTarget(new targets.SnsTopic(this.notificationTopic, {
        message: events.RuleTargetInput.fromText(
          `Pipeline ${id} FAILED. Check: https://console.aws.amazon.com/codesuite/codepipeline/pipelines/${id}-pipeline/view`
        ),
      }));
    }

    // --- Outputs ---
    new CfnOutput(this, 'PipelineName', {
      value: `${id}-pipeline`,
      description: 'CodePipeline name',
    });
  }
}

// ---------------------------------------------------------------------------
// Entry point example (put in bin/pipeline.ts)
// ---------------------------------------------------------------------------
/*
const app = new cdk.App();

new PipelineStack(app, 'MyApp', {
  env: { account: '111111111111', region: 'us-east-1' },
  repo: 'myorg/myapp',
  branch: 'main',
  connectionArn: 'arn:aws:codestar-connections:us-east-1:111111111111:connection/xxx',
  devAccount: '111111111111',
  stagingAccount: '222222222222',
  prodAccount: '333333333333',
  targetRegion: 'us-east-1',
  notificationEmail: 'team@example.com',
});
*/
