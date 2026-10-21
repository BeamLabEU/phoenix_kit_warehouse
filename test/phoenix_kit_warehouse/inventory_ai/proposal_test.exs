defmodule PhoenixKitWarehouse.InventoryAI.ProposalTest do
  # The rows of a proposal from the checked objects (spec §6.4, §9): one row
  # per catalogue item, the objects of one item summed with their
  # breakdown, the catalogue's own facts (never the model's).
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.InventoryAI.Proposal

  defp info(no, unit, starred \\ false) do
    %{
      "no" => no,
      "item_uuid" => "item-#{no}",
      "name" => "Item #{no}",
      "sku" => "S#{no}",
      "unit" => unit,
      "catalogue_uuid" => "cat",
      "category_uuid" => nil,
      "path" => "Cat",
      "starred" => starred
    }
  end

  defp items,
    do: %{
      1 => info(1, "piece", true),
      2 => info(2, "m2"),
      3 => info(3, "piece"),
      4 => info(4, "set")
    }

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

  defp d(v), do: Decimal.new(v)

  test "one row per item; the objects of one item add up, with the breakdown" do
    objects = [
      object("A", %{
        "catalogue_no" => 1,
        "photos" => [1, 2],
        "closed_packages" => d(2),
        "open_packages" => d(1),
        "units_per_package" => d(100)
      }),
      object("B", %{"catalogue_no" => 2, "quantity" => d("12.5")}),
      object("C", %{
        "catalogue_no" => 1,
        "photos" => [3, 2],
        "loose_units" => d(7),
        "match_confidence" => "medium"
      })
    ]

    [hinge, board] = Proposal.build(objects, items())

    assert hinge["row"] == 1
    assert hinge["catalogue_no"] == 1
    assert hinge["item"]["item_uuid"] == "item-1"
    assert hinge["item"]["name"] == "Item 1"
    assert hinge["object_keys"] == ["A", "C"]
    assert hinge["photos"] == [1, 2, 3]
    assert hinge["match_confidence"] == "medium"
    assert hinge["count"]["kind"] == "counted"
    assert Decimal.equal?(hinge["count"]["quantity"], 242)
    assert length(hinge["count"]["formulas"]) == 2
    assert hinge["description"] == "Object A; Object C"
    assert hinge["ai_basis"] == "basis A; basis C"

    assert board["row"] == 2
    assert board["count"]["kind"] == "measured"
    assert Decimal.equal?(board["count"]["quantity"], d("12.5"))
  end

  test "names and units come from the catalogue, never the model's description" do
    [row] =
      Proposal.build(
        [
          object("A", %{
            "catalogue_no" => 4,
            "description" => "Item 999 m2",
            "loose_units" => d(3)
          })
        ],
        items()
      )

    assert row["item"]["unit"] == "set"
    assert row["item"]["name"] == "Item 4"
  end

  test "an object without an item is its own row, waiting for an item" do
    objects = [
      object("A", %{"alternatives" => [1, 3], "loose_units" => d(5)}),
      object("B", %{"alternatives" => [3], "loose_units" => d(2)})
    ]

    [a, b] = Proposal.build(objects, items())

    assert a["item"] == nil
    assert a["count"] == %{"kind" => "item", "quantity" => nil, "formulas" => []}
    assert Enum.map(a["alternatives"], & &1["item_uuid"]) == ["item-1", "item-3"]
    assert b["object_keys"] == ["B"]
  end

  test "a row needing the units per package says so; recount/3 takes them" do
    [row] =
      Proposal.build(
        [object("A", %{"catalogue_no" => 3, "closed_packages" => d(2), "open_packages" => d(1)})],
        items()
      )

    assert row["count"] == %{"kind" => "package_size", "quantity" => nil, "formulas" => []}

    count = Proposal.recount(row, "piece", d(50))
    assert count["kind"] == "counted"
    assert Decimal.equal?(count["quantity"], 117)
  end

  test "recount/3 for an item a person chose instead (a row without one)" do
    [row] = Proposal.build([object("A", %{"loose_units" => d(4)})], items())

    assert %{"kind" => "counted", "quantity" => qty} = Proposal.recount(row, "piece", nil)
    assert Decimal.equal?(qty, 4)
    assert %{"kind" => "quantity"} = Proposal.recount(row, "m2", nil)
  end

  test "the merged row's alternatives: from every object, never the item itself, at most 3" do
    objects = [
      object("A", %{"catalogue_no" => 1, "alternatives" => [3]}),
      object("B", %{"catalogue_no" => 1, "alternatives" => [4, 2]})
    ]

    [row] = Proposal.build(objects, items())
    assert Enum.map(row["alternatives"], & &1["no"]) == [3, 4, 2]
  end

  test "no objects, no rows" do
    assert Proposal.build([], items()) == []
  end
end
