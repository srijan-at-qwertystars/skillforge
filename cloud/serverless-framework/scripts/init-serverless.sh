#!/usr/bin/env bash
# =============================================================================
# init-serverless.sh — Scaffold a Serverless Framework v4 project
# =============================================================================
#
# Usage:
#   ./init-serverless.sh <project-name> [--runtime nodejs20.x|python3.12] [--org <org>]
#
# Creates a production-ready Serverless Framework v4 project with:
#   - TypeScript + esbuild (built-in v4 bundling)
#   - serverless-offline for local development
#   - Organized directory structure
#   - Sample handler, event, and test files
#   - .env support, .gitignore, tsconfig.json
#
# Examples:
#   ./init-serverless.sh my-api
#   ./init-serverless.sh my-api --runtime nodejs20.x --org acme
# =============================================================================

set -euo pipefail

# --- Defaults ---
RUNTIME="nodejs20.x"
ORG=""

# --- Parse arguments ---
PROJECT_NAME="${1:-}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime) RUNTIME="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Usage: $0 <project-name> [--runtime nodejs20.x|python3.12] [--org <org>]"
  exit 1
fi

if [[ -d "$PROJECT_NAME" ]]; then
  echo "Error: Directory '$PROJECT_NAME' already exists."
  exit 1
fi

echo "🚀 Creating Serverless Framework v4 project: $PROJECT_NAME"
echo "   Runtime: $RUNTIME"

# --- Create project structure ---
mkdir -p "$PROJECT_NAME"/{src/{handlers,utils,middleware},tests,events,config}
cd "$PROJECT_NAME"

# --- package.json ---
cat > package.json <<'PKGJSON'
{
  "name": "PROJECT_NAME_PLACEHOLDER",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "serverless offline start --stage dev --httpPort 3000",
    "deploy:dev": "serverless deploy --stage dev",
    "deploy:staging": "serverless deploy --stage staging",
    "deploy:prod": "serverless deploy --stage prod",
    "remove:dev": "serverless remove --stage dev",
    "logs": "serverless logs -f",
    "invoke": "serverless invoke local -f",
    "test": "jest --coverage",
    "lint": "eslint src/ --ext .ts",
    "typecheck": "tsc --noEmit"
  },
  "devDependencies": {
    "@types/aws-lambda": "^8.10.145",
    "@types/node": "^20.14.0",
    "jest": "^29.7.0",
    "ts-jest": "^29.2.0",
    "typescript": "^5.5.0",
    "serverless": "^4.0.0",
    "serverless-offline": "^14.0.0"
  }
}
PKGJSON
sed -i "s/PROJECT_NAME_PLACEHOLDER/$PROJECT_NAME/" package.json

# --- tsconfig.json ---
cat > tsconfig.json <<'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "lib": ["ES2022"],
    "moduleResolution": "node",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "./dist",
    "rootDir": "./src",
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"]
    }
  },
  "include": ["src/**/*.ts"],
  "exclude": ["node_modules", "dist", ".serverless", "tests"]
}
TSCONFIG

# --- jest.config.js ---
cat > jest.config.js <<'JEST'
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/tests'],
  testMatch: ['**/*.test.ts'],
  collectCoverageFrom: ['src/**/*.ts', '!src/**/*.d.ts'],
};
JEST

# --- serverless.yml ---
ORG_LINE=""
if [[ -n "$ORG" ]]; then
  ORG_LINE="org: $ORG"
fi

cat > serverless.yml <<SLESSYML
service: $PROJECT_NAME
frameworkVersion: '4'
$ORG_LINE

provider:
  name: aws
  runtime: $RUNTIME
  architecture: arm64
  stage: \${opt:stage, 'dev'}
  region: \${opt:region, 'us-east-1'}
  memorySize: 512
  timeout: 10
  environment:
    STAGE: \${sls:stage}
    LOG_LEVEL: \${param:logLevel}
  logRetentionInDays: 14
  tracing:
    lambda: true
  iam:
    role:
      statements:
        - Effect: Allow
          Action:
            - dynamodb:GetItem
            - dynamodb:PutItem
            - dynamodb:UpdateItem
            - dynamodb:DeleteItem
            - dynamodb:Query
            - dynamodb:Scan
          Resource:
            - !GetAtt MainTable.Arn
            - !Sub '\${MainTable.Arn}/index/*'

build:
  esbuild:
    bundle: true
    minify: true
    sourcemap:
      type: linked
      setNodeOptions: true
    external:
      - '@aws-sdk/*'

stages:
  default:
    params:
      tableName: \${self:service}-\${sls:stage}
      logLevel: info
  dev:
    params:
      logLevel: debug
  prod:
    params:
      logLevel: warn

functions:
  hello:
    handler: src/handlers/hello.handler
    events:
      - httpApi:
          path: /hello
          method: GET

  createItem:
    handler: src/handlers/items.create
    events:
      - httpApi:
          path: /items
          method: POST

  getItem:
    handler: src/handlers/items.get
    events:
      - httpApi:
          path: /items/{id}
          method: GET

plugins:
  - serverless-offline

package:
  individually: true
  patterns:
    - '!./**'
    - 'src/**'
    - '!src/**/*.test.*'

resources:
  Resources:
    MainTable:
      Type: AWS::DynamoDB::Table
      DeletionPolicy: Retain
      Properties:
        TableName: \${param:tableName}
        BillingMode: PAY_PER_REQUEST
        AttributeDefinitions:
          - { AttributeName: pk, AttributeType: S }
          - { AttributeName: sk, AttributeType: S }
        KeySchema:
          - { AttributeName: pk, KeyType: HASH }
          - { AttributeName: sk, KeyType: RANGE }
  Outputs:
    TableArn:
      Value: !GetAtt MainTable.Arn
    ApiUrl:
      Value: !Sub 'https://\${HttpApi}.execute-api.\${aws:region}.amazonaws.com'
SLESSYML

# --- Sample handlers ---
cat > src/handlers/hello.ts <<'HANDLER'
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';

export const handler = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      message: 'Hello from Serverless Framework v4!',
      stage: process.env.STAGE,
      timestamp: new Date().toISOString(),
    }),
  };
};
HANDLER

cat > src/handlers/items.ts <<'ITEMS'
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand, GetCommand } from '@aws-sdk/lib-dynamodb';

const client = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE_NAME ?? '';

const response = (statusCode: number, body: unknown): APIGatewayProxyResultV2 => ({
  statusCode,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

export const create = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  const body = JSON.parse(event.body ?? '{}');
  const id = crypto.randomUUID();
  const item = { pk: id, sk: 'ITEM', ...body, createdAt: new Date().toISOString() };

  await client.send(new PutCommand({ TableName: TABLE, Item: item }));
  return response(201, { id, ...item });
};

export const get = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  const id = event.pathParameters?.id;
  if (!id) return response(400, { error: 'Missing id parameter' });

  const result = await client.send(new GetCommand({ TableName: TABLE, Key: { pk: id, sk: 'ITEM' } }));
  if (!result.Item) return response(404, { error: 'Item not found' });

  return response(200, result.Item);
};
ITEMS

# --- Sample middleware ---
cat > src/middleware/error-handler.ts <<'MIDDLEWARE'
import type { APIGatewayProxyResultV2 } from 'aws-lambda';

export const withErrorHandler = (
  handler: (event: any) => Promise<APIGatewayProxyResultV2>
) => {
  return async (event: any): Promise<APIGatewayProxyResultV2> => {
    try {
      return await handler(event);
    } catch (error) {
      console.error('Unhandled error:', error);
      return {
        statusCode: 500,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ error: 'Internal server error' }),
      };
    }
  };
};
MIDDLEWARE

# --- Sample utility ---
cat > src/utils/logger.ts <<'LOGGER'
const LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3 } as const;
type LogLevel = keyof typeof LOG_LEVELS;

const currentLevel = (process.env.LOG_LEVEL ?? 'info') as LogLevel;

const shouldLog = (level: LogLevel): boolean =>
  LOG_LEVELS[level] >= LOG_LEVELS[currentLevel];

export const logger = {
  debug: (msg: string, data?: unknown) => shouldLog('debug') && console.debug(msg, data ?? ''),
  info: (msg: string, data?: unknown) => shouldLog('info') && console.info(msg, data ?? ''),
  warn: (msg: string, data?: unknown) => shouldLog('warn') && console.warn(msg, data ?? ''),
  error: (msg: string, data?: unknown) => shouldLog('error') && console.error(msg, data ?? ''),
};
LOGGER

# --- Sample test ---
cat > tests/hello.test.ts <<'TEST'
import { handler } from '../src/handlers/hello';

describe('hello handler', () => {
  it('returns 200 with message', async () => {
    const event = {} as any;
    const result = await handler(event);
    expect(result.statusCode).toBe(200);
    const body = JSON.parse(result.body as string);
    expect(body.message).toContain('Hello');
  });
});
TEST

# --- Sample event for local testing ---
cat > events/httpApi-get.json <<'EVENT'
{
  "version": "2.0",
  "routeKey": "GET /hello",
  "rawPath": "/hello",
  "rawQueryString": "",
  "headers": {
    "content-type": "application/json"
  },
  "requestContext": {
    "http": {
      "method": "GET",
      "path": "/hello"
    },
    "stage": "dev"
  },
  "isBase64Encoded": false
}
EVENT

# --- .env files ---
cat > .env <<'DOTENV'
# Shared environment variables (all stages)
DOTENV

cat > .env.dev <<'DOTENVDEV'
# Development environment variables
LOG_LEVEL=debug
DOTENVDEV

# --- .gitignore ---
cat > .gitignore <<'GITIGNORE'
node_modules/
.serverless/
.esbuild/
dist/
coverage/
.env.local
*.js.map
.DS_Store
GITIGNORE

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  npm install"
echo "  npm run dev          # Start local development"
echo "  npm run deploy:dev   # Deploy to AWS (dev stage)"
echo "  npm test             # Run tests"
