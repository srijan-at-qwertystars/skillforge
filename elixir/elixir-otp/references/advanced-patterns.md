# Advanced Elixir/OTP Patterns

## Table of Contents

- [GenStateMachine](#genstatemachine)
- [Dynamic Supervisors at Scale](#dynamic-supervisors-at-scale)
- [Process Registries](#process-registries)
  - [Registry](#registry)
  - [:global](#global)
  - [Horde](#horde)
- [Backpressure Pipelines](#backpressure-pipelines)
  - [GenStage Patterns](#genstage-patterns)
  - [Flow](#flow)
  - [Broadway](#broadway)
- [Hot Code Reloading](#hot-code-reloading)
- [ETS/DETS Patterns](#etsdets-patterns)
- [persistent_term](#persistent_term)
- [Process Pooling with Poolboy](#process-pooling-with-poolboy)
- [Umbrella Applications](#umbrella-applications)
- [Behaviours Deep Dive](#behaviours-deep-dive)
- [Protocols Deep Dive](#protocols-deep-dive)

---

## GenStateMachine

Use `gen_statem` (via the `gen_state_machine` hex package) for processes with distinct states
and complex transitions. Prefer over GenServer when state machine logic dominates.

```elixir
# Add {:gen_state_machine, "~> 3.0"} to deps
defmodule MyApp.Connection do
  use GenStateMachine, callback_mode: :state_functions

  # --- Public API ---
  def start_link(opts), do: GenStateMachine.start_link(__MODULE__, opts, name: __MODULE__)
  def connect, do: GenStateMachine.cast(__MODULE__, :connect)
  def disconnect, do: GenStateMachine.cast(__MODULE__, :disconnect)
  def send_data(data), do: GenStateMachine.call(__MODULE__, {:send, data})

  # --- Callbacks ---
  @impl true
  def init(opts) do
    {:ok, :disconnected, %{host: opts[:host], socket: nil, retries: 0}}
  end

  # State: :disconnected
  def disconnected(:cast, :connect, data) do
    case do_connect(data.host) do
      {:ok, socket} ->
        {:next_state, :connected, %{data | socket: socket, retries: 0}}
      {:error, _reason} ->
        {:next_state, :backoff, data, [{:state_timeout, backoff_ms(data.retries), :retry}]}
    end
  end
  def disconnected({:call, from}, {:send, _}, data) do
    {:keep_state, data, [{:reply, from, {:error, :disconnected}}]}
  end

  # State: :connected
  def connected(:cast, :disconnect, data) do
    do_close(data.socket)
    {:next_state, :disconnected, %{data | socket: nil}}
  end
  def connected({:call, from}, {:send, payload}, data) do
    result = do_send(data.socket, payload)
    {:keep_state, data, [{:reply, from, result}]}
  end
  def connected(:info, {:tcp_closed, _}, data) do
    {:next_state, :backoff, %{data | socket: nil},
     [{:state_timeout, backoff_ms(0), :retry}]}
  end

  # State: :backoff — auto-retry with exponential backoff
  def backoff(:state_timeout, :retry, data) do
    case do_connect(data.host) do
      {:ok, socket} ->
        {:next_state, :connected, %{data | socket: socket, retries: 0}}
      {:error, _} ->
        retries = data.retries + 1
        {:keep_state, %{data | retries: retries},
         [{:state_timeout, backoff_ms(retries), :retry}]}
    end
  end

  defp backoff_ms(retries), do: min(:timer.seconds(2 ** retries), :timer.minutes(5))
  defp do_connect(_host), do: {:ok, make_ref()}
  defp do_close(_socket), do: :ok
  defp do_send(_socket, _payload), do: :ok
end
```

**Callback modes:**
- `:state_functions` — each state is a function name (shown above). Cleaner for few states.
- `:handle_event_function` — single `handle_event/4` with state as param. Better for many states with shared logic.

**Key features over GenServer:**
- State timeouts (auto-fire after entering state)
- Event timeouts (reset on any event)
- Generic timeouts (named, multiple concurrent)
- Postpone events (re-queue for later state)
- `:next_event` action to inject internal events

---

## Dynamic Supervisors at Scale

### Basic Pattern
```elixir
defmodule MyApp.SessionSupervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_session(session_id) do
    spec = {MyApp.Session, session_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_session(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: 10_000,        # prevent unbounded growth
      max_restarts: 100,
      max_seconds: 5
    )
  end
end
```

### Partitioned DynamicSupervisor for High Throughput

A single DynamicSupervisor becomes a bottleneck at high child counts. Partition across N supervisors:

```elixir
defmodule MyApp.PartitionedSupervisor do
  @partitions System.schedulers_online()

  def child_specs do
    for i <- 0..(@partitions - 1) do
      Supervisor.child_spec(
        {DynamicSupervisor, name: :"#{__MODULE__}_#{i}", strategy: :one_for_one},
        id: :"#{__MODULE__}_#{i}"
      )
    end
  end

  def start_child(key, spec) do
    partition = :erlang.phash2(key, @partitions)
    DynamicSupervisor.start_child(:"#{__MODULE__}_#{partition}", spec)
  end

  def which_children do
    Enum.flat_map(0..(@partitions - 1), fn i ->
      DynamicSupervisor.which_children(:"#{__MODULE__}_#{i}")
    end)
  end
end
```

### PartitionSupervisor (Elixir 1.14+)

Built-in partitioning — simpler than manual approach:

```elixir
# In supervision tree:
{PartitionSupervisor,
  child_spec: DynamicSupervisor,
  name: MyApp.DynSupPartition,
  partitions: System.schedulers_online()}

# Start a child on a deterministic partition:
DynamicSupervisor.start_child(
  {:via, PartitionSupervisor, {MyApp.DynSupPartition, session_id}},
  {MyApp.Session, session_id}
)
```

---

## Process Registries

### Registry

Elixir's built-in local process registry. Fast, supports unique and duplicate keys.

```elixir
# Unique registry — one process per key
{Registry, keys: :unique, name: MyApp.Registry}

# Duplicate registry — multiple processes per key (pub/sub pattern)
{Registry, keys: :duplicate, name: MyApp.PubSub}

# Via tuple for named GenServer
def start_link(id) do
  GenServer.start_link(__MODULE__, id, name: via(id))
end
defp via(id), do: {:via, Registry, {MyApp.Registry, id}}

# Lookup
Registry.lookup(MyApp.Registry, "user:123")
# => [{pid, value}]

# Pub/sub with duplicate registry
Registry.register(MyApp.PubSub, "topic:orders", [])
Registry.dispatch(MyApp.PubSub, "topic:orders", fn entries ->
  for {pid, _value} <- entries, do: send(pid, {:order_event, data})
end)

# Count, select
Registry.count(MyApp.Registry)
Registry.select(MyApp.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])
```

**Partitioned registry** for high concurrency:
```elixir
{Registry, keys: :unique, name: MyApp.Registry, partitions: System.schedulers_online()}
```

### :global

Cluster-wide process registry. Works across connected nodes automatically.

```elixir
:global.register_name(:leader, self())
:global.whereis_name(:leader)   # => pid | :undefined
:global.re_register_name(:leader, new_pid)
:global.unregister_name(:leader)

# Via tuple
GenServer.start_link(MyModule, arg, name: {:global, :my_singleton})
GenServer.call({:global, :my_singleton}, :some_call)
```

**Caveats:**
- Global lock during registration — slow at scale
- Network partitions cause split-brain; no conflict resolution by default
- Use `resolve` function for custom conflict handling
- Consider Horde for large clusters

### Horde

Distributed supervisor and registry built on CRDTs. Add `{:horde, "~> 0.8"}`.

```elixir
# Distributed Registry
defmodule MyApp.DistRegistry do
  use Horde.Registry
  def start_link(_) do
    Horde.Registry.start_link(__MODULE__, [keys: :unique], name: __MODULE__)
  end
  def init(init_arg), do: Horde.Registry.init(init_arg)
end

# Distributed Supervisor
defmodule MyApp.DistSupervisor do
  use Horde.DynamicSupervisor
  def start_link(_) do
    Horde.DynamicSupervisor.start_link(__MODULE__, [strategy: :one_for_one],
      name: __MODULE__,
      members: :auto  # auto-discover cluster members
    )
  end
  def init(init_arg), do: Horde.DynamicSupervisor.init(init_arg)
end

# Start child — Horde distributes across cluster
Horde.DynamicSupervisor.start_child(MyApp.DistSupervisor, {MyApp.Worker, id})
```

**When to use what:**
| Feature | Registry | :global | Horde |
|---------|----------|---------|-------|
| Scope | Local node | Cluster | Cluster |
| Performance | Excellent | Moderate | Good |
| Consistency | Strong (local) | Strong (locks) | Eventual (CRDTs) |
| Split-brain | N/A | Problematic | Tolerant |
| Use case | Default choice | Small clusters, singletons | Large clusters, HA |

---

## Backpressure Pipelines

### GenStage Patterns

**Multi-stage pipeline with ProducerConsumer:**

```elixir
defmodule MyApp.EventProducer do
  use GenStage

  def start_link(_), do: GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  def push(event), do: GenStage.cast(__MODULE__, {:push, event})

  def init(:ok), do: {:producer, {:queue.new(), 0}}

  def handle_cast({:push, event}, {queue, pending}) do
    queue = :queue.in(event, queue)
    dispatch_events(queue, pending, [])
  end

  def handle_demand(incoming_demand, {queue, pending}) do
    dispatch_events(queue, incoming_demand + pending, [])
  end

  defp dispatch_events(queue, 0, events) do
    {:noreply, Enum.reverse(events), {queue, 0}}
  end
  defp dispatch_events(queue, demand, events) do
    case :queue.out(queue) do
      {{:value, event}, queue} ->
        dispatch_events(queue, demand - 1, [event | events])
      {:empty, queue} ->
        {:noreply, Enum.reverse(events), {queue, demand}}
    end
  end
end
```

**Rate-limited consumer:**
```elixir
defmodule MyApp.RateLimitedConsumer do
  use GenStage

  def start_link(_), do: GenStage.start_link(__MODULE__, :ok)

  def init(:ok) do
    {:consumer, %{}, subscribe_to: [{MyApp.EventProducer, max_demand: 10, min_demand: 5}]}
  end

  def handle_events(events, _from, state) do
    Enum.each(events, &process/1)
    Process.sleep(100)  # rate limit
    {:noreply, [], state}
  end
end
```

### Flow

High-level MapReduce over GenStage. Best for CPU-bound parallel processing.

```elixir
# Word frequency with windowing
File.stream!("access.log")
|> Flow.from_enumerable(max_demand: 100)
|> Flow.flat_map(fn line ->
  case parse_log_line(line) do
    {:ok, entry} -> [entry]
    :error -> []
  end
end)
|> Flow.partition(key: {:key, :path})
|> Flow.reduce(fn -> %{} end, fn entry, acc ->
  Map.update(acc, entry.path, 1, &(&1 + 1))
end)
|> Flow.departition(fn -> %{} end, &Map.merge(&1, &2, fn _, a, b -> a + b end), & &1)
|> Enum.sort_by(fn {_path, count} -> count end, :desc)
|> Enum.take(100)
```

### Broadway

Production data pipeline. Manages batching, acknowledgement, graceful shutdown, telemetry.

```elixir
defmodule MyApp.SQSPipeline do
  use Broadway

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {BroadwaySQS.Producer, queue_url: System.fetch_env!("SQS_QUEUE_URL")},
        concurrency: 2
      ],
      processors: [
        default: [concurrency: 10, max_demand: 10]
      ],
      batchers: [
        s3: [concurrency: 4, batch_size: 100, batch_timeout: 1_000],
        default: [concurrency: 2, batch_size: 50]
      ]
    )
  end

  @impl true
  def handle_message(_processor, message, _context) do
    parsed = Jason.decode!(message.data)
    message
    |> Message.update_data(fn _ -> parsed end)
    |> Message.put_batcher(if parsed["type"] == "log", do: :s3, else: :default)
  end

  @impl true
  def handle_batch(:s3, messages, _batch_info, _context) do
    data = Enum.map(messages, & &1.data)
    upload_to_s3(data)
    messages
  end

  def handle_batch(:default, messages, _batch_info, _context) do
    Enum.each(messages, &process_message/1)
    messages
  end

  # Failed messages — return as failed for retry/DLQ
  @impl true
  def handle_failed(messages, _context) do
    Enum.each(messages, fn msg ->
      Logger.error("Failed: #{inspect(msg.data)}")
    end)
    messages
  end
end
```

---

## Hot Code Reloading

### In Development (IEx)
```elixir
iex> recompile()                          # recompile all changed modules
iex> r MyApp.MyModule                     # recompile specific module
iex> Code.compile_file("lib/my_mod.ex")   # compile a file
```

### In Production (OTP Releases)

GenServer state survives hot upgrades via `code_change/3`:

```elixir
defmodule MyApp.Worker do
  use GenServer

  # Called during hot upgrade when module version changes
  @impl true
  def code_change(old_vsn, old_state, _extra) do
    new_state = migrate_state(old_vsn, old_state)
    {:ok, new_state}
  end

  defp migrate_state(_old_vsn, %{data: data}) do
    # Transform old state shape to new
    %{data: data, version: 2, migrated_at: DateTime.utc_now()}
  end
end
```

**Appup and relup files** (for release upgrades):
```bash
# Generate appup
mix release.gen.appup my_app 0.1.0 0.2.0
# Build upgrade release
MIX_ENV=prod mix release --upgrade
# Apply on running node
bin/my_app upgrade "0.2.0"
```

**Caveats:** Hot upgrades are complex in practice. For most deployments, rolling restarts
(blue-green / canary) are safer and simpler.

---

## ETS/DETS Patterns

### ETS Read-Through Cache

```elixir
defmodule MyApp.Cache do
  use GenServer

  @table __MODULE__
  @ttl :timer.minutes(5)

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :miss
        end
      [] -> :miss
    end
  end

  def put(key, value) do
    expires_at = System.monotonic_time(:millisecond) + @ttl
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  def fetch(key, fallback) do
    case get(key) do
      {:ok, value} -> value
      :miss ->
        value = fallback.()
        put(key, value)
        value
    end
  end

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @ttl)
end
```

### ETS as Write-Behind Buffer

```elixir
defmodule MyApp.WriteBuffer do
  use GenServer

  @flush_interval :timer.seconds(10)
  @max_buffer 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def write(key, value) do
    :ets.insert(:write_buffer, {key, value, System.monotonic_time()})
    count = :ets.info(:write_buffer, :size)
    if count >= @max_buffer, do: GenServer.cast(__MODULE__, :flush)
    :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(:write_buffer, [:set, :public, :named_table, write_concurrency: true])
    Process.send_after(self(), :flush, @flush_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state), do: do_flush(state)
  @impl true
  def handle_cast(:flush, state), do: do_flush(state)

  defp do_flush(state) do
    entries = :ets.tab2list(:write_buffer)
    :ets.delete_all_objects(:write_buffer)
    persist_batch(entries)
    Process.send_after(self(), :flush, @flush_interval)
    {:noreply, state}
  end

  defp persist_batch(entries) do
    Enum.each(entries, fn {key, value, _ts} ->
      MyApp.Repo.insert_or_update(key, value)
    end)
  end
end
```

### ETS Table Options Cheat Sheet

| Option | Use when |
|--------|----------|
| `read_concurrency: true` | Many concurrent readers, infrequent writes |
| `write_concurrency: true` | Many concurrent writers to different keys |
| `decentralized_counters: true` | Heavy use of `update_counter` (OTP 23+) |
| `:compressed` | Large values, trade CPU for memory |
| `:ordered_set` | Need range queries or sorted iteration |

### DETS (Disk-Based ETS)

```elixir
{:ok, table} = :dets.open_file(:my_store, [file: ~c"data/store.dets", type: :set])
:dets.insert(table, {"key", "value"})
:dets.lookup(table, "key")
:dets.close(table)
```

**DETS limitations:** 2GB file size limit, slower than ETS, no concurrent writes.
For persistent storage, prefer Ecto/database or `:persistent_term` for read-heavy config.

---

## persistent_term

Global read-optimized storage. Reads are zero-copy (no message passing). Writes trigger
a global GC of all processes — use only for rarely-changing data.

```elixir
# Store config at app start
:persistent_term.put({MyApp, :feature_flags}, %{dark_mode: true, beta: false})

# Read anywhere — extremely fast, no copying
:persistent_term.get({MyApp, :feature_flags})

# Update (triggers global GC — do sparingly)
:persistent_term.put({MyApp, :feature_flags}, %{dark_mode: true, beta: true})
```

**Best for:** compiled routes, feature flags, config, schemas.
**Not for:** frequently changing data, per-request state.

---

## Process Pooling with Poolboy

Add `{:poolboy, "~> 1.5"}` to deps.

```elixir
# In application supervision tree
defmodule MyApp.Application do
  def start(_type, _args) do
    pool_config = [
      name: {:local, :worker_pool},
      worker_module: MyApp.PoolWorker,
      size: 10,                # permanent pool members
      max_overflow: 5          # extra workers under load
    ]

    children = [
      :poolboy.child_spec(:worker_pool, pool_config, [])
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule MyApp.PoolWorker do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok)
  def init(:ok), do: {:ok, %{conn: connect_to_service()}}

  def handle_call({:query, q}, _from, %{conn: conn} = state) do
    result = execute(conn, q)
    {:reply, result, state}
  end
end

# Usage — checkout/checkin automatically
def query(q) do
  :poolboy.transaction(:worker_pool, fn worker ->
    GenServer.call(worker, {:query, q})
  end, :timer.seconds(5))  # checkout timeout
end
```

**Alternative:** `NimblePool` (by Dashbit) — more lightweight, better for short-lived checkouts.

---

## Umbrella Applications

```bash
mix new my_platform --umbrella
cd my_platform/apps
mix new core --sup          # shared business logic
mix new api --sup           # HTTP API
mix new worker --sup        # background jobs
```

**Structure:**
```
my_platform/
├── apps/
│   ├── core/          # shared schemas, contexts
│   ├── api/           # phoenix app, depends on core
│   └── worker/        # broadway/oban jobs, depends on core
├── config/            # shared config
└── mix.exs            # umbrella root
```

**Cross-app dependencies** in `apps/api/mix.exs`:
```elixir
defp deps do
  [{:core, in_umbrella: true}]
end
```

**When to use umbrellas:**
- Multiple deployable units sharing code
- Enforcing boundaries between contexts
- Team ownership boundaries

**When NOT to use:**
- Small projects (overhead not worth it)
- Single deployment unit (use contexts instead)

---

## Behaviours Deep Dive

Behaviours define a set of callbacks a module must implement — Elixir's answer to interfaces.

### Defining with Optional Callbacks and Defaults

```elixir
defmodule MyApp.Notifier do
  @doc "Send a notification"
  @callback notify(recipient :: String.t(), message :: String.t()) ::
    :ok | {:error, term()}

  @callback format_message(String.t()) :: String.t()

  @optional_callbacks format_message: 1

  # Default implementation via __using__
  defmacro __using__(_opts) do
    quote do
      @behaviour MyApp.Notifier

      @impl MyApp.Notifier
      def format_message(msg), do: "[#{__MODULE__}] #{msg}"

      defoverridable format_message: 1
    end
  end
end

defmodule MyApp.EmailNotifier do
  use MyApp.Notifier

  @impl true
  def notify(recipient, message) do
    formatted = format_message(message)
    MyApp.Mailer.send(recipient, formatted)
  end

  # Override default format_message if needed
  @impl true
  def format_message(msg), do: "📧 #{msg}"
end
```

### Runtime Dispatch via Config

```elixir
# config/config.exs
config :my_app, notifier: MyApp.EmailNotifier

# config/test.exs
config :my_app, notifier: MyApp.MockNotifier

# Usage
defmodule MyApp.Alerts do
  @notifier Application.compile_env(:my_app, :notifier)
  def send_alert(user, msg), do: @notifier.notify(user.email, msg)
end
```

---

## Protocols Deep Dive

Protocols provide polymorphism dispatched on the first argument's data type.

### Custom Protocol with Fallback

```elixir
defprotocol MyApp.Serializable do
  @fallback_to_any true
  @doc "Serialize data to a map"
  def serialize(data)
end

defimpl MyApp.Serializable, for: Any do
  def serialize(data), do: %{type: "unknown", value: inspect(data)}
end

defimpl MyApp.Serializable, for: Map do
  def serialize(map), do: map
end

defimpl MyApp.Serializable, for: MyApp.User do
  def serialize(%MyApp.User{} = user) do
    %{type: "user", id: user.id, name: user.name, email: user.email}
  end
end

# Derive for structs — auto-implements using a specific field list
defmodule MyApp.Product do
  @derive {MyApp.Serializable, fields: [:id, :name, :price]}
  defstruct [:id, :name, :price, :internal_cost]
end
```

### Protocol Consolidation

In production releases, protocols are consolidated at compile time for fast dispatch.
This happens automatically with `MIX_ENV=prod mix release`.

```elixir
# mix.exs
def project do
  [
    consolidate_protocols: Mix.env() != :test  # skip in test for faster recompilation
  ]
end
```

### Protocol vs Behaviour

| | Protocol | Behaviour |
|---|----------|-----------|
| Dispatch | On data type (first arg) | On module (compile-time config) |
| Extensible by | Anyone (defimpl) | Module author |
| Use for | Data transformation | Service interfaces |
| Example | Jason.Encoder, String.Chars | GenServer, Plug |
