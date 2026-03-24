// preview-config.ts — Production-ready Storybook preview configuration
//
// Copy to .storybook/preview.ts and customize for your project.
// This includes global decorators, parameters, loaders, and theme setup.
//
// Usage: cp preview-config.ts .storybook/preview.ts

import type { Preview, Decorator } from '@storybook/react';

// --- Import your global styles ---
// import '../src/styles/globals.css';
// import '../src/styles/tailwind.css';

// --- MSW (if using API mocking) ---
// import { initialize, mswLoader } from 'msw-storybook-addon';
// initialize({ onUnhandledRequest: 'bypass' });

// --- Theme (from your design system) ---
// import { ThemeProvider } from 'styled-components'; // or @emotion/react, etc.
// import { lightTheme, darkTheme } from '../src/styles/theme';

// ============================================================
// Decorators — wrap every story
// ============================================================

/** Provides theme context based on global toolbar selection */
const ThemeDecorator: Decorator = (Story, context) => {
  // const theme = context.globals.theme === 'dark' ? darkTheme : lightTheme;
  // return (
  //   <ThemeProvider theme={theme}>
  //     <Story />
  //   </ThemeProvider>
  // );
  return <Story />;
};

/** Wraps stories in common providers (router, query client, auth, etc.) */
const ProvidersDecorator: Decorator = (Story) => {
  // return (
  //   <QueryClientProvider client={new QueryClient()}>
  //     <MemoryRouter>
  //       <AuthProvider>
  //         <Story />
  //       </AuthProvider>
  //     </MemoryRouter>
  //   </QueryClientProvider>
  // );
  return <Story />;
};

/** Adds consistent padding and background */
const LayoutDecorator: Decorator = (Story, context) => {
  // Skip padding for fullscreen stories
  if (context.parameters.layout === 'fullscreen') {
    return <Story />;
  }
  return (
    <div style={{ padding: '1rem' }}>
      <Story />
    </div>
  );
};

// ============================================================
// Parameters — configure addon behavior globally
// ============================================================

const parameters = {
  // Layout
  layout: 'centered' as const,

  // Controls addon — auto-detect control types
  controls: {
    matchers: {
      color: /(background|color)$/i,
      date: /Date$/i,
    },
    expanded: true, // show description and default value columns
    sort: 'requiredFirst' as const,
  },

  // Actions addon — auto-detect event handlers
  actions: {
    argTypesRegex: '^on[A-Z].*',
  },

  // Docs addon
  docs: {
    toc: true, // table of contents in docs pages
  },

  // Viewport addon
  viewport: {
    viewports: {
      mobile: { name: 'Mobile', styles: { width: '375px', height: '812px' } },
      tablet: { name: 'Tablet', styles: { width: '768px', height: '1024px' } },
      desktop: { name: 'Desktop', styles: { width: '1440px', height: '900px' } },
    },
  },

  // Backgrounds addon
  backgrounds: {
    default: 'light',
    values: [
      { name: 'light', value: '#FFFFFF' },
      { name: 'dark', value: '#1A1A2E' },
      { name: 'neutral', value: '#F5F5F5' },
    ],
  },

  // Accessibility addon
  a11y: {
    config: {
      rules: [
        { id: 'color-contrast', enabled: true },
        // Disable rules that don't apply at component level
        { id: 'landmark-one-main', enabled: false },
        { id: 'page-has-heading-one', enabled: false },
        { id: 'region', enabled: false },
      ],
    },
  },

  // Chromatic visual testing (if using)
  // chromatic: {
  //   modes: {
  //     light: { theme: 'light' },
  //     dark: { theme: 'dark' },
  //   },
  // },
};

// ============================================================
// Global types — toolbar controls
// ============================================================

const globalTypes = {
  theme: {
    description: 'Global theme for components',
    toolbar: {
      title: 'Theme',
      icon: 'paintbrush',
      items: [
        { value: 'light', title: 'Light', icon: 'sun' },
        { value: 'dark', title: 'Dark', icon: 'moon' },
      ],
      dynamicTitle: true,
    },
  },
  locale: {
    description: 'Locale for internationalization',
    toolbar: {
      title: 'Locale',
      icon: 'globe',
      items: [
        { value: 'en', title: 'English' },
        { value: 'es', title: 'Español' },
        { value: 'fr', title: 'Français' },
        { value: 'ja', title: '日本語' },
      ],
      dynamicTitle: true,
    },
  },
};

// ============================================================
// Loaders — async data before stories render
// ============================================================

const loaders = [
  // MSW loader (if using msw-storybook-addon)
  // mswLoader,

  // Custom global loader
  // async () => ({
  //   featureFlags: await fetch('/api/features').then((r) => r.json()),
  // }),
];

// ============================================================
// Initial globals — default toolbar values
// ============================================================

const initialGlobals = {
  theme: 'light',
  locale: 'en',
};

// ============================================================
// Export preview configuration
// ============================================================

const preview: Preview = {
  parameters,
  globalTypes,
  initialGlobals,
  loaders,
  decorators: [
    ThemeDecorator,
    ProvidersDecorator,
    LayoutDecorator,
  ],
  tags: ['autodocs'], // enable autodocs for all stories
};

export default preview;
