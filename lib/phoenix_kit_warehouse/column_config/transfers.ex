defmodule PhoenixKitWarehouse.ColumnConfig.Transfers do
  @moduledoc """
  Column registry for the transfers list LiveView.

  Operates on enriched transfer maps of shape:
  `%{uuid, number, status, status_label, source_location_uuid,
     source_location_name, destination_location_uuid,
     destination_location_name, inserted_at, shipped_at, received_at, note,
     lines_count}`.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_transfers"

  defp columns do
    [
      %{
        id: "number",
        label: fn -> dgettext("default", "#") end,
        default?: true,
        align: :left,
        sortable?: true,
        sort_key: &(&1.number || 0),
        default_dir: :desc,
        filterable?: true,
        filter_type: :numeric_range,
        filter_apply: numeric_range_filter(&(&1.number || 0))
      },
      %{
        id: "status",
        label: fn -> dgettext("default", "Status") end,
        default?: true,
        align: :left,
        sortable?: true,
        sort_key: &(&1.status || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :enum,
        filter_options: fn _entries ->
          [
            {"draft", dgettext("default", "Draft")},
            {"in_transit", dgettext("default", "In transit")},
            {"done", dgettext("default", "Done")},
            {"cancelled", dgettext("default", "Cancelled")}
          ]
        end,
        filter_apply: enum_filter(&(&1.status || ""))
      },
      %{
        id: "date",
        label: fn -> dgettext("default", "Date") end,
        default?: true,
        align: :left,
        sortable?: true,
        sort_key: &datetime_to_unix(&1.inserted_at),
        default_dir: :desc,
        filterable?: true,
        filter_type: :date_range,
        filter_apply: date_range_filter(&date_of(&1.inserted_at))
      },
      %{
        id: "source_location",
        label: fn -> dgettext("default", "Source warehouse") end,
        default?: true,
        align: :left,
        sortable?: false,
        filterable?: false
      },
      %{
        id: "destination_location",
        label: fn -> dgettext("default", "Destination warehouse") end,
        default?: true,
        align: :left,
        sortable?: false,
        filterable?: false
      },
      %{
        id: "lines_count",
        label: fn -> dgettext("default", "Lines") end,
        default?: true,
        align: :left,
        sortable?: true,
        sort_key: &(&1.lines_count || 0),
        default_dir: :desc,
        filterable?: true,
        filter_type: :numeric_range,
        filter_apply: numeric_range_filter(&(&1.lines_count || 0))
      },
      %{
        id: "shipped_at",
        label: fn -> dgettext("default", "Shipped at") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &datetime_to_unix(&1.shipped_at),
        default_dir: :desc,
        filterable?: true,
        filter_type: :date_range,
        filter_apply: date_range_filter(&date_of(&1.shipped_at))
      },
      %{
        id: "received_at",
        label: fn -> dgettext("default", "Received at") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &datetime_to_unix(&1.received_at),
        default_dir: :desc,
        filterable?: true,
        filter_type: :date_range,
        filter_apply: date_range_filter(&date_of(&1.received_at))
      },
      %{
        id: "note",
        label: fn -> dgettext("default", "Note") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &(&1.note || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :text,
        filter_apply: text_filter(&(&1.note || ""))
      },
      # Who opened the document and who is answerable for it. Off by default —
      # the lists are already wide — but available in the column picker, since
      # "who did this" is the first question asked about a document nobody
      # recognises. Both come from the same enrich step, so switching them on
      # costs no extra query.
      %{
        id: "created_by",
        label: fn -> dgettext("default", "Created by") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &(&1.created_by || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :text,
        filter_apply: text_filter(&(&1.created_by || ""))
      },
      %{
        id: "performed_by",
        label: fn -> dgettext("default", "Responsible") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &(&1.performed_by || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :text,
        filter_apply: text_filter(&(&1.performed_by || ""))
      }
    ]
  end
end
