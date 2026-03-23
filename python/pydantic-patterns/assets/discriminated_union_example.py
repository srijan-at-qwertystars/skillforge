"""Discriminated union patterns with Pydantic v2.

Demonstrates: tagged unions, nested discriminators, custom discriminator
functions, serialization/deserialization, and exhaustive handling.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any, Literal, Union
from uuid import UUID, uuid4

from pydantic import BaseModel, Discriminator, Field, Tag, TypeAdapter


# ---------------------------------------------------------------------------
# Basic discriminated union — payment methods
# ---------------------------------------------------------------------------


class CreditCardPayment(BaseModel):
    """Payment via credit card."""

    method: Literal["credit_card"] = "credit_card"
    card_number: str = Field(pattern=r"^\d{13,19}$")
    expiry: str = Field(pattern=r"^\d{2}/\d{2}$")
    cvv: str = Field(pattern=r"^\d{3,4}$")


class BankTransferPayment(BaseModel):
    """Payment via bank transfer."""

    method: Literal["bank_transfer"] = "bank_transfer"
    account_number: str
    routing_number: str


class CryptoPayment(BaseModel):
    """Payment via cryptocurrency."""

    method: Literal["crypto"] = "crypto"
    wallet_address: str
    currency: Literal["BTC", "ETH", "USDT"]


# Discriminated union using the "method" field — O(1) dispatch
PaymentMethod = Annotated[
    Union[CreditCardPayment, BankTransferPayment, CryptoPayment],
    Field(discriminator="method"),
]


class Order(BaseModel):
    id: UUID = Field(default_factory=uuid4)
    amount: float = Field(gt=0)
    payment: PaymentMethod


# ---------------------------------------------------------------------------
# Nested discriminated unions — notification system
# ---------------------------------------------------------------------------


class EmailNotification(BaseModel):
    channel: Literal["email"] = "email"
    to: str
    subject: str
    body: str


class SMSNotification(BaseModel):
    channel: Literal["sms"] = "sms"
    phone: str
    message: str = Field(max_length=160)


class PushNotification(BaseModel):
    channel: Literal["push"] = "push"
    device_token: str
    title: str
    body: str
    data: dict[str, str] = Field(default_factory=dict)


NotificationChannel = Annotated[
    Union[EmailNotification, SMSNotification, PushNotification],
    Field(discriminator="channel"),
]


class NotificationBatch(BaseModel):
    """Send multiple notifications across different channels."""

    notifications: list[NotificationChannel]
    scheduled_at: datetime | None = None


# ---------------------------------------------------------------------------
# Custom discriminator function — when the tag isn't a simple field
# ---------------------------------------------------------------------------


class DogAction(BaseModel):
    sound: Literal["bark", "woof"]
    volume: int = Field(ge=1, le=10)


class CatAction(BaseModel):
    sound: Literal["meow", "purr", "hiss"]
    volume: int = Field(ge=1, le=10)


def animal_discriminator(v: Any) -> str:
    """Determine union variant based on the sound value."""
    if isinstance(v, dict):
        sound = v.get("sound", "")
    elif isinstance(v, BaseModel):
        sound = getattr(v, "sound", "")
    else:
        return "dog"

    if sound in ("bark", "woof"):
        return "dog"
    return "cat"


# Using Discriminator() with a callable + Tag annotations
AnimalAction = Annotated[
    Union[
        Annotated[DogAction, Tag("dog")],
        Annotated[CatAction, Tag("cat")],
    ],
    Discriminator(animal_discriminator),
]


class AnimalEvent(BaseModel):
    animal_name: str
    action: AnimalAction


# ---------------------------------------------------------------------------
# Serialization and deserialization patterns
# ---------------------------------------------------------------------------


def demo_serialization():
    """Show serialization round-trips for discriminated unions."""

    # Create an order with credit card payment
    order = Order(
        amount=99.99,
        payment=CreditCardPayment(
            card_number="4111111111111111",
            expiry="12/25",
            cvv="123",
        ),
    )

    # Serialize to dict — discriminator field is included
    data = order.model_dump()
    print("Dict:", data)
    # {'id': ..., 'amount': 99.99, 'payment': {'method': 'credit_card', ...}}

    # Serialize to JSON
    json_str = order.model_dump_json(indent=2)
    print("JSON:", json_str)

    # Deserialize from dict — discriminator routes to correct variant
    restored = Order.model_validate(data)
    assert isinstance(restored.payment, CreditCardPayment)

    # Deserialize from JSON
    restored_json = Order.model_validate_json(json_str)
    assert isinstance(restored_json.payment, CreditCardPayment)

    # Switch payment type — discriminator handles routing
    bank_order = Order.model_validate({
        "amount": 50.00,
        "payment": {
            "method": "bank_transfer",
            "account_number": "123456789",
            "routing_number": "021000021",
        },
    })
    assert isinstance(bank_order.payment, BankTransferPayment)


def demo_batch_notifications():
    """Demonstrate list of discriminated union variants."""

    batch = NotificationBatch.model_validate({
        "notifications": [
            {"channel": "email", "to": "a@b.com", "subject": "Hi", "body": "Hello"},
            {"channel": "sms", "phone": "+1234567890", "message": "Hey!"},
            {"channel": "push", "device_token": "abc123", "title": "Alert", "body": "!"},
        ],
    })

    for n in batch.notifications:
        print(f"  {n.channel}: {type(n).__name__}")

    # Round-trip
    json_data = batch.model_dump_json()
    restored = NotificationBatch.model_validate_json(json_data)
    assert len(restored.notifications) == 3


def demo_type_adapter():
    """Use TypeAdapter for standalone discriminated union validation."""

    ta = TypeAdapter(PaymentMethod)

    # Validate individual payment
    payment = ta.validate_python({
        "method": "crypto",
        "wallet_address": "0xabc123",
        "currency": "ETH",
    })
    assert isinstance(payment, CryptoPayment)

    # Generate JSON Schema — includes discriminator metadata
    schema = ta.json_schema()
    print("Schema:", schema)

    # Validate a list of payments
    list_ta = TypeAdapter(list[PaymentMethod])
    payments = list_ta.validate_python([
        {"method": "credit_card", "card_number": "4111111111111111", "expiry": "12/25", "cvv": "123"},
        {"method": "bank_transfer", "account_number": "999", "routing_number": "021"},
    ])
    assert len(payments) == 2


def demo_custom_discriminator():
    """Demonstrate custom discriminator function."""

    event1 = AnimalEvent.model_validate({
        "animal_name": "Rex",
        "action": {"sound": "bark", "volume": 8},
    })
    assert isinstance(event1.action, DogAction)

    event2 = AnimalEvent.model_validate({
        "animal_name": "Whiskers",
        "action": {"sound": "purr", "volume": 3},
    })
    assert isinstance(event2.action, CatAction)

    print(f"{event1.animal_name}: {event1.action.sound} (vol {event1.action.volume})")
    print(f"{event2.animal_name}: {event2.action.sound} (vol {event2.action.volume})")


# ---------------------------------------------------------------------------
# Exhaustive pattern matching (Python 3.10+)
# ---------------------------------------------------------------------------

MATCH_EXAMPLE = '''
# Python 3.10+ structural pattern matching with discriminated unions
def process_payment(payment: PaymentMethod) -> str:
    match payment:
        case CreditCardPayment(card_number=num):
            return f"Charging card ending in {num[-4:]}"
        case BankTransferPayment(account_number=acc):
            return f"Transferring to account {acc}"
        case CryptoPayment(wallet_address=addr, currency=cur):
            return f"Sending {cur} to {addr}"
'''


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print("=== Serialization ===")
    demo_serialization()

    print("\n=== Batch Notifications ===")
    demo_batch_notifications()

    print("\n=== TypeAdapter ===")
    demo_type_adapter()

    print("\n=== Custom Discriminator ===")
    demo_custom_discriminator()

    print("\nAll examples passed!")
