defmodule PhoenixKitWarehouse.InventoriesFingerprintTest do
  # The seed mark of a line (spec §10.4) and the fingerprint of a document's
  # lines (spec §11.1): taken in the database only, checked by update_draft
  # only when the caller passes the base it read.
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.StockLedger

  defp item! do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "FP #{System.unique_integer([:positive])}"})

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Item #{System.unique_integer([:positive])}",
        catalogue_uuid: cat.uuid,
        status: "active"
      })

    item
  end

  describe "seed_lines/2 marks what it seeds" do
    test "counted_by stock and the seeded quantity, equal to the stock" do
      item = item!()
      location = Ecto.UUID.generate()
      {:ok, _} = StockLedger.upsert_quantity(item.uuid, "8", location_uuid: location)

      [line] = Inventories.seed_lines("en", location)

      assert line["counted_by"] == "stock"
      assert Decimal.eq?(line["seeded_quantity"], 8)
      assert Decimal.eq?(line["counted_quantity"], line["seeded_quantity"])
    end

    test "the marks survive a save and a read back" do
      item = item!()
      location = Ecto.UUID.generate()
      {:ok, _} = StockLedger.upsert_quantity(item.uuid, "8", location_uuid: location)

      {:ok, doc} =
        Inventories.create_draft(%{
          location_uuid: location,
          lines: Inventories.seed_lines("en", location)
        })

      [line] = Inventories.get_document!(doc.uuid).lines
      assert line["counted_by"] == "stock"
      assert Decimal.eq?(StockLedger.to_decimal_or_nil(line["seeded_quantity"]), 8)
    end
  end

  describe "fingerprint/1" do
    test "is md5 of the lines' text, taken in the database" do
      {:ok, doc} =
        Inventories.create_draft(%{lines: [%{"item_uuid" => "x", "counted_quantity" => "1"}]})

      %{rows: [[expected]]} =
        Repo.query!(
          "SELECT md5(lines::text) FROM phoenix_kit_warehouse_inventory_documents WHERE uuid = $1",
          [Ecto.UUID.dump!(doc.uuid)]
        )

      assert Inventories.fingerprint(doc) == expected
      assert Inventories.fingerprint(doc.uuid) == expected
      assert expected =~ ~r/\A[0-9a-f]{32}\z/
    end

    test "changes with the lines, not with the order of the keys or a Decimal's form" do
      {:ok, doc} = Inventories.create_draft(%{lines: [%{"a" => "1", "b" => "2"}]})
      before = Inventories.fingerprint(doc)

      {:ok, _} = Inventories.update_draft(doc, %{lines: [%{"b" => "2", "a" => "1"}]})
      assert Inventories.fingerprint(doc) == before

      {:ok, _} = Inventories.update_draft(doc, %{lines: [%{"b" => "2", "a" => "3"}]})
      refute Inventories.fingerprint(doc) == before
    end

    test "nil for a document that is not there" do
      assert Inventories.fingerprint(Ecto.UUID.generate()) == nil
    end

    test "get_document_with_fingerprint/1 reads both in one go" do
      {:ok, doc} = Inventories.create_draft(%{lines: [%{"a" => "1"}]})

      assert {:ok, %InventoryDocument{uuid: uuid, fingerprint: fingerprint}} =
               Inventories.get_document_with_fingerprint(doc.uuid)

      assert uuid == doc.uuid
      assert fingerprint == Inventories.fingerprint(doc)

      assert Inventories.get_document_with_fingerprint(Ecto.UUID.generate()) ==
               {:error, :not_found}
    end
  end

  describe "update_draft/3 with base_fingerprint:" do
    test "two saves in a row from one tab both pass, each returning the new base" do
      {:ok, doc} = Inventories.create_draft(%{lines: [%{"a" => "1"}]})
      base = Inventories.fingerprint(doc)

      assert {:ok, first} =
               Inventories.update_draft(doc, %{lines: [%{"a" => "2"}]}, base_fingerprint: base)

      assert first.fingerprint == Inventories.fingerprint(doc)

      assert {:ok, second} =
               Inventories.update_draft(first, %{lines: [%{"a" => "3"}]},
                 base_fingerprint: first.fingerprint
               )

      assert second.fingerprint == Inventories.fingerprint(doc)
      assert [%{"a" => "3"}] = Inventories.get_document!(doc.uuid).lines
    end

    test "a tab whose base is old is refused and writes nothing" do
      {:ok, doc} = Inventories.create_draft(%{lines: [%{"a" => "1"}]})
      tab_a = Inventories.fingerprint(doc)
      tab_b = tab_a

      {:ok, _} = Inventories.update_draft(doc, %{lines: [%{"a" => "B"}]}, base_fingerprint: tab_b)

      assert Inventories.update_draft(doc, %{lines: [%{"a" => "A"}], note: "A"},
               base_fingerprint: tab_a
             ) == {:error, :stale}

      reloaded = Inventories.get_document!(doc.uuid)
      assert [%{"a" => "B"}] = reloaded.lines
      assert reloaded.note == nil
    end

    test "a location change from an old base is refused too" do
      {:ok, doc} = Inventories.create_draft(%{lines: [%{"a" => "1"}]})
      base = Inventories.fingerprint(doc)
      {:ok, _} = Inventories.update_draft(doc, %{lines: [%{"a" => "2"}]})

      assert Inventories.update_draft(doc, %{location_uuid: Ecto.UUID.generate()},
               base_fingerprint: base
             ) == {:error, :stale}
    end

    test "a base passed as nil is refused, not taken as no option" do
      {:ok, doc} = Inventories.create_draft(%{lines: [%{"a" => "1"}]})
      {:ok, _} = Inventories.update_draft(doc, %{lines: [%{"a" => "2"}]})

      assert Inventories.update_draft(doc, %{lines: [%{"a" => "nil tab"}], note: "z"},
               base_fingerprint: nil
             ) == {:error, :stale}

      reloaded = Inventories.get_document!(doc.uuid)
      assert [%{"a" => "2"}] = reloaded.lines
      assert reloaded.note == nil
    end

    test "without the option the save is as before: no check, no fingerprint" do
      {:ok, doc} = Inventories.create_draft(%{lines: [%{"a" => "1"}]})
      {:ok, _} = Inventories.update_draft(doc, %{lines: [%{"a" => "2"}]})

      assert {:ok, updated} = Inventories.update_draft(doc, %{lines: [%{"a" => "3"}]})
      assert updated.fingerprint == nil
    end

    test "the status checks come first" do
      {:ok, doc} = Inventories.create_draft(%{lines: []})
      base = Inventories.fingerprint(doc)
      {:ok, _trashed} = Inventories.soft_delete_document(doc, nil)

      assert Inventories.update_draft(doc, %{note: "x"}, base_fingerprint: base) ==
               {:error, :deleted}
    end
  end
end
