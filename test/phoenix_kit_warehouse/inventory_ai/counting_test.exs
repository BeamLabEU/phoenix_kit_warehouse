defmodule PhoenixKitWarehouse.InventoryAI.CountingTest do
  # Packages into the item's unit (spec §9), one table row per test group.
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.InventoryAI.Counting

  defp object(attrs) do
    Map.merge(
      %{
        "object_key" => "A",
        "photos" => [1],
        "closed_packages" => Decimal.new(0),
        "open_packages" => Decimal.new(0),
        "open_fill" => Decimal.new("0.35"),
        "units_per_package" => nil,
        "loose_units" => nil,
        "quantity" => nil
      },
      Map.new(attrs, fn
        {k, v} when is_integer(v) -> {k, Decimal.new(v)}
        {k, v} when is_binary(v) and k != "object_key" -> {k, Decimal.new(v)}
        pair -> pair
      end)
    )
  end

  defp eq?(%Decimal{} = a, b), do: Decimal.equal?(a, Decimal.new(b))

  describe "a piece unit with only loose units" do
    test "the loose units are the count" do
      for unit <- ~w(piece pair set sheet) do
        assert {:counted, qty, _formula} = Counting.count(object(%{"loose_units" => 14}), unit)
        assert eq?(qty, "14")
      end
    end

    test "nothing counted at all needs the quantity typed" do
      assert Counting.count(object(%{}), "piece") == {:needs, :quantity}
    end
  end

  describe "a piece unit with packages and the units per package" do
    test "2 closed boxes of 100 and 1 open at 0.35 is 200 + floor(35) = 235" do
      obj = object(%{"closed_packages" => 2, "open_packages" => 1, "units_per_package" => 100})
      assert {:counted, qty, formula} = Counting.count(obj, "piece")
      assert eq?(qty, "235")
      assert formula =~ "235"
    end

    test "floor is only for the share of the open packages, not the whole" do
      obj =
        object(%{
          "closed_packages" => 1,
          "open_packages" => 1,
          "units_per_package" => 10,
          "open_fill" => "0.37",
          "loose_units" => 2
        })

      # 10 + floor(3.7) + 2 = 15
      assert {:counted, qty, _} = Counting.count(obj, "piece")
      assert eq?(qty, "15")
    end

    test "a term that counts nothing is left out of the formula" do
      closed_only = object(%{"closed_packages" => 4, "units_per_package" => 18})
      assert {:counted, _, "4×18 = 72"} = Counting.count(closed_only, "piece")

      open_only = object(%{"open_packages" => 1, "units_per_package" => 100})
      assert {:counted, _, "⌊1×100×0.35⌋ = 35"} = Counting.count(open_only, "piece")

      all = object(%{"closed_packages" => 2, "open_packages" => 1, "units_per_package" => 100})
      assert {:counted, _, "2×100 + ⌊1×100×0.35⌋ = 235"} = Counting.count(all, "piece")
    end

    test "loose units are added to the packages" do
      obj = object(%{"closed_packages" => 3, "units_per_package" => 12, "loose_units" => 5})
      assert {:counted, qty, _} = Counting.count(obj, "set")
      assert eq?(qty, "41")
    end

    test "the units per package a person typed count where the label had none" do
      obj = object(%{"closed_packages" => 2, "open_packages" => 1})
      assert {:counted, qty, _} = Counting.count(obj, "piece", Decimal.new(50))
      # 100 + floor(17.5) = 117
      assert eq?(qty, "117")
    end

    test "the label wins over what a person typed" do
      obj = object(%{"closed_packages" => 2, "units_per_package" => 100})
      assert {:counted, qty, _} = Counting.count(obj, "piece", Decimal.new(10))
      assert eq?(qty, "200")
    end

    test "a set labelled 10 sets a box is n = 10, not one set a box" do
      obj = object(%{"closed_packages" => 3, "units_per_package" => 10})
      assert {:counted, qty, _} = Counting.count(obj, "set")
      assert eq?(qty, "30")
    end
  end

  describe "a piece unit (not pack) with packages and no units per package" do
    test "needs the units per package, or the quantity" do
      for unit <- ~w(piece pair set sheet) do
        obj = object(%{"closed_packages" => 2, "open_packages" => 1})
        assert Counting.count(obj, unit) == {:needs, :package_size}
      end
    end
  end

  describe "pack: counted in packs, never in pieces" do
    test "closed + open × fill, rounded down to 0.1" do
      obj = object(%{"closed_packages" => 4, "open_packages" => 1, "open_fill" => "0.37"})
      assert {:counted, qty, _} = Counting.count(obj, "pack")
      assert eq?(qty, "4.3")
    end

    test "no open packs: the formula has no open term" do
      assert {:counted, _, "4 = 4"} = Counting.count(object(%{"closed_packages" => 4}), "pack")
    end

    test "the pieces printed on the label do not turn the packs into pieces" do
      obj = object(%{"closed_packages" => 2, "units_per_package" => 100})
      assert {:counted, qty, "2 = 2"} = Counting.count(obj, "pack")
      assert eq?(qty, "2")
    end

    test "pieces seen outside a pack are not added to the packs" do
      obj = object(%{"closed_packages" => 3, "loose_units" => 23})
      assert {:counted, qty, "3 = 3"} = Counting.count(obj, "pack")
      assert eq?(qty, "3")
    end

    test "pieces alone make no number of packs: the quantity is typed" do
      assert Counting.count(object(%{"loose_units" => 23}), "pack") == {:needs, :quantity}
      assert Counting.count(object(%{}), "pack") == {:needs, :quantity}
      assert Counting.seen(object(%{"loose_units" => 23})) == "23"
    end

    test "the units per package a person typed do not count for packs" do
      obj = object(%{"closed_packages" => 2})
      assert {:counted, qty, _} = Counting.count(obj, "pack", Decimal.new(50))
      assert eq?(qty, "2")
    end
  end

  describe "a measured unit" do
    test "the model's quantity, marked measured (never checked by default)" do
      for unit <- ~w(m2 running_meter kg litre m3) do
        obj = object(%{"quantity" => "12.5", "loose_units" => 4})
        assert {:measured, qty, _} = Counting.count(obj, unit)
        assert eq?(qty, "12.5")
      end
    end

    test "no quantity needs it typed" do
      assert Counting.count(object(%{"loose_units" => 4}), "m2") == {:needs, :quantity}
    end
  end

  describe "a unit the table does not know" do
    test "needs the quantity typed" do
      obj = object(%{"closed_packages" => 1, "units_per_package" => 5, "quantity" => "2"})

      for unit <- ["roll", "hour", nil] do
        assert Counting.count(obj, unit) == {:needs, :quantity}
      end
    end
  end

  describe "the model's quantity for a piece unit" do
    test "is not used" do
      obj = object(%{"quantity" => "0.35", "loose_units" => 3})
      assert {:counted, qty, _} = Counting.count(obj, "piece")
      assert eq?(qty, "3")
    end
  end

  describe "count_all/3 — the objects of one row" do
    test "sums the counted objects" do
      a = object(%{"closed_packages" => 1, "units_per_package" => 100})
      b = object(%{"object_key" => "B", "loose_units" => 7})
      assert {:counted, qty, [_, _]} = Counting.count_all([a, b], "piece")
      assert eq?(qty, "107")
    end

    test "one object needing the units per package makes the row need it" do
      a = object(%{"loose_units" => 7})
      b = object(%{"object_key" => "B", "closed_packages" => 2})
      assert Counting.count_all([a, b], "piece") == {:needs, :package_size}

      assert {:counted, qty, _} = Counting.count_all([a, b], "piece", Decimal.new(6))
      assert eq?(qty, "19")
    end

    test "an object needing the quantity wins over one needing the units per package" do
      a = object(%{})
      b = object(%{"object_key" => "B", "closed_packages" => 2})
      assert Counting.count_all([a, b], "piece") == {:needs, :quantity}
    end

    test "measured objects sum, one without a quantity makes the row need it" do
      a = object(%{"quantity" => "2.5"})
      b = object(%{"object_key" => "B", "quantity" => "1.25"})
      assert {:measured, qty, _} = Counting.count_all([a, b], "m2")
      assert eq?(qty, "3.75")

      assert Counting.count_all([a, object(%{})], "m2") == {:needs, :quantity}
    end

    test "stored objects (numbers as text, the way jsonb gives them back) count the same" do
      stored = %{
        "object_key" => "A",
        "closed_packages" => "2",
        "open_packages" => "1",
        "open_fill" => "0.35",
        "units_per_package" => "100",
        "loose_units" => nil,
        "quantity" => nil
      }

      assert {:counted, qty, _} = Counting.count_all([stored], "piece")
      assert eq?(qty, "235")
    end
  end

  describe "seen/1 — what was seen, when the quantity cannot be counted" do
    test "packages with the units per package unknown: each one with a ?" do
      assert Counting.seen(object(%{"closed_packages" => 2})) == "2×?"

      assert Counting.seen(object(%{"closed_packages" => 2, "open_packages" => 1})) ==
               "2×? + ⌊1×?×0.35⌋"
    end

    test "the units per package and the loose units are shown as they are" do
      obj = object(%{"closed_packages" => 1, "units_per_package" => 50, "loose_units" => 7})
      assert Counting.seen(obj) == "1×50 + 7"
      assert Counting.seen(object(%{"loose_units" => 23})) == "23"
    end

    test "a measured quantity alone; nothing seen is nil" do
      assert Counting.seen(object(%{"quantity" => "12.5"})) == "12.5"
      assert Counting.seen(object(%{"closed_packages" => 2, "quantity" => "30"})) == "2×?"
      assert Counting.seen(object(%{})) == nil
    end

    test "stored objects (numbers as text) read the same" do
      stored = %{"closed_packages" => "3", "open_packages" => "0", "loose_units" => nil}
      assert Counting.seen(stored) == "3×?"
    end
  end
end
