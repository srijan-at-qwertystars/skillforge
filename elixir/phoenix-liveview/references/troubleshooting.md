# Phoenix LiveView Troubleshooting Guide

## Table of Contents

- [Why Does My LiveView Re-Render Everything?](#why-does-my-liveview-re-render-everything)
- [Stale Socket State](#stale-socket-state)
- [Memory Leaks from Streams](#memory-leaks-from-streams)
- [File Upload Failures](#file-upload-failures)
- [JS Hook Lifecycle Issues](#js-hook-lifecycle-issues)
- [WebSocket Disconnection Handling](#websocket-disconnection-handling)
- [Debugging with :observer](#debugging-with-observer)
- [Performance Profiling](#performance-profiling)
- [Common Ecto Changeset Errors in LiveView Forms](#common-ecto-changeset-errors-in-liveview-forms)
- [Miscellaneous Gotchas](#miscellaneous-gotchas)

---

## Why Does My LiveView Re-Render Everything?

### Symptom
The entire page flickers or re-renders on every event, even when only a small piece of data changed.

### Causes and Fixes

**1. Large assign that changes reference on every update**

```elixir
# BAD: Rebuilding entire list on every event — all list markup re-renders
def handle_event("toggle", %{"id" => id}, socket) do
  items = Enum.map(socket.assigns.items, fn
    %{id: ^id} = item -> %{item | active: !item.active}
    item -> item
  end)
  {:noreply, assign(socket, :items, items)}
end

# GOOD: Use streams — only the changed item's DOM updates
def handle_event("toggle", %{"id" => id}, socket) do
  item = MyApp.Items.get_item!(id)
  updated = MyApp.Items.toggle_active!(item)
  {:noreply, stream_insert(socket, :items, updated)}
end
```

**2. Computing values inside the template**

```elixir
# BAD: Recomputed every render, forces full diff
~H"""
<%= Enum.count(Enum.filter(@items, & &1.active)) %> active items
"""

# GOOD: Precompute in the callback, assign a simple value
def handle_event("toggle", params, socket) do
  # ... update items ...
  {:noreply, assign(socket, :active_count, count_active(items))}
end
```

**3. Missing key on comprehension**

HEEx tracks list items by position without unique IDs. Add `id` attributes:

```heex
<%!-- BAD: No id, entire list re-renders --%>
<div :for={item <- @items}><%= item.name %></div>

<%!-- GOOD: Unique id enables surgical updates --%>
<div :for={item <- @items} id={"item-#{item.id}"}><%= item.name %></div>
```

**4. Assigning non-serializable or opaque data**

Maps/structs with identical content but different references cause false diffs. Use `assign_new/3` for data that shouldn't change.

### Diagnosing

Enable the LiveView debug tools in `config/dev.exs`:

```elixir
config :phoenix_live_view,
  debug_heex_annotations: true
```

In the browser, open DevTools → Network → WS tab. Inspect the `phx_reply` frames. Large `diff` payloads indicate unnecessary re-renders.

---

## Stale Socket State

### Symptom
UI shows outdated data, events operate on old state, or edits from other users don't appear.

### Causes and Fixes

**1. Not subscribing to PubSub**

```elixir
# Ensure subscription in mount (connected only)
def mount(_params, _session, socket) do
  if connected?(socket), do: Phoenix.PubSub.subscribe(MyApp.PubSub, "items")
  {:ok, stream(socket, :items, MyApp.Items.list_items())}
end
```

**2. Subscribing to wrong topic or forgetting to broadcast**

Verify topic strings match exactly between publisher and subscriber.

**3. Stale data after live_patch**

`live_patch` does NOT re-run `mount/3`. It only calls `handle_params/3`. Reload data there:

```elixir
def handle_params(%{"id" => id}, _uri, socket) do
  item = MyApp.Items.get_item!(id)
  {:noreply, assign(socket, :item, item)}
end
```

**4. Holding references to deleted records**

After a stream_delete, verify the record still exists before operating on it:

```elixir
def handle_event("edit", %{"id" => id}, socket) do
  case MyApp.Items.get_item(id) do
    nil -> {:noreply, put_flash(socket, :error, "Item no longer exists")}
    item -> {:noreply, assign(socket, :editing, item)}
  end
end
```

**5. Race between mount phases**

Remember `mount/3` runs twice: disconnected (for SEO/initial HTML) and connected (WebSocket). If you fetch data only in the connected phase, the initial render is empty:

```elixir
def mount(_params, _session, socket) do
  # Always load data for both phases
  items = MyApp.Items.list_items()
  socket = stream(socket, :items, items)

  # Subscribe only when connected
  if connected?(socket), do: MyApp.Items.subscribe()
  {:ok, socket}
end
```

---

## Memory Leaks from Streams

### Symptom
Memory usage grows over time despite using streams. Node eventually becomes unresponsive.

### Causes and Fixes

**1. Accidentally storing stream data in regular assigns too**

```elixir
# BAD: Duplicating data — streams + regular assign
def mount(_params, _session, socket) do
  items = MyApp.Items.list_items()
  {:ok,
   socket
   |> assign(:items, items)            # ← data stored in process memory
   |> stream(:items, items)}            # ← streams track only DOM IDs
end

# GOOD: Only use streams, don't also assign the list
def mount(_params, _session, socket) do
  {:ok, stream(socket, :items, MyApp.Items.list_items())}
end
```

**2. Never resetting streams on filter/search**

Without `reset: true`, stream entries accumulate forever:

```elixir
# BAD: Old items stay in the DOM
def handle_event("search", %{"q" => q}, socket) do
  {:noreply, stream(socket, :items, MyApp.Items.search(q))}
end

# GOOD: Reset clears previous entries
def handle_event("search", %{"q" => q}, socket) do
  {:noreply, stream(socket, :items, MyApp.Items.search(q), reset: true)}
end
```

**3. Unbounded stream growth (infinite scroll without cleanup)**

For chat-like UIs, limit the number of items in the DOM:

```elixir
def handle_info({:new_message, msg}, socket) do
  socket =
    socket
    |> stream_insert(:messages, msg, at: -1, limit: -200)  # keep last 200
  {:noreply, socket}
end
```

**4. Process accumulation**

Each LiveView is a process. If users open many tabs, processes multiply. Monitor with:

```elixir
# In IEx
:erlang.system_info(:process_count)
Process.list() |> Enum.filter(fn pid ->
  case Process.info(pid, :dictionary) do
    {:dictionary, dict} -> Keyword.has_key?(dict, :phoenix_live_view)
    _ -> false
  end
end) |> length()
```

---

## File Upload Failures

### Symptom
Uploads fail silently, timeout, or produce corrupt files.

### Common Issues

**1. File size exceeds limit**

```elixir
# Default max is 8MB. Increase if needed:
allow_upload(:document, accept: ~w(.pdf .docx), max_file_size: 50_000_000)  # 50MB
```

**2. Missing `multipart: true` on form (non-LiveView form)**

LiveView forms handle this automatically via `<.live_file_input>`, but if mixing with dead views, ensure the form tag has `enctype="multipart/form-data"`.

**3. Endpoint body reader config too small**

```elixir
# config/config.exs — increase for large uploads
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  length: 100_000_000,  # 100MB max body
  json_decoder: Phoenix.json_library()
```

**4. Forgetting to consume uploads**

If you don't call `consume_uploaded_entries/3`, temp files are cleaned up without processing:

```elixir
def handle_event("save", _params, socket) do
  # MUST consume — otherwise the upload temp files are garbage collected
  uploaded_files =
    consume_uploaded_entries(socket, :photos, fn %{path: path}, entry ->
      dest = Path.join(upload_dir(), "#{entry.uuid}-#{entry.client_name}")
      File.cp!(path, dest)
      {:ok, dest}
    end)

  {:noreply, assign(socket, :uploaded_files, uploaded_files)}
end
```

**5. Upload directory doesn't exist or lacks permissions**

```elixir
# Ensure directory exists in application startup
File.mkdir_p!("priv/static/uploads")
```

**6. Reverse proxy dropping connection**

Nginx default `client_max_body_size` is 1MB. Increase:

```nginx
location / {
  client_max_body_size 100M;
  proxy_read_timeout 300s;
}
```

**7. External upload presigned URL expiration**

When using S3 direct uploads, ensure the presigned URL TTL is long enough for slow connections:

```elixir
allow_upload(:avatar,
  accept: ~w(.jpg .png),
  max_entries: 1,
  external: &presign_upload/2
)

defp presign_upload(entry, socket) do
  config = %{
    region: "us-east-1",
    bucket: "my-bucket",
    expires_in: 3600  # 1 hour, not the default 300s
  }
  # ... generate presigned URL
end
```

---

## JS Hook Lifecycle Issues

### Symptom
Hook callbacks don't fire, fire at wrong times, or `this.el` is stale/null.

### Common Issues

**1. Missing `id` on the hooked element**

Every element with `phx-hook` MUST have a unique, stable `id`:

```heex
<%!-- BAD: No id — hook won't work --%>
<div phx-hook="Chart"></div>

<%!-- GOOD --%>
<div id="sales-chart" phx-hook="Chart"></div>
```

**2. `updated()` not called when expected**

`updated()` fires only when the hooked element's attributes or inner HTML change. If you change an assign that doesn't affect the hooked element's rendered output, `updated()` won't fire.

Fix: include a data attribute that changes:

```heex
<div id="chart" phx-hook="Chart" data-version={@chart_version}>
  <%!-- chart renders here --%>
</div>
```

**3. `mounted()` fires before DOM is ready**

The element exists but siblings or children may not be fully rendered. Use `requestAnimationFrame`:

```javascript
Hooks.Chart = {
  mounted() {
    requestAnimationFrame(() => {
      this.initChart()
    })
  }
}
```

**4. Memory leaks in hooks — not cleaning up in `destroyed()`**

```javascript
// BAD: Event listeners leak
Hooks.Tracker = {
  mounted() {
    window.addEventListener("resize", this.handleResize)
  }
  // Missing destroyed() — listener persists forever
}

// GOOD: Clean up
Hooks.Tracker = {
  mounted() {
    this.handleResize = () => { /* ... */ }
    window.addEventListener("resize", this.handleResize)
  },
  destroyed() {
    window.removeEventListener("resize", this.handleResize)
  }
}
```

**5. `handleEvent` not receiving server pushes**

Ensure you register before pushing:

```javascript
Hooks.Notifier = {
  mounted() {
    // Register FIRST
    this.handleEvent("show-notification", ({ message }) => {
      alert(message)
    })
  }
}
```

```elixir
# Server-side push
push_event(socket, "show-notification", %{message: "Done!"})
```

**6. Hook not found error**

Ensure the hook is registered in the LiveSocket constructor:

```javascript
import { Hooks } from "./hooks"  // your hooks file
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,  // ← must be passed here
  params: { _csrf_token: csrfToken }
})
```

---

## WebSocket Disconnection Handling

### Symptom
LiveView shows "disconnected" banner, events stop working, or the page becomes unresponsive.

### Diagnosing

```javascript
// In browser console
window.liveSocket.enableDebug()
// Shows connect, disconnect, join, rejoin events
```

### Common Causes

**1. Idle timeout in reverse proxy**

Nginx default proxy timeout is 60s. LiveView sends heartbeats every 30s by default:

```nginx
location /live {
  proxy_pass http://app:4000;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_read_timeout 120s;     # must exceed heartbeat interval
  proxy_send_timeout 120s;
}
```

**2. Load balancer not supporting WebSocket upgrade**

Ensure your ALB/NLB/HAProxy forwards the `Upgrade: websocket` header.

**3. Server-side crash in LiveView process**

Check server logs for crash reports. A crash in `handle_event` or `handle_info` kills the process. Add rescue clauses for non-critical operations:

```elixir
def handle_info({:external_update, data}, socket) do
  try do
    processed = process_external_data(data)
    {:noreply, assign(socket, :external, processed)}
  rescue
    e ->
      Logger.error("External update failed: #{inspect(e)}")
      {:noreply, socket}
  end
end
```

**4. Client-side reconnection tuning**

```javascript
let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  // Reconnect settings
  reconnectAfterMs: (tries) => [1000, 2000, 5000, 10000][tries - 1] || 10000
})
```

**5. Long-poll fallback not configured**

If WebSocket is blocked (corporate firewalls), ensure long-poll works:

```elixir
# endpoint.ex
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]],
  longpoll: [connect_info: [session: @session_options]]  # ← add this
```

### Graceful Reconnection Patterns

Handle state recovery after reconnection in `mount/3`:

```elixir
def mount(params, session, socket) do
  # mount/3 re-runs on reconnect — ensure it's idempotent
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "updates")
    # Restore transient state from session or database, not assigns
  end

  {:ok,
   socket
   |> assign(:items, MyApp.Items.list())
   |> assign(:last_connected, DateTime.utc_now())}
end
```

---

## Debugging with :observer

### Starting Observer

```elixir
# In IEx (development)
:observer.start()

# Remote node
Node.connect(:"myapp@hostname")
:observer.start()
```

### What to Look For

**Processes tab:**
- Sort by **Message Queue** — large queues indicate a bottleneck.
- Sort by **Memory** — find LiveView processes using excessive memory.
- LiveView processes have `Phoenix.LiveView.Channel` in their initial call.

**Applications tab:**
- Expand your app → supervision tree → find stuck or crashed processes.

**System tab:**
- Monitor total process count (each LiveView = 1 process).
- Watch memory: binary, ETS, process.

### Using LiveDashboard (Production)

```elixir
# router.ex
import Phoenix.LiveDashboard.Router

scope "/" do
  pipe_through [:browser, :admin_auth]
  live_dashboard "/dashboard",
    metrics: MyAppWeb.Telemetry,
    ecto_repos: [MyApp.Repo]
end
```

### Telemetry for LiveView

```elixir
# lib/my_app_web/telemetry.ex
defmodule MyAppWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def metrics do
    [
      summary("phoenix.live_view.mount.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.live_view.handle_event.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.live_view.handle_params.stop.duration", unit: {:native, :millisecond}),
      counter("phoenix.live_view.mount.stop.duration"),
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total")
    ]
  end
end
```

---

## Performance Profiling

### Identifying Slow Callbacks

```elixir
# Wrap suspect callbacks with timing
def handle_event("search", params, socket) do
  {time_us, result} = :timer.tc(fn ->
    MyApp.Search.execute(params)
  end)

  Logger.info("Search took #{time_us / 1000}ms")
  {:noreply, assign(socket, :results, result)}
end
```

### Profiling with :fprof

```elixir
# Profile a specific function
:fprof.apply(&MyApp.HeavyModule.slow_function/1, [args])
:fprof.profile()
:fprof.analyse(sort: :own)
```

### Common Performance Issues

| Issue | Symptom | Fix |
|-------|---------|-----|
| N+1 queries in mount | Slow initial load | Use `Repo.preload/2` or `from(... preload: [...])` |
| Recomputing in render | Every render is slow | Precompute in callbacks, assign results |
| Large assigns | High memory per process | Use streams, temporary_assigns, or assign_async |
| Unindexed DB queries | Slow handle_event | Add database indexes, check with `EXPLAIN` |
| Blocking mount | Page hangs until data loads | Use `assign_async` or `start_async` |
| Too many PubSub messages | CPU spike on broadcasts | Throttle broadcasts, use topic segmentation |

### Reducing Diff Size

```elixir
# Extract static parts into function components
# LiveView tracks changes per component — static components produce zero diffs

# BAD: All inline, entire block re-diffs
~H"""
<div class="card">
  <div class="header"><h2>Dashboard</h2><p>Admin panel</p></div>
  <div class="body"><%= @content %></div>
</div>
"""

# GOOD: Static wrapper is never diffed
attr :content, :string, required: true
def card(assigns) do
  ~H"""
  <div class="card">
    <div class="header"><h2>Dashboard</h2><p>Admin panel</p></div>
    <div class="body"><%= @content %></div>
  </div>
  """
end
```

---

## Common Ecto Changeset Errors in LiveView Forms

### "can't be blank" Not Showing

```elixir
# Ensure :action is set on the changeset for validation display
def handle_event("validate", %{"user" => params}, socket) do
  changeset =
    %User{}
    |> User.changeset(params)
    |> Map.put(:action, :validate)  # ← required for errors to display

  {:noreply, assign_form(socket, changeset)}
end
```

### Form Shows Stale Errors After Successful Save

```elixir
# Reset the form after success
def handle_event("save", %{"item" => params}, socket) do
  case Items.create_item(params) do
    {:ok, _item} ->
      fresh_changeset = Items.change_item(%Item{})
      {:noreply,
       socket
       |> put_flash(:info, "Created!")
       |> assign_form(fresh_changeset)}

    {:error, changeset} ->
      {:noreply, assign_form(socket, changeset)}
  end
end
```

### Association/Embed Changeset Errors Not Displaying

Nested errors require `inputs_for`:

```heex
<.simple_form for={@form} phx-submit="save">
  <.input field={@form[:name]} label="Name" />

  <.inputs_for :let={address_form} field={@form[:address]}>
    <.input field={address_form[:street]} label="Street" />
    <.input field={address_form[:city]} label="City" />
  </.inputs_for>
</.simple_form>
```

```elixir
# Schema must use cast_assoc or cast_embed
def changeset(user, attrs) do
  user
  |> cast(attrs, [:name])
  |> cast_embed(:address, with: &address_changeset/2)
end
```

### Unique Constraint Errors Not Rendering

Database constraints only trigger after `Repo.insert/update`. Map them in the changeset:

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email])
  |> validate_required([:email])
  |> unique_constraint(:email, message: "is already registered")
  # ← unique_constraint converts DB error to changeset error
end
```

### Changeset Errors with Streams

When using streams with forms (e.g., inline editing), each stream item's form needs isolation:

```elixir
def handle_event("validate-item-" <> id, %{"item" => params}, socket) do
  item = MyApp.Items.get_item!(id)
  changeset = Items.change_item(item, params) |> Map.put(:action, :validate)
  {:noreply, stream_insert(socket, :items, Map.put(item, :form, to_form(changeset)))}
end
```

---

## Miscellaneous Gotchas

### Flash Messages Disappearing Immediately

Flash messages auto-clear on the next `live_redirect` or `live_patch`. Use `put_flash` just before navigation, or use `Phoenix.LiveView.JS.show` for persistent notifications.

### `push_navigate` vs `push_patch` vs `redirect`

| Function | Effect |
|----------|--------|
| `push_patch/2` | Same LiveView, triggers `handle_params/3` only |
| `push_navigate/2` | New LiveView, full mount cycle |
| `redirect/2` | Full page load (dead view or external URL) |

### Assigns Not Available in `render/1`

If you see `key :foo not found in assigns`, ensure every code path in `mount/3` and `handle_params/3` sets the assign. Use `assign_new/3` for defaults:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign_new(:items, fn -> [] end)
   |> assign_new(:loading, fn -> false end)}
end
```

### Testing Shows Different Behavior Than Browser

LiveView tests skip the disconnected render by default. To test both phases:

```elixir
test "static render shows loading state", %{conn: conn} do
  conn = get(conn, ~p"/items")
  assert html_response(conn, 200) =~ "Loading..."
end

test "connected render shows items", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/items")
  assert html =~ "Item 1"
end
```
