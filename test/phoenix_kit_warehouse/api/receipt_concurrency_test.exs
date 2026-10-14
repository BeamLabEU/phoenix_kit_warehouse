defmodule PhoenixKitWarehouse.API.ReceiptConcurrencyTest do
  @moduledoc """
  Receipts of one item posting at once record
  an exact `{from, to}` each (`to` is the quantity the atomic add returned,
  `from` is `to` minus the received quantity), so together they form one
  unbroken chain from the seeded stock to the final stock. `previous_quantity`,
  read before the add and without a lock, could not promise that.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Test.Repo

  @moduletag :integration

  @location "00000000-0000-0000-0000-0000000000a8"

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  test "six receipts of one item posting at once leave one chain of exact {from, to} pairs" do
    item = Ecto.UUID.generate()
    refs = for n <- 1..6, do: "RCPT-CONC-#{System.unique_integer([:positive])}-#{n}"

    unboxed(fn ->
      {:ok, _} = StockLedger.upsert_quantity(item, Decimal.new("10"), location_uuid: @location)
    end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(s in Stock, where: s.item_uuid == ^item))
        Repo.delete_all(from(r in GoodsReceipt, where: r.external_ref in ^refs))
      end)
    end)

    receipts =
      refs
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {ref, n} ->
          unboxed(fn ->
            attrs = %{
              location_uuid: @location,
              external_ref: ref,
              lines: [%{"item_uuid" => item, "received_quantity" => Integer.to_string(n)}]
            }

            {:ok, receipt} = GoodsReceipts.create_and_post(attrs, nil)
            Repo.get!(GoodsReceipt, receipt.uuid)
          end)
        end,
        max_concurrency: 6,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, receipt} -> receipt end)

    # Every receipt adds a different positive amount, so ordering the pairs by
    # `to` is the order in which the adds committed.
    pairs =
      receipts
      |> Enum.map(fn %{lines: [line]} ->
        to = StockLedger.to_decimal(line["resulting_quantity"])
        {Decimal.sub(to, StockLedger.to_decimal(line["received_quantity"])), to}
      end)
      |> Enum.sort_by(&elem(&1, 1), Decimal)

    tos = Enum.map(pairs, &elem(&1, 1))
    froms = Enum.map(pairs, &elem(&1, 0))

    # The first `from` is the seed, every other `from` is the previous `to`.
    expected_froms = [Decimal.new(10) | Enum.drop(tos, -1)]
    assert Enum.zip(froms, expected_froms) |> Enum.all?(fn {a, b} -> Decimal.equal?(a, b) end)

    # 10 + (1 + 2 + 3 + 4 + 5 + 6), and the table agrees with the last `to`.
    assert Decimal.equal?(List.last(tos), Decimal.new(31))

    assert Decimal.equal?(
             unboxed(fn -> StockLedger.get_quantity(item, @location) end),
             Decimal.new(31)
           )
  end
end
