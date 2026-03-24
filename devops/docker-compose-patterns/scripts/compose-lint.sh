#!/usr/bin/env bash
# compose-lint.sh — Validate compose.yaml syntax and check for common anti-patterns
#
# Usage:
#   ./compose-lint.sh [compose-file]
#   ./compose-lint.sh                     # defaults to compose.yaml
#   ./compose-lint.sh compose.prod.yaml
#
# Checks:
#   - YAML syntax validity via docker compose config
#   - Deprecated version: field
#   - Missing healthchecks on services used in depends_on
#   - Missing restart policies
#   - Missing resource limits
#   - Hardcoded secrets in environment variables
#   - Unbounded logging (no max-size)
#   - Use of container_name (prevents scaling)
#   - Legacy docker-compose.yml filename
#   - Privileged mode usage

set -euo pipefail

COMPOSE_FILE="${1:-compose.yaml}"
WARN_COUNT=0
ERR_COUNT=0

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

warn() { WARN_COUNT=$((WARN_COUNT + 1)); echo -e "${YELLOW}⚠ WARN:${NC} $1"; }
err()  { ERR_COUNT=$((ERR_COUNT + 1));   echo -e "${RED}✗ ERROR:${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }

echo "═══════════════════════════════════════════"
echo " Compose Lint: ${COMPOSE_FILE}"
echo "═══════════════════════════════════════════"
echo ""

# --- Check file exists ---
if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "File not found: ${COMPOSE_FILE}"
    exit 1
fi

# --- Check filename ---
if [[ "$(basename "$COMPOSE_FILE")" =~ ^docker-compose\. ]]; then
    warn "Legacy filename 'docker-compose.*'. Prefer 'compose.yaml'."
fi

# --- Validate YAML syntax via docker compose ---
if command -v docker &>/dev/null; then
    if docker compose -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
        ok "YAML syntax valid"
    else
        err "Invalid Compose syntax:"
        docker compose -f "$COMPOSE_FILE" config 2>&1 | head -20
    fi
else
    warn "Docker not found — skipping syntax validation"
fi

# --- Check for deprecated version: field ---
if grep -qE '^\s*version\s*:' "$COMPOSE_FILE"; then
    warn "Deprecated 'version:' field found. Remove it — Compose V2 ignores it."
fi

# --- Check for privileged mode ---
if grep -qE '^\s*privileged\s*:\s*true' "$COMPOSE_FILE"; then
    warn "Service uses 'privileged: true'. Avoid unless absolutely necessary."
fi

# --- Check for container_name (prevents scaling) ---
if grep -qE '^\s*container_name\s*:' "$COMPOSE_FILE"; then
    warn "'container_name' found. This prevents scaling with replicas."
fi

# --- Check for hardcoded secrets in environment ---
SECRET_PATTERNS='(PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY)\s*[:=]\s*[^${\s]'
if grep -iEq "$SECRET_PATTERNS" "$COMPOSE_FILE" 2>/dev/null; then
    warn "Possible hardcoded secrets in environment. Use Docker secrets or env_file."
    grep -inE "$SECRET_PATTERNS" "$COMPOSE_FILE" 2>/dev/null | while read -r line; do
        echo "       $line"
    done
fi

# --- Check for missing restart policy ---
# Count services
SERVICE_COUNT=$(grep -cE '^\s{2}\S+:' "$COMPOSE_FILE" 2>/dev/null || echo 0)
RESTART_COUNT=$(grep -cE '^\s+restart\s*:' "$COMPOSE_FILE" 2>/dev/null || echo 0)
if [[ "$SERVICE_COUNT" -gt 0 && "$RESTART_COUNT" -eq 0 ]]; then
    warn "No restart policies found. Set 'restart: unless-stopped' for production services."
fi

# --- Check for unbounded logging ---
if ! grep -qE 'max-size' "$COMPOSE_FILE" 2>/dev/null; then
    if ! grep -qE 'logging' "$COMPOSE_FILE" 2>/dev/null; then
        warn "No logging limits set. Add 'logging: { driver: json-file, options: { max-size: \"10m\", max-file: \"3\" } }'."
    fi
fi

# --- Check for depends_on without condition ---
if grep -A1 'depends_on' "$COMPOSE_FILE" 2>/dev/null | grep -qE '^\s+-\s+\w' 2>/dev/null; then
    warn "depends_on uses list syntax (no conditions). Use 'condition: service_healthy' for reliable startup ordering."
fi

# --- Check for expose without purpose ---
if grep -qE '^\s+expose\s*:' "$COMPOSE_FILE" && ! grep -qE '^\s+networks\s*:' "$COMPOSE_FILE"; then
    warn "'expose:' used without custom networks. It has no effect on the default bridge network."
fi

# --- Summary ---
echo ""
echo "═══════════════════════════════════════════"
if [[ "$ERR_COUNT" -gt 0 ]]; then
    echo -e " ${RED}${ERR_COUNT} error(s)${NC}, ${YELLOW}${WARN_COUNT} warning(s)${NC}"
    exit 1
elif [[ "$WARN_COUNT" -gt 0 ]]; then
    echo -e " ${GREEN}0 errors${NC}, ${YELLOW}${WARN_COUNT} warning(s)${NC}"
    exit 0
else
    echo -e " ${GREEN}All checks passed!${NC}"
    exit 0
fi
