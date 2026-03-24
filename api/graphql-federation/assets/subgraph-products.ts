/**
 * Products Subgraph — Apollo Federation v2
 *
 * Owns: Product, Category entities
 * Demonstrates: @key, @shareable, DataLoader, entity resolution
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
      import: ["@key", "@shareable"])

  type Query {
    product(upc: String!): Product
    topProducts(first: Int = 5): [Product!]!
    categories: [Category!]!
  }

  type Mutation {
    updateProductPrice(upc: String!, price: Int!): Product
  }

  type Product @key(fields: "upc") {
    upc: String!
    name: String!
    price: Int!
    weight: Int
    category: Category!
    createdAt: String!
  }

  type Category @key(fields: "id") {
    id: ID!
    name: String!
    products: [Product!]!
  }

  "Shared value type — identical across subgraphs"
  type Money @shareable {
    amount: Int!
    currency: String!
  }
`);

// ── Data ────────────────────────────────────────────────────────────────────

interface ProductRecord {
  upc: string;
  name: string;
  price: number;
  weight: number;
  categoryId: string;
  createdAt: string;
}

interface CategoryRecord {
  id: string;
  name: string;
}

const categories: CategoryRecord[] = [
  { id: 'cat-1', name: 'Furniture' },
  { id: 'cat-2', name: 'Electronics' },
  { id: 'cat-3', name: 'Kitchen' },
];

const products: ProductRecord[] = [
  { upc: '1', name: 'Table',     price: 899,  weight: 100, categoryId: 'cat-1', createdAt: '2024-01-15T10:00:00Z' },
  { upc: '2', name: 'Couch',     price: 1299, weight: 1000, categoryId: 'cat-1', createdAt: '2024-02-20T14:30:00Z' },
  { upc: '3', name: 'Chair',     price: 54,   weight: 50,  categoryId: 'cat-1', createdAt: '2024-03-10T09:15:00Z' },
  { upc: '4', name: 'Laptop',    price: 1499, weight: 5,   categoryId: 'cat-2', createdAt: '2024-04-05T11:00:00Z' },
  { upc: '5', name: 'Toaster',   price: 39,   weight: 8,   categoryId: 'cat-3', createdAt: '2024-05-01T08:45:00Z' },
];

// ── DataLoaders (created per request to avoid cross-request cache leaks) ────

function createLoaders() {
  return {
    productByUpc: new DataLoader<string, ProductRecord | undefined>(async (upcs) => {
      // Simulates a batched DB query: SELECT * FROM products WHERE upc IN (...)
      console.log(`[DataLoader] Batch loading products: ${upcs.join(', ')}`);
      return upcs.map((upc) => products.find((p) => p.upc === upc));
    }),

    categoryById: new DataLoader<string, CategoryRecord | undefined>(async (ids) => {
      console.log(`[DataLoader] Batch loading categories: ${ids.join(', ')}`);
      return ids.map((id) => categories.find((c) => c.id === id));
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
    product: (_: unknown, { upc }: { upc: string }, ctx: Context) =>
      ctx.loaders.productByUpc.load(upc),

    topProducts: (_: unknown, { first }: { first: number }) =>
      products.slice(0, first),

    categories: () => categories,
  },

  Mutation: {
    updateProductPrice: (_: unknown, { upc, price }: { upc: string; price: number }) => {
      const product = products.find((p) => p.upc === upc);
      if (!product) throw new Error(`Product ${upc} not found`);
      product.price = price;
      return product;
    },
  },

  Product: {
    // Entity resolution — called by the router when another subgraph references a Product
    __resolveReference(ref: { upc: string }, ctx: Context) {
      return ctx.loaders.productByUpc.load(ref.upc);
    },

    category(product: ProductRecord, _: unknown, ctx: Context) {
      return ctx.loaders.categoryById.load(product.categoryId);
    },
  },

  Category: {
    __resolveReference(ref: { id: string }) {
      return categories.find((c) => c.id === ref.id);
    },

    products(category: CategoryRecord) {
      return products.filter((p) => p.categoryId === category.id);
    },
  },
};

// ── Server Setup ────────────────────────────────────────────────────────────

const server = new ApolloServer<Context>({
  schema: buildSubgraphSchema({ typeDefs, resolvers }),
});

const PORT = parseInt(process.env.PORT || '4001', 10);

startStandaloneServer(server, {
  listen: { port: PORT },
  context: async ({ req }) => ({
    loaders: createLoaders(),
    userId: req.headers['x-user-id'] as string | undefined,
  }),
}).then(({ url }) => {
  console.log(`🚀 Products subgraph ready at ${url}`);
});
