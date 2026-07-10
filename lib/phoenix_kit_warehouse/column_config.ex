defmodule PhoenixKitWarehouse.ColumnConfig do
  @moduledoc """
  Shared column-registry engine for warehouse list LiveViews.

  Consolidates what were 6 near-byte-identical `*_column_config.ex` files in
  Andi (`internal_order_column_config.ex`, `inventory_column_config.ex`,
  `stock_column_config.ex`, `supplier_order_column_config.ex`,
  `goods_issue_column_config.ex`, `goods_receipt_column_config.ex`) into one
  engine (`use PhoenixKitWarehouse.ColumnConfig, scope: "..."`) plus 6 short
  `columns/0` definitions — see `PhoenixKitWarehouse.ColumnConfig.{InternalOrders,
  Inventories, Stock, SupplierOrders, GoodsIssues, GoodsReceipts}`.

  Each column is a map with structural metadata:

    * `:id` — string identifier persisted in the per-user view config.
    * `:label` — zero-arity fn returning the translated header label.
    * `:default?` — included in `default_columns/0`.
    * `:align` — `:left` (default) or `:right`.
    * `:sortable?` / `:sort_key` — sortability + key extractor `(entry -> term)`.
    * `:default_dir` — direction the column toggles to on first sort.
    * `:filterable?` / `:filter_type` — `:text | :enum | :date_range | :numeric_range`.
    * `:filter_apply` — `(entries, value) -> entries`.
    * `:filter_options` — for `:enum` only, `(entries -> [{value, label}])`.

  Cell/header rendering stays in the LiveView — only structural metadata lives
  here so it can be reused for table, sort headers, and filter chips.
  """

  defmacro __using__(opts) do
    scope = Keyword.fetch!(opts, :scope)

    quote do
      use Gettext, backend: PhoenixKitWarehouse.Gettext

      import PhoenixKitWarehouse.ColumnConfig,
        only: [
          text_filter: 1,
          enum_filter: 1,
          numeric_range_filter: 1,
          date_range_filter: 1,
          distinct_options: 2,
          datetime_to_unix: 1,
          date_of: 1,
          to_number: 1,
          decimal_to_float: 1
        ]

      @scope unquote(scope)

      @spec scope() :: String.t()
      def scope, do: @scope

      @spec default_columns() :: [String.t()]
      def default_columns,
        do: Enum.filter(columns(), & &1.default?) |> Enum.map(& &1.id)

      @spec all_column_ids() :: [String.t()]
      def all_column_ids, do: Enum.map(columns(), & &1.id)

      @doc "Ordered list of column metadata maps. Used by the picker modal."
      @spec available_columns() :: [map()]
      def available_columns, do: columns()

      @doc "Map `%{id => meta}` for fast lookup during a single render pass."
      @spec column_metadata_map() :: %{String.t() => map()}
      def column_metadata_map, do: Map.new(columns(), &{&1.id, &1})

      @doc "Filter input list to known column ids, preserving order."
      @spec validate_columns([String.t()]) :: [String.t()]
      def validate_columns(ids) when is_list(ids) do
        known = MapSet.new(all_column_ids())
        Enum.filter(ids, &(is_binary(&1) and MapSet.member?(known, &1)))
      end

      @doc "Filter input list to known *filterable* column ids, preserving order."
      @spec validate_filters([String.t()]) :: [String.t()]
      def validate_filters(ids) when is_list(ids) do
        known =
          columns()
          |> Enum.filter(& &1.filterable?)
          |> Enum.map(& &1.id)
          |> MapSet.new()

        Enum.filter(ids, &(is_binary(&1) and MapSet.member?(known, &1)))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Shared filter primitives — return `(entries, value) -> entries` closures.
  # `value` arrives from `phx-change` events, so always treat it as user input.
  # ---------------------------------------------------------------------------

  def text_filter(get_fn) do
    fn entries, value ->
      query = value |> to_string() |> String.trim() |> String.downcase()

      if query == "" do
        entries
      else
        Enum.filter(entries, fn e ->
          e |> get_fn.() |> to_string() |> String.downcase() |> String.contains?(query)
        end)
      end
    end
  end

  def enum_filter(get_fn) do
    fn entries, value ->
      v = to_string(value || "")
      if v == "", do: entries, else: Enum.filter(entries, &(to_string(get_fn.(&1)) == v))
    end
  end

  def numeric_range_filter(get_fn) do
    fn entries, value ->
      min = parse_number(Map.get(value || %{}, "min"))
      max = parse_number(Map.get(value || %{}, "max"))

      if is_nil(min) and is_nil(max) do
        entries
      else
        Enum.filter(entries, fn e ->
          n = e |> get_fn.() |> to_number()
          (is_nil(min) or n >= min) and (is_nil(max) or n <= max)
        end)
      end
    end
  end

  def date_range_filter(get_fn) do
    fn entries, value ->
      from = parse_date(Map.get(value || %{}, "from"))
      to = parse_date(Map.get(value || %{}, "to"))

      if is_nil(from) and is_nil(to) do
        entries
      else
        Enum.filter(entries, &date_in_range?(get_fn.(&1), from, to))
      end
    end
  end

  defp date_in_range?(%Date{} = d, from, to) do
    (is_nil(from) or Date.compare(d, from) != :lt) and
      (is_nil(to) or Date.compare(d, to) != :gt)
  end

  defp date_in_range?(_value, _from, _to), do: false

  # ---------------------------------------------------------------------------
  # Enum option helper (used by Stock's `columns/0` — the only resource whose
  # `filter_options` derives from the current entries rather than a fixed list)
  # ---------------------------------------------------------------------------

  def distinct_options(entries, key) do
    entries
    |> Enum.map(&(Map.get(&1, key) || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, &1})
  end

  # ---------------------------------------------------------------------------
  # Coercion helpers
  # ---------------------------------------------------------------------------

  def datetime_to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  def datetime_to_unix(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  def datetime_to_unix(_), do: 0

  def date_of(%DateTime{} = dt), do: DateTime.to_date(dt)
  def date_of(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)
  def date_of(%Date{} = d), do: d
  def date_of(_), do: nil

  def to_number(%Decimal{} = d), do: Decimal.to_float(d)
  def to_number(n) when is_number(n), do: n / 1
  def to_number(_), do: 0.0

  def decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  def decimal_to_float(n) when is_number(n), do: n / 1
  def decimal_to_float(_), do: 0.0

  defp parse_number(nil), do: nil
  defp parse_number(""), do: nil
  defp parse_number(n) when is_number(n), do: n / 1

  defp parse_number(s) when is_binary(s) do
    case Float.parse(String.replace(s, ",", ".")) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_number(_), do: nil

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(%Date{} = d), do: d

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_date(_), do: nil
end
