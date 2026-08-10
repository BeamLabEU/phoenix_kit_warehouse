defmodule PhoenixKitWarehouse.Web.UrlStateSortColumnsTest do
  @moduledoc """
  Every index LiveView declares its sortable columns twice: once as
  `sortable?: true` in its `ColumnConfig` (what the table header renders and
  what `parse_sort_by/1` accepts), and once as the `in:` whitelist of the
  `sort_by` parameter it declares to `PhoenixKitWeb.Live.UrlState`.

  The two must agree, and nothing at compile time makes them. A column added as
  sortable but left out of the whitelist cannot be sorted by at all: UrlState
  sanitizes a pushed value outside `in:` back to the default, so the header
  click re-sorts by the default column instead — silently, with no error
  anywhere. A column whitelisted but not sortable is the mirror image: `?sort=`
  survives a reload naming a column the list will not sort by.

  Pure unit test — no repo, no LiveView mount.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.ColumnConfig
  alias PhoenixKitWarehouse.Web

  @screens [
    {Web.GoodsIssueIndexLive, ColumnConfig.GoodsIssues},
    {Web.GoodsReceiptIndexLive, ColumnConfig.GoodsReceipts},
    {Web.InternalOrderIndexLive, ColumnConfig.InternalOrders},
    {Web.InventoriesLive, ColumnConfig.Inventories},
    {Web.StockLive, ColumnConfig.Stock},
    {Web.SupplierOrderIndexLive, ColumnConfig.SupplierOrders},
    {Web.TransferIndexLive, ColumnConfig.Transfers}
  ]

  defp sortable_ids(config) do
    meta = config.column_metadata_map()

    config.all_column_ids()
    |> Enum.filter(&match?(%{sortable?: true}, Map.get(meta, &1)))
    |> Enum.sort()
  end

  defp spec!(live, key) do
    Enum.find(live.__phoenix_kit_url_state__().params, &(&1.key == key)) ||
      flunk("#{inspect(live)} declares no UrlState param #{inspect(key)}")
  end

  for {live, config} <- @screens do
    describe "#{inspect(live)} URL state" do
      @live live
      @config config

      test "?sort= accepts exactly the sortable columns" do
        assert Enum.sort(spec!(@live, :sort_by).allowed) == sortable_ids(@config)
      end

      test "the default sort column is itself sortable" do
        assert spec!(@live, :sort_by).default in sortable_ids(@config)
      end

      # A non-sortable first column is what `next_sort_by/1` has to skip when
      # the current sort column is hidden — the re-pick is pushed through
      # push_url_state, which drops anything the whitelist rejects.
      test "?dir= only ever decodes to an existing atom" do
        spec = spec!(@live, :sort_dir)

        assert spec.cast == :atom
        assert Enum.sort(spec.allowed) == [:asc, :desc]
        assert spec.default in spec.allowed
      end
    end
  end
end
