# Review: caching-strategies

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format. 501 lines (1 over limit).

Outstanding application caching guide. Covers fundamentals (hit ratio, when to cache), caching patterns (cache-aside/read-through/write-through/write-behind/refresh-ahead), invalidation strategies (TTL with jitter/event-driven/version-based/tag-based), cache key design (convention/normalization/hashing), multi-layer caching (L1/L2/L3 with code examples), distributed caching (consistent hashing/replication/operational concerns), in-process caching (eviction policies LRU/LFU/W-TinyLFU, Caffeine/lru_cache/cachetools/node-cache), stampede prevention (mutex/XFetch/stale-while-revalidate), warming (startup/predictive), serialization (format comparison), monitoring (metrics table), framework patterns (Spring @Cacheable/Django/NestJS), and anti-patterns.
