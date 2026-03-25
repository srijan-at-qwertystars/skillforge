#!/usr/bin/env bash
# init-biome.sh — Set up Biome in an existing project
#
# Usage:
#   ./init-biome.sh [--strict | --react]
#
# What it does:
#   1. Installs @biomejs/biome (pinned version)
#   2. Detects and migrates from ESLint/Prettier if present
#   3. Creates biome.json with sensible defaults
#   4. Configures VS Code settings (if .vscode/ exists)
#   5. Adds npm scripts to package.json
#
# Options:
#   --strict    Use strict config (all recommended + extra rules)
#   --react     Use React/Next.js optimized config
#   (default)   Standard config with recommended rules
#
# Requirements: Node.js, npm, and a package.json in the current directory

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }

# --- Preflight ---
if [ ! -f "package.json" ]; then
  err "No package.json found. Run this from your project root."
  exit 1
fi

MODE="standard"
if [[ "${1:-}" == "--strict" ]]; then MODE="strict"; fi
if [[ "${1:-}" == "--react" ]];  then MODE="react"; fi

info "Setting up Biome (${MODE} mode)..."

# --- Step 1: Install Biome ---
info "Installing @biomejs/biome..."
npm install --save-dev --save-exact @biomejs/biome
ok "Biome installed"

# --- Step 2: Detect and migrate from ESLint ---
HAS_ESLINT=false
HAS_PRETTIER=false

for f in .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml .eslintrc.yaml eslint.config.js eslint.config.mjs eslint.config.cjs; do
  if [ -f "$f" ]; then HAS_ESLINT=true; break; fi
done

for f in .prettierrc .prettierrc.js .prettierrc.cjs .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.toml prettier.config.js prettier.config.cjs; do
  if [ -f "$f" ]; then HAS_PRETTIER=true; break; fi
done

if [ "$HAS_ESLINT" = true ]; then
  info "ESLint config detected — migrating..."
  npx biome migrate eslint --write 2>/dev/null || warn "ESLint migration had issues (review biome.json manually)"
  ok "ESLint config migrated"
fi

if [ "$HAS_PRETTIER" = true ]; then
  info "Prettier config detected — migrating..."
  npx biome migrate prettier --write 2>/dev/null || warn "Prettier migration had issues (review biome.json manually)"
  ok "Prettier config migrated"
fi

# --- Step 3: Create biome.json (if migration didn't already) ---
if [ ! -f "biome.json" ] && [ ! -f "biome.jsonc" ]; then
  info "Creating biome.json..."

  if [ "$MODE" = "strict" ]; then
    cat > biome.json << 'BIOME_STRICT'
{
  "$schema": "https://biomejs.dev/schemas/2.2.7/schema.json",
  "vcs": {
    "enabled": true,
    "clientKind": "git",
    "useIgnoreFile": true,
    "defaultBranch": "main"
  },
  "files": {
    "ignore": ["dist", "build", "coverage", "node_modules", "*.min.js"]
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 100,
    "lineEnding": "lf"
  },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "suspicious": {
        "noExplicitAny": "error",
        "noConsole": { "level": "warn", "options": { "allow": ["error", "warn"] } }
      },
      "style": {
        "useConst": "error",
        "noVar": "error",
        "useImportType": "error",
        "useExportType": "error",
        "useNodejsImportProtocol": "error"
      },
      "performance": {
        "noAccumulatingSpread": "error",
        "noBarrelFile": "warn"
      },
      "complexity": {
        "noForEach": "warn"
      }
    }
  },
  "assist": {
    "enabled": true,
    "actions": {
      "source": {
        "organizeImports": "on"
      }
    }
  },
  "javascript": {
    "formatter": {
      "quoteStyle": "single",
      "semicolons": "always",
      "trailingCommas": "all",
      "arrowParentheses": "always"
    }
  },
  "json": {
    "formatter": { "trailingCommas": "none" }
  }
}
BIOME_STRICT

  elif [ "$MODE" = "react" ]; then
    cat > biome.json << 'BIOME_REACT'
{
  "$schema": "https://biomejs.dev/schemas/2.2.7/schema.json",
  "vcs": {
    "enabled": true,
    "clientKind": "git",
    "useIgnoreFile": true,
    "defaultBranch": "main"
  },
  "files": {
    "ignore": ["dist", "build", ".next", "coverage", "node_modules", "public"]
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 100,
    "lineEnding": "lf"
  },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "a11y": { "recommended": true },
      "correctness": {
        "useExhaustiveDependencies": "warn",
        "useHookAtTopLevel": "error"
      },
      "suspicious": {
        "noConsole": { "level": "warn", "options": { "allow": ["error", "warn"] } }
      },
      "style": {
        "useConst": "error",
        "useImportType": "error"
      }
    }
  },
  "assist": {
    "enabled": true,
    "actions": {
      "source": { "organizeImports": "on" }
    }
  },
  "javascript": {
    "formatter": {
      "quoteStyle": "single",
      "semicolons": "always",
      "trailingCommas": "all",
      "jsxQuoteStyle": "double"
    }
  },
  "overrides": [
    {
      "include": ["app/**/page.tsx", "app/**/layout.tsx", "app/**/loading.tsx", "app/**/error.tsx", "*.config.ts", "*.config.js"],
      "linter": { "rules": { "style": { "noDefaultExport": "off" } } }
    }
  ]
}
BIOME_REACT

  else
    cat > biome.json << 'BIOME_DEFAULT'
{
  "$schema": "https://biomejs.dev/schemas/2.2.7/schema.json",
  "vcs": {
    "enabled": true,
    "clientKind": "git",
    "useIgnoreFile": true,
    "defaultBranch": "main"
  },
  "files": {
    "ignore": ["dist", "build", "coverage", "node_modules"]
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 100,
    "lineEnding": "lf"
  },
  "linter": {
    "enabled": true,
    "rules": { "recommended": true }
  },
  "assist": {
    "enabled": true,
    "actions": {
      "source": { "organizeImports": "on" }
    }
  },
  "javascript": {
    "formatter": {
      "quoteStyle": "single",
      "semicolons": "always",
      "trailingCommas": "all"
    }
  }
}
BIOME_DEFAULT
  fi

  ok "biome.json created (${MODE})"
else
  ok "biome.json already exists (kept existing config)"
fi

# --- Step 4: Configure VS Code ---
if [ -d ".vscode" ] || [ -f ".vscode/settings.json" ]; then
  info "Configuring VS Code..."
  mkdir -p .vscode

  if [ -f ".vscode/settings.json" ]; then
    # Check if Biome is already configured
    if grep -q "biomejs.biome" .vscode/settings.json 2>/dev/null; then
      ok "VS Code already configured for Biome"
    else
      warn "VS Code settings exist — add Biome manually:"
      echo '  "editor.defaultFormatter": "biomejs.biome"'
      echo '  "editor.formatOnSave": true'
    fi
  else
    cat > .vscode/settings.json << 'VSCODE'
{
  "editor.defaultFormatter": "biomejs.biome",
  "editor.formatOnSave": true,
  "editor.codeActionsOnSave": {
    "source.fixAll.biome": "explicit",
    "source.organizeImports.biome": "explicit"
  },
  "[javascript]": { "editor.defaultFormatter": "biomejs.biome" },
  "[typescript]": { "editor.defaultFormatter": "biomejs.biome" },
  "[typescriptreact]": { "editor.defaultFormatter": "biomejs.biome" },
  "[json]": { "editor.defaultFormatter": "biomejs.biome" },
  "[jsonc]": { "editor.defaultFormatter": "biomejs.biome" },
  "[css]": { "editor.defaultFormatter": "biomejs.biome" }
}
VSCODE
    ok "VS Code settings created"
  fi

  # Recommend the extension
  if [ ! -f ".vscode/extensions.json" ]; then
    cat > .vscode/extensions.json << 'VSEXT'
{
  "recommendations": ["biomejs.biome"]
}
VSEXT
    ok "VS Code extension recommendation added"
  fi
fi

# --- Step 5: Add npm scripts ---
if command -v node &>/dev/null; then
  HAS_CHECK=$(node -e "const p=require('./package.json'); process.exit(p.scripts?.check ? 0 : 1)" 2>/dev/null && echo "yes" || echo "no")
  if [ "$HAS_CHECK" = "no" ]; then
    info "Adding npm scripts..."
    node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.scripts = pkg.scripts || {};
pkg.scripts['check'] = pkg.scripts['check'] || 'biome check .';
pkg.scripts['check:fix'] = pkg.scripts['check:fix'] || 'biome check --write .';
pkg.scripts['lint'] = pkg.scripts['lint'] || 'biome lint .';
pkg.scripts['format'] = pkg.scripts['format'] || 'biome format --write .';
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
    ok "npm scripts added (check, check:fix, lint, format)"
  else
    ok "npm scripts already configured"
  fi
fi

# --- Step 6: Cleanup old tools (optional) ---
if [ "$HAS_ESLINT" = true ] || [ "$HAS_PRETTIER" = true ]; then
  echo ""
  warn "Old tool configs detected. When ready, clean up with:"
  if [ "$HAS_ESLINT" = true ]; then
    echo "  npm uninstall eslint @typescript-eslint/parser @typescript-eslint/eslint-plugin eslint-config-prettier"
    echo "  rm -f .eslintrc* .eslintignore eslint.config.*"
  fi
  if [ "$HAS_PRETTIER" = true ]; then
    echo "  npm uninstall prettier"
    echo "  rm -f .prettierrc* .prettierignore prettier.config.*"
  fi
fi

# --- Done ---
echo ""
ok "Biome setup complete!"
info "Run 'npx biome check .' to verify your project."
