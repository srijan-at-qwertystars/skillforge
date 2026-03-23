#!/usr/bin/env bash
# generate-liveview.sh — Scaffold a new Phoenix LiveView module
#
# Usage:
#   ./generate-liveview.sh ModuleName [app_web_module]
#
# Examples:
#   ./generate-liveview.sh UserSettings
#   ./generate-liveview.sh Admin.Dashboard MyAppWeb
#
# Output: Prints the .ex file content to stdout. Redirect to a file:
#   ./generate-liveview.sh UserSettings > lib/my_app_web/live/user_settings_live.ex
#
# The generated LiveView includes:
#   - mount/3 with connected? guard
#   - handle_params/3 for URL-driven state
#   - handle_event/3 stub
#   - handle_info/2 stub for PubSub
#   - render/1 with HEEx template
#   - handle_async/3 stub

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 ModuleName [AppWebModule]" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 UserSettings" >&2
  echo "  $0 Admin.Dashboard MyAppWeb" >&2
  exit 1
fi

MODULE_NAME="$1"
APP_WEB="${2:-MyAppWeb}"

# Convert Module.Name to snake_case for the topic
SNAKE_NAME=$(echo "$MODULE_NAME" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//' | sed 's/\./_/g')

cat <<ELIXIR
defmodule ${APP_WEB}.${MODULE_NAME}Live do
  @moduledoc """
  LiveView for ${MODULE_NAME}.
  """
  use ${APP_WEB}, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, "${SNAKE_NAME}")
    end

    {:ok,
     socket
     |> assign(:page_title, "${MODULE_NAME}")
     |> assign(:loading, true)
     |> start_async(:load_data, fn -> load_initial_data() end)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, :page_title, "${MODULE_NAME}")
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    assign(socket, :page_title, "Show ${MODULE_NAME}")
  end

  @impl true
  def handle_event("example_event", %{"id" => id}, socket) do
    # Handle client-side events (phx-click, phx-submit, etc.)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:${SNAKE_NAME}_updated, payload}, socket) do
    # Handle PubSub broadcasts and other Erlang messages
    {:noreply, socket}
  end

  @impl true
  def handle_async(:load_data, {:ok, data}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:data, data)}
  end

  @impl true
  def handle_async(:load_data, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> put_flash(:error, "Failed to load data")}
  end

  @impl true
  def render(assigns) do
    ~H\"\"\"
    <div class="${SNAKE_NAME}">
      <.header>
        <%= @page_title %>
      </.header>

      <div :if={@loading}>Loading...</div>

      <div :if={!@loading}>
        <%!-- Your content here --%>
      </div>
    </div>
    \"\"\"
  end

  # Private helpers

  defp load_initial_data do
    # Replace with actual data loading
    []
  end
end
ELIXIR
