defmodule PhoenixKitWarehouse.Web.StockLiveTest do
  use PhoenixKitWarehouse.LiveCase, async: false
  import Phoenix.LiveViewTest

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.MinStockSettings
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Test.MigrationsRunner
  alias PhoenixKitWarehouse.Test.Repo

  # `phoenix_kit_warehouse_min_stock` is created by this package's OWN
  # versioned migration module (see `PhoenixKitWarehouse.Migrations.Postgres`
  # / T16), not by core PhoenixKit's `ensure_current/2` bootstrap that
  # `test_helper.exs` runs once at suite start. Bringing it up here — inside
  # each test's own sandboxed transaction, same trick as
  # `PhoenixKitWarehouse.MinStockSettingsTest` / `DeficitsTest` — is
  # idempotent (`IF NOT EXISTS` DDL) and rolls back with everything else at
  # `on_exit`. Runs for every test in this file (harmless no-op DDL for the
  # pre-existing tests that don't touch min stock).
  setup do
    Ecto.Migrator.up(Repo, :os.system_time(:microsecond), MigrationsRunner, log: false)
    :ok
  end

  defp email, do: "wh-#{System.unique_integer([:positive])}@example.com"

  defp admin do
    {:ok, u} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => email(),
        "password" => "password123456789",
        "first_name" => "W",
        "last_name" => "A"
      })

    {:ok, u} = PhoenixKit.Users.Auth.admin_confirm_user(u)
    {:ok, _} = PhoenixKit.Users.Roles.promote_to_admin(u)
    PhoenixKit.Users.Auth.get_user!(u.uuid)
  end

  defp login(conn, u) do
    t = PhoenixKit.Users.Auth.generate_user_session_token(u)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, t)
  end

  defp path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse")

  defp create_catalogue! do
    {:ok, cat} =
      Catalogue.create_catalogue(%{
        name: "Stock Scope Test #{System.unique_integer([:positive])}"
      })

    cat
  end

  defp create_item!(cat, name) do
    {:ok, item} =
      Catalogue.create_item(%{
        name: name,
        catalogue_uuid: cat.uuid,
        base_price: "10.00",
        status: "active",
        sku: "SK-#{System.unique_integer([:positive])}"
      })

    item
  end

  # Creates real Location records tagged with a fresh warehouse LocationType and
  # marks that type as the warehouse type. The per-test sandbox rolls both the
  # rows and the setting back, so no manual cleanup is needed.
  defp setup_warehouses!(names) do
    {:ok, type} =
      Locations.create_location_type(%{
        name: "Stock WH Type #{System.unique_integer([:positive])}"
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

  test "default view is grouped — no parity toolbar", %{conn: conn} do
    {:ok, _lv, html} = live(login(conn, admin()), path())
    refute html =~ ~s(phx-click="show_column_modal")
  end

  test "switching to flat reveals the parity toolbar and persists the choice", %{conn: conn} do
    a = admin()
    {:ok, lv, _} = live(login(conn, a), path())
    html = render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))
    assert html =~ ~s(phx-change="search")
    assert html =~ ~s(phx-click="show_column_modal")

    cfg = PhoenixKitWarehouse.ViewConfigs.get_view_config(a.uuid, "warehouse_stock")
    assert Map.get(cfg, "stock_view") == "flat"

    # persisted: a fresh mount opens directly in flat
    {:ok, _lv2, html2} = live(login(conn, a), path())
    assert html2 =~ ~s(phx-click="show_column_modal")
  end

  test "column modal save persists columns under warehouse_stock", %{conn: conn} do
    a = admin()
    {:ok, lv, _} = live(login(conn, a), path())
    render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))
    render_click(lv, "add_column", %{"column_id" => "sku"})

    render_click(lv, "update_table_columns", %{
      "column_order" => "item,catalogue,quantity,total_value,sku"
    })

    cfg = PhoenixKitWarehouse.ViewConfigs.get_view_config(a.uuid, "warehouse_stock")
    assert "sku" in Map.get(cfg, "columns", [])
  end

  describe "warehouse scope selector" do
    test "no warehouse select when no warehouse location type is configured", %{conn: conn} do
      StockLedger.set_warehouse_location_type_uuid(nil)
      {:ok, _lv, html} = live(login(conn, admin()), path())
      refute html =~ ~s(phx-change="set_warehouse_scope")
    end

    test "renders a select with an All warehouses option plus configured warehouses", %{
      conn: conn
    } do
      [loc_a, loc_b] = setup_warehouses!(["Stock Scope A", "Stock Scope B"])

      {:ok, _lv, html} = live(login(conn, admin()), path())

      assert html =~ ~s(phx-change="set_warehouse_scope")
      assert html =~ "All warehouses"
      assert html =~ loc_a.name
      assert html =~ loc_b.name
    end

    test "selecting a warehouse scopes the Grouped view to that location's items only", %{
      conn: conn
    } do
      a = admin()
      [loc_a, loc_b] = setup_warehouses!(["Stock Scope A", "Stock Scope B"])
      cat = create_catalogue!()
      item_a = create_item!(cat, "Alpha Widget")
      item_b = create_item!(cat, "Beta Widget")

      {:ok, _} = StockLedger.upsert_quantity(item_a.uuid, "4", location_uuid: loc_a.uuid)
      {:ok, _} = StockLedger.upsert_quantity(item_b.uuid, "6", location_uuid: loc_b.uuid)

      {:ok, lv, html} = live(login(conn, a), path())
      assert html =~ "Alpha Widget"
      assert html =~ "Beta Widget"

      html =
        lv
        |> element("form[phx-change='set_warehouse_scope']")
        |> render_change(%{"location_uuid" => loc_a.uuid})

      assert html =~ "Alpha Widget"
      refute html =~ "Beta Widget"

      cfg = PhoenixKitWarehouse.ViewConfigs.get_view_config(a.uuid, "warehouse_stock")
      assert Map.get(cfg, "warehouse_scope") == loc_a.uuid

      # persisted: a fresh mount opens already scoped to loc_a
      {:ok, _lv2, html2} = live(login(conn, a), path())
      assert html2 =~ "Alpha Widget"
      refute html2 =~ "Beta Widget"
    end

    test "the flat view reflects the same warehouse scope as the grouped view", %{conn: conn} do
      a = admin()
      [loc_a, loc_b] = setup_warehouses!(["Stock Scope A", "Stock Scope B"])
      cat = create_catalogue!()
      item_a = create_item!(cat, "Alpha Widget")
      item_b = create_item!(cat, "Beta Widget")

      {:ok, _} = StockLedger.upsert_quantity(item_a.uuid, "4", location_uuid: loc_a.uuid)
      {:ok, _} = StockLedger.upsert_quantity(item_b.uuid, "6", location_uuid: loc_b.uuid)

      {:ok, lv, _html} = live(login(conn, a), path())

      lv
      |> element("form[phx-change='set_warehouse_scope']")
      |> render_change(%{"location_uuid" => loc_b.uuid})

      html = render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))

      assert html =~ "Beta Widget"
      refute html =~ "Alpha Widget"
    end

    test "choosing All warehouses again clears the scope and restores every item", %{conn: conn} do
      a = admin()
      [loc_a, loc_b] = setup_warehouses!(["Stock Scope A", "Stock Scope B"])
      cat = create_catalogue!()
      item_a = create_item!(cat, "Alpha Widget")
      item_b = create_item!(cat, "Beta Widget")

      {:ok, _} = StockLedger.upsert_quantity(item_a.uuid, "4", location_uuid: loc_a.uuid)
      {:ok, _} = StockLedger.upsert_quantity(item_b.uuid, "6", location_uuid: loc_b.uuid)

      {:ok, lv, _html} = live(login(conn, a), path())

      lv
      |> element("form[phx-change='set_warehouse_scope']")
      |> render_change(%{"location_uuid" => loc_a.uuid})

      html =
        lv
        |> element("form[phx-change='set_warehouse_scope']")
        |> render_change(%{"location_uuid" => ""})

      assert html =~ "Alpha Widget"
      assert html =~ "Beta Widget"

      cfg = PhoenixKitWarehouse.ViewConfigs.get_view_config(a.uuid, "warehouse_stock")
      assert Map.get(cfg, "warehouse_scope") == ""
    end
  end

  describe "search (flat view)" do
    # Regression coverage for the search handler now re-slicing the cached
    # :stock_items instead of re-querying build_stock_items/1 on every
    # keystroke — the pipeline (enrich_stock -> apply_global_search -> ...)
    # itself must still filter correctly against that cache.
    test "search filters the flat table down to matching items", %{conn: conn} do
      a = admin()
      cat = create_catalogue!()
      match = create_item!(cat, "Searchable Bolt")
      other = create_item!(cat, "Unrelated Widget")
      {:ok, _} = StockLedger.upsert_quantity(match.uuid, "3")
      {:ok, _} = StockLedger.upsert_quantity(other.uuid, "3")

      {:ok, lv, _html} = live(login(conn, a), path())
      render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))

      html =
        lv
        |> element("form#stock-search")
        |> render_change(%{"search" => "Bolt"})

      assert html =~ "Searchable Bolt"
      refute html =~ "Unrelated Widget"
    end
  end

  # ---------------------------------------------------------------------------
  # Deficit tracking (§5, full variant) — T19
  # ---------------------------------------------------------------------------

  describe "deficit tracking" do
    # Adds a column to the Flat table and persists it, same two-step sequence
    # as the "column modal save persists columns" test above.
    defp add_flat_column(lv, column_id, order_csv) do
      render_click(lv, "add_column", %{"column_id" => column_id})
      render_click(lv, "update_table_columns", %{"column_order" => order_csv})
    end

    test "inline-editing Min. quantity in the Flat view persists via MinStockSettings", %{
      conn: conn
    } do
      a = admin()
      cat = create_catalogue!()
      item = create_item!(cat, "Deficit Widget")
      {:ok, _} = StockLedger.upsert_quantity(item.uuid, "10")

      {:ok, lv, _html} = live(login(conn, a), path())
      render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))
      add_flat_column(lv, "min_quantity", "item,catalogue,quantity,total_value,min_quantity")

      html =
        lv
        |> element("#stock-min-form-#{item.uuid}")
        |> render_change(%{"item_uuid" => item.uuid, "min_quantity" => "6"})

      assert Decimal.equal?(MinStockSettings.get_min_quantity(item.uuid), Decimal.new("6"))
      assert html =~ ~s(value="6")
    end

    test "an item below its configured minimum is badge-flagged and shown by the Deficit filter",
         %{conn: conn} do
      a = admin()
      cat = create_catalogue!()
      low_item = create_item!(cat, "Low Widget")
      ok_item = create_item!(cat, "OK Widget")
      {:ok, _} = StockLedger.upsert_quantity(low_item.uuid, "5")
      {:ok, _} = StockLedger.upsert_quantity(ok_item.uuid, "3")
      # ok_item has no configured minimum — never a deficit, however low its stock.
      {:ok, _} = MinStockSettings.set_min_quantity(low_item.uuid, "10")

      {:ok, lv, _html} = live(login(conn, a), path())
      render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))

      # add_column + toggle_filter build up :temp_selected_columns /
      # :temp_active_filters; only the final update_table_columns commits
      # them to :selected_columns / :active_filters (what rendering and
      # set_filter_value actually read) — same modal flow ColumnModal drives,
      # done here in one shot instead of two (unlike add_flat_column/3 above,
      # which commits after every single column and would reset the filter
      # toggle before it's ever persisted).
      render_click(lv, "add_column", %{"column_id" => "available"})
      render_click(lv, "add_column", %{"column_id" => "deficit"})
      render_click(lv, "toggle_filter", %{"column_id" => "deficit"})

      html =
        render_click(lv, "update_table_columns", %{
          "column_order" => "item,catalogue,quantity,total_value,available,deficit"
        })

      assert html =~ "Low Widget"
      assert html =~ "OK Widget"
      assert html =~ "badge-error"

      filtered =
        lv
        |> element("form[phx-change='set_filter_value']")
        |> render_change(%{"column_id" => "deficit", "value" => "yes"})

      assert filtered =~ "Low Widget"
      refute filtered =~ "OK Widget"
    end

    test "the Grouped view shows a warning icon next to items below their minimum", %{
      conn: conn
    } do
      a = admin()
      cat = create_catalogue!()
      item = create_item!(cat, "Grouped Deficit Widget")
      {:ok, _} = StockLedger.upsert_quantity(item.uuid, "1")
      {:ok, _} = MinStockSettings.set_min_quantity(item.uuid, "5")

      {:ok, _lv, html} = live(login(conn, a), path())

      assert html =~ "Grouped Deficit Widget"
      assert html =~ "hero-exclamation-triangle"
    end

    test "the Create supplier order button appears only on the deficit row", %{conn: conn} do
      a = admin()
      cat = create_catalogue!()
      low_item = create_item!(cat, "Deficit Button Widget")
      ok_item = create_item!(cat, "Fine Button Widget")
      {:ok, _} = StockLedger.upsert_quantity(low_item.uuid, "1")
      {:ok, _} = StockLedger.upsert_quantity(ok_item.uuid, "20")
      {:ok, _} = MinStockSettings.set_min_quantity(low_item.uuid, "5")

      {:ok, lv, _html} = live(login(conn, a), path())
      render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))

      assert has_element?(
               lv,
               ~s(button[phx-click="create_supplier_order_from_deficit"][phx-value-item_uuid="#{low_item.uuid}"])
             )

      refute has_element?(
               lv,
               ~s(button[phx-click="create_supplier_order_from_deficit"][phx-value-item_uuid="#{ok_item.uuid}"])
             )
    end

    test "an item with a configured minimum but no Stock row at all still shows as a deficit",
         %{conn: conn} do
      a = admin()
      cat = create_catalogue!()
      # No StockLedger.upsert_quantity call at all — this item has never had
      # a Stock row, the sharpest possible deficit (0 available against a
      # real minimum).
      zero_item = create_item!(cat, "Never Stocked Widget")
      {:ok, _} = MinStockSettings.set_min_quantity(zero_item.uuid, "5")

      {:ok, lv, _html} = live(login(conn, a), path())
      html = render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))

      assert html =~ "Never Stocked Widget"

      assert has_element?(
               lv,
               ~s(button[phx-click="create_supplier_order_from_deficit"][phx-value-item_uuid="#{zero_item.uuid}"])
             )
    end

    test "clicking Create supplier order creates a draft SO from the deficit and navigates to it",
         %{conn: conn} do
      a = admin()
      cat = create_catalogue!()
      item = create_item!(cat, "SO Deficit Widget")
      {:ok, _} = StockLedger.upsert_quantity(item.uuid, "2")
      {:ok, _} = MinStockSettings.set_min_quantity(item.uuid, "7")
      StockLedger.set_default_location_uuid(Ecto.UUID.generate())

      {:ok, lv, _html} = live(login(conn, a), path())
      render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv
               |> element(
                 ~s(button[phx-click="create_supplier_order_from_deficit"][phx-value-item_uuid="#{item.uuid}"])
               )
               |> render_click()

      assert String.contains?(redirect_to, "/admin/warehouse/supplier-orders/")

      so_uuid = redirect_to |> String.split("/") |> List.last()
      {:ok, so} = SupplierOrders.get_supplier_order(so_uuid)

      assert so.status == "draft"
      assert so.supplier_uuid == nil
      assert [line] = so.lines
      assert line["item_uuid"] == item.uuid
      assert Decimal.equal?(StockLedger.to_decimal(line["ordered_quantity"]), Decimal.new("5"))
      assert Decimal.equal?(StockLedger.to_decimal(line["on_hand_quantity"]), Decimal.new("2"))
    end
  end
end
