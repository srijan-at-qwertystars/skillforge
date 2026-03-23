# Review: rest-api-design

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5

Issues: none

Excellent skill with standard description format. Comprehensive REST API design guide covering resource naming (plural nouns, lowercase hyphenated, max 2 nesting levels), HTTP methods table (safe/idempotent properties), complete status code reference (2xx/3xx/4xx/5xx), error response format (RFC 9457/7807 Problem Details), pagination (cursor-based preferred, offset-based, Link header RFC 8288), filtering/sorting/field selection, versioning strategies (URI path recommended, with Sunset/Deprecation headers), authentication (Bearer, API key, OAuth 2.1+PKCE), rate limiting (RateLimit-* IETF draft headers), HATEOAS (_links, HAL+JSON), OpenAPI 3.1 specification, bulk operations (207 Multi-Status), caching (ETags, Cache-Control, optimistic concurrency), and anti-patterns.
