defmodule PhoenixKitWarehouse.API.EarlyLookupTest do
  @moduledoc """
  The early lookup of a repeated `external_ref` runs outside any transaction,
  so it must not take the posting layer's advisory lock: a request that is
  refused, a dry run and a retry would otherwise wait for a posting in flight
  with the same reference (and fail after the pool timeout). A miss still
  falls through to the locked lookup inside the posting transaction.

  The lock is held by a transaction on its own real connection
  (`Sandbox.unboxed_run/2`), as a posting in flight would hold it.
  """

  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.GoodsReceipt

  @wait 2_000

  setup do
    %{locations: [first, _second]} = warehouses!(2)
    catalogue = shop_catalogue!()
    user = user!()

    %{
      first: first,
      a: item!(catalogue),
      ctx: ctx(user),
      dry: ctx(user, %{dry_run?: true})
    }
  end

  defp line(item, quantity), do: %{"ref" => %{"id" => item.uuid}, "quantity" => quantity}

  # Holds the advisory lock of a receipt reference on another connection until
  # it is sent `:release` (at the latest when the test ends).
  defp hold_lock!(external_ref) do
    parent = self()
    key = "pkw:#{GoodsReceipt.__schema__(:source)}:#{external_ref}"

    # Not linked to the test: it releases the lock and ends on its own.
    {:ok, holder} =
      Task.start(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
            send(parent, :locked)

            receive do
              :release -> :ok
            after
              30_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive :locked, 5_000

    on_exit(fn ->
      ref = Process.monitor(holder)
      send(holder, :release)
      assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 5_000
    end)

    holder
  end

  # The answer of `fun`, or a failure if it is still waiting after `@wait`.
  defp answer_without_waiting(holder, fun) do
    task = Task.async(fun)

    case Task.yield(task, @wait) do
      {:ok, answer} ->
        answer

      nil ->
        send(holder, :release)
        Task.await(task, 30_000)
        flunk("the early lookup waited for the advisory lock of the reference")
    end
  end

  test "a request refused at validation is answered while a posting holds the reference", %{
    ctx: ctx
  } do
    holder = hold_lock!("EL-REFUSED")

    bad = %{
      "external_ref" => "EL-REFUSED",
      "lines" => [line(%{uuid: Ecto.UUID.generate()}, "-1")]
    }

    assert {:error, :validation_failed, _message, %{posted: false}} =
             answer_without_waiting(holder, fn -> Write.receive_stock(bad, ctx) end)
  end

  test "a dry run is answered while a posting holds the reference", %{a: a, dry: dry} do
    holder = hold_lock!("EL-DRY")
    input = %{"external_ref" => "EL-DRY", "lines" => [line(a, "2")]}

    assert {:preview, %{"status" => "would_post"}, _fingerprint} =
             answer_without_waiting(holder, fn -> Write.receive_stock(input, dry) end)
  end

  test "a retry of a posted reference is answered from the document while the lock is held", %{
    first: first,
    a: a,
    ctx: ctx,
    dry: dry
  } do
    input = %{"external_ref" => "EL-RETRY", "lines" => [line(a, "2")]}

    # Inserted directly: posting it through the API would leave its advisory
    # lock held by the test's own sandbox transaction.
    %{uuid: id} =
      Repo.insert!(%GoodsReceipt{
        status: "posted",
        location_uuid: first.uuid,
        external_ref: "EL-RETRY",
        posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        lines: [%{"item_uuid" => a.uuid, "received_quantity" => "2"}]
      })

    holder = hold_lock!("EL-RETRY")

    assert {:ok, %{"status" => "skipped", "document" => %{"id" => ^id}}} =
             answer_without_waiting(holder, fn -> Write.receive_stock(input, ctx) end)

    assert {:preview, %{"status" => "would_skip", "document" => %{"id" => ^id}}, _fingerprint} =
             answer_without_waiting(holder, fn -> Write.receive_stock(input, dry) end)
  end

  test "a miss falls through to the locked lookup inside the posting transaction", %{
    first: first,
    a: a,
    ctx: ctx
  } do
    input = %{"external_ref" => "EL-QUEUE", "lines" => [line(a, "2")]}
    holder = hold_lock!("EL-QUEUE")

    # The early lookup finds nothing (the first call has not committed), so the
    # posting transaction is the one that queues on the lock.
    call = Task.async(fn -> Write.receive_stock(input, ctx) end)
    assert Task.yield(call, 300) == nil

    send(holder, :release)

    assert {:ok, %{"status" => "posted"}} = Task.await(call, 30_000)
    assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(2))
  end
end
