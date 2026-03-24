---
name: keycloak-auth
description: >
  Use when setting up Keycloak for SSO, configuring OAuth2/OIDC with Keycloak,
  managing realms/clients/users, integrating Keycloak with applications, or
  customizing Keycloak themes and providers. Covers installation (Docker,
  Kubernetes operator, bare metal), authentication flows, SAML 2.0, user
  federation (LDAP/AD), identity brokering, authorization services, Admin API,
  token management, custom SPIs, realm export/import, and HA clustering.
  Do NOT use for Auth0, Okta, AWS Cognito, Firebase Auth, or general
  OAuth2/OIDC without Keycloak.
---

# Keycloak Identity & Access Management

## Installation

### Docker (development)

Run Keycloak 25+ in dev mode with the Quarkus-based distribution:

```bash
docker run -d --name keycloak \
  -p 8080:8080 \
  -e KEYCLOAK_ADMIN=admin \
  -e KEYCLOAK_ADMIN_PASSWORD=admin \
  quay.io/keycloak/keycloak:25.0 start-dev
```

Production with PostgreSQL — set `KC_DB=postgres`, `KC_DB_URL`, `KC_DB_USERNAME`, `KC_DB_PASSWORD`, `KC_HOSTNAME`, and `KC_PROXY_HEADERS=xforwarded`. Use `start --optimized` after running `kc.sh build`.

Build an optimized image for production:

```dockerfile
FROM quay.io/keycloak/keycloak:25.0 AS builder
ENV KC_DB=postgres KC_HEALTH_ENABLED=true KC_METRICS_ENABLED=true
RUN /opt/keycloak/bin/kc.sh build
FROM quay.io/keycloak/keycloak:25.0
COPY --from=builder /opt/keycloak/ /opt/keycloak/
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

### Kubernetes (Keycloak Operator)

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
spec:
  instances: 3
  hostname:
    hostname: auth.example.com
  db:
    vendor: postgres
    url: jdbc:postgresql://keycloak-db:5432/keycloak
    usernameSecret: { name: keycloak-db-secret, key: username }
    passwordSecret: { name: keycloak-db-secret, key: password }
  http:
    tlsSecret: keycloak-tls
  additionalOptions:
    - { name: metrics-enabled, value: "true" }
    - { name: health-enabled, value: "true" }
```

### Bare Metal

```bash
# Requires Java 21 (Java 17 deprecated in KC 25+)
wget https://github.com/keycloak/keycloak/releases/download/25.0.0/keycloak-25.0.0.tar.gz
tar xzf keycloak-25.0.0.tar.gz && cd keycloak-25.0.0
export KC_DB=postgres KC_DB_URL=jdbc:postgresql://localhost:5432/keycloak
export KC_DB_USERNAME=keycloak KC_DB_PASSWORD=keycloak
bin/kc.sh build && bin/kc.sh start --hostname=auth.example.com
```

## Core Concepts

**Realms** — Isolated tenancy units. Each realm has its own users, clients, roles, and identity providers. The `master` realm is for admin only; create separate realms per application or tenant.

**Clients** — Applications or services registered to use Keycloak. Two access types:
- **Confidential**: Server-side apps that can securely store a client secret. Use `client_credentials` or `authorization_code` grants.
- **Public**: SPAs and mobile apps that cannot store secrets. Use `authorization_code` with PKCE.

**Users** — Identities within a realm. Manage credentials, attributes, required actions, and consent.

**Groups** — Hierarchical containers for users. Assign roles and attributes at group level for inheritance.

**Roles** — Two types:
- **Realm roles**: Global to the realm (e.g., `admin`, `user`).
- **Client roles**: Scoped to a specific client (e.g., `my-app:editor`).
- Use composite roles to aggregate multiple roles.

## Client Configuration

Set redirect URIs as narrowly as possible. Never use wildcards in production.

```bash
# Create a confidential client via Admin CLI
/opt/keycloak/bin/kcadm.sh create clients -r my-realm \
  -s clientId=my-backend \
  -s protocol=openid-connect \
  -s 'redirectUris=["https://app.example.com/callback"]' \
  -s clientAuthenticatorType=client-secret \
  -s secret=my-client-secret \
  -s directAccessGrantsEnabled=false \
  -s serviceAccountsEnabled=true
```

**Protocol mappers** control token claims. Add custom claims:

```bash
/opt/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/protocol-mappers/models -r my-realm \
  -s name=department \
  -s protocol=openid-connect \
  -s protocolMapper=oidc-usermodel-attribute-mapper \
  -s 'config."claim.name"=department' \
  -s 'config."user.attribute"=department' \
  -s 'config."id.token.claim"=true' \
  -s 'config."access.token.claim"=true'
```

**Client scopes** group protocol mappers and role scope mappings. Assign as default or optional scopes on clients. Request optional scopes at login with `scope=openid profile my-custom-scope`.

## Authentication Flows

**Browser flow** — Standard interactive login. Supports username/password, OTP, WebAuthn, conditional steps.

**Direct grant** — Resource Owner Password Credentials. Use only for trusted first-party apps. Disable in production when possible.

**Client credentials** — Machine-to-machine. Enable `serviceAccountsEnabled` on the client. No user context.

**Device authorization** — For input-constrained devices (smart TVs, CLI tools). Uses device code flow (RFC 8628).

Customize flows in Admin Console → Authentication → Flows. Clone a built-in flow before modifying.

**Protocols**: OpenID Connect (OIDC), SAML 2.0, OAuth 2.0. Endpoints:
- Discovery: `/realms/{realm}/.well-known/openid-configuration`
- Authorization: `/realms/{realm}/protocol/openid-connect/auth`
- Token: `/realms/{realm}/protocol/openid-connect/token`
- UserInfo: `/realms/{realm}/protocol/openid-connect/userinfo`
- Logout: `/realms/{realm}/protocol/openid-connect/logout`
- JWKS: `/realms/{realm}/protocol/openid-connect/certs`

For SAML clients, configure entity ID, assertion consumer URL, and signing certificate. OAuth 2.0 grants supported: authorization code, client credentials, device code, and token exchange.

## User Federation

### LDAP / Active Directory

Configure in Admin Console → User Federation → Add LDAP provider. Key settings: Connection URL (`ldap://` or `ldaps://`), Bind DN, User DN (`ou=users,dc=example,dc=com`), UUID attribute (`entryUUID` for OpenLDAP, `objectGUID` for AD). Sync modes: `FORCE` (always read LDAP), `IMPORT` (cache locally), `UNSYNCED`. Set mapper types for attribute, role, and group mapping.

### Custom User Storage SPI

Implement `UserStorageProvider`, `UserLookupProvider`, and `CredentialInputValidator`. Register via `META-INF/services/org.keycloak.storage.UserStorageProviderFactory`. Deploy JAR to `providers/` directory and run `kc.sh build`.

## Identity Brokering

Add external IdPs under realm → Identity Providers. **Social login**: Built-in support for Google, GitHub, Facebook, GitLab, Microsoft, Twitter, LinkedIn, Apple — configure OAuth2 client ID/secret from each provider. **External OIDC/SAML**: Add any compliant IdP with authorization URL, token URL, client ID/secret, or import SAML metadata XML. Configure **first login flow** to handle account linking, attribute import, and user creation for brokered users.

## Authorization Services

Enable on a client to use fine-grained authorization (UMA 2.0).
**Resources** — Protected entities (APIs, files, UI elements). Each has a name, type, URI, and optional owner.

**Scopes** — Actions on resources (e.g., `view`, `edit`, `delete`).

**Policies** — Rules evaluated for access decisions:
- Role-based, user-based, group-based
- Time-based (valid time windows)
- JavaScript or custom policy providers
- Aggregated policies (combine with AND/OR logic)

**Permissions** — Link resources/scopes to policies.

**RPT (Requesting Party Token)** — Token containing granted permissions. Obtain via token endpoint with `grant_type=urn:ietf:params:oauth:grant-type:uma-ticket`.

```bash
# Request RPT
curl -X POST "https://auth.example.com/realms/my-realm/protocol/openid-connect/token" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:uma-ticket" \
  -d "audience=my-resource-server" \
  -d "permission=resource-id#scope-name"
```

## Admin API

Authenticate to obtain an admin token, then call REST endpoints:

```bash
# Get admin token
TOKEN=$(curl -s -X POST \
  "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
  | jq -r '.access_token')

# List users
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8080/admin/realms/my-realm/users" | jq

# Create user
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "http://localhost:8080/admin/realms/my-realm/users" \
  -d '{"username":"newuser","enabled":true,"email":"new@example.com",
       "credentials":[{"type":"password","value":"temp123","temporary":true}]}'

# List clients
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8080/admin/realms/my-realm/clients" | jq '.[].clientId'
```

**Admin CLI** (`kcadm.sh`):

```bash
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
  --realm master --user admin --password admin
/opt/keycloak/bin/kcadm.sh get realms
/opt/keycloak/bin/kcadm.sh create realms -s realm=new-realm -s enabled=true
/opt/keycloak/bin/kcadm.sh get users -r my-realm --fields id,username,email
```

## Token Management

**Access token** — Short-lived JWT (default 5 min). Contains realm/client roles, scopes, custom claims. Validate via JWKS or introspection endpoint.
**Refresh token** — Longer-lived (default 30 min, sliding). Enable rotation for security. Use to obtain new access tokens silently.
**ID token** — User identity claims (sub, name, email). Used by client only, never sent to resource servers.
**Token exchange** — Exchange tokens across clients/realms (RFC 8693). Enable `token-exchange` feature flag.

```bash
# Token exchange: internal-to-internal
curl -X POST "https://auth.example.com/realms/my-realm/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=$ACCESS_TOKEN" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=target-client" \
  -d "client_id=source-client" \
  -d "client_secret=source-secret"
```

## Custom Themes

Theme types: `login`, `account`, `admin`, `email`. Stored in `themes/` directory. Set `parent=keycloak.v2` in `theme.properties` to extend the default theme.
```
themes/my-theme/login/
├── theme.properties       # parent=keycloak.v2, styles=css/styles.css
├── resources/css/styles.css
└── login.ftl              # Override FreeMarker templates selectively
```

Override login page with FreeMarker:

```html
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=true; section>
  <#if section = "header">
    <span class="custom-header">${msg("loginAccountTitle")}</span>
  <#elseif section = "form">
    <div class="custom-login-form"><#include "login-form.ftl"></div>
  </#if>
</@layout.registrationLayout>
```

Mount custom themes via Docker volume or bake into the image.

## Custom SPIs

```java
public class MfaSmsAuthenticator implements Authenticator {
    @Override
    public void authenticate(AuthenticationFlowContext context) {
        String phone = context.getUser()
            .getFirstAttribute("phone");
        String code = SmsService.sendCode(phone);
        context.getAuthenticationSession()
            .setAuthNote("sms-code", code);
        context.challenge(context.form()
            .createForm("sms-validation.ftl"));
    }
    @Override
    public void action(AuthenticationFlowContext context) {
        String input = context.getHttpRequest()
            .getDecodedFormParameters().getFirst("sms-code");
        String expected = context.getAuthenticationSession()
            .getAuthNote("sms-code");
        if (expected.equals(input)) {
            context.success();
        } else {
            context.failureChallenge(AuthenticationFlowError.INVALID_CREDENTIALS,
                context.form().setError("invalidCode").createForm("sms-validation.ftl"));
        }
    }
}
```

Register the factory in `META-INF/services/org.keycloak.authentication.AuthenticatorFactory`.

### Custom Event Listener

```java
public class AuditEventListenerProvider implements EventListenerProvider {
    @Override
    public void onEvent(Event event) {
        if (event.getType() == EventType.LOGIN) {
            auditLog.info("User {} logged in from {}",
                event.getUserId(), event.getIpAddress());
        }
    }
    @Override
    public void onEvent(AdminEvent event, boolean includeRepresentation) {
        auditLog.info("Admin action: {} on {}",
            event.getOperationType(), event.getResourcePath());
    }
}
```

Register in `META-INF/services/org.keycloak.events.EventListenerProviderFactory`.

### Deployment

Package SPIs as JARs. Place in `providers/` directory. Run `kc.sh build` to register, then restart.

## Realm Export / Import

```bash
# Export realm (running server)
/opt/keycloak/bin/kc.sh export --dir /tmp/export --realm my-realm

# Import at startup
/opt/keycloak/bin/kc.sh start --import-realm \
  --spi-import-dir=/tmp/export

# Export via Admin API
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8080/admin/realms/my-realm" | jq > realm-export.json

# Partial import via Admin API (merge users, clients, roles)
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "http://localhost:8080/admin/realms/my-realm/partialImport" \
  -d @realm-import.json
```

Use realm exports in CI/CD pipelines for environment promotion (dev → staging → prod). Parameterize URLs and secrets.

## Integration Patterns

### Spring Boot (Resource Server)

Use Spring Security's native OAuth2 support (legacy Keycloak adapters removed in KC 24+):

```yaml
# application.yml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: https://auth.example.com/realms/my-realm
```

```java
@Configuration
@EnableMethodSecurity
public class SecurityConfig {
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http.oauth2ResourceServer(oauth2 -> oauth2
            .jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthConverter())));
        http.authorizeHttpRequests(auth -> auth
            .requestMatchers("/api/public/**").permitAll()
            .requestMatchers("/api/admin/**").hasRole("admin")
            .anyRequest().authenticated());
        return http.build();
    }
    private JwtAuthenticationConverter jwtAuthConverter() {
        var converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(jwt -> {
            Map<String, Object> realmAccess = jwt.getClaim("realm_access");
            List<String> roles = (List<String>) realmAccess.get("roles");
            return roles.stream()
                .map(r -> new SimpleGrantedAuthority("ROLE_" + r))
                .collect(Collectors.toList());
        });
        return converter;
    }
}
```

### Node.js / Express

```javascript
const express = require('express');
const jwt = require('jsonwebtoken');
const jwksClient = require('jwks-rsa');
const app = express();
const client = jwksClient({
  jwksUri: 'https://auth.example.com/realms/my-realm/protocol/openid-connect/certs'
});

function authMiddleware(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'No token' });
  jwt.verify(token, (header, cb) => {
    client.getSigningKey(header.kid, (err, key) => cb(null, key.getPublicKey()));
  }, { issuer: 'https://auth.example.com/realms/my-realm' }, (err, decoded) => {
    if (err) return res.status(403).json({ error: 'Invalid token' });
    req.user = decoded;
    next();
  });
}
app.get('/api/protected', authMiddleware, (req, res) => {
  res.json({ user: req.user.preferred_username });
});
```

### React / Angular (keycloak-js)

```javascript
import Keycloak from 'keycloak-js';

const keycloak = new Keycloak({
  url: 'https://auth.example.com',
  realm: 'my-realm',
  clientId: 'my-spa'  // public client with PKCE
});

await keycloak.init({ onLoad: 'login-required', pkceMethod: 'S256' });

// Attach token to API requests
async function apiFetch(url) {
  await keycloak.updateToken(30);  // refresh if <30s remaining
  return fetch(url, {
    headers: { Authorization: `Bearer ${keycloak.token}` }
  });
}
```

### Nginx Reverse Proxy

```nginx
server {
    listen 443 ssl;
    server_name auth.example.com;
    ssl_certificate /etc/ssl/certs/auth.crt;
    ssl_certificate_key /etc/ssl/private/auth.key;
    location / {
        proxy_pass http://keycloak:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
    }
}
```

Set `KC_PROXY_HEADERS=xforwarded` on Keycloak when behind a reverse proxy.

## High Availability

**Clustering** — Keycloak 25+ uses Infinispan for distributed caching (`KC_CACHE=ispn` default). Nodes discover via JGroups (UDP multicast default, TCP for cloud). **Database** — Use PostgreSQL with connection pooling. Configure `KC_DB_POOL_MIN_SIZE`/`KC_DB_POOL_MAX_SIZE`. **Session persistence** — Enable `--features=persistent-user-sessions` so sessions survive restarts. **Kubernetes** — Use Operator with `instances: 3+`, anti-affinity rules, shared DB, and external Infinispan for cross-site replication.

## Security Best Practices
- **PKCE**: Enforce `S256` for all public clients.
- **Token rotation**: Enable refresh token rotation. Short access token lifespans (5 min).
- **Session management**: Configure idle/max timeouts. Limit concurrent sessions per user.
- **Brute force protection**: Enable in Security Defenses. Configure max failures and lockout.
- **HTTPS only**: Set `KC_HOSTNAME_STRICT_HTTPS=true`. Never run production over HTTP.
- **Content Security Policy**: Configure CSP headers for login pages.
- **Argon2 password hashing**: Default in KC 25+ (non-FIPS). Tune iterations and memory.
- **Regular key rotation**: Rotate realm signing keys periodically.

## Monitoring & Auditing

**Event logging** — Enable login/admin events in realm settings. Forward to external systems via event listener SPIs.

**Prometheus metrics** — Enable with `KC_METRICS_ENABLED=true`. Scrape `/metrics`. Key metrics: `keycloak_logins`, `keycloak_failed_login_attempts`, `keycloak_registrations`, `keycloak_request_duration`.

**Health checks** — Enable with `KC_HEALTH_ENABLED=true`. Endpoints: `/health/live`, `/health/ready`, `/health/started`. Use in Kubernetes liveness/readiness probes.

## Reference Documentation

- **`references/advanced-patterns.md`** — Custom authenticator/event listener/protocol mapper/user storage SPIs, custom REST endpoints, authorization services (policies, decision strategies), token exchange, fine-grained admin permissions, Organizations (KC 25+), Passkeys/WebAuthn.
- **`references/troubleshooting.md`** — Token validation (clock skew, audience, issuer, JWKS), redirect URI mismatches, CORS, LDAP sync/pagination, sessions (sticky, distributed), DB migration, theme caching, TLS, reverse proxy, memory/CPU/Infinispan tuning.
- **`references/integration-guide.md`** — Full code: Spring Boot 3, Node.js/Express, React SPA (react-oidc-context), Angular (angular-auth-oidc-client), Next.js (next-auth), Nginx/Apache proxy auth, Kong/APISIX, Kubernetes Ingress (oauth2-proxy), mobile PKCE (iOS/Android/React Native).

## Helper Scripts

- **`scripts/setup-keycloak.sh`** — Docker Compose setup (KC + PostgreSQL). `--import`, `--stop`, `--reset`.
- **`scripts/keycloak-realm-export.sh`** — Export realm via Admin API, strips secrets. `--full`, `--strip-ids`.
- **`scripts/keycloak-user-sync.sh`** — CSV user sync (create/update, groups/roles, `--dry-run`) or LDAP sync trigger.

## Asset Templates

- **`assets/docker-compose.yml`** — Production stack: health checks, resource limits, JVM tuning, optimized PostgreSQL.
- **`assets/realm-export.json`** — Starter realm: SPA/API/confidential/mobile clients, roles, groups, scopes, security policies.
