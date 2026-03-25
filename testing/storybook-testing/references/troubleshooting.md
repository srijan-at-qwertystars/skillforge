# Storybook 8.x Troubleshooting Guide

## Table of Contents

- [Build Errors](#build-errors)
- [Missing Styles & Assets](#missing-styles--assets)
- [Slow Startup & Performance](#slow-startup--performance)
- [HMR Issues](#hmr-issues)
- [Play Function Failures](#play-function-failures)
- [Test-Runner Flakiness](#test-runner-flakiness)
- [Framework-Specific Issues](#framework-specific-issues)
- [Addon Compatibility](#addon-compatibility)
- [Migration from Storybook 7](#migration-from-storybook-7)

---

## Build Errors

### Webpack Config Conflicts

**Symptom:** `Module not found`, `Cannot resolve module`, or duplicate plugin errors.

**Causes & Fixes:**

1. **Conflicting aliases:** Storybook merges your project's Webpack config. If you define `resolve.alias` in both, they can conflict.
   ```ts
   // .storybook/main.ts
   webpackFinal: async (config) => {
     config.resolve!.alias = {
       ...config.resolve!.alias,
       '@': path.resolve(__dirname, '../src'),
     };
     return config;
   },
   ```

2. **Duplicate plugins:** Never re-add plugins Storybook already includes (HtmlWebpackPlugin, DefinePlugin). Check existing plugins first:
   ```ts
   webpackFinal: async (config) => {
     // Remove conflicting plugin before adding yours
     config.plugins = config.plugins!.filter(
       (p) => p?.constructor?.name !== 'ConflictingPlugin'
     );
     config.plugins.push(new YourPlugin());
     return config;
   },
   ```

3. **CSS/PostCSS loader conflicts:** If using Tailwind or custom PostCSS:
   ```ts
   webpackFinal: async (config) => {
     const cssRule = config.module!.rules!.find(
       (rule) => rule && typeof rule === 'object' && rule.test?.toString().includes('css')
     );
     // Modify or replace the CSS rule as needed
     return config;
   },
   ```

### Vite Config Conflicts

**Symptom:** `Pre-transform error`, plugin errors, or blank Storybook page.

**Causes & Fixes:**

1. **Incompatible Vite plugins:** Some plugins (e.g., `vite-plugin-pages`, `vite-plugin-pwa`) break Storybook. Exclude them:
   ```ts
   // .storybook/main.ts
   async viteFinal(config) {
     config.plugins = config.plugins?.filter(
       (p) => !['vite:pwa', 'vite-plugin-pages'].includes(
         Array.isArray(p) ? '' : (p as any)?.name ?? ''
       )
     );
     return config;
   },
   ```
   Or use the helper:
   ```ts
   import { withoutVitePlugins } from '@storybook/builder-vite';

   async viteFinal(config) {
     return withoutVitePlugins(config, ['vite-plugin-pwa']);
   },
   ```

2. **Vite `define` conflicts:** Storybook sets its own `define` values. Merge carefully:
   ```ts
   async viteFinal(config) {
     return mergeConfig(config, {
       define: { 'process.env.MY_VAR': JSON.stringify('value') },
     });
   },
   ```

3. **Relative path issues:** Vite resolves paths relative to project root. Use absolute paths:
   ```ts
   import { mergeConfig } from 'vite';
   import path from 'path';

   async viteFinal(config) {
     return mergeConfig(config, {
       resolve: {
         alias: { '@': path.resolve(__dirname, '../src') },
       },
     });
   },
   ```

### TypeScript Errors

**Symptom:** `Cannot find module` or type errors in `.storybook/` files.

**Fix:** Ensure `.storybook/` is included in your `tsconfig.json`:
```jsonc
{
  "include": ["src", ".storybook"],
  "compilerOptions": {
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx"
  }
}
```

---

## Missing Styles & Assets

### Global Styles Not Applied

**Symptom:** Components render without CSS in Storybook.

**Fix:** Import global styles in `.storybook/preview.ts`:
```ts
import '../src/styles/globals.css';
import '../src/styles/tailwind.css';
```

### Tailwind CSS Not Working

**Symptom:** Tailwind classes have no effect.

**Checklist:**
1. Import Tailwind in preview: `import '../src/styles/tailwind.css';`
2. Ensure `tailwind.config.js` `content` array includes story files:
   ```js
   content: [
     './src/**/*.{js,ts,jsx,tsx}',
     './.storybook/**/*.{js,ts,jsx,tsx}',  // Include storybook files
   ],
   ```
3. For Vite, ensure PostCSS config is picked up (usually automatic).

### Static Assets (Images, Fonts) Not Loading

**Symptom:** 404 errors for images/fonts.

**Fix:** Configure `staticDirs` in main config:
```ts
const config: StorybookConfig = {
  staticDirs: ['../public', '../src/assets'],
};
```

### CSS Modules Not Resolving

**Symptom:** Styles from `.module.css` files not applied.

**Fix (Webpack):** Storybook should handle CSS Modules out of the box. If not, add the loader:
```ts
webpackFinal: async (config) => {
  config.module!.rules!.push({
    test: /\.module\.css$/,
    use: ['style-loader', { loader: 'css-loader', options: { modules: true } }],
  });
  return config;
},
```

---

## Slow Startup & Performance

### Storybook Takes Minutes to Start

**Causes & Fixes:**

1. **Too many stories matched:** Narrow the glob in `stories`:
   ```ts
   // Bad — scans everything
   stories: ['../src/**/*.stories.*']
   // Better — targeted
   stories: ['../src/components/**/*.stories.tsx']
   ```

2. **Heavy addons:** Remove unused addons. Each addon adds startup cost.

3. **Disable on-demand docs generation:** If not using autodocs:
   ```ts
   // Remove 'autodocs' from default tags
   tags: [],
   ```

4. **Use Vite builder:** Vite is significantly faster than Webpack for Storybook:
   ```bash
   npx storybook@latest automigrate --use-vite
   ```

5. **Disable sourcemaps in dev (Webpack):**
   ```ts
   webpackFinal: async (config) => {
     config.devtool = false;
     return config;
   },
   ```

### Build is Slow

Use `--test` flag for CI builds (skips docs, sourcemaps):
```bash
npx storybook build --test
```

---

## HMR Issues

### Changes Don't Reflect

**Symptom:** Editing components/stories doesn't trigger reload.

**Fixes:**

1. **Check story glob patterns:** Files must match the `stories` glob in `main.ts`.

2. **Vite cached modules:** Clear Vite cache:
   ```bash
   rm -rf node_modules/.cache/storybook
   rm -rf node_modules/.vite
   ```

3. **Webpack cache:** Clear Webpack's persistent cache:
   ```bash
   rm -rf node_modules/.cache
   ```

4. **File system case sensitivity:** On macOS, file casing mismatches can break HMR. Ensure import casing matches the actual file name exactly.

### Full Page Reloads Instead of HMR

**Symptom:** Browser does a full reload instead of hot-updating.

**Fix (Vite):** Avoid exporting non-story values from story files. Only export `default` (meta) and named stories.

**Fix (Webpack):** Ensure `react-refresh` or equivalent is not conflicting. Check for duplicate React instances.

---

## Play Function Failures

### `canvasElement` is null/undefined

**Cause:** The component didn't render before the play function ran.

**Fix:** Always use `waitFor` for assertions that depend on async rendering:
```tsx
play: async ({ canvasElement }) => {
  const canvas = within(canvasElement);
  await waitFor(() => {
    expect(canvas.getByRole('button')).toBeInTheDocument();
  });
},
```

### `userEvent` Actions Have No Effect

**Causes:**

1. **Element not interactive:** Ensure buttons aren't disabled, inputs aren't readonly.
2. **Element hidden behind overlay:** Use `{ pointerEventsCheck: 0 }`:
   ```tsx
   await userEvent.click(canvas.getByRole('button'), {
     pointerEventsCheck: 0,
   });
   ```
3. **Wrong element selected:** Use more specific queries (`getByRole`, `getByLabelText`) over `getByText`.

### Assertions Fail Intermittently

**Cause:** Race conditions between render and assertion.

**Fix:** Wrap in `waitFor`:
```tsx
await waitFor(() => {
  expect(canvas.getByText('Success')).toBeInTheDocument();
}, { timeout: 3000 });
```

### `fn()` Mock Not Recording Calls

**Cause:** The component uses a different reference than the mock.

**Fix:** Ensure the mock is passed via `args`, not imported directly:
```tsx
const meta = {
  component: Form,
  args: { onSubmit: fn() },  // Passed as prop
} satisfies Meta<typeof Form>;
```

---

## Test-Runner Flakiness

### Tests Pass Locally but Fail in CI

**Common Causes:**

1. **Storybook not ready:** Ensure Storybook is fully loaded before running tests:
   ```bash
   npx concurrently -k -s first \
     "npx http-server storybook-static -p 6006 --silent" \
     "npx wait-on tcp:6006 && npx test-storybook"
   ```

2. **Resource constraints in CI:** Add retry and increase timeouts:
   ```bash
   npx test-storybook --maxWorkers=2 --testTimeout=30000
   ```

3. **Missing browsers:** Install Playwright browsers in CI:
   ```bash
   npx playwright install --with-deps chromium
   ```

### Stories Timeout

**Fix:** Increase test timeout in `jest` config or CLI:
```bash
npx test-storybook --testTimeout=60000
```

Or in `.storybook/test-runner.ts`:
```ts
const config: TestRunnerConfig = {
  async postVisit(page) {
    // Increase per-story timeout
    page.setDefaultTimeout(30000);
  },
};
```

### Snapshot Mismatches

**Cause:** Animations, timestamps, random IDs, or non-deterministic content.

**Fixes:**
1. Disable animations: `parameters: { chromatic: { pauseAnimationAtEnd: true } }`
2. Mock `Date.now()` and `Math.random()` in `beforeEach`
3. Add `chromatic: { delay: 500 }` for components with transitions

---

## Framework-Specific Issues

### Next.js

**`next/image` not rendering:**
- Use `@storybook/nextjs` (Webpack) or `@storybook/nextjs-vite`. Both handle `next/image` automatically.
- For unoptimized images: `parameters: { nextjs: { image: { unoptimized: true } } }`

**`useRouter` / `usePathname` errors:**
- `@storybook/nextjs` provides automatic mocking. Override per-story:
  ```tsx
  export const OnSettingsPage: Story = {
    parameters: {
      nextjs: {
        navigation: {
          pathname: '/settings',
          query: { tab: 'profile' },
        },
      },
    },
  };
  ```
- For App Router: `parameters: { nextjs: { appDirectory: true } }`

**Server Components:**
- RSC support is experimental. Wrap server components in Suspense:
  ```tsx
  export const ServerComponent: Story = {
    render: () => (
      <Suspense fallback={<div>Loading...</div>}>
        <MyServerComponent />
      </Suspense>
    ),
  };
  ```
- Mock server-only modules via subpath imports.

**`next/font` not loading:**
- `@storybook/nextjs` handles `next/font/google` and `next/font/local` automatically.
- If custom fonts fail, add the font files to `staticDirs`.

### Vue 3

**Plugin registration errors (`app.use()` not available):**
- Register plugins in `.storybook/preview.ts` using the `setup` function:
  ```ts
  import { setup } from '@storybook/vue3';
  import { createPinia } from 'pinia';
  import { createI18n } from 'vue-i18n';

  setup((app) => {
    app.use(createPinia());
    app.use(createI18n({ locale: 'en', messages }));
  });
  ```

**Pinia store not available:**
```ts
setup((app) => {
  const pinia = createPinia();
  app.use(pinia);
});
```

**Vue Router in stories:**
```ts
import { vueRouter } from 'storybook-vue3-router';

export const WithRouter: Story = {
  decorators: [
    vueRouter([
      { path: '/', component: Home },
      { path: '/about', component: About },
    ]),
  ],
};
```

### Angular

**Dependency injection not working:**
```ts
const meta: Meta<MyComponent> = {
  component: MyComponent,
  decorators: [
    moduleMetadata({
      imports: [CommonModule, HttpClientModule],
      providers: [
        { provide: MyService, useValue: mockMyService },
      ],
    }),
    applicationConfig({
      providers: [provideRouter([])],
    }),
  ],
};
```

**Standalone components (Angular 15+):**
```ts
const meta: Meta<StandaloneComponent> = {
  component: StandaloneComponent,
  // No moduleMetadata needed for standalone components
  // Just provide any required services
  decorators: [
    applicationConfig({
      providers: [provideHttpClient()],
    }),
  ],
};
```

---

## Addon Compatibility

### Version Mismatch Errors

**Symptom:** `Addon X is not compatible with Storybook 8`.

**Fix:** Ensure all `@storybook/*` packages are the same version:
```bash
npx storybook@latest upgrade
```

Check for outdated community addons:
```bash
npm ls | grep storybook
```

### Common Addon Issues

| Addon | Issue | Fix |
|-------|-------|-----|
| `storybook-dark-mode` | Toolbar missing | Update to v4+ for SB8 compat |
| `storybook-addon-designs` | Panel empty | Update to v8-compatible version |
| `@storybook/addon-storysource` | Removed in SB8 | Use code panel in Docs instead |
| `storybook-addon-next-router` | Not needed with `@storybook/nextjs` | Remove; use built-in `parameters.nextjs` |

### Implicit Actions Removed in SB8

**Symptom:** `argTypesRegex` warning; actions not logged.

**Fix:** Replace `argTypesRegex` with explicit `fn()` in args:
```diff
 const meta = {
   component: Button,
-  parameters: { actions: { argTypesRegex: '^on[A-Z].*' } },
+  args: { onClick: fn(), onHover: fn() },
 } satisfies Meta<typeof Button>;
```

---

## Migration from Storybook 7

### Quick Checklist

1. Run the automigration: `npx storybook@latest upgrade`
2. Remove `storiesOf` usage → convert to CSF3
3. Remove `*.stories.mdx` → use `*.mdx` + `*.stories.tsx` separately
4. Replace `@storybook/testing-library` → `@storybook/test`
5. Replace `@storybook/jest` → `@storybook/test`
6. Replace `argTypesRegex` → explicit `fn()` args
7. Update `composeStories` import path
8. Remove Storyshots → use test-runner or portable stories

### Breaking Changes Summary

| Storybook 7 | Storybook 8 |
|-------------|-------------|
| `@storybook/testing-library` | `@storybook/test` |
| `@storybook/jest` | `@storybook/test` |
| `storiesOf()` API | Removed — use CSF3 |
| `*.stories.mdx` | Removed — use separate `.mdx` |
| `argTypesRegex` for actions | Removed — use `fn()` |
| Storyshots | Removed — use test-runner |
| Node 16 | Minimum Node 18 |
