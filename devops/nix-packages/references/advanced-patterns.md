# Nix Advanced Patterns Reference

## Table of Contents

- [Nix Language Deep Dive](#nix-language-deep-dive)
  - [Functors](#functors)
  - [Fixed-Point Computation](#fixed-point-computation)
  - [Advanced Function Patterns](#advanced-function-patterns)
- [Overlays Deep Dive](#overlays-deep-dive)
  - [Overlay Mechanics](#overlay-mechanics)
  - [Composing Overlays](#composing-overlays)
  - [overrideAttrs Patterns](#overrideattrs-patterns)
- [Flake Patterns](#flake-patterns)
  - [Multi-System Flakes](#multi-system-flakes)
  - [flake-utils](#flake-utils)
  - [flake-parts](#flake-parts)
- [Custom Derivations](#custom-derivations)
  - [Phases Deep Dive](#phases-deep-dive)
  - [Fixed-Output Derivations](#fixed-output-derivations)
- [Import From Derivation (IFD)](#import-from-derivation-ifd)
- [Recursive Nix](#recursive-nix)
- [Module System Deep Dive](#module-system-deep-dive)
  - [Option Types](#option-types)
  - [Module Composition](#module-composition)
- [Useful lib Functions](#useful-lib-functions)

---

## Nix Language Deep Dive

### Functors

A functor in Nix is an attrset with a `__functor` attribute, making the attrset callable like a function. This enables stateful function-like objects.

```nix
# Basic functor: an attrset that behaves as a function
let
  counter = {
    value = 0;
    __functor = self: x: {
      value = self.value + x;
      inherit (self) __functor;
    };
  };
in (counter 5).value   # => 5
```

Use cases:
- **Configurable builders** — carry config alongside callable behavior
- **Chainable API** — each call returns a new functor with updated state
- **Default arguments** — embed defaults in the attrset, override via `//`

```nix
# Configurable builder functor
let
  mkBuilder = {
    compiler = "gcc";
    optimize = true;
    __functor = self: src: derivation {
      name = "build";
      builder = "/bin/sh";
      args = [ "-c" "echo building ${src} with ${self.compiler}" ];
      system = builtins.currentSystem;
    };
  };
  clangBuilder = mkBuilder // { compiler = "clang"; };
in clangBuilder "./src"
```

### Fixed-Point Computation

The fixed-point combinator is the foundation of nixpkgs overlays. It computes a value `x` such that `f(x) = x`.

```nix
# The fix combinator — core of Nix's overlay system
fix = f: let x = f x; in x;

# Simple example
fix (self: { a = 1; b = self.a + 1; })   # => { a = 1; b = 2; }

# This is how nixpkgs extends itself:
# extends :: (final -> prev -> attrs) -> (final -> attrs) -> (final -> attrs)
extends = overlay: base: final:
  let prev = base final;
  in prev // overlay final prev;

# Applying overlays is: fix (extends overlay3 (extends overlay2 (extends overlay1 basePackages)))
```

Key insight: `final` is the **fully resolved** package set (the fixed point). `prev` is the set **before** the current overlay. Referencing `final` lets later overlays influence earlier ones — but careless use causes infinite recursion.

```nix
# SAFE: prev references break cycles
final: prev: { myPkg = prev.hello.overrideAttrs (o: { pname = "my-hello"; }); }

# DANGEROUS: final self-reference can diverge
final: prev: { hello = final.hello.overrideAttrs (o: { }); }  # infinite recursion!
```

### Advanced Function Patterns

```nix
# Function composition
compose = f: g: x: f (g x);
pipe = builtins.foldl' (x: f: f x);   # pipe initialValue [ fn1 fn2 fn3 ]

# Recursive attrset merging (deep merge)
recursiveMerge = attrList:
  let
    merge = a: b:
      a // builtins.mapAttrs (name: value:
        if builtins.isAttrs value && builtins.hasAttr name a && builtins.isAttrs a.${name}
        then merge a.${name} value
        else value
      ) b;
  in builtins.foldl' merge {} attrList;

# flip and apply patterns
flip = f: a: b: f b a;
apply = f: args: f args;
```

---

## Overlays Deep Dive

### Overlay Mechanics

An overlay is `final: prev: { ... }` where:
- `final` — the fully assembled package set after all overlays
- `prev` — the package set from the previous overlay layer

```nix
# Overlay that adds a new package and modifies an existing one
myOverlay = final: prev: {
  myTool = final.callPackage ./my-tool.nix {};

  python3 = prev.python3.override {
    packageOverrides = pfinal: pprev: {
      myLib = pfinal.callPackage ./my-python-lib.nix {};
    };
  };

  # Use prev for the base, final for dependencies that may also be overlayed
  myApp = prev.stdenv.mkDerivation {
    pname = "myapp";
    version = "1.0";
    buildInputs = [ final.openssl final.myTool ];  # final: picks up overlayed versions
    src = ./src;
  };
};
```

### Composing Overlays

```nix
# Manual composition
composedOverlay = final: prev:
  let
    prev1 = overlay1 final prev;
    prev2 = overlay2 final (prev // prev1);
  in prev1 // prev2;

# Using lib.composeManyExtensions (preferred)
composedOverlay = lib.composeManyExtensions [ overlay1 overlay2 overlay3 ];

# In a flake
{
  outputs = { self, nixpkgs, ... }: {
    overlays.default = lib.composeManyExtensions [
      (import ./overlays/tools.nix)
      (import ./overlays/python.nix)
      (import ./overlays/patches.nix)
    ];
  };
}
```

### overrideAttrs Patterns

```nix
# Two-argument form (modern, Nix 2.14+): finalAttrs and previousAttrs
pkg.overrideAttrs (finalAttrs: previousAttrs: {
  version = "2.0";
  src = fetchurl {
    url = "https://example.com/pkg-${finalAttrs.version}.tar.gz";  # self-referencing
    hash = "sha256-...";
  };
})

# Appending to existing lists
pkg.overrideAttrs (prev: {
  buildInputs = (prev.buildInputs or []) ++ [ extraDep ];
  patches = (prev.patches or []) ++ [ ./fix.patch ];
  postInstall = (prev.postInstall or "") + ''
    wrapProgram $out/bin/app --prefix PATH : ${lib.makeBinPath [ dep ]}
  '';
})

# override vs overrideAttrs
# override: changes the ARGUMENTS passed to the package function
pkg.override { openssl = libressl; }
# overrideAttrs: changes the ATTRIBUTES of mkDerivation
pkg.overrideAttrs (prev: { doCheck = false; })
```

---

## Flake Patterns

### Multi-System Flakes

```nix
# Manual multi-system (no dependencies)
{
  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
      pkgs = import nixpkgs { inherit system; };
      inherit system;
    });
  in {
    packages = forAllSystems ({ pkgs, ... }: {
      default = pkgs.callPackage ./package.nix {};
    });
    devShells = forAllSystems ({ pkgs, ... }: {
      default = pkgs.mkShell { buildInputs = [ pkgs.go pkgs.gopls ]; };
    });
  };
}
```

### flake-utils

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.callPackage ./pkg.nix {};
        devShells.default = pkgs.mkShell { packages = [ pkgs.nodejs ]; };
      }
    ) // {
      # Non-per-system outputs go here
      overlays.default = final: prev: { };
      nixosModules.default = { ... }: { };
    };
}
```

### flake-parts

flake-parts uses the NixOS module system for flake outputs — best for complex projects.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };
  outputs = inputs @ { flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      perSystem = { pkgs, system, self', ... }: {
        packages.default = pkgs.callPackage ./package.nix {};
        devShells.default = pkgs.mkShell {
          inputsFrom = [ self'.packages.default ];
          packages = [ pkgs.nixfmt-rfc-style ];
        };
        checks.default = self'.packages.default;
        formatter = pkgs.nixfmt-rfc-style;
      };

      flake = {
        overlays.default = final: prev: { };
        nixosModules.default = { config, pkgs, ... }: { };
      };
    };
}
```

Key flake-parts features:
- `perSystem` — per-system outputs with automatic system threading
- `self'` — reference own per-system outputs without `system` boilerplate
- `inputs'` — per-system view of inputs
- `flake` — non-per-system outputs (overlays, nixosModules)
- Module imports for reusable flake components

---

## Custom Derivations

### Phases Deep Dive

```nix
stdenv.mkDerivation {
  pname = "myapp";
  version = "1.0";
  src = ./src;

  # Phase hooks — insert before/after any phase
  preBuild = ''
    echo "Generating files..."
    ./generate-config.sh
  '';
  postInstall = ''
    mkdir -p $out/share/man/man1
    cp docs/myapp.1 $out/share/man/man1/
  '';

  # Skip phases
  dontConfigure = true;    # Skip configurePhase
  doCheck = false;          # Skip checkPhase

  # Custom installPhase
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib
    cp -r build/* $out/
    runHook postInstall       # Always call runHook for extensibility
  '';

  # Multiple outputs (split packages)
  outputs = [ "out" "dev" "doc" ];
  postInstall = ''
    mkdir -p $dev/include $doc/share/doc
    mv $out/include/* $dev/include/
    mv $out/share/doc/* $doc/share/doc/
  '';
}
```

### Fixed-Output Derivations

Fixed-output derivations have network access but must produce a known hash.

```nix
# FOD — fetcher pattern
stdenv.mkDerivation {
  name = "vendor-deps";
  src = ./.;
  nativeBuildInputs = [ pkgs.go ];
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
  outputHash = "sha256-AAAA...";
  buildPhase = ''
    export GOPATH=$TMPDIR/go
    go mod download
    cp -r $TMPDIR/go/pkg/mod/cache $out
  '';
  impureEnvVars = lib.fetchers.proxyImpureEnvVars;  # allow proxy env vars
}
```

---

## Import From Derivation (IFD)

IFD forces Nix to build a derivation during evaluation. Avoid when possible.

```nix
# IFD example — generates Nix from package metadata at eval time
let
  generatedNix = pkgs.runCommand "generated.nix" { buildInputs = [ pkgs.jq ]; } ''
    jq -r '.dependencies | to_entries | map("  \(.key) = \"\(.value)\";") | join("\n")' \
      ${./package.json} > $out
  '';
  deps = import generatedNix;   # IFD! Nix must build generatedNix to evaluate
in ...

# Alternative: pre-generate and commit the Nix file
# Run `nix-build generate-deps.nix -o deps.nix` and commit deps.nix
```

IFD problems: breaks `nix flake check`, slows evaluation, incompatible with lazy evaluation.

---

## Recursive Nix

Recursive Nix allows derivations to invoke `nix-build` inside their build. Experimental.

```nix
# Enable: nix.settings.extra-experimental-features = [ "recursive-nix" ];
stdenv.mkDerivation {
  name = "recursive-example";
  requiredSystemFeatures = [ "recursive-nix" ];
  buildPhase = ''
    export NIX_CONFIG="experimental-features = nix-command flakes"
    innerDrv=$(nix build --print-out-paths --expr '
      with import <nixpkgs> {};
      writeText "inner" "hello from inner build"
    ')
    cp $innerDrv $out
  '';
}
```

---

## Module System Deep Dive

### Option Types

```nix
# Define a module with options
{ lib, config, pkgs, ... }: {
  options.services.myapp = {
    enable = lib.mkEnableOption "myapp service";
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port to listen on";
    };
    settings = lib.mkOption {
      type = lib.types.submodule {
        options = {
          logLevel = lib.mkOption {
            type = lib.types.enum [ "debug" "info" "warn" "error" ];
            default = "info";
          };
          workers = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4;
          };
          extraConfig = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
          };
        };
      };
      default = {};
    };
    package = lib.mkPackageOption pkgs "myapp" {};
  };

  config = lib.mkIf config.services.myapp.enable {
    systemd.services.myapp = {
      description = "My Application";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${config.services.myapp.package}/bin/myapp --port ${toString config.services.myapp.port}";
        DynamicUser = true;
      };
    };
  };
}
```

Common `lib.types`:
| Type | Description |
|------|-------------|
| `types.str` | String |
| `types.int`, `types.ints.positive` | Integer variants |
| `types.bool` | Boolean |
| `types.path` | Path |
| `types.port` | 0–65535 |
| `types.enum [ "a" "b" ]` | Enumeration |
| `types.listOf types.str` | List of type |
| `types.attrsOf types.int` | Attrset of type |
| `types.nullOr types.str` | Nullable |
| `types.either types.str types.int` | Union type |
| `types.submodule { options = ...; }` | Nested module |
| `types.oneOf [ t1 t2 ]` | One of multiple types |
| `types.package` | Nix derivation |

### Module Composition

```nix
# Importing modules
{ imports = [ ./networking.nix ./services.nix ./users.nix ]; }

# Priority control
services.myapp.port = lib.mkDefault 8080;     # low priority, easily overridden
services.myapp.port = lib.mkForce 9090;       # high priority, hard to override
services.myapp.port = lib.mkOverride 50 8080; # explicit priority (default is 100)

# Conditional configuration
config = lib.mkMerge [
  (lib.mkIf config.services.myapp.enable { networking.firewall.allowedTCPPorts = [ cfg.port ]; })
  (lib.mkIf cfg.settings.logLevel == "debug" { environment.systemPackages = [ pkgs.strace ]; })
];
```

---

## Useful lib Functions

```nix
# Attrset manipulation
lib.mapAttrs (name: value: value + 1) { a = 1; b = 2; }       # { a = 2; b = 3; }
lib.filterAttrs (n: v: v > 1) { a = 1; b = 2; }               # { b = 2; }
lib.genAttrs [ "a" "b" ] (name: "val-${name}")                 # { a = "val-a"; b = "val-b"; }
lib.mapAttrsToList (n: v: "${n}=${v}") { a = "1"; }            # [ "a=1" ]
lib.recursiveUpdate { a.b = 1; } { a.c = 2; }                  # { a = { b = 1; c = 2; }; }
lib.attrValues { a = 1; b = 2; }                                # [ 1 2 ]
lib.attrNames { a = 1; b = 2; }                                 # [ "a" "b" ]
lib.hasAttr "a" { a = 1; }                                      # true

# List manipulation
lib.flatten [ [ 1 2 ] [ 3 ] 4 ]                                # [ 1 2 3 4 ]
lib.unique [ 1 2 1 3 ]                                          # [ 1 2 3 ]
lib.optional true "x"                                            # [ "x" ]
lib.optionals false [ "x" "y" ]                                  # []

# String manipulation
lib.concatStringsSep ", " [ "a" "b" "c" ]                       # "a, b, c"
lib.concatMapStringsSep "\n" (x: "- ${x}") [ "a" "b" ]         # "- a\n- b"
lib.removeSuffix ".nix" "foo.nix"                                # "foo"
lib.hasPrefix "hello" "hello world"                              # true
lib.splitString "." "1.2.3"                                      # [ "1" "2" "3" ]

# Path manipulation
lib.makeBinPath [ pkgs.git pkgs.curl ]      # "/nix/store/...-git/bin:/nix/store/...-curl/bin"
lib.makeLibraryPath [ pkgs.openssl ]         # library paths joined with ":"

# Derivation helpers
lib.getName pkgs.hello                       # "hello"
lib.getVersion pkgs.hello                    # "2.12.1"
lib.maintainers.yourname                     # Maintainer metadata
lib.licenses.mit                             # License metadata
lib.platforms.linux                          # [ "x86_64-linux" "aarch64-linux" ... ]
```
