# Review: prisma-orm

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (positive:/negative: sub-keys).

Comprehensive Prisma ORM guide. Covers schema design (PascalCase/camelCase, @map/@@map, native types, indexes), relations (1:1/1:many/many:many implicit+explicit, self-relations), migrations (dev/deploy/reset, seeding, CI/CD), Client queries (CRUD, filtering, sorting, cursor pagination), advanced queries (nested writes, connectOrCreate, upsert, aggregations, groupBy), transactions (batch + interactive with isolation levels), raw queries (tagged templates, Prisma.sql/join, TypedSQL 5.19+), performance (select/include, singleton pattern, connection tuning), type safety (GetPayload, validator, satisfies), extensions (query/result/model), multi-schema (preview feature), testing (mocking + integration), and deployment (edge/serverless with Prisma 6 driver adapters).
