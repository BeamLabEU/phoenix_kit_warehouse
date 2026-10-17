defmodule PhoenixKitWarehouse.StockTrackingContractTest do
  @moduledoc """
  The contract between this module and the shop's "Stock tracking" switch.

  E-commerce reaches Warehouse through variable-module calls guarded by
  `Code.ensure_loaded?/1`, so a rename here would compile on both sides and
  silently show every shop "Warehouse disabled". These tests make the rename
  fail in this repository instead.

  The other half of the contract: nothing in this module reads
  `shop_stock_tracking_enabled`. The warehouse API tools follow the module's
  own state, not the shop's switch.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKit.Settings
  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.StockLedger

  setup do
    # The settings cache is ETS-backed and is not rolled back by the sandbox.
    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_stock_tracking_enabled", false, "shop")
    end)

    :ok
  end

  test "the two functions the switch calls exist with the arities it uses" do
    assert {:module, PhoenixKitWarehouse} = Code.ensure_loaded(PhoenixKitWarehouse)
    assert function_exported?(PhoenixKitWarehouse, :enabled?, 0)
    assert function_exported?(StockLedger, :default_location_uuid, 0)
  end

  test "enabled?/0 is a strict boolean that follows the warehouse_enabled setting" do
    {:ok, _} = PhoenixKitWarehouse.enable_system()
    assert PhoenixKitWarehouse.enabled?() === true

    {:ok, _} = PhoenixKitWarehouse.disable_system()
    assert PhoenixKitWarehouse.enabled?() === false
  end

  test "default_location_uuid/0 is nil when no default is chosen and the UUID once it is" do
    StockLedger.set_default_location_uuid(nil)
    assert StockLedger.default_location_uuid() == nil

    %{locations: [first | _]} = warehouses!(1)
    assert StockLedger.default_location_uuid() == first.uuid
  end

  test "the write tools post the same whether the shop's switch is off or on" do
    %{locations: [first | _]} = warehouses!(1)
    catalogue = shop_catalogue!()
    item = item!(catalogue)
    ctx = ctx(user!())

    for value <- [false, true] do
      {:ok, _} =
        Settings.update_boolean_setting_with_module("shop_stock_tracking_enabled", value, "shop")

      assert {:ok, %{"status" => "posted"}} =
               Write.receive_stock(
                 %{"lines" => [%{"ref" => %{"id" => item.uuid}, "quantity" => "1"}]},
                 ctx
               )
    end

    assert Decimal.equal?(quantity(item.uuid, first.uuid), Decimal.new(2))
  end

  test "no module of this package reads the switch" do
    files = Path.wildcard("lib/**/*.ex")
    assert files != [], "no source file found: the test would pass without reading anything"

    readers = Enum.filter(files, &(File.read!(&1) =~ "shop_stock_tracking_enabled"))

    assert readers == []
  end
end
