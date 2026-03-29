---
name: moon
description: |
  Rust-based build system for monorepos. Use for fast monorepo builds with smart caching.
  NOT for single-package projects. Replaces Turborepo/Nx for Rust-native performance.
---

# Moon Build System

## Quick Start

```bash
# Initialize workspace
moon init

# Run task across all projects
moon run :build

# Run task in specific project
moon run web:build

# Run affected tasks only
moon run :test --affected
```

## Workspace Setup

Create `.moon/workspace.yml` at repository root:

```yaml
# Required: Define projects
projects:
  # Manual mapping
  web: 'apps/web'
  api: 'apps/api'
  ui: 'packages/ui'
  
  # OR auto-discovery with globs
  globs:
    - 'apps/*'
    - 'packages/*'
  
  # OR combine both
  globs:
    - 'apps/*'
    - 'packages/*'
  sources:
    legacy: 'legacy/app'

# Optional: Default project for unscoped commands
defaultProject: 'web'

# Version control
vcs:
  client: 'git'
  provider: 'github'
  defaultBranch: 'main'
  hooks:
    pre-commit:
      - 'moon run :lint :format --affected --status=staged'
  sync: true  # Auto-sync hooks
```

**Output:**
```
✔ Created .moon/workspace.yml
✔ Created .moon/cache/
✔ Synced git hooks to .moon/hooks/
```

## Project Configuration (moon.yml)

Create `moon.yml` in each project directory:

```yaml
# Project metadata
id: 'custom-id'  # Override folder-based name
language: 'typescript'  # javascript | python | rust | go | bash
stack: 'frontend'     # frontend | backend | infrastructure
layer: 'application'  # application | library | tool | automation
tags: ['react', 'nextjs']

# Project dependencies
dependsOn:
  - 'ui'                    # Simple reference
  - id: 'api-client'        # With scope
    scope: 'production'       # production | development | build | peer

# Project-level env (all tasks inherit)
env:
  NODE_ENV: 'production'

# File groups for reuse
fileGroups:
  sources:
    - 'src/**/*'
    - 'types/**/*'
  tests:
    - 'tests/**/*'
    - '**/*.test.ts'
  configs:
    - '*.config.{js,ts}'
    - 'tsconfig.json'

# Tasks
tasks:
  # Basic task
  lint:
    command: 'eslint'
    args: ['--ext', '.ts,.tsx', 'src/']
    inputs:
      - '@group(sources)'
      - '.eslintrc.js'
    
  # Build with outputs (cached)
  build:
    command: 'vite build'
    inputs:
      - '@group(sources)'
      - 'vite.config.ts'
    outputs:
      - 'dist/'           # Folder output
      - 'build/**/*.js'   # Glob output
    deps:
      - 'ui:build'        # Depends on another project's task
      - '^:build'         # Depends on all deps' build tasks
    
  # Dev server (persistent)
  dev:
    command: 'vite dev'
    preset: 'server'       # Disables cache, streams output
    
  # Interactive task
  init:
    command: 'create-app'
    options:
      interactive: true
      
  # Internal task (not for CLI)
  prepare:
    command: 'setup-scripts'
    options:
      internal: true
```

## Task Dependencies

```yaml
tasks:
  build:
    deps:
      # Target format: project:task
      - 'ui:build'
      - 'utils:build'
      
      # Self-reference (same project)
      - 'codegen'
      
      # All dependencies' build tasks
      - '^:build'
      
      # With args/env override
      - target: 'api:build'
        args: ['--env', 'production']
        env:
          NODE_ENV: 'production'
        optional: true  # Skip if doesn't exist
```

**Dependency scopes (v2.1+):**
```yaml
tasks:
  build:
    deps:
      # Only depend on production deps' build
      - target: '^:build'
        scope: 'production'
      
      # Only depend on dev deps' install
      - target: '^:install'
        scope: 'development'
```

## Task Inheritance

Define shared tasks in `.moon/tasks/`:

```yaml
# .moon/tasks/node.yml - applies to all Node projects
tasks:
  install:
    command: 'npm install'
    inputs:
      - 'package.json'
      - 'package-lock.json'
    
  lint:
    command: 'eslint'
    args: ['--ext', '.js,.ts', '.']
    inputs:
      - 'src/**/*'
      - '.eslintrc.js'
    
  test:
    command: 'jest'
    inputs:
      - 'src/**/*'
      - '**/*.test.ts'
    options:
      affectedFiles: true  # Pass affected files as args
```

**Inheritance patterns:**
```yaml
# .moon/tasks/node-frontend.yml
tasks:
  build:
    extends: 'node:build'  # Extend and override
    args: '--mode production'
    
  # Merge strategies
  test:
    command: 'vitest'
    options:
      mergeArgs: 'replace'    # replace | append | prepend
      mergeInputs: 'append'   # replace | append
```

## Caching

### Local Cache

Cache stored in `.moon/cache/`:

```
.moon/cache/
├── hashes/          # Hash manifests (debug)
├── outputs/         # Tar.gz of task outputs
├── states/          # Task run state
└── locks/           # Parallel process locks
```

**Cache configuration:**
```yaml
# moon.yml - per task
tasks:
  build:
    options:
      cache: true              # Enable (default)
      cache: false             # Disable
      cache: 'local'           # Local only
      cache: 'remote'          # Remote only
      cacheKey: 'v2'           # Invalidate cache
      cacheLifetime: '1 day'   # Auto-expire
```

**Workspace cache settings:**
```yaml
# .moon/workspace.yml
hasher:
  walkStrategy: 'vcs'          # vcs (default) | glob
  optimization: 'accuracy'       # accuracy | performance
  warnOnMissingInputs: true
  ignorePatterns:
    - '**/*.png'
    - '**/*.md'

pipeline:
  autoCleanCache: true
  cacheLifetime: '7 days'
```

### Remote Cache

**Self-hosted (bazel-remote):**
```yaml
# .moon/workspace.yml
remote:
  host: 'grpc://cache.internal:9092'
  # OR: 'grpcs://cache.internal:9092' for TLS
  
  api: 'grpc'  # grpc (default) | http
  
  auth:
    token: 'CACHE_TOKEN'  # Env var with Bearer token
    headers:
      'X-Custom': 'value'
  
  cache:
    instanceName: 'my-repo'    # Partition key
    compression: 'zstd'        # none | zstd
    localReadOnly: true        # CI uploads, local only downloads
    verifyIntegrity: true
  
  # TLS
  tls:
    cert: 'certs/ca.pem'
    domain: 'cache.internal'
  
  # mTLS
  mtls:
    caCert: 'certs/ca.pem'
    clientCert: 'certs/client.pem'
    clientKey: 'certs/client.key'
    domain: 'cache.internal'
```

**Depot cloud cache:**
```yaml
remote:
  host: 'grpcs://cache.depot.dev'
  auth:
    token: 'DEPOT_TOKEN'
    headers:
      'X-Depot-Org': 'my-org'
```

**Start bazel-remote:**
```bash
bazel-remote \
  --dir /var/cache/moon \
  --max_size 100 \
  --storage_mode zstd \
  --grpc_address 0.0.0.0:9092
```

## Commands

```bash
# Run tasks
moon run web:build                    # Single task
moon run :build                       # All projects' build
moon run web:build api:lint           # Multiple tasks
moon run :build :test --affected      # Only affected

# Query
moon query projects --tag react       # Filter projects
moon query tasks web                  # List project tasks
moon query graph                      # Output dependency graph

# CI optimized
moon ci                               # Run affected in CI
moon ci --base origin/main            # Custom base

# Docker
moon docker scaffold web              # Scaffold for Docker
moon docker file web                  # Generate Dockerfile
moon docker prune                     # Clean for production

# Sync
moon sync projects                    # Sync all projects
moon sync codeowners                  # Generate CODEOWNERS

# Debug
moon check web                        # Validate config
moon project web                      # Show project info
moon task web:build                   # Show task config
```

## Tokens & Variables

```yaml
tasks:
  build:
    command: 'webpack'
    args:
      - '--config'
      - '@in(0)'           # First input file
      - '--output'
      - '@out(0)'          # First output
    inputs:
      - 'webpack.config.js'
      - '@group(sources)'  # File group reference
    env:
      ROOT: '$workspaceRoot'
      PROJECT: '$projectRoot'
      TARGET: '$target'
```

**Available tokens:**
- `$workspaceRoot` - Workspace root path
- `$projectRoot` - Project root path  
- `$projectSource` - Project source folder
- `$projectName` / `$projectAlias` - Project identifiers
- `$target` - Full target string
- `$taskName` - Task name
- `@in(index)` / `@out(index)` - Input/output by index
- `@group(name)` - File group expansion
- `@args` - All args passthrough

## Best Practices

### 1. Explicit Inputs (Avoid `**/*`)

```yaml
# BAD - triggers on node_modules changes
tasks:
  lint:
    inputs: ['**/*']

# GOOD
tasks:
  lint:
    inputs: ['src/**/*', '.eslintrc.js']
```

### 2. Define Outputs for Caching

```yaml
tasks:
  build:
    command: 'tsc'
    inputs: ['src/**/*']
    outputs: ['dist/']  # Required for cache!
```

### 3. Use Task Presets

```yaml
tasks:
  dev:
    command: 'next dev'
    preset: 'server'  # cache=false, persistent=true
  
  db:migrate:
    command: 'prisma migrate'
    preset: 'utility'  # interactive
```

### 4. Project Boundaries

```yaml
# .moon/workspace.yml
constraints:
  enforceLayerRelationships: true  # app -> lib OK, lib -> app FAIL
  tagRelationships:
    next: ['react']  # Next projects need React deps
```

### 5. Affected Files Optimization

```yaml
tasks:
  lint:
    command: 'eslint'
    options:
      affectedFiles: true  # Only lint changed files
```

### 6. CI Configuration

```yaml
# .moon/workspace.yml
pipeline:
  installDependencies: true
  autoCleanCache: true
  cacheLifetime: '24 hours'
```

```bash
moon ci --base origin/main
```

### 7. File Groups for Reuse

```yaml
# .moon/tasks/node.yml
fileGroups:
  sources: ['src/**/*', 'types/**/*']
  tests: ['tests/**/*', '**/*.test.ts']
  configs: ['*.config.{js,ts}']

# Use in moon.yml
tasks:
  lint:
    inputs: ['@group(sources)', '@group(configs)']
```

## Troubleshooting

```bash
MOON_DEBUG=true moon run web:build  # Debug hash
moon run web:build --force          # Force run
rm -rf .moon/cache/                 # Clear cache
```

## Migration from Turborepo

| Turborepo | Moon |
|-----------|------|
| `dependsOn: ["^build"]` | `deps: ['^:build']` |
| `outputs: ["dist/**"]` | `outputs: ['dist/']` |
| `pipeline` | `tasks` |
| Implicit command | Explicit `command` field |

Key differences: Moon uses `^:task` syntax, requires explicit `command`, supports task inheritance via `.moon/tasks/`, caching is automatic with `outputs` defined.
