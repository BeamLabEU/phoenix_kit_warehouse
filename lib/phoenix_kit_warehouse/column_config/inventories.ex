defmodule PhoenixKitWarehouse.ColumnConfig.Inventories do
  @moduledoc """
  Column registry for the warehouse stocktakes (inventory documents) list LiveView.

  Operates on enriched inventory-document maps of shape `%{uuid, number,
  status, status_label, inserted_at, posted_at, note, lines_count,
  created_by, performed_by}`.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_inventories"

  defp columns do
    [
      number_column(),
      date_column(),
      status_column(&status_options/1),
      note_column(default?: true),
      posted_at_column(),
      lines_count_column(default?: false),
      created_by_column(),
      performed_by_column()
    ]
  end

  defp status_options(_entries) do
    [{"draft", dgettext("default", "Draft")}, {"posted", dgettext("default", "Conducted")}]
  end
end
