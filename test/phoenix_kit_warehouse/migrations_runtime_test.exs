defmodule PhoenixKitWarehouse.MigrationsRuntimeTest do
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.Migrations

  @moduledoc """
  Exercises `migrated_version_runtime/1` against a real database — the read
  path the pure data/string tests in `migrations_test.exs` cannot cover (see
  that file's moduledoc: none of its tests touch a database). A regression in
  the SELECT itself (broken join, wrong classoid) would leave that suite
  green while this function permanently returns 0 in production, and callers
  (status/update task) would never see the real installed version.

  `async: false` — each test mutates the anchor table's table-level COMMENT
  rather than rows.
  """

  @anchor "phoenix_kit_warehouse_stock"

  test "reads 0 when the anchor table carries no marker comment" do
    Repo.query!("COMMENT ON TABLE #{@anchor} IS NULL")

    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end

  test "reads the version parsed out of the pkw_schema marker" do
    Repo.query!("COMMENT ON TABLE #{@anchor} IS 'pkw_schema:1'")

    assert Migrations.migrated_version_runtime(prefix: "public") == 1
  end

  test "reads 0 again once a stamped marker is cleared" do
    Repo.query!("COMMENT ON TABLE #{@anchor} IS 'pkw_schema:1'")
    assert Migrations.migrated_version_runtime(prefix: "public") == 1

    Repo.query!("COMMENT ON TABLE #{@anchor} IS NULL")
    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end
end
