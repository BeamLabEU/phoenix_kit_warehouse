defmodule PhoenixKitWarehouse.MinStockSettings do
  @moduledoc """
  Context for the per-item minimum stock threshold (§5, deficit tracking).

  Backed by `phoenix_kit_warehouse_min_stock` (introduced in core PhoenixKit
  migration V144), a small side table with at most one row per `item_uuid`
  (enforced by a unique index). Items without a row — or whose row has
  `min_quantity == 0` — are treated as having no configured minimum:
  `min_stock_map/0` only returns rows where
  `min_quantity > 0`, since a zero threshold isn't meaningfully different
  from "not configured" for deficit purposes (see the upcoming
  `PhoenixKitWarehouse.Deficits`).
  """

  import Ecto.Query

  alias PhoenixKitWarehouse.MinStock
  alias PhoenixKitWarehouse.StockLedger

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Returns the configured minimum quantity for `item_uuid` as a Decimal.
  Returns `Decimal.new("0")` if no row exists (no minimum configured).
  """
  def get_min_quantity(item_uuid) do
    case repo().get_by(MinStock, item_uuid: item_uuid) do
      nil -> Decimal.new("0")
      row -> row.min_quantity
    end
  end

  @doc """
  Sets (upserts) the minimum quantity for `item_uuid`. `qty` is coerced via
  `StockLedger.to_decimal/1` (accepts a Decimal, a number, or a comma/dot
  decimal string).

  Returns `{:ok, %MinStock{}}` on success, `{:error, changeset}` if the
  coerced quantity fails validation (e.g. negative).
  """
  def set_min_quantity(item_uuid, qty) do
    attrs = %{item_uuid: item_uuid, min_quantity: StockLedger.to_decimal(qty)}

    %MinStock{}
    |> MinStock.changeset(attrs)
    |> repo().insert(
      conflict_target: [:item_uuid],
      on_conflict: {:replace, [:min_quantity, :updated_at]},
      returning: true
    )
  end

  @doc """
  Returns `%{item_uuid => Decimal}` for every item with a configured minimum
  greater than zero. Items with no row, or a row whose `min_quantity` is
  exactly `0`, are omitted — see the moduledoc.
  """
  def min_stock_map do
    MinStock
    |> where([m], m.min_quantity > 0)
    |> repo().all()
    |> Map.new(&{&1.item_uuid, &1.min_quantity})
  end

  @doc """
  Deletes the minimum stock row for `item_uuid`, if any. Idempotent — a
  no-op (not an error) when no row exists.
  """
  def delete_min_quantity(item_uuid) do
    MinStock
    |> where([m], m.item_uuid == ^item_uuid)
    |> repo().delete_all()

    :ok
  end
end
