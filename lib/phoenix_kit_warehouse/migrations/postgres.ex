defmodule PhoenixKitWarehouse.Migrations.Postgres do
  @moduledoc """
  Versioned PostgreSQL migrations for `phoenix_kit_warehouse`'s own tables —
  the ones core PhoenixKit doesn't ship (e.g. `phoenix_kit_warehouse_transfers`).
  `phoenix_kit_warehouse_stock` and the document tables ship in core's own
  V140 (and the host's bootstrap migration mirrors it) — this module never
  touches those, only tables introduced after the module already exists.

  Wired up via the `migration_module/0` callback in `PhoenixKitWarehouse`
  (the `PhoenixKit.Module` behaviour) — `mix phoenix_kit.update` discovers
  it, generates an incremental migration file in the host app, and calls
  `up/1` / `down/1` from it the same way it drives core's own
  `PhoenixKit.Migrations.Postgres`. That module is this one's style
  reference (`execute("CREATE ... IF NOT EXISTS ...")`, one submodule per
  version, `COMMENT ON TABLE ... IS '<v>'` as the version marker) — it is
  NOT inherited from or delegated to; this is a fully independent migrator
  scoped to this package's own tables.

  The version marker lives on `phoenix_kit_warehouse_stock` (a table this
  module can always count on existing by the time it runs) rather than on
  core's `phoenix_kit` table, which is core's marker to manage exclusively.

  ## Versions

  ### V01 - Transfers table
  Creates `phoenix_kit_warehouse_transfers` — the warehouse-to-warehouse
  stock movement document (`draft → in_transit → done`, plus a side
  `cancelled` status). See `PhoenixKitWarehouse.Migrations.Postgres.V01`
  for the full column/index list.
  """

  @current_version 1
  @default_prefix "public"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Latest migration version this module knows how to reach."
  def current_version, do: @current_version

  @doc """
  Reads the currently-migrated version straight from the database, outside
  a migration context, by inspecting the `COMMENT ON TABLE` marker on
  `phoenix_kit_warehouse_stock`. Returns `0` when there is no comment yet —
  that covers both "table missing" and "table exists, never migrated by
  this module" as the same case, since (unlike core's `phoenix_kit`
  marker) this table is always created by something else (core V140 / the
  host's bootstrap migration) before this module ever gets to run, so "no
  comment" can only mean "still at V00".

  Unlike core's `migrated_version_runtime/1`, this does not retry or hunt
  for a repo across fallback strategies — `PhoenixKit.RepoHelper.repo/0` is
  already used synchronously everywhere else in this package and is just
  as reliable here.

  Accepts a keyword list or map; reads `:prefix` (default `"public"`).
  """
  def migrated_version_runtime(opts) do
    prefix = opts |> Map.new() |> Map.get(:prefix, @default_prefix)
    escaped_prefix = String.replace(prefix, "'", "\\'")

    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = 'phoenix_kit_warehouse_stock'
    AND pg_namespace.nspname = '#{escaped_prefix}'
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc """
  Runs every version's `up/1` between the runtime-detected current version
  (exclusive) and `opts[:version]` (inclusive — the target version; always
  supplied by the host wrapper `mix phoenix_kit.update` generates, so it is
  required here rather than defaulted).
  """
  def up(opts) do
    opts = Map.new(opts)
    prefix = Map.get(opts, :prefix, @default_prefix)
    target = Map.fetch!(opts, :version)
    current = migrated_version_runtime(prefix: prefix)

    if current < target do
      for v <- (current + 1)..target, do: version_module(v).up(%{prefix: prefix})
    end

    :ok
  end

  @doc """
  Runs every version's `down/1` between the runtime-detected current
  version and `opts[:version]` (exclusive — the rollback target; defaults
  to `0`, a full rollback, when omitted — mirrors core's `down/1`).
  """
  def down(opts) do
    opts = Map.new(opts)
    prefix = Map.get(opts, :prefix, @default_prefix)
    target = Map.get(opts, :version, 0)
    current = migrated_version_runtime(prefix: prefix)

    if current > target do
      for v <- current..(target + 1)//-1, do: version_module(v).down(%{prefix: prefix})
    end

    :ok
  end

  defp version_module(v) do
    Module.concat([__MODULE__, "V" <> String.pad_leading(to_string(v), 2, "0")])
  end
end
