/**
 * Electron Forge Configuration Template
 *
 * This configuration provides:
 * - Vite bundling for main and renderer processes
 * - Auto-unpacking of native modules
 * - Electron Fuses for security hardening
 * - Platform-specific build targets (DMG, NSIS, deb/rpm/AppImage)
 * - macOS code signing and notarization
 * - Windows code signing
 * - GitHub Releases publishing
 *
 * Environment variables required for signing/publishing:
 *   macOS:  APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID
 *   Windows: WIN_CSC_LINK, WIN_CSC_KEY_PASSWORD
 *   Publish: GITHUB_TOKEN
 */

import type { ForgeConfig } from '@electron-forge/shared-types';
import { MakerSquirrel } from '@electron-forge/maker-squirrel';
import { MakerZIP } from '@electron-forge/maker-zip';
import { MakerDMG } from '@electron-forge/maker-dmg';
import { MakerDeb } from '@electron-forge/maker-deb';
import { MakerRpm } from '@electron-forge/maker-rpm';
import { VitePlugin } from '@electron-forge/plugin-vite';
import { AutoUnpackNativesPlugin } from '@electron-forge/plugin-auto-unpack-natives';
import { FusesPlugin } from '@electron-forge/plugin-fuses';
import { FuseV1Options, FuseVersion } from '@electron/fuses';
import { PublisherGithub } from '@electron-forge/publisher-github';

const config: ForgeConfig = {
  // ─── Packager Configuration ───────────────────────────────────────────────
  packagerConfig: {
    name: 'MyElectronApp',
    executableName: 'my-electron-app',
    appBundleId: 'com.example.my-electron-app',
    icon: './assets/icon', // .icns for macOS, .ico for Windows (omit extension)
    asar: true,

    // macOS-specific
    darwinDarkModeSupport: true,
    osxSign: {},
    osxNotarize: process.env.APPLE_ID
      ? {
          appleId: process.env.APPLE_ID,
          appleIdPassword: process.env.APPLE_APP_SPECIFIC_PASSWORD!,
          teamId: process.env.APPLE_TEAM_ID!,
        }
      : undefined,

    // Ignore dev-only files when packaging
    ignore: [
      /^\/src$/,
      /^\/\.vscode$/,
      /^\/\.github$/,
      /^\/\.eslintrc/,
      /^\/tsconfig/,
      /^\/.gitignore$/,
      /^\/README\.md$/,
    ],

    // Protocol handler (deep linking)
    protocols: [
      {
        name: 'My Electron App',
        schemes: ['my-electron-app'],
      },
    ],
  },

  // ─── Rebuild Configuration ────────────────────────────────────────────────
  rebuildConfig: {
    // Force rebuild native modules for Electron's Node.js version
    force: true,
  },

  // ─── Makers (Build Targets) ───────────────────────────────────────────────
  makers: [
    // macOS — DMG and ZIP
    new MakerDMG({
      format: 'ULFO',
      icon: './assets/icon.icns',
      contents: (opts) => [
        { x: 130, y: 220, type: 'file', path: opts.appPath },
        { x: 410, y: 220, type: 'link', path: '/Applications' },
      ],
    }),
    new MakerZIP({}, ['darwin']),

    // Windows — Squirrel installer
    new MakerSquirrel({
      setupIcon: './assets/icon.ico',
      iconUrl: 'https://raw.githubusercontent.com/your-org/your-app/main/assets/icon.ico',
      // certificateFile: process.env.WIN_CSC_LINK,
      // certificatePassword: process.env.WIN_CSC_KEY_PASSWORD,
    }),

    // Linux — deb and rpm
    new MakerDeb({
      options: {
        maintainer: 'Your Name <your@email.com>',
        homepage: 'https://github.com/your-org/your-app',
        icon: './assets/icon.png',
        categories: ['Utility'],
        section: 'utils',
        mimeType: ['x-scheme-handler/my-electron-app'],
      },
    }),
    new MakerRpm({
      options: {
        homepage: 'https://github.com/your-org/your-app',
        icon: './assets/icon.png',
        categories: ['Utility'],
        license: 'MIT',
      },
    }),
  ],

  // ─── Plugins ──────────────────────────────────────────────────────────────
  plugins: [
    // Vite bundling for main, preload, and renderer
    new VitePlugin({
      build: [
        {
          entry: 'src/main.ts',
          config: 'vite.main.config.ts',
          target: 'main',
        },
        {
          entry: 'src/preload.ts',
          config: 'vite.preload.config.ts',
          target: 'preload',
        },
      ],
      renderer: [
        {
          name: 'main_window',
          config: 'vite.renderer.config.ts',
        },
      ],
    }),

    // Auto-unpack native .node modules from ASAR
    new AutoUnpackNativesPlugin({}),

    // Electron Fuses — security hardening at binary level
    new FusesPlugin({
      version: FuseVersion.V1,
      [FuseV1Options.RunAsNode]: false,
      [FuseV1Options.EnableCookieEncryption]: true,
      [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
      [FuseV1Options.EnableNodeCliInspectArguments]: false,
      [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
      [FuseV1Options.OnlyLoadAppFromAsar]: true,
      [FuseV1Options.GrantFileProtocolExtraPrivileges]: false,
    }),
  ],

  // ─── Publishers ───────────────────────────────────────────────────────────
  publishers: [
    new PublisherGithub({
      repository: {
        owner: 'your-org',
        name: 'your-app',
      },
      prerelease: false,
      draft: true, // Create as draft — review before publishing
    }),
  ],

  // ─── Hooks ────────────────────────────────────────────────────────────────
  hooks: {
    generateAssets: async () => {
      // Generate icons, build CSS, etc. before packaging
    },
    postMake: async (_config, makeResults) => {
      console.log('Build artifacts:');
      for (const result of makeResults) {
        for (const artifact of result.artifacts) {
          console.log(`  → ${artifact}`);
        }
      }
    },
  },
};

export default config;
