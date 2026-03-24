// Content Collection configuration template for Astro 5+
// Copy this file to your project root as content.config.ts
//
// This template includes schemas for common collection types:
// - Blog posts with full metadata
// - Documentation pages with sidebar ordering
// - Author profiles
//
// Customize the schemas to match your content's frontmatter fields.
// Run `npx astro sync` after modifying to regenerate types.

import { defineCollection, z, reference } from 'astro:content';
import { glob, file } from 'astro/loaders';

// ─── Blog Collection ───
// Source: src/content/blog/*.{md,mdx}
// Frontmatter example:
//   ---
//   title: "My Post Title"
//   description: "A brief description"
//   date: 2024-01-15
//   updatedDate: 2024-02-01  # optional
//   author: "jane-doe"       # references authors collection
//   draft: false
//   tags: ["astro", "web"]
//   image: "./hero.jpg"      # relative image for optimization
//   category: "tutorial"
//   ---
const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: ({ image }) =>
    z.object({
      title: z.string().max(100),
      description: z.string().max(300),
      date: z.coerce.date(),
      updatedDate: z.coerce.date().optional(),
      author: reference('authors').optional(),
      draft: z.boolean().default(false),
      tags: z.array(z.string()).default([]),
      image: image().optional(),
      imageAlt: z.string().optional(),
      category: z
        .enum(['tutorial', 'guide', 'opinion', 'news', 'release'])
        .default('tutorial'),
      canonicalUrl: z.string().url().optional(),
      // SEO overrides
      metaTitle: z.string().max(60).optional(),
      metaDescription: z.string().max(160).optional(),
    }),
});

// ─── Documentation Collection ───
// Source: src/content/docs/**/*.{md,mdx}
// Supports nested directories for sections (e.g., docs/getting-started/install.md)
// Frontmatter example:
//   ---
//   title: "Installation"
//   description: "How to install the project"
//   section: "Getting Started"
//   order: 1
//   ---
const docs = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/docs' }),
  schema: z.object({
    title: z.string(),
    description: z.string().optional(),
    // Sidebar organization
    section: z.string().optional(),
    order: z.number().default(999),
    // Navigation
    prev: z.string().optional(),
    next: z.string().optional(),
    // Display options
    tableOfContents: z.boolean().default(true),
    editUrl: z.boolean().default(true),
    // Access control
    draft: z.boolean().default(false),
    badge: z
      .object({
        text: z.string(),
        variant: z.enum(['note', 'tip', 'caution', 'danger']).default('note'),
      })
      .optional(),
  }),
});

// ─── Authors Collection ───
// Source: src/data/authors.json (or .yaml)
// JSON example:
//   [
//     {
//       "id": "jane-doe",
//       "name": "Jane Doe",
//       "email": "jane@example.com",
//       "avatar": "./avatars/jane.jpg",
//       "bio": "Full-stack developer and writer.",
//       "social": { "twitter": "@janedoe", "github": "janedoe" }
//     }
//   ]
const authors = defineCollection({
  loader: file('src/data/authors.json'),
  schema: ({ image }) =>
    z.object({
      name: z.string(),
      email: z.string().email().optional(),
      avatar: image().optional(),
      bio: z.string().optional(),
      role: z.string().optional(),
      social: z
        .object({
          twitter: z.string().optional(),
          github: z.string().optional(),
          linkedin: z.string().optional(),
          website: z.string().url().optional(),
          mastodon: z.string().url().optional(),
        })
        .optional(),
    }),
});

// ─── Projects / Portfolio Collection ───
// Source: src/content/projects/*.{md,mdx}
// Uncomment and customize for portfolio sites:
//
// const projects = defineCollection({
//   loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/projects' }),
//   schema: ({ image }) =>
//     z.object({
//       title: z.string(),
//       description: z.string(),
//       date: z.coerce.date(),
//       image: image().optional(),
//       technologies: z.array(z.string()).default([]),
//       liveUrl: z.string().url().optional(),
//       repoUrl: z.string().url().optional(),
//       featured: z.boolean().default(false),
//       status: z.enum(['completed', 'in-progress', 'archived']).default('completed'),
//     }),
// });

// ─── Changelog / Releases Collection ───
// Uncomment for product/library changelogs:
//
// const changelog = defineCollection({
//   loader: glob({ pattern: '**/*.md', base: './src/content/changelog' }),
//   schema: z.object({
//     version: z.string(),
//     date: z.coerce.date(),
//     title: z.string().optional(),
//     breaking: z.boolean().default(false),
//   }),
// });

// ─── Export all collections ───
export const collections = {
  blog,
  docs,
  authors,
  // projects,
  // changelog,
};
