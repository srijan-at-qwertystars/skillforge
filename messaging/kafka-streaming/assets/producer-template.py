"""
Kafka Producer Template — Python (confluent-kafka) with Avro serialization.

Features:
  - Avro serialization via Schema Registry
  - Delivery callbacks with error handling
  - Graceful shutdown
  - Idempotent producer (default since librdkafka 2.x)

Requirements:
  pip install confluent-kafka[avro] requests

Usage:
  python producer-template.py
"""

import atexit
import json
import logging
import signal
import sys
import time
from dataclasses import dataclass
from typing import Any

from confluent_kafka import KafkaError, KafkaException, Producer
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroSerializer
from confluent_kafka.serialization import (
    MessageField,
    SerializationContext,
    StringSerializer,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger("kafka-producer")

# ---------------------------------------------------------------------------
# Configuration — update for your environment
# ---------------------------------------------------------------------------
KAFKA_CONFIG = {
    "bootstrap.servers": "localhost:9092",
    "acks": "all",
    "enable.idempotence": True,
    "retries": 2147483647,
    "max.in.flight.requests.per.connection": 5,
    "batch.size": 32768,
    "linger.ms": 20,
    "compression.type": "lz4",
    "delivery.timeout.ms": 120000,
}

SCHEMA_REGISTRY_URL = "http://localhost:8081"
TOPIC = "orders"

# Avro schema for the value
VALUE_SCHEMA_STR = json.dumps(
    {
        "type": "record",
        "name": "Order",
        "namespace": "com.example.events",
        "fields": [
            {"name": "order_id", "type": "string"},
            {"name": "customer_id", "type": "string"},
            {"name": "amount", "type": "double"},
            {"name": "currency", "type": "string", "default": "USD"},
            {"name": "created_at", "type": "long", "logicalType": "timestamp-millis"},
        ],
    }
)


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------
@dataclass
class Order:
    order_id: str
    customer_id: str
    amount: float
    currency: str = "USD"
    created_at: int = 0

    def __post_init__(self):
        if self.created_at == 0:
            self.created_at = int(time.time() * 1000)

    def to_dict(self, _ctx: Any = None) -> dict:
        return {
            "order_id": self.order_id,
            "customer_id": self.customer_id,
            "amount": self.amount,
            "currency": self.currency,
            "created_at": self.created_at,
        }


# ---------------------------------------------------------------------------
# Delivery callback
# ---------------------------------------------------------------------------
_delivery_failures = 0


def delivery_callback(err, msg):
    """Called once per message to indicate delivery result."""
    global _delivery_failures
    if err is not None:
        _delivery_failures += 1
        logger.error(
            "Delivery failed for %s [%s]: %s",
            msg.topic(),
            msg.key(),
            err,
        )
    else:
        logger.debug(
            "Delivered %s [%d] @ offset %d",
            msg.topic(),
            msg.partition(),
            msg.offset(),
        )


# ---------------------------------------------------------------------------
# Producer setup
# ---------------------------------------------------------------------------
def create_producer() -> tuple[Producer, AvroSerializer]:
    """Create a Kafka producer with Avro serialization."""
    sr_client = SchemaRegistryClient({"url": SCHEMA_REGISTRY_URL})
    avro_serializer = AvroSerializer(
        sr_client,
        VALUE_SCHEMA_STR,
        to_dict=lambda obj, ctx: obj.to_dict(ctx),
    )

    producer = Producer(KAFKA_CONFIG)
    logger.info("Producer created (bootstrap: %s)", KAFKA_CONFIG["bootstrap.servers"])
    return producer, avro_serializer


# ---------------------------------------------------------------------------
# Send function
# ---------------------------------------------------------------------------
def send_order(
    producer: Producer,
    serializer: AvroSerializer,
    topic: str,
    order: Order,
) -> None:
    """Serialize and send an order to Kafka."""
    key_serializer = StringSerializer("utf_8")
    try:
        producer.produce(
            topic=topic,
            key=key_serializer(order.order_id),
            value=serializer(
                order, SerializationContext(topic, MessageField.VALUE)
            ),
            on_delivery=delivery_callback,
        )
        # Trigger delivery callbacks without blocking
        producer.poll(0)
    except BufferError:
        logger.warning("Producer buffer full — waiting for deliveries...")
        producer.flush(timeout=30)
        # Retry after flush
        producer.produce(
            topic=topic,
            key=key_serializer(order.order_id),
            value=serializer(
                order, SerializationContext(topic, MessageField.VALUE)
            ),
            on_delivery=delivery_callback,
        )
    except KafkaException as e:
        logger.error("Failed to produce message: %s", e)
        raise


# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------
_shutdown = False


def shutdown_handler(signum, frame):
    global _shutdown
    logger.info("Shutdown signal received (signal %d)", signum)
    _shutdown = True


signal.signal(signal.SIGINT, shutdown_handler)
signal.signal(signal.SIGTERM, shutdown_handler)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    producer, serializer = create_producer()

    def cleanup():
        logger.info("Flushing remaining messages...")
        remaining = producer.flush(timeout=30)
        if remaining > 0:
            logger.warning("%d messages were not delivered", remaining)
        logger.info("Producer closed. Delivery failures: %d", _delivery_failures)

    atexit.register(cleanup)

    # Example: produce 10 sample orders
    for i in range(1, 11):
        if _shutdown:
            break
        order = Order(
            order_id=f"ORD-{i:04d}",
            customer_id=f"CUST-{(i % 5) + 1:03d}",
            amount=round(10.0 + i * 7.5, 2),
        )
        send_order(producer, serializer, TOPIC, order)
        logger.info("Sent order %s (amount=%.2f %s)", order.order_id, order.amount, order.currency)

    # Final flush
    producer.flush(timeout=30)
    logger.info("All messages sent. Failures: %d", _delivery_failures)


if __name__ == "__main__":
    main()
