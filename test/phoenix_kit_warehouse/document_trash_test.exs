defmodule PhoenixKitWarehouse.DocumentTrashTest do
  @moduledoc """
  The trash of goods receipts, goods issues, inventory documents and transfers
  (the same rules internal and supplier orders follow): the move to the trash
  and back (`DraftTrash.trash_one/3`, `DraftTrash.restore_one/2` under the
  context functions), the `deleted_at` guard of the draft-only writes, the
  source refs of a trashed document, the trash lists and counters, and the
  activity entries.

  The shared rules run once per kind (`@describetag kind:`); what only one kind
  has (the transfer statuses, the legacy in-transit transfer in the trash, the
  imports, the reserve of an internal order) has its own describe below.
  Everything runs in the sandbox, sequentially; `FOR UPDATE` itself is not
  covered here (it only matters under real concurrency).
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKitWarehouse.DraftTrash
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Test.FakeOrderSources
  alias PhoenixKitWarehouse.Transfer
  alias PhoenixKitWarehouse.Transfers

  @location "00000000-0000-0000-0000-000000000001"
  @source_location "00000000-0000-0000-0000-0000000000a1"
  @destination_location "00000000-0000-0000-0000-0000000000a2"

  @kinds [:goods_receipt, :goods_issue, :inventory, :transfer]
  @with_refs [:goods_receipt, :goods_issue, :transfer]

  setup do
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
      FakeOrderSources.order_kind(),
      FakeOrderSources.sub_order_kind()
    ])

    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Rules shared by the four kinds
  # ---------------------------------------------------------------------------

  for kind <- @kinds do
    describe "#{kind}: move to the trash" do
      @describetag kind: kind

      test "a draft goes to the trash with the actor and a fresh updated_at", %{kind: kind} do
        doc = draft!(kind)
        set_updated_at(kind, doc, ~U[2026-01-01 10:00:00Z])
        actor = uuid()

        assert {:ok, trashed} = trash(kind, doc, actor)
        assert trashed.__struct__ == schema(kind)
        assert %DateTime{} = trashed.deleted_at
        assert trashed.deleted_by_uuid == actor
        assert trashed.status == "draft"
        assert DateTime.compare(trashed.updated_at, ~U[2026-01-01 10:00:00Z]) == :gt

        refute live?(kind, doc)
        assert reload(kind, doc).deleted_by_uuid == actor
      end

      test "a non-draft answers :not_draft and stays live", %{kind: kind} do
        for doc <- non_drafts!(kind) do
          assert {:error, :not_draft} = trash(kind, doc, uuid())
          assert live?(kind, doc)
        end
      end

      test "a stale draft struct of a document posted meanwhile answers :not_draft",
           %{kind: kind} do
        stale = postable_draft!(kind)
        posted = post!(kind, stale)
        refute posted.status == "draft"

        assert {:error, :not_draft} = trash(kind, stale, uuid())
        assert live?(kind, stale)
        assert reload(kind, stale).status == posted.status
      end

      test "a second move answers :deleted and keeps the first deletion marks", %{kind: kind} do
        first_actor = uuid()
        {:ok, trashed} = trash(kind, draft!(kind), first_actor)

        assert {:error, :deleted} = trash(kind, trashed, uuid())
        assert reload(kind, trashed).deleted_by_uuid == first_actor
      end

      test "a live draft struct of a row trashed meanwhile answers :deleted", %{kind: kind} do
        doc = draft!(kind)
        {:ok, _} = trash(kind, doc, uuid())

        assert {:error, :deleted} = trash(kind, doc, uuid())
      end

      test "a missing row answers :not_found", %{kind: kind} do
        ghost = struct(schema(kind), uuid: uuid(), status: "draft")
        assert {:error, :not_found} = trash(kind, ghost, uuid())
      end
    end

    describe "#{kind}: restore" do
      @describetag kind: kind

      test "brings a trashed draft back and clears the deletion marks", %{kind: kind} do
        {:ok, trashed} = trash(kind, draft!(kind), uuid())

        assert {:ok, restored} = restore(kind, trashed, uuid())
        assert restored.__struct__ == schema(kind)
        assert restored.deleted_at == nil
        assert restored.deleted_by_uuid == nil
        assert restored.status == "draft"
        assert live?(kind, trashed)
      end

      test "a live document answers :not_deleted", %{kind: kind} do
        assert {:error, :not_deleted} = restore(kind, draft!(kind), uuid())
      end

      test "restoring twice answers :not_deleted the second time", %{kind: kind} do
        {:ok, trashed} = trash(kind, draft!(kind), uuid())

        assert {:ok, _} = restore(kind, trashed, uuid())
        assert {:error, :not_deleted} = restore(kind, trashed, uuid())
      end

      test "a trashed non-draft (legacy) answers :not_draft and stays trashed",
           %{kind: kind} do
        for doc <- non_drafts!(kind) do
          force_trash!(kind, doc)

          assert {:error, :not_draft} = restore(kind, doc, uuid())
          refute live?(kind, doc)
        end
      end

      test "a missing row answers :not_found", %{kind: kind} do
        assert {:error, :not_found} = restore(kind, struct(schema(kind), uuid: uuid()), uuid())
      end

      test "a restored draft can be edited and posted again", %{kind: kind} do
        {:ok, trashed} = trash(kind, postable_draft!(kind), uuid())
        {:ok, restored} = restore(kind, trashed, nil)

        assert {:ok, %{note: "edited"}} = edit(kind, restored, %{note: "edited"})
        assert {:ok, posted} = post(kind, restored)
        refute posted.status == "draft"
      end
    end

    describe "#{kind}: a trashed draft refuses the draft-only writes" do
      @describetag kind: kind

      test "update_draft answers :deleted and writes nothing", %{kind: kind} do
        doc = draft!(kind)
        {:ok, _} = trash(kind, doc, uuid())

        assert {:error, :deleted} = edit(kind, doc, %{note: "edited"})
        assert reload(kind, doc).note == nil
      end

      test "posting a stale struct of a trashed draft answers :deleted and moves no stock",
           %{kind: kind} do
        doc = postable_draft!(kind)
        before = stock_snapshot(kind, doc)
        {:ok, _} = trash(kind, doc, uuid())

        assert {:error, :deleted} = post(kind, doc)
        assert reload(kind, doc).status == "draft"
        assert stock_snapshot(kind, doc) == before
      end

      test "a live non-draft still answers :not_draft to a stale draft struct", %{kind: kind} do
        posted = post!(kind, postable_draft!(kind))
        stale = %{posted | status: "draft"}

        assert {:error, :not_draft} = edit(kind, stale, %{note: "x"})
        assert {:error, :not_draft} = post(kind, stale)
      end

      test "update_draft of a missing row keeps answering :not_draft", %{kind: kind} do
        ghost = struct(schema(kind), uuid: uuid(), status: "draft")
        assert {:error, :not_draft} = edit(kind, ghost, %{note: "x"})
      end
    end

    describe "#{kind}: trash lists" do
      @describetag kind: kind

      test "the default list is the live documents, trashed: true lists the trashed ones",
           %{kind: kind} do
        live = draft!(kind)
        {:ok, trashed} = trash(kind, draft!(kind), uuid())

        assert live.uuid in uuids(list(kind, []))
        refute trashed.uuid in uuids(list(kind, []))
        refute trashed.uuid in uuids(list(kind, trashed: false))

        assert trashed.uuid in uuids(list(kind, trashed: true))
        refute live.uuid in uuids(list(kind, trashed: true))
      end

      test "the trash list is ordered by number, newest first", %{kind: kind} do
        {:ok, a} = trash(kind, draft!(kind), uuid())
        {:ok, b} = trash(kind, draft!(kind), uuid())

        listed = list(kind, trashed: true) |> Enum.filter(&(&1.uuid in [a.uuid, b.uuid]))
        assert Enum.map(listed, & &1.uuid) == [b.uuid, a.uuid]
      end

      test "the counter counts the trashed documents, legacy non-drafts included",
           %{kind: kind} do
        before_count = count_trashed(kind)
        draft!(kind)
        {:ok, _} = trash(kind, draft!(kind), uuid())
        [legacy | _] = non_drafts!(kind)
        force_trash!(kind, legacy)

        assert count_trashed(kind) == before_count + 2
        assert legacy.uuid in uuids(list(kind, trashed: true))
      end
    end

    describe "#{kind}: activity" do
      @describetag kind: kind

      test "a move to the trash logs trashed with the actor and trash_reason manual",
           %{kind: kind} do
        doc = draft!(kind)
        actor = uuid()
        {:ok, _} = trash(kind, doc, actor)

        assert [entry] = activity(kind, "trashed", doc.uuid)
        assert entry.module == "warehouse"
        assert entry.resource_type == resource_type(kind)
        assert entry.actor_uuid == actor
        assert entry.mode == "manual"
        assert entry.metadata["trash_reason"] == "manual"
        assert entry.metadata["number"] == to_string(doc.number)
        refute Map.has_key?(entry.metadata, "superseded_by_uuid")
      end

      test "a restore logs restored with the actor", %{kind: kind} do
        {:ok, trashed} = trash(kind, draft!(kind), uuid())
        actor = uuid()
        {:ok, _} = restore(kind, trashed, actor)

        assert [entry] = activity(kind, "restored", trashed.uuid)
        assert entry.resource_type == resource_type(kind)
        assert entry.actor_uuid == actor
        assert entry.metadata["number"] == to_string(trashed.number)
      end

      test "a refused move and a refused restore log nothing", %{kind: kind} do
        [non_draft | _] = non_drafts!(kind)
        assert {:error, :not_draft} = trash(kind, non_draft, uuid())
        assert activity(kind, "trashed", non_draft.uuid) == []

        live = draft!(kind)
        assert {:error, :not_deleted} = restore(kind, live, uuid())
        assert activity(kind, "restored", live.uuid) == []
      end

      test "the :inventory_activity_logging switch silences the entries", %{kind: kind} do
        Application.put_env(:phoenix_kit_warehouse, :inventory_activity_logging, false)

        on_exit(fn ->
          Application.delete_env(:phoenix_kit_warehouse, :inventory_activity_logging)
        end)

        {:ok, trashed} = trash(kind, draft!(kind), uuid())
        {:ok, _} = restore(kind, trashed, uuid())

        assert activity(kind, "trashed", trashed.uuid) == []
        assert activity(kind, "restored", trashed.uuid) == []
      end
    end
  end

  for kind <- @with_refs do
    describe "#{kind}: source refs of a trashed document" do
      @describetag kind: kind

      test "add_source_ref answers :deleted and writes nothing", %{kind: kind} do
        doc = draft!(kind)
        {:ok, _} = trash(kind, doc, uuid())

        assert {:error, :deleted} = add_ref(kind, doc, "sub_order", uuid())
        assert reload(kind, doc).source_refs == []
      end

      test "remove_source_ref answers :deleted and keeps the ref", %{kind: kind} do
        doc = draft!(kind)
        ref_uuid = uuid()
        {:ok, doc} = add_ref(kind, doc, "sub_order", ref_uuid)
        {:ok, _} = trash(kind, doc, uuid())

        assert {:error, :deleted} = remove_ref(kind, doc, "sub_order", ref_uuid)
        assert reload(kind, doc).source_refs == [%{"type" => "sub_order", "uuid" => ref_uuid}]
      end

      test "the refs of a live document, non-drafts included, still change", %{kind: kind} do
        [non_draft | _] = non_drafts!(kind)
        ref_uuid = uuid()

        assert {:ok, linked} = add_ref(kind, non_draft, "sub_order", ref_uuid)
        assert linked.source_refs == [%{"type" => "sub_order", "uuid" => ref_uuid}]

        assert {:ok, unlinked} = remove_ref(kind, linked, "sub_order", ref_uuid)
        assert unlinked.source_refs == []
      end

      test "an unregistered ref type is still refused first", %{kind: kind} do
        assert {:error, :invalid_ref_type} = add_ref(kind, draft!(kind), "nope", uuid())
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Kind-specific rules
  # ---------------------------------------------------------------------------

  describe "transfers" do
    test "in_transit, done and cancelled transfers each answer :not_draft" do
      for {status, transfer} <- transfers_by_status!() do
        assert {:error, :not_draft} = Transfers.soft_delete_transfer(transfer, uuid()),
               "#{status} was trashed"

        assert live?(:transfer, transfer)
      end
    end

    test "cancelling a trashed draft answers :deleted and leaves it a draft" do
      transfer = draft!(:transfer)
      {:ok, _} = trash(:transfer, transfer, uuid())

      assert {:error, :deleted} = Transfers.cancel_transfer(transfer, nil)
      assert reload(:transfer, transfer).status == "draft"
    end

    test "update_draft of a stale struct of a shipped transfer answers :not_draft" do
      stale = postable_draft!(:transfer)
      {:ok, _} = Transfers.ship_transfer(stale, nil)

      assert {:error, :not_draft} = Transfers.update_draft(stale, %{note: "late edit"})
      assert reload(:transfer, stale).note == nil
    end

    test "a legacy in-transit transfer in the trash can still be received" do
      item = uuid()
      shipped = shipped_transfer!(item, "3")
      force_trash!(:transfer, shipped)

      assert {:ok, %Transfer{status: "done"}} = Transfers.receive_transfer(shipped, nil)
      assert Decimal.equal?(qty(item, @destination_location), 3)
    end

    test "a legacy in-transit transfer in the trash can still be cancelled" do
      item = uuid()
      shipped = shipped_transfer!(item, "3")
      force_trash!(:transfer, shipped)

      assert {:ok, %Transfer{status: "cancelled"}} = Transfers.cancel_transfer(shipped, nil)
      assert Decimal.equal?(qty(item, @source_location), 10)
    end
  end

  describe "goods issues" do
    test "trashed keeps the issue reason under \"reason\" and puts trash_reason beside it" do
      issue = draft!(:goods_issue, %{reason: "sale"})
      {:ok, _} = GoodsIssues.soft_delete(issue, uuid())

      assert [entry] = activity(:goods_issue, "trashed", issue.uuid)
      assert entry.metadata["reason"] == "sale"
      assert entry.metadata["trash_reason"] == "manual"
    end

    test "importing into a trashed draft answers :deleted" do
      io = posted_internal_order!(uuid(), "10")
      issue = draft!(:goods_issue)
      {:ok, _} = trash(:goods_issue, issue, uuid())

      assert {:error, :deleted} = GoodsIssues.import_from_internal_orders(issue, [io.uuid], nil)
      assert reload(:goods_issue, issue).lines == []
    end
  end

  describe "goods receipts" do
    test "importing into a trashed draft answers :deleted" do
      so = posted_supplier_order!()
      receipt = draft!(:goods_receipt)
      {:ok, _} = trash(:goods_receipt, receipt, uuid())

      assert {:error, :deleted} =
               GoodsReceipts.import_from_supplier_orders(receipt, [so.uuid], nil)

      assert reload(:goods_receipt, receipt).lines == []
    end
  end

  describe "inventory documents" do
    test "the activity entries use the inventory_document resource and inventory actions" do
      doc = draft!(:inventory)
      {:ok, _} = Inventories.soft_delete_document(doc, uuid())
      {:ok, _} = Inventories.restore_document(reload(:inventory, doc), uuid())

      assert [%{resource_type: "inventory_document"}] =
               Activity.list(action: "warehouse.inventory.trashed", resource_uuid: doc.uuid).entries

      assert [%{resource_type: "inventory_document"}] =
               Activity.list(action: "warehouse.inventory.restored", resource_uuid: doc.uuid).entries
    end
  end

  describe "GoodsIssues.overcommitted_internal_orders/1" do
    test "a restored issue whose internal order was imported again meanwhile is reported" do
      item = uuid()
      io = posted_internal_order!(item, "10")

      {:ok, a} = GoodsIssues.import_from_internal_orders(draft!(:goods_issue), [io.uuid], nil)
      assert [%{"issued_quantity" => issued_a}] = a.lines
      assert Decimal.equal?(issued_a, 10)

      {:ok, a} = GoodsIssues.soft_delete(a, uuid())

      {:ok, b} = GoodsIssues.import_from_internal_orders(draft!(:goods_issue), [io.uuid], nil)
      assert [%{"issued_quantity" => issued_b}] = b.lines
      assert Decimal.equal?(issued_b, 10)

      {:ok, a} = GoodsIssues.restore_goods_issue(a, uuid())

      assert [%{uuid: overcommitted}] = GoodsIssues.overcommitted_internal_orders(a)
      assert overcommitted == io.uuid
    end

    test "is [] when the reserve does not exceed the internal order" do
      item = uuid()
      io = posted_internal_order!(item, "10")
      {:ok, a} = GoodsIssues.import_from_internal_orders(draft!(:goods_issue), [io.uuid], nil)
      {:ok, a} = GoodsIssues.soft_delete(a, uuid())
      {:ok, a} = GoodsIssues.restore_goods_issue(a, uuid())

      assert GoodsIssues.overcommitted_internal_orders(a) == []
    end

    test "counts posted issues as reserve too" do
      item = uuid()
      io = posted_internal_order!(item, "10")
      {:ok, a} = GoodsIssues.import_from_internal_orders(draft!(:goods_issue), [io.uuid], nil)
      {:ok, a} = GoodsIssues.soft_delete(a, uuid())

      {:ok, b} = GoodsIssues.import_from_internal_orders(draft!(:goods_issue), [io.uuid], nil)
      seed!(item, "20", @location)
      {:ok, _} = GoodsIssues.post_goods_issue(b, nil)

      {:ok, a} = GoodsIssues.restore_goods_issue(a, uuid())

      assert [%{uuid: overcommitted}] = GoodsIssues.overcommitted_internal_orders(a)
      assert overcommitted == io.uuid
    end

    test "leaves out an internal order that is not posted, even when it is exceeded" do
      item = uuid()
      held = %{item => "15"}

      {:ok, draft_io} =
        InternalOrders.create_internal_order(%{
          location_uuid: @location,
          lines: [line(item, "required_quantity", "10")]
        })

      posted_io = posted_internal_order!(item, "10")

      issue =
        draft!(:goods_issue, %{
          source_refs: [
            %{"type" => "internal_order", "uuid" => draft_io.uuid, "lines" => held},
            %{"type" => "internal_order", "uuid" => posted_io.uuid, "lines" => held}
          ]
        })

      assert [%{uuid: reported}] = GoodsIssues.overcommitted_internal_orders(issue)
      assert reported == posted_io.uuid
    end

    test "leaves out trashed internal orders and issues without internal order refs" do
      item = uuid()
      io = posted_internal_order!(item, "10")
      {:ok, a} = GoodsIssues.import_from_internal_orders(draft!(:goods_issue), [io.uuid], nil)
      {:ok, a} = GoodsIssues.soft_delete(a, uuid())
      {:ok, _b} = GoodsIssues.import_from_internal_orders(draft!(:goods_issue), [io.uuid], nil)
      {:ok, a} = GoodsIssues.restore_goods_issue(a, uuid())

      force_trash_internal_order!(io)
      assert GoodsIssues.overcommitted_internal_orders(a) == []

      assert GoodsIssues.overcommitted_internal_orders(draft!(:goods_issue)) == []
    end
  end

  describe "DraftTrash.trash_one/3 and restore_one/2" do
    test "the database status decides, not the caller's struct" do
      receipt = postable_draft!(:goods_receipt)
      {:ok, _} = GoodsReceipts.post_goods_receipt(receipt, nil)

      assert {:error, :not_draft} = DraftTrash.trash_one(GoodsReceipt, receipt.uuid, uuid())
      assert live?(:goods_receipt, receipt)
    end

    test "returns the updated row and writes no activity" do
      doc = draft!(:inventory)

      assert {:ok, %InventoryDocument{deleted_at: %DateTime{}}} =
               DraftTrash.trash_one(InventoryDocument, doc.uuid, nil)

      assert {:ok, %InventoryDocument{deleted_at: nil}} =
               DraftTrash.restore_one(InventoryDocument, doc.uuid)

      assert activity(:inventory, "trashed", doc.uuid) == []
      assert activity(:inventory, "restored", doc.uuid) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Kind table
  # ---------------------------------------------------------------------------

  defp schema(:goods_receipt), do: GoodsReceipt
  defp schema(:goods_issue), do: GoodsIssue
  defp schema(:inventory), do: InventoryDocument
  defp schema(:transfer), do: Transfer

  defp resource_type(:goods_receipt), do: "goods_receipt"
  defp resource_type(:goods_issue), do: "goods_issue"
  defp resource_type(:inventory), do: "inventory_document"
  defp resource_type(:transfer), do: "transfer"

  defp action_prefix(:goods_receipt), do: "warehouse.goods_receipt"
  defp action_prefix(:goods_issue), do: "warehouse.goods_issue"
  defp action_prefix(:inventory), do: "warehouse.inventory"
  defp action_prefix(:transfer), do: "warehouse.transfer"

  defp draft!(kind, attrs \\ %{})

  defp draft!(:goods_receipt, attrs) do
    {:ok, doc} = GoodsReceipts.create_goods_receipt(Map.merge(%{location_uuid: @location}, attrs))
    doc
  end

  defp draft!(:goods_issue, attrs) do
    {:ok, doc} = GoodsIssues.create_goods_issue(Map.merge(%{location_uuid: @location}, attrs))
    doc
  end

  defp draft!(:inventory, attrs) do
    {:ok, doc} = Inventories.create_draft(Map.merge(%{location_uuid: @location}, attrs))
    doc
  end

  defp draft!(:transfer, attrs) do
    base = %{
      source_location_uuid: @source_location,
      destination_location_uuid: @destination_location
    }

    {:ok, doc} = Transfers.create_transfer(Map.merge(base, attrs))
    doc
  end

  # A draft with one line that moves stock when posted (or shipped).
  defp postable_draft!(:goods_receipt) do
    draft!(:goods_receipt, %{lines: [line(uuid(), "received_quantity", "4")]})
  end

  defp postable_draft!(:goods_issue) do
    item = uuid()
    seed!(item, "10", @location)
    draft!(:goods_issue, %{lines: [line(item, "issued_quantity", "4")]})
  end

  defp postable_draft!(:inventory) do
    draft!(:inventory, %{lines: [line(uuid(), "counted_quantity", "4")]})
  end

  defp postable_draft!(:transfer) do
    item = uuid()
    seed!(item, "10", @source_location)
    draft!(:transfer, %{lines: [line(item, "transfer_quantity", "4")]})
  end

  defp post!(kind, doc) do
    {:ok, posted} = post(kind, doc)
    posted
  end

  # Every status of the kind that is not a draft, one live document each.
  defp non_drafts!(:transfer), do: transfers_by_status!() |> Enum.map(&elem(&1, 1))
  defp non_drafts!(kind), do: [post!(kind, postable_draft!(kind))]

  defp transfers_by_status! do
    {:ok, in_transit} = Transfers.ship_transfer(postable_draft!(:transfer), nil)
    {:ok, shipped} = Transfers.ship_transfer(postable_draft!(:transfer), nil)
    {:ok, done} = Transfers.receive_transfer(shipped, nil)
    {:ok, cancelled} = Transfers.cancel_transfer(draft!(:transfer), nil)

    [in_transit: in_transit, done: done, cancelled: cancelled]
  end

  defp shipped_transfer!(item, quantity) do
    seed!(item, "10", @source_location)
    transfer = draft!(:transfer, %{lines: [line(item, "transfer_quantity", quantity)]})
    {:ok, shipped} = Transfers.ship_transfer(transfer, nil)
    shipped
  end

  defp trash(:goods_receipt, doc, actor), do: GoodsReceipts.soft_delete(doc, actor)
  defp trash(:goods_issue, doc, actor), do: GoodsIssues.soft_delete(doc, actor)
  defp trash(:inventory, doc, actor), do: Inventories.soft_delete_document(doc, actor)
  defp trash(:transfer, doc, actor), do: Transfers.soft_delete_transfer(doc, actor)

  defp restore(:goods_receipt, doc, actor), do: GoodsReceipts.restore_goods_receipt(doc, actor)
  defp restore(:goods_issue, doc, actor), do: GoodsIssues.restore_goods_issue(doc, actor)
  defp restore(:inventory, doc, actor), do: Inventories.restore_document(doc, actor)
  defp restore(:transfer, doc, actor), do: Transfers.restore_transfer(doc, actor)

  defp edit(:goods_receipt, doc, attrs), do: GoodsReceipts.update_draft(doc, attrs)
  defp edit(:goods_issue, doc, attrs), do: GoodsIssues.update_draft(doc, attrs)
  defp edit(:inventory, doc, attrs), do: Inventories.update_draft(doc, attrs)
  defp edit(:transfer, doc, attrs), do: Transfers.update_draft(doc, attrs)

  defp post(:goods_receipt, doc), do: GoodsReceipts.post_goods_receipt(doc, nil)
  defp post(:goods_issue, doc), do: GoodsIssues.post_goods_issue(doc, nil)
  defp post(:inventory, doc), do: Inventories.post_document(doc, nil)
  defp post(:transfer, doc), do: Transfers.ship_transfer(doc, nil)

  defp list(:goods_receipt, opts), do: GoodsReceipts.list_goods_receipts(opts)
  defp list(:goods_issue, opts), do: GoodsIssues.list_goods_issues(opts)
  defp list(:inventory, opts), do: Inventories.list_documents(opts)
  defp list(:transfer, opts), do: Transfers.list_transfers(opts)

  defp count_trashed(:goods_receipt), do: GoodsReceipts.count_trashed_goods_receipts()
  defp count_trashed(:goods_issue), do: GoodsIssues.count_trashed_goods_issues()
  defp count_trashed(:inventory), do: Inventories.count_trashed_documents()
  defp count_trashed(:transfer), do: Transfers.count_trashed_transfers()

  defp add_ref(:goods_receipt, doc, type, id), do: GoodsReceipts.add_source_ref(doc, type, id)
  defp add_ref(:goods_issue, doc, type, id), do: GoodsIssues.add_source_ref(doc, type, id)
  defp add_ref(:transfer, doc, type, id), do: Transfers.add_source_ref(doc, type, id)

  defp remove_ref(:goods_receipt, doc, type, id),
    do: GoodsReceipts.remove_source_ref(doc, type, id)

  defp remove_ref(:goods_issue, doc, type, id), do: GoodsIssues.remove_source_ref(doc, type, id)
  defp remove_ref(:transfer, doc, type, id), do: Transfers.remove_source_ref(doc, type, id)

  # The stock rows a posting of `doc` would move, as plain values.
  defp stock_snapshot(:transfer, doc) do
    for line <- doc.lines, location <- [@source_location, @destination_location] do
      {line["item_uuid"], location, qty(line["item_uuid"], location)}
    end
  end

  defp stock_snapshot(_kind, doc) do
    for line <- doc.lines, do: {line["item_uuid"], qty(line["item_uuid"], @location)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp uuid, do: Ecto.UUID.generate()

  defp uuids(docs), do: Enum.map(docs, & &1.uuid)

  defp reload(kind, doc), do: Repo.get!(schema(kind), doc.uuid)

  defp live?(kind, doc), do: is_nil(reload(kind, doc).deleted_at)

  defp activity(kind, verb, resource_uuid) do
    Activity.list(action: "#{action_prefix(kind)}.#{verb}", resource_uuid: resource_uuid).entries
  end

  defp line(item_uuid, quantity_key, quantity) do
    %{
      "item_uuid" => item_uuid,
      "name" => "Material",
      "unit" => "pcs",
      quantity_key => quantity
    }
  end

  defp seed!(item_uuid, quantity, location) do
    {:ok, _} =
      StockLedger.upsert_quantity(item_uuid, Decimal.new(quantity), location_uuid: location)
  end

  defp qty(item_uuid, location) do
    StockLedger.get_quantity(item_uuid, location)
  end

  # Old code could trash any status with a plain update; the fixtures of the
  # legacy rows do the same.
  defp force_trash!(kind, doc) do
    {1, _} =
      Repo.update_all(
        from(d in schema(kind), where: d.uuid == ^doc.uuid),
        set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )
  end

  defp set_updated_at(kind, doc, at) do
    {1, _} =
      Repo.update_all(from(d in schema(kind), where: d.uuid == ^doc.uuid),
        set: [updated_at: at]
      )
  end

  defp posted_internal_order!(item_uuid, quantity) do
    {:ok, io} =
      InternalOrders.create_internal_order(%{
        location_uuid: @location,
        lines: [line(item_uuid, "required_quantity", quantity)]
      })

    {:ok, posted} = InternalOrders.post_internal_order(io, nil)
    posted
  end

  defp force_trash_internal_order!(io) do
    {1, _} =
      Repo.update_all(
        from(o in PhoenixKitWarehouse.InternalOrder, where: o.uuid == ^io.uuid),
        set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )
  end

  defp posted_supplier_order! do
    {:ok, so} =
      SupplierOrders.create_supplier_order(%{
        location_uuid: @location,
        supplier_uuid: uuid(),
        lines: [line(uuid(), "ordered_quantity", "5")]
      })

    {:ok, posted} = SupplierOrders.post_supplier_order(so, nil)
    posted
  end
end
