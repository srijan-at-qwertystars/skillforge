"""FastAPI request/response model patterns with Pydantic v2.

Demonstrates: input/output separation, pagination, error responses,
partial updates (PATCH), ORM integration, and filtering.
"""

from __future__ import annotations

from datetime import datetime
from typing import Generic, Literal, TypeVar
from uuid import UUID, uuid4

from pydantic import (
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    computed_field,
    field_validator,
    model_validator,
)

# ---------------------------------------------------------------------------
# Generic pagination wrapper
# ---------------------------------------------------------------------------

T = TypeVar("T")


class PaginatedResponse(BaseModel, Generic[T]):
    """Generic paginated response wrapper."""

    items: list[T]
    total: int = Field(ge=0)
    page: int = Field(ge=1)
    per_page: int = Field(ge=1, le=100)

    @computed_field
    @property
    def total_pages(self) -> int:
        return max(1, -(-self.total // self.per_page))  # ceiling division

    @computed_field
    @property
    def has_next(self) -> bool:
        return self.page < self.total_pages

    @computed_field
    @property
    def has_prev(self) -> bool:
        return self.page > 1


# ---------------------------------------------------------------------------
# Standard error response
# ---------------------------------------------------------------------------


class ErrorDetail(BaseModel):
    field: str | None = None
    message: str
    error_type: str


class ErrorResponse(BaseModel):
    """Standard API error response."""

    status: int
    message: str
    details: list[ErrorDetail] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# User models — demonstrates input/output separation
# ---------------------------------------------------------------------------


class UserCreate(BaseModel):
    """POST /users — create a new user."""

    model_config = ConfigDict(str_strip_whitespace=True)

    name: str = Field(min_length=1, max_length=100, examples=["Alice Smith"])
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    role: Literal["user", "admin"] = "user"

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        if v.isdigit():
            raise ValueError("name cannot be purely numeric")
        return v

    @field_validator("password")
    @classmethod
    def validate_password(cls, v: str) -> str:
        if not any(c.isupper() for c in v):
            raise ValueError("password must contain an uppercase letter")
        if not any(c.isdigit() for c in v):
            raise ValueError("password must contain a digit")
        return v


class UserUpdate(BaseModel):
    """PATCH /users/{id} — partial update.

    All fields are optional. Only provided fields are updated.
    Use exclude_unset=True when dumping to get only the set fields.
    """

    name: str | None = Field(default=None, min_length=1, max_length=100)
    email: EmailStr | None = None
    role: Literal["user", "admin"] | None = None


class UserResponse(BaseModel):
    """GET /users/{id} — user detail response.

    Never exposes password. Use from_attributes=True for ORM integration.
    """

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    email: str
    role: str
    is_active: bool = True
    created_at: datetime
    updated_at: datetime | None = None


class UserListItem(BaseModel):
    """GET /users — compact user in list responses."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    email: str
    role: str
    is_active: bool


# ---------------------------------------------------------------------------
# Item models — demonstrates nested models & validation
# ---------------------------------------------------------------------------


class TagModel(BaseModel):
    name: str = Field(min_length=1, max_length=50)
    color: str = Field(default="#000000", pattern=r"^#[0-9a-fA-F]{6}$")


class ItemCreate(BaseModel):
    """POST /items"""

    model_config = ConfigDict(str_strip_whitespace=True)

    title: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=5000)
    price: float = Field(gt=0, examples=[29.99])
    currency: Literal["USD", "EUR", "GBP"] = "USD"
    tags: list[TagModel] = Field(default_factory=list, max_length=10)
    metadata: dict[str, str] = Field(default_factory=dict)

    @field_validator("tags")
    @classmethod
    def unique_tag_names(cls, v: list[TagModel]) -> list[TagModel]:
        names = [t.name.lower() for t in v]
        if len(names) != len(set(names)):
            raise ValueError("tag names must be unique")
        return v


class ItemResponse(BaseModel):
    """GET /items/{id}"""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    title: str
    description: str | None
    price: float
    currency: str
    tags: list[TagModel]
    owner_id: UUID
    created_at: datetime

    @computed_field
    @property
    def display_price(self) -> str:
        symbols = {"USD": "$", "EUR": "€", "GBP": "£"}
        symbol = symbols.get(self.currency, self.currency)
        return f"{symbol}{self.price:.2f}"


# ---------------------------------------------------------------------------
# Query/filter models — for validated query parameters
# ---------------------------------------------------------------------------


class PaginationParams(BaseModel):
    """Common pagination query parameters."""

    page: int = Field(default=1, ge=1)
    per_page: int = Field(default=20, ge=1, le=100)

    @property
    def offset(self) -> int:
        return (self.page - 1) * self.per_page


class UserFilter(PaginationParams):
    """GET /users?role=admin&is_active=true&sort_by=created_at"""

    role: Literal["user", "admin"] | None = None
    is_active: bool | None = None
    search: str | None = Field(default=None, min_length=1, max_length=100)
    sort_by: Literal["name", "email", "created_at"] = "created_at"
    sort_order: Literal["asc", "desc"] = "desc"


# ---------------------------------------------------------------------------
# Bulk operation models
# ---------------------------------------------------------------------------


class BulkDeleteRequest(BaseModel):
    ids: list[UUID] = Field(min_length=1, max_length=100)

    @field_validator("ids")
    @classmethod
    def unique_ids(cls, v: list[UUID]) -> list[UUID]:
        if len(v) != len(set(v)):
            raise ValueError("duplicate IDs not allowed")
        return v


class BulkOperationResult(BaseModel):
    total: int
    succeeded: int
    failed: int
    errors: list[ErrorDetail] = Field(default_factory=list)

    @computed_field
    @property
    def success_rate(self) -> float:
        return self.succeeded / self.total if self.total > 0 else 0.0


# ---------------------------------------------------------------------------
# Usage example with FastAPI
# ---------------------------------------------------------------------------

FASTAPI_EXAMPLE = """
from fastapi import FastAPI, Depends, HTTPException, Query
from uuid import UUID

app = FastAPI()

@app.post("/users", response_model=UserResponse, status_code=201)
async def create_user(user: UserCreate):
    ...

@app.get("/users", response_model=PaginatedResponse[UserListItem])
async def list_users(filters: UserFilter = Depends()):
    ...

@app.get("/users/{user_id}", response_model=UserResponse)
async def get_user(user_id: UUID):
    ...

@app.patch("/users/{user_id}", response_model=UserResponse)
async def update_user(user_id: UUID, updates: UserUpdate):
    # Only apply fields that were explicitly set
    update_data = updates.model_dump(exclude_unset=True)
    ...

@app.delete("/users", response_model=BulkOperationResult)
async def delete_users(request: BulkDeleteRequest):
    ...
"""
