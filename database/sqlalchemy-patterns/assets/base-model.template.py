"""
Base model template with common mixins for SQLAlchemy 2.0.

Usage:
    Copy this file to your project and import Base for all models.
    Customize mixins as needed for your domain.

Example:
    from .base import Base, TimestampMixin, SoftDeleteMixin

    class User(TimestampMixin, SoftDeleteMixin, Base):
        __tablename__ = "users"
        id: Mapped[int] = mapped_column(primary_key=True)
        name: Mapped[str] = mapped_column(String(100))
"""

from datetime import datetime
from typing import Annotated, Any

from sqlalchemy import DateTime, String, Text, event, func, inspect
from sqlalchemy.ext.hybrid import hybrid_property
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column


# ---------------------------------------------------------------------------
# Reusable annotated types
# ---------------------------------------------------------------------------
intpk = Annotated[int, mapped_column(primary_key=True)]
str50 = Annotated[str, mapped_column(String(50))]
str100 = Annotated[str, mapped_column(String(100))]
str255 = Annotated[str, mapped_column(String(255))]
created_ts = Annotated[
    datetime, mapped_column(DateTime(timezone=True), server_default=func.now())
]
updated_ts = Annotated[
    datetime,
    mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    ),
]


# ---------------------------------------------------------------------------
# Base class
# ---------------------------------------------------------------------------
class Base(DeclarativeBase):
    """Base class for all ORM models.

    Provides:
    - Automatic __repr__ with primary key columns
    - to_dict() serialization helper
    """

    def __repr__(self) -> str:
        mapper = inspect(self.__class__)
        pk_cols = [col.key for col in mapper.primary_key]
        pk_vals = ", ".join(f"{col}={getattr(self, col, '?')}" for col in pk_cols)
        return f"<{self.__class__.__name__}({pk_vals})>"

    def to_dict(self, exclude: set[str] | None = None) -> dict[str, Any]:
        """Serialize model to dict. Excludes relationships by default."""
        exclude = exclude or set()
        mapper = inspect(self.__class__)
        return {
            col.key: getattr(self, col.key)
            for col in mapper.column_attrs
            if col.key not in exclude
        }


# ---------------------------------------------------------------------------
# Timestamp mixin
# ---------------------------------------------------------------------------
class TimestampMixin:
    """Adds created_at and updated_at columns."""

    created_at: Mapped[created_ts]
    updated_at: Mapped[updated_ts]


# ---------------------------------------------------------------------------
# Soft delete mixin
# ---------------------------------------------------------------------------
class SoftDeleteMixin:
    """Adds soft delete support.

    - soft_delete() / restore() to toggle
    - is_deleted hybrid property for Python and SQL filtering
    - Pair with do_orm_execute event for auto-filtering (see below)
    """

    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    @hybrid_property
    def is_deleted(self) -> bool:
        return self.deleted_at is not None

    @is_deleted.expression
    @classmethod
    def is_deleted(cls):
        return cls.deleted_at.isnot(None)

    def soft_delete(self) -> None:
        self.deleted_at = func.now()

    def restore(self) -> None:
        self.deleted_at = None


# ---------------------------------------------------------------------------
# Auto-filter soft-deleted rows (opt-in)
#
# Enable by uncommenting the event listener below. After enabling, all SELECT
# queries on models with SoftDeleteMixin will automatically exclude deleted
# rows unless you pass execution_options(include_deleted=True).
# ---------------------------------------------------------------------------
# from sqlalchemy.orm import with_loader_criteria
#
# @event.listens_for(Session, "do_orm_execute")
# def _soft_delete_filter(execute_state):
#     if (
#         execute_state.is_select
#         and not execute_state.is_column_load
#         and not execute_state.is_relationship_load
#         and not execute_state.execution_options.get("include_deleted", False)
#     ):
#         execute_state.statement = execute_state.statement.options(
#             with_loader_criteria(
#                 SoftDeleteMixin,
#                 lambda cls: cls.deleted_at.is_(None),
#                 include_aliases=True,
#             )
#         )


# ---------------------------------------------------------------------------
# Example model using all mixins
# ---------------------------------------------------------------------------
# class User(TimestampMixin, SoftDeleteMixin, Base):
#     __tablename__ = "users"
#
#     id: Mapped[intpk]
#     name: Mapped[str100]
#     email: Mapped[str255] = mapped_column(unique=True, index=True)
#     bio: Mapped[str | None] = mapped_column(Text)
