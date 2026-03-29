# QA Review: earthly skill

**Date**: 2025-03-29
**Reviewer**: Sisyphus-Junior
**Overall Score**: 4.0/5

## Scores

| Criteria | Score | Notes |
|----------|-------|-------|
| Completeness | 4/5 | Missing proper Monorepo Patterns section structure |
| Accuracy | 4/5 | Content accurate but has broken section and duplicate CLI example |
| Actionability | 5/5 | Dense, actionable voice throughout |
| Examples | 5/5 | Good input/output examples with Earthfile syntax |

## Issues Found

### 1. Broken Monorepo Patterns Section (Lines 274-281)
**Severity**: High
**Issue**: Code block fragment without opening fence or section header
```
    BUILD ./libs/shared+test

# Build all
docker-all:
    BUILD ./services/api+docker
    BUILD ./services/worker+docker
```
**Fix**: Add proper section header "## Monorepo Patterns" and opening code fence with context.

### 2. Duplicate CLI Usage in SSH Agent Section (Line 271)
**Severity**: Medium
**Issue**: Line 271 duplicates line 253 - shows `earthly --secret api_key=$(cat api.key) +build` instead of SSH-specific command
**Fix**: Should show `earthly --ssh-agent +build` or similar SSH-specific CLI usage.

### 3. Missing from INDEX.md
**Severity**: High
**Issue**: The earthly skill is not listed in the main INDEX.md catalog
**Fix**: Add entry to INDEX.md with proper category, description, and status.

## Positive Findings

✅ YAML frontmatter valid with name and description
✅ Description has positive AND negative triggers ("Use for... NOT for...")
✅ Body is 455 lines (<500 limit) with dense actionable voice
✅ Examples have clear input/output (Earthfile syntax + CLI commands)
✅ references/RESOURCES.md exists with comprehensive links
✅ scripts/ directory exists with 4 executable helper scripts
✅ All scripts have proper shebang and are executable

## Recommendations

1. Fix the broken Monorepo Patterns section to complete the skill structure
2. Correct the SSH Agent CLI example to show proper SSH flag usage
3. Add skill entry to INDEX.md for discoverability
4. Consider adding a brief "Troubleshooting" section for common Earthly issues

## Verdict

**PASS with fixes required**. Score is 4.0/5 - skill is functional and useful but needs structural fixes before being marked as fully tested.
