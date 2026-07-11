defmodule PhoenixKitWarehouse.Deficits do
  @moduledoc """
  Context for computing per-item stock deficits (§5, full variant).

  Combines three existing signals — current on-hand stock
  (`StockLedger.stock_map/0`), how much of that stock is reserved by posted
  internal orders (`reserved_by_item/0`), and the configured per-item
  minimum (`MinStockSettings.min_stock_map/0`) — into "how much is actually
  available" and "which items have fallen below their minimum".

  Wave-1 limitations (see `dev_docs/DEVELOPMENT_PLAN.md`):
    - The minimum stock threshold is global per item, not per
      `{item_uuid, location_uuid}` pair — `available_by_item/0` sums on-hand
      quantity across every warehouse (via `StockLedger.stock_map/0`).
    - Neither `reserved_by_item/0` nor `available_by_item/0` see stock "in
      transit" on an unfinished (`in_transit`) `Transfer` — it has already
      left the source warehouse's `Stock` row but hasn't yet landed on the
      destination's, so it's invisible to both. Not compensated for here —
      the same limitation is noted on `PhoenixKitWarehouse.Turnover` and
      `Web.StockLive`.
  """

  alias PhoenixKitWarehouse.CommittedQuantities
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.MinStockSettings
  alias PhoenixKitWarehouse.StockLedger

  @doc """
  Returns `%{item_uuid => Decimal}` — the quantity currently reserved
  against each item by posted internal orders.

  Only `status == "posted"` internal orders reserve stock
  (`InternalOrders.list_posted_internal_orders/0` already filters for this
  in SQL) — drafts are unconfirmed proposals and reserve nothing, otherwise
  every draft would manufacture a false deficit.

  For each posted order, each line's reservation is
  `max(0, required_quantity - already_issued)`, where `already_issued` is
  how much of *that order's own* `required_quantity` has already shipped out
  via a Goods Issue referencing it (via `CommittedQuantities.compute/4`).
  This is computed **per line, per order**, then summed by `item_uuid`
  across every order — deliberately not as a single global
  `Σrequired - Σissued` per item. The per-order clamp to zero matters:
  without it, fully (or over-) issuing one internal order could drive that
  order's own line negative, which would then wrongly cancel out a
  different internal order's still-open reservation for the same item once
  summed globally.
  """
  def reserved_by_item do
    orders = InternalOrders.list_posted_internal_orders()
    io_uuids = Enum.map(orders, & &1.uuid)

    committed =
      CommittedQuantities.compute(GoodsIssue, ["internal_order"], io_uuids, "issued_quantity")

    Enum.reduce(orders, %{}, fn io, acc ->
      already_issued_for_io = Map.get(committed, io.uuid, %{})

      Enum.reduce(io.lines, acc, fn line, acc2 ->
        item_uuid = line["item_uuid"]
        required = StockLedger.to_decimal(line["required_quantity"])
        already_issued = Map.get(already_issued_for_io, item_uuid, Decimal.new("0"))
        reserved_line = Decimal.max(Decimal.new("0"), Decimal.sub(required, already_issued))

        Map.update(acc2, item_uuid, reserved_line, &Decimal.add(&1, reserved_line))
      end)
    end)
  end

  @doc """
  Returns `%{item_uuid => Decimal}` — on-hand quantity (summed across every
  warehouse via `StockLedger.stock_map/0`) minus `reserved_by_item/0`, for
  the union of items appearing in either source. An item missing from one
  side is treated as `0` there: an item with stock but no open reservation
  is simply its full on-hand quantity; an item reserved but with no `Stock`
  row at all yields a negative available quantity, surfacing the
  over-commitment rather than hiding it.
  """
  def available_by_item do
    stock = StockLedger.stock_map()
    reserved = reserved_by_item()

    stock
    |> Map.keys()
    |> Kernel.++(Map.keys(reserved))
    |> Enum.uniq()
    |> Map.new(fn item_uuid ->
      on_hand =
        stock |> Map.get(item_uuid, %{quantity: Decimal.new("0")}) |> Map.fetch!(:quantity)

      reserved_qty = Map.get(reserved, item_uuid, Decimal.new("0"))

      {item_uuid, Decimal.sub(on_hand, reserved_qty)}
    end)
  end

  @doc """
  Returns a list of `%{item_uuid:, min_quantity:, available:, deficit:}` —
  one entry per item with a configured minimum
  (`MinStockSettings.min_stock_map/0`, which already excludes unset or
  zero minimums) whose `available_by_item/0` quantity has fallen below that
  minimum. Items at or above their minimum are omitted.
  """
  def list_deficits do
    available = available_by_item()

    Enum.reduce(MinStockSettings.min_stock_map(), [], fn {item_uuid, min_quantity}, acc ->
      item_available = Map.get(available, item_uuid, Decimal.new("0"))

      if Decimal.lt?(item_available, min_quantity) do
        [
          %{
            item_uuid: item_uuid,
            min_quantity: min_quantity,
            available: item_available,
            deficit: Decimal.sub(min_quantity, item_available)
          }
          | acc
        ]
      else
        acc
      end
    end)
  end
end
