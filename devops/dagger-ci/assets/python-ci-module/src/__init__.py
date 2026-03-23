"""
Complete CI pipeline for Python projects using Dagger.

Functions:
    - build:   Install dependencies and build the Python package
    - test:    Run pytest with coverage
    - lint:    Run ruff linter and formatter check
    - publish: Build and push a container image to a registry
    - ci:      Orchestrate the full pipeline (test → lint → build → publish)

Usage:
    dagger call build --source=.
    dagger call test --source=.
    dagger call lint --source=.
    dagger call ci --source=. --registry=ghcr.io/org/app --tag=latest --password=env:GHCR_TOKEN
"""

import dagger
from dagger import dag, function, object_type


@object_type
class PythonCi:
    @function
    def build(self, source: dagger.Directory) -> dagger.Container:
        """Install dependencies and prepare the application container."""
        return (
            self._base_env(source)
            .with_exec(["pip", "install", "-r", "requirements.txt"])
            .with_exec(["python", "-m", "build"])
        )

    @function
    async def test(self, source: dagger.Directory) -> str:
        """Run the test suite with pytest and coverage."""
        return await (
            self._base_env(source)
            .with_exec(["pip", "install", "-r", "requirements.txt"])
            .with_exec(
                [
                    "pytest",
                    "-v",
                    "--tb=short",
                    "--cov=.",
                    "--cov-report=term-missing",
                ]
            )
            .stdout()
        )

    @function
    async def lint(self, source: dagger.Directory) -> str:
        """Run ruff linter and formatter check."""
        return await (
            dag.container()
            .from_("python:3.12-slim")
            .with_exec(["pip", "install", "ruff"])
            .with_directory("/app", source)
            .with_workdir("/app")
            .with_exec(["ruff", "check", "."])
            .with_exec(["ruff", "format", "--check", "."])
            .stdout()
        )

    @function
    async def publish(
        self,
        source: dagger.Directory,
        registry: str,
        tag: str,
        username: str,
        password: dagger.Secret,
    ) -> str:
        """Build a container image and push to a registry."""
        app = (
            dag.container()
            .from_("python:3.12-slim")
            .with_workdir("/app")
            .with_file("/app/requirements.txt", source.file("requirements.txt"))
            .with_mounted_cache("/root/.cache/pip", dag.cache_volume("pip"))
            .with_exec(["pip", "install", "--no-cache-dir", "-r", "requirements.txt"])
            .with_directory("/app", source)
            .with_exposed_port(8000)
            .with_entrypoint(["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0"])
        )

        return await (
            app.with_registry_auth(registry, username, password).publish(
                f"{registry}/app:{tag}"
            )
        )

    @function
    async def ci(
        self,
        source: dagger.Directory,
        registry: str = "",
        tag: str = "latest",
        username: str = "",
        password: dagger.Secret | None = None,
        skip_publish: bool = False,
    ) -> str:
        """Run the full CI pipeline: test, lint, build, and optionally publish."""
        # Run tests
        test_output = await self.test(source)

        # Run lint
        await self.lint(source)

        # Build
        self.build(source)

        if skip_publish or password is None:
            return f"✅ All checks passed\n\nTest output:\n{test_output}"

        # Publish
        ref = await self.publish(source, registry, tag, username, password)
        return f"✅ Published: {ref}"

    def _base_env(self, source: dagger.Directory) -> dagger.Container:
        """Create a base Python container with caching configured."""
        return (
            dag.container()
            .from_("python:3.12-slim")
            .with_workdir("/app")
            .with_mounted_cache("/root/.cache/pip", dag.cache_volume("pip"))
            .with_directory("/app", source)
        )
