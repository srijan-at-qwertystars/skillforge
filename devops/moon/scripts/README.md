# Moon Build System Scripts

This directory contains helper scripts for working with Moon build system.

## Available Scripts

### moon-init.sh
Initialize a new Moon workspace with sensible defaults and shared task templates.

```bash
./moon-init.sh
```

Creates:
- `.moon/workspace.yml` - Workspace configuration
- `.moonignore` - Ignore patterns
- `.moon/tasks/node.yml` - Shared Node.js tasks
- `.moon/tasks/rust.yml` - Shared Rust tasks
- `.moon/tasks/go.yml` - Shared Go tasks

### moon-ci.sh
CI-optimized Moon runner with common patterns.

```bash
./moon-ci.sh                    # Run affected tasks against origin/main
./moon-ci.sh --base HEAD~1      # Run against specific base
./moon-ci.sh --all              # Run all tasks (not just affected)
./moon-ci.sh --remote-cache     # Enable remote caching
```

### moon-affected.sh
Show affected projects and tasks based on changes.

```bash
./moon-affected.sh              # Show affected against origin/main
./moon-affected.sh --base HEAD~5 # Show affected against specific commit
```

### moon-clean.sh
Clean Moon cache and build artifacts.

```bash
./moon-clean.sh                 # Clean everything (cache + outputs)
./moon-clean.sh --cache         # Clean only cache
./moon-clean.sh --outputs       # Clean only build outputs
```

### moon-docker.sh
Docker scaffolding helpers for Moon projects.

```bash
./moon-docker.sh -p web --scaffold   # Scaffold Docker files
./moon-docker.sh -p api --file       # Generate Dockerfile
./moon-docker.sh --prune             # Prune for production
```

### moon-debug.sh
Debug Moon task execution and caching.

```bash
./moon-debug.sh -t web:build --hash   # Show hash debug info
./moon-debug.sh --graph               # Show dependency graph
./moon-debug.sh -t web:build          # Show project and task info
```

## Usage

Copy these scripts to your project or use them as reference for creating your own Moon automation.

```bash
# Copy to your project
cp /path/to/skillforge/devops/moon/scripts/*.sh ./scripts/
chmod +x ./scripts/*.sh
```
