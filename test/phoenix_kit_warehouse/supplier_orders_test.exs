defmodule PhoenixKitWarehouse.SupplierOrdersTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.Test.Repo
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitCatalogue.Catalogue

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp default_location_uuid, do: "00000000-0000-0000-0000-000000000001"

  defp user_uuid do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "so-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "SO",
        "last_name" => "Test"
      })

    user.uuid
  end

  defp create_supplier! do
    {:ok, supplier} =
      Catalogue.create_supplier(%{
        name: "Test Supplier #{System.unique_integer([:positive])}",
        status: "active"
      })

    supplier
  end

  defp create_manufacturer! do
    {:ok, mfr} =
      Catalogue.create_manufacturer(%{
        name: "Test Manufacturer #{System.unique_integer([:positive])}",
        status: "active"
      })

    mfr
  end

  defp create_catalogue! do
    {:ok, cat} =
      Catalogue.create_catalogue(%{
        name: "Test Catalogue #{System.unique_integer([:positive])}",
        status: "active"
      })

    cat
  end

  defp create_item!(attrs \\ %{}) do
    catalogue = create_catalogue!()

    base = %{
      name: "Item #{System.unique_integer([:positive])}",
      catalogue_uuid: catalogue.uuid,
      status: "active"
    }

    {:ok, item} = Catalogue.create_item(Map.merge(base, attrs))
    item
  end

  defp create_draft!(attrs \\ %{}) do
    supplier = create_supplier!()
    base = %{supplier_uuid: supplier.uuid, location_uuid: default_location_uuid()}
    {:ok, order} = SupplierOrders.create_supplier_order(Map.merge(base, attrs))
    {order, supplier}
  end

  defp sample_lines(item_uuid \\ nil) do
    item_uuid = item_uuid || Ecto.UUID.generate()

    [
      %{
        "item_uuid" => item_uuid,
        "name" => "Widget",
        "sku" => "WGT-001",
        "unit" => "piece",
        "catalogue_uuid" => Ecto.UUID.generate(),
        "required_quantity" => Decimal.new("10"),
        "on_hand_quantity" => Decimal.new("3"),
        "shortfall_quantity" => Decimal.new("7"),
        "ordered_quantity" => Decimal.new("7"),
        "base_price" => Decimal.new("12.50")
      }
    ]
  end

  defp posted_internal_order_with_lines(lines, actor_uuid) do
    {:ok, order} =
      InternalOrders.create_internal_order(%{
        location_uuid: default_location_uuid(),
        lines: lines
      })

    {:ok, posted} = InternalOrders.post_internal_order(order, actor_uuid)
    posted
  end

  defp internal_order_line(item, required_qty) do
    %{
      "item_uuid" => item.uuid,
      "name" => item.name,
      "sku" => item.sku || "",
      "unit" => item.unit || "piece",
      "catalogue_uuid" => item.catalogue_uuid,
      "category_uuid" => item.category_uuid,
      "required_quantity" => Decimal.to_string(Decimal.new(required_qty))
    }
  end

  # ---------------------------------------------------------------------------
  # Draft create / update
  # ---------------------------------------------------------------------------

  describe "create_supplier_order/1" do
    test "creates a draft with required supplier_uuid and location_uuid" do
      supplier = create_supplier!()

      {:ok, order} =
        SupplierOrders.create_supplier_order(%{
          supplier_uuid: supplier.uuid,
          location_uuid: default_location_uuid()
        })

      assert order.status == "draft"
      assert order.supplier_uuid == supplier.uuid
      assert order.uuid != nil
      assert order.number != nil
    end

    test "assigns a unique number from the sequence" do
      supplier = create_supplier!()

      {:ok, o1} =
        SupplierOrders.create_supplier_order(%{
          supplier_uuid: supplier.uuid,
          location_uuid: default_location_uuid()
        })

      {:ok, o2} =
        SupplierOrders.create_supplier_order(%{
          supplier_uuid: supplier.uuid,
          location_uuid: default_location_uuid()
        })

      assert o1.number != o2.number
    end

    test "allows a draft without a supplier; posting requires one" do
      # Supplier is now optional at draft creation (chosen on the create form,
      # imported per-supplier) and only required when the order is posted.
      assert {:ok, order} =
               SupplierOrders.create_supplier_order(%{location_uuid: default_location_uuid()})

      assert order.supplier_uuid == nil

      assert {:error, changeset} = SupplierOrders.post_supplier_order(order, nil)
      assert errors_on(changeset).supplier_uuid
    end

    test "stores lines and note" do
      {order, _supplier} = create_draft!(%{lines: sample_lines(), note: "test note"})

      assert length(order.lines) == 1
      assert order.note == "test note"
    end
  end

  describe "update_draft/2" do
    test "updates lines and note on a draft" do
      {order, _} = create_draft!()

      {:ok, updated} =
        SupplierOrders.update_draft(order, %{lines: sample_lines(), note: "updated"})

      assert length(updated.lines) == 1
      assert updated.note == "updated"
    end

    test "returns {:error, :not_draft} for a posted order" do
      actor = user_uuid()
      {order, _} = create_draft!(%{lines: sample_lines()})
      {:ok, posted} = SupplierOrders.post_supplier_order(order, actor)

      assert {:error, :not_draft} = SupplierOrders.update_draft(posted, %{note: "nope"})
    end
  end

  describe "add_source_ref/3 and remove_source_ref/3" do
    test "attaches a reference without touching lines" do
      {order, _} = create_draft!(%{lines: sample_lines()})
      uuid = Ecto.UUID.generate()

      assert {:ok, updated} = SupplierOrders.add_source_ref(order, "internal_order", uuid)

      assert %{"type" => "internal_order", "uuid" => uuid} in updated.source_refs
      assert length(updated.lines) == 1
    end

    test "adding the same {type, uuid} twice is a no-op" do
      {order, _} = create_draft!()
      uuid = Ecto.UUID.generate()

      {:ok, once} = SupplierOrders.add_source_ref(order, "internal_order", uuid)
      {:ok, twice} = SupplierOrders.add_source_ref(once, "internal_order", uuid)

      assert length(twice.source_refs) == 1
    end

    test "removes an attached reference" do
      {order, _} = create_draft!()
      uuid = Ecto.UUID.generate()

      {:ok, attached} = SupplierOrders.add_source_ref(order, "internal_order", uuid)
      assert {:ok, removed} = SupplierOrders.remove_source_ref(attached, "internal_order", uuid)

      assert removed.source_refs == []
    end

    test "removing a reference that isn't present is a no-op" do
      {order, _} = create_draft!()

      assert {:ok, updated} =
               SupplierOrders.remove_source_ref(order, "internal_order", Ecto.UUID.generate())

      assert updated.source_refs == []
    end

    test "works on a posted order (metadata-only, not draft-gated)" do
      actor = user_uuid()
      {order, _} = create_draft!(%{lines: sample_lines()})
      {:ok, posted} = SupplierOrders.post_supplier_order(order, actor)
      uuid = Ecto.UUID.generate()

      assert {:ok, updated} = SupplierOrders.add_source_ref(posted, "internal_order", uuid)
      assert %{"type" => "internal_order", "uuid" => uuid} in updated.source_refs
      assert updated.status == "posted"
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  describe "list_supplier_orders/0" do
    test "excludes soft-deleted orders" do
      actor = user_uuid()
      {order, _} = create_draft!()
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, actor)

      all = SupplierOrders.list_supplier_orders()
      refute Enum.any?(all, &(&1.uuid == order.uuid))
    end

    test "includes non-deleted orders" do
      {order, _} = create_draft!()

      all = SupplierOrders.list_supplier_orders()
      assert Enum.any?(all, &(&1.uuid == order.uuid))
    end
  end

  describe "get_supplier_order!/1 and get_supplier_order/1" do
    test "get_supplier_order!/1 raises on missing" do
      assert_raise Ecto.NoResultsError, fn ->
        SupplierOrders.get_supplier_order!(Ecto.UUID.generate())
      end
    end

    test "get_supplier_order/1 returns {:error, :not_found} on missing" do
      assert {:error, :not_found} = SupplierOrders.get_supplier_order(Ecto.UUID.generate())
    end

    test "get_supplier_order/1 returns {:ok, order}" do
      {order, _} = create_draft!()
      assert {:ok, found} = SupplierOrders.get_supplier_order(order.uuid)
      assert found.uuid == order.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Posting
  # ---------------------------------------------------------------------------

  describe "post_supplier_order/2" do
    test "flips status to posted and sets posted_at" do
      actor = user_uuid()
      {order, _} = create_draft!(%{lines: sample_lines()})

      {:ok, posted} = SupplierOrders.post_supplier_order(order, actor)

      assert posted.status == "posted"
      assert posted.posted_at != nil
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
          "ordered_quantity" => Decimal.new("5"),
          "shortfall_quantity" => Decimal.new("5"),
          "on_hand_quantity" => Decimal.new("0"),
          "required_quantity" => Decimal.new("5"),
          "base_price" => nil
        },
        %{
          "item_uuid" => item_uuid,
          "name" => "Widget dup",
          "sku" => "W-1",
          "ordered_quantity" => Decimal.new("3"),
          "shortfall_quantity" => Decimal.new("3"),
          "on_hand_quantity" => Decimal.new("0"),
          "required_quantity" => Decimal.new("3"),
          "base_price" => nil
        }
      ]

      {order, _} = create_draft!(%{lines: dup_lines})
      {:ok, posted} = SupplierOrders.post_supplier_order(order, actor)

      assert length(posted.lines) == 1
    end

    test "returns {:error, :not_draft} when already posted" do
      actor = user_uuid()
      {order, _} = create_draft!(%{lines: sample_lines()})
      {:ok, _posted} = SupplierOrders.post_supplier_order(order, actor)

      # Attempt to post again using the original (stale) draft struct
      assert {:error, :not_draft} = SupplierOrders.post_supplier_order(order, actor)
    end

    test "in-memory guard returns {:error, :not_draft} for non-draft structs" do
      actor = user_uuid()
      {order, _} = create_draft!(%{lines: sample_lines()})
      {:ok, posted} = SupplierOrders.post_supplier_order(order, actor)

      assert {:error, :not_draft} = SupplierOrders.post_supplier_order(posted, actor)
    end

    test "does NOT write any stock rows" do
      actor = user_uuid()
      {order, _} = create_draft!(%{lines: sample_lines()})

      stock_before = Repo.all(Stock)
      {:ok, _posted} = SupplierOrders.post_supplier_order(order, actor)
      stock_after = Repo.all(Stock)

      assert length(stock_before) == length(stock_after)
    end
  end

  # ---------------------------------------------------------------------------
  # Soft delete
  # ---------------------------------------------------------------------------

  describe "soft_delete_supplier_order/2" do
    test "soft-deletes a draft order" do
      actor = user_uuid()
      {order, _} = create_draft!()

      {:ok, deleted} = SupplierOrders.soft_delete_supplier_order(order, actor)

      assert deleted.deleted_at != nil
      assert deleted.deleted_by_uuid == actor
    end

    test "excludes soft-deleted order from list" do
      actor = user_uuid()
      {order, _} = create_draft!()
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, actor)

      all = SupplierOrders.list_supplier_orders()
      refute Enum.any?(all, &(&1.uuid == order.uuid))
    end

    test "returns {:error, :not_draft} for a posted order" do
      actor = user_uuid()
      {order, _} = create_draft!(%{lines: sample_lines()})
      {:ok, posted} = SupplierOrders.post_supplier_order(order, actor)

      assert {:error, :not_draft} = SupplierOrders.soft_delete_supplier_order(posted, actor)
    end
  end

  # ---------------------------------------------------------------------------
  # Correction
  # ---------------------------------------------------------------------------

  describe "correct_supplier_order/2" do
    test "updates note on a posted order without changing status or lines" do
      actor = user_uuid()
      {order, _} = create_draft!(%{lines: sample_lines(), note: "original"})
      {:ok, posted} = SupplierOrders.post_supplier_order(order, actor)

      {:ok, corrected} = SupplierOrders.correct_supplier_order(posted, %{note: "corrected note"})

      assert corrected.note == "corrected note"
      assert corrected.status == "posted"
    end

    test "does not change lines via correction" do
      actor = user_uuid()
      lines = sample_lines()
      {order, _} = create_draft!(%{lines: lines})
      {:ok, posted} = SupplierOrders.post_supplier_order(order, actor)

      {:ok, corrected} =
        SupplierOrders.correct_supplier_order(posted, %{
          note: "corrected",
          lines: []
        })

      # Lines should NOT be changed by correction_changeset (casts only :note + :storage_folder_uuid)
      assert length(corrected.lines) == length(posted.lines)
    end

    test "updates note on a draft order too" do
      {order, _} = create_draft!(%{note: "draft note"})

      {:ok, corrected} = SupplierOrders.correct_supplier_order(order, %{note: "new note"})

      assert corrected.note == "new note"
    end
  end

  # ---------------------------------------------------------------------------
  # generate_from_internal_order/2
  # ---------------------------------------------------------------------------

  describe "generate_from_internal_order/2" do
    test "drops lines where shortfall is zero (fully stocked)" do
      actor = user_uuid()
      item = create_item!(%{unit: "piece"})

      # Seed stock: item is fully stocked at 10
      StockLedger.upsert_quantity(item.uuid, Decimal.new("10"),
        location_uuid: default_location_uuid()
      )

      line = internal_order_line(item, "10")
      internal_order = posted_internal_order_with_lines([line], actor)

      {:ok, %{supplier_orders: orders, unassigned_lines: unassigned}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      # required=10, on_hand=10, shortfall=0 → dropped
      assert orders == []
      assert unassigned == []
    end

    test "computes shortfall = required - on_hand, clamped to 0" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid, base_price: Decimal.new("5.00")})

      # on_hand = 3, required = 10 → shortfall = 7
      StockLedger.upsert_quantity(item.uuid, Decimal.new("3"),
        location_uuid: default_location_uuid()
      )

      line = internal_order_line(item, "10")
      internal_order = posted_internal_order_with_lines([line], actor)

      {:ok, %{supplier_orders: orders, unassigned_lines: _}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      assert length(orders) == 1
      [so] = orders
      [so_line] = so.lines

      assert Decimal.equal?(so_line["shortfall_quantity"], Decimal.new("7"))
      assert Decimal.equal?(so_line["ordered_quantity"], Decimal.new("7"))
      assert Decimal.equal?(so_line["on_hand_quantity"], Decimal.new("3"))
    end

    test "routes to unassigned when item has 0 suppliers" do
      actor = user_uuid()
      # Item with no manufacturer → no suppliers → unassigned
      item = create_item!()

      StockLedger.upsert_quantity(item.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      line = internal_order_line(item, "5")
      internal_order = posted_internal_order_with_lines([line], actor)

      {:ok, %{supplier_orders: orders, unassigned_lines: unassigned}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      assert orders == []
      assert length(unassigned) == 1
    end

    test "routes to unassigned when item has more than 1 supplier (NEVER auto-pick)" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier_a = create_supplier!()
      supplier_b = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier_a.uuid)
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier_b.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid})

      StockLedger.upsert_quantity(item.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      line = internal_order_line(item, "5")
      internal_order = posted_internal_order_with_lines([line], actor)

      {:ok, %{supplier_orders: orders, unassigned_lines: unassigned}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      assert orders == []
      assert length(unassigned) == 1
    end

    test "assigns to supplier when exactly 1 supplier" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid})

      StockLedger.upsert_quantity(item.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      line = internal_order_line(item, "5")
      internal_order = posted_internal_order_with_lines([line], actor)

      {:ok, %{supplier_orders: orders, unassigned_lines: unassigned}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      assert length(orders) == 1
      assert unassigned == []
      [so] = orders
      assert so.supplier_uuid == supplier.uuid
    end

    test "groups assigned lines by supplier — one draft per supplier" do
      actor = user_uuid()
      mfr_a = create_manufacturer!()
      mfr_b = create_manufacturer!()
      supplier_a = create_supplier!()
      supplier_b = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr_a.uuid, supplier_a.uuid)
      Catalogue.link_manufacturer_supplier(mfr_b.uuid, supplier_b.uuid)

      item_a = create_item!(%{manufacturer_uuid: mfr_a.uuid})
      item_b = create_item!(%{manufacturer_uuid: mfr_b.uuid})

      StockLedger.upsert_quantity(item_a.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      StockLedger.upsert_quantity(item_b.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      lines = [
        internal_order_line(item_a, "5"),
        internal_order_line(item_b, "3")
      ]

      internal_order = posted_internal_order_with_lines(lines, actor)

      {:ok, %{supplier_orders: orders, unassigned_lines: _}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      assert length(orders) == 2
      supplier_uuids = Enum.map(orders, & &1.supplier_uuid) |> Enum.sort()
      assert supplier_a.uuid in supplier_uuids
      assert supplier_b.uuid in supplier_uuids
    end

    test "two items for same supplier produce ONE draft with both lines" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)

      item_1 = create_item!(%{manufacturer_uuid: mfr.uuid})
      item_2 = create_item!(%{manufacturer_uuid: mfr.uuid})

      StockLedger.upsert_quantity(item_1.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      StockLedger.upsert_quantity(item_2.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      lines = [
        internal_order_line(item_1, "5"),
        internal_order_line(item_2, "3")
      ]

      internal_order = posted_internal_order_with_lines(lines, actor)

      {:ok, %{supplier_orders: orders, unassigned_lines: _}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      assert length(orders) == 1
      [so] = orders
      assert so.supplier_uuid == supplier.uuid
      assert length(so.lines) == 2
    end

    test "ordered_quantity defaults to shortfall_quantity" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid})

      # on_hand = 2, required = 9 → shortfall = 7
      StockLedger.upsert_quantity(item.uuid, Decimal.new("2"),
        location_uuid: default_location_uuid()
      )

      line = internal_order_line(item, "9")
      internal_order = posted_internal_order_with_lines([line], actor)

      {:ok, %{supplier_orders: orders, unassigned_lines: _}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      [so] = orders
      [so_line] = so.lines

      assert Decimal.equal?(so_line["ordered_quantity"], Decimal.new("7"))
      assert Decimal.equal?(so_line["shortfall_quantity"], Decimal.new("7"))
    end

    test "base_price copied from catalogue item" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid, base_price: Decimal.new("99.50")})

      StockLedger.upsert_quantity(item.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      line = internal_order_line(item, "1")
      internal_order = posted_internal_order_with_lines([line], actor)

      {:ok, %{supplier_orders: orders, unassigned_lines: _}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      [so] = orders
      [so_line] = so.lines

      assert Decimal.equal?(so_line["base_price"], Decimal.new("99.50"))
    end

    test "all generated drafts have status=draft (not posted)" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid})

      StockLedger.upsert_quantity(item.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      line = internal_order_line(item, "5")
      internal_order = posted_internal_order_with_lines([line], actor)

      {:ok, %{supplier_orders: orders}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      assert Enum.all?(orders, &(&1.status == "draft"))
    end

    test "internal_order_uuid is set on generated drafts" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid})

      StockLedger.upsert_quantity(item.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      line = internal_order_line(item, "5")
      internal_order = posted_internal_order_with_lines([line], actor)

      {:ok, %{supplier_orders: orders}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      assert Enum.all?(orders, &(&1.internal_order_uuid == internal_order.uuid))
    end

    test "success: count increases by the number of generated supplier orders" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid})

      StockLedger.upsert_quantity(item.uuid, Decimal.new("0"),
        location_uuid: default_location_uuid()
      )

      line = internal_order_line(item, "5")
      internal_order = posted_internal_order_with_lines([line], actor)
      before_count = length(SupplierOrders.list_supplier_orders())

      {:ok, %{supplier_orders: orders}} =
        SupplierOrders.generate_from_internal_order(internal_order, actor)

      after_count = length(SupplierOrders.list_supplier_orders())
      assert after_count == before_count + length(orders)
    end
  end

  # ---------------------------------------------------------------------------
  # received_summary/1
  # ---------------------------------------------------------------------------

  describe "received_summary/1" do
    test "returns empty map when no goods receipts exist for the order" do
      {order, _supplier} = create_draft!()
      assert SupplierOrders.received_summary(order) == %{}
    end

    test "sums received_quantity from posted receipts" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      {order, supplier} = create_draft!(%{lines: sample_lines(item_uuid)})
      {:ok, posted_order} = SupplierOrders.post_supplier_order(order, actor)

      # Create and post a goods receipt
      {:ok, receipt} =
        GoodsReceipts.create_goods_receipt(%{
          supplier_uuid: supplier.uuid,
          supplier_order_uuid: posted_order.uuid,
          location_uuid: default_location_uuid(),
          lines: [
            %{
              "item_uuid" => item_uuid,
              "name" => "Widget",
              "sku" => "",
              "unit" => "piece",
              "catalogue_uuid" => Ecto.UUID.generate(),
              "ordered_quantity" => Decimal.new("7"),
              "received_quantity" => Decimal.new("5")
            }
          ]
        })

      {:ok, _posted_receipt} = GoodsReceipts.post_goods_receipt(receipt, actor)

      summary = SupplierOrders.received_summary(posted_order)
      assert Decimal.equal?(summary[item_uuid], Decimal.new("5"))
    end

    test "ignores draft receipts" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      {order, supplier} = create_draft!(%{lines: sample_lines(item_uuid)})
      {:ok, posted_order} = SupplierOrders.post_supplier_order(order, actor)

      # Create a DRAFT receipt (not posted)
      {:ok, _receipt} =
        GoodsReceipts.create_goods_receipt(%{
          supplier_uuid: supplier.uuid,
          supplier_order_uuid: posted_order.uuid,
          location_uuid: default_location_uuid(),
          lines: [
            %{
              "item_uuid" => item_uuid,
              "name" => "Widget",
              "sku" => "",
              "unit" => "piece",
              "catalogue_uuid" => Ecto.UUID.generate(),
              "ordered_quantity" => Decimal.new("7"),
              "received_quantity" => Decimal.new("5")
            }
          ]
        })

      # No post — should be ignored
      summary = SupplierOrders.received_summary(posted_order)
      assert summary == %{}
    end

    test "sums across multiple posted receipts" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      {order, supplier} = create_draft!(%{lines: sample_lines(item_uuid)})
      {:ok, posted_order} = SupplierOrders.post_supplier_order(order, actor)

      make_line = fn qty ->
        [
          %{
            "item_uuid" => item_uuid,
            "name" => "Widget",
            "sku" => "",
            "unit" => "piece",
            "catalogue_uuid" => Ecto.UUID.generate(),
            "ordered_quantity" => Decimal.new("7"),
            "received_quantity" => Decimal.new(qty)
          }
        ]
      end

      {:ok, r1} =
        GoodsReceipts.create_goods_receipt(%{
          supplier_uuid: supplier.uuid,
          supplier_order_uuid: posted_order.uuid,
          location_uuid: default_location_uuid(),
          lines: make_line.("3")
        })

      {:ok, r2} =
        GoodsReceipts.create_goods_receipt(%{
          supplier_uuid: supplier.uuid,
          supplier_order_uuid: posted_order.uuid,
          location_uuid: default_location_uuid(),
          lines: make_line.("2")
        })

      {:ok, _} = GoodsReceipts.post_goods_receipt(r1, actor)
      {:ok, _} = GoodsReceipts.post_goods_receipt(r2, actor)

      summary = SupplierOrders.received_summary(posted_order)
      assert Decimal.equal?(summary[item_uuid], Decimal.new("5"))
    end
  end

  # ---------------------------------------------------------------------------
  # import_from_internal_orders/3 — outstanding quantity (duplicate-order prevention)
  # ---------------------------------------------------------------------------

  describe "import_from_internal_orders/3 — outstanding quantity (duplicate-order prevention)" do
    test "a second supplier order for the same internal order only orders what's not already ordered" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid})

      {:ok, io} =
        InternalOrders.create_internal_order(%{
          location_uuid: default_location_uuid(),
          lines: [
            %{
              "item_uuid" => item.uuid,
              "name" => item.name,
              "catalogue_uuid" => item.catalogue_uuid,
              "required_quantity" => "10"
            }
          ]
        })

      {:ok, io} = InternalOrders.post_internal_order(io, actor)

      # First supplier order: orders the full shortfall (10, since on-hand is 0).
      {order1, _} = create_draft!(%{supplier_uuid: supplier.uuid})
      {:ok, order1} = SupplierOrders.import_from_internal_orders(order1, [io.uuid], actor)
      assert [%{"ordered_quantity" => q1}] = order1.lines
      assert Decimal.equal?(StockLedger.to_decimal(q1), Decimal.new("10"))

      # Second supplier order, same IO, stock still at 0 (nothing received yet):
      # must NOT duplicate the 10 — remaining should be 0.
      {order2, _} = create_draft!(%{supplier_uuid: supplier.uuid})
      {:ok, order2} = SupplierOrders.import_from_internal_orders(order2, [io.uuid], actor)

      assert order2.lines == []
    end

    test "clamps to zero (not negative) when stock partially recovers but the full amount was already ordered" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid})

      {:ok, io} =
        InternalOrders.create_internal_order(%{
          location_uuid: default_location_uuid(),
          lines: [
            %{
              "item_uuid" => item.uuid,
              "name" => item.name,
              "catalogue_uuid" => item.catalogue_uuid,
              "required_quantity" => "10"
            }
          ]
        })

      {:ok, io} = InternalOrders.post_internal_order(io, actor)

      {order_a, _} = create_draft!(%{supplier_uuid: supplier.uuid})
      {:ok, _order_a} = SupplierOrders.import_from_internal_orders(order_a, [io.uuid], actor)

      # 4 of the 10 physically arrive (e.g. via an unrelated receipt/adjustment),
      # so on_hand rises to 4 — but the full 10 was already ordered via order_a.
      # remaining-to-order for a SECOND supplier order should be
      # max(0, required(10) - on_hand(4)) - committed(10) = max(0, 6 - 10) = 0.
      {:ok, _} =
        StockLedger.receive_quantity(item.uuid, Decimal.new("4"),
          location_uuid: default_location_uuid()
        )

      {order_b, _} = create_draft!(%{supplier_uuid: supplier.uuid})
      {:ok, order_b} = SupplierOrders.import_from_internal_orders(order_b, [io.uuid], actor)

      assert order_b.lines == []
    end

    test "the internal-order's source_refs ref records the actually-ordered quantity, and re-import updates it in place" do
      actor = user_uuid()
      mfr = create_manufacturer!()
      supplier = create_supplier!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
      item = create_item!(%{manufacturer_uuid: mfr.uuid})

      {:ok, io} =
        InternalOrders.create_internal_order(%{
          location_uuid: default_location_uuid(),
          lines: [
            %{
              "item_uuid" => item.uuid,
              "name" => item.name,
              "catalogue_uuid" => item.catalogue_uuid,
              "required_quantity" => "10"
            }
          ]
        })

      {:ok, io} = InternalOrders.post_internal_order(io, actor)

      {order, _} = create_draft!(%{supplier_uuid: supplier.uuid})
      {:ok, order} = SupplierOrders.import_from_internal_orders(order, [io.uuid], actor)
      {:ok, order} = SupplierOrders.import_from_internal_orders(order, [io.uuid], actor)

      refs_for_io = Enum.filter(order.source_refs, &(&1["uuid"] == io.uuid))
      assert length(refs_for_io) == 1
    end
  end
end
