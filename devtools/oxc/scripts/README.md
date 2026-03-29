# OXC Helper Scripts

This directory contains helper scripts for working with OXC.

## Available Scripts

### `oxc-quick.sh`
Quick lint with auto-fix enabled.
```bash
./oxc-quick.sh [path]
```

### `oxc-changed.sh`
Lint only files changed in git (staged and unstaged).
```bash
./oxc-changed.sh
```

### `oxc-init.sh`
Initialize OXC in a new project (creates config + installs package).
```bash
./oxc-init.sh
```

### `oxc-ci.sh`
CI mode - fails on any warning.
```bash
./oxc-ci.sh [path]
```

## Usage

Make scripts executable:
```bash
chmod +x scripts/*.sh
```

Or run with bash:
```bash
bash scripts/oxc-init.sh
```
