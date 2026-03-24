#!/usr/bin/env bash
#
# init-storybook.sh — Initialize Storybook in an existing project
#
# Usage:
#   ./init-storybook.sh [--framework react|vue|angular|svelte] [--builder vite|webpack]
#
# If no framework is specified, auto-detects from package.json.
# Installs common addons, creates example stories, and configures main.ts.
#
# Examples:
#   ./init-storybook.sh                         # auto-detect framework
#   ./init-storybook.sh --framework react       # force React
#   ./init-storybook.sh --framework vue --builder webpack
#

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[storybook-init]${NC} $*"; }
warn()  { echo -e "${YELLOW}[storybook-init]${NC} $*"; }
error() { echo -e "${RED}[storybook-init]${NC} $*" >&2; }

# --- Defaults ---
FRAMEWORK=""
BUILDER="vite"

# --- Parse Args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --framework) FRAMEWORK="$2"; shift 2 ;;
    --builder)   BUILDER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--framework react|vue|angular|svelte] [--builder vite|webpack]"
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Check prerequisites ---
if [[ ! -f "package.json" ]]; then
  error "No package.json found. Run this from your project root."
  exit 1
fi

command -v npx >/dev/null 2>&1 || { error "npx not found. Install Node.js 18+."; exit 1; }

# --- Auto-detect framework ---
detect_framework() {
  local pkg
  pkg=$(cat package.json)

  if echo "$pkg" | grep -q '"@angular/core"'; then
    echo "angular"
  elif echo "$pkg" | grep -q '"svelte"'; then
    echo "svelte"
  elif echo "$pkg" | grep -q '"vue"'; then
    echo "vue"
  elif echo "$pkg" | grep -q '"react"'; then
    echo "react"
  else
    echo ""
  fi
}

if [[ -z "$FRAMEWORK" ]]; then
  log "Auto-detecting framework from package.json..."
  FRAMEWORK=$(detect_framework)
  if [[ -z "$FRAMEWORK" ]]; then
    error "Could not detect framework. Use --framework to specify."
    exit 1
  fi
  log "Detected framework: ${BLUE}${FRAMEWORK}${NC}"
fi

# --- Map framework to Storybook type ---
case "$FRAMEWORK" in
  react)
    if [[ "$BUILDER" == "webpack" ]]; then
      SB_TYPE="react-webpack5"
    else
      SB_TYPE="react-vite"
    fi
    ;;
  vue)
    if [[ "$BUILDER" == "webpack" ]]; then
      SB_TYPE="vue3-webpack5"
    else
      SB_TYPE="vue3-vite"
    fi
    ;;
  angular)
    SB_TYPE="angular"
    BUILDER="webpack"  # Angular uses webpack
    ;;
  svelte)
    if [[ "$BUILDER" == "webpack" ]]; then
      SB_TYPE="svelte-webpack5"
    else
      SB_TYPE="svelte-vite"
    fi
    ;;
  *)
    error "Unsupported framework: $FRAMEWORK (use react, vue, angular, or svelte)"
    exit 1
    ;;
esac

log "Initializing Storybook with type: ${BLUE}${SB_TYPE}${NC}"

# --- Initialize Storybook ---
npx storybook@latest init --type "$SB_TYPE" --yes 2>&1 | tail -5
log "Storybook initialized."

# --- Install common addons ---
log "Installing common addons..."
ADDONS=(
  "@storybook/addon-a11y"
  "@storybook/addon-interactions"
  "@storybook/test"
)

# Detect package manager
if [[ -f "pnpm-lock.yaml" ]]; then
  PM="pnpm"
elif [[ -f "yarn.lock" ]]; then
  PM="yarn"
elif [[ -f "bun.lockb" ]]; then
  PM="bun"
else
  PM="npm"
fi

log "Using package manager: ${BLUE}${PM}${NC}"

case "$PM" in
  pnpm) pnpm add -D "${ADDONS[@]}" ;;
  yarn) yarn add -D "${ADDONS[@]}" ;;
  bun)  bun add -D "${ADDONS[@]}" ;;
  npm)  npm install -D "${ADDONS[@]}" ;;
esac

# --- Update main.ts to include new addons ---
MAIN_FILE=".storybook/main.ts"
if [[ ! -f "$MAIN_FILE" ]]; then
  MAIN_FILE=".storybook/main.js"
fi

if [[ -f "$MAIN_FILE" ]]; then
  log "Updating $MAIN_FILE with addon configuration..."

  # Add a11y addon if not already present
  if ! grep -q "addon-a11y" "$MAIN_FILE"; then
    sed -i "s|'@storybook/addon-essentials'|'@storybook/addon-essentials',\n    '@storybook/addon-a11y',\n    '@storybook/addon-interactions'|" "$MAIN_FILE"
    log "Added a11y and interactions addons to config."
  fi

  # Add autodocs
  if ! grep -q "autodocs" "$MAIN_FILE"; then
    sed -i '/addons:/i\  docs: { autodocs: "tag" },' "$MAIN_FILE"
    log "Enabled autodocs."
  fi
fi

# --- Create example story ---
create_react_example() {
  local dir="src/stories"
  mkdir -p "$dir"
  cat > "$dir/Example.stories.tsx" << 'STORY_EOF'
import type { Meta, StoryObj } from '@storybook/react';

/**
 * Example component story — replace with your own components.
 * This demonstrates CSF3 format with args, argTypes, and play functions.
 */
const ExampleButton = ({ label, variant = 'primary', size = 'md', onClick }: {
  label: string;
  variant?: 'primary' | 'secondary' | 'danger';
  size?: 'sm' | 'md' | 'lg';
  onClick?: () => void;
}) => (
  <button
    className={`btn btn-${variant} btn-${size}`}
    onClick={onClick}
    style={{
      padding: size === 'sm' ? '4px 8px' : size === 'lg' ? '12px 24px' : '8px 16px',
      borderRadius: '6px',
      border: 'none',
      cursor: 'pointer',
      backgroundColor: variant === 'primary' ? '#0066FF' : variant === 'danger' ? '#DC2626' : '#6B7280',
      color: 'white',
      fontSize: size === 'sm' ? '12px' : size === 'lg' ? '18px' : '14px',
    }}
  >
    {label}
  </button>
);

const meta = {
  title: 'Example/Button',
  component: ExampleButton,
  tags: ['autodocs'],
  argTypes: {
    variant: { control: 'select', options: ['primary', 'secondary', 'danger'] },
    size: { control: 'radio', options: ['sm', 'md', 'lg'] },
    onClick: { action: 'clicked' },
  },
  parameters: { layout: 'centered' },
} satisfies Meta<typeof ExampleButton>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Primary: Story = {
  args: { label: 'Primary Button', variant: 'primary' },
};

export const Secondary: Story = {
  args: { label: 'Secondary', variant: 'secondary' },
};

export const Large: Story = {
  args: { ...Primary.args, size: 'lg', label: 'Large Button' },
};

export const Small: Story = {
  args: { ...Primary.args, size: 'sm', label: 'Small' },
};
STORY_EOF
  log "Created example React story at $dir/Example.stories.tsx"
}

create_vue_example() {
  local dir="src/stories"
  mkdir -p "$dir"
  cat > "$dir/Example.stories.ts" << 'STORY_EOF'
import type { Meta, StoryObj } from '@storybook/vue3';
import { h } from 'vue';

const ExampleButton = {
  props: {
    label: { type: String, required: true },
    variant: { type: String, default: 'primary' },
  },
  template: `<button :class="'btn-' + variant" @click="$emit('click')">{{ label }}</button>`,
};

const meta: Meta<typeof ExampleButton> = {
  title: 'Example/Button',
  component: ExampleButton,
  tags: ['autodocs'],
  argTypes: {
    variant: { control: 'select', options: ['primary', 'secondary'] },
  },
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Primary: Story = { args: { label: 'Primary Button', variant: 'primary' } };
export const Secondary: Story = { args: { label: 'Secondary', variant: 'secondary' } };
STORY_EOF
  log "Created example Vue story at $dir/Example.stories.ts"
}

case "$FRAMEWORK" in
  react)   create_react_example ;;
  vue)     create_vue_example ;;
  *)       log "Skipping example story for $FRAMEWORK (use generated ones)." ;;
esac

# --- Add npm scripts ---
log "Adding npm scripts..."
if command -v node >/dev/null 2>&1; then
  node -e "
    const pkg = JSON.parse(require('fs').readFileSync('package.json', 'utf8'));
    pkg.scripts = pkg.scripts || {};
    pkg.scripts['storybook'] = pkg.scripts['storybook'] || 'storybook dev -p 6006';
    pkg.scripts['build-storybook'] = pkg.scripts['build-storybook'] || 'storybook build';
    pkg.scripts['build-storybook:test'] = 'storybook build --test';
    pkg.scripts['test-storybook'] = 'test-storybook';
    require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
  "
  log "Added storybook scripts to package.json."
fi

# --- Summary ---
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN} Storybook initialized successfully!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Framework:  ${BLUE}${FRAMEWORK}${NC}"
echo -e "  Builder:    ${BLUE}${BUILDER}${NC}"
echo -e "  Type:       ${BLUE}${SB_TYPE}${NC}"
echo ""
echo -e "  ${YELLOW}Commands:${NC}"
echo -e "    ${PM} run storybook          # start dev server"
echo -e "    ${PM} run build-storybook    # production build"
echo -e "    ${PM} run test-storybook     # run interaction tests"
echo ""
