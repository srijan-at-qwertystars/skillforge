# Review: jwt-authentication

Accuracy: 4/5
Completeness: 5/5
Actionability: 3/5
Trigger quality: 5/5
Overall: 4.25/5

Issues:
- Lines 116-119: CRITICAL BUG in refresh token rotation example. When `not record` is True (token not found in DB), the code accesses `record.family_id`, which would raise an `AttributeError` since `record` is None. The logic should either: (a) store "used" tokens with a revoked flag instead of deleting them, so the family_id can still be looked up; or (b) encode the family_id in the refresh token itself. Current code crashes at runtime for the exact security scenario it's trying to handle (token reuse detection).
- The buggy code is in a security-critical path (refresh token rotation), making it a significant actionability concern — an AI copying this code would produce a crashing auth system.
- All other sections are excellent: algorithm guidance, claims design, validation checklist, key management, vulnerability descriptions, and multi-language implementation patterns are all accurate and actionable.
