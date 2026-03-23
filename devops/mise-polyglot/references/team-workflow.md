# Mise Team Workflow Reference

<!-- TOC -->
- [Adopting Mise in a Repository](#adopting-mise-in-a-repository)
  - [Adding .mise.toml](#adding-misetoml)
  - [What to Commit](#what-to-commit)
  - [Monorepo Layout](#monorepo-layout)
- [Onboarding Developers](#onboarding-developers)
  - [Quick Start for New Developers](#quick-start-for-new-developers)
  - [Setup Task Pattern](#setup-task-pattern)
  - [Documentation Template](#documentation-template)
- [CI/CD Setup](#cicd-setup)
  - [GitHub Actions with jdx/mise-action](#github-actions-with-jdxmise-action)
  - [GitHub Actions — Advanced](#github-actions--advanced)
  - [GitLab CI](#gitlab-ci)
  - [CircleCI](#circleci)
  - [Generic CI Script](#generic-ci-script)
- [Migration from asdf / .tool-versions](#migration-from-asdf--tool-versions)
  - [Zero-Change Migration](#zero-change-migration)
  - [Full Migration to .mise.toml](#full-migration-to-misetoml)
  - [Coexistence Strategy](#coexistence-strategy)
- [Migration from nvm / .nvmrc](#migration-from-nvm--nvmrc)
  - [Drop-in Replacement](#drop-in-replacement)
  - [Full Migration](#full-migration)
  - [Uninstalling nvm](#uninstalling-nvm)
- [Migration from pyenv / .python-version](#migration-from-pyenv--python-version)
  - [Drop-in Replacement](#drop-in-replacement-1)
  - [Full Migration](#full-migration-1)
  - [Virtual Environments](#virtual-environments)
- [Enforcing Tool Versions](#enforcing-tool-versions)
  - [Lockfile](#lockfile)
  - [min_version Guard](#min_version-guard)
  - [CI Version Check](#ci-version-check)
  - [Pre-commit Hook](#pre-commit-hook)
- [Docker Integration](#docker-integration)
  - [Basic Dockerfile](#basic-dockerfile)
  - [Multi-Stage Build](#multi-stage-build)
  - [Docker Compose](#docker-compose)
  - [Dev Containers](#dev-containers)
<!-- /TOC -->

---

## Adopting Mise in a Repository

### Adding .mise.toml

Start by creating a `.mise.toml` at the project root:

```sh
cd my-project
mise use node@20 python@3.12    # creates .mise.toml with pinned versions
```

Or create manually:

```toml
# .mise.toml
min_version = "2025.1.0"

[tools]
node = "20"
python = "3.12"

[env]
NODE_ENV = "development"

[tasks]
dev = "npm run dev"
test = "npm test"
lint = "npm run lint"
setup = "npm install && pip install -r requirements.txt"
```

### What to Commit

```gitignore
# .gitignore — add these lines
.mise.local.toml      # developer-specific overrides
mise.local.toml
```

**Commit**: `.mise.toml`, `mise.lock` (if using lockfile)
**Do NOT commit**: `.mise.local.toml` (personal overrides)

### Monorepo Layout

```
monorepo/
├── .mise.toml                    # root: shared tools and tasks
├── apps/
│   ├── frontend/
│   │   └── .mise.toml            # override node version, add frontend tasks
│   ├── backend/
│   │   └── .mise.toml            # add python, backend-specific env vars
│   └── mobile/
│       └── .mise.toml            # add java, android-specific tools
└── packages/
    └── shared/
        └── .mise.toml            # shared library tools
```

Child configs inherit from parents. A tool in `apps/frontend/.mise.toml` overrides the same tool in the root.

---

## Onboarding Developers

### Quick Start for New Developers

Include this in your project README:

```sh
# 1. Install mise (one-time)
curl https://mise.run | sh

# 2. Activate mise in your shell (add to ~/.bashrc, ~/.zshrc, or fish config)
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
source ~/.bashrc

# 3. Clone and set up the project
git clone https://github.com/org/project.git
cd project
mise install            # installs all tools from .mise.toml
mise run setup          # runs project setup task (if defined)
```

### Setup Task Pattern

Define a `setup` task for one-command project initialization:

```toml
[tasks.setup]
description = "Set up development environment"
run = """
echo '📦 Installing dependencies...'
npm install
pip install -r requirements.txt

echo '🗄️ Setting up database...'
createdb devdb 2>/dev/null || true
python manage.py migrate

echo '✅ Setup complete! Run: mise run dev'
"""
```

### Documentation Template

Add to your project's `CONTRIBUTING.md`:

```markdown
## Development Setup

This project uses [mise](https://mise.jdx.dev) to manage tool versions.

### Prerequisites
- Install mise: `curl https://mise.run | sh`
- Activate in shell: `eval "$(mise activate bash)"` (add to shell rc)

### Getting Started
git clone <repo-url> && cd <project>
mise install          # installs Node 20, Python 3.12, etc.
mise run setup        # installs deps, sets up database
mise run dev          # starts dev server

### Available Tasks
Run `mise tasks` to see all available tasks.
```

---

## CI/CD Setup

### GitHub Actions with jdx/mise-action

Basic setup — reads `.mise.toml` from the repo:

```yaml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
        with:
          install: true        # run mise install
          cache: true          # cache tool installations
      - run: mise run lint
      - run: mise run test
      - run: mise run build
```

### GitHub Actions — Advanced

Matrix builds, mise environments, and artifact caching:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node: ["20", "22"]
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
        with:
          mise_toml: |
            [tools]
            node = "${{ matrix.node }}"
            python = "3.12"
          cache: true
      - run: mise run test

  deploy:
    needs: test
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    environment: production
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
        with:
          install: true
          cache: true
      - run: MISE_ENV=production mise run deploy
```

### GitLab CI

```yaml
# .gitlab-ci.yml

.mise-setup: &mise-setup
  before_script:
    - curl https://mise.run | sh
    - eval "$(~/.local/bin/mise activate bash)"
    - mise install

stages:
  - test
  - build
  - deploy

test:
  stage: test
  image: ubuntu:22.04
  <<: *mise-setup
  script:
    - mise run test

build:
  stage: build
  image: ubuntu:22.04
  <<: *mise-setup
  script:
    - mise run build
  artifacts:
    paths:
      - dist/

deploy:
  stage: deploy
  image: ubuntu:22.04
  <<: *mise-setup
  script:
    - MISE_ENV=production mise run deploy
  only:
    - main
```

### CircleCI

```yaml
# .circleci/config.yml

version: 2.1

commands:
  setup-mise:
    steps:
      - run:
          name: Install mise
          command: |
            curl https://mise.run | sh
            echo 'eval "$(~/.local/bin/mise activate bash)"' >> "$BASH_ENV"
      - run:
          name: Install tools
          command: mise install

jobs:
  test:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - setup-mise
      - restore_cache:
          keys:
            - mise-{{ checksum ".mise.toml" }}
      - run: mise run test
      - save_cache:
          key: mise-{{ checksum ".mise.toml" }}
          paths:
            - ~/.local/share/mise

  build:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - setup-mise
      - run: mise run build

workflows:
  ci:
    jobs:
      - test
      - build:
          requires:
            - test
```

### Generic CI Script

For any CI system without a dedicated mise integration:

```sh
#!/usr/bin/env bash
# ci.sh — Generic CI script using mise
set -euo pipefail

# Install mise
curl https://mise.run | sh
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash)"

# Install tools from .mise.toml
mise install

# Run CI tasks
mise run lint
mise run test
mise run build
```

---

## Migration from asdf / .tool-versions

### Zero-Change Migration

Mise reads `.tool-versions` natively. No file changes needed:

```sh
# Just install mise and activate
curl https://mise.run | sh
eval "$(mise activate bash)"

# Your existing .tool-versions works immediately
mise install    # installs tools from .tool-versions
```

### Full Migration to .mise.toml

Convert `.tool-versions` to `.mise.toml`:

```sh
# .tool-versions (before)
# nodejs 20.11.0
# python 3.12.2
# ruby 3.3.0
# golang 1.22.0

# Equivalent .mise.toml (after)
cat > .mise.toml << 'EOF'
[tools]
node = "20.11.0"
python = "3.12.2"
ruby = "3.3.0"
go = "1.22.0"
EOF

# Remove old file
rm .tool-versions
```

**Tool name mapping** (asdf → mise):

| asdf plugin name | mise tool name |
|-----------------|----------------|
| `nodejs` | `node` |
| `golang` | `go` |
| `python` | `python` |
| `ruby` | `ruby` |
| `terraform` | `terraform` |
| `java` | `java` |
| `erlang` | `erlang` |

### Coexistence Strategy

During migration, keep both files temporarily:

```toml
# .mise.toml
[settings]
legacy_version_file = true    # read .tool-versions (default: true)

[tools]
node = "20"     # .mise.toml takes precedence when both define node
```

Gradual team migration:
1. Add `.mise.toml` alongside `.tool-versions`
2. Team members adopt mise at their own pace
3. Once everyone uses mise, remove `.tool-versions`

---

## Migration from nvm / .nvmrc

### Drop-in Replacement

Mise reads `.nvmrc` and `.node-version` files automatically:

```sh
# Existing .nvmrc
cat .nvmrc
# 20.11.0

# Mise reads it directly
curl https://mise.run | sh
eval "$(mise activate bash)"
mise install    # installs node 20.11.0 from .nvmrc
node --version  # v20.11.0
```

### Full Migration

```sh
# Convert .nvmrc to .mise.toml
node_version=$(cat .nvmrc)
mise use "node@${node_version}"    # creates .mise.toml
rm .nvmrc                          # remove legacy file
```

### Uninstalling nvm

After confirming mise works:

```sh
# Remove nvm from shell rc
# Delete these lines from ~/.bashrc or ~/.zshrc:
#   export NVM_DIR="$HOME/.nvm"
#   [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Remove nvm installation
rm -rf "$NVM_DIR"
```

---

## Migration from pyenv / .python-version

### Drop-in Replacement

Mise reads `.python-version` automatically:

```sh
# Existing .python-version
cat .python-version
# 3.12.2

# Mise reads it directly
mise install    # installs python 3.12.2
python --version
```

### Full Migration

```sh
# Convert to .mise.toml
python_version=$(cat .python-version)
mise use "python@${python_version}"
rm .python-version
```

### Virtual Environments

Mise can manage Python virtualenvs alongside tool versions:

```toml
# .mise.toml
[tools]
python = "3.12"

[env]
# Auto-create and activate a venv
_.python.venv = { path = ".venv", create = true }
```

Or with manual venv management:

```toml
[tasks.venv]
description = "Create virtual environment"
run = "python -m venv .venv && .venv/bin/pip install -r requirements.txt"

[env]
_.path = [".venv/bin"]
VIRTUAL_ENV = "{{config_root}}/.venv"
```

---

## Enforcing Tool Versions

### Lockfile

`mise.lock` pins exact resolved versions for reproducibility:

```toml
# .mise.toml
[settings]
lockfile = true
```

The lockfile is auto-generated on `mise use` and should be committed:

```
# mise.lock (auto-generated, commit this)
[tools]
node = "20.11.1"
python = "3.12.2"
```

### min_version Guard

Ensure team members have a recent enough mise:

```toml
# .mise.toml
min_version = "2025.1.0"    # error if mise is older than this
```

### CI Version Check

```yaml
# In CI, verify mise version
- run: |
    MISE_VERSION=$(mise --version | awk '{print $1}')
    echo "mise version: $MISE_VERSION"
    mise install --check    # verify versions match .mise.toml
```

### Pre-commit Hook

```bash
#!/usr/bin/env bash
# .git/hooks/pre-commit
# Ensure tool versions are installed

if command -v mise &>/dev/null; then
  if ! mise ls --missing --quiet | grep -q '^$'; then
    echo "⚠️  Missing tools. Run: mise install"
    mise ls --missing
    exit 1
  fi
fi
```

---

## Docker Integration

### Basic Dockerfile

```dockerfile
FROM ubuntu:22.04

# Install mise
RUN apt-get update && apt-get install -y curl git && \
    curl https://mise.run | sh && \
    echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc

# Copy config and install tools
COPY .mise.toml .
RUN ~/.local/bin/mise install

# Set up PATH for non-interactive shells
ENV PATH="/root/.local/share/mise/shims:$PATH"

COPY . .
RUN mise run build

CMD ["mise", "run", "start"]
```

### Multi-Stage Build

```dockerfile
# Stage 1: Install tools with mise
FROM ubuntu:22.04 AS builder

RUN apt-get update && apt-get install -y curl git
RUN curl https://mise.run | sh

COPY .mise.toml mise.lock ./
RUN ~/.local/bin/mise install

ENV PATH="/root/.local/share/mise/shims:$PATH"

COPY . .
RUN mise run build

# Stage 2: Runtime (no mise needed)
FROM ubuntu:22.04
COPY --from=builder /app/dist /app/dist
CMD ["/app/dist/server"]
```

### Docker Compose

```yaml
# docker-compose.yml
services:
  app:
    build: .
    volumes:
      - .:/app
      - mise-data:/root/.local/share/mise    # persist tool installs
    environment:
      - MISE_ENV=development
    command: mise run dev

volumes:
  mise-data:
```

### Dev Containers

```json
// .devcontainer/devcontainer.json
{
  "name": "Project Dev Container",
  "image": "ubuntu:22.04",
  "features": {},
  "postCreateCommand": "curl https://mise.run | sh && echo 'eval \"$(~/.local/bin/mise activate bash)\"' >> ~/.bashrc && ~/.local/bin/mise install",
  "customizations": {
    "vscode": {
      "extensions": ["jdx.mise-vscode"]
    }
  },
  "remoteEnv": {
    "PATH": "/root/.local/share/mise/shims:${containerEnv:PATH}"
  }
}
```
