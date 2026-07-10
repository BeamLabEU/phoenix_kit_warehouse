defmodule PhoenixKitWarehouse.Web.InventoriesLiveTabsTest do
  @moduledoc """
  Tests for the Warehouse index page tab routing, active state, and grouped
  in-stock rendering via WarehouseBrowser.stock_sheet.

  Tab switching is done via patch links (live_action), not phx-click events.
  """

  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitCatalogue.Catalogue

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "wh-tabs-#{System.unique_integer([:positive])}@example.com"

  defp create_admin_user do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => unique_email(),
        "password" => "password123456789",
        "first_name" => "Tab",
        "last_name" => "Admin"
      })

    {:ok, user} = PhoenixKit.Users.Auth.admin_confirm_user(user)
    {:ok, _} = PhoenixKit.Users.Roles.promote_to_admin(user)
    PhoenixKit.Users.Auth.get_user!(user.uuid)
  end

  defp log_in_admin(conn, user) do
    token = PhoenixKit.Users.Auth.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  defp warehouse_path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse")

  defp inventories_path,
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/inventories")

  defp create_catalogue!(name_suffix) do
    {:ok, cat} =
      Catalogue.create_catalogue(%{
        name: "WHTab #{name_suffix} #{System.unique_integer([:positive])}",
        status: "active"
      })

    cat
  end

  defp create_active_item!(cat, opts \\ []) do
    name = Keyword.get(opts, :name, "Tab Item #{System.unique_integer([:positive])}")

    {:ok, item} =
      Catalogue.create_item(%{
        name: name,
        catalogue_uuid: cat.uuid,
        base_price: "15.00",
        status: "active",
        sku: "WHTAB-#{System.unique_integer([:positive])}"
      })

    item
  end

  # ---------------------------------------------------------------------------
  # Tab route + active state
  # ---------------------------------------------------------------------------

  describe "tab routes and active state" do
    test "stock tab is active on /admin/warehouse", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, warehouse_path())

      # The "In stock" tab link has tab-active class
      assert html =~ ~r/tab-active[^>]*>.*In stock/s
    end

    test "inventories tab is active on /admin/warehouse/inventories", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, inventories_path())

      # The "Stocktakes" tab link has tab-active class
      assert html =~ ~r/tab-active[^>]*>.*Stocktake/s
    end

    test "stock tab link points to warehouse root", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, warehouse_path())

      assert html =~ warehouse_path()
    end

    test "inventories tab link points to /inventories path", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, warehouse_path())

      assert html =~ inventories_path()
    end

    test "patch to inventories path switches to inventories content", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, warehouse_path())

      # Follow the patch link to the inventories tab
      html = render_patch(lv, inventories_path())

      # Inventories tab content: shows stocktake table header or empty state
      assert html =~ "Stocktake"
    end
  end

  # ---------------------------------------------------------------------------
  # In-stock tab: grouped rendering
  # ---------------------------------------------------------------------------

  describe "in-stock tab grouped rendering" do
    setup do
      # Clear stock so only our test items appear
      PhoenixKitWarehouse.Test.Repo.delete_all(PhoenixKitWarehouse.Stock)
      :ok
    end

    test "items with stock appear grouped under their catalogue section", %{conn: conn} do
      admin = create_admin_user()
      cat_a = create_catalogue!("Alpha")
      cat_b = create_catalogue!("Beta")

      item_a = create_active_item!(cat_a, name: "Alpha Widget")
      item_b = create_active_item!(cat_b, name: "Beta Gadget")

      {:ok, _} = Warehouse.upsert_quantity(item_a.uuid, "10", unit_value: Decimal.new("5.00"))
      {:ok, _} = Warehouse.upsert_quantity(item_b.uuid, "20", unit_value: Decimal.new("3.00"))

      conn = log_in_admin(conn, admin)
      {:ok, _lv, html} = live(conn, warehouse_path())

      assert html =~ "Alpha Widget"
      assert html =~ "Beta Gadget"
    end

    test "catalogue section header appears for each catalogue with stocked items", %{conn: conn} do
      admin = create_admin_user()
      cat_a = create_catalogue!("CatA")
      cat_b = create_catalogue!("CatB")

      item_a = create_active_item!(cat_a)
      item_b = create_active_item!(cat_b)

      {:ok, _} = Warehouse.upsert_quantity(item_a.uuid, "5", unit_value: nil)
      {:ok, _} = Warehouse.upsert_quantity(item_b.uuid, "8", unit_value: nil)

      conn = log_in_admin(conn, admin)
      {:ok, _lv, html} = live(conn, warehouse_path())

      # Both catalogue names should appear (prefix "WHTab" is stripped from
      # displayed catalogue names via catalogue_display_name)
      assert html =~ cat_a.name
      assert html =~ cat_b.name
    end

    test "subtotal row appears for each catalogue section", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!("SubTotCat")
      item = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "12", unit_value: nil)

      conn = log_in_admin(conn, admin)
      {:ok, _lv, html} = live(conn, warehouse_path())

      # The grouped stock sheet renders a per-catalogue section header with a
      # "Total" subtotal (qty + value), in addition to the "Total value" column
      # header — so the "Total" label appears at least twice when a section shows.
      assert (html |> String.split("Total") |> length()) - 1 >= 2
    end

    test "unstocked items are excluded from the stock sheet", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!("ExcludeCat")
      stocked = create_active_item!(cat, name: "Stocked Present")
      unstocked = create_active_item!(cat, name: "Unstocked Absent")

      {:ok, _} = Warehouse.upsert_quantity(stocked.uuid, "3", unit_value: nil)

      conn = log_in_admin(conn, admin)
      {:ok, _lv, html} = live(conn, warehouse_path())

      assert html =~ "Stocked Present"
      refute html =~ "Unstocked Absent"
    end

    test "empty stock shows no-items placeholder", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, warehouse_path())

      # stock_sheet empty state
      assert html =~ "No items in stock"
    end
  end

  # ---------------------------------------------------------------------------
  # Inventories tab: list documents
  # ---------------------------------------------------------------------------

  describe "inventories tab listing" do
    test "inventories tab shows document numbers", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, doc} = Inventories.create_draft(%{})

      {:ok, _lv, html} = live(conn, inventories_path())

      assert html =~ "##{doc.number}"
    end

    test "documents appear newest-first (descending number)", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, doc1} = Inventories.create_draft(%{})
      {:ok, doc2} = Inventories.create_draft(%{})

      {:ok, _lv, html} = live(conn, inventories_path())

      doc1_pos = :binary.match(html, "##{doc1.number}") |> elem(0)
      doc2_pos = :binary.match(html, "##{doc2.number}") |> elem(0)

      assert doc2_pos < doc1_pos,
             "Expected doc2 (##{doc2.number}) before doc1 (##{doc1.number}) in the list"
    end

    test "empty inventories tab shows no-stocktakes placeholder", %{conn: conn} do
      # Delete all docs to ensure empty state
      PhoenixKitWarehouse.Test.Repo.delete_all(PhoenixKitWarehouse.InventoryDocument)

      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, inventories_path())

      assert html =~ "No stocktakes yet"
    end

    test "each document row links to its edit path", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, doc} = Inventories.create_draft(%{})

      {:ok, _lv, html} = live(conn, inventories_path())

      edit_path = PhoenixKit.Utils.Routes.path("/admin/warehouse/inventory/#{doc.uuid}")
      assert html =~ edit_path
    end
  end
end
