defmodule PhoenixKitWarehouse.MigrationsV3Test do
  @moduledoc """
  Chain version 3: the runs of the photo inventory
  (`phoenix_kit_warehouse_inventory_ai_runs`), with an index over the
  document and a partial unique index that lets a document have one running
  run at a time.

  The DB tests run the REAL `Migrations.up/1` and `down/1` through Ecto's
  migration runner against a database put back into its pre-V3 shape first
  (DDL is transactional in Postgres, so the sandbox rolls all of it back).
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitWarehouse.InventoryAIRun
  alias PhoenixKitWarehouse.Migrations

  @runs "phoenix_kit_warehouse_inventory_ai_runs"
  @documents "phoenix_kit_warehouse_inventory_documents"

  defmodule UpToV3 do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.up(prefix: "public", version: 3)
    def down, do: :ok
  end

  defmodule DownToV2 do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.down(prefix: "public", version: 2)
    def down, do: :ok
  end

  defp v3_statements(prefix \\ "public") do
    v2 = Migrations.up_statements(prefix, 2) |> Enum.drop(-1)

    prefix
    |> Migrations.up_statements(3)
    |> Enum.drop(-1)
    |> Enum.drop(length(v2))
    |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
  end

  describe "statements (pure)" do
    test "V3 is one table and its two indexes, all guarded" do
      statements = v3_statements()

      assert length(statements) == 3
      assert Enum.all?(statements, &(&1 =~ "IF NOT EXISTS"))
    end

    test "the table carries every column of the run, with the document FK cascading" do
      [create | _] = v3_statements()

      assert create =~ "CREATE TABLE IF NOT EXISTS public.#{@runs} ("

      for column <- [
            ~s|"uuid" uuid DEFAULT public.uuid_generate_v7() NOT NULL|,
            ~s|"inventory_uuid" uuid NOT NULL|,
            ~s|"location_uuid" uuid NOT NULL|,
            ~s|"place_label" character varying(200)|,
            ~s|"photo_file_uuids" uuid[] DEFAULT '{}'::uuid[] NOT NULL|,
            ~s|"status" character varying(20) DEFAULT 'running'::character varying NOT NULL|,
            ~s|"endpoint_uuid" uuid|,
            ~s|"model" character varying(255)|,
            ~s|"prompt_uuid" uuid|,
            ~s|"ai_request_uuid" uuid|,
            ~s|"catalogue_map" jsonb DEFAULT '{}'::jsonb NOT NULL|,
            ~s|"result" jsonb|,
            ~s|"decisions" jsonb|,
            ~s|"error" text|,
            ~s|"created_by_uuid" uuid|,
            ~s|"applied_by_uuid" uuid|,
            ~s|"late_result" jsonb|,
            ~s|"applied_at" timestamp with time zone|,
            ~s|"inserted_at" timestamp with time zone DEFAULT now() NOT NULL|,
            ~s|"updated_at" timestamp with time zone DEFAULT now() NOT NULL|
          ] do
        assert create =~ column, "the CREATE TABLE lacks #{column}"
      end

      assert create =~ "CONSTRAINT #{@runs}_pkey PRIMARY KEY (uuid)"

      assert create =~
               "CONSTRAINT #{@runs}_inventory_uuid_fkey FOREIGN KEY (inventory_uuid) " <>
                 "REFERENCES public.#{@documents}(uuid) ON DELETE CASCADE"

      refute create =~ "created_by_uuid_fkey"
      refute create =~ "applied_by_uuid_fkey"
    end

    test "the widths come from the schema's column_widths/0" do
      assert InventoryAIRun.column_widths() == %{place_label: 200, status: 20, model: 255}
    end

    test "one index over the document, one partial unique index over running runs" do
      [_create, index, running] = v3_statements()

      assert index ==
               "CREATE INDEX IF NOT EXISTS #{@runs}_inventory_uuid_index ON public.#{@runs} " <>
                 "USING btree (inventory_uuid)"

      assert running ==
               "CREATE UNIQUE INDEX IF NOT EXISTS #{@runs}_running_index ON public.#{@runs} " <>
                 "USING btree (inventory_uuid) WHERE status = 'running'"
    end

    test "the prefix reaches every V3 object" do
      for statement <- v3_statements("warehouse_alt") do
        assert statement =~ "warehouse_alt.#{@runs}"
      end

      [create | _] = v3_statements("warehouse_alt")
      assert create =~ "REFERENCES warehouse_alt.#{@documents}(uuid)"
      assert create =~ "warehouse_alt.uuid_generate_v7()"
    end

    test "up_statements for target 2 stays the published V2 (no V3 object leaks in)" do
      refute "public" |> Migrations.up_statements(2) |> Enum.join("\n") =~ @runs
    end

    test "down to 2 only re-stamps the marker: the table and its rows stay" do
      assert Migrations.down_statements("public", 2) ==
               ["COMMENT ON TABLE public.phoenix_kit_warehouse_stock IS 'pkw_schema:2'"]
    end
  end

  describe "migrating an existing database" do
    setup do
      # A host at pkw_schema:2 has no runs table yet.
      Repo.query!("DROP TABLE IF EXISTS #{@runs}")
      Repo.query!("COMMENT ON TABLE phoenix_kit_warehouse_stock IS 'pkw_schema:2'")
      :ok
    end

    test "up creates the table and stamps pkw_schema:3; a second up is a no-op" do
      assert Migrations.migrated_version_runtime(prefix: "public") == 2
      refute table_exists?()

      run_migration(UpToV3)

      assert Migrations.migrated_version_runtime(prefix: "public") == 3
      assert table_exists?()

      run_migration(UpToV3)
      assert Migrations.migrated_version_runtime(prefix: "public") == 3
    end

    test "a document has at most one running run, any number of finished ones" do
      run_migration(UpToV3)
      doc_uuid = insert_document!()

      assert {:ok, _} = insert_run(doc_uuid, "running")

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               Repo.transaction(fn ->
                 case insert_run(doc_uuid, "running") do
                   {:error, e} -> Repo.rollback(e)
                   ok -> ok
                 end
               end)

      for status <- ~w(proposed error discarded applied proposed) do
        assert {:ok, _} = insert_run(doc_uuid, status)
      end

      assert {:ok, _} = insert_run(insert_document!(), "running")
    end

    test "deleting the document row deletes its runs (ON DELETE CASCADE)" do
      run_migration(UpToV3)
      doc_uuid = insert_document!()
      {:ok, _} = insert_run(doc_uuid, "proposed")

      Repo.query!("DELETE FROM #{@documents} WHERE uuid = $1", [Ecto.UUID.dump!(doc_uuid)])

      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM #{@runs}")
    end

    test "a real down to 2 keeps the table and every run in it" do
      run_migration(UpToV3)
      doc_uuid = insert_document!()
      {:ok, _} = insert_run(doc_uuid, "proposed")

      run_migration(DownToV2)

      assert Migrations.migrated_version_runtime(prefix: "public") == 2
      assert table_exists?()
      assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM #{@runs}")
    end
  end

  defp table_exists? do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = $1 AND table_schema = 'public')",
        [@runs]
      )

    exists?
  end

  defp insert_document! do
    uuid = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO #{@documents} (uuid, location_uuid) VALUES ($1, $2)",
      [Ecto.UUID.dump!(uuid), Ecto.UUID.dump!(Ecto.UUID.generate())]
    )

    uuid
  end

  defp insert_run(doc_uuid, status) do
    Repo.query(
      "INSERT INTO #{@runs} (inventory_uuid, location_uuid, status) VALUES ($1, $2, $3)",
      [Ecto.UUID.dump!(doc_uuid), Ecto.UUID.dump!(Ecto.UUID.generate()), status]
    )
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
