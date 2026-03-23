# LiveView Template
#
# A well-commented template for a typical LiveView with all lifecycle callbacks.
# Copy this file and replace MyAppWeb/MyModule with your actual module names.
#
# File: lib/my_app_web/live/my_module_live.ex

defmodule MyAppWeb.MyModuleLive do
  @moduledoc """
  LiveView for MyModule.

  Handles [describe the feature: listing, CRUD, dashboard, etc.].

  ## Routes

      live "/my_module", MyModuleLive, :index
      live "/my_module/:id", MyModuleLive, :show
  """
  use MyAppWeb, :live_view

  alias MyApp.MyContext

  # ── Lifecycle Callbacks ──────────────────────────────────────────────

  @doc """
  Called twice: once for disconnected (static HTML) render, once on WebSocket connect.

  - Load initial data for BOTH renders.
  - Guard subscriptions and timers with `connected?(socket)`.
  - Use `assign_async` or `start_async` for expensive operations.
  - Return `{:ok, socket}` or `{:ok, socket, temporary_assigns: [...]}`.
  """
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to real-time updates (PubSub, Presence, timers)
      Phoenix.PubSub.subscribe(MyApp.PubSub, "my_module")
    end

    {:ok,
     socket
     |> assign(:page_title, "MyModule")
     |> stream(:records, MyContext.list_records())}
  end

  @doc """
  Called after mount/3 and on every `live_patch` / URL change.

  Use for:
  - URL-driven state (filters, pagination, selected record)
  - Updating page_title based on action
  - Loading data based on URL params
  """
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, :page_title, "All Records")
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    record = MyContext.get_record!(id)

    socket
    |> assign(:page_title, record.name)
    |> assign(:record, record)
  end

  # ── Client Events ───────────────────────────────────────────────────

  @doc """
  Handle events from the client: phx-click, phx-submit, phx-change, etc.

  Pattern match on the event name (first argument).
  Second argument is the event payload (form params, phx-value-* attributes).
  """
  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    record = MyContext.get_record!(id)
    {:ok, _} = MyContext.delete_record(record)
    {:noreply, stream_delete(socket, :records, record)}
  end

  def handle_event("search", %{"q" => query}, socket) do
    results = MyContext.search_records(query)
    {:noreply, stream(socket, :records, results, reset: true)}
  end

  # ── Server Messages ─────────────────────────────────────────────────

  @doc """
  Handle messages from other processes: PubSub broadcasts, Task results,
  Process.send_after timers, GenServer calls.
  """
  @impl true
  def handle_info({:record_created, record}, socket) do
    {:noreply, stream_insert(socket, :records, record, at: 0)}
  end

  def handle_info({:record_updated, record}, socket) do
    {:noreply, stream_insert(socket, :records, record)}
  end

  def handle_info({:record_deleted, record}, socket) do
    {:noreply, stream_delete(socket, :records, record)}
  end

  # ── Async Results ───────────────────────────────────────────────────

  @doc """
  Handle results from `start_async/3`.
  First arg is the async name, second is `{:ok, result}` or `{:exit, reason}`.
  """
  @impl true
  def handle_async(:expensive_operation, {:ok, result}, socket) do
    {:noreply, assign(socket, :result, result)}
  end

  def handle_async(:expensive_operation, {:exit, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Operation failed: #{inspect(reason)}")}
  end

  # ── Render ──────────────────────────────────────────────────────────

  @doc """
  Return HEEx template. Called after every assign change.

  Tips:
  - Extract static parts into function components (zero-diff optimization).
  - Use streams for large lists (`phx-update="stream"`).
  - Access assigns with `@name`, not `socket.assigns.name`.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <div class="my-module">
      <.header>
        <%= @page_title %>
        <:actions>
          <.link patch={~p"/my_module/new"}>
            <.button>New Record</.button>
          </.link>
        </:actions>
      </.header>

      <div id="records" phx-update="stream">
        <div :for={{dom_id, record} <- @streams.records} id={dom_id}
             class="flex items-center justify-between p-4 border-b">
          <span><%= record.name %></span>
          <div class="flex gap-2">
            <.link patch={~p"/my_module/#{record}"}>Show</.link>
            <button phx-click="delete" phx-value-id={record.id}
                    data-confirm="Are you sure?">
              Delete
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Terminate (rarely needed) ───────────────────────────────────────

  @doc """
  Called when the LiveView process is shutting down.
  Use for cleanup of external resources (not PubSub — that's automatic).
  """
  @impl true
  def terminate(_reason, _socket) do
    :ok
  end
end
