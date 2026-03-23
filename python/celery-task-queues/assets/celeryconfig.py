"""
Production-ready Celery configuration template.

Copy this file to your project and adjust values for your environment.
All important settings are included with explanatory comments.

Usage:
    # In your celery.py:
    app.config_from_object("myproject.celeryconfig")

    # Or with environment variable overrides:
    import os
    broker_url = os.environ.get("CELERY_BROKER_URL", "redis://localhost:6379/0")
"""

import os

# =============================================================================
# BROKER (Message Transport)
# =============================================================================

# Redis: redis://host:port/db  |  rediss:// for TLS
# RabbitMQ: amqp://user:pass@host:port/vhost
# SQS: sqs://aws_access_key:aws_secret_key@
broker_url = os.environ.get("CELERY_BROKER_URL", "redis://localhost:6379/0")

# Connection pool size per worker (default: 10)
# Set higher for high-throughput workers
broker_pool_limit = 10

# Broker connection retry on startup (Celery 5.3+)
broker_connection_retry_on_startup = True

# Heartbeat interval for detecting dead connections (seconds)
# Set to 0 to disable (not recommended)
broker_heartbeat = 10

# Connection timeout (seconds)
broker_connection_timeout = 30

# Redis-specific transport options
broker_transport_options = {
    "visibility_timeout": 3600,    # 1 hour; increase for long-running tasks
    "socket_timeout": 5,
    "socket_connect_timeout": 5,
    "retry_on_timeout": True,
}

# =============================================================================
# RESULT BACKEND
# =============================================================================

# Use a SEPARATE Redis DB/instance from the broker
result_backend = os.environ.get("CELERY_RESULT_BACKEND", "redis://localhost:6379/1")

# How long to keep results before they expire (seconds)
# Set to None to keep forever (not recommended — causes memory bloat)
result_expires = 3600  # 1 hour

# Compress results to save memory (zlib, bzip2, gzip, or None)
# result_compression = "gzip"

# =============================================================================
# SERIALIZATION
# =============================================================================

# JSON is safe and interoperable. NEVER use pickle in production
# unless all producers/consumers are fully trusted.
task_serializer = "json"
result_serializer = "json"
accept_content = ["json"]

# If using custom types, register a custom serializer:
# accept_content = ["json", "msgpack"]

# =============================================================================
# TIMEZONE
# =============================================================================

timezone = "UTC"
enable_utc = True

# =============================================================================
# TASK EXECUTION
# =============================================================================

# Acknowledge AFTER task completes (enables redelivery on crash)
# Only safe for idempotent tasks!
task_acks_late = True

# Requeue task if worker is lost (killed, OOM) — requires task_acks_late=True
task_reject_on_worker_lost = True

# Hard time limit: SIGKILL after this many seconds (no cleanup possible)
task_time_limit = 300  # 5 minutes

# Soft time limit: raises SoftTimeLimitExceeded (allows graceful cleanup)
task_soft_time_limit = 240  # 4 minutes

# Track STARTED state (useful for monitoring, costs a backend write per task)
task_track_started = True

# Globally ignore results unless task explicitly sets ignore_result=False
# Enable if most tasks don't need results — reduces backend load
# task_ignore_result = True

# =============================================================================
# WORKER
# =============================================================================

# Number of concurrent worker processes/threads
# CPU-bound: set to CPU core count
# I/O-bound: set to 2-4x CPU cores
# gevent/eventlet: set to 100-1000
worker_concurrency = 8

# Prefetch multiplier: how many messages each worker prefetches
# 1 = fair scheduling (best for long/variable tasks)
# 4-8 = higher throughput for short uniform tasks
worker_prefetch_multiplier = 1

# Recycle worker processes after N tasks (prevents memory leaks)
worker_max_tasks_per_child = 200

# Recycle when resident memory exceeds this (KB) — prefork pool only
worker_max_memory_per_child = 200000  # ~200 MB

# Send task-related events for monitoring (Flower, custom monitors)
worker_send_task_events = True

# Rate of event sending (don't flood the broker)
worker_task_log_format = "[%(asctime)s: %(levelname)s/%(processName)s] %(message)s"

# =============================================================================
# TASK ROUTING
# =============================================================================

# Define queues
# from kombu import Queue
# task_queues = (
#     Queue("default"),
#     Queue("high_priority"),
#     Queue("email"),
#     Queue("reports"),
# )

# Default queue for tasks without explicit routing
task_default_queue = "default"

# Route tasks to specific queues
# task_routes = {
#     "myapp.tasks.send_email": {"queue": "email"},
#     "myapp.tasks.generate_report": {"queue": "reports"},
#     "myapp.tasks.process_payment": {"queue": "high_priority"},
#     "myapp.tasks.*": {"queue": "default"},
# }

# =============================================================================
# PERIODIC TASKS (Celery Beat)
# =============================================================================

# Static schedule — define periodic tasks here
# from celery.schedules import crontab
# beat_schedule = {
#     "cleanup-every-night": {
#         "task": "myapp.tasks.cleanup_old_records",
#         "schedule": crontab(hour=3, minute=0),
#         "args": (90,),
#     },
#     "health-check-every-5-min": {
#         "task": "myapp.tasks.health_check",
#         "schedule": 300.0,
#     },
# }

# For Django: use DatabaseScheduler for admin-managed schedules
# beat_scheduler = "django_celery_beat.schedulers:DatabaseScheduler"

# =============================================================================
# SECURITY
# =============================================================================

# Restrict worker to only execute tasks from known modules
# worker_hijack_root_logger = False
# imports = ("myapp.tasks",)

# Content security — restrict accepted content types
# content_type_whitelist = ["json"]

# Message signing (requires cryptography package)
# security_key = "/path/to/private.key"
# security_certificate = "/path/to/cert.pem"
# security_cert_store = "/path/to/certs/"

# =============================================================================
# LOGGING
# =============================================================================

# Don't hijack root logger — lets you configure your own logging
# worker_hijack_root_logger = False

# Log format
worker_log_format = "[%(asctime)s: %(levelname)s/%(processName)s] %(message)s"
worker_task_log_format = "[%(asctime)s: %(levelname)s/%(processName)s][%(task_name)s(%(task_id)s)] %(message)s"
