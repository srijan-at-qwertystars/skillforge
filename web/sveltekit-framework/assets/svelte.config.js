// svelte.config.js — Production SvelteKit configuration
// Copy to project root and adjust adapter, aliases, and CSP as needed.

import adapter from '@sveltejs/adapter-auto';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),

	compilerOptions: {
		// Enable runes mode project-wide (Svelte 5)
		runes: true
	},

	kit: {
		adapter: adapter(),

		// Path aliases — available as $components, $utils, etc.
		alias: {
			$components: './src/lib/components',
			$utils: './src/lib/utils',
			$stores: './src/lib/stores',
			$types: './src/lib/types',
			$server: './src/lib/server'
		},

		// Content Security Policy directives
		csp: {
			directives: {
				'default-src': ['self'],
				'script-src': ['self'],
				'style-src': ['self', 'unsafe-inline'],
				'img-src': ['self', 'data:', 'https:'],
				'font-src': ['self'],
				'connect-src': ['self'],
				'frame-ancestors': ['none']
			}
		},

		// CSRF protection (enabled by default)
		csrf: {
			checkOrigin: true
		},

		// Environment variable configuration
		env: {
			dir: '.',
			publicPrefix: 'PUBLIC_'
		},

		// Prerender settings
		prerender: {
			crawl: true,
			entries: ['*'],
			handleHttpError: 'warn',
			handleMissingId: 'warn'
		},

		// Version management for detecting new deployments
		version: {
			pollInterval: 60000 // check for new version every 60s
		}
	}
};

export default config;
