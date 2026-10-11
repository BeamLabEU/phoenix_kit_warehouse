defmodule PhoenixKitWarehouse.ColumnConfig.ReasonExternalRefTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.ColumnConfig
  alias PhoenixKitWarehouse.ColumnConfig.GoodsIssues
  alias PhoenixKitWarehouse.ColumnConfig.GoodsReceipts
  alias PhoenixKitWarehouse.ColumnConfig.Inventories

  describe "goods issues" do
    test "offer reason (on by default) and external_ref (off by default)" do
      assert "reason" in GoodsIssues.all_column_ids()
      assert "external_ref" in GoodsIssues.all_column_ids()
      assert "reason" in GoodsIssues.default_columns()
      refute "external_ref" in GoodsIssues.default_columns()
    end

    test "reason is a sortable enum column over the four reasons" do
      meta = GoodsIssues.column_metadata_map()["reason"]

      assert %{sortable?: true, filterable?: true, filter_type: :enum} = meta

      assert Enum.map(meta.filter_options.([]), &elem(&1, 0)) ==
               ~w(production sale damage other)

      rows = [%{reason: "sale"}, %{reason: "damage"}]
      assert [%{reason: "damage"}] = meta.filter_apply.(rows, "damage")
      assert rows == meta.filter_apply.(rows, "")
    end

    test "external_ref is a sortable text column" do
      meta = GoodsIssues.column_metadata_map()["external_ref"]
      rows = [%{external_ref: "SHOP-1"}, %{external_ref: nil}, %{external_ref: "POS-9"}]

      assert %{sortable?: true, filterable?: true, filter_type: :text} = meta
      assert [%{external_ref: "SHOP-1"}] = meta.filter_apply.(rows, "shop")
      assert Enum.sort_by(rows, meta.sort_key) |> hd() == %{external_ref: nil}
    end
  end

  describe "goods receipts and inventories" do
    test "offer external_ref, off by default" do
      for registry <- [GoodsReceipts, Inventories] do
        assert "external_ref" in registry.all_column_ids()
        refute "external_ref" in registry.default_columns()

        assert %{filter_type: :text, sortable?: true} =
                 registry.column_metadata_map()["external_ref"]
      end
    end
  end

  test "external_ref_column/0 is the shared constructor" do
    assert %{id: "external_ref", default?: false, align: :left} =
             ColumnConfig.external_ref_column()
  end
end
