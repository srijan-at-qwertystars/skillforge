defmodule MyApp.MainSupervisor do
  @moduledoc """
  Supervisor with multiple children and configurable strategy.

  Strategies:
  - `:one_for_one`  — restart only the failed child (default, most common)
  - `:one_for_all`  — restart all children when one fails (tightly coupled)
  - `:rest_for_one` — restart the failed child and those started after it

  ## Usage in Application

      def start(_type, _args) do
        children = [MyApp.MainSupervisor]
        Supervisor.start_link(children, strategy: :one_for_one)
      end
  """
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Static workers — started in order, restarted per strategy
      {MyApp.Cache, []},

      # Registry for dynamic process lookup
      {Registry, keys: :unique, name: MyApp.Registry},

      # Task supervisor for fire-and-forget async work
      {Task.Supervisor, name: MyApp.TaskSupervisor},

      # Dynamic supervisor for runtime-spawned children
      {DynamicSupervisor,
       name: MyApp.DynamicWorkerSupervisor,
       strategy: :one_for_one,
       max_children: 1_000},

      # Worker with custom child spec overrides
      Supervisor.child_spec(
        {MyApp.Workers.Example, name: :primary_worker},
        id: :primary_worker,
        restart: :permanent,
        shutdown: 10_000
      ),

      # Second instance of same module with different id
      Supervisor.child_spec(
        {MyApp.Workers.Example, name: :secondary_worker},
        id: :secondary_worker,
        restart: :transient
      )
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 10
    )
  end
end
