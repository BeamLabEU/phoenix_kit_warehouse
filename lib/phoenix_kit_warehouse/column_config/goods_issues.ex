defmodule PhoenixKitWarehouse.ColumnConfig.GoodsIssues do
  @moduledoc """
  Column registry for the goods issues list LiveView.

  Operates on enriched goods-issue maps of shape:
  `%{uuid, number, status, status_label, internal_order_uuid,
     location_uuid, inserted_at, posted_at, lines_count, note,
     created_by, performed_by}`.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_goods_issues"

  defp columns do
    [
      number_column(),
      status_column(&status_options/1),
      plain_column("sub_order", fn -> dgettext("default", "Sub-Order") end),
      internal_order_column(),
      location_column(),
      lines_count_column(),
      date_column(),
      posted_at_column(),
      note_column(),
      created_by_column(),
      performed_by_column()
    ]
  end

  defp status_options(_entries) do
    [{"draft", dgettext("default", "Draft")}, {"posted", dgettext("default", "Posted")}]
  end
end
