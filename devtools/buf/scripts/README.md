# Buf Scripts

Helper scripts for common Buf workflows.

## Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `buf-check.sh` | Comprehensive lint, format, build, and breaking change checks | `./buf-check.sh [branch\|tag\|commit]` |
| `buf-init.sh` | Initialize a new Buf project with configs and example proto | `./buf-init.sh [module-name] [output-dir]` |
| `buf-generate-all.sh` | Generate code for multiple languages using remote BSR plugins | `./buf-generate-all.sh [output-dir]` |
| `buf-ci-check.sh` | CI-friendly checks with JSON output | `./buf-ci-check.sh [against-ref]` |
| `buf-ls-breaking.sh` | List breaking changes between two git refs | `./buf-ls-breaking.sh <from-ref> [to-ref]` |

## Installation

Make scripts executable:

```bash
chmod +x *.sh
```

## Examples

### Quick Project Check

```bash
./buf-check.sh
```

### Initialize New Project

```bash
./buf-init.sh myapi
```

### Generate All Languages

```bash
./buf-generate-all.sh gen
```

### CI JSON Output

```bash
./buf-ci-check.sh .git#branch=main
```

### Compare Breaking Changes

```bash
./buf-ls-breaking.sh v1.0.0 HEAD
```
