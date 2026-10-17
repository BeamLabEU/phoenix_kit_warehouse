defmodule PhoenixKitWarehouse.API.RetryRaceTest do
  @moduledoc """
  An issue for a shop order carries its order link in the posting itself. A
  retry fired right behind the first call (same `external_ref`, same order),
  at any moment of it, ends as one posting and one `skipped`: no second
  document, no effect on either answer, the link on the document and the stock
  moved once.

  Each call runs on its own real connection (`Sandbox.unboxed_run/2`): the
  rows are committed and removed again in `on_exit`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Activity.Entry
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Test.ApiFixtures
  alias PhoenixKitWarehouse.Test.ApiOrders, as: Orders
  alias PhoenixKitWarehouse.Test.Repo

  @moduletag :integration

  # Milliseconds between the first call and its retry: spread over the few
  # milliseconds in which the first call reads, checks and posts.
  @delays [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32]

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # The calls run on separate unboxed connections, outside the test's sandbox
  # transaction, so the fixtures and the documents are really committed. The
  # `on_exit` below removes everything this test created.
  setup do
    order = Ecto.UUID.generate()
    refs = Enum.map(@delays, &"RACE-#{System.unique_integer([:positive])}-#{&1}")

    world =
      unboxed(fn ->
        previous =
          {StockLedger.warehouse_location_type_uuid(), StockLedger.default_location_uuid()}

        %{type: type, locations: [location]} = ApiFixtures.warehouses!(1)
        catalogue = ApiFixtures.catalogue!()
        item = ApiFixtures.item!(catalogue)
        ApiFixtures.seed!(item.uuid, "1000", location.uuid)
        %{previous: previous, type: type, location: location, catalogue: catalogue, item: item}
      end)

    Orders.put(order, "Order #RACE")
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [Orders.kind()])

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_warehouse, :source_kinds)

      unboxed(fn ->
        ids = Repo.all(from(g in GoodsIssue, where: g.external_ref in ^refs, select: g.uuid))
        Repo.delete_all(from(e in Entry, where: e.resource_uuid in ^ids))
        Repo.delete_all(from(g in GoodsIssue, where: g.uuid in ^ids))
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

    Map.merge(world, %{order: order, refs: refs})
  end

  defp issue_input(world, ref) do
    %{
      "external_ref" => ref,
      "reason" => "sale",
      "catalogue_id" => world.catalogue.uuid,
      "source" => %{"kind" => "shop_order", "id" => world.order},
      "lines" => [%{"ref" => %{"id" => world.item.uuid}, "quantity" => "1"}]
    }
  end

  defp call(input) do
    unboxed(fn ->
      ctx = %{actor: %{user_uuid: nil}, request_id: "race", dry_run?: false}
      Write.issue_stock(input, ctx)
    end)
  end

  defp status({:ok, %{"status" => status}}), do: status
  defp status({:ok, %{"status" => status}, _effects}), do: status

  defp effect_codes({:ok, _body}), do: []
  defp effect_codes({:ok, _body, effects}), do: Enum.map(effects, & &1["code"])

  test "a retry fired right behind the first call is skipped, whichever moment it lands on",
       %{refs: refs, order: order} = world do
    rounds =
      for {ref, delay} <- Enum.zip(refs, @delays) do
        input = issue_input(world, ref)
        first = Task.async(fn -> call(input) end)
        Process.sleep(delay)
        retry = Task.async(fn -> call(input) end)
        {ref, Task.await(first, 30_000), Task.await(retry, 30_000)}
      end

    # At a delay of 0 either call may win; one posts, the other is skipped.
    for {ref, first, retry} <- rounds do
      assert Enum.sort([status(first), status(retry)]) == ["posted", "skipped"], ref
      assert effect_codes(first) ++ effect_codes(retry) == [], ref
    end

    documents =
      unboxed(fn ->
        Repo.all(from(g in GoodsIssue, where: g.external_ref in ^refs, select: g))
      end)

    assert length(documents) == length(refs)
    assert Enum.all?(documents, &(&1.status == "posted"))

    # The first call linked its order in every round.
    assert Enum.all?(documents, fn doc ->
             Enum.any?(doc.source_refs, &(&1["type"] == "shop_order" and &1["uuid"] == order))
           end)

    # Only the first call of each round took stock.
    assert Decimal.equal?(
             unboxed(fn -> StockLedger.get_quantity(world.item.uuid, world.location.uuid) end),
             Decimal.new(1000 - length(refs))
           )
  end
end
