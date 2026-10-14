defmodule PhoenixKitWarehouse.API.Stock do
  @moduledoc """
  The two read tools of the warehouse API: `warehouse.list_locations` and
  `warehouse.get_stock`. Handlers are called as `f.(input, ctx)` by the
  API executor of core.
  """

  alias PhoenixKitWarehouse.API.Warehouses

  @doc "`warehouse.list_locations`: the warehouse locations and how far setup has got."
  @spec list_locations(map(), map()) :: {:ok, map()}
  def list_locations(_input, _ctx) do
    %{locations: locations, default_location_id: default, setup: setup} = Warehouses.list()

    {:ok, %{"locations" => locations, "default_location_id" => default, "setup" => setup}}
  end
end
