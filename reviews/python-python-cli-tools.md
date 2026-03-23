# Review: python-cli-tools
Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5
Issues: Non-standard description format.

Excellent Python CLI tools guide. Covers CLI design principles (POSIX conventions, exit codes, TTY detection, subcommands), argparse (subparsers, FileType, mutually exclusive groups, custom Action), Click (decorators, groups, commands, click.Path, click.Choice, click.IntRange, count=True verbosity, pass_context), Typer (Annotated type hints, Enum choices, rich_markup_mode, callbacks, subcommand groups with add_typer), Rich integration (Console to stderr, Table, Progress/track, Panel, Tree, Syntax, Live), I/O patterns (stdin/stdout handling, click.File, click.confirm, non-interactive detection), configuration (XDG Base Directory, tomllib, layered config, Click envvar), error handling (ClickException, typer.Exit, signal handling, exit code 130), testing (CliRunner, isolated_filesystem, TyperRunner, snapshot testing, subprocess integration), async CLIs (asyncio.run with Click, httpx, Progress), distribution (pyproject.toml entry points, shiv, zipapp, PyInstaller, pipx), shell completion (Click bash/zsh/fish, Typer --install-completion, custom completions), logging (verbosity mapping -v/-vv/-vvv), and anti-patterns.
