// .storybook/preview.ts — Production Preview Configuration Template
// Copy to your project's .storybook/preview.ts and adjust as needed.

import type { Preview } from '@storybook/react';
// For Vue: import type { Preview } from '@storybook/vue3';

// --- Global Styles ---
// Import your app's global CSS here so stories match production appearance.
// import '../src/styles/globals.css';
// import '../src/styles/tailwind.css';

// --- MSW Setup (uncomment if using MSW for API mocking) ---
// import { initialize, mswLoader } from 'msw-storybook-addon';
// initialize({ onUnhandledRequest: 'bypass' });

const preview: Preview = {
  // --- Global Parameters ---
  parameters: {
    // Default layout for all stories
    layout: 'centered',  // 'centered' | 'padded' | 'fullscreen'

    // Controls panel
    controls: {
      expanded: true,
      sort: 'requiredFirst',  // 'alpha' | 'requiredFirst' | 'none'
      matchers: {
        color: /(background|color)$/i,
        date: /Date$/i,
      },
    },

    // Backgrounds
    backgrounds: {
      default: 'light',
      values: [
        { name: 'light', value: '#ffffff' },
        { name: 'dark', value: '#1a1a1a' },
        { name: 'gray', value: '#f3f4f6' },
      ],
    },

    // Custom viewports for responsive testing
    viewport: {
      viewports: {
        mobile: {
          name: 'Mobile (375px)',
          styles: { width: '375px', height: '812px' },
        },
        mobileLandscape: {
          name: 'Mobile Landscape',
          styles: { width: '812px', height: '375px' },
        },
        tablet: {
          name: 'Tablet (768px)',
          styles: { width: '768px', height: '1024px' },
        },
        desktop: {
          name: 'Desktop (1440px)',
          styles: { width: '1440px', height: '900px' },
        },
        wide: {
          name: 'Wide (1920px)',
          styles: { width: '1920px', height: '1080px' },
        },
      },
    },

    // Docs configuration
    docs: {
      toc: true,  // Table of contents in docs pages
    },
  },

  // --- Global Decorators ---
  decorators: [
    // Example: Wrap all stories in a layout container
    (Story) => (
      <div style={{ fontFamily: 'system-ui, -apple-system, sans-serif' }}>
        <Story />
      </div>
    ),

    // Example: Theme provider decorator (reads from toolbar)
    // (Story, context) => {
    //   const theme = context.globals.theme === 'dark' ? darkTheme : lightTheme;
    //   return (
    //     <ThemeProvider theme={theme}>
    //       <Story />
    //     </ThemeProvider>
    //   );
    // },

    // Example: Router provider for Next.js / React Router
    // (Story) => (
    //   <MemoryRouter>
    //     <Story />
    //   </MemoryRouter>
    // ),
  ],

  // --- Loaders ---
  loaders: [
    // Uncomment for MSW:
    // mswLoader,
  ],

  // --- Toolbar Controls (Globals) ---
  globalTypes: {
    theme: {
      description: 'Global theme for components',
      toolbar: {
        title: 'Theme',
        icon: 'circlehollow',
        items: [
          { value: 'light', title: 'Light', icon: 'sun' },
          { value: 'dark', title: 'Dark', icon: 'moon' },
        ],
        dynamicTitle: true,
      },
    },
    locale: {
      description: 'Internationalization locale',
      toolbar: {
        title: 'Locale',
        icon: 'globe',
        items: [
          { value: 'en', right: '🇺🇸', title: 'English' },
          { value: 'fr', right: '🇫🇷', title: 'Français' },
          { value: 'de', right: '🇩🇪', title: 'Deutsch' },
          { value: 'ja', right: '🇯🇵', title: '日本語' },
        ],
        dynamicTitle: true,
      },
    },
  },

  // --- Default Tags ---
  tags: ['autodocs'],

  // --- Lifecycle Hooks ---
  // beforeAll: async () => {
  //   // One-time global setup (e.g., initialize MSW)
  // },
  // beforeEach: () => {
  //   // Runs before each story render
  //   return () => {
  //     // Cleanup after each story
  //   };
  // },
};

export default preview;
