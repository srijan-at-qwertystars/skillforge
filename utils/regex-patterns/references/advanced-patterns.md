# Advanced Regex Patterns

> Deep dive into advanced regular expression constructs beyond basic matching.
> Covers PCRE, RE2, and engine-specific features.

## Table of Contents

- [1. Recursive Patterns](#1-recursive-patterns)
- [2. Conditional Patterns](#2-conditional-patterns)
- [3. Atomic Groups](#3-atomic-groups)
- [4. Possessive Quantifiers](#4-possessive-quantifiers)
- [5. Subroutine Calls](#5-subroutine-calls)
- [6. Branch Reset Groups](#6-branch-reset-groups)
- [7. Advanced Backreferences](#7-advanced-backreferences)
- [8. PCRE vs RE2 Differences](#8-pcre-vs-re2-differences)
- [9. Engine Support Matrix](#9-engine-support-matrix)

---

## 1. Recursive Patterns

Recursive patterns allow a regex to reference itself, enabling matching of nested
structures that regular expressions normally cannot handle (e.g., balanced brackets).

**Syntax:**
- `(?R)` or `(?0)` — recurse the entire pattern
- `(?1)`, `(?2)` — recurse into numbered group 1, 2, etc.
- `(?&name)` — recurse into named group

**Supported:** PCRE, Perl, .NET, Oniguruma (Ruby). **NOT supported:** JavaScript, Python `re`, Go, Rust.

### Balanced Parentheses

```regex
\((?:[^()]+|(?R))*\)
```

Breakdown:
- `\(` — literal opening paren
- `(?:` — non-capturing group:
  - `[^()]+` — one or more non-paren characters
  - `|(?R)` — OR recurse the entire pattern (for nested parens)
- `)*` — zero or more times
- `\)` — literal closing paren

**Test:**
- `(a(b(c)d)e)` → full match ✅
- `(a(b)` → no full match (unbalanced) ✅

### Nested HTML-like Tags (Simplified)

```regex
<(\w+)>(?:[^<]+|(?R))*<\/\1>
```

Matches self-nesting tags like `<div><div>inner</div></div>`.

### Recursion into Specific Groups

```regex
(?<block>\{(?:[^{}]+|(?&block))*\})
```

Named group `block` matches balanced curly braces. `(?&block)` recurses
into the named group only, not the whole pattern.

### Depth-Limited Recursion

PCRE does not natively limit recursion depth in the pattern, but you can
control it programmatically:
- PHP: `ini_set('pcre.recursion_limit', 100);`
- PCRE2 API: `pcre2_set_recursion_limit()`

### Practical Example: JSON-like Nested Structures

```regex
(?<value>"[^"]*"|[0-9]+|(?&object)|(?&array))
(?<pair>\s*"[^"]*"\s*:\s*(?&value)\s*)
(?<object>\{\s*(?&pair)(?:,(?&pair))*\s*\})
(?<array>\[\s*(?&value)(?:,\s*(?&value))*\s*\])
```

> ⚠️ This is educational. Use a real JSON parser in production.

---

## 2. Conditional Patterns

Conditional patterns match different sub-patterns based on whether a
previous group matched or a lookaround succeeds.

**Syntax:** `(?(condition)yes-pattern|no-pattern)`

**Conditions can be:**
- Group number: `(?(1)yes|no)` — did group 1 participate?
- Group name: `(?(<name>)yes|no)` or `(?(name)yes|no)`
- Lookahead: `(?(?=lookahead)yes|no)`
- Recursion: `(?(R)yes|no)` — are we inside a recursion?
- `(?(DEFINE)...)` — define groups without matching (PCRE)

**Supported:** PCRE, Perl, .NET, Python `re`. **NOT supported:** JavaScript, Go, Rust.

### Optional Area Code with Conditional

```regex
(\()?\d{3}(?(1)\)|-)\d{3}-\d{4}
```

- If `(` was matched (group 1), expect `)` after area code
- Otherwise, expect `-`
- `(555)123-4567` → match ✅
- `555-123-4567` → match ✅
- `(555-123-4567` → no match ✅

### Define Block (PCRE)

The `DEFINE` block lets you declare named groups as "subroutines" without
actually matching anything at the define site:

```regex
(?(DEFINE)
  (?<year>\d{4})
  (?<month>0[1-9]|1[0-2])
  (?<day>0[1-9]|[12]\d|3[01])
)
(?&year)-(?&month)-(?&day)
```

This separates pattern definition from usage, improving readability.

### Conditional with Lookahead

```regex
(?(?<=USD\s)\d+\.\d{2}|\d+)
```

If preceded by "USD ", match decimal number; otherwise match integer.

---

## 3. Atomic Groups

Atomic groups prevent the regex engine from backtracking into the group
once it has matched. This can dramatically improve performance and change
matching semantics.

**Syntax:** `(?>pattern)`

**Supported:** PCRE, Perl, Java, .NET, Ruby. **NOT supported:** JavaScript, Python `re`, Go, Rust.

### How Atomic Groups Work

```regex
(?>a+)b
```

Against input `aaab`:
1. `a+` greedily matches `aaa`
2. Engine tries to match `b` — succeeds → overall match

Against input `aaac`:
1. `a+` greedily matches `aaa`
2. Engine tries to match `b` — fails
3. **Without atomic:** engine backtracks, tries `aa`, then `a`, etc.
4. **With atomic:** engine does NOT backtrack into the group — fails immediately

### Performance Benefit

```regex
# Vulnerable to catastrophic backtracking:
(\d+)+$

# Safe with atomic group:
(?>(\d+))+$
```

The atomic group prevents the engine from trying different ways to split
digit sequences among the inner and outer quantifiers.

### Atomic Group vs Possessive Quantifier

These are equivalent:
```
(?>a+)    ≡    a++
(?>a*)    ≡    a*+
(?>a?)    ≡    a?+
```

Possessive quantifiers are syntactic sugar for atomic groups around
a single quantified token.

---

## 4. Possessive Quantifiers

Possessive quantifiers match as much as possible and **never give back**
(no backtracking). They are a concise alternative to atomic groups.

**Syntax:** Append `+` to any quantifier:
- `*+` — possessive star (0 or more, no backtrack)
- `++` — possessive plus (1 or more, no backtrack)
- `?+` — possessive optional (0 or 1, no backtrack)
- `{n,m}+` — possessive range

**Supported:** PCRE, Perl, Java, .NET (some versions). **NOT supported:** JavaScript, Python `re`, Go, Rust.

### Examples

```regex
# Match quoted string efficiently:
"[^"]*+"
# The *+ prevents backtracking into the character class

# Match a float that MUST have a decimal:
\d++\.\d++
# Each \d++ locks in its digits — no ambiguity about where integer ends

# Efficient whitespace consumption:
\s++
# Once whitespace is consumed, the engine won't try giving characters back
```

### When to Use Possessive Quantifiers

Use them when:
1. You know backtracking into the quantified part can never lead to a match
2. The quantified token and what follows it are mutually exclusive
   (e.g., `[^"]*+"` — the `[^"]` class and the `"` delimiter can't overlap)
3. You want to prevent ReDoS on user-supplied patterns

### Pitfall: Changing Match Semantics

```regex
# Greedy: "a.*b" against "aXbYb" → matches "aXbYb"
# Possessive: "a.*+b" against "aXbYb" → NO MATCH
# Because .*+ consumes everything including the final 'b', then can't backtrack
```

---

## 5. Subroutine Calls

Subroutine calls let you re-use a defined sub-pattern elsewhere in the regex,
similar to function calls in programming.

**Syntax:**
- `(?1)` — call group 1 as subroutine
- `(?&name)` — call named group as subroutine
- `(?P>name)` — Python-esque named call (Perl/PCRE)
- `\g<name>` — Oniguruma/Ruby syntax

**Supported:** PCRE, Perl, Ruby (Oniguruma). **NOT supported:** JavaScript, Python `re`, Go, Rust, Java.

### Difference: Subroutine Call vs Backreference

```regex
# Backreference \1 — matches the SAME TEXT as group 1 captured:
(abc)\1        # matches "abcabc" only

# Subroutine (?1) — re-executes the PATTERN of group 1:
(abc)(?1)      # matches "abcabc", "abcabc" (same in this case)
               # but with (a|b)(?1), matches "ab", "ba", "aa", "bb"
```

### Practical: Reusable Date Components

```regex
(?(DEFINE)
  (?<y>\d{4})
  (?<m>0[1-9]|1[0-2])
  (?<d>0[1-9]|[12]\d|3[01])
)
# Match date range: YYYY-MM-DD to YYYY-MM-DD
(?&y)-(?&m)-(?&d)\s+to\s+(?&y)-(?&m)-(?&d)
```

### Alternation with Subroutines

```regex
(?<ipv4>(?:\d{1,3}\.){3}\d{1,3})
(?<ipv6>(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4})
# Match either format:
(?&ipv4)|(?&ipv6)
```

---

## 6. Branch Reset Groups

Branch reset groups cause all alternatives within the group to share
the same capturing group numbers, starting from the same index.

**Syntax:** `(?|alternative1|alternative2|...)`

**Supported:** PCRE, Perl, PHP. **NOT supported:** JavaScript, Python `re`, Go, Rust, Java.

### Problem Without Branch Reset

```regex
# Without branch reset:
(?:(Mon)|(Tue)|(Wed)|(Thu)|(Fri))
# Mon → group 1, Tue → group 2, Wed → group 3, etc.
# You must check 5 different groups to find which day matched.
```

### Solution With Branch Reset

```regex
(?|(Mon)|(Tue)|(Wed)|(Thu)|(Fri))
# All alternatives capture into group 1
# Whichever matches, the result is always in group 1
```

### Practical: Parse Different Date Formats

```regex
(?|
  (\d{4})-(\d{2})-(\d{2})   |  # YYYY-MM-DD → groups 1,2,3
  (\d{2})/(\d{2})/(\d{4})   |  # MM/DD/YYYY → same groups 1,2,3
  (\d{2})\.(\d{2})\.(\d{4})    # DD.MM.YYYY → same groups 1,2,3
)
```

> Note: Groups within each branch share numbers, but the _semantics_
> differ (group 1 is year in branch 1, month in branch 2, day in branch 3).
> Name your groups to make this clearer.

---

## 7. Advanced Backreferences

### Standard Backreferences

```regex
(\w+)\s+\1       # Match repeated word: "the the" → match
```

### Named Backreferences

| Engine      | Syntax                    |
|-------------|---------------------------|
| PCRE/Perl   | `\k<name>`, `\k'name'`, `(?P=name)`, `\g{name}` |
| JavaScript  | `\k<name>`                |
| Python      | `(?P=name)`               |
| Java        | `\k<name>`                |
| .NET        | `\k<name>`, `\k'name'`    |

### Relative Backreferences (PCRE)

```regex
(a)(b)\g{-1}    # \g{-1} refers to the most recent group (b) → matches "abb"
(a)(b)\g{-2}    # \g{-2} refers to group before that (a) → matches "aba"
```

### Forward References

Some engines allow referencing a group that appears later in the pattern:

```regex
(\2two|(one))+   # Group 1 contains \2, which references group 2
                 # First iteration: \2 fails (not set), matches "one"
                 # Second iteration: \2 matches "one", then "two" literal
                 # Matches: "onetwo"
```

**Supported:** PCRE, Perl, Java, .NET. Very engine-specific behavior.

### Backreferences Inside Recursion (PCRE)

Inside a recursive call, backreferences refer to the current recursion level:

```regex
(?<q>['"]) .+? \k<q>   # Matches 'text' or "text" — backreference ensures
                        # closing quote matches opening quote
```

### Conditional Backreferences

```regex
(<)?href\s*=\s*(?(1)[^>]*>|[^\s]*)
# If < was matched (group 1), match up to >; otherwise match non-whitespace
```

---

## 8. PCRE vs RE2 Differences

### Architecture

| Aspect              | PCRE/PCRE2              | RE2                      |
|---------------------|-------------------------|--------------------------|
| Algorithm           | Backtracking NFA        | DFA/NFA hybrid           |
| Time complexity     | Exponential worst-case  | **O(n) guaranteed**      |
| Memory              | Stack-based (recursion) | Heap-based automaton     |
| Thread safety       | Needs care              | Built-in                 |
| JIT compilation     | Yes (PCRE2)             | No                       |

### Feature Comparison

| Feature                     | PCRE/PCRE2 | RE2  |
|-----------------------------|------------|------|
| Backreferences (`\1`)       | ✅         | ❌   |
| Recursive patterns (`(?R)`) | ✅         | ❌   |
| Atomic groups (`(?>...)`)   | ✅         | ❌   |
| Possessive quantifiers      | ✅         | ❌   |
| Lookahead `(?=...)`, `(?!...)`  | ✅     | ❌   |
| Lookbehind `(?<=...)`, `(?<!...)` | ✅   | ❌   |
| Conditionals `(?(...)...\|...)` | ✅     | ❌   |
| Branch reset `(?|...)`      | ✅         | ❌   |
| Subroutine calls            | ✅         | ❌   |
| Named groups                | ✅         | ✅   |
| Unicode properties `\p{}`   | ✅         | ✅   |
| Non-capturing groups        | ✅         | ✅   |
| Character classes           | ✅         | ✅   |
| Inline flags `(?i)`         | ✅         | ✅   |
| `\b` word boundary          | ✅         | ✅   |
| Comment groups `(?#...)`    | ✅         | ❌   |

### Which Languages Use Which Engine?

| Language   | Default Engine | Notes                                     |
|------------|---------------|-------------------------------------------|
| JavaScript | Custom (V8/SM)| Backtracking; most PCRE features minus recursion |
| Python     | Custom        | Backtracking; subset of PCRE features     |
| Java       | Custom        | Backtracking; atomic groups, possessive    |
| PHP        | PCRE/PCRE2    | Full PCRE support                         |
| Perl       | Custom (Perl) | The original; superset of PCRE            |
| Go         | **RE2**       | Linear time guaranteed                    |
| Rust       | **RE2-like**  | regex crate, linear time guaranteed       |
| Ruby       | Oniguruma     | Backtracking; rich feature set            |
| .NET       | Custom        | Backtracking; very rich (balancing groups) |

### When to Choose Each

**Use PCRE when:**
- You need backreferences, recursion, or lookarounds
- Input is trusted / bounded
- Pattern complexity requires advanced features

**Use RE2 when:**
- Processing untrusted input (user-supplied patterns)
- Performance guarantees are critical (SLA, real-time)
- Running in high-concurrency environments
- You can restructure patterns to avoid unsupported features

---

## 9. Engine Support Matrix

| Feature                   | JS  | Python | Java | Go  | Rust | PCRE | Perl | Ruby | .NET |
|---------------------------|-----|--------|------|-----|------|------|------|------|------|
| Basic quantifiers         | ✅  | ✅     | ✅   | ✅  | ✅   | ✅   | ✅   | ✅   | ✅   |
| Named groups              | ✅  | ✅     | ✅   | ✅  | ✅   | ✅   | ✅   | ✅   | ✅   |
| Non-capturing groups      | ✅  | ✅     | ✅   | ✅  | ✅   | ✅   | ✅   | ✅   | ✅   |
| Lookahead                 | ✅  | ✅     | ✅   | ❌  | ❌   | ✅   | ✅   | ✅   | ✅   |
| Lookbehind                | ✅  | ✅     | ✅   | ❌  | ❌   | ✅   | ✅   | ✅   | ✅   |
| Backreferences            | ✅  | ✅     | ✅   | ❌  | ❌   | ✅   | ✅   | ✅   | ✅   |
| Atomic groups             | ❌  | ❌     | ✅   | ❌  | ❌   | ✅   | ✅   | ✅   | ✅   |
| Possessive quantifiers    | ❌  | ❌     | ✅   | ❌  | ❌   | ✅   | ✅   | ✅   | ❌   |
| Recursive patterns        | ❌  | ❌     | ❌   | ❌  | ❌   | ✅   | ✅   | ✅   | ❌   |
| Conditionals              | ❌  | ✅     | ❌   | ❌  | ❌   | ✅   | ✅   | ✅   | ✅   |
| Branch reset              | ❌  | ❌     | ❌   | ❌  | ❌   | ✅   | ✅   | ❌   | ❌   |
| Subroutine calls          | ❌  | ❌     | ❌   | ❌  | ❌   | ✅   | ✅   | ✅   | ❌   |
| Unicode properties        | ✅  | ⚠️*   | ✅   | ✅  | ✅   | ✅   | ✅   | ✅   | ✅   |
| Inline flags              | ⚠️  | ✅     | ✅   | ✅  | ✅   | ✅   | ✅   | ✅   | ✅   |
| O(n) guarantee            | ❌  | ❌     | ❌   | ✅  | ✅   | ❌   | ❌   | ❌   | ❌   |

*Python `re` has limited `\p{}` support; use the third-party `regex` module for full Unicode properties.

---

## Workarounds for Missing Features

### Lookahead Alternative (Go/Rust)

Instead of `(?=pattern)`, capture and check in code:

```go
re := regexp.MustCompile(`(prefix)(rest)`)
match := re.FindStringSubmatch(input)
if match != nil && someCondition(match[1]) {
    // proceed with match[2]
}
```

### Backreference Alternative (Go/Rust)

Instead of `(\w+)\s+\1` to find repeated words:

```go
re := regexp.MustCompile(`(\w+)\s+(\w+)`)
matches := re.FindAllStringSubmatch(text, -1)
for _, m := range matches {
    if m[1] == m[2] {
        fmt.Printf("Repeated word: %s\n", m[1])
    }
}
```

### Recursive Pattern Alternative (All non-PCRE)

For balanced brackets, use a stack-based parser or iterative approach:

```python
def find_balanced(s, open_ch='(', close_ch=')'):
    depth = 0
    start = -1
    results = []
    for i, c in enumerate(s):
        if c == open_ch:
            if depth == 0:
                start = i
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0 and start != -1:
                results.append(s[start:i+1])
    return results
```
