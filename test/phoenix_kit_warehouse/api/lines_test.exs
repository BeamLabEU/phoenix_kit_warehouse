defmodule PhoenixKitWarehouse.API.LinesTest do
  @moduledoc """
  `Lines.prepare/2`: refs, quantities and duplicates of a document's lines,
  every problem reported at once.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKitWarehouse.API.Lines

  setup do
    catalogue = catalogue!()
    %{catalogue: catalogue, a: item!(catalogue), b: item!(catalogue)}
  end

  defp prep(lines, opts \\ []),
    do: Lines.prepare(lines, Keyword.merge([minimum: :positive], opts))

  defp line(item, quantity, extra \\ %{}),
    do: Map.merge(%{"ref" => %{"id" => item.uuid}, "quantity" => quantity}, extra)

  defp error_at(errors, path), do: Enum.find(errors, &(&1.path == path))

  test "valid lines come back in order with the item, the Decimal quantity and the ref as given",
       %{a: a, b: b} do
    assert {:ok, [first, second]} = prep([line(a, "2"), line(b, 1.5)])

    assert first.index == 0
    assert first.ref == %{"id" => a.uuid}

    assert first.item == %{
             uuid: a.uuid,
             sku: a.sku,
             name: a.name,
             unit: a.unit,
             catalogue_uuid: a.catalogue_uuid
           }

    assert Decimal.equal?(first.quantity, Decimal.new(2))
    assert first.unit_value == nil
    assert second.index == 1
    assert Decimal.equal?(second.quantity, Decimal.new("1.5"))
  end

  test "unit_value is read only when asked for", %{a: a, b: b} do
    lines = [line(a, "1", %{"unit_value" => "1.25"}), line(b, "1")]

    assert {:ok, [with_value, without]} = prep(lines, unit_value: true)
    assert Decimal.equal?(with_value.unit_value, Decimal.new("1.25"))
    assert without.unit_value == nil

    assert {:ok, [ignored, _]} = prep(lines)
    assert ignored.unit_value == nil

    assert {:error, errors} = prep([line(a, "1", %{"unit_value" => "-3"})], unit_value: true)
    assert %{code: "validation_failed"} = error_at(errors, "lines[0].unit_value")
  end

  test "zero passes with :zero and fails with :positive", %{a: a} do
    assert {:ok, [%{quantity: zero}]} = prep([line(a, "0")], minimum: :zero)
    assert Decimal.equal?(zero, Decimal.new(0))

    assert {:error, errors} = prep([line(a, "0")])
    assert %{message: message} = error_at(errors, "lines[0].quantity")
    assert message =~ "greater than zero"
  end

  test "every problem of every line is reported together, in line order", %{a: a} do
    unknown = %{"id" => Ecto.UUID.generate()}

    lines = [
      line(a, "1"),
      %{"ref" => unknown, "quantity" => "x"},
      "not an object",
      %{"ref" => %{"id" => a.uuid}}
    ]

    assert {:error, errors} = prep(lines)

    assert %{code: "not_found"} = error_at(errors, "lines[1].ref")
    assert %{code: "validation_failed"} = error_at(errors, "lines[1].quantity")
    assert %{code: "validation_failed"} = error_at(errors, "lines[2]")
    assert %{code: "validation_failed"} = error_at(errors, "lines[3].quantity")
    assert %{code: "duplicate_line"} = error_at(errors, "lines[3]")

    indexes = Enum.map(errors, &String.replace(&1.path, ~r/\A.*\[(\d+)\].*\z/, "\\1"))
    assert indexes == Enum.sort_by(indexes, &String.to_integer/1)
  end

  describe "duplicates" do
    test "the same product twice is a duplicate_line on the second line", %{a: a} do
      assert {:error, [error]} = prep([line(a, "1"), line(a, "2")])
      assert error.path == "lines[1]"
      assert error.code == "duplicate_line"
      assert error.first_line == 0
      assert error.message =~ "lines[0]"
    end

    test "an upper-case UUID and a lower-case one are the same product", %{a: a} do
      lines = [
        %{"ref" => %{"id" => String.upcase(a.uuid)}, "quantity" => "1"},
        %{"ref" => %{"id" => a.uuid}, "quantity" => "1"}
      ]

      assert {:error, [%{code: "duplicate_line", path: "lines[1]"}]} = prep(lines)
    end

    test "three lines for one product report the second and the third", %{a: a} do
      assert {:error, errors} = prep([line(a, "1"), line(a, "1"), line(a, "1")])
      assert Enum.map(errors, & &1.path) == ["lines[1]", "lines[2]"]
      assert Enum.all?(errors, &(&1.first_line == 0))
    end

    test "different products are not duplicates", %{a: a, b: b} do
      assert {:ok, [_, _]} = prep([line(a, "1"), line(b, "1")])
    end
  end

  test "an empty list, a non-list and a list with only unusable entries are refused at lines", %{
    a: a
  } do
    for bad <- [[], nil, "x", %{}, 5] do
      assert {:error, [%{path: "lines", code: "validation_failed"}]} = prep(bad), inspect(bad)
    end

    assert {:error, [_]} = prep([nil])
    assert a.uuid
  end

  test "a product of an archived catalogue is refused for a write, at its ref", %{
    catalogue: catalogue,
    a: a
  } do
    set_catalogue_status!(catalogue, "archived")

    assert {:error, [%{path: "lines[0].ref", code: "not_found", message: message}]} =
             prep([line(a, "1")])

    assert message =~ "archived"
  end

  test "line numbers above 9 are sorted numerically", %{catalogue: catalogue} do
    items = for _ <- 1..12, do: item!(catalogue)
    lines = Enum.map(items, &line(&1, "1")) ++ [line(hd(items), "1")]

    assert {:error, [%{path: "lines[12]", first_line: 0}]} = prep(lines)
  end
end
