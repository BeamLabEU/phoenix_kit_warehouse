defmodule PhoenixKitWarehouse.Web.TransferFormLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Test.Repo
  alias PhoenixKitWarehouse.Transfer
  alias PhoenixKitWarehouse.Transfers
  alias PhoenixKitLocations.Locations

  setup do
    Repo.delete_all(Transfer)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "tr-form-#{System.unique_integer([:positive])}@example.com"

  defp create_admin_user do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => unique_email(),
        "password" => "password123456789",
        "first_name" => "Admin",
        "last_name" => "User"
      })

    {:ok, user} = PhoenixKit.Users.Auth.admin_confirm_user(user)
    {:ok, _} = PhoenixKit.Users.Roles.promote_to_admin(user)
    PhoenixKit.Users.Auth.get_user!(user.uuid)
  end

  defp log_in_admin(conn, user) do
    token = PhoenixKit.Users.Auth.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  defp edit_path(uuid), do: PhoenixKit.Utils.Routes.path("/admin/warehouse/transfers/#{uuid}")

  defp items_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/transfers/#{uuid}/items")

  defp files_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/transfers/#{uuid}/files")

  defp comments_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/transfers/#{uuid}/comments")

  # Creates real Location records tagged with a fresh warehouse LocationType
  # and marks that type as the warehouse type. The per-test sandbox rolls
  # both the rows and the setting back, so no manual cleanup is needed.
  defp setup_warehouses!(names) do
    {:ok, type} =
      Locations.create_location_type(%{
        name: "TR Form WH Type #{System.unique_integer([:positive])}"
      })

    locations =
      Enum.map(names, fn name ->
        {:ok, loc} = Locations.create_location(%{name: name, status: "active"})
        Locations.sync_location_types(loc.uuid, [type.uuid])
        loc
      end)

    StockLedger.set_warehouse_location_type_uuid(type.uuid)
    locations
  end

  defp seed_stock!(item_uuid, qty, location_uuid) do
    {:ok, _stock} =
      StockLedger.upsert_quantity(item_uuid, Decimal.new(qty), location_uuid: location_uuid)
  end

  defp sample_line(item_uuid, opts) do
    qty = Keyword.get(opts, :qty, "0")

    %{
      "item_uuid" => item_uuid,
      "name" => "Material #{System.unique_integer([:positive])}",
      "sku" => "MAT-#{System.unique_integer([:positive])}",
      "unit" => "piece",
      "catalogue_uuid" => Ecto.UUID.generate(),
      "transfer_quantity" => qty
    }
  end

  defp create_draft(attrs \\ %{}) do
    {:ok, transfer} = Transfers.create_transfer(attrs)
    transfer
  end

  defp create_draft_with_lines(source, destination, item_uuid, qty) do
    create_draft(%{
      source_location_uuid: source.uuid,
      destination_location_uuid: destination.uuid,
      lines: [sample_line(item_uuid, qty: qty)]
    })
  end

  defp create_draft_with_two_lines(source, destination, item_a, item_b) do
    create_draft(%{
      source_location_uuid: source.uuid,
      destination_location_uuid: destination.uuid,
      lines: [sample_line(item_a, qty: "2"), sample_line(item_b, qty: "3")]
    })
  end

  # Ships a fresh draft (seeding `stock_qty` at the source first) via a
  # direct context call, bypassing the LiveView — the common starting point
  # for every `:receive`/`:cancel-from-in_transit` UI test.
  defp ship!(source, destination, item_uuid, transfer_qty, stock_qty \\ "10") do
    actor_uuid = create_admin_user().uuid
    seed_stock!(item_uuid, stock_qty, source.uuid)
    transfer = create_draft_with_lines(source, destination, item_uuid, transfer_qty)
    {:ok, shipped} = Transfers.ship_transfer(transfer, actor_uuid)
    shipped
  end

  # ---------------------------------------------------------------------------
  # Draft form — General tab
  # ---------------------------------------------------------------------------

  describe "draft transfer form" do
    test "renders Save draft, Cancel and Ship buttons for a draft", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_draft()

      {:ok, lv, _html} = live(conn, edit_path(transfer.uuid))

      assert has_element?(lv, "button", "Save draft")
      assert has_element?(lv, "button[phx-click='cancel']", "Cancel")
      assert has_element?(lv, "button[phx-click='ship']", "Ship")
      refute has_element?(lv, "button[phx-click='receive']")
    end

    test "shows General tab by default", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(transfer.uuid))

      assert html =~ "General"
    end

    test "shows the transfer number in page heading", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(transfer.uuid))

      assert html =~ "#TR-#{transfer.number}"
    end
  end

  # ---------------------------------------------------------------------------
  # Tab navigation
  # ---------------------------------------------------------------------------

  describe "tab navigation" do
    test "Items, Files and Comments tab links are present", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(transfer.uuid))

      assert html =~ "Items"
      assert html =~ "Files"
      assert html =~ "Comments"
    end

    test "items tab shows empty state when no lines", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_draft()

      {:ok, _lv, html} = live(conn, items_path(transfer.uuid))

      assert html =~ "No items yet"
    end

    test "Files tab route is reachable and renders loading or unavailable state", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_draft()

      {:ok, lv, _html} = live(conn, files_path(transfer.uuid))

      assert has_element?(lv, "a.tab-active", "Files")
    end

    test "Comments tab route is reachable", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_draft()

      {:ok, lv, _html} = live(conn, comments_path(transfer.uuid))

      assert has_element?(lv, "a.tab-active", "Comments")
    end
  end

  # ---------------------------------------------------------------------------
  # Warehouse selectors
  # ---------------------------------------------------------------------------

  describe "warehouse selectors" do
    test "renders source and destination selects on a draft", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      [loc_a, _loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      transfer = create_draft(%{source_location_uuid: loc_a.uuid})

      {:ok, _lv, html} = live(conn, edit_path(transfer.uuid))

      assert html =~ ~s(phx-change="set_source_location")
      assert html =~ ~s(phx-change="set_destination_location")
      assert html =~ "TR Site A"
      assert html =~ "TR Site B"
    end

    test "changing the source warehouse persists source_location_uuid", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      [loc_a, loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      transfer = create_draft()

      {:ok, lv, _html} = live(conn, edit_path(transfer.uuid))

      lv
      |> element("form[phx-change='set_source_location']")
      |> render_change(%{"location_uuid" => loc_a.uuid})

      {:ok, updated} = Transfers.get_transfer(transfer.uuid)
      assert updated.source_location_uuid == loc_a.uuid
      assert updated.destination_location_uuid == nil

      lv
      |> element("form[phx-change='set_destination_location']")
      |> render_change(%{"location_uuid" => loc_b.uuid})

      {:ok, updated2} = Transfers.get_transfer(transfer.uuid)
      assert updated2.destination_location_uuid == loc_b.uuid
    end

    test "both warehouses show as read-only text once shipped", %{conn: conn} do
      item_uuid = Ecto.UUID.generate()
      [loc_a, loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      shipped = ship!(loc_a, loc_b, item_uuid, "5")

      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, edit_path(shipped.uuid))

      refute html =~ ~s(phx-change="set_source_location")
      refute html =~ ~s(phx-change="set_destination_location")
      assert html =~ "TR Site A"
      assert html =~ "TR Site B"
    end
  end

  # ---------------------------------------------------------------------------
  # Items tab — transfer_quantity editing
  # ---------------------------------------------------------------------------

  describe "transfer_quantity editing" do
    test "keeper can edit transfer_quantity on a draft line", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      [loc_a, loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      item_uuid = Ecto.UUID.generate()
      transfer = create_draft_with_lines(loc_a, loc_b, item_uuid, "2")

      {:ok, lv, _html} = live(conn, items_path(transfer.uuid))

      lv
      |> element("#tr-qty-form-0")
      |> render_change(%{"index" => "0", "transfer_quantity" => "7"})

      html = render(lv)
      assert html =~ ~r/7/
    end

    test "transfer_quantity is read-only once in_transit", %{conn: conn} do
      item_uuid = Ecto.UUID.generate()
      [loc_a, loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      shipped = ship!(loc_a, loc_b, item_uuid, "5")

      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, items_path(shipped.uuid))

      refute html =~ "tr-qty-form"
      refute html =~ ~s(name="transfer_quantity")
    end
  end

  # ---------------------------------------------------------------------------
  # Line index guards — a tampered/malformed phx-value-index (or hidden
  # "index" form field) must neither crash the LiveView nor silently touch
  # the wrong line. `render_click`/`render_change`'s explicit value map
  # overrides the element's real DOM value, simulating a tampered client.
  # ---------------------------------------------------------------------------

  describe "line index guards" do
    test "remove_line ignores a non-numeric index instead of crashing", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      [loc_a, loc_b] = setup_warehouses!(["TR Idx A", "TR Idx B"])
      item_a = Ecto.UUID.generate()
      item_b = Ecto.UUID.generate()
      transfer = create_draft_with_two_lines(loc_a, loc_b, item_a, item_b)

      {:ok, lv, _html} = live(conn, items_path(transfer.uuid))

      lv
      |> element("button[phx-click='remove_line'][phx-value-index='0']")
      |> render_click(%{"index" => "not-a-number"})

      {:ok, updated} = Transfers.get_transfer(transfer.uuid)
      assert length(updated.lines) == 2
    end

    test "remove_line ignores a negative index instead of deleting the last line", %{
      conn: conn
    } do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      [loc_a, loc_b] = setup_warehouses!(["TR Idx C", "TR Idx D"])
      item_a = Ecto.UUID.generate()
      item_b = Ecto.UUID.generate()
      transfer = create_draft_with_two_lines(loc_a, loc_b, item_a, item_b)

      {:ok, lv, _html} = live(conn, items_path(transfer.uuid))

      # Real DOM index is 0 (first line); a negative index is otherwise a
      # valid integer (String.to_integer/1 wouldn't reject it) but
      # List.delete_at/2 treats it as "from the end", which would silently
      # delete item_b's line instead of item_a's.
      lv
      |> element("button[phx-click='remove_line'][phx-value-index='0']")
      |> render_click(%{"index" => "-1"})

      {:ok, updated} = Transfers.get_transfer(transfer.uuid)
      assert Enum.map(updated.lines, & &1["item_uuid"]) == [item_a, item_b]
    end

    test "set_transfer_qty ignores a negative index instead of updating the wrong line", %{
      conn: conn
    } do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      [loc_a, loc_b] = setup_warehouses!(["TR Idx E", "TR Idx F"])
      item_a = Ecto.UUID.generate()
      item_b = Ecto.UUID.generate()
      transfer = create_draft_with_two_lines(loc_a, loc_b, item_a, item_b)

      {:ok, lv, _html} = live(conn, items_path(transfer.uuid))

      lv
      |> element("#tr-qty-form-0")
      |> render_change(%{"index" => "-1", "transfer_quantity" => "99"})

      {:ok, updated} = Transfers.get_transfer(transfer.uuid)
      refute Enum.any?(updated.lines, &(&1["transfer_quantity"] == "99"))
    end

    test "set_transfer_qty ignores a non-numeric index instead of crashing", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      [loc_a, loc_b] = setup_warehouses!(["TR Idx G", "TR Idx H"])
      item_a = Ecto.UUID.generate()
      item_b = Ecto.UUID.generate()
      transfer = create_draft_with_two_lines(loc_a, loc_b, item_a, item_b)

      {:ok, lv, _html} = live(conn, items_path(transfer.uuid))

      lv
      |> element("#tr-qty-form-0")
      |> render_change(%{"index" => "not-a-number", "transfer_quantity" => "99"})

      {:ok, updated} = Transfers.get_transfer(transfer.uuid)
      refute Enum.any?(updated.lines, &(&1["transfer_quantity"] == "99"))
    end
  end

  # ---------------------------------------------------------------------------
  # Ship action
  # ---------------------------------------------------------------------------

  describe "ship action" do
    test "clicking Ship transitions to in_transit and decreases source stock", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      [loc_a, loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", loc_a.uuid)
      transfer = create_draft_with_lines(loc_a, loc_b, item_uuid, "4")

      {:ok, lv, _html} = live(conn, edit_path(transfer.uuid))

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv |> element("button[phx-click='ship']") |> render_click()

      assert String.contains?(redirect_to, "/admin/warehouse/transfers")

      {:ok, shipped} = Transfers.get_transfer(transfer.uuid)
      assert shipped.status == "in_transit"
      assert shipped.shipped_at != nil

      assert Decimal.equal?(
               StockLedger.get_quantity(item_uuid, loc_a.uuid),
               Decimal.new("6")
             )
    end

    test "shipping without both warehouses set shows an error and stays draft", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      item_uuid = Ecto.UUID.generate()
      transfer = create_draft(%{lines: [sample_line(item_uuid, qty: "4")]})

      {:ok, lv, _html} = live(conn, edit_path(transfer.uuid))

      html = lv |> element("button[phx-click='ship']") |> render_click()

      assert html =~ "select two different warehouses"

      {:ok, still_draft} = Transfers.get_transfer(transfer.uuid)
      assert still_draft.status == "draft"
    end

    test "shipping more than available stock shows an error and stock is unchanged", %{
      conn: conn
    } do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      [loc_a, loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "3", loc_a.uuid)
      transfer = create_draft_with_lines(loc_a, loc_b, item_uuid, "5")

      {:ok, lv, _html} = live(conn, edit_path(transfer.uuid))

      html = lv |> element("button[phx-click='ship']") |> render_click()

      assert html =~ "Insufficient stock"

      {:ok, still_draft} = Transfers.get_transfer(transfer.uuid)
      assert still_draft.status == "draft"

      assert Decimal.equal?(
               StockLedger.get_quantity(item_uuid, loc_a.uuid),
               Decimal.new("3")
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Receive action
  # ---------------------------------------------------------------------------

  describe "receive action" do
    test "renders Receive and Cancel buttons, and an In transit badge, when in_transit", %{
      conn: conn
    } do
      item_uuid = Ecto.UUID.generate()
      [loc_a, loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      shipped = ship!(loc_a, loc_b, item_uuid, "5")

      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, lv, html} = live(conn, edit_path(shipped.uuid))

      assert html =~ "In transit"
      assert has_element?(lv, "button[phx-click='receive']", "Receive")
      assert has_element?(lv, "button[phx-click='open_cancel_confirm']", "Cancel")
      refute has_element?(lv, "button[phx-click='ship']")
    end

    test "clicking Receive transitions to done and increases destination stock", %{conn: conn} do
      item_uuid = Ecto.UUID.generate()
      [loc_a, loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      shipped = ship!(loc_a, loc_b, item_uuid, "5")

      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, edit_path(shipped.uuid))

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv |> element("button[phx-click='receive']") |> render_click()

      assert String.contains?(redirect_to, "/admin/warehouse/transfers")

      {:ok, received} = Transfers.get_transfer(shipped.uuid)
      assert received.status == "done"
      assert received.received_at != nil

      assert Decimal.equal?(
               StockLedger.get_quantity(item_uuid, loc_b.uuid),
               Decimal.new("5")
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Cancel action
  # ---------------------------------------------------------------------------

  describe "cancel action" do
    test "cancelling a draft fires directly, without a confirmation modal", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_draft()

      {:ok, lv, _html} = live(conn, edit_path(transfer.uuid))

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv |> element("button[phx-click='cancel']") |> render_click()

      assert String.contains?(redirect_to, "/admin/warehouse/transfers")

      {:ok, cancelled} = Transfers.get_transfer(transfer.uuid)
      assert cancelled.status == "cancelled"
    end

    test "cancelling an in_transit transfer requires confirming the modal, then reverses stock",
         %{conn: conn} do
      item_uuid = Ecto.UUID.generate()
      [loc_a, loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      shipped = ship!(loc_a, loc_b, item_uuid, "4", "10")

      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, edit_path(shipped.uuid))

      # Stock was decremented by the ship — 10 - 4 = 6 at the source.
      assert Decimal.equal?(StockLedger.get_quantity(item_uuid, loc_a.uuid), Decimal.new("6"))

      # Opening the page doesn't cancel anything yet.
      refute has_element?(lv, "button[phx-click='cancel']")

      lv |> element("button[phx-click='open_cancel_confirm']") |> render_click()

      assert has_element?(lv, "button[phx-click='cancel']", "Cancel transfer")

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv
               |> element("button[phx-click='cancel']", "Cancel transfer")
               |> render_click()

      assert String.contains?(redirect_to, "/admin/warehouse/transfers")

      {:ok, cancelled} = Transfers.get_transfer(shipped.uuid)
      assert cancelled.status == "cancelled"

      # The full 4 units are credited back — source is at its pre-ship level again.
      assert Decimal.equal?(StockLedger.get_quantity(item_uuid, loc_a.uuid), Decimal.new("10"))

      %{entries: entries} = PhoenixKit.Activity.list(action: "warehouse.transfer.cancelled")
      assert Enum.any?(entries, &(&1.resource_uuid == shipped.uuid))
    end

    test "cancel is unavailable once done", %{conn: conn} do
      item_uuid = Ecto.UUID.generate()
      [loc_a, loc_b] = setup_warehouses!(["TR Site A", "TR Site B"])
      shipped = ship!(loc_a, loc_b, item_uuid, "5")
      admin_uuid = create_admin_user().uuid
      {:ok, received} = Transfers.receive_transfer(shipped, admin_uuid)

      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, edit_path(received.uuid))

      refute html =~ ~s(phx-click="cancel")
      refute html =~ ~s(phx-click="open_cancel_confirm")
      assert html =~ "Done"
    end
  end

  # ---------------------------------------------------------------------------
  # Terminal state — correction (admin only)
  # ---------------------------------------------------------------------------

  describe "terminal state" do
    test "admin sees Save correction on a cancelled transfer", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_draft()
      {:ok, cancelled} = Transfers.cancel_transfer(transfer, admin.uuid)

      {:ok, lv, _html} = live(conn, edit_path(cancelled.uuid))

      assert has_element?(lv, "button[phx-click='save_correction']", "Save correction")
    end

    test "non-admin sees an info banner instead of edit controls", %{conn: conn} do
      admin = create_admin_user()
      transfer = create_draft()
      {:ok, cancelled} = Transfers.cancel_transfer(transfer, admin.uuid)

      {:ok, user} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => unique_email(),
          "password" => "password123456789",
          "first_name" => "Regular",
          "last_name" => "User"
        })

      {:ok, user} = PhoenixKit.Users.Auth.admin_confirm_user(user)
      conn = log_in_admin(conn, user)

      {:ok, _lv, html} = live(conn, edit_path(cancelled.uuid))

      assert html =~ "cancelled"
      refute html =~ ~s(phx-click="save_correction")
    end
  end

  # ---------------------------------------------------------------------------
  # Manual link add/remove (upstream source_refs)
  # ---------------------------------------------------------------------------

  describe "manual link add/remove" do
    test "attaching a customer order via the link picker adds it", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_draft()
      customer_order = PhoenixKitWarehouse.Test.Fixtures.insert_order!()

      {:ok, lv, _html} = live(conn, edit_path(transfer.uuid))

      lv |> element("button[phx-click='open_link_picker']") |> render_click()

      lv
      |> element(
        "input[phx-click='source_picker_toggle'][phx-value-uuid='#{customer_order.uuid}']"
      )
      |> render_click()

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ "##{customer_order.data["order_number"]}"
      {:ok, updated} = Transfers.get_transfer(transfer.uuid)
      assert %{"type" => "order", "uuid" => customer_order.uuid} in updated.source_refs
    end

    test "removing an attached reference detaches it", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      customer_order = PhoenixKitWarehouse.Test.Fixtures.insert_order!()

      transfer =
        create_draft(%{source_refs: [%{"type" => "order", "uuid" => customer_order.uuid}]})

      {:ok, lv, html} = live(conn, edit_path(transfer.uuid))
      assert html =~ "##{customer_order.data["order_number"]}"

      html =
        lv
        |> element(
          "button[phx-click='remove_source_ref'][phx-value-uuid='#{customer_order.uuid}']"
        )
        |> render_click()

      refute html =~ "##{customer_order.data["order_number"]}"
      {:ok, updated} = Transfers.get_transfer(transfer.uuid)
      assert updated.source_refs == []
    end
  end
end
