#!/usr/bin/env bash
#
# deploy-pipeline.sh — Set up and deploy a CDK Pipeline with dev/staging/prod stages
#
# Usage:
#   ./deploy-pipeline.sh --repo OWNER/REPO --pipeline-account ACCOUNT_ID --region REGION \
#     [--dev-account ACCOUNT_ID] [--staging-account ACCOUNT_ID] [--prod-account ACCOUNT_ID]
#
# Examples:
#   # All stages in same account
#   ./deploy-pipeline.sh --repo myorg/myapp --pipeline-account 111111111111 --region us-east-1
#
#   # Cross-account pipeline
#   ./deploy-pipeline.sh --repo myorg/myapp \
#     --pipeline-account 111111111111 \
#     --dev-account 222222222222 \
#     --staging-account 333333333333 \
#     --prod-account 444444444444 \
#     --region us-east-1
#
# Prerequisites:
#   - AWS CLI configured with credentials
#   - GitHub connection set up in AWS CodePipeline (or provide --connection-arn)
#   - Node.js 18+

set -euo pipefail

# --- Default values ---
REPO=""
PIPELINE_ACCOUNT=""
DEV_ACCOUNT=""
STAGING_ACCOUNT=""
PROD_ACCOUNT=""
REGION="us-east-1"
CONNECTION_ARN=""
BRANCH="main"
SKIP_BOOTSTRAP=false

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pipeline-account) PIPELINE_ACCOUNT="$2"; shift 2 ;;
    --dev-account) DEV_ACCOUNT="$2"; shift 2 ;;
    --staging-account) STAGING_ACCOUNT="$2"; shift 2 ;;
    --prod-account) PROD_ACCOUNT="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --connection-arn) CONNECTION_ARN="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=true; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^#//' | sed 's/^ //'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Validate required args ---
if [[ -z "$REPO" || -z "$PIPELINE_ACCOUNT" ]]; then
  echo "❌ --repo and --pipeline-account are required."
  echo "Run with --help for usage."
  exit 1
fi

# Default: all stages in pipeline account
DEV_ACCOUNT="${DEV_ACCOUNT:-$PIPELINE_ACCOUNT}"
STAGING_ACCOUNT="${STAGING_ACCOUNT:-$PIPELINE_ACCOUNT}"
PROD_ACCOUNT="${PROD_ACCOUNT:-$PIPELINE_ACCOUNT}"

echo "📋 Pipeline Configuration:"
echo "   Repo:             $REPO"
echo "   Branch:           $BRANCH"
echo "   Pipeline Account: $PIPELINE_ACCOUNT"
echo "   Dev Account:      $DEV_ACCOUNT"
echo "   Staging Account:  $STAGING_ACCOUNT"
echo "   Prod Account:     $PROD_ACCOUNT"
echo "   Region:           $REGION"
echo ""

# --- Prerequisites check ---
echo "🔍 Checking prerequisites..."
for cmd in node npm npx aws; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ $cmd is required but not installed."
    exit 1
  fi
done

# --- Bootstrap accounts ---
if [[ "$SKIP_BOOTSTRAP" == "false" ]]; then
  echo "🥾 Bootstrapping accounts..."

  # Bootstrap pipeline account
  echo "   → Pipeline account ($PIPELINE_ACCOUNT)..."
  npx cdk bootstrap "aws://${PIPELINE_ACCOUNT}/${REGION}" \
    --qualifier pipeline 2>&1 | tail -1

  # Bootstrap target accounts with trust
  for TARGET_ACCOUNT in "$DEV_ACCOUNT" "$STAGING_ACCOUNT" "$PROD_ACCOUNT"; do
    if [[ "$TARGET_ACCOUNT" != "$PIPELINE_ACCOUNT" ]]; then
      echo "   → Target account ($TARGET_ACCOUNT) with trust..."
      npx cdk bootstrap "aws://${TARGET_ACCOUNT}/${REGION}" \
        --trust "$PIPELINE_ACCOUNT" \
        --cloudformation-execution-policies arn:aws:iam::aws:policy/AdministratorAccess \
        --qualifier pipeline 2>&1 | tail -1
    fi
  done
  echo "✅ Bootstrap complete."
else
  echo "⏭️  Skipping bootstrap (--skip-bootstrap)"
fi

# --- Generate pipeline stack ---
echo "🏗️  Generating pipeline stack..."

mkdir -p lib/pipeline

cat > lib/pipeline/pipeline-stack.ts << PIPELINE
import { Stack, StackProps, Stage, StageProps } from 'aws-cdk-lib';
import { Construct } from 'constructs';
import {
  CodePipeline,
  CodePipelineSource,
  ShellStep,
  ManualApprovalStep,
} from 'aws-cdk-lib/pipelines';

// Import your application stacks here
// import { AppStack } from '../app-stack';

/** Application stage — all stacks for one environment */
export class AppStage extends Stage {
  constructor(scope: Construct, id: string, props?: StageProps) {
    super(scope, id, props);

    // Add your stacks here:
    // new AppStack(this, 'App');
    // new DataStack(this, 'Data');
  }
}

export interface PipelineStackProps extends StackProps {
  readonly repo: string;
  readonly branch: string;
  readonly connectionArn?: string;
  readonly devAccount: string;
  readonly stagingAccount: string;
  readonly prodAccount: string;
  readonly region: string;
}

export class PipelineStack extends Stack {
  constructor(scope: Construct, id: string, props: PipelineStackProps) {
    super(scope, id, props);

    const source = props.connectionArn
      ? CodePipelineSource.connection(props.repo, props.branch, {
          connectionArn: props.connectionArn,
        })
      : CodePipelineSource.gitHub(props.repo, props.branch);

    const pipeline = new CodePipeline(this, 'Pipeline', {
      pipelineName: 'AppPipeline',
      crossAccountKeys: true,
      synth: new ShellStep('Synth', {
        input: source,
        commands: [
          'npm ci',
          'npm run build',
          'npx cdk synth',
        ],
        primaryOutputDirectory: 'cdk.out',
      }),
    });

    // Dev stage — auto-deploy
    pipeline.addStage(new AppStage(this, 'Dev', {
      env: { account: props.devAccount, region: props.region },
    }));

    // Staging stage — auto-deploy with post-deployment tests
    pipeline.addStage(new AppStage(this, 'Staging', {
      env: { account: props.stagingAccount, region: props.region },
    }), {
      post: [
        new ShellStep('IntegrationTests', {
          commands: ['echo "Run integration tests here"'],
        }),
      ],
    });

    // Prod stage — manual approval required
    pipeline.addStage(new AppStage(this, 'Prod', {
      env: { account: props.prodAccount, region: props.region },
    }), {
      pre: [
        new ManualApprovalStep('PromoteToProd', {
          comment: 'Review staging deployment before promoting to production.',
        }),
      ],
    });
  }
}
PIPELINE

# --- Generate pipeline entry point ---
cat > bin/pipeline.ts << ENTRY
#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { PipelineStack } from '../lib/pipeline/pipeline-stack';

const app = new cdk.App();

new PipelineStack(app, 'PipelineStack', {
  env: {
    account: '${PIPELINE_ACCOUNT}',
    region: '${REGION}',
  },
  repo: '${REPO}',
  branch: '${BRANCH}',
  ${CONNECTION_ARN:+connectionArn: '${CONNECTION_ARN}',}
  devAccount: '${DEV_ACCOUNT}',
  stagingAccount: '${STAGING_ACCOUNT}',
  prodAccount: '${PROD_ACCOUNT}',
  region: '${REGION}',
});
ENTRY

echo "✅ Pipeline stack generated at lib/pipeline/pipeline-stack.ts"

# --- Build and synth ---
echo "🔨 Building..."
npm run build 2>&1 | tail -3

echo "☁️  Synthesizing..."
npx cdk synth PipelineStack 2>&1 | tail -5

# --- Deploy ---
echo ""
echo "🚀 Deploying pipeline stack..."
npx cdk deploy PipelineStack \
  --require-approval never \
  --qualifier pipeline \
  2>&1 | tail -10

echo ""
echo "✅ Pipeline deployed successfully!"
echo ""
echo "The pipeline is self-mutating: push changes to $BRANCH to trigger updates."
echo ""
echo "Next steps:"
echo "  1. Add your application stacks to lib/pipeline/pipeline-stack.ts (AppStage)"
echo "  2. Commit and push — the pipeline will self-update"
echo "  3. Monitor at: https://${REGION}.console.aws.amazon.com/codesuite/codepipeline/pipelines/AppPipeline/view"
