# Storybook 8.x API Reference

## Table of Contents

- [CSF3 Types](#csf3-types)
- [Meta Object](#meta-object)
- [StoryObj Properties](#storyobj-properties)
- [ArgTypes Specification](#argtypes-specification)
- [Decorator API](#decorator-api)
- [Play Function Utilities](#play-function-utilities)
- [Test-Runner API](#test-runner-api)
- [Configuration Files](#configuration-files)
- [Addon API](#addon-api)

---

## CSF3 Types

### Core Type Imports

```tsx
import type {
  Meta,           // Type for default export (component metadata)
  StoryObj,       // Type for named exports (individual stories)
  StoryFn,        // Function-style story type (legacy, rarely needed)
  StoryContext,   // Context object passed to decorators/play functions
  Args,           // Generic args type
  ArgTypes,       // ArgTypes configuration type
  Parameters,     // Parameters type
  Decorator,      // Decorator function type
  Loader,         // Loader function type
  Preview,        // Preview configuration type
} from '@storybook/react';  // or @storybook/vue3, @storybook/angular, etc.
```

### Type Patterns

```tsx
// Pattern 1: satisfies Meta (recommended)
const meta = {
  component: Button,
} satisfies Meta<typeof Button>;
export default meta;
type Story = StoryObj<typeof meta>;

// Pattern 2: explicit Meta type
const meta: Meta<typeof Button> = {
  component: Button,
};
export default meta;
type Story = StoryObj<typeof meta>;

// Pattern 3: Meta with custom args (when component props differ from story args)
type ButtonStoryArgs = ComponentProps<typeof Button> & {
  containerWidth?: number;
};
const meta = {
  component: Button,
} satisfies Meta<ButtonStoryArgs>;
```

---

## Meta Object

The default export configures all stories in a file.

```tsx
const meta = {
  // --- Required ---
  component: MyComponent,              // The component to render

  // --- Identity ---
  title: 'Category/Subcategory/Name',  // Manual sidebar path (auto-generated if omitted)
  tags: ['autodocs', 'stable'],        // Tags: 'autodocs' generates docs page

  // --- Shared Defaults ---
  args: {                              // Default prop values for all stories
    variant: 'primary',
    size: 'medium',
  },
  argTypes: { /* see ArgTypes section */ },
  parameters: { /* see Parameters below */ },

  // --- Rendering ---
  decorators: [/* see Decorator API */],
  render: (args) => <MyComponent {...args} />,  // Custom render for all stories
  component: MyComponent,
  subcomponents: { Icon, Badge },       // Show in docs alongside main component

  // --- Data & Setup ---
  loaders: [async () => ({ data: await fetchData() })],
  beforeEach: () => {
    // Setup before each story; return cleanup fn
    return () => { /* cleanup */ };
  },

  // --- Play ---
  play: async ({ canvasElement }) => {},  // Default play function
} satisfies Meta<typeof MyComponent>;
```

### Parameters (Common)

```tsx
parameters: {
  // Layout
  layout: 'centered' | 'padded' | 'fullscreen',

  // Backgrounds
  backgrounds: {
    default: 'light',
    values: [
      { name: 'light', value: '#ffffff' },
      { name: 'dark', value: '#1a1a1a' },
    ],
  },

  // Viewport
  viewport: {
    defaultViewport: 'iphone6',
  },

  // Docs
  docs: {
    description: { component: 'A reusable button component' },
    toc: true,                // Show table of contents
    canvas: { sourceState: 'shown' },  // Show source by default
  },

  // Controls
  controls: {
    expanded: true,           // Show full control descriptions
    sort: 'requiredFirst',    // 'alpha' | 'requiredFirst' | 'none'
    exclude: ['className'],   // Hide from controls
  },

  // Accessibility
  a11y: {
    config: {
      rules: [{ id: 'color-contrast', enabled: true }],
    },
    disable: false,
  },

  // Chromatic
  chromatic: {
    viewports: [375, 768, 1200],
    delay: 300,
    pauseAnimationAtEnd: true,
    disableSnapshot: false,
    diffThreshold: 0.063,
  },

  // MSW
  msw: {
    handlers: [/* ...request handlers */],
  },

  // Next.js
  nextjs: {
    appDirectory: true,
    navigation: { pathname: '/home', query: {} },
  },
},
```

---

## StoryObj Properties

Each named export is a story:

```tsx
export const MyStory: Story = {
  // --- Override Meta ---
  args: { label: 'Click' },            // Merge with meta.args
  argTypes: {},                          // Merge with meta.argTypes
  parameters: {},                        // Merge with meta.parameters
  decorators: [],                        // Prepended to meta.decorators
  loaders: [],                           // Prepended to meta.loaders
  tags: ['!autodocs'],                   // Override tags; '!' prefix removes

  // --- Rendering ---
  render: (args, context) => <MyComponent {...args} />,
  // `context` provides: loaded, globals, parameters, argTypes, id, viewMode

  // --- Interaction ---
  play: async (context) => {},

  // --- Setup ---
  beforeEach: () => () => {},

  // --- Naming ---
  name: 'Custom Display Name',          // Override in sidebar (default: export name)
};
```

---

## ArgTypes Specification

Control how args appear in Controls panel and Docs.

```tsx
argTypes: {
  // Text input
  label: {
    control: 'text',
    description: 'Button text content',
    table: {
      type: { summary: 'string' },
      defaultValue: { summary: 'Click me' },
      category: 'Content',              // Group in controls
    },
  },

  // Select dropdown
  variant: {
    control: 'select',
    options: ['primary', 'secondary', 'ghost', 'danger'],
    description: 'Visual style',
    table: {
      type: { summary: "'primary' | 'secondary' | 'ghost' | 'danger'" },
      defaultValue: { summary: 'primary' },
    },
    // Mapping: display label → actual value
    mapping: {
      Primary: 'primary',
      Secondary: 'secondary',
    },
  },

  // Boolean toggle
  disabled: {
    control: 'boolean',
  },

  // Number with range slider
  size: {
    control: { type: 'range', min: 10, max: 100, step: 5 },
  },

  // Color picker
  color: {
    control: 'color',
    presetColors: ['#ff0000', '#00ff00', '#0000ff'],
  },

  // Object editor (JSON)
  style: {
    control: 'object',
  },

  // Date picker
  createdAt: {
    control: 'date',
  },

  // File input
  avatar: {
    control: { type: 'file', accept: '.png,.jpg' },
  },

  // Radio buttons
  alignment: {
    control: 'inline-radio',
    options: ['left', 'center', 'right'],
  },

  // Multi-select checkboxes
  features: {
    control: 'inline-check',
    options: ['dark-mode', 'animations', 'sounds'],
  },

  // Action (logged in Actions panel)
  onClick: {
    action: 'clicked',
    table: { category: 'Events' },
  },

  // Hidden from controls
  id: {
    table: { disable: true },
  },

  // Readonly (shown in docs but not editable)
  version: {
    control: false,
    description: 'Component version',
    table: { type: { summary: 'string' } },
  },

  // Conditional visibility
  advancedMode: {
    control: 'boolean',
  },
  advancedOption: {
    control: 'text',
    if: { arg: 'advancedMode', truthy: true },  // Only show when advancedMode is true
  },
},
```

### Control Types Reference

| Type | Usage | Notes |
|------|-------|-------|
| `text` | Short strings | Default for `string` props |
| `boolean` | True/false toggle | Default for `boolean` props |
| `number` | Numeric input | Set `min`, `max`, `step` |
| `range` | Slider | Set `min`, `max`, `step` |
| `color` | Color picker | Returns hex string |
| `date` | Date picker | Returns timestamp (number) |
| `object` | JSON editor | For objects/arrays |
| `file` | File upload | Returns array of data URLs |
| `select` | Dropdown | Requires `options` |
| `multi-select` | Multi dropdown | Requires `options` |
| `radio` | Radio buttons | Requires `options` |
| `inline-radio` | Horizontal radios | Requires `options` |
| `check` | Checkboxes | Requires `options` |
| `inline-check` | Horizontal checks | Requires `options` |

---

## Decorator API

### Function Signature

```tsx
type Decorator = (
  story: StoryFn,         // The story render function — call as <Story /> (JSX) or story() (fn)
  context: StoryContext,  // Full story context
) => JSX.Element;
```

### StoryContext Shape

```tsx
interface StoryContext {
  args: Args;                  // Current arg values (reactive to Controls)
  argTypes: ArgTypes;          // ArgType definitions
  globals: Globals;            // Global values (theme, locale, etc.)
  parameters: Parameters;     // Story parameters
  hooks: HooksContext;         // Internal hook state
  id: string;                 // Story ID
  name: string;               // Story name
  title: string;              // Component title
  kind: string;               // Deprecated alias for title
  story: string;              // Deprecated alias for name
  viewMode: 'story' | 'docs'; // Current view mode
  loaded: Record<string, any>;// Data from loaders
  abortSignal: AbortSignal;   // Signal for cleanup
  canvasElement: HTMLElement;  // DOM root of the story
  step: StepFunction;         // For labeled play function steps
}
```

### Decorator Patterns

```tsx
// Read and use args
const withContainer = (Story: StoryFn, { args }: StoryContext) => (
  <div className={`container-${args.size}`}>
    <Story />
  </div>
);

// Modify args before passing to story
const withDefaults = (Story: StoryFn, context: StoryContext) => {
  const enhancedArgs = { ...context.args, theme: context.globals.theme };
  return <Story args={enhancedArgs} />;
};

// Conditional rendering
const withSuspense = (Story: StoryFn, { parameters }: StoryContext) => {
  if (parameters.suspense === false) return <Story />;
  return (
    <Suspense fallback={<div>Loading...</div>}>
      <Story />
    </Suspense>
  );
};
```

---

## Play Function Utilities

All from `@storybook/test`:

### within(element)

Creates a scoped Testing Library query object:

```tsx
import { within } from '@storybook/test';

play: async ({ canvasElement }) => {
  const canvas = within(canvasElement);
  const button = canvas.getByRole('button', { name: 'Submit' });
  // Scoped queries: getBy*, findBy*, queryBy*, getAllBy*, findAllBy*, queryAllBy*
},
```

### userEvent

Simulates real user interactions (fires all intermediate events):

```tsx
import { userEvent } from '@storybook/test';

// Typing
await userEvent.type(input, 'hello world');
await userEvent.clear(input);

// Clicking
await userEvent.click(button);
await userEvent.dblClick(element);
await userEvent.tripleClick(element);

// Keyboard
await userEvent.tab();
await userEvent.keyboard('{Enter}');
await userEvent.keyboard('{Shift>}A{/Shift}');  // Shift+A
await userEvent.keyboard('[ArrowDown][ArrowDown][Enter]');

// Selection
await userEvent.selectOptions(select, ['option1', 'option2']);
await userEvent.deselectOptions(select, ['option1']);

// File upload
await userEvent.upload(fileInput, file);
await userEvent.upload(fileInput, [file1, file2]);  // Multiple files

// Hover
await userEvent.hover(element);
await userEvent.unhover(element);

// Pointer (low-level)
await userEvent.pointer([
  { target: element, keys: '[MouseLeft>]' },  // mousedown
  { target: element, keys: '[/MouseLeft]' },  // mouseup
]);

// Clipboard
await userEvent.copy();
await userEvent.cut();
await userEvent.paste();
```

### expect

Vitest-compatible `expect` with DOM matchers:

```tsx
import { expect } from '@storybook/test';

// DOM assertions (jest-dom matchers)
expect(element).toBeInTheDocument();
expect(element).toBeVisible();
expect(element).toHaveTextContent('Hello');
expect(element).toHaveAttribute('aria-label', 'Close');
expect(element).toHaveClass('active');
expect(element).toHaveStyle({ color: 'red' });
expect(element).toBeDisabled();
expect(element).toBeEnabled();
expect(element).toHaveFocus();
expect(element).toBeChecked();
expect(element).toHaveValue('test');
expect(element).toContainElement(child);
expect(element).toBeEmptyDOMElement();
expect(element).toHaveFormValues({ email: 'test@test.com' });

// Standard matchers
expect(value).toBe(expected);
expect(value).toEqual(expected);
expect(value).toBeTruthy();
expect(value).toHaveLength(3);
expect(array).toContain(item);
expect(fn).toHaveBeenCalled();
expect(fn).toHaveBeenCalledTimes(2);
expect(fn).toHaveBeenCalledWith('arg1', 'arg2');
```

### waitFor

Retry an assertion until it passes or times out:

```tsx
import { waitFor } from '@storybook/test';

await waitFor(() => {
  expect(canvas.getByText('Loaded')).toBeInTheDocument();
});

// With options
await waitFor(
  () => expect(canvas.getByText('Done')).toBeInTheDocument(),
  {
    timeout: 5000,    // Max wait time (ms)
    interval: 100,    // Check interval (ms)
  }
);
```

### fn

Create spy/mock functions:

```tsx
import { fn, spyOn } from '@storybook/test';

// Create a mock function for args
const meta = {
  args: {
    onClick: fn(),
    onSubmit: fn().mockResolvedValue({ success: true }),
  },
};

// Spy on module exports
import * as api from '#lib/api';
spyOn(api, 'fetchUsers').mockResolvedValue([{ id: 1, name: 'Alice' }]);

// Assertions on mocks
expect(args.onClick).toHaveBeenCalled();
expect(args.onClick).toHaveBeenCalledTimes(1);
expect(args.onClick).toHaveBeenCalledWith(expect.objectContaining({ id: 1 }));
expect(args.onSubmit).toHaveBeenLastCalledWith({ email: 'test@test.com' });
```

### step

Label sections of play functions for the Interactions panel:

```tsx
play: async ({ canvasElement, step }) => {
  const canvas = within(canvasElement);

  await step('Enter credentials', async () => {
    await userEvent.type(canvas.getByLabelText('Email'), 'user@test.com');
    await userEvent.type(canvas.getByLabelText('Password'), 'password');
  });

  await step('Submit form', async () => {
    await userEvent.click(canvas.getByRole('button', { name: 'Login' }));
  });

  await step('Verify redirect', async () => {
    await waitFor(() => {
      expect(canvas.getByText('Welcome')).toBeInTheDocument();
    });
  });
},
```

### fireEvent

Lower-level event dispatch (prefer `userEvent` for realistic simulation):

```tsx
import { fireEvent } from '@storybook/test';

fireEvent.click(element);
fireEvent.change(input, { target: { value: 'new value' } });
fireEvent.submit(form);
fireEvent.keyDown(element, { key: 'Enter', code: 'Enter' });
fireEvent.focus(element);
fireEvent.blur(element);
fireEvent.scroll(element, { target: { scrollTop: 100 } });

// Drag events
fireEvent.dragStart(element);
fireEvent.dragOver(dropZone);
fireEvent.drop(dropZone, { dataTransfer: { files: [file] } });
fireEvent.dragEnd(element);
```

---

## Test-Runner API

### Configuration File

`.storybook/test-runner.ts`:

```ts
import type { TestRunnerConfig } from '@storybook/test-runner';

const config: TestRunnerConfig = {
  /** Runs once before all tests */
  setup() {
    // e.g., extend expect with custom matchers
  },

  /** Runs before navigating to each story */
  async preVisit(page, context) {
    // page: Playwright Page object
    // context: { id, title, name }
  },

  /** Runs after each story renders (and play function completes) */
  async postVisit(page, context) {
    // Common: accessibility checks, screenshot comparisons
    // page.screenshot(), page.$('#storybook-root')
  },

  /** Custom tags filter */
  tags: {
    include: ['test'],
    exclude: ['no-test'],
    skip: ['skip-test'],
  },

  /** Override story URL */
  getHttpHeaders: async (url) => ({
    Authorization: 'Bearer token',
  }),
};

export default config;
```

### Accessibility Testing in postVisit

```ts
import { injectAxe, checkA11y } from 'axe-playwright';

const config: TestRunnerConfig = {
  async preVisit(page) {
    await injectAxe(page);
  },
  async postVisit(page) {
    await checkA11y(page, '#storybook-root', {
      detailedReport: true,
      detailedReportOptions: { html: true },
    });
  },
};
```

### Visual Snapshot Testing in postVisit

```ts
import { toMatchImageSnapshot } from 'jest-image-snapshot';

const config: TestRunnerConfig = {
  setup() {
    expect.extend({ toMatchImageSnapshot });
  },
  async postVisit(page) {
    const image = await page.locator('#storybook-root').screenshot();
    expect(image).toMatchImageSnapshot({
      failureThreshold: 0.03,
      failureThresholdType: 'percent',
    });
  },
};
```

### CLI Options

```bash
npx test-storybook                          # Run all story tests
npx test-storybook --url http://localhost:6006  # Custom Storybook URL
npx test-storybook --browsers chromium firefox  # Multi-browser
npx test-storybook --coverage                   # With coverage
npx test-storybook --maxWorkers=2               # Limit parallelism
npx test-storybook --testTimeout=60000          # Increase timeout
npx test-storybook --shard=1/3                  # Shard for CI
npx test-storybook --failOnConsole              # Fail on console.error
npx test-storybook --stories-json               # Use pre-built index
npx test-storybook --index-json                 # Use index.json
```

---

## Configuration Files

### .storybook/main.ts

```ts
import type { StorybookConfig } from '@storybook/react-vite';

const config: StorybookConfig = {
  // --- Required ---
  framework: {
    name: '@storybook/react-vite',  // Framework package
    options: {},
  },
  stories: [
    '../src/**/*.stories.@(ts|tsx)',
    '../src/**/*.mdx',
  ],

  // --- Addons ---
  addons: [
    '@storybook/addon-essentials',    // Controls, Actions, Viewport, Backgrounds, Docs
    '@storybook/addon-a11y',          // Accessibility panel
    '@storybook/addon-interactions',  // Interactions panel (play fn debugger)
    '@chromatic-com/storybook',       // Chromatic visual testing
  ],

  // --- Build ---
  staticDirs: ['../public'],
  core: {
    disableTelemetry: true,
  },

  // --- TypeScript ---
  typescript: {
    reactDocgen: 'react-docgen-typescript',
    reactDocgenTypescriptOptions: {
      shouldExtractLiteralValuesFromEnum: true,
      propFilter: (prop) => !prop.parent?.fileName?.includes('node_modules'),
    },
  },

  // --- Builder Customization ---
  async viteFinal(config, { configType }) {
    const { mergeConfig } = await import('vite');
    return mergeConfig(config, {
      resolve: {
        alias: { '@': path.resolve(__dirname, '../src') },
      },
    });
  },

  // OR for Webpack:
  async webpackFinal(config) {
    config.resolve!.alias = {
      ...config.resolve!.alias,
      '@': path.resolve(__dirname, '../src'),
    };
    return config;
  },

  // --- Docs ---
  docs: {
    defaultName: 'Documentation',     // Rename docs page in sidebar
  },

  // --- Composition ---
  refs: {
    'design-system': {
      title: 'Design System',
      url: 'https://ds.example.com/storybook',
    },
  },
};

export default config;
```

### .storybook/preview.ts

```ts
import type { Preview } from '@storybook/react';
import '../src/styles/globals.css';

const preview: Preview = {
  // --- Global Args ---
  args: {},
  argTypes: {},

  // --- Global Parameters ---
  parameters: {
    layout: 'centered',
    controls: { expanded: true, sort: 'requiredFirst' },
    backgrounds: {
      default: 'light',
      values: [
        { name: 'light', value: '#fff' },
        { name: 'dark', value: '#1a1a1a' },
      ],
    },
    viewport: {
      viewports: {
        mobile: { name: 'Mobile', styles: { width: '375px', height: '812px' } },
        tablet: { name: 'Tablet', styles: { width: '768px', height: '1024px' } },
        desktop: { name: 'Desktop', styles: { width: '1440px', height: '900px' } },
      },
    },
  },

  // --- Global Decorators ---
  decorators: [
    (Story) => (
      <div style={{ fontFamily: 'system-ui, sans-serif' }}>
        <Story />
      </div>
    ),
  ],

  // --- Loaders ---
  loaders: [],

  // --- Global Types (toolbar controls) ---
  globalTypes: {
    theme: {
      description: 'Global theme',
      toolbar: {
        title: 'Theme',
        icon: 'circlehollow',
        items: ['light', 'dark'],
        dynamicTitle: true,
      },
    },
  },

  // --- Tags ---
  tags: ['autodocs'],

  // --- Lifecycle ---
  beforeAll: async () => {},
  beforeEach: () => () => {},
};

export default preview;
```

---

## Addon API

### Writing a Custom Addon

```ts
// my-addon/src/manager.ts
import { addons, types } from '@storybook/manager-api';
import { AddonPanel } from '@storybook/components';

const ADDON_ID = 'my-addon';
const PANEL_ID = `${ADDON_ID}/panel`;

addons.register(ADDON_ID, (api) => {
  addons.add(PANEL_ID, {
    type: types.PANEL,
    title: 'My Panel',
    match: ({ viewMode }) => viewMode === 'story',
    render: ({ active }) => (
      <AddonPanel active={!!active}>
        <div>Panel content</div>
      </AddonPanel>
    ),
  });
});
```

### Addon Types

| Type | Constant | Description |
|------|----------|-------------|
| Panel | `types.PANEL` | Tab in the addons panel |
| Tool | `types.TOOL` | Button in the toolbar |
| Tab | `types.TAB` | Full-page tab |
| Preview | `types.PREVIEW` | Wraps the story preview iframe |

### Communicating Between Manager and Preview

```ts
// In manager (addon panel)
import { useChannel } from '@storybook/manager-api';

const emit = useChannel({
  'my-addon/event': (data) => { /* handle response */ },
});
emit('my-addon/request', { key: 'value' });

// In preview (decorator)
import { useChannel } from '@storybook/preview-api';

const emit = useChannel({
  'my-addon/request': (data) => {
    emit('my-addon/event', { result: 'ok' });
  },
});
```
