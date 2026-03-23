// Package main implements a complete CI pipeline for Go projects using Dagger.
//
// Functions:
//   - Build:   Compile the Go binary with optimizations
//   - Test:    Run the full test suite with race detection and coverage
//   - Lint:    Run golangci-lint static analysis
//   - Publish: Build a minimal container image and push to a registry
//   - CI:      Orchestrate the full pipeline (test → lint → build → publish)
//
// Usage:
//
//	dagger call build --src=.
//	dagger call test --src=.
//	dagger call lint --src=.
//	dagger call ci --src=. --registry=ghcr.io/org/app --tag=latest --password=env:GHCR_TOKEN
package main

import (
	"context"
	"dagger/go-ci/internal/dagger"
	"fmt"

	"golang.org/x/sync/errgroup"
)

type GoCi struct{}

// Build compiles a Go application with static linking and stripped debug symbols.
// Returns the compiled binary as a File.
func (m *GoCi) Build(ctx context.Context, src *dagger.Directory) *dagger.File {
	return m.buildEnv(src).
		WithExec([]string{"go", "build", "-ldflags", "-s -w", "-o", "/out/app", "."}).
		File("/out/app")
}

// Test runs the Go test suite with race detection and coverage reporting.
// Returns the test output.
func (m *GoCi) Test(ctx context.Context, src *dagger.Directory) (string, error) {
	return m.buildEnv(src).
		WithExec([]string{
			"go", "test", "./...",
			"-v",
			"-race",
			"-coverprofile=/tmp/coverage.out",
			"-timeout=10m",
		}).
		Stdout(ctx)
}

// Lint runs golangci-lint against the source code.
// Returns the linter output.
func (m *GoCi) Lint(ctx context.Context, src *dagger.Directory) (string, error) {
	return dag.Container().
		From("golangci/golangci-lint:v1.61-alpine").
		WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
		WithMountedCache("/root/.cache/golangci-lint", dag.CacheVolume("golangci-lint")).
		WithMountedDirectory("/src", src).
		WithWorkdir("/src").
		WithExec([]string{"golangci-lint", "run", "--timeout", "5m"}).
		Stdout(ctx)
}

// Publish builds a minimal container image and pushes it to the specified registry.
// Returns the published image reference (digest).
func (m *GoCi) Publish(
	ctx context.Context,
	src *dagger.Directory,
	registry string,
	tag string,
	username string,
	password *dagger.Secret,
) (string, error) {
	binary := m.Build(ctx, src)

	return dag.Container().
		From("gcr.io/distroless/static-debian12:nonroot").
		WithFile("/usr/local/bin/app", binary).
		WithExposedPort(8080).
		WithEntrypoint([]string{"/usr/local/bin/app"}).
		WithRegistryAuth(registry, username, password).
		Publish(ctx, fmt.Sprintf("%s/%s:%s", registry, "app", tag))
}

// CI runs the full pipeline: test and lint in parallel, then build and publish.
// Pass --skip-publish=true to only run checks without pushing.
func (m *GoCi) CI(
	ctx context.Context,
	src *dagger.Directory,
	// +optional
	registry string,
	// +optional
	tag string,
	// +optional
	username string,
	// +optional
	password *dagger.Secret,
	// +optional
	skipPublish bool,
) (string, error) {
	// Run test and lint concurrently
	g, ctx := errgroup.WithContext(ctx)

	g.Go(func() error {
		_, err := m.Test(ctx, src)
		return err
	})

	g.Go(func() error {
		_, err := m.Lint(ctx, src)
		return err
	})

	if err := g.Wait(); err != nil {
		return "", fmt.Errorf("checks failed: %w", err)
	}

	if skipPublish || password == nil {
		// Build only, return success message
		_ = m.Build(ctx, src)
		return "✅ All checks passed, binary built successfully", nil
	}

	if tag == "" {
		tag = "latest"
	}

	return m.Publish(ctx, src, registry, tag, username, password)
}

// buildEnv returns a Go build container with caching configured.
func (m *GoCi) buildEnv(src *dagger.Directory) *dagger.Container {
	return dag.Container().
		From("golang:1.23-alpine").
		WithEnvVariable("CGO_ENABLED", "0").
		WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
		WithMountedCache("/root/.cache/go-build", dag.CacheVolume("gobuild")).
		WithMountedDirectory("/src", src).
		WithWorkdir("/src")
}
