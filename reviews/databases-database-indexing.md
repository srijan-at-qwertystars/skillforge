# Review: database-indexing
Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5
Issues: none

Outstanding database indexing guide with standard description format. Covers fundamentals (B-tree structure, cardinality, selectivity), index types (B-Tree, Hash, GIN, GiST, SP-GiST, BRIN, Bloom), composite indexes (left-prefix rule, equality-then-range), covering indexes (PostgreSQL INCLUDE, MySQL InnoDB), partial indexes (predicate, conditional uniqueness), expression indexes, unique indexes, full-text (PostgreSQL tsvector/GIN, MySQL FULLTEXT), JSON/JSONB indexes (GIN jsonb_path_ops, expression), index analysis (EXPLAIN ANALYZE, unused/redundant detection), maintenance (REINDEX CONCURRENTLY, VACUUM, visibility map, HOT updates, online DDL), MySQL InnoDB specifics (clustered index, secondary lookups), PostgreSQL specifics (GIN fast update, BRIN time-series, HOT fillfactor), design methodology (7-step workload checklist), and anti-patterns.
