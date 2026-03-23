# Review: error-handling-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (positive:/negative: sub-keys).

Excellent cross-language error handling guide. Covers philosophy (fail fast, errors as data), custom exception hierarchy (TypeScript ErrorOptions ES2022), checked vs unchecked exceptions, Result/Either patterns (custom discriminated union, neverthrow, Effect library), error propagation (Error cause, Go %w wrapping, Python raise from), RFC 9457 Problem Details (supersedes RFC 7807), error envelope pattern, HTTP status code mapping, React Error Boundaries, framework-level boundaries (Express/Next.js/Spring/ASP.NET), validation with Zod, async error handling (Promise.allSettled, unhandledRejection), retry patterns (exponential backoff with jitter, retriable vs non-retriable), language-specific patterns (AggregateError, Python 3.11+ ExceptionGroup, Go sentinel errors, Java Optional), and anti-patterns.
