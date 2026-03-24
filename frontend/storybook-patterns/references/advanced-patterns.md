# Advanced Storybook Patterns

> Dense reference for advanced Storybook 8.x patterns. Each section is self-contained with copy-paste examples.

## Table of Contents

- [Portable Stories for Unit Testing](#portable-stories-for-unit-testing)
- [Composing Stories from Other Stories](#composing-stories-from-other-stories)
- [Play Function Composition](#play-function-composition)
- [Custom Render Functions](#custom-render-functions)
- [Loaders for Async Data](#loaders-for-async-data)
- [Custom Decorators with Context](#custom-decorators-with-context)
- [Story Indexer for Custom File Formats](#story-indexer-for-custom-file-formats)
- [Builder API Customization](#builder-api-customization)
- [Webpack Config Overrides](#webpack-config-overrides)
- [Vite Config Overrides](#vite-config-overrides)

---

## Portable Stories for Unit Testing

Portable stories let you reuse Storybook stories in Jest/Vitest without duplicating setup. They apply all decorators, args, loaders, and play functions.

### React — composeStories

```tsx
// Button.test.tsx
import { composeStories } from '@storybook/react';
import { render, screen } from '@testing-library/react';
import * as stories from './Button.stories';

const { Primary, Secondary, WithIcon } = composeStories(stories);

test('Primary renders with correct label', () => {
  render(<Primary />);
  expect(screen.getByText('Primary')).toBeInTheDocument();
});

test('Primary executes play function', async () => {
  const { container } = render(<Primary />);
  await Primary.play({ canvasElement: container });
  // assertions from the play function run here
});

test('Override args at test time', () => {
  render(<Primary label="Override" />);
  expect(screen.getByText('Override')).toBeInTheDocument();
});
```

### composeStory — Single Story

```tsx
import { composeStory } from '@storybook/react';
import meta, { Primary as PrimaryStory } from './Button.stories';

const Primary = composeStory(PrimaryStory, meta);
// Optionally override config:
const CustomPrimary = composeStory(PrimaryStory, meta, {
  decorators: [MyTestDecorator],
  args: { label: 'Test-only label' },
});
```

### Vue 3

```ts
import { composeStories } from '@storybook/vue3';
import { mount } from '@vue/test-utils';
import * as stories from './Button.stories';

const { Default } = composeStories(stories);

test('renders vue button', () => {
  const wrapper = mount(Default());
  expect(wrapper.text()).toContain('Vue Button');
});
```

### Angular

```ts
import { composeStories } from '@storybook/angular';
import { TestBed } from '@angular/core/testing';
import * as stories from './button.stories';

const { Primary } = composeStories(stories);

it('renders button', async () => {
  const { fixture } = await Primary.render();
  expect(fixture.nativeElement.textContent).toContain('Angular Button');
});
```

### Setup file for portable stories (Vitest)

```ts
// vitest.setup.ts — apply global project annotations
import { setProjectAnnotations } from '@storybook/react';
import * as previewAnnotations from './.storybook/preview';

setProjectAnnotations(previewAnnotations);
```

---

## Composing Stories from Other Stories

Reuse stories as building blocks inside other stories. Keeps examples DRY and consistent.

### Args Inheritance

```tsx
import type { Meta, StoryObj } from '@storybook/react';
import { Button } from './Button';

const meta = {
  component: Button,
  args: { size: 'md', variant: 'primary' }, // shared defaults
} satisfies Meta<typeof Button>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Base: Story = { args: { label: 'Base' } };

// Extend from another story's args
export const Large: Story = {
  args: { ...Base.args, size: 'lg' },
};

export const Danger: Story = {
  args: { ...Base.args, variant: 'danger', label: 'Delete' },
};
```

### Render Composition

```tsx
import { Card } from './Card';
import { Primary as PrimaryButton } from './Button.stories';

export const CardWithButton: StoryObj<typeof Card> = {
  render: (args) => (
    <Card {...args}>
      <PrimaryButton {...PrimaryButton.args} />
    </Card>
  ),
};
```

### Page-level Story Composition

```tsx
import { Header } from './Header';
import { LoggedIn as LoggedInHeader } from './Header.stories';
import { Sidebar } from './Sidebar';
import { Default as DefaultSidebar } from './Sidebar.stories';

const meta: Meta<typeof Page> = {
  component: Page,
  title: 'Pages/Dashboard',
};
export default meta;

export const Dashboard: StoryObj<typeof Page> = {
  render: () => (
    <Page
      header={<Header {...LoggedInHeader.args} />}
      sidebar={<Sidebar {...DefaultSidebar.args} />}
    />
  ),
};
```

---

## Play Function Composition

Chain play functions to build multi-step interaction flows. Each step builds on the previous.

### Sequential Composition

```tsx
import { expect, userEvent, within } from '@storybook/test';

export const StepOne: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await userEvent.type(canvas.getByLabelText('Email'), 'user@example.com');
    await userEvent.click(canvas.getByRole('button', { name: 'Next' }));
    await expect(canvas.getByText('Step 2')).toBeVisible();
  },
};

export const StepTwo: Story = {
  play: async (context) => {
    // Run step one first
    await StepOne.play!(context);
    const canvas = within(context.canvasElement);
    await userEvent.type(canvas.getByLabelText('Address'), '123 Main St');
    await userEvent.click(canvas.getByRole('button', { name: 'Submit' }));
    await expect(canvas.getByText('Complete')).toBeVisible();
  },
};
```

### Using step() for Labeled Sub-steps

```tsx
export const FullFlow: Story = {
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement);

    await step('Fill personal info', async () => {
      await userEvent.type(canvas.getByLabelText('Name'), 'Alice');
      await userEvent.type(canvas.getByLabelText('Email'), 'alice@test.com');
    });

    await step('Select plan', async () => {
      await userEvent.click(canvas.getByLabelText('Pro'));
      await expect(canvas.getByText('$29/mo')).toBeVisible();
    });

    await step('Confirm and submit', async () => {
      await userEvent.click(canvas.getByRole('button', { name: 'Confirm' }));
      await expect(canvas.getByText('Thank you!')).toBeVisible();
    });
  },
};
```

### Shared Play Helpers

```tsx
// test-helpers.ts
import { userEvent, within } from '@storybook/test';
import type { StoryContext } from '@storybook/react';

export async function login(context: StoryContext, email: string, password: string) {
  const canvas = within(context.canvasElement);
  await userEvent.type(canvas.getByLabelText('Email'), email);
  await userEvent.type(canvas.getByLabelText('Password'), password);
  await userEvent.click(canvas.getByRole('button', { name: /sign in/i }));
}

// Usage in stories:
export const Authenticated: Story = {
  play: async (context) => {
    await login(context, 'admin@test.com', 'password123');
    await expect(within(context.canvasElement).getByText('Dashboard')).toBeVisible();
  },
};
```

---

## Custom Render Functions

Override how stories render for complex layouts, wrappers, or non-standard component APIs.

### Basic Custom Render

```tsx
export const CustomLayout: Story = {
  args: { title: 'Hello', items: ['a', 'b', 'c'] },
  render: (args) => (
    <div className="custom-layout">
      <h1>{args.title}</h1>
      <ul>
        {args.items.map((item) => <li key={item}>{item}</li>)}
      </ul>
    </div>
  ),
};
```

### Render with Hooks

```tsx
export const WithState: Story = {
  render: (args) => {
    const [count, setCount] = React.useState(0);
    return (
      <div>
        <Button {...args} onClick={() => setCount((c) => c + 1)} />
        <p>Clicked {count} times</p>
      </div>
    );
  },
};
```

### Render with Multiple Components

```tsx
export const FormWithValidation: Story = {
  render: (args) => (
    <FormProvider>
      <Form {...args}>
        <Input name="email" rules={{ required: true }} />
        <Input name="password" rules={{ minLength: 8 }} />
        <SubmitButton />
      </Form>
      <ErrorSummary />
    </FormProvider>
  ),
};
```

### Meta-level Render (applies to all stories in file)

```tsx
const meta = {
  component: Tooltip,
  render: (args) => (
    <div style={{ padding: '100px', textAlign: 'center' }}>
      <Tooltip {...args}>
        <button>Hover me</button>
      </Tooltip>
    </div>
  ),
} satisfies Meta<typeof Tooltip>;
```

---

## Loaders for Async Data

Loaders fetch async data before a story renders. Data is available in `context.loaded`.

### Basic Loader

```tsx
export const WithUser: Story = {
  loaders: [
    async () => ({
      user: await fetch('/api/user/1').then((r) => r.json()),
    }),
  ],
  render: (args, { loaded: { user } }) => (
    <UserProfile {...args} user={user} />
  ),
};
```

### Multiple Loaders

```tsx
export const Dashboard: Story = {
  loaders: [
    async () => ({ stats: await fetchStats() }),
    async () => ({ notifications: await fetchNotifications() }),
  ],
  render: (args, { loaded: { stats, notifications } }) => (
    <DashboardView stats={stats} notifications={notifications} />
  ),
};
```

### Global Loader in preview.ts

```ts
// preview.ts
const preview: Preview = {
  loaders: [
    async () => ({
      config: await fetch('/api/config').then((r) => r.json()),
    }),
  ],
};
```

### Loader with MSW (load after mocks are set up)

```tsx
export const WithMockedData: Story = {
  parameters: {
    msw: {
      handlers: [
        http.get('/api/products', () =>
          HttpResponse.json([{ id: 1, name: 'Widget' }])
        ),
      ],
    },
  },
  loaders: [
    async () => ({
      products: await fetch('/api/products').then((r) => r.json()),
    }),
  ],
  render: (args, { loaded: { products } }) => (
    <ProductList {...args} products={products} />
  ),
};
```

---

## Custom Decorators with Context

Decorators wrap stories. Context gives access to args, globals, parameters, and more.

### Context-Aware Decorator

```tsx
// Decorator that reads globals and applies theme
const ThemeDecorator: Decorator = (Story, context) => {
  const theme = context.globals.theme || 'light';
  return (
    <ThemeProvider theme={themes[theme]}>
      <Story />
    </ThemeProvider>
  );
};
```

### Decorator That Modifies Args

```tsx
const WithDefaultUser: Decorator = (Story, context) => {
  const enhancedArgs = {
    ...context.args,
    user: context.args.user || { name: 'Default User', role: 'viewer' },
  };
  return <Story args={enhancedArgs} />;
};
```

### Conditional Decorator Based on Parameters

```tsx
const PaddingDecorator: Decorator = (Story, context) => {
  const padding = context.parameters.padding ?? '1rem';
  if (context.parameters.noPadding) return <Story />;
  return (
    <div style={{ padding }}>
      <Story />
    </div>
  );
};

// Usage: parameters: { noPadding: true } to opt out
```

### Decorator Execution Order

Decorators apply innermost first: story → component (meta) → global (preview.ts).

```tsx
// preview.ts — outermost
decorators: [GlobalDecorator]

// Meta — middle
decorators: [ComponentDecorator]

// Story — innermost (rendered first, wrapped by the others)
decorators: [StoryDecorator]

// Render order: GlobalDecorator → ComponentDecorator → StoryDecorator → Story
```

### Decorator with State (React)

```tsx
const RouterDecorator: Decorator = (Story) => {
  const [currentPath, setCurrentPath] = React.useState('/');
  return (
    <MemoryRouter initialEntries={[currentPath]}>
      <div>
        <nav>
          <button onClick={() => setCurrentPath('/')}>Home</button>
          <button onClick={() => setCurrentPath('/about')}>About</button>
        </nav>
        <Story />
      </div>
    </MemoryRouter>
  );
};
```

---

## Story Indexer for Custom File Formats

Story indexers tell Storybook how to find and parse stories from non-standard file formats.

### Custom Indexer in main.ts

```ts
// .storybook/main.ts
import type { StorybookConfig, IndexerOptions, IndexInput } from '@storybook/types';
import fs from 'fs';

const config: StorybookConfig = {
  // ...
  experimental_indexers: (existingIndexers) => {
    const yamlIndexer = {
      test: /\.stories\.ya?ml$/,
      createIndex: async (fileName: string, opts: IndexerOptions): Promise<IndexInput[]> => {
        const content = fs.readFileSync(fileName, 'utf-8');
        const yaml = parseYaml(content); // your YAML parser
        return yaml.stories.map((story: any) => ({
          type: 'story',
          importPath: fileName,
          exportName: story.name,
          title: yaml.title,
          tags: story.tags || [],
        }));
      },
    };
    return [...existingIndexers, yamlIndexer];
  },
};
```

### JSON-Based Story Indexer

```ts
const jsonIndexer = {
  test: /\.stories\.json$/,
  createIndex: async (fileName: string): Promise<IndexInput[]> => {
    const data = JSON.parse(fs.readFileSync(fileName, 'utf-8'));
    return Object.entries(data.stories).map(([exportName, story]: [string, any]) => ({
      type: 'story',
      importPath: fileName,
      exportName,
      title: data.title,
      name: story.name || exportName,
    }));
  },
};
```

---

## Builder API Customization

Storybook supports Vite and Webpack builders. Customize their behavior in `main.ts`.

### Switching Builders

```ts
// Vite (default for new projects)
core: { builder: '@storybook/builder-vite' }

// Webpack 5
core: { builder: '@storybook/builder-webpack5' }
```

### Builder Options

```ts
// Vite builder options
core: {
  builder: {
    name: '@storybook/builder-vite',
    options: {
      viteConfigPath: './vite.storybook.config.ts', // custom config file
    },
  },
},

// Webpack builder options
core: {
  builder: {
    name: '@storybook/builder-webpack5',
    options: {
      fsCache: true,       // filesystem cache for faster rebuilds
      lazyCompilation: true, // compile stories on demand
    },
  },
},
```

---

## Webpack Config Overrides

Use `webpackFinal` in `main.ts` to modify the Webpack configuration.

### Adding Aliases

```ts
webpackFinal: async (config) => {
  config.resolve!.alias = {
    ...config.resolve!.alias,
    '@': path.resolve(__dirname, '../src'),
    '@components': path.resolve(__dirname, '../src/components'),
    '@utils': path.resolve(__dirname, '../src/utils'),
  };
  return config;
},
```

### Adding Loaders

```ts
webpackFinal: async (config) => {
  // SVGR support
  const fileLoaderRule = config.module!.rules!.find(
    (rule: any) => rule.test?.test?.('.svg')
  );
  if (fileLoaderRule && typeof fileLoaderRule === 'object') {
    fileLoaderRule.exclude = /\.svg$/;
  }
  config.module!.rules!.push({
    test: /\.svg$/,
    use: ['@svgr/webpack', 'url-loader'],
  });

  // SCSS modules
  config.module!.rules!.push({
    test: /\.module\.scss$/,
    use: ['style-loader', {
      loader: 'css-loader',
      options: { modules: { localIdentName: '[name]__[local]--[hash:base64:5]' } },
    }, 'sass-loader'],
  });

  return config;
},
```

### Modifying Plugins

```ts
webpackFinal: async (config) => {
  const { DefinePlugin } = await import('webpack');
  config.plugins!.push(
    new DefinePlugin({
      'process.env.STORYBOOK': JSON.stringify(true),
      __APP_VERSION__: JSON.stringify(require('../package.json').version),
    })
  );
  return config;
},
```

---

## Vite Config Overrides

Use `viteFinal` in `main.ts` to modify the Vite configuration.

### Path Aliases

```ts
viteFinal: async (config) => {
  config.resolve ??= {};
  config.resolve.alias = {
    ...config.resolve.alias,
    '@': path.resolve(__dirname, '../src'),
    '@assets': path.resolve(__dirname, '../src/assets'),
  };
  return config;
},
```

### Adding Plugins

```ts
import svgr from 'vite-plugin-svgr';
import tsconfigPaths from 'vite-tsconfig-paths';

viteFinal: async (config) => {
  config.plugins ??= [];
  config.plugins.push(svgr());
  config.plugins.push(tsconfigPaths());
  return config;
},
```

### Environment Variables

```ts
viteFinal: async (config) => {
  config.define = {
    ...config.define,
    'process.env.STORYBOOK': JSON.stringify(true),
    __APP_VERSION__: JSON.stringify(process.env.npm_package_version),
  };
  return config;
},
```

### CSS Configuration

```ts
viteFinal: async (config) => {
  config.css ??= {};
  config.css.modules = {
    localsConvention: 'camelCase',
    generateScopedName: '[name]__[local]--[hash:base64:5]',
  };
  config.css.preprocessorOptions = {
    scss: {
      additionalData: `@use "@/styles/variables" as *;`,
    },
  };
  return config;
},
```

### Optimizing Dependencies

```ts
viteFinal: async (config) => {
  config.optimizeDeps ??= {};
  config.optimizeDeps.include = [
    ...(config.optimizeDeps.include || []),
    '@storybook/addon-essentials',
    'lodash-es',
  ];
  config.optimizeDeps.exclude = [
    ...(config.optimizeDeps.exclude || []),
    '@my-org/internal-package', // force re-bundling
  ];
  return config;
},
```

### Full Production-Like Vite Config

```ts
viteFinal: async (config, { configType }) => {
  if (configType === 'PRODUCTION') {
    config.build ??= {};
    config.build.sourcemap = false;
    config.build.minify = 'esbuild';
    config.build.chunkSizeWarningLimit = 1000;
    config.build.rollupOptions = {
      output: {
        manualChunks: {
          vendor: ['react', 'react-dom'],
          storybook: ['@storybook/react'],
        },
      },
    };
  }
  return config;
},
```
