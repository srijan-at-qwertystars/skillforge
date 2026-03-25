# Biome API Reference

> Complete reference for biome.json schema, CLI commands, exit codes, and all configuration options.

## Table of Contents

- [biome.json Top-Level Schema](#biomejson-top-level-schema)
- [Files Configuration](#files-configuration)
- [VCS Configuration](#vcs-configuration)
- [Formatter Configuration](#formatter-configuration)
- [Linter Configuration](#linter-configuration)
- [Linter Rule Categories](#linter-rule-categories)
- [Assist Configuration](#assist-configuration)
- [Language-Specific: JavaScript/TypeScript](#language-specific-javascripttypescript)
- [Language-Specific: JSON](#language-specific-json)
- [Language-Specific: CSS](#language-specific-css)
- [Language-Specific: GraphQL](#language-specific-graphql)
- [Overrides](#overrides)
- [Extends and Plugins](#extends-and-plugins)
- [CLI Commands](#cli-commands)
- [CLI Global Flags](#cli-global-flags)
- [Exit Codes](#exit-codes)
- [Reporters](#reporters)
- [Ignore Patterns](#ignore-patterns)

---

## biome.json Top-Level Schema

```jsonc
{
  "$schema": "https://biomejs.dev/schemas/2.2.7/schema.json",
  "files": { /* ... */ },
  "vcs": { /* ... */ },
  "formatter": { /* ... */ },
  "linter": { /* ... */ },
  "assist": { /* ... */ },
  "javascript": { /* ... */ },
  "typescript": { /* ... */ },
  "json": { /* ... */ },
  "css": { /* ... */ },
  "graphql": { /* ... */ },
  "overrides": [ /* ... */ ],
  "extends": [ /* ... */ ],
  "plugins": [ /* ... */ ]
}
```

Use `biome.jsonc` for comments and trailing commas.

---

## Files Configuration

```jsonc
{
  "files": {
    "includes": ["src/**", "tests/**"],  // Globs to include (v2: replaces "include")
    "ignore": [                          // Globs to exclude
      "dist", "build", "coverage", "node_modules",
      "**/*.min.js", "**/*.bundle.js"
    ],
    "maxSize": 1048576                   // Max file size in bytes (default: 1MB)
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `includes` | `string[]` | All supported files | Glob patterns for files to process |
| `ignore` | `string[]` | `[]` | Glob patterns for files to skip |
| `maxSize` | `number` | `1048576` | Skip files larger than this (bytes) |

---

## VCS Configuration

```jsonc
{
  "vcs": {
    "enabled": true,
    "clientKind": "git",
    "useIgnoreFile": true,
    "defaultBranch": "main"
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | `boolean` | `false` | Enable VCS integration |
| `clientKind` | `"git"` | `"git"` | VCS type (only Git supported) |
| `useIgnoreFile` | `boolean` | `false` | Respect `.gitignore` |
| `defaultBranch` | `string` | `"main"` | Branch for `--changed` comparisons |

---

## Formatter Configuration

### Global Formatter

```jsonc
{
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 100,
    "lineEnding": "lf",
    "formatWithErrors": false,
    "ignore": ["generated/**"]
  }
}
```

| Field | Type | Default | Values |
|-------|------|---------|--------|
| `enabled` | `boolean` | `true` | Enable/disable formatter globally |
| `indentStyle` | `string` | `"tab"` | `"tab"` \| `"space"` |
| `indentWidth` | `number` | `2` | 1–24 |
| `lineWidth` | `number` | `80` | 1–320 |
| `lineEnding` | `string` | `"lf"` | `"lf"` \| `"crlf"` \| `"cr"` |
| `formatWithErrors` | `boolean` | `false` | Format files with syntax errors |
| `ignore` | `string[]` | `[]` | Formatter-specific ignore patterns |

---

## Linter Configuration

### Structure

```jsonc
{
  "linter": {
    "enabled": true,
    "ignore": ["scripts/**"],
    "rules": {
      "recommended": true,          // or "all": true
      "<category>": {
        "<ruleName>": "error",      // simple
        "<ruleName>": {             // with options
          "level": "warn",
          "options": { /* rule-specific */ }
        }
      }
    },
    "domains": {                    // v2 only
      "react": "recommended",
      "next": "all",
      "test": "recommended"
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | `boolean` | `true` | Enable/disable linter |
| `ignore` | `string[]` | `[]` | Linter-specific ignore patterns |
| `rules.recommended` | `boolean` | `false` | Enable curated recommended rules |
| `rules.all` | `boolean` | `false` | Enable all stable rules |
| `domains` | `object` | — | v2: Technology-specific rule groups |

### Rule Severity

| Value | Effect |
|-------|--------|
| `"error"` | Reports as error, exit code 1 |
| `"warn"` | Reports as warning (exit 0 unless `--error-on-warnings`) |
| `"off"` | Disabled |

---

## Linter Rule Categories

### suspicious — Likely Bugs (~80+ rules)

Catches patterns that are probably mistakes.

| Rule | Description | Fix |
|------|-------------|-----|
| `noDebugger` | Disallow `debugger` | Safe |
| `noConsole` | Flag `console.*` calls | — |
| `noDoubleEquals` | Require `===` / `!==` | Unsafe |
| `noExplicitAny` | Disallow `any` type | — |
| `noAssignInExpressions` | Disallow assignment in expressions | — |
| `noAsyncPromiseExecutor` | Disallow async Promise executor | — |
| `noClassAssign` | Disallow reassigning class declarations | — |
| `noCommentText` | Disallow comment-like text in JSX | Safe |
| `noCompareNegZero` | Disallow comparing against `-0` | Safe |
| `noConfusingLabels` | Disallow confusing labels | — |
| `noConfusingVoidType` | Disallow `void` type in confusing positions | Safe |
| `noDuplicateCase` | Disallow duplicate switch cases | — |
| `noDuplicateClassMembers` | Disallow duplicate class members | — |
| `noDuplicateObjectKeys` | Disallow duplicate object keys | — |
| `noDuplicateParameters` | Disallow duplicate function parameters | — |
| `noEmptyInterface` | Disallow empty interfaces | Safe |
| `noExtraNonNullAssertion` | Disallow extra `!` assertions | Safe |
| `noFallthroughSwitchClause` | Require break in switch cases | — |
| `noFunctionAssign` | Disallow reassigning function declarations | — |
| `noGlobalAssign` | Disallow assignment to globals | — |
| `noImportAssign` | Disallow reassigning imports | — |
| `noMisleadingCharacterClass` | Flag misleading character classes in regex | — |
| `noMisleadingInstantiator` | Flag class methods named like constructors | — |
| `noPrototypeBuiltins` | Disallow calling `Object.prototype` methods | — |
| `noRedeclare` | Disallow variable redeclaration | — |
| `noSelfCompare` | Disallow `x === x` | — |
| `noShadowRestrictedNames` | Disallow shadowing restricted names | — |
| `noUnsafeDeclarationMerging` | Flag unsafe declaration merging | — |
| `noUnsafeNegation` | Disallow unsafe negation | Safe |
| `useDefaultSwitchClauseLast` | Require `default` as last switch clause | — |
| `useGetterReturn` | Require `return` in getters | — |
| `useIsArray` | Prefer `Array.isArray()` | Safe |
| `useNamespaceKeyword` | Prefer `namespace` over `module` | Safe |
| `useValidTypeof` | Require valid `typeof` comparisons | Unsafe |
| `noRestrictedImports` | Ban specified imports | — |

### correctness — Definite Errors (~60+ rules)

Code that is almost certainly wrong.

| Rule | Description | Fix |
|------|-------------|-----|
| `noConstAssign` | Disallow `const` reassignment | Unsafe |
| `noConstantCondition` | Disallow constant conditions | — |
| `noConstructorReturn` | Disallow returning from constructors | — |
| `noEmptyCharacterClassInRegex` | Disallow empty character classes | — |
| `noEmptyPattern` | Disallow empty destructuring | — |
| `noGlobalObjectCalls` | Disallow calling global objects as functions | — |
| `noInnerDeclarations` | Disallow declarations in nested blocks | — |
| `noInvalidConstructorSuper` | Validate `super()` calls | — |
| `noInvalidNewBuiltin` | Disallow `new` on non-constructors | Safe |
| `noNewSymbol` | Disallow `new Symbol()` | Safe |
| `noNonoctalDecimalEscape` | Disallow `\8` and `\9` in strings | Unsafe |
| `noPrecisionLoss` | Disallow literal numbers that lose precision | — |
| `noSelfAssign` | Disallow `x = x` | — |
| `noSetterReturn` | Disallow returning from setters | — |
| `noSwitchDeclarations` | Disallow declarations in switch cases | Unsafe |
| `noUndeclaredVariables` | Flag use of undeclared variables | — |
| `noUnreachable` | Disallow unreachable code | — |
| `noUnreachableSuper` | Disallow unreachable `super()` | — |
| `noUnsafeFinally` | Disallow unsafe `finally` blocks | — |
| `noUnsafeOptionalChaining` | Disallow unsafe optional chaining | — |
| `noUnusedImports` | Remove unused imports | Safe |
| `noUnusedLabels` | Remove unused labels | Safe |
| `noUnusedPrivateClassMembers` | Flag unused private members | Safe |
| `noUnusedVariables` | Flag unused variables | Safe |
| `noVoidTypeReturn` | Disallow `void` function returning value | — |
| `useExhaustiveDependencies` | Validate React hook dependencies | — |
| `useHookAtTopLevel` | Enforce hooks at top level | — |
| `useIsNan` | Require `Number.isNaN()` | Unsafe |
| `useValidForDirection` | Validate `for` loop direction | — |
| `useYield` | Require `yield` in generators | — |

### style — Code Conventions (~40+ rules)

Enforces consistency (not formatting — that's the formatter).

| Rule | Description | Fix |
|------|-------------|-----|
| `useConst` | Prefer `const` over `let` when not reassigned | Safe |
| `noVar` | Disallow `var` | Unsafe |
| `useTemplate` | Prefer template literals over concatenation | Unsafe |
| `noDefaultExport` | Disallow default exports | — |
| `useExportType` | Use `export type` for type-only exports | Safe |
| `useImportType` | Use `import type` for type-only imports | Safe |
| `useBlockStatements` | Require braces around blocks | Safe |
| `useCollapsedElseIf` | Prefer `else if` over nested `if` | Safe |
| `useConsistentArrayType` | Consistent array type syntax | Safe |
| `useDefaultParameterLast` | Default params last in function signature | — |
| `useEnumInitializers` | Require explicit enum values | Safe |
| `useExponentiationOperator` | Prefer `**` over `Math.pow()` | Safe |
| `useFilenamingConvention` | Enforce file naming convention | — |
| `useForOf` | Prefer `for...of` over index loop | — |
| `useLiteralEnumMembers` | Require literal enum members | — |
| `useNamingConvention` | Enforce naming conventions | — |
| `useNodejsImportProtocol` | Require `node:` prefix for Node imports | Safe |
| `useNumberNamespace` | Prefer `Number.parseInt()` over global | Safe |
| `useNumericLiterals` | Prefer numeric literals over `parseInt` | Safe |
| `useSelfClosingElements` | Prefer `<Foo />` over `<Foo></Foo>` | Safe |
| `useShorthandArrayType` | Prefer `T[]` over `Array<T>` | Safe |
| `useShorthandAssign` | Prefer `x += 1` over `x = x + 1` | Safe |
| `useSingleVarDeclarator` | One variable per declaration | Safe |

### complexity — Reduce Complexity (~32 rules)

Simplify code patterns.

| Rule | Description | Fix |
|------|-------------|-----|
| `noExtraBooleanCast` | Remove unnecessary `Boolean()` / `!!` | Safe |
| `noForEach` | Prefer `for...of` over `.forEach()` | — |
| `noMultipleSpacesInRegularExpressionLiterals` | Remove extra spaces in regex | Safe |
| `noStaticOnlyClass` | Disallow classes with only static members | — |
| `noThisInStatic` | Disallow `this` in static methods | Safe |
| `noUselessCatch` | Remove useless catch clauses | Safe |
| `noUselessConstructor` | Remove empty constructors | Safe |
| `noUselessEmptyExport` | Remove useless `export {}` | Safe |
| `noUselessFragments` | Remove unnecessary React fragments | Safe |
| `noUselessLabel` | Remove useless labels | Safe |
| `noUselessLoneBlockStatements` | Remove useless lone blocks | Safe |
| `noUselessRename` | Remove useless import/export renaming | Safe |
| `noUselessSwitchCase` | Remove useless switch cases | Safe |
| `noUselessTernary` | Remove useless ternary | Safe |
| `noUselessTypeConstraint` | Remove useless type constraints | Safe |
| `noVoid` | Disallow `void` operator | — |
| `noWith` | Disallow `with` statement | — |
| `useFlatMap` | Prefer `.flatMap()` over `.map().flat()` | Safe |
| `useLiteralKeys` | Prefer `obj.key` over `obj["key"]` | Safe |
| `useOptionalChain` | Prefer `?.` over `&&` chains | Safe |
| `useSimpleNumberKeys` | Prefer simple object keys for numbers | Safe |
| `useSimplifiedLogicExpression` | Simplify boolean expressions | Safe |

### a11y — Accessibility (~36 rules)

Web accessibility best practices for JSX.

| Rule | Description | Fix |
|------|-------------|-----|
| `noAccessKey` | Disallow `accessKey` attribute | — |
| `noAriaHiddenOnFocusable` | Don't hide focusable elements | Safe |
| `noAriaUnsupportedElements` | No ARIA on elements that don't support it | Safe |
| `noAutofocus` | Disallow `autoFocus` | Safe |
| `noBlankTarget` | Require `rel="noreferrer"` with `target="_blank"` | Safe |
| `noDistractingElements` | Disallow `<marquee>` / `<blink>` | Safe |
| `noHeaderScope` | Disallow `scope` on non-`th` elements | Safe |
| `noInteractiveElementToNoninteractiveRole` | Prevent interactive → non-interactive role | — |
| `noNoninteractiveElementToInteractiveRole` | Prevent non-interactive → interactive role | — |
| `noNoninteractiveTabindex` | Disallow tabindex on non-interactive elements | — |
| `noPositiveTabindex` | Disallow positive tabindex | — |
| `noRedundantAlt` | Disallow redundant "image" in alt text | — |
| `noRedundantRoles` | Remove redundant ARIA roles | Safe |
| `noSvgWithoutTitle` | Require `<title>` in SVGs | — |
| `useAltText` | Require alt text on images | — |
| `useAnchorContent` | Require content in `<a>` tags | — |
| `useAriaActivedescendantWithTabindex` | Require tabindex with `aria-activedescendant` | Safe |
| `useAriaPropsForRole` | Require ARIA props for roles | — |
| `useButtonType` | Require `type` on `<button>` | — |
| `useHeadingContent` | Require content in headings | — |
| `useHtmlLang` | Require `lang` on `<html>` | — |
| `useIframeTitle` | Require `title` on `<iframe>` | — |
| `useKeyWithClickEvents` | Require keyboard handler with click | — |
| `useKeyWithMouseEvents` | Require keyboard handler with mouse | — |
| `useMediaCaption` | Require captions on media | — |
| `useValidAnchor` | Validate anchor elements | — |
| `useValidAriaProps` | Validate ARIA attributes | — |
| `useValidAriaRole` | Validate ARIA roles | Safe |
| `useValidAriaValues` | Validate ARIA values | — |
| `useValidLang` | Validate language codes | — |

### performance — Runtime Efficiency (~10 rules)

| Rule | Description | Fix |
|------|-------------|-----|
| `noAccumulatingSpread` | Disallow spreading in `.reduce()` | — |
| `noBarrelFile` | Disallow barrel/index re-export files | — |
| `noDelete` | Prefer `undefined` assignment over `delete` | Unsafe |
| `noReExportAll` | Disallow `export * from` | — |

### security — Safety (~6 rules)

| Rule | Description | Fix |
|------|-------------|-----|
| `noDangerouslySetInnerHtml` | Disallow `dangerouslySetInnerHTML` | — |
| `noDangerouslySetInnerHtmlWithChildren` | Disallow both `children` and `dangerouslySetInnerHTML` | — |
| `noGlobalEval` | Disallow `eval()` | — |

---

## Assist Configuration

```jsonc
{
  "assist": {
    "enabled": true,
    "actions": {
      "source": {
        "organizeImports": "on",          // or object with options
        "useSortedKeys": "on"
      }
    }
  }
}
```

| Action | Effect |
|--------|--------|
| `organizeImports` | Sort and group import statements |
| `useSortedKeys` | Alphabetically sort object keys |

---

## Language-Specific: JavaScript/TypeScript

```jsonc
{
  "javascript": {
    "formatter": {
      "enabled": true,
      "quoteStyle": "single",
      "jsxQuoteStyle": "double",
      "semicolons": "always",
      "trailingCommas": "all",
      "arrowParentheses": "always",
      "bracketSpacing": true,
      "bracketSameLine": false,
      "quoteProperties": "asNeeded",
      "attributePosition": "auto"
    },
    "linter": {
      "enabled": true
    },
    "parser": {
      "unsafeParameterDecoratorsEnabled": false
    },
    "globals": ["__DEV__", "process"]
  }
}
```

### JavaScript Formatter Options

| Option | Type | Default | Values |
|--------|------|---------|--------|
| `quoteStyle` | `string` | `"double"` | `"single"` \| `"double"` |
| `jsxQuoteStyle` | `string` | `"double"` | `"single"` \| `"double"` |
| `semicolons` | `string` | `"always"` | `"always"` \| `"asNeeded"` |
| `trailingCommas` | `string` | `"all"` | `"all"` \| `"es5"` \| `"none"` |
| `arrowParentheses` | `string` | `"always"` | `"always"` \| `"asNeeded"` |
| `bracketSpacing` | `boolean` | `true` | Add spaces in `{ obj }` |
| `bracketSameLine` | `boolean` | `false` | `>` on same line as last attr |
| `quoteProperties` | `string` | `"asNeeded"` | `"asNeeded"` \| `"preserve"` |
| `attributePosition` | `string` | `"auto"` | `"auto"` \| `"multiline"` |

### Parser Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `unsafeParameterDecoratorsEnabled` | `boolean` | `false` | Enable legacy parameter decorators |

### Globals

```jsonc
{
  "javascript": {
    "globals": ["__DEV__", "process", "globalThis"]
  }
}
```

Prevents `noUndeclaredVariables` from flagging global variables.

---

## Language-Specific: JSON

```jsonc
{
  "json": {
    "formatter": {
      "enabled": true,
      "indentStyle": "space",
      "indentWidth": 2,
      "lineWidth": 80,
      "lineEnding": "lf",
      "trailingCommas": "none"
    },
    "linter": {
      "enabled": true
    },
    "parser": {
      "allowComments": true,
      "allowTrailingCommas": true
    }
  }
}
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `trailingCommas` | `string` | `"none"` | `"none"` \| `"all"` — for JSONC |
| `allowComments` | `boolean` | Auto-detect | Allow `//` and `/* */` in JSON |
| `allowTrailingCommas` | `boolean` | Auto-detect | Allow trailing commas |

Biome auto-detects JSONC for `tsconfig.json`, `biome.jsonc`, etc.

---

## Language-Specific: CSS

```jsonc
{
  "css": {
    "formatter": {
      "enabled": true,
      "indentStyle": "space",
      "indentWidth": 2,
      "lineWidth": 80,
      "quoteStyle": "double"
    },
    "linter": {
      "enabled": true
    }
  }
}
```

| Option | Type | Default | Values |
|--------|------|---------|--------|
| `quoteStyle` | `string` | `"double"` | `"single"` \| `"double"` |

> **Note**: Biome supports standard CSS only. SCSS, Less, and Sass are **not** supported.

---

## Language-Specific: GraphQL

```jsonc
{
  "graphql": {
    "formatter": {
      "enabled": true,
      "indentStyle": "space",
      "indentWidth": 2,
      "lineWidth": 80
    }
  }
}
```

GraphQL support: formatting only (no linting as of v2.2).

---

## Overrides

```jsonc
{
  "overrides": [
    {
      "include": ["**/*.test.ts"],     // Required: glob patterns
      "exclude": ["**/__mocks__/**"],  // Optional: exclude within include
      "formatter": { /* ... */ },
      "linter": { /* ... */ },
      "javascript": { /* ... */ },
      "json": { /* ... */ },
      "css": { /* ... */ }
    }
  ]
}
```

Overrides are evaluated top-to-bottom. Later entries take precedence.

---

## Extends and Plugins

### extends

```jsonc
{
  "extends": [
    "./shared/biome-base.json",
    "@my-org/biome-config/strict.json"
  ]
}
```

### plugins (GritQL)

```jsonc
{
  "plugins": [
    "./biome-plugins/no-moment.grit",
    "./biome-plugins/enforce-strict-equality.grit"
  ]
}
```

---

## CLI Commands

### `biome check`

Run lint + format + assist checks.

```bash
biome check [PATH...]                   # Read-only check
biome check --write [PATH...]           # Apply safe fixes + formatting
biome check --write --unsafe [PATH...]  # Include unsafe fixes
```

### `biome lint`

Run linter only.

```bash
biome lint [PATH...]                    # Read-only
biome lint --write [PATH...]            # Apply safe fixes
biome lint --write --unsafe [PATH...]   # Include unsafe fixes
```

### `biome format`

Run formatter only.

```bash
biome format [PATH...]                  # Read-only (show diff)
biome format --write [PATH...]          # Apply formatting
```

### `biome ci`

CI-optimized: read-only, strict, supports reporters.

```bash
biome ci [PATH...]
biome ci --reporter=github .            # GitHub Actions annotations
biome ci --reporter=gitlab .            # GitLab code quality
biome ci --reporter=junit .             # JUnit XML
```

### `biome init`

Create initial `biome.json`.

```bash
biome init                              # Create biome.json
```

### `biome migrate`

Migrate from other tools or upgrade config.

```bash
biome migrate eslint --write            # Migrate ESLint config
biome migrate prettier --write          # Migrate Prettier config
biome migrate --write                   # Upgrade biome.json to latest format
```

### `biome search`

Search code using GritQL patterns.

```bash
biome search 'console.log($msg)' src/
biome search '$x == null' src/
```

### `biome explain`

Get detailed info about a rule.

```bash
biome explain suspicious/noConsole
biome explain noUnusedVariables
```

---

## CLI Global Flags

| Flag | Description |
|------|-------------|
| `--write` | Apply fixes to files |
| `--unsafe` | Include potentially behavior-changing fixes |
| `--staged` | Only process git-staged files |
| `--changed` | Files changed since `defaultBranch` |
| `--since=<ref>` | Files changed since a git ref |
| `--config-path=<path>` | Custom config directory |
| `--reporter=<type>` | Output format (see Reporters) |
| `--max-diagnostics=<n>` | Cap diagnostic count (`none` for unlimited) |
| `--diagnostic-level=<level>` | Minimum severity: `info` \| `warn` \| `error` |
| `--error-on-warnings` | Exit non-zero on warnings |
| `--no-errors-on-unmatched` | Don't error when no files match |
| `--files-ignore-unknown=true` | Skip unsupported file types |
| `--colors=off` | Disable colored output |
| `--verbose` | Enable verbose logging |
| `--only=<group>` | Only run specific rule group(s) |
| `--skip=<rule>` | Skip specific rule(s) |
| `--formatter-enabled=<bool>` | Toggle formatter in `check` |
| `--linter-enabled=<bool>` | Toggle linter in `check` |

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success — no errors found |
| `1` | Errors found (lint, format, or import issues) |
| `2` | CLI usage error or config error |

With `--error-on-warnings`: warnings also cause exit code 1.

---

## Reporters

| Reporter | Format | Use Case |
|----------|--------|----------|
| `default` | Human-readable terminal output | Local development |
| `json` | Machine-readable JSON | Parsing in scripts |
| `json-pretty` | Formatted JSON | Debugging |
| `github` | GitHub Actions annotations | GitHub CI |
| `gitlab` | GitLab code quality report | GitLab CI |
| `junit` | JUnit XML | CI systems with JUnit support |
| `sarif` | SARIF format | Security/code analysis tools |

---

## Ignore Patterns

### Three Levels of Ignoring

1. **Global** — `files.ignore`: excludes from all tools
   ```jsonc
   { "files": { "ignore": ["dist/**", "vendor/**"] } }
   ```

2. **Per-tool** — `formatter.ignore`, `linter.ignore`: granular control
   ```jsonc
   {
     "formatter": { "ignore": ["**/*.generated.ts"] },
     "linter": { "ignore": ["scripts/**"] }
   }
   ```

3. **VCS** — `vcs.useIgnoreFile: true`: respects `.gitignore`

### Inline Suppression

```typescript
// Single line
// biome-ignore lint/suspicious/noConsole: CLI output needed
console.log(msg);

// Range
// biome-ignore-start lint/correctness/noUnusedVariables
const a = 1;
const b = 2;
// biome-ignore-end lint/correctness/noUnusedVariables

// Format suppression
// biome-ignore format: manual table alignment
const x = 1;
```

### CLI Overrides

```bash
# Ignore unknown file types
biome check --files-ignore-unknown=true .

# Suppress "no files matched" errors
biome check --no-errors-on-unmatched .
```
