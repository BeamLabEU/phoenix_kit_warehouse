defmodule PhoenixKitWarehouse.ReadmeTest do
  use ExUnit.Case, async: true

  @readme File.read!(Path.expand("../README.md", __DIR__))

  test "the README describes an implemented module, not a scaffold" do
    refute @readme =~ ~r/scaffold/i
    refute @readme =~ "Planned scope"
    assert @readme =~ "**Status:** implemented"
  end

  test "the uninstall section is kept" do
    assert @readme =~ "### Removing this module"
    assert @readme =~ "COMMENT ON TABLE phoenix_kit_warehouse_stock IS NULL;"
  end
end
