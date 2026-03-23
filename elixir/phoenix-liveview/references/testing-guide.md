# Comprehensive Phoenix LiveView Testing Guide

## Table of Contents

- [Test Setup and Configuration](#test-setup-and-configuration)
- [Unit Testing Function Components](#unit-testing-function-components)
- [Unit Testing LiveComponents](#unit-testing-livecomponents)
- [Integration Testing with live/2](#integration-testing-with-live2)
- [Testing Form Submissions](#testing-form-submissions)
- [Testing File Uploads](#testing-file-uploads)
- [Testing PubSub Events](#testing-pubsub-events)
- [Testing JS Hooks Behavior](#testing-js-hooks-behavior)
- [Testing Async Operations](#testing-async-operations)
- [Testing LiveView Navigation](#testing-liveview-navigation)
- [Testing Streams](#testing-streams)
- [ExUnit Setup Patterns](#exunit-setup-patterns)
- [Factory Patterns for Test Data](#factory-patterns-for-test-data)
- [Test Helpers and Utilities](#test-helpers-and-utilities)

---

## Test Setup and Configuration

### ConnCase Module

All LiveView tests use `ConnCase` which provides an authenticated `conn`:

```elixir
# test/support/conn_case.ex
defmodule MyAppWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MyAppWeb.Endpoint

      use MyAppWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import MyApp.Factory  # if using ex_machina or custom factories
    end
  end

  setup tags do
    MyApp.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
```

### Authenticated Test Setup

```elixir
defmodule MyAppWeb.ConnCase do
  # ...
  setup tags do
    MyApp.DataCase.setup_sandbox(tags)
    conn = Phoenix.ConnTest.build_conn()

    if tags[:authenticated] do
      user = MyApp.Factory.insert(:user)
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    else
      {:ok, conn: conn}
    end
  end

  defp log_in_user(conn, user) do
    token = MyApp.Accounts.generate_user_session_token(user)
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
```

---

## Unit Testing Function Components

Test stateless function components with `render_component/2`:

```elixir
defmodule MyAppWeb.Components.BadgeTest do
  use MyAppWeb.ConnCase, async: true

  alias MyAppWeb.Components.Badge

  test "renders active badge" do
    html = render_component(&Badge.badge/1, status: :active)
    assert html =~ "badge-active"
    assert html =~ "active"
  end

  test "renders inactive badge" do
    html = render_component(&Badge.badge/1, status: :inactive)
    assert html =~ "badge-inactive"
  end

  test "renders with custom class" do
    html = render_component(&Badge.badge/1, status: :active, class: "ml-2")
    assert html =~ "ml-2"
  end
end
```

### Testing Components with Slots

```elixir
defmodule MyAppWeb.Components.ModalTest do
  use MyAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders modal with title and body" do
    assigns = %{}
    html = rendered_to_string(~H"""
    <MyAppWeb.Components.Modal.modal id="test-modal" show={true}>
      <:title>Confirm Action</:title>
      <:body>Are you sure?</:body>
    </MyAppWeb.Components.Modal.modal>
    """)

    assert html =~ "Confirm Action"
    assert html =~ "Are you sure?"
    assert html =~ "test-modal"
  end
end
```

---

## Unit Testing LiveComponents

LiveComponents require a host LiveView for testing. Mount them inside a test LiveView or use `live_component` in your test:

### Approach 1: render_component for Simple Cases

```elixir
defmodule MyAppWeb.ItemCardComponentTest do
  use MyAppWeb.ConnCase, async: true

  alias MyAppWeb.ItemLive.ItemCardComponent

  test "renders item details" do
    item = %MyApp.Items.Item{id: 1, name: "Widget", status: :active}
    html = render_component(ItemCardComponent, id: "item-1", item: item)
    assert html =~ "Widget"
    assert html =~ "active"
  end
end
```

### Approach 2: Mount in a Real LiveView for Event Testing

```elixir
defmodule MyAppWeb.FormComponentTest do
  use MyAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias MyApp.Items

  @tag :authenticated
  test "validates form on change", %{conn: conn} do
    item = insert(:item)
    {:ok, view, _html} = live(conn, ~p"/items/#{item}/edit")

    assert view
           |> form("#item-form", item: %{name: ""})
           |> render_change() =~ "can&#39;t be blank"
  end

  @tag :authenticated
  test "saves valid item", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/items/new")

    view
    |> form("#item-form", item: %{name: "New Item", description: "A test item"})
    |> render_submit()

    assert_patch(view, ~p"/items")
    assert render(view) =~ "New Item"
  end
end
```

---

## Integration Testing with live/2

### Basic LiveView Mount and Render

```elixir
defmodule MyAppWeb.ItemLive.IndexTest do
  use MyAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup [:create_test_data]

  test "renders item listing page", %{conn: conn, items: items} do
    {:ok, _view, html} = live(conn, ~p"/items")

    for item <- items do
      assert html =~ item.name
    end
  end

  test "displays page title", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/items")
    assert page_title(view) == "Items"
  end

  test "handles unauthorized access" do
    conn = build_conn()  # no auth
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/items")
  end

  defp create_test_data(%{conn: conn}) do
    items = for i <- 1..3, do: insert(:item, name: "Item #{i}")
    %{conn: conn, items: items}
  end
end
```

### Testing Element Interactions

```elixir
test "clicking delete removes item", %{conn: conn, item: item} do
  {:ok, view, _html} = live(conn, ~p"/items")

  # Assert item exists
  assert has_element?(view, "#items-#{item.id}")

  # Click delete
  view
  |> element("#items-#{item.id} button[phx-click=delete]")
  |> render_click()

  # Assert item removed
  refute has_element?(view, "#items-#{item.id}")
end

test "clicking sort changes order", %{conn: conn} do
  insert(:item, name: "Zebra")
  insert(:item, name: "Alpha")

  {:ok, view, _html} = live(conn, ~p"/items")

  html = view
         |> element("th[phx-click=sort]", "Name")
         |> render_click()

  # Alpha should appear before Zebra
  assert String.contains?(html, "Alpha") and String.contains?(html, "Zebra")
  alpha_pos = :binary.match(html, "Alpha") |> elem(0)
  zebra_pos = :binary.match(html, "Zebra") |> elem(0)
  assert alpha_pos < zebra_pos
end
```

---

## Testing Form Submissions

### Validation Errors

```elixir
test "shows validation errors on change", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/items/new")

  result =
    view
    |> form("#item-form", item: %{name: "", price: -1})
    |> render_change()

  assert result =~ "can&#39;t be blank"
  assert result =~ "must be greater than 0"
end
```

### Successful Submission

```elixir
test "creates item and redirects", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/items/new")

  {:ok, _view, html} =
    view
    |> form("#item-form", item: %{name: "Widget", price: 9.99})
    |> render_submit()
    |> follow_redirect(conn)

  assert html =~ "Item created successfully"
  assert html =~ "Widget"
end
```

### Testing phx-submit with redirect vs patch

```elixir
# When the form does push_patch
test "saves and patches", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/items/new")

  view
  |> form("#item-form", item: %{name: "Widget"})
  |> render_submit()

  assert_patch(view, ~p"/items")
end

# When the form does push_navigate
test "saves and navigates", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/items/new")

  view
  |> form("#item-form", item: %{name: "Widget"})
  |> render_submit()

  assert_redirect(view, ~p"/items")
end
```

### Testing Multi-Select and Checkbox Forms

```elixir
test "submits multiple selected tags", %{conn: conn} do
  tag1 = insert(:tag, name: "elixir")
  tag2 = insert(:tag, name: "phoenix")

  {:ok, view, _html} = live(conn, ~p"/items/new")

  view
  |> form("#item-form", item: %{
    name: "Widget",
    tag_ids: [tag1.id, tag2.id]
  })
  |> render_submit()

  assert_patch(view)
  item = MyApp.Items.get_item_by_name!("Widget") |> MyApp.Repo.preload(:tags)
  assert length(item.tags) == 2
end
```

---

## Testing File Uploads

### Basic File Upload

```elixir
test "uploads avatar image", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/profile/edit")

  # Create a file input reference
  avatar =
    file_input(view, "#upload-form", :avatar, [
      %{
        last_modified: 1_594_171_879_000,
        name: "photo.jpg",
        content: File.read!("test/fixtures/photo.jpg"),
        size: 1_396,
        type: "image/jpeg"
      }
    ])

  # Assert file is accepted
  assert render_upload(avatar, "photo.jpg") =~ "photo.jpg"

  # Submit the form
  assert view
         |> form("#upload-form")
         |> render_submit() =~ "uploaded successfully"
end
```

### Testing Upload Validations

```elixir
test "rejects files that are too large", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/profile/edit")

  large_content = :crypto.strong_rand_bytes(10_000_000)  # 10MB

  avatar =
    file_input(view, "#upload-form", :avatar, [
      %{
        name: "huge.jpg",
        content: large_content,
        size: byte_size(large_content),
        type: "image/jpeg"
      }
    ])

  assert render_upload(avatar, "huge.jpg") =~ "Too large"
end

test "rejects invalid file types", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/profile/edit")

  avatar =
    file_input(view, "#upload-form", :avatar, [
      %{
        name: "malware.exe",
        content: "not a real exe",
        size: 14,
        type: "application/x-msdownload"
      }
    ])

  assert render_upload(avatar, "malware.exe") =~ "not accepted"
end
```

### Testing Upload Cancellation

```elixir
test "cancels an upload entry", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/profile/edit")

  avatar =
    file_input(view, "#upload-form", :avatar, [
      %{name: "photo.jpg", content: "img", size: 3, type: "image/jpeg"}
    ])

  render_upload(avatar, "photo.jpg")
  assert has_element?(view, "[phx-click=cancel-upload]")

  view
  |> element("[phx-click=cancel-upload]")
  |> render_click()

  refute has_element?(view, "[phx-click=cancel-upload]")
end
```

### Testing Multiple File Uploads

```elixir
test "uploads multiple photos", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/gallery/new")

  photos =
    file_input(view, "#gallery-form", :photos, [
      %{name: "photo1.jpg", content: "img1", size: 4, type: "image/jpeg"},
      %{name: "photo2.jpg", content: "img2", size: 4, type: "image/jpeg"},
      %{name: "photo3.jpg", content: "img3", size: 4, type: "image/jpeg"}
    ])

  render_upload(photos, "photo1.jpg")
  render_upload(photos, "photo2.jpg")
  render_upload(photos, "photo3.jpg")

  html = view |> form("#gallery-form") |> render_submit()
  assert html =~ "3 photos uploaded"
end
```

---

## Testing PubSub Events

### Broadcasting Updates to LiveView

```elixir
test "receives PubSub update and refreshes UI", %{conn: conn, item: item} do
  {:ok, view, _html} = live(conn, ~p"/items")
  assert has_element?(view, "#items-#{item.id}", item.name)

  # Simulate another user updating the item
  updated_item = %{item | name: "Updated Name"}
  Phoenix.PubSub.broadcast(MyApp.PubSub, "items", {:item_updated, updated_item})

  # Assert the LiveView picked up the change
  assert render(view) =~ "Updated Name"
end
```

### Testing PubSub Subscription

```elixir
test "subscribes to updates on mount", %{conn: conn} do
  {:ok, _view, _html} = live(conn, ~p"/items")

  # Create an item (which broadcasts via PubSub in the context module)
  {:ok, new_item} = MyApp.Items.create_item(%{name: "Broadcast Test"})

  # The view should automatically receive the broadcast
  # Give it a moment to process
  assert eventually(fn ->
    {:ok, _view, html} = live(conn, ~p"/items")
    html =~ "Broadcast Test"
  end)
end
```

### Testing Cross-LiveView Communication

```elixir
test "creating item on one view updates another", %{conn: conn} do
  # Mount the list view
  {:ok, list_view, _html} = live(conn, ~p"/items")

  # Mount the create view in another connection
  {:ok, create_view, _html} = live(conn, ~p"/items/new")

  # Create item via the form
  create_view
  |> form("#item-form", item: %{name: "Cross-View Item"})
  |> render_submit()

  # The list view should have received the PubSub broadcast
  assert render(list_view) =~ "Cross-View Item"
end
```

---

## Testing JS Hooks Behavior

JS hooks execute in the browser, so they can't be directly tested with LiveViewTest. However, you can test the server-side contracts.

### Testing push_event from Server

```elixir
test "pushes chart data event on mount", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/dashboard")

  # Assert push_event was called (check via render effect)
  # The push_event data appears in the rendered DOM as a phx-hook data attribute
  assert has_element?(view, "#chart[phx-hook=Chart]")
end
```

### Testing handleEvent Registration

```elixir
test "handles highlight event from JS hook", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/editor")

  # Simulate the event a JS hook would push
  result = render_hook(view, "highlight_line", %{"line" => 42})
  assert result =~ "line-42-highlighted"
end
```

### Testing render_hook

```elixir
test "infinite scroll loads more items", %{conn: conn} do
  for i <- 1..50, do: insert(:item, name: "Item #{i}")

  {:ok, view, html} = live(conn, ~p"/items")

  # Initial load shows first 20
  assert Enum.count(Regex.scan(~r/Item \d+/, html)) == 20

  # Simulate the InfiniteScroll hook pushing "load-more"
  html = render_hook(view, "load-more", %{})
  assert Enum.count(Regex.scan(~r/Item \d+/, html)) == 40
end
```

### End-to-End Testing with Wallaby (Browser Tests)

For true JS hook testing, use Wallaby or Playwright:

```elixir
# test/e2e/chart_test.exs
defmodule MyAppWeb.ChartE2ETest do
  use ExUnit.Case
  use Wallaby.Feature

  @tag :e2e
  feature "chart renders with data", %{session: session} do
    session
    |> visit("/dashboard")
    |> assert_has(css("#chart canvas"))
    |> find(css("#chart"))
    |> assert_text("Sales Data")
  end
end
```

---

## Testing Async Operations

### Testing assign_async

```elixir
test "loads stats asynchronously", %{conn: conn} do
  {:ok, view, html} = live(conn, ~p"/dashboard")

  # Initially shows loading state
  assert html =~ "Loading stats..."

  # Wait for async to complete (send_update triggers render)
  # Process.sleep is a pragmatic approach for async tests
  assert eventually(fn ->
    render(view) =~ "Total: "
  end)
end
```

### Testing start_async + handle_async

```elixir
test "generates report asynchronously", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/reports/new")

  # Trigger report generation
  view |> element("#generate-btn") |> render_click()

  # Should show loading state
  assert render(view) =~ "Generating report..."

  # Wait for completion
  assert eventually(fn ->
    html = render(view)
    html =~ "Report ready" and not (html =~ "Generating report...")
  end)
end
```

### Testing Async Error Handling

```elixir
test "handles async failure gracefully", %{conn: conn} do
  # Set up a condition that causes the async operation to fail
  Mox.expect(MyApp.ExternalServiceMock, :fetch_data, fn -> {:error, :timeout} end)

  {:ok, view, _html} = live(conn, ~p"/dashboard")

  assert eventually(fn ->
    render(view) =~ "Failed to load"
  end)
end
```

### Helper: eventually/1

```elixir
# test/support/test_helpers.ex
defmodule MyApp.TestHelpers do
  def eventually(func, timeout \\ 2000, interval \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_eventually(func, deadline, interval)
  end

  defp do_eventually(func, deadline, interval) do
    if func.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(interval)
        do_eventually(func, deadline, interval)
      else
        false
      end
    end
  end
end
```

---

## Testing LiveView Navigation

### Testing live_patch

```elixir
test "filtering patches URL and updates content", %{conn: conn} do
  active = insert(:item, status: :active)
  inactive = insert(:item, status: :inactive)

  {:ok, view, html} = live(conn, ~p"/items")
  assert html =~ active.name
  assert html =~ inactive.name

  # Click filter link (live_patch)
  view |> element("a", "Active Only") |> render_click()
  assert_patch(view, ~p"/items?status=active")

  html = render(view)
  assert html =~ active.name
  refute html =~ inactive.name
end
```

### Testing live_navigate

```elixir
test "clicking item navigates to show page", %{conn: conn, item: item} do
  {:ok, view, _html} = live(conn, ~p"/items")

  view |> element("#items-#{item.id} a", item.name) |> render_click()
  assert_redirect(view, ~p"/items/#{item}")
end
```

### Testing Redirects After Actions

```elixir
test "deleting last item redirects to empty state", %{conn: conn} do
  item = insert(:item)

  {:ok, view, _html} = live(conn, ~p"/items/#{item}")

  {:ok, _view, html} =
    view
    |> element("button", "Delete")
    |> render_click()
    |> follow_redirect(conn, ~p"/items")

  assert html =~ "No items yet"
end
```

---

## Testing Streams

### Verifying Stream Contents

```elixir
test "streams display all items", %{conn: conn} do
  items = for i <- 1..5, do: insert(:item, name: "Item #{i}")

  {:ok, view, _html} = live(conn, ~p"/items")

  for item <- items do
    assert has_element?(view, "#items-#{item.id}")
  end
end
```

### Testing Stream Insert

```elixir
test "new item appears in stream via PubSub", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/items")

  {:ok, new_item} = MyApp.Items.create_item(%{name: "Stream Insert Test"})

  assert has_element?(view, "#items-#{new_item.id}")
  assert render(view) =~ "Stream Insert Test"
end
```

### Testing Stream Delete

```elixir
test "deleted item removed from stream", %{conn: conn, item: item} do
  {:ok, view, _html} = live(conn, ~p"/items")
  assert has_element?(view, "#items-#{item.id}")

  view
  |> element("#items-#{item.id} button[phx-click=delete]")
  |> render_click()

  refute has_element?(view, "#items-#{item.id}")
end
```

### Testing Stream Reset

```elixir
test "search resets stream with filtered results", %{conn: conn} do
  insert(:item, name: "Elixir Book")
  insert(:item, name: "Phoenix Guide")
  insert(:item, name: "Elixir Course")

  {:ok, view, _html} = live(conn, ~p"/items")

  view
  |> form("#search-form", q: "Elixir")
  |> render_change()

  html = render(view)
  assert html =~ "Elixir Book"
  assert html =~ "Elixir Course"
  refute html =~ "Phoenix Guide"
end
```

---

## ExUnit Setup Patterns

### Using describe + setup

```elixir
defmodule MyAppWeb.ItemLive.IndexTest do
  use MyAppWeb.ConnCase, async: true

  describe "unauthenticated" do
    test "redirects to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/items")
    end
  end

  describe "authenticated" do
    setup [:register_and_log_in_user, :create_items]

    test "lists items", %{conn: conn, items: items} do
      {:ok, _view, html} = live(conn, ~p"/items")
      for item <- items, do: assert(html =~ item.name)
    end

    test "creates new item", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/items/new")
      # ...
    end
  end

  describe "admin" do
    setup [:register_and_log_in_admin]

    test "shows admin controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/items")
      assert html =~ "Admin Panel"
    end
  end

  defp create_items(%{conn: conn}) do
    items = for i <- 1..3, do: insert(:item, name: "Item #{i}")
    %{items: items}
  end
end
```

### Shared Setup Helpers

```elixir
# test/support/live_view_helpers.ex
defmodule MyAppWeb.LiveViewHelpers do
  import Phoenix.LiveViewTest
  import MyApp.Factory

  def register_and_log_in_user(%{conn: conn}) do
    user = insert(:user)
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  def register_and_log_in_admin(%{conn: conn}) do
    admin = insert(:user, role: :admin)
    conn = log_in_user(conn, admin)
    %{conn: conn, user: admin}
  end

  defp log_in_user(conn, user) do
    token = MyApp.Accounts.generate_user_session_token(user)
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
```

### Async Testing

Mark tests as `async: true` when they don't share global state:

```elixir
# Safe for async — each test gets its own DB sandbox
use MyAppWeb.ConnCase, async: true

# NOT safe for async — tests share a GenServer or ETS table
use MyAppWeb.ConnCase, async: false
```

---

## Factory Patterns for Test Data

### Using ExMachina

```elixir
# test/support/factory.ex
defmodule MyApp.Factory do
  use ExMachina.Ecto, repo: MyApp.Repo

  def user_factory do
    %MyApp.Accounts.User{
      name: sequence(:name, &"User #{&1}"),
      email: sequence(:email, &"user#{&1}@example.com"),
      hashed_password: Bcrypt.hash_pwd_salt("password123")
    }
  end

  def item_factory do
    %MyApp.Items.Item{
      name: sequence(:item_name, &"Item #{&1}"),
      description: "A test item",
      price: Decimal.new("9.99"),
      status: :active,
      user: build(:user)
    }
  end

  def item_with_tags_factory do
    %MyApp.Items.Item{
      name: sequence(:item_name, &"Tagged Item #{&1}"),
      tags: build_list(3, :tag),
      user: build(:user)
    }
  end

  def tag_factory do
    %MyApp.Items.Tag{
      name: sequence(:tag_name, &"tag-#{&1}")
    }
  end

  # Trait-like patterns
  def admin_factory do
    struct!(user_factory(), %{role: :admin})
  end
end
```

### Without ExMachina (Custom Factories)

```elixir
defmodule MyApp.Factory do
  alias MyApp.Repo

  def insert(type, attrs \\ %{})

  def insert(:user, attrs) do
    defaults = %{
      name: "User #{System.unique_integer([:positive])}",
      email: "user#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123")
    }

    %MyApp.Accounts.User{}
    |> Ecto.Changeset.change(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  def insert(:item, attrs) do
    user = attrs[:user] || insert(:user)
    defaults = %{
      name: "Item #{System.unique_integer([:positive])}",
      price: Decimal.new("9.99"),
      status: :active,
      user_id: user.id
    }

    %MyApp.Items.Item{}
    |> Ecto.Changeset.change(Map.merge(defaults, Map.delete(attrs, :user)))
    |> Repo.insert!()
  end
end
```

### Fixture Files for Uploads

```
test/
  fixtures/
    photo.jpg      # small valid JPEG for upload tests
    document.pdf   # small valid PDF
    too_large.bin  # file exceeding max size
```

```elixir
# Usage in tests
defp fixture_path(filename), do: Path.join(["test", "fixtures", filename])

test "uploads photo", %{conn: conn} do
  {:ok, view, _} = live(conn, ~p"/profile/edit")
  photo = file_input(view, "#form", :avatar, [
    %{name: "photo.jpg", content: File.read!(fixture_path("photo.jpg")),
      size: File.stat!(fixture_path("photo.jpg")).size, type: "image/jpeg"}
  ])
  render_upload(photo, "photo.jpg")
  # ...
end
```

---

## Test Helpers and Utilities

### Custom Assertions

```elixir
defmodule MyAppWeb.LiveViewAssertions do
  import ExUnit.Assertions
  import Phoenix.LiveViewTest

  def assert_flash(view, kind, message) do
    html = render(view)
    assert html =~ message,
      "Expected flash #{kind}: #{message}\nGot HTML: #{html}"
  end

  def assert_stream_count(view, stream_name, expected_count) do
    html = render(view)
    # Count stream container children
    actual = Regex.scan(~r/id="#{stream_name}-\d+"/, html) |> length()
    assert actual == expected_count,
      "Expected #{expected_count} items in #{stream_name}, got #{actual}"
  end

  def assert_disabled(view, selector) do
    assert has_element?(view, "#{selector}[disabled]")
  end

  def refute_disabled(view, selector) do
    refute has_element?(view, "#{selector}[disabled]")
  end
end
```

### Waiting for Async Results

```elixir
defmodule MyApp.TestHelpers do
  @doc "Polls until func returns truthy or timeout (ms) is reached."
  def eventually(func, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2000)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(func, deadline, interval)
  end

  defp poll(func, deadline, interval) do
    case func.() do
      falsy when falsy in [false, nil] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval)
          poll(func, deadline, interval)
        else
          flunk("eventually/1 timed out")
        end

      truthy ->
        truthy
    end
  end
end
```

### Debug Helper: Print Current DOM

```elixir
# Add to test/support/test_helpers.ex
def debug_view(view) do
  html = render(view) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  IO.puts("\n=== DEBUG VIEW ===\n#{html}\n=== END DEBUG ===\n")
  view
end

# Usage in test
{:ok, view, _html} = live(conn, ~p"/items")
view = debug_view(view)  # prints current HTML
```
