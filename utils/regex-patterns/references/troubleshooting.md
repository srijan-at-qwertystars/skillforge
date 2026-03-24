# Regex Troubleshooting Guide

> Common regex pitfalls, catastrophic backtracking, ReDoS attacks,
> debugging strategies, and performance profiling.

## Table of Contents

- [1. Catastrophic Backtracking Deep Dive](#1-catastrophic-backtracking-deep-dive)
- [2. ReDoS Attack Patterns](#2-redos-attack-patterns)
- [3. Common Mistakes](#3-common-mistakes)
- [4. Debugging Strategies](#4-debugging-strategies)
- [5. Performance Profiling](#5-performance-profiling)
- [6. Encoding and Unicode Issues](#6-encoding-and-unicode-issues)
- [7. Engine-Specific Gotchas](#7-engine-specific-gotchas)
- [8. Fixing Vulnerable Patterns](#8-fixing-vulnerable-patterns)

---

## 1. Catastrophic Backtracking Deep Dive

### What Is Backtracking?

Regex engines (NFA-based) try to match a pattern by exploring paths. When a
path fails, the engine **backtracks** — returns to the last decision point
and tries an alternative. This is normal and usually fast.

**Catastrophic backtracking** occurs when the number of paths grows
exponentially with input length, causing the engine to freeze.

### The Fundamental Cause

Catastrophic backtracking requires **two conditions**:
1. **Ambiguity** — multiple ways the pattern can match the same characters
2. **Failure** — the overall match ultimately fails, forcing the engine
   to try every possible path

### Anatomy of an Exponential Pattern

```regex
(a+)+$
```

Against input `aaaaaaaaaaaaaaaaX`:

| Input length | Paths tried    | Time        |
|-------------|----------------|-------------|
| 10          | ~1,024         | <1ms        |
| 20          | ~1,048,576     | ~1s         |
| 25          | ~33,554,432    | ~30s        |
| 30          | ~1,073,741,824 | ~17 min     |
| 40          | ~1.1 trillion  | ~12 days    |

**Why?** The engine tries every way to divide `aaaa...` between the inner
`a+` and the outer `+`. For n characters, there are 2^(n-1) ways to split.

### Step-by-Step Trace

Pattern: `(a+)+b` — Input: `aaac`

```
Attempt 1: (aaa)+b  → inner matches "aaa", outer 1 rep, b fails at 'c'
Attempt 2: (aa)(a)+b → inner matches "aa", then "a", b fails
Attempt 3: (a)(aa)+b → inner matches "a", then "aa", b fails
Attempt 4: (a)(a)(a)+b → inner matches "a","a","a", b fails
... and so on for every possible partition
```

### Categories of Dangerous Patterns

#### 1. Nested Quantifiers
```
DANGEROUS:  (a+)+       (a*)*       (a+)*       (a*)+
SAFE:       a+          a*          (captured once is fine)
```

#### 2. Overlapping Alternation with Quantifier
```
DANGEROUS:  (a|a)+      (a|ab)+     (\d|\d\d)+
SAFE:       a+          ab?+        \d+
```

#### 3. Adjacent Overlapping Quantifiers
```
DANGEROUS:  \d+\d+\d+   .*.*        \w+\s*\w+
             (when they can match the same chars)
SAFE:       \d+          .*          \w+\s+\w+
             (when boundaries are unambiguous)
```

#### 4. Quantified Group with Overlapping End
```
DANGEROUS:  (\d+)+$     (.*?,)+$    ([a-z]+\s*)+$
SAFE:       \d+$        [^,]+(,[^,]+)*$
```

### Measuring Backtracking

**Python timing test:**
```python
import re, time

pattern = re.compile(r'(a+)+b')
for n in range(5, 30):
    s = 'a' * n + 'c'
    start = time.time()
    pattern.search(s)
    elapsed = time.time() - start
    print(f"n={n:2d}  time={elapsed:.4f}s")
    if elapsed > 5:
        print("  CATASTROPHIC — aborting")
        break
```

**JavaScript timing test:**
```javascript
const re = /(a+)+b/;
for (let n = 5; n < 35; n++) {
    const s = 'a'.repeat(n) + 'c';
    const t0 = performance.now();
    re.test(s);
    const ms = performance.now() - t0;
    console.log(`n=${n}  time=${ms.toFixed(1)}ms`);
    if (ms > 5000) { console.log('  CATASTROPHIC'); break; }
}
```

---

## 2. ReDoS Attack Patterns

### What Is ReDoS?

**Regular Expression Denial of Service (ReDoS)** exploits catastrophic
backtracking to exhaust CPU resources. An attacker sends crafted input
that triggers exponential processing in a vulnerable regex.

### Real-World Incidents

| Year | Company    | Impact                                   | Vulnerable Pattern              |
|------|-----------|------------------------------------------|---------------------------------|
| 2016 | Stack Overflow | Server outage, threads locked      | HTML tag validation regex       |
| 2019 | Cloudflare | 27-minute global outage                 | WAF rule: `.*(?:.*=.*)`        |
| 2021 | Various   | npm packages with ReDoS in validators    | Email/URL validation regexes   |

### Attack Anatomy

1. Attacker identifies a regex used on user input (in validation, parsing, WAF)
2. Attacker crafts input that forces maximum backtracking
3. A single request can consume a server thread for minutes/hours
4. Multiple requests create a denial of service

### Common Vulnerable Validators

```regex
# Email (vulnerable):
^([a-zA-Z0-9])(([\-.]|[_]+)?([a-zA-Z0-9]+))*(@){1}[a-z0-9]+[.]{1}(([a-z]{2,3})|([a-z]{2,3}[.]{1}[a-z]{2,3}))$
# Attack input: "aaaaaaaaaaaaaaaaaaaaaaaa!"

# URL (vulnerable):
^(https?://)?([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(/.*)?$
# Attack input: "http://aaaaaaaaaaaaaaaaaaaaaaaaa"

# HTML comment (vulnerable):
<!--.*?-->|<!--[\s\S]*?-->
# Attack input: "<!--" + "a" * 50000
```

### ReDoS-Safe Alternatives

```regex
# Email (safe — simple, practical):
^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$

# URL (safe):
^https?://[^\s]+$

# Or better: use RE2 engine (Go, Rust) for untrusted input
```

### Prevention Checklist

1. ☐ Audit all regex applied to user input
2. ☐ Run static analysis tools (see below)
3. ☐ Limit input length before regex processing
4. ☐ Set execution timeouts where possible
5. ☐ Use RE2-based engines for untrusted input
6. ☐ Test with adversarial inputs during code review
7. ☐ Avoid nested quantifiers on overlapping character sets

### Static Analysis Tools

| Tool                   | Language   | How to Use                           |
|------------------------|-----------|--------------------------------------|
| `safe-regex`           | npm       | `npx safe-regex "pattern"`           |
| `vuln-regex-detector`  | npm       | `npx vuln-regex-detector "pattern"`  |
| `recheck`              | npm/CLI   | `npx recheck "pattern"`             |
| `rxxr2`                | Haskell   | Academic tool for ReDoS analysis     |
| `dlint` (Deno)         | Deno      | Built-in regex safety linting        |
| `semgrep`              | Multi     | Custom rules for regex patterns      |

---

## 3. Common Mistakes

### Greedy vs Lazy Quantifiers

```regex
# Greedy (default): matches as MUCH as possible
<.*>
# Input: "<b>bold</b>" → matches "<b>bold</b>" (entire string)

# Lazy: matches as LITTLE as possible
<.*?>
# Input: "<b>bold</b>" → matches "<b>" then "</b>" (two matches)
```

**Common mistake:** Using `.*` when you mean `.*?`, or vice versa.

**Better:** Use negated character class instead of lazy quantifier:
```regex
<[^>]*>     # Matches a single tag — faster and clearer than <.*?>
```

### Forgetting to Escape Metacharacters

```regex
# WRONG — . matches ANY character:
192.168.1.1

# RIGHT — \. matches literal dot:
192\.168\.1\.1

# Characters that MUST be escaped in regex:
. * + ? ^ $ { } [ ] ( ) | \
```

### Anchoring Mistakes

```regex
# WRONG — matches "abc" anywhere in string:
\d{3}
# Input: "abc123def" → matches "123"

# RIGHT — full string match:
^\d{3}$
# Input: "abc123def" → no match
# Input: "123" → match
```

### Character Class Mistakes

```regex
# WRONG — dash creates a range:
[a-z-_]  # This works but only because - is at the end/start
[a-_]    # WRONG — range from 'a' to '_' (depends on encoding)

# RIGHT — put dash first, last, or escape it:
[-a-z_]  or  [a-z_-]  or  [a-z\-_]
```

### Backreference vs Capture Group Confusion

```regex
# (\d+) is a CAPTURE GROUP — saves matched text
# \1 is a BACKREFERENCE — matches the same text captured by group 1

# WRONG expectation: "any digit then any digit"
(\d)\1
# Input: "12" → NO match (expects same digit repeated)
# Input: "11" → match
```

### Multiline Mode Confusion

```regex
# ^ and $ normally match start/end of ENTIRE STRING
# With /m flag, they match start/end of each LINE

# Common mistake: expecting ^ to match line start without /m
/^Error:/      # Only matches if "Error:" is at start of string
/^Error:/m     # Matches "Error:" at start of any line
```

### The "." Doesn't Match Newline Trap

```regex
# . matches everything EXCEPT \n by default
# Common mistake: expecting .* to span lines

/START(.*)END/      # Won't match across lines
/START(.*)END/s     # With /s (dotall), . matches \n too
/START([\s\S]*)END/ # Alternative without /s flag
```

### Regex vs String Escaping (Double Escaping)

```java
// Java needs double escaping in string literals:
Pattern.compile("\\d+");      // RIGHT — regex sees \d+
Pattern.compile("\d+");       // WRONG — \d is not a valid Java escape

// Python raw strings avoid this:
re.compile(r'\d+')            // RIGHT — raw string, no double escaping
re.compile('\\d+')            // Also works but harder to read
```

### Catastrophic Alternation Order

```regex
# Order matters for first-match semantics:
# WRONG — short alternative matches first:
(do|done)      # Input: "done" → matches "do" (in some engines)

# RIGHT — put longer alternative first:
(done|do)      # Input: "done" → matches "done"

# Or use anchoring/word boundaries:
\b(do|done)\b  # Word boundary ensures full word match
```

---

## 4. Debugging Strategies

### Strategy 1: Divide and Conquer

Break complex regex into parts and test each independently:

```python
import re

full_pattern = r'^(\w+)\s+(\d{4}-\d{2}-\d{2})\s+"([^"]+)"$'

# Test each part:
assert re.search(r'\w+', 'hello')
assert re.search(r'\d{4}-\d{2}-\d{2}', '2024-01-15')
assert re.search(r'"([^"]+)"', '"test message"')

# Then combine gradually:
assert re.search(r'(\w+)\s+(\d{4}-\d{2}-\d{2})', 'hello 2024-01-15')
```

### Strategy 2: Use Python re.DEBUG

```python
import re
re.compile(r'(?P<year>\d{4})-(?P<month>\d{2})', re.DEBUG)
```

Output:
```
SUBPATTERN 1 0 0
  NAMED_BACKREF 'year'
  MAX_REPEAT 4 4
    IN
      CATEGORY CATEGORY_DIGIT
LITERAL 45
SUBPATTERN 2 0 0
  NAMED_BACKREF 'month'
  MAX_REPEAT 2 2
    IN
      CATEGORY CATEGORY_DIGIT
```

### Strategy 3: Use regex101.com Debugger

1. Paste pattern and test string at regex101.com
2. Select the correct flavor (PCRE2, JavaScript, Python, Go)
3. Click "Regex Debugger" to see step-by-step matching
4. Check "Match Information" for group captures
5. Look for yellow warnings about potential backtracking

### Strategy 4: Add Verbose Mode for Readability

```python
pattern = re.compile(r"""
    ^                       # Start of string
    (?P<protocol>https?)    # HTTP or HTTPS
    ://                     # Separator
    (?P<domain>             # Domain group
        (?:www\.)?          # Optional www prefix
        [a-zA-Z0-9.-]+     # Domain name
        \.[a-zA-Z]{2,}     # TLD
    )
    (?P<path>/[^\s?#]*)?   # Optional path
    (?P<query>\?[^\s#]*)?  # Optional query string
    (?P<fragment>\#\S*)?   # Optional fragment
    $                       # End of string
""", re.VERBOSE)
```

### Strategy 5: Build Incrementally with Tests

```python
import re

def test_pattern(pattern, should_match, should_not_match):
    compiled = re.compile(pattern)
    for s in should_match:
        assert compiled.fullmatch(s), f"Should match: {s!r}"
    for s in should_not_match:
        assert not compiled.fullmatch(s), f"Should NOT match: {s!r}"
    print(f"✅ Pattern OK: {pattern}")

test_pattern(
    r'\d{4}-\d{2}-\d{2}',
    should_match=['2024-01-15', '1999-12-31'],
    should_not_match=['24-1-15', '2024/01/15', 'abcd-ef-gh']
)
```

### Strategy 6: Visualize with Railroad Diagrams

Use debuggex.com or regexper.com to generate visual railroad diagrams
that show the structure of your regex as a flowchart.

---

## 5. Performance Profiling

### Benchmarking Regex Performance

```python
import re, time, statistics

def benchmark_regex(pattern_str, test_strings, iterations=1000):
    pattern = re.compile(pattern_str)
    times = []
    for _ in range(iterations):
        start = time.perf_counter_ns()
        for s in test_strings:
            pattern.search(s)
        elapsed = time.perf_counter_ns() - start
        times.append(elapsed / 1_000_000)  # Convert to ms

    print(f"Pattern: {pattern_str}")
    print(f"  Mean:   {statistics.mean(times):.3f} ms")
    print(f"  Median: {statistics.median(times):.3f} ms")
    print(f"  StdDev: {statistics.stdev(times):.3f} ms")
    print(f"  Min:    {min(times):.3f} ms")
    print(f"  Max:    {max(times):.3f} ms")

test_data = ['user@example.com', 'invalid@@', 'a' * 100 + '@test.com']

benchmark_regex(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$', test_data)
benchmark_regex(r'^[\w.+-]+@[\w.-]+\.\w{2,}$', test_data)
```

### Performance Tips

1. **Compile once, reuse always**
   ```python
   # Module level — compiled once at import:
   EMAIL_RE = re.compile(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')
   ```

2. **Anchor when possible** — `^\d+$` is faster than `\d+` for validation

3. **Use character classes over alternation**
   ```regex
   # Slower:  (a|b|c|d|e)
   # Faster:  [a-e]
   ```

4. **Avoid catastrophic patterns** — see section 1

5. **Use non-capturing groups** — `(?:...)` vs `(...)` when you don't need captures

6. **Be specific** — `[0-9]{4}` is better than `.{4}` for matching years

7. **Prefer negated classes** — `[^"]*"` over `.*?"` (avoids backtracking)

8. **Limit input before regex** — `if len(s) > 1000: reject()` before applying

### Detecting Slow Patterns with Timeout

```python
import signal

class RegexTimeout(Exception):
    pass

def timeout_handler(signum, frame):
    raise RegexTimeout("Regex execution timed out")

def safe_match(pattern, text, timeout_sec=1):
    signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(timeout_sec)
    try:
        return pattern.search(text)
    except RegexTimeout:
        return None
    finally:
        signal.alarm(0)
```

---

## 6. Encoding and Unicode Issues

### UTF-8 Byte Boundary Mismatches

```python
# WRONG — matching on bytes instead of characters:
text_bytes = "café".encode('utf-8')  # b'caf\xc3\xa9'
re.search(rb'.', text_bytes)         # Matches single BYTE, not character

# RIGHT — match on str (Unicode):
re.search(r'.', "café")              # Matches 'c' (one character)
```

### Unicode Normalization

```python
import unicodedata

# These look identical but are different:
s1 = "café"           # 'é' as single codepoint (U+00E9)
s2 = "cafe\u0301"     # 'e' + combining acute accent (U+0301)

re.search(r'café', s1)  # ✅ matches
re.search(r'café', s2)  # ❌ may not match!

# Fix: normalize before matching:
s_normalized = unicodedata.normalize('NFC', s2)
re.search(r'café', s_normalized)  # ✅ matches
```

### Case-Insensitive Matching Across Scripts

```python
# Python re.IGNORECASE handles basic ASCII:
re.search(r'hello', 'HELLO', re.I)  # ✅

# But for full Unicode case folding:
import regex  # pip install regex
regex.search(r'straße', 'STRASSE', regex.IGNORECASE)  # ✅

# Standard re module may not handle this correctly
```

### Common Unicode Pitfalls

| Issue | Problem | Solution |
|-------|---------|----------|
| `\w` matches only ASCII | `\w` in some engines is `[a-zA-Z0-9_]` | Use `re.UNICODE` flag or `\p{L}` |
| Emoji are multi-codepoint | `👨‍👩‍👧‍👦` is 7 codepoints | Use `\X` (grapheme cluster) in PCRE |
| CRLF vs LF | `$` may not match before `\r\n` | Use `\r?\n` or `\R` (PCRE) |
| BOM marker | `\xEF\xBB\xBF` at file start | Strip BOM before matching |

---

## 7. Engine-Specific Gotchas

### JavaScript

- No `re.VERBOSE` / `x` flag — can't add comments in regex
- `String.match()` with `/g` returns strings, not match objects
- Use `matchAll()` for full match objects with `/g`
- `.test()` with `/g` flag advances `lastIndex` — stateful!
  ```javascript
  const re = /a/g;
  re.test('a');  // true,  lastIndex = 1
  re.test('a');  // false! lastIndex reset
  ```

### Python

- `re.match()` only matches at start of string
- `re.search()` matches anywhere — usually what you want
- `re.fullmatch()` matches the entire string (Python 3.4+)
- `re.findall()` returns strings/tuples, not match objects
- Use `re.finditer()` for match objects

### Go

- RE2 engine — no lookahead, lookbehind, or backreferences
- `regexp.Compile()` returns error; `regexp.MustCompile()` panics
- No `Replace` with callback — use `ReplaceAllStringFunc()`
- Named groups need manual index mapping via `SubexpNames()`

### Java

- Verbose with double-escaping: `"\\d+"` for `\d+`
- `Pattern.MULTILINE` only affects `^` and `$`
- `Pattern.DOTALL` makes `.` match `\n`
- `Pattern.COMMENTS` enables verbose mode
- No built-in timeout — wrap in a thread with timeout

### Rust

- regex crate uses RE2-like engine — linear time
- No lookahead/lookbehind/backreferences
- `fancy-regex` crate adds these but loses O(n) guarantee
- Must handle `Result` from `Regex::new()` — pattern compilation can fail

---

## 8. Fixing Vulnerable Patterns

### Pattern Transformation Rules

| Vulnerable Pattern | Safe Alternative | Why |
|---|---|---|
| `(a+)+` | `a+` | Remove nested quantifier |
| `(a\|a)+` | `a+` | Remove overlapping alternation |
| `(a\|ab)+` | `a(b?a)*b?` | Make alternatives exclusive |
| `(.*a){n}` | Count `a` occurrences in code | Avoid quantified greedy |
| `(\d+)+$` | `\d+$` | Flatten nested quantifier |
| `\s*(.*)\s*` | `\S(?:.*\S)?` or `.trim()` | Use string methods |
| `.*\d.*\d.*` | `(?:.*?\d){2}` or check in code | Reduce backtracking |

### Before/After Examples

**Email validation:**
```regex
# BEFORE (vulnerable):
^([a-zA-Z0-9])(([\-.]|[_]+)?([a-zA-Z0-9]+))*(@)([a-zA-Z0-9]+)...

# AFTER (safe):
^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$
```

**URL validation:**
```regex
# BEFORE (vulnerable):
^(https?://)?([a-zA-Z0-9]+\.)+[a-zA-Z]{2,}(/.*)?$

# AFTER (safe):
^https?://[^\s/$.?#][^\s]*$
```

**HTML stripping:**
```regex
# BEFORE (vulnerable):
<([a-z]+)(\s+[a-z]+="[^"]*")*\s*>

# AFTER (safe):
<[^>]+>
```
