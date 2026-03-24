/**
 * MSW (Mock Service Worker) handler templates for API mocking.
 * Use with setupServer (Node/Jest) to intercept network requests.
 *
 * Setup in jest.setup.ts:
 *   import { server } from './src/mocks/server';
 *   beforeAll(() => server.listen({ onUnhandledRequest: 'error' }));
 *   afterEach(() => server.resetHandlers());
 *   afterAll(() => server.close());
 */
import { http, HttpResponse, delay, type HttpHandler } from 'msw';
import { setupServer } from 'msw/node';

// ---- Types ----

interface User {
  id: number;
  name: string;
  email: string;
}

interface ApiError {
  message: string;
  code: string;
}

// ---- CRUD Handlers ----

const BASE_URL = process.env.API_URL ?? 'http://localhost:3000/api';

function url(path: string): string {
  return `${BASE_URL}${path}`;
}

/** Standard REST handlers for a resource */
function createCrudHandlers<T extends { id: number }>(
  resource: string,
  defaultItems: T[],
): HttpHandler[] {
  let items = [...defaultItems];

  return [
    // GET /api/{resource}
    http.get(url(`/${resource}`), async ({ request }) => {
      const searchParams = new URL(request.url).searchParams;
      const page = Number(searchParams.get('page') ?? 1);
      const limit = Number(searchParams.get('limit') ?? 20);
      const start = (page - 1) * limit;

      return HttpResponse.json({
        data: items.slice(start, start + limit),
        pagination: { page, total: items.length, perPage: limit },
      });
    }),

    // GET /api/{resource}/:id
    http.get(url(`/${resource}/:id`), ({ params }) => {
      const item = items.find((i) => i.id === Number(params.id));
      if (!item) {
        return HttpResponse.json(
          { message: `${resource} not found`, code: 'NOT_FOUND' } satisfies ApiError,
          { status: 404 },
        );
      }
      return HttpResponse.json({ data: item });
    }),

    // POST /api/{resource}
    http.post(url(`/${resource}`), async ({ request }) => {
      const body = (await request.json()) as Omit<T, 'id'>;
      const newItem = { ...body, id: items.length + 1 } as T;
      items.push(newItem);
      return HttpResponse.json({ data: newItem }, { status: 201 });
    }),

    // PUT /api/{resource}/:id
    http.put(url(`/${resource}/:id`), async ({ params, request }) => {
      const body = (await request.json()) as Partial<T>;
      const index = items.findIndex((i) => i.id === Number(params.id));
      if (index === -1) {
        return HttpResponse.json(
          { message: 'Not found', code: 'NOT_FOUND' } satisfies ApiError,
          { status: 404 },
        );
      }
      items[index] = { ...items[index], ...body };
      return HttpResponse.json({ data: items[index] });
    }),

    // DELETE /api/{resource}/:id
    http.delete(url(`/${resource}/:id`), ({ params }) => {
      items = items.filter((i) => i.id !== Number(params.id));
      return new HttpResponse(null, { status: 204 });
    }),
  ];
}

// ---- Specific Handlers ----

const defaultUsers: User[] = [
  { id: 1, name: 'Alice', email: 'alice@example.com' },
  { id: 2, name: 'Bob', email: 'bob@example.com' },
];

const userHandlers = createCrudHandlers<User>('users', defaultUsers);

const authHandlers: HttpHandler[] = [
  http.post(url('/auth/login'), async ({ request }) => {
    const { email, password } = (await request.json()) as { email: string; password: string };
    if (email === 'test@example.com' && password === 'password') {
      return HttpResponse.json({
        token: 'mock-jwt-token',
        user: defaultUsers[0],
      });
    }
    return HttpResponse.json(
      { message: 'Invalid credentials', code: 'UNAUTHORIZED' } satisfies ApiError,
      { status: 401 },
    );
  }),

  http.post(url('/auth/logout'), () => {
    return new HttpResponse(null, { status: 204 });
  }),

  http.get(url('/auth/me'), ({ request }) => {
    const authHeader = request.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return HttpResponse.json(
        { message: 'Unauthorized', code: 'UNAUTHORIZED' } satisfies ApiError,
        { status: 401 },
      );
    }
    return HttpResponse.json({ data: defaultUsers[0] });
  }),
];

// ---- Utility Handlers ----

/** Simulate a slow response */
function withDelay(ms: number, handler: HttpHandler): HttpHandler {
  // Use per-test overrides with server.use() instead
  return handler; // delay is applied inside handler if needed
}

/** Handler that always returns an error */
function errorHandler(method: 'get' | 'post' | 'put' | 'delete', path: string, status = 500): HttpHandler {
  const methods = { get: http.get, post: http.post, put: http.put, delete: http.delete };
  return methods[method](url(path), () =>
    HttpResponse.json(
      { message: 'Internal Server Error', code: 'INTERNAL_ERROR' } satisfies ApiError,
      { status },
    ),
  );
}

/** Handler that simulates network error */
function networkErrorHandler(method: 'get' | 'post', path: string): HttpHandler {
  const methods = { get: http.get, post: http.post };
  return methods[method](url(path), () => HttpResponse.error());
}

/** Handler with artificial delay */
function slowHandler(method: 'get' | 'post', path: string, delayMs: number, body: unknown = {}): HttpHandler {
  const methods = { get: http.get, post: http.post };
  return methods[method](url(path), async () => {
    await delay(delayMs);
    return HttpResponse.json(body);
  });
}

// ---- Combined Handlers ----

const handlers: HttpHandler[] = [...userHandlers, ...authHandlers];

// ---- Server Setup ----

const server = setupServer(...handlers);

// ---- Exports ----

export {
  server,
  handlers,
  userHandlers,
  authHandlers,
  createCrudHandlers,
  errorHandler,
  networkErrorHandler,
  slowHandler,
  url,
  defaultUsers,
};
