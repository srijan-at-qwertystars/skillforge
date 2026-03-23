"""
Testcontainers pytest fixture templates for common services.

Usage: Copy the fixtures you need into your project's conftest.py.
Install: pip install testcontainers[postgres,mysql,mongodb,redis,kafka]
         pip install sqlalchemy pymongo redis confluent-kafka boto3
"""

import pytest


# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def postgres_container():
    """Session-scoped PostgreSQL container."""
    from testcontainers.postgres import PostgresContainer

    with PostgresContainer("postgres:16-alpine") as pg:
        yield pg


@pytest.fixture(scope="session")
def postgres_engine(postgres_container):
    """SQLAlchemy engine connected to the test Postgres."""
    from sqlalchemy import create_engine

    engine = create_engine(postgres_container.get_connection_url())
    yield engine
    engine.dispose()


@pytest.fixture
def postgres_session(postgres_engine):
    """Per-test transactional session (rolls back after each test)."""
    from sqlalchemy.orm import Session

    connection = postgres_engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)
    yield session
    session.close()
    transaction.rollback()
    connection.close()


# ---------------------------------------------------------------------------
# MySQL
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def mysql_container():
    """Session-scoped MySQL container."""
    from testcontainers.mysql import MySqlContainer

    with MySqlContainer("mysql:8.4") as mysql:
        yield mysql


@pytest.fixture(scope="session")
def mysql_engine(mysql_container):
    from sqlalchemy import create_engine

    engine = create_engine(mysql_container.get_connection_url())
    yield engine
    engine.dispose()


# ---------------------------------------------------------------------------
# MongoDB
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def mongo_container():
    """Session-scoped MongoDB container."""
    from testcontainers.mongodb import MongoDbContainer

    with MongoDbContainer("mongo:7") as mongo:
        yield mongo


@pytest.fixture(scope="session")
def mongo_client(mongo_container):
    """PyMongo client connected to the test MongoDB."""
    from pymongo import MongoClient

    client = MongoClient(mongo_container.get_connection_url())
    yield client
    client.close()


@pytest.fixture
def mongo_db(mongo_client):
    """Per-test MongoDB database (dropped after each test)."""
    import uuid

    db_name = f"test_{uuid.uuid4().hex[:8]}"
    db = mongo_client[db_name]
    yield db
    mongo_client.drop_database(db_name)


# ---------------------------------------------------------------------------
# Redis
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def redis_container():
    """Session-scoped Redis container."""
    from testcontainers.redis import RedisContainer

    with RedisContainer("redis:7-alpine") as r:
        yield r


@pytest.fixture
def redis_client(redis_container):
    """Per-test Redis client (flushed after each test)."""
    import redis

    client = redis.Redis(
        host=redis_container.get_container_host_ip(),
        port=redis_container.get_exposed_port(6379),
        decode_responses=True,
    )
    yield client
    client.flushall()
    client.close()


# ---------------------------------------------------------------------------
# Kafka
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def kafka_container():
    """Session-scoped Kafka container."""
    from testcontainers.kafka import KafkaContainer

    with KafkaContainer("confluentinc/cp-kafka:7.6.0") as kafka:
        yield kafka


@pytest.fixture
def kafka_producer(kafka_container):
    """Confluent Kafka producer connected to the test broker."""
    from confluent_kafka import Producer

    producer = Producer({"bootstrap.servers": kafka_container.get_bootstrap_server()})
    yield producer
    producer.flush(timeout=5)


@pytest.fixture
def kafka_consumer(kafka_container):
    """Confluent Kafka consumer connected to the test broker."""
    from confluent_kafka import Consumer
    import uuid

    consumer = Consumer({
        "bootstrap.servers": kafka_container.get_bootstrap_server(),
        "group.id": f"test-group-{uuid.uuid4().hex[:8]}",
        "auto.offset.reset": "earliest",
    })
    yield consumer
    consumer.close()


# ---------------------------------------------------------------------------
# LocalStack (AWS emulator)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def localstack_container():
    """Session-scoped LocalStack container for AWS service emulation."""
    from testcontainers.localstack import LocalStackContainer

    with LocalStackContainer("localstack/localstack:3.4") as ls:
        yield ls


@pytest.fixture
def s3_client(localstack_container):
    """Boto3 S3 client pointing at LocalStack."""
    import boto3

    return boto3.client(
        "s3",
        endpoint_url=localstack_container.get_url(),
        aws_access_key_id="test",
        aws_secret_access_key="test",
        region_name="us-east-1",
    )


@pytest.fixture
def sqs_client(localstack_container):
    """Boto3 SQS client pointing at LocalStack."""
    import boto3

    return boto3.client(
        "sqs",
        endpoint_url=localstack_container.get_url(),
        aws_access_key_id="test",
        aws_secret_access_key="test",
        region_name="us-east-1",
    )


@pytest.fixture
def dynamodb_resource(localstack_container):
    """Boto3 DynamoDB resource pointing at LocalStack."""
    import boto3

    return boto3.resource(
        "dynamodb",
        endpoint_url=localstack_container.get_url(),
        aws_access_key_id="test",
        aws_secret_access_key="test",
        region_name="us-east-1",
    )


# ---------------------------------------------------------------------------
# Elasticsearch
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def elasticsearch_container():
    """Session-scoped Elasticsearch container."""
    from testcontainers.elasticsearch import ElasticSearchContainer

    with ElasticSearchContainer("elasticsearch:8.13.4") as es:
        yield es


@pytest.fixture
def es_client(elasticsearch_container):
    """Elasticsearch client connected to test instance."""
    from elasticsearch import Elasticsearch

    host = elasticsearch_container.get_container_host_ip()
    port = elasticsearch_container.get_exposed_port(9200)
    client = Elasticsearch(
        f"http://{host}:{port}",
        verify_certs=False,
    )
    yield client
    client.close()


# ---------------------------------------------------------------------------
# Generic container helper
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def generic_container():
    """Factory fixture for creating arbitrary containers."""
    from testcontainers.core.container import DockerContainer

    containers = []

    def _create(image, ports=None, env=None):
        c = DockerContainer(image)
        for port in (ports or []):
            c.with_exposed_ports(port)
        for key, val in (env or {}).items():
            c.with_env(key, val)
        c.start()
        containers.append(c)
        return c

    yield _create

    for c in reversed(containers):
        c.stop()
