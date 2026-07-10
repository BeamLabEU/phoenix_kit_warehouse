defmodule PhoenixKitWarehouse.InventoriesTest do
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitCatalogue.Catalogue

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_catalogue! do
    {:ok, cat} =
      Catalogue.create_catalogue(%{name: "WH Test #{System.unique_integer([:positive])}"})

    cat
  end

  defp create_active_item!(cat, opts \\ []) do
    base = Keyword.get(opts, :base_price, "10.00")

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Active #{System.unique_integer([:positive])}",
        catalogue_uuid: cat.uuid,
        base_price: base,
        status: "active",
        sku: "WA-#{System.unique_integer([:positive])}"
      })

    item
  end

  defp create_inactive_item!(cat) do
    {:ok, item} =
      Catalogue.create_item(%{
        name: "Inactive #{System.unique_integer([:positive])}",
        catalogue_uuid: cat.uuid,
        base_price: "5.00",
        status: "inactive",
        sku: "WI-#{System.unique_integer([:positive])}"
      })

    item
  end

  defp create_discontinued_item!(cat) do
    {:ok, item} =
      Catalogue.create_item(%{
        name: "Discontinued #{System.unique_integer([:positive])}",
        catalogue_uuid: cat.uuid,
        base_price: "3.00",
        status: "discontinued",
        sku: "WD-#{System.unique_integer([:positive])}"
      })

    item
  end

  defp user_uuid do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "wh-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Test",
        "last_name" => "User"
      })

    user.uuid
  end

  # ---------------------------------------------------------------------------
  # new_draft / seed_lines
  # ---------------------------------------------------------------------------

  describe "new_draft/1 — seeding" do
    test "seeds lines from in-stock active items only" do
      cat = create_catalogue!()
      active = create_active_item!(cat)
      inactive = create_inactive_item!(cat)

      # Only active item has stock
      {:ok, _} = Warehouse.upsert_quantity(active.uuid, "5", unit_value: Decimal.new("10"))
      {:ok, _} = Warehouse.upsert_quantity(inactive.uuid, "3", unit_value: nil)

      doc = Inventories.new_draft("en")

      item_uuids = Enum.map(doc.lines, & &1["item_uuid"])
      assert active.uuid in item_uuids
      refute inactive.uuid in item_uuids
    end

    test "excludes discontinued catalogue items" do
      cat = create_catalogue!()
      active = create_active_item!(cat)
      discontinued = create_discontinued_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(active.uuid, "2", unit_value: nil)
      {:ok, _} = Warehouse.upsert_quantity(discontinued.uuid, "4", unit_value: nil)

      doc = Inventories.new_draft("en")

      item_uuids = Enum.map(doc.lines, & &1["item_uuid"])
      assert active.uuid in item_uuids
      refute discontinued.uuid in item_uuids
    end

    test "seeded line has counted_quantity from current stock" do
      cat = create_catalogue!()
      active = create_active_item!(cat)
      {:ok, _} = Warehouse.upsert_quantity(active.uuid, "7", unit_value: Decimal.new("12"))

      doc = Inventories.new_draft("en")

      line = Enum.find(doc.lines, &(&1["item_uuid"] == active.uuid))
      assert line != nil
      assert Decimal.equal?(Warehouse.to_decimal(line["counted_quantity"]), Decimal.new("7"))
    end

    test "seeded line unit_value defaults to stock unit_value when present" do
      cat = create_catalogue!()
      active = create_active_item!(cat, base_price: "10.00")
      {:ok, _} = Warehouse.upsert_quantity(active.uuid, "3", unit_value: Decimal.new("15"))

      doc = Inventories.new_draft("en")

      line = Enum.find(doc.lines, &(&1["item_uuid"] == active.uuid))
      assert Decimal.equal?(Warehouse.to_decimal(line["unit_value"]), Decimal.new("15"))
    end

    test "seeded line unit_value falls back to item base_price when no stock unit_value" do
      cat = create_catalogue!()
      active = create_active_item!(cat, base_price: "8.50")
      {:ok, _} = Warehouse.upsert_quantity(active.uuid, "2", unit_value: nil)

      doc = Inventories.new_draft("en")

      line = Enum.find(doc.lines, &(&1["item_uuid"] == active.uuid))
      assert Decimal.equal?(Warehouse.to_decimal(line["unit_value"]), Decimal.new("8.50"))
    end

    test "returns an unsaved struct (no uuid assigned by DB)" do
      doc = Inventories.new_draft("en")
      # new_draft returns a struct not yet persisted — uuid may be auto-generated
      # but it has no :inserted_at (nil) confirming it's not DB-persisted
      assert is_nil(doc.inserted_at)
    end
  end

  # ---------------------------------------------------------------------------
  # create_draft / get_document / list_documents
  # ---------------------------------------------------------------------------

  describe "create_draft/1" do
    test "creates a draft document" do
      {:ok, doc} = Inventories.create_draft(%{note: "test note"})

      assert doc.status == "draft"
      assert doc.note == "test note"
      assert is_integer(doc.number)
    end

    test "number is auto-assigned by sequence" do
      {:ok, doc1} = Inventories.create_draft(%{})
      {:ok, doc2} = Inventories.create_draft(%{})

      assert doc2.number > doc1.number
    end
  end

  describe "get_document/1 and get_document!/1" do
    test "get_document/1 returns {:ok, doc} for existing" do
      {:ok, doc} = Inventories.create_draft(%{})
      assert {:ok, found} = Inventories.get_document(doc.uuid)
      assert found.uuid == doc.uuid
    end

    test "get_document/1 returns {:error, :not_found} for missing" do
      assert {:error, :not_found} = Inventories.get_document(Ecto.UUID.generate())
    end

    test "get_document!/1 returns the document" do
      {:ok, doc} = Inventories.create_draft(%{})
      found = Inventories.get_document!(doc.uuid)
      assert found.uuid == doc.uuid
    end
  end

  describe "list_documents/1" do
    test "returns non-deleted documents ordered by number desc" do
      {:ok, doc1} = Inventories.create_draft(%{})
      {:ok, doc2} = Inventories.create_draft(%{})

      docs = Inventories.list_documents([])
      numbers = Enum.map(docs, & &1.number)
      # Newest (highest number) first
      assert Enum.sort(numbers, :desc) == numbers
      assert doc1.number in numbers
      assert doc2.number in numbers
    end
  end

  # ---------------------------------------------------------------------------
  # update_draft/2
  # ---------------------------------------------------------------------------

  describe "update_draft/2" do
    test "updates a draft document" do
      {:ok, doc} = Inventories.create_draft(%{note: "old"})
      {:ok, updated} = Inventories.update_draft(doc, %{note: "new"})
      assert updated.note == "new"
    end

    test "returns {:error, :not_draft} for posted documents" do
      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, _} = Inventories.post_document(doc, user_uuid())
      # Reload to get posted status
      {:ok, posted} = Inventories.get_document(doc.uuid)

      assert {:error, :not_draft} = Inventories.update_draft(posted, %{note: "changed"})
    end
  end

  # ---------------------------------------------------------------------------
  # post_document/2 — track_value: false
  # ---------------------------------------------------------------------------

  describe "post_document/2 track_value=false" do
    test "updates quantity, preserves existing unit_value" do
      cat = create_catalogue!()
      item = create_active_item!(cat)
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "3", unit_value: Decimal.new("7"))

      {:ok, doc} =
        Inventories.create_draft(%{
          track_value: false,
          lines: [%{"item_uuid" => item.uuid, "counted_quantity" => "9"}]
        })

      {:ok, _posted} = Inventories.post_document(doc, user_uuid())

      row = Warehouse.stock_map()[item.uuid]
      assert Decimal.equal?(row.quantity, Decimal.new("9"))
      assert Decimal.equal?(row.unit_value, Decimal.new("7"))
    end

    test "posting sets status: posted, posted_at, performed_by_uuid" do
      cat = create_catalogue!()
      item = create_active_item!(cat)
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "1", unit_value: nil)
      performer = user_uuid()

      {:ok, doc} =
        Inventories.create_draft(%{
          track_value: false,
          lines: [%{"item_uuid" => item.uuid, "counted_quantity" => "2"}]
        })

      {:ok, posted} = Inventories.post_document(doc, performer)

      assert posted.status == "posted"
      assert posted.posted_at != nil
      assert posted.performed_by_uuid == performer
    end

    test "second post returns {:error, :not_draft}" do
      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, _} = Inventories.post_document(doc, user_uuid())
      {:ok, posted} = Inventories.get_document(doc.uuid)

      assert {:error, :not_draft} = Inventories.post_document(posted, user_uuid())
    end
  end

  # ---------------------------------------------------------------------------
  # post_document/2 — track_value: true
  # ---------------------------------------------------------------------------

  describe "post_document/2 track_value=true" do
    test "updates quantity AND unit_value" do
      cat = create_catalogue!()
      item = create_active_item!(cat)
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "3", unit_value: Decimal.new("7"))

      {:ok, doc} =
        Inventories.create_draft(%{
          track_value: true,
          lines: [
            %{
              "item_uuid" => item.uuid,
              "counted_quantity" => "5",
              "unit_value" => "20"
            }
          ]
        })

      {:ok, _posted} = Inventories.post_document(doc, user_uuid())

      row = Warehouse.stock_map()[item.uuid]
      assert Decimal.equal?(row.quantity, Decimal.new("5"))
      assert Decimal.equal?(row.unit_value, Decimal.new("20"))
    end
  end

  # ---------------------------------------------------------------------------
  # post_document/2 — zero quantity
  # ---------------------------------------------------------------------------

  describe "post_document/2 — zero quantity" do
    test "counted 0 zeroes the stock row (row remains)" do
      cat = create_catalogue!()
      item = create_active_item!(cat)
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "10", unit_value: nil)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [%{"item_uuid" => item.uuid, "counted_quantity" => "0"}]
        })

      {:ok, _} = Inventories.post_document(doc, user_uuid())

      row = Warehouse.stock_map()[item.uuid]
      assert row != nil
      assert Decimal.equal?(row.quantity, Decimal.new("0"))
    end
  end

  # ---------------------------------------------------------------------------
  # post_document/2 — partial semantics
  # ---------------------------------------------------------------------------

  describe "post_document/2 — partial" do
    test "item with no line is untouched" do
      cat = create_catalogue!()
      item_in = create_active_item!(cat)
      item_out = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(item_in.uuid, "1", unit_value: nil)
      {:ok, _} = Warehouse.upsert_quantity(item_out.uuid, "99", unit_value: nil)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [%{"item_uuid" => item_in.uuid, "counted_quantity" => "5"}]
        })

      {:ok, _} = Inventories.post_document(doc, user_uuid())

      map = Warehouse.stock_map()
      # item_out was not in the document lines — quantity unchanged
      assert Decimal.equal?(map[item_out.uuid].quantity, Decimal.new("99"))
    end

    test "a line removed before posting is excluded (stock untouched)" do
      cat = create_catalogue!()
      item = create_active_item!(cat)
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "50", unit_value: nil)

      # Create draft with zero lines (simulating the user removed the line)
      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, _} = Inventories.post_document(doc, user_uuid())

      row = Warehouse.stock_map()[item.uuid]
      assert Decimal.equal?(row.quantity, Decimal.new("50"))
    end
  end

  # ---------------------------------------------------------------------------
  # post_document/2 — goods receipt (new stock row created)
  # ---------------------------------------------------------------------------

  describe "post_document/2 — goods receipt" do
    test "creates a new stock row for item with no prior stock" do
      cat = create_catalogue!()
      item = create_active_item!(cat)

      # No stock row exists for item
      assert Warehouse.stock_map()[item.uuid] == nil

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [%{"item_uuid" => item.uuid, "counted_quantity" => "8"}]
        })

      {:ok, _} = Inventories.post_document(doc, user_uuid())

      row = Warehouse.stock_map()[item.uuid]
      assert row != nil
      assert Decimal.equal?(row.quantity, Decimal.new("8"))
    end

    test "audit defaults: previous_quantity == 0, previous_unit_value == nil for new stock" do
      cat = create_catalogue!()
      item = create_active_item!(cat)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [%{"item_uuid" => item.uuid, "counted_quantity" => "3"}]
        })

      {:ok, posted} = Inventories.post_document(doc, user_uuid())

      line = Enum.find(posted.lines, &(&1["item_uuid"] == item.uuid))
      assert Decimal.equal?(Warehouse.to_decimal(line["previous_quantity"]), Decimal.new("0"))
      assert is_nil(line["previous_unit_value"])
    end
  end

  # ---------------------------------------------------------------------------
  # post_document/2 — audit (capture-before-overwrite)
  # ---------------------------------------------------------------------------

  describe "post_document/2 — audit" do
    test "previous_quantity equals the PRE-post quantity" do
      cat = create_catalogue!()
      item = create_active_item!(cat)
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "42", unit_value: Decimal.new("5"))

      {:ok, doc} =
        Inventories.create_draft(%{
          track_value: false,
          lines: [%{"item_uuid" => item.uuid, "counted_quantity" => "10"}]
        })

      {:ok, posted} = Inventories.post_document(doc, user_uuid())

      line = Enum.find(posted.lines, &(&1["item_uuid"] == item.uuid))
      # previous_quantity was 42 BEFORE posting set it to 10
      assert Decimal.equal?(Warehouse.to_decimal(line["previous_quantity"]), Decimal.new("42"))
    end

    test "previous_unit_value equals the PRE-post unit_value" do
      cat = create_catalogue!()
      item = create_active_item!(cat)
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "5", unit_value: Decimal.new("9"))

      {:ok, doc} =
        Inventories.create_draft(%{
          track_value: true,
          lines: [
            %{"item_uuid" => item.uuid, "counted_quantity" => "3", "unit_value" => "20"}
          ]
        })

      {:ok, posted} = Inventories.post_document(doc, user_uuid())

      line = Enum.find(posted.lines, &(&1["item_uuid"] == item.uuid))
      assert Decimal.equal?(Warehouse.to_decimal(line["previous_unit_value"]), Decimal.new("9"))
    end
  end

  # ---------------------------------------------------------------------------
  # line_total/1 and document_total/1
  # ---------------------------------------------------------------------------

  describe "line_total/1" do
    test "computes counted_quantity * unit_value" do
      line = %{"counted_quantity" => "3", "unit_value" => "7"}
      assert Decimal.equal?(Inventories.line_total(line), Decimal.new("21"))
    end

    test "returns 0 when unit_value is nil" do
      line = %{"counted_quantity" => "5", "unit_value" => nil}
      assert Decimal.equal?(Inventories.line_total(line), Decimal.new("0"))
    end
  end

  describe "document_total/1" do
    test "sums line totals" do
      {:ok, doc} =
        Inventories.create_draft(%{
          track_value: true,
          lines: [
            %{
              "item_uuid" => Ecto.UUID.generate(),
              "counted_quantity" => "2",
              "unit_value" => "10"
            },
            %{
              "item_uuid" => Ecto.UUID.generate(),
              "counted_quantity" => "3",
              "unit_value" => "5"
            }
          ]
        })

      # 2*10 + 3*5 = 20 + 15 = 35
      assert Decimal.equal?(Inventories.document_total(doc), Decimal.new("35"))
    end
  end

  # ---------------------------------------------------------------------------
  # soft_delete_document/2
  # ---------------------------------------------------------------------------

  describe "soft_delete_document/2" do
    test "soft-deletes a draft" do
      {:ok, doc} = Inventories.create_draft(%{})
      actor = user_uuid()
      {:ok, deleted} = Inventories.soft_delete_document(doc, actor)

      assert deleted.deleted_at != nil
      assert deleted.deleted_by_uuid == actor
    end

    test "deleted document excluded from list_documents" do
      {:ok, doc} = Inventories.create_draft(%{})
      {:ok, _} = Inventories.soft_delete_document(doc, user_uuid())

      uuids = Inventories.list_documents([]) |> Enum.map(& &1.uuid)
      refute doc.uuid in uuids
    end

    test "returns {:error, :not_draft} for a posted document" do
      {:ok, doc} = Inventories.create_draft(%{})
      {:ok, _} = Inventories.post_document(doc, user_uuid())
      {:ok, posted} = Inventories.get_document(doc.uuid)

      assert {:error, :not_draft} = Inventories.soft_delete_document(posted, user_uuid())
    end
  end

  # ---------------------------------------------------------------------------
  # post_document/2 — duplicate item_uuid lines (must not crash the Multi)
  # ---------------------------------------------------------------------------

  describe "post_document/2 — duplicate item_uuid lines" do
    test "posting lines that repeat an item_uuid does not crash (deduped, first wins)" do
      cat = create_catalogue!()
      item = create_active_item!(cat)
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "1", unit_value: nil)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [
            %{"item_uuid" => item.uuid, "counted_quantity" => "5"},
            %{"item_uuid" => item.uuid, "counted_quantity" => "3"}
          ]
        })

      # Without dedup this raises ArgumentError (Ecto.Multi name collision on
      # {:upsert_stock, item_uuid}); it must instead post cleanly.
      assert {:ok, _posted} = Inventories.post_document(doc, user_uuid())

      row = Warehouse.stock_map()[item.uuid]
      assert row != nil
      # Enum.uniq_by keeps the first occurrence → counted_quantity "5".
      assert Decimal.equal?(row.quantity, Decimal.new("5"))
    end
  end

  # ---------------------------------------------------------------------------
  # post_document/2 — double-posting race (DB-level draft guard)
  # ---------------------------------------------------------------------------

  describe "post_document/2 — double-posting guard" do
    test "re-posting a STALE draft struct is rejected (no silent double-post)" do
      cat = create_catalogue!()
      item = create_active_item!(cat)
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "1", unit_value: nil)

      {:ok, draft} =
        Inventories.create_draft(%{
          lines: [%{"item_uuid" => item.uuid, "counted_quantity" => "5"}]
        })

      # First post succeeds and flips the DB row to "posted".
      {:ok, _posted} = Inventories.post_document(draft, user_uuid())

      # `draft` is now stale: its in-memory status is still "draft", but the DB
      # row is "posted". The in-memory guard alone would re-post it; the DB-level
      # guard must reject the second attempt.
      assert {:error, :not_draft} = Inventories.post_document(draft, user_uuid())
    end
  end
end
