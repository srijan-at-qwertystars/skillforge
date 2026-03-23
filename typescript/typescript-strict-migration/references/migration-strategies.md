# TypeScript Strict Migration Strategies

## Table of Contents

- [Strategy 1: File-by-File with @ts-strict-check Comments](#strategy-1-file-by-file-with-ts-strict-check-comments)
- [Strategy 2: Project References (Strict vs Non-Strict)](#strategy-2-project-references-strict-vs-non-strict)
- [Strategy 3: typescript-strict-plugin Setup and Workflow](#strategy-3-typescript-strict-plugin-setup-and-workflow)
- [Strategy 4: Monorepo Migration (Per-Package Strict Adoption)](#strategy-4-monorepo-migration-per-package-strict-adoption)
- [Strategy 5: Using ts-migrate for Large Codebases](#strategy-5-using-ts-migrate-for-large-codebases)
- [Strategy 6: Flag-by-Flag Rollout](#strategy-6-flag-by-flag-rollout)
- [Handling Third-Party Type Declarations](#handling-third-party-type-declarations)
- [Migration Metrics and Tracking Progress](#migration-metrics-and-tracking-progress)
- [Team Workflow: PR Review Standards for Strict Code](#team-workflow-pr-review-standards-for-strict-code)

---

## Strategy 1: File-by-File with @ts-strict-check Comments

Use per-file comments to opt individual files into strict checking while keeping the global config non-strict. This is the most granular approach.

### How it works

1. Global `tsconfig.json` keeps `"strict": false`
2. Files ready for strict mode get a `// @ts-strict-check` comment at the top
3. The TypeScript compiler (via a plugin or custom checker) enforces strict rules only on annotated files

### Setup with @ts-strict directive

```ts
// @ts-strict
// ↑ This file is checked under strict rules

import { User } from "./models";

export function getUser(id: string): User | null {
  // strictNullChecks is enforced here
  const user = db.find(id);
  if (!user) return null;
  return user;
}
```

### Inverse approach: opt-out with @ts-strict-ignore

For codebases where most files are already strict-ready, annotate legacy files to opt out:

```ts
// @ts-strict-ignore
// ↑ This file is NOT checked under strict rules

import { legacyProcess } from "./old-lib";

export function handler(data) {
  // noImplicitAny not enforced here
  return legacyProcess(data);
}
```

### Bulk annotation

```bash
# Add @ts-strict-ignore to all existing .ts files
find src -name "*.ts" -exec sed -i '1s;^;// @ts-strict-ignore\n;' {} \;

# Count progress
TOTAL=$(find src -name '*.ts' | wc -l)
IGNORED=$(grep -rl '@ts-strict-ignore' src | wc -l)
echo "Strict: $((TOTAL - IGNORED)) / $TOTAL files"
```

### Workflow

1. Annotate all existing files with `@ts-strict-ignore`
2. New files are strict by default (no annotation needed)
3. When touching a legacy file, remove `@ts-strict-ignore` and fix errors
4. CI enforces no new `@ts-strict-ignore` annotations are added
5. Track percentage of files migrated over time

---

## Strategy 2: Project References (Strict vs Non-Strict)

Use TypeScript project references to create separate compilation zones with different strictness levels.

### Directory structure

```
project/
├── tsconfig.json                 # root config (references only)
├── tsconfig.base.json            # shared settings
├── src/
│   ├── strict/
│   │   ├── tsconfig.json         # strict: true
│   │   ├── auth/
│   │   ├── core/
│   │   └── utils/
│   └── legacy/
│       ├── tsconfig.json         # strict: false
│       ├── api/
│       └── handlers/
```

### Root tsconfig.json

```jsonc
{
  "files": [],
  "references": [
    { "path": "./src/strict" },
    { "path": "./src/legacy" }
  ]
}
```

### tsconfig.base.json (shared settings)

```jsonc
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "declaration": true,
    "declarationMap": true,
    "composite": true,
    "outDir": "./dist",
    "rootDir": ".",
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  }
}
```

### src/strict/tsconfig.json

```jsonc
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "outDir": "../../dist/strict",
    "rootDir": "."
  },
  "include": ["./**/*.ts"],
  "references": [
    { "path": "../legacy" }  // strict code CAN import from legacy
  ]
}
```

### src/legacy/tsconfig.json

```jsonc
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "strict": false,
    "outDir": "../../dist/legacy",
    "rootDir": "."
  },
  "include": ["./**/*.ts"]
  // legacy code should NOT import from strict (avoid dependency cycles)
}
```

### Build and check

```bash
# Build all projects in dependency order
tsc --build

# Build only strict project
tsc --build src/strict

# Clean build
tsc --build --clean
```

### Migration workflow

1. Start with all code in `src/legacy/`
2. Move files to `src/strict/` once they pass strict checks
3. Update import paths (or use path aliases to minimize churn)
4. When `src/legacy/` is empty, consolidate back to a single project with `"strict": true`

### Key constraint

With project references, cross-project imports go through `.d.ts` declaration files. The strict project sees only the declared types from legacy code, which means:

- Legacy types that use `any` will propagate `any` into strict code
- Fix exported types in legacy modules first to get clean boundaries

---

## Strategy 3: typescript-strict-plugin Setup and Workflow

The `typescript-strict-plugin` is a TypeScript language service plugin that enforces strict mode on a per-file basis without requiring separate tsconfig files.

### Installation

```bash
npm install -D typescript-strict-plugin
```

### Configuration

```jsonc
// tsconfig.json
{
  "compilerOptions": {
    "strict": false,
    "plugins": [
      {
        "name": "typescript-strict-plugin"
      }
    ]
  }
}
```

### Configuration options

```jsonc
{
  "compilerOptions": {
    "strict": false,
    "plugins": [
      {
        "name": "typescript-strict-plugin",
        "paths": [
          "src/core/",
          "src/utils/",
          "src/new-features/"
        ],
        "excludePaths": [
          "src/legacy/",
          "src/__tests__/"
        ]
      }
    ]
  }
}
```

| Option | Description |
|---|---|
| `paths` | Directories/files always checked strictly (even without `@ts-strict` comment) |
| `excludePaths` | Directories/files never checked strictly (even with `@ts-strict` comment) |

### File-level opt-in

```ts
// @ts-strict
// ↑ Enables strict checking for this file

export function safeParse(json: string): unknown {
  try {
    return JSON.parse(json);
  } catch (err) {
    // useUnknownInCatchVariables is active
    if (err instanceof Error) return { error: err.message };
    return { error: String(err) };
  }
}
```

### File-level opt-out (for files in strict paths)

```ts
// @ts-strict-ignore
// ↑ Disables strict checking for this file even if it's in a strict path
```

### Bulk annotation of legacy files

```bash
# Auto-annotate all files without @ts-strict as @ts-strict-ignore
npx update-strict-comments
```

This command scans all `.ts`/`.tsx` files and adds `// @ts-strict-ignore` to files that don't already have `// @ts-strict`.

### CI enforcement

```bash
# Run the strict plugin check in CI
npx tsc-strict
```

This exits with a non-zero code if any file marked with `// @ts-strict` (or in a strict path) has strict-mode errors.

### IDE integration

The plugin works with VS Code when using the workspace TypeScript version:

```jsonc
// .vscode/settings.json
{
  "typescript.tsdk": "node_modules/typescript/lib",
  "typescript.enablePromptUseWorkspaceTsdk": true
}
```

The editor will show strict errors inline for opted-in files while leaving legacy files unchecked.

### Complete workflow

```
1. npm install -D typescript-strict-plugin
2. Add plugin to tsconfig.json
3. Run: npx update-strict-comments  (adds @ts-strict-ignore to all files)
4. New files: write without any annotation → strict by default
5. Migrating a file:
   a. Remove // @ts-strict-ignore
   b. Run: npx tsc-strict
   c. Fix all errors
   d. Commit
6. CI runs: npx tsc-strict on every PR
7. Track: grep -c '@ts-strict-ignore' across codebase
8. Done when: zero @ts-strict-ignore comments remain
9. Flip tsconfig.json to "strict": true, remove plugin
```

---

## Strategy 4: Monorepo Migration (Per-Package Strict Adoption)

In monorepos (Nx, Turborepo, Lerna, pnpm workspaces), migrate packages independently.

### Typical monorepo structure

```
monorepo/
├── tsconfig.base.json
├── packages/
│   ├── core/           # ← migrate first (shared utilities)
│   │   ├── tsconfig.json
│   │   └── src/
│   ├── api/            # ← migrate second (depends on core)
│   │   ├── tsconfig.json
│   │   └── src/
│   ├── web-app/        # ← migrate last (depends on core + api)
│   │   ├── tsconfig.json
│   │   └── src/
│   └── legacy-admin/   # ← migrate when possible
│       ├── tsconfig.json
│       └── src/
```

### Migration order: dependency graph bottom-up

```
1. packages/core        (no internal dependencies)
2. packages/api         (depends on core)
3. packages/web-app     (depends on core + api)
4. packages/legacy-admin (depends on core + api)
```

### Per-package tsconfig

```jsonc
// packages/core/tsconfig.json — already migrated
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "rootDir": "src",
    "outDir": "dist"
  },
  "include": ["src"]
}
```

```jsonc
// packages/legacy-admin/tsconfig.json — not yet migrated
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "strict": false,
    "rootDir": "src",
    "outDir": "dist"
  },
  "include": ["src"]
}
```

### Tracking migration status across packages

```jsonc
// migration-status.json (checked into repo)
{
  "packages": {
    "core": { "strict": true, "migratedDate": "2024-01-15" },
    "api": { "strict": true, "migratedDate": "2024-02-20" },
    "web-app": { "strict": false, "errorCount": 142, "lastChecked": "2024-03-01" },
    "legacy-admin": { "strict": false, "errorCount": 891, "lastChecked": "2024-03-01" }
  }
}
```

### CI: Enforce strict on migrated packages

```yaml
# .github/workflows/strict.yml
name: Strict Check
on: [pull_request]
jobs:
  strict:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22 }
      - run: npm ci

      # Check each strict package
      - run: npx tsc --noEmit -p packages/core/tsconfig.json
      - run: npx tsc --noEmit -p packages/api/tsconfig.json

      # Non-strict packages: just ensure they compile
      - run: npx tsc --noEmit -p packages/web-app/tsconfig.json
      - run: npx tsc --noEmit -p packages/legacy-admin/tsconfig.json
```

### Nx-specific approach

```bash
# Check strict compliance for a specific project
npx nx run core:typecheck

# Check all projects
npx nx run-many --target=typecheck --all
```

```jsonc
// packages/core/project.json
{
  "targets": {
    "typecheck": {
      "command": "tsc --noEmit -p tsconfig.json"
    }
  }
}
```

### Turborepo approach

```jsonc
// turbo.json
{
  "pipeline": {
    "typecheck": {
      "dependsOn": ["^typecheck"],
      "outputs": []
    }
  }
}
```

```bash
turbo run typecheck
```

### Cross-package type boundary issues

When a strict package imports from a non-strict package, the exported types may contain implicit `any`:

```ts
// packages/legacy-admin/src/utils.ts (non-strict)
export function parseConfig(raw) {  // raw: any (implicit)
  return JSON.parse(raw);           // return: any
}

// packages/core/src/config.ts (strict)
import { parseConfig } from "@monorepo/legacy-admin";
const config = parseConfig(data); // config: any — strict benefits are lost
```

**Fix**: Add explicit types to exports in non-strict packages:

```ts
// packages/legacy-admin/src/utils.ts
export function parseConfig(raw: string): Record<string, unknown> {
  return JSON.parse(raw);
}
```

---

## Strategy 5: Using ts-migrate for Large Codebases

`ts-migrate` (by Airbnb) automates bulk migration by inserting type annotations and `@ts-expect-error` comments.

### Installation

```bash
npm install -D ts-migrate
```

### Full migration (JS → TS with strict)

```bash
# Step 1: Rename .js/.jsx files to .ts/.tsx
npx ts-migrate rename src/

# Step 2: Run codemods to add basic types and @ts-expect-error
npx ts-migrate migrate src/

# Step 3: Compile and verify
npx tsc --noEmit
```

### What ts-migrate does

1. **Renames** `.js`/`.jsx` files to `.ts`/`.tsx`
2. **Adds `@ts-expect-error`** comments above lines that error under strict mode
3. **Inserts basic type annotations** where inferable
4. **Adds explicit `any`** types where inference fails
5. **Preserves runtime behavior** — no logic changes

### Before ts-migrate

```js
// utils.js
function formatName(user) {
  return user.firstName + " " + user.lastName;
}

function getAge(user) {
  return user.birthday ? calculateAge(user.birthday) : null;
}
```

### After ts-migrate

```ts
// utils.ts
// @ts-expect-error: Parameter 'user' implicitly has an 'any' type.
function formatName(user) {
  return user.firstName + " " + user.lastName;
}

// @ts-expect-error: Parameter 'user' implicitly has an 'any' type.
function getAge(user) {
  return user.birthday ? calculateAge(user.birthday) : null;
}
```

### Post-migration cleanup

After `ts-migrate`, you have a compiling TypeScript project with many `@ts-expect-error` comments. The cleanup process:

```bash
# Count remaining issues
grep -r "@ts-expect-error" src/ | wc -l

# Find files with most issues
grep -rl "@ts-expect-error" src/ | while read f; do
  count=$(grep -c "@ts-expect-error" "$f")
  echo "$count $f"
done | sort -rn | head -20
```

### Individual ts-migrate plugins

Run specific transformations instead of the full migration:

```bash
# Only add explicit return types
npx ts-migrate -- --plugins=explicit-any src/

# Available plugins:
# - add-conversions
# - declare-missing-class-properties
# - explicit-any
# - hoist-class-statics
# - jsdoc-to-ts
# - member-accessibility
# - react-class-lifecycle-methods
# - react-class-state
# - react-default-props
# - react-props
# - react-shape
# - strip-ts-ignore
```

### Limitations

- `ts-migrate` inserts `any` and `@ts-expect-error` — it does **not** produce fully typed code
- Treat the output as a starting point, not a finished migration
- Works best for JS → TS conversion; for strict-mode adoption in existing TS, `typescript-strict-plugin` is usually better

---

## Strategy 6: Flag-by-Flag Rollout

Enable one strict flag at a time across the entire codebase. Best for small-to-medium codebases where the error count per flag is manageable.

### Recommended order (by typical error volume and difficulty)

| Order | Flag | Typical Errors | Difficulty |
|---|---|---|---|
| 1 | `noImplicitAny` | Medium | Low — add type annotations |
| 2 | `strictNullChecks` | **High** | Medium — add guards, change types |
| 3 | `strictBindCallApply` | Low | Low — fix call/apply args |
| 4 | `strictFunctionTypes` | Low-Medium | Medium — fix callback types |
| 5 | `strictPropertyInitialization` | Medium | Low — init properties |
| 6 | `noImplicitThis` | Low | Low — add this types or use arrows |
| 7 | `useUnknownInCatchVariables` | Low-Medium | Low — narrow catch vars |
| 8 | `alwaysStrict` | Zero | Zero — just emits "use strict" |

### Step-by-step for each flag

```bash
# 1. Preview the error count
npx tsc --noEmit --noImplicitAny 2>&1 | tail -1
# "Found 47 errors in 12 files."

# 2. Enable the flag in tsconfig.json
# 3. Fix all errors
# 4. Run full build to verify
npx tsc --noEmit

# 5. Commit: "chore: enable noImplicitAny"
# 6. Move to next flag
```

### Incremental tsconfig progression

```jsonc
// Phase 1
{
  "compilerOptions": {
    "strict": false,
    "noImplicitAny": true
  }
}

// Phase 2
{
  "compilerOptions": {
    "strict": false,
    "noImplicitAny": true,
    "strictNullChecks": true
  }
}

// Phase 3 ... continue adding flags

// Final
{
  "compilerOptions": {
    "strict": true
  }
}
```

### Auditing error counts per flag

```bash
#!/bin/bash
# audit-strict-flags.sh — count errors for each flag
FLAGS=(
  "noImplicitAny"
  "strictNullChecks"
  "strictBindCallApply"
  "strictFunctionTypes"
  "strictPropertyInitialization"
  "noImplicitThis"
  "useUnknownInCatchVariables"
)

for flag in "${FLAGS[@]}"; do
  count=$(npx tsc --noEmit --"$flag" 2>&1 | grep -c "error TS")
  printf "%-35s %d errors\n" "$flag" "$count"
done
```

---

## Handling Third-Party Type Declarations

Third-party libraries without proper type declarations are a major source of strict-mode errors.

### Problem 1: Missing @types packages

```ts
// ❌ Error: Could not find a declaration file for module 'some-lib'
import something from "some-lib";
```

**Fix: Install DefinitelyTyped declarations**

```bash
npm install -D @types/some-lib
```

**Fix: If @types doesn't exist, create a local declaration**

```ts
// src/types/some-lib.d.ts
declare module "some-lib" {
  export interface Config {
    timeout: number;
    retries: number;
  }
  export function init(config: Config): void;
  export function process(data: string): Promise<Result>;
}
```

### Problem 2: Outdated @types packages

```ts
// @types/express is behind express — missing new methods
import express from "express";
const app = express();
app.newMethod(); // ❌ Property 'newMethod' does not exist
```

**Fix: Augment the types**

```ts
// src/types/express-augment.d.ts
import "express";

declare module "express" {
  interface Application {
    newMethod(): void;
  }
}
```

### Problem 3: @types packages with loose typing

```ts
// Some @types packages use 'any' liberally
import lodash from "lodash";
const result = lodash.get(obj, "a.b.c"); // result: any
```

**Fix: Wrap with stricter types**

```ts
// src/utils/safe-lodash.ts
import lodash from "lodash";

export function safeGet<T>(
  obj: Record<string, unknown>,
  path: string,
  defaultValue: T
): T {
  const result = lodash.get(obj, path, defaultValue);
  return result as T;
}
```

### Problem 4: Global type pollution

```ts
// Some libraries augment global types in ways that conflict with strict mode
// Fix: isolate in a separate tsconfig
```

```jsonc
// tsconfig.lib-compat.json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "strict": false,
    "types": ["problematic-lib"]
  },
  "include": ["src/wrappers/problematic-lib-wrapper.ts"]
}
```

### Problem 5: Untyped JSON imports

```ts
// ❌ Error with resolveJsonModule + strictNullChecks
import config from "./config.json";
// config type is inferred but may have nullable fields

// ✅ Fix: Type assertion with validation
import rawConfig from "./config.json";

interface AppConfig {
  port: number;
  host: string;
  debug: boolean;
}

function validateConfig(raw: unknown): AppConfig {
  if (typeof raw !== "object" || raw === null) throw new Error("Invalid config");
  const cfg = raw as Record<string, unknown>;
  if (typeof cfg.port !== "number") throw new Error("port must be number");
  if (typeof cfg.host !== "string") throw new Error("host must be string");
  return cfg as unknown as AppConfig;
}

const config = validateConfig(rawConfig);
```

### Strategy: Shim file for all untyped modules

```ts
// src/types/untyped-modules.d.ts
// Catch-all for untyped modules — remove entries as you add proper types
declare module "legacy-auth-lib";
declare module "old-csv-parser";
declare module "internal-metrics";
```

**CI gate to prevent growth:**

```bash
# Count catch-all declarations — should decrease over time
UNTYPED=$(grep -c "declare module" src/types/untyped-modules.d.ts)
echo "Untyped modules: $UNTYPED"
if [ "$UNTYPED" -gt "$MAX_UNTYPED" ]; then
  echo "::error::Too many untyped module declarations ($UNTYPED > $MAX_UNTYPED)"
  exit 1
fi
```

---

## Migration Metrics and Tracking Progress

### Key metrics to track

| Metric | How to Measure | Target |
|---|---|---|
| Strict file percentage | `(total - @ts-strict-ignore count) / total * 100` | 100% |
| `@ts-expect-error` count | `grep -r "@ts-expect-error" src/ \| wc -l` | 0 |
| `as any` count | `grep -r "as any" src/ \| wc -l` | 0 |
| `@ts-ignore` count | `grep -r "@ts-ignore" src/ \| wc -l` | 0 |
| Explicit `any` annotations | `grep -rE ": any[^.]" src/ \| wc -l` | 0 |
| Untyped module declarations | `grep -c "declare module" src/types/ \| wc -l` | 0 |

### Automated progress script

```bash
#!/bin/bash
# strict-progress.sh — Run in CI to track migration metrics

echo "=== TypeScript Strict Migration Progress ==="
echo ""

TOTAL=$(find src -name '*.ts' -o -name '*.tsx' | wc -l)
IGNORED=$(grep -rl '@ts-strict-ignore' src 2>/dev/null | wc -l)
STRICT=$((TOTAL - IGNORED))
PERCENT=$((STRICT * 100 / TOTAL))

echo "Files:           $STRICT / $TOTAL strict ($PERCENT%)"

TS_EXPECT=$(grep -r '@ts-expect-error' src/ 2>/dev/null | wc -l)
echo "@ts-expect-error: $TS_EXPECT"

TS_IGNORE=$(grep -r '@ts-ignore' src/ 2>/dev/null | wc -l)
echo "@ts-ignore:       $TS_IGNORE"

AS_ANY=$(grep -r 'as any' src/ 2>/dev/null | wc -l)
echo "as any:           $AS_ANY"

EXPLICIT_ANY=$(grep -rE ': any[^a-zA-Z]' src/ 2>/dev/null | wc -l)
echo "explicit any:     $EXPLICIT_ANY"

echo ""
echo "Total escape hatches: $((TS_EXPECT + TS_IGNORE + AS_ANY + EXPLICIT_ANY))"
```

### GitHub Actions: Trend tracking

```yaml
# .github/workflows/strict-metrics.yml
name: Strict Metrics
on:
  push:
    branches: [main]

jobs:
  metrics:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Collect strict metrics
        run: |
          TOTAL=$(find src -name '*.ts' -o -name '*.tsx' | wc -l)
          IGNORED=$(grep -rl '@ts-strict-ignore' src 2>/dev/null | wc -l)
          ESCAPE=$(grep -rE '@ts-ignore|@ts-expect-error|as any' src/ 2>/dev/null | wc -l)
          echo "strict_files=$((TOTAL - IGNORED))" >> "$GITHUB_OUTPUT"
          echo "total_files=$TOTAL" >> "$GITHUB_OUTPUT"
          echo "escape_hatches=$ESCAPE" >> "$GITHUB_OUTPUT"

      - name: Update metrics badge
        run: |
          PERCENT=$(( (TOTAL - IGNORED) * 100 / TOTAL ))
          # Update a badge in README or post to a dashboard
          echo "Strict coverage: ${PERCENT}%"
```

### Regression prevention

```yaml
# Fail PR if strict coverage drops
- name: Check strict coverage
  run: |
    TOTAL=$(find src -name '*.ts' -o -name '*.tsx' | wc -l)
    IGNORED=$(grep -rl '@ts-strict-ignore' src 2>/dev/null | wc -l)
    PERCENT=$(( (TOTAL - IGNORED) * 100 / TOTAL ))

    # Get baseline from main branch
    git fetch origin main --depth=1
    git checkout origin/main -- strict-metrics.json 2>/dev/null || echo '{"percent":0}' > strict-metrics.json
    BASELINE=$(jq '.percent' strict-metrics.json)

    if [ "$PERCENT" -lt "$BASELINE" ]; then
      echo "::error::Strict coverage dropped from ${BASELINE}% to ${PERCENT}%"
      exit 1
    fi
    echo '{"percent":'$PERCENT'}' > strict-metrics.json
```

### Dashboard: per-directory breakdown

```bash
#!/bin/bash
# strict-breakdown.sh — Shows migration status per directory
echo "Directory                        Strict  Total   %"
echo "------------------------------------------------------"

for dir in src/*/; do
  if [ -d "$dir" ]; then
    total=$(find "$dir" -name '*.ts' -o -name '*.tsx' | wc -l)
    if [ "$total" -gt 0 ]; then
      ignored=$(grep -rl '@ts-strict-ignore' "$dir" 2>/dev/null | wc -l)
      strict=$((total - ignored))
      pct=$((strict * 100 / total))
      printf "%-32s %5d  %5d  %3d%%\n" "$dir" "$strict" "$total" "$pct"
    fi
  fi
done
```

---

## Team Workflow: PR Review Standards for Strict Code

### PR checklist for strict migration

```markdown
## Strict Migration PR Checklist

- [ ] Removed `// @ts-strict-ignore` from migrated files
- [ ] No new `@ts-expect-error` or `@ts-ignore` comments added
- [ ] No new `as any` type assertions
- [ ] No new `any` type annotations (explicit)
- [ ] All null/undefined access guarded (no non-null assertions `!` unless justified)
- [ ] Type narrowing used instead of type assertions where possible
- [ ] CI passes (`npx tsc-strict` and `npx tsc --noEmit`)
- [ ] No runtime behavior changes (strict migration is type-only)
```

### Git hooks for local enforcement

```bash
#!/bin/bash
# .husky/pre-commit — prevent committing new escape hatches

STAGED=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(ts|tsx)$')

if [ -n "$STAGED" ]; then
  # Check for new @ts-ignore
  NEW_IGNORE=$(echo "$STAGED" | xargs grep -l '@ts-ignore' 2>/dev/null)
  if [ -n "$NEW_IGNORE" ]; then
    echo "❌ New @ts-ignore found in:"
    echo "$NEW_IGNORE"
    echo "Use @ts-expect-error with a description instead, or fix the type error."
    exit 1
  fi

  # Check for new 'as any'
  NEW_ANY=$(echo "$STAGED" | xargs grep -n 'as any' 2>/dev/null)
  if [ -n "$NEW_ANY" ]; then
    echo "⚠️  New 'as any' found:"
    echo "$NEW_ANY"
    echo "Consider using a more specific type assertion or type guard."
    # Warning only — don't block commit
  fi
fi
```

### ESLint rules complementing strict mode

```jsonc
// .eslintrc.json
{
  "rules": {
    "@typescript-eslint/no-explicit-any": "error",
    "@typescript-eslint/no-non-null-assertion": "warn",
    "@typescript-eslint/no-unsafe-assignment": "error",
    "@typescript-eslint/no-unsafe-call": "error",
    "@typescript-eslint/no-unsafe-member-access": "error",
    "@typescript-eslint/no-unsafe-return": "error",
    "@typescript-eslint/strict-boolean-expressions": "warn",
    "@typescript-eslint/switch-exhaustiveness-check": "error",
    "@typescript-eslint/prefer-nullish-coalescing": "warn",
    "@typescript-eslint/prefer-optional-chain": "warn"
  }
}
```

### Code review guidelines

**DO approve:**
- Replacing `any` with specific types
- Adding type guards instead of type assertions
- Using discriminated unions over type casting
- Adding `unknown` + narrowing instead of `any`
- Removing `@ts-strict-ignore` with all errors fixed

**DON'T approve:**
- Adding new `as any` (ask for specific types)
- Using `!` non-null assertion without comment explaining why it's safe
- Replacing `any` with `unknown` but then immediately casting `as SomeType` without validation
- Silencing errors with `@ts-expect-error` without a plan to fix

### Recommended commit message convention

```
chore(strict): enable noImplicitAny

- Added type annotations to 23 functions
- Created interface definitions for API responses
- Installed @types/legacy-lib

Strict progress: 67% (142/212 files)
```

```
fix(strict): migrate src/auth/ to strict mode

- Removed @ts-strict-ignore from 8 files
- Added null guards for session lookups
- Replaced 'as any' with proper type narrowing
- Zero @ts-expect-error comments remaining

Strict progress: 73% (155/212 files)
```

### Pairing strategy for large teams

| Role | Responsibility |
|---|---|
| **Strict Champion** | Owns migration tracker, reviews strict PRs, updates progress |
| **Feature Developer** | Migrates files they touch; new code is always strict |
| **Migration Sprint** | Dedicated time (e.g., 1 day/sprint) for bulk migration |
| **Type Reviewer** | Reviews type-only changes; ensures quality over `any` escape hatches |

### Handling disagreements

When strict mode forces a non-obvious fix:

```ts
// If a proper fix is too complex for this PR, document it:
// @ts-expect-error TODO(#1234): Needs generic refactor of EventBus
// to support contravariant handlers. Tracked in issue #1234.
handler.on("click", legacyCallback);
```

Every `@ts-expect-error` must have:
1. An issue number tracking the fix
2. A brief explanation of why it can't be fixed now
3. No `@ts-ignore` — always use `@ts-expect-error` so it auto-surfaces when the underlying issue is fixed
