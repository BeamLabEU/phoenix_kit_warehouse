defmodule PhoenixKitWarehouse.API.Stock do
  @moduledoc """
  The two read tools of the warehouse API: `warehouse.list_locations` and
  `warehouse.get_stock`. Handlers are called as `f.(input, ctx)` by the
  API executor of core.
  """

  alias PhoenixKitWarehouse.API.Quantity
  alias PhoenixKitWarehouse.API.Refs
  alias PhoenixKitWarehouse.API.Warehouses
  alias PhoenixKitWarehouse.StockLedger

  @doc "`warehouse.list_locations`: the warehouse locations and how far setup has got."
  @spec list_locations(map(), map()) :: {:ok, map()}
  def list_locations(_input, _ctx) do
    %{locations: locations, default_location_id: default, setup: setup} = Warehouses.list()

    {:ok, %{"locations" => locations, "default_location_id" => default, "setup" => setup}}
  end

  @doc """
  `warehouse.get_stock`: per product, the quantity and unit value at every
  location that holds a row (or at the one `location_id`), and the total.
  A ref that does not resolve gives a row with an `"error"`; the other rows
  are still answered.
  """
  @spec get_stock(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def get_stock(input, _ctx) do
    with {:ok, refs} <- refs_list(input["refs"]),
         {:ok, catalogue_uuid} <- Refs.catalogue_scope(input["catalogue_id"], :read),
         {:ok, location_uuid} <- optional_location(input["location_id"]) do
      resolved = Refs.resolve(refs, catalogue_uuid: catalogue_uuid)
      rows = stock_rows(resolved, location_uuid)
      names = location_names()

      results =
        refs
        |> Enum.zip(resolved)
        |> Enum.map(&result(&1, rows, names, location_uuid))

      {:ok, %{"results" => results}}
    else
      {:error, error} -> fail("The request was refused.", [error])
    end
  end

  defp refs_list(refs) when is_list(refs), do: {:ok, refs}

  defp refs_list(_other) do
    {:error, %{path: "refs", code: "validation_failed", message: "refs must be a list."}}
  end

  defp optional_location(nil), do: {:ok, nil}
  defp optional_location(id), do: Warehouses.resolve(id, :read)

  defp stock_rows(resolved, location_uuid) do
    item_uuids = for {:ok, item} <- resolved, uniq: true, do: item.uuid

    rows = if item_uuids == [], do: [], else: StockLedger.stock_for_items(item_uuids)

    rows =
      if location_uuid, do: Enum.filter(rows, &(&1.location_uuid == location_uuid)), else: rows

    Enum.group_by(rows, & &1.item_uuid)
  end

  defp location_names do
    (StockLedger.list_warehouses() || []) |> Map.new(&{&1.uuid, &1.name})
  end

  defp result({ref, {:ok, item}}, rows, names, location_uuid) do
    item_rows =
      case {Map.get(rows, item.uuid, []), location_uuid} do
        {[], nil} -> []
        {[], location} -> [%{location_uuid: location, quantity: Decimal.new(0), unit_value: nil}]
        {found, _location} -> found
      end

    total = Enum.reduce(item_rows, Decimal.new(0), &Decimal.add(&2, &1.quantity))

    %{
      "ref" => ref,
      "id" => item.uuid,
      "sku" => item.sku,
      "name" => item.name,
      "unit" => item.unit,
      "locations" =>
        item_rows
        |> Enum.map(&location_entry(&1, names))
        |> Enum.sort_by(&{&1["name"] || "", &1["location_id"]}),
      "total" => Quantity.format(total)
    }
  end

  defp result({ref, {:error, error}}, _rows, _names, _location_uuid) do
    %{"ref" => ref, "error" => Refs.error_json(error)}
  end

  defp location_entry(row, names) do
    %{
      "location_id" => row.location_uuid,
      "name" => Map.get(names, row.location_uuid),
      "quantity" => Quantity.format(row.quantity),
      "unit_value" => Quantity.format_optional(row.unit_value)
    }
  end

  # The one place a read handler builds a refusal.
  defp fail(message, errors),
    do: {:error, :validation_failed, message, %{errors: errors}}
end
