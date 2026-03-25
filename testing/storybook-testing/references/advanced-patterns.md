# Storybook 8.x Advanced Patterns

## Table of Contents

- [Complex Decorator Composition](#complex-decorator-composition)
- [Portable Stories](#portable-stories)
- [Story Indexer](#story-indexer)
- [Custom Render Functions](#custom-render-functions)
- [Advanced Play Function Patterns](#advanced-play-function-patterns)
- [Storybook Test Hooks](#storybook-test-hooks)
- [MSW Integration Deep-Dive](#msw-integration-deep-dive)
- [Module Mocking](#module-mocking)
- [Viewport & Theme Testing](#viewport--theme-testing)
- [Storybook for Design Systems](#storybook-for-design-systems)

---

## Complex Decorator Composition

### Multi-Layer Provider Stacking

Decorators execute outermost-first. Order matters when providers depend on each other.

```tsx
// .storybook/preview.tsx
import type { Preview } from '@storybook/react';

const preview: Preview = {
  decorators: [
    // Layer 1 (outermost): Error boundary
    (Story) => (
      <ErrorBoundary fallback={<div>Error</div>}>
        <Story />
      </ErrorBoundary>
    ),
    // Layer 2: Theme provider (reads from globals toolbar)
    (Story, context) => {
      const theme = context.globals.theme === 'dark' ? darkTheme : lightTheme;
      return (
        <ThemeProvider theme={theme}>
          <Story />
        </ThemeProvider>
      );
    },
    // Layer 3: Internationalization
    (Story, context) => (
      <I18nProvider locale={context.globals.locale || 'en'}>
        <Story />
      </I18nProvider>
    ),
    // Layer 4 (innermost): Layout wrapper
    (Story) => (
      <div style={{ margin: '1rem', fontFamily: 'sans-serif' }}>
        <Story />
      </div>
    ),
  ],
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
    locale: {
      description: 'Locale',
      toolbar: {
        title: 'Locale',
        icon: 'globe',
        items: ['en', 'fr', 'de', 'ja'],
        dynamicTitle: true,
      },
    },
  },
};
export default preview;
```

### Conditional Decorators

Apply decorators based on story parameters or tags:

```tsx
const withAuth = (Story: StoryFn, context: StoryContext) => {
  if (context.parameters.auth === false) return <Story />;
  return (
    <AuthProvider user={context.parameters.authUser ?? mockUser}>
      <Story />
    </AuthProvider>
  );
};

const meta = {
  component: Dashboard,
  decorators: [withAuth],
  parameters: { auth: true, authUser: { name: 'Alice', role: 'admin' } },
} satisfies Meta<typeof Dashboard>;

export const Unauthenticated: Story = {
  parameters: { auth: false },
};
```

### Args-Reactive Decorators

Read args dynamically so Controls panel changes re-render the decorator:

```tsx
const meta = {
  component: Card,
  args: { elevated: false },
  decorators: [
    (Story, { args }) => (
      <div style={{
        background: args.elevated ? '#f0f0f0' : '#fff',
        padding: '2rem',
        borderRadius: '8px',
      }}>
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof Card>;
```

---

## Portable Stories

Portable stories let you reuse Storybook stories in external test runners (Vitest, Jest).

### Setup for Vitest

```ts
// vitest.setup.ts
import { setProjectAnnotations } from '@storybook/react';
import * as previewAnnotations from './.storybook/preview';

setProjectAnnotations(previewAnnotations);
```

### Running Stories in Vitest

```tsx
import { composeStories } from '@storybook/react';
import { render, screen } from '@testing-library/react';
import * as stories from './LoginForm.stories';

const { SuccessfulLogin, ValidationError } = composeStories(stories);

test('successful login submits form', async () => {
  const { container } = render(<SuccessfulLogin />);
  await SuccessfulLogin.play!({ canvasElement: container });
  // Additional assertions beyond what the play function checks
  expect(screen.queryByText('Error')).not.toBeInTheDocument();
});

test('shows validation error', async () => {
  const { container } = render(<ValidationError />);
  await ValidationError.play!({ canvasElement: container });
});
```

### Composing Stories Across Files

```tsx
import { composeStories } from '@storybook/react';
import * as loginStories from './LoginForm.stories';
import * as dashboardStories from './Dashboard.stories';

const { SuccessfulLogin } = composeStories(loginStories);
const { WithData } = composeStories(dashboardStories);

// Chain: login → then verify dashboard loads
export const PostLoginDashboard: Story = {
  play: async (context) => {
    await SuccessfulLogin.play!(context);
    // Navigation happened, now verify dashboard
    await WithData.play!(context);
  },
};
```

### composeStory for Single Stories

```tsx
import { composeStory } from '@storybook/react';
import meta, { Primary } from './Button.stories';

const PrimaryButton = composeStory(Primary, meta);

test('renders primary button', () => {
  render(<PrimaryButton />);
  expect(screen.getByRole('button')).toHaveClass('btn-primary');
});
```

---

## Story Indexer

Custom story indexers control how Storybook discovers and indexes stories. Defined in `.storybook/main.ts`:

```ts
// .storybook/main.ts
import type { StorybookConfig } from '@storybook/react-vite';

const config: StorybookConfig = {
  stories: ['../src/**/*.stories.@(ts|tsx)'],
  experimental_indexers: (existingIndexers) => {
    const customIndexer = {
      test: /\.custom-stories\.[jt]sx?$/,
      createIndex: async (fileName, { makeTitle }) => {
        // Parse the file and return story entries
        const source = await readFile(fileName, 'utf-8');
        const parsed = parseCustomFormat(source);
        return parsed.stories.map((story) => ({
          type: 'story',
          importPath: fileName,
          exportName: story.name,
          title: makeTitle(story.title),
          tags: story.tags ?? ['autodocs'],
        }));
      },
    };
    return [...existingIndexers, customIndexer];
  },
};
export default config;
```

Use cases:
- Generate stories from design tokens or Figma exports
- Create stories from data files (JSON/YAML)
- Support custom DSLs for story definition

---

## Custom Render Functions

Override how stories render for advanced layouts, multi-component scenarios, or portals:

```tsx
// Render two variants side-by-side for comparison
export const Comparison: Story = {
  render: (args) => (
    <div style={{ display: 'flex', gap: '2rem' }}>
      <div>
        <h3>Light</h3>
        <ThemeProvider theme="light"><Button {...args} /></ThemeProvider>
      </div>
      <div>
        <h3>Dark</h3>
        <ThemeProvider theme="dark"><Button {...args} /></ThemeProvider>
      </div>
    </div>
  ),
  args: { label: 'Click me', variant: 'primary' },
};

// Render with portal target
export const WithModal: Story = {
  render: (args) => (
    <>
      <div id="modal-root" />
      <ModalTrigger {...args} portalTarget="#modal-root" />
    </>
  ),
};

// Render with state (using hooks inside render)
export const Controlled: Story = {
  render: function Render(args) {
    const [value, setValue] = useState(args.defaultValue ?? '');
    return (
      <TextInput
        {...args}
        value={value}
        onChange={(e) => setValue(e.target.value)}
      />
    );
  },
};
```

### Framework-Specific Custom Renders

**Vue 3:**
```ts
export const WithSlots: Story = {
  render: (args) => ({
    components: { DataTable },
    setup: () => ({ args }),
    template: `
      <DataTable v-bind="args">
        <template #header>Custom Header</template>
        <template #cell="{ item }">{{ item.name }}</template>
      </DataTable>
    `,
  }),
};
```

**Angular:**
```ts
export const WithDI: Story = {
  render: (args) => ({
    props: args,
    template: `<app-user-card [user]="user" (click)="onClick($event)"></app-user-card>`,
    moduleMetadata: {
      providers: [{ provide: UserService, useValue: mockUserService }],
    },
  }),
};
```

---

## Advanced Play Function Patterns

### Multi-Step Interactions

```tsx
export const MultiStepWizard: Story = {
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement);

    await step('Fill personal info', async () => {
      await userEvent.type(canvas.getByLabelText('Name'), 'Alice');
      await userEvent.type(canvas.getByLabelText('Email'), 'alice@test.com');
      await userEvent.click(canvas.getByRole('button', { name: 'Next' }));
    });

    await step('Select plan', async () => {
      await userEvent.click(canvas.getByLabelText('Pro Plan'));
      await userEvent.click(canvas.getByRole('button', { name: 'Next' }));
    });

    await step('Confirm and submit', async () => {
      await expect(canvas.getByText('Alice')).toBeInTheDocument();
      await expect(canvas.getByText('Pro Plan')).toBeInTheDocument();
      await userEvent.click(canvas.getByRole('button', { name: 'Submit' }));
    });

    await step('Verify success', async () => {
      await waitFor(() => {
        expect(canvas.getByText('Registration complete')).toBeInTheDocument();
      });
    });
  },
};
```

### Drag-and-Drop Simulation

```tsx
import { fireEvent } from '@storybook/test';

export const DragAndDrop: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const dragItem = canvas.getByTestId('drag-item-1');
    const dropZone = canvas.getByTestId('drop-zone');

    // Simulate HTML5 drag-and-drop via events
    await fireEvent.dragStart(dragItem);
    await fireEvent.dragEnter(dropZone);
    await fireEvent.dragOver(dropZone);
    await fireEvent.drop(dropZone, {
      dataTransfer: {
        getData: () => JSON.stringify({ id: 1, label: 'Item 1' }),
      },
    });
    await fireEvent.dragEnd(dragItem);

    await expect(
      within(dropZone).getByText('Item 1')
    ).toBeInTheDocument();
  },
};
```

### File Upload Simulation

```tsx
export const FileUpload: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const fileInput = canvas.getByLabelText('Upload file');

    const file = new File(['file content'], 'report.pdf', {
      type: 'application/pdf',
    });

    await userEvent.upload(fileInput, file);

    await waitFor(() => {
      expect(canvas.getByText('report.pdf')).toBeInTheDocument();
    });
  },
};

// Drop zone file upload
export const DropZoneUpload: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const dropZone = canvas.getByTestId('file-drop-zone');

    const file = new File(['image data'], 'photo.png', { type: 'image/png' });

    await fireEvent.drop(dropZone, {
      dataTransfer: { files: [file] },
    });

    await waitFor(() => {
      expect(canvas.getByText('photo.png')).toBeInTheDocument();
    });
  },
};
```

### Keyboard Navigation Testing

```tsx
export const KeyboardNav: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);

    // Tab through interactive elements
    await userEvent.tab();
    expect(canvas.getByRole('menuitem', { name: 'File' })).toHaveFocus();

    await userEvent.tab();
    expect(canvas.getByRole('menuitem', { name: 'Edit' })).toHaveFocus();

    // Open submenu with Enter
    await userEvent.keyboard('{Enter}');
    await waitFor(() => {
      expect(canvas.getByRole('menu', { name: 'Edit' })).toBeVisible();
    });

    // Navigate submenu with arrows
    await userEvent.keyboard('{ArrowDown}');
    expect(canvas.getByRole('menuitem', { name: 'Undo' })).toHaveFocus();

    // Escape closes
    await userEvent.keyboard('{Escape}');
    await waitFor(() => {
      expect(canvas.queryByRole('menu', { name: 'Edit' })).not.toBeInTheDocument();
    });
  },
};
```

### Waiting for Async Operations

```tsx
export const AsyncDataLoad: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);

    // Assert loading state shows first
    expect(canvas.getByText('Loading...')).toBeInTheDocument();

    // Wait for data to resolve (MSW or mocked fetch)
    await waitFor(
      () => {
        expect(canvas.getByText('Alice')).toBeInTheDocument();
      },
      { timeout: 5000 }
    );

    // Loading indicator should be gone
    expect(canvas.queryByText('Loading...')).not.toBeInTheDocument();
  },
};
```

---

## Storybook Test Hooks

### beforeEach / Cleanup

`beforeEach` runs before every story render. Return a cleanup function for teardown:

```tsx
import { spyOn, fn } from '@storybook/test';
import * as api from '#lib/api';

const meta = {
  component: UserList,
  beforeEach: () => {
    // Mock API call
    const fetchSpy = spyOn(api, 'fetchUsers').mockResolvedValue([
      { id: 1, name: 'Alice' },
      { id: 2, name: 'Bob' },
    ]);

    // Mock window methods
    const scrollSpy = spyOn(window, 'scrollTo').mockImplementation(() => {});

    // Cleanup runs after story unmounts
    return () => {
      fetchSpy.mockRestore();
      scrollSpy.mockRestore();
    };
  },
} satisfies Meta<typeof UserList>;
```

### beforeAll (Global Setup)

Runs once before all stories. Defined in `preview.ts` or component meta:

```ts
// .storybook/preview.ts
import { initialize } from 'msw-storybook-addon';

const preview: Preview = {
  beforeAll: async () => {
    initialize({ onUnhandledRequest: 'bypass' });
  },
};
```

### Scoping Hooks

Hooks follow Storybook's hierarchy:
1. **Global** (`preview.ts`) → runs for all stories
2. **Component** (meta `beforeEach`) → runs for all stories in the file
3. **Story** (story-level `beforeEach`) → runs for that story only

All cleanup functions execute in reverse order after the story unmounts.

---

## MSW Integration Deep-Dive

### Setup with Storybook 8

```bash
npm i -D msw@2 msw-storybook-addon@2
npx msw init public/
```

```ts
// .storybook/preview.ts
import { initialize, mswLoader } from 'msw-storybook-addon';

initialize({
  onUnhandledRequest: 'bypass',     // Don't warn on non-mocked requests
  serviceWorker: { url: '/mockServiceWorker.js' },
});

const preview: Preview = {
  loaders: [mswLoader],
};
export default preview;
```

### Handler Composition Strategy

```tsx
// src/mocks/handlers.ts — shared handlers
import { http, HttpResponse } from 'msw';

export const userHandlers = [
  http.get('/api/users', () =>
    HttpResponse.json([
      { id: 1, name: 'Alice', role: 'admin' },
      { id: 2, name: 'Bob', role: 'user' },
    ])
  ),
  http.get('/api/users/:id', ({ params }) =>
    HttpResponse.json({ id: params.id, name: 'Alice', role: 'admin' })
  ),
];

export const errorHandlers = [
  http.get('/api/users', () =>
    HttpResponse.json({ message: 'Internal Server Error' }, { status: 500 })
  ),
];

export const emptyHandlers = [
  http.get('/api/users', () => HttpResponse.json([])),
];
```

```tsx
// UserList.stories.tsx
import { userHandlers, errorHandlers, emptyHandlers } from '../mocks/handlers';

const meta = {
  component: UserList,
  parameters: { msw: { handlers: userHandlers } },  // default: success
} satisfies Meta<typeof UserList>;

export const Default: Story = {};

export const Error: Story = {
  parameters: { msw: { handlers: errorHandlers } },
};

export const Empty: Story = {
  parameters: { msw: { handlers: emptyHandlers } },
};

export const Loading: Story = {
  parameters: {
    msw: {
      handlers: [
        http.get('/api/users', async () => {
          await new Promise((r) => setTimeout(r, 999999));
          return HttpResponse.json([]);
        }),
      ],
    },
  },
};
```

### GraphQL Mocking

```tsx
import { graphql, HttpResponse } from 'msw';

export const WithGraphQL: Story = {
  parameters: {
    msw: {
      handlers: [
        graphql.query('GetUsers', () =>
          HttpResponse.json({
            data: { users: [{ id: '1', name: 'Alice' }] },
          })
        ),
        graphql.mutation('CreateUser', ({ variables }) =>
          HttpResponse.json({
            data: { createUser: { id: '3', name: variables.name } },
          })
        ),
      ],
    },
  },
};
```

---

## Module Mocking

### Subpath Imports (Recommended)

```jsonc
// package.json
{
  "imports": {
    "#lib/analytics": {
      "storybook": "./src/lib/analytics.mock.ts",
      "default": "./src/lib/analytics.ts"
    },
    "#lib/auth": {
      "storybook": "./src/lib/auth.mock.ts",
      "default": "./src/lib/auth.ts"
    },
    "#lib/feature-flags": {
      "storybook": "./src/lib/feature-flags.mock.ts",
      "default": "./src/lib/feature-flags.ts"
    }
  }
}
```

```ts
// src/lib/analytics.mock.ts
import { fn } from '@storybook/test';

export const track = fn().mockName('analytics.track');
export const identify = fn().mockName('analytics.identify');
export const pageView = fn().mockName('analytics.pageView');
```

### Per-Story Mock Overrides

```tsx
import { track } from '#lib/analytics';

const meta = {
  component: CheckoutButton,
  beforeEach: () => {
    // Reset to default mock
    (track as any).mockClear();
  },
} satisfies Meta<typeof CheckoutButton>;

export const TracksClick: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await userEvent.click(canvas.getByRole('button'));
    expect(track).toHaveBeenCalledWith('checkout_clicked', { source: 'button' });
  },
};
```

---

## Viewport & Theme Testing

### Custom Viewport Definitions

```ts
// .storybook/preview.ts
const preview: Preview = {
  parameters: {
    viewport: {
      viewports: {
        mobile: { name: 'Mobile', styles: { width: '375px', height: '812px' } },
        tablet: { name: 'Tablet', styles: { width: '768px', height: '1024px' } },
        desktop: { name: 'Desktop', styles: { width: '1440px', height: '900px' } },
      },
    },
  },
};
```

### Responsive Stories

```tsx
export const Mobile: Story = {
  parameters: { viewport: { defaultViewport: 'mobile' }, layout: 'fullscreen' },
};

export const Tablet: Story = {
  parameters: { viewport: { defaultViewport: 'tablet' }, layout: 'fullscreen' },
};

// Chromatic captures at multiple viewports
export const AllBreakpoints: Story = {
  parameters: {
    chromatic: { viewports: [375, 768, 1440] },
  },
};
```

### Theme Switching via Globals

```tsx
// Decorator that reads globals.theme
const withTheme = (Story: StoryFn, { globals }: StoryContext) => {
  const theme = globals.theme === 'dark' ? darkTheme : lightTheme;
  return (
    <ThemeProvider theme={theme}>
      <div style={{
        background: theme.colors.background,
        padding: '1rem',
        minHeight: '100vh',
      }}>
        <Story />
      </div>
    </ThemeProvider>
  );
};
```

### Matrix Testing (Theme × Viewport)

Create stories that render the component in all theme/viewport combinations:

```tsx
const themes = ['light', 'dark'] as const;
const viewports = ['mobile', 'tablet', 'desktop'] as const;

// Programmatically generate stories for each combination
for (const theme of themes) {
  for (const viewport of viewports) {
    module.exports[`${theme}_${viewport}`] = {
      args: { label: 'Button' },
      parameters: {
        viewport: { defaultViewport: viewport },
        backgrounds: { default: theme },
      },
      decorators: [
        (Story) => (
          <ThemeProvider theme={theme === 'dark' ? darkTheme : lightTheme}>
            <Story />
          </ThemeProvider>
        ),
      ],
    } satisfies Story;
  }
}
```

---

## Storybook for Design Systems

### Token-Driven Stories

Document design tokens as stories:

```tsx
// Colors.stories.tsx
const meta = {
  title: 'Design Tokens/Colors',
  tags: ['autodocs'],
} satisfies Meta;

export const Palette: Story = {
  render: () => (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: '1rem' }}>
      {Object.entries(tokens.colors).map(([name, value]) => (
        <div key={name} style={{ textAlign: 'center' }}>
          <div style={{
            background: value,
            width: 64, height: 64,
            borderRadius: 8,
            border: '1px solid #eee',
          }} />
          <code>{name}</code>
          <div style={{ fontSize: 12, color: '#666' }}>{value}</div>
        </div>
      ))}
    </div>
  ),
};
```

### Composition for Multi-Package Systems

```ts
// .storybook/main.ts
const config: StorybookConfig = {
  stories: ['../packages/*/src/**/*.stories.@(ts|tsx)'],
  refs: {
    'icons': { title: 'Icon Library', url: 'https://icons.example.com/storybook' },
    'legacy': { title: 'Legacy Components', url: 'https://legacy.example.com/storybook' },
  },
};
```

### Autodocs with JSDoc

```tsx
interface ButtonProps {
  /** The text content of the button */
  label: string;
  /** Visual style variant
   * @default 'primary'
   */
  variant?: 'primary' | 'secondary' | 'ghost';
  /** Size of the button
   * @default 'medium'
   */
  size?: 'small' | 'medium' | 'large';
  /** Called when the button is clicked */
  onClick?: () => void;
  /** Whether the button is disabled */
  disabled?: boolean;
}
```

JSDoc comments on props auto-populate the Docs page `ArgTypes` table. Use `@default` to show default values.
