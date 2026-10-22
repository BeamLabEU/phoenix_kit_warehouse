defmodule PhoenixKitWarehouse.SupplierOrdersDraftVersionTest do
  @moduledoc """
  The version of a supplier order draft (`draft_version/1`) and the
  `expected_version` option of the functions the supplier order form writes
  a draft with: a form that read the draft before generation appended to it
  gets `{:error, :stale}` and writes nothing, instead of overwriting what was
  appended. The form's side is in `SupplierOrderFormStaleLiveTest`.
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrders

  @location "00000000-0000-0000-0000-000000000001"

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp unique, do: System.unique_integer([:positive])

  defp dec(value), do: Decimal.new(value)

  defp supplier! do
    {:ok, supplier} = Catalogue.create_supplier(%{name: "Supplier #{unique()}", status: "active"})
    supplier
  end

  # An item whose only supplier is `supplier` (through its manufacturer).
  defp item_of!(supplier) do
    {:ok, mfr} = Catalogue.create_manufacturer(%{name: "Mfr #{unique()}", status: "active"})
    Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Cat #{unique()}", status: "active"})

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Item #{unique()}",
        catalogue_uuid: catalogue.uuid,
        status: "active",
        manufacturer_uuid: mfr.uuid
      })

    item
  end

  defp io_line(item, qty) do
    %{
      "item_uuid" => item.uuid,
      "name" => item.name,
      "sku" => item.sku || "",
      "unit" => item.unit || "piece",
      "catalogue_uuid" => item.catalogue_uuid,
      "required_quantity" => qty
    }
  end

  defp posted_io!(lines) do
    {:ok, io} = InternalOrders.create_internal_order(%{location_uuid: @location, lines: lines})
    {:ok, posted} = InternalOrders.post_internal_order(io, nil)
    posted
  end

  defp so_line(item, qty) do
    %{
      "item_uuid" => item.uuid,
      "name" => item.name,
      "required_quantity" => dec(qty),
      "shortfall_quantity" => dec(qty),
      "ordered_quantity" => dec(qty)
    }
  end

  defp draft!(supplier, attrs \\ %{}) do
    {:ok, so} =
      SupplierOrders.create_supplier_order(
        Map.merge(%{location_uuid: @location, supplier_uuid: supplier && supplier.uuid}, attrs)
      )

    so
  end

  defp reload(%{uuid: uuid}), do: SupplierOrders.get_supplier_order!(uuid)

  defp ordered(order, item) do
    case Enum.find(order.lines, &(&1["item_uuid"] == item.uuid)) do
      nil -> nil
      line -> StockLedger.to_decimal(line["ordered_quantity"])
    end
  end

  # A draft of the pair (internal order, supplier) that a form has open, and
  # generation then appends to: item `a` 3 -> 5, item `b` new with 4.
  defp appended_draft! do
    supplier = supplier!()
    a = item_of!(supplier)
    b = item_of!(supplier)
    io = posted_io!([io_line(a, "5"), io_line(b, "4")])

    draft =
      draft!(supplier, %{
        internal_order_uuid: io.uuid,
        lines: [so_line(a, "3")],
        source_refs: [%{"type" => "internal_order", "uuid" => io.uuid}]
      })

    seen = SupplierOrders.draft_version(draft)

    {:ok, %{supplier_orders: [], appended: [%{uuid: uuid}]}} =
      SupplierOrders.generate_from_internal_order(io, nil)

    assert uuid == draft.uuid

    appended = reload(draft)
    assert Decimal.equal?(ordered(appended, a), dec("5"))
    assert Decimal.equal?(ordered(appended, b), dec("4"))

    %{supplier: supplier, a: a, b: b, io: io, draft: draft, appended: appended, seen: seen}
  end

  defp assert_untouched(appended) do
    assert reload(appended) == appended
  end

  # ---------------------------------------------------------------------------
  # draft_version/1
  # ---------------------------------------------------------------------------

  describe "draft_version/1" do
    test "the struct a write returns and the row read back have one version" do
      supplier = supplier!()
      item = item_of!(supplier)
      draft = draft!(supplier, %{lines: [so_line(item, "10")]})

      assert SupplierOrders.draft_version(draft) == SupplierOrders.draft_version(reload(draft))

      lines = [
        so_line(item, "10")
        |> Map.put("ordered_quantity", dec("11.50"))
        |> Map.put("base_price", dec("1.2E+1"))
      ]

      {:ok, updated} = SupplierOrders.update_draft(draft, %{lines: lines, note: "Hello"})

      assert %Decimal{} = hd(updated.lines)["ordered_quantity"]
      assert is_binary(hd(reload(draft).lines)["ordered_quantity"])

      assert SupplierOrders.draft_version(updated) == SupplierOrders.draft_version(reload(draft))
    end

    test "the order of the keys of a line does not count" do
      supplier = supplier!()
      draft = draft!(supplier)
      keys = for i <- 1..40, into: %{}, do: {"k#{i}", i}
      reversed = keys |> Enum.reverse() |> Map.new()

      assert SupplierOrders.draft_version(%{draft | lines: [keys]}) ==
               SupplierOrders.draft_version(%{draft | lines: [reversed]})
    end

    test "lines, refs, supplier, note, status and the trash change it" do
      supplier = supplier!()
      item = item_of!(supplier)
      draft = draft!(supplier, %{lines: [so_line(item, "10")]})
      version = SupplierOrders.draft_version(draft)

      changed = [
        %{draft | lines: [so_line(item, "11")]},
        %{draft | source_refs: [%{"type" => "internal_order", "uuid" => Ecto.UUID.generate()}]},
        %{draft | supplier_uuid: Ecto.UUID.generate()},
        %{draft | note: "changed"},
        %{draft | status: "posted"},
        %{draft | deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)}
      ]

      for other <- changed do
        refute SupplierOrders.draft_version(other) == version, inspect(other)
      end
    end

    test "the storage folder and the timestamps do not change it" do
      supplier = supplier!()
      draft = draft!(supplier)
      version = SupplierOrders.draft_version(draft)

      {:ok, with_folder} = SupplierOrders.set_storage_folder(draft, Ecto.UUID.generate())
      later = DateTime.add(draft.updated_at, 60)

      assert SupplierOrders.draft_version(with_folder) == version
      assert SupplierOrders.draft_version(%{draft | updated_at: later}) == version
    end

    test "generation that appends to the draft changes it" do
      %{seen: seen, appended: appended} = appended_draft!()

      refute SupplierOrders.draft_version(appended) == seen
    end
  end

  # ---------------------------------------------------------------------------
  # update_draft/3
  # ---------------------------------------------------------------------------

  describe "update_draft/3 with expected_version" do
    test "writes when the draft is the version the caller saw" do
      supplier = supplier!()
      item = item_of!(supplier)
      draft = draft!(supplier, %{lines: [so_line(item, "3")]})

      assert {:ok, updated} =
               SupplierOrders.update_draft(draft, %{lines: [so_line(item, "7")]},
                 expected_version: SupplierOrders.draft_version(draft)
               )

      assert Decimal.equal?(ordered(reload(updated), item), dec("7"))
    end

    test "a draft generation appended to meanwhile: :stale, nothing written" do
      %{draft: draft, a: a, seen: seen, appended: appended} = appended_draft!()

      assert {:error, :stale} =
               SupplierOrders.update_draft(draft, %{lines: [so_line(a, "3")], note: "mine"},
                 expected_version: seen
               )

      assert_untouched(appended)
    end

    test "two writes in a row, each with the version the last one returned, are not stale" do
      supplier = supplier!()
      item = item_of!(supplier)
      draft = draft!(supplier, %{lines: [so_line(item, "3")]})

      {:ok, first} =
        SupplierOrders.update_draft(draft, %{lines: [so_line(item, "4")]},
          expected_version: SupplierOrders.draft_version(draft)
        )

      assert {:ok, second} =
               SupplierOrders.update_draft(first, %{lines: [so_line(item, "5")], note: "n"},
                 expected_version: SupplierOrders.draft_version(first)
               )

      assert {:ok, _third} =
               SupplierOrders.update_draft(second, %{note: "m"},
                 expected_version: SupplierOrders.draft_version(second)
               )
    end

    test "without the option it writes as before" do
      %{draft: draft, a: a, appended: appended} = appended_draft!()

      assert {:ok, _} = SupplierOrders.update_draft(draft, %{lines: [so_line(a, "3")]})
      assert reload(appended).lines |> length() == 1
    end

    test "a draft in the trash answers :deleted, a posted one :not_draft, before :stale" do
      supplier = supplier!()
      trashed = draft!(supplier)
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(trashed, nil)
      posted = draft!(supplier)
      {:ok, _} = SupplierOrders.post_supplier_order(posted, nil)

      assert {:error, :deleted} =
               SupplierOrders.update_draft(trashed, %{note: "x"}, expected_version: "old")

      assert {:error, :not_draft} =
               SupplierOrders.update_draft(posted, %{note: "x"}, expected_version: "old")
    end
  end

  # ---------------------------------------------------------------------------
  # post_supplier_order/3
  # ---------------------------------------------------------------------------

  describe "post_supplier_order/3 with expected_version" do
    test "posts the version the caller saw" do
      supplier = supplier!()
      draft = draft!(supplier)

      assert {:ok, %{status: "posted"}} =
               SupplierOrders.post_supplier_order(draft, nil,
                 expected_version: SupplierOrders.draft_version(draft)
               )
    end

    test "a draft appended to after the save that preceded the post: :stale, still a draft" do
      supplier = supplier!()
      a = item_of!(supplier)
      b = item_of!(supplier)
      io = posted_io!([io_line(a, "5"), io_line(b, "4")])

      draft =
        draft!(supplier, %{
          internal_order_uuid: io.uuid,
          lines: [so_line(a, "1")],
          source_refs: [%{"type" => "internal_order", "uuid" => io.uuid}]
        })

      # The form's "Post": save the buffer, then post with the version of the
      # save - generation got in between.
      {:ok, saved} =
        SupplierOrders.update_draft(draft, %{lines: [so_line(a, "3")]},
          expected_version: SupplierOrders.draft_version(draft)
        )

      {:ok, %{appended: [_]}} = SupplierOrders.generate_from_internal_order(io, nil)
      appended = reload(draft)

      assert {:error, :stale} =
               SupplierOrders.post_supplier_order(saved, nil,
                 expected_version: SupplierOrders.draft_version(saved)
               )

      assert_untouched(appended)
      assert appended.status == "draft"
    end

    test "a trashed draft answers :deleted before :stale" do
      supplier = supplier!()
      draft = draft!(supplier)
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(draft, nil)

      assert {:error, :deleted} =
               SupplierOrders.post_supplier_order(draft, nil, expected_version: "old")
    end
  end

  # ---------------------------------------------------------------------------
  # add_source_ref/4, remove_source_ref/4
  # ---------------------------------------------------------------------------

  describe "add_source_ref/4 and remove_source_ref/4 with expected_version" do
    test "write when the draft is the version the caller saw, one after the other" do
      supplier = supplier!()
      draft = draft!(supplier)
      io = posted_io!([])

      assert {:ok, linked} =
               SupplierOrders.add_source_ref(draft, "internal_order", io.uuid,
                 expected_version: SupplierOrders.draft_version(draft)
               )

      assert %{"type" => "internal_order", "uuid" => io.uuid} in reload(draft).source_refs

      assert {:ok, unlinked} =
               SupplierOrders.remove_source_ref(linked, "internal_order", io.uuid,
                 expected_version: SupplierOrders.draft_version(linked)
               )

      assert reload(unlinked).source_refs == []
    end

    test "a draft generation appended to meanwhile: :stale, nothing written" do
      %{draft: draft, io: io, seen: seen, appended: appended} = appended_draft!()
      other = posted_io!([])

      assert {:error, :stale} =
               SupplierOrders.add_source_ref(draft, "internal_order", other.uuid,
                 expected_version: seen
               )

      assert {:error, :stale} =
               SupplierOrders.remove_source_ref(draft, "internal_order", io.uuid,
                 expected_version: seen
               )

      assert_untouched(appended)
    end

    test "a draft in the trash answers :deleted before :stale" do
      supplier = supplier!()
      draft = draft!(supplier)
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(draft, nil)

      assert {:error, :deleted} =
               SupplierOrders.add_source_ref(draft, "internal_order", Ecto.UUID.generate(),
                 expected_version: "old"
               )

      assert {:error, :deleted} =
               SupplierOrders.remove_source_ref(draft, "internal_order", Ecto.UUID.generate(),
                 expected_version: "old"
               )
    end

    test "without the option they write as before" do
      %{draft: draft, io: io} = appended_draft!()

      assert {:ok, _} = SupplierOrders.remove_source_ref(draft, "internal_order", io.uuid)
      assert reload(draft).source_refs == []
    end
  end

  # ---------------------------------------------------------------------------
  # import_from_internal_orders/4
  # ---------------------------------------------------------------------------

  describe "import_from_internal_orders/4 with expected_version" do
    test "imports into the version the caller saw" do
      supplier = supplier!()
      item = item_of!(supplier)
      io = posted_io!([io_line(item, "2")])
      draft = draft!(supplier)

      assert {:ok, imported} =
               SupplierOrders.import_from_internal_orders(draft, [io.uuid], nil,
                 expected_version: SupplierOrders.draft_version(draft)
               )

      assert Decimal.equal?(ordered(imported, item), dec("2"))
    end

    test "a draft generation appended to meanwhile: :stale, nothing written" do
      %{draft: draft, supplier: supplier, seen: seen, appended: appended} = appended_draft!()
      other_io = posted_io!([io_line(item_of!(supplier), "6")])

      assert {:error, :stale} =
               SupplierOrders.import_from_internal_orders(draft, [other_io.uuid], nil,
                 expected_version: seen
               )

      assert_untouched(appended)
    end

    test "a draft in the trash answers :deleted before :stale" do
      supplier = supplier!()
      draft = draft!(supplier)
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(draft, nil)

      assert {:error, :deleted} =
               SupplierOrders.import_from_internal_orders(draft, [], nil, expected_version: "old")
    end
  end
end
