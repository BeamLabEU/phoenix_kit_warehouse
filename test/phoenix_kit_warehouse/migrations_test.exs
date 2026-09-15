defmodule PhoenixKitWarehouse.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.Migrations

  @moduledoc """
  Pins the ownership design for `phoenix_kit_warehouse`: this package owns
  all 8 `phoenix_kit_warehouse_*` tables' FUTURE shape through its module
  migration chain, while core's V140/V144 baseline still creates every table
  on every install, and the chain's V1 merely ADOPTS that shape (stamps the
  `pkw_schema:` marker on the anchor table, `phoenix_kit_warehouse_stock`,
  changes no shape).

  Every test here is a pure data/string assertion over
  `up_statements/2`/`down_statements/2`/`up/1`/`down/1`-as-source-text and
  core's static `PhoenixKit.Migrations.ExpectedSchema.objects/1` manifest —
  none of them touch a database.
  """

  @warehouse_tables ~w(
    phoenix_kit_warehouse_stock
    phoenix_kit_warehouse_inventory_documents
    phoenix_kit_warehouse_internal_orders
    phoenix_kit_warehouse_supplier_orders
    phoenix_kit_warehouse_goods_receipts
    phoenix_kit_warehouse_goods_issues
    phoenix_kit_warehouse_transfers
    phoenix_kit_warehouse_min_stock
  )

  test "PhoenixKitWarehouse declares the module-owned migration chain" do
    # Assert the VALUE, not `function_exported?/3` — `use PhoenixKit.Module`
    # injects an overridable default `migration_module/0`, so exportedness
    # says nothing about whether this module declares one.
    assert Code.ensure_loaded?(PhoenixKitWarehouse)

    assert PhoenixKitWarehouse.migration_module() == Migrations,
           """
           PhoenixKitWarehouse no longer declares its migration chain \
           (migration_module/0 returned #{inspect(PhoenixKitWarehouse.migration_module())}).

           The chain is how phoenix_kit_warehouse's future shape is versioned
           (pkw_schema marker) and how `mix phoenix_kit.update` migrates hosts.
           """
  end

  describe "the coordinator implements the protocol" do
    alias PhoenixKit.Migrations.Postgres.Helpers

    test "current_version/0 and version_table/0" do
      assert Migrations.current_version() == 1
      assert Migrations.version_table() == "phoenix_kit_warehouse_stock"
    end

    test "initial_version/0" do
      assert Migrations.initial_version() == 1
    end

    # `mix phoenix_kit_hello_world.audit_migrations` (the canonical auditor
    # for this protocol) refuses to drive a coordinator missing any of these
    # five — `mix phoenix_kit.update` itself only calls
    # `migrated_version_runtime/1` + `current_version/0`, but `up/1` needs
    # `migrated_version/1` to re-read the version it is about to change.
    test "exports the full five-function protocol, plus version_table/0 and initial_version/0" do
      for {fun, arity} <- [
            {:current_version, 0},
            {:up, 1},
            {:down, 1},
            {:migrated_version, 1},
            {:migrated_version_runtime, 1},
            {:version_table, 0},
            {:initial_version, 0}
          ] do
        assert function_exported?(Migrations, fun, arity),
               "#{inspect(Migrations)} does not export #{fun}/#{arity}"
      end
    end

    # The marker decides whether any LATER version ever runs: core's
    # `classify/2` reads it and answers `:up_to_date` for every version at or
    # below it. Stamping a version this chain does not have therefore skips
    # V2 and everything after it, silently and permanently.
    test "refuses to stamp a version this chain does not have" do
      too_high = Migrations.current_version() + 1

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.up_statements("public", too_high)
      end

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.down_statements("public", too_high)
      end

      # The ceiling itself stays reachable, or the guard would just break
      # the chain instead of bounding it.
      assert Migrations.up_statements("public", Migrations.current_version()) != []
    end

    # This chain interpolates the prefix into every object it creates, and
    # Postgres TRUNCATES an identifier past 63 bytes silently rather than
    # rejecting it — so a prefix core would refuse yields object names that
    # differ from core's while every command still exits 0, breaking the
    # contract adoption rests on. The rules are therefore core's, and this
    # test compares against core rather than restating them.
    test "every public builder that emits SQL validates its own prefix" do
      for fun <- [:up_statements, :down_statements] do
        assert_raise ArgumentError, fn -> apply(Migrations, fun, ["EVIL\";DROP"]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [String.duplicate("a", 30)]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [123]) end
      end
    end

    test "the prefix rules are core's, case and length included" do
      for prefix <- [
            "public",
            "warehouse_alt",
            "Warehouse",
            "9leading_digit",
            "has-dash",
            String.duplicate("a", 20),
            String.duplicate("a", 21),
            String.duplicate("a", 30)
          ] do
        core_accepts =
          try do
            Helpers.validate_prefix!(prefix)
            true
          rescue
            ArgumentError -> false
          end

        ours_accepts =
          try do
            Migrations.up_statements(prefix)
            true
          rescue
            ArgumentError -> false
          end

        assert ours_accepts == core_accepts,
               "prefix #{inspect(prefix)}: core #{if core_accepts, do: "accepts", else: "rejects"}, " <>
                 "this chain #{if ours_accepts, do: "accepts", else: "rejects"} — the two must agree, " <>
                 "or the object names this chain creates stop matching core's"
      end
    end

    test "rejects a prefix that cannot be safely interpolated into DDL" do
      for bad <- ["public.\"; DROP TABLE x; --", "1st", "a-b", ""] do
        assert_raise ArgumentError, fn -> Migrations.up_statements(bad) end
        assert_raise ArgumentError, fn -> Migrations.down_statements(bad, 0) end
      end
    end
  end

  describe "the chain's per-version statement content is pinned (drift guard)" do
    # V1 is a PUBLISHED version once this ships. A host that has already run
    # it will never run it again, so editing its content does not "fix" that
    # host — it silently splits fresh installs from existing ones. Pinning
    # the exact normalised text makes that split a deliberate, visible diff
    # instead of an accidental one buried in a refactor.
    defp normalised(statements),
      do: Enum.map(statements, &(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))

    test "V1's published statements are frozen" do
      v1 = Migrations.up_statements("public", 1) |> normalised()

      assert v1 == [
               "CREATE SEQUENCE IF NOT EXISTS public.phoenix_kit_warehouse_inventory_documents_number_seq AS bigint INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1",
               "CREATE SEQUENCE IF NOT EXISTS public.phoenix_kit_warehouse_internal_orders_number_seq AS bigint INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1",
               "CREATE SEQUENCE IF NOT EXISTS public.phoenix_kit_warehouse_supplier_orders_number_seq AS bigint INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1",
               "CREATE SEQUENCE IF NOT EXISTS public.phoenix_kit_warehouse_goods_receipts_number_seq AS bigint INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1",
               "CREATE SEQUENCE IF NOT EXISTS public.phoenix_kit_warehouse_goods_issues_number_seq AS bigint INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1",
               "CREATE SEQUENCE IF NOT EXISTS public.phoenix_kit_warehouse_transfers_number_seq AS bigint INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_warehouse_stock ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"item_uuid\" uuid NOT NULL, \"location_uuid\" uuid NOT NULL, \"quantity\" numeric DEFAULT 0 NOT NULL, \"unit_value\" numeric, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_warehouse_inventory_documents ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"number\" bigint DEFAULT nextval('public.phoenix_kit_warehouse_inventory_documents_number_seq'::regclass) NOT NULL, \"status\" character varying(20) DEFAULT 'draft'::character varying NOT NULL, \"track_value\" boolean DEFAULT false NOT NULL, \"location_uuid\" uuid NOT NULL, \"storage_folder_uuid\" uuid, \"note\" text, \"lines\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"created_by_uuid\" uuid, \"performed_by_uuid\" uuid, \"posted_at\" timestamp with time zone, \"deleted_at\" timestamp with time zone, \"deleted_by_uuid\" uuid, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_warehouse_internal_orders ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"number\" bigint DEFAULT nextval('public.phoenix_kit_warehouse_internal_orders_number_seq'::regclass) NOT NULL, \"status\" character varying(20) DEFAULT 'draft'::character varying NOT NULL, \"location_uuid\" uuid NOT NULL, \"note\" text, \"lines\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"source_refs\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"created_by_uuid\" uuid, \"performed_by_uuid\" uuid, \"posted_at\" timestamp with time zone, \"deleted_at\" timestamp with time zone, \"deleted_by_uuid\" uuid, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_warehouse_supplier_orders ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"number\" bigint DEFAULT nextval('public.phoenix_kit_warehouse_supplier_orders_number_seq'::regclass) NOT NULL, \"status\" character varying(20) DEFAULT 'draft'::character varying NOT NULL, \"supplier_uuid\" uuid, \"internal_order_uuid\" uuid, \"location_uuid\" uuid NOT NULL, \"note\" text, \"storage_folder_uuid\" uuid, \"lines\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"source_refs\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"created_by_uuid\" uuid, \"performed_by_uuid\" uuid, \"posted_at\" timestamp with time zone, \"deleted_at\" timestamp with time zone, \"deleted_by_uuid\" uuid, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_warehouse_goods_receipts ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"number\" bigint DEFAULT nextval('public.phoenix_kit_warehouse_goods_receipts_number_seq'::regclass) NOT NULL, \"status\" character varying(20) DEFAULT 'draft'::character varying NOT NULL, \"supplier_order_uuid\" uuid, \"supplier_uuid\" uuid, \"location_uuid\" uuid NOT NULL, \"note\" text, \"storage_folder_uuid\" uuid, \"lines\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"source_refs\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"created_by_uuid\" uuid, \"performed_by_uuid\" uuid, \"posted_at\" timestamp with time zone, \"deleted_at\" timestamp with time zone, \"deleted_by_uuid\" uuid, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_warehouse_goods_issues ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"number\" bigint DEFAULT nextval('public.phoenix_kit_warehouse_goods_issues_number_seq'::regclass) NOT NULL, \"status\" character varying(20) DEFAULT 'draft'::character varying NOT NULL, \"internal_order_uuid\" uuid, \"location_uuid\" uuid NOT NULL, \"note\" text, \"storage_folder_uuid\" uuid, \"lines\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"source_refs\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"created_by_uuid\" uuid, \"performed_by_uuid\" uuid, \"posted_at\" timestamp with time zone, \"deleted_at\" timestamp with time zone, \"deleted_by_uuid\" uuid, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_warehouse_transfers ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"number\" bigint DEFAULT nextval('public.phoenix_kit_warehouse_transfers_number_seq'::regclass) NOT NULL, \"status\" character varying(20) DEFAULT 'draft'::character varying NOT NULL, \"source_location_uuid\" uuid, \"destination_location_uuid\" uuid, \"note\" text, \"storage_folder_uuid\" uuid, \"lines\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"source_refs\" jsonb DEFAULT '[]'::jsonb NOT NULL, \"created_by_uuid\" uuid, \"performed_by_uuid\" uuid, \"shipped_at\" timestamp with time zone, \"received_at\" timestamp with time zone, \"cancelled_at\" timestamp with time zone, \"deleted_at\" timestamp with time zone, \"deleted_by_uuid\" uuid, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_warehouse_min_stock ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"item_uuid\" uuid NOT NULL, \"min_quantity\" numeric DEFAULT 0 NOT NULL, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_stock_pkey' AND t.relname = 'phoenix_kit_warehouse_stock' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_stock ADD CONSTRAINT phoenix_kit_warehouse_stock_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_inventory_documents_pkey' AND t.relname = 'phoenix_kit_warehouse_inventory_documents' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_inventory_documents ADD CONSTRAINT phoenix_kit_warehouse_inventory_documents_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_internal_orders_pkey' AND t.relname = 'phoenix_kit_warehouse_internal_orders' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_internal_orders ADD CONSTRAINT phoenix_kit_warehouse_internal_orders_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_supplier_orders_pkey' AND t.relname = 'phoenix_kit_warehouse_supplier_orders' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_supplier_orders ADD CONSTRAINT phoenix_kit_warehouse_supplier_orders_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_goods_receipts_pkey' AND t.relname = 'phoenix_kit_warehouse_goods_receipts' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_goods_receipts ADD CONSTRAINT phoenix_kit_warehouse_goods_receipts_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_goods_issues_pkey' AND t.relname = 'phoenix_kit_warehouse_goods_issues' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_goods_issues ADD CONSTRAINT phoenix_kit_warehouse_goods_issues_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_transfers_pkey' AND t.relname = 'phoenix_kit_warehouse_transfers' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_transfers ADD CONSTRAINT phoenix_kit_warehouse_transfers_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_min_stock_pkey' AND t.relname = 'phoenix_kit_warehouse_min_stock' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_min_stock ADD CONSTRAINT phoenix_kit_warehouse_min_stock_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_stock_quantity_non_negative' AND t.relname = 'phoenix_kit_warehouse_stock' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_stock ADD CONSTRAINT phoenix_kit_warehouse_stock_quantity_non_negative CHECK (quantity >= 0); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_min_stock_min_quantity_non_negative' AND t.relname = 'phoenix_kit_warehouse_min_stock' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_min_stock ADD CONSTRAINT phoenix_kit_warehouse_min_stock_min_quantity_non_negative CHECK (min_quantity >= 0); END IF; END $$",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_stock_item_location_index ON public.phoenix_kit_warehouse_stock USING btree (item_uuid, location_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_stock_location_uuid_index ON public.phoenix_kit_warehouse_stock USING btree (location_uuid)",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_inventory_documents_number_index ON public.phoenix_kit_warehouse_inventory_documents USING btree (number)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_inventory_documents_status_index ON public.phoenix_kit_warehouse_inventory_documents USING btree (status)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_inventory_documents_inserted_at_index ON public.phoenix_kit_warehouse_inventory_documents USING btree (inserted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_inventory_documents_deleted_at_index ON public.phoenix_kit_warehouse_inventory_documents USING btree (deleted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_inventory_documents_location_uuid_index ON public.phoenix_kit_warehouse_inventory_documents USING btree (location_uuid)",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_number_index ON public.phoenix_kit_warehouse_internal_orders USING btree (number)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_status_index ON public.phoenix_kit_warehouse_internal_orders USING btree (status)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_inserted_at_index ON public.phoenix_kit_warehouse_internal_orders USING btree (inserted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_deleted_at_index ON public.phoenix_kit_warehouse_internal_orders USING btree (deleted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_location_uuid_index ON public.phoenix_kit_warehouse_internal_orders USING btree (location_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_source_refs_index ON public.phoenix_kit_warehouse_internal_orders USING gin (source_refs)",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_number_index ON public.phoenix_kit_warehouse_supplier_orders USING btree (number)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_status_index ON public.phoenix_kit_warehouse_supplier_orders USING btree (status)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_inserted_at_index ON public.phoenix_kit_warehouse_supplier_orders USING btree (inserted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_deleted_at_index ON public.phoenix_kit_warehouse_supplier_orders USING btree (deleted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_location_uuid_index ON public.phoenix_kit_warehouse_supplier_orders USING btree (location_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_supplier_uuid_index ON public.phoenix_kit_warehouse_supplier_orders USING btree (supplier_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_internal_order_uuid_index ON public.phoenix_kit_warehouse_supplier_orders USING btree (internal_order_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_source_refs_index ON public.phoenix_kit_warehouse_supplier_orders USING gin (source_refs)",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_number_index ON public.phoenix_kit_warehouse_goods_receipts USING btree (number)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_status_index ON public.phoenix_kit_warehouse_goods_receipts USING btree (status)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_inserted_at_index ON public.phoenix_kit_warehouse_goods_receipts USING btree (inserted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_deleted_at_index ON public.phoenix_kit_warehouse_goods_receipts USING btree (deleted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_location_uuid_index ON public.phoenix_kit_warehouse_goods_receipts USING btree (location_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_index ON public.phoenix_kit_warehouse_goods_receipts USING btree (supplier_order_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_source_refs_index ON public.phoenix_kit_warehouse_goods_receipts USING gin (source_refs)",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_number_index ON public.phoenix_kit_warehouse_goods_issues USING btree (number)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_status_index ON public.phoenix_kit_warehouse_goods_issues USING btree (status)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_inserted_at_index ON public.phoenix_kit_warehouse_goods_issues USING btree (inserted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_deleted_at_index ON public.phoenix_kit_warehouse_goods_issues USING btree (deleted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_location_uuid_index ON public.phoenix_kit_warehouse_goods_issues USING btree (location_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_internal_order_uuid_index ON public.phoenix_kit_warehouse_goods_issues USING btree (internal_order_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_source_refs_index ON public.phoenix_kit_warehouse_goods_issues USING gin (source_refs)",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_number_index ON public.phoenix_kit_warehouse_transfers USING btree (number)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_status_index ON public.phoenix_kit_warehouse_transfers USING btree (status)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_inserted_at_index ON public.phoenix_kit_warehouse_transfers USING btree (inserted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_deleted_at_index ON public.phoenix_kit_warehouse_transfers USING btree (deleted_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_source_location_uuid_index ON public.phoenix_kit_warehouse_transfers USING btree (source_location_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_destination_location_uuid_index ON public.phoenix_kit_warehouse_transfers USING btree (destination_location_uuid)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_shipped_at_index ON public.phoenix_kit_warehouse_transfers USING btree (shipped_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_received_at_index ON public.phoenix_kit_warehouse_transfers USING btree (received_at)",
               "CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_source_refs_index ON public.phoenix_kit_warehouse_transfers USING gin (source_refs)",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_min_stock_item_uuid_index ON public.phoenix_kit_warehouse_min_stock USING btree (item_uuid)",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_inventory_document_performed_by_uuid_fkey' AND t.relname = 'phoenix_kit_warehouse_inventory_documents' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_inventory_documents ADD CONSTRAINT phoenix_kit_warehouse_inventory_document_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_internal_orders_performed_by_uuid_fkey' AND t.relname = 'phoenix_kit_warehouse_internal_orders' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_internal_orders ADD CONSTRAINT phoenix_kit_warehouse_internal_orders_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_supplier_orders_internal_order_uuid_fkey' AND t.relname = 'phoenix_kit_warehouse_supplier_orders' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_supplier_orders ADD CONSTRAINT phoenix_kit_warehouse_supplier_orders_internal_order_uuid_fkey FOREIGN KEY (internal_order_uuid) REFERENCES public.phoenix_kit_warehouse_internal_orders(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_supplier_orders_performed_by_uuid_fkey' AND t.relname = 'phoenix_kit_warehouse_supplier_orders' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_supplier_orders ADD CONSTRAINT phoenix_kit_warehouse_supplier_orders_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_fkey' AND t.relname = 'phoenix_kit_warehouse_goods_receipts' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_goods_receipts ADD CONSTRAINT phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_fkey FOREIGN KEY (supplier_order_uuid) REFERENCES public.phoenix_kit_warehouse_supplier_orders(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_goods_receipts_performed_by_uuid_fkey' AND t.relname = 'phoenix_kit_warehouse_goods_receipts' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_goods_receipts ADD CONSTRAINT phoenix_kit_warehouse_goods_receipts_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_goods_issues_internal_order_uuid_fkey' AND t.relname = 'phoenix_kit_warehouse_goods_issues' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_goods_issues ADD CONSTRAINT phoenix_kit_warehouse_goods_issues_internal_order_uuid_fkey FOREIGN KEY (internal_order_uuid) REFERENCES public.phoenix_kit_warehouse_internal_orders(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_goods_issues_performed_by_uuid_fkey' AND t.relname = 'phoenix_kit_warehouse_goods_issues' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_goods_issues ADD CONSTRAINT phoenix_kit_warehouse_goods_issues_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_warehouse_transfers_performed_by_uuid_fkey' AND t.relname = 'phoenix_kit_warehouse_transfers' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_warehouse_transfers ADD CONSTRAINT phoenix_kit_warehouse_transfers_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL; END IF; END $$",
               "COMMENT ON TABLE public.phoenix_kit_warehouse_stock IS 'pkw_schema:1'"
             ]
    end
  end

  describe "the chain DDL adopts core's V140/V144 shape" do
    test "V1 uses core's exact object names (shape-identical adoption)" do
      statements = Enum.join(Migrations.up_statements(), "\n")

      for name <- [
            "phoenix_kit_warehouse_stock_pkey",
            "phoenix_kit_warehouse_inventory_documents_pkey",
            "phoenix_kit_warehouse_internal_orders_pkey",
            "phoenix_kit_warehouse_supplier_orders_pkey",
            "phoenix_kit_warehouse_goods_receipts_pkey",
            "phoenix_kit_warehouse_goods_issues_pkey",
            "phoenix_kit_warehouse_transfers_pkey",
            "phoenix_kit_warehouse_min_stock_pkey",
            "phoenix_kit_warehouse_stock_quantity_non_negative",
            "phoenix_kit_warehouse_min_stock_min_quantity_non_negative",
            "phoenix_kit_warehouse_inventory_document_performed_by_uuid_fkey",
            "phoenix_kit_warehouse_internal_orders_performed_by_uuid_fkey",
            "phoenix_kit_warehouse_supplier_orders_internal_order_uuid_fkey",
            "phoenix_kit_warehouse_supplier_orders_performed_by_uuid_fkey",
            "phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_fkey",
            "phoenix_kit_warehouse_goods_receipts_performed_by_uuid_fkey",
            "phoenix_kit_warehouse_goods_issues_internal_order_uuid_fkey",
            "phoenix_kit_warehouse_goods_issues_performed_by_uuid_fkey",
            "phoenix_kit_warehouse_transfers_performed_by_uuid_fkey"
          ] do
        assert statements =~ name,
               "V1 no longer creates #{name} — it must stay shape-identical to core's V140/V144"
      end
    end

    test "up stamps the version marker, and stamps it last" do
      statements = Migrations.up_statements()

      assert List.last(statements) ==
               "COMMENT ON TABLE public.phoenix_kit_warehouse_stock IS 'pkw_schema:1'",
             "the marker must be stamped after the DDL it certifies, not before"
    end

    test "applying up to version 0 is not an operation" do
      assert Migrations.up_statements("public", 0) == []
      assert Migrations.up_statements("warehouse_alt", 0) == []
    end

    test "every up statement is guarded (IF NOT EXISTS / DO-block idempotence)" do
      # V1 runs on installs where core's V140/V144 already created everything,
      # so every statement must be a no-op against an object that is already
      # there.
      ddl = Enum.reject(Migrations.up_statements(), &String.starts_with?(&1, "COMMENT"))

      for stmt <- ddl do
        assert stmt =~ "IF NOT EXISTS",
               "statement is not idempotent against a core-created table:\n#{stmt}"
      end
    end
  end

  describe "the chain can never destroy any of the 8 tables" do
    alias PhoenixKit.Migrations.ExpectedSchema

    # Compared against the WHOLE expected content, not scanned for a
    # forbidden substring — a substring check only sees statements the
    # builder produced, so anything appended past it (a literal
    # `execute("DROP TABLE ...")` in `up/1`) would be invisible to it. That
    # path is closed by the source-text test below, which checks what is
    # executed rather than what is built.
    test "down/1 emits exactly the marker bookkeeping, in every target and prefix" do
      assert Migrations.down_statements("public", 0) ==
               ["COMMENT ON TABLE public.phoenix_kit_warehouse_stock IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               ["COMMENT ON TABLE public.phoenix_kit_warehouse_stock IS 'pkw_schema:1'"]

      assert Migrations.down_statements("warehouse_alt", 0) ==
               ["COMMENT ON TABLE warehouse_alt.phoenix_kit_warehouse_stock IS NULL"]

      assert Migrations.down_statements("warehouse_alt", 1) ==
               ["COMMENT ON TABLE warehouse_alt.phoenix_kit_warehouse_stock IS 'pkw_schema:1'"]
    end

    # For `up/1` the expected content is the full set of OPERATIONS rather
    # than the full SQL text. An operation is `{verb, object}`, immune to
    # reformatting and still failing on any statement added, removed or
    # retargeted — including a destructive one, which cannot enter this set
    # without changing it.
    @up_operations [
      {"CREATE SEQUENCE", "phoenix_kit_warehouse_inventory_documents_number_seq"},
      {"CREATE SEQUENCE", "phoenix_kit_warehouse_internal_orders_number_seq"},
      {"CREATE SEQUENCE", "phoenix_kit_warehouse_supplier_orders_number_seq"},
      {"CREATE SEQUENCE", "phoenix_kit_warehouse_goods_receipts_number_seq"},
      {"CREATE SEQUENCE", "phoenix_kit_warehouse_goods_issues_number_seq"},
      {"CREATE SEQUENCE", "phoenix_kit_warehouse_transfers_number_seq"},
      {"CREATE TABLE", "phoenix_kit_warehouse_stock"},
      {"CREATE TABLE", "phoenix_kit_warehouse_inventory_documents"},
      {"CREATE TABLE", "phoenix_kit_warehouse_internal_orders"},
      {"CREATE TABLE", "phoenix_kit_warehouse_supplier_orders"},
      {"CREATE TABLE", "phoenix_kit_warehouse_goods_receipts"},
      {"CREATE TABLE", "phoenix_kit_warehouse_goods_issues"},
      {"CREATE TABLE", "phoenix_kit_warehouse_transfers"},
      {"CREATE TABLE", "phoenix_kit_warehouse_min_stock"},
      {"DO", "phoenix_kit_warehouse_stock_pkey"},
      {"DO", "phoenix_kit_warehouse_inventory_documents_pkey"},
      {"DO", "phoenix_kit_warehouse_internal_orders_pkey"},
      {"DO", "phoenix_kit_warehouse_supplier_orders_pkey"},
      {"DO", "phoenix_kit_warehouse_goods_receipts_pkey"},
      {"DO", "phoenix_kit_warehouse_goods_issues_pkey"},
      {"DO", "phoenix_kit_warehouse_transfers_pkey"},
      {"DO", "phoenix_kit_warehouse_min_stock_pkey"},
      {"DO", "phoenix_kit_warehouse_stock_quantity_non_negative"},
      {"DO", "phoenix_kit_warehouse_min_stock_min_quantity_non_negative"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_warehouse_stock_item_location_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_stock_location_uuid_index"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_warehouse_inventory_documents_number_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_inventory_documents_status_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_inventory_documents_inserted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_inventory_documents_deleted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_inventory_documents_location_uuid_index"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_warehouse_internal_orders_number_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_internal_orders_status_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_internal_orders_inserted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_internal_orders_deleted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_internal_orders_location_uuid_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_internal_orders_source_refs_index"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_warehouse_supplier_orders_number_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_supplier_orders_status_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_supplier_orders_inserted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_supplier_orders_deleted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_supplier_orders_location_uuid_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_supplier_orders_supplier_uuid_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_supplier_orders_internal_order_uuid_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_supplier_orders_source_refs_index"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_warehouse_goods_receipts_number_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_receipts_status_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_receipts_inserted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_receipts_deleted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_receipts_location_uuid_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_receipts_source_refs_index"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_warehouse_goods_issues_number_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_issues_status_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_issues_inserted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_issues_deleted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_issues_location_uuid_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_issues_internal_order_uuid_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_goods_issues_source_refs_index"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_warehouse_transfers_number_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_transfers_status_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_transfers_inserted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_transfers_deleted_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_transfers_source_location_uuid_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_transfers_destination_location_uuid_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_transfers_shipped_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_transfers_received_at_index"},
      {"CREATE INDEX", "phoenix_kit_warehouse_transfers_source_refs_index"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_warehouse_min_stock_item_uuid_index"},
      {"DO", "phoenix_kit_warehouse_inventory_document_performed_by_uuid_fkey"},
      {"DO", "phoenix_kit_warehouse_internal_orders_performed_by_uuid_fkey"},
      {"DO", "phoenix_kit_warehouse_supplier_orders_internal_order_uuid_fkey"},
      {"DO", "phoenix_kit_warehouse_supplier_orders_performed_by_uuid_fkey"},
      {"DO", "phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_fkey"},
      {"DO", "phoenix_kit_warehouse_goods_receipts_performed_by_uuid_fkey"},
      {"DO", "phoenix_kit_warehouse_goods_issues_internal_order_uuid_fkey"},
      {"DO", "phoenix_kit_warehouse_goods_issues_performed_by_uuid_fkey"},
      {"DO", "phoenix_kit_warehouse_transfers_performed_by_uuid_fkey"},
      {"COMMENT ON TABLE", "phoenix_kit_warehouse_stock"}
    ]

    test "up_statements/2 emits exactly these operations and no others" do
      for prefix <- ["public", "warehouse_alt"] do
        actual = Enum.map(Migrations.up_statements(prefix), &operation/1)

        assert Enum.sort(actual) == Enum.sort(@up_operations),
               """
               up_statements(#{inspect(prefix)}) does not emit the expected set of
               operations.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(@up_operations))}
               missing:    #{inspect(Enum.sort(@up_operations) -- Enum.sort(actual))}

               Every statement this chain emits runs against a core-created
               table. Adding one is a chain version (V2+), not something to
               slip past this list.
               """
      end
    end

    # Core's manifest for the 8 warehouse tables' index/constraint objects,
    # not a hand-typed list — a hand-typed list is maintained by the same hand
    # that adds a statement, so it catches a slip but never a deliberate one;
    # the manifest is written on core's side, so this fails both when the
    # chain emits an object core does not declare AND when core declares an
    # object the chain stopped adopting. This is also the test that makes the
    # singular-vs-plural inventory_documents FK name unmissable if it is ever
    # typo'd back to the plural form.
    test "up_statements/2 emits exactly the index/constraint operations core's manifest declares for the 8 warehouse tables" do
      for prefix <- ["public", "warehouse_alt"] do
        actual =
          Migrations.up_statements(prefix, 1)
          |> Enum.reject(
            &(String.starts_with?(&1, "CREATE TABLE") or
                String.starts_with?(&1, "CREATE SEQUENCE") or
                String.starts_with?(&1, "COMMENT ON TABLE"))
          )
          |> Enum.map(&operation/1)

        expected = expected_index_constraint_operations()

        assert Enum.sort(actual) == Enum.sort(expected),
               """
               up_statements(#{inspect(prefix)}, 1) does not emit the operation set
               core's ExpectedSchema declares for the 8 warehouse tables' indexes and
               constraints.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(expected))}
               missing:    #{inspect(Enum.sort(expected) -- Enum.sort(actual))}
               """
      end
    end

    defp expected_index_constraint_operations do
      warehouse_tables = @warehouse_tables

      ExpectedSchema.objects("public")
      |> Enum.filter(fn object ->
        case object.check do
          {_kind, %{table: table}} ->
            table in warehouse_tables and object.class in [:index, :constraint] and
              Map.get(object, :presence) == :required

          _ ->
            false
        end
      end)
      |> Enum.map(fn object ->
        name = object.check |> elem(1) |> Map.fetch!(:name)

        case object.class do
          :constraint -> {"DO", name}
          :index -> {index_verb(object.create), name}
        end
      end)
    end

    defp index_verb(create) do
      if String.starts_with?(create, "CREATE UNIQUE INDEX"),
        do: "CREATE UNIQUE INDEX",
        else: "CREATE INDEX"
    end

    # `ON DELETE SET NULL` is part of the foreign key's DEFINITION — the word
    # DELETE there describes what Postgres does to a child row when the
    # PARENT is deleted, and adoption reproducing core's FK means
    # reproducing core's referential action verbatim. Scanning the raw text
    # for the token would flag it, so the clause is removed before the scan.
    defp strip_referential_actions(statement) do
      String.replace(
        statement,
        ~r/ON\s+(DELETE|UPDATE)\s+(CASCADE|RESTRICT|NO\s+ACTION|SET\s+NULL|SET\s+DEFAULT)/i,
        "ON <referential action>"
      )
    end

    test "the referential-action strip does not blind the destructive scan" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      mutant =
        "ALTER TABLE public.phoenix_kit_warehouse_goods_issues ADD CONSTRAINT x FOREIGN KEY (internal_order_uuid) " <>
          "REFERENCES public.phoenix_kit_warehouse_internal_orders(uuid) ON DELETE SET NULL; DROP TABLE public.phoenix_kit_warehouse_goods_issues"

      assert strip_referential_actions(mutant) =~ forbidden

      assert strip_referential_actions("DELETE FROM public.phoenix_kit_warehouse_stock") =~
               forbidden

      assert strip_referential_actions("TRUNCATE public.phoenix_kit_warehouse_stock") =~ forbidden
    end

    test "no statement anywhere in the data-level chain can drop a table, truncate, or delete rows" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      for prefix <- ["public", "warehouse_alt"] do
        for stmt <- Migrations.up_statements(prefix) do
          refute strip_referential_actions(stmt) =~ forbidden,
                 "up_statements(#{inspect(prefix)}) contains: #{stmt}"
        end

        for target <- [0, 1] do
          for stmt <- Migrations.down_statements(prefix, target) do
            refute strip_referential_actions(stmt) =~ forbidden,
                   "down_statements(#{inspect(prefix)}, #{target}) contains: #{stmt}"
          end
        end
      end
    end

    # `{verb, object}` for one statement. The DO block is identified by the
    # constraint it adds, since its verb says nothing about its target.
    defp operation(statement) do
      normalized = statement |> String.replace(~r/\s+/, " ") |> String.trim()

      if String.starts_with?(normalized, "DO ") do
        [_, constraint] = Regex.run(~r/ADD CONSTRAINT (\w+)/, normalized)
        {"DO", constraint}
      else
        [_, verb, object] =
          Regex.run(
            ~r/^(CREATE UNIQUE INDEX|CREATE INDEX|CREATE SEQUENCE|CREATE TABLE|COMMENT ON TABLE|DROP TABLE|DROP INDEX|TRUNCATE|DELETE FROM|ALTER TABLE)(?: IF NOT EXISTS)? (?:\w+\.)?(\w+)/,
            normalized
          )

        {verb, object}
      end
    end
  end

  describe "what reaches the database is what the tests above inspect" do
    # The tests above read `up_statements/2` and `down_statements/2`. The
    # database gets `up/1` and `down/1`. Nothing connected the two, so a
    # literal `execute("DROP TABLE ...")` written straight into `up/1` would
    # have passed every one of them — the guard was watching the data while
    # the function did the work.
    @source "lib/phoenix_kit_warehouse/migrations.ex"

    test "neither direction executes SQL of its own" do
      source = File.read!(@source)

      refute source =~ ~r/execute\(/,
             """
             #{@source} calls execute/1 with an argument of its own.

             Every statement this chain runs must come from up_statements/2 or
             down_statements/2, because those are what the tests above compare
             against their expected content. A statement executed directly is
             invisible to all of them.
             """

      assert length(Regex.scan(~r/&execute\/1/, source)) == 2,
             "expected exactly two `&execute/1` references — one per direction — " <>
               "in #{@source}"
    end

    test "each direction executes its own builder" do
      source = File.read!(@source)

      assert source =~ ~r/up_statements\(opts\.version\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "up/1 no longer pipes up_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what the up_statements-based tests above check"

      assert source =~ ~r/down_statements\(opts\.version\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "down/1 no longer pipes down_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what `down/1 emits exactly the marker " <>
               "bookkeeping` checks"
    end

    # Scoped to the two functions' own bodies, not the whole file — the
    # moduledoc legitimately discusses "never drops a table" in prose, which
    # a whole-file, case-insensitive scan would flag as a false positive on
    # the English word rather than a SQL token.
    test "up/1 and down/1 themselves contain no DROP/TRUNCATE/DELETE token" do
      source = File.read!(@source)

      [up_body] = Regex.run(~r/def up\(.*?\n  end\n/s, source)
      [down_body] = Regex.run(~r/def down\(.*?\n  end\n/s, source)

      for {name, body} <- [{"up/1", up_body}, {"down/1", down_body}] do
        refute body =~ ~r/DROP|TRUNCATE|DELETE/i,
               "#{name}'s own body in #{@source} contains a DROP/TRUNCATE/DELETE token"
      end
    end
  end

  describe "V1 stays aligned with core's manifest (while core audits the tables)" do
    alias PhoenixKit.Migrations.ExpectedSchema
    alias PhoenixKitWarehouse.GoodsIssue
    alias PhoenixKitWarehouse.GoodsReceipt
    alias PhoenixKitWarehouse.InternalOrder
    alias PhoenixKitWarehouse.InventoryDocument
    alias PhoenixKitWarehouse.SupplierOrder
    alias PhoenixKitWarehouse.Transfer

    @width_schemas %{
      "phoenix_kit_warehouse_goods_receipts" => GoodsReceipt,
      "phoenix_kit_warehouse_goods_issues" => GoodsIssue,
      "phoenix_kit_warehouse_internal_orders" => InternalOrder,
      "phoenix_kit_warehouse_supplier_orders" => SupplierOrder,
      "phoenix_kit_warehouse_inventory_documents" => InventoryDocument,
      "phoenix_kit_warehouse_transfers" => Transfer
    }

    # The lesson phoenix_kit_legal paid for once (three disagreeing DDLs of
    # one table): never a second copy of a width. Parsed back out of each
    # CREATE rather than trusted, so a hard-coded number slipped into
    # up_statements/2 instead of a schema's column_widths/0 fails here even
    # though the two happen to agree today.
    test "every varchar width in each CREATE is that table's schema's column_widths/0" do
      statements = Migrations.up_statements("public", 1)

      for {table, schema} <- @width_schemas do
        create = table_create(statements, table)

        parsed =
          ~r/"(\w+)" character varying\((\d+)\)/
          |> Regex.scan(create)
          |> Map.new(fn [_, col, width] ->
            {String.to_existing_atom(col), String.to_integer(width)}
          end)

        assert parsed == schema.column_widths(),
               """
               #{table}: the CREATE TABLE widths and #{inspect(schema)}.column_widths/0 disagree.

               parsed from DDL: #{inspect(parsed)}
               declared:        #{inspect(schema.column_widths())}
               """
      end
    end

    # Core's V140/V144 baseline still creates these tables and core's
    # ExpectedSchema audits that shape, so until the first shape-changing
    # chain version the two DDLs must agree. The comparison is PER FIELD and
    # asserts both key sets match in full (not just present keys) — a parse
    # that silently dropped some of core's columns, or a V1 column core does
    # not declare, must fail here rather than be skipped.
    test "every column core declares matches V1's, in full, for every table" do
      statements = Migrations.up_statements("public", 1)

      for table <- @warehouse_tables do
        core = core_columns(table)
        ours = v1_columns(statements, table)

        assert Map.keys(ours) -- Map.keys(core) == [],
               "#{table}: V1 creates columns core's manifest does not declare: " <>
                 inspect(Map.keys(ours) -- Map.keys(core))

        assert Map.keys(core) -- Map.keys(ours) == [],
               "#{table}: V1 does not create columns core's manifest declares: " <>
                 inspect(Map.keys(core) -- Map.keys(ours))

        for {column, expected} <- core do
          assert Map.fetch!(ours, column) == expected,
                 """
                 #{table}.#{column}: V1 and core's manifest disagree on the column's shape.

                 V1:              #{inspect(Map.fetch!(ours, column))}
                 core's manifest: #{inspect(expected)}

                 V1 is an adoption and must be shape-identical to core's
                 baseline. A deliberate change is a chain version (V2+).
                 """
        end
      end
    end

    # `%{type, default, not_null}` per column, from the newest revision.
    defp core_columns(table) do
      prefix = "column:#{table}."

      ExpectedSchema.objects("public")
      |> Enum.filter(&(&1.class == :column and String.starts_with?(&1.id, prefix)))
      |> Map.new(fn object ->
        {_version, shape} = List.last(object.revisions)

        {String.replace_prefix(object.id, prefix, ""),
         %{type: shape.type, default: shape.default, not_null: shape.not_null}}
      end)
    end

    # The same shape, parsed back out of the CREATE TABLE V1 emits for `table`.
    defp v1_columns(statements, table) do
      create = table_create(statements, table)

      ~r/^\s*"(\w+)"\s+(.+?),?$/m
      |> Regex.scan(create)
      |> Map.new(fn [_line, name, definition] -> {name, parse_column(definition)} end)
    end

    defp table_create(statements, table) do
      Enum.find(
        statements,
        &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} (")
      )
    end

    defp parse_column(definition) do
      {definition, not_null} =
        case String.replace_suffix(definition, " NOT NULL", "") do
          ^definition -> {definition, false}
          trimmed -> {trimmed, true}
        end

      case String.split(definition, " DEFAULT ", parts: 2) do
        [type] -> %{type: type, default: nil, not_null: not_null}
        [type, default] -> %{type: type, default: default, not_null: not_null}
      end
    end
  end
end
