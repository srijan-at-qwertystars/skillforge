/**
 * Reusable mock factories for common testing patterns.
 * Provides type-safe factory functions to reduce boilerplate in tests.
 */

// ---- Entity Factories ----

type DeepPartial<T> = {
  [P in keyof T]?: T[P] extends object ? DeepPartial<T[P]> : T[P];
};

/**
 * Creates a factory function for test entities with sensible defaults.
 *
 * @example
 * const createUser = createFactory<User>({
 *   id: 1, name: 'Test User', email: 'test@example.com', role: 'user',
 * });
 * const admin = createUser({ role: 'admin', name: 'Admin' });
 * const users = createUser.many(5, (i) => ({ id: i, email: `user${i}@test.com` }));
 */
function createFactory<T extends Record<string, unknown>>(defaults: T) {
  const factory = (overrides: DeepPartial<T> = {}): T => ({
    ...defaults,
    ...overrides,
  } as T);

  factory.many = (count: number, overrideFn?: (index: number) => DeepPartial<T>): T[] =>
    Array.from({ length: count }, (_, i) =>
      factory(overrideFn ? overrideFn(i) : {})
    );

  return factory;
}

// ---- Example Factories ----

interface User {
  id: number;
  name: string;
  email: string;
  role: 'admin' | 'user' | 'viewer';
  createdAt: string;
}

const createUser = createFactory<User>({
  id: 1,
  name: 'Test User',
  email: 'test@example.com',
  role: 'user',
  createdAt: '2024-01-01T00:00:00Z',
});

interface ApiResponse<T> {
  data: T;
  status: number;
  message: string;
  pagination?: { page: number; total: number; perPage: number };
}

function createApiResponse<T>(data: T, overrides: Partial<ApiResponse<T>> = {}): ApiResponse<T> {
  return {
    data,
    status: 200,
    message: 'OK',
    ...overrides,
  };
}

function createPaginatedResponse<T>(
  items: T[],
  page = 1,
  perPage = 20,
  total?: number,
): ApiResponse<T[]> {
  return createApiResponse(items, {
    pagination: { page, total: total ?? items.length, perPage },
  });
}

function createErrorResponse(status: number, message: string): ApiResponse<null> {
  return { data: null, status, message };
}

// ---- Mock Service Factories ----

/**
 * Creates a mock for a class/service with all methods as jest.fn().
 *
 * @example
 * const mockUserService = createMockService<UserService>(['getUser', 'createUser', 'deleteUser']);
 * mockUserService.getUser.mockResolvedValue(createUser());
 */
function createMockService<T>(methods: (keyof T)[]): jest.Mocked<T> {
  const mock = {} as jest.Mocked<T>;
  for (const method of methods) {
    (mock as Record<string, unknown>)[method as string] = jest.fn();
  }
  return mock;
}

/**
 * Creates a mock for a class using its prototype methods.
 *
 * @example
 * const MockedRepo = createMockClass(UserRepository);
 * const repo = new MockedRepo();
 * repo.findById.mockResolvedValue(createUser());
 */
function createMockClass<T extends new (...args: unknown[]) => unknown>(
  ClassRef: T,
): jest.MockedClass<T> {
  return ClassRef as jest.MockedClass<T>;
}

// ---- Storage Mocks ----

function createMockLocalStorage(): Storage {
  const store = new Map<string, string>();
  return {
    getItem: jest.fn((key: string) => store.get(key) ?? null),
    setItem: jest.fn((key: string, value: string) => { store.set(key, value); }),
    removeItem: jest.fn((key: string) => { store.delete(key); }),
    clear: jest.fn(() => { store.clear(); }),
    get length() { return store.size; },
    key: jest.fn((index: number) => [...store.keys()][index] ?? null),
  };
}

// ---- Router Mocks ----

function createMockRouter(overrides: Record<string, unknown> = {}) {
  return {
    push: jest.fn(),
    replace: jest.fn(),
    back: jest.fn(),
    forward: jest.fn(),
    refresh: jest.fn(),
    prefetch: jest.fn(),
    pathname: '/',
    query: {},
    asPath: '/',
    locale: 'en',
    ...overrides,
  };
}

// ---- Event Factories ----

function createMockEvent(overrides: Partial<Event> = {}): Partial<Event> {
  return {
    preventDefault: jest.fn(),
    stopPropagation: jest.fn(),
    ...overrides,
  };
}

function createMockChangeEvent(value: string) {
  return { target: { value }, ...createMockEvent() };
}

// ---- Exports ----

export {
  createFactory,
  createUser,
  createApiResponse,
  createPaginatedResponse,
  createErrorResponse,
  createMockService,
  createMockClass,
  createMockLocalStorage,
  createMockRouter,
  createMockEvent,
  createMockChangeEvent,
  type DeepPartial,
};
