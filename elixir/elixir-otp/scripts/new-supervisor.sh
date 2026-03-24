#!/usr/bin/env bash
# new-supervisor.sh — Scaffolds a Supervisor module with configurable strategy and child specs.
#
# Usage:
#   ./new-supervisor.sh MyApp.WorkerSupervisor
#   ./new-supervisor.sh MyApp.PipelineSupervisor one_for_all
#   ./new-supervisor.sh MyApp.SessionSupervisor one_for_one [output_dir]
#
# Arguments:
#   $1 — Full module name (e.g., MyApp.WorkerSupervisor) [required]
#   $2 — Strategy: one_for_one (default), one_for_all, rest_for_one
#   $3 — Output directory (default: current directory)
#
# Output: Creates a .ex file with the Supervisor module.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <ModuleName> [strategy] [output_dir]"
  echo "Strategies: one_for_one (default), one_for_all, rest_for_one"
  echo "Example: $0 MyApp.WorkerSupervisor one_for_one lib/"
  exit 1
fi

MODULE_NAME="$1"
STRATEGY="${2:-one_for_one}"
OUTPUT_DIR="${3:-.}"

# Validate strategy
case "$STRATEGY" in
  one_for_one|one_for_all|rest_for_one) ;;
  *)
    echo "Error: Invalid strategy '$STRATEGY'. Must be one_for_one, one_for_all, or rest_for_one."
    exit 1
    ;;
esac

# Convert module name to file path
FILE_PATH=$(echo "$MODULE_NAME" | sed 's/\./\//g' | sed 's/\([A-Z]\)/_\1/g' | sed 's/^_//' | sed 's/\/_/\//g' | tr '[:upper:]' '[:lower:]')
FILE_PATH="${OUTPUT_DIR}/${FILE_PATH}.ex"

mkdir -p "$(dirname "$FILE_PATH")"

# Extract simple module name
SIMPLE_NAME=$(echo "$MODULE_NAME" | awk -F. '{print $NF}')

cat > "$FILE_PATH" << ELIXIR
defmodule ${MODULE_NAME} do
  @moduledoc """
  Supervisor for ${SIMPLE_NAME}.

  Strategy: :${STRATEGY}
  - :one_for_one  — restart only the failed child
  - :one_for_all  — restart all children when one fails
  - :rest_for_one — restart the failed child and all children started after it

  ## Usage

  Add to your application supervision tree:

      children = [
        ${MODULE_NAME}
      ]
  """
  use Supervisor

  def start_link(init_arg \\\\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Add child specs here. Examples:
      # {MyApp.Worker, []},
      # {MyApp.Cache, name: MyApp.Cache},
      # {Task.Supervisor, name: MyApp.TaskSupervisor},
      # {Registry, keys: :unique, name: MyApp.Registry},
    ]

    Supervisor.init(children,
      strategy: :${STRATEGY},
      max_restarts: 3,
      max_seconds: 5
    )
  end
end
ELIXIR

echo "Created Supervisor: $FILE_PATH"
echo "Strategy: :${STRATEGY}"
echo "Add to application supervision tree: {${MODULE_NAME}, []}"
