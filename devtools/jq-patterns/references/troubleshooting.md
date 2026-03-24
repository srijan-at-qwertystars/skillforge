# jq Troubleshooting Guide

> Diagnose and fix common jq errors, debug complex filters, handle edge cases,
> and optimize performance for production use.

---

## Table of Contents

- [Common Errors](#common-errors)
  - [Cannot iterate over null](#cannot-iterate-over-null)
  - [Type errors](#type-errors)
  - [Unexpected output](#unexpected-output)
  - [Parse errors](#parse-errors)
  - [Argument errors](#argument-errors)
- [Debugging Techniques](#debugging-techniques)
  - [The debug filter](#the-debug-filter)
  - [stderr for tracing](#stderr-for-tracing)
  - [Step-by-step debugging](#step-by-step-debugging)
- [Understanding jq's Execution Model](#understanding-jqs-execution-model)
  - [Generators and backtracking](#generators-and-backtracking)
  - [How pipes work](#how-pipes-work)
  - [Multiple outputs](#multiple-outputs)
- [Shell Quoting Issues](#shell-quoting-issues)
  - [Single vs double quotes](#single-vs-double-quotes)
  - [Escaping in different shells](#escaping-in-different-shells)
  - [Variable interpolation pitfalls](#variable-interpolation-pitfalls)
- [Large File Handling](#large-file-handling)
- [Unicode Issues](#unicode-issues)
- [Performance Optimization](#performance-optimization)

---

## Common Errors

### Cannot iterate over null

**The most common jq error.** Happens when `.[]` is applied to null.

```bash
# ERROR: Cannot iterate over null (null)
echo '{"data": null}' | jq '.data[]'

# FIX 1: Optional operator ?
echo '{"data": null}' | jq '.data[]?'

# FIX 2: Default value with //
echo '{"data": null}' | jq '(.data // [])[]'

# FIX 3: Guard with select
echo '{"data": null}' | jq '.data | select(. != null) | .[]'

# FIX 4: Conditional
echo '{"data": null}' | jq 'if .data then .data[] else empty end'
```

**Common scenarios that trigger this:**

```bash
# Missing key in some objects
echo '[{"items":[1]},{"other":2}]' | jq '.[].items[]'
# Second object has no .items → null iteration error

# Fix: use ? on the iteration
echo '[{"items":[1]},{"other":2}]' | jq '.[].items[]?'

# Chained access on missing intermediate key
echo '{"a":{}}' | jq '.a.b.c[]'
# .a.b is null → .c fails

# Fix: optional chaining
echo '{"a":{}}' | jq '.a.b?.c?[]?'
```

### Type errors

```bash
# ERROR: string and number cannot be added
echo '{"a":"hello","b":5}' | jq '.a + .b'
# Fix: convert types
echo '{"a":"hello","b":5}' | jq '.a + (.b | tostring)'

# ERROR: null is not iterable
echo '5' | jq '.[]'
# Fix: ensure input is array/object, or use type check
echo '5' | jq 'if type == "array" then .[] else . end'

# ERROR: cannot index number with string "key"
echo '42' | jq '.key'
# Fix: check type first
echo '42' | jq 'if type == "object" then .key else null end'

# ERROR: object is not indexable by number
echo '{"a":1}' | jq '.[0]'
# Objects use string keys, not numeric indices
echo '{"a":1}' | jq '.a'
```

### Unexpected output

```bash
# Problem: getting "null" instead of expected value
echo '{"Name":"alice"}' | jq '.name'
# null — jq is case-sensitive! .name ≠ .Name

# Problem: strings have extra quotes
echo '{"name":"alice"}' | jq '.name'
# "alice"  — use -r for raw output
echo '{"name":"alice"}' | jq -r '.name'
# alice

# Problem: multiple outputs when expecting one
echo '[1,2,3]' | jq '.[]'
# 1  2  3  — wrap in array if you want single output
echo '[1,2,3]' | jq '[.[]]'
# [1,2,3]

# Problem: empty output (no error, no result)
echo '[]' | jq '.[] | select(.x > 5)'
# (nothing) — empty array has nothing to select from
# This is correct behavior; use // to provide default
echo '[]' | jq '[.[] | select(.x > 5)] | if length == 0 then "none found" else . end'

# Problem: output not valid JSON
echo '{"a":1,"b":2}' | jq '.a, .b'
# 1\n2  — multiple outputs; wrap in array for valid JSON
echo '{"a":1,"b":2}' | jq '[.a, .b]'
# [1,2]
```

### Parse errors

```bash
# ERROR: Invalid numeric literal
echo "{'name':'alice'}" | jq '.'
# JSON requires double quotes, not single quotes!
echo '{"name":"alice"}' | jq '.'

# ERROR: parse error (invalid JSON in input)
echo 'not json' | jq '.'
# Fix: validate input first
echo 'not json' | jq -e empty 2>/dev/null || echo "Invalid JSON"

# ERROR: Unexpected end of input
echo '{"a":1' | jq '.'
# Truncated JSON — check upstream source

# Handling mixed JSON/non-JSON input (e.g., command output with headers)
kubectl get pods -o json 2>&1 | jq '.' 2>/dev/null || echo "Not JSON output"
```

### Argument errors

```bash
# ERROR: $name is not defined
jq '.name == $name' data.json
# Fix: pass variables with --arg
jq --arg name "alice" '.name == $name' data.json

# ERROR: --argjson expects JSON value
jq --argjson x hello '.'
# Fix: quote the JSON properly
jq --argjson x '"hello"' '.'   # string
jq --argjson x '42' '.'        # number
jq --argjson x 'true' '.'      # boolean
jq --argjson x 'null' '.'      # null

# Use --arg for strings, --argjson for everything else
jq --arg s "hello" --argjson n 42 '{s: $s, n: $n}'
```

---

## Debugging Techniques

### The debug filter

`debug` prints the current value to stderr without changing the data flow.

```bash
# Basic: inspect current value
echo '{"users":[{"name":"alice"},{"name":"bob"}]}' | \
  jq '.users[] | debug | .name'
# stderr: ["DEBUG:",{"name":"alice"}]
# stderr: ["DEBUG:",{"name":"bob"}]
# stdout: "alice"  "bob"

# With label — identify which debug point
echo '{"a":1,"b":2}' | jq '. | debug("input") | .a | debug("after .a")'
# stderr: ["DEBUG:","input",{"a":1,"b":2}]
# stderr: ["DEBUG:","after .a",1]
# stdout: 1

# Debug in the middle of a pipeline
jq '.data
  | debug("raw data")
  | map(select(.active))
  | debug("after filter")
  | map(.name)
  | debug("final")
' data.json

# Debug with expression
echo '[1,2,3]' | jq 'map(. as $x | debug("processing \($x)") | . * 2)'
```

### stderr for tracing

```bash
# Write custom messages to stderr (doesn't appear in stdout/piped output)
jq -r '.[] | "Processing: \(.name)" | stderr | empty' data.json 2>debug.log

# Combine stderr messages with output
jq '.[]
  | . as $item
  | ("Checking \(.name)" | debug)
  | select(.score > 80)
  | .name
' scores.json
```

### Step-by-step debugging

```bash
# Strategy: build the filter incrementally

# Step 1: verify input structure
jq 'type' data.json                    # "object"? "array"?
jq 'keys' data.json                    # what keys exist?
jq 'length' data.json                  # how many elements?
jq '.[0]' data.json                    # what does first element look like?

# Step 2: test each filter stage
jq '.data' data.json                   # does .data exist?
jq '.data | type' data.json            # what type is it?
jq '.data[]' data.json                 # can we iterate?
jq '.data[] | .name' data.json         # can we access fields?
jq '.data[] | select(.active)' data.json  # does select work?

# Step 3: combine stages
jq '[.data[] | select(.active) | .name]' data.json
```

---

## Understanding jq's Execution Model

### Generators and backtracking

jq filters are **generators**: each filter can produce zero, one, or many outputs.

```bash
# .[] is a generator — it produces one output per element
echo '[1,2,3]' | jq '.[]'
# Output: 1  2  3  (three separate outputs)

# Generators compose: each output feeds the next filter
echo '[[1,2],[3,4]]' | jq '.[][] '
# Output: 1  2  3  4  (inner .[] runs for each outer .[] output)

# select is a generator: produces 0 or 1 outputs
echo '[1,2,3]' | jq '.[] | select(. > 1)'
# Output: 2  3  (1 is "dropped" — select produced 0 outputs for it)

# empty is a generator that produces 0 outputs
echo '[1,2,3]' | jq '.[] | if . == 2 then empty else . end'
# Output: 1  3

# The comma operator creates a generator with multiple outputs
echo '5' | jq '., . * 2, . * 3'
# Output: 5  10  15
```

### How pipes work

```bash
# Each pipe stage receives ALL outputs from the previous stage, one at a time
echo '{"a":[1,2],"b":[3,4]}' | jq '.a[], .b[]'
# Output: 1  2  3  4
# .a[] produces 1,2 then .b[] produces 3,4

# Pipe vs comma:
# .a | .b     → take output of .a, feed to .b
# .a , .b     → produce outputs of .a AND .b independently

# Understanding: map(f) is equivalent to [.[] | f]
echo '[1,2,3]' | jq '[.[] | . * 2]'      # [2,4,6]
echo '[1,2,3]' | jq 'map(. * 2)'          # [2,4,6]  (same thing)
```

### Multiple outputs

```bash
# Problem: unexpected multiplication of results
echo '{"a":1}' | jq '{x: (.a, .a * 2)}'
# {"x":1}
# {"x":2}
# The comma generates two values, so the object is constructed twice

# To get both in one object, wrap in array:
echo '{"a":1}' | jq '{x: [.a, .a * 2]}'
# {"x":[1,2]}

# Problem: cross-product with multiple generators
echo 'null' | jq -n '{a: (1,2), b: (3,4)}'
# {"a":1,"b":3}  {"a":1,"b":4}  {"a":2,"b":3}  {"a":2,"b":4}
# 4 outputs! Each generator independently produces values
```

---

## Shell Quoting Issues

### Single vs double quotes

```bash
# RULE: Always use single quotes for jq filters in bash
# Single quotes prevent shell interpretation

# CORRECT — single quotes protect the jq expression
jq '.users[] | select(.name == "alice")' data.json

# WRONG — double quotes cause shell to interpret $, ", \
jq ".users[] | select(.name == \"alice\")" data.json  # fragile, error-prone

# WRONG — shell expands $name before jq sees it
name="alice"
jq ".users[] | select(.name == \"$name\")" data.json
# If $name contains quotes or special chars, this breaks or injects

# CORRECT — use --arg for shell variables
name="alice"
jq --arg n "$name" '.users[] | select(.name == $n)' data.json
```

### Escaping in different shells

```bash
# Bash: single quotes can't contain single quotes
# Solution 1: end+escape+reopen
jq '.name == '"'"'O'"'"'Brien'"'"''
# Builds: .name == 'O'Brien'

# Solution 2: use double quotes with escaping (less readable)
jq ".name == \"O'Brien\""

# Solution 3 (preferred): use --arg
jq --arg n "O'Brien" '.name == $n'

# Zsh: similar to bash, single quotes are simplest
# Fish: use single quotes; fish doesn't expand $ in single quotes
# PowerShell: use single quotes; for embedded quotes use ''
# cmd.exe (Windows): use double quotes, escape inner quotes with \"
```

### Variable interpolation pitfalls

```bash
# DANGER: never interpolate untrusted input directly
user_input='"; . as $x | halt'  # malicious input
jq ".name == \"$user_input\"" data.json  # CODE INJECTION!

# SAFE: always use --arg for any external data
jq --arg input "$user_input" '.name == $input' data.json

# Multiple variables
jq --arg name "$NAME" --arg email "$EMAIL" \
   '.[] | select(.name == $name and .email == $email)' data.json

# JSON variables (numbers, booleans, objects)
jq --argjson min "$MIN_SCORE" --argjson max "$MAX_SCORE" \
   '.[] | select(.score >= $min and .score <= $max)' data.json

# Using env (requires export)
export THRESHOLD=50
jq '[.[] | select(.score > (env.THRESHOLD | tonumber))]' data.json

# Heredoc for complex filters
jq -f /dev/stdin data.json <<'EOF'
  .users[]
  | select(.active)
  | {name, email}
EOF
```

---

## Large File Handling

### Memory-Efficient Processing

```bash
# Problem: jq loads entire input into memory by default
# 10GB JSON file → 10GB+ RAM usage → crash

# Solution 1: --stream for large single objects/arrays
jq -cn --stream '
  fromstream(1|truncate_stream(inputs))
  | select(.status == "error")
' huge_array.json

# Solution 2: NDJSON — one JSON object per line
# Most memory-efficient: each line processed independently
jq -c 'select(.level == "error")' huge.jsonl

# Solution 3: split before processing
# Split large array into individual objects
jq -c '.[]' huge_array.json > objects.jsonl
# Process line by line
jq -c 'select(.active)' objects.jsonl

# Solution 4: --slurp with care
# Only use -s when you need cross-record operations
# AND the data fits in memory
jq -s 'group_by(.category)' small_enough.jsonl

# Counting without loading everything
jq -cn --stream 'reduce (inputs | select(length == 2)) as $_ (0; . + 1)' huge.json

# Streaming extraction of specific paths
jq -cn --stream '
  select(.[0] == ["results"] and length == 2)
  | .[1]
' huge_response.json
```

### Chunked Processing

```bash
# Process in chunks with split + xargs
jq -c '.[]' huge.json | \
  split -l 1000 - /tmp/chunk_ && \
  for f in /tmp/chunk_*; do
    jq -s 'map(select(.active)) | length' "$f"
  done | jq -s 'add'

# GNU parallel for CPU-bound jq on NDJSON
cat huge.jsonl | parallel --pipe -L1000 'jq -s "map(.value) | add"' | jq -s 'add'
```

---

## Unicode Issues

```bash
# jq handles UTF-8 natively
echo '{"name":"café"}' | jq '.name'           # "café"
echo '{"emoji":"🎉"}' | jq '.emoji'           # "🎉"

# length counts Unicode codepoints, not bytes
echo '"café"' | jq 'length'                    # 4
echo '"café"' | jq 'utf8bytelength'            # 5

# Escaped Unicode in JSON is handled automatically
echo '{"name":"caf\\u00e9"}' | jq '.name'      # "café"

# Explode/implode for codepoint manipulation
echo '"hello"' | jq 'explode'                  # [104,101,108,108,111]
echo '[104,101,108,108,111]' | jq 'implode'    # "hello"

# Problem: BOM (byte order mark) in input
# Remove BOM before piping to jq
sed '1s/^\xEF\xBB\xBF//' file.json | jq '.'
# Or: use file with -f and ensure UTF-8 without BOM

# Problem: binary data in JSON strings
# jq expects valid UTF-8; binary data will cause parse errors
# Fix: base64 encode binary data before putting in JSON

# Problem: locale issues
# Ensure LC_ALL=C.UTF-8 or LANG=en_US.UTF-8 in your environment
export LC_ALL=C.UTF-8
jq '.' data.json
```

---

## Performance Optimization

### Filter Order Matters

```bash
# SLOW: select after expensive transformation
jq '[.[] | heavy_transform | select(.active)]'

# FAST: select first, then transform
jq '[.[] | select(.active) | heavy_transform]'

# SLOW: full recursive descent
jq '[.. | .id? // empty]'

# FAST: targeted path if you know the structure
jq '[.data[].items[].id]'
```

### Avoid Common Anti-patterns

```bash
# SLOW: map + select + map
jq 'map(select(.x)) | map(.name)'

# FAST: combine into single pass
jq '[.[] | select(.x) | .name]'

# SLOW: repeated key lookups in O(n²) join
jq '.users[] as $u | .orders[] | select(.uid == $u.id)'

# FAST: build index first — O(n) join
jq 'INDEX(.users[]; .id) as $u | .orders[] | . + {user: $u[.uid]}'

# SLOW: string concatenation in a loop
jq 'reduce .[] as $x (""; . + $x)'

# FAST: join
jq 'join("")'

# SLOW: repeated calls to jq (one per line)
while read -r line; do
  echo "$line" | jq '.name'
done < data.jsonl

# FAST: let jq process all lines at once
jq -r '.name' data.jsonl
```

### Benchmarking

```bash
# Time your jq commands
time jq '.data[] | select(.active)' large.json > /dev/null

# Compare approaches
echo "Approach 1:"
time jq 'map(select(.x > 5))' data.json > /dev/null

echo "Approach 2:"
time jq '[.[] | select(.x > 5)]' data.json > /dev/null

# Profile with --debug-dump-disasm (if available)
jq --debug-dump-disasm 'map(select(.x))' < /dev/null 2>&1

# Validate without output overhead
time jq empty large.json
```

### Compilation Tips

```bash
# Use -f for reusable complex filters (avoid re-parsing)
echo '.data[] | select(.active) | {name, id}' > filter.jq
jq -f filter.jq data1.json data2.json data3.json

# Pre-validate JSON (fast check)
jq empty suspicious.json && echo "Valid" || echo "Invalid"

# Use --jsonargs for multiple JSON inputs on command line
jq -n --jsonargs '$ARGS.positional' -- '{"a":1}' '{"b":2}'
```
