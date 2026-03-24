// msw-handlers.ts — MSW Mock Handler Templates
//
// Copy-paste these handlers for common API patterns.
// Use with msw-storybook-addon in your stories.
//
// Setup:
//   npm install -D msw msw-storybook-addon
//   npx msw init public/
//
// In preview.ts:
//   import { initialize, mswLoader } from 'msw-storybook-addon';
//   initialize();
//   const preview: Preview = { loaders: [mswLoader] };
//
// In stories:
//   parameters: { msw: { handlers: [myHandlers.list] } }

import { http, HttpResponse, delay } from 'msw';

// ============================================================
// Types — adjust to your API schema
// ============================================================

interface User {
  id: number;
  name: string;
  email: string;
  role: 'admin' | 'editor' | 'viewer';
  avatar?: string;
  createdAt: string;
}

interface PaginatedResponse<T> {
  data: T[];
  total: number;
  page: number;
  pageSize: number;
  totalPages: number;
}

interface ApiError {
  error: string;
  message: string;
  statusCode: number;
}

// ============================================================
// Mock Data
// ============================================================

const mockUsers: User[] = [
  { id: 1, name: 'Alice Johnson', email: 'alice@example.com', role: 'admin', createdAt: '2024-01-15T10:00:00Z' },
  { id: 2, name: 'Bob Smith', email: 'bob@example.com', role: 'editor', createdAt: '2024-02-20T14:30:00Z' },
  { id: 3, name: 'Carol Williams', email: 'carol@example.com', role: 'viewer', createdAt: '2024-03-10T09:15:00Z' },
  { id: 4, name: 'Dave Brown', email: 'dave@example.com', role: 'viewer', createdAt: '2024-04-05T16:45:00Z' },
  { id: 5, name: 'Eve Davis', email: 'eve@example.com', role: 'editor', createdAt: '2024-05-12T11:00:00Z' },
];

let nextId = mockUsers.length + 1;

// ============================================================
// REST CRUD Handlers
// ============================================================

/** Full CRUD handlers for /api/users */
export const userHandlers = {
  /** GET /api/users — list all users */
  list: http.get('/api/users', async () => {
    await delay(200);
    return HttpResponse.json(mockUsers);
  }),

  /** GET /api/users/:id — get single user */
  get: http.get('/api/users/:id', async ({ params }) => {
    await delay(150);
    const user = mockUsers.find((u) => u.id === Number(params.id));
    if (!user) {
      return HttpResponse.json(
        { error: 'Not Found', message: `User ${params.id} not found`, statusCode: 404 },
        { status: 404 }
      );
    }
    return HttpResponse.json(user);
  }),

  /** POST /api/users — create user */
  create: http.post('/api/users', async ({ request }) => {
    await delay(300);
    const body = (await request.json()) as Partial<User>;
    const newUser: User = {
      id: nextId++,
      name: body.name || 'New User',
      email: body.email || 'new@example.com',
      role: body.role || 'viewer',
      createdAt: new Date().toISOString(),
    };
    mockUsers.push(newUser);
    return HttpResponse.json(newUser, { status: 201 });
  }),

  /** PUT /api/users/:id — update user */
  update: http.put('/api/users/:id', async ({ params, request }) => {
    await delay(250);
    const idx = mockUsers.findIndex((u) => u.id === Number(params.id));
    if (idx === -1) {
      return HttpResponse.json(
        { error: 'Not Found', message: `User ${params.id} not found`, statusCode: 404 },
        { status: 404 }
      );
    }
    const body = (await request.json()) as Partial<User>;
    mockUsers[idx] = { ...mockUsers[idx], ...body };
    return HttpResponse.json(mockUsers[idx]);
  }),

  /** DELETE /api/users/:id — delete user */
  delete: http.delete('/api/users/:id', async ({ params }) => {
    await delay(200);
    const idx = mockUsers.findIndex((u) => u.id === Number(params.id));
    if (idx === -1) {
      return HttpResponse.json(
        { error: 'Not Found', message: `User ${params.id} not found`, statusCode: 404 },
        { status: 404 }
      );
    }
    mockUsers.splice(idx, 1);
    return new HttpResponse(null, { status: 204 });
  }),
};

/** All CRUD handlers as an array — use in story parameters */
export const allUserHandlers = Object.values(userHandlers);

// ============================================================
// Authentication Handlers
// ============================================================

export const authHandlers = {
  /** POST /api/auth/login — login */
  login: http.post('/api/auth/login', async ({ request }) => {
    await delay(500);
    const body = (await request.json()) as { email: string; password: string };

    if (body.email === 'admin@example.com' && body.password === 'password') {
      return HttpResponse.json({
        token: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.mock-token',
        user: mockUsers[0],
        expiresIn: 3600,
      });
    }

    return HttpResponse.json(
      { error: 'Unauthorized', message: 'Invalid email or password', statusCode: 401 },
      { status: 401 }
    );
  }),

  /** POST /api/auth/register — register */
  register: http.post('/api/auth/register', async ({ request }) => {
    await delay(600);
    const body = (await request.json()) as { name: string; email: string; password: string };

    // Check duplicate email
    if (mockUsers.some((u) => u.email === body.email)) {
      return HttpResponse.json(
        { error: 'Conflict', message: 'Email already registered', statusCode: 409 },
        { status: 409 }
      );
    }

    const newUser: User = {
      id: nextId++,
      name: body.name,
      email: body.email,
      role: 'viewer',
      createdAt: new Date().toISOString(),
    };
    return HttpResponse.json(
      { token: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.new-user', user: newUser },
      { status: 201 }
    );
  }),

  /** POST /api/auth/logout — logout */
  logout: http.post('/api/auth/logout', async () => {
    await delay(100);
    return new HttpResponse(null, { status: 204 });
  }),

  /** GET /api/auth/me — current user */
  me: http.get('/api/auth/me', async ({ request }) => {
    await delay(150);
    const authHeader = request.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return HttpResponse.json(
        { error: 'Unauthorized', message: 'Missing or invalid token', statusCode: 401 },
        { status: 401 }
      );
    }
    return HttpResponse.json(mockUsers[0]);
  }),

  /** POST /api/auth/refresh — refresh token */
  refresh: http.post('/api/auth/refresh', async () => {
    await delay(200);
    return HttpResponse.json({
      token: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.refreshed-token',
      expiresIn: 3600,
    });
  }),
};

export const allAuthHandlers = Object.values(authHandlers);

// ============================================================
// Pagination Handlers
// ============================================================

export const paginationHandlers = {
  /** GET /api/items?page=1&pageSize=10 — paginated list */
  list: http.get('/api/items', async ({ request }) => {
    await delay(300);
    const url = new URL(request.url);
    const page = Number(url.searchParams.get('page') || '1');
    const pageSize = Number(url.searchParams.get('pageSize') || '10');
    const search = url.searchParams.get('search') || '';
    const sortBy = url.searchParams.get('sortBy') || 'name';
    const order = url.searchParams.get('order') || 'asc';

    // Generate mock items
    const allItems = Array.from({ length: 73 }, (_, i) => ({
      id: i + 1,
      name: `Item ${i + 1}`,
      category: ['Electronics', 'Books', 'Clothing', 'Food'][i % 4],
      price: Math.round((Math.random() * 100 + 1) * 100) / 100,
      inStock: i % 3 !== 0,
    }));

    // Filter
    let filtered = search
      ? allItems.filter((item) =>
          item.name.toLowerCase().includes(search.toLowerCase())
        )
      : allItems;

    // Sort
    filtered = [...filtered].sort((a, b) => {
      const aVal = a[sortBy as keyof typeof a];
      const bVal = b[sortBy as keyof typeof b];
      const cmp = aVal < bVal ? -1 : aVal > bVal ? 1 : 0;
      return order === 'desc' ? -cmp : cmp;
    });

    // Paginate
    const total = filtered.length;
    const totalPages = Math.ceil(total / pageSize);
    const start = (page - 1) * pageSize;
    const data = filtered.slice(start, start + pageSize);

    const response: PaginatedResponse<(typeof allItems)[0]> = {
      data,
      total,
      page,
      pageSize,
      totalPages,
    };
    return HttpResponse.json(response);
  }),

  /** Cursor-based pagination — GET /api/feed?cursor=xyz&limit=20 */
  cursor: http.get('/api/feed', async ({ request }) => {
    await delay(250);
    const url = new URL(request.url);
    const cursor = url.searchParams.get('cursor');
    const limit = Number(url.searchParams.get('limit') || '20');

    const allPosts = Array.from({ length: 100 }, (_, i) => ({
      id: `post-${i + 1}`,
      title: `Post ${i + 1}`,
      body: `Content for post ${i + 1}`,
      createdAt: new Date(2024, 0, 100 - i).toISOString(),
    }));

    const startIdx = cursor
      ? allPosts.findIndex((p) => p.id === cursor) + 1
      : 0;
    const items = allPosts.slice(startIdx, startIdx + limit);
    const nextCursor = items.length === limit ? items[items.length - 1].id : null;

    return HttpResponse.json({
      items,
      nextCursor,
      hasMore: nextCursor !== null,
    });
  }),
};

// ============================================================
// Error State Handlers
// ============================================================

export const errorHandlers = {
  /** Server error (500) */
  serverError: http.get('/api/users', () => {
    return HttpResponse.json(
      { error: 'Internal Server Error', message: 'Something went wrong', statusCode: 500 },
      { status: 500 }
    );
  }),

  /** Network timeout */
  timeout: http.get('/api/users', async () => {
    await delay(30000); // 30s — triggers timeout in most clients
    return HttpResponse.json(mockUsers);
  }),

  /** Rate limited (429) */
  rateLimited: http.get('/api/users', () => {
    return HttpResponse.json(
      { error: 'Too Many Requests', message: 'Rate limit exceeded. Try again in 60s.', statusCode: 429 },
      { status: 429, headers: { 'Retry-After': '60' } }
    );
  }),

  /** Validation error (422) */
  validationError: http.post('/api/users', () => {
    return HttpResponse.json(
      {
        error: 'Validation Error',
        message: 'Invalid input',
        statusCode: 422,
        details: [
          { field: 'email', message: 'Invalid email format' },
          { field: 'name', message: 'Name must be at least 2 characters' },
        ],
      },
      { status: 422 }
    );
  }),

  /** Forbidden (403) */
  forbidden: http.delete('/api/users/:id', () => {
    return HttpResponse.json(
      { error: 'Forbidden', message: 'You do not have permission to delete users', statusCode: 403 },
      { status: 403 }
    );
  }),

  /** Empty response */
  empty: http.get('/api/users', () => {
    return HttpResponse.json([]);
  }),
};

// ============================================================
// Usage in Stories
// ============================================================

/*
// Basic CRUD story:
export const WithUsers: Story = {
  parameters: {
    msw: { handlers: allUserHandlers },
  },
};

// Error state:
export const ServerError: Story = {
  parameters: {
    msw: { handlers: [errorHandlers.serverError] },
  },
};

// Authenticated view:
export const LoggedIn: Story = {
  parameters: {
    msw: { handlers: [...allAuthHandlers, ...allUserHandlers] },
  },
};

// Paginated list:
export const PaginatedList: Story = {
  parameters: {
    msw: { handlers: [paginationHandlers.list] },
  },
};

// Loading state (slow response):
export const Loading: Story = {
  parameters: {
    msw: {
      handlers: [
        http.get('/api/users', async () => {
          await delay(5000);
          return HttpResponse.json(mockUsers);
        }),
      ],
    },
  },
};
*/
