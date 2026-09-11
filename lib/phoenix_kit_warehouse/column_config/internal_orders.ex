defmodule PhoenixKitWarehouse.ColumnConfig.InternalOrders do
  @moduledoc """
  Column registry for the internal orders list LiveView.

  Operates on enriched internal-order maps of shape `%{uuid, number, status,
  status_label, location_uuid, inserted_at, posted_at, lines_count}`.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_internal_orders"

  defp columns do
    [
      number_column(),
      status_column(),
      date_column(),
      sub_order_column(),
      lines_count_column(),
      posted_at_column(),
      note_column(),
      created_by_column(),
      performed_by_column()
    ]
  end

  defp number_column do
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
    }
  end

  defp status_column do
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
    }
  end

  defp date_column do
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
    }
  end

  defp sub_order_column do
    %{
      id: "sub_order",
      label: fn -> dgettext("default", "Sub-order") end,
      default?: true,
      align: :left,
      sortable?: false,
      filterable?: false
    }
  end

  defp lines_count_column do
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
    }
  end

  defp posted_at_column do
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
    }
  end

  defp note_column do
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
  end

  # Who opened the document and who is answerable for it. Off by default —
  # the lists are already wide — but available in the column picker, since
  # "who did this" is the first question asked about a document nobody
  # recognises. Both come from the same enrich step, so switching them on
  # costs no extra query.
  defp created_by_column do
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
    }
  end

  defp performed_by_column do
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
  end
end
