#!/usr/bin/env python3
"""
RabbitMQ Producer/Consumer with publisher confirms, retry logic, and graceful shutdown.

Requirements: pip install pika

Usage:
    python python-producer-consumer.py produce --count 100
    python python-producer-consumer.py consume --queue orders.processing
"""

import argparse
import json
import logging
import signal
import sys
import time
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from uuid import uuid4

import pika
from pika.exceptions import (
    AMQPConnectionError,
    AMQPChannelError,
    UnroutableError,
    NackError,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("rabbitmq-app")

# ─── Configuration ───

DEFAULT_CONFIG = {
    "host": "localhost",
    "port": 5672,
    "vhost": "/production",
    "username": "admin",
    "password": "changeme",
    "heartbeat": 60,
    "blocked_connection_timeout": 300,
    "connection_attempts": 3,
    "retry_delay": 5,
}

EXCHANGE = "orders"
EXCHANGE_TYPE = "topic"
QUEUE = "orders.processing"
ROUTING_KEY = "order.created"
DLX_EXCHANGE = "dlx"
DLQ_QUEUE = "orders.dead-letters"


# ─── Connection Management ───

def create_connection_params(config: dict) -> pika.ConnectionParameters:
    return pika.ConnectionParameters(
        host=config["host"],
        port=config["port"],
        virtual_host=config["vhost"],
        credentials=pika.PlainCredentials(config["username"], config["password"]),
        heartbeat=config["heartbeat"],
        blocked_connection_timeout=config["blocked_connection_timeout"],
        connection_attempts=config["connection_attempts"],
        retry_delay=config["retry_delay"],
    )


@contextmanager
def rabbitmq_connection(config: dict):
    """Context manager for RabbitMQ connections with automatic cleanup."""
    params = create_connection_params(config)
    connection = None
    try:
        connection = pika.BlockingConnection(params)
        logger.info("Connected to RabbitMQ at %s:%d/%s", config["host"], config["port"], config["vhost"])
        yield connection
    finally:
        if connection and connection.is_open:
            connection.close()
            logger.info("Connection closed")


def setup_topology(channel):
    """Declare exchanges, queues, and bindings."""
    # Dead letter exchange and queue
    channel.exchange_declare(exchange=DLX_EXCHANGE, exchange_type="direct", durable=True)
    channel.queue_declare(queue=DLQ_QUEUE, durable=True, arguments={
        "x-queue-type": "quorum",
    })
    channel.queue_bind(exchange=DLX_EXCHANGE, queue=DLQ_QUEUE, routing_key=ROUTING_KEY)

    # Main exchange and queue
    channel.exchange_declare(exchange=EXCHANGE, exchange_type=EXCHANGE_TYPE, durable=True)
    channel.queue_declare(queue=QUEUE, durable=True, arguments={
        "x-queue-type": "quorum",
        "x-delivery-limit": 5,
        "x-dead-letter-exchange": DLX_EXCHANGE,
        "x-dead-letter-routing-key": ROUTING_KEY,
        "x-max-length": 100000,
        "x-overflow": "reject-publish",
    })
    channel.queue_bind(exchange=EXCHANGE, queue=QUEUE, routing_key="order.created.#")

    logger.info("Topology declared: exchange=%s, queue=%s, dlq=%s", EXCHANGE, QUEUE, DLQ_QUEUE)


# ─── Producer ───

class ReliableProducer:
    """Producer with publisher confirms and retry logic."""

    def __init__(self, config: dict, max_retries: int = 3, retry_delay: float = 1.0):
        self.config = config
        self.max_retries = max_retries
        self.retry_delay = retry_delay
        self.connection = None
        self.channel = None
        self._published = 0
        self._failed = 0

    def connect(self):
        params = create_connection_params(self.config)
        self.connection = pika.BlockingConnection(params)
        self.channel = self.connection.channel()
        self.channel.confirm_delivery()
        setup_topology(self.channel)
        logger.info("Producer connected with publisher confirms enabled")

    def close(self):
        if self.connection and self.connection.is_open:
            self.connection.close()
        logger.info("Producer closed. Published: %d, Failed: %d", self._published, self._failed)

    def publish(self, message: dict, routing_key: str = ROUTING_KEY) -> bool:
        """Publish a message with retry logic. Returns True if confirmed."""
        msg_id = str(uuid4())
        body = json.dumps(message, default=str)
        properties = pika.BasicProperties(
            delivery_mode=2,  # persistent
            content_type="application/json",
            message_id=msg_id,
            timestamp=int(time.time()),
            headers={"produced_at": datetime.now(timezone.utc).isoformat()},
        )

        for attempt in range(1, self.max_retries + 1):
            try:
                self.channel.basic_publish(
                    exchange=EXCHANGE,
                    routing_key=routing_key,
                    body=body,
                    properties=properties,
                    mandatory=True,
                )
                self._published += 1
                return True

            except UnroutableError:
                logger.warning("Message %s unroutable (no matching binding)", msg_id)
                self._failed += 1
                return False

            except NackError:
                logger.warning("Message %s nacked by broker (attempt %d/%d)", msg_id, attempt, self.max_retries)
                if attempt < self.max_retries:
                    time.sleep(self.retry_delay * attempt)
                else:
                    self._failed += 1
                    return False

            except (AMQPConnectionError, AMQPChannelError) as e:
                logger.error("Connection error on publish (attempt %d/%d): %s", attempt, self.max_retries, e)
                if attempt < self.max_retries:
                    time.sleep(self.retry_delay * attempt)
                    try:
                        self.connect()
                    except Exception:
                        pass
                else:
                    self._failed += 1
                    return False

        return False

    def publish_batch(self, messages: list, routing_key: str = ROUTING_KEY) -> tuple:
        """Publish a batch of messages. Returns (success_count, failure_count)."""
        success = 0
        failed = 0
        for msg in messages:
            if self.publish(msg, routing_key):
                success += 1
            else:
                failed += 1
        return success, failed


# ─── Consumer ───

class GracefulConsumer:
    """Consumer with manual acks, prefetch control, and graceful shutdown."""

    def __init__(self, config: dict, queue: str = QUEUE, prefetch: int = 10):
        self.config = config
        self.queue = queue
        self.prefetch = prefetch
        self.connection = None
        self.channel = None
        self._running = False
        self._processed = 0
        self._errors = 0
        self._shutdown_event = threading.Event()

    def connect(self):
        params = create_connection_params(self.config)
        self.connection = pika.BlockingConnection(params)
        self.channel = self.connection.channel()
        self.channel.basic_qos(prefetch_count=self.prefetch)
        setup_topology(self.channel)
        logger.info("Consumer connected, prefetch=%d", self.prefetch)

    def _handle_message(self, ch, method, properties, body):
        """Process a message with error handling."""
        msg_id = properties.message_id or "unknown"
        try:
            message = json.loads(body)
            logger.info("Processing message %s: %s", msg_id, json.dumps(message)[:100])

            # --- Your processing logic here ---
            self.process(message, properties)
            # ---

            ch.basic_ack(delivery_tag=method.delivery_tag)
            self._processed += 1

        except json.JSONDecodeError as e:
            logger.error("Invalid JSON in message %s: %s", msg_id, e)
            ch.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
            self._errors += 1

        except KeyboardInterrupt:
            ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
            raise

        except Exception as e:
            logger.error("Error processing message %s: %s", msg_id, e, exc_info=True)
            # Requeue for transient errors; reject (to DLQ) for permanent errors
            requeue = self._is_transient_error(e)
            if requeue:
                ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
            else:
                ch.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
            self._errors += 1

    def process(self, message: dict, properties):
        """Override this method with your processing logic."""
        time.sleep(0.01)  # Simulate work
        logger.debug("Processed: %s", message.get("id", "unknown"))

    @staticmethod
    def _is_transient_error(error: Exception) -> bool:
        """Determine if an error is transient (worth retrying) or permanent."""
        transient_types = (ConnectionError, TimeoutError, OSError)
        return isinstance(error, transient_types)

    def start(self):
        """Start consuming with graceful shutdown support."""
        self._running = True

        # Register signal handlers for graceful shutdown
        original_sigint = signal.getsignal(signal.SIGINT)
        original_sigterm = signal.getsignal(signal.SIGTERM)

        def shutdown_handler(signum, frame):
            sig_name = signal.Signals(signum).name
            logger.info("Received %s — shutting down gracefully...", sig_name)
            self._running = False
            self._shutdown_event.set()
            if self.channel and self.channel.is_open:
                self.channel.stop_consuming()

        signal.signal(signal.SIGINT, shutdown_handler)
        signal.signal(signal.SIGTERM, shutdown_handler)

        try:
            while self._running:
                try:
                    self.connect()
                    self.channel.basic_consume(
                        queue=self.queue,
                        on_message_callback=self._handle_message,
                        auto_ack=False,
                    )
                    logger.info("Consuming from queue: %s", self.queue)
                    self.channel.start_consuming()

                except (AMQPConnectionError, AMQPChannelError) as e:
                    if not self._running:
                        break
                    logger.error("Connection lost: %s. Reconnecting in 5s...", e)
                    time.sleep(5)

                except Exception as e:
                    if not self._running:
                        break
                    logger.error("Unexpected error: %s. Reconnecting in 10s...", e, exc_info=True)
                    time.sleep(10)

        finally:
            signal.signal(signal.SIGINT, original_sigint)
            signal.signal(signal.SIGTERM, original_sigterm)
            if self.connection and self.connection.is_open:
                self.connection.close()
            logger.info(
                "Consumer stopped. Processed: %d, Errors: %d",
                self._processed,
                self._errors,
            )


# ─── CLI ───

def cmd_produce(args):
    config = {**DEFAULT_CONFIG, "host": args.host, "port": args.port}
    producer = ReliableProducer(config)
    producer.connect()

    try:
        for i in range(args.count):
            message = {
                "id": str(uuid4()),
                "type": "order.created",
                "sequence": i + 1,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "data": {"item": f"item-{i+1}", "quantity": (i % 10) + 1, "price": round(9.99 + i * 0.5, 2)},
            }
            ok = producer.publish(message, routing_key=f"order.created.us")
            if ok:
                logger.info("Published %d/%d: %s", i + 1, args.count, message["id"])
            else:
                logger.error("Failed to publish %d/%d", i + 1, args.count)
    finally:
        producer.close()


def cmd_consume(args):
    config = {**DEFAULT_CONFIG, "host": args.host, "port": args.port}
    consumer = GracefulConsumer(config, queue=args.queue, prefetch=args.prefetch)
    consumer.start()


def main():
    parser = argparse.ArgumentParser(description="RabbitMQ Producer/Consumer")
    parser.add_argument("--host", default="localhost", help="RabbitMQ host")
    parser.add_argument("--port", type=int, default=5672, help="RabbitMQ port")

    sub = parser.add_subparsers(dest="command", required=True)

    p_produce = sub.add_parser("produce", help="Publish messages")
    p_produce.add_argument("--count", type=int, default=10, help="Number of messages")

    p_consume = sub.add_parser("consume", help="Consume messages")
    p_consume.add_argument("--queue", default=QUEUE, help="Queue to consume from")
    p_consume.add_argument("--prefetch", type=int, default=10, help="Prefetch count")

    args = parser.parse_args()

    if args.command == "produce":
        cmd_produce(args)
    elif args.command == "consume":
        cmd_consume(args)


if __name__ == "__main__":
    main()
