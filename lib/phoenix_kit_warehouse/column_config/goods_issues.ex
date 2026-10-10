defmodule PhoenixKitWarehouse.ColumnConfig.GoodsIssues do
  @moduledoc """
  Column registry for the goods issues list LiveView.

  Operates on enriched goods-issue maps of shape:
  `%{uuid, number, status, status_label, reason, reason_label, external_ref,
     internal_order_uuid, location_uuid, inserted_at, posted_at, lines_count,
     note, created_by, performed_by}`.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_goods_issues"

  alias PhoenixKitWarehouse.GoodsIssues

  defp columns do
    [
      number_column(),
      status_column(&status_options/1),
      reason_column(),
      plain_column("sub_order", fn -> dgettext("default", "Sub-Order") end),
      internal_order_column(),
      location_column(),
      lines_count_column(),
      date_column(),
      posted_at_column(),
      note_column(),
      external_ref_column(),
      created_by_column(),
      performed_by_column()
    ]
  end

  defp reason_column do
    %{
      id: "reason",
      label: fn -> dgettext("default", "Reason") end,
      default?: true,
      align: :left,
      sortable?: true,
      sort_key: &(&1.reason || ""),
      default_dir: :asc,
      filterable?: true,
      filter_type: :enum,
      filter_options: fn _entries -> GoodsIssues.reason_options() end,
      filter_apply: enum_filter(&(&1.reason || ""))
    }
  end

  defp status_options(_entries) do
    [{"draft", dgettext("default", "Draft")}, {"posted", dgettext("default", "Posted")}]
  end
end
