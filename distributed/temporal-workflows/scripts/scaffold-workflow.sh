#!/usr/bin/env bash
# scaffold-workflow.sh — Generate a new Temporal workflow project scaffold
#
# Usage:
#   ./scaffold-workflow.sh --name my-workflow --lang typescript
#   ./scaffold-workflow.sh --name order-processor --lang go
#   ./scaffold-workflow.sh --name my-workflow --lang typescript --dir ./projects

set -euo pipefail

# Defaults
PROJECT_NAME=""
LANGUAGE=""
OUTPUT_DIR="."

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    echo "Usage: $0 --name <project-name> --lang <typescript|go> [--dir <output-dir>]"
    echo ""
    echo "Options:"
    echo "  --name NAME    Project name (required, used for directory and task queue)"
    echo "  --lang LANG    Language: 'typescript' or 'go' (required)"
    echo "  --dir DIR      Output directory (default: current directory)"
    echo "  -h, --help     Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --name order-processor --lang typescript"
    echo "  $0 --name payment-service --lang go --dir ./services"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)  PROJECT_NAME="$2"; shift 2 ;;
        --lang)  LANGUAGE="$2"; shift 2 ;;
        --dir)   OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)       log_error "Unknown option: $1"; usage ;;
    esac
done

# Validate
if [[ -z "$PROJECT_NAME" ]]; then
    log_error "Project name is required. Use --name <name>"
    exit 1
fi

if [[ -z "$LANGUAGE" ]]; then
    log_error "Language is required. Use --lang <typescript|go>"
    exit 1
fi

if [[ "$LANGUAGE" != "typescript" && "$LANGUAGE" != "go" ]]; then
    log_error "Unsupported language: $LANGUAGE. Use 'typescript' or 'go'."
    exit 1
fi

PROJECT_DIR="${OUTPUT_DIR}/${PROJECT_NAME}"

if [[ -d "$PROJECT_DIR" ]]; then
    log_error "Directory already exists: $PROJECT_DIR"
    exit 1
fi

TASK_QUEUE="${PROJECT_NAME}-queue"

scaffold_typescript() {
    log_info "Scaffolding TypeScript Temporal project: $PROJECT_NAME"

    mkdir -p "$PROJECT_DIR/src"

    # package.json
    cat > "$PROJECT_DIR/package.json" <<PKGJSON
{
  "name": "${PROJECT_NAME}",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "build": "tsc --build",
    "build:watch": "tsc --build --watch",
    "start:worker": "ts-node src/worker.ts",
    "start:client": "ts-node src/client.ts",
    "test": "jest --config jest.config.js",
    "lint": "eslint src/"
  },
  "dependencies": {
    "@temporalio/activity": "^1.11.0",
    "@temporalio/client": "^1.11.0",
    "@temporalio/worker": "^1.11.0",
    "@temporalio/workflow": "^1.11.0"
  },
  "devDependencies": {
    "@temporalio/testing": "^1.11.0",
    "@types/jest": "^29.5.0",
    "@types/node": "^20.0.0",
    "jest": "^29.7.0",
    "ts-jest": "^29.1.0",
    "ts-node": "^10.9.0",
    "typescript": "^5.4.0"
  }
}
PKGJSON

    # tsconfig.json
    cat > "$PROJECT_DIR/tsconfig.json" <<TSCONFIG
{
  "compilerOptions": {
    "target": "ES2021",
    "module": "commonjs",
    "lib": ["ES2021"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true
  },
  "include": ["src/**/*.ts"],
  "exclude": ["node_modules", "dist"]
}
TSCONFIG

    # jest.config.js
    cat > "$PROJECT_DIR/jest.config.js" <<JEST
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  testMatch: ['**/src/**/*.test.ts'],
  moduleFileExtensions: ['ts', 'js', 'json'],
};
JEST

    # Activities
    cat > "$PROJECT_DIR/src/activities.ts" <<'ACTIVITIES'
import { log } from '@temporalio/activity';

export interface ProcessInput {
  id: string;
  data: string;
}

export interface ProcessResult {
  id: string;
  status: string;
  processedAt: string;
}

export async function validateInput(input: ProcessInput): Promise<void> {
  log.info('Validating input', { id: input.id });
  if (!input.id || !input.data) {
    throw new Error('Invalid input: id and data are required');
  }
}

export async function processData(input: ProcessInput): Promise<ProcessResult> {
  log.info('Processing data', { id: input.id });
  // Replace with actual business logic
  return {
    id: input.id,
    status: 'completed',
    processedAt: new Date().toISOString(),
  };
}

export async function sendNotification(result: ProcessResult): Promise<void> {
  log.info('Sending notification', { id: result.id, status: result.status });
  // Replace with actual notification logic (email, Slack, etc.)
}
ACTIVITIES

    # Workflows
    cat > "$PROJECT_DIR/src/workflows.ts" <<WORKFLOWS
import * as wf from '@temporalio/workflow';
import type * as activities from './activities';

const { validateInput, processData, sendNotification } = wf.proxyActivities<typeof activities>({
  startToCloseTimeout: '30s',
  retry: {
    initialInterval: '1s',
    backoffCoefficient: 2,
    maximumAttempts: 3,
    nonRetryableErrorTypes: ['Error'],
  },
});

// Signals and queries
export const cancelSignal = wf.defineSignal('cancel');
export const statusQuery = wf.defineQuery<string>('status');

export interface WorkflowInput {
  id: string;
  data: string;
}

export async function ${PROJECT_NAME//-/}Workflow(input: WorkflowInput): Promise<string> {
  let status = 'started';
  let cancelled = false;

  // Register signal and query handlers
  wf.setHandler(cancelSignal, () => { cancelled = true; });
  wf.setHandler(statusQuery, () => status);

  // Step 1: Validate
  status = 'validating';
  await validateInput(input);

  // Check for cancellation
  if (cancelled) {
    status = 'cancelled';
    return 'Workflow cancelled by user';
  }

  // Step 2: Process
  status = 'processing';
  const result = await processData(input);

  // Step 3: Notify
  status = 'notifying';
  await sendNotification(result);

  status = 'completed';
  return \`Processed \${result.id}: \${result.status}\`;
}
WORKFLOWS

    # Worker
    cat > "$PROJECT_DIR/src/worker.ts" <<WORKER
import { Worker, NativeConnection } from '@temporalio/worker';
import * as activities from './activities';

async function run(): Promise<void> {
  const connection = await NativeConnection.connect({
    address: process.env.TEMPORAL_ADDRESS ?? 'localhost:7233',
  });

  const worker = await Worker.create({
    connection,
    namespace: process.env.TEMPORAL_NAMESPACE ?? 'default',
    workflowsPath: require.resolve('./workflows'),
    activities,
    taskQueue: '${TASK_QUEUE}',
    maxConcurrentActivityTaskExecutions: 100,
    maxConcurrentWorkflowTaskExecutions: 40,
  });

  console.log('Worker started, polling on task queue: ${TASK_QUEUE}');
  await worker.run();
}

run().catch((err) => {
  console.error('Worker failed:', err);
  process.exit(1);
});
WORKER

    # Client
    cat > "$PROJECT_DIR/src/client.ts" <<CLIENT
import { Client, Connection } from '@temporalio/client';

async function run(): Promise<void> {
  const connection = await Connection.connect({
    address: process.env.TEMPORAL_ADDRESS ?? 'localhost:7233',
  });

  const client = new Client({
    connection,
    namespace: process.env.TEMPORAL_NAMESPACE ?? 'default',
  });

  const workflowId = '${PROJECT_NAME}-' + Date.now();

  const handle = await client.workflow.start('${PROJECT_NAME//-/}Workflow', {
    args: [{ id: 'item-1', data: 'sample data' }],
    taskQueue: '${TASK_QUEUE}',
    workflowId,
  });

  console.log(\`Started workflow: \${workflowId}\`);
  console.log(\`Run ID: \${handle.firstExecutionRunId}\`);

  const result = await handle.result();
  console.log(\`Result: \${result}\`);
}

run().catch((err) => {
  console.error('Client failed:', err);
  process.exit(1);
});
CLIENT

    # Test
    cat > "$PROJECT_DIR/src/workflows.test.ts" <<'TEST'
import { TestWorkflowEnvironment } from '@temporalio/testing';
import { Worker } from '@temporalio/worker';

describe('Workflow', () => {
  let env: TestWorkflowEnvironment;

  beforeAll(async () => {
    env = await TestWorkflowEnvironment.createTimeSkipping();
  });

  afterAll(async () => {
    await env?.teardown();
  });

  it('should complete successfully', async () => {
    const worker = await Worker.create({
      connection: env.nativeConnection,
      workflowsPath: require.resolve('./workflows'),
      activities: {
        validateInput: async () => {},
        processData: async (input: any) => ({
          id: input.id,
          status: 'completed',
          processedAt: new Date().toISOString(),
        }),
        sendNotification: async () => {},
      },
      taskQueue: 'test-queue',
    });

    await worker.runUntil(async () => {
      const result = await env.client.workflow.execute('Workflow', {
        args: [{ id: 'test-1', data: 'test data' }],
        taskQueue: 'test-queue',
        workflowId: 'test-wf-1',
      });
      expect(result).toContain('Processed test-1');
    });
  });
});
TEST

    # .gitignore
    cat > "$PROJECT_DIR/.gitignore" <<GITIGNORE
node_modules/
dist/
*.js.map
*.d.ts
!jest.config.js
.env
temporal-dev.db
GITIGNORE

    # README
    cat > "$PROJECT_DIR/README.md" <<README
# ${PROJECT_NAME}

Temporal workflow project.

## Setup

\`\`\`bash
npm install
temporal server start-dev  # In a separate terminal
\`\`\`

## Run

\`\`\`bash
npm run start:worker   # Terminal 1: Start the worker
npm run start:client   # Terminal 2: Execute a workflow
\`\`\`

## Test

\`\`\`bash
npm test
\`\`\`

## Task Queue: \`${TASK_QUEUE}\`
README

    log_ok "TypeScript project created at: $PROJECT_DIR"
    echo ""
    log_info "Next steps:"
    echo "  cd $PROJECT_DIR"
    echo "  npm install"
    echo "  temporal server start-dev  # In another terminal"
    echo "  npm run start:worker       # Start worker"
    echo "  npm run start:client       # Run workflow"
}

scaffold_go() {
    log_info "Scaffolding Go Temporal project: $PROJECT_NAME"

    GO_MODULE="github.com/example/${PROJECT_NAME}"
    mkdir -p "$PROJECT_DIR"/{workflow,activity,worker,starter}

    # go.mod
    cat > "$PROJECT_DIR/go.mod" <<GOMOD
module ${GO_MODULE}

go 1.22

require (
	go.temporal.io/sdk v1.29.0
	github.com/stretchr/testify v1.9.0
)
GOMOD

    # Activity
    cat > "$PROJECT_DIR/activity/activities.go" <<'GOACT'
package activity

import (
	"context"
	"fmt"
	"time"

	"go.temporal.io/sdk/activity"
)

type ProcessInput struct {
	ID   string
	Data string
}

type ProcessResult struct {
	ID          string
	Status      string
	ProcessedAt string
}

func ValidateInput(ctx context.Context, input ProcessInput) error {
	logger := activity.GetLogger(ctx)
	logger.Info("Validating input", "id", input.ID)

	if input.ID == "" || input.Data == "" {
		return fmt.Errorf("invalid input: id and data are required")
	}
	return nil
}

func ProcessData(ctx context.Context, input ProcessInput) (*ProcessResult, error) {
	logger := activity.GetLogger(ctx)
	logger.Info("Processing data", "id", input.ID)

	// Replace with actual business logic
	return &ProcessResult{
		ID:          input.ID,
		Status:      "completed",
		ProcessedAt: time.Now().Format(time.RFC3339),
	}, nil
}

func SendNotification(ctx context.Context, result ProcessResult) error {
	logger := activity.GetLogger(ctx)
	logger.Info("Sending notification", "id", result.ID, "status", result.Status)
	// Replace with actual notification logic
	return nil
}
GOACT

    # Workflow
    cat > "$PROJECT_DIR/workflow/workflow.go" <<GOWF
package workflow

import (
	"fmt"
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"

	act "${GO_MODULE}/activity"
)

func ${PROJECT_NAME//-/}Workflow(ctx workflow.Context, input act.ProcessInput) (string, error) {
	logger := workflow.GetLogger(ctx)
	logger.Info("Workflow started", "id", input.ID)

	ao := workflow.ActivityOptions{
		StartToCloseTimeout: 30 * time.Second,
		RetryPolicy: &temporal.RetryPolicy{
			InitialInterval:    time.Second,
			BackoffCoefficient: 2.0,
			MaximumAttempts:    3,
		},
	}
	ctx = workflow.WithActivityOptions(ctx, ao)

	// Step 1: Validate
	if err := workflow.ExecuteActivity(ctx, act.ValidateInput, input).Get(ctx, nil); err != nil {
		return "", fmt.Errorf("validation failed: %w", err)
	}

	// Step 2: Process
	var result act.ProcessResult
	if err := workflow.ExecuteActivity(ctx, act.ProcessData, input).Get(ctx, &result); err != nil {
		return "", fmt.Errorf("processing failed: %w", err)
	}

	// Step 3: Notify
	if err := workflow.ExecuteActivity(ctx, act.SendNotification, result).Get(ctx, nil); err != nil {
		return "", fmt.Errorf("notification failed: %w", err)
	}

	return fmt.Sprintf("Processed %s: %s", result.ID, result.Status), nil
}
GOWF

    # Worker
    cat > "$PROJECT_DIR/worker/main.go" <<GOWORKER
package main

import (
	"log"

	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"

	act "${GO_MODULE}/activity"
	wf "${GO_MODULE}/workflow"
)

func main() {
	c, err := client.Dial(client.Options{
		HostPort: "localhost:7233",
	})
	if err != nil {
		log.Fatalf("Unable to connect to Temporal: %v", err)
	}
	defer c.Close()

	w := worker.New(c, "${TASK_QUEUE}", worker.Options{
		MaxConcurrentActivityExecutionSize:     200,
		MaxConcurrentWorkflowTaskExecutionSize: 100,
	})

	w.RegisterWorkflow(wf.${PROJECT_NAME//-/}Workflow)
	w.RegisterActivity(act.ValidateInput)
	w.RegisterActivity(act.ProcessData)
	w.RegisterActivity(act.SendNotification)

	log.Println("Worker started, polling on task queue: ${TASK_QUEUE}")
	if err := w.Run(worker.InterruptCh()); err != nil {
		log.Fatalf("Worker failed: %v", err)
	}
}
GOWORKER

    # Starter
    cat > "$PROJECT_DIR/starter/main.go" <<GOSTARTER
package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"go.temporal.io/sdk/client"

	act "${GO_MODULE}/activity"
	wf "${GO_MODULE}/workflow"
)

func main() {
	c, err := client.Dial(client.Options{
		HostPort: "localhost:7233",
	})
	if err != nil {
		log.Fatalf("Unable to connect to Temporal: %v", err)
	}
	defer c.Close()

	workflowID := fmt.Sprintf("${PROJECT_NAME}-%d", time.Now().Unix())

	we, err := c.ExecuteWorkflow(context.Background(), client.StartWorkflowOptions{
		ID:        workflowID,
		TaskQueue: "${TASK_QUEUE}",
	}, wf.${PROJECT_NAME//-/}Workflow, act.ProcessInput{
		ID:   "item-1",
		Data: "sample data",
	})
	if err != nil {
		log.Fatalf("Failed to start workflow: %v", err)
	}

	fmt.Printf("Started workflow: %s (RunID: %s)\n", we.GetID(), we.GetRunID())

	var result string
	if err := we.Get(context.Background(), &result); err != nil {
		log.Fatalf("Workflow failed: %v", err)
	}
	fmt.Printf("Result: %s\n", result)
}
GOSTARTER

    # Workflow test
    cat > "$PROJECT_DIR/workflow/workflow_test.go" <<GOTEST
package workflow

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"go.temporal.io/sdk/testsuite"

	act "${GO_MODULE}/activity"
)

func TestWorkflow(t *testing.T) {
	testSuite := &testsuite.WorkflowTestSuite{}
	env := testSuite.NewTestWorkflowEnvironment()

	env.RegisterActivity(act.ValidateInput)
	env.RegisterActivity(act.ProcessData)
	env.RegisterActivity(act.SendNotification)

	env.OnActivity(act.ProcessData, mock.Anything, mock.Anything).Return(
		&act.ProcessResult{ID: "test-1", Status: "completed", ProcessedAt: "2024-01-01T00:00:00Z"}, nil,
	)

	env.ExecuteWorkflow(${PROJECT_NAME//-/}Workflow, act.ProcessInput{ID: "test-1", Data: "test data"})

	assert.True(t, env.IsWorkflowCompleted())
	assert.NoError(t, env.GetWorkflowError())

	var result string
	assert.NoError(t, env.GetWorkflowResult(&result))
	assert.Contains(t, result, "Processed test-1")
}
GOTEST

    # .gitignore
    cat > "$PROJECT_DIR/.gitignore" <<GITIGNORE
bin/
vendor/
*.exe
.env
GITIGNORE

    # README
    cat > "$PROJECT_DIR/README.md" <<README
# ${PROJECT_NAME}

Temporal workflow project (Go).

## Setup

\`\`\`bash
go mod tidy
temporal server start-dev  # In a separate terminal
\`\`\`

## Run

\`\`\`bash
go run worker/main.go   # Terminal 1: Start the worker
go run starter/main.go  # Terminal 2: Execute a workflow
\`\`\`

## Test

\`\`\`bash
go test ./workflow/...
\`\`\`

## Task Queue: \`${TASK_QUEUE}\`
README

    log_ok "Go project created at: $PROJECT_DIR"
    echo ""
    log_info "Next steps:"
    echo "  cd $PROJECT_DIR"
    echo "  go mod tidy"
    echo "  temporal server start-dev  # In another terminal"
    echo "  go run worker/main.go      # Start worker"
    echo "  go run starter/main.go     # Run workflow"
}

# Execute
case "$LANGUAGE" in
    typescript) scaffold_typescript ;;
    go)         scaffold_go ;;
esac
