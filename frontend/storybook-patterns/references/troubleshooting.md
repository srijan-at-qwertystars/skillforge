# Storybook Troubleshooting Guide

> Solutions for common Storybook 8.x issues across React, Vue, Angular, and Svelte.

## Table of Contents

- [HMR Not Working](#hmr-not-working)
- [Addon Conflicts](#addon-conflicts)
- [CSS Module Problems](#css-module-problems)
- [Monorepo Setup Issues](#monorepo-setup-issues)
- [TypeScript Errors in Stories](#typescript-errors-in-stories)
- [Build Failures by Framework](#build-failures-by-framework)
- [Memory Issues in CI](#memory-issues-in-ci)
- [Slow Startup Optimization](#slow-startup-optimization)
- [React-Specific Gotchas](#react-specific-gotchas)
- [Vue-Specific Gotchas](#vue-specific-gotchas)
- [Angular-Specific Gotchas](#angular-specific-gotchas)
- [Svelte-Specific Gotchas](#svelte-specific-gotchas)

---

## HMR Not Working

### Symptoms
- Changes to stories or components don't reflect in the browser
- Full page reload instead of hot update
- Console shows "full reload" or no HMR messages

### Solutions

**1. Vite builder — check file watching**
```ts
// .storybook/main.ts
viteFinal: async (config) => {
  config.server ??= {};
  config.server.watch = {
    usePolling: true,         // required in Docker/WSL
    interval: 1000,           // polling interval ms
    ignored: ['**/node_modules/**', '**/.git/**'],
  };
  return config;
},
```

**2. Webpack builder — enable hot**
```ts
webpackFinal: async (config) => {
  config.watchOptions = {
    poll: 1000,               // Docker/WSL
    aggregateTimeout: 300,
    ignored: /node_modules/,
  };
  return config;
},
```

**3. Story glob patterns too broad**
```ts
// BAD — too broad, causes slow or broken HMR
stories: ['../src/**/*.stories.*']

// GOOD — specific extensions
stories: ['../src/**/*.stories.@(ts|tsx)']
```

**4. Check for circular imports**
```bash
# Use madge to detect circular dependencies
npx madge --circular --extensions ts,tsx src/
```

**5. Docker/WSL — ensure CHOKIDAR is set**
```bash
CHOKIDAR_USEPOLLING=true npx storybook dev -p 6006
```

---

## Addon Conflicts

### Symptoms
- Addons panel is empty or crashes
- "Cannot read properties of undefined" in manager
- Duplicate addon registrations

### Solutions

**1. Version mismatches — align all @storybook packages**
```bash
# Check for mismatched versions
npx storybook doctor

# Force upgrade all storybook packages
npx storybook@latest upgrade

# Verify consistent versions
npm ls | grep storybook
```

**2. Addon load order matters**
```ts
// main.ts — essentials should come first
addons: [
  '@storybook/addon-essentials',   // FIRST — provides controls, actions, viewport, etc.
  '@storybook/addon-a11y',
  '@storybook/addon-interactions',
  '@storybook/addon-links',
  'storybook-addon-designs',       // third-party last
],
```

**3. Conflicting addons**
```
# These conflict — pick one:
@storybook/addon-knobs (deprecated) + @storybook/addon-controls
@storybook/addon-actions (standalone) + @storybook/addon-essentials (includes actions)

# Fix: remove the duplicate
npm uninstall @storybook/addon-knobs @storybook/addon-actions
```

**4. Clear addon cache**
```bash
rm -rf node_modules/.cache/storybook
npx storybook dev -p 6006 --no-manager-cache
```

**5. Third-party addon compatibility**
```bash
# Check addon compatibility with your Storybook version
npx storybook doctor
# If addon is incompatible, pin to a known-good version
npm install storybook-addon-designs@7.0.0
```

---

## CSS Module Problems

### Symptoms
- CSS modules not applying styles
- `[object Object]` instead of class names
- Global styles leaking between stories

### Solutions

**1. Vite — configure CSS modules**
```ts
// main.ts
viteFinal: async (config) => {
  config.css ??= {};
  config.css.modules = {
    localsConvention: 'camelCase',
    scopeBehaviour: 'local',
    generateScopedName: '[name]__[local]--[hash:base64:5]',
  };
  return config;
},
```

**2. Webpack — add CSS module loader**
```ts
webpackFinal: async (config) => {
  config.module!.rules!.push({
    test: /\.module\.css$/,
    use: [
      'style-loader',
      { loader: 'css-loader', options: { modules: true } },
    ],
  });
  return config;
},
```

**3. Tailwind CSS setup**
```ts
// preview.ts
import '../src/styles/tailwind.css'; // import your Tailwind entry point

// main.ts — ensure PostCSS config is found
viteFinal: async (config) => {
  // Vite auto-detects postcss.config.js, nothing extra needed
  return config;
},
```

**4. CSS-in-JS (styled-components, emotion)**
```ts
// preview.ts — global decorator for styled-components
import { ThemeProvider } from 'styled-components';
import { GlobalStyles } from '../src/styles/GlobalStyles';

decorators: [
  (Story) => (
    <ThemeProvider theme={theme}>
      <GlobalStyles />
      <Story />
    </ThemeProvider>
  ),
],
```

**5. Style isolation between stories**
```ts
// Per-story: reset styles via decorator
decorators: [
  (Story) => (
    <div style={{ all: 'initial' }}>
      <Story />
    </div>
  ),
],
```

---

## Monorepo Setup Issues

### Symptoms
- "Module not found" for shared packages
- Storybook can't resolve workspace dependencies
- Stories from other packages not appearing

### Solutions

**1. Configure stories globs for monorepo**
```ts
// .storybook/main.ts (at workspace root)
stories: [
  '../packages/*/src/**/*.stories.@(ts|tsx)',
  '../apps/web/src/**/*.stories.@(ts|tsx)',
],
```

**2. Resolve workspace packages**
```ts
// Vite
viteFinal: async (config) => {
  config.resolve ??= {};
  config.resolve.alias = {
    ...config.resolve.alias,
    '@myorg/ui': path.resolve(__dirname, '../packages/ui/src'),
    '@myorg/utils': path.resolve(__dirname, '../packages/utils/src'),
  };
  return config;
},

// Webpack
webpackFinal: async (config) => {
  config.resolve!.alias = {
    ...config.resolve!.alias,
    '@myorg/ui': path.resolve(__dirname, '../packages/ui/src'),
  };
  return config;
},
```

**3. Turborepo / Nx — run from correct package**
```json
// turbo.json
{
  "pipeline": {
    "storybook": {
      "dependsOn": ["^build"],
      "cache": false
    },
    "build-storybook": {
      "dependsOn": ["^build"],
      "outputs": ["storybook-static/**"]
    }
  }
}
```

**4. pnpm — shamefully-hoist or configure .npmrc**
```ini
# .npmrc
public-hoist-pattern[]=@storybook/*
public-hoist-pattern[]=storybook
shamefully-hoist=true  # nuclear option — hoists everything
```

**5. Yarn workspaces — nohoist**
```json
// root package.json
{
  "workspaces": {
    "packages": ["packages/*"],
    "nohoist": ["**/storybook", "**/storybook/**"]
  }
}
```

**6. Lerna — link packages**
```bash
npx lerna bootstrap --hoist
# or with npm workspaces
npm install  # auto-links workspaces
```

---

## TypeScript Errors in Stories

### Symptoms
- Type errors in `Meta`, `StoryObj`, or `satisfies`
- "Cannot find module '@storybook/react'"
- Props not inferred correctly

### Solutions

**1. Correct type pattern for CSF3**
```tsx
// CORRECT
import type { Meta, StoryObj } from '@storybook/react';
import { Button } from './Button';

const meta = {
  component: Button,
  // ... rest of config
} satisfies Meta<typeof Button>;
export default meta;
type Story = StoryObj<typeof meta>;

// WRONG — don't use Meta<ButtonProps>
// WRONG — don't annotate const meta: Meta<typeof Button> = { ... }
//          (use satisfies instead for better inference)
```

**2. tsconfig includes storybook files**
```json
// tsconfig.json
{
  "include": [
    "src/**/*",
    ".storybook/**/*",
    "**/*.stories.ts",
    "**/*.stories.tsx"
  ]
}
```

**3. Missing type packages**
```bash
npm install -D @types/react @types/react-dom
npm install -D @storybook/types  # for advanced typing
```

**4. react-docgen vs react-docgen-typescript**
```ts
// main.ts — use react-docgen-typescript for complex types
typescript: {
  reactDocgen: 'react-docgen-typescript',
  reactDocgenTypescriptOptions: {
    shouldExtractLiteralValuesFromEnum: true,
    shouldRemoveUndefinedFromOptional: true,
    propFilter: (prop) => {
      // filter out HTML element props
      if (prop.parent) {
        return !prop.parent.fileName.includes('node_modules/@types/react');
      }
      return true;
    },
  },
},

// Use 'react-docgen' for faster builds (less accurate with complex types)
typescript: { reactDocgen: 'react-docgen' },
```

**5. Satisfies keyword not supported**
```json
// Requires TypeScript 4.9+. Check tsconfig:
{ "compilerOptions": { "target": "ES2022" } }
// Or use explicit typing (less ideal):
const meta: Meta<typeof Button> = { ... };
```

**6. StoryObj generics not working**
```tsx
// If StoryObj<typeof meta> gives errors, use explicit generic:
type Story = StoryObj<typeof Button>;

// For complex props with intersection types:
type ButtonProps = React.ComponentProps<typeof Button>;
type Story = StoryObj<ButtonProps & { extraProp: string }>;
```

---

## Build Failures by Framework

### React

```bash
# Error: "Cannot find module 'react/jsx-runtime'"
npm install react react-dom  # ensure peer deps installed

# Error: "Multiple copies of React"
# Add to main.ts viteFinal:
config.resolve!.dedupe = ['react', 'react-dom'];

# Error: "@storybook/react requires react >= 18"
npm install react@18 react-dom@18
```

### Vue 3

```bash
# Error: "Failed to resolve component"
# Register components globally in preview.ts:
import { setup } from '@storybook/vue3';
import MyComponent from './MyComponent.vue';
setup((app) => { app.component('MyComponent', MyComponent); });

# Error: "Cannot resolve .vue files"
# Vite: install @vitejs/plugin-vue (usually auto-installed)
npm install -D @vitejs/plugin-vue

# Error with Pinia/Vuex
import { setup } from '@storybook/vue3';
import { createPinia } from 'pinia';
setup((app) => { app.use(createPinia()); });
```

### Angular

```bash
# Error: "No provider for X"
# Use applicationConfig decorator:
decorators: [applicationConfig({ providers: [provideHttpClient()] })]

# Error: "NullInjectorError"
decorators: [
  moduleMetadata({ imports: [CommonModule, FormsModule] }),
  applicationConfig({ providers: [provideAnimations()] }),
]

# Error: "Multiple @angular/core packages"
# In angular.json or project.json:
{ "architect": { "storybook": { "options": { "preserveSymlinks": true } } } }
```

### Svelte

```bash
# Error: "Cannot find module 'svelte/internal'"
npm install svelte@4  # ensure compatible version

# Error: Preprocessing not working
# main.ts:
const config: StorybookConfig = {
  framework: {
    name: '@storybook/svelte-vite',
    options: { preprocess: require('svelte-preprocess')() },
  },
};
```

---

## Memory Issues in CI

### Symptoms
- "FATAL ERROR: Ineffective mark-compacts near heap limit Allocation failed"
- "JavaScript heap out of memory" during build
- CI runner killed by OOM

### Solutions

**1. Increase Node.js memory**
```bash
export NODE_OPTIONS="--max-old-space-size=8192"
npx storybook build
```

**2. Use test build (skips docs, smaller output)**
```bash
npx storybook build --test
```

**3. Split builds for large projects**
```bash
# Build subsets of stories
STORYBOOK_STORIES_FILTER='src/components/atoms/**' npx storybook build -o dist/atoms
STORYBOOK_STORIES_FILTER='src/components/molecules/**' npx storybook build -o dist/molecules
```

**4. Reduce story count**
```ts
// main.ts — narrow globs
stories: [
  '../src/components/**/*.stories.tsx', // specific directory
  // NOT '../src/**/*.stories.*'       // too broad
],
```

**5. Chromatic TurboSnap — only test changed stories**
```yaml
- uses: chromaui/action@latest
  with:
    onlyChanged: true  # TurboSnap
    externals: |
      - public/**
```

**6. CI-specific optimizations**
```bash
# GitHub Actions — set memory
- run: npx storybook build
  env:
    NODE_OPTIONS: '--max-old-space-size=8192'

# Docker — set container memory
docker run --memory=8g node:20 sh -c "npm ci && npm run build-storybook"
```

**7. Garbage collection hints**
```bash
NODE_OPTIONS="--max-old-space-size=8192 --expose-gc" npx storybook build
```

---

## Slow Startup Optimization

### Diagnosis

```bash
# Time the startup
time npx storybook dev -p 6006 --no-open

# Profile with DEBUG
DEBUG=storybook:* npx storybook dev -p 6006

# Check story count
find src -name "*.stories.*" | wc -l
```

### Solutions

**1. Use Vite builder (faster than Webpack)**
```bash
npx storybook@latest init --type react_vite
# or migrate:
npx storybook@latest automigrate
```

**2. Narrow story globs**
```ts
// Faster indexing with specific globs
stories: ['../src/components/**/*.stories.tsx']
// Instead of: stories: ['../src/**/*']
```

**3. Lazy compilation (Webpack)**
```ts
core: {
  builder: {
    name: '@storybook/builder-webpack5',
    options: { lazyCompilation: true },
  },
},
```

**4. Reduce addons**
```ts
// Only include addons you actually use
addons: [
  '@storybook/addon-essentials',
  // Remove unused addons — each adds startup time
],
```

**5. Disable telemetry**
```ts
core: { disableTelemetry: true },
```

**6. Use SWC instead of Babel (React)**
```bash
npm install -D @storybook/addon-webpack5-compiler-swc
# main.ts
addons: ['@storybook/addon-webpack5-compiler-swc'],
```

**7. Exclude heavy dependencies**
```ts
viteFinal: async (config) => {
  config.optimizeDeps ??= {};
  config.optimizeDeps.exclude = ['heavy-lib-not-needed-in-storybook'];
  return config;
},
```

**8. Use react-docgen instead of react-docgen-typescript**
```ts
// Faster prop parsing (less accurate for complex types)
typescript: { reactDocgen: 'react-docgen' },
```

---

## React-Specific Gotchas

**Server Components** — RSC can't be rendered directly in Storybook:
```tsx
// Wrap async server components with a client-side wrapper
// button.stories.tsx
const ButtonWrapper = (props: ButtonProps) => <Button {...props} />;
const meta: Meta<typeof ButtonWrapper> = { component: ButtonWrapper };
```

**Next.js** — use `@storybook/nextjs`:
```ts
framework: { name: '@storybook/nextjs', options: {} },
// Provides next/image, next/link, next/navigation mocks
```

**React Router v6** — decorator:
```tsx
import { MemoryRouter } from 'react-router-dom';
decorators: [(Story) => <MemoryRouter><Story /></MemoryRouter>],
```

**Context providers** — stack in preview.ts:
```tsx
decorators: [
  (Story) => (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <ThemeProvider>
          <Story />
        </ThemeProvider>
      </AuthProvider>
    </QueryClientProvider>
  ),
],
```

---

## Vue-Specific Gotchas

**Plugin registration** — use setup():
```ts
import { setup } from '@storybook/vue3';
import { createI18n } from 'vue-i18n';
setup((app) => {
  app.use(createI18n({ locale: 'en', messages }));
});
```

**Provide/Inject** — decorator:
```ts
decorators: [
  () => ({
    provide: { apiClient: mockApiClient },
    template: '<story />',
  }),
],
```

**v-model** — use argTypes:
```ts
argTypes: {
  modelValue: { control: 'text' },
  'onUpdate:modelValue': { action: 'update:modelValue' },
},
```

---

## Angular-Specific Gotchas

**Standalone components** — no moduleMetadata needed:
```ts
const meta: Meta<StandaloneComponent> = {
  component: StandaloneComponent,
  // No moduleMetadata needed for standalone
};
```

**Lazy-loaded modules** — use applicationConfig:
```ts
decorators: [
  applicationConfig({
    providers: [importProvidersFrom(LazyModule)],
  }),
],
```

**Zone.js issues** — ensure polyfills:
```ts
// .storybook/preview.ts
import 'zone.js';
```

---

## Svelte-Specific Gotchas

**Slots** — use render:
```ts
export const WithSlot: Story = {
  render: (args) => ({
    Component: MyComponent,
    props: args,
    slot: '<p>Slot content</p>',
  }),
};
```

**Stores** — reset in decorators:
```ts
import { writable } from 'svelte/store';
decorators: [
  () => {
    userStore.set({ name: 'Test User' });
    return {};
  },
],
```

**SvelteKit** — use the dedicated framework:
```ts
framework: { name: '@storybook/sveltekit', options: {} },
```
