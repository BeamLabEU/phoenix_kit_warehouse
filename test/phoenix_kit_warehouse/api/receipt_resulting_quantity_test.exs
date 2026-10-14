defmodule PhoenixKitWarehouse.API.ReceiptResultingQuantityTest do
  @moduledoc """
  A posted goods receipt line records the quantity the atomic add returned, so
  an API caller's `{from, to}` is exact even when another document moves the
  same stock at the same moment.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.StockLedger

  @location "00000000-0000-0000-0000-0000000000a6"

  defp dec(value), do: StockLedger.to_decimal(value)

  defp post!(lines) do
    assert {:ok, receipt} =
             GoodsReceipts.create_and_post(%{location_uuid: @location, lines: lines}, nil)

    Repo.get!(GoodsReceipt, receipt.uuid)
  end

  test "an item with stock: previous and resulting quantity are both recorded" do
    item = Ecto.UUID.generate()
    {:ok, _} = StockLedger.upsert_quantity(item, Decimal.new("5"), location_uuid: @location)

    [line] = post!([%{"item_uuid" => item, "received_quantity" => "3"}]).lines

    assert Decimal.equal?(dec(line["previous_quantity"]), Decimal.new("5"))
    assert Decimal.equal?(dec(line["resulting_quantity"]), Decimal.new("8"))
  end

  test "an item with no stock row yet: previous 0, resulting equal to the received quantity" do
    item = Ecto.UUID.generate()

    [line] = post!([%{"item_uuid" => item, "received_quantity" => "2.5"}]).lines

    assert Decimal.equal?(dec(line["previous_quantity"]), Decimal.new("0"))
    assert Decimal.equal?(dec(line["resulting_quantity"]), Decimal.new("2.5"))
  end

  test "a zero-quantity line moves nothing and records no resulting quantity" do
    item = Ecto.UUID.generate()
    {:ok, _} = StockLedger.upsert_quantity(item, Decimal.new("4"), location_uuid: @location)

    [line] = post!([%{"item_uuid" => item, "received_quantity" => "0"}]).lines

    assert Decimal.equal?(dec(line["previous_quantity"]), Decimal.new("4"))
    refute Map.has_key?(line, "resulting_quantity")
  end

  test "lines keep the document's own order and each has its own resulting quantity" do
    [a, b] = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    lines =
      post!([
        %{"item_uuid" => b, "received_quantity" => "1"},
        %{"item_uuid" => a, "received_quantity" => "2"}
      ]).lines

    assert Enum.map(lines, & &1["item_uuid"]) == [b, a]
    assert Enum.map(lines, &StockLedger.format_quantity(&1["resulting_quantity"])) == ["1", "2"]
  end
end
