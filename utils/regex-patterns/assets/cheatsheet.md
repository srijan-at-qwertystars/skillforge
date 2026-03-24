# Regex Quick Reference Cheatsheet

## Metacharacters

| Char | Meaning                        | Example             | Matches                |
|------|--------------------------------|---------------------|------------------------|
| `.`  | Any char (except `\n`)         | `a.c`               | `abc`, `a1c`, `a-c`   |
| `\`  | Escape next character          | `\.`                | literal `.`            |
| `^`  | Start of string/line           | `^Hello`            | `Hello` at start       |
| `$`  | End of string/line             | `end$`              | `end` at end           |
| `\|` | Alternation (OR)               | `cat\|dog`          | `cat` or `dog`         |
| `()` | Capturing group                | `(abc)+`            | `abc`, `abcabc`        |

## Quantifiers

| Quantifier | Meaning          | Greedy  | Lazy    | Possessive |
|------------|------------------|---------|---------|------------|
| `*`        | 0 or more        | `a*`    | `a*?`   | `a*+`      |
| `+`        | 1 or more        | `a+`    | `a+?`   | `a++`      |
| `?`        | 0 or 1           | `a?`    | `a??`   | `a?+`      |
| `{n}`      | Exactly n        | `a{3}`  | —       | —          |
| `{n,}`     | n or more        | `a{3,}` | `a{3,}?`| `a{3,}+`   |
| `{n,m}`    | Between n and m  | `a{3,5}`| `a{3,5}?`| `a{3,5}+` |

**Greedy:** Match as much as possible (default).
**Lazy:** Match as little as possible (add `?`).
**Possessive:** Match as much as possible, never backtrack (add `+`; PCRE/Java only).

## Character Classes

| Class    | Meaning                        | Equivalent          |
|----------|--------------------------------|---------------------|
| `[abc]`  | Any of a, b, or c             | —                   |
| `[^abc]` | Any char except a, b, c       | —                   |
| `[a-z]`  | Any char from a to z          | —                   |
| `[a-zA-Z0-9]` | Alphanumeric              | —                   |
| `\d`     | Digit                          | `[0-9]`             |
| `\D`     | Non-digit                      | `[^0-9]`            |
| `\w`     | Word character                 | `[a-zA-Z0-9_]`      |
| `\W`     | Non-word character             | `[^a-zA-Z0-9_]`     |
| `\s`     | Whitespace                     | `[ \t\n\r\f\v]`     |
| `\S`     | Non-whitespace                 | `[^ \t\n\r\f\v]`    |

### Special Characters in Classes

| Pattern        | Meaning                                    |
|----------------|--------------------------------------------|
| `[-abc]`       | Literal `-` (at start/end)                 |
| `[abc-]`       | Literal `-` (at end)                       |
| `[a\-c]`       | Literal `-` (escaped)                      |
| `[\^abc]`      | Literal `^` (escaped or not first)         |
| `[[\]]`        | Literal brackets (escaped)                 |

## Assertions (Zero-Width)

| Assertion      | Meaning                        | Example           |
|----------------|--------------------------------|-------------------|
| `^`            | Start of string (or line w/`m`)| `^Hello`          |
| `$`            | End of string (or line w/`m`)  | `world$`          |
| `\b`           | Word boundary                  | `\bword\b`        |
| `\B`           | Non-word boundary              | `\Bword\B`        |
| `\A`           | Absolute start of string       | `\AFirst`         |
| `\Z`           | End of string (before final `\n`) | `last\Z`       |
| `\z`           | Absolute end of string         | `last\z`          |

## Lookaround Assertions

| Type                | Syntax        | Meaning                     |
|---------------------|---------------|-----------------------------|
| Positive lookahead  | `(?=...)`     | Followed by ...             |
| Negative lookahead  | `(?!...)`     | NOT followed by ...         |
| Positive lookbehind | `(?<=...)`    | Preceded by ...             |
| Negative lookbehind | `(?<!...)`    | NOT preceded by ...         |

**Examples:**
```
\d+(?= dollars)      Digits followed by " dollars"
(?<=\$)\d+            Digits preceded by "$"
\b\w+(?!ing\b)        Word NOT ending in "ing"
(?<!un)happy          "happy" NOT preceded by "un"
```

**Not supported in:** Go (RE2), Rust (regex crate).

## Groups

| Syntax          | Type                    | Example                  |
|-----------------|-------------------------|--------------------------|
| `(abc)`         | Capturing group         | `(foo)bar` → group 1: `foo` |
| `(?:abc)`       | Non-capturing group     | `(?:foo)bar` — no capture |
| `(?<name>abc)`  | Named group (JS/Java)   | `(?<year>\d{4})`         |
| `(?P<name>abc)` | Named group (Python/Go/Rust) | `(?P<year>\d{4})`   |
| `(?|a\|b)`      | Branch reset (PCRE)     | Groups renumbered per branch |
| `(?>abc)`       | Atomic group (PCRE/Java)| No backtracking into group |

## Backreferences

| Syntax          | Meaning                   | Support               |
|-----------------|---------------------------|-----------------------|
| `\1`, `\2`      | Match same text as group  | JS, Python, Java      |
| `\k<name>`      | Named backreference       | JS, Java              |
| `(?P=name)`     | Named backreference       | Python                |
| `\g{1}`         | Explicit group number     | PCRE                  |
| `\g{-1}`        | Relative backreference    | PCRE                  |

## Flags / Modifiers

| Flag | Name              | JS    | Python         | Java                        | Go/Rust  |
|------|-------------------|-------|----------------|-----------------------------| ---------|
| `i`  | Case-insensitive  | `/i`  | `re.I`         | `CASE_INSENSITIVE`          | `(?i)`   |
| `m`  | Multiline         | `/m`  | `re.M`         | `MULTILINE`                 | `(?m)`   |
| `s`  | DotAll            | `/s`  | `re.S`         | `DOTALL`                    | `(?s)`   |
| `g`  | Global            | `/g`  | `findall()`    | `find()` loop               | N/A      |
| `x`  | Verbose           | N/A   | `re.X`         | `COMMENTS`                  | `(?x)`¹  |
| `u`  | Unicode           | `/u`  | default (Py3)  | `UNICODE_CHARACTER_CLASS`   | default  |

¹ Go supports `(?x)` inline (limited); Rust regex crate supports verbose mode.

## Common Escape Sequences

| Sequence | Meaning              |
|----------|----------------------|
| `\n`     | Newline              |
| `\r`     | Carriage return      |
| `\t`     | Tab                  |
| `\f`     | Form feed            |
| `\v`     | Vertical tab         |
| `\0`     | Null character       |
| `\xHH`   | Hex character        |
| `\uHHHH` | Unicode (4-digit)    |
| `\p{L}`  | Unicode letter       |
| `\p{N}`  | Unicode number       |
| `\p{P}`  | Unicode punctuation  |
| `\p{S}`  | Unicode symbol       |
| `\R`     | Any line break (PCRE)|

## Quick Recipes

```
Match any word:             \b\w+\b
Match digits only:          ^\d+$
Match email (simple):       ^[\w.+-]+@[\w.-]+\.\w{2,}$
Match URL:                  ^https?://\S+$
Match IP (simple):          \d{1,3}(\.\d{1,3}){3}
Extract quoted string:      "([^"\\]|\\.)*"
Remove HTML tags:           <[^>]+>
Split CamelCase:            (?<=[a-z])(?=[A-Z])
Trim whitespace:            ^\s+|\s+$
Match blank lines:          ^\s*$
Match non-ASCII:            [^\x00-\x7F]
```
