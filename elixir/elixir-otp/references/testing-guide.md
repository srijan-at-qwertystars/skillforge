# Elixir Testing Guide (ExUnit Deep Dive)

## Table of Contents

- [ExUnit Fundamentals](#exunit-fundamentals)
  - [Async Tests](#async-tests)
  - [Setup and Setup All](#setup-and-setup-all)
  - [Describe Blocks](#describe-blocks)
  - [Tags](#tags)
- [Assertions](#assertions)
- [Doctests](#doctests)
- [Mox — Behaviour Mocking](#mox--behaviour-mocking)
  - [Setup and Configuration](#setup-and-configuration)
  - [Expectations and Stubs](#expectations-and-stubs)
  - [Concurrent Tests with Mox](#concurrent-tests-with-mox)
- [Bypass — HTTP Mocking](#bypass--http-mocking)
- [Ecto Sandbox](#ecto-sandbox)
  - [Configuration](#ecto-sandbox-configuration)
  - [Async Tests with Sandbox](#async-tests-with-sandbox)
  - [Testing Ecto Queries](#testing-ecto-queries)
- [Property-Based Testing with StreamData](#property-based-testing-with-streamdata)
- [Testing GenServers and OTP](#testing-genservers-and-otp)
- [Test Coverage](#test-coverage)
- [CI Setup](#ci-setup)

---

## ExUnit Fundamentals

### Async Tests

Tests marked `async: true` run concurrently across ExUnit's pool (default: `System.schedulers_online() * 2`).

```elixir
defmodule MyApp.ParserTest do
  use ExUnit.Case, async: true  # safe when tests don't share mutable state

  test "parses valid input" do
    assert {:ok, _} = MyApp.Parser.parse("valid data")
  end
end
```

**When to use `async: true`:**
- Pure function tests
- Tests using Ecto sandbox in shared mode
- Tests using `Mox.allow/3` for allowances

**When to use `async: false`:**
- Tests modifying global state (Application env, ETS named tables, files)
- Tests using `Mox.expect/4` without allowances in non-global mode
- Tests that start/stop global processes

### Setup and Setup All

```elixir
defmodule MyApp.AccountTest do
  use ExUnit.Case, async: true

  # Runs before EACH test — receives test context
  setup context do
    user = insert_user(role: context[:role] || :member)
    # Return values merge into test context
    %{user: user, token: generate_token(user)}
  end

  # Runs once for the entire module
  setup_all do
    # Expensive setup shared across all tests
    {:ok, config: load_test_config()}
  end

  # Multiple setup blocks run in order
  setup %{user: user} do
    # Can pattern-match context from prior setup
    {:ok, account: create_account(user)}
  end

  test "user has account", %{user: user, account: account, token: token} do
    assert account.user_id == user.id
    assert token != nil
  end

  # on_exit runs after the test, even if it fails
  setup do
    pid = start_supervised!(MyApp.Worker)
    on_exit(fn ->
      # cleanup runs in a separate process
      assert Process.alive?(pid) == false
    end)
    %{worker: pid}
  end
end
```

**`start_supervised!/2`** — starts a child under the test supervisor, auto-stopped after test:
```elixir
setup do
  worker = start_supervised!({MyApp.Worker, initial_state: %{}})
  %{worker: worker}
end
```

### Describe Blocks

Group related tests. Each `describe` can have its own `setup`.

```elixir
defmodule MyApp.CartTest do
  use ExUnit.Case, async: true

  describe "add_item/2" do
    setup do
      %{cart: MyApp.Cart.new()}
    end

    test "adds item to empty cart", %{cart: cart} do
      cart = MyApp.Cart.add_item(cart, %{id: 1, qty: 1})
      assert length(cart.items) == 1
    end

    test "increments quantity for existing item", %{cart: cart} do
      cart = cart
      |> MyApp.Cart.add_item(%{id: 1, qty: 1})
      |> MyApp.Cart.add_item(%{id: 1, qty: 2})
      assert hd(cart.items).qty == 3
    end
  end

  describe "total/1" do
    test "returns 0 for empty cart" do
      assert MyApp.Cart.total(MyApp.Cart.new()) == Decimal.new(0)
    end
  end
end
```

### Tags

Tag tests for filtering, configuration, or conditional behavior.

```elixir
defmodule MyApp.IntegrationTest do
  use ExUnit.Case

  # Module-level tag
  @moduletag :integration
  @moduletag timeout: 120_000

  @tag :slow
  test "full workflow" do
    # ...
  end

  @tag :skip
  test "not yet implemented" do
  end

  @tag capture_log: true  # suppresses Logger output
  test "noisy operation" do
    assert :ok = MyApp.noisyOperation()
  end
end
```

**Running with tags:**
```bash
mix test --only integration          # run only @tag :integration
mix test --exclude slow              # skip @tag :slow
mix test --include slow              # include even if excluded by default
mix test --only "describe:add_item"  # run specific describe block
```

**Configuring tag exclusions in `test_helper.exs`:**
```elixir
ExUnit.configure(exclude: [:skip, :integration])
ExUnit.start()
```

---

## Assertions

```elixir
# Basic
assert true
refute false
assert value == expected
assert value =~ ~r/pattern/        # regex match
assert value =~ "substring"        # string contains

# Pattern matching
assert {:ok, %{id: id}} = create_user()
assert [_ | _] = non_empty_list     # at least one element

# Exceptions
assert_raise ArgumentError, fn -> raise ArgumentError end
assert_raise ArgumentError, "message", fn -> raise ArgumentError, "message" end

# Process messages
send(self(), {:hello, "world"})
assert_receive {:hello, name}, 1000  # 1s timeout (default 100ms)
assert_received {:hello, "world"}    # already in mailbox, no wait
refute_receive :unexpected, 200      # ensure nothing received in 200ms

# Delta assertions
assert_in_delta 3.14, 3.141592, 0.01

# ExUnit.CaptureLog and CaptureIO
import ExUnit.CaptureLog
import ExUnit.CaptureIO

assert capture_log(fn -> Logger.error("boom") end) =~ "boom"
assert capture_io(fn -> IO.puts("hello") end) =~ "hello"
```

---

## Doctests

```elixir
defmodule MyApp.Math do
  @doc """
  Adds two numbers.

      iex> MyApp.Math.add(1, 2)
      3

      iex> MyApp.Math.add(-1, 1)
      0

  Multi-line example:

      iex> result = MyApp.Math.add(10, 20)
      iex> result * 2
      60
  """
  def add(a, b), do: a + b
end

# In test file:
defmodule MyApp.MathTest do
  use ExUnit.Case, async: true
  doctest MyApp.Math
end
```

**Tips:**
- Doctests run as individual tests — failures show line numbers
- Use `#=>` in docs for illustrative output that isn't tested
- Skip specific doctests: `doctest MyApp.Math, except: [:moduledoc]`
- Doctests don't have access to test context — keep them simple

---

## Mox — Behaviour Mocking

### Setup and Configuration

```elixir
# 1. Define behaviour
defmodule MyApp.WeatherAPI do
  @callback get_forecast(String.t()) :: {:ok, map()} | {:error, term()}
  @callback get_current(String.t()) :: {:ok, map()} | {:error, term()}
end

# 2. test/support/mocks.ex (compiled via test_paths or support)
Mox.defmock(MyApp.MockWeather, for: MyApp.WeatherAPI)

# 3. test/test_helper.exs
ExUnit.start()

# 4. config/test.exs
config :my_app, weather_api: MyApp.MockWeather

# 5. Production code — inject dependency
defmodule MyApp.Forecaster do
  @api Application.compile_env(:my_app, :weather_api, MyApp.RealWeatherAPI)

  def tomorrow(city) do
    case @api.get_forecast(city) do
      {:ok, %{"tomorrow" => forecast}} -> {:ok, forecast}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Expectations and Stubs

```elixir
defmodule MyApp.ForecasterTest do
  use ExUnit.Case, async: true
  import Mox

  # Verify all expectations were called
  setup :verify_on_exit!

  test "returns forecast for city" do
    # expect — must be called exactly N times (default 1)
    expect(MyApp.MockWeather, :get_forecast, fn "London" ->
      {:ok, %{"tomorrow" => %{"temp" => 18}}}
    end)

    assert {:ok, %{"temp" => 18}} = MyApp.Forecaster.tomorrow("London")
  end

  test "expect called multiple times" do
    MyApp.MockWeather
    |> expect(:get_forecast, 3, fn _city -> {:ok, %{"tomorrow" => %{}}} end)

    # Must call exactly 3 times
    for city <- ["London", "Paris", "Tokyo"] do
      MyApp.Forecaster.tomorrow(city)
    end
  end

  test "stub — no call count verification" do
    stub(MyApp.MockWeather, :get_forecast, fn _city ->
      {:ok, %{"tomorrow" => %{"temp" => 20}}}
    end)

    # Can be called any number of times (or not at all)
    assert {:ok, _} = MyApp.Forecaster.tomorrow("anywhere")
  end

  test "stub_with — implement entire behaviour" do
    stub_with(MyApp.MockWeather, MyApp.FakeWeatherAPI)
    # All callbacks delegated to the fake module
  end
end
```

### Concurrent Tests with Mox

```elixir
# Global mode — all processes share expectations (async: false only)
setup do
  Mox.set_mox_global()
  :ok
end

# Private mode (default) — expectations per-process
# When spawned processes need access to mocks:
test "async worker uses mock" do
  parent = self()
  expect(MyApp.MockWeather, :get_forecast, fn _ -> {:ok, %{}} end)

  # Allow the spawned process to use parent's expectations
  pid = spawn(fn ->
    Mox.allow(MyApp.MockWeather, parent, self())
    MyApp.Forecaster.tomorrow("Berlin")
  end)

  ref = Process.monitor(pid)
  assert_receive {:DOWN, ^ref, _, _, :normal}
end

# Or set allowances in setup for start_supervised processes
setup do
  worker = start_supervised!(MyApp.Worker)
  Mox.allow(MyApp.MockWeather, self(), worker)
  %{worker: worker}
end
```

---

## Bypass — HTTP Mocking

Add `{:bypass, "~> 2.1", only: :test}` to deps. Starts a real HTTP server on localhost.

```elixir
defmodule MyApp.GitHubClientTest do
  use ExUnit.Case, async: true

  setup do
    bypass = Bypass.open()
    # Configure client to use bypass URL
    client = MyApp.GitHubClient.new(base_url: "http://localhost:#{bypass.port}")
    %{bypass: bypass, client: client}
  end

  test "fetches user repos", %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, "GET", "/users/jose/repos", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, Jason.encode!([%{name: "elixir"}]))
    end)

    assert {:ok, [%{"name" => "elixir"}]} = MyApp.GitHubClient.repos(client, "jose")
  end

  test "handles server errors", %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, "GET", "/users/jose/repos", fn conn ->
      Plug.Conn.resp(conn, 500, "Internal Server Error")
    end)

    assert {:error, :server_error} = MyApp.GitHubClient.repos(client, "jose")
  end

  test "handles connection refused", %{bypass: bypass, client: client} do
    Bypass.down(bypass)
    assert {:error, :connection_refused} = MyApp.GitHubClient.repos(client, "jose")
    Bypass.up(bypass)  # restore for other tests
  end

  test "any request passes through", %{bypass: bypass, client: client} do
    Bypass.stub(bypass, :any, :any, fn conn ->
      Plug.Conn.resp(conn, 200, "ok")
    end)
    # No assertion on call count
  end
end
```

---

## Ecto Sandbox

### Ecto Sandbox Configuration

```elixir
# config/test.exs
config :my_app, MyApp.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# test/test_helper.exs
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :manual)
```

### Async Tests with Sandbox

```elixir
defmodule MyApp.UserServiceTest do
  use ExUnit.Case, async: true  # safe with sandbox!

  setup do
    # Each test gets its own DB transaction — rolled back after test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
    :ok
  end

  test "creates a user" do
    assert {:ok, user} = MyApp.UserService.create(%{name: "Ada", email: "ada@test.com"})
    assert user.id != nil
    # Transaction rolls back — DB stays clean
  end
end

# Shared sandbox for setup_all (all tests share one transaction)
setup_all do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
  Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
  :ok
end
```

**When spawned processes need DB access:**
```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
  # Allow all processes to use this checkout
  Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
  :ok
end
```

### Testing Ecto Queries

```elixir
defmodule MyApp.QueryTest do
  use MyApp.DataCase, async: true  # DataCase wraps sandbox checkout

  alias MyApp.{User, Repo}

  describe "active_users/0" do
    test "returns only active users" do
      active = insert!(:user, active: true)
      _inactive = insert!(:user, active: false)

      result = User.active_users() |> Repo.all()
      assert [returned] = result
      assert returned.id == active.id
    end

    test "orders by name" do
      insert!(:user, name: "Zara", active: true)
      insert!(:user, name: "Ada", active: true)

      names = User.active_users() |> Repo.all() |> Enum.map(& &1.name)
      assert names == ["Ada", "Zara"]
    end
  end

  # Factory helper (or use ex_machina)
  defp insert!(type, attrs \\ [])
  defp insert!(:user, attrs) do
    defaults = %{name: "User #{System.unique_integer()}", email: "#{System.unique_integer()}@test.com", active: true}
    merged = Map.merge(defaults, Map.new(attrs))
    %User{} |> User.changeset(merged) |> Repo.insert!()
  end
end
```

---

## Property-Based Testing with StreamData

Add `{:stream_data, "~> 1.0", only: :test}` to deps.

```elixir
defmodule MyApp.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Basic property — runs 100 times with random data by default
  property "encode then decode is identity" do
    check all value <- term() do
      assert value == value |> MyApp.Codec.encode() |> MyApp.Codec.decode()
    end
  end

  # Custom generators
  property "sort is idempotent" do
    check all list <- list_of(integer(), min_length: 0, max_length: 1000) do
      sorted = Enum.sort(list)
      assert sorted == Enum.sort(sorted)
    end
  end

  # Generator composition
  property "user changeset validates email" do
    check all name <- string(:alphanumeric, min_length: 1),
              email <- email_generator(),
              age <- integer(1..150) do
      changeset = User.changeset(%User{}, %{name: name, email: email, age: age})
      assert changeset.valid?
    end
  end

  # Custom generator
  defp email_generator do
    gen all local <- string(:alphanumeric, min_length: 1, max_length: 20),
            domain <- member_of(["example.com", "test.org", "mail.net"]) do
      "#{local}@#{domain}"
    end
  end

  # Shrinking — StreamData automatically finds minimal failing case
  property "list reversal" do
    check all list <- list_of(integer()) do
      assert Enum.reverse(Enum.reverse(list)) == list
    end
  end

  # Increase iterations for thorough testing
  property "stress test", max_runs: 1000 do
    check all input <- binary(min_length: 0, max_length: 10_000) do
      assert is_binary(MyApp.process(input))
    end
  end
end
```

**Common generators:**
```elixir
integer()                        # any integer
integer(1..100)                  # range
float(min: 0.0, max: 1.0)       # bounded float
string(:alphanumeric)            # alpha + digits
string(:printable)               # printable chars
binary()                         # raw binary
atom(:alphanumeric)              # atom
boolean()                        # true/false
list_of(integer())               # list of ints
map_of(atom(:alphanumeric), integer())  # map
tuple({integer(), string(:alphanumeric)})  # tuple
one_of([integer(), string(:alphanumeric)])  # union type
member_of(["a", "b", "c"])       # pick from list
term()                           # any term
```

---

## Testing GenServers and OTP

```elixir
defmodule MyApp.CacheTest do
  use ExUnit.Case, async: true

  setup do
    # start_supervised! stops the process after each test
    cache = start_supervised!({MyApp.Cache, name: :"cache_#{System.unique_integer()}"})
    %{cache: cache}
  end

  test "stores and retrieves values", %{cache: cache} do
    :ok = MyApp.Cache.put(cache, :key, "value")
    assert {:ok, "value"} = MyApp.Cache.get(cache, :key)
  end

  test "returns error for missing keys", %{cache: cache} do
    assert :error = MyApp.Cache.get(cache, :missing)
  end

  test "handles crash and restart" do
    # Test with supervised process
    cache = start_supervised!({MyApp.Cache, name: :crash_test})
    MyApp.Cache.put(cache, :key, "value")

    # Simulate crash
    Process.exit(cache, :kill)
    # Wait for restart
    Process.sleep(50)

    # Verify clean state after restart
    new_pid = Process.whereis(:crash_test)
    assert new_pid != cache
    assert :error = MyApp.Cache.get(new_pid, :key)
  end

  test "handles concurrent access", %{cache: cache} do
    tasks = for i <- 1..100 do
      Task.async(fn ->
        MyApp.Cache.put(cache, :"key_#{i}", i)
        {:ok, ^i} = MyApp.Cache.get(cache, :"key_#{i}")
      end)
    end
    Task.await_many(tasks)
  end
end

# Testing GenServer internals (when needed)
test "timer fires handle_info" do
  cache = start_supervised!(MyApp.Cache)
  # Directly send message to trigger handle_info
  send(cache, :cleanup)
  # Verify side effect
  assert :sys.get_state(cache).last_cleanup != nil
end
```

---

## Test Coverage

```bash
# Basic coverage
mix test --cover

# With excoveralls for detailed reports
# Add {:excoveralls, "~> 0.18", only: :test} to deps
mix coveralls              # console output
mix coveralls.html         # HTML report in cover/
mix coveralls.json         # JSON for CI upload
mix coveralls.lcov         # LCOV format
```

**Configuration in `mix.exs`:**
```elixir
def project do
  [
    test_coverage: [tool: ExCoveralls],
    preferred_cli_env: [
      coveralls: :test,
      "coveralls.html": :test,
      "coveralls.json": :test
    ]
  ]
end
```

**`coveralls.json` — ignore files:**
```json
{
  "coverage_options": {
    "minimum_coverage": 80,
    "treat_no_relevant_lines_as_covered": true
  },
  "skip_files": [
    "test/",
    "lib/my_app_web.ex",
    "lib/my_app/release.ex"
  ]
}
```

---

## CI Setup

### GitHub Actions

```yaml
# .github/workflows/test.yml
name: CI
on: [push, pull_request]

env:
  MIX_ENV: test
  ELIXIR_VERSION: "1.16"
  OTP_VERSION: "26"

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: my_app_test
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          elixir-version: ${{ env.ELIXIR_VERSION }}

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}
          restore-keys: ${{ runner.os }}-mix-

      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix format --check-formatted
      - run: mix credo --strict
      - run: mix dialyzer
      - run: mix test --cover
        env:
          DATABASE_URL: postgresql://postgres:postgres@localhost/my_app_test

  deploy:
    needs: test
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "Deploy step here"
```

### Dialyzer in CI (with caching)

```elixir
# mix.exs
defp deps do
  [
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
  ]
end
```

```yaml
# Add to CI steps
- name: Cache PLT
  uses: actions/cache@v4
  with:
    path: priv/plts
    key: plt-${{ runner.os }}-${{ env.OTP_VERSION }}-${{ env.ELIXIR_VERSION }}-${{ hashFiles('mix.lock') }}

- run: mix dialyzer --plt
- run: mix dialyzer --format github
```
