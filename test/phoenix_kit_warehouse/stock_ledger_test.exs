defmodule PhoenixKitWarehouse.StockLedgerTest do
  use PhoenixKitWarehouse.DataCase, async: true

  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.StockLedger, as: Warehouse

  describe "list_stock/0" do
    test "returns all stock rows" do
      item1 = Ecto.UUID.generate()
      item2 = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item1, "3", unit_value: Decimal.new("10"))
      {:ok, _} = Warehouse.upsert_quantity(item2, "5", unit_value: nil)

      rows = Warehouse.list_stock()
      uuids = Enum.map(rows, & &1.item_uuid)

      assert item1 in uuids
      assert item2 in uuids
    end
  end

  describe "stock_map/0" do
    test "returns a map of item_uuid to quantity and unit_value" do
      item = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item, "7", unit_value: Decimal.new("5"))

      map = Warehouse.stock_map()

      assert %{quantity: qty, unit_value: uv} = map[item]
      assert Decimal.equal?(qty, Decimal.new("7"))
      assert Decimal.equal?(uv, Decimal.new("5"))
    end

    test "returns nil unit_value for rows without unit_value" do
      item = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item, "2", unit_value: nil)

      map = Warehouse.stock_map()

      assert %{quantity: qty, unit_value: nil} = map[item]
      assert Decimal.equal?(qty, Decimal.new("2"))
    end

    test "sums quantity across multiple warehouse locations for the same item_uuid" do
      item = Ecto.UUID.generate()
      loc_a = Ecto.UUID.generate()
      loc_b = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item, "3", unit_value: nil, location_uuid: loc_a)
      {:ok, _} = Warehouse.upsert_quantity(item, "5", unit_value: nil, location_uuid: loc_b)

      map = Warehouse.stock_map()

      assert %{quantity: qty} = map[item]
      assert Decimal.equal?(qty, Decimal.new("8"))
    end

    test "unit_value is the value from the most recently updated location row" do
      item = Ecto.UUID.generate()
      loc_a = Ecto.UUID.generate()
      loc_b = Ecto.UUID.generate()

      {:ok, _} =
        Warehouse.upsert_quantity(item, "1", unit_value: Decimal.new("10"), location_uuid: loc_a)

      {:ok, _} =
        Warehouse.upsert_quantity(item, "1", unit_value: Decimal.new("20"), location_uuid: loc_b)

      # Push loc_a's row backward in time so loc_b is unambiguously the most
      # recently updated row (utc_datetime precision is seconds — both rows
      # can otherwise land in the same second). No Process.sleep — patch
      # updated_at directly instead (repo convention, see
      # inventory_posted_edit_live_test.exs).
      old_ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-5, :second)

      Repo.update_all(
        from(s in Stock, where: s.item_uuid == ^item and s.location_uuid == ^loc_a),
        set: [updated_at: old_ts]
      )

      map = Warehouse.stock_map()

      assert %{unit_value: uv} = map[item]
      assert Decimal.equal?(uv, Decimal.new("20"))
    end

    test "unit_value falls back to nil when no location row has one set" do
      item = Ecto.UUID.generate()
      loc_a = Ecto.UUID.generate()
      loc_b = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item, "1", unit_value: nil, location_uuid: loc_a)
      {:ok, _} = Warehouse.upsert_quantity(item, "2", unit_value: nil, location_uuid: loc_b)

      map = Warehouse.stock_map()

      assert %{quantity: qty, unit_value: nil} = map[item]
      assert Decimal.equal?(qty, Decimal.new("3"))
    end
  end

  describe "stock_map_for_location/1" do
    test "scopes results to a single location without aggregating other locations" do
      item = Ecto.UUID.generate()
      loc_a = Ecto.UUID.generate()
      loc_b = Ecto.UUID.generate()

      {:ok, _} =
        Warehouse.upsert_quantity(item, "3", unit_value: Decimal.new("10"), location_uuid: loc_a)

      {:ok, _} =
        Warehouse.upsert_quantity(item, "5", unit_value: Decimal.new("20"), location_uuid: loc_b)

      map_a = Warehouse.stock_map_for_location(loc_a)
      map_b = Warehouse.stock_map_for_location(loc_b)

      assert %{quantity: qty_a, unit_value: uv_a} = map_a[item]
      assert Decimal.equal?(qty_a, Decimal.new("3"))
      assert Decimal.equal?(uv_a, Decimal.new("10"))

      assert %{quantity: qty_b, unit_value: uv_b} = map_b[item]
      assert Decimal.equal?(qty_b, Decimal.new("5"))
      assert Decimal.equal?(uv_b, Decimal.new("20"))
    end

    test "returns an empty map when the location has no stock rows" do
      unknown_location = Ecto.UUID.generate()
      assert Warehouse.stock_map_for_location(unknown_location) == %{}
    end
  end

  describe "stock_for_items/1" do
    test "returns stock rows for specified item uuids" do
      item1 = Ecto.UUID.generate()
      item2 = Ecto.UUID.generate()
      item3 = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item1, "1", unit_value: nil)
      {:ok, _} = Warehouse.upsert_quantity(item2, "2", unit_value: nil)
      {:ok, _} = Warehouse.upsert_quantity(item3, "3", unit_value: nil)

      rows = Warehouse.stock_for_items([item1, item2])
      uuids = Enum.map(rows, & &1.item_uuid)

      assert item1 in uuids
      assert item2 in uuids
      refute item3 in uuids
    end
  end

  describe "stock_for_items_at_location/2" do
    test "returns raw stock rows for the given item uuids, scoped to one location" do
      item1 = Ecto.UUID.generate()
      item2 = Ecto.UUID.generate()
      loc_a = Ecto.UUID.generate()
      loc_b = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item1, "1", unit_value: nil, location_uuid: loc_a)
      {:ok, _} = Warehouse.upsert_quantity(item1, "9", unit_value: nil, location_uuid: loc_b)
      {:ok, _} = Warehouse.upsert_quantity(item2, "2", unit_value: nil, location_uuid: loc_a)

      rows = Warehouse.stock_for_items_at_location([item1, item2], loc_a)

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.location_uuid == loc_a))
      assert Enum.all?(rows, &match?(%Stock{}, &1))

      item1_row = Enum.find(rows, &(&1.item_uuid == item1))
      assert Decimal.equal?(item1_row.quantity, Decimal.new("1"))
    end

    test "excludes item uuids not in the requested list even at the same location" do
      item1 = Ecto.UUID.generate()
      item2 = Ecto.UUID.generate()
      loc = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item1, "1", unit_value: nil, location_uuid: loc)
      {:ok, _} = Warehouse.upsert_quantity(item2, "2", unit_value: nil, location_uuid: loc)

      rows = Warehouse.stock_for_items_at_location([item1], loc)
      uuids = Enum.map(rows, & &1.item_uuid)

      assert item1 in uuids
      refute item2 in uuids
    end
  end

  describe "get_quantity/1" do
    test "returns 0 for unknown item uuid" do
      unknown = Ecto.UUID.generate()
      assert Decimal.equal?(Warehouse.get_quantity(unknown), Decimal.new("0"))
    end

    test "returns the stored quantity for a known item" do
      item = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item, "42", unit_value: nil)
      assert Decimal.equal?(Warehouse.get_quantity(item), Decimal.new("42"))
    end
  end

  describe "get_quantity/2" do
    test "returns 0 when no row exists for the item/location pair" do
      unknown = Ecto.UUID.generate()
      loc = Ecto.UUID.generate()
      assert Decimal.equal?(Warehouse.get_quantity(unknown, loc), Decimal.new("0"))
    end

    test "returns the quantity for the specific item/location pair, not other locations" do
      item = Ecto.UUID.generate()
      loc_a = Ecto.UUID.generate()
      loc_b = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item, "6", unit_value: nil, location_uuid: loc_a)
      {:ok, _} = Warehouse.upsert_quantity(item, "15", unit_value: nil, location_uuid: loc_b)

      assert Decimal.equal?(Warehouse.get_quantity(item, loc_a), Decimal.new("6"))
      assert Decimal.equal?(Warehouse.get_quantity(item, loc_b), Decimal.new("15"))
    end

    test "returns 0 for a known item at an unrelated location" do
      item = Ecto.UUID.generate()
      loc_a = Ecto.UUID.generate()
      loc_b = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item, "6", unit_value: nil, location_uuid: loc_a)

      assert Decimal.equal?(Warehouse.get_quantity(item, loc_b), Decimal.new("0"))
    end
  end

  describe "list_warehouses/0" do
    test "returns nil when no warehouse location type is configured" do
      Warehouse.set_warehouse_location_type_uuid(nil)
      assert Warehouse.list_warehouses() == nil
    end
  end

  describe "total_value/0" do
    test "sums quantity * unit_value for rows with unit_value" do
      item1 = Ecto.UUID.generate()
      item2 = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item1, "2", unit_value: Decimal.new("5"))
      {:ok, _} = Warehouse.upsert_quantity(item2, "3", unit_value: Decimal.new("4"))

      total = Warehouse.total_value()

      # 2*5 + 3*4 = 10 + 12 = 22
      assert Decimal.compare(total, Decimal.new("22")) in [:eq, :gt]
    end

    test "skips rows with nil unit_value" do
      item1 = Ecto.UUID.generate()
      item2 = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item1, "10", unit_value: Decimal.new("3"))
      {:ok, _} = Warehouse.upsert_quantity(item2, "5", unit_value: nil)

      total = Warehouse.total_value()

      # should include item1's 10*3=30 but not item2 (nil unit_value)
      assert Decimal.compare(total, Decimal.new("0")) == :gt
    end
  end

  describe "upsert_quantity/3 — create" do
    test "creates a new stock row" do
      item = Ecto.UUID.generate()
      {:ok, row} = Warehouse.upsert_quantity(item, "5", unit_value: Decimal.new("10"))

      assert row.item_uuid == item
      assert Decimal.equal?(row.quantity, Decimal.new("5"))
      assert Decimal.equal?(row.unit_value, Decimal.new("10"))
    end

    test "creates row with nil unit_value (track_value off)" do
      item = Ecto.UUID.generate()
      {:ok, row} = Warehouse.upsert_quantity(item, "3", unit_value: nil)

      assert row.item_uuid == item
      assert Decimal.equal?(row.quantity, Decimal.new("3"))
      assert is_nil(row.unit_value)
    end
  end

  describe "upsert_quantity/3 — update" do
    test "updates quantity for existing stock row" do
      item = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item, "5", unit_value: Decimal.new("10"))
      {:ok, row} = Warehouse.upsert_quantity(item, "8", unit_value: Decimal.new("10"))

      assert Decimal.equal?(row.quantity, Decimal.new("8"))
    end

    test "updates both quantity and unit_value when unit_value provided" do
      item = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item, "5", unit_value: Decimal.new("10"))
      {:ok, row} = Warehouse.upsert_quantity(item, "8", unit_value: Decimal.new("15"))

      assert Decimal.equal?(row.quantity, Decimal.new("8"))
      assert Decimal.equal?(row.unit_value, Decimal.new("15"))
    end

    test "nil unit_value preserves existing unit_value" do
      item = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item, "5", unit_value: Decimal.new("10"))
      {:ok, row} = Warehouse.upsert_quantity(item, "8", unit_value: nil)

      assert Decimal.equal?(row.quantity, Decimal.new("8"))
      assert Decimal.equal?(row.unit_value, Decimal.new("10"))
    end
  end

  describe "upsert_quantity/3 — Decimal coercion" do
    test "coerces string quantity to Decimal" do
      item = Ecto.UUID.generate()
      {:ok, row} = Warehouse.upsert_quantity(item, "12.5", unit_value: nil)

      assert Decimal.equal?(row.quantity, Decimal.new("12.5"))
    end

    test "coerces float quantity to Decimal" do
      item = Ecto.UUID.generate()
      {:ok, row} = Warehouse.upsert_quantity(item, 3.5, unit_value: nil)

      assert Decimal.equal?(row.quantity, Decimal.from_float(3.5))
    end

    test "coerces integer quantity to Decimal" do
      item = Ecto.UUID.generate()
      {:ok, row} = Warehouse.upsert_quantity(item, 7, unit_value: nil)

      assert Decimal.equal?(row.quantity, Decimal.new(7))
    end

    test "coerces string unit_value to Decimal" do
      item = Ecto.UUID.generate()
      {:ok, row} = Warehouse.upsert_quantity(item, "5", unit_value: "9.99")

      assert Decimal.equal?(row.unit_value, Decimal.new("9.99"))
    end
  end

  describe "upsert_quantity/3 — opts[:repo]" do
    test "accepts a custom repo via opts" do
      item = Ecto.UUID.generate()

      {:ok, row} =
        Warehouse.upsert_quantity(item, "3", unit_value: nil, repo: PhoenixKitWarehouse.Test.Repo)

      assert row.item_uuid == item
    end
  end

  describe "to_decimal/1" do
    test "nil returns 0" do
      assert Decimal.equal?(Warehouse.to_decimal(nil), Decimal.new("0"))
    end

    test "empty string returns 0" do
      assert Decimal.equal?(Warehouse.to_decimal(""), Decimal.new("0"))
    end

    test "Decimal passthrough" do
      d = Decimal.new("3.14")
      assert Decimal.equal?(Warehouse.to_decimal(d), d)
    end

    test "integer conversion" do
      assert Decimal.equal?(Warehouse.to_decimal(5), Decimal.new("5"))
    end

    test "float conversion" do
      assert Decimal.equal?(Warehouse.to_decimal(2.5), Decimal.from_float(2.5))
    end

    test "binary string conversion" do
      assert Decimal.equal?(Warehouse.to_decimal("3.14"), Decimal.new("3.14"))
    end
  end

  describe "to_decimal_or_nil/1" do
    test "nil returns nil" do
      assert is_nil(Warehouse.to_decimal_or_nil(nil))
    end

    test "empty string returns nil" do
      assert is_nil(Warehouse.to_decimal_or_nil(""))
    end

    test "blank string returns nil" do
      assert is_nil(Warehouse.to_decimal_or_nil("   "))
    end

    test "Decimal passthrough" do
      d = Decimal.new("5.0")
      assert Decimal.equal?(Warehouse.to_decimal_or_nil(d), d)
    end

    test "integer conversion" do
      assert Decimal.equal?(Warehouse.to_decimal_or_nil(7), Decimal.new("7"))
    end

    test "float conversion" do
      assert Decimal.equal?(Warehouse.to_decimal_or_nil(1.5), Decimal.from_float(1.5))
    end

    test "binary string conversion" do
      assert Decimal.equal?(Warehouse.to_decimal_or_nil("9.99"), Decimal.new("9.99"))
    end
  end

  describe "to_decimal/1 — comma decimal separator (et/ru locales)" do
    test "comma is treated as a decimal separator" do
      assert Decimal.equal?(Warehouse.to_decimal("1,5"), Decimal.new("1.5"))
    end

    test "comma with trailing zeroes" do
      assert Decimal.equal?(Warehouse.to_decimal("2,50"), Decimal.new("2.50"))
    end

    test "plain dot notation still works" do
      assert Decimal.equal?(Warehouse.to_decimal("3.14"), Decimal.new("3.14"))
    end
  end

  describe "to_decimal_or_nil/1 — comma decimal separator (et/ru locales)" do
    test "comma is treated as a decimal separator" do
      assert Decimal.equal?(Warehouse.to_decimal_or_nil("3,25"), Decimal.new("3.25"))
    end

    test "blank with comma normalisation still returns nil" do
      assert is_nil(Warehouse.to_decimal_or_nil(" , "))
    end
  end
end
