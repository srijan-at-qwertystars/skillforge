#!/usr/bin/env bash
#
# init-cdk-project.sh — Initialize a new CDK project with TypeScript
#
# Usage:
#   ./init-cdk-project.sh <project-name> [--region REGION]
#
# Examples:
#   ./init-cdk-project.sh my-app
#   ./init-cdk-project.sh my-app --region us-west-2
#
# Creates a new CDK TypeScript project with:
#   - Common dependencies pre-installed
#   - Configured tsconfig.json
#   - Basic stack with VPC
#   - Recommended cdk.json feature flags
#   - .gitignore and README

set -euo pipefail

# --- Argument parsing ---
PROJECT_NAME="${1:-}"
REGION="us-east-1"

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Usage: $0 <project-name> [--region REGION]"
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Validate prerequisites ---
echo "🔍 Checking prerequisites..."

for cmd in node npm npx; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ $cmd is required but not installed."
    exit 1
  fi
done

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [[ "$NODE_VERSION" -lt 18 ]]; then
  echo "❌ Node.js 18+ required (found: $(node -v))"
  exit 1
fi

# --- Create project ---
echo "📁 Creating project: $PROJECT_NAME"

if [[ -d "$PROJECT_NAME" ]]; then
  echo "❌ Directory '$PROJECT_NAME' already exists."
  exit 1
fi

mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# --- Initialize CDK app ---
echo "⚡ Running cdk init..."
npx cdk init app --language typescript --generate-only

# --- Install common dependencies ---
echo "📦 Installing common dependencies..."
npm install aws-cdk-lib constructs

npm install --save-dev \
  @types/node \
  typescript \
  ts-jest \
  jest \
  @types/jest \
  esbuild \
  cdk-nag

# --- Configure tsconfig.json ---
echo "⚙️  Configuring TypeScript..."
cat > tsconfig.json << 'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "lib": ["ES2022"],
    "declaration": true,
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "resolveJsonModule": true,
    "esModuleInterop": true,
    "inlineSourceMap": true,
    "inlineSources": true,
    "experimentalDecorators": true,
    "outDir": "lib",
    "rootDir": ".",
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  },
  "include": ["bin/**/*.ts", "lib/**/*.ts", "test/**/*.ts"],
  "exclude": ["node_modules", "cdk.out"]
}
TSCONFIG

# --- Determine class name from project name ---
# Convert kebab-case to PascalCase
CLASS_NAME=$(echo "$PROJECT_NAME" | sed -r 's/(^|-)(\w)/\U\2/g')

# --- Create basic stack with VPC ---
echo "🏗️  Creating basic stack with VPC..."
mkdir -p lib bin test

cat > "lib/${PROJECT_NAME}-stack.ts" << STACK
import { Stack, StackProps, CfnOutput, Tags, RemovalPolicy } from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';

export interface ${CLASS_NAME}StackProps extends StackProps {
  readonly stage?: string;
}

export class ${CLASS_NAME}Stack extends Stack {
  public readonly vpc: ec2.IVpc;

  constructor(scope: Construct, id: string, props?: ${CLASS_NAME}StackProps) {
    super(scope, id, props);

    const stage = props?.stage ?? 'dev';

    // VPC with public and private subnets
    this.vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: stage === 'prod' ? 2 : 1,
      subnetConfiguration: [
        {
          name: 'Public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
        },
        {
          name: 'Private',
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
          cidrMask: 24,
        },
        {
          name: 'Isolated',
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
          cidrMask: 24,
        },
      ],
    });

    // Flow logs for network monitoring
    this.vpc.addFlowLog('FlowLog', {
      destination: ec2.FlowLogDestination.toCloudWatchLogs(),
    });

    // Tags
    Tags.of(this).add('Project', '${PROJECT_NAME}');
    Tags.of(this).add('Stage', stage);

    // Outputs
    new CfnOutput(this, 'VpcId', {
      value: this.vpc.vpcId,
      description: 'VPC ID',
    });
  }
}
STACK

cat > "bin/${PROJECT_NAME}.ts" << APP
#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { ${CLASS_NAME}Stack } from '../lib/${PROJECT_NAME}-stack';

const app = new cdk.App();
const stage = app.node.tryGetContext('stage') || 'dev';

new ${CLASS_NAME}Stack(app, '${CLASS_NAME}Stack', {
  stage,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || '${REGION}',
  },
  description: '${PROJECT_NAME} infrastructure (' + stage + ')',
});
APP

# --- Create test ---
cat > "test/${PROJECT_NAME}.test.ts" << TEST
import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { ${CLASS_NAME}Stack } from '../lib/${PROJECT_NAME}-stack';

describe('${CLASS_NAME}Stack', () => {
  const app = new App();
  const stack = new ${CLASS_NAME}Stack(app, 'TestStack', { stage: 'dev' });
  const template = Template.fromStack(stack);

  test('creates a VPC', () => {
    template.resourceCountIs('AWS::EC2::VPC', 1);
  });

  test('VPC has correct subnet configuration', () => {
    template.hasResourceProperties('AWS::EC2::Subnet', {
      MapPublicIpOnLaunch: true,
    });
  });

  test('has flow logs enabled', () => {
    template.resourceCountIs('AWS::EC2::FlowLog', 1);
  });

  test('uses 1 NAT gateway in dev', () => {
    template.resourceCountIs('AWS::EC2::NatGateway', 1);
  });
});
TEST

# --- Update cdk.json with recommended flags ---
echo "📝 Updating cdk.json..."
cat > cdk.json << CDKJSON
{
  "app": "npx ts-node --prefer-ts-exts bin/${PROJECT_NAME}.ts",
  "watch": {
    "include": ["**"],
    "exclude": [
      "README.md",
      "cdk*.json",
      "**/*.d.ts",
      "**/*.js",
      "tsconfig.json",
      "package*.json",
      "yarn.lock",
      "node_modules",
      "test"
    ]
  },
  "context": {
    "@aws-cdk/aws-lambda:recognizeLayerVersion": true,
    "@aws-cdk/core:stackRelativeExports": true,
    "@aws-cdk/aws-apigateway:usagePlanKeyOrderInsensitiveId": true,
    "@aws-cdk/aws-ecs:arnFormatIncludesClusterName": true,
    "@aws-cdk/aws-s3:createDefaultLoggingPolicy": true,
    "@aws-cdk/core:target-partitions": ["aws", "aws-cn"]
  }
}
CDKJSON

echo ""
echo "✅ Project '$PROJECT_NAME' initialized successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  npx cdk synth          # Synthesize CloudFormation template"
echo "  npx cdk diff           # Preview changes"
echo "  npx cdk deploy         # Deploy to AWS"
echo "  npm test               # Run tests"
echo ""
echo "  Deploy to staging:  npx cdk deploy -c stage=staging"
echo "  Deploy to prod:     npx cdk deploy -c stage=prod"
