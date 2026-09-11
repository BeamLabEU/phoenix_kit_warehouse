defmodule PhoenixKitWarehouse.StockLedgerFormatQuantityTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins `StockLedger.format_quantity/1`, the one place that decides how a
  quantity reads on screen.

  Quantities are stored in `numeric(_, 6)` columns, so a whole count comes back
  as `5.000000` and printing it verbatim shows six zeros nobody entered. The
  scale carries no information here, and the fix is a single normalisation step
  every display path now routes through — which makes this function's exact
  output a contract worth holding still, not an implementation detail. It needs
  no database, so there is no reason for it to go untested.
  """

  alias PhoenixKitWarehouse.StockLedger

  describe "format_quantity/1" do
    test "drops the column's padding zeros" do
      assert StockLedger.format_quantity(Decimal.new("5.000000")) == "5"
      assert StockLedger.format_quantity(Decimal.new("0.000000")) == "0"
      assert StockLedger.format_quantity(Decimal.new("100.000000")) == "100"
    end

    test "keeps every digit the value actually carries" do
      assert StockLedger.format_quantity(Decimal.new("1.500000")) == "1.5"
      assert StockLedger.format_quantity(Decimal.new("0.125000")) == "0.125"
      assert StockLedger.format_quantity(Decimal.new("0.000001")) == "0.000001"
    end

    test "never uses exponent notation" do
      # `Decimal.normalize/1` leaves an integral value in exponent form (5E+0),
      # which is why the `:normal` formatting argument is not optional here. A
      # quantity rendered as "5E+2" in a table would be a bug report.
      assert StockLedger.format_quantity(Decimal.new("500.000000")) == "500"
      refute StockLedger.format_quantity(Decimal.new("500.000000")) =~ "E"
      refute StockLedger.format_quantity(Decimal.new("0.000001")) =~ "E"
    end

    test "accepts the shapes a jsonb line map actually holds" do
      # Lines come back from jsonb with their quantities as strings, and older
      # rows may carry integers or floats. All three reach this function.
      assert StockLedger.format_quantity("5.000000") == "5"
      assert StockLedger.format_quantity("1.500000") == "1.5"
      assert StockLedger.format_quantity(5) == "5"
      assert StockLedger.format_quantity(1.5) == "1.5"
    end

    test "reads the et/ru decimal comma" do
      # `to_decimal/1` normalises a comma to a dot before parsing; without that
      # step `Decimal.parse/1` stops at the comma and silently truncates.
      assert StockLedger.format_quantity("1,5") == "1.5"
    end

    test "treats an absent value as zero, not as a crash" do
      assert StockLedger.format_quantity(nil) == "0"
      assert StockLedger.format_quantity("") == "0"
    end
  end
end
