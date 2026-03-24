---
name: spring-boot-patterns
description: >
  Spring Boot 3.x application patterns and best practices. Use when working with
  Spring Boot, Spring MVC, Spring Data JPA, Spring Security, @RestController,
  @Autowired, @Service, @Repository, @Component, application.yml,
  application.properties, Spring Actuator, Spring Boot Starter dependencies,
  @SpringBootApplication, @ConfigurationProperties, @EnableWebSecurity,
  SecurityFilterChain, OAuth2, JWT authentication, @SpringBootTest, @WebMvcTest,
  @DataJpaTest, Spring profiles, auto-configuration, or Spring Boot DevTools.
  NOT for Micronaut, Quarkus, Jakarta EE without Spring, general Java without
  Spring context, or Spring Framework 4.x/legacy XML-based configuration.
---

# Spring Boot 3.x Patterns

## Project Setup

### Spring Initializr (start.spring.io)

Generate projects via CLI:

```bash
curl https://start.spring.io/starter.zip \
  -d type=gradle-project \
  -d language=java \
  -d bootVersion=3.4.1 \
  -d baseDir=myapp \
  -d groupId=com.example \
  -d artifactId=myapp \
  -d dependencies=web,data-jpa,security,actuator,validation,postgresql \
  -o myapp.zip && unzip myapp.zip
```

### Gradle (build.gradle.kts)

```kotlin
plugins {
    java
    id("org.springframework.boot") version "3.4.1"
    id("io.spring.dependency-management") version "1.1.7"
    id("org.graalvm.buildtools.native") version "0.10.4"  // for native images
}
java { sourceCompatibility = JavaVersion.VERSION_21 }
dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-data-jpa")
    implementation("org.springframework.boot:spring-boot-starter-security")
    implementation("org.springframework.boot:spring-boot-starter-validation")
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    runtimeOnly("org.postgresql:postgresql")
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("org.springframework.security:spring-security-test")
}
```

Maven: use `spring-boot-starter-parent` 3.4.1 as `<parent>`.

## Auto-Configuration

Spring Boot auto-configures beans based on classpath dependencies. Override by defining your own `@Bean` of the same type. Debug with `--debug` flag or `debug=true` in `application.properties` to see the conditions evaluation report.

Exclude specific auto-configurations:

```java
@SpringBootApplication(exclude = { DataSourceAutoConfiguration.class })
public class MyApp { }
```

## REST Controllers

```java
@RestController
@RequestMapping("/api/v1/users")
@Validated
public class UserController {
    private final UserService userService;
    public UserController(UserService userService) { this.userService = userService; }

    @GetMapping
    public Page<UserDto> list(@RequestParam(defaultValue = "0") int page,
                              @RequestParam(defaultValue = "20") int size) {
        return userService.findAll(PageRequest.of(page, size));
    }

    @GetMapping("/{id}")
    public UserDto get(@PathVariable Long id) { return userService.findById(id); }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public UserDto create(@Valid @RequestBody CreateUserRequest req) {
        return userService.create(req);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id) { userService.delete(id); }
}
```

**Input:** `GET /api/v1/users?page=0&size=2`
**Output:**
```json
{
  "content": [{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}],
  "totalElements": 50,
  "totalPages": 25,
  "number": 0
}
```

## Spring Data JPA

### Entity

```java
@Entity
@Table(name = "users")
public class User {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    @Column(nullable = false, unique = true)
    private String email;
    @Column(nullable = false)
    private String name;
    @CreatedDate
    private Instant createdAt;
}
```

### Repository with custom queries and pagination

```java
public interface UserRepository extends JpaRepository<User, Long> {
    Optional<User> findByEmail(String email);
    @Query("SELECT u FROM User u WHERE u.name LIKE %:name%")
    Page<User> searchByName(@Param("name") String name, Pageable pageable);
    @Query(value = "SELECT * FROM users WHERE created_at > :since", nativeQuery = true)
    List<User> findRecentUsers(@Param("since") Instant since);
    boolean existsByEmail(String email);
}
```

### Specifications for dynamic queries

```java
public class UserSpecs {
    public static Specification<User> hasName(String name) {
        return (root, query, cb) -> cb.like(root.get("name"), "%" + name + "%");
    }
    public static Specification<User> createdAfter(Instant date) {
        return (root, query, cb) -> cb.greaterThan(root.get("createdAt"), date);
    }
}
// Usage: userRepo.findAll(hasName("Alice").and(createdAfter(yesterday)), pageable);
```

## Spring Security (Spring Security 6.x)

`WebSecurityConfigurerAdapter` is removed. Use `SecurityFilterChain` beans.

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .sessionManagement(sm -> sm.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/public/**", "/actuator/health").permitAll()
                .requestMatchers("/api/admin/**").hasRole("ADMIN")
                .anyRequest().authenticated()
            )
            .oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()));
        return http.build();
    }

    @Bean
    public JwtDecoder jwtDecoder() {
        return JwtDecoders.fromIssuerLocation("https://auth.example.com");
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }
}
```

Key changes in Spring Security 6.x / Boot 3.x:
- `antMatchers()` → `requestMatchers()`
- Lambda DSL is standard (no chaining `.and()`)
- Use `@EnableMethodSecurity` instead of `@EnableGlobalMethodSecurity`
- `@PreAuthorize("hasRole('ADMIN')")` on methods for fine-grained control

## Configuration

### application.yml with profiles

```yaml
spring:
  application.name: myapp
  datasource:
    url: jdbc:postgresql://localhost:5432/mydb
    username: ${DB_USER}
    password: ${DB_PASSWORD}
  jpa:
    hibernate.ddl-auto: validate
    open-in-view: false
  profiles.active: ${SPRING_PROFILES_ACTIVE:dev}
server.port: 8080
---
spring.config.activate.on-profile: dev
spring.jpa:
  hibernate.ddl-auto: update
  show-sql: true
---
spring.config.activate.on-profile: prod
spring.datasource.hikari.maximum-pool-size: 20
```

### Type-safe configuration with @ConfigurationProperties

```java
@ConfigurationProperties(prefix = "app.mail")
@Validated
public record MailProperties(
    @NotBlank String from, @NotBlank String host,
    @Min(1) @Max(65535) int port, boolean tlsEnabled) {}
```

Enable with `@EnableConfigurationProperties(MailProperties.class)` or `@ConfigurationPropertiesScan`. Properties bind from `app.mail.from`, `app.mail.host`, etc. in application.yml. Kebab-case `tls-enabled` maps to `tlsEnabled`.

## Dependency Injection

Prefer constructor injection (auto-injects with single constructor, no `@Autowired` needed). Use `@Qualifier` to disambiguate, `@Primary` to set default bean.

## Testing

### Integration test

```java
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class UserControllerIT {

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void shouldCreateUser() {
        var req = new CreateUserRequest("Alice", "alice@test.com");
        var resp = restTemplate.postForEntity("/api/v1/users", req, UserDto.class);
        assertThat(resp.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        assertThat(resp.getBody().name()).isEqualTo("Alice");
    }
}
```

### Slice tests

```java
// Controller layer only — no server, mock MVC
@WebMvcTest(UserController.class)
class UserControllerTest {
    @Autowired private MockMvc mockMvc;
    @MockitoBean private UserService userService;

    @Test
    void shouldReturnUser() throws Exception {
        when(userService.findById(1L)).thenReturn(new UserDto(1L, "Alice"));
        mockMvc.perform(get("/api/v1/users/1"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.name").value("Alice"));
    }
}

// JPA layer only — uses embedded H2 by default
@DataJpaTest
class UserRepositoryTest {
    @Autowired private UserRepository userRepo;
    @Autowired private TestEntityManager em;

    @Test
    void shouldFindByEmail() {
        em.persist(new User(null, "alice@test.com", "Alice", null));
        var found = userRepo.findByEmail("alice@test.com");
        assertThat(found).isPresent();
    }
}
```

Note: In Spring Boot 3.4+, use `@MockitoBean` / `@MockitoSpyBean` instead of `@MockBean` / `@SpyBean`.

### Testcontainers integration

```java
@SpringBootTest
@Testcontainers
class UserServiceIT {
    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:16");

    // @ServiceConnection auto-configures datasource — no @DynamicPropertySource needed
}
```

## Actuator

Add `spring-boot-starter-actuator`. Key endpoints: `/actuator/health` (probes), `/actuator/info`, `/actuator/metrics`, `/actuator/env`, `/actuator/beans`.

```yaml
management:
  endpoints.web.exposure.include: health,info,metrics,prometheus
  endpoint.health:
    show-details: when-authorized
    probes.enabled: true  # /actuator/health/liveness and /readiness
```

Custom health indicator:

```java
@Component
public class DatabaseHealthIndicator implements HealthIndicator {
    @Override
    public Health health() {
        return Health.up().withDetail("db", "reachable").build();
    }
}
```

## Error Handling

Use `@RestControllerAdvice` with RFC 7807 `ProblemDetail` (Boot 3.x default):

```java
@RestControllerAdvice
public class GlobalExceptionHandler {
    @ExceptionHandler(ResourceNotFoundException.class)
    @ResponseStatus(HttpStatus.NOT_FOUND)
    public ProblemDetail handleNotFound(ResourceNotFoundException ex) {
        ProblemDetail pd = ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, ex.getMessage());
        pd.setTitle("Resource Not Found");
        return pd;
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    @ResponseStatus(HttpStatus.BAD_REQUEST)
    public ProblemDetail handleValidation(MethodArgumentNotValidException ex) {
        ProblemDetail pd = ProblemDetail.forStatus(HttpStatus.BAD_REQUEST);
        pd.setTitle("Validation Failed");
        pd.setProperty("fieldErrors", ex.getBindingResult().getFieldErrors().stream()
            .collect(Collectors.toMap(FieldError::getField, FieldError::getDefaultMessage)));
        return pd;
    }
}
```

**Input:** `POST /api/v1/users` with `{"name": ""}` → **Output (400):**
```json
{"type":"about:blank","title":"Validation Failed","status":400,"fieldErrors":{"name":"must not be blank"}}
```

Enable with `spring.mvc.problemdetails.enabled=true`.

## Validation

Use `spring-boot-starter-validation` (Jakarta Bean Validation 3.0):

```java
public record CreateUserRequest(
    @NotBlank @Size(min = 2, max = 100) String name,
    @NotBlank @Email String email,
    @NotNull @Min(18) Integer age) {}
```

Custom constraint: annotate with `@Constraint(validatedBy = MyValidator.class)` on a custom annotation.

## Caching

Enable with `@EnableCaching`. Use `@Cacheable("products")`, `@CacheEvict("products")`, `@CachePut`.

```yaml
spring.cache:
  type: caffeine
  caffeine.spec: maximumSize=1000,expireAfterWrite=10m
```

## Scheduling

Enable with `@EnableScheduling`:

```java
@Component
public class ReportJob {
    @Scheduled(cron = "0 0 2 * * *")  // daily at 2 AM
    public void generateDailyReport() { /* ... */ }
    @Scheduled(fixedRate = 60_000)     // every 60s
    public void pollExternalApi() { /* ... */ }
}
```

## Spring Boot 3.x / GraalVM Native Images

### Build native image

```bash
# Maven
./mvnw -Pnative native:compile

# Gradle
./gradlew nativeCompile

# Container image with Buildpacks
./mvnw -Pnative spring-boot:build-image
```

### Key considerations
- Spring AOT processes beans at build time — all beans must be deterministic
- Reflection requires hints: use `@RegisterReflectionForBinding(MyDto.class)`
- Conditional beans (`@ConditionalOnProperty`) are evaluated at build time
- Test with `@SpringBootTest` in native mode using `-PnativeTest`
- Startup time drops from seconds to milliseconds; memory footprint shrinks significantly

### Runtime hints for custom reflection

```java
public class MyRuntimeHints implements RuntimeHintsRegistrar {
    @Override
    public void registerHints(RuntimeHints hints, ClassLoader classLoader) {
        hints.reflection().registerType(MyDto.class, MemberCategory.values());
        hints.resources().registerPattern("data/*.json");
    }
}

@ImportRuntimeHints(MyRuntimeHints.class)
@SpringBootApplication
public class MyApp { }
```

## Virtual Threads (Spring Boot 3.2+)

Enable virtual threads for massive concurrency with minimal config:

```yaml
spring:
  threads:
    virtual:
      enabled: true
```

This configures Tomcat, async task executors, and scheduling to use virtual threads automatically.

## Quick Reference

| Annotation | Purpose |
|---|---|
| `@SpringBootApplication` | Entry point (combines `@Configuration`, `@EnableAutoConfiguration`, `@ComponentScan`) |
| `@RestController` | REST API controller (combines `@Controller` + `@ResponseBody`) |
| `@Service` | Business logic bean |
| `@Repository` | Data access bean (enables exception translation) |
| `@ConfigurationProperties` | Type-safe external config binding |
| `@Transactional` | Declarative transaction management |
| `@EnableMethodSecurity` | Method-level `@PreAuthorize` / `@PostAuthorize` |
| `@MockitoBean` | Replace bean with Mockito mock in tests (Boot 3.4+) |
| `@ServiceConnection` | Auto-configure Testcontainers connection (Boot 3.1+) |
