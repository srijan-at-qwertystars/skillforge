#!/usr/bin/env npx tsx
// seed-database.ts — Seed script template for Drizzle ORM with @faker-js/faker
//
// Usage:
//   npx tsx scripts/seed-database.ts
//   npx tsx scripts/seed-database.ts --reset    # Truncate tables first
//
// Prerequisites:
//   npm i -D tsx @faker-js/faker
//
// Customize the seed functions below to match your schema.

import { faker } from '@faker-js/faker';
import { sql, eq } from 'drizzle-orm';

// ─── CONFIGURE YOUR IMPORTS ─────────────────────────────────────────────
// Update these imports to match your project structure:
//
//   import { db } from '../src/db';
//   import { users, posts, comments, tags, postTags } from '../src/db/schema';
//
// For this template, we use placeholder types. Replace with your actual schema.
// ─────────────────────────────────────────────────────────────────────────

// Placeholder — replace with your actual db and schema imports
const PLACEHOLDER = true;
if (PLACEHOLDER) {
  console.error('⚠ Edit seed-database.ts to import your actual db client and schema.');
  console.error('  Replace the placeholder imports at the top of the file.');
  process.exit(1);
}

// @ts-expect-error — Replace these with your actual imports
import { db } from '../src/db';
// @ts-expect-error — Replace these with your actual imports
import { users, posts, comments, tags, postTags } from '../src/db/schema';

// ─── CONFIGURATION ──────────────────────────────────────────────────────

const SEED_CONFIG = {
  users: 50,
  postsPerUser: { min: 0, max: 10 },
  commentsPerPost: { min: 0, max: 5 },
  tags: ['typescript', 'javascript', 'react', 'nextjs', 'drizzle', 'postgres',
         'docker', 'devops', 'testing', 'performance', 'security', 'api'],
  tagsPerPost: { min: 1, max: 4 },
};

// Set a fixed seed for reproducible data
faker.seed(42);

// ─── HELPERS ────────────────────────────────────────────────────────────

function randomInt(min: number, max: number): number {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function randomSubset<T>(arr: T[], min: number, max: number): T[] {
  const count = randomInt(min, Math.min(max, arr.length));
  const shuffled = [...arr].sort(() => Math.random() - 0.5);
  return shuffled.slice(0, count);
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

// ─── SEED FUNCTIONS ─────────────────────────────────────────────────────

async function seedUsers(count: number) {
  console.log(`  Seeding ${count} users...`);

  const userData = Array.from({ length: count }, () => ({
    name: faker.person.fullName(),
    email: faker.internet.email().toLowerCase(),
    createdAt: faker.date.past({ years: 2 }),
    isActive: faker.datatype.boolean({ probability: 0.85 }),
  }));

  // Batch insert (chunks of 100 to avoid parameter limits)
  const chunkSize = 100;
  const insertedUsers = [];

  for (let i = 0; i < userData.length; i += chunkSize) {
    const chunk = userData.slice(i, i + chunkSize);
    const result = await db.insert(users).values(chunk).returning();
    insertedUsers.push(...result);
  }

  console.log(`  ✓ ${insertedUsers.length} users created`);
  return insertedUsers;
}

async function seedTags() {
  console.log(`  Seeding ${SEED_CONFIG.tags.length} tags...`);

  const tagData = SEED_CONFIG.tags.map((name) => ({ name }));

  const insertedTags = await db.insert(tags)
    .values(tagData)
    .onConflictDoNothing()
    .returning();

  console.log(`  ✓ ${insertedTags.length} tags created`);
  return insertedTags;
}

async function seedPosts(userIds: number[]) {
  console.log(`  Seeding posts...`);
  let totalPosts = 0;
  const allPosts: { id: number; authorId: number }[] = [];

  for (const userId of userIds) {
    const postCount = randomInt(
      SEED_CONFIG.postsPerUser.min,
      SEED_CONFIG.postsPerUser.max,
    );

    if (postCount === 0) continue;

    const postData = Array.from({ length: postCount }, () => ({
      title: faker.lorem.sentence({ min: 3, max: 8 }),
      content: faker.lorem.paragraphs({ min: 1, max: 5 }),
      published: faker.datatype.boolean({ probability: 0.7 }),
      authorId: userId,
      createdAt: faker.date.past({ years: 1 }),
    }));

    const inserted = await db.insert(posts).values(postData).returning({
      id: posts.id,
      authorId: posts.authorId,
    });

    allPosts.push(...inserted);
    totalPosts += inserted.length;
  }

  console.log(`  ✓ ${totalPosts} posts created`);
  return allPosts;
}

async function seedComments(
  postIds: number[],
  userIds: number[],
) {
  console.log(`  Seeding comments...`);
  let totalComments = 0;

  for (const postId of postIds) {
    const commentCount = randomInt(
      SEED_CONFIG.commentsPerPost.min,
      SEED_CONFIG.commentsPerPost.max,
    );

    if (commentCount === 0) continue;

    const commentData = Array.from({ length: commentCount }, () => ({
      text: faker.lorem.sentence({ min: 5, max: 20 }),
      postId,
      authorId: userIds[randomInt(0, userIds.length - 1)],
    }));

    await db.insert(comments).values(commentData);
    totalComments += commentCount;
  }

  console.log(`  ✓ ${totalComments} comments created`);
}

async function seedPostTags(
  postIds: number[],
  tagIds: number[],
) {
  console.log(`  Seeding post-tag relationships...`);
  let totalRelations = 0;

  const allPostTags: { postId: number; tagId: number }[] = [];

  for (const postId of postIds) {
    const selectedTags = randomSubset(
      tagIds,
      SEED_CONFIG.tagsPerPost.min,
      SEED_CONFIG.tagsPerPost.max,
    );

    for (const tagId of selectedTags) {
      allPostTags.push({ postId, tagId });
    }
  }

  // Batch insert
  const chunkSize = 500;
  for (let i = 0; i < allPostTags.length; i += chunkSize) {
    const chunk = allPostTags.slice(i, i + chunkSize);
    await db.insert(postTags).values(chunk).onConflictDoNothing();
    totalRelations += chunk.length;
  }

  console.log(`  ✓ ${totalRelations} post-tag relations created`);
}

// ─── RESET FUNCTION ─────────────────────────────────────────────────────

async function resetDatabase() {
  console.log('  Resetting database...');

  // Delete in reverse dependency order
  await db.delete(postTags);
  await db.delete(comments);
  await db.delete(posts);
  await db.delete(tags);
  await db.delete(users);

  console.log('  ✓ All tables truncated');
}

// ─── MAIN ───────────────────────────────────────────────────────────────

async function main() {
  const startTime = Date.now();
  const shouldReset = process.argv.includes('--reset');

  console.log('');
  console.log('🌱 Drizzle Database Seeder');
  console.log('═══════════════════════════');
  console.log('');

  if (shouldReset) {
    await resetDatabase();
    console.log('');
  }

  // Seed in dependency order
  const insertedUsers = await seedUsers(SEED_CONFIG.users);
  const userIds = insertedUsers.map((u) => u.id);

  const insertedTags = await seedTags();
  const tagIds = insertedTags.map((t) => t.id);

  const insertedPosts = await seedPosts(userIds);
  const postIds = insertedPosts.map((p) => p.id);

  await seedComments(postIds, userIds);
  await seedPostTags(postIds, tagIds);

  const duration = Date.now() - startTime;

  console.log('');
  console.log(`✅ Seeding complete in ${formatDuration(duration)}`);
  console.log('');

  process.exit(0);
}

main().catch((err) => {
  console.error('');
  console.error('❌ Seeding failed:', err);
  process.exit(1);
});
