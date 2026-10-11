defmodule PhoenixKitWarehouse.Web.SetupNoticeLiveTest do
  use PhoenixKitWarehouse.LiveCase, async: false
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.StockLedger

  @notice "#warehouse-setup-notice"
  @settings_link "#warehouse-setup-settings-link"
  @locations_link "#warehouse-setup-locations-link"

  @pages [
    "/admin/warehouse",
    "/admin/warehouse/inventories",
    "/admin/warehouse/internal-orders",
    "/admin/warehouse/supplier-orders",
    "/admin/warehouse/goods-receipts",
    "/admin/warehouse/goods-issues",
    "/admin/warehouse/transfers",
    "/admin/warehouse/turnover"
  ]

  defp login_admin(conn) do
    {:ok, u} =
      Auth.register_user(%{
        "email" => "setup-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "S",
        "last_name" => "N"
      })

    {:ok, u} = Auth.admin_confirm_user(u)
    {:ok, _} = Roles.promote_to_admin(u)
    token = Auth.generate_user_session_token(Auth.get_user!(u.uuid))

    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  defp create_type! do
    {:ok, type} =
      Locations.create_location_type(%{name: "Notice Type #{System.unique_integer([:positive])}"})

    type
  end

  defp create_warehouse!(type) do
    {:ok, loc} =
      Locations.create_location(%{
        name: "Notice WH #{System.unique_integer([:positive])}",
        status: "active"
      })

    Locations.sync_location_types(loc.uuid, [type.uuid])
    loc
  end

  defp configure!(:location_type) do
    StockLedger.set_warehouse_location_type_uuid(nil)
    StockLedger.set_default_location_uuid(nil)
  end

  defp configure!(:locations) do
    configure!(:location_type)
    StockLedger.set_warehouse_location_type_uuid(create_type!().uuid)
  end

  defp configure!(:default_location) do
    configure!(:location_type)
    type = create_type!()
    create_warehouse!(type)
    StockLedger.set_warehouse_location_type_uuid(type.uuid)
  end

  defp configure!(:ready) do
    type = create_type!()
    loc = create_warehouse!(type)
    StockLedger.set_warehouse_location_type_uuid(type.uuid)
    StockLedger.set_default_location_uuid(loc.uuid)
  end

  defp step_notice(step), do: "#{@notice}[data-step=#{step}]"

  # The step text, looked up through the same catalog the page uses, so the
  # test pins which text goes with which step without a hardcoded literal.
  defp step_text(:location_type) do
    dgettext(
      "default",
      "Create a location type for warehouses in Locations, then choose it in Warehouse settings."
    )
  end

  defp step_text(:locations),
    do: dgettext("default", "Add at least one location of the warehouse type in Locations.")

  defp step_text(:default_location),
    do: dgettext("default", "Choose the default warehouse in Warehouse settings.")

  defp href(lv, selector) do
    lv |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.attribute("href")
  end

  describe "stock page" do
    setup %{conn: conn} do
      PhoenixKitLocations.enable_system()
      {:ok, conn: login_admin(conn)}
    end

    test "location type step offers Locations types and the settings", %{conn: conn} do
      configure!(:location_type)
      {:ok, lv, _} = live(conn, Routes.path("/admin/warehouse"))

      assert has_element?(lv, step_notice(:location_type), step_text(:location_type))
      assert has_element?(lv, "#{@locations_link}.btn-primary")
      assert has_element?(lv, "#{@settings_link}.btn-outline")
      refute has_element?(lv, "#{@settings_link}.btn-primary")
      assert href(lv, @locations_link) == [Routes.path("/admin/locations/types")]
      assert href(lv, @settings_link) == [Routes.path("/admin/settings/warehouse")]
    end

    test "locations step offers a new location and the settings", %{conn: conn} do
      configure!(:locations)
      {:ok, lv, _} = live(conn, Routes.path("/admin/warehouse"))

      assert has_element?(lv, step_notice(:locations), step_text(:locations))
      assert has_element?(lv, "#{@locations_link}.btn-primary")
      assert has_element?(lv, "#{@settings_link}.btn-outline")
      refute has_element?(lv, "#{@settings_link}.btn-primary")
      assert href(lv, @locations_link) == [Routes.path("/admin/locations/new")]
      assert href(lv, @settings_link) == [Routes.path("/admin/settings/warehouse")]
    end

    test "default location step offers only the settings", %{conn: conn} do
      configure!(:default_location)
      {:ok, lv, _} = live(conn, Routes.path("/admin/warehouse"))

      assert has_element?(lv, step_notice(:default_location), step_text(:default_location))
      refute has_element?(lv, @locations_link)
      assert has_element?(lv, "#{@settings_link}.btn-primary")
      refute has_element?(lv, "#{@settings_link}.btn-outline")
      assert href(lv, @settings_link) == [Routes.path("/admin/settings/warehouse")]
    end

    test "shows nothing once the warehouse is set up", %{conn: conn} do
      configure!(:ready)
      {:ok, lv, _} = live(conn, Routes.path("/admin/warehouse"))

      refute has_element?(lv, @notice)
      refute has_element?(lv, @settings_link)
      refute has_element?(lv, @locations_link)
    end

    test "hides the Locations button when the Locations module is disabled", %{conn: conn} do
      PhoenixKit.Settings.update_boolean_setting("locations_enabled", false)
      configure!(:location_type)
      {:ok, lv, _} = live(conn, Routes.path("/admin/warehouse"))

      assert has_element?(lv, step_notice(:location_type))
      refute has_element?(lv, @locations_link)
      assert has_element?(lv, "#{@settings_link}.btn-primary")
    end
  end

  describe "unreadable status" do
    setup %{conn: conn} do
      PhoenixKitLocations.enable_system()
      {:ok, conn: login_admin(conn)}
    end

    test "a setting that is not a UUID hides the notice instead of crashing the page", %{
      conn: conn
    } do
      configure!(:location_type)
      PhoenixKit.Settings.update_setting("warehouse_location_type_uuid", "not-a-uuid")

      {:ok, lv, _} = live(conn, Routes.path("/admin/warehouse/goods-issues"))

      refute has_element?(lv, @notice)
      assert has_element?(lv, "#goods-issues-table")
    end
  end

  describe "other pages" do
    setup %{conn: conn} do
      PhoenixKitLocations.enable_system()
      {:ok, conn: login_admin(conn)}
    end

    for page <- @pages do
      test "#{page} shows the notice while not set up and hides it when ready", %{conn: conn} do
        configure!(:locations)
        {:ok, lv, _} = live(conn, Routes.path(unquote(page)))
        assert has_element?(lv, step_notice(:locations))
        assert has_element?(lv, @locations_link)
        assert has_element?(lv, @settings_link)

        configure!(:ready)
        {:ok, lv, _} = live(conn, Routes.path(unquote(page)))
        refute has_element?(lv, @notice)
      end
    end
  end

  describe "settings page" do
    setup %{conn: conn} do
      PhoenixKitLocations.enable_system()
      {:ok, conn: login_admin(conn)}
    end

    test "never shows the notice, even while not set up", %{conn: conn} do
      configure!(:location_type)
      {:ok, lv, _} = live(conn, Routes.path("/admin/settings/warehouse"))

      assert has_element?(lv, ~s(form[phx-change="set_warehouse_type"]))
      refute has_element?(lv, @notice)
      refute has_element?(lv, @settings_link)
    end
  end
end
