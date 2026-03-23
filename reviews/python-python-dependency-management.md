# Review: python-dependency-management

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.75/5

Issues: Line 422 lists `uv pip audit` as a security scanning command, but this command does not exist in uv. The correct approach is to use `pip-audit` (a separate tool by Google/PyPA). Minor inaccuracy in an otherwise excellent guide.

Comprehensive Python dependency management guide with standard description format. Covers modern packaging landscape (PEP 518/517/621), uv (installation, core commands, pip compat, venv/Python management, tool runner uvx, performance), pip + pip-tools (pip-compile/pip-sync, hashes, constraints), Poetry (workflow, dependency groups, publishing, poetry.lock), Hatch (environments, matrix testing, version, scripts), PDM (PEP 621, PEP 582), virtual environments, pyproject.toml reference, dependency specification (PEP 440/508, extras, markers, direct refs), lockfiles (comparison table: uv/Poetry/pip-tools/PDM), dependency resolution (conflict resolution, version bounds strategy, upper bound controversy), CI/CD patterns (caching, lockfile verification, security scanning), monorepo patterns (uv workspaces, path deps, editable installs), tool comparison table, and 10 anti-patterns.
