# Spring Boot Advanced Patterns

## Table of Contents

- [Auto-Configuration Internals](#auto-configuration-internals)
  - [How Auto-Configuration Works](#how-auto-configuration-works)
  - [Creating Custom Auto-Configuration](#creating-custom-auto-configuration)
  - [Conditional Annotations Deep Dive](#conditional-annotations-deep-dive)
- [Custom Starters](#custom-starters)
  - [Starter Module Structure](#starter-module-structure)
  - [Full Custom Starter Example](#full-custom-starter-example)
- [Spring AOT and GraalVM Native Compilation](#spring-aot-and-graalvm-native-compilation)
  - [AOT Processing Pipeline](#aot-processing-pipeline)
  - [Runtime Hints API](#runtime-hints-api)
  - [Native Image Limitations and Workarounds](#native-image-limitations-and-workarounds)
  - [Testing Native Images](#testing-native-images)
- [Virtual Threads (Project Loom)](#virtual-threads-project-loom)
  - [Configuration and Integration](#configuration-and-integration)
  - [When to Use Virtual Threads](#when-to-use-virtual-threads)
  - [Pitfalls and Best Practices](#pitfalls-and-best-practices)
- [Reactive Spring WebFlux](#reactive-spring-webflux)
  - [Reactive Controller Patterns](#reactive-controller-patterns)
  - [WebClient for HTTP Calls](#webclient-for-http-calls)
  - [Server-Sent Events](#server-sent-events)
  - [Backpressure and Error Handling](#backpressure-and-error-handling)
- [R2DBC Reactive Database Access](#r2dbc-reactive-database-access)
  - [R2DBC Configuration](#r2dbc-configuration)
  - [Reactive Repositories](#reactive-repositories)
  - [Transactions in Reactive Context](#transactions-in-reactive-context)
- [Spring Modulith](#spring-modulith)
  - [Module Structure and Boundaries](#module-structure-and-boundaries)
  - [Module Verification and Testing](#module-verification-and-testing)
  - [Event-Based Module Interaction](#event-based-module-interaction)
- [Event-Driven Patterns](#event-driven-patterns)
  - [ApplicationEventPublisher](#applicationeventpublisher)
  - [Transactional Event Listeners](#transactional-event-listeners)
  - [Async Event Processing](#async-event-processing)
  - [Event Externalization](#event-externalization)

---

## Auto-Configuration Internals

### How Auto-Configuration Works

Spring Boot auto-configuration uses `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` (Boot 3.x) to register configuration classes. Each class is annotated with conditional annotations evaluated at startup.

**Load order:**
1. `@SpringBootApplication` triggers `@EnableAutoConfiguration`
2. `AutoConfigurationImportSelector` reads `.imports` file
3. Each configuration class's conditions are evaluated
4. Matching configurations create beans in the application context

```java
// Inspect auto-configuration decisions at runtime
@SpringBootApplication
public class MyApp {
    public static void main(String[] args) {
        ConfigurableApplicationContext ctx = SpringApplication.run(MyApp.class, args);
        ConditionEvaluationReport report = ctx.getBean(ConditionEvaluationReport.class);
        report.getConditionAndOutcomesBySource().forEach((source, outcomes) -> {
            System.out.println("Source: " + source);
            outcomes.forEach(o -> System.out.println("  " + o.getCondition() + " -> " + o.getOutcome()));
        });
    }
}
```

### Creating Custom Auto-Configuration

```java
@AutoConfiguration
@ConditionalOnClass(NotificationService.class)
@EnableConfigurationProperties(NotificationProperties.class)
public class NotificationAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public NotificationService notificationService(NotificationProperties props) {
        return new DefaultNotificationService(props.getEndpoint(), props.getApiKey());
    }

    @Bean
    @ConditionalOnProperty(prefix = "app.notification", name = "async", havingValue = "true")
    public AsyncNotificationDecorator asyncDecorator(NotificationService delegate) {
        return new AsyncNotificationDecorator(delegate);
    }
}
```

Register in `src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`:
```
com.example.notification.NotificationAutoConfiguration
```

### Conditional Annotations Deep Dive

| Annotation | Evaluates |
|---|---|
| `@ConditionalOnClass` | Class is on classpath |
| `@ConditionalOnMissingClass` | Class is NOT on classpath |
| `@ConditionalOnBean` | Bean exists in context |
| `@ConditionalOnMissingBean` | Bean does NOT exist (user override) |
| `@ConditionalOnProperty` | Property matches value |
| `@ConditionalOnResource` | Resource exists on classpath |
| `@ConditionalOnWebApplication` | Web application context |
| `@ConditionalOnExpression` | SpEL expression evaluates true |
| `@ConditionalOnJava` | Java version matches |
| `@ConditionalOnCloudPlatform` | Running on specific cloud |

**Custom condition:**

```java
public class OnFeatureFlagCondition extends SpringBootCondition {
    @Override
    public ConditionOutcome getMatchOutcome(ConditionContext context,
                                            AnnotatedTypeMetadata metadata) {
        String flag = metadata.getAnnotationAttributes(ConditionalOnFeatureFlag.class.getName())
                              .get("value").toString();
        boolean enabled = "true".equals(context.getEnvironment().getProperty("features." + flag));
        return enabled
            ? ConditionOutcome.match("Feature flag '" + flag + "' is enabled")
            : ConditionOutcome.noMatch("Feature flag '" + flag + "' is disabled");
    }
}

@Target({ElementType.TYPE, ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
@Conditional(OnFeatureFlagCondition.class)
public @interface ConditionalOnFeatureFlag {
    String value();
}

// Usage
@Bean
@ConditionalOnFeatureFlag("new-pricing")
public PricingEngine newPricingEngine() { return new PricingEngineV2(); }
```

**Ordering auto-configurations:**

```java
@AutoConfiguration(
    after = DataSourceAutoConfiguration.class,
    before = FlywayAutoConfiguration.class
)
public class MyDataAutoConfiguration { }
```

---

## Custom Starters

### Starter Module Structure

A Spring Boot starter follows a two-module convention:

```
my-spring-boot-starter/
├── my-starter-autoconfigure/      # Auto-configuration + logic
│   ├── src/main/java/
│   │   └── com/example/
│   │       ├── MyAutoConfiguration.java
│   │       └── MyProperties.java
│   ├── src/main/resources/
│   │   └── META-INF/spring/
│   │       └── org.springframework.boot.autoconfigure.AutoConfiguration.imports
│   └── build.gradle.kts
└── my-starter/                    # Dependency aggregator (no code)
    └── build.gradle.kts           # depends on autoconfigure + optional deps
```

### Full Custom Starter Example

**Properties:**
```java
@ConfigurationProperties(prefix = "acme.notification")
public class AcmeNotificationProperties {
    private String endpoint = "https://api.acme.com/notify";
    private String apiKey;
    private Duration timeout = Duration.ofSeconds(5);
    private Retry retry = new Retry();

    public record Retry(int maxAttempts, Duration backoff) {
        public Retry() { this(3, Duration.ofMillis(500)); }
    }
    // getters/setters
}
```

**Auto-configuration:**
```java
@AutoConfiguration
@ConditionalOnClass(AcmeNotificationClient.class)
@EnableConfigurationProperties(AcmeNotificationProperties.class)
public class AcmeNotificationAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public AcmeNotificationClient acmeNotificationClient(
            AcmeNotificationProperties props, RestClient.Builder builder) {
        return new AcmeNotificationClient(
            builder.baseUrl(props.getEndpoint())
                   .defaultHeader("X-API-Key", props.getApiKey())
                   .build(),
            props.getTimeout(),
            props.getRetry()
        );
    }

    @Bean
    @ConditionalOnMissingBean
    @ConditionalOnBean(MeterRegistry.class)
    public AcmeNotificationMetrics acmeMetrics(MeterRegistry registry) {
        return new AcmeNotificationMetrics(registry);
    }
}
```

**Starter build.gradle.kts (dependency aggregator):**
```kotlin
dependencies {
    api(project(":acme-starter-autoconfigure"))
    api("org.springframework.boot:spring-boot-starter-web")
}
```

---

## Spring AOT and GraalVM Native Compilation

### AOT Processing Pipeline

Spring AOT (Ahead-of-Time) processes beans at **build time** to generate optimized code:

1. **Bean Registration** — generates `BeanDefinitionRegistrar` classes (no runtime reflection)
2. **Proxy Generation** — pre-generates CGLIB proxies
3. **Configuration Evaluation** — resolves `@Conditional` annotations at build time
4. **Runtime Hints** — collects reflection, resource, serialization, and JNI hints

```
Source Code → AOT Processing → Generated Code → GraalVM native-image → Binary
```

### Runtime Hints API

```java
public class MyAppRuntimeHints implements RuntimeHintsRegistrar {
    @Override
    public void registerHints(RuntimeHints hints, ClassLoader classLoader) {
        // Reflection for DTO serialization
        hints.reflection()
            .registerType(OrderDto.class, MemberCategory.INVOKE_PUBLIC_CONSTRUCTORS,
                          MemberCategory.INVOKE_PUBLIC_METHODS,
                          MemberCategory.DECLARED_FIELDS)
            .registerType(PaymentDto.class, MemberCategory.values());

        // Resource patterns
        hints.resources()
            .registerPattern("templates/*.html")
            .registerPattern("data/*.json");

        // JDK proxies
        hints.proxies()
            .registerJdkProxy(MyService.class, Serializable.class);

        // Serialization
        hints.serialization()
            .registerType(MySerializableEvent.class);
    }
}

// Test your hints
@SpringBootTest
class RuntimeHintsTest {
    @Test
    void shouldRegisterHints() {
        RuntimeHints hints = new RuntimeHints();
        new MyAppRuntimeHints().registerHints(hints, getClass().getClassLoader());
        assertThat(RuntimeHintsPredicates.reflection()
            .onType(OrderDto.class)).accepts(hints);
    }
}
```

**Annotation-based hints:**
```java
@RegisterReflectionForBinding({OrderDto.class, PaymentDto.class})
@Controller
public class OrderController { }
```

### Native Image Limitations and Workarounds

| Limitation | Workaround |
|---|---|
| No runtime class generation | Pre-generate proxies; avoid CGLIB at runtime |
| Dynamic property sources | Use fixed config; avoid `@DynamicPropertySource` in prod |
| Runtime reflection | Register via `RuntimeHintsRegistrar` or `reflect-config.json` |
| Serialization | Register types via hints API |
| Resource loading | Declare patterns in hints |
| `@Profile` evaluated at build time | Use `@ConditionalOnProperty` instead |
| Lazy initialization limited | Avoid `@Lazy` on beans needing proxies |

### Testing Native Images

```bash
# Run AOT-processed tests (without native binary)
./gradlew test -PspringAot

# Build and run native tests
./gradlew nativeTest

# Run the native image with tracing agent to discover missing hints
java -agentlib:native-image-agent=config-output-dir=src/main/resources/META-INF/native-image \
     -jar build/libs/myapp.jar
```

---

## Virtual Threads (Project Loom)

### Configuration and Integration

```yaml
# application.yml — enables virtual threads for all components
spring:
  threads:
    virtual:
      enabled: true
```

This auto-configures:
- **Tomcat/Jetty/Undertow** — request handling on virtual threads
- **@Async tasks** — `AsyncTaskExecutor` uses virtual threads
- **@Scheduled tasks** — scheduled tasks run on virtual threads
- **Spring MVC** — controller methods execute on virtual threads

**Custom virtual thread executor:**
```java
@Bean
public AsyncTaskExecutor applicationTaskExecutor() {
    return new TaskExecutorAdapter(Executors.newVirtualThreadPerTaskExecutor());
}
```

### When to Use Virtual Threads

**Good fit (I/O-bound work):**
- REST API calls to other services
- Database queries (JDBC — blocking I/O)
- File I/O operations
- Message queue consumers

**Poor fit (CPU-bound or pinning scenarios):**
- Heavy computation / number crunching
- Code holding `synchronized` blocks for long durations (pins carrier thread)
- Native library calls via JNI that block

### Pitfalls and Best Practices

```java
// BAD: synchronized pins virtual thread to carrier thread
public synchronized String fetchData() {
    return restClient.get().uri("/data").retrieve().body(String.class);
}

// GOOD: use ReentrantLock instead
private final ReentrantLock lock = new ReentrantLock();
public String fetchData() {
    lock.lock();
    try {
        return restClient.get().uri("/data").retrieve().body(String.class);
    } finally {
        lock.unlock();
    }
}

// GOOD: use Semaphore for connection limiting
private static final Semaphore permits = new Semaphore(50);
public void callExternalApi() {
    permits.acquire();
    try {
        restClient.get().uri("/api").retrieve().body(String.class);
    } finally {
        permits.release();
    }
}
```

- **ThreadLocal**: virtual threads support ThreadLocal but use ScopedValue (preview) for better performance.
- **Monitoring**: use `-Djdk.tracePinnedThreads=short` to detect pinning.
- **Pool sizing**: virtual threads are cheap; don't pool them. Use `Executors.newVirtualThreadPerTaskExecutor()`.

---

## Reactive Spring WebFlux

### Reactive Controller Patterns

```java
@RestController
@RequestMapping("/api/v1/products")
public class ProductController {

    private final ProductRepository productRepository;

    @GetMapping
    public Flux<Product> list() {
        return productRepository.findAll();
    }

    @GetMapping("/{id}")
    public Mono<ResponseEntity<Product>> get(@PathVariable String id) {
        return productRepository.findById(id)
            .map(ResponseEntity::ok)
            .defaultIfEmpty(ResponseEntity.notFound().build());
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Mono<Product> create(@Valid @RequestBody Product product) {
        return productRepository.save(product);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public Mono<Void> delete(@PathVariable String id) {
        return productRepository.deleteById(id);
    }
}
```

### WebClient for HTTP Calls

```java
@Service
public class ExternalApiService {

    private final WebClient webClient;

    public ExternalApiService(WebClient.Builder builder) {
        this.webClient = builder
            .baseUrl("https://api.example.com")
            .defaultHeader(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
            .filter(ExchangeFilterFunctions.basicAuthentication("user", "pass"))
            .build();
    }

    public Mono<OrderResponse> getOrder(String orderId) {
        return webClient.get()
            .uri("/orders/{id}", orderId)
            .retrieve()
            .onStatus(HttpStatusCode::is4xxClientError, resp ->
                resp.bodyToMono(String.class)
                    .flatMap(body -> Mono.error(new ClientException(body))))
            .bodyToMono(OrderResponse.class)
            .timeout(Duration.ofSeconds(5))
            .retryWhen(Retry.backoff(3, Duration.ofMillis(500))
                .filter(ex -> ex instanceof WebClientResponseException.ServiceUnavailable));
    }

    public Flux<Event> streamEvents() {
        return webClient.get()
            .uri("/events/stream")
            .accept(MediaType.TEXT_EVENT_STREAM)
            .retrieve()
            .bodyToFlux(Event.class);
    }
}
```

### Server-Sent Events

```java
@GetMapping(value = "/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public Flux<ServerSentEvent<StockPrice>> streamPrices() {
    return Flux.interval(Duration.ofSeconds(1))
        .map(seq -> ServerSentEvent.<StockPrice>builder()
            .id(String.valueOf(seq))
            .event("price-update")
            .data(stockService.getCurrentPrice())
            .retry(Duration.ofSeconds(5))
            .build());
}
```

### Backpressure and Error Handling

```java
public Flux<Item> processItems() {
    return itemRepository.findAll()
        .onBackpressureBuffer(256)              // buffer up to 256 items
        .flatMap(this::enrichItem, 16)           // concurrency limit of 16
        .onErrorResume(DatabaseException.class, e -> {
            log.error("DB error, returning empty", e);
            return Flux.empty();
        })
        .onErrorContinue((throwable, item) -> {
            log.warn("Skipping failed item: {}", item, throwable);
        })
        .doOnComplete(() -> log.info("Processing complete"));
}
```

---

## R2DBC Reactive Database Access

### R2DBC Configuration

```yaml
spring:
  r2dbc:
    url: r2dbc:postgresql://localhost:5432/mydb
    username: ${DB_USER}
    password: ${DB_PASSWORD}
    pool:
      initial-size: 5
      max-size: 20
      max-idle-time: 30m
```

Dependencies:
```kotlin
implementation("org.springframework.boot:spring-boot-starter-data-r2dbc")
runtimeOnly("org.postgresql:r2dbc-postgresql")
```

### Reactive Repositories

```java
public interface OrderRepository extends ReactiveCrudRepository<Order, Long> {

    Flux<Order> findByCustomerId(Long customerId);

    @Query("SELECT * FROM orders WHERE status = :status ORDER BY created_at DESC LIMIT :limit")
    Flux<Order> findRecentByStatus(String status, int limit);

    @Query("SELECT COUNT(*) FROM orders WHERE created_at > :since")
    Mono<Long> countOrdersSince(Instant since);

    @Modifying
    @Query("UPDATE orders SET status = :status WHERE id = :id")
    Mono<Integer> updateStatus(Long id, String status);
}
```

**Entity mapping (no JPA — uses Spring Data R2DBC annotations):**
```java
@Table("orders")
public class Order {
    @Id
    private Long id;
    private Long customerId;
    private String status;
    private BigDecimal total;
    @CreatedDate
    private Instant createdAt;
}
```

### Transactions in Reactive Context

```java
@Service
public class OrderService {

    private final OrderRepository orderRepo;
    private final InventoryRepository inventoryRepo;
    private final TransactionalOperator txOp;

    @Transactional
    public Mono<Order> placeOrder(CreateOrderRequest req) {
        return inventoryRepo.decrementStock(req.productId(), req.quantity())
            .then(orderRepo.save(new Order(req.customerId(), req.productId(),
                                           req.quantity(), req.total())))
            .doOnSuccess(order -> log.info("Order placed: {}", order.getId()));
    }

    // Programmatic transactions
    public Mono<Order> placeOrderProgrammatic(CreateOrderRequest req) {
        return txOp.transactional(
            inventoryRepo.decrementStock(req.productId(), req.quantity())
                .then(orderRepo.save(new Order(/* ... */)))
        );
    }
}
```

---

## Spring Modulith

### Module Structure and Boundaries

Spring Modulith enforces modular architecture within a single deployable:

```
com.example.shop/
├── ShopApplication.java
├── order/                    # Module: order
│   ├── Order.java           # Aggregate root (public)
│   ├── OrderService.java    # Public API
│   └── internal/            # Package-private internals
│       ├── OrderRepository.java
│       └── OrderValidator.java
├── inventory/                # Module: inventory
│   ├── InventoryService.java
│   └── internal/
│       └── InventoryRepository.java
└── catalog/                  # Module: catalog
    ├── Product.java
    └── ProductService.java
```

**Rules enforced:**
- Modules correspond to direct sub-packages of the main application package
- `internal` sub-packages are not accessible from other modules
- Module interactions happen only through public APIs or events

### Module Verification and Testing

```java
// Verify module boundaries at test time
@Test
void verifyModularStructure() {
    ApplicationModules modules = ApplicationModules.of(ShopApplication.class);
    modules.verify();  // fails if boundaries violated
}

// Document module structure
@Test
void createModuleDocs() {
    ApplicationModules modules = ApplicationModules.of(ShopApplication.class);
    new Documenter(modules)
        .writeModulesAsPlantUml()
        .writeIndividualModulesAsPlantUml();
}

// Integration test for a single module
@ApplicationModuleTest
class OrderModuleTest {
    @Autowired OrderService orderService;

    @Test
    void shouldCreateOrder(Scenario scenario) {
        scenario.stimulate(() -> orderService.create(new CreateOrderRequest(/*...*/)))
                .andWaitForEventOfType(OrderCreatedEvent.class)
                .matchingMapped(OrderCreatedEvent::orderId, orderId -> orderId != null)
                .toArrive();
    }
}
```

### Event-Based Module Interaction

```java
// Order module publishes event
@Service
@Transactional
public class OrderService {
    private final ApplicationEventPublisher events;

    public Order completeOrder(Long orderId) {
        Order order = orderRepo.findById(orderId).orElseThrow();
        order.complete();
        orderRepo.save(order);
        events.publishEvent(new OrderCompletedEvent(order.getId(), order.getTotal()));
        return order;
    }
}

// Inventory module listens (separate module)
@Service
public class InventoryEventHandler {
    @ApplicationModuleListener
    public void on(OrderCompletedEvent event) {
        inventoryService.releaseReserved(event.orderId());
    }
}
```

---

## Event-Driven Patterns

### ApplicationEventPublisher

```java
// Define event as a record
public record UserRegisteredEvent(Long userId, String email, Instant registeredAt) {}

// Publish from service
@Service
@Transactional
public class UserService {
    private final ApplicationEventPublisher eventPublisher;

    public User register(CreateUserRequest request) {
        User user = userRepository.save(new User(request.name(), request.email()));
        eventPublisher.publishEvent(
            new UserRegisteredEvent(user.getId(), user.getEmail(), Instant.now()));
        return user;
    }
}

// Listen with @EventListener
@Component
public class WelcomeEmailListener {
    @EventListener
    public void onUserRegistered(UserRegisteredEvent event) {
        emailService.sendWelcome(event.email());
    }
}
```

### Transactional Event Listeners

```java
@Component
public class AuditEventListener {

    // Runs AFTER the transaction commits successfully
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onOrderCreated(OrderCreatedEvent event) {
        auditService.logOrderCreation(event.orderId());
    }

    // Runs BEFORE the transaction commits
    @TransactionalEventListener(phase = TransactionPhase.BEFORE_COMMIT)
    public void validateOrder(OrderCreatedEvent event) {
        if (!complianceService.isValid(event)) {
            throw new ComplianceException("Order failed compliance check");
        }
    }

    // Runs if the transaction rolls back
    @TransactionalEventListener(phase = TransactionPhase.AFTER_ROLLBACK)
    public void onRollback(OrderCreatedEvent event) {
        alertService.notifyFailedOrder(event.orderId());
    }
}
```

### Async Event Processing

```java
@Configuration
@EnableAsync
public class AsyncConfig {
    @Bean
    public TaskExecutor eventTaskExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(4);
        executor.setMaxPoolSize(16);
        executor.setQueueCapacity(100);
        executor.setThreadNamePrefix("event-");
        executor.setRejectedExecutionHandler(new CallerRunsPolicy());
        executor.initialize();
        return executor;
    }
}

@Component
public class NotificationListener {
    @Async("eventTaskExecutor")
    @EventListener
    public void onUserRegistered(UserRegisteredEvent event) {
        // Runs asynchronously in a separate thread
        notificationService.send(event.email(), "Welcome!");
    }
}
```

### Event Externalization

Spring Modulith can externalize events to message brokers:

```java
@Configuration
public class EventExternalizationConfig {
    @Bean
    EventExternalizationConfiguration eventExternalization() {
        return EventExternalizationConfiguration.externalizing()
            .select(EventExternalizationConfiguration.annotatedAsExternalized())
            .build();
    }
}

// Mark events for externalization
@Externalized("orders.completed")
public record OrderCompletedEvent(Long orderId, BigDecimal total) {}
```

Supports Kafka, AMQP, JMS, and SNS as transports. Events are published transactionally using the outbox pattern.
