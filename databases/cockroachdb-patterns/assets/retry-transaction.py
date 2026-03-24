#!/usr/bin/env python3
"""
retry-transaction.py

Demonstrates proper CockroachDB transaction retry logic in Python using psycopg2.
Handles SQLSTATE 40001 (serialization failure) with exponential backoff and jitter.

Usage:
    pip install psycopg2-binary
    python retry-transaction.py

Environment:
    DATABASE_URL  - Connection string (default: postgresql://root@localhost:26257/appdb)
"""

import os
import time
import random
import logging
import psycopg2
import psycopg2.errors
from contextlib import contextmanager
from decimal import Decimal
from typing import Callable, TypeVar, Optional

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

T = TypeVar("T")

DEFAULT_DSN = "postgresql://root@localhost:26257/appdb?sslmode=disable"
MAX_RETRIES = 10
BASE_DELAY = 0.01  # 10ms
MAX_DELAY = 5.0    # 5 seconds


def execute_with_retry(
    conn,
    fn: Callable,
    max_retries: int = MAX_RETRIES,
    base_delay: float = BASE_DELAY,
    max_delay: float = MAX_DELAY,
) -> Optional[T]:
    """
    Execute a database operation with automatic retry on serialization failure.

    Uses the SAVEPOINT-based retry protocol recommended by CockroachDB:
      BEGIN; SAVEPOINT cockroach_restart; <ops>; RELEASE SAVEPOINT; COMMIT;
      On 40001: ROLLBACK TO SAVEPOINT cockroach_restart; retry

    Args:
        conn: psycopg2 connection (autocommit must be False)
        fn: Callable that accepts a cursor and performs DB operations
        max_retries: Maximum number of retry attempts
        base_delay: Initial delay between retries (seconds)
        max_delay: Maximum delay between retries (seconds)

    Returns:
        The return value of fn, if any.

    Raises:
        Exception: If max retries exceeded or non-retryable error occurs.
    """
    conn.autocommit = False

    for attempt in range(max_retries):
        try:
            with conn.cursor() as cur:
                cur.execute("SAVEPOINT cockroach_restart")
                result = fn(cur)
                cur.execute("RELEASE SAVEPOINT cockroach_restart")
            conn.commit()
            if attempt > 0:
                logger.info("Transaction succeeded after %d retries", attempt)
            return result

        except psycopg2.errors.SerializationFailure as e:
            # Retryable: rollback to savepoint and retry
            conn.rollback()
            delay = _calculate_backoff(attempt, base_delay, max_delay)
            logger.warning(
                "Retry %d/%d: serialization failure (40001), waiting %.3fs",
                attempt + 1, max_retries, delay,
            )
            time.sleep(delay)

        except psycopg2.Error as e:
            # Non-retryable database error
            conn.rollback()
            raise RuntimeError(f"Non-retryable database error: {e}") from e

    raise RuntimeError(f"Transaction failed after {max_retries} retries")


def _calculate_backoff(attempt: int, base_delay: float, max_delay: float) -> float:
    """Calculate exponential backoff with jitter."""
    backoff = base_delay * (2 ** attempt)
    jitter = random.uniform(0, backoff * 0.5)
    return min(backoff + jitter, max_delay)


# ---------------------------------------------------------------------------
# Example: Account Transfer
# ---------------------------------------------------------------------------

def setup_schema(conn):
    """Create tables and seed data for the demo."""
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS accounts (
                id STRING PRIMARY KEY,
                name STRING NOT NULL,
                balance DECIMAL(12,2) NOT NULL DEFAULT 0,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                CHECK (balance >= 0)
            );

            CREATE TABLE IF NOT EXISTS transfers (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                from_account STRING NOT NULL REFERENCES accounts(id),
                to_account STRING NOT NULL REFERENCES accounts(id),
                amount DECIMAL(12,2) NOT NULL CHECK (amount > 0),
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );

            UPSERT INTO accounts (id, name, balance) VALUES
                ('account-a', 'Alice', 1000.00),
                ('account-b', 'Bob', 500.00);
        """)
    conn.autocommit = False
    logger.info("Schema and seed data ready.")


def transfer(cur, from_id: str, to_id: str, amount: Decimal):
    """Transfer funds between accounts within a transaction."""
    # Lock source account early with SELECT FOR UPDATE
    cur.execute(
        "SELECT balance FROM accounts WHERE id = %s FOR UPDATE",
        (from_id,),
    )
    row = cur.fetchone()
    if row is None:
        raise ValueError(f"Account {from_id} not found")

    balance = row[0]
    if balance < amount:
        raise ValueError(
            f"Insufficient funds: have {balance}, need {amount}"
        )

    # Debit source
    cur.execute(
        "UPDATE accounts SET balance = balance - %s, updated_at = now() WHERE id = %s",
        (amount, from_id),
    )

    # Credit destination
    cur.execute(
        "UPDATE accounts SET balance = balance + %s, updated_at = now() WHERE id = %s",
        (amount, to_id),
    )

    # Record transfer
    cur.execute(
        """INSERT INTO transfers (from_account, to_account, amount)
           VALUES (%s, %s, %s)""",
        (from_id, to_id, amount),
    )

    logger.info("Transferred $%s from %s to %s", amount, from_id, to_id)


def print_balances(conn):
    """Print current account balances."""
    with conn.cursor() as cur:
        cur.execute("SELECT id, name, balance FROM accounts ORDER BY id")
        rows = cur.fetchall()

    print("\nAccount Balances:")
    print("-" * 50)
    for account_id, name, balance in rows:
        print(f"  {account_id:<15} {name:<15} ${balance:>10.2f}")
    print("-" * 50)


def main():
    dsn = os.getenv("DATABASE_URL", DEFAULT_DSN)
    logger.info("Connecting to %s", dsn)

    conn = psycopg2.connect(dsn)
    try:
        setup_schema(conn)

        # Execute transfer with automatic retry on serialization failure
        execute_with_retry(
            conn,
            lambda cur: transfer(cur, "account-a", "account-b", Decimal("50.00")),
        )

        print_balances(conn)
        logger.info("Transfer completed successfully!")

    finally:
        conn.close()


if __name__ == "__main__":
    main()
