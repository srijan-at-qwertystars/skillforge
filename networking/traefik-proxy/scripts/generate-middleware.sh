#!/usr/bin/env bash
#
# generate-middleware.sh — Generate Traefik middleware configurations
#
# Usage:
#   ./generate-middleware.sh TYPE [OPTIONS]
#
# Types:
#   auth          BasicAuth or ForwardAuth middleware
#   rate-limit    Rate limiting middleware
#   headers       Security headers middleware
#   redirect      HTTP→HTTPS or domain redirect middleware
#   cors          CORS headers middleware
#   compress      Compression middleware
#   circuit-breaker  Circuit breaker middleware
#   ip-allowlist  IP allowlist middleware
#   chain         Middleware chain combining multiple middlewares
#   all           Generate a complete middleware stack
#
# Options:
#   --name NAME        Middleware name (default: type name)
#   --format FORMAT    Output format: yaml, docker-labels, k8s-crd (default: yaml)
#   --output FILE      Write to file instead of stdout
#   --help             Show this help
#
# Examples:
#   ./generate-middleware.sh auth --name my-auth --format yaml
#   ./generate-middleware.sh rate-limit --format docker-labels
#   ./generate-middleware.sh headers --format k8s-crd --output security-headers.yaml
#   ./generate-middleware.sh all --output middlewares.yaml
#   ./generate-middleware.sh chain --name prod-stack
#

set -euo pipefail

TYPE=""
NAME=""
FORMAT="yaml"
OUTPUT=""

usage() {
    sed -n '3,30p' "$0" | sed 's/^# \?//'
    exit 0
}

parse_args() {
    if [[ $# -lt 1 ]]; then usage; fi

    TYPE="$1"; shift
    if [[ "$TYPE" == "--help" || "$TYPE" == "-h" ]]; then usage; fi
    NAME="${NAME:-$TYPE}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)   NAME="$2"; shift 2 ;;
            --format) FORMAT="$2"; shift 2 ;;
            --output) OUTPUT="$2"; shift 2 ;;
            --help|-h) usage ;;
            *) echo "Unknown option: $1" >&2; usage ;;
        esac
    done
}

emit() {
    if [[ -n "$OUTPUT" ]]; then
        cat >> "$OUTPUT"
    else
        cat
    fi
}

separator() {
    if [[ -n "$OUTPUT" ]]; then
        echo "" >> "$OUTPUT"
    else
        echo ""
    fi
}

# ─── Generators: YAML (File Provider) ────────────────────────────────────────

gen_auth_yaml() {
    cat <<YAML
http:
  middlewares:
    ${NAME}:
      basicAuth:
        # Generate: htpasswd -nbB admin password
        users:
          - "admin:\$2y\$05\$CHANGE_ME"
        removeHeader: true
        # Alternative: ForwardAuth (uncomment below, comment basicAuth above)
        # forwardAuth:
        #   address: "http://auth-service:4180/oauth2/auth"
        #   trustForwardHeader: true
        #   authResponseHeaders:
        #     - "X-Auth-Request-User"
        #     - "X-Auth-Request-Email"
        #   authRequestHeaders:
        #     - "Authorization"
        #     - "Cookie"
YAML
}

gen_rate_limit_yaml() {
    cat <<YAML
http:
  middlewares:
    ${NAME}:
      rateLimit:
        average: 100          # requests per period
        burst: 200            # max burst size
        period: 1s            # time window
        sourceCriterion:
          ipStrategy:
            depth: 1          # X-Forwarded-For depth (1 = trust 1 proxy)
            # excludedIPs:    # IPs to not rate-limit
            #   - "10.0.0.0/8"
          # OR rate-limit by header:
          # requestHeaderName: "X-API-Key"
          # OR rate-limit by host:
          # requestHost: true
YAML
}

gen_headers_yaml() {
    cat <<YAML
http:
  middlewares:
    ${NAME}:
      headers:
        # HTTPS enforcement
        sslRedirect: true
        forceSTSHeader: true
        stsSeconds: 63072000          # 2 years
        stsIncludeSubdomains: true
        stsPreload: true
        # Security headers
        contentTypeNosniff: true
        browserXssFilter: true
        frameDeny: true
        referrerPolicy: "strict-origin-when-cross-origin"
        permissionsPolicy: "camera=(), microphone=(), geolocation=()"
        # Custom headers
        customResponseHeaders:
          X-Robots-Tag: "noindex, nofollow"    # Remove if public-facing
        customRequestHeaders:
          X-Forwarded-Proto: "https"
YAML
}

gen_redirect_yaml() {
    cat <<YAML
http:
  middlewares:
    # HTTP → HTTPS redirect (usually done via entryPoint redirect instead)
    ${NAME}-https:
      redirectScheme:
        scheme: https
        permanent: true
    # www → apex redirect
    ${NAME}-www:
      redirectRegex:
        regex: "^https?://www\\.(.+)"
        replacement: "https://\${1}"
        permanent: true
    # Path-based redirect
    ${NAME}-path:
      redirectRegex:
        regex: "^https?://(.+)/old-path(.*)"
        replacement: "https://\${1}/new-path\${2}"
        permanent: true
YAML
}

gen_cors_yaml() {
    cat <<YAML
http:
  middlewares:
    ${NAME}:
      headers:
        accessControlAllowMethods:
          - "GET"
          - "POST"
          - "PUT"
          - "DELETE"
          - "OPTIONS"
        accessControlAllowHeaders:
          - "Content-Type"
          - "Authorization"
          - "X-Requested-With"
        accessControlAllowOriginList:
          - "https://app.example.com"
          # - "https://staging.example.com"
          # - "*"    # Allow all origins (use carefully)
        accessControlMaxAge: 3600
        accessControlExposeHeaders:
          - "X-Request-Id"
        addVaryHeader: true
YAML
}

gen_compress_yaml() {
    cat <<YAML
http:
  middlewares:
    ${NAME}:
      compress:
        excludedContentTypes:
          - "text/event-stream"     # SSE streams
          # - "application/grpc"   # gRPC (already compressed)
        minResponseBodyBytes: 1024  # Don't compress small responses
YAML
}

gen_circuit_breaker_yaml() {
    cat <<YAML
http:
  middlewares:
    ${NAME}:
      circuitBreaker:
        # Trip when >25% of responses are 5xx
        expression: "ResponseCodeRatio(500, 600, 0, 600) > 0.25"
        checkPeriod: 10s          # How often to evaluate expression
        fallbackDuration: 30s     # How long to stay open (return 503)
        recoveryDuration: 60s     # Half-open testing duration
        # Alternative expressions:
        # expression: "NetworkErrorRatio() > 0.10"
        # expression: "LatencyAtQuantileMS(95.0) > 2000"
        # expression: "ResponseCodeRatio(500, 600, 0, 600) > 0.25 || NetworkErrorRatio() > 0.10"
YAML
}

gen_ip_allowlist_yaml() {
    cat <<YAML
http:
  middlewares:
    ${NAME}:
      ipAllowList:
        sourceRange:
          - "10.0.0.0/8"          # Private networks
          - "172.16.0.0/12"
          - "192.168.0.0/16"
          # - "203.0.113.0/24"    # Specific public range
        ipStrategy:
          depth: 1                 # X-Forwarded-For depth
          # excludedIPs:
          #   - "127.0.0.1/32"
YAML
}

gen_chain_yaml() {
    cat <<YAML
http:
  middlewares:
    ${NAME}:
      chain:
        middlewares:
          - security-headers       # 1. Add security headers
          - rate-limit             # 2. Rate limit by IP
          - compress               # 3. Compress responses
          # - auth                 # 4. Authentication (uncomment if needed)
          # - circuit-breaker      # 5. Circuit breaker (uncomment if needed)
YAML
}

# ─── Generators: Docker Labels ────────────────────────────────────────────────

gen_auth_labels() {
    cat <<YAML
# Add these labels to your service in docker-compose.yml
labels:
  # BasicAuth — generate hash: htpasswd -nbB admin password (double \$\$ in compose)
  - "traefik.http.middlewares.${NAME}.basicauth.users=admin:\$\$2y\$\$05\$\$CHANGE_ME"
  - "traefik.http.middlewares.${NAME}.basicauth.removeheader=true"
  # Apply to router:
  - "traefik.http.routers.ROUTERNAME.middlewares=${NAME}"
YAML
}

gen_rate_limit_labels() {
    cat <<YAML
labels:
  - "traefik.http.middlewares.${NAME}.ratelimit.average=100"
  - "traefik.http.middlewares.${NAME}.ratelimit.burst=200"
  - "traefik.http.middlewares.${NAME}.ratelimit.period=1s"
  - "traefik.http.middlewares.${NAME}.ratelimit.sourcecriterion.ipstrategy.depth=1"
  - "traefik.http.routers.ROUTERNAME.middlewares=${NAME}"
YAML
}

gen_headers_labels() {
    cat <<YAML
labels:
  - "traefik.http.middlewares.${NAME}.headers.sslredirect=true"
  - "traefik.http.middlewares.${NAME}.headers.forcestsheader=true"
  - "traefik.http.middlewares.${NAME}.headers.stsseconds=63072000"
  - "traefik.http.middlewares.${NAME}.headers.stsincludesubdomains=true"
  - "traefik.http.middlewares.${NAME}.headers.stspreload=true"
  - "traefik.http.middlewares.${NAME}.headers.contenttypenosniff=true"
  - "traefik.http.middlewares.${NAME}.headers.browserxssfilter=true"
  - "traefik.http.middlewares.${NAME}.headers.framedeny=true"
  - "traefik.http.middlewares.${NAME}.headers.referrerpolicy=strict-origin-when-cross-origin"
  - "traefik.http.middlewares.${NAME}.headers.permissionspolicy=camera=(), microphone=(), geolocation=()"
  - "traefik.http.routers.ROUTERNAME.middlewares=${NAME}"
YAML
}

gen_redirect_labels() {
    cat <<YAML
labels:
  # www → apex redirect
  - "traefik.http.middlewares.${NAME}.redirectregex.regex=^https?://www\\\\.(.*)"
  - "traefik.http.middlewares.${NAME}.redirectregex.replacement=https://\$\${1}"
  - "traefik.http.middlewares.${NAME}.redirectregex.permanent=true"
  - "traefik.http.routers.ROUTERNAME.middlewares=${NAME}"
YAML
}

gen_cors_labels() {
    cat <<YAML
labels:
  - "traefik.http.middlewares.${NAME}.headers.accesscontrolallowmethods=GET,POST,PUT,DELETE,OPTIONS"
  - "traefik.http.middlewares.${NAME}.headers.accesscontrolallowheaders=Content-Type,Authorization"
  - "traefik.http.middlewares.${NAME}.headers.accesscontrolalloworiginlist=https://app.example.com"
  - "traefik.http.middlewares.${NAME}.headers.accesscontrolmaxage=3600"
  - "traefik.http.middlewares.${NAME}.headers.addvaryheader=true"
  - "traefik.http.routers.ROUTERNAME.middlewares=${NAME}"
YAML
}

gen_compress_labels() {
    cat <<YAML
labels:
  - "traefik.http.middlewares.${NAME}.compress=true"
  - "traefik.http.middlewares.${NAME}.compress.excludedcontenttypes=text/event-stream"
  - "traefik.http.routers.ROUTERNAME.middlewares=${NAME}"
YAML
}

gen_circuit_breaker_labels() {
    cat <<YAML
labels:
  - "traefik.http.middlewares.${NAME}.circuitbreaker.expression=ResponseCodeRatio(500, 600, 0, 600) > 0.25"
  - "traefik.http.middlewares.${NAME}.circuitbreaker.checkperiod=10s"
  - "traefik.http.middlewares.${NAME}.circuitbreaker.fallbackduration=30s"
  - "traefik.http.middlewares.${NAME}.circuitbreaker.recoveryduration=60s"
  - "traefik.http.routers.ROUTERNAME.middlewares=${NAME}"
YAML
}

gen_ip_allowlist_labels() {
    cat <<YAML
labels:
  - "traefik.http.middlewares.${NAME}.ipallowlist.sourcerange=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  - "traefik.http.middlewares.${NAME}.ipallowlist.ipstrategy.depth=1"
  - "traefik.http.routers.ROUTERNAME.middlewares=${NAME}"
YAML
}

gen_chain_labels() {
    cat <<YAML
labels:
  - "traefik.http.middlewares.${NAME}.chain.middlewares=security-headers,rate-limit,compress"
  - "traefik.http.routers.ROUTERNAME.middlewares=${NAME}"
YAML
}

# ─── Generators: Kubernetes CRDs ─────────────────────────────────────────────

gen_auth_crd() {
    cat <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${NAME}
  # namespace: traefik
spec:
  basicAuth:
    secret: ${NAME}-secret
    removeHeader: true
---
apiVersion: v1
kind: Secret
metadata:
  name: ${NAME}-secret
  # namespace: traefik
type: Opaque
stringData:
  users: |
    admin:\$2y\$05\$CHANGE_ME
YAML
}

gen_rate_limit_crd() {
    cat <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${NAME}
spec:
  rateLimit:
    average: 100
    burst: 200
    period: 1s
    sourceCriterion:
      ipStrategy:
        depth: 1
YAML
}

gen_headers_crd() {
    cat <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${NAME}
spec:
  headers:
    sslRedirect: true
    forceSTSHeader: true
    stsSeconds: 63072000
    stsIncludeSubdomains: true
    stsPreload: true
    contentTypeNosniff: true
    browserXssFilter: true
    frameDeny: true
    referrerPolicy: strict-origin-when-cross-origin
    permissionsPolicy: "camera=(), microphone=(), geolocation=()"
YAML
}

gen_redirect_crd() {
    cat <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${NAME}
spec:
  redirectRegex:
    regex: "^https?://www\\\\.(.*)"
    replacement: "https://\${1}"
    permanent: true
YAML
}

gen_cors_crd() {
    cat <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${NAME}
spec:
  headers:
    accessControlAllowMethods:
      - GET
      - POST
      - PUT
      - DELETE
      - OPTIONS
    accessControlAllowHeaders:
      - Content-Type
      - Authorization
    accessControlAllowOriginList:
      - "https://app.example.com"
    accessControlMaxAge: 3600
    addVaryHeader: true
YAML
}

gen_compress_crd() {
    cat <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${NAME}
spec:
  compress:
    excludedContentTypes:
      - text/event-stream
YAML
}

gen_circuit_breaker_crd() {
    cat <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${NAME}
spec:
  circuitBreaker:
    expression: "ResponseCodeRatio(500, 600, 0, 600) > 0.25"
    checkPeriod: 10s
    fallbackDuration: 30s
    recoveryDuration: 60s
YAML
}

gen_ip_allowlist_crd() {
    cat <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${NAME}
spec:
  ipAllowList:
    sourceRange:
      - "10.0.0.0/8"
      - "172.16.0.0/12"
      - "192.168.0.0/16"
    ipStrategy:
      depth: 1
YAML
}

gen_chain_crd() {
    cat <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${NAME}
spec:
  chain:
    middlewares:
      - name: security-headers
      - name: rate-limit
      - name: compress
YAML
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────

generate() {
    local type="$1"
    local suffix=""

    case "$FORMAT" in
        yaml)          suffix="yaml" ;;
        docker-labels) suffix="labels" ;;
        k8s-crd)       suffix="crd" ;;
        *) echo "Unknown format: $FORMAT (use yaml, docker-labels, k8s-crd)" >&2; exit 1 ;;
    esac

    local func="gen_${type//-/_}_${suffix}"

    if declare -f "$func" >/dev/null 2>&1; then
        "$func" | emit
    else
        echo "No generator for type '${type}' with format '${FORMAT}'" >&2
        exit 1
    fi
}

generate_all() {
    if [[ -n "$OUTPUT" ]]; then
        > "$OUTPUT"    # Truncate output file
    fi

    echo "# Traefik Middleware Stack" | emit
    echo "# Generated by generate-middleware.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)" | emit
    separator

    for mtype in headers rate-limit compress auth circuit-breaker ip-allowlist chain; do
        NAME="$mtype"
        echo "# --- ${mtype} ---" | emit
        generate "$mtype"
        separator
    done

    if [[ -n "$OUTPUT" ]]; then
        echo "Generated complete middleware stack → ${OUTPUT}"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

parse_args "$@"

if [[ -n "$OUTPUT" ]]; then
    > "$OUTPUT"    # Truncate output file
fi

if [[ "$TYPE" == "all" ]]; then
    generate_all
else
    generate "$TYPE"
fi
