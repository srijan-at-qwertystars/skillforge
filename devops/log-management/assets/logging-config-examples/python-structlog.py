"""
Python Logging Configuration — structlog

Production-ready structured logging with:
  - JSON output with consistent schema
  - PII redaction processor
  - Request context via contextvars (async-safe)
  - Human-readable output in development
  - OpenTelemetry trace context injection

Install: pip install structlog

Usage:
    from python_structlog import get_logger, bind_request_context
    logger = get_logger()
    logger.info("user_logged_in", user_id="123")
"""

import logging
import os
import re
import sys
from contextvars import ContextVar
from uuid import uuid4

import structlog

# ---- Context Variables (async-safe) ----
request_id_var: ContextVar[str] = ContextVar("request_id", default="")
trace_id_var: ContextVar[str] = ContextVar("trace_id", default="")
span_id_var: ContextVar[str] = ContextVar("span_id", default="")
user_id_var: ContextVar[str] = ContextVar("user_id", default="")
tenant_id_var: ContextVar[str] = ContextVar("tenant_id", default="")

# ---- Processors ----

def add_service_context(logger, method_name, event_dict):
    """Add service metadata to every log entry."""
    event_dict.setdefault("service", os.environ.get("SERVICE_NAME", "app"))
    event_dict.setdefault("environment", os.environ.get("ENVIRONMENT", "development"))
    event_dict.setdefault("version", os.environ.get("APP_VERSION", "0.0.0"))
    return event_dict


def add_request_context(logger, method_name, event_dict):
    """Inject request context from contextvars."""
    for var, key in [
        (request_id_var, "request_id"),
        (trace_id_var, "trace_id"),
        (span_id_var, "span_id"),
        (user_id_var, "user_id"),
        (tenant_id_var, "tenant_id"),
    ]:
        val = var.get()
        if val:
            event_dict[key] = val
    return event_dict


# Patterns for PII detection
_PII_PATTERNS = {
    "email": re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z]{2,}\b", re.I),
    "ssn": re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
    "credit_card": re.compile(r"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"),
}

_REDACT_KEYS = {"password", "secret", "token", "authorization", "cookie", "ssn", "credit_card"}


def redact_pii(logger, method_name, event_dict):
    """Redact sensitive fields and PII patterns."""
    for key in list(event_dict.keys()):
        if key.lower() in _REDACT_KEYS:
            event_dict[key] = "[REDACTED]"
        elif isinstance(event_dict[key], str):
            for pattern_name, pattern in _PII_PATTERNS.items():
                event_dict[key] = pattern.sub(f"[{pattern_name.upper()}_REDACTED]", event_dict[key])
    return event_dict


def add_otel_context(logger, method_name, event_dict):
    """Inject OpenTelemetry trace context if available."""
    try:
        from opentelemetry import trace
        span = trace.get_current_span()
        ctx = span.get_span_context()
        if ctx and ctx.is_valid:
            event_dict["trace_id"] = format(ctx.trace_id, "032x")
            event_dict["span_id"] = format(ctx.span_id, "016x")
            event_dict["trace_flags"] = ctx.trace_flags
    except ImportError:
        pass
    return event_dict


# ---- Configuration ----

def configure_logging(level: str = "INFO", json_output: bool | None = None):
    """Configure structlog for the application.

    Args:
        level: Log level (DEBUG, INFO, WARNING, ERROR)
        json_output: Force JSON (True), console (False), or auto-detect (None)
    """
    if json_output is None:
        json_output = os.environ.get("ENVIRONMENT", "development") != "development"

    shared_processors = [
        structlog.contextvars.merge_contextvars,
        add_service_context,
        add_request_context,
        add_otel_context,
        redact_pii,
        structlog.stdlib.add_log_level,
        structlog.stdlib.add_logger_name,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.UnicodeDecoder(),
    ]

    if json_output:
        renderer = structlog.processors.JSONRenderer()
    else:
        renderer = structlog.dev.ConsoleRenderer(colors=True)

    structlog.configure(
        processors=[
            *shared_processors,
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )

    formatter = structlog.stdlib.ProcessorFormatter(
        processors=[
            structlog.stdlib.ProcessorFormatter.remove_processors_meta,
            renderer,
        ],
    )

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(formatter)

    root_logger = logging.getLogger()
    root_logger.handlers.clear()
    root_logger.addHandler(handler)
    root_logger.setLevel(getattr(logging, level.upper()))


def get_logger(name: str | None = None) -> structlog.stdlib.BoundLogger:
    """Get a structured logger instance."""
    return structlog.get_logger(name)


def bind_request_context(
    request_id: str | None = None,
    trace_id: str = "",
    user_id: str = "",
    tenant_id: str = "",
):
    """Bind request context for the current async context.

    Call in middleware at request start.
    """
    request_id_var.set(request_id or str(uuid4()))
    trace_id_var.set(trace_id)
    user_id_var.set(user_id)
    tenant_id_var.set(tenant_id)


# ---- Auto-configure on import ----
configure_logging(
    level=os.environ.get("LOG_LEVEL", "INFO"),
)


# ---- Usage Examples ----
# FastAPI middleware:
#
# @app.middleware("http")
# async def logging_middleware(request, call_next):
#     bind_request_context(
#         request_id=request.headers.get("X-Request-ID"),
#         trace_id=request.headers.get("X-Trace-ID", ""),
#         tenant_id=request.headers.get("X-Tenant-ID", ""),
#     )
#     logger = get_logger("http")
#     start = time.monotonic()
#     response = await call_next(request)
#     duration_ms = (time.monotonic() - start) * 1000
#     logger.info("request_completed",
#         method=request.method,
#         path=request.url.path,
#         status=response.status_code,
#         duration_ms=round(duration_ms, 2),
#     )
#     return response
