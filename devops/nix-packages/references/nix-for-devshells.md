# Nix for Development Shells

## Table of Contents

- [Core Concepts](#core-concepts)
- [Language-Specific Shells](#language-specific-shells)
  - [Node.js](#nodejs)
  - [Python](#python)
  - [Rust](#rust)
  - [Go](#go)
  - [Java / JVM](#java--jvm)
  - [C / C++](#c--c)
- [direnv Integration](#direnv-integration)
  - [Setup](#setup)
  - [.envrc Patterns](#envrc-patterns)
  - [nix-direnv for Performance](#nix-direnv-for-performance)
- [Team Workflows](#team-workflows)
  - [Sharing devShells Across Teams](#sharing-devshells-across-teams)
  - [Onboarding with Nix](#onboarding-with-nix)
- [Pinning Tool Versions](#pinning-tool-versions)
- [Multiple Project Environments](#multiple-project-environments)
- [Advanced Patterns](#advanced-patterns)

---

## Core Concepts

A devShell is a reproducible development environment. Every team member gets identical tool versions regardless of their OS or existing system packages.

```nix
# Minimal devShell in a flake
devShells.default = pkgs.mkShell {
  packages = [ ... ];          # Tools available in $PATH
  buildInputs = [ ... ];       # Libraries for compilation (adds to NIX_LDFLAGS, etc.)
  nativeBuildInputs = [ ... ]; # Build tools (compilers, pkg-config)
  shellHook = ''...'';         # Script run on shell entry
  # Any other attrs become environment variables:
  DATABASE_URL = "postgresql://localhost/dev";
};
```

Key differences:
- `packages` — puts things in PATH (preferred for CLIs)
- `buildInputs` — adds library paths for linking (for C deps)
- `nativeBuildInputs` — build-time tools that set up build hooks
- `inputsFrom` — inherit deps from other derivations

```nix
# inputsFrom: inherit all deps from your package into the devShell
devShells.default = pkgs.mkShell {
  inputsFrom = [ self.packages.${system}.default ];
  packages = [ pkgs.nixfmt-rfc-style pkgs.nil ];  # Extra dev tools
};
```

---

## Language-Specific Shells

### Node.js

```nix
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    nodejs_22            # Pin major version
    nodePackages.pnpm    # Or yarn, npm comes with nodejs
    nodePackages.typescript
    nodePackages.typescript-language-server
    nodePackages.prettier
  ];

  shellHook = ''
    export NODE_ENV=development
    # Use project-local node_modules/.bin
    export PATH="$PWD/node_modules/.bin:$PATH"
    echo "Node $(node --version) | pnpm $(pnpm --version)"
  '';
};
```

**With native modules (node-gyp):**
```nix
devShells.default = pkgs.mkShell {
  packages = with pkgs; [ nodejs_22 python3 ];  # python needed for node-gyp
  buildInputs = with pkgs; [ openssl ];
  nativeBuildInputs = with pkgs; [ pkg-config ];
  # node-gyp needs these to compile native addons
};
```

**Using corepack for pnpm/yarn version management:**
```nix
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    nodejs_22
    corepack_22   # Enables corepack-managed pnpm/yarn
  ];
  shellHook = ''
    corepack enable
  '';
};
```

### Python

```nix
# Option 1: System Python with Nix-provided packages
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    (python312.withPackages (ps: with ps; [
      requests flask sqlalchemy pytest
      black ruff mypy
      ipython jupyter
    ]))
    ruff              # CLI also available standalone
  ];
  shellHook = ''
    echo "Python $(python --version)"
  '';
};

# Option 2: Python + venv for pip-managed deps
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    python312
    python312Packages.pip
    python312Packages.virtualenv
    ruff
    pyright
  ];
  buildInputs = with pkgs; [
    openssl            # For packages with C extensions
    libffi
    zlib
  ];
  nativeBuildInputs = with pkgs; [ pkg-config ];

  shellHook = ''
    # Auto-create and activate venv
    if [ ! -d .venv ]; then
      python -m venv .venv
    fi
    source .venv/bin/activate
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.openssl pkgs.zlib ]}"
  '';

  # Needed for pip to compile native extensions
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc ];
};

# Option 3: Poetry project
devShells.default = pkgs.mkShell {
  packages = with pkgs; [ python312 poetry ruff pyright ];
  shellHook = ''
    poetry install --no-root 2>/dev/null
    source $(poetry env info --path)/bin/activate 2>/dev/null || true
  '';
};
```

### Rust

```nix
# Standard Rust from nixpkgs
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    cargo
    rustc
    rust-analyzer
    clippy
    rustfmt
    cargo-watch
    cargo-audit
    cargo-expand
  ];

  buildInputs = with pkgs; [
    openssl
    pkg-config
  ] ++ lib.optionals stdenv.isDarwin [
    darwin.apple_sdk.frameworks.Security
    darwin.apple_sdk.frameworks.SystemConfiguration
  ];

  RUST_SRC_PATH = "${pkgs.rust.packages.stable.rustPlatform.rustLibSrc}";
  RUST_BACKTRACE = "1";

  shellHook = ''
    echo "Rust $(rustc --version)"
  '';
};

# Using rust-overlay for nightly or specific versions
# inputs.rust-overlay.url = "github:oxalica/rust-overlay";
devShells.default = let
  rust = pkgs.rust-bin.stable.latest.default.override {
    extensions = [ "rust-src" "rust-analyzer" ];
    targets = [ "wasm32-unknown-unknown" ];
  };
in pkgs.mkShell {
  packages = [ rust ];
};
```

### Go

```nix
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    go_1_22             # Pin Go version
    gopls               # Language server
    gotools             # goimports, godoc, etc.
    go-tools            # staticcheck
    delve               # Debugger
    golangci-lint       # Linter
    goose               # Database migrations
  ];

  CGO_ENABLED = "1";    # or "0" for pure Go

  shellHook = ''
    export GOPATH="$PWD/.go"
    export GOBIN="$GOPATH/bin"
    export PATH="$GOBIN:$PATH"
    mkdir -p "$GOBIN"
    echo "Go $(go version | awk '{print $3}')"
  '';
};

# With C dependencies (CGO)
devShells.default = pkgs.mkShell {
  packages = with pkgs; [ go_1_22 gopls ];
  buildInputs = with pkgs; [ sqlite ];
  nativeBuildInputs = with pkgs; [ pkg-config gcc ];
  CGO_ENABLED = "1";
};
```

### Java / JVM

```nix
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    jdk21               # Or jdk17, jdk11
    maven               # Or gradle
    jdt-language-server # Eclipse JDT LS for editors
  ];

  JAVA_HOME = "${pkgs.jdk21}";

  shellHook = ''
    echo "Java $(java --version 2>&1 | head -1)"
  '';
};

# Kotlin
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    jdk21
    kotlin
    gradle
    kotlin-language-server
  ];
  JAVA_HOME = "${pkgs.jdk21}";
};

# Clojure
devShells.default = pkgs.mkShell {
  packages = with pkgs; [ jdk21 clojure leiningen clojure-lsp ];
  JAVA_HOME = "${pkgs.jdk21}";
};
```

### C / C++

```nix
devShells.default = pkgs.mkShell {
  packages = with pkgs; [
    gcc13               # Or clang_17
    cmake
    gnumake
    ninja
    gdb
    valgrind
    clang-tools         # clangd, clang-format, clang-tidy
  ];

  buildInputs = with pkgs; [
    openssl
    zlib
    boost
    fmt
  ];

  nativeBuildInputs = with pkgs; [ pkg-config ];

  # For clangd to find headers
  shellHook = ''
    export CPATH="${pkgs.lib.makeSearchPathOutput "dev" "include" [
      pkgs.openssl pkgs.zlib pkgs.boost
    ]}"
  '';
};

# Cross-compilation shell
devShells.cross-arm = pkgs.mkShell {
  packages = with pkgs; [
    pkgsCross.aarch64-multiplatform.stdenv.cc
    cmake
  ];
};
```

---

## direnv Integration

### Setup

```bash
# 1. Install direnv and nix-direnv
# Via home-manager (recommended):
programs.direnv = {
  enable = true;
  nix-direnv.enable = true;    # Cached nix environments
};

# Or manually:
nix profile install nixpkgs#direnv nixpkgs#nix-direnv

# 2. Hook into your shell (add to ~/.bashrc, ~/.zshrc, etc.)
eval "$(direnv hook bash)"     # bash
eval "$(direnv hook zsh)"      # zsh

# 3. Configure nix-direnv (if installed manually)
# Add to ~/.config/direnv/direnvrc:
source $HOME/.nix-profile/share/nix-direnv/direnvrc
```

### .envrc Patterns

```bash
# Basic flake devShell
use flake

# Named devShell
use flake .#myshell

# Flake with extra env vars
use flake
export DATABASE_URL="postgresql://localhost/dev"
export AWS_PROFILE="dev"

# Layout for language-specific project dirs
use flake
layout python3     # Creates .direnv/python-* venv
# or
layout node        # Sets up node_modules/.bin in PATH

# Watch additional files for changes (re-eval on modification)
watch_file flake.nix
watch_file flake.lock
watch_file shell.nix

# Legacy nix-shell compat
use nix              # Uses shell.nix or default.nix

# Dotenv integration (load .env file)
dotenv_if_exists .env
```

### nix-direnv for Performance

nix-direnv caches the devShell evaluation, dramatically speeding up `cd` into projects.

```bash
# Without nix-direnv: 5-30s on every directory entry
# With nix-direnv: <100ms (cached), only re-evaluates when inputs change

# nix-direnv keeps a GC root — your devShell survives garbage collection
# GC roots stored in: .direnv/flake-profile*
```

Home Manager config for nix-direnv:
```nix
programs.direnv = {
  enable = true;
  nix-direnv.enable = true;
  enableBashIntegration = true;
  enableZshIntegration = true;
};
```

---

## Team Workflows

### Sharing devShells Across Teams

```nix
# Strategy 1: Shared flake as input
# In team-tools/flake.nix (published/shared repo):
{
  outputs = { self, nixpkgs, ... }: {
    devShellModules.default = { pkgs, ... }: {
      packages = with pkgs; [ awscli2 terraform kubectl jq yq ];
    };
  };
}

# In project flake.nix:
{
  inputs.team-tools.url = "github:myorg/team-tools";
  outputs = { self, nixpkgs, team-tools, ... }: {
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = with pkgs; [ nodejs_22 ] ++ team-tools.devShellModules.default { inherit pkgs; };
    };
  };
}

# Strategy 2: Overlay that adds team tools
# Shared overlay flake
{
  outputs = { ... }: {
    overlays.default = final: prev: {
      team-cli = final.writeShellScriptBin "team-cli" ''
        echo "Team CLI v1.0"
      '';
    };
  };
}
```

### Onboarding with Nix

Minimal onboarding instructions:

```markdown
## Setup (one-time, ~5 minutes)
1. Install Nix: `curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install`
2. Install direnv: `nix profile install nixpkgs#direnv`
3. Add to shell rc: `eval "$(direnv hook bash)"` (or zsh)
4. Clone repo and cd into it
5. Run `direnv allow`
6. Done — all tools are available
```

---

## Pinning Tool Versions

```nix
# Pin nixpkgs to a specific commit for exact reproducibility
inputs.nixpkgs.url = "github:NixOS/nixpkgs/a3c0b3b21515f74fd2665903d4ce6bc4dc81e838";

# Pin individual tools from different nixpkgs versions
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
};
outputs = { nixpkgs, nixpkgs-stable, ... }: let
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  pkgsStable = import nixpkgs-stable { system = "x86_64-linux"; };
in {
  devShells.x86_64-linux.default = pkgs.mkShell {
    packages = [
      pkgs.nodejs_22          # Latest from unstable
      pkgsStable.terraform    # Stable version for production compat
    ];
  };
};

# Check what version you're getting
nix eval nixpkgs#nodejs_22.version      # "22.x.x"
nix eval nixpkgs#go_1_22.version        # "1.22.x"
```

---

## Multiple Project Environments

### Per-Directory Shells

```nix
# flake.nix with multiple devShells
{
  devShells.x86_64-linux = {
    default = pkgs.mkShell { packages = [ pkgs.nodejs_22 ]; };
    backend = pkgs.mkShell { packages = [ pkgs.go_1_22 pkgs.postgresql ]; };
    frontend = pkgs.mkShell { packages = [ pkgs.nodejs_22 pkgs.yarn ]; };
    ops = pkgs.mkShell { packages = [ pkgs.terraform pkgs.kubectl pkgs.awscli2 ]; };
  };
}
```

```bash
# .envrc for sub-directories
# frontend/.envrc
use flake ..#frontend

# backend/.envrc
use flake ..#backend
```

### Monorepo Pattern

```nix
# Root flake for a monorepo
{
  outputs = { self, nixpkgs, ... }: let
    pkgs = import nixpkgs { system = "x86_64-linux"; };
    commonPackages = with pkgs; [ git jq curl ];
  in {
    devShells.x86_64-linux = {
      default = pkgs.mkShell {
        packages = commonPackages;
        shellHook = "echo 'Root shell — cd into a subproject for specific tools'";
      };
      api = pkgs.mkShell {
        packages = commonPackages ++ (with pkgs; [ go_1_22 gopls ]);
      };
      web = pkgs.mkShell {
        packages = commonPackages ++ (with pkgs; [ nodejs_22 nodePackages.pnpm ]);
      };
      mobile = pkgs.mkShell {
        packages = commonPackages ++ (with pkgs; [ jdk21 kotlin gradle ]);
      };
    };
  };
}
```

---

## Advanced Patterns

### Composable Shell Fragments

```nix
# lib/shells.nix — reusable shell components
{ pkgs }: {
  aws = {
    packages = with pkgs; [ awscli2 ssm-session-manager-plugin ];
    shellHook = ''export AWS_PROFILE="''${AWS_PROFILE:-dev}"'';
  };
  docker = {
    packages = with pkgs; [ docker-compose lazydocker ];
  };
  database = {
    packages = with pkgs; [ postgresql_16 pgcli ];
    shellHook = ''export PGHOST=localhost PGPORT=5432'';
  };
}

# Usage in flake.nix
let
  fragments = import ./lib/shells.nix { inherit pkgs; };
  mergeFragments = frags: {
    packages = builtins.concatLists (map (f: f.packages or []) frags);
    shellHook = builtins.concatStringsSep "\n" (map (f: f.shellHook or "") frags);
  };
  merged = mergeFragments [ fragments.aws fragments.docker fragments.database ];
in pkgs.mkShell merged
```

### Pre/Post Hooks for CI Compatibility

```nix
devShells.default = pkgs.mkShell {
  packages = with pkgs; [ nodejs_22 ];
  shellHook = ''
    # Only run interactive setup when not in CI
    if [ -z "''${CI:-}" ]; then
      echo "🛠  Dev environment loaded"
      [ -f .env ] && source .env
    fi
  '';
};
```

### devShell with Services (process-compose)

```nix
# Use process-compose-flake for multi-service dev environments
{
  inputs.process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
  outputs = { ... }: {
    # Defines a process-compose setup that starts DB, cache, and app together
    # Run with: nix run .#services
  };
}

# Simpler alternative: just use shellHook
devShells.default = pkgs.mkShell {
  packages = with pkgs; [ postgresql redis ];
  shellHook = ''
    export PGDATA="$PWD/.pgdata"
    if [ ! -d "$PGDATA" ]; then
      initdb --auth=trust
    fi
    echo "Start services: pg_ctl start && redis-server --daemonize yes"
  '';
};
```
