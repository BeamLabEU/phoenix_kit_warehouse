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

  test "the README lists the five API tools and their scopes" do
    for name <-
          ~w(warehouse.list_locations warehouse.get_stock warehouse.receive_stock warehouse.set_stock warehouse.issue_stock) do
      assert @readme =~ name
    end

    for scope <-
          ~w(warehouse.stock:read warehouse.stock:receive warehouse.stock:adjust warehouse.stock:issue) do
      assert @readme =~ scope
    end
  end

  test "the README documents the trash and the one_draft_per_source switch" do
    for phrase <- [
          "config :phoenix_kit_warehouse, one_draft_per_source: true",
          "replace_draft_for_source/3",
          "supersede_drafts: true",
          "swap: true",
          "?view=trash"
        ] do
      assert @readme =~ phrase
    end
  end

  test "the README describes the photo inventory and drops its table first on removal" do
    for phrase <- [
          "### Photo inventory (AI)",
          "warehouse_inventory_ai_endpoint_uuid",
          "warehouse_inventory_ai_max_photos",
          "warehouse_inventory_ai_max_items",
          "phoenix_kit_ai",
          "base_fingerprint:",
          "\"counted_by\""
        ] do
      assert @readme =~ phrase
    end

    [_, removal] = String.split(@readme, "### Removing this module", parts: 2)
    [first_drop | _] = Regex.run(~r/^DROP TABLE \S+;/m, removal)
    assert first_drop == "DROP TABLE phoenix_kit_warehouse_inventory_ai_runs;"
  end

  test "the README states the caveats an integrator must know" do
    # the catalogue_id rule, the retry answer, the issue retry gap, the confirmation hold,
    # the log switch
    for phrase <- [
          "more than one active catalogue",
          "external_ref_lines_differ",
          "external_ref_basis_differs",
          "not protected against a repeated request",
          "confirm_token",
          ":inventory_activity_logging"
        ] do
      assert @readme =~ phrase
    end
  end
end
