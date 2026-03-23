# LiveComponent Template
#
# A template for a stateful LiveComponent with proper update/handle_event patterns.
# Copy this file and replace MyAppWeb/MyWidget with your actual module names.
#
# File: lib/my_app_web/live/my_widget_component.ex

defmodule MyAppWeb.MyWidgetComponent do
  @moduledoc """
  Stateful LiveComponent for MyWidget.

  ## Usage

      <.live_component
        module={MyAppWeb.MyWidgetComponent}
        id={"widget-\#{@record.id}"}
        record={@record}
        editable={true}
      />

  ## Parent Communication

  This component sends messages to the parent LiveView via `send/2`.
  Handle them in the parent's `handle_info/2`:

      def handle_info({MyAppWeb.MyWidgetComponent, {:saved, record}}, socket) do
        {:noreply, stream_insert(socket, :records, record)}
      end
  """
  use MyAppWeb, :live_component

  alias MyApp.MyContext

  # ── Mount ────────────────────────────────────────────────────────────
  # Called once when the component is first created (before the first update).
  # Use for initializing local state that doesn't depend on assigns from the parent.

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:editing, false)
     |> assign(:loading, false)}
  end

  # ── Update ───────────────────────────────────────────────────────────
  # Called on every render triggered by the parent. Receives ALL assigns
  # passed from the parent, including :id.
  #
  # Key rules:
  # - Always call `assign(assigns)` to accept parent assigns.
  # - Use `assign_new/3` for values that should persist across re-renders.
  # - Don't do expensive work here — it runs on every parent render.

  @impl true
  def update(%{record: record} = assigns, socket) do
    changeset = MyContext.change_record(record)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:editing, fn -> false end)
     |> assign_form(changeset)}
  end

  # ── Event Handlers ──────────────────────────────────────────────────
  # Events are scoped to this component when the template uses
  # phx-target={@myself}. Without phx-target, events bubble to the parent.

  @impl true
  def handle_event("edit", _params, socket) do
    {:noreply, assign(socket, :editing, true)}
  end

  def handle_event("cancel", _params, socket) do
    record = socket.assigns.record
    changeset = MyContext.change_record(record)

    {:noreply,
     socket
     |> assign(:editing, false)
     |> assign_form(changeset)}
  end

  def handle_event("validate", %{"record" => params}, socket) do
    changeset =
      socket.assigns.record
      |> MyContext.change_record(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"record" => params}, socket) do
    save_record(socket, socket.assigns.record, params)
  end

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="widget-component">
      <%!-- Display Mode --%>
      <div :if={!@editing} class="flex items-center justify-between">
        <div>
          <h3 class="font-semibold"><%= @record.name %></h3>
          <p class="text-sm text-gray-500"><%= @record.description %></p>
        </div>

        <button
          :if={Map.get(assigns, :editable, true)}
          phx-click="edit"
          phx-target={@myself}
          class="btn btn-sm"
        >
          Edit
        </button>
      </div>

      <%!-- Edit Mode --%>
      <div :if={@editing}>
        <.simple_form
          for={@form}
          id={"#{@id}-form"}
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
        >
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:description]} type="textarea" label="Description" />

          <:actions>
            <.button phx-disable-with="Saving...">Save</.button>
            <.button type="button" phx-click="cancel" phx-target={@myself}>
              Cancel
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end

  # ── Private Helpers ─────────────────────────────────────────────────

  defp save_record(socket, record, params) do
    case MyContext.update_record(record, params) do
      {:ok, updated_record} ->
        notify_parent({:saved, updated_record})

        {:noreply,
         socket
         |> assign(:editing, false)
         |> assign(:record, updated_record)
         |> assign_form(MyContext.change_record(updated_record))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg) do
    send(self(), {__MODULE__, msg})
  end
end
