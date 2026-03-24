#!/usr/bin/env bash
# component-generator.sh — Generate a React Server or Client Component
# Usage: ./component-generator.sh <component-name> <server|client>
# Examples:
#   ./component-generator.sh UserProfile server    → src/components/user-profile.tsx (Server Component)
#   ./component-generator.sh SearchBar client       → src/components/search-bar.tsx (Client Component)
#   ./component-generator.sh ui/Button client       → src/components/ui/button.tsx (Client Component in ui/)

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <component-name> <server|client>"
  echo ""
  echo "Examples:"
  echo "  $0 UserProfile server"
  echo "  $0 SearchBar client"
  echo "  $0 ui/Button client"
  exit 1
fi

INPUT_NAME="$1"
COMPONENT_TYPE="$2"

if [ "$COMPONENT_TYPE" != "server" ] && [ "$COMPONENT_TYPE" != "client" ]; then
  echo "Error: Type must be 'server' or 'client'."
  exit 1
fi

# Handle subdirectory paths (e.g., ui/Button)
if echo "$INPUT_NAME" | grep -q '/'; then
  SUBDIR=$(dirname "$INPUT_NAME")
  RAW_NAME=$(basename "$INPUT_NAME")
else
  SUBDIR=""
  RAW_NAME="$INPUT_NAME"
fi

# Convert PascalCase/camelCase to kebab-case for filename
FILE_NAME=$(echo "$RAW_NAME" | sed -r 's/([a-z])([A-Z])/\1-\2/g' | tr '[:upper:]' '[:lower:]')

# Convert to PascalCase for component name
COMPONENT_NAME=$(echo "$RAW_NAME" | sed -r 's/(^|[-_])(\w)/\U\2/g')

# Determine base directory
if [ -d "src/components" ]; then
  BASE_DIR="src/components"
elif [ -d "components" ]; then
  BASE_DIR="components"
else
  BASE_DIR="src/components"
  mkdir -p "$BASE_DIR"
fi

if [ -n "$SUBDIR" ]; then
  TARGET_DIR="$BASE_DIR/$SUBDIR"
  mkdir -p "$TARGET_DIR"
else
  TARGET_DIR="$BASE_DIR"
fi

FILE_PATH="$TARGET_DIR/$FILE_NAME.tsx"

if [ -f "$FILE_PATH" ]; then
  echo "Error: File '$FILE_PATH' already exists."
  exit 1
fi

if [ "$COMPONENT_TYPE" = "client" ]; then
  cat > "$FILE_PATH" << COMPONENT
"use client";

import { useState } from "react";

interface ${COMPONENT_NAME}Props {
  className?: string;
}

export function ${COMPONENT_NAME}({ className }: ${COMPONENT_NAME}Props) {
  return (
    <div className={className}>
      <p>${COMPONENT_NAME} component</p>
    </div>
  );
}
COMPONENT

  echo "✅ Client Component created: $FILE_PATH"
  echo "   - Has \"use client\" directive"
  echo "   - React hooks available (useState, useEffect, etc.)"
  echo "   - Event handlers available (onClick, onChange, etc.)"

else
  cat > "$FILE_PATH" << COMPONENT
interface ${COMPONENT_NAME}Props {
  className?: string;
}

export async function ${COMPONENT_NAME}({ className }: ${COMPONENT_NAME}Props) {
  // Server Component: can await data, access DB, use server-only code
  // const data = await fetchData();

  return (
    <div className={className}>
      <p>${COMPONENT_NAME} component</p>
    </div>
  );
}
COMPONENT

  echo "✅ Server Component created: $FILE_PATH"
  echo "   - No \"use client\" directive (renders on server by default)"
  echo "   - Can use async/await directly"
  echo "   - Can access DB, filesystem, and secrets"
  echo "   - Ships zero JavaScript to the client"
fi
