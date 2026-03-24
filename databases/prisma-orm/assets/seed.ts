// =============================================================================
// Database Seeding Script — Prisma
//
// Features:
//   - Idempotent upserts (safe to run multiple times)
//   - Faker.js integration for realistic data
//   - Relation seeding (users → posts, tags)
//   - Configurable seed counts via environment variables
//   - Progress logging
//
// Setup:
//   npm install --save-dev @faker-js/faker
//
// In package.json:
//   { "prisma": { "seed": "ts-node prisma/seed.ts" } }
//
// Run:
//   npx prisma db seed
//   # or automatically via: npx prisma migrate reset
//
// Environment:
//   SEED_USER_COUNT=20     Number of users to create (default: 20)
//   SEED_POST_COUNT=50     Number of posts to create (default: 50)
// =============================================================================

import { PrismaClient, Prisma } from '@prisma/client';
import { faker } from '@faker-js/faker';

const prisma = new PrismaClient();

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const SEED_USER_COUNT = parseInt(process.env.SEED_USER_COUNT ?? '20', 10);
const SEED_POST_COUNT = parseInt(process.env.SEED_POST_COUNT ?? '50', 10);

// Set faker seed for reproducible data
faker.seed(42);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function log(message: string): void {
  console.log(`🌱 ${message}`);
}

function uniqueSlug(title: string, index: number): string {
  return `${title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')}-${index}`;
}

// ---------------------------------------------------------------------------
// Seed: Admin User (always created)
// ---------------------------------------------------------------------------

async function seedAdmin() {
  log('Creating admin user...');

  const admin = await prisma.user.upsert({
    where: { email: 'admin@example.com' },
    update: {},
    create: {
      email: 'admin@example.com',
      name: 'Admin User',
      role: 'ADMIN',
      // Add password hash if your schema has it:
      // passwordHash: await hash('admin-password', 10),
    },
  });

  log(`  Admin: ${admin.email} (id: ${admin.id})`);
  return admin;
}

// ---------------------------------------------------------------------------
// Seed: Tags
// ---------------------------------------------------------------------------

async function seedTags() {
  log('Creating tags...');

  const tagNames = [
    'TypeScript',
    'JavaScript',
    'Prisma',
    'PostgreSQL',
    'React',
    'Next.js',
    'Node.js',
    'GraphQL',
    'REST API',
    'DevOps',
    'Testing',
    'Performance',
  ];

  const tags = await Promise.all(
    tagNames.map((name) =>
      prisma.tag.upsert({
        where: { name },
        update: {},
        create: {
          name,
          slug: name.toLowerCase().replace(/[^a-z0-9]+/g, '-'),
        },
      })
    )
  );

  log(`  Created ${tags.length} tags`);
  return tags;
}

// ---------------------------------------------------------------------------
// Seed: Users
// ---------------------------------------------------------------------------

async function seedUsers() {
  log(`Creating ${SEED_USER_COUNT} users...`);

  const users = [];

  for (let i = 0; i < SEED_USER_COUNT; i++) {
    const firstName = faker.person.firstName();
    const lastName = faker.person.lastName();
    const email = faker.internet
      .email({ firstName, lastName, provider: 'example.com' })
      .toLowerCase();

    const user = await prisma.user.upsert({
      where: { email },
      update: {},
      create: {
        email,
        name: `${firstName} ${lastName}`,
        role: faker.helpers.weightedArrayElement([
          { value: 'USER' as const, weight: 8 },
          { value: 'MODERATOR' as const, weight: 1.5 },
          { value: 'ADMIN' as const, weight: 0.5 },
        ]),
      },
    });

    users.push(user);
  }

  log(`  Created ${users.length} users`);
  return users;
}

// ---------------------------------------------------------------------------
// Seed: Posts
// ---------------------------------------------------------------------------

async function seedPosts(
  users: { id: string | number }[],
  tags: { id: string | number }[]
) {
  log(`Creating ${SEED_POST_COUNT} posts...`);

  const posts = [];

  for (let i = 0; i < SEED_POST_COUNT; i++) {
    const title = faker.lorem.sentence({ min: 3, max: 8 });
    const slug = uniqueSlug(title, i);
    const author = faker.helpers.arrayElement(users);
    const isPublished = faker.datatype.boolean({ probability: 0.7 });

    // Assign 1-3 random tags
    const postTags = faker.helpers
      .arrayElements(tags, { min: 1, max: 3 })
      .map((tag) => ({
        tag: { connect: { id: tag.id } },
      }));

    try {
      const post = await prisma.post.upsert({
        where: { slug },
        update: {},
        create: {
          title,
          slug,
          content: faker.lorem.paragraphs({ min: 2, max: 6 }, '\n\n'),
          excerpt: faker.lorem.sentence(),
          status: isPublished ? 'PUBLISHED' : 'DRAFT',
          publishedAt: isPublished
            ? faker.date.past({ years: 1 })
            : null,
          author: { connect: { id: author.id } },
          tags: { create: postTags },
        },
      });
      posts.push(post);
    } catch (e) {
      // Skip duplicates silently
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
        continue;
      }
      throw e;
    }
  }

  log(`  Created ${posts.length} posts`);
  return posts;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  log('Starting database seed...');
  console.log('');

  const admin = await seedAdmin();
  const tags = await seedTags();
  const users = await seedUsers();
  const allUsers = [admin, ...users];
  const posts = await seedPosts(allUsers, tags);

  console.log('');
  log('Seed complete!');
  log(`  Users: ${allUsers.length}`);
  log(`  Tags:  ${tags.length}`);
  log(`  Posts: ${posts.length}`);
}

main()
  .catch((e) => {
    console.error('❌ Seed failed:', e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
