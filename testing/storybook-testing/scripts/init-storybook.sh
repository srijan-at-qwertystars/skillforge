#!/usr/bin/env bash
# init-storybook.sh — Initialize Storybook with best practices
#
# Usage:
#   ./init-storybook.sh [--framework react-vite|nextjs|vue3-vite|angular|svelte-vite]
#
# What it does:
#   1. Detects or uses specified framework
#   2. Initializes Storybook via npx storybook@latest init
#   3. Installs recommended addons
#   4. Creates example story files
#   5. Adds npm scripts
#
# Prerequisites: Node.js 18+, npm, an existing project with package.json

set -euo pipefail

FRAMEWORK="${1:---framework}"
FRAMEWORK_VALUE="${2:-}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[storybook-init]${NC} $*"; }
warn() { echo -e "${YELLOW}[storybook-init]${NC} $*"; }
err()  { echo -e "${RED}[storybook-init]${NC} $*" >&2; }

# --- Preflight checks ---
if [ ! -f "package.json" ]; then
  err "No package.json found. Run this from your project root."
  exit 1
fi

if ! command -v node &>/dev/null; then
  err "Node.js is required. Install Node 18+."
  exit 1
fi

NODE_MAJOR=$(node -e "console.log(process.version.split('.')[0].slice(1))")
if [ "$NODE_MAJOR" -lt 18 ]; then
  err "Node 18+ required. Found Node $NODE_MAJOR."
  exit 1
fi

# --- Detect framework ---
detect_framework() {
  if [ -n "$FRAMEWORK_VALUE" ]; then
    echo "$FRAMEWORK_VALUE"
    return
  fi

  if grep -q '"next"' package.json 2>/dev/null; then
    echo "nextjs"
  elif grep -q '"@angular/core"' package.json 2>/dev/null; then
    echo "angular"
  elif grep -q '"svelte"' package.json 2>/dev/null; then
    echo "svelte-vite"
  elif grep -q '"vue"' package.json 2>/dev/null; then
    echo "vue3-vite"
  elif grep -q '"vite"' package.json 2>/dev/null; then
    echo "react-vite"
  else
    echo "react-vite"
  fi
}

DETECTED_FRAMEWORK=$(detect_framework)
log "Detected framework: $DETECTED_FRAMEWORK"

# --- Map to Storybook package ---
case "$DETECTED_FRAMEWORK" in
  react-vite)    SB_FRAMEWORK="@storybook/react-vite" ;;
  nextjs)        SB_FRAMEWORK="@storybook/nextjs" ;;
  vue3-vite)     SB_FRAMEWORK="@storybook/vue3-vite" ;;
  angular)       SB_FRAMEWORK="@storybook/angular" ;;
  svelte-vite)   SB_FRAMEWORK="@storybook/svelte-vite" ;;
  *)
    err "Unknown framework: $DETECTED_FRAMEWORK"
    err "Supported: react-vite, nextjs, vue3-vite, angular, svelte-vite"
    exit 1
    ;;
esac

# --- Step 1: Initialize Storybook ---
log "Initializing Storybook..."
npx storybook@latest init --yes --type "$DETECTED_FRAMEWORK" 2>&1 || {
  warn "Auto-init failed. Trying manual setup..."
  npm install -D storybook "$SB_FRAMEWORK"
  npx storybook init --yes
}

# --- Step 2: Install recommended addons ---
log "Installing recommended addons..."
npm install -D \
  @storybook/addon-essentials \
  @storybook/addon-a11y \
  @storybook/addon-interactions \
  @storybook/test \
  @storybook/test-runner \
  @chromatic-com/storybook \
  2>&1

# --- Step 3: Install MSW for API mocking ---
log "Installing MSW for API mocking..."
npm install -D msw msw-storybook-addon 2>&1
if [ -d "public" ]; then
  npx msw init public/ --save 2>&1 || warn "MSW init skipped (may need manual setup)"
fi

# --- Step 4: Install Playwright for test-runner ---
log "Installing Playwright browsers..."
npx playwright install --with-deps chromium 2>&1 || warn "Playwright install skipped"

# --- Step 5: Add npm scripts ---
log "Adding npm scripts..."
node -e "
const pkg = require('./package.json');
pkg.scripts = pkg.scripts || {};
pkg.scripts['storybook'] = pkg.scripts['storybook'] || 'storybook dev -p 6006';
pkg.scripts['build-storybook'] = pkg.scripts['build-storybook'] || 'storybook build';
pkg.scripts['test-storybook'] = 'test-storybook';
pkg.scripts['test-storybook:ci'] = 'concurrently -k -s first \"npx http-server storybook-static -p 6006 --silent\" \"npx wait-on tcp:6006 && npx test-storybook --maxWorkers=2\"';
require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"

# --- Step 6: Create example story ---
log "Creating example stories..."

# Determine src dir
SRC_DIR="src"
[ -d "$SRC_DIR" ] || SRC_DIR="."

STORIES_DIR="$SRC_DIR/stories"
mkdir -p "$STORIES_DIR"

if [[ "$DETECTED_FRAMEWORK" == *"vue"* ]]; then
  cat > "$STORIES_DIR/ExampleButton.stories.ts" << 'STORY_EOF'
import type { Meta, StoryObj } from '@storybook/vue3';
import ExampleButton from './ExampleButton.vue';

const meta = {
  component: ExampleButton,
  title: 'Example/Button',
  tags: ['autodocs'],
  argTypes: {
    variant: { control: 'select', options: ['primary', 'secondary', 'ghost'] },
    size: { control: 'radio', options: ['small', 'medium', 'large'] },
    disabled: { control: 'boolean' },
  },
} satisfies Meta<typeof ExampleButton>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Primary: Story = {
  args: { label: 'Click me', variant: 'primary', size: 'medium' },
};

export const Secondary: Story = {
  args: { label: 'Secondary', variant: 'secondary', size: 'medium' },
};

export const Disabled: Story = {
  args: { label: 'Disabled', variant: 'primary', disabled: true },
};
STORY_EOF
  log "Created $STORIES_DIR/ExampleButton.stories.ts (Vue)"
else
  cat > "$STORIES_DIR/ExampleButton.stories.tsx" << 'STORY_EOF'
import type { Meta, StoryObj } from '@storybook/react';
import { expect, fn, userEvent, within } from '@storybook/test';

// Inline component for self-contained example
function ExampleButton({
  label = 'Button',
  variant = 'primary',
  size = 'medium',
  disabled = false,
  onClick,
}: {
  label?: string;
  variant?: 'primary' | 'secondary' | 'ghost';
  size?: 'small' | 'medium' | 'large';
  disabled?: boolean;
  onClick?: () => void;
}) {
  const baseStyles: React.CSSProperties = {
    border: 'none',
    borderRadius: '6px',
    cursor: disabled ? 'not-allowed' : 'pointer',
    fontWeight: 600,
    opacity: disabled ? 0.5 : 1,
  };

  const sizes = { small: '8px 12px', medium: '10px 20px', large: '14px 28px' };
  const variants = {
    primary: { background: '#2563eb', color: '#fff' },
    secondary: { background: '#e5e7eb', color: '#1f2937' },
    ghost: { background: 'transparent', color: '#2563eb', border: '1px solid #2563eb' },
  };

  return (
    <button
      style={{ ...baseStyles, padding: sizes[size], ...variants[variant] }}
      disabled={disabled}
      onClick={onClick}
    >
      {label}
    </button>
  );
}

const meta = {
  component: ExampleButton,
  title: 'Example/Button',
  tags: ['autodocs'],
  args: { onClick: fn() },
  argTypes: {
    variant: { control: 'select', options: ['primary', 'secondary', 'ghost'] },
    size: { control: 'radio', options: ['small', 'medium', 'large'] },
    disabled: { control: 'boolean' },
    label: { control: 'text' },
  },
} satisfies Meta<typeof ExampleButton>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Primary: Story = {
  args: { label: 'Click me', variant: 'primary', size: 'medium' },
};

export const Secondary: Story = {
  args: { label: 'Secondary', variant: 'secondary' },
};

export const Ghost: Story = {
  args: { label: 'Ghost', variant: 'ghost' },
};

export const Disabled: Story = {
  args: { label: 'Disabled', variant: 'primary', disabled: true },
};

/** Interaction test: verifies click handler fires */
export const ClickTest: Story = {
  args: { label: 'Click me' },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement);
    await userEvent.click(canvas.getByRole('button'));
    await expect(args.onClick).toHaveBeenCalledTimes(1);
  },
};
STORY_EOF
  log "Created $STORIES_DIR/ExampleButton.stories.tsx (React)"
fi

# --- Done ---
log ""
log "✅ Storybook initialized successfully!"
log ""
log "Next steps:"
log "  npm run storybook           # Start dev server"
log "  npm run build-storybook     # Build static site"
log "  npm run test-storybook      # Run interaction tests (requires running Storybook)"
log ""
