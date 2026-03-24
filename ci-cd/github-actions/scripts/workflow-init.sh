#!/usr/bin/env bash
# workflow-init.sh — Scaffold a GitHub Actions CI workflow for a project.
#
# Usage:
#   ./workflow-init.sh [language/framework]
#
# If no argument is given, auto-detects the language/framework from project files.
# Generates .github/workflows/ci.yml with test, lint, and build steps.
#
# Examples:
#   ./workflow-init.sh              # Auto-detect
#   ./workflow-init.sh node         # Node.js / npm
#   ./workflow-init.sh python       # Python / pip
#   ./workflow-init.sh go           # Go
#   ./workflow-init.sh rust         # Rust / Cargo
#   ./workflow-init.sh java-maven   # Java with Maven
#   ./workflow-init.sh java-gradle  # Java with Gradle

set -euo pipefail

WORKFLOW_DIR=".github/workflows"
WORKFLOW_FILE="${WORKFLOW_DIR}/ci.yml"

detect_language() {
  if [[ -f "package.json" ]]; then
    echo "node"
  elif [[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]] || [[ -f "Pipfile" ]]; then
    echo "python"
  elif [[ -f "go.mod" ]]; then
    echo "go"
  elif [[ -f "Cargo.toml" ]]; then
    echo "rust"
  elif [[ -f "pom.xml" ]]; then
    echo "java-maven"
  elif [[ -f "build.gradle" ]] || [[ -f "build.gradle.kts" ]]; then
    echo "java-gradle"
  elif [[ -f "Gemfile" ]]; then
    echo "ruby"
  elif [[ -f "composer.json" ]]; then
    echo "php"
  elif [[ -f "*.csproj" ]] || [[ -f "*.sln" ]]; then
    echo "dotnet"
  else
    echo "unknown"
  fi
}

LANG="${1:-$(detect_language)}"

if [[ -f "$WORKFLOW_FILE" ]]; then
  echo "⚠  ${WORKFLOW_FILE} already exists. Aborting to avoid overwriting."
  echo "   Delete it first or rename it if you want to regenerate."
  exit 1
fi

mkdir -p "$WORKFLOW_DIR"

case "$LANG" in
  node|nodejs|javascript|typescript)
    PACKAGE_MANAGER="npm"
    if [[ -f "yarn.lock" ]]; then
      PACKAGE_MANAGER="yarn"
    elif [[ -f "pnpm-lock.yaml" ]]; then
      PACKAGE_MANAGER="pnpm"
    fi

    cat > "$WORKFLOW_FILE" <<'WORKFLOW'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node-version: [18, 20, 22]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node-version }}
          cache: 'PACKAGE_MANAGER'
      - run: INSTALL_CMD
      - run: npm run lint --if-present
      - run: npm test --if-present
      - run: npm run build --if-present
WORKFLOW

    sed -i "s/PACKAGE_MANAGER/${PACKAGE_MANAGER}/g" "$WORKFLOW_FILE"
    if [[ "$PACKAGE_MANAGER" == "yarn" ]]; then
      sed -i "s/INSTALL_CMD/yarn install --frozen-lockfile/" "$WORKFLOW_FILE"
    elif [[ "$PACKAGE_MANAGER" == "pnpm" ]]; then
      sed -i "s/INSTALL_CMD/corepack enable \&\& pnpm install --frozen-lockfile/" "$WORKFLOW_FILE"
    else
      sed -i "s/INSTALL_CMD/npm ci/" "$WORKFLOW_FILE"
    fi
    ;;

  python)
    cat > "$WORKFLOW_FILE" <<'WORKFLOW'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        python-version: ['3.10', '3.11', '3.12']
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}
          cache: 'pip'
      - run: pip install -r requirements.txt
      - run: pip install ruff pytest
      - run: ruff check .
      - run: pytest
WORKFLOW
    ;;

  go|golang)
    cat > "$WORKFLOW_FILE" <<'WORKFLOW'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
          cache: true
      - run: go vet ./...
      - run: go test -race -coverprofile=coverage.out ./...
      - run: go build ./...
WORKFLOW
    ;;

  rust)
    cat > "$WORKFLOW_FILE" <<'WORKFLOW'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy
      - uses: Swatinem/rust-cache@v2
      - run: cargo fmt --check
      - run: cargo clippy -- -D warnings
      - run: cargo test
      - run: cargo build --release
WORKFLOW
    ;;

  java-maven)
    cat > "$WORKFLOW_FILE" <<'WORKFLOW'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: '21'
          distribution: 'temurin'
          cache: 'maven'
      - run: mvn verify --batch-mode --no-transfer-progress
WORKFLOW
    ;;

  java-gradle)
    cat > "$WORKFLOW_FILE" <<'WORKFLOW'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: '21'
          distribution: 'temurin'
      - uses: gradle/actions/setup-gradle@v4
      - run: ./gradlew check
      - run: ./gradlew build
WORKFLOW
    ;;

  ruby)
    cat > "$WORKFLOW_FILE" <<'WORKFLOW'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: .ruby-version
          bundler-cache: true
      - run: bundle exec rubocop
      - run: bundle exec rspec
WORKFLOW
    ;;

  php)
    cat > "$WORKFLOW_FILE" <<'WORKFLOW'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          tools: composer
      - run: composer install --no-interaction --prefer-dist
      - run: composer run-script lint --no-interaction || true
      - run: composer run-script test --no-interaction
WORKFLOW
    ;;

  dotnet)
    cat > "$WORKFLOW_FILE" <<'WORKFLOW'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'
      - run: dotnet restore
      - run: dotnet build --no-restore
      - run: dotnet test --no-build --verbosity normal
WORKFLOW
    ;;

  *)
    cat > "$WORKFLOW_FILE" <<'WORKFLOW'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # TODO: Add setup, lint, test, and build steps for your project
      - run: echo "Add your CI steps here"
WORKFLOW
    echo "⚠  Could not detect language. Generated a skeleton workflow."
    echo "   Edit ${WORKFLOW_FILE} to add your project-specific steps."
    ;;
esac

echo "✅ Created ${WORKFLOW_FILE} for '${LANG}'"
echo "   Review and commit: git add ${WORKFLOW_FILE} && git commit -m 'ci: add CI workflow'"
