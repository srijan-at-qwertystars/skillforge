# Review: regex-patterns

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues: Non-standard description format. Language support table (line ~130) incorrectly shows Go as not supporting named groups (✗*), but the Go section (lines 359-360) correctly demonstrates `(?P<name>...)` working. Go's RE2 implementation does support named groups — the table entry is wrong (the footnote only applies to lookaround and backreferences, not named groups).

Comprehensive regex guide. Covers syntax fundamentals (character classes, quantifiers with greedy/lazy/possessive, anchors, alternation), groups (capturing, non-capturing, named with Python/JS/Java syntax, backreferences), lookahead/lookbehind (all 4 types with language support table), common patterns (email, URL, IPv4, ISO date, phone, semver, UUID v4), string manipulation (search/replace, findall, split, fullmatch in Python/JS), flags (global/case-insensitive/multiline/dotall/unicode/verbose with inline syntax), performance (catastrophic backtracking, ReDoS prevention, atomic groups, possessive quantifiers, optimization techniques), language-specific syntax (JS, Python, Go, Java, Rust with PCRE vs POSIX comparison), Unicode handling (property escapes, categories, grapheme clusters), testing/debugging (unit test template, checklist), and anti-patterns (when NOT to use regex, smells and fixes, maintainability).
