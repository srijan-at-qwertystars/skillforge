# Spring Security 6.x Deep Dive

## Table of Contents

- [Architecture Overview](#architecture-overview)
  - [Filter Chain Architecture](#filter-chain-architecture)
  - [Authentication Flow](#authentication-flow)
  - [Authorization Flow](#authorization-flow)
- [SecurityFilterChain Patterns](#securityfilterchain-patterns)
  - [Multiple Filter Chains](#multiple-filter-chains)
  - [Custom Filters](#custom-filters)
  - [Request Matchers](#request-matchers)
- [Method Security](#method-security)
  - [@PreAuthorize and @PostAuthorize](#preauthorize-and-postauthorize)
  - [@Secured and JSR-250](#secured-and-jsr-250)
  - [Custom Security Expressions](#custom-security-expressions)
- [OAuth2 Resource Server](#oauth2-resource-server)
  - [JWT Configuration](#jwt-configuration)
  - [Custom JWT Claims and Authorities](#custom-jwt-claims-and-authorities)
  - [Opaque Token Introspection](#opaque-token-introspection)
- [OAuth2 Client](#oauth2-client)
  - [Authorization Code Flow](#authorization-code-flow)
  - [Client Credentials Flow](#client-credentials-flow)
  - [Token Relay and Propagation](#token-relay-and-propagation)
- [CORS Configuration](#cors-configuration)
  - [Global CORS with SecurityFilterChain](#global-cors-with-securityfilterchain)
  - [Per-Endpoint CORS](#per-endpoint-cors)
- [CSRF for SPAs](#csrf-for-spas)
  - [Cookie-Based CSRF Token](#cookie-based-csrf-token)
  - [Disabling CSRF for APIs](#disabling-csrf-for-apis)
  - [BREACH Protection](#breach-protection)
- [Custom Authentication Providers](#custom-authentication-providers)
  - [Custom AuthenticationProvider](#custom-authenticationprovider)
  - [Custom UserDetailsService](#custom-userdetailsservice)
  - [Multi-Factor Authentication](#multi-factor-authentication)
- [Remember-Me Authentication](#remember-me-authentication)
  - [Persistent Token Approach](#persistent-token-approach)
  - [Configuration](#remember-me-configuration)
- [Session Management](#session-management)
  - [Session Creation Policies](#session-creation-policies)
  - [Concurrent Session Control](#concurrent-session-control)
  - [Session Fixation Protection](#session-fixation-protection)
  - [Spring Session with Redis](#spring-session-with-redis)

---

## Architecture Overview

### Filter Chain Architecture

Spring Security implements security as a chain of servlet filters. The `DelegatingFilterProxy` bridges the servlet container to Spring's `FilterChainProxy`, which delegates to one or more `SecurityFilterChain` instances.

```
Client Request
    │
    ▼
DelegatingFilterProxy (servlet filter)
    │
    ▼
FilterChainProxy
    │
    ├── SecurityFilterChain #1 ("/api/**")
    │   ├── CorsFilter
    │   ├── CsrfFilter
    │   ├── BearerTokenAuthenticationFilter
    │   ├── AuthorizationFilter
    │   └── ExceptionTranslationFilter
    │
    └── SecurityFilterChain #2 ("/**")
        ├── CorsFilter
        ├── CsrfFilter
        ├── UsernamePasswordAuthenticationFilter
        ├── RememberMeAuthenticationFilter
        ├── AuthorizationFilter
        └── ExceptionTranslationFilter
```

**Default filter order (abbreviated):**
1. `ChannelProcessingFilter` — HTTPS redirect
2. `SecurityContextPersistenceFilter` — load/save SecurityContext
3. `CorsFilter` — CORS headers
4. `CsrfFilter` — CSRF protection
5. `LogoutFilter` — logout processing
6. `BearerTokenAuthenticationFilter` — JWT/opaque token
7. `UsernamePasswordAuthenticationFilter` — form login
8. `RememberMeAuthenticationFilter` — remember-me cookie
9. `AnonymousAuthenticationFilter` — anonymous user
10. `ExceptionTranslationFilter` — convert exceptions to HTTP responses
11. `AuthorizationFilter` — URL-based authorization

### Authentication Flow

```
Request with credentials
    │
    ▼
AuthenticationFilter (extracts credentials → Authentication token)
    │
    ▼
AuthenticationManager (ProviderManager)
    │
    ├── AuthenticationProvider #1 (DaoAuthenticationProvider)
    │   └── UserDetailsService → UserDetails → PasswordEncoder.matches()
    │
    ├── AuthenticationProvider #2 (JwtAuthenticationProvider)
    │   └── JwtDecoder → Jwt → JwtAuthenticationConverter
    │
    └── AuthenticationProvider #N
    │
    ▼
Authenticated Authentication → SecurityContextHolder
```

### Authorization Flow

```java
// Authorization is evaluated by AuthorizationManager implementations:
// - RequestMatcherDelegatingAuthorizationManager (URL-based)
// - PreAuthorizeAuthorizationManager (method-based)
// - Jsr250AuthorizationManager (@RolesAllowed)

// The AuthorizationFilter replaces the old FilterSecurityInterceptor in Security 6.x
```

---

## SecurityFilterChain Patterns

### Multiple Filter Chains

```java
@Configuration
@EnableWebSecurity
public class MultiChainSecurityConfig {

    // Chain 1: API endpoints — JWT-based, stateless
    @Bean
    @Order(1)
    public SecurityFilterChain apiFilterChain(HttpSecurity http) throws Exception {
        http.securityMatcher("/api/**")
            .csrf(csrf -> csrf.disable())
            .sessionManagement(sm -> sm.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/public/**").permitAll()
                .requestMatchers("/api/admin/**").hasRole("ADMIN")
                .anyRequest().authenticated()
            )
            .oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()));
        return http.build();
    }

    // Chain 2: Web UI — form login, sessions
    @Bean
    @Order(2)
    public SecurityFilterChain webFilterChain(HttpSecurity http) throws Exception {
        http.securityMatcher("/**")
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/", "/login", "/css/**", "/js/**").permitAll()
                .anyRequest().authenticated()
            )
            .formLogin(form -> form
                .loginPage("/login")
                .defaultSuccessUrl("/dashboard")
                .failureUrl("/login?error=true")
            )
            .logout(logout -> logout
                .logoutSuccessUrl("/login?logout=true")
                .deleteCookies("JSESSIONID")
            )
            .rememberMe(rm -> rm.tokenValiditySeconds(86400));
        return http.build();
    }

    // Chain 3: Actuator — basic auth
    @Bean
    @Order(0)
    public SecurityFilterChain actuatorFilterChain(HttpSecurity http) throws Exception {
        http.securityMatcher("/actuator/**")
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/actuator/health").permitAll()
                .anyRequest().hasRole("OPS")
            )
            .httpBasic(Customizer.withDefaults());
        return http.build();
    }
}
```

### Custom Filters

```java
// JWT authentication filter example
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    private final JwtTokenProvider tokenProvider;

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {
        String token = extractToken(request);
        if (token != null && tokenProvider.validate(token)) {
            Authentication auth = tokenProvider.getAuthentication(token);
            SecurityContextHolder.getContext().setAuthentication(auth);
        }
        filterChain.doFilter(request, response);
    }

    private String extractToken(HttpServletRequest request) {
        String header = request.getHeader("Authorization");
        if (header != null && header.startsWith("Bearer ")) {
            return header.substring(7);
        }
        return null;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return request.getServletPath().startsWith("/api/public/");
    }
}

// Register in the chain
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http.addFilterBefore(
        new JwtAuthenticationFilter(tokenProvider),
        UsernamePasswordAuthenticationFilter.class
    );
    return http.build();
}
```

### Request Matchers

```java
http.authorizeHttpRequests(auth -> auth
    // Exact paths
    .requestMatchers("/login", "/register").permitAll()

    // Ant-style patterns
    .requestMatchers("/api/v1/**").authenticated()

    // HTTP method + pattern
    .requestMatchers(HttpMethod.GET, "/api/products/**").permitAll()
    .requestMatchers(HttpMethod.POST, "/api/products/**").hasRole("ADMIN")
    .requestMatchers(HttpMethod.DELETE, "/api/**").hasRole("ADMIN")

    // Custom RequestMatcher
    .requestMatchers(request -> request.getHeader("X-Internal") != null).hasRole("SERVICE")

    // MVC pattern (recommended for MVC apps — handles trailing slash, suffixes)
    .requestMatchers(MvcRequestMatcher.Builder::pattern, "/users/{id}").authenticated()

    // Catch-all must be last
    .anyRequest().denyAll()
);
```

---

## Method Security

### @PreAuthorize and @PostAuthorize

```java
@Configuration
@EnableMethodSecurity  // replaces @EnableGlobalMethodSecurity
public class MethodSecurityConfig { }

@Service
public class DocumentService {

    // Simple role check
    @PreAuthorize("hasRole('ADMIN')")
    public void deleteAll() { /* ... */ }

    // Check against method parameters
    @PreAuthorize("#userId == authentication.principal.id or hasRole('ADMIN')")
    public UserProfile getProfile(Long userId) { /* ... */ }

    // Complex SpEL with AND/OR
    @PreAuthorize("hasAnyRole('EDITOR', 'ADMIN') and #document.status != 'PUBLISHED'")
    public void editDocument(Document document) { /* ... */ }

    // Post-authorization — filters result after execution
    @PostAuthorize("returnObject.ownerId == authentication.principal.id or hasRole('ADMIN')")
    public Document getDocument(Long id) {
        return documentRepository.findById(id).orElseThrow();
    }

    // Pre-filter collections
    @PreFilter("filterObject.ownerId == authentication.principal.id")
    public void batchDelete(List<Document> documents) { /* ... */ }

    // Post-filter collections
    @PostFilter("filterObject.isPublic or filterObject.ownerId == authentication.principal.id")
    public List<Document> listDocuments() { return documentRepository.findAll(); }
}
```

### @Secured and JSR-250

```java
@Configuration
@EnableMethodSecurity(securedEnabled = true, jsr250Enabled = true)
public class MethodSecurityConfig { }

@Service
public class AdminService {
    @Secured("ROLE_ADMIN")                    // Spring's annotation
    public void adminOnly() { }

    @RolesAllowed({"ADMIN", "MANAGER"})       // JSR-250
    public void managementOnly() { }

    @PermitAll                                 // JSR-250
    public String publicInfo() { return "open"; }
}
```

### Custom Security Expressions

```java
// Custom permission evaluator
@Component
public class CustomPermissionEvaluator implements PermissionEvaluator {
    @Override
    public boolean hasPermission(Authentication auth, Object target, Object permission) {
        if (target instanceof Document doc && permission instanceof String perm) {
            User user = (User) auth.getPrincipal();
            return switch (perm) {
                case "READ" -> doc.isPublic() || doc.getOwnerId().equals(user.getId());
                case "WRITE" -> doc.getOwnerId().equals(user.getId());
                case "DELETE" -> doc.getOwnerId().equals(user.getId())
                                 || user.getRoles().contains("ADMIN");
                default -> false;
            };
        }
        return false;
    }

    @Override
    public boolean hasPermission(Authentication auth, Serializable targetId,
                                  String targetType, Object permission) {
        // Load target by ID and type, then delegate
        return false;
    }
}

// Register it
@Configuration
@EnableMethodSecurity
public class MethodSecurityConfig {
    @Bean
    static MethodSecurityExpressionHandler methodSecurityExpressionHandler(
            CustomPermissionEvaluator evaluator) {
        DefaultMethodSecurityExpressionHandler handler =
            new DefaultMethodSecurityExpressionHandler();
        handler.setPermissionEvaluator(evaluator);
        return handler;
    }
}

// Usage
@PreAuthorize("hasPermission(#doc, 'WRITE')")
public void updateDocument(Document doc) { }
```

---

## OAuth2 Resource Server

### JWT Configuration

```yaml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: https://auth.example.com    # auto-discovers JWKS endpoint
          # OR specify JWKS directly:
          # jwk-set-uri: https://auth.example.com/.well-known/jwks.json
```

```java
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http.oauth2ResourceServer(oauth2 -> oauth2
        .jwt(jwt -> jwt
            .decoder(jwtDecoder())
            .jwtAuthenticationConverter(jwtAuthenticationConverter())
        )
    );
    return http.build();
}

@Bean
public JwtDecoder jwtDecoder() {
    NimbusJwtDecoder decoder = JwtDecoders.fromIssuerLocation("https://auth.example.com");
    // Add custom validation
    OAuth2TokenValidator<Jwt> audienceValidator = token ->
        token.getAudience().contains("my-api")
            ? OAuth2TokenValidatorResult.success()
            : OAuth2TokenValidatorResult.failure(
                new OAuth2Error("invalid_audience", "Expected audience 'my-api'", null));
    OAuth2TokenValidator<Jwt> combined = new DelegatingOAuth2TokenValidator<>(
        JwtValidators.createDefaultWithIssuer("https://auth.example.com"),
        audienceValidator
    );
    decoder.setJwtValidator(combined);
    return decoder;
}
```

### Custom JWT Claims and Authorities

```java
@Bean
public JwtAuthenticationConverter jwtAuthenticationConverter() {
    JwtGrantedAuthoritiesConverter authoritiesConverter = new JwtGrantedAuthoritiesConverter();
    // Map from custom claim "roles" with prefix "ROLE_"
    authoritiesConverter.setAuthoritiesClaimName("roles");
    authoritiesConverter.setAuthorityPrefix("ROLE_");

    JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
    converter.setJwtGrantedAuthoritiesConverter(authoritiesConverter);
    converter.setPrincipalClaimName("preferred_username");
    return converter;
}

// Keycloak-specific: roles nested in realm_access.roles
@Bean
public JwtAuthenticationConverter keycloakJwtConverter() {
    JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
    converter.setJwtGrantedAuthoritiesConverter(jwt -> {
        Map<String, Object> realmAccess = jwt.getClaim("realm_access");
        if (realmAccess == null) return List.of();
        @SuppressWarnings("unchecked")
        List<String> roles = (List<String>) realmAccess.get("roles");
        return roles.stream()
            .map(role -> new SimpleGrantedAuthority("ROLE_" + role.toUpperCase()))
            .collect(Collectors.toList());
    });
    return converter;
}
```

### Opaque Token Introspection

```yaml
spring:
  security:
    oauth2:
      resourceserver:
        opaquetoken:
          introspection-uri: https://auth.example.com/oauth2/introspect
          client-id: my-api
          client-secret: ${OAUTH_CLIENT_SECRET}
```

```java
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http.oauth2ResourceServer(oauth2 -> oauth2
        .opaqueToken(opaque -> opaque
            .introspector(customIntrospector()))
    );
    return http.build();
}

@Bean
public OpaqueTokenIntrospector customIntrospector() {
    OpaqueTokenIntrospector delegate = new NimbusOpaqueTokenIntrospector(
        "https://auth.example.com/oauth2/introspect", "client-id", "client-secret");
    return token -> {
        OAuth2AuthenticatedPrincipal principal = delegate.introspect(token);
        // Add custom authorities
        return new DefaultOAuth2AuthenticatedPrincipal(
            principal.getName(), principal.getAttributes(),
            extractAuthorities(principal));
    };
}
```

---

## OAuth2 Client

### Authorization Code Flow

```yaml
spring:
  security:
    oauth2:
      client:
        registration:
          google:
            client-id: ${GOOGLE_CLIENT_ID}
            client-secret: ${GOOGLE_CLIENT_SECRET}
            scope: openid, profile, email
          github:
            client-id: ${GITHUB_CLIENT_ID}
            client-secret: ${GITHUB_CLIENT_SECRET}
            scope: user:email, read:org
        provider:
          custom-oidc:
            issuer-uri: https://auth.example.com
```

```java
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http.oauth2Login(oauth2 -> oauth2
            .loginPage("/login")
            .userInfoEndpoint(userInfo -> userInfo
                .userService(customOAuth2UserService())
            )
            .successHandler((req, resp, auth) -> resp.sendRedirect("/dashboard"))
        )
        .oauth2Client(Customizer.withDefaults());
    return http.build();
}

@Bean
public OAuth2UserService<OAuth2UserRequest, OAuth2User> customOAuth2UserService() {
    DefaultOAuth2UserService delegate = new DefaultOAuth2UserService();
    return userRequest -> {
        OAuth2User oauthUser = delegate.loadUser(userRequest);
        // Map external OAuth2 user to internal user
        String email = oauthUser.getAttribute("email");
        User localUser = userRepository.findByEmail(email)
            .orElseGet(() -> userRepository.save(new User(email, oauthUser.getName())));
        Set<GrantedAuthority> authorities = new HashSet<>(oauthUser.getAuthorities());
        authorities.addAll(localUser.getRoles().stream()
            .map(r -> new SimpleGrantedAuthority("ROLE_" + r))
            .toList());
        return new DefaultOAuth2User(authorities, oauthUser.getAttributes(), "email");
    };
}
```

### Client Credentials Flow

For service-to-service communication:

```yaml
spring:
  security:
    oauth2:
      client:
        registration:
          internal-api:
            provider: auth-server
            client-id: ${SERVICE_CLIENT_ID}
            client-secret: ${SERVICE_CLIENT_SECRET}
            authorization-grant-type: client_credentials
            scope: api.read, api.write
        provider:
          auth-server:
            token-uri: https://auth.example.com/oauth2/token
```

```java
@Bean
public RestClient restClient(OAuth2AuthorizedClientManager authorizedClientManager) {
    OAuth2ClientHttpRequestInterceptor interceptor =
        new OAuth2ClientHttpRequestInterceptor(authorizedClientManager);
    interceptor.setClientRegistrationIdResolver(request -> "internal-api");
    return RestClient.builder()
        .baseUrl("https://internal-service.example.com")
        .requestInterceptor(interceptor)
        .build();
}
```

### Token Relay and Propagation

For gateway or BFF patterns — propagate the user's token to downstream services:

```java
// With Spring Cloud Gateway
@Bean
public RouteLocator routes(RouteLocatorBuilder builder) {
    return builder.routes()
        .route("user-service", r -> r.path("/api/users/**")
            .filters(f -> f.tokenRelay())
            .uri("lb://user-service"))
        .build();
}

// With RestClient — propagate token manually
@Bean
public RestClient tokenRelayRestClient() {
    return RestClient.builder()
        .requestInterceptor((request, body, execution) -> {
            Authentication auth = SecurityContextHolder.getContext().getAuthentication();
            if (auth instanceof JwtAuthenticationToken jwtAuth) {
                request.getHeaders().setBearerAuth(jwtAuth.getToken().getTokenValue());
            }
            return execution.execute(request, body);
        })
        .build();
}
```

---

## CORS Configuration

### Global CORS with SecurityFilterChain

```java
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http.cors(cors -> cors.configurationSource(corsConfigurationSource()));
    return http.build();
}

@Bean
public CorsConfigurationSource corsConfigurationSource() {
    CorsConfiguration config = new CorsConfiguration();
    config.setAllowedOrigins(List.of(
        "https://app.example.com",
        "https://admin.example.com"
    ));
    config.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"));
    config.setAllowedHeaders(List.of("Authorization", "Content-Type", "X-Requested-With"));
    config.setExposedHeaders(List.of("X-Total-Count", "Link"));
    config.setAllowCredentials(true);
    config.setMaxAge(3600L);

    UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
    source.registerCorsConfiguration("/api/**", config);
    return source;
}
```

### Per-Endpoint CORS

```java
@RestController
@RequestMapping("/api/v1/products")
@CrossOrigin(origins = "https://shop.example.com", maxAge = 3600)
public class ProductController {

    @CrossOrigin(origins = "https://partner.example.com")
    @GetMapping("/catalog")
    public List<Product> catalog() { /* ... */ }
}
```

⚠️ When using Spring Security, always configure CORS through `HttpSecurity.cors()` — it must run BEFORE the security filter chain. `@CrossOrigin` on controllers alone won't work if preflight requests are blocked by security.

---

## CSRF for SPAs

### Cookie-Based CSRF Token

For SPAs (React, Angular, Vue) that need CSRF protection:

```java
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http.csrf(csrf -> csrf
        .csrfTokenRepository(CookieCsrfTokenRepository.withHttpOnlyFalse())
        .csrfTokenRequestHandler(new SpaCsrfTokenRequestHandler())
    );
    return http.build();
}

// SPA-compatible CSRF handler (Spring Security 6.x)
public final class SpaCsrfTokenRequestHandler extends CsrfTokenRequestAttributeHandler {
    private final CsrfTokenRequestHandler delegate = new XorCsrfTokenRequestAttributeHandler();

    @Override
    public void handle(HttpServletRequest request, HttpServletResponse response,
                       Supplier<CsrfToken> csrfToken) {
        this.delegate.handle(request, response, csrfToken);
    }

    @Override
    public String resolveCsrfTokenValue(HttpServletRequest request, CsrfToken csrfToken) {
        if (StringUtils.hasText(request.getHeader(csrfToken.getHeaderName()))) {
            return super.resolveCsrfTokenValue(request, csrfToken);
        }
        return this.delegate.resolveCsrfTokenValue(request, csrfToken);
    }
}
```

**Frontend integration (JavaScript):**
```javascript
// Read CSRF token from cookie
function getCsrfToken() {
    return document.cookie.split('; ')
        .find(row => row.startsWith('XSRF-TOKEN='))
        ?.split('=')[1];
}

// Include in requests
fetch('/api/data', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/json',
        'X-XSRF-TOKEN': getCsrfToken()
    },
    body: JSON.stringify(data)
});
```

### Disabling CSRF for APIs

For stateless APIs using JWT/OAuth2 (no cookies = no CSRF risk):

```java
http.csrf(csrf -> csrf
    .ignoringRequestMatchers("/api/**")  // disable for API routes
);

// Or disable entirely for pure API services
http.csrf(csrf -> csrf.disable());
```

### BREACH Protection

Spring Security 6.x uses `XorCsrfTokenRequestAttributeHandler` by default to protect against BREACH attacks by XOR-encoding the CSRF token on every response.

---

## Custom Authentication Providers

### Custom AuthenticationProvider

```java
@Component
public class LdapFallbackAuthenticationProvider implements AuthenticationProvider {

    private final LdapTemplate ldapTemplate;
    private final UserDetailsService localUserDetailsService;

    @Override
    public Authentication authenticate(Authentication authentication)
            throws AuthenticationException {
        String username = authentication.getName();
        String password = authentication.getCredentials().toString();

        try {
            // Try LDAP first
            ldapTemplate.authenticate("", "(uid=" + username + ")", password);
            UserDetails user = localUserDetailsService.loadUserByUsername(username);
            return new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities());
        } catch (Exception ldapEx) {
            throw new BadCredentialsException("Authentication failed for: " + username);
        }
    }

    @Override
    public boolean supports(Class<?> authentication) {
        return UsernamePasswordAuthenticationToken.class.isAssignableFrom(authentication);
    }
}

// Register — Spring auto-discovers @Component AuthenticationProviders,
// or register explicitly:
@Bean
public AuthenticationManager authenticationManager(
        LdapFallbackAuthenticationProvider ldapProvider,
        DaoAuthenticationProvider daoProvider) {
    return new ProviderManager(List.of(ldapProvider, daoProvider));
}
```

### Custom UserDetailsService

```java
@Service
public class JpaUserDetailsService implements UserDetailsService {

    private final UserRepository userRepository;

    @Override
    @Transactional(readOnly = true)
    public UserDetails loadUserByUsername(String username) throws UsernameNotFoundException {
        return userRepository.findByEmail(username)
            .map(user -> org.springframework.security.core.userdetails.User.builder()
                .username(user.getEmail())
                .password(user.getPasswordHash())
                .roles(user.getRoles().toArray(String[]::new))
                .accountLocked(user.isLocked())
                .accountExpired(user.isExpired())
                .disabled(!user.isEnabled())
                .build())
            .orElseThrow(() -> new UsernameNotFoundException("User not found: " + username));
    }
}

@Bean
public DaoAuthenticationProvider daoAuthenticationProvider(
        JpaUserDetailsService userDetailsService, PasswordEncoder passwordEncoder) {
    DaoAuthenticationProvider provider = new DaoAuthenticationProvider();
    provider.setUserDetailsService(userDetailsService);
    provider.setPasswordEncoder(passwordEncoder);
    return provider;
}
```

### Multi-Factor Authentication

```java
// Custom MFA authentication token
public class MfaAuthenticationToken extends AbstractAuthenticationToken {
    private final Object principal;
    private final String mfaCode;

    public MfaAuthenticationToken(Object principal, String mfaCode) {
        super(null);
        this.principal = principal;
        this.mfaCode = mfaCode;
        setAuthenticated(false);
    }
    // getters...
}

// MFA provider
@Component
public class MfaAuthenticationProvider implements AuthenticationProvider {
    private final TotpService totpService;
    private final UserDetailsService userDetailsService;

    @Override
    public Authentication authenticate(Authentication auth) throws AuthenticationException {
        MfaAuthenticationToken mfaToken = (MfaAuthenticationToken) auth;
        UserDetails user = userDetailsService.loadUserByUsername(mfaToken.getName());
        if (!totpService.verify(user.getUsername(), mfaToken.getMfaCode())) {
            throw new BadCredentialsException("Invalid MFA code");
        }
        return new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities());
    }

    @Override
    public boolean supports(Class<?> authentication) {
        return MfaAuthenticationToken.class.isAssignableFrom(authentication);
    }
}

// MFA controller
@RestController
public class MfaController {
    private final AuthenticationManager authManager;

    @PostMapping("/api/auth/mfa/verify")
    public ResponseEntity<TokenResponse> verifyMfa(@RequestBody MfaRequest request) {
        Authentication auth = authManager.authenticate(
            new MfaAuthenticationToken(request.username(), request.code()));
        String token = jwtTokenProvider.generateToken(auth);
        return ResponseEntity.ok(new TokenResponse(token));
    }
}
```

---

## Remember-Me Authentication

### Persistent Token Approach

```java
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http.rememberMe(rm -> rm
        .tokenRepository(persistentTokenRepository())
        .tokenValiditySeconds(7 * 24 * 3600)   // 7 days
        .userDetailsService(userDetailsService)
        .key("uniqueAndSecretKey")
        .rememberMeParameter("remember-me")     // form parameter name
        .rememberMeCookieName("remember-me")    // cookie name
    );
    return http.build();
}

@Bean
public PersistentTokenRepository persistentTokenRepository() {
    JdbcTokenRepositoryImpl repo = new JdbcTokenRepositoryImpl();
    repo.setDataSource(dataSource);
    // repo.setCreateTableOnStartup(true); // first run only
    return repo;
}
```

**Required table:**
```sql
CREATE TABLE persistent_logins (
    username  VARCHAR(64) NOT NULL,
    series    VARCHAR(64) PRIMARY KEY,
    token     VARCHAR(64) NOT NULL,
    last_used TIMESTAMP   NOT NULL
);
```

### Remember-Me Configuration

```yaml
# Secure cookie settings for production
server:
  servlet:
    session:
      cookie:
        secure: true          # HTTPS only
        http-only: true       # not accessible via JavaScript
        same-site: lax        # CSRF protection
```

---

## Session Management

### Session Creation Policies

```java
http.sessionManagement(sm -> sm
    .sessionCreationPolicy(SessionCreationPolicy.STATELESS)  // for APIs
    // .sessionCreationPolicy(SessionCreationPolicy.IF_REQUIRED)  // default
    // .sessionCreationPolicy(SessionCreationPolicy.ALWAYS)
    // .sessionCreationPolicy(SessionCreationPolicy.NEVER)     // don't create, use if exists
);
```

| Policy | Use Case |
|---|---|
| `STATELESS` | REST APIs with JWT/OAuth2. No session, no CSRF. |
| `IF_REQUIRED` | Default. Creates session when needed. |
| `ALWAYS` | Traditional web apps needing sessions. |
| `NEVER` | Don't create sessions but use existing ones (shared auth). |

### Concurrent Session Control

```java
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http.sessionManagement(sm -> sm
        .maximumSessions(1)                    // one session per user
        .maxSessionsPreventsLogin(true)        // reject new login (vs expire old)
        .expiredUrl("/login?expired=true")     // redirect on session expiry
        .sessionRegistry(sessionRegistry())
    );
    return http.build();
}

@Bean
public SessionRegistry sessionRegistry() {
    return new SessionRegistryImpl();
}

// Required listener for session tracking
@Bean
public HttpSessionEventPublisher httpSessionEventPublisher() {
    return new HttpSessionEventPublisher();
}

// Admin: list active sessions
@RestController
@PreAuthorize("hasRole('ADMIN')")
public class SessionController {
    private final SessionRegistry sessionRegistry;

    @GetMapping("/api/admin/sessions")
    public List<SessionInfo> activeSessions() {
        return sessionRegistry.getAllPrincipals().stream()
            .flatMap(p -> sessionRegistry.getAllSessions(p, false).stream())
            .map(si -> new SessionInfo(si.getSessionId(), si.getPrincipal().toString(),
                                       si.getLastRequest(), si.isExpired()))
            .toList();
    }

    @DeleteMapping("/api/admin/sessions/{sessionId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void expireSession(@PathVariable String sessionId) {
        sessionRegistry.getSessionInformation(sessionId).expireNow();
    }
}
```

### Session Fixation Protection

```java
http.sessionManagement(sm -> sm
    .sessionFixation(sf -> sf.newSession())      // default: create new session on auth
    // .sessionFixation(sf -> sf.migrateSession()) // migrate attributes to new session
    // .sessionFixation(sf -> sf.changeSessionId()) // change ID, keep session
    // .sessionFixation(sf -> sf.none())            // no protection (NOT recommended)
);
```

### Spring Session with Redis

Externalize sessions for horizontal scaling:

```kotlin
// build.gradle.kts
implementation("org.springframework.boot:spring-boot-starter-data-redis")
implementation("org.springframework.session:spring-session-data-redis")
```

```yaml
spring:
  session:
    store-type: redis
    redis:
      namespace: myapp:sessions
    timeout: 30m
  data:
    redis:
      host: ${REDIS_HOST:localhost}
      port: ${REDIS_PORT:6379}
```

```java
@Configuration
@EnableRedisHttpSession(maxInactiveIntervalInSeconds = 1800)
public class SessionConfig {
    @Bean
    public CookieSerializer cookieSerializer() {
        DefaultCookieSerializer serializer = new DefaultCookieSerializer();
        serializer.setCookieName("SESSION");
        serializer.setSameSite("Lax");
        serializer.setUseSecureCookie(true);
        serializer.setDomainName("example.com");
        return serializer;
    }
}
```
