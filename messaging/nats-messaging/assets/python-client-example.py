#!/usr/bin/env python3
"""
python-client-example.py — Production-grade async NATS client in Python.

Demonstrates:
  • Async/await connection with reconnect and error handlers
  • JetStream stream and consumer management
  • Publishing with headers
  • Pull subscriber with batch processing
  • Push subscriber with queue group
  • Key/Value store operations
  • Request/reply pattern
  • Graceful shutdown with signal handling
  • Structured logging and type hints

Prerequisites:
  pip install nats-py

Usage:
  python python-client-example.py
  NATS_URL=nats://remote:4222 python python-client-example.py
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import sys
from dataclasses import dataclass
from typing import Optional

import nats
from nats.aio.client import Client as NATSClient
from nats.aio.msg import Msg
from nats.errors import (
    ConnectionClosedError,
    NoServersError,
    TimeoutError as NATSTimeoutError,
)
from nats.js import JetStreamContext
from nats.js.api import (
    AckPolicy,
    ConsumerConfig,
    DeliverPolicy,
    RetentionPolicy,
    StorageType,
    StreamConfig,
)
from nats.js.errors import NotFoundError
from nats.js.kv import KeyValue

# ─── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logger = logging.getLogger("nats-example")


# ─── Configuration ────────────────────────────────────────────────────────────
@dataclass
class Config:
    """Application configuration, populated from environment variables."""

    url: str = os.getenv("NATS_URL", "nats://localhost:4222")
    creds_file: Optional[str] = os.getenv("NATS_CREDS")
    tls_cert: Optional[str] = os.getenv("NATS_CERT")
    tls_key: Optional[str] = os.getenv("NATS_KEY")
    tls_ca: Optional[str] = os.getenv("NATS_CA")

    # Demo parameters
    publish_count: int = 10
    batch_size: int = 5


# ─── Connection helpers ──────────────────────────────────────────────────────
async def connect(cfg: Config) -> NATSClient:
    """
    Establish a NATS connection with production-grade options.

    Includes reconnect logic, error handlers, and optional TLS / creds.
    """
    nc = NATSClient()

    # ── Event callbacks ───────────────────────────────────────────────────
    async def on_disconnect(conn: NATSClient) -> None:
        logger.warning("Disconnected from NATS")

    async def on_reconnect(conn: NATSClient) -> None:
        logger.info("Reconnected to %s", conn.connected_url)

    async def on_error(conn: NATSClient, sub: object, err: Exception) -> None:
        logger.error("Async error: sub=%s err=%s", sub, err)

    async def on_closed(conn: NATSClient) -> None:
        logger.info("Connection closed")

    # ── Build connect kwargs ──────────────────────────────────────────────
    connect_opts: dict = {
        "servers": cfg.url.split(","),
        "name": "python-nats-example",

        # Reconnect settings — keep trying for ~5 minutes
        "max_reconnect_attempts": 60,
        "reconnect_time_wait": 5,  # seconds

        # Event handlers
        "disconnected_cb": on_disconnect,
        "reconnected_cb": on_reconnect,
        "error_cb": on_error,
        "closed_cb": on_closed,

        # Flush timeout
        "flush_timeout": 10,
    }

    # Optional credentials file
    if cfg.creds_file:
        connect_opts["user_credentials"] = cfg.creds_file

    # Optional TLS
    if cfg.tls_cert and cfg.tls_key:
        import ssl

        tls_ctx = ssl.create_default_context(purpose=ssl.Purpose.SERVER_AUTH)
        tls_ctx.load_cert_chain(cfg.tls_cert, cfg.tls_key)
        if cfg.tls_ca:
            tls_ctx.load_verify_locations(cfg.tls_ca)
        connect_opts["tls"] = tls_ctx

    await nc.connect(**connect_opts)
    logger.info("Connected to %s", nc.connected_url)
    return nc


# ─── JetStream stream management ─────────────────────────────────────────────
async def ensure_stream(js: JetStreamContext) -> None:
    """Create or update the ORDERS stream idempotently."""
    stream_cfg = StreamConfig(
        name="ORDERS",
        subjects=["orders.>"],
        storage=StorageType.FILE,
        num_replicas=1,  # Use 3 in a clustered deployment
        retention=RetentionPolicy.LIMITS,
        max_msgs=-1,
        max_bytes=1 * 1024 * 1024 * 1024,  # 1 GB
        max_age=24 * 60 * 60 * 1_000_000_000,  # 24 hours in nanoseconds
        duplicate_window=2 * 60 * 1_000_000_000,  # 2 minutes in nanoseconds
    )

    try:
        info = await js.find_stream_info_by_subject("orders.>")
        # Stream exists — update its configuration
        await js.update_stream(stream_cfg)
        logger.info("Stream ORDERS updated")
    except NotFoundError:
        info = await js.add_stream(stream_cfg)
        logger.info("Stream ORDERS created — %d messages", info.state.messages)


# ─── Publishing ───────────────────────────────────────────────────────────────
async def publish_messages(
    js: JetStreamContext, count: int, shutdown_event: asyncio.Event
) -> None:
    """Publish order events with headers and deduplication IDs."""
    for i in range(1, count + 1):
        if shutdown_event.is_set():
            break

        payload = json.dumps({
            "order_id": i,
            "item": "widget",
            "qty": i * 10,
        }).encode()

        headers = {
            # Nats-Msg-Id enables server-side deduplication
            "Nats-Msg-Id": f"order-{i}",
            "X-Source": "python-client-example",
        }

        ack = await js.publish(
            f"orders.created.{i}",
            payload,
            headers=headers,
        )
        logger.info(
            "Published order %d → stream=%s seq=%d",
            i, ack.stream, ack.seq,
        )

        # Small delay so consumers can keep up in the demo
        await asyncio.sleep(0.2)

    logger.info("Finished publishing %d messages", count)


# ─── Pull consumer — batch fetch ─────────────────────────────────────────────
async def pull_consumer(
    js: JetStreamContext,
    batch_size: int,
    shutdown_event: asyncio.Event,
) -> None:
    """
    Pull-based consumer that fetches messages in batches.

    Pull consumers give the application explicit control over consumption
    rate and are ideal for worker-pool patterns.
    """
    # Create a durable pull subscription
    psub = await js.pull_subscribe(
        "orders.>",
        durable="order-processor",
        config=ConsumerConfig(
            ack_policy=AckPolicy.EXPLICIT,
            max_ack_pending=128,
            deliver_policy=DeliverPolicy.ALL,
        ),
    )
    logger.info("[Pull] Consumer 'order-processor' started")

    while not shutdown_event.is_set():
        try:
            msgs = await psub.fetch(batch=batch_size, timeout=2)
            for msg in msgs:
                logger.info(
                    "[Pull] Received: subject=%s data=%s",
                    msg.subject, msg.data.decode(),
                )
                # Process message…
                await msg.ack()
        except NATSTimeoutError:
            # Normal when the stream is idle
            continue
        except Exception as exc:
            logger.error("[Pull] Error: %s", exc)
            await asyncio.sleep(1)

    logger.info("[Pull] Shutting down")


# ─── Push consumer — queue group ──────────────────────────────────────────────
async def push_consumer(
    js: JetStreamContext,
    shutdown_event: asyncio.Event,
) -> None:
    """
    Push-based consumer with a queue group for load balancing.

    Queue groups ensure each message is delivered to exactly one member,
    enabling horizontal scaling.
    """

    async def message_handler(msg: Msg) -> None:
        logger.info(
            "[Push] Received: subject=%s data=%s",
            msg.subject, msg.data.decode(),
        )
        # Inspect headers
        if msg.headers and (src := msg.headers.get("X-Source")):
            logger.info("[Push]   Source: %s", src)

        await msg.ack()

    sub = await js.subscribe(
        "orders.>",
        queue="order-workers",
        durable="order-push-worker",
        cb=message_handler,
        config=ConsumerConfig(
            ack_policy=AckPolicy.EXPLICIT,
            deliver_policy=DeliverPolicy.ALL,
            max_ack_pending=64,
        ),
    )
    logger.info("[Push] Consumer 'order-push-worker' started (queue: order-workers)")

    # Wait until shutdown is requested
    await shutdown_event.wait()

    await sub.unsubscribe()
    logger.info("[Push] Shutting down")


# ─── Key/Value store ──────────────────────────────────────────────────────────
async def kv_store_demo(js: JetStreamContext) -> None:
    """Demonstrate NATS JetStream Key/Value store operations."""

    # Create (or bind to) a KV bucket
    kv: KeyValue = await js.create_key_value(
        config=nats.js.api.KeyValueConfig(
            bucket="app-config",
            description="Application configuration",
            history=5,  # Keep last 5 revisions per key
            ttl=0,  # No automatic expiry
            storage=StorageType.FILE,
            num_replicas=1,
        ),
    )
    logger.info("[KV] Bucket 'app-config' ready")

    # ── Put ───────────────────────────────────────────────────────────────
    rev = await kv.put("feature.dark-mode", b"enabled")
    logger.info("[KV] Put feature.dark-mode = enabled (revision %d)", rev)

    # ── Get ───────────────────────────────────────────────────────────────
    entry = await kv.get("feature.dark-mode")
    logger.info(
        "[KV] Get feature.dark-mode = %s (revision %d)",
        entry.value.decode(), entry.revision,
    )

    # ── Update (optimistic concurrency via revision) ──────────────────────
    new_rev = await kv.update("feature.dark-mode", b"disabled", last=entry.revision)
    logger.info("[KV] Updated feature.dark-mode = disabled (revision %d)", new_rev)

    # ── List keys ─────────────────────────────────────────────────────────
    keys = await kv.keys()
    logger.info("[KV] Keys in bucket: %s", keys)

    # ── Delete ────────────────────────────────────────────────────────────
    await kv.delete("feature.dark-mode")
    logger.info("[KV] Deleted feature.dark-mode")


# ─── Request / Reply ─────────────────────────────────────────────────────────
async def request_reply_demo(nc: NATSClient) -> None:
    """Demonstrate the request/reply (RPC) pattern."""

    # ── Responder ─────────────────────────────────────────────────────────
    async def echo_handler(msg: Msg) -> None:
        reply = f"ECHO: {msg.data.decode()}"
        await msg.respond(reply.encode())

    sub = await nc.subscribe("service.echo", cb=echo_handler)

    # ── Requester ─────────────────────────────────────────────────────────
    try:
        reply = await nc.request("service.echo", b"hello from Python", timeout=5)
        logger.info("[ReqRep] Reply: %s", reply.data.decode())
    except NATSTimeoutError:
        logger.error("[ReqRep] Request timed out")
    finally:
        await sub.unsubscribe()


# ─── Main ─────────────────────────────────────────────────────────────────────
async def main() -> None:
    cfg = Config()

    # ── Shutdown coordination ─────────────────────────────────────────────
    shutdown_event = asyncio.Event()

    def handle_signal(sig: int) -> None:
        logger.info("Received signal %s — shutting down gracefully…", signal.Signals(sig).name)
        shutdown_event.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, handle_signal, sig)

    # ── Connect ───────────────────────────────────────────────────────────
    try:
        nc = await connect(cfg)
    except (ConnectionClosedError, NoServersError) as exc:
        logger.fatal("Cannot connect to NATS: %s", exc)
        sys.exit(1)

    try:
        js = nc.jetstream()

        # Create stream
        await ensure_stream(js)

        # KV store demo
        try:
            await kv_store_demo(js)
        except Exception as exc:
            logger.warning("KV demo error (non-fatal): %s", exc)

        # Request/reply demo
        try:
            await request_reply_demo(nc)
        except Exception as exc:
            logger.warning("Request/reply demo error (non-fatal): %s", exc)

        # Start push and pull consumers concurrently
        consumer_tasks = [
            asyncio.create_task(push_consumer(js, shutdown_event)),
            asyncio.create_task(pull_consumer(js, cfg.batch_size, shutdown_event)),
        ]

        # Publish messages
        await publish_messages(js, cfg.publish_count, shutdown_event)

        # Wait for shutdown signal or demo timeout
        try:
            await asyncio.wait_for(shutdown_event.wait(), timeout=15)
        except asyncio.TimeoutError:
            logger.info("Demo timeout reached — shutting down")
            shutdown_event.set()

        # Wait for consumers to finish
        await asyncio.gather(*consumer_tasks, return_exceptions=True)

    finally:
        # Drain ensures in-flight messages are processed before closing
        await nc.drain()
        logger.info("NATS connection drained and closed")

    logger.info("All demos complete")


if __name__ == "__main__":
    asyncio.run(main())
