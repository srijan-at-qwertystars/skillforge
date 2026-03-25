// .storybook/main.ts — Production Storybook Configuration Template
// Copy to your project's .storybook/main.ts and adjust as needed.

import type { StorybookConfig } from '@storybook/react-vite';
// For other frameworks, change the import:
//   '@storybook/nextjs'
//   '@storybook/vue3-vite'
//   '@storybook/angular'
//   '@storybook/svelte-vite'

import path from 'path';

const config: StorybookConfig = {
  // --- Framework ---
  framework: {
    name: '@storybook/react-vite',
    options: {},
  },

  // --- Story Discovery ---
  stories: [
    '../src/**/*.stories.@(ts|tsx)',
    '../src/**/*.mdx',
  ],

  // --- Addons ---
  addons: [
    // Core: Controls, Actions, Viewport, Backgrounds, Measure, Outline
    '@storybook/addon-essentials',
    // Accessibility checks (axe-core)
    '@storybook/addon-a11y',
    // Play function debugger (Interactions panel)
    '@storybook/addon-interactions',
    // Chromatic visual testing integration
    '@chromatic-com/storybook',
  ],

  // --- Static Assets ---
  staticDirs: ['../public'],

  // --- Docs ---
  docs: {
    defaultName: 'Documentation',
  },

  // --- Core Settings ---
  core: {
    disableTelemetry: true,
  },

  // --- TypeScript ---
  typescript: {
    reactDocgen: 'react-docgen-typescript',
    reactDocgenTypescriptOptions: {
      shouldExtractLiteralValuesFromEnum: true,
      shouldExtractValuesFromUnion: true,
      // Exclude node_modules props from docs
      propFilter: (prop) =>
        !prop.parent?.fileName?.includes('node_modules'),
    },
  },

  // --- Vite Customization ---
  async viteFinal(config, { configType }) {
    const { mergeConfig } = await import('vite');
    return mergeConfig(config, {
      resolve: {
        alias: {
          '@': path.resolve(__dirname, '../src'),
          '@components': path.resolve(__dirname, '../src/components'),
        },
      },
      // Production optimizations
      ...(configType === 'PRODUCTION' && {
        build: {
          sourcemap: false,
          minify: true,
        },
      }),
    });
  },

  // --- Webpack Customization (use instead of viteFinal for Webpack) ---
  // async webpackFinal(config) {
  //   config.resolve!.alias = {
  //     ...config.resolve!.alias,
  //     '@': path.resolve(__dirname, '../src'),
  //   };
  //   return config;
  // },

  // --- Storybook Composition (multi-Storybook) ---
  // refs: {
  //   'design-system': {
  //     title: 'Design System',
  //     url: 'https://design-system.example.com/storybook',
  //   },
  // },
};

export default config;
