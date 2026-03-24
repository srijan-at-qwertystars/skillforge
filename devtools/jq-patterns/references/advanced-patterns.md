# Advanced jq Patterns

> Deep-dive into jq's powerful features beyond basic filters: streaming, joins,
> modules, control flow, complex data reshaping, and pipeline integration.

---

## Table of Contents

- [Streaming Parser](#streaming-parser)
- [SQL-Like Joins with INDEX/IN](#sql-like-joins-with-indexin)
- [jq Modules (import/include)](#jq-modules-importinclude)
- [Control Flow: label-break, limit, first, last, until](#control-flow)
- [Environment Variables (env/$ENV)](#environment-variables)
- [Recursive Descent Patterns](#recursive-descent-patterns)
- [Complex Data Reshaping](#complex-data-reshaping)
- [Builtins Reference](#builtins-reference)
- [jq in CI/CD Pipelines](#jq-in-cicd-pipelines)

---

## Streaming Parser

### The Problem

Loading a multi-gigabyte JSON file into memory crashes jq. The streaming parser
processes JSON incrementally, emitting `[path, value]` pairs as it reads.

### --stream Flag

```bash
# Stream emits [path, leaf_value] pairs and [path] end-markers
echo '{"a":1,"b":[2,3]}' | jq --stream -c '.'
# [[\"a\"],1]
# [[\"b\",0],2]
# [[\"b\",1],3]
# [[\"b\",1]]
# [[\"b\"]]

# Extract values at specific paths
echo '{"users":[{"name":"alice"},{"name":"bob"}]}' | \
  jq --stream -c 'select(.[0][-1] == "name") | .[1]'
# "alice"
# "bob"
```

### tostream / fromstream

```bash
# Convert in-memory JSON to stream form
echo '{"a":1,"b":2}' | jq '[tostream]'
# [["a",1],["b",2],["b"]]

# fromstream: rebuild JSON from stream events
echo '{"a":1,"b":2,"c":3}' | \
  jq 'fromstream(tostream | select(.[0][0] != "b"))'
# {"a":1,"c":3}

# truncate_stream: strip N levels of nesting from stream paths
echo '[{"a":1},{"b":2}]' | \
  jq -c --stream 'fromstream(1|truncate_stream(inputs))'
# {"a":1}
# {"b":2}
```

### Streaming Patterns for Large Files

```bash
# Count objects in a huge array without loading it all
jq -cn --stream '[.,inputs] | select(length==2 and .[0][0]!=.[0][-1])' \
  huge.json | wc -l

# Extract specific fields from streamed objects
jq -cn --stream '
  fromstream(1|truncate_stream(inputs))
  | {name: .name, id: .id}
' huge_array.json

# Filter streamed objects
jq -cn --stream '
  fromstream(1|truncate_stream(inputs))
  | select(.status == "active")
' huge_array.json

# Process NDJSON line-by-line (already streaming by nature)
jq -c 'select(.level == "error")' app.jsonl
```

---

## SQL-Like Joins with INDEX/IN

### INDEX — Build a Lookup Table

```bash
# INDEX(stream; key_expr) → object keyed by key_expr
echo '[{"id":"a","name":"Alice"},{"id":"b","name":"Bob"}]' | \
  jq 'INDEX(.[]; .id)'
# {"a":{"id":"a","name":"Alice"},"b":{"id":"b","name":"Bob"}}

# Single-arg form: INDEX(key_expr) on current input array
echo '[{"id":1,"v":"x"},{"id":2,"v":"y"}]' | jq 'INDEX(.id)'
# {"1":{"id":1,"v":"x"},"2":{"id":2,"v":"y"}}
```

### IN — Membership Test

```bash
# IN(stream; expr) — test if value appears in stream
echo '["a","b","c"]' | jq '[.[] | IN("a","c")]'
# [true,false,true]

# Filter using IN
echo '[1,2,3,4,5]' | jq '[.[] | select(IN(2,4,5))]'
# [2,4,5]
```

### SQL-Style Joins

```bash
# Inner join: users + orders on user_id
# users.json: [{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]
# orders.json: [{"user_id":1,"item":"Book"},{"user_id":1,"item":"Pen"},{"user_id":2,"item":"Hat"}]

jq -s '
  INDEX(.[0][]; .id) as $users
  | .[1][]
  | . + {user_name: $users[.user_id | tostring].name}
' users.json orders.json

# Left join: keep all users, attach orders
jq -s '
  INDEX(.[1][]; .user_id | tostring) as $orders
  | .[0][]
  | . + {order: $orders[.id | tostring]}
' users.json orders.json

# Multi-file join using --slurpfile
jq --slurpfile users users.json '
  INDEX($users[]; .id) as $lookup
  | .[]
  | . + {name: $lookup[.user_id].name}
' orders.json

# Group-join: users with array of their orders
jq -s '
  INDEX(.[0][]; .id) as $users
  | .[1]
  | group_by(.user_id)
  | map({
      user: $users[.[0].user_id | tostring].name,
      orders: map(.item)
    })
' users.json orders.json
```

---

## jq Modules (import/include)

### Creating a Module

```bash
# File: ~/.jq/utils.jq
# def sum: reduce .[] as $x (0; . + $x);
# def avg: if length == 0 then 0 else sum / length end;
# def pluck(f): [.[] | f];
# def compact: map(select(. != null and . != ""));
```

### Importing Modules

```bash
# import brings functions into a namespace
jq 'import "utils" as u; [.scores[]] | u::avg' data.json

# include injects functions directly (no namespace prefix)
jq 'include "utils"; [.scores[]] | avg' data.json
```

### Module Search Path

```bash
# jq searches these directories for modules:
# 1. ~/.jq/        (user modules)
# 2. $ORIGIN/../lib/jq/  (relative to jq binary)
# 3. Paths specified with -L flag

jq -L ./lib 'import "mymodule" as m; m::transform' data.json
```

### Module Metadata

```jq
# Modules can declare metadata
module {
  "name": "utils",
  "version": "1.0",
  "description": "Common utility functions"
};

def sum: reduce .[] as $x (0; . + $x);
```

---

## Control Flow

### label-break

```bash
# label-break provides early exit from nested computation
echo '[1,2,3,4,5]' | jq '
  label $out
  | foreach .[] as $x (0;
      . + $x;
      if . > 6 then ., break $out else . end
    )
'
# 1, 3, 6, 10   (stops after sum exceeds 6)
```

### limit

```bash
# limit(n; expr): take first n outputs from expr
echo '[1,2,3,4,5,6,7,8,9,10]' | jq '[limit(3; .[])]'
# [1,2,3]

# Efficient: stops evaluation after n results
jq '[limit(5; .[] | select(.active))]' huge.json

# Use with generators
jq '[limit(10; recurse(. * 2; . < 10000) | select(. > 100))]' <<< '1'
```

### first / last

```bash
# first(expr): emit only the first output of expr
echo '[5,3,1,4,2]' | jq 'first(.[] | select(. < 3))'
# 1

# last(expr): emit only the last output of expr
echo '[5,3,1,4,2]' | jq 'last(.[] | select(. > 3))'
# 4

# Short forms
echo '[1,2,3]' | jq 'first'     # 1  (same as .[0])
echo '[1,2,3]' | jq 'last'      # 3  (same as .[-1])
```

### until

```bash
# until(cond; update): repeatedly apply update until cond is true
echo '1' | jq 'until(. >= 100; . * 2)'
# 128

# Find first power of 2 greater than input
echo '50' | jq 'until(. > 50; . * 2)' <<< '1'

# Newton's method for square root
echo '25' | jq '
  . as $n
  | {x: ., prev: 0}
  | until((.x - .prev) | fabs < 0.0001;
      .x as $prev
      | {x: ((.x + $n / .x) / 2), prev: $prev}
    )
  | .x
'
# 5.000000000016778

# Fibonacci with until
echo 'null' | jq -n '
  {a: 0, b: 1, n: 0}
  | until(.n >= 10; {a: .b, b: (.a + .b), n: (.n + 1)})
  | .a
'
# 55
```

### while

```bash
# while(cond; update): emit values while cond is true
echo '1' | jq '[.,1] | while(.[0] < 100; [.[0] * 2, .[1] + 1]) | .[0]'
# 1 2 4 8 16 32 64

# Generate a sequence
echo 'null' | jq -n '[1 | while(. < 20; . + 3)]'
# [1,4,7,10,13,16,19]
```

### recurse

```bash
# recurse(f): apply f repeatedly, outputting each step
# Useful alternative to .. for controlled recursion

# Powers of 2 less than 1000
echo '1' | jq '[recurse(. * 2; . < 1000)]'
# [1,2,4,8,16,32,64,128,256,512]

# Walk a tree structure
echo '{"name":"root","children":[{"name":"a","children":[{"name":"b","children":[]}]}]}' | \
  jq '[recurse(.children[]?) | .name]'
# ["root","a","b"]
```

---

## Environment Variables

### env and $ENV

```bash
# Access all environment variables
jq -n 'env'                        # full environment as object
jq -n 'env.HOME'                   # single variable
jq -n 'env | keys'                 # list all variable names

# $ENV is equivalent
jq -n '$ENV.PATH'
jq -n '$ENV["HOME"]'

# Use in filters — dynamic config
export API_BASE="https://api.example.com"
echo '{"path":"/users"}' | jq -r 'env.API_BASE + .path'
# https://api.example.com/users

# Build config from environment
jq -n '{
  database: env.DB_HOST,
  port: (env.DB_PORT // "5432" | tonumber),
  debug: (env.DEBUG // "false" | . == "true")
}'

# Check if variable is set
jq -n 'env.MY_VAR // error("MY_VAR not set")'
```

### $__loc__

```bash
# $__loc__ returns the current source location (for debugging modules)
jq -n '$__loc__'
# {"file":"<stdin>","line":1}

# Useful in module debugging
# In mymodule.jq:
# def traced(f): debug("at \($__loc__)") | f;
```

---

## Recursive Descent Patterns

### Basic Recursive Descent (..)

```bash
# .. is equivalent to recurse without arguments
# Descends into all values: objects, arrays, and their elements

# Find all values for key "id" at any depth
jq '.. | .id? // empty'

# Collect all strings in a structure
jq '[.. | strings]'

# Find all objects with a specific key
jq '[.. | objects | select(has("error"))]'
```

### walk — Recursive Transformation

```bash
# walk(f): apply f to every value bottom-up
# Available in jq 1.6+ (built-in) or define manually:
# def walk(f): if type=="object" then to_entries|map(.value|=walk(f))|from_entries|f
#              elif type=="array" then map(walk(f))|f else f end;

# Convert all keys to lowercase
jq 'walk(if type == "object" then with_entries(.key |= ascii_downcase) else . end)'

# Trim all string values
jq 'walk(if type == "string" then gsub("^\\s+|\\s+$"; "") else . end)'

# Recursively remove null values
jq 'walk(if type == "object" then with_entries(select(.value != null)) else . end)'

# Add a field to every object at any depth
jq 'walk(if type == "object" then . + {"_processed": true} else . end)'
```

### env / paths — Targeted Recursion

```bash
# Find paths to specific values
jq '[paths(. == "error")]' deeply_nested.json

# Find and modify deeply nested values
jq 'reduce paths(. == "REDACTED") as $p (.; setpath($p; "***"))' data.json

# Flatten deeply nested structure to dot-notation
jq '
  [paths(scalars) as $p |
    {key: ($p | map(tostring) | join(".")),
     value: getpath($p)}
  ] | from_entries
'
```

---

## Complex Data Reshaping

### Pivot Tables

```bash
# Input: [{date:"2024-01",metric:"sales",value:100},{date:"2024-01",metric:"visits",value:500},...]
# Output: [{date:"2024-01",sales:100,visits:500},...]

jq '
  group_by(.date)
  | map(
      {date: .[0].date}
      + (map({(.metric): .value}) | add)
    )
'

# Unpivot (melt): columns → rows
# Input: [{date:"2024-01",sales:100,visits:500}]
# Output: [{date:"2024-01",metric:"sales",value:100},{date:"2024-01",metric:"visits",value:500}]
jq '
  .[]
  | . as $row
  | keys_unsorted
  | map(select(. != "date"))
  | map({date: $row.date, metric: ., value: $row[.]})
  | .[]
'
```

### Denormalization

```bash
# Embed related records inline
# departments.json: [{"id":1,"name":"Engineering"}]
# employees.json: [{"name":"Alice","dept_id":1}]

jq -s '
  INDEX(.[0][]; .id) as $depts
  | .[1][]
  | .department = $depts[.dept_id | tostring].name
  | del(.dept_id)
' departments.json employees.json
```

### Tree Flattening

```bash
# Flatten a tree to paths
# Input: {"a":{"b":{"c":1},"d":2},"e":3}
jq '
  [paths(scalars)] as $paths
  | [$paths[] as $p | {
      path: ($p | join("/")),
      value: getpath($p)
    }]
'
# [{"path":"a/b/c","value":1},{"path":"a/d","value":2},{"path":"e","value":3}]

# Unflatten dot-notation back to nested structure
# Input: {"a.b.c":1,"a.d":2,"e":3}
jq '
  to_entries
  | reduce .[] as $e ({};
      setpath($e.key | split("."); $e.value)
    )
'
# {"a":{"b":{"c":1},"d":2},"e":3}
```

### Cross-Tabulation

```bash
# Count occurrences by two dimensions
# Input: [{"region":"US","product":"A"},{"region":"EU","product":"A"},...]
jq '
  group_by(.region)
  | map({
      region: .[0].region,
      counts: (group_by(.product) | map({(.[0].product): length}) | add)
    })
'
```

### Transpose

```bash
# Transpose array of arrays
echo '[[1,2,3],[4,5,6]]' | jq 'transpose'
# [[1,4],[2,5],[3,6]]

# Transpose with headers (CSV-like)
jq '
  .[0] as $headers
  | .[1:]
  | map([$headers, .] | transpose | map({(.[0]): .[1]}) | add)
'
```

---

## Builtins Reference

### Math

```bash
nan, infinite, isinfinite, isnan, isnormal, isfinite
floor, ceil, round, trunc, fabs, sqrt, pow(x;y)
log, log2, log10, exp, exp2, exp10
sin, cos, tan, asin, acos, atan, atan(x;y)
significand, exponent, drem(x;y), ldexp(x;y)
j0, j1                    # Bessel functions
```

### String

```bash
length                     # string length (UTF-8 codepoints)
utf8bytelength             # byte length
ascii_downcase, ascii_upcase
ltrimstr(s), rtrimstr(s)   # trim prefix/suffix
startswith(s), endswith(s)
split(s), join(s)          # "a,b" | split(",") → ["a","b"]
gsub(re; s), sub(re; s)   # regex replace (all / first)
test(re), match(re)        # regex test / full match info
capture(re)                # named captures → object
scan(re)                   # all matches as array
@base64, @base64d, @uri, @csv, @tsv, @html, @json, @text
explode, implode           # string ↔ codepoint array
ascii                      # codepoint of first char
tojsonstream, fromjsonstream
```

### Array

```bash
length, reverse, sort, sort_by(f), group_by(f), unique, unique_by(f)
flatten, flatten(n)        # flatten n levels
min, max, min_by(f), max_by(f)
add                        # sum numbers / concat strings/arrays
any, any(f), all, all(f)   # boolean aggregation
contains(x), inside(x)
indices(x), index(x), rindex(x)
first, last, first(f), last(f)
nth(n), nth(n; f)          # nth output of f
range(n), range(a;b), range(a;b;step)
limit(n; f)                # first n outputs of f
until(cond; f)             # loop until
while(cond; f)             # loop while
repeat(f)                  # infinite loop (use with limit)
transpose                  # transpose array of arrays
input, inputs              # read from stdin / remaining inputs
debug, debug(msg)          # print to stderr
```

### Object

```bash
keys, keys_unsorted, values, has(k), in(obj)
to_entries, from_entries, with_entries(f)
del(path), getpath(p), setpath(p;v), delpaths(ps)
paths, paths(f), leaf_paths
```

### Type System

```bash
type                       # "object","array","string","number","boolean","null"
type_error                 # raise type error
strings, numbers, objects, arrays, booleans, nulls, iterables, scalars
isinfinite, isnan, isnormal, isfinite
tostring, tonumber, ascii  # conversions
tojson, fromjson           # serialize / deserialize
```

### Date/Time

```bash
now                        # current Unix epoch (float)
todate                     # epoch → ISO 8601 string
fromdate                   # ISO 8601 → epoch
strftime(fmt)              # format epoch → string
strptime(fmt)              # parse string → broken-down time
mktime                     # broken-down time → epoch
gmtime                     # epoch → broken-down time (UTC)
```

### I/O and System

```bash
input                      # read next JSON input
inputs                     # stream remaining JSON inputs
debug, debug(msg)          # write to stderr, pass through
stderr                     # write to stderr (raw)
input_line_number          # current line number
env, $ENV                  # environment variables
builtins                   # list all builtin function names
length                     # works on strings, arrays, objects, null
empty                      # produce zero outputs
error, error(msg)          # raise error
halt, halt_error, halt_error(code)
path(expr)                 # output path to expr
$__loc__                   # source location {file, line}
```

---

## jq in CI/CD Pipelines

### GitHub Actions

```yaml
# .github/workflows/deploy.yml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Get version from package.json
        id: version
        run: |
          VERSION=$(jq -r .version package.json)
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"

      - name: Check release exists
        run: |
          RELEASE=$(curl -s -H "Authorization: Bearer ${{ secrets.GITHUB_TOKEN }}" \
            "https://api.github.com/repos/${{ github.repository }}/releases/latest" \
            | jq -r '.tag_name')
          echo "Latest release: $RELEASE"

      - name: Update config for environment
        run: |
          jq --arg env "${{ github.ref_name }}" \
             --arg sha "${{ github.sha }}" \
             '.environment = $env | .commit = $sha' \
             config.json > config.tmp && mv config.tmp config.json
```

### GitLab CI

```yaml
# .gitlab-ci.yml
extract-version:
  script:
    - VERSION=$(jq -r .version package.json)
    - echo "VERSION=$VERSION" >> variables.env
  artifacts:
    reports:
      dotenv: variables.env

validate-json:
  script:
    - |
      for f in configs/*.json; do
        if ! jq empty "$f" 2>/dev/null; then
          echo "Invalid JSON: $f" >&2
          exit 1
        fi
      done
```

### Makefile

```makefile
VERSION := $(shell jq -r .version package.json)
DEPS := $(shell jq -r '.dependencies | keys[]' package.json)

.PHONY: info
info:
	@echo "Version: $(VERSION)"
	@echo "Dependencies: $(DEPS)"

.PHONY: config
config:
	@jq --arg env "$(ENV)" '.environment = $$env' config.json > config.tmp
	@mv config.tmp config.json

.PHONY: validate
validate:
	@find . -name '*.json' -exec sh -c 'jq empty "$$1" || exit 1' _ {} \;
	@echo "All JSON files valid"
```

### Pipeline Patterns

```bash
# Version bumping
jq '.version |= (split(".") | .[2] = ((.[2]|tonumber) + 1 | tostring) | join("."))' \
  package.json

# Merge environment-specific config
jq -s '.[0] * .[1]' base-config.json "env/${DEPLOY_ENV}.json" > config.json

# Generate deployment manifest from template
jq --arg image "$DOCKER_IMAGE" \
   --arg tag "$GIT_SHA" \
   --argjson replicas "$REPLICAS" \
   '.spec.template.spec.containers[0].image = "\($image):\($tag)"
    | .spec.replicas = $replicas' \
   k8s-template.json > k8s-deploy.json

# Validate API response in tests
RESPONSE=$(curl -s "$API_URL/health")
if ! echo "$RESPONSE" | jq -e '.status == "healthy"' > /dev/null 2>&1; then
  echo "Health check failed: $RESPONSE" >&2
  exit 1
fi

# Aggregate test results
jq -s '{
  total: map(.tests) | add,
  passed: map(.passed) | add,
  failed: map(.failed) | add,
  duration: map(.duration) | add
}' results/*.json
```
