# Nix Troubleshooting Guide

## Table of Contents

- [Hash Mismatches](#hash-mismatches)
- [Impure Build Failures](#impure-build-failures)
- [Unfree and Broken Packages](#unfree-and-broken-packages)
- [Nix Store Corruption](#nix-store-corruption)
- [Garbage Collection Issues](#garbage-collection-issues)
- [Flake Lock Conflicts](#flake-lock-conflicts)
- [Channel vs Flake Mixing](#channel-vs-flake-mixing)
- [macOS-Specific Issues](#macos-specific-issues)
- [WSL Issues](#wsl-issues)
- [Common Error Messages Decoded](#common-error-messages-decoded)
- [Diagnostic Commands](#diagnostic-commands)

---

## Hash Mismatches

### Symptom
```
error: hash mismatch in fixed-output derivation '/nix/store/...-source':
  specified: sha256-AAAA...
  got:       sha256-BBBB...
```

### Causes & Fixes

**Wrong hash in source definition:**
```nix
# Fix: use lib.fakeHash as placeholder, build, copy real hash from error
src = fetchFromGitHub {
  owner = "org"; repo = "repo"; rev = "v1.0";
  hash = lib.fakeHash;  # or hash = "";
  # Build will fail and print the correct hash — copy it here
};
```

**Upstream tarball changed (re-released tag):**
```bash
# Verify by fetching manually
nix-prefetch-url --unpack https://github.com/org/repo/archive/v1.0.tar.gz
# If hash differs from nixpkgs, the upstream re-tagged. Pin to a commit SHA instead.
```

**NAR hash vs flat hash confusion:**
```nix
# fetchurl uses flat hash by default
fetchurl { url = "..."; hash = "sha256-..."; }
# fetchFromGitHub uses recursive/NAR hash
fetchFromGitHub { owner = "..."; repo = "..."; rev = "..."; hash = "sha256-..."; }
# Don't mix them — the hash format differs
```

**Store path hash mismatch (binary cache):**
```bash
# Repair the specific store path
nix store repair /nix/store/<hash>-<name>
# Or verify and repair all
nix store verify --all --repair
```

---

## Impure Build Failures

### Symptom
```
error: builder for '/nix/store/...' failed: sandbox violation
error: accessing '/usr/lib/...' is not allowed in sandbox mode
```

### Common Causes

**Build accesses network:**
```nix
# Fixed-output derivation: allowed network, but must specify hash
stdenv.mkDerivation {
  outputHash = "sha256-...";
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  # Now network access is allowed in sandbox
}

# Alternatively for testing (NOT production):
stdenv.mkDerivation {
  __noChroot = true;  # Disables sandbox — last resort
}
```

**Build depends on system state (/usr/lib, env vars):**
```nix
# Bad: references system paths
buildPhase = ''
  gcc -I/usr/include -L/usr/lib ...
'';

# Good: use nix-provided dependencies
nativeBuildInputs = [ pkgs.gcc ];
buildInputs = [ pkgs.openssl ];
buildPhase = ''
  gcc -I${pkgs.openssl.dev}/include ...
'';
```

**Environment variable leakage:**
```nix
# Nix sandbox clears most env vars. If build needs one:
preBuild = ''
  export MY_VAR="controlled_value"
'';
# For impure env vars (proxies, etc.) in FODs:
impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [ "MY_SPECIAL_VAR" ];
```

**Timestamps in build output:**
```nix
# Source files carry timestamps that change hashes
preBuild = ''
  find . -type f -exec touch -t 197001010000 {} +
'';
```

---

## Unfree and Broken Packages

### Unfree Packages

```
error: Package 'vscode-1.XX' has an unfree license ('unfree'), refusing to evaluate.
```

```nix
# Global allow (flake)
pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

# Per-package predicate
pkgs = import nixpkgs {
  inherit system;
  config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "vscode" "slack" "zoom-us" "1password"
  ];
};

# Ad-hoc CLI override
NIXPKGS_ALLOW_UNFREE=1 nix build --impure .#myPackage

# NixOS configuration.nix
nixpkgs.config.allowUnfree = true;
```

### Broken Packages

```
error: Package 'foo-1.0' is marked as broken, refusing to evaluate.
```

```nix
# Allow broken packages (use cautiously)
pkgs = import nixpkgs { inherit system; config.allowBroken = true; };
# Or per-package
nixpkgs.config.allowBrokenPredicate = pkg: builtins.elem (lib.getName pkg) [ "foo" ];

# CLI override
NIXPKGS_ALLOW_BROKEN=1 nix build --impure .#pkg
```

### Insecure Packages

```nix
# Packages with known CVEs
nixpkgs.config.permittedInsecurePackages = [ "openssl-1.1.1w" ];
# CLI: NIXPKGS_ALLOW_INSECURE=1 nix build --impure
```

---

## Nix Store Corruption

### Symptoms
- `hash mismatch importing path` on local builds
- `database is malformed` or SQLite errors
- Builds fail with missing dependencies that should exist

### Diagnosis

```bash
# Verify all store paths
nix store verify --all --no-trust 2>&1 | head -50

# Check SQLite database integrity
sudo sqlite3 /nix/var/nix/db/db.sqlite "PRAGMA integrity_check;"

# Check disk health
sudo dmesg | grep -i "error\|fault\|corrupt"
```

### Recovery

```bash
# Repair specific path
nix store repair /nix/store/<hash>-<name>

# Repair everything (slow but thorough)
nix store verify --all --repair

# If SQLite is corrupt — dump and rebuild
sudo systemctl stop nix-daemon
sudo cp /nix/var/nix/db/db.sqlite /nix/var/nix/db/db.sqlite.bak
sudo sqlite3 /nix/var/nix/db/db.sqlite.bak ".dump" | sudo sqlite3 /nix/var/nix/db/db.sqlite.new
sudo mv /nix/var/nix/db/db.sqlite.new /nix/var/nix/db/db.sqlite
sudo systemctl start nix-daemon

# Nuclear option: rebuild from binary cache
nix store verify --all --repair --substituters "https://cache.nixos.org"
```

### Prevention
- Use ECC RAM if possible
- Avoid force-killing nix-daemon during builds
- Don't manually modify `/nix/store`

---

## Garbage Collection Issues

### Store Growing Unbounded

```bash
# Check store size
du -sh /nix/store
nix store info

# Find GC roots (what prevents collection)
nix-store --gc --print-roots | head -30

# Common root sources:
# - result symlinks in project directories
# - /nix/var/nix/profiles/* (old generations)
# - Home Manager generations
# - NixOS system profiles

# Remove old generations first
sudo nix-env --delete-generations +5          # keep last 5
sudo nix-collect-garbage --delete-older-than 30d
home-manager expire-generations "-30 days"

# Then collect garbage
nix store gc
nix store optimise   # deduplicate identical files via hardlinks
```

### GC Deletes Too Much

```bash
# Protect a store path from GC by creating a root
nix-store --add-root /nix/var/nix/gcroots/my-app -r $(nix build --print-out-paths .#myApp)

# Protect current development environment
nix build .#devShells.x86_64-linux.default -o /nix/var/nix/gcroots/my-devshell
```

### GC Hangs or Errors

```bash
# If GC hangs, check for stale locks
ls -la /nix/var/nix/gc.lock
# Remove if stale (ensure no nix-daemon is running)

# Restart daemon and retry
sudo systemctl restart nix-daemon
nix store gc
```

---

## Flake Lock Conflicts

### Git Merge Conflicts in flake.lock

```bash
# Don't manually resolve flake.lock — regenerate it
git checkout --theirs flake.lock   # or --ours
nix flake update
git add flake.lock
```

### Input Version Mismatch

```nix
# Problem: dependency pulls its own nixpkgs, duplicating closure
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  home-manager.url = "github:nix-community/home-manager";
  # Fix: force home-manager to use our nixpkgs
  home-manager.inputs.nixpkgs.follows = "nixpkgs";
};
```

### Updating Specific Inputs

```bash
nix flake lock --update-input nixpkgs          # Update just nixpkgs
nix flake lock --override-input nixpkgs github:NixOS/nixpkgs/nixos-24.11  # Pin specific ref

# Verify lock contents
nix flake metadata  # Shows resolved revisions
```

### Flake Won't Lock (dirty tree)

```bash
# Error: "will not write modified lock file of flake 'path:...' to disk"
git add flake.nix          # flake.nix must be tracked by git
nix flake update           # now it can write flake.lock

# Workaround for testing without committing:
nix build --override-input nixpkgs github:NixOS/nixpkgs/nixos-unstable
```

---

## Channel vs Flake Mixing

### Problem
Using `<nixpkgs>` (channel) in a flake context or mixing both systems.

```nix
# BAD: using channel lookup in a flake
{ pkgs ? import <nixpkgs> {} }:  # <nixpkgs> not available in pure flake eval

# GOOD: accept pkgs as argument from flake.nix
{ pkgs }:
```

### Migration Pattern

```nix
# Legacy default.nix — make it callable from both flake and channel
{ pkgs ? import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {} }:
pkgs.callPackage ./package.nix {}

# Proper flake wrapper
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { nixpkgs, ... }: {
    packages.x86_64-linux.default =
      (import nixpkgs { system = "x86_64-linux"; }).callPackage ./package.nix {};
  };
}
```

### Keep Both Working

```nix
# shell.nix as flake compat wrapper
(import (
  fetchTarball {
    url = "https://github.com/edolstra/flake-compat/archive/master.tar.gz";
    sha256 = "0000000000000000000000000000000000000000000000000000";
  }
) { src = ./.; }).shellNix
```

---

## macOS-Specific Issues

### Nix Breaks After macOS Update

```bash
# macOS updates can remove /nix volume mount
# Re-create the synthetic volume
echo 'nix' | sudo tee /etc/synthetic.conf
sudo diskutil apfs addVolume disk1 APFS nix -mountpoint /nix

# If using Determinate installer:
nix-installer repair

# Restart nix-daemon
sudo launchctl kickstart -k system/org.nixos.nix-daemon
```

### Sandbox Issues on macOS

```nix
# Some builds fail on macOS due to sandbox restrictions
# macOS sandbox is less complete than Linux — common workaround:
stdenv.mkDerivation {
  # For builds that need /usr/bin/security or other macOS tools
  sandboxPaths = [ "/usr/bin/security" "/System/Library" ];
}
```

### Framework and SDK Issues

```nix
# macOS builds needing Apple frameworks
buildInputs = with pkgs.darwin.apple_sdk.frameworks; [
  Security SystemConfiguration CoreServices Foundation AppKit
];

# If pkg-config can't find frameworks, add:
nativeBuildInputs = [ pkgs.pkg-config ];
PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";
```

### Rosetta / ARM Issues

```bash
# On Apple Silicon, some packages only have x86_64 binaries
# Use Rosetta transparent translation:
nix build --system x86_64-darwin .#package

# Or configure multi-arch in nix.conf:
extra-platforms = x86_64-darwin
```

---

## WSL Issues

### /nix/store Permissions

```bash
# WSL1 doesn't support changing ownership properly
# Use WSL2 instead. Verify:
wsl.exe -l -v   # should show VERSION 2

# If filesystem is case-insensitive, add to /etc/wsl.conf:
[automount]
options = "case=dir"
```

### Systemd Not Available (WSL1/older WSL2)

```bash
# Modern WSL2 supports systemd — enable in /etc/wsl.conf:
[boot]
systemd=true

# Without systemd, start nix-daemon manually:
sudo nix-daemon &
```

### Memory Issues in WSL

```bash
# WSL may use too much memory. Limit in %USERPROFILE%/.wslconfig:
[wsl2]
memory=8GB
swap=4GB

# Nix builds can be memory-heavy — limit parallel builds:
# /etc/nix/nix.conf
max-jobs = 2
cores = 4
```

### Filesystem Performance

```bash
# Windows filesystem (via /mnt/c) is very slow for Nix
# Always keep nix projects on the Linux filesystem (/home/user/...)
# NOT on /mnt/c/Users/...
```

---

## Common Error Messages Decoded

### `error: attribute 'X' missing`
```
# Missing attribute in attrset. Check spelling, ensure the package/option exists.
# Debug: nix repl, load the attrset, check with tab completion
nix repl --expr 'import <nixpkgs> {}'
# Then type: pkgs.<Tab> to explore
```

### `error: infinite recursion encountered`
```
# Usually: an overlay referencing final where it should use prev
# Or: a module creating circular mkIf dependencies
# Fix: trace which attribute is recursive:
nix build .#pkg --show-trace 2>&1 | head -100
```

### `error: collision between '...' and '...'`
```
# Two packages install files to the same path
# Fix: use lib.hiPrio or change package priority
environment.systemPackages = [
  (lib.hiPrio pkgs.coreutils-full)   # wins over busybox
  pkgs.busybox
];
```

### `error: cannot build on 'aarch64-linux'`
```bash
# Cross-system build needed. Options:
# 1. Remote builder: add to /etc/nix/machines
# 2. QEMU emulation:
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
# 3. Use a different system in your flake
nix build .#packages.x86_64-linux.default
```

### `error: path '...' is not valid`
```bash
# Store path referenced but not present. Usually after interrupted GC or manual deletion.
nix store repair /nix/store/<path>
# Or rebuild from cache:
nix-store -r /nix/store/<path>
```

### `error: experimental Nix feature 'X' is disabled`
```bash
# Enable the feature in nix.conf:
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
# Or per-command:
nix --extra-experimental-features "nix-command flakes" build
```

### `error: file 'nixpkgs' was not found in the Nix search path`
```bash
# Channel not configured, or using flakes without channel
nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs
nix-channel --update
# Better: migrate to flakes and stop using <nixpkgs>
```

---

## Diagnostic Commands

```bash
# System info
nix --version
nix doctor                         # Check system health
nix show-config                    # Current nix configuration

# Store diagnostics
nix store info                     # Store summary
nix path-info -rSh /nix/store/... # Closure size of a path
nix why-depends .#a .#b           # Why does A depend on B?
nix derivation show .#pkg         # Show derivation inputs/outputs

# Build debugging
nix build .#pkg --show-trace      # Full evaluation trace on error
nix build .#pkg -L                # Stream build logs
nix log /nix/store/...            # View build log of a store path
nix build .#pkg --keep-failed     # Keep build dir on failure (inspect $TMPDIR)

# Flake diagnostics
nix flake metadata                # Show all input revisions
nix flake show                    # Display all outputs
nix flake check                   # Run checks and verify eval

# Repl for exploration
nix repl --expr 'import <nixpkgs> {}'
# or with flake
nix repl .#                       # Load current flake
```
