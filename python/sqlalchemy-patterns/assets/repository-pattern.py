"""
Generic repository pattern for SQLAlchemy 2.0.

Provides CRUD, pagination, and dynamic filtering for any model.

Usage:
    from myapp.repositories.base import BaseRepository

    class UserRepository(BaseRepository[User]):
        pass

    async with AsyncSessionLocal() as session:
        repo = UserRepository(session, User)
        user = await repo.get(1)
        users = await repo.paginate(page=2, per_page=20, filters={"is_active": True})
"""

from typing import Any, Generic, TypeVar, Sequence

from sqlalchemy import Select, func, select, and_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import (
    DeclarativeBase,
    InstrumentedAttribute,
    selectinload,
)

T = TypeVar("T", bound=DeclarativeBase)


class BaseRepository(Generic[T]):
    """Async repository with CRUD, pagination, and filtering."""

    def __init__(self, session: AsyncSession, model: type[T]) -> None:
        self.session = session
        self.model = model

    # ---- Read ----

    async def get(self, id: int) -> T | None:
        """Get a single record by primary key."""
        return await self.session.get(self.model, id)

    async def get_or_raise(self, id: int) -> T:
        """Get by primary key or raise ValueError."""
        obj = await self.session.get(self.model, id)
        if obj is None:
            raise ValueError(f"{self.model.__name__} with id={id} not found")
        return obj

    async def get_by(self, **kwargs: Any) -> T | None:
        """Get a single record matching the given column values."""
        stmt = select(self.model).filter_by(**kwargs)
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def list(
        self,
        *,
        filters: dict[str, Any] | None = None,
        order_by: str | None = None,
        descending: bool = False,
        limit: int | None = None,
        load: list[InstrumentedAttribute] | None = None,
    ) -> Sequence[T]:
        """List records with optional filtering, ordering, and eager loading."""
        stmt = self._apply_filters(select(self.model), filters)
        stmt = self._apply_ordering(stmt, order_by, descending)
        if load:
            stmt = stmt.options(*[selectinload(rel) for rel in load])
        if limit:
            stmt = stmt.limit(limit)
        result = await self.session.scalars(stmt)
        return result.all()

    async def paginate(
        self,
        *,
        page: int = 1,
        per_page: int = 20,
        filters: dict[str, Any] | None = None,
        order_by: str | None = None,
        descending: bool = False,
    ) -> "PaginatedResult[T]":
        """Paginate records. Returns items, total count, and page metadata."""
        base_stmt = self._apply_filters(select(self.model), filters)

        # Count total
        count_stmt = select(func.count()).select_from(base_stmt.subquery())
        total = (await self.session.execute(count_stmt)).scalar_one()

        # Fetch page
        stmt = self._apply_ordering(base_stmt, order_by, descending)
        stmt = stmt.offset((page - 1) * per_page).limit(per_page)
        result = await self.session.scalars(stmt)
        items = result.all()

        return PaginatedResult(
            items=items,
            total=total,
            page=page,
            per_page=per_page,
            pages=(total + per_page - 1) // per_page,
        )

    async def count(self, filters: dict[str, Any] | None = None) -> int:
        """Count records matching filters."""
        stmt = self._apply_filters(select(func.count(self.model.id)), filters)
        result = await self.session.execute(stmt)
        return result.scalar_one()

    async def exists(self, **kwargs: Any) -> bool:
        """Check if a record matching the given values exists."""
        stmt = select(func.count()).select_from(
            select(self.model).filter_by(**kwargs).subquery()
        )
        result = await self.session.execute(stmt)
        return result.scalar_one() > 0

    # ---- Write ----

    async def create(self, **kwargs: Any) -> T:
        """Create and return a new record."""
        obj = self.model(**kwargs)
        self.session.add(obj)
        await self.session.flush()
        await self.session.refresh(obj)
        return obj

    async def create_many(self, items: list[dict[str, Any]]) -> list[T]:
        """Create multiple records."""
        objects = [self.model(**data) for data in items]
        self.session.add_all(objects)
        await self.session.flush()
        return objects

    async def update(self, id: int, **kwargs: Any) -> T:
        """Update a record by primary key."""
        obj = await self.get_or_raise(id)
        for key, value in kwargs.items():
            setattr(obj, key, value)
        await self.session.flush()
        await self.session.refresh(obj)
        return obj

    async def delete(self, id: int) -> None:
        """Hard delete a record by primary key."""
        obj = await self.get_or_raise(id)
        await self.session.delete(obj)
        await self.session.flush()

    async def soft_delete(self, id: int) -> T:
        """Soft delete a record (requires SoftDeleteMixin on model)."""
        obj = await self.get_or_raise(id)
        obj.soft_delete()  # type: ignore[attr-defined]
        await self.session.flush()
        return obj

    # ---- Internal ----

    def _apply_filters(
        self, stmt: Select, filters: dict[str, Any] | None
    ) -> Select:
        """Apply equality filters from a dict. Supports __in, __gt, __lt, __gte, __lte, __like."""
        if not filters:
            return stmt

        conditions = []
        for key, value in filters.items():
            if "__" in key:
                field_name, op = key.rsplit("__", 1)
                col = getattr(self.model, field_name)
                if op == "in":
                    conditions.append(col.in_(value))
                elif op == "gt":
                    conditions.append(col > value)
                elif op == "lt":
                    conditions.append(col < value)
                elif op == "gte":
                    conditions.append(col >= value)
                elif op == "lte":
                    conditions.append(col <= value)
                elif op == "like":
                    conditions.append(col.ilike(f"%{value}%"))
                elif op == "is_null":
                    conditions.append(col.is_(None) if value else col.isnot(None))
                else:
                    conditions.append(getattr(self.model, key) == value)
            else:
                conditions.append(getattr(self.model, key) == value)

        return stmt.where(and_(*conditions))

    def _apply_ordering(
        self, stmt: Select, order_by: str | None, descending: bool
    ) -> Select:
        if order_by:
            col = getattr(self.model, order_by)
            stmt = stmt.order_by(col.desc() if descending else col.asc())
        return stmt


class PaginatedResult(Generic[T]):
    """Container for paginated query results."""

    def __init__(
        self,
        items: Sequence[T],
        total: int,
        page: int,
        per_page: int,
        pages: int,
    ) -> None:
        self.items = items
        self.total = total
        self.page = page
        self.per_page = per_page
        self.pages = pages

    @property
    def has_next(self) -> bool:
        return self.page < self.pages

    @property
    def has_prev(self) -> bool:
        return self.page > 1

    def to_dict(self) -> dict[str, Any]:
        return {
            "items": self.items,
            "total": self.total,
            "page": self.page,
            "per_page": self.per_page,
            "pages": self.pages,
            "has_next": self.has_next,
            "has_prev": self.has_prev,
        }
