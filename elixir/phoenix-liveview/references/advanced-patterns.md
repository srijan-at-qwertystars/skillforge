# Advanced Phoenix LiveView Patterns

## Table of Contents

- [Nested LiveComponents](#nested-livecomponents)
- [Recursive Components](#recursive-components)
- [Multi-Step Wizards](#multi-step-wizards)
- [LiveView as State Machine](#liveview-as-state-machine)
- [Real-Time Collaboration](#real-time-collaboration)
- [Optimistic UI Updates](#optimistic-ui-updates)
- [Handling Race Conditions](#handling-race-conditions)
- [LiveView with Phoenix Channels](#liveview-with-phoenix-channels)
- [Distributed LiveView Across Nodes](#distributed-liveview-across-nodes)

---

## Nested LiveComponents

Nesting LiveComponents creates isolated state boundaries within a LiveView. Each component maintains its own assigns and handles its own events.

### Parent-Child Communication

**Parent → Child**: Pass data via assigns. The child's `update/2` callback receives new assigns.

**Child → Parent**: Use `send(self(), {:child_event, payload})` from the child. The parent handles it in `handle_info/2`.

```elixir
# Parent LiveView
defmodule MyAppWeb.DashboardLive do
  use MyAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :selected_widget, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <.live_component module={MyAppWeb.SidebarComponent} id="sidebar"
        on_select={&send(self(), {:widget_selected, &1})} />
      <.live_component module={MyAppWeb.ContentComponent} id="content"
        widget={@selected_widget} />
    </div>
    """
  end

  @impl true
  def handle_info({:widget_selected, widget}, socket) do
    {:noreply, assign(socket, :selected_widget, widget)}
  end
end
```

### Deeply Nested Components

Avoid deep nesting (3+ levels). Instead:

1. **Flatten the hierarchy** — let the parent LiveView orchestrate state.
2. **Use PubSub** for sibling communication instead of threading callbacks through layers.
3. **Use function components** for purely presentational layers between LiveComponents.

```elixir
# Anti-pattern: deeply nested LiveComponents
<.live_component module={Layout} id="layout">
  <.live_component module={Panel} id="panel">
    <.live_component module={Widget} id="widget">  # 3 levels deep = pain
    </.live_component>
  </.live_component>
</.live_component>

# Better: flat LiveComponents with function component wrappers
<.layout_wrapper>
  <.live_component module={Panel} id="panel" />
  <.live_component module={Widget} id="widget" />
</.layout_wrapper>
```

### Scoped Event Handling

Always use `phx-target={@myself}` inside LiveComponents to scope events to that component:

```elixir
# Inside a LiveComponent's render
<button phx-click="toggle" phx-target={@myself}>Toggle</button>
```

Without `phx-target`, the event bubbles to the parent LiveView.

---

## Recursive Components

Recursive components render tree-like structures: file explorers, nested comments, org charts, menus.

### Function Component Approach (Preferred)

```elixir
defmodule MyAppWeb.TreeComponent do
  use Phoenix.Component

  attr :nodes, :list, required: true
  attr :depth, :integer, default: 0

  def tree(assigns) do
    ~H"""
    <ul class={"ml-#{@depth * 4}"}>
      <li :for={node <- @nodes}>
        <div class="flex items-center gap-2">
          <span :if={node.children != []} class="cursor-pointer"
                phx-click={Phoenix.LiveView.JS.toggle(to: "#children-#{node.id}")}>
            ▶
          </span>
          <span><%= node.name %></span>
        </div>
        <div :if={node.children != []} id={"children-#{node.id}"}>
          <.tree nodes={node.children} depth={@depth + 1} />
        </div>
      </li>
    </ul>
    """
  end
end
```

### LiveComponent Approach (When Nodes Need State)

```elixir
defmodule MyAppWeb.TreeNodeComponent do
  use MyAppWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:expanded, fn -> false end)}
  end

  @impl true
  def handle_event("toggle", _, socket) do
    {:noreply, assign(socket, :expanded, !socket.assigns.expanded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="tree-node">
      <div phx-click="toggle" phx-target={@myself} class="cursor-pointer">
        <%= if @expanded, do: "▼", else: "▶" %> <%= @node.name %>
      </div>
      <div :if={@expanded} class="ml-4">
        <.live_component
          :for={child <- @node.children}
          module={__MODULE__}
          id={"node-#{child.id}"}
          node={child}
        />
      </div>
    </div>
    """
  end
end
```

**Performance note**: For large trees (1000+ nodes), use lazy loading — only fetch children when a node is expanded. Send `handle_event("expand", ...)` to load children from the database on demand.

---

## Multi-Step Wizards

Model wizards as a parent LiveView managing step state, with each step as a component.

### Step-Based Architecture

```elixir
defmodule MyAppWeb.OnboardingLive do
  use MyAppWeb, :live_view

  @steps [:profile, :preferences, :billing, :confirmation]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_step, :profile)
     |> assign(:form_data, %{})
     |> assign(:completed_steps, MapSet.new())}
  end

  @impl true
  def handle_info({:step_completed, step, data}, socket) do
    form_data = Map.merge(socket.assigns.form_data, data)
    next_step = next_step(step)

    {:noreply,
     socket
     |> assign(:form_data, form_data)
     |> assign(:completed_steps, MapSet.put(socket.assigns.completed_steps, step))
     |> assign(:current_step, next_step)}
  end

  @impl true
  def handle_info({:go_back, step}, socket) do
    prev = prev_step(step)
    {:noreply, assign(socket, :current_step, prev)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="wizard">
      <.step_indicator steps={@steps} current={@current_step} completed={@completed_steps} />

      <.live_component
        :if={@current_step == :profile}
        module={MyAppWeb.Onboarding.ProfileStep}
        id="step-profile"
        data={@form_data}
      />
      <.live_component
        :if={@current_step == :preferences}
        module={MyAppWeb.Onboarding.PreferencesStep}
        id="step-preferences"
        data={@form_data}
      />
      <%!-- ... more steps --%>
    </div>
    """
  end

  defp next_step(current) do
    idx = Enum.find_index(@steps, &(&1 == current))
    Enum.at(@steps, idx + 1, :confirmation)
  end

  defp prev_step(current) do
    idx = Enum.find_index(@steps, &(&1 == current))
    Enum.at(@steps, max(idx - 1, 0))
  end
end
```

### URL-Driven Wizard

Use `handle_params/3` with `live_patch` for bookmarkable steps:

```elixir
def handle_params(%{"step" => step}, _uri, socket) do
  step = String.to_existing_atom(step)
  {:noreply, assign(socket, :current_step, step)}
end

# Navigation
<.link patch={~p"/onboarding?step=preferences"}>Next</.link>
```

### Cross-Step Validation

Validate at each step boundary before proceeding. Store partial data in assigns. Only persist to the database at the final step:

```elixir
def handle_info({:step_completed, :billing, billing_data}, socket) do
  all_data = Map.merge(socket.assigns.form_data, billing_data)

  case MyApp.Accounts.create_user(all_data) do
    {:ok, user} ->
      {:noreply,
       socket
       |> assign(:form_data, all_data)
       |> assign(:current_step, :confirmation)
       |> assign(:user, user)}

    {:error, changeset} ->
      {:noreply,
       socket
       |> assign(:form_data, all_data)
       |> put_flash(:error, "Validation failed")
       |> assign(:current_step, find_failing_step(changeset))}
  end
end
```

---

## LiveView as State Machine

Model complex UI workflows explicitly as finite state machines. Pattern-match on `{current_state, event}` tuples.

### Explicit State Machine

```elixir
defmodule MyAppWeb.OrderLive do
  use MyAppWeb, :live_view

  # States: :browsing, :cart, :checkout, :payment, :confirmed, :error
  # Transitions are explicit and exhaustive

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, state: :browsing, order: nil, error: nil)}
  end

  @impl true
  def handle_event(event, params, socket) do
    case transition(socket.assigns.state, event, params, socket) do
      {:ok, new_state, socket} ->
        {:noreply, assign(socket, :state, new_state)}

      {:error, reason, socket} ->
        {:noreply,
         socket
         |> assign(:state, :error)
         |> assign(:error, reason)}
    end
  end

  defp transition(:browsing, "add_to_cart", %{"product_id" => id}, socket) do
    product = MyApp.Catalog.get_product!(id)
    cart = MyApp.Cart.add_item(socket.assigns[:cart] || %{}, product)
    {:ok, :cart, assign(socket, :cart, cart)}
  end

  defp transition(:cart, "checkout", _params, socket) do
    case MyApp.Orders.create_order(socket.assigns.cart) do
      {:ok, order} -> {:ok, :checkout, assign(socket, :order, order)}
      {:error, reason} -> {:error, reason, socket}
    end
  end

  defp transition(:checkout, "submit_payment", %{"token" => token}, socket) do
    case MyApp.Payments.charge(socket.assigns.order, token) do
      {:ok, _payment} -> {:ok, :confirmed, socket}
      {:error, reason} -> {:error, reason, socket}
    end
  end

  defp transition(:error, "retry", _params, socket) do
    {:ok, :cart, assign(socket, :error, nil)}
  end

  defp transition(state, event, _params, socket) do
    {:error, "Invalid transition: #{state} + #{event}", socket}
  end
end
```

### Using a Dedicated State Machine Module

Extract state machine logic for reuse and testability:

```elixir
defmodule MyApp.OrderStateMachine do
  @transitions %{
    browsing: %{"add_to_cart" => :cart},
    cart: %{"checkout" => :checkout, "clear" => :browsing},
    checkout: %{"submit_payment" => :payment, "back" => :cart},
    payment: %{"confirmed" => :confirmed, "failed" => :error},
    error: %{"retry" => :cart}
  }

  def can_transition?(from, event) do
    Map.has_key?(@transitions[from] || %{}, event)
  end

  def next_state(from, event) do
    case get_in(@transitions, [from, event]) do
      nil -> {:error, :invalid_transition}
      state -> {:ok, state}
    end
  end

  def valid_events(state), do: Map.keys(@transitions[state] || %{})
end
```

---

## Real-Time Collaboration

### Shared Document Editing

Use PubSub to broadcast edits. Track cursors and selections per user with Presence.

```elixir
defmodule MyAppWeb.DocumentLive do
  use MyAppWeb, :live_view
  alias MyApp.Documents
  alias MyAppWeb.Presence

  @topic_prefix "document:"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    document = Documents.get_document!(id)
    topic = @topic_prefix <> id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, topic)
      Presence.track(self(), topic, socket.assigns.current_user.id, %{
        username: socket.assigns.current_user.name,
        cursor: nil,
        color: random_color()
      })
    end

    presences = if connected?(socket), do: Presence.list(topic), else: %{}

    {:ok,
     socket
     |> assign(:document, document)
     |> assign(:topic, topic)
     |> assign(:presences, presences)}
  end

  @impl true
  def handle_event("update_content", %{"content" => content}, socket) do
    {:ok, document} = Documents.update_document(socket.assigns.document, %{content: content})

    Phoenix.PubSub.broadcast(MyApp.PubSub, socket.assigns.topic,
      {:content_updated, content, socket.assigns.current_user.id})

    {:noreply, assign(socket, :document, document)}
  end

  @impl true
  def handle_event("cursor_move", %{"position" => pos}, socket) do
    Presence.update(self(), socket.assigns.topic, socket.assigns.current_user.id, fn meta ->
      Map.put(meta, :cursor, pos)
    end)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:content_updated, content, from_user_id}, socket) do
    if from_user_id != socket.assigns.current_user.id do
      {:noreply, assign(socket, :document, %{socket.assigns.document | content: content})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%{event: "presence_diff", payload: diff}, socket) do
    presences = Presence.list(socket.assigns.topic)
    {:noreply, assign(socket, :presences, presences)}
  end

  defp random_color, do: Enum.random(~w(#FF6B6B #4ECDC4 #45B7D1 #96CEB4 #FFEAA7))
end
```

### Conflict Resolution Strategies

1. **Last Write Wins (LWW)** — simplest, acceptable for low-conflict scenarios.
2. **Operational Transform (OT)** — transform concurrent operations to converge. Complex to implement.
3. **CRDTs** — conflict-free replicated data types. Use libraries like `delta_crdt`. Best for distributed systems.
4. **Field-Level Locking** — lock specific fields per user. Show who is editing what via Presence metadata.

```elixir
# Field-level locking with Presence
def handle_event("focus_field", %{"field" => field}, socket) do
  Presence.update(self(), topic, user_id, fn meta ->
    Map.put(meta, :editing_field, field)
  end)
  {:noreply, socket}
end

# In template, check if another user is editing
<.input field={@form[:title]}
  disabled={field_locked_by_other?(@presences, :title, @current_user.id)}
  class={if field_locked_by_other?(@presences, :title, @current_user.id), do: "opacity-50"} />
```

---

## Optimistic UI Updates

Update the UI immediately before the server confirms the action. Roll back on failure.

### Pattern: Optimistic Insert with Rollback

```elixir
def handle_event("send_message", %{"body" => body}, socket) do
  # Create a temporary optimistic entry
  temp_id = "temp-#{System.unique_integer([:positive])}"
  optimistic_msg = %{id: temp_id, body: body, author: socket.assigns.current_user.name,
                     status: :sending, inserted_at: DateTime.utc_now()}

  # Immediately show in UI
  socket = stream_insert(socket, :messages, optimistic_msg, at: -1)

  # Persist asynchronously
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    case MyApp.Chat.create_message(%{body: body, user_id: socket.assigns.current_user.id}) do
      {:ok, message} ->
        send(self(), {:message_confirmed, temp_id, message})
      {:error, _changeset} ->
        send(self(), {:message_failed, temp_id})
    end
  end)

  {:noreply, socket}
end

def handle_info({:message_confirmed, temp_id, real_message}, socket) do
  socket =
    socket
    |> stream_delete_by_dom_id(:messages, "messages-#{temp_id}")
    |> stream_insert(:messages, real_message, at: -1)
  {:noreply, socket}
end

def handle_info({:message_failed, temp_id}, socket) do
  socket = stream_delete_by_dom_id(:messages, "messages-#{temp_id}")
  {:noreply, put_flash(socket, :error, "Message failed to send")}
end
```

### Pattern: JS Commands for Instant Feedback

Use `Phoenix.LiveView.JS` for zero-latency UI feedback:

```elixir
def like_button(assigns) do
  ~H"""
  <button
    phx-click={
      JS.push("like", value: %{id: @post.id})
      |> JS.add_class("text-red-500", to: "#like-#{@post.id}")
      |> JS.set_attribute({"disabled", "true"})
    }
    id={"like-#{@post.id}"}
  >
    ♥ <%= @post.like_count %>
  </button>
  """
end
```

---

## Handling Race Conditions

### Ecto Optimistic Locking

Prevent lost updates when multiple users edit the same record:

```elixir
# In schema
schema "documents" do
  field :title, :string
  field :content, :string
  field :lock_version, :integer, default: 1
  timestamps()
end

# In changeset
def changeset(document, attrs) do
  document
  |> cast(attrs, [:title, :content])
  |> validate_required([:title])
  |> optimistic_lock(:lock_version)
end
```

```elixir
# In LiveView
def handle_event("save", %{"document" => params}, socket) do
  case Documents.update_document(socket.assigns.document, params) do
    {:ok, document} ->
      {:noreply, assign(socket, :document, document)}

    {:error, %Ecto.Changeset{errors: [lock_version: _]}} ->
      # Another user saved first — reload and show conflict
      fresh = Documents.get_document!(socket.assigns.document.id)
      {:noreply,
       socket
       |> assign(:document, fresh)
       |> assign(:conflict, true)
       |> put_flash(:error, "This record was updated by another user. Please review.")}

    {:error, changeset} ->
      {:noreply, assign_form(socket, changeset)}
  end
end
```

### Serializing Critical Operations

Use a GenServer or database-level locks for operations that must not overlap:

```elixir
defmodule MyApp.InventoryLock do
  use GenServer

  def reserve_item(product_id, quantity) do
    GenServer.call(__MODULE__, {:reserve, product_id, quantity})
  end

  @impl true
  def handle_call({:reserve, product_id, quantity}, _from, state) do
    case MyApp.Inventory.reserve(product_id, quantity) do
      {:ok, reservation} -> {:reply, {:ok, reservation}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end
end
```

### Debouncing Rapid Events

Prevent multiple rapid submissions from creating duplicate records:

```elixir
def handle_event("create_order", params, socket) do
  if socket.assigns[:order_pending] do
    {:noreply, socket}
  else
    socket = assign(socket, :order_pending, true)
    case MyApp.Orders.create(params) do
      {:ok, order} ->
        {:noreply,
         socket
         |> assign(:order_pending, false)
         |> push_navigate(to: ~p"/orders/#{order}")}
      {:error, changeset} ->
        {:noreply, assign(socket, order_pending: false) |> assign_form(changeset)}
    end
  end
end
```

---

## LiveView with Phoenix Channels

LiveView runs over a Channel, but you can also use raw Channels alongside LiveView for specialized needs.

### When to Use Channels Directly

- **Binary data streaming** (audio, video) — LiveView only sends HTML diffs.
- **Inter-tab communication** — share state across browser tabs for the same user.
- **Game state updates** — very high-frequency updates where HTML diffing overhead matters.
- **External client integration** — mobile apps, IoT devices connecting via WebSocket.

### Combining LiveView + Channel

```elixir
# Custom Channel for high-frequency updates
defmodule MyAppWeb.GameChannel do
  use Phoenix.Channel

  def join("game:" <> game_id, _params, socket) do
    {:ok, assign(socket, :game_id, game_id)}
  end

  def handle_in("move", %{"x" => x, "y" => y}, socket) do
    broadcast!(socket, "player_moved", %{user: socket.assigns.user_id, x: x, y: y})
    {:noreply, socket}
  end
end
```

```javascript
// In app.js alongside LiveSocket
let gameChannel = socket.channel("game:123", {})
gameChannel.join()
gameChannel.on("player_moved", payload => {
  updatePlayerPosition(payload.user, payload.x, payload.y)
})

// LiveView hook bridges Channel data to LiveView
Hooks.GameBridge = {
  mounted() {
    this.channel = this.liveSocket.socket.channel("game:" + this.el.dataset.gameId)
    this.channel.join()
    this.channel.on("player_moved", data => {
      this.pushEvent("player_update", data)
    })
  },
  destroyed() {
    this.channel.leave()
  }
}
```

---

## Distributed LiveView Across Nodes

### PubSub in a Cluster

Phoenix.PubSub works across nodes when using distributed Erlang or a Redis adapter:

```elixir
# config/runtime.exs for distributed Erlang
config :my_app, MyApp.PubSub,
  adapter: Phoenix.PubSub.PG2  # works automatically in an Erlang cluster

# For non-Erlang clustering (e.g., Kubernetes without distributed Erlang)
config :my_app, MyApp.PubSub,
  adapter: Phoenix.PubSub.Redis,
  url: System.get_env("REDIS_URL")
```

### Sticky Sessions

LiveView WebSocket connections must stick to the same node for their lifetime:

```nginx
# Nginx config for sticky sessions
upstream phoenix_app {
  ip_hash;  # or use cookie-based stickiness
  server app1:4000;
  server app2:4000;
}

location /live {
  proxy_pass http://phoenix_app;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
}
```

### Cross-Node State Considerations

1. **Don't store cluster-critical state only in socket assigns** — it's lost if the node dies.
2. **Use a shared store** (database, Redis, ETS with replication) for state that must survive node failures.
3. **Presence works cross-node** — no extra config needed with distributed Erlang.
4. **Handle reconnection gracefully** — when a node dies, clients reconnect to another node and re-run `mount/3`.

### Node Clustering with libcluster

```elixir
# config/runtime.exs
config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes.DNS,
      config: [
        service: "my-app-headless",
        application_name: "my_app"
      ]
    ]
  ]
```

### Monitoring LiveView Processes Across Nodes

```elixir
# Count LiveView processes across all nodes
def live_view_process_count do
  nodes = [Node.self() | Node.list()]

  Enum.map(nodes, fn node ->
    count = :rpc.call(node, :erlang, :system_info, [:process_count])
    {node, count}
  end)
end

# Use Phoenix.LiveDashboard for per-node visibility
# Add to router:
live_dashboard "/dashboard",
  metrics: MyAppWeb.Telemetry,
  ecto_repos: [MyApp.Repo]
```

---

## Summary: When to Use What

| Pattern | Use When |
|---------|----------|
| Nested LiveComponents | UI sections need isolated state and events |
| Recursive Components | Tree/hierarchical data rendering |
| Multi-Step Wizard | Onboarding, checkout, multi-page forms |
| State Machine | Complex workflows with defined transitions |
| Real-Time Collab | Multiple users editing shared data |
| Optimistic UI | Low-latency feel for user actions |
| Race Condition Handling | Multi-user writes to same resource |
| Channels + LiveView | Binary data, high-frequency updates, external clients |
| Distributed LiveView | Multi-node deployment, horizontal scaling |
