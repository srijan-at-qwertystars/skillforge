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

## License

MIT
