#!/usr/bin/env bash
#
# scaffold-lambda.sh — Scaffold a complete AWS Lambda project
#
# USAGE:
#   ./scaffold-lambda.sh --runtime <node|python|go|rust> --trigger <api|sqs|s3|schedule> --deploy <sam|cdk|serverless> [OPTIONS]
#
# OPTIONS:
#   --runtime   REQUIRED  Lambda runtime: node, python, go, rust
#   --trigger   REQUIRED  Event trigger type: api, sqs, s3, schedule
#   --deploy    REQUIRED  Deployment framework: sam, cdk, serverless
#   --name      OPTIONAL  Project name (default: my-lambda-project)
#   --help      Show this help message and exit
#
# DESCRIPTION:
#   Creates a fully-structured Lambda project directory containing:
#     - Handler source code for the chosen runtime
#     - Deployment configuration (SAM template.yaml, CDK stack, or serverless.yml)
#     - Event trigger wiring in the deployment config
#     - Unit test file
#     - .gitignore, README.md, and Makefile with build/deploy/test targets
#
# EXAMPLES:
#   ./scaffold-lambda.sh --runtime node --trigger api --deploy sam
#   ./scaffold-lambda.sh --runtime python --trigger sqs --deploy serverless --name order-processor
#   ./scaffold-lambda.sh --runtime go --trigger s3 --deploy cdk --name image-resizer
#   ./scaffold-lambda.sh --runtime rust --trigger schedule --deploy sam --name cleanup-job
#

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "${BLUE}[INFO]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
err()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }

# ── Defaults ──────────────────────────────────────────────────────────────────
RUNTIME=""
TRIGGER=""
DEPLOY=""
PROJECT_NAME="my-lambda-project"

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

# ── Parse Arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime)  RUNTIME="$2";       shift 2 ;;
        --trigger)  TRIGGER="$2";       shift 2 ;;
        --deploy)   DEPLOY="$2";        shift 2 ;;
        --name)     PROJECT_NAME="$2";  shift 2 ;;
        --help|-h)  usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
errors=0
if [[ -z "$RUNTIME" ]]; then err "--runtime is required"; errors=1; fi
if [[ -z "$TRIGGER" ]]; then err "--trigger is required"; errors=1; fi
if [[ -z "$DEPLOY" ]];  then err "--deploy is required";  errors=1; fi

if [[ -n "$RUNTIME" ]] && ! [[ "$RUNTIME" =~ ^(node|python|go|rust)$ ]]; then
    err "Invalid runtime '$RUNTIME'. Choose: node, python, go, rust"; errors=1
fi
if [[ -n "$TRIGGER" ]] && ! [[ "$TRIGGER" =~ ^(api|sqs|s3|schedule)$ ]]; then
    err "Invalid trigger '$TRIGGER'. Choose: api, sqs, s3, schedule"; errors=1
fi
if [[ -n "$DEPLOY" ]] && ! [[ "$DEPLOY" =~ ^(sam|cdk|serverless)$ ]]; then
    err "Invalid deploy '$DEPLOY'. Choose: sam, cdk, serverless"; errors=1
fi
if [[ $errors -ne 0 ]]; then exit 1; fi

# ── Derived values ────────────────────────────────────────────────────────────
HANDLER_NAME="handler"
case "$RUNTIME" in
    node)   RUNTIME_ID="nodejs20.x"; EXT="mjs"; SRC_DIR="src" ;;
    python) RUNTIME_ID="python3.12"; EXT="py";  SRC_DIR="src" ;;
    go)     RUNTIME_ID="provided.al2023"; EXT="go"; SRC_DIR="cmd" ;;
    rust)   RUNTIME_ID="provided.al2023"; EXT="rs"; SRC_DIR="src" ;;
esac

PROJECT_DIR="$(pwd)/$PROJECT_NAME"

if [[ -d "$PROJECT_DIR" ]]; then
    err "Directory '$PROJECT_DIR' already exists. Remove it or choose another --name."
    exit 1
fi

printf "\n${BOLD}${CYAN}╭──────────────────────────────────────────╮${RESET}\n"
printf "${BOLD}${CYAN}│   Lambda Project Scaffolder               │${RESET}\n"
printf "${BOLD}${CYAN}╰──────────────────────────────────────────╯${RESET}\n\n"
info "Project:  $PROJECT_NAME"
info "Runtime:  $RUNTIME ($RUNTIME_ID)"
info "Trigger:  $TRIGGER"
info "Deploy:   $DEPLOY"
echo ""

# ── Create directories ───────────────────────────────────────────────────────
info "Creating project structure..."
mkdir -p "$PROJECT_DIR"/{$SRC_DIR,tests,events}
ok "Directories created"

# ── Handler code ──────────────────────────────────────────────────────────────
info "Generating handler code ($RUNTIME)..."
case "$RUNTIME" in
node)
cat > "$PROJECT_DIR/$SRC_DIR/$HANDLER_NAME.$EXT" << 'HANDLER_EOF'
export const handler = async (event, context) => {
  console.log("Event:", JSON.stringify(event, null, 2));

  try {
    const result = await processEvent(event);
    return {
      statusCode: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: "Success", data: result }),
    };
  } catch (error) {
    console.error("Error:", error);
    return {
      statusCode: 500,
      body: JSON.stringify({ message: "Internal Server Error" }),
    };
  }
};

async function processEvent(event) {
  return { received: true, timestamp: new Date().toISOString() };
}
HANDLER_EOF
cat > "$PROJECT_DIR/package.json" << EOF
{
  "name": "$PROJECT_NAME",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "test": "node --experimental-vm-modules node_modules/.bin/jest",
    "lint": "eslint src/"
  },
  "devDependencies": {
    "jest": "^29.7.0",
    "@jest/globals": "^29.7.0"
  }
}
EOF
;;
python)
cat > "$PROJECT_DIR/$SRC_DIR/$HANDLER_NAME.$EXT" << 'HANDLER_EOF'
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """Lambda function entry point."""
    logger.info("Event: %s", json.dumps(event))

    try:
        result = process_event(event)
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "Success", "data": result}),
        }
    except Exception as e:
        logger.error("Error: %s", str(e))
        return {
            "statusCode": 500,
            "body": json.dumps({"message": "Internal Server Error"}),
        }


def process_event(event):
    """Process the incoming event."""
    from datetime import datetime, timezone
    return {"received": True, "timestamp": datetime.now(timezone.utc).isoformat()}
HANDLER_EOF
cat > "$PROJECT_DIR/requirements.txt" << 'EOF'
boto3>=1.34.0
pytest>=7.4.0
pytest-mock>=3.12.0
EOF
;;
go)
mkdir -p "$PROJECT_DIR/cmd"
cat > "$PROJECT_DIR/cmd/main.$EXT" << 'HANDLER_EOF'
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
)

type Response struct {
	StatusCode int               `json:"statusCode"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body"`
}

func handler(ctx context.Context, event json.RawMessage) (Response, error) {
	fmt.Printf("Event: %s\n", string(event))

	body, _ := json.Marshal(map[string]interface{}{
		"message":   "Success",
		"timestamp": time.Now().UTC().Format(time.RFC3339),
	})

	return Response{
		StatusCode: 200,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(body),
	}, nil
}

func main() {
	lambda.Start(handler)
}
HANDLER_EOF
cat > "$PROJECT_DIR/go.mod" << EOF
module $PROJECT_NAME

go 1.21

require github.com/aws/aws-lambda-go v1.47.0
EOF
;;
rust)
mkdir -p "$PROJECT_DIR/src"
cat > "$PROJECT_DIR/src/main.$EXT" << 'HANDLER_EOF'
use lambda_runtime::{service_fn, Error, LambdaEvent};
use serde_json::{json, Value};

async fn handler(event: LambdaEvent<Value>) -> Result<Value, Error> {
    let (payload, _context) = event.into_parts();
    println!("Event: {}", serde_json::to_string_pretty(&payload)?);

    Ok(json!({
        "statusCode": 200,
        "headers": { "Content-Type": "application/json" },
        "body": serde_json::to_string(&json!({
            "message": "Success",
            "received": true
        }))?
    }))
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    lambda_runtime::run(service_fn(handler)).await
}
HANDLER_EOF
cat > "$PROJECT_DIR/Cargo.toml" << EOF
[package]
name = "$PROJECT_NAME"
version = "0.1.0"
edition = "2021"

[dependencies]
lambda_runtime = "0.11"
serde_json = "1.0"
tokio = { version = "1", features = ["macros"] }
EOF
;;
esac
ok "Handler created: $SRC_DIR/$HANDLER_NAME.$EXT"

# ── Test file ─────────────────────────────────────────────────────────────────
info "Generating test file..."
case "$RUNTIME" in
node)
cat > "$PROJECT_DIR/tests/$HANDLER_NAME.test.$EXT" << 'TEST_EOF'
import { describe, it, expect } from "@jest/globals";
import { handler } from "../src/handler.mjs";

describe("Lambda Handler", () => {
  it("should return 200 on valid event", async () => {
    const event = { httpMethod: "GET", path: "/" };
    const result = await handler(event, {});
    expect(result.statusCode).toBe(200);
    const body = JSON.parse(result.body);
    expect(body.message).toBe("Success");
  });
});
TEST_EOF
;;
python)
cat > "$PROJECT_DIR/tests/test_$HANDLER_NAME.$EXT" << 'TEST_EOF'
import json
import pytest
from src.handler import handler


class TestHandler:
    def test_returns_200(self):
        event = {"httpMethod": "GET", "path": "/"}
        result = handler(event, {})
        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["message"] == "Success"

    def test_response_has_timestamp(self):
        result = handler({}, {})
        body = json.loads(result["body"])
        assert "timestamp" in body["data"]
TEST_EOF
touch "$PROJECT_DIR/src/__init__.py"
;;
go)
cat > "$PROJECT_DIR/cmd/main_test.go" << 'TEST_EOF'
package main

import (
	"context"
	"encoding/json"
	"testing"
)

func TestHandler(t *testing.T) {
	event := json.RawMessage(`{"key": "value"}`)
	resp, err := handler(context.Background(), event)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != 200 {
		t.Errorf("expected 200, got %d", resp.StatusCode)
	}
}
TEST_EOF
;;
rust)
cat > "$PROJECT_DIR/tests/handler_test.$EXT" << 'TEST_EOF'
// Integration tests would use lambda_runtime::testing utilities.
// Unit tests for business logic should be added as the project grows.
#[cfg(test)]
mod tests {
    #[test]
    fn placeholder() {
        assert!(true, "Replace with real tests");
    }
}
TEST_EOF
;;
esac
ok "Test file created"

# ── Deployment config ─────────────────────────────────────────────────────────
info "Generating deployment config ($DEPLOY)..."

# Map trigger → SAM/CDK/Serverless event config
build_sam_event() {
    case "$TRIGGER" in
    api)      echo "      Events:
        ApiEvent:
          Type: Api
          Properties:
            Path: /
            Method: get" ;;
    sqs)      echo "      Events:
        SQSEvent:
          Type: SQS
          Properties:
            Queue: !GetAtt InputQueue.Arn
            BatchSize: 10" ;;
    s3)       echo "      Events:
        S3Event:
          Type: S3
          Properties:
            Bucket: !Ref InputBucket
            Events: s3:ObjectCreated:*" ;;
    schedule) echo "      Events:
        ScheduleEvent:
          Type: Schedule
          Properties:
            Schedule: rate(1 hour)
            Enabled: true" ;;
    esac
}

build_sam_resources() {
    case "$TRIGGER" in
    sqs) echo "
  InputQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub \"\${AWS::StackName}-queue\"
      VisibilityTimeout: 60" ;;
    s3) echo "
  InputBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub \"\${AWS::StackName}-bucket\"" ;;
    *) echo "" ;;
    esac
}

case "$DEPLOY" in
sam)
HANDLER_REF="src/$HANDLER_NAME.handler"
[[ "$RUNTIME" == "go" ]] && HANDLER_REF="bootstrap"
[[ "$RUNTIME" == "rust" ]] && HANDLER_REF="bootstrap"
cat > "$PROJECT_DIR/template.yaml" << EOF
AWSTemplateFormatVersion: "2010-09-09"
Transform: AWS::Serverless-2016-10-31
Description: $PROJECT_NAME — $RUNTIME Lambda with $TRIGGER trigger

Globals:
  Function:
    Timeout: 30
    MemorySize: 256
    Tracing: Active
    Architectures:
      - arm64

Resources:
  AppFunction:
    Type: AWS::Serverless::Function
    Properties:
      FunctionName: $PROJECT_NAME
      Handler: $HANDLER_REF
      Runtime: $RUNTIME_ID
      CodeUri: .
$(build_sam_event)
$(build_sam_resources)

Outputs:
  FunctionArn:
    Description: Lambda function ARN
    Value: !GetAtt AppFunction.Arn
EOF
ok "SAM template.yaml created"
;;

cdk)
mkdir -p "$PROJECT_DIR/lib" "$PROJECT_DIR/bin"
cat > "$PROJECT_DIR/lib/stack.ts" << EOF
import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as apigateway from "aws-cdk-lib/aws-apigateway";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as sources from "aws-cdk-lib/aws-lambda-event-sources";
import { Construct } from "constructs";

export class AppStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const fn = new lambda.Function(this, "AppFunction", {
      functionName: "$PROJECT_NAME",
      runtime: lambda.Runtime.$(echo "$RUNTIME_ID" | tr '.' '_' | tr '[:lower:]' '[:upper:]'),
      handler: "src/handler.handler",
      code: lambda.Code.fromAsset("."),
      architecture: lambda.Architecture.ARM_64,
      memorySize: 256,
      timeout: cdk.Duration.seconds(30),
      tracing: lambda.Tracing.ACTIVE,
    });

$(case "$TRIGGER" in
api) echo '    const api = new apigateway.RestApi(this, "Api", { restApiName: "'"$PROJECT_NAME"'" });
    api.root.addMethod("GET", new apigateway.LambdaIntegration(fn));' ;;
sqs) echo '    const queue = new sqs.Queue(this, "InputQueue", { visibilityTimeout: cdk.Duration.seconds(60) });
    fn.addEventSource(new sources.SqsEventSource(queue, { batchSize: 10 }));' ;;
s3)  echo '    const bucket = new s3.Bucket(this, "InputBucket", { removalPolicy: cdk.RemovalPolicy.DESTROY });
    fn.addEventSource(new sources.S3EventSource(bucket, { events: [s3.EventType.OBJECT_CREATED] }));' ;;
schedule) echo '    const rule = new events.Rule(this, "ScheduleRule", { schedule: events.Schedule.rate(cdk.Duration.hours(1)) });
    rule.addTarget(new targets.LambdaFunction(fn));' ;;
esac)
  }
}
EOF
cat > "$PROJECT_DIR/bin/app.ts" << EOF
#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { AppStack } from "../lib/stack";

const app = new cdk.App();
new AppStack(app, "${PROJECT_NAME}-stack", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});
EOF
cat > "$PROJECT_DIR/cdk.json" << EOF
{ "app": "npx ts-node bin/app.ts" }
EOF
# Overwrite package.json for CDK projects
cat > "$PROJECT_DIR/package.json" << EOF
{
  "name": "$PROJECT_NAME",
  "version": "1.0.0",
  "scripts": {
    "build": "tsc",
    "cdk": "cdk",
    "deploy": "cdk deploy",
    "synth": "cdk synth",
    "test": "jest"
  },
  "devDependencies": {
    "aws-cdk-lib": "^2.140.0",
    "constructs": "^10.3.0",
    "typescript": "^5.4.0",
    "ts-node": "^10.9.0",
    "jest": "^29.7.0"
  }
}
EOF
ok "CDK stack created (lib/stack.ts, bin/app.ts, cdk.json)"
;;

serverless)
cat > "$PROJECT_DIR/serverless.yml" << EOF
service: $PROJECT_NAME

provider:
  name: aws
  runtime: $RUNTIME_ID
  architecture: arm64
  memorySize: 256
  timeout: 30
  tracing:
    lambda: true
  stage: \${opt:stage, 'dev'}
  region: \${opt:region, 'us-east-1'}

functions:
  app:
    handler: src/handler.handler
    events:
$(case "$TRIGGER" in
api)      echo "      - http:
          path: /
          method: get
          cors: true" ;;
sqs)      echo "      - sqs:
          arn: !GetAtt InputQueue.Arn
          batchSize: 10" ;;
s3)       echo "      - s3:
          bucket: \${self:service}-bucket
          event: s3:ObjectCreated:*" ;;
schedule) echo "      - schedule:
          rate: rate(1 hour)
          enabled: true" ;;
esac)

$(case "$TRIGGER" in
sqs) echo "resources:
  Resources:
    InputQueue:
      Type: AWS::SQS::Queue
      Properties:
        QueueName: \${self:service}-queue
        VisibilityTimeout: 60" ;;
*) echo "" ;;
esac)

plugins:
  - serverless-offline
EOF
ok "serverless.yml created"
;;
esac

# ── Sample event ──────────────────────────────────────────────────────────────
info "Generating sample event..."
case "$TRIGGER" in
api)
cat > "$PROJECT_DIR/events/event.json" << 'EOF'
{
  "httpMethod": "GET",
  "path": "/",
  "headers": { "Content-Type": "application/json" },
  "queryStringParameters": null,
  "body": null
}
EOF
;;
sqs)
cat > "$PROJECT_DIR/events/event.json" << 'EOF'
{
  "Records": [
    {
      "messageId": "msg-001",
      "body": "{\"action\":\"process\",\"id\":123}",
      "eventSource": "aws:sqs",
      "awsRegion": "us-east-1"
    }
  ]
}
EOF
;;
s3)
cat > "$PROJECT_DIR/events/event.json" << 'EOF'
{
  "Records": [
    {
      "eventSource": "aws:s3",
      "s3": {
        "bucket": { "name": "my-bucket" },
        "object": { "key": "uploads/test.txt", "size": 1024 }
      }
    }
  ]
}
EOF
;;
schedule)
cat > "$PROJECT_DIR/events/event.json" << 'EOF'
{
  "source": "aws.events",
  "detail-type": "Scheduled Event",
  "detail": {},
  "time": "2024-01-15T12:00:00Z"
}
EOF
;;
esac
ok "Sample event: events/event.json"

# ── .gitignore ────────────────────────────────────────────────────────────────
info "Creating .gitignore..."
cat > "$PROJECT_DIR/.gitignore" << 'EOF'
# Dependencies
node_modules/
__pycache__/
*.pyc
vendor/
target/

# Build artifacts
.aws-sam/
cdk.out/
.serverless/
bootstrap
*.zip

# IDE
.idea/
.vscode/
*.swp

# OS
.DS_Store
Thumbs.db

# Environment
.env
.env.local
EOF
ok ".gitignore created"

# ── README.md ─────────────────────────────────────────────────────────────────
info "Creating README.md..."
cat > "$PROJECT_DIR/README.md" << EOF
# $PROJECT_NAME

AWS Lambda function using **$RUNTIME** runtime with **$TRIGGER** trigger, deployed via **$DEPLOY**.

## Quick Start

\`\`\`bash
make build    # Build the project
make test     # Run tests
make deploy   # Deploy to AWS
\`\`\`

## Project Structure

\`\`\`
$PROJECT_NAME/
├── $SRC_DIR/            # Handler source code
├── tests/               # Unit tests
├── events/              # Sample event payloads
├── Makefile             # Build/deploy/test automation
└── $(case "$DEPLOY" in sam) echo "template.yaml" ;; cdk) echo "lib/stack.ts" ;; serverless) echo "serverless.yml" ;; esac)        # Deployment config
\`\`\`

## Configuration

- **Runtime**: $RUNTIME_ID
- **Architecture**: arm64
- **Memory**: 256 MB
- **Timeout**: 30 seconds
EOF
ok "README.md created"

# ── Makefile ──────────────────────────────────────────────────────────────────
info "Creating Makefile..."
cat > "$PROJECT_DIR/Makefile" << 'MAKEFILE_HEAD'
.PHONY: build test deploy clean invoke local

MAKEFILE_HEAD

case "$RUNTIME" in
node)
cat >> "$PROJECT_DIR/Makefile" << 'EOF'
build:
	npm install

test:
	npm test

clean:
	rm -rf node_modules .aws-sam cdk.out .serverless
EOF
;;
python)
cat >> "$PROJECT_DIR/Makefile" << 'EOF'
build:
	pip install -r requirements.txt -t .package
	cp -r src .package/

test:
	python -m pytest tests/ -v

clean:
	rm -rf .package __pycache__ .aws-sam .serverless .pytest_cache
EOF
;;
go)
cat >> "$PROJECT_DIR/Makefile" << 'EOF'
build:
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o bootstrap ./cmd/

test:
	go test ./... -v

clean:
	rm -f bootstrap
	rm -rf .aws-sam .serverless
EOF
;;
rust)
cat >> "$PROJECT_DIR/Makefile" << 'EOF'
build:
	cargo lambda build --release --arm64

test:
	cargo test

clean:
	cargo clean
	rm -rf .aws-sam .serverless
EOF
;;
esac

case "$DEPLOY" in
sam)
cat >> "$PROJECT_DIR/Makefile" << 'EOF'

deploy: build
	sam build
	sam deploy --guided

invoke:
	sam local invoke AppFunction -e events/event.json

local:
	sam local start-api
EOF
;;
cdk)
cat >> "$PROJECT_DIR/Makefile" << 'EOF'

deploy: build
	npx cdk deploy

invoke:
	@echo "Use 'sam local invoke' or deploy and test via AWS CLI"

synth:
	npx cdk synth
EOF
;;
serverless)
cat >> "$PROJECT_DIR/Makefile" << 'EOF'

deploy: build
	npx serverless deploy

invoke:
	npx serverless invoke local -f app -p events/event.json

local:
	npx serverless offline
EOF
;;
esac
ok "Makefile created"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}${GREEN}╭──────────────────────────────────────────╮${RESET}\n"
printf "${BOLD}${GREEN}│   ✅  Project scaffolded successfully!    │${RESET}\n"
printf "${BOLD}${GREEN}╰──────────────────────────────────────────╯${RESET}\n\n"

echo "  📁 $PROJECT_DIR"
echo ""
info "Next steps:"
echo "    cd $PROJECT_NAME"
echo "    make build"
echo "    make test"
echo "    make deploy"
echo ""
