defmodule PhoenixKitWarehouse.Web.TurnoverReportLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.StockLedger

  @location_uuid "00000000-0000-0000-0000-000000000001"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "turnover-live-#{System.unique_integer([:positive])}@example.com"

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

  defp path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse/turnover")

  defp create_catalogue! do
    {:ok, cat} =
      Catalogue.create_catalogue(%{
        name: "Turnover Live Catalogue #{System.unique_integer([:positive])}",
        status: "active"
      })

    cat
  end

  defp create_item!(name) do
    catalogue = create_catalogue!()

    {:ok, item} =
      Catalogue.create_item(%{
        name: name,
        sku: "TL-#{System.unique_integer([:positive])}",
        unit: "piece",
        catalogue_uuid: catalogue.uuid,
        status: "active"
      })

    item
  end

  defp post_receipt!(item_uuid, qty, location_uuid, actor) do
    {:ok, receipt} =
      GoodsReceipts.create_goods_receipt(%{
        location_uuid: location_uuid,
        lines: [%{"item_uuid" => item_uuid, "received_quantity" => Decimal.new(qty)}]
      })

    {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)
    posted
  end

  # Creates real Location records tagged with a fresh warehouse LocationType
  # and marks that type as the warehouse type. The per-test sandbox rolls
  # both the rows and the setting back, so no manual cleanup is needed.
  defp setup_warehouses!(names) do
    {:ok, type} =
      Locations.create_location_type(%{
        name: "Turnover Live WH Type #{System.unique_integer([:positive])}"
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

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "turnover report" do
    test "renders the warehouse header with the Turnover tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, path())

      assert html =~ "Turnover"
    end

    test "defaults the date range to the current calendar month", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      today = Date.utc_today()

      {:ok, _lv, html} = live(conn, path())

      assert html =~ Date.to_iso8601(Date.beginning_of_month(today))
      assert html =~ Date.to_iso8601(Date.end_of_month(today))
    end

    test "shows an empty state when there is no movement in the period", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, path())

      assert html =~ "No movement in this period"
    end

    test "surfaces the balance-is-current caveat as visible UI text, not just a tooltip", %{
      conn: conn
    } do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, path())

      assert html =~ "not a historical balance"
    end

    test "lists an item with a posted receipt from the default period", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      item = create_item!("Turnover Report Widget")
      post_receipt!(item.uuid, "42", @location_uuid, admin.uuid)

      {:ok, _lv, html} = live(conn, path())

      assert html =~ "Turnover Report Widget"
      assert html =~ "42"
    end

    test "narrowing the date window excludes a movement posted outside it", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      item = create_item!("Windowed Widget")
      post_receipt!(item.uuid, "5", @location_uuid, admin.uuid)

      {:ok, lv, html} = live(conn, path())
      assert html =~ "Windowed Widget"

      yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

      html =
        lv
        |> element("form[phx-change='filter_change']")
        |> render_change(%{"date_from" => yesterday, "date_to" => yesterday})

      refute html =~ "Windowed Widget"
    end

    test "hides the warehouse select when no warehouse location type is configured", %{
      conn: conn
    } do
      StockLedger.set_warehouse_location_type_uuid(nil)
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, path())

      refute html =~ "All warehouses"
    end

    test "scoping to one warehouse hides a movement posted at another", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      [loc_a, loc_b] = setup_warehouses!(["Turnover Live WH A", "Turnover Live WH B"])
      item = create_item!("Scoped Widget")
      post_receipt!(item.uuid, "8", loc_a.uuid, admin.uuid)

      {:ok, lv, html} = live(conn, path())
      assert html =~ "All warehouses"
      assert html =~ "Scoped Widget"

      html =
        lv
        |> element("form[phx-change='filter_change']")
        |> render_change(%{"location_uuid" => loc_b.uuid})

      refute html =~ "Scoped Widget"

      html =
        lv
        |> element("form[phx-change='filter_change']")
        |> render_change(%{"location_uuid" => loc_a.uuid})

      assert html =~ "Scoped Widget"
    end
  end
end
