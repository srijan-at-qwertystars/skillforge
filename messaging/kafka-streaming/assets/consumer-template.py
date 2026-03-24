"""
Kafka Consumer Template — Python (confluent-kafka) with manual commit and graceful shutdown.

Features:
  - Manual offset commit (at-least-once semantics)
  - Graceful shutdown on SIGINT/SIGTERM
  - Error handling with dead letter topic routing
  - Configurable batch processing
  - Health check via simple flag

Requirements:
  pip install confluent-kafka

Usage:
  python consumer-template.py
"""

import logging
import signal
import sys
import time
from typing import Callable, Optional

from confluent_kafka import Consumer, KafkaError, KafkaException, Producer, TopicPartition

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger("kafka-consumer")

# ---------------------------------------------------------------------------
# Configuration — update for your environment
# ---------------------------------------------------------------------------
CONSUMER_CONFIG = {
    "bootstrap.servers": "localhost:9092",
    "group.id": "order-processor",
    "auto.offset.reset": "earliest",
    "enable.auto.commit": False,
    "max.poll.interval.ms": 300000,
    "session.timeout.ms": 30000,
    "heartbeat.interval.ms": 10000,
    "fetch.min.bytes": 1024,
    "fetch.max.wait.ms": 500,
    # Uncomment for exactly-once reads (transactional producers only):
    # "isolation.level": "read_committed",
}

TOPICS = ["orders"]
DLQ_TOPIC = "orders-dlq"
MAX_RETRIES = 3
BATCH_SIZE = 100  # commit after this many messages

# ---------------------------------------------------------------------------
# DLQ producer (lazy-initialized)
# ---------------------------------------------------------------------------
_dlq_producer: Optional[Producer] = None


def get_dlq_producer() -> Producer:
    global _dlq_producer
    if _dlq_producer is None:
        _dlq_producer = Producer({
            "bootstrap.servers": CONSUMER_CONFIG["bootstrap.servers"],
            "acks": "all",
            "enable.idempotence": True,
        })
    return _dlq_producer


def send_to_dlq(msg, error: Exception) -> None:
    """Route a failed message to the dead letter topic."""
    producer = get_dlq_producer()
    headers = [
        ("original-topic", msg.topic().encode("utf-8")),
        ("original-partition", str(msg.partition()).encode("utf-8")),
        ("original-offset", str(msg.offset()).encode("utf-8")),
        ("error-class", type(error).__name__.encode("utf-8")),
        ("error-message", str(error)[:500].encode("utf-8")),
        ("failed-at", str(int(time.time() * 1000)).encode("utf-8")),
    ]
    producer.produce(
        topic=DLQ_TOPIC,
        key=msg.key(),
        value=msg.value(),
        headers=headers,
    )
    producer.flush(timeout=10)
    logger.warning(
        "Sent to DLQ: topic=%s partition=%d offset=%d error=%s",
        msg.topic(), msg.partition(), msg.offset(), error,
    )


# ---------------------------------------------------------------------------
# Message processing — replace with your logic
# ---------------------------------------------------------------------------
def process_message(msg) -> None:
    """
    Process a single Kafka message.
    Raise an exception to trigger DLQ routing.
    """
    key = msg.key().decode("utf-8") if msg.key() else None
    value = msg.value().decode("utf-8") if msg.value() else None
    logger.info(
        "Processing: topic=%s partition=%d offset=%d key=%s",
        msg.topic(), msg.partition(), msg.offset(), key,
    )
    # --- Your processing logic here ---
    # Example: parse JSON, update database, call API, etc.
    # raise ValueError("Simulated failure") to test DLQ routing


# ---------------------------------------------------------------------------
# Consumer loop
# ---------------------------------------------------------------------------
class GracefulConsumer:
    """Kafka consumer with graceful shutdown and error handling."""

    def __init__(self, config: dict, topics: list[str]):
        self._consumer = Consumer(config)
        self._topics = topics
        self._running = False
        self._messages_processed = 0
        self._messages_failed = 0

    def start(self) -> None:
        self._running = True
        self._consumer.subscribe(self._topics, on_assign=self._on_assign, on_revoke=self._on_revoke)
        logger.info("Subscribed to topics: %s (group: %s)", self._topics, CONSUMER_CONFIG["group.id"])

        batch_count = 0

        try:
            while self._running:
                msg = self._consumer.poll(timeout=1.0)

                if msg is None:
                    continue

                if msg.error():
                    self._handle_error(msg)
                    continue

                # Process message with retry
                success = False
                for attempt in range(1, MAX_RETRIES + 1):
                    try:
                        process_message(msg)
                        success = True
                        self._messages_processed += 1
                        break
                    except Exception as e:
                        logger.warning(
                            "Processing attempt %d/%d failed: %s",
                            attempt, MAX_RETRIES, e,
                        )
                        if attempt == MAX_RETRIES:
                            send_to_dlq(msg, e)
                            self._messages_failed += 1

                batch_count += 1
                if batch_count >= BATCH_SIZE:
                    self._commit()
                    batch_count = 0

        except KafkaException as e:
            logger.error("Kafka error: %s", e)
            raise
        finally:
            self._shutdown()

    def stop(self) -> None:
        """Signal the consumer to stop."""
        logger.info("Stop requested")
        self._running = False

    def _commit(self) -> None:
        """Commit offsets synchronously."""
        try:
            self._consumer.commit(asynchronous=False)
            logger.debug("Offsets committed")
        except KafkaException as e:
            logger.error("Commit failed: %s", e)

    def _handle_error(self, msg) -> None:
        error = msg.error()
        if error.code() == KafkaError._PARTITION_EOF:
            logger.debug(
                "End of partition: %s [%d] @ %d",
                msg.topic(), msg.partition(), msg.offset(),
            )
        elif error.code() == KafkaError.UNKNOWN_TOPIC_OR_PART:
            logger.error("Unknown topic or partition: %s", error)
        else:
            logger.error("Consumer error: %s", error)

    def _on_assign(self, consumer, partitions) -> None:
        logger.info("Partitions assigned: %s", [f"{p.topic}:{p.partition}" for p in partitions])

    def _on_revoke(self, consumer, partitions) -> None:
        logger.info("Partitions revoked: %s", [f"{p.topic}:{p.partition}" for p in partitions])
        # Commit before revocation to avoid reprocessing
        self._commit()

    def _shutdown(self) -> None:
        """Graceful shutdown: commit final offsets and close."""
        logger.info("Shutting down consumer...")
        try:
            self._commit()
        except Exception:
            pass

        if _dlq_producer is not None:
            _dlq_producer.flush(timeout=10)

        self._consumer.close()
        logger.info(
            "Consumer closed. Processed: %d, Failed (DLQ): %d",
            self._messages_processed,
            self._messages_failed,
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    consumer = GracefulConsumer(CONSUMER_CONFIG, TOPICS)

    def signal_handler(signum, frame):
        logger.info("Received signal %d", signum)
        consumer.stop()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    consumer.start()


if __name__ == "__main__":
    main()
