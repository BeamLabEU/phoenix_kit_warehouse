defmodule PhoenixKitWarehouse.API.WriteLocationTest do
  @moduledoc """
  The write tools refuse a location that is not an active warehouse at
  `location_id` and write nothing: no document, no stock row, no document
  number burnt. A read from such a location still works.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import Ecto.Query
  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKit.Activity.Entry
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.API.Stock, as: StockTools
  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.StockLedger

  setup do
    %{locations: [first, second]} = warehouses!(2)
    catalogue = shop_catalogue!()
    user = user!()
    a = item!(catalogue)

    # Stock at the second warehouse while it is open, so that an issue is
    # refused for the location and not for the stock.
    seed!(a.uuid, "5", second.uuid)
    {:ok, closed} = Locations.update_location(second, %{status: "inactive"})

    %{first: first, closed: closed, a: a, ctx: ctx(user)}
  end

  defp line(item, quantity), do: %{"ref" => %{"id" => item.uuid}, "quantity" => quantity}

  defp footprint do
    %{rows: seqs} =
      Repo.query!("""
      SELECT last_value, is_called FROM phoenix_kit_warehouse_goods_receipts_number_seq
      UNION ALL SELECT last_value, is_called FROM phoenix_kit_warehouse_goods_issues_number_seq
      UNION ALL SELECT last_value, is_called FROM phoenix_kit_warehouse_inventory_documents_number_seq
      """)

    %{
      receipts: Repo.aggregate(GoodsReceipt, :count),
      issues: Repo.aggregate(GoodsIssue, :count),
      inventories: Repo.aggregate(InventoryDocument, :count),
      stock:
        Repo.all(
          from(s in Stock,
            select: {s.item_uuid, s.location_uuid, s.quantity},
            order_by: [s.item_uuid, s.location_uuid]
          )
        ),
      activity: Repo.aggregate(from(e in Entry, where: like(e.action, "warehouse.%")), :count),
      sequences: seqs
    }
  end

  defp requests(location_id, a) do
    [
      receive_stock: %{"location_id" => location_id, "lines" => [line(a, "1")]},
      set_stock: %{"location_id" => location_id, "lines" => [line(a, "1")]},
      issue_stock: %{"location_id" => location_id, "reason" => "sale", "lines" => [line(a, "1")]}
    ]
  end

  defp assert_refused_at_location(requests, ctx, expected) do
    for {tool, input} <- requests do
      before = footprint()

      assert {:error, :validation_failed, _message, %{errors: errors, posted: false}} =
               apply(Write, tool, [input, ctx]),
             "#{tool} did not refuse"

      assert [%{path: "location_id", code: "validation_failed", message: message}] = errors
      assert message =~ expected, "#{tool}: #{message}"
      assert footprint() == before, "#{tool} wrote something"
    end
  end

  test "an inactive warehouse is refused by every write tool, and nothing is written", %{
    closed: closed,
    a: a,
    ctx: ctx
  } do
    closed.uuid |> requests(a) |> assert_refused_at_location(ctx, "inactive")
    assert Decimal.equal?(quantity(a.uuid, closed.uuid), Decimal.new(5))
  end

  test "an inactive warehouse is refused in a preview too", %{closed: closed, a: a, ctx: ctx} do
    dry = Map.put(ctx, :dry_run?, true)
    closed.uuid |> requests(a) |> assert_refused_at_location(dry, "inactive")
  end

  test "an install whose warehouse location type is unset refuses every write tool", %{
    first: first,
    a: a,
    ctx: ctx
  } do
    StockLedger.set_warehouse_location_type_uuid(nil)

    first.uuid |> requests(a) |> assert_refused_at_location(ctx, "location type")
  end

  test "without a location_id the default is checked the same way", %{
    first: first,
    a: a,
    ctx: ctx
  } do
    {:ok, _} = Locations.update_location(first, %{status: "inactive"})

    nil
    |> requests(a)
    |> Enum.map(fn {tool, input} -> {tool, Map.delete(input, "location_id")} end)
    |> assert_refused_at_location(ctx, "inactive")
  end

  test "stock can still be read from an inactive warehouse", %{closed: closed, a: a, ctx: ctx} do
    assert {:ok, %{"results" => [%{"locations" => [%{"location_id" => location} = row]}]}} =
             StockTools.get_stock(
               %{"location_id" => closed.uuid, "refs" => [%{"id" => a.uuid}]},
               ctx
             )

    assert location == closed.uuid
    assert row["quantity"] == "5"
  end
end
