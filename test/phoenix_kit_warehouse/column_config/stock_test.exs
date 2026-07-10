defmodule PhoenixKitWarehouse.ColumnConfig.StockTest do
  use ExUnit.Case, async: true
  alias PhoenixKitWarehouse.ColumnConfig.Stock, as: C

  defp entry(overrides) do
    Map.merge(
      %{
        item: %{},
        display_name: "Widget",
        sku: "W-1",
        catalogue_name: "Hardware",
        category_name: "Bolts",
        unit_label: "pc",
        quantity: Decimal.new("5"),
        unit_value: Decimal.new("2.00"),
        total_value: Decimal.new("10.00")
      },
      overrides
    )
  end

  test "scope/0 is warehouse_stock" do
    assert C.scope() == "warehouse_stock"
  end

  test "default_columns/0 are the starred set in order" do
    assert C.default_columns() == ["item", "catalogue", "quantity", "total_value"]
  end

  test "all_column_ids/0 covers every column" do
    assert C.all_column_ids() ==
             [
               "item",
               "sku",
               "catalogue",
               "category",
               "unit",
               "quantity",
               "unit_value",
               "total_value"
             ]
  end

  test "validate_columns/1 drops unknown ids, keeps order" do
    assert C.validate_columns(["quantity", "bogus", "item"]) == ["quantity", "item"]
  end

  test "validate_filters/1 keeps only filterable ids" do
    assert C.validate_filters(["catalogue", "nope"]) == ["catalogue"]
  end

  test "text filter on item matches display_name, case-insensitive" do
    meta = C.column_metadata_map()["item"]
    rows = [entry(%{display_name: "Widget"}), entry(%{display_name: "Gadget"})]
    assert [%{display_name: "Widget"}] = meta.filter_apply.(rows, "wid")
    assert rows == meta.filter_apply.(rows, "")
  end

  test "enum filter on catalogue matches exactly; options derive from entries" do
    meta = C.column_metadata_map()["catalogue"]
    rows = [entry(%{catalogue_name: "Hardware"}), entry(%{catalogue_name: "Tools"})]
    assert [%{catalogue_name: "Tools"}] = meta.filter_apply.(rows, "Tools")
    assert meta.filter_options.(rows) == [{"Hardware", "Hardware"}, {"Tools", "Tools"}]
  end

  test "numeric_range filter on quantity keeps rows within [min, max]" do
    meta = C.column_metadata_map()["quantity"]

    rows = [
      entry(%{quantity: Decimal.new("1")}),
      entry(%{quantity: Decimal.new("5")}),
      entry(%{quantity: Decimal.new("9")})
    ]

    assert [%{quantity: q}] = meta.filter_apply.(rows, %{"min" => "3", "max" => "7"})
    assert Decimal.equal?(q, Decimal.new("5"))
  end

  test "sort_key for total_value orders by decimal value" do
    meta = C.column_metadata_map()["total_value"]
    lo = entry(%{total_value: Decimal.new("3.00")})
    hi = entry(%{total_value: Decimal.new("30.00")})
    assert Enum.sort_by([hi, lo], meta.sort_key, :asc) == [lo, hi]
  end

  test "total_value sort_key treats nil as 0.0" do
    meta = C.column_metadata_map()["total_value"]
    assert meta.sort_key.(entry(%{total_value: nil})) == 0.0
  end
end
