# Review: storybook-patterns

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **Deprecated `argTypesRegex` presented as current** — `actions: { argTypesRegex: '^on[A-Z].*' }` is used in SKILL.md (lines 54, 173) and assets/preview-config.ts (line 84) without any deprecation warning. In Storybook 8, `argTypesRegex` is deprecated; the recommended replacement is explicit `fn()` from `@storybook/test` per-arg. The skill *does* mention `fn()` as an alternative (SKILL.md line 176), but still showcases the deprecated approach as the primary pattern in preview.ts and the Actions section. Add a deprecation note and prefer `fn()` in examples.

2. **Deprecated `experimental_indexers` API** — references/advanced-patterns.md (line 497) uses `experimental_indexers` which was deprecated in Storybook 8 and replaced by the stable `indexers` API. Rename to `indexers` throughout.

3. **Invalid Jest config key** — references/testing-guide.md (line 618) uses `setupFilesAfterSetup` which is not a valid Jest configuration option. The correct key is `setupFilesAfterFramework`.

## Structure Check

| Criterion | Status |
|-----------|--------|
| YAML frontmatter has name+description | ✅ |
| Description has positive triggers | ✅ ("Use when creating, configuring, or debugging Storybook 8.x...") |
| Description has negative triggers | ✅ ("Do NOT trigger for general unit/E2E testing...") |
| Body under 500 lines | ✅ (498 lines) |
| Imperative voice | ✅ |
| Examples with I/O annotations | ✅ (lines 86, 210, 226, 375, 414) |
| Resources properly linked | ✅ (tables with relative paths to references/, scripts/, assets/) |
| Globs field present | ✅ (*.stories.*, .storybook/**) |

## Content Check

| API/Feature | Correct? | Notes |
|-------------|----------|-------|
| CSF3 format (Meta, StoryObj, satisfies) | ✅ | Matches current Storybook 8.x TypeScript docs |
| Play function syntax (@storybook/test) | ✅ | expect, fn, userEvent, within, waitFor imports correct |
| Addon imports (storybook/manager-api, storybook/theming) | ✅ | Correct Storybook 8 import paths |
| storybook/internal/components (AddonPanel, IconButton) | ✅ | Current API |
| Chromatic integration (chromaui/action, TurboSnap) | ✅ | Correct config and GH Actions usage |
| MSW 2.x API (http, HttpResponse from msw) | ✅ | Correct MSW v2 syntax |
| Viewport addon imports (@storybook/addon-viewport) | ✅ | INITIAL_VIEWPORTS, MINIMAL_VIEWPORTS path correct |
| `argTypesRegex` | ⚠️ | Deprecated in SB8; should flag and prefer fn() |
| `experimental_indexers` | ⚠️ | Deprecated in SB8; should use `indexers` |
| Multi-framework coverage (React, Vue, Angular, Svelte) | ✅ | All four covered with correct imports |

## Trigger Check

- ✅ Triggers for: CSF3 stories, play functions, Controls/Actions/Docs addons, Chromatic, MSW mocking, .storybook config, custom addon dev, autodocs, MDX
- ✅ Does NOT trigger for: general unit testing (Jest/Vitest without Storybook), E2E testing (Playwright/Cypress), plain React components, generic build tooling (Vite/Webpack without Storybook context)
- ✅ Globs provide file-pattern matching for `*.stories.*` and `.storybook/**`

## Summary

Exceptionally comprehensive skill covering the full Storybook 8.x surface area across four frameworks. Excellent scripts, templates, and reference docs. Three accuracy issues found involving deprecated APIs (`argTypesRegex`, `experimental_indexers`) being presented without deprecation notices, and a minor typo in a Jest config key. None are blocking — the correct alternatives are shown elsewhere in the skill. Overall quality is high.
