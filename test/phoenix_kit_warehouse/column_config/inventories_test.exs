defmodule PhoenixKitWarehouse.ColumnConfig.InventoriesTest do
  use ExUnit.Case, async: true
  alias PhoenixKitWarehouse.ColumnConfig.Inventories, as: C

  defp entry(overrides) do
    Map.merge(
      %{
        uuid: "u",
        number: 1,
        status: "draft",
        status_label: "Draft",
        inserted_at: ~U[2026-01-02 10:00:00Z],
        posted_at: nil,
        note: "",
        lines_count: 0
      },
      overrides
    )
  end

  test "scope/0 is warehouse_inventories" do
    assert C.scope() == "warehouse_inventories"
  end

  test "default_columns/0 are the starred set in order" do
    assert C.default_columns() == ["number", "date", "status", "note"]
  end

  test "all_column_ids/0 covers every column" do
    assert C.all_column_ids() == ["number", "date", "status", "note", "posted_at", "lines_count"]
  end

  test "validate_columns/1 drops unknown ids, keeps order" do
    assert C.validate_columns(["note", "bogus", "number"]) == ["note", "number"]
  end

  test "validate_filters/1 keeps only filterable ids" do
    assert C.validate_filters(["status", "nope"]) == ["status"]
  end

  test "numeric_range filter on number keeps rows within [min, max]" do
    meta = C.column_metadata_map()["number"]
    rows = [entry(%{number: 1}), entry(%{number: 5}), entry(%{number: 9})]
    assert [%{number: 5}] = meta.filter_apply.(rows, %{"min" => "3", "max" => "7"})
    assert rows == meta.filter_apply.(rows, %{"min" => "", "max" => ""})
  end

  test "enum filter on status matches exactly; options are draft/posted" do
    meta = C.column_metadata_map()["status"]
    rows = [entry(%{status: "draft"}), entry(%{status: "posted"})]
    assert [%{status: "posted"}] = meta.filter_apply.(rows, "posted")
    assert meta.filter_options.(rows) == [{"draft", "Draft"}, {"posted", "Conducted"}]
  end

  test "date_range filter on date keeps rows within [from, to]" do
    meta = C.column_metadata_map()["date"]

    rows = [
      entry(%{inserted_at: ~U[2026-01-01 00:00:00Z]}),
      entry(%{inserted_at: ~U[2026-02-01 00:00:00Z]})
    ]

    kept = meta.filter_apply.(rows, %{"from" => "2026-01-15", "to" => "2026-02-15"})
    assert [%{inserted_at: ~U[2026-02-01 00:00:00Z]}] = kept
  end

  test "sort_key for number orders ascending by integer" do
    meta = C.column_metadata_map()["number"]

    assert Enum.sort_by([entry(%{number: 9}), entry(%{number: 2})], meta.sort_key, :asc) ==
             [entry(%{number: 2}), entry(%{number: 9})]
  end
end
