defmodule PhoenixKitWarehouse.InternalOrdersTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Test.FakeOrderSources

  setup do
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
      FakeOrderSources.order_kind(),
      FakeOrderSources.sub_order_kind()
    ])

    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp default_location_uuid do
    # Use a stable test UUID for location — internal orders require a non-null location.
    # In production this comes from StockLedger.default_location_uuid/0 (a setting).
    # For tests we use a fixed UUID so we don't depend on configured locations.
    "00000000-0000-0000-0000-000000000001"
  end

  defp user_uuid do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "io-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "IO",
        "last_name" => "Test"
      })

    user.uuid
  end

  defp create_draft!(attrs \\ []) do
    attrs_map = if is_list(attrs), do: Map.new(attrs), else: attrs
    base = %{location_uuid: default_location_uuid()}
    {:ok, order} = InternalOrders.create_internal_order(Map.merge(base, attrs_map))
    order
  end

  defp sample_lines do
    [
      %{
        "item_uuid" => Ecto.UUID.generate(),
        "name" => "Screw M6",
        "sku" => "SCR-M6",
        "unit" => "pcs",
        "catalogue_uuid" => Ecto.UUID.generate(),
        "category_uuid" => Ecto.UUID.generate(),
        "required_quantity" => "10"
      },
      %{
        "item_uuid" => Ecto.UUID.generate(),
        "name" => "Bolt M8",
        "sku" => "BLT-M8",
        "unit" => "pcs",
        "catalogue_uuid" => Ecto.UUID.generate(),
        "category_uuid" => Ecto.UUID.generate(),
        "required_quantity" => "5"
      }
    ]
  end

  defp insert_sub_order_with_material_sheet(_actor_uuid) do
    lines = [
      %{
        "item_uuid" => Ecto.UUID.generate(),
        "name" => "Paint",
        "sku" => "PNT-001",
        "unit" => "l",
        "catalogue_uuid" => Ecto.UUID.generate(),
        "category_uuid" => Ecto.UUID.generate(),
        "required_quantity" => "3"
      }
    ]

    order =
      FakeOrderSources.put_sub_order(%{
        uuid: Ecto.UUID.generate(),
        label: "fake sub-order",
        lines: lines
      })

    sheet = %{lines: lines}

    {order, sheet}
  end

  # ---------------------------------------------------------------------------
  # Draft create / update
  # ---------------------------------------------------------------------------

  describe "create_internal_order/1" do
    test "creates a draft with required location_uuid" do
      {:ok, order} =
        InternalOrders.create_internal_order(%{location_uuid: default_location_uuid()})

      assert order.status == "draft"
      assert order.location_uuid == default_location_uuid()
      assert order.uuid != nil
    end

    test "assigns a unique number from the sequence" do
      {:ok, o1} = InternalOrders.create_internal_order(%{location_uuid: default_location_uuid()})
      {:ok, o2} = InternalOrders.create_internal_order(%{location_uuid: default_location_uuid()})

      assert o1.number != nil
      assert o2.number != nil
      assert o1.number != o2.number
    end

    test "falls back to the configured default location when location_uuid is missing" do
      assert {:ok, order} = InternalOrders.create_internal_order(%{})
      assert order.location_uuid == PhoenixKitWarehouse.StockLedger.default_location_uuid()
    end

    test "stores lines and note" do
      lines = sample_lines()

      {:ok, order} =
        InternalOrders.create_internal_order(%{
          location_uuid: default_location_uuid(),
          lines: lines,
          note: "test note"
        })

      assert length(order.lines) == 2
      assert order.note == "test note"
    end
  end

  describe "update_draft/2" do
    test "updates lines and note on a draft" do
      order = create_draft!()
      lines = sample_lines()

      {:ok, updated} = InternalOrders.update_draft(order, %{lines: lines, note: "updated"})

      assert length(updated.lines) == 2
      assert updated.note == "updated"
    end

    test "returns {:error, :not_draft} for a posted order" do
      actor = user_uuid()
      order = create_draft!(lines: sample_lines())
      {:ok, posted} = InternalOrders.post_internal_order(order, actor)

      assert {:error, :not_draft} = InternalOrders.update_draft(posted, %{note: "nope"})
    end
  end

  describe "add_source_ref/3 and remove_source_ref/3" do
    test "attaches a reference without touching lines" do
      order = create_draft!(lines: sample_lines())
      uuid = Ecto.UUID.generate()

      assert {:ok, updated} = InternalOrders.add_source_ref(order, "order", uuid)

      assert %{"type" => "order", "uuid" => uuid} in updated.source_refs
      assert length(updated.lines) == 2
    end

    test "adding the same {type, uuid} twice is a no-op" do
      order = create_draft!()
      uuid = Ecto.UUID.generate()

      {:ok, once} = InternalOrders.add_source_ref(order, "sub_order", uuid)
      {:ok, twice} = InternalOrders.add_source_ref(once, "sub_order", uuid)

      assert length(twice.source_refs) == 1
    end

    test "removes an attached reference" do
      order = create_draft!()
      uuid = Ecto.UUID.generate()

      {:ok, attached} = InternalOrders.add_source_ref(order, "order", uuid)
      assert {:ok, removed} = InternalOrders.remove_source_ref(attached, "order", uuid)

      assert removed.source_refs == []
    end

    test "removing a reference that isn't present is a no-op" do
      order = create_draft!()

      assert {:ok, updated} =
               InternalOrders.remove_source_ref(order, "order", Ecto.UUID.generate())

      assert updated.source_refs == []
    end

    test "works on a posted order (metadata-only, not draft-gated)" do
      actor = user_uuid()
      order = create_draft!(lines: sample_lines())
      {:ok, posted} = InternalOrders.post_internal_order(order, actor)
      uuid = Ecto.UUID.generate()

      assert {:ok, updated} = InternalOrders.add_source_ref(posted, "order", uuid)
      assert %{"type" => "order", "uuid" => uuid} in updated.source_refs
      assert updated.status == "posted"
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  describe "list_internal_orders/0" do
    test "excludes soft-deleted orders" do
      actor = user_uuid()
      order = create_draft!()
      {:ok, _} = InternalOrders.soft_delete_internal_order(order, actor)

      all = InternalOrders.list_internal_orders()
      refute Enum.any?(all, &(&1.uuid == order.uuid))
    end

    test "includes non-deleted orders" do
      order = create_draft!()

      all = InternalOrders.list_internal_orders()
      assert Enum.any?(all, &(&1.uuid == order.uuid))
    end
  end

  describe "get_internal_order!/1 and get_internal_order/1" do
    test "get_internal_order!/1 raises on missing" do
      assert_raise Ecto.NoResultsError, fn ->
        InternalOrders.get_internal_order!(Ecto.UUID.generate())
      end
    end

    test "get_internal_order/1 returns {:error, :not_found} on missing" do
      assert {:error, :not_found} = InternalOrders.get_internal_order(Ecto.UUID.generate())
    end

    test "get_internal_order/1 returns {:ok, order}" do
      order = create_draft!()
      assert {:ok, found} = InternalOrders.get_internal_order(order.uuid)
      assert found.uuid == order.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # create/2 (generic replacement for the removed create_from_material_sheet/3)
  # ---------------------------------------------------------------------------

  describe "create/2 (generic replacement for the removed create_from_material_sheet/3)" do
    test "creates a draft with the given lines and a single source_ref" do
      actor = user_uuid()
      lines = sample_lines()
      source_ref = %{"type" => "sub_order", "uuid" => Ecto.UUID.generate()}

      {:ok, order} = InternalOrders.create(lines, source_ref, created_by_uuid: actor)

      assert order.status == "draft"
      assert order.lines == lines
      assert order.source_refs == [source_ref]
      assert order.created_by_uuid == actor
      assert order.location_uuid != nil
    end

    test "accepts nil source_ref (no traceability entry)" do
      {:ok, order} = InternalOrders.create(sample_lines(), nil)
      assert order.source_refs == []
    end

    test "accepts an explicit :location_uuid opt" do
      loc = Ecto.UUID.generate()
      {:ok, order} = InternalOrders.create([], nil, location_uuid: loc)
      assert order.location_uuid == loc
    end
  end

  # ---------------------------------------------------------------------------
  # Posting
  # ---------------------------------------------------------------------------

  describe "post_internal_order/2" do
    test "flips status to posted and sets posted_at" do
      actor = user_uuid()
      order = create_draft!(lines: sample_lines())

      {:ok, posted} = InternalOrders.post_internal_order(order, actor)

      assert posted.status == "posted"
      assert posted.posted_at != nil
      assert posted.performed_by_uuid == actor
    end

    test "sets performed_by_uuid to actor" do
      actor = user_uuid()
      order = create_draft!(lines: sample_lines())

      {:ok, posted} = InternalOrders.post_internal_order(order, actor)

      assert posted.performed_by_uuid == actor
    end

    test "deduplicates lines by item_uuid on posting" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()

      dup_lines = [
        %{
          "item_uuid" => item_uuid,
          "name" => "Widget",
          "sku" => "W-1",
          "unit" => "pcs",
          "catalogue_uuid" => Ecto.UUID.generate(),
          "category_uuid" => Ecto.UUID.generate(),
          "required_quantity" => "5"
        },
        %{
          "item_uuid" => item_uuid,
          "name" => "Widget duplicate",
          "sku" => "W-1",
          "unit" => "pcs",
          "catalogue_uuid" => Ecto.UUID.generate(),
          "category_uuid" => Ecto.UUID.generate(),
          "required_quantity" => "3"
        }
      ]

      order = create_draft!(lines: dup_lines)
      {:ok, posted} = InternalOrders.post_internal_order(order, actor)

      assert length(posted.lines) == 1
    end

    test "returns {:error, :not_draft} when already posted" do
      actor = user_uuid()
      order = create_draft!(lines: sample_lines())
      {:ok, _posted} = InternalOrders.post_internal_order(order, actor)

      # Attempt to post again using the original (stale) draft struct
      assert {:error, :not_draft} = InternalOrders.post_internal_order(order, actor)
    end

    test "in-memory guard returns {:error, :not_draft} for non-draft structs" do
      actor = user_uuid()
      order = create_draft!(lines: sample_lines())
      {:ok, posted} = InternalOrders.post_internal_order(order, actor)

      assert {:error, :not_draft} = InternalOrders.post_internal_order(posted, actor)
    end

    test "does NOT write any stock rows" do
      actor = user_uuid()
      order = create_draft!(lines: sample_lines())

      stock_before = PhoenixKitWarehouse.Test.Repo.all(PhoenixKitWarehouse.Stock)
      {:ok, _posted} = InternalOrders.post_internal_order(order, actor)
      stock_after = PhoenixKitWarehouse.Test.Repo.all(PhoenixKitWarehouse.Stock)

      assert length(stock_before) == length(stock_after)
    end
  end

  # ---------------------------------------------------------------------------
  # Soft delete
  # ---------------------------------------------------------------------------

  describe "soft_delete_internal_order/2" do
    test "soft-deletes a draft order" do
      actor = user_uuid()
      order = create_draft!()

      {:ok, deleted} = InternalOrders.soft_delete_internal_order(order, actor)

      assert deleted.deleted_at != nil
      assert deleted.deleted_by_uuid == actor
    end

    test "excludes soft-deleted order from list" do
      actor = user_uuid()
      order = create_draft!()
      {:ok, _} = InternalOrders.soft_delete_internal_order(order, actor)

      all = InternalOrders.list_internal_orders()
      refute Enum.any?(all, &(&1.uuid == order.uuid))
    end

    test "returns {:error, :not_draft} for a posted order" do
      actor = user_uuid()
      order = create_draft!(lines: sample_lines())
      {:ok, posted} = InternalOrders.post_internal_order(order, actor)

      assert {:error, :not_draft} = InternalOrders.soft_delete_internal_order(posted, actor)
    end
  end

  # ---------------------------------------------------------------------------
  # Correction (note-only on posted)
  # ---------------------------------------------------------------------------

  describe "correct_internal_order/2" do
    test "updates note on a posted order" do
      actor = user_uuid()
      order = create_draft!(lines: sample_lines(), note: "original")
      {:ok, posted} = InternalOrders.post_internal_order(order, actor)

      {:ok, corrected} = InternalOrders.correct_internal_order(posted, %{note: "corrected note"})

      assert corrected.note == "corrected note"
      assert corrected.status == "posted"
    end

    test "does not change lines via correction" do
      actor = user_uuid()
      lines = sample_lines()
      order = create_draft!(lines: lines)
      {:ok, posted} = InternalOrders.post_internal_order(order, actor)

      {:ok, corrected} =
        InternalOrders.correct_internal_order(posted, %{
          note: "corrected",
          lines: []
        })

      # Lines should NOT be changed by correction_changeset (it only casts :note)
      assert length(corrected.lines) == length(posted.lines)
    end

    test "updates note on a draft order too" do
      order = create_draft!(note: "draft note")

      {:ok, corrected} = InternalOrders.correct_internal_order(order, %{note: "new note"})

      assert corrected.note == "new note"
    end
  end

  # ---------------------------------------------------------------------------
  # import_from_sources/3 — outstanding quantity
  # ---------------------------------------------------------------------------

  describe "import_from_sources/3 — outstanding quantity" do
    test "re-selecting a sub-order already fully covered by another internal order adds nothing" do
      actor = user_uuid()
      {sub_order, sheet} = insert_sub_order_with_material_sheet(actor)
      [%{"item_uuid" => item_uuid}] = sheet.lines

      first_io = create_draft!()

      {:ok, first_io} =
        InternalOrders.import_from_sources(
          first_io,
          [%{"type" => "sub_order", "uuid" => sub_order.uuid}],
          actor
        )

      assert [%{"required_quantity" => "3"}] = first_io.lines

      second_io = create_draft!()

      {:ok, second_io} =
        InternalOrders.import_from_sources(
          second_io,
          [%{"type" => "sub_order", "uuid" => sub_order.uuid}],
          actor
        )

      # Nothing left to import — second IO gets no line (or a zero line) for that item.
      matching_line = Enum.find(second_io.lines, &(&1["item_uuid"] == item_uuid))
      assert is_nil(matching_line) or matching_line["required_quantity"] == "0"

      [ref] = Enum.filter(second_io.source_refs, &(&1["uuid"] == sub_order.uuid))
      committed = ref["lines"][item_uuid]

      assert is_nil(committed) or
               Decimal.equal?(
                 PhoenixKitWarehouse.StockLedger.to_decimal(committed),
                 Decimal.new("0")
               )
    end

    test "re-importing the same source into the same internal order updates the ref's lines in place" do
      actor = user_uuid()
      {sub_order, _sheet} = insert_sub_order_with_material_sheet(actor)
      order = create_draft!()

      {:ok, updated} =
        InternalOrders.import_from_sources(
          order,
          [%{"type" => "sub_order", "uuid" => sub_order.uuid}],
          actor
        )

      {:ok, updated_again} =
        InternalOrders.import_from_sources(
          updated,
          [%{"type" => "sub_order", "uuid" => sub_order.uuid}],
          actor
        )

      refs_for_source = Enum.filter(updated_again.source_refs, &(&1["uuid"] == sub_order.uuid))
      assert length(refs_for_source) == 1
    end
  end
end
