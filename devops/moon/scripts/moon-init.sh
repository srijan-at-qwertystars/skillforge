#!/bin/bash
# moon-init.sh - Initialize a new Moon workspace with sensible defaults

set -e

echo "🌙 Initializing Moon workspace..."

# Check if moon is installed
if ! command -v moon &> /dev/null; then
    echo "❌ moon is not installed. Install with:"
    echo "   curl -fsSL https://moonrepo.dev/install/moon.sh | bash"
    exit 1
fi

# Create .moon directory structure
mkdir -p .moon/tasks
mkdir -p .moon/cache

# Create workspace.yml
cat > .moon/workspace.yml << 'EOF'
# Moon Workspace Configuration
# https://moonrepo.dev/docs/config/workspace

# Project discovery
projects:
  globs:
    - 'apps/*'
    - 'packages/*'
    - 'tools/*'

# Version control settings
vcs:
  client: 'git'
  provider: 'github'
  defaultBranch: 'main'
  sync: true

# Pipeline settings
pipeline:
  installDependencies: true
  autoCleanCache: true
  cacheLifetime: '7 days'

# Hasher settings
hasher:
  walkStrategy: 'vcs'
  optimization: 'accuracy'
  warnOnMissingInputs: true
EOF

# Create .moonignore
cat > .moonignore << 'EOF'
# Moon ignore patterns
node_modules/
dist/
build/
*.log
.DS_Store
.env.local
.env.*.local
coverage/
.nyc_output/
EOF

# Create shared task templates
mkdir -p .moon/tasks

# Node.js tasks template
cat > .moon/tasks/node.yml << 'EOF'
# Shared Node.js tasks
# Apply with: extends: 'node' in your moon.yml

fileGroups:
  sources:
    - 'src/**/*'
    - 'types/**/*'
  tests:
    - 'tests/**/*'
    - '**/*.test.{ts,tsx,js,mjs}'
    - '**/*.spec.{ts,tsx,js,mjs}'
  configs:
    - '*.config.{js,ts,mjs}'
    - 'tsconfig*.json'
    - 'package.json'

tasks:
  install:
    command: 'npm install'
    inputs:
      - 'package.json'
      - 'package-lock.json'
    options:
      cache: false

  lint:
    command: 'eslint'
    args:
      - '--ext'
      - '.ts,.tsx,.js,.mjs'
      - '.'
    inputs:
      - '@group(sources)'
      - '@group(configs)'
    options:
      affectedFiles: true

  test:
    command: 'jest'
    args:
      - '--passWithNoTests'
    inputs:
      - '@group(sources)'
      - '@group(tests)'
    options:
      affectedFiles: true

  typecheck:
    command: 'tsc'
    args:
      - '--noEmit'
    inputs:
      - '@group(sources)'
      - 'tsconfig.json'
EOF

# Rust tasks template
cat > .moon/tasks/rust.yml << 'EOF'
# Shared Rust tasks
# Apply with: extends: 'rust' in your moon.yml

fileGroups:
  sources:
    - 'src/**/*.rs'
    - 'Cargo.toml'
  tests:
    - 'tests/**/*.rs'
    - '**/*_test.rs'
  configs:
    - 'Cargo.toml'
    - 'Cargo.lock'
    - 'rust-toolchain.toml'

tasks:
  build:
    command: 'cargo build'
    args:
      - '--release'
    inputs:
      - '@group(sources)'
      - '@group(configs)'
    outputs:
      - 'target/release/'

  test:
    command: 'cargo test'
    inputs:
      - '@group(sources)'
      - '@group(tests)'
      - '@group(configs)'

  lint:
    command: 'cargo clippy'
    args:
      - '--all-targets'
      - '--all-features'
      - '--'
      - '-D'
      - 'warnings'
    inputs:
      - '@group(sources)'
      - '@group(configs)'

  format:
    command: 'cargo fmt'
    args:
      - '--check'
    inputs:
      - '@group(sources)'
EOF

# Go tasks template
cat > .moon/tasks/go.yml << 'EOF'
# Shared Go tasks
# Apply with: extends: 'go' in your moon.yml

fileGroups:
  sources:
    - '**/*.go'
    - 'go.mod'
  tests:
    - '**/*_test.go'
  configs:
    - 'go.mod'
    - 'go.sum'

tasks:
  build:
    command: 'go build'
    args:
      - '-o'
      - 'bin/app'
      - './cmd/app'
    inputs:
      - '@group(sources)'
      - '@group(configs)'
    outputs:
      - 'bin/'

  test:
    command: 'go test'
    args:
      - '-v'
      - './...'
    inputs:
      - '@group(sources)'
      - '@group(tests)'
      - '@group(configs)'

  lint:
    command: 'golangci-lint'
    args:
      - 'run'
    inputs:
      - '@group(sources)'
      - '.golangci.yml'
EOF

echo "✅ Moon workspace initialized!"
echo ""
echo "Next steps:"
echo "  1. Create projects in apps/ or packages/ directories"
echo "  2. Add moon.yml to each project"
echo "  3. Run 'moon sync projects' to register projects"
echo "  4. Run 'moon run :build' to build all projects"
echo ""
echo "Documentation: https://moonrepo.dev/docs"
