/// <reference no-default-lib="true" />
/// <reference lib="dom" />
/// <reference lib="dom.iterable" />
/// <reference lib="dom.asynciterable" />
/// <reference lib="deno.ns" />

/**
 * Fresh App Template
 *
 * Run:   deno task dev
 * Build: deno task build
 * Start: deno task start
 */

import { App, fsRoutes, staticFiles } from "fresh";

const app = new App();

app.use(staticFiles());
await fsRoutes(app, {
  dir: "./",
  loadIsland: (path) => import(`./islands/${path}`),
  loadRoute: (path) => import(`./routes/${path}`),
});

if (import.meta.main) {
  await app.listen();
}
