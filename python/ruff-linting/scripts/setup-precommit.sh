#!/usr/bin/env bash
# setup-precommit.sh — Set up pre-commit hooks with ruff check and ruff format
#
# Usage:
#   ./setup-precommit.sh [project-dir]
#
# This script:
#   1. Installs pre-commit if not present
#   2. Creates/updates .pre-commit-config.yaml with Ruff hooks
#   3. Installs the pre-commit git hooks
#   4. Runs an initial check on all files
#
# Options:
#   --ruff-version VERSION   Pin specific Ruff version (default: latest)
#   --no-install              Generate config only, don't install hooks
#   --unsafe-fixes            Allow unsafe fixes in pre-commit
#   --dry-run                 Show what would be done without doing it
#
# Requirements: git, pip (or pipx)

set -euo pipefail

# ---- Parse arguments ----
RUFF_VERSION=""
NO_INSTALL=false
UNSAFE_FIXES=false
DRY_RUN=false
PROJECT_DIR="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ruff-version)
            RUFF_VERSION="$2"
            shift 2
            ;;
        --no-install)
            NO_INSTALL=true
            shift
            ;;
        --unsafe-fixes)
            UNSAFE_FIXES=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            PROJECT_DIR="$1"
            shift
            ;;
    esac
done

cd "$PROJECT_DIR"

echo "=== Ruff Pre-commit Setup ==="
echo "Directory: $(pwd)"
echo ""

# ---- Check prerequisites ----
if ! git rev-parse --git-dir &>/dev/null; then
    echo "ERROR: Not a git repository. Initialize with: git init"
    exit 1
fi

# ---- Determine Ruff version ----
if [[ -z "$RUFF_VERSION" ]]; then
    # Try to get latest version from installed ruff or default
    if command -v ruff &>/dev/null; then
        RUFF_VERSION="v$(ruff --version | awk '{print $2}')"
        echo "Using installed Ruff version: $RUFF_VERSION"
    else
        RUFF_VERSION="v0.11.12"
        echo "Using default Ruff version: $RUFF_VERSION"
    fi
fi

# ---- Build ruff args ----
RUFF_ARGS='["--fix", "--exit-non-zero-on-fix"]'
if $UNSAFE_FIXES; then
    RUFF_ARGS='["--fix", "--unsafe-fixes", "--exit-non-zero-on-fix"]'
fi

# ---- Generate .pre-commit-config.yaml ----
CONFIG_FILE=".pre-commit-config.yaml"
BACKUP=""

if [[ -f "$CONFIG_FILE" ]]; then
    # Check if Ruff hooks already exist
    if grep -q "ruff-pre-commit" "$CONFIG_FILE" 2>/dev/null; then
        echo "WARNING: Ruff hooks already exist in $CONFIG_FILE"
        echo "Updating version to $RUFF_VERSION..."
        if ! $DRY_RUN; then
            sed -i.bak "s|rev:.*# ruff|rev: $RUFF_VERSION  # ruff|" "$CONFIG_FILE" 2>/dev/null || true
            # Try more general pattern
            sed -i.bak "/ruff-pre-commit/{n;s/rev:.*/rev: $RUFF_VERSION/;}" "$CONFIG_FILE" 2>/dev/null || true
        fi
        echo "Updated. Run: pre-commit autoupdate"
    else
        # Append Ruff hooks to existing config
        echo "Appending Ruff hooks to existing $CONFIG_FILE..."
        BACKUP="${CONFIG_FILE}.backup.$(date +%s)"
        if ! $DRY_RUN; then
            cp "$CONFIG_FILE" "$BACKUP"
            cat >> "$CONFIG_FILE" << YAML

  # Ruff linter and formatter
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: $RUFF_VERSION
    hooks:
      - id: ruff
        args: $RUFF_ARGS
      - id: ruff-format
YAML
            echo "Backup saved: $BACKUP"
        fi
    fi
else
    echo "Creating $CONFIG_FILE..."
    if ! $DRY_RUN; then
        cat > "$CONFIG_FILE" << YAML
# Pre-commit configuration
# See https://pre-commit.com for more information
# See https://pre-commit.com/hooks.html for more hooks

repos:
  # Ruff: Python linter and formatter (replaces flake8, black, isort)
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: $RUFF_VERSION
    hooks:
      # Run linter first (with auto-fix)
      - id: ruff
        args: $RUFF_ARGS
      # Then run formatter (formats fixed code)
      - id: ruff-format

  # Optional: other useful hooks
  # - repo: https://github.com/pre-commit/pre-commit-hooks
  #   rev: v4.6.0
  #   hooks:
  #     - id: trailing-whitespace
  #     - id: end-of-file-fixer
  #     - id: check-yaml
  #     - id: check-added-large-files
  #     - id: check-merge-conflict
  #     - id: debug-statements
YAML
    fi
fi

if $DRY_RUN; then
    echo ""
    echo "[DRY RUN] Would create/update $CONFIG_FILE with:"
    echo "  - ruff-pre-commit rev: $RUFF_VERSION"
    echo "  - ruff hook args: $RUFF_ARGS"
    echo "  - ruff-format hook"
    echo ""
    echo "[DRY RUN] Would install pre-commit hooks"
    exit 0
fi

echo ""
echo "Generated $CONFIG_FILE"
echo ""

# ---- Install pre-commit ----
if $NO_INSTALL; then
    echo "Skipping hook installation (--no-install)"
    echo ""
    echo "To install manually:"
    echo "  pip install pre-commit"
    echo "  pre-commit install"
    echo "  pre-commit run --all-files"
    exit 0
fi

if ! command -v pre-commit &>/dev/null; then
    echo "Installing pre-commit..."
    if command -v pipx &>/dev/null; then
        pipx install pre-commit
    elif command -v pip &>/dev/null; then
        pip install pre-commit
    elif command -v uv &>/dev/null; then
        uv tool install pre-commit
    else
        echo "ERROR: Cannot install pre-commit. Install manually: pip install pre-commit"
        exit 1
    fi
fi

echo "Installing git hooks..."
pre-commit install

echo ""
echo "Running initial check on all files..."
pre-commit run --all-files || true

echo ""
echo "=== Setup complete ==="
echo ""
echo "Pre-commit hooks will now run on every 'git commit'."
echo ""
echo "Useful commands:"
echo "  pre-commit run --all-files     # Run on all files"
echo "  pre-commit run ruff            # Run only ruff linter"
echo "  pre-commit run ruff-format     # Run only ruff formatter"
echo "  pre-commit autoupdate          # Update hook versions"
echo "  git commit --no-verify         # Skip hooks (emergency only)"
