#!/usr/bin/env bash
set -euo pipefail

# setup-federation.sh — Scaffold a local Apollo Federation v2 development environment
# Creates: router config, 2 sample subgraphs (products, reviews), compose config
# Usage: ./setup-federation.sh [target-dir]

TARGET_DIR="${1:-.}/federation-dev"
ROUTER_PORT=4000
PRODUCTS_PORT=4001
REVIEWS_PORT=4002

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ── Pre-flight checks ────────────────────────────────────────────────────────

check_command() {
  command -v "$1" &>/dev/null || { warn "$1 not found — some steps may be skipped"; return 1; }
}

info "Checking prerequisites..."
HAS_NODE=true;   check_command node   || HAS_NODE=false
HAS_NPM=true;    check_command npm    || HAS_NPM=false
HAS_ROVER=true;  check_command rover  || HAS_ROVER=false
HAS_ROUTER=true; check_command router || HAS_ROUTER=false
HAS_DOCKER=true; check_command docker || HAS_DOCKER=false

# ── Create project structure ─────────────────────────────────────────────────

info "Creating project at ${TARGET_DIR}..."
mkdir -p "${TARGET_DIR}"/{subgraphs/products,subgraphs/reviews,schemas,router}

# ── Products subgraph schema ─────────────────────────────────────────────────

cat > "${TARGET_DIR}/subgraphs/products/schema.graphql" << 'SCHEMA'
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.7",
    import: ["@key", "@shareable"])

type Query {
  product(upc: String!): Product
  topProducts(first: Int = 5): [Product!]!
}

type Product @key(fields: "upc") {
  upc: String!
  name: String!
  price: Int!
  weight: Int
}
SCHEMA

cat > "${TARGET_DIR}/subgraphs/products/index.ts" << 'TS'
import { ApolloServer } from '@apollo/server';
import { startStandaloneServer } from '@apollo/server/standalone';
import { buildSubgraphSchema } from '@apollo/subgraph';
import { readFileSync } from 'fs';
import { parse } from 'graphql';

const typeDefs = parse(readFileSync('./schema.graphql', 'utf-8'));

const products = [
  { upc: '1', name: 'Table', price: 899, weight: 100 },
  { upc: '2', name: 'Couch', price: 1299, weight: 1000 },
  { upc: '3', name: 'Chair', price: 54, weight: 50 },
];

const resolvers = {
  Query: {
    product: (_: unknown, { upc }: { upc: string }) =>
      products.find((p) => p.upc === upc),
    topProducts: (_: unknown, { first }: { first: number }) =>
      products.slice(0, first),
  },
  Product: {
    __resolveReference(ref: { upc: string }) {
      return products.find((p) => p.upc === ref.upc);
    },
  },
};

const server = new ApolloServer({
  schema: buildSubgraphSchema({ typeDefs, resolvers }),
});

startStandaloneServer(server, { listen: { port: 4001 } }).then(({ url }) => {
  console.log(`Products subgraph ready at ${url}`);
});
TS

cat > "${TARGET_DIR}/subgraphs/products/package.json" << 'JSON'
{
  "name": "subgraph-products",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "tsx index.ts",
    "dev": "tsx watch index.ts"
  },
  "dependencies": {
    "@apollo/server": "^4.11.0",
    "@apollo/subgraph": "^2.9.0",
    "graphql": "^16.9.0"
  },
  "devDependencies": {
    "tsx": "^4.19.0"
  }
}
JSON

# ── Reviews subgraph schema ──────────────────────────────────────────────────

cat > "${TARGET_DIR}/subgraphs/reviews/schema.graphql" << 'SCHEMA'
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.7",
    import: ["@key", "@external", "@requires"])

type Query {
  review(id: ID!): Review
}

type Review @key(fields: "id") {
  id: ID!
  body: String!
  rating: Int!
  product: Product!
}

type Product @key(fields: "upc") {
  upc: String!
  reviews: [Review!]!
  averageRating: Float
  name: String @external
  reviewSummary: String @requires(fields: "name")
}
SCHEMA

cat > "${TARGET_DIR}/subgraphs/reviews/index.ts" << 'TS'
import { ApolloServer } from '@apollo/server';
import { startStandaloneServer } from '@apollo/server/standalone';
import { buildSubgraphSchema } from '@apollo/subgraph';
import { readFileSync } from 'fs';
import { parse } from 'graphql';

const typeDefs = parse(readFileSync('./schema.graphql', 'utf-8'));

const reviews = [
  { id: '1', body: 'Love it!', rating: 5, productUpc: '1' },
  { id: '2', body: 'Too expensive.', rating: 3, productUpc: '1' },
  { id: '3', body: 'Very comfortable.', rating: 4, productUpc: '2' },
  { id: '4', body: 'Could be better.', rating: 2, productUpc: '3' },
];

const resolvers = {
  Query: {
    review: (_: unknown, { id }: { id: string }) =>
      reviews.find((r) => r.id === id),
  },
  Review: {
    __resolveReference(ref: { id: string }) {
      return reviews.find((r) => r.id === ref.id);
    },
    product(review: { productUpc: string }) {
      return { __typename: 'Product', upc: review.productUpc };
    },
  },
  Product: {
    reviews(product: { upc: string }) {
      return reviews.filter((r) => r.productUpc === product.upc);
    },
    averageRating(product: { upc: string }) {
      const productReviews = reviews.filter((r) => r.productUpc === product.upc);
      if (productReviews.length === 0) return null;
      return productReviews.reduce((sum, r) => sum + r.rating, 0) / productReviews.length;
    },
    reviewSummary(product: { upc: string; name?: string }) {
      const count = reviews.filter((r) => r.productUpc === product.upc).length;
      return `${product.name ?? 'Product'} has ${count} review(s)`;
    },
  },
};

const server = new ApolloServer({
  schema: buildSubgraphSchema({ typeDefs, resolvers }),
});

startStandaloneServer(server, { listen: { port: 4002 } }).then(({ url }) => {
  console.log(`Reviews subgraph ready at ${url}`);
});
TS

cat > "${TARGET_DIR}/subgraphs/reviews/package.json" << 'JSON'
{
  "name": "subgraph-reviews",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "tsx index.ts",
    "dev": "tsx watch index.ts"
  },
  "dependencies": {
    "@apollo/server": "^4.11.0",
    "@apollo/subgraph": "^2.9.0",
    "graphql": "^16.9.0"
  },
  "devDependencies": {
    "tsx": "^4.19.0"
  }
}
JSON

# ── Supergraph composition config ────────────────────────────────────────────

cat > "${TARGET_DIR}/supergraph.yaml" << YAML
federation_version: =2.7.1
subgraphs:
  products:
    routing_url: http://localhost:${PRODUCTS_PORT}/graphql
    schema:
      file: ./subgraphs/products/schema.graphql
  reviews:
    routing_url: http://localhost:${REVIEWS_PORT}/graphql
    schema:
      file: ./subgraphs/reviews/schema.graphql
YAML

# ── Router configuration ─────────────────────────────────────────────────────

cat > "${TARGET_DIR}/router/router.yaml" << YAML
supergraph:
  listen: 0.0.0.0:${ROUTER_PORT}
  path: /graphql

sandbox:
  enabled: true

homepage:
  enabled: false

cors:
  origins:
    - http://localhost:3000
    - https://studio.apollographql.com
  allow_headers:
    - Content-Type
    - Authorization
    - Apollo-Require-Preflight

headers:
  all:
    request:
      - propagate:
          named: Authorization
      - propagate:
          named: X-Request-ID

traffic_shaping:
  all:
    deduplicate_query: true
    timeout: 30s
  subgraphs:
    products:
      timeout: 10s
    reviews:
      timeout: 10s

health_check:
  listen: 0.0.0.0:8088
  enabled: true
  path: /health

telemetry:
  exporters:
    logging:
      stdout:
        enabled: true
        format:
          text:
            display_filename: false
            display_line_number: false
YAML

# ── Docker Compose ────────────────────────────────────────────────────────────

cat > "${TARGET_DIR}/docker-compose.yml" << 'YAML'
services:
  products:
    build: ./subgraphs/products
    ports:
      - "4001:4001"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4001/graphql?query=%7B__typename%7D"]
      interval: 10s
      timeout: 5s
      retries: 3

  reviews:
    build: ./subgraphs/reviews
    ports:
      - "4002:4002"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4002/graphql?query=%7B__typename%7D"]
      interval: 10s
      timeout: 5s
      retries: 3

  router:
    image: ghcr.io/apollographql/router:v1.57.1
    ports:
      - "4000:4000"
      - "8088:8088"
    volumes:
      - ./router/router.yaml:/dist/config/router.yaml
      - ./supergraph.graphql:/dist/config/supergraph.graphql
    command:
      - --config
      - /dist/config/router.yaml
      - --supergraph
      - /dist/config/supergraph.graphql
      - --dev
    depends_on:
      products:
        condition: service_healthy
      reviews:
        condition: service_healthy
YAML

ok "Project scaffolded at ${TARGET_DIR}"

# ── Compose supergraph ────────────────────────────────────────────────────────

if [[ "${HAS_ROVER}" == "true" ]]; then
  info "Composing supergraph schema..."
  cd "${TARGET_DIR}"
  if rover supergraph compose --config supergraph.yaml --output supergraph.graphql 2>/dev/null; then
    ok "Supergraph composed → supergraph.graphql"
  else
    warn "Composition failed — check subgraph schemas for errors"
  fi
  cd - >/dev/null
else
  warn "Rover CLI not installed. Install with: curl -sSL https://rover.apollo.dev/nix/latest | sh"
  warn "Then run: cd ${TARGET_DIR} && rover supergraph compose --config supergraph.yaml --output supergraph.graphql"
fi

# ── Install dependencies ─────────────────────────────────────────────────────

if [[ "${HAS_NPM}" == "true" ]]; then
  info "Installing subgraph dependencies..."
  (cd "${TARGET_DIR}/subgraphs/products" && npm install --silent 2>/dev/null) && ok "Products deps installed"
  (cd "${TARGET_DIR}/subgraphs/reviews"  && npm install --silent 2>/dev/null) && ok "Reviews deps installed"
else
  warn "npm not found — run 'npm install' in each subgraph directory manually"
fi

# ── Print next steps ─────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────────────────────"
echo "  Federation development environment ready!"
echo "────────────────────────────────────────────────────────────"
echo ""
echo "  Start subgraphs:"
echo "    cd ${TARGET_DIR}/subgraphs/products && npm start"
echo "    cd ${TARGET_DIR}/subgraphs/reviews  && npm start"
echo ""
echo "  Compose supergraph (requires rover):"
echo "    cd ${TARGET_DIR} && rover supergraph compose --config supergraph.yaml --output supergraph.graphql"
echo ""
echo "  Start router (requires router binary):"
echo "    cd ${TARGET_DIR} && router --config router/router.yaml --supergraph supergraph.graphql --dev"
echo ""
echo "  Or use Docker Compose:"
echo "    cd ${TARGET_DIR} && docker compose up"
echo ""
echo "  Endpoints:"
echo "    Router:    http://localhost:${ROUTER_PORT}/graphql"
echo "    Products:  http://localhost:${PRODUCTS_PORT}/graphql"
echo "    Reviews:   http://localhost:${REVIEWS_PORT}/graphql"
echo "    Health:    http://localhost:8088/health"
echo ""
echo "  Test query:"
echo '    curl -s -X POST -H "Content-Type: application/json" \'
echo '      -d '\''{"query":"{ topProducts { upc name price reviews { body rating } } }"}'\'' \'
echo "      http://localhost:${ROUTER_PORT}/graphql | jq"
echo ""
