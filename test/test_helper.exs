support_dir = Path.expand("support", __DIR__)

["test_repo.ex", "data_case.ex", "live_database_guard.ex", "catalogue_migration.ex"]
|> Enum.each(&Code.require_file(&1, support_dir))

db_name =
  Application.get_env(:phoenix_kit_warehouse, PhoenixKitWarehouse.Test.Repo)[:database] ||
    "phoenix_kit_warehouse_test"

# S014: refuse before anything else touches the database — see
# PhoenixKitWarehouse.Test.LiveDatabaseGuard's moduledoc for why this
# exists alongside (not instead of) the external `pk-test` wrapper.
PhoenixKitWarehouse.Test.LiveDatabaseGuard.check!(db_name)

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    # `psql` client not on PATH — don't crash the whole suite. Fall back to a
    # direct connection probe below, which degrades to excluding :integration
    # when no database is reachable.
    _ -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n  Test database "#{db_name}" not found — integration tests will be excluded.
       Run `createdb #{db_name}` to create the test database.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitWarehouse.Test.Repo.start_link()
      PhoenixKit.Migration.ensure_current(PhoenixKitWarehouse.Test.Repo, log: false)

      # `phoenix_kit_locations` (>= 0.5) owns a decentralized chain of its own
      # (`PhoenixKitLocations.Migrations`, same `migration_module/0`
      # discovery), and core's `ensure_current/2` above no longer carries it.
      # 0.5.0 added `owner_uuid` (+ the owner columns around it) to
      # `phoenix_kit_locations`, which `PhoenixKitLocations.Location` selects
      # on every read — so without this every LiveView test that loads a
      # warehouse location died with `column p0.owner_uuid does not exist`.
      # Executed as data like the warehouse block below: its `up/1` only
      # pipes `up_statements/2` into `execute/1`, and every statement is
      # idempotent, so a bare replay needs no migration runner.
      PhoenixKitLocations.Migrations.up_statements()
      |> Enum.each(&Ecto.Adapters.SQL.query!(PhoenixKitWarehouse.Test.Repo, &1, []))

      # This module's OWN decentralized migration chain
      # (`PhoenixKitWarehouse.Migrations`, discovered by `mix phoenix_kit.update`
      # via `migration_module/0`) now owns the future shape of all 8
      # `phoenix_kit_warehouse_*` tables — core's `ensure_current/2` above only
      # re-applies core's V140/V144 baseline. V1 is a pure adoption (every
      # statement `IF NOT EXISTS`/guarded, so re-running it against the
      # already-migrated core shape is a no-op except for stamping the
      # `pkw_schema:1` marker), so the statements are executed directly as
      # data via `up_statements/2` rather than through `up/1`: `up/1` needs a
      # live `Ecto.Migration` runner (its `execute/1` is
      # `Ecto.Migration.execute/1`), which this bare setup step doesn't have.
      PhoenixKitWarehouse.Migrations.up_statements()
      |> Enum.each(&Ecto.Adapters.SQL.query!(PhoenixKitWarehouse.Test.Repo, &1, []))

      # `phoenix_kit_catalogue` (>= 0.19, this module's floor is 0.28.5) owns a
      # decentralized migration chain of its own (`PhoenixKitCatalogue.Migrations`,
      # discovered by `mix phoenix_kit.update` via `migration_module/0`) — core's
      # `ensure_current/2` above only re-applies CORE's versioned chain, which no
      # longer carries catalogue's V2 (the per-language `slug` column + trigger
      # projections). Without this, every `phoenix_kit_cat_items` insert in this
      # suite fails with `column "slug" ... does not exist`. Run through
      # `Ecto.Migrator` (see `PhoenixKitWarehouse.Test.CatalogueMigration`)
      # rather than called bare: `Migrations.up/1`'s `execute/1` is
      # `Ecto.Migration.execute/1`, which requires a live migration runner
      # process. `all: true` re-applies on every chain-version bump; every
      # statement is idempotent (`IF NOT EXISTS` / guarded) so re-running a
      # version already at that mark is harmless.
      Ecto.Migrator.run(
        PhoenixKitWarehouse.Test.Repo,
        [
          {PhoenixKitWarehouse.Test.CatalogueMigration.migrator_version(),
           PhoenixKitWarehouse.Test.CatalogueMigration}
        ],
        :up,
        all: true,
        log: false
      )

      # A real deployment configures a default warehouse Location; the suite
      # never did. `phoenix_kit_warehouse_stock.location_uuid` is NOT NULL and
      # `StockLedger.upsert_quantity/3` falls back to the
      # `warehouse_default_location_uuid` setting whenever a caller passes no
      # `:location_uuid` — so with the setting unset every such write failed
      # validation with `location_uuid: "can't be blank"`. Seeded here rather
      # than in a `setup` block so it is committed OUTSIDE the sandbox and is
      # therefore visible to every test, async ones included. Tests that care
      # about a specific Location still pass `location_uuid:` explicitly.
      # There is no FK on the column, so a fixed UUID needs no Location row.
      PhoenixKitWarehouse.StockLedger.set_default_location_uuid(
        "00000000-0000-4000-8000-00000000dead"
      )

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitWarehouse.Test.Repo, :manual)
      true
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error] ->
        IO.puts("""
        \n  Could not connect to test database — integration tests will be excluded.
           Run `createdb #{db_name}` to create the test database.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n  Could not connect to test database — integration tests will be excluded.
           Run `createdb #{db_name}` to create the test database.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_warehouse, :test_repo_available, repo_available)

# Minimal PhoenixKit services the context layer reaches for. Without them the
# suite fails in ways that look like product bugs but are missing test wiring:
#
#   * PubSub.Manager — context writes broadcast, and an unstarted registry
#     raises `unknown registry: PhoenixKit.PubSub`.
#   * RateLimiter.Backend — anything that creates a user flows through
#     `PhoenixKit.Users.Auth.register_user/2`, which calls the Hammer-backed
#     rate limiter; without it its ETS table is absent and every such test dies
#     at `:ets.update_counter/4`.
#
# Mirrors `phoenix_kit_staff/test/test_helper.exs`, which in turn mirrors
# core's own `test/test_helper.exs`.
# Started directly rather than via `PhoenixKit.PubSub.Manager`: the Manager
# starts its Phoenix.PubSub from inside its own `init/1`, and in a bare test
# VM that leaves `PhoenixKit.PubSub` unregistered (the Manager process is
# alive but `Registry.meta(PhoenixKit.PubSub, :adapter)` still raises). Every
# context write broadcasts, so without a real registry the suite fails with
# `unknown registry: PhoenixKit.PubSub` — including from dependencies such as
# phoenix_kit_catalogue, which broadcasts on catalogue/item creation.
# Both, in this order. `PhoenixKit.PubSub.Manager` starts its own
# Phoenix.PubSub from inside `init/1`, which in a bare test VM leaves
# `PhoenixKit.PubSub` unregistered — the Manager process is alive but
# `Registry.meta(PhoenixKit.PubSub, :adapter)` still raises. Starting the
# registry explicitly first fixes the broadcasts (every context write
# broadcasts, dependencies such as phoenix_kit_catalogue included); the
# Manager is still needed by callers that go through its own API.
{:ok, _} =
  Supervisor.start_link([{Phoenix.PubSub, name: PhoenixKit.PubSub}], strategy: :one_for_one)

{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Force PhoenixKit's URL prefix cache to "/" so `Paths.*` produce paths the
# test router can actually match. Without it they carry the default
# "/phoenix_kit" prefix, the test router 404s, and every LiveView test dies
# inside `Phoenix.LiveViewTest.connect_from_static_token/3` with a
# FunctionClauseError that names neither the route nor the prefix.
# Mirrors phoenix_kit_staff.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# `PhoenixKitWarehouse.children/0` declares this and the host starts it; the
# test VM has no host, so the form LiveViews' fire-and-forget
# `Task.Supervisor.start_child(PhoenixKitWarehouse.TaskSupervisor, ...)` calls
# exited with `no process`.
{:ok, _} = Task.Supervisor.start_link(name: PhoenixKitWarehouse.TaskSupervisor)

# Start the test Endpoint so Phoenix.LiveViewTest can drive our LiveViews via
# `live/2`. `PhoenixKitWarehouse.Test.Endpoint` existed and `LiveCase` already
# pointed `@endpoint` at it, but nothing ever started it — so every LiveView
# test raised "could not find persistent term for endpoint". Runs with
# `server: false`, so no port is opened. Mirrors phoenix_kit_staff.
if repo_available do
  {:ok, _} = PhoenixKitWarehouse.Test.Endpoint.start_link()
end

exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
