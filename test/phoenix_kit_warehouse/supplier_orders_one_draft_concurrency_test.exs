defmodule PhoenixKitWarehouse.SupplierOrdersOneDraftConcurrencyTest do
  @moduledoc """
  What the "one draft per (internal order, supplier)" rule needs two real
  connections to show.

  Inside the sandbox there is a single connection: a transaction-scoped
  advisory lock is re-entrant for the session that already holds it and a row
  lock never makes the same session wait, so a test there proves nothing about
  serialisation. Every process here runs on its own committed connection
  (`Sandbox.unboxed_run/2`) and everything it commits is removed again in
  `on_exit`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Activity.Entry
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Test.Repo

  @moduletag :integration

  @location "00000000-0000-0000-0000-000000000001"

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp unique, do: System.unique_integer([:positive])

  # A posted internal order for one item whose only supplier is `supplier`,
  # all of it committed and removed again at the end of the test.
  defp new_order do
    fixture =
      unboxed(fn ->
        {:ok, supplier} =
          Catalogue.create_supplier(%{name: "Supplier #{unique()}", status: "active"})

        {:ok, mfr} = Catalogue.create_manufacturer(%{name: "Mfr #{unique()}", status: "active"})
        Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
        {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat #{unique()}", status: "active"})

        {:ok, item} =
          Catalogue.create_item(%{
            name: "Item #{unique()}",
            catalogue_uuid: cat.uuid,
            manufacturer_uuid: mfr.uuid,
            status: "active"
          })

        {:ok, io} =
          InternalOrders.create_internal_order(%{
            location_uuid: @location,
            lines: [
              %{
                "item_uuid" => item.uuid,
                "name" => item.name,
                "unit" => "piece",
                "required_quantity" => "10"
              }
            ]
          })

        {:ok, io} = InternalOrders.post_internal_order(io, nil)
        %{io: io, supplier: supplier, mfr: mfr, cat: cat, item: item}
      end)

    on_exit(fn ->
      unboxed(fn ->
        so_uuids =
          Repo.all(
            from(o in SupplierOrder,
              where: o.internal_order_uuid == ^fixture.io.uuid,
              select: o.uuid
            )
          )

        Repo.delete_all(from(e in Entry, where: e.resource_uuid in ^so_uuids))
        Repo.delete_all(from(o in SupplierOrder, where: o.uuid in ^so_uuids))
        Repo.delete_all(from(o in InternalOrder, where: o.uuid == ^fixture.io.uuid))
        Catalogue.delete_item(fixture.item)
        Catalogue.delete_catalogue(fixture.cat)
        Catalogue.delete_supplier(fixture.supplier)
        Catalogue.delete_manufacturer(fixture.mfr)
      end)
    end)

    fixture
  end

  defp advisory_key(io), do: "phoenix_kit_warehouse:so_for_io:#{io.uuid}"

  defp generate_task(io, opts \\ [supersede_drafts: true]) do
    Task.async(fn ->
      unboxed(fn ->
        SupplierOrders.generate_from_internal_order(io, Ecto.UUID.generate(), opts)
      end)
    end)
  end

  defp fetch(order_or_uuid) do
    uuid = if is_struct(order_or_uuid), do: order_or_uuid.uuid, else: order_or_uuid
    unboxed(fn -> Repo.get!(SupplierOrder, uuid) end)
  end

  defp live_for(%{io: io, supplier: supplier}) do
    unboxed(fn ->
      Repo.all(
        from(o in SupplierOrder,
          where:
            o.internal_order_uuid == ^io.uuid and o.supplier_uuid == ^supplier.uuid and
              is_nil(o.deleted_at)
        )
      )
    end)
  end

  defp insert_draft!(%{io: io, supplier: supplier}, attrs \\ %{}) do
    unboxed(fn ->
      {:ok, so} =
        SupplierOrders.create_supplier_order(
          Map.merge(
            %{
              location_uuid: @location,
              internal_order_uuid: io.uuid,
              supplier_uuid: supplier.uuid
            },
            attrs
          )
        )

      so
    end)
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

  defp hold_advisory(parent, io) do
    holder(parent, fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [advisory_key(io)])
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

  defp wait_for_row_lock_waiter(expected \\ 1) do
    wait_until(
      "#{expected} session(s) waiting for a supplier order row lock",
      "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " <>
        "AND wait_event_type = 'Lock' " <>
        "AND query ILIKE '%phoenix_kit_warehouse_supplier_orders%'",
      expected
    )
  end

  defp plan!(io) do
    {:ok, plan} = unboxed(fn -> SupplierOrders.plan_from_internal_order(io.uuid) end)
    plan
  end

  defp apply_task(io, fingerprint) do
    Task.async(fn ->
      unboxed(fn -> SupplierOrders.apply_plan(io.uuid, fingerprint, %{}, nil) end)
    end)
  end

  # Gives a supplier order a uuid of the caller's choice, so a test knows the
  # order rows are locked in.
  defp with_uuid!(order, prefix) do
    new_uuid = prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    unboxed(fn ->
      {1, _} =
        Repo.update_all(from(o in SupplierOrder, where: o.uuid == ^order.uuid),
          set: [uuid: new_uuid]
        )

      Repo.get!(SupplierOrder, new_uuid)
    end)
  end

  describe "generation with supersede_drafts racing a posting" do
    test "a draft posted while the generation waits for its row stays posted and is not reported" do
      fx = new_order()
      draft = insert_draft!(fx)
      parent = self()

      # Posts the draft in another connection and keeps its row locked.
      poster =
        holder(parent, fn ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          {1, _} =
            Repo.update_all(from(o in SupplierOrder, where: o.uuid == ^draft.uuid),
              set: [status: "posted", posted_at: now, updated_at: now]
            )
        end)

      assert_receive :locked, 10_000

      generator = generate_task(fx.io)
      wait_for_row_lock_waiter()
      send(poster.pid, :commit)

      assert {:ok, :ok} = Task.await(poster, 15_000)
      assert {:ok, %{supplier_orders: [new], superseded: []}} = Task.await(generator, 15_000)

      reloaded = fetch(draft)
      assert reloaded.status == "posted"
      assert reloaded.deleted_at == nil
      assert reloaded.deleted_by_uuid == nil

      assert Enum.sort(Enum.map(live_for(fx), & &1.uuid)) == Enum.sort([draft.uuid, new.uuid])
    end

    test "a draft that is still a draft when the generation gets its row is appended to" do
      fx = new_order()
      draft = insert_draft!(fx)
      parent = self()

      # Holds the row without changing it, then lets go.
      holder_task =
        holder(parent, fn ->
          Repo.all(from(o in SupplierOrder, where: o.uuid == ^draft.uuid, lock: "FOR UPDATE"))
        end)

      assert_receive :locked, 10_000

      generator = generate_task(fx.io)
      wait_for_row_lock_waiter()
      send(holder_task.pid, :commit)

      assert {:ok, :ok} = Task.await(holder_task, 15_000)

      assert {:ok, %{supplier_orders: [], appended: [appended], superseded: []}} =
               Task.await(generator, 15_000)

      assert appended.uuid == draft.uuid
      written = fetch(draft)
      assert written.deleted_at == nil
      assert [%{"ordered_quantity" => "10"}] = written.lines
    end
  end

  describe "generation under the internal order lock" do
    test "two generations wait for the lock and leave exactly one live draft" do
      fx = new_order()
      parent = self()

      lock_holder = hold_advisory(parent, fx.io)
      assert_receive :locked, 10_000

      a = generate_task(fx.io)
      b = generate_task(fx.io)

      # Both are stuck on the lock, in two independent connections.
      wait_for_advisory_waiters(2)
      assert Task.yield(a, 0) == nil
      assert Task.yield(b, 0) == nil
      assert live_for(fx) == []

      send(lock_holder.pid, :commit)
      assert {:ok, :ok} = Task.await(lock_holder, 15_000)

      assert {:ok, first_result} = Task.await(a, 15_000)
      assert {:ok, second_result} = Task.await(b, 15_000)

      # One of them ran second, saw the other's committed draft and found
      # nothing missing.
      [later, earlier] = Enum.sort_by([first_result, second_result], &length(&1.supplier_orders))
      assert later.supplier_orders == [] and later.appended == []
      assert [earlier_order] = earlier.supplier_orders
      assert earlier.superseded == [] and later.superseded == []

      assert [only] = live_for(fx)
      assert only.uuid == earlier_order.uuid
    end

    test "a generation without the option waits for the lock too" do
      fx = new_order()
      parent = self()

      lock_holder = hold_advisory(parent, fx.io)
      assert_receive :locked, 10_000

      generator = generate_task(fx.io, [])
      wait_for_advisory_waiters(1)
      assert Task.yield(generator, 0) == nil

      send(lock_holder.pid, :commit)
      assert {:ok, :ok} = Task.await(lock_holder, 15_000)

      assert {:ok, %{supplier_orders: [_], superseded: []}} = Task.await(generator, 15_000)
    end

    test "a generation for another internal order does not wait for this one's lock" do
      fx = new_order()
      other = new_order()
      parent = self()

      lock_holder = hold_advisory(parent, fx.io)
      assert_receive :locked, 10_000

      assert {:ok, %{supplier_orders: [_], superseded: []}} =
               Task.await(generate_task(other.io), 15_000)

      send(lock_holder.pid, :commit)
      assert {:ok, :ok} = Task.await(lock_holder, 15_000)
    end

    test "restore with a swap takes the same lock, restore without a swap does not" do
      fx = new_order()
      rival = insert_draft!(fx)
      trashed = insert_draft!(fx)
      other_trashed = insert_draft!(fx, %{note: "second"})

      {:ok, trashed} =
        unboxed(fn -> SupplierOrders.soft_delete_supplier_order(trashed, nil) end)

      {:ok, other_trashed} =
        unboxed(fn -> SupplierOrders.soft_delete_supplier_order(other_trashed, nil) end)

      parent = self()
      lock_holder = hold_advisory(parent, fx.io)
      assert_receive :locked, 10_000

      swapper =
        Task.async(fn ->
          unboxed(fn -> SupplierOrders.restore_supplier_order(trashed, nil, swap: true) end)
        end)

      wait_for_advisory_waiters(1)
      assert Task.yield(swapper, 0) == nil
      assert fetch(trashed).deleted_at != nil

      # A restore without a swap goes through while the lock is held.
      plain =
        Task.async(fn ->
          unboxed(fn -> SupplierOrders.restore_supplier_order(other_trashed, nil) end)
        end)

      assert {:ok, %{superseded: []}} = Task.await(plain, 15_000)

      send(lock_holder.pid, :commit)
      assert {:ok, :ok} = Task.await(lock_holder, 15_000)

      assert {:ok, %{superseded: superseded}} = Task.await(swapper, 15_000)

      # The swap trashes every other live draft of the pair: the rival and the
      # one the plain restore has just brought back.
      assert Enum.sort(Enum.map(superseded, & &1.uuid)) ==
               Enum.sort([rival.uuid, other_trashed.uuid])

      assert [only] = live_for(fx)
      assert only.uuid == trashed.uuid
    end
  end

  describe "activity is written after the commit" do
    @describetag :capture_log

    test "a log that fails does not undo a restore with a swap" do
      fx = new_order()
      first = insert_draft!(fx)

      to_trash = insert_draft!(fx)
      {:ok, trashed} = unboxed(fn -> SupplierOrders.soft_delete_supplier_order(to_trash, nil) end)

      # The database refuses every "trashed" activity row; the entry cannot be
      # written, whatever the module does. Were it written inside the
      # transaction, the refusal would abort it and the restore with it.
      unboxed(fn ->
        Repo.query!("""
        CREATE OR REPLACE FUNCTION pkw_test_refuse_so_trashed_entry() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'pkw test: entry refused';
        END;
        $$ LANGUAGE plpgsql
        """)

        Repo.query!("""
        CREATE TRIGGER pkw_test_refuse_so_trashed_entry BEFORE INSERT ON phoenix_kit_activities
        FOR EACH ROW WHEN (NEW.action = 'warehouse.supplier_order.trashed')
        EXECUTE FUNCTION pkw_test_refuse_so_trashed_entry()
        """)
      end)

      on_exit(fn ->
        unboxed(fn ->
          Repo.query!(
            "DROP TRIGGER IF EXISTS pkw_test_refuse_so_trashed_entry ON phoenix_kit_activities"
          )

          Repo.query!("DROP FUNCTION IF EXISTS pkw_test_refuse_so_trashed_entry()")
        end)
      end)

      assert {:ok, %{order: restored, superseded: [gone]}} =
               unboxed(fn -> SupplierOrders.restore_supplier_order(trashed, nil, swap: true) end)

      assert gone.uuid == first.uuid
      assert fetch(first).deleted_at != nil
      assert [only] = live_for(fx)
      assert only.uuid == restored.uuid

      assert unboxed(fn ->
               Repo.aggregate(from(e in Entry, where: e.resource_uuid == ^first.uuid), :count)
             end) == 0
    end
  end

  describe "apply_plan under the internal order lock" do
    test "two applies of one plan: one writes, the other answers a stale plan" do
      fx = new_order()
      plan = plan!(fx.io)
      parent = self()

      lock_holder = hold_advisory(parent, fx.io)
      assert_receive :locked, 10_000

      a = apply_task(fx.io, plan.fingerprint)
      b = apply_task(fx.io, plan.fingerprint)
      wait_for_advisory_waiters(2)
      assert live_for(fx) == []

      send(lock_holder.pid, :commit)
      assert {:ok, :ok} = Task.await(lock_holder, 15_000)

      results =
        Enum.sort_by([Task.await(a, 15_000), Task.await(b, 15_000)], &match?({:ok, _}, &1))

      assert [{:error, {:stale, new_plan}}, {:ok, %{supplier_orders: [written]}}] = results

      refute new_plan.fingerprint == plan.fingerprint
      assert [%{to_order: to_order}] = new_plan.lines
      assert Decimal.eq?(to_order, 0)
      assert [only] = live_for(fx)
      assert only.uuid == written.uuid
    end

    test "posting a draft of the order, started after apply locked it, waits for apply" do
      fx = new_order()
      # apply locks the order's rows in uuid order: the target, then the blocker
      target = fx |> insert_draft!() |> with_uuid!("00000000-0000-4000-8000-")

      blocker =
        fx
        |> insert_draft!(%{supplier_uuid: Ecto.UUID.generate()})
        |> with_uuid!("ffffffff-ffff-4fff-bfff-")

      plan = plan!(fx.io)
      parent = self()

      holder_task =
        holder(parent, fn ->
          Repo.all(from(o in SupplierOrder, where: o.uuid == ^blocker.uuid, lock: "FOR UPDATE"))
        end)

      assert_receive :locked, 10_000

      applier = apply_task(fx.io, plan.fingerprint)
      wait_for_row_lock_waiter(1)

      poster =
        Task.async(fn -> unboxed(fn -> SupplierOrders.post_supplier_order(target, nil) end) end)

      wait_for_row_lock_waiter(2)
      assert Task.yield(poster, 0) == nil

      send(holder_task.pid, :commit)
      assert {:ok, :ok} = Task.await(holder_task, 15_000)

      assert {:ok, %{appended: [appended], supplier_orders: []}} = Task.await(applier, 15_000)
      assert appended.uuid == target.uuid

      # Posted after the append: what was appended is in it.
      assert {:ok, posted} = Task.await(poster, 15_000)
      assert posted.status == "posted"
      assert [%{"ordered_quantity" => "10"}] = posted.lines
    end

    test "an import from the order waits for the order's lock" do
      fx = new_order()
      draft = insert_draft!(fx)
      parent = self()

      lock_holder = hold_advisory(parent, fx.io)
      assert_receive :locked, 10_000

      importer =
        Task.async(fn ->
          unboxed(fn -> SupplierOrders.import_from_internal_orders(draft, [fx.io.uuid], nil) end)
        end)

      wait_for_advisory_waiters(1)
      assert Task.yield(importer, 0) == nil

      send(lock_holder.pid, :commit)
      assert {:ok, :ok} = Task.await(lock_holder, 15_000)

      assert {:ok, imported} = Task.await(importer, 15_000)
      assert [%{"ordered_quantity" => "10"}] = fetch(imported).lines
    end
  end
end
