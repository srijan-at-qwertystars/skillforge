---
name: nix-flakes
description:
  positive: "Use when user works with Nix, asks about flake.nix, devShells, nix develop, nix build, nixpkgs overlays, home-manager, NixOS configuration, or reproducible development environments with Nix."
  negative: "Do NOT use for Docker-based dev environments, Vagrant, or devcontainers without Nix context."
---

# Nix & Nix Flakes

## Nix Fundamentals

Nix is a purely functional package manager. Every package is a derivation producing an immutable output in `/nix/store/<hash>-<name>-<version>`.
- **Purity**: Sandboxed builds with no network access after fetching sources.
- **Reproducibility**: Same inputs produce the same output hash.
- **Atomic upgrades/rollbacks**: Profile switching is a symlink swap.

## Flakes

Flakes provide a standard structure for Nix projects with hermetic evaluation and lockfiles.

### flake.nix Structure

```nix
{
  description = "My project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.hello;
        devShells.default = pkgs.mkShell { packages = [ pkgs.hello ]; };
      }
    );
}
```

### Inputs

Specify dependencies as flake references:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";       # pinned branch
  home-manager.url = "github:nix-community/home-manager/release-24.11";
  home-manager.inputs.nixpkgs.follows = "nixpkgs";          # deduplicate
  my-flake.url = "path:./subdir";                            # local path
};
```

Use `follows` to force inputs to share the same nixpkgs, avoiding duplicate store paths.

### flake.lock

Auto-generated lockfile pinning exact revisions. Commit it to version control. Never edit manually.

```bash
nix flake update                # update all inputs
nix flake update nixpkgs        # update single input (Nix 2.19+)
nix flake lock --update-input nixpkgs  # older Nix
```

### Outputs Schema

Standard output attributes:

- `packages.<system>.<name>` — buildable packages
- `devShells.<system>.<name>` — development shells
- `overlays.<name>` — nixpkgs overlays
- `nixosConfigurations.<hostname>` — NixOS system configs
- `homeConfigurations.<user>` — home-manager configs
- `apps.<system>.<name>` — runnable applications
- `lib` — reusable library functions
- `templates` — project templates

## DevShells

### mkShell Basics

```nix
devShells.default = pkgs.mkShell {
  packages = with pkgs; [ nodejs python3 postgresql ];

  shellHook = ''
    export DATABASE_URL="postgres://localhost/dev"
    echo "Dev environment ready"
  '';
};
```

### buildInputs vs nativeBuildInputs

- `nativeBuildInputs` — tools that run at build time on the build host (compilers, pkg-config, cmake). Use this for most dev tools.
- `buildInputs` — libraries linked into the output, needed at runtime. Use for libraries you link against.

In dev shells the distinction is less critical, but prefer `nativeBuildInputs` for tools and `buildInputs` for libraries.

### Multiple Shells

```nix
devShells = {
  default = pkgs.mkShell { packages = [ pkgs.nodejs ]; };
  backend = pkgs.mkShell { packages = [ pkgs.python3 pkgs.poetry ]; };
  ci = pkgs.mkShell { packages = [ pkgs.nixfmt-rfc-style pkgs.statix ]; };
};
```

Enter a specific shell: `nix develop .#backend`.

### Shell Hooks

Use `shellHook` for setup commands. Keep hooks idempotent:

```nix
shellHook = ''
  export PATH="$PWD/node_modules/.bin:$PATH"
  [ ! -d node_modules ] && npm ci --silent
'';
```

## nix develop

Enter a dev shell interactively:

```bash
nix develop              # default shell from current flake
nix develop .#backend    # named shell
nix develop nixpkgs#python3  # shell from remote flake
nix develop --command zsh     # use specific shell
```

### direnv Integration

Install `nix-direnv` for automatic shell activation. Create `.envrc` with `use flake` (or `use flake .#backend`), then `direnv allow`. Environment activates on `cd` and caches builds to prevent GC.

Install nix-direnv via home-manager:

```nix
programs.direnv = { enable = true; nix-direnv.enable = true; };
```

Commit `.envrc` and `flake.lock` for team reproducibility.

## Building Packages

### stdenv.mkDerivation

```nix
packages.default = pkgs.stdenv.mkDerivation {
  pname = "my-tool";
  version = "1.0.0";
  src = ./.;

  nativeBuildInputs = [ pkgs.cmake ];
  buildInputs = [ pkgs.openssl pkgs.zlib ];

  buildPhase = ''
    cmake . -DCMAKE_INSTALL_PREFIX=$out
    make -j$NIX_BUILD_CORES
  '';

  installPhase = ''
    make install
  '';
};
```

Build phases in order: `unpackPhase`, `patchPhase`, `configurePhase`, `buildPhase`, `checkPhase`, `installPhase`, `fixupPhase`.

### buildPythonPackage

```nix
pkgs.python3Packages.buildPythonPackage {
  pname = "my-lib";
  version = "0.1.0";
  src = ./.;
  format = "pyproject";

  nativeBuildInputs = [ pkgs.python3Packages.setuptools ];
  propagatedBuildInputs = [ pkgs.python3Packages.requests ];

  nativeCheckInputs = [ pkgs.python3Packages.pytest ];
  checkPhase = "pytest";
}
```

### buildGoModule

```nix
pkgs.buildGoModule {
  pname = "my-service";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  # Set vendorHash = null if vendor/ is committed
  subPackages = [ "cmd/server" ];
}
```

Set `vendorHash` to `lib.fakeHash` first, build to get the real hash, then update.

### Overrides

```nix
pkgs.hello.overrideAttrs (old: {
  patches = (old.patches or []) ++ [ ./my-fix.patch ];
})
```

## Nixpkgs

### Package Sets and callPackage

`callPackage` auto-injects function arguments from the package set:

```nix
# my-package.nix
{ lib, stdenv, fetchurl, openssl }:
stdenv.mkDerivation { ... }

# usage
pkgs.callPackage ./my-package.nix {}
pkgs.callPackage ./my-package.nix { openssl = pkgs.libressl; }  # override
```

### Overlays

Overlays modify or extend the package set. Use `final` (fully resolved) and `prev` (before this overlay):

```nix
overlays.default = final: prev: {
  my-tool = final.callPackage ./my-tool.nix {};
  openssl = prev.openssl.overrideAttrs (old: {
    version = "3.2.0";
    src = final.fetchurl { ... };
  });
};
```

Apply overlays when importing nixpkgs:

```nix
pkgs = import nixpkgs {
  inherit system;
  overlays = [ self.overlays.default ];
};
```

Rules: use `prev` to reference the package you override. Use `final` for dependencies to allow further overlays to affect them.

## Language-Specific Dev Environments

### Python

```nix
devShells.default = pkgs.mkShell {
  packages = [
    (pkgs.python3.withPackages (ps: with ps; [ flask requests numpy ]))
    pkgs.ruff pkgs.pyright
  ];
};
```

### Node.js / Rust / Go / Haskell

```nix
# Node.js
pkgs.mkShell { packages = with pkgs; [ nodejs_22 corepack ]; }

# Rust
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [ cargo rustc rust-analyzer clippy ];
  buildInputs = with pkgs; [ openssl pkg-config ];
  RUST_SRC_PATH = "${pkgs.rust.packages.stable.rustPlatform.rustLibSrc}";
}

# Go
pkgs.mkShell { packages = with pkgs; [ go gopls gotools ]; }

# Haskell
pkgs.mkShell {
  packages = [
    (pkgs.haskellPackages.ghcWithPackages (hs: with hs; [ aeson lens ]))
    pkgs.cabal-install pkgs.haskell-language-server
  ];
}
```

## Home-Manager

Manage user-level configuration declaratively.

### Standalone with Flakes

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    home-manager.url = "github:nix-community/home-manager/release-24.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { nixpkgs, home-manager, ... }: {
    homeConfigurations."user" = home-manager.lib.homeManagerConfiguration {
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      modules = [ ./home.nix ];
    };
  };
}
```

### home.nix

```nix
{ pkgs, ... }: {
  home.username = "user";
  home.homeDirectory = "/home/user";
  home.stateVersion = "24.11";  # do not change after initial set
  home.packages = with pkgs; [ ripgrep fd bat jq ];

  programs.git = {
    enable = true;
    userName = "Your Name";
    userEmail = "you@example.com";
  };

  programs.direnv = { enable = true; nix-direnv.enable = true; };
  home.file.".config/starship.toml".source = ./dotfiles/starship.toml;
}
```

Apply: `home-manager switch --flake .#user`.

### As NixOS Module

```nix
home-manager.nixosModules.home-manager
{
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.myuser = import ./home.nix;
}
```

## NixOS Configuration

```nix
{ config, pkgs, ... }: {
  system.stateVersion = "24.11";
  networking.hostName = "myhost";
  networking.firewall.allowedTCPPorts = [ 80 443 22 ];

  users.users.myuser = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" "networkmanager" ];
  };

  environment.systemPackages = with pkgs; [ vim git curl ];
  services.openssh.enable = true;
  services.nginx = {
    enable = true;
    virtualHosts."example.com" = {
      forceSSL = true;
      enableACME = true;
      root = "/var/www/example";
    };
  };

  virtualisation.docker.enable = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
```

### NixOS with Flakes

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  outputs = { self, nixpkgs }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./hardware-configuration.nix ./configuration.nix ];
    };
  };
}
```

Rebuild: `sudo nixos-rebuild switch --flake .#myhost`.

## Nix Language

### Core Constructs

```nix
# let/in — local bindings
let name = "world"; in "Hello, ${name}!"

# with — bring attrset into scope
with pkgs; [ git vim curl ]

# inherit — shorthand for x = x
{ inherit name version; }           # { name = name; version = version; }
{ inherit (pkgs) git vim; }         # { git = pkgs.git; vim = pkgs.vim; }

# functions (curried)
add = x: y: x + y;
mkGreeting = { name, greeting ? "Hello" }: "${greeting}, ${name}!";

# rec attrsets, lists, conditionals
rec { x = 1; y = x + 1; }
[ 1 2 3 ] ++ [ 4 5 ]               # => [ 1 2 3 4 5 ]
if x > 0 then "positive" else "non-positive"
import ./my-module.nix { inherit pkgs; }
```

### Key Builtins and lib

```nix
builtins.map (x: x * 2) [ 1 2 3 ]          # => [ 2 4 6 ]
builtins.filter (x: x > 2) [ 1 2 3 4 ]     # => [ 3 4 ]
builtins.attrNames { a = 1; b = 2; }        # => [ "a" "b" ]
builtins.readFile ./version.txt
builtins.toJSON { a = 1; }                  # => "{\"a\":1}"
lib.mkIf condition value                     # conditional module values
lib.genAttrs [ "x86_64-linux" ] (system: ...) # generate attrsets
lib.filterAttrs (n: v: v != null) attrset
```

### Caching and Binary Caches

Configure substituters in flake `nixConfig`:

```nix
nixConfig = {
  extra-substituters = [ "https://my-cache.cachix.org" ];
  extra-trusted-public-keys = [ "my-cache.cachix.org-1:XXXX=" ];
};
```

Cachix workflow: `cachix use my-cache` to subscribe, `cachix push my-cache ./result` after building.

GitHub Actions:

```yaml
- uses: cachix/install-nix-action@v27
- uses: cachix/cachix-action@v15
  with: { name: my-cache, authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}' }
- run: nix build
```

## Docker Images with Nix

```nix
# Minimal image
packages.docker = pkgs.dockerTools.buildImage {
  name = "my-app";
  tag = "latest";
  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [ self.packages.${system}.default ];
    pathsToLink = [ "/bin" ];
  };
  config.Cmd = [ "/bin/my-app" ];
};

# Layered image — shared deps in lower layers for better caching
packages.dockerLayered = pkgs.dockerTools.buildLayeredImage {
  name = "my-app";
  tag = "latest";
  contents = [ self.packages.${system}.default pkgs.cacert ];
  config.Cmd = [ "/bin/my-app" ];
};
```

Load and run: `docker load < $(nix build .#docker --print-out-paths)`.

## Common Patterns and Anti-Patterns

### Do

- **Pin nixpkgs**: Always use a specific branch or commit, never follow `master` unversioned.
- **Use `follows`**: Deduplicate shared inputs with `inputs.X.inputs.nixpkgs.follows = "nixpkgs"`.
- **Multi-system support**: Use `flake-utils.lib.eachDefaultSystem` or `lib.genAttrs`.
- **Separate concerns**: Split large configs into modules with `imports`.
- **Use `writeShellScriptBin`** for project-specific CLI tools available in dev shells.

### Do Not

- **Avoid `with pkgs;` in large scopes** — makes it unclear where names come from.
- **Do not use `builtins.fetchTarball` in flakes** — breaks purity. Use flake inputs.
- **Do not set `nixConfig.sandbox = false`** unless absolutely required.
- **Avoid `rec` in flake outputs** — use `let/in` or `self` references instead.
- **Do not ignore `flake.lock`** — commit it. Missing lockfiles break reproducibility.
- **Do not put secrets in Nix files** — use `sops-nix` or `agenix` for secret management.
- **Avoid IFD (import from derivation)** — slows evaluation and breaks caching.
