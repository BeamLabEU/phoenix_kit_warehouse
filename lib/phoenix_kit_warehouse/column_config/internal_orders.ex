defmodule PhoenixKitWarehouse.ColumnConfig.InternalOrders do
  @moduledoc """
  Column registry for the internal orders list LiveView.

  Operates on enriched internal-order maps of shape `%{uuid, number, status,
  status_label, location_uuid, inserted_at, posted_at, lines_count}`.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_internal_orders"

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
          [{"draft", dgettext("default", "Draft")}, {"posted", dgettext("default", "Posted")}]
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
        id: "sub_order",
        label: fn -> dgettext("default", "Sub-order") end,
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
        id: "posted_at",
        label: fn -> dgettext("default", "Posted at") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &datetime_to_unix(&1.posted_at),
        default_dir: :desc,
        filterable?: true,
        filter_type: :date_range,
        filter_apply: date_range_filter(&date_of(&1.posted_at))
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
      }
    ]
  end
end
