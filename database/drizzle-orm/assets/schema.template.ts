// schema.template.ts — Example Drizzle schema with users, posts, tags and relations
//
// Copy to src/db/schema.ts and adjust to your needs.
// This template uses PostgreSQL. See comments for MySQL/SQLite alternatives.

import {
  pgTable,
  pgEnum,
  serial,
  integer,
  text,
  varchar,
  boolean,
  timestamp,
  jsonb,
  uuid,
  index,
  uniqueIndex,
  primaryKey,
} from 'drizzle-orm/pg-core';
import { relations, sql } from 'drizzle-orm';

// ─── Enums ──────────────────────────────────────────────────────────────────────

export const roleEnum = pgEnum('role', ['admin', 'user', 'guest']);
export const postStatusEnum = pgEnum('post_status', ['draft', 'published', 'archived']);

// ─── Shared column mixins ───────────────────────────────────────────────────────

const timestamps = {
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull().$onUpdate(() => new Date()),
};

const softDelete = {
  deletedAt: timestamp('deleted_at'),
};

// ─── Users ──────────────────────────────────────────────────────────────────────

export const users = pgTable('users', {
  id: serial('id').primaryKey(),
  name: text('name').notNull(),
  email: varchar('email', { length: 320 }).notNull().unique(),
  role: roleEnum('role').default('user').notNull(),
  isActive: boolean('is_active').default(true).notNull(),
  metadata: jsonb('metadata').$type<{
    avatarUrl?: string;
    bio?: string;
    preferences?: Record<string, unknown>;
  }>(),
  ...timestamps,
  ...softDelete,
}, (t) => [
  index('users_email_idx').on(t.email),
  index('users_role_idx').on(t.role),
  index('users_active_idx').on(t.isActive).where(sql`${t.deletedAt} IS NULL`),
]);

// ─── Posts ───────────────────────────────────────────────────────────────────────

export const posts = pgTable('posts', {
  id: serial('id').primaryKey(),
  title: text('title').notNull(),
  slug: varchar('slug', { length: 255 }).notNull().unique(),
  content: text('content'),
  excerpt: varchar('excerpt', { length: 500 }),
  status: postStatusEnum('status').default('draft').notNull(),
  authorId: integer('author_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  publishedAt: timestamp('published_at'),
  ...timestamps,
  ...softDelete,
}, (t) => [
  index('posts_author_idx').on(t.authorId),
  index('posts_status_idx').on(t.status),
  index('posts_slug_idx').on(t.slug),
  index('posts_published_idx').on(t.publishedAt).where(sql`${t.status} = 'published'`),
]);

// ─── Tags ───────────────────────────────────────────────────────────────────────

export const tags = pgTable('tags', {
  id: serial('id').primaryKey(),
  name: varchar('name', { length: 100 }).notNull().unique(),
  slug: varchar('slug', { length: 100 }).notNull().unique(),
  ...timestamps,
});

// ─── Posts ↔ Tags (many-to-many junction) ───────────────────────────────────────

export const postsToTags = pgTable('posts_to_tags', {
  postId: integer('post_id').notNull().references(() => posts.id, { onDelete: 'cascade' }),
  tagId: integer('tag_id').notNull().references(() => tags.id, { onDelete: 'cascade' }),
}, (t) => [
  primaryKey({ columns: [t.postId, t.tagId] }),
  index('posts_to_tags_post_idx').on(t.postId),
  index('posts_to_tags_tag_idx').on(t.tagId),
]);

// ─── Comments ───────────────────────────────────────────────────────────────────

export const comments = pgTable('comments', {
  id: serial('id').primaryKey(),
  content: text('content').notNull(),
  postId: integer('post_id').notNull().references(() => posts.id, { onDelete: 'cascade' }),
  authorId: integer('author_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  parentId: integer('parent_id'), // Self-referencing for nested comments
  ...timestamps,
}, (t) => [
  index('comments_post_idx').on(t.postId),
  index('comments_author_idx').on(t.authorId),
  index('comments_parent_idx').on(t.parentId),
]);

// ═══════════════════════════════════════════════════════════════════════════════
// Relations — required for db.query relational API
// ═══════════════════════════════════════════════════════════════════════════════

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
  postsToTags: many(postsToTags),
}));

export const tagsRelations = relations(tags, ({ many }) => ({
  postsToTags: many(postsToTags),
}));

export const postsToTagsRelations = relations(postsToTags, ({ one }) => ({
  post: one(posts, {
    fields: [postsToTags.postId],
    references: [posts.id],
  }),
  tag: one(tags, {
    fields: [postsToTags.tagId],
    references: [tags.id],
  }),
}));

export const commentsRelations = relations(comments, ({ one }) => ({
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
    relationName: 'commentReplies',
  }),
}));

// ─── Type exports ───────────────────────────────────────────────────────────────

export type User = typeof users.$inferSelect;
export type NewUser = typeof users.$inferInsert;
export type Post = typeof posts.$inferSelect;
export type NewPost = typeof posts.$inferInsert;
export type Tag = typeof tags.$inferSelect;
export type NewTag = typeof tags.$inferInsert;
export type Comment = typeof comments.$inferSelect;
export type NewComment = typeof comments.$inferInsert;
