---
name: bash-scripting-patterns
description: |
  Use when user writes Bash scripts, asks about shell scripting best practices, error handling (set -euo pipefail), parameter expansion, arrays, process substitution, trap handlers, or ShellCheck fixes.
  Do NOT use for PowerShell, zsh-specific features, Fish shell, or Python/Ruby scripting. Do NOT use for basic command-line usage.
---

# Bash Scripting Patterns & Best Practices

## Script Header and Safety

Start every script with strict mode:

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
```

- `set -e` — exit on first error (non-zero exit status).
- `set -u` — treat unset variables as errors.
- `set -o pipefail` — pipeline fails on first non-zero command, not just the last.
- `IFS=$'\n\t'` — prevent word splitting on spaces; only split on newlines and tabs.

Add `set -x` temporarily for debug tracing. Remove before committing.

Use `#!/usr/bin/env bash` over `#!/bin/bash` for portability across systems where Bash lives in different paths.

## Variable Quoting Rules

**Always quote variables and command substitutions:**

```bash
cp "$src" "$dest"
grep "$pattern" "$file"
result="$(some_command)"
```

**When quoting is unnecessary (but still safe):**
- Inside `[[ ]]` on the left side: `[[ $var == pattern ]]`
- Array index arithmetic: `${array[$i]}`
- Arithmetic context: `$(( count + 1 ))`

**When you intentionally omit quotes:**
- Deliberate word splitting (rare): `flags="-v -n"; grep $flags "$file"`
- Use arrays instead when possible: `flags=(-v -n); grep "${flags[@]}" "$file"`

## Parameter Expansion

```bash
# Default values
name="${1:-default}"          # use default if $1 unset or empty
name="${1:=fallback}"         # assign fallback if unset or empty

# Require variable to be set
: "${DATABASE_URL:?Error: DATABASE_URL not set}"

# String length
echo "${#var}"

# Substring extraction
echo "${var:0:5}"             # first 5 chars
echo "${var:3}"               # from position 3 to end

# Pattern removal
path="/home/user/file.tar.gz"
echo "${path##*/}"            # file.tar.gz  (remove longest prefix match)
echo "${path%.*}"             # /home/user/file.tar  (remove shortest suffix)
echo "${path%%.*}"            # /home/user/file  (remove longest suffix)

# Replacement
echo "${var/old/new}"         # replace first occurrence
echo "${var//old/new}"        # replace all occurrences
echo "${var/#prefix/repl}"    # replace if at start
echo "${var/%suffix/repl}"    # replace if at end

# Case conversion (Bash 4+)
echo "${var^^}"               # UPPERCASE
echo "${var,,}"               # lowercase
echo "${var^}"                # capitalize first char

# Indirect expansion
varname="PATH"
echo "${!varname}"            # expands $PATH
```

## Arrays

### Indexed Arrays

```bash
files=("one.txt" "two.txt" "three.txt")
files+=("four.txt")

echo "${files[0]}"            # first element
echo "${files[@]}"            # all elements (separate words)
echo "${#files[@]}"           # array length

# Iteration — always quote "${array[@]}"
for f in "${files[@]}"; do
  echo "$f"
done

# Slicing
echo "${files[@]:1:2}"       # two elements starting at index 1
```

### Associative Arrays (Bash 4+)

```bash
declare -A config
config[host]="localhost"
config[port]="5432"

echo "${config[host]}"
echo "${!config[@]}"          # all keys
echo "${config[@]}"           # all values

for key in "${!config[@]}"; do
  echo "$key = ${config[$key]}"
done
```

## Conditionals

### `[[ ]]` vs `[ ]`

Prefer `[[ ]]` in Bash scripts. It supports regex, pattern matching, and prevents word splitting:

```bash
# String checks
[[ -z "$var" ]]               # true if empty
[[ -n "$var" ]]               # true if non-empty
[[ "$a" == "$b" ]]            # string equality
[[ "$a" != "$b" ]]            # string inequality
[[ "$a" < "$b" ]]             # lexicographic comparison (safe in [[]])
[[ "$str" == *.txt ]]         # glob pattern match
[[ "$str" =~ ^[0-9]+$ ]]     # regex match (no quotes around regex)

# File checks
[[ -f "$path" ]]              # regular file exists
[[ -d "$path" ]]              # directory exists
[[ -e "$path" ]]              # any file exists
[[ -r "$path" ]]              # readable
[[ -w "$path" ]]              # writable
[[ -x "$path" ]]              # executable
[[ -s "$path" ]]              # file exists and is non-empty
[[ "$a" -nt "$b" ]]           # a is newer than b

# Numeric comparison — use (( )) or -eq/-lt/-gt inside [[ ]]
(( count > 10 ))
[[ "$count" -eq 10 ]]

# Logical operators inside [[ ]]
[[ -f "$f" && -r "$f" ]]
[[ "$a" == "x" || "$a" == "y" ]]
```

## Loops

### For Loops

```bash
# Over array
for item in "${items[@]}"; do
  process "$item"
done

# C-style
for (( i = 0; i < 10; i++ )); do
  echo "$i"
done

# Over glob results (nullglob prevents literal pattern if no match)
shopt -s nullglob
for f in /tmp/*.log; do
  rm "$f"
done
```

### While Read (Line Processing)

```bash
# Read file line by line
while IFS= read -r line; do
  echo "$line"
done < "$file"

# Read command output without subshell (process substitution)
while IFS= read -r line; do
  count=$((count + 1))       # variable survives after loop
done < <(some_command)

# Read delimited data
while IFS=: read -r user _ uid gid _ home shell; do
  echo "$user uses $shell"
done < /etc/passwd
```

### Avoiding Subshell Pitfalls

Piping into `while` creates a subshell — variable changes are lost:

```bash
# BAD: count stays 0 after loop
count=0
cat file | while read -r line; do
  count=$((count + 1))
done
echo "$count"  # prints 0

# GOOD: use process substitution or redirect
count=0
while IFS= read -r line; do
  count=$((count + 1))
done < <(cat file)
echo "$count"  # prints correct value
```

## Functions

```bash
# Define with local variables
my_func() {
  local name="$1"
  local -i count="${2:-0}"    # integer local with default
  echo "Processing $name ($count)"
}

# Return values via stdout (capture with $())
get_timestamp() {
  date +%s
}
ts="$(get_timestamp)"

# Return status codes
is_valid() {
  [[ -f "$1" && -r "$1" ]]
}
if is_valid "$path"; then
  echo "Valid"
fi

# Nameref (Bash 4.3+) — write to caller's variable
populate_result() {
  local -n ref="$1"
  ref="computed value"
}
populate_result myvar
echo "$myvar"  # "computed value"
```

## Error Handling

### Trap Patterns

```bash
# Cleanup on exit (always runs)
cleanup() {
  rm -f "$tmpfile"
  echo "Cleaned up" >&2
}
trap cleanup EXIT

# Error reporting with line number
on_error() {
  echo "Error at line $1, command: $2" >&2
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# Handle signals
trap 'echo "Interrupted" >&2; exit 130' INT TERM
```

### Robust Cleanup Template

```bash
#!/usr/bin/env bash
set -euo pipefail

tmpdir=""
cleanup() {
  local exit_code=$?
  [[ -d "$tmpdir" ]] && rm -rf "$tmpdir"
  exit "$exit_code"
}
trap cleanup EXIT

tmpdir="$(mktemp -d)"
# work in $tmpdir safely; cleanup runs on success, failure, or signal
```

### Retry Logic

```bash
retry() {
  local -i max_attempts="${1:?}"
  local -i delay="${2:?}"
  shift 2
  local -i attempt=1

  until "$@"; do
    if (( attempt >= max_attempts )); then
      echo "Failed after $max_attempts attempts" >&2
      return 1
    fi
    echo "Attempt $attempt failed, retrying in ${delay}s..." >&2
    sleep "$delay"
    (( attempt++ ))
  done
}
retry 3 5 curl -sf https://example.com/health
```

## Input Parsing

### getopts

```bash
verbose=false
output=""

while getopts ":vo:h" opt; do
  case "$opt" in
    v) verbose=true ;;
    o) output="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) echo "Option -$OPTARG requires argument" >&2; exit 1 ;;
    \?) echo "Unknown option -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
# remaining args in "$@"
```

### Long Options with Manual Parsing

```bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose)  verbose=true; shift ;;
    --output)   output="${2:?--output requires a value}"; shift 2 ;;
    --output=*) output="${1#*=}"; shift ;;
    --)         shift; break ;;
    -*)         echo "Unknown option: $1" >&2; exit 1 ;;
    *)          break ;;
  esac
done
```

## File Operations

### Temp Files and Directories

```bash
# Always use mktemp, never hardcoded paths
tmpfile="$(mktemp)"
tmpdir="$(mktemp -d)"

# Template with prefix
tmpfile="$(mktemp /tmp/myapp.XXXXXX)"
```

### Atomic Writes

Write to temp file first, then move. Prevents partial writes on failure:

```bash
generate_config() {
  local dest="$1"
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  # write to tmp
  echo "key=value" > "$tmp"
  mv "$tmp" "$dest"          # atomic on same filesystem
}
```

### File Locking

```bash
exec 9>/var/lock/myapp.lock
if ! flock -n 9; then
  echo "Another instance is running" >&2
  exit 1
fi
# lock released automatically when fd 9 closes (script exit)
```

## Common ShellCheck Warnings and Fixes

| Code   | Issue                                       | Fix                                         |
|--------|---------------------------------------------|---------------------------------------------|
| SC2086 | Unquoted variable                           | `"$var"` instead of `$var`                  |
| SC2046 | Unquoted command substitution               | `"$(cmd)"` or use while-read loop           |
| SC2034 | Unused variable                             | Remove or `export`; suppress if used externally |
| SC2128 | Array without `[@]`                         | `"${arr[@]}"` not `"$arr"`                  |
| SC2155 | Declare and assign separately               | `local var; var="$(cmd)"` to catch errors   |
| SC2164 | `cd` without `||` exit                      | `cd "$dir" || exit 1`                       |
| SC2206 | Word-splitting in array assignment           | `readarray -t arr < <(cmd)` instead of `arr=($(cmd))` |
| SC2012 | Parsing `ls` output                         | Use globs or `find` instead                 |
| SC2162 | `read` without `-r`                         | `read -r var`                               |
| SC2115 | `rm -rf "$dir/"` with potentially empty var | Guard: `[[ -n "$dir" ]] && rm -rf "$dir"`   |

Suppress inline when justified:

```bash
# shellcheck disable=SC2086
gcc $CFLAGS -o output main.c
```

## Portability Considerations

| Feature              | Bash  | POSIX `sh` | Notes                                    |
|----------------------|-------|------------|------------------------------------------|
| `[[ ]]`             | ✅    | ❌         | Use `[ ]` for POSIX                      |
| Arrays               | ✅    | ❌         | Use positional params or temp files       |
| `local`              | ✅    | ⚠️          | Widely supported but not in POSIX spec    |
| Process substitution | ✅    | ❌         | Use named pipes or temp files             |
| `${var,,}`           | ✅    | ❌         | Use `tr '[:upper:]' '[:lower:]'`         |
| `read -r`            | ✅    | ✅         | Always use `-r`                          |
| `$(cmd)`             | ✅    | ✅         | Prefer over backticks                    |
| `=~` regex           | ✅    | ❌         | Use `grep -qE` or `expr` for POSIX       |
| `set -o pipefail`    | ✅    | ❌         | No POSIX equivalent                      |

Write `#!/usr/bin/env bash` when using Bash features. Write `#!/bin/sh` only for POSIX-portable scripts. Test portable scripts with `dash` or `ash`.

## Anti-Patterns

### Never Use `eval` on Untrusted Input

```bash
# BAD — command injection risk
eval "$user_input"

# GOOD — use arrays for dynamic commands
cmd=("find" "$dir" "-name" "$pattern")
"${cmd[@]}"
```

### Never Parse `ls`

```bash
# BAD — breaks on spaces, special chars
for f in $(ls *.txt); do echo "$f"; done

# GOOD — use glob directly
for f in *.txt; do
  [[ -e "$f" ]] || continue
  echo "$f"
done
```

### Avoid Useless `cat`

```bash
# BAD
cat file | grep pattern

# GOOD
grep pattern file
# or for stdin
grep pattern < file
```

### Never Leave Variables Unquoted in Commands

```bash
# BAD — breaks on filenames with spaces
rm $file

# GOOD
rm "$file"
```

### Avoid Uppercase Variable Names for Local Use

Reserve `UPPER_CASE` for environment variables and exported vars. Use `lower_case` for script-local variables to avoid collisions with `PATH`, `HOME`, `IFS`, etc.

<!-- tested: pass -->
