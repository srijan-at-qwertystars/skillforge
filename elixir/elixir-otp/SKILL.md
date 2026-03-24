---
name: elixir-otp
description: >
  USE when writing Elixir code, GenServer, Supervisor, OTP processes, Agent, Task, Registry,
  ETS, GenStage, Flow, Broadway, Mix projects, ExUnit tests, Ecto schemas/changesets/queries,
  behaviours, protocols, macros, mix releases, distributed Elixir, or BEAM/OTP architecture.
  USE when user mentions GenServer callbacks, supervision trees, child specs, process links,
  monitors, pattern matching pipes, Mox mocking, or Erlang interop.
  DO NOT USE for Phoenix LiveView, Phoenix channels, Phoenix router/controllers (use
  phoenix-liveview skill instead). DO NOT USE for pure Erlang without Elixir syntax.
  DO NOT USE for general functional programming concepts not specific to Elixir/BEAM.
---

# Elixir/OTP Patterns

## Elixir Fundamentals

### Pattern Matching and Pipes
Use `=` as match operator. Destructure on the left. Pin with `^` to match existing values.

```elixir
{:ok, result} = {:ok, 42}           # result => 42
[head | tail] = [1, 2, 3]           # head => 1, tail => [2, 3]
%{name: name} = %{name: "Ada", age: 30}  # name => "Ada"
^expected = "hello"                  # match against existing variable
```

Pipe operator chains transformations left-to-right as first argument:
```elixir
"  Hello World  " |> String.trim() |> String.downcase() |> String.split()
# => ["hello", "world"]
```

### Modules, Structs, Protocols, Behaviours

```elixir
defmodule User do
  @enforce_keys [:email]
  defstruct [:name, :email, role: :member]
  def admin?(%User{role: :admin}), do: true
  def admin?(%User{}), do: false
end

user = %User{name: "Ada", email: "ada@example.com"}
admin = %User{user | role: :admin}
```

Protocols provide polymorphism across types. Behaviours define module contracts:
```elixir
defprotocol Displayable do
  def display(data)
end

defimpl Displayable, for: User do
  def display(%User{name: n, email: e}), do: "#{n} <#{e}>"
end

# Behaviours — define callbacks a module must implement
defmodule MyApp.Storage do
  @callback store(String.t(), term()) :: :ok | {:error, term()}
  @callback fetch(String.t()) :: {:ok, term()} | {:error, :not_found}
end

defmodule MyApp.S3Storage do
  @behaviour MyApp.Storage
  @impl true
  def store(key, value), do: # implementation
  @impl true
  def fetch(key), do: # implementation
end
```

## OTP Architecture

### Processes, Messages, Links, Monitors
Processes are lightweight, isolated, communicate via messages. Use `spawn`, `send`, `receive`.

```elixir
pid = spawn(fn -> receive do {:greet, name} -> IO.puts("Hello #{name}") end end)
send(pid, {:greet, "World"})
# Output: Hello World
```

- **Links** (`Process.link/1`, `spawn_link/1`): Bidirectional. If linked process crashes, caller crashes too. Use in supervision trees.
- **Monitors** (`Process.monitor/1`): Unidirectional. Monitored process crash sends `{:DOWN, ref, :process, pid, reason}` message. Use when you need notification without crashing.

## GenServer

Wrap all GenServer interactions in a public API. Keep state minimal. Always use `@impl true`.

```elixir
defmodule Counter do
  use GenServer
  def start_link(initial \\ 0), do: GenServer.start_link(__MODULE__, initial, name: __MODULE__)
  def increment, do: GenServer.call(__MODULE__, :increment)
  def current, do: GenServer.call(__MODULE__, :current)
  def reset, do: GenServer.cast(__MODULE__, :reset)

  @impl true
  def init(initial), do: {:ok, initial}
  @impl true
  def handle_call(:increment, _from, count), do: {:reply, count + 1, count + 1}
  def handle_call(:current, _from, count), do: {:reply, count, count}
  @impl true
  def handle_cast(:reset, _count), do: {:noreply, 0}
  @impl true
  def handle_info(:tick, count), do: (IO.puts("Count: #{count}"); {:noreply, count})
  @impl true
  def terminate(_reason, _state), do: :ok
end
```

**Return values:** `init/1` → `{:ok, state}` | `{:ok, state, {:continue, term}}` | `:ignore` | `{:stop, reason}`. `handle_call/3` → `{:reply, reply, state}` | `{:noreply, state}` | `{:stop, reason, reply, state}`. `handle_cast/2`, `handle_info/2` → `{:noreply, state}` | `{:stop, reason, state}`. Never block inside handlers—offload to `Task`.

## Supervisor

Strategies: `:one_for_one` (restart failed child only, most common), `:one_for_all` (restart all, tightly coupled), `:rest_for_one` (restart failed + those started after it).

```elixir
defmodule MyApp.Supervisor do
  use Supervisor
  def start_link(init_arg), do: Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  @impl true
  def init(_init_arg) do
    children = [
      {Counter, 0},
      {MyApp.Worker, []},
      {Task.Supervisor, name: MyApp.TaskSupervisor}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

Child spec overrides (`use GenServer` auto-generates defaults):
```elixir
def child_spec(arg) do
  %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]},
    restart: :permanent, shutdown: 5000, type: :worker}  # restart: :permanent|:temporary|:transient
end
```

## Application Module

Root supervision tree in `application.ex`:
```elixir
defmodule MyApp.Application do
  use Application
  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Registry, keys: :unique, name: MyApp.Registry},
      {DynamicSupervisor, name: MyApp.DynSup, strategy: :one_for_one},
      MyApp.Supervisor
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.AppSupervisor)
  end
end
```

## Agent and Task

Agent — simple state wrapper. Prefer GenServer for complex logic:
```elixir
{:ok, agent} = Agent.start_link(fn -> %{} end, name: :cache)
Agent.update(:cache, &Map.put(&1, :key, "value"))
Agent.get(:cache, &Map.get(&1, :key))  # => "value"
```

Task — async/await for concurrent work:
```elixir
task = Task.async(fn -> expensive_computation() end)
result = Task.await(task, 10_000)  # 10s timeout

# Use Task.Supervisor + async_nolink to avoid caller crash on task failure
Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn -> risky_work() end) |> Task.await()
```

## Registry and Dynamic Supervisors

Registry provides process discovery by key. Use `:via` tuples for named processes.

```elixir
# Start registry in supervision tree
{Registry, keys: :unique, name: MyApp.Registry}

# Use via tuple for dynamic naming
defmodule Session do
  use GenServer
  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end
  defp via(id), do: {:via, Registry, {MyApp.Registry, id}}
  def lookup(id), do: GenServer.call(via(id), :get)
end

# DynamicSupervisor for runtime children
DynamicSupervisor.start_child(MyApp.DynSup, {Session, "user_123"})
```

## ETS (Erlang Term Storage)

In-memory key-value store. Types: `:set` (unique keys), `:bag`, `:ordered_set`, `:duplicate_bag`. Access: `:public`, `:protected` (default), `:private`.

```elixir
:ets.new(:my_cache, [:set, :public, :named_table])
:ets.insert(:my_cache, {"key", "value"})
:ets.lookup(:my_cache, "key")            # => [{"key", "value"}]
:ets.match(:my_cache, {:"$1", :"$2"})   # => [["key", "value"]]
```

## GenStage and Flow

### GenStage — Backpressure pipelines
Three roles: `:producer`, `:producer_consumer`, `:consumer`. Consumers pull demand upstream.

```elixir
defmodule NumberProducer do
  use GenStage
  def start_link(_), do: GenStage.start_link(__MODULE__, 0)
  def init(counter), do: {:producer, counter}
  def handle_demand(demand, counter) when demand > 0 do
    events = Enum.to_list(counter..(counter + demand - 1))
    {:noreply, events, counter + demand}
  end
end

defmodule Printer do
  use GenStage
  def start_link(_), do: GenStage.start_link(__MODULE__, :ok)
  def init(:ok), do: {:consumer, :ok, subscribe_to: [NumberProducer]}
  def handle_events(events, _from, state) do
    Enum.each(events, &IO.inspect/1)
    {:noreply, [], state}
  end
end
```

### Flow — High-level parallel processing
```elixir
File.stream!("large_file.txt")
|> Flow.from_enumerable()
|> Flow.flat_map(&String.split/1)
|> Flow.partition()
|> Flow.reduce(fn -> %{} end, fn word, acc ->
  Map.update(acc, word, 1, &(&1 + 1))
end)
|> Enum.to_list()
```

For production data ingestion from queues (SQS, Kafka, RabbitMQ), prefer **Broadway** over raw GenStage.

## Mix

```bash
mix new my_app --sup          # New project with supervision tree
mix deps.get                  # Fetch dependencies
mix compile                   # Compile project
mix test                      # Run tests
mix test --cover              # Run with coverage
mix format                    # Auto-format code
mix release                   # Build release
mix ecto.create               # Create database
mix ecto.migrate              # Run migrations
mix ecto.gen.migration name   # Generate migration
```

## ExUnit Testing

```elixir
defmodule UserTest do
  use ExUnit.Case, async: true
  alias MyApp.User
  setup do
    {:ok, user: %User{name: "Test", email: "test@example.com"}}
  end

  describe "admin?/1" do
    test "returns true for admin role", %{user: user} do
      assert User.admin?(%User{user | role: :admin})
    end
    test "returns false for member role", %{user: user} do
      refute User.admin?(user)
    end
  end
end
```

### Mocking with Mox

```elixir
# 1. Define behaviour
defmodule MyApp.HTTPClient do
  @callback get(String.t()) :: {:ok, map()} | {:error, term()}
end

# 2. test/test_helper.exs
Mox.defmock(MyApp.MockHTTP, for: MyApp.HTTPClient)
ExUnit.start()

# 3. config/test.exs
config :my_app, http_client: MyApp.MockHTTP

# 4. Production code — inject via config
defmodule MyApp.Service do
  @client Application.compile_env(:my_app, :http_client, MyApp.RealHTTP)
  def fetch(url), do: @client.get(url)
end

# 5. Test
defmodule MyApp.ServiceTest do
  use ExUnit.Case, async: true
  import Mox
  setup :verify_on_exit!
  test "fetch returns data" do
    expect(MyApp.MockHTTP, :get, fn _url -> {:ok, %{status: 200}} end)
    assert {:ok, %{status: 200}} = MyApp.Service.fetch("/api")
  end
end
```

Use `Mox.allow/3` when spawned processes access mocks. Use `async: false` only when tests share global state.

## Ecto Basics

### Schema, Changeset, Queries
```elixir
defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset
  schema "users" do
    field :name, :string
    field :email, :string
    field :age, :integer
    has_many :posts, MyApp.Post
    timestamps()
  end
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :age])
    |> validate_required([:name, :email])
    |> validate_format(:email, ~r/@/)
    |> validate_number(:age, greater_than: 0)
    |> unique_constraint(:email)
  end
end

# Insert
{:ok, user} = %MyApp.User{} |> MyApp.User.changeset(%{name: "Ada", email: "a@b.com"}) |> MyApp.Repo.insert()

# Query DSL — composable, parameterized (safe from injection)
import Ecto.Query
MyApp.User |> where([u], u.age > 18) |> order_by([u], desc: u.name) |> preload(:posts) |> MyApp.Repo.all()

def active_users(query \\ MyApp.User), do: from(u in query, where: u.active == true)
```

### Migrations
```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration
  def change do
    create table(:users) do
      add :name, :string, null: false
      add :email, :string, null: false
      add :age, :integer
      timestamps()
    end
    create unique_index(:users, [:email])
  end
end
```

Use `Ecto.Multi` for transactional multi-step operations:
```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:user, User.changeset(%User{}, attrs))
|> Ecto.Multi.insert(:profile, fn %{user: user} -> Profile.changeset(%Profile{user_id: user.id}, %{}) end)
|> Repo.transaction()
# => {:ok, %{user: %User{}, profile: %Profile{}}} | {:error, failed_op, changeset, changes}
```

## Metaprogramming

Use macros sparingly. Prefer functions, protocols, and behaviours first.

```elixir
defmacro unless(condition, do: block) do
  quote do
    if !unquote(condition), do: unquote(block)
  end
end

# quote returns AST; unquote injects values into quoted expressions
quote do: 1 + 2   # => {:+, [context: Elixir, ...], [1, 2]}
name = :hello
quote do: unquote(name)  # => :hello
```

Use `__using__/1` for shared module setup (e.g., base schemas):
```elixir
defmodule MyApp.Schema do
  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      @primary_key {:id, :binary_id, autogenerate: true}
    end
  end
end

defmodule MyApp.Post do
  use MyApp.Schema
  schema "posts" do
    field :title, :string
    timestamps()
  end
end
```

## Releases

```bash
MIX_ENV=prod mix release
_build/prod/rel/my_app/bin/my_app start
```

`config/runtime.exs` — executed at runtime, use for secrets and env-specific config:
```elixir
import Config
if config_env() == :prod do
  config :my_app, MyApp.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end
```

`rel/env.sh.eex` — set node name/cookie for distribution:
```bash
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=my_app@${HOSTNAME}
export RELEASE_COOKIE=${ERLANG_COOKIE}
```

## Distributed Elixir

```elixir
Node.connect(:"app@host2")
Node.list()  # => [:"app@host2"]
:rpc.call(:"app@host2", MyModule, :function, [arg1, arg2])
:global.register_name(:my_worker, self())
:global.whereis_name(:my_worker)
```

**libcluster** — automatic cluster formation. Add `{:libcluster, "~> 3.3"}` to deps:
```elixir
# config/runtime.exs
config :libcluster, topologies: [
  k8s: [strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [service: System.get_env("CLUSTER_DNS"), application_name: "my_app"]]
]
# application.ex — add to children:
{Cluster.Supervisor, [Application.get_env(:libcluster, :topologies), [name: MyApp.ClusterSupervisor]]}
```

## Common Pitfalls

1. **GenServer as bottleneck** — A single GenServer serializes all calls. Shard state across multiple processes or use ETS for read-heavy workloads.
2. **Large state in GenServer** — Store large data in ETS or a database. GenServer state is copied on every `call` reply.
3. **Blocking in callbacks** — Never do I/O or heavy computation inside `handle_call`/`handle_cast`. Delegate to `Task.async`.
4. **Forgetting `@impl true`** — Always annotate callbacks. Compiler warns on typos.
5. **Storing PIDs long-term** — PIDs change on restart. Use Registry, `:via` tuples, or `:global` for process discovery.
6. **Missing supervision** — Every long-lived process must be supervised. Unsupervised processes die silently.
7. **Sync calls to self** — A GenServer calling itself via `GenServer.call(__MODULE__, ...)` inside a callback deadlocks. Use internal functions or `handle_continue`.
8. **Not handling `:DOWN` messages** — When monitoring processes, always handle `{:DOWN, ref, :process, pid, reason}` in `handle_info`.
9. **Overusing macros** — Prefer functions and behaviours. Macros make code harder to trace and debug.
10. **Compile-time config for runtime values** — Use `runtime.exs` and `System.fetch_env!/1` for secrets. Never put secrets in `config.exs`.

## References

- **`references/advanced-patterns.md`** — GenStateMachine, dynamic supervisors at scale, process registries (Registry, :global, Horde), backpressure with GenStage/Flow/Broadway, hot code reloading, ETS/DETS patterns, persistent_term, Poolboy, umbrella apps, behaviours/protocols deep dive.
- **`references/troubleshooting.md`** — Process leaks, memory bloat, message queue overflow, supervisor restart intensity, deadlocks, ETS limits, atom exhaustion, binary memory, debugging with :observer/:sys/:recon, common crash reasons.
- **`references/testing-guide.md`** — ExUnit async tests, setup/setup_all, describe blocks, tags, Mox, Bypass, Ecto sandbox, StreamData property testing, doctests, coverage, CI setup.

## Templates and Scripts

### Scripts (`scripts/`)
- **`scripts/new-genserver.sh <Module>`** — Scaffold GenServer with callbacks and child spec.
- **`scripts/new-supervisor.sh <Module> [strategy]`** — Scaffold Supervisor with configurable strategy.
- **`scripts/otp-health-check.sh <node@host>`** — Report process count, memory, queues, ETS, uptime.

### Templates (`assets/`)
- **`assets/genserver-template.ex`** — Production GenServer with telemetry, typespecs, error handling.
- **`assets/supervisor-template.ex`** — Supervisor with multiple children, Registry, DynamicSupervisor.
- **`assets/application-template.ex`** — Application module with supervision tree, runtime config.
- **`assets/mix-project-template.exs`** — mix.exs with common deps, aliases, releases.
- **`assets/docker-compose.yml`** — Dev environment: Postgres, test DB, Redis.

<!-- tested: pass -->
