---
name: phoenix-liveview
description: >
  Expert guide for building real-time, server-rendered web interfaces with Phoenix LiveView (1.0+) in Elixir.
  TRIGGER when: code uses Phoenix.LiveView, Phoenix.LiveComponent, Phoenix.Component, ~H sigil, HEEx templates,
  phx-click/phx-submit/phx-change bindings, LiveView lifecycle callbacks (mount, handle_event, handle_info,
  handle_params), LiveView Streams, live_file_input, PubSub with LiveView, Presence channels, JS hooks with
  phx-hook, or user asks about real-time Elixir web UI, server-rendered interactivity, or Phoenix LiveView
  patterns. Keywords: LiveView, Phoenix, Elixir, real-time, server-rendered, HEEx, LiveComponent, Streams,
  PubSub, uploads, hooks.
  DO NOT TRIGGER when: code uses plain Phoenix controllers without LiveView, Absinthe/GraphQL,
  Phoenix Channels without LiveView, Nerves/embedded Elixir, pure Ecto/database queries unrelated to LiveView,
  or non-Elixir frameworks (React, Rails, Django).
---

# Phoenix LiveView

Phoenix LiveView enables rich, real-time UIs with server-rendered HTML over WebSockets. State lives on the server in an Elixir process. Only minimal diffs are sent to the client. Current stable: v1.1.x (requires Phoenix 1.7+, Elixir 1.14+).

Use LiveView when: real-time updates needed, form-heavy CRUD, dashboards, collaborative features, chat, notifications, search-as-you-type. Avoid when: offline-first apps, heavy client-side computation, or static content pages.

## LiveView Lifecycle

Every LiveView is a GenServer process. Understand the callback order:

1. `mount/3` — initialize assigns. Called twice: once for static HTTP render (disconnected), once on WebSocket connect (connected).
2. `handle_params/3` — called after mount and on every live navigation (`live_patch`). Use for URL-driven state.
3. `render/1` — return HEEx template. Called after any assign change.
4. `handle_event/3` — respond to client events (`phx-click`, `phx-submit`, etc.).
5. `handle_info/2` — respond to Erlang/Elixir messages (PubSub, Process.send_after, etc.).
6. `terminate/2` — cleanup on disconnect (rarely needed).

```elixir
defmodule MyAppWeb.ItemLive.Index do
  use MyAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: MyApp.Items.subscribe()
    {:ok, stream(socket, :items, MyApp.Items.list_items())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, :page_title, "Items")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    assign(socket, :page_title, "Edit Item")
    |> assign(:item, MyApp.Items.get_item!(id))
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    item = MyApp.Items.get_item!(id)
    {:ok, _} = MyApp.Items.delete_item(item)
    {:noreply, stream_delete(socket, :items, item)}
  end

  @impl true
  def handle_info({:item_created, item}, socket) do
    {:noreply, stream_insert(socket, :items, item, at: 0)}
  end
end
```

Guard `connected?(socket)` for subscriptions and timers in `mount/3` — these must not fire during the static render pass.

## HEEx Templates

Use `~H` sigil or `.heex` files. Prefer function components over LiveComponents when no local state is needed.

```elixir
# Function component — stateless, fast
attr :status, :atom, required: true
def badge(assigns) do
  ~H"""
  <span class={"badge badge-#{@status}"}><%= @status %></span>
  """
end

# Usage in template
<.badge status={:active} />
```

Use `<.link navigate={~p"/items/#{@item}"}>` for live navigation (full mount). Use `<.link patch={~p"/items?page=2"}>` for same-LiveView URL changes (triggers `handle_params` only).

## LiveComponent Patterns

Use `Phoenix.LiveComponent` when a UI section needs its own state or event handling scope.

**Stateful LiveComponent** — has its own `id`, maintains assigns across renders:

```elixir
defmodule MyAppWeb.ItemLive.FormComponent do
  use MyAppWeb, :live_component

  @impl true
  def update(%{item: item} = assigns, socket) do
    changeset = MyApp.Items.change_item(item)
    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"item" => params}, socket) do
    changeset =
      socket.assigns.item
      |> MyApp.Items.change_item(params)
      |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  @impl true
  def handle_event("save", %{"item" => params}, socket) do
    case MyApp.Items.create_item(params) do
      {:ok, item} ->
        notify_parent({:saved, item})
        {:noreply,
         socket
         |> put_flash(:info, "Item created")
         |> push_navigate(to: socket.assigns.navigate)}
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
```

Render with: `<.live_component module={MyAppWeb.ItemLive.FormComponent} id={@item.id || :new} item={@item} navigate={~p"/items"} />`

**Stateless components** — use function components instead. LiveComponents have overhead from their own process lifecycle.

## Form Handling with Changesets

Always back forms with `to_form/1` wrapping an Ecto changeset. Use `phx-change` for live validation, `phx-submit` for submission.

```heex
<.simple_form for={@form} id="item-form" phx-change="validate" phx-submit="save" phx-target={@myself}>
  <.input field={@form[:name]} type="text" label="Name" />
  <.input field={@form[:description]} type="textarea" label="Description" />
  <:actions>
    <.button phx-disable-with="Saving...">Save</.button>
  </:actions>
</.simple_form>
```

Key rules:
- Set `changeset.action = :validate` on change events to show errors without prematurely marking fields.
- Use `phx-target={@myself}` inside LiveComponents to scope events.
- Use `phx-disable-with` to prevent double submissions.
- Use `phx-debounce="300"` on text inputs to reduce server round-trips.

## Real-Time Features

### PubSub

Broadcast domain events, subscribe in LiveView `mount/3`:

```elixir
# In context module
def broadcast_item_change({:ok, item}, event) do
  Phoenix.PubSub.broadcast(MyApp.PubSub, "items", {event, item})
  {:ok, item}
end

# In LiveView mount
def mount(_params, _session, socket) do
  if connected?(socket), do: Phoenix.PubSub.subscribe(MyApp.PubSub, "items")
  {:ok, stream(socket, :items, MyApp.Items.list_items())}
end

# Handle broadcasts
def handle_info({:item_updated, item}, socket) do
  {:noreply, stream_insert(socket, :items, item)}
end
```

### Presence

Track connected users with `Phoenix.Presence`. Call `Presence.track/4` in `mount/3` (guarded by `connected?/1`), subscribe to the topic, and handle `presence_diff` events in `handle_info/2` to update the user list assign.

## LiveView Streams

Use streams for large or dynamic collections. Streams do not keep data in server memory — only diffs go to the client.

```elixir
# Initialize
def mount(_params, _session, socket) do
  {:ok, stream(socket, :messages, Chat.list_messages(limit: 50))}
end

# Insert (prepend with at: 0, append with at: -1)
def handle_info({:new_message, msg}, socket) do
  {:noreply, stream_insert(socket, :messages, msg, at: 0)}
end

# Delete
def handle_event("delete_msg", %{"id" => id}, socket) do
  msg = Chat.get_message!(id)
  Chat.delete_message(msg)
  {:noreply, stream_delete(socket, :messages, msg)}
end

# Reset entire stream
def handle_event("filter", %{"q" => query}, socket) do
  {:noreply, stream(socket, :messages, Chat.search(query), reset: true)}
end
```

Template — require `phx-update="stream"` on container and `id` on each item:

```heex
<div id="messages" phx-update="stream">
  <div :for={{dom_id, msg} <- @streams.messages} id={dom_id}>
    <p><strong><%= msg.author %></strong>: <%= msg.body %></p>
  </div>
</div>
```

Batch inserts (no built-in bulk API yet):

```elixir
defp stream_insert_many(socket, name, items, opts \\ []) do
  Enum.reduce(items, socket, fn item, acc ->
    stream_insert(acc, name, item, opts)
  end)
end
```

## File Uploads

Configure in `mount/3` with `allow_upload/3`:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:form, to_form(%{}))
   |> allow_upload(:avatar, accept: ~w(.jpg .jpeg .png), max_entries: 1, max_file_size: 5_000_000)}
end
```

Template:

```heex
<form id="upload-form" phx-submit="save" phx-change="validate">
  <.live_file_input upload={@uploads.avatar} />
  <div :for={entry <- @uploads.avatar.entries}>
    <.live_img_preview entry={entry} width="100" />
    <progress value={entry.progress} max="100"><%= entry.progress %>%</progress>
    <button type="button" phx-click="cancel-upload" phx-value-ref={entry.ref}>&times;</button>
  </div>
  <p :for={err <- upload_errors(@uploads.avatar)} class="error"><%= upload_error_to_string(err) %></p>
  <button type="submit">Upload</button>
</form>
```

Handle submission — `consume_uploaded_entries/3` processes and removes temp files:

```elixir
def handle_event("save", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
      dest = Path.join(["priv/static/uploads", "#{entry.uuid}-#{entry.client_name}"])
      File.cp!(path, dest)
      {:ok, ~p"/uploads/#{Path.basename(dest)}"}
    end)
  {:noreply, update(socket, :uploaded_files, &(&1 ++ uploaded_files))}
end

def handle_event("cancel-upload", %{"ref" => ref}, socket) do
  {:noreply, cancel_upload(socket, :avatar, ref)}
end

def handle_event("validate", _params, socket) do
  {:noreply, socket}
end
```

For direct-to-cloud uploads, use the `external` option in `allow_upload/3` with a presigned URL function.

## JavaScript Hooks

Use `phx-hook` when you need client-side behavior LiveView cannot express.

Register hooks in `app.js`:

```javascript
let Hooks = {
  InfiniteScroll: {
    mounted() {
      this.observer = new IntersectionObserver(entries => {
        if (entries[0].isIntersecting) this.pushEvent("load-more", {});
      });
      this.observer.observe(this.el);
    },
    destroyed() { this.observer.disconnect(); }
  }
};

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks, params: { _csrf_token: csrfToken }
});
```

Template usage: `<div id="scroll-sentinel" phx-hook="InfiniteScroll"></div>`

Hook lifecycle methods: `mounted`, `beforeUpdate`, `updated`, `destroyed`, `disconnected`, `reconnected`.

Available in hooks: `this.el`, `this.pushEvent(event, payload)`, `this.pushEventTo(selector, event, payload)`, `this.handleEvent(event, callback)`.

**Colocated hooks (LiveView 1.1+)** — define JS inline with HEEx:

```heex
<div id="sortable" phx-hook=".Sortable">
  <%= for item <- @items do %>
    <div id={"item-#{item.id}"}><%= item.name %></div>
  <% end %>
</div>

<script :type={Phoenix.LiveView.ColocatedHook} name=".Sortable">
  export default {
    mounted() {
      // Initialize Sortable.js or similar
    }
  }
</script>
```

## JS Commands

Use `Phoenix.LiveView.JS` for client-side operations without server round-trips:

```elixir
alias Phoenix.LiveView.JS

def toggle_menu(js \\ %JS{}) do
  js |> JS.toggle(to: "#mobile-menu") |> JS.toggle_class("rotate-180", to: "#menu-icon")
end
```

```heex
<button phx-click={toggle_menu()}>Menu</button>
<button phx-click={JS.push("delete", value: %{id: @item.id}) |> JS.hide(to: "#modal")}>Confirm</button>
```

JS commands compose. Chain `JS.push/2` when you also need a server event.

## Testing LiveView

Use `Phoenix.LiveViewTest` in ExUnit. Key functions:

```elixir
defmodule MyAppWeb.ItemLiveTest do
  use MyAppWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "Index" do
    setup [:create_item]

    test "lists items", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items")
      assert html =~ item.name
    end

    test "deletes item", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, ~p"/items")
      assert view |> element("#items-#{item.id} a", "Delete") |> render_click() =~ "Item deleted"
      refute has_element?(view, "#items-#{item.id}")
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/items/new")
      assert view |> form("#item-form", item: %{name: ""}) |> render_change() =~ "can&#39;t be blank"
    end

    test "creates item on submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/items/new")
      view |> form("#item-form", item: %{name: "New Item"}) |> render_submit()
      assert_patch(view, ~p"/items")
      assert render(view) =~ "New Item"
    end
  end
end
```

Key test helpers:
- `live/2` — mount LiveView, returns `{:ok, view, html}`
- `render/1` — get current rendered HTML
- `render_click/2` — simulate click event
- `render_change/2` — simulate form change (phx-change)
- `render_submit/2` — simulate form submit (phx-submit)
- `element/3` — target a DOM element by CSS selector
- `form/3` — target a form with values
- `has_element?/3` — assert element exists
- `assert_patch/2` — assert live_patch navigation
- `assert_redirect/2` — assert redirect
- `follow_redirect/3` — follow redirect and return new conn

## Performance Patterns

### Temporary Assigns

For data needed only in the initial render (e.g., large lists before streams existed):

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, :logs, fetch_logs()), temporary_assigns: [logs: []]}
end
```

After first render, `@logs` resets to `[]`, freeing memory. Prefer streams over temporary assigns for new code.

### Async Operations

Use `assign_async/3` and `start_async/3` for non-blocking data loading:

```elixir
# assign_async — declarative, handles loading/error states
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:page_title, "Dashboard")
   |> assign_async(:stats, fn -> {:ok, %{stats: fetch_expensive_stats()}} end)
   |> assign_async(:chart_data, fn -> {:ok, %{chart_data: build_chart()}} end)}
end
```

```heex
<.async_result :let={stats} assign={@stats}>
  <:loading>Loading stats...</:loading>
  <:failed :let={_reason}>Failed to load stats</:failed>
  <p>Total: <%= stats.total %></p>
</.async_result>
```

```elixir
# start_async — imperative, handle result in handle_async/3
def mount(_params, _session, socket) do
  {:ok, start_async(socket, :report, fn -> generate_report() end)}
end

def handle_async(:report, {:ok, report}, socket) do
  {:noreply, assign(socket, :report, report)}
end

def handle_async(:report, {:exit, reason}, socket) do
  {:noreply, put_flash(socket, :error, "Report failed: #{inspect(reason)}")}
end
```

### Reduce Diffs

- Extract static markup into function components — LiveView skips diffing static parts.
- Avoid large assigns that change frequently. Split into smaller assigns.
- Use `@` references only for data that changes; move constants to module attributes.

## Common Anti-Patterns and Gotchas

1. **Blocking mount** — never do expensive DB queries or HTTP calls synchronously in `mount/3`. Use `assign_async` or `start_async`.
2. **Subscribing when disconnected** — always guard PubSub subscriptions with `connected?(socket)`.
3. **Storing derived data** — don't assign data derivable from other assigns. Compute in `render/1` or use function components.
4. **Overusing LiveComponents** — use function components for stateless UI. LiveComponents add process overhead and complexity.
5. **Large assigns** — don't store entire file contents or huge lists in assigns. Use streams or temporary assigns.
6. **Missing `id` on stream items** — streams require unique DOM IDs. Omitting causes silent rendering bugs.
7. **Not handling both mount phases** — `mount/3` runs twice (disconnected + connected). Side effects must be guarded with `connected?(socket)`.
8. **Sending non-serializable data** — assigns must be serializable for diffs. Don't store PIDs, refs, or functions in assigns rendered in templates.
9. **Ignoring `phx-debounce`** — text inputs without debounce flood the server with events on every keystroke.
10. **Not using `phx-disable-with`** — forms without it allow double submissions on slow connections.

## Dead Views vs Live Views

Use dead views (standard controller + template) when page is fully static/cacheable, SEO-only with no interactivity, or simple redirects/downloads. Use LiveView when page needs real-time updates, live form validation, or interactive state changes. Mix both: embed LiveView inside dead views with `live_render/3` for interactive sections.

## Deployment Considerations

- **Sticky sessions** — required when running multiple nodes without distributed Erlang. LiveView WebSocket must hit the same node. Use load balancer affinity (cookie or IP-based).
- **WebSocket config** — ensure reverse proxy supports WebSocket upgrades. Set timeouts to 60s+ for idle connections.
- **Long-poll fallback** — LiveView falls back to long-polling if WebSocket fails. Ensure `/live/longpoll` is accessible.
- **Node clustering** — for cross-node PubSub, use distributed Erlang or Redis adapter. Without it, broadcasts are node-local.
- **Memory** — each LiveView is a process (~2-5KB base). Monitor process count. Use streams to minimize per-process memory.
- **Reconnection** — LiveView auto-reconnects. `mount/3` re-runs on reconnect. Ensure mount is idempotent.
- **CSP headers** — allow `wss://` in `connect-src`. Don't route health checks through the LiveView pipeline.
