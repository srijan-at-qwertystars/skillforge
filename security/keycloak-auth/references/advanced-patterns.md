# Keycloak Advanced Patterns

## Table of Contents

- [Custom Authenticator SPI](#custom-authenticator-spi)
- [Event Listener SPI for Audit Logging](#event-listener-spi-for-audit-logging)
- [Protocol Mapper SPI for Custom Claims](#protocol-mapper-spi-for-custom-claims)
- [User Storage SPI for External Databases](#user-storage-spi-for-external-databases)
- [Custom REST Endpoints](#custom-rest-endpoints)
- [Authorization Services Deep Dive](#authorization-services-deep-dive)
- [Token Exchange Patterns](#token-exchange-patterns)
- [Fine-Grained Admin Permissions](#fine-grained-admin-permissions)
- [Organizations Feature (Keycloak 25+)](#organizations-feature-keycloak-25)
- [Passkeys / WebAuthn Configuration](#passkeys--webauthn-configuration)

---

## Custom Authenticator SPI

Custom authenticators let you inject arbitrary logic into Keycloak's authentication
flows — SMS OTP, hardware token validation, risk-based step-up, or conditional
checks based on user attributes.

### Step 1: Create the Authenticator

```java
package com.example.keycloak.auth;

import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.Authenticator;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

public class CustomOtpAuthenticator implements Authenticator {

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        UserModel user = context.getUser();
        if (user == null) {
            context.attempted();
            return;
        }

        String phoneNumber = user.getFirstAttribute("phoneNumber");
        if (phoneNumber == null || phoneNumber.isEmpty()) {
            // Skip OTP if no phone number configured
            context.success();
            return;
        }

        // Generate and send OTP
        String otp = OtpService.generateOtp();
        context.getAuthenticationSession().setAuthNote("expected-otp", otp);
        context.getAuthenticationSession().setAuthNote("otp-expiry",
            String.valueOf(System.currentTimeMillis() + 300_000)); // 5 min

        OtpService.sendSms(phoneNumber, "Your code: " + otp);

        // Show the OTP form
        context.challenge(
            context.form()
                .setAttribute("phoneHint", maskPhone(phoneNumber))
                .createForm("custom-otp-form.ftl")
        );
    }

    @Override
    public void action(AuthenticationFlowContext context) {
        String inputCode = context.getHttpRequest()
            .getDecodedFormParameters().getFirst("otp");
        String expectedCode = context.getAuthenticationSession()
            .getAuthNote("expected-otp");
        String expiryStr = context.getAuthenticationSession()
            .getAuthNote("otp-expiry");

        if (expiryStr != null && System.currentTimeMillis() > Long.parseLong(expiryStr)) {
            context.failureChallenge(AuthenticationFlowError.EXPIRED_CODE,
                context.form().setError("otpExpired")
                    .createForm("custom-otp-form.ftl"));
            return;
        }

        if (expectedCode != null && expectedCode.equals(inputCode)) {
            context.success();
        } else {
            context.failureChallenge(AuthenticationFlowError.INVALID_CREDENTIALS,
                context.form().setError("otpInvalid")
                    .createForm("custom-otp-form.ftl"));
        }
    }

    @Override
    public boolean requiresUser() { return true; }

    @Override
    public boolean configuredFor(KeycloakSession session, RealmModel realm, UserModel user) {
        return user.getFirstAttribute("phoneNumber") != null;
    }

    @Override
    public void setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user) {
        user.addRequiredAction("CONFIGURE_PHONE");
    }

    @Override
    public void close() {}

    private String maskPhone(String phone) {
        if (phone.length() <= 4) return "****";
        return "****" + phone.substring(phone.length() - 4);
    }
}
```

### Step 2: Create the Factory

```java
package com.example.keycloak.auth;

import org.keycloak.Config;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.AuthenticatorFactory;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.provider.ProviderConfigProperty;
import java.util.List;

public class CustomOtpAuthenticatorFactory implements AuthenticatorFactory {

    public static final String PROVIDER_ID = "custom-otp-authenticator";
    private static final CustomOtpAuthenticator INSTANCE = new CustomOtpAuthenticator();

    @Override
    public String getId() { return PROVIDER_ID; }

    @Override
    public String getDisplayType() { return "Custom SMS OTP"; }

    @Override
    public String getReferenceCategory() { return "otp"; }

    @Override
    public boolean isConfigurable() { return true; }

    @Override
    public AuthenticationExecutionModel.Requirement[] getRequirementChoices() {
        return new AuthenticationExecutionModel.Requirement[]{
            AuthenticationExecutionModel.Requirement.REQUIRED,
            AuthenticationExecutionModel.Requirement.ALTERNATIVE,
            AuthenticationExecutionModel.Requirement.DISABLED,
            AuthenticationExecutionModel.Requirement.CONDITIONAL
        };
    }

    @Override
    public boolean isUserSetupAllowed() { return true; }

    @Override
    public String getHelpText() {
        return "Validates an OTP sent via SMS to the user's registered phone.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return List.of(
            new ProviderConfigProperty("otpLength", "OTP Length",
                "Number of digits in the OTP code", ProviderConfigProperty.STRING_TYPE, "6"),
            new ProviderConfigProperty("otpTtlSeconds", "OTP TTL (seconds)",
                "Time-to-live for the OTP code", ProviderConfigProperty.STRING_TYPE, "300")
        );
    }

    @Override
    public Authenticator create(KeycloakSession session) { return INSTANCE; }

    @Override
    public void init(Config.Scope config) {}

    @Override
    public void postInit(KeycloakSessionFactory factory) {}

    @Override
    public void close() {}
}
```

### Step 3: Register and Deploy

Create `META-INF/services/org.keycloak.authentication.AuthenticatorFactory`:

```
com.example.keycloak.auth.CustomOtpAuthenticatorFactory
```

Create the FreeMarker template `custom-otp-form.ftl` in your theme's `login/` directory:

```html
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=!messagesPerField.existsError('otp'); section>
    <#if section = "header">
        ${msg("otpTitle", "")}
    <#elseif section = "form">
        <form action="${url.loginAction}" method="post">
            <div class="${properties.kcFormGroupClass!}">
                <label for="otp">${msg("otpLabel")}</label>
                <input id="otp" name="otp" type="text" autocomplete="one-time-code"
                       class="${properties.kcInputClass!}" autofocus />
                <span class="hint">${msg("otpSentTo", phoneHint)}</span>
            </div>
            <input type="submit" class="${properties.kcButtonClass!}" value="${msg("doSubmit")}" />
        </form>
    </#if>
</@layout.registrationLayout>
```

Build and deploy:

```bash
mvn clean package
cp target/custom-otp-authenticator.jar /opt/keycloak/providers/
/opt/keycloak/bin/kc.sh build
# Restart Keycloak — the authenticator appears in Authentication → Flows
```

### Step 4: Add to an Authentication Flow

1. Admin Console → Authentication → Flows
2. Duplicate the "Browser" flow
3. Add execution → "Custom SMS OTP"
4. Set requirement to REQUIRED or CONDITIONAL
5. If conditional, add a "Condition - User Attribute" sub-flow checking `phoneNumber`
6. Bind the new flow as the Browser flow for the realm

---

## Event Listener SPI for Audit Logging

Keycloak emits two event types: **login events** (user actions) and **admin events**
(management operations). Custom event listeners can forward these to SIEM systems,
databases, or message queues.

### Full Event Listener Implementation

```java
package com.example.keycloak.events;

import org.keycloak.events.Event;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventType;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.events.admin.OperationType;
import org.keycloak.models.KeycloakSession;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.URI;
import java.util.Map;

public class WebhookEventListenerProvider implements EventListenerProvider {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private final HttpClient httpClient;
    private final String webhookUrl;
    private final KeycloakSession session;

    public WebhookEventListenerProvider(KeycloakSession session, String webhookUrl) {
        this.session = session;
        this.webhookUrl = webhookUrl;
        this.httpClient = HttpClient.newHttpClient();
    }

    @Override
    public void onEvent(Event event) {
        Map<String, Object> payload = Map.of(
            "type", "LOGIN_EVENT",
            "eventType", event.getType().name(),
            "realmId", event.getRealmId(),
            "userId", event.getUserId() != null ? event.getUserId() : "unknown",
            "clientId", event.getClientId() != null ? event.getClientId() : "unknown",
            "ipAddress", event.getIpAddress() != null ? event.getIpAddress() : "unknown",
            "timestamp", event.getTime(),
            "details", event.getDetails() != null ? event.getDetails() : Map.of(),
            "error", event.getError() != null ? event.getError() : ""
        );
        sendWebhook(payload);

        // Log security-critical events at WARN level
        if (event.getType() == EventType.LOGIN_ERROR
                || event.getType() == EventType.LOGOUT
                || event.getType() == EventType.UPDATE_PASSWORD) {
            System.err.printf("[SECURITY] %s user=%s ip=%s client=%s error=%s%n",
                event.getType(), event.getUserId(), event.getIpAddress(),
                event.getClientId(), event.getError());
        }
    }

    @Override
    public void onEvent(AdminEvent event, boolean includeRepresentation) {
        Map<String, Object> payload = Map.of(
            "type", "ADMIN_EVENT",
            "operationType", event.getOperationType().name(),
            "realmId", event.getRealmId(),
            "resourceType", event.getResourceType() != null ? event.getResourceType().name() : "",
            "resourcePath", event.getResourcePath() != null ? event.getResourcePath() : "",
            "authUserId", event.getAuthDetails().getUserId(),
            "authIpAddress", event.getAuthDetails().getIpAddress(),
            "timestamp", event.getTime(),
            "representation", includeRepresentation && event.getRepresentation() != null
                ? event.getRepresentation() : ""
        );
        sendWebhook(payload);
    }

    private void sendWebhook(Map<String, Object> payload) {
        try {
            String json = MAPPER.writeValueAsString(payload);
            HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(webhookUrl))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(json))
                .build();
            httpClient.sendAsync(request, HttpResponse.BodyHandlers.discarding());
        } catch (Exception e) {
            System.err.println("Webhook delivery failed: " + e.getMessage());
        }
    }

    @Override
    public void close() {}
}
```

### Factory

```java
package com.example.keycloak.events;

import org.keycloak.Config;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventListenerProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

public class WebhookEventListenerProviderFactory implements EventListenerProviderFactory {

    private String webhookUrl;

    @Override
    public String getId() { return "webhook-audit"; }

    @Override
    public EventListenerProvider create(KeycloakSession session) {
        return new WebhookEventListenerProvider(session, webhookUrl);
    }

    @Override
    public void init(Config.Scope config) {
        this.webhookUrl = config.get("webhookUrl", "http://localhost:9090/events");
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {}

    @Override
    public void close() {}
}
```

Register in `META-INF/services/org.keycloak.events.EventListenerProviderFactory`.
Enable in Admin Console → Realm Settings → Events → Event Listeners → add `webhook-audit`.

---

## Protocol Mapper SPI for Custom Claims

Add custom claims to tokens derived from external data sources, computed values,
or complex attribute transformations.

```java
package com.example.keycloak.mappers;

import org.keycloak.models.*;
import org.keycloak.protocol.oidc.mappers.*;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.IDToken;
import java.util.*;

public class ExternalApiClaimMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper, OIDCIDTokenMapper, UserInfoTokenMapper {

    public static final String PROVIDER_ID = "external-api-claim-mapper";

    private static final List<ProviderConfigProperty> CONFIG_PROPERTIES = List.of(
        new ProviderConfigProperty("apiEndpoint", "API Endpoint",
            "URL to fetch claim data from", ProviderConfigProperty.STRING_TYPE, ""),
        new ProviderConfigProperty("claimName", "Claim Name",
            "Name of the token claim", ProviderConfigProperty.STRING_TYPE, "external_data"),
        new ProviderConfigProperty("cacheTtlSeconds", "Cache TTL",
            "Cache duration in seconds (0 = no cache)", ProviderConfigProperty.STRING_TYPE, "300")
    );

    @Override
    public String getId() { return PROVIDER_ID; }

    @Override
    public String getDisplayType() { return "External API Claim Mapper"; }

    @Override
    public String getDisplayCategory() { return TOKEN_MAPPER_CATEGORY; }

    @Override
    public String getHelpText() {
        return "Fetches claim values from an external REST API.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return CONFIG_PROPERTIES;
    }

    @Override
    protected void setClaim(IDToken token, ProtocolMapperModel mappingModel,
                            UserSessionModel userSession, KeycloakSession session,
                            ClientSessionContext clientSessionCtx) {
        String apiEndpoint = mappingModel.getConfig().get("apiEndpoint");
        String claimName = mappingModel.getConfig().get("claimName");
        String userId = userSession.getUser().getId();

        // Fetch data from external API (with caching)
        Object claimValue = ExternalApiClient.fetchClaim(apiEndpoint, userId);

        if (claimValue != null) {
            OIDCAttributeMapperHelper.mapClaim(token, mappingModel, claimValue);
        }
    }
}
```

Register in `META-INF/services/org.keycloak.protocol.oidc.mappers.OIDCProtocolMapper`.

---

## User Storage SPI for External Databases

Bridge Keycloak to an external user database (legacy DB, HR system, CRM) without
migrating users.

```java
package com.example.keycloak.storage;

import org.keycloak.component.ComponentModel;
import org.keycloak.credential.CredentialInput;
import org.keycloak.credential.CredentialInputValidator;
import org.keycloak.models.*;
import org.keycloak.models.credential.PasswordCredentialModel;
import org.keycloak.storage.StorageId;
import org.keycloak.storage.UserStorageProvider;
import org.keycloak.storage.user.UserLookupProvider;
import org.keycloak.storage.user.UserQueryProvider;
import java.sql.*;
import java.util.*;
import java.util.stream.Stream;

public class JdbcUserStorageProvider implements UserStorageProvider,
        UserLookupProvider, UserQueryProvider, CredentialInputValidator {

    private final KeycloakSession session;
    private final ComponentModel model;
    private final Connection dbConnection;

    public JdbcUserStorageProvider(KeycloakSession session, ComponentModel model,
                                   Connection dbConnection) {
        this.session = session;
        this.model = model;
        this.dbConnection = dbConnection;
    }

    @Override
    public UserModel getUserByUsername(RealmModel realm, String username) {
        try (PreparedStatement stmt = dbConnection.prepareStatement(
                "SELECT id, username, email, first_name, last_name FROM users WHERE username = ?")) {
            stmt.setString(1, username);
            ResultSet rs = stmt.executeQuery();
            if (rs.next()) {
                return mapUser(realm, rs);
            }
        } catch (SQLException e) {
            throw new RuntimeException("DB lookup failed", e);
        }
        return null;
    }

    @Override
    public UserModel getUserByEmail(RealmModel realm, String email) {
        try (PreparedStatement stmt = dbConnection.prepareStatement(
                "SELECT id, username, email, first_name, last_name FROM users WHERE email = ?")) {
            stmt.setString(1, email);
            ResultSet rs = stmt.executeQuery();
            if (rs.next()) {
                return mapUser(realm, rs);
            }
        } catch (SQLException e) {
            throw new RuntimeException("DB lookup failed", e);
        }
        return null;
    }

    @Override
    public UserModel getUserById(RealmModel realm, String id) {
        String externalId = StorageId.externalId(id);
        try (PreparedStatement stmt = dbConnection.prepareStatement(
                "SELECT id, username, email, first_name, last_name FROM users WHERE id = ?")) {
            stmt.setString(1, externalId);
            ResultSet rs = stmt.executeQuery();
            if (rs.next()) {
                return mapUser(realm, rs);
            }
        } catch (SQLException e) {
            throw new RuntimeException("DB lookup failed", e);
        }
        return null;
    }

    @Override
    public boolean supportsCredentialType(String credentialType) {
        return PasswordCredentialModel.TYPE.equals(credentialType);
    }

    @Override
    public boolean isConfiguredFor(RealmModel realm, UserModel user, String credentialType) {
        return supportsCredentialType(credentialType);
    }

    @Override
    public boolean isValid(RealmModel realm, UserModel user, CredentialInput input) {
        if (!supportsCredentialType(input.getType())) return false;
        String externalId = StorageId.externalId(user.getId());
        try (PreparedStatement stmt = dbConnection.prepareStatement(
                "SELECT password_hash FROM users WHERE id = ?")) {
            stmt.setString(1, externalId);
            ResultSet rs = stmt.executeQuery();
            if (rs.next()) {
                String storedHash = rs.getString("password_hash");
                return PasswordHasher.verify(input.getChallengeResponse(), storedHash);
            }
        } catch (SQLException e) {
            throw new RuntimeException("Credential validation failed", e);
        }
        return false;
    }

    @Override
    public Stream<UserModel> searchForUserStream(RealmModel realm, Map<String, String> params,
                                                  Integer firstResult, Integer maxResults) {
        String search = params.getOrDefault(UserModel.SEARCH, "");
        List<UserModel> users = new ArrayList<>();
        try (PreparedStatement stmt = dbConnection.prepareStatement(
                "SELECT id, username, email, first_name, last_name FROM users " +
                "WHERE username LIKE ? OR email LIKE ? ORDER BY username LIMIT ? OFFSET ?")) {
            stmt.setString(1, "%" + search + "%");
            stmt.setString(2, "%" + search + "%");
            stmt.setInt(3, maxResults != null ? maxResults : 20);
            stmt.setInt(4, firstResult != null ? firstResult : 0);
            ResultSet rs = stmt.executeQuery();
            while (rs.next()) {
                users.add(mapUser(realm, rs));
            }
        } catch (SQLException e) {
            throw new RuntimeException("User search failed", e);
        }
        return users.stream();
    }

    @Override
    public int getUsersCount(RealmModel realm) {
        try (Statement stmt = dbConnection.createStatement()) {
            ResultSet rs = stmt.executeQuery("SELECT COUNT(*) FROM users");
            rs.next();
            return rs.getInt(1);
        } catch (SQLException e) {
            return 0;
        }
    }

    private UserModel mapUser(RealmModel realm, ResultSet rs) throws SQLException {
        ExternalUserAdapter adapter = new ExternalUserAdapter(session, realm, model,
            rs.getString("id"), rs.getString("username"));
        adapter.setEmail(rs.getString("email"));
        adapter.setFirstName(rs.getString("first_name"));
        adapter.setLastName(rs.getString("last_name"));
        return adapter;
    }

    @Override
    public void close() {
        try { dbConnection.close(); } catch (SQLException ignored) {}
    }
}
```

### Factory

```java
package com.example.keycloak.storage;

import org.keycloak.component.ComponentModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.storage.UserStorageProviderFactory;
import java.sql.DriverManager;
import java.util.List;

public class JdbcUserStorageProviderFactory
        implements UserStorageProviderFactory<JdbcUserStorageProvider> {

    @Override
    public String getId() { return "jdbc-user-provider"; }

    @Override
    public JdbcUserStorageProvider create(KeycloakSession session, ComponentModel model) {
        String jdbcUrl = model.get("jdbcUrl");
        String dbUser = model.get("dbUser");
        String dbPassword = model.get("dbPassword");
        try {
            var conn = DriverManager.getConnection(jdbcUrl, dbUser, dbPassword);
            return new JdbcUserStorageProvider(session, model, conn);
        } catch (Exception e) {
            throw new RuntimeException("Cannot connect to external DB", e);
        }
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return List.of(
            new ProviderConfigProperty("jdbcUrl", "JDBC URL",
                "JDBC connection URL", ProviderConfigProperty.STRING_TYPE, ""),
            new ProviderConfigProperty("dbUser", "DB Username",
                "Database username", ProviderConfigProperty.STRING_TYPE, ""),
            new ProviderConfigProperty("dbPassword", "DB Password",
                "Database password", ProviderConfigProperty.PASSWORD, "")
        );
    }
}
```

Register in `META-INF/services/org.keycloak.storage.UserStorageProviderFactory`.

---

## Custom REST Endpoints

Extend Keycloak's REST API with custom endpoints using the `RealmResourceProvider` SPI.

```java
package com.example.keycloak.rest;

import org.keycloak.models.KeycloakSession;
import org.keycloak.services.resource.RealmResourceProvider;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.util.Map;

public class CustomApiResourceProvider implements RealmResourceProvider {

    private final KeycloakSession session;

    public CustomApiResourceProvider(KeycloakSession session) {
        this.session = session;
    }

    @Override
    public Object getResource() { return this; }

    @GET
    @Path("user-stats")
    @Produces(MediaType.APPLICATION_JSON)
    public Response getUserStats() {
        var realm = session.getContext().getRealm();
        long userCount = session.users().getUsersCount(realm);
        long activeSessionCount = session.sessions()
            .getActiveUserSessions(realm, realm.getClientsStream().findFirst().orElse(null));

        return Response.ok(Map.of(
            "realm", realm.getName(),
            "totalUsers", userCount,
            "activeSessions", activeSessionCount
        )).build();
    }

    @POST
    @Path("bulk-disable")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response bulkDisableUsers(List<String> userIds) {
        // Require admin role
        var auth = AdminAuth.authenticateRealmAdminRequest(session);
        if (auth == null) {
            return Response.status(401).build();
        }

        var realm = session.getContext().getRealm();
        int disabled = 0;
        for (String userId : userIds) {
            var user = session.users().getUserById(realm, userId);
            if (user != null) {
                user.setEnabled(false);
                disabled++;
            }
        }
        return Response.ok(Map.of("disabled", disabled)).build();
    }

    @Override
    public void close() {}
}
```

### Factory and Registration

```java
public class CustomApiResourceProviderFactory implements RealmResourceProviderFactory {
    @Override
    public String getId() { return "custom-api"; }

    @Override
    public RealmResourceProvider create(KeycloakSession session) {
        return new CustomApiResourceProvider(session);
    }

    @Override public void init(Config.Scope config) {}
    @Override public void postInit(KeycloakSessionFactory factory) {}
    @Override public void close() {}
}
```

Register in `META-INF/services/org.keycloak.services.resource.RealmResourceProviderFactory`.

Access at: `GET /realms/{realm}/custom-api/user-stats`

---

## Authorization Services Deep Dive

### Policy Types

**Role Policy** — Grants access based on realm or client roles:

```json
{
  "name": "admin-only-policy",
  "type": "role",
  "logic": "POSITIVE",
  "roles": [
    { "id": "realm-admin-role-id", "required": true }
  ]
}
```

**Group Policy** — Access based on group membership:

```json
{
  "name": "engineering-policy",
  "type": "group",
  "logic": "POSITIVE",
  "groups": [
    { "id": "engineering-group-id", "extendChildren": true }
  ]
}
```

**Time Policy** — Restrict access to specific time windows:

```json
{
  "name": "business-hours-policy",
  "type": "time",
  "logic": "POSITIVE",
  "notBefore": "2024-01-01 00:00:00",
  "notOnOrAfter": "2025-12-31 23:59:59",
  "dayMonth": "",
  "hour": "9",
  "hourEnd": "17",
  "minute": "0",
  "minuteEnd": "0"
}
```

**JavaScript Policy** — Custom logic evaluated at runtime:

```javascript
// Enable with: --features=scripts (disabled by default for security)
var context = $evaluation.getContext();
var identity = context.getIdentity();
var attributes = identity.getAttributes();
var email = attributes.getValue('email').asString(0);

if (email.endsWith('@company.com')) {
    $evaluation.grant();
} else {
    $evaluation.deny();
}
```

**Aggregate Policy** — Combine multiple policies with decision strategies:

```json
{
  "name": "combined-access-policy",
  "type": "aggregate",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "policies": ["admin-only-policy", "business-hours-policy"]
}
```

### Decision Strategies

- **UNANIMOUS** — All policies must grant access (AND logic)
- **AFFIRMATIVE** — At least one policy must grant access (OR logic)
- **CONSENSUS** — Majority of policies must grant access

### Permission Evaluation

Create resource-based or scope-based permissions linking resources to policies:

```bash
# Create a resource
curl -X POST "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID/authz/resource-server/resource" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Document",
    "type": "urn:app:resources:document",
    "uris": ["/api/documents/*"],
    "scopes": [{"name": "read"}, {"name": "write"}, {"name": "delete"}]
  }'

# Create a scope-based permission
curl -X POST "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID/authz/resource-server/permission/scope" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "document-write-permission",
    "scopes": ["write"],
    "policies": ["admin-only-policy"],
    "decisionStrategy": "UNANIMOUS"
  }'
```

### Evaluating Permissions in Code

```java
// Server-side permission evaluation
AuthorizationContext authzContext = keycloakSecurityContext.getAuthorizationContext();
if (authzContext.hasResourcePermission("Document")) {
    // User has some permission on Document resource
}
if (authzContext.hasPermission("Document", "write")) {
    // User can write documents
}
```

---

## Token Exchange Patterns

Token exchange (RFC 8693) enables service-to-service delegation. Enable with
`--features=token-exchange`.

### Impersonation

An admin or trusted service acts as another user:

```bash
# Service A impersonates user — requires 'impersonation' role on token-exchange permission
curl -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=service-a" \
  -d "client_secret=service-a-secret" \
  -d "requested_subject=target-user-id" \
  -d "subject_token=$ADMIN_TOKEN" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token"
```

### Delegation (On-behalf-of)

Service B gets a token to call Service C on behalf of the user who called Service B:

```bash
curl -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=service-b" \
  -d "client_secret=service-b-secret" \
  -d "subject_token=$USER_ACCESS_TOKEN" \
  -d "audience=service-c" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token"
```

### Configuring Token Exchange Permissions

In Admin Console, for the target client:
1. Enable "Authorization" on the client
2. Create a "Client" policy referencing the source client
3. Create a token-exchange permission linking the policy

Via Admin API:

```bash
# Grant service-a permission to exchange tokens for service-b's audience
curl -X POST "$KC_URL/admin/realms/$REALM/clients/$SERVICE_B_UUID/authz/resource-server/permission/scope" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "token-exchange-from-service-a",
    "scopes": [{"name": "token-exchange"}],
    "policies": [{"name": "service-a-policy"}]
  }'
```

---

## Fine-Grained Admin Permissions

Keycloak 25+ supports delegating admin capabilities to non-super-admin users.
Enable with `--features=admin-fine-grained-authz`.

### Configurable Permissions

- **Realm management**: Who can manage realm settings
- **Client management**: Per-client create/update/delete/view
- **User management**: CRUD users, manage credentials, assign roles
- **Role management**: Create/assign realm and client roles
- **Group management**: Create/manage groups and membership
- **Identity provider management**: Configure external IdPs

### Setup via Admin API

```bash
# Create a "helpdesk" role that can only manage users and reset passwords
# 1. Create the role
curl -X POST "$KC_URL/admin/realms/$REALM/roles" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "helpdesk-admin"}'

# 2. Assign fine-grained permissions
# Enable permissions on the Users resource
curl -X PUT "$KC_URL/admin/realms/$REALM/users-management-permissions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true}'

# 3. Create a policy for the helpdesk role
# 4. Associate that policy with user-management scopes (view, manage, manage-credentials)
```

---

## Organizations Feature (Keycloak 25+)

Organizations provide multi-tenancy support as a first-class Keycloak feature.
Enable with `--features=organization`.

### Key Concepts

- **Organization**: A tenant entity with its own members, identity providers, and attributes
- **Members**: Users belonging to an organization
- **Organization IdPs**: Dedicated identity providers per organization (e.g., each customer's SAML IdP)
- **Domains**: Verified email domains mapped to organizations for automatic routing

### Configuration via Admin API

```bash
# Create an organization
curl -X POST "$KC_URL/admin/realms/$REALM/organizations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Acme Corp",
    "alias": "acme",
    "enabled": true,
    "domains": [{"name": "acme.com", "verified": true}],
    "attributes": {"plan": ["enterprise"], "industry": ["tech"]}
  }'

# Add a member to an organization
curl -X POST "$KC_URL/admin/realms/$REALM/organizations/$ORG_ID/members" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '"user-uuid-here"'

# Link an IdP to an organization
curl -X POST "$KC_URL/admin/realms/$REALM/organizations/$ORG_ID/identity-providers" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"alias": "acme-saml-idp"}'
```

### Token Claims

Organization membership is automatically included in tokens via the `organization`
claim:

```json
{
  "sub": "user-id",
  "organization": {
    "acme": { "roles": ["member", "admin"] }
  }
}
```

---

## Passkeys / WebAuthn Configuration

Keycloak supports FIDO2/WebAuthn for passwordless authentication.

### Enabling WebAuthn

1. Admin Console → Authentication → Required Actions → Enable "WebAuthn Register"
2. Authentication → Policies → WebAuthn Policy:
   - **RP Entity Name**: Display name shown during registration
   - **Signature Algorithms**: `ES256` (recommended), `RS256`
   - **RP ID**: Your domain (e.g., `auth.example.com`)
   - **Attestation Conveyance**: `none` (recommended), `direct`, or `indirect`
   - **Authenticator Attachment**: `platform` (device biometric), `cross-platform` (security key), or empty (any)
   - **Require Resident Key**: `Yes` for passkeys, `No` for security keys only
   - **User Verification**: `required` (biometric/PIN), `preferred`, or `discouraged`

### Passwordless Flow Setup

1. Clone the Browser flow
2. Add "WebAuthn Passwordless Authenticator" as an alternative execution
3. Remove or make the Username/Password form alternative
4. Set requirement on WebAuthn Passwordless to REQUIRED
5. Bind as the realm's Browser flow

### Passkeys (Discoverable Credentials)

For true passkeys (no username entry needed):

- Set **Require Resident Key** to `Yes` in WebAuthn Passwordless policy
- Set **User Verification** to `required`
- Use **Authenticator Attachment**: `platform` for device passkeys or empty for any

Users register passkeys via Account Console → Security → Passkeys, or during login
if "WebAuthn Register Passwordless" is a required action.

### Conditional WebAuthn

Use a conditional sub-flow to only require WebAuthn if the user has registered a key:

```
Browser Flow (top-level)
├── Cookie (ALTERNATIVE)
├── Identity Provider Redirector (ALTERNATIVE)
└── Forms (ALTERNATIVE, sub-flow)
    ├── Username Form (REQUIRED)
    └── Conditional WebAuthn (CONDITIONAL, sub-flow)
        ├── Condition: User Configured (REQUIRED)
        └── WebAuthn Authenticator (REQUIRED)
```

This avoids blocking users who haven't yet registered a WebAuthn credential.
