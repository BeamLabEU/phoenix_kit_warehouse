defmodule PhoenixKitWarehouseTest do
  use PhoenixKitWarehouse.DataCase, async: false

  describe "module identity" do
    test "module_key/0 and module_name/0" do
      assert PhoenixKitWarehouse.module_key() == "warehouse"
      assert PhoenixKitWarehouse.module_name() == "Warehouse"
    end

    test "version/0 matches mix.exs" do
      assert PhoenixKitWarehouse.version() == Mix.Project.config()[:version]
    end

    test "required_modules/0 declares catalogue and locations" do
      assert PhoenixKitWarehouse.required_modules() == ["catalogue", "locations"]
    end

    test "css_sources/0" do
      assert PhoenixKitWarehouse.css_sources() == [:phoenix_kit_warehouse]
    end

    test "children/0 supervises its own Task.Supervisor" do
      assert PhoenixKitWarehouse.children() == [
               {Task.Supervisor, name: PhoenixKitWarehouse.TaskSupervisor}
             ]
    end

    test "admin_tabs/0 returns 31 tabs, all under module_key() permission" do
      tabs = PhoenixKitWarehouse.admin_tabs()
      assert length(tabs) == 31
      assert Enum.all?(tabs, &(&1.permission == "warehouse"))
    end

    test "admin_tabs/0's root tab hosts StockLive directly (no redirect stub)" do
      root = Enum.find(PhoenixKitWarehouse.admin_tabs(), &(&1.id == :warehouse))
      assert root.match == :exact
      assert root.live_view == {PhoenixKitWarehouse.Web.StockLive, :index}
      assert root.path == "warehouse"
    end

    test "admin_tabs/0 preserves every hidden CRUD tab's priority from today's config.exs" do
      tabs = PhoenixKitWarehouse.admin_tabs()
      hidden = Enum.reject(tabs, & &1.visible)
      assert length(hidden) == 25
      assert Enum.all?(hidden, &(&1.visible == false))
    end

    test "settings_tabs/0 returns the warehouse-location settings page" do
      [tab] = PhoenixKitWarehouse.settings_tabs()
      assert tab.id == :warehouse_settings
      assert tab.permission == "warehouse"
      assert tab.live_view == {PhoenixKitWarehouse.Web.SettingsLive, :index}
    end
  end

  describe "enabled?/0, enable_system/0, disable_system/0" do
    test "defaults to disabled" do
      refute PhoenixKitWarehouse.enabled?()
    end

    test "enable_system/0 flips the setting on and logs activity" do
      assert {:ok, _} = PhoenixKitWarehouse.enable_system()
      assert PhoenixKitWarehouse.enabled?()
    end

    test "disable_system/0 flips the setting off and logs activity" do
      {:ok, _} = PhoenixKitWarehouse.enable_system()
      assert PhoenixKitWarehouse.enabled?()

      assert {:ok, _} = PhoenixKitWarehouse.disable_system()
      refute PhoenixKitWarehouse.enabled?()
    end
  end
end
