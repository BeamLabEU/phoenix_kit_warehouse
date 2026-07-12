defmodule PhoenixKitWarehouse.MinStockSettingsTest do
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.MinStock
  alias PhoenixKitWarehouse.MinStockSettings
  alias PhoenixKitWarehouse.Test.Repo

  describe "get_min_quantity/1" do
    test "returns 0 for an item with no configured minimum" do
      item = Ecto.UUID.generate()

      assert Decimal.equal?(MinStockSettings.get_min_quantity(item), Decimal.new("0"))
    end

    test "returns the configured minimum quantity" do
      item = Ecto.UUID.generate()
      {:ok, _} = MinStockSettings.set_min_quantity(item, "12.5")

      assert Decimal.equal?(MinStockSettings.get_min_quantity(item), Decimal.new("12.5"))
    end
  end

  describe "set_min_quantity/2" do
    test "creates a row when none exists" do
      item = Ecto.UUID.generate()

      assert {:ok, %MinStock{} = row} = MinStockSettings.set_min_quantity(item, "5")
      assert row.item_uuid == item
      assert Decimal.equal?(row.min_quantity, Decimal.new("5"))
    end

    test "upserts — a second call updates the existing row instead of inserting a new one" do
      item = Ecto.UUID.generate()
      {:ok, _} = MinStockSettings.set_min_quantity(item, "5")
      {:ok, _} = MinStockSettings.set_min_quantity(item, "9")

      assert Decimal.equal?(MinStockSettings.get_min_quantity(item), Decimal.new("9"))

      rows = Repo.all(from(m in MinStock, where: m.item_uuid == ^item))
      assert length(rows) == 1
    end

    test "coerces a comma decimal string like StockLedger.to_decimal/1 does" do
      item = Ecto.UUID.generate()
      {:ok, row} = MinStockSettings.set_min_quantity(item, "1,5")

      assert Decimal.equal?(row.min_quantity, Decimal.new("1.5"))
    end

    test "rejects a negative quantity" do
      item = Ecto.UUID.generate()

      assert {:error, changeset} = MinStockSettings.set_min_quantity(item, "-1")
      assert %{min_quantity: ["must be greater than or equal to 0"]} = errors_on(changeset)
    end
  end

  describe "min_stock_map/0" do
    test "includes only items with min_quantity > 0" do
      above_zero = Ecto.UUID.generate()
      exactly_zero = Ecto.UUID.generate()
      {:ok, _} = MinStockSettings.set_min_quantity(above_zero, "3")
      {:ok, _} = MinStockSettings.set_min_quantity(exactly_zero, "0")

      map = MinStockSettings.min_stock_map()

      assert Decimal.equal?(map[above_zero], Decimal.new("3"))
      refute Map.has_key?(map, exactly_zero)
    end

    test "omits items with no row at all" do
      untouched = Ecto.UUID.generate()

      refute Map.has_key?(MinStockSettings.min_stock_map(), untouched)
    end
  end

  describe "delete_min_quantity/1" do
    test "removes the row for the given item" do
      item = Ecto.UUID.generate()
      {:ok, _} = MinStockSettings.set_min_quantity(item, "4")

      assert :ok = MinStockSettings.delete_min_quantity(item)
      assert Decimal.equal?(MinStockSettings.get_min_quantity(item), Decimal.new("0"))
      assert Repo.get_by(MinStock, item_uuid: item) == nil
    end

    test "is idempotent — deleting a non-existent row does not raise" do
      item = Ecto.UUID.generate()

      assert :ok = MinStockSettings.delete_min_quantity(item)
    end
  end
end
