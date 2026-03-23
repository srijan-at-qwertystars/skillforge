# Review: docker-compose-patterns
Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5
Issues: Non-standard description format. 501 lines (1 over limit, minor).

Comprehensive Docker Compose guide covering v2 fundamentals (space not hyphen, compose.yaml, no version field), service configuration, networking (bridge/host/none, aliases, external networks), volumes (named, bind mounts, tmpfs, read-only), healthchecks (PostgreSQL/MySQL/Redis with $$ escaping), dependencies (service_started/service_healthy/service_completed_successfully), environment management (precedence, interpolation, .env), profiles, watch mode (Compose v2.22+, sync/sync+restart/rebuild actions), override files, database stacks (PostgreSQL/Redis/MongoDB with init scripts), common stacks, resource limits, debugging commands, and 12 anti-patterns.
