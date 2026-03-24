defmodule MyApp.Workers.Example do
  @moduledoc """
  Production-ready GenServer template with telemetry, error handling, and state typespecs.

  ## Usage

      MyApp.Workers.Example.start_link(name: :my_worker)
      MyApp.Workers.Example.process(pid, %{key: "value"})
  """
  use GenServer
  require Logger

  # --- Types ---

  @type state :: %{
          started_at: DateTime.t(),
          request_count: non_neg_integer(),
          config: config()
        }

  @type config :: %{
          timeout: pos_integer(),
          max_retries: non_neg_integer()
        }

  @default_config %{timeout: 5_000, max_retries: 3}

  # --- Public API ---

  @doc "Starts the GenServer linked to the calling process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    config = Keyword.get(opts, :config, @default_config)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @doc "Synchronously process a request. Returns `{:ok, result}` or `{:error, reason}`."
  @spec process(GenServer.server(), map()) :: {:ok, term()} | {:error, term()}
  def process(server \\ __MODULE__, request) do
    GenServer.call(server, {:process, request})
  end

  @doc "Asynchronously submit work."
  @spec submit(GenServer.server(), map()) :: :ok
  def submit(server \\ __MODULE__, request) do
    GenServer.cast(server, {:submit, request})
  end

  @doc "Returns the current state (for debugging)."
  @spec get_state(GenServer.server()) :: state()
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  # --- Child Spec ---

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  # --- Callbacks ---

  @impl true
  @spec init(config()) :: {:ok, state()}
  def init(config) do
    Process.flag(:trap_exit, true)

    state = %{
      started_at: DateTime.utc_now(),
      request_count: 0,
      config: Map.merge(@default_config, config)
    }

    :telemetry.execute(
      [:my_app, :worker, :start],
      %{system_time: System.system_time()},
      %{module: __MODULE__}
    )

    Logger.info("#{__MODULE__} started")
    {:ok, state}
  end

  @impl true
  def handle_call({:process, request}, _from, state) do
    start_time = System.monotonic_time()

    case do_process(request, state.config) do
      {:ok, result} ->
        emit_telemetry(:success, start_time, request)
        {:reply, {:ok, result}, %{state | request_count: state.request_count + 1}}

      {:error, reason} = error ->
        emit_telemetry(:error, start_time, request, reason)
        {:reply, error, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(msg, _from, state) do
    Logger.warning("#{__MODULE__} unexpected call: #{inspect(msg)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast({:submit, request}, state) do
    start_time = System.monotonic_time()

    case do_process(request, state.config) do
      {:ok, _result} ->
        emit_telemetry(:success, start_time, request)
        {:noreply, %{state | request_count: state.request_count + 1}}

      {:error, reason} ->
        emit_telemetry(:error, start_time, request, reason)
        Logger.error("#{__MODULE__} async processing failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast(msg, state) do
    Logger.warning("#{__MODULE__} unexpected cast: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.warning("#{__MODULE__} linked process exited: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__} unexpected info: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    :telemetry.execute(
      [:my_app, :worker, :stop],
      %{duration: DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)},
      %{module: __MODULE__, reason: reason, request_count: state.request_count}
    )

    Logger.info("#{__MODULE__} terminating (#{inspect(reason)}), processed #{state.request_count} requests")
    :ok
  end

  # --- Private ---

  @spec do_process(map(), config()) :: {:ok, term()} | {:error, term()}
  defp do_process(request, _config) do
    # Replace with actual processing logic
    {:ok, request}
  end

  defp emit_telemetry(status, start_time, request, error \\ nil) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:my_app, :worker, :request],
      %{duration: duration},
      %{module: __MODULE__, status: status, request_type: Map.get(request, :type), error: error}
    )
  end
end
