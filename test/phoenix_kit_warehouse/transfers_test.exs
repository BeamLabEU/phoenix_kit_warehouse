defmodule PhoenixKitWarehouse.TransfersTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.ActivityLog
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.Test.FakeSourceKind
  alias PhoenixKitWarehouse.Test.Repo
  alias PhoenixKitWarehouse.Transfers

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  @source_uuid "00000000-0000-0000-0000-0000000000a1"
  @destination_uuid "00000000-0000-0000-0000-0000000000a2"

  defp user_uuid do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "tr-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "TR",
        "last_name" => "Test"
      })

    user.uuid
  end

  defp seed_stock!(item_uuid, qty, location_uuid) do
    {:ok, _stock} =
      Warehouse.upsert_quantity(item_uuid, Decimal.new(qty), location_uuid: location_uuid)
  end

  defp sample_line(item_uuid, opts \\ []) do
    qty = Keyword.get(opts, :qty, "0")

    %{
      "item_uuid" => item_uuid,
      "name" => "Material #{System.unique_integer([:positive])}",
      "sku" => "MAT-#{System.unique_integer([:positive])}",
      "unit" => "piece",
      "catalogue_uuid" => Ecto.UUID.generate(),
      "transfer_quantity" => Decimal.new(qty)
    }
  end

  defp create_draft!(attrs \\ %{}) do
    base = %{source_location_uuid: @source_uuid, destination_location_uuid: @destination_uuid}
    {:ok, transfer} = Transfers.create_transfer(Map.merge(base, attrs))
    transfer
  end

  # Creates a draft with a single line for `item_uuid` (seeding 10 units at
  # the source first) and ships it — the common starting point for every
  # `receive_transfer/2` test. Returns `{shipped_transfer, performed_by_uuid}`.
  defp ship!(item_uuid, qty) do
    actor = user_uuid()
    seed_stock!(item_uuid, "10", @source_uuid)
    transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: qty)]})
    {:ok, shipped} = Transfers.ship_transfer(transfer, actor)
    {shipped, actor}
  end

  # ---------------------------------------------------------------------------
  # create_transfer/1
  # ---------------------------------------------------------------------------

  describe "create_transfer/1" do
    test "creates a draft with both locations" do
      transfer = create_draft!()

      assert transfer.status == "draft"
      assert transfer.source_location_uuid == @source_uuid
      assert transfer.destination_location_uuid == @destination_uuid
      assert transfer.uuid != nil
      assert transfer.number != nil
    end

    test "leaves locations nil when not supplied — no default-warehouse fallback" do
      assert {:ok, transfer} = Transfers.create_transfer(%{})

      assert transfer.status == "draft"
      assert transfer.source_location_uuid == nil
      assert transfer.destination_location_uuid == nil
    end

    test "assigns a unique number from the sequence" do
      t1 = create_draft!()
      t2 = create_draft!()

      assert t1.number != t2.number
    end

    test "stores lines" do
      item_uuid = Ecto.UUID.generate()
      lines = [sample_line(item_uuid, qty: "5")]

      transfer = create_draft!(%{lines: lines})

      assert length(transfer.lines) == 1
    end

    test "sets created_by_uuid programmatically" do
      actor = user_uuid()

      {:ok, transfer} = Transfers.create_transfer(%{created_by_uuid: actor})

      assert transfer.created_by_uuid == actor
    end
  end

  # ---------------------------------------------------------------------------
  # update_draft/2
  # ---------------------------------------------------------------------------

  describe "update_draft/2" do
    test "updates locations, lines, and note on a draft" do
      transfer = create_draft!(%{source_location_uuid: nil, destination_location_uuid: nil})
      item_uuid = Ecto.UUID.generate()
      lines = [sample_line(item_uuid, qty: "3")]

      {:ok, updated} =
        Transfers.update_draft(transfer, %{
          source_location_uuid: @source_uuid,
          destination_location_uuid: @destination_uuid,
          lines: lines,
          note: "updated"
        })

      assert updated.source_location_uuid == @source_uuid
      assert updated.destination_location_uuid == @destination_uuid
      assert length(updated.lines) == 1
      assert updated.note == "updated"
    end

    test "returns {:error, :not_draft} for a shipped transfer" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "5")]})
      {:ok, shipped} = Transfers.ship_transfer(transfer, actor)

      assert {:error, :not_draft} = Transfers.update_draft(shipped, %{note: "nope"})
    end
  end

  # ---------------------------------------------------------------------------
  # add_source_ref/3 and remove_source_ref/3
  # ---------------------------------------------------------------------------

  describe "add_source_ref/3 and remove_source_ref/3" do
    setup do
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
        %{
          kind: "widget",
          label: "Widget",
          search: {FakeSourceKind, :search, []},
          resolve: {FakeSourceKind, :resolve, []}
        }
      ])

      on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)
      :ok
    end

    test "attaches a reference without touching lines" do
      item_uuid = Ecto.UUID.generate()
      transfer = create_draft!(%{lines: [sample_line(item_uuid)]})
      uuid = Ecto.UUID.generate()

      assert {:ok, updated} = Transfers.add_source_ref(transfer, "widget", uuid)

      assert %{"type" => "widget", "uuid" => uuid} in updated.source_refs
      assert length(updated.lines) == 1
    end

    test "rejects an unregistered ref type" do
      transfer = create_draft!()

      assert {:error, :invalid_ref_type} =
               Transfers.add_source_ref(transfer, "not_a_kind", Ecto.UUID.generate())
    end

    test "adding the same {type, uuid} twice is a no-op" do
      transfer = create_draft!()
      uuid = Ecto.UUID.generate()

      {:ok, once} = Transfers.add_source_ref(transfer, "widget", uuid)
      {:ok, twice} = Transfers.add_source_ref(once, "widget", uuid)

      assert length(twice.source_refs) == 1
    end

    test "removes an attached reference" do
      transfer = create_draft!()
      uuid = Ecto.UUID.generate()

      {:ok, attached} = Transfers.add_source_ref(transfer, "widget", uuid)
      assert {:ok, removed} = Transfers.remove_source_ref(attached, "widget", uuid)

      assert removed.source_refs == []
    end

    test "removing a reference that isn't present is a no-op" do
      transfer = create_draft!()

      assert {:ok, updated} =
               Transfers.remove_source_ref(transfer, "widget", Ecto.UUID.generate())

      assert updated.source_refs == []
    end

    test "works on a shipped transfer (metadata-only, not draft-gated)" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "5")]})
      {:ok, shipped} = Transfers.ship_transfer(transfer, actor)
      uuid = Ecto.UUID.generate()

      assert {:ok, updated} = Transfers.add_source_ref(shipped, "widget", uuid)
      assert %{"type" => "widget", "uuid" => uuid} in updated.source_refs
      assert updated.status == "in_transit"
    end
  end

  # ---------------------------------------------------------------------------
  # ship_transfer/2 — stock DECREASES at the source
  # ---------------------------------------------------------------------------

  describe "ship_transfer/2" do
    test "flips status to in_transit and sets shipped_at and performed_by_uuid" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "5")]})

      {:ok, shipped} = Transfers.ship_transfer(transfer, actor)

      assert shipped.status == "in_transit"
      assert shipped.shipped_at != nil
      assert shipped.performed_by_uuid == actor
    end

    test "DECREASES stock at the source by transfer_quantity" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "4")]})

      {:ok, _shipped} = Transfers.ship_transfer(transfer, actor)

      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("6"))
    end

    test "does not touch the destination" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "4")]})

      {:ok, _shipped} = Transfers.ship_transfer(transfer, actor)

      assert Decimal.equal?(
               Warehouse.get_quantity(item_uuid, @destination_uuid),
               Decimal.new("0")
             )
    end

    test "insufficient stock on ANY line rolls back the WHOLE ship (no partial stock change), status stays draft" do
      actor = user_uuid()
      item1_uuid = Ecto.UUID.generate()
      item2_uuid = Ecto.UUID.generate()

      # item1 has stock, item2 does NOT
      seed_stock!(item1_uuid, "10", @source_uuid)

      lines = [
        sample_line(item1_uuid, qty: "5"),
        sample_line(item2_uuid, qty: "3")
      ]

      transfer = create_draft!(%{lines: lines})

      result = Transfers.ship_transfer(transfer, actor)

      assert {:error, {:insufficient_stock, ^item2_uuid}} = result

      # item1 stock must be UNCHANGED — whole transaction rolled back
      assert Decimal.equal?(Warehouse.get_quantity(item1_uuid, @source_uuid), Decimal.new("10"))

      # Document must still be draft
      reloaded = Transfers.get_transfer!(transfer.uuid)
      assert reloaded.status == "draft"
    end

    test "previous_source_quantity audit is captured in persisted lines" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "15", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "5")]})

      {:ok, shipped} = Transfers.ship_transfer(transfer, actor)

      [line] = shipped.lines
      prev_qty = Warehouse.to_decimal(line["previous_source_quantity"])
      assert Decimal.equal?(prev_qty, Decimal.new("15"))
    end

    test "transfer_quantity 0 line is a no-op (no stock change)" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      # No stock at all — but transfer_quantity=0 so it's a skip

      stock_before = Repo.all(Stock)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "0")]})
      {:ok, _shipped} = Transfers.ship_transfer(transfer, actor)
      stock_after = Repo.all(Stock)

      new_rows =
        Enum.reject(stock_after, fn s ->
          Enum.any?(stock_before, &(&1.uuid == s.uuid))
        end)

      assert new_rows == []
    end

    test "deduplicates lines by item_uuid on shipping" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "20", @source_uuid)

      dup_lines = [
        sample_line(item_uuid, qty: "5"),
        sample_line(item_uuid, qty: "3")
      ]

      transfer = create_draft!(%{lines: dup_lines})
      {:ok, shipped} = Transfers.ship_transfer(transfer, actor)

      assert length(shipped.lines) == 1
    end

    test "multiple items all decrease source stock" do
      actor = user_uuid()
      item1 = Ecto.UUID.generate()
      item2 = Ecto.UUID.generate()
      seed_stock!(item1, "10", @source_uuid)
      seed_stock!(item2, "8", @source_uuid)

      lines = [
        sample_line(item1, qty: "3"),
        sample_line(item2, qty: "5")
      ]

      transfer = create_draft!(%{lines: lines})
      {:ok, _shipped} = Transfers.ship_transfer(transfer, actor)

      assert Decimal.equal?(Warehouse.get_quantity(item1, @source_uuid), Decimal.new("7"))
      assert Decimal.equal?(Warehouse.get_quantity(item2, @source_uuid), Decimal.new("3"))
    end

    test "double-ship guard: returns {:error, :not_draft}" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "2")]})

      {:ok, _shipped} = Transfers.ship_transfer(transfer, actor)
      assert {:error, :not_draft} = Transfers.ship_transfer(transfer, actor)
    end

    test "in-memory guard: ship on a struct with status != draft returns {:error, :not_draft}" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "2")]})
      {:ok, shipped} = Transfers.ship_transfer(transfer, actor)

      assert {:error, :not_draft} = Transfers.ship_transfer(shipped, actor)
    end

    test "nil source_location_uuid returns {:error, :locations_required} without touching stock" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)

      transfer =
        create_draft!(%{source_location_uuid: nil, lines: [sample_line(item_uuid, qty: "2")]})

      assert {:error, :locations_required} = Transfers.ship_transfer(transfer, actor)
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("10"))
    end

    test "nil destination_location_uuid returns {:error, :locations_required} without touching stock" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)

      transfer =
        create_draft!(%{
          destination_location_uuid: nil,
          lines: [sample_line(item_uuid, qty: "2")]
        })

      assert {:error, :locations_required} = Transfers.ship_transfer(transfer, actor)
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("10"))
    end

    test "equal source and destination returns {:error, :locations_required}" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)

      transfer =
        create_draft!(%{
          destination_location_uuid: @source_uuid,
          lines: [sample_line(item_uuid, qty: "2")]
        })

      assert {:error, :locations_required} = Transfers.ship_transfer(transfer, actor)
    end
  end

  # ---------------------------------------------------------------------------
  # receive_transfer/2 — stock INCREASES at the destination
  # ---------------------------------------------------------------------------

  describe "receive_transfer/2" do
    test "flips status to done and sets received_at and performed_by_uuid" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "5")

      {:ok, received} = Transfers.receive_transfer(shipped, actor)

      assert received.status == "done"
      assert received.received_at != nil
      assert received.performed_by_uuid == actor
    end

    test "INCREASES stock at the destination by transfer_quantity" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "5")

      {:ok, _received} = Transfers.receive_transfer(shipped, actor)

      assert Decimal.equal?(
               Warehouse.get_quantity(item_uuid, @destination_uuid),
               Decimal.new("5")
             )
    end

    test "does not touch the source again" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "4")

      # Source is 10 - 4 = 6 right after shipping.
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("6"))

      {:ok, _received} = Transfers.receive_transfer(shipped, actor)

      # Receiving must not touch the source a second time.
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("6"))
    end

    test "is additive — existing destination stock is preserved" do
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "100", @destination_uuid)
      {shipped, actor} = ship!(item_uuid, "5")

      {:ok, _received} = Transfers.receive_transfer(shipped, actor)

      assert Decimal.equal?(
               Warehouse.get_quantity(item_uuid, @destination_uuid),
               Decimal.new("105")
             )
    end

    test "previous_destination_quantity audit is captured in persisted lines" do
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "20", @destination_uuid)
      {shipped, actor} = ship!(item_uuid, "5")

      {:ok, received} = Transfers.receive_transfer(shipped, actor)

      [line] = received.lines
      prev_qty = Warehouse.to_decimal(line["previous_destination_quantity"])
      assert Decimal.equal?(prev_qty, Decimal.new("20"))
    end

    test "transfer_quantity 0 line is a no-op at the destination" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "0")

      {:ok, _received} = Transfers.receive_transfer(shipped, actor)

      assert Decimal.equal?(
               Warehouse.get_quantity(item_uuid, @destination_uuid),
               Decimal.new("0")
             )
    end

    test "double-receive guard: returns {:error, :not_in_transit}" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "5")

      {:ok, received} = Transfers.receive_transfer(shipped, actor)
      assert received.status == "done"
      assert {:error, :not_in_transit} = Transfers.receive_transfer(shipped, actor)
    end

    test "receiving a draft transfer returns {:error, :not_in_transit}" do
      actor = user_uuid()
      transfer = create_draft!()

      assert {:error, :not_in_transit} = Transfers.receive_transfer(transfer, actor)
    end

    test "nil location on the record returns {:error, :locations_required} (data-corruption guard)" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "5")

      # Simulate manually-corrupted data (bypassing the changeset guards that
      # would normally keep both locations set once a transfer has shipped).
      corrupted = %{shipped | destination_location_uuid: nil}

      assert {:error, :locations_required} = Transfers.receive_transfer(corrupted, actor)
    end
  end

  # ---------------------------------------------------------------------------
  # cancel_transfer/2
  # ---------------------------------------------------------------------------

  describe "cancel_transfer/2" do
    test "from draft: flips status, sets cancelled_at/performed_by_uuid, no stock change" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "5")]})

      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("10"))

      {:ok, cancelled} = Transfers.cancel_transfer(transfer, actor)

      assert cancelled.status == "cancelled"
      assert cancelled.cancelled_at != nil
      assert cancelled.performed_by_uuid == actor

      # No postings — the goods never physically moved.
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("10"))
    end

    test "from in_transit: reverses the ship — source quantity returns to its pre-ship value" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "5")

      # 10 (seeded) - 5 (shipped) = 5.
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("5"))

      {:ok, cancelled} = Transfers.cancel_transfer(shipped, actor)

      assert cancelled.status == "cancelled"
      assert cancelled.cancelled_at != nil
      assert cancelled.performed_by_uuid == actor
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("10"))
    end

    test "from in_transit: does not touch the destination" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "5")

      {:ok, _cancelled} = Transfers.cancel_transfer(shipped, actor)

      assert Decimal.equal?(
               Warehouse.get_quantity(item_uuid, @destination_uuid),
               Decimal.new("0")
             )
    end

    test "reversed_source_quantity audit is captured in persisted lines" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "5")

      {:ok, cancelled} = Transfers.cancel_transfer(shipped, actor)

      [line] = cancelled.lines
      # Source is 5 right before the reversal credit (10 seeded - 5 shipped).
      prev_qty = Warehouse.to_decimal(line["reversed_source_quantity"])
      assert Decimal.equal?(prev_qty, Decimal.new("5"))
    end

    test "transfer_quantity 0 line is a no-op on cancel from in_transit" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "0")

      {:ok, _cancelled} = Transfers.cancel_transfer(shipped, actor)

      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("10"))
    end

    test "from done: returns {:error, :not_cancellable}, status stays done" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "5")
      {:ok, received} = Transfers.receive_transfer(shipped, actor)

      assert {:error, :not_cancellable} = Transfers.cancel_transfer(received, actor)

      reloaded = Transfers.get_transfer!(received.uuid)
      assert reloaded.status == "done"
    end

    test "cancelling an already-cancelled transfer returns {:error, :not_cancellable} without double-crediting the source" do
      item_uuid = Ecto.UUID.generate()
      {shipped, actor} = ship!(item_uuid, "5")
      {:ok, cancelled} = Transfers.cancel_transfer(shipped, actor)
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("10"))

      assert {:error, :not_cancellable} = Transfers.cancel_transfer(cancelled, actor)

      # Still 10 — a second reversal would have wrongly bumped it to 15.
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid, @source_uuid), Decimal.new("10"))
    end
  end

  # ---------------------------------------------------------------------------
  # ActivityLog.log_transfer_cancelled/2
  # ---------------------------------------------------------------------------

  describe "ActivityLog.log_transfer_cancelled/2" do
    test "writes a queryable warehouse.transfer.cancelled activity entry" do
      actor = user_uuid()
      transfer = create_draft!()
      {:ok, cancelled} = Transfers.cancel_transfer(transfer, actor)

      assert :ok = ActivityLog.log_transfer_cancelled(cancelled, actor_uuid: actor)

      %{entries: entries} = PhoenixKit.Activity.list(action: "warehouse.transfer.cancelled")
      assert Enum.any?(entries, &(&1.resource_uuid == cancelled.uuid))
    end
  end

  # ---------------------------------------------------------------------------
  # soft_delete_transfer/2
  # ---------------------------------------------------------------------------

  describe "soft_delete_transfer/2" do
    test "soft-deletes a draft transfer" do
      actor = user_uuid()
      transfer = create_draft!()

      {:ok, deleted} = Transfers.soft_delete_transfer(transfer, actor)

      assert deleted.deleted_at != nil
      assert deleted.deleted_by_uuid == actor
    end

    test "excludes soft-deleted transfers from list" do
      actor = user_uuid()
      transfer = create_draft!()
      {:ok, _} = Transfers.soft_delete_transfer(transfer, actor)

      all = Transfers.list_transfers()
      refute Enum.any?(all, &(&1.uuid == transfer.uuid))
    end

    test "returns {:error, :not_draft} for a shipped transfer" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "2")]})
      {:ok, shipped} = Transfers.ship_transfer(transfer, actor)

      assert {:error, :not_draft} = Transfers.soft_delete_transfer(shipped, actor)
    end
  end

  # ---------------------------------------------------------------------------
  # correct_transfer/2
  # ---------------------------------------------------------------------------

  describe "correct_transfer/2" do
    test "updates note on a shipped transfer without changing status or lines" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10", @source_uuid)
      transfer = create_draft!(%{lines: [sample_line(item_uuid, qty: "2")]})
      {:ok, shipped} = Transfers.ship_transfer(transfer, actor)

      {:ok, corrected} = Transfers.correct_transfer(shipped, %{note: "corrected note"})

      assert corrected.note == "corrected note"
      assert corrected.status == "in_transit"
      assert length(corrected.lines) == length(shipped.lines)
    end

    test "sets storage_folder_uuid" do
      transfer = create_draft!()
      folder_uuid = Ecto.UUID.generate()

      {:ok, corrected} = Transfers.correct_transfer(transfer, %{storage_folder_uuid: folder_uuid})

      assert corrected.storage_folder_uuid == folder_uuid
    end
  end

  # ---------------------------------------------------------------------------
  # set_storage_folder/2
  # ---------------------------------------------------------------------------

  describe "set_storage_folder/2" do
    test "sets the storage folder on any status" do
      transfer = create_draft!()
      folder_uuid = Ecto.UUID.generate()

      {:ok, updated} = Transfers.set_storage_folder(transfer, folder_uuid)

      assert updated.storage_folder_uuid == folder_uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  describe "list_transfers/0" do
    test "includes non-deleted transfers" do
      transfer = create_draft!()
      all = Transfers.list_transfers()
      assert Enum.any?(all, &(&1.uuid == transfer.uuid))
    end
  end

  describe "get_transfer!/1 and get_transfer/1" do
    test "get_transfer!/1 raises on missing" do
      assert_raise Ecto.NoResultsError, fn ->
        Transfers.get_transfer!(Ecto.UUID.generate())
      end
    end

    test "get_transfer/1 returns {:error, :not_found} on missing" do
      assert {:error, :not_found} = Transfers.get_transfer(Ecto.UUID.generate())
    end

    test "get_transfer/1 returns {:ok, transfer}" do
      transfer = create_draft!()
      assert {:ok, found} = Transfers.get_transfer(transfer.uuid)
      assert found.uuid == transfer.uuid
    end
  end
end
