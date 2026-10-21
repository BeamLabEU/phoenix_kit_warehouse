defmodule PhoenixKitWarehouse.InventoryAI.ResponseTest do
  # The check of the model's answer (spec §6.3, §6.4): nothing the model
  # writes reaches a proposal unchecked.
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.InventoryAI.Response

  @numbers MapSet.new(1..20)
  @context %{photo_count: 3, numbers: @numbers}

  defp object(attrs \\ %{}) do
    Map.merge(
      %{
        "object_key" => "A",
        "photos" => [1],
        "description" => "Box of hinges",
        "catalogue_no" => 5,
        "alternatives" => [],
        "match_confidence" => "high",
        "package" => "box",
        "closed_packages" => 2,
        "open_packages" => 1,
        "open_fill" => 0.3,
        "units_per_package" => 100,
        "loose_units" => nil,
        "quantity" => nil,
        "count_confidence" => "high",
        "basis" => "2 closed, 1 open"
      },
      attrs
    )
  end

  defp answer(objects, attrs \\ %{}) do
    Map.merge(
      %{
        "off_purpose" => %{"flag" => false, "reason" => ""},
        "nothing_found" => false,
        "overlap" => "",
        "objects" => objects
      },
      attrs
    )
  end

  defp check_one(attrs) do
    {:ok, %{objects: [checked], warnings: warnings}} =
      Response.check(answer([object(attrs)]), @context)

    {checked, warnings}
  end

  defp warned?(warnings, field), do: Enum.any?(warnings, &(&1["field"] == field))

  describe "schema/0 (§6.3)" do
    test "is strict: every object closed, every property required" do
      schema = Response.schema()

      assert_strict = fn object_schema ->
        assert object_schema["additionalProperties"] == false

        assert Enum.sort(object_schema["required"]) ==
                 Enum.sort(Map.keys(object_schema["properties"]))
      end

      assert_strict.(schema)
      assert_strict.(schema["properties"]["off_purpose"])
      assert_strict.(schema["properties"]["objects"]["items"])

      assert Enum.sort(Map.keys(schema["properties"])) ==
               ~w(nothing_found objects off_purpose overlap)

      assert Enum.sort(Map.keys(schema["properties"]["objects"]["items"]["properties"])) ==
               ~w(alternatives basis catalogue_no closed_packages count_confidence description
                  loose_units match_confidence object_key open_fill open_packages package photos
                  quantity units_per_package)
    end

    test "the nullable numbers and the enums" do
      props = Response.schema()["properties"]["objects"]["items"]["properties"]

      for field <- ~w(open_fill units_per_package loose_units quantity) do
        assert props[field]["type"] == ["number", "null"]
      end

      assert props["catalogue_no"]["type"] == ["integer", "null"]
      assert props["match_confidence"]["enum"] == ~w(high medium low)
      assert props["count_confidence"]["enum"] == ~w(high medium low)

      assert props["package"]["enum"] ==
               ~w(box pack blister bag bin sheet_stack board_stack roll loose other)
    end
  end

  describe "the answer as a whole" do
    test "not a map is an error" do
      assert Response.check(nil, @context) == {:error, :not_an_object}
      assert Response.check([object()], @context) == {:error, :not_an_object}
      assert Response.check("text", @context) == {:error, :not_an_object}
    end

    test "off_purpose with flag true is its own outcome, with the reason" do
      assert Response.check(
               answer([object()], %{
                 "off_purpose" => %{"flag" => true, "reason" => "A screenshot of a chat"}
               }),
               @context
             ) == {:off_purpose, "A screenshot of a chat"}
    end

    test "off_purpose that is not exactly true does not count" do
      assert {:ok, %{objects: [_]}} =
               Response.check(
                 answer([object()], %{"off_purpose" => %{"flag" => "true"}}),
                 @context
               )

      assert {:ok, %{objects: [_]}} =
               Response.check(Map.delete(answer([object()]), "off_purpose"), @context)
    end

    test "nothing_found gives an empty proposal, objects or not" do
      assert {:ok, %{objects: [], nothing_found: true}} =
               Response.check(answer([], %{"nothing_found" => true}), @context)

      assert {:ok, %{objects: [], nothing_found: true, warnings: warnings}} =
               Response.check(answer([object()], %{"nothing_found" => true}), @context)

      assert warned?(warnings, "objects")
    end

    test "an empty or missing objects list is nothing found" do
      assert {:ok, %{objects: [], nothing_found: true}} = Response.check(answer([]), @context)

      assert {:ok, %{objects: [], nothing_found: true}} =
               Response.check(Map.delete(answer([]), "objects"), @context)
    end

    test "an entry that is not an object is dropped with a warning" do
      assert {:ok, %{objects: [_], warnings: warnings}} =
               Response.check(answer([object(), "junk", 3]), @context)

      assert Enum.count(warnings, &(&1["field"] == "objects")) == 2
    end

    test "overlap is kept as text" do
      assert {:ok, %{overlap: "1 and 2 show the same shelf"}} =
               Response.check(
                 answer([object()], %{"overlap" => "1 and 2 show the same shelf"}),
                 @context
               )
    end
  end

  describe "catalogue numbers" do
    test "a number in the list stays" do
      assert {%{"catalogue_no" => 5}, []} = check_one(%{})
    end

    test "a number outside the list becomes null, with a warning" do
      {checked, warnings} = check_one(%{"catalogue_no" => 99})
      assert checked["catalogue_no"] == nil
      assert warned?(warnings, "catalogue_no")
    end

    test "a number of another type becomes null, with a warning" do
      for bad <- ["5", 5.5, true, %{}] do
        {checked, warnings} = check_one(%{"catalogue_no" => bad})
        assert checked["catalogue_no"] == nil
        assert warned?(warnings, "catalogue_no")
      end
    end

    test "a whole float is the number" do
      assert {%{"catalogue_no" => 5}, []} = check_one(%{"catalogue_no" => 5.0})
    end

    test "null stays null without a warning" do
      assert {%{"catalogue_no" => nil}, []} = check_one(%{"catalogue_no" => nil})
    end

    test "alternatives: from the list only, without the chosen one, no repeats, at most 3" do
      {checked, _} = check_one(%{"alternatives" => [5, 7, 99, 7, 8, "9", 10, 11]})
      assert checked["alternatives"] == [7, 8, 10]

      {checked, _} = check_one(%{"catalogue_no" => nil, "alternatives" => [5, 5, 6]})
      assert checked["alternatives"] == [5, 6]

      {checked, _} = check_one(%{"alternatives" => "5"})
      assert checked["alternatives"] == []
    end
  end

  describe "photos" do
    test "only 1..N, without repeats" do
      {checked, _} = check_one(%{"photos" => [2, 0, 4, 2, 3, -1, "1", 1.5]})
      assert checked["photos"] == [2, 3]
    end
  end

  describe "numbers (all Decimal)" do
    test "closed and open packages: whole, fractions rounded down" do
      {checked, warnings} = check_one(%{"closed_packages" => 2.7, "open_packages" => 1})
      assert Decimal.equal?(checked["closed_packages"], 2)
      assert Decimal.equal?(checked["open_packages"], 1)
      refute warned?(warnings, "closed_packages")
    end

    test "a negative package count is 0, with a warning" do
      {checked, warnings} = check_one(%{"closed_packages" => -3, "open_packages" => -0.5})
      assert Decimal.equal?(checked["closed_packages"], 0)
      assert Decimal.equal?(checked["open_packages"], 0)
      assert warned?(warnings, "closed_packages")
      assert warned?(warnings, "open_packages")
    end

    test "a missing or non-number package count is 0, with a warning" do
      {checked, warnings} = check_one(%{"closed_packages" => nil, "open_packages" => "2"})
      assert Decimal.equal?(checked["closed_packages"], 0)
      assert Decimal.equal?(checked["open_packages"], 0)
      assert warned?(warnings, "closed_packages")
      assert warned?(warnings, "open_packages")
    end

    test "open_fill: kept in [0, 0.4], cut to the bound outside it, null is 0.35" do
      {checked, warnings} = check_one(%{"open_fill" => 0.25})
      assert Decimal.equal?(checked["open_fill"], Decimal.new("0.25"))
      refute warned?(warnings, "open_fill")

      {checked, warnings} = check_one(%{"open_fill" => 0.65})
      assert Decimal.equal?(checked["open_fill"], Decimal.new("0.4"))
      assert warned?(warnings, "open_fill")

      {checked, warnings} = check_one(%{"open_fill" => -0.2})
      assert Decimal.equal?(checked["open_fill"], Decimal.new("0"))
      assert warned?(warnings, "open_fill")

      {checked, warnings} = check_one(%{"open_fill" => nil})
      assert Decimal.equal?(checked["open_fill"], Decimal.new("0.35"))
      refute warned?(warnings, "open_fill")
    end

    test "units_per_package: above 0 or null" do
      {checked, _} = check_one(%{"units_per_package" => 50})
      assert Decimal.equal?(checked["units_per_package"], 50)

      for bad <- [0, -5, "10"] do
        {checked, warnings} = check_one(%{"units_per_package" => bad})
        assert checked["units_per_package"] == nil
        assert warned?(warnings, "units_per_package")
      end

      assert {%{"units_per_package" => nil}, []} = check_one(%{"units_per_package" => nil})
    end

    test "loose_units and quantity: 0 or more, or null; never 0 from a bad value" do
      {checked, _} = check_one(%{"loose_units" => 0, "quantity" => 12.5})
      assert Decimal.equal?(checked["loose_units"], 0)
      assert Decimal.equal?(checked["quantity"], Decimal.new("12.5"))

      {checked, warnings} = check_one(%{"loose_units" => -1, "quantity" => "3"})
      assert checked["loose_units"] == nil
      assert checked["quantity"] == nil
      assert warned?(warnings, "loose_units")
      assert warned?(warnings, "quantity")
    end

    test "a float is taken by its shortest text, not its binary expansion" do
      {checked, _} = check_one(%{"open_fill" => 0.35, "quantity" => 0.1})
      assert Decimal.to_string(checked["open_fill"]) == "0.35"
      assert Decimal.to_string(checked["quantity"]) == "0.1"
    end
  end

  describe "texts and enums" do
    test "description and basis at most 120 characters" do
      long = String.duplicate("ä", 200)
      {checked, _} = check_one(%{"description" => long, "basis" => long})
      assert String.length(checked["description"]) == 120
      assert String.length(checked["basis"]) == 120
    end

    test "an unknown confidence is low, an unknown package other" do
      {checked, _} =
        check_one(%{
          "match_confidence" => "sure",
          "count_confidence" => nil,
          "package" => "crate"
        })

      assert checked["match_confidence"] == "low"
      assert checked["count_confidence"] == "low"
      assert checked["package"] == "other"
    end

    test "an object without a key gets its number" do
      {:ok, %{objects: [_, second]}} =
        Response.check(answer([object(), object(%{"object_key" => " "})]), @context)

      assert second["object_key"] == "2"
    end
  end

  describe "truncated?/1" do
    test "an answer cut off inside the JSON" do
      assert Response.truncated?({:no_json_in_response, ~s({"objects": [{"object_key": "A", ")})
      assert Response.truncated?({:no_json_in_response, "  ```json\n{\"objects\": ["})
      refute Response.truncated?({:no_json_in_response, "I cannot help with that."})
      refute Response.truncated?(:request_timeout)
    end
  end
end
