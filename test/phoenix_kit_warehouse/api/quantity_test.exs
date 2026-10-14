defmodule PhoenixKitWarehouse.API.QuantityTest do
  @moduledoc """
  `Quantity`: the strict reading of quantities and unit values the warehouse
  API takes (a decimal string or a JSON number, 0 to 1e9, at most 6 places),
  and their rendering.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.API.Quantity

  defp ok(value, minimum \\ :zero) do
    assert {:ok, %Decimal{} = number} = Quantity.parse(value, minimum)
    Decimal.to_string(number, :normal)
  end

  defp refused(value, minimum \\ :zero) do
    assert {:error, message} = Quantity.parse(value, minimum)
    assert is_binary(message) and message != ""
    message
  end

  describe "parse/2 accepts" do
    test "plain decimal strings" do
      assert ok("12") == "12"
      assert ok("0.5") == "0.5"
      assert ok("0.000001") == "0.000001"
      assert ok("1000000000") == "1000000000"
      assert ok("12.500000") == "12.500000"
    end

    test "integers and floats, with the float read as its shortest decimal form" do
      assert ok(3) == "3"
      assert ok(0) == "0"
      assert ok(0.1) == "0.1"
      assert ok(2.5) == "2.5"
    end

    test "zero for :zero, never for :positive" do
      assert ok("0") == "0"
      assert ok(0.0) == "0"
      assert refused("0", :positive) =~ "greater than zero"
      assert refused(0, :positive) =~ "greater than zero"
      assert ok("0.000001", :positive) == "0.000001"
    end
  end

  describe "parse/2 refuses" do
    test "negative values, in every spelling" do
      assert refused("-1") =~ "plain decimal"
      assert refused(-1) =~ "negative"
      assert refused(-0.5) =~ "negative"
      assert refused("+1") =~ "plain decimal"
    end

    test "exponent forms, so a huge exponent never reaches the database" do
      assert refused("1e3") =~ "plain decimal"
      assert refused("1E+999999") =~ "plain decimal"
      assert refused("1e999999") =~ "plain decimal"
      assert refused(1.0e30) =~ "at most"
    end

    test "padding, separators and fragments" do
      for bad <- [" 5", "5 ", "1,5", ".5", "5.", "", "abc", "1.2.3", "5\n", "\n5", "1_000"] do
        assert refused(bad) =~ "plain decimal", inspect(bad)
      end
    end

    test "more than 6 decimal places, from a string and from a float" do
      assert refused("1.0000001") =~ "6 decimal places"
      assert refused(1.0e-7) =~ "6 decimal places"
    end

    test "more than 1 000 000 000, from a string, an integer and a very long digit string" do
      assert refused("1000000001") =~ "at most"
      assert refused(1_000_000_001) =~ "at most"
      assert refused(String.duplicate("9", 500)) =~ "plain decimal"
      assert refused(10 ** 400) =~ "at most"
    end

    test "values that are not numbers at all" do
      for bad <- [true, false, nil, [], [1], %{}, %{"a" => 1}, :five] do
        assert refused(bad) =~ "number", inspect(bad)
      end
    end
  end

  describe "rendering" do
    test "format/1 drops padding zeros and accepts the shapes a stored line holds" do
      assert Quantity.format(Decimal.new("5.000000")) == "5"
      assert Quantity.format(Decimal.new("1.500000")) == "1.5"
      assert Quantity.format(Decimal.new("0.000000")) == "0"
      assert Quantity.format("7.250") == "7.25"
      assert Quantity.format(100) == "100"
    end

    test "format_optional/1 keeps nil" do
      assert Quantity.format_optional(nil) == nil
      assert Quantity.format_optional(Decimal.new("2.0")) == "2"
    end

    test "to_param/1 is plain notation, the form the posting functions take" do
      assert Quantity.to_param(Decimal.new("100")) == "100"
      assert Quantity.to_param(Decimal.new("0.5")) == "0.5"
      assert Quantity.to_param(Decimal.new("1E+2")) == "100"
    end
  end
end
