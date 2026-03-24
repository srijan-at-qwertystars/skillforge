// Production-ready SvelteKit configuration
// Copy to project root and adjust adapter/settings as needed.

import adapter from '@sveltejs/adapter-auto';
// For specific platforms, replace with:
// import adapter from '@sveltejs/adapter-node';
// import adapter from '@sveltejs/adapter-vercel';
// import adapter from '@sveltejs/adapter-cloudflare';
// import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),

	kit: {
		adapter: adapter(),

		// Path aliases — import from $components, $utils, $server in your code
		alias: {
			$components: 'src/lib/components',
			$utils: 'src/lib/utils',
			$server: 'src/lib/server'
		},

		// Content Security Policy — customize per-environment
		csp: {
			directives: {
				'script-src': ['self']
			},
			// Use <meta> tag for CSP in prerendered pages (no server to set headers)
			reportOnly: {
				'script-src': ['self']
			}
		},

		// CSRF protection — enabled by default, disable only for pure API services
		csrf: {
			checkOrigin: true
		},

		// Prerender configuration
		prerender: {
			// How to handle HTTP errors during prerendering
			handleHttpError: ({ path, referrer, message }) => {
				// Ignore missing blog images during prerender
				if (path.startsWith('/images/')) return;
				// Throw for everything else (fail the build)
				throw new Error(message);
			},
			// How to handle missing hash fragments (#anchor) during prerender
			handleMissingId: 'warn',
			// Entry points for the prerender crawler
			entries: ['*']
		},

		// Set base path for non-root deployments (e.g., GitHub Pages)
		// paths: {
		//   base: '/my-app'
		// },

		// Environment variable prefix for public vars (default: PUBLIC_)
		env: {
			publicPrefix: 'PUBLIC_'
		}

		// Adapter-specific examples:
		//
		// adapter-node:
		// adapter: adapter({
		//   out: 'build',
		//   precompress: true,
		//   envPrefix: 'APP_'
		// })
		//
		// adapter-vercel:
		// adapter: adapter({
		//   runtime: 'nodejs22.x',
		//   regions: ['iad1'],
		//   split: false
		// })
		//
		// adapter-static (full static / SPA):
		// adapter: adapter({
		//   pages: 'build',
		//   assets: 'build',
		//   fallback: '200.html',     // SPA fallback
		//   precompress: true
		// })
		//
		// adapter-cloudflare:
		// adapter: adapter({
		//   routes: {
		//     include: ['/*'],
		//     exclude: ['<all>']
		//   }
		// })
	}
};

export default config;
