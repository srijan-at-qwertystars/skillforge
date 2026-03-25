# sentry_python_config.py — Python Sentry initialization template
#
# Supports Django, Flask, FastAPI, Celery, and standalone Python apps.
#
# Usage:
#   1. Copy this file to your project
#   2. Import and call init_sentry() at application startup
#   3. Set SENTRY_DSN environment variable
#
# Required packages:
#   pip install sentry-sdk
#
# Environment variables:
#   SENTRY_DSN             — Project DSN (required)
#   SENTRY_ENVIRONMENT     — Environment name (default: "development")
#   SENTRY_RELEASE         — Release version (default: auto-detect)
#   SENTRY_TRACES_RATE     — Trace sample rate (default: "0.2")
#   SENTRY_PROFILES_RATE   — Profile sample rate (default: "0.1")
#   SENTRY_SEND_PII        — Send PII like user IPs (default: "false")

import os
import logging

import sentry_sdk
from sentry_sdk.types import Event, Hint

logger = logging.getLogger(__name__)


# --- Event Filtering ---

# Errors to silently drop (non-actionable)
IGNORED_EXCEPTIONS = (
    KeyboardInterrupt,
    SystemExit,
)

# Loggers whose errors should not be reported
IGNORED_LOGGERS = [
    "django.security.DisallowedHost",
    "django.request",  # 404s etc. — usually noise
]


def before_send(event: Event, hint: Hint) -> Event | None:
    """Filter and modify error events before sending to Sentry."""
    # Drop ignored exceptions
    if "exc_info" in hint:
        exc_type = hint["exc_info"][0]
        if exc_type and issubclass(exc_type, IGNORED_EXCEPTIONS):
            return None

    # Drop ignored logger events
    if event.get("logger") in IGNORED_LOGGERS:
        return None

    # Scrub sensitive data from request
    request = event.get("request", {})
    if "cookies" in request:
        request["cookies"] = "[REDACTED]"
    headers = request.get("headers", {})
    for sensitive_header in ("authorization", "cookie", "x-api-key"):
        if sensitive_header in headers:
            headers[sensitive_header] = "[REDACTED]"

    return event


def before_send_transaction(event: Event, hint: Hint) -> Event | None:
    """Filter and modify transaction events before sending."""
    transaction_name = event.get("transaction", "")

    # Drop health check and static file transactions
    if any(
        pattern in transaction_name
        for pattern in ("/health", "/ready", "/live", "/favicon", "/static/")
    ):
        return None

    return event


def traces_sampler(sampling_context: dict) -> float:
    """Dynamic trace sampling based on endpoint."""
    transaction_name = sampling_context.get("transaction_context", {}).get("name", "")

    # Parent sampling decision takes precedence (distributed tracing)
    parent_sampled = sampling_context.get("parent_sampled")
    if parent_sampled is not None:
        return float(parent_sampled)

    # Always trace critical paths
    if any(path in transaction_name for path in ("/payment", "/checkout", "/auth")):
        return 1.0

    # Reduce sampling for high-volume endpoints
    if "/search" in transaction_name or "/feed" in transaction_name:
        return 0.01

    # Default sample rate
    return float(os.environ.get("SENTRY_TRACES_RATE", "0.2"))


# --- Initialization ---

def init_sentry(
    dsn: str | None = None,
    framework: str = "auto",
    **extra_options,
) -> None:
    """
    Initialize Sentry SDK with production-ready defaults.

    Args:
        dsn: Sentry DSN. Falls back to SENTRY_DSN env var.
        framework: One of "auto", "django", "flask", "fastapi", "celery", "generic".
        **extra_options: Additional kwargs passed to sentry_sdk.init().
    """
    dsn = dsn or os.environ.get("SENTRY_DSN")
    if not dsn:
        logger.warning("SENTRY_DSN not set — Sentry is disabled.")
        return

    environment = os.environ.get("SENTRY_ENVIRONMENT", "development")
    release = os.environ.get("SENTRY_RELEASE")
    send_pii = os.environ.get("SENTRY_SEND_PII", "false").lower() == "true"
    profiles_rate = float(os.environ.get("SENTRY_PROFILES_RATE", "0.1"))

    # Auto-detect framework integrations
    integrations = _detect_integrations(framework)

    sentry_sdk.init(
        dsn=dsn,
        environment=environment,
        release=release,
        send_default_pii=send_pii,
        traces_sampler=traces_sampler,
        profiles_sample_rate=profiles_rate,
        before_send=before_send,
        before_send_transaction=before_send_transaction,
        integrations=integrations,
        # Enable automatic session tracking
        auto_session_tracking=True,
        # Max breadcrumbs to keep per event
        max_breadcrumbs=50,
        # Attach server name for multi-server deployments
        server_name=os.environ.get("HOSTNAME"),
        # Additional options
        **extra_options,
    )

    logger.info(
        "Sentry initialized: env=%s release=%s",
        environment,
        release or "(auto)",
    )


def _detect_integrations(framework: str) -> list:
    """Detect and return appropriate Sentry integrations."""
    integrations = []

    if framework == "auto":
        # Auto-detect: Sentry SDK detects installed frameworks automatically.
        # Return empty list — SDK handles it.
        return integrations

    if framework == "django":
        try:
            from sentry_sdk.integrations.django import DjangoIntegration

            integrations.append(DjangoIntegration(
                transaction_style="url",  # Use URL pattern names
                middleware_spans=True,
            ))
        except ImportError:
            logger.warning("Django not installed — skipping DjangoIntegration")

    elif framework == "flask":
        try:
            from sentry_sdk.integrations.flask import FlaskIntegration

            integrations.append(FlaskIntegration(
                transaction_style="url",
            ))
        except ImportError:
            logger.warning("Flask not installed — skipping FlaskIntegration")

    elif framework == "fastapi":
        try:
            from sentry_sdk.integrations.fastapi import FastApiIntegration
            from sentry_sdk.integrations.starlette import StarletteIntegration

            integrations.append(FastApiIntegration(transaction_style="url"))
            integrations.append(StarletteIntegration(transaction_style="url"))
        except ImportError:
            logger.warning("FastAPI not installed — skipping FastApiIntegration")

    elif framework == "celery":
        try:
            from sentry_sdk.integrations.celery import CeleryIntegration

            integrations.append(CeleryIntegration(
                monitor_beat_tasks=True,
                propagate_traces=True,
            ))
        except ImportError:
            logger.warning("Celery not installed — skipping CeleryIntegration")

    # Always try to add common integrations
    _add_optional_integration(integrations, "logging", "LoggingIntegration",
                              level=logging.INFO, event_level=logging.ERROR)
    _add_optional_integration(integrations, "redis", "RedisIntegration")
    _add_optional_integration(integrations, "sqlalchemy", "SqlalchemyIntegration")

    return integrations


def _add_optional_integration(integrations: list, module: str, class_name: str, **kwargs):
    """Try to add an optional integration, skip if not available."""
    try:
        mod = __import__(f"sentry_sdk.integrations.{module}", fromlist=[class_name])
        cls = getattr(mod, class_name)
        integrations.append(cls(**kwargs))
    except (ImportError, AttributeError):
        pass


# --- Utility Functions ---

def set_user_context(user_id: str, email: str | None = None, **extra):
    """Set user context for all subsequent Sentry events."""
    user_data = {"id": user_id}
    if email:
        user_data["email"] = email
    user_data.update(extra)
    sentry_sdk.set_user(user_data)


def set_tenant_context(tenant_id: str, tenant_name: str | None = None):
    """Set multi-tenant context for issue grouping and filtering."""
    sentry_sdk.set_tag("tenant_id", tenant_id)
    if tenant_name:
        sentry_sdk.set_tag("tenant_name", tenant_name)
    sentry_sdk.set_context("tenant", {
        "id": tenant_id,
        "name": tenant_name,
    })


# --- Django Settings Integration ---
# Add to your Django settings.py:
#
#   # At the TOP of settings.py, before other imports:
#   from sentry_config import init_sentry
#   init_sentry(framework="django")
#
# --- Flask Integration ---
# Add to your Flask app factory:
#
#   from sentry_config import init_sentry
#   init_sentry(framework="flask")
#   app = Flask(__name__)
#
# --- FastAPI Integration ---
# Add to your main.py, before creating the app:
#
#   from sentry_config import init_sentry
#   init_sentry(framework="fastapi")
#   app = FastAPI()
#
# --- Celery Integration ---
# Add to your celery.py:
#
#   from sentry_config import init_sentry
#   init_sentry(framework="celery")
#   app = Celery("myapp")


if __name__ == "__main__":
    # Quick test: initialize and send a test event
    init_sentry()
    sentry_sdk.capture_message("Sentry Python test event — everything is working!")
    print("Test event sent to Sentry. Check your dashboard.")
