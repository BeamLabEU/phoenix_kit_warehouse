defmodule PhoenixKitWarehouse.ColumnConfig.InternalOrders do
  @moduledoc """
  Column registry for the internal orders list LiveView.

  Operates on enriched internal-order maps of shape `%{uuid, number, status,
  status_label, location_uuid, inserted_at, posted_at, lines_count, note,
  created_by, performed_by}`.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_internal_orders"

  defp columns do
    [
      number_column(),
      status_column(&status_options/1),
      date_column(),
      plain_column("sub_order", fn -> dgettext("default", "Sub-order") end),
      lines_count_column(),
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
