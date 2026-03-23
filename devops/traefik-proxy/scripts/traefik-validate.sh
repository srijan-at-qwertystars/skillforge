#!/usr/bin/env bash
set -euo pipefail

# Validate Traefik static and dynamic configuration files.
# Usage: traefik-validate.sh [--static FILE] [--dynamic FILE|DIR] [--docker-compose FILE]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

errors=0
warnings=0

log_ok()   { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; ((warnings++)) || true; }
log_err()  { echo -e "${RED}✗${NC} $1"; ((errors++)) || true; }

check_command() {
    if ! command -v "$1" &>/dev/null; then
        log_err "Required command '$1' not found. Install it to continue."
        exit 1
    fi
}

validate_yaml() {
    local file="$1"
    local label="$2"
    if ! python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$file" 2>/dev/null; then
        if ! yq eval '.' "$file" >/dev/null 2>&1; then
            log_err "$label: Invalid YAML syntax in $file"
            return 1
        fi
    fi
    log_ok "$label: Valid YAML syntax"
    return 0
}

validate_static() {
    local file="$1"
    echo ""
    echo "=== Validating static config: $file ==="

    validate_yaml "$file" "Static" || return

    local content
    content=$(cat "$file")

    # Check entrypoints
    if echo "$content" | grep -q "entryPoints"; then
        log_ok "Static: entryPoints defined"
    else
        log_warn "Static: No entryPoints found — Traefik will use defaults (:80)"
    fi

    # Check providers
    if echo "$content" | grep -q "providers"; then
        log_ok "Static: providers section found"
    else
        log_err "Static: No providers configured — Traefik will have no route sources"
    fi

    # Check api.insecure
    if echo "$content" | grep -q "insecure: true\|insecure:true"; then
        log_warn "Static: api.insecure is true — do NOT use in production"
    fi

    # Check exposedByDefault
    if echo "$content" | grep -q "exposedByDefault: true\|exposedByDefault:true"; then
        log_warn "Static: exposedByDefault is true — all containers will be exposed"
    fi

    # Check certificatesResolvers
    if echo "$content" | grep -q "certificatesResolvers"; then
        log_ok "Static: certificatesResolvers configured"
        if echo "$content" | grep -q "storage:"; then
            log_ok "Static: ACME storage path defined"
        else
            log_err "Static: certificatesResolvers without storage path — certs will be lost on restart"
        fi
    fi

    # Check log level
    if echo "$content" | grep -q "level: DEBUG\|level:DEBUG"; then
        log_warn "Static: Log level set to DEBUG — very verbose, not recommended for production"
    fi
}

validate_dynamic() {
    local file="$1"
    echo ""
    echo "=== Validating dynamic config: $file ==="

    validate_yaml "$file" "Dynamic" || return

    local content
    content=$(cat "$file")

    # Check for deprecated v2 syntax
    if echo "$content" | grep -q "ipWhiteList"; then
        log_err "Dynamic: 'ipWhiteList' is deprecated in v3 — use 'ipAllowList'"
    fi

    if echo "$content" | grep -q "stripPrefixRegex"; then
        log_warn "Dynamic: 'stripPrefixRegex' — verify this is still supported in your version"
    fi

    # Check middleware references in routers
    if echo "$content" | grep -q "middlewares:"; then
        log_ok "Dynamic: Middleware references found"
    fi

    # Check for routers without TLS on websecure
    if echo "$content" | grep -q "entryPoints:.*websecure\|entrypoints:.*websecure"; then
        if ! echo "$content" | grep -q "tls:"; then
            log_warn "Dynamic: Router uses websecure entrypoint but no TLS config found"
        fi
    fi

    # Check health checks on services
    if echo "$content" | grep -q "loadBalancer:"; then
        if ! echo "$content" | grep -q "healthCheck:"; then
            log_warn "Dynamic: loadBalancer services without healthCheck — unhealthy backends may receive traffic"
        fi
    fi

    log_ok "Dynamic: $file validated"
}

validate_docker_compose() {
    local file="$1"
    echo ""
    echo "=== Validating Docker Compose: $file ==="

    validate_yaml "$file" "Compose" || return

    local content
    content=$(cat "$file")

    # Check for docker.sock mount
    if echo "$content" | grep -q "docker.sock"; then
        if echo "$content" | grep -q "docker.sock:ro\|docker.sock.*:ro"; then
            log_ok "Compose: docker.sock mounted read-only"
        else
            log_warn "Compose: docker.sock not mounted read-only — security risk"
        fi
    fi

    # Check no-new-privileges
    if echo "$content" | grep -q "no-new-privileges"; then
        log_ok "Compose: no-new-privileges security option set"
    else
        log_warn "Compose: Consider adding security_opt: [no-new-privileges:true]"
    fi

    # Check for api.insecure in command/labels
    if echo "$content" | grep -q "api.insecure=true\|insecure: true"; then
        log_warn "Compose: api.insecure found — remove for production"
    fi

    # Check for network definition
    if echo "$content" | grep -q "networks:"; then
        log_ok "Compose: Networks defined"
    else
        log_warn "Compose: No dedicated network — use a named 'proxy' network"
    fi

    # Check for volume persistence
    if echo "$content" | grep -q "letsencrypt\|acme"; then
        log_ok "Compose: Certificate storage volume found"
    fi

    log_ok "Compose: $file validated"
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Validate Traefik configuration files."
    echo ""
    echo "Options:"
    echo "  --static FILE          Validate a static configuration file (traefik.yml)"
    echo "  --dynamic FILE|DIR     Validate dynamic config file(s) or directory"
    echo "  --docker-compose FILE  Validate a Docker Compose file with Traefik"
    echo "  --all DIR              Validate all .yml/.yaml files in directory"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --static traefik.yml"
    echo "  $0 --dynamic ./dynamic/"
    echo "  $0 --static traefik.yml --dynamic dynamic-config.yml --docker-compose docker-compose.yml"
    echo "  $0 --all /etc/traefik/"
}

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

# Check for python3 or yq
if ! command -v python3 &>/dev/null && ! command -v yq &>/dev/null; then
    log_err "Either python3 (with PyYAML) or yq is required for YAML validation"
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --static)
            [[ -f "$2" ]] || { log_err "File not found: $2"; exit 1; }
            validate_static "$2"
            shift 2
            ;;
        --dynamic)
            if [[ -d "$2" ]]; then
                for f in "$2"/*.{yml,yaml} 2>/dev/null; do
                    [[ -f "$f" ]] && validate_dynamic "$f"
                done
            elif [[ -f "$2" ]]; then
                validate_dynamic "$2"
            else
                log_err "File or directory not found: $2"
                exit 1
            fi
            shift 2
            ;;
        --docker-compose)
            [[ -f "$2" ]] || { log_err "File not found: $2"; exit 1; }
            validate_docker_compose "$2"
            shift 2
            ;;
        --all)
            if [[ -d "$2" ]]; then
                for f in "$2"/*.{yml,yaml} 2>/dev/null; do
                    [[ -f "$f" ]] || continue
                    case "$(basename "$f")" in
                        traefik.yml|traefik.yaml) validate_static "$f" ;;
                        docker-compose*) validate_docker_compose "$f" ;;
                        *) validate_dynamic "$f" ;;
                    esac
                done
            else
                log_err "Directory not found: $2"
                exit 1
            fi
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_err "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo ""
echo "================================"
echo -e "Results: ${GREEN}passed${NC}, ${YELLOW}${warnings} warning(s)${NC}, ${RED}${errors} error(s)${NC}"
if [[ $errors -gt 0 ]]; then
    echo -e "${RED}Validation failed.${NC}"
    exit 1
else
    echo -e "${GREEN}Validation passed.${NC}"
    exit 0
fi
