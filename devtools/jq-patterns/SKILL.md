---
name: jq-patterns
description: >
  Guide for jq command-line JSON processing, transformation, and filtering.
  Use when user needs jq JSON processing, command-line JSON manipulation,
  JSON transformation, filtering JSON data, parsing API responses, extracting
  fields from JSON, reshaping JSON structures, or writing jq expressions.
  NOT for programming language JSON libraries (Python json, JS JSON.parse),
  NOT for JSON Schema validation, NOT for YAML processing (use yq instead),
  NOT for XML processing (use xq instead), NOT for database queries.
---

# jq Patterns — Command-Line JSON Processing

## Basic Filters

```bash
# Identity — pretty-print JSON
echo '{"a":1}' | jq '.'

# Field access
echo '{"name":"alice","age":30}' | jq '.name'          # "alice"

# Nested field access
echo '{"user":{"name":"alice"}}' | jq '.user.name'     # "alice"

# Optional field (suppress errors on missing keys)
echo '{"a":1}' | jq '.b?'                               # null (no error)

# Multiple fields
echo '{"a":1,"b":2,"c":3}' | jq '.a, .c'               # 1\n3
```

## Array Operations

```bash
# Iterate array elements
echo '[1,2,3]' | jq '.[]'                # 1\n2\n3

# Index, slice, negative index
echo '["a","b","c"]' | jq '.[1]'         # "b"
echo '[0,1,2,3,4,5]' | jq '.[2:5]'      # [2,3,4]
echo '[1,2,3]' | jq '.[-1]'              # 3
echo '[1,2,3]' | jq 'length'             # 3

# Wrap results back into array
echo '[1,2,3]' | jq '[.[] | . * 2]'      # [2,4,6]

# Flatten nested arrays
echo '[[1,2],[3,[4,5]]]' | jq 'flatten'       # [1,2,3,4,5]
echo '[[1,[2]],[3]]' | jq 'flatten(1)'        # [1,[2],3]
```

## Pipe Operator

Chain filters with `|`. Each stage receives output of the previous.

```bash
echo '{"users":[{"name":"alice"},{"name":"bob"}]}' | \
  jq '.users[] | .name'
# "alice"
# "bob"
```

## Object Construction

```bash
# Build new objects from input
echo '{"first":"Alice","last":"Smith","age":30}' | \
  jq '{fullname: (.first + " " + .last), age}'
# {"fullname": "Alice Smith", "age": 30}

# Dynamic keys
echo '{"k":"color","v":"red"}' | jq '{(.k): .v}'    # {"color":"red"}
```

## select — Filter Elements

```bash
echo '[{"name":"alice","age":30},{"name":"bob","age":20}]' | \
  jq '.[] | select(.age > 25)'
# {"name":"alice","age":30}

# Combine conditions
jq '.[] | select(.status == "active" and .score >= 80)'

# Regex match
jq '.[] | select(.name | test("^al"; "i"))'

# Null-safe select
jq '.[] | select(.email != null)'
```

## map — Transform Arrays

```bash
echo '[1,2,3]' | jq 'map(. * 10)'            # [10,20,30]

echo '[{"name":"alice"},{"name":"bob"}]' | \
  jq 'map(.name |= ascii_upcase)'
# [{"name":"ALICE"},{"name":"BOB"}]

# map + select pattern
jq 'map(select(.active)) | map(.name)'
```

## reduce — Aggregate Values

```bash
# Sum values
echo '[1,2,3,4,5]' | jq 'reduce .[] as $x (0; . + $x)'   # 15

# Build object from array
echo '[["a",1],["b",2]]' | \
  jq 'reduce .[] as $pair ({}; . + {($pair[0]): $pair[1]})'
# {"a":1,"b":2}
```

## group_by / sort_by / unique_by

```bash
# group_by — returns array of arrays
echo '[{"dept":"eng","name":"a"},{"dept":"sales","name":"b"},{"dept":"eng","name":"c"}]' | \
  jq 'group_by(.dept)'
# [[ {"dept":"eng",...}, {"dept":"eng",...} ], [{"dept":"sales",...}]]

# Group and count
jq 'group_by(.dept) | map({dept: .[0].dept, count: length})'

# sort_by
jq 'sort_by(.created_at) | reverse'    # newest first

# unique_by — deduplicate
jq 'unique_by(.email)'

# min_by / max_by
jq 'min_by(.price)'
jq 'max_by(.score)'
```

## String Interpolation

Use `\()` inside strings to embed expressions:

```bash
echo '{"name":"alice","age":30}' | \
  jq '"User \(.name) is \(.age) years old"'
# "User alice is 30 years old"

# With -r for unquoted output
echo '{"host":"example.com","port":8080}' | \
  jq -r '"\(.host):\(.port)"'
# example.com:8080
```

## Conditionals

```bash
# if-then-else (must include else)
jq 'if .age >= 18 then "adult" else "minor" end'

# Alternative operator // (default for null/false)
jq '.name // "unknown"'

# Nested conditionals
jq 'if .score >= 90 then "A"
     elif .score >= 80 then "B"
     elif .score >= 70 then "C"
     else "F" end'
```

## try-catch

```bash
# Suppress errors
jq '[.[] | try .name]'

# Catch with fallback
jq 'try (.data | tonumber) catch "not a number"'

# Optional operator shorthand: postfix ?
jq '.foo.bar?'
```

## Types and Type Checking

```bash
jq 'type'                         # "object", "array", "string", "number", "boolean", "null"
jq 'select(type == "string")'
jq 'map(strings)'                 # filter to strings only
jq 'map(numbers)'                 # filter to numbers only
jq 'map(objects)'                 # filter to objects only
jq 'map(arrays)'                  # filter to arrays only
jq 'map(booleans)'                # filter to booleans only
jq 'map(nulls)'                   # filter to nulls only

# Type conversions
jq 'tostring'                     # any → string
jq 'tonumber'                     # string → number
jq '.[] | @json'                  # any → JSON string
```

## Format Strings (@base64, @uri, @html, @csv, @tsv)

```bash
# Base64 encode/decode
echo '"hello"' | jq '@base64'          # "aGVsbG8="
echo '"aGVsbG8="' | jq '@base64d'     # "hello"

# URI encode
echo '"a b&c=d"' | jq '@uri'          # "a%20b%26c%3Dd"

# HTML escape
echo '"<b>hi</b>"' | jq '@html'       # "&lt;b&gt;hi&lt;/b&gt;"

# CSV / TSV (input must be arrays)
echo '["name","age"]' | jq '@csv'      # "\"name\",\"age\""
echo '["name","age"]' | jq '@tsv'      # "name\tage"

# CSV with headers
jq -r '["id","name"], (.[] | [.id, .name]) | @csv'
```

## Defining Functions (def)

```bash
# Simple function
jq 'def double: . * 2; [.[] | double]'

# Function with arguments
jq 'def addtax(rate): . * (1 + rate); .price | addtax(0.2)'

# Reusable formatting
jq 'def fmt: "\(.name) <\(.email)>"; .users[] | fmt'

# Recursive function
jq 'def sum: reduce .[] as $x (0; . + $x); .values | sum'
```

## Recursive Descent (..)

Descend into all values recursively:

```bash
# Find all "id" fields at any depth
echo '{"a":{"id":1},"b":{"c":{"id":2}}}' | \
  jq '.. | .id? // empty'
# 1
# 2

# Find all strings in a structure
jq '[.. | strings]'

# Find all numbers greater than 100
jq '[.. | numbers | select(. > 100)]'
```

## Path Expressions (path / getpath / setpath)

```bash
# Get paths to all scalars
echo '{"a":{"b":1},"c":2}' | jq '[paths(scalars)]'
# [["a","b"],["c"]]

# Get value at path
echo '{"a":{"b":1}}' | jq 'getpath(["a","b"])'    # 1

# Set value at path
echo '{"a":{"b":1}}' | jq 'setpath(["a","b"]; 99)'
# {"a":{"b":99}}

# Delete path
echo '{"a":1,"b":2}' | jq 'delpaths([["b"]])'     # {"a":1}

# Leaf paths — useful for flattening
jq '[paths(scalars) as $p | {key: ($p | join(".")), value: getpath($p)}] | from_entries'
```

## input / inputs — Streaming Multiple Files

```bash
# Process each file separately (first file is implicit input)
jq -n '[inputs]' file1.json file2.json    # collects all into one array

# Merge two files
jq -s '.[0] * .[1]' defaults.json overrides.json

# Line-delimited JSON (NDJSON/JSONL)
jq -c '.name' < records.jsonl            # one output per line

# Read NDJSON explicitly
jq -n '[inputs | select(.status == "error")]' < app.jsonl
```

## CLI Options

```bash
# --raw-output / -r: unquoted string output
jq -r '.name' data.json

# --slurp / -s: read all inputs into single array
jq -s 'map(.value) | add' values.jsonl

# --null-input / -n: don't read stdin, useful with inputs
jq -n '{now: now | todate}'

# --arg: pass string variable
jq --arg user "$USER" '.[] | select(.name == $user)' data.json

# --argjson: pass JSON variable (number, bool, null, object)
jq --argjson limit 100 '.[] | select(.count > $limit)' data.json

# --slurpfile: load file into variable as array
jq --slurpfile ids ids.json '.[] | select(.id as $i | $ids[] | . == $i)' data.json

# --rawfile: load file as raw string
jq --rawfile tmpl template.txt '{body: $tmpl}' data.json

# --compact-output / -c: single-line output
jq -c '.' data.json

# --sort-keys / -S: sort object keys
jq -S '.' data.json

# --exit-status / -e: exit 1 if output is false or null
jq -e '.enabled' config.json && echo "enabled"

# --tab: indent with tabs
jq --tab '.' data.json

# --join-output / -j: no trailing newline (useful for piping)
jq -j '.token' auth.json | pbcopy
```

## Combining with curl / APIs

```bash
# Pretty-print API response
curl -s https://api.github.com/users/octocat | jq '.'

# Extract specific fields
curl -s https://api.github.com/repos/jqlang/jq/releases | \
  jq '.[] | {tag: .tag_name, date: .published_at}'

# POST with jq-constructed body
curl -s -X POST https://api.example.com/data \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg name "$NAME" '{name: $name}')"

# Paginate and collect API results
for page in $(seq 1 5); do
  curl -s "https://api.example.com/items?page=$page" | jq '.items[]'
done | jq -s 'unique_by(.id)'

# Chain API calls
ID=$(curl -s https://api.example.com/user | jq -r '.id')
curl -s "https://api.example.com/user/$ID/details" | jq '.profile'
```

## jq in Shell Scripts

```bash
# Assign to variable
name=$(echo '{"name":"alice"}' | jq -r '.name')

# Iterate JSON array in bash
echo '[{"f":"a.txt"},{"f":"b.txt"}]' | jq -r '.[].f' | while read -r file; do
  echo "Processing $file"
done

# Conditional on jq output
if echo '{"ok":true}' | jq -e '.ok' > /dev/null 2>&1; then
  echo "Success"
fi

# Build JSON safely from shell variables (avoids injection)
jq -n --arg host "$HOSTNAME" --argjson port 8080 \
  '{host: $host, port: $port}'

# Read JSON into bash associative array
while IFS='=' read -r key value; do
  config[$key]=$value
done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' config.json)

# Modify JSON file in-place (sponge from moreutils, or temp file)
jq '.version = "2.0"' package.json > tmp.json && mv tmp.json package.json
```

## Complex Transformations

```bash
# Reshape: array of objects → object keyed by field
echo '[{"id":"a","val":1},{"id":"b","val":2}]' | \
  jq 'map({(.id): .val}) | add'
# {"a":1,"b":2}

# Reverse: object → array of objects
echo '{"a":1,"b":2}' | jq 'to_entries | map({id: .key, val: .value})'
# [{"id":"a","val":1},{"id":"b","val":2}]

# Merge array of objects
echo '[{"a":1},{"b":2},{"a":3,"c":4}]' | jq 'reduce .[] as $o ({}; . * $o)'
# {"a":3,"b":2,"c":4}

# Pivot/transpose rows to columns
jq 'group_by(.date) | map({date: .[0].date} + (map({(.metric): .value}) | add))'

# Flatten nested object to dot-notation keys
jq '[paths(scalars) as $p | {([$p[] | tostring] | join(".")): getpath($p)}] | add'

# Add/update field conditionally
jq 'map(if .status == "pending" then .status = "processed" else . end)'

# Remove null fields
jq 'del(.[] | nulls)'                          # from array
jq 'with_entries(select(.value != null))'       # from object

# Deep merge two objects
jq -s '.[0] * .[1]' a.json b.json
```

## with_entries / to_entries / from_entries

```bash
# Rename keys
jq 'with_entries(if .key == "old_name" then .key = "new_name" else . end)'

# Filter object keys
jq 'with_entries(select(.key | startswith("user_")))'

# Transform all values
jq 'with_entries(.value |= tostring)'
```

## Useful Built-ins

```bash
keys, values, has("key"), in(obj), contains, inside, length
ltrimstr/rtrimstr, split/join, ascii_downcase/ascii_upcase
startswith/endswith, test("regex"), match("regex"), capture("(?<name>regex)")
limit(n; expr), first(expr), last(expr), range(n), range(a;b)
env.VAR_NAME                          # access environment variables
now | todate                          # current time as ISO8601
add, any, all, empty, debug           # debug prints to stderr
```

## jq vs Alternatives

- **yq**: YAML-native, jq-like syntax → `yq '.spec.containers[0].image' deploy.yaml`
- **xq**: XML→JSON via jq → `cat pom.xml | xq '.project.dependencies'`
- **gron**: flatten JSON for grep → `gron data.json | grep name | gron -u`
- **fx/jless**: interactive JSON exploration/viewing in terminal

## Performance Tips

- Use `--stream` for files too large to fit in memory
- Filter early: `.data[] | select(...)` not `[.data[]] | map(select(...))`
- Prefer `first(.[] | select(...))` over filtering entire array when you need one match
- Use `limit(n; .[] | expr)` to stop after n results
- Avoid `.. | ...` on large structures; use targeted paths instead
- Use `-c` (compact output) when piping to other tools
- `jq empty` validates JSON without producing output (fast syntax check)

## Common One-Liners

```bash
# Validate JSON
jq empty < file.json

# Count array elements
jq 'length' items.json

# Get unique values of a field
jq '[.[].category] | unique' items.json

# Sum a numeric field
jq '[.[].amount] | add' transactions.json

# Find duplicates
jq 'group_by(.email) | map(select(length > 1)) | flatten'

# Top N by field
jq 'sort_by(-.score) | limit(10; .[])' scores.json

# Convert object to env file
jq -r 'to_entries[] | "\(.key)=\(.value)"' config.json > .env

# Diff two JSON files (keys only)
diff <(jq -S 'keys' a.json) <(jq -S 'keys' b.json)

# Extract nested array, deduplicate, sort
jq '[.results[].tags[]] | unique | sort' api.json

# Create lookup table / Join two files on key
jq 'INDEX(.id)' users.json
jq -s 'INDEX(.[0][]; .id) as $lookup | .[1][] | . + $lookup[.user_id]' users.json orders.json
```
