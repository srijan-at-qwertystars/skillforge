"""Pydantic v2 BaseModel template with common patterns.

Copy and adapt this template when creating new Pydantic models.
Covers: fields, validators, serialization, configuration, and error handling.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any, Literal
from uuid import UUID, uuid4

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    computed_field,
    field_serializer,
    field_validator,
    model_validator,
)


# ---------------------------------------------------------------------------
# Reusable annotated types — define once, use across models
# ---------------------------------------------------------------------------

# A string that is automatically stripped of whitespace
StrippedStr = Annotated[str, Field(min_length=1, max_length=500)]

# A positive integer
PositiveInt = Annotated[int, Field(gt=0)]


# ---------------------------------------------------------------------------
# Model with common patterns
# ---------------------------------------------------------------------------


class ExampleModel(BaseModel):
    """A well-structured Pydantic v2 model demonstrating common patterns."""

    # -- Configuration -------------------------------------------------------
    model_config = ConfigDict(
        # Rename mapping: accept "externalName" in input, use "field_name" internally
        populate_by_name=True,
        # Read data from ORM objects (SQLAlchemy, Django, etc.)
        from_attributes=True,
        # Reject unexpected fields
        extra="forbid",
        # Validate default values
        validate_default=True,
        # Use enum values (not enum members) in serialization
        use_enum_values=True,
        # Strip whitespace from strings
        str_strip_whitespace=True,
    )

    # -- Fields --------------------------------------------------------------

    # Auto-generated UUID with alias for external APIs
    id: UUID = Field(
        default_factory=uuid4,
        alias="externalId",
        description="Unique identifier",
    )

    # Required string with constraints
    name: StrippedStr = Field(
        description="Display name",
        examples=["Alice", "Bob"],
    )

    # Optional field — must explicitly set default to None
    description: str | None = Field(
        default=None,
        max_length=2000,
        description="Optional description",
    )

    # Numeric field with range constraints
    priority: int = Field(default=0, ge=0, le=10)

    # Enum-like field with Literal
    status: Literal["draft", "active", "archived"] = "draft"

    # List with default_factory (never use mutable default directly)
    tags: list[str] = Field(default_factory=list)

    # Datetime with auto-generation
    created_at: datetime = Field(default_factory=datetime.utcnow)

    # -- Field Validators ----------------------------------------------------

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        """Names cannot be purely numeric."""
        if v.isdigit():
            raise ValueError("name must contain at least one non-digit character")
        return v

    @field_validator("tags")
    @classmethod
    def validate_tags(cls, v: list[str]) -> list[str]:
        """Deduplicate and lowercase tags. Return new list, don't mutate."""
        return list(dict.fromkeys(tag.lower().strip() for tag in v if tag.strip()))

    # -- Model Validators ----------------------------------------------------

    @model_validator(mode="before")
    @classmethod
    def pre_process(cls, data: Any) -> Any:
        """Pre-processing on raw input. Guard against non-dict input."""
        if isinstance(data, dict):
            # Normalize legacy field names
            if "title" in data and "name" not in data:
                data["name"] = data.pop("title")
        return data

    @model_validator(mode="after")
    def post_validate(self) -> ExampleModel:
        """Cross-field validation on the constructed instance."""
        if self.status == "archived" and not self.description:
            raise ValueError("archived items must have a description")
        return self

    # -- Computed Fields ------------------------------------------------------

    @computed_field
    @property
    def tag_count(self) -> int:
        """Number of tags. Included in model_dump() and JSON Schema."""
        return len(self.tags)

    # -- Custom Serializers ---------------------------------------------------

    @field_serializer("created_at")
    def serialize_created_at(self, v: datetime, _info: Any) -> str:
        """Always output ISO 8601 format."""
        return v.isoformat()


# ---------------------------------------------------------------------------
# Usage examples
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # Create from dict
    data = {
        "name": "Example Item",
        "tags": ["Python", "python", "Pydantic"],
        "priority": 5,
    }
    item = ExampleModel.model_validate(data)
    print("Created:", item.model_dump(exclude_unset=True))

    # Create from JSON
    json_str = '{"name": "JSON Item", "externalId": "550e8400-e29b-41d4-a716-446655440000"}'
    item2 = ExampleModel.model_validate_json(json_str)
    print("From JSON:", item2.name, item2.id)

    # Serialization options
    print("Full dump:", item.model_dump())
    print("JSON mode:", item.model_dump(mode="json"))
    print("By alias:", item.model_dump(by_alias=True))
    print("Exclude none:", item.model_dump(exclude_none=True))

    # JSON Schema
    print("Schema:", ExampleModel.model_json_schema())

    # Error handling
    try:
        ExampleModel.model_validate({"name": "x", "status": "invalid"})
    except ValidationError as e:
        print(f"Validation failed: {e.error_count()} errors")
        for err in e.errors():
            print(f"  {err['loc']}: {err['msg']}")
