#!/usr/bin/env bash
# init-flake.sh — Initialize a new Nix flake project with a devShell for a chosen language
#
# Usage: init-flake.sh [language]
#   Supported languages: node, python, rust, go
#   If no language is specified, an interactive menu is shown.
#
# Creates: flake.nix, .envrc, .gitignore additions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [language]

Initialize a new Nix flake project with a language-specific devShell.

Supported languages:
  node     - Node.js (with pnpm, TypeScript)
  python   - Python 3.12 (with venv, pip, ruff)
  rust     - Rust stable (with rust-analyzer, clippy)
  go       - Go (with gopls, golangci-lint)

Options:
  -h, --help    Show this help message

Examples:
  $(basename "$0")           # Interactive language selection
  $(basename "$0") node      # Create Node.js flake
  $(basename "$0") rust      # Create Rust flake
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Check prerequisites
if ! command -v nix &>/dev/null; then
  echo "Error: 'nix' is not installed. Install from https://install.determinate.systems/nix" >&2
  exit 1
fi

if ! command -v git &>/dev/null; then
  echo "Error: 'git' is not installed." >&2
  exit 1
fi

# Select language
LANG="${1:-}"
if [[ -z "$LANG" ]]; then
  echo "Select a language for your devShell:"
  echo "  1) node     - Node.js"
  echo "  2) python   - Python"
  echo "  3) rust     - Rust"
  echo "  4) go       - Go"
  echo ""
  read -rp "Enter choice [1-4]: " choice
  case "$choice" in
    1) LANG="node" ;;
    2) LANG="python" ;;
    3) LANG="rust" ;;
    4) LANG="go" ;;
    *) echo "Invalid choice" >&2; exit 1 ;;
  esac
fi

# Validate language
case "$LANG" in
  node|python|rust|go) ;;
  *) echo "Error: Unsupported language '$LANG'. Use: node, python, rust, go" >&2; exit 1 ;;
esac

# Check if flake.nix already exists
if [[ -f "flake.nix" ]]; then
  read -rp "flake.nix already exists. Overwrite? [y/N]: " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

PROJECT_NAME="$(basename "$PWD")"
echo "Initializing $LANG flake for project '$PROJECT_NAME'..."

# Generate language-specific devShell content
generate_devshell() {
  case "$LANG" in
    node)
      cat <<'NIX'
      devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              nodejs_22
              nodePackages.pnpm
              nodePackages.typescript
              nodePackages.typescript-language-server
            ];

            shellHook = ''
              export PATH="$PWD/node_modules/.bin:$PATH"
              echo "🟢 Node.js $(node --version) | pnpm $(pnpm --version)"
            '';
          };
NIX
      ;;
    python)
      cat <<'NIX'
      devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              python312
              python312Packages.pip
              python312Packages.virtualenv
              ruff
              pyright
            ];

            shellHook = ''
              if [ ! -d .venv ]; then
                echo "Creating Python virtual environment..."
                python -m venv .venv
              fi
              source .venv/bin/activate
              echo "🐍 Python $(python --version | cut -d' ' -f2) | venv active"
            '';
          };
NIX
      ;;
    rust)
      cat <<'NIX'
      devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              cargo
              rustc
              rust-analyzer
              clippy
              rustfmt
              cargo-watch
            ];

            buildInputs = with pkgs; [ openssl ]
              ++ lib.optionals stdenv.isDarwin [
                darwin.apple_sdk.frameworks.Security
                darwin.apple_sdk.frameworks.SystemConfiguration
              ];

            nativeBuildInputs = with pkgs; [ pkg-config ];

            RUST_SRC_PATH = "${pkgs.rust.packages.stable.rustPlatform.rustLibSrc}";
            RUST_BACKTRACE = "1";

            shellHook = ''
              echo "🦀 Rust $(rustc --version | cut -d' ' -f2)"
            '';
          };
NIX
      ;;
    go)
      cat <<'NIX'
      devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              go_1_22
              gopls
              gotools
              golangci-lint
              delve
            ];

            CGO_ENABLED = "0";

            shellHook = ''
              export GOPATH="$PWD/.go"
              export GOBIN="$GOPATH/bin"
              export PATH="$GOBIN:$PATH"
              mkdir -p "$GOBIN"
              echo "🔵 $(go version | cut -d' ' -f3)"
            '';
          };
NIX
      ;;
  esac
}

# Write flake.nix
DEVSHELL_CONTENT="$(generate_devshell)"
cat > flake.nix <<FLAKE
{
  description = "${PROJECT_NAME} - ${LANG} project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
      in {
${DEVSHELL_CONTENT}
      });
}
FLAKE

# Write .envrc
if [[ ! -f ".envrc" ]]; then
  cat > .envrc <<'ENVRC'
use flake
ENVRC
  echo "Created .envrc"
else
  echo ".envrc already exists, skipping"
fi

# Update .gitignore
touch .gitignore
declare -a IGNORES=(".direnv" "result" "result-*")
case "$LANG" in
  python) IGNORES+=(".venv" "__pycache__" "*.egg-info") ;;
  go) IGNORES+=(".go") ;;
  node) IGNORES+=("node_modules") ;;
  rust) IGNORES+=("target") ;;
esac

for pattern in "${IGNORES[@]}"; do
  if ! grep -qxF "$pattern" .gitignore 2>/dev/null; then
    echo "$pattern" >> .gitignore
  fi
done
echo "Updated .gitignore"

# Initialize git if needed
if [[ ! -d ".git" ]]; then
  git init -q
  echo "Initialized git repository"
fi

# Stage flake.nix so Nix can see it
git add flake.nix .gitignore
[[ -f .envrc ]] && git add .envrc

echo ""
echo "✅ Flake initialized for $LANG!"
echo ""
echo "Next steps:"
echo "  1. nix develop          # Enter devShell"
echo "  2. direnv allow         # Auto-activate (if direnv installed)"
echo "  3. nix flake update     # Generate flake.lock"
