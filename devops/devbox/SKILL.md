---
name: devbox
description: |
  Portable development environments with Nix. Use for reproducible dev setups.
  NOT for production deployments.
---

# Devbox

Portable, reproducible development environments powered by Nix. No Docker needed.

## Quick Start

```bash
# Install Devbox
curl -fsSL https://get.jetify.com/devbox | bash

# Initialize project
devbox init

# Add packages
devbox add nodejs@20
devbox add go@1.22
devbox add postgresql

# Enter shell
devbox shell

# Run one-off command
devbox run -- node --version
```

## Core Concepts

| Concept | Purpose |
|---------|---------|
| `devbox.json` | Project configuration (packages, scripts, env) |
| `devbox.lock` | Lockfile for reproducible installs |
| `devbox shell` | Enter isolated dev environment |
| `devbox run` | Execute commands in devbox context |
| `devbox services` | Manage background services |

## devbox.json Reference

```json
{
  "packages": [],
  "env": {},
  "shell": {
    "init_hook": [],
    "scripts": {}
  },
  "include": []
}
```

### Packages

Add packages from Nixpkgs:

```bash
devbox add go@1.22
devbox add nodejs@20 python@3.11
devbox add ripgrep fd bat        # CLI tools
devbox rm nodejs                 # Remove package
```

Package formats in devbox.json:

```json
{
  "packages": [
    "go@1.22",
    "nodejs@latest"
  ]
}
```

Or with options:

```json
{
  "packages": {
    "go": "1.22",
    "busybox": {
      "version": "latest",
      "platforms": ["x86_64-linux", "aarch64-linux"]
    },
    "utm": {
      "version": "latest",
      "excluded_platforms": ["x86_64-linux"]
    }
  }
}
```

Platform options: `aarch64-darwin`, `aarch64-linux`, `x86_64-darwin`, `x86_64-linux`

### Flake Packages

```json
{
  "packages": [
    "github:nix-community/fenix#stable.toolchain",
    "github:nixos/nixpkgs/23.11#hello",
    "path:../my-flake#my-package"
  ]
}
```

### Environment Variables

```json
{
  "env": {
    "NODE_ENV": "development",
    "API_URL": "http://localhost:3000",
    "PROJECT_ROOT": "$PWD"
  }
}
```

Load from .env file:

```json
{
  "env_from": ".env"
}
```

### Shell Configuration

```json
{
  "shell": {
    "init_hook": [
      "export PS1='📦 devbox> '",
      "echo 'Dev environment ready!'",
      "source .env.local 2>/dev/null || true"
    ],
    "scripts": {
      "build": "npm run build",
      "test": ["npm run lint", "npm run test:unit"],
      "dev": "npm run dev",
      "db:migrate": "psql -f migrations/init.sql"
    }
  }
}
```

Run scripts:

```bash
devbox run build
devbox run test
devbox run dev
```

## Services

Devbox uses process-compose to manage services.

```bash
devbox services up              # Start all services (foreground TUI)
devbox services up -b           # Start in background
devbox services up postgresql   # Start specific service
devbox services stop            # Stop all services
devbox services ls              # List services and status
devbox services attach          # Attach to background services
```

### Custom Services

Create `process-compose.yml`:

```yaml
version: "0.5"

processes:
  api:
    command: npm run dev
    working_dir: $PWD
    availability:
      restart: "always"
    
  worker:
    command: npm run worker
    depends_on:
      api:
        condition: process_healthy
```

## Plugins

Auto-activated for supported packages:

| Package | Plugin Features |
|---------|-----------------|
| postgresql | Service, env vars, data dir |
| redis | Service, config |
| mysql/mariadb | Service, init scripts |
| nginx | Service, config templates |
| nodejs | npm/yarn setup |
| python | venv auto-activation |
| php | php-fpm service |

### Using Plugins

```bash
devbox add postgresql
devbox services up postgresql
devbox info postgresql        # Show plugin info
```

### Include Custom Plugins

```json
{
  "include": [
    "github:org/repo?dir=plugins/my-plugin",
    "path:./local-plugin.json",
    "plugin:nginx"
  ]
}
```

## CLI Commands

```bash
# Project setup
devbox init                     # Create devbox.json
devbox generate devcontainer    # VS Code devcontainer files
devbox generate dockerfile      # Generate Dockerfile

# Package management
devbox add <pkg>[@version]
devbox rm <pkg>
devbox search <query>           # Search nixpkgs

# Environment
devbox shell                    # Enter dev shell
devbox shell -- <cmd>           # Run single command
devbox run <script>             # Run devbox.json script
devbox run -- <cmd>             # Run arbitrary command

# Services
devbox services up [service]
devbox services stop [service]
devbox services ls

# Info
devbox info <pkg>               # Show package plugin info
devbox list                     # List installed packages
```

## Best Practices

### 1. Pin Package Versions

```json
{
  "packages": [
    "go@1.22.3",
    "nodejs@20.12.0",
    "postgresql@15.6"
  ]
}
```

### 2. Commit Lockfile

```bash
git add devbox.json devbox.lock
git commit -m "Add devbox environment"
```

### 3. Use Scripts for Common Tasks

```json
{
  "shell": {
    "scripts": {
      "setup": ["devbox services up -b", "npm install", "npm run db:migrate"],
      "dev": "npm run dev",
      "test": "npm test",
      "lint": "eslint .",
      "clean": "rm -rf node_modules dist"
    }
  }
}
```

### 4. Environment-Specific Config

```json
{
  "env": {
    "NODE_ENV": "development"
  },
  "shell": {
    "init_hook": [
      "[ -f .env.local ] && source .env.local"
    ]
  }
}
```

### 5. Platform-Specific Packages

```json
{
  "packages": {
    "darwin-helpers": {
      "version": "latest",
      "platforms": ["aarch64-darwin", "x86_64-darwin"]
    }
  }
}
```

## Examples by Stack

### Node.js Project

```json
{
  "packages": ["nodejs@20", "pnpm@latest"],
  "env": {
    "NODE_ENV": "development"
  },
  "shell": {
    "init_hook": ["pnpm install"],
    "scripts": {
      "dev": "pnpm dev",
      "build": "pnpm build",
      "test": "pnpm test"
    }
  }
}
```

### Go Project

```json
{
  "packages": ["go@1.22", "golangci-lint@latest"],
  "env": {
    "GOPATH": "$PWD/.go",
    "PATH": "$PWD/.go/bin:$PATH"
  },
  "shell": {
    "init_hook": ["go mod download"],
    "scripts": {
      "build": "go build -o bin/app ./cmd/app",
      "test": "go test ./...",
      "lint": "golangci-lint run"
    }
  }
}
```

### Python Project

```json
{
  "packages": ["python@3.11", "poetry@latest"],
  "shell": {
    "init_hook": [
      "poetry install",
      "poetry shell"
    ],
    "scripts": {
      "dev": "poetry run python main.py",
      "test": "poetry run pytest"
    }
  }
}
```

### Full-Stack with Database

```json
{
  "packages": [
    "nodejs@20",
    "postgresql@15",
    "redis@latest",
    "go@1.22"
  ],
  "env": {
    "DATABASE_URL": "postgres://localhost:5432/myapp",
    "REDIS_URL": "redis://localhost:6379"
  },
  "shell": {
    "init_hook": [
      "echo 'Run: devbox services up' to start postgres and redis"
    ],
    "scripts": {
      "setup": [
        "devbox services up -b",
        "createdb myapp || true",
        "npm install"
      ],
      "dev": "concurrently 'npm run dev' 'go run ./api'",
      "db:migrate": "psql $DATABASE_URL -f migrations/up.sql"
    }
  }
}
```

### Rust Project

```json
{
  "packages": ["rustup@latest", "libiconv@latest"],
  "env": {
    "PROJECT_DIR": "$PWD"
  },
  "shell": {
    "init_hook": [
      "rustup default stable",
      "cargo fetch"
    ],
    "scripts": {
      "build": "cargo build",
      "build-release": "cargo build --release",
      "test": "cargo test",
      "doc": "cargo doc --open"
    }
  }
}
```

## direnv Integration

Auto-activate when entering directory:

```bash
# Install direnv first
devbox generate direnv

# Or manually create .envrc
echo 'eval "$(devbox generate direnv --print-envrc)"' > .envrc
direnv allow
```

## Global Packages

```bash
devbox global add ripgrep fd bat fzf
devbox global shell            # Enter global shell
devbox global list             # List global packages
```

## Troubleshooting

**Slow first shell:** First `devbox shell` downloads Nix prerequisites. Subsequent shells are fast.

**Package not found:** Use `devbox search <name>` or check search.nixos.org for exact nixpkgs names.

**Lockfile conflicts:**
```bash
devbox update                  # Update all packages
devbox update go               # Update specific package
rm devbox.lock && devbox shell # Regenerate lockfile
```

**Service won't start:** Run `devbox services stop`, then `devbox services up` fresh. Check `devbox info <pkg>` for requirements.

## When NOT to Use Devbox

| Use Case | Better Alternative |
|----------|-------------------|
| Production deployments | Docker, NixOS, native packages |
| Multi-stage builds | Docker |
| System-wide services | systemd, launchd |
| GUI applications | Homebrew, native package managers |

## Comparison

| Tool | Devbox | Docker | Nix |
|------|--------|--------|-----|
| Startup time | Instant | Seconds | Minutes |
| Disk usage | Low | High | Medium |
| Learning curve | Low | Medium | High |
| Native performance | Yes | No | Yes |
| Reproducibility | High | High | Very High |

## Resources

- Search packages: https://search.nixos.org/packages
- Devbox docs: https://www.jetify.com/docs/devbox
- Examples: https://github.com/jetify-com/devbox/tree/main/examples
- Nixpkgs: https://github.com/NixOS/nixpkgs
