#!/usr/bin/env bash
# new-genserver.sh — Scaffolds a GenServer module with standard callbacks and supervisor child spec.
#
# Usage:
#   ./new-genserver.sh MyApp.Workers.EmailSender
#   ./new-genserver.sh MyApp.Cache [output_dir]
#
# Arguments:
#   $1 — Full module name (e.g., MyApp.Workers.EmailSender) [required]
#   $2 — Output directory (default: current directory)
#
# Output: Creates a .ex file with the module at the appropriate path.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <ModuleName> [output_dir]"
  echo "Example: $0 MyApp.Workers.EmailSender"
  echo "         $0 MyApp.Cache lib/"
  exit 1
fi

MODULE_NAME="$1"
OUTPUT_DIR="${2:-.}"

# Convert module name to file path: MyApp.Workers.EmailSender -> my_app/workers/email_sender.ex
FILE_PATH=$(echo "$MODULE_NAME" | sed 's/\./\//g' | sed 's/\([A-Z]\)/_\1/g' | sed 's/^_//' | sed 's/\/_/\//g' | tr '[:upper:]' '[:lower:]')
FILE_PATH="${OUTPUT_DIR}/${FILE_PATH}.ex"

# Create directory structure
mkdir -p "$(dirname "$FILE_PATH")"

# Extract simple module name for function names
SIMPLE_NAME=$(echo "$MODULE_NAME" | awk -F. '{print $NF}')
SNAKE_NAME=$(echo "$SIMPLE_NAME" | sed 's/\([A-Z]\)/_\1/g' | sed 's/^_//' | tr '[:upper:]' '[:lower:]')

cat > "$FILE_PATH" << ELIXIR
defmodule ${MODULE_NAME} do
  @moduledoc """
  GenServer for ${SIMPLE_NAME}.

  ## Usage

      ${MODULE_NAME}.start_link([])
      ${MODULE_NAME}.get_state()
  """
  use GenServer
  require Logger

  # --- Public API ---

  @doc "Starts the GenServer and links it to the calling process."
  def start_link(opts \\\\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current state."
  def get_state(server \\\\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  # --- Child Spec (for Supervisor) ---

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    Logger.info("#{__MODULE__} starting with opts: #{inspect(opts)}")
    state = %{
      started_at: DateTime.utc_now()
    }
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(msg, _from, state) do
    Logger.warning("#{__MODULE__} received unexpected call: #{inspect(msg)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast(msg, state) do
    Logger.warning("#{__MODULE__} received unexpected cast: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__} received unexpected info: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("#{__MODULE__} terminating: #{inspect(reason)}")
    :ok
  end
end
ELIXIR

echo "Created GenServer: $FILE_PATH"
echo "Add to supervisor: {${MODULE_NAME}, []}"
