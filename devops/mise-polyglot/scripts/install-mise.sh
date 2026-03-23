#!/usr/bin/env bash
# install-mise.sh — Install mise and configure shell activation
# Usage: ./install-mise.sh [--no-activate]
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✖${NC} $*" >&2; }

NO_ACTIVATE=false
for arg in "$@"; do
  case "$arg" in
    --no-activate) NO_ACTIVATE=true ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--no-activate]"
      echo ""
      echo "Install mise and configure shell activation."
      echo ""
      echo "Options:"
      echo "  --no-activate   Install mise but skip shell configuration"
      echo "  -h, --help      Show this help message"
      exit 0
      ;;
    *)
      err "Unknown option: $arg"
      exit 1
      ;;
  esac
done

# --- Check for existing installation ---
if command -v mise &>/dev/null; then
  CURRENT_VERSION=$(mise --version 2>/dev/null | head -1)
  warn "mise is already installed: $CURRENT_VERSION"
  read -rp "Reinstall/upgrade? [y/N] " answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    info "Skipping installation."
    exit 0
  fi
fi

# --- Install mise ---
info "Installing mise..."
if command -v curl &>/dev/null; then
  curl -fsSL https://mise.run | sh
elif command -v wget &>/dev/null; then
  wget -qO- https://mise.run | sh
else
  err "Neither curl nor wget found. Please install one and retry."
  exit 1
fi

# Ensure mise is on PATH for this script
export PATH="$HOME/.local/bin:$PATH"

if ! command -v mise &>/dev/null; then
  err "mise installation failed. Binary not found at ~/.local/bin/mise"
  exit 1
fi

MISE_VERSION=$(mise --version 2>/dev/null | head -1)
ok "mise installed: $MISE_VERSION"

# --- Detect shell ---
detect_shell() {
  local shell_name
  shell_name=$(basename "${SHELL:-/bin/bash}")
  echo "$shell_name"
}

DETECTED_SHELL=$(detect_shell)
info "Detected shell: $DETECTED_SHELL"

# --- Configure shell activation ---
if [[ "$NO_ACTIVATE" == "true" ]]; then
  warn "Skipping shell activation (--no-activate flag)."
  echo ""
  info "To activate manually, add to your shell rc:"
  echo '  eval "$(mise activate bash)"     # for bash'
  echo '  eval "$(mise activate zsh)"      # for zsh'
  echo '  mise activate fish | source      # for fish'
  exit 0
fi

configure_shell() {
  local shell_name="$1"
  local rc_file=""
  local activation_line=""

  case "$shell_name" in
    bash)
      rc_file="$HOME/.bashrc"
      activation_line='eval "$(mise activate bash)"'
      ;;
    zsh)
      rc_file="$HOME/.zshrc"
      activation_line='eval "$(mise activate zsh)"'
      ;;
    fish)
      rc_file="$HOME/.config/fish/config.fish"
      activation_line='mise activate fish | source'
      ;;
    *)
      warn "Unsupported shell: $shell_name"
      warn "Add mise activation manually to your shell rc file."
      echo '  eval "$(mise activate bash)"   # bash example'
      return 1
      ;;
  esac

  # Check if already configured
  if [[ -f "$rc_file" ]] && grep -qF "mise activate" "$rc_file"; then
    ok "Shell activation already configured in $rc_file"
    return 0
  fi

  # Create rc file directory if needed (for fish)
  mkdir -p "$(dirname "$rc_file")"

  # Append activation line
  echo "" >> "$rc_file"
  echo "# mise (polyglot dev tool manager)" >> "$rc_file"
  echo "$activation_line" >> "$rc_file"

  ok "Added mise activation to $rc_file"
  return 0
}

configure_shell "$DETECTED_SHELL"

# --- Verify ---
echo ""
info "Verifying installation..."
mise --version
ok "mise is ready!"

echo ""
info "Next steps:"
echo "  1. Restart your shell or run: source ~/$(basename "$(detect_shell)")rc"
echo "  2. Run 'mise doctor' to verify setup"
echo "  3. Run 'mise use node@20' to install your first tool"
