#!/usr/bin/env python3
"""Validate a JSON or YAML config file against a Pydantic model.

Usage:
    pydantic-validate-config.py <config_file> <module> <ModelName>
    pydantic-validate-config.py config.json app.models AppConfig
    pydantic-validate-config.py config.yaml app.settings Settings

Exit codes:
    0 — valid
    1 — validation failed
    2 — usage or import error
"""

import argparse
import importlib
import json
import sys
from pathlib import Path


def load_config(filepath: str) -> dict:
    """Load configuration from JSON or YAML file."""
    path = Path(filepath)
    if not path.exists():
        print(f"Error: Config file '{filepath}' not found.", file=sys.stderr)
        sys.exit(2)

    content = path.read_text(encoding="utf-8")
    suffix = path.suffix.lower()

    if suffix in (".yaml", ".yml"):
        try:
            import yaml
        except ImportError:
            print(
                "Error: PyYAML is required for YAML files. "
                "Install with: pip install pyyaml",
                file=sys.stderr,
            )
            sys.exit(2)
        data = yaml.safe_load(content)
    elif suffix == ".json":
        data = json.loads(content)
    elif suffix == ".toml":
        try:
            import tomllib
        except ImportError:
            try:
                import tomli as tomllib
            except ImportError:
                print(
                    "Error: tomli is required for TOML on Python < 3.11. "
                    "Install with: pip install tomli",
                    file=sys.stderr,
                )
                sys.exit(2)
        data = tomllib.loads(content)
    else:
        # Try JSON first, then YAML
        try:
            data = json.loads(content)
        except json.JSONDecodeError:
            try:
                import yaml
                data = yaml.safe_load(content)
            except Exception:
                print(
                    f"Error: Cannot determine format of '{filepath}'. "
                    "Use .json, .yaml, .yml, or .toml extension.",
                    file=sys.stderr,
                )
                sys.exit(2)

    if not isinstance(data, dict):
        print(
            f"Error: Config file must contain a mapping/object, got {type(data).__name__}.",
            file=sys.stderr,
        )
        sys.exit(2)

    return data


def load_model(module_path: str, model_name: str):
    """Import the Pydantic model class from a module."""
    # Convert file path to module path
    if module_path.endswith(".py"):
        module_path = module_path[:-3].replace("/", ".").replace("\\", ".")

    try:
        mod = importlib.import_module(module_path)
    except ModuleNotFoundError as e:
        print(f"Error: Cannot import module '{module_path}': {e}", file=sys.stderr)
        sys.exit(2)

    model_cls = getattr(mod, model_name, None)
    if model_cls is None:
        available = [n for n in dir(mod) if not n.startswith("_")]
        print(f"Error: '{model_name}' not found in '{module_path}'.", file=sys.stderr)
        print(f"Available: {', '.join(available)}", file=sys.stderr)
        sys.exit(2)

    if not hasattr(model_cls, "model_validate"):
        print(
            f"Error: '{model_name}' does not appear to be a Pydantic model.",
            file=sys.stderr,
        )
        sys.exit(2)

    return model_cls


def format_errors(exc) -> str:
    """Format ValidationError into human-readable output."""
    lines = []
    for err in exc.errors():
        loc = " → ".join(str(part) for part in err["loc"]) or "(root)"
        lines.append(f"  ✗ {loc}: {err['msg']} [type={err['type']}]")
        if "input" in err and err["input"] is not None:
            input_repr = repr(err["input"])
            if len(input_repr) > 80:
                input_repr = input_repr[:77] + "..."
            lines.append(f"    input: {input_repr}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Validate a JSON/YAML config file against a Pydantic model."
    )
    parser.add_argument("config_file", help="Path to config file (JSON, YAML, or TOML)")
    parser.add_argument("module", help="Python module path (e.g., app.models)")
    parser.add_argument("model", help="Pydantic model class name")
    parser.add_argument(
        "--strict", action="store_true", help="Enable strict validation mode"
    )
    parser.add_argument(
        "--quiet", "-q", action="store_true", help="Only output errors"
    )

    args = parser.parse_args()

    data = load_config(args.config_file)
    model_cls = load_model(args.module, args.model)

    try:
        from pydantic import ValidationError
    except ImportError:
        print("Error: pydantic is not installed.", file=sys.stderr)
        sys.exit(2)

    try:
        if args.strict:
            instance = model_cls.model_validate(data, strict=True)
        else:
            instance = model_cls.model_validate(data)
    except ValidationError as e:
        print(f"Validation FAILED ({e.error_count()} error(s)):\n", file=sys.stderr)
        print(format_errors(e), file=sys.stderr)
        sys.exit(1)

    if not args.quiet:
        print(f"✓ Config is valid against {args.model}.")
        print(f"  Fields: {len(instance.model_fields)}")
        dumped = instance.model_dump()
        set_fields = {k for k, v in dumped.items() if v is not None}
        print(f"  Set: {len(set_fields)}/{len(instance.model_fields)}")

    sys.exit(0)


if __name__ == "__main__":
    main()
