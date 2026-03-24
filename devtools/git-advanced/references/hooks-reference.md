# Complete Git Hooks Reference

> Comprehensive guide to all Git hook types, practical examples, and
> hook management frameworks.

---

## Table of Contents

- [Overview](#overview)
- [Client-Side Hooks](#client-side-hooks)
  - [pre-commit](#pre-commit)
  - [prepare-commit-msg](#prepare-commit-msg)
  - [commit-msg](#commit-msg)
  - [post-commit](#post-commit)
  - [pre-rebase](#pre-rebase)
  - [post-checkout](#post-checkout)
  - [post-merge](#post-merge)
  - [pre-push](#pre-push)
  - [pre-auto-gc](#pre-auto-gc)
  - [post-rewrite](#post-rewrite)
  - [fsmonitor-watchman](#fsmonitor-watchman)
  - [p4-changelist / p4-pre-submit](#p4-hooks)
- [Server-Side Hooks](#server-side-hooks)
  - [pre-receive](#pre-receive)
  - [update](#update)
  - [post-receive](#post-receive)
  - [post-update](#post-update)
  - [push-to-checkout](#push-to-checkout)
- [Hook Setup and Management](#hook-setup-and-management)
- [Hook Managers](#hook-managers)
  - [Husky (Node.js)](#husky-nodejs)
  - [Lefthook (Language-agnostic)](#lefthook-language-agnostic)
  - [pre-commit Framework (Python)](#pre-commit-framework-python)
  - [Comparison](#comparison)
- [Best Practices](#best-practices)
- [Quick Reference Table](#quick-reference-table)

---

## Overview

Git hooks are scripts that run automatically at specific points in the Git
workflow. They live in `.git/hooks/` and are not tracked by version control
by default.

**Key facts:**
- Hooks must be executable (`chmod +x`)
- Exit code 0 = success (continue), non-zero = abort the action
- Can be written in any scripting language (bash, Python, Ruby, Node.js)
- `--no-verify` / `-n` bypasses pre-commit and commit-msg hooks
- Hooks are local — not cloned with the repo (use a framework to share)

**Set a custom hooks directory:**

```bash
# Per-repo (committed, shared with team)
git config core.hooksPath .githooks

# Global
git config --global core.hooksPath ~/.config/git/hooks
```

---

## Client-Side Hooks

### pre-commit

**When:** Before the commit is created (after staging, before message editor).
**Can abort:** Yes (non-zero exit prevents commit).
**Bypass:** `git commit --no-verify`

**Use cases:** Linting, formatting, running fast tests, checking for secrets.

**Example: Lint staged files**

```bash
#!/usr/bin/env bash
# Lint only staged files to keep the hook fast

STAGED=$(git diff --cached --name-only --diff-filter=ACM)

# JavaScript/TypeScript linting
JS_FILES=$(echo "$STAGED" | grep -E '\.(js|jsx|ts|tsx)$' || true)
if [ -n "$JS_FILES" ]; then
    echo "🔍 Linting JavaScript/TypeScript..."
    echo "$JS_FILES" | xargs npx eslint --max-warnings=0 || exit 1
fi

# Python linting
PY_FILES=$(echo "$STAGED" | grep -E '\.py$' || true)
if [ -n "$PY_FILES" ]; then
    echo "🔍 Linting Python..."
    echo "$PY_FILES" | xargs python -m flake8 || exit 1
fi

# Check for debug statements
if echo "$STAGED" | xargs grep -l 'console\.log\|debugger\|binding\.pry\|import pdb' 2>/dev/null; then
    echo "❌ Debug statements found in staged files"
    exit 1
fi
```

**Example: Detect secrets**

```bash
#!/usr/bin/env bash
STAGED=$(git diff --cached --name-only --diff-filter=ACM)

# Pattern-based secret detection
PATTERNS=(
    'AKIA[0-9A-Z]{16}'                    # AWS Access Key
    'password\s*=\s*["\x27][^"\x27]+'     # Hardcoded password
    '-----BEGIN (RSA |EC )?PRIVATE KEY'    # Private key
    'sk-[a-zA-Z0-9]{48}'                  # OpenAI API key
    'ghp_[a-zA-Z0-9]{36}'                 # GitHub PAT
)

for pattern in "${PATTERNS[@]}"; do
    if echo "$STAGED" | xargs grep -lE "$pattern" 2>/dev/null; then
        echo "❌ Potential secret detected matching: $pattern"
        exit 1
    fi
done
```

### prepare-commit-msg

**When:** After default message is created, before editor opens.
**Can abort:** Yes.
**Arguments:** `$1` = message file, `$2` = source (message/template/merge/squash/commit), `$3` = commit SHA (for amend).

**Use case:** Auto-insert branch name, ticket number, or template.

**Example: Prepend branch ticket number**

```bash
#!/usr/bin/env bash
# Extract ticket number from branch name (e.g., feature/JIRA-1234-description)
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
TICKET=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1)

# Don't modify merge/squash/amend messages
if [ -n "$TICKET" ] && [ -z "$2" ]; then
    # Only prepend if not already present
    if ! grep -q "$TICKET" "$1"; then
        sed -i.bak "1s/^/[$TICKET] /" "$1"
        rm -f "$1.bak"
    fi
fi
```

### commit-msg

**When:** After user writes the commit message, before commit is finalized.
**Can abort:** Yes.
**Arguments:** `$1` = path to file containing the commit message.

**Use case:** Enforce message format (Conventional Commits, ticket references).

**Example: Conventional Commits enforcement**

```bash
#!/usr/bin/env bash
MSG=$(cat "$1")

# Skip merge commits
if echo "$MSG" | grep -qE '^Merge '; then
    exit 0
fi

# Conventional Commits pattern
PATTERN='^(feat|fix|docs|style|refactor|test|chore|ci|perf|build|revert)(\(.+\))?!?: .{1,100}'

if ! echo "$MSG" | head -1 | grep -qE "$PATTERN"; then
    echo "❌ Commit message does not follow Conventional Commits format."
    echo ""
    echo "Expected: type(scope): description"
    echo "Types: feat, fix, docs, style, refactor, test, chore, ci, perf, build, revert"
    echo "Example: feat(auth): add JWT token refresh"
    echo ""
    echo "Your message: $(head -1 "$1")"
    exit 1
fi

# Check subject line length
SUBJECT=$(head -1 "$1")
if [ ${#SUBJECT} -gt 100 ]; then
    echo "❌ Subject line is ${#SUBJECT} characters (max 100)"
    exit 1
fi

# Check for blank line between subject and body
LINES=$(wc -l < "$1")
if [ "$LINES" -gt 1 ]; then
    SECOND_LINE=$(sed -n '2p' "$1")
    if [ -n "$SECOND_LINE" ]; then
        echo "❌ Second line must be blank (separates subject from body)"
        exit 1
    fi
fi
```

### post-commit

**When:** After the commit is created.
**Can abort:** No (commit already happened).

**Use case:** Notifications, logging, trigger builds.

```bash
#!/usr/bin/env bash
# Display commit summary
SHA=$(git rev-parse --short HEAD)
MSG=$(git log -1 --pretty=%s)
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")

echo "✅ Committed $SHA on $BRANCH: $MSG"

# Optional: notify team chat
# curl -s -X POST "$WEBHOOK_URL" -d "{\"text\": \"$USER committed $SHA: $MSG\"}"
```

### pre-rebase

**When:** Before a rebase starts.
**Can abort:** Yes.
**Arguments:** `$1` = upstream branch, `$2` = branch being rebased (empty if current).

**Use case:** Prevent rebasing published branches.

```bash
#!/usr/bin/env bash
BRANCH=${2:-$(git symbolic-ref --short HEAD 2>/dev/null)}

PROTECTED="main master develop release"
for protected in $PROTECTED; do
    if [ "$BRANCH" = "$protected" ]; then
        echo "❌ Cannot rebase protected branch: $BRANCH"
        exit 1
    fi
done
```

### post-checkout

**When:** After `git checkout` / `git switch` completes.
**Can abort:** No.
**Arguments:** `$1` = prev HEAD, `$2` = new HEAD, `$3` = 1 if branch change, 0 if file checkout.

**Use case:** Auto-install dependencies, display environment info.

```bash
#!/usr/bin/env bash
# Only run on branch changes, not file checkouts
if [ "$3" != "1" ]; then
    exit 0
fi

PREV=$1
CURR=$2

# Check if dependencies changed
if git diff --name-only "$PREV" "$CURR" | grep -q 'package-lock.json\|yarn.lock'; then
    echo "📦 Dependencies changed — running npm install..."
    npm install --quiet
fi

if git diff --name-only "$PREV" "$CURR" | grep -q 'requirements.*\.txt\|Pipfile\.lock'; then
    echo "🐍 Python dependencies changed — running pip install..."
    pip install -r requirements.txt -q
fi

if git diff --name-only "$PREV" "$CURR" | grep -qE '\.env\.example$'; then
    echo "⚠️  .env.example changed — review your local .env file"
fi
```

### post-merge

**When:** After a successful `git merge` (including `git pull`).
**Can abort:** No.
**Arguments:** `$1` = 1 if squash merge, 0 otherwise.

**Use case:** Auto-install dependencies after pulling changes.

```bash
#!/usr/bin/env bash
# Check if dependency files were part of the merge
CHANGED=$(git diff-tree -r --name-only --no-commit-id ORIG_HEAD HEAD)

if echo "$CHANGED" | grep -qE 'package-lock\.json|yarn\.lock|pnpm-lock\.yaml'; then
    echo "📦 Lock file changed — reinstalling dependencies..."
    npm install --quiet 2>/dev/null || yarn install --frozen-lockfile 2>/dev/null
fi

if echo "$CHANGED" | grep -qE 'requirements.*\.txt|Pipfile\.lock|poetry\.lock'; then
    echo "🐍 Python dependencies changed — installing..."
    pip install -r requirements.txt -q 2>/dev/null
fi

if echo "$CHANGED" | grep -q 'migrations/'; then
    echo "🗄️  New migrations detected — run: python manage.py migrate"
fi

if echo "$CHANGED" | grep -q '\.env\.example'; then
    echo "⚠️  .env.example changed — review your local .env"
fi
```

### pre-push

**When:** Before `git push` sends data to the remote.
**Can abort:** Yes.
**Arguments:** `$1` = remote name, `$2` = remote URL. Stdin receives ref info.

**Use case:** Run tests, prevent pushing to protected branches, check branch policies.

**Example: Run tests before push**

```bash
#!/usr/bin/env bash
REMOTE="$1"
URL="$2"

# Prevent direct push to main/master
while read local_ref local_sha remote_ref remote_sha; do
    if echo "$remote_ref" | grep -qE 'refs/heads/(main|master)$'; then
        echo "❌ Direct push to main/master is not allowed. Use a pull request."
        exit 1
    fi
done

# Run test suite
echo "🧪 Running tests before push..."
npm test --silent 2>&1
TEST_EXIT=$?

if [ $TEST_EXIT -ne 0 ]; then
    echo "❌ Tests failed. Push aborted."
    echo "   Run 'npm test' to see failures."
    echo "   Use 'git push --no-verify' to bypass (not recommended)."
    exit 1
fi

echo "✅ Tests passed. Pushing..."
```

**Example: Prevent pushing large files**

```bash
#!/usr/bin/env bash
MAX_SIZE=$((5 * 1024 * 1024))  # 5 MB

while read local_ref local_sha remote_ref remote_sha; do
    if [ "$local_sha" = "0000000000000000000000000000000000000000" ]; then
        continue  # branch deletion
    fi

    # Find new commits being pushed
    if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
        range="$local_sha"
    else
        range="$remote_sha..$local_sha"
    fi

    # Check for large files
    large_files=$(git rev-list --objects "$range" | \
        git cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' | \
        awk -v max="$MAX_SIZE" '/^blob/ && $2 > max {print $3, $2}')

    if [ -n "$large_files" ]; then
        echo "❌ Large files detected (>${MAX_SIZE} bytes):"
        echo "$large_files" | while read file size; do
            echo "   $file ($(numfmt --to=iec $size 2>/dev/null || echo "${size} bytes"))"
        done
        echo "Consider using Git LFS: git lfs track '*.ext'"
        exit 1
    fi
done
```

### pre-auto-gc

**When:** Before `git gc --auto` runs.
**Can abort:** Yes (exit non-zero skips gc).

```bash
#!/usr/bin/env bash
# Prevent gc during business hours
HOUR=$(date +%H)
if [ "$HOUR" -ge 9 ] && [ "$HOUR" -le 17 ]; then
    echo "Skipping auto-gc during business hours"
    exit 1
fi
```

### post-rewrite

**When:** After commands that rewrite commits (`git commit --amend`, `git rebase`).
**Can abort:** No.
**Arguments:** `$1` = command that triggered (amend/rebase). Stdin receives old/new SHA pairs.

```bash
#!/usr/bin/env bash
echo "ℹ️  Commits were rewritten by: $1"
while read old_sha new_sha extra; do
    echo "   $old_sha → $new_sha"
done
```

### fsmonitor-watchman

**When:** Git queries the filesystem monitor for changed files.
**Purpose:** Performance optimization for large repos using Watchman.

```bash
#!/usr/bin/env perl
# See git-fsmonitor--daemon or Watchman integration docs
# Typically auto-configured by:
git config core.fsmonitor true    # Git 2.37+ built-in
# Or:
git config core.fsmonitor "$PWD/.git/hooks/fsmonitor-watchman"
```

### p4 Hooks

`p4-changelist` and `p4-pre-submit` are used with `git p4` for Perforce integration.
Rarely needed outside Perforce shops.

---

## Server-Side Hooks

Server-side hooks run on the machine hosting the remote repository (e.g.,
your Git server, Gitolite, or similar). GitHub/GitLab implement their own
server-side policies via their UI and APIs.

### pre-receive

**When:** Before any refs are updated on the server during a push.
**Can abort:** Yes. Rejecting here rejects the entire push.
**Stdin:** `<old-sha> <new-sha> <ref-name>` per updated ref.

**Use case:** Enforce policies across all branches.

```bash
#!/usr/bin/env bash
while read old_sha new_sha ref; do
    # Reject force pushes (non-fast-forward)
    if [ "$old_sha" != "0000000000000000000000000000000000000000" ]; then
        if ! git merge-base --is-ancestor "$old_sha" "$new_sha" 2>/dev/null; then
            echo "❌ Force push rejected for $ref"
            echo "   Use pull requests to update protected branches."
            exit 1
        fi
    fi

    # Reject pushes of commits with secrets
    commits=$(git rev-list "$old_sha..$new_sha" 2>/dev/null || echo "$new_sha")
    for commit in $commits; do
        if git diff-tree -r --no-commit-id --name-only "$commit" | \
           xargs git show "$commit" -- 2>/dev/null | \
           grep -qE 'AKIA[0-9A-Z]{16}|-----BEGIN.*PRIVATE KEY'; then
            echo "❌ Potential secret detected in commit $commit"
            exit 1
        fi
    done
done
```

### update

**When:** Once per ref being updated (more granular than pre-receive).
**Can abort:** Yes (only rejects the specific ref).
**Arguments:** `$1` = ref name, `$2` = old SHA, `$3` = new SHA.

```bash
#!/usr/bin/env bash
REF=$1
OLD=$2
NEW=$3

# Protect specific branches
case "$REF" in
    refs/heads/main|refs/heads/master|refs/heads/production)
        echo "❌ Direct push to $(basename "$REF") is not allowed."
        echo "   Submit a pull request instead."
        exit 1
        ;;
    refs/tags/*)
        # Prevent tag deletion or modification
        if [ "$NEW" = "0000000000000000000000000000000000000000" ]; then
            echo "❌ Tag deletion is not allowed: $REF"
            exit 1
        fi
        ;;
esac
```

### post-receive

**When:** After all refs have been updated.
**Can abort:** No.
**Stdin:** Same format as pre-receive.

**Use case:** Trigger deployments, send notifications, update issue trackers.

```bash
#!/usr/bin/env bash
while read old_sha new_sha ref; do
    branch=$(echo "$ref" | sed 's|refs/heads/||')

    # Auto-deploy on push to main
    if [ "$branch" = "main" ]; then
        echo "🚀 Deploying to production..."
        /opt/deploy/production.sh "$new_sha" &
    fi

    # Notify on push to any branch
    author=$(git log -1 --format='%an' "$new_sha")
    msg=$(git log -1 --format='%s' "$new_sha")
    # curl -s "$SLACK_WEBHOOK" -d "{\"text\": \"$author pushed to $branch: $msg\"}"
done
```

### post-update

**When:** After refs are updated (simpler than post-receive — no stdin).
**Arguments:** List of updated ref names.

```bash
#!/usr/bin/env bash
# Update server info for dumb HTTP protocol
exec git update-server-info
```

### push-to-checkout

**When:** On a non-bare repo when receiving a push to the currently checked-out branch.
**Can abort:** Yes.

Rarely needed — most setups use bare repositories for remotes.

---

## Hook Setup and Management

### Manual Setup

```bash
# Create a hook
cat > .git/hooks/pre-commit << 'EOF'
#!/usr/bin/env bash
echo "Running pre-commit checks..."
npm run lint --silent || exit 1
EOF
chmod +x .git/hooks/pre-commit

# Share hooks via repo directory
mkdir .githooks
cp .git/hooks/pre-commit .githooks/
git config core.hooksPath .githooks
# Commit .githooks/ to the repo
```

### Template Directory

```bash
# Set up a template for all new repos/clones
mkdir -p ~/.config/git/template/hooks
# Add your hooks there

git config --global init.templateDir ~/.config/git/template
# All future git init / git clone will copy these hooks
```

---

## Hook Managers

### Husky (Node.js)

Best for JavaScript/TypeScript projects. Integrates with npm/yarn lifecycle.

**Setup:**

```bash
# Install
npm install --save-dev husky

# Initialize (creates .husky/ directory)
npx husky init

# Add hooks
echo "npx lint-staged" > .husky/pre-commit
echo 'npx commitlint --edit "$1"' > .husky/commit-msg
```

**With lint-staged (only lint changed files):**

```json
// package.json
{
  "lint-staged": {
    "*.{js,jsx,ts,tsx}": ["eslint --fix", "prettier --write"],
    "*.{css,scss}": ["stylelint --fix"],
    "*.{json,md}": ["prettier --write"]
  }
}
```

**Key features:**
- Zero-config after init
- Hooks stored in `.husky/` directory (committed to repo)
- Supports all Git hooks
- Works with npm, yarn, pnpm

### Lefthook (Language-agnostic)

Fast, polyglot hook manager. Works with any project type.

**Setup:**

```bash
# Install
# macOS: brew install lefthook
# npm: npm install lefthook --save-dev
# Go: go install github.com/evilmartians/lefthook@latest

# Initialize
lefthook install
```

**Configuration (`lefthook.yml`):**

```yaml
pre-commit:
  parallel: true
  commands:
    eslint:
      glob: "*.{js,ts,tsx}"
      run: npx eslint --fix {staged_files}
      stage_fixed: true
    prettier:
      glob: "*.{js,ts,json,css,md}"
      run: npx prettier --write {staged_files}
      stage_fixed: true
    python-lint:
      glob: "*.py"
      run: flake8 {staged_files}
    go-vet:
      glob: "*.go"
      run: go vet ./...

commit-msg:
  commands:
    conventional:
      run: 'grep -qE "^(feat|fix|docs|style|refactor|test|chore|ci|perf|build|revert)(\(.+\))?!?: .+" {1}'

pre-push:
  commands:
    test:
      run: npm test --silent
```

**Key features:**
- Very fast (parallel execution, smart file filtering)
- Single config file for all hooks
- `{staged_files}` placeholder for smart file filtering
- `stage_fixed` auto-stages files modified by fixers
- Works with any language/tool

### pre-commit Framework (Python)

Polyglot hook framework with a large ecosystem of community hooks.

**Setup:**

```bash
# Install
pip install pre-commit
# Or: brew install pre-commit

# Create config
cat > .pre-commit-config.yaml << 'EOF'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-json
      - id: check-added-large-files
        args: ['--maxkb=500']
      - id: detect-private-key
      - id: check-merge-conflict

  - repo: https://github.com/psf/black
    rev: 24.4.2
    hooks:
      - id: black

  - repo: https://github.com/pycqa/flake8
    rev: 7.0.0
    hooks:
      - id: flake8

  - repo: https://github.com/pre-commit/mirrors-eslint
    rev: v9.3.0
    hooks:
      - id: eslint
        types: [javascript, typescript]
        additional_dependencies:
          - eslint@9.3.0
          - typescript

  - repo: https://github.com/compilerla/conventional-pre-commit
    rev: v3.2.0
    hooks:
      - id: conventional-pre-commit
        stages: [commit-msg]
EOF

# Install hooks
pre-commit install
pre-commit install --hook-type commit-msg

# Run against all files (first time)
pre-commit run --all-files

# Update hook versions
pre-commit autoupdate
```

**Key features:**
- Huge ecosystem of community hooks
- Language-agnostic (Python, JS, Go, Rust, etc.)
- Automatic virtual environment per hook
- CI integration: `pre-commit run --all-files`
- Auto-update: `pre-commit autoupdate`

### Comparison

| Feature | Husky | Lefthook | pre-commit |
|---|---|---|---|
| Language | Node.js | Go (any project) | Python (any project) |
| Config format | Shell scripts | YAML | YAML |
| Parallel execution | Via lint-staged | Built-in | Limited |
| Community hooks | ✗ (DIY) | ✗ (DIY) | ✓ Large ecosystem |
| File filtering | Via lint-staged | Built-in globs | Built-in types/globs |
| Auto-fix + re-stage | Via lint-staged | `stage_fixed: true` | ✓ Built-in |
| Speed | Medium | Very fast | Medium |
| Best for | JS/TS projects | Polyglot / speed | Python / ecosystem |
| Install method | npm | brew/npm/go | pip/brew |

---

## Best Practices

### Performance

- **Only check staged/changed files** — never lint the entire codebase in pre-commit
- **Run fast checks in pre-commit**, slow checks in pre-push or CI
- **Use parallel execution** (lefthook, lint-staged)
- **Cache results** where possible (eslint cache, mypy cache)

### Reliability

- Use `#!/usr/bin/env bash` for portability (not `/bin/bash`)
- Handle missing tools gracefully — warn but don't block if optional tool is missing
- Test hooks in CI: `pre-commit run --all-files` or `lefthook run pre-commit`
- Document how to bypass: `git commit --no-verify` (for emergencies only)

### Team Adoption

- Start with non-blocking hooks (warnings) → graduate to blocking
- Use a hook manager (Husky/Lefthook/pre-commit) so hooks are version-controlled
- Add setup instructions to README or CONTRIBUTING.md
- Run the same checks in CI as a backstop

### Security

- Never execute arbitrary code from commit messages in hooks
- Be cautious with hooks that run `eval` or shell expansion
- Server-side hooks are the true enforcement — client hooks can be bypassed
- Use `--no-verify` audit logging if compliance matters

---

## Quick Reference Table

| Hook | Side | Can Abort | Trigger | Common Use |
|---|---|---|---|---|
| `pre-commit` | Client | ✓ | Before commit | Lint, format, secrets |
| `prepare-commit-msg` | Client | ✓ | Before msg editor | Auto-insert ticket # |
| `commit-msg` | Client | ✓ | After msg written | Enforce format |
| `post-commit` | Client | ✗ | After commit | Notifications |
| `pre-rebase` | Client | ✓ | Before rebase | Protect branches |
| `post-checkout` | Client | ✗ | After checkout | Install deps |
| `post-merge` | Client | ✗ | After merge/pull | Install deps |
| `pre-push` | Client | ✓ | Before push | Tests, branch guard |
| `pre-auto-gc` | Client | ✓ | Before auto gc | Schedule gc |
| `post-rewrite` | Client | ✗ | After amend/rebase | Logging |
| `pre-receive` | Server | ✓ | Before accepting push | Policy enforcement |
| `update` | Server | ✓ | Per-ref update | Branch protection |
| `post-receive` | Server | ✗ | After push accepted | Deploy, notify |
| `post-update` | Server | ✗ | After refs update | Update server info |
