# Review: rate-limiting-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (positive:/negative: sub-keys).

Outstanding rate limiting guide. Covers algorithms (fixed window/sliding window log+counter/token bucket/leaky bucket/GCRA), HTTP rate limit headers (IETF draft), server-side implementation (Express middleware, key strategies, tiered limits), Redis-based distributed limiting (Lua scripts for sliding window + token bucket, why Lua over MULTI/EXEC), multi-language implementations (Node.js/Python/Go), API gateways (NGINX/Kong/AWS/Cloudflare), client-side handling (exponential backoff with jitter, retry queue), DDoS defense layers, testing (k6 load test, edge cases, clock abstraction), and anti-patterns.
