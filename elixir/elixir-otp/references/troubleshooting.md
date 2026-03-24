# Elixir/OTP Troubleshooting Guide

## Table of Contents

- [Process Leaks](#process-leaks)
- [Memory Bloat](#memory-bloat)
- [Message Queue Overflow](#message-queue-overflow)
- [Supervisor Restart Intensity](#supervisor-restart-intensity)
- [Deadlocks](#deadlocks)
- [ETS Table Limits](#ets-table-limits)
- [Atom Table Exhaustion](#atom-table-exhaustion)
- [Binary Memory Issues](#binary-memory-issues)
- [Debugging Tools](#debugging-tools)
  - [:observer](#observer)
  - [:sys Module](#sys-module)
  - [Process.info](#processinfo)
  - [:recon](#recon)
- [Common Crash Reasons](#common-crash-reasons)
- [Performance Diagnostics](#performance-diagnostics)

---

## Process Leaks

**Symptoms:** Process count grows over time, memory increases, `Process.list() |> length()` climbs.

**Common causes:**
1. Spawned processes without supervision or monitoring
2. DynamicSupervisor children never terminated
3. Task processes that crash silently and respawn
4. Registry entries not cleaned up

**Diagnosis:**
```elixir
# Current process count
length(Process.list())

# Find process count by module (top creators)
Process.list()
|> Enum.map(fn pid ->
  case Process.info(pid, :dictionary) do
    {:dictionary, dict} -> dict[:"$initial_call"]
    nil -> :dead
  end
end)
|> Enum.frequencies()
|> Enum.sort_by(fn {_, count} -> count end, :desc)
|> Enum.take(20)

# DynamicSupervisor child count
DynamicSupervisor.count_children(MyApp.DynSup)

# Find processes with no links (orphans)
Process.list()
|> Enum.filter(fn pid ->
  case Process.info(pid, :links) do
    {:links, []} -> true
    _ -> false
  end
end)
|> length()
```

**Fixes:**
- Always supervise long-lived processes
- Use `Task.Supervisor` instead of bare `Task.async`
- Add monitors to track child lifetimes
- Set `max_children` on DynamicSupervisor
- Use `Process.monitor/1` and handle `:DOWN` to clean up resources

---

## Memory Bloat

**Symptoms:** RSS grows, `erlang.memory()` shows high total, OOM kills.

**Diagnosis:**
```elixir
# Overall memory breakdown (bytes)
:erlang.memory()
# => [total: ..., processes: ..., processes_used: ..., system: ...,
#     atom: ..., atom_used: ..., binary: ..., code: ..., ets: ...]

# Top memory-consuming processes
Process.list()
|> Enum.map(fn pid ->
  case Process.info(pid, [:memory, :registered_name, :current_function]) do
    info when is_list(info) ->
      %{pid: pid, memory: info[:memory],
        name: info[:registered_name], func: info[:current_function]}
    nil -> nil
  end
end)
|> Enum.reject(&is_nil/1)
|> Enum.sort_by(& &1.memory, :desc)
|> Enum.take(20)

# ETS table memory
:ets.all()
|> Enum.map(fn tab ->
  info = :ets.info(tab)
  %{name: info[:name], size: info[:size], memory: info[:memory] * :erlang.system_info(:wordsize)}
end)
|> Enum.sort_by(& &1.memory, :desc)
|> Enum.take(10)
```

**Common causes and fixes:**
| Cause | Fix |
|-------|-----|
| Large GenServer state | Move to ETS or database |
| Unbounded ETS tables | Add TTL-based cleanup |
| Binary accumulation | Force GC with `:erlang.garbage_collect(pid)` |
| Atom leaks | Never use `String.to_atom/1` on user input |
| Large message queues | Add backpressure, see [Message Queue Overflow](#message-queue-overflow) |

---

## Message Queue Overflow

**Symptoms:** Process mailbox grows, responses slow down, eventually OOM.

**Diagnosis:**
```elixir
# Find processes with large message queues
Process.list()
|> Enum.map(fn pid ->
  case Process.info(pid, [:message_queue_len, :registered_name]) do
    info when is_list(info) -> {info[:registered_name] || pid, info[:message_queue_len]}
    nil -> nil
  end
end)
|> Enum.reject(&is_nil/1)
|> Enum.filter(fn {_, len} -> len > 100 end)
|> Enum.sort_by(fn {_, len} -> len end, :desc)
```

**Common causes:**
1. Producer sends faster than consumer processes
2. GenServer doing slow work in `handle_call` while messages queue up
3. Process receiving messages it never handles (missing `handle_info` clause)
4. Selective receive patterns skipping messages

**Fixes:**
```elixir
# 1. Add catch-all handle_info to discard unexpected messages
@impl true
def handle_info(msg, state) do
  Logger.warning("Unexpected message: #{inspect(msg)}")
  {:noreply, state}
end

# 2. Use load shedding — drop old messages when overloaded
@impl true
def handle_info(:process_batch, state) do
  case Process.info(self(), :message_queue_len) do
    {:message_queue_len, len} when len > 1000 ->
      Logger.warning("Queue overflow (#{len}), dropping messages")
      flush_messages()
      {:noreply, state}
    _ ->
      do_process(state)
  end
end

defp flush_messages do
  receive do
    _ -> flush_messages()
  after
    0 -> :ok
  end
end

# 3. Use GenStage/Broadway for backpressure
# 4. Offload slow work to Task
def handle_call(:slow_query, from, state) do
  Task.start(fn ->
    result = do_slow_query()
    GenServer.reply(from, result)
  end)
  {:noreply, state}
end
```

---

## Supervisor Restart Intensity

**Symptoms:** Supervisor shuts down with `{:shutdown, :reached_max_restart_intensity}`.

**Explanation:** Supervisors have `max_restarts` (default 3) within `max_seconds` (default 5).
If a child crashes more than `max_restarts` times in `max_seconds`, the supervisor itself shuts down.

**Diagnosis:**
```elixir
# Check supervisor config
Supervisor.count_children(MyApp.Supervisor)
# Watch supervisor events
:sys.trace(MyApp.Supervisor, true)  # turn off with false when done
```

**Fixes:**
```elixir
# 1. Increase limits if crashes are transient
Supervisor.init(children,
  strategy: :one_for_one,
  max_restarts: 10,
  max_seconds: 60
)

# 2. Use :transient restart for expected shutdowns
def child_spec(arg) do
  %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]},
    restart: :transient}  # only restart on abnormal exit
end

# 3. Add init error handling — don't crash in init
@impl true
def init(config) do
  case connect(config) do
    {:ok, conn} -> {:ok, %{conn: conn}}
    {:error, reason} ->
      Logger.error("Connection failed: #{inspect(reason)}")
      {:ok, %{conn: nil}, {:continue, :retry_connect}}
  end
end

@impl true
def handle_continue(:retry_connect, state) do
  Process.send_after(self(), :retry_connect, :timer.seconds(5))
  {:noreply, state}
end
```

---

## Deadlocks

**Symptoms:** Process hangs, `GenServer.call` times out with `** (exit) exited in: GenServer.call(...)`.

**Common patterns:**

```elixir
# 1. Self-call deadlock — GenServer calls itself
# BAD:
def handle_call(:foo, _from, state) do
  result = GenServer.call(__MODULE__, :bar)  # DEADLOCK — process waiting on itself
  {:reply, result, state}
end

# FIX: Call internal function directly
def handle_call(:foo, _from, state) do
  result = do_bar(state)
  {:reply, result, state}
end

# 2. Circular call deadlock — A calls B, B calls A
# FIX: Use cast for one direction, or restructure to avoid cycles

# 3. Lock ordering — multiple processes acquiring resources in different order
# FIX: Always acquire locks in consistent order (e.g., alphabetical by name)
```

**Diagnosis:**
```elixir
# Check if a process is stuck
Process.info(pid, [:current_function, :message_queue_len, :status])
# status: :waiting = blocked on receive, :running = active

# Get the current stacktrace
Process.info(pid, :current_stacktrace)

# For GenServer — peek at state without call (won't deadlock)
:sys.get_state(pid)
```

---

## ETS Table Limits

**Default limit:** 1400 tables per node (configurable via `+e` flag).

**Symptoms:** `ArgumentError` when calling `:ets.new/2`, "system limit" errors.

**Diagnosis:**
```elixir
length(:ets.all())  # current table count
:erlang.system_info(:ets_limit)  # configured limit
```

**Fixes:**
- Reuse tables instead of creating per-process
- Use a single table with composite keys: `{module, key}`
- Increase limit: `erl +e 10000` or in `vm.args`: `+e 10000`
- Clean up tables in `terminate/2`:
```elixir
@impl true
def terminate(_reason, %{table: table}) do
  :ets.delete(table)
  :ok
end
```

---

## Atom Table Exhaustion

**Symptoms:** VM crashes with "no more index entries in atom_tab". Unrecoverable — VM shuts down.

**Default limit:** ~1,048,576 atoms. Atoms are never garbage collected.

**Common causes:**
```elixir
# BAD — creates atom from untrusted input
String.to_atom(user_input)
Jason.decode!(json, keys: :atoms)

# GOOD — use existing atoms only
String.to_existing_atom(input)
Jason.decode!(json, keys: :strings)  # or keys: :atoms! for known schemas
```

**Diagnosis:**
```elixir
:erlang.system_info(:atom_count)  # current atoms
:erlang.system_info(:atom_limit)  # max atoms

# Monitor growth over time
spawn(fn ->
  Enum.each(1..100, fn _ ->
    IO.puts("Atoms: #{:erlang.system_info(:atom_count)}")
    Process.sleep(:timer.seconds(60))
  end)
end)
```

**Rules:**
- Never convert user input to atoms
- Use `String.to_existing_atom/1` when atom must exist
- Configure `Jason`/`Poison` with `keys: :strings` for external JSON
- Set atom limit higher with `+t`: `erl +t 2097152`

---

## Binary Memory Issues

**Symptoms:** High binary memory in `:erlang.memory(:binary)`, process memory doesn't match heap size.

**Explanation:** Binaries > 64 bytes are reference-counted on a shared heap. A process may hold
references to large binaries preventing GC even after data is "unused."

**Diagnosis:**
```elixir
# Binary memory
:erlang.memory(:binary)

# Process holding binary references
Process.list()
|> Enum.map(fn pid ->
  case Process.info(pid, [:binary, :registered_name, :memory]) do
    info when is_list(info) ->
      bin_size = info[:binary] |> Enum.map(fn {_, size, _} -> size end) |> Enum.sum()
      %{pid: pid, name: info[:registered_name], bin_size: bin_size, memory: info[:memory]}
    nil -> nil
  end
end)
|> Enum.reject(&is_nil/1)
|> Enum.sort_by(& &1.bin_size, :desc)
|> Enum.take(10)
```

**Fixes:**
```elixir
# Force GC on specific process
:erlang.garbage_collect(pid)

# Copy binary to break reference (useful in long-lived processes)
defp copy_binary(<<data::binary>>), do: :binary.copy(data)

# Hibernate process to force full GC (useful in idle GenServers)
def handle_info(:timeout, state) do
  {:noreply, state, :hibernate}
end

# Use :binary.copy/1 when extracting small parts from large binaries
small_part = :binary.copy(String.slice(large_binary, 0, 100))
```

---

## Debugging Tools

### :observer

GUI tool for inspecting running BEAM systems.

```elixir
# In IEx
:observer.start()

# Remote observation
# On target: Node.connect(:"observer@host")
# Then: :observer.start() on observer node
```

**Tabs:** System (memory, IO), Load Charts, Applications (supervision trees),
Processes (sort by message queue, memory, reductions), Table Viewer (ETS/Mnesia).

### :sys Module

Inspect and control OTP processes without custom code.

```elixir
# Get current state (works for GenServer, GenStage, etc.)
:sys.get_state(MyApp.Worker)
:sys.get_state(pid)

# Get full status
:sys.get_status(MyApp.Worker)

# Trace messages in/out
:sys.trace(MyApp.Worker, true)
# ... observe messages ...
:sys.trace(MyApp.Worker, false)

# Suspend/resume (pause message processing)
:sys.suspend(MyApp.Worker)
:sys.resume(MyApp.Worker)

# Statistics
:sys.statistics(MyApp.Worker, true)
# ... let it run ...
:sys.statistics(MyApp.Worker, :get)
```

### Process.info

```elixir
# Key fields
Process.info(pid, :message_queue_len)  # mailbox size
Process.info(pid, :memory)             # process memory (bytes)
Process.info(pid, :reductions)         # work done (CPU proxy)
Process.info(pid, :current_function)   # what it's doing now
Process.info(pid, :current_stacktrace) # full stacktrace
Process.info(pid, :links)             # linked processes
Process.info(pid, :monitors)          # monitored processes
Process.info(pid, :status)            # :running | :waiting | :suspended
Process.info(pid, :dictionary)        # process dictionary
Process.info(pid, :heap_size)         # heap words

# All info at once
Process.info(pid)
```

### :recon

Production-safe debugging. Add `{:recon, "~> 2.5"}` to deps.

```elixir
# Top N processes by memory
:recon.proc_count(:memory, 10)

# Top N by message queue
:recon.proc_count(:message_queue_len, 10)

# Top N by reductions (CPU) in a window
:recon.proc_window(:reductions, 10, 5000)  # 5 second window

# Port (file/socket) info
:recon.port_types()
:recon.tcp()

# Memory breakdown
:recon_alloc.memory(:usage)
:recon_alloc.memory(:allocated)

# Binary memory analysis
:recon.bin_leak(10)  # find processes leaking binaries

# Trace function calls in production (safe, rate-limited)
:recon_trace.calls({MyApp.Worker, :handle_call, 3}, 10)  # trace 10 calls
:recon_trace.calls({MyApp.Worker, :_, :_}, 100, [scope: :local])
:recon_trace.clear()
```

---

## Common Crash Reasons

| Crash reason | Cause | Fix |
|---|---|---|
| `{:noproc, {GenServer, :call, _}}` | Process not running or not yet started | Check supervision, use `whereis/1`, handle `nil` |
| `{:timeout, {GenServer, :call, _}}` | `call` took > 5s (default) | Increase timeout, use `cast`, or offload to Task |
| `{:bad_return_value, val}` | Callback returned wrong shape | Check return tuples: `{:reply, ...}`, `{:noreply, ...}` |
| `:badarg` | Wrong argument type to BIF/NIF | Check types, especially ETS operations |
| `:badarith` | Arithmetic on non-numbers | Validate input types |
| `{:badmatch, val}` | Pattern match failed | Add catch-all clause or case statement |
| `:function_clause` | No function clause matched | Add fallback clause, check arg types |
| `{:undef, [{Module, :func, args, _}]}` | Function doesn't exist | Check module is compiled, function exported, arity correct |
| `:killed` | Process killed by OS (OOM) or `:erlang.exit(pid, :kill)` | Fix memory leak, increase limits |
| `:normal` | Expected exit | Only crash if `restart: :permanent` |
| `:shutdown` | Supervisor shutting down | Expected, handle cleanup in `terminate/2` |
| `{:shutdown, reason}` | Controlled shutdown with reason | Expected, check reason for details |

---

## Performance Diagnostics

### Quick Health Check

```elixir
IO.puts("Processes: #{length(Process.list())}")
IO.puts("Atoms: #{:erlang.system_info(:atom_count)}")
IO.puts("ETS tables: #{length(:ets.all())}")
IO.puts("Ports: #{length(Port.list())}")

memory = :erlang.memory()
for {key, bytes} <- memory do
  IO.puts("Memory #{key}: #{Float.round(bytes / 1_048_576, 2)} MB")
end
```

### Identifying CPU-Bound Processes

```elixir
# Snapshot reductions, wait, compare
pids = Process.list()
before = Map.new(pids, fn pid ->
  {pid, Process.info(pid, :reductions) |> elem(1)}
end)
Process.sleep(5000)
after_ = Map.new(pids, fn pid ->
  case Process.info(pid, :reductions) do
    {:reductions, r} -> {pid, r}
    nil -> {pid, 0}
  end
end)

pids
|> Enum.map(fn pid ->
  delta = Map.get(after_, pid, 0) - Map.get(before, pid, 0)
  name = case Process.info(pid, :registered_name) do
    {:registered_name, n} -> n
    _ -> pid
  end
  {name, delta}
end)
|> Enum.sort_by(fn {_, d} -> d end, :desc)
|> Enum.take(10)
```

### Scheduler Utilization

```elixir
# Enable scheduler wall time
:erlang.system_flag(:scheduler_wall_time, true)
ts1 = :erlang.statistics(:scheduler_wall_time)
Process.sleep(5000)
ts2 = :erlang.statistics(:scheduler_wall_time)

Enum.zip(Enum.sort(ts1), Enum.sort(ts2))
|> Enum.map(fn {{id, a1, t1}, {^id, a2, t2}} ->
  utilization = Float.round((a2 - a1) / (t2 - t1) * 100, 1)
  IO.puts("Scheduler #{id}: #{utilization}%")
end)
```
