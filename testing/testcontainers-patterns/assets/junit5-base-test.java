/**
 * Base test class for JUnit 5 integration tests using Testcontainers.
 *
 * Provides shared PostgreSQL and Redis containers, connection helpers,
 * and per-test transaction rollback.
 *
 * Usage:
 *   1. Copy into your project's test sources
 *   2. Adjust package name and imports
 *   3. Extend in your integration test classes
 *
 * Dependencies (Maven):
 *   org.testcontainers:testcontainers
 *   org.testcontainers:junit-jupiter
 *   org.testcontainers:postgresql
 *   org.postgresql:postgresql
 *   org.flywaydb:flyway-core (optional, for migrations)
 */

package com.example.testing;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.Network;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.junit.jupiter.Testcontainers;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.SQLException;
import java.time.Duration;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

// Optional: uncomment for Flyway migrations
// import org.flywaydb.core.Flyway;

@Testcontainers
public abstract class AbstractIntegrationTest {

    // -----------------------------------------------------------------------
    // Shared containers (singleton pattern — started once for all subclasses)
    // -----------------------------------------------------------------------

    private static final Network NETWORK = Network.newNetwork();

    protected static final PostgreSQLContainer<?> POSTGRES;
    protected static final GenericContainer<?> REDIS;

    static {
        POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("integration_test")
            .withUsername("test")
            .withPassword("test")
            .withNetwork(NETWORK)
            .withNetworkAliases("postgres")
            .withStartupTimeout(Duration.ofSeconds(60));
        POSTGRES.start();

        REDIS = new GenericContainer<>("redis:7-alpine")
            .withExposedPorts(6379)
            .withNetwork(NETWORK)
            .withNetworkAliases("redis")
            .waitingFor(Wait.forListeningPort());
        REDIS.start();
    }

    // -----------------------------------------------------------------------
    // DataSource & connection management
    // -----------------------------------------------------------------------

    private static HikariDataSource dataSource;
    protected Connection connection;

    @BeforeAll
    static void initDataSource() {
        if (dataSource == null) {
            HikariConfig config = new HikariConfig();
            config.setJdbcUrl(POSTGRES.getJdbcUrl());
            config.setUsername(POSTGRES.getUsername());
            config.setPassword(POSTGRES.getPassword());
            config.setMaximumPoolSize(5);
            config.setMinimumIdle(1);
            dataSource = new HikariDataSource(config);

            runMigrations();
        }
    }

    /**
     * Run database migrations. Override to customize migration behavior.
     * Uncomment the Flyway block or replace with your migration tool.
     */
    protected static void runMigrations() {
        // Option 1: Flyway
        // Flyway.configure()
        //     .dataSource(dataSource)
        //     .locations("classpath:db/migration")
        //     .load()
        //     .migrate();

        // Option 2: Raw SQL init script
        try (Connection conn = dataSource.getConnection()) {
            conn.createStatement().execute("""
                CREATE TABLE IF NOT EXISTS users (
                    id SERIAL PRIMARY KEY,
                    name VARCHAR(255) NOT NULL,
                    email VARCHAR(255) UNIQUE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS orders (
                    id SERIAL PRIMARY KEY,
                    user_id INTEGER REFERENCES users(id),
                    total DECIMAL(10,2) NOT NULL,
                    status VARCHAR(50) DEFAULT 'pending',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );
            """);
        } catch (SQLException e) {
            throw new RuntimeException("Failed to run migrations", e);
        }
    }

    @BeforeEach
    void openConnection() throws SQLException {
        connection = dataSource.getConnection();
        connection.setAutoCommit(false);
    }

    @AfterEach
    void rollbackAndClose() throws SQLException {
        if (connection != null && !connection.isClosed()) {
            connection.rollback();
            connection.close();
        }
    }

    // -----------------------------------------------------------------------
    // Helper methods
    // -----------------------------------------------------------------------

    /**
     * Get a fresh DataSource for creating repositories or services under test.
     */
    protected static DataSource getDataSource() {
        return dataSource;
    }

    /**
     * Get the JDBC URL for the running Postgres container.
     */
    protected static String getJdbcUrl() {
        return POSTGRES.getJdbcUrl();
    }

    /**
     * Get the Redis host for the running Redis container.
     */
    protected static String getRedisHost() {
        return REDIS.getHost();
    }

    /**
     * Get the mapped Redis port for the running Redis container.
     */
    protected static int getRedisPort() {
        return REDIS.getMappedPort(6379);
    }

    /**
     * Get a Redis connection string (host:port).
     */
    protected static String getRedisConnectionString() {
        return getRedisHost() + ":" + getRedisPort();
    }

    /**
     * Execute a SQL statement against the shared Postgres container.
     */
    protected void executeSql(String sql) throws SQLException {
        connection.createStatement().execute(sql);
    }

    /**
     * Clean specific tables between tests. Call from @BeforeEach if needed
     * instead of relying on transaction rollback.
     */
    protected void truncateTables(String... tableNames) throws SQLException {
        for (String table : tableNames) {
            connection.createStatement().execute("TRUNCATE " + table + " CASCADE");
        }
        connection.commit();
    }
}

/*
 * Example subclass:
 *
 * class UserRepositoryTest extends AbstractIntegrationTest {
 *
 *     @Test
 *     void shouldCreateUser() throws SQLException {
 *         executeSql("INSERT INTO users (name, email) VALUES ('alice', 'alice@test.com')");
 *
 *         var rs = connection.createStatement()
 *             .executeQuery("SELECT name FROM users WHERE email = 'alice@test.com'");
 *         assertTrue(rs.next());
 *         assertEquals("alice", rs.getString("name"));
 *         // Transaction is rolled back in @AfterEach
 *     }
 *
 *     @Test
 *     void shouldUseRedis() {
 *         String redisUrl = getRedisConnectionString();
 *         // Connect Jedis/Lettuce to redisUrl
 *     }
 * }
 */
