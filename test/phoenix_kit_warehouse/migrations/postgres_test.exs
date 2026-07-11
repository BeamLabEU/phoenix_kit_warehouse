defmodule PhoenixKitWarehouse.Migrations.PostgresTest do
  # async: false — this test drives real DDL (CREATE TABLE/INDEX, COMMENT ON
  # TABLE) plus Ecto's own schema_migrations bookkeeping through a genuine
  # Ecto.Migrator run; keep it off the shared sandbox's async lane.
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.Migrations.Postgres
  alias PhoenixKitWarehouse.Test.MigrationsRunner
  alias PhoenixKitWarehouse.Test.Repo

  describe "current_version/0" do
    test "is 1" do
      assert Postgres.current_version() == 1
    end
  end

  describe "migrated_version_runtime/1" do
    test "is 0 before V01 has run" do
      assert Postgres.migrated_version_runtime(prefix: "public") == 0
    end

    test "accepts a map as well as a keyword list" do
      assert Postgres.migrated_version_runtime(%{prefix: "public"}) == 0
    end

    test "defaults to the public prefix when omitted" do
      assert Postgres.migrated_version_runtime([]) == 0
    end
  end

  describe "up/1" do
    test "creates phoenix_kit_warehouse_transfers and stamps the version marker" do
      Ecto.Migrator.up(Repo, :os.system_time(:microsecond), MigrationsRunner, log: false)

      assert Postgres.migrated_version_runtime(prefix: "public") == Postgres.current_version()

      assert {:ok, %{rows: [[true]]}} =
               Repo.query(
                 "SELECT to_regclass('public.phoenix_kit_warehouse_transfers') IS NOT NULL",
                 []
               )
    end

    test "is idempotent — running twice does not raise" do
      Ecto.Migrator.up(Repo, :os.system_time(:microsecond), MigrationsRunner, log: false)
      Ecto.Migrator.up(Repo, :os.system_time(:microsecond), MigrationsRunner, log: false)

      assert Postgres.migrated_version_runtime(prefix: "public") == Postgres.current_version()
    end
  end
end
