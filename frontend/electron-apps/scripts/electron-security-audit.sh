#!/usr/bin/env bash
# ============================================================================
# electron-security-audit.sh
# Audits an Electron project for common security misconfigurations.
#
# Usage:
#   ./electron-security-audit.sh [project-directory]
#
# If no directory is provided, audits the current directory.
#
# Checks performed:
#   - nodeIntegration enabled in BrowserWindow options
#   - contextIsolation disabled
#   - sandbox disabled
#   - webSecurity disabled
#   - allowRunningInsecureContent enabled
#   - Raw ipcRenderer exposed to renderer
#   - Remote module usage
#   - shell.openExternal without validation
#   - eval() or new Function() usage
#   - Insecure CSP or missing CSP
#   - Hardcoded secrets/credentials
#   - Outdated Electron version with known CVEs
#   - Missing permission handlers
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

PROJECT_DIR="${1:-.}"
ISSUES_FOUND=0
WARNINGS_FOUND=0

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo -e "${RED}Error: Directory '$PROJECT_DIR' does not exist.${NC}"
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/package.json" ]]; then
  echo -e "${RED}Error: No package.json found in '$PROJECT_DIR'. Is this a Node.js project?${NC}"
  exit 1
fi

echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Electron Security Audit${NC}"
echo -e "${BOLD}  Target: ${BLUE}$(cd "$PROJECT_DIR" && pwd)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""

issue() {
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
  echo -e "  ${RED}✗ ISSUE:${NC} $1"
  if [[ -n "${2:-}" ]]; then
    echo -e "    ${RED}→${NC} $2"
  fi
}

warning() {
  WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
  echo -e "  ${YELLOW}⚠ WARNING:${NC} $1"
  if [[ -n "${2:-}" ]]; then
    echo -e "    ${YELLOW}→${NC} $2"
  fi
}

ok() {
  echo -e "  ${GREEN}✓${NC} $1"
}

section() {
  echo -e "\n${BOLD}[$1]${NC}"
}

# Determine search directories (exclude node_modules, .git, dist, out, build output)
SEARCH_ARGS=(-r --include='*.js' --include='*.ts' --include='*.jsx' --include='*.tsx' --include='*.mjs' --include='*.cjs' -l)
SEARCH_CONTENT_ARGS=(-r --include='*.js' --include='*.ts' --include='*.jsx' --include='*.tsx' --include='*.mjs' --include='*.cjs' -n)
EXCLUDE_ARGS=(--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist --exclude-dir=out --exclude-dir=build --exclude-dir=.webpack --exclude-dir=.vite)

# ──────────────────────────────────────────────────────────
section "1. BrowserWindow Security Settings"
# ──────────────────────────────────────────────────────────

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'nodeIntegration\s*:\s*true' "$PROJECT_DIR" 2>/dev/null; then
  issue "nodeIntegration is enabled" "Set nodeIntegration: false (default). Allowing Node.js in renderer exposes full system access."
  grep "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'nodeIntegration\s*:\s*true' "$PROJECT_DIR" 2>/dev/null | head -5 | sed 's/^/    /'
else
  ok "nodeIntegration is not explicitly enabled"
fi

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'contextIsolation\s*:\s*false' "$PROJECT_DIR" 2>/dev/null; then
  issue "contextIsolation is disabled" "Set contextIsolation: true (default since v12). Without it, renderer can pollute preload prototypes."
  grep "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'contextIsolation\s*:\s*false' "$PROJECT_DIR" 2>/dev/null | head -5 | sed 's/^/    /'
else
  ok "contextIsolation is not disabled"
fi

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'sandbox\s*:\s*false' "$PROJECT_DIR" 2>/dev/null; then
  warning "sandbox is explicitly disabled in some windows" "Consider enabling sandbox: true for all windows (default since v20)."
  grep "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'sandbox\s*:\s*false' "$PROJECT_DIR" 2>/dev/null | head -5 | sed 's/^/    /'
else
  ok "sandbox is not disabled"
fi

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'webSecurity\s*:\s*false' "$PROJECT_DIR" 2>/dev/null; then
  issue "webSecurity is disabled" "Never disable webSecurity — it enforces same-origin policy."
  grep "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'webSecurity\s*:\s*false' "$PROJECT_DIR" 2>/dev/null | head -5 | sed 's/^/    /'
else
  ok "webSecurity is not disabled"
fi

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'allowRunningInsecureContent\s*:\s*true' "$PROJECT_DIR" 2>/dev/null; then
  issue "allowRunningInsecureContent is enabled" "Never allow insecure content in a secure context."
else
  ok "allowRunningInsecureContent is not enabled"
fi

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'experimentalFeatures\s*:\s*true' "$PROJECT_DIR" 2>/dev/null; then
  warning "experimentalFeatures is enabled" "Experimental Chromium features may have unpatched vulnerabilities."
else
  ok "experimentalFeatures is not enabled"
fi

# ──────────────────────────────────────────────────────────
section "2. IPC Security"
# ──────────────────────────────────────────────────────────

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'exposeInMainWorld.*ipcRenderer' "$PROJECT_DIR" 2>/dev/null; then
  RAW_EXPOSE=$(grep "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'exposeInMainWorld.*ipcRenderer[^.]' "$PROJECT_DIR" 2>/dev/null || true)
  if [[ -n "$RAW_EXPOSE" ]]; then
    issue "Raw ipcRenderer may be exposed to renderer" "Never pass the full ipcRenderer object. Wrap each channel in a named function."
    echo "$RAW_EXPOSE" | head -5 | sed 's/^/    /'
  else
    ok "ipcRenderer appears to be wrapped properly in contextBridge"
  fi
else
  ok "No direct ipcRenderer exposure detected"
fi

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'ipcRenderer\.sendSync' "$PROJECT_DIR" 2>/dev/null; then
  warning "Synchronous IPC (sendSync) detected" "Use invoke/handle instead. sendSync blocks the renderer."
  grep "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'ipcRenderer\.sendSync' "$PROJECT_DIR" 2>/dev/null | head -3 | sed 's/^/    /'
else
  ok "No synchronous IPC usage"
fi

# ──────────────────────────────────────────────────────────
section "3. Remote Module"
# ──────────────────────────────────────────────────────────

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" '@electron/remote\|enableRemoteModule\s*:\s*true' "$PROJECT_DIR" 2>/dev/null; then
  issue "Remote module usage detected" "The remote module bypasses security boundaries. Replace with explicit IPC."
  grep "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" '@electron/remote\|enableRemoteModule\s*:\s*true' "$PROJECT_DIR" 2>/dev/null | head -5 | sed 's/^/    /'
else
  ok "No remote module usage"
fi

# ──────────────────────────────────────────────────────────
section "4. Dangerous APIs"
# ──────────────────────────────────────────────────────────

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'shell\.openExternal' "$PROJECT_DIR" 2>/dev/null; then
  # Check if there's URL validation near the openExternal call
  OPEN_EXT_FILES=$(grep "${EXCLUDE_ARGS[@]}" "${SEARCH_ARGS[@]}" 'shell\.openExternal' "$PROJECT_DIR" 2>/dev/null || true)
  if [[ -n "$OPEN_EXT_FILES" ]]; then
    warning "shell.openExternal usage detected — ensure URLs are validated" "Only open https: URLs from a trusted allowlist."
    echo "$OPEN_EXT_FILES" | head -5 | sed 's/^/    /'
  fi
else
  ok "No shell.openExternal usage"
fi

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" '\beval\s*(' "$PROJECT_DIR" 2>/dev/null; then
  warning "eval() usage detected" "eval() can execute arbitrary code. Avoid in production."
  grep "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" '\beval\s*(' "$PROJECT_DIR" 2>/dev/null | head -5 | sed 's/^/    /'
else
  ok "No eval() usage"
fi

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'new\s\+Function\s*(' "$PROJECT_DIR" 2>/dev/null; then
  warning "new Function() usage detected" "Dynamic code generation can be exploited. Prefer static code."
else
  ok "No new Function() usage"
fi

# ──────────────────────────────────────────────────────────
section "5. Content Security Policy"
# ──────────────────────────────────────────────────────────

CSP_FOUND=false
if grep -rq "${EXCLUDE_ARGS[@]}" --include='*.js' --include='*.ts' --include='*.html' 'Content-Security-Policy' "$PROJECT_DIR" 2>/dev/null; then
  CSP_FOUND=true
  ok "Content Security Policy is configured"
  if grep -rq "${EXCLUDE_ARGS[@]}" --include='*.js' --include='*.ts' --include='*.html' "unsafe-eval" "$PROJECT_DIR" 2>/dev/null; then
    warning "CSP contains 'unsafe-eval'" "Remove unsafe-eval from production CSP."
  fi
else
  warning "No Content Security Policy detected" "Add a CSP header or meta tag to prevent XSS."
fi

# ──────────────────────────────────────────────────────────
section "6. Permission Handling"
# ──────────────────────────────────────────────────────────

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'setPermissionRequestHandler' "$PROJECT_DIR" 2>/dev/null; then
  ok "Permission request handler is configured"
else
  warning "No permission request handler" "Set session.setPermissionRequestHandler() to control camera, mic, geolocation access."
fi

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" 'setWindowOpenHandler' "$PROJECT_DIR" 2>/dev/null; then
  ok "Window open handler is configured"
else
  warning "No window open handler" "Set contents.setWindowOpenHandler() to control popup/new window creation."
fi

# ──────────────────────────────────────────────────────────
section "7. Navigation Restrictions"
# ──────────────────────────────────────────────────────────

if grep -q "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" "will-navigate" "$PROJECT_DIR" 2>/dev/null; then
  ok "Navigation handler (will-navigate) is registered"
else
  warning "No will-navigate handler" "Register a will-navigate handler to prevent navigation to untrusted URLs."
fi

# ──────────────────────────────────────────────────────────
section "8. Hardcoded Secrets"
# ──────────────────────────────────────────────────────────

SECRET_PATTERNS='api[_-]?key\s*[:=]\s*["\x27][A-Za-z0-9]\|secret\s*[:=]\s*["\x27][A-Za-z0-9]\|password\s*[:=]\s*["\x27][A-Za-z0-9]\|private[_-]?key\s*[:=]\s*["\x27]'
if grep -iq "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" "$SECRET_PATTERNS" "$PROJECT_DIR" 2>/dev/null; then
  warning "Potential hardcoded secrets detected" "Move secrets to environment variables or OS keychain (safeStorage)."
  grep -i "${EXCLUDE_ARGS[@]}" "${SEARCH_CONTENT_ARGS[@]}" "$SECRET_PATTERNS" "$PROJECT_DIR" 2>/dev/null | head -5 | sed 's/^/    /'
else
  ok "No obvious hardcoded secrets"
fi

# ──────────────────────────────────────────────────────────
section "9. Electron Version"
# ──────────────────────────────────────────────────────────

if [[ -f "$PROJECT_DIR/package.json" ]]; then
  ELECTRON_VER=$(node -e "
    try {
      const pkg = require('$PROJECT_DIR/package.json');
      const ver = (pkg.devDependencies || {}).electron || (pkg.dependencies || {}).electron || 'not found';
      console.log(ver.replace(/[\^~>=<]/g, ''));
    } catch(e) { console.log('error'); }
  " 2>/dev/null || echo "unknown")

  if [[ "$ELECTRON_VER" == "not found" || "$ELECTRON_VER" == "error" || "$ELECTRON_VER" == "unknown" ]]; then
    warning "Could not determine Electron version"
  else
    MAJOR_VER=$(echo "$ELECTRON_VER" | cut -d. -f1)
    echo -e "  ${BLUE}ℹ${NC} Electron version: $ELECTRON_VER"
    if [[ "$MAJOR_VER" -lt 28 ]]; then
      issue "Electron $ELECTRON_VER is outdated" "Upgrade to a supported version (28+). Older versions have known CVEs."
    elif [[ "$MAJOR_VER" -lt 30 ]]; then
      warning "Electron $ELECTRON_VER — consider upgrading to latest stable" "Newer versions include security patches and API improvements."
    else
      ok "Electron version is recent"
    fi
  fi
fi

# ──────────────────────────────────────────────────────────
section "10. npm Audit"
# ──────────────────────────────────────────────────────────

if command -v npm &>/dev/null && [[ -f "$PROJECT_DIR/package-lock.json" ]]; then
  AUDIT_OUTPUT=$(cd "$PROJECT_DIR" && npm audit --production 2>&1 || true)
  VULNERABILITIES=$(echo "$AUDIT_OUTPUT" | grep -o '[0-9]* vulnerabilities' | head -1 || echo "")
  if echo "$AUDIT_OUTPUT" | grep -q '0 vulnerabilities'; then
    ok "No known vulnerabilities in production dependencies"
  elif [[ -n "$VULNERABILITIES" ]]; then
    warning "npm audit found: $VULNERABILITIES" "Run 'npm audit fix' or review and update vulnerable packages."
  else
    echo -e "  ${BLUE}ℹ${NC} Run 'npm audit' manually to check for vulnerabilities"
  fi
else
  echo -e "  ${BLUE}ℹ${NC} Skipped npm audit (no package-lock.json or npm not available)"
fi

# ──────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Summary${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"

if [[ $ISSUES_FOUND -eq 0 && $WARNINGS_FOUND -eq 0 ]]; then
  echo -e "  ${GREEN}✓ No issues or warnings found. Looking good!${NC}"
elif [[ $ISSUES_FOUND -eq 0 ]]; then
  echo -e "  ${YELLOW}⚠ ${WARNINGS_FOUND} warning(s) found. Review recommended.${NC}"
else
  echo -e "  ${RED}✗ ${ISSUES_FOUND} issue(s) and ${WARNINGS_FOUND} warning(s) found. Action required.${NC}"
fi

echo ""
exit $ISSUES_FOUND
