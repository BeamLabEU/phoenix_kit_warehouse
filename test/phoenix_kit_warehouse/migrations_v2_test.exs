defmodule PhoenixKitWarehouse.MigrationsV2Test do
  @moduledoc """
  Chain version 2: `reason` on goods issues, `external_ref` on goods issues,
  goods receipts and inventory documents, plus a partial unique index per
  table over posted, non-deleted documents carrying an `external_ref`.

  The DB tests run the REAL `Migrations.up/1` through Ecto's migration runner
  against a table that is put back into its pre-V2 shape first (DDL is
  transactional in Postgres, so the sandbox rolls all of it back).
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.Migrations

  @issues "phoenix_kit_warehouse_goods_issues"
  @receipts "phoenix_kit_warehouse_goods_receipts"
  @inventories "phoenix_kit_warehouse_inventory_documents"

  defmodule UpToV2 do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.up(prefix: "public", version: 2)
    def down, do: :ok
  end

  describe "statements (pure)" do
    test "V2 adds exactly the reason and external_ref columns, guarded" do
      v2 =
        "public"
        |> Migrations.up_statements(2)
        |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
        |> Enum.filter(&String.starts_with?(&1, "ALTER TABLE"))

      assert length(v2) == 4
      assert Enum.all?(v2, &(&1 =~ "ADD COLUMN IF NOT EXISTS"))

      assert Enum.any?(
               v2,
               &(&1 =~ @issues and &1 =~ "\"reason\" character varying(20)" and
                   &1 =~ "DEFAULT 'production' NOT NULL")
             )

      for table <- [@issues, @receipts, @inventories] do
        assert Enum.any?(
                 v2,
                 &(&1 =~ table and &1 =~ "\"external_ref\" character varying(255)" and
                     not (&1 =~ "NOT NULL"))
               )
      end
    end

    test "every V2 index is a partial unique index over posted, live, referenced documents" do
      indexes =
        "public"
        |> Migrations.up_statements(2)
        |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
        |> Enum.filter(&(&1 =~ "external_ref_index"))

      assert length(indexes) == 3

      for index <- indexes do
        assert index =~ "CREATE UNIQUE INDEX IF NOT EXISTS"
        assert index =~ "(external_ref)"

        assert index =~
                 "WHERE external_ref IS NOT NULL AND status = 'posted' AND deleted_at IS NULL"
      end
    end

    test "V2 widths come from the schemas' v2_column_widths/0" do
      assert GoodsIssue.v2_column_widths() == %{reason: 20, external_ref: 255}
      assert GoodsReceipt.v2_column_widths() == %{external_ref: 255}
      assert InventoryDocument.v2_column_widths() == %{external_ref: 255}
    end

    test "up_statements for target 1 stays the published V1 (no V2 object leaks in)" do
      refute "public" |> Migrations.up_statements(1) |> Enum.join("\n") =~ "external_ref"
    end
  end

  describe "migrating an existing database" do
    setup do
      # Put the three tables back into their pre-V2 shape, as a host at
      # pkw_schema:1 has them, then seed a document that predates the column.
      for table <- [@issues, @receipts, @inventories] do
        Repo.query!("DROP INDEX IF EXISTS #{table}_external_ref_index")
        Repo.query!("ALTER TABLE #{table} DROP COLUMN IF EXISTS external_ref")
      end

      Repo.query!("ALTER TABLE #{@issues} DROP COLUMN IF EXISTS reason")
      Repo.query!("COMMENT ON TABLE phoenix_kit_warehouse_stock IS 'pkw_schema:1'")

      Repo.query!(
        "INSERT INTO #{@issues} (location_uuid, status) VALUES ($1, 'posted')",
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      )

      :ok
    end

    test "up sets reason = production on rows that predate the column" do
      assert Migrations.migrated_version_runtime(prefix: "public") == 1

      run_migration(UpToV2)

      assert Migrations.migrated_version_runtime(prefix: "public") == 2
      assert %{rows: [["production"]]} = Repo.query!("SELECT reason FROM #{@issues}")
    end

    test "after up the column is NOT NULL with default production, external_ref is nullable" do
      run_migration(UpToV2)

      assert %{rows: [["NO", default]]} =
               Repo.query!("""
               SELECT is_nullable, column_default
               FROM information_schema.columns
               WHERE table_name = '#{@issues}' AND column_name = 'reason'
               """)

      assert default =~ "production"

      for table <- [@issues, @receipts, @inventories] do
        assert %{rows: [["YES"]]} =
                 Repo.query!("""
                 SELECT is_nullable FROM information_schema.columns
                 WHERE table_name = '#{table}' AND column_name = 'external_ref'
                 """)
      end
    end

    test "running up again is a no-op" do
      run_migration(UpToV2)
      run_migration(UpToV2)

      assert Migrations.migrated_version_runtime(prefix: "public") == 2
      assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM #{@issues}")
    end

    test "the partial unique index rejects a second posted document with the same external_ref" do
      run_migration(UpToV2)

      for table <- [@issues, @receipts, @inventories] do
        insert = fn status, ref, deleted_at ->
          Repo.query(
            "INSERT INTO #{table} (location_uuid, status, external_ref, deleted_at) " <>
              "VALUES ($1, $2, $3, $4)",
            [Ecto.UUID.dump!(Ecto.UUID.generate()), status, ref, deleted_at]
          )
        end

        assert {:ok, _} = insert.("posted", "EXT-1", nil)

        # Savepoints: a failed statement would otherwise poison the sandbox transaction.
        assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
                 Repo.transaction(fn ->
                   case insert.("posted", "EXT-1", nil) do
                     {:error, e} -> Repo.rollback(e)
                     ok -> ok
                   end
                 end),
               "#{table} accepted a second posted document with the same external_ref"

        # Drafts, soft-deleted documents, other refs and missing refs are outside the index.
        assert {:ok, _} = insert.("draft", "EXT-1", nil)
        assert {:ok, _} = insert.("draft", "EXT-1", nil)
        assert {:ok, _} = insert.("posted", "EXT-1", DateTime.utc_now())
        assert {:ok, _} = insert.("posted", "EXT-2", nil)
        assert {:ok, _} = insert.("posted", nil, nil)
        assert {:ok, _} = insert.("posted", nil, nil)
      end
    end
  end

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
end
