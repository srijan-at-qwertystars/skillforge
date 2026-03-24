# Regex Language Reference

> Side-by-side regex API comparison across JavaScript, Python, Go, Rust, and Java.

## Table of Contents

- [1. Quick Comparison Table](#1-quick-comparison-table)
- [2. JavaScript](#2-javascript)
- [3. Python](#3-python)
- [4. Go](#4-go)
- [5. Rust](#5-rust)
- [6. Java](#6-java)
- [7. Cross-Language Patterns](#7-cross-language-patterns)
- [8. Migration Guide](#8-migration-guide)

---

## 1. Quick Comparison Table

| Feature                  | JavaScript              | Python                   | Go                      | Rust                  | Java                     |
|--------------------------|------------------------|--------------------------|-------------------------|-----------------------|--------------------------|
| Engine                   | V8/SpiderMonkey (BT)   | Custom (BT)              | RE2 (DFA)               | regex crate (DFA)     | Custom (BT)              |
| Compile                  | `/.../` / `new RegExp`  | `re.compile()`           | `regexp.MustCompile()`  | `Regex::new()`        | `Pattern.compile()`      |
| First match              | `.match()` / `.exec()` | `re.search()`            | `FindString()`          | `find()`              | `matcher.find()`         |
| All matches              | `.matchAll()`          | `re.finditer()`          | `FindAllString()`       | `find_iter()`         | `while(m.find())`        |
| Replace first            | `.replace()`           | `re.sub(count=1)`        | `ReplaceFirst()`¹       | `replace()`           | `replaceFirst()`         |
| Replace all              | `.replaceAll()`/`/g`   | `re.sub()`               | `ReplaceAllString()`    | `replace_all()`       | `replaceAll()`           |
| Split                    | `.split()`             | `re.split()`             | `Split()`               | `split()`             | `split()`                |
| Named groups             | `(?<n>...)` ES2018     | `(?P<n>...)`             | `(?P<n>...)`            | `(?P<n>...)`          | `(?<n>...)` Java 7       |
| Backreferences           | ✅ `\1`, `\k<n>`       | ✅ `\1`, `(?P=n)`         | ❌                       | ❌                     | ✅ `\1`, `\k<n>`          |
| Lookahead/behind         | ✅                      | ✅                        | ❌                       | ❌                     | ✅                        |
| O(n) guarantee           | ❌                      | ❌                        | ✅                       | ✅                     | ❌                        |

¹ Go has no built-in `ReplaceFirst`; use `ReplaceAllStringFunc` with a counter.

BT = Backtracking engine. DFA = Deterministic Finite Automaton (linear time).

---

## 2. JavaScript

### Engine: V8 / SpiderMonkey (backtracking NFA)

JavaScript has two ways to create regex: literal syntax and constructor.

### Creating Patterns

```javascript
// Literal (preferred for static patterns):
const re = /\d{4}-\d{2}-\d{2}/g;

// Constructor (for dynamic patterns):
const re2 = new RegExp('\\d{4}-\\d{2}-\\d{2}', 'g');

// Tagged template (no escaping needed — proposed):
// Not yet standard
```

### Core Methods

#### `RegExp.prototype.test()` — Boolean match
```javascript
/\d+/.test('abc123');  // true
/\d+/.test('abc');     // false
```

⚠️ With `/g` flag, `test()` is **stateful** — advances `lastIndex`:
```javascript
const re = /a/g;
re.test('aaa');  // true, lastIndex = 1
re.test('aaa');  // true, lastIndex = 2
re.test('aaa');  // true, lastIndex = 3
re.test('aaa');  // false, lastIndex = 0 (reset)
```

#### `String.prototype.match()` — First match or all matches
```javascript
// Without /g: returns match object (groups, index):
'Date: 2024-01-15'.match(/(\d{4})-(\d{2})-(\d{2})/);
// ['2024-01-15', '2024', '01', '15', index: 6, groups: undefined]

// With /g: returns array of matched strings (no groups!):
'a1 b2 c3'.match(/[a-z]\d/g);
// ['a1', 'b2', 'c3']
```

#### `String.prototype.matchAll()` — Iterate all matches (ES2020)
```javascript
const text = 'Price: $42.99 and $18.50';
const re = /\$(?<amount>\d+\.\d{2})/g;

for (const m of text.matchAll(re)) {
    console.log(m[0]);              // '$42.99', '$18.50'
    console.log(m.groups.amount);   // '42.99', '18.50'
    console.log(m.index);           // 7, 18
}
```

#### `String.prototype.replace()` / `replaceAll()`
```javascript
// Static replacement:
'hello world'.replace(/world/, 'JS');  // 'hello JS'

// With backreference:
'2024-01-15'.replace(/(\d{4})-(\d{2})-(\d{2})/, '$2/$3/$1');
// '01/15/2024'

// With named group reference:
'John Smith'.replace(/(?<first>\w+) (?<last>\w+)/, '$<last>, $<first>');
// 'Smith, John'

// With function:
'hello'.replace(/./g, (ch) => ch.toUpperCase());  // 'HELLO'

// replaceAll (ES2021) — requires /g flag:
'aaa'.replaceAll(/a/g, 'b');  // 'bbb'
```

#### `String.prototype.split()`
```javascript
'one,two,,three'.split(/,/);     // ['one', 'two', '', 'three']
'a1b2c3'.split(/(\d)/);          // ['a', '1', 'b', '2', 'c', '3', '']
// Captures in split pattern are included in result
```

### Named Groups (ES2018+)

```javascript
const re = /(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})/;
const m = '2024-01-15'.match(re);

m.groups.year;   // '2024'
m.groups.month;  // '01'
m.groups.day;    // '15'

// Destructuring:
const { year, month, day } = m.groups;
```

### Flags

| Flag | Name          | Effect                                        | Since   |
|------|---------------|-----------------------------------------------|---------|
| `g`  | global        | Find all matches, not just first              | ES3     |
| `i`  | ignoreCase    | Case-insensitive matching                     | ES3     |
| `m`  | multiline     | `^`/`$` match line boundaries                 | ES3     |
| `s`  | dotAll        | `.` matches `\n`                              | ES2018  |
| `u`  | unicode       | Enable Unicode features, `\p{}`               | ES2015  |
| `y`  | sticky        | Match only at `lastIndex` position            | ES2015  |
| `d`  | hasIndices    | Include start/end indices for groups           | ES2022  |
| `v`  | unicodeSets   | Extended Unicode sets, `\p{}` in classes       | ES2024  |

---

## 3. Python

### Engine: Custom backtracking NFA

Python's `re` module is the standard; the third-party `regex` module adds
extra features (Unicode properties, atomic groups, possessive quantifiers).

### Creating Patterns

```python
import re

# Compile (recommended for reuse):
pattern = re.compile(r'\d{4}-\d{2}-\d{2}')

# With flags:
pattern = re.compile(r'hello', re.IGNORECASE | re.MULTILINE)

# Inline flags:
pattern = re.compile(r'(?im)hello')
```

Always use raw strings (`r'...'`) to avoid double-escaping backslashes.

### Core Functions

#### `re.search()` — First match anywhere
```python
m = re.search(r'(\d+)', 'abc 123 def')
m.group()    # '123'
m.group(1)   # '123'
m.start()    # 4
m.end()      # 7
m.span()     # (4, 7)
```

#### `re.match()` — Match at start only
```python
re.match(r'\d+', '123abc')   # Match object (matches at start)
re.match(r'\d+', 'abc123')   # None (doesn't match at start!)
```

#### `re.fullmatch()` — Match entire string (Python 3.4+)
```python
re.fullmatch(r'\d+', '123')     # Match object
re.fullmatch(r'\d+', '123abc')  # None
```

#### `re.findall()` — All matches as list
```python
re.findall(r'\d+', 'a1 b22 c333')  # ['1', '22', '333']

# With groups — returns tuples:
re.findall(r'(\d+)-(\d+)', '1-2 3-4')  # [('1','2'), ('3','4')]
```

#### `re.finditer()` — Iterator of match objects
```python
for m in re.finditer(r'(?P<word>\w+)', 'hello world'):
    print(m.group('word'), m.span())
# hello (0, 5)
# world (6, 11)
```

#### `re.sub()` — Replace
```python
# Simple:
re.sub(r'\d+', 'NUM', 'abc 123 def 456')  # 'abc NUM def NUM'

# With count:
re.sub(r'\d+', 'NUM', 'a1 b2 c3', count=2)  # 'a NUM b NUM c3'

# With backreference:
re.sub(r'(\w+) (\w+)', r'\2 \1', 'hello world')  # 'world hello'

# With named group reference:
re.sub(r'(?P<a>\w+) (?P<b>\w+)', r'\g<b> \g<a>', 'hello world')

# With function:
re.sub(r'\d+', lambda m: str(int(m.group()) * 2), 'val=5')  # 'val=10'
```

#### `re.split()` — Split by pattern
```python
re.split(r'[,;]\s*', 'a, b;c,  d')  # ['a', 'b', 'c', 'd']

# With capturing group — delimiters included:
re.split(r'([,;])', 'a,b;c')  # ['a', ',', 'b', ';', 'c']

# With maxsplit:
re.split(r'\s+', 'a b c d', maxsplit=2)  # ['a', 'b', 'c d']
```

### Named Groups

```python
m = re.search(r'(?P<year>\d{4})-(?P<month>\d{2})', '2024-01')
m.group('year')     # '2024'
m.group('month')    # '01'
m.groupdict()       # {'year': '2024', 'month': '01'}

# Backreference in pattern:
re.search(r'(?P<word>\w+) (?P=word)', 'the the')  # Match!
```

### Flags

| Flag              | Short  | Effect                          |
|-------------------|--------|---------------------------------|
| `re.IGNORECASE`   | `re.I` | Case-insensitive                |
| `re.MULTILINE`    | `re.M` | `^`/`$` match line boundaries   |
| `re.DOTALL`       | `re.S` | `.` matches `\n`                |
| `re.VERBOSE`      | `re.X` | Allow comments and whitespace   |
| `re.ASCII`        | `re.A` | `\w`, `\d`, `\s` match ASCII only |
| `re.UNICODE`      | `re.U` | Unicode matching (default in Py3) |

### Debugging

```python
re.compile(r'(\d+)-(\w+)', re.DEBUG)
# Prints the compiled regex tree
```

### Third-Party `regex` Module

```python
import regex  # pip install regex

# Atomic groups:
regex.search(r'(?>a+)b', 'aaab')

# Possessive quantifiers:
regex.search(r'a++b', 'aaab')

# Unicode properties:
regex.findall(r'\p{Emoji}', 'Hello 👋 World 🌍')

# Timeout:
regex.search(r'(a+)+b', 'a' * 100, timeout=1.0)
```

---

## 4. Go

### Engine: RE2 (guaranteed linear time)

Go's `regexp` package uses the RE2 engine. This means **no backreferences,
no lookahead/lookbehind, no atomic groups** — but matching is always O(n).

### Creating Patterns

```go
import "regexp"

// MustCompile panics on invalid pattern (use for constants):
var dateRe = regexp.MustCompile(`\d{4}-\d{2}-\d{2}`)

// Compile returns error (use for user input):
re, err := regexp.Compile(userPattern)
if err != nil {
    log.Fatal(err)
}
```

Always compile at package level for reuse. Use backtick strings to avoid escaping.

### Core Methods

#### `MatchString()` — Boolean match
```go
matched := dateRe.MatchString("2024-01-15")  // true
```

#### `FindString()` — First match
```go
dateRe.FindString("Date: 2024-01-15 is today")  // "2024-01-15"
dateRe.FindString("no date here")                // "" (empty string)
```

#### `FindStringSubmatch()` — First match with groups
```go
re := regexp.MustCompile(`(\d{4})-(\d{2})-(\d{2})`)
m := re.FindStringSubmatch("Date: 2024-01-15")
// m[0] = "2024-01-15" (full match)
// m[1] = "2024", m[2] = "01", m[3] = "15"
```

#### `FindAllString()` — All matches
```go
re := regexp.MustCompile(`\d+`)
re.FindAllString("a1 b22 c333", -1)  // ["1", "22", "333"]
re.FindAllString("a1 b22 c333", 2)   // ["1", "22"] (limit to 2)
```

#### `FindAllStringSubmatch()` — All matches with groups
```go
re := regexp.MustCompile(`(\w+)=(\w+)`)
matches := re.FindAllStringSubmatch("a=1 b=2", -1)
// matches[0] = ["a=1", "a", "1"]
// matches[1] = ["b=2", "b", "2"]
```

#### `ReplaceAllString()` — Replace all
```go
re := regexp.MustCompile(`\d+`)
re.ReplaceAllString("a1 b2", "NUM")  // "aNUM bNUM"

// With group reference:
re2 := regexp.MustCompile(`(\w+) (\w+)`)
re2.ReplaceAllString("hello world", "${2} ${1}")  // "world hello"
```

#### `ReplaceAllStringFunc()` — Replace with function
```go
re := regexp.MustCompile(`\d+`)
result := re.ReplaceAllStringFunc("val=5", func(s string) string {
    n, _ := strconv.Atoi(s)
    return strconv.Itoa(n * 2)
})
// "val=10"
```

#### `Split()` — Split by pattern
```go
re := regexp.MustCompile(`[,;]\s*`)
re.Split("a, b;c,  d", -1)  // ["a", "b", "c", "d"]
```

### Named Groups

```go
re := regexp.MustCompile(`(?P<year>\d{4})-(?P<month>\d{2})`)
match := re.FindStringSubmatch("2024-01")
names := re.SubexpNames()

// Build a map:
result := make(map[string]string)
for i, name := range names {
    if i != 0 && name != "" {
        result[name] = match[i]
    }
}
// result = map[year:2024 month:01]

// Or use SubexpIndex (Go 1.15+):
yearIdx := re.SubexpIndex("year")
fmt.Println(match[yearIdx])  // "2024"
```

### Key Differences from PCRE

| Feature                | Go/RE2          | PCRE                    |
|------------------------|-----------------|-------------------------|
| Backreferences         | ❌ Not supported | ✅ `\1`, `\k<name>`     |
| Lookahead/lookbehind   | ❌ Not supported | ✅                       |
| Atomic groups          | ❌ Not supported | ✅ `(?>...)`             |
| Possessive quantifiers | ❌ Not supported | ✅ `*+`, `++`            |
| Word boundary `\b`     | ✅ Supported     | ✅ Supported             |
| Unicode properties     | ✅ `\p{L}`       | ✅ `\p{L}`               |
| Named groups           | ✅ `(?P<n>...)`  | ✅ `(?<n>...)`, `(?P<>)` |

### Workarounds

```go
// Simulate lookahead — check condition after match:
re := regexp.MustCompile(`(\w+)`)
for _, m := range re.FindAllString(text, -1) {
    if !strings.HasSuffix(m, "bar") {
        // This word is NOT followed by "bar"
    }
}

// Simulate backreference — compare groups in code:
re := regexp.MustCompile(`(\w+)\s+(\w+)`)
m := re.FindStringSubmatch(text)
if m[1] == m[2] {
    fmt.Println("Repeated word:", m[1])
}
```

---

## 5. Rust

### Engine: regex crate (RE2-like, linear time guaranteed)

Rust's `regex` crate provides safe, fast regex with DFA-based matching.
Like Go, it trades off some features (no backreferences/lookarounds)
for guaranteed O(n) performance.

### Creating Patterns

```rust
use regex::Regex;

// Basic (compile returns Result):
let re = Regex::new(r"\d{4}-\d{2}-\d{2}").unwrap();

// With error handling:
let re = match Regex::new(pattern) {
    Ok(r) => r,
    Err(e) => { eprintln!("Invalid regex: {}", e); return; }
};

// Lazy static (compile once):
use once_cell::sync::Lazy;
static DATE_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\d{4}-\d{2}-\d{2}").unwrap()
});
```

### Core Methods

#### `is_match()` — Boolean
```rust
re.is_match("2024-01-15");  // true
```

#### `find()` — First match location
```rust
if let Some(m) = re.find("Date: 2024-01-15") {
    println!("{}", m.as_str());   // "2024-01-15"
    println!("{}", m.start());    // 6
    println!("{}", m.end());      // 16
}
```

#### `captures()` — First match with groups
```rust
let re = Regex::new(r"(\d{4})-(\d{2})-(\d{2})").unwrap();
if let Some(caps) = re.captures("Date: 2024-01-15") {
    println!("{}", &caps[0]);  // "2024-01-15"
    println!("{}", &caps[1]);  // "2024"
    println!("{}", &caps[2]);  // "01"
    println!("{}", &caps[3]);  // "15"
}
```

#### `find_iter()` — All matches
```rust
for m in re.find_iter("2024-01-15 and 2025-06-30") {
    println!("{}", m.as_str());
}
```

#### `captures_iter()` — All matches with groups
```rust
let re = Regex::new(r"(?P<key>\w+)=(?P<val>\w+)").unwrap();
for caps in re.captures_iter("a=1 b=2 c=3") {
    println!("{}: {}", &caps["key"], &caps["val"]);
}
```

#### `replace()` / `replace_all()`
```rust
use regex::Regex;

let re = Regex::new(r"\d+").unwrap();
// Replace first:
re.replace("a1 b2", "NUM");       // "aNUM b2"
// Replace all:
re.replace_all("a1 b2", "NUM");   // "aNUM bNUM"

// With backreference:
let re = Regex::new(r"(\w+) (\w+)").unwrap();
re.replace("hello world", "$2 $1");  // "world hello"

// With named group:
let re = Regex::new(r"(?P<first>\w+) (?P<last>\w+)").unwrap();
re.replace("John Smith", "$last, $first");  // "Smith, John"

// With closure:
re.replace_all("val=5", |caps: &regex::Captures| {
    let n: i32 = caps[1].parse().unwrap();
    format!("{}", n * 2)
});
```

#### `split()` — Split by pattern
```rust
let re = Regex::new(r"[,;]\s*").unwrap();
let fields: Vec<&str> = re.split("a, b;c,  d").collect();
// ["a", "b", "c", "d"]
```

### Named Groups

```rust
let re = Regex::new(r"(?P<year>\d{4})-(?P<month>\d{2})").unwrap();
if let Some(caps) = re.captures("2024-01") {
    println!("{}", &caps["year"]);    // "2024"
    println!("{}", &caps["month"]);   // "01"

    // Or with .name():
    if let Some(y) = caps.name("year") {
        println!("{}", y.as_str());
    }
}
```

### `fancy-regex` Crate (Extended Features)

```rust
use fancy_regex::Regex;

// Lookahead:
let re = Regex::new(r"\w+(?=\s+world)").unwrap();

// Lookbehind:
let re = Regex::new(r"(?<=\$)\d+").unwrap();

// Backreference:
let re = Regex::new(r"(\w+)\s+\1").unwrap();
```

⚠️ `fancy-regex` does NOT guarantee linear time.

---

## 6. Java

### Engine: Custom backtracking NFA

Java's `java.util.regex` package provides a full-featured backtracking
engine with atomic groups and possessive quantifiers.

### Creating Patterns

```java
import java.util.regex.*;

// Compile:
Pattern p = Pattern.compile("\\d{4}-\\d{2}-\\d{2}");

// With flags:
Pattern p = Pattern.compile("hello", Pattern.CASE_INSENSITIVE | Pattern.MULTILINE);

// Inline flags:
Pattern p = Pattern.compile("(?im)hello");

// Create matcher:
Matcher m = p.matcher("Date: 2024-01-15");
```

Note the double-escaping in Java string literals: `\\d` for `\d`.

### Core Methods

#### `Matcher.find()` — Find next match
```java
Pattern p = Pattern.compile("\\d+");
Matcher m = p.matcher("a1 b22 c333");
while (m.find()) {
    System.out.println(m.group());   // "1", "22", "333"
    System.out.println(m.start());   // 1, 4, 8
    System.out.println(m.end());     // 2, 6, 11
}
```

#### `Matcher.matches()` — Full string match
```java
Pattern.matches("\\d+", "123");     // true
Pattern.matches("\\d+", "123abc");  // false
```

#### `Matcher.group()` — Capture groups
```java
Pattern p = Pattern.compile("(\\d{4})-(\\d{2})-(\\d{2})");
Matcher m = p.matcher("2024-01-15");
if (m.find()) {
    m.group(0);  // "2024-01-15"
    m.group(1);  // "2024"
    m.group(2);  // "01"
    m.group(3);  // "15"
}
```

#### `String.replaceAll()` / `replaceFirst()`
```java
"a1 b2".replaceAll("\\d+", "NUM");      // "aNUM bNUM"
"a1 b2".replaceFirst("\\d+", "NUM");    // "aNUM b2"

// With backreference:
"hello world".replaceAll("(\\w+) (\\w+)", "$2 $1");  // "world hello"
```

#### `Pattern.split()`
```java
Pattern.compile("[,;]\\s*").split("a, b;c,  d");
// ["a", "b", "c", "d"]
```

### Named Groups (Java 7+)

```java
Pattern p = Pattern.compile("(?<year>\\d{4})-(?<month>\\d{2})");
Matcher m = p.matcher("2024-01");
if (m.find()) {
    m.group("year");   // "2024"
    m.group("month");  // "01"
}
```

### Advanced Features

```java
// Atomic group:
Pattern.compile("(?>a+)b");

// Possessive quantifier:
Pattern.compile("a++b");

// Lookahead:
Pattern.compile("\\d+(?= dollars)");

// Lookbehind:
Pattern.compile("(?<=\\$)\\d+");

// Backreference:
Pattern.compile("(\\w+)\\s+\\1");
```

### Flags

| Flag                              | Short      | Effect                           |
|-----------------------------------|------------|----------------------------------|
| `Pattern.CASE_INSENSITIVE`        | `(?i)`     | Case-insensitive                 |
| `Pattern.MULTILINE`               | `(?m)`     | `^`/`$` match line boundaries    |
| `Pattern.DOTALL`                  | `(?s)`     | `.` matches `\n`                 |
| `Pattern.COMMENTS`                | `(?x)`     | Verbose mode (whitespace/comments) |
| `Pattern.UNICODE_CASE`            | `(?u)`     | Unicode-aware case folding       |
| `Pattern.UNICODE_CHARACTER_CLASS` | —          | `\w`, `\d` match Unicode        |
| `Pattern.UNIX_LINES`              | `(?d)`     | Only `\n` is line terminator     |
| `Pattern.LITERAL`                 | —          | Treat pattern as literal string  |
| `Pattern.CANON_EQ`                | —          | Canonical equivalence matching   |

---

## 7. Cross-Language Patterns

### Same Pattern, All Languages

**Task:** Extract all email addresses from text.

Pattern: `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}`

```javascript
// JavaScript:
const emails = text.match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g);
```

```python
# Python:
emails = re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', text)
```

```go
// Go:
re := regexp.MustCompile(`[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}`)
emails := re.FindAllString(text, -1)
```

```rust
// Rust:
let re = Regex::new(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}").unwrap();
let emails: Vec<&str> = re.find_iter(text).map(|m| m.as_str()).collect();
```

```java
// Java:
Pattern p = Pattern.compile("[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}");
Matcher m = p.matcher(text);
List<String> emails = new ArrayList<>();
while (m.find()) { emails.add(m.group()); }
```

### Same Task: Named Group Extraction

**Task:** Parse `"YYYY-MM-DD"` dates with named groups.

```javascript
// JavaScript:
const m = text.match(/(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})/);
const { year, month, day } = m.groups;
```

```python
# Python:
m = re.search(r'(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})', text)
year, month, day = m.group('year'), m.group('month'), m.group('day')
```

```go
// Go:
re := regexp.MustCompile(`(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})`)
m := re.FindStringSubmatch(text)
year := m[re.SubexpIndex("year")]
month := m[re.SubexpIndex("month")]
day := m[re.SubexpIndex("day")]
```

```rust
// Rust:
let re = Regex::new(r"(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})").unwrap();
if let Some(caps) = re.captures(text) {
    let year = &caps["year"];
    let month = &caps["month"];
    let day = &caps["day"];
}
```

```java
// Java:
Pattern p = Pattern.compile("(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})");
Matcher m = p.matcher(text);
if (m.find()) {
    String year = m.group("year");
    String month = m.group("month");
    String day = m.group("day");
}
```

---

## 8. Migration Guide

### Python → JavaScript

| Python                         | JavaScript                        |
|--------------------------------|-----------------------------------|
| `re.search(pat, s)`           | `s.match(pat)`                    |
| `re.match(pat, s)`            | `s.match(/^pat/)`                 |
| `re.fullmatch(pat, s)`        | `s.match(/^pat$/)`                |
| `re.findall(pat, s)`          | `[...s.matchAll(pat)]`            |
| `re.finditer(pat, s)`         | `s.matchAll(pat)` (iterator)      |
| `re.sub(pat, repl, s)`        | `s.replace(pat, repl)` with `/g`  |
| `re.split(pat, s)`            | `s.split(pat)`                    |
| `(?P<name>...)`               | `(?<name>...)`                    |
| `(?P=name)`                   | `\k<name>`                        |
| `\g<name>` (in replacement)   | `$<name>`                          |
| `re.IGNORECASE`               | `/i`                               |
| `re.MULTILINE`                | `/m`                               |
| `re.DOTALL`                   | `/s`                               |
| `re.VERBOSE`                  | Not available                      |

### Python → Go

| Python                        | Go                                 |
|-------------------------------|-------------------------------------|
| `re.search(pat, s)`          | `re.FindString(s)`                  |
| `re.findall(pat, s)`         | `re.FindAllString(s, -1)`           |
| `re.sub(pat, repl, s)`       | `re.ReplaceAllString(s, repl)`      |
| `re.split(pat, s)`           | `re.Split(s, -1)`                   |
| `(?P<name>...)`              | `(?P<name>...)` (same!)             |
| Lookahead `(?=...)`          | Not available — use code logic      |
| Backreference `\1`           | Not available — compare in code     |

### Java → Rust

| Java                          | Rust                               |
|-------------------------------|-------------------------------------|
| `Pattern.compile(pat)`       | `Regex::new(pat)`                   |
| `matcher.find()`             | `re.find(s)` / `re.captures(s)`    |
| `matcher.group(n)`           | `caps[n]` or `caps.name("n")`      |
| `str.replaceAll(pat, repl)`  | `re.replace_all(s, repl)`          |
| `Pattern.split(s)`           | `re.split(s)`                       |
| `(?<name>...)`               | `(?P<name>...)` (different syntax!) |
| Atomic groups `(?>...)`      | Not available (standard regex crate)|
| Backreference `\1`           | Not available (use `fancy-regex`)   |
