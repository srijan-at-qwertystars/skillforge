#!/usr/bin/env bash
# setup-gleam.sh — Install Gleam language, Erlang/OTP, and create a sample project
#
# Usage:
#   ./setup-gleam.sh                  # Install Gleam + Erlang, create sample project
#   ./setup-gleam.sh --no-project     # Install only, skip project creation
#   ./setup-gleam.sh --project-name myapp  # Custom project name (default: hello_gleam)
#
# Supports: Ubuntu/Debian, macOS (Homebrew), Fedora/RHEL
# Requirements: curl, tar (Linux) or brew (macOS)

set -euo pipefail

GLEAM_VERSION="${GLEAM_VERSION:-1.9.1}"
PROJECT_NAME="hello_gleam"
CREATE_PROJECT=true

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-project)
      CREATE_PROJECT=false
      shift
      ;;
    --project-name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --gleam-version)
      GLEAM_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      head -10 "$0" | tail -8
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ── Detect OS ──────────────────────────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Linux*)  OS="linux" ;;
    Darwin*) OS="macos" ;;
    *)       error "Unsupported OS: $(uname -s)" ;;
  esac
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64)  ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *)             error "Unsupported architecture: $ARCH" ;;
  esac
  info "Detected: $OS ($ARCH)"
}

# ── Install Erlang/OTP ────────────────────────────────────────────────────────
install_erlang() {
  if command -v erl &>/dev/null; then
    local erl_version
    erl_version=$(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo "unknown")
    ok "Erlang/OTP $erl_version already installed"
    return
  fi

  info "Installing Erlang/OTP..."
  case "$OS" in
    macos)
      brew install erlang
      ;;
    linux)
      if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq erlang-dev erlang-nox erlang-src rebar3
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y erlang
      elif command -v yum &>/dev/null; then
        sudo yum install -y erlang
      else
        error "No supported package manager found. Install Erlang manually: https://www.erlang.org/downloads"
      fi
      ;;
  esac
  ok "Erlang/OTP installed"
}

# ── Install Gleam ─────────────────────────────────────────────────────────────
install_gleam() {
  if command -v gleam &>/dev/null; then
    local current
    current=$(gleam --version 2>/dev/null | awk '{print $2}')
    ok "Gleam $current already installed"
    return
  fi

  info "Installing Gleam v${GLEAM_VERSION}..."
  case "$OS" in
    macos)
      brew install gleam
      ;;
    linux)
      local target="gleam-v${GLEAM_VERSION}-${ARCH}-unknown-linux-musl.tar.gz"
      local url="https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/${target}"
      local tmpdir
      tmpdir=$(mktemp -d)
      info "Downloading $url"
      curl -sSL "$url" -o "${tmpdir}/gleam.tar.gz"
      tar -xzf "${tmpdir}/gleam.tar.gz" -C "${tmpdir}"
      sudo install -m 755 "${tmpdir}/gleam" /usr/local/bin/gleam
      rm -rf "$tmpdir"
      ;;
  esac
  ok "Gleam $(gleam --version 2>/dev/null | awk '{print $2}') installed"
}

# ── Install rebar3 (needed for Erlang compilation) ────────────────────────────
install_rebar3() {
  if command -v rebar3 &>/dev/null; then
    ok "rebar3 already installed"
    return
  fi

  info "Installing rebar3..."
  case "$OS" in
    macos)
      brew install rebar3
      ;;
    linux)
      local tmpdir
      tmpdir=$(mktemp -d)
      curl -sSL "https://s3.amazonaws.com/rebar3/rebar3" -o "${tmpdir}/rebar3"
      sudo install -m 755 "${tmpdir}/rebar3" /usr/local/bin/rebar3
      rm -rf "$tmpdir"
      ;;
  esac
  ok "rebar3 installed"
}

# ── Create Sample Project ────────────────────────────────────────────────────
create_project() {
  if [[ -d "$PROJECT_NAME" ]]; then
    warn "Directory '$PROJECT_NAME' already exists, skipping project creation"
    return
  fi

  info "Creating sample project: $PROJECT_NAME"
  gleam new "$PROJECT_NAME"
  cd "$PROJECT_NAME"

  info "Building project..."
  gleam build

  info "Running tests..."
  gleam test

  ok "Sample project '$PROJECT_NAME' created and verified!"
  echo ""
  echo "  cd $PROJECT_NAME"
  echo "  gleam run        # Run the app"
  echo "  gleam test       # Run tests"
  echo "  gleam add <pkg>  # Add a dependency"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  info "Gleam Setup Script"
  echo ""
  detect_os
  install_erlang
  install_rebar3
  install_gleam
  echo ""

  if $CREATE_PROJECT; then
    create_project
  else
    ok "Installation complete. Run 'gleam new myapp' to create a project."
  fi
}

main
