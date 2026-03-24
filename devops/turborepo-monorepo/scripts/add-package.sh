#!/usr/bin/env bash
# =============================================================================
# add-package.sh — Add a new package or app to a Turborepo monorepo
# =============================================================================
# Usage:
#   ./add-package.sh <name> [options]
#
# Options:
#   --type <package|app>      Type of workspace (default: package)
#   --org <scope>             npm org scope (default: read from root package.json)
#   --template <lib|react|node-service>
#                             Template to use (default: lib)
#   --deps <pkg1,pkg2,...>    Comma-separated internal dependencies
#
# Examples:
#   ./add-package.sh auth                           # packages/auth (library)
#   ./add-package.sh auth --type app                # apps/auth (application)
#   ./add-package.sh payments --template react      # React component library
#   ./add-package.sh api --type app --template node-service
#   ./add-package.sh analytics --deps utils,ui      # With internal deps
#
# Must be run from the monorepo root (where turbo.json lives).
# =============================================================================
set -euo pipefail

# --- Defaults ---
NAME=""
TYPE="package"
ORG_SCOPE=""
TEMPLATE="lib"
DEPS=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --type)
      TYPE="$2"
      shift 2
      ;;
    --org)
      ORG_SCOPE="$2"
      shift 2
      ;;
    --template)
      TEMPLATE="$2"
      shift 2
      ;;
    --deps)
      DEPS="$2"
      shift 2
      ;;
    -h|--help)
      head -22 "$0" | grep "^#" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      NAME="$1"
      shift
      ;;
  esac
done

# --- Validate ---
if [[ -z "$NAME" ]]; then
  echo "Error: Package name is required."
  echo "Usage: $0 <name> [--type package|app] [--template lib|react|node-service] [--deps pkg1,pkg2]"
  exit 1
fi

if [[ ! -f "turbo.json" ]]; then
  echo "Error: turbo.json not found. Run this script from the monorepo root."
  exit 1
fi

# --- Detect org scope from root package.json ---
if [[ -z "$ORG_SCOPE" ]]; then
  if command -v jq &> /dev/null && [[ -f "package.json" ]]; then
    # Try to extract scope from existing workspace packages
    ORG_SCOPE=$(jq -r '
      .workspaces // [] | .[] | select(startswith("packages/") or startswith("apps/"))
    ' package.json 2>/dev/null | head -1 || true)
    # Fallback: look at existing packages
    if [[ -z "$ORG_SCOPE" ]]; then
      ORG_SCOPE=$(find packages apps -maxdepth 2 -name "package.json" -exec jq -r '.name // ""' {} \; 2>/dev/null \
        | grep "^@" | head -1 | sed 's/@\([^/]*\)\/.*/\1/' || true)
    fi
  fi
  if [[ -z "$ORG_SCOPE" ]]; then
    ORG_SCOPE="myorg"
    echo "⚠ Could not detect org scope, using default: @${ORG_SCOPE}"
  fi
fi

# --- Set paths ---
if [[ "$TYPE" == "app" ]]; then
  TARGET_DIR="apps/${NAME}"
else
  TARGET_DIR="packages/${NAME}"
fi

FULL_NAME="@${ORG_SCOPE}/${NAME}"

if [[ -d "$TARGET_DIR" ]]; then
  echo "Error: Directory '${TARGET_DIR}' already exists."
  exit 1
fi

echo "📦 Creating ${TYPE}: ${FULL_NAME}"
echo "   Directory: ${TARGET_DIR}"
echo "   Template:  ${TEMPLATE}"
echo ""

# --- Create directory ---
mkdir -p "${TARGET_DIR}/src"

# --- Build internal dependencies JSON ---
DEPS_JSON=""
if [[ -n "$DEPS" ]]; then
  IFS=',' read -ra DEP_ARRAY <<< "$DEPS"
  for dep in "${DEP_ARRAY[@]}"; do
    dep=$(echo "$dep" | xargs)  # trim whitespace
    if [[ -n "$DEPS_JSON" ]]; then
      DEPS_JSON="${DEPS_JSON},"
    fi
    DEPS_JSON="${DEPS_JSON}
    \"@${ORG_SCOPE}/${dep}\": \"workspace:*\""
  done
fi

# --- Generate files based on template ---
case "$TEMPLATE" in
  lib)
    cat > "${TARGET_DIR}/package.json" << EOF
{
  "name": "${FULL_NAME}",
  "private": true,
  "version": "0.0.0",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": {
    ".": "./src/index.ts"
  },
  "scripts": {
    "lint": "eslint src/",
    "typecheck": "tsc --noEmit",
    "test": "echo 'No tests configured yet'",
    "clean": "rm -rf dist .turbo"
  },
  "dependencies": {${DEPS_JSON}
  },
  "devDependencies": {
    "@${ORG_SCOPE}/eslint-config": "workspace:*",
    "@${ORG_SCOPE}/tsconfig": "workspace:*",
    "eslint": "^8.0.0",
    "typescript": "^5.5.0"
  }
}
EOF
    cat > "${TARGET_DIR}/tsconfig.json" << EOF
{
  "extends": "@${ORG_SCOPE}/tsconfig/base.json",
  "compilerOptions": {
    "outDir": "dist"
  },
  "include": ["src"]
}
EOF
    cat > "${TARGET_DIR}/src/index.ts" << EOF
// ${FULL_NAME}

export function hello(): string {
  return "Hello from ${NAME}";
}
EOF
    ;;

  react)
    cat > "${TARGET_DIR}/package.json" << EOF
{
  "name": "${FULL_NAME}",
  "private": true,
  "version": "0.0.0",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": {
    ".": "./src/index.ts"
  },
  "scripts": {
    "lint": "eslint src/",
    "typecheck": "tsc --noEmit",
    "test": "echo 'No tests configured yet'",
    "clean": "rm -rf dist .turbo"
  },
  "dependencies": {${DEPS_JSON}
  },
  "peerDependencies": {
    "react": ">=18.0.0",
    "react-dom": ">=18.0.0"
  },
  "devDependencies": {
    "@${ORG_SCOPE}/eslint-config": "workspace:*",
    "@${ORG_SCOPE}/tsconfig": "workspace:*",
    "@types/react": "^18.0.0",
    "eslint": "^8.0.0",
    "react": "^18.0.0",
    "typescript": "^5.5.0"
  }
}
EOF
    cat > "${TARGET_DIR}/tsconfig.json" << EOF
{
  "extends": "@${ORG_SCOPE}/tsconfig/react-library.json",
  "compilerOptions": {
    "outDir": "dist"
  },
  "include": ["src"]
}
EOF
    cat > "${TARGET_DIR}/src/index.ts" << EOF
// ${FULL_NAME} — React component library
export { ${NAME^} } from "./${NAME^}";
EOF
    # Create a starter component (capitalize first letter)
    COMPONENT_NAME="${NAME^}"
    cat > "${TARGET_DIR}/src/${COMPONENT_NAME}.tsx" << EOF
import React from "react";

export interface ${COMPONENT_NAME}Props {
  children?: React.ReactNode;
  className?: string;
}

export function ${COMPONENT_NAME}({ children, className }: ${COMPONENT_NAME}Props) {
  return <div className={className}>{children}</div>;
}
EOF
    ;;

  node-service)
    cat > "${TARGET_DIR}/package.json" << EOF
{
  "name": "${FULL_NAME}",
  "private": true,
  "version": "0.0.0",
  "main": "./dist/index.js",
  "scripts": {
    "build": "tsc",
    "dev": "tsx watch src/index.ts",
    "start": "node dist/index.js",
    "lint": "eslint src/",
    "typecheck": "tsc --noEmit",
    "test": "echo 'No tests configured yet'",
    "clean": "rm -rf dist .turbo"
  },
  "dependencies": {${DEPS_JSON}
  },
  "devDependencies": {
    "@${ORG_SCOPE}/eslint-config": "workspace:*",
    "@${ORG_SCOPE}/tsconfig": "workspace:*",
    "eslint": "^8.0.0",
    "tsx": "^4.0.0",
    "typescript": "^5.5.0"
  }
}
EOF
    cat > "${TARGET_DIR}/tsconfig.json" << EOF
{
  "extends": "@${ORG_SCOPE}/tsconfig/base.json",
  "compilerOptions": {
    "outDir": "dist",
    "module": "CommonJS",
    "moduleResolution": "node"
  },
  "include": ["src"]
}
EOF
    # Package-level turbo.json for app-specific outputs
    cat > "${TARGET_DIR}/turbo.json" << 'EOF'
{
  "extends": ["//"],
  "tasks": {
    "build": {
      "outputs": ["dist/**"]
    }
  }
}
EOF
    cat > "${TARGET_DIR}/src/index.ts" << EOF
// ${FULL_NAME}

const PORT = process.env.PORT || 3000;

console.log(\`${NAME} service starting on port \${PORT}\`);
EOF
    ;;

  *)
    echo "Error: Unknown template '${TEMPLATE}'. Choose: lib, react, node-service"
    exit 1
    ;;
esac

echo "✅ Created ${TYPE}: ${FULL_NAME} at ${TARGET_DIR}/"
echo ""
echo "Next steps:"
echo "  pnpm install        # Install dependencies and link workspace"
echo "  turbo run build     # Build to verify everything works"
if [[ "$TYPE" == "app" ]]; then
  echo "  turbo run dev --filter=${FULL_NAME}  # Start dev server"
fi
echo ""
echo "To depend on this package from another workspace:"
echo "  \"${FULL_NAME}\": \"workspace:*\""
