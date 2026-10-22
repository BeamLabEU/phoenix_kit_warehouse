defmodule PhoenixKitWarehouse.InventoryAI.ApplyTest do
  # Applying a proposal to the lines of a draft (spec §11.1, §11.2, §11.6):
  # one transaction, the tab's base checked, the run claimed once, every
  # row checked before anything is written, the rules of the lines, the
  # invariant counted_quantity = base_qty + Σ ai_parts on every line.
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.InventoryAIFixtures

  alias PhoenixKit.Activity
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryAI
  alias PhoenixKitWarehouse.InventoryAI.Lines

  setup do
    user = user!()
    location = Ecto.UUID.generate()
    catalogue = catalogue!("Fittings")
    hinge = item!(catalogue, %{name: "Hinge"})
    screw = item!(catalogue, %{name: "Screw"})
    stock!(hinge, location, "500")

    %{user: user, location: location, catalogue: catalogue, hinge: hinge, screw: screw}
  end

  # The catalogue numbers of the setup: 1 Hinge, 2 Screw.
  defp run!(doc, ctx, place, objects),
    do: proposed_run!(doc, place, objects, [ctx.catalogue.uuid])

  defp base(doc), do: Inventories.fingerprint(doc)
  defp lines(doc), do: Inventories.get_document!(doc.uuid).lines
  defp line(doc, item), do: Enum.find(lines(doc), &(&1["item_uuid"] == item.uuid))
  defp eq?(value, expected), do: Decimal.equal?(Lines.decimal(value), Decimal.new(expected))

  defp row(n, item, quantity, extra \\ %{}),
    do: Map.merge(%{"row" => n, "item_uuid" => item.uuid, "quantity" => quantity}, extra)

  # Apply as a tab that has just loaded the document.
  defp apply!(doc, run, rows, user) do
    {:ok, loaded} = Inventories.get_document_with_fingerprint(doc.uuid)

    {:ok, applied} =
      InventoryAI.apply_run(run, loaded.fingerprint, loaded.lines, rows, user,
        inventory_uuid: doc.uuid
      )

    applied
  end

  defp assert_invariant(doc) do
    for line <- lines(doc),
        do: assert(Lines.invariant?(line), "invariant broken: #{inspect(line)}")
  end

  describe "the rules on the document's lines" do
    test "a new warehouse's proposal cannot save the old warehouse's edit buffer", ctx do
      doc = draft!(ctx.location, [])
      old_base = base(doc)
      old_lines = [%{"item_uuid" => ctx.hinge.uuid, "counted_quantity" => "20"}]
      {:ok, moved} = Inventories.update_draft(doc, %{location_uuid: Ecto.UUID.generate()})
      assert moved.lines == []
      run = run!(moved, ctx, "B", [object(%{"catalogue_no" => 2, "loose_units" => 9})])

      assert {:error, :stale} =
               InventoryAI.apply_run(run, old_base, old_lines, [row(1, ctx.screw, "9")], ctx.user,
                 inventory_uuid: doc.uuid
               )

      assert lines(doc) == []
      assert InventoryAI.get_run(doc.uuid, run.uuid).status == "proposed"
    end

    test "a seeded line is replaced by default", ctx do
      doc = draft!(ctx.location)
      run = run!(doc, ctx, "Shelf A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])

      %{document: written, run: applied, summary: summary} =
        apply!(doc, run, [row(1, ctx.hinge, "480")], ctx.user)

      hinge = line(doc, ctx.hinge)
      assert eq?(hinge["counted_quantity"], "480")
      assert eq?(hinge["base_qty"], "0")
      assert hinge["counted_by"] == "ai"
      assert [%{"place" => "Shelf A", "run_uuid" => run_uuid}] = hinge["ai_parts"]
      assert run_uuid == run.uuid
      assert hinge["ai_basis"] =~ "Shelf A: 480"
      assert_invariant(doc)

      assert applied.status == "applied"
      assert applied.applied_by_uuid == ctx.user.uuid
      assert %DateTime{} = applied.applied_at
      assert summary == %{applied: 1, replaced: 1, added: 0, new: 0, below_stock: 1}

      # The tab's new buffer and base, together.
      assert written.fingerprint == base(doc)
      assert written.lines == lines(doc)
    end

    test "a seeded line stays seeded when its stock changed after the seed", ctx do
      doc = draft!(ctx.location)
      stock!(ctx.hinge, ctx.location, "600")
      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 20})])

      apply!(doc, run, [row(1, ctx.hinge, "20")], ctx.user)

      assert eq?(line(doc, ctx.hinge)["counted_quantity"], "20")
    end

    test "seeded, add: the seeded number is the base", ctx do
      doc = draft!(ctx.location)
      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 20})])

      %{summary: summary} =
        apply!(doc, run, [row(1, ctx.hinge, "20", %{"action" => "add"})], ctx.user)

      hinge = line(doc, ctx.hinge)
      assert eq?(hinge["counted_quantity"], "520")
      assert hinge["base_source"] == "stock"
      assert summary.added == 1
      assert_invariant(doc)
    end

    test "a line without the mark is seeded when it equals the stock (\"500\" against 500.000000)",
         ctx do
      doc = draft!(ctx.location, [%{"item_uuid" => ctx.hinge.uuid, "counted_quantity" => "500"}])
      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 30})])

      apply!(doc, run, [row(1, ctx.hinge, "30")], ctx.user)

      assert eq?(line(doc, ctx.hinge)["counted_quantity"], "30")
    end

    test "a line without the mark that differs from the stock is a hand count: added to", ctx do
      doc = draft!(ctx.location, [%{"item_uuid" => ctx.hinge.uuid, "counted_quantity" => "120"}])
      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 30})])

      apply!(doc, run, [row(1, ctx.hinge, "30")], ctx.user)

      hinge = line(doc, ctx.hinge)
      assert eq?(hinge["counted_quantity"], "150")
      assert eq?(hinge["base_qty"], "120")
      assert hinge["base_source"] == "manual"
    end

    test "hand count 120, place A gives 30: 150; A again gives 35: 155, not 185 and not 35",
         ctx do
      doc =
        draft!(ctx.location, [
          %{"item_uuid" => ctx.hinge.uuid, "counted_quantity" => "120", "counted_by" => "manual"}
        ])

      first = run!(doc, ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 30})])
      apply!(doc, first, [row(1, ctx.hinge, "30")], ctx.user)
      assert eq?(line(doc, ctx.hinge)["counted_quantity"], "150")

      second = run!(doc, ctx, " a ", [object(%{"catalogue_no" => 1, "loose_units" => 35})])
      %{summary: summary} = apply!(doc, second, [row(1, ctx.hinge, "35")], ctx.user)

      hinge = line(doc, ctx.hinge)
      assert eq?(hinge["counted_quantity"], "155")
      assert eq?(hinge["base_qty"], "120")
      assert length(hinge["ai_parts"]) == 1
      assert summary.replaced == 1
      assert_invariant(doc)
    end

    test "another place adds a part; retaking A with A and B changes only A", ctx do
      doc = draft!(ctx.location, [])

      apply!(
        doc,
        run!(doc, ctx, "A", [object(%{"catalogue_no" => 2, "loose_units" => 100})]),
        [row(1, ctx.screw, "100")],
        ctx.user
      )

      apply!(
        doc,
        run!(doc, ctx, "B", [object(%{"catalogue_no" => 2, "loose_units" => 50})]),
        [row(1, ctx.screw, "50")],
        ctx.user
      )

      assert eq?(line(doc, ctx.screw)["counted_quantity"], "150")

      apply!(
        doc,
        run!(doc, ctx, "A", [object(%{"catalogue_no" => 2, "loose_units" => 70})]),
        [row(1, ctx.screw, "70")],
        ctx.user
      )

      screw = line(doc, ctx.screw)
      assert eq?(screw["counted_quantity"], "120")
      assert Enum.map(screw["ai_parts"], & &1["place"]) == ["A", "B"]
      assert_invariant(doc)
    end

    test "two runs with empty place labels add up", ctx do
      doc = draft!(ctx.location, [])

      apply!(
        doc,
        run!(doc, ctx, nil, [object(%{"catalogue_no" => 2, "loose_units" => 30})]),
        [row(1, ctx.screw, "30")],
        ctx.user
      )

      apply!(
        doc,
        run!(doc, ctx, "", [object(%{"catalogue_no" => 2, "loose_units" => 20})]),
        [row(1, ctx.screw, "20")],
        ctx.user
      )

      assert eq?(line(doc, ctx.screw)["counted_quantity"], "50")
      assert_invariant(doc)
    end

    test "a new item becomes a new line, as Add item builds it", ctx do
      doc = draft!(ctx.location)
      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => 2, "loose_units" => 9})])

      %{summary: summary} = apply!(doc, run, [row(1, ctx.screw, "9")], ctx.user)

      screw = line(doc, ctx.screw)
      assert screw["name"] == "Screw"
      assert screw["unit"] == "piece"
      assert screw["catalogue_uuid"] == ctx.catalogue.uuid
      assert eq?(screw["unit_value"], "2.00")
      assert eq?(screw["counted_quantity"], "9")
      assert summary.new == 1
    end

    test "a new line takes the item's name in the page's language, as Add item does", ctx do
      bolt =
        item!(ctx.catalogue, %{
          name: "Bolt",
          data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "Bolt"},
            "et" => %{"_name" => "Polt"}
          }
        })

      doc = draft!(ctx.location)
      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 3})])
      {:ok, loaded} = Inventories.get_document_with_fingerprint(doc.uuid)
      [proposed] = run.result["rows"]
      number = proposed["row"]

      {:ok, _} =
        InventoryAI.apply_run(
          run,
          loaded.fingerprint,
          loaded.lines,
          [row(number, bolt, "3")],
          ctx.user,
          inventory_uuid: doc.uuid,
          locale: "et"
        )

      assert line(doc, bolt)["name"] == "Polt"
    end

    test "lines no photo saw are not touched", ctx do
      doc = draft!(ctx.location)
      before = line(doc, ctx.hinge)
      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => 2, "loose_units" => 9})])

      apply!(doc, run, [row(1, ctx.screw, "9")], ctx.user)

      assert line(doc, ctx.hinge) == before
    end

    test "the item a person chose instead of the proposal's", ctx do
      doc = draft!(ctx.location, [])
      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => nil, "loose_units" => 4})])

      apply!(doc, run, [row(1, ctx.screw, "4")], ctx.user)

      assert eq?(line(doc, ctx.screw)["counted_quantity"], "4")
    end

    test "the tab's unsaved edits are the starting point, as Save draft writes them", ctx do
      doc = draft!(ctx.location)
      {:ok, loaded} = Inventories.get_document_with_fingerprint(doc.uuid)

      edited = [
        %{
          "item_uuid" => ctx.screw.uuid,
          "counted_quantity" => Decimal.new(3),
          "counted_by" => "manual"
        }
        | loaded.lines
      ]

      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => 2, "loose_units" => 9})])

      {:ok, _} =
        InventoryAI.apply_run(run, loaded.fingerprint, edited, [row(1, ctx.screw, "9")], ctx.user,
          inventory_uuid: doc.uuid
        )

      assert eq?(line(doc, ctx.screw)["counted_quantity"], "12")
      assert line(doc, ctx.hinge)
    end

    test "how it was counted: the formula, or what the person typed", ctx do
      doc = draft!(ctx.location, [])

      run =
        run!(doc, ctx, "A", [
          object(%{
            "catalogue_no" => 2,
            "closed_packages" => 2,
            "open_packages" => 1,
            "units_per_package" => 100,
            "loose_units" => nil
          })
        ])

      apply!(doc, run, [row(1, ctx.screw, "235")], ctx.user)
      assert line(doc, ctx.screw)["ai_basis"] == "A: 2×100 + ⌊1×100×0.35⌋ = 235"

      retake = run!(doc, ctx, "A", [object(%{"catalogue_no" => 2, "loose_units" => 9})])
      apply!(doc, retake, [row(1, ctx.screw, "11")], ctx.user)
      assert line(doc, ctx.screw)["ai_basis"] == "A: entered by hand: 11"
    end

    test "the units per package a person typed count in the formula", ctx do
      doc = draft!(ctx.location, [])

      run =
        run!(doc, ctx, "A", [
          object(%{"catalogue_no" => 2, "closed_packages" => 3, "loose_units" => nil})
        ])

      apply!(doc, run, [row(1, ctx.screw, "30", %{"package_size" => "10"})], ctx.user)

      assert line(doc, ctx.screw)["ai_basis"] =~ "3×10"
    end
  end

  describe "rows the table merged" do
    test "a merged row counts the formulas of all its rows and keeps them in the decisions",
         ctx do
      doc = draft!(ctx.location, [])

      run =
        run!(doc, ctx, "A", [
          object(%{"catalogue_no" => 2, "loose_units" => 9}),
          object(%{"object_key" => "B", "catalogue_no" => nil, "loose_units" => 4})
        ])

      %{run: applied} =
        apply!(doc, run, [row(1, ctx.screw, "13", %{"merged_rows" => [2]})], ctx.user)

      screw = line(doc, ctx.screw)
      assert eq?(screw["counted_quantity"], "13")
      assert screw["ai_basis"] == "A: 9, 4"
      assert [%{"row" => 1, "merged_rows" => [2]}] = applied.decisions["rows"]
      assert_invariant(doc)
    end

    test "a merged row number that is not in the proposal, or stands twice, is refused", ctx do
      doc = draft!(ctx.location, [])

      run =
        run!(doc, ctx, "A", [
          object(%{"catalogue_no" => 2, "loose_units" => 9}),
          object(%{"object_key" => "B", "catalogue_no" => 1, "loose_units" => 4})
        ])

      {:ok, loaded} = Inventories.get_document_with_fingerprint(doc.uuid)

      apply = fn rows ->
        InventoryAI.apply_run(run, loaded.fingerprint, loaded.lines, rows, ctx.user,
          inventory_uuid: doc.uuid
        )
      end

      assert {:error, {:invalid_rows, [%{row: 1, field: "merged_rows", error: :unknown}]}} =
               apply.([row(1, ctx.screw, "13", %{"merged_rows" => [7]})])

      assert {:error, {:invalid_rows, [%{row: 1, field: "merged_rows", error: :unknown}]}} =
               apply.([row(1, ctx.screw, "13", %{"merged_rows" => "2"})])

      assert {:error, {:invalid_rows, [%{row: 2, field: "row", error: :repeated}]}} =
               apply.([
                 row(1, ctx.screw, "13", %{"merged_rows" => [2]}),
                 row(2, ctx.hinge, "4")
               ])

      assert InventoryAI.get_run(doc.uuid, run.uuid).status == "proposed"
    end
  end

  describe "what is kept" do
    test "the decisions in the run and the journal entry", ctx do
      doc = draft!(ctx.location)
      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])

      %{run: applied} = apply!(doc, run, [row(1, ctx.hinge, "480")], ctx.user)

      assert [decision] = applied.decisions["rows"]
      assert decision["item_uuid"] == ctx.hinge.uuid
      assert decision["action"] == "replace"
      assert eq?(decision["previous_counted_quantity"], "500")
      assert eq?(decision["counted_quantity"], "480")

      assert [entry] =
               Activity.list(action: "warehouse.inventory.ai_applied", resource_uuid: doc.uuid).entries

      assert entry.metadata["run_uuid"] == run.uuid
      assert entry.metadata["applied"] == 1
      assert entry.metadata["below_stock"] == 1
      assert entry.actor_uuid == ctx.user.uuid
    end

    test "posting keeps the keys of the photo inventory", ctx do
      doc = draft!(ctx.location)
      run = run!(doc, ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      apply!(doc, run, [row(1, ctx.hinge, "480")], ctx.user)

      {:ok, posted} =
        Inventories.post_document(Inventories.get_document!(doc.uuid), ctx.user.uuid)

      hinge = Enum.find(posted.lines, &(&1["item_uuid"] == ctx.hinge.uuid))
      assert hinge["counted_by"] == "ai"
      assert [_part] = hinge["ai_parts"]
    end
  end

  describe "refusals - nothing is written, the run stays proposed" do
    setup ctx do
      doc = draft!(ctx.location)

      run =
        run!(doc, ctx, "A", [
          object(%{"catalogue_no" => 1, "loose_units" => 480}),
          object(%{"object_key" => "B", "catalogue_no" => 2, "loose_units" => 5})
        ])

      {:ok, loaded} = Inventories.get_document_with_fingerprint(doc.uuid)
      %{doc: doc, run: run, loaded: loaded}
    end

    defp refused(ctx, rows, base \\ nil, lines \\ nil) do
      result =
        InventoryAI.apply_run(
          ctx.run,
          base || ctx.loaded.fingerprint,
          lines || ctx.loaded.lines,
          rows,
          ctx.user,
          inventory_uuid: ctx.doc.uuid
        )

      assert InventoryAI.get_run(ctx.doc.uuid, ctx.run.uuid).status == "proposed"
      assert lines(ctx.doc) == ctx.loaded.lines
      result
    end

    test "a blank or unreadable quantity is an error of the field, never 0", ctx do
      for bad <- ["", "  ", "abc", nil] do
        assert {:error, {:invalid_rows, [%{row: 1, field: "quantity", error: :invalid}]}} =
                 refused(ctx, [row(1, ctx.hinge, bad)])
      end
    end

    test "a quantity that is not a finite number below 10^12 is an error, never written", ctx do
      for bad <- [
            Decimal.new("NaN"),
            Decimal.new("Infinity"),
            Decimal.new("-Infinity"),
            "1000000000000"
          ] do
        assert {:error, {:invalid_rows, [%{row: 1, field: "quantity"}]}} =
                 refused(ctx, [row(1, ctx.hinge, bad)])
      end
    end

    test "a package size that is not a finite number above 0 is an error", ctx do
      for bad <- [Decimal.new("NaN"), Decimal.new("Infinity"), "0", "-2", "abc"] do
        assert {:error, {:invalid_rows, [%{row: 1, field: "package_size", error: :invalid}]}} =
                 refused(ctx, [row(1, ctx.hinge, "480", %{"package_size" => bad})])
      end
    end

    test "a negative quantity is an error, not cut to 0", ctx do
      assert {:error, {:invalid_rows, [%{row: 1, field: "quantity", error: :negative}]}} =
               refused(ctx, [row(1, ctx.hinge, "-5")])
    end

    test "one bad row stops the good ones too", ctx do
      assert {:error, {:invalid_rows, [%{row: 2}]}} =
               refused(ctx, [row(1, ctx.hinge, "480"), row(2, ctx.screw, "")])
    end

    test "a row that is not in the run's proposal", ctx do
      assert {:error, {:invalid_rows, [%{row: 9, field: "row", error: :unknown}]}} =
               refused(ctx, [row(9, ctx.hinge, "1")])
    end

    test "an item that is not there or not active", ctx do
      inactive = item!(ctx.catalogue, %{status: "inactive"})

      assert {:error, {:invalid_rows, [%{row: 1, field: "item_uuid", error: :not_active}]}} =
               refused(ctx, [row(1, inactive, "1")])

      assert {:error, {:invalid_rows, [%{row: 1, field: "item_uuid", error: :invalid}]}} =
               refused(ctx, [%{"row" => 1, "item_uuid" => "nope", "quantity" => "1"}])
    end

    test "two rows of one item (the table merges them first)", ctx do
      assert {:error, {:invalid_rows, [%{row: 2, field: "item_uuid", error: :repeated}]}} =
               refused(ctx, [row(1, ctx.hinge, "1"), row(2, ctx.hinge, "2")])
    end

    test "an action the line does not allow", ctx do
      assert {:error, {:invalid_rows, [%{row: 1, field: "action", error: :not_allowed}]}} =
               refused(ctx, [row(1, ctx.hinge, "1", %{"action" => "replace_part"})])
    end

    test "no rows", ctx do
      assert refused(ctx, []) == {:error, :nothing_to_apply}
    end

    test "the tab's base is old: another tab saved", ctx do
      {:ok, _} =
        Inventories.update_draft(ctx.doc, %{
          note: "other tab",
          lines: [%{"item_uuid" => ctx.hinge.uuid, "counted_quantity" => "1"}]
        })

      assert InventoryAI.apply_run(
               ctx.run,
               ctx.loaded.fingerprint,
               ctx.loaded.lines,
               [row(1, ctx.hinge, "480")],
               ctx.user,
               inventory_uuid: ctx.doc.uuid
             ) ==
               {:error, :stale}

      assert InventoryAI.get_run(ctx.doc.uuid, ctx.run.uuid).status == "proposed"
      assert [%{"counted_quantity" => "1"}] = lines(ctx.doc)
    end

    test "no base at all", ctx do
      assert refused(ctx, [row(1, ctx.hinge, "480")], "") == {:error, :stale}
    end

    test "applied twice: the second is refused", ctx do
      {:ok, %{document: written}} =
        InventoryAI.apply_run(
          ctx.run,
          ctx.loaded.fingerprint,
          ctx.loaded.lines,
          [row(1, ctx.hinge, "480")],
          ctx.user,
          inventory_uuid: ctx.doc.uuid
        )

      assert InventoryAI.apply_run(
               ctx.run,
               written.fingerprint,
               written.lines,
               [row(1, ctx.hinge, "480")],
               ctx.user,
               inventory_uuid: ctx.doc.uuid
             ) ==
               {:error, :not_proposed}
    end

    test "a discarded run", ctx do
      {:ok, _} = InventoryAI.discard_run(ctx.run, ctx.user, inventory_uuid: ctx.doc.uuid)

      assert InventoryAI.apply_run(
               ctx.run,
               ctx.loaded.fingerprint,
               ctx.loaded.lines,
               [row(1, ctx.hinge, "480")],
               ctx.user,
               inventory_uuid: ctx.doc.uuid
             ) ==
               {:error, :not_proposed}
    end

    test "a document in the trash, or posted", ctx do
      {:ok, _} = Inventories.soft_delete_document(ctx.doc, nil)

      assert InventoryAI.apply_run(
               ctx.run,
               ctx.loaded.fingerprint,
               ctx.loaded.lines,
               [row(1, ctx.hinge, "480")],
               ctx.user,
               inventory_uuid: ctx.doc.uuid
             ) ==
               {:error, :deleted}

      other = draft!(ctx.location)
      run = run!(other, ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 1})])
      {:ok, loaded} = Inventories.get_document_with_fingerprint(other.uuid)
      {:ok, _} = Inventories.post_document(other, ctx.user.uuid)

      assert InventoryAI.apply_run(
               run,
               loaded.fingerprint,
               loaded.lines,
               [row(1, ctx.hinge, "1")],
               ctx.user,
               inventory_uuid: other.uuid
             ) ==
               {:error, :not_draft}
    end

    test "the document moved to another warehouse after the run", ctx do
      {:ok, moved} =
        Inventories.update_draft(ctx.doc, %{location_uuid: Ecto.UUID.generate()},
          base_fingerprint: ctx.loaded.fingerprint
        )

      assert InventoryAI.apply_run(
               ctx.run,
               moved.fingerprint,
               moved.lines,
               [row(1, ctx.hinge, "480")],
               ctx.user,
               inventory_uuid: ctx.doc.uuid
             ) ==
               {:error, :location_changed}
    end

    test "a run of another document: its fingerprint can be the same, the document is not", ctx do
      twin = draft!(ctx.location)
      {:ok, twin_loaded} = Inventories.get_document_with_fingerprint(twin.uuid)
      assert twin_loaded.fingerprint == ctx.loaded.fingerprint

      assert InventoryAI.apply_run(
               ctx.run,
               twin_loaded.fingerprint,
               twin_loaded.lines,
               [row(1, ctx.hinge, "480")],
               ctx.user,
               inventory_uuid: twin.uuid
             ) == {:error, :wrong_document}

      assert InventoryAI.get_run(ctx.doc.uuid, ctx.run.uuid).status == "proposed"
      assert lines(ctx.doc) == ctx.loaded.lines
      assert lines(twin) == twin_loaded.lines
    end

    test "without the caller's document nothing is applied", ctx do
      assert InventoryAI.apply_run(
               ctx.run,
               ctx.loaded.fingerprint,
               ctx.loaded.lines,
               [row(1, ctx.hinge, "480")],
               ctx.user,
               []
             ) == {:error, :wrong_document}

      assert InventoryAI.get_run(ctx.doc.uuid, ctx.run.uuid).status == "proposed"
      assert lines(ctx.doc) == ctx.loaded.lines
    end

    test "a run is not found through another document", ctx do
      twin = draft!(ctx.location)
      assert InventoryAI.get_run(twin.uuid, ctx.run.uuid) == nil
      assert InventoryAI.get_run(ctx.doc.uuid, "nope") == nil
    end

    test "two lines of one item in the tab", ctx do
      doubled = ctx.loaded.lines ++ ctx.loaded.lines

      assert {:error, {:invalid_rows, [%{row: 1, field: "line", error: :repeated}]}} =
               refused(ctx, [row(1, ctx.hinge, "480")], nil, doubled)
    end
  end
end
