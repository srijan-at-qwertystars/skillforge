# Review: regex-patterns

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

## Structure Check

- [x] YAML frontmatter has `name` and `description`
- [x] Description includes positive triggers (regex, pattern matching, text extraction, lookahead/lookbehind, ReDoS, named capture groups) AND negative triggers (simple string contains, JSON/XML/HTML parsing, CSS selectors, glob patterns)
- [x] Body under 500 lines (479 lines excluding frontmatter)
- [x] Imperative voice, no filler — writing is direct and technical throughout
- [x] Examples with input/output provided for every pattern
- [x] references/, scripts/, and assets/ properly linked from SKILL.md with descriptions

## Content Check

### Verified Accurate
- Named capture group syntax per language (JS `(?<name>)`, Python `(?P<name>)`, Go `(?P<name>)`, Rust `(?P<name>)`, Java `(?<name>)`) — all correct per web verification
- Lookahead/lookbehind support matrix (Go ❌, Rust ❌, others ✅) — correct
- JavaScript has no `/x` verbose flag — correctly marked as `—` (N/A) in flags table
- Python `re` module does NOT support `\p{L}` unicode properties — correctly marked ❌
- Rust regex crate uses `(?P<name>...)` only (not `(?<name>...)`) — correctly shown
- ReDoS/catastrophic backtracking explanations are accurate with correct exponential growth examples
- Language API cheatsheets (JS/Python/Go/Rust/Java) — code examples are correct and runnable

### Inaccuracy Found
- **`assets/regex-flags-matrix.md` line 14**: Claims Go supports `(?x) partial` for verbose/extended mode. **Go RE2 does NOT support `(?x)`**. RE2 only supports `(?i)`, `(?m)`, `(?s)`, and `(?U)`. Web-verified against RE2 syntax docs and Go regexp package docs.
- **`assets/cheatsheet.md` line 114**: Same error — footnote states "Go supports `(?x)` inline (limited)". This is incorrect.
- Note: The main SKILL.md body (line 65) correctly states only `(?i)`, `(?m)`, `(?s)` for Go, so the main document is accurate.

### Minor Nits
- URL pattern `^https?:\/\/[^\s/$.?#].[^\s]*$` (line 80): The `.` after the character class is unescaped, meaning it matches ANY character. This is intentional but could confuse readers. A brief comment would help.
- `language-reference.md` table shows `ReplaceFirst()` for Go, but footnote clarifies it doesn't exist — the table cell could be clearer (e.g., `—¹`).

### Missing Gotchas
- No mention of JavaScript's `String.prototype.replaceAll()` requiring `/g` flag or a string argument (throws TypeError without `/g`)
- No mention of Python `re.match()` vs `re.search()` gotcha in the main SKILL.md (covered in troubleshooting.md only)
- These are minor since supplemental docs cover them

### Examples Correctness
- All regex patterns in SKILL.md tested against stated inputs — correct
- Scripts (`regex-tester.sh`, `redos-checker.py`, `pattern-generator.py`) are well-structured with proper argument parsing and error handling
- `common-patterns.json` has 34 patterns with test strings — comprehensive

## Trigger Check

- Description is specific with 10+ positive trigger phrases (regex, regular expressions, pattern matching, text extraction, validation patterns, string parsing, lookahead/lookbehind, named capture groups, regex debugging, ReDoS prevention)
- Four clear negative triggers (simple string checks, JSON/XML/HTML parsing, CSS selectors/XPath, glob/fnmatch)
- Would correctly trigger for: "help me write a regex for email validation", "how do I use lookahead in Python", "is this regex vulnerable to ReDoS"
- Would correctly NOT trigger for: "parse this JSON", "find files matching *.txt", "use querySelector"
- No risk of false triggering for unrelated queries

## Issues

1. **Go `(?x)` verbose mode incorrectly claimed** in `assets/regex-flags-matrix.md` and `assets/cheatsheet.md`. Go RE2 does not support `(?x)`. Fix: Change Go verbose entry to `N/A` or `❌` in both files.
