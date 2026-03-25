---
name: storybook-testing
description: >
  Guide for developing and testing UI components with Storybook 8.x. Use when writing Storybook stories, component documentation, visual testing, interaction testing with play functions, configuring Storybook addons, working with CSF3 format, building component libraries, setting up controls/args/argTypes, or integrating decorators and loaders. Do NOT use for Playwright/Cypress end-to-end testing unrelated to Storybook, Jest/Vitest unit testing without UI components, REST/GraphQL API testing, CLI application testing, or backend service testing.
---

# Storybook Component Development & Testing

## Installation & Project Setup

Initialize Storybook in an existing project:

```bash
npx storybook@latest init
```

Framework-specific packages — use the correct one in `.storybook/main.ts`:

| Framework | Package |
|-----------|---------|
| React + Vite | `@storybook/react-vite` |
| React + Webpack | `@storybook/react-webpack5` |
| Next.js | `@storybook/nextjs` |
| Vue 3 + Vite | `@storybook/vue3-vite` |
| Angular | `@storybook/angular` |
| Svelte + Vite | `@storybook/svelte-vite` |

Minimal `.storybook/main.ts`:

```ts
import type { StorybookConfig } from '@storybook/react-vite';
const config: StorybookConfig = {
  framework: { name: '@storybook/react-vite', options: {} },
  stories: ['../src/**/*.stories.@(ts|tsx|mdx)'],
  addons: [
    '@storybook/addon-essentials',
    '@storybook/addon-a11y',
    '@chromatic-com/storybook',
  ],
};
export default config;
```

Essential addons to install:

```bash
npm i -D @storybook/addon-essentials @storybook/addon-a11y @storybook/test @storybook/test-runner @chromatic-com/storybook
```

## CSF3 Format (Component Story Format 3)

Every story file exports a default `meta` object and named story objects. Stories are objects, not functions.

```tsx
// Button.stories.tsx
import type { Meta, StoryObj } from '@storybook/react';
import { Button } from './Button';

const meta = {
  component: Button,
  title: 'UI/Button',
  tags: ['autodocs'],
} satisfies Meta<typeof Button>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Primary: Story = {
  args: { label: 'Click me', variant: 'primary' },
};

export const Disabled: Story = {
  args: { label: 'Disabled', disabled: true },
};
```

Key rules:
- Default export = component meta (component, title, tags, decorators, args, argTypes, parameters, loaders, beforeEach).
- Named exports = individual stories. Each is a `StoryObj`.
- Add `tags: ['autodocs']` to auto-generate a docs page.
- Use `satisfies Meta<typeof Component>` for full type safety.

## Args & ArgTypes

**Args** set default prop values. Define at meta level (shared) or story level (override).

```tsx
const meta = {
  component: Button,
  args: { size: 'medium' },          // shared default
  argTypes: {
    variant: {
      control: 'select',
      options: ['primary', 'secondary', 'ghost'],
      description: 'Visual style variant',
      table: { defaultValue: { summary: 'primary' } },
    },
    onClick: { action: 'clicked' },   // logs to Actions panel
    size: {
      control: 'radio',
      options: ['small', 'medium', 'large'],
    },
    disabled: { control: 'boolean' },
    label: { control: 'text' },
  },
} satisfies Meta<typeof Button>;
```

Control types: `text`, `boolean`, `number`, `range`, `color`, `date`, `object`, `select`, `multi-select`, `radio`, `inline-radio`, `check`, `inline-check`, `file`.

Hide an arg from controls: `argTypes: { id: { table: { disable: true } } }`.

## Decorators

Wrap stories with layout, providers, or context. Three scopes:

**Story-level:** `decorators: [(Story) => <ThemeProvider theme={dark}><Story /></ThemeProvider>]`

**Component-level** (in meta):
```tsx
const meta = {
  component: Card,
  decorators: [(Story) => <div style={{ padding: '2rem' }}><Story /></div>],
} satisfies Meta<typeof Card>;
```

**Global** (`.storybook/preview.ts`): Same syntax inside `Preview` config object.

Decorators receive `(Story, context)` — access `context.args`, `context.globals`, `context.parameters`.

## Parameters

Static metadata attached to stories. Configure addon behavior:

```tsx
export const Mobile: Story = {
  parameters: {
    viewport: { defaultViewport: 'iphone6' },
    layout: 'fullscreen',            // 'centered' | 'padded' | 'fullscreen'
    backgrounds: { default: 'dark' },
    docs: { description: { story: 'Mobile layout variant' } },
    chromatic: { viewports: [375, 768] },
    a11y: { config: { rules: [{ id: 'color-contrast', enabled: false }] } },
  },
};
```

## Loaders

Async functions that fetch data before rendering. Data available via `context.loaded`:

```tsx
export const WithUser: Story = {
  loaders: [async () => ({ user: await (await fetch('/api/user/1')).json() })],
  render: (args, { loaded: { user } }) => <Profile {...args} user={user} />,
};
```

## Play Functions & Interaction Testing

Use `@storybook/test` (wraps Testing Library + Vitest expect). Play functions run after the story renders.

```tsx
import { expect, fn, userEvent, within, waitFor } from '@storybook/test';

const meta = {
  component: LoginForm,
  args: { onSubmit: fn() },
} satisfies Meta<typeof LoginForm>;

export const SuccessfulLogin: Story = {
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement);

    await userEvent.type(canvas.getByLabelText('Email'), 'user@test.com');
    await userEvent.type(canvas.getByLabelText('Password'), 'secret123');
    await userEvent.click(canvas.getByRole('button', { name: 'Sign In' }));

    await waitFor(() => {
      expect(args.onSubmit).toHaveBeenCalledWith({
        email: 'user@test.com',
        password: 'secret123',
      });
    });
  },
};

export const ValidationError: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await userEvent.click(canvas.getByRole('button', { name: 'Sign In' }));
    await expect(canvas.getByText('Email is required')).toBeInTheDocument();
  },
};
```

Key `@storybook/test` exports: `fn`, `expect`, `within`, `userEvent`, `waitFor`, `spyOn`, `clearAllMocks`.

Use `fn()` for callback/event handler args. Use `spyOn()` for module-level function spying.

### Composing Play Functions

Reuse play functions via `composeStories`:

```tsx
import { composeStories } from '@storybook/react';
import * as stories from './LoginForm.stories';
const { SuccessfulLogin } = composeStories(stories);

export const AfterLogin: Story = {
  play: async (context) => {
    await SuccessfulLogin.play!(context);
    await expect(within(context.canvasElement).getByText('Dashboard')).toBeInTheDocument();
  },
};
```

## beforeEach Hook

Run setup code before each story renders. Return a cleanup function for teardown:

```tsx
const meta = {
  component: UserList,
  beforeEach: () => {
    const spy = spyOn(api, 'fetchUsers').mockResolvedValue([{ id: 1, name: 'Alice' }]);
    return () => spy.mockRestore();
  },
} satisfies Meta<typeof UserList>;
```

## Mocking

### Module Mocking

Use subpath imports in `package.json` for type-safe module mocking:

```jsonc
// package.json
{
  "imports": {
    "#lib/analytics": {
      "storybook": "./src/lib/analytics.mock.ts",
      "default": "./src/lib/analytics.ts"
    }
  }
}
```

Then import via `#lib/analytics` in source code. Storybook auto-resolves to the mock.

Alternatively, mock inline with `beforeEach`:

```tsx
const meta = {
  component: Dashboard,
  beforeEach: () => {
    spyOn(analyticsModule, 'track').mockImplementation(() => {});
  },
} satisfies Meta<typeof Dashboard>;
```

### Network Mocking with MSW

```bash
npm i -D msw msw-storybook-addon
npx msw init public/
```

Configure in `.storybook/preview.ts`:

```ts
import { initialize, mswLoader } from 'msw-storybook-addon';
initialize();
const preview: Preview = {
  loaders: [mswLoader],
};
```

Per-story handlers:

```tsx
import { http, HttpResponse } from 'msw';

export const WithData: Story = {
  parameters: {
    msw: {
      handlers: [
        http.get('/api/users', () => HttpResponse.json([{ id: 1, name: 'Alice' }])),
      ],
    },
  },
};

export const ErrorState: Story = {
  parameters: {
    msw: { handlers: [http.get('/api/users', () => HttpResponse.json({ error: 'fail' }, { status: 500 }))] },
  },
};
```

## Accessibility Testing (a11y Addon)

```bash
npm i -D @storybook/addon-a11y
```

Add to `.storybook/main.ts` addons array. Configure per-story:

```tsx
export const AccessibleButton: Story = {
  args: { label: 'Submit', ariaLabel: 'Submit form' },
  parameters: {
    a11y: { config: { rules: [{ id: 'color-contrast', enabled: true }] } },
  },
};
```

Disable a11y for a specific story: `parameters: { a11y: { disable: true } }`.

## Docs Addon & MDX

### Autodocs

Add `tags: ['autodocs']` to meta. Storybook generates a docs page from component props, JSDoc, and stories.

### Custom MDX Documentation

```mdx
{/* Button.mdx */}
import { Meta, Canvas, Controls, ArgTypes } from '@storybook/blocks';
import * as ButtonStories from './Button.stories';

<Meta of={ButtonStories} />

# Button Component
<Canvas of={ButtonStories.Primary} />
<Controls of={ButtonStories.Primary} />
<ArgTypes of={ButtonStories} />
```

Key doc blocks: `Meta`, `Canvas`, `Story`, `Controls`, `ArgTypes`, `Source`, `Description`, `Primary`, `Stories`, `Subtitle`, `Title`.

## Visual Testing

### Chromatic

```bash
npm i -D chromatic
npx chromatic --project-token=<token>
```

Per-story config:

```tsx
export const Hero: Story = {
  parameters: {
    chromatic: {
      viewports: [375, 768, 1200],
      delay: 300,
      pauseAnimationAtEnd: true,
      disableSnapshot: false,
    },
  },
};
```

Skip snapshots: `parameters: { chromatic: { disableSnapshot: true } }`.

### Storybook Test Runner

Turns all stories into executable tests using Playwright:

```bash
npm i -D @storybook/test-runner
```

Add script: `"test-storybook": "test-storybook"`

```bash
# Requires Storybook running on localhost:6006
npm run storybook &
npx test-storybook
npx test-storybook --coverage
npx test-storybook --browsers chromium firefox webkit
npx test-storybook --url https://your-storybook.com
```

Custom test-runner config (`.storybook/test-runner.ts`) — add `postVisit` hooks for a11y checks or screenshot comparisons.

## Storybook Composition

Combine multiple Storybooks in one UI via `refs` in `.storybook/main.ts`:

```ts
const config: StorybookConfig = {
  refs: {
    'design-system': { title: 'Design System', url: 'https://ds.example.com/storybook' },
  },
};
```

## Publishing

Build static Storybook for deployment:

```bash
npx storybook build              # outputs to storybook-static/
npx storybook build -o dist/docs # custom output dir
npx http-server storybook-static # local preview
```

Deploy to GitHub Pages, Netlify, Vercel, S3, or Chromatic.

## CI/CD Integration

GitHub Actions example:

```yaml
name: Storybook CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npx storybook build --test
      - run: npx concurrently -k -s first "npx http-server storybook-static -p 6006 --silent" "npx wait-on tcp:6006 && npx test-storybook"
      - run: npx chromatic --project-token=${{ secrets.CHROMATIC_TOKEN }} --exit-zero-on-changes
```

## Framework-Specific Notes

**Next.js:** Use `@storybook/nextjs`. Supports `next/image`, `next/link`, `next/navigation` automatically. RSC support is experimental — wrap server components with Suspense in stories.

**Vue 3:** Use `@storybook/vue3-vite`. Args map to props. Use `render` for slots:
```ts
export const WithSlot: Story = {
  render: (args) => ({
    components: { MyButton }, setup: () => ({ args }),
    template: '<MyButton v-bind="args">Click me</MyButton>',
  }),
};
```

**Angular:** Use `@storybook/angular` (15+). Use `moduleMetadata` for DI:
```ts
const meta: Meta<AlertComponent> = {
  component: AlertComponent,
  decorators: [moduleMetadata({ imports: [CommonModule], providers: [AlertService] })],
};
```

**Svelte:** Use `@storybook/svelte-vite`. Requires Svelte 5+. Args map directly to component props.

## Story Organization

Colocate stories with components: `Button.tsx` + `Button.stories.tsx` + optional `Button.mdx`.

Name stories by state: `Default`, `Loading`, `Error`, `Empty`, `Disabled`, `WithLongContent`, `Mobile`.

Use `title` hierarchy: `'Design System/Atoms/Button'`, `'Features/Auth/LoginForm'`, `'Pages/Dashboard'`.
