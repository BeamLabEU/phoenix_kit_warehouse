defmodule PhoenixKitWarehouse.GoodsReceiptsTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.Test.Repo
  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitCatalogue.Catalogue

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  defp user_uuid do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "gr-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "GR",
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

  defp create_catalogue! do
    {:ok, cat} =
      Catalogue.create_catalogue(%{
        name: "Test Catalogue #{System.unique_integer([:positive])}",
        status: "active"
      })

    cat
  end

  defp create_item! do
    catalogue = create_catalogue!()

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Item #{System.unique_integer([:positive])}",
        catalogue_uuid: catalogue.uuid,
        status: "active"
      })

    item
  end

  defp sample_gr_line(item_uuid, opts \\ []) do
    ordered = Keyword.get(opts, :ordered, "10")
    received = Keyword.get(opts, :received, "0")

    %{
      "item_uuid" => item_uuid,
      "name" => "Widget",
      "sku" => "WGT-001",
      "unit" => "piece",
      "catalogue_uuid" => Ecto.UUID.generate(),
      "ordered_quantity" => Decimal.new(ordered),
      "received_quantity" => Decimal.new(received),
      "unit_value" => nil
    }
  end

  defp create_draft!(attrs \\ %{}) do
    base = %{location_uuid: @default_location_uuid}
    {:ok, receipt} = GoodsReceipts.create_goods_receipt(Map.merge(base, attrs))
    receipt
  end

  defp create_posted_supplier_order!(actor_uuid) do
    supplier = create_supplier!()
    item = create_item!()

    {:ok, order} =
      SupplierOrders.create_supplier_order(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location_uuid,
        lines: [
          %{
            "item_uuid" => item.uuid,
            "name" => item.name,
            "sku" => "",
            "unit" => "piece",
            "catalogue_uuid" => item.catalogue_uuid,
            "required_quantity" => Decimal.new("10"),
            "on_hand_quantity" => Decimal.new("0"),
            "shortfall_quantity" => Decimal.new("10"),
            "ordered_quantity" => Decimal.new("10"),
            "base_price" => Decimal.new("5.00")
          }
        ]
      })

    {:ok, posted} = SupplierOrders.post_supplier_order(order, actor_uuid)
    {posted, item, supplier}
  end

  # Posted supplier order for a caller-supplied supplier/item, used to build
  # two SOs that share the same item (for multi-SO merge scenarios).
  defp create_posted_supplier_order_for_item!(supplier, item, actor_uuid, ordered_qty) do
    {:ok, order} =
      SupplierOrders.create_supplier_order(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location_uuid,
        lines: [
          %{
            "item_uuid" => item.uuid,
            "name" => item.name,
            "sku" => "",
            "unit" => "piece",
            "catalogue_uuid" => item.catalogue_uuid,
            "required_quantity" => Decimal.new(ordered_qty),
            "on_hand_quantity" => Decimal.new("0"),
            "shortfall_quantity" => Decimal.new(ordered_qty),
            "ordered_quantity" => Decimal.new(ordered_qty),
            "base_price" => Decimal.new("5.00")
          }
        ]
      })

    {:ok, posted} = SupplierOrders.post_supplier_order(order, actor_uuid)
    posted
  end

  defp create_internal_order_with_refs!(source_refs) do
    {:ok, io} =
      InternalOrders.create_internal_order(%{
        location_uuid: @default_location_uuid,
        lines: [],
        source_refs: source_refs
      })

    io
  end

  # Posted supplier order carrying its own lineage (internal_order_uuid FK +
  # source_refs), as the real import_from_internal_orders/3 flow would set.
  defp create_posted_supplier_order_from_io!(io, actor_uuid) do
    supplier = create_supplier!()
    item = create_item!()

    {:ok, order} =
      SupplierOrders.create_supplier_order(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location_uuid,
        internal_order_uuid: io.uuid,
        source_refs: [%{"type" => "internal_order", "uuid" => io.uuid}],
        lines: [
          %{
            "item_uuid" => item.uuid,
            "name" => item.name,
            "sku" => "",
            "unit" => "piece",
            "catalogue_uuid" => item.catalogue_uuid,
            "required_quantity" => Decimal.new("10"),
            "on_hand_quantity" => Decimal.new("0"),
            "shortfall_quantity" => Decimal.new("10"),
            "ordered_quantity" => Decimal.new("10"),
            "base_price" => Decimal.new("5.00")
          }
        ]
      })

    {:ok, posted} = SupplierOrders.post_supplier_order(order, actor_uuid)
    posted
  end

  # ---------------------------------------------------------------------------
  # Warehouse.receive_quantity/3 tests
  # ---------------------------------------------------------------------------

  describe "Warehouse.receive_quantity/3" do
    test "first receipt creates a stock row at the given quantity" do
      item_uuid = Ecto.UUID.generate()

      {:ok, stock} =
        Warehouse.receive_quantity(item_uuid, Decimal.new("10"),
          location_uuid: @default_location_uuid
        )

      assert Decimal.equal?(stock.quantity, Decimal.new("10"))
      assert stock.item_uuid == item_uuid
    end

    test "second receipt adds (10 then 4 = 14)" do
      item_uuid = Ecto.UUID.generate()

      {:ok, _} =
        Warehouse.receive_quantity(item_uuid, Decimal.new("10"),
          location_uuid: @default_location_uuid
        )

      {:ok, stock} =
        Warehouse.receive_quantity(item_uuid, Decimal.new("4"),
          location_uuid: @default_location_uuid
        )

      assert Decimal.equal?(stock.quantity, Decimal.new("14"))
    end

    test "uses default location when no location_uuid given" do
      item_uuid = Ecto.UUID.generate()

      {:ok, stock} = Warehouse.receive_quantity(item_uuid, Decimal.new("5"))

      assert stock.item_uuid == item_uuid
      assert Decimal.equal?(stock.quantity, Decimal.new("5"))
    end

    test "is additive — does NOT replace existing quantity" do
      item_uuid = Ecto.UUID.generate()

      # First set an absolute quantity via upsert
      {:ok, _} =
        Warehouse.upsert_quantity(item_uuid, Decimal.new("100"),
          location_uuid: @default_location_uuid
        )

      # Then add via receive_quantity — should be additive
      {:ok, stock} =
        Warehouse.receive_quantity(item_uuid, Decimal.new("20"),
          location_uuid: @default_location_uuid
        )

      assert Decimal.equal?(stock.quantity, Decimal.new("120"))
    end

    test "returns {:ok, %Stock{}} usable inside Ecto.Multi" do
      item_uuid = Ecto.UUID.generate()

      multi =
        Ecto.Multi.run(Ecto.Multi.new(), :receive, fn repo, _changes ->
          Warehouse.receive_quantity(item_uuid, Decimal.new("7"),
            location_uuid: @default_location_uuid,
            repo: repo
          )
        end)

      assert {:ok, %{receive: stock}} = Repo.transaction(multi)
      assert Decimal.equal?(stock.quantity, Decimal.new("7"))
    end

    test "accumulates correctly across multiple receipts" do
      item_uuid = Ecto.UUID.generate()
      amounts = [Decimal.new("3"), Decimal.new("7"), Decimal.new("2")]

      for amt <- amounts do
        {:ok, _} =
          Warehouse.receive_quantity(item_uuid, amt, location_uuid: @default_location_uuid)
      end

      final = Warehouse.get_quantity(item_uuid)
      assert Decimal.equal?(final, Decimal.new("12"))
    end
  end

  # ---------------------------------------------------------------------------
  # create_goods_receipt/1
  # ---------------------------------------------------------------------------

  describe "create_goods_receipt/1" do
    test "creates a draft with location_uuid" do
      receipt = create_draft!()

      assert receipt.status == "draft"
      assert receipt.location_uuid == @default_location_uuid
      assert receipt.uuid != nil
      assert receipt.number != nil
    end

    test "assigns a unique number from the sequence" do
      r1 = create_draft!()
      r2 = create_draft!()

      assert r1.number != r2.number
    end

    test "falls back to the configured default location when location_uuid is missing" do
      assert {:ok, receipt} = GoodsReceipts.create_goods_receipt(%{})
      assert receipt.location_uuid == Warehouse.default_location_uuid()
    end

    test "stores lines" do
      item_uuid = Ecto.UUID.generate()
      lines = [sample_gr_line(item_uuid)]

      receipt = create_draft!(%{lines: lines})

      assert length(receipt.lines) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # update_draft/2
  # ---------------------------------------------------------------------------

  describe "update_draft/2" do
    test "updates lines and note on a draft" do
      receipt = create_draft!()
      item_uuid = Ecto.UUID.generate()
      lines = [sample_gr_line(item_uuid, received: "5")]

      {:ok, updated} = GoodsReceipts.update_draft(receipt, %{lines: lines, note: "updated"})

      assert length(updated.lines) == 1
      assert updated.note == "updated"
    end

    test "returns {:error, :not_draft} for a posted receipt" do
      actor = user_uuid()
      receipt = create_draft!()
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      assert {:error, :not_draft} = GoodsReceipts.update_draft(posted, %{note: "nope"})
    end
  end

  # ---------------------------------------------------------------------------
  # create_from_supplier_order/2
  # ---------------------------------------------------------------------------

  describe "create_from_supplier_order/2" do
    test "creates a draft with lines copied from the supplier order" do
      actor = user_uuid()
      {so, item, supplier} = create_posted_supplier_order!(actor)

      {:ok, receipt} = GoodsReceipts.create_from_supplier_order(so, actor)

      assert receipt.status == "draft"
      assert receipt.supplier_order_uuid == so.uuid
      assert receipt.supplier_uuid == supplier.uuid
      assert receipt.location_uuid == so.location_uuid
      assert length(receipt.lines) == 1

      [line] = receipt.lines
      assert line["item_uuid"] == item.uuid
    end

    test "lines have ordered_quantity snapshot from the supplier order" do
      actor = user_uuid()
      {so, _item, _supplier} = create_posted_supplier_order!(actor)

      {:ok, receipt} = GoodsReceipts.create_from_supplier_order(so, actor)

      [line] = receipt.lines
      assert Decimal.equal?(Warehouse.to_decimal(line["ordered_quantity"]), Decimal.new("10"))
    end

    test "received_quantity defaults to 0 (not the ordered quantity)" do
      actor = user_uuid()
      {so, _item, _supplier} = create_posted_supplier_order!(actor)

      {:ok, receipt} = GoodsReceipts.create_from_supplier_order(so, actor)

      [line] = receipt.lines
      assert Decimal.equal?(Warehouse.to_decimal(line["received_quantity"]), Decimal.new("0"))
    end

    test "sets created_by_uuid" do
      actor = user_uuid()
      {so, _item, _supplier} = create_posted_supplier_order!(actor)

      {:ok, receipt} = GoodsReceipts.create_from_supplier_order(so, actor)

      assert receipt.created_by_uuid == actor
    end

    test "deduplicates lines by item_uuid (supplier order may have dups)" do
      actor = user_uuid()
      item = create_item!()
      supplier = create_supplier!()

      dup_line = %{
        "item_uuid" => item.uuid,
        "name" => item.name,
        "sku" => "",
        "unit" => "piece",
        "catalogue_uuid" => item.catalogue_uuid,
        "required_quantity" => Decimal.new("5"),
        "on_hand_quantity" => Decimal.new("0"),
        "shortfall_quantity" => Decimal.new("5"),
        "ordered_quantity" => Decimal.new("5"),
        "base_price" => nil
      }

      {:ok, order} =
        SupplierOrders.create_supplier_order(%{
          supplier_uuid: supplier.uuid,
          location_uuid: @default_location_uuid,
          lines: [dup_line, dup_line]
        })

      {:ok, posted} = SupplierOrders.post_supplier_order(order, actor)
      {:ok, receipt} = GoodsReceipts.create_from_supplier_order(posted, actor)

      assert length(receipt.lines) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # import_from_supplier_orders/3 — 3-tier chain derivation
  # ---------------------------------------------------------------------------

  describe "import_from_supplier_orders/3 — chain derivation" do
    test "derives internal-order and customer-order/sub-order refs transitively" do
      actor = user_uuid()
      order_ref = %{"type" => "order", "uuid" => Ecto.UUID.generate()}
      sub_order_ref = %{"type" => "sub_order", "uuid" => Ecto.UUID.generate()}

      io = create_internal_order_with_refs!([order_ref, sub_order_ref])
      so = create_posted_supplier_order_from_io!(io, actor)
      receipt = create_draft!()

      assert {:ok, updated} =
               GoodsReceipts.import_from_supplier_orders(receipt, [so.uuid], actor)

      refs = updated.source_refs

      assert %{"type" => "supplier_order", "uuid" => so.uuid} in refs
      assert %{"type" => "internal_order", "uuid" => io.uuid} in refs
      assert order_ref in refs
      assert sub_order_ref in refs
      assert length(refs) == 4
    end

    test "deduplicates the chain across multiple supplier orders sharing an internal order" do
      actor = user_uuid()
      shared_order_ref = %{"type" => "order", "uuid" => Ecto.UUID.generate()}
      distinct_order_ref = %{"type" => "order", "uuid" => Ecto.UUID.generate()}

      shared_io = create_internal_order_with_refs!([shared_order_ref])
      other_io = create_internal_order_with_refs!([shared_order_ref, distinct_order_ref])

      so1 = create_posted_supplier_order_from_io!(shared_io, actor)
      so2 = create_posted_supplier_order_from_io!(other_io, actor)
      receipt = create_draft!()

      assert {:ok, updated} =
               GoodsReceipts.import_from_supplier_orders(receipt, [so1.uuid, so2.uuid], actor)

      refs = updated.source_refs

      assert %{"type" => "supplier_order", "uuid" => so1.uuid} in refs
      assert %{"type" => "supplier_order", "uuid" => so2.uuid} in refs
      assert %{"type" => "internal_order", "uuid" => shared_io.uuid} in refs
      assert %{"type" => "internal_order", "uuid" => other_io.uuid} in refs
      assert shared_order_ref in refs
      assert distinct_order_ref in refs
      # shared_order_ref must appear only once despite being referenced by both IOs
      assert length(refs) == 6
    end

    test "falls back to the legacy internal_order_uuid FK when a supplier order has no source_refs" do
      actor = user_uuid()
      order_ref = %{"type" => "order", "uuid" => Ecto.UUID.generate()}
      io = create_internal_order_with_refs!([order_ref])

      supplier = create_supplier!()
      item = create_item!()

      {:ok, order} =
        SupplierOrders.create_supplier_order(%{
          supplier_uuid: supplier.uuid,
          location_uuid: @default_location_uuid,
          internal_order_uuid: io.uuid,
          lines: [
            %{
              "item_uuid" => item.uuid,
              "name" => item.name,
              "sku" => "",
              "unit" => "piece",
              "catalogue_uuid" => item.catalogue_uuid,
              "required_quantity" => Decimal.new("10"),
              "on_hand_quantity" => Decimal.new("0"),
              "shortfall_quantity" => Decimal.new("10"),
              "ordered_quantity" => Decimal.new("10"),
              "base_price" => Decimal.new("5.00")
            }
          ]
        })

      {:ok, legacy_so} = SupplierOrders.post_supplier_order(order, actor)
      receipt = create_draft!()

      assert {:ok, updated} =
               GoodsReceipts.import_from_supplier_orders(receipt, [legacy_so.uuid], actor)

      refs = updated.source_refs

      assert %{"type" => "internal_order", "uuid" => io.uuid} in refs
      assert order_ref in refs
    end
  end

  describe "import_from_supplier_orders/3 — outstanding quantity (duplicate-receipt prevention)" do
    test "a second receipt for a secondarily-merged SO reflects already-received quantity from the first merged receipt" do
      actor = user_uuid()
      supplier = create_supplier!()
      item = create_item!()

      so1 = create_posted_supplier_order_for_item!(supplier, item, actor, "10")
      so2 = create_posted_supplier_order_for_item!(supplier, item, actor, "10")

      # First goods receipt merges BOTH supplier orders into one line.
      # so1 becomes the primary supplier_order_uuid FK; so2 is only recorded
      # as a secondary "supplier_order" entry in source_refs.
      receipt1 = create_draft!()

      {:ok, receipt1} =
        GoodsReceipts.import_from_supplier_orders(receipt1, [so1.uuid, so2.uuid], actor)

      assert [%{"ordered_quantity" => merged_ordered}] = receipt1.lines
      assert Decimal.equal?(Warehouse.to_decimal(merged_ordered), Decimal.new("20"))

      {:ok, receipt1} =
        GoodsReceipts.update_draft(receipt1, %{
          lines: [
            %{
              "item_uuid" => item.uuid,
              "name" => item.name,
              "sku" => "",
              "unit" => "piece",
              "catalogue_uuid" => item.catalogue_uuid,
              "ordered_quantity" => Decimal.new("20"),
              "received_quantity" => Decimal.new("6"),
              "unit_value" => nil
            }
          ]
        })

      {:ok, _posted_receipt1} = GoodsReceipts.post_goods_receipt(receipt1, actor)

      # Second receipt imports ONLY so2 — the SO that was a secondary
      # (non-primary) reference on receipt1. Its remaining outstanding
      # quantity must reflect the 6 units already received via the merged
      # receipt (10 ordered - 6 received = 4), not the full original 10.
      receipt2 = create_draft!()
      {:ok, receipt2} = GoodsReceipts.import_from_supplier_orders(receipt2, [so2.uuid], actor)

      assert [%{"ordered_quantity" => q2}] = receipt2.lines
      assert Decimal.equal?(Warehouse.to_decimal(q2), Decimal.new("4"))
    end

    test "a second goods receipt for the same supplier order only receives what's not already received" do
      actor = user_uuid()
      {so, item, _supplier} = create_posted_supplier_order!(actor)

      receipt1 = create_draft!()
      {:ok, receipt1} = GoodsReceipts.import_from_supplier_orders(receipt1, [so.uuid], actor)
      assert [%{"ordered_quantity" => q1}] = receipt1.lines
      assert Decimal.equal?(Warehouse.to_decimal(q1), Decimal.new("10"))

      {:ok, receipt1} =
        GoodsReceipts.update_draft(receipt1, %{
          lines: [
            %{
              "item_uuid" => item.uuid,
              "name" => item.name,
              "sku" => "",
              "unit" => "piece",
              "catalogue_uuid" => item.catalogue_uuid,
              "ordered_quantity" => Decimal.new("10"),
              "received_quantity" => Decimal.new("6"),
              "unit_value" => nil
            }
          ]
        })

      {:ok, _posted_receipt1} = GoodsReceipts.post_goods_receipt(receipt1, actor)

      receipt2 = create_draft!()
      {:ok, receipt2} = GoodsReceipts.import_from_supplier_orders(receipt2, [so.uuid], actor)

      assert [%{"ordered_quantity" => q2}] = receipt2.lines
      assert Decimal.equal?(Warehouse.to_decimal(q2), Decimal.new("4"))
    end
  end

  # ---------------------------------------------------------------------------
  # add_source_ref/3 and remove_source_ref/3 — manual linking
  # ---------------------------------------------------------------------------

  describe "add_source_ref/3 and remove_source_ref/3" do
    test "attaches a reference without touching lines" do
      item_uuid = Ecto.UUID.generate()
      receipt = create_draft!(%{lines: [sample_gr_line(item_uuid)]})
      uuid = Ecto.UUID.generate()

      assert {:ok, updated} = GoodsReceipts.add_source_ref(receipt, "order", uuid)

      assert %{"type" => "order", "uuid" => uuid} in updated.source_refs
      assert length(updated.lines) == 1
    end

    test "adding the same {type, uuid} twice is a no-op" do
      receipt = create_draft!()
      uuid = Ecto.UUID.generate()

      {:ok, once} = GoodsReceipts.add_source_ref(receipt, "internal_order", uuid)
      {:ok, twice} = GoodsReceipts.add_source_ref(once, "internal_order", uuid)

      assert length(twice.source_refs) == 1
    end

    test "removes an attached reference" do
      receipt = create_draft!()
      uuid = Ecto.UUID.generate()

      {:ok, attached} = GoodsReceipts.add_source_ref(receipt, "supplier_order", uuid)
      assert {:ok, removed} = GoodsReceipts.remove_source_ref(attached, "supplier_order", uuid)

      assert removed.source_refs == []
    end

    test "removing a reference that isn't present is a no-op" do
      receipt = create_draft!()

      assert {:ok, updated} =
               GoodsReceipts.remove_source_ref(receipt, "order", Ecto.UUID.generate())

      assert updated.source_refs == []
    end

    test "works on a posted receipt (metadata-only, not draft-gated)" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      receipt = create_draft!(%{lines: [sample_gr_line(item_uuid, received: "5")]})
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)
      uuid = Ecto.UUID.generate()

      assert {:ok, updated} = GoodsReceipts.add_source_ref(posted, "order", uuid)
      assert %{"type" => "order", "uuid" => uuid} in updated.source_refs
      assert updated.status == "posted"
    end
  end

  # ---------------------------------------------------------------------------
  # post_goods_receipt/2 — stock increases
  # ---------------------------------------------------------------------------

  describe "post_goods_receipt/2" do
    test "flips status to posted and sets posted_at and performed_by_uuid" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      receipt = create_draft!(%{lines: [sample_gr_line(item_uuid, received: "5")]})

      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      assert posted.status == "posted"
      assert posted.posted_at != nil
      assert posted.performed_by_uuid == actor
    end

    test "INCREASES warehouse stock by received_quantity" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()

      # No prior stock
      receipt =
        create_draft!(%{lines: [sample_gr_line(item_uuid, received: "8")]})

      {:ok, _posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      qty = Warehouse.get_quantity(item_uuid)
      assert Decimal.equal?(qty, Decimal.new("8"))
    end

    test "stock increase is ADDITIVE over prior stock" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()

      # Prior stock from some other source
      {:ok, _} =
        Warehouse.upsert_quantity(item_uuid, Decimal.new("50"),
          location_uuid: @default_location_uuid
        )

      receipt = create_draft!(%{lines: [sample_gr_line(item_uuid, received: "10")]})
      {:ok, _posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      qty = Warehouse.get_quantity(item_uuid)
      assert Decimal.equal?(qty, Decimal.new("60"))
    end

    test "line with received_quantity == 0 contributes no stock change" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()

      # Line defaults received=0
      receipt = create_draft!(%{lines: [sample_gr_line(item_uuid, received: "0")]})

      stock_before = Repo.all(Stock)
      {:ok, _posted} = GoodsReceipts.post_goods_receipt(receipt, actor)
      stock_after = Repo.all(Stock)

      # No new stock row created
      new_rows =
        Enum.reject(stock_after, fn s ->
          Enum.any?(stock_before, &(&1.uuid == s.uuid))
        end)

      assert new_rows == []
    end

    test "previous_quantity audit is captured in persisted lines" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()

      # Set up prior stock
      {:ok, _} =
        Warehouse.upsert_quantity(item_uuid, Decimal.new("15"),
          location_uuid: @default_location_uuid
        )

      receipt = create_draft!(%{lines: [sample_gr_line(item_uuid, received: "5")]})
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      [line] = posted.lines
      prev_qty = Warehouse.to_decimal(line["previous_quantity"])
      assert Decimal.equal?(prev_qty, Decimal.new("15"))
    end

    test "previous_quantity is 0 when item had no prior stock" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()

      receipt = create_draft!(%{lines: [sample_gr_line(item_uuid, received: "3")]})
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      [line] = posted.lines
      prev_qty = Warehouse.to_decimal(line["previous_quantity"])
      assert Decimal.equal?(prev_qty, Decimal.new("0"))
    end

    test "deduplicates lines by item_uuid on posting" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()

      dup_lines = [
        sample_gr_line(item_uuid, received: "5"),
        sample_gr_line(item_uuid, received: "3")
      ]

      receipt = create_draft!(%{lines: dup_lines})
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      assert length(posted.lines) == 1
    end

    test "double-post guard: returns {:error, :not_draft}" do
      actor = user_uuid()
      receipt = create_draft!()

      {:ok, _posted} = GoodsReceipts.post_goods_receipt(receipt, actor)
      assert {:error, :not_draft} = GoodsReceipts.post_goods_receipt(receipt, actor)
    end

    test "in-memory guard: post on a struct with status != draft returns {:error, :not_draft}" do
      actor = user_uuid()
      receipt = create_draft!()
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      assert {:error, :not_draft} = GoodsReceipts.post_goods_receipt(posted, actor)
    end

    test "multi-receipt safety: second receipt with received=0 does not double-count" do
      actor = user_uuid()
      {so, item, _supplier} = create_posted_supplier_order!(actor)

      # First goods receipt: received=10
      {:ok, gr1} = GoodsReceipts.create_from_supplier_order(so, actor)
      gr1 = update_received_qty(gr1, item.uuid, Decimal.new("10"))
      {:ok, _} = GoodsReceipts.post_goods_receipt(gr1, actor)

      qty_after_first = Warehouse.get_quantity(item.uuid)
      assert Decimal.equal?(qty_after_first, Decimal.new("10"))

      # Second goods receipt for same SO: received defaults to 0 → no stock change
      {:ok, gr2} = GoodsReceipts.create_from_supplier_order(so, actor)
      {:ok, _} = GoodsReceipts.post_goods_receipt(gr2, actor)

      qty_final = Warehouse.get_quantity(item.uuid)
      # Still 10 — received_quantity was 0, nothing added
      assert Decimal.equal?(qty_final, Decimal.new("10"))
    end

    test "multi-receipt with received > 0: second receipt adds to stock" do
      actor = user_uuid()
      {so, item, _supplier} = create_posted_supplier_order!(actor)

      {:ok, gr1} = GoodsReceipts.create_from_supplier_order(so, actor)
      gr1 = update_received_qty(gr1, item.uuid, Decimal.new("6"))
      {:ok, _} = GoodsReceipts.post_goods_receipt(gr1, actor)

      {:ok, gr2} = GoodsReceipts.create_from_supplier_order(so, actor)
      gr2 = update_received_qty(gr2, item.uuid, Decimal.new("4"))
      {:ok, _} = GoodsReceipts.post_goods_receipt(gr2, actor)

      qty_final = Warehouse.get_quantity(item.uuid)
      assert Decimal.equal?(qty_final, Decimal.new("10"))
    end

    test "Decimal math is preserved (no float rounding)" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()

      receipt =
        create_draft!(%{lines: [sample_gr_line(item_uuid, received: "1.5")]})

      {:ok, _posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      qty = Warehouse.get_quantity(item_uuid)
      assert Decimal.equal?(qty, Decimal.new("1.5"))
    end

    test "multiple items in one receipt all increase stock" do
      actor = user_uuid()
      item1 = Ecto.UUID.generate()
      item2 = Ecto.UUID.generate()

      lines = [
        sample_gr_line(item1, received: "5"),
        sample_gr_line(item2, received: "3")
      ]

      receipt = create_draft!(%{lines: lines})
      {:ok, _posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      assert Decimal.equal?(Warehouse.get_quantity(item1), Decimal.new("5"))
      assert Decimal.equal?(Warehouse.get_quantity(item2), Decimal.new("3"))
    end
  end

  # ---------------------------------------------------------------------------
  # soft_delete/2
  # ---------------------------------------------------------------------------

  describe "soft_delete/2" do
    test "soft-deletes a draft receipt" do
      actor = user_uuid()
      receipt = create_draft!()

      {:ok, deleted} = GoodsReceipts.soft_delete(receipt, actor)

      assert deleted.deleted_at != nil
      assert deleted.deleted_by_uuid == actor
    end

    test "excludes soft-deleted receipts from list" do
      actor = user_uuid()
      receipt = create_draft!()
      {:ok, _} = GoodsReceipts.soft_delete(receipt, actor)

      all = GoodsReceipts.list_goods_receipts()
      refute Enum.any?(all, &(&1.uuid == receipt.uuid))
    end

    test "returns {:error, :not_draft} for a posted receipt" do
      actor = user_uuid()
      receipt = create_draft!()
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      assert {:error, :not_draft} = GoodsReceipts.soft_delete(posted, actor)
    end
  end

  # ---------------------------------------------------------------------------
  # correct_goods_receipt/2
  # ---------------------------------------------------------------------------

  describe "correct_goods_receipt/2" do
    test "updates note on a posted receipt without changing status or lines" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      receipt = create_draft!(%{lines: [sample_gr_line(item_uuid, received: "2")]})
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      {:ok, corrected} = GoodsReceipts.correct_goods_receipt(posted, %{note: "corrected note"})

      assert corrected.note == "corrected note"
      assert corrected.status == "posted"
    end

    test "does not change lines via correction (lines are immutable after posting)" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      receipt = create_draft!(%{lines: [sample_gr_line(item_uuid, received: "2")]})
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)

      {:ok, corrected} =
        GoodsReceipts.correct_goods_receipt(posted, %{
          note: "corrected",
          lines: []
        })

      # Lines should NOT be changed — correction_changeset only casts :note + :storage_folder_uuid
      assert length(corrected.lines) == length(posted.lines)
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  describe "list_goods_receipts/0" do
    test "includes non-deleted receipts" do
      receipt = create_draft!()
      all = GoodsReceipts.list_goods_receipts()
      assert Enum.any?(all, &(&1.uuid == receipt.uuid))
    end

    test "excludes soft-deleted receipts" do
      actor = user_uuid()
      receipt = create_draft!()
      {:ok, _} = GoodsReceipts.soft_delete(receipt, actor)

      all = GoodsReceipts.list_goods_receipts()
      refute Enum.any?(all, &(&1.uuid == receipt.uuid))
    end
  end

  describe "get_goods_receipt!/1 and get_goods_receipt/1" do
    test "get_goods_receipt!/1 raises on missing" do
      assert_raise Ecto.NoResultsError, fn ->
        GoodsReceipts.get_goods_receipt!(Ecto.UUID.generate())
      end
    end

    test "get_goods_receipt/1 returns {:error, :not_found} on missing" do
      assert {:error, :not_found} = GoodsReceipts.get_goods_receipt(Ecto.UUID.generate())
    end

    test "get_goods_receipt/1 returns {:ok, receipt}" do
      receipt = create_draft!()
      assert {:ok, found} = GoodsReceipts.get_goods_receipt(receipt.uuid)
      assert found.uuid == receipt.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Update received_quantity for a specific item in a receipt's in-memory lines,
  # then persist via update_draft.
  defp update_received_qty(%GoodsReceipt{} = receipt, item_uuid, qty) do
    updated_lines =
      Enum.map(receipt.lines, fn line ->
        if line["item_uuid"] == item_uuid do
          Map.put(line, "received_quantity", qty)
        else
          line
        end
      end)

    {:ok, updated} = GoodsReceipts.update_draft(receipt, %{lines: updated_lines})
    updated
  end
end
