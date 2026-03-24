# jq Cheatsheet — Quick Reference Card

> Operators, builtins, format strings, and CLI flags at a glance.

---

## CLI Flags

| Flag | Long Form | Description |
|------|-----------|-------------|
| `-r` | `--raw-output` | Output strings without quotes |
| `-R` | `--raw-input` | Read input as raw strings, not JSON |
| `-c` | `--compact-output` | One-line output |
| `-S` | `--sort-keys` | Sort object keys |
| `-s` | `--slurp` | Read all inputs into array |
| `-n` | `--null-input` | Don't read stdin |
| `-e` | `--exit-status` | Exit 1 if last output is false/null |
| `-j` | `--join-output` | No trailing newline |
| | `--tab` | Indent with tabs |
| | `--indent N` | Indent with N spaces |
| | `--arg k v` | Set `$k` to string `v` |
| | `--argjson k v` | Set `$k` to JSON value `v` |
| | `--slurpfile k f` | Set `$k` to array from file `f` |
| | `--rawfile k f` | Set `$k` to raw string from file `f` |
| | `--jsonargs` | Treat remaining args as JSON |
| | `--args` | Treat remaining args as strings |
| `-f` | `--from-file f` | Read filter from file `f` |
| `-L` | | Add directory to module search path |
| | `--stream` | Parse input in streaming mode |

---

## Operators

### Access

| Syntax | Description | Example |
|--------|-------------|---------|
| `.` | Identity | `jq '.'` |
| `.foo` | Object field | `jq '.name'` |
| `.foo.bar` | Nested field | `jq '.user.name'` |
| `.foo?` | Optional (no error) | `jq '.maybe?'` |
| `.[n]` | Array index | `jq '.[0]'` |
| `.[-n]` | From end | `jq '.[-1]'` |
| `.[a:b]` | Slice | `jq '.[2:5]'` |
| `.[]` | Iterate all | `jq '.[]'` |
| `.[]?` | Iterate (safe) | `jq '.[]?'` |

### Pipe & Combine

| Syntax | Description | Example |
|--------|-------------|---------|
| `\|` | Pipe (chain) | `.a \| .b` |
| `,` | Multiple outputs | `.a, .b` |
| `//` | Alternative (default) | `.x // "default"` |
| `?//` | Try-alternative | `.x ?// "fallback"` |
| `as $v` | Variable binding | `. as $x \| ...` |

### Comparison

| Syntax | Description |
|--------|-------------|
| `==`, `!=` | Equality |
| `<`, `<=`, `>`, `>=` | Ordering |
| `and`, `or`, `not` | Boolean logic |

### Arithmetic

| Syntax | Description |
|--------|-------------|
| `+`, `-`, `*`, `/`, `%` | Math operators |
| `+` on strings | Concatenation |
| `+` on arrays | Concatenation |
| `*` on objects | Deep merge |

### Update

| Syntax | Description | Example |
|--------|-------------|---------|
| `=` | Set value | `.name = "new"` |
| `\|=` | Update in-place | `.age \|= . + 1` |
| `+=`, `-=`, `*=`, `/=` | Arithmetic update | `.count += 1` |
| `//=` | Set if null | `.x //= "default"` |

---

## Object Builtins

```
keys / keys_unsorted     values              length
has("key")               in(obj)             contains(obj)
to_entries               from_entries        with_entries(f)
del(.key)                getpath(p)          setpath(p; v)
delpaths(ps)             paths               paths(filter)
leaf_paths               path(expr)
```

## Array Builtins

```
length         reverse        sort / sort_by(f)
group_by(f)    unique / unique_by(f)
flatten(n)     min / max      min_by(f) / max_by(f)
add            any / any(f)   all / all(f)
contains(x)    inside(x)      indices(x)
index(x)       rindex(x)      first / last
first(f)       last(f)        nth(n; f)
range(n)       range(a;b)     range(a;b;step)
limit(n; f)    until(c; f)    while(c; f)
repeat(f)      recurse(f)     recurse(f; c)
transpose      input          inputs
map(f)         map_values(f)  select(f)
empty          reduce         foreach
```

## String Builtins

```
length              utf8bytelength
ascii_downcase      ascii_upcase
ltrimstr(s)         rtrimstr(s)
startswith(s)       endswith(s)
split(s)            join(s)
test(re)            test(re; flags)
match(re)           capture(re)
scan(re)            sub(re; s)       gsub(re; s)
explode             implode
tostring            tonumber
ascii
```

**Regex flags:** `"x"` (extended), `"i"` (case-insensitive), `"g"` (global), `"m"` (multiline), `"s"` (single-line)

## Format Strings

| Format | Description | Example |
|--------|-------------|---------|
| `@base64` | Base64 encode | `"hello" \| @base64` → `"aGVsbG8="` |
| `@base64d` | Base64 decode | `"aGVsbG8=" \| @base64d` → `"hello"` |
| `@uri` | URI encode | `"a b" \| @uri` → `"a%20b"` |
| `@html` | HTML escape | `"<b>" \| @html` → `"&lt;b&gt;"` |
| `@csv` | CSV row | `["a","b"] \| @csv` → `"\"a\",\"b\""` |
| `@tsv` | TSV row | `["a","b"] \| @tsv` → `"a\tb"` |
| `@json` | JSON string | `42 \| @json` → `"42"` |
| `@text` | Plain text | `42 \| @text` → `"42"` |

## Type System

| Filter | Description |
|--------|-------------|
| `type` | Returns type as string |
| `strings` | Select only strings |
| `numbers` | Select only numbers |
| `objects` | Select only objects |
| `arrays` | Select only arrays |
| `booleans` | Select only booleans |
| `nulls` | Select only nulls |
| `iterables` | Select arrays and objects |
| `scalars` | Select non-iterables |
| `isinfinite` | Test for infinite |
| `isnan` | Test for NaN |
| `infinite` | Produce infinity |
| `nan` | Produce NaN |

## Control Flow

```bash
# if-then-else (else is required)
if .x > 0 then "positive" elif .x == 0 then "zero" else "negative" end

# try-catch
try .foo catch "error"
try .foo                    # silently ignore errors
.foo?                       # postfix try (same as try .foo)

# label-break
label $out | foreach .[] as $x (0; . + $x; if . > 10 then ., break $out else . end)

# reduce
reduce .[] as $x (init; update)

# foreach
foreach .[] as $x (init; update; extract)
```

## Date/Time

```bash
now                          # Unix epoch (float)
now | todate                 # ISO 8601 string
now | strftime("%Y-%m-%d")   # Custom format
"2024-01-15T00:00:00Z" | fromdate   # → epoch
```

## I/O & Debugging

```bash
input                        # Read next JSON value
inputs                       # Stream all remaining
debug                        # Print to stderr, pass through
debug("label")               # Debug with label
stderr                       # Write to stderr (raw)
env / $ENV                   # Environment variables
env.HOME                     # Specific env var
$__loc__                     # Source location
builtins                     # List all builtins
```

## Common Patterns

```bash
# Map + filter
[.[] | select(.active) | .name]

# Group + aggregate
group_by(.cat) | map({cat: .[0].cat, n: length})

# Build lookup table
INDEX(.[]; .id)

# Join two files
jq -s 'INDEX(.[0][]; .id) as $t | .[1][] | . + $t[.fk]' a.json b.json

# Flatten nested to dot-notation
[paths(scalars) as $p | {([$p[]|tostring]|join(".")): getpath($p)}] | add

# Unflatten dot-notation
to_entries | reduce .[] as $e ({}; setpath($e.key|split("."); $e.value))

# Remove nulls recursively
walk(if type=="object" then with_entries(select(.value!=null)) else . end)

# Conditional update
map(if .status == "old" then .status = "new" else . end)

# Safe navigation
.a?.b?.c? // "default"
```
