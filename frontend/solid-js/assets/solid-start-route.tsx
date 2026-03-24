// solid-start-route.tsx — SolidStart route with data loading, error handling, and SEO.
//
// Place in src/routes/ for file-based routing (e.g., src/routes/users/[id].tsx → /users/:id).
// Includes: createAsync, cache, Suspense, ErrorBoundary, Meta.

import { Show, Suspense, ErrorBoundary } from "solid-js";
import { useParams, createAsync, cache, A } from "@solidjs/router";
import { Title, Meta } from "@solidjs/meta";

// -- Types --
interface User {
  id: string;
  name: string;
  email: string;
  bio: string;
}

// -- Data loading --
// cache() deduplicates requests by key across components and navigations
const getUser = cache(async (id: string): Promise<User> => {
  "use server"; // Runs on server only — safe for DB/API calls
  const res = await fetch(`https://api.example.com/users/${id}`);
  if (!res.ok) throw new Error(`User not found (${res.status})`);
  return res.json();
}, "user");

// Preload hint: triggers fetch on link hover
export const route = {
  preload: ({ params }: { params: { id: string } }) => getUser(params.id),
};

// -- Route component --
export default function UserPage() {
  const params = useParams<{ id: string }>();
  const user = createAsync(() => getUser(params.id));

  return (
    <main>
      <A href="/">← Back to home</A>

      <ErrorBoundary
        fallback={(err, reset) => (
          <div>
            <h2>Something went wrong</h2>
            <p>{err.message}</p>
            <button onClick={reset}>Try again</button>
          </div>
        )}
      >
        <Suspense fallback={<div class="skeleton">Loading user...</div>}>
          <Show when={user()}>
            {(u) => (
              <>
                {/* SEO meta tags */}
                <Title>{u().name} — Profile</Title>
                <Meta name="description" content={u().bio} />

                <article>
                  <h1>{u().name}</h1>
                  <p>{u().email}</p>
                  <p>{u().bio}</p>
                </article>
              </>
            )}
          </Show>
        </Suspense>
      </ErrorBoundary>
    </main>
  );
}
