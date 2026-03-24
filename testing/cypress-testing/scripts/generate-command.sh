#!/usr/bin/env bash
set -euo pipefail

# generate-command.sh — Generates a new custom Cypress command with TypeScript declaration.
# Usage: ./generate-command.sh <command-name> <description>
#
# Examples:
#   ./generate-command.sh dragTo "Drag an element to a target"
#   ./generate-command.sh waitForApi "Wait for an API call to complete"
#   ./generate-command.sh selectDropdown "Select an option from a custom dropdown"

if [ $# -lt 2 ]; then
  echo "Usage: $0 <command-name> <description>"
  echo ""
  echo "Generates a new custom Cypress command with TypeScript declarations."
  echo ""
  echo "Examples:"
  echo "  $0 dragTo 'Drag an element to a target'"
  echo "  $0 waitForApi 'Wait for an API call to complete'"
  exit 1
fi

COMMAND_NAME="$1"
shift
DESCRIPTION="$*"

# Validate command name (camelCase, no spaces)
if [[ ! "$COMMAND_NAME" =~ ^[a-z][a-zA-Z0-9]*$ ]]; then
  echo "Error: Command name must be camelCase (e.g., 'myCommand')."
  exit 1
fi

# Detect project structure
COMMANDS_FILE=""
TYPES_FILE=""

# Search for the commands file
for candidate in \
  "cypress/support/commands.ts" \
  "cypress/support/commands.js" \
  "cypress/support/commands/index.ts" \
  "cypress/support/commands/index.js"; do
  if [ -f "$candidate" ]; then
    COMMANDS_FILE="$candidate"
    break
  fi
done

# Search for the types file
for candidate in \
  "cypress/support/commands.ts" \
  "cypress/support/index.d.ts" \
  "cypress/support/cypress.d.ts" \
  "cypress.d.ts"; do
  if [ -f "$candidate" ]; then
    TYPES_FILE="$candidate"
    break
  fi
done

# Determine if TypeScript
IS_TS=false
if [[ "$COMMANDS_FILE" == *.ts ]] || [ -f "cypress/tsconfig.json" ]; then
  IS_TS=true
fi

if [ -z "$COMMANDS_FILE" ]; then
  echo "Error: Could not find Cypress commands file."
  echo "Expected one of:"
  echo "  - cypress/support/commands.ts"
  echo "  - cypress/support/commands.js"
  echo ""
  echo "Run setup-cypress.sh first or create the file manually."
  exit 1
fi

echo "📝 Generating command: $COMMAND_NAME"
echo "   Description: $DESCRIPTION"
echo "   Commands file: $COMMANDS_FILE"

# Generate the command implementation
COMMAND_CODE=""
if [ "$IS_TS" = true ]; then
  COMMAND_CODE="
/**
 * Custom command: $COMMAND_NAME
 * $DESCRIPTION
 */
Cypress.Commands.add('$COMMAND_NAME', (/* add parameters here */) => {
  // TODO: Implement $COMMAND_NAME
  // $DESCRIPTION
  cy.log('$COMMAND_NAME called');
});"
else
  COMMAND_CODE="
/**
 * Custom command: $COMMAND_NAME
 * $DESCRIPTION
 */
Cypress.Commands.add('$COMMAND_NAME', (/* add parameters here */) => {
  // TODO: Implement $COMMAND_NAME
  // $DESCRIPTION
  cy.log('$COMMAND_NAME called');
});"
fi

# Check if command already exists
if grep -q "Commands.add('$COMMAND_NAME'" "$COMMANDS_FILE" 2>/dev/null; then
  echo "⚠️  Command '$COMMAND_NAME' already exists in $COMMANDS_FILE"
  exit 1
fi

# Append command to commands file
echo "$COMMAND_CODE" >> "$COMMANDS_FILE"
echo "✅ Added command to $COMMANDS_FILE"

# Generate TypeScript declaration
if [ "$IS_TS" = true ]; then
  # For .ts files with inline declarations, check for existing Chainable interface
  if grep -q "interface Chainable" "$COMMANDS_FILE" 2>/dev/null; then
    # Insert before the closing brace of the Chainable interface
    # Find the last closing brace of the interface and insert before it
    DECLARATION="      /**
       * $DESCRIPTION
       */
      $COMMAND_NAME(/* add parameters here */): Chainable<void>;"

    # Use a temp file for safe editing
    TEMP_FILE=$(mktemp)
    awk -v decl="$DECLARATION" '
      /interface Chainable/ { in_interface=1 }
      in_interface && /^[[:space:]]*\}/ {
        print decl
        in_interface=0
      }
      { print }
    ' "$COMMANDS_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$COMMANDS_FILE"
    echo "✅ Added TypeScript declaration to $COMMANDS_FILE"

  elif [ -n "$TYPES_FILE" ] && [ "$TYPES_FILE" != "$COMMANDS_FILE" ]; then
    # Separate types file
    if grep -q "interface Chainable" "$TYPES_FILE" 2>/dev/null; then
      DECLARATION="    /**
     * $DESCRIPTION
     */
    $COMMAND_NAME(/* add parameters here */): Chainable<void>;"

      TEMP_FILE=$(mktemp)
      awk -v decl="$DECLARATION" '
        /interface Chainable/ { in_interface=1 }
        in_interface && /^[[:space:]]*\}/ {
          print decl
          in_interface=0
        }
        { print }
      ' "$TYPES_FILE" > "$TEMP_FILE"
      mv "$TEMP_FILE" "$TYPES_FILE"
      echo "✅ Added TypeScript declaration to $TYPES_FILE"
    else
      echo "⚠️  No Chainable interface found in $TYPES_FILE. Add declaration manually."
    fi
  else
    echo "⚠️  No types file found. Consider adding a declaration file."
    echo "   Add to cypress/support/index.d.ts or your commands file:"
    echo ""
    echo "   declare global {"
    echo "     namespace Cypress {"
    echo "       interface Chainable {"
    echo "         $COMMAND_NAME(/* params */): Chainable<void>;"
    echo "       }"
    echo "     }"
    echo "   }"
  fi
fi

# Create a test stub for the command
TEST_DIR="cypress/e2e"
if [ ! -d "$TEST_DIR" ]; then
  TEST_DIR="cypress/integration"
fi

EXT=$( [ "$IS_TS" = true ] && echo "ts" || echo "js" )

echo ""
echo "✨ Command '$COMMAND_NAME' generated successfully!"
echo ""
echo "Next steps:"
echo "  1. Implement the command body in $COMMANDS_FILE"
echo "  2. Add proper parameters and types"
echo "  3. Use in tests: cy.$COMMAND_NAME()"
echo ""
echo "Example usage in a test:"
echo ""
echo "  it('uses $COMMAND_NAME', () => {"
echo "    cy.$COMMAND_NAME(/* args */);"
echo "  });"
