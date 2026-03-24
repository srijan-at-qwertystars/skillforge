/**
 * Reviews Subgraph — Apollo Federation v2
 *
 * Owns: Review entity
 * Contributes: Product.reviews, Product.averageRating, User.reviews
 * Demonstrates: @key, @external, @requires, entity resolution, contributing fields
 */

import { ApolloServer } from '@apollo/server';
import { startStandaloneServer } from '@apollo/server/standalone';
import { buildSubgraphSchema } from '@apollo/subgraph';
import { parse } from 'graphql';
import DataLoader from 'dataloader';

// ── Schema ──────────────────────────────────────────────────────────────────

const typeDefs = parse(/* GraphQL */ `
  extend schema
    @link(url: "https://specs.apollo.dev/federation/v2.7",
      import: ["@key", "@external", "@requires", "@provides"])

  type Query {
    review(id: ID!): Review
    recentReviews(limit: Int = 10): [Review!]!
  }

  type Mutation {
    createReview(input: CreateReviewInput!): Review!
    deleteReview(id: ID!): Boolean!
  }

  input CreateReviewInput {
    productUpc: String!
    authorId: String!
    body: String!
    rating: Int!
  }

  type Review @key(fields: "id") {
    id: ID!
    body: String!
    rating: Int!
    createdAt: String!
    product: Product! @provides(fields: "name")
    author: User!
  }

  "Extends Product from the products subgraph with review data"
  type Product @key(fields: "upc") {
    upc: String!
    name: String @external
    reviews: [Review!]!
    averageRating: Float
    reviewCount: Int!
    reviewSummary: String @requires(fields: "name")
  }

  "Extends User — references the users subgraph entity"
  type User @key(fields: "id") {
    id: ID!
    reviews: [Review!]!
    reviewCount: Int!
  }
`);

// ── Data ────────────────────────────────────────────────────────────────────

interface ReviewRecord {
  id: string;
  body: string;
  rating: number;
  productUpc: string;
  authorId: string;
  createdAt: string;
}

const reviews: ReviewRecord[] = [
  { id: 'r1', body: 'Absolutely love this table! Solid build quality.',       rating: 5, productUpc: '1', authorId: 'u1', createdAt: '2024-06-01T10:00:00Z' },
  { id: 'r2', body: 'Good table but a bit pricey for what you get.',          rating: 3, productUpc: '1', authorId: 'u2', createdAt: '2024-06-15T14:30:00Z' },
  { id: 'r3', body: 'The couch is incredibly comfortable. Worth every penny.', rating: 5, productUpc: '2', authorId: 'u1', createdAt: '2024-07-01T09:00:00Z' },
  { id: 'r4', body: 'Chair is okay for the price. Nothing special.',          rating: 3, productUpc: '3', authorId: 'u3', createdAt: '2024-07-20T16:45:00Z' },
  { id: 'r5', body: 'Best laptop I have ever owned. Fast and lightweight.',    rating: 5, productUpc: '4', authorId: 'u2', createdAt: '2024-08-10T11:20:00Z' },
  { id: 'r6', body: 'Toaster works great. Simple and effective.',             rating: 4, productUpc: '5', authorId: 'u3', createdAt: '2024-08-25T07:30:00Z' },
];

let nextId = reviews.length + 1;

// ── DataLoaders ─────────────────────────────────────────────────────────────

function createLoaders() {
  return {
    reviewById: new DataLoader<string, ReviewRecord | undefined>(async (ids) => {
      console.log(`[DataLoader] Batch loading reviews: ${ids.join(', ')}`);
      return ids.map((id) => reviews.find((r) => r.id === id));
    }),

    reviewsByProductUpc: new DataLoader<string, ReviewRecord[]>(async (upcs) => {
      console.log(`[DataLoader] Batch loading reviews for products: ${upcs.join(', ')}`);
      return upcs.map((upc) => reviews.filter((r) => r.productUpc === upc));
    }),

    reviewsByAuthorId: new DataLoader<string, ReviewRecord[]>(async (authorIds) => {
      console.log(`[DataLoader] Batch loading reviews for authors: ${authorIds.join(', ')}`);
      return authorIds.map((aid) => reviews.filter((r) => r.authorId === aid));
    }),
  };
}

type Loaders = ReturnType<typeof createLoaders>;

interface Context {
  loaders: Loaders;
  userId?: string;
}

// ── Resolvers ───────────────────────────────────────────────────────────────

const resolvers = {
  Query: {
    review: (_: unknown, { id }: { id: string }, ctx: Context) =>
      ctx.loaders.reviewById.load(id),

    recentReviews: (_: unknown, { limit }: { limit: number }) =>
      [...reviews].sort((a, b) => b.createdAt.localeCompare(a.createdAt)).slice(0, limit),
  },

  Mutation: {
    createReview: (_: unknown, { input }: { input: { productUpc: string; authorId: string; body: string; rating: number } }) => {
      if (input.rating < 1 || input.rating > 5) {
        throw new Error('Rating must be between 1 and 5');
      }
      const review: ReviewRecord = {
        id: `r${nextId++}`,
        body: input.body,
        rating: input.rating,
        productUpc: input.productUpc,
        authorId: input.authorId,
        createdAt: new Date().toISOString(),
      };
      reviews.push(review);
      return review;
    },

    deleteReview: (_: unknown, { id }: { id: string }) => {
      const index = reviews.findIndex((r) => r.id === id);
      if (index === -1) return false;
      reviews.splice(index, 1);
      return true;
    },
  },

  Review: {
    __resolveReference(ref: { id: string }, ctx: Context) {
      return ctx.loaders.reviewById.load(ref.id);
    },

    product(review: ReviewRecord) {
      // Return entity reference with @provides fields
      // The router can use the provided "name" without fetching from Products subgraph
      return { __typename: 'Product' as const, upc: review.productUpc };
    },

    author(review: ReviewRecord) {
      return { __typename: 'User' as const, id: review.authorId };
    },
  },

  Product: {
    // Entity resolution — router calls this when a Product needs review fields
    async reviews(product: { upc: string }, _: unknown, ctx: Context) {
      return ctx.loaders.reviewsByProductUpc.load(product.upc);
    },

    async averageRating(product: { upc: string }, _: unknown, ctx: Context) {
      const productReviews = await ctx.loaders.reviewsByProductUpc.load(product.upc);
      if (productReviews.length === 0) return null;
      const sum = productReviews.reduce((acc, r) => acc + r.rating, 0);
      return Math.round((sum / productReviews.length) * 10) / 10;
    },

    async reviewCount(product: { upc: string }, _: unknown, ctx: Context) {
      const productReviews = await ctx.loaders.reviewsByProductUpc.load(product.upc);
      return productReviews.length;
    },

    // @requires(fields: "name") — the router fetches `name` from the Products subgraph first
    async reviewSummary(product: { upc: string; name?: string }, _: unknown, ctx: Context) {
      const productReviews = await ctx.loaders.reviewsByProductUpc.load(product.upc);
      const avgRating = productReviews.length > 0
        ? (productReviews.reduce((s, r) => s + r.rating, 0) / productReviews.length).toFixed(1)
        : 'N/A';
      return `${product.name ?? 'Product'}: ${productReviews.length} review(s), avg ${avgRating}/5`;
    },
  },

  User: {
    async reviews(user: { id: string }, _: unknown, ctx: Context) {
      return ctx.loaders.reviewsByAuthorId.load(user.id);
    },

    async reviewCount(user: { id: string }, _: unknown, ctx: Context) {
      const userReviews = await ctx.loaders.reviewsByAuthorId.load(user.id);
      return userReviews.length;
    },
  },
};

// ── Server Setup ────────────────────────────────────────────────────────────

const server = new ApolloServer<Context>({
  schema: buildSubgraphSchema({ typeDefs, resolvers }),
});

const PORT = parseInt(process.env.PORT || '4002', 10);

startStandaloneServer(server, {
  listen: { port: PORT },
  context: async ({ req }) => ({
    loaders: createLoaders(),
    userId: req.headers['x-user-id'] as string | undefined,
  }),
}).then(({ url }) => {
  console.log(`🚀 Reviews subgraph ready at ${url}`);
});
