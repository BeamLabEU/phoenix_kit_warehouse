defmodule PhoenixKitWarehouse.SupplierOrderPlanTest do
  @moduledoc """
  The read-only plan behind "generate supplier orders" of a posted internal
  order: who supplies each line and why, how much is still to order, the
  fingerprint that tells a stale plan, and the check of the manual choices.
  Nothing here writes a supplier order.
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo
  alias PhoenixKitCatalogue.Schemas.Supplier
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrderPlan
  alias PhoenixKitWarehouse.SupplierOrders

  @location "00000000-0000-0000-0000-000000000001"

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp uuid, do: Ecto.UUID.generate()

  defp unique, do: System.unique_integer([:positive])

  defp supplier!(attrs \\ %{}) do
    {:ok, supplier} =
      Catalogue.create_supplier(
        Map.merge(%{name: "Supplier #{unique()}", status: "active"}, attrs)
      )

    supplier
  end

  # The local row becomes the projection of a CRM company. The column is not
  # castable (the catalogue sets it through its CRM link action).
  defp project!(%Supplier{uuid: uuid} = supplier, company_uuid) do
    Repo.update_all(from(s in Supplier, where: s.uuid == ^uuid),
      set: [crm_company_uuid: company_uuid]
    )

    %{supplier | crm_company_uuid: company_uuid}
  end

  defp manufacturer!(suppliers \\ []) do
    {:ok, mfr} = Catalogue.create_manufacturer(%{name: "Mfr #{unique()}", status: "active"})
    Enum.each(suppliers, &Catalogue.link_manufacturer_supplier(mfr.uuid, &1.uuid))
    mfr
  end

  defp item!(attrs \\ %{}) do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Cat #{unique()}", status: "active"})

    {:ok, item} =
      Catalogue.create_item(
        Map.merge(
          %{name: "Item #{unique()}", catalogue_uuid: catalogue.uuid, status: "active"},
          attrs
        )
      )

    item
  end

  # The catalogue makes the first link of an item its primary; a test says
  # which link is the primary itself.
  defp info!(item, supplier_uuid, attrs \\ %{}) do
    {primary?, attrs} = Map.pop(attrs, :is_primary, false)

    {:ok, info} =
      Catalogue.create_supplier_info(
        Map.merge(
          %{item_uuid: item.uuid, supplier_uuid: supplier_uuid, supplier_source: "local"},
          attrs
        )
      )

    Repo.update_all(from(i in ItemSupplierInfo, where: i.uuid == ^info.uuid),
      set: [is_primary: primary?]
    )

    %{info | is_primary: primary?}
  end

  defp io_line(item_or_uuid, qty, extra \\ %{})

  defp io_line(%Item{} = item, qty, extra) do
    Map.merge(
      %{
        "item_uuid" => item.uuid,
        "name" => item.name,
        "sku" => item.sku || "",
        "unit" => item.unit || "piece",
        "catalogue_uuid" => item.catalogue_uuid,
        "required_quantity" => qty
      },
      extra
    )
  end

  defp io_line(item_uuid, qty, extra) when is_binary(item_uuid) do
    Map.merge(%{"item_uuid" => item_uuid, "name" => "Gone", "required_quantity" => qty}, extra)
  end

  defp posted_io!(lines) do
    {:ok, io} = InternalOrders.create_internal_order(%{location_uuid: @location, lines: lines})
    {:ok, posted} = InternalOrders.post_internal_order(io, nil)
    posted
  end

  defp stock!(item, qty) do
    {:ok, _} = StockLedger.upsert_quantity(item.uuid, qty, location_uuid: @location)
  end

  defp so_line(item, qty) do
    %{"item_uuid" => item.uuid, "name" => item.name, "ordered_quantity" => qty}
  end

  defp io_ref(io_uuid, lines \\ nil)
  defp io_ref(io_uuid, nil), do: %{"type" => "internal_order", "uuid" => io_uuid}
  defp io_ref(io_uuid, lines), do: Map.put(io_ref(io_uuid), "lines", lines)

  defp draft_so!(attrs) do
    {:ok, so} =
      SupplierOrders.create_supplier_order(
        Map.merge(%{location_uuid: @location, supplier_uuid: supplier!().uuid}, attrs)
      )

    so
  end

  defp posted_so!(attrs) do
    {:ok, posted} = attrs |> draft_so!() |> SupplierOrders.post_supplier_order(nil)
    posted
  end

  # create_and_post keeps no document link, so draft and post.
  defp receive!(so, item, qty) do
    {:ok, receipt} =
      GoodsReceipts.create_goods_receipt(%{
        supplier_order_uuid: so.uuid,
        supplier_uuid: so.supplier_uuid,
        location_uuid: @location,
        lines: [%{"item_uuid" => item.uuid, "received_quantity" => qty}]
      })

    {:ok, _} = GoodsReceipts.post_goods_receipt(receipt, nil)
  end

  defp issue!(item, qty, attrs) do
    {:ok, issue} =
      GoodsIssues.create_goods_issue(
        Map.merge(
          %{
            location_uuid: @location,
            lines: [%{"item_uuid" => item.uuid, "issued_quantity" => qty}]
          },
          attrs
        )
      )

    {:ok, _} = GoodsIssues.post_goods_issue(issue, nil)
  end

  defp plan!(io) do
    {:ok, plan} = SupplierOrders.plan_from_internal_order(io.uuid)
    plan
  end

  defp only_line(%{lines: [line | _]}), do: line

  defp fingerprint(io), do: plan!(io).fingerprint

  defp assert_dec(actual, expected) do
    assert Decimal.equal?(actual, Decimal.new(expected)),
           "expected #{expected}, got #{inspect(actual)}"
  end

  defp candidate_uuids(line), do: Enum.map(line.candidates, & &1.uuid)

  # ---------------------------------------------------------------------------
  # Supplier of a line
  # ---------------------------------------------------------------------------

  describe "supplier of a line" do
    test "an active local primary wins even when the manufacturer has another supplier" do
      primary = supplier!()
      other = supplier!()
      item = item!(%{manufacturer_uuid: manufacturer!([other]).uuid})
      info!(item, primary.uuid, %{is_primary: true})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :primary
      assert line.auto_supplier_uuid == primary.uuid
      assert Enum.sort(candidate_uuids(line)) == Enum.sort([primary.uuid, other.uuid])
      assert Enum.find(line.candidates, &(&1.uuid == primary.uuid)).sources == [:primary]
    end

    test "the only supplier linked to the item is picked, labelled as the item's" do
      supplier = supplier!()
      item = item!()
      info!(item, supplier.uuid)

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :single_candidate
      assert line.reason_source == :item_link
      assert line.auto_supplier_uuid == supplier.uuid
    end

    test "the only supplier of the manufacturer is picked, labelled as the manufacturer's" do
      supplier = supplier!()
      item = item!(%{manufacturer_uuid: manufacturer!([supplier]).uuid})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :single_candidate
      assert line.reason_source == :manufacturer
      assert line.auto_supplier_uuid == supplier.uuid
    end

    test "one supplier reached both ways is one candidate with both sources" do
      supplier = supplier!()
      item = item!(%{manufacturer_uuid: manufacturer!([supplier]).uuid})
      info!(item, supplier.uuid)

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :single_candidate
      assert line.reason_source == :item_link
      assert [%{uuid: uuid, sources: [:item_link, :manufacturer]}] = line.candidates
      assert uuid == supplier.uuid
    end

    test "NEVER auto-pick: two manufacturer suppliers without a primary are ambiguous" do
      a = supplier!()
      b = supplier!()
      item = item!(%{manufacturer_uuid: manufacturer!([a, b]).uuid})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :ambiguous
      assert line.auto_supplier_uuid == nil
      assert Enum.sort(candidate_uuids(line)) == Enum.sort([a.uuid, b.uuid])
    end

    test "NEVER auto-pick: an item link and another manufacturer supplier are ambiguous" do
      a = supplier!()
      b = supplier!()
      item = item!(%{manufacturer_uuid: manufacturer!([b]).uuid})
      info!(item, a.uuid)

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :ambiguous
      assert line.auto_supplier_uuid == nil
    end

    test "nothing linked: no supplier, without a primary issue" do
      line = only_line(plan!(posted_io!([io_line(item!(), "5")])))

      assert line.reason == :no_supplier
      assert line.primary_issue == nil
      assert line.candidates == []
      assert line.auto_supplier_uuid == nil
    end

    test "a primary that is no warehouse supplier: no supplier, the primary shown as unresolved" do
      item = item!()
      company = uuid()
      info!(item, company, %{supplier_source: "crm_company", is_primary: true})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :no_supplier
      assert line.primary_issue == :unresolved
      assert [%{uuid: ^company, why: :unresolved, sources: [:primary]}] = line.excluded
    end

    test "an unresolved primary does not hide the only other candidate" do
      supplier = supplier!()
      item = item!(%{manufacturer_uuid: manufacturer!([supplier]).uuid})
      info!(item, uuid(), %{supplier_source: "crm_company", is_primary: true})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :single_candidate
      assert line.reason_source == :manufacturer
      assert line.primary_issue == :unresolved
      assert line.auto_supplier_uuid == supplier.uuid
    end

    test "a CRM company resolves to the local supplier that projects it" do
      company = uuid()
      local = project!(supplier!(), company)
      item = item!()
      info!(item, company, %{supplier_source: "crm_company", is_primary: true})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :primary
      assert line.auto_supplier_uuid == local.uuid
    end

    test "a CRM supplier of the manufacturer resolves to its local projection" do
      company = uuid()
      local = project!(supplier!(), company)
      mfr = manufacturer!()
      Catalogue.link_manufacturer_supplier(mfr.uuid, company, supplier_source: "crm_company")
      item = item!(%{manufacturer_uuid: mfr.uuid})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :single_candidate
      assert line.auto_supplier_uuid == local.uuid
    end

    test "two projections of one company: an active one, then the earliest" do
      # Current catalogue schemas allow one projection per company; older
      # ones did not, and the rule must stay deterministic for them.
      Repo.query!("DROP INDEX IF EXISTS phoenix_kit_cat_suppliers_crm_company_uuid_index")
      company = uuid()
      inactive_first = project!(supplier!(%{status: "inactive"}), company)
      active_second = project!(supplier!(), company)
      active_third = project!(supplier!(), company)
      set_inserted_at!(inactive_first, ~U[2026-01-01 00:00:00Z])
      set_inserted_at!(active_second, ~U[2026-01-02 00:00:00Z])
      set_inserted_at!(active_third, ~U[2026-01-03 00:00:00Z])

      item = item!()
      info!(item, company, %{supplier_source: "crm_company", is_primary: true})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :primary
      assert line.auto_supplier_uuid == active_second.uuid
    end

    test "two projections: the one the item already names directly is the company's" do
      Repo.query!("DROP INDEX IF EXISTS phoenix_kit_cat_suppliers_crm_company_uuid_index")
      company = uuid()
      earliest = project!(supplier!(), company)
      named = project!(supplier!(), company)
      set_inserted_at!(earliest, ~U[2026-01-01 00:00:00Z])
      set_inserted_at!(named, ~U[2026-01-02 00:00:00Z])

      item = item!(%{manufacturer_uuid: manufacturer!([named]).uuid})
      info!(item, company, %{supplier_source: "crm_company"})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :single_candidate
      assert line.auto_supplier_uuid == named.uuid
      assert [%{sources: [:item_link, :manufacturer]}] = line.candidates
    end

    test "an inactive supplier is no candidate" do
      active = supplier!()
      inactive = supplier!(%{status: "inactive"})
      item = item!(%{manufacturer_uuid: manufacturer!([active, inactive]).uuid})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :single_candidate
      assert line.auto_supplier_uuid == active.uuid
      assert [%{uuid: excluded, why: :inactive}] = line.excluded
      assert excluded == inactive.uuid
    end

    test "an inactive primary is no candidate and is named as the primary issue" do
      primary = supplier!(%{status: "inactive"})
      other = supplier!()
      item = item!(%{manufacturer_uuid: manufacturer!([other]).uuid})
      info!(item, primary.uuid, %{is_primary: true})

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert line.reason == :single_candidate
      assert line.primary_issue == :inactive
      assert line.auto_supplier_uuid == other.uuid
    end

    test "an item missing from the catalogue (or deleted) is shown and cannot be chosen" do
      deleted = item!()
      Repo.update_all(from(i in Item, where: i.uuid == ^deleted.uuid), set: [status: "deleted"])
      io = posted_io!([io_line(uuid(), "5"), io_line(deleted, "5")])

      for line <- plan!(io).lines do
        assert line.reason == :no_item
        assert line.choosable? == false
        assert line.choices == []
        assert line.auto_supplier_uuid == nil
      end
    end

    test "resolve_line_supplier/2 answers for an item outside a plan" do
      supplier = supplier!()
      item = item!(%{manufacturer_uuid: manufacturer!([supplier]).uuid})
      ctx = SupplierOrderPlan.catalogue_context([item])

      assert %{reason: :single_candidate, supplier_uuid: supplier_uuid} =
               SupplierOrderPlan.resolve_line_supplier(item, ctx)

      assert supplier_uuid == supplier.uuid

      assert %{reason: :no_item, supplier_uuid: nil, candidates: []} =
               SupplierOrderPlan.resolve_line_supplier(nil, ctx)
    end
  end

  defp set_inserted_at!(%Supplier{uuid: uuid}, at) do
    Repo.update_all(from(s in Supplier, where: s.uuid == ^uuid), set: [inserted_at: at])
  end

  # ---------------------------------------------------------------------------
  # Quantities
  # ---------------------------------------------------------------------------

  describe "quantity to order" do
    test "stock on the internal order's location is subtracted" do
      item = item!()
      stock!(item, "3")

      line = only_line(plan!(posted_io!([io_line(item, "10")])))

      assert_dec(line.required, "10")
      assert_dec(line.need, "10")
      assert_dec(line.on_hand, "3")
      assert_dec(line.stock, "3")
      assert_dec(line.in_transit, "0")
      assert_dec(line.to_order, "7")
      assert line.zero_reason == nil
    end

    test "covered by stock: nothing to order, said so" do
      item = item!()
      stock!(item, "20")

      line = only_line(plan!(posted_io!([io_line(item, "5")])))

      assert_dec(line.to_order, "0")
      assert_dec(line.stock, "20")
      assert line.zero_reason == :on_hand
      assert line.choosable? == false
    end

    test "a posted order fully received counts once - in stock (R=10, received 6 -> order 4)" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      so = posted_so!(%{internal_order_uuid: io.uuid, lines: [so_line(item, "6")]})
      receive!(so, item, "6")

      line = only_line(plan!(io))

      assert_dec(line.on_hand, "6")
      assert_dec(line.in_transit, "0")
      assert_dec(line.to_order, "4")
    end

    test "a posted order partly received: the rest is in transit" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      so = posted_so!(%{internal_order_uuid: io.uuid, lines: [so_line(item, "10")]})
      receive!(so, item, "6")

      line = only_line(plan!(io))

      assert_dec(line.on_hand, "6")
      assert_dec(line.in_transit, "4")
      assert_dec(line.to_order, "0")
      assert line.zero_reason == :in_transit
      assert [%{uuid: from_uuid, number: number}] = line.in_transit_from
      assert from_uuid == so.uuid
      assert number == so.number
    end

    test "a combined posted order: this order's share, capped by what is still unreceived" do
      # A 6 + B 5 ordered together, all 11 received, B issued its 5: A sees 6
      # on hand and nothing in transit, so 4 are still to order.
      item = item!()
      io_a = posted_io!([io_line(item, "10")])
      io_b = posted_io!([io_line(item, "5")])

      so =
        posted_so!(%{
          internal_order_uuid: io_a.uuid,
          lines: [so_line(item, "11")],
          source_refs: [
            io_ref(io_a.uuid, %{item.uuid => "6"}),
            io_ref(io_b.uuid, %{item.uuid => "5"})
          ]
        })

      receive!(so, item, "11")
      issue!(item, "5", %{internal_order_uuid: io_b.uuid, source_refs: [io_ref(io_b.uuid)]})

      line_a = only_line(plan!(io_a))
      assert_dec(line_a.on_hand, "6")
      assert_dec(line_a.in_transit, "0")
      assert_dec(line_a.to_order, "4")

      line_b = only_line(plan!(io_b))
      assert_dec(line_b.issued, "5")
      assert_dec(line_b.to_order, "0")
      assert line_b.zero_reason == :issued
    end

    test "a combined posted order not yet received: this order's share is in transit" do
      item = item!()
      io_a = posted_io!([io_line(item, "10")])
      io_b = posted_io!([io_line(item, "5")])

      posted_so!(%{
        lines: [so_line(item, "11")],
        source_refs: [
          io_ref(io_a.uuid, %{item.uuid => "6"}),
          io_ref(io_b.uuid, %{item.uuid => "5"})
        ]
      })

      line = only_line(plan!(io_a))
      assert_dec(line.in_transit, "6")
      assert_dec(line.to_order, "4")
    end

    test "a combined draft counts its ref lines for this order" do
      item = item!()
      io_a = posted_io!([io_line(item, "10")])
      io_b = posted_io!([io_line(item, "5")])

      draft_so!(%{
        internal_order_uuid: io_b.uuid,
        lines: [so_line(item, "8")],
        source_refs: [
          io_ref(io_a.uuid, %{item.uuid => "3"}),
          io_ref(io_b.uuid, %{item.uuid => "5"})
        ]
      })

      line = only_line(plan!(io_a))
      assert_dec(line.in_transit, "3")
      assert_dec(line.to_order, "7")
    end

    test "a draft of this order counts its actual lines, with the keeper's edits" do
      edited = item!()
      dropped = item!()
      io = posted_io!([io_line(edited, "10"), io_line(dropped, "4")])

      # Generated with 10 and 4, then the keeper lowered one to 3 and removed
      # the other line.
      draft_so!(%{internal_order_uuid: io.uuid, lines: [so_line(edited, "3")]})

      [line_edited, line_dropped] = plan!(io).lines

      assert_dec(line_edited.in_transit, "3")
      assert_dec(line_edited.to_order, "7")
      assert_dec(line_dropped.in_transit, "0")
      assert_dec(line_dropped.to_order, "4")
    end

    test "a draft with the item twice brings its first line - what posting keeps" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      draft_so!(%{internal_order_uuid: io.uuid, lines: [so_line(item, "3"), so_line(item, "5")]})

      line = only_line(plan!(io))
      assert_dec(line.in_transit, "3")
      assert_dec(line.to_order, "7")
    end

    test "a draft without a supplier counts like any draft of this order" do
      item = item!()
      io = posted_io!([io_line(item, "10")])

      draft =
        draft_so!(%{
          supplier_uuid: nil,
          internal_order_uuid: io.uuid,
          lines: [so_line(item, "4")]
        })

      plan = plan!(io)
      line = only_line(plan)

      assert_dec(line.in_transit, "4")
      assert_dec(line.to_order, "6")

      assert [%{uuid: uuid, supplier_uuid: nil, single_source?: true}] = plan.supplier_orders
      assert uuid == draft.uuid
    end

    test "an order pointing at this internal order but referring only to another one is not its own" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      other = posted_io!([io_line(item, "3")])

      draft_so!(%{
        internal_order_uuid: io.uuid,
        lines: [so_line(item, "3")],
        source_refs: [io_ref(other.uuid, %{item.uuid => "3"})]
      })

      plan = plan!(io)
      line = only_line(plan)

      assert_dec(line.in_transit, "0")
      assert_dec(line.to_order, "10")
      assert [%{single_source?: false}] = plan.supplier_orders
    end

    test "trashed supplier orders count for nothing" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      draft = draft_so!(%{internal_order_uuid: io.uuid, lines: [so_line(item, "4")]})
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(draft, nil)

      plan = plan!(io)
      assert_dec(only_line(plan).to_order, "10")
      assert plan.supplier_orders == []
    end

    test "issued by a ref with lines: the ref's lines" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      stock!(item, "20")

      issue!(item, "7", %{
        internal_order_uuid: io.uuid,
        source_refs: [io_ref(io.uuid, %{item.uuid => "4"})]
      })

      line = only_line(plan!(io))
      assert_dec(line.issued, "4")
      assert_dec(line.need, "6")
    end

    test "issued by a ref without lines (as create_from_internal_order writes it): the issue's lines" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      stock!(item, "20")
      issue!(item, "4", %{internal_order_uuid: io.uuid, source_refs: [io_ref(io.uuid)]})

      line = only_line(plan!(io))
      assert_dec(line.issued, "4")
      assert_dec(line.need, "6")
      # 20 - 4 = 16 left on hand covers the remaining 6
      assert_dec(line.to_order, "0")
    end

    test "re-importing the order into the issue made from it keeps the ref without lines" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      stock!(item, "10")

      {:ok, issue} = GoodsIssues.create_from_internal_order(io, nil)
      {:ok, issue} = GoodsIssues.import_from_internal_orders(issue, [io.uuid], nil)

      assert [%{"issued_quantity" => issued}] = issue.lines
      assert_dec(issued, "10")
      assert [ref] = Enum.filter(issue.source_refs, &(&1["uuid"] == io.uuid))
      refute Map.has_key?(ref, "lines")

      {:ok, _} = GoodsIssues.post_goods_issue(issue, nil)

      line = only_line(plan!(io))
      assert_dec(line.issued, "10")
      assert_dec(line.on_hand, "0")
      assert_dec(line.to_order, "0")
    end

    test "issued with no ref to the order but its internal_order_uuid: the issue's lines" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      stock!(item, "4")

      issue!(item, "4", %{
        internal_order_uuid: io.uuid,
        source_refs: [%{"type" => "sub_order", "uuid" => uuid()}]
      })

      line = only_line(plan!(io))
      assert_dec(line.issued, "4")
      assert_dec(line.need, "6")
      assert_dec(line.on_hand, "0")
      assert_dec(line.to_order, "6")
    end

    test "an issue with both a ref and internal_order_uuid counts once; drafts do not count" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      stock!(item, "20")

      issue!(item, "3", %{
        internal_order_uuid: io.uuid,
        source_refs: [io_ref(io.uuid, %{item.uuid => "3"})]
      })

      {:ok, _draft} =
        GoodsIssues.create_goods_issue(%{
          internal_order_uuid: io.uuid,
          location_uuid: @location,
          lines: [%{"item_uuid" => item.uuid, "issued_quantity" => "5"}],
          source_refs: [io_ref(io.uuid)]
        })

      assert_dec(only_line(plan!(io)).issued, "3")
    end

    test "the same item twice: need adds up, the first lines are covered first" do
      item = item!()
      stock!(item, "5")
      io = posted_io!([io_line(item, "4"), io_line(item, "6")])

      [first, second] = plan!(io).lines

      assert_dec(first.on_hand, "4")
      assert_dec(first.to_order, "0")
      assert first.zero_reason == :on_hand
      assert_dec(second.on_hand, "1")
      assert_dec(second.to_order, "5")
      assert first.key != second.key
    end

    test "issued and in transit are spread over duplicate lines in order" do
      item = item!()
      io = posted_io!([io_line(item, "4"), io_line(item, "6")])
      stock!(item, "20")
      issue!(item, "5", %{internal_order_uuid: io.uuid, source_refs: [io_ref(io.uuid)]})
      draft_so!(%{internal_order_uuid: io.uuid, lines: [so_line(item, "2")]})
      StockLedger.upsert_quantity(item.uuid, "0", location_uuid: @location)

      [first, second] = plan!(io).lines

      assert_dec(first.issued, "4")
      assert_dec(first.to_order, "0")
      assert first.zero_reason == :issued
      assert_dec(second.issued, "1")
      assert_dec(second.need, "5")
      assert_dec(second.in_transit, "2")
      assert_dec(second.to_order, "3")
    end
  end

  # ---------------------------------------------------------------------------
  # The plan
  # ---------------------------------------------------------------------------

  describe "plan_from_internal_order/2" do
    test "answers :not_found, :not_posted and :deleted" do
      assert {:error, :not_found} = SupplierOrders.plan_from_internal_order(uuid())
      assert {:error, :not_found} = SupplierOrders.plan_from_internal_order("not-a-uuid")

      {:ok, draft} = InternalOrders.create_internal_order(%{location_uuid: @location})
      assert {:error, :not_posted} = SupplierOrders.plan_from_internal_order(draft.uuid)

      posted = posted_io!([io_line(item!(), "1")])
      trash_io!(posted)
      assert {:error, :deleted} = SupplierOrders.plan_from_internal_order(posted.uuid)
    end

    test "lines carry key, explanation, choices; groups follow the automatic supplier" do
      auto = supplier!()
      ambiguous_a = supplier!()
      ambiguous_b = supplier!()
      inactive = supplier!(%{status: "inactive"})
      auto_item = item!(%{manufacturer_uuid: manufacturer!([auto]).uuid})

      ambiguous_item =
        item!(%{manufacturer_uuid: manufacturer!([ambiguous_a, ambiguous_b]).uuid})

      covered_item = item!(%{manufacturer_uuid: manufacturer!([auto]).uuid})
      stock!(covered_item, "9")

      io =
        posted_io!([
          io_line(auto_item, "2", %{"explanation" => "For the cabinet.\n\nComment: rush"}),
          io_line(ambiguous_item, "3"),
          io_line(covered_item, "1")
        ])

      plan = plan!(io)
      [auto_line, ambiguous_line, covered_line] = plan.lines

      assert auto_line.key == "0:#{auto_item.uuid}"
      assert ambiguous_line.key == "1:#{ambiguous_item.uuid}"
      assert auto_line.explanation == "For the cabinet.\n\nComment: rush"
      assert auto_line.name == auto_item.name

      assert auto_line.choosable? and ambiguous_line.choosable?
      refute covered_line.choosable?
      assert covered_line.choices == []

      # candidates first, then every other active local supplier
      assert Enum.take(ambiguous_line.choices, 2) == candidate_uuids(ambiguous_line)
      assert auto.uuid in ambiguous_line.choices
      refute inactive.uuid in ambiguous_line.choices
      assert ambiguous_line.choices == Enum.uniq(ambiguous_line.choices)

      assert [%{supplier_uuid: group_supplier, supplier_name: name, keys: keys}] = plan.groups
      assert group_supplier == auto.uuid
      assert name == auto.name
      assert keys == [auto_line.key]

      assert plan.location_uuid == @location
      assert plan.internal_order.uuid == io.uuid
      assert is_binary(plan.fingerprint) and byte_size(plan.fingerprint) == 64
    end

    test "lists the live supplier orders of the internal order" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      own = draft_so!(%{internal_order_uuid: io.uuid, lines: [so_line(item, "1")]})

      combined =
        posted_so!(%{lines: [so_line(item, "1")], source_refs: [io_ref(io.uuid, %{})]})

      _unrelated = draft_so!(%{lines: [so_line(item, "1")]})

      plan = plan!(io)

      assert Enum.sort(Enum.map(plan.supplier_orders, & &1.uuid)) ==
               Enum.sort([own.uuid, combined.uuid])
    end
  end

  defp set_stock_quantity!(item, quantity) do
    Repo.update_all(from(s in Stock, where: s.item_uuid == ^item.uuid), set: [quantity: quantity])
  end

  defp trash_io!(%InternalOrder{uuid: uuid}) do
    Repo.update_all(from(o in InternalOrder, where: o.uuid == ^uuid),
      set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end

  # ---------------------------------------------------------------------------
  # Fingerprint
  # ---------------------------------------------------------------------------

  describe "fingerprint" do
    test "two plans in a row agree; 10 and 10.00 are one quantity" do
      item = item!(%{manufacturer_uuid: manufacturer!([supplier!()]).uuid})
      io = posted_io!([io_line(item, "20")])
      stock!(item, "1")
      set_stock_quantity!(item, Decimal.new("10.00"))

      # the column keeps the scale it was written with
      assert [%Stock{quantity: stored}] =
               Repo.all(from(s in Stock, where: s.item_uuid == ^item.uuid))

      assert Decimal.to_string(stored) == "10.00"

      first = fingerprint(io)
      assert first == fingerprint(io)

      set_stock_quantity!(item, Decimal.new("10"))
      assert first == fingerprint(io)
    end

    test "holds the status and deleted_at of the internal order" do
      io = posted_io!([io_line(item!(), "5")])
      before = SupplierOrderPlan.build_for(io).fingerprint
      assert before == fingerprint(io)

      refute before == SupplierOrderPlan.build_for(%{io | status: "draft"}).fingerprint

      trashed = %{io | deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)}
      refute before == SupplierOrderPlan.build_for(trashed).fingerprint
    end

    test "a note on the posted internal order does not make the plan stale" do
      io = posted_io!([io_line(item!(), "5")])
      before = fingerprint(io)

      Repo.update_all(from(o in InternalOrder, where: o.uuid == ^io.uuid),
        set: [note: "later", updated_at: DateTime.add(DateTime.utc_now(), 3600)]
      )

      assert before == fingerprint(io)
    end

    test "changes with the stock" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      stock!(item, "3")
      before = fingerprint(io)

      stock!(item, "4")
      refute before == fingerprint(io)
    end

    test "changes when an item link is closed" do
      supplier = supplier!()
      item = item!()
      info = info!(item, supplier.uuid)
      io = posted_io!([io_line(item, "10")])
      before = fingerprint(io)

      {:ok, _} = Catalogue.update_supplier_info(info, %{valid_to: Date.utc_today()})
      refute before == fingerprint(io)
    end

    test "changes when the manufacturer is unlinked from a supplier" do
      a = supplier!()
      b = supplier!()
      mfr = manufacturer!([a, b])
      item = item!(%{manufacturer_uuid: mfr.uuid})
      io = posted_io!([io_line(item, "10")])
      before = fingerprint(io)

      {:ok, _} = Catalogue.unlink_manufacturer_supplier(mfr.uuid, b.uuid)
      refute before == fingerprint(io)
    end

    test "changes when the primary changes" do
      a = supplier!()
      b = supplier!()
      item = item!()
      info!(item, a.uuid, %{is_primary: true})
      info_b = info!(item, b.uuid)
      io = posted_io!([io_line(item, "10")])
      before = fingerprint(io)

      {:ok, _} = Catalogue.set_primary_supplier_info(info_b)
      refute before == fingerprint(io)
    end

    test "changes when any supplier is deactivated" do
      io = posted_io!([io_line(item!(), "10")])
      bystander = supplier!()
      before = fingerprint(io)

      {:ok, _} = Catalogue.update_supplier(bystander, %{status: "inactive"})
      refute before == fingerprint(io)
    end

    test "changes when a draft of the order is edited" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      draft = draft_so!(%{internal_order_uuid: io.uuid, lines: [so_line(item, "10")]})
      before = fingerprint(io)

      {:ok, _} = SupplierOrders.update_draft(draft, %{lines: [so_line(item, "12")]})
      refute before == fingerprint(io)
    end

    test "changes with a new draft and with a posted draft" do
      item = item!()
      io = posted_io!([io_line(item, "10")])
      before = fingerprint(io)

      draft = draft_so!(%{internal_order_uuid: io.uuid, lines: []})
      with_draft = fingerprint(io)
      refute before == with_draft

      {:ok, _} = SupplierOrders.post_supplier_order(draft, nil)
      refute with_draft == fingerprint(io)
    end
  end

  # ---------------------------------------------------------------------------
  # Manual choices
  # ---------------------------------------------------------------------------

  describe "validate_plan_choices/2" do
    setup do
      a = supplier!()
      b = supplier!()
      bystander = supplier!()
      inactive = supplier!(%{status: "inactive"})
      ambiguous_item = item!(%{manufacturer_uuid: manufacturer!([a, b]).uuid})
      covered_item = item!()
      stock!(covered_item, "5")
      gone = uuid()

      io =
        posted_io!([
          io_line(ambiguous_item, "3"),
          io_line(covered_item, "1"),
          io_line(gone, "1")
        ])

      plan = plan!(io)
      [ambiguous, covered, missing] = plan.lines

      %{
        plan: plan,
        a: a,
        bystander: bystander,
        inactive: inactive,
        ambiguous: ambiguous.key,
        covered: covered.key,
        missing: missing.key
      }
    end

    test "a candidate, any active supplier, an upper-case uuid or skip are fine", ctx do
      for choice <- [ctx.a.uuid, ctx.bystander.uuid, String.upcase(ctx.a.uuid), "skip"] do
        assert :ok = SupplierOrders.validate_plan_choices(ctx.plan, %{ctx.ambiguous => choice})
      end

      assert :ok = SupplierOrders.validate_plan_choices(ctx.plan, %{})
    end

    test "an unknown, inactive or malformed supplier is refused", ctx do
      for choice <- [uuid(), ctx.inactive.uuid, "not-a-uuid", nil] do
        assert {:error, {:invalid_choice, key}} =
                 SupplierOrders.validate_plan_choices(ctx.plan, %{ctx.ambiguous => choice})

        assert key == ctx.ambiguous
      end
    end

    test "no choice for a missing item, a line with nothing to order or an unknown key", ctx do
      for key <- [ctx.missing, ctx.covered, "9:#{uuid()}"], choice <- [ctx.a.uuid, "skip"] do
        assert {:error, {:invalid_choice, ^key}} =
                 SupplierOrders.validate_plan_choices(ctx.plan, %{key => choice})
      end
    end
  end
end
