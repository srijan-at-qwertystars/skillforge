# SkillForge 🛠️

**An auto-generated library of Claude Code skills for working engineers.**

## What is this?

SkillForge is a curated, auto-generated collection of Claude Code skills — installable knowledge packs that make Claude an expert in specific tools, frameworks, protocols, and engineering patterns.

Each skill is a self-contained folder with a `SKILL.md` that Claude Code can load to gain deep expertise on a topic.

## How to use

### Install a single skill

Copy the skill folder into your Claude Code skills directory:

```bash
# Personal (available everywhere)
cp -r <category>/<skill-name> ~/.claude/skills/

# Project-specific (version-controlled)
cp -r <category>/<skill-name> .claude/skills/
```

### Browse available skills

See [INDEX.md](INDEX.md) for the full catalog with categories and descriptions.

## Skill structure

Each skill follows the standard Claude Code skill format:

```
skill-name/
├── SKILL.md          # Main skill file (YAML frontmatter + instructions)
├── scripts/          # Optional helper scripts
└── references/       # Optional additional documentation
```

## Contributing

This repository is auto-generated. Skills are created by an autonomous pipeline that researches topics, writes comprehensive instructions, and packages them as Claude Code skills.

## Anthropic API Equivalent Cost

| Model | Base Input Cost<br>*(Total In - Cached)* | Output Cost | Cache Read Cost<br>*(90% off base)* | Total Equivalent |
| :--- | :--- | :--- | :--- | :--- |
| **Opus 4.6 (fast mode)**<br>*(44.0m base, 12.5m out, 471.7m cached)* | **$1,320.00**<br>*($30.00 / 1M)* | **$1,875.00**<br>*($150.00 / 1M)* | **$1,415.10**<br>*($3.00 / 1M)* | **$4,610.10** |
| **claude-haiku-4.5**<br>*(226.3k base, 44.1k out, 683.3k cached)* | **$0.23**<br>*($1.00 / 1M)* | **$0.22**<br>*($5.00 / 1M)* | **$0.07**<br>*($0.10 / 1M)* | **$0.52** |

**Total Equivalent Cost:** $4,610.62

## License

MIT
