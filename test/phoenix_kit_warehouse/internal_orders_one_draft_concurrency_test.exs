defmodule PhoenixKitWarehouse.InternalOrdersOneDraftConcurrencyTest do
  @moduledoc """
  What the "one draft per source" rule needs two real connections to show.

  Inside the sandbox there is a single connection: a transaction-scoped
  advisory lock is re-entrant for the session that already holds it and a row
  lock never makes the same session wait, so a test there proves nothing about
  serialisation. Every process here runs on its own committed connection
  (`Sandbox.unboxed_run/2`) and the rows are removed again in `on_exit`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Activity.Entry
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Test.Repo

  @moduletag :integration

  @location "00000000-0000-0000-0000-000000000001"

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp new_source do
    source = %{"type" => "sub_order", "uuid" => Ecto.UUID.generate()}

    on_exit(fn ->
      unboxed(fn ->
        uuids =
          Repo.all(
            from(o in InternalOrder,
              where: fragment("? @> ?::jsonb", o.source_refs, ^[source]),
              select: o.uuid
            )
          )

        Repo.delete_all(from(e in Entry, where: e.resource_uuid in ^uuids))
        Repo.delete_all(from(o in InternalOrder, where: o.uuid in ^uuids))
      end)
    end)

    source
  end

  defp advisory_key(%{"type" => type, "uuid" => uuid}),
    do: "phoenix_kit_warehouse:io_source:#{type}:#{uuid}"

  defp lines do
    [
      %{
        "item_uuid" => Ecto.UUID.generate(),
        "name" => "Screw M6",
        "unit" => "pcs",
        "required_quantity" => "10"
      }
    ]
  end

  defp insert!(source, attrs \\ %{}) do
    unboxed(fn ->
      {:ok, order} =
        InternalOrders.create_internal_order(
          Map.merge(%{location_uuid: @location, source_refs: [source], lines: lines()}, attrs)
        )

      order
    end)
  end

  defp replace_task(source, actor \\ Ecto.UUID.generate()) do
    Task.async(fn ->
      unboxed(fn ->
        InternalOrders.replace_draft_for_source(lines(), source,
          created_by_uuid: actor,
          location_uuid: @location
        )
      end)
    end)
  end

  defp fetch(order_or_uuid) do
    uuid = if is_struct(order_or_uuid), do: order_or_uuid.uuid, else: order_or_uuid
    unboxed(fn -> Repo.get!(InternalOrder, uuid) end)
  end

  defp live_for(source) do
    unboxed(fn -> InternalOrders.list_for_source(source["type"], source["uuid"]) end)
  end

  # Runs in its own connection and holds `fun`'s locks until told to commit.
  defp holder(parent, fun) do
    Task.async(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          fun.()
          send(parent, :locked)

          receive do
            :commit -> :ok
          after
            15_000 -> Repo.rollback(:holder_timeout)
          end
        end)
      end)
    end)
  end

  defp hold_advisory(parent, source) do
    holder(parent, fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [advisory_key(source)])
    end)
  end

  # The waiters are known to be waiting only once the database says so;
  # polling pg_locks / pg_stat_activity avoids guessing a sleep.
  defp wait_until(description, sql, expected, attempts \\ 250)

  defp wait_until(description, _sql, _expected, 0), do: flunk("never saw: #{description}")

  defp wait_until(description, sql, expected, attempts) do
    %{rows: [[count]]} = unboxed(fn -> Repo.query!(sql) end)

    if count >= expected do
      :ok
    else
      receive do
      after
        20 -> wait_until(description, sql, expected, attempts - 1)
      end
    end
  end

  defp wait_for_advisory_waiters(expected) do
    wait_until(
      "#{expected} session(s) waiting for an advisory lock",
      "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted " <>
        "AND database = (SELECT oid FROM pg_database WHERE datname = current_database())",
      expected
    )
  end

  defp wait_for_row_lock_waiter do
    wait_until(
      "a session waiting for an internal order row lock",
      "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " <>
        "AND wait_event_type = 'Lock' " <>
        "AND query ILIKE '%phoenix_kit_warehouse_internal_orders%'",
      1
    )
  end

  describe "replace_draft_for_source/3 racing a posting" do
    test "a draft posted while the replacement waits for its row stays posted and is not reported" do
      source = new_source()
      draft = insert!(source)
      parent = self()

      # Posts the draft in another connection and keeps its row locked.
      poster =
        holder(parent, fn ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          {1, _} =
            Repo.update_all(from(o in InternalOrder, where: o.uuid == ^draft.uuid),
              set: [status: "posted", posted_at: now, updated_at: now]
            )
        end)

      assert_receive :locked, 10_000

      replacer = replace_task(source)
      wait_for_row_lock_waiter()
      send(poster.pid, :commit)

      assert {:ok, :ok} = Task.await(poster, 15_000)
      assert {:ok, %{order: new, superseded: []}} = Task.await(replacer, 15_000)

      reloaded = fetch(draft)
      assert reloaded.status == "posted"
      assert reloaded.deleted_at == nil
      assert reloaded.deleted_by_uuid == nil

      assert Enum.sort(Enum.map(live_for(source), & &1.uuid)) ==
               Enum.sort([draft.uuid, new.uuid])
    end

    test "a draft that is still a draft when the replacement gets its row is trashed" do
      source = new_source()
      draft = insert!(source)
      parent = self()

      # Holds the row without changing it, then lets go.
      holder_task =
        holder(parent, fn ->
          Repo.all(from(o in InternalOrder, where: o.uuid == ^draft.uuid, lock: "FOR UPDATE"))
        end)

      assert_receive :locked, 10_000

      replacer = replace_task(source)
      wait_for_row_lock_waiter()
      send(holder_task.pid, :commit)

      assert {:ok, :ok} = Task.await(holder_task, 15_000)
      assert {:ok, %{superseded: [gone]}} = Task.await(replacer, 15_000)

      assert gone.uuid == draft.uuid
      assert fetch(draft).deleted_at != nil
    end
  end

  describe "replace_draft_for_source/3 under the source lock" do
    test "two replacements for one source wait for the lock and leave exactly one live draft" do
      source = new_source()
      parent = self()

      lock_holder = hold_advisory(parent, source)
      assert_receive :locked, 10_000

      a = replace_task(source)
      b = replace_task(source)

      # Both are stuck on the source lock, in two independent connections.
      wait_for_advisory_waiters(2)
      assert Task.yield(a, 0) == nil
      assert Task.yield(b, 0) == nil
      assert live_for(source) == []

      send(lock_holder.pid, :commit)
      assert {:ok, :ok} = Task.await(lock_holder, 15_000)

      assert {:ok, first_result} = Task.await(a, 15_000)
      assert {:ok, second_result} = Task.await(b, 15_000)

      # One of them ran second and saw the other's committed draft.
      [earlier, later] = Enum.sort_by([first_result, second_result], &length(&1.superseded))
      assert earlier.superseded == []
      assert [trashed] = later.superseded
      assert trashed.uuid == earlier.order.uuid

      assert [only] = live_for(source)
      assert only.uuid == later.order.uuid
      assert fetch(earlier.order).deleted_at != nil
    end

    test "a replacement for another source does not wait for this source's lock" do
      source = new_source()
      other = new_source()
      parent = self()

      lock_holder = hold_advisory(parent, source)
      assert_receive :locked, 10_000

      assert {:ok, %{superseded: []}} = Task.await(replace_task(other), 15_000)

      send(lock_holder.pid, :commit)
      assert {:ok, :ok} = Task.await(lock_holder, 15_000)
    end

    test "restore with a swap takes the same lock, restore without a swap does not" do
      source = new_source()
      other_draft = insert!(source)
      trashed = insert!(source)

      {:ok, trashed} =
        unboxed(fn -> InternalOrders.soft_delete_internal_order(trashed, nil) end)

      parent = self()
      lock_holder = hold_advisory(parent, source)
      assert_receive :locked, 10_000

      swapper =
        Task.async(fn ->
          unboxed(fn -> InternalOrders.restore_internal_order(trashed, nil, swap: true) end)
        end)

      wait_for_advisory_waiters(1)
      assert Task.yield(swapper, 0) == nil
      assert fetch(trashed).deleted_at != nil

      send(lock_holder.pid, :commit)
      assert {:ok, :ok} = Task.await(lock_holder, 15_000)

      assert {:ok, %{superseded: [gone]}} = Task.await(swapper, 15_000)
      assert gone.uuid == other_draft.uuid
      assert [only] = live_for(source)
      assert only.uuid == trashed.uuid
    end

    test "restore without a swap does not wait for the source lock" do
      source = new_source()
      trashed = insert!(source)

      {:ok, trashed} =
        unboxed(fn -> InternalOrders.soft_delete_internal_order(trashed, nil) end)

      parent = self()
      lock_holder = hold_advisory(parent, source)
      assert_receive :locked, 10_000

      plain =
        Task.async(fn ->
          unboxed(fn -> InternalOrders.restore_internal_order(trashed, nil) end)
        end)

      assert {:ok, %{superseded: []}} = Task.await(plain, 15_000)

      send(lock_holder.pid, :commit)
      assert {:ok, :ok} = Task.await(lock_holder, 15_000)
    end
  end

  describe "activity is written after the commit" do
    @describetag :capture_log

    test "a log that fails does not undo the replacement" do
      source = new_source()
      first = insert!(source)

      # The database refuses every "trashed" activity row; the entry cannot be
      # written, whatever the module does. Were it written inside the
      # transaction, the refusal would abort it and the replacement with it.
      unboxed(fn ->
        Repo.query!("""
        CREATE OR REPLACE FUNCTION pkw_test_refuse_trashed_entry() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'pkw test: entry refused';
        END;
        $$ LANGUAGE plpgsql
        """)

        Repo.query!("""
        CREATE TRIGGER pkw_test_refuse_trashed_entry BEFORE INSERT ON phoenix_kit_activities
        FOR EACH ROW WHEN (NEW.action = 'warehouse.internal_order.trashed')
        EXECUTE FUNCTION pkw_test_refuse_trashed_entry()
        """)
      end)

      on_exit(fn ->
        unboxed(fn ->
          Repo.query!(
            "DROP TRIGGER IF EXISTS pkw_test_refuse_trashed_entry ON phoenix_kit_activities"
          )

          Repo.query!("DROP FUNCTION IF EXISTS pkw_test_refuse_trashed_entry()")
        end)
      end)

      assert {:ok, %{order: new, superseded: [gone]}} = Task.await(replace_task(source), 15_000)

      assert gone.uuid == first.uuid
      assert fetch(first).deleted_at != nil
      assert [only] = live_for(source)
      assert only.uuid == new.uuid

      assert unboxed(fn ->
               Repo.aggregate(from(e in Entry, where: e.resource_uuid == ^first.uuid), :count)
             end) == 0
    end
  end
end
