---
name: regex-patterns
description: >
  Expert guidance for regular expressions, pattern matching, and text extraction/validation.
  Use when user needs regex, regular expressions, pattern matching, text extraction,
  validation patterns, string parsing with patterns, lookahead/lookbehind assertions,
  named capture groups, regex debugging, or ReDoS prevention. Covers JS, Python, Go, Rust, Java.
  NOT for simple string contains/indexOf checks, NOT for parsing structured formats like
  JSON/XML/HTML where a dedicated parser is better, NOT for CSS selectors or XPath queries,
  NOT for glob/fnmatch file patterns.
---

# Regex Patterns — Authoritative Reference

## Core Syntax Quick Reference

```
.          any char (except newline unless DOTALL/s flag)
\d \D      digit / non-digit          \w \W  word char / non-word
\s \S      whitespace / non-whitespace \b \B  word boundary / non-boundary
[abc]      character class             [^abc] negated class
[a-z]      range                       [a-zA-Z0-9_] union
(...)      capturing group             (?:...) non-capturing group
|          alternation                 \1 \2  backreference
^  $       start / end of string (or line with m flag)
*  +  ?    0+, 1+, 0-or-1             {n} {n,} {n,m}  exact/min/range
*? +? ??   lazy (non-greedy) versions  *+ ++ ?+  possessive (no backtrack)
```

## Language-Specific Syntax Differences

### Named Capturing Groups

| Language   | Syntax              | Replacement Ref | Notes                          |
|------------|----------------------|-----------------|--------------------------------|
| JavaScript | `(?<name>...)`       | `$<name>`       | ES2018+                        |
| Python     | `(?P<name>...)`      | `\g<name>`      | Also `(?P=name)` for backref   |
| Java       | `(?<name>...)`       | `${name}`       | Java 7+                        |
| Go         | `(?P<name>...)`      | —               | RE2 engine; use SubexpNames()  |
| Rust       | `(?P<name>...)`      | `$name`         | regex crate                    |

### Lookahead and Lookbehind

| Feature              | Syntax      | JS  | Python | Java | Go  | Rust |
|----------------------|-------------|-----|--------|------|-----|------|
| Positive lookahead   | `(?=...)`   | ✅  | ✅     | ✅   | ❌  | ❌   |
| Negative lookahead   | `(?!...)`   | ✅  | ✅     | ✅   | ❌  | ❌   |
| Positive lookbehind  | `(?<=...)`  | ✅  | ✅     | ✅   | ❌  | ❌   |
| Negative lookbehind  | `(?<!...)`  | ✅  | ✅     | ✅   | ❌  | ❌   |

Go (RE2) and Rust (regex crate) guarantee linear-time matching by disallowing
lookarounds and backreferences. Use capture groups + post-match logic instead.

### Flags / Modifiers

| Flag | Meaning            | JS     | Python          | Java                   |
|------|--------------------|--------|-----------------|------------------------|
| `i`  | case-insensitive   | `/i`   | `re.IGNORECASE` | `Pattern.CASE_INSENSITIVE` |
| `m`  | multiline ^/$      | `/m`   | `re.MULTILINE`  | `Pattern.MULTILINE`    |
| `s`  | dotall (. = \n)    | `/s`   | `re.DOTALL`     | `Pattern.DOTALL`       |
| `g`  | global (all match) | `/g`   | `re.findall()`  | `Matcher.find()` loop  |
| `u`  | unicode            | `/u`   | default Py3     | `Pattern.UNICODE_CHARACTER_CLASS` |
| `x`  | verbose/extended   | —      | `re.VERBOSE`    | `Pattern.COMMENTS`     |

Go: use `(?i)`, `(?m)`, `(?s)` inline prefixes. Rust: same inline syntax.

## Common Validated Patterns

### Email (practical, covers 99%+ real addresses)

```regex
^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$
```

- Input: `user@example.com` → match. `user@.com` → no match.
- For strict RFC 5322: use a library, not regex. Regex cannot fully validate RFC 5322.

### URL (HTTP/HTTPS)

```regex
^https?:\/\/[^\s/$.?#].[^\s]*$
```

Stricter with domain validation:
```regex
^https?:\/\/(?:www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b[-a-zA-Z0-9()@:%_\+.~#?&\/=]*$
```

- Input: `https://example.com/path?q=1` → match. `ftp://x` → no match.

### IPv4 Address

```regex
^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$
```

- Input: `192.168.1.1` → match. `256.1.1.1` → no match.

### IPv6 Address (full form)

```regex
^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$
```

For compressed IPv6 (with ::), use a library — regex alone is fragile.

### ISO 8601 Date (YYYY-MM-DD)

```regex
^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$
```

- Input: `2024-01-15` → match. `2024-13-01` → no match.
- Does NOT validate leap years. Use date parsing libraries for that.

### US Phone Number

```regex
^(?:\+1[-.\s]?)?(?:\(\d{3}\)|\d{3})[-.\s]?\d{3}[-.\s]?\d{4}$
```

- Input: `(555) 123-4567`, `+1-555-123-4567`, `5551234567` → all match.

### International Phone (E.164)

```regex
^\+?[1-9]\d{1,14}$
```

### Password Strength (min 8 chars, upper+lower+digit+special)

```regex
^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]{8,}$
```

Uses lookaheads to assert each requirement independently.

### Semantic Version (semver)

```regex
^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([\da-zA-Z-]+(?:\.[\da-zA-Z-]+)*))?(?:\+([\da-zA-Z-]+(?:\.[\da-zA-Z-]+)*))?$
```

- Input: `1.2.3-beta.1+build.123` → match.

### UUID v4

```regex
^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$
```

Apply with `i` flag for case-insensitive matching.

### Hex Color

```regex
^#(?:[0-9a-fA-F]{3}){1,2}$
```

- Input: `#fff`, `#1a2b3c` → match. `#12345` → no match.

### Extracting Quoted Strings

```regex
"([^"\\]|\\.)*"
```

Handles escaped quotes. Input: `He said "hello \"world\""` → captures full quoted string.

### CSV Field Extraction

```regex
(?:^|,)(?:"([^"]*(?:""[^"]*)*)"|([^,]*))
```

Prefer a CSV parser library for production use.

## Lookahead and Lookbehind Patterns

### Password must contain digit but NOT start with digit
```regex
^(?=.*\d)(?![0-9]).*$
```

### Extract price after dollar sign (lookbehind)
```regex
(?<=\$)\d+(?:\.\d{2})?
```

- Input: `Price: $42.99` → captures `42.99`.
- For Go/Rust (no lookbehind): use a capture group instead:
  `\$(\d+(?:\.\d{2})?)` then extract group 1.

### Match word NOT followed by specific word
```regex
\bfoo(?!\s+bar)\b
```

- Input: `foo baz` → match. `foo bar` → no match.

### Match word NOT preceded by specific word
```regex
(?<!\bnot\s)\bgood\b
```

## Unicode Support

### Unicode Property Escapes (`\p{}`)

| Language   | Support      | Syntax Example         | Notes                         |
|------------|-------------|------------------------|-------------------------------|
| JavaScript | ✅ ES2018+  | `/\p{L}/u`             | Requires `u` flag             |
| Python re  | ❌          | —                      | Use `regex` module instead    |
| Python regex| ✅         | `\p{Emoji}`            | `pip install regex`           |
| Java       | ✅ partial  | `\p{IsLatin}`          | Limited emoji support         |
| Go         | ✅          | `\p{Latin}`            | RE2 supports Unicode cats     |
| Rust       | ✅          | `\p{Greek}`            | regex crate                   |

### Common Unicode Categories

```
\p{L}    any letter          \p{Lu}   uppercase letter
\p{Ll}   lowercase letter    \p{N}    any number
\p{P}    punctuation         \p{S}    symbol
\p{Z}    separator           \p{M}    mark (combining)
\p{Emoji} emoji codepoint    \p{Script=Han} CJK characters
```

### Match any letter across all scripts
```
JS:     /\p{L}+/gu
Python: regex.findall(r'\p{L}+', text)
Go:     regexp.MustCompile(`\pL+`)       // short form, no braces for single-char
Rust:   Regex::new(r"\p{L}+").unwrap()
```

### Strip diacritics pattern (match combining marks)
```regex
\p{M}
```

Normalize to NFD first, then remove `\p{M}` characters.

## Performance and Security

### Catastrophic Backtracking / ReDoS

Patterns vulnerable to exponential backtracking:

```
DANGEROUS: (a+)+         — nested quantifiers
DANGEROUS: (a|a)+        — overlapping alternation
DANGEROUS: (.*a){10}     — quantified greedy with constraint
DANGEROUS: (\d+)+$       — nested quantifier at end
```

**How to detect:** Input a long non-matching string (e.g., `"aaa...aab"` for `(a+)+b`).
If runtime grows exponentially with input length, pattern is vulnerable.

**Prevention rules:**
1. Never nest quantifiers: `(x+)+` → rewrite as `x+`
2. Never use overlapping alternations: `(a|ab)` → `ab?`
3. Use possessive quantifiers where supported: `a++` (Java, PCRE)
4. Use atomic groups: `(?>a+)` (Java, .NET, PCRE — NOT JS, Python, Go, Rust)
5. Limit input length before applying regex
6. Prefer RE2-based engines (Go, Rust) for untrusted input — guaranteed O(n)
7. Use static analysis tools: `safe-regex`, `vuln-regex-detector`, `recheck`
8. Set timeouts: Java `Matcher` has no built-in timeout; Python `regex` module
   supports `timeout` parameter; JS has no native timeout

### Performance Best Practices

- **Compile once, reuse:** Never compile regex inside loops.
  ```python
  # BAD
  for line in lines:
      re.match(r'\d+', line)
  # GOOD
  pattern = re.compile(r'\d+')
  for line in lines:
      pattern.match(line)
  ```
  ```go
  // GOOD — compile at package level
  var dateRe = regexp.MustCompile(`\d{4}-\d{2}-\d{2}`)
  ```

- **Anchor patterns** when checking full-string match: `^...$` avoids scanning.
- **Use non-capturing groups** `(?:...)` when you do not need the capture.
- **Be specific:** `[0-9]` or `\d` over `.` — reduces backtracking paths.
- **Avoid `.* ` at start** — use `[^X]*X` to match up to delimiter X.
- **Prefer `\b` word boundaries** over complex lookaround for word matching.
- **Lazy quantifiers** (`*?`, `+?`) are NOT always faster — they change match
  behavior, not necessarily performance. Use when you want shortest match.

## Regex vs. Parsers — When NOT to Use Regex

| Task                              | Use Regex? | Better Alternative              |
|-----------------------------------|------------|----------------------------------|
| Validate email format             | ✅ basic   | Library for full RFC compliance  |
| Parse JSON                        | ❌         | `JSON.parse()` / `json.loads()` |
| Parse HTML/XML                    | ❌         | DOM parser, BeautifulSoup, etc.  |
| Parse CSV                         | ⚠️ simple  | CSV library                      |
| Extract from log lines            | ✅         | —                                |
| Validate IP address               | ✅         | `ipaddress` module (Python)      |
| Parse programming language syntax | ❌         | Parser generator (ANTLR, PEG)   |
| Simple string contains check      | ❌         | `str.contains()` / `indexOf()`  |
| Match nested/recursive structures | ❌         | Parser (regex cannot count nesting) |
| Find/replace in text              | ✅         | —                                |
| Tokenize structured data          | ⚠️         | Lexer/parser                     |
| URL routing                       | ✅         | Framework router if available    |

**Rule of thumb:** If the grammar is regular (no nesting/recursion), regex works.
If context-free or context-sensitive, use a parser.

## Debugging and Testing Tools

- **regex101.com** — Test regex with explanation, debugger, multiple flavors
  (PCRE2, JS, Python, Go, Java, Rust). Shows match steps, group captures.
- **regexr.com** — JS-focused, good for learning with inline explanations.
- **debuggex.com** — Visual railroad diagrams for regex.
- **safe-regex (npm)** — Detect ReDoS-vulnerable patterns in JS.
- **recheck** — Cross-language ReDoS checker.
- **Python `re.DEBUG`** — Pass `re.DEBUG` flag to see compiled regex tree.

## Language-Specific API Cheatsheet

### JavaScript
```javascript
const re = /(?<year>\d{4})-(?<month>\d{2})/;
const m = '2024-01'.match(re);
// m.groups.year → '2024', m.groups.month → '01'
'hello world'.replace(/\b\w/g, c => c.toUpperCase()); // 'Hello World'
// matchAll for iteration:
for (const m of str.matchAll(/\d+/g)) { console.log(m[0], m.index); }
```

### Python
```python
import re
m = re.search(r'(?P<year>\d{4})-(?P<month>\d{2})', '2024-01')
m.group('year')   # '2024'
re.findall(r'\b\w+\b', 'hello world')  # ['hello', 'world']
re.sub(r'\d+', lambda m: str(int(m.group()) * 2), 'val=5')  # 'val=10'
```

### Go
```go
re := regexp.MustCompile(`(?P<year>\d{4})-(?P<month>\d{2})`)
match := re.FindStringSubmatch("2024-01")
yearIdx := re.SubexpIndex("year")
fmt.Println(match[yearIdx]) // "2024"
// ReplaceAllStringFunc for dynamic replacement
re.ReplaceAllStringFunc(s, strings.ToUpper)
```

### Rust
```rust
use regex::Regex;
let re = Regex::new(r"(?P<year>\d{4})-(?P<month>\d{2})").unwrap();
let caps = re.captures("2024-01").unwrap();
println!("{}", &caps["year"]); // "2024"
// Iterate all matches
for m in re.find_iter(text) { println!("{}", m.as_str()); }
```

### Java
```java
Pattern p = Pattern.compile("(?<year>\\d{4})-(?<month>\\d{2})");
Matcher m = p.matcher("2024-01");
if (m.find()) { System.out.println(m.group("year")); } // "2024"
// replaceAll with backreference
str.replaceAll("(\\w+)", "[$1]");
```

## Practical Recipes

### Strip HTML tags (simple — use a parser for complex HTML)
```regex
<[^>]+>
```
Input: `<b>bold</b>` → ` bold ` after replacement with empty string.

### Extract domain from URL
```regex
https?://(?:www\.)?([^/]+)
```
Input: `https://www.example.com/path` → group 1: `example.com`

### Match balanced parentheses (one level only)
```regex
\([^()]*\)
```
For nested parens, use a parser or recursive regex (PCRE/Perl only: `\((?:[^()]+|(?R))*\)`).

### Split CamelCase into words
```regex
(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])
```
Input: `parseHTMLDocument` → split points yield `parse`, `HTML`, `Document`.
For Go/Rust (no lookaround), use `[a-z][A-Z]` capture + manual split.

### Match multiline block between markers
```regex
(?s)BEGIN(.+?)END
```
The `(?s)` flag makes `.` match newlines. Use lazy `+?` to get shortest block.

### Remove duplicate whitespace
```regex
\s{2,}
```
Replace with single space. Input: `hello   world` → `hello world`.

### Validate strong password with specific error messages
Apply separate lookahead patterns and report which failed:
```javascript
const checks = [
  [/(?=.*[a-z])/, 'Must contain lowercase'],
  [/(?=.*[A-Z])/, 'Must contain uppercase'],
  [/(?=.*\d)/,    'Must contain digit'],
  [/(?=.{8,})/,   'Must be 8+ characters'],
];
const errors = checks.filter(([re]) => !re.test(pw)).map(([,msg]) => msg);
```

## Supplemental Resources

### references/

In-depth reference documents for advanced topics:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Recursive patterns,
  conditional patterns, atomic groups, possessive quantifiers, subroutine calls,
  branch reset groups, advanced backreferences, PCRE vs RE2 feature comparison,
  and engine support matrix.

- **[troubleshooting.md](references/troubleshooting.md)** — Catastrophic backtracking
  deep dive with step-by-step traces, ReDoS attack patterns and real-world incidents,
  common mistakes (greedy vs lazy, escaping, anchoring), debugging strategies,
  performance profiling, encoding/Unicode issues, and engine-specific gotchas.

- **[language-reference.md](references/language-reference.md)** — Side-by-side regex
  API comparison for JavaScript (RegExp, matchAll, named groups), Python (re module,
  compile, finditer, sub), Go (regexp package, RE2 differences), Rust (regex crate),
  and Java (Pattern/Matcher). Includes cross-language examples and migration guide.

### scripts/

Executable utility scripts (`chmod +x`):

- **[regex-tester.sh](scripts/regex-tester.sh)** — Bash script that tests a regex
  against input strings. Shows matches, capture groups, and timing. Supports
  `-i` (case-insensitive), `-g` (global), `-t` (timing), `-f` (file input).
  ```
  ./scripts/regex-tester.sh '\d{4}-\d{2}-\d{2}' '2024-01-15' 'not-a-date'
  ```

- **[redos-checker.py](scripts/redos-checker.py)** — Python script that analyzes
  regex patterns for ReDoS vulnerabilities. Static analysis detects nested quantifiers,
  overlapping alternation, and other dangerous constructs. Optional `--test` flag
  runs dynamic timing analysis.
  ```
  ./scripts/redos-checker.py '(a+)+b' --test
  ```

- **[pattern-generator.py](scripts/pattern-generator.py)** — Python script that
  generates common regex patterns (email, URL, phone, date, IP, etc.) formatted
  for JavaScript, Python, Go, Rust, or Java.
  ```
  ./scripts/pattern-generator.py email --lang javascript
  ./scripts/pattern-generator.py --all --lang go
  ```

### assets/

Copy-paste-ready reference files:

- **[common-patterns.json](assets/common-patterns.json)** — JSON file with 34
  validated regex patterns (email, URL, IPv4, IPv6, dates, phones, credit cards,
  SSN, ZIP codes, UUID, hex colors, semver, MAC address, JWT, etc.) with test strings.

- **[cheatsheet.md](assets/cheatsheet.md)** — Quick reference: metacharacters,
  quantifiers (greedy/lazy/possessive), character classes, assertions, lookarounds,
  groups, backreferences, flags, escape sequences, and common recipes.

- **[regex-flags-matrix.md](assets/regex-flags-matrix.md)** — Comparison matrix of
  regex flags across JavaScript, Python, Go, Rust, Java, PCRE, Ruby, and .NET.
  Covers inline flag syntax, flag combinations, global mode per language,
  verbose mode comparison, and Unicode flag details.

<!-- tested: pass -->
