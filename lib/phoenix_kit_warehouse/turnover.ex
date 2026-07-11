defmodule PhoenixKitWarehouse.Turnover do
  @moduledoc """
  Context for the warehouse turnover report (§8, no export — see
  `Web.TurnoverReportLive`).

  `compute/3` derives per-item inflow/outflow totals for a date window by
  reading the `lines` of already-posted documents — `GoodsReceipt`,
  `GoodsIssue`, `Transfer`, and `InventoryDocument` — there is no separate
  ledger/journal table in the module to query instead.

  Only items with nonzero `inflow` or `outflow` in the window are returned:
  the base item set is the union of items appearing in a posted movement,
  not every item with a `Stock` row — an item sitting untouched in the
  warehouse for the whole period isn't part of a *movement* report. `balance`
  is then looked up per item on top of that set, not the other way around.

  ## Wave-1 limitations

    - `balance` is the item's **current** on-hand quantity (from
      `StockLedger.stock_map/0` or `stock_map_for_location/1`), NOT a
      historical balance as of `date_to`. Reconstructing a point-in-time
      balance would require a ledger/journal of every stock-affecting event
      in order, which the module doesn't have — this is an accepted wave-1
      limitation, not a bug. Re-surface it in the UI (see
      `Web.TurnoverReportLive`), don't just document it here.
    - `balance` doesn't see stock "in transit" on an unfinished
      (`in_transit`) `Transfer` — same limitation as
      `Deficits.available_by_item/0`.
    - A `Transfer` that shipped (counted as outflow via `shipped_at`) and
      was LATER cancelled from `in_transit` — crediting the quantity back to
      the source, see `Transfers.cancel_transfer/2` — still counts as an
      outflow here if `shipped_at` falls in the window: the cancellation's
      reversal credit isn't a receipt, a transfer receive, or an inventory
      count, so it isn't one of the fields this report reads. Not
      compensated for in wave 1.
    - `posted_at` / `shipped_at` / `received_at` are not indexed on the
      underlying tables, so `compute/3`'s date-range scan gets slower as
      document volume grows. A known tech-debt item (to be recorded in
      `dev_docs/DEVELOPMENT_PLAN.md` — see T22), not fixed here.
  """

  import Ecto.Query

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Transfer

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Computes per-item turnover for the closed window `[date_from, date_to]`
  (both `Date`, inclusive), optionally scoped to a single warehouse via
  `location_uuid` (`nil` sums every warehouse).

  Returns a list of `%{item_uuid:, name:, sku:, unit:, inflow:, outflow:,
  balance:}`, `inflow`/`outflow`/`balance` all `Decimal`, one entry per item
  that had a posted movement in the window (see moduledoc for exactly what
  counts, and for the `balance` limitations).
  """
  def compute(location_uuid, %Date{} = date_from, %Date{} = date_to) do
    from_dt = start_of_day(date_from)
    to_dt = end_of_day(date_to)

    {inventory_in, inventory_out} = inventory_deltas_by_item(location_uuid, from_dt, to_dt)

    inflow =
      location_uuid
      |> receipts_by_item(from_dt, to_dt)
      |> merge_add(transfers_in_by_item(location_uuid, from_dt, to_dt))
      |> merge_add(inventory_in)

    outflow =
      location_uuid
      |> issues_by_item(from_dt, to_dt)
      |> merge_add(transfers_out_by_item(location_uuid, from_dt, to_dt))
      |> merge_add(inventory_out)

    balance = balance_map(location_uuid)

    item_uuids = inflow |> Map.keys() |> Kernel.++(Map.keys(outflow)) |> Enum.uniq()

    build_rows(item_uuids, inflow, outflow, balance)
  end

  # ---------------------------------------------------------------------------
  # Per-source item -> Decimal maps
  # ---------------------------------------------------------------------------

  defp receipts_by_item(location_uuid, from_dt, to_dt) do
    GoodsReceipt
    |> where([r], is_nil(r.deleted_at) and r.status == "posted")
    |> where([r], r.posted_at >= ^from_dt and r.posted_at <= ^to_dt)
    |> filter_location(location_uuid, :location_uuid)
    |> repo().all()
    |> sum_lines_by_item("received_quantity")
  end

  defp issues_by_item(location_uuid, from_dt, to_dt) do
    GoodsIssue
    |> where([i], is_nil(i.deleted_at) and i.status == "posted")
    |> where([i], i.posted_at >= ^from_dt and i.posted_at <= ^to_dt)
    |> filter_location(location_uuid, :location_uuid)
    |> repo().all()
    |> sum_lines_by_item("issued_quantity")
  end

  defp transfers_in_by_item(location_uuid, from_dt, to_dt) do
    Transfer
    |> where([t], is_nil(t.deleted_at))
    |> where([t], t.received_at >= ^from_dt and t.received_at <= ^to_dt)
    |> filter_location(location_uuid, :destination_location_uuid)
    |> repo().all()
    |> sum_lines_by_item("transfer_quantity")
  end

  defp transfers_out_by_item(location_uuid, from_dt, to_dt) do
    Transfer
    |> where([t], is_nil(t.deleted_at))
    |> where([t], t.shipped_at >= ^from_dt and t.shipped_at <= ^to_dt)
    |> filter_location(location_uuid, :source_location_uuid)
    |> repo().all()
    |> sum_lines_by_item("transfer_quantity")
  end

  # Returns `{inflow_map, outflow_map}` from the same pass over each posted
  # InventoryDocument's lines: `counted_quantity - previous_quantity` (both
  # always present once posted — see `Inventories.build_posting_multi/2`)
  # feeds inflow when positive, outflow (as `abs/1`) when negative, and is
  # skipped entirely when exactly zero.
  defp inventory_deltas_by_item(location_uuid, from_dt, to_dt) do
    InventoryDocument
    |> where([d], is_nil(d.deleted_at) and d.status == "posted")
    |> where([d], d.posted_at >= ^from_dt and d.posted_at <= ^to_dt)
    |> filter_location(location_uuid, :location_uuid)
    |> repo().all()
    |> Enum.reduce({%{}, %{}}, fn doc, acc ->
      Enum.reduce(doc.lines || [], acc, &add_delta_line/2)
    end)
  end

  defp add_delta_line(line, {inflow_acc, outflow_acc} = acc) do
    case line["item_uuid"] do
      nil ->
        acc

      item_uuid ->
        delta =
          Decimal.sub(
            StockLedger.to_decimal(line["counted_quantity"]),
            StockLedger.to_decimal(line["previous_quantity"])
          )

        cond do
          Decimal.gt?(delta, Decimal.new("0")) ->
            {Map.update(inflow_acc, item_uuid, delta, &Decimal.add(&1, delta)), outflow_acc}

          Decimal.lt?(delta, Decimal.new("0")) ->
            abs_delta = Decimal.abs(delta)

            {inflow_acc,
             Map.update(outflow_acc, item_uuid, abs_delta, &Decimal.add(&1, abs_delta))}

          true ->
            acc
        end
    end
  end

  # Sums `line[field]` (coerced via `StockLedger.to_decimal/1`) across every
  # line of every doc, keyed by `item_uuid`. Lines with a missing item_uuid
  # or a zero (or negative — shouldn't happen post-audit, but defensive)
  # quantity contribute nothing. Posted documents are already deduplicated
  # by item_uuid on their own `lines` at posting time (see e.g.
  # `GoodsReceipts.apply_stock_and_post/3`), so no re-dedup is needed here —
  # and even if it weren't, summing duplicates is the *correct* behavior for
  # a total-movement report.
  defp sum_lines_by_item(docs, field) do
    Enum.reduce(docs, %{}, fn doc, acc ->
      Enum.reduce(doc.lines || [], acc, fn line, acc2 ->
        add_line_quantity(acc2, line["item_uuid"], StockLedger.to_decimal(line[field]))
      end)
    end)
  end

  defp add_line_quantity(acc, nil, _qty), do: acc

  defp add_line_quantity(acc, item_uuid, qty) do
    if Decimal.gt?(qty, Decimal.new("0")) do
      Map.update(acc, item_uuid, qty, &Decimal.add(&1, qty))
    else
      acc
    end
  end

  defp merge_add(map1, map2) do
    Map.merge(map1, map2, fn _item_uuid, a, b -> Decimal.add(a, b) end)
  end

  # ---------------------------------------------------------------------------
  # Balance (current on-hand — see moduledoc limitations)
  # ---------------------------------------------------------------------------

  defp balance_map(nil) do
    Map.new(StockLedger.stock_map(), fn {item_uuid, entry} -> {item_uuid, entry.quantity} end)
  end

  defp balance_map(location_uuid) do
    Map.new(StockLedger.stock_map_for_location(location_uuid), fn {item_uuid, entry} ->
      {item_uuid, entry.quantity}
    end)
  end

  # ---------------------------------------------------------------------------
  # Row assembly — enrich with catalogue name/sku/unit, as in stock_live.ex
  # ---------------------------------------------------------------------------

  # Iterates the *items* `Catalogue.list_items_by_uuids/1` resolves (not the
  # raw uuid list) — an item_uuid whose catalogue card was hard-deleted since
  # the movement was posted is silently dropped, matching `StockLive`'s own
  # enrichment (`build_stock_items/1`).
  defp build_rows(item_uuids, inflow, outflow, balance_map) do
    item_uuids
    |> Catalogue.list_items_by_uuids()
    |> Enum.map(fn item ->
      %{
        item_uuid: item.uuid,
        name: item.name,
        sku: item.sku,
        unit: item.unit,
        inflow: Map.get(inflow, item.uuid, Decimal.new("0")),
        outflow: Map.get(outflow, item.uuid, Decimal.new("0")),
        balance: Map.get(balance_map, item.uuid, Decimal.new("0"))
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.name || ""))
  end

  # ---------------------------------------------------------------------------
  # Query / date helpers
  # ---------------------------------------------------------------------------

  defp filter_location(query, nil, _field), do: query

  defp filter_location(query, location_uuid, field) do
    where(query, [q], field(q, ^field) == ^location_uuid)
  end

  defp start_of_day(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp end_of_day(%Date{} = date), do: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
end
