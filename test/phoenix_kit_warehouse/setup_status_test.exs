defmodule PhoenixKitWarehouse.SetupStatusTest do
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.StockLedger

  defp create_type! do
    {:ok, type} =
      Locations.create_location_type(%{
        name: "Setup WH Type #{System.unique_integer([:positive])}"
      })

    type
  end

  defp create_location!(type, name \\ nil) do
    {:ok, loc} =
      Locations.create_location(%{
        name: name || "Setup WH #{System.unique_integer([:positive])}",
        status: "active"
      })

    if type, do: Locations.sync_location_types(loc.uuid, [type.uuid])
    loc
  end

  describe "setup_status/0" do
    test "needs the location type while the warehouse type setting is unset" do
      StockLedger.set_warehouse_location_type_uuid(nil)
      StockLedger.set_default_location_uuid(nil)

      assert StockLedger.setup_status() == {:needs, :location_type}
    end

    test "needs locations when the type is set but no location carries it" do
      type = create_type!()
      StockLedger.set_warehouse_location_type_uuid(type.uuid)
      StockLedger.set_default_location_uuid(nil)
      # A location of some other type does not count as a warehouse.
      create_location!(nil)

      assert StockLedger.setup_status() == {:needs, :locations}
    end

    test "needs the location type when the chosen type no longer exists" do
      type = create_type!()
      StockLedger.set_warehouse_location_type_uuid(type.uuid)
      StockLedger.set_default_location_uuid(nil)
      {:ok, _} = Locations.delete_location_type(type)

      assert StockLedger.setup_status() == {:needs, :location_type}
    end

    test "needs the default location when warehouses exist but none is chosen" do
      type = create_type!()
      create_location!(type)
      StockLedger.set_warehouse_location_type_uuid(type.uuid)
      StockLedger.set_default_location_uuid(nil)

      assert StockLedger.setup_status() == {:needs, :default_location}
    end

    test "needs the default location when it points outside the warehouse list" do
      type = create_type!()
      create_location!(type)
      stray = create_location!(nil)
      StockLedger.set_warehouse_location_type_uuid(type.uuid)
      StockLedger.set_default_location_uuid(stray.uuid)

      assert StockLedger.setup_status() == {:needs, :default_location}
    end

    test "is ready when the default location is one of the warehouses" do
      type = create_type!()
      loc = create_location!(type)
      StockLedger.set_warehouse_location_type_uuid(type.uuid)
      StockLedger.set_default_location_uuid(loc.uuid)

      assert StockLedger.setup_status() == :ready
    end
  end
end
