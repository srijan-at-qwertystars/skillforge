# Review: connection-pooling

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (positive:/negative: sub-keys).

Outstanding multi-language connection pooling guide. Covers why pool (lifecycle comparison), sizing (cores x 2 + spindles formula, Little's Law, benchmarking), pool parameters table, app-level pools (HikariCP/SQLAlchemy/node-postgres/Go database/sql with tuning and common mistakes), external poolers (PgBouncer modes/config/monitoring, PgCat with read/write splitting, ProxySQL for MySQL), serverless connection management (Neon/Supabase/RDS Proxy/PlanetScale), monitoring (key metrics/platform-specific queries), troubleshooting (leaks/exhaustion/too-many-connections/slow queries), and anti-patterns.
