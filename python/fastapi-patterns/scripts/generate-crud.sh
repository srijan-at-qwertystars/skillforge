#!/usr/bin/env bash
# generate-crud.sh — Generate CRUD router, schema, and service for a FastAPI resource
#
# Usage: ./generate-crud.sh <resource-name> [output-dir]
# Example: ./generate-crud.sh product
#          ./generate-crud.sh product ./app
#
# Generates:
#   <output-dir>/models/<resource>.py    — SQLAlchemy model
#   <output-dir>/schemas/<resource>.py   — Pydantic request/response schemas
#   <output-dir>/services/<resource>.py  — Business logic service
#   <output-dir>/routers/<resource>.py   — APIRouter with CRUD endpoints
#
# The generated code uses async SQLAlchemy 2.0, Pydantic v2, and follows
# the repository/service pattern.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <resource-name> [output-dir]"
    echo "Example: $0 product ./app"
    exit 1
fi

RAW_NAME="$1"
OUTPUT_DIR="${2:-.}"

# Naming conventions
LOWER="${RAW_NAME,,}"                                    # product
UPPER="${LOWER^}"                                        # Product
SNAKE="${LOWER//-/_}"                                    # product (handle dashes)
CLASS="${SNAKE^}"                                        # Product
TABLE="${SNAKE}s"                                        # products

mkdir -p "$OUTPUT_DIR"/{models,schemas,services,routers}

echo "🔧 Generating CRUD for: $CLASS"

# --- Model ---
cat > "$OUTPUT_DIR/models/${SNAKE}.py" << PYEOF
from datetime import datetime

from sqlalchemy import DateTime, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class ${CLASS}(Base):
    __tablename__ = "${TABLE}"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(200), index=True)
    description: Mapped[str | None] = mapped_column(default=None)
    is_active: Mapped[bool] = mapped_column(default=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
PYEOF

# --- Schema ---
cat > "$OUTPUT_DIR/schemas/${SNAKE}.py" << PYEOF
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class ${CLASS}Create(BaseModel):
    name: str = Field(..., min_length=1, max_length=200)
    description: str | None = None


class ${CLASS}Update(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=200)
    description: str | None = None
    is_active: bool | None = None


class ${CLASS}Response(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    description: str | None
    is_active: bool
    created_at: datetime
    updated_at: datetime


class ${CLASS}List(BaseModel):
    items: list[${CLASS}Response]
    total: int
    page: int
    pages: int
PYEOF

# --- Service ---
cat > "$OUTPUT_DIR/services/${SNAKE}.py" << PYEOF
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.${SNAKE} import ${CLASS}
from app.schemas.${SNAKE} import ${CLASS}Create, ${CLASS}Update


class ${CLASS}Service:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def get_by_id(self, ${SNAKE}_id: int) -> ${CLASS} | None:
        return await self.session.get(${CLASS}, ${SNAKE}_id)

    async def get_list(
        self, *, page: int = 1, size: int = 20, active_only: bool = True
    ) -> tuple[list[${CLASS}], int]:
        query = select(${CLASS})
        if active_only:
            query = query.where(${CLASS}.is_active == True)

        count = (await self.session.execute(
            select(func.count()).select_from(query.subquery())
        )).scalar_one()

        items = (await self.session.execute(
            query.order_by(${CLASS}.id).offset((page - 1) * size).limit(size)
        )).scalars().all()

        return list(items), count

    async def create(self, data: ${CLASS}Create) -> ${CLASS}:
        instance = ${CLASS}(**data.model_dump())
        self.session.add(instance)
        await self.session.flush()
        await self.session.refresh(instance)
        return instance

    async def update(self, ${SNAKE}_id: int, data: ${CLASS}Update) -> ${CLASS} | None:
        instance = await self.get_by_id(${SNAKE}_id)
        if not instance:
            return None
        update_data = data.model_dump(exclude_unset=True)
        for key, value in update_data.items():
            setattr(instance, key, value)
        await self.session.flush()
        await self.session.refresh(instance)
        return instance

    async def delete(self, ${SNAKE}_id: int) -> bool:
        instance = await self.get_by_id(${SNAKE}_id)
        if not instance:
            return False
        await self.session.delete(instance)
        await self.session.flush()
        return True
PYEOF

# --- Router ---
cat > "$OUTPUT_DIR/routers/${SNAKE}.py" << PYEOF
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.schemas.${SNAKE} import (
    ${CLASS}Create,
    ${CLASS}List,
    ${CLASS}Response,
    ${CLASS}Update,
)
from app.services.${SNAKE} import ${CLASS}Service

router = APIRouter(prefix="/${TABLE}", tags=["${TABLE}"])


def get_service(db: AsyncSession = Depends(get_db)) -> ${CLASS}Service:
    return ${CLASS}Service(db)


@router.get("/", response_model=${CLASS}List)
async def list_${TABLE}(
    page: int = Query(1, ge=1),
    size: int = Query(20, ge=1, le=100),
    svc: ${CLASS}Service = Depends(get_service),
):
    items, total = await svc.get_list(page=page, size=size)
    return ${CLASS}List(
        items=items, total=total, page=page, pages=(total + size - 1) // size
    )


@router.get("/{${SNAKE}_id}", response_model=${CLASS}Response)
async def get_${SNAKE}(
    ${SNAKE}_id: int,
    svc: ${CLASS}Service = Depends(get_service),
):
    item = await svc.get_by_id(${SNAKE}_id)
    if not item:
        raise HTTPException(status_code=404, detail="${CLASS} not found")
    return item


@router.post("/", response_model=${CLASS}Response, status_code=status.HTTP_201_CREATED)
async def create_${SNAKE}(
    data: ${CLASS}Create,
    svc: ${CLASS}Service = Depends(get_service),
):
    return await svc.create(data)


@router.patch("/{${SNAKE}_id}", response_model=${CLASS}Response)
async def update_${SNAKE}(
    ${SNAKE}_id: int,
    data: ${CLASS}Update,
    svc: ${CLASS}Service = Depends(get_service),
):
    item = await svc.update(${SNAKE}_id, data)
    if not item:
        raise HTTPException(status_code=404, detail="${CLASS} not found")
    return item


@router.delete("/{${SNAKE}_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_${SNAKE}(
    ${SNAKE}_id: int,
    svc: ${CLASS}Service = Depends(get_service),
):
    if not await svc.delete(${SNAKE}_id):
        raise HTTPException(status_code=404, detail="${CLASS} not found")
PYEOF

echo ""
echo "✅ Generated CRUD files for '${CLASS}':"
echo "   $OUTPUT_DIR/models/${SNAKE}.py"
echo "   $OUTPUT_DIR/schemas/${SNAKE}.py"
echo "   $OUTPUT_DIR/services/${SNAKE}.py"
echo "   $OUTPUT_DIR/routers/${SNAKE}.py"
echo ""
echo "Add to app/main.py:"
echo "   from app.routers.${SNAKE} import router as ${SNAKE}_router"
echo "   app.include_router(${SNAKE}_router, prefix=\"/api/v1\")"
