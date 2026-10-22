defmodule PhoenixKitWarehouse.SupplierOrdersApplyPlanTest do
  @moduledoc """
  Writing a plan of "generate supplier orders": the drafts a plan writes into
  (`targets`), `assemble/2` and `merge_into/2` (pure), `apply_plan/5` and the
  generation without choices (`generate_from_internal_order/3`) - one draft
  per (internal order, supplier), what is missing appended to it, nothing sent
  to the trash.

  The races (the lock, the row locks) need two connections and live in
  `SupplierOrdersOneDraftConcurrencyTest`.
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.SupplierOrders

  @location "00000000-0000-0000-0000-000000000001"

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp uuid, do: Ecto.UUID.generate()

  defp unique, do: System.unique_integer([:positive])

  defp dec(value), do: Decimal.new(value)

  defp supplier!(attrs \\ %{}) do
    {:ok, supplier} =
      Catalogue.create_supplier(
        Map.merge(%{name: "Supplier #{unique()}", status: "active"}, attrs)
      )

    supplier
  end

  defp manufacturer!(suppliers) do
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

  # An item whose only supplier is `supplier` (through its manufacturer).
  defp item_of!(supplier, attrs \\ %{}) do
    item!(Map.put(attrs, :manufacturer_uuid, manufacturer!([supplier]).uuid))
  end

  defp info!(item, supplier_uuid, primary?) do
    {:ok, info} =
      Catalogue.create_supplier_info(%{
        item_uuid: item.uuid,
        supplier_uuid: supplier_uuid,
        supplier_source: "local"
      })

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

  defp io_ref(io_uuid), do: %{"type" => "internal_order", "uuid" => io_uuid}
  defp io_ref(io_uuid, lines), do: Map.put(io_ref(io_uuid), "lines", lines)

  defp draft!(supplier, attrs \\ %{}) do
    {:ok, so} =
      SupplierOrders.create_supplier_order(
        Map.merge(%{location_uuid: @location, supplier_uuid: supplier && supplier.uuid}, attrs)
      )

    so
  end

  defp so_line(item, qty, extra \\ %{}) do
    Map.merge(
      %{
        "item_uuid" => item.uuid,
        "name" => item.name,
        "ordered_quantity" => qty,
        "shortfall_quantity" => qty
      },
      extra
    )
  end

  defp plan!(io) do
    {:ok, plan} = SupplierOrders.plan_from_internal_order(io.uuid)
    plan
  end

  defp line_for(plan, item), do: Enum.find(plan.lines, &(&1.item_uuid == item.uuid))

  defp reload(%{uuid: uuid}), do: SupplierOrders.get_supplier_order!(uuid)

  defp live_orders(io) do
    from(o in SupplierOrder,
      where: o.internal_order_uuid == ^io.uuid and is_nil(o.deleted_at),
      order_by: [asc: o.number]
    )
    |> Repo.all()
  end

  defp all_orders_count, do: Repo.aggregate(SupplierOrder, :count)

  defp generate!(io, opts \\ []) do
    {:ok, result} = SupplierOrders.generate_from_internal_order(io, uuid(), opts)
    result
  end

  # What the database gives back for a value written as JSON.
  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp assert_dec(actual, expected) do
    assert Decimal.equal?(StockLedger.to_decimal(actual), dec(expected)),
           "expected #{expected}, got #{inspect(actual)}"
  end

  defp ordered(order, item) do
    order.lines |> Enum.find(&(&1["item_uuid"] == item.uuid)) |> Map.get("ordered_quantity")
  end

  # "Add 10% reserve" of the supplier order form, on one line.
  defp add_reserve(line) do
    shortfall = StockLedger.to_decimal(line["shortfall_quantity"] || "0")
    reserve = Decimal.round(Decimal.mult(shortfall, dec("0.10")), 0, :ceiling)
    Map.put(line, "ordered_quantity", Decimal.max(shortfall, Decimal.add(shortfall, reserve)))
  end

  # ---------------------------------------------------------------------------
  # merge_into/2
  # ---------------------------------------------------------------------------

  describe "merge_into/2" do
    test "a new item goes to the end, the draft's own lines stay as they are" do
      kept = %{"item_uuid" => "a", "ordered_quantity" => dec("3"), "note" => "keeper"}
      new = %{"item_uuid" => "b", "ordered_quantity" => dec("5"), "explanation" => "Why b"}

      assert SupplierOrders.merge_into([kept], [new]) == [kept, new]
    end

    test "an item already there: ordered adds up, shortfall is the new ordered, the rest stays" do
      existing = %{
        "item_uuid" => "a",
        "name" => "Keeper's name",
        "sku" => "K-1",
        "unit" => "box",
        "base_price" => "7.50",
        "custom" => "kept",
        "required_quantity" => "4",
        "on_hand_quantity" => "1",
        "shortfall_quantity" => "3",
        "ordered_quantity" => "4",
        "explanation" => "First"
      }

      new = %{
        "item_uuid" => "a",
        "name" => "Plan name",
        "sku" => "P-1",
        "unit" => "piece",
        "base_price" => dec("9"),
        "required_quantity" => dec("10"),
        "on_hand_quantity" => dec("2"),
        "shortfall_quantity" => dec("6"),
        "ordered_quantity" => dec("6"),
        "explanation" => "First\n\nSecond"
      }

      assert [merged] = SupplierOrders.merge_into([existing], [new])

      assert_dec(merged["ordered_quantity"], "10")
      assert_dec(merged["shortfall_quantity"], "10")
      assert_dec(merged["required_quantity"], "10")
      assert_dec(merged["on_hand_quantity"], "2")
      assert merged["explanation"] == "First\n\nSecond"

      for key <- ~w(name sku unit base_price custom),
          do: assert(merged[key] == existing[key], key)
    end

    test "a line the keeper reduced: shortfall follows ordered, so +10% keeps what was appended" do
      # The plan said 10, the keeper cut the line to 3; the next plan appends 7.
      reduced = %{"item_uuid" => "a", "shortfall_quantity" => "10", "ordered_quantity" => "3"}

      new = %{
        "item_uuid" => "a",
        "shortfall_quantity" => dec("7"),
        "ordered_quantity" => dec("7")
      }

      [merged] = SupplierOrders.merge_into([reduced], [new])
      assert_dec(merged["ordered_quantity"], "10")
      assert_dec(merged["shortfall_quantity"], "10")

      # +10% from shortfall: 10 + 1, never more than that, never less than 10.
      assert_dec(add_reserve(merged)["ordered_quantity"], "11")
    end

    test "an item twice in the draft: only its first line grows, as posting keeps it" do
      first = %{"item_uuid" => "a", "ordered_quantity" => "2", "shortfall_quantity" => "2"}
      second = %{"item_uuid" => "a", "ordered_quantity" => "5", "shortfall_quantity" => "5"}
      free = %{"name" => "No item", "ordered_quantity" => "1"}

      new = %{
        "item_uuid" => "a",
        "ordered_quantity" => dec("4"),
        "shortfall_quantity" => dec("4")
      }

      assert [merged, ^second, ^free] = SupplierOrders.merge_into([first, second, free], [new])
      assert_dec(merged["ordered_quantity"], "6")
    end

    test "the requirement of a combined draft is added to, unless this order's ref counts the item" do
      line = %{"item_uuid" => "a", "required_quantity" => "15", "ordered_quantity" => "15"}

      new = %{
        "item_uuid" => "a",
        "required_quantity" => dec("10"),
        "ordered_quantity" => dec("6")
      }

      counted = MapSet.new(["a"])
      [kept] = SupplierOrders.merge_into([line], [new], required: {:add_except, counted})
      assert_dec(kept["required_quantity"], "15")
      assert_dec(kept["ordered_quantity"], "21")

      [added] = SupplierOrders.merge_into([line], [new], required: {:add_except, MapSet.new()})
      assert_dec(added["required_quantity"], "25")

      [same] = SupplierOrders.merge_into([line], [new], required: :keep)
      assert_dec(same["required_quantity"], "15")
    end

    test "nothing new leaves the lines as they are" do
      lines = [%{"item_uuid" => "a", "ordered_quantity" => "2"}]
      assert SupplierOrders.merge_into(lines, []) == lines
      assert SupplierOrders.merge_into([], []) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Targets of a plan
  # ---------------------------------------------------------------------------

  describe "targets of a plan" do
    test "a draft of the pair wins over a combined one; of two drafts the higher number" do
      sup = supplier!()
      item = item_of!(sup)
      io = posted_io!([io_line(item, "10")])

      combined = draft!(sup, %{source_refs: [io_ref(io.uuid), io_ref(uuid())]})
      older = draft!(sup, %{internal_order_uuid: io.uuid})
      newer = draft!(sup, %{internal_order_uuid: io.uuid, source_refs: [io_ref(io.uuid)]})

      plan = plan!(io)

      assert %{uuid: target_uuid, single_source?: true} = plan.targets[sup.uuid]
      assert target_uuid == newer.uuid
      assert [%{supplier_uuid: group_sup, target: %{uuid: ^target_uuid}}] = plan.groups
      assert group_sup == sup.uuid
      refute target_uuid in [older.uuid, combined.uuid]
    end

    test "with no draft of the pair, a combined draft of the supplier that refers to the order" do
      sup = supplier!()
      item = item_of!(sup)
      io = posted_io!([io_line(item, "10")])

      low = draft!(sup, %{source_refs: [io_ref(io.uuid), io_ref(uuid())]})
      high = draft!(sup, %{source_refs: [io_ref(uuid()), io_ref(io.uuid)]})

      assert %{uuid: uuid, single_source?: false} = plan!(io).targets[sup.uuid]
      assert uuid == high.uuid
      refute uuid == low.uuid
    end

    test "a posted order, a trashed draft, a draft naming the order but referring elsewhere and one without supplier are no targets" do
      sup = supplier!()
      item = item_of!(sup)
      io = posted_io!([io_line(item, "10")])

      {:ok, _posted} =
        sup
        |> draft!(%{internal_order_uuid: io.uuid, lines: [so_line(item, "1")]})
        |> SupplierOrders.post_supplier_order(nil)

      {:ok, _trashed} =
        sup
        |> draft!(%{internal_order_uuid: io.uuid})
        |> SupplierOrders.soft_delete_supplier_order(nil)

      _elsewhere = draft!(sup, %{internal_order_uuid: io.uuid, source_refs: [io_ref(uuid())]})
      _no_supplier = draft!(nil, %{internal_order_uuid: io.uuid})

      plan = plan!(io)
      assert plan.targets == %{}
      assert [%{target: :new}] = plan.groups
    end
  end

  # ---------------------------------------------------------------------------
  # assemble/2
  # ---------------------------------------------------------------------------

  describe "assemble/2" do
    setup do
      a = supplier!()
      b = supplier!()
      c = supplier!()

      a1 = item_of!(a, %{base_price: dec("5")})
      a2 = item_of!(a)
      b1 = item!()
      info!(b1, b.uuid, true)
      info!(b1, c.uuid, false)
      both = item!(%{manufacturer_uuid: manufacturer!([a, b]).uuid})
      orphan = item!()
      covered = item_of!(a)
      stock!(covered, "50")
      gone = uuid()

      io =
        posted_io!([
          io_line(a1, "4", %{"explanation" => "One"}),
          io_line(b1, "3"),
          io_line(both, "2"),
          io_line(orphan, "1"),
          io_line(covered, "5"),
          io_line(gone, "2"),
          io_line(a2, "6"),
          io_line(a1, "1", %{"explanation" => "Two"})
        ])

      draft = draft!(a, %{internal_order_uuid: io.uuid})

      %{
        io: io,
        a: a,
        b: b,
        c: c,
        a1: a1,
        a2: a2,
        b1: b1,
        both: both,
        orphan: orphan,
        covered: covered,
        gone: gone,
        draft: draft
      }
    end

    test "groups by supplier, merges an item's lines, targets the draft or :new", ctx do
      plan = plan!(ctx.io)

      assert %{orders: orders, not_ordered: not_ordered, unplaced: unplaced} =
               SupplierOrders.assemble(plan, %{})

      assert [order_a, order_b] = orders
      assert order_a.supplier_uuid == ctx.a.uuid
      assert order_a.supplier_name == ctx.a.name
      assert order_a.target.uuid == ctx.draft.uuid
      assert order_b.supplier_uuid == ctx.b.uuid
      assert order_b.target == :new

      # a1 twice in the internal order: one line, 4 + 1, both explanations
      assert [line_a1, line_a2] = order_a.lines
      assert line_a1["item_uuid"] == ctx.a1.uuid
      assert_dec(line_a1["ordered_quantity"], "5")
      assert_dec(line_a1["shortfall_quantity"], "5")
      assert_dec(line_a1["required_quantity"], "5")
      assert_dec(line_a1["base_price"], "5")
      assert line_a1["explanation"] == "One\n\nTwo"
      assert line_a1["catalogue_uuid"] == ctx.a1.catalogue_uuid
      assert line_a2["item_uuid"] == ctx.a2.uuid
      assert_dec(line_a2["ordered_quantity"], "6")
      assert length(order_a.keys) == 3

      assert [%{"item_uuid" => b1_uuid}] = order_b.lines
      assert b1_uuid == ctx.b1.uuid

      assert Enum.map(unplaced, & &1.item_uuid) |> Enum.sort() ==
               Enum.sort([ctx.both.uuid, ctx.orphan.uuid])

      assert Enum.map(not_ordered, & &1.item_uuid) |> Enum.sort() ==
               Enum.sort([ctx.covered.uuid, ctx.gone])
    end

    test "a choice reassigns an automatic line, places an ambiguous one, skip drops one", ctx do
      plan = plan!(ctx.io)

      choices = %{
        line_for(plan, ctx.b1).key => String.upcase(ctx.c.uuid),
        line_for(plan, ctx.both).key => ctx.a.uuid,
        line_for(plan, ctx.a2).key => "skip"
      }

      %{orders: orders, unplaced: unplaced} = SupplierOrders.assemble(plan, choices)

      assert [order_a, order_c] = orders
      assert order_a.supplier_uuid == ctx.a.uuid

      assert Enum.map(order_a.lines, & &1["item_uuid"]) == [ctx.a1.uuid, ctx.both.uuid]

      assert order_c.supplier_uuid == ctx.c.uuid
      assert order_c.target == :new
      assert [%{"item_uuid" => b1_uuid}] = order_c.lines
      assert b1_uuid == ctx.b1.uuid

      assert Enum.map(unplaced, & &1.item_uuid) |> Enum.sort() ==
               Enum.sort([ctx.a2.uuid, ctx.orphan.uuid])
    end

    test "choices for lines that cannot be chosen are ignored", ctx do
      plan = plan!(ctx.io)

      choices = %{
        line_for(plan, ctx.covered).key => ctx.b.uuid,
        "99:#{uuid()}" => ctx.b.uuid
      }

      assert SupplierOrders.assemble(plan, choices) == SupplierOrders.assemble(plan, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # apply_plan/5
  # ---------------------------------------------------------------------------

  describe "apply_plan/5" do
    test "writes exactly assemble/2, merged into the target drafts with merge_into/2" do
      a = supplier!()
      b = supplier!()
      c = supplier!()
      a1 = item_of!(a)
      a2 = item_of!(a)
      b1 = item_of!(b)
      both = item!(%{manufacturer_uuid: manufacturer!([a, b]).uuid})
      lone = item!()
      covered = item_of!(a)
      stock!(covered, "9")

      io =
        posted_io!([
          io_line(a1, "10", %{"explanation" => "For the door"}),
          io_line(a2, "4"),
          io_line(b1, "3"),
          io_line(both, "2"),
          io_line(lone, "5"),
          io_line(covered, "1")
        ])

      # The keeper cut a1 to 3 and added a line of their own.
      extra = item!()

      target =
        draft!(a, %{
          internal_order_uuid: io.uuid,
          note: "keeper note",
          lines: [so_line(a1, "3", %{"base_price" => "1.25"}), so_line(extra, "2")]
        })

      plan = plan!(io)

      choices = %{
        line_for(plan, b1).key => c.uuid,
        line_for(plan, both).key => a.uuid
      }

      expected = SupplierOrders.assemble(plan, choices)
      before = all_orders_count()

      assert {:ok, result} =
               SupplierOrders.apply_plan(io.uuid, plan.fingerprint, choices, uuid())

      assert result.superseded == []
      assert [appended] = result.appended
      assert appended.uuid == target.uuid
      assert [created] = result.supplier_orders
      assert all_orders_count() == before + 1

      by_target =
        Map.new(expected.orders, fn
          %{target: :new} = order -> {{:new, order.supplier_uuid}, order}
          order -> {order.target.uuid, order}
        end)

      a_order = Map.fetch!(by_target, target.uuid)
      written_target = reload(target)

      assert written_target.lines == json(SupplierOrders.target_lines(a_order, io.uuid))

      assert written_target.lines ==
               json(SupplierOrders.merge_into(a_order.target.lines, a_order.lines))

      assert written_target.note == "keeper note"
      assert written_target.supplier_uuid == a.uuid

      c_order = Map.fetch!(by_target, {:new, c.uuid})
      written_new = reload(created)
      assert written_new.supplier_uuid == c.uuid
      assert written_new.internal_order_uuid == io.uuid
      assert written_new.location_uuid == @location
      assert written_new.status == "draft"
      assert written_new.lines == json(c_order.lines)

      assert map_size(by_target) == 2

      # a1: 3 + 7 (the keeper's 3 counts as in transit), the new items appended
      assert_dec(ordered(written_target, a1), "10")
      assert_dec(ordered(written_target, a2), "4")
      assert_dec(ordered(written_target, both), "2")
      assert_dec(ordered(written_target, extra), "2")

      assert [%{"reason" => "no_supplier", "item_uuid" => lone_uuid}] = result.unassigned_lines
      assert lone_uuid == lone.uuid
      assert Enum.map(result.skipped, & &1.item_uuid) == [covered.uuid]
    end

    test "source_refs: a new order and a draft of the pair record their actual lines" do
      sup = supplier!()
      a1 = item_of!(sup)
      a2 = item_of!(sup)
      io = posted_io!([io_line(a1, "10"), io_line(a2, "5")])

      # An old draft with no refs and a hand-edited line (cf. a draft made
      # before generation wrote refs).
      old = draft!(sup, %{internal_order_uuid: io.uuid, lines: [so_line(a1, "6")]})

      plan = plan!(io)

      {:ok, %{appended: [appended]}} =
        SupplierOrders.apply_plan(io.uuid, plan.fingerprint, %{}, nil)

      assert appended.uuid == old.uuid

      assert [%{"type" => "internal_order", "uuid" => ref_uuid, "lines" => lines}] =
               reload(old).source_refs

      assert ref_uuid == io.uuid
      assert_dec(lines[a1.uuid], "10")
      assert_dec(lines[a2.uuid], "5")
      assert map_size(lines) == 2

      other_io = posted_io!([io_line(a1, "2")])

      {:ok, %{supplier_orders: [created]}} =
        SupplierOrders.apply_plan(other_io.uuid, plan!(other_io).fingerprint, %{}, nil)

      assert [%{"type" => "internal_order", "uuid" => other_uuid, "lines" => %{} = new_lines}] =
               reload(created).source_refs

      assert other_uuid == other_io.uuid
      assert_dec(new_lines[a1.uuid], "2")
    end

    test "source_refs: a combined draft gets this order's ref topped up, other refs untouched" do
      sup = supplier!()
      a1 = item_of!(sup)
      io = posted_io!([io_line(a1, "10")])
      other_ref = io_ref(uuid(), %{"x" => "3"})

      combined =
        draft!(sup, %{
          lines: [so_line(a1, "7")],
          source_refs: [other_ref, io_ref(io.uuid, %{a1.uuid => "4"})]
        })

      plan = plan!(io)
      assert plan.targets[sup.uuid].uuid == combined.uuid

      {:ok, %{appended: [_]}} = SupplierOrders.apply_plan(io.uuid, plan.fingerprint, %{}, nil)

      written = reload(combined)
      # 4 already ordered for this order, 6 appended
      assert_dec(ordered(written, a1), "13")
      assert [^other_ref, %{"uuid" => ref_uuid, "lines" => lines}] = written.source_refs
      assert ref_uuid == io.uuid
      assert_dec(lines[a1.uuid], "10")
    end

    test "a combined draft keeps the summed requirement; an item new to this order's ref adds to it" do
      sup = supplier!()
      a1 = item_of!(sup)
      a2 = item_of!(sup)
      io = posted_io!([io_line(a1, "10"), io_line(a2, "4")])

      # Imported from this order (a1: 4 so far) and another one: a1 needs
      # 10 + 5 = 15 in all, a2 is there for the other order only.
      combined =
        draft!(sup, %{
          lines: [
            so_line(a1, "9", %{"required_quantity" => "15"}),
            so_line(a2, "3", %{"required_quantity" => "3"})
          ],
          source_refs: [
            io_ref(io.uuid, %{a1.uuid => "4"}),
            io_ref(uuid(), %{a1.uuid => "5", a2.uuid => "3"})
          ]
        })

      plan = plan!(io)
      [order] = SupplierOrders.assemble(plan, %{}).orders
      assert order.target.uuid == combined.uuid

      {:ok, %{appended: [_]}} = SupplierOrders.apply_plan(io.uuid, plan.fingerprint, %{}, nil)

      written = reload(combined)
      assert written.lines == json(SupplierOrders.target_lines(order, io.uuid))

      [line_a1, line_a2] = written.lines
      assert_dec(line_a1["required_quantity"], "15")
      assert_dec(line_a1["ordered_quantity"], "15")
      assert_dec(line_a2["required_quantity"], "7")
      assert_dec(line_a2["ordered_quantity"], "7")
    end

    test "a combined draft linked without \"lines\" keeps that ref: it stands for the whole draft" do
      sup = supplier!()
      a = item_of!(sup)
      b = item_of!(sup)
      io = posted_io!([io_line(a, "5"), io_line(b, "3")])

      # Made with "New" and linked to the order by hand (`add_source_ref/4`).
      linked = draft!(sup, %{lines: [so_line(a, "5")], source_refs: [io_ref(io.uuid)]})

      plan = plan!(io)
      assert plan.targets[sup.uuid].uuid == linked.uuid
      assert_dec(line_for(plan, a).to_order, "0")
      assert_dec(line_for(plan, b).to_order, "3")

      {:ok, %{appended: [_]}} = SupplierOrders.apply_plan(io.uuid, plan.fingerprint, %{}, nil)

      written = reload(linked)
      assert_dec(ordered(written, a), "5")
      assert_dec(ordered(written, b), "3")
      assert written.source_refs == [io_ref(io.uuid)]

      # What was ordered is in transit for the next plan, as it was for this one.
      assert Enum.all?(plan!(io).lines, &Decimal.eq?(&1.to_order, 0))
    end

    test "nothing goes to the trash, with supersede_drafts or without" do
      sup = supplier!()
      item = item_of!(sup)
      io = posted_io!([io_line(item, "10")])
      first = draft!(sup, %{internal_order_uuid: io.uuid})
      second = draft!(sup, %{internal_order_uuid: io.uuid})

      {:ok, %{appended: [appended], superseded: []}} =
        SupplierOrders.apply_plan(io.uuid, plan!(io).fingerprint, %{}, nil,
          supersede_drafts: true
        )

      assert appended.uuid == second.uuid
      assert Enum.map(live_orders(io), & &1.uuid) == [first.uuid, second.uuid]

      assert Activity.list(action: "warehouse.supplier_order.trashed", resource_uuid: first.uuid).entries ==
               []
    end

    test "a stale fingerprint answers the new plan and writes nothing" do
      sup = supplier!()
      other = supplier!()
      item = item_of!(sup)
      io = posted_io!([io_line(item, "10")])
      draft = draft!(sup, %{internal_order_uuid: io.uuid, lines: [so_line(item, "2")]})

      changes = [
        stock: fn -> stock!(item, "1") end,
        draft_edited: fn ->
          {:ok, _} = SupplierOrders.update_draft(draft, %{lines: [so_line(item, "3")]})
        end,
        new_draft: fn -> draft!(other, %{internal_order_uuid: io.uuid}) end,
        supplier_deactivated: fn ->
          {:ok, _} = Catalogue.update_supplier(other, %{status: "inactive"})
        end,
        draft_posted: fn -> {:ok, _} = SupplierOrders.post_supplier_order(reload(draft), nil) end
      ]

      for {name, change} <- changes do
        plan = plan!(io)
        change.()
        snapshot = Repo.all(from(o in SupplierOrder, order_by: o.uuid))

        assert {:error, {:stale, new_plan}} =
                 SupplierOrders.apply_plan(io.uuid, plan.fingerprint, %{}, nil),
               "#{name}"

        refute new_plan.fingerprint == plan.fingerprint
        assert new_plan.fingerprint == plan!(io).fingerprint
        assert Repo.all(from(o in SupplierOrder, order_by: o.uuid)) == snapshot, "#{name}"
      end
    end

    test "a target warehouse change within the same timestamp makes the preview stale" do
      supplier = supplier!()
      item = item_of!(supplier)
      io = posted_io!([io_line(item, "10")])
      draft = draft!(supplier, %{internal_order_uuid: io.uuid, lines: [so_line(item, "2")]})
      plan = plan!(io)

      Repo.update_all(from(o in SupplierOrder, where: o.uuid == ^draft.uuid),
        set: [location_uuid: uuid()]
      )

      moved = reload(draft)
      assert moved.updated_at == draft.updated_at

      assert {:error, {:stale, _}} =
               SupplierOrders.apply_plan(io.uuid, plan.fingerprint, %{}, nil)

      assert reload(draft) == moved
      assert length(live_orders(io)) == 1
    end

    test "a closed link, an unlinked manufacturer or a new primary make the plan stale" do
      a = supplier!()
      b = supplier!()
      linked = item!()
      info = info!(linked, a.uuid, false)
      mfr = manufacturer!([a, b])
      via_mfr = item!(%{manufacturer_uuid: mfr.uuid})
      primary_item = item!()
      info!(primary_item, a.uuid, true)
      info_b = info!(primary_item, b.uuid, false)
      io = posted_io!([io_line(linked, "1"), io_line(via_mfr, "1"), io_line(primary_item, "1")])

      changes = [
        fn -> {:ok, _} = Catalogue.update_supplier_info(info, %{valid_to: Date.utc_today()}) end,
        fn -> {:ok, _} = Catalogue.unlink_manufacturer_supplier(mfr.uuid, b.uuid) end,
        fn -> {:ok, _} = Catalogue.set_primary_supplier_info(info_b) end
      ]

      for change <- changes do
        plan = plan!(io)
        change.()
        before = all_orders_count()

        assert {:error, {:stale, _}} =
                 SupplierOrders.apply_plan(io.uuid, plan.fingerprint, %{}, nil)

        assert all_orders_count() == before
      end
    end

    test "invalid choices are refused and nothing is written" do
      a = supplier!()
      b = supplier!()
      ambiguous = item!(%{manufacturer_uuid: manufacturer!([a, b]).uuid})
      covered = item_of!(a)
      stock!(covered, "10")
      gone = uuid()
      io = posted_io!([io_line(ambiguous, "2"), io_line(covered, "1"), io_line(gone, "1")])
      plan = plan!(io)
      key = line_for(plan, ambiguous).key

      for {bad_key, choices} <- [
            {key, %{key => uuid()}},
            {key, %{key => "not-a-uuid"}},
            {line_for(plan, covered).key, %{line_for(plan, covered).key => a.uuid}},
            {"2:#{gone}", %{"2:#{gone}" => a.uuid}}
          ] do
        before = all_orders_count()

        assert {:error, {:invalid_choice, ^bad_key}} =
                 SupplierOrders.apply_plan(io.uuid, plan.fingerprint, choices, nil)

        assert all_orders_count() == before
      end
    end

    test "an upper-case supplier uuid is written as the supplier" do
      a = supplier!()
      b = supplier!()
      ambiguous = item!(%{manufacturer_uuid: manufacturer!([a, b]).uuid})
      io = posted_io!([io_line(ambiguous, "2")])
      plan = plan!(io)
      choices = %{line_for(plan, ambiguous).key => String.upcase(b.uuid)}

      assert {:ok, %{supplier_orders: [created]}} =
               SupplierOrders.apply_plan(io.uuid, plan.fingerprint, choices, nil)

      assert reload(created).supplier_uuid == b.uuid
    end

    test "a missing, unposted or trashed internal order" do
      assert {:error, :not_found} = SupplierOrders.apply_plan(uuid(), "x", %{}, nil)
      assert {:error, :not_found} = SupplierOrders.apply_plan("nope", "x", %{}, nil)

      {:ok, draft} = InternalOrders.create_internal_order(%{location_uuid: @location})
      assert {:error, :not_posted} = SupplierOrders.apply_plan(draft.uuid, "x", %{}, nil)

      io = posted_io!([io_line(item_of!(supplier!()), "1")])
      plan = plan!(io)

      Repo.update_all(from(o in InternalOrder, where: o.uuid == ^io.uuid),
        set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      assert {:error, :deleted} = SupplierOrders.apply_plan(io.uuid, plan.fingerprint, %{}, nil)
      assert live_orders(io) == []
    end
  end

  # ---------------------------------------------------------------------------
  # generate_from_internal_order/3: the same path without choices
  # ---------------------------------------------------------------------------

  describe "generate_from_internal_order/3" do
    test "appends to the live draft of the pair; the keeper's edits and note stay" do
      sup = supplier!()
      a1 = item_of!(sup)
      a2 = item_of!(sup)
      io = posted_io!([io_line(a1, "10"), io_line(a2, "4")])
      keeper = item!()

      draft =
        draft!(sup, %{
          internal_order_uuid: io.uuid,
          note: "call first",
          lines: [so_line(a1, "12", %{"base_price" => "3"}), so_line(keeper, "1")]
        })

      result = generate!(io)

      assert result.supplier_orders == []
      assert [appended] = result.appended
      assert appended.uuid == draft.uuid

      written = reload(draft)
      assert written.note == "call first"
      # a1 is covered by the keeper's 12 already; a2 is appended
      assert Enum.map(written.lines, & &1["item_uuid"]) == [a1.uuid, keeper.uuid, a2.uuid]
      assert_dec(ordered(written, a1), "12")
      assert written.lines |> hd() |> Map.get("base_price") == "3"
      assert_dec(ordered(written, a2), "4")
      assert [draft.uuid] == Enum.map(live_orders(io), & &1.uuid)
    end

    test "a line the keeper removed or reduced is ordered again into the same draft" do
      sup = supplier!()
      a1 = item_of!(sup)
      a2 = item_of!(sup)
      io = posted_io!([io_line(a1, "10"), io_line(a2, "5")])

      %{supplier_orders: [draft]} = generate!(io)

      {:ok, _} =
        SupplierOrders.update_draft(draft, %{
          lines: [draft.lines |> hd() |> Map.put("ordered_quantity", "3")]
        })

      %{supplier_orders: [], appended: [appended]} = generate!(io)
      assert appended.uuid == draft.uuid

      written = reload(draft)
      assert_dec(ordered(written, a1), "10")
      assert_dec(ordered(written, a2), "5")

      a1_line = Enum.find(written.lines, &(&1["item_uuid"] == a1.uuid))
      assert_dec(a1_line["shortfall_quantity"], "10")
      assert_dec(add_reserve(a1_line)["ordered_quantity"], "11")
    end

    test "a second generation with nothing missing writes nothing" do
      sup = supplier!()
      io = posted_io!([io_line(item_of!(sup), "10")])

      %{supplier_orders: [draft]} = generate!(io)
      updated_at = reload(draft).updated_at

      assert %{supplier_orders: [], appended: [], unassigned_lines: [], superseded: []} =
               generate!(io)

      assert reload(draft).updated_at == updated_at
    end

    test "a combined draft linked without \"lines\": a second generation orders nothing again" do
      sup = supplier!()
      a = item_of!(sup)
      b = item_of!(sup)
      io = posted_io!([io_line(a, "5"), io_line(b, "3")])
      linked = draft!(sup, %{lines: [so_line(a, "5")], source_refs: [io_ref(io.uuid)]})

      assert %{supplier_orders: [], appended: [_]} = generate!(io)
      assert %{supplier_orders: [], appended: []} = generate!(io)

      written = reload(linked)
      assert_dec(ordered(written, a), "5")
      assert_dec(ordered(written, b), "3")
      assert length(written.lines) == 2
    end

    test "writes source_refs, so an import afterwards sees what is ordered" do
      sup = supplier!()
      item = item_of!(sup)
      io = posted_io!([io_line(item, "10")])

      %{supplier_orders: [generated]} = generate!(io)
      assert [%{"uuid" => ref_uuid, "lines" => lines}] = generated.source_refs
      assert ref_uuid == io.uuid
      assert_dec(lines[item.uuid], "10")

      other = draft!(sup)
      {:ok, imported} = SupplierOrders.import_from_internal_orders(other, [io.uuid], nil)
      assert imported.lines == []
    end

    test "unassigned lines say why; nothing to order is reported as skipped" do
      a = supplier!()
      b = supplier!()
      ambiguous = item!(%{manufacturer_uuid: manufacturer!([a, b]).uuid})
      lone = item!()
      covered = item_of!(a)
      stock!(covered, "10")
      gone = uuid()

      io =
        posted_io!([
          io_line(ambiguous, "2"),
          io_line(lone, "1"),
          io_line(covered, "1"),
          io_line(gone, "3", %{"explanation" => "why"})
        ])

      result = generate!(io)

      assert result.supplier_orders == []

      assert Enum.map(result.unassigned_lines, &{&1["item_uuid"], &1["reason"]}) == [
               {ambiguous.uuid, "ambiguous"},
               {lone.uuid, "no_supplier"},
               {gone, "no_item"}
             ]

      assert List.last(result.unassigned_lines)["explanation"] == "why"
      assert_dec(List.last(result.unassigned_lines)["ordered_quantity"], "3")
      assert [%{item_uuid: covered_uuid, zero_reason: :on_hand}] = result.skipped
      assert covered_uuid == covered.uuid
    end

    test "a line without a supplier, partly in a draft: the rest is appended to that draft" do
      sup = supplier!()
      lone = item!()
      ambiguous = item!(%{manufacturer_uuid: manufacturer!([supplier!(), supplier!()]).uuid})
      io = posted_io!([io_line(lone, "4"), io_line(ambiguous, "3")])

      draft =
        draft!(sup, %{
          internal_order_uuid: io.uuid,
          lines: [so_line(lone, "1"), so_line(ambiguous, "1")]
        })

      result = generate!(io)

      assert result.supplier_orders == []
      assert [%{uuid: appended_uuid}] = result.appended
      assert appended_uuid == draft.uuid
      assert result.unassigned_lines == []

      written = reload(draft)
      assert_dec(ordered(written, lone), "4")
      assert_dec(ordered(written, ambiguous), "3")
      assert length(written.lines) == 2
      assert [draft.uuid] == Enum.map(live_orders(io), & &1.uuid)

      # Nothing is missing any more: a second generation writes nothing.
      assert %{supplier_orders: [], appended: []} = generate!(io)
    end

    test "a preselected line chosen \"do not order\" is not appended" do
      sup = supplier!()
      lone = item!()
      io = posted_io!([io_line(lone, "4")])
      draft = draft!(sup, %{internal_order_uuid: io.uuid, lines: [so_line(lone, "1")]})

      plan = plan!(io)
      key = line_for(plan, lone).key

      assert %{orders: [%{supplier_uuid: placed_sup, target: %{uuid: target}}]} =
               SupplierOrders.assemble(plan, %{})

      assert {placed_sup, target} == {sup.uuid, draft.uuid}

      assert {:ok, result} =
               SupplierOrders.apply_plan(io.uuid, plan.fingerprint, %{key => "skip"}, uuid())

      assert result.appended == []
      assert [%{"reason" => "skipped"}] = result.unassigned_lines
      assert_dec(ordered(reload(draft), lone), "1")
    end

    test "an unposted internal order is :not_posted" do
      {:ok, draft} =
        InternalOrders.create_internal_order(%{
          location_uuid: @location,
          lines: [io_line(item_of!(supplier!()), "1")]
        })

      assert {:error, :not_posted} = SupplierOrders.generate_from_internal_order(draft, nil)
    end

    test "the internal order is read again, not taken from the struct" do
      sup = supplier!()
      item = item_of!(sup)
      io = posted_io!([io_line(item, "10")])

      %{supplier_orders: [so]} = generate!(%{io | lines: []})
      assert_dec(ordered(so, item), "10")
    end
  end

  # ---------------------------------------------------------------------------
  # Import: the same supplier rules
  # ---------------------------------------------------------------------------

  describe "import_from_internal_orders/3" do
    test "resolves the supplier like the plan: a primary link wins over the manufacturer's" do
      primary = supplier!()
      other = supplier!()
      item = item!(%{manufacturer_uuid: manufacturer!([primary, other]).uuid})
      info!(item, primary.uuid, true)
      io = posted_io!([io_line(item, "4")])

      assert line_for(plan!(io), item).auto_supplier_uuid == primary.uuid

      {:ok, into_other} =
        SupplierOrders.import_from_internal_orders(draft!(other), [io.uuid], nil)

      assert into_other.lines == []

      {:ok, into_primary} =
        SupplierOrders.import_from_internal_orders(draft!(primary), [io.uuid], nil)

      assert_dec(ordered(into_primary, item), "4")
    end

    test "a CRM supplier of the manufacturer is its local projection, as in the plan" do
      company = uuid()
      local = supplier!()

      Repo.update_all(
        from(s in PhoenixKitCatalogue.Schemas.Supplier, where: s.uuid == ^local.uuid),
        set: [crm_company_uuid: company]
      )

      {:ok, mfr} = Catalogue.create_manufacturer(%{name: "Mfr #{unique()}", status: "active"})
      Catalogue.link_manufacturer_supplier(mfr.uuid, company, supplier_source: "crm_company")
      item = item!(%{manufacturer_uuid: mfr.uuid})
      io = posted_io!([io_line(item, "3")])

      {:ok, imported} = SupplierOrders.import_from_internal_orders(draft!(local), [io.uuid], nil)
      assert_dec(ordered(imported, item), "3")
    end

    test "reads the draft under its lock, not from a stale struct" do
      sup = supplier!()
      item = item_of!(sup)
      keeper = item!()
      io = posted_io!([io_line(item, "4")])
      draft = draft!(sup)

      {:ok, _} = SupplierOrders.update_draft(draft, %{lines: [so_line(keeper, "1")]})

      {:ok, imported} = SupplierOrders.import_from_internal_orders(draft, [io.uuid], nil)
      assert Enum.map(imported.lines, & &1["item_uuid"]) == [keeper.uuid, item.uuid]
    end

    test "a combined draft linked without \"lines\" keeps that ref; generation orders nothing again" do
      sup = supplier!()
      a = item_of!(sup)
      b = item_of!(sup)
      c = item_of!(sup)
      y = posted_io!([io_line(c, "2")])
      x = posted_io!([io_line(a, "5"), io_line(b, "3")])

      combined =
        draft!(sup, %{
          internal_order_uuid: y.uuid,
          lines: [so_line(c, "2"), so_line(a, "5")],
          source_refs: [io_ref(y.uuid, %{c.uuid => "2"}), io_ref(x.uuid)]
        })

      {:ok, imported} = SupplierOrders.import_from_internal_orders(combined, [x.uuid], nil)
      # A is covered by the whole draft; only B is missing.
      assert_dec(ordered(imported, a), "5")
      assert_dec(ordered(imported, b), "3")
      assert Enum.find(imported.source_refs, &(&1["uuid"] == x.uuid)) == io_ref(x.uuid)

      assert %{supplier_orders: [], appended: []} = generate!(x)
      updated_at = reload(combined).updated_at
      assert %{supplier_orders: [], appended: []} = generate!(x)

      written = reload(combined)
      assert written.updated_at == updated_at
      assert_dec(ordered(written, a), "5")
      assert_dec(ordered(written, b), "3")
      assert_dec(ordered(written, c), "2")
      assert length(written.lines) == 3
    end
  end
end
