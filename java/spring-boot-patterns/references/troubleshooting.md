# Spring Boot Troubleshooting Guide

## Table of Contents

- [Common Startup Failures](#common-startup-failures)
  - [Bean Conflicts and Duplicate Definitions](#bean-conflicts-and-duplicate-definitions)
  - [Circular Dependencies](#circular-dependencies)
  - [DataSource Configuration Failures](#datasource-configuration-failures)
  - [Port Already in Use](#port-already-in-use)
  - [Missing Dependencies and ClassNotFoundException](#missing-dependencies-and-classnotfoundexception)
- [Debugging Auto-Configuration](#debugging-auto-configuration)
  - [The --debug Flag](#the---debug-flag)
  - [ConditionEvaluationReport](#conditionevaluationreport)
  - [Actuator Conditions Endpoint](#actuator-conditions-endpoint)
  - [Common Auto-Configuration Surprises](#common-auto-configuration-surprises)
- [Test Context Caching](#test-context-caching)
  - [How Context Caching Works](#how-context-caching-works)
  - [Diagnosing Slow Tests](#diagnosing-slow-tests)
  - [Optimizing Context Reuse](#optimizing-context-reuse)
- [Memory Leaks](#memory-leaks)
  - [Common Leak Sources](#common-leak-sources)
  - [Diagnosing with Actuator and JFR](#diagnosing-with-actuator-and-jfr)
  - [Hikari Connection Pool Issues](#hikari-connection-pool-issues)
- [Slow Startup Diagnostics](#slow-startup-diagnostics)
  - [Startup Timing with ApplicationStartup](#startup-timing-with-applicationstartup)
  - [Reducing Startup Time](#reducing-startup-time)
- [Migration from Boot 2.x to 3.x](#migration-from-boot-2x-to-3x)
  - [Jakarta EE Namespace Migration](#jakarta-ee-namespace-migration)
  - [Spring Security Migration](#spring-security-migration)
  - [Configuration Properties Changes](#configuration-properties-changes)
  - [Other Breaking Changes](#other-breaking-changes)

---

## Common Startup Failures

### Bean Conflicts and Duplicate Definitions

**Error:**
```
BeanDefinitionOverrideException: Invalid bean definition with name 'dataSource'
defined in class path resource [...]: Cannot register bean definition [...] 
There is already [...] bound.
```

**Causes and fixes:**

```yaml
# Allow overriding (not recommended for production)
spring:
  main:
    allow-bean-definition-overriding: true
```

**Better solutions:**

```java
// 1. Use @Primary to designate the preferred bean
@Bean
@Primary
public DataSource primaryDataSource() { return new HikariDataSource(primaryConfig()); }

@Bean
@Qualifier("reporting")
public DataSource reportingDataSource() { return new HikariDataSource(reportConfig()); }

// 2. Exclude auto-configuration if you provide your own
@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)
public class MyApp { }

// 3. Use @ConditionalOnMissingBean in your auto-configuration
@Bean
@ConditionalOnMissingBean
public MyService myService() { return new DefaultMyService(); }
```

### Circular Dependencies

**Error:**
```
BeanCurrentlyInCreationException: Error creating bean with name 'serviceA':
Requested bean is currently in creation: Is there an unresolvable circular reference?
```

Spring Boot 3.x **disallows** circular dependencies by default (Boot 2.x allowed them via proxies).

**Solutions (in order of preference):**

```java
// 1. BEST: Refactor to remove the cycle. Extract shared logic:
// Before: A → B → A
// After:  A → C, B → C

// 2. Use @Lazy on one injection point (breaks the cycle)
@Service
public class ServiceA {
    private final ServiceB serviceB;
    public ServiceA(@Lazy ServiceB serviceB) { this.serviceB = serviceB; }
}

// 3. Use events to decouple
@Service
public class OrderService {
    private final ApplicationEventPublisher events;
    public void complete(Long orderId) {
        events.publishEvent(new OrderCompletedEvent(orderId));
    }
}

@Service
public class InventoryService {
    @EventListener
    public void onOrderCompleted(OrderCompletedEvent event) { /* ... */ }
}

// 4. Last resort — allow circular references (Boot 3.x)
// spring.main.allow-circular-references=true
```

### DataSource Configuration Failures

**Error:**
```
Failed to configure a DataSource: 'url' attribute is not specified and 
no embedded datasource could be configured.
```

**Common causes:**

```yaml
# 1. Missing JDBC driver — add to dependencies
# runtimeOnly("org.postgresql:postgresql")

# 2. Wrong property format (MUST use spring.datasource, not spring.data.source)
spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/mydb
    username: user
    password: pass

# 3. H2 not on classpath for tests
# testRuntimeOnly("com.h2database:h2")

# 4. Using environment variable with wrong syntax
spring:
  datasource:
    url: ${DATABASE_URL:jdbc:postgresql://localhost:5432/mydb}
```

**DataSource with Testcontainers:**
```java
@SpringBootTest
@Testcontainers
class MyIT {
    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16");
    // No @DynamicPropertySource needed — @ServiceConnection does it
}
```

### Port Already in Use

**Error:**
```
Web server failed to start. Port 8080 was already in use.
```

```bash
# Find and kill the process using the port
lsof -i :8080
kill <PID>

# Or use a random port
# server.port=0

# Or specify a different port
# server.port=8081
```

### Missing Dependencies and ClassNotFoundException

**Error:**
```
ClassNotFoundException: jakarta.servlet.http.HttpServletRequest
```

Common Boot 3.x classpath issues:

```kotlin
// Spring Boot 3.x uses Jakarta EE 9+
// WRONG: javax.servlet (Java EE)
// RIGHT: jakarta.servlet (Jakarta EE)
implementation("jakarta.servlet:jakarta.servlet-api")

// WRONG (old Spring Security)
// implementation("org.springframework.security:spring-security-web:5.x")
// RIGHT — managed by Boot BOM
implementation("org.springframework.boot:spring-boot-starter-security")
```

---

## Debugging Auto-Configuration

### The --debug Flag

```bash
# CLI
java -jar myapp.jar --debug

# application.properties
debug=true

# Environment variable
DEBUG=true java -jar myapp.jar
```

Outputs a `CONDITIONS EVALUATION REPORT` at startup:

```
============================
CONDITIONS EVALUATION REPORT
============================

Positive matches:
-----------------
   DataSourceAutoConfiguration matched:
      - @ConditionalOnClass found required classes 'javax.sql.DataSource', 
        'org.springframework.jdbc.datasource.embedded.EmbeddedDatabaseType'

Negative matches:
-----------------
   MongoAutoConfiguration:
      Did not match:
         - @ConditionalOnClass did not find required class 
           'com.mongodb.client.MongoClient'
```

### ConditionEvaluationReport

```java
// Programmatic access to the report
@Component
public class AutoConfigDiagnostics implements ApplicationRunner {
    private final ConditionEvaluationReport report;

    public AutoConfigDiagnostics(ConfigurableApplicationContext ctx) {
        this.report = ConditionEvaluationReport.get(
            (ConfigurableListableBeanFactory) ctx.getBeanFactory());
    }

    @Override
    public void run(ApplicationArguments args) {
        // Find why a specific auto-configuration didn't apply
        report.getConditionAndOutcomesBySource().entrySet().stream()
            .filter(e -> e.getKey().contains("Security"))
            .forEach(e -> {
                System.out.println("=== " + e.getKey() + " ===");
                e.getValue().forEach(co -> System.out.println(
                    "  " + co.getCondition().getClass().getSimpleName() +
                    " → " + (co.getOutcome().isMatch() ? "MATCH" : "NO MATCH") +
                    ": " + co.getOutcome().getMessage()));
            });
    }
}
```

### Actuator Conditions Endpoint

```yaml
management:
  endpoints:
    web:
      exposure:
        include: conditions,beans,env,configprops
```

```bash
# View auto-configuration report via HTTP
curl localhost:8080/actuator/conditions | jq '.contexts.application.positiveMatches'

# View all registered beans
curl localhost:8080/actuator/beans | jq '.contexts.application.beans | keys[]' | wc -l

# View resolved configuration
curl localhost:8080/actuator/configprops | jq '.contexts.application.beans'
```

### Common Auto-Configuration Surprises

| Symptom | Cause | Fix |
|---|---|---|
| H2 console appears in production | H2 on classpath + `spring.h2.console.enabled` | Move H2 to `testRuntimeOnly` |
| Two DataSources created | Both `spring-boot-starter-data-jpa` and manual DataSource | Use `@ConditionalOnMissingBean` or exclude |
| Security blocks all endpoints | `spring-boot-starter-security` on classpath | Add `SecurityFilterChain` bean or exclude |
| Flyway runs unwanted migrations | Flyway on classpath | `spring.flyway.enabled=false` or exclude |
| Jackson not serializing Java 8 dates | Missing `jackson-datatype-jsr310` | Boot auto-includes it; check `@JsonFormat` |

---

## Test Context Caching

### How Context Caching Works

Spring caches application contexts between tests to avoid repeated startup. The cache key is built from:
- `@ContextConfiguration` locations/classes
- `@ActiveProfiles`
- `@TestPropertySource`
- `@MockitoBean` / `@MockitoSpyBean` declarations
- `@DynamicPropertySource` methods
- Context initializers

**Any difference in these creates a NEW context.**

### Diagnosing Slow Tests

```bash
# Enable context cache logging
# application-test.properties
logging.level.org.springframework.test.context.cache=DEBUG
```

Output shows:
```
Spring test ApplicationContext cache statistics:
  size=3, maxSize=32, parentContextCount=0, hitCount=12, missCount=3
```

If `missCount` is high, contexts are not being reused.

### Optimizing Context Reuse

```java
// BAD: Each test class creates a new context due to different @MockitoBean sets
@SpringBootTest
class OrderServiceTest {
    @MockitoBean OrderRepository orderRepo;       // Context key A
}
@SpringBootTest
class PaymentServiceTest {
    @MockitoBean PaymentRepository paymentRepo;    // Context key B (different!)
}

// GOOD: Shared base class with common mocks
@SpringBootTest
abstract class BaseIntegrationTest {
    @MockitoBean OrderRepository orderRepo;
    @MockitoBean PaymentRepository paymentRepo;
}
class OrderServiceTest extends BaseIntegrationTest { /* ... */ }
class PaymentServiceTest extends BaseIntegrationTest { /* ... */ }

// GOOD: Use slice tests to keep contexts minimal
@WebMvcTest(OrderController.class)    // Only loads web layer
class OrderControllerTest { }

@DataJpaTest                           // Only loads JPA layer
class OrderRepositoryTest { }
```

**@DirtiesContext — use sparingly:**
```java
@SpringBootTest
@DirtiesContext(classMode = ClassMode.AFTER_CLASS)  // destroys context after class
class StatefulTest { }
// Only use when a test genuinely modifies shared state (e.g., schema changes)
```

---

## Memory Leaks

### Common Leak Sources

1. **Unclosed resources in `@Bean` methods:**
```java
// BAD: InputStream never closed
@Bean
public Properties externalConfig() throws IOException {
    Properties props = new Properties();
    props.load(new FileInputStream("/config/external.properties")); // LEAK
    return props;
}

// GOOD: try-with-resources
@Bean
public Properties externalConfig() throws IOException {
    Properties props = new Properties();
    try (var is = new FileInputStream("/config/external.properties")) {
        props.load(is);
    }
    return props;
}
```

2. **Event listeners holding references:**
```java
// BAD: growing list without eviction
@Component
public class EventAccumulator {
    private final List<Event> events = new ArrayList<>(); // unbounded
    @EventListener
    public void onEvent(MyEvent e) { events.add(e); }
}
```

3. **ThreadLocal not cleaned in servlet context:**
```java
// BAD in virtual threads / thread pools
private static final ThreadLocal<UserContext> ctx = new ThreadLocal<>();

// GOOD: always clean up
try {
    ctx.set(userContext);
    chain.doFilter(request, response);
} finally {
    ctx.remove();
}
```

### Diagnosing with Actuator and JFR

```yaml
# Expose memory metrics
management:
  endpoints:
    web:
      exposure:
        include: health,metrics,heapdump
  metrics:
    tags:
      application: ${spring.application.name}
```

```bash
# Heap dump via actuator
curl -o heap.hprof localhost:8080/actuator/heapdump

# JVM metrics
curl localhost:8080/actuator/metrics/jvm.memory.used | jq
curl localhost:8080/actuator/metrics/jvm.gc.pause | jq

# Java Flight Recorder
java -XX:StartFlightRecording=duration=60s,filename=recording.jfr -jar myapp.jar

# Analyze with JDK Mission Control (jmc) or jfr tool
jfr print --events jdk.ObjectAllocationSample recording.jfr
```

### Hikari Connection Pool Issues

```
HikariPool-1 - Connection is not available, request timed out after 30000ms.
```

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 20           # default 10
      minimum-idle: 5
      connection-timeout: 30000       # 30s
      idle-timeout: 600000            # 10min
      max-lifetime: 1800000           # 30min
      leak-detection-threshold: 60000 # log warning if connection held >60s
```

```bash
# Monitor pool metrics
curl localhost:8080/actuator/metrics/hikaricp.connections.active
curl localhost:8080/actuator/metrics/hikaricp.connections.idle
curl localhost:8080/actuator/metrics/hikaricp.connections.pending
```

**Common cause — missing `@Transactional` leading to connection exhaustion:**
```java
// BAD: Each lazy-loaded collection opens a new connection
public List<OrderDto> getAllOrders() {
    return orderRepo.findAll().stream()
        .map(o -> new OrderDto(o.getId(), o.getItems())) // N+1 + connection leak
        .toList();
}

// GOOD: Fetch eagerly with JOIN FETCH or use @Transactional
@Transactional(readOnly = true)
public List<OrderDto> getAllOrders() {
    return orderRepo.findAllWithItems().stream()
        .map(o -> new OrderDto(o.getId(), o.getItems()))
        .toList();
}
```

---

## Slow Startup Diagnostics

### Startup Timing with ApplicationStartup

```java
@SpringBootApplication
public class MyApp {
    public static void main(String[] args) {
        SpringApplication app = new SpringApplication(MyApp.class);
        app.setApplicationStartup(new BufferingApplicationStartup(4096));
        app.run(args);
    }
}
```

View at `/actuator/startup` (expose the endpoint):
```yaml
management:
  endpoints:
    web:
      exposure:
        include: startup
```

```bash
# Find slowest startup steps
curl localhost:8080/actuator/startup | jq '
  .timeline.events
  | sort_by(-.duration.seconds)
  | .[0:10]
  | .[] | {step: .startupStep.name, duration: .duration}'
```

### Reducing Startup Time

1. **Lazy initialization:**
```yaml
spring:
  main:
    lazy-initialization: true  # beans created on first use
```
⚠️ Trade-off: faster startup but first request is slower, and errors surface later.

2. **Exclude unused auto-configurations:**
```java
@SpringBootApplication(exclude = {
    MongoAutoConfiguration.class,
    RedisAutoConfiguration.class,
    MailSenderAutoConfiguration.class
})
public class MyApp { }
```

3. **Use class data sharing (CDS):**
```bash
# Create CDS archive
java -Dspring.context.exit=onRefresh -XX:ArchiveClassesAtExit=app-cds.jsa -jar myapp.jar
# Run with CDS
java -XX:SharedArchiveFile=app-cds.jsa -jar myapp.jar
```

4. **Spring AOT for fastest startup:**
```bash
# Process at build time + native image
./gradlew nativeCompile
# Startup: ~50ms instead of ~3s
```

5. **JVM tuning:**
```bash
java -XX:TieredStopAtLevel=1 \     # faster JIT warmup
     -Xss256k \                     # smaller thread stacks
     -XX:+UseSerialGC \             # simpler GC for small apps
     -jar myapp.jar
```

---

## Migration from Boot 2.x to 3.x

### Jakarta EE Namespace Migration

All `javax.*` packages that were part of Java EE are now `jakarta.*`:

```java
// BEFORE (Boot 2.x / Java EE)
import javax.persistence.*;
import javax.servlet.http.*;
import javax.validation.constraints.*;
import javax.annotation.*;

// AFTER (Boot 3.x / Jakarta EE 9+)
import jakarta.persistence.*;
import jakarta.servlet.http.*;
import jakarta.validation.constraints.*;
import jakarta.annotation.*;
```

**Automated migration:**
```bash
# OpenRewrite recipe
./gradlew rewriteRun -Drewrite.activeRecipe=org.openrewrite.java.spring.boot3.UpgradeSpringBoot_3_0

# IntelliJ migration tool
# Refactor → Migrate Packages and Classes → Java EE to Jakarta EE
```

### Spring Security Migration

```java
// BEFORE (Boot 2.x / Security 5.x)
@Configuration
@EnableWebSecurity
public class SecurityConfig extends WebSecurityConfigurerAdapter {
    @Override
    protected void configure(HttpSecurity http) throws Exception {
        http.authorizeRequests()
            .antMatchers("/public/**").permitAll()
            .anyRequest().authenticated()
            .and()
            .httpBasic();
    }
}

// AFTER (Boot 3.x / Security 6.x)
@Configuration
@EnableWebSecurity
public class SecurityConfig {
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http.authorizeHttpRequests(auth -> auth
                .requestMatchers("/public/**").permitAll()
                .anyRequest().authenticated()
            )
            .httpBasic(Customizer.withDefaults());
        return http.build();
    }
}
```

Key changes:
| Boot 2.x | Boot 3.x |
|---|---|
| `WebSecurityConfigurerAdapter` | `SecurityFilterChain` @Bean |
| `.authorizeRequests()` | `.authorizeHttpRequests()` |
| `.antMatchers()` | `.requestMatchers()` |
| `.and()` chaining | Lambda DSL |
| `@EnableGlobalMethodSecurity` | `@EnableMethodSecurity` |
| `@MockBean` | `@MockitoBean` (Boot 3.4+) |

### Configuration Properties Changes

```yaml
# Removed/changed properties in Boot 3.x:
# BEFORE → AFTER

# spring.redis.* → spring.data.redis.*
spring:
  data:
    redis:
      host: localhost
      port: 6379

# spring.elasticsearch.rest.* → spring.elasticsearch.*
spring:
  elasticsearch:
    uris: http://localhost:9200

# server.max-http-header-size → server.max-http-request-header-size
server:
  max-http-request-header-size: 16KB

# management.metrics.export.* → management.<product>.*
management:
  prometheus:
    metrics:
      export:
        enabled: true
```

### Other Breaking Changes

1. **Java 17 minimum** — Boot 3.x requires Java 17+
2. **Trailing slash matching disabled:**
```java
// "/users/" no longer matches "/users" by default
// To restore:
@Configuration
public class WebConfig implements WebMvcConfigurer {
    @Override
    public void configurePathMatch(PathMatchConfigurer configurer) {
        configurer.setUseTrailingSlashMatch(true); // deprecated, fix URLs instead
    }
}
```

3. **YML property binding stricter** — kebab-case enforced for `@ConfigurationProperties`
4. **Micrometer changes:**
```java
// BEFORE
Timer.builder("http.requests").tag("status", "200").register(registry);
// AFTER — use Observation API
ObservationRegistry registry;
Observation.createNotStarted("http.requests", registry)
    .lowCardinalityKeyValue("status", "200")
    .observe(() -> { /* timed code */ });
```

5. **Spring Boot 3.x migration checklist:**
   - [ ] Upgrade to Java 17+
   - [ ] Run OpenRewrite `javax` → `jakarta` migration
   - [ ] Update Security config (remove `WebSecurityConfigurerAdapter`)
   - [ ] Fix `antMatchers` → `requestMatchers`
   - [ ] Update `spring.redis.*` → `spring.data.redis.*`
   - [ ] Replace `@MockBean` with `@MockitoBean` (Boot 3.4+)
   - [ ] Test with `--debug` for auto-configuration changes
   - [ ] Review Actuator endpoint exposure changes
   - [ ] Update Micrometer metric names and tags
   - [ ] Verify third-party libraries have Jakarta EE support
