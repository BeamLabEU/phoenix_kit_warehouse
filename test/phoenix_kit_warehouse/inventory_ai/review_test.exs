defmodule PhoenixKitWarehouse.InventoryAI.ReviewTest do
  # The proposal as a person reviews it (spec §5.4, §11.2, §11.3): the item
  # of a row, rows of one item merged at once and split back, the quantity
  # and the units per package typed, the switch of the rule, the default
  # tick and the rows Apply gets.
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.InventoryAI.Proposal
  alias PhoenixKitWarehouse.InventoryAI.Review

  defp info(no, unit \\ "piece") do
    %{
      "no" => no,
      "item_uuid" => "item-#{no}",
      "name" => "Item #{no}",
      "sku" => "S#{no}",
      "unit" => unit,
      "catalogue_uuid" => "cat",
      "category_uuid" => nil,
      "path" => "Cat",
      "starred" => false
    }
  end

  defp items, do: %{1 => info(1), 2 => info(2), 3 => info(3, "m2"), 4 => info(4)}

  defp object(key, attrs) do
    Map.merge(
      %{
        "object_key" => key,
        "photos" => [1],
        "description" => "Object #{key}",
        "catalogue_no" => nil,
        "alternatives" => [],
        "match_confidence" => "high",
        "package" => "box",
        "closed_packages" => Decimal.new(0),
        "open_packages" => Decimal.new(0),
        "open_fill" => Decimal.new("0.35"),
        "units_per_package" => nil,
        "loose_units" => nil,
        "quantity" => nil,
        "count_confidence" => "high",
        "basis" => "basis #{key}"
      },
      attrs
    )
  end

  # A run as the database gives it back: the rows through JSON, numbers as text.
  defp run(objects, place \\ "Shelf A") do
    rows = objects |> Proposal.build(items()) |> Jason.encode!() |> Jason.decode!()
    %{uuid: "run-1", place_label: place, result: %{"rows" => rows}}
  end

  defp stock(map), do: Map.new(map, fn {uuid, qty} -> {uuid, %{quantity: Decimal.new(qty)}} end)

  defp view_row(review, key, lines \\ [], stock \\ %{}) do
    review |> Review.view(lines, stock) |> Enum.find(&(&1.key == key))
  end

  describe "the rows" do
    test "one row per proposal row, the item and the count of the run" do
      review =
        Review.new(
          run([
            object("A", %{"catalogue_no" => 1, "loose_units" => 10}),
            object("B", %{"catalogue_no" => 2, "loose_units" => 4, "photos" => [2, 3]})
          ])
        )

      [a, b] = Review.view(review, [], %{})
      assert {a.key, a.item["item_uuid"], a.quantity} == {1, "item-1", "10"}
      assert {b.key, b.item["item_uuid"], b.quantity, b.photos} == {2, "item-2", "4", [2, 3]}
      assert a.kind == :counted
      assert a.action == "new"
    end

    test "a row without an item waits for one and cannot be ticked" do
      review = Review.new(run([object("A", %{"loose_units" => 10})]))
      row = view_row(review, 1)

      assert row.item == nil
      assert row.kind == :item
      refute row.checked
      assert :no_item in row.reasons

      assert {:ok, review} = Review.set_checked(review, 1, true)
      refute view_row(review, 1).checked
    end

    test "a measured unit is filled in but never ticked; a missing quantity is to be typed" do
      review =
        Review.new(
          run([
            object("A", %{"catalogue_no" => 3, "quantity" => Decimal.new("12.5")}),
            object("B", %{"catalogue_no" => 4, "closed_packages" => Decimal.new(2)})
          ])
        )

      measured = view_row(review, 1)
      assert {measured.kind, measured.quantity, measured.checked} == {:measured, "12.5", false}
      assert :measured in measured.reasons

      package = view_row(review, 2)
      assert {package.kind, package.quantity, package.checked} == {:package_size, "", false}
    end

    test "the units per package typed count the row; the quantity typed wins over the count" do
      review = Review.new(run([object("A", %{"catalogue_no" => 4, "closed_packages" => 2})]))

      {:ok, review} =
        Review.set_inputs(review, 1, %{"package_size" => "50"}, [], stock(%{"item-4" => "0"}))

      row = view_row(review, 1, [], stock(%{"item-4" => "0"}))
      assert {row.kind, row.quantity} == {:counted, "100"}
      assert row.formulas == ["2×50 + ⌊0×50×0.35⌋ = 100"]

      {:ok, review} =
        Review.set_inputs(review, 1, %{"quantity" => "97"}, [], stock(%{"item-4" => "0"}))

      row = view_row(review, 1, [], stock(%{"item-4" => "0"}))
      assert {row.kind, row.quantity} == {:typed, "97"}
      assert :typed in row.reasons
    end

    test "an unknown row is refused" do
      review = Review.new(run([object("A", %{"catalogue_no" => 1, "loose_units" => 1})]))

      assert Review.set_inputs(review, 9, %{"quantity" => "1"}, [], %{}) == {:error, :unknown_row}
      assert Review.choose(review, 9, info(2)) == {:error, :unknown_row}
      assert Review.set_checked(review, 9, true) == {:error, :unknown_row}
      assert Review.unmerge(review, 9) == {:error, :unknown_row}
    end
  end

  describe "the default tick (§11.3)" do
    test "a starred item counted with confidence is ticked; a new one without a star is not" do
      review = Review.new(run([object("A", %{"catalogue_no" => 1, "loose_units" => 10})]))

      assert view_row(review, 1, [], stock(%{"item-1" => "12"})).checked

      row = view_row(review, 1, [], %{})
      refute row.checked
      assert :new_without_star in row.reasons
    end

    test "a low confidence, a sharply low total, a manual line are not ticked" do
      low =
        Review.new(
          run([
            object("A", %{"catalogue_no" => 1, "loose_units" => 10, "count_confidence" => "low"})
          ])
        )

      assert :low_count in view_row(low, 1, [], stock(%{"item-1" => "10"})).reasons

      review = Review.new(run([object("A", %{"catalogue_no" => 1, "loose_units" => 10})]))
      sharp = view_row(review, 1, [], stock(%{"item-1" => "100"}))
      assert :sharply_below_stock in sharp.reasons
      refute sharp.checked

      manual = [%{"item_uuid" => "item-1", "counted_quantity" => "120", "counted_by" => "manual"}]
      row = view_row(review, 1, manual, stock(%{"item-1" => "100"}))
      assert row.action == "add"
      assert row.actions == ["add", "replace_all"]
      assert Decimal.eq?(row.total, 130)
      assert :manual_line in row.reasons
      refute row.checked
    end

    test "the person's tick stands over the default" do
      review = Review.new(run([object("A", %{"catalogue_no" => 1, "loose_units" => 10})]))
      {:ok, review} = Review.set_checked(review, 1, true)
      assert view_row(review, 1).checked

      {:ok, review} = Review.set_checked(review, 1, false)
      refute view_row(review, 1, [], stock(%{"item-1" => "10"})).checked
    end

    test "a quantity typed into a row keeps the tick the row showed: a correction accepts it" do
      review =
        Review.new(
          run([
            object("A", %{"catalogue_no" => 1, "loose_units" => 10}),
            object("B", %{"catalogue_no" => 2, "loose_units" => 5})
          ])
        )

      stock = stock(%{"item-1" => "12"})
      assert view_row(review, 1, [], stock).checked
      refute view_row(review, 2, [], stock).checked

      {:ok, review} = Review.set_inputs(review, 1, %{"quantity" => "11"}, [], stock)
      {:ok, review} = Review.set_inputs(review, 2, %{"quantity" => "6"}, [], stock)

      row = view_row(review, 1, [], stock)
      assert {row.kind, row.quantity, row.checked} == {:typed, "11", true}
      refute view_row(review, 2, [], stock).checked

      # A tick the person set stands through a later edit.
      {:ok, review} = Review.set_checked(review, 2, true)
      {:ok, review} = Review.set_inputs(review, 2, %{"quantity" => "7"}, [], stock)
      assert view_row(review, 2, [], stock).checked

      # The quantity the row shows, sent again, is no edit: the tick stays the default.
      fresh = Review.new(run([object("A", %{"catalogue_no" => 1, "loose_units" => 10})]))
      {:ok, fresh} = Review.set_inputs(fresh, 1, %{"quantity" => "10"}, [], stock)
      assert hd(fresh.rows).checked == nil
    end
  end

  describe "the line in the sheet" do
    test "a seeded line is replaced by default, its switch adds; the total follows" do
      review = Review.new(run([object("A", %{"catalogue_no" => 1, "loose_units" => 30})]))

      seeded = [
        %{
          "item_uuid" => "item-1",
          "counted_quantity" => "500",
          "counted_by" => "stock",
          "seeded_quantity" => "500"
        }
      ]

      row = view_row(review, 1, seeded, stock(%{"item-1" => "600"}))
      assert {row.action, row.actions} == {"replace", ["replace", "add"]}
      assert Decimal.eq?(row.total, 30)
      assert row.line.kind == :seeded
      assert Decimal.eq?(row.line.seeded, 500)
      assert Decimal.eq?(row.line.stock, 600)

      {:ok, review} =
        Review.set_inputs(review, 1, %{"action" => "add"}, seeded, stock(%{"item-1" => "600"}))

      assert Decimal.eq?(view_row(review, 1, seeded, stock(%{"item-1" => "600"})).total, 530)

      # An action the line does not offer is the default.
      {:ok, review} =
        Review.set_inputs(
          review,
          1,
          %{"action" => "replace_part"},
          seeded,
          stock(%{"item-1" => "600"})
        )

      assert view_row(review, 1, seeded, stock(%{"item-1" => "600"})).action == "replace"
    end

    test "a line of the AI shows its base by source and its parts" do
      review = Review.new(run([object("A", %{"catalogue_no" => 1, "loose_units" => 30})], "B"))

      line = %{
        "item_uuid" => "item-1",
        "counted_quantity" => "150",
        "counted_by" => "ai",
        "base_qty" => "120",
        "base_source" => "manual",
        "ai_parts" => [%{"run_uuid" => "r0", "place" => "A", "qty" => "30"}]
      }

      row = view_row(review, 1, [line], stock(%{"item-1" => "100"}))
      assert row.action == "add_part"
      assert Decimal.eq?(row.total, 180)
      assert row.line.kind == :ai
      assert {row.line.base_source, Decimal.to_string(row.line.base)} == {"manual", "120"}
      assert [{"A", qty}] = row.line.parts
      assert Decimal.eq?(qty, 30)
    end

    test "a manual line shows what the photos counted before" do
      review = Review.new(run([object("A", %{"catalogue_no" => 1, "loose_units" => 5})]))

      line = %{
        "item_uuid" => "item-1",
        "counted_quantity" => "120",
        "counted_by" => "manual",
        "ai_parts_history" => [%{"run_uuid" => "r0", "place" => "A", "qty" => "30"}]
      }

      row = view_row(review, 1, [line])
      assert row.line.kind == :manual
      assert [{"A", _qty}] = row.line.history
    end

    test "two lines of one item in the sheet are said, and the row is not ticked" do
      review = Review.new(run([object("A", %{"catalogue_no" => 1, "loose_units" => 5})]))
      line = %{"item_uuid" => "item-1", "counted_quantity" => "1", "counted_by" => "manual"}

      row = view_row(review, 1, [line, line], stock(%{"item-1" => "1"}))
      assert row.line.kind == :repeated
      assert :repeated_line in row.reasons
      refute row.checked
    end
  end

  describe "choosing the item, merging" do
    test "an item another row holds merges the rows at once: one row, the sum" do
      review =
        Review.new(
          run([
            object("A", %{"catalogue_no" => 1, "loose_units" => 10}),
            object("B", %{"loose_units" => 4, "match_confidence" => "medium"})
          ])
        )

      {:ok, review} = Review.choose(review, 2, info(1))

      assert [row] = Review.view(review, [], stock(%{"item-1" => "14"}))
      assert {row.key, row.rows, row.quantity, row.merged?} == {1, [1, 2], "14", true}
      assert row.match_confidence == "medium"
      assert row.checked

      # "Undo" restores the rows of the run.
      {:ok, review} = Review.unmerge(review, 1)
      assert [a, b] = Review.view(review, [], %{})
      assert {a.key, a.item["item_uuid"], a.quantity} == {1, "item-1", "10"}
      assert {b.key, b.item, b.merged?} == {2, nil, false}
    end

    test "typed quantities are summed when merging" do
      review =
        Review.new(
          run([
            object("A", %{"catalogue_no" => 1, "loose_units" => 10}),
            object("B", %{"catalogue_no" => 2, "loose_units" => 4})
          ])
        )

      {:ok, review} = Review.set_inputs(review, 1, %{"quantity" => "11"}, [], %{})
      {:ok, review} = Review.choose(review, 2, info(1))

      assert [row] = Review.view(review, [], %{})
      assert {row.kind, row.quantity} == {:typed, "15"}
    end

    test "choosing another item resets the typed values and the switch" do
      review = Review.new(run([object("A", %{"catalogue_no" => 1, "loose_units" => 10})]))

      {:ok, review} =
        Review.set_inputs(review, 1, %{"quantity" => "3", "action" => "new"}, [], %{})

      {:ok, review} = Review.choose(review, 1, info(2))

      row = view_row(review, 1)
      assert {row.item["item_uuid"], row.quantity, row.kind} == {"item-2", "10", :counted}
    end

    test "the alternatives of a row are offered, without its item" do
      review =
        Review.new(
          run([object("A", %{"catalogue_no" => 1, "alternatives" => [2, 4], "loose_units" => 1})])
        )

      row = view_row(review, 1)
      assert Enum.map(row.alternatives, & &1["no"]) == [2, 4]
      assert Review.offered_item(review, 1, 4)["item_uuid"] == "item-4"
      assert Review.offered_item(review, 1, 3) == nil
    end
  end

  describe "the rows Apply gets" do
    test "only the ticked ones, with their rows, item, quantity, switch and units per package" do
      review =
        Review.new(
          run([
            object("A", %{"catalogue_no" => 1, "loose_units" => 10}),
            object("B", %{"loose_units" => 4}),
            object("C", %{"catalogue_no" => 4, "closed_packages" => 2})
          ])
        )

      {:ok, review} = Review.choose(review, 2, info(1))
      {:ok, review} = Review.set_inputs(review, 3, %{"package_size" => "50"}, [], %{})
      {:ok, review} = Review.set_checked(review, 3, true)

      lines = [%{"item_uuid" => "item-1", "counted_quantity" => "9", "counted_by" => "stock"}]
      stock = stock(%{"item-1" => "9", "item-4" => "0"})

      assert Review.apply_rows(review, lines, stock) == [
               %{
                 "row" => 1,
                 "merged_rows" => [2],
                 "item_uuid" => "item-1",
                 "quantity" => "14",
                 "action" => "replace",
                 "package_size" => ""
               },
               %{
                 "row" => 3,
                 "merged_rows" => [],
                 "item_uuid" => "item-4",
                 "quantity" => "100",
                 "action" => "new",
                 "package_size" => "50"
               }
             ]
    end

    test "the field errors of Apply land on their rows, a merged row's included" do
      review =
        Review.new(
          run([
            object("A", %{"catalogue_no" => 1, "loose_units" => 10}),
            object("B", %{"loose_units" => 4})
          ])
        )

      {:ok, review} = Review.choose(review, 2, info(1))

      review =
        Review.put_errors(review, [
          %{row: 2, field: "quantity", error: :invalid},
          %{row: nil, field: "row", error: :unknown}
        ])

      assert view_row(review, 1).errors == %{"quantity" => :invalid}
      assert Review.put_errors(review, []) |> view_row(1) |> Map.get(:errors) == %{}
    end
  end
end
