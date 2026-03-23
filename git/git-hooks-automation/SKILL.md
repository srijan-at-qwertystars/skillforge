---
name: git-hooks-automation
description:
  positive: "Use when user sets up Git hooks, asks about Husky, lint-staged, pre-commit framework, commitlint, conventional commits, pre-push checks, or automating code quality checks in the Git workflow."
  negative: "Do NOT use for Git rebase/merge workflows (use git-rebase-workflows skill), CI/CD pipelines (use github-actions-workflows skill), or basic git commands."
---

# Git Hooks & Automation

## Git Hooks Overview

Git hooks are scripts that run automatically at specific points in the Git workflow. They live in `.git/hooks/` by default.

### Client-Side Hooks

| Hook | Trigger | Common Use |
|------|---------|------------|
| `pre-commit` | Before commit is created | Lint, format, type-check staged files |
| `prepare-commit-msg` | After default message, before editor opens | Prepopulate commit template |
| `commit-msg` | After user enters commit message | Validate message format |
| `post-commit` | After commit completes | Notifications, logging |
| `pre-push` | Before push to remote | Run tests, build validation |
| `pre-rebase` | Before rebase starts | Prevent rebasing published commits |
| `post-checkout` | After `git checkout` / `git switch` | Update dependencies |
| `post-merge` | After merge completes | Reinstall dependencies |

### Server-Side Hooks

| Hook | Trigger | Common Use |
|------|---------|------------|
| `pre-receive` | Before refs are updated on push | Enforce policies, reject bad pushes |
| `update` | Per-branch, before ref update | Branch-level access control |
| `post-receive` | After push completes | Deploy, notify, trigger CI |

Hooks are executable files in `.git/hooks/`. Remove `.sample` suffix to activate. Exit 0 = pass, non-zero = abort. Problem: `.git/hooks/` is untracked. Use a hook manager to share hooks across the team.

---

## Husky (v9+)

Husky manages Git hooks for Node.js projects. Hooks live in `.husky/` and are committed to the repo.

### Setup

```bash
npm install --save-dev husky
npx husky init
```

`husky init` creates `.husky/` directory and adds a `prepare` script to `package.json`:

```json
{
  "scripts": {
    "prepare": "husky"
  }
}
```

Run `npm install` after cloning to auto-install hooks via the `prepare` lifecycle script.

### Create Hooks

Create executable shell scripts in `.husky/`:

```bash
# .husky/pre-commit
npx lint-staged
```

```bash
# .husky/commit-msg
npx --no -- commitlint --edit "$1"
```

```bash
# .husky/pre-push
npm run test -- --ci
npm run build
```

Husky v9 removed the `npx husky add` command. Create hook files directly. Ensure they are executable.

### Monorepo

Initialize Husky in the repo root. Hook scripts can call workspace-specific commands.

---

## lint-staged

Run linters and formatters only on staged files. Pairs with Husky's `pre-commit` hook.

### Configuration

In `package.json`:

```json
{
  "lint-staged": {
    "*.{js,jsx,ts,tsx}": ["eslint --fix", "prettier --write"],
    "*.{json,md,yml,yaml}": ["prettier --write"],
    "*.css": ["stylelint --fix", "prettier --write"]
  }
}
```

Or use a dedicated config file (`.lintstagedrc.json`, `lint-staged.config.js`).

### Advanced Patterns

Use functions for dynamic commands:

```js
// lint-staged.config.js
export default {
  '*.{ts,tsx}': (filenames) => {
    const files = filenames.join(' ');
    return [
      `eslint --fix ${files}`,
      `prettier --write ${files}`,
      // Run tsc on the whole project, not per-file
      'tsc --noEmit',
    ];
  },
};
```

### Performance Tips

- Keep glob patterns specific.
- Avoid whole-project commands (like `tsc --noEmit`) in pre-commit — move to pre-push or CI.
- lint-staged runs commands in parallel per glob group. Use `--concurrent false` to serialize.
- Do not add `git add` to commands — lint-staged handles re-staging automatically since v10.

---

## pre-commit Framework (Python)

Language-agnostic hook manager written in Python. Supports hooks for any language.

### Install

```bash
pip install pre-commit   # or: brew install pre-commit
```

### Configure `.pre-commit-config.yaml`

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-added-large-files
        args: ['--maxkb=500']

  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.11.0
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format

  - repo: https://github.com/pre-commit/mirrors-mypy
    rev: v1.14.0
    hooks:
      - id: mypy
        additional_dependencies: [types-requests]
```

### Install Hooks

```bash
pre-commit install                          # Install pre-commit hook
pre-commit install --hook-type commit-msg   # commit-msg hook
pre-commit run --all-files                  # Run on all files
pre-commit autoupdate                       # Update hook versions
```

### Key Features

- **Hook marketplace**: [pre-commit.com/hooks](https://pre-commit.com/hooks.html).
- **Language isolation**: Each hook runs in its own environment.
- **Caching**: First run is slow; subsequent runs are fast.
- **`files` / `exclude`**: Scope hooks to specific paths.
- **`stages`**: Assign hooks to specific Git stages.
- Pin `rev` values. Run `pre-commit autoupdate` to update.

---

## commitlint

Enforce commit message conventions. Typically used with Conventional Commits.

### Install

```bash
npm install --save-dev @commitlint/cli @commitlint/config-conventional
```

### Configure `commitlint.config.js`

```js
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [2, 'always', [
      'feat', 'fix', 'docs', 'style', 'refactor',
      'perf', 'test', 'build', 'ci', 'chore', 'revert',
    ]],
    'subject-case': [2, 'never', ['start-case', 'pascal-case', 'upper-case']],
    'header-max-length': [2, 'always', 100],
  },
};
```

Rule format: `[severity, applicability, value]`. Severity: `0` = off, `1` = warn, `2` = error.

### Custom Plugin Rules

```js
export default {
  extends: ['@commitlint/config-conventional'],
  plugins: [
    {
      rules: {
        'ticket-in-scope': ({ scope }) => {
          const valid = !scope || /^[A-Z]+-\d+$/.test(scope);
          return [valid, 'Scope must be a ticket ID (e.g., PROJ-123)'];
        },
      },
    },
  ],
  rules: {
    'ticket-in-scope': [1, 'always'],
  },
};
```

### Wire to Husky

```bash
# .husky/commit-msg
npx --no -- commitlint --edit "$1"
```

---

## Conventional Commits

Structured commit message format that enables automated changelogs, semantic versioning, and clear history.

### Format

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### Types

| Type | Purpose |
|------|---------|
| `feat` | New feature (triggers MINOR version bump) |
| `fix` | Bug fix (triggers PATCH version bump) |
| `docs` | Documentation only |
| `style` | Formatting, whitespace (not CSS) |
| `refactor` | Code change that neither fixes nor adds |
| `perf` | Performance improvement |
| `test` | Adding or updating tests |
| `build` | Build system or dependencies |
| `ci` | CI configuration |
| `chore` | Maintenance tasks |
| `revert` | Revert a previous commit |

### Breaking Changes

Signal with `!` after type/scope or `BREAKING CHANGE:` footer:

```
feat(api)!: remove deprecated /v1 endpoints

BREAKING CHANGE: All /v1 API endpoints have been removed. Migrate to /v2.
```

Breaking changes trigger a MAJOR version bump.

### Benefits

- Automated `CHANGELOG.md` generation (via `release-please`, `semantic-release`).
- Deterministic semver from commit history.
- Machine-readable commit history.

---

## Common Hook Recipes

### Pre-commit: Lint + Format + Type-check

**Husky + lint-staged:**

```bash
# .husky/pre-commit
npx lint-staged
```

```json
{
  "lint-staged": {
    "*.{ts,tsx}": ["eslint --fix", "prettier --write"],
    "*.{json,md,css}": ["prettier --write"]
  }
}
```

**pre-commit framework:**

```yaml
repos:
  - repo: https://github.com/pre-commit/mirrors-eslint
    rev: v9.0.0
    hooks:
      - id: eslint
        args: [--fix]
```

### Commit-msg: Enforce Conventional Commits

```bash
# .husky/commit-msg
npx --no -- commitlint --edit "$1"
```

### Pre-push: Test + Build

```bash
# .husky/pre-push
npm run test -- --ci --bail
npm run build
```

Keep pre-push hooks fast. Run only critical tests.

---

## Lefthook

Go-based Git hook manager. Fast, language-agnostic, built-in parallelism. Alternative to Husky for polyglot/monorepo projects.

### Install

```bash
npm install --save-dev lefthook    # or: brew install lefthook
```

### Configure `lefthook.yml`

```yaml
pre-commit:
  parallel: true
  commands:
    lint:
      glob: "*.{js,ts,tsx}"
      run: npx eslint --fix {staged_files}
      stage_fixed: true
    format:
      glob: "*.{js,ts,tsx,json,md,css}"
      run: npx prettier --write {staged_files}
      stage_fixed: true
    typecheck:
      glob: "*.{ts,tsx}"
      run: npx tsc --noEmit

commit-msg:
  commands:
    commitlint:
      run: npx commitlint --edit {1}

pre-push:
  commands:
    test:
      run: npm run test -- --ci
```

### Key Advantages Over Husky

- **Parallel execution**: Commands run concurrently by default.
- **No Node.js runtime required**: Single binary, no cold-start.
- **Built-in staged file filtering**: `{staged_files}` placeholder — no lint-staged needed.
- **`stage_fixed: true`**: Auto-restage files modified by fixers.
- **Local overrides**: `lefthook-local.yml` for personal settings (gitignored).

---

## Sharing Hooks in Teams

- Husky: Commit `.husky/` and `prepare` script.
- Lefthook: Commit `lefthook.yml`. Each dev runs `lefthook install`.
- pre-commit: Commit `.pre-commit-config.yaml`. Each dev runs `pre-commit install`.

### CI Alignment

Run the same checks in CI that hooks enforce locally:

```yaml
# GitHub Actions
- run: npx eslint . --max-warnings 0
- run: npx prettier --check .
- run: npx commitlint --from ${{ github.event.pull_request.base.sha }}
```

Document hook setup in `CONTRIBUTING.md`. Automate installation via `prepare` (npm) or `post-checkout`.

---

## Bypassing Hooks

```bash
git commit --no-verify -m "emergency fix"
git push --no-verify
```

Appropriate: emergency hotfixes, WIP commits on feature branches, CI where hooks duplicate pipeline checks. Never bypass to avoid fixing lint errors.

---

## Performance Optimization

### Incremental Checks

- Use lint-staged or Lefthook's `{staged_files}` to check only changed files.
- Move `tsc --noEmit` to pre-push or CI.
- Use `eslint --cache` and `prettier --cache`.

### Parallel Execution

- Lefthook: `parallel: true` at hook level.
- Husky: Use shell background jobs or `concurrently`.
- pre-commit: Hooks run sequentially. Group related checks into one hook.

### Cache Aggressively

```json
{
  "lint-staged": {
    "*.{ts,tsx}": ["eslint --fix --cache", "prettier --write --cache"]
  }
}
```

### Skip Unnecessary Work

- Filter by file extension in glob patterns.
- Use Lefthook's `exclude` or pre-commit's `exclude` to skip generated files.

---

## Troubleshooting

### Hook Not Running

1. Verify hook exists and is executable: `ls -la .git/hooks/pre-commit`.
2. Husky: Check `prepare` script ran after `npm install`.
3. pre-commit / Lefthook: Run `pre-commit install` or `lefthook install`.
4. Check Git version — `core.hooksPath` requires Git 2.9+.

### Permission Issues

```bash
chmod +x .husky/pre-commit .husky/commit-msg .husky/pre-push
```

On Windows, ensure LF line endings in hook scripts. Add to `.gitattributes`:

```
.husky/* text eol=lf
```

### CI vs Local

- CI skips hooks by default. Run linters/tests as explicit CI steps.
- Set `HUSKY=0` in CI to disable Husky if hooks interfere.
- pre-commit in CI: Use `pre-commit run --all-files` as a CI step.

### Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `hint: The '.husky/pre-commit' hook was ignored` | Not executable | `chmod +x .husky/pre-commit` |
| `commitlint: Please add rules` | Missing config | Create `commitlint.config.js` |
| `lint-staged: no staged files match` | Wrong glob | Check glob patterns match your file extensions |
| `pre-commit: hook id not found` | Wrong `rev` or `id` | Run `pre-commit autoupdate`, verify hook ID |
| `core.hooksPath` conflict | Multiple hook managers | Use one manager per repo; check `git config core.hooksPath` |
