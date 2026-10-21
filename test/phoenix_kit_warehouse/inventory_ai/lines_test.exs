defmodule PhoenixKitWarehouse.InventoryAI.LinesTest do
  # The line of the document and what a run does to it (spec §10.4, §11.2,
  # §11.3). Every rule is checked against the invariant
  # counted_quantity = base_qty + Σ ai_parts.
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.InventoryAI.Lines

  @item "0192d1f0-0000-7000-8000-000000000001"

  defp d(value), do: Decimal.new(value)
  defp eq?(value, expected), do: Decimal.equal?(Lines.decimal(value), d(expected))

  defp part(place, qty, run \\ nil) do
    %{
      "run_uuid" => run || Ecto.UUID.generate(),
      "place" => place,
      "qty" => d(qty),
      "basis" => "#{place}: #{qty}"
    }
  end

  defp seeded(qty),
    do: %{
      "item_uuid" => @item,
      "counted_quantity" => d(qty),
      "counted_by" => "stock",
      "seeded_quantity" => d(qty)
    }

  defp manual(qty),
    do: %{"item_uuid" => @item, "counted_quantity" => d(qty), "counted_by" => "manual"}

  defp unlabelled(qty), do: %{"item_uuid" => @item, "counted_quantity" => qty}

  defp new_line do
    %{"item_uuid" => @item, "name" => "Hinge", "unit" => "piece", "counted_quantity" => d(0)}
  end

  defp apply!(line, action, part), do: Lines.apply(line, action, part, new_line())

  defp parts_qty(line), do: Enum.map(line["ai_parts"], &Lines.decimal(&1["qty"]))

  defp assert_invariant(line) do
    assert Lines.invariant?(line), "invariant broken: #{inspect(line)}"
    line
  end

  describe "same_place?/2" do
    test "both labels non-empty and equal after trimming and case" do
      assert Lines.same_place?("Shelf 2, top", "  shelf 2, TOP ")
      refute Lines.same_place?("Shelf 2", "Shelf 3")
    end

    test "an empty label is never the same place" do
      refute Lines.same_place?("", "")
      refute Lines.same_place?(nil, nil)
      refute Lines.same_place?("  ", "Shelf 2")
      refute Lines.same_place?(nil, "Shelf 2")
    end
  end

  describe "kind/2" do
    test "a line with ai_parts that hold the invariant is the AI's" do
      line = apply!(manual(120), "add", part("A", 30))
      assert Lines.kind(line, d(500)) == :ai
    end

    test "counted_by stock is seeded, whatever the stock is now" do
      assert Lines.kind(seeded(500), d(600)) == :seeded
      assert Lines.kind(seeded(500), nil) == :seeded
    end

    test "counted_by manual is manual, even at the stock's number" do
      assert Lines.kind(manual(8), d(8)) == :manual
    end

    test "an unlabelled line is seeded only when it equals the stock (Decimal.eq?)" do
      assert Lines.kind(unlabelled("8"), Decimal.new("8.000000")) == :seeded
      assert Lines.kind(unlabelled(d(8)), Decimal.new("8.000000")) == :seeded
      assert Lines.kind(unlabelled("7"), d(8)) == :manual
      assert Lines.kind(unlabelled("8"), nil) == :manual
    end

    test "ai_parts that no longer add up (edited by hand some other way) is manual" do
      line = apply!(nil, "new", part("A", 30))
      assert Lines.kind(%{line | "counted_quantity" => d(31)}, nil) == :manual
    end
  end

  describe "choices/3 — the default and the switch (§11.2)" do
    test "no line: a new one" do
      assert Lines.choices(nil, nil, "A") == %{kind: :none, default: "new", actions: ["new"]}
    end

    test "seeded: replace, or add" do
      assert %{kind: :seeded, default: "replace", actions: ["replace", "add"]} =
               Lines.choices(seeded(500), d(500), "A")
    end

    test "the AI's line with this place: replace that part" do
      line = apply!(nil, "new", part("A", 30))

      assert %{default: "replace_part", actions: ["replace_part", "add_part", "replace_all"]} =
               Lines.choices(line, nil, " a ")
    end

    test "the AI's line without this place: add a part" do
      line = apply!(nil, "new", part("A", 30))

      assert %{default: "add_part", actions: ["add_part", "replace_all"]} =
               Lines.choices(line, nil, "B")
    end

    test "two empty labels add up" do
      line = apply!(nil, "new", part("", 30))
      assert %{default: "add_part"} = Lines.choices(line, nil, "")
      assert %{default: "add_part"} = Lines.choices(line, nil, nil)
    end

    test "manual: add, or replace all" do
      assert %{kind: :manual, default: "add", actions: ["add", "replace_all"]} =
               Lines.choices(manual(120), d(500), "A")

      assert %{kind: :manual, default: "add"} = Lines.choices(unlabelled("7"), d(8), "A")
    end
  end

  describe "apply/4 — every rule keeps the invariant" do
    test "new: base 0, one part" do
      line = assert_invariant(apply!(nil, "new", part("A", 30)))
      assert eq?(line["counted_quantity"], "30")
      assert eq?(line["base_qty"], "0")
      assert line["counted_by"] == "ai"
      assert line["name"] == "Hinge"
      assert parts_qty(line) == [d(30)]
    end

    test "seeded, replace: base 0, one part" do
      line = assert_invariant(apply!(seeded(500), "replace", part("A", 480)))
      assert eq?(line["counted_quantity"], "480")
      assert eq?(line["base_qty"], "0")
      refute Map.has_key?(line, "base_source")
      assert line["counted_by"] == "ai"
    end

    test "seeded, add: the seeded number is the base, from stock" do
      line = assert_invariant(apply!(seeded(500), "add", part("A", 20)))
      assert eq?(line["counted_quantity"], "520")
      assert eq?(line["base_qty"], "500")
      assert line["base_source"] == "stock"
    end

    test "manual 120, place A gives 30: 150 (base 120 manual, A 30); A again gives 35: 155" do
      first = assert_invariant(apply!(manual(120), "add", part("A", 30)))
      assert eq?(first["counted_quantity"], "150")
      assert eq?(first["base_qty"], "120")
      assert first["base_source"] == "manual"

      assert %{default: "replace_part"} = Lines.choices(first, nil, "A")
      second = assert_invariant(apply!(first, "replace_part", part("A", 35)))
      assert eq?(second["counted_quantity"], "155")
      assert eq?(second["base_qty"], "120")
      assert parts_qty(second) == [d(35)]
    end

    test "a second place adds a part: A 100, B 50 is 150, then C 30 is 180" do
      line = apply!(nil, "new", part("A", 100))
      line = assert_invariant(apply!(line, "add_part", part("B", 50)))
      assert eq?(line["counted_quantity"], "150")

      line = assert_invariant(apply!(line, "add_part", part("C", 30)))
      assert eq?(line["counted_quantity"], "180")
      assert parts_qty(line) == [d(100), d(50), d(30)]
    end

    test "retaking A with parts A and B changes only A" do
      line = apply!(nil, "new", part("A", 100))
      line = apply!(line, "add_part", part("B", 50))
      line = assert_invariant(apply!(line, "replace_part", part("a", 70)))

      assert eq?(line["counted_quantity"], "120")
      assert Enum.map(line["ai_parts"], & &1["place"]) == ["a", "B"]
      assert parts_qty(line) == [d(70), d(50)]
    end

    test "two runs with empty labels add up" do
      line = apply!(nil, "new", part("", 30))
      assert %{default: default} = Lines.choices(line, nil, "")
      line = assert_invariant(apply!(line, default, part("", 20)))
      assert eq?(line["counted_quantity"], "50")
    end

    test "replace all: base 0, only this part" do
      line = apply!(manual(120), "add", part("A", 30))
      line = assert_invariant(apply!(line, "replace_all", part("B", 12)))
      assert eq?(line["counted_quantity"], "12")
      assert eq?(line["base_qty"], "0")
      assert parts_qty(line) == [d(12)]
      refute Map.has_key?(line, "base_source")
    end

    test "manual, replace all" do
      line = assert_invariant(apply!(manual(120), "replace_all", part("A", 30)))
      assert eq?(line["counted_quantity"], "30")
    end

    test "the other keys of the line stay; the stale display sum goes" do
      line =
        manual(120)
        |> Map.merge(%{"unit_value" => "2.5", "name" => "Old", "_sum" => d(300)})
        |> apply!("add", part("A", 30))

      assert line["unit_value"] == "2.5"
      assert line["name"] == "Old"
      refute Map.has_key?(line, "_sum")
    end

    test "ai_basis joins the parts' bases with \"; \"" do
      line = apply!(nil, "new", part("A", 100))
      line = apply!(line, "add_part", part("B", 50))
      assert line["ai_basis"] == "A: 100; B: 50"
    end

    test "a stored line (numbers as text) keeps the invariant too" do
      stored = %{
        "item_uuid" => @item,
        "counted_quantity" => "150",
        "counted_by" => "ai",
        "base_qty" => "120",
        "base_source" => "manual",
        "ai_parts" => [%{"run_uuid" => "r", "place" => "A", "qty" => "30"}]
      }

      assert Lines.kind(stored, nil) == :ai
      line = assert_invariant(apply!(stored, "replace_part", part("A", 35)))
      assert eq?(line["counted_quantity"], "155")
    end

    test "an action outside the line's choices is refused" do
      assert_raise ArgumentError, fn -> apply!(seeded(5), "replace_part", part("A", 1)) end
      assert_raise ArgumentError, fn -> apply!(nil, "add", part("A", 1)) end
      assert_raise ArgumentError, fn -> apply!(manual(5), "replace", part("A", 1)) end
    end
  end

  describe "manual_edit/2 (§10.4)" do
    test "after the AI: manual, the number is the base, the parts go to the history" do
      line = apply!(manual(120), "add", part("A", 30))
      edited = Lines.manual_edit(line, d(140))

      assert edited["counted_by"] == "manual"
      assert eq?(edited["counted_quantity"], "140")
      assert eq?(edited["base_qty"], "140")
      assert edited["base_source"] == "manual"
      refute Map.has_key?(edited, "ai_parts")
      refute Map.has_key?(edited, "ai_basis")
      assert [%{"place" => "A"}] = edited["ai_parts_history"]
      assert Lines.kind(edited, nil) == :manual
    end

    test "an edit to the seeded number is still a count" do
      assert Lines.manual_edit(seeded(8), d(8))["counted_by"] == "manual"
      assert Lines.kind(Lines.manual_edit(seeded(8), d(8)), d(8)) == :manual
    end

    test "the history grows over several edits" do
      line = apply!(nil, "new", part("A", 30)) |> Lines.manual_edit(d(31))
      line = apply!(line, "add", part("B", 5)) |> Lines.manual_edit(d(40))
      assert Enum.map(line["ai_parts_history"], & &1["place"]) == ["A", "B"]
    end
  end

  describe "below the stock (§11.3)" do
    test "below: the total is under the stock" do
      assert Lines.below_stock?(d(9), d(10))
      refute Lines.below_stock?(d(10), d(10))
      refute Lines.below_stock?(d(0), nil)
    end

    test "sharply below: 0 against a stock above 0, or under half of it" do
      assert Lines.sharply_below_stock?(d(0), d(1))
      assert Lines.sharply_below_stock?(d(4), d(10))
      refute Lines.sharply_below_stock?(d(5), d(10))
      refute Lines.sharply_below_stock?(d(0), d(0))
      refute Lines.sharply_below_stock?(d(0), nil)
    end
  end

  describe "default_check/1 (§11.3)" do
    defp good(attrs \\ %{}) do
      Map.merge(
        %{
          item?: true,
          match_confidence: "high",
          count_confidence: "medium",
          count_kind: :counted,
          total: d(100),
          stock: d(100),
          starred?: true,
          line_kind: :seeded
        },
        attrs
      )
    end

    test "checked only when every condition holds" do
      assert Lines.default_check(good()) == {true, []}
      assert Lines.default_check(good(%{starred?: false})) == {true, []}

      assert Lines.default_check(good(%{starred?: false, line_kind: :none, stock: nil})) ==
               {false, [:new_without_star]}
    end

    test "each reason on its own" do
      for {attrs, reason} <- [
            {%{item?: false}, :no_item},
            {%{match_confidence: "low"}, :low_match},
            {%{count_confidence: "low"}, :low_count},
            {%{count_kind: :measured}, :measured},
            {%{count_kind: :package_size, total: nil}, :needs_input},
            {%{count_kind: :quantity, total: nil}, :needs_input},
            {%{total: d(40)}, :sharply_below_stock},
            {%{total: d(0)}, :sharply_below_stock},
            {%{line_kind: :manual}, :manual_line}
          ] do
        {checked, reasons} = Lines.default_check(good(attrs))
        refute checked
        assert reason in reasons, "#{inspect(attrs)} gave #{inspect(reasons)}"
      end
    end

    test "a new line with a star is checked" do
      assert Lines.default_check(good(%{line_kind: :none, stock: nil})) == {true, []}
    end
  end
end
