---
name: goreleaser
description: |
  Go binary release automation. Use for automated Go releases.
  NOT for multi-language release pipelines.
tested: true
---

# GoReleaser

## Quick Start

```bash
# Install
go install github.com/goreleaser/goreleaser/v2@latest

# Initialize config
goreleaser init

# Dry run (local build, no release)
goreleaser release --snapshot --clean

# Full release (requires GITHUB_TOKEN)
goreleaser release --clean
```

## Core Config (.goreleaser.yaml)

```yaml
version: 2

project_name: myapp

before:
  hooks:
    - go mod tidy
    - go generate ./...

builds:
  - id: myapp
    main: ./cmd/myapp
    binary: myapp
    env:
      - CGO_ENABLED=0
    goos:
      - linux
      - darwin
      - windows
    goarch:
      - amd64
      - arm64
    ldflags:
      - -s -w
      - -X main.version={{.Version}}
      - -X main.commit={{.Commit}}
      - -X main.date={{.Date}}

archives:
  - format: tar.gz
    name_template: >-
      {{ .ProjectName }}_
      {{- .Version }}_
      {{- .Os }}_
      {{- .Arch }}
    format_overrides:
      - goos: windows
        format: zip
    files:
      - README.md
      - LICENSE
      - completions/*
      - manpages/*

checksum:
  name_template: 'checksums.txt'
  algorithm: sha256

changelog:
  sort: asc
  filters:
    exclude:
      - '^docs:'
      - '^test:'
      - '^chore:'
      - Merge pull request
      - Merge branch
```

## Build Targets

### Multi-Platform Matrix

```yaml
builds:
  - id: cli
    main: ./cmd/cli
    binary: mycli
    env:
      - CGO_ENABLED=0
    goos:
      - linux
      - darwin
      - windows
      - freebsd
    goarch:
      - amd64
      - arm64
      - arm
    goarm:
      - 6
      - 7
    ignore:
      - goos: darwin
        goarch: arm
      - goos: windows
        goarch: arm64
```

### Conditional Builds

```yaml
builds:
  - id: server
    main: ./cmd/server
    binary: server
    env:
      - CGO_ENABLED=0
    goos: [linux]
    goarch: [amd64]
    # Only build on tags
    skip: '{{ not .IsRegularRelease }}'
```

### CGO Builds (with Docker)

```yaml
builds:
  - id: cgo-app
    main: ./cmd/app
    binary: app
    env:
      - CGO_ENABLED=1
      - CC=x86_64-linux-gnu-gcc
    goos: [linux]
    goarch: [amd64]
    # Use prebuilt Docker image with cross-compilers
    dockerfile: Dockerfile.build
```

## Archives & Packaging

### Archive Templates

```yaml
archives:
  - id: default
    format: tar.gz
    # Dynamic naming
    name_template: >-
      {{ .ProjectName }}_
      {{- .Version }}_
      {{- .Os }}_
      {{- .Arch }}
      {{- if .Arm }}v{{ .Arm }}{{ end }}
    
    # Wrap in directory
    wrap_in_directory: true
    
    # Strip binary paths
    strip_binary_directory: true
    
    # Additional files
    files:
      - src: README.md
        dst: .
        strip_parent: true
      - src: LICENSE
        dst: .
      - src: completions/*
        dst: completions/
      - src: docs/man/*.1
        dst: man/
      - src: config/*.yaml
        dst: config/
        info:
          owner: root
          group: root
          mode: 0644
```

### Multiple Archive Formats

```yaml
archives:
  - id: tarballs
    builds: [linux, darwin]
    format: tar.gz
  
  - id: zips
    builds: [windows]
    format: zip
    # Windows-specific files
    files:
      - src: scripts/install.ps1
        dst: install.ps1
```

## Checksum & Signing

### Checksum Generation

```yaml
checksum:
  name_template: '{{ .ProjectName }}_{{ .Version }}_checksums.txt'
  algorithm: sha256
  # Split by artifact set
  split: true
  # Extra files to checksum
  extra_files:
    - glob: ./dist/*.sbom.json
```

### GPG Signing

```yaml
signs:
  - artifacts: checksum
    cmd: gpg
    args:
      - --batch
      - --yes
      - --output
      - $signature
      - --detach-sign
      - $artifact
    signature: '${artifact}.sig'
```

### Cosign (Keyless)

```yaml
signs:
  - cmd: cosign
    env:
      - COSIGN_EXPERIMENTAL=1
    certificate: '${artifact}.pem'
    args:
      - sign-blob
      - --output-certificate=${certificate}
      - --output-signature=${signature}
      - ${artifact}
    artifacts: all
```

## Docker Images

### Basic Docker Build

```yaml
dockers:
  - image_templates:
      - 'ghcr.io/user/{{ .ProjectName }}:{{ .Tag }}'
      - 'ghcr.io/user/{{ .ProjectName }}:latest'
    dockerfile: Dockerfile
    build_flag_templates:
      - --pull
      - --label=org.opencontainers.image.created={{.Date}}
      - --label=org.opencontainers.image.title={{.ProjectName}}
      - --label=org.opencontainers.image.revision={{.FullCommit}}
      - --label=org.opencontainers.image.version={{.Version}}
    extra_files:
      - config.yaml
```

## Homebrew Tap

### Basic Formula

```yaml
brews:
  - name: myapp
    repository:
      owner: myuser
      name: homebrew-tap
    homepage: 'https://github.com/myuser/myapp'
    description: 'My CLI tool'
    install: bin.install "myapp"
```

## GitHub Releases

### Basic Release

```yaml
release:
  github:
    owner: myuser
    name: myrepo
  
  # Draft release first
  draft: true
  
  # Generate release notes from commits
  mode: keep-existing
  
  # Header/footer templates
  header: |
    ## Installation
    
    ```bash
    # macOS/Linux
    curl -sSL https://get.myapp.dev | bash
    ```
  
  footer: |
    ## Changelog
    
    See [CHANGELOG.md](https://github.com/myuser/myrepo/blob/main/CHANGELOG.md)
  
  # Extra files
  extra_files:
    - glob: ./dist/install.sh
    - glob: ./docs/*.md
```

### Release Notes Generation

```yaml
changelog:
  use: github
  groups:
    - title: Features
      regexp: '^.*feat[(\w)]*:+.*$'
      order: 0
    - title: 'Bug fixes'
      regexp: '^.*fix[(\w)]*:+.*$'
      order: 1
    - title: 'Documentation'
      regexp: '^.*docs[(\w)]*:+.*$'
      order: 2
    - title: Other
      order: 999
  filters:
    exclude:
      - '^test:'
      - '^chore:'
      - Merge pull request
      - Merge branch
```

## GitLab Releases

```yaml
release:
  gitlab:
    owner: mygroup
    name: myproject
  
  # GitLab-specific options
  draft: false
  prerelease: auto
  
  # Use GitLab release notes
  mode: keep-existing
```

## Snapcraft

```yaml
snapcrafts:
  - name: myapp
    summary: 'My awesome app'
    description: 'Longer description here'
    grade: stable
    confinement: strict
    license: MIT
    
    # Base snap
    base: core22
    
    # Apps exposed
    apps:
      myapp:
        command: myapp
        plugs: [home, network, removable-media]
    
    # Additional files
    extra_files:
      - source: README.md
        destination: README.md
        mode: 0644
```

## Nix

```yaml
nix:
  - repository:
      owner: myuser
      name: nur-packages
    path: pkgs/myapp
    commit_author:
      name: goreleaserbot
      email: bot@goreleaser.com
    commit_msg_template: 'myapp: {{ .Tag }}'
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `GITHUB_TOKEN` | GitHub API access |
| `GITLAB_TOKEN` | GitLab API access |
| `GORELEASER_KEY` | GoReleaser Pro license |
| `DOCKER_USERNAME` | Docker Hub login |
| `DOCKER_PASSWORD` | Docker Hub password |
| `HOMEBREW_TAP_GITHUB_TOKEN` | Separate token for tap repo |
| `COSIGN_PASSWORD` | Cosign key password |
| `GPG_FINGERPRINT` | GPG key ID |

## CI/CD Integration

### GitHub Actions

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write
  packages: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      
      - uses: actions/setup-go@v5
        with:
          go-version: stable
      
      - uses: goreleaser/goreleaser-action@v6
        with:
          distribution: goreleaser
          version: '~> v2'
          args: release --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Best Practices

### Version Injection

```go
var version = "dev"

func main() {
    fmt.Println(version)
}
```

### Validate Config

```bash
goreleaser check
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `git is in a dirty state` | Add files to `.gitignore` or commit changes |
| `GITHUB_TOKEN not found` | Set env var or use `--skip=publish` |
| `no linux builds found` | Check `goos`/`goarch` matrix |
| `docker: not found` | Install Docker or skip with `--skip=docker` |
| `gpg: signing failed` | Ensure GPG key is imported and unlocked |

## Migration from v1 to v2

```yaml
# Add version header
version: 2

# Replace deprecated options
# archives.replacements → name_template
# builds.ldflags template vars → use {{.Version}} etc directly
```
