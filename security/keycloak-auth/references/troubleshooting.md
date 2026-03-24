# Keycloak Troubleshooting Guide

## Table of Contents

- [Token Validation Failures](#token-validation-failures)
- [Redirect URI Mismatches](#redirect-uri-mismatches)
- [CORS Configuration Problems](#cors-configuration-problems)
- [LDAP Sync Failures and Pagination](#ldap-sync-failures-and-pagination)
- [Session Management Issues](#session-management-issues)
- [Database Migration Issues During Upgrades](#database-migration-issues-during-upgrades)
- [Theme Caching During Development](#theme-caching-during-development)
- [TLS / Certificate Configuration](#tls--certificate-configuration)
- [Behind Reverse Proxy](#behind-reverse-proxy)
- [Memory / CPU Tuning for Production](#memory--cpu-tuning-for-production)
- [Infinispan Cache Tuning](#infinispan-cache-tuning)

---

## Token Validation Failures

### Clock Skew

**Symptom**: Token validation fails intermittently with "token not yet valid" or
"token expired" errors even though the token was just issued.

**Cause**: Clock difference between the Keycloak server and the resource server.

**Diagnosis**:

```bash
# Compare times on Keycloak server vs resource server
date -u  # run on both machines

# Decode token and check timestamps
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iat: .iat, exp: .exp, nbf: .nbf}'

# Convert epoch to human-readable
date -d @$(echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.iat')
```

**Fix**:

```bash
# Sync NTP on both servers
sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd

# In application code, add clock skew tolerance
# Spring Boot:
spring.security.oauth2.resourceserver.jwt.clock-skew=30s

# Node.js (jsonwebtoken):
jwt.verify(token, key, { clockTolerance: 30 });  // 30 seconds tolerance

# Go (go-jose):
claims.ValidateWithLeeway(jwt.Expected{Time: time.Now()}, 30*time.Second)
```

### Audience Mismatch

**Symptom**: `invalid_token` error with "audience not valid" or "aud claim missing".

**Cause**: The `aud` claim in the access token doesn't include the client ID of the
resource server validating the token.

**Diagnosis**:

```bash
# Check the aud claim in the token
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.aud'
# Example output: "account"  — wrong! Should be your resource server's client ID
```

**Fix**:

1. Add an "audience" protocol mapper to the client scope:
   ```bash
   # Via Admin API — add audience mapper to the client
   curl -X POST "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID/protocol-mappers/models" \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{
       "name": "resource-server-audience",
       "protocol": "openid-connect",
       "protocolMapper": "oidc-audience-mapper",
       "config": {
         "included.client.audience": "my-resource-server",
         "id.token.claim": "false",
         "access.token.claim": "true"
       }
     }'
   ```

2. Or configure the resource server to not validate audience:
   ```yaml
   # Spring Boot — disable audience validation (less secure)
   spring:
     security:
       oauth2:
         resourceserver:
           jwt:
             audiences: []  # accepts any audience
   ```

### Wrong Issuer URL

**Symptom**: `invalid_issuer` error during token validation.

**Cause**: The `iss` claim in the token doesn't match what the resource server expects.
Common when Keycloak is behind a proxy and the internal/external URLs differ.

**Diagnosis**:

```bash
# Check issuer in token
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.iss'
# e.g., "http://keycloak:8080/realms/my-realm"

# Check what the discovery endpoint reports
curl -s "$KC_URL/realms/$REALM/.well-known/openid-configuration" | jq '.issuer'
# e.g., "https://auth.example.com/realms/my-realm"
```

**Fix**:

Set the hostname correctly on Keycloak so internal and external URLs match:

```bash
# Keycloak environment variables
KC_HOSTNAME=auth.example.com
KC_HOSTNAME_STRICT=true
KC_PROXY_HEADERS=xforwarded

# Or in application, set issuer-uri to match the token's iss claim:
spring.security.oauth2.resourceserver.jwt.issuer-uri=https://auth.example.com/realms/my-realm
```

### JWKS Retrieval Failures

**Symptom**: `Could not obtain JWKS from endpoint` or signature validation fails.

**Diagnosis**:

```bash
# Test JWKS endpoint connectivity from the resource server
curl -v "$KC_URL/realms/$REALM/protocol/openid-connect/certs"

# Check if the key ID (kid) in the token matches any key in JWKS
TOKEN_KID=$(echo "$TOKEN" | cut -d. -f1 | base64 -d 2>/dev/null | jq -r '.kid')
JWKS_KIDS=$(curl -s "$KC_URL/realms/$REALM/protocol/openid-connect/certs" | jq -r '.keys[].kid')
echo "Token kid: $TOKEN_KID"
echo "JWKS kids: $JWKS_KIDS"
```

**Fix**:

- Ensure JWKS endpoint is reachable from resource server (network/firewall)
- After key rotation, resource server must refetch JWKS — configure cache TTL:
  ```yaml
  # Spring Boot
  spring.security.oauth2.resourceserver.jwt.jwk-set-cache-lifespan=300s
  ```
- If behind proxy, ensure the proxy passes through to the JWKS endpoint

---

## Redirect URI Mismatches

**Symptom**: `invalid_redirect_uri` error during login flow.

**Common Causes**:

1. **Trailing slash mismatch**: `https://app.com/callback` vs `https://app.com/callback/`
2. **HTTP vs HTTPS**: Configured `https://` but app sends `http://`
3. **Port mismatch**: `localhost:3000` vs `localhost:8080`
4. **Path mismatch**: `/auth/callback` vs `/callback`
5. **Wildcard issues**: Using `*` in production (avoid this)

**Diagnosis**:

```bash
# Check configured redirect URIs for a client
curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC_URL/admin/realms/$REALM/clients?clientId=my-app" | \
  jq '.[0].redirectUris'

# Check Keycloak server logs for the exact URI that was rejected
docker logs keycloak 2>&1 | grep -i "redirect"
```

**Fix**:

```bash
# Update redirect URIs to exactly match what the app sends
curl -X PUT "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "redirectUris": [
      "https://app.example.com/callback",
      "https://app.example.com/silent-refresh.html",
      "http://localhost:3000/callback"
    ],
    "webOrigins": [
      "https://app.example.com",
      "http://localhost:3000"
    ]
  }'
```

**Best Practices**:

- Never use `*` wildcards in production redirect URIs
- Use exact URIs per environment (dev/staging/prod)
- For SPAs, register the silent-refresh callback URL separately
- Include localhost URIs only for development clients
- For mobile apps using custom schemes: `myapp://callback`

---

## CORS Configuration Problems

**Symptom**: Browser console shows `Access-Control-Allow-Origin` errors when the SPA
calls Keycloak endpoints.

**Diagnosis**:

```bash
# Test CORS preflight request
curl -v -X OPTIONS "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type"

# Check response headers for:
# Access-Control-Allow-Origin: https://app.example.com
# Access-Control-Allow-Methods: POST
# Access-Control-Allow-Headers: Content-Type
```

**Fix**:

1. Set **Web Origins** on the client in Keycloak:
   ```bash
   curl -X PUT "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID" \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"webOrigins": ["https://app.example.com", "http://localhost:3000"]}'
   ```

2. Use `+` as a web origin to automatically allow all registered redirect URI origins.

3. If behind a reverse proxy, ensure the proxy doesn't strip or duplicate CORS headers:
   ```nginx
   # Don't add CORS headers at proxy level — let Keycloak handle it
   # Remove any proxy_set_header Access-Control-* directives
   ```

4. For development, a common mistake is the port mismatch:
   - React dev server on `http://localhost:3000`
   - Web Origin set to `http://localhost` (missing port)
   - Fix: Set `http://localhost:3000` as the Web Origin

---

## LDAP Sync Failures and Pagination

### Connection Failures

**Symptom**: "Unable to connect to LDAP server" or "Connection timed out".

**Diagnosis**:

```bash
# Test basic LDAP connectivity
ldapsearch -x -H ldap://ldap.example.com:389 -D "cn=admin,dc=example,dc=com" \
  -w "password" -b "dc=example,dc=com" "(objectClass=person)" -LLL | head -20

# Test LDAPS (TLS)
ldapsearch -x -H ldaps://ldap.example.com:636 -D "cn=admin,dc=example,dc=com" \
  -w "password" -b "dc=example,dc=com" "(objectClass=person)" -LLL | head -20

# Check certificate for LDAPS
openssl s_client -connect ldap.example.com:636 -showcerts </dev/null 2>/dev/null | \
  openssl x509 -noout -dates -subject
```

**Fix**:

- Import the LDAP server's CA certificate into Keycloak's truststore:
  ```bash
  keytool -importcert -file ldap-ca.crt -alias ldap-ca \
    -keystore /opt/keycloak/conf/truststore.jks -storepass changeit
  # Set in Keycloak:
  KC_SPI_TRUSTSTORE_FILE_FILE=/opt/keycloak/conf/truststore.jks
  KC_SPI_TRUSTSTORE_FILE_PASSWORD=changeit
  ```

### Pagination Issues (Large Directories)

**Symptom**: Only first 1000 users sync from LDAP, or sync hangs.

**Cause**: LDAP servers enforce size limits (Active Directory defaults to 1000).
Keycloak needs paged results enabled.

**Fix**:

- In Admin Console → User Federation → LDAP:
  - **Pagination**: Enable
  - **Batch Size**: 500 (adjust based on LDAP server limits)
  - **Full Sync Period**: 86400 (once per day)
  - **Changed Users Sync Period**: 600 (every 10 min)

- For Active Directory with large user bases:
  ```
  # AD-specific settings:
  UUID LDAP attribute: objectGUID
  User Object Classes: person, organizationalPerson, user
  Username LDAP Attribute: sAMAccountName
  RDN LDAP Attribute: cn
  ```

### Mapper Issues

**Symptom**: User attributes not syncing correctly from LDAP.

**Diagnosis**:

```bash
# Check what LDAP returns for a specific user
ldapsearch -x -H ldap://ldap.example.com -D "cn=admin,dc=example,dc=com" \
  -w "password" -b "ou=users,dc=example,dc=com" \
  "(sAMAccountName=jdoe)" "*" | grep -i -E "^(dn|cn|mail|sAMAccountName|memberOf):"
```

**Fix**: Verify mapper configurations match actual LDAP attribute names. Common
mistakes:

- `mail` vs `email` vs `userPrincipalName`
- `cn` vs `displayName` for first/last name
- Group DN format in memberOf mapper
- Case sensitivity in attribute names (LDAP is generally case-insensitive but
  Keycloak mappers are case-sensitive for the Keycloak side)

---

## Session Management Issues

### Sticky Sessions in Clustered Deployment

**Symptom**: Login works sometimes but fails randomly. Users get logged out
unexpectedly. "Invalid session" errors in logs.

**Cause**: Load balancer not routing requests to the same Keycloak node that holds
the session.

**Fix**:

```nginx
# Nginx — use cookie-based sticky sessions
upstream keycloak {
    server kc-node1:8080;
    server kc-node2:8080;
    sticky cookie KC_ROUTE expires=1h domain=.example.com httponly;
}
```

```yaml
# Kubernetes Ingress — use session affinity
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/session-cookie-name: "KC_ROUTE"
    nginx.ingress.kubernetes.io/session-cookie-max-age: "3600"
```

### Distributed Cache Issues

**Symptom**: Sessions not shared across nodes; users must re-authenticate when
routed to a different node.

**Diagnosis**:

```bash
# Check Infinispan cluster status
curl -s "http://keycloak:9000/health" | jq
# or check Keycloak logs for JGroups cluster formation
docker logs keycloak 2>&1 | grep -i "jgroups\|cluster\|ispn\|infinispan"
```

**Fix**:

```bash
# Ensure all nodes can communicate via JGroups
# For Kubernetes, use DNS_PING or KUBE_PING:
KC_CACHE=ispn
KC_CACHE_STACK=kubernetes

# Or for TCP-based discovery (non-K8s):
KC_CACHE_STACK=tcp
JAVA_OPTS_APPEND="-Djgroups.dns.query=keycloak-jgroups.default.svc.cluster.local"
```

For Keycloak 25+, enable persistent user sessions to survive restarts:

```bash
KC_FEATURES=persistent-user-sessions
```

---

## Database Migration Issues During Upgrades

**Symptom**: Keycloak fails to start after upgrade with Liquibase/migration errors.

**Pre-Upgrade Checklist**:

```bash
# 1. ALWAYS back up the database before upgrading
pg_dump -U keycloak -h localhost keycloak > keycloak-backup-$(date +%Y%m%d).sql

# 2. Check current Keycloak version
docker exec keycloak /opt/keycloak/bin/kc.sh show-config | grep version

# 3. Read the migration guide for your version jump
# https://www.keycloak.org/docs/latest/upgrading/
```

**Common Migration Errors**:

1. **Liquibase checksum mismatch**:
   ```
   Validation Failed: 1 change sets check sum
   ```
   **Fix**: Clear the Liquibase checksum (last resort):
   ```sql
   -- PostgreSQL
   UPDATE databasechangelog SET md5sum = NULL WHERE id = 'failing-changeset-id';
   ```

2. **Column already exists**:
   ```
   ERROR: column "xyz" of relation "table" already exists
   ```
   **Fix**: The migration was partially applied. Mark it as executed:
   ```sql
   INSERT INTO databasechangeloglock (id, locked) VALUES (1, false)
       ON CONFLICT (id) DO UPDATE SET locked = false;
   ```

3. **Timeout during migration** (large user tables):
   ```bash
   # Increase statement timeout for the migration
   JAVA_OPTS_APPEND="-Dkc.db.tx-timeout=600"
   ```

**Recovery**:

```bash
# Restore from backup if migration fails catastrophically
psql -U keycloak -h localhost keycloak < keycloak-backup-20240101.sql
# Then retry with the previous version and debug the issue
```

---

## Theme Caching During Development

**Symptom**: Theme changes not appearing after editing templates. Old CSS/templates
served despite file changes.

**Fix** — Disable theme caching for development:

```bash
# Keycloak environment variables (Quarkus)
KC_SPI_THEME_STATIC_MAX_AGE=-1
KC_SPI_THEME_CACHE_THEMES=false
KC_SPI_THEME_CACHE_TEMPLATES=false

# Or via CLI options
/opt/keycloak/bin/kc.sh start-dev \
  --spi-theme-static-max-age=-1 \
  --spi-theme-cache-themes=false \
  --spi-theme-cache-templates=false
```

For Docker development:

```yaml
services:
  keycloak:
    image: quay.io/keycloak/keycloak:25.0
    command: start-dev
    environment:
      KC_SPI_THEME_STATIC_MAX_AGE: "-1"
      KC_SPI_THEME_CACHE_THEMES: "false"
      KC_SPI_THEME_CACHE_TEMPLATES: "false"
    volumes:
      - ./themes/my-theme:/opt/keycloak/themes/my-theme
```

**Important**: Re-enable caching in production. Theme caching significantly impacts
performance when disabled.

**Browser Caching**: Even with server-side caching disabled, browsers cache CSS/JS.
Use hard refresh (Ctrl+Shift+R) or disable browser cache in DevTools.

---

## TLS / Certificate Configuration

### Self-Signed Certificate for Development

```bash
# Generate self-signed cert
openssl req -x509 -newkey rsa:4096 -keyout keycloak-key.pem -out keycloak-cert.pem \
  -days 365 -nodes -subj "/CN=localhost/O=Dev"

# Start Keycloak with TLS
/opt/keycloak/bin/kc.sh start \
  --https-certificate-file=/path/to/keycloak-cert.pem \
  --https-certificate-key-file=/path/to/keycloak-key.pem \
  --hostname=localhost
```

### Production TLS with Let's Encrypt

```bash
# Use certbot to obtain certificates
certbot certonly --standalone -d auth.example.com

# Configure Keycloak
KC_HTTPS_CERTIFICATE_FILE=/etc/letsencrypt/live/auth.example.com/fullchain.pem
KC_HTTPS_CERTIFICATE_KEY_FILE=/etc/letsencrypt/live/auth.example.com/privkey.pem
KC_HOSTNAME=auth.example.com
KC_HOSTNAME_STRICT_HTTPS=true
```

### Java Keystore (JKS) Format

```bash
# Convert PEM to PKCS12 then to JKS
openssl pkcs12 -export -in cert.pem -inkey key.pem -out keycloak.p12 \
  -name keycloak -passout pass:changeit
keytool -importkeystore -srckeystore keycloak.p12 -srcstoretype PKCS12 \
  -destkeystore keycloak.jks -deststoretype JKS \
  -srcstorepass changeit -deststorepass changeit

# Use with Keycloak
KC_HTTPS_KEY_STORE_FILE=/opt/keycloak/conf/keycloak.jks
KC_HTTPS_KEY_STORE_PASSWORD=changeit
```

### Trusting External Certificates

When Keycloak connects to external services (LDAP, external IdPs) using TLS:

```bash
# Import CA certificate into Keycloak's truststore
keytool -importcert -file external-ca.crt -alias external-ca \
  -keystore /opt/keycloak/conf/truststore.jks -storepass changeit -noprompt

KC_SPI_TRUSTSTORE_FILE_FILE=/opt/keycloak/conf/truststore.jks
KC_SPI_TRUSTSTORE_FILE_PASSWORD=changeit
```

---

## Behind Reverse Proxy

### Common Problems

**Symptom**: Mixed content warnings, redirect loops, "Invalid redirect" errors,
tokens with wrong issuer URL.

### Nginx Configuration

```nginx
server {
    listen 443 ssl http2;
    server_name auth.example.com;

    ssl_certificate /etc/ssl/certs/auth.crt;
    ssl_certificate_key /etc/ssl/private/auth.key;

    location / {
        proxy_pass http://keycloak-backend:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;

        # Required for large tokens/headers
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;

        # WebSocket support for admin console
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### Keycloak Settings for Proxy

```bash
# Keycloak 25+ (Quarkus):
KC_PROXY_HEADERS=xforwarded   # or 'forwarded' for RFC 7239 Forwarded header
KC_HOSTNAME=auth.example.com
KC_HOSTNAME_STRICT=true
KC_HTTP_ENABLED=true           # Allow HTTP on internal network (proxy terminates TLS)
KC_HOSTNAME_STRICT_HTTPS=true  # Enforce HTTPS in generated URLs

# IMPORTANT: KC_PROXY is deprecated in KC 25+. Use KC_PROXY_HEADERS instead.
# Old: KC_PROXY=edge → New: KC_PROXY_HEADERS=xforwarded
```

### Apache httpd Configuration

```apache
<VirtualHost *:443>
    ServerName auth.example.com
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/auth.crt
    SSLCertificateKeyFile /etc/ssl/private/auth.key

    ProxyPreserveHost On
    ProxyPass / http://keycloak:8080/
    ProxyPassReverse / http://keycloak:8080/

    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port "443"
</VirtualHost>
```

### Debugging Proxy Issues

```bash
# Check what headers Keycloak receives
# Enable TRACE logging for HTTP:
KC_LOG_LEVEL=INFO,org.keycloak.services:DEBUG

# Verify the well-known endpoint returns correct URLs
curl -s "https://auth.example.com/realms/my-realm/.well-known/openid-configuration" | \
  jq '{issuer, authorization_endpoint, token_endpoint}'
# All URLs should use the public hostname (auth.example.com) not the internal one
```

---

## Memory / CPU Tuning for Production

### JVM Heap Sizing

```bash
# Default heap is 512m — increase for production
JAVA_OPTS_APPEND="-Xms1024m -Xmx2048m"

# For containers, use percentage-based sizing
JAVA_OPTS_APPEND="-XX:MaxRAMPercentage=70.0 -XX:InitialRAMPercentage=50.0"

# Enable GC logging for tuning
JAVA_OPTS_APPEND="-Xlog:gc*:file=/tmp/gc.log:time,uptime,level,tags:filecount=5,filesize=10m"
```

### Sizing Guidelines

| Users  | Concurrent Sessions | Recommended Heap | CPU Cores | Instances |
|--------|---------------------|------------------|-----------|-----------|
| < 1K   | < 100               | 512m–1g          | 1–2       | 1         |
| 1K–10K | 100–1000            | 1g–2g            | 2–4       | 2         |
| 10K–50K| 1000–5000           | 2g–4g            | 4–8       | 2–3       |
| > 50K  | > 5000              | 4g–8g            | 8+        | 3+        |

### Database Connection Pool

```bash
# Tune connection pool size based on load
KC_DB_POOL_MIN_SIZE=10
KC_DB_POOL_MAX_SIZE=100
KC_DB_POOL_INITIAL_SIZE=10

# For PostgreSQL, tune on the DB side too:
# max_connections = instances * KC_DB_POOL_MAX_SIZE + overhead
```

### Kubernetes Resource Limits

```yaml
resources:
  requests:
    cpu: "1"
    memory: "1Gi"
  limits:
    cpu: "4"
    memory: "2Gi"
```

### Monitoring Key Metrics

```bash
# Enable metrics endpoint
KC_METRICS_ENABLED=true

# Key Prometheus metrics to monitor:
# - jvm_memory_used_bytes{area="heap"} — heap usage
# - keycloak_request_duration_seconds — request latency
# - keycloak_logins{provider="keycloak"} — login rate
# - keycloak_failed_login_attempts — failed login rate
# - vendor_agroal_active_count — active DB connections
# - vendor_agroal_available_count — available DB connections
```

---

## Infinispan Cache Tuning

Keycloak uses Infinispan for distributed caching in clustered deployments. Proper
tuning is critical for performance and consistency.

### Cache Types

| Cache             | Purpose                     | Default Size | Eviction |
|-------------------|-----------------------------|--------------|----------|
| `realms`          | Realm metadata              | 10,000       | LRU      |
| `users`           | User entities               | 10,000       | LRU      |
| `sessions`        | User sessions               | Unbounded    | None     |
| `authenticationSessions` | In-flight auth flows | Unbounded    | None     |
| `offlineSessions` | Offline tokens              | Unbounded    | None     |
| `clientSessions`  | Client sessions             | Unbounded    | None     |
| `loginFailures`   | Brute-force tracking        | Unbounded    | None     |
| `authorization`   | Authorization policies      | 10,000       | LRU      |
| `keys`            | Public keys (JWKS)          | 1,000        | LRU      |
| `work`            | Cluster-wide invalidation   | -            | -        |
| `actionTokens`    | One-time action tokens      | Unbounded    | None     |

### Custom Infinispan Configuration

Create a custom `cache-ispn.xml` in `/opt/keycloak/conf/`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<infinispan xmlns="urn:infinispan:config:14.0"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            xsi:schemaLocation="urn:infinispan:config:14.0
            https://infinispan.org/schemas/infinispan-config-14.0.xsd">

    <jgroups>
        <stack name="custom-tcp" extends="tcp">
            <TCP bind_addr="${jgroups.bind.address:SITE_LOCAL}"
                 bind_port="${jgroups.bind.port:7800}" />
            <!-- For Kubernetes -->
            <dns.DNS_PING dns_query="${jgroups.dns.query}"
                          dns_record_type="A"
                          stack.combine="REPLACE" stack.position="MPING" />
        </stack>
    </jgroups>

    <cache-container name="keycloak">
        <transport lock-timeout="60000" stack="custom-tcp" />

        <!-- Increase user cache for large deployments -->
        <local-cache name="users">
            <encoding>
                <key media-type="application/x-java-object"/>
                <value media-type="application/x-java-object"/>
            </encoding>
            <memory max-count="50000" when-full="REMOVE"/>
        </local-cache>

        <!-- Increase realm cache if many realms -->
        <local-cache name="realms">
            <encoding>
                <key media-type="application/x-java-object"/>
                <value media-type="application/x-java-object"/>
            </encoding>
            <memory max-count="20000" when-full="REMOVE"/>
        </local-cache>

        <!-- Session caches — distributed across cluster -->
        <distributed-cache name="sessions" owners="2">
            <expiration lifespan="-1" />
        </distributed-cache>

        <distributed-cache name="authenticationSessions" owners="2">
            <expiration lifespan="1800000" />  <!-- 30 min max for auth flows -->
        </distributed-cache>

        <distributed-cache name="offlineSessions" owners="1">
            <expiration lifespan="-1" />
        </distributed-cache>

        <distributed-cache name="loginFailures" owners="2">
            <expiration lifespan="900000" />  <!-- 15 min -->
        </distributed-cache>

        <distributed-cache name="actionTokens" owners="2">
            <expiration lifespan="300000" max-idle="-1" interval="60000" />
        </distributed-cache>

        <replicated-cache name="work" />
    </cache-container>
</infinispan>
```

Apply the custom configuration:

```bash
KC_CACHE_CONFIG_FILE=cache-ispn.xml
# Or
/opt/keycloak/bin/kc.sh build --cache-config-file=cache-ispn.xml
```

### External Infinispan for Cross-DC

For multi-datacenter deployments, use an external Infinispan cluster:

```bash
KC_CACHE=ispn
KC_CACHE_REMOTE_HOST=infinispan.example.com
KC_CACHE_REMOTE_PORT=11222
KC_CACHE_REMOTE_USERNAME=keycloak
KC_CACHE_REMOTE_PASSWORD=password
KC_CACHE_REMOTE_TLS_ENABLED=true
```

### Cache Monitoring

```bash
# Check cache statistics via metrics endpoint
curl -s "http://keycloak:9000/metrics" | grep -E "vendor_cache"

# Key metrics:
# vendor_cache_manager_default_cache_sessions_statistics_stores — session stores
# vendor_cache_manager_default_cache_users_statistics_hits — user cache hits
# vendor_cache_manager_default_cache_users_statistics_misses — user cache misses
# vendor_cache_manager_default_cache_users_statistics_evictions — evictions

# Calculate hit ratio:
# hit_ratio = hits / (hits + misses)
# Target: > 0.95 for user/realm caches
# If hit ratio < 0.90, increase cache size
```

### Troubleshooting Cache Issues

**Symptom**: Stale data after admin changes (role changes not taking effect).

**Fix**: Ensure the `work` cache is replicated and JGroups cluster is healthy:

```bash
# Check cluster members
docker exec keycloak /opt/keycloak/bin/kc.sh show-config 2>&1 | grep -i cluster

# Check Keycloak logs for cluster formation
docker logs keycloak 2>&1 | grep "Received new cluster view"
# Should show all expected nodes
```

**Symptom**: OutOfMemoryError with many active sessions.

**Fix**: Enable persistent sessions and limit in-memory session count:

```bash
KC_FEATURES=persistent-user-sessions
# Sessions overflow to database, reducing memory pressure
```
