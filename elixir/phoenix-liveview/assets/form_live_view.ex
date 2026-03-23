# Form LiveView Example
#
# A complete LiveView form with changeset validation, error display,
# flash messages, and proper create/update handling.
#
# File: lib/my_app_web/live/item_live/form_live.ex

defmodule MyAppWeb.ItemLive.FormLive do
  @moduledoc """
  LiveView for creating and editing Items with full form handling.

  ## Routes

      live "/items/new", ItemLive.FormLive, :new
      live "/items/:id/edit", ItemLive.FormLive, :edit
  """
  use MyAppWeb, :live_view

  alias MyApp.Catalog
  alias MyApp.Catalog.Item

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    item = %Item{}
    changeset = Catalog.change_item(item)

    socket
    |> assign(:page_title, "New Item")
    |> assign(:item, item)
    |> assign(:categories, Catalog.list_categories())
    |> assign_form(changeset)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    item = Catalog.get_item!(id)
    changeset = Catalog.change_item(item)

    socket
    |> assign(:page_title, "Edit #{item.name}")
    |> assign(:item, item)
    |> assign(:categories, Catalog.list_categories())
    |> assign_form(changeset)
  end

  # ── Form Events ─────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"item" => item_params}, socket) do
    changeset =
      socket.assigns.item
      |> Catalog.change_item(item_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"item" => item_params}, socket) do
    save_item(socket, socket.assigns.live_action, item_params)
  end

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <.header>
        <%= @page_title %>
        <:subtitle>
          <%= if @live_action == :new, do: "Fill in the details to create a new item.",
              else: "Update the item details below." %>
        </:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="item-form"
        phx-change="validate"
        phx-submit="save"
      >
        <%!-- Text input with debounce to reduce server events --%>
        <.input
          field={@form[:name]}
          type="text"
          label="Name"
          placeholder="Enter item name"
          phx-debounce="300"
          required
        />

        <.input
          field={@form[:description]}
          type="textarea"
          label="Description"
          placeholder="Describe the item..."
          phx-debounce="500"
          rows="4"
        />

        <.input
          field={@form[:price]}
          type="number"
          label="Price"
          step="0.01"
          min="0"
        />

        <%!-- Select input --%>
        <.input
          field={@form[:category_id]}
          type="select"
          label="Category"
          prompt="Select a category"
          options={Enum.map(@categories, &{&1.name, &1.id})}
        />

        <%!-- Checkbox --%>
        <.input
          field={@form[:published]}
          type="checkbox"
          label="Published"
        />

        <%!-- Radio-like select for status --%>
        <.input
          field={@form[:status]}
          type="select"
          label="Status"
          options={[
            {"Draft", "draft"},
            {"Active", "active"},
            {"Archived", "archived"}
          ]}
        />

        <:actions>
          <.button phx-disable-with="Saving...">
            <%= if @live_action == :new, do: "Create Item", else: "Update Item" %>
          </.button>

          <.link navigate={~p"/items"} class="text-sm text-gray-500 hover:text-gray-700">
            Cancel
          </.link>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  # ── Private Helpers ─────────────────────────────────────────────────

  defp save_item(socket, :new, item_params) do
    case Catalog.create_item(item_params) do
      {:ok, item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Item \"#{item.name}\" created successfully.")
         |> push_navigate(to: ~p"/items/#{item}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_item(socket, :edit, item_params) do
    case Catalog.update_item(socket.assigns.item, item_params) do
      {:ok, item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Item \"#{item.name}\" updated successfully.")
         |> push_navigate(to: ~p"/items/#{item}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end

# ── Supporting Context Module (for reference) ──────────────────────────
#
# defmodule MyApp.Catalog do
#   alias MyApp.Catalog.Item
#   alias MyApp.Repo
#
#   def list_items, do: Repo.all(Item)
#   def get_item!(id), do: Repo.get!(Item, id)
#
#   def create_item(attrs) do
#     %Item{}
#     |> Item.changeset(attrs)
#     |> Repo.insert()
#     |> broadcast(:item_created)
#   end
#
#   def update_item(%Item{} = item, attrs) do
#     item
#     |> Item.changeset(attrs)
#     |> Repo.update()
#     |> broadcast(:item_updated)
#   end
#
#   def change_item(%Item{} = item, attrs \\ %{}) do
#     Item.changeset(item, attrs)
#   end
#
#   defp broadcast({:ok, item}, event) do
#     Phoenix.PubSub.broadcast(MyApp.PubSub, "items", {event, item})
#     {:ok, item}
#   end
#   defp broadcast({:error, _} = error, _event), do: error
# end
