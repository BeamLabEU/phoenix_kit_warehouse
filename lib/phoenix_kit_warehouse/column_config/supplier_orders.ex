defmodule PhoenixKitWarehouse.ColumnConfig.SupplierOrders do
  @moduledoc """
  Column registry for the supplier orders list LiveView.

  Operates on enriched supplier-order maps of shape:
  `%{uuid, number, status, status_label, supplier_uuid, supplier_name,
     internal_order_uuid, location_uuid, inserted_at, posted_at, lines_count,
     note, created_by, performed_by}`.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_supplier_orders"

  defp columns do
    [
      number_column(),
      status_column(&status_options/1),
      supplier_column(),
      internal_order_column(),
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
