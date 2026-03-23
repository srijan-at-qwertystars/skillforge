---
name: regex-patterns
description:
  positive: "Use when user writes regex, asks about regular expressions, pattern matching, capture groups, lookahead/lookbehind, character classes, quantifiers, or regex performance (backtracking)."
  negative: "Do NOT use for glob patterns, SQL LIKE, or simple string contains/startsWith checks."
---

# Regular Expression Patterns and Best Practices

## Syntax Fundamentals

### Character Classes

| Class      | Matches                        | Example              | Matches           |
|------------|--------------------------------|----------------------|-------------------|
| `[abc]`    | Any of a, b, c                 | `[aeiou]`            | `"hello"` → `e,o` |
| `[^abc]`   | Not a, b, or c                 | `[^0-9]`             | `"a1b"` → `a,b`   |
| `[a-z]`    | Range a through z              | `[A-Za-z]`           | letters only       |
| `.`        | Any char except newline        | `a.c`                | `"abc"`, `"a1c"`   |
| `\d`       | Digit `[0-9]`                  | `\d{3}`              | `"123"`            |
| `\D`       | Non-digit                      | `\D+`                | `"abc"`            |
| `\w`       | Word char `[A-Za-z0-9_]`      | `\w+`                | `"foo_1"`          |
| `\W`       | Non-word char                  | `\W`                 | `"@"`, `" "`       |
| `\s`       | Whitespace `[ \t\n\r\f\v]`    | `\s+`                | `" \t"`            |
| `\S`       | Non-whitespace                 | `\S+`                | `"hello"`          |

### Quantifiers

| Quantifier | Meaning            | Greedy    | Lazy      | Possessive |
|------------|--------------------|-----------|-----------|------------|
| `*`        | 0 or more          | `a*`      | `a*?`     | `a*+`      |
| `+`        | 1 or more          | `a+`      | `a+?`     | `a++`      |
| `?`        | 0 or 1             | `a?`      | `a??`     | `a?+`      |
| `{n}`      | Exactly n          | `a{3}`    | —         | —          |
| `{n,}`     | n or more          | `a{2,}`   | `a{2,}?`  | `a{2,}+`   |
| `{n,m}`    | Between n and m    | `a{2,4}`  | `a{2,4}?` | `a{2,4}+`  |

Greedy matches as much as possible, then backtracks. Lazy matches as little as possible. Possessive never backtracks (PCRE/Java only).

### Anchors

| Anchor | Matches                                      |
|--------|----------------------------------------------|
| `^`    | Start of string (or line with `m` flag)       |
| `$`    | End of string (or line with `m` flag)         |
| `\b`   | Word boundary                                 |
| `\B`   | Non-word boundary                             |
| `\A`   | Absolute start of string (Python, Java, PCRE) |
| `\z`   | Absolute end of string                        |

```
# Word boundary example
Pattern: \bcat\b
Match:   "the cat sat"  → "cat"
No match: "concatenate"
```

### Alternation

Use `|` for OR. Wrap in group to limit scope:

```
cat|dog food       # matches "cat" OR "dog food"
(cat|dog) food     # matches "cat food" OR "dog food"
```

## Groups

### Capturing Groups

```
Pattern: (\d{4})-(\d{2})-(\d{2})
Input:   "2025-07-15"
Group 1: "2025"
Group 2: "07"
Group 3: "15"
```

### Non-Capturing Groups

Use `(?:...)` when grouping is needed but capture is not:

```
Pattern: (?:https?|ftp)://\S+
# Groups for alternation only, no capture overhead
```

### Named Groups

```python
# Python:  (?P<name>...)
import re
m = re.search(r'(?P<year>\d{4})-(?P<month>\d{2})', '2025-07')
m.group('year')   # "2025"

# JavaScript:  (?<name>...)
const m = /(?<year>\d{4})-(?<month>\d{2})/.exec('2025-07');
m.groups.year     // "2025"

# Java/PCRE:  (?<name>...)  (same as JS)
```

### Backreferences

Reference a previously captured group within the same pattern:

```
# Match repeated words
\b(\w+)\s+\1\b              # "the the cat" → "the the"
(?P<word>\w+)\s+(?P=word)    # Named backreference (Python)
```

## Lookahead and Lookbehind

Zero-width assertions — match a position, consume no characters.

| Type                | Syntax       | Example                         | Matches              |
|---------------------|--------------|----------------------------------|----------------------|
| Positive lookahead  | `(?=...)`    | `\d+(?= dollars)`               | `"100"` in `"100 dollars"` |
| Negative lookahead  | `(?!...)`    | `\d+(?! dollars)`                | `"100"` in `"100 euros"` |
| Positive lookbehind | `(?<=...)`   | `(?<=\$)\d+`                     | `"50"` in `"$50"`   |
| Negative lookbehind | `(?<!...)`   | `(?<!un)happy`                   | `"happy"` not `"unhappy"` |

### Language Support

| Feature         | JS (ES2018+) | Python | Java | Go  | Rust (`regex`) | PCRE |
|-----------------|-------------|--------|------|-----|----------------|------|
| Lookahead       | ✓           | ✓      | ✓    | ✗   | ✗              | ✓    |
| Lookbehind      | ✓           | ✓      | ✓    | ✗   | ✗              | ✓    |
| Named groups    | ✓ `(?<>)`   | ✓ `(?P<>)` | ✓ | ✗*  | ✓ `(?P<>)`    | ✓    |
| Possessive `++` | ✗           | ✗      | ✓    | ✗   | ✗              | ✓    |
| Atomic `(?>)`   | ✗           | ✗      | ✓**  | ✗   | ✗              | ✓    |

\*Go `regexp` uses RE2 — no lookaround or backreferences. Use `regexp2` for PCRE features.  
\**Java supports atomic groups via possessive quantifiers; explicit `(?>)` in Java 13+.

### Practical Lookbehind Examples

```
# Extract value after key
Pattern: (?<=temperature=)\d+
Input:   "temperature=72"  → "72"

# Password strength: at least one digit, one uppercase, one special
Pattern: ^(?=.*\d)(?=.*[A-Z])(?=.*[!@#$%^&*]).{8,}$
Input:   "Secur3!ty"  → match
```

## Common Patterns

### Email (practical, not RFC-complete)

```
^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$
# Matches: user@example.com, first.last+tag@sub.domain.org
# Rejects: @missing.com, user@.com
```

### URL

```
^https?://[^\s/$.?#].[^\s]*$
# Matches: https://example.com/path?q=1
```

### IPv4

```
^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$
# Matches: 192.168.1.1, 10.0.0.255
# Rejects: 999.1.1.1, 1.2.3.4.5
```

### ISO Date (YYYY-MM-DD)

```
^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$  # 2025-07-15 ✓ | 2025-13-01 ✗
```

### Phone (North American)

```
^(?:\+1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}$
# Matches: (555) 123-4567, +1-555-123-4567
```

### Semantic Version

```
^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([\da-zA-Z-]+(?:\.[\da-zA-Z-]+)*))?(?:\+([\da-zA-Z-]+(?:\.[\da-zA-Z-]+)*))?$
# Matches: 1.0.0, 2.1.3-beta.1
```

### UUID v4

```
^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$
# Matches: 550e8400-e29b-41d4-a716-446655440000
```

## String Manipulation

### Search and Replace

```python
# Python
re.sub(r'\b(\w)', lambda m: m.group(1).upper(), 'hello world')
# → "Hello World"
```

```javascript
// JavaScript
'2025-07-15'.replace(/(\d{4})-(\d{2})-(\d{2})/, '$2/$3/$1');
// → "07/15/2025"
```

### Extract All Matches

```python
# Python
re.findall(r'\b[A-Z][a-z]+\b', 'Alice met Bob at the Park')
# → ['Alice', 'Bob', 'Park']
```

```javascript
// JavaScript
[...'a1b2c3'.matchAll(/[a-z](\d)/g)].map(m => m[1]);
// → ['1', '2', '3']
```

### Split

```python
re.split(r'[,;\s]+', 'a, b;c  d')  # → ['a', 'b', 'c', 'd']
```

### Validate (full match)

```python
re.fullmatch(r'\d{3}-\d{4}', '123-4567')  # Match object (use fullmatch, not match)
```

```javascript
/^\d{3}-\d{4}$/.test('123-4567');  // true — anchor with ^ and $
```

## Flags

| Flag | Name             | Effect                                  | JS   | Python         |
|------|------------------|-----------------------------------------|------|----------------|
| `g`  | Global           | Match all occurrences                   | `/g` | `re.findall()` |
| `i`  | Case-insensitive | `A` matches `a`                         | `/i` | `re.IGNORECASE`|
| `m`  | Multiline        | `^`/`$` match line boundaries           | `/m` | `re.MULTILINE` |
| `s`  | DotAll           | `.` matches `\n`                        | `/s` | `re.DOTALL`    |
| `u`  | Unicode          | Full Unicode matching                   | `/u` | default        |
| `x`  | Verbose          | Ignore whitespace, allow `#` comments   | —    | `re.VERBOSE`   |

### Inline Flags

Embed flags inside the pattern:

```python
# Python inline
r'(?i)hello'       # case-insensitive
r'(?ms)^start.*end$'  # multiline + dotall
```

```
# PCRE/Java inline
(?i:CaSe)          # case-insensitive for this group only
```

## Performance

### Catastrophic Backtracking

Occurs when the engine explores exponential paths. Triggered by nested quantifiers on overlapping character classes.

```
# DANGEROUS — O(2^n) on non-matching input
Pattern: (a+)+$
Input:   "aaaaaaaaaaaaaaaaX"
# Engine tries every way to partition "a"s, then fails at "X"

# SAFE rewrite
Pattern: a+$
```

### ReDoS Prevention Rules

1. **Never nest quantifiers on overlapping classes**: `(\w+)+`, `(\d+)*\d+`, `(a|a)+`
2. **Anchor patterns**: Use `^` and `$` to bound the search space
3. **Prefer specific classes over `.`**: Use `[^"]*` instead of `.*` inside quoted strings
4. **Set timeouts on untrusted input** (.NET, Java, Python 3.11+)
5. **Use linear-time engines for untrusted patterns**: RE2 (Go), Rust `regex`, .NET `NonBacktracking`

### Atomic Groups and Possessive Quantifiers

Prevent backtracking into a subexpression once matched:

```
# Atomic group (PCRE, Java 13+)
(?>a+)b        # Matches "aaab", fails fast on "aaac"

# Possessive quantifier (Java, PCRE)
a++b           # Same behavior, shorter syntax
# Equivalent: once 'a+' has consumed all 'a's, never give any back
```

### Optimization Techniques

- **Pre-compile patterns**: `re.compile()` in Python, `Pattern.compile()` in Java
- **Use non-capturing groups** `(?:...)` when captures are not needed
- **Place most likely alternative first**: `(common|rare)` not `(rare|common)`
- **Avoid `.*` at pattern start**: Anchor or use a literal prefix instead
- **Benchmark with pathological input**: Test `"a" * 1000 + "X"` against your pattern

## Language-Specific Syntax

### JavaScript

```javascript
const re = /(?<proto>https?):\/\/(?<host>[^/]+)/;
const m = re.exec('https://example.com/path');
m.groups.proto; // "https"
m.groups.host;  // "example.com"

// String.matchAll (ES2020) — requires /g flag
for (const m of str.matchAll(/pattern/g)) { /* ... */ }
```

### Python

```python
import re

# re module: backtracking NFA, full features
# For advanced features (atomic groups, possessive quantifiers): pip install regex
import regex
regex.search(r'(?>a+)b', 'aaab')  # atomic group support

# re.VERBOSE for readable patterns
pattern = re.compile(r'''
    (?P<area>\d{3})   # area code
    [-.\s]?           # separator
    (?P<number>\d{7}) # phone number
''', re.VERBOSE)
```

### Go

```go
// Go uses RE2 — linear time, no backtracking
// No lookaround, no backreferences, no possessive quantifiers
re := regexp.MustCompile(`(\d{4})-(\d{2})-(\d{2})`)
matches := re.FindStringSubmatch("2025-07-15")
// matches[1] = "2025", matches[2] = "07", matches[3] = "15"

// Named groups via (?P<name>...)
re2 := regexp.MustCompile(`(?P<year>\d{4})-(?P<month>\d{2})`)
```

### Java

```java
// Full PCRE-like features: lookaround, atomic, possessive
Pattern p = Pattern.compile("(?<year>\\d{4})-(?<month>\\d{2})");
Matcher m = p.matcher("2025-07");
if (m.find()) {
    m.group("year");  // "2025"
}

// Possessive quantifier to prevent backtracking
Pattern safe = Pattern.compile("[^\"]*+\"");
```

### Rust

```rust
// regex crate: RE2-based, linear time, no backtracking
// No lookaround, no backreferences
use regex::Regex;
let re = Regex::new(r"(?P<y>\d{4})-(?P<m>\d{2})-(?P<d>\d{2})").unwrap();
let caps = re.captures("2025-07-15").unwrap();
caps.name("y").unwrap().as_str(); // "2025"

// For PCRE features: use `fancy-regex` crate (supports lookaround)
```

### PCRE vs POSIX

| Feature             | PCRE                  | POSIX ERE             |
|---------------------|-----------------------|-----------------------|
| Lazy quantifiers    | ✓ `*?` `+?`          | ✗                     |
| Lookaround          | ✓                     | ✗                     |
| Named groups        | ✓                     | ✗                     |
| Backreferences      | ✓ `\1`                | BRE only `\1`         |
| Non-capturing group | ✓ `(?:...)`           | ✗                     |
| Character classes   | `\d \w \s`            | `[:digit:] [:alpha:]` |
| Atomic groups       | ✓ `(?>...)`           | ✗                     |

## Unicode Handling

### Unicode Property Escapes (`\p{...}`)

```javascript
// JavaScript (requires /u or /v flag)
/\p{Script=Greek}/u.test('Ω');       // true
/\p{Emoji}/u.test('😀');              // true

// Python (pip install regex — stdlib re has limited \p support)
import regex
regex.findall(r'\p{Han}', '你好world')  # ['你', '好']
```

### Common Unicode Categories

| Category    | Shorthand | Matches                     |
|-------------|-----------|------------------------------|
| `\p{L}`     | Letter    | Any letter (all scripts)     |
| `\p{N}`     | Number    | Any numeric character        |
| `\p{P}`     | Punct     | Any punctuation              |
| `\p{S}`     | Symbol    | Currency, math, emoji, etc.  |
| `\p{Z}`     | Separator | Spaces, line/paragraph sep   |
| `\p{M}`     | Mark      | Combining marks (accents)    |

### Grapheme Clusters

A single visible character may be multiple code points. Use `\X` (PCRE, Python `regex`) to match one grapheme cluster:

```python
import regex
regex.findall(r'\X', 'é👨‍👩‍👧')  # ['é', '👨‍👩‍👧']
```

In JavaScript, use the `/v` flag (ES2024) with `\p{RGI_Emoji}` for emoji matching.

## Testing and Debugging

1. **Start simple**: Build incrementally — test each part before combining
2. **Use test-driven regex**: Write match/no-match pairs first, then build the pattern
3. **Use regex101.com**: Select the correct flavor. Use the debugger to trace backtracking
4. **Test edge cases**: Empty string, single char, max length, Unicode, newlines
5. **Test pathological input**: Repeat near-match chars to detect backtracking (`"a" * 50 + "!"`)

### Unit Test Template (Python)

```python
import re, pytest

PATTERN = re.compile(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')

@pytest.mark.parametrize("email,expected", [
    ("user@example.com", True),
    ("a.b+c@sub.domain.org", True),
    ("@missing.com", False),
    ("no-at-sign", False),
    ("user@.com", False),
])
def test_email(email, expected):
    assert bool(PATTERN.fullmatch(email)) == expected
```

### Debugging Checklist

- Verify the regex flavor matches your runtime
- Check for unescaped special characters: `. * + ? ( ) [ ] { } ^ $ | \`
- Confirm anchors: Use `^...$` for full-string validation
- Inspect greedy vs lazy behavior when matches are too long or too short
- Profile with large inputs to catch hidden backtracking

## Anti-Patterns

### When NOT to Use Regex

- **Parsing HTML/XML/JSON**: Use a proper parser. Regex cannot handle nested structures
- **Simple string checks**: Use `str.startswith()`, `str.endswith()`, `in` operator
- **Arithmetic validation**: Use parseInt, not regex, for "number between 1-999"
- **Complex date validation**: Regex cannot verify leap years — use date libraries
- **Recursive grammars**: Use PEG, ANTLR, or tree-sitter instead

### Regex Smells and Fixes

| Smell                           | Fix                                        |
|---------------------------------|--------------------------------------------|
| Pattern exceeds ~120 chars      | Break into named parts or use verbose mode |
| Nested quantifiers `(a+)+`     | Flatten: `a+`                              |
| Multiple `.*` segments          | Replace with negated classes `[^x]*`       |
| Duplicated alternation `(a\|a)` | Deduplicate or restructure                |
| No anchors on validation regex  | Add `^` and `$`                            |
| Using regex for a 3-line parser | Write explicit parsing code                |

### Maintainability

- Prefer named groups over numbered groups for anything used in code
- Use `(?#...)` inline comments or verbose mode (`/x`, `re.VERBOSE`)
- Store patterns as named constants, not inline literals
- Document what the pattern matches and what it rejects
- Include test cases alongside every production regex
