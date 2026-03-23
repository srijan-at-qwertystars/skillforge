# Review: mongodb-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format. Zone sharding uses older API names (sh.addShardTag/addTagRange vs newer sh.addShardToZone/updateZoneKeyRange), though both still work.

Comprehensive MongoDB skill covering schema design (embedding vs referencing with criteria), design patterns (attribute, bucket, computed, extended reference, outlier, subset, polymorphic), indexing (compound/ESR rule, multikey, text, wildcard, partial, TTL, unique, explain/covered queries), aggregation pipeline ($match/$project/$group/$sort/$limit/$lookup/$facet/$merge with optimization rules), multi-document transactions with retry logic, Mongoose ODM (schema/virtuals/hooks/populate/lean/discriminators), query optimization (projection, cursor-based pagination, read preferences), change streams with resume tokens, sharding strategies (hashed/ranged/compound/zone), security (RBAC, CSFLE, TLS, audit), and anti-patterns.
