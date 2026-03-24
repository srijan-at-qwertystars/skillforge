<!--
  route-template.svelte — Complete SvelteKit route template
  Demonstrates: load data, form actions, error handling, SEO, and progressive enhancement.
  Copy to src/routes/<your-route>/+page.svelte and customize.

  Pair with a +page.server.ts that exports `load` and `actions`.
-->
<script lang="ts">
	import { enhance } from '$app/forms';
	import { goto, invalidateAll } from '$app/navigation';
	import { page } from '$app/state';

	// Data from load function and form action result
	let { data, form } = $props();

	// Local reactive state
	let isSubmitting = $state(false);
	let showConfirmation = $state(false);

	// Derived state
	let itemCount = $derived(data.items?.length ?? 0);
	let hasErrors = $derived(form?.errors && Object.keys(form.errors).length > 0);

	// Format helpers
	function formatDate(date: string): string {
		return new Intl.DateTimeFormat('en-US', {
			year: 'numeric',
			month: 'short',
			day: 'numeric'
		}).format(new Date(date));
	}
</script>

<!-- SEO and meta tags -->
<svelte:head>
	<title>{data.title ?? 'Page Title'} | My App</title>
	<meta name="description" content={data.description ?? 'Page description'} />
	<meta property="og:title" content={data.title ?? 'Page Title'} />
	<meta property="og:description" content={data.description ?? 'Page description'} />
	<link rel="canonical" href={page.url.href} />
</svelte:head>

<main class="container">
	<!-- Page header -->
	<header>
		<h1>{data.title ?? 'Page Title'}</h1>
		{#if data.subtitle}
			<p class="subtitle">{data.subtitle}</p>
		{/if}
	</header>

	<!-- Success message from form action -->
	{#if form?.success}
		<div class="alert alert-success" role="alert">
			<p>✅ {form.message ?? 'Action completed successfully.'}</p>
		</div>
	{/if}

	<!-- Error messages from form action -->
	{#if hasErrors}
		<div class="alert alert-error" role="alert">
			<p>Please fix the following errors:</p>
			<ul>
				{#each Object.entries(form.errors) as [field, message]}
					<li><strong>{field}:</strong> {message}</li>
				{/each}
			</ul>
		</div>
	{/if}

	<!-- Form with progressive enhancement -->
	<section>
		<h2>Create Item</h2>
		<form
			method="POST"
			action="?/create"
			use:enhance={() => {
				isSubmitting = true;
				return async ({ result, update }) => {
					isSubmitting = false;
					if (result.type === 'success') {
						showConfirmation = true;
						setTimeout(() => (showConfirmation = false), 3000);
					}
					await update();
				};
			}}
		>
			<div class="form-group">
				<label for="name">Name</label>
				<input
					id="name"
					name="name"
					type="text"
					required
					value={form?.data?.name ?? ''}
					class:error={form?.errors?.name}
					aria-invalid={form?.errors?.name ? 'true' : undefined}
					aria-describedby={form?.errors?.name ? 'name-error' : undefined}
				/>
				{#if form?.errors?.name}
					<p id="name-error" class="field-error">{form.errors.name}</p>
				{/if}
			</div>

			<div class="form-group">
				<label for="email">Email</label>
				<input
					id="email"
					name="email"
					type="email"
					required
					value={form?.data?.email ?? ''}
					class:error={form?.errors?.email}
				/>
			</div>

			<div class="form-group">
				<label for="category">Category</label>
				<select id="category" name="category">
					{#each data.categories ?? [] as category}
						<option value={category.id}>{category.name}</option>
					{/each}
				</select>
			</div>

			<button type="submit" disabled={isSubmitting}>
				{isSubmitting ? 'Saving...' : 'Create Item'}
			</button>
		</form>
	</section>

	<!-- Data list with empty state -->
	<section>
		<h2>Items ({itemCount})</h2>

		{#if itemCount === 0}
			<div class="empty-state">
				<p>No items yet. Create one above.</p>
			</div>
		{:else}
			<ul class="item-list">
				{#each data.items as item (item.id)}
					<li class="item-card">
						<div>
							<h3>{item.name}</h3>
							<p class="meta">Created {formatDate(item.createdAt)}</p>
						</div>
						<div class="actions">
							<a href="/{item.id}/edit">Edit</a>
							<form method="POST" action="?/delete" use:enhance>
								<input type="hidden" name="id" value={item.id} />
								<button type="submit" class="btn-danger">Delete</button>
							</form>
						</div>
					</li>
				{/each}
			</ul>
		{/if}
	</section>

	<!-- Async/streamed data -->
	{#if data.analytics}
		<section>
			<h2>Analytics</h2>
			{#await data.analytics}
				<p class="loading">Loading analytics...</p>
			{:then analytics}
				<dl>
					<dt>Total Views</dt>
					<dd>{analytics.views}</dd>
					<dt>Unique Visitors</dt>
					<dd>{analytics.visitors}</dd>
				</dl>
			{:catch}
				<p class="error">Failed to load analytics.</p>
			{/await}
		</section>
	{/if}

	<!-- Confirmation dialog -->
	{#if showConfirmation}
		<div class="toast" role="status">
			Item created successfully!
		</div>
	{/if}
</main>

<style>
	.container {
		max-width: 48rem;
		margin: 0 auto;
		padding: 2rem 1rem;
	}
	.alert {
		padding: 1rem;
		border-radius: 0.5rem;
		margin-bottom: 1.5rem;
	}
	.alert-success {
		background: #f0fdf4;
		border: 1px solid #bbf7d0;
	}
	.alert-error {
		background: #fef2f2;
		border: 1px solid #fecaca;
	}
	.form-group {
		margin-bottom: 1rem;
	}
	.field-error {
		color: #dc2626;
		font-size: 0.875rem;
		margin-top: 0.25rem;
	}
	.empty-state {
		text-align: center;
		padding: 3rem;
		color: #6b7280;
	}
	.item-card {
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding: 1rem;
		border: 1px solid #e5e7eb;
		border-radius: 0.5rem;
		margin-bottom: 0.5rem;
	}
	.btn-danger {
		color: #dc2626;
		background: none;
		border: 1px solid #dc2626;
		cursor: pointer;
	}
	.toast {
		position: fixed;
		bottom: 1rem;
		right: 1rem;
		background: #065f46;
		color: white;
		padding: 0.75rem 1.5rem;
		border-radius: 0.5rem;
	}
</style>
