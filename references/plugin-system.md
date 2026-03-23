# Claude Code Skill/Plugin System — Reference

## Folder Anatomy

A Claude Code skill is a **folder** with at minimum a `SKILL.md` file:

```
skill-name/
├── SKILL.md          # REQUIRED — entry point (case-sensitive)
├── scripts/          # Optional — executable helpers for deterministic tasks
├── references/       # Optional — extra docs loaded on demand
└── assets/           # Optional — templates, images, etc.
```

- Folder names: **kebab-case** only (e.g., `review-database`, not `ReviewDatabase`).
- Only `SKILL.md` (not `skill.md`, `README.md`) is recognized as the entry point.

## Placement Locations

| Scope       | Path                          | Notes                            |
|-------------|-------------------------------|----------------------------------|
| Personal    | `~/.claude/skills/<name>/`    | Available in every project       |
| Project     | `.claude/skills/<name>/`      | Version-controlled, team-shared  |

## YAML Frontmatter Fields

The `SKILL.md` must start with YAML frontmatter between `---` fences:

```yaml
---
name: my-skill-name          # Required. Kebab-case, must match folder name.
description: |               # Required. ≤1024 chars. Determines auto-triggering.
  What it does + WHEN to trigger + when NOT to trigger.
version: 1.0.0               # Optional. SemVer.
author: Your Name             # Optional.
invoke: both                  # Optional. "both" | "auto" | "manual"
---
```

### Required Fields
- **name**: Kebab-case identifier. Must match the folder name.
- **description**: The most critical field. Determines whether Claude loads the skill. Must specify:
  - What the skill does
  - Positive triggers (when TO use it)
  - Negative triggers (when NOT to use it)
  - Keywords, abbreviations, common dev slang

## Progressive Disclosure (3-Stage Loading)

1. **Metadata (always loaded)**: `name` and `description` from frontmatter — read every time Claude evaluates which skills to activate.
2. **SKILL.md body (loaded on match)**: Full instructions, loaded only if metadata matches user intent.
3. **Resources (on demand)**: Scripts, references, assets — loaded only when the skill explicitly requests them.

This keeps context usage efficient — only relevant content is loaded.

## Triggering Rules

- Claude reads all skill `description` fields at context setup time.
- If user intent matches a skill's description, Claude loads the full SKILL.md body.
- **Auto-trigger**: Claude runs the skill automatically when context matches.
- **Manual invoke**: User types `/skill-name` to invoke directly.
- **Both**: Skill can be triggered either way (default).

### Description Optimization Tips
- Use action-oriented, situation-specific language.
- List keyword variants and natural phrases.
- Include abbreviations and common developer slang.
- Specify both positive AND negative triggers.
- Keep it "pushy" — specific enough to trigger reliably but not so broad it misfires.

**Good example:**
```yaml
description: |
  Analyzes Dockerfile and docker-compose.yml for security issues, 
  performance problems, and best practice violations. Use when user 
  asks about Docker security, container hardening, or image optimization.
  Do NOT use for general Docker tutorials or basic docker run commands.
```

**Bad example:**
```yaml
description: Helps with Docker stuff.
```

## SKILL.md Body Best Practices

- Dense, actionable, imperative voice. No filler.
- Any AI reading it should be able to execute perfectly.
- Under 500 lines. If approaching limit, split into `references/` with clear pointers.
- Explain the "why" behind instructions, not just rigid rules.
- Include examples with input/output pairs where applicable.
- Use checklists and step-by-step guides for workflows.
- Variables available: `$ARGUMENTS`, `$SELECTION`, custom `args:` definitions.

## Installation Methods

1. **Manual**: Copy skill folder to `~/.claude/skills/` or `.claude/skills/`.
2. **Git clone**: Clone a repo of skills into the skills directory.
3. **Plugin marketplace** (if available):
   ```
   /plugin marketplace add owner/repo
   /plugin install skill-name@marketplace-name
   ```

## Plugin Packaging (Multi-Skill)

For distributing multiple skills as a plugin:
```
.claude-plugin/
├── plugin.json         # Manifest
└── skills/
    ├── skill-one/
    │   └── SKILL.md
    └── skill-two/
        └── SKILL.md
```

**plugin.json example:**
```json
{
  "name": "my-plugin",
  "description": "A custom Claude Code plugin.",
  "version": "1.0.0",
  "author": { "name": "Your Name" },
  "skills": "./skills/"
}
```

## Testing and Verification

- Use `claude doctor` to verify skills are loaded.
- Skills appear under "Loaded Skills" when installed correctly.
- Write test prompts to verify trigger rates.
- Benchmark skill vs raw Claude for quality comparison.

## Key Rules for This Repository

1. Every skill lives in `~/skillforge/<category>/<skill-name>/SKILL.md`.
2. Frontmatter always has `name` and `description` (with positive + negative triggers).
3. Body is dense, actionable, <500 lines.
4. If content exceeds limit, use `references/` subfolder.
5. Scripts go in `scripts/` subfolder.
6. INDEX.md tracks all skills with category, name, one-line description.
