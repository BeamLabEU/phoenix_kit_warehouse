defmodule PhoenixKitWarehouse.SupplierOrdersOneDraftTest do
  @moduledoc """
  The "one draft per source" rule of `SupplierOrders`: the `supersede_drafts`
  option of `generate_from_internal_order/3`, `restore_supplier_order/3`, the
  `deleted_at` guard of the draft-only writes and the activity entries of a
  move to the trash. The unit is the pair (internal order, supplier).

  Everything here runs in the sandbox (one connection). What needs two real
  connections (the race with posting, the serialisation by the advisory lock)
  lives in `SupplierOrdersOneDraftConcurrencyTest`.
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.SupplierOrders

  @location "00000000-0000-0000-0000-000000000001"

  defp uuid, do: Ecto.UUID.generate()

  defp unique, do: System.unique_integer([:positive])

  # A supplier and an item that resolves to it alone (via the manufacturer).
  defp supplier_with_item! do
    {:ok, supplier} = Catalogue.create_supplier(%{name: "Supplier #{unique()}", status: "active"})

    {:ok, mfr} = Catalogue.create_manufacturer(%{name: "Mfr #{unique()}", status: "active"})
    Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Cat #{unique()}", status: "active"})

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Item #{unique()}",
        catalogue_uuid: catalogue.uuid,
        manufacturer_uuid: mfr.uuid,
        status: "active"
      })

    %{supplier: supplier, item: item}
  end

  defp io_line(item, qty) do
    %{
      "item_uuid" => item.uuid,
      "name" => item.name,
      "sku" => item.sku || "",
      "unit" => item.unit || "piece",
      "catalogue_uuid" => item.catalogue_uuid,
      "category_uuid" => item.category_uuid,
      "required_quantity" => qty
    }
  end

  defp posted_io!(items) do
    {:ok, io} =
      InternalOrders.create_internal_order(%{
        location_uuid: @location,
        lines: Enum.map(items, &io_line(&1, "10"))
      })

    {:ok, posted} = InternalOrders.post_internal_order(io, nil)
    posted
  end

  defp generate!(io, actor \\ uuid(), opts \\ []) do
    {:ok, result} = SupplierOrders.generate_from_internal_order(io, actor, opts)
    result
  end

  defp insert!(attrs) do
    {:ok, so} =
      SupplierOrders.create_supplier_order(Map.merge(%{location_uuid: @location}, attrs))

    so
  end

  defp trashed!(attrs) do
    {:ok, trashed} = attrs |> insert!() |> SupplierOrders.soft_delete_supplier_order(uuid())
    trashed
  end

  defp reload(%SupplierOrder{uuid: uuid}), do: SupplierOrders.get_supplier_order!(uuid)

  defp live?(order), do: is_nil(reload(order).deleted_at)

  defp io_uuid! do
    {:ok, io} = InternalOrders.create_internal_order(%{location_uuid: @location})
    io.uuid
  end

  defp io_ref(io_uuid), do: %{"type" => "internal_order", "uuid" => io_uuid}

  defp activity(action, resource_uuid) do
    Activity.list(action: action, resource_uuid: resource_uuid).entries
  end

  defp live_for(io, supplier) do
    SupplierOrder
    |> where([o], o.internal_order_uuid == ^io.uuid and o.supplier_uuid == ^supplier.uuid)
    |> where([o], is_nil(o.deleted_at))
    |> Repo.all()
  end

  describe "generate_from_internal_order/3 with supersede_drafts" do
    test "the second generation trashes the first drafts, one live draft per supplier remains" do
      %{supplier: sup_a, item: item_a} = supplier_with_item!()
      %{supplier: sup_b, item: item_b} = supplier_with_item!()
      io = posted_io!([item_a, item_b])
      actor = uuid()

      first = generate!(io, uuid(), supersede_drafts: true)
      assert first.superseded == []
      assert length(first.supplier_orders) == 2

      second = generate!(io, actor, supersede_drafts: true)

      assert Enum.sort(Enum.map(second.superseded, & &1.uuid)) ==
               Enum.sort(Enum.map(first.supplier_orders, & &1.uuid))

      assert Enum.all?(second.superseded, &(&1.deleted_by_uuid == actor))
      assert Enum.all?(second.superseded, &match?(%DateTime{}, &1.deleted_at))

      for old <- first.supplier_orders, do: refute(live?(old))
      for new <- second.supplier_orders, do: assert(live?(new))

      assert [live_a] = live_for(io, sup_a)
      assert [live_b] = live_for(io, sup_b)

      assert Enum.sort([live_a.uuid, live_b.uuid]) ==
               Enum.sort(Enum.map(second.supplier_orders, & &1.uuid))
    end

    test "the previous result keys stay and the new key is additive" do
      %{item: item} = supplier_with_item!()
      io = posted_io!([item])

      assert {:ok, %{supplier_orders: [_], unassigned_lines: [], superseded: []}} =
               SupplierOrders.generate_from_internal_order(io, uuid(), supersede_drafts: true)
    end

    test "without the option the old drafts stay live and nothing is reported" do
      %{supplier: sup, item: item} = supplier_with_item!()
      io = posted_io!([item])

      first = generate!(io)
      second = generate!(io)
      third = generate!(io, uuid(), supersede_drafts: false)

      assert second.superseded == []
      assert third.superseded == []
      assert length(live_for(io, sup)) == 3

      for so <- first.supplier_orders ++ second.supplier_orders, do: assert(live?(so))
    end

    test "a supplier the new generation did not touch keeps its draft" do
      %{supplier: sup_a, item: item_a} = supplier_with_item!()
      %{item: item_b} = supplier_with_item!()
      io = posted_io!([item_a, item_b])

      [old_a] = generate_for(io, item_a, supersede_drafts: true)
      [old_b] = generate_for(io, item_b, supersede_drafts: true)

      # The stock now covers the second supplier's item completely.
      StockLedger.upsert_quantity(item_b.uuid, Decimal.new("100"), location_uuid: @location)

      result = generate!(io, uuid(), supersede_drafts: true)

      assert [new_a] = result.supplier_orders
      assert new_a.supplier_uuid == sup_a.uuid
      assert Enum.map(result.superseded, & &1.uuid) == [old_a.uuid]
      refute live?(old_a)
      assert live?(old_b)
    end

    test "a generation that creates nothing trashes nothing" do
      %{item: item} = supplier_with_item!()
      io = posted_io!([item])
      [old] = generate!(io, uuid(), supersede_drafts: true).supplier_orders

      StockLedger.upsert_quantity(item.uuid, Decimal.new("100"), location_uuid: @location)

      assert {:ok, %{supplier_orders: [], superseded: []}} =
               SupplierOrders.generate_from_internal_order(io, uuid(), supersede_drafts: true)

      assert live?(old)
    end

    test "a posted supplier order of the same pair is never touched" do
      %{supplier: sup, item: item} = supplier_with_item!()
      io = posted_io!([item])
      [draft] = generate!(io, uuid(), supersede_drafts: true).supplier_orders
      {:ok, posted} = SupplierOrders.post_supplier_order(draft, nil)

      result = generate!(io, uuid(), supersede_drafts: true)

      assert result.superseded == []
      assert reload(posted).status == "posted"
      assert live?(posted)
      assert length(live_for(io, sup)) == 2
    end

    test "an imported supplier order that refers to another internal order is left alone" do
      %{supplier: sup, item: item} = supplier_with_item!()
      io = posted_io!([item])
      other_io = uuid()

      imported =
        insert!(%{
          supplier_uuid: sup.uuid,
          internal_order_uuid: io.uuid,
          source_refs: [io_ref(other_io), io_ref(io.uuid)]
        })

      only_other =
        insert!(%{
          supplier_uuid: sup.uuid,
          internal_order_uuid: io.uuid,
          source_refs: [io_ref(other_io)]
        })

      odd_ref =
        insert!(%{
          supplier_uuid: sup.uuid,
          internal_order_uuid: io.uuid,
          source_refs: [%{"type" => "something_else", "uuid" => io.uuid}]
        })

      result = generate!(io, uuid(), supersede_drafts: true)

      assert result.superseded == []
      for so <- [imported, only_other, odd_ref], do: assert(live?(so))
    end

    test "a draft imported from this internal order alone, or with no refs, goes" do
      %{supplier: sup, item: item} = supplier_with_item!()
      io = posted_io!([item])

      own_ref =
        insert!(%{
          supplier_uuid: sup.uuid,
          internal_order_uuid: io.uuid,
          source_refs: [Map.put(io_ref(io.uuid), "lines", %{})]
        })

      no_refs = insert!(%{supplier_uuid: sup.uuid, internal_order_uuid: io.uuid})

      result = generate!(io, uuid(), supersede_drafts: true)

      assert Enum.sort(Enum.map(result.superseded, & &1.uuid)) ==
               Enum.sort([own_ref.uuid, no_refs.uuid])
    end

    test "drafts of another internal order, another supplier or none are left alone" do
      %{supplier: sup, item: item} = supplier_with_item!()
      other_sup = insert_supplier!()
      io = posted_io!([item])
      other_io = posted_io!([item])

      elsewhere = insert!(%{supplier_uuid: sup.uuid, internal_order_uuid: other_io.uuid})
      other_supplier = insert!(%{supplier_uuid: other_sup.uuid, internal_order_uuid: io.uuid})
      no_supplier = insert!(%{internal_order_uuid: io.uuid})
      no_order = insert!(%{supplier_uuid: sup.uuid})

      result = generate!(io, uuid(), supersede_drafts: true)

      assert result.superseded == []
      for so <- [elsewhere, other_supplier, no_supplier, no_order], do: assert(live?(so))
    end

    test "a draft that is already in the trash is not reported again" do
      %{supplier: sup, item: item} = supplier_with_item!()
      io = posted_io!([item])
      gone = trashed!(%{supplier_uuid: sup.uuid, internal_order_uuid: io.uuid})

      result = generate!(io, uuid(), supersede_drafts: true)

      assert result.superseded == []
      assert reload(gone).deleted_by_uuid == gone.deleted_by_uuid
    end

    test "activity trashed is written with the reason and the order that took its place" do
      %{supplier: sup, item: item} = supplier_with_item!()
      io = posted_io!([item])
      actor = uuid()

      [old] = generate!(io, uuid(), supersede_drafts: true).supplier_orders
      %{supplier_orders: [new]} = generate!(io, actor, supersede_drafts: true)

      assert new.supplier_uuid == sup.uuid

      assert [entry] = activity("warehouse.supplier_order.trashed", old.uuid)
      assert entry.resource_type == "supplier_order"
      assert entry.actor_uuid == actor
      assert entry.metadata["trash_reason"] == "superseded"
      assert entry.metadata["superseded_by_uuid"] == new.uuid
      assert entry.metadata["number"] == to_string(old.number)
    end
  end

  defp insert_supplier! do
    {:ok, supplier} = Catalogue.create_supplier(%{name: "Supplier #{unique()}", status: "active"})
    supplier
  end

  # Runs the generation on a copy of the internal order that only holds the
  # line of one item, so only that item's supplier gets a draft.
  defp generate_for(io, item, opts) do
    lines = Enum.filter(io.lines, &(&1["item_uuid"] == item.uuid))
    generate!(%{io | lines: lines}, uuid(), opts).supplier_orders
  end

  describe "restore_supplier_order/3" do
    test "brings a trashed draft back" do
      actor = uuid()
      trashed = trashed!(%{supplier_uuid: uuid(), internal_order_uuid: io_uuid!()})

      assert {:ok, %{order: restored, superseded: []}} =
               SupplierOrders.restore_supplier_order(trashed, actor)

      assert restored.deleted_at == nil
      assert restored.deleted_by_uuid == nil
      assert live?(trashed)
      assert [entry] = activity("warehouse.supplier_order.restored", trashed.uuid)
      assert entry.actor_uuid == actor
    end

    test "a live order is :not_deleted" do
      live = insert!(%{supplier_uuid: uuid()})
      assert {:error, :not_deleted} = SupplierOrders.restore_supplier_order(live, uuid())
    end

    test "a trashed posted order (legacy) is :not_draft and stays in the trash" do
      so = insert!(%{supplier_uuid: uuid(), lines: [%{"item_uuid" => uuid()}]})
      {:ok, posted} = SupplierOrders.post_supplier_order(so, nil)

      from(o in SupplierOrder, where: o.uuid == ^posted.uuid)
      |> Repo.update_all(set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)])

      assert {:error, :not_draft} =
               SupplierOrders.restore_supplier_order(posted, uuid(), swap: true)

      refute live?(posted)
    end

    test "an unknown order is :not_found" do
      ghost = %SupplierOrder{uuid: uuid(), status: "draft"}
      assert {:error, :not_found} = SupplierOrders.restore_supplier_order(ghost, uuid())
    end

    test "with swap the live drafts of the same pair go, the restored one stays" do
      io = io_uuid!()
      sup = uuid()
      actor = uuid()

      trashed = trashed!(%{supplier_uuid: sup, internal_order_uuid: io})
      rival_a = insert!(%{supplier_uuid: sup, internal_order_uuid: io})
      rival_b = insert!(%{supplier_uuid: sup, internal_order_uuid: io, source_refs: [io_ref(io)]})

      assert {:ok, %{order: restored, superseded: superseded}} =
               SupplierOrders.restore_supplier_order(trashed, actor, swap: true)

      assert Enum.sort(Enum.map(superseded, & &1.uuid)) == Enum.sort([rival_a.uuid, rival_b.uuid])
      assert Enum.all?(superseded, &(&1.deleted_by_uuid == actor))
      assert restored.uuid == trashed.uuid
      assert live?(trashed)
      refute live?(rival_a)
      refute live?(rival_b)

      assert [entry] = activity("warehouse.supplier_order.trashed", rival_a.uuid)
      assert entry.metadata["trash_reason"] == "restore_swap"
      assert entry.metadata["superseded_by_uuid"] == trashed.uuid
    end

    test "with swap a posted draft, a combined one and other pairs stay" do
      io = io_uuid!()
      sup = uuid()
      trashed = trashed!(%{supplier_uuid: sup, internal_order_uuid: io})

      {:ok, posted} =
        %{supplier_uuid: sup, internal_order_uuid: io, lines: [%{"item_uuid" => uuid()}]}
        |> insert!()
        |> SupplierOrders.post_supplier_order(nil)

      combined =
        insert!(%{supplier_uuid: sup, internal_order_uuid: io, source_refs: [io_ref(uuid())]})

      other_supplier = insert!(%{supplier_uuid: uuid(), internal_order_uuid: io})
      other_io = insert!(%{supplier_uuid: sup, internal_order_uuid: io_uuid!()})

      assert {:ok, %{superseded: []}} =
               SupplierOrders.restore_supplier_order(trashed, uuid(), swap: true)

      for so <- [posted, combined, other_supplier, other_io, trashed], do: assert(live?(so))
    end

    test "without swap (the default or swap: false) nothing else is trashed" do
      io = io_uuid!()
      sup = uuid()
      rival = insert!(%{supplier_uuid: sup, internal_order_uuid: io})

      first = trashed!(%{supplier_uuid: sup, internal_order_uuid: io})
      second = trashed!(%{supplier_uuid: sup, internal_order_uuid: io})

      assert {:ok, %{superseded: []}} = SupplierOrders.restore_supplier_order(first, uuid())

      assert {:ok, %{superseded: []}} =
               SupplierOrders.restore_supplier_order(second, uuid(), swap: false)

      for so <- [rival, first, second], do: assert(live?(so))
    end

    test "a combined draft is restored without a swap even when swap is asked" do
      io = io_uuid!()
      sup = uuid()
      rival = insert!(%{supplier_uuid: sup, internal_order_uuid: io})

      combined =
        trashed!(%{
          supplier_uuid: sup,
          internal_order_uuid: io,
          source_refs: [io_ref(io), io_ref(uuid())]
        })

      assert {:ok, %{superseded: []}} =
               SupplierOrders.restore_supplier_order(combined, uuid(), swap: true)

      assert live?(rival)
      assert live?(combined)
    end

    test "a draft without a supplier or an internal order is restored without a swap" do
      io = io_uuid!()
      rival = insert!(%{internal_order_uuid: io})
      trashed = trashed!(%{internal_order_uuid: io})

      assert {:ok, %{superseded: []}} =
               SupplierOrders.restore_supplier_order(trashed, uuid(), swap: true)

      assert live?(rival)
    end
  end

  describe "writes on a trashed supplier order" do
    test "update_draft and post_supplier_order answer :deleted" do
      trashed = trashed!(%{supplier_uuid: uuid(), lines: [%{"item_uuid" => uuid()}]})

      assert {:error, :deleted} = SupplierOrders.update_draft(trashed, %{note: "late"})
      assert {:error, :deleted} = SupplierOrders.post_supplier_order(trashed, nil)

      reloaded = reload(trashed)
      assert reloaded.status == "draft"
      assert reloaded.note == nil
    end

    test "add_source_ref answers :deleted and writes nothing" do
      trashed = trashed!(%{supplier_uuid: uuid()})

      assert {:error, :deleted} = SupplierOrders.add_source_ref(trashed, "internal_order", uuid())
      assert reload(trashed).source_refs == []
    end

    test "add_source_ref and remove_source_ref look at the row, not at the struct" do
      source = io_ref(io_uuid!())
      so = insert!(%{supplier_uuid: uuid(), source_refs: [source]})
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(so, nil)

      assert {:error, :deleted} = SupplierOrders.add_source_ref(so, "internal_order", uuid())

      assert {:error, :deleted} =
               SupplierOrders.remove_source_ref(so, "internal_order", source["uuid"])

      assert reload(so).source_refs == [source]
    end

    test "remove_source_ref answers :deleted and keeps the ref" do
      source = io_ref(io_uuid!())
      trashed = trashed!(%{supplier_uuid: uuid(), source_refs: [source]})

      assert {:error, :deleted} =
               SupplierOrders.remove_source_ref(trashed, "internal_order", source["uuid"])

      assert reload(trashed).source_refs == [source]
    end

    test "the links of a live order, posted ones included, still change" do
      source = io_ref(io_uuid!())
      so = insert!(%{supplier_uuid: uuid(), lines: [%{"item_uuid" => uuid()}]})
      {:ok, posted} = SupplierOrders.post_supplier_order(so, nil)

      assert {:ok, linked} =
               SupplierOrders.add_source_ref(posted, "internal_order", source["uuid"])

      assert linked.source_refs == [source]

      assert {:ok, unlinked} =
               SupplierOrders.remove_source_ref(linked, "internal_order", source["uuid"])

      assert unlinked.source_refs == []
    end

    test "a posted order still answers :not_draft" do
      so = insert!(%{supplier_uuid: uuid(), lines: [%{"item_uuid" => uuid()}]})
      {:ok, posted} = SupplierOrders.post_supplier_order(so, nil)

      assert {:error, :not_draft} = SupplierOrders.update_draft(posted, %{note: "x"})
      assert {:error, :not_draft} = SupplierOrders.post_supplier_order(so, nil)
    end

    test "an import into a trashed draft answers :deleted" do
      trashed = trashed!(%{supplier_uuid: uuid()})

      assert {:error, :deleted} =
               SupplierOrders.import_from_internal_orders(trashed, [uuid()], uuid())
    end
  end

  describe "soft_delete_supplier_order/2" do
    test "trashes a draft, records the actor and logs a manual trashed activity" do
      actor = uuid()
      so = insert!(%{supplier_uuid: uuid()})

      assert {:ok, trashed} = SupplierOrders.soft_delete_supplier_order(so, actor)
      assert trashed.deleted_by_uuid == actor
      refute live?(so)

      assert [entry] = activity("warehouse.supplier_order.trashed", so.uuid)
      assert entry.actor_uuid == actor
      assert entry.metadata["trash_reason"] == "manual"
      refute Map.has_key?(entry.metadata, "superseded_by_uuid")
    end

    test "a draft posted elsewhere is not trashed from a stale struct" do
      so = insert!(%{supplier_uuid: uuid(), lines: [%{"item_uuid" => uuid()}]})
      {:ok, _posted} = SupplierOrders.post_supplier_order(so, nil)

      assert {:error, :not_draft} = SupplierOrders.soft_delete_supplier_order(so, uuid())
      assert live?(so)
      assert activity("warehouse.supplier_order.trashed", so.uuid) == []
    end

    test "an order already in the trash answers :deleted and keeps its first actor" do
      first_actor = uuid()
      so = insert!(%{supplier_uuid: uuid()})
      {:ok, trashed} = SupplierOrders.soft_delete_supplier_order(so, first_actor)

      assert {:error, :deleted} = SupplierOrders.soft_delete_supplier_order(so, uuid())
      assert reload(trashed).deleted_by_uuid == first_actor
    end

    test "a row that no longer exists answers :not_found" do
      ghost = %SupplierOrder{uuid: uuid(), status: "draft"}
      assert {:error, :not_found} = SupplierOrders.soft_delete_supplier_order(ghost, uuid())
    end

    test "a posted struct answers :not_draft" do
      assert {:error, :not_draft} =
               SupplierOrders.soft_delete_supplier_order(%SupplierOrder{status: "posted"}, uuid())
    end
  end
end
