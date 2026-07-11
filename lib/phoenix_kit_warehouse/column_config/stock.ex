defmodule PhoenixKitWarehouse.ColumnConfig.Stock do
  @moduledoc """
  Column registry for the warehouse stock-balances ("In stock") flat list LiveView.

  Operates on enriched flat stock maps of shape `%{item, display_name, sku,
  catalogue_name, category_name, unit_label, quantity, unit_value,
  total_value, min_quantity, available, below_min?}` where `quantity`,
  `unit_value`, `total_value`, `min_quantity`, and `available` are `Decimal`
  (or nil for value columns), `below_min?` is boolean, and the rest are
  strings.

  `min_quantity` / `available` / `below_min?` come from
  `PhoenixKitWarehouse.Deficits` and `PhoenixKitWarehouse.MinStockSettings`
  (§5, deficit tracking) — deliberately global-per-item (summed across every
  warehouse), not scoped to the current `warehouse_scope`, same as
  `Deficits.available_by_item/0` itself.
  """

  use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_stock"

  defp columns do
    [
      %{
        id: "item",
        label: fn -> dgettext("default", "Item") end,
        default?: true,
        align: :left,
        sortable?: true,
        sort_key: &String.downcase(&1.display_name || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :text,
        filter_apply: text_filter(&(&1.display_name || ""))
      },
      %{
        id: "sku",
        label: fn -> dgettext("default", "SKU") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &(&1.sku || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :text,
        filter_apply: text_filter(&(&1.sku || ""))
      },
      %{
        id: "catalogue",
        label: fn -> dgettext("default", "Catalogue") end,
        default?: true,
        align: :left,
        sortable?: true,
        sort_key: &(&1.catalogue_name || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :enum,
        filter_options: fn entries -> distinct_options(entries, :catalogue_name) end,
        filter_apply: enum_filter(&(&1.catalogue_name || ""))
      },
      %{
        id: "category",
        label: fn -> dgettext("default", "Category") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &(&1.category_name || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :enum,
        filter_options: fn entries -> distinct_options(entries, :category_name) end,
        filter_apply: enum_filter(&(&1.category_name || ""))
      },
      %{
        id: "unit",
        label: fn -> dgettext("default", "Unit") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &(&1.unit_label || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :enum,
        filter_options: fn entries -> distinct_options(entries, :unit_label) end,
        filter_apply: enum_filter(&(&1.unit_label || ""))
      },
      %{
        id: "quantity",
        label: fn -> dgettext("default", "In stock") end,
        default?: true,
        align: :right,
        sortable?: true,
        sort_key: &decimal_to_float(&1.quantity),
        default_dir: :desc,
        filterable?: true,
        filter_type: :numeric_range,
        filter_apply: numeric_range_filter(&decimal_to_float(&1.quantity))
      },
      %{
        id: "unit_value",
        label: fn -> dgettext("default", "Unit value") end,
        default?: false,
        align: :right,
        sortable?: true,
        sort_key: &decimal_to_float(&1.unit_value),
        default_dir: :desc,
        filterable?: true,
        filter_type: :numeric_range,
        filter_apply: numeric_range_filter(&decimal_to_float(&1.unit_value))
      },
      %{
        id: "total_value",
        label: fn -> dgettext("default", "Total value") end,
        default?: true,
        align: :right,
        sortable?: true,
        sort_key: &decimal_to_float(&1.total_value),
        default_dir: :desc,
        filterable?: true,
        filter_type: :numeric_range,
        filter_apply: numeric_range_filter(&decimal_to_float(&1.total_value))
      },
      %{
        id: "min_quantity",
        label: fn -> dgettext("default", "Min. quantity") end,
        default?: false,
        align: :right,
        sortable?: true,
        sort_key: &decimal_to_float(&1.min_quantity),
        default_dir: :desc,
        filterable?: true,
        filter_type: :numeric_range,
        filter_apply: numeric_range_filter(&decimal_to_float(&1.min_quantity))
      },
      %{
        id: "available",
        label: fn -> dgettext("default", "Available") end,
        default?: false,
        align: :right,
        sortable?: true,
        sort_key: &decimal_to_float(&1.available),
        default_dir: :asc,
        filterable?: true,
        filter_type: :numeric_range,
        filter_apply: numeric_range_filter(&decimal_to_float(&1.available))
      },
      %{
        id: "deficit",
        label: fn -> dgettext("default", "Deficit") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: & &1.below_min?,
        default_dir: :desc,
        filterable?: true,
        filter_type: :enum,
        filter_options: fn _entries ->
          [{"yes", dgettext("default", "Yes")}, {"no", dgettext("default", "No")}]
        end,
        filter_apply: enum_filter(&if(&1.below_min?, do: "yes", else: "no"))
      }
    ]
  end
end
