#!/usr/bin/env python3
"""
generate-test-template.py — Generate a Testcontainers test template.

Creates a ready-to-run integration test file for a chosen language and service.

Usage:
    python generate-test-template.py <language> <service> [--output <file>]

Languages: java, python, node, go, dotnet
Services:  postgres, mysql, mongodb, redis, kafka, elasticsearch, localstack

Examples:
    python generate-test-template.py java postgres
    python generate-test-template.py python redis --output tests/test_redis.py
    python generate-test-template.py node kafka --output tests/kafka.test.ts
    python generate-test-template.py go mongodb
    python generate-test-template.py dotnet postgres
"""

import argparse
import sys
import os
from pathlib import Path

TEMPLATES = {
    # -----------------------------------------------------------------
    # Java
    # -----------------------------------------------------------------
    ("java", "postgres"): {
        "filename": "PostgresIntegrationTest.java",
        "content": '''\
package com.example;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;

import static org.junit.jupiter.api.Assertions.*;

@Testcontainers
class PostgresIntegrationTest {

    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
        .withDatabaseName("testdb")
        .withUsername("test")
        .withPassword("test");

    @Test
    void shouldConnectAndQuery() throws Exception {
        try (Connection conn = DriverManager.getConnection(
                postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {

            conn.createStatement().execute(
                "CREATE TABLE users (id SERIAL PRIMARY KEY, name VARCHAR(255))");
            conn.createStatement().execute(
                "INSERT INTO users (name) VALUES ('alice')");

            ResultSet rs = conn.createStatement().executeQuery(
                "SELECT name FROM users WHERE name = 'alice'");
            assertTrue(rs.next());
            assertEquals("alice", rs.getString("name"));
        }
    }
}
''',
    },
    ("java", "redis"): {
        "filename": "RedisIntegrationTest.java",
        "content": '''\
package com.example;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import redis.clients.jedis.Jedis;

import static org.junit.jupiter.api.Assertions.*;

@Testcontainers
class RedisIntegrationTest {

    @Container
    static GenericContainer<?> redis = new GenericContainer<>("redis:7-alpine")
        .withExposedPorts(6379)
        .waitingFor(Wait.forListeningPort());

    @Test
    void shouldSetAndGetValue() {
        try (Jedis jedis = new Jedis(redis.getHost(), redis.getMappedPort(6379))) {
            jedis.set("key", "value");
            assertEquals("value", jedis.get("key"));
        }
    }
}
''',
    },
    ("java", "kafka"): {
        "filename": "KafkaIntegrationTest.java",
        "content": '''\
package com.example;

import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.clients.producer.*;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.KafkaContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.time.Duration;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

@Testcontainers
class KafkaIntegrationTest {

    @Container
    static KafkaContainer kafka = new KafkaContainer(
        DockerImageName.parse("confluentinc/cp-kafka:7.6.0"));

    @Test
    void shouldProduceAndConsume() throws Exception {
        String topic = "test-topic";

        // Producer
        Properties prodProps = new Properties();
        prodProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, kafka.getBootstrapServers());
        prodProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        prodProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);

        try (KafkaProducer<String, String> producer = new KafkaProducer<>(prodProps)) {
            producer.send(new ProducerRecord<>(topic, "key", "hello")).get();
        }

        // Consumer
        Properties consProps = new Properties();
        consProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, kafka.getBootstrapServers());
        consProps.put(ConsumerConfig.GROUP_ID_CONFIG, "test-group");
        consProps.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        consProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
        consProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);

        try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(consProps)) {
            consumer.subscribe(List.of(topic));
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofSeconds(10));
            assertEquals(1, records.count());
            assertEquals("hello", records.iterator().next().value());
        }
    }
}
''',
    },
    ("java", "mongodb"): {
        "filename": "MongoDbIntegrationTest.java",
        "content": '''\
package com.example;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import org.bson.Document;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.MongoDBContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.junit.jupiter.api.Assertions.*;

@Testcontainers
class MongoDbIntegrationTest {

    @Container
    static MongoDBContainer mongo = new MongoDBContainer("mongo:7");

    @Test
    void shouldInsertAndFind() {
        try (MongoClient client = MongoClients.create(mongo.getConnectionString())) {
            MongoCollection<Document> collection =
                client.getDatabase("testdb").getCollection("users");

            collection.insertOne(new Document("name", "alice").append("age", 30));

            Document found = collection.find(new Document("name", "alice")).first();
            assertNotNull(found);
            assertEquals("alice", found.getString("name"));
        }
    }
}
''',
    },
    ("java", "mysql"): {
        "filename": "MySqlIntegrationTest.java",
        "content": '''\
package com.example;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.MySQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.*;

import static org.junit.jupiter.api.Assertions.*;

@Testcontainers
class MySqlIntegrationTest {

    @Container
    static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.4")
        .withDatabaseName("testdb")
        .withUsername("test")
        .withPassword("test");

    @Test
    void shouldConnectAndQuery() throws Exception {
        try (Connection conn = DriverManager.getConnection(
                mysql.getJdbcUrl(), mysql.getUsername(), mysql.getPassword())) {

            conn.createStatement().execute(
                "CREATE TABLE items (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))");
            conn.createStatement().execute(
                "INSERT INTO items (name) VALUES ('widget')");

            ResultSet rs = conn.createStatement().executeQuery("SELECT name FROM items");
            assertTrue(rs.next());
            assertEquals("widget", rs.getString("name"));
        }
    }
}
''',
    },
    ("java", "elasticsearch"): {
        "filename": "ElasticsearchIntegrationTest.java",
        "content": '''\
package com.example;

import org.junit.jupiter.api.Test;
import org.testcontainers.elasticsearch.ElasticsearchContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.net.URI;
import java.net.http.*;

import static org.junit.jupiter.api.Assertions.*;

@Testcontainers
class ElasticsearchIntegrationTest {

    @Container
    static ElasticsearchContainer es = new ElasticsearchContainer("elasticsearch:8.13.4")
        .withEnv("xpack.security.enabled", "false");

    @Test
    void shouldIndexAndSearch() throws Exception {
        HttpClient client = HttpClient.newHttpClient();
        String baseUrl = "http://" + es.getHttpHostAddress();

        // Health check
        HttpResponse<String> health = client.send(
            HttpRequest.newBuilder(URI.create(baseUrl + "/_cluster/health")).build(),
            HttpResponse.BodyHandlers.ofString());
        assertEquals(200, health.statusCode());
    }
}
''',
    },
    ("java", "localstack"): {
        "filename": "LocalStackIntegrationTest.java",
        "content": '''\
package com.example;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.localstack.LocalStackContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import software.amazon.awssdk.auth.credentials.*;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;

import static org.junit.jupiter.api.Assertions.*;
import static org.testcontainers.containers.localstack.LocalStackContainer.Service.S3;

@Testcontainers
class LocalStackIntegrationTest {

    @Container
    static LocalStackContainer localstack = new LocalStackContainer(
            DockerImageName.parse("localstack/localstack:3.4"))
        .withServices(S3);

    @Test
    void shouldCreateS3Bucket() {
        S3Client s3 = S3Client.builder()
            .endpointOverride(localstack.getEndpointOverride(S3))
            .credentialsProvider(StaticCredentialsProvider.create(
                AwsBasicCredentials.create(
                    localstack.getAccessKey(), localstack.getSecretKey())))
            .region(Region.of(localstack.getRegion()))
            .build();

        s3.createBucket(CreateBucketRequest.builder().bucket("test-bucket").build());

        var buckets = s3.listBuckets().buckets();
        assertTrue(buckets.stream().anyMatch(b -> b.name().equals("test-bucket")));
    }
}
''',
    },

    # -----------------------------------------------------------------
    # Python
    # -----------------------------------------------------------------
    ("python", "postgres"): {
        "filename": "test_postgres.py",
        "content": '''\
"""Integration tests with PostgreSQL using Testcontainers."""
import pytest
from testcontainers.postgres import PostgresContainer
import sqlalchemy

@pytest.fixture(scope="module")
def postgres():
    with PostgresContainer("postgres:16-alpine") as pg:
        yield pg

@pytest.fixture(scope="module")
def engine(postgres):
    engine = sqlalchemy.create_engine(postgres.get_connection_url())
    with engine.begin() as conn:
        conn.execute(sqlalchemy.text(
            "CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT NOT NULL)"
        ))
    yield engine
    engine.dispose()

def test_insert_and_query(engine):
    with engine.begin() as conn:
        conn.execute(sqlalchemy.text("INSERT INTO users (name) VALUES (:n)"), {"n": "alice"})
        result = conn.execute(sqlalchemy.text("SELECT name FROM users WHERE name = :n"), {"n": "alice"})
        assert result.fetchone()[0] == "alice"

def test_count(engine):
    with engine.begin() as conn:
        result = conn.execute(sqlalchemy.text("SELECT COUNT(*) FROM users"))
        assert result.fetchone()[0] >= 0
''',
    },
    ("python", "redis"): {
        "filename": "test_redis.py",
        "content": '''\
"""Integration tests with Redis using Testcontainers."""
import pytest
from testcontainers.redis import RedisContainer
import redis

@pytest.fixture(scope="module")
def redis_container():
    with RedisContainer("redis:7-alpine") as r:
        yield r

@pytest.fixture
def client(redis_container):
    c = redis.Redis(
        host=redis_container.get_container_host_ip(),
        port=redis_container.get_exposed_port(6379),
        decode_responses=True,
    )
    yield c
    c.flushall()
    c.close()

def test_set_and_get(client):
    client.set("key", "value")
    assert client.get("key") == "value"

def test_list_operations(client):
    client.rpush("queue", "a", "b", "c")
    assert client.llen("queue") == 3
    assert client.lpop("queue") == "a"
''',
    },
    ("python", "mongodb"): {
        "filename": "test_mongodb.py",
        "content": '''\
"""Integration tests with MongoDB using Testcontainers."""
import pytest
from testcontainers.mongodb import MongoDbContainer
from pymongo import MongoClient

@pytest.fixture(scope="module")
def mongo():
    with MongoDbContainer("mongo:7") as m:
        yield m

@pytest.fixture
def db(mongo):
    client = MongoClient(mongo.get_connection_url())
    database = client["testdb"]
    yield database
    client.drop_database("testdb")
    client.close()

def test_insert_and_find(db):
    db.users.insert_one({"name": "alice", "age": 30})
    user = db.users.find_one({"name": "alice"})
    assert user is not None
    assert user["age"] == 30
''',
    },
    ("python", "kafka"): {
        "filename": "test_kafka.py",
        "content": '''\
"""Integration tests with Kafka using Testcontainers."""
import pytest
from testcontainers.kafka import KafkaContainer
from confluent_kafka import Producer, Consumer
import uuid, time

@pytest.fixture(scope="module")
def kafka():
    with KafkaContainer("confluentinc/cp-kafka:7.6.0") as k:
        yield k

def test_produce_and_consume(kafka):
    topic = f"test-{uuid.uuid4().hex[:8]}"

    # Produce
    producer = Producer({"bootstrap.servers": kafka.get_bootstrap_server()})
    producer.produce(topic, value=b"hello")
    producer.flush(timeout=5)

    # Consume
    consumer = Consumer({
        "bootstrap.servers": kafka.get_bootstrap_server(),
        "group.id": f"test-{uuid.uuid4().hex[:8]}",
        "auto.offset.reset": "earliest",
    })
    consumer.subscribe([topic])

    msg = None
    for _ in range(30):
        msg = consumer.poll(timeout=1.0)
        if msg is not None:
            break

    consumer.close()
    assert msg is not None
    assert msg.value() == b"hello"
''',
    },
    ("python", "mysql"): {
        "filename": "test_mysql.py",
        "content": '''\
"""Integration tests with MySQL using Testcontainers."""
import pytest
from testcontainers.mysql import MySqlContainer
import sqlalchemy

@pytest.fixture(scope="module")
def mysql():
    with MySqlContainer("mysql:8.4") as m:
        yield m

@pytest.fixture(scope="module")
def engine(mysql):
    engine = sqlalchemy.create_engine(mysql.get_connection_url())
    yield engine
    engine.dispose()

def test_connection(engine):
    with engine.begin() as conn:
        result = conn.execute(sqlalchemy.text("SELECT 1"))
        assert result.fetchone()[0] == 1
''',
    },
    ("python", "elasticsearch"): {
        "filename": "test_elasticsearch.py",
        "content": '''\
"""Integration tests with Elasticsearch using Testcontainers."""
import pytest
from testcontainers.elasticsearch import ElasticSearchContainer
from elasticsearch import Elasticsearch

@pytest.fixture(scope="module")
def es_container():
    with ElasticSearchContainer("elasticsearch:8.13.4") as es:
        yield es

@pytest.fixture(scope="module")
def es_client(es_container):
    host = es_container.get_container_host_ip()
    port = es_container.get_exposed_port(9200)
    client = Elasticsearch(f"http://{host}:{port}", verify_certs=False)
    yield client
    client.close()

def test_cluster_health(es_client):
    health = es_client.cluster.health()
    assert health["status"] in ("green", "yellow")
''',
    },
    ("python", "localstack"): {
        "filename": "test_localstack.py",
        "content": '''\
"""Integration tests with LocalStack using Testcontainers."""
import pytest
import boto3
from testcontainers.localstack import LocalStackContainer

@pytest.fixture(scope="module")
def localstack():
    with LocalStackContainer("localstack/localstack:3.4") as ls:
        yield ls

@pytest.fixture
def s3(localstack):
    return boto3.client(
        "s3",
        endpoint_url=localstack.get_url(),
        aws_access_key_id="test",
        aws_secret_access_key="test",
        region_name="us-east-1",
    )

def test_create_bucket(s3):
    s3.create_bucket(Bucket="test-bucket")
    buckets = s3.list_buckets()["Buckets"]
    assert any(b["Name"] == "test-bucket" for b in buckets)
''',
    },

    # -----------------------------------------------------------------
    # Node.js / TypeScript
    # -----------------------------------------------------------------
    ("node", "postgres"): {
        "filename": "postgres.test.ts",
        "content": '''\
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { PostgreSqlContainer, StartedPostgreSqlContainer } from "@testcontainers/postgresql";
import { Pool } from "pg";

describe("PostgreSQL Integration", () => {
  let container: StartedPostgreSqlContainer;
  let pool: Pool;

  beforeAll(async () => {
    container = await new PostgreSqlContainer("postgres:16-alpine")
      .withDatabase("testdb")
      .start();
    pool = new Pool({ connectionString: container.getConnectionUri() });

    await pool.query(`
      CREATE TABLE users (
        id SERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT UNIQUE
      )
    `);
  }, 120_000);

  afterAll(async () => {
    await pool.end();
    await container.stop();
  });

  it("should insert and query a user", async () => {
    await pool.query("INSERT INTO users (name, email) VALUES ($1, $2)", ["alice", "alice@test.com"]);
    const { rows } = await pool.query("SELECT name FROM users WHERE email = $1", ["alice@test.com"]);
    expect(rows[0].name).toBe("alice");
  });
});
''',
    },
    ("node", "redis"): {
        "filename": "redis.test.ts",
        "content": '''\
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { GenericContainer, StartedTestContainer, Wait } from "testcontainers";
import { createClient, RedisClientType } from "redis";

describe("Redis Integration", () => {
  let container: StartedTestContainer;
  let client: RedisClientType;

  beforeAll(async () => {
    container = await new GenericContainer("redis:7-alpine")
      .withExposedPorts(6379)
      .withWaitStrategy(Wait.forListeningPorts())
      .start();

    client = createClient({
      url: `redis://${container.getHost()}:${container.getMappedPort(6379)}`,
    });
    await client.connect();
  }, 60_000);

  afterAll(async () => {
    await client.quit();
    await container.stop();
  });

  it("should set and get a value", async () => {
    await client.set("key", "value");
    expect(await client.get("key")).toBe("value");
  });
});
''',
    },
    ("node", "kafka"): {
        "filename": "kafka.test.ts",
        "content": '''\
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { KafkaContainer, StartedKafkaContainer } from "@testcontainers/kafka";
import { Kafka } from "kafkajs";

describe("Kafka Integration", () => {
  let container: StartedKafkaContainer;
  let kafka: Kafka;

  beforeAll(async () => {
    container = await new KafkaContainer("confluentinc/cp-kafka:7.6.0").start();
    kafka = new Kafka({ brokers: [container.getBootstrapServers()] });
  }, 120_000);

  afterAll(async () => {
    await container.stop();
  });

  it("should produce and consume a message", async () => {
    const topic = "test-topic";
    const admin = kafka.admin();
    await admin.connect();
    await admin.createTopics({ topics: [{ topic }] });
    await admin.disconnect();

    const producer = kafka.producer();
    await producer.connect();
    await producer.send({ topic, messages: [{ value: "hello" }] });
    await producer.disconnect();

    const consumer = kafka.consumer({ groupId: "test-group" });
    await consumer.connect();
    await consumer.subscribe({ topic, fromBeginning: true });

    const messages: string[] = [];
    await new Promise<void>((resolve) => {
      consumer.run({
        eachMessage: async ({ message }) => {
          messages.push(message.value!.toString());
          resolve();
        },
      });
    });

    await consumer.disconnect();
    expect(messages).toContain("hello");
  });
});
''',
    },
    ("node", "mongodb"): {
        "filename": "mongodb.test.ts",
        "content": '''\
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { MongoDBContainer, StartedMongoDBContainer } from "@testcontainers/mongodb";
import { MongoClient, Db } from "mongodb";

describe("MongoDB Integration", () => {
  let container: StartedMongoDBContainer;
  let client: MongoClient;
  let db: Db;

  beforeAll(async () => {
    container = await new MongoDBContainer("mongo:7").start();
    client = new MongoClient(container.getConnectionString());
    await client.connect();
    db = client.db("testdb");
  }, 60_000);

  afterAll(async () => {
    await client.close();
    await container.stop();
  });

  it("should insert and find a document", async () => {
    const users = db.collection("users");
    await users.insertOne({ name: "alice", age: 30 });
    const user = await users.findOne({ name: "alice" });
    expect(user?.age).toBe(30);
  });
});
''',
    },
    ("node", "mysql"): {
        "filename": "mysql.test.ts",
        "content": '''\
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { MySqlContainer, StartedMySqlContainer } from "@testcontainers/mysql";
import mysql from "mysql2/promise";

describe("MySQL Integration", () => {
  let container: StartedMySqlContainer;
  let connection: mysql.Connection;

  beforeAll(async () => {
    container = await new MySqlContainer("mysql:8.4").start();
    connection = await mysql.createConnection({
      host: container.getHost(),
      port: container.getPort(),
      user: container.getUsername(),
      password: container.getUserPassword(),
      database: container.getDatabase(),
    });
  }, 120_000);

  afterAll(async () => {
    await connection.end();
    await container.stop();
  });

  it("should query the database", async () => {
    const [rows] = await connection.query("SELECT 1 as result");
    expect((rows as any[])[0].result).toBe(1);
  });
});
''',
    },
    ("node", "elasticsearch"): {
        "filename": "elasticsearch.test.ts",
        "content": '''\
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { ElasticsearchContainer, StartedElasticsearchContainer } from "@testcontainers/elasticsearch";

describe("Elasticsearch Integration", () => {
  let container: StartedElasticsearchContainer;

  beforeAll(async () => {
    container = await new ElasticsearchContainer("elasticsearch:8.13.4")
      .withEnvironment({ "xpack.security.enabled": "false" })
      .start();
  }, 120_000);

  afterAll(async () => {
    await container.stop();
  });

  it("should be healthy", async () => {
    const url = container.getHttpUrl();
    const res = await fetch(`${url}/_cluster/health`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(["green", "yellow"]).toContain(body.status);
  });
});
''',
    },
    ("node", "localstack"): {
        "filename": "localstack.test.ts",
        "content": '''\
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { LocalstackContainer, StartedLocalStackContainer } from "@testcontainers/localstack";
import { S3Client, CreateBucketCommand, ListBucketsCommand } from "@aws-sdk/client-s3";

describe("LocalStack Integration", () => {
  let container: StartedLocalStackContainer;
  let s3: S3Client;

  beforeAll(async () => {
    container = await new LocalstackContainer("localstack/localstack:3.4").start();
    s3 = new S3Client({
      endpoint: container.getConnectionUri(),
      region: "us-east-1",
      credentials: { accessKeyId: "test", secretAccessKey: "test" },
      forcePathStyle: true,
    });
  }, 60_000);

  afterAll(async () => {
    await container.stop();
  });

  it("should create an S3 bucket", async () => {
    await s3.send(new CreateBucketCommand({ Bucket: "test-bucket" }));
    const { Buckets } = await s3.send(new ListBucketsCommand({}));
    expect(Buckets?.some((b) => b.Name === "test-bucket")).toBe(true);
  });
});
''',
    },

    # -----------------------------------------------------------------
    # Go
    # -----------------------------------------------------------------
    ("go", "postgres"): {
        "filename": "postgres_test.go",
        "content": '''\
package integration_test

import (
\t"context"
\t"database/sql"
\t"testing"

\t_ "github.com/lib/pq"
\t"github.com/testcontainers/testcontainers-go/modules/postgres"
)

func TestPostgres(t *testing.T) {
\tctx := context.Background()

\tpgContainer, err := postgres.Run(ctx, "postgres:16-alpine",
\t\tpostgres.WithDatabase("testdb"),
\t\tpostgres.WithUsername("test"),
\t\tpostgres.WithPassword("test"),
\t)
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tt.Cleanup(func() { pgContainer.Terminate(ctx) })

\tconnStr, _ := pgContainer.ConnectionString(ctx, "sslmode=disable")
\tdb, err := sql.Open("postgres", connStr)
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tdefer db.Close()

\t_, err = db.ExecContext(ctx, "CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT)")
\tif err != nil {
\t\tt.Fatal(err)
\t}

\t_, err = db.ExecContext(ctx, "INSERT INTO users (name) VALUES ($1)", "alice")
\tif err != nil {
\t\tt.Fatal(err)
\t}

\tvar name string
\terr = db.QueryRowContext(ctx, "SELECT name FROM users WHERE name = $1", "alice").Scan(&name)
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tif name != "alice" {
\t\tt.Errorf("expected alice, got %s", name)
\t}
}
''',
    },
    ("go", "redis"): {
        "filename": "redis_test.go",
        "content": '''\
package integration_test

import (
\t"context"
\t"fmt"
\t"testing"

\t"github.com/redis/go-redis/v9"
\t"github.com/testcontainers/testcontainers-go"
\t"github.com/testcontainers/testcontainers-go/wait"
)

func TestRedis(t *testing.T) {
\tctx := context.Background()

\treq := testcontainers.ContainerRequest{
\t\tImage:        "redis:7-alpine",
\t\tExposedPorts: []string{"6379/tcp"},
\t\tWaitingFor:   wait.ForListeningPort("6379/tcp"),
\t}
\tctr, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
\t\tContainerRequest: req,
\t\tStarted:          true,
\t})
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tt.Cleanup(func() { ctr.Terminate(ctx) })

\thost, _ := ctr.Host(ctx)
\tport, _ := ctr.MappedPort(ctx, "6379/tcp")

\trdb := redis.NewClient(&redis.Options{
\t\tAddr: fmt.Sprintf("%s:%s", host, port.Port()),
\t})
\tdefer rdb.Close()

\trdb.Set(ctx, "key", "value", 0)
\tval, err := rdb.Get(ctx, "key").Result()
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tif val != "value" {
\t\tt.Errorf("expected value, got %s", val)
\t}
}
''',
    },
    ("go", "mongodb"): {
        "filename": "mongodb_test.go",
        "content": '''\
package integration_test

import (
\t"context"
\t"testing"

\t"github.com/testcontainers/testcontainers-go/modules/mongodb"
\t"go.mongodb.org/mongo-driver/bson"
\t"go.mongodb.org/mongo-driver/mongo"
\t"go.mongodb.org/mongo-driver/mongo/options"
)

func TestMongoDB(t *testing.T) {
\tctx := context.Background()

\tmongoCtr, err := mongodb.Run(ctx, "mongo:7")
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tt.Cleanup(func() { mongoCtr.Terminate(ctx) })

\turi, _ := mongoCtr.ConnectionString(ctx)
\tclient, err := mongo.Connect(ctx, options.Client().ApplyURI(uri))
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tdefer client.Disconnect(ctx)

\tcoll := client.Database("testdb").Collection("users")
\t_, err = coll.InsertOne(ctx, bson.M{"name": "alice", "age": 30})
\tif err != nil {
\t\tt.Fatal(err)
\t}

\tvar result bson.M
\terr = coll.FindOne(ctx, bson.M{"name": "alice"}).Decode(&result)
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tif result["name"] != "alice" {
\t\tt.Errorf("expected alice, got %v", result["name"])
\t}
}
''',
    },
    ("go", "kafka"): {
        "filename": "kafka_test.go",
        "content": '''\
package integration_test

import (
\t"context"
\t"testing"
\t"time"

\t"github.com/testcontainers/testcontainers-go/modules/kafka"
\tkgo "github.com/segmentio/kafka-go"
)

func TestKafka(t *testing.T) {
\tctx := context.Background()

\tkafkaCtr, err := kafka.Run(ctx, "confluentinc/cp-kafka:7.6.0")
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tt.Cleanup(func() { kafkaCtr.Terminate(ctx) })

\tbrokers, err := kafkaCtr.Brokers(ctx)
\tif err != nil {
\t\tt.Fatal(err)
\t}

\ttopic := "test-topic"

\t// Produce
\twriter := &kgo.Writer{
\t\tAddr:  kgo.TCP(brokers...),
\t\tTopic: topic,
\t}
\terr = writer.WriteMessages(ctx, kgo.Message{Value: []byte("hello")})
\tif err != nil {
\t\tt.Fatal(err)
\t}
\twriter.Close()

\t// Consume
\treader := kgo.NewReader(kgo.ReaderConfig{
\t\tBrokers: brokers,
\t\tTopic:   topic,
\t})
\tdefer reader.Close()

\tctxTimeout, cancel := context.WithTimeout(ctx, 10*time.Second)
\tdefer cancel()
\tmsg, err := reader.ReadMessage(ctxTimeout)
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tif string(msg.Value) != "hello" {
\t\tt.Errorf("expected hello, got %s", string(msg.Value))
\t}
}
''',
    },
    ("go", "mysql"): {
        "filename": "mysql_test.go",
        "content": '''\
package integration_test

import (
\t"context"
\t"database/sql"
\t"testing"

\t_ "github.com/go-sql-driver/mysql"
\t"github.com/testcontainers/testcontainers-go/modules/mysql"
)

func TestMySQL(t *testing.T) {
\tctx := context.Background()

\tctr, err := mysql.Run(ctx, "mysql:8.4",
\t\tmysql.WithDatabase("testdb"),
\t\tmysql.WithUsername("test"),
\t\tmysql.WithPassword("test"),
\t)
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tt.Cleanup(func() { ctr.Terminate(ctx) })

\tconnStr, _ := ctr.ConnectionString(ctx)
\tdb, err := sql.Open("mysql", connStr)
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tdefer db.Close()

\tvar result int
\terr = db.QueryRowContext(ctx, "SELECT 1").Scan(&result)
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tif result != 1 {
\t\tt.Errorf("expected 1, got %d", result)
\t}
}
''',
    },
    ("go", "elasticsearch"): {
        "filename": "elasticsearch_test.go",
        "content": '''\
package integration_test

import (
\t"context"
\t"net/http"
\t"testing"

\t"github.com/testcontainers/testcontainers-go/modules/elasticsearch"
)

func TestElasticsearch(t *testing.T) {
\tctx := context.Background()

\tesCtr, err := elasticsearch.Run(ctx, "elasticsearch:8.13.4",
\t\telasticsearch.WithPassword(""),
\t)
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tt.Cleanup(func() { esCtr.Terminate(ctx) })

\tsettings, err := esCtr.Settings(ctx)
\tif err != nil {
\t\tt.Fatal(err)
\t}

\tresp, err := http.Get(settings.Address + "/_cluster/health")
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tdefer resp.Body.Close()

\tif resp.StatusCode != 200 {
\t\tt.Errorf("expected 200, got %d", resp.StatusCode)
\t}
}
''',
    },
    ("go", "localstack"): {
        "filename": "localstack_test.go",
        "content": '''\
package integration_test

import (
\t"context"
\t"testing"

\t"github.com/aws/aws-sdk-go-v2/aws"
\t"github.com/aws/aws-sdk-go-v2/credentials"
\t"github.com/aws/aws-sdk-go-v2/service/s3"
\t"github.com/testcontainers/testcontainers-go/modules/localstack"
)

func TestLocalStack(t *testing.T) {
\tctx := context.Background()

\tlsCtr, err := localstack.Run(ctx, "localstack/localstack:3.4")
\tif err != nil {
\t\tt.Fatal(err)
\t}
\tt.Cleanup(func() { lsCtr.Terminate(ctx) })

\thost, _ := lsCtr.Host(ctx)
\tport, _ := lsCtr.MappedPort(ctx, "4566/tcp")

\tendpoint := "http://" + host + ":" + port.Port()

\ts3Client := s3.New(s3.Options{
\t\tBaseEndpoint: aws.String(endpoint),
\t\tCredentials:  credentials.NewStaticCredentialsProvider("test", "test", ""),
\t\tRegion:       "us-east-1",
\t\tUsePathStyle: true,
\t})

\t_, err = s3Client.CreateBucket(ctx, &s3.CreateBucketInput{
\t\tBucket: aws.String("test-bucket"),
\t})
\tif err != nil {
\t\tt.Fatal(err)
\t}

\tresult, err := s3Client.ListBuckets(ctx, &s3.ListBucketsInput{})
\tif err != nil {
\t\tt.Fatal(err)
\t}

\tfound := false
\tfor _, b := range result.Buckets {
\t\tif aws.ToString(b.Name) == "test-bucket" {
\t\t\tfound = true
\t\t}
\t}
\tif !found {
\t\tt.Error("test-bucket not found")
\t}
}
''',
    },

    # -----------------------------------------------------------------
    # .NET
    # -----------------------------------------------------------------
    ("dotnet", "postgres"): {
        "filename": "PostgresIntegrationTest.cs",
        "content": '''\
using Testcontainers.PostgreSql;
using Npgsql;
using Xunit;

public class PostgresIntegrationTest : IAsyncLifetime
{
    private readonly PostgreSqlContainer _postgres = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .WithDatabase("testdb")
        .WithUsername("test")
        .WithPassword("test")
        .Build();

    public Task InitializeAsync() => _postgres.StartAsync();
    public Task DisposeAsync() => _postgres.DisposeAsync().AsTask();

    [Fact]
    public async Task ShouldInsertAndQuery()
    {
        await using var conn = new NpgsqlConnection(_postgres.GetConnectionString());
        await conn.OpenAsync();

        await using var cmd = new NpgsqlCommand(
            "CREATE TABLE users (id serial PRIMARY KEY, name text)", conn);
        await cmd.ExecuteNonQueryAsync();

        cmd.CommandText = "INSERT INTO users (name) VALUES ('alice')";
        await cmd.ExecuteNonQueryAsync();

        cmd.CommandText = "SELECT name FROM users WHERE name = 'alice'";
        var result = await cmd.ExecuteScalarAsync();
        Assert.Equal("alice", result);
    }
}
''',
    },
    ("dotnet", "redis"): {
        "filename": "RedisIntegrationTest.cs",
        "content": '''\
using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Containers;
using StackExchange.Redis;
using Xunit;

public class RedisIntegrationTest : IAsyncLifetime
{
    private readonly IContainer _redis = new ContainerBuilder()
        .WithImage("redis:7-alpine")
        .WithPortBinding(6379, true)
        .WithWaitStrategy(Wait.ForUnixContainer().UntilPortIsAvailable(6379))
        .Build();

    public Task InitializeAsync() => _redis.StartAsync();
    public Task DisposeAsync() => _redis.DisposeAsync().AsTask();

    [Fact]
    public async Task ShouldSetAndGet()
    {
        var host = _redis.Hostname;
        var port = _redis.GetMappedPublicPort(6379);
        using var connection = await ConnectionMultiplexer.ConnectAsync($"{host}:{port}");
        var db = connection.GetDatabase();

        await db.StringSetAsync("key", "value");
        var result = await db.StringGetAsync("key");
        Assert.Equal("value", result.ToString());
    }
}
''',
    },
    ("dotnet", "mongodb"): {
        "filename": "MongoDbIntegrationTest.cs",
        "content": '''\
using Testcontainers.MongoDb;
using MongoDB.Driver;
using MongoDB.Bson;
using Xunit;

public class MongoDbIntegrationTest : IAsyncLifetime
{
    private readonly MongoDbContainer _mongo = new MongoDbBuilder()
        .WithImage("mongo:7")
        .Build();

    public Task InitializeAsync() => _mongo.StartAsync();
    public Task DisposeAsync() => _mongo.DisposeAsync().AsTask();

    [Fact]
    public async Task ShouldInsertAndFind()
    {
        var client = new MongoClient(_mongo.GetConnectionString());
        var db = client.GetDatabase("testdb");
        var collection = db.GetCollection<BsonDocument>("users");

        await collection.InsertOneAsync(new BsonDocument { { "name", "alice" }, { "age", 30 } });

        var filter = Builders<BsonDocument>.Filter.Eq("name", "alice");
        var result = await collection.Find(filter).FirstOrDefaultAsync();
        Assert.NotNull(result);
        Assert.Equal("alice", result["name"].AsString);
    }
}
''',
    },
    ("dotnet", "kafka"): {
        "filename": "KafkaIntegrationTest.cs",
        "content": '''\
using DotNet.Testcontainers.Builders;
using Confluent.Kafka;
using Xunit;

public class KafkaIntegrationTest : IAsyncLifetime
{
    private readonly IContainer _kafka = new ContainerBuilder()
        .WithImage("confluentinc/cp-kafka:7.6.0")
        .WithPortBinding(9092, true)
        .WithEnvironment("KAFKA_NODE_ID", "1")
        .WithEnvironment("KAFKA_PROCESS_ROLES", "broker,controller")
        .WithEnvironment("KAFKA_CONTROLLER_QUORUM_VOTERS", "1@localhost:9093")
        .WithEnvironment("KAFKA_LISTENERS", "PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093")
        .WithEnvironment("KAFKA_CONTROLLER_LISTENER_NAMES", "CONTROLLER")
        .WithEnvironment("KAFKA_LISTENER_SECURITY_PROTOCOL_MAP", "PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT")
        .WithWaitStrategy(Wait.ForUnixContainer().UntilPortIsAvailable(9092))
        .Build();

    public Task InitializeAsync() => _kafka.StartAsync();
    public Task DisposeAsync() => _kafka.DisposeAsync().AsTask();

    [Fact]
    public void ShouldProduceMessage()
    {
        var bootstrap = $"{_kafka.Hostname}:{_kafka.GetMappedPublicPort(9092)}";
        var config = new ProducerConfig { BootstrapServers = bootstrap };

        using var producer = new ProducerBuilder<Null, string>(config).Build();
        var result = producer.ProduceAsync("test-topic", new Message<Null, string> { Value = "hello" }).Result;
        Assert.NotNull(result);
    }
}
''',
    },
    ("dotnet", "mysql"): {
        "filename": "MySqlIntegrationTest.cs",
        "content": '''\
using Testcontainers.MySql;
using MySqlConnector;
using Xunit;

public class MySqlIntegrationTest : IAsyncLifetime
{
    private readonly MySqlContainer _mysql = new MySqlBuilder()
        .WithImage("mysql:8.4")
        .Build();

    public Task InitializeAsync() => _mysql.StartAsync();
    public Task DisposeAsync() => _mysql.DisposeAsync().AsTask();

    [Fact]
    public async Task ShouldQuery()
    {
        await using var conn = new MySqlConnection(_mysql.GetConnectionString());
        await conn.OpenAsync();

        await using var cmd = new MySqlCommand("SELECT 1", conn);
        var result = await cmd.ExecuteScalarAsync();
        Assert.Equal(1L, result);
    }
}
''',
    },
    ("dotnet", "elasticsearch"): {
        "filename": "ElasticsearchIntegrationTest.cs",
        "content": '''\
using Testcontainers.Elasticsearch;
using Xunit;

public class ElasticsearchIntegrationTest : IAsyncLifetime
{
    private readonly ElasticsearchContainer _es = new ElasticsearchBuilder()
        .WithImage("elasticsearch:8.13.4")
        .Build();

    public Task InitializeAsync() => _es.StartAsync();
    public Task DisposeAsync() => _es.DisposeAsync().AsTask();

    [Fact]
    public async Task ShouldBeHealthy()
    {
        using var client = new HttpClient();
        var response = await client.GetAsync($"{_es.GetConnectionString()}/_cluster/health");
        response.EnsureSuccessStatusCode();
    }
}
''',
    },
    ("dotnet", "localstack"): {
        "filename": "LocalStackIntegrationTest.cs",
        "content": '''\
using DotNet.Testcontainers.Builders;
using Amazon.S3;
using Amazon.S3.Model;
using Xunit;

public class LocalStackIntegrationTest : IAsyncLifetime
{
    private readonly IContainer _localstack = new ContainerBuilder()
        .WithImage("localstack/localstack:3.4")
        .WithPortBinding(4566, true)
        .WithWaitStrategy(Wait.ForUnixContainer().UntilPortIsAvailable(4566))
        .Build();

    public Task InitializeAsync() => _localstack.StartAsync();
    public Task DisposeAsync() => _localstack.DisposeAsync().AsTask();

    [Fact]
    public async Task ShouldCreateBucket()
    {
        var endpoint = $"http://{_localstack.Hostname}:{_localstack.GetMappedPublicPort(4566)}";
        var s3 = new AmazonS3Client(
            new Amazon.Runtime.BasicAWSCredentials("test", "test"),
            new AmazonS3Config
            {
                ServiceURL = endpoint,
                ForcePathStyle = true
            });

        await s3.PutBucketAsync(new PutBucketRequest { BucketName = "test-bucket" });
        var buckets = await s3.ListBucketsAsync();
        Assert.Contains(buckets.Buckets, b => b.BucketName == "test-bucket");
    }
}
''',
    },
}

# Default filenames for languages
DEFAULT_EXTENSIONS = {
    "java": ".java",
    "python": ".py",
    "node": ".test.ts",
    "go": "_test.go",
    "dotnet": ".cs",
}

LANGUAGE_ALIASES = {
    "js": "node",
    "javascript": "node",
    "typescript": "node",
    "ts": "node",
    "nodejs": "node",
    "py": "python",
    "csharp": "dotnet",
    "cs": "dotnet",
    "golang": "go",
}


def main():
    parser = argparse.ArgumentParser(
        description="Generate a Testcontainers test template."
    )
    parser.add_argument(
        "language",
        help="Language: java, python, node, go, dotnet",
    )
    parser.add_argument(
        "service",
        help="Service: postgres, mysql, mongodb, redis, kafka, elasticsearch, localstack",
    )
    parser.add_argument(
        "--output", "-o",
        help="Output file path (default: stdout or language-appropriate filename)",
    )
    parser.add_argument(
        "--list", "-l",
        action="store_true",
        help="List available language/service combinations",
    )

    args = parser.parse_args()

    if args.list:
        print("Available templates:")
        for lang, svc in sorted(TEMPLATES.keys()):
            info = TEMPLATES[(lang, svc)]
            print(f"  {lang:10s} {svc:20s} → {info['filename']}")
        return

    lang = LANGUAGE_ALIASES.get(args.language.lower(), args.language.lower())
    service = args.service.lower()

    key = (lang, service)
    if key not in TEMPLATES:
        print(f"Error: No template for language='{lang}', service='{service}'", file=sys.stderr)
        print(f"\nAvailable combinations:", file=sys.stderr)
        for l, s in sorted(TEMPLATES.keys()):
            if l == lang:
                print(f"  {l} {s}", file=sys.stderr)
        if not any(l == lang for l, _ in TEMPLATES.keys()):
            print(f"\nSupported languages: java, python, node, go, dotnet", file=sys.stderr)
        sys.exit(1)

    template = TEMPLATES[key]
    content = template["content"]

    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(content)
        print(f"✅ Generated: {output_path}")
    else:
        default_name = template["filename"]
        output_path = Path(default_name)
        if output_path.exists():
            print(f"⚠️  {default_name} already exists. Printing to stdout:\n", file=sys.stderr)
            print(content)
        else:
            output_path.write_text(content)
            print(f"✅ Generated: {output_path}")


if __name__ == "__main__":
    main()
