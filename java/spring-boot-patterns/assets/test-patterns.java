// =============================================================================
// Spring Boot Test Patterns Reference
// =============================================================================
// Common test patterns for Spring Boot 3.x applications.
// Copy and adapt individual test classes as needed.
// =============================================================================

// ---------------------------------------------------------------------------
// 1. @WebMvcTest — Controller Layer Tests (no server)
// ---------------------------------------------------------------------------
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.http.MediaType;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(UserController.class)
class UserControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private UserService userService;

    @Test
    @WithMockUser  // provides a mock authenticated user
    void shouldReturnUser() throws Exception {
        when(userService.findById(1L))
            .thenReturn(new UserDto(1L, "Alice", "alice@test.com"));

        mockMvc.perform(get("/api/v1/users/1"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.name").value("Alice"))
            .andExpect(jsonPath("$.email").value("alice@test.com"));
    }

    @Test
    @WithMockUser(roles = "ADMIN")
    void shouldCreateUser() throws Exception {
        when(userService.create(any()))
            .thenReturn(new UserDto(1L, "Bob", "bob@test.com"));

        mockMvc.perform(post("/api/v1/users")
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {"name": "Bob", "email": "bob@test.com"}
                    """))
            .andExpect(status().isCreated())
            .andExpect(jsonPath("$.id").value(1));
    }

    @Test
    @WithMockUser
    void shouldReturn400ForInvalidInput() throws Exception {
        mockMvc.perform(post("/api/v1/users")
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {"name": "", "email": "not-an-email"}
                    """))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.fieldErrors.name").exists());
    }

    @Test
    void shouldReturn401WhenNotAuthenticated() throws Exception {
        mockMvc.perform(get("/api/v1/users/1"))
            .andExpect(status().isUnauthorized());
    }
}


// ---------------------------------------------------------------------------
// 2. @DataJpaTest — Repository Layer Tests
// ---------------------------------------------------------------------------
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.test.autoconfigure.orm.jpa.TestEntityManager;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;

import static org.assertj.core.api.Assertions.assertThat;

@DataJpaTest
class UserRepositoryTest {

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private TestEntityManager entityManager;

    @Test
    void shouldFindByEmail() {
        entityManager.persistAndFlush(
            new User(null, "alice@test.com", "Alice", null));

        var found = userRepository.findByEmail("alice@test.com");

        assertThat(found).isPresent();
        assertThat(found.get().getName()).isEqualTo("Alice");
    }

    @Test
    void shouldSearchByNameWithPagination() {
        entityManager.persistAndFlush(new User(null, "a@test.com", "Alice", null));
        entityManager.persistAndFlush(new User(null, "b@test.com", "Bob", null));
        entityManager.persistAndFlush(new User(null, "c@test.com", "Alicia", null));

        Page<User> results = userRepository.searchByName("Ali", PageRequest.of(0, 10));

        assertThat(results.getContent()).hasSize(2);
        assertThat(results.getContent())
            .extracting(User::getName)
            .containsExactlyInAnyOrder("Alice", "Alicia");
    }

    @Test
    void shouldCheckExistsByEmail() {
        entityManager.persistAndFlush(
            new User(null, "alice@test.com", "Alice", null));

        assertThat(userRepository.existsByEmail("alice@test.com")).isTrue();
        assertThat(userRepository.existsByEmail("bob@test.com")).isFalse();
    }
}


// ---------------------------------------------------------------------------
// 3. @SpringBootTest — Full Integration Test
// ---------------------------------------------------------------------------
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class UserControllerIntegrationTest {

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void shouldCreateAndRetrieveUser() {
        // Create
        var createReq = new CreateUserRequest("Alice", "alice@test.com", 25);
        var createResp = restTemplate.postForEntity(
            "/api/v1/users", createReq, UserDto.class);
        assertThat(createResp.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        assertThat(createResp.getBody()).isNotNull();
        Long userId = createResp.getBody().id();

        // Retrieve
        var getResp = restTemplate.getForEntity(
            "/api/v1/users/" + userId, UserDto.class);
        assertThat(getResp.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(getResp.getBody().name()).isEqualTo("Alice");
    }
}


// ---------------------------------------------------------------------------
// 4. Testcontainers — Real Database Integration Tests
// ---------------------------------------------------------------------------
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@Testcontainers
class UserServiceWithPostgresIT {

    @Container
    @ServiceConnection  // auto-configures datasource (Boot 3.1+)
    static PostgreSQLContainer<?> postgres =
        new PostgreSQLContainer<>("postgres:16-alpine");

    @Autowired
    private UserService userService;

    @Test
    void shouldPersistAndRetrieveUser() {
        UserDto created = userService.create(
            new CreateUserRequest("Alice", "alice@test.com", 25));
        assertThat(created.id()).isNotNull();

        UserDto found = userService.findById(created.id());
        assertThat(found.name()).isEqualTo("Alice");
    }
}


// ---------------------------------------------------------------------------
// 5. Testcontainers — Multiple Services
// ---------------------------------------------------------------------------
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.KafkaContainer;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

@SpringBootTest
@Testcontainers
abstract class BaseIntegrationTest {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres =
        new PostgreSQLContainer<>("postgres:16-alpine");

    @Container
    @ServiceConnection(name = "redis")
    static GenericContainer<?> redis =
        new GenericContainer<>(DockerImageName.parse("redis:7-alpine"))
            .withExposedPorts(6379);

    @Container
    @ServiceConnection
    static KafkaContainer kafka =
        new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.7.0"));
}

// Extend for all integration tests — shared context for caching
class OrderServiceIT extends BaseIntegrationTest {
    @Autowired OrderService orderService;
    // tests...
}
class PaymentServiceIT extends BaseIntegrationTest {
    @Autowired PaymentService paymentService;
    // tests...
}


// ---------------------------------------------------------------------------
// 6. @WebMvcTest with Security — OAuth2/JWT Testing
// ---------------------------------------------------------------------------
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors;

@WebMvcTest(OrderController.class)
class OrderControllerSecurityTest {

    @Autowired private MockMvc mockMvc;
    @MockitoBean private OrderService orderService;

    @Test
    void shouldAllowAccessWithValidJwt() throws Exception {
        when(orderService.findById(1L)).thenReturn(new OrderDto(1L, "PENDING"));

        mockMvc.perform(get("/api/v1/orders/1")
                .with(SecurityMockMvcRequestPostProcessors.jwt()
                    .authorities(new SimpleGrantedAuthority("ROLE_USER"))
                    .jwt(jwt -> jwt.claim("sub", "user123"))))
            .andExpect(status().isOk());
    }

    @Test
    void shouldDenyAccessWithoutAdminRole() throws Exception {
        mockMvc.perform(delete("/api/v1/orders/1")
                .with(SecurityMockMvcRequestPostProcessors.jwt()
                    .authorities(new SimpleGrantedAuthority("ROLE_USER"))))
            .andExpect(status().isForbidden());
    }

    @Test
    void shouldAllowAdminToDelete() throws Exception {
        mockMvc.perform(delete("/api/v1/orders/1")
                .with(csrf())
                .with(SecurityMockMvcRequestPostProcessors.jwt()
                    .authorities(new SimpleGrantedAuthority("ROLE_ADMIN"))))
            .andExpect(status().isNoContent());
    }
}


// ---------------------------------------------------------------------------
// 7. Custom Test Utilities
// ---------------------------------------------------------------------------

// Reusable test annotation for common integration test setup
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@Testcontainers
@ActiveProfiles("test")
@interface IntegrationTest {}

// Usage:
@IntegrationTest
class MyServiceIT {
    // No need to repeat annotations
}


// ---------------------------------------------------------------------------
// 8. Output Capture — Testing Logging Output
// ---------------------------------------------------------------------------
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;

@ExtendWith(OutputCaptureExtension.class)
class AuditServiceTest {

    @Test
    void shouldLogAuditEvent(CapturedOutput output) {
        auditService.log("user.login", "user123");
        assertThat(output).contains("AUDIT: user.login by user123");
    }
}


// ---------------------------------------------------------------------------
// 9. @JsonTest — JSON Serialization Tests
// ---------------------------------------------------------------------------
import org.springframework.boot.test.autoconfigure.json.JsonTest;
import org.springframework.boot.test.json.JacksonTester;

@JsonTest
class UserDtoJsonTest {

    @Autowired
    private JacksonTester<UserDto> json;

    @Test
    void shouldSerialize() throws Exception {
        var user = new UserDto(1L, "Alice", "alice@test.com");
        assertThat(json.write(user))
            .extractingJsonPathStringValue("$.name").isEqualTo("Alice");
        assertThat(json.write(user))
            .doesNotHaveJsonPath("$.password");
    }

    @Test
    void shouldDeserialize() throws Exception {
        var content = """
            {"id": 1, "name": "Alice", "email": "alice@test.com"}
            """;
        assertThat(json.parse(content))
            .usingRecursiveComparison()
            .isEqualTo(new UserDto(1L, "Alice", "alice@test.com"));
    }
}


// ---------------------------------------------------------------------------
// 10. RestClient Testing with MockRestServiceServer
// ---------------------------------------------------------------------------
import org.springframework.boot.test.autoconfigure.web.client.RestClientTest;
import org.springframework.test.web.client.MockRestServiceServer;

@RestClientTest(ExternalApiService.class)
class ExternalApiServiceTest {

    @Autowired private ExternalApiService apiService;
    @Autowired private MockRestServiceServer server;

    @Test
    void shouldFetchOrder() {
        server.expect(requestTo("/orders/123"))
            .andRespond(withSuccess("""
                {"id": "123", "status": "COMPLETED"}
                """, MediaType.APPLICATION_JSON));

        OrderResponse order = apiService.getOrder("123");
        assertThat(order.status()).isEqualTo("COMPLETED");
        server.verify();
    }
}
