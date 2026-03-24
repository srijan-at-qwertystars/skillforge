#!/usr/bin/env bash
#
# scaffold-pulumi-project.sh - Scaffold a new Pulumi infrastructure project
#
# Usage:
#   scaffold-pulumi-project.sh [OPTIONS]
#
# Options:
#   --cloud      aws|azure|gcp       Target cloud provider (required)
#   --language   ts|python|go        Programming language (required)
#   --template   vpc|eks|serverless|static-site  Project template (required)
#   --name       <project-name>      Name for the Pulumi project (required)
#   --dir        <directory>         Output directory (default: ./<project-name>)
#   -h, --help                       Show this help message
#
# Examples:
#   scaffold-pulumi-project.sh --cloud aws --language ts --template vpc --name my-network
#   scaffold-pulumi-project.sh --cloud gcp --language python --template serverless --name api-functions --dir ./infra
#
# Description:
#   Generates a complete Pulumi project scaffold with the correct runtime,
#   dependencies, starter code, stack config, and .gitignore for the chosen
#   cloud/language/template combination.

set -euo pipefail

# ─── Colors & helpers ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
  sed -n '3,/^$/s/^# \?//p' "$0"
  exit 0
}

# ─── Argument parsing ───────────────────────────────────────────────────────

CLOUD=""
LANGUAGE=""
TEMPLATE=""
PROJECT_NAME=""
OUTPUT_DIR=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cloud)    CLOUD="$2";        shift 2 ;;
      --language) LANGUAGE="$2";     shift 2 ;;
      --template) TEMPLATE="$2";     shift 2 ;;
      --name)     PROJECT_NAME="$2"; shift 2 ;;
      --dir)      OUTPUT_DIR="$2";   shift 2 ;;
      -h|--help)  usage ;;
      *)          die "Unknown option: $1. Use -h for help." ;;
    esac
  done
}

# ─── Validation ──────────────────────────────────────────────────────────────

validate_inputs() {
  local valid=true

  if [[ -z "$CLOUD" ]]; then
    err "Missing required flag: --cloud"; valid=false
  elif [[ ! "$CLOUD" =~ ^(aws|azure|gcp)$ ]]; then
    err "Invalid cloud provider '$CLOUD'. Must be aws, azure, or gcp."; valid=false
  fi

  if [[ -z "$LANGUAGE" ]]; then
    err "Missing required flag: --language"; valid=false
  elif [[ ! "$LANGUAGE" =~ ^(ts|python|go)$ ]]; then
    err "Invalid language '$LANGUAGE'. Must be ts, python, or go."; valid=false
  fi

  if [[ -z "$TEMPLATE" ]]; then
    err "Missing required flag: --template"; valid=false
  elif [[ ! "$TEMPLATE" =~ ^(vpc|eks|serverless|static-site)$ ]]; then
    err "Invalid template '$TEMPLATE'. Must be vpc, eks, serverless, or static-site."; valid=false
  fi

  if [[ -z "$PROJECT_NAME" ]]; then
    err "Missing required flag: --name"; valid=false
  elif [[ ! "$PROJECT_NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
    err "Project name must start with a lowercase letter and contain only [a-z0-9-]."; valid=false
  fi

  [[ "$valid" == "true" ]] || die "Validation failed. Use -h for help."

  # Default output directory to the project name
  OUTPUT_DIR="${OUTPUT_DIR:-"./$PROJECT_NAME"}"

  if [[ -d "$OUTPUT_DIR" ]]; then
    die "Directory '$OUTPUT_DIR' already exists. Remove it or choose a different --dir."
  fi
}

# ─── Runtime helpers ─────────────────────────────────────────────────────────

runtime_name() {
  case "$LANGUAGE" in
    ts)     echo "nodejs" ;;
    python) echo "python" ;;
    go)     echo "go" ;;
  esac
}

cloud_plugin() {
  case "$CLOUD" in
    aws)   echo "@pulumi/aws" ;;
    azure) echo "@pulumi/azure-native" ;;
    gcp)   echo "@pulumi/gcp" ;;
  esac
}

cloud_region_key() {
  case "$CLOUD" in
    aws)   echo "aws:region" ;;
    azure) echo "azure-native:location" ;;
    gcp)   echo "gcp:project" ;;
  esac
}

cloud_region_default() {
  case "$CLOUD" in
    aws)   echo "us-west-2" ;;
    azure) echo "WestUS2" ;;
    gcp)   echo "my-gcp-project" ;;
  esac
}

# ─── Pulumi.yaml ─────────────────────────────────────────────────────────────

generate_pulumi_yaml() {
  local runtime
  runtime="$(runtime_name)"

  local runtime_block
  if [[ "$LANGUAGE" == "ts" ]]; then
    runtime_block="runtime:
  name: nodejs
  options:
    typescript: true"
  else
    runtime_block="runtime: ${runtime}"
  fi

  cat > "$OUTPUT_DIR/Pulumi.yaml" <<EOF
name: ${PROJECT_NAME}
${runtime_block}
description: "${TEMPLATE} infrastructure on ${CLOUD}, managed by Pulumi"
EOF
  ok "Created Pulumi.yaml"
}

# ─── Pulumi.dev.yaml ─────────────────────────────────────────────────────────

generate_stack_config() {
  local region_key region_default
  region_key="$(cloud_region_key)"
  region_default="$(cloud_region_default)"

  cat > "$OUTPUT_DIR/Pulumi.dev.yaml" <<EOF
# Stack configuration for the dev environment
config:
  ${region_key}: ${region_default}
  ${PROJECT_NAME}:environment: dev
EOF
  ok "Created Pulumi.dev.yaml"
}

# ─── .gitignore ──────────────────────────────────────────────────────────────

generate_gitignore() {
  local content=""
  case "$LANGUAGE" in
    ts)
      content="node_modules/
bin/
dist/
*.js
*.js.map
*.d.ts
!jest.config.js
package-lock.json"
      ;;
    python)
      content="__pycache__/
*.pyc
.venv/
venv/
*.egg-info/
dist/
build/"
      ;;
    go)
      content="bin/
vendor/
*.exe
*.test
*.out"
      ;;
  esac

  cat > "$OUTPUT_DIR/.gitignore" <<EOF
${content}

# Pulumi
Pulumi.*.yaml.bak
EOF
  ok "Created .gitignore"
}

# ─── TypeScript files ────────────────────────────────────────────────────────

generate_ts_deps() {
  local cloud_pkg
  cloud_pkg="$(cloud_plugin)"
  local extra_deps=""
  case "$TEMPLATE" in
    vpc)          extra_deps='"@pulumi/awsx": "^2.0.0",' ;;
    eks)          extra_deps='"@pulumi/awsx": "^2.0.0", "@pulumi/eks": "^2.0.0",' ;;
    serverless)   extra_deps="" ;;
    static-site)  extra_deps="" ;;
  esac

  cat > "$OUTPUT_DIR/package.json" <<EOF
{
  "name": "${PROJECT_NAME}",
  "version": "0.1.0",
  "main": "index.ts",
  "devDependencies": {
    "@types/node": "^20.0.0",
    "typescript": "^5.0.0"
  },
  "dependencies": {
    "@pulumi/pulumi": "^3.0.0",
    "${cloud_pkg}": "^6.0.0"${extra_deps:+,}
    ${extra_deps}
  }
}
EOF

  cat > "$OUTPUT_DIR/tsconfig.json" <<EOF
{
  "compilerOptions": {
    "strict": true,
    "outDir": "bin",
    "target": "es2020",
    "module": "commonjs",
    "moduleResolution": "node",
    "sourceMap": true,
    "experimentalDecorators": true,
    "pretty": true,
    "noFallthroughCasesInSwitch": true,
    "noImplicitReturns": true,
    "forceConsistentCasingInFileNames": true
  },
  "files": ["index.ts"]
}
EOF
  ok "Created package.json & tsconfig.json"
}

generate_ts_index() {
  local file="$OUTPUT_DIR/index.ts"
  case "$TEMPLATE" in
    vpc)
      cat > "$file" <<'TSEOF'
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as awsx from "@pulumi/awsx";

const config = new pulumi.Config();
const env = config.require("environment");

// Create a VPC with public and private subnets
const vpc = new awsx.ec2.Vpc(`${env}-vpc`, {
  cidrBlock: "10.0.0.0/16",
  numberOfAvailabilityZones: 2,
  natGateways: { strategy: awsx.ec2.NatGatewayStrategy.Single },
  tags: { Environment: env, ManagedBy: "pulumi" },
});

export const vpcId = vpc.vpcId;
export const publicSubnetIds = vpc.publicSubnetIds;
export const privateSubnetIds = vpc.privateSubnetIds;
TSEOF
      ;;
    eks)
      cat > "$file" <<'TSEOF'
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as awsx from "@pulumi/awsx";
import * as eks from "@pulumi/eks";

const config = new pulumi.Config();
const env = config.require("environment");
const nodeCount = config.getNumber("nodeCount") || 2;
const instanceType = config.get("instanceType") || "t3.medium";

const vpc = new awsx.ec2.Vpc(`${env}-vpc`, {
  cidrBlock: "10.0.0.0/16",
  numberOfAvailabilityZones: 2,
  natGateways: { strategy: awsx.ec2.NatGatewayStrategy.Single },
});

const cluster = new eks.Cluster(`${env}-cluster`, {
  vpcId: vpc.vpcId,
  subnetIds: vpc.privateSubnetIds,
  instanceType: instanceType,
  desiredCapacity: nodeCount,
  minSize: 1,
  maxSize: nodeCount * 2,
});

export const kubeconfig = cluster.kubeconfig;
export const clusterName = cluster.eksCluster.name;
TSEOF
      ;;
    serverless)
      cat > "$file" <<'TSEOF'
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

const config = new pulumi.Config();
const env = config.require("environment");

// IAM role for Lambda
const lambdaRole = new aws.iam.Role(`${env}-lambda-role`, {
  assumeRolePolicy: aws.iam.assumeRolePolicyForPrincipal({
    Service: "lambda.amazonaws.com",
  }),
});

new aws.iam.RolePolicyAttachment(`${env}-lambda-basic`, {
  role: lambdaRole,
  policyArn: aws.iam.ManagedPolicy.AWSLambdaBasicExecutionRole,
});

// Lambda function
const fn = new aws.lambda.Function(`${env}-api-handler`, {
  runtime: aws.lambda.Runtime.NodeJS20dX,
  handler: "index.handler",
  role: lambdaRole.arn,
  code: new pulumi.asset.AssetArchive({
    "index.js": new pulumi.asset.StringAsset(
      `exports.handler = async (event) => ({
        statusCode: 200,
        body: JSON.stringify({ message: "Hello from ${env}!" }),
      });`
    ),
  }),
  tags: { Environment: env },
});

// API Gateway
const api = new aws.apigatewayv2.Api(`${env}-http-api`, {
  protocolType: "HTTP",
});

const integration = new aws.apigatewayv2.Integration(`${env}-integration`, {
  apiId: api.id,
  integrationType: "AWS_PROXY",
  integrationUri: fn.arn,
});

const route = new aws.apigatewayv2.Route(`${env}-route`, {
  apiId: api.id,
  routeKey: "GET /",
  target: pulumi.interpolate`integrations/${integration.id}`,
});

const stage = new aws.apigatewayv2.Stage(`${env}-stage`, {
  apiId: api.id,
  name: "$default",
  autoDeploy: true,
});

export const apiUrl = api.apiEndpoint;
export const functionName = fn.name;
TSEOF
      ;;
    static-site)
      cat > "$file" <<'TSEOF'
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

const config = new pulumi.Config();
const env = config.require("environment");
const domain = config.get("domainName");

// S3 bucket for website content
const bucket = new aws.s3.BucketV2(`${env}-site-bucket`, {
  tags: { Environment: env, ManagedBy: "pulumi" },
});

new aws.s3.BucketWebsiteConfigurationV2(`${env}-site-config`, {
  bucket: bucket.id,
  indexDocument: { suffix: "index.html" },
  errorDocument: { key: "error.html" },
});

// CloudFront distribution
const oai = new aws.cloudfront.OriginAccessIdentity(`${env}-oai`, {
  comment: `OAI for ${env} static site`,
});

const cdn = new aws.cloudfront.Distribution(`${env}-cdn`, {
  enabled: true,
  defaultRootObject: "index.html",
  origins: [{
    originId: bucket.arn,
    domainName: bucket.bucketRegionalDomainName,
    s3OriginConfig: { originAccessIdentity: oai.cloudfrontAccessIdentityPath },
  }],
  defaultCacheBehavior: {
    targetOriginId: bucket.arn,
    viewerProtocolPolicy: "redirect-to-https",
    allowedMethods: ["GET", "HEAD"],
    cachedMethods: ["GET", "HEAD"],
    forwardedValues: { queryString: false, cookies: { forward: "none" } },
  },
  restrictions: { geoRestriction: { restrictionType: "none" } },
  viewerCertificate: { cloudfrontDefaultCertificate: true },
});

export const bucketName = bucket.id;
export const cdnUrl = pulumi.interpolate`https://${cdn.domainName}`;
TSEOF
      ;;
  esac
  ok "Created index.ts (${TEMPLATE} template)"
}

# ─── Python files ─────────────────────────────────────────────────────────────

generate_python_deps() {
  local cloud_pkg
  case "$CLOUD" in
    aws)   cloud_pkg="pulumi-aws>=6.0.0" ;;
    azure) cloud_pkg="pulumi-azure-native>=2.0.0" ;;
    gcp)   cloud_pkg="pulumi-gcp>=7.0.0" ;;
  esac
  local extra=""
  case "$TEMPLATE" in
    vpc|eks) extra=$'\npulumi-awsx>=2.0.0' ;;
  esac

  cat > "$OUTPUT_DIR/requirements.txt" <<EOF
pulumi>=3.0.0
${cloud_pkg}${extra}
EOF
  ok "Created requirements.txt"
}

generate_python_main() {
  local file="$OUTPUT_DIR/__main__.py"
  case "$TEMPLATE" in
    vpc)
      cat > "$file" <<'PYEOF'
"""VPC infrastructure managed by Pulumi."""
import pulumi
import pulumi_awsx as awsx

config = pulumi.Config()
env = config.require("environment")

vpc = awsx.ec2.Vpc(
    f"{env}-vpc",
    cidr_block="10.0.0.0/16",
    number_of_availability_zones=2,
    nat_gateways=awsx.ec2.NatGatewayConfigurationArgs(
        strategy=awsx.ec2.NatGatewayStrategy.SINGLE,
    ),
    tags={"Environment": env, "ManagedBy": "pulumi"},
)

pulumi.export("vpc_id", vpc.vpc_id)
pulumi.export("public_subnet_ids", vpc.public_subnet_ids)
pulumi.export("private_subnet_ids", vpc.private_subnet_ids)
PYEOF
      ;;
    *)
      cat > "$file" <<PYEOF
"""${TEMPLATE} infrastructure managed by Pulumi."""
import pulumi
import pulumi_${CLOUD} as cloud

config = pulumi.Config()
env = config.require("environment")

# TODO: Add ${TEMPLATE} resources for ${CLOUD}
pulumi.export("environment", env)
PYEOF
      ;;
  esac
  ok "Created __main__.py (${TEMPLATE} template)"
}

# ─── Go files ─────────────────────────────────────────────────────────────────

generate_go_deps() {
  cat > "$OUTPUT_DIR/go.mod" <<EOF
module ${PROJECT_NAME}

go 1.21

require (
	github.com/pulumi/pulumi/sdk/v3 v3.100.0
	github.com/pulumi/pulumi-${CLOUD}/sdk/v6 v6.0.0
)
EOF
  ok "Created go.mod"
}

generate_go_main() {
  local file="$OUTPUT_DIR/main.go"
  cat > "$file" <<GOEOF
package main

import (
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "")
		env := cfg.Require("environment")

		// TODO: Add ${TEMPLATE} resources for ${CLOUD}
		ctx.Export("environment", pulumi.String(env))
		return nil
	})
}
GOEOF
  ok "Created main.go (${TEMPLATE} template)"
}

# ─── Orchestration ───────────────────────────────────────────────────────────

generate_language_files() {
  case "$LANGUAGE" in
    ts)
      generate_ts_deps
      generate_ts_index
      ;;
    python)
      generate_python_deps
      generate_python_main
      ;;
    go)
      generate_go_deps
      generate_go_main
      ;;
  esac
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  validate_inputs

  info "Scaffolding Pulumi project '${PROJECT_NAME}'"
  info "  Cloud:    ${CLOUD}"
  info "  Language: ${LANGUAGE}"
  info "  Template: ${TEMPLATE}"
  info "  Dir:      ${OUTPUT_DIR}"
  echo

  mkdir -p "$OUTPUT_DIR"

  generate_pulumi_yaml
  generate_stack_config
  generate_gitignore
  generate_language_files

  echo
  ok "Project scaffolded at ${OUTPUT_DIR}"
  info "Next steps:"
  info "  cd ${OUTPUT_DIR}"
  case "$LANGUAGE" in
    ts)     info "  npm install" ;;
    python) info "  python -m venv venv && source venv/bin/activate && pip install -r requirements.txt" ;;
    go)     info "  go mod tidy" ;;
  esac
  info "  pulumi stack init dev"
  info "  pulumi up"
}

main "$@"
