#!/usr/bin/env bash
# action-init.sh — Scaffold a custom GitHub Action (JavaScript or Docker).
#
# Usage:
#   ./action-init.sh <action-name> <type>
#
# Arguments:
#   action-name  Name of the action (used for directory and metadata)
#   type         Action type: "javascript" (or "js") | "docker" | "composite"
#
# Examples:
#   ./action-init.sh my-action javascript
#   ./action-init.sh deploy-helper docker
#   ./action-init.sh setup-env composite

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <action-name> <type>"
  echo ""
  echo "Types: javascript (js), docker, composite"
  echo ""
  echo "Examples:"
  echo "  $0 my-action javascript"
  echo "  $0 deploy-helper docker"
  echo "  $0 setup-env composite"
  exit 1
fi

ACTION_NAME="$1"
ACTION_TYPE="$2"
ACTION_DIR="$ACTION_NAME"

if [[ -d "$ACTION_DIR" ]]; then
  echo "⚠  Directory '${ACTION_DIR}' already exists. Aborting."
  exit 1
fi

case "$ACTION_TYPE" in
  javascript|js)
    mkdir -p "${ACTION_DIR}"/{src,__tests__,dist}

    # action.yml
    cat > "${ACTION_DIR}/action.yml" <<YAML
name: '${ACTION_NAME}'
description: 'TODO: Describe what this action does'
author: 'TODO: Your name or org'

inputs:
  token:
    description: 'GitHub token for API access'
    required: false
    default: \${{ github.token }}
  example-input:
    description: 'An example input parameter'
    required: true

outputs:
  result:
    description: 'The result of the action'

runs:
  using: 'node20'
  main: 'dist/index.js'

branding:
  icon: 'zap'
  color: 'blue'
YAML

    # package.json
    cat > "${ACTION_DIR}/package.json" <<JSON
{
  "name": "${ACTION_NAME}",
  "version": "1.0.0",
  "description": "GitHub Action: ${ACTION_NAME}",
  "main": "src/index.js",
  "scripts": {
    "build": "ncc build src/index.js -o dist --source-map --license licenses.txt",
    "test": "jest --coverage",
    "lint": "eslint src/ __tests__/",
    "all": "npm run lint && npm test && npm run build"
  },
  "dependencies": {
    "@actions/core": "^1.10.0",
    "@actions/github": "^6.0.0",
    "@actions/exec": "^1.1.1"
  },
  "devDependencies": {
    "@vercel/ncc": "^0.38.0",
    "jest": "^29.7.0"
  },
  "license": "MIT"
}
JSON

    # src/index.js
    cat > "${ACTION_DIR}/src/index.js" <<'JS'
const core = require('@actions/core');
const github = require('@actions/github');

async function run() {
  try {
    const exampleInput = core.getInput('example-input', { required: true });
    const token = core.getInput('token');

    core.info(`Running with input: ${exampleInput}`);

    const octokit = github.getOctokit(token);
    const { context } = github;

    core.debug(`Event: ${context.eventName}`);
    core.debug(`Repo: ${context.repo.owner}/${context.repo.repo}`);

    // TODO: Implement your action logic here

    core.setOutput('result', 'success');
    core.info('Action completed successfully');
  } catch (error) {
    core.setFailed(`Action failed: ${error.message}`);
  }
}

run();
JS

    # __tests__/index.test.js
    cat > "${ACTION_DIR}/__tests__/index.test.js" <<'JS'
const core = require('@actions/core');

// Mock @actions/core
jest.mock('@actions/core');

describe('action', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('should set output on success', async () => {
    core.getInput.mockReturnValue('test-value');

    // TODO: Import and test your action logic
    // const { run } = require('../src/index');
    // await run();

    // expect(core.setOutput).toHaveBeenCalledWith('result', 'success');
    expect(true).toBe(true); // Placeholder
  });

  it('should fail gracefully on error', async () => {
    core.getInput.mockImplementation(() => {
      throw new Error('Missing input');
    });

    // TODO: Test error handling
    expect(true).toBe(true); // Placeholder
  });
});
JS

    # .gitignore
    cat > "${ACTION_DIR}/.gitignore" <<'GITIGNORE'
node_modules/
*.log
.DS_Store
coverage/
# Do NOT ignore dist/ — it must be committed for actions
GITIGNORE

    # README.md
    cat > "${ACTION_DIR}/README.md" <<MD
# ${ACTION_NAME}

TODO: Describe what this action does.

## Inputs

| Input | Description | Required | Default |
|---|---|---|---|
| \`token\` | GitHub token for API access | No | \`\${{ github.token }}\` |
| \`example-input\` | An example input parameter | Yes | — |

## Outputs

| Output | Description |
|---|---|
| \`result\` | The result of the action |

## Usage

\`\`\`yaml
- uses: your-org/${ACTION_NAME}@v1
  with:
    example-input: 'hello'
\`\`\`

## Development

\`\`\`bash
npm install
npm test
npm run build    # Compile to dist/ (must commit dist/)
\`\`\`
MD
    echo "✅ Created JavaScript action in '${ACTION_DIR}/'"
    echo "   Next: cd ${ACTION_DIR} && npm install && npm run build"
    ;;

  docker)
    mkdir -p "${ACTION_DIR}"/{src,__tests__}

    # action.yml
    cat > "${ACTION_DIR}/action.yml" <<YAML
name: '${ACTION_NAME}'
description: 'TODO: Describe what this action does'
author: 'TODO: Your name or org'

inputs:
  example-input:
    description: 'An example input parameter'
    required: true

outputs:
  result:
    description: 'The result of the action'

runs:
  using: 'docker'
  image: 'Dockerfile'
  args:
    - \${{ inputs.example-input }}

branding:
  icon: 'box'
  color: 'purple'
YAML

    # Dockerfile
    cat > "${ACTION_DIR}/Dockerfile" <<'DOCKERFILE'
FROM alpine:3.20

RUN apk add --no-cache bash curl jq

COPY src/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
DOCKERFILE

    # src/entrypoint.sh
    cat > "${ACTION_DIR}/src/entrypoint.sh" <<'BASH'
#!/bin/bash
set -euo pipefail

EXAMPLE_INPUT="$1"

echo "Running with input: ${EXAMPLE_INPUT}"

# TODO: Implement your action logic here

RESULT="success"
echo "result=${RESULT}" >> "$GITHUB_OUTPUT"
echo "Action completed successfully"
BASH
    chmod +x "${ACTION_DIR}/src/entrypoint.sh"

    # __tests__/test.sh
    cat > "${ACTION_DIR}/__tests__/test.sh" <<'BASH'
#!/bin/bash
set -euo pipefail

# Basic smoke test for the Docker action
echo "=== Testing entrypoint ==="

# Create a fake GITHUB_OUTPUT file
export GITHUB_OUTPUT=$(mktemp)

# Run the entrypoint
bash "$(dirname "$0")/../src/entrypoint.sh" "test-input"

# Verify output was set
if grep -q "result=success" "$GITHUB_OUTPUT"; then
  echo "✅ Test passed: output was set correctly"
else
  echo "❌ Test failed: expected 'result=success' in GITHUB_OUTPUT"
  cat "$GITHUB_OUTPUT"
  exit 1
fi

rm -f "$GITHUB_OUTPUT"
BASH
    chmod +x "${ACTION_DIR}/__tests__/test.sh"

    # README.md
    cat > "${ACTION_DIR}/README.md" <<MD
# ${ACTION_NAME}

TODO: Describe what this action does.

## Inputs

| Input | Description | Required |
|---|---|---|
| \`example-input\` | An example input parameter | Yes |

## Outputs

| Output | Description |
|---|---|
| \`result\` | The result of the action |

## Usage

\`\`\`yaml
- uses: your-org/${ACTION_NAME}@v1
  with:
    example-input: 'hello'
\`\`\`

## Development

\`\`\`bash
# Test locally
bash __tests__/test.sh

# Build and test Docker image
docker build -t ${ACTION_NAME} .
docker run --rm ${ACTION_NAME} "test-input"
\`\`\`
MD
    echo "✅ Created Docker action in '${ACTION_DIR}/'"
    echo "   Next: cd ${ACTION_DIR} && bash __tests__/test.sh"
    ;;

  composite)
    mkdir -p "${ACTION_DIR}"

    # action.yml
    cat > "${ACTION_DIR}/action.yml" <<YAML
name: '${ACTION_NAME}'
description: 'TODO: Describe what this composite action does'
author: 'TODO: Your name or org'

inputs:
  example-input:
    description: 'An example input parameter'
    required: true
  optional-input:
    description: 'An optional parameter'
    required: false
    default: 'default-value'

outputs:
  result:
    description: 'The result of the action'
    value: \${{ steps.run.outputs.result }}

runs:
  using: 'composite'
  steps:
    - name: Validate inputs
      run: |
        if [[ -z "\${{ inputs.example-input }}" ]]; then
          echo "::error::example-input is required"
          exit 1
        fi
      shell: bash

    - name: Run main logic
      id: run
      run: |
        echo "Running with: \${{ inputs.example-input }}"
        echo "Optional: \${{ inputs.optional-input }}"
        # TODO: Implement your action logic
        echo "result=success" >> "\$GITHUB_OUTPUT"
      shell: bash
YAML

    # README.md
    cat > "${ACTION_DIR}/README.md" <<MD
# ${ACTION_NAME}

TODO: Describe what this composite action does.

## Inputs

| Input | Description | Required | Default |
|---|---|---|---|
| \`example-input\` | An example input parameter | Yes | — |
| \`optional-input\` | An optional parameter | No | \`default-value\` |

## Outputs

| Output | Description |
|---|---|
| \`result\` | The result of the action |

## Usage

\`\`\`yaml
- uses: your-org/${ACTION_NAME}@v1
  with:
    example-input: 'hello'
\`\`\`
MD
    echo "✅ Created composite action in '${ACTION_DIR}/'"
    ;;

  *)
    echo "❌ Unknown action type: '${ACTION_TYPE}'"
    echo "   Valid types: javascript (js), docker, composite"
    exit 1
    ;;
esac
