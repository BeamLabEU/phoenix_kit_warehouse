defmodule PhoenixKitWarehouse.Web.InventoriesLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitCatalogue.Catalogue

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "wh-admin-#{System.unique_integer([:positive])}@example.com"

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

  defp warehouse_path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse")
  defp inventories_path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse/inventories")

  defp create_catalogue! do
    # Intentionally NOT ANDI-prefixed: the warehouse shows ALL active catalogues
    # (no prefix filter), like sub-orders — so a non-prefixed catalogue must appear.
    {:ok, cat} =
      Catalogue.create_catalogue(%{
        name: "WHIdx Test #{System.unique_integer([:positive])}",
        status: "active"
      })

    cat
  end

  defp create_active_item!(cat) do
    {:ok, item} =
      Catalogue.create_item(%{
        name: "Active Item #{System.unique_integer([:positive])}",
        catalogue_uuid: cat.uuid,
        base_price: "10.00",
        status: "active",
        sku: "WH-IDX-#{System.unique_integer([:positive])}"
      })

    item
  end

  # ---------------------------------------------------------------------------
  # Stock tab tests
  # ---------------------------------------------------------------------------

  describe "In stock tab" do
    test "renders the page title", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, warehouse_path())

      assert html =~ "Warehouse"
    end

    test "New stocktake link has correct href on the Stocktakes tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      # The "New stocktake" create button now lives in the Stocktakes (inventories)
      # tab toolbar, not in the shared header on the in-stock tab.
      {:ok, _lv, html} = live(conn, inventories_path())

      expected_path = PhoenixKit.Utils.Routes.path("/admin/warehouse/inventory/new")
      assert html =~ expected_path
    end

    test "lists only items with a non-zero balance", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      stocked = create_active_item!(cat)
      unstocked = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(stocked.uuid, "42", unit_value: Decimal.new("5.00"))

      conn = log_in_admin(conn, admin)
      {:ok, _lv, html} = live(conn, warehouse_path())

      # In-stock item is shown with its quantity; the un-stocked one is not.
      assert html =~ stocked.name
      assert html =~ "42"
      refute html =~ unstocked.name
    end

    test "a zeroed item is not listed", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      item = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "0", unit_value: nil)

      conn = log_in_admin(conn, admin)
      {:ok, _lv, html} = live(conn, warehouse_path())

      refute html =~ item.name
    end

    test "item with nil unit_value shows placeholder dash for total value", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      item = create_active_item!(cat)

      # No unit_value — only quantity
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "10", unit_value: nil)

      conn = log_in_admin(conn, admin)
      {:ok, _lv, html} = live(conn, warehouse_path())

      assert html =~ item.name
      # The placeholder dash for missing total value
      assert html =~ "—"
    end
  end

  # ---------------------------------------------------------------------------
  # Inventories tab tests
  # ---------------------------------------------------------------------------

  describe "Inventories tab" do
    test "lists documents newest-first by number", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      # Create two drafts — rely on the sequence to get ascending numbers
      {:ok, doc1} = Inventories.create_draft(%{})
      {:ok, doc2} = Inventories.create_draft(%{})

      # Inventories route is now served by a separate LiveView — visit it directly.
      {:ok, _lv, html} = live(conn, inventories_path())

      # doc2 has a higher number than doc1 so it should appear first
      doc1_pos = :binary.match(html, "##{doc1.number}") |> elem(0)
      doc2_pos = :binary.match(html, "##{doc2.number}") |> elem(0)

      assert doc2_pos < doc1_pos,
             "Expected doc2 (#{doc2.number}) to appear before doc1 (#{doc1.number}) in the inventory list"
    end

    test "inventory tab shows document numbers", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, doc} = Inventories.create_draft(%{})

      # Inventories route is now served by a separate LiveView — visit it directly.
      {:ok, _lv, html} = live(conn, inventories_path())

      assert html =~ "##{doc.number}"
    end
  end

  # ---------------------------------------------------------------------------
  # Locale test
  # ---------------------------------------------------------------------------

  describe "Locale" do
    test "ru locale page loads successfully", %{conn: conn} do
      admin = create_admin_user()

      conn =
        conn
        |> log_in_admin(admin)
        |> Plug.Conn.put_session(:locale, "ru")

      {:ok, _lv, html} = live(conn, warehouse_path())

      # Page should load — "Warehouse" header renders (en fallback before i18n task)
      assert html =~ "Warehouse"
    end
  end
end
