---
name: nix-packages
description: >
  Use when writing Nix expressions, flake.nix files, shell.nix, default.nix, derivations,
  NixOS configuration.nix, Home Manager home.nix, nixpkgs overlays, or devShells. Trigger on
  mentions of nix build, nix develop, nix run, nix-shell, nix-env, nixos-rebuild, mkDerivation,
  mkShell, buildInputs, fetchurl, fetchFromGitHub, dockerTools, cachix, flake.lock, or nixpkgs.
  Also trigger when user asks about reproducible builds, declarative package management, immutable
  package stores, or Nix language syntax (attrsets, let-in, with, inherit, rec).
  DO NOT trigger for Nginx web server config, Unix/Linux general commands, npm/nix-like-named tools,
  or Nix the cryptocurrency. DO NOT trigger for Docker unless specifically using Nix dockerTools.
---

# Nix Package Manager — Comprehensive Skill

## Core Philosophy

Nix is a purely functional package manager. Every package is built in isolation, addressed by a cryptographic hash of all inputs. Key principles:

- **Reproducible builds**: Same inputs always produce same outputs. No implicit dependencies.
- **Declarative configuration**: Describe desired state; Nix computes how to reach it.
- **Immutable store**: All packages live in `/nix/store/<hash>-<name>`. Never modified in place.
- **Atomic upgrades/rollbacks**: Switching between configurations is instantaneous and reversible.
- **Multi-user support**: Multiple users can install packages without conflicts.

## Installation

### Determinate Systems Installer (Recommended)
```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```
Enables flakes and `nix-command` by default. Supports Linux, macOS (survives upgrades), WSL, containers. Clean uninstall via `nix-installer uninstall`.

### Official Multi-User Install
```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
```
Requires root. Creates build users and a systemd/launchd daemon.

### Official Single-User Install
```bash
sh <(curl -L https://nixos.org/nix/install) --no-daemon
```
No root needed. All state under `~/.nix-profile`.

### Enable Flakes (if not using Determinate installer)
Add to `~/.config/nix/nix.conf` or `/etc/nix/nix.conf`:
```
experimental-features = nix-command flakes
```

## Nix Language Essentials

Nix is purely functional, lazily evaluated, dynamically typed. Everything is an expression.

### Attribute Sets, Let Bindings, Functions
```nix
{ name = "hello"; version = "2.12"; }          # Basic attrset
rec { a = 1; b = a + 1; }                      # Recursive (self-referencing)
{ x = 1; } // { y = 2; }                       # Merge => { x = 1; y = 2; }
attrs.name                                      # Access => "hello"
attrs.missing or "default"                      # Access with fallback

let x = 1; y = x + 2; in y * 3                 # Let binding => 9

inc = x: x + 1;                                # Single-arg function
add = a: b: a + b;                             # Curried function
greet = { name, greeting ? "Hello" }: "${greeting}, ${name}!";  # Destructuring + defaults
f = { a, b, ... }: a + b;                      # Variadic (accept extra attrs)
```

### with, inherit, import
```nix
with pkgs; [ git curl wget ]                              # Bring attrs into scope
let x = 1; y = 2; in { inherit x y; }                    # Copy from scope => { x=1; y=2; }
{ inherit (pkgs) git curl; }                              # Copy from attrset
let myLib = import ./lib.nix; in myLib.doThing 42         # Load + evaluate .nix file
"Hello, ${name}!"                                         # String interpolation
''
  multiline string (indentation stripped)
''
```

## Nixpkgs

Nixpkgs is the largest package repository (~100,000 packages). Search at https://search.nixos.org/packages or via CLI:
```bash
nix search nixpkgs python3                    # Search by name
nix shell nixpkgs#python3 nixpkgs#nodejs      # Ad-hoc shell with packages
nix run nixpkgs#hello                          # Run package directly
```

### Overriding and Overlays
```nix
# Override function arguments
pkgs.hello.override { stdenv = pkgs.clangStdenv; }

# Override derivation attributes
pkgs.hello.overrideAttrs (old: {
  version = "2.13";
  src = pkgs.fetchurl { url = "..."; hash = "sha256-..."; };
})

# Overlay: a function final -> prev -> { ... }
final: prev: {
  myHello = prev.hello.overrideAttrs (old: {
    pname = "my-hello";
    patches = old.patches or [] ++ [ ./custom.patch ];
  });
}

# Apply overlay in flake
pkgs = import nixpkgs { inherit system; overlays = [ myOverlay ]; };
```

## Nix Flakes

Flakes standardize project structure for reproducibility. A flake is a directory with `flake.nix` at root.

### flake.nix Structure
```nix
{
  description = "My project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.callPackage ./package.nix {};
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ nodejs yarn typescript ];
        };
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/myapp";
        };
      });
}
```

### Key Concepts
- **inputs**: Declare dependencies (other flakes). Pinned in `flake.lock`.
- **outputs**: Function producing packages, devShells, apps, nixosConfigurations, etc.
- **flake.lock**: Auto-generated lockfile. Commit to VCS. Update with `nix flake update`.

### Essential Commands
```bash
nix flake init                    # Create flake.nix from template
nix flake update                  # Update all inputs in flake.lock
nix flake lock --update-input nixpkgs  # Update single input
nix flake show                    # Display flake outputs
nix flake metadata                # Show flake metadata and inputs
nix develop                       # Enter default devShell
nix develop .#myshell             # Enter named devShell
nix build                         # Build default package
nix build .#mypackage             # Build named package
nix run                           # Run default app
nix run .#myapp                   # Run named app
```

## Development Shells

### mkShell
```nix
devShells.default = pkgs.mkShell {
  buildInputs = with pkgs; [ python3 poetry black ruff ];

  shellHook = ''
    echo "Python dev environment loaded"
    export PROJECT_ROOT=$(pwd)
  '';

  # Environment variables
  DATABASE_URL = "postgresql://localhost/dev";
};
```

### Language-Specific Shells
```nix
# Rust
pkgs.mkShell {
  buildInputs = with pkgs; [ cargo rustc rust-analyzer clippy rustfmt ];
  RUST_SRC_PATH = "${pkgs.rust.packages.stable.rustPlatform.rustLibSrc}";
}
# Python
pkgs.mkShell {
  buildInputs = with pkgs; [
    (python3.withPackages (ps: with ps; [ requests flask pytest ]))  ruff
  ];
}
# Node.js
pkgs.mkShell { buildInputs = with pkgs; [ nodejs_20 yarn nodePackages.typescript ]; }
# Go
pkgs.mkShell { buildInputs = with pkgs; [ go gopls gotools go-tools ]; CGO_ENABLED = "0"; }
```

## Building Packages

### stdenv.mkDerivation
```nix
# package.nix
{ lib, stdenv, fetchFromGitHub, cmake, pkg-config, openssl }:

stdenv.mkDerivation rec {
  pname = "myapp";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "myorg";
    repo = "myapp";
    rev = "v${version}";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  nativeBuildInputs = [ cmake pkg-config ];  # Build-time only tools
  buildInputs = [ openssl ];                  # Libraries linked at runtime

  cmakeFlags = [ "-DENABLE_TESTS=OFF" ];

  # Override individual phases if needed
  installPhase = ''
    mkdir -p $out/bin
    cp myapp $out/bin/
  '';

  meta = with lib; {
    description = "My application";
    homepage = "https://github.com/myorg/myapp";
    license = licenses.mit;
    maintainers = [ maintainers.yourname ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
```

### Build Phases and Dependencies
Standard phases in order: `unpackPhase` → `patchPhase` → `configurePhase` → `buildPhase` → `checkPhase` → `installPhase` → `fixupPhase`. Override any phase as a string. Disable with `dontBuild = true;`, `dontConfigure = true;`, etc.

- **nativeBuildInputs**: Build-time tools (compilers, pkg-config). Run on build host in cross-compilation.
- **buildInputs**: Runtime libraries. Target platform in cross-compilation.
- **propagatedBuildInputs**: Runtime deps that propagate to downstream dependents.
- **nativeCheckInputs**: Test-only dependencies.

### Fetchers
```nix
fetchurl { url = "https://example.com/foo-1.0.tar.gz"; hash = "sha256-..."; }
fetchFromGitHub { owner = "org"; repo = "repo"; rev = "v1.0"; hash = "sha256-..."; }
fetchgit { url = "https://example.com/repo.git"; rev = "abc123"; hash = "sha256-..."; }
```
Compute hashes: use `nix-prefetch-url` or set hash to `""` — Nix prints the correct hash on failure.

## NixOS Configuration

### /etc/nixos/configuration.nix
```nix
{ config, pkgs, ... }: {
  system.stateVersion = "24.11";
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  networking.hostName = "myhost";
  networking.firewall.allowedTCPPorts = [ 80 443 22 ];

  users.users.alice = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" "networkmanager" ];
    shell = pkgs.zsh;
  };

  environment.systemPackages = with pkgs; [ vim git curl htop ];
  services.openssh.enable = true;
  services.nginx = {
    enable = true;
    virtualHosts."example.com" = {
      forceSSL = true; enableACME = true; root = "/var/www/example";
    };
  };
  virtualisation.docker.enable = true;
  nixpkgs.config.allowUnfree = true;
}
```
Apply: `sudo nixos-rebuild switch`. Test: `sudo nixos-rebuild test`. Rollback: `sudo nixos-rebuild switch --rollback`.

## Home Manager

Manages user-level config declaratively. Works on NixOS, non-NixOS Linux, and macOS.

### Standalone Setup (with flakes)
```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { nixpkgs, home-manager, ... }: {
    homeConfigurations."alice" = home-manager.lib.homeManagerConfiguration {
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      modules = [ ./home.nix ];
    };
  };
}
```

### home.nix
```nix
{ pkgs, ... }: {
  home.username = "alice";
  home.homeDirectory = "/home/alice";
  home.stateVersion = "24.11";
  home.packages = with pkgs; [ ripgrep fd bat jq fzf ];

  programs.git = {
    enable = true; userName = "Alice"; userEmail = "alice@example.com";
    extraConfig.init.defaultBranch = "main";
  };
  programs.zsh = {
    enable = true; enableCompletion = true;
    oh-my-zsh = { enable = true; theme = "robbyrussell"; };
  };
  programs.neovim = { enable = true; defaultEditor = true; viAlias = true; vimAlias = true; };

  home.file.".config/starship.toml".source = ./dotfiles/starship.toml;
  xdg.configFile."alacritty/alacritty.toml".source = ./dotfiles/alacritty.toml;
}
```
Apply with `home-manager switch --flake .#alice`.

## nix-shell vs nix develop

| Aspect | nix-shell (Legacy) | nix develop (Flakes) |
|---|---|---|
| Config file | shell.nix / default.nix | flake.nix devShells output |
| Reproducibility | No lockfile, can drift | flake.lock pins all inputs |
| Command | `nix-shell` | `nix develop` |
| Ad-hoc packages | `nix-shell -p python3 git` | `nix shell nixpkgs#python3 nixpkgs#git` |
| direnv integration | `use nix` | `use flake` |
| Recommendation | Legacy projects only | Prefer for all new projects |

Migrate by moving `shell.nix` deps into `devShells.default` in `flake.nix`.

## Binary Caches and Cachix

### Configure Substituters
```nix
nix.settings = {
  substituters = [ "https://cache.nixos.org" "https://mycache.cachix.org" ];
  trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "mycache.cachix.org-1:XXXXXX..."
  ];
};
```

### Cachix Usage
```bash
cachix use mycache            # Configure as substituter
nix build | cachix push mycache   # Push build results
cachix pin mycache myapp $(nix build --print-out-paths)   # Pin a store path
```

## Cross-Compilation

```nix
# In flake.nix — cross-compile by setting crossSystem
let pkgsCross = import nixpkgs { localSystem = "x86_64-linux"; crossSystem = "aarch64-linux"; };
in pkgsCross.stdenv.mkDerivation { ... }

# Shorthand via nixpkgs' pkgsCross
pkgs.pkgsCross.aarch64-multiplatform.hello    # ARM64 Linux
pkgs.pkgsCross.musl64.hello                   # Static linking
pkgs.pkgsCross.mingwW64.hello                 # Windows target
```

Build: `nix build .#packages.aarch64-linux.default` with appropriate emulation (QEMU/binfmt) or remote builders.

## Docker Images with Nix
```nix
# dockerTools.buildImage — full control
pkgs.dockerTools.buildImage {
  name = "myapp"; tag = "latest";
  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [ self.packages.${system}.default pkgs.coreutils pkgs.bash ];
    pathsToLink = [ "/bin" ];
  };
  config = {
    Cmd = [ "/bin/myapp" ]; ExposedPorts = { "8080/tcp" = {}; };
    Env = [ "PORT=8080" ]; WorkingDir = "/app";
  };
}

# streamLayeredImage — faster builds, layer caching
pkgs.dockerTools.streamLayeredImage {
  name = "myapp"; tag = "latest";
  contents = [ self.packages.${system}.default ];
  config.Cmd = [ "/bin/myapp" ];
}
```
Build and load: `nix build .#dockerImage && docker load < result`.

## CI/CD with Nix

### GitHub Actions
```yaml
name: CI
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
        with:
          github_access_token: ${{ secrets.GITHUB_TOKEN }}
      - uses: cachix/cachix-action@v15
        with:
          name: mycache
          authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}
      - run: nix flake check
      - run: nix build
```

### Nix Flake Check
Define `checks` output to run tests in CI:
```nix
checks.${system} = {
  tests = pkgs.runCommand "tests" { buildInputs = [ myapp ]; } ''
    myapp --run-tests
    touch $out
  '';
  lint = pkgs.runCommand "lint" { buildInputs = [ pkgs.nixfmt-rfc-style ]; } ''
    nixfmt --check ${./.}/*.nix
    touch $out
  '';
};
```

## Common Pitfalls and Solutions

**Hash Mismatches**: Set hash to `lib.fakeHash` or `""`, build, copy correct hash from error. Use SRI format: `hash = "sha256-AAAA...";`.

**Impure Builds**: Build depends on system state. Fix: use fetchers for sources. `__noChroot = true;` only as last resort.

**Unfree Packages**: `config.allowUnfree = true;` or `NIXPKGS_ALLOW_UNFREE=1 nix build --impure`.

**Flake Follows**: `inputs.dep.inputs.nixpkgs.follows = "nixpkgs";` to avoid duplicate nixpkgs.

**IFD**: Avoid `import (pkgs.runCommand ...)` — breaks `nix flake check`. Pre-generate Nix files.

See `references/troubleshooting.md` for comprehensive solutions including store corruption, macOS/WSL issues, and error message decoder.

## Quick Reference

```bash
nix profile install nixpkgs#hello      # Install       | nix repl             # REPL
nix profile remove hello               # Remove        | nix eval .#pkg.version  # Eval
nix store gc                           # Garbage collect| nix why-depends .#a .#b # Deps
nix store optimise                     # Deduplicate   | nix path-info -rSh .#p  # Size
nix fmt                                # Format        | nix flake check         # Checks
```

## Additional Resources

### References (`references/`)
- **`advanced-patterns.md`** — Functors, fixed-points, overlay composition, overrideAttrs patterns, flake-parts, flake-utils, custom derivations, IFD, recursive Nix, module system deep dive with option types, and useful `lib` functions.
- **`troubleshooting.md`** — Hash mismatches, impure builds, unfree/broken packages, store corruption & recovery, garbage collection, flake lock conflicts, channel-to-flake migration, macOS and WSL issues, common error messages decoded, diagnostic commands.
- **`nix-for-devshells.md`** — Language-specific devShells (Node.js, Python, Rust, Go, Java, C/C++), direnv + nix-direnv integration, `.envrc` patterns, team onboarding workflows, version pinning, monorepo patterns, composable shell fragments.

### Scripts (`scripts/`)
- **`init-flake.sh`** — Interactive flake project initializer. Creates `flake.nix` with language-specific devShell (node/python/rust/go), `.envrc`, and `.gitignore`. Usage: `./scripts/init-flake.sh [language]`
- **`gc-optimize.sh`** — Store management helper: size reporting, garbage collection, generation cleanup, deduplication. Usage: `./scripts/gc-optimize.sh [status|gc|gc-old|optimize|full|roots|big]`
- **`search-packages.sh`** — Search nixpkgs with version info and descriptions, table or JSON output. Usage: `./scripts/search-packages.sh <query> [--json] [--limit N]`

### Assets (`assets/`)
- **`flake-template.nix`** — Complete flake.nix with devShell, package, overlay, NixOS module, checks, and formatter outputs. Copy and replace `TODO` markers.
- **`shell-template.nix`** — Configurable mkShell template with toggles for Node.js, Python, Rust, Go, C++. Import from your flake.
- **`github-actions-nix.yml`** — GitHub Actions CI workflow with Nix + Cachix for flake check, build, and formatting.
- **`.envrc`** — Annotated direnv config for automatic `nix develop` activation with caching notes.
