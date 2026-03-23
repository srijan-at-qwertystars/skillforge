---
name: python-cli-tools
description:
  positive: "Use when user builds Python CLI tools, asks about Click, Typer, argparse, Rich console output, CLI argument parsing, subcommands, or distributing Python CLI applications."
  negative: "Do NOT use for bash scripting (use bash-scripting-patterns skill), Go CLI tools (cobra), or general Python scripting without CLI framework context."
---

# Python CLI Tools

## CLI Design Principles

Follow POSIX conventions. Use `--long-flags` and `-s` short flags. Return exit code 0 on success, nonzero on failure. Always provide `--help`. Write errors to stderr, data to stdout. Support `--quiet` and `--verbose`. Make output pipeable — avoid color/formatting when stdout is not a TTY.

```python
import sys

def main():
    if sys.stdout.isatty():
        print("\033[1mFormatted output\033[0m")
    else:
        print("Plain output")  # piped to another command
    sys.exit(0)
```

Use subcommands for related operations (`mycli db migrate`, `mycli db rollback`). Keep top-level `--help` concise — show subcommand list, not every flag.

## argparse

Use `argparse` for zero-dependency CLIs or stdlib-only constraints.

```python
import argparse

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mytool", description="Process data files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n  mytool convert input.csv --format json",
    )
    parser.add_argument("--version", action="version", version="%(prog)s 1.0.0")
    sub = parser.add_subparsers(dest="command", required=True)

    convert_p = sub.add_parser("convert", help="Convert file formats")
    convert_p.add_argument("input", type=argparse.FileType("r"), help="Input file")
    convert_p.add_argument("-f", "--format", choices=["json", "yaml", "toml"], default="json")
    convert_p.add_argument("-o", "--output", type=argparse.FileType("w"), default="-")

    validate_p = sub.add_parser("validate", help="Validate against schema")
    validate_p.add_argument("schema", help="Schema file path")
    validate_p.add_argument("files", nargs="+", help="Files to validate")
    group = validate_p.add_mutually_exclusive_group()
    group.add_argument("--strict", action="store_true")
    group.add_argument("--lenient", action="store_true")
    return parser

# Custom action for validation
class ValidatePathAction(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        from pathlib import Path
        p = Path(values)
        if not p.exists():
            parser.error(f"Path does not exist: {values}")
        setattr(namespace, self.dest, p)

if __name__ == "__main__":
    args = build_parser().parse_args()
```

## Click

Use Click for mature CLIs needing decorators, composability, and plugin systems.

```python
import click

@click.group()
@click.version_option("1.0.0")
@click.option("-v", "--verbose", count=True, help="Increase verbosity (-v, -vv, -vvv)")
@click.pass_context
def cli(ctx: click.Context, verbose: int):
    """My CLI tool — process and transform data."""
    ctx.ensure_object(dict)
    ctx.obj["verbose"] = verbose

@cli.command()
@click.argument("src", type=click.Path(exists=True))
@click.argument("dst", type=click.Path())
@click.option("--format", "fmt", type=click.Choice(["json", "yaml", "csv"]), default="json")
@click.option("--dry-run", is_flag=True, help="Preview changes without writing")
@click.pass_context
def convert(ctx: click.Context, src: str, dst: str, fmt: str, dry_run: bool):
    """Convert SRC file to DST in the specified format."""
    if ctx.obj["verbose"] >= 1:
        click.echo(f"Converting {src} -> {dst} ({fmt})")
    if dry_run:
        click.secho("Dry run — no files written", fg="yellow")
        return

@cli.command()
@click.argument("files", nargs=-1, required=True, type=click.Path(exists=True))
@click.option("--workers", type=click.IntRange(1, 32), default=4)
def validate(files: tuple[str, ...], workers: int):
    """Validate one or more data files."""
    for f in files:
        click.echo(f"Validating {f}")
```

## Typer

Use Typer for modern Python CLIs leveraging type hints. Builds on Click internally.

```python
from typing import Annotated, Optional
from enum import Enum
from pathlib import Path
import typer

app = typer.Typer(help="Data processing CLI", rich_markup_mode="rich")

class Format(str, Enum):
    json = "json"
    yaml = "yaml"
    csv = "csv"

@app.command()
def convert(
    src: Annotated[Path, typer.Argument(help="Source file", exists=True)],
    dst: Annotated[Path, typer.Argument(help="Destination file")],
    fmt: Annotated[Format, typer.Option("--format", "-f")] = Format.json,
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Preview only")] = False,
    verbose: Annotated[int, typer.Option("--verbose", "-v", count=True)] = 0,
):
    """Convert [bold]SRC[/bold] to DST in specified format."""
    if verbose:
        typer.echo(f"Converting {src} -> {dst} as {fmt.value}")
    if dry_run:
        typer.echo("Dry run — skipping write")
        raise typer.Exit()
```

### Typer Callbacks and Subcommand Groups

```python
@app.callback()
def main(
    ctx: typer.Context,
    version: Annotated[Optional[bool], typer.Option("--version", is_eager=True)] = None,
):
    """My CLI tool."""
    if version:
        typer.echo("1.0.0")
        raise typer.Exit()

db_app = typer.Typer(help="Database operations")
app.add_typer(db_app, name="db")

@db_app.command()
def migrate(revision: str = "head"):
    """Run database migrations."""
    typer.echo(f"Migrating to {revision}")
```

## Rich Integration

Use Rich for tables, progress bars, trees, and styled output. Send Rich output to stderr to keep stdout clean for data.

```python
from rich.console import Console
from rich.table import Table
from rich.progress import track, Progress
from rich.panel import Panel
from rich.tree import Tree
from rich.syntax import Syntax
from rich.live import Live

console = Console(stderr=True)

def show_results(items: list[dict]):
    table = Table(title="Results", show_lines=True)
    table.add_column("Name", style="cyan")
    table.add_column("Status", style="green")
    table.add_column("Duration", justify="right")
    for item in items:
        table.add_row(item["name"], item["status"], f"{item['ms']}ms")
    console.print(table)

def process_files(paths: list[str]):
    for path in track(paths, description="Processing..."):
        pass  # work here

def download_all(urls: list[str]):
    with Progress(console=console) as progress:
        task = progress.add_task("Downloading", total=len(urls))
        for url in urls:
            progress.advance(task)

def show_config(config: dict):
    tree = Tree("[bold]Configuration[/bold]")
    for key, val in config.items():
        tree.add(f"[cyan]{key}[/cyan] = {val}")
    console.print(Panel(tree, title="Current Config"))

def show_code(code: str, lang: str = "python"):
    console.print(Syntax(code, lang, theme="monokai", line_numbers=True))

def monitor_status():
    with Live(generate_table(), console=console, refresh_per_second=4) as live:
        while True:
            live.update(generate_table())
```

## Input/Output Patterns

```python
import sys, click

@click.command()
@click.argument("input", type=click.File("r"), default="-")
def process(input):
    """Process INPUT file (use - or omit for stdin)."""
    for line in input:
        click.echo(line.strip().upper())

def has_stdin_data() -> bool:
    return not sys.stdin.isatty()

def confirm_action(message: str) -> bool:
    if not sys.stdin.isatty():
        return True  # non-interactive: assume yes
    return click.confirm(message)

@click.command()
@click.option("--password", prompt=True, hide_input=True, confirmation_prompt=True)
def login(password: str):
    click.echo("Authenticated")
```

## Configuration

Follow XDG Base Directory spec. Layer: defaults → config file → env vars → CLI flags.

```python
from pathlib import Path
import os, tomllib

def get_config_dir() -> Path:
    xdg = os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")
    return Path(xdg) / "mytool"

def load_config() -> dict:
    defaults = {"format": "json", "verbose": False, "workers": 4}
    config_file = get_config_dir() / "config.toml"
    if config_file.exists():
        with open(config_file, "rb") as f:
            defaults.update(tomllib.load(f))
    if env_fmt := os.environ.get("MYTOOL_FORMAT"):
        defaults["format"] = env_fmt
    return defaults
```

Click reads env vars directly with `envvar`:

```python
@click.command()
@click.option("--format", envvar="MYTOOL_FORMAT", default="json", show_envvar=True)
@click.option("--workers", envvar="MYTOOL_WORKERS", type=int, default=4)
def run(format: str, workers: int):
    pass
```

## Error Handling

Write errors to stderr. Provide actionable messages. Never print raw tracebacks to end users.

```python
import click, sys
from pathlib import Path

@click.command()
@click.argument("path", type=click.Path())
def process(path: str):
    if not Path(path).exists():
        raise click.ClickException(f"File not found: {path}")
    try:
        data = expensive_parse(path)
    except ValueError as e:
        raise click.ClickException(f"Invalid data in {path}: {e}")

# Typer error helper
import typer

def fail(msg: str, code: int = 1) -> None:
    typer.echo(f"Error: {msg}", err=True)
    raise typer.Exit(code)

# Graceful Ctrl+C
@click.command()
def long_task():
    try:
        for i in range(1000):
            do_work(i)
    except KeyboardInterrupt:
        click.echo("\nAborted.", err=True)
        sys.exit(130)  # 128 + SIGINT(2)
```

## Testing CLI Tools

### Click and Typer CliRunner

```python
from click.testing import CliRunner

def test_convert():
    runner = CliRunner()
    with runner.isolated_filesystem():
        with open("input.csv", "w") as f:
            f.write("a,b\n1,2\n")
        result = runner.invoke(cli, ["convert", "input.csv", "out.json"])
        assert result.exit_code == 0

def test_error_handling():
    runner = CliRunner()
    result = runner.invoke(cli, ["convert", "nonexistent.csv", "out.json"])
    assert result.exit_code != 0

def test_stdin_input():
    runner = CliRunner()
    result = runner.invoke(process, input="line1\nline2\n")
    assert "LINE1" in result.output

# Typer uses the same pattern
from typer.testing import CliRunner as TyperRunner

def test_typer_app():
    runner = TyperRunner()
    result = runner.invoke(app, ["convert", "data.csv", "out.json", "--format", "json"])
    assert result.exit_code == 0
```

### Snapshot and Integration Testing

```python
def test_help_output(snapshot):
    result = CliRunner().invoke(cli, ["--help"])
    assert result.output == snapshot

import subprocess

def test_cli_integration():
    result = subprocess.run(
        ["python", "-m", "mytool", "convert", "test.csv", "--format", "json"],
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0
```

## Async CLIs

```python
import asyncio, click
from rich.progress import Progress

@click.command()
@click.argument("urls", nargs=-1)
def fetch(urls: tuple[str, ...]):
    """Fetch URLs concurrently."""
    asyncio.run(_fetch_all(urls))

async def _fetch_all(urls: tuple[str, ...]):
    import httpx
    async with httpx.AsyncClient() as client:
        tasks = [client.get(url) for url in urls]
        results = await asyncio.gather(*tasks, return_exceptions=True)
        for url, r in zip(urls, results):
            if isinstance(r, Exception):
                click.echo(f"FAIL {url}: {r}", err=True)
            else:
                click.echo(f"OK   {url} [{r.status_code}]")

async def fetch_with_progress(urls: list[str]):
    import httpx
    with Progress() as progress:
        task = progress.add_task("Fetching", total=len(urls))
        async with httpx.AsyncClient() as client:
            for url in urls:
                await client.get(url)
                progress.advance(task)
```

## Distribution

### pyproject.toml Entry Points

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "mytool"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["click>=8.1", "rich>=13.0"]

[project.scripts]
mytool = "mytool.cli:cli"

[project.optional-dependencies]
dev = ["pytest"]
```

### Packaging and Distribution

```bash
# shiv: self-contained executable
shiv -c mytool -o mytool.pyz mytool

# zipapp: stdlib only, no deps
python -m zipapp mypackage -p "/usr/bin/env python3" -o mytool.pyz

# PyInstaller: standalone binary
pyinstaller --onefile --name mytool src/mytool/cli.py

# pipx: recommend for user installs (isolated envs)
pipx install mytool
```

## Shell Completion

```bash
# Click: generate completion scripts
eval "$(_MYTOOL_COMPLETE=bash_source mytool)"   # bash
eval "$(_MYTOOL_COMPLETE=zsh_source mytool)"    # zsh
_MYTOOL_COMPLETE=fish_source mytool | source    # fish

# Typer: built-in completion management
mytool --install-completion
mytool --show-completion
```

Custom completions in Typer:

```python
def complete_formats(incomplete: str) -> list[str]:
    return [f for f in ["json", "yaml", "csv", "toml"] if f.startswith(incomplete)]

@app.command()
def convert(
    fmt: Annotated[str, typer.Option(autocompletion=complete_formats)] = "json",
):
    pass
```

## Logging and Verbosity

Map `-v` count to log levels. Use `logging` for structured output, stderr for logs.

```python
import logging, click

def configure_logging(verbosity: int) -> None:
    levels = {0: logging.WARNING, 1: logging.INFO, 2: logging.DEBUG}
    logging.basicConfig(
        level=levels.get(verbosity, logging.DEBUG),
        format="%(levelname)s %(name)s: %(message)s",
        stream=__import__("sys").stderr,
    )

@click.command()
@click.option("-v", "--verbose", count=True, help="-v info, -vv debug")
@click.option("-q", "--quiet", is_flag=True, help="Suppress all output")
def cli(verbose: int, quiet: bool):
    configure_logging(-1 if quiet else verbose)
    logger = logging.getLogger("mytool")
    logger.info("Starting processing")
    logger.debug("Debug details: config=%s", config)
```

## Anti-Patterns

Avoid these mistakes:

- **Wall of text**: Use `click.echo_via_pager()` for long output. Limit default output.
- **Missing `--help`**: Every command and subcommand must have help text via docstrings.
- **No exit codes**: Always `sys.exit(1)` on failure. Never silently succeed on error.
- **Hard-coded paths**: Use `Path.home()`, `XDG_CONFIG_HOME`, `click.get_app_dir()`.
- **Color without detection**: Use `click.style()` which respects `NO_COLOR` env var.
- **Swallowing exceptions**: Log errors to stderr, exit nonzero. Never `except: pass`.
- **Mixing data and status**: Machine-readable data to stdout, human messages to stderr.
- **No `--version`**: Use `click.version_option()` or `typer.Option(is_eager=True)`.
- **Ignoring signals**: Handle `SIGINT`/`SIGTERM` for cleanup. Exit code 130 for Ctrl+C.
- **Requiring interactivity**: Accept all input via flags; prompts as fallback only.

<!-- tested: pass -->
