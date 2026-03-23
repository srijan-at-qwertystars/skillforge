# Mise Troubleshooting Reference

<!-- TOC -->
- [Shell Activation Issues](#shell-activation-issues)
  - [Mise Commands Work but Tools Don't Activate](#mise-commands-work-but-tools-dont-activate)
  - [Shell Not Recognized](#shell-not-recognized)
  - [Activation in Non-Interactive Shells](#activation-in-non-interactive-shells)
  - [IDE / Editor Integration](#ide--editor-integration)
- [PATH Conflicts](#path-conflicts)
  - [Wrong Tool Version Active](#wrong-tool-version-active)
  - [System Tools Override Mise](#system-tools-override-mise)
  - [PATH Order Debugging](#path-order-debugging)
  - [Shims vs PATH Entry](#shims-vs-path-entry)
- [Tool Installation Failures](#tool-installation-failures)
  - [Common Build Errors](#common-build-errors)
  - [Python Installation Issues](#python-installation-issues)
  - [Node.js Installation Issues](#nodejs-installation-issues)
  - [Ruby Installation Issues](#ruby-installation-issues)
  - [Network / Download Errors](#network--download-errors)
- [Backend Errors](#backend-errors)
  - [Aqua Backend Failures](#aqua-backend-failures)
  - [Cargo Backend Failures](#cargo-backend-failures)
  - [Pipx Backend Failures](#pipx-backend-failures)
  - [GitHub Backend Failures](#github-backend-failures)
  - [Disabling Problematic Backends](#disabling-problematic-backends)
- [Legacy File Conflicts](#legacy-file-conflicts)
  - [Multiple Version Files](#multiple-version-files)
  - [.tool-versions Conflicts](#tool-versions-conflicts)
  - [Disabling Legacy File Support](#disabling-legacy-file-support)
- [Slow Shell Startup](#slow-shell-startup)
  - [Diagnosing Slow Activation](#diagnosing-slow-activation)
  - [Optimization Strategies](#optimization-strategies)
  - [Measuring Startup Time](#measuring-startup-time)
- [mise doctor Output Interpretation](#mise-doctor-output-interpretation)
  - [Running mise doctor](#running-mise-doctor)
  - [Common Warnings and Fixes](#common-warnings-and-fixes)
  - [Health Check in CI](#health-check-in-ci)
- [Plugin Compatibility](#plugin-compatibility)
  - [asdf Plugin Issues](#asdf-plugin-issues)
  - [Plugin Update Problems](#plugin-update-problems)
  - [Plugin vs Core Backend](#plugin-vs-core-backend)
<!-- /TOC -->

---

## Shell Activation Issues

### Mise Commands Work but Tools Don't Activate

**Symptom**: `mise ls` shows installed tools but `node --version` uses system node (or says "not found").

**Cause**: Missing shell activation.

**Fix**: Add activation to your shell rc file:

```sh
# Bash (~/.bashrc)
eval "$(mise activate bash)"

# Zsh (~/.zshrc)
eval "$(mise activate zsh)"

# Fish (~/.config/fish/config.fish)
mise activate fish | source
```

Then restart your shell or source the file:
```sh
source ~/.bashrc   # or ~/.zshrc
```

**Verify**:
```sh
mise doctor       # should show "activated: yes"
which node        # should point to mise shim or install path
```

### Shell Not Recognized

**Symptom**: `mise activate` errors or unexpected behavior.

**Fix**: Ensure you're using the correct shell name:
```sh
echo $SHELL       # check your shell
echo $0           # check current shell process
mise activate bash   # for bash
mise activate zsh    # for zsh
mise activate fish   # for fish
```

### Activation in Non-Interactive Shells

**Symptom**: Tools not available in scripts, cron jobs, or CI.

**Cause**: Shell activation only works in interactive shells. Non-interactive shells need shims or explicit exec.

**Fix options**:

```sh
# Option 1: Use mise exec (recommended for scripts)
mise exec -- node script.js
mise exec -- python app.py

# Option 2: Use shims (add to PATH)
export PATH="$HOME/.local/share/mise/shims:$PATH"
node script.js

# Option 3: Activate in the script
eval "$(mise activate bash --shims)"
node script.js
```

### IDE / Editor Integration

**Symptom**: IDE uses wrong tool version or can't find tools.

**Fix for VS Code**:
- Install the `jdx.mise-vscode` extension
- Or add to VS Code settings:
```json
{
  "terminal.integrated.env.linux": {
    "PATH": "${env:HOME}/.local/share/mise/shims:${env:PATH}"
  }
}
```

**Fix for JetBrains IDEs**:
- Set SDK/interpreter path to: `~/.local/share/mise/installs/<tool>/<version>/bin/<binary>`
- Or configure the shims path in terminal settings

---

## PATH Conflicts

### Wrong Tool Version Active

**Symptom**: `node --version` shows a different version than `mise ls` says is active.

**Debug**:
```sh
mise ls                # what mise thinks is active
which node             # what the shell resolves
mise where node        # where mise installed it
type -a node           # all node binaries in PATH
mise doctor            # check for issues
```

**Common causes**:
- Another version manager (nvm, pyenv) modifying PATH after mise
- Homebrew-installed versions taking precedence
- Shell rc file ordering (mise activate must come after other PATH modifications)

**Fix**: Ensure `eval "$(mise activate ...)"` is the **last** PATH-modifying line in your shell rc.

### System Tools Override Mise

**Symptom**: System-installed tools take precedence over mise-managed tools.

**Debug**:
```sh
type -a python         # shows all python binaries in order
echo $PATH | tr ':' '\n'  # show PATH entries
```

**Fix**: Mise activation should prepend to PATH. If system paths come first, move activation later in your rc file:

```sh
# ~/.bashrc — mise should be LAST
export PATH="/usr/local/bin:$PATH"   # system paths first
# ... other PATH modifications ...
eval "$(mise activate bash)"         # mise last (highest priority)
```

### PATH Order Debugging

```sh
# Show complete PATH with mise entries highlighted
echo $PATH | tr ':' '\n' | grep -n mise

# Show which version of each tool is resolved
for tool in node python ruby go; do
  echo "$tool: $(which $tool 2>/dev/null || echo 'not found')"
done

# Verify mise's PATH entries
mise env | grep PATH
```

### Shims vs PATH Entry

Mise can operate in two modes:

1. **Activate mode** (recommended): `eval "$(mise activate bash)"` — dynamically updates PATH on `cd`
2. **Shims mode**: `export PATH="$HOME/.local/share/mise/shims:$PATH"` — static shims that call mise to resolve versions

If you see stale versions, try reshimming:
```sh
mise reshim
```

---

## Tool Installation Failures

### Common Build Errors

**Missing build dependencies**:
```sh
# Debian/Ubuntu
sudo apt-get install -y build-essential libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev libffi-dev \
  liblzma-dev libncursesw5-dev xz-utils tk-dev

# macOS
xcode-select --install
brew install openssl readline sqlite3 xz zlib
```

**Verbose output for debugging**:
```sh
mise install node@20 --verbose    # show detailed install output
mise install python@3.12 --raw    # show raw build output
```

### Python Installation Issues

**Symptom**: Python build fails with missing headers.

```sh
# Debian/Ubuntu — install build deps
sudo apt-get install -y build-essential libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev curl \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
  libffi-dev liblzma-dev

# macOS — install build deps
brew install openssl readline sqlite3 xz zlib tcl-tk

# Set compiler flags on macOS
export LDFLAGS="-L$(brew --prefix openssl)/lib"
export CPPFLAGS="-I$(brew --prefix openssl)/include"
mise install python@3.12
```

**Symptom**: `No module named '_ssl'`
```sh
# Ensure openssl development headers are installed
sudo apt-get install libssl-dev   # Debian/Ubuntu
brew install openssl              # macOS
mise uninstall python@3.12 && mise install python@3.12
```

### Node.js Installation Issues

**Symptom**: Node build fails or binary doesn't match architecture.

```sh
# Force a clean reinstall
mise uninstall node@20
mise cache clear
mise install node@20

# On Apple Silicon, ensure using arm64
uname -m    # should be arm64
mise install node@20 --verbose
```

### Ruby Installation Issues

**Symptom**: Ruby build fails.

```sh
# Install Ruby build dependencies
# Debian/Ubuntu
sudo apt-get install -y autoconf patch build-essential rustc libssl-dev \
  libyaml-dev libreadline6-dev zlib1g-dev libgmp-dev libncurses5-dev \
  libffi-dev libgdbm6 libgdbm-dev libdb-dev uuid-dev

# macOS
brew install openssl libyaml libffi

mise install ruby@3.3 --verbose
```

### Network / Download Errors

**Symptom**: Download timeouts or SSL errors.

```sh
# Check connectivity
curl -I https://nodejs.org
curl -I https://github.com

# Use a mirror (for Node.js)
export NODE_BUILD_MIRROR_URL="https://unofficial-builds.nodejs.org"
mise install node@20

# Increase timeout
export MISE_FETCH_REMOTE_VERSIONS_TIMEOUT=30   # seconds

# Behind a proxy
export HTTP_PROXY="http://proxy:8080"
export HTTPS_PROXY="http://proxy:8080"
mise install
```

---

## Backend Errors

### Aqua Backend Failures

**Symptom**: `aqua:owner/repo` fails to install.

```sh
# Verify the package exists in aqua registry
# Check: https://github.com/aquaproj/aqua-registry

# Update the aqua registry cache
mise cache clear

# Try verbose install
mise install "aqua:cli/cli" --verbose

# Fallback to github backend
# Change: "aqua:cli/cli" → "github:cli/cli"
```

### Cargo Backend Failures

**Symptom**: `cargo:crate` fails to compile.

```sh
# Ensure Rust toolchain is installed
mise use rust@stable     # or install via rustup

# Install with verbose output
mise install "cargo:ripgrep" --verbose

# Common fix: update Rust
rustup update stable
```

### Pipx Backend Failures

**Symptom**: `pipx:package` fails.

```sh
# Ensure Python is available (pipx needs it)
mise use python@3.12
mise install "pipx:black" --verbose

# If pipx itself is missing
pip install pipx
mise install "pipx:black"
```

### GitHub Backend Failures

**Symptom**: `github:owner/repo` fails to download or extract.

```sh
# Rate limiting — authenticate
export GITHUB_TOKEN="ghp_..."
mise install "github:owner/repo" --verbose

# Wrong architecture detection
mise install "github:owner/repo" --verbose 2>&1 | grep -i arch
```

### Disabling Problematic Backends

```sh
# Disable a backend globally
mise settings set disable_backends asdf

# Disable multiple
mise settings set disable_backends "asdf,pipx"

# Re-enable all
mise settings set disable_backends ""
```

---

## Legacy File Conflicts

### Multiple Version Files

**Symptom**: Unexpected tool version active when multiple version files exist.

**Precedence** (highest to lowest):
1. `.mise.toml` (current directory)
2. `.mise.toml` (parent directories)
3. `~/.config/mise/config.toml` (global)
4. `.tool-versions` (current directory)
5. `.node-version`, `.python-version`, etc.
6. `.nvmrc`

**Debug**:
```sh
# See which config file is setting the version
mise ls --json | python3 -c "
import sys, json
for tool in json.load(sys.stdin):
    print(f\"{tool['tool']}: {tool['version']} (from {tool.get('source', 'unknown')})\")
"

# Or simply
mise doctor
```

### .tool-versions Conflicts

**Symptom**: `.tool-versions` and `.mise.toml` define different versions of the same tool.

**Fix**: `.mise.toml` always wins. Either:
1. Remove the tool from `.tool-versions`
2. Align versions between files
3. Delete `.tool-versions` entirely after migration

### Disabling Legacy File Support

If legacy files cause confusion:

```toml
# .mise.toml or ~/.config/mise/config.toml
[settings]
legacy_version_file = false    # ignore .node-version, .python-version, etc.
```

Or disable for specific tools:
```toml
[settings]
legacy_version_file_disable_tools = ["python", "node"]
```

---

## Slow Shell Startup

### Diagnosing Slow Activation

**Symptom**: Shell takes noticeably longer to start after adding mise activation.

**Measure**:
```sh
# Time shell startup with mise
time bash -ic "exit"
time zsh -ic "exit"

# Time mise activation specifically
time mise activate bash > /dev/null
time mise hook-env > /dev/null
```

### Optimization Strategies

```sh
# 1. Reduce tools in global config — only pin what you need globally
cat ~/.config/mise/config.toml

# 2. Disable unused backends
mise settings set disable_backends "asdf"

# 3. Reduce plugin update frequency
mise settings set plugin_autoupdate_last_check_duration "30d"

# 4. Use shims instead of activate (faster but less dynamic)
# Replace: eval "$(mise activate bash)"
# With:    export PATH="$HOME/.local/share/mise/shims:$PATH"

# 5. Clear stale cache
mise cache clear
mise prune
```

### Measuring Startup Time

```sh
# Detailed timing
MISE_LOG_LEVEL=debug time mise activate bash > /dev/null

# Compare with and without mise
time bash --norc -ic "exit"                          # baseline
time bash -ic "exit"                                 # with all rc
time bash -ic "eval \"\$(mise activate bash)\"; exit"  # mise only
```

---

## mise doctor Output Interpretation

### Running mise doctor

```sh
mise doctor
```

Produces a diagnostic report covering:
- mise version and build info
- Shell activation status
- Config files detected and their paths
- Installed tools and versions
- Plugin status
- Potential issues

### Common Warnings and Fixes

**"mise is not activated"**
```
⚠ mise is not activated. Run `eval "$(mise activate bash)"` in your shell rc.
```
Fix: Add activation to shell rc (see [Shell Activation Issues](#shell-activation-issues)).

**"mise is out of date"**
```
⚠ mise is out of date (current: 2024.1.0, latest: 2025.1.0)
```
Fix:
```sh
mise self-update
```

**"missing tools"**
```
⚠ missing tools: node@20.11.0, python@3.12.2
```
Fix:
```sh
mise install
```

**"config file not trusted"**
```
⚠ config file not trusted: /path/to/.mise.toml
```
Fix:
```sh
mise trust /path/to/.mise.toml
# Or trust all configs in a directory
mise settings set trusted_config_paths "/path/to/workspace"
```

**"legacy file conflicts"**
```
⚠ conflicting versions: node 20 (.mise.toml) vs node 18 (.nvmrc)
```
Fix: Remove the legacy file or align versions.

**"plugin out of date"**
```
⚠ plugin terraform is out of date
```
Fix:
```sh
mise plugin update terraform
mise plugin update --all
```

### Health Check in CI

```yaml
# GitHub Actions
- name: Verify mise setup
  run: |
    mise doctor
    mise ls --missing | tee /dev/stderr | (! grep -q .)  # fail if missing tools
```

---

## Plugin Compatibility

### asdf Plugin Issues

**Symptom**: asdf plugin doesn't work with mise.

```sh
# Check if mise has a core backend for the tool (preferred)
mise ls-remote <tool>    # if this works, core backend is available

# If using asdf plugin explicitly
mise plugin install terraform https://github.com/asdf-community/asdf-hashicorp.git
mise install terraform@1.7

# Verify plugin is installed
mise plugin ls
```

**Common issues**:
- asdf backend disabled by default on some platforms → enable with `mise settings set disable_backends ""`
- Plugin expects `asdf` command → mise provides compatibility shims
- Plugin uses bash-specific features → ensure bash is installed

### Plugin Update Problems

**Symptom**: Plugin can't find new versions.

```sh
# Update the specific plugin
mise plugin update terraform

# Update all plugins
mise plugin update --all

# Force reinstall a plugin
mise plugin uninstall terraform
mise plugin install terraform
```

### Plugin vs Core Backend

Mise has built-in (core) support for many tools. Core backends are faster and more reliable than plugins.

**Core-supported tools** (partial list): node, python, ruby, go, java, erlang, elixir, rust, bun, deno

```sh
# Check if a tool uses core or plugin backend
mise ls --json | grep -A2 '"tool":"node"'

# Force core backend (if available)
[tools]
node = "20"          # uses core backend automatically

# Force asdf plugin backend
[tools]
"asdf:nodejs" = "20"   # explicitly use asdf plugin
```

Prefer core backends when available — they're faster, have better error messages, and don't require plugin management.
