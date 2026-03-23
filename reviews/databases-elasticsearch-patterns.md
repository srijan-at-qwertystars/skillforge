# Review: elasticsearch-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (Positive:/Negative: labels inside quoted strings within the `|` YAML block).

Comprehensive Elasticsearch guide. Covers index and mapping design (explicit mappings, dynamic:strict, field type selection, dynamic templates), analyzers (built-in standard/simple/whitespace/keyword, custom analyzers with char_filter/tokenizer/token_filter chain, edge_ngram for autocomplete with different search-time analyzer), Query DSL (bool with must/filter/should/must_not, match/multi_match with boost, term-level queries, nested queries, function_score with field_value_factor and gauss decay), full-text search patterns (relevance tuning, fuzziness AUTO, synonyms via search_analyzer), aggregations (terms, date_histogram, range, nested, pipeline with cumulative_sum/derivative, composite for high cardinality), ILM (hot-warm-cold architecture with rollover/shrink/forcemerge), aliases and zero-downtime reindexing, performance tuning (shard sizing 10-50GB, bulk indexing 5-15MB, query optimization with filter caching, search_after for deep pagination, index.sort), search templates (mustache), runtime fields, data modeling (nested vs parent-child vs denormalized comparison), monitoring (cluster health, slow logs, key metrics), and anti-patterns (over-sharding, mapping explosion, deep pagination with PIT solution).
