# OXC Skill

**Status**: enriched

**Path**: [SKILL.md](SKILL.md)

## Description

High-performance JS/TS linter written in Rust. Use for fast linting of large codebases. NOT for projects requiring full ESLint compatibility or custom rules.

## Contents

- **SKILL.md** - Main skill documentation with usage patterns, configuration, and best practices
- **references/** - Official documentation links and GitHub repositories
- **scripts/** - Helper scripts for common OXC operations

## Quick Reference

| Task | Command |
|------|---------|
| Lint | `npx oxlint .` |
| Fix | `npx oxlint --fix` |
| CI Mode | `npx oxlint --max-warnings 0` |
| List Rules | `npx oxlint --rules` |

## Resources

- Website: https://oxc.rs/
- GitHub: https://github.com/oxc-project/oxc
- VS Code Extension: `oxc.oxc-vscode`
