#!/usr/bin/env bash
# =============================================================================
# init-project.sh — Initialize a Pulumi project with best practices
# =============================================================================
#
# Usage:
#   ./init-project.sh --name my-infra [OPTIONS]
#
# Required:
#   --name NAME            Project name (must be alphanumeric with hyphens)
#
# Options:
#   --runtime RUNTIME      Language runtime: nodejs|python|go|dotnet (default: nodejs)
#   --backend BACKEND      State backend: cloud|s3|local|azure|gcs (default: cloud)
#   --stack STACK           Initial stack name (default: dev)
#   --secrets-provider SP  Secrets provider: passphrase|awskms|gcpkms|azurekeyvault
#                          (default: passphrase)
#   --dir DIR              Output directory (default: ./<NAME>)
#   -h, --help             Show this help message
#
# Examples:
#   ./init-project.sh --name my-app --runtime python --backend s3 --stack staging
#   ./init-project.sh --name web-infra --runtime nodejs --secrets-provider awskms
#
# Prerequisites:
#   - pulumi CLI installed (https://www.pulumi.com/docs/install/)
#   - git installed
#   - Runtime toolchain installed (node/npm, python/pip, go, dotnet)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "${CYAN}[STEP]${NC}  $*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROJECT_NAME=""
RUNTIME="nodejs"
BACKEND="cloud"
STACK="dev"
SECRETS_PROVIDER="passphrase"
OUTPUT_DIR=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    sed -n '2,/^# =====/p' "$0" | head -n -1 | sed 's/^# \?//'
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)             PROJECT_NAME="$2";       shift 2 ;;
        --runtime)          RUNTIME="$2";            shift 2 ;;
        --backend)          BACKEND="$2";            shift 2 ;;
        --stack)            STACK="$2";              shift 2 ;;
        --secrets-provider) SECRETS_PROVIDER="$2";   shift 2 ;;
        --dir)              OUTPUT_DIR="$2";         shift 2 ;;
        -h|--help)          usage ;;
        *)
            error "Unknown option: $1"
            echo "Run with --help for usage information."
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if [[ -z "$PROJECT_NAME" ]]; then
    error "--name is required."
    echo "Run with --help for usage information."
    exit 1
fi

if ! [[ "$PROJECT_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    error "Project name must start with a letter and contain only alphanumerics, hyphens, or underscores."
    exit 1
fi

VALID_RUNTIMES="nodejs python go dotnet"
if ! echo "$VALID_RUNTIMES" | grep -qw "$RUNTIME"; then
    error "Invalid runtime '$RUNTIME'. Must be one of: $VALID_RUNTIMES"
    exit 1
fi

VALID_BACKENDS="cloud s3 local azure gcs"
if ! echo "$VALID_BACKENDS" | grep -qw "$BACKEND"; then
    error "Invalid backend '$BACKEND'. Must be one of: $VALID_BACKENDS"
    exit 1
fi

VALID_SECRETS="passphrase awskms gcpkms azurekeyvault"
if ! echo "$VALID_SECRETS" | grep -qw "$SECRETS_PROVIDER"; then
    error "Invalid secrets-provider '$SECRETS_PROVIDER'. Must be one of: $VALID_SECRETS"
    exit 1
fi

# Default output dir to project name if not specified
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_NAME}"

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------
step "Checking prerequisites..."

if ! command -v pulumi &>/dev/null; then
    error "pulumi CLI is not installed. Install it from https://www.pulumi.com/docs/install/"
    exit 1
fi
success "pulumi CLI found: $(pulumi version)"

if ! command -v git &>/dev/null; then
    error "git is not installed."
    exit 1
fi
success "git found: $(git --version | head -1)"

# Check runtime-specific toolchain
case "$RUNTIME" in
    nodejs)
        if ! command -v node &>/dev/null; then
            error "node is not installed. Required for nodejs runtime."
            exit 1
        fi
        if ! command -v npm &>/dev/null; then
            error "npm is not installed. Required for nodejs runtime."
            exit 1
        fi
        success "Node.js found: $(node --version)"
        ;;
    python)
        if ! command -v python3 &>/dev/null; then
            error "python3 is not installed. Required for python runtime."
            exit 1
        fi
        success "Python found: $(python3 --version)"
        ;;
    go)
        if ! command -v go &>/dev/null; then
            error "go is not installed. Required for go runtime."
            exit 1
        fi
        success "Go found: $(go version)"
        ;;
    dotnet)
        if ! command -v dotnet &>/dev/null; then
            error "dotnet is not installed. Required for dotnet runtime."
            exit 1
        fi
        success ".NET found: $(dotnet --version)"
        ;;
esac

# ---------------------------------------------------------------------------
# Create project directory
# ---------------------------------------------------------------------------
step "Creating project directory: $OUTPUT_DIR"

if [[ -d "$OUTPUT_DIR" ]]; then
    error "Directory '$OUTPUT_DIR' already exists. Remove it or choose a different name."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"
PROJECT_ROOT="$(pwd)"

success "Created $PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Generate Pulumi.yaml
# ---------------------------------------------------------------------------
step "Generating Pulumi.yaml..."

# Map runtime to Pulumi runtime name
PULUMI_RUNTIME="$RUNTIME"
if [[ "$RUNTIME" == "nodejs" ]]; then
    PULUMI_RUNTIME="nodejs"
fi

cat > Pulumi.yaml <<EOF
name: ${PROJECT_NAME}
runtime:
  name: ${PULUMI_RUNTIME}
$(if [[ "$RUNTIME" == "nodejs" ]]; then echo "  options:
    typescript: true"; fi)
description: Infrastructure managed by Pulumi — ${PROJECT_NAME}
config:
  pulumi:tags:
    value:
      pulumi:template: ${PROJECT_NAME}
EOF

success "Created Pulumi.yaml"

# ---------------------------------------------------------------------------
# Generate stack config
# ---------------------------------------------------------------------------
step "Creating stack configuration: Pulumi.${STACK}.yaml"

cat > "Pulumi.${STACK}.yaml" <<EOF
# Stack-specific configuration for '${STACK}'
# Set values with: pulumi config set <key> <value> --stack ${STACK}
config: {}
EOF

success "Created Pulumi.${STACK}.yaml"

# ---------------------------------------------------------------------------
# Generate .gitignore
# ---------------------------------------------------------------------------
step "Creating .gitignore..."

cat > .gitignore <<'GITIGNORE'
# Pulumi
.pulumi/

# Node.js
node_modules/
dist/
*.js
*.js.map
*.d.ts
!jest.config.js
!eslint.config.js

# Python
__pycache__/
*.pyc
venv/
.venv/

# Go
bin/

# .NET
bin/
obj/

# IDE
.idea/
.vscode/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Environment
.env
.env.local
*.pem
GITIGNORE

success "Created .gitignore"

# ---------------------------------------------------------------------------
# Generate runtime-specific files
# ---------------------------------------------------------------------------
step "Generating runtime-specific project files..."

case "$RUNTIME" in
    nodejs)
        # tsconfig.json
        cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "strict": true,
    "outDir": "dist",
    "target": "es2020",
    "module": "commonjs",
    "moduleResolution": "node",
    "sourceMap": true,
    "experimentalDecorators": true,
    "declaration": true,
    "noFallthroughCasesInSwitch": true,
    "noImplicitReturns": true,
    "forceConsistentCasingInFileNames": true,
    "skipLibCheck": true
  },
  "include": ["**/*.ts"],
  "exclude": ["node_modules", "dist"]
}
EOF
        success "Created tsconfig.json"

        # package.json
        cat > package.json <<EOF
{
  "name": "${PROJECT_NAME}",
  "version": "0.1.0",
  "description": "Pulumi infrastructure — ${PROJECT_NAME}",
  "main": "index.ts",
  "scripts": {
    "build": "tsc",
    "preview": "pulumi preview",
    "up": "pulumi up",
    "destroy": "pulumi destroy"
  },
  "devDependencies": {
    "@types/node": "^20",
    "typescript": "^5"
  },
  "dependencies": {
    "@pulumi/pulumi": "^3"
  }
}
EOF
        success "Created package.json"

        # index.ts
        cat > index.ts <<'EOF'
import * as pulumi from "@pulumi/pulumi";

// Read stack-specific configuration
const config = new pulumi.Config();

// Export stack outputs
export const stackName = pulumi.getStack();
export const projectName = pulumi.getProject();
EOF
        success "Created index.ts"
        ;;

    python)
        # requirements.txt
        cat > requirements.txt <<'EOF'
pulumi>=3.0.0,<4.0.0
EOF
        success "Created requirements.txt"

        # Pulumi.yaml already sets runtime; create __main__.py
        cat > __main__.py <<'EOF'
"""Pulumi infrastructure program."""
import pulumi

# Read stack-specific configuration
config = pulumi.Config()

# Export stack outputs
pulumi.export("stack_name", pulumi.get_stack())
pulumi.export("project_name", pulumi.get_project())
EOF
        success "Created __main__.py"
        ;;

    go)
        # Initialize Go module
        cat > main.go <<EOF
package main

import (
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		// Read stack-specific configuration
		// conf := config.New(ctx, "")

		ctx.Export("stackName", pulumi.String(ctx.Stack()))
		ctx.Export("projectName", pulumi.String(ctx.Project()))
		return nil
	})
}
EOF
        success "Created main.go"
        ;;

    dotnet)
        cat > Program.cs <<'EOF'
using Pulumi;
using System.Collections.Generic;

return await Deployment.RunAsync(() =>
{
    // Read stack-specific configuration
    var config = new Config();

    return new Dictionary<string, object?>
    {
        ["stackName"] = Deployment.Instance.StackName,
        ["projectName"] = Deployment.Instance.ProjectName,
    };
});
EOF
        success "Created Program.cs"
        ;;
esac

# ---------------------------------------------------------------------------
# Initialize git repository
# ---------------------------------------------------------------------------
step "Initializing git repository..."

git init --quiet
git add -A
git commit --quiet -m "chore: initialize Pulumi project '${PROJECT_NAME}'"
success "Initialized git repository with initial commit"

# ---------------------------------------------------------------------------
# Configure state backend
# ---------------------------------------------------------------------------
step "Configuring state backend: ${BACKEND}..."

case "$BACKEND" in
    cloud)
        info "Using Pulumi Cloud backend (default). Ensure PULUMI_ACCESS_TOKEN is set."
        ;;
    s3)
        # Prompt or expect env var for bucket name
        S3_BUCKET="${PULUMI_BACKEND_S3_BUCKET:-}"
        if [[ -z "$S3_BUCKET" ]]; then
            warn "Set PULUMI_BACKEND_S3_BUCKET or run: pulumi login s3://<bucket-name>"
            warn "Skipping backend login — configure manually."
        else
            pulumi login "s3://${S3_BUCKET}" 2>/dev/null || warn "S3 backend login failed — configure manually."
        fi
        ;;
    local)
        mkdir -p .pulumi
        pulumi login --local 2>/dev/null || warn "Local backend login failed."
        success "Using local file backend (.pulumi/)"
        ;;
    azure)
        AZURE_CONTAINER="${PULUMI_BACKEND_AZURE_CONTAINER:-}"
        if [[ -z "$AZURE_CONTAINER" ]]; then
            warn "Set PULUMI_BACKEND_AZURE_CONTAINER or run: pulumi login azblob://<container>"
            warn "Skipping backend login — configure manually."
        else
            pulumi login "azblob://${AZURE_CONTAINER}" 2>/dev/null || warn "Azure backend login failed — configure manually."
        fi
        ;;
    gcs)
        GCS_BUCKET="${PULUMI_BACKEND_GCS_BUCKET:-}"
        if [[ -z "$GCS_BUCKET" ]]; then
            warn "Set PULUMI_BACKEND_GCS_BUCKET or run: pulumi login gs://<bucket>"
            warn "Skipping backend login — configure manually."
        else
            pulumi login "gs://${GCS_BUCKET}" 2>/dev/null || warn "GCS backend login failed — configure manually."
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Create initial stack
# ---------------------------------------------------------------------------
step "Creating initial stack '${STACK}' with secrets provider '${SECRETS_PROVIDER}'..."

SECRETS_FLAG=""
case "$SECRETS_PROVIDER" in
    passphrase)
        SECRETS_FLAG="--secrets-provider passphrase"
        if [[ -z "${PULUMI_CONFIG_PASSPHRASE:-}" && -z "${PULUMI_CONFIG_PASSPHRASE_FILE:-}" ]]; then
            warn "Set PULUMI_CONFIG_PASSPHRASE or PULUMI_CONFIG_PASSPHRASE_FILE for non-interactive use."
        fi
        ;;
    awskms)
        KMS_KEY="${PULUMI_SECRETS_KMS_KEY:-}"
        if [[ -z "$KMS_KEY" ]]; then
            warn "Set PULUMI_SECRETS_KMS_KEY (e.g., alias/pulumi-secrets or full ARN)."
            SECRETS_FLAG="--secrets-provider awskms://alias/pulumi-secrets"
        else
            SECRETS_FLAG="--secrets-provider awskms://${KMS_KEY}"
        fi
        ;;
    gcpkms)
        GCP_KEY="${PULUMI_SECRETS_GCP_KEY:-}"
        if [[ -z "$GCP_KEY" ]]; then
            warn "Set PULUMI_SECRETS_GCP_KEY (projects/P/locations/L/keyRings/R/cryptoKeys/K)."
            SECRETS_FLAG="--secrets-provider gcpkms://projects/PROJECT/locations/LOCATION/keyRings/RING/cryptoKeys/KEY"
        else
            SECRETS_FLAG="--secrets-provider gcpkms://${GCP_KEY}"
        fi
        ;;
    azurekeyvault)
        AZ_VAULT="${PULUMI_SECRETS_AZ_VAULT:-}"
        if [[ -z "$AZ_VAULT" ]]; then
            warn "Set PULUMI_SECRETS_AZ_VAULT (e.g., https://myvault.vault.azure.net/keys/mykey)."
            SECRETS_FLAG="--secrets-provider azurekeyvault://myvault.vault.azure.net/keys/mykey"
        else
            SECRETS_FLAG="--secrets-provider azurekeyvault://${AZ_VAULT}"
        fi
        ;;
esac

# shellcheck disable=SC2086
if pulumi stack init "$STACK" $SECRETS_FLAG 2>/dev/null; then
    success "Stack '${STACK}' created"
else
    warn "Stack '${STACK}' may already exist or backend is not configured. Configure manually."
fi

# ---------------------------------------------------------------------------
# Set common config values
# ---------------------------------------------------------------------------
step "Setting common config values..."

pulumi config set pulumi:tags '{"managed-by":"pulumi","project":"'"${PROJECT_NAME}"'"}' --stack "$STACK" 2>/dev/null || true
success "Common tags configured"

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------
step "Installing dependencies..."

case "$RUNTIME" in
    nodejs)
        npm install --quiet 2>/dev/null && success "npm dependencies installed" || warn "npm install failed — run manually."
        ;;
    python)
        if command -v python3 &>/dev/null; then
            python3 -m venv venv 2>/dev/null && success "Python venv created"
            # shellcheck disable=SC1091
            source venv/bin/activate 2>/dev/null || true
            pip install -q -r requirements.txt 2>/dev/null && success "pip dependencies installed" || warn "pip install failed — run manually."
        fi
        ;;
    go)
        go mod init "${PROJECT_NAME}" 2>/dev/null || true
        go mod tidy 2>/dev/null && success "Go modules tidied" || warn "go mod tidy failed — run manually."
        ;;
    dotnet)
        dotnet new console --force --no-restore 2>/dev/null || true
        dotnet add package Pulumi 2>/dev/null && success ".NET packages restored" || warn "dotnet restore failed — run manually."
        ;;
esac

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Project '${PROJECT_NAME}' initialized successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
info "Directory:        ${PROJECT_ROOT}"
info "Runtime:          ${RUNTIME}"
info "Backend:          ${BACKEND}"
info "Stack:            ${STACK}"
info "Secrets Provider: ${SECRETS_PROVIDER}"
echo ""
info "Next steps:"
echo "  cd ${OUTPUT_DIR}"
echo "  pulumi preview    # Preview changes"
echo "  pulumi up         # Deploy changes"
echo ""
