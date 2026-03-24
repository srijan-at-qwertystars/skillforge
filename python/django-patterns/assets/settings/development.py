"""
Development settings — extends base with debugging tools and relaxed security.
"""
from .base import *  # noqa: F401,F403
from .base import INSTALLED_APPS, MIDDLEWARE

DEBUG = True

# --- Apps ---
INSTALLED_APPS += [
    "debug_toolbar",
    "django_extensions",
]

# --- Middleware ---
MIDDLEWARE.insert(0, "debug_toolbar.middleware.DebugToolbarMiddleware")

# --- Debug Toolbar ---
INTERNAL_IPS = ["127.0.0.1", "localhost"]

# --- CORS ---
CORS_ALLOW_ALL_ORIGINS = True

# --- Email ---
EMAIL_BACKEND = "django.core.mail.backends.console.EmailBackend"

# --- Auth ---
AUTH_PASSWORD_VALIDATORS = []  # Relaxed for development

# --- Logging ---
LOGGING["loggers"]["django.db.backends"] = {  # noqa: F405
    "handlers": ["console"],
    "level": "WARNING",  # Set to DEBUG to see all SQL queries
    "propagate": False,
}
