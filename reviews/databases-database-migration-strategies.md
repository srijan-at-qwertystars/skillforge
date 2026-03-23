# Review: database-migration-strategies

Accuracy: 4/5
Completeness: 5/5
Actionability: 4/5
Trigger quality: 4/5
Overall: 4.25/5

Issues:
- COMMIT inside DO block (lines 236-253) is invalid PostgreSQL — DO blocks cannot use transaction control. Must use CREATE PROCEDURE + CALL instead. Filed as GitHub issue #3.
- File is 501 lines, exceeding the 500-line limit by 1.

Otherwise excellent skill. Covers migration tool comparison (Flyway, Liquibase, Alembic, Prisma Migrate, golang-migrate, Knex), naming conventions, zero-downtime patterns (expand-contract, dual-write, blue-green), backward-compatible changes, dangerous operations with safe alternatives, large table migrations (pt-online-schema-change, gh-ost, pg_repack), data vs schema migrations, environment management, rollback strategies, CI/CD integration, and anti-patterns.
