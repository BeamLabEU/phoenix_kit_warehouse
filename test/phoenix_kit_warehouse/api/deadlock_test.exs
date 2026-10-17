defmodule PhoenixKitWarehouse.API.DeadlockTest do
  @moduledoc """
  A posting that Postgres aborts to break a lock cycle with another document is
  answered as a retryable error that says nothing was posted, not as a bare
  failure.

  The cycle is real: another connection holds the stock row of the second item
  of the issue, the issue (which locks its rows in item order) takes the first
  and waits for the second, then that connection asks for the first. The issue
  has been waiting longer, so its deadlock check fires first and it is the one
  aborted. Each side runs on its own real connection (`Sandbox.unboxed_run/2`),
  so the rows are committed and removed again in `on_exit`.
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
  alias PhoenixKitWarehouse.Test.Repo

  @moduletag :integration

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    ref = "DEADLOCK-#{System.unique_integer([:positive])}"

    world =
      unboxed(fn ->
        previous =
          {StockLedger.warehouse_location_type_uuid(), StockLedger.default_location_uuid()}

        %{type: type, locations: [location]} = ApiFixtures.warehouses!(1)
        catalogue = ApiFixtures.catalogue!()

        # The issue locks its rows in item uuid order: `first` is the lower one.
        [first, second] =
          Enum.sort_by([ApiFixtures.item!(catalogue), ApiFixtures.item!(catalogue)], & &1.uuid)

        for item <- [first, second], do: ApiFixtures.seed!(item.uuid, "10", location.uuid)

        %{
          previous: previous,
          type: type,
          location: location,
          catalogue: catalogue,
          first: first,
          second: second
        }
      end)

    on_exit(fn ->
      unboxed(fn ->
        ids = Repo.all(from(i in GoodsIssue, where: i.external_ref == ^ref, select: i.uuid))
        Repo.delete_all(from(e in Entry, where: e.resource_uuid in ^ids))
        Repo.delete_all(from(i in GoodsIssue, where: i.uuid in ^ids))
        items = [world.first.uuid, world.second.uuid]
        Repo.delete_all(from(s in Stock, where: s.item_uuid in ^items))
        Catalogue.permanently_delete_item(world.first)
        Catalogue.permanently_delete_item(world.second)
        Catalogue.permanently_delete_catalogue(world.catalogue)

        {type_uuid, location_uuid} = world.previous
        StockLedger.set_warehouse_location_type_uuid(type_uuid)
        StockLedger.set_default_location_uuid(location_uuid)
        Locations.delete_location(world.location)
        Locations.delete_location_type(world.type)
      end)
    end)

    Map.put(world, :ref, ref)
  end

  defp lock_row(item, location) do
    Repo.all(
      from(s in Stock,
        where: s.item_uuid == ^item.uuid and s.location_uuid == ^location.uuid,
        lock: "FOR UPDATE"
      )
    )
  end

  # Whether some backend waits for a lock held by the backend `holder_pid`
  # (not any waiter of the cluster: other suites share the server); polled
  # with a bounded number of messages to ourselves instead of a sleep.
  defp wait_for_a_waiter(_holder_pid, 0), do: flunk("the issue never waited for a lock")

  defp wait_for_a_waiter(holder_pid, tries) do
    %{rows: [[waiting]]} =
      unboxed(fn ->
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
          [holder_pid]
        )
      end)

    if waiting > 0 do
      :ok
    else
      Process.send_after(self(), :poll, 20)

      receive do
        :poll -> wait_for_a_waiter(holder_pid, tries - 1)
      end
    end
  end

  test "a deadlock is answered as a retryable error with posted false, and the call can be sent again",
       %{ref: ref, first: first, second: second, location: location, catalogue: catalogue} do
    ctx = ApiFixtures.ctx(%{uuid: nil})
    parent = self()

    input = %{
      "external_ref" => ref,
      "reason" => "sale",
      "catalogue_id" => catalogue.uuid,
      "lines" => [
        %{"ref" => %{"id" => first.uuid}, "quantity" => "1"},
        %{"ref" => %{"id" => second.uuid}, "quantity" => "1"}
      ]
    }

    # The other document: holds the second row, then asks for the first.
    other =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            lock_row(second, location)
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:holding, pid})

            receive do
              :ask_for_the_first -> lock_row(first, location)
            after
              10_000 -> :never_asked
            end
          end)
        end)
      end)

    assert_receive {:holding, holder_pid}, 10_000

    issue = Task.async(fn -> unboxed(fn -> Write.issue_stock(input, ctx) end) end)

    wait_for_a_waiter(holder_pid, 250)
    send(other.pid, :ask_for_the_first)

    assert {:error, :internal_error, message, %{posted: false, retry_after: 1}} =
             Task.await(issue, 30_000)

    assert message =~ "send the same call again"
    assert {:ok, _rows} = Task.await(other, 30_000)

    # Rolled back: no document, no stock moved.
    assert unboxed(fn ->
             Repo.aggregate(from(i in GoodsIssue, where: i.external_ref == ^ref), :count)
           end) == 0

    assert Decimal.equal?(
             unboxed(fn -> StockLedger.get_quantity(first.uuid, location.uuid) end),
             Decimal.new(10)
           )

    assert Decimal.equal?(
             unboxed(fn -> StockLedger.get_quantity(second.uuid, location.uuid) end),
             Decimal.new(10)
           )

    # The same call, sent again, posts.
    assert {:ok, %{"status" => "posted"}} = unboxed(fn -> Write.issue_stock(input, ctx) end)

    assert Decimal.equal?(
             unboxed(fn -> StockLedger.get_quantity(first.uuid, location.uuid) end),
             Decimal.new(9)
           )
  end
end
