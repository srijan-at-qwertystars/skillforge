defmodule MyApp.Application do
  @moduledoc """
  OTP Application module — root of the supervision tree.

  Started automatically by Mix. Configures and starts all supervised processes.
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Database — must start first (other children may depend on it)
      MyApp.Repo,

      # Telemetry supervisor — metrics and instrumentation
      MyApp.Telemetry,

      # PubSub for broadcasting events
      {Phoenix.PubSub, name: MyApp.PubSub},

      # Process registry for dynamic process lookup
      {Registry, keys: :unique, name: MyApp.Registry, partitions: System.schedulers_online()},

      # Cluster formation (for distributed Elixir)
      {Cluster.Supervisor, [topologies(), [name: MyApp.ClusterSupervisor]]},

      # Application-specific supervision tree
      MyApp.MainSupervisor,

      # Task supervisor for async work
      {Task.Supervisor, name: MyApp.TaskSupervisor},

      # Dynamic supervisor for on-demand workers
      {DynamicSupervisor,
       name: MyApp.DynamicSupervisor,
       strategy: :one_for_one,
       max_children: 5_000}
    ]

    opts = [strategy: :one_for_one, name: MyApp.AppSupervisor]

    Logger.info("Starting #{__MODULE__} in #{config_env()} mode")

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        on_start()
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start application: #{inspect(reason)}")
        error
    end
  end

  @impl true
  def stop(_state) do
    Logger.info("#{__MODULE__} stopping")
    :ok
  end

  # Called after supervision tree is up
  defp on_start do
    Logger.info("Application started successfully")
    # Run post-startup tasks: cache warming, health checks, etc.
  end

  defp config_env do
    Application.get_env(:my_app, :env, :dev)
  end

  # Cluster topology — configure via runtime.exs in production
  defp topologies do
    Application.get_env(:libcluster, :topologies, [])
  end
end
