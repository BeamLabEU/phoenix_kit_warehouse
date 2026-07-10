defmodule PhoenixKitWarehouse.ViewConfigsTest do
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.ViewConfigs

  test "get_view_config/2 returns %{} when nothing saved yet" do
    assert ViewConfigs.get_view_config("00000000-0000-0000-0000-000000000001", "warehouse_stock") ==
             %{}
  end

  test "merge_view_config/3 persists and round-trips" do
    uuid = "00000000-0000-0000-0000-000000000002"

    assert {:ok, %{"stock_view" => "flat"}} =
             ViewConfigs.merge_view_config(uuid, "warehouse_stock", %{"stock_view" => "flat"})

    assert ViewConfigs.get_view_config(uuid, "warehouse_stock") == %{"stock_view" => "flat"}
  end

  test "merge_view_config/3 preserves keys not touched by a later merge" do
    uuid = "00000000-0000-0000-0000-000000000003"

    {:ok, _} =
      ViewConfigs.merge_view_config(uuid, "warehouse_internal_orders", %{
        "columns" => ["number", "status"]
      })

    {:ok, merged} =
      ViewConfigs.merge_view_config(uuid, "warehouse_internal_orders", %{
        "active_filters" => ["status"]
      })

    assert merged == %{"columns" => ["number", "status"], "active_filters" => ["status"]}
  end

  test "scopes are independent for the same user" do
    uuid = "00000000-0000-0000-0000-000000000004"
    {:ok, _} = ViewConfigs.merge_view_config(uuid, "warehouse_stock", %{"stock_view" => "flat"})

    assert ViewConfigs.get_view_config(uuid, "warehouse_inventories") == %{}
  end
end
