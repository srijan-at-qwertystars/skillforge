// src/content.config.ts — Content Collection Configuration Template
//
// Place this file at src/content.config.ts in your Astro 5 project.
// Docs: https://docs.astro.build/en/guides/content-collections/

import { defineCollection, reference } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

// --- Blog Collection ---
const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: ({ image }) =>
    z.object({
      title: z.string().max(100),
      description: z.string().max(300),
      pubDate: z.coerce.date(),
      updatedDate: z.coerce.date().optional(),
      // Use image() helper for build-time image optimization
      heroImage: image().optional(),
      author: reference('authors'),
      tags: z.array(z.string()).default([]),
      draft: z.boolean().default(false),
      // SEO overrides
      metaTitle: z.string().optional(),
      metaDescription: z.string().optional(),
      canonicalUrl: z.string().url().optional(),
    }),
});

// --- Authors Collection ---
const authors = defineCollection({
  loader: glob({ pattern: '**/*.json', base: './src/content/authors' }),
  schema: ({ image }) =>
    z.object({
      name: z.string(),
      bio: z.string(),
      avatar: image().optional(),
      email: z.string().email().optional(),
      social: z
        .object({
          twitter: z.string().optional(),
          github: z.string().optional(),
          website: z.string().url().optional(),
        })
        .optional(),
    }),
});

// --- Documentation Collection ---
const docs = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/docs' }),
  schema: z.object({
    title: z.string(),
    description: z.string().optional(),
    // Sidebar ordering
    order: z.number().default(999),
    // Organize into sections
    section: z.string().default('General'),
    // Show/hide in sidebar
    sidebar: z.boolean().default(true),
    // Related docs
    relatedDocs: z.array(reference('docs')).default([]),
  }),
});

// --- Changelog Collection ---
const changelog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/changelog' }),
  schema: z.object({
    version: z.string(),
    date: z.coerce.date(),
    breaking: z.boolean().default(false),
    features: z.array(z.string()).default([]),
    fixes: z.array(z.string()).default([]),
    deprecated: z.array(z.string()).default([]),
  }),
});

// --- Projects / Portfolio Collection ---
// Uncomment to use:
// const projects = defineCollection({
//   loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/projects' }),
//   schema: ({ image }) =>
//     z.object({
//       title: z.string(),
//       description: z.string(),
//       thumbnail: image(),
//       tags: z.array(z.string()).default([]),
//       liveUrl: z.string().url().optional(),
//       repoUrl: z.string().url().optional(),
//       featured: z.boolean().default(false),
//       order: z.number().default(0),
//     }),
// });

// --- Export all collections ---
export const collections = {
  blog,
  authors,
  docs,
  changelog,
  // projects,
};
