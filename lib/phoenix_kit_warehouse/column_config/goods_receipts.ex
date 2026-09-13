defmodule PhoenixKitWarehouse.ColumnConfig.GoodsReceipts do
  @moduledoc """
  Column registry for the goods receipts list LiveView.

  Operates on enriched goods-receipt maps of shape:
  `%{uuid, number, status, status_label, supplier_order_uuid, supplier_uuid,
     supplier_name, location_uuid, inserted_at, posted_at, lines_count, note,
     created_by, performed_by}`.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_goods_receipts"

  defp columns do
    [
      number_column(),
      status_column(&status_options/1),
      plain_column("supplier_order", fn -> dgettext("default", "Supplier Order") end),
      supplier_column(),
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
