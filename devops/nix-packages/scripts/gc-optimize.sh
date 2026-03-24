#!/usr/bin/env bash
# gc-optimize.sh — Nix store garbage collection and optimization helper
#
# Usage: gc-optimize.sh [command]
#   Commands:
#     status    - Show store size, root count, and generation info (default)
#     gc        - Run garbage collection (remove unreferenced paths)
#     gc-old    - Delete generations older than 30 days, then GC
#     optimize  - Deduplicate store via hardlinking
#     full      - gc-old + optimize (full cleanup)
#     roots     - List all GC roots
#     big       - Show largest store paths by closure size
#
# Options:
#   --days N   - Number of days for gc-old (default: 30)
#   -h, --help - Show this help message

set -euo pipefail

DAYS=30

usage() {
  cat <<EOF
Usage: $(basename "$0") [command] [options]

Nix store garbage collection and optimization helper.

Commands:
  status    Show store size, root count, and generations (default)
  gc        Run garbage collection
  gc-old    Delete old generations (--days N, default 30) then GC
  optimize  Deduplicate store files via hardlinks
  full      gc-old + optimize (full cleanup)
  roots     List all GC roots
  big       Show largest store paths by closure size

Options:
  --days N    Days threshold for gc-old (default: 30)
  -h, --help  Show this help

Examples:
  $(basename "$0")                # Show status
  $(basename "$0") gc             # Basic garbage collection
  $(basename "$0") gc-old --days 14   # Delete generations older than 14 days
  $(basename "$0") full           # Full cleanup
EOF
}

# Check prerequisites
if ! command -v nix &>/dev/null; then
  echo "Error: 'nix' is not installed." >&2
  exit 1
fi

# Parse arguments
COMMAND="status"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --days)
      DAYS="${2:-30}"
      shift 2
      ;;
    status|gc|gc-old|optimize|full|roots|big)
      COMMAND="$1"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Helper: format bytes
format_size() {
  local bytes="$1"
  if [[ "$bytes" -ge 1073741824 ]]; then
    echo "$(echo "scale=1; $bytes / 1073741824" | bc)G"
  elif [[ "$bytes" -ge 1048576 ]]; then
    echo "$(echo "scale=1; $bytes / 1048576" | bc)M"
  elif [[ "$bytes" -ge 1024 ]]; then
    echo "$(echo "scale=1; $bytes / 1024" | bc)K"
  else
    echo "${bytes}B"
  fi
}

# Helper: get store size
get_store_size() {
  du -sb /nix/store 2>/dev/null | cut -f1 || echo "0"
}

cmd_status() {
  echo "═══════════════════════════════════════"
  echo "  Nix Store Status"
  echo "═══════════════════════════════════════"
  echo ""

  # Store size
  local store_bytes
  store_bytes="$(get_store_size)"
  echo "Store size:       $(format_size "$store_bytes")"

  # Path count
  local path_count
  path_count="$(find /nix/store -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
  echo "Store paths:      $path_count"

  # GC roots
  local root_count
  root_count="$(nix-store --gc --print-roots 2>/dev/null | grep -cv '^$' || echo 0)"
  echo "GC roots:         $root_count"

  # Nix version
  echo "Nix version:      $(nix --version 2>/dev/null | head -1)"

  # System profiles
  echo ""
  echo "System generations:"
  if command -v nix-env &>/dev/null; then
    nix-env --list-generations 2>/dev/null | tail -5 || echo "  (none or no access)"
  fi

  # Home Manager generations
  if command -v home-manager &>/dev/null; then
    echo ""
    echo "Home Manager generations:"
    home-manager generations 2>/dev/null | tail -5 || echo "  (not available)"
  fi
  echo ""
}

cmd_gc() {
  echo "Running garbage collection..."
  local before
  before="$(get_store_size)"

  nix store gc 2>&1

  local after
  after="$(get_store_size)"
  local freed=$((before - after))
  echo ""
  echo "Freed: $(format_size $freed)"
  echo "Store size: $(format_size "$before") → $(format_size "$after")"
}

cmd_gc_old() {
  echo "Deleting generations older than ${DAYS} days..."

  # User profile generations
  nix-env --delete-generations "+5" 2>/dev/null || true

  # System-wide (requires sudo)
  if [[ -d /nix/var/nix/profiles/system ]]; then
    echo "Cleaning system generations (may require sudo)..."
    sudo nix-env --delete-generations --profile /nix/var/nix/profiles/system "+5" 2>/dev/null || true
  fi

  # Nix collect-garbage with time threshold
  echo "Running garbage collection for paths older than ${DAYS}d..."
  nix-collect-garbage --delete-older-than "${DAYS}d" 2>&1

  echo ""
  echo "Store size: $(format_size "$(get_store_size)")"
}

cmd_optimize() {
  echo "Optimizing store (deduplicating via hardlinks)..."
  echo "This may take a while for large stores."
  echo ""
  nix store optimise 2>&1
  echo ""
  echo "Store size after optimization: $(format_size "$(get_store_size)")"
}

cmd_full() {
  echo "═══════════════════════════════════════"
  echo "  Full Store Cleanup"
  echo "═══════════════════════════════════════"
  echo ""
  local before
  before="$(get_store_size)"

  cmd_gc_old
  echo ""
  echo "───────────────────────────────────────"
  echo ""
  cmd_optimize

  local after
  after="$(get_store_size)"
  local freed=$((before - after))
  echo ""
  echo "═══════════════════════════════════════"
  echo "Total freed: $(format_size $freed)"
  echo "Final store size: $(format_size "$after")"
  echo "═══════════════════════════════════════"
}

cmd_roots() {
  echo "GC Roots:"
  echo "───────────────────────────────────────"
  nix-store --gc --print-roots 2>/dev/null | sort
}

cmd_big() {
  echo "Largest store paths by closure size (top 20):"
  echo "───────────────────────────────────────"
  # Get all direct store paths, compute closure size, sort
  nix path-info --all -Sh 2>/dev/null \
    | sort -t$'\t' -k2 -h \
    | tail -20 \
    | tac
}

# Dispatch command
case "$COMMAND" in
  status)   cmd_status ;;
  gc)       cmd_gc ;;
  gc-old)   cmd_gc_old ;;
  optimize) cmd_optimize ;;
  full)     cmd_full ;;
  roots)    cmd_roots ;;
  big)      cmd_big ;;
esac
