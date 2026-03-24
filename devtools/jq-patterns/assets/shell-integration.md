# Shell Integration Patterns for jq

> Patterns for using jq in bash scripts, Makefiles, and CI/CD pipelines.

---

## Table of Contents

- [Bash Script Patterns](#bash-script-patterns)
- [Variable Handling](#variable-handling)
- [Iteration Patterns](#iteration-patterns)
- [Error Handling](#error-handling)
- [Makefile Integration](#makefile-integration)
- [CI/CD Pipeline Patterns](#cicd-pipeline-patterns)
- [Shell Functions Library](#shell-functions-library)
- [Tips & Gotchas](#tips--gotchas)

---

## Bash Script Patterns

### Reading JSON values into variables

```bash
# Single value
name=$(jq -r '.name' config.json)

# Multiple values (one jq call, not multiple!)
read -r name email role < <(jq -r '[.name, .email, .role] | @tsv' config.json)

# Into an array
mapfile -t names < <(jq -r '.[].name' users.json)
echo "${names[0]}"    # first name
echo "${#names[@]}"   # count
```

### Building JSON safely from shell variables

```bash
# ALWAYS use --arg / --argjson — never interpolate variables into jq strings

# String variables
jq -n --arg host "$HOSTNAME" --arg user "$USER" \
  '{host: $host, user: $user}'

# Numeric / boolean / null
jq -n --argjson port "${PORT:-8080}" --argjson debug "${DEBUG:-false}" \
  '{port: $port, debug: $debug}'

# Build from environment
export APP_NAME="myapp" APP_VERSION="1.0"
jq -n 'env | with_entries(select(.key | startswith("APP_")))'

# Combine shell array into JSON array
tags=("web" "production" "v2")
printf '%s\n' "${tags[@]}" | jq -R . | jq -s '{tags: .}'
```

### Modifying JSON files in-place

```bash
# Method 1: temp file (portable, safe)
jq '.version = "2.0"' config.json > config.json.tmp && mv config.json.tmp config.json

# Method 2: sponge (requires moreutils)
jq '.version = "2.0"' config.json | sponge config.json

# Method 3: variable (for small files)
content=$(jq '.version = "2.0"' config.json) && echo "$content" > config.json

# Atomic update with error checking
update_json() {
    local file="$1" filter="$2"
    local tmp="${file}.tmp.$$"
    if jq "$filter" "$file" > "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        echo "Failed to update $file" >&2
        return 1
    fi
}
update_json config.json '.version = "2.0"'
```

### Conditional logic based on JSON

```bash
# Check a boolean field
if jq -e '.enabled' config.json > /dev/null 2>&1; then
    echo "Feature is enabled"
fi

# Check if field exists and has value
if jq -e '.database.host // empty' config.json > /dev/null 2>&1; then
    echo "Database configured"
fi

# Switch on string value
case $(jq -r '.environment' config.json) in
    production)  deploy_prod ;;
    staging)     deploy_staging ;;
    *)           deploy_dev ;;
esac
```

---

## Variable Handling

### Passing variables to jq

```bash
# Strings → --arg (always string type in jq)
jq --arg name "$USER_NAME" '.[] | select(.name == $name)' data.json

# JSON values → --argjson (preserves type)
jq --argjson limit "$LIMIT" '.[] | select(.count > $limit)' data.json

# File contents → --slurpfile (loads as array)
jq --slurpfile allow allowlist.json '
  .[] | select(.id | IN($allow[][]))
' data.json

# Raw file contents → --rawfile (loads as string)
jq --rawfile tmpl template.txt '{body: $tmpl, type: "text"}' data.json

# Environment variables (requires export)
export TARGET="production"
jq 'select(.env == env.TARGET)' data.json

# $ARGS for positional
jq -n --args '$ARGS.positional' -- "hello" "world"
# ["hello", "world"]

jq -n --jsonargs '$ARGS.positional' -- '{"a":1}' '{"b":2}'
# [{"a":1}, {"b":2}]
```

### Avoiding injection

```bash
# DANGEROUS — shell expansion in jq filter
user_input='"; halt_error'
jq ".name == \"$user_input\"" data.json  # INJECTION!

# SAFE — always use --arg
jq --arg input "$user_input" '.name == $input' data.json

# SAFE — use env
export SEARCH_TERM="$user_input"
jq 'select(.name == env.SEARCH_TERM)' data.json
```

---

## Iteration Patterns

### Processing JSON arrays in bash

```bash
# Simple: one field per line
jq -r '.[].name' users.json | while IFS= read -r name; do
    echo "Hello, $name"
done

# Multiple fields per record (tab-separated)
jq -r '.[] | [.name, .email, .role] | @tsv' users.json | \
while IFS=$'\t' read -r name email role; do
    echo "Creating account for $name ($email) as $role"
    create_account "$name" "$email" "$role"
done

# Process complex objects (compact JSON per line)
jq -c '.[]' records.json | while IFS= read -r record; do
    id=$(echo "$record" | jq -r '.id')
    name=$(echo "$record" | jq -r '.name')
    echo "Processing $id: $name"
done

# With index tracking
jq -c '.[] | {i: input_line_number, d: .}' records.json 2>/dev/null | \
while IFS= read -r line; do
    echo "$line" | jq -r '"\(.i): \(.d.name)"'
done

# Parallel processing with xargs
jq -r '.[].url' urls.json | xargs -P4 -I{} curl -sS "{}"
```

### Accumulating results

```bash
# Collect outputs into a file, then combine
: > results.json  # truncate
jq -r '.[].id' items.json | while IFS= read -r id; do
    curl -s "https://api.example.com/items/$id" >> results.json
done
jq -s '.' results.json > combined.json

# Using process substitution
jq -s '.' <(
    jq -r '.[].id' items.json | while IFS= read -r id; do
        curl -s "https://api.example.com/items/$id"
    done
) > combined.json
```

---

## Error Handling

### Robust jq in scripts

```bash
#!/usr/bin/env bash
set -euo pipefail

# Validate input before processing
validate_json() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "Error: File not found: $file" >&2
        return 1
    fi
    if ! jq empty "$file" 2>/dev/null; then
        echo "Error: Invalid JSON: $file" >&2
        return 1
    fi
}

# Safe jq wrapper with error context
safe_jq() {
    local filter="$1"
    shift
    local result
    if ! result=$(jq "$filter" "$@" 2>&1); then
        echo "jq error: $result" >&2
        echo "  filter: $filter" >&2
        echo "  files: $*" >&2
        return 1
    fi
    echo "$result"
}

# Retry pattern for API + jq
fetch_and_parse() {
    local url="$1" filter="${2:-.}" retries=3
    local attempt=0 response
    while (( attempt < retries )); do
        if response=$(curl -sf "$url") && echo "$response" | jq -e "$filter" > /dev/null 2>&1; then
            echo "$response" | jq "$filter"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep $((attempt * 2))
    done
    echo "Failed after $retries attempts: $url" >&2
    return 1
}
```

### Handling missing/optional data

```bash
# Default values
version=$(jq -r '.version // "0.0.0"' package.json)

# Required fields with error
required_field() {
    local file="$1" field="$2"
    local value
    value=$(jq -r "$field // empty" "$file")
    if [[ -z "$value" ]]; then
        echo "Required field missing: $field in $file" >&2
        exit 1
    fi
    echo "$value"
}
db_host=$(required_field config.json '.database.host')
```

---

## Makefile Integration

### Basic patterns

```makefile
# Extract version from package.json
VERSION := $(shell jq -r .version package.json)

# Get list of dependencies
DEPS := $(shell jq -r '.dependencies | keys[]' package.json)

# Conditional based on config
DEBUG := $(shell jq -r '.debug // false' config.json)
ifeq ($(DEBUG),true)
  BUILD_FLAGS += -DDEBUG
endif

.PHONY: version
version:
	@echo "$(VERSION)"
```

### Config management

```makefile
ENV ?= development

.PHONY: config
config:
	@jq -s '.[0] * .[1]' \
		config/base.json \
		config/$(ENV).json \
		> config/resolved.json
	@echo "Config generated for $(ENV)"

.PHONY: config-validate
config-validate:
	@jq -e '.host and .port and .database' config/resolved.json > /dev/null \
		|| (echo "ERROR: Missing required config fields" >&2; exit 1)

.PHONY: config-show
config-show:
	@jq -C '.' config/resolved.json
```

### Build artifacts

```makefile
.PHONY: manifest
manifest:
	@jq -n \
		--arg version "$(VERSION)" \
		--arg commit "$(shell git rev-parse --short HEAD)" \
		--arg date "$(shell date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg branch "$(shell git branch --show-current)" \
		'{version: $$version, commit: $$commit, date: $$date, branch: $$branch}' \
		> build-manifest.json

# Note: $$ in Makefile becomes $ in shell (escaping for Make)
```

---

## CI/CD Pipeline Patterns

### GitHub Actions

```yaml
name: Build and Deploy
on: push

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Extract version
        id: version
        run: echo "version=$(jq -r .version package.json)" >> "$GITHUB_OUTPUT"

      - name: Validate configs
        run: |
          errors=0
          for f in config/*.json; do
            if ! jq empty "$f" 2>/dev/null; then
              echo "::error file=$f::Invalid JSON"
              errors=$((errors + 1))
            fi
          done
          exit $errors

      - name: Update deploy config
        run: |
          jq --arg sha "${{ github.sha }}" \
             --arg ref "${{ github.ref_name }}" \
             --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
             '. + {commit: $sha, branch: $ref, deployed_at: $ts}' \
             deploy.json > deploy.json.tmp && mv deploy.json.tmp deploy.json

      - name: Check API health
        run: |
          response=$(curl -sf "${{ vars.API_URL }}/health" || echo '{}')
          if ! echo "$response" | jq -e '.status == "healthy"' > /dev/null; then
            echo "::error::Health check failed"
            echo "$response" | jq .
            exit 1
          fi
```

### GitLab CI

```yaml
stages:
  - validate
  - build
  - deploy

validate-json:
  stage: validate
  script:
    - |
      find . -name '*.json' -not -path './node_modules/*' | while read f; do
        jq empty "$f" 2>/dev/null || { echo "Invalid: $f"; exit 1; }
      done

extract-metadata:
  stage: build
  script:
    - export VERSION=$(jq -r .version package.json)
    - echo "VERSION=$VERSION" >> variables.env
    - |
      jq -n --arg v "$VERSION" --arg sha "$CI_COMMIT_SHA" \
        '{version: $v, commit: $sha}' > metadata.json
  artifacts:
    reports:
      dotenv: variables.env
    paths:
      - metadata.json
```

### Generic CI Script

```bash
#!/usr/bin/env bash
# ci-json-check.sh — validate and lint JSON files in CI
set -euo pipefail

errors=0
warnings=0

# Validate JSON syntax
echo "=== Checking JSON syntax ==="
while IFS= read -r f; do
    if ! jq empty "$f" 2>/dev/null; then
        echo "ERROR: Invalid JSON: $f"
        errors=$((errors + 1))
    fi
done < <(find . -name '*.json' -not -path '*/node_modules/*' -not -path '*/.git/*')

# Check for common issues
echo "=== Checking for issues ==="
for f in $(find . -name '*.json' -not -path '*/node_modules/*' -not -path '*/.git/*'); do
    # Check for duplicate keys (jq silently takes last)
    dupes=$(python3 -c "
import json, sys
class D(dict):
    def __init__(self):
        self.dupes = []
    def __setitem__(self, k, v):
        if k in self: self.dupes.append(k)
        super().__setitem__(k, v)
d = D()
json.loads(open('$f').read(), object_pairs_hook=lambda pairs: d.update(pairs) or d)
for k in d.dupes: print(f'  duplicate key: {k}')
" 2>/dev/null || true)
    if [[ -n "$dupes" ]]; then
        echo "WARNING: $f"
        echo "$dupes"
        warnings=$((warnings + 1))
    fi
done

echo
echo "Results: $errors errors, $warnings warnings"
exit $errors
```

---

## Shell Functions Library

Reusable functions for common jq tasks in shell scripts:

```bash
# json_get — safely extract a value with default
json_get() {
    local file="$1" path="$2" default="${3:-}"
    jq -r "$path // \"$default\"" "$file" 2>/dev/null || echo "$default"
}
# Usage: name=$(json_get config.json '.name' 'unnamed')

# json_set — update a field in a JSON file
json_set() {
    local file="$1" path="$2" value="$3"
    local tmp="${file}.tmp.$$"
    jq --argjson v "$value" "$path = \$v" "$file" > "$tmp" && mv "$tmp" "$file"
}
# Usage: json_set config.json '.debug' 'true'

# json_merge — merge multiple JSON files
json_merge() {
    jq -s 'reduce .[] as $x ({}; . * $x)' "$@"
}
# Usage: json_merge base.json override.json > merged.json

# json_validate — validate with descriptive error
json_validate() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "Not found: $file" >&2; return 1
    fi
    if ! jq empty "$file" 2>/dev/null; then
        echo "Invalid JSON: $file" >&2
        jq empty "$file" 2>&1 | head -5 >&2
        return 1
    fi
    return 0
}
# Usage: json_validate config.json || exit 1

# json_each — iterate over array elements with callback
json_each() {
    local file="$1" callback="$2"
    jq -c '.[]' "$file" | while IFS= read -r item; do
        $callback "$item"
    done
}
# Usage: process_item() { echo "$1" | jq -r '.name'; }
#        json_each items.json process_item

# json_query — interactive jq with error feedback
json_query() {
    local file="$1" filter="$2"
    local result
    if result=$(jq "$filter" "$file" 2>&1); then
        echo "$result"
    else
        echo "Query failed: $result" >&2
        return 1
    fi
}
```

---

## Tips & Gotchas

### Quoting rules

```bash
# 1. ALWAYS single-quote jq filters
jq '.name'           # ✓
jq ".name"           # ✗ works here but fragile

# 2. Use --arg for ALL external data
jq --arg v "$var" '. + {key: $v}'    # ✓
jq ". + {key: \"$var\"}"             # ✗ injection risk

# 3. In Makefiles, escape $ as $$
# Makefile: jq --arg v "$$VERSION" ...

# 4. In YAML (CI), use | for multiline
# run: |
#   jq '.foo | .bar' file.json
```

### Performance

```bash
# Call jq once, not in a loop
# BAD:
for id in $(cat ids.txt); do jq ".[$id]" data.json; done
# GOOD:
jq '[.[]] | INDEX(.id)' data.json  # build once, query from result

# Use -c when piping to other tools
jq -c '.[]' big.json | grep '"error"'  # faster than jq select
```

### Common mistakes

```bash
# Forgetting -r (quotes in output)
name=$(jq '.name' f.json)      # name is '"alice"' with quotes!
name=$(jq -r '.name' f.json)   # name is 'alice'

# Forgetting to wrap .[] in array
jq '.[] | select(.x)' f.json       # multiple outputs (not JSON array)
jq '[.[] | select(.x)]' f.json     # single JSON array output

# Using -s when you don't need it
jq -s '.name' f.json    # ERROR: array has no .name
jq '.name' f.json       # correct for single object input

# Empty output vs null
jq '.missing' f.json    # outputs "null" (the JSON value)
jq '.missing // empty' f.json  # outputs nothing
```
