#!/usr/bin/env bash
# otp-health-check.sh — Connects to a running Elixir node and reports system health.
#
# Reports: process count, memory usage, message queue lengths, ETS tables,
#          uptime, top memory consumers, scheduler utilization.
#
# Usage:
#   ./otp-health-check.sh my_app@hostname
#   ./otp-health-check.sh my_app@hostname --cookie my_secret_cookie
#   ./otp-health-check.sh my_app@hostname --full
#
# Arguments:
#   $1 — Target node name (e.g., my_app@127.0.0.1) [required]
#   --cookie COOKIE — Erlang cookie (default: reads from ~/.erlang.cookie)
#   --full — Include extended diagnostics (top processes, ETS details)
#
# Prerequisites:
#   - Target node must be running and reachable
#   - Erlang/Elixir installed on the machine running this script
#   - Matching Erlang cookie

set -euo pipefail

FULL_REPORT=false
TARGET_NODE=""
COOKIE_ARG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cookie)
      COOKIE_ARG="--cookie $2"
      shift 2
      ;;
    --full)
      FULL_REPORT=true
      shift
      ;;
    --help|-h)
      head -17 "$0" | tail -15
      exit 0
      ;;
    *)
      TARGET_NODE="$1"
      shift
      ;;
  esac
done

if [[ -z "$TARGET_NODE" ]]; then
  echo "Usage: $0 <node_name> [--cookie COOKIE] [--full]"
  echo "Example: $0 my_app@127.0.0.1"
  exit 1
fi

# Generate unique observer node name
OBSERVER_NODE="health_check_$(date +%s)@127.0.0.1"

HEALTH_SCRIPT='
target = String.to_atom(System.argv() |> List.first())
full = "--full" in System.argv()

IO.puts("=" |> String.duplicate(60))
IO.puts("OTP Health Check — #{target}")
IO.puts("Timestamp: #{DateTime.utc_now() |> DateTime.to_string()}")
IO.puts("=" |> String.duplicate(60))

# Connect to target node
unless Node.connect(target) do
  IO.puts("ERROR: Cannot connect to #{target}")
  IO.puts("Check that the node is running and the cookie matches.")
  System.halt(1)
end

# Gather data via :rpc
call = fn mod, fun, args ->
  case :rpc.call(target, mod, fun, args) do
    {:badrpc, reason} ->
      IO.puts("  RPC error for #{mod}.#{fun}: #{inspect(reason)}")
      nil
    result -> result
  end
end

# --- Process Info ---
process_count = call.(:erlang, :system_info, [:process_count])
process_limit = call.(:erlang, :system_info, [:process_limit])
IO.puts("\n📊 PROCESSES")
IO.puts("  Count: #{process_count} / #{process_limit} (#{Float.round(process_count / process_limit * 100, 1)}% used)")

# --- Memory ---
memory = call.(:erlang, :memory, [])
if memory do
  IO.puts("\n💾 MEMORY")
  total_mb = Float.round(memory[:total] / 1_048_576, 2)
  IO.puts("  Total:     #{total_mb} MB")
  IO.puts("  Processes: #{Float.round(memory[:processes] / 1_048_576, 2)} MB")
  IO.puts("  ETS:       #{Float.round(memory[:ets] / 1_048_576, 2)} MB")
  IO.puts("  Atoms:     #{Float.round(memory[:atom] / 1_048_576, 2)} MB")
  IO.puts("  Binary:    #{Float.round(memory[:binary] / 1_048_576, 2)} MB")
  IO.puts("  Code:      #{Float.round(memory[:code] / 1_048_576, 2)} MB")
  IO.puts("  System:    #{Float.round(memory[:system] / 1_048_576, 2)} MB")
end

# --- Atoms ---
atom_count = call.(:erlang, :system_info, [:atom_count])
atom_limit = call.(:erlang, :system_info, [:atom_limit])
IO.puts("\n⚛️  ATOMS")
IO.puts("  Count: #{atom_count} / #{atom_limit} (#{Float.round(atom_count / atom_limit * 100, 1)}% used)")

# --- Uptime ---
{uptime_ms, _} = call.(:erlang, :statistics, [:wall_clock])
uptime_hours = Float.round(uptime_ms / 3_600_000, 2)
uptime_days = Float.round(uptime_ms / 86_400_000, 2)
IO.puts("\n⏱️  UPTIME")
IO.puts("  #{uptime_days} days (#{uptime_hours} hours)")

# --- Message Queues ---
IO.puts("\n📬 MESSAGE QUEUES (top 10)")
procs = call.(:erlang, :processes, [])
if procs do
  queue_info =
    procs
    |> Enum.map(fn pid ->
      case :rpc.call(target, Process, :info, [pid, [:message_queue_len, :registered_name]]) do
        info when is_list(info) ->
          {info[:registered_name] || inspect(pid), info[:message_queue_len]}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_, len} -> len end, :desc)
    |> Enum.take(10)

  for {name, len} <- queue_info do
    indicator = if len > 100, do: " ⚠️", else: ""
    IO.puts("  #{String.pad_trailing(inspect(name), 40)} #{len}#{indicator}")
  end
end

# --- ETS Tables ---
ets_tables = call.(:ets, :all, [])
IO.puts("\n📋 ETS TABLES")
IO.puts("  Count: #{length(ets_tables || [])}")
ets_limit = call.(:erlang, :system_info, [:ets_limit])
IO.puts("  Limit: #{ets_limit}")

if full && ets_tables do
  IO.puts("  Top 10 by memory:")
  ets_tables
  |> Enum.map(fn tab ->
    case :rpc.call(target, :ets, :info, [tab]) do
      info when is_list(info) ->
        word_size = call.(:erlang, :system_info, [:wordsize]) || 8
        %{name: info[:name], size: info[:size], memory: info[:memory] * word_size}
      _ -> nil
    end
  end)
  |> Enum.reject(&is_nil/1)
  |> Enum.sort_by(& &1.memory, :desc)
  |> Enum.take(10)
  |> Enum.each(fn t ->
    mb = Float.round(t.memory / 1_048_576, 3)
    IO.puts("    #{String.pad_trailing(inspect(t.name), 35)} #{t.size} entries, #{mb} MB")
  end)
end

# --- Top Memory Consumers ---
if full && procs do
  IO.puts("\n🔥 TOP 15 MEMORY CONSUMERS")
  procs
  |> Enum.map(fn pid ->
    case :rpc.call(target, Process, :info, [pid, [:memory, :registered_name, :current_function]]) do
      info when is_list(info) ->
        %{pid: inspect(pid), memory: info[:memory], name: info[:registered_name], func: info[:current_function]}
      _ -> nil
    end
  end)
  |> Enum.reject(&is_nil/1)
  |> Enum.sort_by(& &1.memory, :desc)
  |> Enum.take(15)
  |> Enum.each(fn p ->
    name = if p.name, do: inspect(p.name), else: p.pid
    mb = Float.round(p.memory / 1_048_576, 3)
    IO.puts("  #{String.pad_trailing(name, 35)} #{mb} MB  #{inspect(p.func)}")
  end)
end

# --- Ports ---
ports = call.(:erlang, :ports, [])
IO.puts("\n🔌 PORTS")
IO.puts("  Count: #{length(ports || [])}")

# --- Schedulers ---
schedulers = call.(:erlang, :system_info, [:schedulers_online])
IO.puts("\n⚙️  SCHEDULERS")
IO.puts("  Online: #{schedulers}")

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Health check complete.")
if !full, do: IO.puts("Run with --full for extended diagnostics.")
'

echo "Connecting to $TARGET_NODE..."
elixir --name "$OBSERVER_NODE" $COOKIE_ARG -e "$HEALTH_SCRIPT" -- "$TARGET_NODE" $(if $FULL_REPORT; then echo "--full"; fi)
