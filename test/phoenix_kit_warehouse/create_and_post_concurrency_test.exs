defmodule PhoenixKitWarehouse.CreateAndPostConcurrencyTest do
  @moduledoc """
  Concurrency behaviour of the posting functions, which a single sandboxed
  connection cannot show: every process here runs on its own real connection
  (`Sandbox.unboxed_run/2`), so the rows are committed and are removed again
  in `on_exit`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Test.Repo

  @moduletag :integration

  @location "00000000-0000-0000-0000-0000000000c1"

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp seed!(item, quantity) do
    unboxed(fn ->
      {:ok, _} =
        StockLedger.upsert_quantity(item, Decimal.new(quantity), location_uuid: @location)
    end)
  end

  defp cleanup_on_exit(items, external_refs, inventory_uuids \\ []) do
    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(s in Stock, where: s.item_uuid in ^items))
        Repo.delete_all(from(g in GoodsIssue, where: g.external_ref in ^external_refs))
        Repo.delete_all(from(d in InventoryDocument, where: d.uuid in ^inventory_uuids))
      end)
    end)
  end

  describe "GoodsIssues.create_and_post/2 with a shared external_ref" do
    test "concurrent identical calls create exactly one document, the rest answer :already_posted" do
      for _round <- 1..3 do
        item = Ecto.UUID.generate()
        ref = "CONC-#{System.unique_integer([:positive])}"
        seed!(item, "100")
        cleanup_on_exit([item], [ref])

        attrs = %{
          location_uuid: @location,
          external_ref: ref,
          lines: [%{"item_uuid" => item, "issued_quantity" => "1"}]
        }

        results =
          1..6
          |> Task.async_stream(
            fn _ -> unboxed(fn -> GoodsIssues.create_and_post(attrs, nil) end) end,
            max_concurrency: 6,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert [{:ok, %GoodsIssue{status: "posted"}}] =
                 Enum.filter(results, &match?({:ok, %GoodsIssue{}}, &1))

        assert Enum.count(results, &match?({:ok, :already_posted, %GoodsIssue{}}, &1)) == 5
        assert length(results) == 6

        assert unboxed(fn ->
                 Repo.aggregate(from(g in GoodsIssue, where: g.external_ref == ^ref), :count)
               end) == 1

        # Only the winner took stock.
        assert Decimal.equal?(
                 unboxed(fn -> StockLedger.get_quantity(item, @location) end),
                 Decimal.new("99")
               )
      end
    end
  end

  describe "Inventories.post_document/2 under a concurrent stock change" do
    test "the recorded previous quantity includes a change committed while the post waited" do
      item = Ecto.UUID.generate()
      seed!(item, "10")

      {:ok, doc} =
        unboxed(fn ->
          Inventories.create_draft(%{
            location_uuid: @location,
            lines: [%{"item_uuid" => item, "counted_quantity" => Decimal.new("4")}]
          })
        end)

      cleanup_on_exit([item], [], [doc.uuid])
      parent = self()

      # Holds the stock row lock with an uncommitted +5 until told to commit.
      holder =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              from(s in Stock, where: s.item_uuid == ^item and s.location_uuid == ^@location)
              |> Repo.update_all(inc: [quantity: Decimal.new("5")])

              send(parent, :locked)

              receive do
                :commit -> :ok
              after
                15_000 -> Repo.rollback(:holder_timeout)
              end
            end)
          end)
        end)

      assert_receive :locked, 10_000

      poster = Task.async(fn -> unboxed(fn -> Inventories.post_document(doc, nil) end) end)

      wait_until_blocked_on_a_lock()
      send(holder.pid, :commit)

      assert {:ok, {:ok, :ok}} = {:ok, Task.await(holder, 15_000)}
      assert {:ok, posted} = Task.await(poster, 15_000)

      [line] = posted.lines
      assert Decimal.equal?(line["previous_quantity"], Decimal.new("15"))
      assert Decimal.equal?(unboxed(fn -> StockLedger.get_quantity(item, @location) end), 4)
    end
  end

  # The poster is only known to be waiting for the holder once the database
  # says so; polling the lock state avoids guessing a sleep.
  defp wait_until_blocked_on_a_lock(attempts \\ 250)

  defp wait_until_blocked_on_a_lock(0), do: flunk("the post never blocked on the held row lock")

  defp wait_until_blocked_on_a_lock(attempts) do
    %{rows: [[blocked]]} =
      unboxed(fn ->
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity " <>
            "WHERE datname = current_database() AND wait_event_type = 'Lock' " <>
            "AND query ILIKE '%phoenix_kit_warehouse_stock%'"
        )
      end)

    if blocked > 0 do
      :ok
    else
      receive do
      after
        20 -> wait_until_blocked_on_a_lock(attempts - 1)
      end
    end
  end
end
