// Fresh route handler with island component template
//
// Usage: Copy to routes/<name>.tsx in a Fresh project.
// The handler fetches data server-side, and the page renders
// with an interactive island component.

import { Handlers, PageProps } from "$fresh/server.ts";
import { Head } from "$fresh/runtime.ts";
import InteractiveWidget from "../islands/InteractiveWidget.tsx";

// Type for the page data (fetched server-side)
interface PageData {
  title: string;
  items: Array<{ id: string; name: string; value: number }>;
  lastUpdated: string;
}

// Server-side handler — runs on every request
export const handler: Handlers<PageData> = {
  async GET(req: Request, ctx) {
    // Access URL params for dynamic routes: ctx.params.slug
    // Access middleware state: ctx.state.user
    const url = new URL(req.url);
    const page = Number(url.searchParams.get("page") ?? "1");

    try {
      // Fetch data server-side (DB, API, KV, etc.)
      const kv = await Deno.openKv();
      const items: PageData["items"] = [];

      for await (const entry of kv.list({ prefix: ["items"] })) {
        items.push(entry.value as PageData["items"][0]);
      }

      return ctx.render({
        title: "Dashboard",
        items,
        lastUpdated: new Date().toISOString(),
      });
    } catch (error) {
      console.error("Failed to load data:", error);
      return new Response("Internal Server Error", { status: 500 });
    }
  },

  async POST(req: Request, ctx) {
    const form = await req.formData();
    const name = form.get("name")?.toString();

    if (!name) {
      return new Response("Name is required", { status: 400 });
    }

    const kv = await Deno.openKv();
    const id = crypto.randomUUID();
    await kv.set(["items", id], { id, name, value: 0 });

    // Redirect back to the page (POST-Redirect-GET pattern)
    return new Response(null, {
      status: 303,
      headers: { Location: req.url },
    });
  },
};

// Page component — server-rendered HTML
export default function DashboardPage({ data }: PageProps<PageData>) {
  return (
    <>
      <Head>
        <title>{data.title}</title>
        <meta name="description" content="Dashboard with interactive widgets" />
      </Head>

      <div class="page">
        <header>
          <h1>{data.title}</h1>
          <p>Last updated: {data.lastUpdated}</p>
        </header>

        {/* Static content — zero JS shipped */}
        <section>
          <h2>Items ({data.items.length})</h2>
          <ul>
            {data.items.map((item) => (
              <li key={item.id}>
                {item.name}: {item.value}
              </li>
            ))}
          </ul>
        </section>

        {/* Island — hydrated on the client with interactivity */}
        <section>
          <h2>Interactive Controls</h2>
          <InteractiveWidget items={data.items} />
        </section>

        {/* Standard HTML form — no JS needed */}
        <section>
          <h2>Add Item</h2>
          <form method="POST">
            <input type="text" name="name" placeholder="Item name" required />
            <button type="submit">Add</button>
          </form>
        </section>
      </div>
    </>
  );
}

// ─── Island Component (save as islands/InteractiveWidget.tsx) ────────────
//
// import { useSignal } from "@preact/signals";
//
// interface Props {
//   items: Array<{ id: string; name: string; value: number }>;
// }
//
// export default function InteractiveWidget({ items }: Props) {
//   const selected = useSignal<string | null>(null);
//   const filter = useSignal("");
//
//   const filtered = items.filter((item) =>
//     item.name.toLowerCase().includes(filter.value.toLowerCase())
//   );
//
//   return (
//     <div>
//       <input
//         type="text"
//         placeholder="Filter items..."
//         value={filter}
//         onInput={(e) => filter.value = (e.target as HTMLInputElement).value}
//       />
//       <ul>
//         {filtered.map((item) => (
//           <li
//             key={item.id}
//             onClick={() => selected.value = item.id}
//             style={{ fontWeight: selected.value === item.id ? "bold" : "normal" }}
//           >
//             {item.name} ({item.value})
//           </li>
//         ))}
//       </ul>
//       {selected.value && <p>Selected: {selected.value}</p>}
//     </div>
//   );
// }
