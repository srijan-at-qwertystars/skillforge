"""
Base model template for SQLAlchemy 2.0 projects.

Provides: auto-incrementing id, created_at, updated_at timestamps,
soft delete support, and a useful __repr__.

Usage:
    from myapp.models.base import Base, SoftDeleteMixin

    class User(Base):
        __tablename__ = "users"
        name: Mapped[str] = mapped_column(String(100))

    class Post(SoftDeleteMixin, Base):
        __tablename__ = "posts"
        title: Mapped[str] = mapped_column(String(200))
"""

from datetime import datetime
from typing import Any, Optional

from sqlalchemy import MetaData, String, func, event
from sqlalchemy.orm import (
    DeclarativeBase,
    Mapped,
    Session,
    mapped_column,
)

# Deterministic constraint names — required for Alembic batch mode (SQLite)
# and to avoid migration churn across environments.
NAMING_CONVENTION: dict[str, str] = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    """Abstract base for all models."""

    metadata = MetaData(naming_convention=NAMING_CONVENTION)

    # Common columns on every table
    id: Mapped[int] = mapped_column(primary_key=True)
    created_at: Mapped[datetime] = mapped_column(
        server_default=func.now(),
        default=None,  # let the DB set it
    )
    updated_at: Mapped[datetime] = mapped_column(
        server_default=func.now(),
        onupdate=func.now(),
        default=None,
    )

    def __repr__(self) -> str:
        pk_cols = [c.name for c in self.__table__.primary_key.columns]
        pk_vals = ", ".join(f"{c}={getattr(self, c, '?')}" for c in pk_cols)
        return f"<{self.__class__.__name__}({pk_vals})>"


class SoftDeleteMixin:
    """Mixin that adds soft delete columns and helper methods.

    Apply BEFORE Base in MRO:
        class Post(SoftDeleteMixin, Base): ...

    Auto-filtering: register the event listener below to exclude
    soft-deleted rows from all ORM SELECT queries by default.
    """

    deleted_at: Mapped[Optional[datetime]] = mapped_column(default=None, index=True)
    is_deleted: Mapped[bool] = mapped_column(default=False, index=True)

    def soft_delete(self) -> None:
        self.is_deleted = True
        self.deleted_at = datetime.utcnow()

    def restore(self) -> None:
        self.is_deleted = False
        self.deleted_at = None


def register_soft_delete_filter(session_class: type = Session) -> None:
    """Register an ORM event that auto-filters soft-deleted rows.

    Call once at app startup:
        register_soft_delete_filter()

    To include deleted rows in a specific query:
        stmt = select(Post).execution_options(include_deleted=True)
    """
    from sqlalchemy.orm import with_loader_criteria

    @event.listens_for(session_class, "do_orm_execute")
    def _exclude_soft_deleted(execute_state: Any) -> None:
        if (
            execute_state.is_select
            and not execute_state.execution_options.get("include_deleted", False)
        ):
            execute_state.statement = execute_state.statement.options(
                with_loader_criteria(
                    SoftDeleteMixin,
                    lambda cls: cls.is_deleted == False,  # noqa: E712
                    include_aliases=True,
                )
            )
