// Root layout server load — src/routes/+layout.server.ts
// Provides the authenticated user session to all pages.
// Copy to src/routes/+layout.server.ts.

import type { LayoutServerLoad } from './$types';

export const load: LayoutServerLoad = async ({ locals, cookies, url }) => {
	// locals.user is populated by hooks.server.ts (auth hook)
	// This makes user data available in ALL pages via data.user

	// Optional: track last visited URL for redirect-after-login
	if (locals.user && url.pathname !== '/login') {
		cookies.set('last_path', url.pathname, {
			path: '/',
			httpOnly: true,
			sameSite: 'lax',
			secure: true,
			maxAge: 60 * 60 // 1 hour
		});
	}

	return {
		user: locals.user
			? {
					id: locals.user.id,
					email: locals.user.email,
					name: locals.user.name
					// Omit sensitive fields (role, tokens, etc.) unless needed
				}
			: null
	};
};

// Usage in any +page.svelte or +layout.svelte:
//
// <script>
//   let { data } = $props();
//   // data.user is available on every page
// </script>
//
// {#if data.user}
//   <p>Hello, {data.user.name}</p>
// {:else}
//   <a href="/login">Sign in</a>
// {/if}
//
// Usage in child +page.server.ts load functions:
//
// export const load: PageServerLoad = async ({ parent }) => {
//   const { user } = await parent();
//   // Use user data — but prefer locals.user to avoid waterfall
// };
//
// Protected route pattern (in group layout):
//
// // src/routes/(protected)/+layout.server.ts
// import { redirect } from '@sveltejs/kit';
// import type { LayoutServerLoad } from './$types';
//
// export const load: LayoutServerLoad = async ({ locals }) => {
//   if (!locals.user) redirect(303, '/login');
//   return { user: locals.user };
// };
