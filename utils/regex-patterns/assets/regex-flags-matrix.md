# Regex Flags Matrix — Cross-Language Comparison

Side-by-side comparison of regex flags/modifiers across languages.

## Flag Equivalents

| Purpose            | JavaScript   | Python          | Go          | Rust        | Java                            | PCRE/Perl   | Ruby       | .NET                |
|--------------------|--------------|-----------------|-------------|-------------|----------------------------------|-------------|------------|---------------------|
| **Case-insensitive** | `/i`       | `re.IGNORECASE` / `re.I` | `(?i)` | `(?i)` | `Pattern.CASE_INSENSITIVE`     | `/i`        | `/i`       | `RegexOptions.IgnoreCase` |
| **Multiline** (^/$ per line) | `/m` | `re.MULTILINE` / `re.M` | `(?m)` | `(?m)` | `Pattern.MULTILINE`          | `/m`        | default¹   | `RegexOptions.Multiline` |
| **DotAll** (. matches \n) | `/s` (ES2018) | `re.DOTALL` / `re.S` | `(?s)` | `(?s)` | `Pattern.DOTALL`            | `/s`        | `/m`²      | `RegexOptions.Singleline` |
| **Global** (all matches) | `/g`  | `findall()`/`finditer()` | `FindAll*()` | `find_iter()` | `while(m.find())`        | `/g`        | `scan()`   | `Matches()`         |
| **Unicode**        | `/u`         | default (Py3)   | default     | default     | `UNICODE_CHARACTER_CLASS`        | `/u`        | default³   | default             |
| **Verbose/extended** | N/A        | `re.VERBOSE` / `re.X` | `(?x)` partial | `(?x)` | `Pattern.COMMENTS`          | `/x`        | `/x`       | `RegexOptions.IgnorePatternWhitespace` |
| **Sticky**         | `/y`         | N/A             | N/A         | N/A         | `\G` anchor + `find()`          | `\G` anchor | `\G`       | `\G` anchor         |
| **Indices** (match positions) | `/d` (ES2022) | `.span()` | `FindIndex()` | `.start()`/`.end()` | `.start()`/`.end()` | `@-`, `@+` | `.offset()` | `.Index`, `.Length` |
| **ASCII-only**     | N/A          | `re.ASCII` / `re.A` | default⁴ | N/A     | N/A                              | N/A         | N/A        | N/A                 |
| **Unicode sets**   | `/v` (ES2024)| N/A             | N/A         | N/A         | N/A                              | N/A         | N/A        | N/A                 |

**Notes:**
1. Ruby's `^`/`$` match line boundaries by default (like multiline in other langs).
2. Ruby uses `/m` for dotall (`.` matches `\n`), unlike other languages where `/m` is multiline.
3. Ruby regex is Unicode-aware when the source encoding is UTF-8.
4. Go RE2 defaults to UTF-8 but `\w`, `\d` match ASCII only unless you use `\p{}`.

## Inline Flag Syntax

Inline flags allow enabling modifiers within the pattern itself.

| Language   | Enable flags       | Disable flags       | Scoped flags            |
|------------|--------------------|---------------------|-------------------------|
| JavaScript | N/A (flags on `/`)  | N/A                 | N/A                     |
| Python     | `(?i)`, `(?m)`, `(?s)`, `(?x)` | N/A     | `(?i:pattern)` (Py 3.6+)|
| Go         | `(?i)`, `(?m)`, `(?s)` | `(?-i)`, `(?-m)`, `(?-s)` | `(?i:pattern)` |
| Rust       | `(?i)`, `(?m)`, `(?s)`, `(?x)` | `(?-i)`, etc. | `(?i:pattern)`  |
| Java       | `(?i)`, `(?m)`, `(?s)`, `(?x)` | `(?-i)`, etc. | `(?i:pattern)`  |
| PCRE       | `(?i)`, `(?m)`, `(?s)`, `(?x)` | `(?-i)`, etc. | `(?i:pattern)`  |
| Ruby       | `(?i)`, `(?m)`, `(?x)` | `(?-i)`, etc.    | `(?i:pattern)`          |
| .NET       | `(?i)`, `(?m)`, `(?s)`, `(?x)` | `(?-i)`, etc. | `(?i:pattern)`  |

**Example:** Match case-insensitively only for part of the pattern:
```
hello (?i:world)    # "world" is case-insensitive; "hello" is not
```

## Flag Combinations

| Combo     | Meaning                              | Common Use Case                  |
|-----------|--------------------------------------|----------------------------------|
| `gi`      | Global + case-insensitive            | Find all case-insensitive matches|
| `gm`      | Global + multiline                   | Match patterns on every line     |
| `gms`     | Global + multiline + dotall          | Match patterns across lines      |
| `gim`     | Global + case-insensitive + multiline| Search all lines, any case       |
| `xs`      | Verbose + dotall                     | Readable pattern matching `\n`   |

## How "Global" Works Per Language

### JavaScript
```javascript
// With /g: matchAll returns iterator of all matches
for (const m of str.matchAll(/\d+/g)) { console.log(m[0]); }

// Without /g: match() returns only first match
str.match(/\d+/);  // first match only

// ⚠️ /g makes test() and exec() stateful via lastIndex
const re = /a/g;
re.test('aaa');  // true, lastIndex=1
re.test('aaa');  // true, lastIndex=2
```

### Python
```python
# No /g flag — use different functions:
re.search(r'\d+', text)       # first match
re.findall(r'\d+', text)      # all matches (strings)
re.finditer(r'\d+', text)     # all matches (iterator of Match objects)
```

### Go
```go
// Single match:
re.FindString(text)            // first match
// All matches:
re.FindAllString(text, -1)     // all matches (-1 = unlimited)
re.FindAllString(text, 5)      // at most 5 matches
```

### Rust
```rust
// Single match:
re.find(text)                  // first match
// All matches:
re.find_iter(text)             // iterator over all matches
re.captures_iter(text)         // iterator with capture groups
```

### Java
```java
// Single match:
if (matcher.find()) { matcher.group(); }
// All matches:
while (matcher.find()) { matcher.group(); }
// Or with Stream (Java 9+):
matcher.results().forEach(r -> System.out.println(r.group()));
```

## Verbose Mode Comparison

Verbose/extended mode allows whitespace and comments in patterns for readability.

### Python
```python
pattern = re.compile(r"""
    ^                   # Start of string
    (?P<year>\d{4})     # Year: 4 digits
    -                   # Separator
    (?P<month>\d{2})    # Month: 2 digits
    -                   # Separator
    (?P<day>\d{2})      # Day: 2 digits
    $                   # End of string
""", re.VERBOSE)
```

### Java
```java
Pattern p = Pattern.compile(
    "^"                        +  // Start
    "(?<year>\\d{4})"          +  // Year
    "-"                        +  // Separator
    "(?<month>\\d{2})"         +  // Month
    "-"                        +  // Separator
    "(?<day>\\d{2})"           +  // Day
    "$",                          // End
    Pattern.COMMENTS
);
```

### Go (limited inline support)
```go
// (?x) enables verbose mode in RE2:
re := regexp.MustCompile(`(?x)
    ^
    (?P<year>\d{4})     # Year
    -                   # Separator
    (?P<month>\d{2})    # Month
    -                   # Separator
    (?P<day>\d{2})      # Day
    $
`)
```

### JavaScript (NOT supported — use concatenation)
```javascript
// No verbose flag — use template literals with comments:
const year  = '(?<year>\\d{4})';   // Year
const month = '(?<month>\\d{2})';  // Month
const day   = '(?<day>\\d{2})';    // Day
const re = new RegExp(`^${year}-${month}-${day}$`);
```

## Unicode Flag Details

| Feature                | JS `/u`        | JS `/v`       | Python Py3  | Go          | Java              |
|------------------------|----------------|---------------|-------------|-------------|-------------------|
| `\p{L}` (Unicode letter) | ✅           | ✅            | ❌ (`re`)¹  | ✅          | ✅                |
| `\p{Emoji}`            | ✅             | ✅            | ❌ (`re`)¹  | ❌          | ❌                |
| `\p{Script=Latin}`     | ✅             | ✅            | ❌ (`re`)¹  | ❌          | `\p{IsLatin}` ✅  |
| Set operations in `[]` | ❌             | ✅            | ❌          | ❌          | ❌                |
| String properties      | ❌             | ✅            | ❌          | ❌          | ❌                |

¹ Use the third-party `regex` module (`pip install regex`) for `\p{}` support in Python.
