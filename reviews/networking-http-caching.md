# Review: http-caching

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.75/5

Issues:
- Lines 204-206: API response example uses `Vary: Accept-Encoding, Authorization` with `s-maxage=60`, which directly contradicts the advice on line 109 stating that `Vary: Authorization` "destroys CDN hit rates" and recommending `Cache-Control: private` instead. The example should use `Cache-Control: private, no-cache` for auth-varying responses, or the API example should be for a non-auth-varying endpoint.
- Otherwise excellent — thorough coverage of HTTP caching headers, CDN strategies, service worker patterns, and anti-patterns.
