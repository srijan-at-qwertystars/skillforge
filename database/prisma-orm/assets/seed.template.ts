// ==============================================================================
// Prisma Seed Script Template
//
// Populates the database with realistic sample data using @faker-js/faker.
//
// Setup:
//   1. npm install -D @faker-js/faker tsx
//   2. Add to package.json: "prisma": { "seed": "tsx prisma/seed.ts" }
//   3. Run: npx prisma db seed
//
// Notes:
//   - Uses upsert to be idempotent (safe to run multiple times)
//   - Adjust counts via SEED_USERS / SEED_POSTS_PER_USER / SEED_TAGS constants
//   - For production seeds (admin user, config), keep at top in upserts
//   - For dev-only fake data, wrap in NODE_ENV check
// ==============================================================================

import { PrismaClient, Role, PostStatus } from '@prisma/client'
import { faker } from '@faker-js/faker'

const prisma = new PrismaClient()

// =============================================================================
// Configuration
// =============================================================================

const SEED_USERS = 20
const SEED_POSTS_PER_USER = 5
const SEED_TAGS = 15
const SEED_COMMENTS_PER_POST = 3

// Deterministic seed for reproducible data
faker.seed(42)

// =============================================================================
// Helpers
// =============================================================================

function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
}

function randomEnum<T>(enumObj: Record<string, T>): T {
  const values = Object.values(enumObj)
  return values[Math.floor(Math.random() * values.length)]
}

function randomSubset<T>(arr: T[], min = 1, max = 3): T[] {
  const count = faker.number.int({ min, max: Math.min(max, arr.length) })
  return faker.helpers.arrayElements(arr, count)
}

// =============================================================================
// Seed: Production essentials (always run)
// =============================================================================

async function seedProduction() {
  console.log('🔧 Seeding production essentials...')

  // Admin user — always present
  const admin = await prisma.user.upsert({
    where: { email: 'admin@example.com' },
    update: {},
    create: {
      email: 'admin@example.com',
      name: 'Admin User',
      password: '$2b$10$placeholder_hash_replace_me', // hash in real app
      role: 'ADMIN',
      active: true,
      profile: {
        create: {
          website: 'https://example.com',
          company: 'Example Inc.',
        },
      },
    },
  })

  console.log(`  ✅ Admin user: ${admin.email} (id: ${admin.id})`)

  // Default categories
  const categories = ['Technology', 'Science', 'Design', 'Business', 'Lifestyle']
  for (const name of categories) {
    await prisma.category.upsert({
      where: { slug: slugify(name) },
      update: {},
      create: { name, slug: slugify(name), description: `Posts about ${name.toLowerCase()}` },
    })
  }

  console.log(`  ✅ ${categories.length} categories created`)
}

// =============================================================================
// Seed: Development fake data
// =============================================================================

async function seedDevelopment() {
  console.log('🌱 Seeding development data...')

  // --- Tags ---
  const tagNames = Array.from({ length: SEED_TAGS }, () => faker.word.noun())
  const uniqueTags = [...new Set(tagNames)]
  const tags = await Promise.all(
    uniqueTags.map((name) =>
      prisma.tag.upsert({
        where: { slug: slugify(name) },
        update: {},
        create: { name, slug: slugify(name) },
      }),
    ),
  )
  console.log(`  ✅ ${tags.length} tags created`)

  // --- Users with posts, comments ---
  const allCategories = await prisma.category.findMany()
  const users = []

  for (let i = 0; i < SEED_USERS; i++) {
    const firstName = faker.person.firstName()
    const lastName = faker.person.lastName()
    const email = faker.internet.email({ firstName, lastName }).toLowerCase()

    const user = await prisma.user.upsert({
      where: { email },
      update: {},
      create: {
        email,
        name: `${firstName} ${lastName}`,
        password: '$2b$10$placeholder_hash',
        role: randomEnum(Role),
        active: faker.datatype.boolean(0.9),
        bio: faker.person.bio(),
        metadata: {
          theme: faker.helpers.arrayElement(['light', 'dark', 'system']),
          language: faker.helpers.arrayElement(['en', 'es', 'fr', 'de']),
          notifications: {
            email: faker.datatype.boolean(),
            push: faker.datatype.boolean(),
          },
        },
        profile: {
          create: {
            website: faker.datatype.boolean(0.5) ? faker.internet.url() : null,
            location: faker.location.city(),
            company: faker.datatype.boolean(0.6) ? faker.company.name() : null,
            socials: {
              twitter: faker.datatype.boolean(0.4) ? `@${faker.internet.username()}` : null,
              github: faker.datatype.boolean(0.5) ? faker.internet.username() : null,
            },
          },
        },
      },
    })
    users.push(user)
  }
  console.log(`  ✅ ${users.length} users created`)

  // --- Posts ---
  let postCount = 0
  for (const user of users) {
    const numPosts = faker.number.int({ min: 0, max: SEED_POSTS_PER_USER })
    for (let j = 0; j < numPosts; j++) {
      const title = faker.lorem.sentence({ min: 3, max: 8 })
      const status = randomEnum(PostStatus)
      const selectedTags = randomSubset(tags, 1, 4)
      const selectedCategories = randomSubset(allCategories, 1, 2)

      await prisma.post.create({
        data: {
          title,
          slug: `${slugify(title)}-${faker.string.alphanumeric(6)}`,
          content: faker.lorem.paragraphs({ min: 2, max: 6 }),
          excerpt: faker.lorem.sentence(),
          status,
          featured: faker.datatype.boolean(0.1),
          viewCount: faker.number.int({ min: 0, max: 10000 }),
          publishedAt: status === 'PUBLISHED' ? faker.date.past({ years: 1 }) : null,
          authorId: user.id,
          tags: {
            create: selectedTags.map((tag) => ({
              tagId: tag.id,
              assignedBy: user.id,
            })),
          },
          categories: {
            connect: selectedCategories.map((cat) => ({ id: cat.id })),
          },
        },
      })
      postCount++
    }
  }
  console.log(`  ✅ ${postCount} posts created`)

  // --- Comments ---
  const allPosts = await prisma.post.findMany({ select: { id: true } })
  let commentCount = 0
  for (const post of allPosts) {
    const numComments = faker.number.int({ min: 0, max: SEED_COMMENTS_PER_POST })
    for (let k = 0; k < numComments; k++) {
      const randomUser = faker.helpers.arrayElement(users)
      await prisma.comment.create({
        data: {
          body: faker.lorem.paragraph(),
          authorId: randomUser.id,
          postId: post.id,
        },
      })
      commentCount++
    }
  }
  console.log(`  ✅ ${commentCount} comments created`)
}

// =============================================================================
// Main
// =============================================================================

async function main() {
  console.log('🚀 Starting seed...\n')

  await seedProduction()

  if (process.env.NODE_ENV !== 'production') {
    await seedDevelopment()
  }

  console.log('\n✅ Seed complete!')
}

main()
  .catch((e) => {
    console.error('❌ Seed failed:', e)
    process.exit(1)
  })
  .finally(async () => {
    await prisma.$disconnect()
  })
