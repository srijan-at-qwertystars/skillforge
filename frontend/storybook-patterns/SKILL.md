---
name: storybook-patterns
description: >
  Use when creating, configuring, or debugging Storybook 8.x stories, addons, interaction tests, visual tests, or docs for React, Vue, Angular, Svelte, or Web Components. Triggers on CSF3 story format, play functions, Controls/Actions/Docs/Viewport addons, Chromatic visual testing, MSW API mocking, custom addon development, .storybook config files (main.ts, preview.ts, manager.ts), autodocs, MDX, design system theming, or storybook deployment. Do NOT trigger for general unit/E2E testing outside Storybook, component code without story context, or generic build tooling.
globs:
  - "**/*.stories.{ts,tsx,js,jsx,svelte,vue}"
  - "**/*.stories.mdx"
  - ".storybook/**/*"
---

# Storybook 8.x Patterns

## Setup

```bash
npx storybook@latest init --type react_vite    # React+Vite
npx storybook@latest init --type vue3_vite      # Vue 3
npx storybook@latest init --type angular        # Angular
npx storybook@latest init --type svelte_vite    # Svelte
npx storybook@latest init --type web_components_vite  # Web Components
```

### main.ts — Build Config

```ts
// .storybook/main.ts
import type { StorybookConfig } from '@storybook/react-vite';
const config: StorybookConfig = {
  framework: '@storybook/react-vite',
  stories: ['../src/**/*.mdx', '../src/**/*.stories.@(js|jsx|ts|tsx)'],
  addons: ['@storybook/addon-essentials', '@storybook/addon-a11y'],
  docs: { autodocs: 'tag' },
  staticDirs: ['../public'],
  typescript: { reactDocgen: 'react-docgen-typescript' },
  core: { disableTelemetry: true },
  viteFinal: async (config) => {
    config.resolve ??= {};
    config.resolve.alias = { ...config.resolve.alias, '@': '/src' };
    return config;
  },
};
export default config;
```

### preview.ts — Rendering Globals

```ts
import type { Preview } from '@storybook/react';
import '../src/styles/globals.css';
const preview: Preview = {
  parameters: {
    layout: 'centered',
    controls: { matchers: { color: /(background|color)$/i, date: /Date$/i } },
    actions: { argTypesRegex: '^on[A-Z].*' },
  },
  decorators: [(Story) => (<ThemeProvider theme={defaultTheme}><Story /></ThemeProvider>)],
  globalTypes: {
    theme: {
      description: 'Global theme',
      toolbar: { title: 'Theme', icon: 'paintbrush', items: ['light', 'dark'], dynamicTitle: true },
    },
  },
};
export default preview;
```

### manager.ts — UI Customization

```ts
import { addons } from 'storybook/manager-api';
import { create } from 'storybook/theming';
addons.setConfig({
  theme: create({
    base: 'light', brandTitle: 'My Design System', brandUrl: 'https://example.com',
    brandImage: '/logo.svg', colorPrimary: '#0066FF', colorSecondary: '#1EA7FD',
  }),
  sidebar: { showRoots: true },
});
```

## CSF3 Story Format

Export a default meta object and named story objects. CSF3 uses object syntax — no render function needed for simple cases.

```tsx
// Button.stories.tsx — INPUT: React component with variant, size, label, onClick props
import type { Meta, StoryObj } from '@storybook/react';
import { Button } from './Button';

const meta = {
  title: 'Components/Button',
  component: Button,
  tags: ['autodocs'],
  args: { label: 'Click me' },
  argTypes: {
    variant: { control: 'select', options: ['primary', 'secondary', 'danger'],
      description: 'Visual style', table: { defaultValue: { summary: 'primary' } } },
    size: { control: 'radio', options: ['sm', 'md', 'lg'] },
    onClick: { action: 'clicked' },
  },
  decorators: [(Story) => <div style={{ padding: '1rem' }}><Story /></div>],
  parameters: { layout: 'centered' },
} satisfies Meta<typeof Button>;
export default meta;
type Story = StoryObj<typeof meta>;

// OUTPUT: Stories appear in sidebar under Components/Button with auto-generated docs
export const Primary: Story = { args: { variant: 'primary', label: 'Primary' } };
export const Secondary: Story = { args: { variant: 'secondary', label: 'Secondary' } };

// Custom render for complex composition
export const WithIcon: Story = {
  args: { label: 'Save' },
  render: (args) => <Button {...args}><Icon name="save" /> {args.label}</Button>,
};
```

### Vue 3 CSF3

```ts
import type { Meta, StoryObj } from '@storybook/vue3';
import Button from './Button.vue';
const meta: Meta<typeof Button> = {
  title: 'Components/Button', component: Button, tags: ['autodocs'],
  argTypes: { variant: { control: 'select', options: ['primary', 'ghost'] } },
};
export default meta;
type Story = StoryObj<typeof meta>;
export const Default: Story = { args: { label: 'Vue Button' } };
```

### Angular CSF3

```ts
import type { Meta, StoryObj } from '@storybook/angular';
import { moduleMetadata, applicationConfig } from '@storybook/angular';
import { ButtonComponent } from './button.component';
const meta: Meta<ButtonComponent> = {
  title: 'Components/Button', component: ButtonComponent,
  decorators: [moduleMetadata({ imports: [CommonModule] }),
    applicationConfig({ providers: [provideAnimations()] })],
};
export default meta;
type Story = StoryObj<ButtonComponent>;
export const Primary: Story = { args: { label: 'Angular Button', variant: 'primary' } };
```

## Controls Addon

Auto-generated from prop types. Override with `argTypes`:

```ts
argTypes: {
  color: { control: 'color' },
  date: { control: 'date' },
  count: { control: { type: 'range', min: 0, max: 100, step: 5 } },
  json: { control: 'object' },
  internalRef: { table: { disable: true } },       // hide from panel
  // Conditional controls — show based on other args
  showLabel: { control: 'boolean' },
  label: { control: 'text', if: { arg: 'showLabel', truthy: true } },
  mode: { control: 'select', options: ['simple', 'advanced'] },
  advancedConfig: { control: 'object', if: { arg: 'mode', eq: 'advanced' } },
}
```

## Actions Addon

```ts
// argTypes action (preferred)
argTypes: { onClick: { action: 'clicked' }, onChange: { action: 'changed' } }
// Global regex in preview.ts
parameters: { actions: { argTypesRegex: '^on[A-Z].*' } }
// fn() for assertions in play functions
import { fn } from '@storybook/test';
args: { onClick: fn() }
```

## Docs Addon

### Autodocs

```ts
tags: ['autodocs']           // per-story meta
docs: { autodocs: 'tag' }   // main.ts — only tagged
docs: { autodocs: true }    // main.ts — all stories
```

### MDX Documentation

```mdx
{/* Button.mdx */}
import { Meta, Canvas, Controls, ArgTypes, Source } from '@storybook/blocks';
import * as ButtonStories from './Button.stories';
<Meta of={ButtonStories} />
# Button
Primary action element.
<Canvas of={ButtonStories.Primary} />
<Controls />
<ArgTypes of={ButtonStories} />
```

Doc blocks: `<Meta>`, `<Canvas>`, `<Story>`, `<Controls>`, `<ArgTypes>`, `<Source>`, `<Description>`, `<Primary>`, `<Stories>`, `<Subtitle>`, `<Title>`.

## Interaction Testing

Write tests in stories with play functions using `@storybook/test`:

```tsx
// INPUT: Form component with email, password fields and submit handler
import { expect, fn, userEvent, within, waitFor } from '@storybook/test';

export const FilledForm: Story = {
  args: { onSubmit: fn() },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement);
    await userEvent.type(canvas.getByLabelText('Email'), 'test@example.com');
    await userEvent.type(canvas.getByLabelText('Password'), 'secret123');
    await userEvent.click(canvas.getByRole('button', { name: /submit/i }));
    await waitFor(() => {
      expect(args.onSubmit).toHaveBeenCalledOnce();
      expect(canvas.getByText('Success')).toBeInTheDocument();
    });
  },
};
// OUTPUT: Interactions panel shows step-by-step pass/fail for each assertion

// Compose play functions for multi-step flows
export const StepTwo: Story = {
  play: async (context) => {
    await FilledForm.play!(context);
    const canvas = within(context.canvasElement);
    await userEvent.click(canvas.getByText('Next'));
    await expect(canvas.getByText('Step 2')).toBeVisible();
  },
};
```

Run in CI:

```bash
npx concurrently -k -s first \
  "npx http-server storybook-static --port 6006 --silent" \
  "npx wait-on tcp:127.0.0.1:6006 && npx test-storybook --url http://127.0.0.1:6006"
```

## Visual Testing

### Chromatic

```bash
npm install -D chromatic
npx chromatic --project-token=<TOKEN>
```

```yaml
# .github/workflows/chromatic.yml
name: Chromatic
on: push
jobs:
  visual:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - run: npm ci
      - uses: chromaui/action@latest
        with:
          projectToken: ${{ secrets.CHROMATIC_PROJECT_TOKEN }}
          buildScriptName: build-storybook
          onlyChanged: true  # TurboSnap
```

### Per-Story Snapshot Config

```ts
parameters: {
  chromatic: {
    disableSnapshot: true,                // skip this story
    viewports: [320, 768, 1200],          // multi-viewport snapshots
    diffThreshold: 0.3,                   // tolerance
    delay: 300,                           // wait before capture
  },
}
```

## Viewport Addon

```ts
// preview.ts
import { INITIAL_VIEWPORTS, MINIMAL_VIEWPORTS } from '@storybook/addon-viewport';
parameters: {
  viewport: {
    viewports: {
      ...MINIMAL_VIEWPORTS,
      customMobile: { name: 'Custom Mobile', styles: { width: '375px', height: '812px' } },
    },
    defaultViewport: 'responsive',
  },
}
// Per-story: parameters: { viewport: { defaultViewport: 'iphone14' } }
```

## Component Composition

```ts
// main.ts — reference external Storybooks
refs: {
  'design-system': { title: 'Design System', url: 'https://ds.example.com/storybook' },
  internal: { title: 'Shared Components', url: 'http://localhost:6007' },
},
```

## Custom Addons

### Panel Addon

```tsx
// src/addons/my-panel/manager.tsx
import React from 'react';
import { addons, types, useAddonState, useChannel } from 'storybook/manager-api';
import { AddonPanel } from 'storybook/internal/components';

const ADDON_ID = 'my-org/my-panel';
addons.register(ADDON_ID, () => {
  addons.add(`${ADDON_ID}/panel`, {
    type: types.PANEL, title: 'My Panel',
    render: ({ active }) => {
      const [data, setData] = useAddonState(ADDON_ID, {});
      useChannel({ [`${ADDON_ID}/result`]: (d) => setData(d) });
      return <AddonPanel active={active!}><pre>{JSON.stringify(data, null, 2)}</pre></AddonPanel>;
    },
  });
});
```

### Toolbar Addon

```tsx
import { addons, types, useGlobals } from 'storybook/manager-api';
import { IconButton } from 'storybook/internal/components';
import { OutlineIcon } from '@storybook/icons';

addons.register('my-org/toolbar', () => {
  addons.add('my-org/toolbar/btn', {
    type: types.TOOL, title: 'Toggle Outline',
    match: ({ viewMode }) => viewMode === 'story',
    render: () => {
      const [globals, updateGlobals] = useGlobals();
      return (
        <IconButton active={globals.outline} onClick={() => updateGlobals({ outline: !globals.outline })}>
          <OutlineIcon />
        </IconButton>
      );
    },
  });
});
// Register in main.ts: addons: ['./src/addons/my-panel/manager']
```

## MSW API Mocking

```bash
npm install -D msw msw-storybook-addon && npx msw init public/
```

```ts
// preview.ts
import { initialize, mswLoader } from 'msw-storybook-addon';
initialize();
const preview: Preview = { loaders: [mswLoader] };
```

```tsx
// INPUT: Component that fetches /api/users — OUTPUT: Story renders with mocked data
import { http, HttpResponse } from 'msw';

export const WithData: Story = {
  parameters: {
    msw: {
      handlers: [
        http.get('/api/users', () => HttpResponse.json([{ id: 1, name: 'Alice' }])),
        http.post('/api/users', async ({ request }) => {
          const body = await request.json();
          return HttpResponse.json({ id: 2, ...body }, { status: 201 });
        }),
      ],
    },
  },
};
export const WithError: Story = {
  parameters: {
    msw: { handlers: [http.get('/api/users', () => HttpResponse.json({ error: 'fail' }, { status: 500 }))] },
  },
};
```

## Design System Theming

```ts
// .storybook/theme.ts
import { create } from 'storybook/theming';
export default create({
  base: 'light', brandTitle: 'Acme DS', brandUrl: 'https://acme.design',
  fontBase: '"Inter", sans-serif', fontCode: '"Fira Code", monospace',
  colorPrimary: '#6366F1', colorSecondary: '#8B5CF6',
  appBg: '#F8FAFC', appContentBg: '#FFF', barBg: '#FFF',
});
```

### Token Documentation

```tsx
// tokens/Colors.stories.tsx — INPUT: design tokens object — OUTPUT: visual palette grid
const meta: Meta = { title: 'Tokens/Colors', tags: ['autodocs'] };
export default meta;
export const Palette: StoryObj = {
  render: () => (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: '1rem' }}>
      {Object.entries(tokens.colors).map(([name, value]) => (
        <div key={name} style={{ textAlign: 'center' }}>
          <div style={{ background: value, width: 64, height: 64, borderRadius: 8 }} />
          <code>{name}</code><div>{value}</div>
        </div>
      ))}
    </div>
  ),
};
```

## Build Optimization

```ts
// main.ts
core: { builder: { name: '@storybook/builder-vite', options: {} } }, // lazy compilation
stories: ['../src/components/**/*.stories.tsx'],  // narrow globs reduce indexing
// CLI: npx storybook build --test  (2-4x faster, skips docs)
```

```json
{ "scripts": {
  "storybook": "storybook dev -p 6006",
  "build-storybook": "storybook build",
  "build-storybook:test": "storybook build --test",
  "test-storybook": "test-storybook"
}}
```

## Deployment

```bash
npx storybook build -o storybook-static          # static build
npx chromatic --project-token=$TOKEN --auto-accept-changes=main  # Chromatic
```

### GitHub Pages

```yaml
name: Deploy Storybook
on: { push: { branches: [main] } }
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions: { pages: write, id-token: write }
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build-storybook
      - uses: actions/upload-pages-artifact@v3
        with: { path: storybook-static }
      - uses: actions/deploy-pages@v4
```

### Nginx

```nginx
server {
  listen 80;
  root /var/www/storybook;
  location / { try_files $uri $uri/ /index.html; }
  location ~* \.(js|css|png|svg|woff2?)$ { expires 1y; add_header Cache-Control "public, immutable"; }
}
```