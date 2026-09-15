defmodule PhoenixKitWarehouse.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_warehouse` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`. This follows the canonical shape
  documented in `phoenix_kit_hello_world`'s README ("Versioned migrations",
  "Adopting a table core already creates") and its
  `mix phoenix_kit_hello_world.audit_migrations` task: **two readers**
  (`migrated_version/1` for migration context, `migrated_version_runtime/1`
  for Mix-task context), `up/1` re-reading the version before it changes
  anything, and a namespaced `COMMENT ON TABLE` marker on one anchor table
  for a chain that spans eight. `phoenix_kit_billing` (`v4_statements/2`,
  ten adopted tables in one version) and `phoenix_kit_dashboards` (one
  adopted table) are the closest sibling examples of this exact adoption
  situation.

  ## Ownership situation — read before touching

  All 8 `phoenix_kit_warehouse_*` tables are core's baseline: `V140` created
  `stock`, `inventory_documents`, `internal_orders`, `supplier_orders`,
  `goods_receipts`, and `goods_issues`; `V144` added `transfers` and
  `min_stock`. On every existing install all 8 already have their full
  current shape before this chain ever executes — this is an ADOPTION, not
  a create. Varchar widths are never restated as a second number: each of
  the six document schemas' own `column_widths/0` (`GoodsReceipt`,
  `GoodsIssue`, `InternalOrder`, `SupplierOrder`, `InventoryDocument`,
  `Transfer` — `Stock` and `MinStock` have no varchar column) is the single
  shape authority this chain's DDL interpolates.

  Rather than stamp all 8 tables, the chain anchors its version marker on a
  single table — `phoenix_kit_warehouse_stock`, chosen because it is the
  first table core's `V140` creates and has no FK dependencies of its own —
  the same way `phoenix_kit_billing`'s multi-table V4 anchors on a single
  pre-existing table instead of stamping all ten it adopts.

  ### Two reconciled discrepancies between core's migration source and its `ExpectedSchema` manifest

  1. Eight columns (`item_uuid`/`location_uuid` across `stock`, `min_stock`,
     `goods_issues`, `goods_receipts`, `internal_orders`,
     `inventory_documents`, `supplier_orders`) are declared `NOT NULL` by
     both core's actual migration source (`v140.ex`/`v144.ex`) and the
     manifest's own structured `revisions.not_null` field, but the
     manifest's human-readable `create:` string for those columns omits
     `NOT NULL`. This chain's DDL follows the source and `revisions` (`NOT
     NULL` on all eight) — the `create:` string is the buggy
     representation.
  2. The FK on `phoenix_kit_warehouse_inventory_documents.performed_by_uuid`
     is named `phoenix_kit_warehouse_inventory_document_performed_by_uuid_fkey`
     — **singular** "document" — unlike its five sibling `performed_by_uuid`
     FKs, which all use the plural table name. Postgres's default FK-naming
     silently truncates the `<table>_<column>_fkey` identifier once it
     exceeds the 63-byte `NAMEDATALEN` limit, which is what actually
     happened here (`v140.ex` never names this FK explicitly). This chain
     hard-codes the singular name as a literal constraint name — it is not
     derived programmatically from the table name.

  ### Phase 0 — this V1 adopts, and changes NOTHING

  `CREATE TABLE IF NOT EXISTS` shape-identical to core's `V140`/`V144`
  baseline, under core's exact object names (every pkey, index, check
  constraint, and FK), then a **namespaced** marker stamp on the anchor
  table (`pkw_schema:1` — an adopted table may already carry a foreign
  comment, so the reader must treat prose as version 0, never crash on it,
  never assume it means V1). Because the shape is unchanged, core's
  `ExpectedSchema` manifest stays accurate: **no core release is required
  and there is no release-ordering hazard.** This package releases alone.

  ### Phase 1 — the first real shape change (V2+) is when core must move too

  Before shipping a version that changes any of the 8 tables' shape:

    1. add the objects that version alters to core's manifest generator's
       `@excluded_exact` (`dev_docs/squash/generate_baseline.exs`) and
       regenerate `ExpectedSchema`;
    2. raise this package's `:phoenix_kit` floor to the release that ships
       that regenerated manifest.

  Skipping step 1 means `mix phoenix_kit.repair` restores the old shape
  after every run, silently undoing the new version.

  ### Phase 2 — creation leaves core's baseline at the next squash cycle

  When core cuts its next baseline, module-owned tables are simply not
  included: fresh installs from then on get all 8 `phoenix_kit_warehouse_*`
  tables from THIS chain's V1 — which is why V1's `up/1` ensures the
  `uuid_generate_v7()` function (and its `pgcrypto` extension) exist rather
  than assuming core's chain already provided them, and why every `CREATE
  TABLE` must already be the full, correct definition on its own, not
  merely a shape-matching no-op for an already-existing table. Existing
  installs are untouched — a baseline squash only affects fresh installs
  and below-floor bridging.

  ## What must NEVER happen

  No conditional core migration of the form "module absent → drop the
  tables" — that is nondeterministic (depends on which packages are
  compiled in) and destroys data on a host that merely removed the
  package. Removing this module's data is a human, manual step — see
  README.md "Removing this module" for the operator SQL. There is
  deliberately no automated uninstall path, and `down/1` NEVER drops any of
  the 8 tables for ANY target version, including `0` — it only unstamps
  (or re-stamps) the marker on the anchor table. The rows are live stock
  balances and document history, and on most installs every table is
  core-created; rolling back this module's chain must not destroy any of
  them.

  The migrated version is tracked as a `pkw_schema:<N>` COMMENT on
  `phoenix_kit_warehouse_stock`. A marker-less table, or one carrying a
  foreign (non-`pkw_schema:`) comment, reads as version 0 — the
  core-baseline shape before this chain existed.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.Transfer

  @initial_version 1
  @current_version 1
  @default_prefix "public"
  @marker_prefix "pkw_schema:"

  @stock "phoenix_kit_warehouse_stock"
  @inventory_documents "phoenix_kit_warehouse_inventory_documents"
  @internal_orders "phoenix_kit_warehouse_internal_orders"
  @supplier_orders "phoenix_kit_warehouse_supplier_orders"
  @goods_receipts "phoenix_kit_warehouse_goods_receipts"
  @goods_issues "phoenix_kit_warehouse_goods_issues"
  @transfers "phoenix_kit_warehouse_transfers"
  @min_stock "phoenix_kit_warehouse_min_stock"

  # The single table this chain's marker lives on — `stock` is core's V140
  # anchor table (first created, no FK dependencies of its own). Every other
  # table adopted below shares this chain's version; none of them carry a
  # marker of their own.
  @version_table @stock

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  The version a bare, freshly-created set of tables is at (Phase 2 — a
  future install whose core baseline no longer creates these tables).
  """
  @spec initial_version() :: pos_integer()
  def initial_version, do: @initial_version

  @doc """
  The table carrying the `pkw_schema:<N>` marker for the whole 8-table chain.

  Not part of the protocol `mix phoenix_kit.update` calls. Exported so an
  auditor (`mix phoenix_kit_hello_world.audit_migrations`) can verify the
  marker is really a number without hard-coding this table's name.
  """
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  Applies every chain version up to `opts[:version]` (default
  `current_version/0`). Migration-context only — re-reads the installed
  version via `migrated_version/1` before making any change, so a database
  already at (or ahead of) the target does nothing.
  """
  @spec up(keyword() | map()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)

    if migrated_version(opts) < opts.version do
      # Don't assume core's chain ran first (Phase 2): `uuid_generate_v7()`
      # is built on pgcrypto's `gen_random_bytes`, and
      # `ensure_uuid_v7_function/1` does not install extensions — without
      # the first call the function is created and then fails on the first
      # insert.
      Helpers.ensure_extension!("pgcrypto")
      Helpers.ensure_uuid_v7_function(opts.prefix)

      opts.prefix
      |> up_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  Rolls back to `opts[:version]` (default `0`). Migration-context only.
  Never drops a table or a row in any of the 8, for any target — see the
  moduledoc.
  """
  @spec down(keyword() | map()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)

    if migrated_version(opts) > opts.version do
      opts.prefix
      |> down_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  The version currently installed, read INSIDE a migration — through
  `Ecto.Migration`'s own `repo()`. No rescue: inside a migration a version
  that cannot be read must abort the transaction, never be guessed at.
  `up/1` and `down/1` call this — never `migrated_version_runtime/1` —
  before making any change.
  """
  @spec migrated_version(keyword() | map()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(repo(), opts.prefix)
  end

  @doc """
  Runtime-safe reader — the one `mix phoenix_kit.update` calls, from a Mix
  task with no migrator running, through PhoenixKit's configured repo
  instead of `Ecto.Migration`'s.

  An invalid prefix is re-raised, matching core's own reader: `0` means
  "not installed here", so reporting it for a bad prefix would tell the
  operator something false and send the updater off to install a schema
  over live data. Genuine unreachability still yields `0`, which is safe
  only because `up/1` re-reads the version in migration context before
  touching anything — a wrong `0` costs a redundant migration file, never
  wrong DDL.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.prefix)
  rescue
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. The
  ownership test suite parses these statements to prove that the object
  names are core's `V140`/`V144` names, that every `CREATE TABLE` stays
  shape-identical to core's `ExpectedSchema` manifest, that every varchar
  width is its owning schema's `column_widths/0`, and that nothing here can
  drop a table.

  `target` selects how much of the chain to emit (default
  `current_version/0`): `0` applies nothing (not an operation — clearing
  the marker is `down/1`'s job); `1` is the pure `V140`/`V144`-adoption step
  across all 8 tables.
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ @default_prefix, target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix)

    if target == 0 do
      []
    else
      v1_statements(prefix, target)
    end
  end

  @doc """
  The SQL `down/1` executes, as data (marker bookkeeping only, on the
  anchor table). V1 changes no shape of its own — it is pure adoption — so
  there is nothing to drop beyond the marker; all 8 tables and every row in
  them are left untouched, for any target including `0`.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ @default_prefix, target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix)
    qualified = Helpers.qualify_table(@version_table, prefix)

    if target > 0 do
      ["COMMENT ON TABLE #{qualified} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{qualified} IS NULL"]
    end
  end

  # ── V1 statement builder ────────────────────────────────────────────────

  defp v1_statements(prefix, target) do
    users = Helpers.qualify_table("phoenix_kit_users", prefix)
    uuid_default = Helpers.uuid_v7_call(prefix)

    qs = Helpers.qualify_table(@stock, prefix)
    qid = Helpers.qualify_table(@inventory_documents, prefix)
    qio = Helpers.qualify_table(@internal_orders, prefix)
    qso = Helpers.qualify_table(@supplier_orders, prefix)
    qgr = Helpers.qualify_table(@goods_receipts, prefix)
    qgi = Helpers.qualify_table(@goods_issues, prefix)
    qtr = Helpers.qualify_table(@transfers, prefix)
    qms = Helpers.qualify_table(@min_stock, prefix)

    seq_id = Helpers.qualify_table("#{@inventory_documents}_number_seq", prefix)
    seq_io = Helpers.qualify_table("#{@internal_orders}_number_seq", prefix)
    seq_so = Helpers.qualify_table("#{@supplier_orders}_number_seq", prefix)
    seq_gr = Helpers.qualify_table("#{@goods_receipts}_number_seq", prefix)
    seq_gi = Helpers.qualify_table("#{@goods_issues}_number_seq", prefix)
    seq_tr = Helpers.qualify_table("#{@transfers}_number_seq", prefix)

    receipt_widths = GoodsReceipt.column_widths()
    issue_widths = GoodsIssue.column_widths()
    internal_order_widths = InternalOrder.column_widths()
    supplier_order_widths = SupplierOrder.column_widths()
    document_widths = InventoryDocument.column_widths()
    transfer_widths = Transfer.column_widths()

    sequences =
      for seq <- [seq_id, seq_io, seq_so, seq_gr, seq_gi, seq_tr] do
        "CREATE SEQUENCE IF NOT EXISTS #{seq} AS bigint INCREMENT BY 1 MINVALUE 1 " <>
          "MAXVALUE 9223372036854775807 START WITH 1 CACHE 1"
      end

    tables = [
      """
      CREATE TABLE IF NOT EXISTS #{qs} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "item_uuid" uuid NOT NULL,
        "location_uuid" uuid NOT NULL,
        "quantity" numeric DEFAULT 0 NOT NULL,
        "unit_value" numeric,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{qid} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "number" bigint DEFAULT nextval('#{seq_id}'::regclass) NOT NULL,
        "status" character varying(#{document_widths.status}) DEFAULT 'draft'::character varying NOT NULL,
        "track_value" boolean DEFAULT false NOT NULL,
        "location_uuid" uuid NOT NULL,
        "storage_folder_uuid" uuid,
        "note" text,
        "lines" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "created_by_uuid" uuid,
        "performed_by_uuid" uuid,
        "posted_at" timestamp with time zone,
        "deleted_at" timestamp with time zone,
        "deleted_by_uuid" uuid,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{qio} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "number" bigint DEFAULT nextval('#{seq_io}'::regclass) NOT NULL,
        "status" character varying(#{internal_order_widths.status}) DEFAULT 'draft'::character varying NOT NULL,
        "location_uuid" uuid NOT NULL,
        "note" text,
        "lines" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "source_refs" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "created_by_uuid" uuid,
        "performed_by_uuid" uuid,
        "posted_at" timestamp with time zone,
        "deleted_at" timestamp with time zone,
        "deleted_by_uuid" uuid,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{qso} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "number" bigint DEFAULT nextval('#{seq_so}'::regclass) NOT NULL,
        "status" character varying(#{supplier_order_widths.status}) DEFAULT 'draft'::character varying NOT NULL,
        "supplier_uuid" uuid,
        "internal_order_uuid" uuid,
        "location_uuid" uuid NOT NULL,
        "note" text,
        "storage_folder_uuid" uuid,
        "lines" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "source_refs" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "created_by_uuid" uuid,
        "performed_by_uuid" uuid,
        "posted_at" timestamp with time zone,
        "deleted_at" timestamp with time zone,
        "deleted_by_uuid" uuid,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{qgr} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "number" bigint DEFAULT nextval('#{seq_gr}'::regclass) NOT NULL,
        "status" character varying(#{receipt_widths.status}) DEFAULT 'draft'::character varying NOT NULL,
        "supplier_order_uuid" uuid,
        "supplier_uuid" uuid,
        "location_uuid" uuid NOT NULL,
        "note" text,
        "storage_folder_uuid" uuid,
        "lines" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "source_refs" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "created_by_uuid" uuid,
        "performed_by_uuid" uuid,
        "posted_at" timestamp with time zone,
        "deleted_at" timestamp with time zone,
        "deleted_by_uuid" uuid,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{qgi} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "number" bigint DEFAULT nextval('#{seq_gi}'::regclass) NOT NULL,
        "status" character varying(#{issue_widths.status}) DEFAULT 'draft'::character varying NOT NULL,
        "internal_order_uuid" uuid,
        "location_uuid" uuid NOT NULL,
        "note" text,
        "storage_folder_uuid" uuid,
        "lines" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "source_refs" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "created_by_uuid" uuid,
        "performed_by_uuid" uuid,
        "posted_at" timestamp with time zone,
        "deleted_at" timestamp with time zone,
        "deleted_by_uuid" uuid,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{qtr} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "number" bigint DEFAULT nextval('#{seq_tr}'::regclass) NOT NULL,
        "status" character varying(#{transfer_widths.status}) DEFAULT 'draft'::character varying NOT NULL,
        "source_location_uuid" uuid,
        "destination_location_uuid" uuid,
        "note" text,
        "storage_folder_uuid" uuid,
        "lines" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "source_refs" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "created_by_uuid" uuid,
        "performed_by_uuid" uuid,
        "shipped_at" timestamp with time zone,
        "received_at" timestamp with time zone,
        "cancelled_at" timestamp with time zone,
        "deleted_at" timestamp with time zone,
        "deleted_by_uuid" uuid,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{qms} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "item_uuid" uuid NOT NULL,
        "min_quantity" numeric DEFAULT 0 NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """
    ]

    pkeys =
      for {table, qualified} <- [
            {@stock, qs},
            {@inventory_documents, qid},
            {@internal_orders, qio},
            {@supplier_orders, qso},
            {@goods_receipts, qgr},
            {@goods_issues, qgi},
            {@transfers, qtr},
            {@min_stock, qms}
          ] do
        pkey_guard(table, qualified, prefix)
      end

    checks = [
      check_guard(
        @stock,
        qs,
        "phoenix_kit_warehouse_stock_quantity_non_negative",
        "CHECK (quantity >= 0)",
        prefix
      ),
      check_guard(
        @min_stock,
        qms,
        "phoenix_kit_warehouse_min_stock_min_quantity_non_negative",
        "CHECK (min_quantity >= 0)",
        prefix
      )
    ]

    indexes =
      [
        {"UNIQUE", "#{@stock}_item_location_index", qs, "btree", "item_uuid, location_uuid"},
        {"", "#{@stock}_location_uuid_index", qs, "btree", "location_uuid"},
        {"UNIQUE", "#{@inventory_documents}_number_index", qid, "btree", "number"},
        {"", "#{@inventory_documents}_status_index", qid, "btree", "status"},
        {"", "#{@inventory_documents}_inserted_at_index", qid, "btree", "inserted_at"},
        {"", "#{@inventory_documents}_deleted_at_index", qid, "btree", "deleted_at"},
        {"", "#{@inventory_documents}_location_uuid_index", qid, "btree", "location_uuid"},
        {"UNIQUE", "#{@internal_orders}_number_index", qio, "btree", "number"},
        {"", "#{@internal_orders}_status_index", qio, "btree", "status"},
        {"", "#{@internal_orders}_inserted_at_index", qio, "btree", "inserted_at"},
        {"", "#{@internal_orders}_deleted_at_index", qio, "btree", "deleted_at"},
        {"", "#{@internal_orders}_location_uuid_index", qio, "btree", "location_uuid"},
        {"", "#{@internal_orders}_source_refs_index", qio, "gin", "source_refs"},
        {"UNIQUE", "#{@supplier_orders}_number_index", qso, "btree", "number"},
        {"", "#{@supplier_orders}_status_index", qso, "btree", "status"},
        {"", "#{@supplier_orders}_inserted_at_index", qso, "btree", "inserted_at"},
        {"", "#{@supplier_orders}_deleted_at_index", qso, "btree", "deleted_at"},
        {"", "#{@supplier_orders}_location_uuid_index", qso, "btree", "location_uuid"},
        {"", "#{@supplier_orders}_supplier_uuid_index", qso, "btree", "supplier_uuid"},
        {"", "#{@supplier_orders}_internal_order_uuid_index", qso, "btree",
         "internal_order_uuid"},
        {"", "#{@supplier_orders}_source_refs_index", qso, "gin", "source_refs"},
        {"UNIQUE", "#{@goods_receipts}_number_index", qgr, "btree", "number"},
        {"", "#{@goods_receipts}_status_index", qgr, "btree", "status"},
        {"", "#{@goods_receipts}_inserted_at_index", qgr, "btree", "inserted_at"},
        {"", "#{@goods_receipts}_deleted_at_index", qgr, "btree", "deleted_at"},
        {"", "#{@goods_receipts}_location_uuid_index", qgr, "btree", "location_uuid"},
        {"", "#{@goods_receipts}_supplier_order_uuid_index", qgr, "btree", "supplier_order_uuid"},
        {"", "#{@goods_receipts}_source_refs_index", qgr, "gin", "source_refs"},
        {"UNIQUE", "#{@goods_issues}_number_index", qgi, "btree", "number"},
        {"", "#{@goods_issues}_status_index", qgi, "btree", "status"},
        {"", "#{@goods_issues}_inserted_at_index", qgi, "btree", "inserted_at"},
        {"", "#{@goods_issues}_deleted_at_index", qgi, "btree", "deleted_at"},
        {"", "#{@goods_issues}_location_uuid_index", qgi, "btree", "location_uuid"},
        {"", "#{@goods_issues}_internal_order_uuid_index", qgi, "btree", "internal_order_uuid"},
        {"", "#{@goods_issues}_source_refs_index", qgi, "gin", "source_refs"},
        {"UNIQUE", "#{@transfers}_number_index", qtr, "btree", "number"},
        {"", "#{@transfers}_status_index", qtr, "btree", "status"},
        {"", "#{@transfers}_inserted_at_index", qtr, "btree", "inserted_at"},
        {"", "#{@transfers}_deleted_at_index", qtr, "btree", "deleted_at"},
        {"", "#{@transfers}_source_location_uuid_index", qtr, "btree", "source_location_uuid"},
        {"", "#{@transfers}_destination_location_uuid_index", qtr, "btree",
         "destination_location_uuid"},
        {"", "#{@transfers}_shipped_at_index", qtr, "btree", "shipped_at"},
        {"", "#{@transfers}_received_at_index", qtr, "btree", "received_at"},
        {"", "#{@transfers}_source_refs_index", qtr, "gin", "source_refs"},
        {"UNIQUE", "#{@min_stock}_item_uuid_index", qms, "btree", "item_uuid"}
      ]
      |> Enum.map(fn {unique, name, table, method, columns} ->
        "CREATE #{unique_prefix(unique)}INDEX IF NOT EXISTS #{name} ON #{table} USING #{method} (#{columns})"
      end)

    fks = [
      # Reconciled discrepancy 2 (moduledoc): singular "document" — Postgres's default FK-naming
      # truncated this identifier past 63 bytes; hard-coded literally, not
      # derived from the (plural) table name.
      fk_guard(
        @inventory_documents,
        qid,
        "phoenix_kit_warehouse_inventory_document_performed_by_uuid_fkey",
        "performed_by_uuid",
        users,
        prefix
      ),
      fk_guard(
        @internal_orders,
        qio,
        "#{@internal_orders}_performed_by_uuid_fkey",
        "performed_by_uuid",
        users,
        prefix
      ),
      fk_guard(
        @supplier_orders,
        qso,
        "#{@supplier_orders}_internal_order_uuid_fkey",
        "internal_order_uuid",
        qio,
        prefix
      ),
      fk_guard(
        @supplier_orders,
        qso,
        "#{@supplier_orders}_performed_by_uuid_fkey",
        "performed_by_uuid",
        users,
        prefix
      ),
      fk_guard(
        @goods_receipts,
        qgr,
        "#{@goods_receipts}_supplier_order_uuid_fkey",
        "supplier_order_uuid",
        qso,
        prefix
      ),
      fk_guard(
        @goods_receipts,
        qgr,
        "#{@goods_receipts}_performed_by_uuid_fkey",
        "performed_by_uuid",
        users,
        prefix
      ),
      fk_guard(
        @goods_issues,
        qgi,
        "#{@goods_issues}_internal_order_uuid_fkey",
        "internal_order_uuid",
        qio,
        prefix
      ),
      fk_guard(
        @goods_issues,
        qgi,
        "#{@goods_issues}_performed_by_uuid_fkey",
        "performed_by_uuid",
        users,
        prefix
      ),
      fk_guard(
        @transfers,
        qtr,
        "#{@transfers}_performed_by_uuid_fkey",
        "performed_by_uuid",
        users,
        prefix
      )
    ]

    marker = ["COMMENT ON TABLE #{qs} IS '#{@marker_prefix}#{target}'"]

    sequences ++ tables ++ pkeys ++ checks ++ indexes ++ fks ++ marker
  end

  defp unique_prefix("UNIQUE"), do: "UNIQUE "
  defp unique_prefix(""), do: ""

  defp pkey_guard(table, qualified, prefix) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{table}_pkey'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (uuid);
      END IF;
    END
    $$
    """
  end

  defp check_guard(table, qualified, constraint_name, check_clause, prefix) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{constraint_name} #{check_clause};
      END IF;
    END
    $$
    """
  end

  defp fk_guard(table, qualified, constraint_name, column, references, prefix) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{constraint_name} FOREIGN KEY (#{column}) REFERENCES #{references}(uuid) ON DELETE SET NULL;
      END IF;
    END
    $$
    """
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{})
    prefix = validated_prefix(Map.get(opts, :prefix) || @default_prefix)

    opts
    |> Map.put(:prefix, prefix)
    |> Map.put_new(:version, version)
  end

  defp read_version(repo, prefix) do
    if table_exists?(repo, prefix) do
      repo |> table_comment(prefix) |> parse_version()
    else
      0
    end
  end

  defp table_exists?(repo, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = $1 AND table_schema = $2
    )
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[exists?]]}} -> exists?
      {:error, error} -> raise error
    end
  end

  defp table_comment(repo, prefix) do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = $1 AND n.nspname = $2
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[comment]]}} -> comment
      {:ok, %{rows: []}} -> nil
      {:error, error} -> raise error
    end
  end

  defp parse_version(@marker_prefix <> n) do
    case Integer.parse(n) do
      {version, ""} when version >= 0 -> version
      _ -> 0
    end
  end

  defp parse_version(_), do: 0

  defp validate_target!(target) when target > @current_version do
    raise ArgumentError,
          "PhoenixKitWarehouse.Migrations has no version #{target} " <>
            "(current_version/0 is #{@current_version}); stamping it would make every " <>
            "later version look already applied"
  end

  defp validate_target!(_target), do: :ok

  defp validated_prefix(prefix) do
    if Code.ensure_loaded?(Helpers) and function_exported?(Helpers, :validate_prefix!, 1) do
      Helpers.validate_prefix!(prefix)
    else
      unless is_binary(prefix) and prefix =~ ~r/^[a-z_][a-z0-9_]*$/ and byte_size(prefix) <= 20 do
        raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
      end
    end

    prefix
  end
end
