defmodule PhoenixKitWarehouse.ColumnConfig.Transfers do
  @moduledoc """
  Column registry for the transfers list LiveView.

  Operates on enriched transfer maps of shape:
  `%{uuid, number, status, status_label, source_location_uuid,
     source_location_name, destination_location_uuid,
     destination_location_name, inserted_at, shipped_at, received_at, note,
     lines_count, created_by, performed_by}`.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_transfers"

  defp columns do
    [
      number_column(),
      status_column(&status_options/1),
      date_column(),
      plain_column("source_location", fn -> dgettext("default", "Source warehouse") end),
      plain_column("destination_location", fn -> dgettext("default", "Destination warehouse") end),
      lines_count_column(),
      timestamp_column("shipped_at", :shipped_at, fn -> dgettext("default", "Shipped at") end),
      timestamp_column("received_at", :received_at, fn -> dgettext("default", "Received at") end),
      note_column(),
      created_by_column(),
      performed_by_column()
    ]
  end

  defp status_options(_entries) do
    [
      {"draft", dgettext("default", "Draft")},
      {"in_transit", dgettext("default", "In transit")},
      {"done", dgettext("default", "Done")},
      {"cancelled", dgettext("default", "Cancelled")}
    ]
  end
end
