#!/usr/bin/env bash
#
# generate-story.sh — Generate a CSF3 story file from a component file
#
# Usage:
#   ./generate-story.sh <component-file-path>
#   ./generate-story.sh src/components/Button.tsx
#   ./generate-story.sh src/components/Card.vue
#   ./generate-story.sh --output src/stories/Button.stories.tsx src/components/Button.tsx
#
# Generates a .stories.tsx/.stories.ts file with:
#   - Auto-detected props from the component file
#   - Default story with sensible args
#   - Playground story with all controls
#   - Interaction test template with play function
#
# Supports: .tsx, .ts, .jsx, .js, .vue, .svelte
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[generate-story]${NC} $*"; }
warn()  { echo -e "${YELLOW}[generate-story]${NC} $*"; }
error() { echo -e "${RED}[generate-story]${NC} $*" >&2; }

# --- Parse args ---
OUTPUT=""
COMPONENT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) OUTPUT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--output <path>] <component-file>"
      echo ""
      echo "Examples:"
      echo "  $0 src/components/Button.tsx"
      echo "  $0 --output src/stories/Button.stories.tsx src/components/Button.tsx"
      exit 0
      ;;
    *) COMPONENT_FILE="$1"; shift ;;
  esac
done

if [[ -z "$COMPONENT_FILE" ]]; then
  error "No component file specified."
  echo "Usage: $0 <component-file>"
  exit 1
fi

if [[ ! -f "$COMPONENT_FILE" ]]; then
  error "File not found: $COMPONENT_FILE"
  exit 1
fi

# --- Detect component info ---
FILENAME=$(basename "$COMPONENT_FILE")
EXTENSION="${FILENAME##*.}"
BASENAME="${FILENAME%.*}"

# Strip common suffixes to get component name
COMPONENT_NAME="$BASENAME"
COMPONENT_NAME="${COMPONENT_NAME%.component}"  # Angular
COMPONENT_NAME="${COMPONENT_NAME%.Component}"

COMPONENT_DIR=$(dirname "$COMPONENT_FILE")

# Determine story file location
if [[ -z "$OUTPUT" ]]; then
  case "$EXTENSION" in
    vue)    OUTPUT="${COMPONENT_DIR}/${BASENAME}.stories.ts" ;;
    svelte) OUTPUT="${COMPONENT_DIR}/${BASENAME}.stories.ts" ;;
    *)      OUTPUT="${COMPONENT_DIR}/${BASENAME}.stories.tsx" ;;
  esac
fi

STORY_EXT="${OUTPUT##*.}"

# --- Detect framework ---
detect_framework() {
  case "$EXTENSION" in
    vue)    echo "vue" ;;
    svelte) echo "svelte" ;;
    *)
      # Check package.json
      if [[ -f "package.json" ]]; then
        if grep -q '"@angular/core"' package.json; then
          echo "angular"
        else
          echo "react"
        fi
      else
        echo "react"
      fi
      ;;
  esac
}

FRAMEWORK=$(detect_framework)
log "Framework: ${BLUE}${FRAMEWORK}${NC}"
log "Component: ${BLUE}${COMPONENT_NAME}${NC}"

# --- Extract props (best effort) ---
extract_react_props() {
  local file="$1"
  local props=()

  # Try to find interface/type Props
  while IFS= read -r line; do
    # Match: propName: type or propName?: type
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)\??:[[:space:]]*(.*) ]]; then
      local name="${BASH_REMATCH[1]}"
      local type="${BASH_REMATCH[2]}"
      type="${type%;}"
      type="${type%%,}"
      # Skip internal props
      case "$name" in
        children|className|style|ref|key) continue ;;
      esac
      props+=("${name}:${type}")
    fi
  done < <(sed -n '/\(Props\|Properties\)\s*[={]/,/^}/p' "$file" 2>/dev/null || true)

  # Fallback: look for destructured props in function signature
  if [[ ${#props[@]} -eq 0 ]]; then
    while IFS= read -r match; do
      props+=("${match}:unknown")
    done < <(grep -oP '(?<=\{\s)[^}]+(?=\})' "$file" | head -1 | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^\.\.\.' | sed 's/=.*//' || true)
  fi

  printf '%s\n' "${props[@]}"
}

PROPS=()
if [[ "$FRAMEWORK" == "react" ]]; then
  while IFS= read -r prop; do
    [[ -n "$prop" ]] && PROPS+=("$prop")
  done < <(extract_react_props "$COMPONENT_FILE")
fi

# --- Build story title ---
# Convert path to Storybook hierarchy
RELATIVE_PATH="${COMPONENT_DIR#src/}"
RELATIVE_PATH="${RELATIVE_PATH#components/}"
STORY_TITLE=$(echo "$RELATIVE_PATH/$COMPONENT_NAME" | sed 's|/|/|g' | sed 's|^\./||')
# Capitalize first letter of each segment
STORY_TITLE=$(echo "$STORY_TITLE" | sed 's|/|\n|g' | while read -r seg; do
  echo "${seg^}"
done | paste -sd '/')

log "Story title: ${BLUE}${STORY_TITLE}${NC}"

# --- Generate story ---
generate_react_story() {
  local args_block=""
  local argtypes_block=""

  for prop_entry in "${PROPS[@]}"; do
    local name="${prop_entry%%:*}"
    local type="${prop_entry#*:}"

    # Generate arg defaults
    case "$type" in
      string|string*) args_block+="    ${name}: '${name} value',\n" ;;
      number|number*) args_block+="    ${name}: 0,\n" ;;
      boolean|boolean*) args_block+="    ${name}: false,\n" ;;
      *) args_block+="    // ${name}: undefined,\n" ;;
    esac

    # Generate argTypes
    case "$type" in
      string|string*) argtypes_block+="    ${name}: { control: 'text' },\n" ;;
      number|number*) argtypes_block+="    ${name}: { control: 'number' },\n" ;;
      boolean|boolean*) argtypes_block+="    ${name}: { control: 'boolean' },\n" ;;
      *\"*\"|*"'*'") argtypes_block+="    ${name}: { control: 'select', options: [] },\n" ;;
      *) argtypes_block+="    ${name}: { control: 'text' },\n" ;;
    esac
  done

  # Handle callback props
  if grep -qP 'on[A-Z]\w*' "$COMPONENT_FILE" 2>/dev/null; then
    local callbacks
    callbacks=$(grep -oP 'on[A-Z]\w*' "$COMPONENT_FILE" | sort -u | head -5)
    for cb in $callbacks; do
      argtypes_block+="    ${cb}: { action: '${cb}' },\n"
    done
  fi

  cat << STORY_EOF
import type { Meta, StoryObj } from '@storybook/react';
import { expect, fn, userEvent, within, waitFor } from '@storybook/test';
import { ${COMPONENT_NAME} } from './${BASENAME}';

const meta = {
  title: '${STORY_TITLE}',
  component: ${COMPONENT_NAME},
  tags: ['autodocs'],
  args: {
$(echo -en "$args_block")  },
  argTypes: {
$(echo -en "$argtypes_block")  },
  parameters: {
    layout: 'centered',
    docs: {
      description: {
        component: '${COMPONENT_NAME} component — update this description.',
      },
    },
  },
  decorators: [
    (Story) => (
      <div style={{ padding: '1rem' }}>
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof ${COMPONENT_NAME}>;

export default meta;
type Story = StoryObj<typeof meta>;

/** Default story — renders component with base args. */
export const Default: Story = {};

/** All variants — showcase different prop combinations. */
export const Playground: Story = {
  args: {
    ...meta.args,
  },
};

/** Interaction test — validates user interactions. */
export const WithInteraction: Story = {
  args: {
    ...meta.args,
  },
  play: async ({ canvasElement, args, step }) => {
    const canvas = within(canvasElement);

    await step('Component renders', async () => {
      // TODO: Update selector to match your component
      // const element = canvas.getByRole('button');
      // expect(element).toBeVisible();
    });

    await step('User interacts', async () => {
      // TODO: Add interaction steps
      // await userEvent.click(canvas.getByRole('button'));
      // await waitFor(() => {
      //   expect(args.onClick).toHaveBeenCalled();
      // });
    });
  },
};
STORY_EOF
}

generate_vue_story() {
  cat << STORY_EOF
import type { Meta, StoryObj } from '@storybook/vue3';
import ${COMPONENT_NAME} from './${FILENAME}';

const meta: Meta<typeof ${COMPONENT_NAME}> = {
  title: '${STORY_TITLE}',
  component: ${COMPONENT_NAME},
  tags: ['autodocs'],
  argTypes: {
    // TODO: Add argTypes based on component props
  },
  parameters: {
    layout: 'centered',
  },
};

export default meta;
type Story = StoryObj<typeof meta>;

/** Default rendering of the component. */
export const Default: Story = {
  args: {
    // TODO: Add default args
  },
};

/** Playground — all props exposed as controls. */
export const Playground: Story = {
  args: {
    ...Default.args,
  },
};
STORY_EOF
}

generate_svelte_story() {
  cat << STORY_EOF
import type { Meta, StoryObj } from '@storybook/svelte';
import ${COMPONENT_NAME} from './${FILENAME}';

const meta: Meta<typeof ${COMPONENT_NAME}> = {
  title: '${STORY_TITLE}',
  component: ${COMPONENT_NAME},
  tags: ['autodocs'],
  argTypes: {
    // TODO: Add argTypes based on component props
  },
  parameters: {
    layout: 'centered',
  },
};

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  args: {
    // TODO: Add default args
  },
};

export const Playground: Story = {
  args: {
    ...Default.args,
  },
};
STORY_EOF
}

generate_angular_story() {
  cat << STORY_EOF
import type { Meta, StoryObj } from '@storybook/angular';
import { moduleMetadata } from '@storybook/angular';
import { CommonModule } from '@angular/common';
import { ${COMPONENT_NAME} } from './${BASENAME}';

const meta: Meta<${COMPONENT_NAME}> = {
  title: '${STORY_TITLE}',
  component: ${COMPONENT_NAME},
  tags: ['autodocs'],
  decorators: [
    moduleMetadata({
      imports: [CommonModule],
    }),
  ],
  argTypes: {
    // TODO: Add argTypes based on component inputs
  },
  parameters: {
    layout: 'centered',
  },
};

export default meta;
type Story = StoryObj<${COMPONENT_NAME}>;

export const Default: Story = {
  args: {
    // TODO: Add default args matching @Input() properties
  },
};

export const Playground: Story = {
  args: {
    ...Default.args,
  },
};
STORY_EOF
}

# --- Write story file ---
if [[ -f "$OUTPUT" ]]; then
  warn "Story file already exists: $OUTPUT"
  read -r -p "Overwrite? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    log "Aborted."
    exit 0
  fi
fi

mkdir -p "$(dirname "$OUTPUT")"

case "$FRAMEWORK" in
  react)   generate_react_story > "$OUTPUT" ;;
  vue)     generate_vue_story > "$OUTPUT" ;;
  svelte)  generate_svelte_story > "$OUTPUT" ;;
  angular) generate_angular_story > "$OUTPUT" ;;
esac

log "Generated story: ${BLUE}${OUTPUT}${NC}"

# --- Summary ---
LINES=$(wc -l < "$OUTPUT")
echo ""
echo -e "${GREEN}✓ Story generated: ${OUTPUT} (${LINES} lines)${NC}"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo "  1. Update args with real default values"
echo "  2. Add argTypes for proper controls"
echo "  3. Fill in the interaction test play function"
echo "  4. Run: npx storybook dev -p 6006"
echo ""
