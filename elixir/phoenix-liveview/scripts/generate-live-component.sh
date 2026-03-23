#!/usr/bin/env bash
# generate-live-component.sh — Scaffold a Phoenix LiveComponent
#
# Usage:
#   ./generate-live-component.sh ModuleName [--stateless] [app_web_module]
#
# Flags:
#   --stateless   Generate a function component instead of a LiveComponent
#
# Examples:
#   ./generate-live-component.sh ItemCard                    # Stateful LiveComponent
#   ./generate-live-component.sh ItemCard --stateless        # Function component
#   ./generate-live-component.sh Admin.UserRow MyAppWeb      # Custom app module
#
# Output: Prints .ex file content to stdout. Redirect to a file:
#   ./generate-live-component.sh ItemCard > lib/my_app_web/live/item_card_component.ex

set -euo pipefail

STATELESS=false
MODULE_NAME=""
APP_WEB="MyAppWeb"

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --stateless)
      STATELESS=true
      ;;
    *)
      if [ -z "$MODULE_NAME" ]; then
        MODULE_NAME="$arg"
      else
        APP_WEB="$arg"
      fi
      ;;
  esac
done

if [ -z "$MODULE_NAME" ]; then
  echo "Usage: $0 ModuleName [--stateless] [AppWebModule]" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 ItemCard                    # Stateful LiveComponent" >&2
  echo "  $0 ItemCard --stateless        # Function component" >&2
  echo "  $0 Admin.UserRow MyAppWeb      # Custom app module" >&2
  exit 1
fi

SNAKE_NAME=$(echo "$MODULE_NAME" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//' | sed 's/\./_/g')

if [ "$STATELESS" = true ]; then
  # Generate a function component (stateless)
  cat <<ELIXIR
defmodule ${APP_WEB}.Components.${MODULE_NAME} do
  @moduledoc """
  Function component for ${MODULE_NAME}.
  Stateless — use this when no local state or event handling is needed.
  """
  use Phoenix.Component

  attr :id, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def ${SNAKE_NAME}(assigns) do
    ~H\"\"\"
    <div id={@id} class={@class}>
      <%= render_slot(@inner_block) %>
    </div>
    \"\"\"
  end
end
ELIXIR

else
  # Generate a stateful LiveComponent
  cat <<ELIXIR
defmodule ${APP_WEB}.${MODULE_NAME}Component do
  @moduledoc """
  Stateful LiveComponent for ${MODULE_NAME}.

  Usage:
    <.live_component module={${APP_WEB}.${MODULE_NAME}Component}
      id={"${SNAKE_NAME}-\#{@record.id}"}
      record={@record}
      on_action={&send(self(), {:${SNAKE_NAME}_action, &1})}
    />
  """
  use ${APP_WEB}, :live_component

  @impl true
  def mount(socket) do
    # Called once when the component is first created.
    # Use for one-time initialization that doesn't depend on assigns.
    {:ok, assign(socket, :editing, false)}
  end

  @impl true
  def update(assigns, socket) do
    # Called on mount and whenever parent re-renders with new assigns.
    # Always receives all assigns from the parent.
    {:ok,
     socket
     |> assign(assigns)
     |> assign_defaults()}
  end

  @impl true
  def handle_event("edit", _params, socket) do
    {:noreply, assign(socket, :editing, true)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, :editing, false)}
  end

  @impl true
  def handle_event("save", %{"${SNAKE_NAME}" => params}, socket) do
    # Process the save, then notify the parent LiveView
    notify_parent({:saved, params})
    {:noreply, assign(socket, :editing, false)}
  end

  @impl true
  def render(assigns) do
    ~H\"\"\"
    <div id={@id} class="${SNAKE_NAME}-component">
      <div :if={!@editing}>
        <%!-- Display mode --%>
        <button phx-click="edit" phx-target={@myself}>Edit</button>
      </div>

      <div :if={@editing}>
        <%!-- Edit mode --%>
        <form phx-submit="save" phx-target={@myself}>
          <%!-- Form fields here --%>
          <button type="submit">Save</button>
          <button type="button" phx-click="cancel" phx-target={@myself}>Cancel</button>
        </form>
      </div>
    </div>
    \"\"\"
  end

  # Private helpers

  defp assign_defaults(socket) do
    socket
    |> assign_new(:editing, fn -> false end)
  end

  defp notify_parent(msg) do
    send(self(), {__MODULE__, msg})
  end
end
ELIXIR
fi
