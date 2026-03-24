// retry-transaction.go
//
// Demonstrates proper CockroachDB transaction retry logic in Go using pgx.
// Handles SQLSTATE 40001 (serialization failure) with exponential backoff.
//
// Usage:
//   go run retry-transaction.go
//
// Requires:
//   go get github.com/jackc/pgx/v5
//   go get github.com/jackc/pgx/v5/pgxpool

package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math"
	"math/rand"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	defaultDSN    = "postgresql://root@localhost:26257/appdb?sslmode=disable"
	maxRetries    = 10
	baseDelay     = 10 * time.Millisecond
	maxDelay      = 5 * time.Second
	serializationFailureCode = "40001"
)

func main() {
	ctx := context.Background()

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		dsn = defaultDSN
	}

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer pool.Close()

	if err := setup(ctx, pool); err != nil {
		log.Fatalf("Setup failed: %v", err)
	}

	// Transfer $50 from account A to account B with retry logic
	err = ExecuteWithRetry(ctx, pool, func(ctx context.Context, tx pgx.Tx) error {
		return transfer(ctx, tx, "account-a", "account-b", 50.00)
	})
	if err != nil {
		log.Fatalf("Transfer failed: %v", err)
	}

	printBalances(ctx, pool)
	log.Println("Transfer completed successfully!")
}

// ExecuteWithRetry runs a transaction function with automatic retry on
// serialization failure (SQLSTATE 40001). Uses exponential backoff with jitter.
func ExecuteWithRetry(ctx context.Context, pool *pgxpool.Pool, fn func(ctx context.Context, tx pgx.Tx) error) error {
	for attempt := 0; attempt < maxRetries; attempt++ {
		err := pgx.BeginTxFunc(ctx, pool, pgx.TxOptions{
			IsoLevel: pgx.Serializable,
		}, func(tx pgx.Tx) error {
			return fn(ctx, tx)
		})

		if err == nil {
			if attempt > 0 {
				log.Printf("Transaction succeeded after %d retries", attempt)
			}
			return nil
		}

		// Check if the error is a serialization failure (retryable)
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == serializationFailureCode {
			delay := calculateBackoff(attempt)
			log.Printf("Retry %d/%d: serialization failure, waiting %v", attempt+1, maxRetries, delay)

			select {
			case <-ctx.Done():
				return fmt.Errorf("context cancelled during retry: %w", ctx.Err())
			case <-time.After(delay):
				continue
			}
		}

		// Non-retryable error
		return fmt.Errorf("transaction failed with non-retryable error: %w", err)
	}

	return fmt.Errorf("transaction failed after %d retries", maxRetries)
}

// calculateBackoff returns exponential backoff duration with jitter.
func calculateBackoff(attempt int) time.Duration {
	backoff := float64(baseDelay) * math.Pow(2, float64(attempt))
	jitter := rand.Float64() * backoff * 0.5 // 0-50% jitter
	delay := time.Duration(backoff + jitter)
	if delay > maxDelay {
		delay = maxDelay
	}
	return delay
}

// transfer moves amount from one account to another within a transaction.
func transfer(ctx context.Context, tx pgx.Tx, fromID, toID string, amount float64) error {
	// Check source balance using SELECT FOR UPDATE to acquire lock early
	var balance float64
	err := tx.QueryRow(ctx,
		"SELECT balance FROM accounts WHERE id = $1 FOR UPDATE",
		fromID,
	).Scan(&balance)
	if err != nil {
		return fmt.Errorf("failed to read source balance: %w", err)
	}

	if balance < amount {
		return fmt.Errorf("insufficient funds: have %.2f, need %.2f", balance, amount)
	}

	// Debit source
	_, err = tx.Exec(ctx,
		"UPDATE accounts SET balance = balance - $1, updated_at = now() WHERE id = $2",
		amount, fromID,
	)
	if err != nil {
		return fmt.Errorf("failed to debit source: %w", err)
	}

	// Credit destination
	_, err = tx.Exec(ctx,
		"UPDATE accounts SET balance = balance + $1, updated_at = now() WHERE id = $2",
		amount, toID,
	)
	if err != nil {
		return fmt.Errorf("failed to credit destination: %w", err)
	}

	// Record the transfer
	_, err = tx.Exec(ctx, `
		INSERT INTO transfers (id, from_account, to_account, amount, created_at)
		VALUES (gen_random_uuid(), $1, $2, $3, now())`,
		fromID, toID, amount,
	)
	if err != nil {
		return fmt.Errorf("failed to record transfer: %w", err)
	}

	return nil
}

// setup creates the schema and seed data for the demo.
func setup(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `
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
	`)
	return err
}

// printBalances prints current balances for all accounts.
func printBalances(ctx context.Context, pool *pgxpool.Pool) {
	rows, err := pool.Query(ctx, "SELECT id, name, balance FROM accounts ORDER BY id")
	if err != nil {
		log.Printf("Failed to query balances: %v", err)
		return
	}
	defer rows.Close()

	fmt.Println("\nAccount Balances:")
	fmt.Println("--------------------------------------------------")
	for rows.Next() {
		var id, name string
		var balance float64
		if err := rows.Scan(&id, &name, &balance); err != nil {
			log.Printf("Failed to scan row: %v", err)
			continue
		}
		fmt.Printf("  %-15s %-15s $%.2f\n", id, name, balance)
	}
	fmt.Println("--------------------------------------------------")
}
