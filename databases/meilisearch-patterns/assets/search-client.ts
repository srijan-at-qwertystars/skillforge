/**
 * Meilisearch TypeScript Search Client
 *
 * A type-safe wrapper around the Meilisearch JS SDK providing:
 *  - Generic index operations
 *  - Filtered, faceted, sorted, and paginated search
 *  - InstantSearch.js adapter integration
 *  - Hybrid / semantic search helpers
 *  - Multi-index search
 *  - Tenant-token generation
 *  - Document CRUD & task waiting utilities
 *  - Index settings management
 *
 * @example
 * ```ts
 * import { createClient, search, addDocuments } from "./search-client";
 *
 * const client = createClient("http://localhost:7700", "masterKey");
 * await addDocuments(client, "products", [{ id: 1, name: "Keyboard" }]);
 * const results = await search<Product>(client, "products", "keyboard");
 * ```
 */

import {
  MeiliSearch,
  Index,
  SearchParams,
  SearchResponse,
  MultiSearchParams,
  MultiSearchResponse,
  EnqueuedTask,
  Task,
  Settings,
  TokenSearchRules,
} from "meilisearch";

// Re-export the SDK client type for consumers.
export type { MeiliSearch, Index, SearchResponse, Task, Settings };

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Options accepted by {@link createClient}. */
export interface ClientOptions {
  /** Meilisearch host URL (default: http://localhost:7700). */
  host?: string;
  /** API key – use a search-only key in the browser. */
  apiKey?: string;
  /** Custom request headers forwarded with every HTTP call. */
  headers?: Record<string, string>;
}

/** Extended search parameters exposing the most useful knobs. */
export interface SearchOptions<T = Record<string, unknown>> {
  /** Full-text query string. */
  q?: string;
  /** Filter expression (string or nested array). */
  filter?: string | string[] | string[][];
  /** Attributes to use as facets in the response. */
  facets?: string[];
  /** Sort rules, e.g. ["price:asc", "rating:desc"]. */
  sort?: string[];
  /** Number of results per page (default 20). */
  limit?: number;
  /** Offset for cursor-based pagination. */
  offset?: number;
  /** Page number (1-based) for page-based pagination. */
  page?: number;
  /** Hits per page when using page-based pagination. */
  hitsPerPage?: number;
  /** Attributes to retrieve (defaults to displayedAttributes). */
  attributesToRetrieve?: (keyof T & string)[];
  /** Attributes to highlight. */
  attributesToHighlight?: (keyof T & string)[];
  /** Attributes to crop. */
  attributesToCrop?: (keyof T & string)[];
  /** Enable hybrid search with semantic ratio (0 = keyword, 1 = semantic). */
  hybridSemanticRatio?: number;
  /** Embedder to use for hybrid search. */
  hybridEmbedder?: string;
}

/** Typed error wrapper for Meilisearch API errors. */
export class MeiliSearchError extends Error {
  constructor(
    message: string,
    public readonly code: string,
    public readonly httpStatus: number,
    public readonly link?: string,
  ) {
    super(message);
    this.name = "MeiliSearchError";
  }
}

// ---------------------------------------------------------------------------
// Client Initialization
// ---------------------------------------------------------------------------

/**
 * Create and return a configured MeiliSearch client instance.
 *
 * @param host - Meilisearch server URL.
 * @param apiKey - API key for authentication.
 * @param headers - Optional custom HTTP headers.
 * @returns A {@link MeiliSearch} client.
 */
export function createClient(
  host = "http://localhost:7700",
  apiKey?: string,
  headers?: Record<string, string>,
): MeiliSearch {
  return new MeiliSearch({ host, apiKey, headers });
}

// ---------------------------------------------------------------------------
// Index Operations
// ---------------------------------------------------------------------------

/**
 * Get or create an index, returning a typed {@link Index} handle.
 *
 * @param client - MeiliSearch client instance.
 * @param uid - Unique index identifier.
 * @param primaryKey - Optional primary key field name.
 * @returns The index handle.
 */
export async function getOrCreateIndex<T extends Record<string, unknown>>(
  client: MeiliSearch,
  uid: string,
  primaryKey?: string,
): Promise<Index<T>> {
  try {
    return await client.getIndex<T>(uid);
  } catch {
    const task = await client.createIndex(uid, { primaryKey });
    await client.waitForTask(task.taskUid);
    return client.getIndex<T>(uid);
  }
}

/**
 * Delete an index by its uid.
 *
 * @param client - MeiliSearch client instance.
 * @param uid - Index identifier to delete.
 */
export async function deleteIndex(
  client: MeiliSearch,
  uid: string,
): Promise<void> {
  const task = await client.deleteIndex(uid);
  await client.waitForTask(task.taskUid);
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

/**
 * Perform a search on the given index with type-safe options.
 *
 * @typeParam T - Shape of a document in the index.
 * @param client - MeiliSearch client.
 * @param indexUid - Target index identifier.
 * @param query - Search query string.
 * @param options - Additional search options.
 * @returns Typed search response.
 */
export async function search<T extends Record<string, unknown>>(
  client: MeiliSearch,
  indexUid: string,
  query: string,
  options: SearchOptions<T> = {},
): Promise<SearchResponse<T>> {
  const index = client.index<T>(indexUid);

  const params: SearchParams = {
    filter: options.filter,
    facets: options.facets,
    sort: options.sort,
    limit: options.limit,
    offset: options.offset,
    page: options.page,
    hitsPerPage: options.hitsPerPage,
    attributesToRetrieve: options.attributesToRetrieve as string[],
    attributesToHighlight: options.attributesToHighlight as string[],
    attributesToCrop: options.attributesToCrop as string[],
  };

  // Hybrid / semantic search support (Meilisearch v1.3+).
  if (options.hybridSemanticRatio !== undefined) {
    (params as Record<string, unknown>).hybrid = {
      semanticRatio: options.hybridSemanticRatio,
      embedder: options.hybridEmbedder ?? "default",
    };
  }

  return index.search(query, params);
}

/**
 * Execute a multi-index search in a single HTTP round-trip.
 *
 * @param client - MeiliSearch client.
 * @param queries - Array of per-index search queries.
 * @returns Combined results from all queried indexes.
 */
export async function multiSearch(
  client: MeiliSearch,
  queries: MultiSearchParams["queries"],
): Promise<MultiSearchResponse> {
  return client.multiSearch({ queries });
}

/**
 * Helper for hybrid / semantic search on a single index.
 *
 * @param client - MeiliSearch client.
 * @param indexUid - Target index.
 * @param query - Natural-language query.
 * @param semanticRatio - Balance between keyword (0) and semantic (1). Default 0.5.
 * @param embedder - Name of the configured embedder. Default "default".
 * @returns Search response.
 */
export async function hybridSearch<T extends Record<string, unknown>>(
  client: MeiliSearch,
  indexUid: string,
  query: string,
  semanticRatio = 0.5,
  embedder = "default",
): Promise<SearchResponse<T>> {
  return search<T>(client, indexUid, query, {
    hybridSemanticRatio: semanticRatio,
    hybridEmbedder: embedder,
  });
}

// ---------------------------------------------------------------------------
// InstantSearch.js Integration
// ---------------------------------------------------------------------------

/**
 * Create an InstantSearch.js-compatible search client using the
 * `@meilisearch/instant-meilisearch` adapter.
 *
 * @example
 * ```ts
 * import { createInstantSearchClient } from "./search-client";
 * import instantsearch from "instantsearch.js";
 * import { searchBox, hits } from "instantsearch.js/es/widgets";
 *
 * const { searchClient, setMeiliSearchParams } = createInstantSearchClient(
 *   "http://localhost:7700",
 *   "searchOnlyApiKey",
 * );
 *
 * const search = instantsearch({ indexName: "products", searchClient });
 * search.addWidgets([searchBox({ container: "#search" }), hits({ container: "#hits" })]);
 * search.start();
 * ```
 *
 * @param host - Meilisearch URL.
 * @param apiKey - Search-only API key.
 * @param options - Adapter-specific options (finitePagination, etc.).
 * @returns The adapter's return value (searchClient + helpers).
 */
export function createInstantSearchClient(
  host: string,
  apiKey: string,
  options: Record<string, unknown> = {},
) {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { instantMeiliSearch } = require("@meilisearch/instant-meilisearch");
  return instantMeiliSearch(host, apiKey, {
    finitePagination: true,
    ...options,
  });
}

// ---------------------------------------------------------------------------
// Document CRUD
// ---------------------------------------------------------------------------

/**
 * Add or replace documents in an index.
 *
 * @param client - MeiliSearch client.
 * @param indexUid - Target index.
 * @param documents - Array of document objects.
 * @param primaryKey - Optional primary key override.
 * @returns The enqueued task.
 */
export async function addDocuments<T extends Record<string, unknown>>(
  client: MeiliSearch,
  indexUid: string,
  documents: T[],
  primaryKey?: string,
): Promise<EnqueuedTask> {
  const index = client.index<T>(indexUid);
  return index.addDocuments(documents, { primaryKey });
}

/**
 * Partially update documents (merge with existing fields).
 *
 * @param client - MeiliSearch client.
 * @param indexUid - Target index.
 * @param documents - Partial document objects (must contain the primary key).
 * @returns The enqueued task.
 */
export async function updateDocuments<T extends Record<string, unknown>>(
  client: MeiliSearch,
  indexUid: string,
  documents: Partial<T>[],
): Promise<EnqueuedTask> {
  const index = client.index<T>(indexUid);
  return index.updateDocuments(documents as T[]);
}

/**
 * Delete documents by their primary-key values.
 *
 * @param client - MeiliSearch client.
 * @param indexUid - Target index.
 * @param ids - Array of document IDs (primary key values).
 * @returns The enqueued task.
 */
export async function deleteDocuments(
  client: MeiliSearch,
  indexUid: string,
  ids: (string | number)[],
): Promise<EnqueuedTask> {
  const index = client.index(indexUid);
  return index.deleteDocuments(ids);
}

// ---------------------------------------------------------------------------
// Task Utilities
// ---------------------------------------------------------------------------

/**
 * Wait for a task to reach a terminal state (succeeded / failed).
 *
 * @param client - MeiliSearch client.
 * @param taskUid - Task identifier returned by any write operation.
 * @param timeoutMs - Maximum time to wait in milliseconds (default 30 000).
 * @param intervalMs - Polling interval in milliseconds (default 250).
 * @returns The completed {@link Task}.
 * @throws {MeiliSearchError} If the task fails.
 */
export async function waitForTask(
  client: MeiliSearch,
  taskUid: number,
  timeoutMs = 30_000,
  intervalMs = 250,
): Promise<Task> {
  const task = await client.waitForTask(taskUid, {
    timeOutMs: timeoutMs,
    intervalMs,
  });

  if (task.status === "failed") {
    throw new MeiliSearchError(
      task.error?.message ?? "Task failed",
      task.error?.code ?? "unknown",
      0,
      task.error?.link,
    );
  }

  return task;
}

// ---------------------------------------------------------------------------
// Index Settings Management
// ---------------------------------------------------------------------------

/**
 * Retrieve the full settings object for an index.
 *
 * @param client - MeiliSearch client.
 * @param indexUid - Target index.
 * @returns Current index {@link Settings}.
 */
export async function getSettings(
  client: MeiliSearch,
  indexUid: string,
): Promise<Settings> {
  const index = client.index(indexUid);
  return index.getSettings();
}

/**
 * Apply a partial settings update to an index and wait for completion.
 *
 * @param client - MeiliSearch client.
 * @param indexUid - Target index.
 * @param settings - Partial {@link Settings} to merge.
 * @returns The completed task.
 */
export async function updateSettings(
  client: MeiliSearch,
  indexUid: string,
  settings: Settings,
): Promise<Task> {
  const index = client.index(indexUid);
  const enqueued = await index.updateSettings(settings);
  return waitForTask(client, enqueued.taskUid);
}

/**
 * Reset all settings of an index to their default values.
 *
 * @param client - MeiliSearch client.
 * @param indexUid - Target index.
 * @returns The completed task.
 */
export async function resetSettings(
  client: MeiliSearch,
  indexUid: string,
): Promise<Task> {
  const index = client.index(indexUid);
  const enqueued = await index.resetSettings();
  return waitForTask(client, enqueued.taskUid);
}

// ---------------------------------------------------------------------------
// Tenant Token Generation
// ---------------------------------------------------------------------------

/**
 * Generate a tenant token that restricts search to specific filter rules.
 *
 * Tenant tokens are JWTs signed with an API key; they let you expose
 * search to end-users while enforcing row-level security.
 *
 * @param client - MeiliSearch client.
 * @param apiKeyUid - UID of the parent API key (visible in /keys).
 * @param searchRules - Per-index filter rules to embed in the token.
 * @param expiresAt - Optional expiry date for the token.
 * @returns A signed JWT string.
 *
 * @example
 * ```ts
 * const token = await generateTenantToken(client, apiKeyUid, {
 *   products: { filter: "tenant_id = 42" },
 * });
 * ```
 */
export async function generateTenantToken(
  client: MeiliSearch,
  apiKeyUid: string,
  searchRules: TokenSearchRules,
  expiresAt?: Date,
): Promise<string> {
  return client.generateTenantToken(apiKeyUid, searchRules, {
    expiresAt,
  });
}

// ---------------------------------------------------------------------------
// Error Handling Utility
// ---------------------------------------------------------------------------

/**
 * Wrap an async Meilisearch call, converting SDK errors into {@link MeiliSearchError}.
 *
 * @param fn - Async function to execute.
 * @returns The resolved value of `fn`.
 * @throws {MeiliSearchError} on failure.
 */
export async function withErrorHandling<T>(fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (err: unknown) {
    if (err && typeof err === "object" && "httpStatus" in err) {
      const e = err as {
        message: string;
        code: string;
        httpStatus: number;
        link?: string;
      };
      throw new MeiliSearchError(e.message, e.code, e.httpStatus, e.link);
    }
    throw err;
  }
}
