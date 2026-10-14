defmodule PhoenixKitWarehouse.API.WarehousesTest do
  @moduledoc """
  `Warehouses` and `warehouse.list_locations`: which locations stock may be
  written to, and the answers when the module is not set up.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.API.Stock
  alias PhoenixKitWarehouse.API.Warehouses
  alias PhoenixKitWarehouse.StockLedger

  describe "list/0" do
    test "lists the warehouse locations, marks the default, reports ready" do
      %{locations: [first, second]} = warehouses!(2)

      assert %{locations: locations, default_location_id: default, setup: "ready"} =
               Warehouses.list()

      assert default == first.uuid

      assert Enum.sort_by(locations, & &1["id"]) ==
               Enum.sort_by(
                 [
                   %{
                     "id" => first.uuid,
                     "name" => first.name,
                     "status" => "active",
                     "default" => true
                   },
                   %{
                     "id" => second.uuid,
                     "name" => second.name,
                     "status" => "active",
                     "default" => false
                   }
                 ],
                 & &1["id"]
               )
    end

    test "with no warehouse type configured: no locations, no default, needs_location_type" do
      StockLedger.set_warehouse_location_type_uuid(nil)
      StockLedger.set_default_location_uuid(nil)

      assert %{locations: [], default_location_id: nil, setup: "needs_location_type"} =
               Warehouses.list()
    end

    test "a type with no location needs_locations; a default outside the list is not reported" do
      {:ok, type} =
        Locations.create_location_type(%{name: "Empty #{System.unique_integer([:positive])}"})

      StockLedger.set_warehouse_location_type_uuid(type.uuid)
      StockLedger.set_default_location_uuid(nil)
      assert %{setup: "needs_locations", locations: []} = Warehouses.list()

      %{locations: [_first]} = warehouses!(1)
      StockLedger.set_default_location_uuid(Ecto.UUID.generate())
      assert %{setup: "needs_default_location", default_location_id: nil} = Warehouses.list()
    end
  end

  describe "resolve/2" do
    setup do
      %{locations: [first, second]} = warehouses!(2)
      %{first: first, second: second}
    end

    test "nil is the default warehouse", %{first: first} do
      assert Warehouses.resolve(nil, :write) == {:ok, first.uuid}
      assert Warehouses.resolve(nil, :read) == {:ok, first.uuid}
    end

    test "a listed warehouse, in any letter case", %{second: second} do
      assert Warehouses.resolve(second.uuid, :write) == {:ok, second.uuid}
      assert Warehouses.resolve(String.upcase(second.uuid), :write) == {:ok, second.uuid}
    end

    test "no default and no location_id names the setting" do
      StockLedger.set_default_location_uuid(nil)

      assert {:error, %{path: "location_id", code: "validation_failed", message: message}} =
               Warehouses.resolve(nil, :write)

      assert message =~ "warehouse_default_location_uuid"
    end

    test "a default that is not a warehouse is refused with the same hint" do
      StockLedger.set_default_location_uuid(Ecto.UUID.generate())

      assert {:error, %{message: message}} = Warehouses.resolve(nil, :write)
      assert message =~ "default"
    end

    test "a valid UUID that is not a warehouse location is refused" do
      {:ok, plain} = Locations.create_location(%{name: "Not a warehouse", status: "active"})

      for bad <- [plain.uuid, Ecto.UUID.generate()] do
        assert {:error, %{path: "location_id", code: "validation_failed", message: message}} =
                 Warehouses.resolve(bad, :write)

        assert message =~ "not a warehouse location"
      end
    end

    test "malformed and non-string values are refused" do
      for bad <- ["nope", 5, %{}, [], true] do
        assert {:error, %{path: "location_id", code: "validation_failed"}} =
                 Warehouses.resolve(bad, :write)
      end
    end

    test "a 16-character value is malformed, not read as a raw UUID" do
      assert {:error, %{path: "location_id", code: "validation_failed", message: message}} =
               Warehouses.resolve("0123456789abcdef", :write)

      assert message =~ "must be a UUID"
    end

    test "an inactive warehouse can be read but not written", %{second: second} do
      {:ok, _} = Locations.update_location(second, %{status: "inactive"})

      assert Warehouses.resolve(second.uuid, :read) == {:ok, second.uuid}

      assert {:error, %{message: message}} = Warehouses.resolve(second.uuid, :write)
      assert message =~ "inactive"
    end

    test "an unconfigured warehouse type is refused for reads and writes" do
      StockLedger.set_warehouse_location_type_uuid(nil)

      for mode <- [:read, :write] do
        assert {:error, %{message: message}} = Warehouses.resolve(Ecto.UUID.generate(), mode)
        assert message =~ "location type"
      end
    end
  end

  describe "the list_locations handler" do
    test "answers the same data as Warehouses.list/0" do
      %{locations: [first | _]} = warehouses!(2)
      ctx = ctx(user!())

      assert {:ok,
              %{"locations" => locations, "default_location_id" => default, "setup" => "ready"}} =
               Stock.list_locations(%{}, ctx)

      assert default == first.uuid
      assert length(locations) == 2
      assert Enum.count(locations, & &1["default"]) == 1
    end
  end
end
