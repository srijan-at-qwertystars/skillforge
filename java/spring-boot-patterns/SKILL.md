---
name: spring-boot-patterns
description: |
  Use when user builds Spring Boot applications, asks about @RestController, Spring Data JPA/R2DBC, Spring Security configuration, dependency injection, exception handling with @ControllerAdvice, or Spring Boot testing (@SpringBootTest, @WebMvcTest, @DataJpaTest).
  Do NOT use for legacy Spring XML config, Spring Framework without Boot, or Java EE/Jakarta EE patterns unrelated to Spring Boot.
---

# Spring Boot Patterns and Best Practices

Spring Boot 3.x / Spring Framework 6.x on Java 17+.

## 1. Project Structure and Layered Architecture

Organize by feature, not by technical layer. Each feature package contains its controller, service, repository, and DTOs. Keep controllers thin — delegate to services. Services hold business logic. Repositories handle persistence. Use Java records for DTOs:

```java
public record OrderDTO(Long id, String status, BigDecimal total) {}
```

---

## 2. REST Controllers

```java
@RestController
@RequestMapping("/api/v1/orders")
@RequiredArgsConstructor
public class OrderController {
    private final OrderService orderService;

    @GetMapping
    public Page<OrderDTO> list(Pageable pageable) { return orderService.findAll(pageable); }

    @GetMapping("/{id}")
    public OrderDTO get(@PathVariable Long id) { return orderService.findById(id); }

    @PostMapping
    public ResponseEntity<OrderDTO> create(@Valid @RequestBody CreateOrderRequest req) {
        OrderDTO created = orderService.create(req);
        return ResponseEntity.created(URI.create("/api/v1/orders/" + created.id())).body(created);
    }
}
```

### Validation with Jakarta Bean Validation

```java
public record CreateOrderRequest(
    @NotBlank String customerName,
    @NotEmpty List<@Valid OrderItemRequest> items
) {}
public record OrderItemRequest(@NotNull Long productId, @Min(1) int quantity) {}
```

Spring Boot auto-negotiates JSON by default. Add XML with `jackson-dataformat-xml` on classpath.

---

## 3. Exception Handling — @ControllerAdvice and ProblemDetail (RFC 7807)

Enable RFC 7807 responses: `spring.mvc.problemdetails.enabled=true`

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(ResourceNotFoundException.class)
    public ProblemDetail handleNotFound(ResourceNotFoundException ex, HttpServletRequest req) {
        ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.NOT_FOUND);
        problem.setTitle("Resource Not Found");
        problem.setDetail(ex.getMessage());
        problem.setInstance(URI.create(req.getRequestURI()));
        problem.setProperty("timestamp", Instant.now());
        return problem;
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ProblemDetail handleValidation(MethodArgumentNotValidException ex) {
        ProblemDetail problem = ProblemDetail.forStatus(HttpStatus.BAD_REQUEST);
        problem.setTitle("Validation Failed");
        var errors = ex.getBindingResult().getFieldErrors().stream()
            .collect(Collectors.toMap(FieldError::getField,
                fe -> fe.getDefaultMessage() != null ? fe.getDefaultMessage() : "invalid",
                (a, b) -> a));
        problem.setProperty("fieldErrors", errors);
        return problem;
    }
}
```

---

## 4. Dependency Injection Patterns

Use constructor injection with `final` fields. With a single constructor, `@Autowired` is optional. Use Lombok `@RequiredArgsConstructor` to eliminate boilerplate:

```java
@Service
@RequiredArgsConstructor
public class OrderService {
    private final OrderRepository orderRepository;
    private final PaymentGateway paymentGateway;
}
```

### Profiles and Conditional Beans

```java
@Configuration
public class PaymentConfig {
    @Bean
    @Profile("production")
    public PaymentGateway stripeGateway(StripeProperties props) {
        return new StripePaymentGateway(props);
    }

    @Bean
    @Profile("!production")
    public PaymentGateway fakeGateway() { return new FakePaymentGateway(); }
}
```

Use `@ConditionalOnProperty(name = "app.cache.enabled", havingValue = "true")` for feature flags.

---

## 5. Spring Data JPA

### Repository Basics

```java
public interface OrderRepository extends JpaRepository<Order, Long> {
    List<Order> findByStatus(OrderStatus status);

    @Query("SELECT o FROM Order o WHERE o.customer.email = :email")
    Page<Order> findByCustomerEmail(@Param("email") String email, Pageable pageable);
}
```

### Specifications for Dynamic Queries

```java
public interface OrderRepository extends JpaRepository<Order, Long>,
        JpaSpecificationExecutor<Order> {}

public class OrderSpecs {
    public static Specification<Order> hasStatus(OrderStatus status) {
        return (root, query, cb) -> cb.equal(root.get("status"), status);
    }
    public static Specification<Order> createdAfter(LocalDate date) {
        return (root, query, cb) -> cb.greaterThan(root.get("createdAt"), date);
    }
}
// Usage: repo.findAll(hasStatus(PENDING).and(createdAfter(cutoff)), PageRequest.of(0, 20));
```

### Projections

Use interface projections to fetch only needed columns:

```java
public interface OrderSummary {
    Long getId();
    String getStatus();
}
List<OrderSummary> findByCustomerId(Long customerId);
```

Or DTO projections via JPQL:

```java
@Query("SELECT new com.example.app.order.OrderDTO(o.id, o.status, o.total) FROM Order o")
List<OrderDTO> findAllProjected();
```

### Avoiding N+1 Queries

Use `@EntityGraph` or `JOIN FETCH`:

```java
@EntityGraph(attributePaths = {"items", "customer"})
List<Order> findByStatus(OrderStatus status);

@Query("SELECT o FROM Order o JOIN FETCH o.items WHERE o.id = :id")
Optional<Order> findByIdWithItems(@Param("id") Long id);
```

Set `spring.jpa.properties.hibernate.default_batch_fetch_size=50` as a global fallback.

### Pagination

Accept `Pageable` in controller methods. Spring resolves from `?page=0&size=20&sort=createdAt,desc`.

---

## 6. Spring Security

### SecurityFilterChain Configuration

`WebSecurityConfigurerAdapter` is removed. Use `SecurityFilterChain` beans:

```java
@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class SecurityConfig {
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .sessionManagement(sm -> sm.sessionCreationPolicy(STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/public/**", "/actuator/health").permitAll()
                .requestMatchers("/api/admin/**").hasRole("ADMIN")
                .anyRequest().authenticated())
            .oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()));
        return http.build();
    }
}
```

### OAuth2 Resource Server (JWT)

```yaml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: https://auth.example.com/issuer
```

Map custom claims to authorities with `JwtAuthenticationConverter`:

```java
@Bean
public JwtAuthenticationConverter jwtAuthenticationConverter() {
    var grantedAuthorities = new JwtGrantedAuthoritiesConverter();
    grantedAuthorities.setAuthoritiesClaimName("roles");
    grantedAuthorities.setAuthorityPrefix("ROLE_");
    var converter = new JwtAuthenticationConverter();
    converter.setJwtGrantedAuthoritiesConverter(grantedAuthorities);
    return converter;
}
```

### Method Security

```java
@PreAuthorize("hasRole('ADMIN')")
public void deleteOrder(Long id) { ... }

@PreAuthorize("#order.customerId == authentication.principal.claims['sub']")
public void updateOrder(Order order) { ... }
```

---

## 7. Configuration

### application.yml with Profiles

```yaml
spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/app
    username: ${DB_USERNAME}
    password: ${DB_PASSWORD}
  jpa:
    open-in-view: false
    hibernate.ddl-auto: validate
    properties.hibernate.default_batch_fetch_size: 50
  profiles.active: ${SPRING_PROFILES_ACTIVE:dev}
---
spring:
  config.activate.on-profile: dev
  datasource.url: jdbc:h2:mem:devdb
```

Always set `spring.jpa.open-in-view=false` to prevent lazy loading outside transactions.

### @ConfigurationProperties

```java
@ConfigurationProperties(prefix = "app.payment")
public record PaymentProperties(String apiKey, String webhookSecret, Duration timeout) {}
```

Enable with `@EnableConfigurationProperties(PaymentProperties.class)` or `@ConfigurationPropertiesScan`.

---

## 8. Testing Pyramid

### Unit Tests — No Spring Context

```java
class OrderServiceTest {
    private final OrderRepository repo = mock(OrderRepository.class);
    private final OrderService service = new OrderService(repo, mock(PaymentGateway.class));

    @Test
    void create_validRequest_returnsOrder() {
        when(repo.save(any())).thenAnswer(inv -> inv.getArgument(0));
        OrderDTO result = service.create(new CreateOrderRequest("Alice", List.of()));
        assertThat(result.status()).isEqualTo("PENDING");
    }
}
```

### @WebMvcTest — Controller Slice

```java
@WebMvcTest(OrderController.class)
class OrderControllerTest {
    @Autowired MockMvc mockMvc;
    @MockBean OrderService orderService;

    @Test
    void get_existingOrder_returns200() throws Exception {
        when(orderService.findById(1L)).thenReturn(new OrderDTO(1L, "PENDING", BigDecimal.TEN));
        mockMvc.perform(get("/api/v1/orders/1"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.status").value("PENDING"));
    }

    @Test
    void create_invalidRequest_returns400() throws Exception {
        mockMvc.perform(post("/api/v1/orders")
                .contentType(APPLICATION_JSON).content("{}"))
            .andExpect(status().isBadRequest());
    }
}
```

### @DataJpaTest — Repository Slice with Testcontainers

```java
@DataJpaTest
@Testcontainers
@AutoConfigureTestDatabase(replace = NONE)
class OrderRepositoryTest {
    @Container
    static PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:16");

    @DynamicPropertySource
    static void dbProps(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", pg::getJdbcUrl);
        registry.add("spring.datasource.username", pg::getUsername);
        registry.add("spring.datasource.password", pg::getPassword);
    }

    @Autowired OrderRepository repository;

    @Test
    void findByStatus_returnsPendingOrders() {
        repository.save(new Order("Alice", OrderStatus.PENDING));
        assertThat(repository.findByStatus(OrderStatus.PENDING)).hasSize(1);
    }
}
```

Reserve `@SpringBootTest` for end-to-end flows. Use `webEnvironment = RANDOM_PORT` with `TestRestTemplate` or `WebTestClient`. Combine with Testcontainers for realistic external dependencies.

---

## 9. Actuator and Production Readiness

```yaml
management:
  endpoints.web.exposure.include: health,info,metrics,prometheus
  endpoint.health:
    show-details: when_authorized
    probes.enabled: true
```

### Custom Health Indicator

```java
@Component
@RequiredArgsConstructor
public class PaymentGatewayHealthIndicator implements HealthIndicator {
    private final PaymentGateway gateway;

    @Override
    public Health health() {
        try {
            gateway.ping();
            return Health.up().withDetail("provider", "stripe").build();
        } catch (Exception e) {
            return Health.down(e).build();
        }
    }
}
```

### Custom Actuator Endpoint

```java
@Endpoint(id = "appinfo")
@Component
public class AppInfoEndpoint {
    @ReadOperation
    public Map<String, Object> info() {
        return Map.of("version", "2.1.0", "startedAt", Instant.now());
    }
}
```

---

## 10. Logging

### SLF4J and Structured Logging (Spring Boot 3.4+)

```java
@Service
@Slf4j  // Lombok
public class OrderService {
    public OrderDTO findById(Long id) {
        log.debug("Fetching order id={}", id);
        // ...
    }
}
```

Enable structured JSON output (ECS or GELF) in `application.yml`:

```yaml
logging:
  structured:
    format:
      console: ecs
    ecs:
      service:
        name: order-service
        environment: production
```

### MDC for Request Correlation

```java
@Component
public class CorrelationFilter implements Filter {
    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        String correlationId = Optional.ofNullable(
                ((HttpServletRequest) req).getHeader("X-Correlation-ID"))
            .orElse(UUID.randomUUID().toString());
        MDC.put("correlationId", correlationId);
        try { chain.doFilter(req, res); } finally { MDC.clear(); }
    }
}
```

With Micrometer Tracing, trace IDs propagate to MDC automatically.

## 11. Common Anti-Patterns

| Anti-Pattern | Fix |
|---|---|
| **Field injection** (`@Autowired` on fields) | Use constructor injection with `final` fields |
| **Business logic in controllers** | Move to `@Service` classes |
| **N+1 queries** | Use `JOIN FETCH`, `@EntityGraph`, or batch fetch size |
| **`spring.jpa.open-in-view=true`** | Set to `false`; fetch eagerly in service layer |
| **Catching `Exception` broadly** | Catch specific exceptions in `@ControllerAdvice` |
| **Returning entities from controllers** | Map to DTOs (records) before returning |
| **`@Transactional` without `readOnly`** | Add `@Transactional(readOnly = true)` for queries |
| **Manual `EntityManager`** | Use repository methods, `@Query`, or Specifications |
| **Blocking calls in reactive pipelines** | Offload to `Schedulers.boundedElastic()` |
| **Hardcoded config** | Externalize with `@ConfigurationProperties` or env vars |

## 12. Migration Notes — Spring Boot 3.x / Spring 6.x

- Java 17+ required. Java 21 recommended for virtual threads.
- Upgrade to Spring Boot 2.7.x first, then jump to 3.x.

### Breaking Changes

| Area | Change |
|---|---|
| **Namespace** | `javax.*` → `jakarta.*` (all imports) |
| **Security** | `WebSecurityConfigurerAdapter` removed → `SecurityFilterChain` beans |
| **Security** | `@EnableGlobalMethodSecurity` → `@EnableMethodSecurity` |
| **Properties** | Use `spring-boot-properties-migrator` for renamed/removed props |
| **Hibernate** | Upgraded to 6.x — review HQL/JPQL changes, ID generation |
| **Trailing slash** | Trailing slash matching disabled by default |
| **Observability** | Spring Cloud Sleuth → Micrometer Tracing |

### New Capabilities in 3.x

- **GraalVM native images** via AOT processing.
- **Virtual threads** (Java 21): `spring.threads.virtual.enabled=true`.
- **`@HttpExchange`** declarative HTTP clients replace `RestTemplate`/`WebClient` wiring.
- **`RestClient`**: synchronous replacement for `RestTemplate`.
- **Structured logging** (3.4+): native ECS/GELF JSON output.
- **`@ServiceConnection`** (3.1+): auto-configure Testcontainers connections.

<!-- tested: pass -->
