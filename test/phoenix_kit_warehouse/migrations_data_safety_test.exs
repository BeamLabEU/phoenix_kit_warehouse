defmodule PhoenixKitWarehouse.MigrationsDataSafetyTest do
  use PhoenixKitWarehouse.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitWarehouse.Migrations
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.StockLedger

  @moduledoc """
  The acceptance a table full of live stock balances actually needs, and
  that no static test can give: a REAL row, a REAL `down/1` run as a
  migration, and the row still there afterwards, byte-for-byte.

  `migrations_test.exs` proves what the chain BUILDS (no
  DROP/TRUNCATE/DELETE token anywhere, `down/1` emits marker bookkeeping
  only). That is a proof about text. This file proves what the chain DOES
  to a database that holds a real stock balance — on the anchor table,
  `phoenix_kit_warehouse_stock`, the table most likely to be non-empty on a
  real host at upgrade time.

  The last test is the mutation check: it runs the same survival harness
  against a deliberately destructive rollback and requires it to FAIL.
  Without that, a survival assertion that silently stopped asserting (wrong
  table name, empty row set) would stay green forever and prove nothing.

  `async: false` — the migrator wants the shared sandbox connection.
  """

  defmodule RollbackToZero do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.down(prefix: "public", version: 0)
    def down, do: :ok
  end

  defmodule RollbackToOneFromMap do
    @moduledoc false
    use Ecto.Migration

    # Deliberately the MAP shape: it is accepted, so it must carry
    # `:version` like the keyword list does.
    def up, do: Migrations.down(%{prefix: "public", version: 1})
    def down, do: :ok
  end

  defmodule DestructiveRollback do
    @moduledoc false
    use Ecto.Migration

    # NOT what the package ships — the mutant the survival check must catch.
    def up do
      execute("DELETE FROM public.phoenix_kit_warehouse_stock")
    end

    def down, do: :ok
  end

  setup do
    item_uuid = Ecto.UUID.generate()
    location_uuid = Ecto.UUID.generate()

    {:ok, stock} =
      StockLedger.upsert_quantity(item_uuid, "42.5",
        location_uuid: location_uuid,
        unit_value: "9.99"
      )

    {:ok, stock: stock}
  end

  test "a real down(version: 0) leaves the seeded stock row alive, quantity/unit_value unchanged",
       %{stock: stock} do
    before_count = count()

    run_migration(RollbackToZero)

    assert count() == before_count,
           "rolling this chain back changed the row count in phoenix_kit_warehouse_stock"

    reloaded = Repo.get!(Stock, stock.uuid)
    assert reloaded.item_uuid == stock.item_uuid
    assert reloaded.location_uuid == stock.location_uuid
    assert reloaded.quantity == stock.quantity
    assert reloaded.unit_value == stock.unit_value
  end

  test "the rollback still does its one real job: the marker is cleared" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_warehouse_stock IS 'pkw_schema:1'")
    assert Migrations.migrated_version_runtime(prefix: "public") == 1

    run_migration(RollbackToZero)

    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end

  test "a rollback to version 1 passed as a map stops at 1, not at 0" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_warehouse_stock IS 'pkw_schema:1'")

    run_migration(RollbackToOneFromMap)

    assert Migrations.migrated_version_runtime(prefix: "public") == 1,
           "the map shape lost :version and rolled the chain further back than asked"
  end

  test "the survival check has teeth: a destructive rollback fails it", %{stock: stock} do
    before_count = count()

    run_migration(DestructiveRollback)

    # The same assertions the real test makes. Both must fail here, or the
    # real test above is decoration.
    assert_raise ExUnit.AssertionError, fn ->
      assert count() == before_count
    end

    assert_raise ExUnit.AssertionError, fn ->
      assert Repo.get(Stock, stock.uuid) != nil
    end
  end

  test "README's manual removal SQL leaves no phoenix_kit_warehouse_* table or sequence" do
    # The number sequences are not OWNED BY their columns, so DROP TABLE alone
    # orphans them. Guard against the list being empty before the drop, or
    # the "nothing survives" assertion would pass vacuously.
    assert length(warehouse_relations()) == 14

    Enum.each(readme_removal_statements(), &Repo.query!/1)

    assert warehouse_relations() == [],
           "README's removal SQL left relations behind"
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # Runs the migration IN THIS PROCESS, through Ecto's own migration runner,
  # rather than `Ecto.Migrator.up/4`. The Migrator runs the migration inside a
  # `Task`, which then has to check out the sandbox connection this test
  # already owns — it never gets it, and every assertion below dies in the
  # checkout queue instead of testing the rollback. The runner is what the
  # Migrator itself calls once it has dealt with locking and version
  # bookkeeping; going straight to it keeps the real migration context (so
  # `execute/1` inside `down/1` is the real `execute/1`) and drops only the
  # parts this file is not about.
  defp run_migration(module) do
    Runner.run(
      Repo,
      [],
      :os.system_time(:microsecond),
      module,
      :forward,
      :up,
      :up,
      log: false,
      log_migrations_sql: false
    )
  end

  defp warehouse_relations do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.relname
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relkind IN ('r', 'S')
        AND c.relname LIKE 'phoenix\\_kit\\_warehouse\\_%'
      ORDER BY c.relname
      """)

    List.flatten(rows)
  end

  # The first ```sql block under README's "Removing this module" heading, one
  # statement per `;`, comment lines stripped.
  defp readme_removal_statements do
    [_, section] =
      "../../README.md"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> String.split("### Removing this module", parts: 2)

    [_, sql | _] = String.split(section, ["```sql", "```"])

    sql
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "--"))
    |> Enum.join("\n")
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM phoenix_kit_warehouse_stock")
    count
  end
end
