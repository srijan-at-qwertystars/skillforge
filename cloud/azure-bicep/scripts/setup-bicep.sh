#!/usr/bin/env bash
# setup-bicep.sh — Install Bicep CLI, configure VS Code extension, initialize project structure
#
# Usage:
#   ./setup-bicep.sh                  # Full setup: install CLI + init project
#   ./setup-bicep.sh --install-only   # Only install Bicep CLI
#   ./setup-bicep.sh --init-only      # Only initialize project structure
#   ./setup-bicep.sh --dir ./myproj   # Init project in a specific directory
#
# Prerequisites: Azure CLI (az), bash 4+
# Supports: Linux, macOS, WSL

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

PROJECT_DIR="."
INSTALL_ONLY=false
INIT_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-only) INSTALL_ONLY=true; shift ;;
    --init-only)    INIT_ONLY=true; shift ;;
    --dir)          PROJECT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Install Bicep CLI ──────────────────────────────────────────────────────────
install_bicep() {
  info "Checking Azure CLI..."
  if ! command -v az &>/dev/null; then
    error "Azure CLI not found. Install from https://aka.ms/install-azure-cli"
    exit 1
  fi
  info "Azure CLI version: $(az version --query '"azure-cli"' -o tsv)"

  info "Installing/upgrading Bicep CLI via Azure CLI..."
  az bicep install 2>/dev/null || az bicep upgrade 2>/dev/null || true

  if az bicep version &>/dev/null; then
    info "Bicep CLI version: $(az bicep version 2>&1 | head -1)"
  else
    warn "az bicep not available, trying standalone install..."
    if [[ "$(uname)" == "Linux" ]]; then
      curl -Lo /tmp/bicep https://github.com/Azure/bicep/releases/latest/download/bicep-linux-x64
      chmod +x /tmp/bicep
      sudo mv /tmp/bicep /usr/local/bin/bicep
    elif [[ "$(uname)" == "Darwin" ]]; then
      brew install azure/bicep/bicep 2>/dev/null || {
        curl -Lo /tmp/bicep https://github.com/Azure/bicep/releases/latest/download/bicep-osx-x64
        chmod +x /tmp/bicep
        sudo mv /tmp/bicep /usr/local/bin/bicep
      }
    fi
    info "Standalone Bicep version: $(bicep --version 2>&1 | head -1)"
  fi
}

# ── Configure VS Code Extension ───────────────────────────────────────────────
configure_vscode() {
  if command -v code &>/dev/null; then
    info "Installing VS Code Bicep extension..."
    code --install-extension ms-azuretools.vscode-bicep --force 2>/dev/null || \
      warn "Could not install VS Code extension (VS Code may not be running)"
  else
    warn "VS Code CLI not found — install Bicep extension manually: ms-azuretools.vscode-bicep"
  fi
}

# ── Initialize Project Structure ──────────────────────────────────────────────
init_project() {
  local dir="$1"
  info "Initializing Bicep project in: $dir"

  mkdir -p "$dir"/{modules,parameters,tests,scripts,.github/workflows}

  # bicepconfig.json
  if [[ ! -f "$dir/bicepconfig.json" ]]; then
    cat > "$dir/bicepconfig.json" << 'BICEPCONFIG'
{
  "analyzers": {
    "core": {
      "enabled": true,
      "rules": {
        "no-unused-params": { "level": "warning" },
        "no-unused-vars": { "level": "warning" },
        "no-hardcoded-location": { "level": "error" },
        "prefer-interpolation": { "level": "warning" },
        "secure-parameter-default": { "level": "error" },
        "adminusername-should-not-be-literal": { "level": "error" },
        "no-hardcoded-env-urls": { "level": "warning" },
        "use-parent-property": { "level": "warning" },
        "outputs-should-not-contain-secrets": { "level": "error" },
        "use-recent-api-versions": { "level": "warning" },
        "use-resource-symbol-reference": { "level": "warning" }
      }
    }
  },
  "moduleAliases": {
    "br": {
      "public": {
        "registry": "mcr.microsoft.com",
        "modulePath": "bicep"
      }
    }
  }
}
BICEPCONFIG
    info "Created bicepconfig.json"
  fi

  # main.bicep stub
  if [[ ! -f "$dir/main.bicep" ]]; then
    cat > "$dir/main.bicep" << 'MAINBICEP'
metadata description = 'Main deployment template'
targetScope = 'resourceGroup'

@description('Environment name')
@allowed(['dev', 'staging', 'prod'])
param environment string

@description('Azure region')
param location string = resourceGroup().location

var tags = {
  environment: environment
  managedBy: 'bicep'
  lastDeployed: utcNow('yyyy-MM-dd')
}

// Add your modules and resources here
MAINBICEP
    info "Created main.bicep"
  fi

  # main.bicepparam stub
  if [[ ! -f "$dir/parameters/dev.bicepparam" ]]; then
    cat > "$dir/parameters/dev.bicepparam" << 'DEVPARAM'
using '../main.bicep'

param environment = 'dev'
DEVPARAM
    info "Created parameters/dev.bicepparam"
  fi

  # .gitignore additions
  if [[ ! -f "$dir/.gitignore" ]]; then
    cat > "$dir/.gitignore" << 'GITIGNORE'
# Bicep build output
*.json
!bicepconfig.json
!package.json

# Parameter files with secrets
parameters/*.secret.*

# VS Code
.vscode/settings.json
GITIGNORE
    info "Created .gitignore"
  fi

  info "Project structure initialized:"
  find "$dir" -maxdepth 2 -not -path '*/.git/*' | head -20 | sed "s|^$dir|.|"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  info "=== Azure Bicep Setup ==="

  if [[ "$INIT_ONLY" == false ]]; then
    install_bicep
    configure_vscode
  fi

  if [[ "$INSTALL_ONLY" == false ]]; then
    init_project "$PROJECT_DIR"
  fi

  info "=== Setup Complete ==="
  echo ""
  info "Next steps:"
  echo "  1. Edit main.bicep with your resources"
  echo "  2. Run: az bicep lint --file main.bicep"
  echo "  3. Run: az deployment group validate -g <rg> --template-file main.bicep"
  echo "  4. Run: az deployment group what-if -g <rg> --template-file main.bicep"
}

main
