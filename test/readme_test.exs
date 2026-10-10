defmodule PhoenixKitWarehouse.ReadmeTest do
  use ExUnit.Case, async: true

  @readme File.read!(Path.expand("../README.md", __DIR__))

  test "the README describes an implemented module, not a scaffold" do
    refute @readme =~ ~r/scaffold/i
    refute @readme =~ "Planned scope"
    assert @readme =~ "**Status:** implemented"
  end

  test "the README covers stock, documents, posting semantics and the programmatic API" do
    for needle <- [
          "Stock per item and location",
          "Goods issue",
          "Inventory document",
          "compare-and-swap",
          "create_and_post",
          "external_ref",
          "warehouse_source_kinds/0"
        ] do
      assert @readme =~ needle, "README no longer mentions #{inspect(needle)}"
    end
  end

  test "the uninstall section is kept" do
    assert @readme =~ "### Removing this module"
    assert @readme =~ "COMMENT ON TABLE phoenix_kit_warehouse_stock IS NULL;"
  end
end
