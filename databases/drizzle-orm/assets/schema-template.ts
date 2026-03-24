// schema-template.ts — Common schema patterns: users, posts, tags, many-to-many
//
// Copy this file to your project and customize. Includes:
// - Users with roles (enum)
// - Posts with full-text search
// - Tags with many-to-many junction table
// - Comments with nested relations
// - Timestamps and soft-delete pattern
// - Indexes and constraints

import {
  pgTable,
  pgEnum,
  serial,
  text,
  varchar,
  integer,
  boolean,
  timestamp,
  jsonb,
  index,
  uniqueIndex,
  primaryKey,
} from 'drizzle-orm/pg-core';
import { relations, sql } from 'drizzle-orm';

// ─── Enums ──────────────────────────────────────────────────────────────

export const roleEnum = pgEnum('role', ['user', 'admin', 'moderator']);
export const postStatusEnum = pgEnum('post_status', ['draft', 'published', 'archived']);

// ─── Users ──────────────────────────────────────────────────────────────

export const users = pgTable('users', {
  id: serial('id').primaryKey(),
  name: text('name').notNull(),
  email: varchar('email', { length: 255 }).notNull().unique(),
  role: roleEnum('role').default('user').notNull(),
  avatarUrl: text('avatar_url'),
  bio: text('bio'),
  metadata: jsonb('metadata').$type<{
    theme?: 'light' | 'dark';
    notifications?: boolean;
    [key: string]: unknown;
  }>().default({}),
  isActive: boolean('is_active').default(true).notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
  deletedAt: timestamp('deleted_at'),  // soft delete
}, (table) => [
  uniqueIndex('users_email_idx').on(table.email),
  index('users_role_idx').on(table.role),
  index('users_active_idx').on(table.isActive).where(sql`is_active = true`),
]);

// ─── Posts ───────────────────────────────────────────────────────────────

export const posts = pgTable('posts', {
  id: serial('id').primaryKey(),
  title: varchar('title', { length: 500 }).notNull(),
  slug: varchar('slug', { length: 500 }).notNull().unique(),
  content: text('content'),
  excerpt: varchar('excerpt', { length: 1000 }),
  status: postStatusEnum('status').default('draft').notNull(),
  authorId: integer('author_id')
    .references(() => users.id, { onDelete: 'cascade' })
    .notNull(),
  publishedAt: timestamp('published_at'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
}, (table) => [
  uniqueIndex('posts_slug_idx').on(table.slug),
  index('posts_author_idx').on(table.authorId),
  index('posts_status_idx').on(table.status),
  index('posts_published_idx').on(table.publishedAt)
    .where(sql`status = 'published'`),
]);

// ─── Tags ───────────────────────────────────────────────────────────────

export const tags = pgTable('tags', {
  id: serial('id').primaryKey(),
  name: varchar('name', { length: 100 }).notNull().unique(),
  slug: varchar('slug', { length: 100 }).notNull().unique(),
  description: text('description'),
  color: varchar('color', { length: 7 }),  // hex color
  createdAt: timestamp('created_at').defaultNow().notNull(),
});

// ─── Post-Tags Junction (Many-to-Many) ─────────────────────────────────

export const postTags = pgTable('post_tags', {
  postId: integer('post_id')
    .references(() => posts.id, { onDelete: 'cascade' })
    .notNull(),
  tagId: integer('tag_id')
    .references(() => tags.id, { onDelete: 'cascade' })
    .notNull(),
  assignedAt: timestamp('assigned_at').defaultNow().notNull(),
}, (table) => [
  primaryKey({ columns: [table.postId, table.tagId] }),
]);

// ─── Comments ───────────────────────────────────────────────────────────

export const comments = pgTable('comments', {
  id: serial('id').primaryKey(),
  body: text('body').notNull(),
  postId: integer('post_id')
    .references(() => posts.id, { onDelete: 'cascade' })
    .notNull(),
  authorId: integer('author_id')
    .references(() => users.id, { onDelete: 'set null' }),
  parentId: integer('parent_id'),  // self-referencing for threads
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
}, (table) => [
  index('comments_post_idx').on(table.postId),
  index('comments_author_idx').on(table.authorId),
  index('comments_parent_idx').on(table.parentId),
]);

// ─── Relations ──────────────────────────────────────────────────────────

export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
  comments: many(comments),
}));

export const postsRelations = relations(posts, ({ one, many }) => ({
  author: one(users, {
    fields: [posts.authorId],
    references: [users.id],
  }),
  comments: many(comments),
  postTags: many(postTags),
}));

export const tagsRelations = relations(tags, ({ many }) => ({
  postTags: many(postTags),
}));

export const postTagsRelations = relations(postTags, ({ one }) => ({
  post: one(posts, {
    fields: [postTags.postId],
    references: [posts.id],
  }),
  tag: one(tags, {
    fields: [postTags.tagId],
    references: [tags.id],
  }),
}));

export const commentsRelations = relations(comments, ({ one, many }) => ({
  post: one(posts, {
    fields: [comments.postId],
    references: [posts.id],
  }),
  author: one(users, {
    fields: [comments.authorId],
    references: [users.id],
  }),
  parent: one(comments, {
    fields: [comments.parentId],
    references: [comments.id],
    relationName: 'commentThread',
  }),
  replies: many(comments, { relationName: 'commentThread' }),
}));

// ─── Type Inference ─────────────────────────────────────────────────────

export type User = typeof users.$inferSelect;
export type NewUser = typeof users.$inferInsert;
export type Post = typeof posts.$inferSelect;
export type NewPost = typeof posts.$inferInsert;
export type Tag = typeof tags.$inferSelect;
export type Comment = typeof comments.$inferSelect;
