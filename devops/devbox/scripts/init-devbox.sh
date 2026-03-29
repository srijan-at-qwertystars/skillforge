#!/bin/bash
# Devbox Project Initializer
# Usage: ./init-devbox.sh [project-type]
# project-type: nodejs|go|python|rust|elixir|fullstack

set -euo pipefail

PROJECT_TYPE="${1:-generic}"
PROJECT_NAME=$(basename "$PWD")

echo "🚀 Initializing Devbox for $PROJECT_TYPE project: $PROJECT_NAME"

# Initialize devbox if not exists
if [ ! -f "devbox.json" ]; then
    devbox init
fi

case "$PROJECT_TYPE" in
    nodejs|node|js)
        echo "📦 Setting up Node.js project..."
        devbox add nodejs@20 pnpm@latest
        cat > devbox.json << 'EOF'
{
  "packages": ["nodejs@20", "pnpm@latest"],
  "env": {
    "NODE_ENV": "development"
  },
  "shell": {
    "init_hook": [
      "[ -f package.json ] || echo '{}' > package.json",
      "pnpm install"
    ],
    "scripts": {
      "dev": "pnpm dev",
      "build": "pnpm build",
      "test": "pnpm test",
      "lint": "pnpm lint"
    }
  }
}
EOF
        ;;

    go|golang)
        echo "🐹 Setting up Go project..."
        devbox add go@1.22 golangci-lint@latest
        cat > devbox.json << 'EOF'
{
  "packages": ["go@1.22", "golangci-lint@latest"],
  "env": {
    "GOPATH": "$PWD/.go",
    "PATH": "$PWD/.go/bin:$PATH"
  },
  "shell": {
    "init_hook": [
      "[ -f go.mod ] || go mod init",
      "go mod download"
    ],
    "scripts": {
      "build": "go build -o bin/app ./cmd/app",
      "test": "go test ./...",
      "lint": "golangci-lint run",
      "dev": "go run ./cmd/app"
    }
  }
}
EOF
        ;;

    python|py)
        echo "🐍 Setting up Python project..."
        devbox add python@3.11 poetry@latest
        cat > devbox.json << 'EOF'
{
  "packages": ["python@3.11", "poetry@latest"],
  "shell": {
    "init_hook": [
      "[ -f pyproject.toml ] || poetry init --no-interaction",
      "poetry install"
    ],
    "scripts": {
      "dev": "poetry run python main.py",
      "test": "poetry run pytest",
      "lint": "poetry run ruff check ."
    }
  }
}
EOF
        ;;

    rust|rs)
        echo "🦀 Setting up Rust project..."
        devbox add rustup@latest libiconv@latest
        cat > devbox.json << 'EOF'
{
  "packages": ["rustup@latest", "libiconv@latest"],
  "shell": {
    "init_hook": [
      "rustup default stable",
      "[ -f Cargo.toml ] || cargo init",
      "cargo fetch"
    ],
    "scripts": {
      "build": "cargo build",
      "build-release": "cargo build --release",
      "test": "cargo test",
      "dev": "cargo run",
      "doc": "cargo doc --open"
    }
  }
}
EOF
        ;;

    elixir|ex)
        echo "💧 Setting up Elixir project..."
        devbox add elixir@latest postgresql@15
        cat > devbox.json << 'EOF'
{
  "packages": ["elixir@latest", "postgresql@15"],
  "env": {
    "DATABASE_URL": "postgres://localhost:5432/dev"
  },
  "shell": {
    "init_hook": [
      "[ -f mix.exs ] || mix new . --app dev",
      "mix deps.get"
    ],
    "scripts": {
      "dev": "mix phx.server || mix run --no-halt",
      "test": "mix test",
      "setup": "devbox services up -b && mix ecto.setup"
    }
  }
}
EOF
        ;;

    fullstack)
        echo "🌐 Setting up Full-Stack project..."
        devbox add nodejs@20 go@1.22 postgresql@15 redis@latest
        cat > devbox.json << 'EOF'
{
  "packages": [
    "nodejs@20",
    "go@1.22",
    "postgresql@15",
    "redis@latest"
  ],
  "env": {
    "DATABASE_URL": "postgres://localhost:5432/app",
    "REDIS_URL": "redis://localhost:6379",
    "API_PORT": "8080",
    "FRONTEND_PORT": "3000"
  },
  "shell": {
    "init_hook": [
      "echo 'Run: devbox services up' to start postgres and redis"
    ],
    "scripts": {
      "setup": [
        "devbox services up -b",
        "createdb app 2>/dev/null || true",
        "npm install",
        "go mod download"
      ],
      "dev": "concurrently 'npm run dev' 'go run ./api'",
      "api": "go run ./api",
      "frontend": "npm run dev",
      "db:migrate": "psql $DATABASE_URL -f migrations/up.sql"
    }
  }
}
EOF
        ;;

    *)
        echo "⚙️ Setting up generic project..."
        cat > devbox.json << 'EOF'
{
  "packages": [],
  "env": {},
  "shell": {
    "init_hook": [
      "echo 'Devbox ready! Add packages with: devbox add <package>'"
    ],
    "scripts": {}
  }
}
EOF
        ;;
esac

echo "✅ Devbox configured for $PROJECT_TYPE"
echo ""
echo "Next steps:"
echo "  1. Run 'devbox shell' to enter the environment"
echo "  2. Run 'devbox run setup' to initialize services"
echo "  3. Run 'devbox run dev' to start development"
