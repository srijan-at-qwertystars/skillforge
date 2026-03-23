#!/usr/bin/env bash
#
# init-dagger-project.sh — Initialize a Dagger project with SDK choice
#
# Usage:
#   ./init-dagger-project.sh [--sdk=go|python|typescript] [--name=module-name] [--dir=path]
#
# Options:
#   --sdk=SDK       SDK to use: go (default), python, typescript
#   --name=NAME     Module name (default: basename of target directory)
#   --dir=DIR       Target directory (default: current directory)
#   --help          Show this help message
#
# Examples:
#   ./init-dagger-project.sh --sdk=go --name=my-ci
#   ./init-dagger-project.sh --sdk=python --dir=./my-project
#   ./init-dagger-project.sh --sdk=typescript --name=web-ci --dir=./frontend
#
# Prerequisites:
#   - dagger CLI installed (https://docs.dagger.io/install)
#   - Docker or compatible container runtime running
#

set -euo pipefail

SDK="go"
MODULE_NAME=""
TARGET_DIR="."

usage() {
    sed -n '3,16p' "$0" | sed 's/^# \?//'
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --sdk=*)    SDK="${arg#*=}" ;;
        --name=*)   MODULE_NAME="${arg#*=}" ;;
        --dir=*)    TARGET_DIR="${arg#*=}" ;;
        --help|-h)  usage ;;
        *)          echo "Unknown option: $arg"; usage ;;
    esac
done

# Validate SDK choice
case "$SDK" in
    go|python|typescript) ;;
    ts) SDK="typescript" ;;
    py) SDK="python" ;;
    *)  echo "Error: Invalid SDK '$SDK'. Choose: go, python, typescript"; exit 1 ;;
esac

# Check prerequisites
if ! command -v dagger &>/dev/null; then
    echo "Error: dagger CLI not found. Install: https://docs.dagger.io/install"
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    echo "Warning: Docker does not appear to be running. Dagger requires a container runtime."
fi

# Create and enter target directory
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

if [ -z "$MODULE_NAME" ]; then
    MODULE_NAME="$(basename "$(pwd)")"
fi

echo "🚀 Initializing Dagger module '$MODULE_NAME' with $SDK SDK in $(pwd)"

# Initialize Dagger module
if [ -f "dagger.json" ]; then
    echo "⚠️  dagger.json already exists. Skipping dagger init."
else
    dagger init --sdk="$SDK" --name="$MODULE_NAME"
    echo "✅ Dagger module initialized"
fi

# Create project structure
mkdir -p ci scripts

# Create .daggerignore if it doesn't exist
if [ ! -f ".daggerignore" ]; then
    cat > .daggerignore <<'IGNORE'
.git
node_modules
vendor
.venv
__pycache__
dist
build
.next
coverage
*.tar.gz
IGNORE
    echo "✅ Created .daggerignore"
fi

# Create starter function based on SDK
case "$SDK" in
    go)
        MAIN_FILE="dagger/main.go"
        if [ -f "$MAIN_FILE" ]; then
            echo "ℹ️  $MAIN_FILE already exists — skipping starter function"
        else
            mkdir -p dagger
            cat > "$MAIN_FILE" <<'GOCODE'
package main

import (
	"context"
	"dagger/ci/internal/dagger"
)

type CI struct{}

// Build compiles the application and returns the binary.
func (m *CI) Build(ctx context.Context, src *dagger.Directory) *dagger.File {
	return dag.Container().
		From("golang:1.23-alpine").
		WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
		WithMountedCache("/root/.cache/go-build", dag.CacheVolume("gobuild")).
		WithMountedDirectory("/src", src).
		WithWorkdir("/src").
		WithEnvVariable("CGO_ENABLED", "0").
		WithExec([]string{"go", "build", "-o", "/app", "."}).
		File("/app")
}

// Test runs the test suite.
func (m *CI) Test(ctx context.Context, src *dagger.Directory) (string, error) {
	return dag.Container().
		From("golang:1.23-alpine").
		WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
		WithMountedDirectory("/src", src).
		WithWorkdir("/src").
		WithExec([]string{"go", "test", "./...", "-v"}).
		Stdout(ctx)
}

// Lint runs golangci-lint.
func (m *CI) Lint(ctx context.Context, src *dagger.Directory) (string, error) {
	return dag.Container().
		From("golangci/golangci-lint:v1.61-alpine").
		WithMountedDirectory("/src", src).
		WithWorkdir("/src").
		WithExec([]string{"golangci-lint", "run"}).
		Stdout(ctx)
}
GOCODE
            echo "✅ Created starter Go functions in $MAIN_FILE"
        fi
        ;;

    python)
        MAIN_FILE="dagger/src/__init__.py"
        if [ -f "$MAIN_FILE" ]; then
            echo "ℹ️  $MAIN_FILE already exists — skipping starter function"
        else
            mkdir -p dagger/src
            cat > "$MAIN_FILE" <<'PYCODE'
import dagger
from dagger import dag, function, object_type


@object_type
class CI:
    @function
    async def build(self, source: dagger.Directory) -> dagger.Container:
        """Build the application container."""
        return (
            dag.container()
            .from_("python:3.12-slim")
            .with_workdir("/app")
            .with_file("/app/requirements.txt", source.file("requirements.txt"))
            .with_mounted_cache("/root/.cache/pip", dag.cache_volume("pip"))
            .with_exec(["pip", "install", "-r", "requirements.txt"])
            .with_directory("/app", source)
        )

    @function
    async def test(self, source: dagger.Directory) -> str:
        """Run the test suite."""
        return await (
            dag.container()
            .from_("python:3.12-slim")
            .with_directory("/app", source)
            .with_workdir("/app")
            .with_mounted_cache("/root/.cache/pip", dag.cache_volume("pip"))
            .with_exec(["pip", "install", "-r", "requirements.txt"])
            .with_exec(["pytest", "-v"])
            .stdout()
        )

    @function
    async def lint(self, source: dagger.Directory) -> str:
        """Run linting with ruff."""
        return await (
            dag.container()
            .from_("python:3.12-slim")
            .with_directory("/app", source)
            .with_workdir("/app")
            .with_exec(["pip", "install", "ruff"])
            .with_exec(["ruff", "check", "."])
            .stdout()
        )
PYCODE
            echo "✅ Created starter Python functions in $MAIN_FILE"
        fi
        ;;

    typescript)
        MAIN_FILE="dagger/src/index.ts"
        if [ -f "$MAIN_FILE" ]; then
            echo "ℹ️  $MAIN_FILE already exists — skipping starter function"
        else
            mkdir -p dagger/src
            cat > "$MAIN_FILE" <<'TSCODE'
import { dag, Container, Directory, object, func } from "@dagger.io/dagger"

@object()
class CI {
  @func()
  build(source: Directory): Container {
    return dag
      .container()
      .from("node:20-slim")
      .withDirectory("/app", source)
      .withWorkdir("/app")
      .withMountedCache("/app/node_modules", dag.cacheVolume("node-modules"))
      .withExec(["npm", "ci"])
      .withExec(["npm", "run", "build"])
  }

  @func()
  async test(source: Directory): Promise<string> {
    return dag
      .container()
      .from("node:20-slim")
      .withDirectory("/app", source)
      .withWorkdir("/app")
      .withMountedCache("/app/node_modules", dag.cacheVolume("node-modules"))
      .withExec(["npm", "ci"])
      .withExec(["npm", "test"])
      .stdout()
  }

  @func()
  async lint(source: Directory): Promise<string> {
    return dag
      .container()
      .from("node:20-slim")
      .withDirectory("/app", source)
      .withWorkdir("/app")
      .withMountedCache("/app/node_modules", dag.cacheVolume("node-modules"))
      .withExec(["npm", "ci"])
      .withExec(["npx", "eslint", "."])
      .stdout()
  }
}
TSCODE
            echo "✅ Created starter TypeScript functions in $MAIN_FILE"
        fi
        ;;
esac

# Summary
echo ""
echo "📦 Project structure:"
find . -not -path './.git/*' -not -path './node_modules/*' -not -path './vendor/*' | head -30 | sed 's/^/   /'
echo ""
echo "🎉 Ready! Try:"
echo "   dagger functions            # List available functions"
echo "   dagger call build --src=.   # Run the build function"
echo "   dagger call test --src=.    # Run the test function"
