#!/usr/bin/env bash
# workflow-lint.sh — Lint GitHub Actions workflow files using actionlint.
#
# Usage:
#   ./workflow-lint.sh [workflow-file-or-dir]
#
# If no argument is given, lints all .yml/.yaml files in .github/workflows/.
# Installs actionlint automatically if not found.
#
# Examples:
#   ./workflow-lint.sh                                    # Lint all workflows
#   ./workflow-lint.sh .github/workflows/ci.yml           # Lint one file
#   ./workflow-lint.sh .github/workflows/                 # Lint directory

set -euo pipefail

ACTIONLINT_VERSION="1.7.7"

install_actionlint() {
  echo "📦 Installing actionlint v${ACTIONLINT_VERSION}..."

  local os arch url
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "❌ Unsupported architecture: $arch"
      exit 1
      ;;
  esac

  case "$os" in
    linux)
      url="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${os}_${arch}.tar.gz"
      local tmpdir
      tmpdir=$(mktemp -d)
      curl -sL "$url" | tar xz -C "$tmpdir"
      sudo mv "${tmpdir}/actionlint" /usr/local/bin/actionlint
      rm -rf "$tmpdir"
      ;;
    darwin)
      if command -v brew &>/dev/null; then
        brew install actionlint
      else
        url="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${os}_${arch}.tar.gz"
        local tmpdir
        tmpdir=$(mktemp -d)
        curl -sL "$url" | tar xz -C "$tmpdir"
        sudo mv "${tmpdir}/actionlint" /usr/local/bin/actionlint
        rm -rf "$tmpdir"
      fi
      ;;
    *)
      echo "❌ Unsupported OS: $os"
      echo "   Install actionlint manually: https://github.com/rhysd/actionlint"
      exit 1
      ;;
  esac

  echo "✅ actionlint installed: $(actionlint --version 2>&1 | head -1)"
}

# Check for actionlint
if ! command -v actionlint &>/dev/null; then
  echo "actionlint not found."
  install_actionlint
fi

TARGET="${1:-.github/workflows}"
EXIT_CODE=0

if [[ -f "$TARGET" ]]; then
  # Lint a single file
  echo "🔍 Linting: ${TARGET}"
  if actionlint "$TARGET"; then
    echo "✅ ${TARGET}: no issues found"
  else
    EXIT_CODE=1
  fi
elif [[ -d "$TARGET" ]]; then
  # Lint all workflow files in directory
  FILES=()
  while IFS= read -r -d '' f; do
    FILES+=("$f")
  done < <(find "$TARGET" -maxdepth 1 -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 2>/dev/null)

  if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "⚠  No .yml/.yaml files found in ${TARGET}"
    exit 0
  fi

  echo "🔍 Linting ${#FILES[@]} workflow file(s) in ${TARGET}/"
  echo ""

  PASS=0
  FAIL=0
  for f in "${FILES[@]}"; do
    if actionlint "$f" 2>&1; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      EXIT_CODE=1
    fi
  done

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Results: ${PASS} passed, ${FAIL} failed (${#FILES[@]} total)"
  if [[ $FAIL -eq 0 ]]; then
    echo "✅ All workflow files are valid"
  else
    echo "❌ ${FAIL} file(s) have issues"
  fi
else
  echo "❌ '${TARGET}' is not a file or directory"
  echo ""
  echo "Usage: $0 [workflow-file-or-dir]"
  echo "  Default: .github/workflows/"
  exit 1
fi

exit $EXIT_CODE
