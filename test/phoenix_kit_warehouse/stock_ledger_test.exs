defmodule PhoenixKitWarehouse.StockLedgerTest do
  use PhoenixKitWarehouse.DataCase, async: true

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
