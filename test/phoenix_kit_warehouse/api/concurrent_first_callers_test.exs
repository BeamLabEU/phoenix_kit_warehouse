defmodule PhoenixKitWarehouse.API.ConcurrentFirstCallersTest do
  @moduledoc """
  Two first calls with one `external_ref` that both miss the early lookup (neither
  has committed yet) must end as one posting and one `skipped`, and as one
  document: the lookup inside the posting transaction, under the advisory lock
  of the reference, is what makes the loser answer from the winner's document.

  Each call runs on its own real connection (`Sandbox.unboxed_run/2`), started
  together, so the rows are committed and removed again in `on_exit`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Activity.Entry
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Test.ApiFixtures
  alias PhoenixKitWarehouse.Test.Repo

  @moduletag :integration

  @rounds 12

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    refs = for n <- 1..@rounds, do: "FIRST-#{System.unique_integer([:positive])}-#{n}"

    world =
      unboxed(fn ->
        previous =
          {StockLedger.warehouse_location_type_uuid(), StockLedger.default_location_uuid()}

        %{type: type, locations: [location]} = ApiFixtures.warehouses!(1)
        catalogue = ApiFixtures.catalogue!()
        item = ApiFixtures.item!(catalogue)

        %{
          previous: previous,
          type: type,
          location: location,
          catalogue: catalogue,
          item: item
        }
      end)

    on_exit(fn ->
      unboxed(fn ->
        ids = Repo.all(from(r in GoodsReceipt, where: r.external_ref in ^refs, select: r.uuid))
        Repo.delete_all(from(e in Entry, where: e.resource_uuid in ^ids))
        Repo.delete_all(from(r in GoodsReceipt, where: r.uuid in ^ids))
        Repo.delete_all(from(s in Stock, where: s.item_uuid == ^world.item.uuid))
        Catalogue.permanently_delete_item(world.item)
        Catalogue.permanently_delete_catalogue(world.catalogue)

        {type_uuid, location_uuid} = world.previous
        StockLedger.set_warehouse_location_type_uuid(type_uuid)
        StockLedger.set_default_location_uuid(location_uuid)
        Locations.delete_location(world.location)
        Locations.delete_location_type(world.type)
      end)
    end)

    Map.put(world, :refs, refs)
  end

  # Both calls hold a connection and wait for each other before they start, so
  # that neither can finish before the other has begun.
  defp together(input, ctx) do
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          unboxed(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Write.receive_stock(input, ctx)
            after
              10_000 -> :never_started
            end
          end)
        end)
      end

    pids =
      for _ <- 1..2,
          do:
            (receive do
               {:ready, pid} -> pid
             after
               10_000 -> flunk("no start")
             end)

    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end

  defp status({:ok, %{"status" => status}}), do: status
  defp status({:ok, %{"status" => status}, _effects}), do: status
  defp status(other), do: other

  test "two first callers on one reference end as one posting, one skip and one document",
       %{refs: refs, item: item, catalogue: catalogue, location: location} do
    ctx = ApiFixtures.ctx(%{uuid: nil})

    for ref <- refs do
      input = %{
        "external_ref" => ref,
        "catalogue_id" => catalogue.uuid,
        "lines" => [%{"ref" => %{"id" => item.uuid}, "quantity" => "2"}]
      }

      answers = together(input, ctx)

      assert answers |> Enum.map(&status/1) |> Enum.sort() == ["posted", "skipped"], ref
    end

    documents =
      unboxed(fn -> Repo.all(from(r in GoodsReceipt, where: r.external_ref in ^refs)) end)

    assert documents |> Enum.map(& &1.external_ref) |> Enum.sort() == Enum.sort(refs)
    assert Enum.all?(documents, &(&1.status == "posted"))

    # Only the posting call took stock: two units a round.
    assert Decimal.equal?(
             unboxed(fn -> StockLedger.get_quantity(item.uuid, location.uuid) end),
             Decimal.new(2 * length(refs))
           )
  end
end
