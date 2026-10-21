defmodule PhoenixKitWarehouse.InternalOrdersOneDraftTest do
  @moduledoc """
  The "one draft per source" rule of `InternalOrders`: `replace_draft_for_source/3`,
  `list_for_source/2`, `multi_source?/1`, `restore_internal_order/3`, the
  `deleted_at` guard of the draft-only writes and the activity entries of a
  move to the trash.

  Everything here runs in the sandbox (one connection). What needs two real
  connections (the race with posting, the serialisation by the advisory lock)
  lives in `InternalOrdersOneDraftConcurrencyTest`.
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Test.FakeOrderSources

  @location "00000000-0000-0000-0000-000000000001"

  setup do
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
      FakeOrderSources.order_kind(),
      FakeOrderSources.sub_order_kind()
    ])

    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)
    :ok
  end

  defp uuid, do: Ecto.UUID.generate()

  defp ref(type, uuid), do: %{"type" => type, "uuid" => uuid}

  defp lines do
    [
      %{
        "item_uuid" => uuid(),
        "name" => "Screw M6",
        "unit" => "pcs",
        "required_quantity" => "10"
      }
    ]
  end

  defp replace!(source_ref, actor \\ uuid()) do
    {:ok, result} =
      InternalOrders.replace_draft_for_source(lines(), source_ref,
        created_by_uuid: actor,
        location_uuid: @location
      )

    result
  end

  defp insert!(attrs) do
    {:ok, order} =
      InternalOrders.create_internal_order(Map.merge(%{location_uuid: @location}, attrs))

    order
  end

  defp trashed!(source) do
    order = insert!(%{source_refs: [source]})
    {:ok, trashed} = InternalOrders.soft_delete_internal_order(order, uuid())
    trashed
  end

  defp reload(%InternalOrder{uuid: uuid}), do: InternalOrders.get_internal_order!(uuid)

  defp live?(order), do: is_nil(reload(order).deleted_at)

  defp activity(action, resource_uuid) do
    Activity.list(action: action, resource_uuid: resource_uuid).entries
  end

  describe "replace_draft_for_source/3" do
    test "the second call for the same source trashes the first draft" do
      source = ref("sub_order", uuid())
      actor = uuid()

      %{order: first, superseded: []} = replace!(source)
      %{order: second, superseded: superseded} = replace!(source, actor)

      assert Enum.map(superseded, & &1.uuid) == [first.uuid]
      assert [%{deleted_by_uuid: ^actor}] = superseded
      assert [%{deleted_at: %DateTime{}}] = superseded

      assert live?(second)
      refute live?(first)
      assert reload(first).deleted_by_uuid == actor
      assert [live] = InternalOrders.list_for_source("sub_order", source["uuid"])
      assert live.uuid == second.uuid
    end

    test "repeated calls leave exactly one live draft" do
      source = ref("sub_order", uuid())

      for _ <- 1..4, do: replace!(source)

      assert [%InternalOrder{status: "draft"}] =
               InternalOrders.list_for_source("sub_order", source["uuid"])
    end

    test "the new draft is built like create/3 does" do
      source = ref("sub_order", uuid())
      creator = uuid()

      assert {:ok, %{order: order, superseded: []}} =
               InternalOrders.replace_draft_for_source(lines(), source,
                 created_by_uuid: creator,
                 location_uuid: @location
               )

      assert order.status == "draft"
      assert order.source_refs == [source]
      assert order.created_by_uuid == creator
      assert order.location_uuid == @location
      assert [%{"required_quantity" => "10"}] = order.lines
    end

    test "a posted internal order of the same source is never touched" do
      source = ref("sub_order", uuid())
      %{order: draft} = replace!(source)
      {:ok, posted} = InternalOrders.post_internal_order(draft, nil)

      %{order: new, superseded: superseded} = replace!(source)

      assert superseded == []
      assert reload(posted).status == "posted"
      assert live?(posted)
      assert live?(new)
    end

    test "a combined draft (several sources) is left alone" do
      source = ref("sub_order", uuid())
      other = ref("sub_order", uuid())
      combined = insert!(%{source_refs: [source, other]})

      %{superseded: superseded} = replace!(source)

      assert superseded == []
      assert live?(combined)
    end

    test "a combined draft whose other ref has an unreadable shape is still left alone" do
      source = ref("sub_order", uuid())
      odd = insert!(%{source_refs: [source, %{"note" => "hand written"}]})

      assert %{superseded: []} = replace!(source)
      assert live?(odd)
    end

    test "a draft of another source and one of another type with the same uuid are left alone" do
      source = ref("sub_order", uuid())
      another = insert!(%{source_refs: [ref("sub_order", uuid())]})
      same_uuid_other_type = insert!(%{source_refs: [ref("order", source["uuid"])]})
      no_source = insert!(%{source_refs: []})

      assert %{superseded: []} = replace!(source)

      assert live?(another)
      assert live?(same_uuid_other_type)
      assert live?(no_source)
    end

    test "a draft whose ref carries the imported \"lines\" key is replaced" do
      source = ref("sub_order", uuid())

      imported =
        insert!(%{
          source_refs: [Map.put(source, "lines", %{Ecto.UUID.generate() => "5"})]
        })

      %{superseded: superseded} = replace!(source)

      assert Enum.map(superseded, & &1.uuid) == [imported.uuid]
      refute live?(imported)
    end

    test "a draft that got the ref through add_source_ref is replaced" do
      source = ref("sub_order", uuid())
      blank = insert!(%{})
      {:ok, blank} = InternalOrders.add_source_ref(blank, "sub_order", source["uuid"])
      assert blank.source_refs == [source]

      %{superseded: superseded} = replace!(source)

      assert Enum.map(superseded, & &1.uuid) == [blank.uuid]
    end

    test "an already trashed draft is not reported again" do
      source = ref("sub_order", uuid())
      %{order: first} = replace!(source)
      %{order: second} = replace!(source)
      %{superseded: superseded} = replace!(source)

      assert Enum.map(superseded, & &1.uuid) == [second.uuid]
      refute live?(first)
    end

    test "several live one-source drafts all go to the trash" do
      source = ref("sub_order", uuid())
      a = insert!(%{source_refs: [source]})
      b = insert!(%{source_refs: [source]})

      %{superseded: superseded} = replace!(source)

      assert Enum.sort(Enum.map(superseded, & &1.uuid)) == Enum.sort([a.uuid, b.uuid])
    end

    test "without a source it behaves like create/3" do
      other = insert!(%{source_refs: [ref("sub_order", uuid())]})

      assert {:ok, %{order: order, superseded: []}} =
               InternalOrders.replace_draft_for_source(lines(), nil, location_uuid: @location)

      assert order.source_refs == []
      assert live?(other)
    end

    test "an invalid new draft rolls back and trashes nothing" do
      source = ref("sub_order", uuid())
      %{order: first} = replace!(source)

      assert {:error, %Ecto.Changeset{}} =
               InternalOrders.replace_draft_for_source(lines(), source,
                 location_uuid: "not-a-uuid"
               )

      assert live?(first)
    end

    test "a source ref that is not a type/uuid map is refused" do
      assert {:error, :invalid_source_ref} =
               InternalOrders.replace_draft_for_source(lines(), %{"type" => "sub_order"},
                 location_uuid: @location
               )
    end
  end

  describe "list_for_source/2" do
    test "returns live internal orders of the source, newest first by inserted_at" do
      source = ref("sub_order", uuid())
      old = insert!(%{source_refs: [source]})
      newest = insert!(%{source_refs: [source]})
      middle = insert!(%{source_refs: [source, ref("sub_order", uuid())]})

      # Numbers are not chronological, so order must come from inserted_at.
      set_inserted_at(old, ~U[2026-01-01 10:00:00Z])
      set_inserted_at(middle, ~U[2026-01-02 10:00:00Z])
      set_inserted_at(newest, ~U[2026-01-03 10:00:00Z])

      assert Enum.map(InternalOrders.list_for_source("sub_order", source["uuid"]), & &1.uuid) ==
               [newest.uuid, middle.uuid, old.uuid]
    end

    test "excludes trashed orders, other sources and other types" do
      source = ref("sub_order", uuid())
      live = insert!(%{source_refs: [source]})
      trashed = insert!(%{source_refs: [source]})
      {:ok, _} = InternalOrders.soft_delete_internal_order(trashed, nil)
      insert!(%{source_refs: [ref("order", source["uuid"])]})
      insert!(%{source_refs: [ref("sub_order", uuid())]})

      assert [%{uuid: found}] = InternalOrders.list_for_source("sub_order", source["uuid"])
      assert found == live.uuid
    end

    test "includes posted orders" do
      source = ref("sub_order", uuid())
      draft = insert!(%{source_refs: [source], lines: lines()})
      {:ok, posted} = InternalOrders.post_internal_order(draft, nil)

      assert [%{uuid: found, status: "posted"}] =
               InternalOrders.list_for_source("sub_order", source["uuid"])

      assert found == posted.uuid
    end

    test "returns [] for an unknown source" do
      assert InternalOrders.list_for_source("sub_order", uuid()) == []
    end
  end

  describe "multi_source?/1" do
    test "is false for no refs and for one source" do
      refute InternalOrders.multi_source?(%InternalOrder{source_refs: []})
      refute InternalOrders.multi_source?(%InternalOrder{source_refs: nil})
      refute InternalOrders.multi_source?(%InternalOrder{source_refs: [ref("order", "a")]})
    end

    test "is false when one source appears twice or carries the imported \"lines\" key" do
      one = ref("sub_order", "a")

      refute InternalOrders.multi_source?(%InternalOrder{
               source_refs: [one, Map.put(one, "lines", %{"x" => "1"})]
             })
    end

    test "is true for two distinct sources, also of different types" do
      assert InternalOrders.multi_source?(%InternalOrder{
               source_refs: [ref("sub_order", "a"), ref("sub_order", "b")]
             })

      assert InternalOrders.multi_source?(%InternalOrder{
               source_refs: [ref("sub_order", "a"), ref("order", "a")]
             })
    end
  end

  describe "restore_internal_order/3" do
    test "brings a trashed draft back and clears the deletion marks" do
      order = insert!(%{source_refs: [ref("sub_order", uuid())]})
      {:ok, trashed} = InternalOrders.soft_delete_internal_order(order, uuid())

      assert {:ok, %{order: restored, superseded: []}} =
               InternalOrders.restore_internal_order(trashed, uuid())

      assert restored.deleted_at == nil
      assert restored.deleted_by_uuid == nil
      assert restored.status == "draft"
      assert live?(order)
    end

    test "by default does not swap: the live drafts of the same source stay" do
      source = ref("sub_order", uuid())
      %{order: first} = replace!(source)
      %{order: second} = replace!(source)

      assert {:ok, %{order: restored, superseded: []}} =
               InternalOrders.restore_internal_order(first, uuid())

      assert live?(restored)
      assert live?(second)
    end

    test "with swap: true every live one-source draft of the source goes to the trash" do
      source = ref("sub_order", uuid())
      first = trashed!(source)
      a = insert!(%{source_refs: [source]})
      b = insert!(%{source_refs: [source]})
      actor = uuid()

      assert {:ok, %{order: restored, superseded: superseded}} =
               InternalOrders.restore_internal_order(first, actor, swap: true)

      assert Enum.sort(Enum.map(superseded, & &1.uuid)) == Enum.sort([a.uuid, b.uuid])
      assert Enum.all?(superseded, &(&1.deleted_by_uuid == actor))
      assert live?(restored)
      refute live?(a)
      refute live?(b)

      assert [only] = InternalOrders.list_for_source("sub_order", source["uuid"])
      assert only.uuid == first.uuid
    end

    test "with swap: true a posted order of the same source stays" do
      source = ref("sub_order", uuid())
      first = trashed!(source)
      posted_draft = insert!(%{source_refs: [source], lines: lines()})
      {:ok, posted} = InternalOrders.post_internal_order(posted_draft, nil)

      assert {:ok, %{superseded: []}} =
               InternalOrders.restore_internal_order(first, uuid(), swap: true)

      assert reload(posted).status == "posted"
      assert live?(posted)
    end

    test "with swap: true a combined draft among the live ones stays" do
      source = ref("sub_order", uuid())
      first = trashed!(source)
      combined = insert!(%{source_refs: [source, ref("sub_order", uuid())]})

      assert {:ok, %{superseded: []}} =
               InternalOrders.restore_internal_order(first, uuid(), swap: true)

      assert live?(combined)
    end

    test "a combined trashed draft is restored without a swap even with swap: true" do
      source = ref("sub_order", uuid())
      other = ref("sub_order", uuid())
      combined = insert!(%{source_refs: [source, other]})
      {:ok, combined} = InternalOrders.soft_delete_internal_order(combined, uuid())
      %{order: live_one} = replace!(source)

      assert {:ok, %{order: restored, superseded: []}} =
               InternalOrders.restore_internal_order(combined, uuid(), swap: true)

      assert live?(restored)
      assert live?(live_one)
    end

    test "a trashed draft without a source is restored without a swap" do
      blank = insert!(%{})
      {:ok, blank} = InternalOrders.soft_delete_internal_order(blank, uuid())
      other = insert!(%{})

      assert {:ok, %{superseded: []}} =
               InternalOrders.restore_internal_order(blank, uuid(), swap: true)

      assert live?(other)
    end

    test "a live order answers :not_deleted" do
      order = insert!(%{})
      assert {:error, :not_deleted} = InternalOrders.restore_internal_order(order, uuid())
    end

    test "a trashed posted order (legacy) answers :not_draft and stays trashed" do
      order = insert!(%{lines: lines()})
      {:ok, posted} = InternalOrders.post_internal_order(order, nil)

      {1, _} =
        Repo.update_all(
          from(o in InternalOrder, where: o.uuid == ^posted.uuid),
          set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

      assert {:error, :not_draft} = InternalOrders.restore_internal_order(posted, uuid())
      refute live?(posted)
    end

    test "an unknown order answers :not_found" do
      assert {:error, :not_found} =
               InternalOrders.restore_internal_order(%InternalOrder{uuid: uuid()}, uuid())
    end

    test "restoring twice answers :not_deleted the second time" do
      order = insert!(%{})
      {:ok, trashed} = InternalOrders.soft_delete_internal_order(order, nil)

      assert {:ok, _} = InternalOrders.restore_internal_order(trashed, uuid())
      assert {:error, :not_deleted} = InternalOrders.restore_internal_order(trashed, uuid())
    end
  end

  describe "soft_delete_internal_order/2" do
    test "keeps the returns: {:ok, order} for a draft, :not_draft for a posted one" do
      draft = insert!(%{lines: lines()})
      actor = uuid()

      assert {:ok, %InternalOrder{deleted_by_uuid: ^actor, deleted_at: %DateTime{}}} =
               InternalOrders.soft_delete_internal_order(draft, actor)

      posted_draft = insert!(%{lines: lines()})
      {:ok, posted} = InternalOrders.post_internal_order(posted_draft, nil)

      assert {:error, :not_draft} = InternalOrders.soft_delete_internal_order(posted, actor)
    end

    test "a draft posted behind the caller's back is not trashed" do
      stale = insert!(%{lines: lines()})
      {:ok, _} = InternalOrders.post_internal_order(stale, nil)

      assert {:error, :not_draft} = InternalOrders.soft_delete_internal_order(stale, uuid())
      assert live?(stale)
      assert reload(stale).status == "posted"
    end

    test "an already trashed draft answers :deleted and keeps its first deletion marks" do
      first_actor = uuid()
      order = insert!(%{})
      {:ok, trashed} = InternalOrders.soft_delete_internal_order(order, first_actor)

      assert {:error, :deleted} = InternalOrders.soft_delete_internal_order(trashed, uuid())
      assert reload(order).deleted_by_uuid == first_actor
    end

    test "touches updated_at" do
      order = insert!(%{})
      set_updated_at(order, ~U[2026-01-01 10:00:00Z])

      {:ok, trashed} = InternalOrders.soft_delete_internal_order(order, nil)

      assert DateTime.compare(trashed.updated_at, ~U[2026-01-01 10:00:00Z]) == :gt
      assert DateTime.compare(reload(order).updated_at, ~U[2026-01-01 10:00:00Z]) == :gt
    end
  end

  describe "a trashed internal order" do
    setup do
      order = insert!(%{lines: lines()})
      {:ok, trashed} = InternalOrders.soft_delete_internal_order(order, nil)
      %{trashed: trashed}
    end

    test "update_draft answers :deleted and writes nothing", %{trashed: trashed} do
      assert {:error, :deleted} = InternalOrders.update_draft(trashed, %{note: "edited"})
      assert reload(trashed).note == nil
    end

    test "post_internal_order answers :deleted and does not post", %{trashed: trashed} do
      assert {:error, :deleted} = InternalOrders.post_internal_order(trashed, nil)
      assert reload(trashed).status == "draft"
    end

    test "import_from_sources answers :deleted", %{trashed: trashed} do
      assert {:error, :deleted} =
               InternalOrders.import_from_sources(trashed, [ref("sub_order", uuid())], uuid())
    end

    test "add_source_ref answers :deleted and writes nothing", %{trashed: trashed} do
      assert {:error, :deleted} = InternalOrders.add_source_ref(trashed, "sub_order", uuid())
      assert reload(trashed).source_refs == []
    end

    test "add_source_ref and remove_source_ref look at the row, not at the struct" do
      source = ref("sub_order", uuid())
      order = insert!(%{source_refs: [source]})
      {:ok, _} = InternalOrders.soft_delete_internal_order(order, nil)

      assert {:error, :deleted} = InternalOrders.add_source_ref(order, "sub_order", uuid())

      assert {:error, :deleted} =
               InternalOrders.remove_source_ref(order, "sub_order", source["uuid"])

      assert reload(order).source_refs == [source]
    end

    test "remove_source_ref answers :deleted and keeps the ref" do
      source = ref("sub_order", uuid())

      {:ok, trashed} =
        InternalOrders.soft_delete_internal_order(insert!(%{source_refs: [source]}), nil)

      assert {:error, :deleted} =
               InternalOrders.remove_source_ref(trashed, "sub_order", source["uuid"])

      assert reload(trashed).source_refs == [source]
    end

    test "the links of a live order, posted ones included, still change" do
      source = ref("sub_order", uuid())
      posted = insert!(%{lines: lines()}) |> InternalOrders.post_internal_order(nil) |> elem(1)

      assert {:ok, linked} = InternalOrders.add_source_ref(posted, "sub_order", source["uuid"])
      assert linked.source_refs == [source]

      assert {:ok, unlinked} =
               InternalOrders.remove_source_ref(linked, "sub_order", source["uuid"])

      assert unlinked.source_refs == []
    end

    test "a posted live order still answers :not_draft" do
      draft = insert!(%{lines: lines()})
      {:ok, posted} = InternalOrders.post_internal_order(draft, nil)

      stale = %{posted | status: "draft"}
      assert {:error, :not_draft} = InternalOrders.update_draft(stale, %{note: "x"})
      assert {:error, :not_draft} = InternalOrders.post_internal_order(stale, nil)
    end

    test "update_draft on a missing row keeps answering :not_draft" do
      assert {:error, :not_draft} =
               InternalOrders.update_draft(%InternalOrder{uuid: uuid()}, %{note: "x"})
    end

    test "a restored order can be edited and posted again", %{trashed: trashed} do
      {:ok, %{order: restored}} = InternalOrders.restore_internal_order(trashed, nil)

      assert {:ok, %{note: "edited"}} = InternalOrders.update_draft(restored, %{note: "edited"})
      assert {:ok, %{status: "posted"}} = InternalOrders.post_internal_order(restored, nil)
    end
  end

  describe "activity" do
    test "a superseded draft gets warehouse.internal_order.trashed with the reason" do
      source = ref("sub_order", uuid())
      %{order: first} = replace!(source)
      actor = uuid()
      %{order: second} = replace!(source, actor)

      assert [entry] = activity("warehouse.internal_order.trashed", first.uuid)
      assert entry.module == "warehouse"
      assert entry.resource_type == "internal_order"
      assert entry.actor_uuid == actor
      assert entry.metadata["trash_reason"] == "superseded"
      assert entry.metadata["superseded_by_uuid"] == second.uuid
      assert entry.metadata["number"] == to_string(first.number)
    end

    test "nothing is logged for the order that stays" do
      source = ref("sub_order", uuid())
      %{order: first} = replace!(source)
      %{order: second} = replace!(source)

      assert activity("warehouse.internal_order.trashed", second.uuid) == []
      assert [_] = activity("warehouse.internal_order.trashed", first.uuid)
    end

    test "a manual soft delete is logged with reason manual" do
      order = insert!(%{})
      actor = uuid()
      {:ok, _} = InternalOrders.soft_delete_internal_order(order, actor)

      assert [entry] = activity("warehouse.internal_order.trashed", order.uuid)
      assert entry.metadata["trash_reason"] == "manual"
      assert entry.actor_uuid == actor
      refute Map.has_key?(entry.metadata, "superseded_by_uuid")
    end

    test "restore logs restored; a swap logs trashed with reason restore_swap" do
      source = ref("sub_order", uuid())
      %{order: first} = replace!(source)
      %{order: second} = replace!(source)
      actor = uuid()

      {:ok, %{order: restored}} = InternalOrders.restore_internal_order(first, actor, swap: true)

      assert [restored_entry] = activity("warehouse.internal_order.restored", restored.uuid)
      assert restored_entry.actor_uuid == actor

      swap_entries = activity("warehouse.internal_order.trashed", second.uuid)
      assert Enum.any?(swap_entries, &(&1.metadata["trash_reason"] == "restore_swap"))

      swap = Enum.find(swap_entries, &(&1.metadata["trash_reason"] == "restore_swap"))
      assert swap.metadata["superseded_by_uuid"] == restored.uuid
    end

    test "a refused restore and a refused delete log nothing" do
      live = insert!(%{})
      assert {:error, :not_deleted} = InternalOrders.restore_internal_order(live, nil)
      assert activity("warehouse.internal_order.restored", live.uuid) == []

      draft = insert!(%{lines: lines()})
      {:ok, posted} = InternalOrders.post_internal_order(draft, nil)
      assert {:error, :not_draft} = InternalOrders.soft_delete_internal_order(posted, nil)
      assert activity("warehouse.internal_order.trashed", posted.uuid) == []
    end

    test "the :inventory_activity_logging switch silences the new entries" do
      Application.put_env(:phoenix_kit_warehouse, :inventory_activity_logging, false)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_warehouse, :inventory_activity_logging)
      end)

      source = ref("sub_order", uuid())
      %{order: first} = replace!(source)
      %{order: _second} = replace!(source)
      {:ok, _} = InternalOrders.restore_internal_order(first, nil)

      assert activity("warehouse.internal_order.trashed", first.uuid) == []
      assert activity("warehouse.internal_order.restored", first.uuid) == []
    end
  end

  defp set_inserted_at(%InternalOrder{uuid: uuid}, at) do
    {1, _} =
      Repo.update_all(from(o in InternalOrder, where: o.uuid == ^uuid), set: [inserted_at: at])
  end

  defp set_updated_at(%InternalOrder{uuid: uuid}, at) do
    {1, _} =
      Repo.update_all(from(o in InternalOrder, where: o.uuid == ^uuid), set: [updated_at: at])
  end
end
