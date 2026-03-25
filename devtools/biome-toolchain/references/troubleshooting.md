# Biome Troubleshooting Guide

> Solutions for common Biome errors, migration issues, CI failures, and performance problems.

## Table of Contents

- [Parse Errors](#parse-errors)
- [Config Validation Errors](#config-validation-errors)
- [Conflicting Rules](#conflicting-rules)
- [Migration from ESLint](#migration-from-eslint)
- [Migration from Prettier](#migration-from-prettier)
- [Biome v1 to v2 Migration](#biome-v1-to-v2-migration)
- [CI/CD Failures](#cicd-failures)
- [Editor Integration Problems](#editor-integration-problems)
- [Performance Issues](#performance-issues)
- [Rule Suppression Patterns](#rule-suppression-patterns)
- [Handling Third-Party Code](#handling-third-party-code)
- [Common Error Messages](#common-error-messages)

---

## Parse Errors

### Unsupported Syntax

**Symptom**: `Biome could not parse this file` or unexpected parse errors.

**Causes**:
- File uses syntax Biome doesn't support (decorators with non-standard proposals, pipeline operator)
- File is actually HTML/Vue/Svelte/Astro with embedded JS (partial support)
- SCSS/Less/Sass files (Biome supports plain CSS only)
- Malformed source (broken syntax)

**Solutions**:
```jsonc
// Exclude unsupported files
{
  "files": {
    "ignore": ["**/*.vue", "**/*.svelte", "**/*.scss"]
  },
  // Or skip unknown file types
  "formatter": { "ignore": ["**/*.astro"] },
  "linter": { "ignore": ["**/*.astro"] }
}
```

### formatWithErrors

If you want formatting to proceed despite parse errors:
```jsonc
{ "formatter": { "formatWithErrors": true } }
```

### File Too Large

**Symptom**: File silently skipped.

Biome skips files >1 MB by default:
```jsonc
{ "files": { "maxSize": 2097152 } }  // 2 MB
```

---

## Config Validation Errors

### Invalid biome.json

**Symptom**: `Failed to deserialize` or `Unknown key` errors.

**Common causes**:
- Typo in key name (e.g., `"semicolons"` inside `"formatter"` instead of `"javascript.formatter"`)
- Using v1 keys in v2 config (e.g., `"ignore"` instead of `"files.ignore"`)
- JSON syntax errors in `biome.json` (trailing commas in JSON, not JSONC)

**Solutions**:
1. Use `biome.jsonc` if you want comments and trailing commas
2. Add `$schema` for editor validation:
   ```jsonc
   { "$schema": "https://biomejs.dev/schemas/2.2.7/schema.json" }
   ```
3. Run `npx biome check` — it reports config errors before processing files

### Wrong Nesting

```jsonc
// WRONG: quoteStyle at top-level formatter
{ "formatter": { "quoteStyle": "single" } }

// CORRECT: quoteStyle under javascript.formatter
{ "javascript": { "formatter": { "quoteStyle": "single" } } }
```

### Common Misplacements

| Option | Wrong Location | Correct Location |
|--------|---------------|-----------------|
| `quoteStyle` | `formatter` | `javascript.formatter` or `css.formatter` |
| `semicolons` | `formatter` | `javascript.formatter` |
| `trailingCommas` | `formatter` | `javascript.formatter` or `json.formatter` |
| `jsxQuoteStyle` | `formatter` | `javascript.formatter` |

---

## Conflicting Rules

### Rules That Conflict With Each Other

**Symptom**: Fix one diagnostic, another appears at the same location.

Biome's built-in rules are designed not to conflict, but issues can arise with:

1. **GritQL plugins conflicting with built-in rules**: Disable the built-in version
2. **`all: true` enabling contradictory rules**: Explicitly disable the unwanted one:
   ```jsonc
   {
     "linter": {
       "rules": {
         "all": true,
         "style": {
           "noDefaultExport": "off",    // Conflicts with framework requirements
           "useDefaultExportedComponent": "off"  // If exists
         }
       }
     }
   }
   ```

### Rules Conflicting With Formatter

The Biome linter and formatter are separate — they should not conflict. If you see formatting applied then reverted:
- Ensure you're not running Prettier alongside Biome
- Check VS Code has only one default formatter set
- Remove `eslint-config-prettier` if still installed

---

## Migration from ESLint

### Step-by-Step Migration

```bash
# 1. Auto-migrate config
npx biome migrate eslint --write

# 2. Review generated biome.json
cat biome.json

# 3. Run and check for issues
npx biome check .

# 4. Fix formatting differences
npx biome check --write .

# 5. Remove ESLint when satisfied
npm uninstall eslint @typescript-eslint/parser @typescript-eslint/eslint-plugin \
  eslint-config-prettier eslint-plugin-react eslint-plugin-react-hooks \
  eslint-plugin-import eslint-plugin-jsx-a11y
rm .eslintrc* .eslintignore
```

### Rules Without Biome Equivalents

These ESLint rules/plugins have **no Biome equivalent** yet:
- `eslint-plugin-promise` (most rules)
- `eslint-plugin-n` (Node.js-specific)
- `eslint-plugin-unicorn` (partial — some rules migrated)
- `@typescript-eslint` type-aware rules requiring the TS compiler (e.g., `no-misused-promises`, `no-floating-promises` — nursery has `noFloatingPromises`)
- Custom ESLint rules (rewrite as GritQL plugins)

### Common Migration Surprises

| Issue | Cause | Fix |
|-------|-------|-----|
| Too many `noDefaultExport` errors | Biome enables this with `recommended` in strict style | `"style": { "noDefaultExport": "off" }` |
| Import order changed | Biome sorts differently from `eslint-plugin-import` | Configure `organizeImports` groups |
| `noExplicitAny` too strict | ESLint may have had this as warning | Adjust severity or add overrides for test files |
| Missing `eslint-disable` → `biome-ignore` | Auto-migrate doesn't convert inline comments | Find/replace: `eslint-disable.*` → `biome-ignore` |

### Inline Comment Migration

```bash
# Find all ESLint disable comments
grep -rn "eslint-disable" src/

# Manual conversion pattern:
# FROM: // eslint-disable-next-line no-console
# TO:   // biome-ignore lint/suspicious/noConsole: <reason>
```

---

## Migration from Prettier

### Step-by-Step

```bash
npx biome migrate prettier --write
```

### Formatting Differences

Biome's formatter is ~97% compatible with Prettier. Known differences:

| Area | Prettier | Biome |
|------|----------|-------|
| JSX multiline | Different line-breaking in some edge cases | May wrap differently |
| Object formatting | Certain nested object formatting | Slightly different heuristics |
| Template literals | Some edge cases | Different whitespace choices |
| HTML attributes | Some wrapping differences | Different attribute placement |

### Handling Diffs After Migration

```bash
# Format everything with Biome
npx biome format --write .

# Commit the formatting changes as a single "migration" commit
git add -A
git commit -m "chore: migrate formatting from Prettier to Biome"
```

> **Tip**: Use `git blame --ignore-rev` to skip the formatting commit in blame history. Add the commit hash to `.git-blame-ignore-revs`.

---

## Biome v1 to v2 Migration

### Auto-Migrate

```bash
npx @biomejs/biome migrate --write
```

### Key Breaking Changes

| v1 | v2 | Action |
|----|----|----|
| `"ignore": [...]` in linter/formatter | `"files": { "ignore": [...] }` or negation globs in `includes` | Update config structure |
| `rome-ignore` comments | `biome-ignore` | Find/replace |
| `--config-path` CLI flag | Removed | Use `--config-path` in newer syntax or let Biome auto-discover |
| `organizeImports.enabled` | Moved to `assist.actions.source.organizeImports` | Update config |
| `trailingComma` (old key) | `trailingCommas` | Rename |
| Flat `ignore`/`include` | `files.includes` with negation globs | Rewrite patterns |

### Config Structure Change

```jsonc
// v1 style
{
  "organizeImports": { "enabled": true },
  "linter": { "ignore": ["dist/**"] }
}

// v2 style
{
  "assist": {
    "actions": { "source": { "organizeImports": "on" } }
  },
  "files": { "includes": ["**", "!dist/**"] }
}
```

### New v2 Features to Enable

```jsonc
{
  "linter": {
    "domains": {
      "react": "recommended",
      "test": "recommended"
    }
  }
}
```

---

## CI/CD Failures

### Exit Code Issues

| Exit Code | Meaning |
|-----------|---------|
| `0` | Success — no errors |
| `1` | Lint/format errors found |
| `2` | Config error or CLI usage error |

`biome ci` is strict: any lint error or formatting difference = exit 1.

### Common CI Problems

**Problem**: CI fails but local passes.
```bash
# Ensure same Biome version
npx biome --version  # local
# Compare with CI — use --save-exact in package.json
```

**Problem**: "No files matched" error in CI.
```bash
# Add --no-errors-on-unmatched
biome ci --no-errors-on-unmatched .
```

**Problem**: Too many diagnostics flood CI logs.
```bash
biome ci --max-diagnostics=50 .
```

**Problem**: CI is slow on large repos.
```bash
# Only check changed files
biome ci --changed --since=origin/main .
```

### GitHub Actions — Recommended Setup

```yaml
- uses: biomejs/setup-biome@v2
  with:
    version: latest  # or pin: "2.2.7"
- run: biome ci --reporter=github .
```

The `--reporter=github` flag produces GitHub-native annotations on PRs.

### GitLab CI

```yaml
biome:
  image: node:22
  script:
    - npx @biomejs/biome ci --reporter=gitlab .
  artifacts:
    reports:
      codequality: gl-code-quality-report.json
```

---

## Editor Integration Problems

### VS Code — Biome Not Formatting

**Checklist**:
1. Install `biomejs.biome` extension
2. Set as default formatter:
   ```json
   { "editor.defaultFormatter": "biomejs.biome" }
   ```
3. Set per-language if needed:
   ```json
   { "[typescript]": { "editor.defaultFormatter": "biomejs.biome" } }
   ```
4. Disable conflicting extensions (Prettier, ESLint formatting)
5. Check Output panel → "Biome" for errors

### VS Code — Biome Binary Not Found

**Symptom**: Extension shows "Could not find Biome binary".

**Solutions**:
- Run `npm install` to ensure `@biomejs/biome` is in `node_modules`
- Set explicit path: `"biome.lspBin": "./node_modules/.bin/biome"`
- For global install: `"biome.lspBin": "/usr/local/bin/biome"`

### JetBrains — Biome Not Working

1. Go to Settings → Languages & Frameworks → Biome
2. Ensure "Enable Biome" is checked
3. Verify the Biome binary path (auto-detected from `node_modules`)
4. Restart the IDE after configuration changes

### Multiple Formatters Conflict

If both Prettier and Biome are installed:
```json
{
  "editor.defaultFormatter": "biomejs.biome",
  "prettier.enable": false
}
```

---

## Performance Issues

### Large Codebases

Biome is written in Rust and handles large repos well, but:

**Symptom**: Slow initial run on huge monorepo.

**Solutions**:
```jsonc
{
  "files": {
    "ignore": [
      "node_modules",
      "dist",
      "build",
      ".next",
      "coverage",
      "**/*.min.js",
      "**/*.bundle.js"
    ],
    "maxSize": 1048576  // Skip files > 1MB
  },
  "vcs": {
    "enabled": true,
    "useIgnoreFile": true  // Respect .gitignore
  }
}
```

**Use `--changed` for incremental checking**:
```bash
biome ci --changed --since=origin/main .
```

### Memory Usage

For very large monorepos (10,000+ files), Biome's scanner (v2) may use significant memory. Workarounds:
- Process packages individually: `biome check packages/app/`
- Use `files.includes` to narrow scope
- Run in CI with adequate memory allocation

### Slow Editor Experience

- Ensure `node_modules`, `dist`, etc. are in `files.ignore`
- Check that VCS integration is enabled (avoids scanning git-ignored files)
- Biome LSP processes files on-demand — it shouldn't be slow for editing

---

## Rule Suppression Patterns

### Single-Line Suppression

```typescript
// biome-ignore lint/suspicious/noConsole: needed for debugging
console.log("debug info");
```

### Multi-Line Range Suppression

```typescript
// biome-ignore-start lint/suspicious/noConsole
console.log("start");
console.log("end");
// biome-ignore-end lint/suspicious/noConsole
```

### Format Suppression

```typescript
// biome-ignore format: manual alignment for readability
const matrix = [
  [1,  0,  0],
  [0,  1,  0],
  [0,  0,  1],
];
```

### Multiple Rules on One Line

```typescript
// biome-ignore lint/suspicious/noConsole lint/style/noVar: legacy code
var x = 1; console.log(x);
```

### Suppression Must Include Reason

```typescript
// WRONG — no explanation
// biome-ignore lint/suspicious/noConsole

// CORRECT — includes reason after colon
// biome-ignore lint/suspicious/noConsole: CLI tool needs console output
```

### Finding Existing Suppressions

```bash
grep -rn "biome-ignore" src/
grep -rn "biome-ignore-start" src/  # Find range suppressions
```

---

## Handling Third-Party Code

### Vendored / Generated Code

```jsonc
{
  "files": {
    "ignore": [
      "vendor/**",
      "src/generated/**",
      "src/**/*.generated.ts",
      "public/scripts/**"
    ]
  }
}
```

### Selective Disable for Generated Code

```jsonc
{
  "overrides": [
    {
      "include": ["src/generated/**", "src/**/*.gen.ts"],
      "linter": { "enabled": false },
      "formatter": { "enabled": false }
    }
  ]
}
```

### Declaration Files

```jsonc
{
  "overrides": [
    {
      "include": ["**/*.d.ts"],
      "linter": {
        "rules": {
          "suspicious": { "noExplicitAny": "off" },
          "style": { "noNamespace": "off" }
        }
      }
    }
  ]
}
```

### Checking Only Your Code (Ignoring Dependencies)

```jsonc
{
  "files": {
    "includes": ["src/**", "tests/**", "scripts/**"]
  },
  "vcs": {
    "enabled": true,
    "useIgnoreFile": true  // .gitignore already excludes node_modules
  }
}
```

---

## Common Error Messages

### "Run `biome migrate` to apply the changes"

Biome detected your config uses deprecated syntax. Run:
```bash
npx biome migrate --write
```

### "The file was skipped. Unknown file type."

Biome doesn't know this file extension. Either:
- Add it to the supported list (if supported)
- Ignore it: `"files": { "ignore": ["**/*.xyz"] }`
- Use `--files-ignore-unknown=true` in CLI

### "Found X errors and Y warnings"

Not an error per se — this is Biome reporting results. Exit code 1 means errors were found.

To convert warnings to non-blocking:
```bash
biome ci --diagnostic-level=error .  # Only fail on errors, not warnings
```

### "Could not resolve configuration"

Config file path issue:
```bash
# Check which config Biome is using
npx biome check --verbose .
# Explicitly point to config
npx biome check --config-path=./config .
```

### "Conflicting configuration in overrides"

Two override entries match the same file with contradictory settings. Later entries win — reorder or merge them.

### "The maximum number of diagnostics has been reached"

```bash
npx biome check --max-diagnostics=none .  # Show all
npx biome check --max-diagnostics=200 .   # Increase limit
```
