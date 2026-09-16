defmodule PhoenixKitWarehouse.ColumnConfig.SharedColumnsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The six document registries build most of their columns from the shared
  constructors in `PhoenixKitWarehouse.ColumnConfig`. These tests pin the
  contract those constructors keep for every list at once, which is the
  whole point of sharing them.
  """

  alias PhoenixKitWarehouse.ColumnConfig

  @document_registries [
    ColumnConfig.GoodsIssues,
    ColumnConfig.GoodsReceipts,
    ColumnConfig.InternalOrders,
    ColumnConfig.Inventories,
    ColumnConfig.SupplierOrders,
    ColumnConfig.Transfers
  ]

  test "every document registry offers the creator/responsible pair, off by default" do
    for registry <- @document_registries do
      ids = registry.all_column_ids()
      assert "created_by" in ids, "#{inspect(registry)} lacks created_by"
      assert "performed_by" in ids, "#{inspect(registry)} lacks performed_by"
      refute "created_by" in registry.default_columns()
      refute "performed_by" in registry.default_columns()
    end
  end

  test "every document registry leads with a sortable, numeric-filterable number column" do
    for registry <- @document_registries do
      assert %{id: "number", sortable?: true, filter_type: :numeric_range, default?: true} =
               hd(registry.available_columns())
    end
  end

  test "number_column/0's numeric_range filter accepts comma and dot decimals" do
    col = ColumnConfig.number_column()
    entries = [%{number: 1}, %{number: 2}, %{number: 3}]

    assert col.filter_apply.(entries, %{"min" => "1,5"}) == [%{number: 2}, %{number: 3}]
    assert col.filter_apply.(entries, %{"max" => "1.5"}) == [%{number: 1}]
  end

  test "number_column/0's numeric_range filter ignores unparseable text" do
    col = ColumnConfig.number_column()
    entries = [%{number: 1}, %{number: 2}]

    assert col.filter_apply.(entries, %{"min" => "not-a-number"}) == entries
  end

  test "timestamp_column/4 sorts on the named field and filters by date range" do
    col = ColumnConfig.timestamp_column("shipped_at", :shipped_at, fn -> "Shipped" end)

    assert %{id: "shipped_at", default?: false, filter_type: :date_range, default_dir: :desc} =
             col

    assert col.label.() == "Shipped"

    early = %{shipped_at: ~U[2026-01-01 10:00:00Z]}
    late = %{shipped_at: ~U[2026-03-01 10:00:00Z]}
    assert col.sort_key.(early) < col.sort_key.(late)
    assert col.filter_apply.([early, late], %{"from" => "2026-02-01"}) == [late]
  end

  test "text_column/4 sorts and filters on the named field, tolerating nil" do
    col = ColumnConfig.text_column("note", :note, fn -> "Note" end, default?: true)

    assert %{id: "note", default?: true, filter_type: :text, default_dir: :asc} = col
    assert col.sort_key.(%{note: nil}) == ""

    entries = [%{note: "Urgent"}, %{note: nil}, %{note: "routine"}]
    assert col.filter_apply.(entries, "URG") == [%{note: "Urgent"}]
  end

  test "status_column/1 takes the per-document option list as a closure" do
    col = ColumnConfig.status_column(fn _entries -> [{"draft", "Draft"}] end)

    assert %{id: "status", filter_type: :enum} = col
    assert col.filter_options.([]) == [{"draft", "Draft"}]

    assert col.filter_apply.([%{status: "draft"}, %{status: "posted"}], "draft") == [
             %{status: "draft"}
           ]
  end

  test "plain_column/2 is shown by default and neither sortable nor filterable" do
    assert %{id: "x", default?: true, sortable?: false, filterable?: false} =
             ColumnConfig.plain_column("x", fn -> "X" end)
  end
end
